; ============================================================================
;  KKernel — 调度器:内核线程 + 抢占式轮转
;
;  在这之前,系统里只有一个"执行流":shell 敲命令 → 程序跑 → 回到 shell。
;  PIT 每 10 ms 敲一次 IRQ0,但我们只是数了个 tick 就返回了。这个文件把那次
;  中断变成"换人的机会":中断进来时 CPU 的现场已经在栈上了,只要我们把这个
;  esp 存起来、换成另一个线程的 esp,再按原路 popad + iret 回去 —— 回去的
;  就已经是另一个线程了。**OS 里的"并发"说白了就是这一下换栈。**
;
;  为什么能这么干:每个线程的栈上都有一份一模一样的现场
;     [pushad 八个寄存器][向量号][错误码][eip][cs][eflags]
;  (新线程的那份是我们自己搭出来的,见 sched_spawn)。所以"切线程"不需要什么
;  神奇的指令,只要 esp 指着谁的现场,iret 就回谁那儿去。
;
;  谁在管:irq0_stub(pit.asm)在 pushad 之后调 sched_pick ——
;    1. 把当前 esp / cr3 存进当前线程的 TCB
;    2. 时间片到了就从 sched_cur+1 开始找下一个活着的线程(轮转)
;    3. 返回它的 esp,stub 里一句 `mov esp, eax` 就换过去了
;  顺序上有个坑:p 必须**先发 EOI 再切** —— 不然新线程跑起来时 PIC 还在等这
;  一次的 EOI,IRQ0 就再也不来了(定时器"死"了,但屏幕上看不出来)。
;
;  老实交代的局限(玩具够用,别当正经调度器):
;    · 线程默认共用内核地址空间,但 ring3 程序有**自己**的:地址空间状态现在
;      也在 TCB 里(TCB_SP_*),每条 shell 线程都能各跑各的程序 —— 见 paging.asm
;      的 space_cur 和 sched_pick 里的切换
;    · 内核不是可重入的:线程最好只算自己的、只打印,别一起去读写文件系统
;      (FAT/ATA 那些全局缓冲会被互相踩)
;    · 打印会互相插队:两个线程同时 term_print,字可能串行(不崩,但难看)
;    · 没有优先级、没有阻塞队列、没有真正的 sleep 队列 —— 想等就 pit_wait_ticks
;    · 杀不掉"正在跑的线程"(0 号 = shell 自己):它还在用那条栈
; ============================================================================

SCHED_MAX         equ 16                ; 最多几个进程/线程(含 0 号 = shell 自己)
TCB_SIZE          equ 192               ; 每个 TCB 192 字节(A2/A3+B:身份/优先级/睡眠/进程组,见 /4、imul)
TCB_ESP           equ 0                 ; 被切走时保存的 esp(指向它的现场)
TCB_CR3           equ 4                 ; 它的页目录(程序在跑时可能是程序自己的)
TCB_STATE         equ 8                 ; 见下面的 ST_*
TCB_TICKS         equ 12                ; 它一共拿到过几个 tick
TCB_STACK         equ 16                ; 栈的物理基址(死了要还给页池)
TCB_NAME          equ 20                ; 名字(给 ps 看的)
TCB_RUNS          equ 24                ; 被调度上去过几次
TCB_OWNER         equ 28                ; 它出生在哪条 shell 上

; ---- 地址空间状态:每线程一份 ----
; 以前这些是 paging.asm 里的全局变量,于是全系统只允许一个程序;现在搬进 TCB,
; space_cur 指向"当前线程的这一块",space_* 例程都通过它读写。
; 注意 TCB_CR3 仍然是"真正写进 CR3 的那个页目录",切换时和这里配套。
TCB_SP_PD         equ 32                ; 程序页目录物理地址(0 = 没在跑程序)
TCB_SP_PT         equ 36                ; 它私有的低端页表
TCB_SP_LIVE       equ 40                ; 1 = 这套空间正在用(14 号页错误才补页)
TCB_SP_PAGES      equ 44                ; 这套空间固定占几页(页目录 + 页表 = 2)
TCB_SP_IMGBYTES   equ 48                ; 这次镜像多少字节(决定 .bss 从哪开始)
TCB_SP_PFRUN      equ 52                ; 这一次运行补进来几页
TCB_SP_PFIMG      equ 56                ; 其中镜像窗口几页
TCB_SP_PFHEAP     equ 60                ; 其中堆窗口几页
TCB_SP_FIRSTPA    equ 64                ; 第一次补进来的物理页(展示用)
TCB_SP_RUNESP     equ 68                ; 进 ring3 前的内核栈顶(退出/被杀回这儿)
TCB_SP_RUNSTAT    equ 72                ; 0 = 正常退出,1 = 被内核干掉
TCB_SP_FREED      equ 76                ; 收摊时还回去的页数
TCB_SP_HEAPPAGES  equ 80                ; 堆窗口页数(开机时算好,spawn 时照抄)
TCB_SP_ARGSVA     equ 84                ; 参数页虚拟地址
TCB_SP_STACKVA    equ 88                ; 用户栈页虚拟地址
TCB_SP_STACKTOP   equ 92                ; 用户栈顶
TCB_SP_RUNNING    equ 96                ; 1 = 这条线程正在跑 ring3 程序(给 ps 看)
TCB_SP_STAGE_PA   equ 100               ; 镜像暂存区(物理地址;按需分页从这里拷)
TCB_SP_STAGE_PAGES equ 104              ; 暂存区占几页
TCB_SP_KILLREQ    equ 108               ; 1 = 别的 shell 要求干掉这条线程上的程序
                                        ;     (IRQ0 在 ring3 现场上收摊,见 pit.asm)

; ---- 进程/信号地基:PCB 直接内嵌在 TCB 里(见 docs/process-signal-design.md)----
;  pid = 槽号 + 1,所以 PID 1..16;父进程号 0 表示「没有父进程」(shell 主线程)。
TCB_PARENT        equ 112               ; 父进程 pid(0 = 壳/孤儿)
TCB_EXITCODE      equ 116               ; 退出码(是不是有效看 STATE 是否为 ST_ZOMBIE)
TCB_PENDING       equ 120               ; 待投递信号位图(bit = 动作号)
TCB_BLOCKED       equ 124               ; 被屏蔽信号位图(bit = 动作号)
TCB_PFCOW         equ 128               ; 这趟运行里 COW 缺页复制了几页

