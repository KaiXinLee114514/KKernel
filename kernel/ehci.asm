; ============================================================================
;  KKernel — EHCI(USB 2.0)主机控制器驱动
;
;  只做三件事:
;    1) PCI 探测 + BAR0(4 KiB MMIO)映射到固定虚拟地址 + 控制器复位/跑起来
;    2) 高速设备的三种传输:control / bulk / interrupt
;    3) 根端口的 PORTSC 读取与端口复位(EHCI 只跑高速;低速/全速设备交
;       companion UHCI —— 本内核里 QEMU 的 usb-kbd 若挂 ehci.0 也是高速)
;
;  枚举(FAT 里的 set_address/读描述符/认 HID 还是 MSC)不在这里:usb.asm 的
;  通用枚举经 usb_control 分发过来。本文件只提供 HC 传输层 + 端口状态。
;
;  ── 为什么只用一枚异步 QH ──────────────────────────────────────────────
;  控制传输和 bulk 传输在本内核里都是"线程上下文里同步等结果":枚举、
;  SCSI 命令、热插拔任务都串行发生(我们的 shell 同一时刻只有一条命令在跑,
;  热插拔任务也只在 shell 空闲时执行)。所以不需要完整异步调度器:同一时刻
;  只有一笔异步传输。做法:
;    · ASYNCLISTADDR 固定指向 EHCI_ASYNC_QH(自环、H 位=1);
;    · 每次传输把 qTD 链挂上去、把 QH token 从 HALT 改成"可跑";
;    · 轮询最后一枚 qTD 的 ACTIVE 位等完成,完了再把 QH 打回 HALT。
;  中断传输单独用周期帧列表里的 EHCI_INT_QH(QEMU 里键盘每 8 ms 挂一次)。
;
;  ── 结构放哪 ────────────────────────────────────────────────────────────
;  0x3C0000-0x3C2FFF:usb.asm / usbdisk.asm(见各自文件头)
;  0x3D2000-0x3D3FFF:本文件(周期帧列表 0x3D2000,异步 QH/qTD 0x3D3000+);
;  0x3D0000-0x3D1FFF 是 pmem 位图,不能碰。都在这段恒等映射的低内存里,
;  交给 EHCI 的指针就是物理地址。
;
;  参考:EHCI 规范 1.0 / Linux drivers/usb/host/ehci-*.c(只抄了最小子集)
; ============================================================================

; ---- BAR0 映射到的固定虚拟地址(4 KiB 对齐)----
EHCI_MMIO_VA     equ 0xFE000000

; ---- 结构区(0x3D2000 起)----
EHCI_FRAME_LIST  equ 0x3D2000       ; 周期帧列表:1024 × 4B = 4 KiB(4 KiB 对齐)
EHCI_ASYNC_QH    equ 0x3D3000       ; 异步列表头 QH(常驻:只当"哑头",不承载传输)
EHCI_XFER_QH     equ 0x3D3040       ; 传输 QH(控制/bulk 共用;挂在头 QH 后面)
EHCI_ASYNC_QTD   equ 0x3D3100       ; 异步 qTD 链:8 枚 × 32B
EHCI_ASYNC_QTD_N equ 8
EHCI_INT_QH      equ 0x3D3200       ; 中断 QH
EHCI_INT_QTD     equ 0x3D3240       ; 中断 qTD(1 枚)
EHCI_INT_BUF     equ 0x3D3260       ; 8 B HID 报告(收到后拷进 usb.asm 的 USB_INT_BUF)

; ---- 操作寄存器(相对 ehci_op = capbase + CAPLENGTH)----
EHCI_CMD         equ 0x00
EHCI_STS         equ 0x04
EHCI_INTR        equ 0x08
EHCI_FRINDEX     equ 0x0C
EHCI_DSSEG       equ 0x10
EHCI_PERIODIC    equ 0x14
EHCI_ASYNC       equ 0x18
EHCI_CFGFLAG     equ 0x40
EHCI_PORTSC      equ 0x44

; command 寄存器位
EHCI_CMD_RUN     equ 0x00000001
EHCI_CMD_RESET   equ 0x00000002      ; HCRESET
EHCI_CMD_PSE     equ 0x00000010      ; 周期调度使能
EHCI_CMD_ASE     equ 0x00000020      ; 异步调度使能
EHCI_CMD_ITC1    equ 0x00010000      ; 中断阈值 = 1 帧

