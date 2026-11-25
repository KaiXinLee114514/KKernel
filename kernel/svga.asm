; ===========================================================================
;  svga.asm —— VMware SVGA(VMSVGA)显示更新驱动
;
;  为什么需要它:
;    VirtualBox 把显卡模拟成 VMSVGA(VMware SVGA 兼容设备,PCI 15AD:0405)。
;    在 legacy VBE 模式下,VBE 的线性帧缓冲写入不会可靠地推送到宿主显示
;    (宿主只按自己的脏页跟踪刷新,表现为屏幕"拼帧"/叠字)。VMSVGA 的正规
;    刷新通道是 SVGA FIFO:guest 往 FIFO 里塞 SVGA_CMD_UPDATE 矩形并敲
;    SVGA_REG_SYNC,VMSVGA 设备异步处理后刷新显示。
;
;    本驱动只在 PCI 上真的发现 15AD:0405 时启用(QEMU 的 stdvga、真机
;    VGA 都不受影响:svga_ok=0,所有入口立即返回,零开销)。
;
;  挂载点:
;    kernel/kmain.asm 里 paging_init 之后 call svga_try_init
;    (必须在分页开启后:需要 paging_map 把设备 MEM 区映射到固定 VA)。
;
;  刷新策略:
;    fbterm 只把"有变化"记成 svga_dirty,由 svga_tick(PIT IRQ0,每 100ms)
;    发一笔整屏 UPDATE。逐行小矩形更新在 VMSVGA 上实测会被合并成拼帧,
;    因此不用。
;
;  参考: Linux drivers/gpu/drm/vmwgfx(vmwgfx_cmd.c / vmwgfx_drv.c /
;        device_include/svga_reg.h)与 VMware SVGA 接口文档。
; ===========================================================================

SVGA_VENDOR_ID  equ 0x15AD
SVGA_DEVICE_ID  equ 0x0405

; ---- SVGA 寄存器索引(见 svga_reg.h)----
SVGA_REG_ENABLE          equ 1
SVGA_REG_WIDTH           equ 2
SVGA_REG_HEIGHT          equ 3
SVGA_REG_BITS_PER_PIXEL  equ 7
SVGA_REG_BYTES_PER_LINE  equ 12
SVGA_REG_FB_START        equ 13
SVGA_REG_MEM_START       equ 18
SVGA_REG_MEM_SIZE        equ 19
SVGA_REG_CONFIG_DONE     equ 20
SVGA_REG_SYNC            equ 21
SVGA_REG_MEM_REGS        equ 30

; ---- FIFO 内部寄存器(相对设备 MEM 区的 dword 下标)----
SVGA_FIFO_MIN       equ 0
SVGA_FIFO_MAX       equ 1
SVGA_FIFO_NEXT_CMD  equ 2
SVGA_FIFO_STOP      equ 3
SVGA_FIFO_BUSY      equ 290
SVGA_FIFO_RESERVED  equ 14          ; 写命令期间标记(设备 CAP_RESERVE)

SVGA_CMD_UPDATE     equ 1           ; 参数:x,y,w,h 四个 u32(像素)
SVGA_SYNC_GENERIC   equ 1

SVGA_MEM_VA         equ 0xF1000000  ; 设备 MEM 区前 8KiB 映射到的固定虚拟地址
SVGA_MEM_MAP_SIZE   equ 8192
SVGA_FIFO_SIZE      equ 4096        ; FIFO 环大小(在已映射的 8KiB 窗口内)
SVGA_UPDATE_BYTES   equ 20          ; 一条 UPDATE 命令 = 5 个 dword

; ---------------------------------------------------------------------------
;  svga_read:eax = 寄存器索引 → eax = 值
; ---------------------------------------------------------------------------
svga_read:
    push edx
    mov dx, [svga_port]
    out dx, eax                     ; index
    inc dx
    in eax, dx                      ; value
    pop edx
    ret

; ---------------------------------------------------------------------------
;  svga_write:eax = 寄存器索引,ebx = 值
; ---------------------------------------------------------------------------
svga_write:
    push eax
    push edx
    mov dx, [svga_port]
    out dx, eax                     ; index
    inc dx
    mov eax, ebx
    out dx, eax                     ; value
    pop edx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  svga_update:把一块矩形内容推给宿主显示
;    eax = x, ebx = y, ecx = w, edx = h(像素)
;  FIFO 满/设备不响应时放弃本笔(下一笔 100ms 后还会来,不会卡死)。
; ---------------------------------------------------------------------------
svga_update:
    pushad
    cmp byte [svga_ok], 0
    je .done
    mov [svga_u_x], eax
    mov [svga_u_y], ebx
    mov [svga_u_w], ecx
    mov [svga_u_h], edx
    ; ---- 等 FIFO 腾出 20 字节(设备用 STOP 表示消费到哪)----
    mov ebp, 300000
