#!/usr/bin/env python3
# console-line-preserve-test.py — an ASYNCHRONOUS LOG MUST NOT ALTER THE LINE THE OPERATOR IS TYPING.
#
# ⛔⛔ WHY THIS EXISTS, AND WHY NO SERIAL GATE COULD EVER HAVE CAUGHT IT.
# On the 1.56.45 burn the operator typed a command and a one-shot landed inside it:
#
#     [ASSIST] > ahid: first mouse report accumulated
#     ether      aethersafha --opacity 128 --client /present_probe
#
# The `a` of `aethersafha` is stranded before the log and the rest resumes on the next row. ⚠ In the
# SERIAL transcript those are simply two writes in order and look perfectly fine — which is exactly how
# the defect survived: `issues/2026-08-11-hid-drain-rearm-and-isr-console-lock.md` diagnosed it from a
# serial log and ruled it *"working as intended"*. **The corruption exists only on the framebuffer,
# because only the framebuffer has a cursor.** So the oracle has to be the framebuffer.
#
# ⭐⭐ THE ASSERTION IS PIXEL EQUALITY, NOT OCR, and that is deliberate. Decoding glyphs would need a
# second copy of the kashi font in Python — a private reimplementation of the thing under test, i.e.
# the "two implementations of the same idea" trap agnos gpu.md §2.1 names. Instead:
#
#     1. type a partial command at the prompt (NO Enter) — the line is live on screen
#     2. screendump  -> BEFORE
#     3. move the mouse, which fires `hid: first mouse report accumulated` while that line is displayed
#     4. screendump  -> AFTER
#     5. the LAST NON-EMPTY console row must be PIXEL-IDENTICAL in both
#
# The row is expected to MOVE (the log is printed above it), so the test compares the row's CONTENT, not
# its position. That is precisely the property: the log may take screen space, it may not take my line.
#
# ⚠ WHAT THIS DOES NOT PROVE: that the log line itself is present and legible. That is asserted
# separately and weakly (a new non-empty row appeared). Serial already proves the text; this file exists
# for the cursor interaction alone.
#
# Exit 0 = the line survived. Exit 1 = it was altered. Exit 2 = the run could not be set up.
import os, socket, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORK = os.path.join(ROOT, "build/agnsh-smoke")
IMG  = os.path.join(WORK, "agnos-agnsh.img")
SER  = os.path.join(WORK, "serial-conspv.log")
MON  = "/tmp/agnos-conspv.sock"
SHOT_BEFORE = os.path.join(WORK, "conspv-before.ppm")
SHOT_AFTER  = os.path.join(WORK, "conspv-after.ppm")

# The console's own geometry, from kernel/arch/x86_64/fb_console.cyr. ⚠ Mirrored here, so if the console
# ever changes cell size or origin this harness must change with it — the failure is a loud row-count
# mismatch rather than a silent pass.
CELL_W, CELL_H = 8, 16
FB_CONSOLE_Y0  = 0
TYPED = "aethersafha"          # no spaces: a space is a blank cell and would weaken the row scan

def p(*a): print(*a, flush=True)

def read_ppm(path):
    with open(path, "rb") as f:
        if f.readline().strip() != b"P6": return None
        line = f.readline()
        while line.startswith(b"#"): line = f.readline()
        w, h = map(int, line.split())
        f.readline()
        return w, h, f.read(w * h * 3)

def scale_for(h):
    # Mirrors fb_putc: `s = 1; if (height > 1200) { s = 2; }`
    return 2 if h > 1200 else 1

def row_band(w, h, data, r, s):
    """Raw bytes of console row r (a cell_h*s-tall full-width band), or None if off-screen."""
    ch = CELL_H * s
    y0 = FB_CONSOLE_Y0 + r * ch
    if y0 + ch > h: return None
    return data[y0 * w * 3 : (y0 + ch) * w * 3]

def row_nonblank(band):
    """True if the band holds any non-background pixel. Background is fb_bg_color = black."""
    return band is not None and any(b > 24 for b in band)

def last_text_row(w, h, data, s):
    ch = CELL_H * s
    nrows = (h - FB_CONSOLE_Y0) // ch
    for r in range(nrows - 1, -1, -1):
        if row_nonblank(row_band(w, h, data, r, s)): return r
    return -1

def n_text_rows(w, h, data, s):
    ch = CELL_H * s
    nrows = (h - FB_CONSOLE_Y0) // ch
    return sum(1 for r in range(nrows) if row_nonblank(row_band(w, h, data, r, s)))

if not os.path.exists(IMG):
    p(f"SKIP: {IMG} not present — run the agnsh smoke first to build the image"); sys.exit(2)
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/OVMF/OVMF_CODE.fd"):
    if os.path.exists(c): OVMF = c; break
else:
    p("SKIP: no OVMF firmware found"); sys.exit(2)

subprocess.run(["cp", os.path.join(WORK, "vars.fd"), os.path.join(WORK, "vars-conspv.fd")], check=False)
open(SER, "w").close()
for f in (SHOT_BEFORE, SHOT_AFTER, MON):
    try: os.unlink(f)
    except FileNotFoundError: pass

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-cpu", "max",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars-conspv.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-AGNSH",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
    # ⭐ THE MOUSE IS THE STIMULUS, not scenery: `hid: first mouse report accumulated` is a one-shot that
    # fires on the first physical motion, so it can be made to land at a moment of our choosing —
    # namely while a half-typed line is on screen. That controllability is the whole test design.
    "-device", "usb-mouse,bus=xhci.0",
    "-serial", f"file:{SER}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

