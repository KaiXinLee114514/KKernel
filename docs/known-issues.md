[简体中文](zh-CN/known-issues.md)

# Known Issues (and Where They Stand)

This file records only **confirmed problems that are still unfixed** — so the next person (or we ourselves) doesn't step on them again, and so we don't forget them as "probably fine".

## 1. Framebuffer terminal: garbled screen after scrolling (fixed, 2026-10)

**Long output now scrolls cleanly**: after `cat DOCS/README.TXT` (2 KB+ of Chinese) scrolls several screens, the screen is still aligned line by line and the screen reader still recognises it (the hd suite has a dedicated assertion, "the screen is still readable after long Chinese scrolling"). This section stays as a record.

The symptom at the time: after `cat DOCS/README.TXT` the screen was garbled — old content mixed with `?`, unreadable character cell by character cell. It turned out to be **two** problems:

1. **Cell alignment**: 600 pixels ÷ 16 = 37.5; `fb_newline` used to clamp the bottom to `600-16 = 584`, and `584 % 16 = 8` — once scrolling started, every new line sat 8 pixels lower than the line it replaced, so "two generations of text overlapped" (in QEMU, half-line ghosting; in VirtualBox the phase drifted with every scroll until the whole screen was garbage). Now the screen height is first rounded down to a multiple of 16 (`fb_height & ~15` → 592), then one line is subtracted ⇒ the cursor always lands on a cell boundary, and the bottom 8 pixels go unused.
2. **It looked like "broken rendering", but half of it was a bad test**: writing to the VBE framebuffer is **MMIO** in QEMU — one memory operation per pixel; painting a full screen of 2 KB of Chinese takes several seconds. The harness used to "sleep 0.9 s after typing the command" and then grab the screen; what it captured was often **half-drawn** — which showed up as "17 assertions failed". Now it waits for the screen to go quiet (two consecutive grabs identical) before capturing, and assertions poll; see [pitfalls](pitfalls.md) 6.34.

**A bonus**: after fixing the alignment + waiting for the paint to finish, the same assertions all went green, and there's no need to "look at large files in several chunks" any more.


## 2. Buzzer: inaudible in VBox, durations are estimates, no volume control (known, not fixing this time)

**Current state**

1. **VirtualBox doesn't emulate the PC speaker.** `run PLAY MYSONG.TXT` runs perfectly in VBox (the score is parsed, the screen scrolls), it just makes **no sound** — VBox has never implemented the PIT channel 2 + `0x61` PC-speaker emulation (it only knows AC'97/HDA sound cards). QEMU has it, but **since 7.0 it doesn't attach an audio backend by default**; you have to pass `-machine pcspk-audiodev=snd0 -audiodev pa,id=snd0` explicitly for it to beep (the full command is in [quickstart.md §8](quickstart.md)). The test QEMU runs with `-display none` and no audio backend, so **automated tests can't assert sound** (the old "`--list` parses note names" assertion was withdrawn along with the sample scores).
2. **Durations are estimates.** No IRQ0/timer was added this time: `beep`'s "milliseconds" are a busy-wait on an instruction loop (`SPKR_LOOPS_PER_MS` in `kernel/speaker.asm`). On local QEMU (TCG) a nominal 300 ms actually waited 289~318 ms (±5%, jittering with host load); another machine / KVM / real hardware can differ by several times. Pitch is **unaffected**: that's computed by the PIT hardware dividing 1193182 Hz, the same on any host.
3. **The PC buzzer is a square wave and has no volume control.** The hardware only has "on / off" (the two bits at `0x61`), and at full volume it's harsh, so the image **ships no built-in scores** (the player is there; write your own). To make it quieter you can only act on the host side: turn the system volume down, or in the host mixer (`wpctl` / `pavucontrol`) turn the QEMU stream down separately (start it with a recognisable name via `-audiodev pa,id=snd0,out.stream-name=KKernel`). ★ **There is no volume parameter on the QEMU side**: `-audiodev pa,id=snd0,out.volume=0.2` is wrong and QEMU refuses to start (`Parameter 'out.volume' is unexpected`, measured locally on 10.0.11; upstream QAPI's `AudiodevPerDirectionOptions` only has frequency / channels / voices / format / buffer-length / mixing-engine). If you want no sound at all, switch backends: `-audiodev wav,id=snd0,path=/tmp/kk.wav` (record only, no playback) or `-audiodev none,id=snd0`.