; status 寄存器位
EHCI_STS_INT     equ 0x00000001
EHCI_STS_ERR     equ 0x00000002
EHCI_STS_HALT    equ 0x00001000

; PORTSC 位
EHCI_PS_CCS      equ 0x00000001      ; 当前连接
EHCI_PS_CSC      equ 0x00000002      ; 连接变化(写 1 清)
EHCI_PS_PE       equ 0x00000004      ; 端口使能
EHCI_PS_PEC      equ 0x00000008      ; 端口使能变化(写 1 清)
EHCI_PS_OCC      equ 0x00000010      ; 过流变化(写 1 清)
EHCI_PS_RESET    equ 0x00000100      ; 复位
EHCI_PS_LS       equ 0x00000C00      ; 低速设备标志(bit10)
EHCI_PS_POWER    equ 0x00001000      ; 端口上电
EHCI_PS_OWNER    equ 0x00002000      ; 端口归属:1 = companion(UHCI)
EHCI_PS_PSPD     equ 0x0C000000      ; 端口速度:0=全速 1=低速 2=高速
EHCI_PS_W1C      equ EHCI_PS_CSC | EHCI_PS_PEC | EHCI_PS_OCC

; QH 字段偏移(总 48 B,32 B 对齐)
QH_NEXT          equ 0
QH_INFO1         equ 4
QH_INFO2         equ 8
QH_CURRENT       equ 12
QH_QTD_NEXT      equ 16
QH_ALT_NEXT      equ 20
QH_TOKEN         equ 24
QH_BUF           equ 28

; QH info1 位(Endpoint Characteristics)
QH_RL_HS         equ 4 << 28         ; NAK 重载计数(高速取 4)
QH_HEAD          equ 1 << 15         ; 异步回收列表头
QH_DTC           equ 1 << 14         ; 数据翻转由 qTD 的 DT 位给(控制/bulk/中断都用)
QH_HIGH_SPEED    equ 2 << 12         ; EPS = 高速
; 地址 bit0-6、端点号 bit8-11 由调用方按设备填

; QH info2:高带宽管道倍数,高速普通端点 = 1
QH_MULT_HS       equ 1 << 30
; 周期调度 s-mask:微帧 0
QH_SMASK0        equ 1 << 0

; QH token
QH_TOKEN_HALT    equ 0x40

; qTD 字段偏移(总 32 B,32 B 对齐)
QTD_NEXT         equ 0
QTD_ALT_NEXT     equ 4
QTD_TOKEN        equ 8
QTD_BUF0         equ 12

; qTD token 位
QTD_TOGGLE       equ 0x80000000
QTD_IOC          equ 0x00008000
QTD_CERR3        equ 3 << 10
QTD_PID_OUT      equ 0 << 8
QTD_PID_IN       equ 1 << 8
QTD_PID_SETUP    equ 2 << 8
QTD_ACTIVE       equ 0x00000080
QTD_ERRMASK      equ 0x00000078      ; HALT|DBE|Babble|XactErr

EHCI_LIST_END    equ 1               ; "空指针"

; ===========================================================================
;  ehci_init:开机调一次(由 usb.asm 的 usb_init 在 UHCI 初始化之后调)。
;  扫 PCI → 映射 BAR0 → 控制器复位 → 建周期帧列表/异步 QH → 跑起来 → 端口上电。
;  没有 EHCI 或初始化失败:静默(ehci_ok 保持 0,后续调用都直接返回)。
; ===========================================================================
ehci_init:
    pushad
    mov byte [ehci_ok], 0
    mov dword [ehci_op], 0
    mov dword [ehci_base], 0
    mov dword [ehci_ports], 0
    mov dword [ehci_mmio_phys], 0

    ; ---- 1. PCI 扫描:class 0x0C / sub 0x03 / prog-if 0x20 ----
    xor esi, esi
.pci_slot:
    ; 空槽(读 vendor 得 0xFFFFFFFF)直接跳过
    mov eax, 0
    mov ebx, esi
    xor ecx, ecx
    xor edx, edx
    call pci_mk_addr
    call pci_read32
    cmp eax, 0xFFFFFFFF
    je .pci_next
    ; 读 class/rev 寄存器(offset 0x08)
    mov eax, 0
    mov ebx, esi
    xor ecx, ecx
    mov edx, 0x08
    call pci_mk_addr
    call pci_read32
    mov edx, eax
    shr edx, 24                     ; dl = class
    cmp dl, 0x0C
    jne .pci_next
    mov edx, eax
    shr edx, 16
    and edx, 0xFF                   ; dl = subclass
    cmp dl, 0x03
    jne .pci_next
    mov edx, eax
    shr edx, 8
    and edx, 0xFF                   ; dl = prog-if
    cmp dl, 0x20
    jne .pci_next
    jmp .pci_found
