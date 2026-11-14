; ============================================================================
;  kernel/kifs.asm — KiFS 只读驱动(Phase B0)
;
;  KiFS 是 KKernel 自己的文件系统(设计文档在 kifs 仓库 docs/kifs.md,
;  宿主工具 tools/mkifs.py 生成/检查镜像、fsck 当标准答案)。Phase B0 只做
;  **内核侧只读挂载**,命令组:
;
;      kifs info              看 superblock:magic/version/块大小/总块数/
;                             root_oid/free_blocks/卷标
;      kifs ls [path]         列目录(省略路径 = 根目录 /)
;      kifs cat <path>        打印文件内容(内联 / 单段多块 extent)
;      kifs stat <path>       oid / 类型 / 权限 / 大小 / 块数 / 内联长度 /
;                             extent / 父 oid
;
;  为什么固定 LBA 而不是自动探测:Phase B0 是"先让内核能读一致格式"的
;  最小闭环,分区位置和宿主测试镜像焊死(22528 = 11 MiB),省掉挂载表、
;  分区表解析和 VFS 层;Phase B1 再谈 /MNT/KIFS。**没挂 VFS,只读**,
;  和 FAT16 命令各读各的分区,互不影响。
;
;  静默原则:普通镜像 / 软盘 / FAT 盘上这个位置没有 KiFS(或校验不过),
;  kifs_init 一声不吭地返回,kifs_ok=0;现有测试一个都不受影响。
;
;  内存(0x3C3000-0x3C5FFF,与 kmain.asm 顶部布局表同步;0x3C2000 之后
;  到 0x3C2FFF 是 usbdisk 的 4 KiB 数据缓冲,别越界):
;      0x3C3000  4 KiB 块缓冲(ATA 读盘目标)
;      0x3C4000  4 KiB 目录内容缓冲
;      0x3C5000  128 B 当前 record
;      0x3C5100  256 B 路径缓冲
;      全局变量在下面数据段(内核映像里,可写)
;
;  磁盘布局(全部小端;权威实现:宿主 tools/mkifs.py):
;    superblock(512 B;主副本在**分区块 1** —— 块 0 是引导块留空,
;      设计文档写的是"块 0",但权威实现 mkifs.py 是块 1,以 py 为准):
;      magic 'KIFS'@0(0x5346494B), version 0x00010000@4, block_size 4096@8,
;      total_blocks@12, data_start@20, data_next@24, meta_next@28,
;      record_start@40, record_count@44, root_oid@48, free_blocks@52,
;      flags@56, uuid@60(16 B), label@76(32 B),
;      checksum = crc32(前 108 字节)@108,其余补 0
;      备份副本在块 2 和最后一块(本驱动只读块 1,不信备份)
;    record 128 B(record 表从块 record_start 起,第 oid 个在 +oid*128):
;      oid@0, type@4(1=文件 2=目录), flags@5, perm@6,
;      size@8, blocks@12, parent@16, ctime@20, mtime@24, kw_index@28,
;      n_ext@32, inline_len@33, inline_off@34,
;      extents@36(3 × 12 B:start u32 / count u16 / pad u16),
;      ext_index@72, n_ext_total@76, next_free_oid@80, owner@84(16 B)
;      内联数据从 inline_off(36)起,最多 92 B;内联时 extent 区不能读
;      —— v0 宿主工具把 36..128 整段留给内联数据,owner/extent 都被盖住
;    目录内容 = 一串目录项:oid u32@0, type u8@4, name_len u8@5,
;      entry_len u16@6,名字 UTF-8@8,entry_len 4 对齐,按名字字节序排
;    perm 16 位:bit0-2 owner rwx,bit3-5 group,bit6-8 other,
;      bit9 hide,bit10 ro,bit11 iolock(只读驱动:只展示,不校验)
;
;  只读:本文件没有一个 ata_write_sectors 调用(故意的)。
; ============================================================================

; ---------------------------------------------------------------------------
;  常量 / 固定缓冲
; ---------------------------------------------------------------------------
KIFS_PART_LBA     equ 22528              ; KiFS 分区固定起点(11 MiB / 8 = LBA 22528)
KIFS_MAGIC        equ 0x5346494B         ; dword 'KIFS'(小端)
KIFS_VERSION      equ 0x00010000
KIFS_BLOCK_SIZE   equ 4096
KIFS_BLOCK_SECTORS equ KIFS_BLOCK_SIZE / 512
KIFS_INLINE_OFF   equ 36                 ; v0 宿主工具固定内联数据偏移
KIFS_INLINE_MAX   equ 92
KIFS_REC_SIZE     equ 128
KIFS_DIR_MAX      equ 4096               ; Phase B0:目录内容最大 4 KiB(单块)
KIFS_CAT_MAX      equ 61440              ; Phase B0:cat 上限 60 KiB(流式,不落大缓冲)

KIFS_IO_BUF       equ 0x3C3000           ; 4 KiB 块缓冲
KIFS_DIR_BUF      equ 0x3C4000           ; 4 KiB 目录内容缓冲
KIFS_REC_BUF      equ 0x3C5000           ; 128 B 当前 record
KIFS_PATH_BUF     equ 0x3C5100           ; 256 B 路径缓冲

