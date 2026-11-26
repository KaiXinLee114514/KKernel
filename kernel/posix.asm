; ============================================================================
;  KKernel — i386 Linux ABI 转译层(int 0x80)  Phase P1
;
;  目标:让现成的 Linux i386 静态程序(最终是 static busybox)直接跑起来。
;  不改动原生 int 0x30 API;int 0x80 进来后在这里转译到内核能力。
;
;  P1 只做最小闭环:
;      1  sys_exit(code)                         ebx = 退出码
;      3  sys_read(fd, buf, count)               fd 0 = 键盘
;      4  sys_write(fd, buf, count)              fd 1/2 = 控制台
;  其它编号一律 eax = -ENOSYS;fd 不合法 = -EBADF。
;
;  ABI(Linux i386 int 0x80):
;      eax = 系统调用号,ebx/ecx/edx/esi/edi/ebp = 参数
;      返回:eax = 结果;出错为 -errno(负数)
;      ★ 除 eax 外所有寄存器必须原样返回 —— 这是 Linux int 0x80 的语义,
;        libc 程序默认这么假设(它只指望 eax 变)。
;
;  和 int 0x30 的关系:两层完全独立;int 0x30 是 KKernel 原生 API(程序是
;  平铺 BIN),int 0x80 是给 ELF(Linux ABI)用的。内核里互不影响。
; ============================================================================

POSIX_VECTOR    equ 0x80                ; int 0x80(和 Linux 一致)
POSIX_ENOSYS    equ 38                  ; 未知系统调用
POSIX_EBADF     equ 9                   ; 坏 fd

; ---------------------------------------------------------------------------
;  posix_install:把 0x80 号中断门装上(DPL=3:ring 3 程序可 int 进来)
; ---------------------------------------------------------------------------
posix_install:
    mov eax, POSIX_VECTOR
    mov ebx, posix_stub
    call idt_install_user
    ret

; ---------------------------------------------------------------------------
;  posix_stub:int 0x80 的第一站。保存现场 → 派发 → 回填 eax → iret
;  和 api_stub 同样的坑:切段寄存器会冲掉 eax(系统调用号),先存 EBP 再切。
; ---------------------------------------------------------------------------
posix_stub:
    pushad
    push ds
    push es
    push fs
    push gs
    mov ebp, eax                        ; ebp = 系统调用号
    mov ax, 0x10                        ; 内核数据段(平坦)
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov eax, ebp
    push eax                            ; [esp] = 调用号(线程栈上,SLEEP 也安全)
    call posix_dispatch
    ; 结果写回 pushad 帧的 eax 槽:此刻 [esp]=调用号槽,上面 gs/fs/es/ds 16B,
    ; 再 +20 是 pushad 帧基址,帧内 eax 槽在 +28。其余寄存器 popad 自然恢复原值。
    mov [esp + 20 + 28], eax
    pop edx                             ; 取回调用号
    pop gs
    pop fs
    pop es
    pop ds
    popad
    iret

; ---------------------------------------------------------------------------
;  posix_dispatch:eax = 调用号 → 调用对应实现(返回值放 eax)
;  参数按 Linux 约定:ebx/ecx/edx/esi/edi/ebp
; ---------------------------------------------------------------------------
posix_dispatch:
    cmp eax, 1
    je sys_exit
    cmp eax, 3
    je sys_read
    cmp eax, 4
    je sys_write
    mov eax, -POSIX_ENOSYS
    ret

; ---------------------------------------------------------------------------
;  sys_exit(code):ebx = 退出码。不返回。
;  复用 int 0x30 的退出路径:有父进程 → process_exit(僵尸等收尸);
;  没有父进程(shell 直接跑的)→ api_exit 恢复内核现场回 shell。
; ---------------------------------------------------------------------------
sys_exit:
    mov eax, ebx                        ; api_exit 从 ebx 读退出码
    mov ebx, eax
    jmp api_exit                        ; 不返回

; ---------------------------------------------------------------------------
;  sys_write(fd, buf, count)   ebx=fd, ecx=buf, edx=count
;  fd 1/2 → 控制台;其它 → -EBADF。返回写入字节数。
;  逐字节 pushad/popad 调 term_putc:term_putc 走 tty 层(VBE 图形/文本模式都正确)。
; ---------------------------------------------------------------------------
sys_write:
    cmp ebx, 1
    je .wr_ok
    cmp ebx, 2
    je .wr_ok
    mov eax, -POSIX_EBADF
    ret
.wr_ok:
    push ecx
    push edx
    mov ebp, edx                        ; ebp = 剩余字节数
    mov edi, ecx                        ; edi = 用户缓冲
    test ebp, ebp
    jz .wr_done
.wr_loop:
    mov al, [edi]
    pushad
    call term_putc
    popad
    inc edi
    dec ebp
    jnz .wr_loop
.wr_done:
    pop edx
    pop ecx
    mov eax, edx                        ; 返回值 = count
    ret

; ---------------------------------------------------------------------------
;  sys_read(fd, buf, count)    ebx=fd, ecx=buf, edx=count
;  P1:只支持 fd 0(键盘),一次读 1 个字节;后台进程(不能读 tty)返回 0(EOF,
;  与 Linux 的"后台读终端"语义一致,免得卡死)。其它 fd → -EBADF。
; ---------------------------------------------------------------------------
sys_read:
    test ebx, ebx
    jz .rd_ok
    mov eax, -POSIX_EBADF
    ret
.rd_ok:
    test edx, edx                       ; count == 0 → 直接 0
    jz .rd_zero
    ; 后台进程不能抢键盘:返回 0(EOF),和 int 0x30 的 getchar 策略一致
    call jobctl_key_allowed
    test eax, eax
    jz .rd_zero
    ; 记"最近读键盘的 tick":前台作业里读键的算交互程序,^C 交给它自己处理
    push ecx
    push edx
    call process_cur_tcb
    mov ecx, [pit_ticks]
    mov [eax + TCB_KBUSY], ecx
    mov dword [eax + TCB_KBWAIT], 1     ; 正阻塞等键盘:交互程序
    push eax
    call kbd_getchar                    ; 没有键就 hlt 等中断;返回 al
    pop ecx
    mov dword [ecx + TCB_KBWAIT], 0
    pop edx
    pop ecx                             ; ecx = 用户缓冲
    mov [ecx], al
    mov eax, 1
    ret
.rd_zero:
    xor eax, eax
    ret