; ---- 身份(最小多用户):登录用户 & 组;fork/spawn 时继承 ----
;  0 = super(root/SYSTEM),1 = system,2 = user(见 kernel/users.asm)
TCB_UID           equ 132               ; 登录用户号
TCB_GID           equ 136               ; 登录用户组号

; ---- A3:优先级调度 + 睡眠(先占好字段;A2 只负责把 TCB 扩大、清干净)----
TCB_PRIO          equ 140               ; 优先级:0 最高,15 最低(shell=8,idle=15)
TCB_WCHAN         equ 144               ; 睡眠在哪个通道上(0 = 没在睡)
TCB_SLEEPTICKS    equ 148               ; 睡眠超时还剩几个 tick(0 = 不限时)
TCB_READY_NEXT    equ 152               ; 就绪队列:下一项(槽号+1,0 = 没有)
TCB_READY_PREV    equ 156               ; 就绪队列:上一项(槽号+1,0 = 没有)
TCB_SLEEPFLAG     equ 160               ; 睡眠结果:0 = 正常唤醒,1 = 超时

; ---- A2:用户窗口总页数(镜像窗口 + 堆区 + 参数页 + guard + 栈增长区)----
;   space_create 清窗口、fork 标 COW、space_destroy 收摊都按它扫。
TCB_SP_WINDOWPAGES equ 164              ; 从 SPACE_IMG_VA 起一共几页
; ---- A3:就绪队列/aging ----
;  AGE = 这个线程在就绪队列里连续等了多少个 tick(不是自己的 tick);
;  等满 AGING_TICKS 就提一级优先级,保证低优先级线程不会饿死。
TCB_AGE           equ 168               ; 就绪等太久的 tick 数(A3 aging 用)

; ---- B(Phase B 作业控制):进程组/会话 + shell 作业载荷 ----
;  进程组是"作业"的单位:shell 每个作业一个 pgrp(组长 = 首进程 pid);
;  ^C/^Z 发给前台进程组,tcsetpgrp 记录哪个组现在占着终端。
TCB_PGRP          equ 172               ; 进程组号(0 = 还没分配)
TCB_SID           equ 176               ; 会话号(最小实现:所有 shell/作业同会话)
TCB_EXECBUF       equ 180               ; 子进程 exec 载荷页(名字+参数;0 = 没有)
TCB_STOPREQ       equ 184               ; 1 = ^Z 要求这条线程在 ring3 现场停下
TCB_KBUSY         equ 188               ; 最近一次读键盘的 tick(判"交互程序"用)
; ★ 为什么用 TCB_SIZE 宏而不是固定移位:TCB 从 32 → 40 → 108 → 112 一路长,全仓的
;   下标步长都靠这个宏(踩过:改完忘了某个 shl/imul,TCB 全错位)。
%define TCB_OFF(id) (((id) * TCB_SIZE))

ST_EMPTY          equ 0                 ; 空槽
ST_ALIVE          equ 1                 ; 活着(RUN:可被调度)
ST_DEAD           equ 2                 ; (留着)已经死掉的
ST_ZOMBIE         equ 3                 ; 已退出,等父进程 wait 收尸
ST_STOPPED        equ 4                 ; 被信号暂停(调度器跳过)
ST_SLEEPING       equ 5                 ; 睡在某个通道上等唤醒/超时

SCHED_STACK_PAGES equ 4                 ; 每个线程 16 KiB 内核栈(ring3 中断/深调用要用)
                                        ;   ★ 栈下面还有 1 页 guard(摘出恒等映射),
                                        ;   共 SCHED_STACK_PAGES+1 页连续物理页,见 kstack_alloc
SLICE_TICKS       equ 2                 ; 一次跑 2 个 tick(20 ms)就换人
SCHED_PRIO_SHELL  equ 8                 ; shell / 普通线程默认优先级
SCHED_PRIO_IDLE   equ 15                ; 最低优先级(以后空闲线程用)
SCHED_PRIO_KERNEL equ 7                 ; 内核服务线程:比普通线程高一级
AGING_TICKS       equ 100               ; 等 1 秒(100 tick)提一级优先级
SCHED_CS          equ 0x08              ; 内核代码段选择子(GDT 第 2 项)
SHELL_PGRP        equ 1                 ; shell 自己的进程组(shell 线程都属于它)
SHELL_SID         equ 1                 ; 会话号(最小实现:全家一个会话)
EFLAGS_IF         equ 0x202             ; eflags:IF=1,新线程一上来就能被打断

; ---------------------------------------------------------------------------
;  sched_init:清空 TCB 表,把"现在这个上下文"登记成 0 号线程
;  注意 esp / cr3 先留 0:这个上下文就是 shell 自己,它第一次被切走的时候
;  sched_pick 才知道它的 esp 在哪 —— 不用我们猜。
; ---------------------------------------------------------------------------
sched_init:
    pushad
    mov edi, tcb_table
    mov ecx, SCHED_MAX * TCB_SIZE / 4
    xor eax, eax
    rep stosd

    mov edi, tcb_table
    mov dword [edi + TCB_STATE], ST_ALIVE
    mov dword [edi + TCB_OWNER], 0
    mov dword [edi + TCB_NAME], nm_main
    ; 0 号线程的地址空间布局:kmain 在 paging_init 之前就算好了全局模板,
    ; 这里抄进 TCB;之后全局的 space_heap_pages 等只是"模板",真正干活的是 TCB。
    mov eax, [space_heap_pages]
    mov [edi + TCB_SP_HEAPPAGES], eax
    mov eax, [space_args_va]
    mov [edi + TCB_SP_ARGSVA], eax
    mov eax, [space_stack_va]
    mov [edi + TCB_SP_STACKVA], eax
    mov eax, [space_user_stack_top]
    mov [edi + TCB_SP_STACKTOP], eax
    mov eax, [space_window_pages]
    mov [edi + TCB_SP_WINDOWPAGES], eax
    mov eax, [sched_default_prio]
    mov [edi + TCB_PRIO], eax
    ; B:0 号线程 = 主 shell,它属于 shell 自己的进程组/会话
    mov dword [edi + TCB_PGRP], SHELL_PGRP
    mov dword [edi + TCB_SID], SHELL_SID
    mov [space_cur], edi                ; 现在跑的就是 0 号线程
    mov dword [tss_blk + TSS_ESP0], 0   ; ring3 进来时才设,先清掉开机时的旧值
    mov dword [sched_cur], 0
    mov dword [sched_live], 1
    mov dword [sched_slice], SLICE_TICKS
    mov dword [sched_on], 0             ; 先在开机流程里跑完,shell 起来再开
    mov dword [sched_next_demo], 0
    popad
    ret