; kifs_err 错误码(命令层翻译成人话)
KIFS_ERR_NONE     equ 0
KIFS_ERR_NOENT    equ 1                  ; 路径不存在
KIFS_ERR_NOTDIR   equ 2                  ; 不是目录
KIFS_ERR_NOTFILE  equ 3                  ; 不是文件
KIFS_ERR_DIRBIG   equ 4                  ; 目录内容超出 4 KiB
KIFS_ERR_IO       equ 5                  ; 读盘失败

; ===========================================================================
;  kifs_crc32:esi = 数据,ecx = 长度 → eax = zlib crc32
;  和宿主 Python 的 zlib.crc32 逐位一致(多项式 0xEDB88320,初值/终值取反)
; ===========================================================================
kifs_crc32:
    push ebx
    push edx
    push ecx
    push esi
    mov eax, 0xFFFFFFFF
.next_byte:
    test ecx, ecx
    jz .done
    movzx edx, byte [esi]
    xor al, dl
    mov ebx, 8
.next_bit:
    shr eax, 1
    jnc .no_xor
    xor eax, 0xEDB88320
.no_xor:
    dec ebx
    jnz .next_bit
    inc esi
    dec ecx
    jmp .next_byte
.done:
    not eax
    pop esi
    pop ecx
    pop edx
    pop ebx
    ret

; ===========================================================================
;  kifs_read_block:eax = 块号 → 读进 KIFS_IO_BUF;返回 eax = 0 / -1
;  块 LBA = 22528 + 块号 × 8(4096 B = 8 扇区)
; ===========================================================================
kifs_read_block:
    pushad
    shl eax, 3                            ; 块号 → 扇区偏移
    add eax, KIFS_PART_LBA
    mov ecx, KIFS_BLOCK_SECTORS
    mov edi, KIFS_IO_BUF
    call ata_read_sectors                 ; eax=0 成功 / -1 失败,其它寄存器不动
    mov [kifs_rb_ret], eax
    popad
    mov eax, [kifs_rb_ret]
    ret

; ===========================================================================
;  kifs_read_record:eax = oid, edi = 128 B 目标 → eax = 0 / -1
;  oid 合法范围 1..record_count-1;record 在块 record_start + oid/32,
;  块内偏移 (oid & 31) * 128
;  (保留寄存器;内部用 KIFS_IO_BUF 做块缓冲,调用者别同时指望它的内容)
; ===========================================================================
kifs_read_record:
    pushad
    mov [kifs_rr_oid], eax
    mov [kifs_rr_dst], edi
    cmp eax, [kifs_record_count]
    jae .fail
    test eax, eax
    jz .fail
    ; 块号 = record_start + oid/32
    mov edx, eax
    shr edx, 5
    add edx, [kifs_record_start]
    mov eax, edx
    call kifs_read_block
    test eax, eax
    jnz .fail
    ; 块内偏移 = (oid & 31) * 128
    mov eax, [kifs_rr_oid]
    and eax, 31
    shl eax, 7
    add eax, KIFS_IO_BUF
    mov esi, eax
    mov edi, [kifs_rr_dst]
    mov ecx, KIFS_REC_SIZE
    cld
    rep movsb
    mov dword [kifs_rr_ret], 0
    jmp .out
.fail:
    mov dword [kifs_rr_ret], -1
.out:
    popad
    mov eax, [kifs_rr_ret]
    ret

; ===========================================================================
;  kifs_read_content:esi = record 指针,edi = 目标,ecx = 最多读多少
;   → eax = 实际读到的字节数 / -1
;  内联:从 inline_off 拷 min(inline_len, max) 字节
;  多块:按 extent 一段段读块、逐块拷贝,总共不超过 min(size, max)
;  (目录内容也走这里;Phase B0 目录 ≤ 4 KiB,所以最多一块)
; ===========================================================================
kifs_read_content:
    pushad
    mov [kifs_rc_rec], esi
    mov [kifs_rc_dst], edi
    mov [kifs_rc_max], ecx
    mov dword [kifs_rc_written], 0
    ; ---- 内联? ----
    movzx eax, byte [esi + 33]            ; inline_len
    test eax, eax
    jz .extents
    ; 内联边界自洽:inline_off + inline_len 不能越过 record
    movzx edx, word [esi + 34]            ; inline_off
    lea ebx, [eax + edx]
    cmp ebx, KIFS_REC_SIZE
    ja .fail
    ; n = min(inline_len, max)
    cmp eax, [kifs_rc_max]
    jbe .inline_n_ok
    mov eax, [kifs_rc_max]
.inline_n_ok:
    mov [kifs_rc_n], eax
    mov ecx, eax
    mov esi, [kifs_rc_rec]
    movzx edx, word [esi + 34]
    add esi, edx
    mov edi, [kifs_rc_dst]
    cld
    rep movsb
    mov eax, [kifs_rc_n]
    jmp .out
.extents:
    ; 目标读取长度 = min(size, max)
    mov esi, [kifs_rc_rec]
    mov eax, [esi + 8]                    ; size
    cmp eax, [kifs_rc_max]
    jbe .size_ok
    mov eax, [kifs_rc_max]
.size_ok:
    mov [kifs_rc_left], eax
    movzx eax, byte [esi + 32]            ; n_ext
    mov [kifs_rc_ne], eax
    mov dword [kifs_rc_exti], 0
    mov eax, [kifs_rc_dst]
    mov [kifs_rc_cur], eax
