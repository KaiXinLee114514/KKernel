[English](../process-signal-design.md)

# 进程与信号(process / fork / exec / signal)设计稿

> 状态:设计稿。本阶段(first cut)的**目标**是"能 fork 出子进程、能 exec 换像、能 wait 收尸、
> 能 ps 看见、能 kill 掉、信号能解析并记在位图上"这几件事,不是完整的 POSIX 进程模型。
>
> 参照:`docs/design-multishell-cow.md`(下称"参照稿")。术语、Phase 划分、TCB 现场格式一律沿用;
> 本稿只补它没写的进程表/PCB 字段/exec/wait/信号,并把它规划却未落地的 Phase 3 定成可执行的步骤。
>
> 涉及文件(实现时):新增 `kernel/process.asm`;改 `kernel/sched.asm`、`kernel/paging.asm`、
> `kernel/pmem.asm`(已完成大半)、`kernel/shell.asm`、`kernel/api.asm`、`kernel/pit.asm`、
> `include/kkernel.h`、`Makefile`、`tests/qemu_test.py`。

---

## 0. 定位与术语

### 0.1 三个阶段的分工

| 阶段 | 主题 | 状态 | 本稿关系 |
| --- | --- | --- | --- |
| Phase 1 | 每线程独立地址空间(`space_create/activate/destroy`、按需分页、弹床页) | 已完成 | 直接复用 |
| Phase 2 | 多 shell 虚拟控制台(`cons.asm`、`SH_MAX=4`、Ctrl+Left/Right、每 shell 行编辑缓冲) | 已完成 | 本阶段**保留不动**(见 §3) |
| Phase 3 | fork + 写时复制 | 参照稿只写了设计,本稿落成步骤 | 本稿主体(§1.4–§1.5) |
| 本稿新增 | 进程表/PCB 字段、exec、wait/exit、kill、信号三元组骨架 | 待实现 | §1、§2、§5 |

### 0.2 术语(与参照稿对齐)

| 术语 | 含义 | 代码符号 |
| --- | --- | --- |
| 槽(slot) | 调度表的第 i 项,`i ∈ [0, SCHED_MAX)` | `TCB_OFF(id)` |
| 进程 / 线程 | 本阶段一一对应:一个 TCB 槽就是一个进程;shell 自己也是进程 | `sched_cur` |
| PCB | 进程控制块。**本阶段不另立结构,直接内嵌在 TCB 里** | 见 §1.2 |
| PID | 对外可见的进程号,`pid = 槽号 + 1`(推导值,不占字段) | — |
| 地址空间 | PD + 低端 PT + 若干用户页 + 镜像暂存(staging)页 | `space_*` |
| 镜像暂存页 | `TCB_SP_STAGE_PA` 指的物理页,不在地址空间里,按需分页从这里拷 | `STAGE_PA/STAGE_PAGES` |
| 弹床页 | 0x17F000,里面是 `int 0x30` + 退出路径,程序 `ret` 落回内核 | `tramp_code` |
| 参数页 / 用户栈页 | 堆窗口最后两页,`ARGSVA` / `STACKVA` | `space_user_page` |
| 僵尸 | 已退出、槽还占着等父进程 wait 的进程 | `ST_ZOMBIE` |
| 收尸 | wait 取走退出码、还内核栈、清槽 | `process_wait` |
| 现场 | 被切走时栈上的 `[pushad 32][向量/错误码 8][EIP][CS][EFLAGS][ESP3][SS3]` | `TCB_ESP` |

### 0.3 与参照稿的差异(以本稿为准)

| 项 | 参照稿 | 本稿 | 原因 |
| --- | --- | --- | --- |
| 进程数 | `SCHED_MAX=6` | **16** | 要能同时摆下 4 条 shell + 若干子进程 |
| TCB 大小 | 112,终局规划 144 | **132**(已落地) | 用户定稿的偏移;PARENT/EXITCODE/PENDING/BLOCKED/PFCOW 五个新字段共 20 字节 |
| PID 来源 | 槽号(0 起) | **槽号 + 1**(1..16) | 0 留给"没有父进程";与 shell 提示里的编号区分 |
| 19 号 API | gettid | **wait** | 本阶段没有多线程,gettid 没用 |
| exec | 列为"不做什么" | 做(无 argv) | 要凑 fork+exec |
| 内核线程 fork | 不做 | 仍不做;shell 的 `fork` 走两条特例路(§1.4.4) | 复制内核栈上下文不可靠 |

---

## 1. 进程模型

### 1.1 进程表:16 个槽,PID = 槽号 + 1

- 表就是 `sched.asm` 里的 TCB 数组,`SCHED_MAX = 16`,`TCB_SIZE = 132`,`TCB_OFF(id) = id * 132`。
- 整表静态占 **16 × 132 = 2112 字节(0x840)**,`sched_init` 一次性清零。
- **PID 1..16 就是槽 0..15**,`pid = slot + 1`。PID 1(槽 0)是 0 号 shell;槽 0..3 是 4 条 shell 内核线程
  (PID 1..4);用户程序、fork 子进程从槽 4 起。
- **实现选择:PCB 直接内嵌在 TCB 里**,不建平行表。理由:
  1. 少一张表和一处"表项 ↔ TCB"的同步点,少一个不一致来源;
  2. fork 只要拿到一个空槽,PCB 字段天然跟着 TCB 走(寄存器现场、地址空间、信号位图都在同一块);
  3. `sched_pick`/`sched_kill`/`sched_abandon_current` 一个字都不用改就能继续用;
  4. 设计上仍然**视作 16 项进程表**——`ps` 按槽遍历、PID 由槽号推导,行为与"独立 PCB 表"等价。
- PID 分配:`process_alloc_slot` 从 `SH_MAX` 起线性找第一个 `ST_EMPTY`(shell 槽不参与 fork 分配);
  找不到返回 -1(`sched_live >= SCHED_MAX` 时先判,省一次遍历)。
- **PID 会复用**:槽被 wait 收掉后又被下一个 fork 拿到,旧 pid 就指向新进程。本阶段接受这一点,
  用两条纪律兜住:(a)`kill`/`signal_send` 先校验目标 `STATE != ST_EMPTY`;(b)`wait` 只认
  `TCB_PARENT == 我 && ST_ZOMBIE`,不认 pid 本身。

### 1.2 PCB / TCB 字段

偏移是字节偏移,宽度全部 4 字节(`dd`)。`pid` 是推导值,**不占字段**。

