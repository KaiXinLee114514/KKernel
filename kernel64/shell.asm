; ============================================================================
;  KKernel x86-64 — 最小 shell
;
;  命令:help / info / echo <text> / clear / ticks / reboot
;  输入靠 IRQ1 键盘中断把字符塞进环形缓冲,主循环 hlt 等键。
; ============================================================================

; ---------------------------------------------------------------------------
;  shell_main:提示符 → 读一行 → 执行
; ---------------------------------------------------------------------------
shell_main:
.loop:
    mov dword [con_fg], CON_COLOR_GREEN
    lea rsi, [msg_prompt]
    call con_print
    mov dword [con_fg], CON_COLOR_WHITE
    mov dword [sh_len], 0
.line:
    hlt
    call kbd_getc
    jc .line
    cmp al, 10
    je .enter
    cmp al, 8
    je .backspace
    cmp al, 32
    jb .line
    cmp al, 127
    jae .line
    mov ecx, [sh_len]
    cmp ecx, 250
    jae .line
    mov [sh_line + rcx], al
    inc dword [sh_len]
    call con_putc
    jmp .line
.backspace:
    mov ecx, [sh_len]
    test ecx, ecx
    jz .line
    dec ecx
    mov [sh_len], ecx
    mov al, 8
    call con_putc
    jmp .line
.enter:
    mov al, 10
    call con_putc
    mov ecx, [sh_len]
    mov byte [sh_line + rcx], 0
    call shell_execute
    jmp .loop

; ---------------------------------------------------------------------------
;  shell_execute:解析并执行 sh_line
; ---------------------------------------------------------------------------
shell_execute:
    push rbx
    push rsi
    push rdi
    lea rsi, [sh_line]
.skip_sp:
    cmp byte [rsi], ' '
    jne .have_cmd
    inc rsi
    jmp .skip_sp
.have_cmd:
    cmp byte [rsi], 0
    je .done
    mov rbx, rsi                    ; 命令词起点
.find_end:
    mov al, [rsi]
    test al, al
    jz .no_args
    cmp al, ' '
    je .end_word
    inc rsi
    jmp .find_end
.end_word:
    mov byte [rsi], 0               ; 截断命令词
    inc rsi
.skip_sp2:
    cmp byte [rsi], ' '
    jne .dispatch
    inc rsi
    jmp .skip_sp2
.no_args:
    xor esi, esi
.dispatch:
    lea rdi, [name_help]
    call str_eq64
    test eax, eax
    jnz .help
    lea rdi, [name_info]
    call str_eq64
    test eax, eax
    jnz .info
    lea rdi, [name_echo]
    call str_eq64
    test eax, eax
    jnz .echo
    lea rdi, [name_clear]
    call str_eq64
    test eax, eax
    jnz .clear
    lea rdi, [name_ticks]
    call str_eq64
    test eax, eax
    jnz .ticks
    lea rdi, [name_reboot]
    call str_eq64
    test eax, eax
    jnz .reboot
    ; ---- 未知命令 ----
    lea rsi, [msg_unknown]
    call con_print
    mov rsi, rbx
    call con_print
    call con_newline
    jmp .done

.help:
    lea rsi, [msg_help]
    call con_print
    jmp .done
.echo:
    test rsi, rsi
    jz .echo_nl
    mov rsi, rsi
    call con_print
.echo_nl:
    call con_newline
    jmp .done
.clear:
    call con_clear
    jmp .done
.ticks:
    lea rsi, [msg_ticks]
    call con_print
    mov rax, [ticks]
    call con_print_dec64
    call con_newline
    jmp .done
.reboot:
    lea rsi, [msg_reboot]
    call con_print
    mov dx, 0xCF9
    mov al, 0x06
    out dx, al
    mov al, 0x0E
    out dx, al
.halt:
    cli
    hlt
    jmp .halt

