; ============================================================================
;  KKernel — 进程地基:PCB(内嵌在 TCB 里)+ fork/exec/wait/exit + 三元组信号
;
;  ── 这是在解决什么问题 ──────────────────────────────────────────────────
;  Phase 1 已经把"地址空间状态"从全局变量搬进了 TCB,于是每条 shell 线程
;  能各跑各的程序;但线程之间还是兄弟关系 —— 没有父子、没有等待、没有退出码,
;  也没有"复制一份自己"的办法。这一层补的就是这些东西:
;
;    · 进程表:就是调度器的 TCB 表(SCHED_MAX = 16 项),PID = 槽号 + 1。
;      为什么不另开一张表:fork 的时候本来就要分配槽、内核栈、页目录,再维护
;      两张互相指向的表只会多一处不一致。PCB 字段(父 pid / 退出码 / 信号位图 /
;      COW 计数)直接追加在 TCB 尾部,见 sched.asm 的 TCB_PARENT..TCB_PFCOW。
;    · fork:父进程的地址空间**不复制页**,只把页表项改成 PAGE_COW + 只读、
;      引用计数 +1;谁先写谁触发 14 号页错误,由 paging.asm 复制那一页。
;    · exec:在本进程里换一套地址空间再 iret 进 ring 3(cmd_run 的加载流程,
;      但不新建线程)。
;    · wait/exit:子进程退出后留在表里当僵尸(ZOMBIE),父进程 wait 拿退出码
;      并收回槽和内核栈。
;    · 信号:权限类/动作/级别 三元组编码成 32 位 signal_t,默认动作按动作号走;
;      本阶段不做"发送方权限够不够"的校验,只把字段和位图留好。
;
;  ── 和设计稿的对应 ──────────────────────────────────────────────────────
;  docs/process-signal-design.md 第 1/2 节。实现上比设计稿多了一个选择:
;  "进程表 16 项"直接复用 TCB 表,所以 shell 的 4 条线程就是 PID 1..4。
; ============================================================================

; ---- signal_t 的位划分:高 8 位权限类,中 8 位动作,低 16 位级别 ----
SIG_CLASS_SHIFT   equ 24
SIG_ACTION_SHIFT  equ 16
SIG_CLASS_SUPER   equ 0
SIG_CLASS_SYSTEM  equ 1
SIG_CLASS_USER    equ 2
SIG_ACT_KILL      equ 1
SIG_ACT_TERM      equ 2
SIG_ACT_STOP      equ 3
SIG_ACT_CONT      equ 4
SIG_ACT_INTR      equ 5
SIG_ACT_USR       equ 6
SIG_LEVEL_NONE    equ 0                ; 0 = 最高,仅 super 可发、不可屏蔽
SIG_LEVEL_SYS     equ 1                ; 1 = 系统级
SIG_LEVEL_USER    equ 2                ; 2 = 用户级,可屏蔽
SIG_LEVEL_HINT    equ 3                ; 3 = 提示级

; ---------------------------------------------------------------------------
;  process_cur_tcb:eax = 当前线程的 TCB 指针(只毁 eax)
; ---------------------------------------------------------------------------
process_cur_tcb:
    mov eax, [sched_cur]
    imul eax, TCB_SIZE
    add eax, tcb_table
    ret

; ---------------------------------------------------------------------------
;  process_getpid:eax = 当前进程号(1..SCHED_MAX)
; ---------------------------------------------------------------------------
process_getpid:
    mov eax, [sched_cur]
    inc eax
    ret

; ---------------------------------------------------------------------------
;  process_alloc_slot:找一个空槽 → eax = 槽号,CF=0;满了 CF=1
;  空槽 = ST_EMPTY。僵尸还占着槽(等父进程收尸),不会被抢。
; ---------------------------------------------------------------------------
process_alloc_slot:
    xor eax, eax
.loop:
    mov edx, eax
    imul edx, TCB_SIZE
    add edx, tcb_table
    cmp dword [edx + TCB_STATE], ST_EMPTY
    je .ok
    inc eax
    cmp eax, SCHED_MAX
    jb .loop
    stc
    ret
.ok:
    clc
    ret

; ---------------------------------------------------------------------------
;  process_clear_tcb:把 edx 指向的 TCB 整块清零,恢复成空槽
; ---------------------------------------------------------------------------
process_clear_tcb:
    pushad
    mov edi, edx
    xor eax, eax
    mov ecx, TCB_SIZE / 4
    rep stosd
    mov dword [edx + TCB_STATE], ST_EMPTY
    mov dword [edx + TCB_NAME], nm_free
    popad
    ret

