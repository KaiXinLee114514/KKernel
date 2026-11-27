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

## P2: files and memory (done)

| # | Syscall | Signature | P2 behaviour |
|---|---|---|---|
| 5 | `open` | `open(path, flags, mode)` | opens an **existing** FAT file; `flags` low 2 bits = 0/1/2 (read/write); other bits (e.g. `O_CREAT`) → `-ENOSYS`; path resolved from the FAT root (no per-process cwd); max path 39 chars |
| 6 | `close` | `close(fd)` | fds 0/1/2 always succeed; 3+ frees the slot |
| 19 | `lseek` | `lseek(fd, offset, whence)` | `SEEK_SET`/`SEEK_CUR`/`SEEK_END`; offset must stay inside 0..8 KiB; fds 0/1/2 → `-ESPIPE` |
| 3 | `read` | `read(fd, buf, count)` | fd 0 = keyboard (as before); fd 3+ = file: reads up to `count` bytes from the current offset, advances the offset |
| 4 | `write` | `write(fd, buf, count)` | fd 1/2 = console; fd 3+ = **whole-file overwrite**: old content is read into a scratch buffer, the requested range is replaced, and the file is written back in one go |
| 45 | `brk` | `brk(addr)` | program heap: `addr = 0` returns the current break; a valid `addr` moves it and returns the new value; out of range returns the old value |

Implementation notes:

- The file-descriptor table is **global** (8 file slots, fds 3..10) and is
  protected by the existing `fs_lock` mutex. It is cleared in
  `process_exec`, so a newly started program never inherits stale fds.
- `open` reuses the FAT helpers (`fat_path` / `fat_stat` / `fat_read_file` /
  `fat_write_file`) with `fs_lock` held and the FAT current directory
  temporarily reset to the root.
- File data flows through one global 8 KiB scratch buffer, so the whole file
  is read/modified/written for every call. Simple and correct for small
  files; not a POSIX-grade page cache.
- `brk` only tracks the break in the TCB (`TCB_POSIX_BRK`); actual pages are
  demand-paged zero pages from the program heap window
  (`SPACE_HEAP_VA` = 0x180000), so the first write to a new page just works.
- Error codes used: `-EBADF` (bad fd), `-ENOENT` (no such file),
  `-EINVAL` (bad argument / too large), `-EMFILE` (fd table full),
  `-ENOSPC` (file would exceed scratch), `-ESPIPE` (seek on a pipe),
  `-EIO` (FAT I/O error), `-ENOSYS` (unsupported).

## P3: file metadata, directories and time (done)

| # | Syscall | Signature | P3 behaviour |
|---|---|---|---|
| 106 | `stat` | `stat(path, buf)` | fills an i386 `struct stat` (64 bytes): `st_mode`, `st_size`, `st_mtime`, ...; directories and the root `"/"` are supported |
| 107 | `lstat` | `lstat(path, buf)` | identical to `stat` (FAT has no symlinks) |
| 108 | `fstat` | `fstat(fd, buf)` | fds 0/1/2 → `S_IFCHR`; file fds from the fd table; directory fds → `S_IFDIR` |
| 220 | `getdents64` | `getdents64(fd, buf, count)` | iterates FAT directory entries as `linux_dirent64` records; the entry index cookie lives in the fd slot |
| 54 | `ioctl` | `ioctl(fd, req, arg)` | only `TCGETS` (0x5401) on fds 0/1/2 → zeroed 36-byte termios and 0; anything else → `-ENOTTY` |
| 13 | `time` | `time(tloc)` | CMOS RTC → Unix timestamp (local time, no timezone); also stores into `*tloc` when non-NULL |
| 78 | `gettimeofday` | `gettimeofday(tv, tz)` | `tv = {sec, usec}`; `usec` is derived from the 100 Hz PIT ticks |

Implementation notes:

- **Directory descriptors**: `open()` on a directory succeeds read-only and
  marks the fd with `PFD_DIR`; `read`/`write`/`lseek` on it return `-EISDIR`.
  The directory first cluster is stored in the fd slot, and `PFD_OFF` doubles
  as the `getdents64` cookie (index of the next entry).