.ext_loop:
    cmp dword [kifs_rc_left], 0
    je .ext_done
    cmp dword [kifs_rc_ne], 0
    je .ext_done
    ; extent[i] 在 record + 36 + i*12
    mov eax, [kifs_rc_exti]
    imul eax, eax, 12
    mov esi, [kifs_rc_rec]
    lea esi, [esi + eax + 36]
    mov eax, [esi]                        ; start 块
    mov [kifs_rc_blk], eax
    movzx eax, word [esi + 4]             ; 块数
    mov [kifs_rc_bcnt], eax
.blk_loop:
    cmp dword [kifs_rc_left], 0
    je .ext_done
    cmp dword [kifs_rc_bcnt], 0
    je .next_ext
    mov eax, [kifs_rc_blk]
    call kifs_read_block
    test eax, eax
    jnz .fail
    mov ecx, [kifs_rc_left]
    cmp ecx, KIFS_BLOCK_SIZE
    jbe .chunk_ok
    mov ecx, KIFS_BLOCK_SIZE
.chunk_ok:
    mov [kifs_rc_n], ecx
    mov esi, KIFS_IO_BUF
    mov edi, [kifs_rc_cur]
    cld
    rep movsb
    mov eax, [kifs_rc_n]
    add [kifs_rc_cur], eax
    sub [kifs_rc_left], eax
    add [kifs_rc_written], eax
    inc dword [kifs_rc_blk]
    dec dword [kifs_rc_bcnt]
    jmp .blk_loop
.next_ext:
    inc dword [kifs_rc_exti]
    dec dword [kifs_rc_ne]
    jmp .ext_loop
.ext_done:
    mov eax, [kifs_rc_written]
    jmp .out
.fail:
    mov eax, -1
.out:
    mov [kifs_rc_ret], eax
    popad
    mov eax, [kifs_rc_ret]
    ret

; ===========================================================================
;  kifs_resolve:esi = 路径(以 0 结尾,绝对/相对都行,"/" = 根)
;   → eax = oid(0 = 失败,kifs_err 里是原因)
;  从 root_oid 开始逐段走目录;每段 = 字节精确比较(区分大小写)
; ===========================================================================
kifs_resolve:
    pushad
    mov [kifs_rs_path], esi
    mov dword [kifs_err], KIFS_ERR_NONE
    mov eax, [kifs_root_oid]
    mov [kifs_rs_oid], eax
.seg_loop:
    ; 跳过 '/'
    mov esi, [kifs_rs_path]
.slash:
    cmp byte [esi], '/'
    jne .seg_start
    inc esi
    jmp .slash
.seg_start:
    cmp byte [esi], 0
    je .ok                                ; 路径走完了
    ; 本段 [start, end)
    mov [kifs_rs_comp], esi
    mov edi, esi
.scan:
    mov al, [edi]
    test al, al
    jz .scan_end
    cmp al, '/'
    je .scan_end
    inc edi
    jmp .scan
.scan_end:
    mov ecx, edi
    sub ecx, esi
    mov [kifs_rs_complen], ecx
    mov [kifs_rs_path], edi               ; 下一轮从这里继续
    ; ---- 读当前 record:必须是目录且内容 ≤ 4 KiB ----
    mov eax, [kifs_rs_oid]
    mov edi, KIFS_REC_BUF
    call kifs_read_record
    test eax, eax
    jnz .err_noent
    cmp byte [KIFS_REC_BUF + 4], 2        ; TYPE_DIR
    jne .err_notdir
    mov eax, [KIFS_REC_BUF + 8]           ; 目录内容大小
    cmp eax, KIFS_DIR_MAX
    ja .err_notdir
    mov esi, KIFS_REC_BUF
    mov edi, KIFS_DIR_BUF
    mov ecx, KIFS_DIR_MAX
    call kifs_read_content
    test eax, eax
    js .err_noent
    mov [kifs_rs_dirsize], eax
    ; ---- 线性扫目录项 ----
    mov dword [kifs_rs_pos], 0
.entry_loop:
    mov edx, [kifs_rs_pos]
    mov eax, [kifs_rs_dirsize]
    sub eax, edx
    cmp eax, 8                            ; 目录项头 8 B
    jb .err_noent
    lea esi, [KIFS_DIR_BUF + edx]
    movzx ecx, word [esi + 6]             ; entry_len
    test ecx, ecx
    jz .err_noent
    movzx eax, byte [esi + 5]             ; name_len
    cmp eax, [kifs_rs_complen]
    jne .entry_next
    ; 名字逐个字节比
    lea esi, [esi + 8]
    mov edi, [kifs_rs_comp]
    mov ecx, [kifs_rs_complen]
    cld
    repe cmpsb
    jne .entry_next
    ; 命中:oid 进状态,继续下一段
    mov edx, [kifs_rs_pos]
    mov eax, [KIFS_DIR_BUF + edx]         ; 子项 oid
    mov [kifs_rs_oid], eax
    jmp .seg_loop
.entry_next:
    mov edx, [kifs_rs_pos]
    movzx ecx, word [KIFS_DIR_BUF + edx + 6]
    add edx, ecx
    mov [kifs_rs_pos], edx
    jmp .entry_loop
.err_noent:
    mov dword [kifs_err], KIFS_ERR_NOENT
    mov dword [kifs_rs_ret], 0
    jmp .out
.err_notdir:
    mov dword [kifs_err], KIFS_ERR_NOTDIR
    mov dword [kifs_rs_ret], 0
    jmp .out
