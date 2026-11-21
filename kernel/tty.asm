; ============================================================================
;  KKernel — 控制台 TTY:输出包装(ANSI CSI 子集 / ASCII 降级)+ 行规程输入
;
;  之前控制台输出直接进 term_putc(VGA 显存 / 帧缓冲),没有"终端"这一层。
;  这个文件把输出接过来:
;    term_putc  → tty_out_char   单字节:ANSI 状态机 + 基本控制字符
;    term_print → tty_out_str    UTF-8 码位流:charset=utf8 原样,ascii 降级
;  底下真正画屏的入口改名叫 term_raw_putc(kmain.asm,内容没动)。
;
;  ctrl_on(console.ctrl):
;    1 = 解释 ANSI CSI 子集:A/B/C/D 上下左右、H/f 定位、J 清屏、K 清行、
;        m 设置颜色(0/1/22/30-37/39/40-47/49);未知序列整段丢弃。
;    0 = "哑终端":不解释转义,ESC 显示成 "[ESC]" 字样(便于看到原始字节);
;        \r \n \b \t \a 这些基本控制字符照旧处理。
;  charset(console.charset):
;    utf8  = 原样交给字库(中文/日文有字形就能显示);
;    ascii = 降级成 ASCII:假名→罗马字(かいかーねる→kaikaaneru)、希腊字母/
;            数学符号、全角→半角、其它 CJK/emoji→'?',便于文本模式/无字库使用。
;
;  pipe 捕获优先:程序输出被管道捕获时,**原始字节**原样进缓冲(和以前的
;  term_putc/term_print 行为一致),不能先降级;全屏程序(vi/计算器)用
;  term_puts_at 直接画,不经过这里。
;
;  输入:键盘中断仍然往 kbd_buf 塞字节,这里提供行规程读入(tty_read_line /
;  tty_read_line_timeout / tty_read_password),给开机向导和登录用;
;  tty_read_char / tty_input_char 是给"程序主动读写控制台"预留的最小接口
;  (输入缓冲 256 B 是 tty 自己的补丁队列,硬件按键走键盘的 64 B 环)。
; ============================================================================

TTY_CSI_MAX_PARAMS equ 4                ; CSI 最多记几个数字参数
TTY_ESC_NONE       equ 0
TTY_ESC_START      equ 1
TTY_ESC_CSI        equ 2
TTY_INTR           equ 0x03             ; Ctrl-C
TTY_EOF_KEY        equ 0x04             ; Ctrl-D
TTY_STOP_KEY       equ 0x1A             ; Ctrl-Z
TTY_QUIT_KEY       equ 0x1C             ; Ctrl-\ (键盘层目前不产生,留个位)

; ===========================================================================
;  输出入口:接管 term_putc / term_print
; ===========================================================================
term_putc:
    jmp tty_out_char

term_print:
    cmp dword [pipe_capture_on], 0
    jne .pipe
    jmp tty_out_str
.pipe:
    jmp pipe_capture_str

; ---------------------------------------------------------------------------
;  tty_init:从当前显示模式取字符尺寸,初始化状态(默认开控制字符/UTF-8)
; ---------------------------------------------------------------------------
tty_init:
    pushad
    call term_size                      ; eax = 列, ebx = 行
    mov [tty_cols], eax
    mov [tty_rows], ebx
    mov dword [tty_attr], COL_NORMAL
    mov dword [tty_esc_state], TTY_ESC_NONE
    mov byte [tty_last_vowel], 0
    popad
    ret

; ---------------------------------------------------------------------------
;  tty_out_str:esi = 以 0 结尾的 UTF-8 串 → 经 TTY 输出
; ---------------------------------------------------------------------------
tty_out_str:
    pushad
    call console_lock                   ; A4:tty 输出互斥,整串不和其他线程交错
.loop:
    call utf8_decode                    ; eax = 码位(0=结束),esi 前进
    test eax, eax
    jz .done
    cmp eax, 0x80
    jb .one_byte
    ; ---- 非 ASCII:UTF-8 模式原样交字库,ASCII 模式降级 ----
    cmp dword [tty_utf8], 0
    je .ascii_fallback
    call term_print_cp
    jmp .loop
.ascii_fallback:
    call tty_map_ascii
    jmp .loop
.one_byte:
    call tty_out_char
    jmp .loop
.done:
    call console_unlock
    popad
    ret

; ---------------------------------------------------------------------------
;  tty_out_char:al = 单字节 → ANSI 状态机 / 基本控制字符 / 直接落屏
; ---------------------------------------------------------------------------
tty_out_char:
    pushad
    call console_lock                   ; A4:单字符输出也进互斥(递归计数,串内不重复等锁)
    ; ---- 管道捕获优先:原始字节进缓冲,不做任何解释 ----
    cmp dword [pipe_capture_on], 0
    je .no_pipe
    call pipe_capture_byte
    jmp .done
.no_pipe:
    cmp dword [tty_ctrl_on], 0
    jne .ctrl_mode
    ; ================= 哑终端模式 =================
    cmp al, 27
    jne .dumb_basic
    ; ESC 显示成可读的 "[ESC]"
    mov al, '['
    call tty_put_raw
    mov al, 'E'
    call tty_put_raw
    mov al, 'S'
    call tty_put_raw
    mov al, 'C'
    call tty_put_raw
    mov al, ']'
    call tty_put_raw
    jmp .done
.dumb_basic:
    call tty_handle_basic
    jmp .done
.ctrl_mode:
    ; ================= ANSI 模式 =================
    cmp byte [tty_esc_state], TTY_ESC_NONE
    jne .in_escape
    cmp al, 27
    jne .normal_char
    mov byte [tty_esc_state], TTY_ESC_START
    jmp .done
.normal_char:
    call tty_handle_basic
    jmp .done
.in_escape:
    cmp byte [tty_esc_state], TTY_ESC_START
    jne .csi_collect
    ; ---- ESC 之后期望 '[' ----
    cmp al, '['
    jne .esc_drop
    mov byte [tty_esc_state], TTY_ESC_CSI
    mov dword [tty_csi_n], 0
    mov dword [tty_csi_cur], 0
    jmp .done
.esc_drop:
    mov byte [tty_esc_state], TTY_ESC_NONE
    jmp .done
.csi_collect:
    ; ---- CSI:数字 / ';' / 终字节 ----
    cmp al, '0'
    jb .csi_not_digit
    cmp al, '9'
    ja .csi_not_digit
    movzx eax, al
    sub eax, '0'
    mov ecx, [tty_csi_cur]
    imul ecx, ecx, 10
    add ecx, eax
    cmp ecx, 255
    jbe .csi_cur_ok
    mov ecx, 255
