; ============================================================================
;  KKernel — i386 Linux ABI 转译层(int 0x80)  Phase P1 + P2 + P3 + P4
;
;  目标:让现成的 Linux i386 静态程序(最终是 static busybox)直接跑起来。
;  不改动原生 int 0x30 API;int 0x80 进来后在这里转译到内核能力。
;
;  P1:
;      1  sys_exit(code)                         ebx = 退出码
;      3  sys_read(fd, buf, count)               fd 0 = 键盘
;      4  sys_write(fd, buf, count)              fd 1/2 = 控制台
;  P2(本阶段):
;      5  sys_open(path, flags, mode)            fd 0/1/2 控制台,3+ = 文件
;      6  sys_close(fd)                          0/1/2 也算成功;3+ 释放槽
;      19 sys_lseek(fd, offset, whence)          SEEK_SET/CUR/END
;      3  sys_read(fd, ...)                      3+ = 文件(fd 0 仍是键盘)
;      4  sys_write(fd, ...)                     3+ = 文件(只支持"整文件覆盖")
;      45 sys_brk(addr)                          接程序堆窗口 SPACE_HEAP_VA
;  P3(本阶段,文件元信息 / 目录 / 时间):
;      106 sys_stat(path, buf)                   i386 struct stat(64B)
;      107 sys_lstat(path, buf)                  同 stat(不解析符号链接)
;      108 sys_fstat(fd, buf)                    0/1/2 = 字符设备,3+ = fd 表
;      220 sys_getdents64(fd, buf, count)        目录 fd 遍历 FAT 目录项
;      54  sys_ioctl(fd, req, arg)               仅 TCGETS(0x5401) 对控制台返回假 termios
;      13  sys_time(tloc)                        CMOS RTC → Unix 时间戳
;      78  sys_gettimeofday(tv, tz)              tv = {sec, usec}
;  P4(进程):
;      2   sys_fork()                            复制当前进程,子进程返回 0,父进程返回子 pid
;      20  sys_getpid()                          → 当前进程 pid
;      114 sys_wait4(pid, status*, options, ru)  等子进程退出/停止;options 只认 WNOHANG/WUNTRACED
;      37  sys_kill(pid, sig)                   只支持 pid>0;sig 支持 KILL/TERM/INT/STOP/CONT
;      11  sys_execve(path, argv, envp)         替换当前进程映像;argv/envp 先忽略
;  说明:P4 分段做 fork/getpid/wait4/kill/execve;fd 继承先不做(fd 表是全局的,
;      fork 天然共享、execve 会清空),写进 docs 已知限制。
;  目录 fd:open 只读打开目录成功,PFD_FLAGS 的 bit2 置位;read/write/lseek → -EISDIR。
;  其它编号一律 eax = -ENOSYS;fd 不合法 = -EBADF。
;
;  ABI(Linux i386 int 0x80):
;      eax = 系统调用号,ebx/ecx/edx/esi/edi/ebp = 参数
;      返回:eax = 结果;出错为 -errno(负数)
;      ★ 除 eax 外所有寄存器必须原样返回 —— 这是 Linux int 0x80 的语义,
;        libc 程序默认这么假设(它只指望 eax 变)。
;
;  P2 简化(写进 docs/posix.md 的"已知限制"):
;    · fd 表是全局的 8 个文件槽(fd 3..10),用 fs_lock 串行化;每进程独立 fd 表留 P3;
;    · open 只支持已存在的文件(不创建;O_CREAT/O_APPEND/O_TRUNC 返回 -ENOSYS);
;    · 文件读写上限 8 KiB(用一个全局 scratch 整读整写);
;    · write 是"读-改-整文件重写",不是真正的原地写;
;    · 路径按根目录解析(不接进程 cwd),最长 39 字符。
; ============================================================================

POSIX_VECTOR    equ 0x80                ; int 0x80(和 Linux 一致)
POSIX_ENOENT    equ 2
POSIX_EIO       equ 5
POSIX_EBADF     equ 9
POSIX_EINVAL    equ 22
POSIX_EMFILE    equ 24
POSIX_ENOSPC    equ 28
POSIX_ESPIPE    equ 29
POSIX_ENAMETOOLONG equ 36
POSIX_ENOSYS    equ 38
POSIX_EISDIR    equ 21
POSIX_ENOTDIR   equ 20
POSIX_ENOTTY    equ 25
; P4 新错误码
POSIX_EPERM     equ 1
POSIX_ESRCH     equ 3
POSIX_ECHILD    equ 10
POSIX_EAGAIN    equ 11
; P4b:kill 支持的最小信号集(Linux i386 信号号)
POSIX_SIGINT    equ 2
POSIX_SIGKILL   equ 9
POSIX_SIGTERM   equ 15
POSIX_SIGCONT   equ 18
POSIX_SIGSTOP   equ 19
; 拼 process.asm 的 signal_t:class<<24 | action<<16 | level
; (用 user 类 + user 级:同 uid 的进程之间可以发;super 类留给原生 int 0x30)
POSIX_SIGKILL_T equ (2 << 24) | (1 << 16) | 2   ; class=user action=kill level=user
POSIX_SIGTERM_T equ (2 << 24) | (2 << 16) | 2   ; class=user action=term level=user
POSIX_SIGINTR_T equ (2 << 24) | (5 << 16) | 2   ; class=user action=intr level=user
POSIX_SIGSTOP_T equ (2 << 24) | (3 << 16) | 2   ; class=user action=stop level=user
POSIX_SIGCONT_T equ (2 << 24) | (4 << 16) | 2   ; class=user action=cont level=user

; ---- P3:stat 模式位 / ioctl ----
S_IFREG         equ 0x8000
S_IFDIR         equ 0x4000
S_IFCHR         equ 0x2000
POSIX_MODE_FILE equ S_IFREG | 0x1A4    ; 0644
POSIX_MODE_DIR  equ S_IFDIR | 0x1ED    ; 0755
POSIX_MODE_CHR  equ S_IFCHR | 0x190    ; 0620
POSIX_TCGETS    equ 0x5401
; ---- i386 struct stat 偏移 ----
ST_MODE         equ 8
ST_NLINK        equ 10
ST_SIZE         equ 20
ST_BLKSIZE      equ 24
ST_BLOCKS       equ 28
ST_ATIME        equ 32
ST_MTIME        equ 40
ST_CTIME        equ 48
STAT_SIZE       equ 64

