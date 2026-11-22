; ============================================================================
;  KKernel — Phase C:swap(页换出 / 换入)+ 用户大匿名堆
;
;  为什么要有 swap:物理页池就那么大,程序却能申请比它多得多的匿名内存
;  (SWAPTEST 在 -m 16 下要 18 MiB,物理页池才 12 MiB)。办法是把一部分
;  "程序自己在用、但最近没人碰"的物理页写到磁盘上的 swap 区,把帧腾出来;
;  程序再碰那一页时,缺页处理把它读回来。程序完全不知道发生过什么。
;
;  一句话流程:
;    页不够 → swap_evict_one 挑一个 ANON 帧 → 内容拷到 bounce 缓冲 →
;    写 swap 区 → 页表项改成「present=0 + bit9 + 槽号」→ 物理帧还给页池。
;    再访问 → 缺页里看到这种 PTE → swap_swapin:拿一帧 → 读盘 → 装回 PTE
;    → 释放槽位 → iret 重执行那条指令。
;
;  swap 区在磁盘上是固定的一段(不经过 FAT,只走 ATA PIO):
;    布局由 tools/mkswap.py 生成:HD 镜像(16 MiB)之后追加 16 MiB,
;    起始 LBA = 32768(16 MiB / 512),头 16 字节:
;      +0  "KSWP" 魔数   +4  version=1   +8  total_slots=4096   +12 slot_size=4096
;    没有合法头(普通 hd 测试镜像)→ swap 静默禁用,一切照旧 —— 这样以前的
;    测试(尤其 hd 的页池页数断言)不受影响。
;
;  PTE 编码:
;    正常页:  物理帧地址(4 KiB 对齐) | PAGE_P | PAGE_RW | PAGE_USER
;    COW 页:  ... | PAGE_COW(bit9)
;    swap 页: 槽号 << 12 | PAGE_SWAP(bit9,重用 COW 的位),且 present=0
;             (present=0 和 COW 页靠 present 位区分,不会混)
;
;  哪些页能换出:只在缺页补页时(tag ANON)标记的用户页,且 pmem 引用计数==1。
;    内核栈/页目录/页表/ATA 缓冲/双缓冲/COW 共享页(引用>1)都不标 ANON,
;    永远不会被换出。
;
;  锁/关中断:整个换出/换入过程 pushfd+cli 关中断做完(单核,不需要锁;
;    ATA PIO 是纯端口轮询,不依赖中断)。代价是换页那一下会丢几个 tick ——
;    玩具系统,先保证正确。
; ============================================================================

; ---- swap 区布局(必须和 tools/mkswap.py 一致)----
SWAP_LBA        equ 32768              ; 16 MiB / 512
SWAP_SLOTS      equ 4096               ; 16 MiB / 4 KiB
SWAP_SLOT_SIZE  equ 4096
SWAP_MAGIC      equ 0x5057534B         ; "KSWP"(小端: 'K','S','W','P')
SWAP_VERSION    equ 1
PAGE_SWAP       equ 0x200              ; PTE bit9:present=0 + bit9 = 在 swap 里
; USER_HEAP_VA / USER_HEAP_MAX 定义在 kmain.asm(所有模块共用的一份)

