; ============================================================================
;  KKernel x86-64 — LFB 8×16 ASCII 控制台
;
;  直接往 VBE 线性帧缓冲里画像素,字形用 64 位内核自带的 8×16 点阵
;  (tools/mkfont8x16.py 从 font/font-kkf.bin 导出的 ASCII 部分)。
;  没有文本书模式可用 —— 进了长模式以后 BIOS/VGA 文本模式都没了。
;
;  状态变量在 start.asm 的数据段:
;    lfb_phys/lfb_pitch/lfb_width/lfb_height  boot_info 抄来的帧缓冲参数
;    con_cols/con_rows/con_row/con_col/con_fg  光标、尺寸、前景色
; ============================================================================

; ---------------------------------------------------------------------------
;  con_init:算行列数、清屏
; ---------------------------------------------------------------------------
con_init:
    push rax
    push rdi
    push rcx
    mov eax, [lfb_width]
    shr eax, 3
    mov [con_cols], eax
    mov eax, [lfb_height]
    shr eax, 4
    mov [con_rows], eax
    mov dword [con_fg], CON_COLOR_WHITE
    pop rcx
    pop rdi
    pop rax
    jmp con_clear

; ---------------------------------------------------------------------------
;  con_clear:整屏涂黑,光标回左上角
; ---------------------------------------------------------------------------
con_clear:
    push rax
    push rdi
    push rcx
    mov edi, [lfb_phys]
    mov eax, [lfb_width]
    imul eax, [lfb_height]
    mov ecx, eax
    xor eax, eax
    cld
    rep stosd
    mov dword [con_row], 0
    mov dword [con_col], 0
    pop rcx
    pop rdi
    pop rax
    ret

; ---------------------------------------------------------------------------
;  con_putc:al = 一个 ASCII 字符(10=换行,8=退格,13 忽略)
; ---------------------------------------------------------------------------
con_putc:
    cmp al, 10
    je con_newline
    cmp al, 13
    je .ret
    cmp al, 8
    je con_backspace

    push rbx
    push rsi
    push rdi
    push rcx
    push rdx
    push r8

    ; ---- 字形指针 = font8x16 + (ch-0x20)*16 ----
    movzx eax, al
    cmp eax, 0x20
    jae .hi
    mov eax, ' '
    jmp .have
.hi:
    cmp eax, 0x7F
    jb .have
    mov eax, ' '
.have:
    sub eax, 0x20
    shl eax, 4
    lea rsi, [font8x16]
    add rsi, rax

    ; ---- 目标地址 = lfb + row*16*pitch + col*8*4 ----
    mov eax, [con_row]
    shl eax, 4                      ; 行号 → 像素行(每字符 16 像素高)
    imul eax, [lfb_pitch]
    mov edx, [con_col]
    shl edx, 5                    ; *8 像素 *4 字节 = *32
    add eax, edx
    mov edi, [lfb_phys]
    add edi, eax

    ; ---- 16 行 × 8 列像素 ----
    mov ecx, 16
.row_loop:
    mov bl, [rsi]
    mov r8d, 0x80
    xor edx, edx
.pix_loop:
    xor eax, eax
    test bl, r8b
    jz .zero
    mov eax, [con_fg]
.zero:
    mov [rdi + rdx * 4], eax
    shr r8b, 1
    inc edx
    cmp edx, 8
    jb .pix_loop
    add edi, [lfb_pitch]
    inc rsi
    dec ecx
    jnz .row_loop

    ; ---- 光标前进 ----
    inc dword [con_col]
    mov eax, [con_col]
    cmp eax, [con_cols]
    jl .done
    call con_newline
.done:
    pop r8
    pop rdx
    pop rcx
    pop rdi
    pop rsi
    pop rbx
.ret:
    ret

; ---------------------------------------------------------------------------
;  con_newline:光标到下一行行首,到底了就滚屏
; ---------------------------------------------------------------------------
con_newline:
    push rax
    push rdi
    push rcx
    mov dword [con_col], 0
    inc dword [con_row]
    mov eax, [con_row]
    cmp eax, [con_rows]
    jl .done
    call con_scroll
    mov eax, [con_rows]
    dec eax
    mov [con_row], eax
.done:
    pop rcx
    pop rdi
    pop rax
    ret

; ---------------------------------------------------------------------------
;  con_scroll:整体上移一行,最后一行涂黑
; ---------------------------------------------------------------------------
con_scroll:
    push rax
    push rsi
    push rdi
    push rcx
    mov esi, [lfb_phys]
    mov eax, [lfb_pitch]
    shl eax, 4
    add esi, eax                    ; 源 = 第二文本行(16 像素行)
    mov edi, [lfb_phys]             ; 目标 = 第一行
    mov eax, [con_rows]
    dec eax
    shl eax, 4
    imul eax, [lfb_pitch]
    shr eax, 2                      ; 字节数 → dword 数
    mov ecx, eax
    cld
    rep movsd
    ; 最后一行涂黑(16 像素行)
    mov edi, [lfb_phys]
    mov eax, [con_rows]
    dec eax
    shl eax, 4
    imul eax, [lfb_pitch]
    add edi, eax
    mov eax, [lfb_pitch]
    shl eax, 4
    shr eax, 2
    mov ecx, eax
    xor eax, eax
    rep stosd
    pop rcx
    pop rdi
    pop rsi
    pop rax
    ret

