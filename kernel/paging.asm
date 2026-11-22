; ============================================================================
;  KKernel — 分页(页目录 + 页表)
;
;  ── 分页在干嘛 ──────────────────────────────────────────────────────────
;  开分页之前,线性地址就是物理地址。开了 CR0.PG 之后,CPU 把线性地址
;  按 两级页表 翻译成物理地址:
;
;      线性地址 = [ 页目录索引(10 位) | 页表索引(10 位) | 页内偏移(12 位) ]
;                    ↓ 查 CR3 指向的页目录(4 KiB,1024 项 × 4 字节)
;                    ↓ 查出页表基址,再查页表(4 KiB,1024 项)
;                    ↓ 查出**物理页**基址,加上偏移
;
;  每个表项 4 字节:高 20 位 = 物理页基址(所以页必须 4 KiB 对齐),
;  低 12 位是标志位。这里只用两个:
;      bit0 P   present   1 = 这页存在,0 = 不存在(访问就触发 14 号页错误)
;      bit1 R/W writable  1 = 可写,0 = 只读
;  所以 "物理页 | 0x3" = 存在且可写。
;
;  一个页表管 4 MiB(1024 项 × 4 KiB),一个页目录管 4 GiB。
;
;  ── 这个阶段的布局 ──────────────────────────────────────────────────────
;  1. 恒等映射(线性 = 物理)前 16 MiB —— 内核、VGA(0xB8000)、IDT、栈、各种缓冲、
;     字库,还有 4 MiB 以上的**页池**都在里面,所以指针可以直接当物理地址用,
;     写代码完全不用想 MMU(这就是"平铺的手感")
;  2. VBE 线性帧缓冲通常在 0xFD000000 这种高地址,单独挂一张页表映射进来
;     (不映射的话第一次往屏幕写像素就吃 14 号页错误)
;  3. paging_map / paging_unmap 是**动态建表**:页表不存在就从页池里拿一页现建,
;     映射完还能解掉、把页还回页池 —— shell 里的 pmap / pumap / ptest 玩的就是它
;
;  开分页之前必须先把要用的表都填好,开之后下一条指令就得在映射范围内 —— 顺序不能错。
;
;  表放哪儿:页目录 0x1000,恒等页表 0-4 MiB 固定用 0x2000(PT_LOW),
;  帧缓冲页表 0x4000(PT_LFB)。4 MiB 以上的恒等页表**从页池动态要** ——
;  paging_init 在 pmem_init 之后跑,此时页池已经可用;这些页在开分页前
;  按物理地址写,开分页后它们天然落在恒等映射里。
; ============================================================================

PD_ADDR     equ 0x1000                 ; 页目录(4 KiB)
PT_LOW      equ 0x2000                 ; 页表:恒等 0x000000-0x3FFFFF
PT_LFB      equ 0x4000                 ; 页表:给 VBE 线性帧缓冲用

PAGE_P      equ 1                      ; bit0 present
PAGE_RW     equ 2                      ; bit1 writable
PAGE_USER   equ 4                      ; bit2 ring 3 也能碰(U/S)。内核页故意不设这一位
PAGE_COW    equ 0x200                  ; bit9 写时复制:页是只读的,写它要复制一份
                                       ;   (bit9 是 CPU 不用的软件位)

; 注意:帧缓冲地址用 kmain.asm 里的 fb_phys 变量(内核启动时从 BOOTINFO 抄过来的)

; 把一张页表填满:恒等映射从 %2 开始的 4 MiB
%macro IDENT_PT 2
    mov edi, %1
    mov eax, %2
    or  eax, PAGE_P | PAGE_RW
    mov ecx, 1024
%%loop:
    mov [edi], eax
    add edi, 4
    add eax, 4096                      ; 下一页
    dec ecx
    jnz %%loop
%endmacro

; ---------------------------------------------------------------------------
;  paging_init:建表 → 开分页
; ---------------------------------------------------------------------------
paging_init:
    pushad

    ; ---- 1) 清页目录(1024 项全得是 0;页表下面整张填满,不用先清)----
    mov edi, PD_ADDR
    xor eax, eax
    mov ecx, 1024
    rep stosd

    ; ---- 2) 页目录挂恒等页表:0-4 MiB 固定,4 MiB 以上按 ident_limit 动态要页表 ----
    ;   ident_limit 是 kmain.asm 启动时按 E820 探到的 RAM 算的
    ;   (4 MiB 起步,4 MiB 对齐,封顶 256 MiB)。
    ;   0-4 MiB 永远要(内核/VGA/低区缓冲/字库都在里面);往后每 4 MiB 一张页表,
    ;   页表页从页池拿(此时还没开分页,物理地址直接写;开分页后自动可见)。
    mov eax, PT_LOW | PAGE_P | PAGE_RW
    mov [PD_ADDR + 0 * 4], eax         ; 管 0x00000000-0x003FFFFF
    IDENT_PT PT_LOW, 0x000000

    mov ebx, 1                         ; 页目录项下标
    mov esi, 0x400000                  ; 当前这 4 MiB 段的物理基址
.dyn_pt_loop:
    cmp esi, [ident_limit]
    jae .ident_done
    call pmem_alloc                    ; 要一页当页表
    test eax, eax
    jz .ident_done                     ; 页池空了(理论上不会:页池 >= 页表数)
    mov edx, eax                       ; 留一份页表物理地址
    mov edi, eax
    mov ecx, 1024
    mov eax, esi
    or  eax, PAGE_P | PAGE_RW
.dyn_fill:
    mov [edi], eax
    add edi, 4
    add eax, 4096
    dec ecx
    jnz .dyn_fill
    mov eax, edx
    or  eax, PAGE_P | PAGE_RW
    mov [PD_ADDR + ebx * 4], eax       ; 挂进页目录
    inc ebx
    add esi, 0x400000
    jmp .dyn_pt_loop
.ident_done:

    ; ---- 4) 把 VBE 线性帧缓冲也映射进来 ----
    ; 做法:按 4 MiB 对齐算出页目录索引,给它挂一张新页表,里面 1024 项都指向那 4 MiB。
    cmp dword [fb_phys], 0             ; stub 没拿到图形模式就跳过
    je .no_lfb
    mov eax, [fb_phys]
    shr eax, 22                        ; 页目录索引(4 MiB 为单位)
    mov [lfb_pde_idx], eax
    shl eax, 22                        ; 对齐到 4 MiB 的基址
    mov [lfb_base], eax

    mov edi, PT_LFB
    mov eax, [lfb_base]
    or  eax, PAGE_P | PAGE_RW
    mov ecx, 1024