.wait_space:
    mov edi, [SVGA_MEM_VA + SVGA_FIFO_NEXT_CMD * 4]
    mov eax, [SVGA_MEM_VA + SVGA_FIFO_STOP * 4]
    mov ebx, [SVGA_MEM_VA + SVGA_FIFO_MAX * 4]
    mov ecx, [SVGA_MEM_VA + SVGA_FIFO_MIN * 4]
    cmp edi, eax
    jae .next_ge_stop
    mov edx, eax
    sub edx, edi                    ; 空闲 = stop - next
    jmp .have_free
.next_ge_stop:
    mov edx, ebx
    sub edx, edi                    ; 空闲 = (max-next) + (stop-min)
    add eax, edx
    mov edx, eax
    sub edx, ecx
.have_free:
    cmp edx, SVGA_UPDATE_BYTES
    jae .room
    dec ebp
    jnz .wait_space
    jmp .done                       ; 队列满:这一笔丢掉
.room:
    ; ---- 命令不能跨过环末尾 ----
    mov edi, [SVGA_MEM_VA + SVGA_FIFO_NEXT_CMD * 4]
    mov ebx, [SVGA_MEM_VA + SVGA_FIFO_MAX * 4]
    mov eax, ebx
    sub eax, edi
    cmp eax, SVGA_UPDATE_BYTES
    jae .in_place
    mov edi, [SVGA_MEM_VA + SVGA_FIFO_MIN * 4]
.in_place:
    ; ---- 写命令:期间用 RESERVED 标记,写完后更新 NEXT_CMD ----
    mov dword [SVGA_MEM_VA + SVGA_FIFO_RESERVED * 4], SVGA_UPDATE_BYTES
    mov ebx, SVGA_MEM_VA
    add ebx, edi
    mov dword [ebx], SVGA_CMD_UPDATE
    mov eax, [svga_u_x]
    mov [ebx + 4], eax
    mov eax, [svga_u_y]
    mov [ebx + 8], eax
    mov eax, [svga_u_w]
    mov [ebx + 12], eax
    mov eax, [svga_u_h]
    mov [ebx + 16], eax
    add edi, SVGA_UPDATE_BYTES
    cmp edi, [SVGA_MEM_VA + SVGA_FIFO_MAX * 4]
    jb .next_ok
    mov edi, [SVGA_MEM_VA + SVGA_FIFO_MIN * 4]
.next_ok:
    mov [SVGA_MEM_VA + SVGA_FIFO_NEXT_CMD * 4], edi
    mov dword [SVGA_MEM_VA + SVGA_FIFO_RESERVED * 4], 0
    ; ---- 敲门铃:置 BUSY 再写 SVGA_REG_SYNC ----
    mov dword [SVGA_MEM_VA + SVGA_FIFO_BUSY * 4], 1
    mov eax, SVGA_REG_SYNC
    mov ebx, SVGA_SYNC_GENERIC
    call svga_write
    mov byte [svga_dirty], 1
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  svga_full_update:整屏推一次(未启用时立即返回)
; ---------------------------------------------------------------------------
svga_full_update:
    pushad
    cmp byte [svga_ok], 0
    je .done
    xor eax, eax                    ; x = 0
    xor ebx, ebx                    ; y = 0
    mov ecx, [fb_width]             ; w = 屏宽
    mov edx, [fb_height]            ; h = 屏高
    call svga_update
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  svga_tick:PIT IRQ0 里调。有脏数据时最多 100ms 发一次整屏刷新。
; ---------------------------------------------------------------------------
svga_tick:
    pushad
    cmp byte [svga_ok], 0
    je .done
    cmp byte [svga_dirty], 0
    je .done
    call pit_get_ticks
    sub eax, [svga_last_refresh]
    cmp eax, 10                     ; 100 ms
    jb .done
    call pit_get_ticks
    mov [svga_last_refresh], eax
    call svga_full_update
    mov byte [svga_dirty], 0        ; full_update 里会再置,清掉
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  svga_try_init:在 PCI 上找 VMSVGA 并打开它的显示引擎。
;    失败(没这设备/参数不对/映射失败)→ svga_ok=0,退回 legacy VBE 路径。
;    必须在 paging_init 之后调用。
; ---------------------------------------------------------------------------
svga_try_init:
    pushad
    mov byte [svga_ok], 0
    ; ---- 1) 扫 PCI bus0 slot2..7,找 15AD:0405 ----
    xor ebx, ebx                    ; ebx = slot
