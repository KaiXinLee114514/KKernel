#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
KiFS C2:QEMU 真断电注入压测。

做法:在"写文件"这条路径上,趁内核真的往盘上写(journal BEGIN / 记录 / COMMIT /
回放 delta / END)的时候,用 SIGKILL 把 QEMU 进程**当场打死** —— 模拟拔电源,
而不是让客户机"配合地"退出。然后拿同一个镜像重新开机,让内核自己从 journal
恢复,再从三个角度交叉验证:

  1. 内核视角:`kifs cat` 读出来的内容只能是"旧值"或"新值"(不许半截);
     `kifs journal` 里不许有 OPEN / COMMIT 遗留;屏幕上不许有 kifs 错误 / panic。
  2. 磁盘视角:重启后直接扫 64 个 journal 块(校验规则抄内核 kifs_jrn_parse:
     magic / seq / VALID / len<=4076 / crc16),确认没有未 END 的事务。
     这条能抓到"内核屏幕上说干净、盘上却留着 COMMIT"的假干净。
  3. 宿主工具视角:每 3 轮拿 mkifs.py fsck + read 独立验一遍结构
     (块占用、三份 superblock 一致、record/extent 合法)。

崩溃时机不是瞎睡(每轮只挑一种):
  A  按 Enter 后随机 20–120 ms 杀      —— 多半还在解析命令 / CoW 写数据块;
  B  轮询镜像文件 mtime,等**第一次真落盘**后再随机 5–30 ms 杀
     —— 基本压在 BEGIN / 记录 / COMMIT 上(常常留下 OPEN 事务);
  C  轮询 journal 区,等**新事务的 COMMIT 块真的落盘**后再随机 0–8 ms 杀
     —— 正好卡在"已提交、还没回放完/没写 END"的窗口,专考重放;
  D  等屏幕出现 "kifs: wrote ..." 后立刻杀 —— 事务已 END,考"承诺必须兑现";
  E  连写两个文件,第一个确认成功,在第二个的事务里杀;
  F  先用 C 留一个"已提交未 END"的事务,再开机,**等恢复自己开始写盘时补一刀**
     —— 专测 "恢复过程中再断电"。

为什么要 SIGKILL:`os.kill(pid, SIGKILL)`,不做 pkill 模糊匹配、不 killall、
也不只是关 monitor 了事。QEMU 进程没有机会 flush 自己的缓存 —— 和拔电源一样。
socket 路径带 pid 和轮次,不会撞上别的测试。

用法:
    python3 -u tests/kifs_crash_test.py --img build/kkernel-hd.img --iters 20 \\
        --host-tool /Files/Project/kifs/tools/mkifs.py

