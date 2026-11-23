; ============================================================================
;  KKernel — USB 大容量储存(U2/U3:读写 + 上面挂 FAT)
;
;  在 usb.asm 的 UHCI 底座上补四块:
;    1) bulk 端点传输:每个 TD 发一个包(≤64B),toggle 显式给,3 秒超时
;    2) Bulk-Only Transport(BOT):CBW 31 字节 / CSW 13 字节
;    3) SCSI 最小集:INQUIRY / TEST UNIT READY / READ CAPACITY(10) / READ(10)
;        / WRITE(10) / SYNCHRONIZE CACHE(10) / REQUEST SENSE
;       WRITE 失败会先发 REQUEST SENSE 再重试(最多 3 次)。
;    4) `usbdisk mount/umount`:把块设备层(blkdev.asm)的当前设备从 ATA 切到
;       USB,让同一个 FAT 驱动去读写 U 盘;umount 时原样恢复 ATA 的挂载状态。
;
;  ── 只支持一个 USB 设备 ──────────────────────────────────────────────────
;  usb.asm 的枚举只认第一个设备(地址 1)。所以 U 盘能用的前提是:它是这台
;  机器上第一个枚举到的 USB 设备(测试环境里只有它;真机上要是先插了 USB
;  键盘,就得先拔键盘 —— 见 README 的限制一节)。
;
;  ── 结构放哪 ─────────────────────────────────────────────────────────────
;  usb.asm 用了 0x3C0000–0x3C11FF;本文件占 0x3C1200–0x3C2FFF(0x400000 起
;  才是物理页池)。80 个 TD 够一次读 8 个扇区(512B = 8 包)。
;
;  ── BOT 的 DATA toggle 约定(照 USB Mass Storage BOT 规范)──────────────
;    CBW: DATA0;数据阶段:从 DATA0 起每包翻;CSW: DATA1。
;    每条命令都是显式给初始 toggle,不依赖上一条命令的残留状态。
; ============================================================================

; ---- 结构区(0x3C1200 起,usb.asm 之后)----
USB_BULK_QH    equ 0x3C1200
USB_BULK_TD    equ 0x3C1210       ; 80 × 16 B = 1280 B
USB_BOT_CBW    equ 0x3C1800       ; 31 B
USB_BOT_CSW    equ 0x3C1820       ; 13 B
USB_MSD_CDB    equ 0x3C1840       ; 16 B CDB
USB_MSD_TMP    equ 0x3C1860       ; 64 B(INQUIRY 36B / READ CAP 8B / SENSE 18B)
USB_MSD_DATA   equ 0x3C2000       ; 4 KiB 数据缓冲(最多 8 扇区)
USB_MSD_BACKUP equ 0x3C1A00       ; 512 B:usbdisk write 自测时备份原扇区

USB_MAX_TD     equ 80

; ===========================================================================
;  usbdisk_init:开机调一次(kmain 在 usb_init 之后)。没 U 盘就静默。
; ===========================================================================
usbdisk_init:
    pushad
    mov byte [usbdisk_ready], 0
    cmp byte [usb_msd_ok], 0
    je .out

    ; ---- TEST UNIT READY:设备可能还在转,重试 3 次 ----
    mov dword [usbd_retry], 3
.try_ready:
    call usb_scsi_test_unit_ready
    test eax, eax
    jz .ready
    dec dword [usbd_retry]
    jnz .try_ready
    jmp .out
.ready:
    ; ---- INQUIRY:厂商/型号/版本(失败也继续,信息只用于显示)----
    call usb_scsi_inquiry
    ; ---- READ CAPACITY:总扇区 + 块大小 ----
    call usb_scsi_capacity
    test eax, eax
    jnz .out
    mov byte [usbdisk_ready], 1
    mov eax, [usbdisk_lba]
    call blkdev_set_usb_sectors         ; 块设备层:USB 设备总扇区数
.out:
    popad
    ret

; ===========================================================================
;  usb_bulk_xfer:一次 bulk 传输(按 mps 拆成多个 TD,每 TD 一个包)
;    esi = 缓冲, ecx = 长度, edi = 端点地址, edx = 1 IN / 0 OUT, ebx = 起始 toggle
;    返回 eax = 0 成功,-1 失败/超时
; ===========================================================================

; ===========================================================================
;  usbd_frames_bulk / usbd_frames_ctrl:把 1024 项帧列表切到 bulk QH 或切回
;  控制 QH(枚举/后续控制传输仍走控制 QH)
; ===========================================================================
usbd_frames_bulk:
    pushad
    cld
    mov edi, USB_FRAME_LIST
    mov eax, USB_BULK_QH | 2
    mov ecx, 1024
    rep stosd
    popad
    ret

usbd_frames_ctrl:
    pushad
    cld
    mov edi, USB_FRAME_LIST
    mov eax, USB_CTRL_QH | 2
    mov ecx, 1024
    rep stosd
    popad
    ret

usb_bulk_xfer:
    pushad
    cmp byte [usb_msd_ok], 0
    je .offline                     ; 盘被拔掉: 直接失败,别碰硬件
    cmp dword [usb_msd_ctrl], 2
    je .to_ehci
    jmp .go
.to_ehci:
    popad
    jmp ehci_bulk_xfer              ; EHCI 高速设备走 EHCI 传输
.offline:
    mov dword [usb_xfer_ret], -1
    popad
    ret
.go:
    mov [usb_xfer_buf], esi
    mov [usb_xfer_len], ecx
    mov [usb_xfer_ep], edi
    mov [usb_xfer_dir], edx
    mov [usb_xfer_toggle], ebx
    mov dword [usb_xfer_ret], -1

    ; 方向对应的 max packet,上限 64
    mov eax, [usb_msd_mps_out]
    test edx, edx
    jz .mps_ok
    mov eax, [usb_msd_mps_in]