.csi_cur_ok:
    mov [tty_csi_cur], ecx
    jmp .done
.csi_not_digit:
    cmp al, ';'
    jne .csi_final
    call tty_csi_push_param
    mov dword [tty_csi_cur], 0
    jmp .done
.csi_final:
    call tty_csi_push_param
    call tty_csi_dispatch              ; al = 终字节
    mov byte [tty_esc_state], TTY_ESC_NONE
    jmp .done
.done:
    call console_unlock
    popad
    ret

; tty_csi_push_param:把 [tty_csi_cur] 追加进参数数组(最多 TTY_CSI_MAX_PARAMS)
tty_csi_push_param:
    push eax
    push ecx
    mov ecx, [tty_csi_n]
    cmp ecx, TTY_CSI_MAX_PARAMS
    jae .full
    mov eax, [tty_csi_cur]
    mov [tty_csi_params + ecx * 4], eax
    inc ecx
    mov [tty_csi_n], ecx
.full:
    pop ecx
    pop eax
    ret

; tty_param:ecx = 第几个参数(0 起),edx = 缺省值 → eax = 参数值(0/越界用缺省)
tty_param:
    push ebx
    mov eax, edx
    cmp ecx, [tty_csi_n]
    jae .out
    mov ebx, [tty_csi_params + ecx * 4]
    test ebx, ebx
    jz .out                            ; ANSI 里 0 = 用缺省
    mov eax, ebx
.out:
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  tty_csi_dispatch:al = CSI 终字节
; ---------------------------------------------------------------------------
tty_csi_dispatch:
    pushad
    cmp al, 'A'
    je .up
    cmp al, 'B'
    je .down
    cmp al, 'C'
    je .right
    cmp al, 'D'
    je .left
    cmp al, 'H'
    je .pos
    cmp al, 'f'
    je .pos
    cmp al, 'J'
    je .clear
    cmp al, 'K'
    je .erase_line
    cmp al, 'm'
    je .sgr
    jmp .done                          ; 未知:整段丢弃
.up:
    xor ecx, ecx
    mov edx, 1
    call tty_param
    mov ebx, eax
    call tty_get_row
    sub eax, ebx
    jns .up_ok
    xor eax, eax
.up_ok:
    mov [tty_tmp_row], eax
    call tty_get_col
    mov ebx, eax
    mov eax, [tty_tmp_row]
    call tty_set_rowcol
    jmp .done
.down:
    xor ecx, ecx
    mov edx, 1
    call tty_param
    mov ebx, eax
    call tty_get_row
    add eax, ebx
    mov ecx, [tty_rows]
    dec ecx
    cmp eax, ecx
    jbe .down_ok
    mov eax, ecx
.down_ok:
    mov [tty_tmp_row], eax
    call tty_get_col
    mov ebx, eax
    mov eax, [tty_tmp_row]
    call tty_set_rowcol
    jmp .done
.right:
    xor ecx, ecx
    mov edx, 1
    call tty_param
    mov ebx, eax
    call tty_get_col
    add eax, ebx
    mov ecx, [tty_cols]
    dec ecx
    cmp eax, ecx
    jbe .right_ok
    mov eax, ecx
.right_ok:
    mov ebx, eax
    call tty_get_row
    call tty_set_rowcol
    jmp .done
.left:
    xor ecx, ecx
    mov edx, 1
    call tty_param
    mov ebx, eax
    call tty_get_col
    sub eax, ebx
    jns .left_ok
    xor eax, eax
.left_ok:
    mov ebx, eax
    call tty_get_row
    call tty_set_rowcol
    jmp .done
.pos:
    xor ecx, ecx
    mov edx, 1
    call tty_param                     ; 行(1 起)
    dec eax
    jns .pos_r_ok
    xor eax, eax
.pos_r_ok:
    mov [tty_tmp_row], eax
    mov ecx, 1
    mov edx, 1
    call tty_param                     ; 列(1 起)
    dec eax
    jns .pos_c_ok
    xor eax, eax
.pos_c_ok:
    mov ebx, eax
    mov eax, [tty_tmp_row]
    call tty_set_rowcol
    jmp .done
.clear:
    call term_clear                    ; 清屏+光标回左上(VGA/VBE 都管)
    jmp .done
.erase_line:
    call tty_erase_line                ; 清光标到行尾
    jmp .done
.sgr:
    ; ---- 逐个参数设置颜色/亮度 ----
    mov eax, [tty_attr]
    mov [tty_sgr_attr], eax
    xor ecx, ecx
.sgr_loop:
    cmp ecx, [tty_csi_n]
    jae .sgr_apply
    mov eax, [tty_csi_params + ecx * 4]
    inc ecx
    cmp eax, 0
    je .sgr_reset
    cmp eax, 1
    je .sgr_bold
    cmp eax, 22
    je .sgr_nobold
    cmp eax, 30
    jb .sgr_loop
    cmp eax, 37
    ja .sgr_bg
    ; ---- 前景色 30-37 ----
    sub eax, 30
    lea ebx, [tty_ansi_fg]
    movzx eax, byte [ebx + eax]
    mov ebx, [tty_sgr_attr]
    and ebx, 0xF0
    or ebx, eax
    mov [tty_sgr_attr], ebx
    jmp .sgr_loop
.sgr_bg:
    cmp eax, 40
    jb .sgr_loop
    cmp eax, 47
    ja .sgr_loop
    ; ---- 背景色 40-47 ----
    sub eax, 40
    lea ebx, [tty_ansi_bg]
    movzx eax, byte [ebx + eax]
    mov ebx, [tty_sgr_attr]
    and ebx, 0x0F
    or ebx, eax
    mov [tty_sgr_attr], ebx
    jmp .sgr_loop
.sgr_reset:
    mov dword [tty_sgr_attr], COL_NORMAL
    jmp .sgr_loop
.sgr_bold:
    or dword [tty_sgr_attr], 0x08
    jmp .sgr_loop
.sgr_nobold:
    and dword [tty_sgr_attr], 0xFFFFFFF7
    jmp .sgr_loop
.sgr_apply:
    mov eax, [tty_sgr_attr]
    mov [tty_attr], eax
    call term_set_color                ; al = 属性字节
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  tty_handle_basic:al = 字符 → 处理 \n \r \b \t \a 与可打印字符
; ---------------------------------------------------------------------------
tty_handle_basic:
    pushad
    movzx eax, al
    cmp al, 10
    je .lf
    cmp al, 13
    je .cr
    cmp al, 8
    je .bs
    cmp al, 9
    je .tab
    cmp al, 7
    je .done
    cmp al, 32
    jb .done
    ; ---- 可打印 ASCII:先清"前一假名元音"记录,再原样落屏 ----
    mov byte [tty_last_vowel], 0
    call tty_put_raw
    jmp .done
