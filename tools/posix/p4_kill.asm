; ---------------------------------------------------------------------------
;  POSIX P4 测试程序:kill(37) 最小信号集 KILL/TERM/INT/STOP/CONT
;    1. fork 一个子进程(它在用户态死循环,给父进程杀)
;    2. kill(pid, 0)   探测 → 0
;    3. kill(pid, 19)  SIGSTOP → 0;wait4(WUNTRACED) 拿到"停住"事件(status&0xFF == 0x7F)
;    4. kill(pid, 18)  SIGCONT → 0
;    5. kill(pid, 2)   SIGINT  → 0(只投 pending,不杀)
;    6. kill(pid, 999) 非法信号 → -EINVAL(22)
;    7. kill(999, 15)  不存在的 pid → -ESRCH(3)
;    8. kill(0, 15)    不支持的 pid 形式 → -ENOSYS(38)
;    9. kill(pid, 15)  SIGTERM → 0;wait4 拿到退出事件,(status>>8)&0xFF == 137
;   10. 打印 "p4-kill: ok" 后 exit(0)
;  失败:      p4-kill: FAIL   退出码 1
; ---------------------------------------------------------------------------
BITS 32

section .text
global _start
_start:
    sub esp, 32                 ; [esp+0]=子pid [esp+4]=status [esp+8]=pid
    ; ---- fork ----
    mov eax, 2
    int 0x80
    cmp eax, -1
    je .fail
    test eax, eax
    jz .child
    mov [esp + 0], eax

    ; ---- kill(pid, 0) 探测 ----
    mov eax, 37
    mov ebx, [esp + 0]
    xor ecx, ecx
    int 0x80
    test eax, eax
    jnz .fail

    ; ---- kill(pid, SIGSTOP=19) ----
    mov eax, 37
    mov ebx, [esp + 0]
    mov ecx, 19
    int 0x80
    test eax, eax
    jnz .fail

    ; ---- wait4(pid, &status, WUNTRACED=2, 0):应拿到停住事件 ----
    mov eax, 114
    mov ebx, [esp + 0]
    lea ecx, [esp + 4]
    mov edx, 2
    xor esi, esi
    int 0x80
    cmp eax, [esp + 0]
    jne .fail
    mov ebx, [esp + 4]
    and ebx, 0xFF
    cmp ebx, 0x7F
    jne .fail

    ; ---- kill(pid, SIGCONT=18) ----
    mov eax, 37
    mov ebx, [esp + 0]
    mov ecx, 18
    int 0x80
    test eax, eax
    jnz .fail

    ; ---- kill(pid, SIGINT=2):投 pending,不杀 ----
    mov eax, 37
    mov ebx, [esp + 0]
    mov ecx, 2
    int 0x80
    test eax, eax
    jnz .fail

    ; ---- kill(子pid, 999):非法信号 → -EINVAL(22)----
    mov eax, 37
    mov ebx, [esp + 0]
    mov ecx, 999
    int 0x80
    cmp eax, -22
    jne .fail

    ; ---- kill(999, SIGTERM):不存在的 pid → -ESRCH(3)----
    mov eax, 37
    mov ebx, 999
    mov ecx, 15
    int 0x80
    cmp eax, -3
    jne .fail

    ; ---- kill(0, SIGTERM):不支持的 pid 形式 → -ENOSYS(38)----
    mov eax, 37
    xor ebx, ebx
    mov ecx, 15
    int 0x80
    cmp eax, -38
    jne .fail

    ; ---- kill(pid, SIGTERM=15)----
    mov eax, 37
    mov ebx, [esp + 0]
    mov ecx, 15
    int 0x80
    test eax, eax
    jnz .fail

    ; ---- wait4(pid, &status, 0, 0):退出事件,(status>>8)&0xFF == 137 ----
    mov eax, 114
    mov ebx, [esp + 0]
    lea ecx, [esp + 4]
    xor edx, edx
    xor esi, esi
    int 0x80
    cmp eax, [esp + 0]
    jne .fail
    mov ebx, [esp + 4]
    shr ebx, 8
    and ebx, 0xFF
    cmp ebx, 137                    ; 128 + SIGKILL(9):被信号杀死
    jne .fail

    ; ---- 打印 "p4-kill: ok\n" ----
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
    ; 用户态死循环(父进程会先 STOP 再 CONT 再 TERM)
.child_loop:
    mov ecx, 0x100000
.child_spin:
    dec ecx
    jnz .child_spin
    jmp .child_loop

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
msg_ok       db "p4-kill: ok", 10
msg_ok_len   equ $ - msg_ok
msg_fail     db "p4-kill: FAIL", 10
msg_fail_len equ $ - msg_fail
