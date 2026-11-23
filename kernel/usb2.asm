; ============================================================================
;  KKernel — 双控制器 USB 栈:UHCI + EHCI + 热插拔
;
;  这个文件是 USB 子系统的"入口层",负责:
;    · usb_init:开机初始化两个控制器(UHCI 在 usb.asm、EHCI 在 ehci.asm),
;      再把开机时就插着的设备枚举出来
;    · usb_control / usb_arm_int:按设备所属控制器把传输分发给 UHCI 或 EHCI
;    · usb_poll:IRQ0 里的轮询(键盘中断 + 热插拔变化检测)
;    · usb_hotplug_task:线程上下文里真正处理热插拔(枚举/下线)
;    · cmd_usb:shell 的 usb 命令(控制器 + 设备记录)
;
;  ── 设备记录 ────────────────────────────────────────────────────────────
;  本内核的 USB 只认两种设备:一个 HID boot 键盘(kb_*)、一个 USB 大容量
;  储存(usbdisk 里的 usbdis_*)。每条记录里带 ctrl(1=UHCI,2=EHCI)、port、
;  speed(0=全速,2=高速)、addr、端点、mps。传输时按记录里的 ctrl 分发。
;  多个同类设备:后来的覆盖前面的(够用;测试也只插一个键盘/一个 U 盘)。
;
;  ── 热插拔怎么分工 ──────────────────────────────────────────────────────
;  IRQ0(usb_poll,100 Hz)只做**只看不碰**:读两侧 PORTSC 的连接位,和
;  "已用端口"位图比对,有不一致就置 usb_hotplug_pending。真正的端口复位/
;  枚举/SCSI 探测需要几十毫秒、还要 hlt 等,放在线程上下文的
;  usb_hotplug_task 里(挂 shell 等待按键的 hlt 循环前)。
;
;  ── 端口归属 ────────────────────────────────────────────────────────────
;  EHCI 的端口复位流程里,低速/全速设备会被置 PORTSC.OWNER 交给 companion
;  (UHCI)控制器;本文件扫 EHCI 端口时看到 OWNER 就跳过,等 companion 侧的
;  端口自己冒出来再枚举。QEMU 里 EHCI 上挂的 usb-kbd 也会被报成高速,
;  所以本内核实现了 EHCI 的中断传输(见 ehci.asm)。
; ============================================================================

; ===========================================================================
;  usb_init:开机调一次(kmain 在 pci_scan 之后)。失败不停机。
;  没有 USB 控制器时静默返回(没有 USB 的机器行为不变)。
; ===========================================================================
usb_init:
    pushad
    mov byte [usb_ready], 0
    mov byte [usb_hid_ok], 0
    mov byte [usb_msd_ok], 0
    mov byte [usb_uhci_ok], 0
    mov byte [usb_hotplug_pending], 0
    mov dword [usb_uhci_ports_used], 0
    mov dword [ehci_ports_used], 0
    mov dword [usb_next_addr], 1
    mov dword [kb_ctrl], 0
    mov byte [kb_present], 0
    mov dword [usb_msd_ctrl], 0
    mov dword [usb_ctl_ctrl], 1

    ; ---- UHCI(老驱动;成功时 usb_uhci_init 内部置 usb_uhci_ok=1)----
    call usb_uhci_init

    ; ---- EHCI(没有控制器 / 初始化失败时 ehci_ok=0)----
    call ehci_init

    cmp byte [usb_uhci_ok], 0
    jne .have_ctrl
    cmp byte [ehci_ok], 0
    je .silent

.have_ctrl:
    ; ---- 第一次热插拔处理:把开机时就插着的设备枚举出来 ----
    call usb_hotplug_process
    mov byte [usb_ready], 1
    popad
    ret
.silent:
    popad
    ret

