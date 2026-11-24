[简体中文](zh-CN/programs.md)

# Writing programs for KKernel (the `int 0x30` interface)

Want to change this system? **The fastest way to see results is to not touch the kernel — write a
program, drop it on the disk, and run it.** Programs are flat binaries built with `nasm -f bin`, placed
in the FAT16 partition, and started from the shell with `run`.

> Also, since the TCC port, `run` recognizes **ELF32 executables** too (magic `\x7fELF`):
> the kernel's `kernel/elf.asm` expands PT_LOAD segments from the program headers into a flat image and
> runs it, using the ELF `e_entry` as the entry point. Programs compiled inside the system by TCC are in
> this format (see `extensions/tcc/README.md` for details). The flat BIN loading path is unchanged; the
> two formats coexist.

Ready-made examples live in `progs/`:

| Program | What it does | Which parts of the interface it uses |
|---|---|---|
| `HELLO.asm` | Minimal: prints one line of English + one line of Chinese + one Han character | 0 / 3 / 4 |
| `COUNT.asm` | Loops and prints, decimal/hex, prints Han characters by code point | 0 / 1 / 2 / 3 / 4 |
| `CALC.asm` | **Calculator**: add/sub/mul/div, decimal point, square, fixed-point math done by hand | 6 / 9 / 10 / 13 |
| `EDIT.asm` | **Full-screen text editor**: visible cursor (bright green `_`), arrow keys, `Ctrl-F` search, save, open | 6 / 7 / 8 / 9 / 10 / 11 / 12 / 13 |
| `PLAY.C` | **Text score player** (written in C): reads a score from FAT and makes the speaker sing | 7 / 14 |
| `TOUCH.asm` | **Demand-paging demo**: touches memory page by page, then checks each page still holds what it wrote | 0 / 1 / 3 / 4 |
| `ZH.TXT` | Demo text baked into the image: Chinese/UTF-8 (Yellow Crane Tower, emoji, bad-byte replacement), see `cat DOCS/ZH.TXT` | – |
| `EN.TXT` | Demo text baked into the image: Shakespeare's Sonnet 18, see `cat DOCS/EN.TXT` | – |
| `JPKR.TXT` | Demo text baked into the image: Japanese/Korean, see `cat DOCS/JPKR.TXT` | – |
| `RING3.asm` | **ring 3 demo**: prints CS / CPL / SS / ESP / [ESP], proving the program really runs in user mode and that the stack and trampoline page come from the kernel | 0 / 2 / 4 |
| `FAULT.asm` | **Protection demo**: deliberately reads the kernel's `0x00100000` and is cleanly killed by a page fault (the kernel keeps running) | 0 / 4 |

---

## 1. Three-line hello

```asm
[BITS 32]
[ORG 0x120000]          ; ← required, must match the kernel's load address

start:
    mov eax, 0          ; function 0: print a string
    mov esi, msg
    int 0x30
    ret                 ; return to the shell

msg db 'hello from a program', 10, 0
```

Assemble, pack, run:

```bash
nasm -f bin progs/HELLO.asm -o build/HELLO.BIN        # 1. assemble (flat binary)
python3 tools/mkfat.py build/kkernel-hd.img 6144 8 \    # 2. pack into the FAT16 partition
    HELLO.BIN=build/HELLO.BIN
make hd                                               # 3. boot (or ./tools/run.sh --hd)

> run HELLO                                           # 4. run it in the shell (name is case-insensitive)
running HELLO.BIN
hello from a program
program returned to the shell
```

`make` already knows about `progs/*.asm` (the `$(BUILD)/%.BIN` rule), so adding your own program just
means dropping `MYPROG.asm` into `progs/`, adding `MYPROG.BIN` to the `PROGS` variable in the
`Makefile`, and appending `MYPROG.BIN=build/MYPROG.BIN` to the `mkfat.py` line in the `$(HDIMG)` rule.

> Use **uppercase** filenames: the 8.3 convention for ISO/FAT is uppercase, and the name `nasm` emits
> has to match. Incidentally, the `Makefile` rule `$(BUILD)/%.BIN: progs/%.asm` is case-sensitive —
> the source file must be named `progs/MYPROG.asm`.

## 2. The interface: fifteen functions in total

The first six are the "print/read a key" basics:

