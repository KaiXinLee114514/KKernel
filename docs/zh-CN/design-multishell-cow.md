[English](../design-multishell-cow.md)

# 多 shell 虚拟控制台 + fork/COW

> 设计稿,**还没实现**。基线是 2026-11-14 的工作树:Phase 1「每线程地址空间」
> 已经改完(未提交),4 条 shell 各跑各的程序;但屏幕只有一块,FAT/ATA 还是全局的。
>
> 行号会漂(Phase 1 的改动就挪了不少),找函数名;带「约」的行号只保证写这份稿子时对得上。

现在能做的事:开 4 条 shell、Ctrl+←/→ 换键盘、每条 shell 各跑一个 ring 3 程序。
不能做的事:**同时看见**两个程序的屏幕(后打印的盖掉前面的),以及 `fork`。

这份设计分两个阶段:

| 阶段 | 目标 | 关键改动 |
|---|---|---|
| Phase 2 | 4 块**虚拟控制台**:每条 shell 一块文本缓冲,Ctrl+←/→ 切整屏;两个 shell 可以同时跑程序 | `kernel/cons.asm`(新)、输出路由、切换重绘、每控制台键盘环、文件系统大锁 |
| Phase 3 | `fork` + 写时复制(COW):父程序分叉,子进程写自己的页,父进程数据不变 | 新 API 18/19/20、页表克隆、页池引用计数、COW 缺页、僵尸/等待 |

不在范围里:`fork+exec`、每控制台独立输入法状态、SMP、每控制台滚动历史(只保留一屏)、
把内核改成完全可重入(Phase 2 用一把「文件系统大锁」绕过去,理由见 §3.6)。

---

## 0. 先看结论

- **屏幕不是「再画一遍」,是「每块屏一份 14 800 字节的格子」**。4 块 = 16 页,
  从物理页池拿,恒等映射,直接当指针用。
- 输出路径只有一个真正的岔口:`term_print_cp`(vgafont.asm:147)。它现在在 VBE 下
  直接尾调 `fb_putcp`;Phase 2 改成先写当前 shell 的格子,再决定画不画。
- **切换发生在键盘中断里,只改几个全局变量**:`sh_active`、`sh_switch_flag`、
  `cons_redraw`、`ime_switch`。重绘交给线程(在 shell 线程的 `.mine`,或者一条常驻的
  `cons` 线程),中断里一个 `fb_` 都不碰。
- 文件系统那堆全局缓冲不打算逐个改成可重入;加一把**调度器级的大锁**(`sched_noswitch`):
  持锁期间 IRQ0 照常来,但**不换线程**。比 `cli` 好:键盘不丢、时钟不停。
- fork 的页表克隆只处理 **USER=1 且 present** 的页;内核恒等映射页保持共享、不 COW
  (ring 3 碰不到)。COW 用 PTE 的 **bit 9**(现有代码只用 0/1/2 三位,bit 9 空着)。
- 引用计数用**每页 4 bit** 的 nibble 表,放 `0x3D2000`(位图 0x3D0000-0x3D1FFF 上面,
  和 USB 的 0x3Cxxxx 不冲突;8 页够 64 512 页)。15 次共享上限 = 同一条链最多 15 个进程共享一页,即 fork 深度上限 14 层。

---

## 1. 基线:现在已经有什么

### 1.1 线程(TCB)

`kernel/sched.asm` 当前:`SCHED_MAX = 6`,`TCB_SIZE = 112`,每个线程 2 页(8 KiB)内核栈,
`SLICE_TICKS = 2`(20 ms)。

| 偏移 | 字段 | 说明 |
|---:|---|---|
| 0 | `TCB_ESP` | 切走时保存的 esp,指向栈上的现场 |
| 4 | `TCB_CR3` | 它的页目录(跑程序时是程序自己的) |
| 8 | `TCB_STATE` | 0 空 / 1 活 / 2 死(留) |
| 12 | `TCB_TICKS` | 拿到过多少 tick |
| 16 | `TCB_STACK` | 内核栈物理基址(死了还页池) |
| 20 | `TCB_NAME` | `ps` 显示的名字 |
| 24 | `TCB_RUNS` | 被调度上去过几次 |
| 28 | `TCB_OWNER` | 出生在哪条 shell(现在只用于 display) |
| 32–104 | `TCB_SP_*` | 地址空间:PD/PT/LIVE/PAGES/IMGBYTES/PFRUN/PFIMG/PFHEAP/FIRSTPA/RUNESP/RUNSTAT/FREED/HEAPPAGES/ARGSVA/STACKVA/STACKTOP/RUNNING/STAGE_PA/STAGE_PAGES |
| 108 | `TCB_SP_KILLREQ` | 别的 shell 要求杀掉这条线程上的程序 |

切换的现场格式(和 `irq0_stub` 一致,从低地址到高地址):

```
[pushad 八个寄存器][向量号 0x20][错误码 0][eip][cs][eflags]
```

`sched_pick` 保存 esp/cr3、写 `space_cur`、`mov cr3`、`tss_blk+TSS_ESP0 = [TCB_SP_RUNESP]`。
`irq0_stub`(pit.asm)在 ring 3 现场上检查 `SP_KILLREQ`,有的话直接跳 `run_resume_kernel`
收摊——**这个机制 Phase 3 要复用,但 fork 出来的孩子没有 `cmd_run` 现场,见 §4.7.5**。

### 1.2 shell

`kernel/shell.asm`:`SH_MAX = 4`,`SHELL_LINE_MAX = 128`,`SH_BUF_SZ = 132`,`SH_DIR_SZ = 64`。

- 4 条 shell = 4 条内核线程;0 号是开机线程(用开机栈),1–3 号各 2 页栈。
- `sh_active` 决定键盘归谁;`Ctrl+←/→` 在**键盘中断**里直接调 `shell_switch_step` → `shell_switch_to`
  (约 :286),只搬 `sh_nbuf/sh_nlen/sh_ndir`,置 `sh_switch_flag`,不打印。
- `shell_main`(约 :39)主循环:不是自己就拿 `hlt` 等;轮到自己且 `sh_switch_flag` 时,
  换行 + `--- shell N ---` + 提示符 + 没敲完的半行(`shell_readline_resume`)。
- `cmd_run`(约 :2014)现在每条线程各建各的地址空间:装载锁 `loader_lock`(约 :2382)
  只罩「读文件 → 建 PD/PT → 拷参数」,`iret` 进 ring 3 之前就放掉,所以**程序本身是并行的**。
- `cmd_kill` 对 shell 线程只置 `SP_KILLREQ`(下一次 IRQ0 在它自己的栈上收摊);
  对普通线程 `sched_kill` + 快照 + `space_destroy_at`。

### 1.3 地址空间

`kernel/paging.asm`:
`PD_ADDR = 0x1000`,`PT_LOW = 0x2000`(恒等 0–4 MiB,`P|RW`,**不带 USER**),
`PT_LFB = 0x4000`;`PAGE_P = 1`,`PAGE_RW = 2`,`PAGE_USER = 4`——**只有这三位**。

- `space_create`(约 :346):从页池拿 1 页当 PD、1 页当 PT,分别从 `PD_ADDR`/`PT_LOW`
  整块拷 1024 个 dword;`PD[0] = PT | P|RW|USER`;把 PT 下标 288 起的
  `96 + SP_HEAPPAGES` 项清零(镜像窗口 0x120000–0x17FFFF 共 96 页,堆窗口
  0x180000–0x3AFFFF 共 560 页,128 MiB 时)。
- `page_fault_try_handle`(约 :472):只补「不存在」的页;镜像页从 `[SP_STAGE_PA]`
  按页内偏移拷,堆页清零;装 `PTE = pa | P|RW|USER`,`invlpg`。
- `space_destroy`(约 :621):扫两个窗口里 present 的 PTE,逐页 dec-ref;PT/PD 私有直接还,
  暂存区逐页 dec-ref。
- 用户栈/参数页在堆窗口最后几页(`args=0x3AE000`,`stack=0x3AF000`,`top=0x3AFFFC`),
  弹床在镜像窗口最后一页(0x17F000);两个窗口合起来**覆盖全部用户页**——Phase 3 的
  COW/引用计数可以直接复用这套扫描。

### 1.4 屏幕

`kernel/fbterm.asm` 是 VBE 图形终端,不是文本模式:

- 字符格 **8×16** 像素;ASCII 8 宽,汉字 16 宽;字体在运行时搬到恒等映射顶部。
- 文本网格 = `fb_width >> 3` 列 × `(fb_height & ~15) >> 4` 行。800×600 → **100×37**
  (600 = 37×16 + 8,最下面 8 像素不用;`fb_newline` 夹到 576 = 36×16)。
- 13 页行缓冲(只装当前一行,按脏段 `fb_flush`);26 页悬浮条还原缓冲(`fb_bar_*`)。
- `fb_putcp` 的换行语义:**先画,`fb_cur_x += 宽度`,再判断 `>= fb_width` 才 `fb_newline`**;
  汉字贴最后一列会画出界半格再换行。控制台缓冲要照抄这个顺序,否则重绘会差一格。
- `fb_putcp_at(eax=码位, ebx=行, ecx=列)` 不动光标,正好用来整屏重绘;
  每换一行会 `fb_flush` 一次(37 行 = 37 次)。

### 1.5 终端输出、键盘、文件、管道

- 输出:见 §3.2 的调用图。真正解码 UTF-8 的是 `term_print`(kmain.asm:839),
  解码后调 `term_print_cp`(vgafont.asm:147);**VBE 下 `term_print_cp` 直接尾调
  `fb_putcp`,绕过 `term_putc`**。`term_puts_at`(kmain.asm:771)只给输入法悬浮条用。
- 键盘:`kernel/keyboard.asm` 一个 64 字节环(`kbd_buf`,`KBD_BUF_SIZE=64`),
  IRQ1 里 `kbd_push`,读者 `kbd_getchar`/`kbd_getkey` 空时 `fb_flush; hlt`。
- 文件:`kernel/fat.asm` 用全局 `FAT_BUF = 0x100000` 一个 4 KiB 扇区缓冲、全局
  `[fat_dir]`,外加一堆 `fat_scan_*`/`lfn_*` 临时变量;`kernel/ata.asm` 有
  `ata_lba/ata_buf/ata_src/ata_left/ata_chunk` 全局。**整套不可重入。**
- 管道:`kernel/pipe.asm` 全局 `pipe_capture_on/pipe_out_buf/...`,头注释明说
  「一次只让一个 ring 3 程序跑,所以不需要等待队列」——Phase 2 之后这句话不成立。
- `int 0x30` 是 **DPL=3 的 32 位中断门(0xEE)**,进门 `IF=0`:系统调用**整段不可被抢占**。
  这是好事(API 里的 `fat_*` 天然原子),也是坏事(里面不能 `hlt` 等锁)。

### 1.6 现状里挡路的几个点

| # | 问题 | 位置 | 影响 |
|---:|---|---|---|
| 1 | 屏幕是全局唯一 | `fb_*` 全局光标/行缓冲 | 后打印的覆盖前面的 |
| 2 | `fat_dir` 全局 | fat.asm | 两条 shell 同时 `cd`/读文件会串目录 |
| 3 | `kbd_buf` 全局 | keyboard.asm | 后台程序会偷活动 shell 的键 |
| 4 | 管道捕获全局 | pipe.asm | 两条管道链同时跑会串缓冲 |
| 5 | `kbd_getchar` 的 `hlt` 没开中断 | keyboard.asm:519 | 在 `IF=0` 的 API 里会睡死(见 P0.1) |
| 6 | 没有 `CR0.WP` | paging.asm `paging_init` | Phase 3 COW 的内核写不会触发缺页 |

---

## 2. 前置收尾(P0,不做完别开 Phase 2)

- [ ] **P0.1 修键盘等待的 `hlt`**:`kbd_getkey`/`kbd_getchar` 的 `.wait` 现在直接 `hlt`。
  API 门进来 `IF=0`,`hlt` 等不到可屏蔽中断。改成:

  ```asm
  .wait:
      call fb_flush
      pushfd
      sti
      hlt
      popfd          ; 回到调用者原来的 IF(shell=1,API=0)
      jmp .loop
  ```

  这不只是 Phase 2 的铺垫——现在「程序里按任意键继续」在真机上就是死机,
  QEMU 里靠中断pending 侥幸能醒,别赌。
- [ ] **P0.2 清掉「一次只让一个程序跑」的残留**:README 第 83/533 行、`known-issues.md`
  里相关段落、测试里 `another shell is running a program` 的断言。Phase 1 已经能并行跑,
  Phase 2 只是把屏幕也分开。
