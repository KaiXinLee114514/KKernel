[简体中文](zh-CN/architecture.md)

# Architecture and Implementation Details

> This document used to be §4–§5 of the README; it was split out to make it easier to read.

## Graphics mode (VBE + framebuffer)

The text-mode route can only fit 63 Chinese characters (a single Chinese character takes two 8-pixel-wide character cells), so proper Chinese has to go through graphics mode — the screen is just a chunk of video memory, and what gets painted on it is entirely up to you.

```
real-mode stub  int 0x10 AX=4F00/4F01 enumerate modes → AX=4F02 set 800×600×32 (with a linear framebuffer)
                → write framebuffer physical address/width/height/pitch/color depth into BOOTINFO (0x8000)
paging          the framebuffer sits at 0xFD000000, outside the identity-mapped window (0..ident)
                → work out the page-directory entry on a 4 MiB boundary and hang a page table off it to map the framebuffer in (skip this and the very first pixel write takes a page fault)
framebuffer terminal  kernel/fbterm.asm: codepoint → binary-search the font → fetch bits row by row → write 4-byte pixels into video memory
                (color comes from converting the text-mode attribute byte to RGB; scrolling is just a memmove of the whole framebuffer up by 16 rows)
```

Pitfall: one row of a 16×16 Chinese glyph is **two bytes**, and the low-address byte is the left half. At first I started drawing leftwards from bit15, and the result was **Chinese characters with their left and right halves swapped** (every character looked like it had been "folded in half"). The fix was `rol ax, 8` to swap the two bytes back.

## Disk: font, FAT16, running programs