; ---------------------------------------------------------------------------
;  con_backspace:退一格并擦掉那个字符
; ---------------------------------------------------------------------------
con_backspace:
    push rax
    push rdi
    push rcx
    push rdx
    cmp dword [con_col], 0
    ja .left
    cmp dword [con_row], 0
    je .done
    dec dword [con_row]
    mov eax, [con_cols]
    dec eax
    mov [con_col], eax
    jmp .clear
.left:
    dec dword [con_col]
.clear:
    mov eax, [con_row]
    shl eax, 4
    imul eax, [lfb_pitch]
    mov edx, [con_col]
    shl edx, 5
    add eax, edx
    mov edi, [lfb_phys]
    add edi, eax
    mov ecx, 16
.erow:
    mov dword [edi + 0], 0
    mov dword [edi + 4], 0
    mov dword [edi + 8], 0
    mov dword [edi + 12], 0
    mov dword [edi + 16], 0
    mov dword [edi + 20], 0
    mov dword [edi + 24], 0
    mov dword [edi + 28], 0
    add edi, [lfb_pitch]
    dec ecx
    jnz .erow
.done:
    pop rdx
    pop rcx
    pop rdi
    pop rax
    ret

; ---------------------------------------------------------------------------
;  con_print:rsi = 0 结尾字符串
; ---------------------------------------------------------------------------
con_print:
    push rsi
    push rax
.loop:
    mov al, [rsi]
    test al, al
    jz .done
    call con_putc
    inc rsi
    jmp .loop
.done:
    pop rax
    pop rsi
    ret

; ---------------------------------------------------------------------------
;  con_print_dec32:eax = 无符号数,打十进制
; ---------------------------------------------------------------------------
con_print_dec32:
    push rbx
    push rcx
    push rdx
    push rsi
    lea rsi, [con_num_buf + 20]
    mov byte [rsi], 0
    mov ebx, 10
    mov ecx, eax
.loop:
    mov eax, ecx
    xor edx, edx
    div ebx
    mov ecx, eax
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test ecx, ecx
    jnz .loop
    call con_print
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ---------------------------------------------------------------------------
;  con_print_dec64:rax = 无符号 64 位数,打十进制(ticks 用)
; ---------------------------------------------------------------------------
con_print_dec64:
    push rbx
    push rcx
    push rdx
    push rsi
    lea rsi, [con_num_buf + 28]
    mov byte [rsi], 0
    mov ebx, 10
    mov rcx, rax
.loop:
    mov rax, rcx
    xor edx, edx
    div rbx
    mov rcx, rax
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rcx, rcx
    jnz .loop
    call con_print
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ---------------------------------------------------------------------------
;  con_print_hex32:eax = 32 位数,打 0xXXXXXXXX
; ---------------------------------------------------------------------------
con_print_hex32:
    push rbx
    push rcx
    push rdx
    push rsi
    mov ebx, eax
    lea rsi, [con_hex_buf]
    mov byte [rsi], '0'
    mov byte [rsi + 1], 'x'
    add rsi, 2
    mov ecx, 8
.loop:
    rol ebx, 4
    mov edx, ebx
    and edx, 0x0F
    mov dl, [con_hexdigits + rdx]
    mov [rsi], dl
    inc rsi
    dec ecx
    jnz .loop
    mov byte [rsi], 0
    lea rsi, [con_hex_buf]
    call con_print
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ---------------------------------------------------------------------------
;  con_show_bootinfo:开机横幅下面的那几行
; ---------------------------------------------------------------------------
con_show_bootinfo:
    push rax
    push rsi
    ; LFB 一行
    mov dword [con_fg], CON_COLOR_GREEN
    lea rsi, [msg_bi_lfb]
    call con_print
    mov eax, [lfb_phys]
    call con_print_hex32
    lea rsi, [msg_bi_space]
    call con_print
    mov eax, [lfb_width]
    call con_print_dec32
    mov al, 'x'
    call con_putc
    mov eax, [lfb_height]
    call con_print_dec32
    mov al, 'x'
    call con_putc
    mov eax, [lfb_bpp]
    call con_print_dec32
    call con_newline
    ; 内存一行
    lea rsi, [msg_bi_ram]
    call con_print
    mov eax, [ram_top]
    shr eax, 20
    call con_print_dec32
    lea rsi, [msg_bi_mib]
    call con_print
    mov eax, [e820_count]
    call con_print_dec32
    call con_newline
    ; 镜像一行
    lea rsi, [msg_bi_img]
    call con_print
    mov eax, [k64_phys]
    call con_print_hex32
    lea rsi, [msg_bi_size]
    call con_print
    mov eax, [k64_size]
    call con_print_dec32
    lea rsi, [msg_bi_bytes]
    call con_print
    call con_newline
    mov dword [con_fg], CON_COLOR_WHITE
    pop rsi
    pop rax
    ret
