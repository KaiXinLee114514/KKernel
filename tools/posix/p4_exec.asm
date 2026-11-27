; ---------------------------------------------------------------------------
;  POSIX P4 测试程序:execve(11)
;    1. 打印 "p4-exec: start"
;    2. execve("NO_SUCH_FILE.ELF") 必须失败,返回 -ENOENT(-2)
;    3. 打印 "p4-exec: enoent ok"
;    4. execve("TEST/P1_HELLO.ELF") 成功 → 当前进程映像被替换成 P1_HELLO,
;       它打印 "hello from int 0x80" 后 exit(0)(shell 会看到程序返回)。
;  失败:      p4-exec: FAIL   退出码 1
; ---------------------------------------------------------------------------
BITS 32

section .text
global _start
_start:
    ; ---- 打印 "p4-exec: start\n" ----
    mov eax, 4
    mov ebx, 1
    lea ecx, [msg_start]
    mov edx, msg_start_len
    int 0x80

    ; ---- execve("NO_SUCH_FILE.ELF", 0, 0):应返回 -ENOENT(-2)----
    mov eax, 11
    lea ebx, [path_missing]
    xor ecx, ecx
    xor edx, edx
    int 0x80
    cmp eax, -2
    jne .fail

    ; ---- 打印 "p4-exec: enoent ok\n" ----
    mov eax, 4
    mov ebx, 1
    lea ecx, [msg_enoent]
    mov edx, msg_enoent_len
    int 0x80

    ; ---- execve("TEST/P1_HELLO.ELF", 0, 0):成功则不返回 ----
    mov eax, 11
    lea ebx, [path_hello]
    xor ecx, ecx
    xor edx, edx
    int 0x80
    ; 走到这里说明 execve 失败了(不该发生)
    jmp .fail

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
msg_start      db "p4-exec: start", 10
msg_start_len  equ $ - msg_start
msg_enoent     db "p4-exec: enoent ok", 10
msg_enoent_len equ $ - msg_enoent
msg_fail       db "p4-exec: FAIL", 10
msg_fail_len   equ $ - msg_fail
path_missing   db "NO_SUCH_FILE.ELF", 0
path_hello     db "TEST/P1_HELLO.ELF", 0
