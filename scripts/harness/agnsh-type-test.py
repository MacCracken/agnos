#!/usr/bin/env python3
# Drive agnsh in QEMU through a USB-xHCI keyboard: wait for the banner, then
# inject keystrokes via the HMP `sendkey` monitor command and watch the serial
# log for the command's output. Proves end-to-end ring-3 typing.
#
# Exit 0 = every typed line reached ring 3 and the shell answered it.
# Exit 1 = it did not (a RESULT). Exit 2 = the run could not be set up (NOT a pass).
import socket, subprocess, sys, time, os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORK = os.path.join(ROOT, "build/agnsh-smoke")
IMG  = os.path.join(WORK, "agnos-agnsh.img")
SER  = os.path.join(WORK, "serial-type.log")
MON  = "/tmp/agnos-type.sock"
# ⛔ A RUN THAT COULD NOT BE SET UP IS NOT A PASS, AND IT SAYS SO IN ITS OWN VOICE.
# This harness BUILDS NOTHING — it boots whatever `scripts/smoke/agnsh-smoke.sh` last left in
# build/agnsh-smoke/agnos-agnsh.img (CHANGELOG 1.56.42: "builds no image ... so build.sh alone tests a
# stale kernel"). With that image absent QEMU used to exit instantly and the run died 25 s later at
# "FAIL: no monitor"; with OVMF absent it died on a NameError at the Popen. Both are non-zero, but
# neither named the actual problem. Say it here, and NEVER with exit 0 — a skipped run of a
# typed-input harness is not evidence that typed input works.
if not os.path.exists(IMG):
    print(f"FAIL (setup): {IMG} missing — run scripts/smoke/agnsh-smoke.sh first", flush=True)
    sys.exit(2)
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/OVMF/OVMF_CODE.fd"):
    if os.path.exists(c): OVMF = c; break
else:
    print("FAIL (setup): no OVMF firmware found — nothing to boot the image with", flush=True)
    sys.exit(2)
subprocess.run(["cp", os.path.join(WORK, "vars.fd"), os.path.join(WORK, "vars-type.fd")])
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-cpu", "max",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars-type.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-AGNSH",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
    # ⭐ A REAL BOOT MOUSE on the same xHCI, so the HID binder has a protocol-0x02 interface to find.
    # ⚠ It is a SEPARATE device here, which is the easy case. QEMU cannot reproduce archaemenid's hard
    # one — a Keychron K2 exposing a boot keyboard AND a boot mouse in the SAME slot — so the composite
    # path is iron-only and must not be called proven from a green run here.
    "-device", "usb-mouse,bus=xhci.0",
    "-serial", f"file:{SER}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def p(*a): print(*a, flush=True)