rc = 2
try:
    s = None
    for _ in range(80):
        try:
            s = socket.socket(socket.AF_UNIX); s.connect(MON); break
        except OSError: time.sleep(0.25)
    if s is None: p("FAIL: no QEMU monitor"); sys.exit(2)
    s.settimeout(1.0)

    def drain():
        try:
            while True: s.recv(65536)
        except OSError: pass

    def ser():
        try: return open(SER, "rb").read().decode("latin1")
        except OSError: return ""

    banner = False
    for _ in range(120):
        if "agnoshi" in ser(): banner = True; break
        time.sleep(0.25)
    p("banner seen:", banner)
    if not banner: p("FAIL: never reached the shell"); sys.exit(2)
    time.sleep(1.5)

    km = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '/': 'slash'}
    def typ(word, settle=0.10):
        for ch in word:
            s.sendall(("sendkey " + km.get(ch, ch) + "\n").encode())
            time.sleep(settle); drain()

    # ⚠ PRIME WITH A BARE ENTER. QEMU drops the first character of the first typed line (documented in
    # agnsh-type-test.py: `help` arrives as `elp`; emulation-only, iron has never shown it). The prime
    # also burns the KEYBOARD one-shot, so the only log left to fire is the mouse one — which is what
    # this test wants to control.
    typ("\n"); time.sleep(1.5)

    typ(TYPED); time.sleep(1.5)
    s.sendall((f"screendump {SHOT_BEFORE}\n").encode()); time.sleep(2.5); drain()

    mark = len(ser())
    for _ in range(14):
        s.sendall(b"mouse_move 9 6\n"); time.sleep(0.12); drain()
    time.sleep(2.0)
    s.sendall((f"screendump {SHOT_AFTER}\n").encode()); time.sleep(2.5); drain()
    fired = "first mouse report accumulated" in ser()[mark:]
    p("mouse one-shot fired while the line was live:", fired)

    b = read_ppm(SHOT_BEFORE); a = read_ppm(SHOT_AFTER)
    if b is None or a is None: p("FAIL: could not read a screendump"); sys.exit(2)
    (bw, bh, bd), (aw, ah, ad) = b, a
    if (bw, bh) != (aw, ah): p(f"FAIL: geometry changed {bw}x{bh} -> {aw}x{ah}"); sys.exit(2)
    sc = scale_for(bh)
    p(f"framebuffer {bw}x{bh}, scale {sc}, cell {CELL_W*sc}x{CELL_H*sc}")

    rb = last_text_row(bw, bh, bd, sc)
    ra = last_text_row(aw, ah, ad, sc)
    p(f"last text row: before={rb} after={ra}   text rows: {n_text_rows(bw,bh,bd,sc)} -> {n_text_rows(aw,ah,ad,sc)}")
    if rb < 0 or ra < 0: p("FAIL: no text on the console at all"); sys.exit(2)

    # ⛔ NON-VACUITY GATE #1 — the stimulus must actually have happened. Without this the whole test
    # passes trivially on a boot where no log ever fired, which is the shape of green this tree keeps
    # finding. A missing one-shot is INCONCLUSIVE (exit 2), not a pass.
    if not fired:
        p("INCONCLUSIVE: the mouse one-shot never fired, so nothing interrupted the line — nothing tested")
        sys.exit(2)

    # ⛔ NON-VACUITY GATE #2 — the SCREEN must have changed. Without this the whole test passes on a
    # kernel that dropped the log entirely (the "boot-phase mute" this fix exists NOT to be), because an
    # unchanged screen trivially has an unchanged line.
    # ⚠ NOT "a row was added": measured 2026-08-16, the console is already SCROLLING by the time the
    # shell prompt appears (57 text rows, last text row pinned at 63 of 64), so printing a line shifts
    # the screen up and the row COUNT never moves. A row-count check would be permanently red here and
    # was, on the first run of this harness. Whole-framebuffer inequality is scroll-agnostic and is the
    # honest form of "something was printed".
    if bd == ad:
        p("FAIL: the framebuffer is byte-identical before and after — the log never reached the screen")
        rc = 1; sys.exit(1)

    # ⭐ THE ASSERTION. Same content, wherever it now sits.
    band_b = row_band(bw, bh, bd, rb, sc)
    band_a = row_band(aw, ah, ad, ra, sc)
    if band_b == band_a:
        p(f"PASS: the typed line is pixel-identical after the log (moved row {rb} -> {ra})")
        rc = 0
    else:
        diff = sum(1 for x, y in zip(band_b, band_a) if x != y)
        p(f"FAIL: the log ALTERED the operator's line — {diff} bytes differ in the last text row")
        p("      (this is the 1.56.45 signature: the log is appended to the prompt and the")
        p("       remainder of the typed command is pushed onto the following row)")
        rc = 1
    s.sendall(b"quit\n"); time.sleep(0.3)
finally:
    try: qemu.terminate(); qemu.wait(timeout=5)
    except Exception:
        try: qemu.kill()
        except Exception: pass
    try: os.unlink(MON)
    except FileNotFoundError: pass
sys.exit(rc)
