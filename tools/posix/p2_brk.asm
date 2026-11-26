; ---------------------------------------------------------------------------
;  POSIX P2 测试程序:brk(45) 程序堆
;    1. brk(0) 取当前 break
;    2. brk(cur + 3 页)
;    3. 三页各写 dword 模式,再读回比对
;    4. 成功打印 "p2-brk: ok" 并 exit(0);失败 "p2-brk: FAIL" 并 exit(1)
; ---------------------------------------------------------------------------
BITS 32

section .text
global _start
_start:
    ; brk(0) → 当前 break
    mov eax, 45
    xor ebx, ebx
    int 0x80
    test eax, eax
    js .fail
    mov edi, eax                        ; edi = 堆起点

    ; brk(edi + 0x3000) → 必须返回新值
    lea ebx, [edi + 0x3000]
    mov eax, 45
    int 0x80
    lea ecx, [edi + 0x3000]
    cmp eax, ecx
    jne .fail

    ; ---- 填充 3 页(每页 1024 个 dword,同页同值)----
    xor edx, edx                        ; edx = page
.fill_page:
    mov eax, edx
    shl eax, 12
    lea ecx, [edi + eax]                ; ecx = 页基址
    mov ebx, 1024
.fill_dw:
    mov eax, edx
    imul eax, eax, 0x01010101
    add eax, 0x5A5A0000
    mov [ecx], eax
    add ecx, 4
    dec ebx
    jnz .fill_dw
    inc edx
    cmp edx, 3
    jb .fill_page

    ; ---- 读回校验 ----
    xor edx, edx
.verify_page:
    mov eax, edx
    shl eax, 12
    lea ecx, [edi + eax]
    mov ebx, 1024
.verify_dw:
    mov eax, edx
    imul eax, eax, 0x01010101
    add eax, 0x5A5A0000
    cmp [ecx], eax
    jne .fail
    add ecx, 4
    dec ebx
    jnz .verify_dw
    inc edx
    cmp edx, 3
    jb .verify_page

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
msg_ok     db "p2-brk: ok", 10
msg_ok_len equ $ - msg_ok
msg_fail   db "p2-brk: FAIL", 10
msg_fail_len equ $ - msg_fail