退出码 0 = 全部通过;1 = 有用例失败(会打印整屏、盘上 journal 状态,并保留
工作目录方便事后验尸)。
"""
import argparse
import os
import random
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import qemu_test as Q          # noqa: E402  复用 Monitor / 字库 / 屏幕 OCR

# 和 Makefile 的 KIFS_LBA 保持一致:16MB 盘上 KiFS 分区固定从 22528 扇区起
KIFS_LBA = 22528
PART_BYTES = 4 * 1024 * 1024
BLOCK = 4096

# journal 块头(和 kernel/kifs.asm 的 KIFS_JRN_* 一字不差)
JRN_MAGIC = 0x4E524A4B         # 'KJRN'
JF_VALID, JF_BEGIN, JF_COMMIT, JF_END = 1, 2, 4, 8
JRN_PAYLOAD = 4076

SHELL_MARK = 'type "help" for commands.'
FONT = os.path.normpath(os.path.join(HERE, "..", "font", "full-kkf.bin"))

# 默认计划:B/C 是真正压 journal 的,权重给高;A/D 是"没写/写完了"的对照。
# A×2, B×6, C×6, D×2, E×2, F×2 = 20 轮,正好覆盖六种时机。
MODE_BAG = ["A"] * 2 + ["B"] * 6 + ["C"] * 6 + ["D"] * 2 + ["E"] * 2 + ["F"] * 2


class ProbeFail(Exception):
    """测试断言失败(镜像/内核的问题),不是脚本自身的 bug。"""


# ---------------------------------------------------------------------------
#  宿主工具
# ---------------------------------------------------------------------------
def host_run(host_tool, *args, check=True):
    p = subprocess.run([sys.executable, "-u", host_tool, *args],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       timeout=180)
    out = p.stdout.decode("utf-8", "replace")
    if check and p.returncode != 0:
        raise ProbeFail("宿主工具 %s 失败(rc=%d):\n%s"
                        % (" ".join(args[:1]), p.returncode, out.strip()))
    return p.returncode, out


def make_initial_image(image, host_tool, workdir):
    """在 image 的 KiFS 分区里准备: /f = OLD-CONTENT,/docs/hello.txt = hello from KiFS"""
    part = os.path.join(workdir, "kifs-init.img")
    if os.path.exists(part):
        os.unlink(part)
    host_run(host_tool, "format", part, "--size-mib", "4", "--label", "KKIFS")
    host_run(host_tool, "mkdir", part, "/docs")
    host_run(host_tool, "write", part, "/docs/hello.txt", "--data", "hello from KiFS")
    host_run(host_tool, "write", part, "/f", "--data", "OLD-CONTENT")
    host_run(host_tool, "fsck", part)          # 初始镜像本身必须干净
    blob = open(part, "rb").read()
    if len(blob) != PART_BYTES:
        raise ProbeFail("初始 KiFS 镜像大小不对: %d" % len(blob))
    with open(image, "r+b") as fh:
        fh.seek(KIFS_LBA * 512)
        fh.write(blob)


# ---------------------------------------------------------------------------
#  直接读盘上的 journal(不信内核的自述)
# ---------------------------------------------------------------------------
def crc16(data, crc=0xFFFF):
    """CRC16-CCITT(poly 0x1021, init 0xFFFF),和 kernel/kifs.asm 的 kifs_crc16 一致。"""
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def read_partition(image):
    with open(image, "rb") as fh:
        fh.seek(KIFS_LBA * 512)
        blob = fh.read(PART_BYTES)
    if len(blob) != PART_BYTES:
        raise ProbeFail("镜像不够大,读不到完整的 KiFS 分区")
    return blob


def journal_layout(blob):
    """从 superblock 里拿 journal 的起始块号和块数。"""
    if blob[BLOCK:BLOCK + 4] != b"KIFS":
        raise ProbeFail("KiFS 分区 superblock magic 不对")
    return (struct.unpack_from("<I", blob, BLOCK + 32)[0],
            struct.unpack_from("<I", blob, BLOCK + 36)[0])


def _parse_journal(blob, base, n, check_crc=True):
    """→ {seq: "END"|"COMMIT"|"OPEN"},规则和内核 kifs_jrn_scan 一致。

    check_crc=True 时只认过得了 kifs_jrn_parse 的块(magic / seq!=0 / VALID /
    len<=4076 / crc16)—— "写了一半的记录块"会被忽略,不会把撕裂数据当有效事务。
    快速轮询时传 False:只关心 BEGIN/COMMIT/END 这些控制块(它们 len=0、
    crc 恒为 0xFFFF),跳过 4 KB 记录的 CRC 能把轮询压到亚毫秒级。
    """
    txns = {}
    for i in range(n):
        off = base + i * BLOCK
        blk = blob[off:off + BLOCK]
        if len(blk) < BLOCK:
            break
        if struct.unpack_from("<I", blk, 0)[0] != JRN_MAGIC:
            continue
        seq = struct.unpack_from("<I", blk, 4)[0]
        if not seq:
            continue
        flags = struct.unpack_from("<H", blk, 8)[0]
        if not flags & JF_VALID:
            continue
        if check_crc:
            ln = struct.unpack_from("<H", blk, 16)[0]
            if ln > JRN_PAYLOAD:
                continue
            if crc16(blk[20:20 + ln]) != struct.unpack_from("<H", blk, 18)[0]:
                continue
        t = txns.setdefault(seq, {"end": 0, "commit": 0})
        if flags & JF_END:
            t["end"] += 1
        elif flags & JF_COMMIT:
            t["commit"] += 1
    return {seq: ("END" if t["end"] else ("COMMIT" if t["commit"] else "OPEN"))
            for seq, t in txns.items()}


def scan_journal(blob):
    """整盘(4MB)解析,带完整校验。"""
    js, n = journal_layout(blob)
    return _parse_journal(blob, js * BLOCK, n, True)


def scan_journal_live(image, layout):
    """只读 journal 区(64 块 = 256KB),不校验记录 CRC —— 给崩溃时机轮询用。"""
    js, n = layout
    with open(image, "rb") as fh:
        fh.seek(KIFS_LBA * 512 + js * BLOCK)
        data = fh.read(n * BLOCK)
    if len(data) != n * BLOCK:
        raise ProbeFail("镜像不够大,读不到 journal 区")
    return _parse_journal(data, 0, n, False)


# ---------------------------------------------------------------------------
#  QEMU
# ---------------------------------------------------------------------------
class VM:
    """一台 QEMU。kill() 就是拔电源(SIGKILL),没有优雅退出。"""

    def __init__(self, image, tag, workdir):
        self.image = image
        self.sock = os.path.join(workdir, "mon-%d-%s.sock" % (os.getpid(), tag))
        self.qmp = self.sock + ".qmp"
        self.mon = None
        for p in (self.sock, self.qmp):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass
        self.proc = subprocess.Popen(
            ["qemu-system-i386",
             "-drive", "file=%s,format=raw,if=ide,index=0" % image,
             "-boot", "c",
             "-display", "none", "-no-reboot", "-usb",
             "-monitor", "unix:%s,server,nowait" % self.sock,
             "-qmp", "unix:%s,server,nowait" % self.qmp],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.launch = time.monotonic()
        try:
            self.mon = Q.Monitor(self.sock, timeout=10)
        except Exception:
            self.kill()
            raise

    def kill(self):
        """SIGKILL:不给 QEMU 任何收尾/刷盘机会。"""
        if self.mon is not None:
            try:
                self.mon.s.close()
            except OSError:
                pass
            self.mon = None
        if self.proc.poll() is None:
            os.kill(self.proc.pid, signal.SIGKILL)
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        for p in (self.sock, self.qmp):
            try:
                os.unlink(p)
            except OSError:
                pass


def shot_text(vm, glyphs):
    """抓一帧并 OCR 成文本行。

    不用 Q.Monitor.screendump():它内部 `cmd(..., wait=1.0)` 每张图固定睡 1 秒,
    一轮几十张图就是几分钟。screendump 命令返回 (qemu) 时文件已经写完了,
    少等这一秒不影响正确性。
    """
    path = vm.mon.shot_path
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    vm.mon.cmd("screendump %s" % path, wait=0.05, budget=5.0)
    for _ in range(50):
        if os.path.exists(path) and os.path.getsize(path) > 1000:
            break
        time.sleep(0.02)
    else:
        raise ProbeFail("screendump 没生成文件(QEMU 可能已经死了)")
    return Q.screen_text(Image.open(path).convert("RGB"), glyphs)


def dump(lines):
    return "\n".join("    | " + l for l in lines if l.strip())


def wait_shell(vm, glyphs, timeout=30.0, settle=0.6):
    """等开机横幅出现,再 settle 一下让 shell 缓过来(开机打印时打字会丢键)。"""
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        if vm.proc.poll() is not None:
            raise ProbeFail("QEMU 在开机途中自己退出了(rc=%s)" % vm.proc.returncode)
        if SHELL_MARK in "\n".join(shot_text(vm, glyphs)):
            time.sleep(settle)
            return time.monotonic() - t0
        time.sleep(0.05)
    raise ProbeFail("等不到 shell 横幅 %r" % SHELL_MARK)


def stage_command(vm, glyphs, cmd, attempts=4):
    """把命令敲进去并确认回显完整(不按 Enter)。丢字就退格重敲。"""
    for k in range(attempts):
        if k:
            for _ in range(len(cmd) + 6):
                vm.mon.sendkey("backspace")
            time.sleep(0.12)
        vm.mon.type_text(cmd, delay=0.0)
        deadline = time.monotonic() + 2.5
        while time.monotonic() < deadline:
            lines = shot_text(vm, glyphs)
            # 只认"行尾正好是这条命令":多了/少了字符都不算(比如 /ff 不能当 /f)
            if any(l.rstrip().endswith(cmd) for l in lines):
                return True
            time.sleep(0.06)
        if os.environ.get("KIFS_CRASH_DEBUG"):
            print("  ! 回显不完整(第 %d 次):\n%s" % (k + 1, dump(lines)))
    return False


def press_enter(vm):
    vm.mon.sendkey("ret")


def wait_marker(vm, glyphs, marker, timeout=8.0):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        if vm.proc.poll() is not None:
            raise ProbeFail("QEMU 意外退出(rc=%s)" % vm.proc.returncode)
        if marker in "\n".join(shot_text(vm, glyphs)):
            return time.monotonic() - t0
        time.sleep(0.05)
    raise ProbeFail("等不到屏幕标记 %r" % marker)


def is_prompt(line):
    s = line.strip()
    return s.startswith("(") and s.endswith(">")


def read_file_value(vm, glyphs, path):
    """kifs cat <path> → 紧跟回显的那一行内容(空文件返回 "")。"""
    cmd = "kifs cat %s" % path
    if not stage_command(vm, glyphs, cmd):
        raise ProbeFail("命令打不进去: %s" % cmd)
    press_enter(vm)
    deadline = time.monotonic() + 6.0
    while time.monotonic() < deadline:
        lines = shot_text(vm, glyphs)
        idx = None
        for i, l in enumerate(lines):
            if l.rstrip().endswith(cmd):
                idx = i
        if idx is None:
            continue
        for l in lines[idx + 1:]:
            s = l.strip()
            if not s:
                continue
            if is_prompt(s):
                return ""
            return s
        time.sleep(0.05)
    raise ProbeFail("读不到 %s 的输出:\n%s" % (path, dump(lines)))


def check_journal_screen(vm, glyphs):
    """kifs journal → (尾部行, 有问题的行)。要求没有 OPEN / COMMIT。"""
    cmd = "kifs journal"
    if not stage_command(vm, glyphs, cmd):
        raise ProbeFail("命令打不进去: %s" % cmd)
    press_enter(vm)
    deadline = time.monotonic() + 10.0
    lines = []
    while time.monotonic() < deadline:
        lines = shot_text(vm, glyphs)
        idx = None
        for i, l in enumerate(lines):
            if l.rstrip().endswith(cmd):
                idx = i
        if idx is None:
            continue
        tail = lines[idx + 1:]
        joined = "\n".join(tail)
        if ("journal:" in joined
                and ("state=" in joined or "(empty)" in joined or "（空）" in joined)
                and any(is_prompt(l) for l in tail)):
            bad = [l for l in tail if "state=OPEN" in l or "state=COMMIT" in l]
            return tail, bad
        time.sleep(0.05)
    raise ProbeFail("等不到 kifs journal 的输出:\n%s" % dump(lines))


# ---------------------------------------------------------------------------
#  崩溃注入
# ---------------------------------------------------------------------------
def wait_first_disk_write(image, t0, timeout=4.0):
    """QEMU 第一次 pwrite 落盘的时刻(相对 t0)。轮询 mtime,1.5 ms 一次。

    比"按 Enter 后睡 N 毫秒"准得多:客户机什么时候真正开始写盘受主机负载影响,
    实测能从 0.17 s 飘到 0.6 s;盯住 mtime 就把"写盘窗口"变成了确定的时间锚点。
    """
    try:
        last = os.stat(image).st_mtime_ns
    except FileNotFoundError:
        return None
    while time.monotonic() - t0 < timeout:
        try:
            if os.stat(image).st_mtime_ns != last:
                return time.monotonic() - t0
        except FileNotFoundError:
            return None
        time.sleep(0.0015)
    return None


def wait_new_commit(image, layout, known, timeout=6.0):
    """轮询 journal 区,等一个**新 seq 的 COMMIT 块**真正落盘。

    为什么盯 COMMIT:这是 journal 的承诺点 —— COMMIT 一落盘,这个事务就必须
    在重启后被完整回放。此后的回放/END 才是真正考验 idempotent 的窗口。
    实测 COMMIT 落盘后到 END 之间只有 ~20-40 ms,靠"睡固定毫秒"很难稳定命中,
    直接盯盘的字节状态就稳了。
    """
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        for seq, st in scan_journal_live(image, layout).items():
            if seq not in known and st != "OPEN":
                return seq, st, time.monotonic() - t0
        time.sleep(0.0005)
    return None, None, None


def crash(vm, image, glyphs, mode, rng, t_ret, layout, known):
    """按 mode 决定什么时候 SIGKILL。返回人类可读的时机描述。"""
    kind = {"E": "C", "F": "C"}.get(mode, mode)
    if kind == "A":
        d = rng.uniform(0.02, 0.12)
        time.sleep(d)
        return "Enter+%dms" % (d * 1000)
    if kind == "B":
        first = wait_first_disk_write(image, t_ret)
        if first is None:
            raise ProbeFail("按 Enter 后 4 秒内镜像一次都没被写(命令没执行?)")
        extra = rng.uniform(0.005, 0.03)
        time.sleep(extra)
        return "首次落盘+%dms" % (extra * 1000)
    if kind == "C":
        seq, st, dt = wait_new_commit(image, layout, known)
        if seq is None:
            raise ProbeFail("按 Enter 后 6 秒内没等到 COMMIT 落盘(命令没执行?)")
        extra = rng.uniform(0.0, 0.008)
        time.sleep(extra)
        return "%s落盘@%.0fms+%dms" % (st, dt * 1000, extra * 1000)
    if kind == "D":
        dt = wait_marker(vm, glyphs, "kifs: wrote", timeout=10.0)
        return "看到 wrote(%.2fs)" % dt
    raise AssertionError(mode)


def classify(pre, post):
    """→ (状态, seq, 新增的 seq 列表)。状态: noop / OPEN / COMMIT / END"""
    new = sorted(set(post) - set(pre))
    if not new:
        return "noop", None, []
    seq = new[-1]
    return post[seq], seq, new


# ---------------------------------------------------------------------------
#  一轮
# ---------------------------------------------------------------------------
def run_iteration(i, iters, mode, image, workdir, glyphs, host_tool, rng, cur,
                  verbose):
    """跑一轮"写入→断电→重启恢复→三重校验"。成功返回统计 dict,失败抛 ProbeFail。"""
    t_start = time.monotonic()
    # 这一轮要写的文件:偶数轮写 /f,奇数轮写 /docs/hello.txt(走目录内容块)
    if mode == "E":
        plan = [("f", "/f", "NEW-%d" % i),
                ("h", "/docs/hello.txt", "H-%d" % i)]
    elif i % 2 == 0:
        plan = [("f", "/f", "NEW-%d" % i)]
    else:
        plan = [("h", "/docs/hello.txt", "H-%d" % i)]
    crash_target = plan[-1]
    confirmed = {k: v for k, v in cur.items()}

    # ---- 1. 开机,把命令敲好(最后一条先不回车) ----
    vm = VM(image, "c%d" % i, workdir)
    try:
        wait_shell(vm, glyphs)
        for key, path, val in plan[:-1]:
            cmd = "kifs write %s %s" % (path, val)
            if not stage_command(vm, glyphs, cmd):
                raise ProbeFail("命令打不进去: %s" % cmd)
            press_enter(vm)
            wait_marker(vm, glyphs, "kifs: wrote", timeout=10.0)
            confirmed[key] = val
        cmd = "kifs write %s %s" % (crash_target[1], crash_target[2])
        if not stage_command(vm, glyphs, cmd):
            raise ProbeFail("命令打不进去: %s" % cmd)
        pre_blob = read_partition(image)
        pre = scan_journal(pre_blob)
        layout = journal_layout(pre_blob)
        press_enter(vm)
        t_ret = time.monotonic()
        when = crash(vm, image, glyphs, mode, rng, t_ret, layout, set(pre))
    finally:
        vm.kill()

    post = scan_journal(read_partition(image))
    state, seq, new = classify(pre, post)
    if mode == "D" and state != "END":
        raise ProbeFail("D 轮已看到 wrote 但盘上没有 END(事务没落完?): %s" % state)
    if verbose:
        print("  [%d] 崩溃: %s → 事务 seq=%s state=%s 新增=%s"
              % (i, when, seq, state, new))

    # ---- 2. 模式 F:开机,等"恢复自己开始写盘"时再补一刀 ----
    rec = {"i": i, "mode": mode, "when": when, "state": state, "seq": seq,
           "recovery_hit": "", "fsck": "", "secs": 0.0}
    if mode == "F":
        vm2 = VM(image, "r%d" % i, workdir)
        try:
            pre2 = scan_journal(read_partition(image))
            t0 = vm2.launch
            hit_at = wait_first_disk_write(image, t0, timeout=8.0)
            if hit_at is None:
                # 上一刀其实已经 END 了,恢复没东西可写;退化成"开机中段杀"
                time.sleep(max(0.0, 1.2 - (time.monotonic() - t0)))
                rec["recovery_hit"] = "没有恢复写盘(上一刀已 END)"
            else:
                time.sleep(rng.uniform(0.0, 0.02))
                rec["recovery_hit"] = "恢复写盘后+<=20ms"
        finally:
            vm2.kill()
        post2 = scan_journal(read_partition(image))
        if rec["recovery_hit"].startswith("恢复"):
            still = [s for s in new if s in post2 and post2[s] != "END"]
            rec["recovery_hit"] += "(被中断)" if still else "(恢复已完成)"

    # ---- 3. 重启验证 ----
    vm = VM(image, "v%d" % i, workdir)
    try:
        boot_screen = "\n".join(shot_text(vm, glyphs))
        got_f = read_file_value(vm, glyphs, "/f")
        got_h = read_file_value(vm, glyphs, "/docs/hello.txt")
        jtail, jbad = check_journal_screen(vm, glyphs)
        screen_all = "\n".join(shot_text(vm, glyphs))
    finally:
        vm.kill()

    # ---- 4. 断言 ----
    problems = []
    if "panic" in (boot_screen + screen_all).lower():
        problems.append("屏幕上出现 panic")
    if 'kifs: no KiFS image' in screen_all:
        problems.append("内核认不出 KiFS 镜像(kifs_init 失败,恢复可能没跑)")

    # 4.1 文件内容:严格到"该是哪个值就是哪个值"
    got = {"f": got_f, "h": got_h}
    for key, path, val in plan:
        old = cur[key] if (key, path, val) == crash_target else confirmed[key]
        if (key, path, val) == crash_target:
            if state in ("COMMIT", "END"):
                allowed = {val}
            else:                      # noop / OPEN:事务没提交,必须还是旧值
                allowed = {old}
        else:
            allowed = {val}            # 已确认写完的,必须一字不差
        if got[key] not in allowed:
            problems.append("%s 内容是 %r,应为 %s(state=%s)"
                            % (path, got[key], " 或 ".join(sorted(allowed)), state))
    for key, path in (("f", "/f"), ("h", "/docs/hello.txt")):
        if key not in [p[0] for p in plan] and got[key] != cur[key]:
            problems.append("%s 没被写过却变了: %r != %r" % (path, got[key], cur[key]))

    # 4.2 屏幕上的 journal 不许有 OPEN / COMMIT
    if jbad:
        problems.append("kifs journal 有未结束事务: %s" % jbad)

    # 4.3 盘上 journal 也不许有(不信屏幕)
    post_verify = scan_journal(read_partition(image))
    left = {s: st for s, st in post_verify.items() if st != "END"}
    if left:
        problems.append("重启后盘上仍有未 END 事务: %s" % left)

    # 4.4 每 3 轮用宿主工具独立验结构 + 读内容
    if i % 3 == 0 or i == iters:
        part = os.path.join(workdir, "check-%d.img" % i)
        with open(part, "wb") as fh:
            fh.write(read_partition(image))
        rc, out = host_run(host_tool, "fsck", part, check=False)
        rec["fsck"] = "pass" if rc == 0 else "FAIL"
        if rc != 0:
            problems.append("宿主 fsck 失败:\n%s" % out.strip())
        for key, path in (("f", "/f"), ("h", "/docs/hello.txt")):
            rc, out = host_run(host_tool, "read", part, path, check=False)
            if rc != 0 or out.rstrip("\n") != got[key]:
                problems.append("宿主读出 %s = %r,内核说 %r"
                                % (path, out.rstrip("\n"), got[key]))
        os.unlink(part)

    if problems:
        raise ProbeFail(";".join(problems) + "\n  崩溃时机: " + when
                        + "\n  最后屏幕:\n" + dump(screen_all.splitlines()))

    rec["f"], rec["h"] = got_f, got_h
    rec["secs"] = time.monotonic() - t_start
    cur["f"], cur["h"] = got_f, got_h
    return rec


# ---------------------------------------------------------------------------
#  main
# ---------------------------------------------------------------------------
def build_plan(iters, rng):
    plan = [MODE_BAG[k % len(MODE_BAG)] for k in range(iters)]
    # 打散:别让同一类都挤在一起(种子固定 → 可复现)
    rng.shuffle(plan)
    # A 是"多半没写盘"的对照,F 必须有一刀,否则少了"恢复中再断电"这一种
    if iters >= 12 and "F" not in plan:
        plan[-1] = "F"
    return plan


def main():
    ap = argparse.ArgumentParser(
        description="KiFS 真断电注入压测(SIGKILL 循环 + 重启 journal 恢复校验)")
    ap.add_argument("--img", default="build/kkernel-hd.img",
                    help="含 KiFS 分区的硬盘镜像(会在临时目录里复制一份来折腾)")
    ap.add_argument("--iters", type=int, default=20, help="断电轮数(默认 20)")
    ap.add_argument("--host-tool", default=os.environ.get(
                        "KIFS_HOST_TOOL", "/Files/Project/kifs/tools/mkifs.py"),
                    help="宿主 mkifs.py 路径(默认取 $KIFS_HOST_TOOL)")
    ap.add_argument("--seed", type=int, default=None,
                    help="随机种子(默认用时间;会打印出来,便于复现)")
    ap.add_argument("--keep", action="store_true", help="保留工作目录(镜像)")
    ap.add_argument("--modes", default=None,
                    help="调试用:只跑这些时机,比如 --modes C 或 --modes B,F")
    ap.add_argument("--verbose", action="store_true", help="打印每轮的崩溃时机/事务状态")
    args = ap.parse_args()

    image = os.path.abspath(args.img)
    if not os.path.exists(image):
        print("找不到镜像: %s\n先跑 `make build/kkernel-hd.img`" % image)
        return 1
    host_tool = os.path.abspath(args.host_tool)
    if not os.path.exists(host_tool):
        print("找不到宿主工具: %s" % host_tool)
        return 1
    if not os.path.exists(FONT):
        print("找不到字库: %s" % FONT)
        return 1
    if args.iters <= 0:
        print("--iters 必须 >= 1")
        return 1

    seed = args.seed if args.seed is not None else int(time.time() * 1000) & 0x7FFFFFFF
    rng = random.Random(seed)
    if args.modes:
        seq = [m.strip().upper() for m in args.modes.split(",") if m.strip()]
        if not seq or any(m not in "ABCDEF" for m in seq):
            print("--modes 只认 A/B/C/D/E/F")
            return 1
        plan = [seq[k % len(seq)] for k in range(args.iters)]
    else:
        plan = build_plan(args.iters, rng)
    glyphs = Q.load_font(FONT)
    workdir = tempfile.mkdtemp(prefix="kkifs-crash-%d-" % os.getpid())
    work_img = os.path.join(workdir, "hd-crash.img")
    keep = args.keep or bool(os.environ.get("KIFS_CRASH_KEEP"))

    print("KiFS 真断电注入压测: %d 轮,seed=%d" % (args.iters, seed))
    print("镜像: %s(复制到 %s 上折腾,原镜像不动)" % (image, work_img))
    print("计划: " + " ".join(plan))
    print("")
    results = []
    t_all = time.monotonic()
    try:
        shutil.copyfile(image, work_img)
        make_initial_image(work_img, host_tool, workdir)

        # 预检:初始镜像必须能开机、读得到两个文件、journal 全 END
        cur = {"f": "OLD-CONTENT", "h": "hello from KiFS"}
        vm = VM(work_img, "pre", workdir)
        try:
            boot = wait_shell(vm, glyphs)
            got = {k: read_file_value(vm, glyphs, p)
                   for k, p in (("f", "/f"), ("h", "/docs/hello.txt"))}
            _, bad = check_journal_screen(vm, glyphs)
            if "panic" in "\n".join(shot_text(vm, glyphs)).lower():
                raise ProbeFail("预检屏幕上出现 panic")
        finally:
            vm.kill()
        if got != cur or bad:
            print("预检失败:开机 %.2fs,读到 %r,journal 问题 %r" % (boot, got, bad))
            raise ProbeFail("初始镜像预检失败")
        print("预检通过:开机 %.2fs,/f=%r,/docs/hello.txt=%r,journal 无 OPEN"
              % (boot, got["f"], got["h"]))
        print("")

        for i, mode in enumerate(plan, 1):
            try:
                rec = run_iteration(i, args.iters, mode, work_img, workdir,
                                    glyphs, host_tool, rng, cur, args.verbose)
            except ProbeFail as e:
                keep = True
                print("[%2d/%2d] %s 失败: %s" % (i, args.iters, mode, e))
                raise
            results.append(rec)
            print("[%2d/%2d] %-2s %-16s 事务=%-6s seq=%-4s /f=%-11s hello=%-15s "
                  "%5.1fs%s"
                  % (i, args.iters, mode, rec["when"], rec["state"],
                     rec["seq"] if rec["seq"] is not None else "-",
                     rec["f"], rec["h"], rec["secs"],
                     ("  fsck=" + rec["fsck"]) if rec["fsck"] else ""))
    except ProbeFail as e:
        print("")
        print("❌ 失败: %s" % e)
        print("工作目录保留在: %s" % workdir)
        return 1
    except KeyboardInterrupt:
        print("\n中断(工作目录 %s)" % workdir)
        return 1
    finally:
        if not keep:
            shutil.rmtree(workdir, ignore_errors=True)
        else:
            print("\n工作目录: %s" % workdir)

    # ---- 总结 ----
    print("")
    total = time.monotonic() - t_all
    counts = {}
    for r in results:
        counts[r["state"]] = counts.get(r["state"], 0) + 1
    print("全部 %d/%d 通过,用时 %.1fs。崩溃时机覆盖: %s"
          % (len(results), args.iters, total,
             " ".join("%s=%d" % (k, v) for k, v in sorted(counts.items()))))
    print("  noop=没赶上写盘  OPEN=崩在 BEGIN/记录  COMMIT=已提交待回放  "
          "END=崩在 END 之后")
    fmodes = [r for r in results if r["mode"] == "F"]
    if fmodes:
        print("  恢复中再断电: " + "; ".join(r["recovery_hit"] for r in fmodes))
    print("最终值: /f=%r  /docs/hello.txt=%r" % (cur["f"], cur["h"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