; ---------------------------------------------------------------------------
;  process_fork:fork() —— 复制当前进程
;
;    入:ebx = api_stub 的栈帧基址(那里有程序的 pushad 现场 + iret 帧)
;    出:eax = 子进程 pid(父进程);子进程从 int 0x30 下一条指令回来,eax = 0
;        失败 eax = -1
;
;  顺序和设计稿一致:
;	找槽 → 子内核栈(16 KiB + guard) → 子页目录/页表各 1 页 → 预检引用计数 →
;    整页拷父页目录/页表 → 窗口页全部 COW(父子都只读、计数 +1)→
;    刷新父进程 TLB → 在子栈顶搭 60 字节 iret 帧 → 填 TCB → ++sched_live
;  真正"复制页"推迟到写的时候(14 号页错误里的 .cow 分支)。
; ---------------------------------------------------------------------------
process_fork:
    pushad
    mov [pf_frame], ebx

    ; ---- 0) 快照父进程的关键字段(后面几次函数调用会毁寄存器)----
    call process_cur_tcb
    mov [pf_parent_tcb], eax
    mov edx, eax
    mov eax, [edx + TCB_SP_PD]
    mov [pf_parent_pd], eax
    mov eax, [edx + TCB_SP_PT]
    mov [pf_parent_pt], eax
    ; guard 页下标:窗口里唯一一页「只读且不参与 COW」的,单独处理
    mov eax, [edx + TCB_SP_STACKVA]
    sub eax, 0x1000
    shr eax, 12
    and eax, 0x3FF
    mov [pf_guard_idx], eax
    cmp dword [edx + TCB_SP_LIVE], 0
    je .fail                            ; 父进程没在跑程序(理论上到不了)
    cmp dword [pf_parent_pd], 0
    je .fail

    ; ---- 1) 找一个空槽 ----
    call process_alloc_slot
    jc .fail
    mov [pf_slot], eax

    ; ---- 2) 子进程的内核栈:16 KiB + guard(IRQ0 从 ring 3 进来要用它)----
    call kstack_alloc
    test eax, eax
    jz .fail
    mov [pf_child_stack], eax

    ; ---- 3) 子进程自己的页目录 + 低端页表 ----
    call pmem_alloc
    test eax, eax
    jz .fail_stack
    mov [pf_child_pd], eax
    call pmem_alloc
    test eax, eax
    jz .fail_pd
    mov [pf_child_pt], eax

    ; ---- 4) 预检:窗口里每个 present 页的引用计数都必须 < 15 ----
    ;   4 bit 计数封顶 15;先查一遍,免得标了一半 COW 才发现加不上去。
    mov esi, [pf_parent_pt]
    mov ebx, (SPACE_IMG_VA >> 12) & 0x3FF
    mov ecx, [pf_parent_tcb]
    mov ecx, [ecx + TCB_SP_WINDOWPAGES]
.precheck:
    cmp ebx, [pf_guard_idx]
    je .pk_next                         ; guard 页不共享、不标 COW
    mov eax, [esi + ebx * 4]
    test eax, PAGE_P
    jz .pk_next
    and eax, 0xFFFFF000
    call pmem_ref_get
    jc .fail_all                        ; 不在页池里:页表坏了
    cmp eax, 15
    jae .fail_all
.pk_next:
    inc ebx
    dec ecx
    jnz .precheck

    ; ---- 5) 整页拷父进程的页目录 / 页表,再把 PD[0] 指向子页表 ----
    mov edi, [pf_child_pd]
    mov esi, [pf_parent_pd]
    mov ecx, 1024
    rep movsd
    mov edi, [pf_child_pt]
    mov esi, [pf_parent_pt]
    mov ecx, 1024
    rep movsd
    mov edi, [pf_child_pd]
    mov eax, [pf_child_pt]
    or  eax, PAGE_P | PAGE_RW | PAGE_USER
    mov [edi], eax

    ; ---- 6) 两个窗口里的页全部改成写时复制 ----
    ;   父页表和子页表都写成"只读 + PAGE_COW",并把引用计数 +1。
    ;   谁写谁触发 14 号页错误,paging.asm 复制一份后把这一项恢复成可写。
    mov esi, [pf_parent_pt]
    mov edi, [pf_child_pt]
    mov ebx, (SPACE_IMG_VA >> 12) & 0x3FF
    mov ecx, [pf_parent_tcb]
    mov ecx, [ecx + TCB_SP_WINDOWPAGES]
.mark_cow:
    cmp ebx, [pf_guard_idx]
    je .cow_next                        ; guard 页:父子各用各的,不进 COW
    mov eax, [esi + ebx * 4]
    test eax, PAGE_P
    jz .cow_next
    mov edx, eax
    and edx, 0xFFFFF000
    push eax
    mov eax, edx
    call pmem_ref_inc
    pop eax
    and eax, 0xFFFFF000
    or  eax, PAGE_P | PAGE_USER | PAGE_COW
    mov [esi + ebx * 4], eax            ; 父进程
    mov [edi + ebx * 4], eax            ; 子进程
.cow_next:
    inc ebx
    dec ecx
    jnz .mark_cow

    ; ---- 7) 镜像暂存区也共享:每页引用计数 +1 ----
    mov esi, [pf_parent_tcb]
    mov eax, [esi + TCB_SP_STAGE_PA]
    mov ecx, [esi + TCB_SP_STAGE_PAGES]
    test eax, eax
    jz .no_stage
.stage_inc:
    push eax
    push ecx
    call pmem_ref_inc
    pop ecx
    pop eax
    add eax, PAGE_BYTES
    dec ecx
    jnz .stage_inc