.pci_next:
    inc esi
    cmp esi, 32
    jb .pci_slot
    jmp .fail
.pci_found:
    mov [ehci_slot], esi

    ; ---- 2. 读 vendor:device 和 BAR0 ----
    mov eax, 0
    mov ebx, [ehci_slot]
    xor ecx, ecx
    xor edx, edx
    call pci_mk_addr
    call pci_read32
    mov [ehci_id], eax              ; 低 16 = vendor,高 16 = device

    mov eax, 0
    mov ebx, [ehci_slot]
    xor ecx, ecx
    mov edx, 0x10
    call pci_mk_addr
    call pci_read32
    test al, 1
    jnz .fail                       ; BAR0 不是 MMIO(异常情况)
    and eax, 0xFFFFFFF0
    mov [ehci_mmio_phys], eax

    ; ---- 3. 打开 MEM + BusMaster(16 位命令寄存器写,别碰 status 的写 1 清位) ----
    mov byte [pci_bus], 0
    mov eax, [ehci_slot]
    mov [pci_slot], al
    mov byte [pci_func], 0
    mov dl, PCI_R_COMMAND
    call pci_cur_read
    and eax, 0xFFFF
    or eax, PCI_CMD_MEM | PCI_CMD_BM
    call pci_write_command

    ; ---- 4. BAR0(4 KiB)映射到固定 VA ----
    mov eax, EHCI_MMIO_VA
    mov ebx, [ehci_mmio_phys]
    mov ecx, PAGE_P | PAGE_RW
    call paging_map
    jc .fail
    mov dword [ehci_base], EHCI_MMIO_VA

    ; ---- 5. 解析 capbase:CAPLENGTH → 操作寄存器基址;HCSPARAMS → 端口数 ----
    mov esi, EHCI_MMIO_VA
    mov eax, [esi]                  ; CAPLENGTH(低 8 位)+ HCIVERSION(高 16)
    and eax, 0xFF
    add eax, EHCI_MMIO_VA
    mov [ehci_op], eax
    mov eax, [esi + 4]              ; HCSPARAMS:N_PORTS = bits3:0
    and eax, 0xF
    mov [ehci_ports], eax
    test eax, eax
    jz .pf

    ; ---- 6. 控制器复位:USBCMD.HCRESET 置 1,等它自清 ----
    mov edi, [ehci_op]
    mov dword [edi + EHCI_CMD], EHCI_CMD_RESET
    call pit_get_ticks
    add eax, 25                     ; 250 ms 超时
    mov [ehci_deadline], eax
.reset_wait:
    mov eax, [edi + EHCI_CMD]
    test eax, EHCI_CMD_RESET
    jz .reset_done
    call pit_get_ticks
    cmp eax, [ehci_deadline]
    jae .fail
    hlt
    jmp .reset_wait