On top of the disk there is also a very thin "device" abstraction: names under `/DEV` are taken over by the kernel device table (see [devices.md](devices.md)).
(it hasn't been fully updated yet)
This area got a page of its own: **[filesystem.md](filesystem.md)** — the image's LBA map, the ATA PIO register order and its two pitfalls, how the disk font is loaded, FAT16's fields and the write-file flow, how to use `mkfat.py`, and how the tests use two channels to prove that "the bytes really landed on disk".

If you want to write programs, see the other page: **[programs.md](programs.md)** — the six functions of `int 0x30`, why we use an interrupt instead of `call`ing kernel functions, the program's memory/stack conventions, and how to add one to the image.

The one-line version:

```
run HELLO      → fat_stat to get the size → fat_read_file reads it into 0x120000 first (staging)
               → space_create builds a fresh empty address space (page directory + two pages of page tables; not one window page is handed out)
               → switch CR3 → call 0x120000 → whichever page the program touches, the page fault fills it in from the staging area
               → the program rets back to the shell → switch CR3 back → the faulted-in pages go back to the page pool along with their page tables
inside a program: mov eax, 0 / mov esi, string / int 0x30   ← print one line
```

### Every program gets its own address space (and gets it on demand)

Before running a program, the kernel builds it a fresh set of page tables (**see `space_create` in [kernel/paging.asm](../kernel/paging.asm)**):

```
page directory  = a copy of the kernel page directory     (kernel, IDT, VGA, font, framebuffer are all still there)
page table[0]   = a copy of PT_LOW, but the 208 entries covering 0x120000~0x1EFFFF are **cleared to "not present"**
private pages   = not a single page handed out in advance — whichever page the program touches, page fault 14 fills it in right then
```

So: the program's **virtual addresses don't change** (it's still linked at `0x120000`, and the program itself needs no changes),
**every run gets a brand-new batch of physical pages**, and **only the pages it actually walks on get memory**:

```
> run HELLO.BIN
running HELLO.BIN
address space: CR3 = 0x00400000  (own page directory + demand paging)
Hello from HELLO.BIN - I was loaded from the FAT16 disk!
program returned to the shell
address space destroyed: 3 page(s) back to the pool
demand paging: 1 page(s) faulted in (image 1 + heap 0), first page 0x00402000
```

A 249-byte program **only needs 1 page** (previously the whole window was handed to it). The one that deliberately stomps on memory is
[progs/TOUCH.asm](../progs/TOUCH.asm); `run TOUCH` touches 32 heap pages one by one plus one `.bss` page,
then goes back and checks that every page still holds the marker it wrote:

```
> run TOUCH.BIN
  heap: touched 32 pages (4 KiB each), wrote 0xA5 into every one of them
  pages that were NOT zero before my write: 0     ← a freshly handed page must be a clean zero page
  pages that did not read back what I wrote: 0     ← every page really belongs to me
  page beyond the file (bss at 0x17E000): was zero, as it should be
demand paging: 34 page(s) faulted in (image 2 + heap 32), first page 0x00425000
```

The fault-in flow (all in `page_fault_try_handle` in [kernel/paging.asm](../kernel/paging.asm)
and `isr_common` in [kernel/idt.asm](../kernel/idt.asm)): CR2 is the faulting address → decide whether it
falls in the image window or the heap window (outside the windows it's the usual red-screen panic) → grab a page from the page pool, zero it →
in the image window, copy the part that is "inside the file" from the staging area ("outside the file" is `.bss`, left as a zero page) →
fill in the page table + `invlpg` → `iret` back to **re-execute that instruction**. The program never notices a thing.

A few honest admissions:

- Copy-on-write, swap-based page replacement, and automatic user-stack growth are all in place (see the next two sections); the remaining limits:
  COW-shared pages (refcount > 1) are never swapped out, swap contents are neither compressed nor persisted, and a full swap returns ENOMEM;
- **Holes in the window also get pages** (a program that merely reads an address near 0x180000 also gets a zero page);
- The kernel window stays identity-mapped, so `int 0x30` still works — **ring 3 is not required**,
  and pointers a program passes to the kernel still resolve (at that point the kernel is running on the program's own page tables).

### Programs run in ring 3: they can't touch the kernel's memory

`RING3.BIN` asks the CPU directly "who am I right now" (`CS = 0x1B`, `CPL = 3`), while `FAULT.BIN` deliberately reads kernel memory —
the kernel catches it, prints the reason, kills the program, and the machine keeps running:

![ring 3: the program runs at CPL=3, and touching kernel memory gets it killed](screenshot-ring3.png)

The program starts at `0x120000`, but **the kernel does not `call` into it** — the kernel uses `iret` to drop it into user mode
(CPL=3); its code segment is 0x1B and its stack segment is 0x23. It can see this for itself:

```
> run RING3.BIN
running RING3.BIN
address space: CR3 = 0x00406000  (own page directory + demand paging)
RING3.BIN: asking the CPU where I am running
  CS  = 0x0000001B  (CPL = 3), SS = 0x00000023  ESP = 0x001EFFFC, [ESP] = 0x0019F000
if CS is 0x001b and CPL is 3, this program is not the kernel any more.

program returned to the shell
```

The `0x17F000` in `[ESP]` is the **trampoline page** the kernel pushed for it: the program's final `ret` jumps there,
and the trampoline is just three instructions (`mov eax,15 / int 0x30 / jmp $`) — shout "I'm out" and you're back in the shell.
**Not one existing program needs changing** (the crt0 of C programs also ends in `ret`).

Now, what if it tries to touch the kernel's turf:

```
> run FAULT.BIN
FAULT.BIN: now reading kernel memory at 0x00100000 ...

program crashed: page fault at 0x00100000 (EIP 0x0012000C) -- that page belongs to the
kernel, not to you

program was killed, the kernel is fine
```

Page-table permissions are checked **level by level**: the pages of the kernel's identity mapping (0..ident) have U/S=0, program pages have U/S=1,
so `mov ebx,[0x100000]` is an immediate page fault; the kernel's response is to **kill the program and carry on**
(it used to panic; now it's `program was killed`). User-mode exceptions are no longer kernel panics either:
`isr_common` first looks at CS (CPL) in the error code, and if it's 3 it hands things to `prog_kill_from_fault`.

The pieces of real estate a program has (all inside its own address space, faulted in on demand):

| Address | Purpose |
| --- | --- |
| `0x120000`-`0x17EFFF` | program image window (96 pages; don't use `0x17F000` as a data buffer — that's the trampoline page) |
| `0x17F000` | trampoline page (one separately mapped page: three instructions that shout "I'm out" on the program's behalf) |
| `0x180000`-`heap top - 1` | heap window (`malloc` grows from here; size depends on machine memory, roughly 2.1 MB by default) |
| `heap top - 0x2000` | argument page: the kernel's copy of the arguments (0x11F000) is "somebody else's memory" to ring 3, so the loader copies the whole block over |
| `heap top - 0x1000` | user stack (stack top = heap top - 4; those 4 bytes are the trampoline address) |
| `0x80000000`+ | big anonymous heap (blocks requested by `anon_alloc`; one demand-built page table per 4 MiB, cold pages can be swapped out to the swap area) |

### The next layer down in physical memory: swap (page out/in)

When the physical page pool (starting at 4 MiB, sized according to machine memory) runs low, it first swaps **cold pages out to disk** and then hands out new pages —
user programs never notice, they're just occasionally a bit slower. Implemented in [kernel/swap.asm](../kernel/swap.asm).

- **Swap area**: the test image `build/kkernel-swap.img` appends **16 MiB at the end** of the normal 16 MiB disk image
  (starting at LBA 32768, **4095 4 KiB slots**); the **first 4 KiB of the swap area is a header block** (first 16 bytes `"KSWP" + version + total_slots + slot_size`, the rest reserved), and data slots start at sector +8 so that slot 0 doesn't overwrite the header.
  A normal image has no such header → swap is **silently disabled**, and existing tests and page-count baselines are unaffected.
- **Frame metadata**: 8 bytes per physical frame (flags + address of the PTE pointing back at it), carved out of the page pool at boot according to `pmem_total`
  (with `-m 128`, 59 metadata pages manage 30207 frames); the slot bitmap is 512 bytes of static BSS.
  Only "user demand pages with refcount == 1" are marked swappable (ANON); COW parent/child shared pages,
  kernel pages, page tables, and DMA/IO buffers are never touched.
- **PTE encoding**: after swapping out, PTE = `present=0` + software bit 9 (`PAGE_SWAP`) + top 20 bits slot number;
  COW uses present=1 + bit9, and the two are distinguished by present, so they can't collide.
- **Swap out (CLOCK second chance)**: sweep the whole pool from the cursor, skipping non-ANON / refcount >1 / PTEs that no longer point at
  this frame; a set reference bit is cleared and the frame skipped for one round; the next hit is selected: allocate a slot → copy 4 KiB to the bounce buffer →
  `ata_write_sectors` (bypassing FLUSH CACHE; swap doesn't need persistence) → PTE becomes slot+bit9 → flush TLB →
  return the frame. Interrupts are off throughout (ATA PIO is polled and needs no interrupts; on a single core this is the lock).
- **Trigger points**: demand fault fill-in / fork allocation / kernel stack allocation / big-anonymous-heap growth all go through
  `swap_alloc_frame`; when the pool is full it reclaims a few pages and retries (up to 4 rounds). CLOCK's first pass only clears reference bits,
  so the reclaim function has to loop until it actually gets a page.
- **Swap in**: a fault sees present=0 + bit9 → `swap_swapin`: allocate a frame (swap something else out first if the pool is full) →
  read 4 KiB back from disk → re-check that nobody touched the PTE → install `P|RW|USER` → `invlpg` → free the slot;
  not a single byte of data goes wrong, and `SWAPTEST`'s sampled re-reads specifically verify this.
- **Big anonymous heap**: `anon_alloc(n)` (int 0x30 function 31) pushes the TCB's `brk` (`TCB_UBRK`) up from
  `0x80000000`; the first touch of a 4 MiB segment builds its page table on demand, then hands out pages on demand. Child processes created by `fork`
  **do not inherit** the big anonymous heap (the corresponding PDE in the page directory is cleared and brk is reset) — noted in the known limitations below.
- **Known limitations**: COW-shared pages are not swapped out; a full swap returns ENOMEM (no OOM killer); swap contents
  are not persistent (gone on reboot, the image is rebuilt every time); no compression, no per-process quota; interrupts-off single-core assumption,
  SMP would need real locks; with `-m 16` the page pool is only about 6 MiB, and one `SWAPTEST` round takes about a minute
  (under QEMU/TCG an ATA PIO write of a 4 KiB page takes about 20 ms, which is the main source of test runtime).

### Threads and scheduling (kernel threads + priority scheduling)

`kernel/sched.asm` has 16 thread slots, each a **196-byte** TCB: esp / cr3 / state /
ticks received / times scheduled / physical pages of the stack / name / which shell it was born on /
parent process / exit code / uid+gid / process group and session (pgrp/sid) / priority / sleep channel and timeout /
ready-queue forward and back pointers / aging counter / big anonymous heap brk / exec payload page / Ctrl-C and Ctrl-Z flags.
(It used to be 32 bytes, which is why the whole repo used `shl 5` as the index stride; when fields were added this became `imul X, TCB_SIZE` —
see 6.36 in the [pitfall notes](pitfalls.md).) **Thread 0 is always the shell itself** — it isn't created by anyone; at boot the current context is simply filled into its slot.

The preemption point is **IRQ0 (PIT, 100 Hz)**: `irq0_stub` sends EOI first, then checks whether the scheduler is enabled; if so it hands the
current esp to `sched_pick` to decide who runs next, then does `mov esp, eax` to switch stacks, followed by `popad` +
`iret` and "returns" into another thread. **The stack switch can only happen at the interrupt-entry layer**: `iret` pops EIP/CS/EFLAGS
off the stack, and switching esp in an ordinary function and then `ret`ing cannot get you back (reasoning in 6.13 of the [pitfall notes](pitfalls.md)).

A new thread's "scene" is laid out by hand by `sched_spawn` on its own stack: in the same format `irq0_stub` expects,
it places EFLAGS / CS / EIP / error code / vector number / the eight registers of pushad, with esp pointing at the bottom of the pile.
So the first time it is `iret`ed into, it looks as if it "was just interrupted", and the function body starts from the top.

Limitations (toy-grade honest disclosure):
- There is priority scheduling: 0 is highest, ordinary shell threads are 8, idle is 15; each level has a FIFO ready queue + bitmap,
  same-level threads round-robin on a 20 ms (2 tick) slice, and a higher-priority ready thread preempts. There are block/wake primitives
  (`sched_sleep_on` / `sched_sleep_timeout` / `sched_wakeup`); `process_wait` and
  `tty_read_line` both sleep on channels; aging only slowly raises low-priority threads to shell level, so nothing starves
- Each thread has a 4-page stack (16 KiB) + 1 guard page underneath (removed from the identity mapping, so stepping on it gives #PF;
  a real kernel stack overflow that reaches the double-fault gate prints a panic instead of rebooting)
- The user stack carves a 128-page (512 KiB) growth area off the top of the heap window, faulted in on demand;
  below the stack top are the argument page and the guard page (going out of bounds gets you peacefully killed)
- `kill`ing a thread that is **running a program** checks whether the cr3 it's using is the current program's:
  if so, the address space is torn down along with it (page directory + private page tables + every faulted-in page goes back to the pool)
- Global state such as the terminal and FAT is protected by locks (`kernel/lock.asm`): spin locks, recursive sleeping mutexes,
  `console_lock` keeps multi-threaded output from interleaving, `fs_lock` serializes file commands;
  the lock order `fs_mutex → console_mutex` is allowed, the reverse is forbidden
- These are still **kernel-mode** threads: no ring 3, no TSS, and not yet "one address space per thread"

Try it yourself:

```
> spawn            # no argument: first time alpha, second time beta
spawned thread 4 (alpha)
> spawn
spawned thread 5 (beta)
> ps
ps: 6 alive / 16 slots, scheduled ticks 1169
  [0] shell   ticks=893  runs=85
  [1] shell2  ticks=790  runs=80
  [2] shell3  ticks=700  runs=78
  [3] shell4  ticks=690  runs=77
  [4] alpha   ticks=170  runs=85
  [5] beta    ticks=110  runs=56
> kill 4
killed thread 4 (alpha)
```

`ticks` and `runs` are both climbing, which shows these threads **really take turns on the CPU**, rather than "registering and
lying there"; after `kill`, `debug pmem` shows the free page count back at the pre-run baseline — the stack was borrowed, and it gets returned.
(The baseline numbers vary with memory size: boot uses 19 resident pages + page-table pages for the identity mapping; the 4 shells each use 2 stack pages,
and thread 0 uses the boot stack, which doesn't come out of the pool.)

### Multiple shells: one hangs, three more carry on

4 shells means 4 kernel threads (0 is the boot thread, the other 3 are `spawn`ed in `kmain`).
Which shell owns the keyboard is tracked by a single `sh_active`, and **Ctrl+← / Ctrl+→ switching happens directly in the keyboard interrupt handler** —
this is crucial: if switching depended on "the active shell responding", a shell stuck inside `run HANG` could never be switched away from;
by doing it in the interrupt, whoever presses the key can hand the keyboard to somebody else.

Each shell has its own line buffer and current directory; on a switch:
- Print `--- shell N ---` as a separator, then redraw the prompt and **the half-typed line you never finished**
- Half-typed input follows the shell: type half a line in shell 1 → switch to shell 2 and do something else → switch back and the half line is still there; press Enter and it executes
- **Each shell runs its own program** (all that address-space state is now per-thread): one shell sits in `run HANG`,
  switch to another and `run HELLO.BIN` works fine, no fighting
- Shell threads themselves **cannot be killed** (`kill 0`~`kill 3` won't tear down the thread): the keyboard hangs off them, and killing one would leave nobody to receive keys;
  but `kill <tid>` stops the program it is running, and even an infinite loop in ring 3 gets collected by the next timer interrupt

```
> shell
shells: 4
(you are in shell 1)
  [0] shell    <- keyboard here
  [1] shell2
  [2] shell3
  [3] shell4
Ctrl+Left / Ctrl+Right switches, or: shell <n>
> shell 3
--- shell 3 ---
3>
```

To see "a hang doesn't affect the others" with your own eyes: `run HANG` (a demo program that prints a line at the start and
**spins 24 rounds, about 40–60 seconds, then exits by itself**), and while it's hogging that shell, `Ctrl+→` escapes to another shell where `echo`
still responds — that's the point of multiple shells. To reclaim the stuck one early: in another shell, `kill 0` (thread number from `ps`),
and the kernel will tear it down at the next timer interrupt.

> Why isn't `run HANG` a real infinite loop: a demo has to have a beginning and an end, so the test suite can keep using that shell.
> To try "never comes back", bump `HANG_ROUNDS` in `progs/HANG.asm`, or delete the two lines
> `dec dword [rounds]` / `jnz .loop` — then collect it with `kill 0` from another shell.

![4 shells switching between each other](screenshot-shells.png)

`shell` lists them, `Ctrl+→` switches to shell 2 to type a command, `3> date time` is shell 3 running something;
the last two lines are the "half-typed command" demo: in shell 1, `echo half-typed line survives` is typed without pressing Enter, then you switch away,
and when you switch back it's still there (the line below the prompt); press Enter and it executes.

### Pinyin input method: Shift toggles Chinese/English, type pinyin and pick characters

Press **Shift** once to switch to Chinese (press again to switch back to English), then type pinyin:

```
> shuang
（屏幕最底两行浮出候选条,命令行保持不动）
 1.双 2.爽 3.霜 4.塽   1-9 pick  space pick first Esc cancel
 拼音: shuang
> 霜
```

After picking a character, the pinyin is erased in place and replaced by the Chinese character, the command line **neither wraps nor redraws**, and the candidate bar (two lines) simply disappears.
When there are more candidates than fit on one page, the page number appears on the right of the first line; press `,` / `.` to page in place and redraw the bar:

```
> xiang
（底行:1.想 2.向 3.像 4.相 5.乡 6.项 7.象 8.香 9.响  ,/. page 1/4  Esc cancel）
```
(author's note: Japanese and Korean aren't happening — they're not my native language anyway. Traditional Chinese would be doable, but then you can't avoid the phonetic input; Cangjie and Zhuyin are beyond me)
Digits 1-9 pick the candidate at that position **on the current page**, space picks the first candidate on the current page, `,` / `.` go to the previous / next page
(the page number is hidden when there is only one page of candidates), Esc cancels; candidates are ordered by **word frequency** (most common first).
The data lives on disk at `/SYS/PINYIN.BIN` (6000 common characters, 400 syllables; a syllable like `ji` has 11 pages), generated by
`tools/mkpinyin.py` using wordfreq + pypinyin; to swap the word list, run `make pinyin` (needs those two Python packages).
If the file isn't on disk, the input method quietly turns itself off and nothing else is affected.

![Pinyin input method](screenshot-ime.png)

### rc.conf: read config at boot, run services according to it

`/SYS/RC.CONF` is just lines of `key=value` (the BSD / OpenRC style, not systemd sections).
At boot the kernel reads it, prints `boot_msg`, and uses `autostart` to decide whether to start the enabled services;
the single command `rc` shows the config, lists services, starts services, re-reads a file you just wrote, and there's even an event ledger with PIT ticks. Details and every key are in [rc-conf.md](rc-conf.md).
The display name defaults to `KKernel`, and can be customized in `RC.CONF` with `osname = your name` (boot prints one line `os: <name>`).

![rc.conf service list and event ledger](screenshot-rc.png)

### Prompt styles: a `style` command for when you get bored

Staring at the same `>` every day really does hurt the eyes, so the prompt became swappable (since 0.14 the **default is a kaomoji**):

```
(・ω・)> style
prompt style: kao   (style plain|moe|dos|c64|kao 换样式,默认 kao;RC.CONF 里写 style = moe 开机生效)
(・ω・)> cat nosuch.txt
file not found
(；ω；)> ls
BIN  <DIR>
LIB  <DIR>
...
(・ω・)>
```

| Style | What it looks like |
|---|---|
| `kao` (default) | yellow `(・ω・)>` / `(・ω・)docs>`; the face turns red `(；ω；)` after a failed command, and recovers on the next input (ps: kawaii~) |
| `plain` | `>` / `docs>` / `2>` |
| `moe` | pink `かいかーねる>`; file-not-found and unknown-command messages also become snarky lines |
| `dos` | `C:\>` / `C:\docs>` |
| `c64` | `READY.`, one command per line, that Commodore 64 BASIC feel |

Add a line `style = moe` (or `kao` / `plain` / `dos` / `c64`) to `RC.CONF` and that style is used from boot (see [rc-conf.md](rc-conf.md)).
The cute strings aren't made up nonsense: the font includes half-width katakana and CJK; 0.13 also added Greek/punctuation/math/arrows/geometric/symbol ranges to the font,
so kaomoji have a lot more material to work with.

![Kaomoji prompt](screenshot-style-kao.png)

![Moe-style prompt](screenshot-style-moe.png)
