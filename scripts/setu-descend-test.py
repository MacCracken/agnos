#!/usr/bin/env python3
# setu-descend-test.py — prove crab DIRECTORY NAVIGATION on agnos: Enter descends
# into the selected directory (re-readdir the child), Backspace ascends to the
# parent. crab logs each successful navigation to serial as "crab: cd <path>"
# (the dispositive gate). Key delivery over setu is a touch lossy (the nav/pane
# tests tolerate it too), so each nav action retries until its effect is observed.
#
# Drive: focus the right pane ("/"), descend into entry 0 (a directory), then
# ascend back to "/". Reuses build/ae-setu-smoke/agnos-ae.img (built by
# aethersafha-setu-smoke.sh, which stages the fresh crab-agnos).
import socket, subprocess, sys, time, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = ROOT + "/build/ae-setu-smoke"
IMG  = WORK + "/agnos-ae.img"
SER  = WORK + "/serial-descend.log"
MON  = WORK + "/mon-descend.sock"
VARS = WORK + "/vars-descend.fd"
PPM_A = WORK + "/crab-descend-before.ppm"
PPM_B = WORK + "/crab-descend-after.ppm"

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
    def kr(): return ser().count("key received")
    def sendkey(k):
        drain(); s.sendall((f"sendkey {k}\n").encode()); time.sleep(0.5); drain()
    def screendump(path):
        drain(); s.sendall((f"screendump {path}\n").encode()); time.sleep(1.5); drain()

    # wait for both clients (puka + crab) to present, then settle
    for _ in range(50):
        if ser().count("presented surface") >= 2: break
        time.sleep(1)
    time.sleep(int(os.environ.get("AE_RENDER_WAIT", "14")))
    drain()
    screendump(PPM_A)

    # focus the RIGHT pane ("/") — retry until a key lands (delivery is lossy)
    focused = False
    for _ in range(4):
        before = kr(); sendkey("right"); time.sleep(1.2)
        if kr() > before: focused = True; break
    p(f"  [focus]   right pane -> {'active' if focused else 'NO key landed'}")

    # descend into the selected directory — retry until a non-root cd is logged
    descended_to = None
    for _ in range(4):
        sendkey("ret"); time.sleep(1.6)
        m = re.search(r'crab: cd (/\S+)', ser())
        if m: descended_to = m.group(1); break
    p(f"  [descend] Enter -> {'cd ' + descended_to if descended_to else 'NO cd logged'}")
    screendump(PPM_B)

    # ascend back to the parent "/" — retry until the root cd is logged
    ascended_root = False
    for _ in range(4):
        sendkey("backspace"); time.sleep(1.6)
        if "crab: cd /\n" in ser(): ascended_root = True; break
    p(f"  [ascend]  Backspace -> {'cd / (root)' if ascended_root else 'NO root cd logged'}")

    p(f"  crab 'key received' x{kr()}")
    descend_ok = descended_to is not None and descended_to != "/"
    if descend_ok and ascended_root:
        p(f"  PASS: crab descended into {descended_to} on Enter and ascended to / on Backspace — DIRECTORY NAVIGATION over setu")
    else:
        p("  FAIL: navigation gate not met (descend_ok=%s ascend_ok=%s)" % (descend_ok, ascended_root)); rc = 1
finally:
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=5)
    except Exception: qemu.kill()

p("")
p("setu-descend-test: PASS" if rc == 0 else "setu-descend-test: FAIL")
sys.exit(rc)