.reset_done:
    mov dword [edi + EHCI_STS], 0x3F    ; 清状态(写 1 清)
    mov dword [edi + EHCI_INTR], 0      ; 关中断(我们轮询)
    mov dword [edi + EHCI_DSSEG], 0     ; 32 位寻址,段寄存基址清零
    mov dword [edi + EHCI_FRINDEX], 0

    ; ---- 7. 周期帧列表先全填"列表结束",等有中断端点再挂 QH ----
    cld
    mov edi, EHCI_FRAME_LIST
    mov ecx, 1024
    mov eax, EHCI_LIST_END
    rep stosd

    ; ---- 8. 异步 QH:哑头 QH(H=1、HALT)+ 传输 QH(挂在头后面,环形) ----
    ;  头 QH 永远停在 HALT,只负责"列表起点";传输 QH 承载 qTD 链。
    mov edi, EHCI_ASYNC_QH
    mov eax, EHCI_XFER_QH
    or eax, 2                       ; 列表指针 type=QH
    mov [edi + QH_NEXT], eax
    mov dword [edi + QH_INFO1], QH_HEAD
    mov dword [edi + QH_INFO2], 0
    mov dword [edi + QH_CURRENT], 0
    mov dword [edi + QH_QTD_NEXT], EHCI_LIST_END
    mov dword [edi + QH_ALT_NEXT], EHCI_LIST_END
    mov dword [edi + QH_TOKEN], QH_TOKEN_HALT

    mov edi, EHCI_XFER_QH
    mov eax, EHCI_ASYNC_QH
    or eax, 2
    mov [edi + QH_NEXT], eax
    mov dword [edi + QH_INFO1], 0
    mov dword [edi + QH_INFO2], 0
    mov dword [edi + QH_CURRENT], 0
    mov dword [edi + QH_QTD_NEXT], EHCI_LIST_END
    mov dword [edi + QH_ALT_NEXT], EHCI_LIST_END
    mov dword [edi + QH_TOKEN], QH_TOKEN_HALT

    ; ---- 9. 写 PERIODIC/ASYNC 基址,USBCMD = RUN | PSE | ASE | ITC1 ----
    mov edi, [ehci_op]
    mov dword [edi + EHCI_PERIODIC], EHCI_FRAME_LIST
    mov dword [edi + EHCI_ASYNC], EHCI_ASYNC_QH
    mov dword [edi + EHCI_CMD], EHCI_CMD_RUN | EHCI_CMD_PSE | EHCI_CMD_ASE | EHCI_CMD_ITC1

    ; ---- 10. 等 STS.HALT 清零(控制器真的跑起来了)----
    call pit_get_ticks
    add eax, 5                      ; 50 ms 超时
    mov [ehci_deadline], eax
.halt_wait:
    mov eax, [edi + EHCI_STS]
    test eax, EHCI_STS_HALT
    jz .halt_done
    call pit_get_ticks
    cmp eax, [ehci_deadline]
    jae .fail
    hlt
    jmp .halt_wait
.halt_done:
    ; ---- 11. CONFIGFLAG=1:根端口全归 EHCI(不交给 companion)----
    mov dword [edi + EHCI_CFGFLAG], 1

    ; ---- 12. 端口上电 ----
    xor ebx, ebx
.port_power:
    cmp ebx, [ehci_ports]
    jae .port_power_done
    mov ecx, ebx
    call ehci_read_portsc
    test eax, EHCI_PS_POWER
    jnz .pp_next
    and eax, ~EHCI_PS_W1C
    or eax, EHCI_PS_POWER
    lea esi, [edi + EHCI_PORTSC]
    mov [esi + ebx*4], eax
.pp_next:
    inc ebx
    jmp .port_power
.port_power_done:
    mov byte [ehci_ok], 1
    popad
    ret
.pf:
    jmp .fail
.fail:
    popad
    ret

; ===========================================================================
;  ehci_read_portsc:ecx = 端口号(0 起)→ eax = PORTSC
; ===========================================================================
ehci_read_portsc:
    mov eax, [ehci_op]
    lea eax, [eax + EHCI_PORTSC + ecx*4]
    mov eax, [eax]
    ret

; ===========================================================================
;  ehci_port_reset:ecx = 端口号 → eax = 0 失败/交给 companion,2 高速已使能
;  复位期间本线程会 hlt 等 50ms;只在线程上下文调(热插拔任务/开机)。
; ===========================================================================
ehci_port_reset:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov [ehci_port_idx], ecx
    mov edi, [ehci_op]
    lea esi, [edi + EHCI_PORTSC]
    lea esi, [esi + ecx*4]          ; esi = 本端口 PORTSC 地址

    mov eax, [esi]
    test eax, EHCI_PS_CCS
    jz .fail                        ; 没插设备
    test eax, EHCI_PS_OWNER
    jnz .fail                       ; 已经归 companion(UHCI)了

    ; ---- 开始复位:清变化位/PE,置 RESET ----
    and eax, ~(EHCI_PS_W1C | EHCI_PS_PE)
    or eax, EHCI_PS_RESET
    mov [esi], eax

    mov ecx, 5                      ; 50 ms(规范要求至少 50ms)
    call pit_wait_ticks

    ; ---- 结束复位:清 RESET,顺手清变化位 ----
    mov eax, [esi]
    and eax, ~(EHCI_PS_W1C | EHCI_PS_RESET)
    mov [esi], eax

    ; ---- 等 PE 起来(高速设备复位完成后端口自动使能)----
    call pit_get_ticks
    add eax, 10                     ; 100 ms 超时
    mov [ehci_deadline], eax