| eax | What it does | Arguments | Returns |
|---|---|---|---|
| 0 | Print a UTF-8 string (0-terminated, `\n` starts a new line) | esi = address | — |
| 1 | Print decimal | ebx = value | — |
| 2 | Print hex (prefixes `0x` automatically) | ebx = value | — |
| 3 | Print one Unicode code point (Han characters work too) | ebx = code point | — |
| 4 | Set color | bl = attribute byte | — |
| 5 | Wait for a key (arrow keys are skipped) | — | al = ASCII |

The next nine are what "full-screen program + sound" needs (the calculator, editor, and player rely on
them):

| eax | What it does | Arguments | Returns |
|---|---|---|---|
| 6 | Clear the screen (cursor to top-left) | — | — |
| 7 | Read a file | esi = filename, edi = buffer, ecx = limit | eax = bytes read, -1 on failure |
| 8 | Write a file (create/overwrite) | esi = filename, edi = data, ecx = byte count | eax = 0 on success, -1 on failure |
| 9 | Position the cursor | ebx = row, ecx = column (0-based, clamped if out of range) | — |
| 10 | Wait for a **key event** | — | eax = ASCII or `0x100 + code` |
| 11 | Screen size | — | eax = columns, ebx = rows |
| 12 | Get the program arguments | — | esi = argument string (the part after `run EDIT DOCS/NOTES.TXT`) |
| 13 | Draw text at a position | esi = string, ebx = row, ecx = column, edx = max cells | eax = cells actually used |
| 14 | **Speaker**: beep at freq Hz for ms | ebx = frequency Hz, ecx = milliseconds (frequency <= 0 = silence for that long) | — |

Function 14 (in C, `j_beep(freq_hz, ms)`; the player `progs/PLAY.C` relies on it) has two things worth
knowing:

* **The pitch is accurate**, derived by dividing 1193182 Hz through PIT channel 2, independent of how
  fast the host is;
* **The duration is an estimate**: no IRQ0/timer was added this time, so "milliseconds" are counted by
  busy-waiting (the calibration is in `kernel/speaker.asm`). To actually hear it you need to give QEMU
  an audio backend, see [section 8 of quickstart.md](quickstart.md);
* With frequency <= 0 it makes no sound but still waits — use it as `sleep` (the rests in a score are
  exactly this).

The extended key codes returned by function 10 (the arrow-key family):

```
1 = ↑   2 = ↓   3 = ←   4 = →   5 = Home   6 = End
7 = Delete   8 = PgUp   9 = PgDn
```

Other function numbers are ignored (the dispatcher just `ret`s at the end). Function 13 is the
"don't scroll, don't move the cursor" way of drawing: a full-screen program decides where every
character goes, and it stops at `\n` — perfect for drawing row by row.

### Register convention (important)

After `int 0x30`:

* **eax / ebx / esi** = return values (functions that don't use them may still clobber them; don't
  expect them preserved)
* **ecx / edx / edi / ebp** = guaranteed unchanged

Why this section exists: `api_stub` wraps everything in `pushad`/`popad`, and `popad` would **restore
the return values too**, so at the exit it deliberately writes those three slots back into the registers
the program sees (see the comments in `kernel/api.asm`).

The color byte follows the old VGA text-mode rules: `0x0A` bright green, `0x0B` bright cyan, `0x0E`
bright yellow, `0x07` light gray, `0x0C` bright red. In graphics mode the kernel converts it to RGB.

Other registers (beyond eax / ebx / esi) are not guaranteed preserved; `push` them yourself if you need
them.

## 3. Why an interrupt instead of calling kernel functions

Kernel functions live at **absolute addresses** (the whole kernel is one flat binary loaded at 0x10000).
If a program hardcodes `call 0x012345`, then the moment the kernel changes and a function moves, the
program blows up on the spot.

So there's an interrupt gate in between: `int 0x30` goes through the IDT (vector 0x30 is installed by the
kernel at boot with `idt_install`, see `kernel/api.asm`). Programs only know function numbers, and the
kernel can change however it likes — that's the minimal concept of a "system call".

A few conventions, while we're here:

* Programs are read into **0x120000** (`PROG_ADDR`), hence `[ORG 0x120000]` — note this is a **virtual
  address**; the physical pages are handed out fresh by the kernel each time (see the next item);
* The stack is still the **kernel stack** (growing down from `0x90000`); programs don't build their own;
* The shell enters with `call 0x120000`, so a program's `ret` returns to the shell — the simplest way
  back;
