[简体中文](zh-CN/c-programs.md)

# Writing KKernel Programs in C

**No cross compiler needed — plain `gcc` will do.** Programs are compiled into flat binaries, put
into the FAT16 partition, and started from the shell with `run XXX` — exactly the same as the
`progs/*.asm` route, only in a different language.

```c
#include <stdio.h>
#include <kkernel.h>

int main(void)
{
    j_color(KK_LCYAN);
    printf("hello from C, screen is %d cols\n", j_screensize(NULL));
    return 0;
}
```

```bash
make                 # builds progs/*.c automatically (needs gcc's 32-bit support)
make cc-check        # check whether the C toolchain is there
make hd              # once booted: run CHELLO
```

On machines **without 32-bit support**, `make` **skips** the C programs and prints
`sudo apt install gcc-multilib`, while the assembly part builds as usual — nobody cloning this gets
stuck.

---

## 1. How the pieces fit together

| File | What it does |
|---|---|
| `include/kkernel.h` | C wrappers for the 14 `int 0x30` functions (static inline assembly) + color/key constants |
| `lib/crt0.asm` | Entry point: `_start` → clear BSS → `main()` → `ret` back to the shell; plus the trampoline used by `exit()` |
| `lib/minic.c` | Mini libc: string / ctype / malloc / printf / a little stdio (~600 lines) |
| `lib/minic.h` | Declarations for the above (and the real contents of our own `<stdio.h>` and friends) |
| `include/*.h` | Thin shims: so that old-style `#include <stdio.h>` hits our implementation |
| `lib/kkernel.ld` | Linker script: place at 0x120000, output a flat binary, and hand out the BSS boundary symbols |
| `progs/*.c` | Your C programs |

The compile commands (already written in the Makefile; shown here so humans can follow along):

```bash
gcc -m32 -std=gnu89 -ffreestanding -fno-pic -fno-stack-protector \
    -fno-asynchronous-unwind-tables -fno-builtin -nostdlib -O2 \
    -Iinclude -Ilib -c progs/Foo.c -o build/Foo.o
ld -m elf_i386 -T lib/kkernel.ld build/crt0.o build/Foo.o build/minic.o -o build/Foo.BIN
```

Every flag has a reason:

* `-m32`: KKernel is 32-bit x86, so programs must be 32-bit code;
* `-ffreestanding -nostdlib`: there's no libc on bare metal, so don't link glibc (it wouldn't start
  even if you did);
* `-fno-pic`: `int 0x30` passes arguments in `ebx`, and position-independent code uses `ebx` as the
  GOT pointer;
* `-fno-stack-protector -fno-asynchronous-unwind-tables`: `__stack_chk_*` and `.eh_frame` are
  libc/runtime things; bring them along and the link fails;
* `-fno-builtin`: don't replace `memcpy` and friends with compiler-inlined versions (ours are
  simpler);
* `-std=gnu89`: old C code (the STEVIE kind) doesn't build with gcc 14 by default; gnu89 is the
  least hassle.

## 2. Program conventions

```
0x120000            program is read here by the shell (this is also the link address)   ← virtual address
0x120000..0x17FFFF  image window (96 pages, 384 KiB; code + read-only data + initialized data)
0x180000..heap top-1  heap (malloc carves from here; size depends on machine memory / where the font is, about 2.1 MB by default,
                     exact boundary via j_heap_end(); the two pages below the heap top are the argument page and the user stack)
(font: at runtime it lives in a slot at ident-2 MiB on top of the identity map; on a default 128 MiB machine that's 0x7A00000 upwards)
```

* **Both regions are now "per-program private pages", and handed out only on demand**: the kernel
  builds the page tables, but not a single page of the image window or the heap window (96 + 560
  pages by default) is mapped in advance — whichever page your code/data touches first, the page
  fault handler grabs a page from the physical page pool, zeroes it, fills in the table (then
  re-executes that instruction, so you never notice). On exit the pages go back to the pool along
  with the page tables. So the virtual addresses are the same as when you wrote the code, but where
  they land physically is different every run (to see how many pages you touched, run `run TOUCH`,
  or look at the last line of `run FOO`: `demand paging: N page(s) faulted in (image x + heap y)`);