**To do it accurately (next step)**

Read **PIT channel 0**'s counter in `speaker_beep` as the time base (latch: `out 0x43,0x00`; then read `0x40` twice), no interrupts needed, microsecond precision. The cost is assuming channel 0 is running (it is after the BIOS boots) and a few dozen more lines of state machine — skipped this time on "toy OS, sounds right is good enough".

**If it sounds wrong**

Change only `SPKR_LOOPS_PER_MS`: if it's clearly too slow overall, lower it; too fast, raise it. Pitch (frequency) needs no adjustment.

## 3. `rm` / `rmdir` work now; long file names and an in-program delete are still missing

Deletion landed in 2026-10: `rm <file>` deletes a file, `rmdir <dir>` deletes an empty directory (refuses if not empty). Two rules worth remembering:

- A directory entry isn't "cleared to 0" but has its first byte set to **`0xE5`** — `0x00` means "everything after this entry is empty", and writing 0 would hide every sibling file later in the same directory.
- Directories must go through `rmdir` separately, and must be confirmed empty first: deleting a directory entry outright orphans every file on its cluster chain (same lesson as the page pool).

Still missing: **long file names (VFAT)** are a separate matter; `mini-libc` still has no `remove()` (there's no delete in the program API, so the editor's save can still only overwrite a same-named file).

## 4. `exit()` in programs jumps back to the shell via a setjmp trampoline

`lib/crt0.asm` stores a trampoline; `exit()` uses `longjmp` to jump back and then `ret`. That means, one, there's no "unwind", and two, cleanup code registered by the program never runs. Doing it properly requires the concept of a "process" first (today's program is just a chunk of code called from the kernel).

## 5. Demand paging "gives pages on access", and a few things aren't done (not bugs — unwritten)

Programs now run with **demand paging**: the kernel only builds empty page tables, and a page is filled in when the program touches it (see README §5). The following are deliberate taste calls, not breakage:

* **No page replacement / swap / copy-on-write**: once a page is filled in it stays until the program exits;
* **Given on "access", not on "use"**: a program that merely reads an address inside a hole in the image window still gets a zero page (the fault handler only looks at which window CR2 falls in, not whether the page means anything);
* **No self-growing stack for programs**: the stack is still the shell's stack = 0x90000 in the kernel's page tables; nothing catches a program's stack overflow (same as before);
* **The windows are fixed**: the image window is 96 pages (384 KiB), heap window pages are decided at runtime (`space_heap_pages`, default ~560 pages = 2.2 MB); program images are capped at 384 KiB and `malloc` only slices within that heap — a bigger heap means changing the memory layout (see "the three variable things" in the README);
* **RPL/permission bits are ignored**: faulted-in pages are all "user read/write" (flags = 3), but the kernel window is still identity-mapped into the program's address space, so programs can still modify kernel memory — blocking that needs ring 3.

## 6. A "wild address" during fault-in still red-screens (by design)

If CR2 isn't in the image window/heap window (the program sent a pointer flying, or the stack overflowed into another segment), `page_fault_try_handle` returns "not my problem" and the usual `isr_common` red-screen panic follows (exception name / error code / EIP / CS / EFLAGS / CR2, the full set). So seeing `EXCEPTION 0E` doesn't necessarily mean demand paging broke — look at **CR2** first: inside a window means the fault-in logic is at fault; outside means the program itself stepped into thin air.


## 7. The timer only goes as far as "counting seconds" (not a bug — unwritten)

`kernel/pit.asm` makes 8254 channel 0 fire IRQ0 at 100 Hz; the interrupt handler only `inc`s a tick counter, and `uptime` / `sleep` are built on it. What already works: second-level timing, and `hlt` sleeping without burning CPU (check the `qemu-system-i386` process while idle — CPU usage is near 0; both `kbd_getchar` and `pit_wait_ticks` `hlt` for interrupts rather than spinning). Not done yet:

- **10 ms granularity**: `uptime` only reports whole seconds, `sleep` only accepts whole seconds. For finer, change `PIT_DIV` (11932 ≈ 100 Hz); the cost is more frequent interrupts.
- **The 32-bit tick wraps**: at 100 Hz that's 497 days per cycle. `pit_wait_ticks` compares using a "difference goes negative" test, so it won't hang at wrap; but `uptime`'s seconds restart from 0 (toy system, fine for now).
- **No preemption yet**: `pit_irq` only bumps the counter + sends EOI, it doesn't switch stacks — an infinite loop can still monopolise the system (`run` going wild still means a reboot). The next step is **preemptive kernel threads**, and the hard part is that the kernel is **not reentrant**: globals are shared, `hlt`-waiting-for-a-key and state machines like `space_live` all live on the same stack, so you first have to draw the line around "what may be preempted" and then save/switch context in `pit_irq` (the comments are already there).
- **No nested interrupts**: interrupt gates clear IF automatically, so `pit_irq` won't be interrupted by the keyboard (or vice versa). Both handlers are tiny today, which is fine; longer handlers would need the "fast top half, slow bottom half" arrangement.


## 8. The real-time clock (RTC) is read-only, and has no timezone (not a bug — unwritten)

`kernel/rtc.asm` reads the date and time from CMOS `0x70`/`0x71` (the shell's `date` is built on it). What's already right: wait for UIP (update-in-progress) to clear before reading, **read twice and compare** (retry if a second ticked over between the two reads, at most 3 tries), BCD → binary, 12-hour PM bit to 24-hour, guess 20xx if the century register `0x32` can't be read, and finally range checks (seconds ≤ 59, month ≤ 12, and so on). The following are **deliberately not done**:

- **Read-only, no writes**: there's no `settime`. Writing to the RTC means masking the NMI bit (bit7 of `0x70`) first and dodging the clock's own update; a toy system skips it.
- **No timezone**: `date` prints the number stored in CMOS. A PC's RTC usually holds **local time** (that's basically how it works when dual-booting with Windows), while QEMU defaults to **UTC** — so the window targets `make run` / `make hd` all add `-rtc base=localtime` to make the guest agree with your watch; the test harness deliberately doesn't (it needs host UTC as the reference for assertions).
- **Century is a guess**: some machines don't implement register `0x32`; if it can't be read, assume 20xx.
- **Precision**: normally the error is far below 1 second; if all three reads are unstable, the boot line adds `-- read was unstable, values may be off by a second`; if the time is clearly wrong (the clock was never set, say) it prints `-- values look wrong (clock not set?)`.
- **No DST / leap seconds**: not a second more, not a second less.
- **The tests can't recognise Chinese weekdays**: screen OCR compares pixels against font bitmaps, so `星期三` becomes `??????` — the suite only asserts the ASCII part; the weekday has to be checked by eye in a screenshot (see [pitfalls](pitfalls.md) 6.12).


## Three Traps Found Running Under VirtualBox (2026-10, two fixed)

Same kernel, same image: everything fine in QEMU, garbled screen + crashes in VirtualBox. We tracked each one down:

### 1. Newline clamped the cursor to "half a cell" (fixed)

`fb_newline` used to clamp the cursor to `fb_height - 16`. At 800×600 that's **584**, and 584 % 16 = 8 — not on a character cell boundary. So as soon as scrolling began, every new line was 8 pixels below the line it replaced, and the screen showed "two generations of text on top of each other" (a screenshot shows the "ghost output" strip on the right immediately).

Fix (committed): round the screen height down to a multiple of 16 first (`and ebx, ~15`), then subtract one line — the cursor always lands on a cell boundary.

### 2. Multi-sector PIO reads are unreliable in VirtualBox (worked around with "one sector at a time")

Symptom: in VBox the font fails to load from disk (only the built-in 416 ASCII glyphs remain → all Chinese becomes missing-glyph boxes); `cat` on a Chinese file writes **the same value over the whole kernel area**, then a triple fault and the VM goes straight to Guru Meditation.

Cause: `ata_read_sectors` issues one command for several sectors and relies on "wait for one DRQ per sector". Under VBox it times out waiting for DRQ on some sector → returns failure, **but the drive is still holding untransferred data**; the next read command accepts the leftover data as new data → directory entries/cluster chains garbage → reading the disk with a wild cluster number/length → memory stomped.

Current state: `ATA_MAX_CHUNK = 1` (one sector per command); reads and writes are both stable, at the cost of a few extra seconds of font loading. The real fix: on failure, drain the data port first (`in` until DRQ clears) then retry, or retry with smaller chunks after a failure.