.lf:
    ; ONLCR:\n → \r\n(哑终端/ANSI 都这么干)
    mov al, 13
    call tty_put_raw
    mov al, 10
    call tty_put_raw
    jmp .done
.cr:
    mov al, 13
    call tty_put_raw
    jmp .done
.bs:
    mov al, 8
    call tty_put_raw
    jmp .done
.tab:
    call tty_tab
    jmp .done
.done:
    popad
    ret

; tty_tab:把 \t 展开成到下一个 8 列制表位的空格
tty_tab:
    pushad
    call tty_get_col
    mov ebx, eax
    and ebx, 7
    mov ecx, 8
    sub ecx, ebx
.tab_loop:
    test ecx, ecx
    jz .done
    push ecx
    mov al, ' '
    call tty_put_raw
    pop ecx
    dec ecx
    jmp .tab_loop
.done:
    popad
    ret

; tty_put_raw:al → 真正的画屏入口(kmain 里改名前的 term_putc)
tty_put_raw:
    jmp term_raw_putc

; ---------------------------------------------------------------------------
;  tty_get_col / tty_get_row:→ eax = 当前字符列/行
; ---------------------------------------------------------------------------
tty_get_col:
    cmp dword [vbe_ok], 0
    je .vga
    mov eax, [fb_cur_x]
    shr eax, 3
    ret
.vga:
    movzx eax, byte [term_col]
    ret

tty_get_row:
    cmp dword [vbe_ok], 0
    je .vga
    mov eax, [fb_cur_y]
    shr eax, 4
    ret
.vga:
    movzx eax, byte [term_row]
    ret

; ---------------------------------------------------------------------------
;  tty_set_rowcol:eax = 行, ebx = 列(夹到边界内)
;  图形模式直接写 fb_cur_x/fb_cur_y:不是不想用 term_set_cursor,而是它 VBE
;  分支里 call term_size 把 ebx(行)冲掉了,行号永远落到最后一行(已知 bug,
;  不在这个提交里改它,免得影响 vi/计算器的既有行为)。
; ---------------------------------------------------------------------------
tty_set_rowcol:
    pushad
    mov [tty_tmp_row], eax
    mov [tty_tmp_col], ebx
    cmp dword [vbe_ok], 0
    je .vga
    ; ---- 图形模式 ----
    mov eax, [tty_tmp_row]
    cmp eax, [tty_rows]
    jb .r_ok
    mov eax, [tty_rows]
    dec eax
.r_ok:
    mov ebx, [tty_tmp_col]
    cmp ebx, [tty_cols]
    jb .c_ok
    mov ebx, [tty_cols]
    dec ebx
.c_ok:
    shl eax, 4
    mov [fb_cur_y], eax
    shl ebx, 3
    mov [fb_cur_x], ebx
    popad
    ret
.vga:
    mov ebx, [tty_tmp_row]
    mov ecx, [tty_tmp_col]
    call term_set_cursor
    popad
    ret

; ---------------------------------------------------------------------------
;  tty_erase_line:清除光标到行尾(ANSI K),光标不动
; ---------------------------------------------------------------------------
tty_erase_line:
    pushad
    cmp dword [vbe_ok], 0
    je .vga
    ; ---- 图形模式:先把行缓冲里这一行的脏段落盘,再整段清黑 ----
    call fb_flush
    mov eax, [fb_cur_y]
    imul eax, [fb_pitch]
    mov edi, [fb_phys]
    add edi, eax
    mov eax, [fb_cur_x]
    shl eax, 2
    add edi, eax                       ; 起始像素地址
    mov ebx, [fb_width]
    sub ebx, [fb_cur_x]                ; 还要清多少像素(=dword 数)
    jbe .fb_done
    mov ebp, FB_CELL_H
.fb_row:
    push edi
    mov ecx, ebx
    xor eax, eax
    rep stosd
    pop edi
    add edi, [fb_pitch]
    dec ebp
    jnz .fb_row
.fb_done:
    call fb_lb_forget                  ; 显存被改过,行缓冲记账作废
    popad
    ret
.vga:
    ; ---- 文本模式:当前属性空格填到行尾 ----
    movzx eax, byte [term_row]
    imul eax, VGA_COLS
    movzx ebx, byte [term_col]
    add eax, ebx
    shl eax, 1
    add eax, VGA_MEM
    mov edi, eax
    mov ecx, VGA_COLS
    sub ecx, ebx
    jle .vga_done
    mov al, ' '
    mov ah, [term_color]
    rep stosw
.vga_done:
    popad
    ret

; ---------------------------------------------------------------------------
;  tty_map_ascii:eax = 非 ASCII 码位 → 按降级表输出 ASCII
;    - 全角 ASCII(0xFF01-0xFF5E)→ 半角;全角空格 → 空格
;    - ー(长音)→ 前一个假名罗马字的收尾元音(かいかーねる→kaikaaneru)
;    - 假名/希腊/数学符号查表;其它 CJK/emoji → '?'
; ---------------------------------------------------------------------------
tty_map_ascii:
    pushad
    mov [tty_map_cp], eax
    cmp eax, 0xFF01
    jb .not_fullwidth
    cmp eax, 0xFF5E
    ja .not_fullwidth
    sub eax, 0xFEE0
    call tty_out_char
    jmp .done
.not_fullwidth:
    cmp eax, 0x3000                    ; 全角空格
    jne .prolong
    mov al, ' '
    call tty_out_char
    jmp .done
.prolong:
    cmp eax, 0x30FC                    ; ー
    jne .table
    movzx eax, byte [tty_last_vowel]
    test al, al
    jnz .prolong_emit
    mov al, '-'
.prolong_emit:
    movzx edx, al
    mov [tty_tmp_vowel], edx
    call tty_out_char
    mov edx, [tty_tmp_vowel]
    mov [tty_last_vowel], dl
    jmp .done
.table:
    mov ebx, tty_ascii_tab
.lookup:
    mov eax, [ebx]
    test eax, eax
    jz .unknown
    cmp eax, [tty_map_cp]
    je .found
    add ebx, 8
    jmp .lookup
.found:
    mov esi, [ebx + 4]
    call tty_emit_str
    jmp .done
.unknown:
    mov al, '?'
    call tty_out_char
.done:
    popad
    ret

; tty_emit_str:esi = 0 结尾的 ASCII 串 → 逐字节输出,并记录收尾元音(给 ー 用)
tty_emit_str:
    pushad
.loop:
    mov al, [esi]
    test al, al
    jz .done
    inc esi
    mov [tty_tmp_ch], al
    movzx eax, al
    mov [tty_tmp_ch], eax
    call tty_out_char
    jmp .loop
