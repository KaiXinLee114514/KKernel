; ============================================================================
;  KKernel — ATA(IDE 硬盘)PIO 驱动(读 + 写)
;
;  为什么用 ATA 不用软驱:
;    软驱(FDC,0x3F0)要配 DMA、管马达、等转速,几百行还容易挂;
;    ATA 就是"往几个端口写参数 → 搬 0x1F0 的数据口",几十行就能跑。
;    我们的镜像本来就能当硬盘挂(-hda 那条测试路径),这条路现成的。
;
;  LBA28 读一个扇区:
;    1. 选盘 + LBA 高 4 位 → 0x1F6(0xE0 = 主盘 LBA 模式,0xF0 = 从盘)
;    2. 扇区数 → 0x1F2;LBA 低 24 位 → 0x1F3/0x1F4/0x1F5
;    3. 命令 → 0x1F7(读 = 0x20,写 = 0x30)
;    4. 等状态寄存器:BSY(bit7) 清掉、DRQ(bit3) 置起来
;    5. 从 0x1F0 搬 256 次 16 位 = 512 字节
;  写的时候每写一个端口要等约 400ns(读状态口四次就行),不然老硬盘会丢字节;
;  写完还要发 0xE7(FLUSH CACHE)让它把缓存落盘。
; ============================================================================

ATA_DATA    equ 0x1F0
ATA_SECCNT  equ 0x1F2
ATA_LBA_LO  equ 0x1F3
ATA_LBA_MID equ 0x1F4
ATA_LBA_HI  equ 0x1F5
ATA_DRIVE   equ 0x1F6
ATA_STATUS  equ 0x1F7
ATA_CMD     equ 0x1F7

ATA_SR_BSY  equ 0x80                    ; 忙
ATA_SR_DRQ  equ 0x08                    ; 数据就绪
ATA_SR_ERR  equ 0x01                    ; 出错

ATA_TIMEOUT equ 0x000FFFFF
; 一次命令最多读多少扇区:255 是硬件上限,但实测 QEMU 一次 255 扇区会有部分传输
; (ATA 规范允许驱动器只传一部分),于是后面的数据变成 0。16 扇区=8 KB 很稳。
ATA_MAX_CHUNK equ 16
; ★ VirtualBox 的 PIO 实现下,一次命令读多个扇区会在某个扇区上等不到 DRQ,
;   超时返回失败 —— 但**驱动器那边还挂着没传完的数据**,下一次读就把旧数据当新数据收,
;   目录项/簇链全读花,最后拿着野簇号去读盘、把内存写穿(实测:整个内核被写成一个
;   重复值 → 三连异常 → VirtualBox 报 Guru Meditation)。
;   每次只发一个扇区是"笨但正确"的:读写都稳,代价是字库(3449 扇区)加载慢几秒。
;   正经修法见 docs/known-issues.md:失败时先排空数据口再重试,或者按盘重试小分块。

; ---------------------------------------------------------------------------
;  ata_delay400:约 400ns(端口 I/O 本身就有延迟,读四次状态口足够)
; ---------------------------------------------------------------------------
ata_delay400:
    push eax
    push edx
    mov dx, ATA_STATUS
    in al, dx
    in al, dx
    in al, dx
    in al, dx
    pop edx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  ata_wait_ready:等 BSY 清;返回 CF=1 表示超时
; ---------------------------------------------------------------------------
ata_wait_ready:
    push eax
    push ecx
    push edx
    mov ecx, ATA_TIMEOUT
.loop:
    mov dx, ATA_STATUS
    in  al, dx
    test al, ATA_SR_BSY
    jz .ok
    loop .loop
    pop edx
    pop ecx
    pop eax
    stc
    ret
.ok:
    pop edx
    pop ecx
    pop eax
    clc
    ret

; ---------------------------------------------------------------------------
;  ata_wait_drq:等 DRQ(数据就绪);顺便看一眼 ERR。CF=1 = 出错/超时
; ---------------------------------------------------------------------------
ata_wait_drq:
    push eax
    push ecx
    push edx
    mov ecx, ATA_TIMEOUT