### 3. The missing-glyph (Chinese) rendering path has a second crash point (unfixed)

After limiting disk reads to a single sector, `cat DOCS/NOTES.TXT` prints the first line (ASCII) and then still crashes: registers get wild values and the stack climbs from 0x90000 all the way to 0x131BC (corrupting the first 32 KiB of the kernel image). The suspected spot is the "missing glyph" branch of `fb_putcp`: after drawing the box it only does `add [fb_cur_x], 8`, **without the right-edge overflow check normal glyphs get** — needs further investigation.

## Debugging Tools (Added This Time, Kept)

* One extra boot line: `fb: phys=... w=... h=... pitch=... bpp=...  modeinfo: bytesPerScanLine=... linBytesPerScanLine=... vbe=...` — see at a glance whether the framebuffer geometry the VM handed us is right (QEMU 0xFD000000 / VBox 0xE0000000, otherwise identical);
* A **call-record ring** in `ata_read_sectors` (64 entries: LBA/sector count/target/caller); after a crash, `VBoxManage debugvm <vm> dumpvmcore` the memory and you can read out who read/wrote the disk and stomped memory;
* A **safety gate** in the same function: absurd sector counts, or "target + length" running past the identity-mapped region (0~ident now), are rejected outright — better a "read failed" than the kernel burying itself.


## Floppy Boot: Used to Halt in the Boot Sector (fixed, 2026-10-06)

**`make test-fda` is green now**; this section stays as a "record of the trap". The symptom then: after booting the floppy image the screen was completely black (720×400 text mode, nothing printed after clearing), and QEMU's monitor showed the CPU at `EIP=0x7D78` (the `halt16` in the boot sector), `HLT=1`, real mode ⇒ the disk read had failed and halted after 3 retries; the kernel was never loaded. The root cause was **two** overlapping problems:

1. **Floppies shouldn't use EDD**: the BIOS often reports "LBA extended read supported" for floppies too, but a floppy's EDD read **fails when it crosses a track** (1.44 MB has 18 sectors per track; reading 8 sectors at once easily crosses one). ⇒ `boot_drive < 0x80` always goes CHS, and the CHS branch clamps a single read to the track boundary (`read_chunk` in `boot/boot.asm`).
2. **ISA DMA can't cross a 64 KiB physical boundary** (floppies use DMA; hard disks' EDD doesn't ⇒ this never showed up on hard disks): the destination `0x1F200` plus 4 KiB crosses `0x20000`, and the BIOS errors out immediately. ⇒ before each read, clamp the sector count to "how much is left in the current 64 KiB page"; also **don't loop a fixed number of times** — how many sectors the BIOS actually reads is up to it, so check whether `dap_lba` has reached `KERNEL_LBA + KERNEL_SECTS`.

How we confirmed the fix: ① `make test-fda` green 7 runs in a row (19 assertions); ② dumped the guest's 128 KiB kernel area starting at `0x10000` with QMP `pmemsave` and compared it byte-for-byte with the image — only 1485 bytes differ, in 610 runs, and **the longest run is 14 bytes**, never a whole sector ⇒ all differences are data the kernel changed at runtime (`.bss`, shell buffers); all 256 sectors were read correctly. ③ On a boot-sector read failure the failing LBA is left at `0x7B00`, to make the next investigation easier.

**Test harness** problems fixed along the way (the other side of the same trap):
- The default screendump path used to be the fixed `build/_shot.ppm`, so two test rounds (or me and the suite) running at once would **read each other's screens** — the hard-disk round's "how the disk is read" assertion occasionally read `boot disk: CHS fallback` off the floppy screen. The default path now includes the process ID (`/tmp/kkernel-shot-<pid>.ppm`).
- The dozens of boot lines are painted onto the VBE framebuffer one line at a time by the kernel (MMIO is slow); with only a 2-second wait before grabbing, a busy machine could capture a **half-drawn** screen ⇒ occasional false failures. Now it waits for the last line (`type "help" for commands.`) to appear before asserting one by one; a real failure OCRs the screen and saves it to `build/screen-fail.png`.


## 9. Boundaries of the Scheduler (Kernel Threads + Preemptive Round-Robin)

