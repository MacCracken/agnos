#!/usr/bin/env python3
# kriya-crash-probe — isolate "newer bins crash" cleanly. Reuses the delegation
# image (build/agnsh-deleg/agnos-deleg.img; has /bin + /hello.txt=OWLPROOF).
# ORDER MATTERS: known-good bin FIRST (proves the exec path works in THIS image
# /run), then the suspects — so a hang can't be blamed on a prior command's hang.
#   bnrmr hi        2026-06-08 build, user says WORKS -> proves #37 exec is live
#   owl -p /hello   2026-06-09 build (newer) -> is owl broken or was it collateral?
#   echo Hello      kriya (2026-06-13, newest) -> the simplest kriya applet
# Full serial per command; a command that hangs ends the run (single-core coop).
import socket, subprocess, sys, time, os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORK = os.path.join(ROOT, "build/agnsh-deleg")
IMG  = os.path.join(WORK, "agnos-deleg.img")
SER  = os.path.join(WORK, "serial-probe.log")
MON  = "/tmp/agnos-probe.sock"
if not os.path.exists(IMG):
    print("FAIL: image missing — run agnsh-delegation-test.py first"); sys.exit(1)
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/edk2/x64/OVMF_CODE.fd",
          "/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_CODE_4M.fd"):
    if os.path.exists(c): OVMF = c; break
subprocess.run(["cp", os.path.join(WORK, "vars.fd"), os.path.join(WORK, "vars-probe.fd")])
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-cpu", "max",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars-probe.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-DELEG",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
    "-serial", f"file:{SER}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def p(*a): print(*a, flush=True)
rc = 1
try:
    s = None
    for _ in range(60):
        try: s = socket.socket(socket.AF_UNIX); s.connect(MON); break
        except OSError: time.sleep(0.2)
    if s is None: p("FAIL: no monitor"); sys.exit(1)
    s.settimeout(1.0)
    def drain():
        try:
            while True: s.recv(65536)
        except OSError: pass
    def ser():
        try: return open(SER, "rb").read().decode("latin1")
        except OSError: return ""
    km = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '/': 'slash', '"': 'shift-apostrophe'}
    def typ(word, settle=2.0):
        for ch in word:
            key = km.get(ch, ch)
            if ch.isupper(): key = "shift-" + ch.lower()
            s.sendall(("sendkey " + key + "\n").encode())
            time.sleep(0.22); drain()          # slower: avoid dropped keystrokes
        time.sleep(settle)
    def run(cmd, timeout=35):
        m = len(ser()); typ(cmd, settle=1.0)
        deadline = time.time() + timeout
        while time.time() < deadline:
            seg = ser()[m:]
            if seg.count("ASSIST") >= 1 and len(seg) > len(cmd) + 6:
                time.sleep(1.0); break
            time.sleep(0.5)
        return ser()[m:]

    ok = False
    for _ in range(480):
        if "agnoshi" in ser(): ok = True; break
        time.sleep(0.25)
    p("banner seen:", ok)
    if not ok: p("FAIL: no agnsh banner"); p(ser()[-1500:]); sys.exit(1)

    # ⚠ VACUITY FLOOR ON THE LIST ITSELF. The verdict below is "every command came back", and that
    # is TRUE OF AN EMPTY LIST: comment the three suspects out to "just re-check the known-good bin"
    # and the probe goes green having driven nothing. This probe is named for four applets; below
    # four it is not this probe, so the count is asserted rather than assumed.
    CMDS = ['bnrmr hi\n', 'kriya true\n', 'owl -p /hello.txt\n', 'echo Hello\n']
    if len(CMDS) < 4:
        p(f"FAIL: probe enumerates {len(CMDS)} command(s) — vacuous below 4"); sys.exit(1)

    returned = 0
    hung = None
    for cmd in CMDS:
        seg = run(cmd, timeout=35)
        p(f"=========== {cmd.strip()!r} ===========")
        p(seg if seg.strip() else "(empty / wedged — no output, no prompt return)")
        # if the prompt did NOT come back, the system hung here — note it
        if "ASSIST" not in seg:
            p(f">>> HUNG at {cmd.strip()!r} — no prompt returned, halting probe")
            hung = cmd.strip(); break
        returned += 1
    p("=== full serial tail ===")
    p(ser()[-3000:])
    # ⚠ WHY THE VERDICT IS COMPUTED HERE AND PRINTED, NOT ASSUMED. `rc = 0` sat on this line
    # unconditionally until 1.56.58 — three lines below the hang detector that had just printed
    # ">>> HUNG at 'bnrmr hi'" and broken out of the loop. The probe reported the wedge in prose and
    # then exited 0, so the exact crash this file exists to isolate scored the same as a clean run
    # for anything reading status instead of eyeballing the log: a wrapper, `&& echo ok`, a sweep
    # row. Same colour for the run where the serial log went unreadable and every seg came back ""
    # — "we could not test it" and "it works" must never be the same colour. So the outcome is
    # derived from the enumeration and PRINTED: a probe that says "1/4 returned a prompt" is
    # reporting the hang it found, not a green tree.
    p(f"commands that returned a prompt: {returned}/{len(CMDS)}")
    if hung is not None:
        p(f"FAIL: hung at {hung!r} — {returned}/{len(CMDS)} returned a prompt"); rc = 1
    elif returned < len(CMDS):
        # Unreachable while the hang above is the loop's only early exit; kept so that adding a
        # second `break` cannot quietly shrink the enumeration back into a pass.
        p(f"FAIL: only {returned}/{len(CMDS)} commands ran — the enumeration broke"); rc = 1
    else:
        p(f"PASS: all {returned}/{len(CMDS)} commands returned a prompt"); rc = 0
    s.sendall(b"quit\n"); time.sleep(0.2)
finally:
    qemu.terminate()
    try: qemu.wait(timeout=3)
    except subprocess.TimeoutExpired: qemu.kill()
sys.exit(rc)