- [ ] **P0.3 `cmd_run` 的注释/文档同步**:`cmd_run` 已经按线程暂存镜像、`loader_lock`
  只罩装载;README 的程序章节还按单程序写。
- [ ] **P0.4 决定显示线程的槽位**:Phase 2 要加一条常驻 `cons` 线程(`SCHED_MAX 6 → 8`),
  `ps`/测试的「4 alive / 6 slots」要跟着改。
- [ ] **P0.5 Phase 3 再动 `CR0.WP`**(`paging_init` 里 `or eax, 0x80000000` 改成
  `or eax, 0x00010000 | 0x80000000`);Phase 2 不需要,别提前改,免得内核写只读页
  触发一堆莫名其妙的 14 号。

---

## 3. Phase 2:每 shell 一块虚拟控制台

### 3.1 缓冲:算尺寸、放哪、长什么样

#### 3.1.1 尺寸

| 项 | 计算 | 值 |
|---|---|---:|
| 列数 | `fb_width >> 3` | 100 |
| 行数 | `(fb_height & ~15) >> 4` | 37 |
| 格子数 | 100 × 37 | 3 700 |
| 每格 | 4 字节(见下) | 4 B |
| 每块 | 3 700 × 4 | **14 800 B** |
| 每块占页 | `(14800+4095)>>12` | **4 页**(16 384 B,尾巴浪费 1 584 B) |
| 4 块 | 4 × 4 | **16 页**(65 536 B) |

作为对比:整屏像素是 800×600×4 = **1.92 MB**,4 块根本放不下;文本格是 1/130 的量级。
这就是为什么「虚拟控制台」存的是**字符格**,不是像素。

#### 3.1.2 格子格式

```text
 31      24 23 22 21 20                    0
+----------+--+--+--+-----------------------+
|   attr   |W |T |保留|       码位 cp        |
+----------+--+--+--+-----------------------+
```

| 位 | 名字 | 含义 |
|---|---|---|
| 0–20 | `cp` | Unicode 码位(0x10FFFF 只要 21 位) |
| 21 | 保留 | 留给「下划线/反显」之类,先 0 |
| 22 | `CELL_TAIL` | 1 = 这是汉字的第二格,重绘时跳过 |
| 23 | `CELL_WIDE` | 1 = 汉字头格(宽 16 像素 = 2 格) |
| 24–31 | `attr` | 和 `term_color` 同格式(`0x0F` 白字黑底) |

- 不用「UTF-8 字节流」:光标定位、退格、重绘都要随机访问,变长编码会逼着每次从头解码。
- `attr` 直接用 `term_color`,重绘时 `fb_color_of(attr)` 就是 `term_fb_color`,不用再发明一套调色板。
- 空白格统一是 `0x07000020`(空格 + 0x07)。`cons_init` 时整块 `rep stosd` 填好。

#### 3.1.3 从哪来

在 `kmain.asm` 的 `paging_init`(约 :265)之后、`sched_init`(约 :363)之前插入:

```asm
    call cons_init          ; 4 × pmem_alloc_pages(4);任一失败 → 全退 + cons_ok=0
```

此时页池(`pmem_init`,:165)和恒等映射(`paging_init`)都好了,`term_init`(:177)也好了,
可以直接打一行:

```text
cons: 4 consoles x 100x37 (14800 B each, 16 pages)
```

分配到的物理地址就是虚拟地址(恒等映射),不用再建页表。`pmem_alloc_pages` 保证
**4 页连续**;起点只保证 4 KiB 页对齐(不保证 16 KiB 对齐),但 14 800 B 一定落在
这 4 页里,`rep stosd` 不会踩到别人。
128 MiB 的默认配置页池 30 207 页,16 页是 0.05%,可以忽略;`-m 8` 没有页池时
`pmem_alloc_pages` 返回 0,`cons_ok=0`,退回「一块屏 + 只换键盘」的老行为(见 §3.1.5)。

#### 3.1.4 控制台表

`kernel/cons.asm`(新文件)里的 BSS:

```asm
cons_buf      dd 4 dup(0)        ; 每块 4 页的基址(物理=虚拟)
cons_cx       dd 4 dup(0)        ; 光标列(格)
cons_cy       dd 4 dup(0)        ; 光标行
cons_attr     dd 4 dup(07h)      ; 当前颜色(attr 字节)
cons_seq      dd 4 dup(0)        ; 写一次 +1,重绘用来发现「画的时候又有人写」
cons_redraw   dd 0               ; 要重绘的控制台号 + 1;0 = 不用重绘
cons_pages    dd 0               ; 实际占了几页(给 layout/测试)
cons_ok       db 0               ; 0 = 没有控制台,全走老路
cons_cols     dd 0
cons_rows     dd 0
```

TCB 里加两个字段(Phase 2):

| 偏移 | 字段 | 说明 |
|---:|---|---|
| 112 | `TCB_CONS` | 这条线程的输出/键盘属于哪块控制台(0–3) |
| 116 | `TCB_CWD` | 切走瞬间的 `fat_dir` 快照(名字叫 CWD,实际存的是原始簇号,见 §3.6.3) |

`TCB_SIZE` 112 → **120**,`SCHED_MAX` 6 → **8**(4 条 shell + 1 条 `cons` 线程 + 3 个空位)。
`sched_init` 把 0 号的 `TCB_CONS=0`;`shell_spawn_extra` 起 1–3 号时把 `TCB_CONS` 设成 `ebp`;
`sched_spawn` 默认 0(cons 线程算 0 号屏的)。槽位约定:**0–3 = shell,4 = cons,
5 起 = fork/演示线程**(Phase 2 到 7,Phase 3 到 11)。`cmd_kill` 要拒掉 `tid == 4`(cons 线程不能杀);0–3 只给它跑的程序打 `KILLREQ`,5 起才走「连线程带地址空间」的路径。**`sched_spawn` 还必须把 `TCB_CWD`
初始化成当时的 `[fat_dir]`**,不能留 0——否则在子目录里起的线程第一次被调度就被
拉回根目录。`cmd_spawn`(演示线程)要显式把 `TCB_CONS` 设成 `[space_cur+TCB_CONS]`,
别让后台 shell 起的线程把字画到 0 号屏。

> 为什么正好 4 块:和 `SH_MAX=4` 对齐。要加 shell 就得同时加 4 页,先别贪。

#### 3.1.5 失败路径

- `cons_init` 四次 `pmem_alloc_pages(4)` **全有或全无**:任何一次失败,把已经拿到的
  页还回池、`cons_ok=0`、**不启动 `cons` 线程**,`term_*` 全走原来的直画。
  Ctrl+←/→ 仍然只换键盘,屏幕保持旧行为。`layout` 行里 `cons=0`,测试据此跳过
  控制台断言。
- 不做「只拿到 1–3 块」的半吊子状态:4 条 shell 共享同一套屏幕语义,少一块就会
  出现「这条虚拟、那条直画」的怪事,不如整体退回老路。

### 3.2 输出路由:从 `term_print_cp` 岔出去

先看现在的调用图(只列会写屏幕的):

```text
term_print(kmain:839) ──UTF-8 解码──> term_print_cp(vgafont:147)
                                        ├─ 控制字符(<0x20) → term_putc(kmain:567)
                                        └─ VBE 可打印 ─────> fb_putcp(fbterm:444) ─> fb_blit
term_putc ─────────────────────────────────────────────────> fb_putc(fbterm:404) ─> fb_putcp
term_puts_at(kmain:771) ───────────────────────────────────> fb_putcp_at(fbterm:486)  [IME 条]
程序 API 3 ────────────────────────────────────────────────> term_print_cp
程序 API 6 clear ──────────────────────────────────────────> term_clear → fb_clear
程序 API 9 set_cursor ─────────────────────────────────────> term_set_cursor
```

关键事实:**VBE 下可打印字符根本不经过 `term_putc`**——`term_print_cp` 直接尾调
`fb_putcp`。所以只挂 `term_putc` 会漏掉所有正常文字(这个坑很隐蔽:中文能捕到才怪)。

#### 3.2.1 挂哪几个点

| 函数 | 现在 | Phase 2 改成 |
|---|---|---|
| `term_print_cp`(vgafont:147) | `jne fb_putcp` | `jne cons_putcp`(cons 内部再决定画不画) |
| `term_putc`(kmain:567) | 控制字符 → `fb_putc` | 先 `call cons_putc_byte`,再按活动控制台决定 `fb_putc` |
| `term_clear`(kmain 里 `fb_clear` 的包装) | 整屏黑 | `call cons_clear`(清当前缓冲 + 光标);活动且 `!cons_repaint_busy` 才 `fb_clear` |
| `term_set_cursor`(kmain:719) | 改 `fb_cur_*` | 存 `cons_cx/cy`,活动才改 `fb_cur_*` |
| `term_set_color`(kmain:558) | 改 `term_color/term_fb_color` | 再存 `cons_attr[cur]` |
| `term_puts_at`(kmain:771) | 直写像素 | **不捕获**;只允许活动控制台画(后台程序调用直接丢,见 §3.4) |
| `term_print` 的管道捕获 | `pipe_capture_on` 时提前返回 | 增加 `pipe_owner == 当前控制台` 判断(§3.6) |

`term_putc` 的细节:它现在处理 `\n\r\b`,然后 `fb_putc`。改成:

```asm
term_putc:
    ; ... 原有 pipe_capture 判断(捕获时直接 return,不进控制台) ...
    cmp byte [cons_ok], 0
    je .old
    mov edx, [space_cur]
    test edx, edx
    jz .old                    ; 启动早期(sched_init 之前)没有 TCB
    call cons_putc_byte        ; 写缓冲/光标;eax=1 表示"连画都替你做完了"
    test eax, eax
    jnz .done
    mov eax, [edx + TCB_CONS]
    cmp eax, [sh_active]
    jne .done                  ; 后台:缓冲写完就完事
    cmp byte [cons_repaint_busy], 0
    jne .done                  ; 正在整屏重绘:别插队,seq 复查会把它补上
.old:
    jmp fb_putc                ; 原来那条路(活动控制台/无 cons)
.done:
    ret
```

`cons_putc_byte` 处理三类:

- `8/10/13`:**全部自己处理屏幕并返回 `eax=1`**。退格 `fb_cur_x = cx*8` 后画空格
  (否则 `fb_putc(8)` 只退 8 像素,汉字会退成半格);回车只 `fb_cur_x=0`;
  换行先改缓冲;只有**活动控制台且 `cons_repaint_busy==0`** 时才 `fb_putc(10)`
  (由它 `fb_newline`/滚屏)。返回 1 是
  为了不让尾部再画一遍——`\n` 若返回 0 会变成双换行。
- 可打印 ASCII:只把字节记进缓冲、推进 `cons_cx/cy`(越界只滚缓冲),返回 0,
  由尾部 `fb_putc` 画一次。**不要在这里 `fb_newline`**,屏幕换行/滚屏由
  `fb_putc`/`fb_putcp` 自己做,否则双换行。
- 其它控制字节:忽略。

`term_print_cp` 那条路已经由 `cons_putcp` 处理,不会重复(因为 VBE 下可打印字符
不经过 `term_putc`)。

#### 3.2.2 `cons_putcp` 做什么

```text
cons_putcp(eax=码位)
  1. id = [space_cur+TCB_CONS];若 cons_ok=0 / space_cur=0 → jmp fb_putcp(老路)
  2. 宽度 = fb_glyph(cp) 的宽度 >> 3(1 或 2;缺字按 1)
  3. 若 宽=2 且 列=cols-1:先 `cons_newline`;活动控制台还要先 `fb_newline`
     (避免汉字画到帧缓冲外,见下)
  4. 清掉目标格上可能压着的半个汉字(头/尾),写头格;宽 2 再写尾格(CELL_TAIL)
  5. 列 += 宽;若 列 >= cols → cons_newline(只滚缓冲、光标归零;
     屏幕的换行/滚屏由第 6 步的 fb_putcp 自己完成,这里再 fb_newline 会双换行)
  6. 若 id == [sh_active] 且 [cons_repaint_busy]==0:
       term_fb_color = fb_color_of([cons_attr+id*4])
       fb_putcp(cp)            ; 由它推进 fb_cur_x/y、必要时 fb_newline
  7. ret
```

几个必须写进代码的细节:

1. **先画后判越界**:`fb_putcp` 是「画完再 `add fb_cur_x, width`,再判断 `>= fb_width`」。
   缓冲也照这个顺序,否则重绘时光标会差一格。但**宽 2 且贴最后一列**时,`fb_blit`
   会写 16 像素、越过 800 宽冲进下一行——现在就有这个隐患,控制台缓冲顺手修掉:
   在写之前 `if (col + w > cols) cons_newline()`。代价是「最后一个汉字提前换行」,
   肉眼几乎看不出来。