.fill_lfb:
    mov [edi], eax
    add edi, 4
    add eax, 4096
    dec ecx
    jnz .fill_lfb

    mov eax, PT_LFB
    or  eax, PAGE_P | PAGE_RW
    mov edi, [lfb_pde_idx]
    mov [PD_ADDR + edi * 4], eax

.no_lfb:

    ; ---- 5) CR3 ← 页目录物理地址,然后开 CR0.PG ----
    mov eax, PD_ADDR
    mov cr3, eax
    mov eax, cr0
    or  eax, 0x80010000                ; CR0.PG = 1,CR0.WP = 1
                                       ;   WP:内核(ring0)写只读页也触发页错误 ——
                                       ;   COW 缺页处理靠它,不然内核写会绕过
    mov cr0, eax

    popad
    ret

; ---------------------------------------------------------------------------
;  paging_map:把虚拟地址 eax 映射到物理地址 ebx(都要 4 KiB 对齐),ecx = 标志
;  页表不存在就找页池要一页现建(这就是动态建表)。CF=1 = 失败(页池空了)
;  破坏 eax/ebx/ecx/edx/edi(调用方不用指望它们)
; ---------------------------------------------------------------------------
paging_map:
    pushad
    mov [map_va], eax
    mov [map_pa], ebx
    mov [map_flags], ecx

    mov edi, eax
    shr edi, 22
    and edi, 0x3FF                     ; 页目录项下标
    mov edx, [PD_ADDR + edi * 4]
    test edx, 1
    jnz .have_pt                       ; 已经有页表了,直接用

    ; ---- 没有页表:从页池拿一页,清零,挂进页目录 ----
    call pmem_alloc
    test eax, eax
    jz .fail                           ; 页池空了
    mov ebx, eax
    mov edi, eax                       ; 页池在恒等映射里,可以直接写
    xor eax, eax
    mov ecx, 1024
    rep stosd
    mov eax, ebx
    or  eax, PAGE_P | PAGE_RW
    mov edi, [map_va]
    shr edi, 22
    and edi, 0x3FF
    mov [PD_ADDR + edi * 4], eax
    mov edx, eax

.have_pt:
    and edx, 0xFFFFF000                ; 页表的物理地址
    mov edi, [map_va]
    shr edi, 12
    and edi, 0x3FF                     ; 页表项下标
    mov eax, [map_pa]
    and eax, 0xFFFFF000
    or  eax, [map_flags]
    mov [edx + edi * 4], eax
    mov eax, [map_va]
    invlpg [eax]                       ; 让 CPU 忘掉这个地址的旧翻译
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; ---------------------------------------------------------------------------
;  paging_unmap:解掉虚拟地址 eax 处的映射
;  返回 eax = 原来映到的物理地址(本来没映 = 0)
;  如果这张页表被解空了,连页表一起还给页池(PDE 也清掉)
; ---------------------------------------------------------------------------
paging_unmap:
    pushad
    mov [map_va], eax
    mov dword [map_pa], 0

    mov edi, eax
    shr edi, 22
    and edi, 0x3FF
    mov edx, [PD_ADDR + edi * 4]
    test edx, 1
    jz .done                           ; 连页表都没有
    and edx, 0xFFFFF000
    mov edi, [map_va]
    shr edi, 12
    and edi, 0x3FF
    mov eax, [edx + edi * 4]
    mov [map_pa], eax                  ; 记下旧 PTE(当返回值)
    test eax, 1
    jz .done                           ; 本来就没映
    mov dword [edx + edi * 4], 0
    mov eax, [map_va]
    invlpg [eax]

    ; ---- 这张页表还有别的映射吗?没有就整张还回去 ----
    xor ecx, ecx
.scan:
    cmp dword [edx + ecx * 4], 0
    jne .done                          ; 还有别的项,页表留着
    inc ecx
    cmp ecx, 1024
    jb .scan

    mov eax, [map_va]
    shr eax, 22
    and eax, 0x3FF
    mov dword [PD_ADDR + eax * 4], 0   ; PDE 清掉
    mov eax, [map_va]
    invlpg [eax]
    mov eax, edx
    call pmem_free                     ; 页表页还给页池(不是池里的会被拒,无所谓)

.done:
    mov eax, [map_pa]
    and eax, 0xFFFFF000
    mov [map_pa], eax
    popad
    mov eax, [map_pa]                  ; popad 会把 eax 冲掉,所以从内存里取
    ret

; ---------------------------------------------------------------------------
;  paging_translate:eax = 虚拟地址 → eax = 物理地址。CF=1 = 没映射
; ---------------------------------------------------------------------------
paging_translate:
    push ebx
    push edi
    mov edi, eax
    shr edi, 22
    and edi, 0x3FF
    mov ebx, [PD_ADDR + edi * 4]
    test ebx, 1
    jz .no
    and ebx, 0xFFFFF000
    mov edi, eax
    shr edi, 12
    and edi, 0x3FF
    mov ebx, [ebx + edi * 4]
    test ebx, 1
    jz .no
    and ebx, 0xFFFFF000
    and eax, 0xFFF                     ; 页内偏移
    add eax, ebx
    pop edi
    pop ebx
    clc
    ret
.no:
    xor eax, eax
    pop edi
    pop ebx
    stc
    ret

; ---------------------------------------------------------------------------
;  paging_ident_unmap:eax = 物理页(4 MiB 以上页池里的)→ 从恒等映射摘掉
;  用于内核栈 guard 页:摘掉后一碰就 #PF,不会静悄悄踩别人。
;  只改 PTE(动态恒等映射页表是各进程共享的那张),不碰 PT 本身。
; ---------------------------------------------------------------------------
paging_ident_unmap:
    push eax
    push ecx
    push edx
    push edi
    mov edi, eax
    shr edi, 22                        ; PDE 下标(≥1:页池在 4 MiB 以上)
    mov edx, [PD_ADDR + edi * 4]
    test edx, PAGE_P
    jz .out
    and edx, 0xFFFFF000
    mov ecx, eax
    shr ecx, 12
    and ecx, 0x3FF
    mov dword [edx + ecx * 4], 0
    invlpg [eax]
.out:
    pop edi
    pop edx
    pop ecx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  paging_ident_map:eax = 物理页 → 重新挂回恒等映射(P|RW)
