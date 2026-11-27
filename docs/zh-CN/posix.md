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

## P3:文件元信息、目录与时间(已完成)

| 编号 | 调用 | 签名 | P3 行为 |
|---|---|---|---|
| 106 | `stat` | `stat(path, buf)` | 填 i386 `struct stat`(64 字节):`st_mode`/`st_size`/`st_mtime` 等;支持目录和根 `"/"` |
| 107 | `lstat` | `lstat(path, buf)` | 同 `stat`(FAT 没有符号链接) |
| 108 | `fstat` | `fstat(fd, buf)` | fd 0/1/2 → `S_IFCHR`;3+ 走 fd 表;目录 fd → `S_IFDIR` |
| 220 | `getdents64` | `getdents64(fd, buf, count)` | 把 FAT 目录项按 `linux_dirent64` 记录返回;条目索引 cookie 存在 fd 槽里 |
| 54 | `ioctl` | `ioctl(fd, req, arg)` | 只支持 fd 0/1/2 的 `TCGETS`(0x5401)→ 36 字节清零 termios,返回 0;其它 → `-ENOTTY` |
| 13 | `time` | `time(tloc)` | CMOS RTC → Unix 时间戳(本地时间,不做时区);`tloc` 非空时写入 |
| 78 | `gettimeofday` | `gettimeofday(tv, tz)` | `tv = {sec, usec}`;`usec` 由 100 Hz PIT tick 推算 |

实现说明:

- **目录 fd**:`open` 打开目录只允许只读成功,fd 槽的 `PFD_FLAGS` 打上
  `PFD_DIR` 标记;对目录 fd 的 `read`/`write`/`lseek` 返回 `-EISDIR`。
  目录首簇存在 fd 槽里,`PFD_OFF` 同时用作 `getdents64` 的 cookie(下一条索引)。
- `getdents64` 用到 fat.asm 新增的两个辅助函数:`fat_dir_open`(路径 → 目录首簇)
  和 `fat_dirent`(取第 N 个目录项,跳过删除项、LFN 项和 `.`/`..`)。
  返回的名字是 **8.3 短名**(长文件名的文件以短别名出现)。记录布局
  `d_ino/d_off/d_reclen/d_type/d_name`,8 字节对齐;`d_type` 为 4(DT_DIR)
  或 8(DT_REG)。
- `struct stat` 用 i386 布局(64 字节):`st_dev` 0、`st_ino` 4、`st_mode` 8、
  `st_nlink` 10、`st_uid` 12、`st_gid` 14、`st_rdev` 16、`st_size` 20、
  `st_blksize` 24、`st_blocks` 28、`st_atime` 32、`st_mtime` 40、`st_ctime` 48。
  时间字段都取当前 RTC 时间;`st_mode` 文件 0644、目录 0755、控制台字符设备 0620。
- `time`/`gettimeofday` 按公历闰年规则把 RTC 日期换算成 Unix 时间戳;不支持时区
  (CMOS 本地时间当 UTC 处理)。`gettimeofday.tv_usec` = `(ticks % 10) * 10000`。
- P3 新增错误码:`-EISDIR`(把目录当文件用)、`-ENOTDIR`、`-ENOTTY`。

## P4:进程(P4a/P4b/P4c 已完成)

P4 分三段:**P4a**(fork/getpid/wait4)、**P4b**(kill)、**P4c**(execve),全部完成。
进程层直接复用原生内核能力(fork 写时复制地址空间、wait/收尸、信号、exec)。

