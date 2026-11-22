# USB 大容量储存(读写 + FAT 挂载)

> 插一个 U 盘,`usbdisk mount` 之后 shell 的 `ls / cat / write / cp / mkdir / rm`
> 直接操作 U 盘上的 FAT16/FAT32 文件系统;`usbdisk umount` 再干净地切回内部 ATA 盘。
> 底层是 UHCI(USB 1.1)+ Bulk-Only Transport,SCSI READ(10)/WRITE(10)。

## 用法

```
> usbdisk                      ← INQUIRY + READ CAPACITY + 挂载状态
usbdisk: QEMU QEMU HARDDISK rev 2.5+
usbdisk: 16384 sectors × 512 B = 8192 KiB
usbdisk: status: not mounted (FAT device: ATA)

> usbdisk mount                ← 扫 MBR 分区表,把 FAT 文件系统切到 U 盘
usbdisk: mounted FAT16 at LBA 2048, 16384 sectors

> ls
USB_HI.TXT
> cat USB_HI.TXT
hello from usb
> write NEW.TXT hello-usb
wrote NEW.TXT (9 bytes)
> mkdir USBDIR
created directory USBDIR

> usbdisk umount               ← 同步缓存,恢复 ATA 的 FAT 几何/cwd
usbdisk: unmounted, FAT device back to ATA FAT16 at LBA 6144

> ls                           ← 又回到内部硬盘
BIN  DOCS  SRC  ...
```

| 命令 | 作用 |
|---|---|
| `usbdisk` | INQUIRY:厂商 / 型号 / 版本 + 扇区数 + 当前挂载状态 |
| `usbdisk mount` | 切块设备到 USB;扫 MBR 找 FAT 分区(LBA0 无分区表时按超级软盘处理)并 `fat_mount` |
| `usbdisk umount` | SYNCHRONIZE CACHE → 恢复 ATA 的 FAT 状态(几何/目录缓存/分配提示)→ cwd 回根 |
| `usbdisk status` | 当前 FAT 设备是 ATA 还是 USB、挂的是 FAT16 还是 FAT32 |
| `usbdisk read <lba> [count]` | READ(10) 裸读扇区;默认打印前 64 字节 |
| `usbdisk hexdump <lba>` | READ(10) 读一个扇区并转储完整 512 字节 |
| `usbdisk write <lba>` | 写自测:备份原扇区 → 写图案 → 读回逐字节校验 → 恢复原扇区 |
| `usbdisk mbr` | 解析 LBA 0 的四个 MBR 分区项 |
| `usbdisk sense` | REQUEST SENSE,看最近一次错误感应数据 |

mount 后所有文件命令都走 USB——**不用**给 `ls/cat/write` 加设备前缀(U3 的取舍:
单 FAT 上下文 + 显式 mount/umount,比给每条命令加 `USB:` 前缀干净)。

## 分层(为什么 FAT 驱动一行设备相关代码都没有)

```
shell 的 ls/cat/write/cp/mkdir/rm/...        (shell.asm,完全不知道块设备的存在)
        ↓
fat.asm   FAT16 / FAT32 文件系统             (fat_dev_read / fat_dev_write)
        ↓
blkdev.asm  块设备抽象:blkdev_ata / blkdev_usb + blk_cur 指针
        ↓                                    (统一 ABI:eax=LBA, ecx=扇区数, edi=buf)
   ata.asm  ATA PIO 读写             usbdisk.asm  SCSI READ(10)/WRITE(10) → USB BOT
```

- **U1(blkdev)**:`kernel/blkdev.asm`。描述符 20B(名字 / 读函数 / 写函数 / 扇区数 /
  扇区大小);`blk_read_sectors` / `blk_write_sectors` 按 `[blk_cur]` 分发,ABI 和原来的
  `ata_read_sectors` 一样(`eax=LBA, ecx=n, edi=buf`;写是 `esi=src`),所以 FAT 驱动只是把
  `call ata_read_sectors` 换成 `call fat_dev_read`(30 处),逻辑零改动。
  USB 后端按 ≤8 扇区一块(USB_MSD_DATA 4 KiB 缓冲)分块搬运,并保护所有调用者寄存器。
- **U2(BOT 写路径)**:`usb_scsi_write` = WRITE(10)(CDB `0x2A`)+ CBW flags=0x00 + 数据 OUT
  + CSW 校验;失败 `REQUEST SENSE` 后重试 ≤3 次。`usb_scsi_sync` = SYNCHRONIZE CACHE(10)。
  底层 `usb_bulk_xfer` 原本就支持 OUT 方向,这次直接复用(按 mps 拆 TD,3 秒超时)。
- **U3(FAT 挂载)**:`usbdisk mount` 时 `fat_state_save` 把整段 FAT 全局状态(几何/缓存/
  fat_dir/fat_next_free/…,`fat_state_begin..fat_state_end`)备份到 0x3C6000,
  然后 `blkdev_select_usb` + `fat_set_part_base` + 重新 `fat_mount`;
  `umount` 反过来 `fat_state_restore` + `blkdev_select_ata`。无文件系统/读失败会回滚到 ATA。

## 测试

```bash
make -s test-usb-kbd   # USB 键盘(UHCI + HID boot):枚举 / HID 报告 / shift 打字 → shell
make -s test-usb       # 只读裸盘:INQUIRY / 容量 / READ(10) / MBR / SENSE
make -s test-usb-rw    # U 盘 FAT16:mount → ls/cat/write/cp/mkdir/rm → umount → 重挂 → host 校验
make -s test-usb-rw32  # 同上,但 U 盘是 FAT32(64 MiB)
```

`--usb-rw` 测试的 U 盘镜像由 `tests/qemu_test.py` 里的 `make_usb_fat16_image()` /
`make_usb_fat32_image()` **纯 Python 现造**(MBR + BPB + 两份 FAT + 根目录 + 预置
USB_HI.TXT,不依赖 mkfs.fat/mtools)。跑完 QEMU 后用**独立的 Python FAT 解析器**
(`Fat16` 类 + `check_usb_fat_image()`)**离线读** U 盘镜像,确认内核写的字节真的落盘:
文件内容逐字节一致、rm 掉的真没了、两份 FAT 一致、簇链无交叉/短链;
同时校验内部 ATA 镜像一字节未变(mount/umount 没误写)。

## 限制 / 已知问题

- 同一时刻只驱动**一台** USB 大容量设备,且只认第一台;没有热插拔(需重新上电)。
- mount 后不能同时用 U 盘和 ATA 的文件(单 FAT 上下文);要拷文件就先 mount、操作、umount。
- WRITE(10) 每次 BOT 一个数据阶段(≤8 扇区/次),FAT 表 1 个扇区一写,速度是 UHCI
  全速量级("能用",不追求快)。
- 不支持长文件名(LFN)——和内部 FAT 驱动一致,只用 8.3 短名。
- 拔盘/坏 CSW 时返回错误并回滚挂载,不做重试风暴。

## 以后可以往哪长

- **U4 EHCI(USB 2.0 高速)**:调研结论见 `AGENT-USB-REPORT.md`;QEMU 的
  `-device usb-ehci` 下 usb-storage 会以 480 Mb/s 高速设备接进来,值得做,但需要
  新的控制器驱动(周期帧列表/异步 QH/qTD/PING)+ 传输层抽象重构,列为后续阶段。
- 多设备枚举(键盘 + U 盘同时用,现在 usb.asm 的键盘和 usbdisk 各自枚举,要统一)。
- 热插拔(端口变化中断 / 定时轮询 PORTSC)。
- xHCI(真机新平台)。
