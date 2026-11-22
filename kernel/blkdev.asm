; ============================================================================
;  KKernel — blkdev.asm
;  块设备抽象层(Phase U1):把"读/写扇区"从具体硬件上解耦。
;
;  为什么要有这一层:
;    FAT 驱动原来每读一个扇区都直接 call ata_read_sectors —— 文件系统代码
;    和 ATA 硬件绑在一起。U3 要让同一个 FAT 驱动去读写插在 USB 上的 U 盘,
;    所以加一层很薄的块设备分发:ATA 和 USB 大容量储存设备各注册一个描述符,
;    上层只认 blk_read_sectors / blk_write_sectors,通过 blk_cur 选当前设备。
;
;  ABI(和 ata_read_sectors 完全一致,由 fat.asm 的 fat_dev_read/write 转过来):
;    blk_read_sectors : eax=LBA, ecx=扇区数, edi=目标缓冲 → eax=0 成功 / -1 失败
;    blk_write_sectors: eax=LBA, ecx=扇区数, esi=源缓冲   → eax=0 成功 / -1 失败
;  调用方除 eax 外的通用寄存器保持不变(分发前 push ebx,后端自己保护寄存器)。
;
;  设备描述符(20 字节):
;    +0  name      dd  名字字符串指针("ATA" / "USB",调试与报告用)
;    +4  read      dd  读函数(ABI 同上)
;    +8  write     dd  写函数(ABI 同上)
;    +12 sectors   dd  设备总扇区数(0 = 未知)
;    +16 sector_sz dd  扇区大小(本内核只支持 512)
;
;  USB 后端一次 Bulk-Only 传输最多 8 个扇区(中间缓冲 USB_MSD_DATA 4 KiB),
;  大请求自动拆成多段;中间缓冲和 usbdisk 命令共用(都在进程上下文用,
;  中断里 usb_poll 只碰 HID 中断端点,不会踩这块)。
; ============================================================================

BLK_FAT_STATE_BUF equ 0x3C6000          ; USB 挂载时保存 ATA FAT 挂载状态的缓冲
BLK_FAT_STATE_MAX equ 4096              ; 状态区上限(超过要加大缓冲,见汇编期自检)
BLK_USB_MAX_CHUNK equ 8                 ; 一次 USB BOT 最多几个扇区

; ---------------------------------------------------------------- 代码
; ---------------------------------------------------------------------------
;  blk_read_sectors / blk_write_sectors:按当前设备分发
; ---------------------------------------------------------------------------
blk_read_sectors:
    push ebx
    mov ebx, [blk_cur]
    call dword [ebx + 4]
    pop ebx
    ret

blk_write_sectors:
    push ebx
    mov ebx, [blk_cur]
    call dword [ebx + 8]
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  blkdev_select_ata / blkdev_select_usb:切换当前设备(usbdisk mount/umount 用)
; ---------------------------------------------------------------------------
blkdev_select_ata:
    mov dword [blk_cur], blkdev_ata
    ret

blkdev_select_usb:
    mov dword [blk_cur], blkdev_usb
    ret

; blkdev_set_usb_sectors:记录 USB 设备总扇区数(usbdisk_init 读完容量后调),eax=总扇区
blkdev_set_usb_sectors:
    mov [blkdev_usb + 12], eax
    ret

; blkdev_get_sectors:返回当前设备总扇区数(0 = 未知),eax=值
blkdev_get_sectors:
    mov eax, [blk_cur]
    mov eax, [eax + 12]
    ret

; ---------------------------------------------------------------------------
;  ATA 后端:ABI 完全一致,直接跳过去
; ---------------------------------------------------------------------------
blk_ata_read:
    jmp ata_read_sectors
blk_ata_write:
    jmp ata_write_sectors

; ---------------------------------------------------------------------------
;  USB 后端:读扇区
;  eax=LBA, ecx=n, edi=buf;拆成 <=8 扇区的 BOT 传输,中间缓冲 USB_MSD_DATA。
; ---------------------------------------------------------------------------
blk_usb_read:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp
    cmp dword [usbdisk_ready], 0
    je .fail
    mov ebp, eax                    ; 当前 LBA
    mov ebx, edi                    ; 当前目标指针
    mov [blk_usb_left], ecx         ; 还剩几扇区
.loop:
    mov ecx, [blk_usb_left]
    test ecx, ecx
    jz .ok
    cmp ecx, BLK_USB_MAX_CHUNK
    jbe .chunk
    mov ecx, BLK_USB_MAX_CHUNK
.chunk:
    mov [blk_usb_chunk], ecx
    mov eax, ebp
    mov edi, USB_MSD_DATA
    call usb_scsi_read
    test eax, eax
    jnz .fail
    ; 数据已经到 USB_MSD_DATA:抄给调用方
    mov esi, USB_MSD_DATA
    mov edi, ebx
    mov ecx, [blk_usb_chunk]
    shl ecx, 9
    cld
    rep movsb                       ; esi/edi 前进到段尾
    mov ebx, edi
    mov ecx, [blk_usb_chunk]
    add ebp, ecx
    sub [blk_usb_left], ecx
    jmp .loop
.ok:
    xor eax, eax
    jmp .out
.fail:
    mov eax, -1
.out:
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  USB 后端:写扇区
;  eax=LBA, ecx=n, esi=buf
; ---------------------------------------------------------------------------
blk_usb_write:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp
    cmp dword [usbdisk_ready], 0
    je .fail
    mov ebp, eax                    ; 当前 LBA
    mov ebx, esi                    ; 当前源指针
    mov [blk_usb_left], ecx
.loop:
    mov ecx, [blk_usb_left]
    test ecx, ecx
    jz .ok
    cmp ecx, BLK_USB_MAX_CHUNK
    jbe .chunk
    mov ecx, BLK_USB_MAX_CHUNK
.chunk:
    mov [blk_usb_chunk], ecx
    ; 先把这一小段抄进 USB 的中间缓冲
    mov esi, ebx
    mov edi, USB_MSD_DATA
    mov ecx, [blk_usb_chunk]
    shl ecx, 9
    cld
    rep movsb
    mov ebx, esi
    ; 发 WRITE(10)
    mov eax, ebp
    mov ecx, [blk_usb_chunk]
    mov edi, USB_MSD_DATA
    call usb_scsi_write
    test eax, eax
    jnz .fail
    mov ecx, [blk_usb_chunk]
    add ebp, ecx
    sub [blk_usb_left], ecx
    jmp .loop
.ok:
    xor eax, eax
    jmp .out
.fail:
    mov eax, -1
.out:
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; 数据区尺寸自检:fat.asm 末尾会算好 FAT_STATE_SIZE(挂载状态区字节数)
%if FAT_STATE_SIZE > BLK_FAT_STATE_MAX
    %error "FAT 挂载状态区超过 BLK_FAT_STATE_MAX(4 KiB):要加大保存缓冲再继续"
%endif

; ---------------------------------------------------------------- 数据
align 4
blk_cur:
    dd blkdev_ata                   ; 当前设备:开机默认 ATA 硬盘

blkdev_ata:
    dd blk_name_ata, blk_ata_read, blk_ata_write, 0, 512
blkdev_usb:
    dd blk_name_usb, blk_usb_read, blk_usb_write, 0, 512

blk_name_ata    db "ATA", 0
blk_name_usb    db "USB", 0

blk_usb_left    dd 0                ; USB 后端的剩余扇区数
blk_usb_chunk   dd 0                ; 本次 BOT 传输的扇区数