- `getdents64` uses two new FAT helpers: `fat_dir_open` (resolve a path to a
  directory first cluster) and `fat_dirent` (fetch the N-th directory entry,
  skipping deleted entries, LFN entries and `.`/`..`). Names are returned in
  **8.3 form** — long file names appear via their short aliases. Records are
  `d_ino/d_off/d_reclen/d_type/d_name`, 8-byte aligned; `d_type` is 4
  (DT_DIR) or 8 (DT_REG).
- `struct stat` uses the i386 layout (64 bytes): `st_dev` 0, `st_ino` 4,
  `st_mode` 8, `st_nlink` 10, `st_uid` 12, `st_gid` 14, `st_rdev` 16,
  `st_size` 20, `st_blksize` 24, `st_blocks` 28, `st_atime` 32, `st_mtime` 40,
  `st_ctime` 48. All timestamps are the current RTC time; `st_mode` is 0644
  for files, 0755 for directories, 0620 for the console character device.
- `time`/`gettimeofday` convert the RTC date to a Unix timestamp using the
  standard leap-year rules. There is no timezone support (CMOS local time is
  treated as UTC). `gettimeofday.tv_usec` is `(ticks % 10) * 10000`.
- Error codes added in P3: `-EISDIR` (directory used as a file),
  `-ENOTDIR`, `-ENOTTY`.

## P4: processes (in progress — P4a done)

P4 is staged: **P4a** (fork/getpid/wait4) is done; **P4b** (kill) and **P4c**
(execve) follow. Processes are implemented on top of the native kernel
process layer (`fork` with copy-on-write address spaces, wait/reap, signals).

| # | Syscall | Signature | P4 behaviour |
|---|---|---|---|
| 2 | `fork` | `fork()` | copies the current process (copy-on-write window pages, own guard page, shared image staging); **child returns 0, parent returns the child pid**, failure `-EAGAIN` |
| 20 | `getpid` | `getpid()` | → pid of the calling process (pid = TCB slot + 1) |
| 114 | `wait4` | `wait4(pid, status*, options, rusage)` | waits for a child; `options` recognised: `WNOHANG` (1) and `WUNTRACED` (2); `pid` supports `> 0` and `-1` (any child); returns child pid, `0` for WNOHANG-with-no-event, `-ECHILD` when there is no child, `-ENOSYS` for the other pid forms. `*status` uses the Linux encoding: normal exit `(exitcode & 0xFF) << 8`, stopped `0x7F` |

Implementation notes:

- `fork` reuses `process_fork`: the kernel-side interrupt frame is copied into the
  child's fresh kernel stack, so the child resumes exactly like the parent a moment
  after `int 0x80`, with `eax = 0`. The parent-child link is recorded in the TCB, so
  `wait4` reaps only own children.
- `wait4` maps Linux option bits onto the kernel's wait flags and reads the event
  details (status/pid/exit code) from the **calling thread's own TCB**, so two
  processes waiting concurrently cannot clobber each other's result.
- The POSIX brk pointer (`TCB_POSIX_BRK`) is inherited by fork (parent and child keep
  the same break value).
- FD inheritance is deliberately not implemented in P4: the POSIX fd table is a
  **single global table** (not per-process), so a forked child shares it with the
  parent, and `execve` clears it (see known limitations).

## Testing (P1 + P2 + P3 + P4a)

- P1: [`tools/posix/p1_hello.asm`](../tools/posix/p1_hello.asm) — bare-metal
  i386 ELF that calls `write(1, "hello from int 0x80\n", 20)` then `exit(0)`.
- P2: [`tools/posix/p2_file.asm`](../tools/posix/p2_file.asm) — `brk` buffer,
  `open`/`read`/`write`/`lseek`/`close` on `TEST/P2_DATA.TXT`, prints
  `p2-file: p2 data ok` then `p2-file: done`; and
  [`tools/posix/p2_brk.asm`](../tools/posix/p2_brk.asm) — `brk` three new heap
  pages, writes and verifies a dword pattern, prints `p2-brk: ok`.
