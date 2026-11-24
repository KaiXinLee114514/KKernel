[简体中文](zh-CN/pitfalls.md)

# Pitfalls we've stepped on (debugging notes)

> This section is the collection of traps actually hit during development and the debugging that
> followed — each one maps to a specific hang or data corruption. Originally README §6.

## 6.1 The floppy BIOS doesn't support LBA extended reads

The first version only did `int 0x13 AH=42h` (LBA extended read, 8 sectors at a time), and QEMU
immediately answered `DISK READ FAILED`.

Using the `tests/probe_disk.asm` probe I measured three read methods against the same image, mounted
once as a floppy and once as a hard disk:

| Method | Floppy `-fda` | Hard disk `-hda` |
|---|---|---|
| `AH=42h` LBA read, 8 sectors | ❌ `CF=1 AH=01` (function not supported) | ✅ works, data correct |
| `AH=02h` CHS read, 1 sector | ✅ works, data correct | ❌ `CF=1 AH=20` (bad geometry) |
| `AH=41h` EDD support probe | `CF=1` (honestly says "no") | `CF=0` |

**Conclusion**: the floppy BIOS simply doesn't recognize LBA extended reads; only hard disks do. So
the right approach is:

1. First ask `AH=41h` whether it's supported (check `CF`, `BX=0xAA55`, bit0 of `CX`)
2. Supported → go LBA, read 8 sectors at a time
3. Not supported → fall back to CHS, **and truncate every read to "how many sectors are left on this
   track"** (CHS reads must not cross tracks)

`boot/boot.asm` now has both paths, and `make test-fda` / `make test-hda` each exercise one.
The probe is kept in `tests/probe_disk.asm` — if you switch to a different BIOS environment, run it
first.

⚠️ But **don't trust the `AH=41h` answer alone**: some BIOSes claim EDD support for floppies too and
then fail the moment a read crosses a track. So the boot sector now says "**drive number < 0x80 always
goes CHS**" and doesn't ask. That's the other half of the 6.33 trap.

## 6.2 Asked for 255 sectors, only the first one was real

When reading the on-disk font, the command went out and the status looked fine, but in memory **only
the first sector held data, everything after was zeros** — every character on screen turned into a
missing-glyph box.

Cause: the ATA spec allows a drive to **transfer only part of the request**, and in PIO mode you must
wait for `DRQ` before each sector. Switching to chunked reads (16 sectors per chunk) with an
`ata_wait_drq` before every sector read the whole thing.

## 6.3 `mov al, 0xE0` threw away the LBA

The drive-select byte has to go into `al`, and the LBA happens to live in `eax` — the low 8 bits got
clobbered on the spot, turning "read LBA 0x1E0" into "read LBA 0x00". The lesson: **look at the bytes
in memory, don't trust "the function returned success"**.

## 6.4 `mov ax, 0x10` wiped out the syscall number

The `int 0x30` entry has to switch itself to the kernel data segment first (`mov ax, 0x10`) — and the
function number happens to be in `eax`. So the dispatcher always saw `0x10` and no function ever
matched. The fix is to stash the function number in `ebp` first.

This class of "the low 16 bits got written over in passing" bit us twice (6.3 and 6.4), both for the
same reason: **in protected mode segment registers are only 16 bits wide, and the low half of `eax` is
useful elsewhere.**

## 6.5 The program load address landed in the middle of the font (the nastiest one)

The program used to load at `0x300000` — far from the kernel, looked perfectly reasonable. But the
full font was read to `0x200000`, 1.8 MB stretching to `0x3BE600`, and **`0x300000` sits right in the
middle of the bitmap data**: the moment the program loaded, it overwrote the bitmaps for a handful of
Chinese characters (the 249-byte `HELLO.BIN` trampled nine characters, U+782A~U+7832, and "砰" would
render as garbage).

Why it was so nasty: **both features worked when tested separately** — `run HELLO` was fine, Chinese
display was fine. It only showed up when you "ran the program and then displayed those particular
characters", and at first I even suspected the font file was corrupt.

The fix was three things:

1. Move the load address to `0x120000` (above it is `FILE_BUF`, below it the font, and the 896 KB in
   between is all free);
2. `run` first uses `fat_stat` to read the size from the directory entry and refuses anything too big,
   so it can't be read in and cover the font (at the time the check was `PROG_MAX_SIZE` = 896 KB;
   later programs switched to a "private image window", so the real limit became 384 KiB (now decided
   by the image window) — see section 5);
