[简体中文](zh-CN/usb-disk.md)

# USB mass storage (read/write + FAT mount) + USB 2.0 EHCI + hotplug

> Plug in a USB stick; after `usbdisk mount`, the shell's `ls / cat / write / cp / mkdir / rm`
> operate directly on the FAT16/FAT32 filesystem on the stick; `usbdisk umount` switches cleanly back
> to the internal ATA disk.
> Underneath it's **two controllers — UHCI (USB 1.1 full-speed) + EHCI (USB 2.0 high-speed)** — with
> Bulk-Only Transport and SCSI READ(10)/WRITE(10); both controllers have **hotplug** on their ports
> (periodic PORTSC CSC polling).

## Usage

```
> usb                                       ← controller + device list
usb: UHCI 8086:7020 io 0xC040 p1=0x00000005 p2=0x00000000
usb: EHCI 8086:24CD mmio 1000 ports 6
usb: kbd ctrl=UHCI port=1 speed=full addr=1 class=HID
usb: msd ctrl=EHCI port=1 speed=high addr=2 class=MSD
usb: HID boot keyboard ready
usb: HID reports 0
usbdisk: QEMU QEMU HARDDISK rev 2.5+
usbdisk: 16384 sectors x 512 B = 8192 KiB

> usbdisk mount                ← scan the MBR partition table and switch the FAT filesystem to the stick
usbdisk: mounted FAT16 at LBA 2048, 16384 sectors

> ls
USB_HI.TXT
> cat USB_HI.TXT
hello from usb
> write NEW.TXT hello-usb
wrote NEW.TXT (9 bytes)
> mkdir USBDIR
created directory USBDIR

> usbdisk umount               ← sync the cache, restore the ATA FAT geometry/cwd
usbdisk: unmounted, FAT device back to ATA FAT16 at LBA 6144

> ls                           ← back on the internal hard disk
BIN  DOCS  SRC  ...
```

Hotplug (plug and unplug while running, no reboot needed):

```
> usbdisk                     ← with no stick inserted
usbdisk: status: not mounted (FAT device: ATA)

[plug in the stick, about 1~2 seconds later]
> usb                         ← ctrl=EHCI class=MSD shows up in the usb list
usb: msd ctrl=EHCI port=1 speed=high addr=2 class=MSD

[pull the stick straight out while running]
usbdisk: removed, FAT device back to ATA FAT16    ← if mounted, rolls back to ATA automatically
> usbdisk status
usbdisk: status: not mounted (FAT device: ATA)   ← the command doesn't crash
```