.mps_ok:
    test eax, eax
    jz .bail
    cmp eax, 64
    jbe .mps_cap
    mov eax, 64
.mps_cap:
    mov [usb_xfer_mps], eax

    ; 停 QH,清 TD 区(别让上一笔的残留被硬件捡起来)
    mov dword [USB_BULK_QH + 4], 1
    cld
    mov edi, USB_BULK_TD
    xor eax, eax
    mov ecx, USB_MAX_TD * 4
    rep stosd

    mov esi, [usb_xfer_buf]
    mov ecx, [usb_xfer_len]
    test ecx, ecx
    jz .empty
    mov ebp, [usb_xfer_toggle]
    mov ebx, USB_BULK_TD
    xor edi, edi                      ; TD 计数
.pkt:
    ; ---- 这一包的字节数 → [usb_pkt_len] ----
    mov eax, [usb_xfer_mps]
    cmp eax, ecx
    jbe .len_ok
    mov eax, ecx
.len_ok:
    mov [usb_pkt_len], eax

    ; ---- token ----
    mov edx, [usb_msd_addr]
    shl edx, 8
    cmp dword [usb_xfer_dir], 0
    jne .in_pid
    or edx, 0xE1                      ; OUT
    jmp .pid_done
.in_pid:
    or edx, 0x69                      ; IN
.pid_done:
    mov eax, [usb_xfer_ep]
    shl eax, 15
    or edx, eax
    mov eax, ebp
    shl eax, 19
    or edx, eax
    mov eax, [usb_pkt_len]
    dec eax
    and eax, 0x7FF
    shl eax, 21
    or edx, eax

    mov dword [ebx + 4], TD_STATUS
    mov [ebx + 8], edx
    mov [ebx + 12], esi

    ; 先按"中间项"链接,最后再改最后一根
    lea eax, [ebx + 16]
    or eax, 4
    mov [ebx], eax

    ; 前进
    mov eax, [usb_pkt_len]
    add esi, eax
    sub ecx, eax
    xor ebp, 1
    add ebx, 16
    inc edi
    test ecx, ecx
    jnz .pkt
    mov dword [ebx - 16], 1           ; 最后一个 TD:link=1
    mov [usb_xfer_ntd], edi

    ; 挂到 QH,3 秒超时(300 tick)
    mov dword [USB_BULK_QH], 1        ; 队列头:没有下一个 QH,链到终止
    mov dword [USB_BULK_QH + 4], USB_BULK_TD
    call usbd_frames_bulk             ; 帧列表切到 bulk QH
    call pit_get_ticks
    add eax, 300
    mov [usb_deadline], eax

.wait:
    ; 扫所有 TD:有错就失败
    mov ebx, USB_BULK_TD
    mov ecx, [usb_xfer_ntd]
.scan:
    mov eax, [ebx + 4]
    test eax, TD_ERRMASK
    jnz .fail
    add ebx, 16
    dec ecx
    jnz .scan

    ; 最后一个 TD 完成了吗?
    mov ebx, USB_BULK_TD
    mov eax, [usb_xfer_ntd]
    dec eax
    shl eax, 4
    add ebx, eax
    test dword [ebx + 4], TD_ACTIVE
    jz .ok

    call pit_get_ticks
    sub eax, [usb_deadline]
    jns .fail
    hlt
    jmp .wait

.ok:
    mov dword [USB_BULK_QH + 4], 1
    call usbd_frames_ctrl
    mov dword [usb_xfer_ret], 0
    jmp .done

.empty:
    mov dword [usb_xfer_ret], 0
    jmp .done

.fail:
    ; 清 Active,别让下一笔传输重跑坏 TD
    mov ebx, USB_BULK_TD
    mov ecx, [usb_xfer_ntd]
.clr:
    test ecx, ecx
    jz .clr_done
    and dword [ebx + 4], 0xFF7FFFFF
    add ebx, 16
    dec ecx
    jmp .clr
.clr_done:
    mov dword [USB_BULK_QH + 4], 1
    call usbd_frames_ctrl
    mov dword [usb_xfer_ret], -1
.done:
    mov eax, usb_mutex
    call mutex_unlock
    popad
    mov eax, [usb_xfer_ret]
    ret
.bail:
    mov dword [usb_xfer_ret], -1
    jmp .done

; ===========================================================================
;  usb_bot:发一条 SCSI 命令(Bulk-Only Transport)
;    esi = CDB, ecx = 数据长度, edi = 数据缓冲, edx = 1 IN / 0 OUT, ebx = CDB 长度
;    返回 eax = 0 成功,-1 失败;usb_bot_status = CSW 状态码
; ===========================================================================
usb_bot:
    pushad
    ; 整个 BOT 事务(多笔 bulk)串行化:防止另一线程的枚举/读写插进来
    ; 把 CBW/CSW/数据缓冲搅乱。mutex 可重入(usb_hotplug_process 已持锁时没问题)。
    mov eax, usb_mutex
    call mutex_lock
    mov [usb_bot_cdb], esi
    mov [usb_bot_dlen], ecx
    mov [usb_bot_dbuf], edi
    mov [usb_bot_dir], edx
    mov [usb_bot_cdblen], ebx
    mov dword [usb_xfer_ret], -1

    ; ---- 填 CBW ----
    mov dword [USB_BOT_CBW], 0x43425355          ; 'USBC'
    inc dword [usb_bot_tag]
    mov eax, [usb_bot_tag]
    mov [USB_BOT_CBW + 4], eax
    mov eax, [usb_bot_dlen]
    mov [USB_BOT_CBW + 8], eax
    xor eax, eax
    cmp dword [usb_bot_dir], 0
    je .flags
    mov al, 0x80