| 偏移 | 符号 | 含义 | 备注 |
| --- | --- | --- | --- |
| 0 | `TCB_ESP` | 被切走时保存的 esp,指向它的现场 | 换栈靠它 |
| 4 | `TCB_CR3` | 它的页目录物理地址 | 程序在跑时是程序自己的 |
| 8 | `TCB_STATE` | 状态,见 §1.3 | 调度器只看这一个 |
| 12 | `TCB_TICKS` | 累计拿过几个 tick | `ps` 显示 |
| 16 | `TCB_STACK` | 内核栈物理基址(2 页,8 KiB) | 死了要还给页池 |
| 20 | `TCB_NAME` | 名字指针 | `ps` 显示 |
| 24 | `TCB_RUNS` | 被调度上去过几次 | `ps` 显示 |
| 28 | `TCB_OWNER` | 出生在哪条 shell 上(0..3) | 键鼠归属;**uid 预留挂靠点** |
| 32 | `TCB_SP_PD` | 程序页目录物理地址(0 = 没在跑程序) | |
| 36 | `TCB_SP_PT` | 私有低端页表物理地址 | |
| 40 | `TCB_SP_LIVE` | 1 = 这套空间正在用 | 缺页补页要看 |
| 44 | `TCB_SP_PAGES` | 空间固定占几页(PD+PT=2) | |
| 48 | `TCB_SP_IMGBYTES` | 这次镜像多少字节(决定 .bss 起点) | |
| 52 | `TCB_SP_PFRUN` | 本次运行补进来几页 | 诊断账 |
| 56 | `TCB_SP_PFIMG` | 其中镜像窗口几页 | 诊断账 |
| 60 | `TCB_SP_PFHEAP` | 其中堆窗口几页 | 诊断账 |
| 64 | `TCB_SP_FIRSTPA` | 第一次补进来的物理页 | 展示用 |
| 68 | `TCB_SP_RUNESP` | 进 ring3 前的内核栈顶(= `TSS.esp0`) | 退出/被杀的落点 |
| 72 | `TCB_SP_RUNSTAT` | 0=正常退出 1=被内核干掉 | |
| 76 | `TCB_SP_FREED` | 收摊时还回去的页数 | 诊断账 |
| 80 | `TCB_SP_HEAPPAGES` | 堆窗口页数(开机算好,spawn 时照抄) | |
| 84 | `TCB_SP_ARGSVA` | 参数页虚拟地址(堆窗口倒数第二页) | |
| 88 | `TCB_SP_STACKVA` | 用户栈页虚拟地址(堆窗口最后一页) | |
| 92 | `TCB_SP_STACKTOP` | 用户栈顶 | |
| 96 | `TCB_SP_RUNNING` | 1 = 正在跑 ring3 程序 | `ps` 标记 |
| 100 | `TCB_SP_STAGE_PA` | 镜像暂存区物理地址 | 按需分页的源 |
| 104 | `TCB_SP_STAGE_PAGES` | 暂存区占几页 | |
| 108 | `TCB_SP_KILLREQ` | 1 = 别的 shell 要求干掉这条线程上的程序 | 保留原语义 |
| **112** | `TCB_PARENT` | 父进程 pid(0 = 壳/孤儿) | **新** |
| **116** | `TCB_EXITCODE` | 退出码(有效性与否看 STATE 是否 ZOMBIE) | **新** |
| **120** | `TCB_PENDING` | 待投递信号位图,bit = 动作号(§2.5) | **新** |
| **124** | `TCB_BLOCKED` | 被屏蔽信号位图,bit = 动作号 | **新** |
| **128** | `TCB_PFCOW` | 这趟运行里 COW 缺页复制了几页 | **新** |

- 132 = 4 的倍数,`imul` 取偏移不用处理余数;`sizeof(TCB)` 与 `TCB_SIZE` 必须同步改。
- **uid 字段位置**:132 已排满,不留空洞。预留方案见 §4.2(下一阶段扩到 140,`TCB_UID=132`/`TCB_GID=136`)。
  本阶段**不加字段**,`TCB_OWNER` 维持"出生 shell"语义。

### 1.3 状态机

| 状态 | 值 | 谁把它设成这个 | `sched_pick` | 说明 |
| --- | --- | --- | --- | --- |
| `ST_EMPTY` | 0 | 开机 / 收尸后 / kill 后 | 跳过 | 可被 fork 分配 |
| `ST_ALIVE` | 1 | `sched_spawn`、fork、`cont` | **可调度** | 唯一可被挑中的状态 |
| `ST_DEAD` | 2 | (保留) | 跳过 | 旧代码遗留,本阶段不用 |
| `ST_ZOMBIE` | 3 | `process_exit` | 跳过 | 等父进程 wait 收;槽+内核栈还占着 |
| `ST_STOPPED` | 4 | `stop` 信号 | 跳过 | `cont` 回到 ALIVE |

```
EMPTY ──spawn/fork──▶ ALIVE ──stop──▶ STOPPED
                        │               │
                        │               └──cont──▶ ALIVE
                        ├──exit──▶ ZOMBIE ──wait──▶ EMPTY
                        └──kill──▶ EMPTY(直接回收)
```

- `sched_pick` 已经只挑 `ST_ALIVE`,所以 STOPPED **不需要改调度器**就自动被跳过(零成本)。
- ZOMBIE 的 TCB 里寄存器现场是死的,但 `TCB_STACK` 两页**必须留着**——它是 wait 之后才还的,
  而且(重要)`process_exit` 收摊时不能还自己脚下这两页,只能留给 wait。

### 1.4 fork:写时复制

#### 1.4.1 页引用计数表(4 bit/页)

pmem 侧已实现,这里只把"契约"钉死,后面 fork 全靠它。

| 项 | 值 |
| --- | --- |
| 位图基址 | `PMEM_BITMAP = 0x3D0000`,8192 字节(65536 位,bit = 页号) |
| 计数表基址 | `REFCOUNT_BASE = 0x3D2000`,**8 KiB**,`REFCOUNT_DWORDS = 2048` dword |
| 粒度 | **4 bit / 页**;字节地址 = `REFCOUNT_BASE + (页号 >> 1)`,偶数页取**低** 4 位、奇数页取**高** 4 位 |
| 值 | 0 = 未分配;1..15 = 被几个地址空间引用;**15 是硬上限** |
| 覆盖 | 2048 dword × 8 nibble = 16384 页;本机 4 MiB 只有 1024 页,余量充足 |
| 溢出 | `pmem_ref_inc` 满 15 返回 **CF=1**,调用方当 ENOMEM 处理 |

| 原语 | 入参 | 出参 | 语义 |
| --- | --- | --- | --- |
| `pmem_alloc` / `pmem_alloc_pages` | 页数 | eax=物理页 / CF | 分配后**计数置 1**(已有) |
| `pmem_ref_set1` | eax=物理页 | — | 清零后置 1(fork 回收用) |
| `pmem_ref_inc` | eax=物理页 | CF=1 表示满 15 | 加一个引用 |
| `pmem_free` / `pmem_free_pages` | eax=物理页 | CF / eax=真还掉的页数 | **改语义:引用计数 -1,归零才清位图 + 改 `free_count`/`alloced`** |

- 语义改动的杀伤面:`pmem_free` 退化成"减引用"后,**再没有"无条件还页"的入口**。所有"我知道它一定只剩
  我一个引用"的地方(开机保留区、加载失败的临时页)仍可照旧调,因为此时计数就是 1 → 行为不变。
- "还在几个引用"的查询本阶段不单独开入口:`pmem_free` 里已经取过 nibble,需要时返回即可,别再加一个
  `pmem_ref_get` 去走第二遍同样的位运算(参照稿列了 get/inc/dec 三个,实际只落 `set1`/`inc`/`free`)。

#### 1.4.2 fork 执行顺序

入口:`process_fork`(由 `int 0x30` 功能 18 调用,`ebx` = `api_stub` 的栈帧基址;`eax` 返回子 pid / -1)。
**顺序是刻意排的:先把所有会失败的事做完,再动父进程的 PTE**,这样任何一步失败都能干净回滚。

1. **判容量**:`sched_live >= SCHED_MAX` → 返回 -1(ENOMEM/进程满)。
2. **找槽**:从 `SH_MAX` 起找第一个 `ST_EMPTY`,得 `child_id`;`child_pid = child_id + 1`。没有 → -1。
3. **预分配 4 页**:子 PD、子低端 PT、子内核栈 2 页(`pmem_alloc_pages`)。任一失败 → 把已分配的全部
   `pmem_free`、返回 -1。
4. **预检**:遍历父 PT 所有 present 用户页,每页 nibble 若为 15 → 释放刚分配的 4 页、返回 -1
   (`cow: too many shared pages`)。放在这里是为了第 6 步 `pmem_ref_inc` 不会中途返回 CF=1。
5. **清 TLB 前准备**:记下父进程的 `frame`(`[frame+16..47]` 是 pushad,`+48` EIP、`+52` CS、
   `+56` EFLAGS、`+60` ESP3、`+64` SS3——参照稿 §4.3.2)。
6. **父页转 COW**(遍历父 PD[0] 指向的 PT 的全部 1024 项,跳过 `present=0` 或 `PAGE_USER=0` 的内核页):
   - `PTE &= ~PAGE_RW`;
   - `PTE |= PAGE_COW`(`PAGE_COW = 0x200`,PTE bit9;bit9 在硬件上是 available 位,不影响分页);
   - `pmem_ref_inc(页物理地址)`。
   参数页和用户栈页也在堆窗口里,**一并被这一遍覆盖**,不需要特判。