; ---- fd 表:0/1/2 = 控制台;3..(3+POSIX_FD_FILE_MAX-1) = 文件 ----
POSIX_FD_FILE_BASE  equ 3
POSIX_FD_FILE_MAX   equ 8               ; 8 个文件槽(fd 3..10)
PFD_USED            equ 0               ; 1 = 这个槽被占用
PFD_FLAGS           equ 4               ; open 的 flags(0=读,1=写,2=读写)
PFD_FSIZE           equ 8               ; 文件大小(open 时 fat_stat 得到)
PFD_OFF             equ 12              ; 当前读写偏移
PFD_PATH            equ 16              ; 路径(含 0,最长 39 字符)
POSIX_FD_PATHLEN    equ 40
PFD_CLUS            equ 56              ; 目录 fd:目录首簇(0 = 根);普通文件为 0
POSIX_FD_ENT        equ 60              ; 每槽 60 字节
PFD_DIR             equ 4               ; PFD_FLAGS 的 bit2:目录 fd
POSIX_SCRATCH_SIZE  equ 8192            ; 全局 scratch:整读整写用(<=8 KiB 文件)

; ---------------------------------------------------------------------------
;  posix_install:把 0x80 号中断门装上(DPL=3:ring 3 程序可 int 进来)
; ---------------------------------------------------------------------------
posix_install:
    mov eax, POSIX_VECTOR
    mov ebx, posix_stub
    call idt_install_user
    ret

; ---------------------------------------------------------------------------
;  posix_fd_reset:清空 POSIX 文件 fd 表(process_exec 每次装载新程序时调用)。
;  int 0x80 的 fd 表是全局的,程序退出/被杀后槽位不能留给下一个程序。
; ---------------------------------------------------------------------------
posix_fd_reset:
    pushad
    mov edi, posix_fd_tab
    mov ecx, (POSIX_FD_FILE_MAX * POSIX_FD_ENT) / 4
    xor eax, eax
    rep stosd
    popad
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
;  posix_dispatch:eax = 调用号 → 对应实现(返回值放 eax)
; ---------------------------------------------------------------------------
posix_dispatch:
    cmp eax, 1
    je sys_exit
    cmp eax, 2
    je sys_fork
    cmp eax, 20
    je sys_getpid
    cmp eax, 114
    je sys_wait4
    cmp eax, 37
    je sys_kill
    cmp eax, 11
    je sys_execve
    cmp eax, 3
    je sys_read
    cmp eax, 4
    je sys_write
    cmp eax, 5
    je sys_open
    cmp eax, 6
    je sys_close
    cmp eax, 19
    je sys_lseek
    cmp eax, 45
    je sys_brk
    cmp eax, 13
    je sys_time
    cmp eax, 54
    je sys_ioctl
    cmp eax, 78
    je sys_gettimeofday
    cmp eax, 106
    je sys_stat
    cmp eax, 107
    je sys_lstat
    cmp eax, 108
    je sys_fstat
    cmp eax, 220
    je sys_getdents64
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
;  sys_fork():fork(2) —— 复制当前进程(写时复制),子进程也返回到 ring 3。
;  复用 process.asm 的 process_fork:它需要 ebx = 中断现场帧基址。
;  本函数是从 posix_dispatch `je` 过来的(没有额外 call),栈上是:
;      [esp]    = 返回给 posix_stub 的地址
;      [esp+4]  = 调用号槽
;      [esp+8]..[esp+23] = gs/fs/es/ds(各 4B)
;      [esp+24] = pushad 帧基址
;  和 api.asm 的 api_h_fork(int 0x30 的 fork)是同一套布局。
;  返回:父进程 = 子 pid;子进程 = 0;失败 = -EAGAIN。
; ---------------------------------------------------------------------------
sys_fork:
    lea ebx, [esp + 24]                 ; ebx = pushad 帧基址(process_fork 会抄这个现场)
    call process_fork                   ; eax = 子 pid / 0(子) / -1
    cmp eax, -1
    jne .ok
    mov eax, -POSIX_EAGAIN              ; 资源不足(fork 失败)
.ok:
    ret

; ---------------------------------------------------------------------------
;  sys_getpid():getpid(20) → 当前 pid
; ---------------------------------------------------------------------------
sys_getpid:
    call process_getpid                 ; eax = sched_cur + 1
    ret

; ---------------------------------------------------------------------------
;  sys_wait4(pid, status*, options, rusage):wait4(114)
;  Linux 参数:ebx=pid,ecx=status*,edx=options(WNOHANG=1/WUNTRACED=2),esi=rusage
;  映射到 process_wait2(eax=pid, ebx=我们的 flags: bit0=WUNTRACED, bit1=WNOHANG)
;  返回:子 pid / 0(WNOHANG 且无事件) / -ECHILD / -ENOSYS(暂不支持的 pid)
;  退出状态按 Linux:正常退出 status = (exitcode & 0xFF) << 8;停住 status = 0x7F。
; ---------------------------------------------------------------------------
sys_wait4:
    pushad
    ; ebx=pid, ecx=status*(原值在 [esp+24] 槽), edx=options
    mov eax, ebx                        ; eax = pid
    cmp eax, -1
    je .wf_pid_ok
    test eax, eax
    jle .wf_enosys                      ; pid 0 / < -1:暂不支持(进程组语义)
.wf_pid_ok:
    ; Linux options → 我们的 flags(bit0=WUNTRACED, bit1=WNOHANG)
    xor ebx, ebx
    test edx, 1                         ; LINUX_WNOHANG
    jz .wf_no_nohang
    or ebx, 2
.wf_no_nohang:
    test edx, 2                         ; LINUX_WUNTRACED
    jz .wf_no_untraced
    or ebx, 1
.wf_no_untraced:
    call process_wait2                  ; eax = -1 没孩子 / 0 有事件 / 1 WNOHANG 无事件
    cmp eax, -1
    je .wf_echild
    cmp eax, 1
    je .wf_noevent
    ; ---- 有事件:从本线程 TCB 读事件细节(线程私有,不会被别的 waiter 覆盖)----
    call process_cur_tcb
    mov edx, [eax + TCB_WAIT_PID]       ; 事件 pid
    mov ecx, [eax + TCB_WAIT_STATUS]    ; 0=退出 1=停住
    test ecx, ecx
    jnz .wf_stopped
    mov ebx, [eax + TCB_WAIT_CODE]      ; 退出码
    and ebx, 0xFF
    shl ebx, 8                          ; Linux WIFEXITED:status = code << 8
    jmp .wf_write_status
