[English](../hacking.md)

# 参与开发（怎么改）

> 原为 README §8。



改完 `make` 一下,`./tools/run.sh --hd` 就能看到效果。

## 8.1 加一个自己的程序(最推荐)

```bash
cp progs/HELLO.asm progs/MYPROG.asm     # 改吧
make                                    # Makefile 会自动编 progs/*.asm
python3 tools/mkfat.py build/kkernel-hd.img 6144 8 MYPROG.BIN=build/MYPROG.BIN
make hd                                 # 或者在 Makefile 的 PROGS 里加一行,让 make hd 自动带上
> run MYPROG
```

接口、约定、例子都在 **[docs/programs.md](../programs.md)**。

## 8.2 写个全屏程序(计算器/编辑器就是这么来的)

想要"自己清屏、自己排版"的程序,用第 6/9/10/11/12/13 号功能:
清屏、定位、读键事件(方向键)、问屏幕尺寸、取参数、在指定位置画字。
`progs/CALC.asm`(300 行)和 `progs/EDIT.asm`(400 行)就是照这个套路写的,
三条踩过的经验写在 [docs/programs.md 第 6 节](../programs.md)。

## 8.3 改开机那句话

`kernel/kmain.asm` 最下面的数据区,`msg_title` 就是第一行:

```asm
msg_title   db 'KKernel - stage 5', 10, 0     ; 10 = 换行,0 = 字符串结束
```

中文也直接写(字符串是 UTF-8,图形模式下能显示;文本模式会成乱码,见 6.8)。

## 8.4 加一条 shell 命令

三处,都在 `kernel/shell.asm`:

```asm
; 1) 写处理函数(想打印就用 term_print,想读参数用 [cmd_arg])
cmd_hi:
    mov esi, msg_hi
    call term_print
    ret

msg_hi db 'hi there', 10, 0                 ; 2) 加字符串

; 3) 在命令表里登记(名字 + 处理函数)
n_hi db 'hi', 0
cmd_table:
    dd n_hi, cmd_hi
    ...
```

命令名匹配是**整词**比较(`str_eq`),所以 `page` 不会被 `pa` 之类误命中。

## 8.5 往镜像里放个文件

```bash
python3 tools/mkfat.py build/kkernel-hd.img 6144 8 \
    DOCS/NOTES.TXT=my-notes.txt BIN/HELLO.BIN=build/HELLO.BIN
make hd
> cat DOCS/NOTES.TXT
```

参数含义、为什么是 6144、每簇几个扇区怎么选的,见
[docs/filesystem.md 第 6 节](../filesystem.md)。

## 8.6 改分页怎么映射

`kernel/paging.asm` 顶部那两张页表是**开机固定**的;恒等映射 0~ident(最多 256 MiB),
4 MiB 以上的页表页运行时从页池拿:

```asm
PD_ADDR     equ 0x1000     ; 页目录
PT_LOW      equ 0x2000     ; 恒等 0-4 MiB
PT_LFB      equ 0x4000     ; VBE 帧缓冲窗口
; 4 MiB 以上的恒等页表:没有固定地址,运行时 pmem_alloc 一页一页拿
```

想玩"虚拟地址 ≠ 物理地址"不用改代码,shell 里现成有:

```
> debug pmap 0x8000000     ← 从页池拿一页(4 MiB 以上),现建页表映到 128 MiB 那个虚拟地址
> debug page 0x8000000     ← 看 PDE/PTE:虚拟 0x08000000、物理 0x00400000
> debug pumap 0x8000000    ← 解映射并把页还回去
> debug ptest        ← 一个命令跑完整个流程(分配→建表→读写→归还),还会检查页池有没有泄漏
```

要加一个"固定的自定义映射",在 `paging_init` 末尾照 LFB 那段写就行;
`paging_map(va, pa, flags)` 和 `paging_unmap(va)` 是内核里的动态接口
(`kernel/paging.asm`,页表不够会自己找 `pmem_alloc` 要页)。想让它"映了但不许写",
把 flags 里的 `PAGE_RW` 去掉,写它就会吃 13 号通用保护异常。

想改"程序能用多大内存"看 `paging.asm` 顶部的 `SPACE_IMG_PAGES` / `SPACE_HEAP_PAGES`
—— 镜像窗口是常量 96 页,堆窗口页数是运行时变量 `space_heap_pages`(参数页/栈顶
`space_args_va`/`space_stack_va`/`space_user_stack_top` 也是运行时算的),建空间时一页都不给,
是程序碰到才补。想知道它是怎么补的,从 `page_fault_try_handle` 看起;
想关掉按需分页回到"一次给满",在 `space_create` 里把清页表那几行换成
`paging_map` 逐页映上去就行(老版本就是这么写的,git 历史里能翻到)。
`cmd_run` 里那几步一眼能认出来:建空间 → 写镜像大小 → 切 CR3 跑 → `space_destroy` 归还。

## 8.7 让 panic 屏显示更多

`kernel/idt.asm` 里 `isr_common` 就是那个"红屏 + 停机"。异常帧里的东西都在栈上:

```
[ebp+32]=向量号  [ebp+36]=错误码  [ebp+40]=EIP  [ebp+44]=CS  [ebp+48]=EFLAGS
```

想再打 `CR3`、`DS`、或者页表项,照着 `mov eax, cr2 / call term_print_hex` 那样加一行就行。

## 8.8 用 C 写程序

`make cc-check` 看看工具链在不在,然后往 `progs/` 里丢一个 `.c`,把名字加进
`Makefile` 的 `C_PROGS`,再 `make hd`。接口、内存布局、迷你 libc 有什么没有什么,
都在 [docs/c-programs.md](../c-programs.md);`progs/CHELLO.c` 是现成例子。

## 8.9 想看汇编到底编成了什么

```bash
make lst        # 生成 build/boot.lst 和 build/kernel.lst(带机器码的反汇编)
qemu ... -s -S  # 配合 gdb:target remote :1234(或 ./tools/run.sh --gdb)
```

## 8.10 推送到 GitHub(国内网络时通时不通)

手动 `git push` 碰上 GitHub 抽风就得干等。用现成的脚本:

```bash
tools/onekey_push.sh --dry-run                       # 先看看要推什么
GH_TOKEN=ghp_xxx tools/onekey_push.sh                # 带上 PAT 推(失败自动重试)
tools/onekey_push.sh                                 # 配过 credential.helper / SSH 时直接推
tools/onekey_push.sh --branch dev --retry 8 --sleep 15
```

token 只从环境变量 `GH_TOKEN` 读,**不写进 config、不落盘**。想长期免输入可以
`git config --global credential.helper store`(明文存 `~/.git-credentials`),
或者干脆每次拷进环境变量。