# The shell's OWN ANSWER to each line this harness types, mirrored from agnoshi src/agnsh.cyr
# (`help` -> :381, `version` -> print_version/VERSION_STR :48, `mode` -> :422). ⚠ Mirrored, so if
# agnsh ever rewords one of these the failure is a loud "2/3 answered", never a silent pass.
# ⛔ NOT the ECHOED word: agnsh's own `help` output lists "version" and "mode" (:382-383), so counting
# echoes would let ONE surviving keystroke score 3/3 with the other two lines never delivered.
ANSWERS = (("help", "show this help"), ("version", "agnoshi 1."), ("mode", "Current mode:"))

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
    p("banner seen:", ok)
    # ⛔ NON-VACUITY GATE #1 — UNTIL 1.56.58 THIS RESULT WAS PRINTED AND THROWN AWAY.
    # There was no `rc` and no `sys.exit()` below this line at all: the success condition of the whole
    # harness was "the interpreter reached the end of the file". So a guest that triple-faulted before
    # ring 3 — or a stale/half-written agnos-agnsh.img — still connected the monitor socket (so the
    # "no monitor" exit above did not fire), returned "" from every ser() (which swallows OSError),
    # printed `banner seen: False`, printed `(((NO new output)))` at the bottom, and EXITED 0.
    # README.md lists this harness as proof of "basic typed-input paths"; on that run it typed into a
    # dead machine and reported success. The siblings that DO gate it say so plainly (sweep-test.py:152
    # `if not ok: FAIL: no agnsh banner`, console-line-preserve-test.py's "never reached the shell").
    if not ok:
        p("FAIL: no agnsh banner in 25s — the guest never reached the shell, so nothing was typed at all")
        sys.exit(1)

    # ⚠ SETTLE COM1 BEFORE MARKING, or the banner becomes evidence of typing.
    # `ok` flips the instant the WORD "agnoshi" lands, and COM1 is a byte stream: the remaining four
    # banner lines ("Built-ins: help, version, mode, ...", the version digits, the prompt) arrive
    # milliseconds later — i.e. AFTER the mark — and are then indistinguishable from output a keystroke
    # produced. Reproduced in the isolation rig: the post-mark capture opened with `[ASSIST] >  1.9.10`
    # and the whole Built-ins line, with not one key pressed yet. Wait for the port to go quiet — FOUR
    # consecutive equal readings, not one: the first cut of this loop broke on a single 0.25 s gap
    # INSIDE the banner and let the same four lines through. Bounded at 10 s, so an endlessly chatty
    # kernel still proceeds (and then answers for itself under gate #2 below).
    prev, quiet = -1, 0
    for _ in range(40):
        cur = len(ser())
        quiet = quiet + 1 if cur == prev else 0
        prev = cur
        if quiet >= 4: break
        time.sleep(0.25)

    mark = len(ser())
    km = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot'}
    def typ(word):
        for ch in word:
            s.sendall(("sendkey " + km.get(ch, ch) + "\n").encode())
            time.sleep(0.10); drain()
        time.sleep(1.4)

    # ⚠ PRIME THE INPUT PATH. In QEMU the FIRST character of the FIRST typed line is dropped — `help`
    # arrives as `elp` — and everything after it is intact. It is not the kbscan spin (restoring the old
    # 256-iteration drain does not fix it) and it is not new work: q35's i8042 used to deliver keys in
    # parallel and covered it, so deleting PS/2 (2026-08-08) made a pre-existing race VISIBLE rather than
    # creating one. ⚠ Iron has never had a PS/2 producer and has shown no key loss (AE-T2 burn: 19/19),
    # so this is believed emulation-only — believed, not proven. A bare Enter absorbs the loss.
    typ("\n")
    p("typing: help<Enter>");    typ("help\n")
    p("typing: version<Enter>"); typ("version\n")
    p("typing: mode<Enter>");    typ("mode\n")
    time.sleep(0.8)
    # ⭐ MOVE THE MOUSE, so the boot-mouse endpoint actually reports and the kernel's accumulator has
    # something to fold. Without this, "hid: mouse configured" would be the whole of the evidence — a
    # binder can perfectly bind a device that never speaks, which is the same class of green as a marker
    # that proves only compilation.
    for _i in range(12):
        s.sendall(b"mouse_move 8 5\n"); time.sleep(0.12); drain()
    s.sendall(b"mouse_button 1\n"); time.sleep(0.15); drain()
    s.sendall(b"mouse_button 0\n"); time.sleep(0.5); drain()
    time.sleep(1.2)
    new = ser()[mark:]
    p("================ NEW serial output after typing ================")
    p(new if new.strip() else "(((NO new output — keystrokes did not register)))")
    p("===============================================================")

    # ⛔ NON-VACUITY GATE #2 — AND "NEW OUTPUT IS NON-EMPTY" IS NOT A FLOOR.
    # The obvious floor is `new.strip()`, and it is worth exactly nothing here: klog writes to the SAME
    # COM1 asynchronously, so one timer/hid line landing inside the typing window is "new output" that no
    # keystroke produced. Rig-proved on a guest whose keyboard delivered nothing at all: the capture
    # filled with `hid: poll idle, N ticks` and a non-empty test would have called that green.
    # The floor is therefore the SHELL'S ANSWER to each line we typed, COUNTED AND PRINTED — a run that
    # reports 1/3 is telling you its own input path broke, which is the only thing this harness is for.
    answered = [cmd for cmd, marker in ANSWERS if marker in new]
    p(f"new serial bytes after typing: {len(new)}")
    p(f"typed lines the shell answered: {len(answered)}/{len(ANSWERS)}  {answered}")
    rc = 0 if len(answered) == len(ANSWERS) else 1
    p("agnsh-type-test:", "PASS — every typed line reached ring 3 and was answered" if rc == 0
      else "FAIL — a typed line went unanswered; a FAIL here is a RESULT, not a broken harness")
    s.sendall(b"quit\n"); time.sleep(0.2)
finally:
    qemu.terminate()
    try: qemu.wait(timeout=3)
    except subprocess.TimeoutExpired: qemu.kill()
sys.exit(rc)