.wf_stopped:
    mov ebx, 0x7F                       ; WIFSTOPPED:低 8 位 = 0x7F
.wf_write_status:
    mov edi, [esp + 24]                 ; 原始 ecx = status*(可能为 NULL)
    test edi, edi
    jz .wf_no_write
    mov [edi], ebx
.wf_no_write:
    mov [esp + 28], edx                 ; 放回 pushad 的 eax 槽:返回子 pid
    jmp .wf_out
.wf_echild:
    mov dword [esp + 28], -POSIX_ECHILD
    jmp .wf_out
.wf_noevent:
    mov dword [esp + 28], 0
    jmp .wf_out
.wf_enosys:
    mov dword [esp + 28], -POSIX_ENOSYS
.wf_out:
    popad
    ret

; ---------------------------------------------------------------------------
;  sys_kill(pid, sig):kill(37)
;  Linux 参数:ebx=pid,ecx=sig。P4b 只支持 pid > 0。
;  sig 支持:KILL(9)/TERM(15)/INT(2)/STOP(19)/CONT(18);sig=0 只探测(返回 0)。
;  返回:0 成功 / -ESRCH(没有该进程)/ -EPERM(权限不够)/ -EINVAL(信号不支持)/
;        -ENOSYS(暂不支持的 pid 形式)。
;  实现:映射到 process.asm 的 signal_t,调 process_signal_send(带 uid 权限检查)。
; ---------------------------------------------------------------------------
sys_kill:
    ; ebx = pid, ecx = sig
    cmp ebx, 1
    jl .kill_enosys                     ; pid 0 / 负数(进程组语义):暂不支持
    mov ebp, ebx                        ; ebp = pid(下面要用别的东西)
    mov eax, ecx                        ; eax = sig
    test eax, eax
    jz .kill_zero                       ; kill(pid, 0) = 探测,直接成功
    ; ---- 先确认目标 TCB 存在(非空槽),区分 ESRCH 与 EPERM ----
    mov edx, ebp
    dec edx                             ; pid - 1 = TCB 槽号
    cmp edx, SCHED_MAX
    jae .kill_esrch
    imul edx, TCB_SIZE
    add edx, tcb_table
    cmp dword [edx + TCB_STATE], ST_EMPTY
    je .kill_esrch
    ; ---- 信号号 → signal_t ----
    cmp eax, POSIX_SIGKILL
    je .kill_kill
    cmp eax, POSIX_SIGTERM
    je .kill_term
    cmp eax, POSIX_SIGINT
    je .kill_intr
    cmp eax, POSIX_SIGSTOP
    je .kill_stop
    cmp eax, POSIX_SIGCONT
    je .kill_cont
    mov eax, -POSIX_EINVAL
    ret
.kill_kill:
    mov ebx, POSIX_SIGKILL_T
    jmp .kill_send
.kill_term:
    mov ebx, POSIX_SIGTERM_T
    jmp .kill_send
.kill_intr:
    mov ebx, POSIX_SIGINTR_T
    jmp .kill_send
.kill_stop:
    mov ebx, POSIX_SIGSTOP_T
    jmp .kill_send
.kill_cont:
    mov ebx, POSIX_SIGCONT_T
.kill_send:
    mov eax, ebp                        ; eax = pid
    call process_signal_send            ; eax = 0 成功 / -1 失败(权限/状态)
    cmp eax, -1
    jne .kill_ok
    mov eax, -POSIX_EPERM
    ret
.kill_ok:
    xor eax, eax
    ret
.kill_zero:
    xor eax, eax
    ret
.kill_esrch:
    mov eax, -POSIX_ESRCH
    ret
.kill_enosys:
    mov eax, -POSIX_ENOSYS
    ret

; ---------------------------------------------------------------------------
;  sys_execve(path, argv, envp):execve(11)
;  Linux 参数:ebx=pathname,ecx=argv,edx=envp(P4c 先忽略 argv/envp —— 新程序
;  拿不到参数,shell 的 run 仍走原生 int 0x30 的带参数路径)。
;  行为:把 pathname 拷进内核缓冲 → process_exec 替换当前进程映像;
;        成功不返回(iret 到新程序入口),失败返回 -ENOENT / -ENAMETOOLONG。
;  process.asm 侧配合:exec 前切内核页目录(CR3=0x1000)+ ring3 错误返回模式。
; ---------------------------------------------------------------------------
sys_execve:
    ; ---- 1) 拷贝 pathname(此刻 CR3 还是用户页目录,可直接读用户地址)----
    mov esi, ebx
    mov edi, posix_exec_path
    mov ecx, 63
.ex_copy:
    mov al, [esi]
    mov [edi], al
    inc esi
    inc edi
    test al, al
    jz .ex_copied
    dec ecx
    jnz .ex_copy
    mov eax, -POSIX_ENAMETOOLONG
    ret
.ex_copied:
    ; ---- 2) 走 process_exec 的 ring3 错误返回模式 ----
    ;  保证走"普通调用"分支(不用 TCB_EXECBUF 作业载荷):execve 自己给了路径。
    call process_cur_tcb
    mov dword [eax + TCB_EXECBUF], 0
    mov dword [proc_exec_error_mode], 1
    mov eax, posix_exec_path
    call process_exec                   ; 成功不返回;失败(-ENOENT)会返回
    ret

; ---------------------------------------------------------------------------
;  sys_write(fd, buf, count) → 写入字节数 / -errno
;  fd 1/2 = 控制台;fd 3.. = POSIX 文件(读旧+补零+覆盖,整文件写回)
; ---------------------------------------------------------------------------
sys_write:
    cmp ebx, 1
    je .wr_console
    cmp ebx, 2
    je .wr_console
    cmp ebx, POSIX_FD_FILE_BASE
    jb .wr_ebadf
    push esi
    push edi
    push ebp
    mov ebp, edx                        ; count
    mov esi, ecx                        ; user buf
    call posix_fd_lookup
    test eax, eax
    jz .wr_file_ebadf
    mov ebx, eax                        ; ebx = fd entry
    mov eax, [ebx + PFD_FLAGS]
    and eax, 3
    jz .wr_file_ebadf
    test ebp, ebp
    jz .wr_file_nothing
    ; 边界:off + count <= scratch
    mov ecx, [ebx + PFD_OFF]
    mov edx, ecx
    add edx, ebp                        ; edx = new size
    cmp edx, POSIX_SCRATCH_SIZE
    jbe .wr_file_size_ok
    mov eax, -POSIX_ENOSPC
    jmp .wr_file_out
