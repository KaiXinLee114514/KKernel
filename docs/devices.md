[简体中文](zh-CN/devices.md)

# The /DEV Device Abstraction Layer

> The smallest edition of "everything is a file": reading the clock, writing to the screen,
> throwing things away — to a program these are all just **opening a name and reading or writing
> bytes**. KKernel's FAT16 has already paved the "name → bytes" road; `/DEV` adds only a short
> stretch: when a filename starts with `DEV/`, **don't look at the disk, look at the device table**.

## 1. What devices exist

| Name | Read | Write | Notes |
|---|---|---|---|
| `DEV/NULL` | Always 0 bytes | Discard | The classic `/dev/null`: a black hole, write whatever you like |
| `DEV/ZERO` | As many `0x00` as you ask for | Discard | Typical use: zero out a buffer |
| `DEV/RANDOM` | Pseudorandom bytes | Not supported | xorshift32, seeded from the PIT tick count (different on every boot) |
| `DEV/RTC` | `YYYY-MM-DD HH:MM:SS` (19 bytes) | Not supported | Reads the CMOS clock live, no caching |
| `DEV/CON` | Not supported | Printed to the screen as UTF-8 text | No automatic newline; write `\n` yourself if you want one |
| `DEV/DEVICES` | Lists all device names (space-separated) | Not supported | The device table reports its own names; adding a device needs no change here |

The `/DEV` directory contains **placeholder files** put there by `tools/mkfat.py` (you can see them
with `ls DEV`), but their on-disk contents are never read — reads and writes both go through the
kernel device layer. The placeholder content is just a one-line description
(`progs/DEV_NODE.txt`), so anyone looking straight at the image can tell what these are.

## 2. Trying it in the shell

Try it in the shell (Chinese output shown as-is):

```text
> ls DEV
README.TXT 673 bytes
NULL 86 bytes
ZERO 86 bytes
RANDOM 86 bytes
RTC 86 bytes
CON 86 bytes
DEVICES 86 bytes
> cat DEV/RTC
2026-11-07 03:18:41
> cat DEV/DEVICES
NULL ZERO RANDOM RTC CON DEVICES
> write DEV/CON hello, console!
hello, console!wrote DEV/CON
> write DEV/NULL 这不占地方
wrote DEV/NULL
> cat DEV/NULL
> cat DEV/CON
device is not readable
```

Device names are case-insensitive, and a leading `/` is optional: `DEV/RTC`, `dev/rtc` and
`/DEV/RTC` all work.

## 3. Using it from a program

Functions **7 (read file)** and **8 (write file)** of `int 0x30` share the same device layer as the
shell, so programs get device access **without any new interface**. In C it's just ordinary
`fopen/fread/fwrite`:

```c
#include <stdio.h>

int main(void)
{
    char t[32];
    FILE *f = fopen("DEV/RTC", "rb");
    if (!f) { printf("no dev\n"); return 1; }
    fread(t, 1, sizeof t - 1, f);      /* 19-byte time string */
    fclose(f);
    printf("现在是 %s\n", t);
    return 0;
}
```

The last part of `progs/IOTEST.c` is exactly this device self-test (reads `DEV/RTC`, writes
`DEV/NULL`); `run iotest` in the shell shows the result.

## 4. Implementation (and why it looks like this)

```
kernel/dev.asm
  dev_table      device table: 12 bytes per entry (name pointer / read function / write function; 0 = that direction unsupported)
  dev_lookup     esi = name → eax = table entry (0 = not a device name)
  dev_xxx_read   read: edi = buffer, ecx = limit → eax = byte count (-1 = failure)
  dev_xxx_write  write: esi = data, ecx = length → eax = 0 on success (-1 = failure)
```

There are only two call sites:

- Functions 7/8 in `kernel/api.asm`: call `dev_lookup` **before** entering `fat_path`; on a hit,
  call the handler directly and never touch the current directory (so `fat_dir` isn't left
  halfway updated).
- `cat` / `write` in `kernel/shell.asm`: same idea, check the device first. The result of
  `cat DEV/XXX` gets a `0` terminator appended before printing, so bytes left in the buffer from
  the previous use don't get printed too.

Each handler does its own `pushad` to protect registers and leaves only the result in `eax` — that
way both kernel call sites (cat/write calling directly, the API calling through the interrupt) can
share the same set of functions.

## 5. Adding a new device

1. Write the handler (read and/or write), following the register conventions above;
2. Add a row to `dev_table` in `kernel/dev.asm`, with the name string in the data segment;
3. Add a placeholder entry for `DEV/` to `MKFAT_FILES` in the `Makefile`:
   `DEV/name=progs/DEV_NODE.txt`;
4. If you want it documented, add a row to the table above.

No code in `ls` / `cat` / `write` / the API needs to change — name resolution and the device table
pick it up automatically.

## 6. Known limitations

- **There is only one `/DEV` namespace**: `/dev` is a "name prefix" for a virtual directory, not a
  real directory you can `cd` into (`cd DEV` still enters the directory that exists in FAT, it's
  just that the files inside read out as magic).
- **No open/close, no seek**: every read starts from the beginning; `DEV/RTC` re-reads the clock on
  every read.
- **No permission bits**: every program can read every device (the kernel has no permission model
  yet anyway).
- **The write direction returns no byte count**: the handler only reports success/failure;
  `DEV/CON` truncates anything past 255 bytes.
- **`cat DEV/RANDOM` prints binary garbage**: it's a byte device, not text; use a program to read it
  if you want to see the effect.
- Device placeholder files show up in `ls` as 86 bytes (the length of the placeholder text), which
  says nothing about the device's actual data volume.
