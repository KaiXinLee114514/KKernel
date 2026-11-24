[简体中文](zh-CN/fat-plan.md)

# Adding subdirectories and FAT32 to the FAT driver (implementation plan)

> **Status: all done ✅** (2026-02; subdirectories + cd/mkdir/rmdir + FAT32 + tests/offline assertions are all on main)
> The remaining pitfalls are recorded in "what's not done" at the end of this page, and in `known-issues.md`.

This page is the **design written before the work**, not the current state. For the current state see
[filesystem.md](filesystem.md). Both features were requested by users: FAT32 is the one most wanted,
subdirectories right behind it — in order, subdirectories first (small, immediately useful), then
FAT32 (which amounts to rewriting the driver).

## 0. Where it's stuck today

All the "find a file" code in `kernel/fat.asm` hardcodes three assumptions:

```
1. Directory = the fixed area of the root directory (root_ents 32-byte entries from fat_root_lba)  ← a subdirectory is a cluster chain, not a fixed area
2. Name = 11 bytes of 8.3, with no notion of paths                                   ← need a/b/c.txt
3. FAT entry = 16 bits                                                 ← FAT32 is 32 bits
```

Those three hardcoded spots are in `fat_find` (line 146), the free-slot search in `fat_write_file`
(line 456), and `fat_list` (line 576). **First pull all three into one "directory cursor", so
subdirectories and FAT32 both fit into it.**

## 1. Subdirectories (do first)

### 1.1 Abstraction: a directory cursor

```asm
; a directory = either the "root area" (fixed LBA + entry count) or a "cluster chain"
fat_dir        dd 0     ; starting cluster (0 = root area)
fat_dir_lba    dd 0     ; root-area mode: current sector
fat_dir_idx    dd 0     ; which entry within the current sector

fat_dir_open:      ; esi = path → find the first cluster of this directory (error if it doesn't exist)
fat_dir_entry:     ; → fetch the next valid directory entry into FAT_BUF, esi points at it; CF=1 at the end
fat_dir_close
```

The `fat_dir_entry` loop reads one sector at a time (root area: sequential LBAs; subdirectory: along
the cluster chain), scans the 32-byte entries, skips 0xE5 and LFNs (attr&0x0F==0x0F), and stops at
0x00.

### 1.2 Path resolution

```asm
fat_resolve:       ; esi = "DIR/SUB/FILE.TXT" → split out the directory part and the last name segment
                   ; look up segment by segment: each directory name is first searched for in the current directory (attr & 0x10 = directory)
                   ; returns: edi = final 8.3 name buffer, fat_dir = first cluster of the target directory
```

Conventions: FAT names are case-insensitive (`fat_name83` already upper-cases); both `/` and `\` are
accepted as separators (`\` is handier on vi's command line).

### 1.3 Creating/removing directories

```
mkdir DIR    → allocate a cluster, zero it → write "." and ".." entries (.. points at the parent, 0 for root)
             → find a free slot in the parent directory and write the entry (attr = 0x10, first cluster, size 0)