.wr_file_size_ok:
    push ecx                            ; 保存 offset
    push edx                            ; 保存 new size
    lea esi, [ebx + PFD_PATH]
    mov edi, posix_scratch
    call posix_fs_read                  ; eax = old size / -1
    pop edx                             ; new size
    pop ecx                             ; offset
    cmp eax, -1
    jne .wr_file_old_ok
    mov eax, -POSIX_EIO
    jmp .wr_file_out
.wr_file_old_ok:
    ; 补零 old..new(eax=old, edx=new, ecx=offset)
    mov edi, posix_scratch
    add edi, eax
.wr_file_zero_loop:
    cmp eax, edx
    jae .wr_file_zero_done
    mov byte [edi], 0
    inc edi
    inc eax
    jmp .wr_file_zero_loop
.wr_file_zero_done:
    ; 覆盖:scratch+offset ← buf,count 字节
    mov edi, posix_scratch
    add edi, ecx
    mov ecx, ebp
.wr_file_copy:
    mov al, [esi]
    mov [edi], al
    inc esi
    inc edi
    dec ecx
    jnz .wr_file_copy
    ; 整文件写回
    push edx                            ; new size
    lea esi, [ebx + PFD_PATH]
    mov edi, posix_scratch
    mov ecx, edx
    call posix_fs_write                 ; eax = 0 / -1
    pop edx
    test eax, eax
    js .wr_file_ioerr
    ; 更新 fd:off += count;fsize = new size
    mov eax, [ebx + PFD_OFF]
    add eax, ebp
    mov [ebx + PFD_OFF], eax
    mov [ebx + PFD_FSIZE], edx
    mov eax, ebp
    jmp .wr_file_out
.wr_file_nothing:
    xor eax, eax
    jmp .wr_file_out
.wr_file_ebadf:
    mov eax, -POSIX_EBADF
    jmp .wr_file_out
.wr_file_ioerr:
    mov eax, -POSIX_EIO
.wr_file_out:
    pop ebp
    pop edi
    pop esi
    ret
.wr_console:
    push ecx
    push edx
    mov ebp, edx                        ; ebp = 剩余字节数
    mov edi, ecx                        ; edi = 用户缓冲
    test ebp, ebp
    jz .wr_console_done
.wr_console_loop:
    mov al, [edi]
    pushad
    call term_putc
    popad
    inc edi
    dec ebp
    jnz .wr_console_loop
.wr_console_done:
    pop edx
    pop ecx
    mov eax, edx                        ; 返回值 = count
    ret
.wr_ebadf:
    mov eax, -POSIX_EBADF
    ret

; ---------------------------------------------------------------------------
;  sys_read(fd, buf, count) → 读到的字节数 / -errno
;  fd 0 = 键盘(阻塞读 1 字节);fd 3.. = POSIX 文件
; ---------------------------------------------------------------------------
sys_read:
    test ebx, ebx
    jz .rd_stdin
    cmp ebx, POSIX_FD_FILE_BASE
    jb .rd_ebadf
    push esi
    push edi
    push ebp
    mov ebp, edx                        ; count
    mov esi, ecx                        ; user buf
    call posix_fd_lookup
    test eax, eax
    jz .rd_file_ebadf
    mov ebx, eax                        ; entry
    test dword [ebx + PFD_FLAGS], PFD_DIR
    jnz .rd_file_isdir
    test ebp, ebp
    jz .rd_file_zero
    mov eax, [ebx + PFD_OFF]
    cmp eax, [ebx + PFD_FSIZE]
    jae .rd_file_zero
    mov ecx, [ebx + PFD_FSIZE]
    sub ecx, eax                        ; 剩余
    cmp ecx, ebp
    jbe .rd_n_ok
    mov ecx, ebp
.rd_n_ok:
    mov ebp, ecx                        ; n
    push eax                            ; offset
    push esi                            ; user buf
    lea esi, [ebx + PFD_PATH]
    mov edi, posix_scratch
    call posix_fs_read                  ; eax 仅作成功标志
    pop esi                             ; user buf
    pop ecx                             ; offset
    cmp eax, -1
    je .rd_file_ioerr
    lea edi, [posix_scratch]
    add edi, ecx
    mov ecx, ebp
.rd_file_copy:
    mov al, [edi]
    mov [esi], al
    inc edi
    inc esi
    dec ecx
    jnz .rd_file_copy
    mov eax, [ebx + PFD_OFF]
    add eax, ebp
    mov [ebx + PFD_OFF], eax
    mov eax, ebp
    jmp .rd_file_out
.rd_file_zero:
    xor eax, eax
    jmp .rd_file_out
.rd_file_isdir:
    mov eax, -POSIX_EISDIR
    jmp .rd_file_out
.rd_file_ebadf:
    mov eax, -POSIX_EBADF
    jmp .rd_file_out
.rd_file_ioerr:
    mov eax, -POSIX_EIO
.rd_file_out:
    pop ebp
    pop edi
    pop esi
    ret
.rd_ebadf:
    mov eax, -POSIX_EBADF
    ret
.rd_stdin:
    test edx, edx
    jz .rd_stdin_zero
    call jobctl_key_allowed
    test eax, eax
    jz .rd_stdin_eof                ; 后台作业:读 tty 给 EOF
    push ecx
    push edx
    call process_cur_tcb
    mov ebx, eax
    test ebx, ebx
    jz .rd_stdin_eof_pop
    call pit_get_ticks
    mov [ebx + TCB_KBUSY], eax
    mov dword [ebx + TCB_KBWAIT], 1
    call kbd_getchar
    mov dl, al
    mov dword [ebx + TCB_KBWAIT], 0
    pop edx
    pop ecx
    mov [ecx], dl
    mov eax, 1
    ret
.rd_stdin_zero:
    xor eax, eax
    ret
.rd_stdin_eof:
    xor eax, eax
    ret
.rd_stdin_eof_pop:
    pop edx
    pop ecx
    xor eax, eax
    ret

