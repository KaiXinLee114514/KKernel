# KKernel

**一个从零手写的 32 位 x86 操作系统。**
(...!才...才不是专门为你写的README呢...碰巧罢了...! 哼!zako!baka!!)
引导扇区、保护模式、分页、抢占调度、图形终端、FAT 文件系统、设备层、管道、多 shell、系统内 C 编译器、USB 大容量存储——全部自己实现，不 fork 任何现成内核。

不是教学演示，也不是课程作业：每次提交都要求能启动、能通过自动化测试、有文档。(哪个混蛋说我这是教学系统的?!)

![KKernel 硬盘模式:字库从磁盘读、FAT16 列目录、跑磁盘上的程序](docs/screenshot-fat.png)

*硬盘模式启动：从磁盘加载 42 112 字形全字库、挂载 FAT16、`ls` 列目录、`run` 跑盘上的程序。*

![4 条 shell 互相切换](docs/screenshot-shells.png) ![计算器](docs/screenshot-calc.png) ![文本编辑器](docs/screenshot-edit.png) ![拼音输入法悬浮候选条](docs/screenshot-ime.png)

## 设计目标

参照 Unix v6「小而完整」的标准从零搭一个操作系统：**引导 → 内核 → 内存管理 → 进程 → 文件系统 → 设备 → shell → 工具链**，每一层都自己写，并且能自己编译自己跑起来。

不追求马上兼容 POSIX 或现成软件生态，先把「一个系统该有的骨架」做完整，再往上叠加网络、POSIX-lite、多用户等能力。(太难了一时半会兼容不完)

## 基础功能

### 引导与内核

- 512 字节引导扇区（软盘 / 硬盘双路径，LBA 多扇区读 + CHS 兜底）
- 保护模式：GDT、IDT、TSS，26 个中断 / 异常处理
- E820 内存探测，运行时确定 `ident` 映射与页池大小，物理页池 + 分页 + 按需分页
- 每个程序独立地址空间，页表从页池动态分配，退出时整空间回收、页泄漏检测

### 进程与多 shell

- 抢占式轮转调度（20 ms 时间片，6 个线程槽），每线程独立内核栈
- ring 3 用户态执行：`iret` 进入、TSS 维护内核栈；用户程序摸内核内存会被页保护干掉
- 4 条 shell 各跑在一条内核线程里，每条 shell 可以独立启动程序，`Ctrl+←/→` 切换焦点
- `ps` / `spawn` / `kill` 管理内核线程与程序

### 图形终端与中文

- VBE 800×600×32 图形模式，帧缓冲按行缓冲、脏段刷新，支持滚动
- UTF-8 终端：ASCII + 全宽汉字混排、42 112 字形全字库（从磁盘加载）、416 字形内置子集兜底
- 拼音输入法：Shift 切换，候选条浮在屏幕最底两行（候选 + 拼音回显各一行），支持翻页 / 取消
- 提示符样式：`kao`（默认颜文字 `(・ω・)`） / `plain` / `moe` / `dos` / `c64`，`RC.CONF` 可设
- 颜色、光标、清屏、按行定位输出等终端功能

### 文件系统

- FAT16 / FAT32 读写：子目录、VFAT 长文件名、多簇文件、两份 FAT 一致性维护
- `mkfat.py` 宿主工具生成镜像；系统镜像根目录分为 `/BIN` `/LIB` `/SYS` `/DOCS` `/SRC` `/TEST` `/DEV` `/MNT` `/INCLUDE`
- `run` 命令自动去 `/BIN` 找程序；程序可以直接读写当前目录、子目录
- 实验性 **KiFS** 文件系统（独立仓库）：journal 崩溃一致性 + 写时复制（CoW），支持大卷、符号链接、FUSE 挂载

### 设备与存储

- `/DEV` 虚拟设备层：`NULL` `ZERO` `RANDOM` `RTC` `CON` `DEVICES`，`cat` / `write` 直接用
- ATA PIO 硬盘驱动（LBA28 / LBA48），支持多设备
- UHCI USB 主机控制器 + USB 大容量存储（只读裸盘）：INQUIRY / READ CAPACITY / READ(10) / MBR 解析
- PCI 总线枚举（枚举 IDE / USB / 网卡等设备）

