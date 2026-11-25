; ============================================================================
;  KKernel x86-64 — 64 位内核入口(K64.BIN,由 32 位内核加载到物理 0x03010000)
;
;  32 位内核的 start64 命令会:
;    1) 检查 CPUID 支持长模式(PAE + LM)
;    2) 把 BIN/K64.BIN 读进物理 0x03010000(最多 128 KiB)
;    3) 在 0x0300F000 填一张 boot_info(magic 'K64I')
;    4) 在 0x03000000 建 PML4/PDPT/PD(0-1GiB 2MiB 大页 + 0xC0000000-0xFFFFFFFF 覆盖 LFB)
;    5) 打开 PAE / EFER.LME / CR0.PG,远跳到 0x03010000
;
;  这是**单向**旅程:64 位内核不再回 32 位(MVP 不做 start32)。
;  32 位内核的实时状态(进程/文件系统/shell)都不会带过来 —— 64 位内核
;  是另一个"从零开始"的小系统,只是借用了 VBE 帧缓冲和 E820 信息。
;
;  本文件按 [ORG 0x03010000] 平铺,构建产物就是可以直接跳进来执行的镜像。
; ============================================================================

[BITS 64]
[ORG 0x03010000]

BOOT_INFO64 equ 0x0300F000      ; 32 位侧填的 boot_info
K64I_MAGIC  equ 0x4934364B      ; 'K64I'(小端)

; 颜色(BGR0 32bpp:0x00RRGGBB)
CON_COLOR_WHITE equ 0x00FFFFFF
CON_COLOR_GREEN equ 0x0000FF00
CON_COLOR_RED   equ 0x00FF0000

; ---------------------------------------------------------------------------
;  入口:重新装 GDT、校验 boot_info、初始化、进 shell
; ---------------------------------------------------------------------------
k64_entry:
    cli
    ; ---- 用 64 位 GDT 重载 CS(32 位侧跳过来时用的还是那边的 GDT)----
    lgdt [k64_gdt_desc]
    push qword 0x08
    mov rax, k64_cs_ok
    push rax
    retfq

k64_cs_ok:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    ; ---- 校验 boot_info ----
    mov rbx, BOOT_INFO64
    mov eax, [rbx]
    cmp eax, K64I_MAGIC
    jne k64_bad_magic

    ; ---- 换自己的栈(32 位侧在 boot_info+48 填的 64 位栈顶)----
    mov rsp, [rbx + 48]
    xor rbp, rbp

    ; ---- 把 boot_info 抄进本地变量 ----
    mov eax, [rbx + 4]
    mov [lfb_phys], eax
    mov eax, [rbx + 8]
    mov [lfb_pitch], eax
    mov eax, [rbx + 12]
    mov [lfb_width], eax
    mov eax, [rbx + 16]
    mov [lfb_height], eax
    mov eax, [rbx + 20]
    mov [lfb_bpp], eax
    mov eax, [rbx + 28]
    mov [e820_count], eax
    mov eax, [rbx + 32]
    mov [ram_top], eax
    mov eax, [rbx + 36]
    mov [k64_phys], eax
    mov eax, [rbx + 40]
    mov [k64_size], eax

    ; ---- 控制台 ----
    call con_init
    ; ---- 中断 / 定时器 / 键盘 ----
    call idt_init
    call pic_remap
    call pit_init
    call kbd_drain

    ; ---- 横幅 ----
    mov dword [con_fg], CON_COLOR_GREEN
    lea rsi, [msg_banner]
    call con_print
    call con_show_bootinfo
    mov dword [con_fg], CON_COLOR_WHITE

    sti
    jmp shell_main

k64_bad_magic:
    mov dword [con_fg], CON_COLOR_RED
    lea rsi, [msg_bad_magic]
    call con_print
.hang:
    cli
    hlt
    jmp .hang

; ---------------------------------------------------------------------------
;  各模块
; ---------------------------------------------------------------------------
%include "kernel64/console.asm"
%include "kernel64/idt.asm"
%include "kernel64/shell.asm"

; ===========================================================================
;  数据
; ===========================================================================
align 16
; ---- 64 位 GDT:0x08 代码段(L=1) / 0x10 数据段 ----
k64_gdt:
    dq 0x0000000000000000
    dq 0x00AF9A000000FFFF
    dq 0x00CF92000000FFFF
k64_gdt_end:
k64_gdt_desc:
    dw k64_gdt_end - k64_gdt - 1
    dq k64_gdt