; ===========================================================================
;  usb_control:控制传输的顶层分发(ABI 与 usb_uhci_control 完全相同)
;    esi = SETUP 8B, edi = 数据缓冲, ecx = 长度, edx = 1 IN / 0 无数据
; ===========================================================================
usb_control:
    cmp dword [usb_ctl_ctrl], 2
    je ehci_control
    jmp usb_uhci_control

; ===========================================================================
;  usb_arm_int:重新挂键盘中断 IN 的顶层分发
; ===========================================================================
usb_arm_int:
    cmp dword [kb_ctrl], 2
    je ehci_int_arm
    jmp usb_uhci_arm_int

; ===========================================================================
;  usb_poll:IRQ0(100 Hz)调
;    · 先扫端口变化(只置 pending,不枚举)
;    · UHCI 键盘:/EHCI 键盘:按 kb_ctrl 走各自的中断处理
; ===========================================================================
usb_poll:
    pushad
    pushf
    call usb_hotplug_scan_irq
    cmp byte [usb_ready], 0
    je .out
    cmp byte [usb_uhci_ok], 0
    je .try_ehci
    cmp dword [kb_ctrl], 1
    jne .try_ehci
    call usb_uhci_poll
.try_ehci:
    cmp byte [ehci_ok], 0
    je .out
    cmp dword [kb_ctrl], 2
    jne .out
    call ehci_int_poll
.out:
    popf
    popad
    ret

; ===========================================================================
;  usb_hotplug_scan_irq:IRQ0 上下文,只读 PORTSC 比对,不碰设备
; ===========================================================================
usb_hotplug_scan_irq:
    pushad
    ; ---- UHCI:2 个端口 ----
    cmp byte [usb_uhci_ok], 0
    je .ehci_scan
    xor ebx, ebx
.u_port:
    mov ecx, ebx
    call usb_read_port
    movzx eax, ax
    test eax, USB_P_CCS
    jz .u_gone
    bt dword [usb_uhci_ports_used], ebx
    jc .u_next
    mov byte [usb_hotplug_pending], 1
    jmp .u_next
.u_gone:
    bt dword [usb_uhci_ports_used], ebx
    jnc .u_next
    mov byte [usb_hotplug_pending], 1
.u_next:
    inc ebx
    cmp ebx, 2
    jb .u_port

.ehci_scan:
    cmp byte [ehci_ok], 0
    je .out
    xor ebx, ebx
.e_port:
    cmp ebx, [ehci_ports]
    jae .out
    mov ecx, ebx
    call ehci_read_portsc
    test eax, EHCI_PS_OWNER
    jnz .e_next                     ; 交给 companion 的端口不归我们管
    test eax, EHCI_PS_CCS
    jz .e_gone
    bt dword [ehci_ports_used], ebx
    jc .e_next
    mov byte [usb_hotplug_pending], 1
    jmp .e_next
.e_gone:
    bt dword [ehci_ports_used], ebx
    jnc .e_next
    mov byte [usb_hotplug_pending], 1
.e_next:
    inc ebx
    jmp .e_port
.out:
    popad
    ret

; ===========================================================================
;  usb_hotplug_task:线程上下文(shell 等键的 hlt 循环前)调
;  pending 才真正处理;端口复位/枚举/SCSI 探测都可能 hlt 等几十毫秒。
; ===========================================================================
usb_hotplug_task:
    pushad
    cmp byte [usb_ready], 0
    je .out
    cmp byte [usb_hotplug_pending], 0
    je .out
    mov byte [usb_hotplug_pending], 0
    call usb_hotplug_process
.out:
    popad
    ret

; ===========================================================================
;  usb_hotplug_process:遍历两个控制器的端口
;    · 新连上(CCS=1 且未标记 used)→ 复位端口 + 枚举 + 填设备记录
;    · 断开(used 但 CCS=0)→ 清记录(键盘/优盘各自处理)
; ===========================================================================
usb_hotplug_process:
    pushad
    ; 枚举/复位/控制传输与 BOT 批量共用控制器 QH/qTD/数据缓冲,必须互斥。
    ; mutex 可重入(hotplug 里的 usbdisk_init 再进 usb_bot 没问题)。
    mov eax, usb_mutex
    call mutex_lock

    ; ---------- UHCI:2 个端口 ----------
    cmp byte [usb_uhci_ok], 0
    je .ehci_part
    xor ebx, ebx