.pe_wait:
    mov eax, [esi]
    test eax, EHCI_PS_RESET
    jnz .pe_more
    test eax, EHCI_PS_PE
    jnz .hs_ok
.peek_again:
    call pit_get_ticks
    cmp eax, [ehci_deadline]
    jae .handoff
    hlt
    jmp .pe_wait
.pe_more:
    call pit_get_ticks
    cmp eax, [ehci_deadline]
    jae .handoff
    hlt
    jmp .pe_wait

.handoff:
    ; 复位后仍没使能:低速/全速设备(或异常)→ 交 companion,我们不碰
    mov eax, [esi]
    test eax, EHCI_PS_CCS
    jz .fail
    and eax, ~(EHCI_PS_W1C | EHCI_PS_PE)
    or eax, EHCI_PS_OWNER
    mov [esi], eax
    jmp .fail

.hs_ok:
    ; 高速设备已使能:再清一次变化位(PE 留着)
    mov eax, [esi]
    and eax, ~EHCI_PS_W1C
    mov [esi], eax
    mov eax, 2
    jmp .out
.fail:
    xor eax, eax
.out:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; ===========================================================================
;  ehci_qtd_fill:填一枚 qTD 的缓冲区指针和 token(不碰 next/alt_next)
;    edi = qTD, esi = 缓冲地址, ecx = 长度, edx = token(不含长度位)
;  只支持不跨 4 KiB 页的传输(本内核的最大一笔是 4096 B 且页对齐,足够)
; ===========================================================================
ehci_qtd_fill:
    push eax
    mov [edi + QTD_BUF0], esi
    mov dword [edi + QTD_BUF0 + 4], 0
    mov dword [edi + QTD_BUF0 + 8], 0
    mov dword [edi + QTD_BUF0 + 12], 0
    mov dword [edi + QTD_BUF0 + 16], 0
    mov eax, ecx
    shl eax, 16
    or eax, edx
    mov [edi + QTD_TOKEN], eax
    pop eax
    ret

; ===========================================================================
;  ehci_async_submit:把 qTD 链挂到传输 QH 上并重启异步调度
;    edi = 链头, ebx = 链尾, esi = QH info1, edx = QH info2
; ===========================================================================
ehci_async_submit:
    push eax
    push edi
    mov [ehci_last_qtd], ebx
    or esi, QH_HEAD                   ; 它同时是异步列表头,H 位置 1
    mov eax, EHCI_XFER_QH
    mov [eax + QH_INFO1], esi
    mov [eax + QH_INFO2], edx
    mov dword [eax + QH_CURRENT], 0
    mov [eax + QH_QTD_NEXT], edi
    mov dword [eax + QH_ALT_NEXT], EHCI_LIST_END
    mov dword [eax + QH_TOKEN], 0

    ; ---- 重启异步调度:关 ASE → 等 ASS=0 → 写 ASYNCLISTADDR → 开 ASE ----
    ;   (QEMU 对"保留在环里的 QH 改字段再敲门铃"不可靠:实测第二笔传输
    ;    起控制器不再取新 qTD。整个调度重来一遍最稳。)
    mov edi, [ehci_op]
    mov eax, [edi + EHCI_CMD]
    and eax, ~EHCI_CMD_ASE
    mov [edi + EHCI_CMD], eax
    mov ecx, 20
.ass_off:
    mov eax, [edi + EHCI_STS]
    test eax, 0x8000                 ; STS.ASS
    jz .ass_off_done
    hlt
    dec ecx
    jnz .ass_off
.ass_off_done:
    mov dword [edi + EHCI_ASYNC], EHCI_XFER_QH
    mov eax, [edi + EHCI_CMD]
    or eax, EHCI_CMD_ASE
    mov [edi + EHCI_CMD], eax
    pop edi
    pop eax
    ret

; ===========================================================================
;  ehci_async_wait:轮询最后一枚 qTD 直到不再 ACTIVE
;    返回 eax = 0 成功,-1 失败/超时;完事后把异步 QH 打回 HALT
; ===========================================================================
ehci_async_wait:
    push ecx
    push edx
    push esi
    push edi
    mov esi, [ehci_last_qtd]
    call pit_get_ticks
    add eax, 300                    ; 3 秒超时
    mov [ehci_deadline], eax
.wait_loop:
    mov eax, [esi + QTD_TOKEN]
    test eax, QTD_ACTIVE
    jz .done
    call pit_get_ticks
    cmp eax, [ehci_deadline]
    jae .timeout
    hlt
    jmp .wait_loop