* **Each program has its own address space (with pages handed out on demand)**: before `run`, the kernel
  builds it a page directory + an empty page table — `0x120000~0x17FFFF` (the 384 KiB image window) and
  `0x180000~heap top` (the heap window, about 2.1 MB). In the program's page table these window pages are
  all "**not present**", and **not a single physical page is given up front**. Whichever page the program
  touches, page fault 14 grabs a page, zeroes it, fills the table, and irets back to re-execute the
  instruction.
  Benefits: a 249-byte `HELLO.BIN` only consumes 1 page (previously the whole window was handed over);
  pages touched are always **clean zero pages** (so globals default to 0), physical pages are a different
  batch every time (`run TOUCH` shows this best); and when it finishes, the page tables go back to the
  pool too. Virtual addresses don't change, so programs need no edits.
  The image window is only 384 KiB; `run` refuses images larger than that;
* But the **kernel window is still identity-mapped** (0~ident): the upside is that `int 0x30` is always
  available and the kernel can directly read pointers passed in by programs; the cost is that programs
  can still modify kernel memory — "can't read other people's pages" is done, "can't modify the kernel"
  waits for ring 3;
* Programs **can** take arguments: for `run EDIT DOCS/NOTES.TXT` the shell writes `NOTES.TXT` into the
  argument block `0x11F000` (`PROG_ARG_ADDR`), and the program fetches it with function 12 (empty string
  if there are no arguments).

## 4. A slightly more complex example: `COUNT.asm`

```asm
start:
    mov eax, 4
    mov ebx, 0x0E           ; bright yellow
    int 0x30

    mov ebx, 1
.loop:
    push ebx                ; ★ save ebx before each call
    mov eax, 1              ; print decimal
    int 0x30
    mov eax, 0
    mov esi, msg_space
    int 0x30
    pop ebx
    inc ebx
    cmp ebx, 10
    jbe .loop
```

`push ebx` / `pop ebx` is mandatory: the interface only promises its own little contract, not that
"ebx is unchanged across the call".

`COUNT.asm` also has the trick of printing Han characters by code point:

```asm
    mov ebx, 0x4F60         ; U+4F60 is "你"
    mov eax, 3
    int 0x30
```

As long as the font has that code point, it can be drawn. The built-in font has only 416 glyphs (roughly
enough for ASCII + common characters), while **the full font in the hard-disk image has 42,112** (CJK
basic block, extension A, kana, hangul, full-width punctuation, some emoji). Booting from floppy falls
back to the built-in subset — Han characters then show up as missing-glyph boxes.

## 5. Using Chinese in programs

The ready-made full demo is `ZH.TXT` in the image (`cat DOCS/ZH.TXT` in the shell): bitmap Han
characters, 4-byte emoji, and how deliberately corrupted bytes are drawn as the replacement character
`�` instead of hanging the system.

To write your own, just write UTF-8 bytes directly; the kernel's `term_print` decodes them:

```asm
msg db '你好,世界!', 10, 0
```

No need to think about code points or encoding tables. The only trap is **the editor and toolchain**: the
file itself must be saved as UTF-8 (every Chinese file in this repo is), and `nasm` just copies the
bytes without caring what encoding they are.

## 6. Four things to remember when writing a "full-screen program"

Both the calculator and the editor are full-screen (they clear the screen themselves and decide where
every character goes); the traps they hit apply to you too:

**① The entry point must be the first code in the file.** The kernel starts executing at the address
given by `[ORG]`, which is **the first byte of the file**. `CALC.asm` originally put small wrapper
functions like `api_clear` at the very front, and `run CALC` flashed back to the shell — it executed
only the "clear screen" line and then `ret`ed.
Either put the entry first, or make the first instruction `jmp start`.

**② The terminal overwrites, it doesn't redraw.** When a new line is shorter than the old one, the old
characters stay on screen: the calculator would show garbage like `1.00.1 *1000`. So every line you draw
must **pad the whole row with spaces** (`pad_line` in `CALC.asm`, `fill_row` in `EDIT.asm`).

**③ Don't use `al` as a scratch variable and then use `eax` as an address.** The editor inserts a
character by `mov eax, [cursor]` and then writing to `[TEXT+eax]` — if a `mov al, <char>` sneaks in
between, the low byte of `eax` is overwritten by the character value, and the write lands at
`TEXT + char code`. The symptom is bizarre: typing produces blank lines everywhere (because what gets
left in place is the original `\n`).

