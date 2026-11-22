# 架构与实现细节

> 本文档原为 README 的 §4–§5，拆分出来方便阅读。

## 图形模式(VBE + 帧缓冲)

文本模式那条路只能放 63 个汉字(一个汉字要占两个 8 像素宽的字符格),所以正经中文
得进图形模式 —— 屏幕就是一块显存,画什么全由自己决定。

```
实模式 stub    int 0x10 AX=4F00/4F01 列模式 → AX=4F02 设成 800×600×32(带线性帧缓冲)
               → 把 帧缓冲物理地址/宽/高/pitch/色深 写进 BOOTINFO(0x8000)
分页           帧缓冲在 0xFD000000,不在恒等映射窗口(0~ident)里
               → 按 4 MiB 对齐算页目录项,挂一张页表把它映射进来(不映射第一次写像素就吃页错误)
帧缓冲终端     kernel/fbterm.asm:码位 → 二分查找字库 → 逐行取位 → 往显存写 4 字节像素
               (颜色从文本模式的属性字节换算成 RGB;滚屏就是 memmove 整块显存往上 16 行)
```

坑:16×16 的汉字一行是**两个字节**,低地址那个才是左半边 —— 一开始我用 bit15 开始往左画,
结果**汉字左右两半反了**(每个字看着像"对折过"的样子)。修法是 `rol ax, 8` 把两个字节换回来。

## 磁盘:字库、FAT16、跑程序

磁盘之上还有一层很薄的「设备」抽象:`/DEV` 下的名字由内核设备表接管(见 [docs/devices.md](docs/devices.md))。
(因为还没更新完)
这一块单独写了一页:**[docs/filesystem.md](docs/filesystem.md)** —— 镜像的 LBA 地图、
ATA PIO 的寄存器顺序和两个坑、磁盘字库怎么加载、FAT16 的字段和写文件流程、
`mkfat.py` 怎么用、测试怎么用两条信道证明"字节真的落盘了"。

想写程序的话看另一页:**[docs/programs.md](docs/programs.md)** —— `int 0x30` 的六个功能、
为什么用中断而不是 `call` 内核函数、程序的内存/栈约定、怎么加进镜像。

一句话版:

```
run HELLO      → fat_stat 看大小 → fat_read_file 先读进 0x120000(暂存)
               → space_create 建一套空地址空间(页目录 + 页表两页,窗口里的页一页都不给)
               → 切 CR3 → call 0x120000 → 程序碰到哪页,页错误才从暂存区补哪页
               → 程序 ret 回 shell → 切回 CR3 → 补出来的页连页表一起还给页池
程序里:         mov eax, 0 / mov esi, 字符串 / int 0x30   ← 打印一行
```

### 每个程序有自己的地址空间(而且是按需给的)

跑程序之前,内核给它现搭一套页表(**见 [kernel/paging.asm](kernel/paging.asm)
的 `space_create`**):

```
页目录   = 内核页目录的副本        (内核、IDT、VGA、字库、帧缓冲都还在)
页表[0]  = PT_LOW 的副本,但 0x120000~0x1EFFFF 的 208 项**清成"不存在"**
私有页   = 一页都不预先给 —— 程序碰到哪一页,14 号页错误才现补哪一页
```

所以:程序的**虚拟地址不变**(还是链接到 `0x120000`,程序自己不用改),
**物理页每次运行都是新的一批**,而且**只有它真正走过的页才会拿到内存**:

```
> run HELLO.BIN
running HELLO.BIN
address space: CR3 = 0x00400000  (own page directory + demand paging)
Hello from HELLO.BIN - I was loaded from the FAT16 disk!
program returned to the shell
address space destroyed: 3 page(s) back to the pool
demand paging: 1 page(s) faulted in (image 1 + heap 0), first page 0x00402000
```