.u_port:
    mov ecx, ebx
    call usb_read_port
    movzx eax, ax
    test eax, USB_P_CCS
    jz .u_gone
    bt dword [usb_uhci_ports_used], ebx
    jc .u_next
    ; 新设备:复位(usb_port_reset 会开 PE)→ 枚举
    mov ecx, ebx
    call usb_port_reset
    test eax, eax
    jz .u_mark                    ; 复位失败:先标 used,免得每 tick 重试
    bts dword [usb_uhci_ports_used], ebx
    mov dword [usb_ctl_ctrl], 1
    mov dword [usb_ctl_speed], 0
    mov eax, ebx
    inc eax
    mov [usb_scan_port], eax
    call usb_enumerate_new
    jmp .u_next
.u_gone:
    bt dword [usb_uhci_ports_used], ebx
    jnc .u_next
    btr dword [usb_uhci_ports_used], ebx
    mov dword [usb_ctl_ctrl], 1
    mov eax, ebx
    inc eax
    mov [usb_scan_port], eax
    call usb_detach_port
    jmp .u_next
.u_mark:
    bts dword [usb_uhci_ports_used], ebx
.u_next:
    inc ebx
    cmp ebx, 2
    jb .u_port

    ; ---------- EHCI:ports 个端口 ----------
.ehci_part:
    cmp byte [ehci_ok], 0
    je .out
    xor ebx, ebx
.e_port:
    cmp ebx, [ehci_ports]
    jae .out
    mov ecx, ebx
    call ehci_read_portsc
    test eax, EHCI_PS_OWNER
    jnz .e_next                     ; 归 companion 的端口跳过
    test eax, EHCI_PS_CCS
    jz .e_gone
    bt dword [ehci_ports_used], ebx
    jc .e_next
    ; 新设备:复位(只对高速设备成功)→ 枚举
    mov ecx, ebx
    call ehci_port_reset
    test eax, eax
    jz .e_mark
    bts dword [ehci_ports_used], ebx
    mov dword [usb_ctl_ctrl], 2
    mov dword [usb_ctl_speed], 2
    mov eax, ebx
    inc eax
    mov [usb_scan_port], eax
    call usb_enumerate_new
    jmp .e_next
.e_gone:
    bt dword [ehci_ports_used], ebx
    jnc .e_next
    btr dword [ehci_ports_used], ebx
    mov dword [usb_ctl_ctrl], 2
    mov eax, ebx
    inc eax
    mov [usb_scan_port], eax
    call usb_detach_port
    jmp .e_next
.e_mark:
    bts dword [ehci_ports_used], ebx
.e_next:
    inc ebx
    jmp .e_port
.out:
    mov eax, usb_mutex
    call mutex_unlock
    popad
    ret

; ===========================================================================
;  usb_enumerate_new:通用枚举 + 按类型填设备记录
;   返回 usb_enumerate 的返回值(已经在记录里落好)
; ===========================================================================
usb_enumerate_new:
    pushad
    call usb_enumerate
    cmp eax, 2
    je .hid
    cmp eax, 3
    je .msd
    jmp .out