.flags:
    mov [USB_BOT_CBW + 12], al
    mov byte [USB_BOT_CBW + 13], 0               ; LUN 0
    mov eax, [usb_bot_cdblen]
    mov [USB_BOT_CBW + 14], al
    mov esi, [usb_bot_cdb]
    mov edi, USB_BOT_CBW + 15
    mov ecx, [usb_bot_cdblen]
    cld
    rep movsb

    ; ---- CBW:bulk OUT,DATA0 ----
    mov esi, USB_BOT_CBW
    mov ecx, 31
    mov edi, [usb_msd_ep_out]
    xor edx, edx
    xor ebx, ebx
    call usb_bulk_xfer
    test eax, eax
    jnz .fail

    ; ---- 数据阶段(有数据才跑)----
    mov ecx, [usb_bot_dlen]
    test ecx, ecx
    jz .csw
    mov esi, [usb_bot_dbuf]
    mov edi, [usb_msd_ep_out]
    mov edx, [usb_bot_dir]
    test edx, edx
    jz .dir_done
    mov edi, [usb_msd_ep_in]
.dir_done:
    xor ebx, ebx
    call usb_bulk_xfer
    test eax, eax
    jnz .fail

.csw:
    ; ---- CSW:bulk IN,DATA1 ----
    mov esi, USB_BOT_CSW
    mov ecx, 13
    mov edi, [usb_msd_ep_in]
    mov edx, 1
    mov ebx, 1
    call usb_bulk_xfer
    test eax, eax
    jnz .fail

    ; ---- 校验 CSW ----
    cmp dword [USB_BOT_CSW], 0x53425355          ; 'USBS'
    jne .fail
    mov eax, [usb_bot_tag]
    cmp dword [USB_BOT_CSW + 4], eax
    jne .fail
    mov eax, [USB_BOT_CSW + 8]
    mov [usb_bot_residue], eax
    movzx eax, byte [USB_BOT_CSW + 12]
    mov [usb_bot_status], al
    test al, al
    jnz .fail
    mov dword [usb_xfer_ret], 0
    jmp .done
.fail:
    mov dword [usb_xfer_ret], -1
.done:
    popad
    mov eax, [usb_xfer_ret]
    ret

; ===========================================================================
;  SCSI 小命令(都走 usb_bot)
; ===========================================================================

; TEST UNIT READY:CDB 6 字节全 0
usb_scsi_test_unit_ready:
    pushad
    mov edi, USB_MSD_CDB
    xor eax, eax
    mov ecx, 4
    rep stosd
    mov esi, USB_MSD_CDB
    xor ecx, ecx
    xor edi, edi
    xor edx, edx
    mov ebx, 6
    call usb_bot
    mov [usb_xfer_ret], eax
    popad
    mov eax, [usb_xfer_ret]
    ret

; INQUIRY:CDB 12 00 00 00 24 00,数据 36 字节
usb_scsi_inquiry:
    pushad
    mov edi, USB_MSD_CDB
    xor eax, eax
    mov ecx, 4
    rep stosd
    mov byte [USB_MSD_CDB], 0x12
    mov byte [USB_MSD_CDB + 4], 36
    mov esi, USB_MSD_CDB
    mov ecx, 36
    mov edi, USB_MSD_TMP
    mov edx, 1
    mov ebx, 6
    call usb_bot
    mov [usb_xfer_ret], eax
    test eax, eax
    jnz .done
    ; 抄出 vendor[8](+8)/ product[16](+16) / revision[4](+32),补 0
    mov esi, USB_MSD_TMP + 8
    mov edi, usb_inq_vendor
    mov ecx, 8
    cld
    rep movsb
    mov byte [usb_inq_vendor + 8], 0
    mov esi, USB_MSD_TMP + 16
    mov edi, usb_inq_product
    mov ecx, 16
    rep movsb
    mov byte [usb_inq_product + 16], 0
    mov esi, USB_MSD_TMP + 32
    mov edi, usb_inq_rev
    mov ecx, 4
    rep movsb
    mov byte [usb_inq_rev + 4], 0
.done:
    popad
    mov eax, [usb_xfer_ret]
    ret

; READ CAPACITY(10):CDB 10 字节(首字节 0x25),数据 8 字节 = last_lba(BE32)+块大小(BE32)
usb_scsi_capacity:
    pushad
    mov edi, USB_MSD_CDB
    xor eax, eax
    mov ecx, 4
    rep stosd
    mov byte [USB_MSD_CDB], 0x25
    mov esi, USB_MSD_CDB
    mov ecx, 8
    mov edi, USB_MSD_TMP
    mov edx, 1
    mov ebx, 10
    call usb_bot
    mov [usb_xfer_ret], eax
    test eax, eax
    jnz .done
    mov eax, [USB_MSD_TMP]
    bswap eax
    inc eax                            ; last_lba + 1 = 总扇区数
    mov [usbdisk_lba], eax
    mov eax, [USB_MSD_TMP + 4]
    bswap eax
    test eax, eax
    jz .done
    mov [usbdisk_block], eax
.done:
    popad
    mov eax, [usb_xfer_ret]
    ret

