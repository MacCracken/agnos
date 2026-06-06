#!/usr/bin/env python3
# Drive agnsh's FS verbs on the REAL kernel ext2 root in QEMU (xHCI keyboard via
# HMP sendkey), proving the 1.4.2 verbs execute against the live filesystem — not
# just the host smoke. Sequence:
#   echo VERBPROOF > /vtest   (echo verb -> open(AO_CREAT)+write on ext2)
#   ls /                       (ls verb -> getdents; must now list `vtest`)
#   cat /vtest                 (cat verb -> open+read; must print VERBPROOF)
# PASS = `vtest` appears in the `ls /` output segment AND `VERBPROOF` appears in
# the `cat` output segment (both AFTER their command, so not just typed-echo).
# Default mode is ASSIST (no confirm prompt for echo/ls/cat — all non-destructive).
import socket, subprocess, sys, time, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(ROOT, "build/agnsh-smoke")
IMG  = os.path.join(WORK, "agnos-agnsh.img")
SER  = os.path.join(WORK, "serial-verb.log")
MON  = "/tmp/agnos-verb.sock"
if not os.path.exists(IMG):
    print("FAIL: image not built — run scripts/agnsh-smoke.sh first"); sys.exit(1)
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/OVMF/OVMF_CODE.fd"):
    if os.path.exists(c): OVMF = c; break
subprocess.run(["cp", os.path.join(WORK, "vars.fd"), os.path.join(WORK, "vars-verb.fd")])
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-cpu", "max",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars-verb.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-AGNSH",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
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

    # HMP sendkey names for the chars we need (letters/digits pass through).
    km = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '/': 'slash',
          '>': 'shift-dot'}
    def typ(word):
        for ch in word:
            key = km.get(ch, ch)
            if ch.isupper(): key = "shift-" + ch.lower()
            s.sendall(("sendkey " + key + "\n").encode())
            time.sleep(0.10); drain()
        time.sleep(1.6)

    ok = False
    for _ in range(280):          # ~70s — TCG boot + DHCP retries can be slow
        if "agnoshi" in ser(): ok = True; break
        time.sleep(0.25)
    p("banner seen:", ok)
    if not ok: p("FAIL: no agnsh banner"); sys.exit(1)

    p("typing: echo VERBPROOF > /vtest")
    typ("echo VERBPROOF > /vtest\n")

    m_ls = len(ser())
    p("typing: ls /")
    typ("ls /\n")
    ls_seg = ser()[m_ls:]

    m_cat = len(ser())
    p("typing: cat /vtest")
    typ("cat /vtest\n")
    cat_seg = ser()[m_cat:]

    time.sleep(0.6)
    p("=========== ls / segment ===========")
    p(ls_seg if ls_seg.strip() else "(empty)")
    p("=========== cat /vtest segment ===========")
    p(cat_seg if cat_seg.strip() else "(empty)")
    p("==========================================")

    ls_ok = "vtest" in ls_seg            # echo created a real ext2 file
    cat_ok = "VERBPROOF" in cat_seg      # cat read it back
    p("ls lists vtest (echo wrote to ext2):", ls_ok)
    p("cat returns VERBPROOF (read back):", cat_ok)
    if ls_ok and cat_ok:
        p("agnsh-verb-test: PASS"); rc = 0
    else:
        p("agnsh-verb-test: FAIL")
    s.sendall(b"quit\n"); time.sleep(0.2)
finally:
    qemu.terminate()
    try: qemu.wait(timeout=3)
    except subprocess.TimeoutExpired: qemu.kill()
sys.exit(rc)
