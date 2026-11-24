[English](../usb-disk.md)

# USB 大容量储存(读写 + FAT 挂载)+ USB 2.0 EHCI + 热插拔

> 插一个 U 盘,`usbdisk mount` 之后 shell 的 `ls / cat / write / cp / mkdir / rm`
> 直接操作 U 盘上的 FAT16/FAT32 文件系统;`usbdisk umount` 再干净地切回内部 ATA 盘。
> 底层是 **UHCI(USB 1.1 全速)+ EHCI(USB 2.0 高速)双控制器**,Bulk-Only Transport,
> SCSI READ(10)/WRITE(10);两个控制器的端口都有 **热插拔**(定时轮询 PORTSC CSC)。

## 用法

```
> usb                                       ← 控制器 + 设备列表
usb: UHCI 8086:7020 io 0xC040 p1=0x00000005 p2=0x00000000
usb: EHCI 8086:24CD mmio 1000 ports 6
usb: kbd ctrl=UHCI port=1 speed=full addr=1 class=HID
usb: msd ctrl=EHCI port=1 speed=high addr=2 class=MSD
usb: HID boot keyboard ready
usb: HID reports 0
usbdisk: QEMU QEMU HARDDISK rev 2.5+
usbdisk: 16384 sectors x 512 B = 8192 KiB

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

热插拔(运行中插拔,不需要重启):

```
> usbdisk                     ← 没插盘时
usbdisk: status: not mounted (FAT device: ATA)

[插上 U 盘,约 1~2 秒后]
> usb                         ← usb 列表里出现 ctrl=EHCI class=MSD
usb: msd ctrl=EHCI port=1 speed=high addr=2 class=MSD

[运行中直接拔掉 U 盘]
usbdisk: removed, FAT device back to ATA FAT16    ← 若正挂载,自动回滚到 ATA
> usbdisk status
usbdisk: status: not mounted (FAT device: ATA)   ← 命令不会崩
```

键盘也可以热插拔:插上 USB 键盘立即可用(按所在的控制器:EHCI 走高速中断传输,
UHCI 走全速中断传输);拔掉后自动回退到 PS/2 键盘。

| 命令 | 作用 |
|---|---|
| `usb` | 控制器信息(UHCI I/O 基址 / EHCI MMIO)+ 设备列表(ctrl/port/speed/addr/class)+ HID 报告数 |
| `usbdisk` | INQUIRY:厂商 / 型号 / 版本 + 扇区数 + 当前挂载状态 |
| `usbdisk mount` | 切块设备到 USB;扫 MBR 找 FAT 分区(LBA0 无分区表时按超级软盘处理)并 `fat_mount` |
| `usbdisk umount` | SYNCHRONIZE CACHE → 恢复 ATA 的 FAT 状态(几何/目录缓存/分配提示)→ cwd 回根 |
| `usbdisk status` | 当前 FAT 设备是 ATA 还是 USB、挂的是 FAT16 还是 FAT32(没插盘也安全) |
| `usbdisk read <lba> [count]` | READ(10) 裸读扇区;默认打印前 64 字节 |
| `usbdisk hexdump <lba>` | READ(10) 读一个扇区并转储完整 512 字节 |
| `usbdisk write <lba>` | 写自测:备份原扇区 → 写图案 → 读回逐字节校验 → 恢复原扇区 |
| `usbdisk mbr` | 解析 LBA 0 的四个 MBR 分区项 |
| `usbdisk sense` | REQUEST SENSE,看最近一次错误感应数据 |

mount 后所有文件命令都走 USB——**不用**给 `ls/cat/write` 加设备前缀(U3 的取舍:
单 FAT 上下文 + 显式 mount/umount,比给每条命令加 `USB:` 前缀干净)。

## 分层

```
shell 的 ls/cat/write/cp/mkdir/rm/...        (shell.asm,完全不知道块设备的存在)
        ↓
fat.asm   FAT16 / FAT32 文件系统             (fat_dev_read / fat_dev_write)
        ↓