; ---------------------------------------------------------------------------
;  sys_open(path, flags, mode):P2 只支持已存在文件(不创建)
;  flags 低 2 位:0/1/2(读/写/读写);其它位(O_CREAT 等)→ -ENOSYS。
; ---------------------------------------------------------------------------
sys_open:
    mov eax, ecx
    and eax, ~3
    jnz .op_enosys
    and ecx, 3
    mov [posix_open_flags], ecx
    ; 路径拷到 posix_path_tmp(最长 39 字符)
    mov esi, ebx
    mov edi, posix_path_tmp
    mov ecx, POSIX_FD_PATHLEN - 1
.op_copy:
    lodsb
    test al, al
    jz .op_copy_done
    stosb
    dec ecx
    jnz .op_copy
    mov eax, -POSIX_ENAMETOOLONG
    ret
.op_copy_done:
    mov byte [edi], 0
    ; 以根目录解析:FAT 全局状态需要 fs_lock
    call fs_lock
    mov eax, [fat_dir]
    mov [posix_saved_dir], eax
    mov dword [fat_dir], 0
    mov esi, posix_path_tmp
    call fat_path
    jc .op_err_nofile
    mov esi, eax                        ; 末段名
    cmp byte [esi], 0
    je .op_root_dir                     ; 路径就是根目录
    call fat_stat
    cmp eax, -1
    je .op_err_nofile
    mov [posix_open_size], eax
    mov eax, [fat_stat_attr]
    test al, 0x10                       ; attr bit4 = 目录
    jnz .op_dir
    cmp dword [posix_open_size], POSIX_SCRATCH_SIZE
    ja .op_err_toobig
    mov dword [posix_open_dirflag], 0
    mov dword [posix_open_clus], 0
    jmp .op_have
.op_root_dir:
    mov dword [posix_open_size], 0
    mov dword [posix_open_dirflag], 1
    mov dword [posix_open_clus], 0
    jmp .op_have
.op_dir:
    cmp dword [posix_open_flags], 0     ; 目录只允许只读打开
    jne .op_err_eisdir
    mov esi, posix_path_tmp
    call fat_dir_open                   ; 取目录首簇(内部重新从根解析)
    cmp eax, -1
    je .op_err_nofile
    mov dword [posix_open_dirflag], 1
    mov eax, [fat_dent_clus]
    mov [posix_open_clus], eax
.op_have:
    ; 找空槽
    mov edi, posix_fd_tab
    mov ecx, 0
.op_find:
    cmp ecx, POSIX_FD_FILE_MAX
    jae .op_err_noslot
    cmp byte [edi + PFD_USED], 0
    je .op_found
    add edi, POSIX_FD_ENT
    inc ecx
    jmp .op_find
.op_found:
    ; 恢复 fat_dir + 解锁,再填表(填表不需要 FAT 锁)
    mov eax, [posix_saved_dir]
    mov [fat_dir], eax
    call fs_unlock
    mov byte [edi + PFD_USED], 1
    mov eax, [posix_open_flags]
    cmp dword [posix_open_dirflag], 0
    je .op_flags_ok
    or eax, PFD_DIR
.op_flags_ok:
    mov [edi + PFD_FLAGS], eax
    mov eax, [posix_open_size]
    mov [edi + PFD_FSIZE], eax
    mov dword [edi + PFD_OFF], 0
    mov eax, [posix_open_clus]
    mov [edi + PFD_CLUS], eax
    ; 路径进槽
    push edi
    mov esi, posix_path_tmp
    lea edi, [edi + PFD_PATH]
    mov ecx, POSIX_FD_PATHLEN
    rep movsb
    pop edi
    ; fd = 3 + (slot - posix_fd_tab)/56
    mov eax, edi
    sub eax, posix_fd_tab
    mov ecx, POSIX_FD_ENT
    xor edx, edx
    div ecx
    add eax, POSIX_FD_FILE_BASE
    ret
.op_err_nofile:
    call posix_restore_dir_unlock
    mov eax, -POSIX_ENOENT
    ret
.op_err_toobig:
    call posix_restore_dir_unlock
    mov eax, -POSIX_EINVAL
    ret
.op_err_noslot:
    call posix_restore_dir_unlock
    mov eax, -POSIX_EMFILE
    ret
.op_err_eisdir:
    call posix_restore_dir_unlock
    mov eax, -POSIX_EISDIR
    ret
.op_enosys:
    mov eax, -POSIX_ENOSYS
    ret

; ---------------------------------------------------------------------------
;  sys_close(fd):0/1/2 直接成功;3+ 清槽
; ---------------------------------------------------------------------------
sys_close:
    cmp ebx, POSIX_FD_FILE_BASE
    jb .cl_ok
    call posix_fd_lookup
    test eax, eax
    jz .cl_ebadf
    mov byte [eax + PFD_USED], 0
.cl_ok:
    xor eax, eax
    ret
.cl_ebadf:
    mov eax, -POSIX_EBADF
    ret

; ---------------------------------------------------------------------------
;  sys_lseek(fd, offset, whence):ebx=fd, ecx=offset, edx=whence
;  0=SEEK_SET,1=SEEK_CUR,2=SEEK_END;偏移必须非负且 <= 8 KiB
; ---------------------------------------------------------------------------
sys_lseek:
    mov ebp, edx                        ; 先存 whence(posix_fd_lookup 会踩 edx)
    cmp ebx, POSIX_FD_FILE_BASE
    jb .ls_pipe
    call posix_fd_lookup
    test eax, eax
    jz .ls_ebadf
    mov esi, eax
    test dword [esi + PFD_FLAGS], PFD_DIR
    jnz .ls_eisdir
    cmp ebp, 0
    je .ls_set
    cmp ebp, 1
    je .ls_cur
    cmp ebp, 2
    je .ls_end
    mov eax, -POSIX_EINVAL
    ret
.ls_set:
    mov eax, ecx
    jmp .ls_check
.ls_cur:
    mov eax, [esi + PFD_OFF]
    add eax, ecx
    jmp .ls_check
.ls_end:
    mov eax, [esi + PFD_FSIZE]
    add eax, ecx
.ls_check:
    test eax, eax
    js .ls_einval
    cmp eax, POSIX_SCRATCH_SIZE
    ja .ls_einval
    mov [esi + PFD_OFF], eax
    ret
.ls_pipe:
    mov eax, -POSIX_ESPIPE
    ret