; ---------------------------------------------------------------------------
;  sched_enable:开关一拨,下一次 IRQ0 就开始轮转
;  (一句 mov 就是原子的,不用 cli/sti)
; ---------------------------------------------------------------------------
sched_enable:
    mov dword [sched_on], 1
    ret

; ---------------------------------------------------------------------------
;  kstack_alloc:给线程要一段内核栈(16 KiB)+ 下面一页 guard
;    出:eax = 栈基址(4 页连续物理页),ebx = guard 页物理地址;eax=0 = 页池空了
;  为什么要 guard:内核栈溢出是最阴的 bug —— 越过栈底就静悄悄踩到别人的页。
;  这里把 guard 页从**恒等映射**里摘掉:一旦越界写,CPU 立刻 #PF(不在映射里),
;  内核不会带着花掉的栈继续跑。
; ---------------------------------------------------------------------------
kstack_alloc:
    pushad
    mov ecx, SCHED_STACK_PAGES + 1      ; guard 1 页 + 栈 4 页,必须连续
    call pmem_alloc_pages
    test eax, eax
    jz .fail
    mov [kstack_guard], eax             ; 整段第一页 = guard
    add eax, 4096
    mov [kstack_base], eax              ; 第二页起 = 栈
    mov eax, [kstack_guard]
    call paging_ident_unmap             ; guard 摘出恒等映射
    popad
    mov eax, [kstack_base]
    mov ebx, [kstack_guard]
    ret
.fail:
    popad
    xor eax, eax
    xor ebx, ebx
    ret

; ---------------------------------------------------------------------------
;  kstack_free:入 eax = 栈基址(guard 在它下面 4 KiB);把 guard 映射回来,
;  然后连着 guard 一起还给页池(共 SCHED_STACK_PAGES+1 页)。
; ---------------------------------------------------------------------------
kstack_free:
    pushad
    mov ebx, eax
    sub ebx, 4096                       ; guard = 栈基址 - 4 KiB(连续分配)
    mov eax, ebx
    call paging_ident_map               ; 先映射回来,页池/后续使用者才能正常访问
    mov eax, ebx
    mov ecx, SCHED_STACK_PAGES + 1
    call pmem_free_pages
    popad
    ret

; ---------------------------------------------------------------------------
;  sched_pick:由 irq0_stub 调用(此刻 pushad 已经把现场压在栈上了)
;    入:[sched_save_esp] = 当前 esp
;    出:eax = 接下来该 resume 的 esp(可能是同一个,那就是"不切")
;
;  这里**不能**自己换 esp:换栈那一下必须由调用方(irq0_stub)来做,
;  不然这个函数的 ret 会从别人的栈上弹返回地址。
; ---------------------------------------------------------------------------

; ===========================================================================
;  A3:优先级就绪队列
;  16 个优先级,每级一条 FIFO 双链表;链表节点放在 TCB 里:
;    TCB_READY_NEXT / TCB_READY_PREV 存「槽号+1」(0 = 没有)
;  位图 sched_ready_bitmap 记哪几级非空 —— bsf 一条指令就能找最高优先级。
;  约定:正在跑的线程不在队列里;其它 ST_ALIVE 线程必须都在队列里。
; ===========================================================================
sched_ready_enqueue:
    ; 入:esi = 槽号(0..SCHED_MAX-1)
    push eax
    push ebx
    push ecx
    push edx
    push edi
    mov edx, esi
    imul edx, TCB_SIZE
    add edx, tcb_table                  ; edx = TCB
    mov ebx, [edx + TCB_PRIO]           ; 优先级 = 队列下标
    mov eax, esi
    inc eax                             ; 本项 = 槽号+1
    lea edi, [sched_q_tail]
    mov ecx, [edi + ebx * 4]            ; ecx = 原队尾(0 = 空队)
    mov [edx + TCB_READY_PREV], ecx
    mov dword [edx + TCB_READY_NEXT], 0
    test ecx, ecx
    jz .first
    ; 原队尾的 next 指向本项
    dec ecx
    imul ecx, TCB_SIZE
    add ecx, tcb_table
    mov [ecx + TCB_READY_NEXT], eax
    jmp .linked
.first:
    lea edi, [sched_q_head]
    mov [edi + ebx * 4], eax            ; 队头 = 本项
.linked:
    lea edi, [sched_q_tail]
    mov [edi + ebx * 4], eax            ; 队尾 = 本项
    ; 位图置位
    mov ecx, ebx
    mov eax, 1
    shl eax, cl
    or [sched_ready_bitmap], eax
    pop edi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

sched_ready_remove:
    ; 入:esi = 槽号(必须在队列里)
    push eax
    push ebx
    push ecx
    push edx
    push edi
    push ebp
    mov edx, esi
    imul edx, TCB_SIZE
    add edx, tcb_table
    mov ebx, [edx + TCB_PRIO]
    mov ebp, [edx + TCB_READY_PREV]     ; 前项(槽号+1)
    mov ecx, [edx + TCB_READY_NEXT]     ; 后项
    ; 前项的 next(或队头)指向后项
    test ebp, ebp
    jz .at_head
    mov eax, ebp
    dec eax
    imul eax, TCB_SIZE
    add eax, tcb_table
    mov [eax + TCB_READY_NEXT], ecx
    jmp .fix_tail
.at_head:
    lea edi, [sched_q_head]
    mov [edi + ebx * 4], ecx
