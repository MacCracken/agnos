#!/usr/bin/env python3
# hid-wheel-test — DOES A MOUSE WHEEL BYTE REACH THE KERNEL AT ALL?
#
# ⭐⭐ THIS IS THE BOTTOM OF A FIVE-REPO CHAIN, AND THE ONLY QUESTION THAT MATTERS FIRST. Scrolling
# needs agnos -> bhumi -> aethersafha -> setu -> dhancha -> crab. Every layer above is pointless if
# the byte never arrives, and until 1.56.49 it could not: `hid_process_mouse_report` read bytes [1]
# and [2] and left byte [3] — documented in its own layout comment as "wheel (s8, optional)" — on the
# floor. `#98 ptrscan`'s record had no field for it either.
#
# ⛔ USB HID BOOT PROTOCOL DEFINES A 3-BYTE MOUSE REPORT, so byte [3] is formally out of contract.
# `hid.cyr`'s own SHORT_PACKET note says the opposite happens in practice — *"the boot mouse's 4-byte
# reports on an 8-byte endpoint"* — and THAT disagreement is what this harness settles, with the
# controller's own residual field as the evidence rather than an argument.
#
# ⛔ HMP CANNOT SEND A WHEEL EVENT. `sendkey` is keys and `mouse_button` is a 1/2/4 button bitmask —
# there is no wheel verb, which is why every other harness here uses the HMP socket and this one adds
# a QMP one. QMP's `input-send-event` carries `button: wheel-up` / `wheel-down`.
#
# The oracle is a kernel line, printed from the `#98` arm (thread context — a kprintln in the HID
# drain's ISR context deadlocks, which is why the fold records a flag and this prints it):
#     hid: wheel byte seen, b3=<byte> resid=<event residual>
import json, os, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/hid-wheel")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-wheel.img")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-wheel.sock"
QMP    = "/tmp/agnos-wheel-qmp.sock"
AGNOS  = os.path.join(ROOT, "build/agnos")
GNOBOOT= os.path.join(ROOT, "../gnoboot/build/BOOTX64.EFI")
AE_BIN = os.environ.get("AE_BIN", os.path.join(ROOT, "../aethersafha/build/aethersafha_agnos"))
DISK_MB, PART_OFFSET, PART_BLOCKS = 512, 34603008, 122880
EXT2_FEATURES = "^resize_inode,^dir_index,^ext_attr,^huge_file,^64bit,^metadata_csum"

def p(*a): print(*a, flush=True)
def sh(c): subprocess.run(c, shell=True, check=True)

for need in (AGNOS, GNOBOOT, ROOTFS):
    if not os.path.exists(need):
        p(f"FAIL: missing {need}"); sys.exit(1)
OVMF = None
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/OVMF/OVMF_CODE.fd"):
    if os.path.exists(c): OVMF = c; break
if OVMF is None: p("SKIP: no OVMF"); sys.exit(2)
OVMF_VARS = None
for c in ("/usr/share/edk2/x64/OVMF_VARS.4m.fd", "/usr/share/OVMF/OVMF_VARS.fd"):
    if os.path.exists(c): OVMF_VARS = c; break

subprocess.run(["rm", "-rf", WORK]); os.makedirs(WORK, exist_ok=True)
subprocess.run(["cp", "-a", ROOTFS, SEED])
if os.path.exists(AE_BIN):
    subprocess.run(["cp", AE_BIN, os.path.join(SEED, "bin", "aethersafha")])
    subprocess.run(["chmod", "+x", os.path.join(SEED, "bin", "aethersafha")])

sh(f"dd if=/dev/zero of={IMG} bs=1M count={DISK_MB} status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100%")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-WHEEL -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
if OVMF_VARS:
    subprocess.run(["cp", OVMF_VARS, os.path.join(WORK, "vars.fd")])
    subprocess.run(["chmod", "+w", os.path.join(WORK, "vars.fd")])