7. **staging 页单独 +1**:`TCB_SP_STAGE_PA` 起 `STAGE_PAGES` 页**不在地址空间里**(第 6 步遍历不到),
   必须显式 `pmem_ref_inc`。漏了这一步的后果:父进程退出时 `space_destroy` 把 staging 页还回页池,
   子进程按需分页会读已经归别人的物理页——**静默读到垃圾**,最难查。
8. **复制页表**:`rep movsd` 1024 个 dword,父 PD → 子 PD、父 PT → 子 PT(各整页);
   再 `子PD[0] = 子PT | PAGE_P | PAGE_RW | PAGE_USER`(子进程的页目录项必须可写、用户态可访问)。
9. **搭子进程 iret 现场**(在子内核栈上,`TCB_STACK + 8192` 往下 60 字节):
   子 `TCB_ESP = 栈顶 - 60`。内容从低到高:

   | 帧内偏移 | 内容 | 取法 |
   | --- | --- | --- |
   | +0 .. +27 | pushad 里除 eax 外的 7 个寄存器 | 照抄父 `frame+16` 起 28 字节 |
   | +28 | **EAX = 0** | 子进程的 `fork()` 返回值 |
   | +32 | 向量号/错误码占位 2 个 dword(8 字节) | 0(与切换帧同格式,`popad; add esp,8` 正好跳过) |
   | +40 | EIP | = 父 `[frame+48]`,即 `int 0x30` 的下一条指令 |
   | +44 | CS | = 父 `[frame+52]`(`USER_CS_SEG`) |
   | +48 | EFLAGS | = 父 `[frame+56]` |
   | +52 | ESP3 | = 父 `[frame+60]`(同一个用户栈虚拟地址,共享页,第一次写就 COW) |
   | +56 | SS3 | = 父 `[frame+64]`(`USER_DATA_SEG`) |

   共 60 字节。`pushad` 的存放顺序决定 eax 在 `+28`(与 `api_stub` 的 `[esp+28]` 写回一致)。
10. **填子 TCB**:`STATE=ST_ALIVE`、`CR3=子PD`、`STACK=子栈pa`、`RUNS=0`、
    `OWNER=父OWNER`、`PARENT=父pid`、`EXITCODE=0`、`PENDING/BLOCKED/PFCOW=0`、
    `SP_PD=子PD`、`SP_PT=子PT`、`SP_LIVE=0`、`SP_PAGES`/`IMGBYTES`/`HEAPPAGES`/`ARGSVA`/`STACKVA`/
    `STACKTOP` 照抄父、`SP_STAGE_PA/STAGE_PAGES` 同父(第 7 步已 +1)、
    `SP_RUNESP = 子栈顶`(必须,`TSS.esp0` 要指这儿,后面 ring3 中断才不至于写 0 地址)、
    `SP_RUNSTAT=0`、`SP_RUNNING=0`、`SP_KILLREQ=0`、`NAME` 指 `"child"`。
11. **刷 TLB(必须)**:`mov eax, cr3; mov cr3, eax`。父进程 TLB 里那些页还是
    "可写、不是 COW"的旧项,不刷的话父进程写下去**直接改到共享页**,COW 等于没做。
12. `++sched_live`,返回 `child_pid`。父进程从 API 18 拿到子 pid;子进程下次被 `sched_pick` 挑中时,
    `popad; add esp,8; iret` 回到 ring3,`eax = 0`。

#### 1.4.3 失败与上限

- 失败点只有第 1–4 步和"没有空槽",全在改父 PTE 之前,回滚只需 `pmem_free` 刚分配的 4 页。
- 引用计数上限 15 ⇒ **同一条链上最多 15 个地址空间共享一页**,单链 fork 深度 ≤ 14;
  第 15 个 fork 报 ENOMEM,这是设计约束不是 bug(`fork: too many shared pages`)。
- 子进程建好后立刻被 kill / 父进程立刻退出都不影响:回收走 `space_destroy`(逐页减引用),计数自洽。

#### 1.4.4 三条"fork"入口

| 入口 | 谁在跑 | 走哪条路 | 子进程从哪开始 |
| --- | --- | --- | --- |
| shell 命令 `fork` | 内核 shell 线程 | `process_spawn_demo`:`sched_spawn` 起一个内核例程,补 `PARENT`/`NAME` | 内核演示例程(打印 pid/ppid 后 `exit(7)`) |
| shell 命令 `fork <prog>` | 内核 shell 线程 | `process_fork_exec`:新槽 + 新空间 + 装载 prog + 预搭 iret 帧 | ring3 的 `prog_entry` |
| `int 0x30` 功能 18 | ring3 程序 | `process_fork`(本文 §1.4.2,COW 全流程) | 父进程 `int 0x30` 下一条,`eax=0` |

- **内核线程不做 COW fork**:把 shell 的内核栈现场复制给子进程,子进程返回时会回到"命令解析到一半"的
  内核代码,拿它没辙。所以 shell 的两个 `fork` 命令是特例路:一个 spawn 演示线程,一个直接建"已装好程序的
  新进程"。真正的 COW 只在 ring3 程序自己调功能 18 时发生(FORK.BIN 就是这么测的)。

### 1.5 COW 缺页处理

`idt.asm` 侧:`isr_common` 在 `call page_fault_try_handle` 之前 `mov ecx, [ebp+36]`(错误码;
`[ebp+32]` 是向量号),错误码进函数参数。

`page_fault_try_handle`(已在 `paging.asm`,此处定稿契约):

1. `err & 3 == 3` 才算:bit0 = present(页在)、bit1 = write(写访问)。读缺页、非 present 都不进 COW 分支。
2. 取失败地址对应的 PT 项(`CR2 >> 12` 查表),要求 `PAGE_P` 且 `PAGE_COW`。
3. 分配一新页(`pmem_alloc_pages(1)`),失败 → 打印 `cow: out of memory (page still shared)`、返回 0
   → 上层走"程序被收掉"的老路(`prog_kill_from_fault`),**不 panic**。
4. `rep movsd` 1024 个 dword 整页复制。
5. PTE = `新pa | PAGE_P | PAGE_RW | PAGE_USER`(清 COW,恢复可写)。
6. `invlpg` 刷这一页的 TLB。
7. `pmem_free(旧pa)` —— 在新语义下就是**减一个引用**;别人还在用就只剩位图里的计数变化。
8. `++[TCB_SP_PFCOW]`,`ps` 里能看见这次运行复制了几页。
9. 返回 **1** → `isr_common` iret 回去重新执行那条写指令。

**必须的前提:`CR0 |= 0x80010000`**(bit31 PG + **bit16 WP**,写保护)。
`WP=0` 时内核态(CPL0)写只读页**根本不触发页错误**——fork 之后回到内核态的任何一次写都会
静默修改共享页。WP 位是 COW 的命门,`kmain`/分页初始化里置一次即可。

### 1.6 exec:换像不换进程

入口 `process_exec`(`esi` = 文件名字符串,`dl` = 是否作为 fork 子进程执行,见下)。**不创建新进程**:
PID、槽、`TCB_PARENT` 都不变,换的是地址空间和"从哪条指令开始跑"。

1. 存 `[fat_dir]`(当前目录),`loader_lock`(串行化 ATA 读,和 `cmd_run` 共用一把锁)。
2. 名字解析:补 `.BIN`;`fat_path` 失败再试 `BIN/` 前缀;**沿用 `cmd_run` 里那段,抽成公共例程
   `loader_load_image`**(否则两处各写一遍,迟早不一致)。
3. `fat_stat` 看大小 → `fat_read_file` 读到 `PROG_ADDR = 0x120000`;若是 ELF 走 `elf_load`
   (得 `prog_size` / `prog_entry`)。