2. **覆盖半个汉字**:如果目标格是 `CELL_TAIL`,先把它的头格抹成空格;如果目标格是
   `CELL_WIDE`,把它的尾格也抹掉。否则会出现「半个字 + 新字」的残影。
3. **退格**:`cx>0` 时 `cx--`;若落在 `CELL_TAIL`,再 `cx--` 并把两格都抹掉。
   `fb_putc(8)` 只退 8 像素(半个汉字),所以活动控制台的退格由 `cons_putc_byte`
   直接改 `fb_cur_x = cx*8`、画空格,不走 `fb_putc`。
4. **`\r` / `\n`**:`\r` 只归零;`\n` 走 `cons_newline`:行号 +1,到底了就把
   `(rows-1)*cols*4` 字节整体前移(14.8 KiB 的 `rep movsd`),最后一行填空格。
   活动控制台同时让 `fb_putc(10)` 走 `fb_newline`(它会自己滚 VBE)。
5. **清屏**:`cons_clear` 把当前块填 `0x07000020`、`cx=cy=0`;活动时才 `fb_clear`。

#### 3.2.3 每控制台的颜色和光标

- `term_set_color` 除了写全局 `term_color/term_fb_color`,还要写
  `cons_attr[[space_cur+TCB_CONS]]`。后台程序改色只改自己那块,不污染前台。
- **画之前**从 `cons_attr` 重算 `term_fb_color`(而不是信任全局值),否则后台程序
  一次 `set_color` 会让前台下一个字用错颜色。`cons_putc_byte` 画可打印 ASCII 之前
  也要重算一次(它后面直接尾调 `fb_putc`)。
- 所有钩子先判 `space_cur != 0`:启动早期(`cons_init` 之后、`sched_init` 之前)
  BSS 里还是 0,直接 `[space_cur+TCB_CONS]` 会读到低地址;这时只改全局、走老路。
- 切换控制台时:保存 `cons_cx/cy`(本来就在写),恢复时
  `fb_cur_x = cx*8`,`fb_cur_y = cy*16`;`term_color = cons_attr`。
- `term_set_cursor`(API 9)只改**本控制台**的 `cons_cx/cy`;不是活动控制台就到此为止,
  是的话再改 `fb_cur_*`。

#### 3.2.4 管道

管道捕获的输出**不应该**进控制台缓冲:它本来就不画屏。现有 `term_putc`/`term_print`
一开头就判断 `pipe_capture_on` 并 `return`,所以只要把 `cons_*` 钩子放在这个判断
**之后**,管道就自动不受影响。需要补的是「哪条控制台的管道」:

```asm
pipe_capture_on   dd 0
pipe_owner        dd 0      ; 新增:控制台号
```

`term_putc`/`term_print` 的捕获判断改成 `cmp [pipe_capture_on],0; je .normal` 之后,
再 `cmp [pipe_owner],[cons]`;不等就不捕、也不画(理论上不会发生,因为管道链是串行的,
见 §3.6)。

#### 3.2.5 谁在画:一次只能有一个画手

现有 `fb_*` 全是全局状态(`fb_cur_*`、行缓冲 `fb_lb_row`、脏段)。Phase 2 的规则:

- **只有 `[sh_active]` 控制台的输出才画屏**;后台只写缓冲。
- 前台输出用 `pushf; cli` 包住一次「查 `id == sh_active` + `fb_putcp` + 可能的一次
  `fb_newline`」,大约几十微秒,结尾 `popf`;检查必须和画在同一个关中断段里,否则
  「刚查完还是前台、马上被切走」会让老线程往新屏上补一个字。
- **不要裸 `sti`**:打印可能发生在 `int 0x30` 里(API 3,IF=0),裸开中断会在系统
  调用中途放进定时器。所有「临时关中断」统一写成 `pushf; cli; ...; popf`。
- 重绘线程按**行**关中断(一行最多 100 个字,约 0.3 ms),行与行之间允许被抢占;
  `cons_repaint_busy` 期间前台输出只写缓冲、不画屏,靠 `cons_seq` 的复查在第二遍补上。
- 不用自旋锁:单 CPU 上自旋等锁会把持锁者永远挡住。用 `pushf/cli` 短临界区 +
  「后台不画」已经足够;长活(FAT/ATA)则用 §3.6 的 `sched_noswitch`。

#### 3.2.6 成本

- 单字:一次 `fb_glyph` 二分 + `fb_blit` 128 个 dword(8 宽)或 256 个(16 宽)。
- 换行:一次 `fb_flush`,一行的脏段最多 800×16×4 = 51 KB。
- 满屏重绘:约 3 700 字、37 次 flush、最多 1.9 MB MMIO。QEMU 里量级是几十毫秒,
  真机更快;这个数决定 §3.3 允不允许在中断里干(结论:不)。

### 3.3 切换:中断里只立旗,重绘交给线程

`shell_switch_to`(shell.asm 约 :286)已经在中断上下文里做了三件事:备份/装回行缓冲和 cwd、
改 `sh_active`、置 `sh_switch_flag`。Phase 2 只加**两行**:

```asm
    mov eax, [sh_target]
    inc eax
    mov [cons_redraw], eax      ; 目标控制台号 + 1(0 表示没有)
    mov byte [ime_switch], 1    ; 输入法:切走就放弃这次组合
```

**不调任何 `fb_`**,不 `call term_print`,不 `hlt`。中断里唯一多出来的开销是两次内存写。

#### 3.3.1 谁来消费 `cons_redraw`

两条路,谁先跑到谁画;用 `cons_repaint_busy` 防止两个人同时画:

1. **shell 线程的 `.mine`**(shell_main 约 :39):在打 `--- shell N ---` 之前
   `call cons_service`。这样切回一条停在提示符的 shell 时,先看到它原来的屏幕,
   再看到分隔行。
2. **常驻 `cons` 线程**:专治「切到一条正在 ring 3 里跑程序的 shell」——那条线程
   不会回到 `.mine`,只有别人能替它重绘。

```asm
; kernel/cons.asm
kthread_cons:
    cmp dword [cons_redraw], 0
    je .sleep
    call cons_service
.sleep:
    hlt
    jmp kthread_cons
```

启动顺序:`shell_spawn_extra` 之后、`sched_enable` 之前
`sched_spawn(kthread_cons, nm_cons)`。但**别依赖「第一个空槽」**:如果某条 shell
因页池不足没起来,`cons` 会落到 3 号,而 `sh_active=3` 指的正是 3 号 TCB——
键盘就进了 `cons`,shell 4 永远收不到键。

所以给 `sched_spawn` 加一个 `ecx = 期望槽号(0 = 任意)`:
`shell_spawn_extra` 传 1/2/3,`cons` 传 **4**,fork 从 **5** 起扫。
槽位因此固定为 0–3 shell、4 cons、5–11 fork/演示线程。失败就少一条线程:停在提示符的 shell 仍能自己重绘,
但「切到正在跑程序的 shell」会保留旧画面,直到程序下一次系统调用/退出——
把这个退化写进 known-issues,别假装没有。

#### 3.3.2 `cons_service`

```asm
cons_service:
    cmp byte [ime_switch], 0     ; 先收输入法:即使这次不用重绘,条子也得收
    je .noime
    mov byte [ime_switch], 0
    cmp dword [fb_bar_active], 0
    je .noime
    call ime_abort
.noime:
    cmp dword [cons_redraw], 0
    je .ret
    mov eax, [cons_redraw]
    dec eax
    cmp eax, [sh_active]
    jne .ret                    ; 已经又切走了:这面旗留给下一次
    mov al, 1
    xchg al, [cons_repaint_busy]  ; 置 1;若原来是 1,写回去还是 1
    test al, al
    jnz .ret                      ; 有人正在画
    cmp dword [fb_bar_active], 0
    je .nobar
    call ime_abort              ; 悬浮条是覆盖层,先收掉(会画两笔,马上被整屏覆盖)
.nobar:
    call cons_repaint
    ; 画的过程中可能又被切走(IRQ 把 cons_redraw 改成别的目标):
    ; 只在旗子还是自己时才清,否则留给下一次
    mov eax, [cons_redraw]
    lea ecx, [sh_active]
    mov ecx, [ecx]
    inc ecx
    cmp eax, ecx
    jne .busy_clear
    mov dword [cons_redraw], 0
.busy_clear:
    mov byte [cons_repaint_busy], 0
.ret:
    ret
```

#### 3.3.3 `cons_repaint`

```text
cons_repaint:
  fb_flush                       ; 行缓冲里可能还有没刷的字
  pushf; cli
  fb_clear                       ; 整屏黑(1.9 MB,一次)
  popf
  seq0 = cons_seq[sh_active]
.again:
  for row = 0 .. rows-1:
      if cons_redraw != sh_active+1: return    ; 开始画这一行前先查
      pushf; cli
      for col = 0 .. cols-1:
          cell = buf[row*cols+col]
          if cell & CELL_TAIL: continue
          if (cell & 0x1FFFFF) == ' ' and attr 背景是黑: continue
          term_fb_color = fb_color_of(attr)
          fb_putcp_at(cp, row, col)
      popf
      if cons_redraw != sh_active+1: return    ; 画完这行再查
  if cons_seq[sh_active] != seq0 and retry < 1:
      seq0 = cons_seq[sh_active]
      retry++
      jmp .again                   ; 画的时候又有人写:再刷一遍
  fb_cur_x = cons_cx*8; fb_cur_y = cons_cy*16
  term_color = cons_attr; term_fb_color = fb_color_of(term_color)
```

- 跳过空格能省掉大半工作量:满屏文字才接近 3 700 个字。
- `fb_clear` 用 `pushf; cli ... popf` 包住(约 1–2 ms),否则清到一半被切走、
  另一块屏重绘完,回来接着清会把人家刚画的全抹掉。
- 每行 `cli` 期间最多 100 个字 + 一次 `fb_flush`,约 0.3 ms;37 行合计 ~10 ms 的
  「关中断时间」,但分散在 37 段里,键盘不会丢(IRQ 控制器至少缓冲一个)。
- **版本检查**:`cons_seq` 每写一格 +1。重绘开始记下 `seq0`,结束时不等就再画一遍
  (最多两遍);还变就把 `cons_redraw` 重新立起来,下一次 tick 再来。这样「重绘过程中
  前台又打印了」不会留下半屏旧字。
- **每行开始和结束都查一次 `cons_redraw == 自己+1`**。画到一半被切走、新控制台已经
  重绘完并把旗清掉,老的重绘必须立刻收手,否则会把新屏盖成花脸。
- `fb_clear` 会 `fb_lb_forget`,所以重绘前先 `fb_flush`;重绘后 `fb_lb_row=-1`,
  下一次正常输出会重新认领行。

#### 3.3.4 为什么不在中断里画

- 满屏 1.9 MB MMIO,中断里干就是几十毫秒的「键盘装死」;VirtualBox 的 MMIO 更慢。
- `fb_*` 全是全局状态,中断里画到一半被嵌套中断/调度打断,行缓冲会串。
- 原设计约束是「中断里只立旗、不在中断里重绘」;这里只是把「shell 线程」扩成
  「shell 线程或专职 cons 线程」,不违背原意。

#### 3.3.5 切换后的光标

`shell_switch_to` 不碰 `fb_cur_*`;等重绘结束,`cons_repaint` 按目标控制台的
`cons_cx/cy` 设 `fb_cur_x/y`。这期间如果有输出落进来(理论上不会,因为源线程还在中断返回路上),
它按旧的 `fb_cur` 画,下一次重绘会纠正。

#### 3.3.6 切回时,半行不能打两遍

`shell_main` 的 `.mine` 在 `sh_switch_flag` 时会把 `shell_buf` 用 `term_print` 重打一遍
(现在屏幕是全局的,只能这么补)。Phase 2 里控制台缓冲已经存着这半行,再打就多一份。

做法:记录「输入起点」和「切走时的光标」,切回先擦掉旧半行,再打标题/提示符/半行:

- `shell_readline` 在画完提示符、开始收键前,把当前 `cons_cx/cy` 存进
  `sh_line_cx[SH_MAX]`/`sh_line_cy[SH_MAX]`(每 shell 一份,普通数组)。
- `shell_switch_to`(IRQ)只多存两个数:`sh_ncx[sh_active]=cons_cx[...]`,
  `sh_ncy[...]=cons_cy[...]`;不打印。
- `.mine` 里 `cons_service` 之后、打 `--- shell N ---` 之前,且 **`cons_ok && shell_len > 0` 时**调
  `cons_erase_input(id, sh_line_cx, sh_line_cy, sh_ncx, sh_ncy)`:
  从输入起点到切走光标的所有格填 `0x07000020`,`cons_seq++`;若 `id==sh_active`,
  同时用 `fb_putcp_at(' ')` 把屏幕上的旧字擦掉(最多 128 格,~1 ms)。