.ok:
    mov eax, [kifs_rs_oid]
    mov [kifs_rs_ret], eax
.out:
    popad
    mov eax, [kifs_rs_ret]
    ret

; ===========================================================================
;  kifs_print_perm:eax = 16 位 perm → 打印 9 字符 rwxrwxrwx + 3 位标志数字
;  (hide/ro/iolock 只展示,不强制 —— 只读驱动不校验权限)
; ===========================================================================
kifs_print_perm:
    pushad
    mov [kifs_perm_tmp], eax
    xor ebx, ebx                          ; 组内位移 0/3/6
.group:
    cmp ebx, 9
    jae .flags
    mov eax, [kifs_perm_tmp]
    mov ecx, ebx
    shr eax, cl
    mov ecx, eax
    ; r = bit0
    and ecx, 1
    mov al, '-'
    test ecx, ecx
    jz .put_r
    mov al, 'r'
.put_r:
    call term_putc
    mov eax, [kifs_perm_tmp]
    mov ecx, ebx
    shr eax, cl
    mov ecx, eax
    ; w = bit1
    and ecx, 2
    mov al, '-'
    test ecx, ecx
    jz .put_w
    mov al, 'w'
.put_w:
    call term_putc
    mov eax, [kifs_perm_tmp]
    mov ecx, ebx
    shr eax, cl
    mov ecx, eax
    ; x = bit2
    and ecx, 4
    mov al, '-'
    test ecx, ecx
    jz .put_x
    mov al, 'x'
.put_x:
    call term_putc
    add ebx, 3
    jmp .group
.flags:
    mov ebx, 9                            ; hide / ro / iolock
.flag_loop:
    mov eax, [kifs_perm_tmp]
    mov ecx, ebx
    shr eax, cl
    and al, 1
    add al, '0'
    call term_putc
    inc ebx
    cmp ebx, 12
    jb .flag_loop
    popad
    ret

; ===========================================================================
;  kifs_print_owner:esi = record 指针 → 打印 owner(16 B,遇 0 停)
;  注意:v0 宿主工具在**内联** record 里把 36..128 全拿去放内联数据了,
;  owner@84 会被数据覆盖 —— inline_len > 48 时干脆不打(打了是乱码);
;  非内联 record 的 owner 字段是好的。
; ===========================================================================
kifs_print_owner:
    pushad
    cmp byte [esi + 33], 0                ; inline_len
    je .print
    cmp byte [esi + 33], 48
    ja .out                               ; owner 区被内联数据盖住,不显示
.print:
    lea esi, [esi + 84]
    xor ebx, ebx
.loop:
    cmp ebx, 16
    jae .out
    mov al, [esi + ebx]
    test al, al
    jz .out
    call term_putc
    inc ebx
    jmp .loop
.out:
    popad
    ret

; ===========================================================================
;  kifs_copy_path:把 [usbd_rest] 的路径参数拷进 KIFS_PATH_BUF
;   去尾部空格,最多 255 字节,返回 eax = 长度(0 = 没给路径)
; ===========================================================================
kifs_copy_path:
    pushad
    mov esi, [usbd_rest]
    mov edi, KIFS_PATH_BUF
    xor ecx, ecx
.copy:
    cmp ecx, 255
    jae .trim
    mov al, [esi + ecx]
    test al, al
    jz .trim
    mov [edi + ecx], al
    inc ecx
    jmp .copy
.trim:
    test ecx, ecx
    jz .store
    cmp byte [edi + ecx - 1], ' '
    jne .store
    dec ecx
    jmp .trim
.store:
    mov byte [edi + ecx], 0
    mov [kifs_path_len], ecx
    popad
    mov eax, [kifs_path_len]
    ret

; ===========================================================================
;  kifs_path_default:空路径 → 根目录 "/"
; ===========================================================================
kifs_path_default:
    cmp dword [kifs_path_len], 0
    jne .ret
    mov byte [KIFS_PATH_BUF], '/'
    mov byte [KIFS_PATH_BUF + 1], 0
    mov dword [kifs_path_len], 1
.ret:
    ret

; ===========================================================================
;  kifs_print_err:按 kifs_err 打印一句红色错误
; ===========================================================================
kifs_print_err:
    pushad
    mov al, COL_ERR
    call term_set_color
    mov eax, [kifs_err]
    cmp eax, KIFS_ERR_NOTDIR
    jne .e2
    mov esi, msg_kifs_notdir
    jmp .emit
.e2:
    cmp eax, KIFS_ERR_NOTFILE
    jne .e3
    mov esi, msg_kifs_notfile
    jmp .emit
.e3:
    cmp eax, KIFS_ERR_DIRBIG
    jne .e4
    mov esi, msg_kifs_dirbig
    jmp .emit
.e4:
    cmp eax, KIFS_ERR_IO
    jne .enoent
    mov esi, msg_kifs_ioerr
    jmp .emit
.enoent:
    mov esi, msg_kifs_notfound
.emit:
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    popad
    ret

; ===========================================================================
;  kifs_print_usage:用法错误(红色)
; ===========================================================================
kifs_print_usage:
    pushad
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_kifs_usage
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    popad
    ret

