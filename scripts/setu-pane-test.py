#!/usr/bin/env python3
# setu-pane-test.py — prove crab DUAL-PANE switching: the Right arrow moves the
# active pane (bright header/selection) from the left pane to the right pane.
import socket, subprocess, sys, time, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = ROOT + "/build/ae-setu-smoke"
IMG  = WORK + "/agnos-ae.img"
SER  = WORK + "/serial-pane.log"
MON  = WORK + "/mon-pane.sock"
VARS = WORK + "/vars-pane.fd"
PPM_A = WORK + "/crab-pane-before.ppm"
PPM_B = WORK + "/crab-pane-after.ppm"

def find(cands):
    for c in cands:
        if os.path.isfile(c): return c
    return None
OVMF_CODE = find(["/usr/share/edk2/x64/OVMF_CODE.4m.fd","/usr/share/edk2/x64/OVMF_CODE.fd","/usr/share/OVMF/OVMF_CODE.fd","/usr/share/OVMF/OVMF_CODE_4M.fd"])
OVMF_VARS = find(["/usr/share/edk2/x64/OVMF_VARS.4m.fd","/usr/share/edk2/x64/OVMF_VARS.fd","/usr/share/OVMF/OVMF_VARS.fd","/usr/share/OVMF/OVMF_VARS_4M.fd"])
subprocess.run(["cp", OVMF_VARS, VARS], check=True); os.chmod(VARS, 0o644)
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-cpu", "max",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
    "-drive", f"if=pflash,format=raw,file={VARS}",
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

def hi_mean_x(path):
    # mean X of the ACTIVE-pane bright-blue (header 80,130,200 + selection 50,95,165)
    # within the crab window region (x>=355).
    try: d = open(path, "rb").read()
    except OSError: return -1
    m = re.match(rb'P6\s+(\d+)\s+(\d+)\s+(\d+)\s', d); W = int(m.group(1)); px = d[m.end():]
    sx = 0; n = 0
    for k in range(len(px) // 3):
        R, G, B = px[3*k], px[3*k+1], px[3*k+2]; x = k % W
        if x >= 355 and R < 110 and 88 < G < 165 and B > 140:
            sx += x; n += 1
    return (sx / n) if n > 80 else -1

rc = 0
try:
    s = None
    for _ in range(60):
        try:
            s = socket.socket(socket.AF_UNIX); s.connect(MON); break
        except OSError: time.sleep(0.2)
    if s is None: p("FAIL: no monitor"); sys.exit(1)
    s.settimeout(1.0)
    def drain():
        try:
            while True:
                if not s.recv(65536): break
        except OSError: pass
    def hmp(cmd):
        s.sendall((cmd + "\n").encode()); time.sleep(0.4); drain()

    for _ in range(50):
        if ser().count("presented surface") >= 2: break
        time.sleep(1)
    time.sleep(int(os.environ.get("AE_RENDER_WAIT", "14")))
    drain()

    hmp("screendump %s" % PPM_A); time.sleep(1.0)
    xa = hi_mean_x(PPM_A)
    p(f"  [A] before: active-pane highlight mean-x = {xa:.0f} (left pane)")

    for _ in range(3):
        hmp("sendkey right"); time.sleep(0.9)
    time.sleep(1.5)
    hmp("screendump %s" % PPM_B); time.sleep(1.0)
    xb = hi_mean_x(PPM_B)
    got = ser().count("key received")
    p(f"  [B] after Right: active-pane highlight mean-x = {xb:.0f}; crab 'key received' x{got}")

    moved_right = xa > 0 and xb > 0 and (xb - xa) > 60
    if moved_right:
        p(f"  PASS: Right arrow moved the ACTIVE pane {xb-xa:.0f}px right (left → right pane) — dual-pane switch over setu")
    else:
        p("  FAIL: the active pane did not switch on Right (pane-switch not routed)"); rc = 1
finally:
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=5)
    except Exception: qemu.kill()

p("")
p("setu-pane-test: PASS" if rc == 0 else "setu-pane-test: FAIL")
sys.exit(rc)