| # | 系统调用 | 签名 | P4 行为 |
|---|---|---|---|
| 2 | `fork` | `fork()` | 复制当前进程(写时复制窗口页、独立 guard 页、共享镜像 staging);**子进程返回 0、父进程返回子 pid**,失败 `-EAGAIN` |
| 20 | `getpid` | `getpid()` | → 调用进程的 pid(pid = TCB 槽号 + 1) |
| 114 | `wait4` | `wait4(pid, status*, options, rusage)` | 等子进程退出/停止;`options` 只认 `WNOHANG`(1)/`WUNTRACED`(2);`pid` 支持 `> 0` / `-1`(任意子进程);返回子 pid、WNOHANG 无事件返回 `0`、没孩子 `-ECHILD`、其它 pid 形式 `-ENOSYS`;`*status` 用 Linux 编码:正常退出 `(exitcode & 0xFF) << 8`、停住 `0x7F` |
| 11 | `execve` | `execve(path, argv, envp)` | 用 `path` 处的 ELF/BIN 替换当前程序镜像;`argv`/`envp` 暂忽略(不传给程序);失败返回 `-ENOENT` 且旧程序继续运行;成功不返回 |
| 37 | `kill` | `kill(pid, sig)` | 只支持 `pid > 0`(0/负 → `-ENOSYS`);信号支持 `SIGKILL`(9)/`SIGTERM`(15)/`SIGINT`(2)/`SIGSTOP`(19)/`SIGCONT`(18);`sig = 0` 是探测;返回 `0` / `-ESRCH`(无此进程)/ `-EPERM`(权限)/ `-EINVAL`(信号不支持) |

实现说明:

- `fork` 复用 `process_fork`:内核侧中断现场被复制进子进程的内核栈,所以子进程
  从 `int 0x80` 返回点继续跑、`eax = 0`;父子关系记在 TCB 里,`wait4` 只收自己的
  孩子。
- `wait4` 把 Linux 选项位映射到内核 wait 标志,事件详情(状态/pid/退出码)从
  **调用线程自己的 TCB** 读,两个进程并发 wait 不会互相覆盖。
- `fork` 继承 POSIX brk 指针(`TCB_POSIX_BRK`)。
- `kill` 把 Linux 信号号映射到内核的打包 `signal_t`(`class<<24 | action<<16 |
  level`,user 类/user 级)后调 `process_signal_send`,原生 UID 权限检查仍然生效;
  先校验目标槽是否存在,以此区分 `-ESRCH` 与 `-EPERM`。
- `execve` 先把用户态路径拷进内核缓冲(`posix_exec_path`,最长 63 字节,超了 →
  `-ENAMETOOLONG`),清掉继承来的 `TCB_EXECBUF` 载荷,再调原生 `process_exec`。
  因为换镜像是整体替换地址空间,`process_exec` 入口会先切到内核页目录
  (`CR3 = 0x1000`):0x120000 程序窗口只有在内核页目录下才是内核暂存区。失败时
  旧地址空间还活着,于是从 `TCB_SP_PD` 恢复原 CR3 并把 `-ENOENT` 返回给调用者。
  `posix_fd_reset` 在 `process_exec` 入口就执行,所以**失败的 execve 也会清空
  POSIX fd 表**(见已知限制)。
- FD 继承在 P4 里明确不做:POSIX fd 表是**全局表**(不是每进程),因此 fork
  出的子进程与父进程共享;`execve` 会清空(见已知限制)。

## 测试(P1 + P2 + P3 + P4a + P4b + P4c)

- P1:[`tools/posix/p1_hello.asm`](../../tools/posix/p1_hello.asm) —— 裸汇编 i386 ELF,
  调 `write(1, "hello from int 0x80\n", 20)` 后 `exit(0)`。
- P2:[`tools/posix/p2_file.asm`](../../tools/posix/p2_file.asm) —— `brk` 拿缓冲,
  对 `TEST/P2_DATA.TXT` 做 `open`/`read`/`write`/`lseek`/`close`,打印
  `p2-file: p2 data ok` 和 `p2-file: done`;以及
  [`tools/posix/p2_brk.asm`](../../tools/posix/p2_brk.asm) —— `brk` 申请 3 个新堆页,
  写入并校验 dword 模式,打印 `p2-brk: ok`。
- P3:[`tools/posix/p3_stat.asm`](../../tools/posix/p3_stat.asm) —— 对文件和目录
  各做一次 `stat`(校验 `st_size` 和 `st_mode` 类型位),不存在的文件 → `-ENOENT`;
  `open`+`fstat` 普通文件与控制台,以及 `ioctl(TCGETS)` 对控制台返回 0、对文件
  fd 返回 `-ENOTTY`;打印 `p3-stat: ok`。
  [`tools/posix/p3_dents.asm`](../../tools/posix/p3_dents.asm) —— 打开 `TEST/` 目录 fd,
  校验 `read` → `-EISDIR`、带写标志 `open` → `-EISDIR`,循环 `getdents64` 遍历
  `TEST/`,要求条目数 ≥ 3 且包含 `P2_DATA.TXT`;打印 `p3-dents: ok`。
  [`tools/posix/p3_time.asm`](../../tools/posix/p3_time.asm) —— `time(0)` > 0、
  `time(&t)` 一致且忙等后单调不减、`gettimeofday` 返回合理的 `{sec, usec}`;
  打印 `p3-time: ok`。