* images larger than 384 KiB are rejected by `run` (that's all the private image window is).

* **Entry point**: `_start` in `lib/crt0.asm` (selected by the linker script's `ENTRY(_start)`).
  It clears BSS and then calls `main()`, so just write `int main(void)` — **do not** write your own
  `_start`;
* **Return**: when `main` returns (or `exit()` is called) you're back in the shell. There are no
  processes and no return-value semantics; the exit code is only useful for debugging;
* **Arguments**: `int main(int argc, char **argv)` **doesn't work** — there is no argv. Use
  `const char *arg = j_arg();` (that's the string from `run FOO args`);
* **BSS**: a flat binary doesn't store "all-zero sections", so crt0 clears it; and the pages faulted
  in on demand are already clean zero pages (the part beyond the image file isn't even copied) —
  belt and braces, so "global arrays are zero by default" holds.

## 3. What the mini libc has and doesn't have

**Has**: `strlen/strcpy/strncpy/strcat/strcmp/strncmp/strchr/strrchr/strcspn/memcpy/memmove/memset`,
`is*/to*`, `malloc/calloc/realloc/free` (first fit + adjacent coalescing),
`printf/fprintf/sprintf/snprintf` (`%d %i %u %x %X %o %c %s %p %%`, with width/precision/`-`/`0`/`+`/`#`),
`fopen/fclose/fgets/fgetc/fputc/fputs/puts/fflush`, `remove/rename/access`, `atoi/abs/exit/system/getenv`.

**Doesn't have**: floating-point formatting (`%f`), `scanf`, directory traversal, `time`, signals,
threads, `qsort`, locale/wide characters.

**Where it differs from POSIX** (important):

* The file model is "**read it all, write it all**": `fopen("r")` reads the whole file into memory
  (64 KB max), `fopen("w")` accumulates in memory and writes to disk once at `fclose`. No seek and
  rewrite, no append;
* `remove()` always returns -1: the kernel interface has **no file deletion** (see
  [known-issues.md](known-issues.md));
* `rename()` is "read it out + write it under the new name"; the old file stays;
* `system()` just prints "no shell escape" — there are no processes in this system;
* `getenv()` always returns NULL (old code has to supply its own defaults).

## 4. Example: `progs/CHELLO.c`

It tries everything that works: the various printf formats, malloc/free to see how much heap is
left, the 16 colors, getting the argument, using the argument as a filename and counting
lines/bytes. Run:

```
> run CHELLO
> run CHELLO DOCS/README.TXT
```

You'll see it in `ls`: `CHELLO.BIN`, 8888 bytes — roughly 6 KB of that is the mini libc and crt0,
so "every C program carries its own copy of libc" isn't really wasteful (it's read from disk
anyway).

## 5. Ready-made examples: the C programs in `progs/` and STEVIE

* `progs/CHELLO.c`: printf / malloc / arguments / reading files — a workout for everything that's
  available;
* `extensions/vi/`: **STEVIE 3.68 — a public-domain vi clone (vim's ancestor)**, ported over
  wholesale:

```bash
make hd
> run vi DOCS/NOTES.TXT      # open the editor (:w saves, :q quits, i enters insert mode, ESC back to normal)
```

Its "machine-dependent layer" used to be called `nt.c` (the Windows NT version); now it's our own
`extensions/vi/kkernel.c`: the screen goes through `int 0x30` functions 9/13 (position + draw text
at a position), the keyboard through 10 (arrow keys map straight onto STEVIE's `K_UARROW` key
codes), files through 7/8. The editor core (~10,900 lines) was not changed at all — which says
quite a lot about how easy code with a clean platform layer is to port.

The platform layer only has to provide this much:

```
windinit / windexit / windgoto(row,col) / wchangescreen   screen
outchar / outstr / flushbuf                                draw characters
inchar                                                     get a key
fopenb / fixname                                           files and filenames
beep / delay / sleep / sig / dochdir / mysystem / doshell   misc (mostly empty stubs)
```

**A pitfall I hit for real**: in the NT version `fixname` is `fixname(char *s)` — one argument,
returns a static buffer — and my first version wrote it as "three arguments, writes into the
caller's buffer". `stevie.h` has the old-style declaration `char *fixname();`, and **the compiler
says nothing when the argument count is wrong**, so saving produced an empty filename: vi reported
"save successful", while the disk got a directory entry whose name was all spaces. Lesson: when
porting a platform function from old code, look at the original implementation first; don't
freelance off the signature you assume.
