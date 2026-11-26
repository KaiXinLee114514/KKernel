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

## 测试(P1)

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

## 已知限制(P1)

- `read` 一次只读一个字节且只支持 `fd 0`;没有行规程、没有 termios。
- 还没有 0/1/2 以外的 fd —— 文件系统调用在 P2 到来。
- 程序必须是静态链接的 i386 ELF;没有动态链接器、没有 `mmap`、没有线程。
- 转译层是"并列"于原生 API,而不是叠在它上面;一个程序必须选一种 ABI
  (混用行为未定义)。