.no_stage:

    ; ---- 7.5) 子进程的 guard 页:单独给一页(不和父进程共享)----
    ;   两边空间各自收摊,free_window 各还各的页;共享会变成双重释放。
    mov eax, [pf_child_pt]
    mov ebx, [pf_guard_idx]
    mov dword [eax + ebx * 4], 0        ; 先摘掉继承下来的父 guard 项
    mov ecx, 1
    call pmem_alloc_pages
    test eax, eax
    jz .fail_all                        ; OOM:半套 COW 已标,放弃子进程
    mov [pf_child_guard_pa], eax
    mov edi, eax
    xor eax, eax
    mov ecx, 1024
    rep stosd                           ; 清零
    mov eax, [pf_child_guard_pa]
    or eax, PAGE_P | PAGE_USER          ; 只读:越界写 → #PF → 杀程序
    mov edi, [pf_child_pt]
    mov ebx, [pf_guard_idx]
    mov [edi + ebx * 4], eax

    ; ---- 8) 父进程的页表刚改成只读,刷一下 TLB ----
    mov eax, [pf_parent_pd]
    mov cr3, eax

    ; ---- 9) 在子进程内核栈顶搭现场(和 sched_pick 的 resume 布局一致)----
    ;   [pushad 8 个][向量号][错误码][EIP][CS][EFLAGS][ESP3][SS3] = 60 字节
    ;   sched_pick 恢复时 popad → add esp,8 → iret;iret 看到 5 个 dword
    ;   就从 ring 0 回到 ring 3,子进程像刚做完 int 0x30 一样继续跑。
    mov edi, [pf_child_stack]
    add edi, SCHED_STACK_PAGES * 4096
    sub edi, 60
    mov [pf_child_frame], edi
    mov esi, [pf_frame]
    mov ecx, 8
    rep movsd                           ; 程序的所有寄存器照抄父进程
    mov dword [edi], 0                  ; 向量号(占位)
    mov dword [edi + 4], 0              ; 错误码(占位)
    add edi, 8
    mov ecx, 5
    rep movsd                           ; EIP / CS / EFLAGS / ESP3 / SS3
    mov edi, [pf_child_frame]
    mov dword [edi + 28], 0             ; 子进程 eax = 0(fork 的返回值)

    ; ---- 10) 填子进程 TCB ----
    mov edx, [pf_slot]
    imul edx, TCB_SIZE
    add edx, tcb_table
    mov eax, [pf_child_frame]
    mov [edx + TCB_ESP], eax
    mov eax, [pf_child_pd]
    mov [edx + TCB_CR3], eax
    mov dword [edx + TCB_STATE], ST_ALIVE
    mov dword [edx + TCB_TICKS], 0
    mov dword [edx + TCB_RUNS], 0
    mov eax, [pf_parent_tcb]
    mov eax, [eax + TCB_OWNER]
    mov [edx + TCB_OWNER], eax          ; 跟着父进程的 shell(键盘归属)
    mov eax, [pf_child_stack]
    mov [edx + TCB_STACK], eax
    mov dword [edx + TCB_NAME], nm_child

    mov esi, [pf_parent_tcb]
    mov eax, [esi + TCB_UID]            ; 登录身份跟着父进程(最小多用户)
    mov [edx + TCB_UID], eax
    mov eax, [esi + TCB_GID]
    mov [edx + TCB_GID], eax
    mov eax, [esi + TCB_SP_HEAPPAGES]
    mov [edx + TCB_SP_HEAPPAGES], eax
    mov eax, [esi + TCB_SP_ARGSVA]
    mov [edx + TCB_SP_ARGSVA], eax
    mov eax, [esi + TCB_SP_STACKVA]
    mov [edx + TCB_SP_STACKVA], eax
    mov eax, [esi + TCB_SP_STACKTOP]
    mov [edx + TCB_SP_STACKTOP], eax
    mov eax, [esi + TCB_SP_WINDOWPAGES]
    mov [edx + TCB_SP_WINDOWPAGES], eax
    mov dword [edx + TCB_WCHAN], 0
    mov dword [edx + TCB_SLEEPTICKS], 0
    mov dword [edx + TCB_READY_NEXT], 0
    mov dword [edx + TCB_READY_PREV], 0
    mov dword [edx + TCB_SLEEPFLAG], 0
    mov eax, [esi + TCB_PRIO]           ; 优先级跟着父进程(fork 继承)
    mov [edx + TCB_PRIO], eax
    mov eax, [pf_child_pd]
    mov [edx + TCB_SP_PD], eax
    mov eax, [pf_child_pt]
    mov [edx + TCB_SP_PT], eax
    mov dword [edx + TCB_SP_LIVE], 1
    mov eax, [esi + TCB_SP_PAGES]
    mov [edx + TCB_SP_PAGES], eax
    mov eax, [esi + TCB_SP_IMGBYTES]
    mov [edx + TCB_SP_IMGBYTES], eax
    mov dword [edx + TCB_SP_PFRUN], 0
    mov dword [edx + TCB_SP_PFIMG], 0
    mov dword [edx + TCB_SP_PFHEAP], 0
    mov dword [edx + TCB_SP_FIRSTPA], 0
    mov eax, [esi + TCB_SP_STAGE_PA]
    mov [edx + TCB_SP_STAGE_PA], eax
    mov eax, [esi + TCB_SP_STAGE_PAGES]
    mov [edx + TCB_SP_STAGE_PAGES], eax
    mov dword [edx + TCB_SP_RUNSTAT], 0
    mov dword [edx + TCB_SP_RUNNING], 0
    mov dword [edx + TCB_SP_KILLREQ], 0
    mov dword [edx + TCB_SP_FREED], 0
    mov eax, [pf_child_stack]
    add eax, SCHED_STACK_PAGES * 4096
    mov [edx + TCB_SP_RUNESP], eax
    mov eax, [sched_cur]
    inc eax
    mov [edx + TCB_PARENT], eax
    mov dword [edx + TCB_EXITCODE], 0
    mov dword [edx + TCB_PENDING], 0
    mov dword [edx + TCB_BLOCKED], 0
    mov dword [edx + TCB_PFCOW], 0
    inc dword [sched_live]

    mov eax, [pf_slot]
    inc eax                             ; 父进程拿到 pid
    mov [pf_result], eax
    popad
    mov eax, [pf_result]
    ret

    ; ---- 失败:把已经拿到的页按相反顺序还回去 ----
.fail_all:
    mov eax, [pf_child_pt]
    call pmem_free
    mov eax, [pf_child_pd]
    call pmem_free
.fail_stack:
    mov eax, [pf_child_stack]
    call kstack_free
.fail:
    mov dword [pf_result], -1
    popad
    mov eax, [pf_result]
    ret
.fail_pd:
    mov eax, [pf_child_pd]
    call pmem_free
    jmp .fail_stack