; ---------------------------------------------------------------------------
;  swap_init:开机时调(kmain 在 paging_init 之后)。读 swap 头,合法就
;  从页池拿几页做"帧元数据表",然后打开开关。不合法 → 静默禁用。
; ---------------------------------------------------------------------------
swap_init:
    pushad
    mov dword [swap_enabled], 0
    ; ---- 1) 读 swap 头(一个扇区)----
    mov eax, SWAP_LBA
    mov ecx, 1
    mov edi, swap_hdr
    call ata_read_sectors
    test eax, eax
    jnz .out                           ; 读不到(盘太小/没有盘)→ 静默
    cmp dword [swap_hdr], SWAP_MAGIC
    jne .out
    cmp dword [swap_hdr + 4], SWAP_VERSION
    jne .out
    cmp dword [swap_hdr + 8], SWAP_SLOTS
    jne .out
    cmp dword [swap_hdr + 12], SWAP_SLOT_SIZE
    jne .out

    ; ---- 2) 帧元数据表:每帧 8 字节(flags + PTE 地址)----
    mov eax, [pmem_total]
    shl eax, 3                         ; × 8
    add eax, 4095
    shr eax, 12                        ; 向上取整到页
    test eax, eax
    jz .out
    mov [swap_meta_pages], eax
    mov ecx, eax
    call pmem_alloc_pages
    test eax, eax
    jz .out
    mov [swap_meta_base], eax
    ; 清零(flags 全 0 = 没有可换出的页)
    mov edi, eax
    xor eax, eax
    mov ecx, [swap_meta_pages]
    shl ecx, 10                        ; 页数 × 1024 dword
    rep stosd

    ; ---- 3) 槽位位图清零,统计清零 ----
    mov edi, swap_slot_bitmap
    xor eax, eax
    mov ecx, SWAP_SLOTS / 8 / 4        ; 512 字节 = 128 dword
    rep stosd
    mov dword [swap_slots_total], SWAP_SLOTS
    mov dword [swap_slots_used], 0
    mov dword [swap_out_count], 0
    mov dword [swap_in_count], 0
    mov dword [swap_cursor], 0
    mov dword [swap_enabled], 1

    ; ---- 4) 开机报一行(普通 hd 镜像没有 swap 头,不会走到这里)----
    mov al, COL_OK
    call term_set_color
    mov esi, msg_swap_boot
    call term_print
    mov eax, [swap_slots_total]
    call term_print_dec
    mov esi, msg_swap_boot2
    call term_print
    mov eax, [swap_meta_pages]
    call term_print_dec
    mov esi, msg_swap_boot3
    call term_print
    mov al, COL_NORMAL
    call term_set_color
.out:
    popad
    ret

; ---------------------------------------------------------------------------
;  swap_meta_ptr:入 eax = 帧物理地址 → eax = 元数据指针(0 = 没启用/不在池里)
; ---------------------------------------------------------------------------
swap_meta_ptr:
    push ebx
    push edx
    test eax, 0xFFFFF000
    jz .bad
    test eax, 0xFFF
    jnz .bad
    mov ebx, [swap_meta_base]
    test ebx, ebx
    jz .bad
    cmp eax, [pmem_start]
    jb .bad
    cmp eax, [pmem_end]
    jae .bad
    sub eax, [pmem_start]
    shr eax, 12
    cmp eax, [pmem_total]
    jae .bad
    shl eax, 3
    add eax, ebx
    pop edx
    pop ebx
    ret
.bad:
    xor eax, eax
    pop edx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  swap_mark_anon:把这个帧标成"匿名用户页、可换出"
;    入:eax = 帧物理地址,ebx = 指向它的页表项地址
;    只在 pmem 引用计数 == 1 时标(共享/COW 页不换出);保留所有寄存器。
; ---------------------------------------------------------------------------
swap_mark_anon:
    pushad
    cmp dword [swap_enabled], 0
    je .out
    mov [sma_pa], eax
    call swap_meta_ptr
    test eax, eax
    jz .out
    mov [sma_meta], eax
    mov eax, [sma_pa]
    call pmem_ref_get
    jc .out
    cmp eax, 1
    jne .out                           ; 有别人共享(COW):不换出
    mov edi, [sma_meta]
    mov byte [edi], 3                  ; bit0 ANON + bit1 CLOCK 参考位
    mov [edi + 4], ebx
.out:
    popad
    ret

; ---------------------------------------------------------------------------
;  swap_frame_dispose:帧被释放/被标 COW 时清掉元数据(防止换出到错页)
;    入:eax = 帧物理地址(不是池里的就忽略);保留所有寄存器。
; ---------------------------------------------------------------------------
swap_frame_dispose:
    pushad
    cmp dword [swap_enabled], 0
    je .out
    call swap_meta_ptr
    test eax, eax
    jz .out
    mov dword [eax], 0
