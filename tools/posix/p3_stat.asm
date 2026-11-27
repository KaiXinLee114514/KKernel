; ---------------------------------------------------------------------------
;  POSIX P3 测试程序:stat / fstat / ioctl(TCGETS)
;    1. stat("TEST/P2_DATA.TXT") → 普通文件,size=11,mtime>0
;    2. stat("TEST") → 目录(S_IFDIR)
;    3. stat("/") → 根目录(S_IFDIR)
;    4. stat("TEST/NOFILE.TXT") → -ENOENT(-2)
;    5. open 文件 → fstat(fd) 看 size/mode;fstat(0) 看字符设备位
;    6. ioctl(1, TCGETS) → 0;ioctl(文件 fd, TCGETS) → -ENOTTY(-25)
;  输出正常:  p3-stat: ok
;  失败:      p3-stat: FAIL   退出码 1
; ---------------------------------------------------------------------------
BITS 32

section .text
global _start
_start:
    ; ---- 用 brk 拿两页缓冲当 stat 结构 / termios ----
    mov eax, 45
    xor ebx, ebx
    int 0x80
    test eax, eax
    js .fail
    mov edi, eax                        ; edi = 缓冲基址
    lea ebx, [edi + 0x2000]
    mov eax, 45
    int 0x80
    lea ecx, [edi + 0x2000]
    cmp eax, ecx
    jne .fail

    ; ---- 1) stat(TEST/P2_DATA.TXT) ----
    mov eax, 106
    mov ebx, path_file
    mov ecx, edi
    int 0x80
    test eax, eax
    jnz .fail
    cmp dword [edi + 20], 11            ; st_size
    jne .fail
    movzx eax, word [edi + 8]           ; st_mode
    and eax, 0xF000
    cmp eax, 0x8000                     ; S_IFREG
    jne .fail
    cmp dword [edi + 40], 0             ; st_mtime > 0
    jbe .fail

    ; ---- 2) stat(TEST) → 目录 ----
    lea esi, [edi + 128]
    mov eax, 106
    mov ebx, path_dir
    mov ecx, esi
    int 0x80
    test eax, eax
    jnz .fail
    movzx eax, word [esi + 8]
    and eax, 0xF000
    cmp eax, 0x4000                     ; S_IFDIR
    jne .fail

    ; ---- 3) stat("/") → 根目录 ----
    lea esi, [edi + 256]
    mov eax, 106
    mov ebx, path_root
    mov ecx, esi
    int 0x80
    test eax, eax
    jnz .fail
    movzx eax, word [esi + 8]
    and eax, 0xF000
    cmp eax, 0x4000
    jne .fail

    ; ---- 4) stat 不存在的文件 → -ENOENT ----
    mov eax, 106
    mov ebx, path_nofile
    mov ecx, edi
    int 0x80
    cmp eax, -2
    jne .fail

    ; ---- 5) open + fstat ----
    mov eax, 5
    mov ebx, path_file
    xor ecx, ecx
    xor edx, edx
    int 0x80
    test eax, eax
    js .fail
    mov ebp, eax                        ; ebp = fd

    lea esi, [edi + 384]
    mov eax, 108                        ; fstat(fd, buf)
    mov ebx, ebp
    mov ecx, esi
    int 0x80
    test eax, eax
    jnz .fail
    cmp dword [esi + 20], 11
    jne .fail
    movzx eax, word [esi + 8]
    and eax, 0xF000
    cmp eax, 0x8000
    jne .fail

    ; fstat(0) → 字符设备
    lea esi, [edi + 512]
    mov eax, 108
    xor ebx, ebx
    mov ecx, esi
    int 0x80
    test eax, eax
    jnz .fail
    movzx eax, word [esi + 8]
    and eax, 0xF000
    cmp eax, 0x2000                     ; S_IFCHR
    jne .fail

    ; ---- 6) ioctl ----
    mov eax, 54
    mov ebx, 1
    mov ecx, 0x5401                     ; TCGETS
    lea edx, [edi + 640]
    int 0x80
    test eax, eax
    jnz .fail

    mov eax, 54
    mov ebx, ebp                        ; 文件 fd → 不支持
    mov ecx, 0x5401
    lea edx, [edi + 640]
    int 0x80
    cmp eax, -25                        ; -ENOTTY
    jne .fail

    ; close(fd)
    mov eax, 6
    mov ebx, ebp
    int 0x80
    test eax, eax
    js .fail

    ; ---- 成功 ----
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
path_file   db "TEST/P2_DATA.TXT", 0
path_dir    db "TEST", 0
path_root   db "/", 0
path_nofile db "TEST/NOFILE.TXT", 0
msg_ok      db "p3-stat: ok", 10
msg_ok_len  equ $ - msg_ok
msg_fail    db "p3-stat: FAIL", 10
msg_fail_len equ $ - msg_fail
