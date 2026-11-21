; ===========================================================================
;  users.asm —— 最小多用户:内置用户表 + 登录 + 身份(uid/gid)落进 TCB
;
;  这个阶段只做"身份",不做完整的权限隔离:
;    · 3 个内置用户:super(uid 0,别名 root / SYSTEM)、system(uid 1)、user(uid 2)
;    · 密码明文存表里(注释说明:哈希/盐留给下一阶段,这里求小)
;    · 登录:用户名(不分大小写,空 = user) + 密码(区分大小写),3 次失败退回 user
;    · 软盘启动没有 FAT → 跳过登录,默认 super(保护老测试的屏幕断言)
;    · 登录成功后 uid/gid 写进所有 TCB;之后 shell_spawn_extra / fork / spawn 继承
;      (kernel/shell.asm / kernel/process.asm)
;    · shell 命令:whoami / su / login(本文件实现,shell.asm 里登记)
;    · 信号发送权限检查在 process.asm 的 process_signal_send 开头
;
;  用户表项 36 字节:
;    +0   name[16]   (NUL 结尾,后面补 0)
;    +16  uid        dd
;    +20  gid        dd
;    +24  password   dd → 明文密码串
;    +28  alias1     dd → 别名串(0 = 无)
;    +32  alias2     dd → 别名串(0 = 无)
; ===========================================================================

US_NAME   equ 0
US_UID    equ 16
US_GID    equ 20
US_PW     equ 24
US_ALIAS1 equ 28
US_ALIAS2 equ 32
US_SIZE   equ 36

; ---------------------------------------------------------------------------
;  users_apply_uid:把当前登录身份写进所有活着的 TCB
;    (登录时只有主 shell 线程;su 时其它 shell/进程也一起换,简单直接)
; ---------------------------------------------------------------------------
users_apply_uid:
    pushad
    xor ebx, ebx
.loop:
    cmp ebx, SCHED_MAX
    jae .out
    mov eax, ebx
    imul eax, TCB_SIZE
    add eax, tcb_table
    cmp dword [eax + TCB_STATE], ST_EMPTY
    je .next
    mov edx, [login_uid]
    mov [eax + TCB_UID], edx
    mov edx, [login_gid]
    mov [eax + TCB_GID], edx
.next:
    inc ebx
    jmp .loop
.out:
    popad
    ret

; ---------------------------------------------------------------------------
;  users_find:esi = 用户名(不分大小写,别名也算)→ eax = 表项指针 / 0
; ---------------------------------------------------------------------------
users_find:
    push ebx
    push edi
    mov ebx, users_tab
.next:
    cmp ebx, users_tab_end
    jae .notfound
    ; ---- 名字 ----
    mov edi, ebx                        ; 表项名字段在 +0
    call users_streq_nocase
    test eax, eax
    jnz .found
    ; ---- alias1 ----
    mov edi, [ebx + US_ALIAS1]
    test edi, edi
    jz .try_alias2
    call users_streq_nocase
    test eax, eax
    jnz .found
.try_alias2:
    mov edi, [ebx + US_ALIAS2]
    test edi, edi
    jz .next_entry
    call users_streq_nocase
    test eax, eax
    jnz .found
.next_entry:
    add ebx, US_SIZE
    jmp .next
.found:
    mov eax, ebx
    pop edi
    pop ebx
    ret
.notfound:
    xor eax, eax
    pop edi
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  users_streq_nocase:esi/edi 两个 NUL 结尾串,不分大小写比较 → eax 1/0
;  users_streq:       区分大小写比较 → eax 1/0
; ---------------------------------------------------------------------------
users_streq_nocase:
    push esi
    push edi
.loop:
    mov al, [esi]
    mov dl, [edi]
    cmp al, 'A'
    jb .no_up1
    cmp al, 'Z'
    ja .no_up1
    add al, 32
.no_up1:
    cmp dl, 'A'
    jb .no_up2
    cmp dl, 'Z'
    ja .no_up2
    add dl, 32
.no_up2:
    cmp al, dl
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

