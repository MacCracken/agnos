#!/usr/bin/env python3
# doom-ingame-smoke.py — boot the staged AGNOS doom image, drive the menu via
# QEMU HMP sendkey (USB-xHCI kbd), start a new game, and gate on the live 3D
# view. The stock doom-smoke.sh only reaches TITLEPIC (a 2D bitmap), which
# never exercises the wall/flat renderer; this harness is what actually
# verifies in-game rendering on the AGNOS target.
#
# Reuses the image staged by doom-smoke.sh (build/doom-smoke/agnos-doom.img,
# DOOM_SELFTEST kernel runs `/bin/doom`), modeled on doom-input-test.py.
#
# HELD KEYS (2026-07-12 fix): the menu keys are sent with an explicit hold time
# (`sendkey <k> <HOLD_MS>`), NOT a bare tap. doom runs ring-3 IF=0 and drains ALL
# buffered scancodes per input_poll() into a PERSISTENT key_state (make sets 1,
# break sets 0). A bare `sendkey w` releases so fast that the make AND the break
# land in the SAME kbscan#42 drain — key_state nets straight back to 0, no
# input edge is ever seen, and the menu never advances (it sits on TITLEPIC).
# Holding the key for ~half a second guarantees doom polls at least once with the
# key still down (make read, break not yet arrived), so the edge-detected menu
# fires. The kernel scancode-delivery path itself is correct — verified by
# doom-input-test.py's held-key run — this is purely a sendkey-cadence fix.
#
# Gates (title-vs-3D robust — the old ">=8 colors/row" gate FALSE-PASSED on
# TITLEPIC, whose detailed art also clears 8):
#   1. in-game frame DIFFERS from the captured title (not stuck on TITLEPIC)
#   2. floor band carries a textured-flat color signature: every sampled row in
#      the floor band has a DISTINCT-color count in [MIN..MAX]. A real DOOM flat
#      (a 64x64 tile COLORMAP-shaded) measures ~11-30 distinct/row; the pre-0.29.3
#      one-texel smear measured 1-4 (fails MIN); TITLEPIC art measures ~51-59
#      (fails MAX). The window rejects both a smear and the title illustration.
#
# Outputs (in build/doom-smoke/): doom-ingame.ppm + doom-ingame.png for eyes,
# plus doom-title.ppm (the captured title reference).
# Env: DOOM_RENDER_WAIT (default 10s) — title render wait before the menu drive.
#      DOOM_KEY_HOLD (default 500) — per-key hold time in ms for the menu drive.
import socket, struct, subprocess, sys, time, os, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(ROOT, "build/doom-smoke")
IMG  = os.path.join(WORK, "agnos-doom.img")
SER  = os.path.join(WORK, "serial-ingame.log")
VARS = os.path.join(WORK, "vars-ingame.fd")
MON  = "/tmp/agnos-doom-ingame.sock"
PPM  = os.path.join(WORK, "doom-ingame.ppm")
PPM_TITLE = os.path.join(WORK, "doom-title.ppm")
PNG  = os.path.join(WORK, "doom-ingame.png")

FLOOR_MIN = 8    # below → a flat-color smear (pre-0.29.3), not a real flat
FLOOR_MAX = 45   # above → detailed 2D art (e.g. TITLEPIC ~51-59), not a flat

if not os.path.exists(IMG):
    print("FAIL: %s missing — run scripts/doom-smoke.sh first" % IMG); sys.exit(1)

OVMF = ""
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/edk2/x64/OVMF_CODE.fd",
          "/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_CODE_4M.fd"):
    if os.path.exists(c): OVMF = c; break
if not OVMF: print("FAIL: OVMF not found"); sys.exit(1)

subprocess.run(["cp", os.path.join(WORK, "vars.fd"), VARS])
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-cpu", "max",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF}",
    "-drive", f"if=pflash,format=raw,file={VARS}",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-DOOM",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
    "-serial", f"file:{SER}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def p(*a): print(*a, flush=True)
def ser():
    try: return open(SER, "rb").read().decode("latin1")
    except OSError: return ""

HOLD = int(os.environ.get("DOOM_KEY_HOLD", "500"))

