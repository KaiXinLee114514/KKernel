; ============================================================================
;  KKernel x86-64 — 中断/异常/PIC/PIT/键盘
;
;  长模式下的 IDT 门是 16 字节:offset 15:0 | selector | IST/type_attr |
;  offset 31:16 | offset 63:32 | 保留。异常处理要能区分"CPU 推了错误码"和
;  "没推"两种情况 —— 没推的补一个 0,这样两者进来时的栈布局一致:
;
;      [rsp] = 向量号(我们推的)  [rsp+8] = 错误码(CPU 推的或补的 0)
;      [rsp+16] = RIP  [rsp+24] = CS  [rsp+32] = RFLAGS
;
;  异常打印 vector/err/RIP/CS 后停机;IRQ0 = PIT 100 Hz(tick),IRQ1 = 键盘。
; ============================================================================

; ---------------------------------------------------------------------------
;  异常 stub(0..31)
; ---------------------------------------------------------------------------
%assign vec 0
%rep 32
%if (vec == 8) || ((vec >= 10) && (vec <= 14)) || (vec == 17) || (vec == 21) || (vec == 29) || (vec == 30)
exc_%+vec:
    push qword vec                  ; CPU 已经推了错误码
%else
exc_%+vec:
    push qword 0                    ; 补一个假错误码
    push qword vec
%endif
    jmp exc_common
%assign vec vec+1
%endrep

; ---------------------------------------------------------------------------
;  exc_common:保存现场 → 打印 → 停机
; ---------------------------------------------------------------------------
exc_common:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    ; 15 个寄存器 = 120 字节
    mov rdi, [rsp + 120]            ; vector
    mov rsi, [rsp + 128]            ; error
    mov rdx, [rsp + 136]            ; RIP
    mov rcx, [rsp + 144]            ; CS
    call exc_halt
.hang:
    cli
    hlt
    jmp .hang

; ---------------------------------------------------------------------------
;  exc_halt:红色打印异常现场(rdi=vector,rsi=err,rdx=rip,rcx=cs)
; ---------------------------------------------------------------------------
exc_halt:
    push rsi                        ; 栈:[rsp]=cs [rsp+8]=rip [rsp+16]=err
    push rdx
    push rcx
    mov dword [con_fg], CON_COLOR_RED
    lea rsi, [msg_exc]
    call con_print
    mov eax, edi
    call con_print_dec32
    lea rsi, [msg_exc_err]
    call con_print
    mov rax, [rsp + 16]             ; error
    call con_print_hex32
    lea rsi, [msg_exc_rip]
    call con_print
    mov rax, [rsp + 8]              ; RIP
    call con_print_hex32
    lea rsi, [msg_exc_cs]
    call con_print
    mov rax, [rsp + 0]              ; CS
    call con_print_hex32
    call con_newline
    lea rsi, [msg_exc_stop]
    call con_print
.forever:
    cli
    hlt
    jmp .forever

; ---------------------------------------------------------------------------
;  默认 stub:不该发生的中断
; ---------------------------------------------------------------------------
irq_default:
    cli
    hlt
    jmp irq_default

; ---------------------------------------------------------------------------
;  IRQ stub:IRQ0=PIT, IRQ1=键盘(主片,remap 到 0x20/0x21)
; ---------------------------------------------------------------------------
irq0:
    push qword 0
    push qword 0x20
    jmp irq_common

irq1:
    push qword 0
    push qword 0x21
    jmp irq_common

irq_common:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov rdi, [rsp + 120]            ; vector
    call irq_handler
    mov al, 0x20                    ; EOI(都挂在主片)
    out 0x20, al
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    add rsp, 16
    iretq

; ---------------------------------------------------------------------------
;  irq_handler:rdi = 向量号
; ---------------------------------------------------------------------------
irq_handler:
    cmp edi, 0x20
    je .timer
    cmp edi, 0x21
    je .kbd
    ret
.timer:
    inc qword [ticks]
    ret
.kbd:
    in al, 0x60
    call kbd_translate
    test al, al
    jz .kbd_done
    call kbd_put
.kbd_done:
    ret

; ---------------------------------------------------------------------------
;  idt_init:填 256 个门(默认 irq_default,再覆盖异常和 IRQ)
; ---------------------------------------------------------------------------
idt_init:
    push rdi
    push rax
    push rbx
    ; 先全部填成 irq_default
    xor edi, edi
.all_loop:
    mov rax, irq_default
    call idt_set
    inc edi
    cmp edi, 256
    jb .all_loop
    ; 异常 0..31
    %assign vec 0
    %rep 32
    mov rax, exc_%+vec
    mov rdi, vec
    call idt_set
    %assign vec vec+1
    %endrep
    ; IRQ0/IRQ1
    mov rax, irq0
    mov edi, 0x20
    call idt_set
    mov rax, irq1
    mov edi, 0x21
    call idt_set
    lidt [idt_desc]
    pop rbx
    pop rax
    pop rdi
    ret

; ---------------------------------------------------------------------------
;  idt_set:rax = 处理函数偏移,rdi = 向量号
; ---------------------------------------------------------------------------
idt_set:
    push rbx
    lea rbx, [idt_table]
    mov rcx, rdi
    shl rcx, 4
    add rbx, rcx
    mov word [rbx + 0], ax
    shr rax, 16
    mov word [rbx + 6], ax
    shr rax, 16
    mov dword [rbx + 8], eax
    mov word [rbx + 2], 0x08        ; 代码段选择子
    mov byte [rbx + 4], 0           ; IST = 0
    mov byte [rbx + 5], 0x8E        ; P=1 DPL0 中断门
    pop rbx
    ret

; ---------------------------------------------------------------------------
;  pic_remap:8259 重映射到 0x20/0x28,只放开 IRQ0/IRQ1
; ---------------------------------------------------------------------------
pic_remap:
    push rax
    mov al, 0x11
    out 0x20, al
    out 0xA0, al
    mov al, 0x20
    out 0x21, al
    mov al, 0x28
    out 0xA1, al
    mov al, 0x04
    out 0x21, al
    mov al, 0x02
    out 0xA1, al
    mov al, 0x01
    out 0x21, al
    out 0xA1, al
    mov al, 0xFC                    ; 只留 IRQ0/IRQ1
    out 0x21, al
    mov al, 0xFF
    out 0xA1, al
    pop rax
    ret

; ---------------------------------------------------------------------------
;  pit_init:通道 0,100 Hz(1.193182 MHz / 100 = 11932)
; ---------------------------------------------------------------------------
pit_init:
    push rax
    mov al, 0x36
    out 0x43, al
    mov eax, 11932
    out 0x40, al
    mov al, ah
    out 0x40, al
    pop rax
    ret

; ---------------------------------------------------------------------------
;  kbd_drain:把 i8042 输出缓冲里的残留字节读掉(32 位内核可能留下)
; ---------------------------------------------------------------------------
kbd_drain:
    push rax
    push rcx
    mov ecx, 64                     ; 最多 64 字节,防止死循环
.loop:
    in al, 0x64
    test al, 1
    jz .done
    in al, 0x60
    dec ecx
    jnz .loop
.done:
    pop rcx
    pop rax
    ret