4. 还 cwd、**还旧地址空间**:若 `SP_LIVE` 先 `space_deactivate`(换回 `PD_ADDR` 内核页目录),
   再 `space_destroy_at(旧 PD)`;旧 staging 页 `pmem_free_pages`(减引用,可能别人还共享着)。
5. 装载:新 staging 页 `pmem_alloc_pages(stage_pages)`,从 `PROG_ADDR` 拷进去,写 `SP_STAGE_PA/STAGE_PAGES`。
6. `space_create` → `space_set_image(prog_size)` → `space_activate` → `space_prepare_user`
   (弹床页 + 用户栈页,栈顶放弹床地址)。
7. `space_user_page(SP_ARGSVA)`:参数页 `PROG_ARG_STR` 处**写一个 0 字节**(空 argv,见 §1.6.2)。
8. 清 `SP_KILLREQ`、`SP_RUNSTAT=0`、`SP_RUNNING=1`、`SP_RUNESP = esp`、`TSS.esp0 = esp`。
9. `loader_unlock`;段寄存器置 `USER_DATA_SEG`;压 5 个 dword(`SS3/ESP3/EFLAGS|IF/CS3/entry`)后 `iret`。
10. 失败(文件不存在/ELF 坏/页不够):`loader_unlock`、恢复 cwd、**返回 -1 给调用方**,旧地址空间
    此时已经被销毁了 —— 所以调用方(API 24)在 -1 时应当 `process_exit(-1)`,不能假装还能跑。

#### 1.6.1 fork + exec

- 组合方式:父 `fork()` 得子 pid;子进程的返回值是 0,于是子进程在用户态调 `execve`(功能 24),
  子进程"原地"换像;父进程 `wait()` 收尸。这是 Unix 的标准写法,本设计不改。
- shell 的 `fork <prog>` 走 `process_fork_exec`,是**组合好的快速路**:不复制父空间(反正要扔掉),
  直接新槽 → 新空间 → 装载 → 预搭 iret 帧 → 返回 pid。少一次全页复制和一次销毁,也避开
  "内核线程 COW fork"这个坑。

#### 1.6.2 本阶段的 exec 形状

- **只支持无 argv**:参数页 `PROG_ARG_STR` 只写一个 0(`j_arg` 读到空串)。argv/envp 是下一阶段(§6)。
- `process_exec` 单独调用(不经 fork)时,若是 shell 槽上正在跑的程序,等价于 `run`——**本阶段不给
  用户态开 exec 的 API 24**,只在 `process_fork_exec` 里内部调用;API 24 的号段先占住(§5.3)。
- exec 是可选的:`fork` 之后不 exec,子进程就是父进程的副本(COW 保证隔离)。

### 1.7 exit / wait:僵尸与收尸

#### 1.7.1 `process_exit(eax = code)` —— 不返回

1. `edx = TCB_OFF(sched_cur)`(当前进程)。
2. 有地址空间(`SP_LIVE` 或 `SP_PD != 0`)→ `space_deactivate` → `space_destroy_at(SP_PD)`,
   清 `SP_PD/SP_PT/SP_LIVE/STAGE_PA`;staging 页 `pmem_free_pages`。
   **顺序不能反**:先 destroy 会把当前正在用的页表页当垃圾还掉。
3. `STATE = ST_ZOMBIE`,`EXITCODE = code`,`SP_RUNNING = 0`。
4. `process_adopt_children(我的pid)`:把 `PARENT == 我` 的子进程改成 `PARENT = 1`(0 号 shell 收养)。
   不做的话那些子进程永远是"父已死"的孤儿,谁也 wait 不到,槽白占。
5. `sched_abandon_current`:挑下一个 `ST_ALIVE` → 换 `CR3`、`TSS.esp0 = [对方 TCB_SP_RUNESP]` →
   `esp = [对方 TCB_ESP]; popad; add esp,8; iret`。
   **不返回 shell**:fork 出来的子进程退出时不能走 `run_resume_kernel`(那条路会回到 shell 的
   `.after_prog`,销毁的不是它的空间、打的行也是错的,而且会打乱 shell 的状态机)。
6. 一个 ALIVE 都没有 → `sti; hlt` 睡死(和 `sched_abandon_current` 现有行为一致)。
- 统一路径:`process_exit` 对内核线程也成立(演示子进程 `exit(7)`),它没有地址空间,第 2 步跳过;
  它的 `TCB_ESP` 仍然指向一个合法的切换现场,`sched_abandon_current` 一样能切走。
- API 15(`api_exit`)与 API 20 的关系:15 是**程序返回**(弹床页那条路,不一定是进程退出),
  20 是**进程退出**。`api_exit` 里按 `TCB_PARENT != 0` 分流:有父 → `process_exit`,
  无父(shell 直接 `run` 的程序)→ 老路 `run_resume_kernel`。两者最终都回到"当前空间收摊",但收摊人不同。

#### 1.7.2 `process_wait(eax = pid)` —— 返回退出码 / -1

`pid == -1` 表示任意子进程。循环:

1. 扫全部 16 槽,找 `STATE == ST_ZOMBIE && TCB_PARENT == 我的pid && (pid == -1 || pid == 槽号+1)`。
2. 找到:取 `EXITCODE`(存栈上)→ `pmem_free_pages(TCB_STACK, 2)`(内核栈这时才还)→
   **整块 132 字节清零**(等价 `ST_EMPTY`)→ `--sched_live` → 返回退出码。
3. 扫完没有僵尸:
   - 也没有任何"我的子进程"(即不存在 `TCB_PARENT == 我 && STATE != ST_EMPTY`)→ 返回 **-1**
     (`wait: no child`)。
   - 有活的子进程 → `pushfd; sti; hlt; popfd`,然后回第 1 步重扫。
4. **`hlt` 前必须 `sti`**:中断关着 `hlt` 会睡到天荒地老(除非有 NMI);
   唤醒靠 IRQ0(每 tick 都会进),所以最多睡 10 ms 就重扫一次,不需要信号量。
- 竞态说明:第 3 步"检查"和第 2 步"睡下"之间子进程退出,睡眠会照睡到下一个 tick 再重扫——无害
  (只是多睡一个 tick),不需要额外锁。
- 非子进程的僵尸(**kill 路径直接回收的那种,见 §1.8**)永远不会被谁看到,这是刻意的。

### 1.8 kill:三条路

`process_kill(eax = pid)`(shell 的 `kill <pid> [sig]` 和 `int 0x30` 22 号都走它):

1. `pid` 映射槽号;越界或 `STATE == ST_EMPTY` → 返回 -1。
2. `pid == 自己的 pid` → 拒绝(`kill: cannot kill yourself`,shell 里等价于 `cmd_kill` 现在的 "cannot kill")。
3. **shell 槽(`槽号 < SH_MAX`)且 `SP_RUNNING == 1`**:只能置 `TCB_SP_KILLREQ = 1`,
   由 IRQ0 的 `run_resume_kernel` 收摊(**保留原语义**:理由是不敢在别人的 ring3 现场上直接毁栈)。
4. **普通进程**:`space_deactivate`(若 LIVE)→ `space_destroy_at` → staging 页 `pmem_free_pages` →
   `pmem_free_pages(TCB_STACK, 2)` → 清 `TCB_PARENT` 的父进程? 不,先 `process_adopt_children` →
   整块清零 → `--sched_live` → 返回 0。
   这条路**不经过 ST_ZOMBIE**,所以父进程的 `wait` 拿不到它——属于"已被收尸",`wait` 会当成
   没有这个子进程(如果它是唯一的子进程,`wait` 返回 -1)。
5. 目标已经是 ZOMBIE:按第 4 步清掉(顺手收尸),返回 0。

| 目标 | 结果 | 父进程 wait 能拿到吗 |
| --- | --- | --- |
| shell 槽上正在跑的程序 | 置 `KILLREQ`,IRQ0 收摊,打印 killed | 能(走 `run_resume_kernel`,与 run 一样) |
| 普通进程(ST_ALIVE/STOPPED) | 立刻销毁,清槽 | **不能**(已被收尸) |
| ZOMBIE | 清槽 | 不能 |
| 自己 | 拒绝 | — |

