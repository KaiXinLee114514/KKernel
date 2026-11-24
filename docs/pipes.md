[简体中文](zh-CN/pipes.md)

# Pipes

KKernel's shell supports pipes of the form `A | B`: **sequential execution**, no concurrency needed. While A runs, its screen output is captured by the kernel into a buffer borrowed from the physical page pool; when A finishes, the bytes in the buffer become stdin for B (and any later stages). So unlike a Linux pipe, where "two processes run at the same time", this is "run one, then the next" — in exchange, there's almost no concurrency/blocking logic in the kernel.

```
> cat DOCS/README.TXT | run WC
54 lines 254 words 3241 bytes
> ls BIN | run GREP HELLO
HELLO.BIN 249 bytes
CHELLO.BIN 18536 bytes
> help | echo hi
hi
```

## Syntax

- Commands are separated by `|`, at most **4 stages**; each stage can be a shell built-in (echo/cat/ls/help...) or `run program args`.
- Leading spaces are skipped and trailing spaces trimmed. An empty stage (e.g. `h1 | | h2`) reports `pipe: empty command in the pipeline`; more than 4 stages reports `pipe: too many stages (max 4)`.
- The last stage's output goes to the screen as usual; intermediate stages' output is captured and fed to the next stage.
- If captured output exceeds the buffer capacity it is truncated and, when the whole pipeline finishes, one line is printed: `pipe: output truncated (buffer full)`.

## Where the Buffer Comes From

When executing a pipeline the kernel borrows buffers from the physical page pool with `pmem_alloc_pages`:

- 2 stages (1 intermediate buffer): try **16 pages (64 KB)** first, then 4 pages (16 KB), then 1 page (4 KB);
- 3 or more stages need two buffers used alternately (stage 1's output to stage 2, stage 2's output to stage 3); both are requested in the same order as above;
- If the page pool is too small it reports `pipe: not enough pages for a pipe buffer` and the whole pipeline is not executed.

Buffers are returned immediately with `pmem_free_pages` when the pipeline finishes, so nothing stays resident. That means small-memory runs like `-m 16` still work (8 MB page pool, borrowing 64 KB is no big deal), while `-m 8` has no page pool and pipes error out immediately.

## How Programs Read stdin

The program on the right side of the pipe uses **int 0x30 function 17**:

```c
/* Read at most max bytes from the pipe/stdin; returns the number of bytes
   actually read, 0 = nothing left */
static inline int j_pipe_read(void *buf, int max)
{
    int r;
    asm volatile("int $0x30" : "=a"(r)
                 : "a"(17), "D"(buf), "c"(max)
                 : "ebx", "edx", "esi", "memory");
    return r;
}
```

With no pipe input (plain `run WC` from the command line) it returns 0 immediately, and the program prints a hint and exits normally. `include/kkernel.h` has `j_pipe_read` ready to use.

## Bundled Pipe Tools

Four small C programs, sources in `progs/`, built into `/BIN` automatically:

| Program | Usage | Description |
|---|---|---|
| `WC` | `run WC` | count lines/words/bytes on stdin: `54 lines 254 words 3241 bytes` |
| `UPPER` | `run UPPER` | upper-case all of stdin |
| `GREP` | `run GREP <substring>` | print only lines containing the substring (substring match, case-sensitive) |
| `HEAD` | `run HEAD [lines]` | print the first N lines (default 10) |

Examples:

```
> cat DOCS/README.TXT | run UPPER | run HEAD 3
> cat DOCS/README.TXT | run GREP the | run WC
> ls BIN | run HEAD 5
```

## Implementation (Kernel Side)

- `kernel/pipe.asm`:
  - capture state `pipe_capture_on` + `pipe_out_begin/pipe_out_end`/`pipe_in_set`/`pipe_reset`;
  - `pipe_capture_byte/pipe_capture_str/pipe_capture_cp` write terminal output into the buffer (without printing to screen);
  - `pipe_read` is what int 0x30 function 17 calls; it copies bytes by position out of the "current stdin buffer".
- `kernel/kmain.asm`: `term_putc` / `term_print` check `pipe_capture_on` on entry and route content into the buffer while capturing;
- `kernel/api.asm`: function 17 → `pipe_read`; API3 (print code point) also goes through capture;
- `kernel/shell.asm`: `shell_execute` scans the current line for `|` on entry; if present, `shell_pipe_execute`: split stages → borrow buffers → set capture/input per stage → `call shell_execute_plain` (the original command dispatch) → free buffers at the end; log messages from stage programs (running/space/teardown) are muted via `pipe_active`.
- Full-screen UIs write video memory / position the cursor directly (`term_puts_at`, `fb_putcp_at`) and bypass the capture points, so full-screen programs such as CALC/EDIT/VI are not suitable inside a pipe.

## The Gap Versus Linux

Linux's pipe is a pile of "two processes alive at once" service logic: ring buffer pages, read/write blocking and wakeups, SIGPIPE, file-descriptor lifetimes, splice and so on. KKernel runs one program at a time, so sequential pipes cover most text-filtering scenarios; real concurrency (read while writing, streaming large files) needs the scheduler to run multiple ring-3 tasks, per-task address spaces and blocking primitives first — that's the next step.

## Traps We Hit

- The first version of the executor kept the "stage number" in `ebx` across the `shell_execute_plain` call — but shell command dispatch and kernel print functions use registers freely, so the stage number got clobbered and the loop exited immediately (symptom: "the pipe produces no output at all"). The fix was to keep the stage number, previous buffer and length in memory (`pipe_stage_idx` etc.) and reload them at each step.
- `term_putc`/`term_print_dec` also clobber `ebx` — you can't use registers as state around debug prints.
- The capture buffer has no automatic `\0` appended, so tools must read bytes according to the return value rather than treating it as a C string.
