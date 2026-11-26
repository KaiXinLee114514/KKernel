[简体中文](zh-CN/posix.md)

# POSIX Translation Layer (int 0x80)

KKernel can run existing **Linux i386 static executables** through an `int 0x80`
translation layer. The native `int 0x30` program API is untouched — the two
interfaces are independent:

| Interface | Used by | Entry | Register convention |
|---|---|---|---|
| `int 0x30` | KKernel native flat binaries | kernel `api.asm` | `eax` = function number |
| `int 0x80` | Linux i386 ELF programs | kernel `posix.asm` | `eax` = syscall number (Linux ABI) |

## Why a translation layer

The final goal is to run off-the-shelf **static busybox** applets. Writing a
full Linux kernel is out of scope, but most of the user-visible functionality
is already in the kernel (console, FAT filesystem, processes, memory); the
`int 0x80` layer only has to translate the Linux register ABI to those kernel
capabilities.

## Linux i386 ABI (as implemented)

- Entry: IDT vector `0x80`, DPL = 3 (callable from ring 3).
- Arguments: `eax` = syscall number, then `ebx`, `ecx`, `edx`, `esi`, `edi`,
  `ebp` = arguments in the usual Linux order.
- Return: `eax` = result; on error a **negative** value (`-errno`).
- **All registers except `eax` are preserved** across the call — Linux
  programs (and libc) rely on this.
- Unknown syscall number: `eax = -ENOSYS` (`-38`).

## P1: minimal closed loop (done)

| # | Syscall | Signature | P1 behaviour |
|---|---|---|---|
| 1 | `exit` | `exit(code)` | terminate the calling process, code passed to the parent `wait` |
| 3 | `read` | `read(fd, buf, count)` | only `fd 0` (keyboard), returns 1; background processes get `0` (EOF) |
| 4 | `write` | `write(fd, buf, count)` | `fd 1`/`fd 2` → console; other fds → `-EBADF` (`-9`) |

Implementation notes:

- `kernel/posix.asm` installs the `int 0x80` gate and dispatches syscalls.
  The dispatch frame uses the same "save everything, write only `eax` back"
  pattern as the native `int 0x30` stub, so register-preservation comes for
  free.
- `sys_write` feeds bytes through the normal terminal layer (`term_putc`), so
  output is identical to a native program (and works in both the VBE graphics
  console and the VGA text fallback).
- `sys_exit` reuses the existing process-exit path: a child process becomes a
  zombie for its parent; a program started directly by the shell returns to
  the shell prompt.

## Testing (P1)

- Test program: [`tools/posix/p1_hello.asm`](../tools/posix/p1_hello.asm) —
  a bare-metal i386 ELF (no libc) that calls
  `write(1, "hello from int 0x80\n", 20)` then `exit(0)`.
  Built with `nasm -f elf32` and `ld -m elf_i386 -static -n -Ttext=0x120000`.
  (`-Ttext=0x120000`: the kernel ELF loader expands programs into its program
  window at 0x120000; `-n` keeps the linker from emitting an extra `PT_LOAD`
  segment below the base address.)
- `make test-posix` boots the hard-disk image, runs
  `run TEST/P1_HELLO.ELF`, and asserts: the `hello` string appears, the shell
  prompt comes back, and the page pool does not leak.

## Roadmap

| Phase | Content | Status |
|---|---|---|
| P1 | `exit` / `read` / `write` | done |
| P2 | `open` / `close` / `lseek` / file read/write, `brk` | planned |
| P3 | `stat` / `fstat` / `getdents` / `ioctl` / time syscalls | planned |
| P4 | `fork` / `execve` / `wait4` / `getpid` / `kill` | planned (evaluate first) |
| P5 | static i386 busybox applet subset | planned (evaluate first) |

## Known limitations (P1)

- `read` reads one byte at a time and only from `fd 0`; no line discipline,
  no termios.
- No file descriptors beyond 0/1/2 yet — file syscalls arrive in P2.
- Programs must be statically linked i386 ELFs. No dynamic linker, no
  `mmap`, no threads.
- The translation layer lives next to, not on top of, the native API; a
  program must pick one ABI (mixing both is undefined).
