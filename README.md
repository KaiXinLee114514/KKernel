English | [简体中文](README.zh-CN.md)

# KKernel

**A 32-bit x86 operating system written from scratch.**
(W-what?! I-I didn't write this README for you... it just happened...! Hmph! zako! baka!! ((つд⊂)))
Boot sector, protected mode, paging, preemptive scheduling, graphical terminal, FAT filesystem, device layer, pipes, multiple shells, an in-system C compiler, USB mass storage — all implemented by hand, without forking any existing kernel.

This is not a teaching demo, and it is not a course assignment: every commit is expected to boot, pass the automated tests, and be documented. (Who's the jerk calling this a "teaching system"?!)

![KKernel in hard-disk mode: font loaded from disk, FAT16 directory listing, running a program from the disk](docs/screenshot-fat.png)

*Hard-disk boot: load the full 42,112-glyph font from disk, mount FAT16, `ls` the directory, `run` a program stored on the disk.*

![Four shells switching between each other](docs/screenshot-shells.png) ![Calculator](docs/screenshot-calc.png) ![Text editor](docs/screenshot-edit.png) ![Pinyin IME floating candidate bar](docs/screenshot-ime.png)

## Design goals

Build an operating system from scratch against the Unix v6 "small but complete" standard: **boot → kernel → memory management → processes → filesystem → devices → shell → toolchain**. Every layer is written by hand, and the system can compile and run programs on itself.

The goal is not immediate POSIX or existing-software-ecosystem compatibility; first complete "the skeleton any system should have", then pile on networking, POSIX-lite, multi-user, and so on. (Way too hard to finish compatibility any time soon.)

## Core features

### Boot and kernel

- 512-byte boot sector (separate floppy / hard-disk paths, LBA multi-sector read with CHS fallback)
- Protected mode: GDT, IDT, TSS, 26 interrupt/exception handlers
- E820 memory detection, runtime-determined `ident` mapping and page-pool size, physical page pool + paging + demand paging
- Independent address space per program, page tables allocated dynamically from the page pool, whole space reclaimed on exit, page-leak detection

### Processes and multiple shells

- Preemptive round-robin scheduling (20 ms time slice, 6 thread slots), per-thread kernel stack
- ring 3 user-mode execution: entered via `iret`, TSS maintains the kernel stack; a user program touching kernel memory is killed by page protection
- 4 shells, each running on its own kernel thread; each shell can start programs independently, `Ctrl+←/→` switches focus
- `ps` / `spawn` / `kill` manage kernel threads and programs

### Graphical terminal and Chinese

- VBE 800×600×32 graphics mode, framebuffer with per-line buffering and dirty-segment refresh, scrolling support
- UTF-8 terminal: mixed ASCII and full-width CJK, 42,112-glyph full font (loaded from disk), built-in 416-glyph subset as fallback
- Pinyin input method: Shift to toggle, candidate bar floating on the bottom two screen lines (one line candidates + one line pinyin echo), paging / cancel supported
- Prompt styles: `kao` (default kaomoji `(・ω・)`) / `plain` / `moe` / `dos` / `c64`, configurable in `RC.CONF`
- Terminal features: colors, cursor, clear screen, line-addressed output, etc.

### Filesystem

- FAT16 / FAT32 read-write: subdirectories, VFAT long file names, multi-cluster files, two-FAT consistency maintenance
- `mkfat.py` host tool generates images; the system image root is split into `/BIN` `/LIB` `/SYS` `/DOCS` `/SRC` `/TEST` `/DEV` `/MNT` `/INCLUDE`
- The `run` command automatically searches `/BIN` for programs; programs can read and write the current directory and subdirectories
- Experimental **KiFS** filesystem (separate repo): journal-based crash consistency + copy-on-write (CoW), supports large volumes, symlinks, FUSE mounting

### Devices and storage

- `/DEV` virtual device layer: `NULL` `ZERO` `RANDOM` `RTC` `CON` `DEVICES`, usable directly with `cat` / `write`
- ATA PIO disk driver (LBA28 / LBA48), multiple devices supported
- UHCI USB host controller + USB mass storage (read-write): INQUIRY / READ CAPACITY / READ(10) / WRITE(10) / MBR parsing; USB keyboard (HID boot) input
- FAT16/FAT32 filesystem on USB block devices: after `usbdisk mount`, `ls/cat/write/cp/mv/mkdir/rm` work directly (unmounting restores the internal disk)
- PCI bus enumeration (enumerates IDE / USB / NIC and other devices)

### Shell and pipes

- 30+ built-in commands: `ls` `cd` `cat` `write` `cp` `mv` `rm` `mkdir` `rmdir` `run` `ps` `kill` `spawn` `shell` `clear` `info` `debug` `reboot` `uptime` `sleep` `date` `style` `pci` `usbdisk` `rc` `help`, etc.
- Pipes `A | B` (up to 4 stages): the producer's screen output is captured by the kernel into a page-pool buffer, and the consumer reads it back via `int 0x30` function 17; bundled `WC` / `UPPER` / `GREP` / `HEAD` tools
- When `write` / `cp` / `mv` hit an existing name, they prompt **R/D/O** (Rename / Don't write / Overwrite)
- `RC.CONF` configures boot hostname / services / prompt style; an event ledger records the boot process and is queryable with `rc log`
- Command history, line editing (backspace deletes a whole UTF-8 character), multi-line buffer

### Development toolchain

- Built-in **TCC 0.9.28 port**: compile C inside the system → produce ELF → run it directly (TCC source unmodified, with 18 standard headers in `/INCLUDE`)
- Host-side development route: `bin/kkernel-cc` + SDK, compile C programs into KKernel executables and drop them into `progs/`
- `int 0x30` syscall API, 17 functions: printing, strings, file read/write, keyboard, memory info, heap, arguments, pipes, etc.

### User programs

- Calculator (fixed-point decimal arithmetic), text editor (whole-character UTF-8 editing + pinyin input), vi (STEVIE port), Minesweeper (4 difficulties / random mine count / QUICKPASS cheat code), floating-point calculator, player, plus a batch of self-test programs

### Tests

- 18 groups of QEMU automated suites (floppy / hard disk / FAT32 / page-fault / keyboard / shell / full font / USB key/read-write/FAT mount / tty / login / scheduler / job control / swap, etc.) plus a Minesweeper-specific suite. The test bench really boots QEMU, takes screenshots, and asserts on screen content with OCR — no mocks
- The separate KiFS project additionally has power-loss injection consistency tests

## Quick start

Dependencies (Debian/Ubuntu):

```sh
sudo apt install nasm qemu-system-x86 gcc-multilib python3 genisoimage
```

Build and boot:

```sh
git clone https://github.com/KaiXinLee114514/KKernel.git
cd KKernel
make hd                 # build the 16 MB hard-disk image build/kkernel-hd.img
./tools/run.sh --hd     # boot it with QEMU
#For now, if you're building on Windows, please turn to claude code or vibe coding to solve it
```

You can also run `make run` to boot the default hard-disk image directly.

### Things to play with

```text
> help                  # command list
> ls                    # list directory (root holds the 9 category directories)
> run CALC              # calculator
> run MINE.BIN          # Minesweeper (1-4 picks difficulty; the QUICKPASS cheat code marks mines in red (cheat code: 1) it tests screen redrawing / mine generation etc. 2) I've personally raged over it a dozen times already...))
> run EDIT DOCS/NOTES.TXT
> cat DOCS/ZH.TXT       # "Yellow Crane Tower" — Chinese display
> cat DOCS/ZH.TXT | run GREP 黄鹤    # pipes
> run TCC.BIN -c SRC/TCC_INC.C -o A.O
> run TCC.BIN -static -nostdlib A.O LIB/CRT_TCC.O LIB/MINIC.O -o A.ELF
> run A.ELF             # compile C inside the system and run it
```

> TCC identifies file types by filename suffix; use lowercase `.c` / `.o` on the command line.

### Tests

```sh
make test               # all 18 QEMU suites (about 90–120 minutes)
make test-hda           # single suite: quick hard-disk-mode validation
make test-mine          # Minesweeper-specific suite
make test-usb           # USB mass storage, read-only
make test-usb-kbd       # USB keyboard input
make test-usb-rw        # FAT16 read-write on a USB disk + mounting
make test-usb-rw32      # same for FAT32
```

## Source map

```text
boot/        boot sector (512 B) and kernel loading
kernel/      kernel: kmain / paging / sched / fat / ata / usb / fbterm / ime / shell / api / elf ...
lib/         mini libc (minic) and C startup code
include/     kkernel.h — int 0x30 API declarations
progs/       C / assembly user programs: calculator, editor, vi, Minesweeper, TCC toolchain, test programs...
extensions/  TCC port, STEVIE (vi), player and other extensions
tccinc/      the 18 standard headers of the in-system TCC (become /INCLUDE in the image)
font/        font data and generation tools
tools/       mkfat / mkimg / run.sh / onekey_push.sh, etc.
tests/       QEMU automated tests (qemu_test.py, etc.)
docs/        architecture, pitfalls, shell commands, subsystem docs
```

## Documentation index

| Document | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | implementation details of graphics mode, disk / address space / ring 3 / threads / multi-shell / IME / rc.conf |
| [docs/pitfalls.md](docs/pitfalls.md) | 39 real debugging war stories (debugging notes, the essence) |
| [docs/shell-commands.md](docs/shell-commands.md) | shell command reference |
| [docs/hacking.md](docs/hacking.md) | how to hack: build, test, debug, commit conventions |
| [docs/roadmap.md](docs/roadmap.md) | roadmap and TODOs |
| [docs/filesystem.md](docs/filesystem.md) | FAT16/32 implementation, image layout, mkfat usage |
| [docs/encoding.md](docs/encoding.md) | UTF-8, fonts, pinyin input method |
| [docs/programs.md](docs/programs.md) | user programs (SDK) and the int 0x30 API |
| [docs/pci.md](docs/pci.md) | PCI bus enumeration |
| [docs/usb-disk.md](docs/usb-disk.md) | USB mass storage (read-write + FAT16/FAT32 mounting) |
| [docs/pipes.md](docs/pipes.md) | sequential pipe implementation |
| [docs/devices.md](docs/devices.md) | the `/DEV` device layer |
| [docs/font.md](docs/font.md) | Chinese and font data |
| [docs/rc-conf.md](docs/rc-conf.md) | `RC.CONF` configuration keys |
| [docs/known-issues.md](docs/known-issues.md) | known limitations and flaky-test notes |
| [docs/design-multishell-cow.md](docs/design-multishell-cow.md) | multi-shell virtual console + fork/memory CoW design draft |

## Known limitations

- **Single user, no account/permission system**: the only isolation is ring 3; FAT has no permission bits. (Now we have it — too lazy to update the docs, just added a few lines. Anyway now we have it: Super=root=SYSTEM is the highest account, password root, and I don't know the rest.)
- **No fork/exec/signals**: programs are started by the shell and return to the shell on exit; **memory-level fork + copy-on-write (CoW) is not implemented yet** and belongs to the Phase 3 roadmap (note: the CoW in the KiFS filesystem is copy-on-write of file data blocks — a different thing). (Actually we have it now.)
- **No networking**: PCI can enumerate NICs, but the protocol stack is not written yet. (Really no time — wait for it.)
- **USB controllers support only UHCI (full speed 12 Mbps)**: USB2.0 high speed (EHCI) / USB3 (xHCI) not implemented yet. Mass storage supports read-write + FAT16/FAT32 mounting; hot-plug is not supported, and the first USB device must be a disk (when a usb-kbd is plugged in it can be used as a keyboard).
- **Single core**: no SMP; the graphical terminal refreshes per pixel, unsuitable for high-frame-rate action games.
- Limited real-hardware compatibility (mostly validated in QEMU); see [docs/known-issues.md](docs/known-issues.md) for the detailed list. (Really don't have that much money to buy new devices for experiments!)

## Contributing

- See [docs/hacking.md](docs/hacking.md) for the development process and conventions: Chinese comments, run `make test-hda` after changes, Chinese prefixes in commit messages.
- If you hit a bug, open an issue with the QEMU version and a reproduction command.
- PRs are welcome too — small, testable, well-described changes are the easiest to merge.

## License

[GPL-3.0](LICENSE). The font comes from GNU Unifont (GPL-2+, see [font/README.md](font/README.md)); third-party components such as the TCC port and STEVIE are copyrighted by their respective authors — see the README in the corresponding directory.

---

**KKernel** —— *Kai + Kernel*. An operating system a middle-school student started writing from the boot sector, still growing. (From the second half of 2027 onwards, please imagine a high-school student here.)
Contact: lkx2025awa@outlook.com qq:3927714593 SMS:(+86)183-7205-1152 X:qq3927714593