.loop:
    mov dx, ATA_STATUS
    in  al, dx
    test al, ATA_SR_ERR
    jnz .fail
    test al, ATA_SR_DRQ
    jnz .ok
    loop .loop
.fail:
    pop edx
    pop ecx
    pop eax
    stc
    ret
.ok:
    pop edx
    pop ecx
    pop eax
    clc
    ret

; ---------------------------------------------------------------------------
;  ata_setup_lba:按 [ata_lba] 选盘、填 LBA 三个端口
; ---------------------------------------------------------------------------
ata_setup_lba:
    push eax
    push ebx
    push edx
    mov eax, [ata_lba]

    mov ebx, eax
    shr ebx, 24
    and bl, 0x0F
    or  bl, 0xE0                        ; LBA 模式;bit4 = 主/从盘
    mov al, [ata_drive]
    and al, 1
    shl al, 4
    or  bl, al
    mov dx, ATA_DRIVE
    mov al, bl
    out dx, al
    call ata_delay400

    mov dx, ATA_SECCNT
    mov al, [ata_chunk]                 ; 本次读几个扇区(最多 255)
    out dx, al

    mov eax, [ata_lba]                  ; ★ 必须重新取:上面 `mov al, ...` 已经把 EAX 改花了
    mov ebx, eax                        ; LBA 低 24 位
    mov dx, ATA_LBA_LO
    mov al, bl
    out dx, al
    shr ebx, 8
    mov dx, ATA_LBA_MID
    mov al, bl
    out dx, al
    shr ebx, 8
    mov dx, ATA_LBA_HI
    mov al, bl
    out dx, al

    pop edx
    pop ebx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  ata_identify:IDENTIFY DEVICE(0xEC)读盘参数,总扇区数存 [ata_sectors]
;  返回 eax = 0 成功 / -1 失败(没盘、ATAPI 或不支持)。只改 eax。
;
;  为什么要它:swap 区头在 LBA 32768,16 MB 的测试镜像只有 32768 个扇区,
;  不先问一句"盘多大"就直接读就是越界 —— QEMU 返回零糊弄过去,VirtualBox
;  会报 "disk read error"。所以先 IDENTIFY,再让 swap_init 判断容量。
; ---------------------------------------------------------------------------
ata_identify:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov dword [ata_sectors], 0
    ; ---- 选盘(LBA 模式;IDENTIFY 不看 LBA,只要主/从选对)----
    mov al, [ata_drive]
    and al, 1
    shl al, 4
    or  al, 0xA0
    mov dx, ATA_DRIVE
    out dx, al
    call ata_delay400
    ; ---- 参数清零 ----
    xor eax, eax
    mov dx, ATA_SECCNT
    out dx, al
    mov dx, ATA_LBA_LO
    out dx, al
    mov dx, ATA_LBA_MID
    out dx, al
    mov dx, ATA_LBA_HI
    out dx, al
    ; ---- 命令 0xEC:IDENTIFY DEVICE ----
    mov dx, ATA_CMD
    mov al, 0xEC
    out dx, al
    ; ---- 状态 0x00 / 0xFF = 这个位置没有设备(浮动总线)----
    mov dx, ATA_STATUS
    in al, dx
    cmp al, 0
    je .fail
    cmp al, 0xFF
    je .fail
    ; ---- 等 BSY 清 ----
    call ata_wait_ready
    jc .fail
    ; ---- 不是 ATA 的话 LBA_MID/HI 会被塞魔法值(ATAPI / SATA)----
    mov dx, ATA_LBA_MID
    in al, dx
    test al, al
    jnz .fail
    mov dx, ATA_LBA_HI
    in al, dx
    test al, al
    jnz .fail
    ; ---- 等 DRQ,搬 256 个 word = 512 字节 ----
    call ata_wait_drq
    jc .fail
    mov edi, ata_ident_buf
    mov ecx, 256
    mov dx, ATA_DATA
    cld
    rep insw
    ; ---- word 49 bit9:LBA 寻址支持?(不支持的老盘不谈容量)----
    test word [ata_ident_buf + 98], 0x0200
    jz .fail
    ; ---- word 60/61 = LBA28 总扇区数(低字在前)----
    mov eax, [ata_ident_buf + 120]
    test eax, eax
    jz .fail
    mov [ata_sectors], eax
    xor eax, eax
    jmp .out