.hid:
    mov byte [kb_present], 1
    mov eax, [usb_ctl_ctrl]
    mov [kb_ctrl], eax
    mov eax, [usb_ctl_speed]
    mov [kb_speed], eax
    mov eax, [usb_ctl_addr]
    mov [kb_addr], eax
    mov eax, [usb_scan_port]
    mov [kb_port], eax
    mov eax, [usb_ep_addr]
    mov [kb_ep], eax
    mov eax, [usb_ep_mps]
    mov [kb_mps], eax
    mov eax, [usb_ep_interval]
    mov [kb_interval], eax
    mov byte [kb_toggle], 0
    mov byte [usb_toggle], 0
    cmp byte [kb_ctrl], 2
    je .hid_arm
    ; UHCI 键盘:usb_uhci_arm_int 用 usb_dev_addr(旧驱动里的全局)
    mov eax, [kb_addr]
    mov [usb_dev_addr], eax
.hid_arm:
    call usb_arm_int
    jmp .out
.msd:
    mov byte [usb_msd_ok], 1
    mov eax, [usb_ctl_ctrl]
    mov [usb_msd_ctrl], eax
    mov eax, [usb_ctl_speed]
    mov [msd_speed], eax
    mov eax, [usb_ctl_addr]
    mov [usb_msd_addr], eax
    mov eax, [usb_scan_port]
    mov [msd_port], eax
    ; 把枚举时的 scratch 端点信息落进 U 盘自己的全局(usbdisk.asm 用)
    mov eax, [usb_scratch_ep_in]
    mov [usb_msd_ep_in], eax
    mov eax, [usb_scratch_ep_out]
    mov [usb_msd_ep_out], eax
    mov eax, [usb_scratch_mps_in]
    mov [usb_msd_mps_in], eax
    mov eax, [usb_scratch_mps_out]
    mov [usb_msd_mps_out], eax
    ; 重新做 SCSI 探测(READ CAPACITY 等)
    call usbdisk_init
.out:
    popad
    ret

; ===========================================================================
;  usb_detach_port:某个端口上的设备下线(usb_ctl_ctrl/scan_port 已由调用方设好)
; ===========================================================================
usb_detach_port:
    pushad
    ; ---- 是我们的键盘吗?----
    cmp byte [kb_present], 0
    je .msd
    mov eax, [usb_ctl_ctrl]
    cmp [kb_ctrl], eax
    jne .msd
    mov eax, [usb_scan_port]
    cmp [kb_port], eax
    jne .msd
    mov byte [kb_present], 0
    mov byte [usb_hid_ok], 0
    mov dword [kb_ctrl], 0
    ; EHCI 的中断 QH 不用特别停:qTD 会自然停,usb_hid_ok=0 后不再 poll
.msd:
    ; ---- 是我们的 U 盘吗?----
    cmp byte [usb_msd_ok], 0
    je .out
    mov eax, [usb_ctl_ctrl]
    cmp [usb_msd_ctrl], eax
    jne .out
    mov eax, [usb_scan_port]
    cmp [msd_port], eax
    jne .out
    call usbdisk_on_unplug           ; usbdisk.asm:ready=0 + 已挂载就强制回 ATA
    ; 拔掉后 usbdisk 命令必须回到"没有 U 盘"的状态,设备记录一并清掉
    mov byte [usb_msd_ok], 0
    mov dword [usb_msd_ctrl], 0
    mov dword [msd_port], 0
    mov dword [usb_msd_addr], 0
.out:
    popad
    ret

; ===========================================================================
;  usb_print_ctrl:eax = 控制器号(1=UHCI,2=EHCI)→ 打印控制器名
; ===========================================================================
usb_print_ctrl:
    cmp eax, 2
    je .ehci
    mov esi, msg_ctrl_uhci
    jmp term_print
.ehci:
    mov esi, msg_ctrl_ehci
    jmp term_print

; ===========================================================================
;  cmd_usb:shell 的 usb 命令
; ===========================================================================
cmd_usb:
    pushad
    cmp byte [usb_uhci_ok], 0
    jne .have
    cmp byte [ehci_ok], 0
    jne .have
    cmp dword [pci_usb_addr], -1
    je .none
    mov esi, msg_usb_notinit
    call term_print
    jmp .done
.none:
    mov esi, msg_usb_none
    call term_print
    jmp .done
