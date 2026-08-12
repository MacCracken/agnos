#!/usr/bin/env python3
# hid-mouse-deferred-test — prove the MOUSE one-shot still reaches the console after being
# deferred out of ISR context (agnos 1.56.43). Adapted from sweep-test.py.
# original header follows:
# sweep-test — settle the roadmap's "Uncertain — verify on the next burn" items that are
# USERLAND, in QEMU, so they do not each cost an iron boot.
#
# ⭐ WHY THIS EXISTS AT ALL. Those items were parked as "no work expected, ride the next burn"
# and then rode several burns without producing an outcome. Three of the four are pure userland
# behaviour — a shell reaction, a syscall wrapper, a version string — and userland is QEMU's
# job, not iron's ([[feedback_localize_before_theorizing_userland_is_qemu]]). Only the ones that
# genuinely need archaemenid's own silicon (the xHCI keyboard's Backspace scancode, timestamps
# landing on a real disk) belong on a burn card. An iron boot costs the operator a reboot of
# their only machine; a QEMU run costs a minute.
#
# Checks, in this order (see the ordering note below):
#   1. iam Kernel line   — `iam` printed a bare "AGNOS" with no version. The whole chain is wired
#                          (_AGNOS_VERSION -> uname#34 release@32 -> mihi_uname -> iam_render_kernel),
#                          so the standing hypothesis is a stale staged binary. This runs a freshly
#                          built one; a bare AGNOS here means the hypothesis is WRONG and there is
#                          a real bug.
#   2. kriya ln -s       — un-gated at kriya 1.1.9 (K_HAVE_SYMLINK 0 -> 1, routed through the named
#                          SYS_SYMLINK#63). The kernel primitive is already proven by tests/symlink;
#                          what is unproven is kriya's own wiring, which no host smoke can reach
#                          because the agnos arm is compiled out on Linux by construction.
#   3. kriya readlink    — the no-follow peer (#70). Reading back the LINK TEXT (not the followed
#                          content) is what distinguishes a real readlink from a stat that followed.
#   4. faulter &         — the `bg-fault` item: a background job that takes a #PF. Does the shell
#                          survive and reap it, or halt with it?
#
# ⚠ ORDER IS DELIBERATE: the faulting job runs LAST. It is the only check that deliberately
# destabilises the system, so anything it perturbs cannot contaminate a reading taken before it.
# A fault-first ordering would make every later result un-attributable.
#
# ⛔ Each check reports its own PASS/FAIL and the script exits non-zero if ANY fail — but a failure
# here is a RESULT, not a broken harness. These are open questions; "kriya ln -s fails on agnos" is
# exactly the kind of answer this exists to produce, and it should be read as data.
#
# Builds its own image from build/rootfs (so run stage-tools.sh first) + build/agnos.
import socket, subprocess, sys, time, os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GNOBOOT = os.environ.get("GNOBOOT_ROOT", os.path.join(ROOT, "../gnoboot")) + "/build/BOOTX64.EFI"
AGNOS = os.path.join(ROOT, "build/agnos")
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK = os.path.join(ROOT, "build/hidmouse")
IMG = os.path.join(WORK, "agnos-hidmouse.img")
SEED = os.path.join(WORK, "seed")
SER = os.path.join(WORK, "serial-hidmouse.log")
MON = "/tmp/agnos-hidmouse.sock"
PART_OFFSET = 33 * 1048576
PART_BLOCKS = (67 * 1048576) // 4096
EXT2_FEATURES = os.environ.get("EXT2_SMOKE_FEATURES",
                               "^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg")

def need(*paths):
    for p in paths:
        if not os.path.exists(p):
            print("FAIL: missing", p, "(build the kernel + run stage-tools.sh --build first)")
            sys.exit(1)
need(GNOBOOT, AGNOS, os.path.join(ROOTFS, "bin/agnsh"),
     os.path.join(ROOTFS, "bin/kriya"), os.path.join(ROOTFS, "bin/iam"),
     os.path.join(ROOTFS, "bin/faulter"))

OVMF_CODE = OVMF_VARS = None
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/edk2/x64/OVMF_CODE.fd",
          "/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_CODE_4M.fd"):
    if os.path.exists(c): OVMF_CODE = c; break
for c in ("/usr/share/edk2/x64/OVMF_VARS.4m.fd", "/usr/share/edk2/x64/OVMF_VARS.fd",
          "/usr/share/OVMF/OVMF_VARS.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"):
    if os.path.exists(c): OVMF_VARS = c; break
if not OVMF_CODE or not OVMF_VARS:
    print("FAIL: OVMF not found"); sys.exit(1)