249 字节的程序**只要 1 页**(以前是把整个窗口全给它)。主动去踩内存的是
[progs/TOUCH.asm](progs/TOUCH.asm),`run TOUCH` 会一页一页碰 32 页堆 + 一页 `.bss`,
然后回头检查每一页都还是自己写进去的标记:

```
> run TOUCH.BIN
  heap: touched 32 pages (4 KiB each), wrote 0xA5 into every one of them
  pages that were NOT zero before my write: 0     ← 现给的页必须是干净零页
  pages that did not read back what I wrote: 0     ← 每页都真的归自己
  page beyond the file (bss at 0x17E000): was zero, as it should be
demand paging: 34 page(s) faulted in (image 2 + heap 32), first page 0x00425000
```

补页的流程(都在 [kernel/paging.asm](kernel/paging.asm) 的 `page_fault_try_handle`
和 [kernel/idt.asm](kernel/idt.asm) 的 `isr_common` 里):CR2 是出错地址 → 判断它
落在镜像窗口还是堆窗口(窗口外就照旧红屏 panic)→ 从页池拿一页、清零 →
镜像窗口里"文件之内"的部分从暂存区拷过来("文件之外"就是 `.bss`,留零页)→
填页表 + `invlpg` → `iret` 回去**重执行那条指令**。程序完全感觉不到。

几个老实交代的地方:

- 写时复制、swap 页置换、用户栈自动增长都有了(见下面两节);剩下的限制:
  COW 共享页(引用计数 >1)不换出、swap 内容无压缩也无持久化、swap 满了返回 ENOMEM;
- 窗口里的**空洞也会给页**(程序只是读一下 0x180000 附近的地址,也会拿到一页零页);
- 内核窗口继续恒等映射,所以 `int 0x30` 照旧能用 —— **不需要 ring 3**,
  程序传给内核的指针也照旧解得开(那会儿用的就是程序这套页表)。

### 程序跑在 ring 3:内核的内存它碰不到

`RING3.BIN` 会直接问 CPU"我现在是谁"(`CS = 0x1B`、`CPL = 3`),`FAULT.BIN` 则故意去读内核内存 ——
被内核抓住、打印原因、把这个程序干掉,机器继续跑:

![ring 3:程序在 CPL=3 跑,摸内核内存会被干掉](docs/screenshot-ring3.png)

程序从 `0x120000` 跑起来,但**不是内核 `call` 进去的** —— 内核用 `iret` 把它丢进用户态
(CPL=3),它的代码段是 0x1B、栈段是 0x23。它自己能看到这件事:

```
> run RING3.BIN
running RING3.BIN
address space: CR3 = 0x00406000  (own page directory + demand paging)
RING3.BIN: asking the CPU where I am running
  CS  = 0x0000001B  (CPL = 3), SS = 0x00000023  ESP = 0x001EFFFC, [ESP] = 0x0019F000
if CS is 0x001b and CPL is 3, this program is not the kernel any more.

program returned to the shell
```

`[ESP]` 那个 `0x17F000` 是内核替它压进去的**弹床页**:程序最后一句 `ret` 会跳到那儿,
弹床里就三条指令(`mov eax,15 / int 0x30 / jmp $`)—— 喊一声"我退出了"就回 shell。
**现成程序一个都不用改**(C 程序的 crt0 也是 `ret`)。

想去碰内核的地盘呢:

```
> run FAULT.BIN
FAULT.BIN: now reading kernel memory at 0x00100000 ...

program crashed: page fault at 0x00100000 (EIP 0x0012000C) -- that page belongs to the
kernel, not to you

program was killed, the kernel is fine
```

页表是**逐级**查权限的:内核恒等映射的那些页(0~ident)U/S=0,程序页才是 U/S=1,
所以 `mov ebx,[0x100000]` 直接页错误;内核的处理是**把程序干掉、自己接着跑**
(以前是 panic,现在是 `program was killed`)。用户态异常也不再是内核 panic:
`isr_common` 先看错误码里的 CS(CPL),是 3 就交给 `prog_kill_from_fault`。