; READ(10):CDB 28 00 LBA(BE32) 00 长度(BE16) 00
;   eax = LBA,ecx = 扇区数(1..8),edi = 缓冲;返回 eax=0 成功
usb_scsi_read:
    pushad
    mov [usb_read_lba], eax
    mov [usb_read_cnt], ecx
    mov [usb_read_buf], edi

    mov edi, USB_MSD_CDB
    xor eax, eax
    mov ecx, 4
    rep stosd
    mov byte [USB_MSD_CDB], 0x28
    mov eax, [usb_read_lba]
    bswap eax
    mov [USB_MSD_CDB + 2], eax
    mov ax, [usb_read_cnt]
    xchg al, ah
    mov [USB_MSD_CDB + 7], ax

    mov esi, USB_MSD_CDB
    mov ecx, [usb_read_cnt]
    shl ecx, 9                         ; ×512
    mov edi, [usb_read_buf]
    mov edx, 1
    mov ebx, 10
    call usb_bot
    mov [usb_xfer_ret], eax
    popad
    mov eax, [usb_xfer_ret]
    ret

; REQUEST SENSE:CDB 03 00 00 00 12 00,数据 18 字节
usb_scsi_sense:
    pushad
    mov edi, USB_MSD_CDB
    xor eax, eax
    mov ecx, 4
    rep stosd
    mov byte [USB_MSD_CDB], 0x03
    mov byte [USB_MSD_CDB + 4], 18
    mov esi, USB_MSD_CDB
    mov ecx, 18
    mov edi, USB_MSD_TMP
    mov edx, 1
    mov ebx, 6
    call usb_bot
    mov [usb_xfer_ret], eax
    popad
    mov eax, [usb_xfer_ret]
    ret

; WRITE(10):CDB 2A 00 LBA(BE32) 00 长度(BE16) 00
;   eax = LBA,ecx = 扇区数(1..8),edi = 数据缓冲;返回 eax=0 成功
;   失败先发 REQUEST SENSE 看原因,再重试(最多 3 次 —— U2 验收要求)。
;   注意 USB_MSD_DATA 是唯一的 USB 数据缓冲,重试之间不能有别人碰它;
;   调用方(blkdev 后端)保证一次只发一条命令。
usb_scsi_write:
    pushad
    mov [usb_write_lba], eax
    mov [usb_write_cnt], ecx
    mov [usb_write_buf], edi
    mov dword [usb_write_try], 0
.try:
    ; ---- 填 CDB:WRITE(10) ----
    mov edi, USB_MSD_CDB
    xor eax, eax
    mov ecx, 4
    rep stosd
    mov byte [USB_MSD_CDB], 0x2A              ; WRITE(10)
    mov eax, [usb_write_lba]
    bswap eax
    mov [USB_MSD_CDB + 2], eax
    mov ax, [usb_write_cnt]
    xchg al, ah
    mov [USB_MSD_CDB + 7], ax

    mov esi, USB_MSD_CDB
    mov ecx, [usb_write_cnt]
    shl ecx, 9                                ; ×512
    mov edi, [usb_write_buf]
    xor edx, edx                              ; 0 = 数据阶段 OUT(主机 → 设备)
    mov ebx, 10
    call usb_bot
    test eax, eax
    jz .ok
    ; ---- 失败:问一次 SENSE(错误码留在 USB_MSD_TMP,`usbdisk sense` 能看),再重试 ----
    mov [usb_xfer_ret], eax
    call usb_scsi_sense
    inc dword [usb_write_try]
    cmp dword [usb_write_try], 3
    jb .try
    popad
    mov eax, -1
    ret
.ok:
    popad
    xor eax, eax
    ret

; SYNCHRONIZE CACHE(10):CDB 35 00 00 00 00 00 00 00 00 00(无数据阶段)
usb_scsi_sync:
    pushad
    mov edi, USB_MSD_CDB
    xor eax, eax
    mov ecx, 4
    rep stosd
    mov byte [USB_MSD_CDB], 0x35
    mov esi, USB_MSD_CDB
    xor ecx, ecx
    xor edi, edi
    xor edx, edx
    mov ebx, 10
    call usb_bot
    mov [usb_xfer_ret], eax
    popad
    mov eax, [usb_xfer_ret]
    ret

; ===========================================================================
;  打印辅助
; ===========================================================================

; al = 0xNN → 打印两个十六进制字符
usbd_hex8:
    push eax
    push ebx
    push esi
    movzx ebx, al
    mov esi, ebx
    shr esi, 4
    mov al, [usbd_hex_digits + esi]
    call term_putc
    and ebx, 0x0F
    mov al, [usbd_hex_digits + ebx]
    call term_putc
    pop esi
    pop ebx
    pop eax
    ret

; 打印定长字段(去尾部空格):esi = 指针,ecx = 长度
usbd_put_field:
    pushad
    mov [usbd_fld_ptr], esi
    mov [usbd_fld_len], ecx
    mov edi, ecx
.trim:
    test edi, edi
    jz .done
    mov esi, [usbd_fld_ptr]
    mov eax, edi
    dec eax
    cmp byte [esi + eax], ' '
    jne .print
    dec edi
    jmp .trim
.print:
    mov [usbd_fld_len], edi
.loop:
    cmp dword [usbd_fld_len], 0
    je .done
    mov esi, [usbd_fld_ptr]
    mov al, [esi]
    call term_putc
    inc dword [usbd_fld_ptr]
    dec dword [usbd_fld_len]
    jmp .loop
.done:
    popad
    ret

; 十六进制 + ASCII 转储:esi = 缓冲,ecx = 长度
usbd_hexdump:
    pushad
    mov [usbd_dump_buf], esi
    mov [usbd_dump_len], ecx
    xor ebp, ebp
.row:
    cmp ebp, [usbd_dump_len]
    jae .done
    mov eax, ebp
    call pci_ph4
    mov esi, msg_hexdump_colon
    call term_print
    xor ebx, ebx
