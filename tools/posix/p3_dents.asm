; ---------------------------------------------------------------------------
;  POSIX P3 测试程序:getdents64 + 目录 fd 语义
;    1. open("TEST", O_RDONLY) → 目录 fd(>=3)
;    2. read(目录 fd) → -EISDIR(-21)
;    3. open("TEST", O_WRONLY) → -EISDIR(-21)
;    4. 循环 getdents64 遍历 TEST/,统计条目数并找 "P2_DATA.TXT"
;    5. 条目数 >= 3 且找到目标 → 打印 "p3-dents: ok"
;  注:目录项由内核按 FAT 8.3 名返回(长名文件用短别名),"."/".." 不列。
; ---------------------------------------------------------------------------
BITS 32

section .text
global _start
_start:
    ; ---- 用 brk 拿 1 页缓冲(dentbuf + 计数字段)----
    mov eax, 45
    xor ebx, ebx
    int 0x80
    test eax, eax
    js .fail
    mov edi, eax                        ; edi = 缓冲基址(基址+0x1000 起放目录项)

    ; ---- 1) open("TEST", O_RDONLY) ----
    mov eax, 5
    mov ebx, path_dir
    xor ecx, ecx
    xor edx, edx
    int 0x80
    test eax, eax
    js .fail
    cmp eax, 3
    jb .fail
    mov ebp, eax                        ; ebp = 目录 fd

    ; ---- 2) read(目录 fd) → -EISDIR ----
    mov eax, 3
    mov ebx, ebp
    lea ecx, [edi + 0x1000]
    mov edx, 16
    int 0x80
    cmp eax, -21
    jne .fail

    ; ---- 3) open("TEST", O_WRONLY) → -EISDIR ----
    mov eax, 5
    mov ebx, path_dir
    mov ecx, 1
    xor edx, edx
    int 0x80
    cmp eax, -21
    jne .fail

    ; ---- 4) getdents64 循环 ----
    mov dword [edi + 0x800], 0          ; count
    mov dword [edi + 0x804], 0          ; found
.gd_loop:
    mov eax, 220
    mov ebx, ebp
    lea ecx, [edi + 0x1000]
    mov edx, 1024
    int 0x80
    test eax, eax
    js .fail
    jz .gd_done
    mov edx, eax                        ; edx = 本次字节数
    xor ebx, ebx                        ; ebx = 记录偏移
.parse:
    cmp ebx, edx
    jae .gd_loop
    movzx eax, word [edi + 0x1000 + ebx + 16]   ; d_reclen
    mov [edi + 0x808], eax
    lea ecx, [edi + 0x1000 + ebx + 19]  ; d_name
    mov esi, name_target
.cmp_name:
    mov al, [ecx]
    cmp al, [esi]
    jne .next_rec
    test al, al
    jz .found
    inc ecx
    inc esi
    jmp .cmp_name
.found:
    mov dword [edi + 0x804], 1
.next_rec:
    inc dword [edi + 0x800]
    mov eax, [edi + 0x808]
    add ebx, eax
    jmp .parse
.gd_done:
    cmp dword [edi + 0x800], 3
    jb .fail
    cmp dword [edi + 0x804], 1
    jne .fail

    ; close(fd)
    mov eax, 6
    mov ebx, ebp
    int 0x80
    test eax, eax
    js .fail

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
path_dir    db "TEST", 0
name_target db "P2_DATA.TXT", 0
msg_ok      db "p3-dents: ok", 10
msg_ok_len  equ $ - msg_ok
msg_fail    db "p3-dents: FAIL", 10
msg_fail_len equ $ - msg_fail
