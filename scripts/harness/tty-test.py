#!/usr/bin/env python3
# tty-test.py — agnos 1.57.13: the console line's mode and the fd-kind query from RING 3, and SIGWINCH to watchers only.
# Wrapped by scripts/smoke/tty-smoke.sh (a sweep row). Issues (archived at 1.57.13):
#   docs/development/issues/archived/2026-10-12-console-line-discipline-has-no-ring3-control.md  (console_mode#110)
#   docs/development/issues/archived/2026-10-12-no-way-to-ask-what-an-fd-is.md                   (fd_kind#111)
#   docs/development/issues/archived/2026-10-12-console-grid-changes-without-sigwinch.md         (SIGWINCH 28)
#
# ⭐ WHAT IT DRIVES. tests/waits/waitx seeded as /bin/agnsh (the driver) and /bin/waitx (its children), /wx/mode = `tty`,
# on a TTY_SELFTEST kernel (a plain kernel plus console_mode#110's geometry knob — no live modeset is reachable under
# QEMU, so the knob calls the same fb_set_geom a modeset does). An xHCI keyboard, keys typed through HMP `sendkey`.
# The driver prints `WXK-READY <t>` when the harness may type, `WXK-LINE <t> <hex>` for what each read returned and
# `WXK-OK <t>` / `WXK-FAIL <t>` for its own checks. THE ECHO is checked HERE, on the serial log (the console echo is
# kputc -> COM1, and the driver prints nothing between a READY and its LINE):
#   T0 warm-up Enter (the first key of a session is swallowed: retried)
#   T1 the echo is observable: `seen1` appears (the positive control — without it every NOECHO check is vacuous)
#   T2 NOECHO (waiting read): `qjxa<BS>k` reads back `qjxk` and NOTHING is echoed (no byte, no BS SP BS, no newline);
#      a second hidden line `wvz` (the mode persists while its holder lives); clear; `seen2` echoed again (M-TTY1)
#   T3 NOECHO (the NB reader, agnsh's prompt poll): `nbx<BS>q` reads back `nbq`, hidden (backspace editing too)
#   T4 FLUSH: typeahead `junk` discarded (the next line is `kept`); an NB partial `ab` discarded (-3 -> -2, next `cd`);
#      NOECHO|FLUSH in one call (TCSETSF): `zzz` discarded, `pw` hidden
#   T5 the mode dies with its owner: a child EXITS holding NOECHO, then a child is KILLED holding it while blocked in a
#      read — after each the driver's line (`seen5`, `seen6`) is ECHOED                                (mutation M-TTY2)
#   T6 fd_kind#111: console 0/1/2, a file, a directory, both pipe ends (PIPE), a closed fd, signalfd/epoll/timerfd,
#      invalid fds -> -1                                                                               (mutation M-TTY4)
#   T7 SIGWINCH: SAME geometry = no post; SHRINK and RESTORE = one 28 each to the bit-28 signalfd watcher, NOTHING to a
#      process holding a bit-10 signalfd, nothing to the driver (no signalfd)                         (mutation M-TTY3)
#   T8 a signalfd reads a signal >= 32 (kill#16 self 40 -> a bit-40 signalfd reads 40 once): the vfs_read_signalfd walk
#      stopped at 31 until 1.57.13                                                                     (mutation M-TTY5)
#   (1.57.13 review)
#   T9 the mode is the CONSOLE's, never the line's: a CHILD of the NOECHO holder reads `cq` hidden and exits (the first
#      cut's MODE-OWN deadlocked it); a holder that never reads keeps nobody waiting — the driver's NB poll `nbh` and
#      blocking read `bh` both return, hidden; the holder exits and `seen9` is echoed                    (mutation M-TTY6)
#   T10 a BLOCKING read of console fd 2 with no key pending for >= 1 s returns `fd2r`, echoed (it hlt'd at IF=0 until
#      1.57.13); fd 1 non-blocking answers -2                                                           (mutation M-TTY7)
#   T11 THE GHOST PROMPT, on the FRAMEBUFFER (HMP screendump — COM1 has no cursor): ED 2J, NOECHO, `GHOSTPW: ` with no
#      newline at row 0, a hidden `gpw`, the program's "\n" and three lines. The prompt must still be at row 0 and on no
#      other row; also fd_kind on a kernel memfile (/fonts, VFS_MEMFILE) = 2                            (mutation M-TTY8)
# Boots -smp 1, then -smp 4 (KVM when /dev/kvm is writable, else multi-threaded TCG — printed); banner-gated (a boot
# with no "AGNOS kernel v" is VOID, retried, never scored). Denies the shared SMOKE_INVARIANT_DENY (_invdeny.py),
# `fault: pid=`, #GP/#PF/PANIC and a second `kybernet: exec /bin/agnsh`.
# Env: TTY_SMP (default "1 4"), SMOKE_KVM (0 = TCG), QEMU_TRIES (default 6).
# Exit: 0 every check passed on every boot · 1 a check failed · 2 VOID (a boot never handed off, nothing failed).
import os, re, socket, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _freshness import refuse_stale_kernel, refuse_stale, exerciser_sources
from _invdeny import smoke_invariant_deny
from _qsock import qsock

