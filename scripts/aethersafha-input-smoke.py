#!/usr/bin/env python3
# aethersafha-input-smoke.py — validate kbscan(#42) -> bhumi Set-1 decode ->
# compositor end-to-end: prove a keypress reaches aethersafha's input_handle and
# drives the desktop on AGNOS.
#
# DROP-IN for agnos/scripts/ (mirror of doom-input-test.py). Reuses the image
# staged by scripts/aethersafha-smoke.sh (build/ae-smoke/agnos-ae.img, the
# AETHERSAFHA_SELFTEST kernel runs /bin/aethersafha -> renders its desktop and
# loops), but boots it with a QEMU USB-xHCI keyboard so HMP `sendkey` injects
# real Set-1 make/break (hid_poll -> kb_buf -> kbscan#42 -> bhumi_scancode_process
# -> HID usage -> the compositor's input_map, the same buffer iron's IRQ1 fills).
#
# Two signals, two input classes:
#   1. send 'f4' (close focused window) -> input_apply removes the focused window
#      -> the framebuffer screendump CHANGES vs the two-window desktop.
#   2. send 'esc' (quit) -> input_map = IA_QUIT -> the compositor loop exits ->
#      the kernel prints "aethersafha: frame loop ok" / "exec: aethersafha
#      returned" (which never appear while it is parked in the render loop).
# Either alone proves kbscan+decode deliver; together they cover a window-mgmt
# action + quit.
import socket, subprocess, sys, time, os

ROOT  = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK  = os.path.join(ROOT, "build/ae-smoke")
IMG   = os.path.join(WORK, "agnos-ae.img")
SER   = os.path.join(WORK, "serial-input.log")
MON   = "/tmp/agnos-ae-input.sock"
PPM_A = os.path.join(WORK, "ae-input-a.ppm")  # two-window desktop
PPM_B = os.path.join(WORK, "ae-input-b.ppm")  # after 'f4' (focused window closed)

if not os.path.exists(IMG):
    print("FAIL: %s missing — run scripts/aethersafha-smoke.sh first" % IMG); sys.exit(1)

OVMF = ""
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/edk2/x64/OVMF_CODE.fd",
          "/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_CODE_4M.fd"):
    if os.path.exists(c): OVMF = c; break
if not OVMF: print("FAIL: OVMF not found"); sys.exit(1)

subprocess.run(["cp", os.path.join(WORK, "vars.fd"), os.path.join(WORK, "vars-input.fd")])
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass

KVM = ["-enable-kvm", "-cpu", "host"] if os.path.exists("/dev/kvm") else ["-cpu", "max"]
qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", *KVM,
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars-input.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-AE",
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

    # Wait for aethersafha to exec + render the desktop.
    for _ in range(40):
        if "exec: running /bin/aethersafha" in ser(): break
        time.sleep(1)
    time.sleep(int(os.environ.get("AE_RENDER_WAIT", "8")))
    drain()

    PPM_C = os.path.join(WORK, "ae-input-c.ppm")  # after 'f4' (focused window closed)

    # (A) two-window desktop
    hmp("screendump %s" % PPM_A); time.sleep(1.0)
    ca = colors(PPM_A)
    p(f"  [A] desktop screendump: {ca} colors")

    # (1) Tab -> IA_FOCUS_NEXT -> the focused titlebar tint moves (non-destructive)
    hmp("sendkey tab"); time.sleep(2.0)
    hmp("screendump %s" % PPM_B); time.sleep(1.0)
    cb = colors(PPM_B)
    tab_changed = imgbytes(PPM_A) != imgbytes(PPM_B)
    p(f"  [B] post-'tab' screendump: {cb} colors, changed={tab_changed}")

    # (2) F4 -> IA_CLOSE_FOCUSED -> a window disappears
    hmp("sendkey f4"); time.sleep(2.0)
    hmp("screendump %s" % PPM_C); time.sleep(1.0)
    cc = colors(PPM_C)
    f4_changed = imgbytes(PPM_B) != imgbytes(PPM_C)
    p(f"  [C] post-'f4' screendump: {cc} colors, changed={f4_changed}")

    if (tab_changed or f4_changed) and ca > 8:
        p("  PASS: framebuffer changed after a keystroke — input reached input_apply")
    else:
        p("  FAIL: framebuffer unchanged after tab+f4 — window-mgmt input did not register"); rc = 1

    # (3) Esc -> IA_QUIT -> the compositor loop exits
    hmp("sendkey esc"); time.sleep(3.0)
    log = ser()
    if "frame loop ok" in log or "exec: aethersafha returned" in log:
        p("  PASS: 'esc' quit the compositor (IA_QUIT reached the loop -> clean exit)")
    else:
        p("  FAIL: 'esc' did not quit the compositor (IA_QUIT never set)"); rc = 1
finally:
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=5)
    except Exception:
        qemu.kill()

p("")
p("  --- aethersafha serial tail ---")
for ln in [l for l in ser().splitlines() if any(k in l for k in ("aethersafha", "desktop", "frame", "exec:"))][-12:]:
    p("   " + ln)
p("")
p("aethersafha-input-smoke: PASS — kbscan+Set-1 decode deliver input to the compositor" if rc == 0 else "aethersafha-input-smoke: FAIL")
sys.exit(rc)