.done:
    mov eax, [esi + QTD_TOKEN]
    test eax, QTD_ERRMASK
    jnz .timeout
    xor eax, eax
    jmp .off
.timeout:
    mov eax, -1
.off:
    mov edi, EHCI_XFER_QH
    mov dword [edi + QH_QTD_NEXT], EHCI_LIST_END
    mov dword [edi + QH_TOKEN], QH_TOKEN_HALT
    pop edi
    pop esi
    pop edx
    pop ecx
    ret

; ===========================================================================
;  ehci_control:控制传输(接口与 usb.asm 的 usb_control 相同)
;    esi = SETUP 8 字节, edi = 数据缓冲, ecx = 长度, edx = 1 IN / 0 无数据
;    返回 eax = 0 成功 / -1 失败
;  只用 IN 数据阶段(本内核的控制传输全是 GET_DESCRIPTOR;OUT 用不到)
; ===========================================================================
ehci_control:
    pushad
    mov dword [ec_ctrl_ret], -1
    mov [ec_setup], esi
    mov [ec_buf], edi
    mov [ec_len], ecx
    mov [ec_dir], edx
    cmp byte [ehci_ok], 0
    je .out

    ; ---- 清 qTD 链(8 枚 × 32B = 8 × 8 dword)----
    cld
    mov edi, EHCI_ASYNC_QTD
    xor eax, eax
    mov ecx, EHCI_ASYNC_QTD_N * 8
    rep stosd

    ; ---- SETUP qTD(第 0 枚):DATA0,8 字节 ----
    mov edi, EHCI_ASYNC_QTD
    mov esi, [ec_setup]
    mov ecx, 8
    mov edx, QTD_CERR3 | QTD_PID_SETUP | QTD_ACTIVE
    call ehci_qtd_fill
    mov dword [edi + QTD_ALT_NEXT], EHCI_LIST_END

    ; ---- DATA qTD(第 1 枚,仅 IN)+ STATUS qTD ----
    mov dword [ec_hasdata], 0
    cmp dword [ec_len], 0
    je .no_data
    cmp dword [ec_dir], 0
    je .no_data
    mov dword [ec_hasdata], 1

    mov edi, EHCI_ASYNC_QTD + 32
    mov esi, [ec_buf]
    mov ecx, [ec_len]
    mov edx, QTD_TOGGLE | QTD_CERR3 | QTD_PID_IN | QTD_ACTIVE
    call ehci_qtd_fill
    mov dword [edi + QTD_ALT_NEXT], EHCI_LIST_END

    ; SETUP → DATA
    mov eax, EHCI_ASYNC_QTD + 32
    mov dword [EHCI_ASYNC_QTD + QTD_NEXT], eax
    ; STATUS 在 +64
    mov dword [ec_status], EHCI_ASYNC_QTD + 64
    ; DATA → STATUS
    mov eax, EHCI_ASYNC_QTD + 64
    mov dword [EHCI_ASYNC_QTD + 32 + QTD_NEXT], eax
    jmp .build_status

.no_data:
    ; 无数据阶段:SETUP → STATUS(在 +32)
    mov dword [ec_status], EHCI_ASYNC_QTD + 32
    mov eax, EHCI_ASYNC_QTD + 32
    mov dword [EHCI_ASYNC_QTD + QTD_NEXT], eax

.build_status:
    ; STATUS qTD:长度 0,DATA1;数据 IN 时用 OUT,否则用 IN
    mov edi, [ec_status]
    mov edx, QTD_TOGGLE | QTD_IOC | QTD_CERR3 | QTD_ACTIVE
    cmp dword [ec_hasdata], 0
    je .status_in
    or edx, QTD_PID_OUT
    jmp .status_fill
.status_in:
    or edx, QTD_PID_IN
.status_fill:
    xor esi, esi
    xor ecx, ecx
    call ehci_qtd_fill
    mov dword [edi + QTD_NEXT], EHCI_LIST_END
    mov dword [edi + QTD_ALT_NEXT], EHCI_LIST_END

    ; ---- QH:高速 control 端点 0(默认管道 mps 固定 64)----
    mov esi, QH_RL_HS | (64 << 16) | QH_HIGH_SPEED | QH_DTC
    mov eax, [usb_ctl_addr]
    and eax, 0x7F
    or esi, eax                     ; 设备地址 bit0-6,端点号 0
    mov edx, QH_MULT_HS
    mov edi, EHCI_ASYNC_QTD         ; 链头
    mov ebx, [ec_status]            ; 链尾(STATUS 那枚)
    call ehci_async_submit
    call ehci_async_wait
    mov [ec_ctrl_ret], eax
