; ---------------------------------------------------------------------------
;  POSIX P3 测试程序:time(13) / gettimeofday(78)
;    1. time(0) 返回 > 0
;    2. time(&t) 返回值与写入的 t 一致,t >= 第一次
;    3. 忙等一小会儿再取一次,时间应单调不减
;    4. gettimeofday(&tv) 返回 0,tv_sec > 0,tv_usec < 1000000
;  输出正常:  p3-time: ok
; ---------------------------------------------------------------------------
BITS 32

section .text
global _start
_start:
    ; ---- 用 brk 拿 1 页缓冲(timeval / tloc)----
    mov eax, 45
    xor ebx, ebx
    int 0x80
    test eax, eax
    js .fail
    mov edi, eax                        ; edi = 缓冲基址

    ; ---- 1) time(0) > 0 ----
    mov eax, 13
    xor ebx, ebx
    int 0x80
    test eax, eax
    jle .fail
    mov ebp, eax                        ; ebp = t1

    ; ---- 2) time(&buf) 一致,t2 >= t1 ----
    mov eax, 13
    mov ebx, edi
    int 0x80
    cmp eax, ebp
    jl .fail
    cmp [edi], eax
    jne .fail
    mov ebp, eax                        ; ebp = t2

    ; ---- 3) 忙等约几十万次再取一次(单调不减)----
    mov ecx, 300000
.wait:
    dec ecx
    jnz .wait
    mov eax, 13
    xor ebx, ebx
    int 0x80
    test eax, eax
    jle .fail
    cmp eax, ebp
    jl .fail

    ; ---- 4) gettimeofday(&tv, 0) ----
    mov eax, 78
    lea ebx, [edi + 16]
    xor ecx, ecx
    int 0x80
    test eax, eax
    jnz .fail
    mov eax, [edi + 16]                 ; tv_sec
    test eax, eax
    jle .fail
    cmp eax, ebp
    jl .fail
    cmp dword [edi + 20], 1000000       ; tv_usec < 1e6
    jae .fail

    mov eax, 4
    mov ebx, 1
    mov ecx, msg_ok
    mov edx, msg_ok_len
    int 0x80
    xor ebx, ebx
    mov eax, 1
    int 0x80
    hlt

.fail:
    mov eax, 4
    mov ebx, 1
    mov ecx, msg_fail
    mov edx, msg_fail_len
    int 0x80
    mov ebx, 1
    mov eax, 1
    int 0x80
    hlt

section .text
msg_ok      db "p3-time: ok", 10
msg_ok_len  equ $ - msg_ok
msg_fail    db "p3-time: FAIL", 10
msg_fail_len equ $ - msg_fail
