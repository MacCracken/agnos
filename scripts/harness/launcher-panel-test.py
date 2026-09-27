#!/usr/bin/env python3
# launcher-panel-test.py — Ctrl+F2 OPENS THE APPLICATION LAUNCHER ON THE PANEL.
#
# ⛔⛔ WHY A FRAMEBUFFER ORACLE. aethersafha's own suites gate the launcher's pure half (registry,
# selection, key semantics, geometry — 44 assertions) and its compositing (a pixel proof through
# `render_desktop`). Neither can see the seam this file tests: that a REAL Ctrl+F2 chord, arriving
# over the real HID path on the real kernel, reaches `lnch_openp()` and puts the panel on the real
# screen. A compositor log line saying "launcher opened" would prove only that a branch ran.
#
# ⭐ THE ASSERTION IS BEFORE/AFTER PIXELS IN THE PANEL'S OWN RECT — no OCR, no font. The launcher paints
# a 2 px accent seal across the top of its panel, at coordinates the compositor computes from the screen
# size (`lnch_panel_x/y/w`), so the harness recomputes the same arithmetic and looks there:
#
#     1. boot, run `aethersafha` with NO --clients (launcher mode: nothing pre-loaded)
#     2. screendump -> BEFORE
#     3. sendkey ctrl-f2
#     4. screendump -> AFTER
#     5. the panel rect must CHANGE, and carry a horizontal run of one uniform colour where the
#        accent seal goes
#
# ⚠ WHAT THIS DOES NOT PROVE: that Enter launches the selected app. Nothing here sends Enter; this
# header promised a "client-count check below" that no version of the file ever ran. Enter -> spawn is
# gated by the crab-*-test.py harnesses (open -> DOWN -> Enter, scored on crab's own `presented`
# line) and by puka-resize-test.py.
#
# ⛔ THE COMPOSITOR UNDER TEST IS AE_BIN (default ../aethersafha/build/aethersafha_agnos), staged into
# an image this harness builds from build/agnos + build/rootfs, as its siblings do. Until agnos 1.57.10
# it booted a copy of puka-terminal-test.py's image, carrying whatever kernel and compositor that run
# had baked in — measured 2026-09-27: a kernel that differed from build/agnos, and the 2026-09-08
# aethersafha from build/rootfs. Since aethersafha 0.16.26 that is worse than stale: every older
# compositor matched F2 without reading Ctrl, so an old binary opens on `ctrl-f2` as well and passes
# here without the chord contract ever being tested.
#
# Exit 0 = the panel appeared. 1 = it did not. 2 = the run could not be set up.
import os, socket, subprocess, sys, time

ROOT   = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/launcher-panel")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-launcher.img")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-launcher.sock"
AGNOS  = os.path.join(ROOT, "build/agnos")
SHOT_BEFORE = os.path.join(WORK, "before.ppm")
SHOT_AFTER  = os.path.join(WORK, "after.ppm")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _freshness import refuse_stale_kernel
refuse_stale_kernel(ROOT)
GNOBOOT = os.path.join(ROOT, "../gnoboot/build/BOOTX64.EFI")
AE_BIN  = os.environ.get("AE_BIN", os.path.join(ROOT, "../aethersafha/build/aethersafha_agnos"))
DISK_MB, PART_OFFSET, PART_BLOCKS = 512, 34603008, 122880
EXT2_FEATURES = "^resize_inode,^dir_index,^ext_attr,^huge_file,^64bit,^metadata_csum"

# Mirrored from aethersafha/src/launcher.cyr. ⚠ If the panel's geometry changes there, this must change
# with it — the failure is a loud "no accent run found", not a silent pass.
LNCH_W, LNCH_PAD, LNCH_ROW_H = 260, 10, 22
# puka + crab are registered at boot. ⚠ aethersafha 0.16.26 adds a third row, thoth, only when
# /bin/thoth exists; build/rootfs stages none, and an image that did would need 3 here.
N_APPS = 2