.col:
    cmp ebx, 16
    jae .ascii
    mov eax, ebp
    add eax, ebx
    cmp eax, [usbd_dump_len]
    jae .pad
    mov esi, [usbd_dump_buf]
    movzx eax, byte [esi + eax]
    call usbd_hex8
    mov al, ' '
    call term_putc
    jmp .next_col
.pad:
    mov esi, msg_hexdump_pad
    call term_print
.next_col:
    inc ebx
    jmp .col
.ascii:
    mov al, '|'
    call term_putc
    xor ebx, ebx
.ascii_loop:
    cmp ebx, 16
    jae .ascii_end
    mov eax, ebp
    add eax, ebx
    cmp eax, [usbd_dump_len]
    jae .ascii_end
    mov esi, [usbd_dump_buf]
    movzx eax, byte [esi + eax]
    cmp al, 32
    jb .dot
    cmp al, 126
    ja .dot
    jmp .put
.dot:
    mov al, '.'
.put:
    call term_putc
    inc ebx
    jmp .ascii_loop
.ascii_end:
    mov al, '|'
    call term_putc
    mov al, 10
    call term_putc
    add ebp, 16
    jmp .row
.done:
    popad
    ret

; 取 [cmd_arg] 的第一个词到 esi/ecx(词长),并返回词后的参数指针到 [usbd_rest]
; 返回 ecx > 0;空参数时 ecx=0
;  usbd_first_word:[cmd_arg] 的第一个词
;    返回 esi = 词起点, ecx = 词长度, [usbd_rest] = 词后面的参数起点(跳过空格)
usbd_first_word:
    push edi
    mov esi, [cmd_arg]
.skip:
    cmp byte [esi], ' '
    jne .start
    inc esi
    jmp .skip
.start:
    mov edi, esi
.len:
    mov al, [edi]
    test al, al
    jz .len_done
    cmp al, ' '
    je .len_done
    inc edi
    jmp .len
.len_done:
    mov ecx, edi
    sub ecx, esi
    ; 参数指针 = 词尾,跳过空格
.arg:
    cmp byte [edi], ' '
    jne .arg_done
    inc edi
    jmp .arg
.arg_done:
    mov [usbd_rest], edi
    pop edi
    ret

; 解析 [cmd_arg] 的十进制 LBA → usb_read_lba;CF=1 表示不是合法数字
usbd_parse_lba:
    ; parse_dec 解析的是 [cmd_arg],这里先临时切到 [usbd_rest](参数本身)
    mov eax, [cmd_arg]
    mov [usbd_saved_arg], eax
    mov eax, [usbd_rest]
    mov [cmd_arg], eax
    call parse_dec
    mov edx, [usbd_saved_arg]
    mov [cmd_arg], edx
    jc .bad
    mov [usb_read_lba], eax
    clc
    ret
.bad:
    stc
    ret

; usbd_find_part:从读进来的 LBA0 缓冲(ebx)里找 FAT 分区起始 LBA
;   eax = 分区起始 LBA;CF=1 = 没有可识别的 FAT 分区
;   规则:先扫 MBR 4 个分区项,认 FAT 类型(0x04/0x06/0x0B/0x0C/0x0E);
;   没有分区表 → 当超级软盘(分区起点 0),要求它是合法 FAT 引导扇区。
usbd_find_part:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    cmp word [ebx + 510], 0xAA55
    jne .notfound
    mov ecx, 4
    lea esi, [ebx + 446]
.scan:
    movzx eax, byte [esi + 4]                 ; 分区类型
    cmp al, 0x04
    je .hit
    cmp al, 0x06
    je .hit
    cmp al, 0x0B
    je .hit
    cmp al, 0x0C
    je .hit
    cmp al, 0x0E
    je .hit
    add esi, 16
    dec ecx
    jnz .scan
    ; 没有 FAT 分区项:看看是不是"超级软盘"(引导扇区直接就是 FAT)
    cmp word [ebx + 11], 512
    jne .notfound
    cmp word [ebx + 22], 0
    je .notfound                              ; FAT32 的超级软盘也认(但少见)
    xor eax, eax
    clc
    jmp .out
.hit:
    mov eax, [esi + 8]                        ; 分区起始 LBA(小端)
    clc
    jmp .out
.notfound:
    stc
.out:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; ===========================================================================
;  shell 的 usbdisk 命令
;    usbdisk                 设备信息 + 当前挂载状态
;    usbdisk mount           找 U 盘上的 FAT 分区,挂到 FAT 驱动上(切块设备)
;    usbdisk umount          恢复 ATA 的 FAT 挂载状态
;    usbdisk status          看当前挂的是 U 盘还是 ATA
;    usbdisk read <lba>      读一个扇区并转储前 64 字节
;    usbdisk hexdump <lba>   读一个扇区并全量转储(512B,会滚屏)
;    usbdisk write <lba>     写测试扇区(先备份→写图案→读回比对→恢复原内容)
;    usbdisk mbr             读 LBA0 并解析 4 个分区表项
;    usbdisk sense           发 REQUEST SENSE 看错误码
; ===========================================================================
cmd_usbdisk:
    pushad
    cmp byte [usb_msd_ok], 0
    jne .have_dev
    ; 无设备时 status 依然要报告状态(FAT 设备是 ATA / 未挂载),
    ; 其余子命令走"没有 U 盘"提示。
    call usbd_first_word
    test ecx, ecx
    jz .no_dev
    mov edx, n_usbd_status
    call str_eq
    test eax, eax
    jnz .do_status
    jmp .no_dev