.fix_tail:
    ; 后项的 prev(或队尾)指向前项
    test ecx, ecx
    jz .at_tail
    dec ecx
    imul ecx, TCB_SIZE
    add ecx, tcb_table
    mov [ecx + TCB_READY_PREV], ebp
    jmp .cleared
.at_tail:
    lea edi, [sched_q_tail]
    mov [edi + ebx * 4], ebp
.cleared:
    ; 队空了就清位图
    lea edi, [sched_q_head]
    cmp dword [edi + ebx * 4], 0
    jne .unlink
    mov ecx, ebx
    mov eax, 1
    shl eax, cl
    not eax
    and [sched_ready_bitmap], eax
.unlink:
    xor eax, eax
    mov [edx + TCB_READY_NEXT], eax
    mov [edx + TCB_READY_PREV], eax
    pop ebp
    pop edi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

sched_ready_dequeue_best:
    ; 出:eax = 槽号(最高优先级队的队头),-1 = 没有可运行线程
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov eax, [sched_ready_bitmap]
    test eax, eax
    jz .none
    bsf ecx, eax                        ; 数字最小的非空级 = 最高优先级
    mov esi, [sched_q_head + ecx * 4]
    dec esi                             ; 槽号
    call sched_ready_remove             ; 摘掉(esi = 槽号)
    mov eax, esi
    jmp .out
.none:
    mov eax, -1
.out:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  sched_pick:由 irq0_stub 调用(此刻 pushad 已经把现场压在栈上了)
;    入:[sched_save_esp] = 当前 esp
;    出:eax = 接下来该 resume 的 esp(可能是同一个,那就是"不切")
;
;  这里**不能**自己换 esp:换栈那一下必须由调用方(irq0_stub)来做,
;  不然这个函数的 ret 会从别人的栈上弹返回地址。
; ---------------------------------------------------------------------------
sched_pick:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    ; ---- 1) 把当前线程的现场存好 ----
    mov eax, [sched_cur]
    imul eax, TCB_SIZE
    mov ebx, tcb_table
    add ebx, eax
    mov ecx, [sched_save_esp]
    mov [ebx + TCB_ESP], ecx
    mov eax, cr3
    mov [ebx + TCB_CR3], eax

.again:
    inc dword [ebx + TCB_TICKS]
    inc dword [sched_ticks]

    ; ---- 2) 睡眠超时扫描(不管 sched_on 开没开都要走:开机向导也在用)----
    xor esi, esi
.to_scan:
    mov edi, esi
    imul edi, TCB_SIZE
    add edi, tcb_table
    cmp dword [edi + TCB_STATE], ST_SLEEPING
    jne .to_next
    mov ecx, [edi + TCB_SLEEPTICKS]
    test ecx, ecx
    jz .to_next                         ; 不限时
    dec ecx
    mov [edi + TCB_SLEEPTICKS], ecx
    jnz .to_next
    ; 到点了:记「超时」、醒来、挂回就绪队列
    mov dword [edi + TCB_SLEEPFLAG], 1
    mov dword [edi + TCB_WCHAN], 0
    mov dword [edi + TCB_STATE], ST_ALIVE
    call sched_ready_enqueue            ; esi = 槽号
.to_next:
    inc esi
    cmp esi, SCHED_MAX
    jb .to_scan

    ; ---- 3) 调度没开?回去继续数 tick ----
    cmp dword [sched_on], 0
    je .keep

    ; ---- 4) aging:在就绪队列里等太久的,优先级提一级(低优先级不饿死)----
    xor esi, esi
.age_scan:
    mov edi, esi
    imul edi, TCB_SIZE
    add edi, tcb_table
    cmp dword [edi + TCB_STATE], ST_ALIVE
    jne .age_next
    cmp esi, [sched_cur]
    je .age_next                        ; 正在跑的不算"等"
    inc dword [edi + TCB_AGE]
    cmp dword [edi + TCB_AGE], AGING_TICKS
    jb .age_next
    mov dword [edi + TCB_AGE], 0
    mov eax, [edi + TCB_PRIO]
    ; 老化只把「比普通优先级低」的线程往上提,最多提到 SCHED_PRIO_SHELL(8):
    ; 普通线程不会被自己老化成"永远最优先",低优先级也不会被饿死。
    cmp eax, SCHED_PRIO_SHELL
    jbe .age_next
    dec eax
    call sched_ready_remove             ; 按旧优先级摘
    mov [edi + TCB_PRIO], eax
    call sched_ready_enqueue            ; 按新优先级挂
.age_next:
    inc esi
    cmp esi, SCHED_MAX
    jb .age_scan

    ; ---- 5) 决定切不切 ----
    cmp dword [ebx + TCB_STATE], ST_ALIVE
    jne .switch                         ; 自己在睡/僵尸:必须换人
    mov eax, [sched_ready_bitmap]
    test eax, eax
    jz .keep                            ; 没别人可跑:保持
    bsf ecx, eax
    cmp ecx, [ebx + TCB_PRIO]
    jb .switch                          ; 有人优先级比当前高:抢占
    dec dword [sched_slice]
    jg .keep                            ; 时间片没到
    mov dword [sched_slice], SLICE_TICKS

.switch:
    ; 当前线程还活着就排到同优先级队尾(睡/僵尸/暂停的不排)
    cmp dword [ebx + TCB_STATE], ST_ALIVE
    jne .pick
    mov esi, [sched_cur]
    call sched_ready_enqueue
.pick:
    call sched_ready_dequeue_best
    cmp eax, -1
    je .idle
    jmp .go

.idle:
    ; 一条可运行线程都没有:把控制权还给调用方(它的 hlt 循环会继续睡),
    ; 下个 tick 再进来扫。★ 不能在这里 sti;hlt —— 那会让嵌套的 IRQ0
    ; 一层层压栈,睡一夜就把内核栈睡爆了。
    mov eax, [sched_save_esp]
    jmp .out

