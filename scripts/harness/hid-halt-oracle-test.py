# hid-halt-oracle-test — can the iron burn TELL ITS OUTCOMES APART? (residual #1, 1.56.59)
#
# ⭐ WHAT THIS GATES, AND WHY IT IS NOT THE THING THE ROADMAP WANTS. The roadmapped procedure is
# "provoke a real endpoint halt on archaemenid and confirm input resumes". That needs real silicon and
# is NOT what this runs. What this runs is the ORACLE for that burn — the instrument that decides
# whether its result means anything.
#
# ⛔ BEFORE 1.56.59 THE BURN WAS UNFALSIFIABLE. `hid_recover_halted` cleared `hid_ep_needs_reset`
# BEFORE the EP-state check and had no else branch, so a provoked halt whose state read came back
# non-Halted left ZERO trace. The operator could not distinguish
#     (a) no stall ever reached the driver — the provocation failed, from
#     (b) a stall reached us and recovery DECLINED,
# and (b) reads as a passing run. A burn that cannot fail honestly is a trip to the machine that
# produces a feeling, not a gate.
#
# ⚠ HID_CC_INJECT_HALT DOES NOT FAKE A HALT, and that is the line the 1.56.57 operator ruling drew
# when it withdrew the build-gated stub seam. The completion code is software-injected; `xhci_ep_state`
# still reads the CONTROLLER's real Output EP Context. Under QEMU the controller never halted, so it
# answers non-Halted and recovery correctly DECLINES — which is precisely the branch that used to be
# silent. ⇒ This proves the oracle. It does NOT prove Reset Endpoint / Set TR Dequeue, which has still
# never executed anywhere and still needs a real stall on real silicon.
#
# ⚠ KEYSTROKES ARE REQUIRED, and that is why this is a harness and not a smoke. QEMU's usb-kbd emits
# NO interrupt-IN completion until a key is actually pressed, so a boot-and-grep run exercises nothing:
# the injector lives in the completion path. Measured — a no-keystroke boot of this exact kernel prints
# `hid: keyboard configured` and never reaches the injector.
import os, subprocess, sys, time, socket, tempfile, shutil

ROOT    = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
GNOBOOT = os.path.join(ROOT, "../gnoboot/build/BOOTX64.EFI")
AGNOS   = os.path.join(ROOT, "build/agnos")
LOG     = os.path.join(ROOT, "build/hid-halt-oracle.log")
MON     = "/tmp/agnos-hidhalt.sock"

def p(*a): print(*a, flush=True)
def sh(c): subprocess.run(c, shell=True, check=True)

for need in (AGNOS, GNOBOOT):
    if not os.path.exists(need):
        p(f"FAIL: missing {need}"); sys.exit(1)

# ⛔ THE KERNEL MUST CARRY THE INJECTOR, and this is checked rather than assumed: without it the run
# is a silent no-op that scores PASS on a grep for absence. Same vacuity class the 1.56.58 sweep fixed.
# ⛔⛔ AND THE WITNESS IS A SEPARATE STRING FROM THE ASSERTION, BECAUSE THIS GATE CAUGHT ITSELF.
# The first version keyed this precondition on "endpoint flagged HALTED" — the very line the run
# asserts. Mutation-testing it (deleting the decline line) made the gate SKIP rather than FAIL: the
# oracle derived from the artifact under test, which is the V5 shape, in the gate written to prove an
# oracle. The arming banner is emitted by a different #ifdef site, so removing the decline line now
# reddens this gate instead of excusing it.
if b"HALT INJECTION ARMED" not in open(AGNOS, "rb").read():
    p("SKIP: build/agnos was not built with HID_CC_INJECT_HALT=1 — this run would prove nothing.")
    p("      Build it with:  HID_CC_INJECT_HALT=1 sh scripts/build.sh")
    sys.exit(2)

OC = OV = None
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/OVMF/OVMF_CODE.fd"):
    if os.path.exists(c): OC = c; break
for c in ("/usr/share/edk2/x64/OVMF_VARS.4m.fd", "/usr/share/OVMF/OVMF_VARS.fd"):
    if os.path.exists(c): OV = c; break
if not OC or not OV: p("SKIP: no OVMF"); sys.exit(2)

W = tempfile.mkdtemp(); IMG = f"{W}/d.img"
sh(f"dd if=/dev/zero of={IMG} bs=1M count=128 status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on >/dev/null 2>&1")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
shutil.copy(OV, f"{W}/vars.fd"); os.chmod(f"{W}/vars.fd", 0o644)
open(LOG, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass

q = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-cpu", "max",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OC}",
    "-drive", f"if=pflash,format=raw,file={W}/vars.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=d0",
    "-device", "nvme,drive=d0,serial=AGNOS-HIDHLT",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
    "-serial", f"file:{LOG}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def ser():
    try: return open(LOG, errors="replace").read()
    except FileNotFoundError: return ""

rc = 2
try:
    s = None
    for _ in range(120):
        try: s = socket.socket(socket.AF_UNIX); s.connect(MON); break
        except OSError: time.sleep(0.25)
    if s is None: p("FAIL: no monitor"); sys.exit(2)

    for _ in range(120):
        if "keyboard configured" in ser(): break
        time.sleep(0.5)
    if "keyboard configured" not in ser():
        p("INCONCLUSIVE: the HID keyboard never configured — nothing to complete"); sys.exit(2)
    p("keyboard configured: True")

    time.sleep(3)
    for _ in range(12):
        s.sendall(b"sendkey a\n"); time.sleep(0.35)
    time.sleep(5)
    out = ser()

    fired  = "hid: endpoint flagged HALTED but the controller reports EP state" in out
    reset  = "hid: an endpoint halted and was reset" in out
    p("decline line present:", fired)
    p("reset line present:  ", reset)
    p("---- verdict ----")
    if fired or reset:
        for l in out.splitlines():
            if "hid: endpoint flagged" in l or "hid: an endpoint halted" in l:
                p("  " + l.strip())
        p("PASS: a halting completion code reached the driver and the outcome is REPORTED.")
        p("      The iron burn can now distinguish 'no stall reached us' from 'a stall did and")
        p("      recovery declined' — before 1.56.59 both were silence, and the second read as a pass.")
        rc = 0
    else:
        p("FAIL: the injector ran but NEITHER outcome was reported — the early-out is silent again.")
        p("      That is the exact regression this gate exists to catch: it makes the iron burn")
        p("      unfalsifiable. Check hid_recover_halted's else branch.")
        rc = 1
finally:
    try: q.kill()
    except Exception: pass
    shutil.rmtree(W, ignore_errors=True)
p("serial:", LOG)
sys.exit(rc)