---

## 2. 信号模型

### 2.1 三元组:权限类 : 动作 : 级别

信号的规范写法是 `<class>:<action>:<level>`,例:`super:kill:0`、`user:term:2`、`system:stop:1`。
三段的取值互相独立,但语义上互相约束(级别 0 只允许 super、级别 1 只允许 super/system 发……)。
**本阶段不校验发送方权限**,只解析、编码、存字段(§2.8)。

### 2.2 权限类(class)

| 值 | 名字 | 别名 | 本阶段含义 |
| --- | --- | --- | --- |
| 0 | `super` | `root`、`SYSTEM` | 最高;root 与 SYSTEM 都只是它的**别名**,同一 class |
| 1 | `system` | — | 系统级(内核/服务) |
| 2 | `user` | — | 普通用户 |
| 3..15 | 保留 | — | 解析器拒绝 |

- 别名只写在文档和解析器里,**不做身份系统**:没有 uid、没有"谁是 root"的判断(§4)。
- ⚠ 大小写陷阱:`SYSTEM`(全大写)是 `super` 的别名,`system`(全小写)是 class 1。解析器
  **大小写敏感**;shell 提示里建议只用 `super:kill:0`,别让用户写 `SYSTEM`。

### 2.3 动作(action)

| 值 | 名字 | 默认动作 | 本阶段实现程度 |
| --- | --- | --- | --- |
| 0 | (保留) | — | 解析器拒绝,位图 bit0 恒为 0 |
| 1 | `kill` | 立即终止,不可拦截(级别 0) | 完整 |
| 2 | `term` | 终止;可被处理函数捕获 | 只有默认动作(无用户态处理函数) |
| 3 | `stop` | `ST_ALIVE → ST_STOPPED` | 完整 |
| 4 | `cont` | `ST_STOPPED → ST_ALIVE` | 完整(附带把滞留 pending 投递) |
| 5 | `intr` | 中断当前系统调用 | **简化**:只置 pending,不真打断 |
| 6 | `usr` | 用户自定义 | **只置 pending**,留给下一阶段 |
| 7..255 | 保留 | — | 解析器拒绝 |

### 2.4 级别(level)

| 值 | 名字 | 谁能发 | 受 blocked 影响 | 落到位图后的行为 |
| --- | --- | --- | --- | --- |
| 0 | 最高 | 仅 super | 否 | 发送时**立即就地执行**(不等到 tick);kill 用它 = 不可拦截 |
| 1 | 系统级 | super / system | 否 | 置 pending,下个 tick 由 pump 执行 |
| 2 | 用户级 | 任意(本阶段) | 是 | 置位即执行;被 blocked 时滞留 pending,解除后执行 |
| 3 | 提示级 | 任意(本阶段) | 是 | 只置 pending;**内核不产生动作**(usr/intr 本来就没有内核动作) |

- 级别决定的三件事只有:①发送门槛(本阶段不校验);②是否看 blocked;③级别 0 立即执行。
- 位图里只有"动作号",没有级别。**严格区分 1/2/3 需要 pending 带级别(三元组队列),那是 sigaction
  阶段的事**;本阶段用"发送时决定行为"绕开这个缺口,语义上仍然自洽(级别 3 配 kill 没有意义,配 usr
  就是"记一笔")。

### 2.5 `signal_t` 32 位编码与解析

| 位 | 宽度 | 含义 |
| --- | --- | --- |
| 31..24 | 8 | 权限类(0..15 有效) |
| 23..16 | 8 | 动作(1..6 有效) |
| 15..0 | 16 | 级别(0..3 有效) |

| 文本 | class | action | level | `signal_t` |
| --- | --- | --- | --- | --- |
| `super:kill:0` | 0 | 1 | 0 | `0x00010000` |
| `system:term:1` | 1 | 2 | 1 | `0x01020001` |
| `user:term:2` | 2 | 2 | 2 | `0x02020002` |
| `system:stop:1` | 1 | 3 | 1 | `0x01030001` |
| `super:cont:1` | 0 | 4 | 1 | `0x00040001` |
| `user:intr:2` | 2 | 5 | 2 | `0x02050002` |
| `user:usr:3` | 2 | 6 | 3 | `0x02060003` |

`process_signal_parse`(`esi` = ASCII 串,`eax` = `signal_t`,`CF = 1` 表示语法错):

1. 跳过前导空格;空串 → 错。
2. 比 class:`super` / `root` → 0;`SYSTEM` → 0(全大写);`system` → 1;`user` → 2。
   最长匹配优先(`super` 与 `system` 不共享前缀,但 `s...` 要按长度比),必须紧跟 `:`。
3. 比 action:`kill`/`term`/`stop`/`cont`/`intr`/`usr` → 1..6,必须紧跟 `:` 或串尾。
4. 读 level:1–2 位十进制数字,范围 0..3;出现非数字或 >3 → 错。
5. 允许结尾空白,多余字符 → 错。
6. `eax = class << 24 | action << 16 | level`;`CF = 0`。
- 解析器**不写任何状态**(纯函数),`kill` 命令里解析失败就回落到默认 `super:kill:0` 并提示一行。

### 2.6 pending / blocked 位图与投递

- 两个 32 位字,bit = **动作号**:bit1 kill、bit2 term、bit3 stop、bit4 cont、bit5 intr、bit6 usr;
  bit0 与 bit7..31 恒 0。有效掩码 `SIGNAL_ACTIONS = 0x007E`。
- 发送:根据级别决定是否被 blocked 挡住(级别 0/1 直接无视 blocked)→ 置 `PENDING` 位;级别 0 立刻执行。
- 投递点(`process_signal_pump`,**内核唯一消费 pending 的地方**):
  - 在 `kernel/pit.asm` 的 `irq0_stub` 里,EOI 之后、`sched_pick` 之前
    (`call process_signal_pump_current`),对当前进程的 `PENDING & ~BLOCKED` 逐位执行;
    执行完清位。**pump 必须保全所有寄存器**(中断路径上不能弄脏别人的现场):
    `pushad`/`popad`,或者只碰约定允许破坏的那几个。
  - `process_signal_send` 里,级别 0 的就地执行也走同一段(抽成 `process_signal_apply`)。
  - `cont` 之后、`signal_block` 解除屏蔽之后,各调一次 pump(把滞留的补上)。
- **级别 0 的"立即"意味着在发送方上下文里终止目标**:目标一定是别的进程(自己发给自己被 §1.8 第 2 步
  拒掉常规路径),清槽安全;若目标当前正在 ring3 跑,走的还是 §1.8 第 4 步(直接销毁)。
  杀当前进程的路径必须是"**跳走**"(`jmp sched_abandon_current`),不能 `ret`——返回地址在即将废弃的栈上。

### 2.7 动作语义(照抄用户定稿,逐条对应实现)

| 动作 | 语义 | 实现落点 |
| --- | --- | --- |
| `kill` | 立即终止;级别 0 不可拦截,连 blocked 都不看 | `process_kill(pid)`;`ST_ZOMBIE` 都算"终止过" |
| `term` | 可被用户态处理函数捕获;**本阶段没有处理函数 → 默认动作 = 终止** | 同 kill,但留 `process_signal_deliver_user` 的空壳 |
| `stop` | `STATE = ST_STOPPED`;调度器(已只挑 ALIVE)自动跳过 | 写字段即可 |
| `cont` | `STATE = ST_ALIVE`,然后 pump 一次把滞留的 pending 投掉 | `sched_live` 不变 |
| `intr` | 中断当前系统调用 | 简化:只置 pending / 清位,不碰 api_dispatch 的现场 |
| `usr` | 用户自定义 | 只置 pending,留给下一阶段 sigaction |