.have:

    ; ---- UHCI 控制器行(格式与旧版一致,test-usb 依赖)----
    cmp byte [usb_uhci_ok], 0
    je .ehci_line
    mov esi, msg_usb_ctrl
    call term_print
    mov eax, [pci_usb_id]
    call pci_ph4
    mov al, ':'
    call term_putc
    mov eax, [pci_usb_id]
    shr eax, 16
    call pci_ph4
    mov esi, msg_usb_io
    call term_print
    mov eax, [usb_iobase]
    call pci_ph4
    mov esi, msg_usb_p1
    call term_print
    xor ecx, ecx
    call usb_read_port
    movzx eax, ax
    call pci_ph4
    mov esi, msg_usb_p2
    call term_print
    mov ecx, 1
    call usb_read_port
    movzx eax, ax
    call pci_ph4
    mov al, 10
    call term_putc

.ehci_line:
    ; ---- EHCI 控制器行 ----
    cmp byte [ehci_ok], 0
    je .devices
    mov esi, msg_usb_ehci
    call term_print
    mov eax, [ehci_id]
    call pci_ph4
    mov al, ':'
    call term_putc
    mov eax, [ehci_id]
    shr eax, 16
    call pci_ph4
    mov esi, msg_usb_mmio
    call term_print
    mov eax, [ehci_mmio_phys]
    call pci_ph4
    mov esi, msg_usb_ports
    call term_print
    mov eax, [ehci_ports]
    call term_print_dec
    mov al, 10
    call term_putc
.devices:
    ; ---- 键盘设备行:usb: kbd ctrl=UHCI port=1 speed=full addr=1 class=HID ----
    cmp byte [kb_present], 0
    je .msd_line
    mov esi, msg_usb_kbd
    call term_print
    mov eax, [kb_ctrl]
    call usb_print_ctrl
    mov esi, msg_usb_port
    call term_print
    mov eax, [kb_port]
    call term_print_dec
    mov esi, msg_usb_speed
    call term_print
    cmp dword [kb_speed], 2
    je .kb_high
    mov esi, msg_speed_full
    call term_print
    jmp .kb_addr
.kb_high:
    mov esi, msg_speed_high
    call term_print
.kb_addr:
    mov esi, msg_usb_addr
    call term_print
    mov eax, [kb_addr]
    call term_print_dec
    mov esi, msg_usb_hid
    call term_print

.msd_line:
    ; ---- U 盘设备行:usb: msd ctrl=EHCI port=1 speed=high addr=2 class=MSD ----
    cmp byte [usb_msd_ok], 0
    je .hid_tail
    mov esi, msg_usb_msdline
    call term_print
    mov eax, [usb_msd_ctrl]
    call usb_print_ctrl
    mov esi, msg_usb_port
    call term_print
    mov eax, [msd_port]
    call term_print_dec
    mov esi, msg_usb_speed
    call term_print
    cmp dword [msd_speed], 2
    je .msd_high
    mov esi, msg_speed_full
    call term_print
    jmp .msd_addr
.msd_high:
    mov esi, msg_speed_high
    call term_print
.msd_addr:
    mov esi, msg_usb_addr
    call term_print
    mov eax, [usb_msd_addr]
    call term_print_dec
    mov esi, msg_usb_msdclass
    call term_print
    ; 容量行(usbdisk 的 READ CAPACITY 结果):N sectors x 512 B = M KiB
    mov esi, msg_usb_msdinfo
    call term_print
    mov eax, [usbdisk_lba]
    call term_print_dec
    mov esi, msg_usb_sectors
    call term_print
    mov eax, [usbdisk_block]
    call term_print_dec
    mov esi, msg_usb_b
    call term_print
    mov eax, [usbdisk_lba]
    imul eax, [usbdisk_block]
    shr eax, 10                     ; ⟶ KiB
    call term_print_dec
    mov esi, msg_usb_kib
    call term_print
    mov al, 10
    call term_putc

