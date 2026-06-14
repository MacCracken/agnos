#!/usr/bin/env python3
# Drive agnsh in QEMU through a USB-xHCI keyboard: wait for the banner, then
# inject keystrokes via the HMP `sendkey` monitor command and watch the serial
# log for the command's output. Proves end-to-end ring-3 typing.
import socket, subprocess, sys, time, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(ROOT, "build/agnsh-smoke")
IMG  = os.path.join(WORK, "agnos-agnsh.img")
SER  = os.path.join(WORK, "serial-kvm.log")
MON  = "/tmp/agnos-kvm.sock"
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/OVMF/OVMF_CODE.fd"):
    if os.path.exists(c): OVMF = c; break
subprocess.run(["cp", os.path.join(WORK, "vars.fd"), os.path.join(WORK, "vars-kvm.fd")])
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-enable-kvm", "-cpu", "host",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars-kvm.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-AGNSH",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
    "-serial", f"file:{SER}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def p(*a): print(*a, flush=True)

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

    ok = False
    for _ in range(100):
        if "agnoshi" in ser(): ok = True; break
        time.sleep(0.25)
    p("banner seen:", ok)

    mark = len(ser())
    km = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot'}
    def typ(word):
        for ch in word:
            s.sendall(("sendkey " + km.get(ch, ch) + "\n").encode())
            time.sleep(0.10); drain()
        time.sleep(1.4)

    p("typing: help<Enter>");    typ("help\n")
    p("typing: version<Enter>"); typ("version\n")
    p("typing: mode<Enter>");    typ("mode\n")
    time.sleep(0.8)
    new = ser()[mark:]
    p("================ NEW serial output after typing ================")
    p(new if new.strip() else "(((NO new output — keystrokes did not register)))")
    p("===============================================================")
    s.sendall(b"quit\n"); time.sleep(0.2)
finally:
    qemu.terminate()
    try: qemu.wait(timeout=3)
    except subprocess.TimeoutExpired: qemu.kill()
