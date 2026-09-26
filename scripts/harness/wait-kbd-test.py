#!/usr/bin/env python3
# wait-kbd-test.py — agnos 1.57.7 (Path 2, S3d B2): the keyboard read BLOCKS ONLY ITS CALLER, and ONE reader owns
# each cooked line. Wrapped by scripts/smoke/wait-kbd-smoke.sh (a sweep row).
#
# ⭐ WHAT IT DRIVES. tests/waits/waitx is seeded as /bin/agnsh (the driver — kybernet runs it IF=1 time-sliced, so its
# #43 children are ordinary scheduled procs) and /bin/waitx (the `kbdblk` / `spin` children), with /wx/mode = `kbd`.
# A PLAIN kernel, an xHCI keyboard (`-device qemu-xhci -device usb-kbd`), keys typed through the HMP `sendkey`.
# The driver prints `WXK-READY <k>` when it is ready for input and `WXK-OK <k>` / `WXK-FAIL <k>` for its own checks;
# this harness types, then checks the lines on top (per-check PASS/FAIL):
#   K0 warm  — a blocking read answered by Enter (retried up to 3x, 1 s apart: the first key of a session is swallowed)
#   K1 lines — `abc`, `Hello World` (shift), `xz<BS>y` -> `xy`, then Ctrl-D at line start -> 0 (EOF)
#   K2 yields — K = ncpu spinners over an 800 ms window while the driver's blocking read waits: every spinner gets
#              >= 0.8 x W (the reader holds no CPU; mutation M-F0, the held read, -> ~0 at -smp 1)
#   K3 NB yields to the owner — a `kbdblk` child blocks in its read; the driver's NB polls are ALL -2 while the child
#              gets `zz` (mutation M-F3: the NB reader drains the child's keys)
#   K4 one line each — two `kbdblk` children: `one` and `two` go to different children, whole (mutation M-F4)
#   K5 NB keeps a partial line — the driver's NB accumulator holds `ab` (-3) while a child waits for the LINE; `c\n`
#              completes the DRIVER's `abc\n`; then `d\n` reaches the child (mutation M-F6)
# Per-line latency (last key sent -> line seen on the serial log) is REPORTED, not gated.
# Boots -smp 1, then -smp 4 (KVM when /dev/kvm is writable, else multi-threaded TCG — printed). Each boot is
# banner-gated: a boot whose log never shows "AGNOS kernel v" is VOID (retried up to 6x, never scored).
# Denies the shared SMOKE_INVARIANT_DENY (through _invdeny.py — no pasted copy), `fault: pid=`, #GP/#PF/PANIC and a
# second `kybernet: exec /bin/agnsh`.
# Env: WAITKBD_SMP (default "1 4"), SMOKE_KVM (0 = TCG), QEMU_TRIES (default 6).
# Exit: 0 every check passed on every boot · 1 a check failed · 2 VOID (a boot never handed off, nothing failed).
import os, re, socket, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _freshness import refuse_stale_kernel, refuse_stale, exerciser_sources
from _invdeny import smoke_invariant_deny

AGNOS = os.path.join(ROOT, "build/agnos")
WAITX_DIR = os.path.join(ROOT, "tests/waits")
WAITX = os.path.join(WAITX_DIR, "build/waitx")
GNOBOOT = os.environ.get("GNOBOOT_ROOT", os.path.join(ROOT, "../gnoboot")) + "/build/BOOTX64.EFI"
refuse_stale_kernel(ROOT)
refuse_stale(WAITX, exerciser_sources(WAITX_DIR), "sources (tests/waits)",
             "(cd tests/waits && cyrius build --agnos waitx.cyr build/waitx)")
