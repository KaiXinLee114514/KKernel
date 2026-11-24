[简体中文](zh-CN/roadmap.md)

# Roadmap and To-Do

> Originally README §10–§11.

## Next Up: What to Play With

**Just landed: PCI bus enumeration** — a single `pci` command lists every device in the machine (vendor:device, class name, IRQ), and `pci 0:1.2` shows one device in detail; on QEMU you see the whole set at once: IDE, USB (UHCI), display, NIC (see [docs/pci.md](pci.md)). **This is the road paved for USB** — to read a USB keyboard you first need to know where the USB controller is and where its register window (that I/O BAR) is mapped.

Before that came **ring 3 user mode + the rc.conf service/event store** — programs run at CPL=3, can't touch kernel pages, and die if they do while the kernel stays calm (see "Programs run in ring 3" in the [architecture doc](architecture.md)). Before that, **multiple shells**: four shells, each a kernel thread, `Ctrl+←/→` switches focus in the keyboard interrupt, and when one is stuck in `run HANG` another keeps working (see "Multiple shells" in the [architecture doc](architecture.md)). One step before that: kernel threads + preemptive round-robin (save state and switch stacks in the PIT's IRQ0, `ps`/`spawn`/`kill`) and `date` (reading the CMOS real-time clock).

Things you could pick up next:
- **Blinking cursor**: the cursor is solid now; with a 100 Hz tick you just flip it in `pit_irq` (not done yet)
- **`settime`**: write the time to CMOS (must mask the NMI bit first and dodge the clock update; see [docs/known-issues.md](known-issues.md) §8)
- **One address space per thread**: ring 3 exists, but the address-space state is still global (only one shell runs a program at a time); `space_*` has to be attached to threads before several processes can run at once
- **The next layer of rc.conf**: `RC.CONF` (key=value) already manages "which programs run at boot" and the event log (see [docs/rc-conf.md](rc-conf.md)); still missing are dependencies (`after=` / `requires=`), `stop` (services are one-shot programs) and retry-on-failure

## Not Done Yet (Good Places to Start)