.done:
    ; tty_tmp_ch = 最后输出的字符(空串时是最后一次残留,清成 0)
    mov eax, [tty_tmp_ch2]
    xor eax, eax
    mov al, [esi - 1]                  ; 最后一个字符(esi 已指向 0 处)
    cmp al, 'a'
    jb .no_vowel
    cmp al, 'e'
    jbe .is_vowel                      ; a-e 里 a/e 是元音
    cmp al, 'i'
    je .is_vowel
    cmp al, 'o'
    je .is_vowel
    cmp al, 'u'
    je .is_vowel
.no_vowel:
    mov byte [tty_last_vowel], 0
    jmp .out
.is_vowel:
    mov [tty_last_vowel], al
.out:
    popad
    ret

; ===========================================================================
;  输入:行规程(给开机向导 / 登录用)
; ===========================================================================
; tty_read_line:edi = 缓冲,ecx = 上限(含结尾 NUL)→ eax = 长度(阻塞)
tty_read_line:
    pushad
    xor edx, edx
    call tty_read_setup
    jmp tty_read_loop

; tty_read_line_timeout:edi/ecx 同上,edx = 超时(100 Hz tick,0=无限)
tty_read_line_timeout:
    pushad
    call tty_read_setup
    jmp tty_read_loop

; tty_read_password:同上,但不回显
tty_read_password:
    pushad
    xor edx, edx
    call tty_read_setup
    mov dword [tr_echo], 0
    jmp tty_read_loop

tty_read_setup:
    mov [tr_buf], edi
    mov [tr_max], ecx
    mov dword [tr_len], 0
    mov [tr_timeout], edx
    mov dword [tr_deadline], 0
    test edx, edx
    jz .no_deadline
    add edx, [pit_ticks]
    mov [tr_deadline], edx
.no_deadline:
    mov eax, [tty_echo]
    mov [tr_echo], eax
    ret

tty_read_loop:
.wait:
    call kbd_avail
    test eax, eax
    jnz .have_key
    ; ---- 没键:到时间了吗 ----
    cmp dword [tr_timeout], 0
    je .sleep
    mov eax, [pit_ticks]
    cmp eax, [tr_deadline]
    jae .timeout
.sleep:
    call fb_flush                      ; 保证提示行先上屏,再睡
    ; ---- 有调度器就睡在 tty_chan 通道上(键盘 IRQ / 超时唤醒)----
    cmp dword [sched_on], 0
    je .poll_only
    cmp dword [tr_timeout], 0
    je .sleep_block
    ; 限时版:算一下还剩几个 tick,<= 0 直接超时
    mov ecx, [tr_deadline]
    sub ecx, [pit_ticks]
    jbe .timeout
    mov eax, tty_chan
    call sched_sleep_timeout           ; eax = 1 超时 / 0 被叫醒
    test eax, eax
    jnz .timeout
    jmp .wait
.sleep_block:
    ; 不限时版:prepare → 关中断复查有没有键 → 有键就撤,没键就睡
    mov eax, tty_chan
    call sched_sleep_prepare
    call kbd_avail
    test eax, eax
    jnz .sleep_cancel
    call sched_sleep_commit
    jmp .wait
.sleep_cancel:
    call sched_sleep_cancel
    sti
    jmp .wait
.poll_only:
    hlt                                ; 调度器还没开(极早期):裸 hlt 轮询
    jmp .wait
.have_key:
    call kbd_getkey                    ; eax = ASCII,或 0x100+n(扩展键)
    cmp eax, 0x100
    jae .wait                          ; 方向键等扩展键:忽略
    cmp al, 13
    je .enter
    cmp al, 8
    je .backspace
    cmp al, TTY_INTR
    je .intr
    cmp al, TTY_EOF_KEY
    je .eof
    cmp al, TTY_STOP_KEY
    je .wait
    cmp al, TTY_QUIT_KEY
    je .wait
    cmp al, 32
    jb .wait
    cmp al, 0x7E
    ja .wait                           ; 向导/登录只收 ASCII 可见字符
    ; ---- 普通字符:有空间就存,回显 ----
    mov edx, [tr_len]
    mov ecx, [tr_max]
    dec ecx
    cmp edx, ecx
    jae .wait
    mov ebx, [tr_buf]
    mov [ebx + edx], al
    inc edx
    mov [tr_len], edx
    cmp dword [tr_echo], 0
    je .wait
    call tty_out_char
    jmp .wait
.enter:
    ; ---- 回车:收尾 + 换行 ----
    cmp dword [tr_echo], 0
    je .finish
    mov al, 10
    call tty_out_char
    jmp .finish
.backspace:
    ; ---- 退格:删一个字符(这里只收 ASCII,一个字节一个字符)----
    mov edx, [tr_len]
    test edx, edx
    jz .wait
    dec edx
    mov [tr_len], edx
    cmp dword [tr_echo], 0
    je .wait
    mov al, 8
    call tty_out_char
    mov al, ' '
    call tty_out_char
    mov al, 8
    call tty_out_char
    jmp .wait
.intr:
    ; ---- Ctrl-C:回显 ^C,清空当前行,按"空行"返回 ----
    cmp dword [tty_isig], 0
    je .wait
    mov dword [tr_len], 0
    cmp dword [tr_echo], 0
    je .finish
    mov al, '^'
    call tty_out_char
    mov al, 'C'
    call tty_out_char
    mov al, 10
    call tty_out_char
    jmp .finish
.eof:
    ; ---- Ctrl-D:当成"输入结束",返回已输入内容 ----
    jmp .finish
.timeout:
    ; ---- 超时:返回已输入内容(空的话由调用方走默认值)----
    cmp dword [tr_echo], 0
    je .finish
    mov al, 10
    call tty_out_char
.finish:
    mov edi, [tr_buf]
    mov eax, [tr_len]
    mov byte [edi + eax], 0
    popad
    mov eax, [tr_len]
    ret

; ---------------------------------------------------------------------------
;  tty_read_char / tty_input_char:程序主动读写控制台的最小接口
;  (硬件按键在键盘环里;tty_ring 是给程序注入输入用的 256 B 补丁队列)
; ---------------------------------------------------------------------------
tty_input_char:
    ; al = 字节
    push eax
    push ebx
    push ecx
    push edx
    mov ebx, [tty_ring_head]
    mov ecx, [tty_ring_tail]
    mov edx, ebx
    inc edx
    and edx, 255
    cmp edx, ecx
    je .full                           ; 满:丢
    mov [tty_ring + ebx], al
    mov [tty_ring_head], edx
.full:
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