- 然后正常打标题 + 提示符 + `shell_buf`;因为起点已经被擦掉,这一份就是唯一一份;
  打完把新的 `cons_cx/cy` 写回 `sh_line_cx/cy`。
- 半行跨行(超过 100 列)时,擦除范围是「起点到第一行行尾 + 中间整行 + 最后一行到光标」;
  `SHELL_LINE_MAX=128`,最多两行,不用做通用矩形。

### 3.4 输入法悬浮条:全局覆盖层,不属于任何一块缓冲

现状(`kernel/ime.asm`):

- `ime_show`(:208)先 `fb_bar_begin`,把屏幕最后两行**像素**存进 26 页还原缓冲,
  再清黑、用 `term_puts_at` 逐格画候选(第一行)和拼音回显(第二行);
  `fb_bar_end` 把原像素贴回去。`fb_bar_active` 记着「条子还开着」。
- 它**不换行、不碰命令行**,所以 `term_puts_at` 不接入控制台缓冲——条子上的字
  不应该变成 shell 的历史输出。

Phase 2 的规则:

| 问题 | 决定 |
|---|---|
| 条子归谁 | **只归活动控制台**。后台线程调 `ime_show` 直接返回(加 `cons == sh_active` 判断) |
| 切走时 | `shell_switch_to` 只置 `ime_switch=1`;`cons_service` 在重绘前调 `ime_abort`(收条、清 `ime_*` 状态) |
| 切回来 | 组合已经丢了,不恢复。这是**有意的**:恢复半截拼音比丢掉更让人困惑 |
| 条子像素 | `fb_bar_end` 先把旧像素贴回(旧控制台的画面),紧接着 `cons_repaint` 整屏覆盖,不会残留 |
| 程序自己画的「条」 | 编辑器用 API 13 `puts_at` 画的东西不进缓冲,切走再切回就没了;程序必须自己能整屏重画(EDIT 按键时会重画)。`term_puts_at` 入口加 `cons == sh_active` 判断,后台程序调用直接返回,别让它在别人的屏上画 |

> 消费 `ime_switch` 的代码就是 §3.3.2 `cons_service` 的开头:先收条,再判重绘旗。
> 只在 `cons_redraw` 非 0 时才收条会漏掉「切回一条停在提示符的 shell」这种情况。

> 悬浮条只有两行(第一行 9 个候选,第二行拼音),`IME_BUF_MAX=12`,和 100 列不冲突。

### 3.5 键盘:每控制台一个 64 字节环

现状是一个全局环 `kbd_buf`(64 B)+ `kbd_head/kbd_tail`,IRQ1 里 `kbd_push`。

Phase 2:

```asm
KBD_BUF_SIZE  equ 64
kbd_buf       times KBD_BUF_SIZE * SH_MAX db 0   ; 256 B
kbd_head      dd SH_MAX dup(0)
kbd_tail      dd SH_MAX dup(0)
```

| 函数 | 改动 |
|---|---|
| `kbd_push(al)` | 索引 = `[sh_active]`(IRQ 里 sh_active 就是「键盘现在归谁」);满照旧丢 |
| `kbd_avail` | 索引 = `[space_cur+TCB_CONS]`;返回该控制台的可读字节数 |
| `kbd_consume(ecx)` | 同上,推进该控制台的 tail |
| `kbd_seq_len` | 同上,判断该控制台队尾的 ESC 序列 |
| `kbd_getkey/kbd_getchar` | 只读自己控制台;空/不是活动控制台就 `pushfd; sti; hlt; popfd` 等 |

要点:

1. **IRQ1 压键用 `sh_active`,读者用自己的 `TCB_CONS`**。两者一般相等;不相等时
   (后台程序在读),它读不到任何键——键都进了活动控制台。这正是要的行为。
2. 后台程序 `kbd_getchar` 会**睡着**,不是忙等;直到 `Ctrl+←/→` 把它变成活动,
   IRQ 才会给它送键。ecosystem 里的 `ECHO` 在后台不会偷字。
3. `Ctrl+←/→` 在 IRQ 里被 `shell_switch_step` 吃掉,永远不会进任何环。
4. `shell_wait_key` 仍然先判 `sched_cur == sh_active`,否则返回 0;它读的也是
   `sh_active` 这块环,和以前等价。
5. 行缓冲不用动:`sh_nbuf/sh_nlen/sh_ndir` 本来就是每 shell 一份;程序读键不经过
   shell 行编辑。
6. **`kbd_push(0)` 是唤醒伪键**:`shell_switch_to` 靠它把 `hlt` 的读者踢醒,但
   `kbd_getchar` 现在会把 0 当普通键返回——后台的 `ECHO` 会多打一个
   `[0:0x00]`。Phase 2 的 `kbd_getchar/kbd_getkey` 读到 0 应直接 `jmp .loop`
   (键码 0 本来就不是合法字符);或者改成「先置 wake 标志、再 hlt」的两段式。
   这条不改,双屏切换测试会被伪键污染。

### 3.6 全局缓冲保护:一把调度器级的大锁

#### 3.6.1 问题

`int 0x30` 是 `IF=0` 的中断门,所以**系统调用内部天然不可抢占**;但 shell 线程自己
调 `fat_*` 时 `IF=1`,会被 IRQ0 切走,另一条 shell 线程可能同时进 `fat_read_file`。
`FAT_BUF`(0x100000)、`[fat_dir]`、`ata_*`、`lfn_*` 全是单份,必然互相踩。

逐个函数改成可重入(每线程一份缓冲)要动 2 378 行 FAT 代码,风险和收益不成比例。
Phase 2 用一把**调度器级大锁**:

```asm
; kernel/sched.asm
sched_noswitch  dd 0        ; >0 时 sched_pick 不换人

; 临界区入口/出口(可以嵌套)
fs_lock:
    inc dword [sched_noswitch]
    ret
fs_unlock:
    dec dword [sched_noswitch]
    ret
```

`sched_pick` 在保存完 esp/cr3、加完 tick 之后:

```asm
    cmp dword [sched_noswitch], 0
    jne .same                   ; 返回原 esp,不换人(IRQ 照发、EOI 照发)
```

为什么比 `cli` 好:

- ATA PIO 读一个 384 KiB 的程序是**几十到几百毫秒**;整段 `cli` 会丢键盘、拖慢时钟。
- `sched_noswitch` 只阻止「换线程」,IRQ1/PIT 照常进,键盘字节进环(64 字节上限,
  够用),`pit_ticks` 照走。
- 单 CPU 上 `inc dword [mem]` 是单条指令,中断只在指令之间发生,不需要 `lock`。

#### 3.6.2 罩哪些函数

在这些**顶层入口**的第一条指令 `call fs_lock`、最后一条 `call fs_unlock`
(失败路径也要 `fs_unlock`):

| 文件 | 函数 |
|---|---|
| kernel/fat.asm | `fat_path`、`fat_stat`、`fat_read_file`、`fat_write_file`、`fat_chdir`、`fat_list`、`fat_mkdir`、`fat_unlink`、`fat_rmdir`、`fat_alloc_cluster`、`fat_set_entry`、`fat_find`、`fat_find_run`、`fat_write_run` |
| kernel/ata.asm | `ata_read_sectors`、`ata_write_sectors` |

内部辅助函数(`fat_next_cluster`、`fat_scan_*`、`lfn_*`)**不重复加锁**,默认调用者
已经持有;`fs_lock`/`unlock` 用计数器支持嵌套。

**绝对不能**在持锁段里做的事:`hlt`、`pit_wait_ticks`、`loader_lock`、等键盘。
现在的 FAT/ATA 路径都只轮询端口/读扇区,满足这个约束。典型持锁时间:
读一个目录扇区 <1 ms;读 384 KiB 程序约 0.1–0.4 s(QEMU),期间别的 shell 会「顿一下」,
但键盘、时钟、屏幕都还活着——这是有意的取舍。

#### 3.6.3 `fat_dir` 变成每线程

`fat.asm` 里到处直接读 `[fat_dir]`,不动它;改成**切换线程时存/取快照**:

- TCB 加 `TCB_CWD`(偏移 116)。名字叫 CWD,存的是**切走那一瞬间的 `[fat_dir]` 原始值**,
  不是「逻辑当前目录」——这一点很重要。
- `sched_pick` 每次真正换人时:
  切走前 `mov eax,[fat_dir]; mov [旧 TCB+TCB_CWD],eax`;
  切进后 `mov eax,[新 TCB+TCB_CWD]; mov [fat_dir],eax`。
- **不要在 `cmd_cd` 里单独写 `TCB_CWD`**:一来 `shell_execute_plain` 会用 `saved_dir`
  把 `fat_dir` 恢复回去,单写会被覆盖;二来 shell 线程可能在 `fat_path` 里被切走,
  那一刻的 `fat_dir` 是「半进半出」的临时值,恰恰是恢复现场需要的值,而「逻辑 cwd」
  反而不是。存原始快照,两个场景一次解决。
- `cmd_run` 的 `cmd_saved_dir` 保留(它防的是「装载时 fat_path 临时 chdir」)。
- `api.asm` 文件 API 的 `api_saved_dir` 也保留,双保险。

#### 3.6.4 管道

`pipe_*` 是单份全局。两条 shell 同时跑 `A | B` 会串。最小改法:

```asm
pipe_busy  dd 0
; shell_pipe_execute 开头:
.retry:
    mov al, 1
    xchg [pipe_busy], al
    test al, al
    jz .got
    hlt
    jmp .retry
.got:
    ; ... 整条链 ...
    mov dword [pipe_busy], 0
```

`hlt` 只在这里出现(调用者是 shell 线程,`IF=1`)。第二条 shell 会等,不会报错;
如果不想等,也可以直接打「另一条 shell 正在跑管道」并返回,二选一,建议**等**
(管道通常几秒内结束,报错更烦)。

#### 3.6.5 其它共享状态

| 状态 | 处理 |
|---|---|
| `evt_log` 环形 16 条 | 入口 `pushf; cli`,`popf`;IRQ 里本来 `IF=0`,嵌套安全 |
| `loader_busy`(`loader_lock`) | 保留;只在 shell 线程用,`hlt` 等待 |
| `prog_size/prog_entry/name_buf/PROG_ARG_ADDR` | 已经被 `loader_lock` 罩住;不要在锁外读 |
| `term_color/term_fb_color` | 每控制台 `cons_attr`,画前重算;全局值只在活动线程里有意义 |
| `fb_*` | 只有活动控制台画;每次 `fb_*` 调用用 `cli` 包住(§3.2.5) |
| `sh_active/sh_switch_flag` | 只 IRQ 写;线程读,单字节/单 dword,天然原子 |
| `space_cur` | 每线程,`sched_pick` 维护,已经是现状 |
| `sched_kill` 的「检查→释放栈」 | `cmd_kill` 里用 `pushf; cli ... popf` 包住,否则检查完可能被切到目标线程,再释放它的栈就踩空了 |
| `pmem_free_count/alloced` | 只在 `cli` 或 `IF=0` 的系统调用里改;`debug pmem` 读之前也 `cli` 一下 |

### 3.7 内存和页数预算

| 项 | 页 | 说明 |
|---|---:|---|
| 4 块控制台缓冲 | 16 | `cons_init` 一次性拿,常驻 |
| `cons` 线程内核栈 | 2 | `sched_spawn` 的 8 KiB |
| TCB 表 | 0 | BSS,8 × 120 = 960 B |
| 代码 | ~5 KiB | 算进内核镜像,不占页池 |
| **合计** | **18 页** | 72 KiB,默认页池 30 207 页 |

`layout` 行加一段(`kmain` 打 layout 的地方):

```text
... pool=0x00400000-0x079ff000 pages=30207 cons=16
```

测试的 `expected_free_pages()`(qemu_test.py:1005)现在减 45;Phase 2 要减
`45 + layout_val("cons") + (2 若 cons > 0 否则 0)`(cons 线程栈),即默认 **63**。
不要硬编码 63,从 layout 读:`-m 8` 时 `cons=0`,`cons` 线程也没起,只能减 45。

### 3.8 测试计划(Phase 2)

先改测试台的两处:

1. `expected_free_pages()`:减去 `layout_val("cons")` 和 cons 线程的 2 页。
2. `ps` 断言:`4 alive / 6 slots` → **`5 alive / 8 slots`**,并多一行 `cons`。

新增 `tests/qemu_test.py` 的 `--shell` 套件里一个 `test_shell_consoles()`
(接在现有多 shell 用例 ~:1500 后面),全部用**图形模式 OCR**(`screen_text(shot, glyphs)`),
不要读 `0xB8000`——VBE 下那里没有字。