.slot_loop:
    add ebx, 2
    cmp ebx, 8
    jae .out
    xor eax, eax                    ; bus = 0
    xor ecx, ecx                    ; func = 0
    xor edx, edx                    ; offset = 0(id)
    call pci_mk_addr
    call pci_read32
    cmp eax, (SVGA_DEVICE_ID << 16) | SVGA_VENDOR_ID
    jne .slot_loop
    ; ---- 2) 取 BAR0(I/O 基址),允许低 2 位标志 ----
    xor eax, eax
    xor ecx, ecx
    mov edx, 0x10                   ; BAR0
    call pci_mk_addr
    call pci_read32
    and eax, 0xFFFC
    mov [svga_port], ax
    ; ---- 3) 打开 I/O 空间(有些 BIOS 已开,保险起见)----
    mov dword [pci_bus], 0
    mov [pci_slot], ebx
    mov dword [pci_func], 0
    call pci_cur_read               ; → eax = command/status dword(低 16 位是 command)
    and eax, 0xFFFF
    or eax, 1                       ; I/O space enable
    call pci_write_command          ; 16 位写 command
    ; ---- 4) 校验 FB_START 与内核用的 LFB 物理地址一致 ----
    mov eax, SVGA_REG_FB_START
    call svga_read
    cmp eax, [fb_phys]
    jne .out
    ; ---- 5) 读 MEM_START(设备 FIFO 所在物理地址)与 MEM_SIZE ----
    mov eax, SVGA_REG_MEM_START
    call svga_read
    test eax, 0xFFF
    jnz .out                        ; 必须 4KiB 对齐
    mov [svga_mem_phys], eax
    mov eax, SVGA_REG_MEM_SIZE
    call svga_read
    cmp eax, SVGA_MEM_MAP_SIZE
    jb .out                         ; 太小,放不下 FIFO
    mov [svga_mem_size], eax
    ; ---- 6) 把 MEM 区前 8KiB 映射到固定 VA ----
    mov eax, SVGA_MEM_VA
    mov ebx, [svga_mem_phys]
    mov ecx, PAGE_P | PAGE_RW
    call paging_map
    jc .out
    ; ---- 7) 初始化 FIFO(照 vmwgfx 的 vmw_fifo_create)----
    mov eax, SVGA_REG_MEM_REGS
    call svga_read
    shl eax, 2                      ; MIN = MEM_REGS * 4
    cmp eax, 4096
    jae .min_ok
    mov eax, 4096
.min_ok:
    mov [svga_fifo_min], eax
    mov ebx, eax
    mov [SVGA_MEM_VA + SVGA_FIFO_MIN * 4], ebx
    add ebx, SVGA_FIFO_SIZE
    mov [SVGA_MEM_VA + SVGA_FIFO_MAX * 4], ebx
    mov [SVGA_MEM_VA + SVGA_FIFO_NEXT_CMD * 4], eax
    mov [SVGA_MEM_VA + SVGA_FIFO_STOP * 4], eax
    mov dword [SVGA_MEM_VA + SVGA_FIFO_BUSY * 4], 0
    ; ---- 8) 显示模式参数(legacy VBE 下设备显示尺寸可能没初始化)----
    mov eax, SVGA_REG_WIDTH
    mov ebx, [fb_width]
    call svga_write
    mov eax, SVGA_REG_HEIGHT
    mov ebx, [fb_height]
    call svga_write
    mov eax, SVGA_REG_BITS_PER_PIXEL
    mov ebx, 32
    call svga_write
    mov eax, SVGA_REG_BYTES_PER_LINE
    mov ebx, [fb_pitch]
    call svga_write
    ; ---- 9) 打开显示引擎 + 配置完成 ----
    mov eax, SVGA_REG_ENABLE
    mov ebx, 3                      ; ENABLE(1) | HIDE(2) —— 与 vmwgfx 驱动一致
    call svga_write
    mov eax, SVGA_REG_CONFIG_DONE
    mov ebx, 1
    call svga_write
    mov byte [svga_ok], 1
    ; ---- 10) 当前屏幕内容整屏推一次 ----
    call svga_full_update
.out:
    popad
    ret

; ---------------------------------------------------------------------------
;  数据
; ---------------------------------------------------------------------------
svga_ok         db 0
svga_dirty      db 0
svga_port       dw 0
svga_last_refresh dd 0
svga_mem_phys   dd 0
svga_mem_size   dd 0
svga_fifo_min   dd 0
svga_u_x        dd 0
svga_u_y        dd 0
svga_u_w        dd 0
svga_u_h        dd 0
