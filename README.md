# KKernel

**一个从零手写的 32 位 x86 操作系统。目标：功能对标并超越 1975 年的 Unix v6。**

引导扇区、保护模式、分页、抢占调度、VBE 图形终端、FAT16/FAT32、`/DEV` 设备层、管道、多 shell、系统内 C 编译器、USB 大容量存储——全部自己实现，不 fork 任何现成内核。

这不是教学演示。每一次提交都要求：能启动、能通过自动化测试、有文档。

![KKernel 硬盘模式:字库从磁盘读、FAT16 列目录、跑磁盘上的程序](docs/screenshot-fat.png)

*硬盘模式启动：从磁盘加载 42 112 字形全字库、挂载 FAT16、`ls` 列目录、`run` 跑盘上的程序。*

![4 条 shell 互相切换](docs/screenshot-shells.png) ![计算器](docs/screenshot-calc.png) ![文本编辑器](docs/screenshot-edit.png) ![拼音输入法悬浮候选条](docs/screenshot-ime.png)

## 为什么对标 Unix v6

Unix v6（1975）是「小而完整」的标杆：在 64 KB 地址空间的 PDP-11 上，同时做到多任务、分层文件系统、shell、C 编译器和设备抽象——一个能自己养活自己的最小系统。

KKernel 用同一套标准要求自己，但放在 2026 年的 x86 硬件上，并把 v6 时代没有的东西补上：图形、UTF-8/中文、USB、系统内自举编译器。

**现在的 KKernel 已经覆盖了 v6 的骨架，并在图形、中文、自举编译、USB 上超出；差距在多用户、信号、fork、网络——这些是路线图里明确的目标。**

## 和 Unix v6 对照

| 能力 | Unix v6 (1975) | KKernel (2026) |
|---|---|---|
| 平台 | PDP-11/40，64 KB 地址空间 | x86 32 位，分页 + ring 3 |
| 内存管理 | 交换，无分页 | 分页 + 按需分页，每程序独立地址空间 |
| 进程 | 分时多用户进程 | 抢占式内核线程（20 ms 轮转）+ 4 条 shell，每条 shell 各跑一个程序 |
| 用户态隔离 | 有（多用户） | 有（ring 3 + TSS + 页表 U/S 位） |
| 文件系统 | 原生 Unix FS（RK05 盘） | FAT16/FAT32 读写；实验性 KiFS（独立仓库，journal + CoW） |
| 设备抽象 | 字符/块设备 | `/DEV` 虚拟设备层 + ATA PIO（LBA28/48）+ UHCI USB 存储（只读） |
| 终端 | 串口 ASCII | VBE 800×600×32 图形终端，UTF-8 + 42 112 字形 + 拼音输入法 |
| 编译器 | 系统自带 C 编译器 | 内置 TCC 移植：系统内编译 C → ELF → 运行 |
| shell | sh（管道、重定向） | KKernel shell：管道、`cp`/`mv`、`/DEV`、样式、rc.conf 开机服务 |
| 网络 | 无 | 无（PCI 已能枚举 e1000，协议栈在路线图上） |
| 多用户/权限 | 多用户 + 权限位 | 单用户；FAT 无权限位（隔离靠 ring 3） |
| 体积 | 内核数十 KB，磁盘 2.5 MB 级 | 内核 128 KB，镜像 16 MB，代码约 2.4 万行 |

> 一句话：**KKernel 是 v6 的能力骨架 + 2026 年的终端/编译器/USB，还差 v6 的多用户与网络。**

## 已实现

