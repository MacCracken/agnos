#!/usr/bin/env python3
# console-ansi-test.py — agnos 1.57.18: THE CONSOLE AS A TERMINAL, judged on the FRAMEBUFFER.
# Issue: docs/development/issues/archived/2026-11-06-the-console-is-short-of-a-terminal.md (thoth's TUI filter).
#
# tests/waits/waitx mode `ansi` (ph_ansi) draws each screen, prints `WXA-READY <shot>` and blocks in a hidden read of
# fd 0; this harness takes an HMP screendump, judges the cells, and types Enter (re-typed until the probe's `WXA-GOT
# <shot>`: the first key of a session can be swallowed). Cells are judged by COLOUR and by comparison with REFERENCE
# cells drawn on the same screen — never by decoding glyphs, so no second copy of the kashi font lives here (the
# console-line-preserve-test.py rule). The cell grid mirrors fb_console.cyr: 8x16 at scale 1, 16x32 at scale 2
# (height > 1200), origin 0.
#
#   N   console_mode#110 CM_NOSERIAL (4): a frame written while opted out is DRAWN (row 0 inked) but absent from COM1; a
#       CHILD's write while the parent is opted out reaches COM1 (per process); a child that opts out and exits leaves
#       no bit to the next process in its slot (dies with it); the kernel's own line (the first-key `hid:` one-shot,
#       typed inside the window) reaches COM1; the #110 return values (the probe's WAITX-OK ansi-noser).   (M-CA1)
#   A   EL 0 / 1 / 2 with the active background (bce); a row of U+2500 keeps its width; one replacement cell per
#       maximal subpart (U+0100, a lone continuation, an overlong, a truncated and a surrogate sequence); wide =
#       2 cells, combining = 0; U+00E9 is CP437 0x82; a sequence split across two writes; a 10- and a 17-parameter SGR
#       keep their background; SGR 7 / 27; OSC (BEL and ST), DCS, APC, PM, SOS, an OSC carrying LF and UTF-8, a
#       CAN-cancelled OSC all swallowed; an unterminated OSC bounded at 4096 bytes; Tab; the pending wrap (a full row
#       + CR LF leaves no blank line, a full row + glyph wraps first); DECAWM off (?7l).                   (M-CA2..)
#   ED  ED 1 and ED 0 with the active background.
#   C   the cursor: drawn (an underline: the bottom 2 font rows inverted, Linux fbcon's CUR_UNDERLINE), hidden by ?25l,
#       no ghost after a move, a scroll or an erased line, drawn on the last column while a wrap is pending.
#   PAT the framebuffer's PAT entry 1 is WC (`fb: PAT entry 1 = 0x01 WC` — it was the firmware's WT, the scroll's 194 ms).
#   timings (reported, not scored): one 128x64 frame mirrored vs opted out; 32 scrolls of the whole console.
# Env: CA_SMP (default "1 4"), SMOKE_KVM (0 = TCG), QEMU_TRIES (default 6).
# Exit: 0 every check passed on every boot · 1 a check failed · 2 VOID / INCONCLUSIVE (nothing was measured).
import os, re, socket, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _freshness import refuse_stale_kernel, refuse_stale, exerciser_sources
from _invdeny import smoke_invariant_deny
from _qsock import qsock
from _siblings import sibling

AGNOS = os.path.join(ROOT, "build/agnos")
WAITX_DIR = os.path.join(ROOT, "tests/waits")
WAITX = os.path.join(WAITX_DIR, "build/waitx")
GNOBOOT = os.path.join(sibling("gnoboot", "GNOBOOT_ROOT"), "build/BOOTX64.EFI")
refuse_stale_kernel(ROOT)
refuse_stale(WAITX, exerciser_sources(WAITX_DIR), "sources (tests/waits)",
             "(cd tests/waits && cyrius build --agnos waitx.cyr build/waitx)")
INV_DENY = smoke_invariant_deny()
WORK = os.path.join(ROOT, "build/console-ansi")
SEED = os.path.join(WORK, "seed")
IMG = os.path.join(WORK, "K.img")
MON = qsock(os.path.join(ROOT, "build/ca-mon.sock"))
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
try:
    p("kernel flags:", open(os.path.join(ROOT, "build/agnos.flags")).read().split("\n")[0])
