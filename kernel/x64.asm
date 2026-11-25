; ============================================================================
;  kernel/x64.asm — 32 位侧的长模式入口:start64 命令 + 一切到底
;
;  shell 里敲 `start64`:
;    1) CPUID 查 PAE(leaf 1 EDX bit6)和长模式(leaf 0x80000001 EDX bit29)
;    2) FAT 里读 BIN/K64.BIN(≤128 KiB)到物理 0x03010000
;    3) 在 0x0300F000 填 boot_info(magic 'K64I'),把帧缓冲/E820/栈顶交给 64 位内核
;    4) 在 0x03000000 建 PML4/PDPT/PD:
;         PML4[0] → PDPT;PDPT[0] → PD0(0-1GiB 2 MiB 大页)
;         PDPT[3] → PD3(0xC0000000-0xFFFFFFFF,覆盖 VBE LFB)
;    5) CR4.PAE=1,CR3=PML4,EFER.LME=1,CR0.PG=1,远跳 0x08:0x03010000
;
;  ★ 物理布局为什么要挑 0x03000000(48 MiB)这一片:
;    32 位内核的 kernel heap 是 0x180000-0x6E0000,pmem 页池从 0x400000 起,
;    低区缓冲也全在 16 MiB 以下。把这些结构放在 heap 里,QEMU 侥幸能跑,
;    VirtualBox 会在切页表后的 lgdt 处给我一记 GURU_MEDITATION(实测)。
;    0x03000000 在 heap 之外、又远低于 64 MiB,普通小内存机器也够不着。
;
;  注意:32 位内核的页表(CR3=0x1000)就此退役。跳过去之后不再回来。
; ============================================================================

; ---- 物理布局(和 kernel64/start.asm 的约定,改一边必须改另一边)----
;  ★ 必须避开:kernel heap 0x180000-0x6E0000、pmem 页池(0x400000 起)。
;    这一组全部在 0x03000000(48 MiB)区,64 MiB 以上 RAM 才够用。
BOOT_INFO64   equ 0x0300F000            ; boot_info(4 KiB 页,0x03000000 区)
K64_LOAD_ADDR equ 0x03010000            ; K64.BIN 加载地址(= kernel64 的 ORG)
K64_MAX_SIZE  equ 0x20000               ; 128 KiB 上限
K64I_MAGIC    equ 0x4934364B            ; 'K64I'
X64_PML4      equ 0x03000000            ; 页表区 0x03000000-0x03003FFF(16 KiB)
X64_PDPT      equ 0x03001000
X64_PD0       equ 0x03002000
X64_PD3       equ 0x03003000
X64_STACK_TOP equ 0x0300D000            ; 64 位栈顶(栈向 0x03004000 长)
X64_RAM_MIN   equ 0x04000000            ; 至少 64 MiB 物理内存才够这套布局

; ---------------------------------------------------------------------------
;  cmd_start64:shell 命令
; ---------------------------------------------------------------------------
cmd_start64:
    pushad
    ; ---- 1) CPU 支持长模式吗 ----
    call x64_supported
    test eax, eax
    jz .no_cpu
    ; ---- 1b) RAM 够吗:新布局在 0x03000000(48 MiB)以上,留到 64 MiB 才稳 ----
    cmp dword [ident_limit], X64_RAM_MIN
    jb .need_ram
    ; ---- 2) 找 BIN/K64.BIN,量大小 ----
    mov esi, [cmd_arg]
    call strip_name
    mov esi, x64_path_k64
    call fat_path
    jc .no_file
    mov esi, eax
    mov [x64_last_name], eax
    call fat_stat
    cmp eax, -1
    je .no_file
    cmp eax, K64_MAX_SIZE
    ja .too_big
    ; ---- 3) 读进 0x200000 ----
    mov [x64_file_size], eax
    mov esi, [x64_last_name]
    mov edi, K64_LOAD_ADDR
    call fat_read_file
    cmp eax, -1
    je .read_err
    mov [x64_file_size], eax
    ; ---- 4) 填 boot_info,直接跳(不返回)----
    call x64_build_bootinfo
    mov al, COL_OK
    call term_set_color
    mov esi, msg_x64_jump
    call term_print
    call x64_switch
.no_cpu:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_x64_nocpu
    call term_print
    jmp .fail_done
.need_ram:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_x64_needram
    call term_print
    jmp .fail_done
.no_file:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_x64_nofile
    call term_print
    jmp .fail_done
.too_big:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_x64_toobig
    call term_print
    jmp .fail_done
.read_err:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_x64_readerr
    call term_print
.fail_done:
    mov al, COL_NORMAL
    call term_set_color
    popad
    ret

; ---------------------------------------------------------------------------
;  x64_supported:CPUID 检查 → eax=1 支持 / 0 不支持
; ---------------------------------------------------------------------------
x64_supported:
    push ebx
    push ecx
    push edx
    xor eax, eax
    cpuid
    cmp eax, 1
    jb .no
    mov eax, 1
    cpuid
    test edx, 1 << 6                    ; PAE
    jz .no
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000001
    jb .no
    mov eax, 0x80000001
    cpuid
    test edx, 1 << 29                   ; 长模式(LM)
    jz .no
    mov eax, 1
    jmp .out
.no:
    xor eax, eax