;  和 paging_ident_unmap 配对:还 guard 页之前先映射回来。
; ---------------------------------------------------------------------------
paging_ident_map:
    push eax
    push ecx
    push edx
    push edi
    mov edi, eax
    shr edi, 22
    mov edx, [PD_ADDR + edi * 4]
    test edx, PAGE_P
    jz .out                            ; 没有恒等页表(理论上不会发生)
    and edx, 0xFFFFF000
    mov ecx, eax
    shr ecx, 12
    and ecx, 0x3FF
    or eax, PAGE_P | PAGE_RW
    mov [edx + ecx * 4], eax
    and eax, 0xFFFFF000
    invlpg [eax]
.out:
    pop edi
    pop edx
    pop ecx
    pop eax
    ret

; ===========================================================================
;  ── 程序地址空间:每条线程一套页目录 + 按需分页 ──────────────────────────
;  第一步(全分页)已经做完:每条 shell 线程跑程序前都给它建一套**自己的页目录**:
;
;        页目录   = 内核页目录的副本(内核、VGA、IDT、栈、帧缓冲都还在)
;        页表[0]  = PT_LOW 的副本,但两个窗口的项被清成"不存在"
;
;  ★ 状态在哪:以前 space_pd / space_pt / space_live … 是全局变量,所以全系统
;    同时只能跑一个程序;现在它们都在**当前线程的 TCB**(TCB_SP_*)里,
;    space_cur 指向当前线程那一块,sched_pick 每次换人时更新它。
;    于是 4 条 shell 线程可以各跑各的 ring3 程序。
;
;  第二步就是**按需分页**(demand paging):程序拿到的是 208 页的地址窗口,
;  但建表的时候**一页物理内存都不给**。程序第一次碰某页 → CPU 报 14 号页错误
;  → page_fault_try_handle 判断这个地址属于哪个窗口、从页池现拿一页、
;  把内容准备好(镜像页:从该空间自己的暂存区拷;堆/`.bss` 页:留 0)→ 填进
;  页表 → iret 回去把那条指令**重执行一遍**,这次就通了。程序完全不知道发生过什么。
;
;     程序视角:                         物理内存:
;       0x120000 ┌──────────────┐          程序碰过的页才真的存在,
;                │  镜像 128 页  │          HELLO.BIN 这种小程序只拿走 1 页,
;       0x180000 ├──────────────┤          而不是像以前那样一上来就占 208 页。
;                │   堆 80 页    │
;       0x1F0000 └──────────────┘
;
;  好处:① 小程序不再白占 832 KiB;② `.bss`(文件之外的页)天然是零页;
;        ③ 一个程序能吃的上限是 208 页,越出窗口就是真错误(panic)。
;  还没做:页面换出/置换(没有 swap、没有"页用完了挑一页扔掉")、写时复制、
;         精确的越界检测(窗口内的空洞也会给页)。这几样都不打算做 —— 玩具够了。
;
;  内核窗口继续恒等映射 —— 所以 int 0x30 那些内核函数照旧能用,**不需要 ring 3**;
;  程序传给内核的指针也照旧解得开(那会儿用的就是程序这套页表)。
; ===========================================================================
%ifndef SPACE_IMG_VA
; ★ 这些常量在 kernel/kmain.asm 里定义一份(布局打印要用),这里只是兜底:
;   如果单独汇编本文件(没有 kmain)也能过。两边必须一致。
SPACE_IMG_VA     equ 0x120000          ; 程序镜像窗口(shell.asm 的 PROG_ADDR)
SPACE_IMG_PAGES  equ 0x60              ; 384 KiB(0x120000-0x17FFFF,见 include/kkernel.h)
SPACE_HEAP_VA    equ 0x180000          ; 堆窗口起点(KK_HEAP_START)
SPACE_TRAMP_VA   equ SPACE_IMG_VA + (SPACE_IMG_PAGES - 1) * 4096
%endif
; 堆窗口页数 / 参数页 / 用户栈顶是运行时变量(kmain.asm 算好):
;   space_heap_pages / space_args_va / space_stack_va / space_user_stack_top
SPACE_ARGS_COPY  equ (4 + 2048 + 3) / 4                            ; 拷贝长度(dword 数)
; ★ 栈顶那 4 字节(堆窗口最后一页顶部往下 4 字节)就是 space_prepare_user 写进去的弹床地址:
;   程序 `ret` 时 [esp] 正是这里。**别**把 ESP 设成 0x1F0000(窗口外、内核临时缓冲):
;   程序第一次 ret 就会撞上"内核的页",错误码 bit0=1 —— 这个坑踩过一次。
; 两个窗口在 0x120000-0x1EFFFF 里是**连着**的(96 + 112 = 208 页),
; 所以在私有页表里清/扫这两个窗口用一段连续下标就够:
;   下标 = 0x120000>>12 = 288 起,共 208 项 → 0x120000-0x1EFFFF
;   后面 0x1F0000 是内核自己的临时缓冲,不能碰

