[简体中文](zh-CN/shell-commands.md)

# Shell Command Reference

> Originally README §7.

```
help          list commands
echo <text>   print the text back
clear         clear the screen
info          CR0/CR2/CR3/CR4, IDT base and limit, segment registers, disk access method
debug <what>  diagnostics/self-checks all live under this one (the demo commands used to be
              scattered around; now they're tucked away here):
  debug page <hex>   walk the page tables level by level, find where a virtual address maps (e.g. debug page 0x400000)
  debug pmem         physical page pool: total pages, used, free, bitmap address
  debug pmap <va>    grab a page from the pool and build page tables on demand mapping it at a virtual address
                     (the most direct way to play with paging)
  debug pumap <va>   unmap and return the page to the pool (an emptied page table is reclaimed too)
  debug ptest        self-test: alloc → build tables → write via virtual address / read via physical
                     → unmap → return, checking for leaks
  debug fault        deliberately step on an unmapped address to see the page-fault panic screen
reboot        reboot (through the 8042 keyboard controller)
ls            list the current directory (name + size in bytes; hard-disk mode only; under the root
              are eight category subdirectories)
cat <file>    print a file (UTF-8 text); Chinese shows up directly;
              under /DEV are virtual devices: cat DEV/RTC for the time, cat DEV/DEVICES to list devices
write <f> <t> write a file (create or overwrite, actually lands on disk);
              if the target exists it asks R/D/O first: R rename, D (or Esc) don't write, O overwrite;
              under /DEV: write DEV/CON hi prints to the screen, write DEV/NULL drops it into the void
cp <src> <dst> copy a file (the source is read into the 60 KiB file buffer, then written to the target);
              if the target is written as DOCS/ (trailing /) or is an existing directory name
              → copy into that directory, name unchanged;
              if the resulting file already exists it also asks R/D/O (same as above)
mv <src> <dst> rename/move a file (implemented as copy + delete source, moving the FAT directory entry;
              subdirectories and long file names both supported);
              if the target exists it asks R/D/O too
run <file>    build a separate address space for the program (demand paging) and run it (a name without
              a dot gets .BIN appended; bare run prints the interface description; when it finishes it
              reports how many pages were faulted in: run TOUCH shows this best)
A | B         pipe (sequential, max 4 stages): A's screen output is swallowed by the kernel into a
              64 KB buffer, and when A finishes the buffer becomes B's stdin (B reads it with int 0x30
              function 17, see docs/pipes.md);
              e.g. cat DOCS/README.TXT | run WC / ls BIN | run GREP HELLO
              pipe tools: WC (lines/words/bytes), UPPER (upper-case), GREP <substring>, HEAD [lines]
usbdisk       read-only raw USB disk (USB mass storage): bare usbdisk shows device info (INQUIRY/capacity);
              usbdisk read <lba> reads one sector and prints 64 B / hexdump <lba> shows the full 512 B /
              mbr decodes the partition table / sense reads the SCSI sense data
date [fmt]    read the CMOS clock: bare date prints date + time + weekday; add ymd / mdy / dmy / time
              to change the format
style [name]  change the prompt style: kao (kaomoji (・ω・), errors become (；ω；), default) /
              plain (plain >) / moe (cute: かいかーねる>, errors come with a snarky remark) /
              dos (C:\>) / c64 (READY.); bare style shows which one is in use
pci [b:s.f]   PCI bus enumeration: bare pci lists every device on the bus, add an address like 0:1.2
              to see one device in detail
uptime        how long since boot (includes the tick count, e.g. up 4 s (432 ticks at 100 Hz))
sleep <sec>   sleep that many seconds with hlt (idle doesn't burn CPU; max 3600 s)
ps            list kernel threads (number / name / ticks received / how often scheduled)
spawn [who]   start a demo thread (alpha / beta each print a line per second; no argument starts them
              in turn)
kill <id>     kill a thread and return its stack to the physical page pool (0~3 are the shells
              themselves and can't be killed)
shell [n]     list the 4 shells (marking which one the keyboard belongs to), or jump straight to one
              with shell 3; Ctrl+Left / Ctrl+Right switches to the neighbour at any time (even a hung
              shell can be switched away from)
rc [what]     rc.conf (key=value service/event store, see docs/rc-conf.md):
  rc              summary: config file name, number of keys, hostname, autostart / on_crash
  rc list         list services (number / program / enabled-disabled / args)
  rc get <key>    get the value of a key (keys are case-insensitive)
  rc start <n>    run service n as a program (same path as run)
  rc log          event log: boot / config read / service start-stop / program finished / crashed /
                  kill / shell switch, each with its tick
  rc reload       re-read /SYS/RC.CONF from disk (a write in the shell takes effect immediately)
```