.out:
    popad
    ret

; ---------------------------------------------------------------------------
;  swap_slot_alloc → eax = 槽号(0..4095)/ -1(满了)
; ---------------------------------------------------------------------------
swap_slot_alloc:
    push ebx
    push ecx
    push edx
    xor edx, edx                       ; dword 下标
.scan:
    mov ebx, [swap_slot_bitmap + edx * 4]
    cmp ebx, -1
    jne .found
    inc edx
    cmp edx, SWAP_SLOTS / 32
    jb .scan
    mov eax, -1
    jmp .out
.found:
    not ebx
    bsf eax, ebx                       ; 字节里第一个空闲位
    mov ebx, edx
    shl ebx, 5                         ; dword 下标 × 32
    add eax, ebx                       ; 槽号
    ; 置位
    mov ebx, eax
    mov ecx, eax
    and ecx, 31
    shr ebx, 5
    bts dword [swap_slot_bitmap + ebx * 4], ecx
.out:
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  swap_slot_free:入 eax = 槽号;保留所有寄存器
; ---------------------------------------------------------------------------
swap_slot_free:
    push eax
    push ebx
    push ecx
    cmp eax, SWAP_SLOTS
    jae .out
    mov ebx, eax
    mov ecx, eax
    and ecx, 31
    shr ebx, 5
    btr dword [swap_slot_bitmap + ebx * 4], ecx
.out:
    pop ecx
    pop ebx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  swap_evict_one:按 CLOCK 找一个可换出的帧,写盘,把 PTE 改成 swap 编码。
;    出:eax = 1 换出了一页 / 0 没有可换的(swap 关着/都 locked/swap 满)
;    全程关中断(调用方进来时可能已经关着;pushfd/cli 再 popfd)。
; ---------------------------------------------------------------------------
swap_evict_one:
    pushad
    pushfd
    cli
    cmp dword [swap_enabled], 0
    je .none
    mov dword [ev_left], 0
    mov eax, [pmem_total]
    mov [ev_left], eax
    mov esi, [swap_cursor]             ; 从上次的位置接着扫(CLOCK 指针)
    test esi, esi
    jnz .scan
.scan:
    ; ---- 帧号 esi → 物理地址 + 元数据指针 ----
    mov eax, esi
    shl eax, 12
    add eax, [pmem_start]
    mov [ev_pa], eax
    mov edi, [swap_meta_base]
    mov eax, esi
    shl eax, 3
    add edi, eax
    mov [ev_meta], edi
    movzx eax, byte [edi]
    test al, 1                         ; ANON?
    jz .next
    ; ---- 引用计数必须正好是 1(共享页不换出)----
    mov eax, [ev_pa]
    call pmem_ref_get
    jc .clear
    cmp eax, 1
    jne .next
    ; ---- 页表项得真的还指着这个帧 ----
    mov edi, [ev_meta]
    mov edx, [edi + 4]
    test edx, edx
    jz .clear
    mov eax, [edx]
    test eax, 1
    jz .clear                          ; 已经不是 present 了(被别人换了/拆了)
    mov ecx, eax
    and ecx, 0xFFFFF000
    cmp ecx, [ev_pa]
    jne .clear
    ; ---- CLOCK 二次机会:参考位为 1 的只清位跳过,下一圈再选它 ----
    movzx eax, byte [edi]
    test al, 2
    jz .evict
    and byte [edi], 0xFD
    jmp .next
.clear:
    mov edi, [ev_meta]
    and byte [edi], 0xFC
.next:
    inc esi
    cmp esi, [pmem_total]
    jb .cursor_ok
    xor esi, esi
.cursor_ok:
    mov [swap_cursor], esi
    dec dword [ev_left]
    jnz .scan
.none:
    popfd
    popad
    xor eax, eax
    ret