except OSError:
    pass

def sh(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if r.returncode != 0:
        p("FAIL build step:", cmd, "\n", r.stderr.decode("latin1")[:400]); sys.exit(1)

# ---- the image: ESP 1-33 MiB (gnoboot + kernel) + ext2 33-100 MiB seeded with the driver (ring3-seed.sh's recipe)
subprocess.run(["rm", "-rf", WORK]); os.makedirs(os.path.join(SEED, "bin")); os.makedirs(os.path.join(SEED, "wx"))
for n in ("agnsh", "waitx"):
    subprocess.run(["cp", WAITX, os.path.join(SEED, "bin", n)])
open(os.path.join(SEED, "wx", "mode"), "w").write("ansi\n")
sh(f"dd if=/dev/zero of={IMG} bs=1M count=128 status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100MiB")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-CA -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={33 * 1048576} {IMG} {(67 * 1048576) // 4096}")

def accel(smp):
    # KVM for both boots when available: the timings are reported under KVM (the issue's numbers are KVM's)
    if os.access("/dev/kvm", os.W_OK) and os.environ.get("SMOKE_KVM", "1") == "1": return ["-enable-kvm", "-cpu", "host"]
    if smp <= 1: return ["-cpu", "max"]
    return ["-accel", "tcg,thread=multi", "-cpu", "max"]

class Boot:
    def __init__(self, smp):
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
            "-drive", f"file={img},format=raw,if=none,id=disk0", "-device", "nvme,drive=disk0,serial=AGNOS-CA",
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
        self.s.setblocking(False)
        try:
            while True:
                if not self.s.recv(65536): break
        except OSError: pass
        self.s.settimeout(0.5)
    def key(self, k):
        self.s.sendall(("sendkey " + k + "\n").encode()); time.sleep(0.15); self.drain()
    def wait(self, pat, timeout, since=0):
        dl = time.time() + timeout
        while time.time() < dl:
            m = re.search(pat, self.text()[since:])
            if m: return m
            if self.q.poll() is not None: break
            time.sleep(0.05)
        return None
    def enter_until(self, pat, tries=5, each=4.0):
        # one Enter, then another only if `pat` (the probe's acknowledgement) has not appeared within `each` seconds
        for _ in range(tries):
            self.key("ret")
            if self.wait(pat, each): return True
        return False
    def shot(self, name):
        path = os.path.join(WORK, name + ".ppm")
        try: os.unlink(path)
        except FileNotFoundError: pass
        self.s.sendall(("screendump " + path + "\n").encode())
        last = -1
        dl = time.time() + 10
        while time.time() < dl:
            time.sleep(0.25); self.drain()
            sz = os.path.getsize(path) if os.path.exists(path) else -1
            if sz > 100 and sz == last: return read_ppm(path)
            last = sz
        return None
    def kill(self):
        try: self.q.kill(); self.q.wait(5)
        except Exception: pass

def read_ppm(path):
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
def ok(msg):
    global npass; npass += 1; p("  PASS:", msg)
def bad(msg):
    global nfail; nfail += 1; p("  FAIL:", msg)
def check(cond, msg):
    (ok if cond else bad)(msg)

BLACK, WHITE = (0, 0, 0), (255, 255, 255)
BLUE, GREEN, RED, MAGENTA, CYAN = (0, 0, 170), (0, 170, 0), (170, 0, 0), (170, 0, 170), (0, 170, 170)

class Screen:
    """One screendump as a cell grid (fb_console.cyr's geometry)."""
    def __init__(self, img):
        self.w, self.h, self.d = img
        self.s = 2 if self.h > 1200 else 1
        self.cw, self.ch = 8 * self.s, 16 * self.s
        self.cols, self.rows = self.w // self.cw, self.h // self.ch
    def cell(self, r, c):
        y0, x0 = r * self.ch, c * self.cw
        return b"".join(self.d[((y0 + y) * self.w + x0) * 3:((y0 + y) * self.w + x0 + self.cw) * 3] for y in range(self.ch))
    def scan(self, cb, y):
        return cb[y * self.cw * 3:(y + 1) * self.cw * 3]
    def colours(self, cb):
        return {tuple(cb[i:i + 3]) for i in range(0, len(cb), 3)}
    def solid(self, r, c, rgb):
        return self.cell(r, c) == bytes(rgb) * (self.cw * self.ch)
    def inked(self, r, c):
        return any(v > 24 for v in self.cell(r, c))
    def glyph(self, r, c, fg=WHITE, bg=BLACK):
        """A glyph cell drawn fg on bg: exactly those two colours, bg the majority (a glyph is mostly background)."""
        cb = self.cell(r, c)
        if self.colours(cb) != {fg, bg}: return False
        nfg = sum(1 for i in range(0, len(cb), 3) if tuple(cb[i:i + 3]) == fg)
        return nfg * 2 < self.cw * self.ch
    def bar(self, r, c):
        """The cursor's bar: the bottom 2 font rows (2*s scanlines) all white."""
        cb = self.cell(r, c)
        return all(self.scan(cb, y) == b"\xff" * (self.cw * 3) for y in range(self.ch - 2 * self.s, self.ch))
    def cursor(self, r, c):
        """A cursor on a BLANK cell: the bar, and nothing above it."""
        cb = self.cell(r, c)
        top = cb[:(self.ch - 2 * self.s) * self.cw * 3]
        return self.bar(r, c) and not any(top)
    def cursors(self, rows):
        return [(r, c) for r in rows for c in range(self.cols) if self.cursor(r, c)]
    def bars(self, rows):
        return [(r, c) for r in rows for c in range(self.cols) if self.bar(r, c)]
    def stripe(self, r, c):
        """Every scanline uniform, exactly one font row (s scanlines) of ink: a full-width horizontal line."""
        cb = self.cell(r, c)
        lit = 0
        for y in range(self.ch):
            sl = self.scan(cb, y)
            if sl == b"\xff" * (self.cw * 3): lit += 1
            elif any(sl): return False
        return lit == self.s

def judge_n(S, t, smp):
    tag = f"[smp{smp}] N"
    check(all(S.inked(0, c) for c in range(17)), f"{tag} the opted-out text is DRAWN (row 0 cells 0-16 inked: 'WXA-SECRET-OPTOUT')")
    i = t.find("WXA-READY noser-begin"); j = t.find("WXA-NOSER-END", i + 1) if i >= 0 else -1
    if i < 0 or j < 0: bad(f"{tag} the opt-out window markers are missing (noser-begin {i}, NOSER-END {j})"); return
    seg = t[i:j]
    check("WXA-SECRET" not in seg, f"{tag} nothing the probe wrote while opted out reached COM1 (no 'WXA-SECRET')")
    check("WXA-SECRET" not in t, f"{tag} 'WXA-SECRET' appears nowhere in the serial log")
    check("A" * S.cols in seg, f"{tag} the frame written BEFORE the opt-out reached COM1 (a row of {S.cols} 'A')")
    check("g" * S.cols not in t, f"{tag} the frame written opted out did NOT reach COM1 (no row of {S.cols} 'g')")
    check("WXA-CHILD-MIRRORED" in seg, f"{tag} a CHILD's write while its parent is opted out reached COM1 (per process)")
    check("WXA-CHILD2-MIRRORED" in seg, f"{tag} the process after an opted-out child exited reached COM1 (the bit died with it)")
    check("first keyboard report dispatched" in seg, f"{tag} the kernel's own line printed inside the window reached COM1")
    m = re.search(r"WXA-NOSER-END n0=(-?\d+) p4=(-?\d+) q=(-?\d+) c=(-?\d+) q2=(-?\d+) u1=(-?\d+) u2=(-?\d+) pa=(-?\d+) pb=(-?\d+) pc=(-?\d+) frame_bytes=(\d+) mirror_us=(\d+) quiet_us=(\d+)", t)
    if m:
        g = [int(x) for x in m.groups()]
        p(f"    #110: before=0x{g[0]:x} set(4)->0x{g[1]:x} query->0x{g[2]:x} clear(4)->0x{g[3]:x} after->0x{g[4]:x} unknown-bit {g[5]} FLUSH-in-clear {g[6]}; children pids {g[7]} {g[8]} {g[9]}")
        if g[8] == g[9]: ok(f"{tag} the opted-out child's slot (pid {g[8]}) was reused by the next child, which was mirrored")
        else: p(f"    note: the opted-out child (pid {g[8]}) and the next (pid {g[9]}) took different slots — the reuse case was not exercised this boot")
        TIMES.append((smp, "frame", g[10], g[11], g[12]))
    else:
        bad(f"{tag} no parsable WXA-NOSER-END line")
    check(re.search(r"WAITX-OK ansi-noser", t) is not None, f"{tag} the probe's own #110 checks (WAITX-OK ansi-noser)")

def judge_a(S, smp):
    tag = f"[smp{smp}] A"
    C = S.cols
    check(all(S.glyph(0, c) for c in range(5)) and all(S.solid(0, c, BLUE) for c in range(5, C)),
          f"{tag} EL 0: cells 0-4 keep 'A', cells 5-{C-1} take the active background (blue)")
    check(all(S.solid(1, c, GREEN) for c in range(6)) and all(S.glyph(1, c) for c in range(6, 10)) and all(S.solid(1, c, BLACK) for c in range(10, C)),
          f"{tag} EL 1: cells 0-5 (cursor inclusive) green, 6-9 keep 'B', the rest untouched")
    check(all(S.solid(2, c, RED) for c in range(C)), f"{tag} EL 2: the whole row red")
    box = S.cell(3, 0); PIPE = S.cell(3, 10); REPL = S.cell(4, 1)
    check(all(S.cell(3, c) == box for c in range(10)) and S.stripe(3, 0),
          f"{tag} ten U+2500 draw ten identical cells of one full-width line (CP437 0xC4)")
    check(S.inked(3, 10) and PIPE != box and S.solid(3, 11, BLACK), f"{tag} the '|' after them is at column 10: the row kept its width")
    check(S.inked(4, 1) and REPL not in (box, PIPE) and S.inked(4, 0) and S.cell(4, 2) == PIPE,
          f"{tag} U+0100 (no CP437 cell) draws ONE replacement cell")
    check(S.cell(5, 0) == REPL and S.cell(5, 1) == PIPE, f"{tag} a lone continuation byte = one replacement cell")
    check(S.cell(6, 0) == REPL and S.cell(6, 1) == REPL and S.cell(6, 2) == PIPE, f"{tag} an overlong C0 AF = two replacement cells")
    check(S.cell(7, 0) == REPL and S.inked(7, 1) and S.cell(7, 1) not in (REPL, PIPE) and S.cell(7, 2) == PIPE,
          f"{tag} a truncated E2 94 then 'x' = one replacement cell, then 'x'")
    check(all(S.cell(8, c) == REPL for c in range(3)) and S.cell(8, 3) == PIPE, f"{tag} a surrogate ED A0 80 = three replacement cells")
    check(S.cell(9, 0) == REPL and S.solid(9, 1, BLACK) and S.cell(9, 2) == PIPE, f"{tag} U+1F600 (wide) = the replacement cell + a blank pad")
    check(S.cell(10, 0) == REPL and S.solid(10, 1, BLACK) and S.cell(10, 2) == PIPE, f"{tag} U+4E00 (wide CJK) = the replacement cell + a blank pad")
    check(S.glyph(11, 0) and S.cell(11, 1) == PIPE and S.solid(11, 2, BLACK), f"{tag} U+0301 (combining) takes no cell")
    check(S.glyph(12, 0) and S.cell(12, 0) != REPL and S.cell(12, 1) == PIPE, f"{tag} U+00E9 draws its CP437 glyph (0x82), not the replacement")
    check(S.cell(13, 0) == box and S.cell(13, 1) == PIPE, f"{tag} a UTF-8 sequence split across two write calls still decodes")
    FG10, BG10 = (10, 200, 30), (200, 20, 100)
    check(S.glyph(14, 0, FG10, BG10) and S.solid(14, 1, BG10) and S.solid(14, 2, BG10) and S.solid(14, 3, BLACK),
          f"{tag} a 10-parameter SGR keeps BOTH truecolours (38;2;10;200;30;48;2;200;20;100)")
    check(S.glyph(15, 0, (1, 2, 3), (90, 80, 70)) and S.solid(15, 1, (90, 80, 70)), f"{tag} a 17-parameter SGR keeps its background (parameters 14-16)")
    cb = S.cell(16, 0)
    nwhite = sum(1 for i in range(0, len(cb), 3) if tuple(cb[i:i + 3]) == WHITE)
    check(S.colours(cb) == {WHITE, BLACK} and nwhite * 2 > len(cb) // 3 and S.solid(16, 1, WHITE),
          f"{tag} SGR 7: 'Z' and a space drawn reversed (white background)")
    check(S.glyph(16, 2) and S.solid(16, 3, BLACK), f"{tag} SGR 27: 'W' and a space drawn normal again")
    check(S.solid(16, 4, RED), f"{tag} SGR 31;42;7: a reversed space takes the red foreground as its background")
    check(all(S.cell(17, c) == PIPE for c in range(8)) and all(S.solid(17, c, BLACK) for c in range(8, C)) and all(S.solid(18, c, BLACK) for c in range(C)),
          f"{tag} OSC (BEL, ST), DCS, APC, PM, SOS, an OSC with LF + UTF-8 and a CAN-cancelled OSC: only the eight '|' are drawn")
    check(S.inked(19, 0) and S.inked(19, 1) and S.cell(19, 2) == PIPE and S.solid(19, 3, BLACK),
          f"{tag} an UNTERMINATED OSC ends after 4096 bytes: 'OK|' after it is drawn at column 0")
    check(all(S.solid(20, c, BLACK) for c in range(8)) and S.inked(20, 8) and S.solid(20, 9, BLACK), f"{tag} Tab from column 0 lands on column 8")
    check(S.inked(21, 1) and all(S.solid(21, c, BLACK) for c in range(2, 8)) and S.inked(21, 8), f"{tag} Tab from column 2 lands on column 8")
    check(S.inked(22, 7) and all(S.solid(22, c, BLACK) for c in range(8, 16)) and S.inked(22, 16), f"{tag} Tab from column 8 lands on column 16")
    check(S.solid(23, C - 2, BLACK) and S.inked(23, C - 1), f"{tag} Tab with no stop left stops on the last column")
    check(all(S.inked(24, c) for c in range(C)) and S.inked(25, 0) and S.solid(25, 1, BLACK) and all(S.solid(26, c, BLACK) for c in range(C)),
          f"{tag} pending wrap: a full row + CR LF puts 'N' on the very next row (no blank line)")
    check(all(S.inked(27, c) for c in range(C)) and S.inked(28, 0) and S.solid(28, 1, BLACK), f"{tag} pending wrap: a full row + a glyph wraps first")
    check(all(S.inked(31, c) for c in range(C)) and S.cell(31, C - 1) != S.cell(31, C - 2) and all(S.solid(32, c, BLACK) for c in range(C)),
          f"{tag} DECAWM off (?7l): the glyph after a full row overwrites the last column and nothing wraps")

def judge_ed(S, smp):
    tag = f"[smp{smp}] ED"
    C = S.cols
    check(all(S.solid(r, c, MAGENTA) for r in range(4) for c in range(C)), f"{tag} ED 1: rows 0-3 erased whole, in the active background (magenta)")
    check(all(S.solid(4, c, MAGENTA) for c in range(11)) and all(S.glyph(4, c) for c in range(11, 20)) and all(S.solid(4, c, BLACK) for c in range(20, C)),
          f"{tag} ED 1: row 4 erased from column 0 to the cursor (10) inclusive, 11-19 kept")
    check(all(S.glyph(r, c) for r in (5, 6) for c in range(20)), f"{tag} rows 5 and 6 between the two erases are kept")
    check(all(S.glyph(7, c) for c in range(5)) and all(S.solid(7, c, CYAN) for c in range(5, C)), f"{tag} ED 0: row 7 erased from the cursor (5) on, in cyan")
    check(all(S.solid(r, c, CYAN) for r in range(8, 36) for c in range(C)), f"{tag} ED 0: every row below erased in cyan")

def judge_c(shots, smp):
    tag = f"[smp{smp}] C"
    S1, S2, S3, S4, S5, S6 = shots
    R = S1.rows
    body = [r for r in range(R) if r not in (43, 44, 45, 46, 47)]
    check(S1.cursor(2, 6) and S1.glyph(2, 4) and S1.glyph(2, 5) and not S1.bar(2, 5) and S1.cursors(body) == [(2, 6)],
          f"{tag} c1 the cursor is drawn at (2, 6) after 'AB' (an underline: bottom 2 font rows) and nowhere else")
    check(S2.solid(2, 6, BLACK) and S2.cursors(range(R)) == [], f"{tag} c2 ?25l hides it: (2, 6) blank and no cursor on the screen")
    check(S3.solid(9, 9, BLACK) and S3.cursor(11, 19) and S3.cursors(body) == [(11, 19)], f"{tag} c3 moved (9,9) -> (11,19): no ghost left at (9, 9)")
    check(S4.inked(R - 2, 0) and S4.solid(R - 2, 1, BLACK) and S4.cursor(R - 1, 0) and S4.cursors(body) == [(R - 1, 0)],
          f"{tag} c4 a scroll did not carry the cursor up: (rows-2, 1) blank, the cursor at (rows-1, 0)")
    check(S5.solid(19, 4, BLACK) and S5.cursor(19, 0) and all(S5.solid(19, c, BLACK) for c in range(1, 4)) and S5.cursors(body) == [(19, 0)],
          f"{tag} c5 an erased line left no ghost at (19, 4); the cursor at (19, 0)")
    C = S6.cols
    check(all(S6.inked(29, c) for c in range(C)) and S6.bar(29, C - 1) and not S6.bar(29, C - 2) and S6.bars(body) == [(29, C - 1)],
          f"{tag} c6 a wrap pending after a full row: the cursor is drawn on the LAST column")

TIMES = []
for smp in [int(x) for x in os.environ.get("CA_SMP", "1 4").split()]:
    p(f"\n=== boot -smp {smp}  accel: {' '.join(accel(smp))} ===")
    b = None
    for attempt in range(1, TRIES + 1):
        b = Boot(smp)
        b.wait(r"AGNOS kernel v|gnoboot: fail @|BootManagerMenuApp|Please select boot device", 90)
        t = b.text()
        if "AGNOS kernel v" in t: break
        b.kill()
        subprocess.run(["cp", b.ser, b.ser + f".attempt{attempt}"])
        why = VOID_RE.search(t)
        p(f"  (VOID attempt {attempt}: {why.group(0) if why else 'no banner'} — the kernel never ran; retrying)")
        b = None
    if b is None:
        p(f"  VOID: [smp{smp}] the firmware never handed off in {TRIES} attempts — not scored"); nvoid += 1; continue
    shots = {}
    inconclusive = None
    try:
        m = b.wait(r"WXA-GRID cols=(\d+) rows=(\d+)", 120)
        if not m: bad(f"[smp{smp}] the probe never started (no WXA-GRID)"); raise StopIteration
        cols, rows = int(m.group(1)), int(m.group(2))
        p(f"  console grid {cols}x{rows}")
        if cols < 64 or rows < 50:
            inconclusive = f"the console grid {cols}x{rows} is smaller than the 64x50 the screens are laid out for"; raise StopIteration
        # N — the opt-out window: type once both children have spoken, so the first key's kernel line lands inside it
        if not b.wait(r"WXA-CHILD2-MIRRORED|WXA-SECRET-WAITING", 60): bad(f"[smp{smp}] N the children never spoke")
        time.sleep(1.0)
        if not b.enter_until(r"WXA-NOSER-END"): bad(f"[smp{smp}] N the probe never left the opt-out window"); raise StopIteration
        for name in ("nshot", "a", "ed", "c1", "c2", "c3", "c4", "c5", "c6"):
            if not b.wait(r"WXA-READY " + name + r"\x1b", 60): bad(f"[smp{smp}] no WXA-READY {name}"); raise StopIteration
            time.sleep(0.6)
            img = b.shot(f"{name}-smp{smp}")
            if img is None: bad(f"[smp{smp}] the {name} screendump is missing"); raise StopIteration
            shots[name] = Screen(img)
            if not b.enter_until(r"WXA-GOT " + name + r"\x1b"): bad(f"[smp{smp}] the probe never acknowledged {name}"); raise StopIteration
        b.wait(r"WXA-DONE", 60)
        b.wait(r"kybernet: shell exited", 30)
    except StopIteration:
        pass
    t = b.text()
    b.kill()
    if inconclusive:
        p(f"  INCONCLUSIVE: [smp{smp}] {inconclusive} — not scored"); nvoid += 1; continue
    for ln in t.splitlines():
        if re.search(r"WXA-(GRID|NOSER-END|SCROLL|DONE)|WAITX-(OK|FAIL|DONE)|kybernet: shell exited", ln): p("    " + ln.strip()[:240])
    if "nshot" in shots: judge_n(shots["nshot"], t, smp)
    if "a" in shots: judge_a(shots["a"], smp)
    if "ed" in shots: judge_ed(shots["ed"], smp)
    if all(k in shots for k in ("c1", "c2", "c3", "c4", "c5", "c6")):
        judge_c([shots[k] for k in ("c1", "c2", "c3", "c4", "c5", "c6")], smp)
    m = re.search(r"WXA-SCROLL n=(\d+) us=(\d+) per_us=(\d+)", t)
    if m: TIMES.append((smp, "scroll", int(m.group(1)), int(m.group(2)), int(m.group(3))))
    else: bad(f"[smp{smp}] no WXA-SCROLL timing line")
    # the scroll's real cost was the mapping: PAT entry 1 must BE write-combining (vmm.cyr pat_init_cpu; fb_verify_wc
    # decodes the type from the live MSR since 1.57.18 — it printed "WC verified" over a write-through entry for years)
    check(re.search(r"fb: PAT entry 1 = 0x01 WC \(firmware PAT 0x[0-9a-f]+\)", t) is not None and "fb: WARN PAT" not in t,
          f"[smp{smp}] the framebuffer's PAT entry 1 is WC (fb: PAT entry 1 = 0x01 WC)")
    check("WAITX-FAIL" not in t, f"[smp{smp}] no WAITX-FAIL line")
    check("kybernet: shell exited" in t, f"[smp{smp}] the driver exited 0 and kybernet saw it")
    hits = [ln for ln in t.splitlines() if re.search(INV_DENY, ln)]
    check(not hits, f"[smp{smp}] no latched kernel invariant line (SMOKE_INVARIANT_DENY via _invdeny.py){': ' + str(hits[:3]) if hits else ''}")
    f = [ln for ln in t.splitlines() if re.search(r"fault: pid=|#GP|#PF|PANIC", ln)]
    check(not f, f"[smp{smp}] no fault, #GP/#PF or PANIC line{': ' + str(f[:3]) if f else ''}")

for row in TIMES:
    if row[1] == "frame":
        smp, _, nb, mir, qui = row
        p(f"  timing (reported): smp{smp} one {nb}-byte frame: mirrored to COM1 {mir} us, opted out {qui} us")
    else:
        smp, _, n, us, per = row
        p(f"  timing (reported): smp{smp} {n} scrolls in {us} us = {per} us per scroll")
p(f"\n=== console-ansi-test: {npass} passed, {nfail} failed, {nvoid} void ===")
if nfail: p("console-ansi-test: FAIL"); sys.exit(1)
if nvoid: p("console-ansi-test: VOID (a boot never handed off, or nothing could be measured)"); sys.exit(2)
p("console-ansi-test: PASS")
sys.exit(0)