.ls_ebadf:
    mov eax, -POSIX_EBADF
    ret
.ls_einval:
    mov eax, -POSIX_EINVAL
    ret
.ls_eisdir:
    mov eax, -POSIX_EISDIR
    ret

; ---------------------------------------------------------------------------
;  sys_brk(addr):返回新的 break(成功)或旧值(失败);addr=0 → 查询当前值。
;  P2 只记账+边界检查,真正的物理页在首次写时由缺页处理补零。
; ---------------------------------------------------------------------------
sys_brk:
    push ebx                            ; [esp] = requested addr
    call process_cur_tcb
    test eax, eax
    jz .brk_fail
    mov edx, eax                        ; edx = tcb
    mov eax, [edx + TCB_POSIX_BRK]
    test eax, eax
    jnz .brk_have
    mov eax, SPACE_HEAP_VA
    mov [edx + TCB_POSIX_BRK], eax
.brk_have:
    mov ecx, [esp]                      ; requested
    test ecx, ecx
    jz .brk_return                      ; 查询当前 break
    mov esi, [edx + TCB_SP_HEAPPAGES]
    shl esi, 12
    add esi, SPACE_HEAP_VA              ; esi = 堆窗口上界
    cmp ecx, SPACE_HEAP_VA
    jb .brk_return
    cmp ecx, esi
    ja .brk_return
    mov [edx + TCB_POSIX_BRK], ecx
    mov eax, ecx
.brk_return:
    pop ebx
    ret
.brk_fail:
    mov eax, -POSIX_EINVAL
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  posix_fd_lookup:ebx = fd → eax = 槽指针 / 0(未打开或非法 fd)
; ---------------------------------------------------------------------------
posix_fd_lookup:
    xor eax, eax
    cmp ebx, POSIX_FD_FILE_BASE
    jb .lk_out
    mov edx, ebx
    sub edx, POSIX_FD_FILE_BASE
    cmp edx, POSIX_FD_FILE_MAX
    jae .lk_out
    imul edx, POSIX_FD_ENT
    add edx, posix_fd_tab
    cmp byte [edx + PFD_USED], 0
    je .lk_out
    mov eax, edx
.lk_out:
    ret

; ---------------------------------------------------------------------------
;  posix_restore_dir_unlock:恢复 [fat_dir] 并 fs_unlock(调用者须在持锁状态)
; ---------------------------------------------------------------------------
posix_restore_dir_unlock:
    mov eax, [posix_saved_dir]
    mov [fat_dir], eax
    call fs_unlock
    ret

; ---------------------------------------------------------------------------
;  posix_fs_stat:esi = POSIX 路径(可含 '/')→ eax = 文件大小 / -1
; ---------------------------------------------------------------------------
posix_fs_stat:
    pushad
    mov [posix_fs_path], esi
    call fs_lock
    mov eax, [fat_dir]
    mov [posix_saved_dir], eax
    mov dword [fat_dir], 0
    mov esi, [posix_fs_path]
    call fat_path
    jc .pfs_fail
    mov esi, eax
    call fat_stat
    mov [posix_ret], eax
    call posix_restore_dir_unlock
    popad
    mov eax, [posix_ret]
    ret
.pfs_fail:
    call posix_restore_dir_unlock
    mov dword [posix_ret], -1
    popad
    mov eax, [posix_ret]
    ret

; ---------------------------------------------------------------------------
;  posix_fs_read:esi = 路径,edi = 目标 → eax = 读到的字节数 / -1
; ---------------------------------------------------------------------------
posix_fs_read:
    pushad
    mov [posix_fs_path], esi
    mov [posix_fs_buf], edi
    call fs_lock
    mov eax, [fat_dir]
    mov [posix_saved_dir], eax
    mov dword [fat_dir], 0
    mov esi, [posix_fs_path]
    call fat_path
    jc .pfr_fail
    mov esi, eax
    mov edi, [posix_fs_buf]
    call fat_read_file
    mov [posix_ret], eax
    call posix_restore_dir_unlock
    popad
    mov eax, [posix_ret]
    ret
.pfr_fail:
    call posix_restore_dir_unlock
    mov dword [posix_ret], -1
    popad
    mov eax, [posix_ret]
    ret

; ---------------------------------------------------------------------------
;  posix_fs_write:esi = 路径,edi = 数据,ecx = 长度 → eax = 0 / -1
;  (整文件写;fat_write_file 只接受当前目录单段名)
; ---------------------------------------------------------------------------
posix_fs_write:
    pushad
    mov [posix_fs_path], esi
    mov [posix_fs_buf], edi
    mov [posix_fs_len], ecx
    call fs_lock
    mov eax, [fat_dir]
    mov [posix_saved_dir], eax
    mov dword [fat_dir], 0
    mov esi, [posix_fs_path]
    call fat_path
    jc .pfw_fail
    mov esi, eax
    mov edi, [posix_fs_buf]
    mov ecx, [posix_fs_len]
    call fat_write_file
    mov [posix_ret], eax
    call posix_restore_dir_unlock
    popad
    mov eax, [posix_ret]
    ret
.pfw_fail:
    call posix_restore_dir_unlock
    mov dword [posix_ret], -1
    popad
    mov eax, [posix_ret]
    ret


; ===========================================================================
;  P3:stat / fstat / lstat / getdents64 / ioctl / time / gettimeofday
; ===========================================================================

; ---------------------------------------------------------------------------
;  posix_stat_fill:把 i386 struct stat(64B)填到 [esi]
;    输入:esi = statbuf, eax = 模式位(含 S_IFxxx), ecx = 文件大小
;    时间字段用当前 RTC 时间(秒级),dev/ino/nlink 等填最小可用值。
; ---------------------------------------------------------------------------
posix_stat_fill:
    pushad
    mov [posix_st_mode], eax
    mov [posix_st_size], ecx
    mov edi, esi
    mov ecx, STAT_SIZE / 4
    xor eax, eax
    rep stosd                           ; 整个结构先清零
    mov eax, [posix_st_mode]
    mov [esi + ST_MODE], ax
    mov word [esi + ST_NLINK], 1
    mov eax, [posix_st_size]
    mov [esi + ST_SIZE], eax
    mov dword [esi + ST_BLKSIZE], 512
    mov edx, eax
    add edx, 511
    shr edx, 9
    mov [esi + ST_BLOCKS], edx
    mov dword [esi + 4], 1              ; st_ino(随便给个非 0 值)
    call posix_epoch
    mov [esi + ST_ATIME], eax
    mov [esi + ST_MTIME], eax
    mov [esi + ST_CTIME], eax
    popad
    ret