.fail:
    mov dword [ata_sectors], 0
    mov eax, -1
.out:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret


; ---------------------------------------------------------------------------
;  ata_read_sectors:eax = LBA,ecx = 扇区数,edi = 目标地址;返回 eax = 0 成功 / -1 失败
;
;  ★ 调用者的寄存器(ebx/ecx/edx/esi/edi/ebp)必须原样保留,只有 eax 是返回值。
;    (踩过:原先 pushad 只护住安全闸那一段,popad 之后 `mov dx, ATA_CMD/DATA`
;     把 EDX 改成 0x1F0 就返回;FAT 层拿 EDX 存"扇区内字节偏移",分配器于是从
;     扇区中间开始扫零,簇号全场乱飞 —— 一路写到 8192 号簇,把根目录写成了 FAT 表)
; ---------------------------------------------------------------------------
ata_read_sectors:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp
    ; ---- 记一笔:谁(返回地址)用哪个 LBA/几个扇区/读到哪 ----
    ; 崩溃之后转储虚拟机内存、照 ATA_LOG_ADDR 一看就知道是谁把内存写穿的
    mov ebx, [ata_log_pos]
    and ebx, ATA_LOG_N - 1
    shl ebx, 4
    add ebx, ata_log
    mov [ebx + 0], eax                  ; LBA
    mov [ebx + 4], ecx                  ; 扇区数
    mov [ebx + 8], edi                  ; 目标
    mov edx, [esp + 24]                 ; 返回地址 = 调用者(6 个 push 之后)
    mov [ebx + 12], edx
    inc dword [ata_log_pos]
    ; ---- 安全闸:扇区数 > 255 或者目标地址不在已映射的低端内存里,一律拒绝 ----
    ; (踩过:一个算错的 LBA/长度把整块内存写成同一个值,内核自己把自己埋了)
    test ecx, ecx                       ; 0 个扇区?直接拒绝
    jz .fail
    cmp ecx, 0x100000                   ; 一次读 512 MB?肯定不对
    ja .fail
    cmp edi, 0x10000                    ; 目标必须在已映射的低端内存里
    jb .fail
    mov edx, ecx                        ; 而且"目标 + 长度"不能越过恒等映射(运行时 ident_limit)
    shl edx, 9
    jc .fail
    add edx, edi
    jc .fail
    cmp edx, [ident_limit]
    ja .fail
    mov [ata_lba], eax
    mov [ata_buf], edi
    mov [ata_left], ecx
.loop:
    cmp dword [ata_left], 0
    je .done
    ; 本次读几块:最多 ATA_MAX_CHUNK 扇区(ATA 的 SECCNT 是 8 位,0 表示 256)
    mov eax, [ata_left]
    cmp eax, ATA_MAX_CHUNK
    jbe .use_it
    mov eax, ATA_MAX_CHUNK
.use_it:
    mov [ata_chunk], al
    call ata_setup_lba
    mov dx, ATA_CMD
    mov al, 0x20                        ; READ SECTORS
    out dx, al
    ; ★ 关键:多扇区 PIO **不能一口气读完** —— 驱动器每传完一个扇区会重新拉 DRQ,
    ;   必须每个扇区等一次 DRQ 再搬 256 个 16 位。整块硬读的话只有头一个扇区是对的,
    ;   后面的数据是零/旧数据(这个坑踩了一轮)。
    mov edi, [ata_buf]
    movzx ebp, byte [ata_chunk]
.sector:
    call ata_wait_drq
    jc .fail
    mov ecx, 256
    mov dx, ATA_DATA
    rep insw
    dec ebp
    jnz .sector
    movzx eax, byte [ata_chunk]
    add [ata_lba], eax
    imul eax, 512
    add [ata_buf], eax
    movzx eax, byte [ata_chunk]
    sub [ata_left], eax
    jmp .loop
.done:
    xor eax, eax
    jmp .out