.hid_tail:
    ; ---- HID 就绪尾巴(test-usb-kbd 依赖)----
    cmp byte [usb_hid_ok], 0
    je .nodev_check
    mov esi, msg_usb_ok
    call term_print
    mov esi, msg_usb_reports
    call term_print
    mov eax, [usb_hid_reports]
    call term_print_dec
    mov al, 10
    call term_putc
    jmp .done
.nodev_check:
    cmp byte [kb_present], 0
    jne .done
    cmp byte [usb_msd_ok], 0
    jne .done
    mov esi, msg_usb_nodev
    call term_print
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  数据
; ---------------------------------------------------------------------------
usb_mutex         times 12 db 0 ; 串行化所有 USB 传输(hotplug 枚举/BOT 批量);kernel/lock.asm mutex
usb_uhci_ok       db 0          ; UHCI 控制器可用
usb_ctl_ctrl      dd 1          ; 当前枚举中的设备属于哪个控制器(1=UHCI,2=EHCI)
usb_ctl_addr      dd 0          ; 当前枚举中的设备地址
usb_ctl_mps       dd 8          ; 当前枚举中的控制端点 mps
usb_ctl_speed     dd 0          ; 当前枚举中的设备速度(0=全速,2=高速)
usb_scan_port     dd 0          ; 当前枚举中的端口号(从 1 开始)
usb_next_addr     dd 1          ; 下一个要分配的 USB 设备地址(1..127)
usb_hotplug_pending db 0        ; IRQ0 发现端口变化,等线程上下文处理
usb_uhci_ports_used dd 0        ; UHCI 端口占用位图(bit0=port1)
ehci_ports_used   dd 0          ; EHCI 端口占用位图

kb_present        db 0          ; 键盘记录有效
kb_ctrl           dd 0          ; 键盘在哪个控制器(1=UHCI,2=EHCI)
kb_port           dd 0          ; 端口号(从 1 开始)
kb_speed          dd 0
kb_addr           dd 0          ; USB 设备地址
kb_ep             dd 0          ; 中断 IN 端点地址
kb_mps            dd 0
kb_interval       dd 0
kb_toggle         db 0          ; HID 报告的 DATA0/DATA1 翻转

usb_msd_ctrl      dd 0          ; U 盘在哪个控制器
msd_speed         dd 0
usb_msd_addr      dd 0          ; U 盘设备地址(usbdisk.asm 的 bulk 传输用)
msd_port          dd 0

; 枚举期间的中断/批量端点暂存(枚举解析往这里写,结束再按类型落进记录,
; 这样"插键盘"不会冲掉已经在用的 U 盘端点信息)
usb_scratch_ep_in   dd 0
usb_scratch_ep_out  dd 0
usb_scratch_mps_in  dd 0
usb_scratch_mps_out dd 0

; ---------------------------------------------------------------------------
;  消息
; ---------------------------------------------------------------------------
msg_usb_ehci    db 'usb: EHCI ', 0
msg_usb_mmio    db ' mmio ', 0
msg_usb_ports   db ' ports ', 0
msg_usb_kbd     db 'usb: kbd ctrl=', 0
msg_usb_msdline db 'usb: msd ctrl=', 0
msg_ctrl_uhci   db 'UHCI', 0
msg_ctrl_ehci   db 'EHCI', 0
msg_usb_port    db ' port=', 0
msg_usb_speed   db ' speed=', 0
msg_speed_full  db 'full', 0
msg_speed_high  db 'high', 0
msg_usb_addr    db ' addr=', 0
msg_usb_hid     db ' class=HID', 10, 0
msg_usb_msdclass db ' class=MSD', 10, 0
msg_usb_msdinfo db 'usbdisk: ', 0
msg_usb_sectors db ' sectors x ', 0
msg_usb_b       db ' B = ', 0
msg_usb_kib     db ' KiB', 0