users_streq:
    push esi
    push edi
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
;  users_trim:esi = 串;跳过前导空格,原地去掉尾部空格,返回 esi = 第一个非空格
; ---------------------------------------------------------------------------
users_trim:
    push eax
    push edi
.skip:
    cmp byte [esi], ' '
    jne .find_end
    inc esi
    jmp .skip
.find_end:
    mov edi, esi
.scan:
    cmp byte [edi], 0
    je .back
    inc edi
    jmp .scan
.back:
    cmp edi, esi
    jbe .done
    cmp byte [edi - 1], ' '
    jne .done
    dec edi
    jmp .back
.done:
    mov byte [edi], 0
    pop edi
    pop eax
    ret

; ---------------------------------------------------------------------------
;  users_login:开机登录(shell 线程还没起来,单线程跑)
;    用户名为空 → user;3 次失败 → 退回 user 并提示
;    fat_ok = 0(软盘启动)→ 直接跳过,默认 super
; ---------------------------------------------------------------------------
users_login:
    pushad
    cmp byte [fat_ok], 0
    je .out
    mov dword [ul_tries], 0
.retry:
    ; ---- 用户名 ----
    mov esi, msg_login
    call term_print
    mov edi, ul_name_buf
    mov ecx, 32
    call tty_read_line
    mov esi, ul_name_buf
    call users_trim
    cmp byte [esi], 0
    jne .have_name
    mov esi, ul_name_user               ; 空行 = user
.have_name:
    call users_find
    test eax, eax
    jz .bad_user
    mov [ul_entry], eax
    ; ---- 密码 ----
    mov esi, msg_password
    call term_print
    mov edi, ul_pw_buf
    mov ecx, 32
    call tty_read_password
    mov al, 10                          ; 密码不回显,自己补个换行
    call term_putc
    mov edx, [ul_entry]
    mov edi, [edx + US_PW]
    mov esi, ul_pw_buf
    call users_streq
    test eax, eax
    jz .bad_pw
    ; ---- 成功:记身份 + 写 TCB ----
    mov edx, [ul_entry]
    mov eax, [edx + US_UID]
    mov [login_uid], eax
    mov eax, [edx + US_GID]
    mov [login_gid], eax
    lea eax, [edx + US_NAME]
    mov [login_name], eax
    call users_apply_uid
    mov esi, msg_welcome
    call term_print
    mov esi, [login_name]
    call term_print
    mov esi, msg_uid_eq
    call term_print
    mov eax, [login_uid]
    call term_print_dec
    mov esi, msg_close
    call term_print
    jmp .out
.bad_user:
    mov esi, msg_login_bad_user
    call term_print
    inc dword [ul_tries]
    jmp .maybe_fallback
.bad_pw:
    mov esi, msg_login_bad_pw
    call term_print
    inc dword [ul_tries]
.maybe_fallback:
    cmp dword [ul_tries], 3
    jb .retry
    ; ---- 3 次失败:退回 user ----
    mov esi, msg_login_fallback
    call term_print
    mov dword [login_uid], 2
    mov dword [login_gid], 2
    mov dword [login_name], ul_name_user
    call users_apply_uid
.out:
    popad
    ret

; ---------------------------------------------------------------------------
;  shell 命令:whoami —— 我是谁
; ---------------------------------------------------------------------------
cmd_whoami:
    pushad
    mov esi, msg_whoami
    call term_print
    mov esi, [login_name]
    call term_print
    mov esi, msg_uid_eq
    call term_print
    mov eax, [login_uid]
    call term_print_dec
    mov esi, msg_close
    call term_print
    popad
    ret

; ---------------------------------------------------------------------------
;  shell 命令:su <用户> —— 切身份(只有 uid 0 = super 能用,不再问密码)
; ---------------------------------------------------------------------------
cmd_su:
    pushad
    cmp dword [login_uid], 0
    je .root
    mov esi, msg_su_deny
    call term_print
    jmp .out
.root:
    call usbd_first_word                ; esi/ecx = 第一个词;[usbd_rest] = 剩下
    test ecx, ecx
    jz .usage
    ; 拷进名字缓冲并加 NUL(名字最长 31)
    cmp ecx, 31
    jbe .len_ok
    mov ecx, 31
