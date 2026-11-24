[简体中文](zh-CN/hacking.md)

# Hacking (how to make changes)

> Originally README §8.

After a change, run `make`, then `./tools/run.sh --hd` to see the result.

## 8.1 Add a program of your own (most recommended)

```bash
cp progs/HELLO.asm progs/MYPROG.asm     # hack away
make                                    # the Makefile builds progs/*.asm automatically
python3 tools/mkfat.py build/kkernel-hd.img 6144 8 MYPROG.BIN=build/MYPROG.BIN
make hd                                 # or add a line to PROGS in the Makefile so make hd includes it
> run MYPROG
```

Interfaces, conventions and examples are all in **[docs/programs.md](programs.md)**.

## 8.2 Write a full-screen program (this is how the calculator/editor came about)

For a program that "clears the screen and lays itself out", use functions 6/9/10/11/12/13:
clear the screen, position the cursor, read key events (arrow keys), ask for the screen size, fetch
arguments, draw text at a given position. `progs/CALC.asm` (300 lines) and `progs/EDIT.asm`
(400 lines) were written exactly this way, and the three lessons learned are in section 6 of
[docs/programs.md](programs.md).

## 8.3 Change the boot message

In the data area at the bottom of `kernel/kmain.asm`, `msg_title` is the first line:

```asm
msg_title   db 'KKernel - stage 5', 10, 0     ; 10 = newline, 0 = end of string
```

Chinese works there too (the string is UTF-8 and displays in graphics mode; in text mode it turns
into mojibake, see 6.8).

## 8.4 Add a shell command

Three places, all in `kernel/shell.asm`:

```asm
; 1) write the handler (use term_print to print, [cmd_arg] to read arguments)
cmd_hi:
    mov esi, msg_hi
    call term_print
    ret

msg_hi db 'hi there', 10, 0                 ; 2) add the string

; 3) register it in the command table (name + handler)
n_hi db 'hi', 0
cmd_table:
    dd n_hi, cmd_hi
    ...
```

Command-name matching is a **whole-word** comparison (`str_eq`), so `page` won't be caught by `pa` or
the like.

## 8.5 Put a file into the image

```bash
python3 tools/mkfat.py build/kkernel-hd.img 6144 8 \
    DOCS/NOTES.TXT=my-notes.txt BIN/HELLO.BIN=build/HELLO.BIN
make hd
> cat DOCS/NOTES.TXT
```

For what the arguments mean, why 6144, and how the sectors per cluster are chosen, see section 6 of
[docs/filesystem.md](filesystem.md).

## 8.6 Change how paging maps things

The two page tables at the top of `kernel/paging.asm` are **fixed at boot**; identity mapping covers
0~ident (up to 256 MiB), and page-table pages above 4 MiB are taken from the page pool at run time:

```asm
PD_ADDR     equ 0x1000     ; page directory
PT_LOW      equ 0x2000     ; identity 0-4 MiB
PT_LFB      equ 0x4000     ; VBE framebuffer window
; identity page tables above 4 MiB: no fixed address, pmem_alloc grabs a page at a time at run time
```

To play with "virtual address ≠ physical address" you don't have to change any code; the shell has it
ready-made:

```
> debug pmap 0x8000000     ← take a page from the pool (above 4 MiB) and build a page table mapping it at virtual 128 MiB
> debug page 0x8000000     ← look at the PDE/PTE: virtual 0x08000000, physical 0x00400000
> debug pumap 0x8000000    ← unmap and give the page back
> debug ptest        ← one command runs the whole cycle (alloc → build tables → read/write → return) and also checks the pool for leaks
```

To add a "fixed custom mapping", write it at the end of `paging_init` following the LFB block;
`paging_map(va, pa, flags)` and `paging_unmap(va)` are the dynamic interfaces in the kernel
(`kernel/paging.asm`; if the page tables run short it asks `pmem_alloc` for pages itself). To make a
mapping "mapped but not writable", drop `PAGE_RW` from the flags and writing to it takes general
protection exception 13.

To change "how much memory a program can use", look at `SPACE_IMG_PAGES` / `SPACE_HEAP_PAGES` at the
top of `paging.asm` — the image window is a constant 96 pages, the heap-window page count is the
runtime variable `space_heap_pages` (the argument page / stack top `space_args_va` / `space_stack_va`
/ `space_user_stack_top` are computed at run time too), and creating a space hands out no pages at
all: pages are faulted in when the program touches them. To see how that works, start from
`page_fault_try_handle`; to turn demand paging off and go back to "give it all up front", replace the
page-table-clearing lines in `space_create` with `paging_map` calls mapping page by page (that's how
the old version did it; it's in the git history). The steps in `cmd_run` are easy to spot: create the
space → write the image size → switch CR3 and run → `space_destroy` to give it back.

## 8.7 Make the panic screen show more

`isr_common` in `kernel/idt.asm` is that "red screen + halt". Everything in the exception frame is on
the stack:

```
[ebp+32]=vector  [ebp+36]=error code  [ebp+40]=EIP  [ebp+44]=CS  [ebp+48]=EFLAGS
```

To print `CR3`, `DS` or page-table entries as well, add a line following
`mov eax, cr2 / call term_print_hex`.

## 8.8 Write programs in C

Run `make cc-check` to see whether the toolchain is there, then drop a `.c` into `progs/`, add the
name to `C_PROGS` in the `Makefile`, and `make hd`. Interfaces, memory layout, and what mini-libc
does and doesn't have are all in [docs/c-programs.md](c-programs.md); `progs/CHELLO.c` is a
ready-made example.

## 8.9 See what the assembly actually assembled into

```bash
make lst        # produces build/boot.lst and build/kernel.lst (disassembly with machine code)
qemu ... -s -S  # with gdb: target remote :1234 (or ./tools/run.sh --gdb)
```

## 8.10 Pushing to GitHub (the network in China comes and goes)

When a manual `git push` runs into one of GitHub's bad days, you just have to sit and wait. Use the
ready-made script:

```bash
tools/onekey_push.sh --dry-run                       # see what would be pushed first
GH_TOKEN=ghp_xxx tools/onekey_push.sh                # push with a PAT (retries automatically on failure)
tools/onekey_push.sh                                 # push directly when credential.helper / SSH is set up
tools/onekey_push.sh --branch dev --retry 8 --sleep 15
```

The token is read only from the `GH_TOKEN` environment variable; it is **never written to config and
never touches disk**. For long-term password-free pushes you can
`git config --global credential.helper store` (stores `~/.git-credentials` in plain text), or just
copy the token into the environment variable each time.