3. Two locks were added to the tests: a **sentinel** (`run HELLO` must be followed by the screen
   correctly drawing U+7830 砰, whose bitmap lives in the region that used to get trampled), and a
   **static check** (read `PROG_ADDR` / `FONT_LOAD_ADDR` and the font file size from the source and
   compute whether the program region and font region overlap). Both locks were verified to "go red if
   you change the address back".

While at it, one place I miscalculated: a glyph record stores an offset **relative to the data area**,
so a glyph's address is `font base + data_off + off`, not `base + off` — forgetting `data_off` is a
482 KB error and makes the "which characters got trampled" conclusion completely wrong. **Which base an
offset is relative to matters more than the offset itself.**

## 6.6 The extra bit16 in EFLAGS on the panic screen is not a bug

The divide-by-zero panic screen printed `EFLAGS = 0x00010046`, while at boot it was clearly
`0x00000046`; the extra `0x10000` is bit16 (RF, Resume Flag). The CPU adds it itself: **fault-class
exceptions push RF into the exception frame** so that `iret`ing back to retry the instruction doesn't
immediately fault again. I spent a round chasing that `0x10046` (and first misread it as bit8, TF),
before writing it down clearly in `idt.asm`.

## 6.7 Printing the same line twice overwrites itself / `div` clobbers the color register

- The early VGA driver "returned to column 0" on every print, so a second `print` on the same line
  covered the first — later changed so that **only a newline repositions**.
- Decimal printing used `div`, and `div` puts the remainder in `edx` — while the color happened to
  live in `dl`, so the digits came out in random colors. Changed to **store the color in memory**
  instead of a register.

## 6.8 VGA text mode only has ASCII glyphs

Writing Chinese to the screen produces mojibake (the BIOS font only contains ASCII).

Don't think "just swap the font and Chinese will display": in VGA text mode a character cell is **only
8 pixels wide** (the font is an 8×N bitmap; the height can be raised to 16 or even 32 via CRTC Maximum
Scan Line), while a standard Chinese character is **16×16** — an 8-pixel-wide cell simply cannot hold
one, and no font swap will save you. To really display Chinese you have to enter graphics mode and
draw the bitmap yourself (see section 4).
(I did take the text-mode path to its limit: stuff the font into VGA plane 2, split a Chinese character
across two cells; the register details are in [font/README.md](../font/README.md), but the ceiling is 63
characters, so graphics mode is the default and that experiment can still be run with
`make run-font`.)

## 6.9 `not` doesn't set flags (the page allocator skipped a whole run of free pages)

For the bitmap allocator's free-page search, my first version looked like this:

```asm
    mov eax, [esi + edx*4]
    not eax                ; invert so 0 bits (free pages) become 1
    jnz .found             ; ✗ this ZF was left by the **previous** instruction
```

`not`, like `mov`, **does not affect flags**. So `jnz` tested flags left over from something else, and
the result was pure luck: with the page pool completely empty, the first `debug ptest` allocation got
page 33 (`0x00420000`), as if the first 32 pages were "already in use". Use an instruction that
actually sets flags:

```asm
    cmp eax, -1            ; all ones = this dword is fully occupied
    jne .found
```