AGNOS = os.path.join(ROOT, "build/agnos")
WAITX_DIR = os.path.join(ROOT, "tests/waits")
WAITX = os.path.join(WAITX_DIR, "build/waitx")
# 1.57.13 merge (the carry track's sibling rule): <NAME>_ROOT, else ${SIBLINGS_ROOT:-$ROOT/..}/<repo>.
GNOBOOT = os.environ.get("GNOBOOT_ROOT", os.path.join(os.environ.get("SIBLINGS_ROOT", os.path.join(ROOT, "..")), "gnoboot")) + "/build/BOOTX64.EFI"
refuse_stale_kernel(ROOT)
# ⛔ The geometry knob exists only in a TTY_SELFTEST build: a plain kernel answers -1 and T7 would fail for the WRONG
# reason. scripts/build.sh records the flags of the image it wrote.
try:
    _flags = open(os.path.join(ROOT, "build/agnos.flags")).read()
except OSError:
    _flags = ""
if "flags=TTY_SELFTEST\n" not in _flags:
    print("FAIL: build/agnos is not a TTY_SELFTEST build (build/agnos.flags: %r) — run TTY_SELFTEST=1 sh scripts/build.sh" % _flags.split("\n")[0], flush=True)
    sys.exit(1)
refuse_stale(WAITX, exerciser_sources(WAITX_DIR), "sources (tests/waits)",
             "(cd tests/waits && cyrius build --agnos waitx.cyr build/waitx)")
INV_DENY = smoke_invariant_deny()
WORK = os.path.join(ROOT, "build/tty")
SEED = os.path.join(WORK, "seed")
IMG = os.path.join(WORK, "K.img")
MON = qsock(os.path.join(ROOT, "build/tty-mon.sock"))   # 1.57.13 merge: short + per-tree (_qsock.py) — a sweep worker copy's
                                                          # build/ path is the 108-byte sun_path class the carry track fixed
EXT2_FEATURES = os.environ.get("EXT2_SMOKE_FEATURES", "^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg")
TRIES = int(os.environ.get("QEMU_TRIES", "6"))
VOID_RE = re.compile(r"gnoboot: fail @|BootManagerMenuApp|Please select boot device")

def p(*a): print(*a, flush=True)
for need in (AGNOS, WAITX, GNOBOOT):
    if not os.path.exists(need):
        p("FAIL: missing", need, "— this harness measured NOTHING"); sys.exit(1)
OVMF_CODE = OVMF_VARS = None
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/edk2/x64/OVMF_CODE.fd",
          "/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_CODE_4M.fd"):
    if os.path.exists(c): OVMF_CODE = c; break
for c in ("/usr/share/edk2/x64/OVMF_VARS.4m.fd", "/usr/share/edk2/x64/OVMF_VARS.fd",
          "/usr/share/OVMF/OVMF_VARS.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"):
    if os.path.exists(c): OVMF_VARS = c; break
if not OVMF_CODE or not OVMF_VARS:
    p("FAIL: OVMF not found — this harness measured NOTHING"); sys.exit(1)

