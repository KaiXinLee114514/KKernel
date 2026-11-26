; ============================================================================
;  KKernel POSIX 转译层 P1 测试程序(无 libc,裸汇编 i386 Linux 程序)
;
;  构建:
;      nasm -f elf32 tools/posix/p1_hello.asm -o build/posix/p1_hello.o
;      ld -m elf_i386 -static -Ttext=0x120000 -e _start \
;         --build-id=none -o build/posix/P1_HELLO.ELF build/posix/p1_hello.o
;
;  为什么用 -Ttext=0x120000:KKernel 的 ELF 装载器(elf_load)把程序展开到
;  0x120000(内核的程序窗口),所以 ELF 的段地址必须从 0x120000 起;
;  默认的 0x08048000 会被它判成"镜像太大"而拒绝(见 kernel/elf.asm 开头)。
;
;  验证目标:kernel/posix.asm 的 int 0x80 转译层
;      sys_write(4):fd 1 输出 "hello from int 0x80\n"
;      sys_exit(1):  退出码 0
; ============================================================================

BITS 32

section .text
global _start
_start:
    mov eax, 4                          ; sys_write
    mov ebx, 1                          ; fd 1 = stdout
    mov ecx, msg                        ; buf
    mov edx, msg_len                    ; count
    int 0x80

    mov eax, 1                          ; sys_exit
    xor ebx, ebx                        ; code = 0
    int 0x80

.hang:                                  ; 正常不会到这里(exit 不返回)
    hlt
    jmp .hang

section .rodata
msg:    db "hello from int 0x80", 10
msg_len equ $ - msg
