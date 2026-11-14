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

SCHED_MAX         equ 6                 ; 最多几个线程(含 0 号 = shell 自己)
TCB_SIZE          equ 112               ; 每个 TCB 112 字节(见 /4、imul 的用法)
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
; ★ 为什么用 TCB_SIZE 宏而不是固定移位:TCB 从 32 → 40 → 108 → 112 一路长,全仓的
;   下标步长都靠这个宏(踩过:改完忘了某个 shl/imul,TCB 全错位)。
%define TCB_OFF(id) (((id) * TCB_SIZE))

ST_EMPTY          equ 0                 ; 空槽
ST_ALIVE          equ 1                 ; 活着
ST_DEAD           equ 2                 ; (留着)已经死掉的

SCHED_STACK_PAGES equ 2                 ; 每个线程 8 KiB 栈,从物理页池拿
SLICE_TICKS       equ 2                 ; 一次跑 2 个 tick(20 ms)就换人
SCHED_CS          equ 0x08              ; 内核代码段选择子(GDT 第 2 项)
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

    ; ---- 1) 把当前线程的现场存好,顺手记一个 tick ----
    mov eax, [sched_cur]
    imul eax, TCB_SIZE                  ; × TCB_SIZE(112,不是 2 的幂)
    mov ebx, tcb_table
    add ebx, eax
    mov ecx, [sched_save_esp]
    mov [ebx + TCB_ESP], ecx
    mov eax, cr3
    mov [ebx + TCB_CR3], eax
    inc dword [ebx + TCB_TICKS]
    inc dword [sched_ticks]

    ; ---- 2) 只有自己一个线程?不用切(省掉一次 cr3 折腾)----
    cmp dword [sched_live], 2
    jb .keep

    ; ---- 3) 时间片还没用完?继续跑 ----
    dec dword [sched_slice]
    jg .keep
    mov dword [sched_slice], SLICE_TICKS

    ; ---- 4) 从 cur+1 开始找下一个活着的(转一圈,最多 SCHED_MAX 次)----
    mov esi, [sched_cur]
    mov ecx, SCHED_MAX
.next_slot:
    inc esi
    cmp esi, SCHED_MAX
    jb .no_wrap
    xor esi, esi
.no_wrap:
    mov edx, esi
    imul edx, TCB_SIZE
    add edx, tcb_table
    cmp dword [edx + TCB_STATE], ST_ALIVE
    jne .try_next
    ; 找到人:换地址空间(每个线程自己的 cr3),再交出它的 esp
    mov [sched_cur], esi
    mov [space_cur], edx                ; 之后 space_* 就读写这个人的 TCB
    mov eax, [edx + TCB_CR3]
    mov cr3, eax
    ; ring3 进来的中断用它的内核栈顶:该线程正在跑程序时就是 run_esp;
    ; 没跑程序时是 0(纯内核线程不会有特权级切换,用不到 esp0)
    mov eax, [edx + TCB_SP_RUNESP]
    mov [tss_blk + TSS_ESP0], eax
    inc dword [edx + TCB_RUNS]
    mov eax, [edx + TCB_ESP]
    jmp .out
.try_next:
    dec ecx
    jnz .next_slot

    ; 一圈下来只剩自己 → 当没切
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

    ; ---- 2) 要一段连续页当栈(栈得是连续内存,不然 push 就散了)----
    mov ecx, SCHED_STACK_PAGES
    call pmem_alloc_pages
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
    ; 地址空间布局跟造它的线程一样(全局模板在 kmain 里算好就没再变过)
    mov eax, [space_heap_pages]
    mov [edx + TCB_SP_HEAPPAGES], eax
    mov eax, [space_args_va]
    mov [edx + TCB_SP_ARGSVA], eax
    mov eax, [space_stack_va]
    mov [edx + TCB_SP_STACKVA], eax
    mov eax, [space_user_stack_top]
    mov [edx + TCB_SP_STACKTOP], eax
    inc dword [sched_live]
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

    ; ★ 先把整块 TCB 抄到 kill_space,再清槽 —— 调用方(cmd_kill)要按里面的
    ;   地址空间字段把那套页目录 / 私有页表 / 镜像暂存区收摊:否则 kill 一条
    ;   正在跑程序的线程,那套空间就漏在页池里了。
    mov esi, ebx
    mov edi, kill_space
    mov ecx, TCB_SIZE / 4
    rep movsd

    ; 还栈(杀的是别人,它此刻没在跑,放心还)
    mov eax, [ebx + TCB_STACK]
    test eax, eax
    jz .freed
    mov ecx, SCHED_STACK_PAGES
    call pmem_free_pages
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