Keyboards hotplug too: plug in a USB keyboard and it works immediately (depending on which controller
it's on: EHCI uses high-speed interrupt transfers, UHCI full-speed); unplug it and it falls back to
the PS/2 keyboard.

| Command | What it does |
|---|---|
| `usb` | controller info (UHCI I/O base / EHCI MMIO) + device list (ctrl/port/speed/addr/class) + HID report count |
| `usbdisk` | INQUIRY: vendor / model / revision + sector count + current mount state |
| `usbdisk mount` | switch the block device to USB; scan the MBR for a FAT partition (treat it as a superfloppy if LBA0 has no partition table) and `fat_mount` |
| `usbdisk umount` | SYNCHRONIZE CACHE → restore the ATA FAT state (geometry/directory cache/allocation hint) → cwd back to root |
| `usbdisk status` | whether the current FAT device is ATA or USB, and whether it's FAT16 or FAT32 (safe with no stick inserted) |
| `usbdisk read <lba> [count]` | READ(10) raw sector read; prints the first 64 bytes by default |
| `usbdisk hexdump <lba>` | READ(10) one sector and dump the full 512 bytes |
| `usbdisk write <lba>` | write self-test: back up the original sector → write a pattern → read back and verify byte by byte → restore the original sector |
| `usbdisk mbr` | decode the four MBR partition entries at LBA 0 |
| `usbdisk sense` | REQUEST SENSE, look at the most recent error sense data |

After mount, every file command goes over USB — you **don't** prefix `ls/cat/write` with a device
(the U3 trade-off: a single FAT context + explicit mount/umount is cleaner than a `USB:` prefix on
every command).

## Layering

```
shell's ls/cat/write/cp/mkdir/rm/...        (shell.asm, completely unaware that block devices exist)
        ↓
fat.asm   FAT16 / FAT32 filesystem             (fat_dev_read / fat_dev_write)
        ↓
blkdev.asm  block-device abstraction: blkdev_ata / blkdev_usb + the blk_cur pointer
        ↓                                    (unified ABI: eax=LBA, ecx=sector count, edi=buf)
   ata.asm  ATA PIO read/write             usbdisk.asm  SCSI READ(10)/WRITE(10) → USB BOT
        ↓
usb2.asm  controller/device model + hotplug task (usb_hotplug_task)
        ↓
ehci.asm  EHCI (USB2.0 high-speed)      usb.asm  UHCI (USB1.1 full-speed, the original driver)
  async QH/qTD (control+bulk)             control transfers + periodic frame list (interrupt keyboard)
  periodic frame list (interrupt keyboard)   frame list (original implementation)
```

- **U1 (blkdev)**: `kernel/blkdev.asm`. Descriptor 20B (name / read function / write function /
  sector count / sector size); `blk_read_sectors` / `blk_write_sectors` dispatch on `[blk_cur]`, with
  the same ABI as the old `ata_read_sectors` (`eax=LBA, ecx=n, edi=buf`; writes take `esi=src`), so the
  FAT driver only had to swap `call ata_read_sectors` for `call fat_dev_read` (30 places), with zero
  logic changes. The USB backend moves data in chunks of ≤8 sectors (USB_MSD_DATA 4 KiB buffer) and
  preserves all caller registers.
- **U2 (BOT write path)**: `usb_scsi_write` = WRITE(10) (CDB `0x2A`) + CBW flags=0x00 + data OUT
  + CSW check; on failure it does `REQUEST SENSE` and retries up to 3 times. `usb_scsi_sync` =
  SYNCHRONIZE CACHE(10).
- **U3 (FAT mount)**: on `usbdisk mount`, `fat_state_save` backs up the whole FAT global state
  (geometry/cache/fat_dir/fat_next_free/…, `fat_state_begin..fat_state_end`) to 0x3C6000, then
  `blkdev_select_usb` + `fat_set_part_base` + a fresh `fat_mount`; `umount` does the reverse with
  `fat_state_restore` + `blkdev_select_ata`. No filesystem / a read failure rolls back to ATA.
- **EHCI (USB 2.0 high-speed)**: `kernel/ehci.asm`. PCI scan for class `0C/03/prog-if 20`, BAR0 4 KiB
  MMIO mapped through paging to the fixed VA `0xFE000000`; operational register base = BAR0 +
  CAPLENGTH. Structures live at 0x3D2000~0x3D3260: 4 KiB periodic frame list, async QH, qTD array,
  interrupt QH/qTD/buffer. Control and bulk transfers share one **async QH as the list head**
  (`EHCI_XFER_QH`): for each transfer write the QH → **fully restart the async schedule** (CMD clear
  ASE → wait for STS.ASS to drop → write ASYNCLISTADDR → CMD set ASE), then poll the last qTD's
  ACTIVE/error bits. QEMU's EHCI is unreliable about "patching a QH that's still in the ring and
  ringing the doorbell" (it stops fetching qTDs from the second transfer on); restarting the whole
  thing is the most robust. The interrupt keyboard uses an interrupt QH hung in the periodic frame
  list every 8 frames.
- **Dual controllers (usb2.asm)**: each device records its own `ctrl` (1=UHCI / 2=EHCI), `port`,
  `speed`, address and endpoints; control/bulk/interrupt transfers dispatch on the controller to
  `usb_uhci_*` / `ehci_*`. USB 2.0 enumeration rules: EHCI only takes high-speed devices, and
  full/low-speed devices are handed by EHCI to the companion UHCI after port reset (writing
  PORTSC.OWNER) — in QEMU usb-storage is 480 Mb/s high-speed (goes through EHCI) and usb-kbd is
  12 Mb/s full-speed (goes through UHCI by default; explicitly attached to `ehci.0` it's high-speed
  too and goes through EHCI).
- **Hotplug**: `usb_poll` in the PIT IRQ0 only does **read-only PORTSC change detection** (compare the
  CSC bit with the last snapshot → set `usb_hotplug_pending`); the real enumeration / reset /
  configure / unplug happens in `usb_hotplug_task` in **thread context** (hooked in before the
  shell's `hlt` wait-for-key, entered once per tick), so the sleeps/delays/control transfers in
  enumeration never run inside the interrupt. Insert: port reset → generic enumeration → fill in the
  keyboard/USB-stick record by type; remove: clear the record, `usbdisk_on_unplug` automatically
  switches FAT back to ATA, keyboard falls back to PS/2.
- **usb_lock**: `usb_hotplug_process` holds the lock for its whole run, and `usb_bot` holds it for
  the whole BOT transaction (`usb_mutex`, the sleepable, recursive mutex in kernel/lock.asm).
  Enumeration/reset/control transfers and BOT bulk share the controller's QH/qTD/data buffers, so
  multiple threads (two shells reading/writing the stick at once, hotplug enumeration colliding with
  file operations) have to be mutually excluded. Same-thread reentry is fine (enumeration calls
  usbdisk_init→usb_bot).

## Tests

```bash
make -s test-usb-kbd      # USB keyboard (UHCI + HID boot): enumerate / HID report / shift typing → shell
make -s test-usb          # raw read-only disk (UHCI): INQUIRY / capacity / READ(10) / MBR / SENSE
make -s test-usb-rw       # stick FAT16: mount → ls/cat/write/cp/mkdir/rm → umount → remount → host check
make -s test-usb-rw32     # same, but the stick is FAT32 (64 MiB)
make -s test-usb-ehci     # EHCI high-speed stick (mount/read-write/umount) + UHCI keyboard login
make -s test-usb-hotplug  # hotplug: plug/unplug the stick while running (auto umount/remount with contents intact) + keyboard
                          # plug/unplug (UHCI/EHCI) + PS/2 fallback after unplugging the keyboard
```

The `--usb-rw` test's USB-stick image is **built on the fly in pure Python** by
`make_usb_fat16_image()` / `make_usb_fat32_image()` in `tests/qemu_test.py` (MBR + BPB + two FATs +
root directory + a pre-seeded USB_HI.TXT, with no mkfs.fat/mtools dependency). After QEMU finishes,
an **independent Python FAT parser** (`Fat16` class + `check_usb_fat_image()`) **reads the stick
image offline** and confirms the bytes the kernel wrote really landed on disk: file contents
byte-identical, what was `rm`ed is really gone, both FATs agree, the cluster chain has no
crossings/short chains; at the same time it verifies the internal ATA image hasn't changed by a
single byte (mount/umount didn't write to it by mistake).

`--usb-hotplug` uses QEMU monitor's `device_add` / `device_del` to plug devices in and out at run
time (note: when QEMU removes usb-storage it also reclaims the `-drive if=none` backend, so before
re-inserting you have to `drive_add` the backend again; the kernel's hotplug task is asynchronous, so
the test polls the `usb` output until `class=MSD` shows up before mounting).

## Limitations / known issues

- At most one of each device type: one USB keyboard + one USB mass-storage device (keyboard and stick
  can be used at the same time, but two sticks or two keyboards can't); no USB hub support.
- After mount you can't use files on the USB stick and on ATA at the same time (single FAT context);
  to copy files, mount, operate, umount.
- WRITE(10) does one data phase per BOT (≤8 sectors each), and the FAT table is written one sector at
  a time; EHCI high-speed is faster than UHCI, but it's still not bulk streaming (one schedule per
  BOT), and it doesn't chase peak speed.
- No long file names (LFN) — consistent with the internal FAT driver, 8.3 short names only.
- EHCI's periodic frame list is only used for keyboard interrupt transfers; no isochronous
  (audio/UVC and such) support.
- Unplugging / a bad CSW returns an error and rolls the mount back, without a retry storm.
- Hotplug detection is 100 Hz polling of the PORTSC CSC bit (not a USB interrupt); insertion to
  usable takes about 1~2 seconds.

## Where it could grow

- xHCI (USB 3.x, new platforms on real hardware).
- Multi-device/hub support (right now `usb2.asm`'s record table only has slots for keyboard + mass
  storage).
- More complete HID report parsing (mouse, multimedia keys).
- Isochronous transfers on EHCI's periodic frame list.