; ---------------------------------------------------------------------------
;  space_create:建一套程序地址空间 —— 只给页目录 + 页表两页,窗口页一页不给
;  返回 eax = 页目录物理地址(0 = 页池不够);另外填好当前线程 TCB 里的
;  TCB_SP_PD / TCB_SP_PT。**每条线程各建各的**,互不干扰。
; ---------------------------------------------------------------------------
space_create:
    pushad
    mov edx, [space_cur]
    mov dword [edx + TCB_SP_PD], 0
    mov dword [edx + TCB_SP_PT], 0
    mov dword [edx + TCB_SP_PAGES], 0
    mov dword [edx + TCB_SP_LIVE], 0
    ; ★ TCB_SP_IMGBYTES 这里**不能清**:它是"这次要跑的镜像是多大"的输入参数,
    ;   由 space_set_image 填好 —— 之前在这里清成 0,结果整个镜像窗口都被当成
    ;   `.bss` 填零页,程序拿到的是一页页的 0 字节(执行起来一路乱跳到野地址)。
    mov dword [edx + TCB_SP_PFRUN], 0
    mov dword [edx + TCB_SP_PFIMG], 0
    mov dword [edx + TCB_SP_PFHEAP], 0
    mov dword [edx + TCB_SP_FIRSTPA], 0

    ; ---- 1) 页目录:从页池拿一页,把内核页目录整份拷过来 ----
    call pmem_alloc
    test eax, eax
    jz .fail
    mov edx, [space_cur]
    mov [edx + TCB_SP_PD], eax
    mov edi, eax
    mov esi, PD_ADDR
    mov ecx, 1024
    rep movsd

    ; ---- 2) 私有页表:拷 PT_LOW(0-4 MiB 的映射),挂到页目录[0] ----
    call pmem_alloc
    test eax, eax
    jz .fail
    mov edx, [space_cur]
    mov [edx + TCB_SP_PT], eax
    mov edi, eax
    mov esi, PT_LOW
    mov ecx, 1024
    rep movsd
    mov edx, [space_cur]
    mov eax, [edx + TCB_SP_PT]
    or  eax, PAGE_P | PAGE_RW | PAGE_USER
    ; ★ 这一级也必须带 U/S —— 页表是"逐级查权限"的:PD 项说"用户不许",
    ;   下面页表项写得再漂亮,ring 3 一访问还是保护违规(#PF,错误码 bit0=1)。
    ;   这里踩过:程序第一条指令就挂在 0x120000,错误码 bit0=1 而不是"没有页"。
    mov edi, [edx + TCB_SP_PD]
    mov [edi], eax

    ; ---- 3) 两个窗口的项清成"不存在" —— 这一行就是按需分页的起点 ----
    ; PT_LOW 是恒等映射的,那两个窗口的项本来也"存在"(指向内核视角的物理页)。
    ; 不抹掉的话程序一访问就拿到内核的物理页,私有页就白搭了。
    mov edi, [edx + TCB_SP_PT]
    mov eax, SPACE_IMG_VA
    shr eax, 12
    and eax, 0x3FF                     ; 窗口第一页在页表里的下标(288)
    lea edi, [edi + eax * 4]
    mov ecx, [edx + TCB_SP_WINDOWPAGES] ; 镜像窗口 + 堆区 + 参数页 + guard + 栈增长区
    xor eax, eax
    rep stosd

    ; ---- 4) 记账:固定只占页目录 + 页表两页 ----
    mov edx, [space_cur]
    mov dword [edx + TCB_SP_PAGES], 2
    popad
    mov edx, [space_cur]
    mov eax, [edx + TCB_SP_PD]
    clc
    ret
.fail:
    call space_destroy                 ; 半路失败也要把已经拿到的页还回去
    popad
    xor eax, eax
    stc
    ret

; ---------------------------------------------------------------------------
;  space_set_image:告诉分页层"这次要跑的镜像有多少字节"
;  页错误处理拿它判断:偏移 < 文件长度 → 从暂存区拷;否则留零(`.bss`)。
;  习惯上的顺序是 space_create 先、这个后(create 不碰这个输入);
;  反过来写也能用,但别在中间插一个会清 TCB_SP_IMGBYTES 的调用。
; ---------------------------------------------------------------------------
space_set_image:
    mov edx, [space_cur]
    mov [edx + TCB_SP_IMGBYTES], eax
    mov dword [edx + TCB_SP_PFRUN], 0
    mov dword [edx + TCB_SP_PFIMG], 0
    mov dword [edx + TCB_SP_PFHEAP], 0
    mov dword [edx + TCB_SP_FIRSTPA], 0
    ret

; ---------------------------------------------------------------------------
;  space_activate / space_deactivate:切到程序页目录 / 切回内核页目录
;
;  切换和 TCB_SP_LIVE 开关必须成对:开着的时候 14 号页错误才会走按需分页,
;  关着(或没有程序在跑)时页错误 = 真错误,照旧 panic。
;  状态存在当前线程的 TCB 里 —— 每条 shell 线程可以各开各的。
; ---------------------------------------------------------------------------
space_activate:
    push eax
    push edx
    mov edx, [space_cur]
    mov dword [edx + TCB_SP_LIVE], 1   ; 先开开关,再换 CR3
    mov eax, [edx + TCB_SP_PD]
    mov cr3, eax
    pop edx
    pop eax
    ret

space_deactivate:
    push eax
    push edx
    mov edx, [space_cur]
    mov dword [edx + TCB_SP_LIVE], 0   ; 先关开关,再换回内核页目录
    mov eax, PD_ADDR
    mov cr3, eax
    pop edx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  page_fault_try_handle:14 号页错误的"按需分页"部分(被 idt.asm 的 isr_common 调)
;  返回 eax = 1 = 页已经补好了,iret 回去重试那条指令;0 = 不是能补的页错误
;         (真越界 / 没有程序在跑 / 页池空了)→ 交给 panic 打印
;
;  进来时:CR2 = 出错地址,CR3 = 程序的页目录,中断关着(用户寄存器在 isr_common 压好了)
;  这里只碰内核低地址(恒等映射,程序页目录里也有)+ 页池(4 MiB 以上,恒等)——
;  所以处理过程本身不会再缺页。
; ---------------------------------------------------------------------------
page_fault_try_handle:
    pushad
    mov dword [pf_ret], 0
    ; 这次缺页是谁的?space_cur 在每次调度切换时更新,所以在 ring3 被打断
    ; 的线程就是它的空间 —— 别用"当前 CR3"去猜,四条线程各有一套。
    mov eax, [space_cur]
    mov [pf_space], eax
    cmp dword [eax + TCB_SP_LIVE], 0
    je .out                            ; 没有程序在跑:不关我事
    cmp dword [eax + TCB_SP_PT], 0
    je .out                            ; 页表都没有,别硬撑

    mov eax, cr2
    mov [pf_va], eax

    ; ---- COW:写一个"存在但只读且带 PAGE_COW"的页 → 复制一份再用 ----
    ;  错误码 bit0=1(present)且 bit1=1(write)才可能是 COW;
    ;  idt.asm 在 call 之前把错误码放进了 ecx。
    mov eax, ecx
    mov [pf_err], eax
    and eax, 3
    cmp eax, 3
    jne .classify
    mov eax, [pf_va]
    shr eax, 12
    and eax, 0x3FF
    mov edi, [pf_space]
    mov edi, [edi + TCB_SP_PT]
    mov eax, [edi + eax * 4]
    test eax, PAGE_P
    jz .classify
    test eax, PAGE_COW
    jnz .cow
.classify:
    mov eax, [pf_va]                    ; COW 判定用掉了 eax,这里恢复成出错地址

    ; ---- Phase C:大匿名堆 [USER_HEAP_VA, TCB_UBRK) ----
    ;     用户申请的大块匿名内存:必要时现挂一张 4 MiB 页表,再走补页/换入。
    cmp eax, USER_HEAP_VA
    jb .windows
    mov edi, [pf_space]
    cmp eax, [edi + TCB_UBRK]
    jb .bigheap