blkdev.asm  块设备抽象:blkdev_ata / blkdev_usb + blk_cur 指针
        ↓                                    (统一 ABI:eax=LBA, ecx=扇区数, edi=buf)
   ata.asm  ATA PIO 读写             usbdisk.asm  SCSI READ(10)/WRITE(10) → USB BOT
        ↓
usb2.asm  控制器/设备模型 + 热插拔任务(usb_hotplug_task)
        ↓
ehci.asm  EHCI(USB2.0 高速)        usb.asm  UHCI(USB1.1 全速,原驱动)
  异步 QH/qTD(控制+批量)              控制传输 + 周期帧列表(中断键盘)
  周期帧列表(中断键盘)               帧列表(原实现)
```

- **U1(blkdev)**:`kernel/blkdev.asm`。描述符 20B(名字 / 读函数 / 写函数 / 扇区数 /
  扇区大小);`blk_read_sectors` / `blk_write_sectors` 按 `[blk_cur]` 分发,ABI 和原来的
  `ata_read_sectors` 一样(`eax=LBA, ecx=n, edi=buf`;写是 `esi=src`),所以 FAT 驱动只是把
  `call ata_read_sectors` 换成 `call fat_dev_read`(30 处),逻辑零改动。
  USB 后端按 ≤8 扇区一块(USB_MSD_DATA 4 KiB 缓冲)分块搬运,并保护所有调用者寄存器。
- **U2(BOT 写路径)**:`usb_scsi_write` = WRITE(10)(CDB `0x2A`)+ CBW flags=0x00 + 数据 OUT
  + CSW 校验;失败 `REQUEST SENSE` 后重试 ≤3 次。`usb_scsi_sync` = SYNCHRONIZE CACHE(10)。
- **U3(FAT 挂载)**:`usbdisk mount` 时 `fat_state_save` 把整段 FAT 全局状态(几何/缓存/
  fat_dir/fat_next_free/…,`fat_state_begin..fat_state_end`)备份到 0x3C6000,
  然后 `blkdev_select_usb` + `fat_set_part_base` + 重新 `fat_mount`;
  `umount` 反过来 `fat_state_restore` + `blkdev_select_ata`。无文件系统/读失败会回滚到 ATA。
- **EHCI(USB 2.0 高速)**:`kernel/ehci.asm`。PCI 扫 class `0C/03/prog-if 20`,BAR0 4 KiB
  MMIO 经 paging 映射到固定 VA `0xFE000000`;操作寄存器基址 = BAR0 + CAPLENGTH。
  结构区在 0x3D2000~0x3D3260:周期帧列表 4 KiB、异步 QH、qTD 数组、中断 QH/qTD/缓冲。
  控制/批量传输共用一个**异步 QH 作为列表头**(`EHCI_XFER_QH`):每笔传输写 QH →
  **完整重启异步调度**(CMD 清 ASE → 等 STS.ASS 落 → 写 ASYNCLISTADDR → CMD 置 ASE),
  然后轮询最后一枚 qTD 的 ACTIVE/错误位。QEMU 的 EHCI 对"留在环里的 QH 改字段再敲门铃"
  不可靠(第二笔起不取 qTD),整段重启最稳。中断键盘用周期帧列表里每 8 帧挂一次的中断 QH。
- **双控制器(usb2.asm)**:每个设备记录自己的 `ctrl`(1=UHCI / 2=EHCI)、`port`、`speed`、
  地址和端点;控制/批量/中断传输按控制器分发到 `usb_uhci_*` / `ehci_*`。
  USB2.0 的枚举规则:EHCI 只认高速设备,全速/低速设备在端口复位后由 EHCI 移交给
  companion UHCI(写 PORTSC.OWNER)——QEMU 里 usb-storage 是 480 Mb/s 高速(走 EHCI),
  usb-kbd 是 12 Mb/s 全速(默认走 UHCI;显式挂 `ehci.0` 时也是高速,走 EHCI)。
- **热插拔**:PIT IRQ0 里的 `usb_poll` 只做**只读的 PORTSC 变化检测**(CSC 位与上次
  快照比较 → 置 `usb_hotplug_pending`);真正的枚举/复位/配置/卸载在**线程上下文**的
  `usb_hotplug_task` 里做(挂在 shell 等键 `hlt` 前,每 tick 进来一次),这样枚举里的
  睡眠/延时/控制传输都不在中断里做。插入:端口复位 → 通用枚举 → 按类型填键盘/U 盘
  记录;拔出:清记录、`usbdisk_on_unplug` 自动把 FAT 切回 ATA、键盘回 PS/2。
- **usb_lock**:`usb_hotplug_process` 整体持锁、`usb_bot` 整个 BOT 事务持锁
  (`usb_mutex`,kernel/lock.asm 的可睡眠可重入 mutex)。枚举/复位/控制传输和 BOT 批量
  共用控制器的 QH/qTD/数据缓冲,多线程(两条 shell 同时读写 U 盘、热插拔枚举撞上文件
  操作)必须互斥。同线程重入没问题(枚举里再调 usbdisk_init→usb_bot)。

## 测试

```bash
make -s test-usb-kbd      # USB 键盘(UHCI + HID boot):枚举 / HID 报告 / shift 打字 → shell
make -s test-usb          # 只读裸盘(UHCI):INQUIRY / 容量 / READ(10) / MBR / SENSE
make -s test-usb-rw       # U 盘 FAT16:mount → ls/cat/write/cp/mkdir/rm → umount → 重挂 → host 校验
make -s test-usb-rw32     # 同上,但 U 盘是 FAT32(64 MiB)
make -s test-usb-ehci     # EHCI 高速 U 盘(mount/读写/umount)+ UHCI 键盘登录
make -s test-usb-hotplug  # 热插拔:运行中插拔 U 盘(自动 umount/重挂内容还在)+ 键盘
                          # 插拔(UHCI/EHCI)+ 拔键盘后 PS/2 回退
