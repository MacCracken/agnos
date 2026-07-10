#!/usr/bin/env python3
# setu-stat-test.py — prove crab RICHER LISTING (per-entry size via stat #33) on
# agnos. crab stat's every file in a listed directory (its full path -> sys_stat,
# st_size @ +16) and logs "crab: stat <name> <size>" to serial. The left pane
# starts at /bin (real binaries), so the serial must carry plausible multi-KB/MB
# sizes. Reuses build/ae-setu-smoke/agnos-ae.img (staged fresh crab-agnos).
import socket, subprocess, sys, time, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = ROOT + "/build/ae-setu-smoke"
IMG  = WORK + "/agnos-ae.img"
SER  = WORK + "/serial-stat.log"
MON  = WORK + "/mon-stat.sock"
VARS = WORK + "/vars-stat.fd"
PPM  = WORK + "/crab-stat.ppm"

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
    # crab stat's on startup (before/around present), so a plain boot + serial grep
    for _ in range(60):
        if "crab: stat " in ser(): break
        time.sleep(1)
    time.sleep(3)

    # screendump for a visual (best-effort)
    try:
        s = socket.socket(socket.AF_UNIX); s.connect(MON); time.sleep(0.3)
        s.sendall((f"screendump {PPM}\n").encode()); time.sleep(1.5); s.close()
    except OSError: pass

    stats = re.findall(r'crab: stat (\S+) (\d+)', ser())
    for name, sz in stats:
        p(f"  stat {name:14s} = {int(sz):>10d} bytes")
    big = [ (n,int(z)) for n,z in stats if int(z) > 1000 ]
    if len(stats) >= 1 and len(big) >= 1:
        p(f"  PASS: crab stat'd {len(stats)} file(s) on agnos; {len(big)} with real (>1KB) sizes — RICHER LISTING via stat #33")
    else:
        p(f"  FAIL: expected real per-file sizes from stat #33 (got {len(stats)} stat lines, {len(big)} >1KB)"); rc = 1
finally:
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=5)
    except Exception: qemu.kill()

p("")
p("setu-stat-test: PASS" if rc == 0 else "setu-stat-test: FAIL")
sys.exit(rc)