| 子系统 | 内容 |
|---|---|
| 引导 | 512 B 引导扇区（软盘/硬盘双路径，LBA + CHS 兜底），加载内核到 0x100000 |
| 内核骨架 | 保护模式、GDT/IDT、26 个中断/异常、TSS、`iret` 进入 ring 3 |
| 内存 | E820 探测、运行时 `ident`、物理页池、分页 + 按需分页、每程序独立地址空间、页泄漏回收 |
| 调度 | 抢占式轮转（20 ms 时间片，6 个线程槽），`ps`/`spawn`/`kill`；多 shell 各一条内核线程，`Ctrl+←/→` 切焦点 |
| 图形 | VBE 800×600×32、帧缓冲行缓冲与滚动、UTF-8 终端（解码 + 全宽汉字）、42 112 字形全字库（磁盘）/ 416 字形内置子集、光标/清屏/颜色、提示符样式（`kao` 默认 / `plain` / `moe` / `dos` / `c64`） |
| 输入 | PS/2 键盘、拼音输入法（Shift 切换，候选条浮在屏幕最底两行，候选 + 拼音回显） |
| 文件系统 | FAT16/FAT32 读写（子目录、VFAT 长文件名、多簇文件、FAT 双份一致性）；`mkfat.py` 生成镜像；镜像根目录 `/BIN` `/LIB` `/SYS` `/DOCS` `/SRC` `/TEST` `/DEV` `/MNT` `/INCLUDE` |
| 设备 | `/DEV` 虚拟设备（`NULL` `ZERO` `RANDOM` `RTC` `CON` `DEVICES`）、ATA PIO、UHCI USB + USB 大容量储存只读（INQUIRY / READ CAPACITY / READ(10) / MBR）、PCI 总线枚举 |
| shell | 30+ 命令：`ls` `cd` `cat` `write` `cp` `mv` `rm` `mkdir` `run` `ps` `shell` `style` `usbdisk` 等 |
| 管道 | `A \| B` 顺序管道（最多 4 段）：生产者屏幕输出被内核捕获进页池缓冲，消费者用 `int 0x30` 功能 17 读回；配套工具 `WC` / `UPPER` / `GREP` / `HEAD` |
| 工具链 | 内置 TCC 0.9.28 移植（源码没改，配 18 个标准头文件到 `/INCLUDE`）：系统内编译 C → ELF → 运行；宿主机 `bin/kkernel-cc` + SDK |
| 用户程序 | 计算器、文本编辑器（UTF-8 整字符退格 + 拼音输入）、vi（STEVIE 移植）、扫雷（4 难度 / 随机雷数 / QUICKPASS 作弊）、FCALC 浮点计算器、播放器、自测试程序等 |
| 系统服务 | `RC.CONF` 开机配置（hostname/services/style…）、服务启动、事件账本（环形缓冲 + `rc log`） |
| 测试 | 9 组 QEMU 自动化套件（软盘/硬盘/FAT32/异常/键盘/shell/完整字库/USB），测试台屏幕 OCR 断言；另有 KiFS 断电注入测试（独立项目） |

## 路线图摘要

**已完成的大项**：多 shell 地址空间地基（每线程 TCB 持地址空间状态）、管道、`/DEV`、USB 大容量储存、FAT32、系统内 TCC 自举、KiFS 实验文件系统（journal + CoW，独立仓库）。

**下一步**：
1. **每 shell 独立虚拟控制台**（Phase 2）：后台 shell 不再共用一块屏，`Ctrl+←/→` 切出真正的多窗口体验——设计见 [docs/design-multishell-cow.md](docs/design-multishell-cow.md)。
2. **fork + 写时复制 + wait**（Phase 3）：真正的进程模型，为 POSIX 兼容打地基。
3. **网络**：PCI 已能枚举 e1000，协议栈（ARP/IP/ICMP/UDP/TCP）是中期目标。
4. **POSIX-lite**：在 `int 0x30` 之上叠一层类 POSIX 系统调用，让现成 C 程序更容易移植。
5. **多用户与权限**、**USB 写入**、**SMP**：长期目标。

详见 [docs/roadmap.md](docs/roadmap.md)。

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
```

也可以 `make run` 直接跑默认硬盘镜像。

### 有哪些能玩的

```text
> help                  # 命令列表
> ls                    # 列目录（根目录是 9 个分类目录）
> run CALC              # 计算器
> run MINE.BIN          # 扫雷（1-4 选难度；QUICKPASS 作弊码把雷标红）
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

测试台会真的启动 QEMU、截图、用 OCR 断言屏幕内容；每项测试都对应一个真实行为，而不是 mock。

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
| [docs/design-multishell-cow.md](docs/design-multishell-cow.md) | 多 shell 虚拟控制台 + fork/CoW 设计稿 |

## 已知限制

- **单用户，无账户/权限体系**：隔离只有 ring 3；FAT 没有权限位。
- **没有 fork/exec/信号**：程序由 shell 启动，退出回 shell；进程模型的 Phase 2/3 在路线图上。
- **没有网络**：PCI 能枚举网卡，协议栈还没写。
- **USB 只支持 UHCI + 只读储存**，第一个 USB 设备必须是 U 盘，不支持热插拔。
- **单核**：无 SMP；图形终端逐像素刷新，不适合高频动画游戏。
- 真机兼容性有限（主要在 QEMU 验证）；详细清单见 [docs/known-issues.md](docs/known-issues.md)。

## 参与开发

- 开发流程与约定见 [docs/hacking.md](docs/hacking.md)：中文注释、改完必须跑 `make test-hda`、提交信息中文前缀。
- 遇到 bug 请开 issue，附 QEMU 版本与复现命令。
- 也可以直接提 PR——小型、可测试、带说明的改动最容易合入。

## 许可

[GPL-3.0](LICENSE)。字库来自 GNU Unifont（GPL-2+，见 [font/README.md](font/README.md)）；TCC 移植、STEVIE 等第三方组件版权归各自作者，见对应目录的 README。

---

**KKernel** —— *Kai + Kernel*。一个初中生从引导扇区开始写的操作系统，仍在持续长大。