| # | 操作 | 断言 |
|---:|---|---|
| 1 | 开机 `shell` | `shells: 4`;`consoles: 4 x 100x37`(或 `cons` 命令) |
| 2 | shell 1 `echo alpha-only` | 屏幕有 `alpha-only` |
| 3 | Ctrl+→ 到 shell 2 | **没有** `alpha-only`;有 shell 2 自己的提示符 |
| 4 | shell 2 `echo beta-only`;Ctrl+← | 有 `alpha-only`、**没有** `beta-only`;再 Ctrl+→ 反过来 |
| 5 | shell 1 敲 `echo half`(不回车);切走再切回 | `half` 还在;回车能执行 |
| 6 | shell 1 `run HANG`;Ctrl+→;shell 2 `run ECHO` | `ECHO test: press keys`;说明两条 shell 真的在同时跑程序 |
| 7 | 在 ECHO 里敲 `abc`、`q` | 回显 `[0:0x61]` 之类;最后 `ECHO done.` |
| 8 | Ctrl+← 回 shell 1 | `this shell is stuck now` / `still spinning` 仍在(缓冲保住了) |
| 9 | 等 `done spinning`;`echo back` | `back`;shell 1 可继续用 |
| 10 | `debug pmem` | `free` 页数 == `expected_free_pages()` |
| 11 | `ps` | `5 alive / 8 slots`,有 `cons` |
| 12 | 输入法:shell 1 `run EDIT`;Shift;敲 `nihao`;Ctrl+→;Ctrl+←;Esc | 不花屏;条子没了;提示符能回来 |

**Demo 脚本**(手工演示 / 视频用):

```text
shell 1: run HANG            # 红字,开始空转
Ctrl+Right                    # 屏 2:干净的另一块屏,不是 HANG 的字
shell 2: run ECHO             # 两条程序同时在跑
         abc q
Ctrl+Left                     # 屏 1:HANG 的 "still spinning" / "done spinning" 还在
shell 2: kill 0               # 从另一条 shell 杀掉 HANG 的程序(SP_KILLREQ)
shell 1: echo back            # 收摊完成,提示符回来
```

小内存回归:`qemu -m 8`(没有页池)开机应打 `cons: disabled (no page pool)`,
Ctrl+←/→ 仍只换键盘;所有控制台断言跳过。

### 3.9 代码量、风险、清单

| 文件 | 新增/改动 | 估计行数 |
|---|---|---:|
| kernel/cons.asm(新) | 缓冲、`cons_putcp/byte`、滚屏、重绘 | ~380 |
| kernel/vgafont.asm | `term_print_cp` 一个 `jne` → `call` | 2 |
| kernel/kmain.asm | `cons_init`、hooks、layout、`cons` 线程 | ~60 |
| kernel/keyboard.asm | 每控制台环 + 等待 `sti/hlt` | ~70 |
| kernel/fat.asm / ata.asm | `fs_lock/unlock` 调用 | ~40 |
| kernel/sched.asm | `TCB_CONS/CWD`、`sched_noswitch`、CWD 同步 | ~30 |
| kernel/shell.asm | 切换旗、`cons_service`、管道锁(`cd` **不**写 CWD) | ~60 |
| kernel/pipe.asm | `pipe_owner`、`pipe_busy` | ~30 |
| kernel/ime.asm | 活动控制台判断、`ime_switch` | ~20 |
| tests/qemu_test.py | 12 条断言 + 页数公式 | ~120 |
| **合计** | | **~800 行,~5 KiB** |

主要风险:

| 风险 | 影响 | 缓解 |
|---|---|---|
| 满屏重绘太慢(VirtualBox MMIO) | 切换卡顿 0.1–1 s | 跳过空格;只画有字的行;最坏退化到「只画前 30 行」可配置 |
| 后台程序仍往全局 `fb_*` 写 | 花屏 | 所有输出先判 `cons == sh_active`;后台只写缓冲 |
| `kbd_getchar` 的 `hlt` 没修 | API 里睡死 | P0.1 必须先做 |
| 长 `fs_lock` 段饿死别的 shell | 切过去像卡住 | 持锁只罩真正的 FAT/ATA;不做 `hlt`;文档写明最长量级 |
| 控制台缓冲把页池吃光(小内存) | 开不了机 | `cons_ok=0` 回退;`-m 8` 断言 |
| IME 条残留 | 切换后花屏 | `ime_abort` + 整屏重绘;程序自画的条不做保证 |
| `SCHED_MAX` 改了但某处硬编码 6 | TCB 越界/ps 少一条 | `TCB_OFF` 宏;全仓 grep `SCHED_MAX`/`TCB_SIZE` |
| 测试仍按 80×25 读 VGA | 全红 | 用 OCR;`term_size` 在 VBE 下是 100×37 |

Phase 2 清单:

- [ ] P0.1–P0.5
- [ ] `TCB_CONS/TCB_CWD`,`TCB_SIZE=120`,`SCHED_MAX=8`
- [ ] `cons_init`:16 页、填空格、layout 行
- [ ] `cons_putcp/cons_putc_byte/cons_clear/cons_newline` + hooks
- [ ] 每控制台键盘环 + `sti/hlt` 等待
- [ ] `shell_switch_to` 置 `cons_redraw/ime_switch`
- [ ] `cons_service/cons_repaint` + `cons` 线程
- [ ] `fs_lock/sched_noswitch` + FAT/ATA 入口
- [ ] `TCB_CWD` 同步(`sched_pick` 存/取原始 `fat_dir`;`cmd_cd` 不写它)
- [ ] `pipe_owner/pipe_busy`
- [ ] 测试 12 条 + `expected_free_pages`
- [ ] README/known-issues 同步(删「一次只让一个程序跑」)

---

## 4. Phase 3:fork 与 copy-on-write

Phase 1 之后,每条线程已经有自己的 `SP_PD/SP_PT`;Phase 3 要做的是:
**复制一份页表,但先不复制物理页**,等谁写再给谁复制。难点不在「复制」,
在「怎么知道一页被几个人用着」——这就是引用计数表存在的原因。

### 4.1 ABI:3 个新功能号

现有 `int 0x30` 功能号 0–17(`kernel/api.asm` 的 `api_dispatch`)。下一个空闲是 **18**,
再往后 19、20。Phase 3 用:

| 号 | 名字 | 入参 | 返回 | 说明 |
|---:|---|---|---|---|
| 15 | `exit` | `ebx` = 退出码 | 不返回 | 以前忽略 `ebx`,现在存进 `TCB_EXITCODE` |
| **18** | `fork` | 无 | 父:`eax` = 子 tid(>0);子:`eax` = 0;失败:`eax` = -1 | 复制当前进程 |
| **19** | `wait` | `ebx` = 子 tid;`0xFFFFFFFF` = 任意子进程 | `eax` = 退出码;无子进程/出错 `eax` = -1 | 阻塞,直到有子进程退出 |
| **20** | `gettid` | 无 | `eax` = 当前 tid | 日志/调试用 |

约定沿用现有 `api_stub`(`api.asm:70` 起):

- `eax` = 功能号,`ebx/ecx/edx/esi/edi` 是参数;**只有 `eax/ebx/esi` 会写回**给用户
  (`[esp+28]/[esp+16]/[esp+4]`),`ecx/edx/edi/ebp` 用户保证不变。
- 入口是 `0xEE` 的 DPL3 中断门(IF=0),所以 **fork 本身是原子的**,不会被定时器
  切在「页表复制了一半」的位置。
- `fork` 失败返回 -1 的三种原因:没有空 TCB 槽、页池不够(PD/PT + 2 页栈)、
  某页引用计数已经 15(见 §4.4)。
- `wait` 是唯一一个会**主动开中断**的系统调用:`pushfd; sti; hlt; popfd` 循环重扫,
  否则 IF=0 的 `hlt` 永远醒不过来(Phase 2 的 P0.1 就是同一类 bug)。

`api_usage` 文本要补 18/19/20;`api.md`(如果有)同步。**不实现 `fork+exec`**:
新进程和父进程跑同一段代码,想换程序请 `exit` 后再从 shell `run`,这是有意的范围控制。

### 4.2 TCB:加 4 个字段,扩到 144 字节

| 偏移 | 字段 | 说明 |
|---:|---|---|
| 0–108 | 现有(112 B) | ESP/CR3/STATE/…/SP_KILLREQ |
| 112 | `TCB_CONS` | Phase 2:控制台号 |
| 116 | `TCB_CWD` | Phase 2:`fat_dir` 快照 |
| **120** | `TCB_PARENT` | 父 tid;`-1` = 不是 fork 出来的 |
| **124** | `TCB_EXITCODE` | `exit(ebx)` 存的退出码 |
| **128** | `TCB_PFCOW` | 这个进程因 COW 复制了多少页(统计/测试) |
| **132** | `TCB_FLAGS` | bit0 = forked;bit1 = exiting(正在收摊) |
| 136/140 | 保留 | 对齐到 144,以后加字段不用再挪 |

`TCB_SIZE` **120 → 144**(Phase 2 已经把 112 用到 116);`SCHED_MAX` **8 → 12**。为什么是 12:

- 4 条 shell + 1 条 `cons` 线程 = 5;
- fork 出来的子进程要占槽,留 6 个;
- 12 × 144 = 1 728 B,TCB 表还是 BSS 里的一小块。

`sched_spawn` 把新字段初始化:`PARENT=-1`、`EXITCODE=0`、`PFCOW=0`、`FLAGS=0`。
状态机加 `ST_ZOMBIE=3`(已退出、等父进程收尸);`sched_pick` 只挑 `ST_ALIVE`,
僵尸永远不会被调度。`ps` 要能显示 `zombie` 和 `parent=N`。

> TCB 从 Phase 1 的 112 分两步扩到 144(Phase 2 先到 120)会把所有 `TCB_OFF`/`TCB_SIZE` 的使用点都牵动一遍
> (`sched.asm`、`paging.asm`、`shell.asm`、`pit.asm`、`api.asm`)。都用宏,不要手写 112。

### 4.3 复制页表:先改权限,再谈复制

#### 4.3.1 顺序很重要

```text
sched_fork:
  1. 从 5 起找空槽(0–4 是 shell/cons);若没有 → eax=-1
  2. 预分配:PD 1 页、PT 1 页、子内核栈 2 页(共 4 页);失败 → 全退,-1
  3. 先扫一遍**父** PT:任何 present+USER 页的引用计数已经是 15 → 释放第 2 步的 4 页,
     返回 -1(4 bit 装不下第 16 个共享者)
  4. 标记**父** PT 0..1023:present && USER →
         pmem_ref_inc(pa);PTE |= PAGE_COW;PTE &= ~PAGE_RW
  5. 复制:父 PD 整页 1024 dword → 子 PD;父 PT 整页 1024 dword → 子 PT
     (此时父 PT 已经是 COW/只读,子 PT 自然继承);然后
     `子 PD[0] = 子 PT | P|RW|USER`——不修这一项,子进程会继续用父的页表,fork 白做
  6. 刷新父的 TLB:mov eax,cr3; mov cr3,eax   ; 否则父还拿着可写的旧 TLB 项
  7. 在子栈顶搭 iret 帧(见 §4.3.2);填 TCB;TCB_ESP/TCB_SP_RUNESP
     (SP_STAGE_PA/SP_STAGE_PAGES **从父复制**,并对暂存区每页 `pmem_ref_inc`——父子
      共用同一份镜像暂存区,谁先退都不能把它抽走;SP_KILLREQ=0、SP_RUNSTAT=0、
      SP_LIVE=1、SP_RUNNING=1;SP_PAGES/SP_IMGBYTES/SP_HEAPPAGES/SP_ARGSVA/
      SP_STACKVA/SP_STACKTOP 从父复制;SP_PFRUN/PFIMG/PFHEAP/FIRSTPA/SP_FREED=0)
  8. ++sched_live;eax=子 tid
```

**先分配、后标记**是刻意的:标记阶段只做「inc + or/and」,不会失败;
这样就没有「标记了一半失败要回滚」的烂摊子。4 页在 30 207 页的池里几乎不可能失败,
但还是要在第 2 步检查,失败就把已分配的还回去。

#### 4.3.2 子线程的第一次调度

子线程不是从 `sched_spawn` 的「内核线程入口」开始,而是**从 `int 0x30` 的下一条
指令开始**,所以栈上要摆一个「中断返回」现场,让 `irq0_stub` 的收尾直接 `iret` 到
用户态:

```text
        ┌──────────────┐  ← 子栈顶(8 KiB 页的末尾),TCB_SP_RUNESP
        │ SS3          │
        │ ESP3         │   iret 帧(5 dword,20 B)
        │ EFLAGS       │
        │ CS3          │
        │ EIP          │
        ├──────────────┤
        │ 错误码 0      │
        │ 向量 0x20     │   irq0_stub 的 add esp,8 会扔掉
        ├──────────────┤
        │ EDI … EAX    │   pushad 的 8 个 dword(32 B)
        └──────────────┘  ← TCB_ESP = 栈顶 - 60
```

- `EIP/CS3/EFLAGS/ESP3/SS3` 从 `api_stub` 的帧抄。**注意基准**:进入
  `api_dispatch` 时 `esp` 指向 gs(`api_stub` 压完 pushad+四个段寄存器),把这一刻的
  `esp` 记作 `frame`(`api_dispatch` 的 case 18 里 `lea esi,[esp+4]` 跳过 `call` 的返回地址,再 `call sched_fork`),则
  `[frame+48]=EIP`、`[frame+52]=CS`、`[frame+56]=EFLAGS`、`[frame+60]=ESP3`、
  `[frame+64]=SS3`;`pushad` 的八个寄存器在 `[frame+16..44]`。`sched_fork` 内部用
  `esi` 而不是 `[esp+48]`,否则会被 call 压入的返回地址带偏。
- **`EAX` 必须置 0**——子进程从 `fork` 返回 0;其余寄存器照抄(父子看到一样的
  `ebx/ecx/edx/…`,这是 fork 的语义)。
- `TCB_SP_RUNESP = 栈顶`(不是栈顶-60):`sched_pick` 会把它写进 `TSS.esp0`,
  ring 3 第一次进中断时 CPU 从栈顶往下压,和现有 `cmd_run` 的做法一致。
- 子线程的 `TCB_CR3 = 新 PD`;第一次被 `sched_pick` 选中时 `mov cr3` 就生效,
  不需要在 fork 里手动切过去。

#### 4.3.3 哪些页会被标 COW

遍历的是**父 PT 的 0..1023 项**,条件 `present && PAGE_USER`;标完再整页拷给子,
子 PT 自然继承同样的 COW/只读项。**不要反过来只标子 PT**——父的 PTE 还是 RW,父写
根本不会缺页,孩子会一直看见父后来写进去的内容,COW 就漏了一半。

| 页 | 在 PT 里的位置 | 会被标 |
|---|---|---|
| 镜像窗口 0x120000–0x17FFFF | 288–383 | 已按需补过的页才 present,标 |
| 堆窗口 0x180000–0x3AFFFF | 384–943(128 MiB 时 560 页) | 已按需补过的页才 present,标 |
| 弹床页 0x17F000 | 383 | 标(它其实是镜像窗口的最后一页) |
| 用户栈页 | `SP_STACKVA` | 标(必须) |
| 参数页 | `SP_ARGSVA` | 标 |
| 该 PT 里的内核恒等映射 | 0–287(0–0x11FFFF)、944–1023(0x3B0000–0x3FFFFFF) | **不标**(无 `PAGE_USER`) |

> 两个窗口**首尾相接**:`SPACE_IMG_PAGES=96` 正好是 0x60000 字节,镜像窗口
> 0x120000–0x17FFFF,堆窗口紧接着从 0x180000 开始。`space_create` 从 PT 下标 288
> 起清 `96 + SP_HEAPPAGES` 项,清的就是这一整段连续地址。COW 遍历按
> 「present + USER」判,不依赖窗口边界;但算 PT 下标时别把两段当成不相干的两块。

- 非 present 的页(还没按需补)不标:父子谁先碰谁补,互不影响。
- 标完必须 `mov cr3` 刷新 TLB;否则父进程刚写过的页在 TLB 里还是 RW,写下去不会
  触发缺页,COW 就漏了。
- **staging 页(SP_STAGE_PA)不是 COW**:它在内核空间、只读共享,直接 inc_ref 后父子
  共用;销毁时各自 dec,最后一个还页。
- **引用计数上限 15** 是 4 bit 的硬限制:同一个物理页最多被 15 个地址空间共享,
  第 16 个共享者加不进来。fork 前若发现任何一页已经是 15,直接返回 -1;实际含义是
  「同一页最多 15 个地址空间共享」,单链 fork 深度上限 14 层(父页初始 1,每 fork 一层 +1)。

#### 4.3.4 4 页的成本

| 分配 | 页数 | 谁释放 |
|---|---:|---|
| 子 PD | 1 | `space_destroy_at` |
| 子 PT | 1 | `space_destroy_at` |
| 子内核栈 | 2 | `wait` 收尸时 `pmem_free_pages` |
| **每次 fork 新分配** | **4 页** | 父的 staging 页只加引用,不复制 |

用户页一页都不复制——这是 fork 便宜的原因。一个 3 700 格控制台缓冲只占 4 页,
fork 一次和它同量级。

### 4.4 引用计数表:每页半个字节

#### 4.4.1 尺寸和位置

| 项 | 值 |
|---|---:|
| 页池最大页数 | 64 512(`PMEM_BITMAP` 8 KiB,一页一位) |
| 每页计数 | 4 bit(0–15) |
| 表大小 | 64 512 / 2 = **32 256 B = 8 页** |
| 默认 128 MiB 实际页数 | 30 207 |
| 实际用到 | 30 207 / 2 = **15 104 B ≈ 4 页** |

位置:**0x3D2000**,紧挨页池位图 `0x3D0000–0x3D1FFF` 后面,保留到 0x3D9FFF(8 页)。
已核对:0x3D2000–0x3D9FFF 在当前仓库里没有任何使用者(`grep -i 3d2/3d3…` 只命中
`kernel/arm64/` 里的假阳性);USB 用到 0x3C2FFF,PINYIN 到 0x3BFFFF,不冲突。

```asm
PMEM_REF equ 0x3D2000          ; kernel/pmem.asm
```

```text
0x3D0000 ┌──────────────┐ 页池位图 8 KiB(一页一位)
0x3D2000 ├──────────────┤ 引用计数表 32 KiB(最大 8 页;默认只用 15 104 B)
0x3DA000 └──────────────┘
```

`pmem_init` 里 `rep stosd` 清 8 页。为什么不做成「按需增长」:表是静态地址,
`pmem_alloc` 在中断/系统调用里都能直接算,不用再查指针。

#### 4.4.2 编码

```text
byte[pa>>12 / 2]:
   低 4 位 = 页号偶数的计数
   高 4 位 = 页号奇数的计数
```

```asm
; eax = 物理地址 → edi = 该页 nibble 的字节地址,cl = 半边偏移(0 或 4)
pmem_ref_ptr:
    mov edx, eax
    shr edx, 12
    mov ecx, [pmem_start]
    shr ecx, 12
    sub edx, ecx               ; 页号(池内从 0 开始)
    mov ecx, edx
    shr edx, 1
    and ecx, 1
    shl ecx, 2                 ; 0 或 4
    lea edi, [PMEM_REF + edx]
    ret
```

#### 4.4.3 三个原语

| 函数 | 入/出 | 语义 |
|---|---|---|
| `pmem_ref_get(eax=pa)` | `eax` = 计数 | 池外/未分配返回 0 |
| `pmem_ref_inc(eax=pa)` | `eax` = 新计数;`CF=1` = 溢出(已经 15)或页未分配 | 溢出时**不改**表 |
| `pmem_ref_dec(eax=pa)` | `eax` = 新计数;`CF=1` = 原本就是 0 | **减到 0 时顺手清位图、`--pmem_free_count`**(即真正还页) |

#### 4.4.4 接进现有分配器

| 现有函数 | 现在 | Phase 3 |
|---|---|---|
| `pmem_alloc` | `bts` 后返回 | `bts` 后 `ref=1` |
| `pmem_alloc_pages` | 同样 | 每页 `ref=1` |
| `pmem_free` | `btr`,计数减 | 校验对齐/范围/位图后调 `pmem_ref_dec`;`ref` 原本 0 → `CF=1` |
| `pmem_free_pages` | 循环 `pmem_free` | 返回「真正还回池」的页数(即 dec 减到 0 的页数) |

**关键语义**:`pmem_free` 不再等于「一定还页」。共享页上调用它只是「我这份不要了」,
位图保持置位,`pmem_free_count` 不变。这样 `debug pmem` 看到的空闲页数始终是
「真正可分配的页」,测试的 `expected_free_pages` 不会被共享页骗。

重复释放仍然返回 `CF=1`(`ref` 已经是 0 → 说明调用者错了),保留现有断言。

### 4.5 缺页:present + COW + 写

现有 `page_fault_try_handle`(`paging.asm:472`)只处理「页不存在」。Phase 3 在它
最前面加一段:

```text
page_fault_try_handle:
    ; idt.asm 在 call 前加一句:mov ecx,[ebp+36](ISR 帧里的错误码)
    mov [pf_err], ecx
    ; 新:present 的写错误,可能是 COW
    test byte [pf_err], 1       ; 错误码 bit0 = present
    jz .not_present
    test byte [pf_err], 2       ; bit1 = write
    jz .fail                    ; 读 present 页还缺页:不是 COW,交回上层
    ; 取 PTE,判 PAGE_COW
    ...
    test eax, PAGE_COW
    jz .fail
    ; 到这里:确定是 COW
    pmem_alloc_pages(1)
    jz .oom
    memcpy 4 KiB:源=旧物理页(恒等映射),目标=新页
    PTE = 新pa | P | RW | USER   ; 去掉 COW
    invlpg [cr2]
    pmem_ref_dec(旧pa)
    ++[space_cur+TCB_PFCOW]
    return 1                    ; iret 重执行那条写指令
```

要点:

1. **判 `present` 用错误码 bit0,不要用 `space_live` 猜**。COW 缺页的 PTE 是
   present 的,现有「PTE 已 present 就返回 0」那条会直接把它漏过去,必须放在它**前面**。
2. `CR0.WP` 必须置 1(`paging_init` 里 `or eax, 0x00010000`,和 `0x80000000` 一起)。
   否则内核态写只读页不触发缺页,`copy_to_user` 类的路径绕过 COW,父子会共享同一页
   还都以为自己独占。Phase 1 现在只 `or 0x80000000`,这是 Phase 3 的**硬前置**。
3. 内核态(CPL=0)的 COW 写也要处理:系统调用里写用户缓冲区(比如 `read` 把文件
   读进程序给的地址)发生在父/子自己的 CR3 下,PTE 可能已经是 COW+只读。处理方式
   相同;不要用「CS&3==3」把内核态挡掉。
4. 旧页 `pmem_ref_dec`:减到 0 时它自己清位图还页(当前映射已经改成新页,旧页可能
   真的没人了)。**不要再补一次 `pmem_free`**,否则会多减一次。
5. **OOM**:打印 `cow: out of memory` 后 **返回 0**(不是 1),把决定权交回
   `idt.asm`:它已经有一条「用户态 → `prog_kill_from_fault`」的路,别在 handler 里
   重复造。内核态(CS&3==0)继续走 panic——内核里没有「杀掉谁」的语义。
6. 非 COW 的 present 写错误(权限违规)原样返回 0,继续走现有的 panic/kill 判断,
   不要吞掉。

`invlpg` 只刷当前 CR2 那一页;父进程的 TLB 在 fork 时已经刷过,子进程刚加载 CR3,
没有旧项。

### 4.6 销毁:只减引用,不盲目还页

`space_destroy_at`(`paging.asm:625`)现在是「present 就 `pmem_free`」。改成:

```text
space_free_window:
  对每个 present 的 PTE:
      pa = PTE & 0xFFFFF000
      PTE = 0
      pmem_ref_dec(pa)
      若 dec 返回「减到 0」 → ++sd_pages   ; 真正还回池
  最后 invlpg 或 reload cr3

space_destroy_at:
  SP_LIVE=0
  释放镜像/堆窗口(按 PT 项,不按窗口名)
  pmem_free(SP_PT) / pmem_free(SP_PD)   ; 私有页,ref 必为 1
  for pa = SP_STAGE_PA .. +PAGES: pmem_ref_dec(pa);为 0 才 ++sd_pages
  返回 sd_pages
```

- **PD/PT 不共享**:每次 fork 都新分配、整页复制,销毁时直接 `pmem_free`(它们的
  ref 是 1)。不要对它们做 dec-ref 语义,否则父进程的 PD 会被子进程的错误销毁带走。
- 镜像/堆窗口的页、栈页、参数页、弹床页都可能是共享的,必须走引用计数。
- `SP_STAGE_PA` 是装载时的内核暂存区,**不在用户页表里**,不会被标 COW;fork 后父子
  共享它,销毁时同样走 dec-ref(每个 fork 都 inc 过)。不能直接 `pmem_free` 整段——
  父进程还在跑时那样会把 staging 抽走,父的下一次镜像缺页补出零页。