**④ The visible cursor needs no bookkeeping — provided you already redraw the whole screen.** The editor
calls `api_clear` and redraws everything on every keystroke (see ②), so when the cursor leaves an old
cell, that cell is covered by the body text (or spaces) anyway; the new position just needs a bright `_`
drawn last with function 13 (`CURSOR_CHAR` / `CURSOR_ATTR = 0x0A`), and no "restore then draw" backup
logic is needed. What you do need to be careful about is **bounds**: don't draw when the cursor is
outside the text area or when that column is pushed off screen by a long line — and note that function
13's `edx` is an **absolute column limit**, not "how many cells to draw" (pass 1 and, in graphics mode,
nothing is drawn at all because "1 cell can't fit a character past column 0").

## 7. A real trap: the load address was chosen in the middle of the font

Programs used to load at **0x300000** — looked reasonable (3 MB, far from the kernel), but **it was
wrong**: the full font used to be at 0x200000, 1.8 MB stretching to 0x3BE600, and 0x300000 sat right in
the middle of the **bitmap data**.
(Since stage 2-B the font lives in a slot at the top of the identity map, ident-2 MiB, so the paragraph
above is history; the offline check below still guards "the program area must not sit on the font" using
the conservative lower bound `FONT_LOAD_ADDR=0x200000`.)

Consequence: loading a program overwrote the bitmaps of several characters. Measured: the 249-byte
`HELLO.BIN` trampled **nine Han characters, U+782A~U+7832** (`砪砫砬砭砮砯砰砱砲`), and those characters
rendered as garbage — and the bug only appeared when **those characters** were displayed, so it was easy
to spend ages investigating "the font itself is broken".

Worth writing down the arithmetic too (it was worked out properly while chasing this): each glyph record
in the font stores an offset **relative to the data area** (after `data_off`), so a glyph's address in
memory is

```
font base (0x200000) + data_off (0x7B610 in full-kkf.bin) + that glyph's off
```

not "base + off". The first time I forgot `data_off`, the result was off by 0x7B610 ≈ 482 KB and every
conclusion was wrong — worth remembering: **which base an offset is relative to matters more than the
offset itself.**

This kind of "two things each own a chunk of memory and neither tells the other" bug is especially
nasty: both features work when tested separately. What we do now:

* Load address moved to **0x120000** (above it is `FILE_BUF`, below it the font, with 896 KB of empty
  space in between);
* `run` first uses `fat_stat` to check the size in the directory entry and refuses anything too big, so
  it can't be read in and cover the font (at the time the check was `PROG_MAX_SIZE` = 896 KB; programs
  now use a "private image window" with a real limit of 384 KiB, and the constant is kept for the static
  check below);
* One test is a sentinel: after `run HELLO` the screen must correctly draw **U+7830 砰**
  (`font still intact: 砰`) — that character sits in the region that used to get trampled;
* Another test is a **static check**: read `PROG_ADDR` / `FONT_LOAD_ADDR` from the source and compute
  whether the program region `[PROG_ADDR, PROG_ADDR+PROG_MAX_SIZE)` and the font region
  `[FONT_LOAD_ADDR, FONT_LOAD_ADDR+font byte count)` overlap — the moment someone moves the load
  address back into the font, this goes red.

Want to verify on screen that you haven't trampled something else? Use the `find_text` approach — render
the expected text into a bitmap and then look for it in the screenshot (see `tests/qemu_test.py`); it's
more reliable than eyeballing.

## 8. Debugging tips

* Going wild in a program (e.g. accessing an unmapped address) triggers the kernel's panic screen, which
  shows EIP — but that EIP is from the kernel address space's point of view, so you have to look it up
  against `build/kernel.lst` or `nasm -l build/HELLO.lst` yourself;
* To single-step/breakpoint, use `./tools/run.sh --gdb` (`-s -S`, then gdb `target remote :1234`);
* After a program returns, the shell prints `program returned to the shell` — if you don't see that
  line, it didn't return (infinite loop or crashed).

## 9. Want to extend the interface?

Adding a function takes three places, all in `kernel/api.asm`:

```asm
api_dispatch:
    cmp eax, 6
    je .new_thing           ; 1) add a branch
    ...
.new_thing:
    ...
    ret

api_usage:                  ; 2) add a line of description (visible by just typing run)
    db '  eax=6  ...', 10
```

3) Remember to keep the text in `api_usage`, `progs/README.TXT`, and this page in sync — if the three
disagree, the next person to change things (probably you, three months later) will curse.

One more caution mentioned above, repeated here as a warning: **changing segment registers inside
`api_stub` also changes `eax`** (`mov ax, 0x10` wipes the function number). That's why the function
number is stashed in `ebp` and restored afterwards. When you add code there yourself, don't touch `eax`
before it is restored.