.fail:
    mov eax, -1                         ; 调用方必须检查:失败时目标缓冲里是旧内容
.out:
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  ata_write_sectors:eax = LBA,ecx = 扇区数,esi = 源地址;返回 eax = 0 / -1
;  注意:写盘是真写 —— 拿镜像的副本试,别拿唯一的镜像练手
;  寄存器约定同 ata_read_sectors:调用者的寄存器别动,只有 eax 是返回值。
; ---------------------------------------------------------------------------
ata_write_sectors:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp
    mov [ata_lba], eax
    mov [ata_src], esi
    mov [ata_left], ecx
.loop:
    cmp dword [ata_left], 0
    je .flush
    mov eax, [ata_left]
    cmp eax, ATA_MAX_CHUNK
    jbe .use_it_w
    mov eax, ATA_MAX_CHUNK
.use_it_w:
    mov [ata_chunk], al
    call ata_setup_lba
    mov dx, ATA_CMD
    mov al, 0x30                        ; WRITE SECTORS
    out dx, al
    ; 写也一样:每个扇区等一次 DRQ(而且每写一个扇区要留 400ns)
    mov esi, [ata_src]
    movzx ebp, byte [ata_chunk]
.sector_w:
    call ata_wait_drq
    jc .fail
    mov ecx, 256
    mov dx, ATA_DATA
    rep outsw
    call ata_delay400
    dec ebp
    jnz .sector_w
    movzx eax, byte [ata_chunk]
    add [ata_lba], eax
    imul eax, 512
    add [ata_src], eax
    movzx eax, byte [ata_chunk]
    sub [ata_left], eax
    jmp .loop
.flush:
    mov dx, ATA_CMD
    mov al, 0xE7                        ; FLUSH CACHE
    out dx, al
    call ata_wait_ready
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
;  ata_write_sectors_nf:和 ata_write_sectors 一样,但最后**不发 FLUSH CACHE**。
;    swap 内容不需要持久化(重启就丢,正是 swap 的语义),QEMU 端的 FLUSH
;    每次都会 fsync 镜像,几百次换出会把测试拖到几分钟 —— 所以 swap 用这个。
;    注意:只能给"丢了也无所谓"的数据(swap 槽)用。
; ---------------------------------------------------------------------------
ata_write_sectors_nf:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp
    mov [ata_lba], eax
    mov [ata_src], esi
    mov [ata_left], ecx
.loop:
    cmp dword [ata_left], 0
    je .done
    mov eax, [ata_left]
    cmp eax, ATA_MAX_CHUNK
    jbe .use_it_w
    mov eax, ATA_MAX_CHUNK
.use_it_w:
    mov [ata_chunk], al
    call ata_setup_lba
    mov dx, ATA_CMD
    mov al, 0x30                        ; WRITE SECTORS
    out dx, al
    mov esi, [ata_src]
    movzx ebp, byte [ata_chunk]
.sector_w:
    call ata_wait_drq
    jc .fail
    mov ecx, 256
    mov dx, ATA_DATA
    rep outsw
    call ata_delay400
    dec ebp
    jnz .sector_w
    movzx eax, byte [ata_chunk]
    add [ata_lba], eax
    imul eax, 512
    add [ata_src], eax
    movzx eax, byte [ata_chunk]
    sub [ata_left], eax
    jmp .loop
.done:
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

; ---------------------------------------------------------------- 变量
ata_lba    dd 0
ata_buf    dd 0
ata_src    dd 0
ata_left   dd 0
ata_chunk  db 1
ata_ident_buf times 512 db 0         ; IDENTIFY DEVICE 的 256 个 word
ata_sectors   dd 0                   ; 当前盘总扇区数(LBA28;0 = 未知/没盘)
; ATA 调用记录(环形,64 条 × 16 字节):LBA / 扇区数 / 目标 / 调用者返回地址
ATA_LOG_N  equ 64
ata_log    times (ATA_LOG_N * 16) db 0
ata_log_pos dd 0
ata_drive  db 0x80                      ; 0x80 = 主盘,0x81 = 从盘(fontdisk 会按 BOOTINFO 设)
