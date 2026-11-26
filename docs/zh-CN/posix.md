[English](../posix.md)

# POSIX 转译层(int 0x80)

KKernel 现在能直接跑**现成的 Linux i386 静态可执行文件** —— 通过一个 `int 0x80`
转译层。原生 `int 0x30` 程序接口不受影响,两个接口互相独立:

| 接口 | 谁在用 | 入口 | 寄存器约定 |
|---|---|---|---|
| `int 0x30` | KKernel 原生平铺程序 | kernel `api.asm` | `eax` = 功能号 |
| `int 0x80` | Linux i386 ELF 程序 | kernel `posix.asm` | `eax` = 系统调用号(Linux ABI) |

## 为什么做转译层

最终目标是跑**现成的 static busybox** applet。写一个完整 Linux 内核不现实,
但用户可见的大部分功能内核里已经有了(控制台、FAT 文件系统、进程、内存);
`int 0x80` 层只负责把 Linux 的寄存器 ABI 翻译到这些内核能力上。

## Linux i386 ABI(本实现遵循的)

- 入口:IDT 向量 `0x80`,DPL = 3(ring 3 程序可以 int 进来)。
- 参数:`eax` = 系统调用号,之后 `ebx`、`ecx`、`edx`、`esi`、`edi`、`ebp`
  按 Linux 的惯例放参数。
- 返回:`eax` = 结果;出错返回**负数**(`-errno`)。
- **除 `eax` 外所有寄存器跨越调用保持不变** —— Linux 程序(和 libc)依赖这一点。
- 未知系统调用号:`eax = -ENOSYS`(`-38`)。

## P1:最小闭环(已完成)

| 编号 | 调用 | 签名 | P1 行为 |
|---|---|---|---|
| 1 | `exit` | `exit(code)` | 结束当前进程,退出码交给父进程 `wait` |
| 3 | `read` | `read(fd, buf, count)` | 只支持 `fd 0`(键盘),返回 1;后台进程返回 0(EOF) |
| 4 | `write` | `write(fd, buf, count)` | `fd 1`/`fd 2` → 控制台;其它 fd → `-EBADF`(`-9`) |

实现要点:

- `kernel/posix.asm` 装 `int 0x80` 门并派发系统调用。派发帧沿用原生 `int 0x30`
  stub 的"全保存、只回写 `eax`"套路,所以寄存器保持语义自然成立。
- `sys_write` 把字节喂给正常终端层(`term_putc`),输出和原生程序一模一样
  (VBE 图形控制台和 VGA 文本模式兜底都工作)。
- `sys_exit` 复用现有进程退出路径:子进程变成僵尸等父进程收尸;shell 直接
  跑起来的程序则回到 shell 提示符。

## P2:文件与内存(已完成)

| 编号 | 调用 | 签名 | P2 行为 |
|---|---|---|---|
| 5 | `open` | `open(path, flags, mode)` | 打开**已存在**的 FAT 文件;`flags` 低 2 位 = 0/1/2(读/写);其它位(如 `O_CREAT`)→ `-ENOSYS`;路径从 FAT 根目录解析(无进程 cwd);路径最长 39 字符 |
| 6 | `close` | `close(fd)` | fd 0/1/2 直接成功;3+ 释放槽位 |
| 19 | `lseek` | `lseek(fd, offset, whence)` | `SEEK_SET`/`SEEK_CUR`/`SEEK_END`;偏移必须落在 0..8 KiB;fd 0/1/2 → `-ESPIPE` |
| 3 | `read` | `read(fd, buf, count)` | fd 0 = 键盘(同前);fd 3+ = 文件:从当前偏移读最多 `count` 字节并推进偏移 |
| 4 | `write` | `write(fd, buf, count)` | fd 1/2 = 控制台;fd 3+ = **整文件覆盖**:先读旧内容进 scratch,替换目标区间,再一次性写回文件 |
| 45 | `brk` | `brk(addr)` | 程序堆:`addr = 0` 返回当前 brk;合法 `addr` 移动 brk 并返回新值;越界返回旧值 |

实现说明:

- 文件描述符表是**全局**的(8 个文件槽,fd 3..10),用现有 `fs_lock` 互斥锁保护;
  每次 `process_exec` 都会清空,新程序不会继承上一个程序的 fd。
- `open` 复用 FAT 辅助函数(`fat_path`/`fat_stat`/`fat_read_file`/`fat_write_file`),
  期间持 `fs_lock`,并把 FAT 当前目录临时重置到根目录。