; ===========================================================================
;  kifs_init:探测 + 校验 superblock。成功 kifs_ok=1,失败**什么都不打印**。
;  普通镜像里这块区域是 0,FAT16/FAT32/软盘测试完全不感知。
; ===========================================================================
kifs_init:
    pushad
    mov byte [kifs_ok], 0
    ; ---- 读 superblock(主副本在分区块 1;块 0 是引导块留空)----
    mov eax, 1
    call kifs_read_block
    test eax, eax
    jnz .out
    ; ---- 静态字段 ----
    cmp dword [KIFS_IO_BUF + 0], KIFS_MAGIC
    jne .out
    cmp dword [KIFS_IO_BUF + 4], KIFS_VERSION
    jne .out
    cmp dword [KIFS_IO_BUF + 8], KIFS_BLOCK_SIZE
    jne .out
    ; ---- superblock checksum:crc32(前 108 字节) == @108 ----
    mov esi, KIFS_IO_BUF
    mov ecx, 108
    call kifs_crc32
    cmp eax, [KIFS_IO_BUF + 108]
    jne .out
    ; ---- 布局自洽(手算,防呆;镜像坏了就别当 KiFS)----
    mov eax, [KIFS_IO_BUF + 12]           ; total_blocks
    cmp eax, 8
    jb .out
    mov ebx, [KIFS_IO_BUF + 40]           ; record_start
    cmp ebx, eax
    jae .out
    mov ecx, [KIFS_IO_BUF + 44]           ; record_count
    cmp ecx, 2
    jb .out
    cmp ecx, 4096
    ja .out
    ; record 表占块数 = ceil(record_count / 32);record 表必须落在镜像里
    lea edx, [ecx + 31]
    shr edx, 5
    add edx, ebx
    cmp edx, eax
    ja .out
    ; root_oid 必须在 record 表范围内
    mov edx, [KIFS_IO_BUF + 48]
    test edx, edx
    jz .out
    cmp edx, ecx
    jae .out
    ; ---- 存全局 ----
    mov eax, [KIFS_IO_BUF + 4]
    mov [kifs_version], eax
    mov eax, [KIFS_IO_BUF + 8]
    mov [kifs_block_size], eax
    mov eax, [KIFS_IO_BUF + 12]
    mov [kifs_total_blocks], eax
    mov eax, [KIFS_IO_BUF + 40]
    mov [kifs_record_start], eax
    mov eax, [KIFS_IO_BUF + 44]
    mov [kifs_record_count], eax
    mov eax, [KIFS_IO_BUF + 48]
    mov [kifs_root_oid], eax
    mov eax, [KIFS_IO_BUF + 52]
    mov [kifs_free_blocks], eax
    mov eax, [KIFS_IO_BUF + 56]
    mov [kifs_flags], eax
    ; 卷标 32 B(强制补一个 0 方便当字符串打)
    mov esi, KIFS_IO_BUF + 76
    mov edi, kifs_label
    mov ecx, 32
    cld
    rep movsb
    mov byte [kifs_label + 32], 0
    ; ---- 根 record 必须是目录,否则也不算 KiFS ----
    mov eax, [kifs_root_oid]
    mov edi, KIFS_REC_BUF
    call kifs_read_record
    test eax, eax
    jnz .out
    cmp byte [KIFS_REC_BUF + 4], 2
    jne .out
    mov byte [kifs_ok], 1
.out:
    popad
    ret

; ===========================================================================
;  cmd_kifs — shell 命令入口
;    kifs info / kifs ls [path] / kifs cat <path> / kifs stat <path>
;  没镜像时只打一句提示(规格要求的固定文案),不碰 FAT 状态。
; ===========================================================================
cmd_kifs:
    pushad
    ; 第一个词 = 子命令,后面 = 路径参数
    mov esi, [cmd_arg]
    call usbd_first_word                  ; esi/ecx = 词;[usbd_rest] = 词后的参数
    mov [kifs_word_ptr], esi
    mov [kifs_word_len], ecx
    call kifs_copy_path                   ; 路径 → KIFS_PATH_BUF(去尾空格)
    ; ---- 没镜像? ----
    cmp byte [kifs_ok], 0
    jne .have_image
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_kifs_noimg
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    jmp .done
.have_image:
    ; ---- 没子命令 = info ----
    cmp dword [kifs_word_len], 0
    je .do_info
    mov esi, [kifs_word_ptr]
    mov ecx, [kifs_word_len]
    mov edx, n_kifs_info
    call str_eq
    test eax, eax
    jnz .do_info
    mov esi, [kifs_word_ptr]
    mov ecx, [kifs_word_len]
    mov edx, n_kifs_ls
    call str_eq
    test eax, eax
    jnz .do_ls
    mov esi, [kifs_word_ptr]
    mov ecx, [kifs_word_len]
    mov edx, n_kifs_cat
    call str_eq
    test eax, eax
    jnz .do_cat
    mov esi, [kifs_word_ptr]
    mov ecx, [kifs_word_len]
    mov edx, n_kifs_stat
    call str_eq
    test eax, eax
    jnz .do_stat
    call kifs_print_usage
    jmp .done