INV_DENY = smoke_invariant_deny()
WORK = os.path.join(ROOT, "build/wait-kbd")
SEED = os.path.join(WORK, "seed")
IMG = os.path.join(WORK, "K.img")
MON = "/tmp/agnos-wait-kbd.sock"
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
open(os.path.join(SEED, "wx", "mode"), "w").write("kbd\n")
sh(f"dd if=/dev/zero of={IMG} bs=1M count=128 status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100MiB")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-WAITKBD -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={33 * 1048576} {IMG} {(67 * 1048576) // 4096}")

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
            "-drive", f"file={img},format=raw,if=none,id=disk0", "-device", "nvme,drive=disk0,serial=AGNOS-WAITKBD",
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
    def kill(self):
        try: self.q.kill(); self.q.wait(5)
        except Exception: pass

def hexs(s): return s.encode().hex()

npass = nfail = nvoid = 0
lat = []
def ok(msg):
    global npass; npass += 1; p("  PASS:", msg)
def bad(msg):
    global nfail; nfail += 1; p("  FAIL:", msg)

for smp in [int(x) for x in os.environ.get("WAITKBD_SMP", "1 4").split()]:
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
    try:
        # K0 — the swallowed first key: Enter, retried until the line comes back
        m, _ = b.wait(r"WXK-READY k0", 90)
        if not m: bad(f"[smp{smp}] the driver never became ready (WXK-READY k0)"); raise StopIteration
        got0 = False
        for _ in range(3):
            b.typ("\n")
            m, _ = b.wait(r"WXK-LINE k0 ", 1.0)
            if m: got0 = True; break
        if not got0:
            m, _ = b.wait(r"WXK-LINE k0 ", 3.0); got0 = m is not None
        # K1 — four blocking reads
        b.wait(r"WXK-READY k1", 10)
        for tag, keys in (("k1.0", "abc\n"), ("k1.1", "Hello World\n"), ("k1.2", "xz\by\n"), ("k1.3", "\x04")):
            t_sent = b.typ(keys)
            m, t_seen = b.wait(r"WXK-LINE " + re.escape(tag) + r" ", 10)
            if m: lat.append((smp, tag, int((t_seen - t_sent) * 1000)))
        # K2 — the reader holds no CPU while the spinners run; type well after the window
        m, _ = b.wait(r"WXK-READY k2", 20)
        time.sleep(1.5)
        t_sent = b.typ("k2\n")
        m, t_seen = b.wait(r"WXK-LINE k2 ", 10)
        if m: lat.append((smp, "k2", int((t_seen - t_sent) * 1000)))
        b.wait(r"WXK-(OK|FAIL) k2", 20)
        # K3 — the child owns the line; the driver's NB polls must not drain it
        m, _ = b.wait(r"WXK-READY k3", 20)
        time.sleep(0.3)
        t_sent = b.typ("zz\n")
        m, t_seen = b.wait(r"WXK-CHILD k3 ", 10)
        if m: lat.append((smp, "k3", int((t_seen - t_sent) * 1000)))
        b.wait(r"WXK-(OK|FAIL) k3", 20)
        # K4 — two children, one whole line each
        m, _ = b.wait(r"WXK-READY k4", 20)
        time.sleep(0.3)
        b.typ("one\n"); time.sleep(0.5); b.typ("two\n")
        b.wait(r"WXK-(OK|FAIL) k4", 20)
        # K5 — the NB partial line keeps the line
        m, _ = b.wait(r"WXK-READY k5a", 20)
        time.sleep(0.3)
        b.typ("ab")
        m, _ = b.wait(r"WXK-READY k5b", 20)
        time.sleep(0.3)
        b.typ("c\n")
        m, _ = b.wait(r"WXK-READY k5c", 20)
        time.sleep(0.3)
        b.typ("d\n")
        b.wait(r"WXK-(OK|FAIL) k5", 20)
        b.wait(r"kybernet: shell exited", 30)
    except StopIteration:
        pass
    t = b.text()
    b.kill()
    subprocess.run(["cp", b.ser, os.path.join(WORK, f"serial-smp{smp}.final.log")])
    for ln in t.splitlines():
        if "WXK-" in ln or "WAITX-" in ln or "kybernet: " in ln: p("    " + ln.strip())
    def line_of(tag):
        m = re.search(r"WXK-LINE " + re.escape(tag) + r" (\S+)", t)
        return m.group(1) if m else None
    def child_lines(tag):
        return re.findall(r"WXK-CHILD " + re.escape(tag) + r" (\S+)", t)
    p(f"  -- -smp {smp} verdicts --")
    for k in ("k0", "k1", "k2", "k3", "k4", "k5"):
        if re.search(r"WXK-OK " + k + r"\b", t): ok(f"[smp{smp}] {k}: the driver's own check")
        else: bad(f"[smp{smp}] {k}: the driver's own check (no WXK-OK {k})")
    if got0: ok(f"[smp{smp}] K0 a blocking read returned the warm-up line")
    else: bad(f"[smp{smp}] K0 no line after 3 Enters")
    for tag, want in (("k1.0", "abc\n"), ("k1.1", "Hello World\n"), ("k1.2", "xy\n")):
        if line_of(tag) == hexs(want): ok(f"[smp{smp}] K1 {tag} = {want!r}")
        else: bad(f"[smp{smp}] K1 {tag} = {line_of(tag)} (want {hexs(want)} {want!r})")
    if line_of("k1.3") == "EOF": ok(f"[smp{smp}] K1 Ctrl-D at line start is EOF (0)")
    else: bad(f"[smp{smp}] K1 Ctrl-D gave {line_of('k1.3')} (want EOF)")
    if line_of("k2") == hexs("k2\n"): ok(f"[smp{smp}] K2 the waiting read returned its line")
    else: bad(f"[smp{smp}] K2 line {line_of('k2')}")
    c3 = child_lines("k3")
    if c3 == [hexs("zz\n")]: ok(f"[smp{smp}] K3 the owning child got 'zz' whole")
    else: bad(f"[smp{smp}] K3 child lines {c3}")
    c4 = child_lines("k4")
    if sorted(c4) == sorted([hexs("one\n"), hexs("two\n")]): ok(f"[smp{smp}] K4 each child got exactly one whole line, and they differ")
    else: bad(f"[smp{smp}] K4 child lines {c4}")
    if line_of("k5") == hexs("abc\n"): ok(f"[smp{smp}] K5 the NB reader kept its partial line: 'abc' whole")
    else: bad(f"[smp{smp}] K5 driver NB line {line_of('k5')} (want {hexs('abc' + chr(10))})")
    c5 = child_lines("k5")
    if c5 == [hexs("d\n")]: ok(f"[smp{smp}] K5 the waiting child got the NEXT line 'd'")
    else: bad(f"[smp{smp}] K5 child lines {c5}")
    if re.search(r"WXK-DONE pass=\d+ fail=0", t): ok(f"[smp{smp}] WXK-DONE with fail=0")
    else: bad(f"[smp{smp}] WXK-DONE with fail=0 (missing or fail > 0)")
    if "WXK-FAIL" in t: bad(f"[smp{smp}] a WXK-FAIL line")
    else: ok(f"[smp{smp}] no WXK-FAIL line")
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
p(f"\n=== wait-kbd-test: {npass} passed, {nfail} failed, {nvoid} void ===")
if nfail: p("wait-kbd-test: FAIL"); sys.exit(1)
if nvoid: p("wait-kbd-test: VOID (a boot never handed off — infrastructure, not the kernel)"); sys.exit(2)
p("wait-kbd-test: PASS")
sys.exit(0)