- P4a:[`tools/posix/p4_fork.asm`](../../tools/posix/p4_fork.asm) —— `getpid`、`fork`
  和 `wait4`:子进程打印 `p4-fork: child` 后 `exit(42)`,父进程 `wait4` 等它、
  校验退出状态后打印 `p4-fork: ok`;同时校验 `getpid` 在 fork/wait 前后没变。
- P4b:[`tools/posix/p4_kill.asm`](../../tools/posix/p4_kill.asm) —— fork 一个死循环
  子进程,然后 kill 它:探测(`sig 0`)、`SIGSTOP` + `wait4(WUNTRACED)` 拿到
  `0x7F` 停住状态、`SIGCONT`、`SIGINT`(接受但不杀)、非法信号 → `-EINVAL`、
  不存在的 pid → `-ESRCH`、不支持的 pid 形式 → `-ENOSYS`,最后 `SIGTERM` +
  `wait4` 看到退出码 137;打印 `p4-kill: ok`。
- 用 `nasm -f elf32` + `ld -m elf_i386 -static -n -Ttext=0x120000` 构建
  (`-Ttext=0x120000`:内核 ELF 装载器把程序展开到 0x120000 程序窗口;
  `-n` 防止链接器在基址以下额外生成一个 `PT_LOAD` 段)。
- P4c:[`tools/posix/p4_exec.asm`](../../tools/posix/p4_exec.asm) —— 对不存在的路径
  `execve` 返回 `-ENOENT`(旧程序继续跑),再对 `TEST/P1_HELLO.ELF` `execve`,
  当前镜像被 hello 程序替换(打印 `hello from int 0x80` 后正常退出回 shell);
  打印 `p4-exec: enoent ok`。
- `make test-posix` 启动硬盘镜像,依次跑 P1–P4c 程序,断言:输出字符串出现、
  每个程序后回到 shell、页池不泄漏。


## 路线图

| 阶段 | 内容 | 状态 |
|---|---|---|
| P1 | `exit` / `read` / `write` | 完成 |
| P2 | `open` / `close` / `lseek` / 文件读写、`brk` | 完成 |
| P3 | `stat` / `fstat` / `getdents64` / `ioctl` / `time` / `gettimeofday` | 完成 |
| P4 | `fork` / `execve` / `wait4` / `getpid` / `kill` | 完成:P4a(fork/getpid/wait4)、P4b(kill)、P4c(execve) |
| P5 | static i386 busybox applet 子集 | 计划(先评估) |

## 已知限制(P1 + P2 + P3 + P4a + P4b + P4c)

- fd 0 的 `read` 一次只读一个字节;没有行规程/termios。
- fd 表是全局的(不是每进程):fork 出的子进程与父进程共享 fd;`execve` 会清空 fd 表(P4 明确不做 fd 继承)。
- `open` 不创建/不截断文件(`O_CREAT` 等 → `-ENOSYS`);`write` 是整文件覆盖,
  不是原地更新。
- 文件大小上限 8 KiB(单个 scratch 缓冲)。
- 文件路径从 FAT 根目录解析,没有每进程 cwd。
- `brk` 只能在进程预先算好的堆窗口内增长。
- `getdents64` 只返回 FAT **8.3 短名**(长文件名以短别名出现),且跳过 `.`/`..`;
  还没有长名目录遍历。
- `stat` 是合成元信息:uid/gid 都是 0、没有真实权限位(文件 0644、目录 0755),
  时间戳都取当前时间。
- `time`/`gettimeofday` 把 CMOS 本地时间当 UTC;没有时区,也没有亚秒级 RTC 精度
  (usec 来自 PIT tick)。
- 目录只能只读打开;`open` 除访问模式外不支持其它 flag(没有 `O_DIRECTORY`、
  `O_NONBLOCK` 等)。
- `kill` 只支持 `pid > 0` 和上面五种信号;进程组(`pid <= 0`)、`sigaction`/
  信号处理函数、实时信号都还没有实现。