tty_read_char:
    ; → eax = 字符;tty 缓冲空则阻塞从键盘读
    push ebx
    push ecx
    mov ebx, [tty_ring_tail]
    mov ecx, [tty_ring_head]
    cmp ebx, ecx
    je .kbd
    movzx eax, byte [tty_ring + ebx]
    inc ebx
    and ebx, 255
    mov [tty_ring_tail], ebx
    pop ecx
    pop ebx
    ret
.kbd:
    pop ecx
    pop ebx
    jmp kbd_getchar                    ; 阻塞等一个 ASCII 键

; ===========================================================================
;  开机向导:RC.CONF 里没有 console.ctrl / console.charset 时问两句
;    - 有 FAT 才问(软盘启动保持默认,不进交互——否则会挡掉老测试的屏幕断言)
;    - 10 秒不答就用默认值:VBE 控制台 → y/u,文本模式 → n/a
;    - 答案写回 SYS/RC.CONF(保留原内容),再 rc_load 一次让配置生效
; ===========================================================================
tty_rc_init:
    pushad
    cmp byte [fat_ok], 0
    je .out
    ; ---- 两个键都已有:不问,直接应用 ----
    mov esi, k_console_ctrl
    call rc_get
    test eax, eax
    jz .ask
    mov esi, k_console_charset
    call rc_get
    test eax, eax
    jz .ask
    call tty_rc_apply
    jmp .out
.ask:
    ; ---- 问题 1:要不要控制字符 ----
    mov esi, msg_wiz_ctrl
    call term_print
    mov edi, tty_wiz_buf
    mov ecx, 16
    mov edx, TICK_HZ * 10              ; 10 秒(100 Hz)
    call tty_read_line_timeout
    mov esi, tty_wiz_buf
    call tty_parse_yn                  ; eax = 1/0/-1
    cmp eax, -1
    jne .q1_ok
    xor eax, eax
    cmp dword [vbe_ok], 0
    je .q1_ok
    mov eax, 1
.q1_ok:
    mov [tty_wiz_ctrl], eax
    ; ---- 问题 2:字符集 ----
    mov esi, msg_wiz_charset
    call term_print
    mov edi, tty_wiz_buf
    mov ecx, 16
    mov edx, TICK_HZ * 10
    call tty_read_line_timeout
    mov esi, tty_wiz_buf
    call tty_parse_au                  ; eax = 1(utf8)/0(ascii)/-1
    cmp eax, -1
    jne .q2_ok
    xor eax, eax
    cmp dword [vbe_ok], 0
    je .q2_ok
    mov eax, 1
.q2_ok:
    mov [tty_wiz_charset], eax
    ; ---- 写回 SYS/RC.CONF,再重新加载一次 ----
    call tty_rc_save
    call rc_load
    call tty_rc_apply
.out:
    popad
    ret

; tty_parse_yn:esi = 输入串 → eax = 1(y)/0(n)/-1(空或未知)
tty_parse_yn:
    push esi
.skip:
    cmp byte [esi], ' '
    jne .chk
    inc esi
    jmp .skip
.chk:
    mov al, [esi]
    cmp al, 'y'
    je .yes
    cmp al, 'Y'
    je .yes
    cmp al, 'n'
    je .no
    cmp al, 'N'
    je .no
    mov eax, -1
    pop esi
    ret
.yes:
    mov eax, 1
    pop esi
    ret
.no:
    xor eax, eax
    pop esi
    ret

; tty_parse_au:esi = 输入串 → eax = 1(utf8/u)/0(ascii/a)/-1(空或未知)
tty_parse_au:
    push esi
.skip:
    cmp byte [esi], ' '
    jne .chk
    inc esi
    jmp .skip
.chk:
    mov al, [esi]
    cmp al, 'u'
    je .u
    cmp al, 'U'
    je .u
    cmp al, 'a'
    je .a
    cmp al, 'A'
    je .a
    mov eax, -1
    pop esi
    ret
.u:
    mov eax, 1
    pop esi
    ret
.a:
    xor eax, eax
    pop esi
    ret

; tty_copy_z:esi = 0 结尾串 → 拷到 edi,edi 前进到末尾
tty_copy_z:
    push eax
.loop:
    mov al, [esi]
    test al, al
    jz .done
    mov [edi], al
    inc esi
    inc edi
    jmp .loop
.done:
    pop eax
    ret

; ---------------------------------------------------------------------------
;  tty_rc_save:把 console.ctrl / console.charset 追加进 SYS/RC.CONF
;  (FAT 写 API 是"整文件重写",所以先读出旧内容再追写;失败就只应用不落盘)
; ---------------------------------------------------------------------------
tty_rc_save:
    pushad
    mov eax, [fat_dir]
    mov [tty_rc_saved_dir], eax
    mov dword [fat_dir], 0
    ; ---- 解析 SYS/RC.CONF ----
    mov esi, tty_rc_fname
    call fat_path
    jc .restore
    mov [tty_rc_seg], eax
    ; ---- 读旧内容到 rc_buf(读不到就当空文件) ----
    mov esi, eax
    mov edi, rc_buf
    call fat_read_file
    cmp eax, -1
    jne .have_len
    xor eax, eax
.have_len:
    ; ---- edi 指到旧内容末尾 ----
    mov ecx, eax
    mov edi, rc_buf
    add edi, ecx
    test ecx, ecx
    jz .append
    mov al, [edi - 1]
    cmp al, 10
    je .append
    mov byte [edi], 10
    inc edi
.append:
    ; ---- console.ctrl=y|n ----
    mov esi, tty_rc_k_ctrl
    call tty_copy_z
    mov al, 'n'
    cmp dword [tty_wiz_ctrl], 0
    je .ctrl_val
    mov al, 'y'
.ctrl_val:
    mov [edi], al
    inc edi
    mov byte [edi], 10
    inc edi
    ; ---- console.charset=utf8|ascii ----
    mov esi, tty_rc_k_charset
    call tty_copy_z
    mov esi, tty_rc_v_ascii
    cmp dword [tty_wiz_charset], 0
    je .cs_val
    mov esi, tty_rc_v_utf8
.cs_val:
    call tty_copy_z
    mov byte [edi], 10
    inc edi
    ; ---- 回写整个文件 ----
    mov ecx, edi
    sub ecx, rc_buf
    mov esi, [tty_rc_seg]
    mov edi, rc_buf
    call fat_write_file
.restore:
    mov eax, [tty_rc_saved_dir]
    mov [fat_dir], eax
    popad
    ret

; ---------------------------------------------------------------------------
;  tty_rc_apply:从 rc_get 读 console.ctrl / console.charset 并应用
; ---------------------------------------------------------------------------
tty_rc_apply:
    pushad
    ; ---- console.ctrl:y/Y=开,n/N=关,其它不动 ----
    mov esi, k_console_ctrl
    call rc_get
    test eax, eax
    jz .charset
    mov al, [eax]
    cmp al, '"'                        ; rc_parse 一般已去引号,这里兜个底
    jne .ctrl_ch
    mov al, [eax + 1]
