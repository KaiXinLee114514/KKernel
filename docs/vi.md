[简体中文](zh-CN/vi.md)

# Putting vi inside KKernel: the STEVIE port story

`run VI DOCS/NOTES.TXT` — the vi running in this KKernel isn't something we wrote from scratch; it's
a port of a **public-domain** vi clone. This page explains which one it is, why we picked it, what we
changed (and what we **didn't**), and which traps we hit.

---

## 1. Which one: STEVIE 3.68

While digging through the Windows XP SP1 source, there was an editor's source sitting under
`NT/sdktools/vi`. The interesting part is that **Microsoft didn't write it** — it's **STEVIE
(STEVIE 3.68)**, a public-domain vi clone, and the direct ancestor of **vim**.

Its own readme puts it like this:

```
STEVIE Source Release - 3.68
This is a source release of the STEVIE editor, a public domain clone of
the UNIX editor 'vi'. The program was originally developed for the Atari ST,
but has been ported to UNIX, OS/2, DOS, and Minix-ST as well.
...
The good news about stevie is that it is extremely portable.
```

**Why pick it:**

| | STEVIE 3.68 | vim 9.x |
|---|---|---|
| Core code size | ~10,900 lines of C | 557,683 lines of C (`src/*.c`) |
| What it needs from libc | a little string/memory/`printf`/`fopen` | a whole POSIX stack: pthreads, locale, iconv, termcap, signals… |
| What it needs from the OS | a very small "machine-dependent layer" (below) | `fork`/`exec`/`waitpid`/`ioctl`/`termios`/signals/mmap/directory tree/swap files |
| Licence | public domain | GPL-compatible, but far too many dependencies |

**Why vim can't be moved**: vim stands at the "POSIX userland" level — it wants libc, processes,
terminal control, a directory tree. KKernel today has a 4,000-odd-line kernel, no libc and no
processes; what's missing is **an entire layer**, not a handful of functions. STEVIE is different:
it's a 1991 artifact that stuffed everything "talking to the machine" into one file, so replacing
that file makes it run.

## 2. We only took the public-domain part

```
extensions/vi/
    alloc.c ascii.h cmdline.c edit.c env.h fileio.c help.c hexchars.c
    keymap.h linefunc.c mark.c misccmds.c normal.c ops.c ops.h param.c
    param.h ptrfunc.c regexp.c regexp.h regmagic.h regsub.c screen.c
    search.c stevie.h undo.c version.c vi.c        ← the core (public domain)
    kkernel.c                                        ← the backend we wrote
```

**Not** taken: `nt.c` (Microsoft's Win32 platform layer), `sources`, `vi.rc`, `makefile` (NT build
files). So what goes into the repo is STEVIE itself plus our own backend.

## 3. How much the port actually changed: the platform layer + a three-line patch

STEVIE concentrates the machine-dependent code in one file (`nt.c` / `tos.c` / `unix.c`); the
platform layer has to provide exactly this much:

```
screen   windinit()                ask how big the screen is (ours: int 0x30 function 11)
         windexit()                clean up before exit
         windgoto(row, col)        position the cursor                (function 9)
         wchangescreen()           refresh
         outchar / outstr          draw a character/string            (function 13, buffered a line at a time)
         flushbuf()                flush what's buffered
keyboard inchar()                  get one key            (function 10, arrow keys mapped to K_UARROW…)
files    fopenb(name, mode)        open a file            (7/8, see mini-libc's stdio)
         fixname(name)             tidy the name into FAT 8.3 form
misc     beep / delay / sleep / sig / dochdir / mysystem / doshell
         setviconsoletitle / usecmdconsole / useviconsole / StrLength
```

On the core side only three things changed:

1. `env.h`: `#define NT` → `#define KKERNEL` (which conveniently switched off termcap for us too:
   without termcap it uses hardcoded sequences, and those sequences all live in `nt.c` anyway, so
   they had to be rewritten regardless)
2. `stevie.h`: drop `<excpt.h>` / `<ntdef.h>` (MSVC things)
3. `vi.c`: `main(argc, argv)` → `vimain(argc, argv)`, with our own `main` as the entry point —
   because a KKernel program has no argv, so arguments are fetched with `int 0x30` function 12

**The editor core (editing, commands, search, regexp, undo, screen diffing) wasn't touched at all.**
That's the payoff of a clean platform layer: swap one file and the editor can't tell it changed
machines.

## 4. The traps (all worth recording)

### 4.1 `fixname()`'s signature: wrong parameter count, and the compiler says nothing

In the NT version it is:

```c
char *fixname(s)          /* one parameter, returns a static buffer */
char *s;
```

My first version, going by intuition, took "three parameters, writing into a caller-supplied buf".
`stevie.h` has the old-style declaration `char *fixname();`, so **a wrong parameter count doesn't
produce a single compile-time error**; at run time `fopen(fixname(fname),"w")` passes garbage as the
second and third arguments, so the file name comes out empty:

* vi still pops up `"vitest.txt" 1 line, 14 characters` (it thinks it saved fine);
* but the disk grows a directory entry whose **name is all spaces**, which it can't recognise the
  second time it opens it.

Lesson: when porting platform functions in old code, **look at the original implementation first —
don't wing it from a signature you assumed**.

### 4.2 One extra byte in `Scroll()` → a page fault

STEVIE uses two character buffers for "screen diffing": `Realscreen` (what's on the screen now) and
`Nextscreen` (what should be). We have no "read the screen back" interface, so `Scroll()` (the
scrolling done when inserting or deleting whole lines) uses a lazy but correct trick: **dirty
`Realscreen`** and let STEVIE repaint the whole screen the next time it redraws.

The problem is that the buffer size is `malloc(Rows*Columns)` in `alloc.c` — **no +1** — and I filled
it as `Rows*(Columns+1)`: the extra byte landed right on the first few bytes of the next block on the
heap. The consequence isn't an immediate error but something a little later:

```
*** KERNEL PANIC ***
EXCEPTION 0E: page fault
EIP = 0x0012068E            ← inside vi
CR2 = 0x01010109            ← 0x01 fill value + offset 8; you can see at a glance it's a "pointer" overwritten with 0x01
```

**One byte out of bounds is still out of bounds**; and the scene of this bug (the CR2 value) actually
had the clue written all over it — 0x01010101 is my `memset` fill value.

While we're at it: STEVIE's `Rows` is the **whole screen's line count** (it keeps the last line for
the status/`: ` command line itself). My first version "helpfully" subtracted one for it, and the
result was a blank line at the bottom with the status line one row higher.

### 4.3 Chinese displays, but vi treats it as bytes

STEVIE is a 1991 editor and only knows bytes: a UTF-8 Chinese character in a file looks like three
"weird characters" to it, and it draws them as `?` on screen (its character table has no such code
points). So:

* viewing a Chinese file in vi → the Chinese shows up as `?` (the file itself is fine; `cat` shows it correctly);
* to read Chinese properly, use `cat` (the kernel's `term_print` decodes UTF-8 and draws the characters directly);
* to edit Chinese you can use our own assembly editor `run EDIT` (it stores bytes and draws UTF-8).

Making vi UTF-8 aware is **a job for the next step** (STEVIE's `outchar` and buffers are all byte
streams, so the "cursor column" has to be computed by display width, and it must not split a
character in half).

## 5. How to run it yourself

```bash
make hd
# in the shell:
run VI DOCS/NOTES.TXT
    i            enter insert mode
    typing…      press ESC when done
    :w           save (really writes into FAT16)
    :q           quit; refuses if there are unsaved changes → :wq or :q!
```

The automated tests (`make test-hd-font`) check a few things:

* vi's screen shows the `~` empty lines and the `"vitest.txt"` status line → it came up;
* typing in insert mode → the line you typed appears on screen;
* `:w` → the status line reports the file name; `:q` → back to the shell;
* finally **parse the image offline** and assert that `VITEST.TXT` contains the bytes we typed
  (don't trust the kernel's own "saved", look at the disk).

## 6. If you want to keep going, a few directions

1. **UTF-8 support** (4.3 above): let vi display and edit Chinese properly;
2. **Block cursor**: right now "where the cursor is, you guess" (graphics mode has no hardware
   cursor); draw an inverted block instead;
3. **`:!cmd`**: today it just prints "no shell escape" — revisit once there are processes;
4. **Multiple windows/files**: STEVIE supports multiple files; the `Rows/Columns` scheme doesn't get
   in the way;
5. Hook `help.c`'s help screen up to Chinese: the docs are ours, change them freely.