.out:
    mov eax, [ec_ctrl_ret]
    mov [esp + 28], eax             ; 写回 pushad 的 eax 槽
    popad
    ret

; ===========================================================================
;  ehci_bulk_xfer:bulk 传输(接口与 usbdisk.asm 的 usb_bulk_xfer 相同)
;    esi = 缓冲, ecx = 长度, edi = 端点地址, edx = 1 IN / 0 OUT, ebx = 起始 toggle
;    返回 eax = 0 成功 / -1 失败
;  一笔最多 4 KiB(USB_MSD_DATA 是一页;BOT 的 CBW/CSW 只有几十字节)
; ===========================================================================
ehci_bulk_xfer:
    pushad
    mov dword [eb_ret], -1
    mov [eb_buf], esi
    mov [eb_len], ecx
    mov [eb_ep], edi
    mov [eb_dir], edx
    mov [eb_toggle], ebx
    cmp byte [ehci_ok], 0
    je .out
    cmp byte [usb_msd_ok], 0
    je .out
    cmp ecx, 4096
    ja .out
    test ecx, ecx
    jz .out

    ; ---- 清 qTD(2 枚就够了,清 4 枚保险)----
    cld
    mov edi, EHCI_ASYNC_QTD
    xor eax, eax
    mov ecx, 4 * 8
    rep stosd

    ; ---- token:方向/toggle/CERR/IOC ----
    mov edx, QTD_CERR3 | QTD_IOC | QTD_ACTIVE
    cmp dword [eb_toggle], 0
    je .no_toggle
    or edx, QTD_TOGGLE
.no_toggle:
    cmp dword [eb_dir], 0
    je .dir_out
    or edx, QTD_PID_IN
    mov esi, [usb_msd_mps_in]
    jmp .mps_ok
.dir_out:
    or edx, QTD_PID_OUT
    mov esi, [usb_msd_mps_out]
.mps_ok:
    test esi, esi
    jz .bail
    cmp esi, 512
    jbe .mps_cap
    mov esi, 512
.mps_cap:
    mov [eb_mps], esi

    ; ---- 填 qTD ----
    mov edi, EHCI_ASYNC_QTD
    mov esi, [eb_buf]
    mov ecx, [eb_len]
    call ehci_qtd_fill
    mov dword [edi + QTD_NEXT], EHCI_LIST_END
    mov dword [edi + QTD_ALT_NEXT], EHCI_LIST_END

    ; ---- QH:高速 bulk 端点;地址/端点号按 usbdisk 的记录填 ----
    mov esi, QH_RL_HS | QH_HIGH_SPEED | QH_DTC
    mov eax, [eb_mps]
    shl eax, 16
    or esi, eax
    mov eax, [usb_msd_addr]
    and eax, 0x7F
    or esi, eax
    mov eax, [eb_ep]
    and eax, 0x0F
    shl eax, 8
    or esi, eax
    mov edx, QH_MULT_HS
    mov edi, EHCI_ASYNC_QTD
    mov ebx, EHCI_ASYNC_QTD
    call ehci_async_submit
    call ehci_async_wait
    mov [eb_ret], eax
    jmp .out
.bail:
.out:
    mov eax, [eb_ret]
    mov [esp + 28], eax
    popad
    ret

; ===========================================================================
;  ehci_int_arm:给 HID 键盘的中断 IN 端点挂 qTD(并把它排进周期帧列表)
;  用 usb2.asm 里的键盘记录:kb_addr / kb_ep / kb_mps / kb_toggle。
; ===========================================================================
ehci_int_arm:
    pushad
    cmp byte [ehci_ok], 0
    je .out
    cmp byte [kb_present], 0
    je .out

    ; ---- 清中断 qTD ----
    cld
    mov edi, EHCI_INT_QTD
    xor eax, eax
    mov ecx, 8
    rep stosd

    ; ---- qTD:8 字节 IN,按 kb_toggle 给 DT 位 ----
    mov edx, QTD_CERR3 | QTD_IOC | QTD_PID_IN | QTD_ACTIVE
    movzx eax, byte [kb_toggle]
    test eax, eax
    jz .no_tog
    or edx, QTD_TOGGLE