.evict:
    ; ---- 1) 找个 swap 槽 ----
    call swap_slot_alloc
    cmp eax, -1
    je .none                           ; swap 满了:调用方按 ENOMEM 处理
    mov [ev_slot], eax
    ; ---- 2) 帧内容 → bounce 缓冲(先拷好,再改 PTE,最后写盘;
    ;        写盘在 PTE 改完之后做也行,但先写盘失败时更容易回滚)----
    mov esi, [ev_pa]
    mov edi, swap_bounce
    mov ecx, 1024
    rep movsd
    ; ---- 3) 写 swap 区(8 个扇区)----
    mov eax, [ev_slot]
    shl eax, 3
    add eax, SWAP_LBA
    mov ecx, 8
    mov esi, swap_bounce
    call ata_write_sectors_nf           ; swap 无需持久化:不发 FLUSH(否则 QEMU 每次 fsync)
    test eax, eax
    jz .write_ok
    ; 写失败:把槽还了,这一帧跳过(不冒险改 PTE)
    mov eax, [ev_slot]
    call swap_slot_free
    mov edi, [ev_meta]
    and byte [edi], 0xFC
    jmp .next
.write_ok:
    ; ---- 4) PTE 改成 swap 编码,刷 TLB ----
    mov eax, [ev_slot]
    shl eax, 12
    or eax, PAGE_SWAP
    mov edi, [ev_meta]
    mov edx, [edi + 4]
    mov [edx], eax
    mov eax, cr3                       ; 整个 TLB 刷掉(被换出的页可能正在当前进程的 TLB 里)
    mov cr3, eax
    ; ---- 5) 元数据清空,物理帧还给页池 ----
    mov edi, [ev_meta]
    mov dword [edi], 0
    mov eax, [ev_pa]
    call pmem_free
    inc dword [swap_slots_used]
    inc dword [swap_out_count]
    popfd
    popad
    mov eax, 1
    ret

; ---------------------------------------------------------------------------
;  swap_reclaim:入 eax = 想换出几页 → eax = 实际换出几页(停下时可能不够)
; ---------------------------------------------------------------------------
swap_reclaim:
    pushad
    mov [sw_want], eax
    mov dword [sw_got], 0
.loop:
    call swap_evict_one
    test eax, eax
    jz .done
    inc dword [sw_got]
    mov eax, [sw_got]
    cmp eax, [sw_want]
    jb .loop
.done:
    popad
    mov eax, [sw_got]
    ret

; ---------------------------------------------------------------------------
;  swap_alloc_frame:要一帧(页池空先换出几页再重试)→ eax = 帧物理地址/0
;    eax 是返回值;ecx/edx 保留。全程关中断,避免两个线程同时换页。
; ---------------------------------------------------------------------------
swap_alloc_frame:
    push ecx
    push edx
    pushfd
    cli
    mov dword [sfa_tries], 0
.retry:
    mov ecx, 1
    call pmem_alloc_pages
    test eax, eax
    jnz .done
    cmp dword [swap_enabled], 0
    je .done                           ; 没 swap:就是真没页了(返回 0)
    cmp dword [sfa_tries], 4
    jae .done
    inc dword [sfa_tries]
    mov eax, 1
    call swap_reclaim
    jmp .retry                         ; 即使这一圈"只清了 CLOCK 参考位、没换出"
                                       ; 也要再试;上限 sfa_tries=4 兜底
.done:
    popfd
    pop edx
    pop ecx
    ret