```

`--usb-rw` 测试的 U 盘镜像由 `tests/qemu_test.py` 里的 `make_usb_fat16_image()` /
`make_usb_fat32_image()` **纯 Python 现造**(MBR + BPB + 两份 FAT + 根目录 + 预置
USB_HI.TXT,不依赖 mkfs.fat/mtools)。跑完 QEMU 后用**独立的 Python FAT 解析器**
(`Fat16` 类 + `check_usb_fat_image()`)**离线读** U 盘镜像,确认内核写的字节真的落盘:
文件内容逐字节一致、rm 掉的真没了、两份 FAT 一致、簇链无交叉/短链;
同时校验内部 ATA 镜像一字节未变(mount/umount 没误写)。

`--usb-hotplug` 用 QEMU monitor 的 `device_add` / `device_del` 在运行中插拔设备
(注意:QEMU 删掉 usb-storage 时会顺带回收 `-drive if=none` 的后端,重插前要
`drive_add` 重建后端;内核热插拔任务是异步的,测试里轮询 `usb` 输出等 `class=MSD`
出现再 mount)。

## 限制 / 已知问题

- 每种设备最多同时一个:一个 USB 键盘 + 一个 USB 大容量设备(键盘和 U 盘可以同时用,
  但两个 U 盘、两个键盘不行);不支持 USB hub。
- mount 后不能同时用 U 盘和 ATA 的文件(单 FAT 上下文);要拷文件就先 mount、操作、umount。
- WRITE(10) 每次 BOT 一个数据阶段(≤8 扇区/次),FAT 表 1 个扇区一写;EHCI 高速下
  比 UHCI 快,但仍不是 bulk 流式(每笔 BOT 一次调度),不追求极限速度。
- 不支持长文件名(LFN)——和内部 FAT 驱动一致,只用 8.3 短名。
- EHCI 的周期帧列表只用于键盘中断传输;没有 isochronous(音频/UVC 之类)支持。
- 拔盘/坏 CSW 时返回错误并回滚挂载,不做重试风暴。
- 热插拔检测是 100 Hz 轮询 PORTSC 的 CSC 位(不是 USB 中断),插入到能用约 1~2 秒。

## 以后可以往哪长

- xHCI(USB 3.x,真机新平台)。
- 多设备/hub 支持(现在 `usb2.asm` 的记录表只留了键盘 + 大容量两槽)。
- 更完整的 HID 报告解析(鼠标、多媒体键)。
- EHCI 周期帧列表做 isochronous 传输。
