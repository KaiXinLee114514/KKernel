; ============================================================================
;  KKernel — 内核镜像入口文件
;
;  内核镜像的布局(整块被引导扇区搬到 0x10000):
;      +0x0000  实模式 stub:问 VBE 要图形模式、写启动参数、建 GDT、进保护模式
;      +0x????  32 位内核:终端、IDT、分页、键盘、shell(kmain.asm 及以下)
;
;  为什么要这么分层:VBE 只能实模式调 BIOS,而 512 字节的引导扇区塞不下这些代码。
;  放在内核镜像开头,空间就宽松了;引导扇区只剩"读盘 + 跳过来"。
;
;  构建: nasm -f bin -I kernel/ kernel/start.asm -o build/kernel.bin
;  注意:[ORG 0x10000] 只能写一次(整个平铺镜像共用一个原点),所以 stub.asm 和
;        kmain.asm 里都不要再写 ORG/BITS 头(见各自文件开头)。
; ============================================================================

[BITS 32]
[ORG 0x10000]

; ---- 跨模块共享的常量(定义在所有 include 之前,谁都能用)--------------------
BLK_FAT_STATE_BUF equ 0x3C6000          ; blkdev:USB 挂载时保存 ATA FAT 挂载状态的缓冲
BLK_FAT_STATE_MAX equ 4096              ; 状态区上限(4 KiB)

; ---- x64 长模式结构区(32→64 位切换用)----
;   固定在 0x03000000:既不在内核 heap(0x180000–0x6E0000),也由 kmain 在
;   pmem_init 之后调 pmem_reserve 标记为已占用,防止页池分配踩进来。
;   (旧地址 0x1E0000-0x200000 落在 heap 里:QEMU 侥幸,VBox 里 triple fault。)
X64_REGION_BASE equ 0x03000000
X64_REGION_SIZE equ 0x00040000          ; 256 KiB(64 页)

kmain:                                  ; 32 位内核入口(stub 里 jmp 0x10000 跳过来)
;  ⚠️ 第一个被 include 的文件决定 0x10000 处的第一条指令 —— 因为 `kmain:` 本身不占字节。
;     所以入口代码必须排在第一个,别的模块(哪怕是被前面引用的)都放后面。
%include "kmain.asm"                     ; 终端 + 启动信息(必须在最前)
%include "utf8.asm"                      ; UTF-8 解码
%include "ata.asm"                       ; ATA 硬盘 PIO
%include "pci.asm"                       ; PCI 总线枚举(USB 的前置工作)
%include "usb.asm"                       ; UHCI + HID 键盘(第一步,只有键盘)
%include "ehci.asm"                      ; USB 2.0 EHCI 控制器(高速)
%include "usb2.asm"                      ; 双控制器分发 + 热插拔
%include "usbdisk.asm"                    ; USB 大容量储存(只读裸盘)
%include "fontdisk.asm"                  ; 从磁盘加载完整字库
%include "fat.asm"                       ; FAT16 文件系统
%include "blkdev.asm"                    ; 块设备抽象层(ATA / USB 统一 read/write sector)
%include "dev.asm"                       ; /DEV 设备抽象层(虚拟设备:NULL/ZERO/RTC/...)
%include "pipe.asm"                      ; 顺序管道:输出捕获 + stdin 读管
%include "api.asm"                    ; 程序接口 int 0x30
%include "posix.asm"                  ; i386 Linux ABI 转译层 int 0x80(P1)
%include "speaker.asm"                   ; PC 蜂鸣器(beep,忙等标定见文件开头)
%include "idt.asm"                       ; IDT / 异常 / panic 屏
%include "fpu.asm"                       ; x87 浮点单元初始化
%include "tss.asm"                       ; 用户段 + TSS(ring 3 的地基)
%include "paging.asm"                    ; 页目录 / 页表
%include "pmem.asm"                      ; 物理页池(位图分配器,paging_map 会找它要页)
%include "elf.asm"                       ; ELF32 可执行文件装载器(TCC 程序用)
%include "fbterm.asm"                   ; 帧缓冲终端(图形模式)
%include "svga.asm"                   ; VMSVGA(VirtualBox/VMware)显示更新:SVGA FIFO UPDATE
%include "vgafont.asm"                   ; 自定义点阵字模(文本模式实验)
%include "keyboard.asm"                  ; PS/2 键盘(顺手重映射 PIC)
%include "pit.asm"                       ; PIT 定时器(IRQ0,100 Hz 心跳)
%include "tty.asm"                       ; 控制台 TTY(ANSI/ASCII 降级 + 行规程输入;要 TICK_HZ)
%include "rtc.asm"                       ; CMOS 实时时钟(日期 / 时间)
%include "sched.asm"                     ; 调度器(内核线程 + 抢占式轮转)
%include "rc.asm"                        ; rc.conf 配置 + 事件账本(控制程序事件)
%include "shell.asm"
%include "ime.asm"                     ; shell
%include "process.asm"                  ; 进程/信号(shell 的 ps/fork/wait/kill 要用它的符号)
%include "users.asm"                    ; 最小多用户:用户表 + 登录 + 身份落 TCB
%include "lock.asm"                     ; 锁(A4):spin_lock / 睡眠互斥锁 / console_lock / fs_lock
%include "jobctl.asm"                   ; Phase B:作业控制(进程组/会话 + 前台进程组 + ^C/^Z 过滤)
%include "swap.asm"                     ; Phase C:swap 换出/换入 + 用户大匿名堆
%include "x64.asm"                      ; x86-64:start64 命令 + 长模式切换(kernel64/K64.BIN)

; 内核区补到 256 KiB(512 扇区,和 tools/mkimg.py 的 KERNEL_SECTS 一致)——
; 引导扇区本来就读 256 个扇区,所以这里只是把文件补够,顺便当"超出就报错"的尺子。
; (以前补到 64 KiB;加了 ring 3 + rc.conf 之后内容过 64 KiB 了,改成对齐真正的上限。)
times (512 * 512) - ($ - $$) db 0