.ctrl_ch:
    cmp al, 'y'
    je .ctrl_on
    cmp al, 'Y'
    je .ctrl_on
    cmp al, 'n'
    je .ctrl_off
    cmp al, 'N'
    je .ctrl_off
    jmp .charset
.ctrl_on:
    mov dword [tty_ctrl_on], 1
    jmp .charset
.ctrl_off:
    mov dword [tty_ctrl_on], 0
.charset:
    ; ---- console.charset:u/U=utf8,a/A=ascii,其它不动 ----
    mov esi, k_console_charset
    call rc_get
    test eax, eax
    jz .out
    mov al, [eax]
    cmp al, '"'
    jne .cs_ch
    mov al, [eax + 1]
.cs_ch:
    cmp al, 'u'
    je .cs_utf8
    cmp al, 'U'
    je .cs_utf8
    cmp al, 'a'
    je .cs_ascii
    cmp al, 'A'
    je .cs_ascii
    jmp .out
.cs_utf8:
    mov dword [tty_utf8], 1
    jmp .out
.cs_ascii:
    mov dword [tty_utf8], 0
.out:
    popad
    ret

; ===========================================================================
;  shell 的 tty 命令:调试/演示控制字符与字符集开关
;     tty                      显示当前状态
;     tty on|off               控制字符解释开/关
;     tty ascii|utf8           字符集切换
;     tty esc                  发一串 ANSI 转义:清屏、定位、写 "ESC-OK"
; ===========================================================================
cmd_tty:
    pushad
    mov esi, [cmd_arg]
    cmp byte [esi], 0
    je .show
    call usbd_first_word
    test ecx, ecx
    jz .usage
    mov edx, n_tty_on
    call str_eq
    test eax, eax
    jnz .set_on
    mov esi, [cmd_arg]
    call usbd_first_word
    mov edx, n_tty_off
    call str_eq
    test eax, eax
    jnz .set_off
    mov esi, [cmd_arg]
    call usbd_first_word
    mov edx, n_tty_ascii
    call str_eq
    test eax, eax
    jnz .set_ascii
    mov esi, [cmd_arg]
    call usbd_first_word
    mov edx, n_tty_utf8
    call str_eq
    test eax, eax
    jnz .set_utf8
    mov esi, [cmd_arg]
    call usbd_first_word
    mov edx, n_tty_esc
    call str_eq
    test eax, eax
    jnz .emit_esc
    jmp .usage
.set_on:
    mov dword [tty_ctrl_on], 1
    jmp .show
.set_off:
    mov dword [tty_ctrl_on], 0
    jmp .show
.set_ascii:
    mov dword [tty_utf8], 0
    jmp .show
.set_utf8:
    mov dword [tty_utf8], 1
    jmp .show
.emit_esc:
    mov esi, msg_tty_esc
    call term_print
    jmp .done
.usage:
    mov esi, msg_tty_usage
    call term_print
    jmp .done
.show:
    call tty_print_state
.done:
    popad
    ret

tty_print_state:
    pushad
    mov esi, msg_tty_s_ctrl
    call term_print
    cmp dword [tty_ctrl_on], 0
    je .ctrl_off
    mov esi, msg_on
    jmp .ctrl_done
.ctrl_off:
    mov esi, msg_off
.ctrl_done:
    call term_print
    mov esi, msg_tty_s_charset
    call term_print
    cmp dword [tty_utf8], 0
    je .cs_ascii
    mov esi, msg_utf8
    jmp .cs_done
.cs_ascii:
    mov esi, msg_ascii
.cs_done:
    call term_print
    mov esi, msg_tty_s_size
    call term_print
    mov eax, [tty_cols]
    call term_print_dec
    mov al, 'x'
    call term_putc
    mov eax, [tty_rows]
    call term_print_dec
    mov esi, msg_tty_s_end
    call term_print
    popad
    ret

; ===========================================================================
;  数据
; ===========================================================================
; ---- 状态 ----
tty_cols        dd 80                  ; 每行字符格(term_size 给,图形 100)
tty_rows        dd 25                  ; 行数
tty_ctrl_on     dd 1                   ; console.ctrl:1=解释 ANSI
tty_utf8        dd 1                   ; console.charset:1=utf8 / 0=ascii
tty_echo        dd 1                   ; 行规程回显
tty_canon       dd 1                   ; 规范模式(行缓冲)
tty_isig        dd 1                   ; Ctrl-C 产生中断
tty_attr        dd 0x07                ; 当前 SGR 属性(ANSI 模式)
tty_esc_state   db TTY_ESC_NONE
tty_last_vowel  db 0                   ; ー 长音用的"前一个元音"
tty_csi_n       dd 0
tty_csi_cur     dd 0
tty_csi_params  times TTY_CSI_MAX_PARAMS dd 0
tty_tmp_row     dd 0
tty_tmp_col     dd 0
tty_tmp_n       dd 0
tty_tmp_vowel   dd 0
tty_tmp_ch      dd 0
tty_tmp_ch2     dd 0
tty_sgr_attr    dd 0
tty_map_cp      dd 0
; ---- 行规程状态 ----
tr_buf          dd 0
tr_max          dd 0
tr_len          dd 0
tr_timeout      dd 0
tr_deadline     dd 0
tr_echo         dd 1
tty_chan        dd 0                   ; tty 睡眠通道(键盘 IRQ 唤醒)

; ---- 程序注入输入用的 256 B 环 ----
tty_ring        times 256 db 0
tty_ring_head   dd 0
tty_ring_tail   dd 0
; ---- SGR 颜色映射:ANSI 色号 → VGA 属性位(前景/背景) ----
tty_ansi_fg     db 0, 4, 2, 6, 1, 5, 3, 7
tty_ansi_bg     db 0x00, 0x40, 0x20, 0x60, 0x10, 0x50, 0x30, 0x70
; ---- 开机向导 ----
msg_wiz_ctrl    db 'Is your console enable with control-characters? y/n: ', 0
msg_wiz_charset db 'Which types of output do you want? ascii/utf8 (a/u): ', 0
k_console_ctrl  db 'console.ctrl', 0
k_console_charset db 'console.charset', 0
tty_rc_fname    db 'SYS/RC.CONF', 0
tty_rc_k_ctrl   db 'console.ctrl=', 0
tty_rc_k_charset db 'console.charset=', 0
tty_rc_v_ascii  db 'ascii', 0
tty_rc_v_utf8   db 'utf8', 0
tty_rc_saved_dir dd 0
tty_rc_seg      dd 0
tty_wiz_buf     times 16 db 0
tty_wiz_ctrl    dd 0
tty_wiz_charset dd 0