rc = 0
try:
    s = None
    for _ in range(60):
        try:
            s = socket.socket(socket.AF_UNIX); s.connect(MON); break
        except OSError:
            time.sleep(0.2)
    if s is None: p("FAIL: no monitor"); sys.exit(1)
    s.settimeout(1.0)
    def drain():
        try:
            while True:
                if not s.recv(65536): break
        except OSError: pass
    def hmp(cmd):
        s.sendall((cmd + "\n").encode()); time.sleep(0.5); drain()

    # Wait for doom to exec + render the title.
    for _ in range(40):
        if "exec: running /bin/doom" in ser(): break
        time.sleep(1)
    time.sleep(int(os.environ.get("DOOM_RENDER_WAIT", "10")))
    drain()

    # Capture the TITLE reference BEFORE driving the menu — gate 1 asserts the
    # in-game frame differs from it (so a stuck-on-TITLEPIC run cannot pass).
    hmp("screendump %s" % PPM_TITLE); time.sleep(1.0)

    # title -> main menu (any key) -> New Game ('e', cursor 0) -> skill ('e').
    # HELD keys (see header): hold each ~HOLD ms so doom polls with the key down
    # before the release, then a gap so the release is drained before the next.
    hmp("sendkey w %d" % HOLD); time.sleep(2.0)
    hmp("sendkey e %d" % HOLD); time.sleep(2.0)
    hmp("sendkey e %d" % HOLD); time.sleep(2.0)

    # Wait for the map to load (serial prints "map: V="). NB: the boot-time
    # load_map(1) also prints this, so it is NOT proof the menu drive worked —
    # the render gates below are authoritative. Kept as an informational line.
    started = "map: V=" in ser()
    if started:
        p("  info: 'map: V=' present on serial (boot map and/or menu-started game)")
    time.sleep(8)  # let the 3D view render a few frames

    hmp("screendump %s" % PPM); time.sleep(2.0)
    if os.path.exists(PPM) and os.path.getsize(PPM) > 1000:
        p(f"  screendump: {PPM} ({os.path.getsize(PPM)} B)")
    else:
        p("  FAIL: no in-game screendump"); rc = 1
finally:
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=5)
    except Exception: qemu.kill()

# --- Parse helper ----------------------------------------------------------
def load_ppm(path):
    d = open(path, "rb").read()
    parts = d.split(maxsplit=4)
    w, h = int(parts[1]), int(parts[2])
    off = d.index(parts[3]) + len(parts[3]) + 1
    return w, h, d[off:]

# --- Gate 1: in-game frame differs from the captured title -----------------
if rc == 0 and os.path.exists(PPM) and os.path.exists(PPM_TITLE):
    title_bytes = open(PPM_TITLE, "rb").read()
    ingame_bytes = open(PPM, "rb").read()
    if ingame_bytes == title_bytes:
        p("  FAIL: in-game frame is byte-identical to TITLEPIC — menu never "
          "advanced (held-key drive did not start a game)")
        rc = 1
    else:
        p("  PASS: frame changed from TITLEPIC (menu drive advanced past the title)")

# --- Gate 2: floor band carries a textured-flat color signature ------------
# The kernel blits the 320x200 frame at an integer block scale; sample the
# top-left pixel of each block so rows map 1:1 onto engine rows. The floor
# band (engine rows ~140..164, between the far geometry and the HUD at 168)
# must look like a shaded flat: distinct-color count per row in [MIN..MAX].
if rc == 0 and os.path.exists(PPM):
    w, h, px = load_ppm(PPM)
    scale = max(1, min(w // 320, h // 200))
    rows_checked, rows_ok, counts = 0, 0, []
    for ey in range(140, 165, 4):          # engine rows in the floor band
        y = ey * scale
        if y >= h: break
        seen = set()
        for ex in range(0, 320, 2):        # every 2nd engine column
            o = (y * w + ex * scale) * 3
            seen.add(px[o:o+3])
        rows_checked += 1
        counts.append(len(seen))
        if FLOOR_MIN <= len(seen) <= FLOOR_MAX: rows_ok += 1
    if rows_checked and rows_ok == rows_checked:
        p(f"  PASS: floor band textured — distinct colors/row {counts} "
          f"(flat window [{FLOOR_MIN}..{FLOOR_MAX}]; TITLEPIC art is ~51-59)")
    else:
        p(f"  FAIL: floor band not a textured flat — distinct colors/row {counts} "
          f"(outside [{FLOOR_MIN}..{FLOOR_MAX}] — title art or smear)")
        rc = 1

    # PNG for eyes (stdlib only), downscaled to the engine frame.
    try:
        rows = []
        for ey in range(200):
            row = bytearray()
            for ex in range(320):
                o = ((ey * scale) * w + ex * scale) * 3
                row += px[o:o+3]
            rows.append(bytes(row))
        def chunk(t, d2):
            c = t + d2
            return struct.pack(">I", len(d2)) + c + struct.pack(">I", zlib.crc32(c))
        raw = b"".join(b"\x00" + r for r in rows)
        open(PNG, "wb").write(b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 320, 200, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
        p(f"  PNG: {PNG}")
    except Exception as e:
        p(f"  (png conversion skipped: {e})")

p("")
p("  --- serial (doom lines) ---")
for ln in [l for l in ser().splitlines() if any(k in l for k in ("doom", "map", "wad", "exec:", "PANIC", "FAULT"))][-12:]:
    p("   " + ln)
p("")
p("doom-ingame-smoke: %s" % ("PASS — in-game 3D view renders textured flats on AGNOS" if rc == 0 else "FAIL"))
sys.exit(rc)