def sh(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if r.returncode != 0:
        print("FAIL build step:", cmd, "\n", r.stderr.decode("latin1")[:400]); sys.exit(1)

subprocess.run(["rm", "-rf", WORK]); os.makedirs(WORK, exist_ok=True)
subprocess.run(["cp", "-a", ROOTFS, SEED])
# A known symlink TARGET with known contents, so a followed read and a no-follow readlink
# return provably DIFFERENT bytes. Without that contrast, a stat that silently followed would
# be indistinguishable from a working readlink.
os.makedirs(os.path.join(SEED, "etc"), exist_ok=True)
with open(os.path.join(SEED, "etc", "hostname"), "w") as f: f.write("archaemenid\n")
sh(f"dd if=/dev/zero of={IMG} bs=1M count=128 status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100MiB")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-HIDM -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
subprocess.run(["cp", OVMF_VARS, os.path.join(WORK, "vars.fd")])
subprocess.run(["chmod", "+w", os.path.join(WORK, "vars.fd")])
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass
print(f"built sweep image: {IMG}")

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-cpu", "max",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-HIDM",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
    "-device", "usb-mouse,bus=xhci.0",
    "-serial", f"file:{SER}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def p(*a): print(*a, flush=True)
results = {}
rc = 1
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
            while True: s.recv(65536)
        except OSError: pass
    def ser():
        try: return open(SER, "rb").read().decode("latin1")
        except OSError: return ""
    km = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '/': 'slash', '&': 'shift-7',
          '_': 'shift-minus'}
    def typ(word, settle=2.0):
        for ch in word:
            key = km.get(ch, ch)
            if ch.isupper(): key = "shift-" + ch.lower()
            s.sendall(("sendkey " + key + "\n").encode())
            time.sleep(0.10); drain()
        time.sleep(settle)
    def run_wait(cmd, marker, timeout=30):
        m = len(ser()); typ(cmd, settle=1.0)
        deadline = time.time() + timeout
        while time.time() < deadline:
            seg = ser()[m:]
            if marker is not None and marker in seg: return seg
            time.sleep(0.5)
        return ser()[m:]

    ok = False
    for _ in range(480):
        if "agnoshi" in ser(): ok = True; break
        time.sleep(0.25)
    p("banner seen:", ok)
    if not ok: p("FAIL: no agnsh banner"); sys.exit(1)
    time.sleep(1.0)

    # ⛔ WARM-UP KEYSTROKE — THE FIRST KEY OF THE SESSION IS EATEN, AND IT COST A RESULT.
    # The very first press is what triggers "hid: first keyboard report dispatched via the
    # endpoint registry", and it does not reach the line editor. On the first run of this
    # harness that swallowed the `r` of `run /bin/iam`; agnsh saw `un /bin/iam`, could not
    # parse it, and the iam check reported FAIL. ⇒ It looked exactly like "iam is broken"
    # while measuring nothing about iam at all — a dropped keystroke wearing a bug's clothes.
    # A bare Enter absorbs the window before any check that carries meaning runs.
    typ("\n", settle=2.0)

    # ---- THE POINT OF THIS HARNESS -------------------------------------------------------
    # The mouse one-shot ("hid: first mouse report accumulated") used to be printed from INSIDE
    # hid_process_mouse_report, i.e. from ISR context, where kprintln can deadlock the CPU against
    # its own console lock. It is now deferred: hid_poll sets a flag and hid_service_deferred()
    # prints it from thread context (kb_has_key + the #98 ptrscan arm).
    #
    # ⭐ THAT REFACTOR IS ONLY PROVEN IF THE LINE STILL APPEARS. A silent success would look
    # identical to a broken flush, so this harness makes the mouse actually move and then asserts
    # the line arrives. It is the mouse half of the reachability proof; the keyboard half is
    # covered by sweep-test.py, which sees the line on every run.
    #
    # ⚠ NO TYPING IS REQUIRED between the motion and the assertion, and that is deliberate: the
    # shell sits in a kb_has_key() poll loop, which calls hid_service_deferred() on every pass. If
    # the line only appeared after a keystroke, the flush would be reaching ring 3 by luck rather
    # than by the polling path the fix relies on.
    boot_mark = len(ser())
    bound_line = ""
    for ln in ser().splitlines():
        if "boot-mouse interfaces bound" in ln: bound_line = ln.strip()
    p("  bind line:", bound_line or "(none)")
    results["a boot mouse was bound at all"] = "bound: 1" in bound_line or "bound: 2" in bound_line

    m = len(ser())
    for _ in range(12):
        s.sendall(b"mouse_move 24 18\n"); time.sleep(0.15); drain()
    deadline = time.time() + 30
    seen = False
    while time.time() < deadline:
        if "hid: first mouse report accumulated" in ser()[boot_mark:]: seen = True; break
        time.sleep(0.5)
    results["mouse one-shot flushed from thread context (no typing)"] = seen
    p("  after motion, one-shot seen without typing:", seen)

    # The shell must still be alive and answering after all of that — if the deferred flush had
    # deadlocked or corrupted anything, this is where it would show.
    post = run_wait("version\n", "agnoshi 1.", timeout=30)
    results["shell still answers after mouse activity"] = "agnoshi 1." in post

    p("=========== mouse segment ==========="); p(ser()[m:][-700:])
    p("=" * 60)
    for k, v in results.items():
        p(f"  {'PASS' if v else 'FAIL'}  {k}")
    rc = 0 if all(results.values()) else 1
    p("hid-mouse-deferred-test:", "PASS" if rc == 0 else "FAIL")
    s.sendall(b"quit\n"); time.sleep(0.2)
finally:
    qemu.terminate()
    try: qemu.wait(timeout=3)
    except subprocess.TimeoutExpired: qemu.kill()
sys.exit(rc)