.go:
    ; eax = 选中的槽号
    mov [sched_cur], eax
    mov esi, eax
    imul esi, TCB_SIZE
    add esi, tcb_table
    mov [space_cur], esi                ; 之后 space_* 读写这个人的 TCB
    mov eax, [esi + TCB_CR3]
    mov cr3, eax
    mov eax, [esi + TCB_SP_RUNESP]
    mov [tss_blk + TSS_ESP0], eax
    inc dword [esi + TCB_RUNS]
    mov dword [sched_slice], SLICE_TICKS
    mov eax, [esi + TCB_ESP]
    jmp .out

.keep:
    mov eax, [sched_save_esp]
.out:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  A3 睡眠/唤醒 API
;  通道(chan)约定:一个 4 字节全局地址(谁睡在上面由调用方约定)。
;  process_wait 用「父线程 TCB 指针」当通道,tty 用 tty_chan。
;
;  掉唤醒(lost wakeup)防护的用法:
;      call sched_sleep_prepare     ; 关中断,把自己标成睡眠
;      <关中断复查条件;条件已成立 -> call sched_sleep_cancel / sti>
;      call sched_sleep_commit      ; 开中断睡到被叫醒
; ---------------------------------------------------------------------------

; sched_sleep_prepare:eax = 通道;出:IF=0(调用方复查条件后再 commit/cancel)
sched_sleep_prepare:
    push ebx
    push ecx
    push edx
    cli
    mov ecx, eax
    call process_cur_tcb                ; eax = 当前 TCB
    mov dword [eax + TCB_STATE], ST_SLEEPING
    mov [eax + TCB_WCHAN], ecx
    mov dword [eax + TCB_SLEEPTICKS], 0
    mov dword [eax + TCB_SLEEPFLAG], 0
    pop edx
    pop ecx
    pop ebx
    ret

; sched_sleep_timeout_prepare:eax = 通道,ecx = 超时 tick(必须 >0)
sched_sleep_timeout_prepare:
    push ebx
    push ecx
    push edx
    cli
    mov [sched_sp_to], ecx
    mov ecx, eax
    call process_cur_tcb
    mov dword [eax + TCB_STATE], ST_SLEEPING
    mov [eax + TCB_WCHAN], ecx
    mov ecx, [sched_sp_to]
    mov [eax + TCB_SLEEPTICKS], ecx
    mov dword [eax + TCB_SLEEPFLAG], 0
    pop edx
    pop ecx
    pop ebx
    ret

; sched_sleep_commit:睡到被 wakeup 或超时叫醒;出:eax = SLEEPFLAG(1=超时),IF=1
sched_sleep_commit:
    push ebx
    push ecx
    push edx
    push edi
    call process_cur_tcb
    mov edi, eax
.sleep_loop:
    sti
    hlt
    cli
    cmp dword [edi + TCB_STATE], ST_SLEEPING
    je .sleep_loop
    mov eax, [edi + TCB_SLEEPFLAG]
    mov dword [edi + TCB_SLEEPFLAG], 0
    sti
    pop edi
    pop edx
    pop ecx
    pop ebx
    ret

; sched_sleep_cancel:把"准备睡"撤回(ST_SLEEPING→ST_ALIVE);不开关中断
sched_sleep_cancel:
    push eax
    push edi
    call process_cur_tcb
    mov edi, eax
    cmp dword [edi + TCB_STATE], ST_SLEEPING
    jne .out
    mov dword [edi + TCB_STATE], ST_ALIVE
    mov dword [edi + TCB_WCHAN], 0
    mov dword [edi + TCB_SLEEPTICKS], 0
    mov dword [edi + TCB_SLEEPFLAG], 0
.out:
    pop edi
    pop eax
    ret

; sched_sleep_on:eax = 通道 → 睡到被唤醒(不计超时)
sched_sleep_on:
    push eax
    call sched_sleep_prepare
    call sched_sleep_commit
    pop eax
    xor eax, eax
    ret

; sched_sleep_timeout:eax = 通道,ecx = 超时 tick → eax = 1 超时 / 0 正常唤醒
sched_sleep_timeout:
    push eax
    push ecx
    call sched_sleep_timeout_prepare
    call sched_sleep_commit
    pop ecx
    pop eax
    ret

; sched_wakeup:eax = 通道 → 把睡在这条通道上的线程全部叫醒(IRQ 安全)
sched_wakeup:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi
    pushfd
    cli
    mov ebx, eax                        ; 通道
    xor esi, esi
.wk_loop:
    mov edi, esi
    imul edi, TCB_SIZE
    add edi, tcb_table
    cmp dword [edi + TCB_STATE], ST_SLEEPING
    jne .wk_next
    cmp [edi + TCB_WCHAN], ebx
    jne .wk_next
    mov dword [edi + TCB_SLEEPFLAG], 0
    mov dword [edi + TCB_WCHAN], 0
    mov dword [edi + TCB_SLEEPTICKS], 0
    mov dword [edi + TCB_STATE], ST_ALIVE
    call sched_ready_enqueue            ; esi = 槽号
.wk_next:
    inc esi
    cmp esi, SCHED_MAX
    jb .wk_loop
    popfd
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; sched_wakeup_all:同 sched_wakeup(本实现就是"唤醒通道上所有线程")
sched_wakeup_all:
    jmp sched_wakeup

; sched_yield:主动让出 CPU(把自己的时间片清零,然后借 IRQ0 走一遍完整调度)
sched_yield:
    cli
    mov dword [sched_slice], 0
    int 0x20
    mov dword [sched_slice], SLICE_TICKS
    sti
    ret

; sched_setprio:eax = 槽号,ecx = 优先级(0..15)→ eax = 0 成功 / -1 参数错
sched_setprio:
    push ebx
    push edx
    push esi
    push edi
    push ebp
    mov dword [spr_ret], -1
    cmp eax, SCHED_MAX
    jae .out
    cmp ecx, 15
    ja .out
    mov ebx, eax                        ; 槽号
    mov ebp, ecx                        ; 新优先级
    mov edi, eax
    imul edi, TCB_SIZE
    add edi, tcb_table
    cmp dword [edi + TCB_STATE], ST_EMPTY
    je .out
    mov [spr_slot], ebx
    mov [spr_val], ebp
    pushfd
    cli
    ; 它在队列里的话(ALIVE 且不是当前线程)先摘下来,改完再挂回去
    cmp dword [edi + TCB_STATE], ST_ALIVE
    jne .set
    cmp ebx, [sched_cur]
    je .set
    mov esi, ebx
    call sched_ready_remove