.windows:
    ; ---- 这个地址落在哪个窗口?(窗口外 = 真错误)----
    mov ebx, eax
    sub ebx, SPACE_IMG_VA
    cmp ebx, SPACE_IMG_PAGES * 4096
    jb .image
    mov ebx, eax
    sub ebx, SPACE_HEAP_VA
    mov edi, [pf_space]
    mov ecx, [edi + TCB_SP_HEAPPAGES]
    shl ecx, 12
    cmp ebx, ecx
    jb .heap
    ; ---- 用户栈增长区:[TCB_SP_STACKVA, TCB_SP_STACKTOP) ----
    ;   越往下用栈,缺页就现补一页;补到 guard 页就杀程序。
    mov ebx, eax
    mov edi, [pf_space]
    mov ecx, [edi + TCB_SP_STACKVA]
    cmp ebx, ecx
    jb .out
    mov edx, [edi + TCB_SP_STACKTOP]
    cmp ebx, edx
    jae .out
    mov byte [pf_is_img], 0             ; 栈页 = 零页(和堆页同一条补页路径)
    jmp .check_pte
.image:
    mov byte [pf_is_img], 1
    jmp .check_pte
.heap:
    mov byte [pf_is_img], 0
    jmp .check_pte

; ---- 大匿名堆缺页:页表不在就现挂一张,然后补页/从 swap 读回 ----
.bigheap:
    ; PDE 下标 = va >> 22
    mov eax, [pf_va]
    shr eax, 22
    mov [bh_pdeidx], eax
    mov edx, [pf_space]
    mov edx, [edx + TCB_SP_PD]
    lea edx, [edx + eax * 4]
    mov [bh_pdeaddr], edx
    mov eax, [edx]
    test eax, PAGE_P
    jnz .bh_have_pt
    ; 没有页表:要一页(页池紧先换出冷页),清零后挂成用户页表
    call swap_alloc_frame
    test eax, eax
    jz .oom
    mov [bh_pt], eax
    mov edi, eax
    xor eax, eax
    mov ecx, 1024
    rep stosd
    mov eax, [bh_pt]
    or  eax, PAGE_P | PAGE_RW | PAGE_USER
    mov edx, [bh_pdeaddr]
    mov [edx], eax
.bh_have_pt:
    mov edx, [bh_pdeaddr]
    mov eax, [edx]
    and eax, 0xFFFFF000
    mov [bh_pt], eax
    ; 页表项地址
    mov eax, [pf_va]
    shr eax, 12
    and eax, 0x3FF
    mov edi, [bh_pt]
    lea edi, [edi + eax * 4]
    mov [pf_pteaddr], edi
    mov eax, [edi]
    test eax, PAGE_P
    jnz .out                           ; 页在(比如只读)→ 交给 panic
    mov edx, eax
    and edx, 0xFFFFF000
    jz .bh_fresh
    ; ---- 是 swap 页:读回来 ----
    mov eax, [pf_pteaddr]
    mov ebx, [pf_va]
    call swap_swapin
    test eax, eax
    jz .oom
    mov dword [pf_ret], 1
    popad
    mov eax, [pf_ret]
    ret
.bh_fresh:
    ; ---- 拿一帧,清零,装 PTE ----
    call swap_alloc_frame
    test eax, eax
    jz .oom
    mov [pf_new_pa], eax
    mov edi, eax
    xor eax, eax
    mov ecx, 1024
    rep stosd
    mov edi, [pf_pteaddr]
    mov eax, [pf_new_pa]
    or  eax, PAGE_P | PAGE_RW | PAGE_USER
    mov [edi], eax
    mov eax, [pf_va]
    invlpg [eax]
    ; 记账
    mov edi, [pf_space]
    inc dword [edi + TCB_SP_PFRUN]
    inc dword [space_pf_total]
    cmp dword [edi + TCB_SP_FIRSTPA], 0
    jne .bh_anon
    mov eax, [pf_new_pa]
    mov [edi + TCB_SP_FIRSTPA], eax
.bh_anon:
    ; 匿名页,引用计数 1 → 登记可换出
    mov eax, [pf_new_pa]
    mov ebx, [pf_pteaddr]
    call swap_mark_anon
    mov dword [pf_ret], 1
    popad
    mov eax, [pf_ret]
    ret

.cow:
    ; ---- 1) 记下旧页,拿一页新的,整页复制 ----
    and eax, 0xFFFFF000
    mov [pf_old_pa], eax
    call swap_alloc_frame               ; 页池紧就先换出冷页(Phase C)
    test eax, eax
    jz .cow_oom
    mov [pf_new_pa], eax
    mov esi, [pf_old_pa]
    mov edi, eax
    mov ecx, 1024
    rep movsd
    ; ---- 2) 本进程的 PTE 换成新页:可写、去掉 COW ----
    mov eax, [pf_va]
    shr eax, 12
    and eax, 0x3FF
    mov edi, [pf_space]
    mov edi, [edi + TCB_SP_PT]
    mov edx, [pf_new_pa]
    or  edx, PAGE_P | PAGE_RW | PAGE_USER
    mov [edi + eax * 4], edx
    lea edx, [edi + eax * 4]
    mov [pf_pteaddr], edx
    mov eax, [pf_va]
    invlpg [eax]
    ; ---- Phase C:复制出来的新页是匿名页(引用计数 1),登记可换出 ----
    mov eax, [pf_new_pa]
    mov ebx, [pf_pteaddr]
    call swap_mark_anon
    ; ---- 3) 旧页少一个引用者(归零才真的还给页池)----
    mov eax, [pf_old_pa]
    call pmem_free
    ; ---- 4) 记账:这页算 COW 复制,不算"按需补页" ----
    mov edi, [pf_space]
    inc dword [edi + TCB_PFCOW]
    mov dword [pf_ret], 1
    popad
    mov eax, [pf_ret]
    ret
.cow_oom:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_cow_oom
    call term_print
    popad
    mov eax, 0
    ret

.check_pte:
    ; 这一项要是已经"存在",说明不是缺页(比如写只读页)→ 别乱补,交给 panic
    mov eax, [pf_va]
    shr eax, 12
    and eax, 0x3FF
    mov edi, [pf_space]
    mov edi, [edi + TCB_SP_PT]
    lea edi, [edi + eax * 4]
    mov [pf_pteaddr], edi
    mov eax, [edi]
    test eax, 1
    jnz .out
    ; ---- Phase C:present=0 但带 swap 标记 → 从 swap 区读回来 ----
    mov edx, eax
    and edx, 0xFFFFF000
    jz .need_page
    mov eax, [pf_pteaddr]
    mov ebx, [pf_va]
    call swap_swapin
    test eax, eax
    jz .oom
    mov dword [pf_ret], 1
    popad
    mov eax, [pf_ret]
    ret