.len_ok:
    mov edi, ul_name_buf
.copy:
    mov al, [esi]
    mov [edi], al
    inc esi
    inc edi
    dec ecx
    jnz .copy
    mov byte [edi], 0
    mov esi, ul_name_buf
    call users_trim
    cmp byte [esi], 0
    je .usage
    call users_find
    test eax, eax
    jz .nouser
    mov edx, eax
    mov eax, [edx + US_UID]
    mov [login_uid], eax
    mov eax, [edx + US_GID]
    mov [login_gid], eax
    lea eax, [edx + US_NAME]
    mov [login_name], eax
    call users_apply_uid
    call users_sync_tcb0                ; 主 shell 线程的 TCB 也跟上(它可能不在表里跑)
    mov esi, msg_su_ok
    call term_print
    mov esi, [login_name]
    call term_print
    mov esi, msg_uid_eq
    call term_print
    mov eax, [login_uid]
    call term_print_dec
    mov esi, msg_close
    call term_print
    jmp .out
.nouser:
    mov esi, msg_su_nouser
    call term_print
    jmp .out
.usage:
    mov esi, msg_su_usage
    call term_print
.out:
    popad
    ret

; ---------------------------------------------------------------------------
;  users_sync_tcb0:把当前线程的 TCB 也刷成登录身份
;    (users_apply_uid 扫的是 tcb_table,正常情况下已经覆盖;这里再保险一次)
; ---------------------------------------------------------------------------
users_sync_tcb0:
    push eax
    push edx
    call process_cur_tcb
    mov edx, [login_uid]
    mov [eax + TCB_UID], edx
    mov edx, [login_gid]
    mov [eax + TCB_GID], edx
    pop edx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  shell 命令:login —— 重新登录(退到登录提示再走一遍)
; ---------------------------------------------------------------------------
; ---- 命令名(给 shell.asm 的命令表引用)----
n_whoami        db 'whoami', 0
n_su            db 'su', 0
n_login         db 'login', 0

cmd_login:
    pushad
    mov al, 10
    call term_putc
    mov dword [ul_tries], 0
    call users_login
    popad
    ret

; ===========================================================================
;  用户表(3 个内置用户)
; ===========================================================================
users_tab:
u_super:
    db 'super', 0
    times 10 db 0
    dd 0                                ; uid
    dd 0                                ; gid
    dd u_super_pw
    dd u_alias_root
    dd u_alias_system_upper
u_system:
    db 'system', 0
    times 9 db 0
    dd 1
    dd 1
    dd u_system_pw
    dd 0
    dd 0
u_user:
    db 'user', 0
    times 11 db 0
    dd 2
    dd 2
    dd u_user_pw
    dd 0
    dd 0
users_tab_end:

u_super_pw          db 'root', 0
u_system_pw         db 'system', 0
u_user_pw           db 0
u_alias_root        db 'root', 0
u_alias_system_upper db 'SYSTEM', 0
ul_name_user        db 'user', 0

; ---- 登录状态(users_apply_uid / fork / shell_spawn_extra 都从这里取)----
login_uid       dd 0                    ; 软盘启动默认 super
login_gid       dd 0
login_name      dd u_super              ; 指向表项名字段

ul_tries        dd 0
ul_entry        dd 0
ul_name_buf     times 32 db 0
ul_pw_buf       times 32 db 0

; ---- 提示文案 ----
msg_login           db 'login: ', 0
msg_password        db 'Password: ', 0
msg_login_bad_user  db 'login incorrect', 10, 0
msg_login_bad_pw    db 'Login incorrect', 10, 0
msg_login_fallback  db 'login: too many attempts, falling back to user', 10, 0
msg_welcome         db 'Welcome, ', 0
msg_uid_eq          db ' (uid=', 0
msg_close           db ')', 10, 0
msg_whoami          db 'whoami: ', 0
msg_su_deny         db 'su: permission denied: need super', 13, 10, 0
msg_su_nouser       db 'su: no such user', 13, 10, 0
msg_su_ok           db 'su: now ', 0
msg_su_usage        db 'su: usage: su <user>', 13, 10, 0