; ---- 命令名 ----
n_tty           db 'tty', 0
n_tty_on        db 'on', 0
n_tty_off       db 'off', 0
n_tty_ascii     db 'ascii', 0
n_tty_utf8      db 'utf8', 0
n_tty_esc       db 'esc', 0
; ---- 消息 ----
msg_tty_usage   db 'tty: usage: tty [on|off] [ascii|utf8] [esc]', 13, 10, 0
msg_tty_esc     db 27, '[2J', 27, '[1;1H', 'ESC-OK', 13, 10, 0
msg_tty_s_ctrl  db 'tty: ctrl=', 0
msg_tty_s_charset db ' charset=', 0
msg_tty_s_size  db ' size=', 0
msg_tty_s_end   db 13, 10, 0
msg_on          db 'on', 0
msg_off         db 'off', 0
msg_utf8        db 'utf8', 0
msg_ascii       db 'ascii', 0

; ---------------------------------------------------------------------------
;  ASCII 降级表:码位 → 罗马字/替代串(按码位升序;dd 码位, dd 串指针;0,0 结束)
;  由 tools 里的脚本生成后贴入(平假名/片假名全表 + 常见希腊/数学/标点)。
; ---------------------------------------------------------------------------
; ---- ASCII 降级映射表:码位 → 罗马字/替代串(dd 码位, dd 串指针; 0,0 结束) ----
tty_ascii_tab:
    dd 0x00B0, tty_s_0
    dd 0x00B7, tty_s_1
    dd 0x03A9, tty_s_2
    dd 0x03C9, tty_s_3
    dd 0x2025, tty_s_4
    dd 0x2026, tty_s_5
    dd 0x2200, tty_s_6
    dd 0x3001, tty_s_7
    dd 0x3002, tty_s_1
    dd 0x300C, tty_s_8
    dd 0x300D, tty_s_8
    dd 0x300E, tty_s_8
    dd 0x300F, tty_s_8
    dd 0x301C, tty_s_9
    dd 0x3041, tty_s_10
    dd 0x3042, tty_s_10
    dd 0x3043, tty_s_11
    dd 0x3044, tty_s_11
    dd 0x3045, tty_s_12
    dd 0x3046, tty_s_12
    dd 0x3047, tty_s_13
    dd 0x3048, tty_s_13
    dd 0x3049, tty_s_14
    dd 0x304A, tty_s_14
    dd 0x304B, tty_s_15
    dd 0x304C, tty_s_16
    dd 0x304D, tty_s_17
    dd 0x304E, tty_s_18
    dd 0x304F, tty_s_19
    dd 0x3050, tty_s_20
    dd 0x3051, tty_s_21
    dd 0x3052, tty_s_22
    dd 0x3053, tty_s_23
    dd 0x3054, tty_s_24
    dd 0x3055, tty_s_25
    dd 0x3056, tty_s_26
    dd 0x3057, tty_s_27
    dd 0x3058, tty_s_28
    dd 0x3059, tty_s_29
    dd 0x305A, tty_s_30
    dd 0x305B, tty_s_31
    dd 0x305C, tty_s_32
    dd 0x305D, tty_s_33
    dd 0x305E, tty_s_34
    dd 0x305F, tty_s_35
    dd 0x3060, tty_s_36
    dd 0x3061, tty_s_37
    dd 0x3062, tty_s_28
    dd 0x3063, tty_s_38
    dd 0x3064, tty_s_39
    dd 0x3065, tty_s_30
    dd 0x3066, tty_s_40
    dd 0x3067, tty_s_41
    dd 0x3068, tty_s_42
    dd 0x3069, tty_s_43
    dd 0x306A, tty_s_44
    dd 0x306B, tty_s_45
    dd 0x306C, tty_s_46
    dd 0x306D, tty_s_47
    dd 0x306E, tty_s_48
    dd 0x306F, tty_s_49
    dd 0x3070, tty_s_50
    dd 0x3071, tty_s_51
    dd 0x3072, tty_s_52
    dd 0x3073, tty_s_53
    dd 0x3074, tty_s_54
    dd 0x3075, tty_s_55
    dd 0x3076, tty_s_56
    dd 0x3077, tty_s_57
    dd 0x3078, tty_s_58
    dd 0x3079, tty_s_59
    dd 0x307A, tty_s_60
    dd 0x307B, tty_s_61
    dd 0x307C, tty_s_62
    dd 0x307D, tty_s_63
    dd 0x307E, tty_s_64
    dd 0x307F, tty_s_65
    dd 0x3080, tty_s_66
    dd 0x3081, tty_s_67
    dd 0x3082, tty_s_68
    dd 0x3083, tty_s_69
    dd 0x3084, tty_s_69
    dd 0x3085, tty_s_70
    dd 0x3086, tty_s_70
    dd 0x3087, tty_s_71
    dd 0x3088, tty_s_71
    dd 0x3089, tty_s_72
    dd 0x308A, tty_s_73
    dd 0x308B, tty_s_74
    dd 0x308C, tty_s_75
    dd 0x308D, tty_s_76
    dd 0x308E, tty_s_77
    dd 0x308F, tty_s_77
    dd 0x3090, tty_s_11
    dd 0x3091, tty_s_13
    dd 0x3092, tty_s_14
    dd 0x3093, tty_s_78
    dd 0x3094, tty_s_79
    dd 0x3095, tty_s_15
    dd 0x3096, tty_s_21
    dd 0x309D, tty_s_38
    dd 0x309E, tty_s_38
    dd 0x30A1, tty_s_10
    dd 0x30A2, tty_s_10
    dd 0x30A3, tty_s_11
    dd 0x30A4, tty_s_11
    dd 0x30A5, tty_s_12
    dd 0x30A6, tty_s_12
    dd 0x30A7, tty_s_13
    dd 0x30A8, tty_s_13
    dd 0x30A9, tty_s_14
    dd 0x30AA, tty_s_14
    dd 0x30AB, tty_s_15
    dd 0x30AC, tty_s_16
    dd 0x30AD, tty_s_17
    dd 0x30AE, tty_s_18
    dd 0x30AF, tty_s_19
    dd 0x30B0, tty_s_20
    dd 0x30B1, tty_s_21
    dd 0x30B2, tty_s_22
    dd 0x30B3, tty_s_23
    dd 0x30B4, tty_s_24
    dd 0x30B5, tty_s_25
    dd 0x30B6, tty_s_26
    dd 0x30B7, tty_s_27
    dd 0x30B8, tty_s_28
    dd 0x30B9, tty_s_29
    dd 0x30BA, tty_s_30
    dd 0x30BB, tty_s_31
    dd 0x30BC, tty_s_32
    dd 0x30BD, tty_s_33
    dd 0x30BE, tty_s_34
    dd 0x30BF, tty_s_35
    dd 0x30C0, tty_s_36
    dd 0x30C1, tty_s_37
    dd 0x30C2, tty_s_28
    dd 0x30C3, tty_s_38
    dd 0x30C4, tty_s_39
    dd 0x30C5, tty_s_30
    dd 0x30C6, tty_s_40
    dd 0x30C7, tty_s_41
    dd 0x30C8, tty_s_42
    dd 0x30C9, tty_s_43
    dd 0x30CA, tty_s_44
    dd 0x30CB, tty_s_45
    dd 0x30CC, tty_s_46
    dd 0x30CD, tty_s_47
    dd 0x30CE, tty_s_48
    dd 0x30CF, tty_s_49
    dd 0x30D0, tty_s_50
    dd 0x30D1, tty_s_51
    dd 0x30D2, tty_s_52
    dd 0x30D3, tty_s_53
    dd 0x30D4, tty_s_54
    dd 0x30D5, tty_s_55
    dd 0x30D6, tty_s_56
    dd 0x30D7, tty_s_57
    dd 0x30D8, tty_s_58
    dd 0x30D9, tty_s_59
    dd 0x30DA, tty_s_60
    dd 0x30DB, tty_s_61
    dd 0x30DC, tty_s_62
    dd 0x30DD, tty_s_63
    dd 0x30DE, tty_s_64
    dd 0x30DF, tty_s_65
    dd 0x30E0, tty_s_66
    dd 0x30E1, tty_s_67
    dd 0x30E2, tty_s_68
    dd 0x30E3, tty_s_69
    dd 0x30E4, tty_s_69
    dd 0x30E5, tty_s_70
    dd 0x30E6, tty_s_70
    dd 0x30E7, tty_s_71
    dd 0x30E8, tty_s_71
    dd 0x30E9, tty_s_72
    dd 0x30EA, tty_s_73
    dd 0x30EB, tty_s_74
    dd 0x30EC, tty_s_75
    dd 0x30ED, tty_s_76
    dd 0x30EE, tty_s_77
    dd 0x30EF, tty_s_77
    dd 0x30F0, tty_s_11
    dd 0x30F1, tty_s_13
    dd 0x30F2, tty_s_14
    dd 0x30F3, tty_s_78
    dd 0x30F4, tty_s_79
    dd 0x30F5, tty_s_15
    dd 0x30F6, tty_s_21
    dd 0x30F7, tty_s_80
    dd 0x30F8, tty_s_81
    dd 0x30F9, tty_s_82
    dd 0x30FA, tty_s_83
    dd 0x30FB, tty_s_14
    dd 0x30FD, tty_s_38
    dd 0x30FE, tty_s_38
    dd 0, 0

