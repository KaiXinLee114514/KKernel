; ============================================================================
;  KKernel — 作业控制(Phase B)地基:进程组/会话 + 前台进程组 + ^C/^Z 过滤
;
;  这一层回答三个问题:
;    1) "这个进程属于哪个作业?"          → TCB_PGRP(进程组号,组长 = 首进程 pid)
;    2) "现在哪个作业占着键盘/屏幕?"      → tty_fg_pgrp(前台进程组)
;    3) "键盘上的 ^C/^Z 该给谁?"          → jobctl_kbd_filter(在 kbd_push 之前过滤)
;
;  约定(最小实现):
;    · 会话只有一个(SHELL_SID = 1):所有 shell 线程和它们启的作业都在同一会话;
;    · shell 自己的进程组固定为 SHELL_PGRP = 1;shell 线程(含主 shell)都属于它;
;    · 每个作业由 shell 用 setpgid(子 pid, 子 pid) 建一个新组,首进程是组长;
;    · shell 跑前台作业前 tcsetpgrp(作业组),结束后 tcsetpgrp(SHELL_PGRP)。
;
;  ^C 的语义(兼顾旧程序):
;    · 前台是 shell 组 → 不进信号,^C 照常进键盘缓冲,由 shell 行规程清行;
;    · 前台是作业,且它最近 1 秒内读过键盘(j_getkey/j_getchar 会记 TCB_KBUSY)
;      → 认为它是"交互程序"(如 MINE),^C 字节照常给它自己处理;
;    · 否则 → 给当前 ring3 线程置 KILLREQ,下一次 IRQ0 在它自己的现场上收摊。
;  ^Z 的语义:前台是作业 → 置 STOPREQ,IRQ0 里把线程标 ST_STOPPED 并唤醒父 shell。
;  后台读 tty:jobctl_key_allowed 返回 0,api 的 getchar/getkey 直接给 EOF/无事件。
;
;  这个文件在 start.asm 里最后 include,所以能安全使用 TCB_* / sched_* /
;  process_* 等前面文件里的符号,也能被前面 include 的 keyboard.asm 前向调用。
; ============================================================================

; ---------------------------------------------------------------------------
;  tty_fg_pgrp:当前占用终端(键盘)的前台进程组。默认是 shell 自己的组。
; ---------------------------------------------------------------------------
tty_fg_pgrp     dd SHELL_PGRP

; ---------------------------------------------------------------------------
;  tty_setpgrp:切换前台进程组(eax = 新组号)→ eax = 0
;  最小实现不做归属校验:只有内核 shell 和程序里的 tcsetpgrp 会调它。
; ---------------------------------------------------------------------------
tty_setpgrp:
    mov [tty_fg_pgrp], eax
    xor eax, eax
    ret

; ---------------------------------------------------------------------------
;  tty_getpgrp:→ eax = 当前前台进程组
; ---------------------------------------------------------------------------
tty_getpgrp:
    mov eax, [tty_fg_pgrp]
    ret

; ---------------------------------------------------------------------------
;  jobctl_key_allowed:当前线程能不能读键盘?
;    出:eax = 1 可以(前台作业 / shell 自己) / 0 后台作业(读 tty 给 EOF)
;  这是"后台读 tty 的简单策略":后台不阻塞挂起,直接当没输入。
; ---------------------------------------------------------------------------
jobctl_key_allowed:
    push ecx
    call process_cur_tcb
    mov ecx, [eax + TCB_PGRP]
    cmp ecx, [tty_fg_pgrp]
    je .ok
    cmp ecx, SHELL_PGRP
    je .ok
    xor eax, eax
    pop ecx
    ret
.ok:
    mov eax, 1
    pop ecx
    ret

; ---------------------------------------------------------------------------
;  jobctl_kbd_filter:键盘输入过滤(kbd_push 写环形缓冲之前调用)
;    入:al = 刚翻译出来的字符(控制码已经是 0x01..0x1A)
;    出:CF=1 已消费(不要再进缓冲) / CF=0 照常进缓冲(eax/al 原样保留)
;    警告:必须保留 eax——调用方 kbd_push 还指着 al 存字符呢!
; ---------------------------------------------------------------------------
jobctl_fg_running:
    push ecx
    push edx
    xor ecx, ecx
    mov edx, tcb_table
.loop:
    cmp ecx, SCHED_MAX
    jae .none
    cmp dword [edx + TCB_STATE], ST_EMPTY
    je .next
    mov eax, [edx + TCB_PGRP]
    cmp eax, [tty_fg_pgrp]
    jne .next
    cmp dword [edx + TCB_SP_RUNNING], 0
    je .next
    mov eax, edx
    pop edx
    pop ecx
    ret
.next:
    add edx, TCB_SIZE
    inc ecx
    jmp .loop
.none:
    xor eax, eax
    pop edx
    pop ecx
    ret

jobctl_kbd_filter:
    push eax
    push ebx
    push ecx
    push edx
    cmp al, 3                           ; ^C
    je .intr
    cmp al, 0x1A                        ; ^Z
    je .stop
    jmp .pass
.intr:
    mov ebx, [tty_fg_pgrp]
    cmp ebx, SHELL_PGRP
    je .pass                            ; shell 自己跑内置命令:^C 只清行
    ; 注意:当前被中断的线程不一定是前台作业(别的 shell 线程也在轮转,
    ; 前台作业可能正处于被抢占状态)——必须按**进程组**去扫 TCB,
    ; 不能把 space_cur 当作目标(踩过:^C 十次有八次落在别的 shell 上,全丢)。
    call jobctl_fg_running
    test eax, eax
    jz .consumed                        ; 前台组里没有 ring3 程序在跑:吃掉按键
    ; ★ 正阻塞在 getkey/getchar 等键盘 = 交互程序(如游戏):^C 交给它自己处理。
    ;   只靠"最近 1 秒读过键"不够 —— 玩家长时间不按键时 tick 早就过期了,
    ;   而这时程序还卡在内核的 hlt 轮询里,KILLREQ 也收不到(踩过:MINE 的 ^C 失效)。
    cmp dword [eax + TCB_KBWAIT], 0
    jne .pass
    ; 否则:前台作业最近 1 秒(100 tick)读过键盘也算交互程序
    mov ecx, [pit_ticks]
    sub ecx, [eax + TCB_KBUSY]
    cmp ecx, 100
    jb .pass
    mov dword [eax + TCB_SP_KILLREQ], 1 ; IRQ0 在它自己的现场上收摊
    jmp .consumed
.stop:
    mov ebx, [tty_fg_pgrp]
    cmp ebx, SHELL_PGRP
    je .pass                            ; shell 自己:^Z 当普通按键(忽略)
    call jobctl_fg_running
    test eax, eax
    jz .consumed
    mov dword [eax + TCB_STOPREQ], 1    ; IRQ0 里标 STOPPED + 唤醒父 shell
    jmp .consumed
.pass:
    pop edx
    pop ecx
    pop ebx
    pop eax
    clc                                 ; CF=0:照常进缓冲
    ret
.consumed:
    pop edx
    pop ecx
    pop ebx
    pop eax
    stc                                 ; CF=1:已消费
    ret