; ---------------------------------------------------------------------------
;  posix_epoch:返回 Unix 时间戳(秒),RTC → 1970-01-01 起的秒数
;  CMOS 时间按本地时间处理(不做时区换算)。
; ---------------------------------------------------------------------------
posix_epoch:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    call rtc_get
    ; ---- 年:1970 .. rtc_year-1 的 365/366 天累加 ----
    mov ecx, 1970
    mov edi, [rtc_year]
    xor ebx, ebx
.pe_year:
    cmp ecx, edi
    jae .pe_years_done
    add ebx, 365
    mov eax, ecx
    call posix_is_leap
    add ebx, eax
    inc ecx
    jmp .pe_year
.pe_years_done:
    ; ---- 月:1 .. rtc_mon-1 的天数 ----
    mov ecx, 1
    mov esi, posix_mdays
    movzx eax, byte [rtc_mon]           ; ★ rtc_mon 是 db,必须按字节读
    mov [posix_epoch_mon], eax
.pe_mon:
    cmp ecx, [posix_epoch_mon]
    jae .pe_mons_done
    movzx eax, byte [esi + ecx - 1]
    add ebx, eax
    inc ecx
    jmp .pe_mon
.pe_mons_done:
    ; 闰年且月份 > 2 时 +1(2 月 29 日)
    cmp dword [posix_epoch_mon], 2
    jbe .pe_no_leap
    mov eax, [rtc_year]
    call posix_is_leap
    add ebx, eax
.pe_no_leap:
    movzx eax, byte [rtc_day]
    dec eax
    add ebx, eax
    ; ---- 秒 = 天 * 86400 + 时 * 3600 + 分 * 60 + 秒 ----
    imul ebx, ebx, 86400
    movzx eax, byte [rtc_hour]
    imul eax, eax, 3600
    add ebx, eax
    movzx eax, byte [rtc_min]
    imul eax, eax, 60
    add ebx, eax
    movzx eax, byte [rtc_sec]
    add ebx, eax
    mov eax, ebx
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  posix_is_leap:eax = 年 → eax = 1/0(公历闰年)
; ---------------------------------------------------------------------------
posix_is_leap:
    push ebx
    push ecx
    push edx
    mov ecx, eax
    xor edx, edx
    mov ebx, 4
    div ebx
    test edx, edx
    jnz .pil_no
    mov eax, ecx
    xor edx, edx
    mov ebx, 100
    div ebx
    test edx, edx
    jnz .pil_yes
    mov eax, ecx
    xor edx, edx
    mov ebx, 400
    div ebx
    test edx, edx
    jnz .pil_no
.pil_yes:
    mov eax, 1
    jmp .pil_out
.pil_no:
    xor eax, eax
.pil_out:
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  sys_time(tloc):ebx = time_t*(可为 0);返回 Unix 时间戳
; ---------------------------------------------------------------------------
sys_time:
    push ebx
    call posix_epoch
    pop ebx
    test ebx, ebx
    jz .t_out
    mov [ebx], eax
.t_out:
    ret

; ---------------------------------------------------------------------------
;  sys_gettimeofday(tv, tz):ebx = timeval*(sec,usec),ecx = timezone*(忽略)
; ---------------------------------------------------------------------------
sys_gettimeofday:
    push esi
    push edi
    mov esi, ebx
    mov edi, ecx
    call posix_epoch
    test esi, esi
    jz .gt_done
    mov [esi], eax
    push eax
    call pit_get_ticks
    mov ecx, 10
    xor edx, edx
    div ecx                             ; edx = 10ms tick 的余数
    imul edx, edx, 10000
    mov [esi + 4], edx
    pop eax
.gt_done:
    xor eax, eax
    pop edi
    pop esi
    ret

; ---------------------------------------------------------------------------
;  sys_ioctl(fd, req, arg):只支持控制台(0/1/2)的 TCGETS → 假 termios
; ---------------------------------------------------------------------------
sys_ioctl:
    cmp ecx, POSIX_TCGETS
    jne .io_enotty
    cmp ebx, POSIX_FD_FILE_BASE
    jae .io_enotty
    test edx, edx
    jz .io_ok
    push edi
    push ecx
    mov edi, edx
    mov ecx, 9                          ; 36 字节(termios)
    xor eax, eax
    rep stosd
    pop ecx
    pop edi
.io_ok:
    xor eax, eax
    ret
.io_enotty:
    mov eax, -POSIX_ENOTTY
    ret

; ---------------------------------------------------------------------------
;  posix_stat_common:esi = 路径,edi = statbuf → eax = 0 / -errno
;  目录和文件都支持(根目录 "/" 也支持)。
; ---------------------------------------------------------------------------
posix_stat_common:
    pushad
    mov [posix_st_path], esi
    mov [posix_st_buf], edi
    call fs_lock
    mov eax, [fat_dir]
    mov [posix_saved_dir], eax
    mov dword [fat_dir], 0
    mov esi, [posix_st_path]
    call fat_path
    jc .sc_fail
    cmp byte [eax], 0
    je .sc_root
    mov esi, eax
    call fat_stat
    cmp eax, -1
    je .sc_fail
    mov [posix_st_size], eax
    mov eax, [fat_stat_attr]
    test al, 0x10
    jnz .sc_dir
    mov eax, POSIX_MODE_FILE
    jmp .sc_mode_ok
.sc_dir:
    mov eax, POSIX_MODE_DIR
    jmp .sc_mode_ok
.sc_root:
    mov dword [posix_st_size], 0
    mov eax, POSIX_MODE_DIR
.sc_mode_ok:
    mov [posix_st_mode], eax
    mov eax, [posix_saved_dir]
    mov [fat_dir], eax
    call fs_unlock
    mov esi, [posix_st_buf]
    mov eax, [posix_st_mode]
    mov ecx, [posix_st_size]
    call posix_stat_fill
    mov dword [esp + 28], 0
    jmp .sc_out
.sc_fail:
    mov eax, [posix_saved_dir]
    mov [fat_dir], eax
    call fs_unlock
    mov dword [esp + 28], -POSIX_ENOENT
.sc_out:
    popad
    ret

