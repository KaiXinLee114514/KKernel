[简体中文](zh-CN/filesystem.md)

# KKernel's disk: ATA PIO, on-disk font, FAT16 / FAT32

This page covers **what's on the disk, how the kernel reads it, and how it writes to it**. Three
files are involved:

| File | What it does |
|---|---|
| `kernel/ata.asm` | ATA (IDE) hard-disk PIO driver, reads/writes raw sectors |
| `kernel/fontdisk.asm` | copies the full font from disk into memory at boot |
| `kernel/fat.asm` | FAT16: find files, read files, write files, list directories |

The companion Python tools are `tools/mkimg.py` (assemble the image + place the font) and
`tools/mkfat.py` (create the partition + place files).

---

## 1. What the whole image looks like

`build/kkernel-hd.img` is 16 MB, laid out by LBA (logical sector number, 1 sector = 512 bytes):

```
LBA 0            boot sector (512 bytes, read by the BIOS to 0x7C00)
LBA 1 - 4        real-mode stub (moved to 0x500; ask VBE, enter protected mode)
LBA 5 onward     32-bit kernel (512 sectors = 256 KiB, moved to 0x10000)
LBA 2047         font descriptor block: magic 'JFD1' + font LBA + sector count + byte count
LBA 2048 onward  the font itself (KKF0 format, 1,765,648 bytes = 3449 sectors)
LBA 6144 onward  FAT16 partition (8 MB; the only place "files" can be operated on)
```

Why the FAT16 partition starts at **6144**: the font only ends at sector 5496, leaving a little slack
after it. The partition start is **hardcoded** in two places, and both have to change together:

* `FAT_PART_LBA equ 6144` in `kernel/fat.asm` (the kernel goes to this LBA to find the "boot sector")
* `mkfat.py $(HDIMG) 6144 8 ...` in the `Makefile`

> There is no MBR partition table — `fat_mount` isn't "parsing a partition table", it **goes straight
> to a fixed LBA** and reads that FAT boot sector. For a toy system that's the least effort; the cost
> is that the partition can't move.

The floppy image (`build/kkernel.img`, 1.44 MB) only has the first three items — no font and no
filesystem; BIOS floppy reads are a separate test route (`make test-fda`).

## 2. Why we stopped using BIOS disk reads