.set:
    mov [edi + TCB_PRIO], ebp
    cmp dword [edi + TCB_STATE], ST_ALIVE
    jne .ok
    cmp ebx, [sched_cur]
    je .ok
    mov esi, ebx
    call sched_ready_enqueue
.ok:
    mov dword [spr_ret], 0
    popfd
.out:
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ebx
    mov eax, [spr_ret]
    ret

; sched_getprio:eax = 槽号 → eax = 优先级(0 最高..15 最低),-1 = 号不对
sched_getprio:
    cmp eax, SCHED_MAX
    jae .bad
    mov edx, eax
    imul edx, TCB_SIZE
    add edx, tcb_table
    cmp dword [edx + TCB_STATE], ST_EMPTY
    je .bad
    mov eax, [edx + TCB_PRIO]
    ret
.bad:
    mov eax, -1
    ret


; ---------------------------------------------------------------------------
;  sched_spawn:造一个新线程
;    入:eax = 入口地址(线程从这儿开始跑),ebx = 名字字符串
;    出:CF=0 时 eax = 线程号;CF=1 = 没槽 / 没内存
;
;  新线程的"现场"是搭出来的,不是压出来的 —— 按 irq0_stub 里那份格式,
;  从栈顶往下摆:
;     [eflags][cs][eip] [错误码][向量号] [eax..edi 八个]
;  esp 指向最低的 edi。这样第一次被调度上去时,stub 的 popad + iret
;  一条不差地把它送进入口函数。
; ---------------------------------------------------------------------------
sched_spawn:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp

    mov [spawn_entry], eax
    mov [spawn_name], ebx

    ; ---- 1) 找一个空槽 ----
    xor esi, esi
.find_slot:
    mov edx, esi
    imul edx, TCB_SIZE
    add edx, tcb_table
    cmp dword [edx + TCB_STATE], ST_EMPTY
    je .got_slot
    inc esi
    cmp esi, SCHED_MAX
    jb .find_slot
    stc                                 ; 槽满了
    jmp .out

.got_slot:
    mov [spawn_slot], esi
    mov [spawn_tcb], edx

    ; ---- 2) 内核栈:16 KiB + 下面一页 guard(see kstack_alloc)----
    call kstack_alloc
    test eax, eax
    jz .nomem
    mov [spawn_stack], eax

    ; ---- 3) 在栈顶搭现场 ----
    mov edi, eax
    add edi, SCHED_STACK_PAGES * 4096    ; edi = 栈顶上沿(栈往下长)
    mov eax, [spawn_entry]
    mov [edi - 12], eax                  ; eip:iret 之后从这儿开始
    mov dword [edi - 8], SCHED_CS        ; cs
    mov dword [edi - 4], EFLAGS_IF       ; eflags
    mov dword [edi - 16], 0              ; 错误码(用不上)
    mov dword [edi - 20], IRQ0_VECTOR    ; 向量号(stub 会 add esp,8 丢掉)
    ; pushad 的八个:全 0,线程从干净的寄存器开始
    mov dword [edi - 24], 0              ; eax
    mov dword [edi - 28], 0              ; ecx
    mov dword [edi - 32], 0              ; edx
    mov dword [edi - 36], 0              ; ebx
    mov dword [edi - 40], 0              ; esp(占位,popad 会跳过)
    mov dword [edi - 44], 0              ; ebp
    mov dword [edi - 48], 0              ; esi
    mov dword [edi - 52], 0              ; edi ← esp 指这儿
    sub edi, 52

    ; ---- 4) 填 TCB ----
    mov edx, [spawn_tcb]
    mov [edx + TCB_ESP], edi
    mov eax, cr3
    mov [edx + TCB_CR3], eax             ; 和造它的那个线程共用地址空间
    mov dword [edx + TCB_STATE], ST_ALIVE
    mov dword [edx + TCB_TICKS], 0
    mov dword [edx + TCB_RUNS], 0
    mov dword [edx + TCB_OWNER], 0       ; 出生地由调用方填(cmd_spawn)
    mov eax, [spawn_stack]
    mov [edx + TCB_STACK], eax
    mov eax, [spawn_name]
    mov [edx + TCB_NAME], eax
    ; 地址空间状态从"没有"开始 —— 空槽可能还留着上一个死者的页目录/计数。
    ; 布局四字段(HEAPPAGES/ARGSVA/STACKVA/STACKTOP)下面马上覆盖,这里一并清掉。
    mov dword [edx + TCB_SP_PD], 0
    mov dword [edx + TCB_SP_PT], 0
    mov dword [edx + TCB_SP_LIVE], 0
    mov dword [edx + TCB_SP_PAGES], 0
    mov dword [edx + TCB_SP_IMGBYTES], 0
    mov dword [edx + TCB_SP_PFRUN], 0
    mov dword [edx + TCB_SP_PFIMG], 0
    mov dword [edx + TCB_SP_PFHEAP], 0
    mov dword [edx + TCB_SP_FIRSTPA], 0
    mov dword [edx + TCB_SP_RUNSTAT], 0
    mov dword [edx + TCB_SP_FREED], 0
    mov dword [edx + TCB_SP_STAGE_PA], 0
    mov dword [edx + TCB_SP_STAGE_PAGES], 0
    mov dword [edx + TCB_SP_RUNNING], 0
    mov dword [edx + TCB_SP_KILLREQ], 0
    ; 地址空间布局跟造它的线程一样(全局模板在 kmain 里算好就没再变过)
    mov eax, [space_heap_pages]
    mov [edx + TCB_SP_HEAPPAGES], eax
    mov eax, [space_args_va]
    mov [edx + TCB_SP_ARGSVA], eax
    mov eax, [space_stack_va]
    mov [edx + TCB_SP_STACKVA], eax
    mov eax, [space_user_stack_top]
    mov [edx + TCB_SP_STACKTOP], eax
    mov eax, [space_window_pages]
    mov [edx + TCB_SP_WINDOWPAGES], eax
    ; 调度/睡眠字段:新线程默认优先级,睡眠状态一律清零
    mov eax, [sched_default_prio]
    mov [edx + TCB_PRIO], eax
    mov dword [edx + TCB_AGE], 0
    mov dword [edx + TCB_WCHAN], 0
    mov dword [edx + TCB_SLEEPTICKS], 0
    mov dword [edx + TCB_READY_NEXT], 0
    mov dword [edx + TCB_READY_PREV], 0
    mov dword [edx + TCB_SLEEPFLAG], 0
    ; 进程/信号字段:空槽可能留着上一个死者的值,必须清干净
    mov dword [edx + TCB_PARENT], 0
    mov dword [edx + TCB_EXITCODE], 0
    mov dword [edx + TCB_PENDING], 0
    mov dword [edx + TCB_BLOCKED], 0
    mov dword [edx + TCB_PFCOW], 0
    ; B:进程组/会话/作业载荷/停止请求也清零(空槽可能留着上一个人的)
    mov dword [edx + TCB_PGRP], 0
    mov dword [edx + TCB_SID], 0
    mov dword [edx + TCB_EXECBUF], 0
    mov dword [edx + TCB_STOPREQ], 0
    mov dword [edx + TCB_KBUSY], 0
    ; 内核线程没有 ring3 程序,但给一个有效的 esp0 顶(真跑程序时 exec 会覆盖)
    mov eax, [spawn_stack]
    add eax, SCHED_STACK_PAGES * 4096
    mov [edx + TCB_SP_RUNESP], eax
    ; 把新线程放进就绪队列 —— inc sched_live 和入队必须一起原子完成,
    ; 否则调度器可能先看见"活着的线程"、却找不到它在哪条队列里。
    pushfd
    cli
    inc dword [sched_live]
    mov esi, [spawn_slot]
    call sched_ready_enqueue
    popfd
    mov eax, [spawn_slot]                ; 返回线程号
    clc
    jmp .out