; ---------------------------------------------------------------------------
;  process_wait:等一个僵尸子进程并收尸(阻塞版)
;
;    入:eax = 子进程 pid,-1 = 任意子进程
;    出:eax = 退出码;没有子进程可等 → -1
;    副作用:proc_last_child = 这次收掉的是谁(给 shell 打印用)
;
;  "阻塞"用 sti;hlt:INT 0x30 的门把 IF 清掉了,这里显式开中断再睡,
;  IRQ0 的调度器就能把 CPU 让给别的线程(包括我们等的那个孩子)。
;  醒来后 cli 回到内核态继续扫表 —— 表的改动全在中断里,不会撕裂。
;  没有孩子(或等的 pid 不是自己的娃)时立刻返回 -1,不睡。
; ---------------------------------------------------------------------------
process_wait:
    pushad
    mov [pw_pid], eax
    mov dword [pw_ret], -1
    mov dword [proc_last_child], 0
.retry:
    xor esi, esi
.scan:
    mov edx, esi
    imul edx, TCB_SIZE
    add edx, tcb_table
    cmp dword [edx + TCB_STATE], ST_ZOMBIE
    jne .next
    mov eax, [sched_cur]
    inc eax
    cmp [edx + TCB_PARENT], eax          ; 只收自己的娃
    jne .next
    mov eax, [pw_pid]
    cmp eax, -1
    je .reap
    lea ecx, [esi + 1]
    cmp eax, ecx
    jne .next
.reap:
    mov [pw_slot], esi
    mov eax, [edx + TCB_EXITCODE]
    mov [pw_ret], eax
    lea eax, [esi + 1]
    mov [proc_last_child], eax
    ; 内核栈(16 KiB + guard)还回去(地址空间在 exit 时已经拆了)
    mov eax, [edx + TCB_STACK]
    test eax, eax
    jz .nostack
    call kstack_free
.nostack:
    mov edx, [pw_slot]
    imul edx, TCB_SIZE
    add edx, tcb_table
    call process_clear_tcb
    dec dword [sched_live]
    jmp .done
.next:
    inc esi
    cmp esi, SCHED_MAX
    jb .scan

    ; ---- 没扫到僵尸:这个 pid 还有没有活着的(或暂停的)孩子? ----
    xor esi, esi
.child:
    mov edx, esi
    imul edx, TCB_SIZE
    add edx, tcb_table
    cmp dword [edx + TCB_STATE], ST_EMPTY
    je .child_next
    mov eax, [sched_cur]
    inc eax
    cmp [edx + TCB_PARENT], eax
    jne .child_next
    mov eax, [pw_pid]
    cmp eax, -1
    je .sleep
    lea ecx, [esi + 1]
    cmp eax, ecx
    je .sleep
.child_next:
    inc esi
    cmp esi, SCHED_MAX
    jb .child

    ; ---- 没有孩子:wait 立刻返回 -1(和 POSIX 的 ECHILD 一个意思)----
    jmp .done
.sleep:
    sti
    hlt
    cli
    jmp .retry
.done:
    popad
    mov eax, [pw_ret]
    ret

; ---------------------------------------------------------------------------
;  process_exit:当前进程退出(不返回)
;    入:eax = 退出码
;  变成僵尸(等父进程 wait 收),拆掉地址空间,然后把 CPU 让给下一条线程。
;  fork 出来的子进程从 api_exit / demo 线程走到这里;shell 主线程不走这条路。
; ---------------------------------------------------------------------------
process_exit:
    pushad
    mov edx, [space_cur]
    mov [edx + TCB_EXITCODE], eax
    mov dword [edx + TCB_STATE], ST_ZOMBIE
    mov dword [edx + TCB_SP_RUNNING], 0
    mov dword [edx + TCB_SP_KILLREQ], 0
    call space_destroy                  ; 当前线程的空间;没建也能调
    popad
    jmp sched_abandon_current

; ---------------------------------------------------------------------------
;  process_terminate:按"终止"这个默认动作处理一个进程
;    入:edx = 目标 TCB,eax = 退出码
;    出:eax = 0 成功 / -1 拒绝(杀自己、空槽、shell 没在跑程序)
;
;  三种收法:
;    · shell 线程正在跑 ring 3 程序 → 只挂 KILLREQ,让 IRQ0 在用户现场收摊
;      (不能在这里换它的栈 —— 它现在没在跑,但栈的用法归 pit.asm 管,保留原语义)
;    · 有父进程的普通进程 → 标 ZOMBIE,交给父进程 wait 收尸
;    · 没有父进程的普通线程 → 立刻收尸(这是原来 kill 的行为:还栈 + 清槽)
; ---------------------------------------------------------------------------
process_terminate:
    pushad
    mov [pt_tcb], edx
    mov [pt_code], eax
    ; 不能杀正在执行的自己
    mov eax, [sched_cur]
    imul eax, TCB_SIZE
    add eax, tcb_table
    cmp eax, edx
    je .deny
    mov eax, [edx + TCB_STATE]
    cmp eax, ST_ALIVE
    je .alive
    cmp eax, ST_STOPPED
    jne .deny
.alive:
    ; 算槽号:(tcb - tcb_table) / TCB_SIZE
    mov eax, edx
    sub eax, tcb_table
    xor edx, edx
    mov ecx, TCB_SIZE
    div ecx
    mov [pt_slot], eax
    cmp eax, SH_MAX
    jb .shell_slot
    mov ecx, [pt_tcb]
    cmp dword [ecx + TCB_PARENT], 0
    jne .zombie
    ; ---- 没有父进程:保持旧 kill 语义(立刻还栈、清槽)----
    mov eax, [pt_slot]
    call sched_kill
    jc .deny
    call sched_kill_space
    test eax, eax
    jz .ok
    mov edi, eax
    call space_destroy_at               ; 它的页目录/页表/窗口页
    jmp .ok
.zombie:
    mov edx, [pt_tcb]
    mov dword [edx + TCB_STATE], ST_ZOMBIE
    mov eax, [pt_code]
    mov [edx + TCB_EXITCODE], eax
    mov dword [edx + TCB_SP_RUNNING], 0
    mov dword [edx + TCB_SP_KILLREQ], 0
    mov edi, edx
    call space_destroy_at
    jmp .ok