`kill` comes in two flavours: a **plain kernel thread** is killed outright — `sched_kill` first copies its whole TCB into `kill_space`, then `cmd_kill` returns its page directory / private page tables / image staging area to the page pool from the snapshot; a **shell thread** (0..3) can't have the thread itself killed (the keyboard hangs off it), but whatever program it's running can be — another shell sends it a `KILLREQ`, and the next time the timer interrupts it from ring 3 it winds down **on its own kernel stack** (`irq0_stub` jumps straight to `run_resume_kernel`), pages returned to the pool as usual.



`kernel/sched.asm` is a toy round-robin scheduler, deliberately tiny. The following "missing" features are design choices, not omissions:

- **No priorities, no block/wake**: 6 slots, 20 ms per slot, pure round-robin. A thread that wants to "wait a while" can only busy-wait or `hlt` (like `sleep`); there's no sleep queue and no `yield` semantics
- **No "one address space per thread"**: all threads share the kernel page directory. CR3 is saved/restored with the thread, so a preemption that happens while "running a program" (CR3 switched) doesn't cross wires, but threads still share one address space
- **Still kernel mode**: no ring 3 / TSS / syscall gate; threads are on equal footing with the kernel and anyone can modify kernel memory
- **Printing interleaves**: the terminal's cursor position/colour is global state, so two threads printing at once interleave; when a thread prints to the screen while you're typing a command, even the prompt and echo get garbled (the command still executes — it's the display that's garbled, not the input buffer). Clean printing needs "interrupt-disabled critical sections" or a terminal lock
- **No lock primitives**: no spinlocks / semaphores. We avoid the issue by "threads don't share mutable state"
- **Stack fixed at 2 pages (8 KiB), unprotected**: a kernel stack overflow steps straight onto the neighbouring physical page (identity-mapped, nothing stops it)
- **`kill` takes effect immediately**: it doesn't reclaim resources (threads have none anyway), but if it happens to kill a thread mid-print, half a line is left on screen
- **The address space is already split per thread**: `space_pd` / `space_pt` / `space_live` / image size / fault counts all live in each thread's TCB, `space_cur` follows `sched_pick`; `TSS.esp0` is also set per thread, so two shells running ring 3 programs don't stomp each other's stacks. Two shared points remain: ① the load lock — "read file + expand + build space + copy arguments" runs one thread at a time (the staging area `PROG_ADDR` / `PROG_ARG_STR` is still global); real parallelism starts once the program is running; ② keyboard and screen — the foreground shell's program grabs the keys, background programs can't see the keyboard (per-shell consoles are the next stage)
- **`kill`ing "a thread that's running a program"**: the thread's stack is returned by `sched_kill`, the address space is copied into `kill_space` before the slot is cleared, and `cmd_kill` tears it down with `space_destroy_at`, so no pages leak. Only the tiny window "snapshot copied, not yet torn down" remains (single CPU, can't disable interrupts for the whole thing), and the probability of truly concurrent kills of the same slot is negligible
- **A stuck shell is rescued by another shell**: the demo program `run HANG` occupies thread 0; `Ctrl+←/→` over to another shell and `kill 0` stops its program (`shell 1`'s own keyboard is dead at that point, so the command has to come from another shell). For a shell "running a program", `kill` only kills the program, not the thread. If the program is stuck in a blocking kernel call (waiting for the keyboard, say) rather than spinning in ring 3, `KILLREQ` only takes effect once it's back in ring 3

## 10. Boundaries of ring 3 (User-Mode Programs)

Programs really do run at CPL=3 now (`kernel/tss.asm` rebuilds the GDT + TSS, program page-table entries carry the U/S bit), but this is "enough to explain what protection is", not a complete user-mode process:

- **Only one syscall gate**: `int $0x30`, 15 functions + number 15 "exit". No `sysenter`/`syscall`, no general convention for passing pointers into the kernel — any string the kernel hands to a program has to be copied into the program's own pages first (that's where the argument page at heap-top-0x2000 comes from; forget to copy = the program crashes on first read, see [pitfalls](pitfalls.md) 6.20)
- **The user stack is one page (4092 bytes)**: stack top = heap top-4; below that you leave the window → page fault and killed. No "program grows its own stack", no friendly guard-page message (just an ordinary page fault)
- **The trampoline page occupies a fixed address**: the `ret` at the end of a program returns to the "exit" syscall at `0x17F000`; a program **must not use** `0x17F000` as a data buffer (EDIT's filename buffer used to live there; after the layout change it crashed on save — on exit the `ret` jumped into the page overwritten by the filename; it was moved to `0x17E000`)
- **No `fork`/`exec`/`wait`, no signals**: each shell runs one program; exit is exit
- **No privileged instructions**: `hlt` / `cli` / `sti` / `in` / `out` / `lgdt` … raise #GP, handled as "the program crashed" (the HANG demo used `hlt` to sleep; it tripped on this the day ring 3 landed)
- **A few "one per system" things remain in the kernel**: the load staging area (PROG_ADDR/argument block) is serialised by a load lock; keyboard and screen exist once (§9); the page directory/private page tables/staging area are already per-thread, and `kill` reclaims them
- **No page replacement / swap / copy-on-write**: holes in the window are "faulted in on access"; touched pages stay until teardown
- **Kernel threads are still ring 0**: demo threads spawned by `spawn` and the shell threads are kernel mode; only programs entered via `run` are ring 3. "One address space per thread + everything in user mode" means doing all of the above together
- **Shell threads themselves can't be killed**: `kill 0`~`kill 3` don't tear down the thread (the keyboard hangs off it; kill it and nobody collects keys), they only send a "wind down" request to the program on that thread: a ring 3 infinite loop is taken out at the next timer interrupt; a program stuck in kernel mode (inside some API) only takes effect once it returns to ring 3. There's also no "restart a shell"

## 11. Boundaries of PCI Enumeration (added 2026-10)

The `pci` command lists every device on bus 0, but it's a "viewer", not a full bus driver:

- **Only scans bus 0**: buses behind bridges (behind PCIe roots, CardBus and the like) are invisible; real hardware with multiple bus levels needs recursive scanning.
- **The IRQ number is read but not wired up**: `irq 11` is just a number in configuration space; the IDT has no corresponding gate, so USB can only poll for now. Using interrupts means untangling PIRQ routing first (and UHCI defaults to IRQ10/11 on the 8259).
- **I/O BARs don't report a size**: only the base address (writing all 1s to measure the size wedges QEMU's whole configuration space, see [pitfalls](pitfalls.md) 6.32).
- **Memory BAR sizes are occasionally too large**: we measured VGA's BAR2 as 64 KiB while QEMU's `info pci` says 4 KiB — when you actually use that region, trust the device manual.
- **Configuration space only flips three switches**: enumeration enables I/O / MMIO / Bus Master on each device, leaves every other bit alone, and doesn't write BARs.
- **No hotplug**: one scan at boot; devices plugged in later are never noticed (that needs the ACPI/PCIe machinery).