.nomem:
    stc
.out:
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  sched_kill:杀掉一个线程(把它的栈还给页池)
;    入:eax = 线程号   出:CF=0 成功,CF=1 = 号不对 / 空槽 / 想杀自己
;  为什么不能杀自己:0 号线程就是 shell,它还在用那条栈走路 —— 自己把自己
;  脚下的栈还给页池,下一条 push 就把自己埋了。
; ---------------------------------------------------------------------------
sched_kill:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    cmp eax, SCHED_MAX
    jae .bad
    cmp eax, [sched_cur]
    je .bad
    mov ebx, eax
    imul ebx, TCB_SIZE
    add ebx, tcb_table
    cmp dword [ebx + TCB_STATE], ST_ALIVE
    jne .bad
    ; 先把它从就绪队列里摘掉(否则调度器还会挑到一条已经死了的线程)
    mov esi, eax
    call sched_ready_remove

    ; ★ 先把整块 TCB 抄到 kill_space,再清槽 —— 调用方(cmd_kill)要按里面的
    ;   地址空间字段把那套页目录 / 私有页表 / 镜像暂存区收摊:否则 kill 一条
    ;   正在跑程序的线程,那套空间就漏在页池里了。
    mov esi, ebx
    mov edi, kill_space
    mov ecx, TCB_SIZE / 4
    rep movsd

    ; 还栈(杀的是别人,它此刻没在跑,放心还;guard 一起还)
    mov eax, [ebx + TCB_STACK]
    test eax, eax
    jz .freed
    call kstack_free
.freed:
    mov dword [ebx + TCB_STATE], ST_EMPTY
    mov dword [ebx + TCB_STACK], 0
    mov dword [ebx + TCB_ESP], 0
    mov dword [ebx + TCB_CR3], 0
    mov dword [ebx + TCB_TICKS], 0
    mov dword [ebx + TCB_RUNS], 0
    mov dword [ebx + TCB_NAME], nm_free
    mov dword [ebx + TCB_OWNER], 0
    ; 地址空间字段一起清掉(槽会被复用,别让它带着上一个人的指针)
    lea edi, [ebx + TCB_SP_PD]
    xor eax, eax
    mov ecx, (TCB_SIZE - TCB_SP_PD) / 4
    rep stosd
    dec dword [sched_live]
    clc
    jmp .out

.bad:
    stc
.out:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  sched_name:eax = 线程号 → esi = 名字指针,CF=1(越界)时 esi = 0
;  给 ps / kill 打印用
; ---------------------------------------------------------------------------
sched_name:
    xor esi, esi
    cmp eax, SCHED_MAX
    jae .bad
    mov esi, tcb_table
    imul eax, TCB_SIZE
    add esi, eax
    mov esi, [esi + TCB_NAME]
    clc
    ret
.bad:
    stc
    ret

; ---------------------------------------------------------------------------
;  thread_alpha / thread_beta:两个演示线程
;  每秒打一行自己的名字 + 数到几。它们互相抢 CPU 的痕迹就在屏幕上:
;  谁的名字在"对方数到一半"的时候插进来。等的时候用 pit_wait_ticks(hlt),
;  不烧 CPU —— 睡眠期间 CPU 完全是另一个线程的。
; ---------------------------------------------------------------------------
thread_alpha:
    mov dword [demo_a], 0
.loop:
    inc dword [demo_a]
    mov byte [term_color], COL_NORMAL    ; 打印前先把颜色摆正(另一个线程可能改了)
    mov esi, msg_t_alpha
    call term_print
    mov eax, [demo_a]
    call term_print_dec
    mov al, 10
    call term_putc
    mov ecx, 100                         ; 1 秒
    call pit_wait_ticks
    jmp .loop

thread_beta:
    mov dword [demo_b], 0
.loop:
    inc dword [demo_b]
    mov byte [term_color], COL_NORMAL
    mov esi, msg_t_beta
    call term_print
    mov eax, [demo_b]
    call term_print_dec
    mov al, 10
    call term_putc
    mov ecx, 100
    call pit_wait_ticks
    jmp .loop

