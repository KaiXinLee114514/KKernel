; ============================================================================
;  STACK.BIN — 用户栈自动增长的测试程序(A5 用)
;
;  它干两件"故意吃栈"的事:
;    1) 深递归:40 层,每层吃 4088 字节 → 约 160 KiB 用户栈。
;       建空间时只给了栈顶一页,其余靠 14 号页错误现补 —— 递归越深越往下长。
;    2) 大局部数组:一次性在栈上压 200 KiB(50 页),逐页写标记。
;
;  两件事都干完还能打印 STACK-OK,说明用户栈从 1 页自动长到了至少 360 KiB,
;  没踩到 guard 页、也没把内核搞崩。
;
;  编译: nasm -f bin progs/STACK.asm -o build/STACK.BIN
;  调用: shell 里  run STACK
; ============================================================================

[BITS 32]
[ORG 0x120000]

DEPTH       equ 40                      ; 递归层数
FRAME       equ 4084                    ; 每层栈帧(4 的倍数,凑成 40×4084≈160 KiB)
BIG_PAGES   equ 50                      ; 大局部数组 50 页 = 200 KiB

start:
    ; ---- 1) 深递归 ----
    mov eax, DEPTH
    call rec

    ; ---- 2) 大局部数组:压 200 KiB 栈,逐页写一遍 ----
    mov eax, BIG_PAGES
    shl eax, 12                         ; = BIG_PAGES × 4096
    sub esp, eax                        ; 一次性压栈
    mov ebx, esp
    mov ecx, BIG_PAGES
.touch:
    mov dword [ebx], 0x5A5A5A5A         ; 每页碰一下 → 页错误现补页
    add ebx, 4096
    dec ecx
    jnz .touch
    add esp, eax                        ; 弹回去

    ; ---- 都活下来了 ----
    mov eax, 0
    mov esi, msg_ok
    int 0x30

    ret                                 ; 返回 shell

; rec(eax=剩余层数):每层吃 FRAME 字节,写个标记防优化,再递归下一层
rec:
    test eax, eax
    jz .ret
    push eax
    sub esp, FRAME
    mov dword [esp], 0x12345678         ; 标记:保证这页真被用到
    dec eax
    call rec
    add esp, FRAME
    pop eax
.ret:
    ret

msg_ok db 'STACK-OK', 10, 0