.shell_slot:
    mov edx, [pt_tcb]
    cmp dword [edx + TCB_SP_RUNNING], 0
    je .deny
    cmp dword [edx + TCB_SP_RUNESP], 0
    je .deny
    cmp dword [edx + TCB_SP_RUNSTAT], 0
    jne .deny
    mov dword [edx + TCB_SP_KILLREQ], 1
.ok:
    mov dword [pt_ret], 0
    jmp .out
.deny:
    mov dword [pt_ret], -1
.out:
    popad
    mov eax, [pt_ret]
    ret

; ---------------------------------------------------------------------------
;  process_signal_send:发一个信号
;    入:eax = 目标 pid,ebx = signal_t
;    出:eax = 0 成功 / -1 (pid 不对、动作号不对、目标拒绝)
;
;  语义(本阶段):
;    · 总是先把动作号对应的 pending 位记上;
;    · 级别 >= 2 且目标 blocked 位图里有这一位 → 只记 pending,不执行动作;
;    · 级别 0/1 不可屏蔽,直接执行默认动作;
;    · kill/term 的默认动作都是"终止"(term 的用户态处理函数留给下一阶段);
;      stop/cont 改 TCB 状态(调度器只挑 ST_ALIVE,所以 STOPPED 就是暂停);
;      intr/usr 只投 pending。
;    · 发送方权限(最小多用户,见 kernel/users.asm):uid 0(super)不受限;
;      super 类只允许 uid 0,system 类只允许 uid 0/1,user 类不限;
;      级别 0(只查不杀)只允许 uid 0;越权返回 -1 并打印权限提示。
; ---------------------------------------------------------------------------
process_signal_send:
    pushad
    mov [ss_pid], eax
    mov [ss_sig], ebx
    mov dword [ss_ret], -1

    ; ---- 1) 拆 signal_t ----
    mov edx, ebx
    shr edx, SIG_CLASS_SHIFT
    and edx, 0xFF
    mov [ss_class], edx
    mov edx, ebx
    shr edx, SIG_ACTION_SHIFT
    and edx, 0xFF
    mov [ss_action], edx
    movzx edx, bx
    mov [ss_level], edx
    cmp dword [ss_action], SIG_ACT_KILL
    jb .out
    cmp dword [ss_action], SIG_ACT_USR
    ja .out

    ; ---- 1.5) 发送方权限检查(最小多用户)----
    ;   uid 0(super)想发什么发什么;super 类只允许 uid 0,system 类只允许
    ;   uid 0/1,user 类不限;级别 0(只查询不杀)只允许 uid 0。
    call process_cur_tcb
    mov ecx, [eax + TCB_UID]
    test ecx, ecx
    jz .perm_ok                         ; uid 0 = super,全放行
    cmp dword [ss_class], SIG_CLASS_SUPER
    je .perm_deny
    cmp dword [ss_class], SIG_CLASS_SYSTEM
    ja .perm_level                      ; user 类:uid 不限,只查级别
    cmp ecx, 1                          ; system 类:uid 0/1
    ja .perm_deny
.perm_level:
    cmp dword [ss_level], SIG_LEVEL_NONE
    jne .perm_ok
.perm_deny:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_perm_denied
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    mov dword [ss_ret], -1
    jmp .out
.perm_ok:

    ; ---- 2) 找目标 ----
    mov eax, [ss_pid]
    test eax, eax
    jz .out
    cmp eax, SCHED_MAX
    ja .out
    dec eax
    mov [ss_slot], eax
    imul eax, TCB_SIZE
    add eax, tcb_table
    mov [ss_tcb], eax
    cmp dword [eax + TCB_STATE], ST_EMPTY
    je .out

    ; ---- 3) 记 pending(bit = 动作号)----
    mov ecx, [ss_action]
    mov eax, 1
    shl eax, cl
    mov [ss_bit], eax
    mov edx, [ss_tcb]
    or  [edx + TCB_PENDING], eax

    ; ---- 4) 级别 2/3 且被屏蔽 → 先压着 ----
    cmp dword [ss_level], SIG_LEVEL_USER
    jb .deliver
    mov edx, [ss_tcb]
    mov ecx, [edx + TCB_BLOCKED]
    and ecx, eax
    jz .deliver
    mov dword [ss_ret], 0
    jmp .out

.deliver:
    ; ---- 5) 按动作执行默认动作 ----
    mov eax, [ss_action]
    cmp eax, SIG_ACT_STOP
    je .do_stop
    cmp eax, SIG_ACT_CONT
    je .do_cont
    cmp eax, SIG_ACT_INTR
    jae .accept                         ; intr/usr:只投 pending
    mov edx, [ss_tcb]
    mov eax, 128 + 9                    ; 128 + SIGKILL(9) → 被信号杀死
    call process_terminate
    mov [ss_ret], eax
    jmp .out

.do_stop:
    mov edx, [ss_tcb]
    cmp dword [edx + TCB_STATE], ST_ALIVE
    jne .accept
    mov dword [edx + TCB_STATE], ST_STOPPED
    jmp .accept

.do_cont:
    mov edx, [ss_tcb]
    cmp dword [edx + TCB_STATE], ST_STOPPED
    jne .accept
    mov dword [edx + TCB_STATE], ST_ALIVE
.accept:
    mov dword [ss_ret], 0
.out:
    popad
    mov eax, [ss_ret]
    ret