.need_page:
    ; ---- 从页池拿一页(页池紧的话先换出冷页;轮转让每次物理页不同)----
    call swap_alloc_frame
    test eax, eax
    jz .oom
    mov [pf_new_pa], eax

    ; ---- 先把这页清零:堆页和 `.bss` 要的零页就是它 ----
    mov edi, eax
    xor eax, eax
    mov ecx, 1024
    rep stosd

    cmp byte [pf_is_img], 0
    je .install
    ; ---- 镜像页:文件里有的部分从**这套空间自己的暂存区**拷过来 ----
    ; ★ 这里必须**按页对齐**算偏移:缺页的地址不一定在页开头
    ;   (ring 3 用 call 跳进函数,取指就直接落在页中间 0x121C10)。
    ;   以前程序从 0x120000 顺序往下跑,缺页总是发生在页边界上,
    ;   拿"出错地址"当拷贝起点也看不出问题 —— 一旦从页中间进代码,
    ;   整页就会错位,程序跑的就是别人家的字节(踩过:CHELLO.BIN 崩在 0x0)。
    mov eax, [pf_va]
    sub eax, SPACE_IMG_VA
    and eax, 0xFFFFF000
    mov [pf_off], eax
    mov edi, [pf_space]
    cmp eax, [edi + TCB_SP_IMGBYTES]
    jae .install                       ; 文件之外 → 就是 `.bss`,留零
    mov edx, [edi + TCB_SP_IMGBYTES]
    sub edx, eax                       ; 这页还剩多少字节要拷
    cmp edx, 4096
    jbe .have_len
    mov edx, 4096                      ; 整页
.have_len:
    mov [pf_len], edx
    ; ★ 以前暂存区就是 0x120000(和程序镜像窗口同一个虚拟地址),必须临时切回
    ;   内核页目录才能读到;现在每条线程的镜像先拷进页池里自己的暂存区
    ;   (物理地址恒等映射,程序页目录里也映着),直接读就行 —— 不用碰 CR3,
    ;   也不会因为"别的 shell 又 run 了一个程序"把这一页的源数据踩掉。
    mov edi, [pf_space]
    mov esi, [edi + TCB_SP_STAGE_PA]
    test esi, esi
    jz .install                        ; 没暂存区(理论上不该有)→ 当 `.bss` 留零
    add esi, [pf_off]
    mov edi, [pf_new_pa]
    mov ecx, [pf_len]
    add ecx, 3
    shr ecx, 2                         ; 字节 → dword(向上取整)
    rep movsd

.install:
    ; ---- 把新页填进程序私有页表的对应项,并让 CPU 忘掉旧翻译 ----
    mov eax, [pf_va]
    shr eax, 12
    and eax, 0x3FF
    mov edi, [pf_space]
    mov edi, [edi + TCB_SP_PT]
    mov edx, [pf_new_pa]
    or  edx, PAGE_P | PAGE_RW | PAGE_USER ; U/S=1:程序自己要用这些页(ring 3)
    mov [edi + eax * 4], edx
    mov eax, [pf_va]
    invlpg [eax]

    ; ---- Phase C:这页是匿名用户页(引用计数 1),登记可换出 ----
    mov eax, [pf_new_pa]
    mov ebx, [pf_pteaddr]
    call swap_mark_anon

    ; ---- 记账(给 run 的输出和测试用)----
    mov edi, [pf_space]
    inc dword [edi + TCB_SP_PFRUN]
    inc dword [space_pf_total]
    cmp byte [pf_is_img], 0
    je .count_heap
    inc dword [edi + TCB_SP_PFIMG]
    jmp .first_page
.count_heap:
    inc dword [edi + TCB_SP_PFHEAP]
.first_page:
    cmp dword [edi + TCB_SP_FIRSTPA], 0
    jne .ok
    mov eax, [pf_new_pa]
    mov [edi + TCB_SP_FIRSTPA], eax    ; 第一次补进来的是哪页(常是镜像第 0 页)
.ok:
    mov dword [pf_ret], 1
    popad
    mov eax, [pf_ret]
    ret

.oom:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_pf_oom
    call term_print
    ; 掉到 .out 返回 0 → panic 屏还会打出错地址,方便对账
.out:
    popad
    mov eax, [pf_ret]
    ret

; ---------------------------------------------------------------------------
;  space_destroy:拆掉**当前线程**的程序地址空间(空间没建也能调:指针 0 的
;  步骤直接跳过)。返回 eax = 还回去的页数
;
;  space_destroy_at:拆 `edi` 指向的那块地址空间状态(用来杀别的 shell 的程序)。
;  两条入口共用下面这段:扫私有页表里"存在的"项(那才是按需分页真给出去的
;  页),再加上页目录 + 页表 + 镜像暂存区,一起还给页池。
; ---------------------------------------------------------------------------
space_destroy:
    mov eax, [space_cur]
    mov [sd_block], eax
    jmp sd_go
space_destroy_at:
    mov [sd_block], edi
sd_go:                                  ; 两条入口共用(非局部标签,别改成 .go)
    pushad
    mov dword [sd_pages], 0
    mov ebx, [sd_block]
    mov dword [ebx + TCB_SP_LIVE], 0   ; 先把开关关掉,免得半路又触发按需分页

    ; ---- Phase C:大匿名堆(0x80000000 起)的帧/页表/swap 槽一起收 ----
    mov edi, ebx
    call swap_space_free
    add [sd_pages], eax

    ; ---- 窗口里已经补进来的私有页 ----
    mov edi, [ebx + TCB_SP_PT]
    test edi, edi
    jz .no_scan
    mov ebx, SPACE_IMG_VA
    mov ecx, SPACE_IMG_PAGES
    call space_free_window
    mov ebx, SPACE_HEAP_VA
    mov eax, [sd_block]
    mov ecx, [eax + TCB_SP_WINDOWPAGES]
    sub ecx, SPACE_IMG_PAGES            ; 堆区 + 参数页 + guard + 栈增长区
    call space_free_window
.no_scan:

    mov eax, [sd_block]
    mov eax, [eax + TCB_SP_PT]
    test eax, eax
    jz .no_pt
    call pmem_free
    jc .no_pt
    inc dword [sd_pages]