Reading disks with `int 0x13` at boot is fine (that's exactly what the boot sector does), but after
that:

* the BIOS only has one operation, "read sector N", and **it has no idea what a file is**;
* `int 0x13` is a real-mode interrupt, and once in protected mode you'd have to switch back and forth,
  which is a nuisance;
* we want to use the 1.8 MB font on the hard disk, and the amount the BIOS reads at a time isn't a
  good fit either.

So once in protected mode we drive the **ATA controller ports** (0x1F0~0x1F7) directly — that approach
is called PIO (Programmed I/O: the CPU moves the data in a word at a time, no DMA).

## 3. The ATA PIO driver (`kernel/ata.asm`)

Reading one sector uses a fixed register order:

```
0x1F6 ← 0xE0 | (LBA >> 24 & 0x0F)   select the master + top 4 bits of the LBA
0x1F2 ← sector count
0x1F3 ← LBA & 0xFF                  low 24 bits, spread over three ports
0x1F4 ← (LBA >> 8) & 0xFF
0x1F5 ← (LBA >> 16) & 0xFF
0x1F7 ← 0x20 (read) / 0x30 (write)  command register: issue the command
wait on 0x1F7: BSY (bit7) goes 0 and DRQ (bit3) goes 1
read 0x1F0 256 times (16 bits) = 512 bytes
```

Only two functions are exported (both in `kernel/ata.asm`):

```asm
; eax = starting LBA, ecx = sector count, edi = destination; returns eax = 0 on success
call ata_read_sectors

; eax = starting LBA, ecx = sector count, esi = source; returns eax = 0 on success
call ata_write_sectors
```

Writing to disk takes two extra steps, and skipping either can lose data:

1. **wait ~400 ns before each port write** (`ata_delay400`, reading the status port four times counts
   as the wait) — old drives can't take writes that fast;
2. after writing, send **0xE7 = FLUSH CACHE** so the drive really commits its internal cache
   (otherwise quitting QEMU can leave data sitting in the cache).

### Trap 1: asked for 255 sectors, only one came back

When reading the font, the first version "issued a 255-sector read in one go"; the status said
success, but **only the first sector in memory was correct — the rest were all zeros**.

The reason is that the ATA spec allows the drive to transfer **only part** of the request (as much as
it feels like), and in PIO mode every sector transferred requires waiting for DRQ. The fix is
chunking + waiting per sector within each chunk:

```asm
ATA_MAX_CHUNK equ 16          ; chunk size: 255 is the hardware limit, 16 (=8 KB) proved most reliable
```

`ata_wait_drq` waits for `DRQ=1` before each 512-byte move, and that's what got all 3449 sectors in.

### Trap 2: `mov al, 0xE0` loses the LBA

In `ata_setup_lba` the LBA lives in `eax`, and one step along the way does `mov al, 0xE0` (the
drive-select byte) — `al` is the low 8 bits of `eax`, so the low byte of the LBA got overwritten with
0xE0 on the spot.

So "read LBA 0x1E0" became "read LBA 0x00", the whole font read back as 0 → every character on screen
was a **missing-glyph box**. The fix: list all the parameters first, then load the LBA back into `eax`
from memory. The lesson from this class of bug is **look at the bytes in memory, don't trust "the
function returned success"**.

## 4. On-disk font (`kernel/fontdisk.asm`)

The kernel area is only 256 KiB (`KERNEL_SECTS = 512`), while the full font is **1.8 MB / 42,112
glyphs**, so `incbin` is out. Hence:

* `font/font-kkf.bin` (416 glyphs, ~12 KB) is **compiled into the kernel** as the fallback;
* `font/full-kkf.bin` (42,112 glyphs) **lives on the disk** and is read into memory at boot.

The boot flow (`font_load_from_disk`):

```
read the boot drive number at BOOTINFO+72 → if it isn't 0x80 onwards (hard disk), don't even try; use the built-in subset
read the descriptor block at LBA 2047 → if the first 4 bytes aren't 'JFD1', give up
read the font to 0x200000 using the LBA/sector count in the descriptor block
check for 'KKF0' at 0x200000 → if it's there, switch over (read the glyph count into font_glyphs)
```

Three notes:

* **why the address is 0x200000**: paging identity-maps 0~ident (at least 4 MiB), 2 MB is inside that,
  so once it's read in it can be used as an ordinary pointer (no new mapping needed);
* **why a failed read isn't a problem**: any step going wrong falls back to the built-in subset and
  the system still boots — the font is an enhancement, not a requirement. Booting from floppy takes
  exactly this path;
* the line `font: loaded from disk (ATA), 42112 glyphs` on screen is the evidence
  (`font: built-in subset, 416 glyphs` means it fell back).

## 5. FAT16 (`kernel/fat.asm`)

Only the "just enough" slice: 8.3 short names + subdirectories + both FAT16/FAT32 formats. **No**
long file names (LFN), **no** file timestamps. Creating/removing/entering/leaving subdirectories is
there (see 5.2 below).

Fields used from the boot sector (offsets are relative to the partition start; `fat_mount` reads them
one by one):

| Offset | Meaning | Variable in the code |
|---|---|---|
| 11 | bytes per sector (must be 512, otherwise give up) | `fat_bps` |
| 13 | sectors per cluster | `fat_spc` |
| 14 | reserved sectors (the FAT starts after these) | `fat_reserved` |
| 16 | number of FATs (usually 2) | `fat_nfats` |
| 17 | root-directory entries (32 bytes each) | `fat_root_ents` |
| 22 | sectors per FAT (**0 = this is FAT32**; FAT32 uses the fields at 36/44/48 below) | `fat_size` |
| 36 | FAT32: sectors per FAT (32-bit) | `fat_size` |
| 44 | FAT32: root-directory first cluster (the root is a cluster chain too) | `fat_root_cluster` |
| 48 | FAT32: FSInfo sector number | `fat_fsinfo` |
| 510 | 0xAA55 signature (not this and it isn't a boot sector) | — |

Three computed locations: `fat_fat_lba` (the FAT), `fat_root_lba` (root directory), `fat_data_lba`
(start of the data area); with `fat_spc` you can translate "cluster number" into "sector number":
`LBA = fat_data_lba + (cluster - 2) * fat_spc`.
(Clusters 0 and 1 are reserved values used by the FAT itself, so data clusters start at 2.)

**Telling FAT16 from FAT32 is just checking whether the 16-bit field at offset 22 is 0** — that's the
only hard difference in the spec, no guessing and no partition table needed. Once it's known, the
differences are in four places (all tucked behind one `fat_fat32` flag in the code):

| | FAT16 | FAT32 |
|---|---|---|
| FAT entry | 2 bytes | 4 bytes (top 4 bits reserved; mask with `& 0x0FFFFFFF` after reading) |
| Root directory | fixed area (`root_ents` × 32 bytes) | ordinary cluster chain, starting at the cluster number in offset 44 |
| End-of-chain threshold | ≥ 0xFFF8 | ≥ 0x0FFFFFF8 (`fat_eoc` variable) |
| First cluster in a directory entry | offset +26 (16 bits) | low 16 bits at +26 + **high 16 bits at offset +20** |

So "find a free directory entry", "walk the directory chain looking for a name" and "add a cluster to
a directory" need **only one body of code** for both formats; only `fat_next_cluster` /
`fat_set_entry` / `fat_alloc_cluster` and the places that fetch a cluster number fork.

Function list:

| Function | What it does |
|---|---|
| `fat_mount` | read the boot sector and compute the locations above; `fat_ok` = 1 means mounted |
| `fat_name83` | turn `"hello.bin"` into the 11 bytes `HELLO   BIN` in a directory entry |
| `fat_find` | linear search for that name in the root directory, and when found remember **the sector and offset of the directory entry** |
| `fat_next_cluster` | look up the next cluster in the FAT (with a one-sector FAT cache `fat_cache_lba`) |
| `fat_read_file` | read a file into memory along its cluster chain, returning the byte count (-1 if not found) |
| `fat_set_entry` | change a FAT entry, **writing both FAT copies** |
| `fat_alloc_cluster` | find a free cluster and mark it end-of-chain |
| `fat_write_file` | write a file: overwrite if it exists, create if not (taking one directory entry) |
| `fat_list` | list the current directory (name + byte count, `<DIR>` for directories), used by `ls` |
| `fat_chdir` | enter a subdirectory (check attr bit4, take the first cluster), used by `cd` |
| `fat_path` | split `DOCS/NOTE.TXT` on `/` (or `\`), `fat_chdir` layer by layer, return a pointer to the last segment |
| `fat_free_slot` | find a free directory entry in the current directory; when a subdirectory is full, chain a new (zeroed) cluster onto it |
| `fat_mkdir` | create a directory: take a slot → allocate a cluster → zero it → write `.` and `..` → write the entry back into the parent |
| `fat_rmdir` | remove a directory: scan first to confirm it only has `.`/`..` (refuse if not empty), then free the whole cluster chain and mark the parent entry 0xE5 |
| `fat_dotdot` | read the parent cluster number from the `..` entry in the current directory's first cluster (used by `cd ..`) |
| `fat_zero_cluster` | write a whole cluster of zeros (a new directory wants a clean cluster) |
| `fat_ent_cluster` | get the first cluster from a directory entry (FAT16 takes +26; FAT32 also combines the high bits at +20) |

### 5.2 Subdirectories and paths

* `fat_dir` is "the current directory": **0 = root**, any other value = that directory's first
  cluster. Every lookup/list/free-slot search has to ask it "root or cluster chain" first, and that
  fork is written the same way in all three places.
* `.` and `..` are real directory entries written on disk (written when the directory is created),
  and `ls` hides them; `cd ..` just reads the cluster number in the `..` entry — a top-level
  directory's `..` is filled with 0 by the old FAT convention, i.e. "root".
* The shell saves/restores `fat_dir` before and after each command (a save at each dispatch point),
  so a command like `cat DOCS/X.TXT` only "borrows" the directory cursor and won't lose your `cd`;
  `cd` itself writes the new directory back into that saved copy.
* The `int 0x30` file interface (7 read / 8 write) goes through `fat_path` too, so `cat`, `run`, the
  editor and vi's save all accept paths like `DOCS/NOTE.TXT`, relative to the **current directory**:
  `cd DOCS` and then `run VI NOTE.TXT` still saves `DOCS/NOTE.TXT`.

### 5.3 Collision prompt at the shell layer (R/D/O)

Before `write`, `cp` and `mv` actually commit, they check whether the target exists (with `fat_path`
+ `fat_stat`; FAT names are case-insensitive). If it does, they print

```
Found file with same filename. Rename / Don't write / Overwrite? (R/D/O)
```

Keys: `R` reads a new name line (echo, backspace, Enter to finish), re-checks with the new name, and
asks again if it collides; `D` or Esc gives up (prints `not written.`); `O` overwrites. Writes to
`/DEV` virtual devices and writes inside a pipe don't prompt (pipes need a clean data stream); when
cp/mv's target is a directory, the check is on the final file `DIR/basename`.

### The full write path

```
1. fat_find looks for a file of the same name → if found, mark it free along its cluster chain (equivalent to deleting the old contents)
2. restart from the first free cluster and write cluster by cluster: write data → fat_set_entry links it into the chain
3. when creating, take a free directory entry in the root directory and fill in the first cluster and file size
4. send FLUSH CACHE
```

The `fat_set_entry` in step 2 **changes both FAT copies** — FAT16 deliberately keeps two as protection
against exactly this; change only one and the filesystem looks corrupt to other systems. One offline
assertion in the tests watches this specifically.

### Limits (pick from here if you want to extend it)

* names support 8.3 + VFAT long file names (when writing, long-name entries are added with LFN
  checksums; the 8.3 alias is a natural truncation/`~N`);
* no timestamps are written (those bytes in the directory entry stay 0);
* overwriting a file doesn't free the old cluster chain (leaks clusters; data is fine, "the disk just
  occupies a few extra clusters");
* FSInfo is only read in and kept; it isn't updated when writing (other systems just miss a "how much
  is free" hint);
* writing does no error recovery beyond "disk full", and doesn't check whether a cluster is really
  free (`fat_alloc_cluster` only looks at whether the FAT entry is 0).

## 6. Putting files into the image: `tools/mkfat.py`

```bash
python3 tools/mkfat.py build/kkernel-hd.img 6144 8 \
    DOCS/README.TXT=progs/README.TXT \
    BIN/HELLO.BIN=build/HELLO.BIN
```

* the 2nd argument is the partition's starting LBA (must match `FAT_PART_LBA`), the 3rd is the
  partition size (MB);
* everything after that is `name-in-image=file-on-host`;
* sectors per cluster is **picked automatically**: `mkfat.py` computes it so the cluster count lands
  in the `[4085, 65525)` range FAT16 requires (for 8 MB that's 2 sectors/cluster, data area starting
  at LBA 6241, 8143 clusters);
* a name ending in `/` = create a directory; a file name containing `/` creates its parent directories
  automatically
  (that's how the system image is layered: the root directory only holds `BIN/ LIB/ SYS/ DOCS/ SRC/ TEST/ DEV/ MNT/ INCLUDE/` nine category directories,

```bash
python3 tools/mkfat.py build/kkernel-hd.img 6144 8 \
    DOCS/README.TXT=progs/README.TXT DOCS/ DOCS/NOTE.TXT=progs/NOTES.TXT
```

### FAT32 partitions

Add `--fat32`: same command line, same kernel, just the partition formatted as FAT32 (32 reserved
sectors, 4-byte FAT entries, root directory = cluster 2 + FSInfo/backup boot sector). FAT32 requires
**at least 65525 clusters**, and an 8 MB partition can't reach that no matter how you tune it, so the
image has to grow:

```bash
python3 tools/mkimg.py build/boot.bin build/stub.bin build/kernel.bin build/kkernel-hd32.img \
    font/full-kkf.bin --disk-mb 96
python3 tools/mkfat.py build/kkernel-hd32.img 6144 88 --fat32 DOCS/README.TXT=progs/README.TXT \
    DOCS/ DOCS/NOTE.TXT=progs/NOTES.TXT
```

`make hd32` / `make test-hd32` are those two steps. Why it automatically picks 2 sectors/cluster:
`mkfat.py` tries from 32 sectors/cluster downwards and the first one with "cluster count ≥ 65525"
wins.

`make hd` runs this step automatically (the `$(HDIMG)` rule in the `Makefile`), so normally you just:

```bash
make hd          # build + boot the full hard-disk image
# or
./tools/run.sh --hd
```

## 7. How to verify it's real (not "it looks right")

All the disk tests live in the `--fontdisk` profile of `tests/qemu_test.py` (`make test-hd-font`), and
they use **two independent channels**:

**Channel one: screen pixels.** QEMU runs headless, `monitor` grabs a `screendump`, then the expected
text is rendered with `font/full-kkf.bin` in Python into an "ink/no-ink" grid, and that pattern is
looked for in the screenshot. This proves "the kernel thinks it displayed it".

**Channel two: offline image parsing.** After the test, QEMU is shut down first (so it flushes), and
then **without looking at the kernel**, the 70-line `Fat16` class in `qemu_test.py` (pure Python:
computes the boot-sector fields itself, walks the cluster chain itself; it also identifies FAT32 by
"is offset 22 zero") reads the image as a block device and asserts:

* `TEST.TXT` really is in the root directory, and its content really is `hello-from-fat16` (written
  from the shell with `write test.txt hello-from-fat16`);
* stuff in subdirectories is right too: `DOCS/NOTE.TXT` and `progs/NOTES.TXT` are byte-identical,
  `DOCS/SUBFILE.TXT` was written by `write` after `cd DOCS` in the shell, `TESTDIR/INNER.TXT` was
  written in a second-level directory, and the empty directory removed with `rmdir` really is gone
  from the root;
* the cluster entry in **both** FATs is end-of-chain, i.e. **both FATs were updated**;
* the image's original `DOCS/README.TXT` / `BIN/HELLO.BIN` / `BIN/COUNT.BIN` are **byte-for-byte
  identical** to the source files in the repo;
* the font descriptor block at LBA 2047 and the font from LBA 2048 are byte-identical to
  `font/full-kkf.bin`.

This proves "the bytes really landed on the disk" — the kernel's own `wrote test.txt` is not evidence.

`make test-hd32` runs the same assertions on a FAT32 image (plus one "boot reports FAT32"), with the
same kernel and the same parser, so the situation "FAT16 works but FAT32 is just decoration" can't
slip through.