.have_dev:

    ; ---- 没初始化成功:允许 sense,其它命令报错 ----
    cmp byte [usbdisk_ready], 0
    jne .info
    call usbd_first_word
    test ecx, ecx
    jz .not_ready
    mov edx, n_usbd_sense
    call str_eq
    test eax, eax
    jnz .do_sense
    jmp .not_ready

.info:
    ; ---- 设备信息 ----
    mov esi, msg_usbd_dev
    call term_print
    mov esi, usb_inq_vendor
    mov ecx, 8
    call usbd_put_field
    mov al, ' '
    call term_putc
    mov esi, usb_inq_product
    mov ecx, 16
    call usbd_put_field
    mov esi, msg_usbd_rev
    call term_print
    mov esi, usb_inq_rev
    mov ecx, 4
    call usbd_put_field
    mov al, 10
    call term_putc

    mov esi, msg_usbd_cap
    call term_print
    mov eax, [usbdisk_lba]
    call term_print_dec
    mov esi, msg_usbd_sect
    call term_print
    mov eax, [usbdisk_block]
    call term_print_dec
    mov esi, msg_usbd_bytes
    call term_print
    mov eax, [usbdisk_lba]
    mov ecx, [usbdisk_block]
    mul ecx
    mov ecx, 1024
    div ecx
    call term_print_dec
    mov esi, msg_usbd_kib
    call term_print

    ; ---- 当前挂的是谁(ATA 硬盘 / U 盘)----
    cmp byte [usb_mounted], 0
    je .info_ata
    mov esi, msg_usbd_state_usb
    call term_print
    jmp .info_dispatch
.info_ata:
    mov esi, msg_usbd_state_ata
    call term_print
.info_dispatch:

    ; ---- 有参数就继续分发 ----
    call usbd_first_word
    test ecx, ecx
    jz .done

    mov edx, n_usbd_read
    call str_eq
    test eax, eax
    jnz .do_read
    mov edx, n_usbd_hexdump
    call str_eq
    test eax, eax
    jnz .do_hexdump
    mov edx, n_usbd_mbr
    call str_eq
    test eax, eax
    jnz .do_mbr
    mov edx, n_usbd_sense
    call str_eq
    test eax, eax
    jnz .do_sense
    mov edx, n_usbd_mount
    call str_eq
    test eax, eax
    jnz .do_mount
    mov edx, n_usbd_umount
    call str_eq
    test eax, eax
    jnz .do_umount
    mov edx, n_usbd_status
    call str_eq
    test eax, eax
    jnz .do_status
    mov edx, n_usbd_write
    call str_eq
    test eax, eax
    jnz .do_write
    jmp .usage

; ---- usbdisk read <lba>:读 1 扇区,转储前 64 字节 ----
.do_read:
    call usbd_parse_lba
    jc .usage
    mov ecx, 1
    mov edi, USB_MSD_DATA
    call usb_scsi_read
    test eax, eax
    jnz .read_fail
    mov esi, USB_MSD_DATA
    mov ecx, 64
    call usbd_hexdump
    jmp .done

; ---- usbdisk hexdump <lba>:读 1 扇区,全量转储 ----
.do_hexdump:
    call usbd_parse_lba
    jc .usage
    mov ecx, 1
    mov edi, USB_MSD_DATA
    call usb_scsi_read
    test eax, eax
    jnz .read_fail
    mov esi, USB_MSD_DATA
    mov ecx, 512
    call usbd_hexdump
    jmp .done

; ---- usbdisk mbr ----
.do_mbr:
    xor eax, eax
    mov ecx, 1
    mov edi, USB_MSD_DATA
    call usb_scsi_read
    test eax, eax
    jnz .read_fail
    mov dword [usbd_i], 0
.mbr_loop:
    mov eax, [usbd_i]
    cmp eax, 4
    jae .mbr_done
    ; esi = USB_MSD_DATA + 446 + i*16
    shl eax, 4
    add eax, 446
    add eax, USB_MSD_DATA
    mov [usbd_ptr], eax
    ; "pN: "
    mov esi, msg_mbr_p
    call term_print
    mov eax, [usbd_i]
    inc eax
    call term_print_dec
    mov esi, msg_mbr_type
    call term_print
    mov esi, [usbd_ptr]
    movzx eax, byte [esi + 4]
    call usbd_hex8
    mov esi, msg_mbr_start
    call term_print
    mov esi, [usbd_ptr]
    mov eax, [esi + 8]          ; start LBA(小端)
    call term_print_dec
    mov esi, msg_mbr_secs
    call term_print
    mov esi, [usbd_ptr]
    mov eax, [esi + 12]         ; sectors(小端)
    call term_print_dec
    mov al, 10
    call term_putc
    inc dword [usbd_i]
    jmp .mbr_loop
.mbr_done:
    jmp .done

; ---- usbdisk sense ----
.do_sense:
    call usb_scsi_sense
    ; 失败也继续打内容:REQUEST SENSE 本身失败才是真没救
    mov esi, msg_sense_hdr
    call term_print
    movzx eax, byte [USB_MSD_TMP]
    and al, 0x7F
    call usbd_hex8
    mov esi, msg_sense_key
    call term_print
    movzx eax, byte [USB_MSD_TMP + 2]
    and al, 0x0F
    call usbd_hex8
    mov esi, msg_sense_asc
    call term_print
    movzx eax, byte [USB_MSD_TMP + 12]
    call usbd_hex8
    mov esi, msg_sense_ascq
    call term_print
    movzx eax, byte [USB_MSD_TMP + 13]
    call usbd_hex8
    mov al, 10
    call term_putc
    jmp .done


