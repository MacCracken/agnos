#!/usr/bin/env python3
# Reproduce the iron "keyboard dies after the first command" multi-verb freeze
# IN QEMU, for free — by driving the PS/2 i8042 keyboard (HMP sendkey -> IRQ1 ->
# kb_isr -> kb_buf) instead of usb-kbd (-> hid_poll). The IRQ1 path is the EXACT
# code path archaemenid uses (its firmware emulates an i8042 that delivers via
# IRQ1); the usb-kbd path is QEMU-only, which is why every prior smoke missed
# this. No -device qemu-xhci / usb-kbd here, so q35's default PS/2 keyboard
# receives sendkey.
#
# Sequence = the 14115 sequence that WORKED pre-1.44.x: help -> version -> mode.
# PASS (bug NOT reproduced) = all three command outputs appear in order.
# FAIL (bug reproduced)     = the first appears, later ones do not (keyboard
#                             went dead after the first command).
import socket, subprocess, sys, time, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(ROOT, "build/agnsh-smoke")
IMG  = os.path.join(WORK, "agnos-agnsh.img")
SER  = os.path.join(WORK, "serial-irq1.log")
MON  = "/tmp/agnos-irq1.sock"
if not os.path.exists(IMG):
    print("FAIL: image not built — run scripts/agnsh-smoke.sh first"); sys.exit(1)
OVMF = None
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/OVMF/OVMF_CODE.fd"):
    if os.path.exists(c): OVMF = c; break
if OVMF is None:
    print("FAIL: no OVMF firmware found"); sys.exit(1)
subprocess.run(["cp", os.path.join(WORK, "vars.fd"), os.path.join(WORK, "vars-irq1.fd")])
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass

DWELL = float(os.environ.get("DWELL", "0"))   # seconds idle at the prompt before cmd2 (dwell-time test)
SMP   = os.environ.get("SMP", "1")             # match iron's "cpus online: 4" with SMP=4

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-cpu", "max",
    "-smp", SMP,
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars-irq1.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-AGNSH",
    # NO qemu-xhci / usb-kbd: sendkey now targets the q35 PS/2 i8042 -> IRQ1.
    "-serial", f"file:{SER}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def p(*a): print(*a, flush=True)

rc = 1
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
            while True: s.recv(65536)
        except OSError: pass

    def ser():
        try: return open(SER, "rb").read().decode("latin1")
        except OSError: return ""

    km = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '/': 'slash',
          '>': 'shift-dot'}
    def typ(word):
        for ch in word:
            key = km.get(ch, ch)
            if ch.isupper(): key = "shift-" + ch.lower()
            s.sendall(("sendkey " + key + "\n").encode())
            time.sleep(0.10); drain()
        time.sleep(1.8)

    ok = False
    for _ in range(320):
        if "agnoshi" in ser(): ok = True; break
        time.sleep(0.25)
    p("banner seen:", ok)
    if not ok: p("FAIL: no agnsh banner (PS/2 boot)"); sys.exit(1)

    # --- command 1: help ---
    m1 = len(ser())
    p("typing #1: help")
    typ("help\n")
    seg1 = ser()[m1:]

    # --- dwell at the prompt (simulate the user reading help's output) ---
    if DWELL > 0:
        p(f"dwelling {DWELL}s at the prompt (idle keyboard read spin)...")
        time.sleep(DWELL)

    # --- command 2: version ---
    m2 = len(ser())
    p("typing #2: version")
    typ("version\n")
    seg2 = ser()[m2:]

    # --- command 3: mode ---
    m3 = len(ser())
    p("typing #3: mode")
    typ("mode\n")
    seg3 = ser()[m3:]

    time.sleep(0.6)
    p("=========== seg1 (after help) ===========");    p(seg1 if seg1.strip() else "(empty)")
    p("=========== seg2 (after version) ========");    p(seg2 if seg2.strip() else "(empty)")
    p("=========== seg3 (after mode) ===========");    p(seg3 if seg3.strip() else "(empty)")
    p("=========================================")

    # "Built-ins" header is help's body; "version"/agnoshi reprint marks version ran;
    # "Current mode" marks mode ran. We check that each command's ECHO + effect lands.
    c1 = ("Built-ins" in seg1) or ("help" in seg1)
    c2 = ("version" in seg2) or ("agnoshi" in seg2) or ("1.7.0" in seg2)
    c3 = ("mode" in seg3) or ("Current mode" in seg3) or ("ASSIST" in seg3) or ("auto" in seg3)
    p("cmd1 help registered:   ", c1)
    p("cmd2 version registered:", c2)
    p("cmd3 mode registered:   ", c3)
    if c1 and c2 and c3:
        p("agnsh-irq1-repro: PASS (multi-verb works over IRQ1 — bug NOT reproduced)"); rc = 0
    elif c1 and not (c2 or c3):
        p("agnsh-irq1-repro: BUG REPRODUCED (keyboard died after the first command)"); rc = 2
    else:
        p("agnsh-irq1-repro: INCONCLUSIVE (partial)"); rc = 3
    s.sendall(b"quit\n"); time.sleep(0.2)
finally:
    qemu.terminate()
    try: qemu.wait(timeout=3)
    except subprocess.TimeoutExpired: qemu.kill()
sys.exit(rc)
