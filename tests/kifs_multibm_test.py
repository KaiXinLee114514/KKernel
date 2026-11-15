#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
KiFS 内核多块位图支持测试。

卷的位图占多个 4 KiB 块(256 MiB 卷 / 4 KiB 块 → 2 块位图,每块管 32768 个数据块)。
把 data_next 预置到 40000,让写入分配必须落在**第 2 个位图块**上,验证:
  * mount 能按需换入任意位图块;
  * 分配/释放跨位图块边界正确,flush 把脏位图块作为整块 delta 提交;
  * journal 提交后宿主 mkifs.py fsck 的 free_blocks 必须与位图一致(回归:
    老代码把位图块索引算成 block/64,改到数据区,fsck 报 free_blocks 不符);
  * 重启后数据/位图都持久。

用法:
    python3 -u tests/kifs_multibm_test.py --img build/kkernel-hd.img \
        --host-tool /Files/Project/kifs/tools/mkifs.py
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import qemu_test as Q          # noqa: E402
import kifs_crash_test as C    # noqa: E402  复用 VM / 屏幕 OCR / 命令辅助

KIFS_LBA = 22528
VOL_MIB = 256
BLOCK = 4096
FONT = os.path.normpath(os.path.join(HERE, "..", "font", "full-kkf.bin"))
SHELL_MARK = 'type "help" for commands.'


def build_image(base_hd, host_tool, workdir):
    """在 base_hd 副本尾部烧一个 256 MiB/4 KiB 块、data_next=40000 的 KiFS 卷。"""
    hd = os.path.join(workdir, "hd.img")
    shutil.copyfile(base_hd, hd)
    os.truncate(hd, 336 * 1024 * 1024)

    kimg = os.path.join(workdir, "kifs.img")
    C.host_run(host_tool, "format", kimg, "--size-mib", str(VOL_MIB),
               "--block-size", str(BLOCK), "--label", "KKIFSBM")
    C.host_run(host_tool, "mkdir", kimg, "/docs")
    C.host_run(host_tool, "mkdir", kimg, "/w")
    C.host_run(host_tool, "write", kimg, "/docs/hello.txt", "--data", "hello from KiFS")
    src = os.path.join(workdir, "big.bin")
    with open(src, "wb") as f:
        f.write(bytes(range(256)) * 50)          # 12800 B → 4 块
    C.host_run(host_tool, "write", kimg, "/docs/big.bin", "--from", src)

    # 预置 data_next=40000(直接改主 superblock 三副本),让新分配跨进第 2 个位图块
    host_dir = os.path.dirname(os.path.abspath(host_tool))
    py = ("import sys; sys.path.insert(0, %r)\n"
          "import mkifs\n"
          "img = mkifs.Image(%r)\n"
          "img.sb.data_next = 40000\n"
          "sb = img.sb.pack()\n"
          "img.write_data_block(1, sb); img.write_data_block(2, sb);\n"
          "img.write_data_block(img.sb.total_blocks - 1, sb)\n"
          "img.close()\n") % (host_dir, kimg)
    subprocess.run([sys.executable, "-c", py], check=True)
    rc, out = C.host_run(host_tool, "fsck", kimg)
    assert "fsck 通过" in out, out

    with open(kimg, "rb") as f:
        vol = f.read()
    with open(hd, "r+b") as f:
        f.seek(KIFS_LBA * 512)
        f.write(vol)
    return hd, src


def run_cmd(vm, glyphs, cmd, expect, timeout=12.0):
    if not C.stage_command(vm, glyphs, cmd):
        raise C.ProbeFail("命令打不进去: %s" % cmd)
    C.press_enter(vm)
    t0 = time.monotonic()
    lines = []
    while time.monotonic() - t0 < timeout:
        lines = C.shot_text(vm, glyphs)
        joined = "\n".join(lines)
        if expect in joined:
            return lines
        time.sleep(0.05)
    raise C.ProbeFail("等不到 %r 的输出:\n%s" % (expect, C.dump(lines)))