tty_ascii_strs:
tty_s_0: db 'd', 'e', 'g', 0
tty_s_1: db '.', 0
tty_s_2: db 'O', 0
tty_s_3: db 'w', 0
tty_s_4: db '.', '.', 0
tty_s_5: db '.', '.', '.', 0
tty_s_6: db 'A', 0
tty_s_7: db ',', 0
tty_s_8: db '"', 0
tty_s_9: db '~', 0
tty_s_10: db 'a', 0
tty_s_11: db 'i', 0
tty_s_12: db 'u', 0
tty_s_13: db 'e', 0
tty_s_14: db 'o', 0
tty_s_15: db 'k', 'a', 0
tty_s_16: db 'g', 'a', 0
tty_s_17: db 'k', 'i', 0
tty_s_18: db 'g', 'i', 0
tty_s_19: db 'k', 'u', 0
tty_s_20: db 'g', 'u', 0
tty_s_21: db 'k', 'e', 0
tty_s_22: db 'g', 'e', 0
tty_s_23: db 'k', 'o', 0
tty_s_24: db 'g', 'o', 0
tty_s_25: db 's', 'a', 0
tty_s_26: db 'z', 'a', 0
tty_s_27: db 's', 'h', 'i', 0
tty_s_28: db 'j', 'i', 0
tty_s_29: db 's', 'u', 0
tty_s_30: db 'z', 'u', 0
tty_s_31: db 's', 'e', 0
tty_s_32: db 'z', 'e', 0
tty_s_33: db 's', 'o', 0
tty_s_34: db 'z', 'o', 0
tty_s_35: db 't', 'a', 0
tty_s_36: db 'd', 'a', 0
tty_s_37: db 'c', 'h', 'i', 0
tty_s_38: db 0
tty_s_39: db 't', 's', 'u', 0
tty_s_40: db 't', 'e', 0
tty_s_41: db 'd', 'e', 0
tty_s_42: db 't', 'o', 0
tty_s_43: db 'd', 'o', 0
tty_s_44: db 'n', 'a', 0
tty_s_45: db 'n', 'i', 0
tty_s_46: db 'n', 'u', 0
tty_s_47: db 'n', 'e', 0
tty_s_48: db 'n', 'o', 0
tty_s_49: db 'h', 'a', 0
tty_s_50: db 'b', 'a', 0
tty_s_51: db 'p', 'a', 0
tty_s_52: db 'h', 'i', 0
tty_s_53: db 'b', 'i', 0
tty_s_54: db 'p', 'i', 0
tty_s_55: db 'f', 'u', 0
tty_s_56: db 'b', 'u', 0
tty_s_57: db 'p', 'u', 0
tty_s_58: db 'h', 'e', 0
tty_s_59: db 'b', 'e', 0
tty_s_60: db 'p', 'e', 0
tty_s_61: db 'h', 'o', 0
tty_s_62: db 'b', 'o', 0
tty_s_63: db 'p', 'o', 0
tty_s_64: db 'm', 'a', 0
tty_s_65: db 'm', 'i', 0
tty_s_66: db 'm', 'u', 0
tty_s_67: db 'm', 'e', 0
tty_s_68: db 'm', 'o', 0
tty_s_69: db 'y', 'a', 0
tty_s_70: db 'y', 'u', 0
tty_s_71: db 'y', 'o', 0
tty_s_72: db 'r', 'a', 0
tty_s_73: db 'r', 'i', 0
tty_s_74: db 'r', 'u', 0
tty_s_75: db 'r', 'e', 0
tty_s_76: db 'r', 'o', 0
tty_s_77: db 'w', 'a', 0
tty_s_78: db 'n', 0
tty_s_79: db 'v', 'u', 0
tty_s_80: db 'v', 'a', 0
tty_s_81: db 'v', 'i', 0
tty_s_82: db 'v', 'e', 0
tty_s_83: db 'v', 'o', 0