; ---------------------------------------------------------------------------
;  kifs info
; ---------------------------------------------------------------------------
.do_info:
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_kifs_info_head
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    ; magic + version + block_size
    mov esi, msg_kifs_magic
    call term_print
    mov eax, [kifs_version]
    call term_print_hex
    mov esi, msg_kifs_blocksize
    call term_print
    mov eax, [kifs_block_size]
    call term_print_dec
    mov al, 10
    call term_putc
    ; total_blocks / root_oid / free_blocks
    mov esi, msg_kifs_total
    call term_print
    mov eax, [kifs_total_blocks]
    call term_print_dec
    mov esi, msg_kifs_root
    call term_print
    mov eax, [kifs_root_oid]
    call term_print_dec
    mov esi, msg_kifs_free
    call term_print
    mov eax, [kifs_free_blocks]
    call term_print_dec
    mov al, 10
    call term_putc
    ; label / flags
    mov esi, msg_kifs_label
    call term_print
    mov esi, kifs_label
    call term_print
    mov esi, msg_kifs_flags
    call term_print
    mov eax, [kifs_flags]
    call term_print_dec
    mov al, 10
    call term_putc
    jmp .done

; ---------------------------------------------------------------------------
;  kifs ls [path]
; ---------------------------------------------------------------------------
.do_ls:
    call kifs_path_default
    mov esi, KIFS_PATH_BUF
    call kifs_resolve
    test eax, eax
    jz .err
    ; 目标 record
    mov edi, KIFS_REC_BUF
    call kifs_read_record
    test eax, eax
    jnz .err_io
    cmp byte [KIFS_REC_BUF + 4], 2        ; 必须是目录
    jne .err_notdir
    mov eax, [KIFS_REC_BUF + 8]
    cmp eax, KIFS_DIR_MAX
    ja .err_dirbig
    mov esi, KIFS_REC_BUF
    mov edi, KIFS_DIR_BUF
    mov ecx, KIFS_DIR_MAX
    call kifs_read_content
    test eax, eax
    js .err_io
    mov [kifs_ls_size], eax
    mov dword [kifs_ls_pos], 0
.ls_loop:
    mov edx, [kifs_ls_pos]
    mov eax, [kifs_ls_size]
    sub eax, edx
    cmp eax, 8
    jb .done                              ; 目录项也走完了
    lea esi, [KIFS_DIR_BUF + edx]
    movzx ecx, word [esi + 6]             ; entry_len
    test ecx, ecx
    jz .done
    ; 子项 record(失败就按 entry_len 跳过,不整条命令翻车)
    mov eax, [KIFS_DIR_BUF + edx]         ; 子项 oid
    mov edi, KIFS_REC_BUF
    call kifs_read_record
    test eax, eax
    jnz .ls_next
    ; 类型 d/-
    mov al, '-'
    cmp byte [KIFS_REC_BUF + 4], 2
    jne .ls_kind
    mov al, 'd'
.ls_kind:
    call term_putc
    mov al, ' '
    call term_putc
    ; 权限 12 字符
    movzx eax, word [KIFS_REC_BUF + 6]
    call kifs_print_perm
    ; owner
    mov esi, KIFS_REC_BUF
    call kifs_print_owner
    mov al, ' '
    call term_putc
    ; 文件大小(目录打 "dir",和宿主 mkifs.py ls 一致)
    cmp byte [KIFS_REC_BUF + 4], 2
    jne .ls_size_file
    mov esi, msg_kifs_word_dir
    call term_print
    jmp .ls_size_done
.ls_size_file:
    mov eax, [KIFS_REC_BUF + 8]
    call term_print_dec
.ls_size_done:
    mov al, ' '
    call term_putc
    ; 名字(直接从目录缓冲里取,bytes 原样打)
    mov edx, [kifs_ls_pos]
    lea esi, [KIFS_DIR_BUF + edx + 8]
    movzx ecx, byte [KIFS_DIR_BUF + edx + 5]   ; name_len
    test ecx, ecx
    jz .ls_name_done
.ls_name_loop:
    mov al, [esi]
    call term_putc
    inc esi
    dec ecx
    jnz .ls_name_loop
.ls_name_done:
    mov al, 10
    call term_putc
.ls_next:
    mov edx, [kifs_ls_pos]
    movzx ecx, word [KIFS_DIR_BUF + edx + 6]
    test ecx, ecx
    jz .done
    add edx, ecx
    mov [kifs_ls_pos], edx
    jmp .ls_loop

; ---------------------------------------------------------------------------
;  kifs cat <path> — 流式输出,内联直接打,extent 按块读、按字节打
;  (不往内存里整份放,所以 60 KiB 上限只是个"别拿它 cat 大文件"的规矩)
; ---------------------------------------------------------------------------
.do_cat:
    cmp dword [kifs_path_len], 0
    je .usage
    mov esi, KIFS_PATH_BUF
    call kifs_resolve
    test eax, eax
    jz .err
    mov edi, KIFS_REC_BUF
    call kifs_read_record
    test eax, eax
    jnz .err_io
    cmp byte [KIFS_REC_BUF + 4], 1        ; 必须是文件
    jne .err_notfile
    mov eax, [KIFS_REC_BUF + 8]
    cmp eax, KIFS_CAT_MAX
    ja .err_filebig
    mov byte [kifs_cat_last], 0
    mov dword [kifs_cat_printed], 0
    ; ---- 内联?先整段读到 IO 缓冲再逐字节打(最多 92 B)----
    cmp byte [KIFS_REC_BUF + 33], 0
    je .cat_ext
    mov esi, KIFS_REC_BUF
    mov edi, KIFS_IO_BUF
    mov ecx, KIFS_INLINE_MAX
    call kifs_read_content
    test eax, eax
    js .err_io
    mov ecx, eax
    test ecx, ecx
    jz .cat_end
    mov esi, KIFS_IO_BUF
    mov dword [kifs_cat_printed], 1