.no_pt:
    mov eax, [sd_block]
    mov eax, [eax + TCB_SP_PD]
    test eax, eax
    jz .no_pd
    call pmem_free
    jc .no_pd
    inc dword [sd_pages]
.no_pd:
    ; ---- 镜像暂存区:连续几页,一起还 ----
    mov eax, [sd_block]
    mov eax, [eax + TCB_SP_STAGE_PA]
    test eax, eax
    jz .no_stage
    mov ebx, [sd_block]
    mov ecx, [ebx + TCB_SP_STAGE_PAGES]
    call pmem_free_pages
    add dword [sd_pages], eax
.no_stage:
    mov eax, [sd_block]
    mov dword [eax + TCB_SP_PD], 0
    mov dword [eax + TCB_SP_PT], 0
    mov dword [eax + TCB_SP_IMGBYTES], 0
    mov dword [eax + TCB_SP_PAGES], 0
    mov dword [eax + TCB_SP_STAGE_PA], 0
    mov dword [eax + TCB_SP_STAGE_PAGES], 0
    mov dword [eax + TCB_SP_RUNNING], 0
    popad
    mov eax, [sd_pages]
    ret

; ---------------------------------------------------------------------------
;  内部小工具
; ---------------------------------------------------------------------------
; 把 [sd_block].TCB_SP_PT 里从虚拟地址 ebx 起的 ecx 项中"存在的"页还给页池,并计数
; (存在的项 = 程序真的碰过、我们真给过的页;没碰过的项是 0,跳过)
space_free_window:
    push eax
    push ebx
    push ecx
    push edx
    push esi
.loop:
    mov eax, ebx
    shr eax, 12
    and eax, 0x3FF                     ; 页表项下标
    mov esi, [sd_block]
    mov esi, [esi + TCB_SP_PT]
    lea esi, [esi + eax * 4]           ; 这一项的地址
    mov edx, [esi]
    test edx, 1
    jz .swapped                        ; present=0:可能是 swap 页
    ; ---- 正常页:还帧,清 PTE(清掉免得残留元数据指向已归还的帧)----
    mov dword [esi], 0
    and edx, 0xFFFFF000
    mov eax, edx
    call pmem_free
    jc .next
    inc dword [sd_pages]
    jmp .next
.swapped:
    ; ---- Phase C:swap 页 → 还 swap 槽(不占物理页)----
    test edx, PAGE_SWAP
    jz .next
    mov eax, edx
    shr eax, 12
    cmp dword [swap_enabled], 0
    je .next
    call swap_slot_free
    cmp eax, SWAP_SLOTS
    jae .next
    cmp dword [swap_slots_used], 0
    je .next
    dec dword [swap_slots_used]
.next:
    add ebx, 4096
    dec ecx
    jnz .loop
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  space_user_page:给程序空间里某个虚拟地址**先**映射一页(带 U/S=1)
;    eax = 虚拟地址 → eax = 这页的物理地址(0 = 页池空了)
;  ring 3 有两块页不能等缺页:弹床页(程序 ret 回去执行 int 0x30 的地方)和用户
;  栈页(程序在 ring 3 用的栈)。写内容直接用返回的物理地址 —— 页池在 0x400000
;  以上是恒等映射的,内核视角里物理地址就是虚拟地址。
; ---------------------------------------------------------------------------
space_user_page:
    mov ebx, PAGE_P | PAGE_RW | PAGE_USER
    ; 落到下面带权限位的那条

; space_user_page_flags:ebx = 页表项权限位(必须含 PAGE_P)
;   比如队栈 guard 页要
;   PAGE_P|PAGE_USER(只读) —— 写它就 #PF,程序被干掉。
space_user_page_flags:
    mov [sup_flags], ebx
    push ebx
    push ecx
    push edx
    push edi
    mov [sup_va], eax
    mov ecx, 1
    call pmem_alloc_pages
    test eax, eax
    jz .out
    mov [sup_pa], eax
    mov edi, eax                        ; 新页清零(栈页里除了返回地址都该是 0)
    xor eax, eax
    mov ecx, 1024
    rep stosd
    ; 装进私有页表 —— 这里**必须**带 PAGE_USER:没有这一位,ring 3 一碰就是
    ; "页在,但你没资格"(错误码 bit0=1)的保护违规,而不是缺页。
    mov ebx, [sup_va]
    shr ebx, 12
    and ebx, 0x3FF                      ; 页表项下标
    mov edx, [space_cur]
    mov edi, [edx + TCB_SP_PT]
    mov eax, [sup_pa]
    or eax, [sup_flags]
    mov [edi + ebx * 4], eax
    inc dword [edx + TCB_SP_PAGES]      ; 这两页不是"按需补的",跟着空间一起收摊
    mov eax, [sup_va]
    invlpg [eax]
    mov eax, [sup_pa]