; ---------------------------------------------------------------------------
;  swap_swapin:缺页时把 swap 页读回来
;    入:eax = 页表项地址,ebx = 缺页虚拟地址
;    出:eax = 1 成功(PTE 已补好,EIP 重试就会成功)/ 0 失败(当 OOM 处理)
; ---------------------------------------------------------------------------
swap_swapin:
    pushad
    mov [si_pte], eax
    mov [si_va], ebx
    ; ---- 1) 校验 PTE 编码:present=0 + bit9 + 槽号 ----
    mov edx, [eax]
    test edx, 1
    jnz .fail
    mov ecx, edx
    and ecx, 0xFFFFF000
    jz .fail                           ; 空 PTE
    mov eax, edx
    shr eax, 12                        ; 槽号
    cmp eax, SWAP_SLOTS
    jae .fail
    mov [si_slot], eax
    ; 槽位必须真被占着
    mov ebx, eax
    mov ecx, eax
    and ecx, 31
    shr ebx, 5
    bt dword [swap_slot_bitmap + ebx * 4], ecx
    jnc .fail
    ; ---- 2) 拿一帧(页池不足时先换出别的)----
    call swap_alloc_frame
    test eax, eax
    jz .fail_noalloc
    mov [si_frame], eax
    ; ---- 3) 读回来 ----
    mov eax, [si_slot]
    shl eax, 3
    add eax, SWAP_LBA
    mov ecx, 8
    mov edi, [si_frame]
    call ata_read_sectors
    test eax, eax
    jnz .fail_free_frame
    ; ---- 4) 再确认一次 PTE(保险:单核关中断,理论上没人改)----
    mov eax, [si_pte]
    mov edx, [eax]
    mov ecx, edx
    and ecx, 0xFFFFF000
    mov eax, [si_slot]
    shl eax, 12
    cmp ecx, eax
    jne .fail_free_frame
    ; ---- 5) 装回 PTE:present + 可写 + 用户 ----
    mov eax, [si_frame]
    or eax, PAGE_P | PAGE_RW | PAGE_USER
    mov edx, [si_pte]
    mov [edx], eax
    mov eax, [si_va]
    invlpg [eax]
    ; ---- 6) 释放槽位 + 记账 ----
    mov eax, [si_slot]
    call swap_slot_free
    dec dword [swap_slots_used]
    inc dword [swap_in_count]
    mov edi, [space_cur]
    inc dword [edi + TCB_SP_PFRUN]
    inc dword [space_pf_total]
    cmp dword [edi + TCB_SP_FIRSTPA], 0
    jne .no_first
    mov eax, [si_frame]
    mov [edi + TCB_SP_FIRSTPA], eax
.no_first:
    ; 读回来的页还是匿名页,可以再次被换出
    mov eax, [si_frame]
    mov ebx, [si_pte]
    call swap_mark_anon
    popad
    mov eax, 1
    ret
.fail_free_frame:
    ; 读失败:帧还回去,槽继续保持(下次缺页再试),数据没动
    mov eax, [si_frame]
    call pmem_free
.fail_noalloc:
.fail:
    popad
    xor eax, eax
    ret

; ---------------------------------------------------------------------------
;  swap_anon_alloc(eax = 字节数)→ eax = 大匿名堆基址(VA)/ 0(失败)
;    syscall 31 的 handler;调用后用户程序直接用这块 VA,第一次碰就按需补页。
; ---------------------------------------------------------------------------
swap_anon_alloc:
    pushad
    test eax, eax
    jz .fail
    add eax, 4095
    and eax, 0xFFFFF000
    test eax, eax
    jz .fail
    mov [ua_size], eax
    call process_cur_tcb
    mov [ua_tcb], eax
    mov edx, [eax + TCB_UBRK]
    test edx, edx
    jnz .have_brk
    mov edx, USER_HEAP_VA
    mov [eax + TCB_UBRK], edx
.have_brk:
    mov ebx, edx
    add ebx, [ua_size]
    jc .fail
    mov ecx, USER_HEAP_VA
    add ecx, USER_HEAP_MAX
    cmp ebx, ecx
    ja .fail                           ; 超过 64 MiB 上限
    mov eax, [ua_tcb]
    mov [eax + TCB_UBRK], ebx
    mov [ua_ret], edx                  ; 返回这次分到的基址
    popad
    mov eax, [ua_ret]                  ; ★ popad 会把 eax 还原成输入参数,所以返回值
    ret                                ;   必须存在全局里、popad 之后再取
.fail:
    popad
    xor eax, eax
    ret