## Pinyin Input Method

- **Single characters only**: no phrases, no suggestions, one character per syllable.
- **Candidates page**: 9 per page, `ime_page` tracks the current page; when there's more than one page the hint shows a page number like "`1/4`", and **`,` goes to the previous page / `.` to the next** (stops at either end); within a page the numbering is always `1`-`9` (matching the `1-9 pick` keys); after picking / cancelling / starting a new pinyin it returns to page 1. Arrow keys weren't used because they're ESC-prefixed and get lost or mangled into other keys in the shell.
- **The word list is "high-frequency single characters"**: wordfreq's Chinese frequency list, top 6000 characters — not a textbook "common characters" list; rare characters not being found is normal (400 syllables cover 6000 characters, ~15 per syllable on average; the biggest is `ji` with 92, 11 pages).
- **Shift is the toggle**: other platforms usually use Ctrl+Space; here Shift was chosen for reachability, at the cost that **pressing Shift alone toggles the mode** (combinations still work; pressed-with-another-key doesn't count).
- **The candidate bar takes the bottom two screen rows**: it's drawn "floating" over the last two rows (one row of candidates, one row of pinyin echo; the pixels of those two rows are saved first and restored after drawing); if the line being edited falls inside them, everything shifts up one row; but if the page pool is too tight to get the 104 KiB restore buffer, it falls back to the old drawing method (print candidates on a new line, redraw the command line after picking).
- **Paging/cancel redraw in place**: the bar floats over the bottom two rows; paging and cancelling erase and redraw, leaving nothing behind on screen.
