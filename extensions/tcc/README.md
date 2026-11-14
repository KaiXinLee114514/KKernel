# TCC 移植版（KKernel 系统内 C 编译器）

Tiny C Compiler 0.9.28rc (<https://github.com/TinyCC/tinycc>) 的 KKernel 移植。

## 当前状态

- ✅ `run TCC.BIN -c t1.c -o t1.o` 能编译出**合法的 i386 ELF 目标文件**
  （已在镜像里验证：T1.O 864 字节，readelf 确认 ELF32 REL Intel i386）
- ✅ **能链接并运行**：内核已加 ELF loader（`kernel/elf.asm`），FAT16 里预置了
  `CRT_TCC.O`（TCC 专用最小 crt）和 `MINIC.O`（KKernel libc）。系统内可以：
  ```
  > run tcc.bin -c hello.c -o hello.o
  > run tcc.bin -static -nostdlib hello.o crt_tcc.o minic.o -o hello.elf
  > run hello.elf
  hello from TCC ELF! ...
  ```
  注意 **必须加 `-static`**（默认动态链接会带 `PT_INTERP /lib/ld-tcc.so.1`，
  KKernel 没有动态链接器）；`-nostdlib` 是因为系统里没有 libc.a/libtcc1.a。
- ✅ **支持 `#include <...>`**：镜像里新增 `/INCLUDE` 目录（由仓库 `tccinc/` 的 18 个头文件生成），
  `#include <stdio.h>` / `<stdlib.h>` / `<string.h>` / `<ctype.h>` / `<stdint.h>` / `<limits.h>` /
  `<errno.h>` / `<time.h>` / `<unistd.h>` 以及 TCC 自带的 `stdarg.h`/`stddef.h`/`stdbool.h` 等都能用。
  TCC 对系统头按 `sysinclude_path + "/" + name` 拼路径（`CONFIG_TCC_SYSINCLUDEPATHS "/include"`），
  内核的 `fat_path` 已支持跳过开头的 `/` 当相对根目录解析 —— 所以 **TCC 源码一行没改**。
  ```
  > run TCC.BIN -c src/tcc_inc.c -o tcc_inc.o
  > run TCC.BIN -static -nostdlib tcc_inc.o lib/crt_tcc.o lib/minic.o -o tcc_inc.elf
  > run tcc_inc.elf
  TCC #include: include works
  sizeof(size_t)=4
  ```
  示例源码在 `progs/TCC_INC.C`（镜像里是 `/SRC/TCC_INC.C`）。
  注意 TCC 按**后缀**认文件类型：命令行里用小写 `.c` / `.o`（FAT 查名字大小写不敏感，
  但 TCC 拿到的是你敲的那个字符串）。
- 限制：暂不支持动态链接、`-run`、自定义链接脚本；系统头是最小集（实现以 `lib/minic.c` 为准）。

## 构建

需要宿主机 gcc-multilib（`sudo apt install gcc-multilib`）：

```
make build/TCC.BIN   # 从本目录源码编译 TCC（用宿主机 gcc -m32）
make hd              # 重建硬盘镜像（TCC.BIN + T1.C 进 FAT16）
```

镜像里直接跑：

```
> run tcc.bin -c t1.c -o t1.o
> ls          # 能看到 T1.O
```

带系统头编译（`/INCLUDE` 由 `make` 从仓库 `tccinc/` 生成进镜像）：

```
> run tcc.bin -c src/tcc_inc.c -o tcc_inc.o
> run tcc.bin -static -nostdlib tcc_inc.o lib/crt_tcc.o lib/minic.o -o tcc_inc.elf
> run tcc_inc.elf
```

## 目录

| 路径 | 内容 |
|------|------|
| `src/` | TCC 源码（0.9.28rc，含移植改动） |
| `kkinc/` | 编译 TCC 时用的 libc 头文件（assert/fcntl/setjmp/math/signal/glob/sys/*、stdint/inttypes） |
| `src/config.h` | 手写：i386/ELF/Linux 目标、静态、关 semlock/bcheck/backtrace |
| `kkmain.c` | wrapper：KKernel crt0 不传 argc/argv，这里从 int 0x30 12 号 (`j_arg()`) 构造出 argv 再调 `tcc_real_main()` |
| `src/tccdefs_.h` | 由 `conftest` 的 `c2str` 生成（嵌入 TCC 的预定义宏字符串） |

## 移植改动（相对上游）

1. `src/config.h`：全套配置 + `TCC_TARGET_I386`
2. `src/tcc.c`：`main()` 改名 `tcc_real_main()`（wrapper 负责调用）
3. `src/tccpp.c`：`TOKSYM_TAL_SIZE`/`TOKSTR_TAL_SIZE` 256KB → 16KB
   （KKernel 用户堆只有 320KB；池满会链式扩展，小文件不受影响）
4. `kkmain.c`：构造 argv 调用 `tcc_real_main()`
5. 配套的 KKernel libc 修复（`lib/minic.c`）：
   - `fwrite` 先判 stdout/stderr 再查 mode —— gcc builtin 优化会把
     `fputs`/`fprintf` 字面量转成 `fwrite`，否则 TCC 的 stdout/stderr 输出静默
   - `fdopen` 把 fd 映射回 `open()` 创建的 FILE —— 否则 TCC 写 .o 文件失败

## 已知限制 / 下一步

- 系统头是最小集：声明以 `lib/minic.c` 实际实现为准，缺的头文件可以在仓库 `tccinc/` 里补
  （改完 `make` 就会重新生成镜像里的 `/INCLUDE`）
- `libtcc1.a`（TCC 自带运行时库）没有
- 生成的 `.o` 还不能链接成 KKernel 可执行 BIN（需要 linker + ELF loader）