; ---------------------------------------------------------------------------
;  swap_space_free:地址空间收摊时,把大匿名堆的帧/页表/swap 槽全还回去。
;    入:edi = 空间状态(TCB 指针);出: eax = 释放的物理页数
;    小窗口(镜像/堆/栈)的帧由 paging.asm 的 space_free_window 负责,
;    swap 页(PTE present=0)那里也会释放槽位 —— 见 space_free_window。
; ---------------------------------------------------------------------------
swap_space_free:
    pushad
    mov [sf_space], edi
    mov ebx, 0                         ; 释放页数
    mov edx, [edi + TCB_SP_PD]
    test edx, edx
    jz .done
    mov eax, [edi + TCB_UBRK]
    cmp eax, USER_HEAP_VA
    jbe .done                          ; 没用过大匿名堆
    sub eax, USER_HEAP_VA
    shr eax, 22                        ; 最高 PDE 下标(相对 USER_HEAP_VA)
    mov [sf_maxidx], eax
    mov dword [sf_idx], 0
.pde_loop:
    mov eax, [sf_idx]
    cmp eax, [sf_maxidx]
    ja .done
    add eax, USER_HEAP_VA >> 22
    mov edx, [sf_space]
    mov edx, [edx + TCB_SP_PD]
    lea edx, [edx + eax * 4]           ; PDE 地址
    mov [sf_pdeaddr], edx
    mov eax, [edx]
    test eax, 1
    jz .next_pde
    and eax, 0xFFFFF000
    mov [sf_pt], eax
    mov dword [sf_j], 0
.pte_loop:
    mov eax, [sf_j]
    mov edx, [sf_pt]
    lea edx, [edx + eax * 4]           ; PTE 地址
    mov eax, [edx]
    test eax, 1
    jz .pte_swapped
    ; 正常页:一帧
    and eax, 0xFFFFF000
    call pmem_free
    jc .pte_next
    inc ebx
    jmp .pte_next
.pte_swapped:
    mov eax, [edx]
    test eax, PAGE_SWAP
    jz .pte_next                       ; 空项
    shr eax, 12
    test eax, eax
    jz .pte_next
    call swap_slot_free
    dec dword [swap_slots_used]
.pte_next:
    inc dword [sf_j]
    cmp dword [sf_j], 1024
    jb .pte_loop
    ; 页表页本身
    mov eax, [sf_pt]
    call pmem_free
    jc .next_pde
    inc ebx
    mov edx, [sf_pdeaddr]
    mov dword [edx], 0
.next_pde:
    inc dword [sf_idx]
    jmp .pde_loop
.done:
    mov [sf_ret], ebx
    popad
    mov eax, [sf_ret]
    ret

; ---------------------------------------------------------------------------
;  数据区
; ---------------------------------------------------------------------------
swap_enabled     dd 0
swap_meta_base   dd 0                  ; 帧元数据表(页池里的物理地址;恒等映射可直接用)
swap_meta_pages  dd 0
swap_slots_total dd 0
swap_slots_used  dd 0
swap_out_count   dd 0
swap_in_count    dd 0
swap_cursor      dd 0                  ; CLOCK 指针(帧号)
swap_hdr         times 512 db 0        ; swap 头扇区
swap_bounce      times 4096 db 0       ; 换出/换入的双缓冲(4 KiB)
swap_slot_bitmap times 512 db 0        ; 4096 槽 = 512 字节位图

; 临时变量(函数之间不重入,摆在全局省栈)
sma_pa       dd 0
sma_meta     dd 0
ev_left      dd 0
ev_pa        dd 0
ev_meta      dd 0
ev_slot      dd 0
sw_want      dd 0
sw_got       dd 0
sfa_tries    dd 0
si_pte       dd 0
si_va        dd 0
si_slot      dd 0
si_frame     dd 0
ua_size      dd 0
ua_tcb       dd 0
ua_ret       dd 0
sf_ret       dd 0
sf_space     dd 0
sf_maxidx    dd 0
sf_idx       dd 0
sf_pdeaddr   dd 0
sf_pt        dd 0
sf_j         dd 0
sw_tmp       dd 0

msg_swap_boot  db 'swap: ', 0
msg_swap_boot2 db ' slots x 4 KiB (16 MiB), frame metadata ', 0
msg_swap_boot3 db ' pages', 10, 0