程序自己那几块地(都在它自己的地址空间里,按需补页):

| 地址 | 干什么 |
| --- | --- |
| `0x120000`-`0x17EFFF` | 程序镜像窗口(96 页;别拿 `0x17F000` 当数据缓冲——那是弹床页) |
| `0x17F000` | 弹床页(单独映的 1 页:三条指令替程序喊"我退出") |
| `0x180000`-`堆顶-1` | 堆窗口(`malloc` 从这儿长;大小看机器内存,默认约 2.1 MB) |
| `堆顶-0x2000` | 参数页:内核里那份参数(0x11F000)对 ring 3 是"别人家的内存",装载器整块拷过来 |
| `堆顶-0x1000` | 用户栈(栈顶 = 堆顶-4,那 4 字节是弹床地址) |
| `0x80000000`+ | 大匿名堆(`anon_alloc` 申请的块;每 4 MiB 一张按需建的页表,冷页可换出到 swap 区) |

### 物理内存的下一层:swap(页换出/换入)

物理页池(4 MiB 起,大小随机器内存)不够时会先把**冷页换出到磁盘**,再给新页 ——
用户程序完全感觉不到,只是偶尔慢一截。实现在 [kernel/swap.asm](kernel/swap.asm)。

- **swap 区**:测试镜像 `build/kkernel-swap.img` 在正常 16 MiB 硬盘镜像**末尾追加 16 MiB**
  (LBA 32768 起,4096 个 4 KiB 槽),头 16 字节 `"KSWP" + version + total_slots + slot_size`。
  普通镜像没有这个头 → swap **静默禁用**,旧测试和页数基线一点不受影响。
- **帧元数据**:每物理帧 8 字节(标志位 + 指回它的 PTE 地址),开机时按 `pmem_total`
  从页池借几页存(`-m 128` 时 59 页元数据管 30207 帧);槽位图 512 字节静态 BSS。
  只有「引用计数 == 1 的用户按需页」才会被标成可换出(ANON),COW 父子共享页、
  内核页、页表、DMA/IO 缓冲一律不碰。
- **PTE 编码**:换出后 PTE = `present=0` + 软件位 bit9(`PAGE_SWAP`)+ 高 20 位槽号;
  COW 用的是 present=1 + bit9,两者靠 present 区分,不会撞。
- **换出(CLOCK 二次机会)**:从游标扫全池,跳过非 ANON / 引用计数 >1 / PTE 不再指向
  这一帧的;参考位 =1 先清掉跳过一圈,再遇到就选中:分配槽 → 4 KiB 拷到弹跳缓冲 →
  `ata_write_sectors`(绕开 FLUSH CACHE,swap 不需要持久化)→ PTE 改 slot+bit9 → 刷 TLB →
  还帧。全程关中断(ATA PIO 是轮询的,不需要中断;单核下这就是锁)。
- **触发点**:缺页补页 / fork 分配 / 内核栈分配 / 大匿名堆扩展,统一走
  `swap_alloc_frame`;页池满时它回收几页再试(最多 4 轮)。CLOCK 第一圈只清参考位,
  所以回收函数要循环到真拿到页为止。
- **换入**:缺页看到 present=0 + bit9 → `swap_swapin`:分配帧(池满先换出别的页)→
  从磁盘读回 4 KiB → 复核 PTE 没被人动过 → 装回 `P|RW|USER` → `invlpg` → 释放槽位;
  数据一个字节都不会错,`SWAPTEST` 的抽样重读专门验这件事。
- **大匿名堆**:`anon_alloc(n)`(int 0x30 功能号 31)把 TCB 里的 `brk`(`TCB_UBRK`)从
  `0x80000000` 往上推;第一次碰某 4 MiB 段时按需建页表,再按需给页。从 `fork` 出来的
  子进程**不继承**大匿名堆(页目录对应 PDE 清空、brk 复位)—— 记在下面的已知限制里。