; ---- usbdisk mount:保存 ATA 的 FAT 状态 → 切块设备到 USB → 找分区 → fat_mount ----
.do_mount:
    cmp byte [usb_mounted], 0
    jne .mount_busy
    call fat_state_save                      ; ATA 的挂载状态先存起来
    call blkdev_select_usb
    mov eax, [usbdisk_lba]
    call blkdev_set_usb_sectors
    ; 读 LBA0(MBR / 超级软盘引导扇区)
    xor eax, eax
    mov ecx, 1
    mov edi, USB_MSD_DATA
    call usb_scsi_read
    test eax, eax
    jnz .mount_ioerr
    mov ebx, USB_MSD_DATA
    call usbd_find_part
    jc .mount_nofs
    call fat_set_part_base                   ; eax = 分区起始 LBA
    call fat_mount
    test eax, eax
    jnz .mount_nofs
    mov byte [usb_mounted], 1
    call shell_reset_cwd                     ; shell 的 cwd 回根(新文件系统)
    ; 挂载成功信息:FAT 类型 + 分区起点 + 总扇区数
    mov esi, msg_usbd_mounted
    call term_print
    call fat_type
    call term_print_dec
    mov esi, msg_usbd_at
    call term_print
    call fat_get_part_base
    call term_print_dec
    mov esi, msg_usbd_comma
    call term_print
    call blkdev_get_sectors
    call term_print_dec
    mov esi, msg_usbd_sectors
    call term_print
    jmp .done
.mount_busy:
    mov esi, msg_usbd_mountbusy
    call term_print
    jmp .done
.mount_ioerr:
    call fat_state_restore
    call blkdev_select_ata
    call shell_reset_cwd
    mov esi, msg_usbd_mountioerr
    call term_print
    jmp .done
.mount_nofs:
    call fat_state_restore
    call blkdev_select_ata
    call shell_reset_cwd
    mov esi, msg_usbd_mountnofs
    call term_print
    jmp .done

; ---- usbdisk umount:同步设备缓存 → 恢复 ATA 挂载状态 → 块设备切回 ATA ----
.do_umount:
    cmp byte [usb_mounted], 0
    je .umount_no
    call usb_scsi_sync
    call fat_state_restore
    call blkdev_select_ata
    mov byte [usb_mounted], 0
    call shell_reset_cwd
    mov esi, msg_usbd_umounted
    call term_print
    call fat_type
    call term_print_dec
    mov esi, msg_usbd_at
    call term_print
    call fat_get_part_base
    call term_print_dec
    mov al, 10
    call term_putc
    jmp .done
.umount_no:
    mov esi, msg_usbd_umountno
    call term_print
    jmp .done

; ---- usbdisk status:当前挂的是谁 ----
.do_status:
    cmp byte [usb_mounted], 0
    je .status_ata
    mov esi, msg_usbd_status_usb
    call term_print
    call fat_type
    call term_print_dec
    mov esi, msg_usbd_at
    call term_print
    call fat_get_part_base
    call term_print_dec
    mov al, 10
    call term_putc
    jmp .done
.status_ata:
    mov esi, msg_usbd_status_ata
    call term_print
    jmp .done

; ---- usbdisk write <lba>:写路径自测 ----
; 先读原扇区到备份缓冲 → 写 512 字节测试图案 → 读回逐字节比对 → 恢复原内容。
; 这样既能验证 WRITE(10)/CSW/重试链路,又不会把盘上的 FAT 文件系统弄坏。
.do_write:
    call usbd_parse_lba
    jc .usage
    mov eax, [usb_read_lba]
    cmp eax, [usbdisk_lba]
    jae .usage
    ; 1) 备份原扇区
    mov ecx, 1
    mov edi, USB_MSD_BACKUP
    call usb_scsi_read
    test eax, eax
    jnz .write_fail
    ; 2) 造测试图案:字节 i = i XOR 0xA5
    mov edi, USB_MSD_DATA
    xor edx, edx
.write_fill:
    mov eax, edx
    xor al, 0xA5
    mov [edi], al
    inc edi
    inc edx
    cmp edx, 512
    jb .write_fill
    ; 3) 写设备
    mov eax, [usb_read_lba]
    mov ecx, 1
    mov edi, USB_MSD_DATA
    call usb_scsi_write
    test eax, eax
    jnz .write_fail
    ; 4) 读回比对
    mov eax, [usb_read_lba]
    mov ecx, 1
    mov edi, USB_MSD_DATA
    call usb_scsi_read
    test eax, eax
    jnz .write_fail
    mov esi, USB_MSD_DATA
    xor edx, edx
.write_cmp:
    mov eax, edx
    xor al, 0xA5
    cmp [esi], al
    jne .write_bad
    inc esi
    inc edx
    cmp edx, 512
    jb .write_cmp
    ; 5) 恢复原内容(自测用的扇区不能真的改坏)
    mov eax, [usb_read_lba]
    mov ecx, 1
    mov edi, USB_MSD_BACKUP
    call usb_scsi_write
    test eax, eax
    jnz .write_fail
    mov esi, msg_usbd_wr_ok
    call term_print
    mov eax, [usb_read_lba]
    call term_print_dec
    mov al, 10
    call term_putc
    jmp .done
.write_bad:
    mov eax, [usb_read_lba]
    mov ecx, 1
    mov edi, USB_MSD_BACKUP
    call usb_scsi_write
    mov esi, msg_usbd_wr_bad
    call term_print
    jmp .done
.write_fail:
    mov esi, msg_usbd_wr_fail
    call term_print
    jmp .done

.read_fail:
    mov esi, msg_usbd_readfail
    call term_print
    jmp .done

.usage:
    mov esi, msg_usbd_usage
    call term_print
    jmp .done