.no_tog:
    mov esi, EHCI_INT_BUF
    mov ecx, 8
    mov edi, EHCI_INT_QTD
    call ehci_qtd_fill
    mov dword [edi + QTD_NEXT], EHCI_LIST_END
    mov dword [edi + QTD_ALT_NEXT], EHCI_LIST_END

    ; ---- 中断 QH ----
    mov edi, EHCI_INT_QH
    mov eax, EHCI_INT_QH
    and eax, ~0x1F
    or eax, 2
    mov [edi + QH_NEXT], eax
    ; info1 = mps<<16 | 高速 | DTC | 设备地址 | 端点号<<8
    mov eax, [kb_mps]
    test eax, eax
    jnz .mps_ok
    mov eax, 8
.mps_ok:
    shl eax, 16
    or eax, QH_HIGH_SPEED | QH_DTC
    mov edx, [kb_addr]
    and edx, 0x7F
    or eax, edx
    mov edx, [kb_ep]
    and edx, 0x0F
    shl edx, 8
    or eax, edx
    mov [edi + QH_INFO1], eax
    mov dword [edi + QH_INFO2], QH_MULT_HS | QH_SMASK0
    mov dword [edi + QH_CURRENT], 0
    mov dword [edi + QH_QTD_NEXT], EHCI_INT_QTD
    mov dword [edi + QH_ALT_NEXT], EHCI_LIST_END
    mov dword [edi + QH_TOKEN], 0

    ; ---- 周期帧列表:每 8 帧(8 ms)挂一次中断 QH,其余填列表结束 ----
    cld
    mov edi, EHCI_FRAME_LIST
    mov ecx, 1024
.fill:
    test ecx, 7
    jnz .term
    mov eax, EHCI_INT_QH
    and eax, ~0x1F
    or eax, 2
    jmp .store
.term:
    mov eax, EHCI_LIST_END
.store:
    mov [edi], eax
    add edi, 4
    dec ecx
    jnz .fill
.out:
    popad
    ret

; ===========================================================================
;  ehci_int_poll:usb_poll(IRQ0,100 Hz)里调,处理 EHCI 键盘的中断 IN
;   - qTD 还 ACTIVE → 什么都没发生(NAK 也会保持 ACTIVE)
;   - 完成 → 把 8 字节报告拷进 USB_INT_BUF,交给 usb.asm 的解析;翻转 DT 重挂
;   - 出错 → 直接翻转 DT 重挂(键盘不会 STALL,能自愈)
; ===========================================================================
ehci_int_poll:
    pushad
    cmp byte [ehci_ok], 0
    je .out
    cmp byte [usb_hid_ok], 0
    je .out
    cmp dword [kb_ctrl], 2
    jne .out

    mov eax, [EHCI_INT_QTD + QTD_TOKEN]
    test eax, QTD_ACTIVE
    jnz .out
    test eax, QTD_ERRMASK
    jnz .rearm
    ; 完成:把报告搬到 USB_INT_BUF(usb_handle_report 读那里)
    cld
    mov esi, EHCI_INT_BUF
    mov edi, USB_INT_BUF
    mov ecx, 8
    rep movsb
    call usb_handle_report
.rearm:
    xor byte [kb_toggle], 1
    call ehci_int_arm
.out:
    popad
    ret

; ===========================================================================
;  数据
; ===========================================================================
ehci_ok          db 0
ehci_slot        dd 0               ; PCI slot(0..31)
ehci_id          dd 0               ; 低 16 = vendor,高 16 = device
ehci_mmio_phys   dd 0               ; BAR0 物理地址(4 KiB 对齐)
ehci_base        dd 0               ; BAR0 映射后的 VA
ehci_op          dd 0               ; 操作寄存器基址 = base + CAPLENGTH
ehci_ports       dd 0               ; HCSPARAMS.N_PORTS
ehci_port_idx    dd 0
ehci_deadline    dd 0
ehci_cmdval      dd 0
ehci_last_qtd    dd 0

; ehci_control 的暂存
ec_setup         dd 0
ec_buf           dd 0
ec_len           dd 0
ec_dir           dd 0
ec_hasdata       dd 0
ec_status        dd 0
ec_ctrl_ret      dd 0

; ehci_bulk_xfer 的暂存
eb_buf           dd 0
eb_len           dd 0
eb_ep            dd 0
eb_dir           dd 0
eb_toggle        dd 0
eb_mps           dd 0
eb_ret           dd 0