- `stop` 对 shell 槽:允许,但 shell 停下就没人读键盘了(整条 shell 冻住)。这是**设计上接受**的副作用,
  测试别对 shell 发 stop。
- 对 `ST_ZOMBIE` 发信号:只置 pending,没有动作(僵尸不会再被调度);`wait` 之后位图随槽清零。

### 2.8 本阶段边界(明确不做)

- **不做权限校验**:不检查发送方 class 是否够格,`user` 也能发 `super:kill:0`(级别只用于编码与
  blocked 判断)。这是给下一阶段多用户留的坑,不是疏忽,写在这里免得被当 bug。
- 不做 pending 的**队列化**(同一动作连发两次只记一次)、不做信号编号(SIGKILL/SIGTERM 那套)、
  不做信号屏蔽的父进程继承(blocked 在 fork 时清零,见 §1.4.2 第 10 步)。
- 不做 `intr` 的真打断(那要能在 `api_dispatch` 中途 unwind 回 ring3)。

---

## 3. 与多 shell 的关系

**本阶段暂时保留多 shell,一行不删。**

| 项 | 现状 | 本阶段 |
| --- | --- | --- |
| shell 条数 | `SH_MAX = 4`,槽 0..3 四条内核线程 | 保留;PID 1..4 |
| 切换 | `Ctrl+Left/Right`,`sh_active` 决定谁收键盘 | 不动 |
| 键盘归属 | `sh_active` | 不动 |
| 每 shell 行编辑缓冲 | 每线程一份 | 不动 |
| shell 的 PID | 槽号(0..3) | **1..4**(+1) |
| `ps` 的槽数 | 6 | 16 |
| 杀 shell 上正在跑的程序 | 置 `KILLREQ`,`IRQ0` 收摊 | 原样保留(§1.8 第 3 步) |

- 每条 shell 自身也是一个进程(PID 1..4),有 `TCB_PARENT = 0`、有 `TCB_OWNER = 自己`。
- fork 出的子进程**不占 shell 槽**:`process_alloc_slot` 从 `SH_MAX` 起找,shell 槽永远留给 shell。
- 子进程的"终端"归属:继承父的 `TCB_OWNER`,`ps` 里看得见;但**输出仍然走全局光标/屏幕**
  (Phase 2 的虚拟控制台只管 shell 自己的行编辑,不管子进程)。这是已知的粗糙点,下一阶段
  (§6"shell/控制台简化")再处理,**本阶段不动键盘与切换逻辑**。

---

## 4. 与多用户 / 权限的关系

### 4.1 本阶段做什么、不做什么

| 项 | 本阶段 |
| --- | --- |
| `signal_t` 里的权限类字段 | **设计进去**(8 位,0/1/2 有效) |
| 解析/编码/存储权限类 | **做** |
| 发送时的权限校验(发送方 class 够不够) | **不做** |
| root / SYSTEM 身份映射 | **不做**,只写别名关系(§2.2) |
| 进程的 uid/gid | **不做**,只预留字段位置(§4.2) |
| 文件权限位、`TCB_OWNER` 的权限含义 | **不做**,维持"出生 shell"语义 |

### 4.2 uid 字段的预留位置

132 字节已排满(0..131 全是字段,无空洞)。下一阶段落地多用户时的方案:

| 方案 | 做法 | 代价 |
| --- | --- | --- |
| **A(采用)** | `TCB_SIZE` 132 → **140**,新增 `TCB_UID = 132`、`TCB_GID = 136` | 改一个 `equ` + `sched.asm` 里 16×132 的静态缓冲区(2112 → 2240 字节);`TCB_OFF` 自动跟着变,其它偏移不动 |
| B | 复用 `TCB_OWNER` 高字节当 uid 提示 | 不改大小,但语义混杂、`OWNER` 同时表达"哪条 shell"和"谁",不可取 |

- 本阶段**不加字段**,`TCB_OWNER` 保持 0..3 的"出生 shell 编号"。
- `signal_t` 的 class 与将来 uid 的对应:uid 0 ↔ class 0(super),系统账号 ↔ class 1,普通用户 ↔ class 2。
  这条映射现在只写在文档里,代码不查。

### 4.3 身份判定的接口预留

将来 `process_signal_check_sender(sig)` 的签名先想好:`eax = signal_t`,`CF = 1` 表示"不许发"。
本阶段这个函数**不存在**;`process_signal_send` 里留一行注释指到这里,下一阶段直接填实现。

---

## 5. 分阶段实施计划

### 5.1 本阶段(first cut)清单

| # | 内容 | 落点 | 完成判据 |
| --- | --- | --- | --- |
| 1 | 进程表 16 项、五个新字段、`pid = 槽+1`、状态机 | `kernel/sched.asm`(已改) | `ps` 打 16 槽;`sizeof(TCB)=132` |
| 2 | 引用计数表 + `pmem_free` 改减引用语义 | `kernel/pmem.asm`(已改) | fork 后 `debug pmem` 的 free 数不暴跌 |
| 3 | `PAGE_COW`、COW 缺页、`CR0.WP` | `kernel/paging.asm`(已改)/`idt.asm`/`kmain` | FORK.BIN 父子互不串页 |
| 4 | `process_fork`(COW 全流程) | 新 `kernel/process.asm` | 功能 18 返回父 pid / 子 0 |
| 5 | `process_exec`(无 argv) | 同上 | `fork FORK.BIN` 能跑起来 |
| 6 | `process_exit` / `process_wait` / 收养孤儿 | 同上 | 子退出 → ZOMBIE → wait 拿到码 |
| 7 | `process_kill`(三条路) | 同上 | `kill 5` 后 ps 里没了 |
| 8 | 信号:解析/编码/发送/pending/blocked/pump/stop/cont | 同上 + `pit.asm` | `kill 5 user:term:2` 生效 |
| 9 | shell 命令 `ps`/`fork`/`fork <prog>`/`wait`/`kill <pid> [sig]` | `kernel/shell.asm` | 见 §5.2 |
| 10 | API 18–23 + `kkernel.h` 包装 | `kernel/api.asm`、`include/kkernel.h` | 见 §5.3 |

### 5.2 shell 命令

| 命令 | 行为 | 输出约定(测试要认的字符串) |
| --- | --- | --- |
| `ps` | 遍历 16 槽打一行一进程 | 头 `N alive / 16 slots`;行 `[pid] name ppid=P st=ALIVE ticks=N runs=M` |
| `fork` | 内建演示子进程(spawn 内核例程) | `fork: child pid=5 ppid=1`,子进程自己打 `child: pid=5 ppid=1`,然后 `exit(7)` |
| `fork <prog>` | 新进程 + 新空间 + 装载 prog,子进程从 ring3 开始 | `fork: pid=5 /prog 已装载`(单行) |
| `wait` | 等任意子进程,打退出码 | `wait: pid=5 exit=7`;无子进程 `wait: no child` |
| `kill <pid>` | 默认信号 `super:kill:0` | 成功 `kill: pid=5 killed`;失败 `kill: no such process` / `kill: cannot kill yourself` |
| `kill <pid> <class>:<action>:<level>` | 先 `process_signal_parse`,失败回落默认并提示 | `kill: bad signal "..."` |

- `ps` 的行格式**保留 `[id] name ticks=N` 前缀**(已有测试正则 `\[(\d)\] (alpha|beta)\s+ticks=(\d+)`
  依赖它),`ppid=`/`st=` 追加在后。只把表头 `6 slots` 改成 `16 slots`。
- `kill` 的 pid 解析沿用 `cmd_kill` 现有的十进制解析,`0` 视为"自己"→ 拒绝。

### 5.3 系统调用(`int 0x30`)与 `kkernel.h`

`api_stub` 的写回约定不变:只写回 `eax`/`ebx`/`esi`;`ecx`/`edx`/`edi`/`ebp` 用户侧只读。