- 子进程退出时 `space_destroy_at(space_cur)`,父进程的页仍然活着(ref>0);
  父进程随后读写自己的页不会受影响——这正是 COW 要的。
- 返回值只数「真正还回池」的页,`after_prog` 打印的 `address space destroyed N page(s)`
  在共享场景下会变小,这是对的:那 N 页本来就没还。

### 4.7 exit / wait / 僵尸

#### 4.7.1 两条退出路

现在 `api_exit` 只有一条路:

```asm
mov edx, [space_cur]
mov esp, [edx + TCB_SP_RUNESP]
段 = GDT_KDATA
cr3 = PD_ADDR
jmp run_resume_kernel        ; → space_deactivate; sti; popad; jmp cmd_run.after_prog
```

这条路径的前提是「这个线程是从 `cmd_run` 的 `pushad` 进去的」——shell/cons 线程成立,
**fork 出来的子进程不成立**:它的内核栈上只有 §4.3.2 那个 iret 帧,没有 `cmd_run`
的 `pushad` 现场,`run_resume_kernel` 的 `popad` 会弹到 iret 帧的 SS3/ESP3 上当寄存器。

所以 `api_exit` 要分叉:

```asm
api_exit:
    mov edx, [space_cur]
    test byte [edx+TCB_FLAGS], 1      ; bit0 = forked
    jnz .forked_exit
    ; 原来的路:shell / cons 线程
    mov esp, [edx+TCB_SP_RUNESP]
    ...
    jmp run_resume_kernel
.forked_exit:
    mov eax, [edx+TCB_EXITCODE]       ; api_dispatch 在 case 15 存的 ebx
    call child_exit                   ; 见下
```

#### 4.7.2 `child_exit`:把自己变成僵尸,然后切走

```asm
; eax = 退出码
child_exit:
    mov edx, [space_cur]
    mov [edx+TCB_EXITCODE], eax
    or  dword [edx+TCB_FLAGS], 2      ; exiting
    mov edi, [sched_cur]
    call sched_orphan_children        ; 活子归 0 号,僵尸子当场收掉
    mov edx, [space_cur]
    call space_deactivate             ; SP_LIVE=0,cr3=PD_ADDR(不能带着子的 CR3 释放 PD)
    mov edi, edx
    call space_destroy_at             ; 把地址空间账结清(会清 SP_RUNNING)
    mov edx, [space_cur]              ; destroy 可能改了 edx,重新取
    mov dword [edx+TCB_STATE], ST_ZOMBIE
    mov dword [edx+TCB_SP_RUNNING], 0
    ; 不能 return:这层栈马上就要被丢弃
    mov dword [sched_save_esp], esp   ; 存哪都行,僵尸不会再被调度
    call sched_pick                   ; 返回下一个 ALIVE 的 TCB_ESP
    cmp eax, [edx+TCB_ESP]            ; 只剩自己?
    je .lonely
    mov esp, eax
    popad                             ; 目标线程的 irq0 现场
    add esp, 8                        ; 错误码 + 向量
    iret                              ; 回到它当初被切走的地方
.lonely:
    cli
    hlt                               ; 没有别人可跑了,停在这儿
    jmp .lonely
```

为什么这样能工作:每条**可被调度**的线程,其 `TCB_ESP` 要么指向 `irq0_stub` 保存的
`pushad` 块(被定时器切走),要么指向 `wait` 里 `hlt` 时被切走的同一个位置。
`popad; add esp,8; iret` 正是 `irq0_stub` 的收尾动作,所以「借下一个线程的栈返回」
是合法的。前提:**`wait` 必须用 `sti; hlt` 睡**,不能忙等——忙等时 `TCB_ESP` 是
`api_wait` 的调用栈,形状不对。`wait` 用 `pushfd; sti; hlt; popfd`,和这个收尾兼容。

#### 4.7.3 父进程 wait

```text
api_wait(ebx=pid):
.rescan:
  for tid = 0 .. SCHED_MAX-1:
      if STATE==ST_ZOMBIE and TCB_PARENT==mytid and (pid==-1 or tid==pid):
          status = TCB_EXITCODE
          pmem_free_pages(TCB_STACK, 2)
          清 TCB 槽;--sched_live
          eax = status; ret
  if 没有任何「PARENT==mytid 且 ALIVE」的子进程:
      eax = -1; ret
  if [space_cur+TCB_SP_KILLREQ] != 0:      ; 睡在这里时被 kill
      mov eax, 1
      jmp child_exit                       ; 不再返回
  pushfd; sti; hlt; popfd
  jmp .rescan
```

- `pid==-1` 等任意一个;`pid>0` 等指定那个。没有子进程、或指定 tid 不是自己的子进程,
  返回 -1(不阻塞)。
- 收尸时才还子进程的内核栈(2 页),不是 `exit` 时——父进程可能还要读 `TCB_EXITCODE`。
- `wait` 在 `int 0x30` 的 IF=0 里,所以循环里必须自己 `sti; hlt`,否则永远醒不过来。
- 两条 shell 线程永远不调用 `wait`;它们的「子进程」是 `cmd_run` 起的程序,程序退出
  走 `run_resume_kernel` → `after_prog`,不需要 wait。

#### 4.7.4 孤儿和收尸

| 场景 | 处理 |
|---|---|
| 父进程 exit 时还有 ALIVE 子进程 | 把它们的 `TCB_PARENT` 改成 `0`(归 0 号 shell) |
| 父进程 exit 时还有 ZOMBIE 子进程 | 直接收尸(还栈、清槽、`--sched_live`),否则永远没人 wait |
| 0 号线程空闲 | 在 `shell_wait_key` 的 `hlt` 前调 `reap_children(0)`,收掉 `PARENT==0` 的僵尸 |
| 程序退出但留下僵尸子进程 | `after_prog` 里调 `reap_children(当前 tid)`,把 `PARENT==我` 的僵尸收掉 |
| 程序退出但还有 ALIVE 子进程 | `after_prog` 里把它们 `TCB_PARENT` 改成 `0`,由 0 号空闲时收尸 |
| `cmd_kill` 杀掉一个 forked 子进程 | 走 `child_exit(1)`,不碰 `run_resume_kernel`(见 §4.7.5) |

`reap_children(tid)` 就是 `wait` 里那段「扫 + 还栈 + 清槽」,抽成函数给三处复用;
`sched_orphan_children(tid)` 再把「ALIVE 改父、ZOMBIE 收掉」包一层,给 `child_exit`
和 `after_prog` 用。
它必须在 `IF=1` 的上下文调用吗?不一定:扫表 + `pmem_free_pages` 都不睡眠,
`IF=0` 也能跑,只是别在持 `fs_lock` 时调。

#### 4.7.5 被 kill / 崩溃的 forked 子进程

`pit.asm` 的 KILLREQ 分支现在无条件跳 `run_resume_kernel`,对 forked 子进程是错的
(同 §4.7.1 的理由)。**`prog_kill_from_fault`(14 号缺页/其它异常)也一样**:它现在
打印完就 `esp=[run_esp]` 跳 `run_resume_kernel`,forked 子进程的栈上没有 `cmd_run`
的 pushad 现场。两处都要先看 `TCB_FLAGS bit0`:

```asm
; prog_kill_from_fault 打印完 crash 之后:
    mov edx, [space_cur]
    test byte [edx+TCB_FLAGS], 1
    jnz .forked_crash
    ; 原路:esp=[run_esp]; jmp run_resume_kernel
.forked_crash:
    mov eax, 1
    call child_exit
```

`pit.asm` 的 KILLREQ:

```asm
    test byte [edx+TCB_FLAGS], 1
    jnz .kill_forked          ; 必须在 mov esp,[SP_RUNESP] 之前判
    ; 原逻辑:esp=[SP_RUNESP]; jmp run_resume_kernel
.kill_forked:
    mov eax, 1                  ; 被杀的退出码
    call child_exit
```

`cmd_kill` 先拒 `tid == 4`(cons 线程);0–3 是 shell 线程,只给它跑的程序打
`KILLREQ`;对 **forked 子进程**(5 起)也不要走 `sched_kill`:置 `SP_KILLREQ=1`,让它经
`child_exit(1)` 变成僵尸(父进程 `wait` 才拿得到状态 1)。`sched_kill` 只留给
「不是从 ring 3 跑程序」的内核线程/异常兜底;否则父进程的 `wait` 会看到「没有这个
子进程」,返回 -1。`SP_KILLREQ` 路径只负责立旗,实际收摊在中断返回点。

已知缺口:`SP_KILLREQ` 只在 **CS 的 CPL=3** 时被 `irq0_stub` 认领。forked 子进程
如果正阻塞在 `wait`/`kbd_getchar` 的内核态里,要等它回到 ring 3 才生效;`wait` 循环
已经加了 KILLREQ 检查(见 §4.7.3),`kbd_getchar` 没有——它要等到下一次按键把
系统调用返回。这条写进 known-issues,别在演示里杀一个睡死的读键程序。

#### 4.7.6 上限

| 限制 | 值 | 说明 |
|---|---:|---|
| 总槽位 | 12 | 4 shell + cons + 6 fork 余量 |
| 每次 fork 物理页 | 4 | PD/PT/2 页栈,用户页 0 复制 |
| 单页引用上限 | 15 | 4 bit;同一页最多 15 个地址空间共享 |
| fork 深度 | ≤14 | 每层给共享页 +1 引用,4 bit 上限 15;实际还受「宽度 × 深度」共同限制 |
| 僵尸槽 | 6 | 子进程退出后不 wait 会占槽;`after_prog`/0 号线程兜底收尸 |
| 不做 | `fork+exec`、信号、进程组、SMP、FPU 上下文切换 | 写进 known-issues |

> **FPU/SSE 是已知缺口**:TCB 不保存 `ST0–ST7`/`XMM`。Phase 2 允许多个程序并行后,
> 两条线程同时用浮点会互相踩。当前 `FPU.BIN`/`FCALC.BIN` 是单程序测试,不会撞;
> 真要多进程浮点,得在 `sched_pick` 里加 `fnsave/frstor`(每 TCB 108 字节 + 512 字节 XMM,
> TCB 还要再扩)。Phase 3 明确不做,列进 known-issues。

### 4.8 测试计划(Phase 3)

新增两个 C 程序,放进 `progs/`(`C_PROGS` 列表,`make` 后由 `mkfat.py` 装进 `/BIN`)。

先在 `include/kkernel.h` 里加 `static inline` 封装(照 `j_getchar` 的写法):
`j_fork()`(功能 18)、`j_wait(pid)`(19,`ebx=pid`)、`j_gettid()`(20)、
`j_exit_code(code)`(15,`ebx=code`)。

> 注意 `include/kkernel.h` 现在有个**没被任何程序使用**的 `j_exit(const char *msg)`
> (清屏+打一行字,不调 API 15)。别直接改它的签名:把它改名 `j_exit_msg`,另加
> `j_exit_code(int code)`,现有代码零改动。

**`progs/FORK.C`**:

```c
volatile int shared[4] = {1, 2, 3, 4};
j_print("FORK: start\n");
int pid = j_fork();
if (pid == 0) {
    shared[0] = 99;
    printf("child sees %d\n", shared[0]);    /* 99 */
    j_exit_code(7);
}
printf("parent sees %d\n", shared[0]);       /* 1,COW 生效 */
int st = j_wait(pid);
printf("child %d exited %d\n", pid, st);     /* 7 */
printf("parent still sees %d\n", shared[0]); /* 1 */
j_print("FORK: done\n");
```

**`progs/FORK2.C`**:`for (i=0;i<3;i++){ if(j_fork()==0) j_exit_code(i); j_wait(-1); }`
再打 `FORK2: 3 forks done`;用来查「连续 fork/exit 不泄漏」。

**`progs/FORK3.C`**(可选):子进程 exit 后父进程 `sleep` 一会儿再 `ps` 看僵尸,
然后 `wait`。时间断言容易 flaky,放在手工 demo 里,不进自动测试。

`tests/qemu_test.py` 的 `--shell` 套件加一组(或新开 `--fork` 模式,`main()` 里加开关,
`Makefile` 的 `test` 目标加一行):