What `uptime` / `sleep` look like (the timer is just the 100 Hz IRQ0 being counted):

```
> uptime
up 4 s (432 ticks at 100 Hz)
> sleep 2
slept 2 s (200 ticks)
> uptime
up 13 s (1306 ticks at 100 Hz)
```

What `date` looks like (it reads the real time out of CMOS; the windowed QEMU targets add
`-rtc base=localtime`, so it agrees with the watch on your wrist):

```
> date
2026-10-07 11:03:36 星期三
RTC: BCD, 24-hour mode (no timezone handling)
> date ymd
2026-10-07
> date mdy
10/07/2026
> date dmy
07/10/2026
> date time
11:03:42
> date xxx
date: unknown format, try ymd / mdy / dmy / time (got: xxx)
```

*(Chinese output shown as-is.)*

Sample output of `debug page` / `debug pmap` (this is what paging actually does):

```
> debug page 0x400000    ← identity mapping: virtual address = physical address
virtual      = 0x00400000
PDE index    = 0x00000001 [1] = 0x00003003  present + writable
PTE index    = 0x00000000 [0] = 0x00400003  present
physical     = 0x00400000
> debug page 0x20000000  ← beyond the identity-mapping ceiling (256 MiB) nothing is mapped
virtual      = 0x20000000
PDE index    = 0x00000080 [128] = 0x00000000  PDE not present -> would page-fault
> debug pmap 0x8000000   ← build a page table on the fly and map a physical page from the pool onto it
mapped 0x08000000 -> physical 0x00400000  (page table created on demand; check with: debug page <va>)
> debug page 0x8000000
virtual      = 0x08000000
PDE index    = 0x00000020 [32] = 0x00401003  present + writable
PTE index    = 0x00000000 [0] = 0x00400003  present
physical     = 0x00400000
> debug pumap 0x8000000
unmapped, gave back 0x00400000  (page returned to the pool; empty page table recycled)
```

The keyboard hands over raw bytes; Chinese is typed by pressing **Shift to toggle the Pinyin IME**
(the candidate bar floats on the bottom two lines of the screen, see the
[architecture doc](architecture.md)); you can also just `cat` a UTF-8 file: `cat DOCS/ZH.TXT` is the
ready-made demo.

To build programs inside the system itself, run TCC (the in-system C compiler):

```
> run TCC.BIN -c src/tcc_inc.c -o tcc_inc.o
> run TCC.BIN -static -nostdlib tcc_inc.o lib/crt_tcc.o lib/minic.o -o tcc_inc.elf
> run tcc_inc.elf        ← TCC #include: include works / sizeof(size_t)=4
```

The system headers live in `/INCLUDE` in the image (from `tccinc/` in the repo); `#include <stdio.h>`
/ `<string.h>` and friends all work; details in
[extensions/tcc/README.md](../extensions/tcc/README.md). Note that TCC decides file type by
**suffix**, so write the lowercase `.c` / `.o` on the command line (FAT lookups are case-insensitive,
but TCC gets the exact string you typed).