; ---------------------------------------------------------------------------
;  数据
; ---------------------------------------------------------------------------
sched_on        dd 0                    ; 调度开关:0 = IRQ0 只数 tick
sched_cur       dd 0                    ; 当前线程号
sched_live      dd 0                    ; 活着的线程数
sched_ticks     dd 0                    ; 调度器一共数了多少 tick
sched_slice     dd SLICE_TICKS          ; 当前线程还剩几个 tick 的时间片
sched_save_esp  dd 0                    ; irq0_stub 交给 sched_pick 的 esp
sched_next_demo dd 0                    ; spawn 不带参数时下一个起谁(0=alpha 1=beta)
sched_default_prio dd SCHED_PRIO_SHELL  ; 新线程默认优先级
kstack_base     dd 0                    ; kstack_alloc 的返回值暂存
kstack_guard    dd 0                    ; kstack_alloc 的 guard 页暂存

; ---- A3:就绪队列(16 个优先级,每级一条 FIFO;位图记哪几级非空)----
sched_ready_bitmap dd 0
sched_q_head    times 16 dd 0           ; 每级队头(槽号+1,0 = 空)
sched_q_tail    times 16 dd 0           ; 每级队尾(槽号+1,0 = 空)
sched_sp_to     dd 0                    ; timeout_prepare 的超时暂存
spr_slot        dd 0                    ; sched_setprio 的临时
spr_val         dd 0
spr_ret         dd 0

; sched_spawn 的临时变量(不用 ebp 帧,省得栈上再挪一遍)
spawn_entry     dd 0
spawn_name      dd 0
spawn_slot      dd 0
spawn_tcb       dd 0
spawn_stack     dd 0

demo_a          dd 0                    ; alpha 数到几
demo_b          dd 0                    ; beta 数到几

kill_space      times TCB_SIZE db 0     ; 上一次 sched_kill 杀掉的线程的 TCB 快照

; ---------------------------------------------------------------------------
;  sched_abandon_current:当前线程不要了(退出/被杀),直接换到下一条 ALIVE 线程
;
;  和 sched_pick 的区别:这条线程的现场**不用保存**(它已经死了),
;  所以不写 [sched_save_esp],直接挑人、换 CR3、把对方的现场 popad/iret 回来。
;  调用前必须已经把当前 TCB 标成 ST_ZOMBIE(否则会又挑回自己)。
; ---------------------------------------------------------------------------

; ---------------------------------------------------------------------------
;  sched_abandon_current:当前线程不要了(退出/被杀),交给下一条可运行线程
;
;  和 sched_pick 的区别:这条线程的现场**不用保存**(它已经死了/是僵尸),
;  所以不写 [sched_save_esp],直接挑人、换 CR3、把对方的现场 popad/iret 回来。
;  调用前必须已经把当前 TCB 标成 ST_ZOMBIE(否则会又挑回自己)。
;  优先级队列里有人的话不用管队列:直接取最高优先级的。
; ---------------------------------------------------------------------------
sched_abandon_current:
    cli
.again:
    call sched_ready_dequeue_best
    cmp eax, -1
    je .idle
    ; eax = 槽号:切过去
    mov [sched_cur], eax
    mov esi, eax
    imul esi, TCB_SIZE
    add esi, tcb_table
    mov [space_cur], esi
    mov eax, [esi + TCB_CR3]
    mov cr3, eax
    mov eax, [esi + TCB_SP_RUNESP]
    mov [tss_blk + TSS_ESP0], eax
    inc dword [esi + TCB_RUNS]
    mov dword [sched_slice], SLICE_TICKS
    mov esp, [esi + TCB_ESP]
    popad
    add esp, 8
    iret
.idle:
    ; 一个可运行线程都没有 —— 只能睡死(理论上 shell 主线程不会退)
    sti
    hlt
    jmp .again

; ---------------------------------------------------------------------------
;  sched_check_stopreq:IRQ0 里检查"当前 ring3 线程要不要被 ^Z 暂停"
;    由 irq0_stub 在 .no_kill_req 处调用;此时栈上是 irq0_stub 的帧,
;    helper 又多压了个返回地址,所以中断前 CS 在 [esp+48]。
;  做了:清 STOPREQ、STATE=ST_STOPPED、唤醒父进程(shell)。
;  之后 irq0_stub 照常走 sched_pick —— 它会把这份中断现场存进 TCB_ESP,切走;
;  CONT 时从这儿恢复。
; ---------------------------------------------------------------------------
sched_check_stopreq:
    mov eax, [esp + 48]                 ; 中断前的 CS
    and eax, 3
    cmp eax, 3
    jne .out
    mov edx, [space_cur]
    cmp dword [edx + TCB_STOPREQ], 0
    je .out
    cmp dword [edx + TCB_SP_RUNNING], 0
    je .out
    mov dword [edx + TCB_STOPREQ], 0
    mov dword [edx + TCB_STATE], ST_STOPPED
    ; 父进程(通常是 shell)可能在 wait:叫醒它,让它看到 Stopped 的作业
    mov ecx, [edx + TCB_PARENT]
    test ecx, ecx
    jz .out
    dec ecx
    imul ecx, TCB_SIZE
    add ecx, tcb_table
    mov eax, ecx
    call sched_wakeup
.out:
    ret

; ---------------------------------------------------------------------------
;  sched_kill_space:上一次 sched_kill 杀掉的线程的地址空间快照
;    出:eax = kill_space(里面有 TCB_SP_* 字段),或者 0 = 它当时没在跑程序
;  shell 靠它把那套页目录 / 私有页表 / 暂存区收摊 —— 见 cmd_kill。
; ---------------------------------------------------------------------------
sched_kill_space:
    xor eax, eax
    mov edx, [kill_space + TCB_SP_PD]
    or  edx, [kill_space + TCB_SP_PT]   ; 半路被杀的线程可能只建到一半
    jz .none
    mov eax, kill_space
.none:
    ret

tcb_table       times SCHED_MAX * TCB_SIZE db 0

nm_main         db 'shell', 0
nm_free         db '(free)', 0
msg_t_alpha     db 'alpha ', 0
msg_t_beta      db 'beta ', 0

; 线程名字符串(n_alpha / n_beta 给 shell 解析 spawn 的参数用)
n_alpha         db 'alpha', 0
n_beta          db 'beta', 0
n_thread_alpha  db 'thread', 0          ; (留着:以后 spawn 自定义名字用)