.cat_inline_loop:
    mov al, [esi]
    mov [kifs_cat_last], al
    call term_putc
    inc esi
    dec ecx
    jnz .cat_inline_loop
    jmp .cat_end
.cat_ext:
    mov eax, [KIFS_REC_BUF + 8]
    mov [kifs_cat_left], eax
    movzx eax, byte [KIFS_REC_BUF + 32]   ; n_ext
    mov [kifs_cat_ne], eax
    mov dword [kifs_cat_exti], 0
.cat_ext_loop:
    cmp dword [kifs_cat_left], 0
    je .cat_end
    cmp dword [kifs_cat_ne], 0
    je .cat_end
    mov eax, [kifs_cat_exti]
    imul eax, eax, 12
    lea esi, [KIFS_REC_BUF + eax + 36]
    mov eax, [esi]                        ; start 块
    mov [kifs_cat_blk], eax
    movzx eax, word [esi + 4]             ; 块数
    mov [kifs_cat_bcnt], eax
.cat_block_loop:
    cmp dword [kifs_cat_left], 0
    je .cat_end
    cmp dword [kifs_cat_bcnt], 0
    je .cat_next_ext
    mov eax, [kifs_cat_blk]
    call kifs_read_block
    test eax, eax
    jnz .err_io
    mov ecx, [kifs_cat_left]
    cmp ecx, KIFS_BLOCK_SIZE
    jbe .cat_chunk_ok
    mov ecx, KIFS_BLOCK_SIZE
.cat_chunk_ok:
    mov [kifs_cat_n], ecx
    mov esi, KIFS_IO_BUF
    mov dword [kifs_cat_printed], 1
.cat_print_loop:
    mov al, [esi]
    mov [kifs_cat_last], al
    call term_putc
    inc esi
    dec ecx
    jnz .cat_print_loop
    mov eax, [kifs_cat_n]
    sub [kifs_cat_left], eax
    inc dword [kifs_cat_blk]
    dec dword [kifs_cat_bcnt]
    jmp .cat_block_loop
.cat_next_ext:
    inc dword [kifs_cat_exti]
    dec dword [kifs_cat_ne]
    jmp .cat_ext_loop
.cat_end:
    ; 内容不是以换行结尾(或空文件)就补一个换行,提示符别粘在内容后面
    cmp dword [kifs_cat_printed], 0
    je .cat_newline
    cmp byte [kifs_cat_last], 10
    je .done
.cat_newline:
    mov al, 10
    call term_putc
    jmp .done

; ---------------------------------------------------------------------------
;  kifs stat <path>
; ---------------------------------------------------------------------------
.do_stat:
    call kifs_path_default
    mov esi, KIFS_PATH_BUF
    call kifs_resolve
    test eax, eax
    jz .err
    mov edi, KIFS_REC_BUF
    call kifs_read_record
    test eax, eax
    jnz .err_io
    ; 标题(带路径)
    mov esi, msg_kifs_stat_head
    call term_print
    mov esi, KIFS_PATH_BUF
    call term_print
    mov al, 10
    call term_putc
    ; oid
    mov esi, msg_kifs_stat_oid
    call term_print
    mov eax, [KIFS_REC_BUF]
    call term_print_dec
    ; type
    mov esi, msg_kifs_stat_type
    call term_print
    cmp byte [KIFS_REC_BUF + 4], 2
    jne .stype_file
    mov esi, msg_kifs_word_dir
    jmp .stype_put
.stype_file:
    mov esi, msg_kifs_word_file
.stype_put:
    call term_print
    mov al, 10
    call term_putc
    ; perm + owner
    mov esi, msg_kifs_stat_perm
    call term_print
    movzx eax, word [KIFS_REC_BUF + 6]
    call kifs_print_perm
    mov esi, KIFS_REC_BUF
    call kifs_print_owner
    mov al, 10
    call term_putc
    ; size
    mov esi, msg_kifs_stat_size
    call term_print
    mov eax, [KIFS_REC_BUF + 8]
    call term_print_dec
    mov esi, msg_kifs_bytes
    call term_print
    ; blocks + inline_len
    mov esi, msg_kifs_stat_blocks
    call term_print
    mov eax, [KIFS_REC_BUF + 12]
    call term_print_dec
    mov esi, msg_kifs_stat_inline
    call term_print
    movzx eax, byte [KIFS_REC_BUF + 33]
    call term_print_dec
    mov al, 10
    call term_putc
    ; extents:n_ext + 每段 (start=.. blocks=..)
    mov esi, msg_kifs_stat_ext
    call term_print
    movzx eax, byte [KIFS_REC_BUF + 32]
    call term_print_dec
    mov dword [kifs_st_i], 0
.st_ext_loop:
    mov ebx, [kifs_st_i]
    movzx eax, byte [KIFS_REC_BUF + 32]
    cmp ebx, eax
    jae .st_ext_done
    mov esi, msg_kifs_stat_ext_one
    call term_print
    mov eax, [kifs_st_i]
    imul eax, eax, 12
    lea esi, [KIFS_REC_BUF + eax + 36]
    mov eax, [esi]
    call term_print_dec
    mov esi, msg_kifs_stat_ext_blocks
    call term_print
    mov eax, [kifs_st_i]
    imul eax, eax, 12
    lea esi, [KIFS_REC_BUF + eax + 40]
    movzx eax, word [esi]
    call term_print_dec
    inc dword [kifs_st_i]
    jmp .st_ext_loop
