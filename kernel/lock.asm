; ===========================================================================
;  kernel/lock.asm —— 锁(Phase A4:调度器地基的同步原语)
;
;  单核内核的并发来源只有两个:
;    1) 线程抢占:IRQ0 每 2 tick 可能切到别的线程,临界区被打断;
;    2) 中断:IRQ 处理函数和被打断的线程竞争同一份全局状态。
;
;  所以这里提供两档锁:
;    - spin_lock / spin_unlock:短临界区,持锁期间关中断(cli),不能被抢占,
;      持锁时间必须在"几条指令"级别(不能等 IO、不能睡)。
;    - mutex_lock / mutex_unlock:睡眠互斥锁(递归),拿不到锁就
;      sched_sleep_on(mutex 地址) 睡在锁自己身上,unlock 唤醒等待者。
;      适合 FAT/ATA 这种会等几十毫秒的操作;不能在中断上下文里用。
;
;  实例:
;    console_mutex → console_lock / console_unlock:每个字符/整串输出加锁,
;                    保证不同线程的 tty 输出不会交错;
;    fs_mutex      → fs_lock / fs_unlock:文件系统命令与文件类系统调用,
;                    保护 FAT 全局状态(fat_dir / FAT 缓冲 / ATA 寄存器组)。
;
;  ★ 锁顺序(死锁预防):
;       fs_mutex → console_mutex 允许(文件系统命令里会打印);
;       console_mutex → fs_mutex 禁止(输出路径绝不去碰文件系统)。
;    spin_lock 只用于"不嵌套、不睡"的极短临界区;持 spin 锁时禁止再拿任何
;    其他锁、禁止调用可能睡眠的函数。
;
;  实现说明:mutex 的 owner 存"TCB 指针",同一线程重入时只加深 depth;
;  unlock 只有在 depth 归零时才真正释放并 sched_wakeup。调度器内部状态
;  (TCB 表、就绪队列)本来就在 cli 里改(见 sched.asm),不再另加锁。
; ===========================================================================

; ---- mutex 结构:3 个 dword,全 0 = 空闲(所以不用初始化,定义即 0)----
MUTEX_LOCKED equ 0                      ; 0=空闲 1=已锁
MUTEX_OWNER  equ 4                      ; 持有者 TCB 指针(0=无)
MUTEX_DEPTH  equ 8                      ; 同一线程的重入深度
MUTEX_SIZE   equ 12

; ---------------------------------------------------------------------------
;  spin_lock:eax = 锁地址(dword,0=空闲)
;    把调用方的 IF 压栈,持锁期间关中断;拿不到就 sti;hlt 等下一次中断再试。
;    必须用 spin_unlock 配平(pop 掉 IF)。
;    注意:单核下"等锁"等于等持锁线程被调度回来,所以持锁时间要短。
; ---------------------------------------------------------------------------
spin_lock:
    pushfd
    cli
.spin:
    cmp dword [eax], 0
    je .got
    sti                                 ; 让定时器/键盘中断进来,否则单核死等
    hlt
    cli
    jmp .spin
.got:
    mov dword [eax], 1
    ret

; ---------------------------------------------------------------------------
;  spin_unlock:eax = 锁地址;释放并恢复 spin_lock 之前的中断状态
; ---------------------------------------------------------------------------
spin_unlock:
    mov dword [eax], 0
    popfd
    ret

; ---------------------------------------------------------------------------
;  mutex_init:eax = mutex 地址 → 清零(定义即 0,一般不需要调用)
; ---------------------------------------------------------------------------
mutex_init:
    mov dword [eax + MUTEX_LOCKED], 0
    mov dword [eax + MUTEX_OWNER], 0
    mov dword [eax + MUTEX_DEPTH], 0
    ret

; ---------------------------------------------------------------------------
;  mutex_lock:eax = mutex 地址;阻塞直到拿到锁
;    - 空闲:占锁,记录 owner=当前 TCB,depth=1
;    - 已被同一线程持有:递归,只加深 depth(方便 console 输出里套输出)
;    - 别的线程持有:睡在 "mutex 地址" 这个通道上,醒了再试
; ---------------------------------------------------------------------------
mutex_lock:
    pushad
    pushfd                              ; 保存调用方的中断状态(不能无条件 sti:
                                        ; 开机早期 IDT 还没装好,乱开中断会 triple fault)
    cli
.retry:
    mov ebx, eax                        ; ebx = mutex 地址(上下文切换会保存寄存器)
    cmp dword [ebx + MUTEX_LOCKED], 0
    jne .busy
    ; ---- 空闲:占锁 ----
    mov dword [ebx + MUTEX_LOCKED], 1
    mov dword [ebx + MUTEX_DEPTH], 1
    call process_cur_tcb
    mov [ebx + MUTEX_OWNER], eax
    popfd                               ; 恢复调用方的 IF
    popad
    ret
.busy:
    call process_cur_tcb
    cmp eax, [ebx + MUTEX_OWNER]
    jne .wait
    ; ---- 同一线程重入:只加深 ----
    inc dword [ebx + MUTEX_DEPTH]
    popfd
    popad
    ret
.wait:
    mov eax, ebx                        ; 通道 = mutex 自己的地址
    call sched_sleep_on                 ; 睡到 unlock 时被唤醒(内部管理 IF)
    cli                                 ; 醒来重新进临界区再看一眼
    jmp .retry

; ---------------------------------------------------------------------------
;  mutex_unlock:eax = mutex 地址;depth 归零才真正释放并唤醒等待者
; ---------------------------------------------------------------------------
mutex_unlock:
    pushad
    pushfd                              ; 保存调用方 IF,别顺手把中断开成花
    cli
    mov ebx, eax
    dec dword [ebx + MUTEX_DEPTH]
    jnz .out
    mov dword [ebx + MUTEX_LOCKED], 0
    mov dword [ebx + MUTEX_OWNER], 0
    mov eax, ebx                        ; 通道 = mutex 地址
    call sched_wakeup                   ; 唤醒所有睡在这把锁上的线程
.out:
    popfd
    popad
    ret

; ---------------------------------------------------------------------------
;  console_lock / console_unlock:tty 输出互斥(保护 VBE 光标/行缓冲/ANSI 状态)
;  允许递归:term_print → tty_out_char 会两次进入,靠 mutex 递归计数
; ---------------------------------------------------------------------------
; ★ 包一层时**必须保护 eax**:mutex_lock 用 eax 传 mutex 地址,而 tty_out_char
;   正拿 al 当"要输出的字符" —— 不保护的话每个字符都会变成地址低字节(踩过:
;   屏幕全是花字,查了半天)
console_lock:
    push eax
    mov eax, console_mutex
    call mutex_lock
    pop eax
    ret

console_unlock:
    push eax
    mov eax, console_mutex
    call mutex_unlock
    pop eax
    ret

; ---------------------------------------------------------------------------
;  fs_lock / fs_unlock:文件系统互斥(FAT 全局状态 + ATA 读盘缓冲)
;  锁顺序:fs_lock → console_lock 允许(文件命令里打印);反过来禁止。
; ---------------------------------------------------------------------------
fs_lock:
    push eax
    mov eax, fs_mutex
    call mutex_lock
    pop eax
    ret

fs_unlock:
    push eax
    mov eax, fs_mutex
    call mutex_unlock
    pop eax
    ret

; ---------------------------------------------------------------------------
;  数据:两个 mutex 实例(全 0 = 空闲)
; ---------------------------------------------------------------------------
console_mutex   times MUTEX_SIZE db 0   ; tty 输出锁
fs_mutex        times MUTEX_SIZE db 0   ; 文件系统锁
