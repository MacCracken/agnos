#!/usr/bin/env python3
# setu-focus-test.py — prove FOCUS routes over setu: TAB cycles focus, the compositor
# sends SETU_INPUT_FOCUS to the affected clients, and each client re-renders its border
# BRIGHT (focused) vs DIM (unfocused). Reuses the aethersafha-setu-smoke image (two
# cascaded present_probe clients) + a USB-xHCI keyboard for HMP `sendkey`.
#
# Windows: client A (first-accepted) top-left (x<355), client B (last-accepted) bottom-right
# (x>=355). Initial focus = the last-accepted client (B, bright). Inject TAB twice — focus
# cycles B -> Files(no client) -> A — so focus lands on A. The BRIGHT-green border must move
# from region B to region A: focus is client-rendered, over setu, driven by keyboard.
import socket, subprocess, sys, time, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = ROOT + "/build/ae-setu-smoke"
IMG  = WORK + "/agnos-ae.img"
SER  = WORK + "/serial-focus.log"
MON  = WORK + "/mon-focus.sock"
VARS = WORK + "/vars-focus.fd"
PPM_A = WORK + "/setu-focus-before.ppm"
PPM_B = WORK + "/setu-focus-after.ppm"

if not os.path.exists(IMG):
    print("FAIL: %s missing — run scripts/aethersafha-setu-smoke.sh first" % IMG); sys.exit(1)

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

def regions(path):
    # bright-green border pixels in region A (x<355) vs region B (x>=355)
    try: d = open(path, "rb").read()
    except OSError: return (-1, -1)
    m = re.match(rb'P6\s+(\d+)\s+(\d+)\s+(\d+)\s', d)
    if not m: return (-1, -1)
    W = int(m.group(1)); px = d[m.end():]
    a = b = 0
    n = len(px) // 3
    for k in range(n):
        j = k * 3
        R, G, B = px[j], px[j+1], px[j+2]
        if R < 80 and G > 200 and B < 80:      # bright green = a FOCUSED client's border
            if (k % W) < 355: a += 1
            else: b += 1
    return (a, b)

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
        s.sendall((cmd + "\n").encode()); time.sleep(0.5); drain()

    for _ in range(50):
        if ser().count("presented surface") >= 2: break
        time.sleep(1)
    time.sleep(int(os.environ.get("AE_RENDER_WAIT", "14")))
    drain()

    # (A) BEFORE: last-accepted client (region B) holds focus -> B border bright.
    hmp("screendump %s" % PPM_A); time.sleep(1.0)
    aA, bA = regions(PPM_A)
    p(f"  [A] before: bright-green border  regionA(x<355)={aA}  regionB(x>=355)={bA}")

    # Cycle focus with TAB: B -> Files(no client) -> A.  (usb-kbd HID: TAB scancode)
    hmp("sendkey tab"); time.sleep(1.5)
    hmp("sendkey tab"); time.sleep(2.0)

    # (B) AFTER: focus now on region A -> A border bright, B dim.
    hmp("screendump %s" % PPM_B); time.sleep(1.0)
    aB, bB = regions(PPM_B)
    p(f"  [B] after TABx2: bright-green border  regionA(x<355)={aB}  regionB(x>=355)={bB}")

    # Region A is present_probe (green borders); region B is the dhancha widget client
    # (blue title, no green border). Initial focus = the last-accepted client (dhancha, B),
    # so present_probe (A) starts DIM. TAB cycles B -> Files -> A, landing focus on
    # present_probe, whose border goes BRIGHT green — the focus indicator moving over setu.
    moved_to_A = aB > 500 and aA < 300      # present_probe went dim -> bright on TAB
    p(f"      present_probe (region A) bright-green border {aA}->{aB}")
    if moved_to_A:
        p("  PASS: TAB moved focus onto present_probe — its border went BRIGHT green (focus routed over setu)")
    elif aB != aA:
        p("  PARTIAL: the focus indicator changed but not the expected dim->bright on region A — inspect the PPMs"); rc = 1
    else:
        p("  FAIL: focus indicator did not move on TAB — SETU_INPUT_FOCUS not reaching clients"); rc = 1
finally:
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=5)
    except Exception: qemu.kill()

p("")
p("  --- serial tail (setu) ---")
for ln in [l for l in ser().splitlines() if any(k in l for k in ("setu","aethersafha","presented","client"))][-8:]:
    p("   " + ln)
p("")
p("setu-focus-test: PASS — focus routes over setu (TAB-cycled, client-rendered)" if rc == 0 else "setu-focus-test: FAIL")
sys.exit(rc)