def check(ok, desc, extra=""):
    print(("✅ " if ok else "❌ ") + desc)
    if not ok and extra:
        print(extra)
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--img", default="build/kkernel-hd.img")
    ap.add_argument("--host-tool", default="/Files/Project/kifs/tools/mkifs.py")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    workdir = tempfile.mkdtemp(prefix="kifs-multibm-")
    results = []
    vm = None
    try:
        hd, src = build_image(args.img, args.host_tool, workdir)
        glyphs = Q.load_font(FONT)
        vm = C.VM(hd, "m0", workdir)
        C.wait_shell(vm, glyphs)

        run_cmd(vm, glyphs, "kifs info", "free_blocks=65430")
        results.append(check(True, "mount 256MiB 卷(位图 2 块)/ free_blocks=65430"))
        lines = C.shot_text(vm, glyphs)
        results.append(check(any("total_blocks=65536" in l for l in lines),
                             "卷容量读到 65536 块(跨位图块卷被接受)"))

        run_cmd(vm, glyphs, "kifs stat /docs/big.bin", "start=37 blocks=4")
        results.append(check(True, "现有文件 extent 正常"))
        run_cmd(vm, glyphs, "kifs cat /docs/big.bin | kifs write /w/copy.bin",
                "wrote 12801 bytes to /w/copy.bin")
        results.append(check(True, "跨位图块写入成功(wrote 12801 bytes)"))
        run_cmd(vm, glyphs, "kifs stat /w/copy.bin", "start=40000 blocks=4")
        results.append(check(True, "新文件分配落在第 2 个位图块区间(extent start=40000)"))
        run_cmd(vm, glyphs, "kifs info", "free_blocks=65426")
        results.append(check(True, "free_blocks 减 4(65430→65426)"))
        tail, bad = C.check_journal_screen(vm, glyphs)
        results.append(check(not bad, "journal 全部 state=END(无 OPEN/COMMIT)", "\n".join(bad)))

        # ---- 重启持久化 ----
        vm.kill(); vm = None
        vm = C.VM(hd, "m1", workdir)
        C.wait_shell(vm, glyphs)
        run_cmd(vm, glyphs, "kifs info", "free_blocks=65426")
        results.append(check(True, "重启后 free_blocks 一致(65426)"))
        run_cmd(vm, glyphs, "kifs stat /w/copy.bin", "start=40000 blocks=4")
        results.append(check(True, "重启后 copy.bin 的 extent 持久化"))
        run_cmd(vm, glyphs, "kifs cat /w/copy.bin | run WC", "12801 bytes")
        results.append(check(True, "重启后 cat copy.bin 字节数一致(12801)"))

        vm.kill(); vm = None

        # ---- 宿主交叉验证 ----
        vol = os.path.join(workdir, "vol-extract.img")
        with open(hd, "rb") as f:
            f.seek(KIFS_LBA * 512)
            data = f.read(VOL_MIB * 1024 * 1024)
        with open(vol, "wb") as f:
            f.write(data)
        rc, out = C.host_run(args.host_tool, "fsck", vol)
        ok = "fsck 通过" in out and "相符" not in out
        results.append(check(ok, "宿主 mkifs.py fsck 通过(free_blocks 与位图一致)", out))
        out = os.path.join(workdir, "copy-read.bin")
        C.host_run(args.host_tool, "read", vol, "/w/copy.bin", "--out", out)
        expect = open(src, "rb").read() + b"\n"     # kifs write 从管道读时补一个换行
        results.append(check(open(out, "rb").read() == expect,
                             "宿主读回 copy.bin 与源逐字节一致(含管道补的换行)"))

        print("\n%d 项通过, %d 项失败" % (sum(results), len(results) - sum(results)))
        return 0 if all(results) else 1
    finally:
        if vm is not None:
            vm.kill()
        if args.keep or not all(results):
            print("(工作目录保留: %s)" % workdir)
        else:
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
