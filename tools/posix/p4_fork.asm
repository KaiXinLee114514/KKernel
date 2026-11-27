; ---------------------------------------------------------------------------
;  POSIX P4 测试程序:进程调用 fork(2) / getpid(20) / wait4(114)
;    1. getpid() 拿到父 pid
;    2. fork():子进程打印 "p4-fork: child" 后 exit(42);父进程 wait4 等它
;    3. 父进程校验:wait4 返回子 pid、status>>8 == 42、getpid() 没变
;    4. 打印 "p4-fork: ok" 后 exit(0)
;  输出正常:  p4-fork: child
;             p4-fork: ok
;  失败:      p4-fork: FAIL   退出码 1
;  说明:ELF 的 .text 段是只读的,局部变量都放用户栈(fork 后 COW 复制,互不影响)。
; ---------------------------------------------------------------------------
BITS 32

section .text
global _start
_start:
    sub esp, 32                         ; 局部:[esp+0]=父pid [esp+4]=子pid [esp+8]=status
    ; ---- getpid(20):应 > 0 ----
    mov eax, 20
    int 0x80
    test eax, eax
    jle .fail
    mov [esp + 0], eax                  ; 父 pid

    ; ---- fork(2) ----
    mov eax, 2
    int 0x80
    cmp eax, -1
    je .fail
    test eax, eax
    jz .child                           ; 子进程:eax = 0
    mov [esp + 4], eax                  ; 父进程:保存子 pid

    ; ---- wait4(child_pid, &status, 0, NULL) ----
    mov eax, 114
    mov ebx, [esp + 4]
    lea ecx, [esp + 8]
    xor edx, edx
    xor esi, esi
    int 0x80
    cmp eax, [esp + 4]                  ; 应返回子 pid
    jne .fail
    ; status>>8 & 0xFF 应 == 42(子进程 exit(42))
    mov ebx, [esp + 8]
    shr ebx, 8
    and ebx, 0xFF
    cmp ebx, 42
    jne .fail
    ; ---- getpid 仍是父 pid ----
    mov eax, 20
    int 0x80
    cmp eax, [esp + 0]
    jne .fail

    ; ---- 打印 "p4-fork: ok\n" ----
    mov eax, 4
    mov ebx, 1
    lea ecx, [msg_ok]
    mov edx, msg_ok_len
    int 0x80
    xor ebx, ebx
    mov eax, 1
    int 0x80
    hlt

.child:
    ; ---- 子进程:getpid() 应 > 0 且不同于父 pid ----
    mov eax, 20
    int 0x80
    test eax, eax
    jle .child_fail
    ; 打印 "p4-fork: child\n"
    mov eax, 4
    mov ebx, 1
    lea ecx, [msg_child]
    mov edx, msg_child_len
    int 0x80
    mov eax, 1
    mov ebx, 42                         ; 退出码 42,父进程校验
    int 0x80
    hlt

.child_fail:
    mov eax, 4
    mov ebx, 1
    lea ecx, [msg_fail]
    mov edx, msg_fail_len
    int 0x80
    mov eax, 1
    mov ebx, 1
    int 0x80
    hlt

.fail:
    mov eax, 4
    mov ebx, 1
    lea ecx, [msg_fail]
    mov edx, msg_fail_len
    int 0x80
    mov eax, 1
    mov ebx, 1
    int 0x80
    hlt

section .text
msg_child    db "p4-fork: child", 10
msg_child_len equ $ - msg_child
msg_ok       db "p4-fork: ok", 10
msg_ok_len   equ $ - msg_ok
msg_fail     db "p4-fork: FAIL", 10
msg_fail_len equ $ - msg_fail
