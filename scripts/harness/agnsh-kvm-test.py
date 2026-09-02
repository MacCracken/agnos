#!/usr/bin/env python3
# Drive agnsh in QEMU through a USB-xHCI keyboard: wait for the banner, then
# inject keystrokes via the HMP `sendkey` monitor command and watch the serial
# log for the command's output. Proves end-to-end ring-3 typing.
import socket, subprocess, sys, time, os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
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

# ⚠ VACUITY FLOOR. Through 1.56.58 this file contained exactly ONE sys.exit — the "no monitor" bail
# below — so every other outcome fell off the end of the script and scored 0. The banner result was
# PRINTED (`banner seen: False`) and never gated, and so was the "(((NO new output)))" line that this
# harness's own text calls "keystrokes did not register". MEASURED, on the empty case (stub QEMU that
# opens the monitor socket and writes no serial): the old form printed `banner seen: False`, printed
# its NO-new-output banner, and exited 0 — byte-for-byte the same verdict as a real KVM boot that
# typed help/version/mode and got agnsh's answers back. The concrete scenario: QEMU comes up under
# `-enable-kvm -cpu host`, the monitor socket connects (so the bail never fires), and the guest then
# triple-faults or build/agnsh-smoke/agnos-agnsh.img is stale — ser() returns "" on all 100 polls,
# three commands are typed into a dead machine, and the harness certifies end-to-end ring-3 typing
# having observed zero bytes. scripts/harness/README.md:48 lists this harness as proof of "basic
# typed-input paths"; that claim was unfalsifiable.
# ⇒ rc starts at FAIL and is cleared only where an assertion has actually been evaluated and held.
# Both enumerations now PRINT their byte counts rather than implying them: a run that says "0 bytes"
# is reporting that its OWN enumeration broke, not that agnsh had nothing to say. Floor-and-print
# pattern copied from scripts/check/toolchain-pin-check.sh.
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

    ok = False
    for _ in range(100):
        if "agnoshi" in ser(): ok = True; break
        time.sleep(0.25)
    p("banner seen:", ok, "|", len(ser()), "bytes of serial after the 25 s banner wait")
    # ⛔ GATE 1 — the guest must have REACHED agnsh. Everything below types into whatever is on the
    # other end of the xHCI keyboard; if that is a triple-faulted machine, the keystrokes land
    # nowhere and every observation made after this point is an observation of an empty log.
    if not ok:
        p("FAIL: no agnoshi banner — the guest never reached ring 3, so there is nothing to type at")
        sys.exit(1)

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
    # ⛔ GATE 2 — the typing must have MOVED the log. This is the assertion the printout above has
    # always been making in English and never in an exit code. ⚠ Deliberately a byte-growth floor and
    # NOT an echo match: the first keypress of a session is eaten by the endpoint-registry dispatch
    # (sweep-test.py:155 documents the same swallow). MEASURED on two consecutive real KVM runs of
    # this harness, 2026-09-02: the first echoed "elp" for "help", the second echoed "rsion" for
    # "version" — the swallow does not even land on a fixed command, so a gate that demanded the
    # typed text back would be red on a working kernel. Non-empty is the floor; what came back is
    # for the reader above.
    p("typed 3 commands | serial grew", len(new), "bytes")
    if new.strip():
        rc = 0
        p("PASS: agnsh banner reached and USB-xHCI keystrokes produced serial output")
    else:
        p("FAIL: 3 commands went in via HMP sendkey and the serial log did not grow by one non-blank"
          " byte — ring-3 typing was not exercised, so nothing here was proven")
    s.sendall(b"quit\n"); time.sleep(0.2)
finally:
    qemu.terminate()
    try: qemu.wait(timeout=3)
    except subprocess.TimeoutExpired: qemu.kill()

sys.exit(rc)