.out:
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  x64_build_bootinfo:把 32 位内核知道的信息交给 64 位内核
;
;  偏移(和 kernel64/start.asm 对应):
;    0 magic 'K64I'   4 lfb_phys   8 lfb_pitch  12 fb_w  16 fb_h  20 bpp
;   24 e820_ptr     28 e820_count 32 ram_top    36 k64_phys 40 k64_size
;   48 stack_top(qword)
; ---------------------------------------------------------------------------
x64_build_bootinfo:
    push eax
    push ecx
    push edi
    mov edi, BOOT_INFO64
    xor eax, eax
    mov ecx, 16                         ; 64 字节清零
    cld
    rep stosd
    mov dword [BOOT_INFO64 + 0], K64I_MAGIC
    mov eax, [fb_phys]
    mov [BOOT_INFO64 + 4], eax
    mov eax, [fb_pitch]
    mov [BOOT_INFO64 + 8], eax
    mov eax, [fb_width]
    mov [BOOT_INFO64 + 12], eax
    mov eax, [fb_height]
    mov [BOOT_INFO64 + 16], eax
    mov eax, [fb_bpp]
    mov [BOOT_INFO64 + 20], eax
    mov dword [BOOT_INFO64 + 24], 0x9400   ; E820 缓冲(固定)
    mov eax, [e820_entries]
    mov [BOOT_INFO64 + 28], eax
    mov eax, [ram_top]
    mov [BOOT_INFO64 + 32], eax
    mov dword [BOOT_INFO64 + 36], K64_LOAD_ADDR
    mov eax, [x64_file_size]
    mov [BOOT_INFO64 + 40], eax
    mov dword [BOOT_INFO64 + 48], X64_STACK_TOP
    mov dword [BOOT_INFO64 + 52], 0
    pop edi
    pop ecx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  x64_switch:建页表 → 开 PAE/LME/PG → 远跳 64 位内核(不返回)
; ---------------------------------------------------------------------------
x64_switch:
    cli
    ; ---- 1) 清 PML4/PDPT/PD0/PD3(16 KiB)----
    mov edi, X64_PML4
    xor eax, eax
    mov ecx, (4096 * 4) / 4
    cld
    rep stosd
    ; ---- 2) PML4[0] = PDPT(P|RW)----
    mov eax, X64_PDPT
    or eax, 3
    mov [X64_PML4 + 0], eax
    mov dword [X64_PML4 + 4], 0
    ; ---- 3) PD0:0-1GiB,512 个 2 MiB 大页 ----
    mov edi, X64_PD0
    xor edx, edx
    mov ecx, 512
.fill0:
    mov eax, edx
    or eax, 0x83                        ; P|RW|PS
    mov [edi + 0], eax
    mov dword [edi + 4], 0
    add edi, 8
    add edx, 0x200000
    dec ecx
    jnz .fill0
    ; ---- 4) PD3:0xC0000000-0xFFFFFFFF,覆盖 VBE LFB ----
    mov edi, X64_PD3
    mov edx, 0xC0000000
    mov ecx, 512
.fill3:
    mov eax, edx
    or eax, 0x83
    mov [edi + 0], eax
    mov dword [edi + 4], 0
    add edi, 8
    add edx, 0x200000
    dec ecx
    jnz .fill3
    ; ---- 5) PDPT[0]=PD0(0-1GiB), PDPT[3]=PD3(0xC0000000-0xFFFFFFFF)----
    mov eax, X64_PD0
    or eax, 3
    mov [X64_PDPT + 0], eax
    mov dword [X64_PDPT + 4], 0
    mov eax, X64_PD3
    or eax, 3
    mov [X64_PDPT + 24], eax            ; PDPT 项 8 字节,第 3 项在 +24
    mov dword [X64_PDPT + 28], 0

    ; ---- 6) 切模式前先把栈换到安全区(0x03004000-0x0300D000)----
    mov esp, X64_STACK_TOP
    ; ---- 7) 关 32 位分页 ----
    mov eax, cr0
    and eax, 0x7FFFFFFF
    mov cr0, eax
    ; ---- 8) CR4.PAE = 1 ----
    mov eax, cr4
    or eax, 0x20
    mov cr4, eax
    ; ---- 9) CR3 = PML4 ----
    mov eax, X64_PML4
    mov cr3, eax
    ; ---- 10) EFER.LME = 1 ----
    mov ecx, 0xC0000080
    rdmsr
    or eax, 0x100
    wrmsr
    ; ---- 11) CR0.PG = 1(加 WP,和 32 位内核一致)----
    mov eax, cr0
    or eax, 0x80000000
    or eax, 0x00010000
    mov cr0, eax
    ; ---- 12) 装 64 位 GDT,重载数据段 ----
    lgdt [x64_gdt_desc]
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    ; ---- 13) 远跳 0x08:0x200000(从这一刻起是 64 位模式)----
    push dword 0x08
    push dword K64_LOAD_ADDR
    retf

; ===========================================================================
;  数据
; ===========================================================================
align 16
; 64 位 GDT:0x08 代码段(L=1)/ 0x10 数据段
x64_gdt:
    dq 0x0000000000000000
    dq 0x00AF9A000000FFFF
    dq 0x00CF92000000FFFF
x64_gdt_end:
; 注意:QEMU 在 EFER.LMA=1 的兼容模式下执行 LGDT 也按 10 字节操作数读,
; 所以这里直接给满 10 字节(32 位真机上多余 4 字节会被忽略)。
x64_gdt_desc:
    dw x64_gdt_end - x64_gdt - 1
    dq x64_gdt

x64_last_name  dd 0
x64_file_size  dd 0

x64_path_k64   db 'BIN/K64.BIN', 0

msg_x64_jump   db 'start64: jumping to 64-bit kernel at 0x03010000 (long mode)', 10, 0
msg_x64_nocpu  db 'start64: CPU does not support long mode (PAE/LM)', 10, 0
msg_x64_needram db 'start64: need more RAM (at least 64 MiB)', 10, 0
msg_x64_nofile db 'start64: BIN/K64.BIN not found (rebuild the disk image)', 10, 0
msg_x64_toobig db 'start64: K64.BIN too big (max 128 KiB)', 10, 0
msg_x64_readerr db 'start64: read error', 10, 0