| 号 | 名字 | 用户入参 | 返回(`eax`) | 内核实现 | 备注 |
| --- | --- | --- | --- | --- | --- |
| 0–17 | 现有 | — | — | — | 不动 |
| 18 | `fork` | — | 父:子 pid;子:0;失败 -1 | `process_fork` | `ebx` 传 `api_stub` 帧基址(内部用) |
| 19 | `wait` | `ebx = pid`(`-1` = 任意) | 退出码 / -1 | `process_wait` | |
| 20 | `exit` | `ebx = code` | 不返回 | `process_exit` | 与 15 同实现,15 是"程序返回"、20 是"进程退出" |
| 21 | `getpid` | — | pid(1..16) | `process_getpid` | |
| 22 | `signal_send` | `ebx = pid`,`ecx = signal_t` | 0 / -1 | `process_signal_send` | 内核侧约定:`eax=pid, ebx=sig` |
| 23 | `signal_block` | `ebx = 位图`(bit = 动作号) | 新的 `BLOCKED` | `process_signal_block` | 简化版:直接覆盖位图,置位=屏蔽;解除后 pump 一次 |
| 24 | `exec` | `esi = 文件名` | 不返回 / -1 | `process_exec` | **本阶段只给 `fork <prog>` 内核路径用**,用户态先不开放 |

`include/kkernel.h` 新增 `static inline` 包装:

```
j_fork()            -> eax            0 / 子pid / -1
j_wait(pid)         -> eax            退出码 / -1
j_exit_code(code)   -> 不返回         ← 注意!别叫 j_exit
j_getpid()          -> eax
j_signal_send(pid, sig)  -> eax
j_signal_block(mask)     -> eax
```

- **命名冲突**:`j_exit(const char *msg)` 已经存在,语义是"清屏 + 打一行",**不调 API 15**。
  进程退出必须另起名字(`j_exit_code` 或 `j_proc_exit`),否则将来有人改 `j_exit` 的实现会把
  一堆程序的返回值改成 0。
- 宏风格照抄 `KK_SYSCALL0`/`KK_SYSCALL1`;`signal_t` 在 C 侧就是 `uint32_t`,不引入结构体。

### 5.4 建议实现顺序(每步都能单独编、单独测)

1. `sched.asm`:确认 132/16 与五个新字段编得过,`ps` 打 16 槽(shell 槽 0..3 正常)。
2. `pmem.asm`:确认 `pmem_free` 减引用语义下,开机内存账不变(`debug pmem` 前后一致)。
3. `paging.asm` + `idt.asm`:COW 分支 + `CR0.WP`;先手动造一个"父写 COW 页"的场景,看 `PFCOW` 涨。
4. `process.asm`:只做 `process_alloc_slot` / `process_getpid` / `process_exit` / `process_wait`,
   配 `fork`(演示,spawn 路)和 `wait` 两条 shell 命令 → 先跑通"生一个进程、收一个退出码"。
5. `process_fork`:COW 全流程 + 功能 18;用 FORK.BIN 验父子隔离。
6. `process_kill` + `kill` 命令;验 shell 槽与普通进程两条路。
7. 信号:解析 → 编码 → `send`(级别 0 立即、级别 2 滞留)→ `pump`(IRQ0)→ `stop/cont`;
   最后 `signal_block`。
8. `process_fork_exec` + `fork <prog>`;API 24 内部调用。
9. `ps` 行格式 + 表头 16 槽;`tests/qemu_test.py --proc`;`Makefile` 的 `test-proc`。
10. 回归:`make -s test-hda` 20/20、`make test-shell`、`make test-hd-font`。

### 5.5 测试怎么加

`tests/qemu_test.py`:

| 项 | 内容 |
| --- | --- |
| 开关 | `proc_mode = "--proc" in argv`;在 `argv` 过滤列表里加 `"--proc"`(否则会被当成镜像路径) |
| 位置 | 放在 `hd_mode`(`--fontdisk`)那一段之后,单独一个 `if proc_mode:` 块;复用 `run` / `wait_idle` / `rescan` / `has` 那套辅助函数(和 `shell`/`hd` 段一样) |
| 镜像 | 必须是 **HDIMG**(FORK.BIN 在盘上),所以 `--hda --fontdisk` 一起给 |

断言(全部按屏幕文字认,和现有用例风格一致):

| # | 断言 | 期望文本 |
| --- | --- | --- |
| 1 | fork 的计数与父子关系 | FORK.BIN 打出 `parent: shared=1 wait=7`(父进程自己的值)、`child: shared=99`(子进程改过自己那份) |
| 2 | COW 父子页面隔离 | 上面两行同时出现 → 说明父写没串到子、子写没串到父 |
| 3 | `ps` 出现父子 | 正则 `\[(\d+)\] (FORK|child).*ppid=(\d+)` 且父行 `ppid=1` |
| 4 | 子进程退出后是僵尸 | `ps` 里 `st=ZOMBIE`;`wait` 之后 `ps` 里该 pid 消失 |
| 5 | wait 拿到退出码 | `wait: pid=N exit=7` |
| 6 | kill 终止 | `kill N` → `kill: pid=N killed` → `ps` 里没有 N |
| 7 | 信号语法解析 | `kill N super:kill:0` 被接受;`kill N user:term:2` 被接受;`kill N bogus:x:0` 打 `bad signal` 且进程还在 |
| 8 | stop / cont(可选) | `kill N system:stop:1` 后 `ps` 里 `st=STOPPED`,再 `system:cont:1` 回 `st=ALIVE` |

`Makefile`:

```
test-proc: $(HDIMG)
	$(MAKE) -s -B $(HDIMG)
	python3 -u tests/qemu_test.py $(HDIMG) --hda --fontdisk --font font/full-kkf.bin --proc
```

- `test-proc` 加进 `.PHONY`;`test:` 目标里也串上(可选,跑得慢的话先只留手动)。
- 用 `$(HDIMG)` 而不是 `$(IMG)`:FORK.BIN 必须能从 FAT 盘上读到;`$(MAKE) -s -B` 是为了把
  `progs/FORK.BIN` 的改动重新打进镜像。
- **`test-hda` 必须保持 20/20**:它跑的是软盘路径,和进程无关,但 `ps` 表头里的槽数改了之后,
  **任何写死 `6 slots` 的用例都要跟着改**(`shell` 模式下 `ps_rows()` 里就有 `"alive / 6 slots"`,
  以及 `ids == [4, 5]` 这种按旧 `SCHED_MAX` 写的断言)。

### 5.6 已知坑(实现时按这个清单自查)

1. fork 之后**必须刷 CR3**,否则父进程 TLB 里还留着"可写"的旧页表项,COW 静默失效。
2. **`CR0.WP`(bit16)必须置位**,否则内核写只读页不触发缺页,COW 只对 ring3 生效——半残。
3. 引用计数满 15 时 fork 失败:**预检放在改 PTE 之前**,不然回滚要把父进程的 PTE 一位位改回去。
4. **staging 页要单独 `pmem_ref_inc`**,它不在地址空间里,遍历 PT 时看不见。
5. `TSS.esp0` 必须在切进 ring3 前指向新栈顶(fork 子进程是 `栈顶`,不是 `栈顶-60`)。
6. `wait` 里 `hlt` 前必须 `sti`,否则睡死(除非有 NMI);用 `pushfd/sti/hlt/popfd` 包起来。
7. `process_exit` 里 **先 `space_deactivate` 再 `space_destroy`**,顺序反了会回收正在用的页表页。
8. `process_exit` 不能 `ret`:返回到即将被 wait 回收的栈上是未定义行为,一律 `jmp sched_abandon_current`。
9. 杀当前进程的路径(信号 pump 里)同理,必须跳走。
10. 内核线程**不做 COW fork**(§1.4.4);shell 的 `fork` 走特例路,别图省事复用 `process_fork`。
11. `ps` 的既有正则依赖 `[id] name ticks=` 前缀,**追加字段可以、改前缀会挂测试**。
12. `j_exit` 名字被占(§5.3),新增包装叫 `j_exit_code`。
13. 孤儿必须被收养(`process_adopt_children`),否则父进程退出后子进程永远无人 wait,槽泄漏。
14. fork 子进程的 `TCB_ESP` 现场同时是"第一次被调度"的入口和"被切走后恢复"的现场,
    两者格式相同(60 字节),别再单独造一套。