.not_ready:
    mov esi, msg_usbd_notready
    call term_print
    jmp .done

.no_dev:
    mov esi, msg_usbd_nodev
    call term_print
    jmp .done
.done:
    popad
    ret

; ===========================================================================
;  usbdisk_on_unplug: U 盘被拔掉时的回调(usb2.asm 热插拔线程调)
; ===========================================================================
usbdisk_on_unplug:
    pushad
    mov byte [usbdisk_ready], 0
    cmp byte [usb_mounted], 0
    je .out
    call fat_state_restore
    call blkdev_select_ata
    mov byte [usb_mounted], 0
    call shell_reset_cwd
    mov esi, msg_usbd_unplugged
    call term_print
.out:
    popad
    ret

; ---------------------------------------------------------------------------
;  数据
; ---------------------------------------------------------------------------
msg_usbd_unplugged db 'usbdisk: removed, FAT device back to ATA FAT16', 10, 0
usbdisk_ready   db 0
usb_mounted     db 0                    ; 1 = FAT 驱动当前挂在 U 盘上
usb_bot_tag     dd 0x4B4B0001
usb_bot_status  db 0
usb_bot_residue dd 0
usb_bot_cdb     dd 0
usb_bot_dlen    dd 0
usb_bot_dbuf    dd 0
usb_bot_dir     dd 0
usb_bot_cdblen  dd 0

usbdisk_lba     dd 0
usbdisk_block   dd 512

usb_xfer_ep     dd 0
usb_xfer_toggle dd 0
usb_xfer_ntd    dd 0
usb_xfer_mps    dd 64
usb_xfer_ret    dd 0
usb_pkt_len     dd 0

usb_read_lba    dd 0
usb_read_cnt    dd 0
usb_read_buf    dd 0

usb_write_lba   dd 0
usb_write_cnt   dd 0
usb_write_buf   dd 0
usb_write_try   dd 0

usbd_i          dd 0
usbd_retry      dd 0
usbd_saved_arg  dd 0
usbd_ptr        dd 0
usbd_rest       dd 0
usbd_fld_ptr    dd 0
usbd_fld_len    dd 0
usbd_dump_buf   dd 0
usbd_dump_len   dd 0

usb_inq_vendor  times 9 db 0
usb_inq_product times 17 db 0
usb_inq_rev     times 5 db 0

usbd_hex_digits db '0123456789ABCDEF'

; 命令名
n_usbd_read     db 'read', 0
n_usbd_hexdump  db 'hexdump', 0
n_usbd_mbr      db 'mbr', 0
n_usbd_sense    db 'sense', 0
n_usbd_mount    db 'mount', 0
n_usbd_umount   db 'umount', 0
n_usbd_status   db 'status', 0
n_usbd_write    db 'write', 0

; 消息
msg_usbd_dev      db 'usbdisk: ', 0
msg_usbd_rev      db ' rev ', 0
msg_usbd_cap      db 'usbdisk: ', 0
msg_usbd_sect     db ' sectors x ', 0
msg_usbd_bytes    db ' B = ', 0
msg_usbd_kib      db ' KiB', 10, 0
msg_usbd_nodev    db 'usbdisk: no USB mass storage device (first USB device must be the disk)', 10, 0
msg_usbd_notready db 'usbdisk: device found but SCSI init failed (try `usbdisk sense`)', 10, 0
msg_usbd_readfail db 'usbdisk: read failed (see `usbdisk sense`)', 10, 0
msg_usbd_usage    db 'usbdisk: usage: usbdisk [mount | umount | status | read <lba> | hexdump <lba> | write <lba> | mbr | sense]', 10, 0
msg_usbd_state_ata    db 'usbdisk: FAT device: ATA (internal disk)', 10, 0
msg_usbd_state_usb    db 'usbdisk: FAT device: USB (USB mass storage)', 10, 0
msg_usbd_mounted      db 'usbdisk: mounted FAT', 0
msg_usbd_umounted     db 'usbdisk: unmounted, FAT device back to ATA FAT', 0
msg_usbd_at           db ' at LBA ', 0
msg_usbd_comma        db ', ', 0
msg_usbd_sectors      db ' sectors', 10, 0
msg_usbd_mountbusy    db 'usbdisk: already mounted (run `usbdisk umount` first)', 10, 0
msg_usbd_mountioerr   db 'usbdisk: mount failed: cannot read MBR/boot sector', 10, 0
msg_usbd_mountnofs    db 'usbdisk: mount failed: no FAT16/FAT32 filesystem found on the USB disk', 10, 0
msg_usbd_umountno     db 'usbdisk: not mounted (nothing to unmount)', 10, 0
msg_usbd_status_usb   db 'usbdisk: status: mounted FAT', 0
msg_usbd_status_ata   db 'usbdisk: status: not mounted (FAT device: ATA)', 10, 0
msg_usbd_wr_ok        db 'usbdisk: write test ok (backup/verify/restore, LBA ', 0
msg_usbd_wr_bad       db 'usbdisk: write test FAILED: readback mismatch (original restored)', 10, 0
msg_usbd_wr_fail      db 'usbdisk: write test failed (see `usbdisk sense`)', 10, 0
msg_hexdump_colon db ': ', 0
msg_hexdump_pad   db '   ', 0
msg_mbr_p         db 'p', 0
msg_mbr_type      db ': type=0x', 0
msg_mbr_start     db ' start=', 0
msg_mbr_secs      db ' sectors=', 0
msg_sense_hdr     db 'sense: rc=0x', 0
msg_sense_key     db ' key=0x', 0
msg_sense_asc     db ' asc=0x', 0
msg_sense_ascq    db ' ascq=0x', 0