- 文件数据通过一个全局 8 KiB scratch 缓冲流转,所以每次调用都是"整文件读-改-写"。
  小文件足够简单正确,但不是 POSIX 级页缓存。
- `brk` 只在 TCB(`TCB_POSIX_BRK`)里记账;真正物理页由程序堆窗口
  (`SPACE_HEAP_VA` = 0x180000)的缺页处理按需补零页,所以首次写新页就能用。
- 涉及的错误码:`-EBADF`(fd 非法)、`-ENOENT`(文件不存在)、
  `-EINVAL`(参数非法/过大)、`-EMFILE`(fd 表满)、`-ENOSPC`(超出 scratch)、
  `-ESPIPE`(管道上的 seek)、`-EIO`(FAT I/O 错误)、`-ENOSYS`(不支持)。

## 测试(P1 + P2)

- P1:[`tools/posix/p1_hello.asm`](../../tools/posix/p1_hello.asm) —— 裸汇编 i386 ELF,
  调 `write(1, "hello from int 0x80\n", 20)` 后 `exit(0)`。
- P2:[`tools/posix/p2_file.asm`](../../tools/posix/p2_file.asm) —— `brk` 拿缓冲,
  对 `TEST/P2_DATA.TXT` 做 `open`/`read`/`write`/`lseek`/`close`,打印
  `p2-file: p2 data ok` 和 `p2-file: done`;以及
  [`tools/posix/p2_brk.asm`](../../tools/posix/p2_brk.asm) —— `brk` 申请 3 个新堆页,
  写入并校验 dword 模式,打印 `p2-brk: ok`。
- 用 `nasm -f elf32` + `ld -m elf_i386 -static -n -Ttext=0x120000` 构建
  (`-Ttext=0x120000`:内核 ELF 装载器把程序展开到 0x120000 程序窗口;
  `-n` 防止链接器在基址以下额外生成一个 `PT_LOAD` 段)。
- `make test-posix` 启动硬盘镜像,依次跑 P1/P2 程序,断言:输出字符串出现、
  每个程序后回到 shell、页池不泄漏。


- 测试程序:[`tools/posix/p1_hello.asm`](../../tools/posix/p1_hello.asm) ——
  一个裸机 i386 ELF(无 libc),调用 `write(1, "hello from int 0x80\n", 20)`
  然后 `exit(0)`。用 `nasm -f elf32` + `ld -m elf_i386 -static -n -Ttext=0x120000`
  构建。
  (`-Ttext=0x120000`:内核 ELF 装载器把程序展开到自己的程序窗口 0x120000;
  `-n` 防止链接器在基址下面再生成一个映射 ELF 头的 `PT_LOAD` 段。)
- `make test-posix` 启动硬盘镜像,跑 `run TEST/P1_HELLO.ELF`,断言:`hello`
  字符串出现、shell 提示符回来、页池没有泄漏。

## 路线图

| 阶段 | 内容 | 状态 |
|---|---|---|
| P1 | `exit` / `read` / `write` | 完成 |
| P2 | `open` / `close` / `lseek` / 文件读写、`brk` | 计划 |
| P3 | `stat` / `fstat` / `getdents` / `ioctl` / 时间调用 | 计划 |
| P4 | `fork` / `execve` / `wait4` / `getpid` / `kill` | 计划(先评估) |
| P5 | static i386 busybox applet 子集 | 计划(先评估) |

## 已知限制(P1 + P2)

- fd 0 的 `read` 一次只读一个字节;没有行规程/termios。
- fd 表是全局的(不是每进程):fork 会共享它;P4 做 fork 时再一起考虑。
- `open` 不创建/不截断文件(`O_CREAT` 等 → `-ENOSYS`);`write` 是整文件覆盖,
  不是原地更新。
- 文件大小上限 8 KiB(单个 scratch 缓冲)。
- 文件路径从 FAT 根目录解析,没有每进程 cwd。
- `brk` 只能在进程预先算好的堆窗口内增长。

- `read` 一次只读一个字节且只支持 `fd 0`;没有行规程、没有 termios。
- 还没有 0/1/2 以外的 fd —— 文件系统调用在 P2 到来。
- 程序必须是静态链接的 i386 ELF;没有动态链接器、没有 `mmap`、没有线程。
- 转译层是"并列"于原生 API,而不是叠在它上面;一个程序必须选一种 ABI
  (混用行为未定义)。
