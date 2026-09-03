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
# Both enumerations now PRINT their counts rather than implying them: a run that says "0/3 answered"
# is reporting that its OWN enumeration broke, not that agnsh had nothing to say. Floor-and-print
# pattern copied from scripts/check/toolchain-pin-check.sh.

# The shell's OWN ANSWER to each line this harness types, mirrored from agnoshi src/agnsh.cyr
# (`help` -> :381, `version` -> print_version/VERSION_STR :48, `mode` -> :422), same oracle and same
# spellings as the sibling agnsh-type-test.py:58 — the two harnesses must not disagree about what
# counts as agnsh having answered. ⚠ Mirrored, so if agnsh rewords one of these the failure is a loud
# "2/3 answered", never a silent pass.
# ⛔ NOT the ECHOED word, for the reason the sibling gives at :56-57: agnsh's own `help` output lists
# "version" and "mode" (:382-383), so counting echoes would let ONE surviving keystroke score 3/3.
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
    p("banner seen:", ok, "|", len(ser()), "bytes of serial after the 25 s banner wait")
    # ⛔ GATE 1 — the guest must have REACHED agnsh. Everything below types into whatever is on the
    # other end of the xHCI keyboard; if that is a triple-faulted machine, the keystrokes land
    # nowhere and every observation made after this point is an observation of an empty log.
    if not ok:
        p("FAIL: no agnoshi banner — the guest never reached ring 3, so there is nothing to type at")
        sys.exit(1)

    # ⚠ SETTLE COM1 BEFORE MARKING, so the window gate 2 reads is the TYPING window and not the tail
    # of the banner. `ok` flips the instant the WORD "agnoshi" lands and COM1 is a byte stream, so the
    # rest of the startup banner (the Built-ins line, the version digits, the prompt) arrives
    # milliseconds later — AFTER the mark — and is then indistinguishable from output a keystroke
    # produced. Reproduced in the sibling's isolation rig: the post-mark capture opened with
    # `[ASSIST] >  1.9.10` and the whole Built-ins line with not one key pressed yet. Four consecutive
    # equal readings, not one — the sibling's first cut broke on a single 0.25 s gap INSIDE the banner.
    # Bounded at 10 s so an endlessly chatty kernel still proceeds (and then answers for itself below).
    # ⚠ WHAT THIS DOES NOT BUY, stated because it would be easy to assume otherwise: it does not make
    # the answer markers un-forgeable. agnsh prints VERSION_STR from BOTH the startup banner
    # (agnsh.cyr:296) and the `version` command (:51), so a shell that CRASH-LOOPS re-prints it inside
    # the window with no key delivered. Measured on the stub rig, respawning guest, zero keystrokes:
    # 1/3 answered — the leaked one was `version`. What rejects that run is the 3-of-3 conjunction
    # below, not this loop; the loop only keeps the FIRST banner out of the measurement.
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

    # ⚠ PRIME THE INPUT PATH — and it is what makes the answer oracle below usable at all. In QEMU the
    # FIRST character of the FIRST typed line is dropped and everything after it is intact. MEASURED on
    # two consecutive real KVM runs of this harness, 2026-09-02: the first echoed "elp" for "help", the
    # second echoed "rsion" for "version" — the swallow does not even land on a fixed command. Without
    # this bare Enter to absorb it, `help` arrives as `elp`, agnsh answers "not found", and a WORKING
    # kernel scores 2/3. Same reasoning and same fix as the sibling (agnsh-type-test.py:123-129), which
    # also records that iron has never shown the loss (AE-T2 burn 19/19) — believed emulation-only.
    typ("\n")
    p("typing: help<Enter>");    typ("help\n")
    p("typing: version<Enter>"); typ("version\n")
    p("typing: mode<Enter>");    typ("mode\n")
    time.sleep(0.8)
    new = ser()[mark:]
    p("================ NEW serial output after typing ================")
    p(new if new.strip() else "(((NO new output — keystrokes did not register)))")
    p("===============================================================")
    # ⛔ GATE 2 — THE SHELL MUST HAVE ANSWERED WHAT WE TYPED. ⚠ Until 1.56.59 this gate was
    # `if new.strip()`, which is a floor ANY producer on this port can satisfy: klog writes the SAME
    # COM1 asynchronously, so a single timer/hid line landing inside the ~5 s typing window is "new
    # output" that no keystroke produced. MEASURED on the stub rig against a guest whose keyboard
    # delivered NOTHING at all: the window filled with 2044 bytes of `hid: poll idle, N ticks`, and
    # the old form printed "PASS: agnsh banner reached and USB-xHCI keystrokes produced serial
    # output" and exited 0 — byte-identical to the verdict of a real KVM run that typed three
    # commands and got three answers. A gate an unrelated producer can satisfy is not a floor, and
    # this harness is listed in scripts/harness/README.md:48 as proof of "basic typed-input paths".
    # ⚠ The 1.56.58 note this block replaced argued for byte-growth over an ECHO match, and that
    # argument is sound and is kept above where it belongs (the prime at :100) — it is a reason not to
    # demand the typed TEXT back, not a reason to accept any bytes at all. The oracle is the third
    # option neither considered: the shell's ANSWERS, counted and printed, ported from the sibling
    # agnsh-type-test.py:148-158. A run that reports 1/3 is telling you its own input path broke.
    answered = [cmd for cmd, marker in ANSWERS if marker in new]
    p(f"typed 3 commands | serial grew {len(new)} bytes")
    p(f"typed lines the shell answered: {len(answered)}/{len(ANSWERS)}  {answered}")
    if len(answered) == len(ANSWERS):
        rc = 0
        p("PASS: agnsh banner reached and every USB-xHCI-typed line was answered by the shell")
    else:
        p(f"FAIL: 3 commands went in via HMP sendkey and agnsh answered {len(answered)} of them"
          f" — ring-3 typing was not exercised end to end, so nothing here was proven"
          f" (serial grew {len(new)} bytes, which on this port proves only that SOMETHING wrote)")
    s.sendall(b"quit\n"); time.sleep(0.2)
finally:
    qemu.terminate()
    try: qemu.wait(timeout=3)
    except subprocess.TimeoutExpired: qemu.kill()

sys.exit(rc)
