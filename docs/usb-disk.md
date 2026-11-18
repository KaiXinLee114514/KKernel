# USB 大容量储存(只读裸盘)

> 插一个 U 盘,`usbdisk` 一条命令就能看它是什么、读任意扇区、解 MBR 分区表。
> 目前是 **只读 + 裸扇区**:不接 FAT、不写盘 —— 这是刻意的第一步。

## 用法

```
> usbdisk
usbdisk: QEMU QEMU HARDDISK rev 2.5+
usbdisk: 8192 sectors × 512 B = 4096 KiB

> usbdisk read 1                 ← 读 LBA 1,转储前 64 字节
0000: 55 53 42 20 54 45 53 54  20 53 45 43 54 4F 52 20  | USB TEST SECTOR
0010: 31 20 2D 20 4B 4B 65 72  6E 65 6C 20 75 73 62 64  | 1 - KKernel usbd
...

> usbdisk hexdump 1              ← 完整 512 字节(16 行 × 32B + ASCII 列)

> usbdisk mbr
usbdisk: MBR (LBA 0)
p1: type=0x06 start=2048 sectors=4096
p2: type=0x00 start=0 sectors=0
...

> usbdisk sense
sense: rc=0x70 key=0x00 asc=0x00 ascq=0x00
```

| 命令 | 作用 |
|---|---|
| `usbdisk` | INQUIRY:厂商 / 型号 / 版本 + READ CAPACITY(10) 得到的扇区数与容量 |
| `usbdisk read <lba> [count]` | READ(10) 读扇区;默认打印前 64 字节(调试用) |
| `usbdisk hexdump <lba>` | READ(10) 读一个扇区并转储完整 512 字节 |
| `usbdisk mbr` | 读 LBA 0,解析四个 MBR 分区项(type / start_lba / sectors) |
| `usbdisk sense` | REQUEST SENSE,看最近一次错误感应数据 |

## 限制

- **只读**:没有 WRITE(10),也没有 FAT 挂载。要看文件内容只能用 `read`/`hexdump` 自己按手册算。
- **只有 UHCI(USB 1.1)**:QEMU 的 PIIX3 自带的 UHCI 没问题;真机新笔记本多半是 xHCI,那份驱动还没写。
- **一次只认一个 USB 设备,而且要插在第一个枚举到的位置**:`usb_init` 找到第一个设备就停;
  如果先插的是 USB 键盘,`usbdisk` 会报
  `no USB mass storage device (first USB device must be the disk)`。要同时用键盘 + U 盘,
  得先把「多设备枚举」补上(见 [路线图](roadmap.md))。
- 全速设备跑在 12 Mbit/s(足够读小 U 盘),大容量盘能认但读大文件会慢。
- LUN 固定 0、单接口、无热插拔(开机后拔插不重新枚举)。

## 实现

代码在 `kernel/usbdisk.asm`,分三层:

1. **UHCI bulk 传输**(`usb_bulk_xfer`)
   - 复用 `usb.asm` 的帧列表/QH/TD 结构,把帧列表临时切到 `USB_BULK_QH`(传输完切回控制 QH);
   - 一个 TD 一个包(≤ `wMaxPacketSize`),DATA0/DATA1 toggle 显式翻转;
   - 等待时扫 TD 的 `TD_ERRMASK`,3 秒超时;失败清 Active 并恢复链路。
2. **Bulk-Only Transport**(`usb_bot`)
   - CBW 31 字节:`dCBWSignature='USBC'(0x43425355)` + tag + 传输长度 + flags(0x80=IN)+ LUN + CDB(16B);
   - 数据阶段(IN/OUT 由 CDB 决定);CSW 13 字节:`dCSWSignature='USBS'(0x53425355)` + tag + residue + status。
3. **SCSI 命令集**(最小集)
   - `TEST UNIT READY(0x00)` `INQUIRY(0x12,36B)` `READ CAPACITY(10)(0x25,8B,大端)`
     `READ(10)(0x28,LBA 大端 32 位 + 扇区数大端 16 位)` `REQUEST SENSE(0x03,18B)`。

枚举侧(`kernel/usb.asm` 的 `usb_enumerate`):读完整配置描述符后识别
**接口 Class 8 / SubClass 6 / Protocol 0x50**(Mass Storage, SCSI, Bulk-Only),
记录 bulk IN/OUT 端点与 `wMaxPacketSize` → `SET_CONFIGURATION(1)` → `usb_msd_ok=1`;
`usbdisk_init`(开机时在 `usb_init` 之后调用)再做 SCSI 初始化。

> 一个容易摔的坑:控制传输的 EP0 `bMaxPacketSize0` 不是永远 8 字节。
> usb-storage 是 64 —— 所以枚举时先读设备描述符前 8 字节拿它,再按它读完整的描述符。

## 内存

| 区域 | 用途 |
|---|---|
| `0x3C1200` | `USB_BULK_QH`(bulk 常驻队列头) |
| `0x3C1210` | `USB_BULK_TD` 数组(80 × 16B) |
| `0x3C1800` | `USB_BOT_CBW`(31 字节指令块) |
| `0x3C1820` | `USB_BOT_CSW`(13 字节状态块) |
| `0x3C1840` | `USB_MSD_CDB`(16 字节 SCSI 命令) |
| `0x3C1860` | `USB_MSD_TMP`(INQUIRY/容量等临时缓冲) |
| `0x3C2000` | `USB_MSD_DATA`(扇区数据缓冲,4 KiB) |

## 测试

```bash
make test-usb      # 无头自动化:QEMU 挂一个 4 MiB 假 U 盘(已知 MBR + LBA1 文本)
```

测试会断言:设备识别(INQUIRY)、容量(8192 扇区 × 512B = 4096 KiB)、READ(10) 读到 LBA1 的已知文本、
MBR 分区项(`p1: type=0x06 start=2048 sectors=4096`)、REQUEST SENSE 的正常响应。

想手动玩:

```bash
# 造一个 4 MiB 假 U 盘,LBA1 写点东西
python3 - <<'EOF'
buf = bytearray(4 * 1024 * 1024)
buf[446:462] = bytes([0x80,0,0,0,0x06,0,0,0]) + (2048).to_bytes(4,"little") + (4096).to_bytes(4,"little")
buf[510:512] = b"\x55\xAA"
buf[512:512+45] = b"USB TEST SECTOR 1 - KKernel usbdisk read-only"
open("/tmp/usbstick.img","wb").write(buf)
EOF

qemu-system-i386 -m 128 -drive file=build/kkernel-hd.img,format=raw,if=ide \
  -usb -device usb-storage,drive=stick \
  -drive if=none,id=stick,format=raw,file=/tmp/usbstick.img
```

## 以后可以往哪长

- WRITE(10) + 写盘(先只读验证,再放开)
- FAT16/FAT32 挂到 U 盘上(`ls USB/` / `cat USB/DOCS/README.TXT`)
- 多设备枚举(键盘 + U 盘同时用)、热插拔(端口状态变化中断/轮询)
- xHCI 驱动(真机新笔记本),或者先支持 EHCI(USB 2.0)
- `mount` / `umount` 命令,把设备号抽象出来(现在是「第一台 USB 设备」的简化版)