### Shell 与管道

- 30+ 内部命令：`ls` `cd` `cat` `write` `cp` `mv` `rm` `mkdir` `rmdir` `run` `ps` `kill` `spawn` `shell` `clear` `info` `debug` `reboot` `uptime` `sleep` `date` `style` `pci` `usbdisk` `rc` `help` 等
- 管道 `A | B`（最多 4 段）：生产者屏幕输出被内核捕获进页池缓冲，消费者通过 `int 0x30` 功能 17 读回；自带 `WC` / `UPPER` / `GREP` / `HEAD` 工具
- `write` / `cp` / `mv` 写文件撞名时提示 **R/D/O**（Rename / Don't write / Overwrite）
- `RC.CONF` 配置开机 hostname / services / 提示符样式；事件账本记录启动过程，`rc log` 可查
- 命令历史、行编辑（退格按 UTF-8 整字符删除）、多行 buffer

### 开发工具链

- 内置 **TCC 0.9.28 移植**：系统内编译 C → 生成 ELF → 直接运行（TCC 源码未改，配 18 个标准头文件在 `/INCLUDE`）
- 宿主开发路线：`bin/kkernel-cc` + SDK，把 C 程序编成 KKernel 可执行文件丢进 `progs/`
- `int 0x30` 系统调用 API 17 个功能：打印、字符串、文件读写、键盘、内存信息、堆、参数、管道等

### 用户程序

- 计算器（定点小数四则运算）、文本编辑器（UTF-8 整字符编辑 + 拼音输入）、vi（STEVIE 移植）、扫雷（4 难度 / 随机雷数 / QUICKPASS 作弊码）、浮点计算器、播放器、以及一批自测试程序

### 测试

- 9 组 QEMU 自动化套件（软盘 / 硬盘 / FAT32 / 分页异常 / 键盘 / shell / 完整字库 / USB 等），测试台真正启动 QEMU、截图、用 OCR 断言屏幕内容，不做 mock
- KiFS 独立项目另有断电注入一致性测试

## 快速开始

依赖（Debian/Ubuntu）：

```sh
sudo apt install nasm qemu-system-x86 gcc-multilib python3 genisoimage
```

编译并启动：

```sh
git clone https://github.com/KaiXinLee114514/KKernel.git
cd KKernel
make hd                 # 构建 16 MB 硬盘镜像 build/kkernel-hd.img
./tools/run.sh --hd     # 用 QEMU 启动
#目前windows编译请左转claude code或vibe coding解决
```

也可以 `make run` 直接跑默认硬盘镜像。

### 有哪些能玩的

```text
> help                  # 命令列表
> ls                    # 列目录（根目录是 9 个分类目录）
> run CALC              # 计算器
> run MINE.BIN          # 扫雷（1-4 选难度；QUICKPASS 作弊码把雷标红(作弊码 一是测试这个系统重绘制 雷生成什么的 二是我自己已经破防十几次了...)）
> run EDIT DOCS/NOTES.TXT
> cat DOCS/ZH.TXT       # 《黄鹤楼》——中文显示
> cat DOCS/ZH.TXT | run GREP 黄鹤    # 管道
> run TCC.BIN -c SRC/TCC_INC.C -o A.O
> run TCC.BIN -static -nostdlib A.O LIB/CRT_TCC.O LIB/MINIC.O -o A.ELF
> run A.ELF             # 系统内编译 C 并运行
```

> TCC 按文件后缀识别文件类型，命令行里请用小写 `.c` / `.o`。

### 测试

```sh
make test               # 全部 9 组 QEMU 套件（约 40–60 分钟）
make test-hda           # 单组：硬盘模式快速验证
make test-mine          # 扫雷专项
make test-usb           # USB 大容量储存（挂一个假 U 盘启动）
```

## 源码地图