- **Long file names (VFAT)**: `rm` / `rmdir` / `mkdir` / subdirectories all work now, but names are still 8.3 (short names); VFAT long names are a separate directory-entry encoding and deserve their own round
- **Deleting from programs**: `rm` is a shell command; `mini-libc` still has no `remove()` (so the editor can only overwrite an existing file, not delete the old one)
- ~~Protecting the kernel from programs~~: done (ring 3 + TSS + U/S bits, see the [architecture doc](architecture.md)) — the next step is to keep the kernel window out of the program's page directory entirely (right now we still copy the kernel page directory, just with U/S=0)
- ~~The next layer of virtual memory~~: demand paging, **copy-on-write (fork)**, **swap page replacement**, **automatic user-stack growth**, **large anonymous heap + `anon_alloc`** are all done (see the swap section of the [architecture doc](architecture.md)); what's left is **swap compression / persistence / per-process quotas**, plus the "holes in the window get pages too" fault-in-on-access optimisation
- **The next layer of multiple shells**: right now **only one shell can run a program at a time** (the address-space state is global), and a killed thread doesn't release its address space either (see [docs/known-issues.md](known-issues.md) §9). To let four shells run programs at once, `space_*` has to move onto threads and threads need "clean up on exit"
- **Truly concurrent pipes**: today it's a sequential buffered pipe ("finish A, then feed B", see [docs/pipes.md](pipes.md)); buffers are borrowed from the page pool and returned when done. To write-while-reading like Unix (streaming large output, `tail -f`), the scheduler must first run several ring-3 programs at once (one address space per task) + pipe blocking/wakeup primitives
- **The next layer of the scheduler**: priority scheduling, blocking/wakeup and locks (A3/A4) are done; what remains is threads sharing one address space and still being in kernel mode; moving toward "real processes" means ring 3 + TSS + per-thread page directories (the item above)
- **Blinking cursor**: possible now that there's a timer (the cursor is solid; just flip it in `pit_irq`)
- **Finer-grained `sleep`**: it sleeps in whole seconds now (the tick granularity is already 10 ms, the shell just only accepts whole seconds)
- **ELF loading**: programs are flat binaries read to a fixed address (no segments, no relocations), and they don't grow on demand; `malloc` exists (the one in mini-libc) but the heap is a fixed size
- **USB**: PCI enumeration can already see QEMU's UHCI controller (00:01.2, BAR4 = I/O `0xC040`) and an e1000 NIC; the path on the diagram is **UHCI init → EP0 control transfers → HID keyboard → EHCI + mass storage** (why this order and what each step trips over is at the end of [docs/pci.md](pci.md))
- **Mouse (IRQ12)**: a PS/2 mouse has a few more traps than the keyboard (you must send commands and read 3-byte packets)
- **`date` is read-only and has no timezone**: no `settime` (writing CMOS means masking the NMI bit and dodging the clock update; see [docs/known-issues.md](known-issues.md) §8); what it prints is the raw number in CMOS, with no timezone conversion
- **Multi-floppy edition (mfd)**: the floppy line has "retired", but if you want to go full retro you could build an old-style distribution with **one disk per role** (like the DOS era, where installing software meant "please insert disk 2"):
  1.44 MB per disk = 2880 sectors, and a 256 KiB kernel eats 512 of them, so the budget has to be tight. It would be **a modification of the floppy edition** (reusing the CHS read path in `boot/boot.asm`, not a fresh start). Disk roles (the label lives in sector 0 of each disk, along with the `MFLP` magic and the disk number):

  | Disk | Label | What goes on it | Size now |
  |----|------|--------|-----------|
  | 1 | `minimal system` | boot sector + stub + kernel (with the built-in 416-glyph subset), boots straight into the shell | 128 KiB |
  | 2 | `disk read/write` | FAT12/16 read/write + program disk (HELLO/COUNT/CALC/TOUCH/EDIT/VI/PLAY) + demo texts (ZH/EN/JPKR) + `RC.CONF` | ~110 KiB |
  | 3 | `more characters (1/2)` | first half of the full font `full-kkf.bin` (1.8 MB doesn't fit on one floppy) | ~893 KiB |
  | 4 | `more characters (2/2)` | second half of the full font | ~893 KiB |
  | 5 | `add-ons` | things added later (player/games/demos); numbering can continue | spare |

  The hard part isn't reading disks (the ATA/CHS machinery is ready-made), it's **swapping disks**: after "please insert disk 2" you have to detect that the medium changed — BIOS `INT 13h AH=16h` media-change detection is unreliable, so you usually fall back to the crude method of "read sector 0, verify the `MFLP` magic and disk number"; if the wrong disk is inserted, say "this one is `more characters (2/2)`, not the one I asked for". `make mfd` generates disk1..5 in one go, and in QEMU you can swap disks by hand with the monitor's `change floppy0`
- **x86_64 (long mode)**: this is 32-bit protected mode, and all 12.7k lines of assembly are 32-bit. Going 64-bit isn't "make the registers wider", it's a **rewrite**: PAE + 4-level page tables (PML4/PDPT/PD/PT), long-mode GDT/TSS + IST, IDT gate format, no more `pusha/popa`, the SysV calling convention (first 6 args in rdi/rsi/rdx/rcx/r8/r9), doubled struct sizes (TCB/BOOTINFO/directory-entry pointers), and programs and libc rebuilt as 64-bit. The recommendation is **not to convert in place** but to start a new tree (branch or new directory) and climb milestone by milestone: ① boot into long mode and print → ② interrupts/keyboard → ③ paging + heap → ④ FAT16 read → ⑤ ring 3 → ⑥ scheduler. Keep the old tree as the "it runs" demo and let the new one catch up slowly
- **Loading the kernel from disk**: the kernel is still read by the boot sector from fixed LBAs; there's no "load the kernel from a filesystem"