- **已知限制**:COW 共享页不换出;swap 满返回 ENOMEM(不会 OOM 杀进程);swap 内容
  不持久化(重启即失效,镜像每次重建);无压缩、无每进程配额;关中断单核假设,
  SMP 要另外做锁;`-m 16` 时页池只有约 6 MiB,`SWAPTEST` 跑一轮约 1 分钟
  (QEMU/TCG 下 ATA PIO 写 4 KiB 页约 20 ms,这是测试耗时的主要来源)。

### 线程与调度(内核线程 + 优先级调度)

`kernel/sched.asm` 里 16 个线程槽,每槽是一个 **196 字节**的 TCB:esp / cr3 / 状态 /
拿到过多少 tick / 被调度过几次 / 栈的物理页 / 名字 / 出生在哪条 shell 上 /
父进程 / 退出码 / uid+gid / 进程组与会话(pgrp/sid)/ 优先级 / 睡眠通道与超时 /
就绪队列前后指针 / aging 计数 / 大匿名堆 brk / exec 载荷页 / Ctrl-C、Ctrl-Z 标志。
(原来是 32 字节,所以全仓都用 `shl 5` 当下标步长;加字段时改成了 `imul X, TCB_SIZE` ——
见 [踩坑笔记](pitfalls.md) 的 6.36。)**0 号线程永远是 shell 自己** ——
它不是被谁创建的,而是开机时把当前上下文直接填进去。

抢占点在 **IRQ0(PIT,100 Hz)**:`irq0_stub` 先发 EOI,然后判断调度器开没开,开了就把
当前 esp 交给 `sched_pick` 决定下一个该跑谁,再 `mov esp, eax` 换栈,接着 `popad` +
`iret` 就"回到"另一个线程里去了。**换栈这件事只能在中断入口这一层做**:`iret` 要从
栈上弹 EIP/CS/EFLAGS,在普通函数里换完 esp 再 `ret` 是回不去的(理由见 [踩坑笔记](pitfalls.md) 的 6.13)。

新线程的"现场"由 `sched_spawn` 在它自己的栈上手工摆出来:按 `irq0_stub` 的格式摆好
EFLAGS / CS / EIP / 错误码 / 向量号 / pushad 的八个寄存器,esp 指向这摞东西的最底下。
于是它第一次被 `iret` 上去时,看起来就像"刚被中断打断过",函数体从头开始跑。

局限(玩具级别的诚实说明):
- 有优先级调度:0 最高、普通 shell 线程 8、idle 15;每级一个 FIFO 就绪队列 + 位图,
  同级按 20 ms(2 个 tick)时间片轮转,高优先级就绪可抢占。有阻塞/唤醒原语
  (`sched_sleep_on` / `sched_sleep_timeout` / `sched_wakeup`),`process_wait` 和
  `tty_read_line` 都睡在通道上;aging 只把低优先级线程慢慢提到 shell 级,不会被饿死
- 每个线程 4 页栈(16 KiB)+ 底下 1 页 guard 页(恒等映射摘掉,踩了会 #PF;
  内核栈真溢出走到双重故障门会打印 panic,而不是重启)
- 用户栈从堆窗口顶部划出 128 页(512 KiB)增长区,按需补页;
  栈顶下面是参数页与 guard 页(越界会被和平杀掉)
- `kill` 一条**正在跑程序**的线程时,会看它当时用的 cr3 是不是现在这套程序的:
  是就把地址空间一并收摊(页目录 + 私有页表 + 已经按需补上的页全还回池子)
- 终端、FAT 等全局状态用锁保护(`kernel/lock.asm`):spin 锁、可递归睡眠 mutex,
  `console_lock` 保证多线程输出不插花,`fs_lock` 串行化文件命令;
  锁顺序 `fs_mutex → console_mutex` 允许、反向禁止