; ---------------------------------------------------------------------------
;  process_signal_block:设置当前进程的信号屏蔽位图
;    入:eax = 新位图(bit = 动作号)
;    出:eax = 旧位图
;  简化:pending 里"已经被屏蔽的"继续压着,已解除屏蔽的这次不补投(下一阶段
;  有真正的信号处理函数时再在返回用户态前统一投递)。
; ---------------------------------------------------------------------------
process_signal_block:
    mov edx, eax
    call process_cur_tcb
    mov ecx, [eax + TCB_BLOCKED]
    mov [eax + TCB_BLOCKED], edx
    and [eax + TCB_PENDING], edx
    mov eax, ecx
    ret

; ---------------------------------------------------------------------------
;  signal_parse:把 "<权限类>:<动作>:<级别>" 解析成 signal_t
;    入:esi = 字符串
;    出:CF=0 时 eax = signal_t,ebx = 权限类,ecx = 动作,edx = 级别
;        CF=1 语法错误
;  权限类接受 super/system/user,以及别名 root、SYSTEM(都映射到 super —— 本阶段
;  还没有身份系统,先把名字认下来)。
; ---------------------------------------------------------------------------
signal_parse:
    ; ---- 权限类 ----
    call sig_take_field
    jc .bad
    cmp al, ':'
    jne .bad
    mov edx, s_super
    call sig_eq
    test eax, eax
    jnz .cls0
    mov edx, s_root
    call sig_eq
    test eax, eax
    jnz .cls0
    mov edx, s_system
    call sig_eq
    test eax, eax
    jnz .cls1
    mov edx, s_system_upper
    call sig_eq
    test eax, eax
    jnz .cls1
    mov edx, s_user
    call sig_eq
    test eax, eax
    jnz .cls2
    jmp .bad
.cls0:
    mov dword [sp_class], SIG_CLASS_SUPER
    jmp .do_action
.cls1:
    mov dword [sp_class], SIG_CLASS_SYSTEM
    jmp .do_action
.cls2:
    mov dword [sp_class], SIG_CLASS_USER

.do_action:
    ; ---- 动作 ----
    call sig_take_field
    jc .bad
    cmp al, ':'
    jne .bad
    mov edx, s_kill
    call sig_eq
    test eax, eax
    jnz .act_kill
    mov edx, s_term
    call sig_eq
    test eax, eax
    jnz .act_term
    mov edx, s_stop
    call sig_eq
    test eax, eax
    jnz .act_stop
    mov edx, s_cont
    call sig_eq
    test eax, eax
    jnz .act_cont
    mov edx, s_intr
    call sig_eq
    test eax, eax
    jnz .act_intr
    mov edx, s_usr
    call sig_eq
    test eax, eax
    jnz .act_usr
    jmp .bad
.act_kill:
    mov dword [sp_action], SIG_ACT_KILL
    jmp .do_level
.act_term:
    mov dword [sp_action], SIG_ACT_TERM
    jmp .do_level
.act_stop:
    mov dword [sp_action], SIG_ACT_STOP
    jmp .do_level
.act_cont:
    mov dword [sp_action], SIG_ACT_CONT
    jmp .do_level
.act_intr:
    mov dword [sp_action], SIG_ACT_INTR
    jmp .do_level
.act_usr:
    mov dword [sp_action], SIG_ACT_USR

.do_level:
    ; ---- 级别:0..3 ----
    call sig_take_field
    jc .bad
    cmp al, 0
    jne .bad                            ; 级别后面不该再有东西
    mov esi, sig_buf
    xor eax, eax
    xor ecx, ecx
.num:
    movzx edx, byte [esi]
    test dl, dl
    jz .num_done
    cmp dl, '0'
    jb .bad
    cmp dl, '9'
    ja .bad
    cmp ecx, 2
    ja .bad
    imul eax, eax, 10
    sub edx, '0'
    add eax, edx
    inc esi
    inc ecx
    jmp .num
.num_done:
    test ecx, ecx
    jz .bad
    cmp eax, SIG_LEVEL_HINT
    ja .bad
    mov [sp_level], eax

    ; ---- 拼成 32 位 signal_t ----
    mov eax, [sp_class]
    shl eax, SIG_CLASS_SHIFT
    mov edx, [sp_action]
    shl edx, SIG_ACTION_SHIFT
    or  eax, edx
    mov edx, [sp_level]
    or  eax, edx
    mov ebx, [sp_class]
    mov ecx, [sp_action]
    mov edx, [sp_level]
    clc
    ret
.bad:
    stc
    ret

; ---------------------------------------------------------------------------
;  sig_take_field:从 esi 抄一个 ":" 分隔的字段到 sig_buf
;    出:al = 这个字段后面的分隔符(0 = 到头,':' = 还有下一段)
;        CF=1 字段超长;esi 指向分隔符之后(到头时指向 NUL)
; ---------------------------------------------------------------------------
sig_take_field:
    push edi
    push ecx
    mov edi, sig_buf
    xor ecx, ecx
.loop:
    mov al, [esi]
    test al, al
    jz .end
    cmp al, ':'
    je .colon
    cmp ecx, 20
    jae .bad
    mov [edi], al
    inc edi
    inc esi
    inc ecx
    jmp .loop
.colon:
    mov byte [edi], 0
    inc esi
    pop ecx
    pop edi
    clc
    ret
.end:
    mov byte [edi], 0
    pop ecx
    pop edi
    clc
    ret
.bad:
    stc
    pop ecx
    pop edi
    ret

; ---------------------------------------------------------------------------
;  sig_eq:sig_buf 和 edx 指向的 NUL 字符串相等?→ eax = 1/0
; ---------------------------------------------------------------------------
sig_eq:
    push esi
    push edi
    mov esi, sig_buf
    mov edi, edx
.loop:
    mov al, [esi]
    cmp al, [edi]
    jne .no
    test al, al
    jz .yes
    inc esi
    inc edi
    jmp .loop
.yes:
    mov eax, 1
    jmp .out