- P3: [`tools/posix/p3_stat.asm`](../tools/posix/p3_stat.asm) — `stat` on a
  file and on a directory (checks `st_size` / `st_mode` type bits), missing
  file → `-ENOENT`, `open`+`fstat` on a file and on the console, plus
  `ioctl(TCGETS)` on the console / `-ENOTTY` on a file fd; prints
  `p3-stat: ok`.
  [`tools/posix/p3_dents.asm`](../tools/posix/p3_dents.asm) — opens `TEST/`
  as a directory fd, checks `read` → `-EISDIR` and `open` with write flags →
  `-EISDIR`, then loops `getdents64` over `TEST/` checking that at least three
  entries are returned and that `P2_DATA.TXT` is among them; prints
  `p3-dents: ok`.
  [`tools/posix/p3_time.asm`](../tools/posix/p3_time.asm) — `time(0)` > 0,
  `time(&t)` matches and is monotonic after a short wait, `gettimeofday`
  returns a plausible `{sec, usec}`; prints `p3-time: ok`.
- Built with `nasm -f elf32` and `ld -m elf_i386 -static -n -Ttext=0x120000`.
  (`-Ttext=0x120000`: the kernel ELF loader expands programs into its program
  window at 0x120000; `-n` keeps the linker from emitting an extra `PT_LOAD`
  segment below the base address.)
- `make test-posix` boots the hard-disk image, runs the P1/P2 programs, and
  asserts: the expected strings appear, the shell prompt comes back after each
  program, and the page pool does not leak.
- P4a: [`tools/posix/p4_fork.asm`](../tools/posix/p4_fork.asm) —— `getpid`,
  `fork` and `wait4`: the child prints `p4-fork: child` and exits with 42, the parent
  waits, checks the exit status and prints `p4-fork: ok`; it also verifies `getpid`
  did not change across fork/wait.
- `make test-posix` starts the hard-disk image and runs all P1–P4a programs,
  asserting the output strings, return to the shell after each program and that
  the page pool does not leak.

## Roadmap

| Phase | Content | Status |
|---|---|---|
| P1 | `exit` / `read` / `write` | done |
| P2 | `open` / `close` / `lseek` / file read/write, `brk` | done |
| P3 | `stat` / `fstat` / `getdents64` / `ioctl` / `time` / `gettimeofday` | done |
| P4 | `fork` / `execve` / `wait4` / `getpid` / `kill` | in progress: P4a (fork/getpid/wait4) done; P4b (kill) and P4c (execve) next |
| P5 | static i386 busybox applet subset | planned (evaluate first) |

## Known limitations (P1 + P2 + P3 + P4a)

- `read` on fd 0 reads one byte at a time; no line discipline, no termios.
- The fd table is global (not per-process): a forked child shares its parent's
  file descriptors; `execve` clears them (FD inheritance is deliberately not
  implemented in P4).
- `open` never creates or truncates files (`O_CREAT` etc. → `-ENOSYS`);
  `write` is a whole-file overwrite, not an in-place update.
- Files are limited to 8 KiB (single scratch buffer).
- File paths are resolved from the FAT root; there is no per-process cwd.
- `brk` only grows inside the pre-computed heap window of the process.
- `getdents64` returns FAT **8.3 short names only** (long names via their
  short aliases), and skips `.`/`..`. No `readdir` of long names yet.
- `stat` reports synthetic metadata: uid/gid both 0, no real permission bits
  (files 0644, directories 0755), and all timestamps are the current time.
- `time`/`gettimeofday` treat the CMOS local time as UTC; no timezone,
  no sub-second RTC precision (usec comes from PIT ticks).
- Open directories are read-only; there is no `open` flag support beyond
  access mode (no `O_DIRECTORY`, `O_NONBLOCK`, ...).