- 还是**内核态**线程:没有 ring 3、没有 TSS、也还没做到"一个线程一套地址空间"

自己试试:

```
> spawn            # 不带参数:第一次 alpha,第二次 beta
spawned thread 4 (alpha)
> spawn
spawned thread 5 (beta)
> ps
ps: 6 alive / 16 slots, scheduled ticks 1169
  [0] shell   ticks=893  runs=85
  [1] shell2  ticks=790  runs=80
  [2] shell3  ticks=700  runs=78
  [3] shell4  ticks=690  runs=77
  [4] alpha   ticks=170  runs=85
  [5] beta    ticks=110  runs=56
> kill 4
killed thread 4 (alpha)
```

`ticks` 和 `runs` 都在涨,说明这几个线程是**真的轮流在 CPU 上跑**,而不是"登记了一下
躺在那儿";`kill` 完再 `debug pmem`,空闲页数会回到开跑前的基线 —— 栈是借的,还得还。
(基线数字随内存大小变:boot 常驻 19 页 + 恒等映射的页表页;4 条 shell 各占 2 页栈,
0 号用的是开机栈,不占池子。)

### 多 shell:卡死一条,还有三条

4 条 shell 就是 4 条内核线程(0 号是开机那条,另外 3 条在 `kmain` 里 `spawn` 出来)。
键盘归谁用一个 `sh_active` 记着,**Ctrl+← / Ctrl+→ 的切换是在键盘中断处理里直接做的** ——
这点很关键:如果切换要靠"活动 shell 自己响应",那条正卡在 `run HANG` 里的 shell 就永远
换不走了;放在中断里,谁来按键谁就能把键盘交给别人。

每条 shell 有自己的行缓冲和当前目录,切换时:
- 打一条 `--- shell N ---` 当分隔,再把提示符和**你没敲完的那半行**重新画出来
- 半行输入跟着 shell 走:1 号敲一半 → 切到 2 号干点别的 → 切回来,那半行还在,回车就执行
- **每条 shell 各跑一个程序**(地址空间那套状态现在每线程一份):一条 `run HANG` 卡着,
  切到另一条 `run HELLO.BIN` 照样跑,互不打架
- shell 线程本身**杀不掉**(`kill 0`~`kill 3` 不会拆线程):键盘挂在它们身上,杀了没人收键;
  但 `kill <线程号>` 会停掉它正在跑的程序,连 ring 3 里的死循环也能被下一次时钟中断收走

```
> shell
shells: 4
(you are in shell 1)
  [0] shell    <- keyboard here
  [1] shell2
  [2] shell3
  [3] shell4
Ctrl+Left / Ctrl+Right switches, or: shell <n>
> shell 3
--- shell 3 ---
3> 
```

想亲眼看"卡死也不影响别人":`run HANG`(开头报一行、**转 24 圈约 40~60 秒后自己退出**的
演示程序),趁它占着这条 shell 的时候 `Ctrl+→` 逃到别的 shell,`echo` 照样有响应 —— 这就是
多 shell 的意义。要提前收回卡住的那条:在别的 shell 里 `kill 0`(线程号见 `ps`),
它会在下一次时钟中断时被内核收摊。

> `run HANG` 为什么不是真死循环:演示程序要有始有终,测试套件才能接着用那条 shell。
> 想试"永远回不来",把 `progs/HANG.asm` 的 `HANG_ROUNDS` 改大、或者删掉
> `dec dword [rounds]` / `jnz .loop` 两行 —— 然后从另一条 shell `kill 0` 把它收掉。

![4 条 shell 互相切换](docs/screenshot-shells.png)

`shell` 列出来,`Ctrl+→` 切到 2 号敲命令,`3> date time` 是 3 号在跑;
最后那两行是"半行命令"的演示:在 1 号敲了 `echo half-typed line survives` 没回车就跑掉了,
切回来时它还在(提示符下面那行),回车就能执行。

### 拼音输入法:Shift 切中英,打拼音选字