.no:
    xor eax, eax
.out:
    pop edi
    pop esi
    ret

; ---------------------------------------------------------------------------
;  process_spawn_kernel:起一个内核线程,并把它记成当前进程的孩子
;    入:eax = 入口,ebx = 名字
;    出:CF=0 时 eax = 线程号(槽),CF=1 = 没槽 / 没内存
;  给 shell 的 fork 命令和 exec 子线程用。
; ---------------------------------------------------------------------------
process_spawn_kernel:
    push ebx
    call sched_spawn
    jc .fail
    ; 填父进程/归属(此时 eax = 槽号)
    mov edx, eax
    imul edx, TCB_SIZE
    add edx, tcb_table
    mov ecx, [sched_cur]
    mov [edx + TCB_OWNER], ecx
    inc ecx
    mov [edx + TCB_PARENT], ecx
    ; 登录身份从当前进程继承(最小多用户)
    ;   注意:这里不能踩 eax —— 本函数的返回值就是 eax=槽号,
    ;   下面要用 push/pop 把它保住(commit3 曾漏了,导致 fork 拿到
    ;   一个"当前 TCB 指针"当 pid,test-proc 全挂)。
    push eax
    mov eax, [sched_cur]
    imul eax, TCB_SIZE
    add eax, tcb_table
    mov ecx, [eax + TCB_UID]
    mov [edx + TCB_UID], ecx
    mov ecx, [eax + TCB_GID]
    mov [edx + TCB_GID], ecx
    pop eax
    clc
    pop ebx
    ret
.fail:
    stc
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  process_exec:在**当前进程**里装入一个程序,然后 iret 进 ring 3(不返回)
;    入:eax = 程序名(可以带路径;没有扩展名不自动补,请写全 PROG.BIN)
;  流程照抄 cmd_run 里"读文件 → 展开 ELF → 暂存页 → 建空间 → 弹床/栈/参数页 →
;  iret"的那一段,区别只有:不建新线程、旧地址空间先拆掉。
;  失败 → 退出码 1(父进程 wait 能拿到),并打印原因。
; ---------------------------------------------------------------------------
process_exec:
    pushad
    mov esi, eax
    mov edi, proc_exec_buf
    mov ecx, 60
.copy_name:
    lodsb
    test al, al
    jz .name_done
    stosb
    dec ecx
    jnz .copy_name
.name_done:
    mov byte [edi], 0

    mov eax, [fat_dir]
    mov [proc_exec_dir], eax

    call loader_lock

    ; ---- 1) 找文件:先按给的路径,stat 不到再试根目录的 BIN/ ----
    ;  fat_path 只负责"按 / 分段 chdir",不检查文件在不在(和 cmd_run 一样),
    ;  所以关在 fat_stat 上判。程序一般放在 /BIN 下,而 shell 的 cwd 是根,
    ;  于是 "HANG.BIN" 这种裸名字必须再按 "BIN/HANG.BIN" 试一次。
    mov dword [proc_exec_tried], 0
.search:
    mov esi, proc_exec_buf
    call fat_path
    jc .try_bin
    mov [proc_exec_file], eax
    mov esi, eax
    call fat_stat
    cmp eax, -1
    je .try_bin
    cmp eax, (SPACE_IMG_PAGES - 1) * 4096
    ja .nofile
    mov [proc_exec_size], eax
    jmp .have_size
.try_bin:
    cmp dword [proc_exec_tried], 0
    jne .nofile
    mov dword [proc_exec_tried], 1
    mov dword [fat_dir], 0
    mov esi, proc_exec_buf
    mov edi, proc_exec_path
    mov al, 'B'
    stosb
    mov al, 'I'
    stosb
    mov al, 'N'
    stosb
    mov al, '/'
    stosb
    mov ecx, 59
.copy_path:
    lodsb
    stosb
    test al, al
    jz .path_done
    dec ecx
    jnz .copy_path
    mov byte [edi], 0
.path_done:
    mov esi, proc_exec_path
    call fat_path
    jc .nofile
    mov [proc_exec_file], eax
    mov esi, eax
    call fat_stat
    cmp eax, -1
    je .nofile
    cmp eax, (SPACE_IMG_PAGES - 1) * 4096
    ja .nofile
    mov [proc_exec_size], eax
.have_size:
    mov esi, [proc_exec_file]
    mov edi, PROG_ADDR
    call fat_read_file
    cmp eax, -1
    je .nofile
    mov [proc_exec_size], eax

    ; ---- 2) ELF?展开成平铺镜像 ----
    mov dword [proc_exec_entry], PROG_ADDR
    mov esi, PROG_ADDR
    cmp dword [esi], 0x464C457F
    jne .flat_ready
    mov eax, [proc_exec_size]
    call elf_load
    test eax, eax
    jz .nofile
    mov [proc_exec_size], eax
    mov [proc_exec_entry], edx