Trap: `not` / `mov` / `lea` don't touch flags, so never follow them directly with a conditional jump.
(`inc`/`dec` only **don't change CF**; they do update ZF/SF, so `inc edx` + `cmp` is safe.)

## 6.10 "Create space" also cleared "how big the image is" (the program ran a whole window of zero bytes)

First version of demand paging: the CPU touched 0x120000 and got a red screen, reporting:

```
EXCEPTION 0E: page fault
EIP = 0x00200008   CS = 0x00000008   EFLAGS = 0x00010203
CR2 (faulting address) = 0x5CD90000
```

CR2 was a wild address (not 0x120000), which meant **the first page-in had actually succeeded** and the
program was running — just running the wrong content. Only after dumping physical memory and reading
the `space_*` variables did it become clear:

```
space_img_bytes = 0x00000000     ← ✗ image size is 0
space_pf_run    = 0x000000d0     ← faulted in the whole window (208 pages then), every single one
pf_off          = 0x0007f000
pf_len          = 0x00000000     ← every page counted as "outside the file", nothing copied
```

With `space_img_bytes` = 0, the fault-in logic believed **the whole window was `.bss`**, so it handed a
zero page to every page: the program executed the entire window of zero bytes (`add [eax], al` bouncing
around), eventually jumped somewhere wild like 0x00200008 → secondary page fault → red screen.

The root cause wasn't the fault-in logic but the **call order**: in `cmd_run`, `space_set_image`
(writes the size) came before `space_create` (creates the space), and `space_create` zeroes its own
state at the top — wiping the size that had just been written. Two fixes: create must **not clear the
input parameter** `space_img_bytes`, and the call order becomes create → set_image. Lesson: when an init
function "resets its own state", don't reset **the input someone just gave you** — this symptom
(everything is 0) looks exactly like a logic error, and the cheapest way to find it is to dump memory
and look at the variables rather than staring at the code.

## 6.11 `mov ebx, 10` clobbered the just-parsed digit (`sleep 2` slept 10 seconds)

The day I added the timer, `uptime` was fine but `sleep 2` reported:

```
> sleep 2
slept 10 s (1000 ticks)
```

2 seconds became 10 — so the parsed number was not 2 at all. Looking at the `parse_dec` loop:

```asm
.next:
    mov bl, [esi]
    sub bl, '0'          ; ← digit fetched, stored in bl
    mov ebx, 10          ; ✗ bl is part of ebx; this overwrites the digit with 10
    mul ebx              ; eax = eax×10
    movzx ebx, bl
    add eax, ebx         ; so it adds 10
```

`mul ebx` needs the multiplier in ebx, and the digit just parsed sits in bl — the `2` I typed one
character at a time got overwritten by the multiplier, and the final `1 * 10 + 10` arithmetic produced
10. The fix is **multiply first, then re-read the character**:

```asm
    mov ebx, 10
    mul ebx
    test edx, edx
    jnz .bad
    movzx ebx, byte [esi]   ; ← re-read the original character, don't rely on "the register from last read"
    sub ebx, '0'
    add eax, ebx
```

This was already the **second** time for this class of bug (the earlier one was `mov ebx, [shell_len]`
clobbering the `bl` holding the first byte), so the lesson is burned in: in x86 **"al/ax/eax are the
same register"** — writing to ebx changes bl, writing to eax changes al. When you're holding a
"temporary value", think about whether the next instruction will overwrite it in passing; a temporary
that can be clobbered should either live in another register or be **re-read from memory**.

## 6.12 The test harness can't recognize "Wednesday" (OCR's fault), and `-qmp` must have `unix:`

Building the CMOS clock hit two traps unrelated to kernel code but very time-consuming:

- **Screenshot OCR can't read Chinese weekdays**: `tests/qemu_test.py`'s `screen_text()` compares screen
  pixels against the font bitmaps, so the `星期三` printed by `date` comes out as `??????`. That's why
  the test suite **only asserts on the ASCII part** (timestamp, `RTC: BCD...`, format arguments), and
  the weekday has to be checked by a human looking at the screenshot.
- **QEMU's `-qmp` argument must be written as `unix:/path/to.sock`**: leave off the `unix:` prefix and
  QEMU exits immediately (`'...' is not a valid char driver`). `-monitor` doesn't need the prefix,
  `-qmp` does — while debugging this I also found a QEMU from a previous run that hadn't been killed
  cleanly and was still holding `build/kkernel-hd.img`.

## 6.13 Stack switching may only happen at interrupt entry (decide "where to resume" at design time)

The most dangerous step when adding preemption is "swap esp to another thread's stack". If you let
`sched_pick` swap esp inside the function and then `ret`, you're doomed: the return address popped comes
from the **new stack**, where the new thread's frame sits — one `ret` and you jump into somebody else's
register values and execute them as code. So the division of labor is fixed: `sched_pick` only decides
"who's next" and **returns** it; the actual esp swap is done by the interrupt entry `irq0_stub` itself.
That entry layer has no `ret` (it does `popad` + `add esp,8` + `iret`), so right after the swap it pops
the new thread's frame back into registers and irets away.
In one sentence: the moment esp changes, the meaning of everything on the stack changes — whoever
changes esp is responsible for "where execution resumes".

## 6.14 Inserted a function into the middle of a fall-through code path (first line of input swallowed)

`shell_readline` and `shell_readline_resume` are **deliberately written back to back**: the former only
resets the length, then falls through into the latter's loop body, sharing one function body (the former
is "a new line", the latter is "keep editing the half-line that was there"). I later inserted the
newly written `shell_wait_key` between the two; it compiled without a complaint — but `shell_readline`
now fell into "wait for a key then `ret`" instead of the read-line loop, and the symptom was: **the
first command echoed to the screen but no command ever executed** (every key was treated as "this line
is done", all characters dropped). Lesson: when inserting a function into assembly, pick a clean
boundary such as a `ret` or a comment block; never insert into a spot where "the previous function body
continues by fall-through".

## 6.15 An inactive shell sleeping in `kbd_getchar` steals the "wakeup byte"

When switching shells, I used to stuff a `0x00` into the keyboard ring buffer as an alarm clock to wake
the thread sleeping on the `hlt` inside `kbd_getchar`. The problem: **only one thread can get that
byte** — if an inactive shell grabbed it, that shell went back to waiting for real keys, and when you
switched back it wouldn't redraw the prompt and would eat keys meant for the active shell. The fix was
to wrap our own wait-for-key loop at the shell layer (`shell_wait_key`): only call `kbd_getchar` when
"I am the active shell and there really is a key in the buffer", otherwise `hlt` inside **its own** loop
(the timer wakes it every tick, and it rechecks whether it's still active).

## 6.16 Don't wait for the screen with a fixed `sleep` in tests: characters are "drawn", not instant

After multi-shell landed, the hd suite suddenly had 8 extra failures: files were written, yet `ls`
"couldn't see" `TEST.TXT`; the `run` usage text, `address space destroyed`, `demand paging: 34 page(s)`
all "disappeared". Not a line of code was broken — I typed the same command sequence slowly on a clean
VM and everything was correct.

The truth was in the screenshot: at capture time, the **last line of `ls` was only half drawn** (ending
in half a `CHELL…`), with `TEST.TXT` still below, not reached yet. The kernel draws characters into the
VBE framebuffer over MMIO, and a full screen takes several seconds; the test's `run()` typed the
command and only `sleep(0.9)` before capturing and asserting. Four shell threads and the 100 Hz timer
slow the guest down a bit, and 0.9 seconds stops being enough.

The fix has two layers: `run()` now waits for the screen to "go quiet" (two consecutive identical
captures) after typing, and assertions use `wait_for("text to see")` polling until it appears. Lesson:
**never bet on a fixed wait time in a test that checks screen content** — either wait for "the screen
stopped changing" or wait for "some text actually appeared".

## 6.17 Page tables check permissions **level by level**: forget U/S at the PD level and the program dies on its first instruction

Adding `PAGE_USER` to the program's page-table entries still wasn't enough; the program took a
`page fault at 0x00120000` at 0x120000 (error code bit0=1 = "page is there, but it's not yours").
Cause: permissions aren't only in the final-level PTE, **the PD entry counts too** — in `space_create`,
hooking up the private page table did `or eax, PAGE_P|PAGE_RW` and forgot `PAGE_USER`. Both levels have
to have it.

## 6.18 Fault-in copies must be **page-aligned**

When an image page faulted, data was copied from the staging area like this: `pf_off = faulting address
- SPACE_IMG_VA`, then copy a whole page from `SPACE_IMG_VA + pf_off`. **A straight-line program never
shows the bug** — it only faults at page boundaries, so `pf_off` is always page-aligned. Then ring 3
produced a `call` that entered code mid-page: the first instruction fetch landed at `0x121C10`, so the
bytes from `0x121C10` onward were copied to the start of the page — the whole page shifted, and the
program ran "somebody else's bytes" (symptom: crashing at a nonsense address).
The correct form is to `and eax, 0xFFFFF000` first and use that as the offset.

## 6.19 `hlt` is privileged: the demo program killed itself first

`HANG.BIN` used `hlt` as "sleep 10 ms" (fine in ring 0). After the program moved to ring 3, executing
`hlt` raised #GP and the kernel handled it as an exception — the demo that was supposed to "hang one
shell" crashed itself first. Changed to a busy spin (`dec ecx / jnz`); the timer preempts every 20 ms,
so the other shells still make progress.

## 6.20 Kernel pointers must not be handed to ring3 programs

API 12 (get argument) used to return the kernel's argument buffer `0x11F004`. Perfectly natural in ring
0; in ring 3 the program took a page fault on the first read (the C program `CHELLO.BIN` crashed at
`0x00012D72`, which is exactly the empty string `api_empty` in the kernel). The fix: reserve a page in
the program's own heap window as the argument page, have the loader copy "magic number + argument
string" into it as one block, and API 12 returns the address there. **Every API that returns a pointer
should be asked "is this address inside the program's own space?"**

## 6.21 Three small nasm traps (hit while writing ring 3 with `-f bin`)

- `&` / `>>` on a **label** fails outright with `` `&' operator may only be applied to scalar values ``
  (`dd label` is fine, that just writes the address as data) — the TSS descriptor base in the GDT was
  changed to be filled in at boot time instead.
- A "prefixed local label" like `xxx.yyy:` changes the prefix of **subsequent** local labels to
  `xxx.yyy`, so a whole region of `cmd_run.nomem` becomes undefined. Targets need to use global labels
  (`run_resume_kernel`).
- Inside single-quoted strings `''` is not an escape (`'the kernel''s'` reports `comma expected`).

## 6.22 The config-read buffer sat inside FAT's sector buffer (read back 0 bytes)

`rc_load` has to read `RC.CONF` into memory before parsing. The first version, to save effort, picked a
fixed address `0x10C000` that looked "empty" — that address is **inside `FAT_BUF`
(0x100000~0x10FFFF)**. `fat_read_file` reads sectors into `FAT_BUF` and then copies to the destination;
the destination was inside that same buffer, so the content got trampled and parsing produced 0 keys.

The symptom is very deceptive: at boot it read 9 keys (nobody had touched `FAT_BUF` yet), but after
`write RC.CONF ...` a subsequent `rc reload` reported `RC.CONF, 0 keys`.

Lesson: when picking a buffer in the kernel, **read the memory layout comment first** (the table at the
top of `kernel/kmain.asm`); don't just fill in whatever "looks empty". Better still, use the kernel's own
static buffer (`rc_buf times RC_MAX db 0` in `kernel/rc.asm`).

## 6.23 Unbalanced `push` in a loop: `ret` jumped to `0x00000007`

`rc list` printed the two services and then `KERNEL PANIC`, `EIP = 0x00000007`. Cause: to preserve
`ecx` the loop body did `push ecx` first, but after listing the entry it jumped straight back with
`jmp .loop` — 4 extra bytes pushed per item, so `popad` restored registers from a **misaligned** stack
and `ret` naturally flew to a wild address. Changed to **keep the loop index in a memory variable**
(`rc_lst_i`), not touching the stack at all, and this class of bug went extinct.

One more: to change a return value inside a `pushad` frame you must write `[esp + 28]` (eax's offset in
the pushad frame); make sure this "convention" is written in the function comment, or the next person
will step on it too.

## 6.24 Two "invisible contracts": clobbered registers + `strip_name` zeroing the first space

One morning I caught two traps of the same kind, both in "small utility functions":

* `rc_streq_nocase` (string compare) used `bl` to hold a character but **didn't preserve ebx**. `rc_get`
  used ebx to hold "the key pointer to find", so only the first key could be found — the symptom was
  that `hostname` had a value while `autostart` / `on_crash` all showed "(not set)" and
  `services 0 (0)`.
* The `rc` command's `cmd_rc` called `strip_name` (the shell's old "trim trailing spaces from the
  argument" function). What it actually does is **replace the first space with 0** — that was written
  for commands taking exactly one argument (`cat FILE`, `run PROG`) — so in `rc get hostname` the
  `hostname` got eaten and execution fell into the `.bad_arg` branch.

Lesson: a utility function should either document "which registers I clobber" or wrap its whole body in
`push`/`pop`; before calling an old function someone else wrote, read both its **comment and its
implementation** (the name rarely tells the whole truth).

## 6.25 Interrupt gates clear IF, and `jmp` won't restore it for you

The program enters the kernel **through an interrupt gate** (`int 0x30` and page fault 14 both count),
and that hardware path in x86 **clears EFLAGS.IF**. After the program exits, the kernel goes through
`jmp run_resume_kernel` (not `iret`), so IF=0 all the way back into the shell — with a truly scary
consequence: timer (IRQ0) and keyboard (IRQ1) interrupts were left hanging in the 8259 with nobody
taking them (`pic0: irr=03 imr=fc isr=00` in `info pic`), and the shell's `hlt` never got a wakeup, so
the whole system looked hung — while the CPU was sitting happily in `hlt` and the PIC mask was fine.

Debugging moves: `info registers` to see whether `EFL` contains `0x200` (`00000206` = interrupts on,
`00000097` = interrupts off), then `info pic` to see whether `irr` has anything pending — comparing the
two tells "really hung" apart from "just interrupts disabled".
Fix: `run_resume_kernel` adds a `sti` after switching back to the kernel page directory.

## 6.26 Config space reads all zeros: forgot to set bit31

PCI mechanism #1 is "write address (0xCF8), read data (0xCFC)", and **bit31 of that address must be 1**,
meaning "actually issue this access". Forget to set it and the CPU never starts a config cycle; you read
back 0x00000000 — on screen every device reads as `0000:0000`, with no error reported. Suspect the
address register before the device.

## 6.27 Scanning only func 0 misses a device's "siblings"

A PCI device can have up to 8 functions. The ISA bridge (00:01.0) is just a bridge; its **IDE controller
(00:01.1), USB controller (00:01.2), and power management (00:01.3) are all its functions**. How to
tell: read the header type at the start of the device header; bit7 = 1 means "multi-function device",
in which case funcs 1~7 all need scanning. Scan only func 0 and "you can't see IDE or USB" on your
machine.

## 6.28 Absent devices return 0xFFFF, not 0

Reading an empty slot returns **0xFFFF** from config space (vendor ID 0xFFFF is the "no device"
convention), not 0. So test "is there a device here" with `cmp eax, 0xFFFFFFFF`.
Also, 0x00000000 is a different case: the device is there, but the register really is 0.

## 6.29 Write the command register with a 16-bit write (status is write-1-to-clear)

The command register and status register share offset 4: the low 16 bits are command (read/write), the
high 16 bits are status (**write 1 to clear**). To enable Bus Master, write only the low 16 bits
(`out dx, ax`); a 32-bit write clears all the high status bits — erasing information like "what errors
the device has reported". Our enumeration enables I/O + MMIO + Bus Master on every device, using 16-bit
writes.

## 6.30 Unbalanced hand-written push/pop: `ret` flew to 0x9208

Writing hex printing for PCI, I hand-wrote three variants `pci_ph1/2/4`, and one of them **popped one
register too many** at the end, so `ret` popped dirty stack data (0x9208) ⇒ at boot:
`*** KERNEL PANIC *** / EXCEPTION 0E: page fault / EIP = 0x00009208`.
Lesson: **either use pushad/popad honestly, or don't move the stack by a single extra byte** (same trap
as 6.23, two shapes). Rewritten as one loop with `pushad/popad` + `shr edx, cl`, it never happened
again.

## 6.31 QEMU's USB keyboard steals `sendkey` (the window looks dead)

Two traps in a row:
1. Using `-device usb-kbd` alone reports `No 'usb-bus' bus found for device 'usb-kbd'` — you need
   `-usb` first (which also attaches the machine's built-in PIIX3 UHCI controller at 00:01.2).
2. **Once a usb-kbd is really plugged in, QEMU's `sendkey` goes to the USB keyboard instead** ⇒ our
   PS/2 driver receives nothing and the tests look like "the system died". So the Makefile and the test
   harness only use `-usb` (we want that UHCI controller) and never plug in a USB keyboard.

## 6.32 Writing all-ones to an I/O BAR to size it breaks the whole config space

"Write all ones to the BAR, read it back and invert to get the size" is the standard PCI trick, but on
this QEMU it is only safe for **memory BARs**: doing it once on the IDE's BAR4 (an I/O BAR) made the
config space of **every** device read back 0x0004 / all zeros, even its own size reading as a nonsense
number like 62224 (the true size is 16 bytes). So `kernel/pci.asm` now only sizes memory BARs and takes
I/O BARs' bases as given — the UHCI BAR4 the USB driver needs is an I/O base (`0xC040`), and knowing the
address is enough; we don't need the size.

## 6.33 Floppy: EDD crossing tracks + ISA DMA crossing 64 KiB (two traps stacked)

`make test-fda` once went entirely red: the floppy image booted to a **black screen**, and QEMU monitor
showed the CPU stopped at `EIP=0x7D78` (the boot sector's `halt16`), `HLT=1`, still in real mode — disk
read failed, retried three times, halted. The trap was **two stacked together**, and either one alone
was fatal:

1. **The floppy took the EDD/LBA path**: the BIOS claimed support, but floppy EDD reads **fail when
   crossing a track** (1.44 MB has 18 sectors per track; reading 8 at a time crosses easily) ⇒ drive
   numbers `< 0x80` always go CHS.
2. **ISA DMA cannot cross a 64 KiB physical boundary**: floppy reads use DMA (hard-disk EDD doesn't, so
   hard disks were always fine). The destination address `0x1F200` plus a 4 KiB read crosses `0x20000`
   and the BIOS errors out ⇒ clamp the sector count before every read to "how much is left in the
   current 64 KiB page"; see `read_chunk` in `boot/boot.asm`.
   One more: **don't loop a fixed number of times** — how many sectors actually got read is decided by
   the BIOS, so check whether `dap_lba` has reached `KERNEL_LBA + KERNEL_SECTS`.

How to confirm it really read everything: `make test-fda` passing 7 times in a row is only the first
layer; the strict check is dumping the 128 KiB kernel region starting at guest `0x10000` with QMP
`pmemsave` and comparing it byte by byte against the image — 1485 bytes differ, split into 610 runs,
**the longest run only 14 bytes**, and no whole-sector difference ⇒ every difference is data the kernel
changed itself at runtime (`.bss`, shell buffers), and all 256 sectors are there.

## 6.34 Test screenshots: don't use a fixed path, and don't assert while it's half drawn

Two traps in the test harness itself, both showing up as "one flaky false failure":

- Screenshots used to be written to a fixed `build/_shot.ppm`. With two test rounds running at once (or
  me and the harness), it would **read somebody else's screen** — the hard-disk round's "read method"
  assertion occasionally saw `boot disk: CHS fallback` from the floppy screen. The default path now
  includes the pid (`/tmp/kkernel-shot-<pid>.ppm`).
- The several dozen boot lines are drawn by the kernel **one line at a time into the VBE framebuffer**
  (MMIO, several seconds per screen), while the screenshot only waited 2 seconds. On a busy machine you
  could capture a half-drawn screen. Now it waits for the last line to appear (up to 10 seconds) before
  asserting line by line; on a real failure it OCRs the screen and saves `build/screen-fail.png`, so you
  don't have to guess.
- The same problem bit the simplest `--shell` branch too: `run()` used to "type, sleep 0.7 seconds, then
  assert", and the usage line printed by `debug` (with no subcommand) simply doesn't finish drawing on a
  busy machine ⇒ `make test-shell` failed reliably-but-falsely. Now `run()` waits for the screen to go
  quiet both before and after typing (two consecutive identical captures).
  ⚠️ In that branch you **cannot** use the outer `wait_idle` directly: it is defined in the hd-mode
  section, which the floppy `--shell` run hasn't reached ⇒ `NameError`; writing a local copy in the
  branch is the least painful (same trap as `wait_for` in 6.x).

## 6.35 Framebuffer scrolling: cell alignment + "don't mistake slow for broken"

The terminal in graphics mode (VBE) **draws characters into the framebuffer itself**, and scrolling is a
`rep movsd` moving 16 rows up as a block. Two traps:

1. **600 pixels ÷ 16 = 37.5**: the bottom edge used to be clamped to `600-16 = 584`, and `584 % 16 = 8` —
   after one scroll, every newly written row sat 8 pixels lower than the old rows scrolled up, so "two
   generations of text" overlapped and the whole screen turned to garbage. Now the height is first
   aligned to 16 (`fb_height & ~15` → 592) and then one row subtracted, so the cursor always lands on a
   cell line.
2. **Slow is not the same as broken**: writing to the VBE framebuffer in QEMU is MMIO, and a full screen
   of 2 KB of Chinese takes several seconds. Half of the "garbled screens" back then were actually the
   harness capturing a half-drawn screen (the fixed sleep wasn't enough) — after fixing the alignment
   and the harness's waiting (6.34), the same assertions all passed.

The hd suite now has a dedicated assertion: after 2 KB of Chinese has scrolled several screens, use the
output of `uptime` as a probe to confirm the screen is still "readable".

## 6.36 Called a memory variable as a function, jumped into the data area

Adding "remember which shell this thread was born on" to `spawn`, I wrote

```asm
call sched_cur          ; ✗ sched_cur is a dd, not a function
```

`sched_cur` is **a `dd` in the kernel data area** (holding the current thread number), not a function.
So `call` pushed the return address and jumped into the data area, where the CPU executed zero bytes,
ran straight through `sched_live` / `sched_ticks`, and finally blew up near `sched_cur`'s own storage:

```
*** KERNEL PANIC ***
EXCEPTION 0E: page fault
EIP = 0x0001D1BA   CS = 0x00000008   EFLAGS = 0x00010202
CR2 (faulting address) = 0x38000004
```

**How I located it** (a trick worth remembering): `EIP = 0x1D1BA` is a **code address**, while all kernel
code lives after `0x10000` — checking the listing from `nasm -l build/kernel.lst`, the line at `0xD1B1`
reads:

```
0xD1B1:   367 0000D1B1 00000000     <1> sched_cur       dd 0
```

In other words, **EIP landed on `sched_cur` itself**: `call` really did jump into the data area. Changing
it to `mov eax, [sched_cur]` fixed it.

Lesson: **the target of `call` / `jmp` must be a code label**; variables are always read with `[...]`.
One more trap in the same family: writing the same expression as `call [mem]` is also wrong — that jumps
to the address held in **the value stored in the variable**, which is most likely a thread number
(0/1/2), not code.

## 6.37 TCB grew from 32 bytes to 40: every `shl 5` in the repo had to change

The TCB used to be exactly 32 bytes, so the whole repo used `shl X, 5` as "× struct size" (easy to
write, fast). This time a field had to be added (which shell it was born on), and 32 was no longer
enough — 40 is not a power of two, so every index computation had to become `imul X, TCB_SIZE`.

Where it bit: **I changed everything but forgot one `shl`**, and that site computed indices as if the
TCB were 32 bytes, so the esp/cr3/state it read were all shifted (symptoms varied wildly: thread numbers
in `ps` didn't match, kill killed the wrong target, stack switches even landed on someone else's). So now
the whole repo uses one macro:

```asm
%define TCB_OFF(id) (((id) * TCB_SIZE))
```

**Next time a field is added, only `TCB_SIZE` changes.** If you really want to be lazy, go further: don't
use a multiple of 32 at all — a non-power-of-two like 40 is actually safer, because `shl 5` is instantly
wrong, loudly wrong, instead of quietly half-right.

## 6.38 Glyphs in cute text need to be checked against the font first

Writing cute text for the prompt, my first version used a standard kaomoji: `(｡•́︿•̀｡)`, and it came up
as boxes on the machine. Cause: the font (42112 glyphs) has **every half-width katakana
`U+FF61-FF9F`**, including `｡ ･ ﾟ ノ ｰ`, but `• U+2022`, `́ U+0301`, `̀ U+0300`, `︿ U+FE3F`,
`ω U+03C9`, `∀ U+2200` are all absent; a different font wouldn't help either — missing glyphs can only
show the replacement character.

So check before writing text:

```sh
python3 - <<'EOF'
import struct
d = open("font/full-kkf.bin","rb").read()
_, n, _hs = struct.unpack_from("<III", d, 4)
want = "かいかーねる ﾟ ー ; ) ・ あれ"
for ch in dict.fromkeys(want):
    v = ord(ch); lo, hi = 0, n-1; ok = False
    while lo <= hi:
        mid = (lo+hi)//2; c = struct.unpack_from("<I", d, 16+mid*12)[0]
        if c == v: ok = True; break
        lo, hi = (mid+1, hi) if c < v else (lo, mid-1)
    print(ch, hex(v), "有" if ok else "缺")
EOF
```

Also: `style` changes the prompt itself, so **test assertions must not depend on non-ASCII characters in
the prompt** — the harness's OCR only knows the characters in its font, and `かいかーねる` is always
`??????` in an assertion. That's why the suite only asserts on pure ASCII things like `C:\>` /
`prompt style: dos`.

## 6.39 The framebuffer is slow because every glyph touches video memory once

`cat DOCS/README.TXT` (2 KB of Chinese) took 5.7 seconds at VBE 800x600. The root cause isn't the "glyph
drawing algorithm" but **writing to video memory (MMIO) 16 times per character** — video memory writes
are far slower than ordinary memory.

The fix is to give the terminal a "current line" line buffer (`kernel/fbterm.asm`, 13 pages = 53 KB,
allocated from the physical page pool with `pmem_alloc_pages` at boot):

- Drawing writes only to this RAM, recording the dirty span's left/right bounds `[x0, x1)`
- On `fb_newline` / scroll / backspace, call `fb_flush` once to move the dirty span into video memory
- After scrolling or clearing the screen, `fb_lb_forget` invalidates the buffer, otherwise old pixels get
  smeared back onto a clean screen
- If pages can't be allocated (or pitch is out of range), set `fb_lb_base = 0` and fall back to
  character-by-character direct writes automatically

Two side traps:

1. **`call fb_flush` before going to sleep in `hlt`**, otherwise a "half line with no newline" (the
   prompt, for instance) never shows up — it's still in RAM, waiting for a newline that never comes.
2. **`pmem_init` must come before `fb_init`**: the line buffer needs the page pool, and the page pool has
   to be initialized while paging is still off.

A/B measured at the same moment after the change: 5.69 s → **0.90 s (about 6.3×)**, while the sha256 of
the final screen before and after is **exactly identical** — pure speedup, not a pixel changed. Lesson:
**measure before you change; after changing, prove with pixels that the look didn't change.**