```text
boot/        引导扇区（512 B）与内核加载
kernel/      内核：kmain / paging / sched / fat / ata / usb / fbterm / ime / shell / api / elf …
lib/         迷你 libc（minic）与 C 启动代码
include/     kkernel.h —— int 0x30 API 声明
progs/       C / 汇编用户程序：计算器、编辑器、vi、扫雷、TCC 工具链、测试程序…
extensions/  TCC 移植、STEVIE(vi)、播放器等扩展
tccinc/      系统内 TCC 的 18 个标准头文件（生成镜像里的 /INCLUDE）
font/        字库数据与生成工具
tools/       mkfat / mkimg / run.sh / onekey_push.sh 等
tests/       QEMU 自动化测试（qemu_test.py 等）
docs/        架构、踩坑、shell 命令、子系统文档
```

## 文档索引

| 文档 | 内容 |
|---|---|
| [docs/architecture.md](docs/architecture.md) | 图形模式、磁盘/地址空间/ring 3/线程/多 shell/输入法/rc.conf 实现细节 |
| [docs/pitfalls.md](docs/pitfalls.md) | 39 条真实踩坑记录（调试笔记，精华所在） |
| [docs/shell-commands.md](docs/shell-commands.md) | shell 命令参考 |
| [docs/hacking.md](docs/hacking.md) | 怎么改：构建、测试、调试、提交约定 |
| [docs/roadmap.md](docs/roadmap.md) | 路线图与待办 |
| [docs/filesystem.md](docs/filesystem.md) | FAT16/32 实现、镜像布局、mkfat 用法 |
| [docs/encoding.md](docs/encoding.md) | UTF-8、字库、拼音输入法 |
| [docs/programs.md](docs/programs.md) | 用户程序(SDK) 与 int 0x30 API |
| [docs/pci.md](docs/pci.md) | PCI 总线枚举 |
| [docs/usb-disk.md](docs/usb-disk.md) | USB 大容量储存（只读裸盘） |
| [docs/pipes.md](docs/pipes.md) | 顺序管道实现 |
| [docs/devices.md](docs/devices.md) | `/DEV` 设备层 |
| [docs/font.md](docs/font.md) | 中文与字库数据 |
| [docs/rc-conf.md](docs/rc-conf.md) | `RC.CONF` 配置项 |
| [docs/known-issues.md](docs/known-issues.md) | 已知限制与 flaky 测试说明 |
| [docs/design-multishell-cow.md](docs/design-multishell-cow.md) | 多 shell 虚拟控制台 + fork/内存 CoW 设计稿 |

## 已知限制

- **单用户，无账户/权限体系**：隔离只有 ring 3；FAT 没有权限位。(现在有了,文档懒得更新 临时加的几句 总之有了 Super=root=SYSTEM为最高账户 密码root 剩下的我也不知道了)
- **没有 fork/exec/信号**：程序由 shell 启动，退出回 shell；**内存级 fork + 写时复制（CoW）尚未实现**，属于 Phase 3 路线图（注：KiFS 文件系统里的 CoW 是文件数据块的写时复制，与本条不同）。(实际上有了)
- **没有网络**：PCI 能枚举网卡，协议栈还没写。(实在是没时间 等着吧)
- **USB 只支持 UHCI + 只读储存**，第一个 USB 设备必须是 U 盘，不支持热插拔。(这句删了...已经有了好吗?!)
- **单核**：无 SMP；图形终端逐像素刷新，不适合高频动画游戏。
- 真机兼容性有限（主要在 QEMU 验证）；详细清单见 [docs/known-issues.md](docs/known-issues.md)。(实在是没那么多钱买新设备做experiments了!)

## 参与开发

- 开发流程与约定见 [docs/hacking.md](docs/hacking.md)：中文注释、改完必须跑 `make test-hda`、提交信息中文前缀。
- 遇到 bug 请开 issue，附 QEMU 版本与复现命令。
- 也可以直接提 PR——小型、可测试、带说明的改动最容易合入。

## 许可

[GPL-3.0](LICENSE)。字库来自 GNU Unifont（GPL-2+，见 [font/README.md](font/README.md)）；TCC 移植、STEVIE 等第三方组件版权归各自作者，见对应目录的 README。

---

**KKernel** —— *Kai + Kernel*。一个初中生从引导扇区开始写的操作系统，仍在持续长大。(2027下半年以后请自行脑补为高中生)
联系方式:lkx2025awa@outlook.com qq:3927714593 SMS:(+86)183-7205-1152 X:qq3927714593