.st_ext_done:
    mov al, 10
    call term_putc
    ; parent
    mov esi, msg_kifs_stat_parent
    call term_print
    mov eax, [KIFS_REC_BUF + 16]
    call term_print_dec
    mov al, 10
    call term_putc
    jmp .done

; ---------------------------------------------------------------------------
;  错误出口(路径解析失败 / 读盘失败 / 类型不对 / 目录太大)
; ---------------------------------------------------------------------------
.err:
    call kifs_print_err
    jmp .done
.err_io:
    mov dword [kifs_err], KIFS_ERR_IO
    jmp .err
.err_notdir:
    mov dword [kifs_err], KIFS_ERR_NOTDIR
    jmp .err
.err_notfile:
    mov dword [kifs_err], KIFS_ERR_NOTFILE
    jmp .err
.err_dirbig:
    mov dword [kifs_err], KIFS_ERR_DIRBIG
    jmp .err
.err_filebig:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_kifs_filebig
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    jmp .done
.usage:
    call kifs_print_usage
.done:
    popad
    ret

; ===========================================================================
;  数据
; ===========================================================================
kifs_ok            db 0
kifs_version       dd 0
kifs_block_size    dd 0
kifs_total_blocks  dd 0
kifs_record_start  dd 0
kifs_record_count  dd 0
kifs_root_oid      dd 0
kifs_free_blocks   dd 0
kifs_flags         dd 0
kifs_label         times 33 db 0
kifs_err           dd 0

; 函数间的小状态(flat 内核里用内存传参,省得跟一堆 helper 的寄存器契约打架)
kifs_rb_ret        dd 0
kifs_rr_oid        dd 0
kifs_rr_dst        dd 0
kifs_rr_ret        dd 0

kifs_rc_rec        dd 0
kifs_rc_dst        dd 0
kifs_rc_max        dd 0
kifs_rc_left       dd 0
kifs_rc_written    dd 0
kifs_rc_ne         dd 0
kifs_rc_exti       dd 0
kifs_rc_cur        dd 0
kifs_rc_n          dd 0
kifs_rc_blk        dd 0
kifs_rc_bcnt       dd 0
kifs_rc_ret        dd 0

kifs_rs_path       dd 0
kifs_rs_oid        dd 0
kifs_rs_comp       dd 0
kifs_rs_complen    dd 0
kifs_rs_dirsize    dd 0
kifs_rs_pos        dd 0
kifs_rs_ret        dd 0

kifs_perm_tmp      dd 0
kifs_word_ptr      dd 0
kifs_word_len      dd 0
kifs_path_len      dd 0

kifs_ls_size       dd 0
kifs_ls_pos        dd 0

kifs_cat_left      dd 0
kifs_cat_ne        dd 0
kifs_cat_exti      dd 0
kifs_cat_blk       dd 0
kifs_cat_bcnt      dd 0
kifs_cat_n         dd 0
kifs_cat_printed   dd 0
kifs_cat_last      db 0

kifs_st_i          dd 0

; 子命令名(和 shell.asm 的 cmd_table 一起用)
n_kifs_info  db 'info', 0
n_kifs_ls    db 'ls', 0
n_kifs_cat   db 'cat', 0
n_kifs_stat  db 'stat', 0

; 文案。错误文案按任务规格逐字固定,测试断言要匹配。
msg_kifs_noimg     db 'kifs: no KiFS image (read-only driver at LBA 22528)', 10, 0
msg_kifs_usage     db 'kifs: usage: kifs info | ls [path] | cat <path> | stat <path>', 10, 0
msg_kifs_notfound  db 'kifs: path not found', 10, 0
msg_kifs_notdir    db 'kifs: not a directory', 10, 0
msg_kifs_notfile   db 'kifs: not a file', 10, 0
msg_kifs_dirbig    db 'kifs: directory too big (Phase B0 supports <= 4 KiB)', 10, 0
msg_kifs_filebig   db 'kifs: file too big (Phase B0 cat supports <= 60 KiB)', 10, 0
msg_kifs_ioerr     db 'kifs: read error (ATA)', 10, 0

msg_kifs_info_head db 'kifs: KiFS read-only driver (Phase B0), partition at LBA 22528', 10, 0
msg_kifs_magic     db '  magic=KIFS version=', 0
msg_kifs_blocksize db ' block_size=', 0
msg_kifs_total     db '  total_blocks=', 0
msg_kifs_root      db ' root_oid=', 0
msg_kifs_free      db ' free_blocks=', 0
msg_kifs_label     db '  label=', 0
msg_kifs_flags     db ' flags=', 0

msg_kifs_stat_head db 'kifs stat: ', 0
msg_kifs_stat_oid  db '  oid=', 0
msg_kifs_stat_type db ' type=', 0
msg_kifs_stat_perm db '  perm=', 0
msg_kifs_stat_size db '  size=', 0
msg_kifs_bytes     db ' bytes', 0
msg_kifs_stat_blocks db '  blocks=', 0
msg_kifs_stat_inline db ' inline_len=', 0
msg_kifs_stat_ext  db '  extents=', 0
msg_kifs_stat_ext_one db ' (start=', 0
msg_kifs_stat_ext_blocks db ' blocks=', 0
msg_kifs_stat_parent db '  parent=', 0

msg_kifs_word_dir  db 'dir', 0
msg_kifs_word_file db 'file', 0