; ---------------------------------------------------------------------------
;  sys_stat(path, buf)/sys_lstat = stat(不解析符号链接)
; ---------------------------------------------------------------------------
sys_stat:
    mov esi, ebx
    mov edi, ecx
    jmp posix_stat_common

sys_lstat:
    jmp sys_stat

; ---------------------------------------------------------------------------
;  sys_fstat(fd, buf):0/1/2 = 字符设备;3+ = fd 表里的文件/目录
; ---------------------------------------------------------------------------
sys_fstat:
    push edi
    mov edi, ecx                        ; statbuf
    cmp ebx, POSIX_FD_FILE_BASE
    jb .fs_console
    call posix_fd_lookup
    test eax, eax
    jz .fs_ebadf
    mov esi, eax
    test dword [esi + PFD_FLAGS], PFD_DIR
    jnz .fs_dir
    mov eax, POSIX_MODE_FILE
    mov ecx, [esi + PFD_FSIZE]
    jmp .fs_fill
.fs_dir:
    mov eax, POSIX_MODE_DIR
    xor ecx, ecx
    jmp .fs_fill
.fs_console:
    mov eax, POSIX_MODE_CHR
    xor ecx, ecx
.fs_fill:
    mov esi, edi
    call posix_stat_fill
    xor eax, eax
    pop edi
    ret
.fs_ebadf:
    pop edi
    mov eax, -POSIX_EBADF
    ret

; ---------------------------------------------------------------------------
;  sys_getdents64(fd, buf, count):目录 fd → 若干个 linux_dirent64 记录
;  记录布局(i386,u64 对齐 4/8):d_ino 0(8B)、d_off 8、d_reclen 16(2B)、
;  d_type 18(1B)、d_name 19(NUL 结尾,不足 8 字节对齐补零)。
;  返回本轮写入的字节数;没有更多条目返回 0;目录 fd 的 PFD_OFF 当 cookie 用。
; ---------------------------------------------------------------------------
sys_getdents64:
    pushad
    mov [posix_gd_buf], ecx
    mov [posix_gd_left], edx
    mov dword [posix_gd_written], 0
    call posix_fd_lookup
    test eax, eax
    jz .gd_ebadf
    mov [posix_gd_ent], eax
    test dword [eax + PFD_FLAGS], PFD_DIR
    jz .gd_enotdir
.gd_loop:
    mov eax, [posix_gd_ent]
    mov eax, [eax + PFD_CLUS]
    mov edx, [posix_gd_ent]
    mov edx, [edx + PFD_OFF]
    call fat_dirent                     ; eax = 1 找到 / 0 结束 / -1 错
    cmp eax, 0
    je .gd_done
    js .gd_eio
    ; ---- 名字长度 ----
    mov esi, fat_dent_name
    xor ecx, ecx
.gd_namelen:
    cmp byte [esi + ecx], 0
    je .gd_namedone
    inc ecx
    jmp .gd_namelen
.gd_namedone:
    mov [posix_gd_namelen], ecx
    ; ---- reclen = (19 + namelen + 1 + 7) & ~7 ----
    lea eax, [ecx + 27]
    and eax, 0xFFFFFFF8
    mov [posix_gd_reclen], eax
    ; ---- 放得下吗?放不下就结束本轮(不消费该条目)----
    mov edx, [posix_gd_written]
    add edx, eax
    cmp edx, [posix_gd_left]
    ja .gd_done
    ; ---- 记录清零 ----
    mov edi, [posix_gd_buf]
    add edi, [posix_gd_written]
    push edi
    mov ecx, eax
    xor eax, eax
    rep stosb
    pop edi
    ; ---- 头:ino/off/reclen/type ----
    mov eax, [posix_gd_ent]
    mov eax, [eax + PFD_OFF]
    add eax, 1
    mov [edi + 0], eax
    mov dword [edi + 4], 0
    mov [edi + 8], eax                  ; d_off(下一条的 cookie)
    mov dword [edi + 12], 0
    mov eax, [posix_gd_reclen]
    mov [edi + 16], ax
    mov al, 8                           ; DT_REG
    mov edx, [fat_dent_attr]
    test dl, 0x10
    jz .gd_type_ok
    mov al, 4                           ; DT_DIR
.gd_type_ok:
    mov [edi + 18], al
    ; ---- 名字 ----
    lea edi, [edi + 19]
    mov esi, fat_dent_name
    mov ecx, [posix_gd_namelen]
    inc ecx
.gd_copy:
    mov al, [esi]
    mov [edi], al
    inc esi
    inc edi
    dec ecx
    jnz .gd_copy
    ; ---- 记账 + 下一条 ----
    mov eax, [posix_gd_reclen]
    add [posix_gd_written], eax
    mov eax, [posix_gd_ent]
    inc dword [eax + PFD_OFF]
    jmp .gd_loop
.gd_done:
    mov eax, [posix_gd_written]
    mov [esp + 28], eax
    jmp .gd_out
.gd_ebadf:
    mov dword [esp + 28], -POSIX_EBADF
    jmp .gd_out
.gd_enotdir:
    mov dword [esp + 28], -POSIX_ENOTDIR
    jmp .gd_out
.gd_eio:
    mov dword [esp + 28], -POSIX_EIO
.gd_out:
    popad
    ret

; ---------------------------------------------------------------------------
;  数据
; ---------------------------------------------------------------------------
posix_saved_dir     dd 0
posix_open_flags    dd 0
posix_open_size     dd 0
posix_open_dirflag  dd 0
posix_open_clus     dd 0
posix_st_mode       dd 0
posix_st_size       dd 0
posix_st_path       dd 0
posix_st_buf        dd 0
posix_gd_buf        dd 0
posix_gd_left       dd 0
posix_gd_written    dd 0
posix_gd_ent        dd 0
posix_gd_reclen     dd 0
posix_gd_namelen    dd 0
posix_mdays         db 31,28,31,30,31,30,31,31,30,31,30,31
posix_epoch_mon     dd 0
posix_fs_path       dd 0
posix_fs_buf        dd 0
posix_fs_len        dd 0
posix_ret           dd 0
posix_path_tmp      times POSIX_FD_PATHLEN db 0
posix_fd_tab        times POSIX_FD_FILE_MAX * POSIX_FD_ENT db 0
posix_scratch       times POSIX_SCRATCH_SIZE db 0
posix_exec_path     times 64 db 0       ; execve 的 pathname 内核缓冲