.out:
    pop edi
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  space_prepare_user:准备 ring 3 的两块页
;    · 弹床页(镜像窗口最后一页 0x17F000)写三条指令:mov eax,15 / int 0x30 / jmp $
;    · 用户栈页(堆窗口最后一页,地址运行时定 space_stack_va)的栈顶放一个返回地址 = 弹床
;  返回 eax = 弹床虚拟地址;0 = 页池不够(调用方按 OOM 处理)
;  为什么要弹床:现有程序的结尾都是 `ret`(汇编写的,C 那套也是),而 ret 的目标
;  地址是我们压进用户栈的。压内核地址没用 —— ring 3 一跳过去就是 #PF。所以压
;  一段"用户态里的小代码",它替程序喊一声"我退出"(int 0x30 功能号 15)。
;  好处:HELLO/TOUCH/EDIT/CALC/UTF8/HANG 一个字节都不用改。
; ---------------------------------------------------------------------------
space_prepare_user:
    pushad
    mov eax, SPACE_TRAMP_VA
    call space_user_page
    test eax, eax
    jz .fail
    mov edi, eax                        ; 往弹床页写那三条指令
    mov esi, tramp_code
    mov ecx, tramp_code_end - tramp_code
    rep movsb
    ; ---- 用户栈:先只映射顶部一页(往下增长交给 #PF 补页)----
    mov edx, [space_cur]
    mov eax, [edx + TCB_SP_STACKTOP]
    and eax, 0xFFFFF000                 ; 栈顶所在的那一页
    call space_user_page
    test eax, eax
    jz .fail
    mov edi, eax
    add edi, 4096 - 4                   ; 栈顶往下 4 字节:弹床的地址
    mov dword [edi], SPACE_TRAMP_VA
    ; ---- 栈增长区底下垫一页 guard(只读)----
    ;   往下越过栈区界一页 → #PF(页在但只读)→ prog_kill_from_fault
    ;   不会一路踩穿堆、踩进内核。
    mov edx, [space_cur]
    mov eax, [edx + TCB_SP_STACKVA]
    sub eax, 0x1000                     ; 栈增长区下面那一页 = guard
    mov ebx, PAGE_P | PAGE_USER         ; 故意不带 PAGE_RW:只读!
    call space_user_page_flags
    test eax, eax
    jz .fail
    popad
    mov eax, SPACE_TRAMP_VA
    ret
.fail:
    popad
    xor eax, eax
    ret

; ---------------------------------------------------------------------------
;  prog_kill_from_fault:ring 3 的程序犯错了(页错误/特权指令)→ 干掉它,系统活着
;    ebx = isr_common 的帧指针([+32] 向量 [+36] 错误码 [+40] EIP [+44] CS)
;  不返回:把内核现场恢复成"程序还没跑"的样子(和 api.asm 的 exit 门同一条路),
;  直接跳回 cmd_run。这正是 ring 3 的意义:玩具程序乱写地址,内核不受影响。
; ---------------------------------------------------------------------------
prog_kill_from_fault:
    pushad
    mov [pk_frame], ebx
    mov eax, EV_PROG_CRASH              ; 事件账本:程序崩了(附带出错处的 EIP)
    mov ebx, [ebx + 40]
    call evt_log
    call rc_on_crash                    ; on_crash="reboot" 的话,这里就去重启
    mov al, 10
    call term_putc
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_pk_head
    call term_print
    mov eax, [pk_frame]
    cmp dword [eax + 32], 14
    jne .other
    ; ---- 14 号页错误:报 CR2(碰了哪儿)和 EIP(哪条指令碰的)----
    mov esi, msg_pk_pf
    call term_print
    mov eax, cr2
    call term_print_hex
    mov esi, msg_pk_eip
    call term_print
    mov eax, [pk_frame]
    mov eax, [eax + 40]
    call term_print_hex
    mov eax, [pk_frame]
    ; 错误码:bit0=页存在(1)/不存在(0),bit1=写操作,bit2=ring 3 访问。
    ;  bit0=1 = "页在,但没你的份"(碰内核内存就是这种);bit0=0 = 压根没映射。
    test dword [eax + 36], 1
    jz .notmapped
    mov esi, msg_pk_notyours
    call term_print
    jmp .done
.notmapped:
    mov esi, msg_pk_umapped
    call term_print
    jmp .done
.other:
    ; ---- 别的异常(#GP/#UD…):多半是碰了只有内核能用的指令 ----
    mov esi, msg_pk_exc
    call term_print
    mov eax, [pk_frame]
    mov eax, [eax + 32]
    call term_print_dec
    mov esi, msg_pk_eip
    call term_print
    mov eax, [pk_frame]
    mov eax, [eax + 40]
    call term_print_hex
    mov esi, msg_pk_priv
    call term_print
.done:
    mov al, 10
    call term_putc
    mov al, COL_NORMAL
    call term_set_color

    ; ---- 回 shell 的内核现场 ----
    mov edx, [space_cur]
    mov dword [edx + TCB_SP_RUNSTAT], 1 ; 1 = 不是正常退出,是"被干掉的"
    mov esp, [edx + TCB_SP_RUNESP]
    mov ax, GDT_KDATA
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov eax, PD_ADDR
    mov cr3, eax                        ; 换回内核页目录
    jmp run_resume_kernel

lfb_pde_idx  dd 0
lfb_base     dd 0
map_va       dd 0
map_pa       dd 0
map_flags    dd 0

; ---- 每线程状态(TCB 里的 TCB_SP_*)由 space_cur 指向:切换线程时 sched_pick 更新它 ----
space_cur      dd 0                    ; 当前线程的地址空间块(= &tcb_table[cur])
space_pf_total dd 0                    ; 开机到现在一共补了几页(pmem 命令会显示)
sd_block       dd 0                    ; space_destroy(_at) 正在拆的那块空间
sd_pages       dd 0                    ; space_destroy 数的页数

pf_space       dd 0                    ; page_fault_try_handle:这次缺页属于哪块空间
pf_va          dd 0                    ; 出错地址(从 CR2 抄下来)
pf_new_pa      dd 0                    ; 这一页现拿的物理地址
pf_off         dd 0                    ; 镜像页在文件里的偏移(第几页 × 4096)
pf_len         dd 0                    ; 要从暂存区拷多少字节
pf_ret         dd 0                    ; page_fault_try_handle 的返回值
pf_is_img      db 0                    ; 出错的是镜像窗口(1)还是堆窗口(0)
msg_pf_oom     db 'out of physical pages while faulting in a page', 10, 0
msg_cow_oom     db 'cow: out of memory (page still shared)', 13, 10, 0
pf_err          dd 0
pf_old_pa       dd 0
pf_pteaddr      dd 0                    ; C:缺页要补/换入的那条页表项地址
bh_pdeidx       dd 0                    ; C:大匿名堆缺页的 PDE 下标
bh_pdeaddr      dd 0                    ; C:大匿名堆缺页的 PDE 地址
bh_pt           dd 0                    ; C:大匿名堆的页表物理地址

sup_va         dd 0                    ; space_user_page:要映的虚拟地址
sup_pa         dd 0                    ; space_user_page:拿到的物理页
sup_flags      dd 0                    ; space_user_page_flags 的权限位
pk_frame       dd 0                    ; prog_kill_from_fault:异常现场的帧指针
; 弹床页里的三条指令:mov eax,15(退出) / int 0x30 / jmp $。程序 `ret` 到这里。
tramp_code:
    db 0xB8, 15, 0x00, 0x00, 0x00
    db 0xCD, 0x30
    db 0xEB, 0xFE
tramp_code_end:
msg_pk_head    db 'program crashed: ', 0
msg_pk_pf      db 'page fault at ', 0
msg_pk_exc     db 'exception ', 0
msg_pk_eip     db ' (EIP ', 0
msg_pk_notyours db ') -- that page belongs to the kernel, not to you', 10, 0
msg_pk_umapped  db ') -- that address is not mapped in your memory', 10, 0
msg_pk_priv    db ') -- that is a privileged instruction, only the kernel may run it', 10, 0
