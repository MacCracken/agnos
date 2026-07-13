#!/usr/bin/env python3
# doom-input-test.py — validate kbscan(#42) end-to-end: prove a keypress reaches
# cyrius-doom's input_poll and drives the game.
#
# Reuses the image staged by doom-smoke.sh (build/doom-smoke/agnos-doom.img,
# DOOM_SELFTEST kernel runs `/bin/doom` -> menu_run on MENU_TITLE / TITLEPIC),
# but boots it with a QEMU USB-xHCI keyboard so HMP `sendkey` injects real
# Set-1 make/break (hid_poll -> kb_buf, the same buffer iron's IRQ1 fills).
#
# Two signals, two input classes:
#   1. send 'w' (movement) -> input_flags != 0 -> title advances to the main
#      menu -> the framebuffer screendump CHANGES vs the title.
#   2. send 'q' (quit)      -> input_quit -> menu_run returns -1 -> doom exits
#      -> the kernel prints "exec: doom returned" / doom prints "quit from menu".
# Either alone proves kbscan delivers; together they cover input_flags + quit.
import socket, subprocess, sys, time, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(ROOT, "build/doom-smoke")
IMG  = os.path.join(WORK, "agnos-doom.img")
SER  = os.path.join(WORK, "serial-input.log")
MON  = "/tmp/agnos-doom-input.sock"
PPM_A = os.path.join(WORK, "doom-input-a.ppm")  # title
PPM_B = os.path.join(WORK, "doom-input-b.ppm")  # after 'w'

if not os.path.exists(IMG):
    print("FAIL: %s missing — run scripts/doom-smoke.sh first" % IMG); sys.exit(1)

OVMF = ""
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/edk2/x64/OVMF_CODE.fd",
          "/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_CODE_4M.fd"):
    if os.path.exists(c): OVMF = c; break
if not OVMF: print("FAIL: OVMF not found"); sys.exit(1)

subprocess.run(["cp", os.path.join(WORK, "vars.fd"), os.path.join(WORK, "vars-input.fd")])
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-cpu", "max",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars-input.fd",
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

def colors(path):
    try: d = open(path, "rb").read()
    except OSError: return -1
    i = d.find(b'\n', d.find(b'\n', d.find(b'\n') + 1) + 1) + 1  # skip P6\n W H\n 255\n
    px = d[i:]; seen = set()
    for k in range(0, len(px) - 2, 3):
        seen.add(px[k:k+3])
    return len(seen)

def imgbytes(path):
    try: return open(path, "rb").read()
    except OSError: return b""

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

    # (A) title screen
    hmp("screendump %s" % PPM_A); time.sleep(1.0)
    ca = colors(PPM_A)
    p(f"  [A] title screendump: {ca} colors")

    # (1) movement key 'w' -> title should advance to the main menu.
    # HELD key (2026-07-12): a bare `sendkey w` releases so fast that the make
    # AND break land in one input_poll drain — doom's persistent key_state nets
    # back to 0 and no edge is seen. Hold ~HOLD ms so doom polls with the key
    # down before the release. (The kernel scancode path is correct either way;
    # this is a sendkey-cadence requirement for a cooperatively-polled IF=0 guest.)
    hmp("sendkey w %d" % int(os.environ.get("DOOM_KEY_HOLD", "500"))); time.sleep(2.0)
    hmp("screendump %s" % PPM_B); time.sleep(1.0)
    cb = colors(PPM_B)
    p(f"  [B] post-'w' screendump: {cb} colors")

    changed = imgbytes(PPM_A) != imgbytes(PPM_B) and ca > 16 and cb > 16
    if changed:
        p("  PASS: framebuffer changed after 'w' — input_flags reached menu_run (title advanced)")
    else:
        p("  FAIL: framebuffer unchanged after 'w' — movement input did not register"); rc = 1

    # (2) quit key 'q' -> menu_run returns -1 -> doom exits (held, see above)
    hmp("sendkey q %d" % int(os.environ.get("DOOM_KEY_HOLD", "500"))); time.sleep(3.0)
    log = ser()
    if "quit from menu" in log or "exec: doom returned" in log:
        p("  PASS: 'q' quit doom (input_quit reached menu_run -> doom_exit)")
    else:
        p("  FAIL: 'q' did not quit doom (input_quit never set)"); rc = 1
finally:
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=5)
    except Exception:
        qemu.kill()

p("")
p("  --- doom serial tail ---")
for ln in [l for l in ser().splitlines() if any(k in l for k in ("doom", "quit", "exec:", "WASD"))][-12:]:
    p("   " + ln)
p("")
p("doom-input-test: PASS — kbscan delivers input to DOOM" if rc == 0 else "doom-input-test: FAIL")
sys.exit(rc)