open(SER, "w").close()
for sk in (MON, QMP):
    try: os.unlink(sk)
    except FileNotFoundError: pass

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "2048M", "-cpu", "max", "-smp", "4",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-WHL",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0", "-device", "usb-mouse,bus=xhci.0",
    "-serial", f"file:{SER}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
    "-qmp", f"unix:{QMP},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def ser():
    try: return open(SER, "r", errors="replace").read()
    except FileNotFoundError: return ""

rc = 2
qs = None
try:
    s = None
    for _ in range(120):
        try: s = socket.socket(socket.AF_UNIX); s.connect(MON); break
        except OSError: time.sleep(0.25)
    if s is None: p("FAIL: no HMP monitor"); sys.exit(2)
    s.settimeout(1.0)
    def drain():
        try:
            while True:
                if not s.recv(65536): break
        except Exception: pass
    km = {"\n": "ret"}
    def typ(t, settle=0.10):
        for ch in t:
            s.sendall(("sendkey " + km.get(ch, ch) + "\n").encode()); time.sleep(settle); drain()

    # QMP: connect, greet, negotiate capabilities.
    for _ in range(120):
        try: qs = socket.socket(socket.AF_UNIX); qs.connect(QMP); break
        except OSError: time.sleep(0.25)
    if qs is None: p("FAIL: no QMP socket"); sys.exit(2)
    qs.settimeout(3.0)
    qs.recv(65536)                                   # greeting
    qs.sendall(b'{"execute":"qmp_capabilities"}\n')
    qs.recv(65536)
    p("qmp: capabilities negotiated")

    def wheel(direction, n=6):
        # ⚠ A WHEEL "CLICK" IS A PRESS *AND* A RELEASE. Sending only the press leaves QEMU's input
        # layer holding a button down and the guest sees one edge, not a detent.
        for _ in range(n):
            ev = {"execute": "input-send-event", "arguments": {"events": [
                {"type": "btn", "data": {"down": True,  "button": direction}},
                {"type": "btn", "data": {"down": False, "button": direction}}]}}
            qs.sendall((json.dumps(ev) + "\n").encode())
            try: qs.recv(65536)
            except Exception: pass
            time.sleep(0.25)

    for _ in range(240):
        if "[ASSIST]" in ser(): break
        time.sleep(0.5)
    p("booted to agnsh:", "[ASSIST]" in ser())
    p("mouse bound:", "hid: mouse configured" in ser())

    # ⭐ SOMETHING MUST BE CALLING `#98`. The kernel only folds reports when the ring is polled, and the
    # one-shot prints from the ptrscan arm — no consumer, no drain, no line, and that would look
    # identical to "no wheel byte". The compositor is that consumer.
    typ("\n"); time.sleep(1.0)
    typ("aethersafha\n"); time.sleep(18.0)
    p("compositor up:", "aethersafha:" in ser())
    p("ptrscan reached from ring 3:", "ptrscan: first call from ring 3" in ser())

    mark = len(ser())
    wheel("wheel-up", 8)
    time.sleep(2.0)
    wheel("wheel-down", 8)
    time.sleep(3.0)
    out = ser()[mark:]
    seen = "hid: wheel byte seen" in out
    line = ""
    for ln in out.splitlines():
        if "wheel byte seen" in ln: line = ln.strip(); break

    p("---- verdict ----")
    p("wheel byte reached the kernel:", seen)
    if line: p("  ", line)
    if not ("ptrscan: first call from ring 3" in ser()):
        p("INCONCLUSIVE: nothing called #98, so the HID ring was never drained — this says")
        p("              nothing about the wheel byte. Get a pointer consumer running first.")
        rc = 2
    elif seen:
        p("PASS: byte [3] carries wheel data on this device — the chain above can be built.")
        rc = 0
    else:
        p("NEGATIVE, AND THIS IS A REAL ANSWER: no wheel byte arrived. USB HID boot protocol is a")
        p("        3-byte report and this device honours that, so scrolling needs the mouse moved to")
        p("        REPORT protocol with a parsed descriptor before any of the five repos above matter.")
        rc = 1
    p("serial:", SER)
finally:
    try: s.sendall(b"quit\n")
    except Exception: pass
    try: qemu.wait(timeout=10)
    except Exception: qemu.kill()
sys.exit(rc)