rmdir DIR    → the directory must be empty (only "." and "..") → write 0xE5 to the entry's first byte, mark the cluster chain free again
```

### 1.4 Current directory + shell

```
cwd        dd 0        ; first cluster of the current directory (0 = root)
cwd_path   db "\\", 0  ; for the prompt
cd <dir>    supports cd .., cd \, cd A/B
mkdir <name>
rmdir <name>
ls [path]   with no argument, lists the current directory
cat <path> / write <path> <content> / run <path>
```

The prompt changes from `> ` to `\` or `\SUB> ` (so you can see at a glance where you are).

### 1.5 Other places that have to change along

* `cat`'s file-buffer limit stays 60 KB;
* functions 7/8 of `int 0x30` (read/write file) already take a string — just let them eat paths, and C programs and vi benefit automatically;
* vi/editor: give the file-name argument a path (`run vi docs/notes.txt`); they only hand the name to the kernel anyway.

## 2. FAT32 (later; amounts to replacing half the driver)

### 2.1 Detection

Read the BPB on mount and **support both**:

| | FAT16 | FAT32 |
|---|---|---|
| BPB offset 13 `spc` | sectors per cluster | same |
| offset 14 `reserved` | reserved sectors | same |
| offset 16 `nfats` | number of FATs | same |
| offset 17 `root_ents` | root-directory entries | **must be 0** |
| offset 22 `sectors_per_fat16` | sectors per FAT | **0** (use offset 36) |
| offset 36 `spf32` | — | sectors per FAT (32-bit) |
| offset 44 `root_cluster` | — | root-directory first cluster (usually 2) |
| offset 48 `fsinfo` | — | FSInfo sector number |
| offset 32 `total32` | total sectors of a large partition | same |

Detection: offset 22 == 0 → FAT32; otherwise go by offset 22. Store `fat_type` (=16/32) and
**dispatch FAT reads/writes on it**:

```asm
fat_get_entry:   ; cluster in eax → eax = table entry (FAT16: 2 bytes; FAT32: 4 bytes & 0x0FFFFFFF)
fat_set_entry:   ; FAT32 has to preserve the top 4 bits (they're not part of the cluster number)
```

### 2.2 Data area and root directory

* FAT32 data area start = reserved sectors + nfats × spf32 (**no fixed root area**);
* root directory = the cluster chain starting at `root_cluster` → which reuses the "directory cursor"
  from section 1 (the root becomes a cluster chain too);
* a pitfall along the way: FAT32's "top 4 bits of a cluster number are reserved", so comparing against
  end-of-chain has to mask with `& 0x0FFFFFFF` before checking `>= 0x0FFFFFF8`, otherwise a value like
  0xFFFFFFF7 gets treated as a valid cluster;
* FSInfo only gets updated on writes (free cluster count / next free cluster); the kernel just needs
  to read it and check the 0x41615252 signature — not updating it doesn't affect mounting, other
  systems will rescan themselves.

### 2.3 Disk-building tool

`tools/mkfat.py` gains `--fat32`:
* 32-bit entries (0x0FFFFFF8 end-of-chain, 0x0FFFFFFF end-of-table, top 4 bits reserved);
* `root_ents=0`, `spf32`, `root_cluster=2`, FSInfo sector in the BPB;
* root directory contents written on the chain starting at cluster 2;
* a somewhat bigger partition (an 8 MB partition of a 16 MB image actually has room for FAT32, it's
  just that the cluster count has to land in the FAT32 range ≥ 65525 — so **the partition has to
  grow** to ~40 MB, or use 512-byte clusters; whichever you pick goes into the image size in the
  Makefile).

### 2.4 How the tests prove it really is FAT32

* run `ls` / `cat` / `write` through the whole thing;
* when parsing the image offline, **don't just use our own Python parser** — cross-check with
  `mtools`/`mcopy` from `mtools`, or `fsck.fat -v` (they know FAT32); that's the hard evidence that
  "other people's tools accept it" too;
* mount test: `sudo mount -o loop,offset=... kkernel-hd.img /mnt` works too (needs root; make it
  "do it if we can, skip if not" in the test).

## 3. Step-by-step plan (each step runs and commits on its own)

1. **Directory-cursor refactor** (behaviour unchanged, `make test` must still be all green) — pull out
   `fat_dir_open/entry/next` and switch `fat_find`/`fat_list`/`fat_write_file` over to it;
2. **Subdirectories**: `fat_resolve`, `mkdir`, `cd`, `ls path`, `cat/run path`;
3. **Writing in subdirectories**: create/modify files inside a subdirectory (the free-slot search has
   to walk the cluster chain; extend the directory cluster when necessary);
4. **Tests + docs**: local QEMU assertions + offline parsing + `fsck.fat` cross-check;
5. **FAT32 detection + read**: mount, `ls`, `cat` (read-only first);
6. **FAT32 write**: create files, modify files, allocate clusters (32-bit entries + FSInfo);
7. **mkfat.py --fat32 + Makefile + tests**: build a FAT32 image and run the whole suite above on it;
8. docs wrap-up (README, filesystem.md, and turn this file into a "done" record).

## 4. Existing problems to fix along the way

* "long output garbles the screen after scrolling" from [known-issues.md](known-issues.md) has to be
  fixed first — otherwise the new `ls` on a big directory and `cat` on a long file will drag the
  tests down with it (last round's tests got bitten by it);
* `make test` drifts when the machine is saturated by other work (the fixed waits in the tests aren't
  enough): screen reads for full-screen programs have to "wait until the screen is stable and accept
  it only when enough characters are recognisable", which is already being done.
