; ---------------------------------------------------------------------------
;  POSIX P2 测试程序:文件系统调用 open/read/write/lseek/close
;    1. open("TEST/P2_DATA.TXT", O_RDONLY)
;    2. read 到缓冲
;    3. write 到屏幕(前缀 "p2-file: ")
;    4. lseek 回文件头,再 read 一次,内容应与第一次等长
;    5. close,exit(0)
;  输出正常:  p2-file: p2 data ok
;             p2-file: done
;  失败:      p2-file: FAIL   退出码 1
; ---------------------------------------------------------------------------
BITS 32

section .text
global _start
_start:
    ; 先用 brk 申请一页当读缓冲(ELF 的 .text 是只读段,不能当缓冲用)
    mov eax, 45
    xor ebx, ebx
    int 0x80
    test eax, eax
    js .fail
    mov edi, eax                        ; edi = buf
    lea ebx, [eax + 0x1000]
    mov eax, 45
    int 0x80
    lea ecx, [edi + 0x1000]
    cmp eax, ecx
    jne .fail

    ; fd = open("TEST/P2_DATA.TXT", 0, 0)
    mov eax, 5
    mov ebx, path_data
    xor ecx, ecx
    xor edx, edx
    int 0x80
    test eax, eax
    js .fail
    mov esi, eax                        ; esi = fd

    ; n = read(fd, buf, 64)
    mov eax, 3
    mov ebx, esi
    mov ecx, edi
    mov edx, 64
    int 0x80
    test eax, eax
    jle .fail
    mov ebp, eax                        ; ebp = n

    ; write(1, "p2-file: ", 9)
    mov eax, 4
    mov ebx, 1
    mov ecx, msg_prefix
    mov edx, 9
    int 0x80

    ; write(1, buf, n)
    mov eax, 4
    mov ebx, 1
    mov ecx, edi
    mov edx, ebp
    int 0x80

    ; lseek(fd, 0, SEEK_SET) → 0
    mov eax, 19
    mov ebx, esi
    xor ecx, ecx
    xor edx, edx
    int 0x80
    test eax, eax
    js .fail

    ; 再 read 一次:应得到同样长度
    mov eax, 3
    mov ebx, esi
    lea ecx, [edi + 64]
    mov edx, 64
    int 0x80
    cmp eax, ebp
    jne .fail

    ; close(fd) → 0
    mov eax, 6
    mov ebx, esi
    int 0x80
    test eax, eax
    js .fail

    ; write(1, "p2-file: done\n", 14)
    mov eax, 4
    mov ebx, 1
    mov ecx, msg_done
    mov edx, msg_done_len
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
path_data  db "TEST/P2_DATA.TXT", 0
msg_prefix db "p2-file: "
msg_done   db "p2-file: done", 10
msg_done_len equ $ - msg_done
msg_fail   db "p2-file: FAIL", 10
msg_fail_len equ $ - msg_fail