.flat_ready:
    mov eax, [proc_exec_dir]
    mov [fat_dir], eax                  ; 文件目录还给 shell 的 cwd

    ; ---- 3) 旧空间先拆(第一次 exec 时什么也没有)----
    call space_destroy

    ; ---- 4) 镜像拷进本进程自己的暂存区 ----
    mov eax, [proc_exec_size]
    add eax, 4095
    shr eax, 12
    test eax, eax
    jz .nofile
    mov [proc_exec_pages], eax
    mov ecx, eax
    call pmem_alloc_pages
    test eax, eax
    jz .nomem
    mov edx, [space_cur]
    mov [edx + TCB_SP_STAGE_PA], eax
    mov ecx, [proc_exec_pages]
    mov [edx + TCB_SP_STAGE_PAGES], ecx
    mov esi, PROG_ADDR
    mov edi, eax
    mov ecx, [proc_exec_size]
    add ecx, 3
    shr ecx, 2
    rep movsd

    ; ---- 5) 建新地址空间 ----
    call space_create
    jc .nomem
    mov eax, [proc_exec_size]
    call space_set_image
    call space_activate
    call space_prepare_user             ; 弹床页 + 用户栈页
    test eax, eax
    jz .nomem
    mov eax, [space_cur]
    mov eax, [eax + TCB_SP_ARGSVA]
    call space_user_page                ; 参数页(零 = 没有参数)
    test eax, eax
    jz .nomem

    ; ---- 6) 退出/中断要用它的内核栈顶 ----
    mov edx, [space_cur]
    mov eax, [edx + TCB_STACK]
    add eax, SCHED_STACK_PAGES * 4096
    mov [edx + TCB_SP_RUNESP], eax
    mov [tss_blk + TSS_ESP0], eax
    mov dword [edx + TCB_SP_RUNSTAT], 0
    mov dword [edx + TCB_SP_RUNNING], 1
    mov dword [edx + TCB_SP_KILLREQ], 0
    call loader_unlock

    ; ---- 7) 进 ring 3 ----
    mov ax, USER_DATA_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov edx, [space_cur]
    push dword USER_DATA_SEG            ; SS3
    push dword [edx + TCB_SP_STACKTOP]  ; ESP3
    push dword EFLAGS_IF
    push dword USER_CODE_SEG            ; CS3
    push dword [proc_exec_entry]        ; EIP
    iret

.nofile:
    mov eax, [proc_exec_dir]
    mov [fat_dir], eax
    call loader_unlock
    mov esi, msg_exec_nofile
    jmp .die
.nomem:
    mov eax, [proc_exec_dir]
    mov [fat_dir], eax
    call loader_unlock
    mov esi, msg_exec_nomem
.die:
    mov al, COL_ERR
    call term_set_color
    call term_print
    mov al, 10
    call term_putc
    mov al, COL_NORMAL
    call term_set_color
    mov eax, 1
    call process_exit                   ; 不返回

; ---------------------------------------------------------------------------
;  proc_exec_child:shell 的 "fork <程序>" 起的子线程入口
;  程序名放在 proc_exec_name(父进程先填好)。
; ---------------------------------------------------------------------------
proc_exec_child:
    mov eax, [proc_exec_name]
    call process_exec
    mov eax, 1
    call process_exit

; ---------------------------------------------------------------------------
;  proc_demo_child:shell 的 "fork" 用的演示子进程 —— 跑一会儿,带退出码 7 走
; ---------------------------------------------------------------------------
proc_demo_child:
    mov ecx, 600                          ; 约 6 秒(全局 tick);留够 ps/kill 的观察窗口
    call pit_wait_ticks
    mov eax, 7
    call process_exit

; ---------------------------------------------------------------------------
;  process_status_name:eax = TCB_STATE → esi = 状态串(ps 用)
; ---------------------------------------------------------------------------
process_status_name:
    cmp eax, ST_ZOMBIE
    je .zombie
    cmp eax, ST_STOPPED
    je .stopped
    mov esi, st_run
    ret
.zombie:
    mov esi, st_zombie
    ret
.stopped:
    mov esi, st_stopped
    ret

; ---------------------------------------------------------------------------
;  数据
; ---------------------------------------------------------------------------
pf_frame        dd 0
pf_parent_tcb   dd 0
pf_parent_pd    dd 0
pf_parent_pt    dd 0
pf_slot         dd 0
pf_child_tcb    dd 0
pf_child_stack  dd 0
pf_guard_idx    dd 0                    ; 父进程 guard 页在窗口页表中的下标
pf_child_guard_pa dd 0                  ; 子进程自己那页 guard
pf_child_pd     dd 0
pf_child_pt     dd 0
pf_child_frame  dd 0
pf_result       dd 0

pw_pid          dd 0
pw_slot         dd 0
pw_ret          dd 0
proc_last_child dd 0

pt_tcb          dd 0
pt_code         dd 0
pt_slot         dd 0
pt_ret          dd 0

ss_pid          dd 0
ss_sig          dd 0
ss_class        dd 0
ss_action       dd 0
ss_level        dd 0
ss_slot         dd 0
ss_tcb          dd 0
ss_bit          dd 0
ss_ret          dd 0

sp_class        dd 0
sp_action       dd 0
sp_level        dd 0
sig_buf         times 24 db 0

proc_exec_name  dd 0                    ; shell "fork <程序>" 传进来的名字指针
proc_exec_buf   times 64 db 0
proc_exec_path  times 64 db 0
proc_exec_dir   dd 0
proc_exec_file  dd 0
proc_exec_size  dd 0
proc_exec_entry dd 0
proc_exec_pages dd 0
proc_exec_tried dd 0

nm_child        db 'child', 0
nm_demo         db 'demo', 0
nm_exec         db 'exec', 0
st_run          db 'RUN', 0
st_zombie       db 'ZOMBIE', 0
st_stopped      db 'STOP', 0

s_super         db 'super', 0
s_system        db 'system', 0
s_user          db 'user', 0
s_root          db 'root', 0
s_system_upper  db 'SYSTEM', 0
s_kill          db 'kill', 0
s_term          db 'term', 0
s_stop          db 'stop', 0
s_cont          db 'cont', 0
s_intr          db 'intr', 0
s_usr           db 'usr', 0
s_none          db 'none', 0

; 给 shell(cmd_kill)按编号取名字
sig_class_strs  dd s_super, s_system, s_user
sig_action_strs dd s_none, s_kill, s_term, s_stop, s_cont, s_intr, s_usr

msg_exec_nofile db 'exec: program not found', 13, 10, 0
msg_exec_nomem  db 'exec: not enough memory to build the address space', 13, 10, 0
msg_perm_denied db 'permission denied: need super', 13, 10, 0