15. 信号 pump 在 IRQ0 里跑,**必须保全寄存器**;它的输出没有任何返回空间。

### 5.7 后续阶段

| 阶段 | 内容 | 依赖 |
| --- | --- | --- |
| 4 | `sigaction`:用户态处理函数、真正的信号帧(进处理函数前把 `EIP/ESP` 改到用户注册的地址)、`term` 可捕获 | 本阶段位图与动作语义 |
| 4 | 真正 `intr`:在 `api_dispatch` 中途 unwind 回 ring3,系统调用返回 `EINTR` | 需要 api 层记录"可打断点" |
| 5 | 多用户身份:uid/gid、`TCB_UID/GID`、class 校验(`process_signal_check_sender`)、文件权限位 | 本阶段的 class 编码与预留位置 |
| 5 | `exec` 的 argv/envp:参数页从"一个 0 字节"扩成 `argc/argv[]/envp[]` 结构 | `process_exec` 与 `j_arg` |
| 6 | 进程组 / 会话:会话首进程、前后台进程组、`Ctrl+C` 发给前台组、`TCB_PGID/TSID` | 多 shell 与控制台简化 |
| 6 | shell / 控制台简化:每 shell 只留一个前台进程、`wait` 与作业控制、去掉 `SH_MAX` 的四线程模型 | Phase 2 的虚拟控制台 |
| 7 | SMP:每 CPU 一个 `sched_cur`、`sched_live` 原子化、`loader_lock` 换自旋锁 | 全部 |
| — | FPU/SSE 上下文保存、内核线程 fork、`ST_DEAD` 清理 | 低优先 |

---

## 6. 接口预留(本阶段未实现)

下面这些是**设计上已经留好位置、代码里明确没有**的东西。写实现时别顺手加,加之前先回这一节改文档。

| # | 预留项 | 位置 | 本阶段状态 | 下一阶段怎么接 |
| --- | --- | --- | --- | --- |
| P1 | `TCB_UID` / `TCB_GID` 字段 | TCB 132 之后(132/136),`TCB_SIZE` → 140 | 不加字段 | 改一个 `equ` + 静态缓冲区大小(§4.2) |
| P2 | 发送方权限校验 `process_signal_check_sender` | `process_signal_send` 里留注释 | 无此函数,不校验 | 填实现,`CF=1` 拒发 |
| P3 | class ↔ 身份的映射(root/SYSTEM/user) | §2.2 别名表、§4.3 | 只有文档映射 | 接 uid 系统,`uid==0 → class 0` |
| P4 | 级别 1/2/3 的严格区分 | `TCB_PENDING` 只有动作号 | 只能用位图,"发送时定行为"绕开 | pending 改三元组队列(动作+级别+来源) |
| P5 | `sigaction`:用户态处理函数 | `term` 的默认动作 | 只有"默认=终止",无处理函数 | 用户态注册函数表,投递时改用户栈与 EIP |
| P6 | 真 `intr`:打断系统调用 | `api_dispatch` | 只置 pending,不打断 | 在 syscall 入口埋可打断点,返回 `EINTR` |
| P7 | `usr` 动作的用户自定义处理 | `process_signal_apply` | 只置 pending | 与 P5 合并 |
| P8 | `exec` 的 argv/envp | 参数页 `PROG_ARG_STR` | 只写一个 0 字节 | 参数页改成 `argc/argv[]/envp[]` 布局,`j_arg` 跟改 |
| P9 | 用户态 `exec` API(功能 24 开放) | `api_dispatch` 24 号 | 只给内核 `fork <prog>` 用 | 开放 DPL3 调用 + `-1` 时自杀语义 |
| P10 | 进程组 / 会话(`TCB_PGID`/`TSID`) | TCB 再扩 8 字节 | 无字段 | P1 一起扩,`Ctrl+C` 发给前台组 |
| P11 | 作业控制(前台/后台、`SIGTTIN`/`SIGTTOU`) | 无 | 无 | 依赖 P10 + shell 简化 |
| P12 | shell/控制台简化(`SH_MAX` 收敛、每 shell 单前台) | `shell.asm`/`cons.asm` | **本阶段不动**(§3) | 单独阶段,先做完 P10 |
| P13 | SMP 支持 | `sched.asm` | 单核假设 | `sched_cur` 每 CPU、`sched_live` 原子化 |
| P14 | 僵尸队列 / `reap_children` 批量收尸 | `process_wait` | 线性扫 16 槽(够用) | pid 多了再换队列 |
| P15 | FPU 上下文、内核线程 fork、`ST_DEAD` 清理 | — | 不做 | 低优先 |

## 7. wait 状态为什么不能放全局(Phase D wait-race)

`process_wait2` 会**在系统调用里睡觉等子进程退出**。睡眠期间这个线程的内核栈还在
(调度器切线程只换 `TCB_ESP`,内核栈不在睡眠期间回收),别的线程随时可能进来执行
同一个函数。如果"这次 wait 的参数/睡眠通道/出参"放在跨线程共享的全局变量里
(旧实现的 `pw_pid`/`pw_flags`/`pw_tcb`/`pw_sleeping` + `proc_wait_status`/
`proc_wait_pid`/`proc_wait_code`/`proc_last_*`),两个线程同时 wait 就会互相覆盖:

- 睡眠通道被改 → 唤醒丢 / `sched_sleep_cancel` 撤错睡眠;
- 收尸对象被改 → 收到别人的孩子 / 对已经清掉的 TCB 再收一遍;
- `proc_wait_*` 被后一个 waiter 覆盖 → 调用者拿到别人的退出码、页数。

修法(当前实现):

1. **睡眠期间的现场放本线程内核栈帧**。`process_wait2` 入口 `pushad` 后
   `sub esp, PW_FRAME`,参数、`PW_SELF`(本线程 TCB 指针,兼作 sleep channel)、
   `PW_SLEEPING` 全在帧里;`sched_sleep_prepare/commit/cancel` 只认这个通道。
2. **事件出参写本线程 TCB**。`TCB_SIZE` 200→240,新增
   `TCB_WAIT_STATUS`/`TCB_WAIT_PID`/`TCB_WAIT_CODE`(本次 wait 的事件)和
   `TCB_LAST_CHILD`/`LAST_FREED`/`LAST_RUNSTAT`/`LAST_PFRUN`/`LAST_PFIMG`/
   `LAST_PFHEAP`/`LAST_FIRSTPA`(收尸快照,给 `cmd_run` 打印作业结果用)。
   `process_wait`、`process_wait_status_get`、`process_last_child_get`、
   `process_last_snapshot` 都经 `process_cur_tcb()` 读当前线程的 TCB,
   线程之间没有共享的 wait 状态。
3. **以后同类"阻塞系统调用的现场"一律照此办理**:本线程内核栈帧 + 本线程 TCB,
   放不下再扩 `TCB_SIZE`(所有步长走 `TCB_SIZE` 宏 / `TCB_OFF`,不要硬编码)。
   `--wait-race` 用两个并发实例各 fork/wait 50 轮做回归:两个父线程同时卡在
   `process_wait2` 里,任何跨线程串扰都会在退出码上暴露(顺便还会用 shell 的
   `jobs` 扫描制造第三个并发 waiter)。

---

---

*本稿的偏移/函数名/API 号与 `kernel/sched.asm`(SCHED_MAX=16、TCB_SIZE=240(Phase D wait-race 后))、
`kernel/pmem.asm`(REFCOUNT_BASE=0x3D2000)、`kernel/paging.asm`(PAGE_COW=0x200)对齐。
若实现中改了这些常量,先改本稿再改代码。*