| # | 操作 | 断言 |
|---:|---|---|
| 1 | `run FORK.BIN` | `parent sees 1`;`child sees 99`;`child <tid> exited 7`;`parent still sees 1`;`FORK: done` |
| 2 | 再 `run FORK.BIN` | 同样五句;没有 `out of memory`/`cow:` |
| 3 | 跑前 `debug pmem`;跑后 `debug pmem` | 两次 `free:` 相同(PD/PT/栈/COW 页全回收) |
| 4 | `run FORK2.BIN` | `FORK2: 3 forks done`;`debug pmem` 仍相同 |
| 5 | 连跑 3 次 FORK2 | free 页数不单调下降(允许 ±0) |
| 6 | `ps` | `5 alive / 12 slots`(没有僵尸时) |
| 7 | `kill` 一个 forked 子进程(手工 demo) | 子进程消失,父进程 `wait` 返回 1,`debug pmem` 不掉页 |

Phase 3 把 `SCHED_MAX` 从 8 扩到 12,§3.8 里 `5 alive / 8 slots` 的断言要同步改成
`5 alive / 12 slots`。

页数断言用 `debug pmem` 的 `free:` 行,和现有 `expected_free_pages()` 同一套解析;
引用计数表在 0x3D2000(保留区),**不进页池**,所以 `expected_free_pages()` 不用改
(Phase 2 的 63 不变)。但 `ps` 的槽数从 8 变 12,Phase 2 的断言要一起改。

**手工 demo**:

```text
shell 1: run FORK.BIN        # 父子各打各的,父看到 1、子看到 99
shell 1: debug pmem          # 跑前跑后 free 一样
shell 2: run FORK2.BIN       # 同时跑,互不干扰
shell 1: ps                  # 12 slots,FORK 的子进程短暂出现
```

### 4.9 代码量、风险、清单

| 文件 | 改动 | 估计行数 |
|---|---|---:|
| kernel/sched.asm | `sched_fork`、`child_exit`、`reap_children`、TCB 扩字段 | ~220 |
| kernel/paging.asm | `space_clone`、COW 缺页分支、`space_destroy` 改造 | ~170 |
| kernel/pmem.asm | 引用计数表 + 3 个原语 + alloc/free 接入 | ~130 |
| kernel/api.asm | 18/19/20、case 15 存退出码、`api_usage` | ~70 |
| kernel/pit.asm | KILLREQ 分支判 forked | ~10 |
| kernel/shell.asm | `ps` 显示、`after_prog` 收尸、`cmd_kill` | ~40 |
| progs/ | FORK.C、FORK2.C | ~80 |
| tests/qemu_test.py | 7 条断言 + `--fork` | ~120 |
| **合计** | | **~840 行,~5 KiB** |

内核从 ~85 KiB 涨到 ~95 KiB,仍 < 128 KiB;0x3D2000 多预留 32 KiB 静态表
(默认只用 15 104 B,不算页池)。

主要风险:

| 风险 | 后果 | 缓解 |
|---|---|---|
| 忘设 `CR0.WP` | COW 完全不触发,父子共享同一页且都以为独占 | `paging_init` 里 `or eax,0x00010001`;测试「父看到 1」必挂 |
| fork 的 iret 帧偏移错 | 子进程第一次被调度就 triple fault / 跑飞 | 按 §4.3.2 的 60 字节精确搭;先在 QEMU `-d int` 看一次 |
| `TSS.esp0` 指到父的栈 | 子进程第一次中断压垮父栈 | `sched_pick` 用 `TCB_SP_RUNESP`;fork 里设子栈顶 |
| 标记 COW 后没刷 TLB | 父进程写不进缺页,COW 漏 | `mov cr3` 重载;fork 返回前做 |
| 引用计数泄漏 | 页池慢性减少,最后 OOM | `debug pmem` 前后断言;`space_destroy` 每条路径都 dec |
| 僵尸不回收 | 槽位耗尽,fork 返回 -1 | `after_prog`/0 号线程兜底;`ps` 看 zombie |
| `pmem_free` 语义改宽 | 老调用点以为「一定还页」 | 全仓 grep `pmem_free`;`space_destroy` 用返回值统计 |
| 15 次引用上限 | 宽 fork 树失败 | 预检;返回 -1 不崩溃;文档写明 |
| FPU 状态不保存 | 并行浮点程序互相踩 | known-issues;Phase 3 不做 |
| `SCHED_MAX` 8→12 漏改 | TCB 越界/ps 少 | 用 `SCHED_MAX` 宏;grep 硬编码 6/8 |

Phase 3 清单:

- [ ] P0 收尾(§2)
- [ ] `TCB_PARENT/EXITCODE/PFCOW/FLAGS`,`TCB_SIZE=144`,`SCHED_MAX=12`,`ST_ZOMBIE`
- [ ] 引用计数表 0x3D2000,`pmem_ref_*`,alloc/free 接入
- [ ] `space_clone`:PD/PT 复制 + 标 COW + 刷 TLB
- [ ] `sched_fork`:4 页预分配、60 字节帧、TCB 字段
- [ ] COW 缺页分支 + `CR0.WP`
- [ ] `space_destroy` 改 dec-ref
- [ ] `api 18/19/20`、case 15 退出码、`api_usage`
- [ ] `child_exit` + `wait` + `reap_children` + 孤儿
- [ ] `pit.asm` KILLREQ 判 forked
- [ ] `ps` 显示 parent/zombie
- [ ] FORK/FORK2 程序 + 7 条测试
- [ ] known-issues:FPU、fork+exec、SMP

---

## 5. 附录

### 5.1 内存地图(Phase 2 + Phase 3 之后)

| 地址 | 用途 | 变化 |
|---|---|---|
| 0x1000 | 页目录 `PD_ADDR` | |
| 0x2000 | `PT_LOW`(0–4 MiB,无 USER) | |
| 0x4000 | `PT_LFB` | |
| 0x10000–0x2FFFF | 内核(≤128 KiB) | 涨到 ~95 KiB |
| 0x90000 | 开机栈 | |
| 0x100000 | `FAT_BUF` | |
| 0x110000 | `FILE_BUF` | |
| 0x120000–0x17FFFF | 程序镜像窗口(96 页) | |
| 0x180000–0x3AFFFF | 堆窗口(`SP_HEAPPAGES` 页) | |
| 0x3B0000–0x3BFFFF | PINYIN(IME) | |
| 0x3C0000–0x3C2FFF | USB 帧列表/QH/TD/BOT | |
| 0x3D0000–0x3D1FFF | 页池位图(8 KiB) | |
| **0x3D2000–0x3D9FFF** | **引用计数表(预留 32 KiB,默认用 15 104 B;Phase 3 新)** | 新增 |
| 0x3DA000–0x3FFFFF | 空闲 | |
| 0x400000–0x079FF000 | 页池(默认 30 207 页) | 少 18 页(控制台) |
| 0xFD000000 | VBE LFB | |

### 5.2 TCB 最终布局(144 B)

| 偏移 | 字段 | 偏移 | 字段 |
|---:|---|---:|---|
| 0 | `TCB_ESP` | 76 | `SP_FREED` |
| 4 | `TCB_CR3` | 80 | `SP_HEAPPAGES` |
| 8 | `TCB_STATE` | 84 | `SP_ARGSVA` |
| 12 | `TCB_TICKS` | 88 | `SP_STACKVA` |
| 16 | `TCB_STACK` | 92 | `SP_STACKTOP` |
| 20 | `TCB_NAME` | 96 | `SP_RUNNING` |
| 24 | `TCB_RUNS` | 100 | `SP_STAGE_PA` |
| 28 | `TCB_OWNER` | 104 | `SP_STAGE_PAGES` |
| 32 | `SP_PD` | 108 | `SP_KILLREQ` |
| 36 | `SP_PT` | **112** | **`TCB_CONS`(Phase 2)** |
| 40 | `SP_LIVE` | **116** | **`TCB_CWD`(Phase 2)** |
| 44 | `SP_PAGES` | **120** | **`TCB_PARENT`(Phase 3)** |
| 48 | `SP_IMGBYTES` | **124** | **`TCB_EXITCODE`(Phase 3)** |
| 52 | `SP_PFRUN` | **128** | **`TCB_PFCOW`(Phase 3)** |
| 56 | `SP_PFIMG` | **132** | **`TCB_FLAGS`(Phase 3)** |
| 60 | `SP_PFHEAP` | 136 | 保留 |
| 64 | `SP_FIRSTPA` | 140 | 保留 |
| 68 | `SP_RUNESP` | | |
| 72 | `SP_RUNSTAT` | | |

### 5.3 新增/改动函数一览

| 文件 | 函数 | Phase |
|---|---|---|
| kernel/cons.asm(新) | `cons_init`、`cons_putcp`、`cons_putc_byte`、`cons_newline`、`cons_clear`、`cons_erase_input`、`cons_service`、`cons_repaint`、`kthread_cons` | 2 |
| kernel/vgafont.asm | `term_print_cp`(改一个跳转) | 2 |
| kernel/kmain.asm | `cons_init` 调用、`term_*` 钩子、`layout`、`sched_spawn(kthread_cons)` | 2 |
| kernel/keyboard.asm | `kbd_push/avail/consume/seq_len/getkey/getchar`(每控制台)、`sti/hlt` 等待 | 2 |
| kernel/sched.asm | `sched_noswitch`、`fs_lock/fs_unlock`、`TCB_CONS/CWD`、CWD 同步;`sched_fork`、`child_exit`、`reap_children`、`sched_orphan_children`、`TCB` 扩字段 | 2/3 |
| kernel/shell.asm | `shell_switch_to` 立旗、`cons_service`、`shell_pipe_execute` 加锁、`ps` 显示、`after_prog` 收尸 | 2/3 |
| kernel/fat.asm | 14 个入口 `fs_lock/unlock` | 2 |
| kernel/ata.asm | 读/写扇区 `fs_lock/unlock` | 2 |
| kernel/pipe.asm | `pipe_owner`、`pipe_busy` | 2 |
| kernel/ime.asm | 活动控制台判断、`ime_switch` | 2 |
| kernel/paging.asm | `space_clone`、COW 分支(`pf_err`)、`space_destroy` dec-ref、`CR0.WP` | 3 |
| kernel/pmem.asm | `pmem_ref_get/inc/dec`、alloc/free 接入、`pmem_init` 清表 | 3 |
| kernel/api.asm | 18/19/20、case 15、`api_usage` | 3 |
| kernel/pit.asm | KILLREQ 判 forked | 3 |
| kernel/idt.asm | 14 号分支 `mov ecx,[ebp+36]` 后再调 `page_fault_try_handle` | 3 |
| progs/ | `FORK.C`、`FORK2.C` | 3 |
| tests/qemu_test.py | 12 + 7 条断言、`--fork`、页数公式 | 2/3 |

### 5.4 验收(全部通过才算完)

- [ ] `make` 干净编译,内核 < 128 KiB,开机 `layout` 行含 `cons=16`
- [ ] 4 条 shell 各自 `echo` 不同内容,Ctrl+←/→ 来回切,屏幕互不污染
- [ ] 半行输入切走再切回,内容还在,回车能执行
- [ ] shell 1 `run HANG`、shell 2 `run ECHO` 同时跑;两边按键互不串
- [ ] 从 shell 2 `kill` 掉 shell 1 的程序,shell 1 回到提示符
- [ ] `ps` = 5 alive / 12 slots;`debug pmem` == `expected_free_pages()`
- [ ] IME 组合中切 shell 不花屏、不留条
- [ ] `run FORK.BIN`:父看到 1、子看到 99、`wait` 返回 7
- [ ] 连跑 `FORK2.BIN` 3 次,页池 free 页数不降
- [ ] `ps` 能看到 `zombie`(手工 demo);`wait` 后消失
- [ ] `qemu -m 8` 无页池时 `cons: disabled`,Ctrl+←/→ 仍换键盘,不崩
- [ ] `make test` 全绿(fda/hda/div/pgfault/kbd/shell/font/fat32/usb/fork)

### 5.5 不做什么

| 不做 | 原因 |
|---|---|
| `fork+exec` | exec 要换镜像、重设入口,和当前「镜像窗口 + 暂存区」模型冲突;先让 fork 稳 |
| 每进程页表级的写时复制(PT 共享) | PD/PT 只有 2 页,fork 直接复制更简单,少一层引用 |
| 信号/进程组/会话 | 没有需求;`kill` 已经是「按 tid 杀」 |
| SMP | 单 CPU;`cli`/`invlpg` 够用,没有 TLB shootdown |
| FPU/SSE 上下文切换 | 要再扩 TCB、加 `fnsave/frstor`;Phase 3 明确不做,记进 known-issues |
| 内核线程 fork | API 只从 ring 3 进;shell/cons 线程不 fork |
| 控制台滚动回看(scrollback) | 缓冲只有一屏,滚出去就没了;要回看得加环形历史,内存翻倍 |

---

*文档基于 2026-11 的工作树(Phase 1 已提交前状态)。行号会漂,函数名不会;
对不上时以函数名为锚,`git log -S` 找改动。*