按一下 **Shift** 切到中文(再按一下切回英文),然后打拼音:

```
> shuang
（屏幕最底两行浮出候选条,命令行保持不动）
 1.双 2.爽 3.霜 4.塽   1-9 pick  space pick first Esc cancel
 拼音: shuang
> 霜
```

选字之后,拼音被原地擦掉、换成汉字,命令行**不换行也不重画**,候选条(两行)直接消失。
候选多于一页时,第一行右侧会显示页码,按 `,` / `.` 就地翻页重画候选条:

```
> xiang
（底行:1.想 2.向 3.像 4.相 5.乡 6.项 7.象 8.香 9.响  ,/. page 1/4  Esc cancel）
```
(作者ps:日文韩文目前不会做 毕竟也不是我的母语 繁体中文倒是可以 但是免不了拼音了 仓颉注音我不行)
数字 1-9 直接选**当前页**对应的候选、空格选当前页第 1 个、`,` / `.` 翻上一页 / 下一页
(候选只有一页时提示里不显示页码)、Esc 取消;候选按**词频**排(最常用的在最前面)。
数据在磁盘的 `/SYS/PINYIN.BIN`(6000 常用字、400 个音节,`ji` 这种音有 11 页),由
`tools/mkpinyin.py` 用 wordfreq + pypinyin 生成;想换词表就跑 `make pinyin`(需要这两个 python 包)。
盘上没有这个文件时输入法会自己安静地关掉,不影响其它功能。

![拼音输入法](docs/screenshot-ime.png)

### rc.conf:开机读配置、按配置跑服务

`/SYS/RC.CONF` 就是一行行 `key=value`(BSD / OpenRC 那种写法,不是 systemd 的段)。
开机时内核读它、把 `boot_msg` 打出来、按 `autostart` 决定要不要把启用的服务跑起来;
`rc` 一条命令就能看配置、看服务、起服务、重读刚写下的文件,还有一本带 PIT tick 的
事件账本。细节和全部 key 见 [docs/rc-conf.md](docs/rc-conf.md)。
显示名默认 `KKernel`,可在 `RC.CONF` 里用 `osname = 你的名字` 自定义(开机打一行 `os: <名字>`)。

![rc.conf 服务列表与事件账本](docs/screenshot-rc.png)

### 提示符样式:一个 `style` 命令看腻就换

天天盯着一样的 `>` 确实眼睛疼,所以提示符做成了可换的样式(0.14 版起**默认就是颜文字**):

```
(・ω・)> style
prompt style: kao   (style plain|moe|dos|c64|kao 换样式,默认 kao;RC.CONF 里写 style = moe 开机生效)
(・ω・)> cat nosuch.txt
file not found
(；ω；)> ls
BIN  <DIR>
LIB  <DIR>
...
(・ω・)>
```

| 样式 | 长什么样 |
|---|---|
| `kao`(默认) | 黄色 `(・ω・)>` / `(・ω・)docs>`;命令出错后脸变红 `(；ω；)`,下一次输入就恢复(ps:kawaii~) |
| `plain` | `>` / `docs>` / `2>` |
| `moe` | 粉色 `かいかーねる>`,文件找不到、命令不认识也换成吐槽文案 |
| `dos` | `C:\>` / `C:\docs>` |
| `c64` | `READY.`,一行一条命令,Commodore 64 BASIC 那味儿 |

`RC.CONF` 里加一行 `style = moe`(或 `kao` / `plain` / `dos` / `c64`),开机就用那个样式(见 [docs/rc-conf.md](docs/rc-conf.md))。
萌文案不是乱写的:字库里有半角片假名和 CJK;0.13 版又把希腊/标点/数学/箭头/几何/符号等范围补进字库,
kaomoji 能用的素材多了一大把。

![颜文字提示符](docs/screenshot-style-kao.png)

![萌样式提示符](docs/screenshot-style-moe.png)