; ---- boot_info 抄来的信息 ----
lfb_phys    dd 0
lfb_pitch   dd 0
lfb_width   dd 0
lfb_height  dd 0
lfb_bpp     dd 0
e820_count  dd 0
ram_top     dd 0
k64_phys    dd 0
k64_size    dd 0

; ---- 控制台状态 ----
con_cols    dd 0
con_rows    dd 0
con_row     dd 0
con_col     dd 0
con_fg      dd 0x00FFFFFF
con_num_buf times 32 db 0
con_hex_buf times 12 db 0
con_hexdigits db '0123456789ABCDEF'

; ---- IDT ----
align 16
idt_table:
    times 256 * 16 db 0
idt_desc:
    dw 256 * 16 - 1
    dq idt_table

; ---- 键盘 ----
kbd_buf     times 256 db 0
kbd_head    dd 0
kbd_tail    dd 0
kbd_shift   db 0
kbd_skip    db 0
align 8
ticks       dq 0

; ---- shell ----
sh_line     times 256 db 0
sh_len      dd 0
vendor_buf  times 16 db 0

; ---- 扫描码映射(set 1;0 = 忽略)----
kb_map_lower:
    db 0, 27, '1','2','3','4','5','6','7','8','9','0','-','=',8,9   ; 00-0F
    db 'q','w','e','r','t','y','u','i','o','p','[',']',10,0        ; 10-1D
    db 'a','s','d','f','g','h','j','k','l',';',0x27,'`'           ; 1E-29
    db 0,'\','z','x','c','v','b','n','m',',','.','/'               ; 2A-35
    db 0,'*',0,' '                                                 ; 36-39
    times 0x80 - 0x3A db 0
kb_map_shift:
    db 0, 27, '!','@','#','$','%','^','&','*','(',')','_','+',8,9   ; 00-0F
    db 'Q','W','E','R','T','Y','U','I','O','P','{','}',10,0        ; 10-1D
    db 'A','S','D','F','G','H','J','K','L',':','"','~'             ; 1E-29
    db 0,'|','Z','X','C','V','B','N','M','<','>','?'               ; 2A-35
    db 0,'*',0,' '                                                 ; 36-39
    times 0x80 - 0x3A db 0

; ---- 消息 ----
msg_banner    db 'KKernel x86-64', 10, 'long mode: enabled', 10, 0
msg_bad_magic db 'k64: bad boot_info magic', 10, 0
msg_prompt    db 'k64> ', 0
msg_unknown   db 'unknown command: ', 0
msg_ticks     db 'ticks: ', 0
msg_reboot    db 'reboot: byebye', 10, 0
msg_help      db 'k64 commands:', 10,
              db '  help   - this message', 10,
              db '  info   - CPU / paging / memory / LFB info', 10,
              db '  echo   - echo <text>', 10,
              db '  clear  - clear the screen', 10,
              db '  ticks  - PIT tick count (100 Hz)', 10,
              db '  reboot - reboot the machine', 10, 0
msg_info      db 'info:', 10, 0
msg_bi_cpu    db '  CPU: ', 0
msg_bi_cr0    db '  CR0=', 0
msg_bi_cr4    db ' CR4=', 0
msg_bi_efer   db ' EFER=', 0
msg_info_pae  db '  PAE=', 0
msg_info_lme  db ' LME=', 0
msg_bi_ram    db '  RAM: ', 0
msg_bi_mib    db ' MiB, E820 entries: ', 0
msg_bi_e820   db ' E820 entries', 0
msg_bi_lfb    db '  LFB: ', 0
msg_bi_space  db ' ', 0
msg_bi_img    db '  K64: ', 0
msg_bi_size   db ', ', 0
msg_bi_bytes  db ' bytes', 0
msg_info_ticks db '  ticks: ', 0
msg_exc       db 'EXCEPTION #', 0
msg_exc_err   db ' err=', 0
msg_exc_rip   db ' rip=', 0
msg_exc_cs    db ' cs=', 0
msg_exc_stop  db 'kernel stopped.', 10, 0

name_help     db 'help', 0
name_info     db 'info', 0
name_echo     db 'echo', 0
name_clear    db 'clear', 0
name_ticks    db 'ticks', 0
name_reboot   db 'reboot', 0

; ---- 8×16 ASCII 字模(由 tools/mkfont8x16.py 从 font/font-kkf.bin 导出)----
align 16
font8x16:
    incbin "build/font8x16.bin"