def sh(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if r.returncode != 0:
        p("FAIL build step:", cmd, "\n", r.stderr.decode("latin1")[:400]); sys.exit(1)

# ---- the image: ESP 1-33 MiB (gnoboot + kernel) + ext2 33-100 MiB seeded with the driver (ring3-seed.sh's recipe)
subprocess.run(["rm", "-rf", WORK]); os.makedirs(os.path.join(SEED, "bin")); os.makedirs(os.path.join(SEED, "wx"))
for n in ("agnsh", "waitx"):
    subprocess.run(["cp", WAITX, os.path.join(SEED, "bin", n)])
open(os.path.join(SEED, "wx", "mode"), "w").write("tty\n")
sh(f"dd if=/dev/zero of={IMG} bs=1M count=128 status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100MiB")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-TTY -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={33 * 1048576} {IMG} {(67 * 1048576) // 4096}")

def accel(smp):
    if smp <= 1: return ["-cpu", "max"]
    if os.access("/dev/kvm", os.W_OK) and os.environ.get("SMOKE_KVM", "1") == "1": return ["-enable-kvm", "-cpu", "host"]
    return ["-accel", "tcg,thread=multi", "-cpu", "max"]

KEYS = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '/': 'slash', '\b': 'backspace', '\x04': 'ctrl-d'}

class Boot:
    def __init__(self, smp, attempt):
        self.ser = os.path.join(WORK, f"serial-smp{smp}.log")
        img = os.path.join(WORK, f"K-smp{smp}.img")
        subprocess.run(["cp", IMG, img])
        subprocess.run(["cp", OVMF_VARS, os.path.join(WORK, "vars.fd")]); subprocess.run(["chmod", "+w", os.path.join(WORK, "vars.fd")])
        open(self.ser, "w").close()
        try: os.unlink(MON)
        except FileNotFoundError: pass
        self.q = subprocess.Popen(["qemu-system-x86_64", "-machine", "q35", "-m", "512M"] + accel(smp) + ["-smp", str(smp),
            "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
            "-drive", f"if=pflash,format=raw,file={WORK}/vars.fd",
            "-drive", f"file={img},format=raw,if=none,id=disk0", "-device", "nvme,drive=disk0,serial=AGNOS-TTY",
            "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
            "-serial", f"file:{self.ser}", "-display", "none", "-no-reboot",
            "-monitor", f"unix:{MON},server,nowait"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.s = None
        for _ in range(100):
            try:
                self.s = socket.socket(socket.AF_UNIX); self.s.connect(MON); break
            except OSError: time.sleep(0.1)
        if self.s: self.s.settimeout(0.5)
    def text(self):
        try: return open(self.ser, "rb").read().decode("latin1")
        except OSError: return ""
    def drain(self):
        # NON-blocking: a blocking recv with the socket's 0.5 s timeout made every key cost 0.6 s and put that
        # into the latency figures
        self.s.setblocking(False)
        try:
            while True:
                if not self.s.recv(65536): break
        except OSError: pass
        self.s.settimeout(0.5)
    def typ(self, s):
        # returns the host time the LAST key was sent (the latency origin); each key is held 100 ms by sendkey
        t_last = time.time()
        for ch in s:
            key = KEYS.get(ch, ch)
            if ch.isupper(): key = "shift-" + ch.lower()
            self.s.sendall(("sendkey " + key + "\n").encode())
            t_last = time.time()
            time.sleep(0.15); self.drain()
        return t_last
    def wait(self, pat, timeout, since=0):
        dl = time.time() + timeout
        while time.time() < dl:
            t = self.text()
            m = re.search(pat, t[since:])
            if m: return m, time.time()
            if self.q.poll() is not None: break
            time.sleep(0.02)
        return None, time.time()
    def shot(self, name):
        # HMP screendump (PPM). Returns the path once the file has stopped growing, else None.
        path = os.path.join(WORK, name + ".ppm")
        try: os.unlink(path)
        except FileNotFoundError: pass
        self.s.sendall(("screendump " + path + "\n").encode())
        last = -1
        dl = time.time() + 8
        while time.time() < dl:
            time.sleep(0.25); self.drain()
            sz = os.path.getsize(path) if os.path.exists(path) else -1
            if sz > 100 and sz == last: return path
            last = sz
        return None
    def kill(self):
        try: self.q.kill(); self.q.wait(5)
        except Exception: pass

def hexs(s): return s.encode().hex()

def read_ppm(path):
    # (w, h, rgb bytes) of a P6 screendump, or None
    try:
        with open(path, "rb") as f:
            if f.readline().strip() != b"P6": return None
            line = f.readline()
            while line.startswith(b"#"): line = f.readline()
            w, h = map(int, line.split())
            f.readline()
            return w, h, f.read(w * h * 3)
    except (OSError, ValueError):
        return None

npass = nfail = nvoid = 0
lat = []
def ok(msg):
    global npass; npass += 1; p("  PASS:", msg)
def bad(msg):
    global nfail; nfail += 1; p("  FAIL:", msg)


def segment(t, a, b):
    """The serial text after the line holding marker `a` and before marker `b` (None when either is missing)."""
    i = t.find(a)
    if i < 0: return None
    i = t.find("\n", i)
    if i < 0: return None
    j = t.find(b, i + 1)
    if j < 0: return None
    return t[i + 1:j]
KLINE = re.compile(r"^\s*(\[\s*\d+\.\d+\]|kybernet:|hid:|xhci:|lifecycle:|klug:|kbd:)")
def echo_of(seg):
    """What the console ECHOED inside a segment: the segment minus whole kernel/diagnostic lines."""
    if seg is None: return None
    keep = []
    for ln in seg.split("\n"):
        if KLINE.search(ln): continue
        keep.append(ln)
    return "\n".join(keep)

for smp in [int(x) for x in os.environ.get("TTY_SMP", "1 4").split()]:
    p(f"\n=== boot -smp {smp}  accel: {' '.join(accel(smp))} ===")
    b = None
    for attempt in range(1, TRIES + 1):
        b = Boot(smp, attempt)
        m, _ = b.wait(r"AGNOS kernel v|gnoboot: fail @|BootManagerMenuApp|Please select boot device", 90)
        t = b.text()
        if "AGNOS kernel v" in t: break
        b.kill()
        subprocess.run(["cp", b.ser, b.ser + f".attempt{attempt}"])
        why = VOID_RE.search(t)
        p(f"  (VOID attempt {attempt}: {why.group(0) if why else 'no banner'} — the kernel never ran; retrying)")
        b = None
    if b is None:
        p(f"  VOID: [smp{smp}] the firmware never handed off in {TRIES} attempts — not scored"); nvoid += 1; continue
    got0 = False
    shots = [None, None]
    try:
        m, _ = b.wait(r"WXK-READY t0", 90)
        if not m: bad(f"[smp{smp}] the driver never became ready (WXK-READY t0)"); raise StopIteration
        for _ in range(3):
            b.typ("\n")
            m, _ = b.wait(r"WXK-LINE t0 ", 1.0)
            if m: got0 = True; break
        if not got0:
            m, _ = b.wait(r"WXK-LINE t0 ", 3.0); got0 = m is not None
        # T1 / T2 / T3
        b.wait(r"WXK-READY t1", 10); time.sleep(0.2)
        t_sent = b.typ("seen1\n"); m, t_seen = b.wait(r"WXK-LINE t1 ", 10)
        if m: lat.append((smp, "t1", int((t_seen - t_sent) * 1000)))
        b.wait(r"WXK-READY t2\n", 10); time.sleep(0.2)
        b.typ("qjxa\bk\n"); b.wait(r"WXK-LINE t2\.0 ", 10)
        time.sleep(0.2); b.typ("wvz\n"); b.wait(r"WXK-LINE t2\.1 ", 10)
        b.wait(r"WXK-READY t2c", 10); time.sleep(0.2)
        b.typ("seen2\n"); b.wait(r"WXK-LINE t2\.2 ", 10)
        b.wait(r"WXK-READY t3", 10); time.sleep(0.3)
        b.typ("nbx\bq\n"); b.wait(r"WXK-LINE t3 ", 10)    # backspace editing under NOECHO on the NB reader
        # T4 — typeahead while nobody reads (the driver sleeps 2.5 s after t4a / t4e)
        b.wait(r"WXK-READY t4a", 10); b.typ("junk")
        b.wait(r"WXK-READY t4b", 10); time.sleep(0.2)
        b.typ("kept\n"); b.wait(r"WXK-LINE t4 ", 10)
        b.wait(r"WXK-READY t4c", 10); time.sleep(0.3); b.typ("ab")
        b.wait(r"WXK-READY t4d", 15); time.sleep(0.3)
        b.typ("cd\n"); b.wait(r"WXK-LINE t4d ", 10)
        b.wait(r"WXK-READY t4e", 10); b.typ("zzz")
        b.wait(r"WXK-READY t4f", 10); time.sleep(0.2)
        b.typ("pw\n"); b.wait(r"WXK-LINE t4f ", 10)
        # T5
        b.wait(r"WXK-READY t5\n", 15); time.sleep(0.2)
        b.typ("seen5\n"); b.wait(r"WXK-LINE t5 ", 10)
        b.wait(r"WXK-READY t5b", 20); time.sleep(0.2)
        b.typ("seen6\n"); b.wait(r"WXK-LINE t5b ", 10)
        # T6 / T7 / T8 run without keys
        b.wait(r"WXK-(OK|FAIL) t8", 60)
        # T9 — the mode is the console's: a child of the NOECHO holder reads; a holder that never reads holds nothing
        b.wait(r"WXK-READY t9a", 15); time.sleep(0.3)
        b.typ("cq\n"); b.wait(r"WXK-CHILD t9a ", 10)
        b.wait(r"WXK-READY t9b", 20); time.sleep(0.3)
        b.typ("nbh\n"); b.wait(r"WXK-LINE t9b ", 12)
        b.wait(r"WXK-READY t9c", 15); time.sleep(0.3)
        b.typ("bh\n"); b.wait(r"WXK-LINE t9c ", 10)
        b.wait(r"WXK-READY t9d", 15); time.sleep(0.3)
        b.typ("seen9\n"); b.wait(r"WXK-LINE t9d ", 10)
        # T10 — a read on console fd 2: the read is BLOCKED with no key pending for >= 1 s before the first key
        b.wait(r"WXK-READY t10", 15); time.sleep(1.2)
        b.typ("fd2r\n"); b.wait(r"WXK-LINE t10 ", 10)
        # T11 — the ghost prompt: screendump the prompt, type the hidden line, screendump after the program's lines
        m, _ = b.wait(r"GHOSTPW: ", 15); time.sleep(0.8)
        shots[0] = b.shot(f"ghost-before-smp{smp}")
        b.typ("gpw\n")
        b.wait(r"WXK-READY t11shot", 10); time.sleep(0.8)
        shots[1] = b.shot(f"ghost-after-smp{smp}")
        b.wait(r"WXK-(OK|FAIL) t11", 15)
        b.wait(r"kybernet: shell exited", 30)
    except StopIteration:
        pass
    t = b.text()
    b.kill()
    subprocess.run(["cp", b.ser, os.path.join(WORK, f"serial-smp{smp}.final.log")])
    for ln in t.splitlines():
        if "WXK-" in ln or "WXT-" in ln or "WAITX-" in ln or "kybernet: " in ln: p("    " + ln.strip())
    def line_of(tag):
        m = re.search(r"WXK-LINE " + re.escape(tag) + r" (\S+)", t)
        return m.group(1) if m else None
    p(f"  -- -smp {smp} verdicts --")
    for k in ("t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11"):
        if re.search(r"WXK-OK " + k + r"\b", t): ok(f"[smp{smp}] {k}: the driver's own check")
        else: bad(f"[smp{smp}] {k}: the driver's own check (no WXK-OK {k})")
    if got0: ok(f"[smp{smp}] T0 a blocking read returned the warm-up line")
    else: bad(f"[smp{smp}] T0 no line after 3 Enters")
    for tag, want in (("t1", "seen1\n"), ("t2.0", "qjxk\n"), ("t2.1", "wvz\n"), ("t2.2", "seen2\n"), ("t3", "nbq\n"),
                      ("t4", "kept\n"), ("t4d", "cd\n"), ("t4f", "pw\n"), ("t5", "seen5\n"), ("t5b", "seen6\n"),
                      ("t9b", "nbh\n"), ("t9c", "bh\n"), ("t9d", "seen9\n"), ("t10", "fd2r\n"), ("t11", "gpw\n")):
        if line_of(tag) == hexs(want): ok(f"[smp{smp}] {tag} read back {want!r}")
        else: bad(f"[smp{smp}] {tag} read back {line_of(tag)} (want {hexs(want)} {want!r})")
    # THE ECHO — what the console printed between each READY and its LINE
    def shown(a, b_, word):
        e = echo_of(segment(t, a, b_))
        return e is not None and word in e
    def hidden(a, b_, chars, tag):
        e = echo_of(segment(t, a, b_))
        if e is None: bad(f"[smp{smp}] {tag}: markers {a!r}..{b_!r} not found"); return
        leaked = [c for c in e if c in chars or c in "\x08\n"]
        if leaked: bad(f"[smp{smp}] {tag}: the console ECHOED {e!r} (want nothing)")
        else: ok(f"[smp{smp}] {tag}: nothing echoed (no byte, no BS, no newline)")
    if shown("WXK-READY t1", "WXK-LINE t1 ", "seen1"): ok(f"[smp{smp}] T1 the plain read ECHOED 'seen1' (the echo is observable)")
    else: bad(f"[smp{smp}] T1 'seen1' was not echoed: {echo_of(segment(t, 'WXK-READY t1', 'WXK-LINE t1 '))!r}")
    hidden("WXK-READY t2\n", "WXK-LINE t2.0 ", "qjxak", "T2 NOECHO 'qjxa<BS>k'")
    hidden("WXK-LINE t2.0 ", "WXK-LINE t2.1 ", "wvz", "T2 NOECHO second line 'wvz' (the mode persisted)")
    if shown("WXK-READY t2c", "WXK-LINE t2.2 ", "seen2"): ok(f"[smp{smp}] T2 after the clear 'seen2' is ECHOED")
    else: bad(f"[smp{smp}] T2 after the clear 'seen2' not echoed: {echo_of(segment(t, 'WXK-READY t2c', 'WXK-LINE t2.2 '))!r}")
    hidden("WXK-READY t3", "WXK-LINE t3 ", "nbxq", "T3 NOECHO on the NB reader 'nbx<BS>q'")
    if "junk" not in t: ok(f"[smp{smp}] T4 the flushed typeahead 'junk' was never read or echoed")
    else: bad(f"[smp{smp}] T4 'junk' appeared on the console")
    if "zzz" not in t: ok(f"[smp{smp}] T4 NOECHO|FLUSH discarded 'zzz'")
    else: bad(f"[smp{smp}] T4 'zzz' appeared on the console")
    hidden("WXK-READY t4f", "WXK-LINE t4f ", "pw", "T4 NOECHO|FLUSH 'pw'")
    if shown("WXK-READY t5\n", "WXK-LINE t5 ", "seen5"): ok(f"[smp{smp}] T5 after the NOECHO owner EXITED the driver's line is ECHOED")
    else: bad(f"[smp{smp}] T5 after the owner's exit 'seen5' not echoed: {echo_of(segment(t, 'WXK-READY t5' + chr(10), 'WXK-LINE t5 '))!r}")
    if shown("WXK-READY t5b", "WXK-LINE t5b ", "seen6"): ok(f"[smp{smp}] T5 after the NOECHO owner was KILLED the driver's line is ECHOED")
    else: bad(f"[smp{smp}] T5 after the kill 'seen6' not echoed: {echo_of(segment(t, 'WXK-READY t5b', 'WXK-LINE t5b '))!r}")
    # T9 / T10 — the mode is the console's (whoever reads), and console fd 2 is the cooked, echoing line
    hidden("WXK-READY t9a", "WXK-CHILD t9a ", "cq", "T9a a CHILD of the NOECHO holder read 'cq' hidden (no deadlock)")
    if re.search(r"WXK-CHILD t9a " + hexs("cq\n"), t): ok(f"[smp{smp}] T9a the child read 'cq'")
    else: bad(f"[smp{smp}] T9a the child never read 'cq' (the line was held by the mode?)")
    hidden("WXK-READY t9b", "WXK-LINE t9b ", "nbh", "T9b NB poll under ANOTHER process's NOECHO 'nbh'")
    hidden("WXK-READY t9c", "WXK-LINE t9c ", "bh", "T9c blocking read under ANOTHER process's NOECHO 'bh'")
    if shown("WXK-READY t9d", "WXK-LINE t9d ", "seen9"): ok(f"[smp{smp}] T9d after the holder died 'seen9' is ECHOED")
    else: bad(f"[smp{smp}] T9d 'seen9' not echoed: {echo_of(segment(t, 'WXK-READY t9d', 'WXK-LINE t9d '))!r}")
    if shown("WXK-READY t10", "WXK-LINE t10 ", "fd2r"): ok(f"[smp{smp}] T10 the fd-2 read is the cooked line: 'fd2r' ECHOED")
    else: bad(f"[smp{smp}] T10 'fd2r' not echoed: {echo_of(segment(t, 'WXK-READY t10', 'WXK-LINE t10 '))!r}")
    gi = t.find("GHOSTPW: "); gj = t.find("WXK-G1 ", gi + 1) if gi >= 0 else -1
    gseg = t[gi + 9:gj] if gi >= 0 and gj > gi else None
    if gseg == "\n": ok(f"[smp{smp}] T11 NOECHO 'gpw' behind a prompt with no newline: nothing echoed (only the program's own LF)")
    else: bad(f"[smp{smp}] T11 between the prompt and the program's lines the console printed {gseg!r} (want only '\\n')")
    # T11 — THE GHOST PROMPT, on the framebuffer (COM1 has no cursor, so no serial check can see it). The prompt's
    # first 8 cells ('GHOSTPW:') at row 0 of the BEFORE shot are the reference; in the AFTER shot they must still be at
    # row 0 (never erased) and on NO other row (never replayed under the cursor).
    gb = read_ppm(shots[0]) if shots[0] else None
    ga = read_ppm(shots[1]) if shots[1] else None
    if gb is None or ga is None: bad(f"[smp{smp}] T11 a screendump is missing ({shots}) — the ghost check measured nothing")
    elif gb[:2] != ga[:2]: bad(f"[smp{smp}] T11 the two screendumps differ in size {gb[:2]} vs {ga[:2]}")
    else:
        gw, gh = gb[0], gb[1]
        sc = 2 if gh > 1200 else 1
        cw, chh = 8 * sc, 16 * sc
        def cells(img, r, n=8):
            w_, h_, d_ = img
            y0 = r * chh
            if y0 + chh > h_: return None
            return b"".join(d_[(y0 + y) * w_ * 3:(y0 + y) * w_ * 3 + n * cw * 3] for y in range(chh))
        ref = cells(gb, 0)
        nrows = gh // chh
        if ref is None or not any(x > 24 for x in ref):
            bad(f"[smp{smp}] T11 row 0 of the BEFORE shot carries no ink — the console is not drawing; the ghost check measured nothing")
        else:
            ok(f"[smp{smp}] T11 the prompt is drawn at row 0 ({gw}x{gh}, scale {sc}) — the reference")
            if cells(ga, 0) == ref: ok(f"[smp{smp}] T11 the prompt is still at row 0 after the hidden line and three prints")
            else: bad(f"[smp{smp}] T11 row 0 no longer carries the prompt (erased by a print: the fb line stayed live)")
            ghosts = [r for r in range(1, nrows) if cells(ga, r) == ref]
            if not ghosts: ok(f"[smp{smp}] T11 no ghost: the prompt appears on no other row")
            else: bad(f"[smp{smp}] T11 GHOST PROMPT replayed on row(s) {ghosts} (the fb line stayed live after the hidden Enter)")
    if re.search(r"WXK-DONE pass=\d+ fail=0", t): ok(f"[smp{smp}] WXK-DONE with fail=0")
    else: bad(f"[smp{smp}] WXK-DONE with fail=0 (missing or fail > 0)")
    if "WXK-FAIL" in t or "WAITX-FAIL" in t: bad(f"[smp{smp}] a WXK-FAIL / WAITX-FAIL line")
    else: ok(f"[smp{smp}] no WXK-FAIL / WAITX-FAIL line")
    if "kybernet: shell exited" in t: ok(f"[smp{smp}] the driver exited 0 and kybernet saw it")
    else: bad(f"[smp{smp}] the driver never exited (no 'kybernet: shell exited')")
    hits = [ln for ln in t.splitlines() if re.search(INV_DENY, ln)]
    if hits: bad(f"[smp{smp}] a latched kernel invariant line fired: {hits[:3]}")
    else: ok(f"[smp{smp}] no latched kernel invariant line (SMOKE_INVARIANT_DENY via _invdeny.py)")
    f = [ln for ln in t.splitlines() if re.search(r"fault: pid=|#GP|#PF|PANIC", ln)]
    if f: bad(f"[smp{smp}] fault/#GP/#PF/PANIC: {f[:3]}")
    else: ok(f"[smp{smp}] no fault, #GP/#PF or PANIC line")
    ne = t.count("kybernet: exec /bin/agnsh")
    if ne <= 1: ok(f"[smp{smp}] /bin/agnsh was launched once")
    else: bad(f"[smp{smp}] /bin/agnsh was launched {ne} times")

for smp, tag, ms in lat:
    p(f"  latency (reported): smp{smp} {tag} last key -> line seen {ms} ms")
p(f"\n=== tty-test: {npass} passed, {nfail} failed, {nvoid} void ===")
if nfail: p("tty-test: FAIL"); sys.exit(1)
if nvoid: p("tty-test: VOID (a boot never handed off — infrastructure, not the kernel)"); sys.exit(2)
p("tty-test: PASS")
sys.exit(0)