def p(*a): print(*a, flush=True)
def sh(c): subprocess.run(c, shell=True, check=True)

def panel_rect(sw, sh):
    ph = LNCH_PAD * 2 + N_APPS * LNCH_ROW_H
    px = (sw - LNCH_W) // 2
    py = max((sh - ph) // 3, 0)
    return px, py, LNCH_W, ph

def read_ppm(path):
    with open(path, "rb") as f:
        if f.readline().strip() != b"P6": return None
        line = f.readline()
        while line.startswith(b"#"): line = f.readline()
        w, h = map(int, line.split())
        f.readline()
        return w, h, f.read(w * h * 3)

def px_at(w, data, x, y):
    i = (y * w + x) * 3
    return data[i:i+3]

def rect_bytes(w, data, x, y, rw, rh):
    out = bytearray()
    for yy in range(y, y + rh):
        i = (yy * w + x) * 3
        out += data[i:i + rw * 3]
    return bytes(out)

def longest_uniform_run(w, data, x, y, rw):
    """Longest horizontal run of one non-background colour on row y within [x, x+rw)."""
    best, cur, prev = 0, 0, None
    for xx in range(x, x + rw):
        c = px_at(w, data, xx, y)
        if c == prev and any(b > 24 for b in c):
            cur += 1
        else:
            cur = 1 if any(b > 24 for b in c) else 0
        prev = c
        best = max(best, cur)
    return best

for need in (AGNOS, GNOBOOT, ROOTFS, AE_BIN):
    if not os.path.exists(need):
        p(f"SKIP: missing {need}"); sys.exit(2)
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/OVMF/OVMF_CODE.fd"):
    if os.path.exists(c): OVMF = c; break
else:
    p("SKIP: no OVMF firmware"); sys.exit(2)
for c in ("/usr/share/edk2/x64/OVMF_VARS.4m.fd", "/usr/share/OVMF/OVMF_VARS.fd"):
    if os.path.exists(c): OVMF_VARS = c; break
else:
    p("SKIP: no OVMF vars template"); sys.exit(2)

# ⚠ A failed build step is exit 2 (not set up), never 1: 1 is this file's "the panel did not appear".
try:
    subprocess.run(["rm", "-rf", WORK], check=True); os.makedirs(WORK)
    subprocess.run(["cp", "-a", ROOTFS, SEED], check=True)
    subprocess.run(["cp", AE_BIN, os.path.join(SEED, "bin", "aethersafha")], check=True)
    subprocess.run(["chmod", "+x", os.path.join(SEED, "bin", "aethersafha")], check=True)
    p("seed: /bin/aethersafha <-", AE_BIN, f"({os.path.getsize(AE_BIN)} bytes)")
    sh(f"dd if=/dev/zero of={IMG} bs=1M count={DISK_MB} status=none")
    sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100%")
    sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
    sh(f"mformat -i {IMG}@@1048576 -F")
    sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
    sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
    sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
    sh(f"mkfs.ext2 -F -q -L AGNOS-LNCH -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
    subprocess.run(["cp", OVMF_VARS, os.path.join(WORK, "vars.fd")], check=True)
    subprocess.run(["chmod", "+w", os.path.join(WORK, "vars.fd")], check=True)
except (subprocess.CalledProcessError, OSError) as e:
    p(f"SKIP: could not build the image — {e}"); sys.exit(2)

open(SER, "w").close()
for f in (SHOT_BEFORE, SHOT_AFTER, MON):
    try: os.unlink(f)
    except FileNotFoundError: pass

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "2048M", "-cpu", "max", "-smp", "4",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-LNCH",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0", "-device", "usb-mouse,bus=xhci.0",
    "-serial", f"file:{SER}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

rc = 2
try:
    s = None
    for _ in range(100):
        try:
            s = socket.socket(socket.AF_UNIX); s.connect(MON); break
        except OSError: time.sleep(0.25)
    if s is None: p("FAIL: no monitor"); sys.exit(2)
    s.settimeout(1.0)

    def drain():
        try:
            while True: s.recv(65536)
        except OSError: pass
    def ser():
        try: return open(SER, "rb").read().decode("latin1")
        except OSError: return ""

    ok = False
    for _ in range(160):
        if "agnoshi" in ser(): ok = True; break
        time.sleep(0.25)
    p("shell banner:", ok)
    if not ok: p("FAIL: never reached the prompt"); sys.exit(2)
    time.sleep(2.0)

    km = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '/': 'slash'}
    def typ(word, settle=0.10):
        for ch in word:
            s.sendall(("sendkey " + km.get(ch, ch) + "\n").encode())
            time.sleep(settle); drain()

    # ⚠ A bare Enter first: QEMU drops the first character of the first typed line (documented in
    # agnsh-type-test.py). Then `aethersafha` with NO --clients — launcher mode, nothing pre-loaded.
    typ("\n"); time.sleep(1.0)
    typ("aethersafha\n"); time.sleep(14.0)
    mark = len(ser())
    ready = "launcher ready" in ser()
    p("compositor reports launcher mode:", ready)

    s.sendall((f"screendump {SHOT_BEFORE}\n").encode()); time.sleep(3.0); drain()
    # ⚠ SENT REPEATEDLY, AND THAT IS NOT PADDING. The compositor drains the HID ring once per FRAME
    # (agnos issue 2026-08-11: `kbscan #42` inside a bounded `sti` window), so a single injected key can
    # land in a gap and be gone before the next drain — the same "one record per frame" shape that
    # produced the *"puka didn't register key commands"* report. Repeating makes arrival a certainty
    # rather than a race; the launcher is idempotent under repeat (re-opening resets the selection).
    for _ in range(6):
        s.sendall(b"sendkey ctrl-f2\n"); time.sleep(1.2); drain()
    time.sleep(2.0)
    s.sendall((f"screendump {SHOT_AFTER}\n").encode()); time.sleep(3.0); drain()
    opened = "launcher opened" in ser()[mark:]
    p("compositor reports the launcher opened:", opened)

    b = read_ppm(SHOT_BEFORE); a = read_ppm(SHOT_AFTER)
    if b is None or a is None: p("FAIL: could not read a screendump"); sys.exit(2)
    (bw, bh, bd), (aw, ah, ad) = b, a
    if (bw, bh) != (aw, ah): p(f"FAIL: geometry changed {bw}x{bh} -> {aw}x{ah}"); sys.exit(2)
    px, py, pw, ph = panel_rect(bw, bh)
    p(f"framebuffer {bw}x{bh}; panel rect ({px},{py}) {pw}x{ph}")

    # ⛔ NON-VACUITY: the compositor must have SAID it opened. Without this the pixel test can pass on a
    # frame that changed for any other reason (a cursor move, a repaint) and we would call it a launcher.
    if not opened:
        p("INCONCLUSIVE: the compositor never logged 'launcher opened' — Ctrl+F2 did not reach it")
        sys.exit(2)

    before_rect = rect_bytes(bw, bd, px, py, pw, ph)
    after_rect  = rect_bytes(aw, ad, px, py, pw, ph)
    if before_rect == after_rect:
        p("FAIL: the panel rect is pixel-identical before and after Ctrl+F2 — nothing was drawn"); rc = 1
    else:
        # The accent seal is 2 px of ONE colour across the panel's full width.
        run = longest_uniform_run(aw, ad, px, py, pw)
        p(f"longest uniform run on the seal row: {run} px (panel width {pw})")
        if run >= pw - 4:
            p("PASS: Ctrl+F2 put the launcher panel on the framebuffer (accent seal spans the panel)")
            rc = 0
        else:
            p("FAIL: the rect changed but no full-width accent seal was found — is that the panel?")
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