.info:
    lea rsi, [msg_info]
    call con_print
    ; CPU 厂商(CPUID leaf 0:EBX,EDX,ECX 拼 12 字节)
    lea rsi, [msg_bi_cpu]
    call con_print
    xor eax, eax
    cpuid
    mov [vendor_buf + 0], ebx
    mov [vendor_buf + 4], edx
    mov [vendor_buf + 8], ecx
    mov byte [vendor_buf + 12], 0
    lea rsi, [vendor_buf]
    call con_print
    call con_newline
    ; CR0 / CR4 / EFER
    lea rsi, [msg_bi_cr0]
    call con_print
    mov rax, cr0
    call con_print_hex32
    lea rsi, [msg_bi_cr4]
    call con_print
    mov rax, cr4
    call con_print_hex32
    lea rsi, [msg_bi_efer]
    call con_print
    mov ecx, 0xC0000080
    rdmsr
    call con_print_hex32
    call con_newline
    ; PAE / LME
    lea rsi, [msg_info_pae]
    call con_print
    mov rax, cr4
    shr eax, 5
    and eax, 1
    call con_print_dec32
    lea rsi, [msg_info_lme]
    call con_print
    mov ecx, 0xC0000080
    rdmsr
    shr eax, 8
    and eax, 1
    call con_print_dec32
    call con_newline
    ; 内存
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
    ; 显示
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
    ; 本镜像
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
    ; 时钟
    lea rsi, [msg_info_ticks]
    call con_print
    mov rax, [ticks]
    call con_print_dec64
    call con_newline
    jmp .done

.done:
    pop rdi
    pop rsi
    pop rbx
    ret

; ---------------------------------------------------------------------------
;  str_eq64:rdi 与 rbx 两个 0 结尾字符串比较 → eax=1 相等 / 0 不等
; ---------------------------------------------------------------------------
str_eq64:
    push rdi
    push rbx
.loop:
    mov al, [rdi]
    mov cl, [rbx]
    cmp al, cl
    jne .no
    test al, al
    jz .yes
    inc rdi
    inc rbx
    jmp .loop
.no:
    xor eax, eax
    jmp .out
.yes:
    mov eax, 1
.out:
    pop rbx
    pop rdi
    ret

; ---------------------------------------------------------------------------
;  kbd_put:al = 字符 → 环形缓冲(满了就丢)
; ---------------------------------------------------------------------------
kbd_put:
    push rbx
    push rcx
    movzx ebx, al
    mov eax, [kbd_tail]
    lea ecx, [eax + 1]
    and ecx, 0xFF
    cmp ecx, [kbd_head]
    je .done
    mov [kbd_buf + rax], bl
    mov [kbd_tail], ecx
.done:
    pop rcx
    pop rbx
    ret

; ---------------------------------------------------------------------------
;  kbd_getc:取一个字符 → al;CF=1 表示没有(CF=0 表示取到了)
; ---------------------------------------------------------------------------
kbd_getc:
    mov eax, [kbd_head]
    cmp eax, [kbd_tail]
    je .empty
    push rbx
    mov ebx, eax
    lea edx, [eax + 1]
    and edx, 0xFF
    mov [kbd_head], edx
    movzx eax, byte [kbd_buf + rbx]
    pop rbx
    clc
    ret
.empty:
    stc
    ret

; ---------------------------------------------------------------------------
;  kbd_translate:al = set1 扫描码 → al = ASCII(0 = 忽略)
; ---------------------------------------------------------------------------
kbd_translate:
    cmp al, 0xE0
    je .skip_set
    cmp byte [kbd_skip], 0
    jne .skip_one
    cmp al, 0x2A
    je .shift_on
    cmp al, 0x36
    je .shift_on
    cmp al, 0xAA
    je .shift_off
    cmp al, 0xB6
    je .shift_off
    test al, 0x80
    jnz .none
    lea rbx, [kb_map_lower]
    cmp byte [kbd_shift], 0
    je .lookup
    lea rbx, [kb_map_shift]
.lookup:
    movzx eax, al
    cmp eax, 0x7F
    ja .none
    movzx eax, byte [rbx + rax]
    ret
.skip_set:
    mov byte [kbd_skip], 1
    xor eax, eax
    ret
.skip_one:
    mov byte [kbd_skip], 0
    xor eax, eax
    ret
.shift_on:
    mov byte [kbd_shift], 1
    xor eax, eax
    ret
.shift_off:
    mov byte [kbd_shift], 0
    xor eax, eax
    ret
.none:
    xor eax, eax
    ret
