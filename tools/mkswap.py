#!/usr/bin/env python3
"""mkswap.py — 给 KKernel 的 HD 镜像末尾追加一块 swap 区(Phase C)

用法:
    python3 tools/mkswap.py <hd.img> <out.img> [--size-mib N]

做两件事:
  1) 把 hd.img 原样拷成 out.img;
  2) 在 out.img 末尾(16 MiB 处)追加一块 swap 区:
     - 起始 LBA 32768(16 MiB / 512)
     - 首 4 KiB(8 扇区)是头块:前 16 字节 = "KSWP" + version(1) + total_slots + slot_size(4096),
       其余保留为 0;数据槽从 +8 扇区开始(避免槽 0 覆盖头,内核里叫 SWAP_HDR_SECTORS)

镜像里没有这块区(或者头不合法)时,内核的 swap_init 会静默禁用 swap——
所以普通的 hd 测试镜像完全不受影响。
"""
import struct
import sys
import os

SWAP_LBA = 32768          # 和 kernel/swap.asm 的 SWAP_LBA 一致
SECTOR = 512
SLOT_SIZE = 4096
VERSION = 1
MAGIC = b"KSWP"


def main():
    raw = sys.argv[1:]
    size_mib = 16
    if "--size-mib" in raw:
        i = raw.index("--size-mib")
        size_mib = int(raw[i + 1])
        del raw[i:i + 2]
    args = [a for a in raw if not a.startswith("--")]
    if len(args) != 2:
        print(__doc__)
        return 1
    src, dst = args
    if not os.path.exists(src):
        print(f"mkswap: source image not found: {src}")
        return 1
    size = size_mib * 1024 * 1024
    # 首 4 KiB 留给 KSWP 头(内核从 SWAP_LBA+8 扇区开始用槽,见 kernel/swap.asm)
    total_slots = size // SLOT_SIZE - 1

    data = bytearray(open(src, "rb").read())
    if len(data) > SWAP_LBA * SECTOR:
        print(f"mkswap: {src} is bigger than the swap start LBA ({SWAP_LBA})")
        return 1
    # 补零到 swap 区起点(普通 16 MiB HD 镜像正好在这里)
    if len(data) < SWAP_LBA * SECTOR:
        data.extend(b"\x00" * (SWAP_LBA * SECTOR - len(data)))
    # swap 头 + 零填充
    data.extend(b"\x00" * 0)  # 占位:下面写头和区
    start = SWAP_LBA * SECTOR
    header = struct.pack("<4sIII", MAGIC, VERSION, total_slots, SLOT_SIZE)
    blob = bytearray(b"\x00" * size)
    blob[0:len(header)] = header
    data = bytearray(data[:start]) + blob
    open(dst, "wb").write(data)
    print(f"mkswap: {dst} = {len(data)} bytes, swap at LBA {SWAP_LBA}, "
          f"{total_slots} slots x {SLOT_SIZE} B ({size_mib} MiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
