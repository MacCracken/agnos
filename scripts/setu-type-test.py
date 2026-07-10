#!/usr/bin/env python3
# setu-type-test.py — prove TEXT INPUT over setu: type a word into the dhancha client's
# text field and see the characters appear. Keys route kernel->bhumi->compositor->setu
# to the focused client (dhancha, region B); the client maps each HID usage to a letter,
# appends to its buffer, and re-renders the field via rekha. Each key is sent ONCE (the
# field appends per keystroke, so retries would duplicate letters).
import socket, subprocess, sys, time, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = ROOT + "/build/ae-setu-smoke"
IMG  = WORK + "/agnos-ae.img"
SER  = WORK + "/serial-type.log"
MON  = WORK + "/mon-type.sock"
VARS = WORK + "/vars-type.fd"
PPM  = WORK + "/setu-type.ppm"

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

WORD = os.environ.get("TYPE_WORD", "file")   # letters must be in the font (F I L E ...)

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

    # type the word, one key at a time (each appends one char to the field)
    p(f"  typing '{WORD}' into the focused dhancha client...")
    for ch in WORD:
        hmp("sendkey " + ch); time.sleep(1.3)
    time.sleep(1.5)
    hmp("screendump %s" % PPM); time.sleep(1.0)

    # measure white text pixels in the field band of region B (the dhancha window).
    d = open(PPM, "rb").read()
    m = re.match(rb'P6\s+(\d+)\s+(\d+)\s+(\d+)\s', d); W = int(m.group(1)); px = d[m.end():]
    # dhancha window B at ~ (360,260); chrome titlebar ~20px, then FILE title ~40, then FIELD.
    # field band ~ y[320,375], x>=355.
    fieldwhite = 0
    for k in range(len(px) // 3):
        R, G, B = px[3*k], px[3*k+1], px[3*k+2]; x = k % W; y = k // W
        if x >= 355 and 318 < y < 378 and R > 200 and G > 200 and B > 200:
            fieldwhite += 1
    p(f"  white text pixels in the field band: {fieldwhite}")
    if fieldwhite > 150:
        p(f"  PASS: typed characters appeared in the dhancha text field — TEXT INPUT over setu")
    else:
        p("  FAIL: no typed text in the field (keys dropped or not routed)"); rc = 1
finally:
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=5)
    except Exception: qemu.kill()

p("")
p("setu-type-test: PASS" if rc == 0 else "setu-type-test: FAIL")
sys.exit(rc)
