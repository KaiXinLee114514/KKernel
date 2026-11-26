; ============================================================================
;  KKernel — i386 Linux ABI 转译层(int 0x80)  Phase P1 + P2
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

; ---- fd 表:0/1/2 = 控制台;3..(3+POSIX_FD_FILE_MAX-1) = 文件 ----
POSIX_FD_FILE_BASE  equ 3
POSIX_FD_FILE_MAX   equ 8               ; 8 个文件槽(fd 3..10)
PFD_USED            equ 0               ; 1 = 这个槽被占用
PFD_FLAGS           equ 4               ; open 的 flags(0=读,1=写,2=读写)
PFD_FSIZE           equ 8               ; 文件大小(open 时 fat_stat 得到)
PFD_OFF             equ 12              ; 当前读写偏移
PFD_PATH            equ 16              ; 路径(含 0,最长 39 字符)
POSIX_FD_PATHLEN    equ 40
POSIX_FD_ENT        equ 56              ; 每槽 56 字节(4*4 + 40)
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
    call fat_stat
    cmp eax, -1
    je .op_err_nofile
    cmp eax, POSIX_SCRATCH_SIZE
    ja .op_err_toobig
    mov [posix_open_size], eax
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
    mov [edi + PFD_FLAGS], eax
    mov eax, [posix_open_size]
    mov [edi + PFD_FSIZE], eax
    mov dword [edi + PFD_OFF], 0
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

; ---------------------------------------------------------------------------
;  数据
; ---------------------------------------------------------------------------
posix_saved_dir     dd 0
posix_open_flags    dd 0
posix_open_size     dd 0
posix_fs_path       dd 0
posix_fs_buf        dd 0
posix_fs_len        dd 0
posix_ret           dd 0
posix_path_tmp      times POSIX_FD_PATHLEN db 0
posix_fd_tab        times POSIX_FD_FILE_MAX * POSIX_FD_ENT db 0
posix_scratch       times POSIX_SCRATCH_SIZE db 0
