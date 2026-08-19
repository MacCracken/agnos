#!/usr/bin/env python3
# ae-resize-fault-test — REPRODUCE the 2026-08-18 iron page fault in QEMU.
#
# ⭐⭐ WHAT THIS IS FOR. The burn ended with the compositor dead:
#     resize started -- a grip press was caught, region: 6
#     window action applied — 5 (minimize), source 2 (button)   x2
#     key usage seen: 63 (F6)   key usage seen: 62 (F5)
#     fault: pid=6 vec=e cr2=0x12600000 err=0x4 rip=0x623d43
#     run: exit 142
# An iron boot costs the operator a reboot of their only machine; this costs a minute. The fault is
# in USERLAND (the compositor), which is QEMU's job.
#
# ⛔ THE SEQUENCE IS THE EXPERIMENT, not the keys individually. What is suspected is a RESIZE LEFT IN
# FLIGHT (the grip press was caught and never released) while the window it holds is minimized and
# then maximized under it. Each of those was applied TWICE on iron because the launcher/F2/F3 chrome
# handlers bypassed the release filter `input_handle` applies at its own door.
#
# ⚠ AE_BIN selects which compositor to stage, so the same harness answers both halves:
#     AE_BIN=<pre-fix binary>  -> does the harness reproduce the fault at all?
#     AE_BIN=<post-fix binary> -> does the press-gate fix remove it?
# Reproducing FIRST is the point. A harness that has never produced the fault cannot clear a fix.
import os, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/ae-resize-fault")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-aefault.img")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-aefault.sock"
AGNOS  = os.path.join(ROOT, "build/agnos")
GNOBOOT= os.path.join(ROOT, "../gnoboot/build/BOOTX64.EFI")
AE_BIN = os.environ.get("AE_BIN", os.path.join(ROOT, "../aethersafha/build/aethersafha_agnos"))
DISK_MB, PART_OFFSET, PART_BLOCKS = 512, 34603008, 122880
EXT2_FEATURES = "^resize_inode,^dir_index,^ext_attr,^huge_file,^64bit,^metadata_csum"

def p(*a): print(*a, flush=True)
def sh(c): subprocess.run(c, shell=True, check=True)

for need in (AGNOS, GNOBOOT, ROOTFS, AE_BIN):
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
# ⚠ The compositor under test — NOT whatever stage-tools last left in the shared rootfs.
subprocess.run(["cp", AE_BIN, os.path.join(SEED, "bin", "aethersafha")])
subprocess.run(["chmod", "+x", os.path.join(SEED, "bin", "aethersafha")])
p("seed: /bin/aethersafha <-", AE_BIN, f"({os.path.getsize(AE_BIN)} bytes)")

sh(f"dd if=/dev/zero of={IMG} bs=1M count={DISK_MB} status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100%")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-AEFAULT -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
if OVMF_VARS:
    subprocess.run(["cp", OVMF_VARS, os.path.join(WORK, "vars.fd")])
    subprocess.run(["chmod", "+w", os.path.join(WORK, "vars.fd")])
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "2048M", "-cpu", "max", "-smp", "4",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-AEF",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0", "-device", "usb-mouse,bus=xhci.0",
    "-serial", f"file:{SER}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def ser(): 
    try: return open(SER, "r", errors="replace").read()
    except FileNotFoundError: return ""

rc = 2
try:
    s = None
    for _ in range(120):
        try: s = socket.socket(socket.AF_UNIX); s.connect(MON); break
        except OSError: time.sleep(0.25)
    if s is None: p("FAIL: no monitor"); sys.exit(2)
    s.settimeout(1.0)
    def drain():
        try:
            while True:
                if not s.recv(65536): break
        except Exception: pass
    def mon(cmd, wait=0.25):
        s.sendall((cmd + "\n").encode()); time.sleep(wait); drain()

    km = {"\n": "ret", " ": "spc", "-": "minus", "/": "slash", ".": "dot"}
    def typ(t, settle=0.10):
        for ch in t:
            s.sendall(("sendkey " + km.get(ch, ch) + "\n").encode()); time.sleep(settle); drain()

    # boot to the shell
    for _ in range(240):
        if "[ASSIST]" in ser(): break
        time.sleep(0.5)
    p("booted to agnsh:", "[ASSIST]" in ser())

    typ("\n"); time.sleep(1.0)
    typ("aethersafha\n"); time.sleep(18.0)   # launcher mode — the control that is known to take keys
    mark = len(ser())
    p("compositor up:", "aethersafha:" in ser())

    # ⚠ PROBE FIRST: does ANY key reach the compositor in this harness? F3 logs on EVERY press
    # (not first-sight only), so it is the cheap oracle for key delivery. A sequence test that never
    # delivered a key produces a meaningless negative — which is exactly what the first run did.
    kmark = len(ser())
    # ⚠ LONG settle, few keys. QEMU drops keys that land between the compositor's once-per-frame HID
    # drains, so a fast burst cannot tell "2 keys x 1 action" from "1 key x 2 actions" — which is
    # exactly the doubling under test. Three keys at 2.5 s each are individually delivered, so the
    # count IS the discriminator: 3 -> fixed, 6 -> doubling.
    # ⚠ BURSTS, NOT SPACING. Measured: f3 x8 @0.7s -> 2 switches, but x3 @2.5s -> 0. The compositor
    # drains HID once per FRAME, so a key that lands between drains is gone; repetition beats patience.
    NPROBE = 8
    for _ in range(NPROBE):
        s.sendall(b"sendkey f3\n"); time.sleep(0.7); drain()
    time.sleep(1.5)
    themed = ser()[kmark:].count("theme switched")
    p(f"key-delivery probe: F3 x{NPROBE} ->", themed, "theme switches   (expect", NPROBE, "fixed /", NPROBE*2, "doubling)")
    if themed == 0:
        p("ABORT: no key reached the compositor — the sequence below cannot be trusted")

    # ⛔ THE SEQUENCE. Mouse to a window edge and PRESS-AND-HOLD so a resize grip is caught and the
    # gesture is left IN FLIGHT — that is the state the iron log shows ("resize started", never a
    # release). Then minimize and maximize the window out from under it.
    # ⭐ SPAWN A WINDOW FIRST — launcher mode starts empty, and there is nothing to resize until a
    # client exists. `--clients` pre-spawns but delivered ZERO keys in this harness, so the launcher
    # is the only path that gives both windows AND input.
    # ⚠ RETRY UNTIL IT SPAWNS. QEMU drops keys that miss the once-per-frame HID drain, so a fixed
    # burst sometimes never reaches Enter. A run with no window cannot exercise F6/F5 at all.
    spawned = False
    for attempt in range(4):
        for _ in range(10):
            s.sendall(b"sendkey f2\n"); time.sleep(0.6); drain()
        time.sleep(1.0)
        for _ in range(10):
            s.sendall(b"sendkey ret\n"); time.sleep(0.6); drain()
        time.sleep(6.0)
        if "launching from the launcher" in ser()[mark:]:
            spawned = True; break
        p(f"  spawn attempt {attempt+1} did not take — retrying")
    p("client spawned:", spawned)
    # ⛔ NO WINDOW MEANS NO EXPERIMENT. Scoring this run as "survived" is how a harness reports a pass
    # for a test it never performed — the postfix run did exactly that before this guard existed.
    if not spawned:
        p("INCONCLUSIVE: no client window — F6/F5 had nothing to act on, verdict withheld")
        try: s.sendall(b"quit\n")
        except Exception: pass
        qemu.terminate(); sys.exit(2)

    mon("mouse_move 0 0", 0.3)          # park at origin
    mon("mouse_move 700 500", 0.4)      # onto a client window's lower-right region
    mon("mouse_button 1", 0.6)          # PRESS AND HOLD — resize grip caught
    mon("mouse_move 20 20", 0.4)        # drag a little, still held
    # ⭐ SEQ selects which half runs, so the crash can be attributed to ONE action instead of a pair.
    # Operator, 2026-08-18: "I believe I hit the crash when trying to maximize."
    SEQ = os.environ.get("SEQ", "f6f5")
    p("sequence under test:", SEQ)
    if "f6" in SEQ:
        for _ in range(6):
            s.sendall(b"sendkey f6\n"); time.sleep(0.7); drain()   # minimize
    if "f5" in SEQ:
        for _ in range(6):
            s.sendall(b"sendkey f5\n"); time.sleep(0.7); drain()   # maximize
    mon("mouse_button 0", 0.5)          # release at last
    time.sleep(4.0)

    out = ser()[mark:]
    faulted   = "fault: pid=" in out
    exited142 = "exit 142" in out
    alive     = "aethersafha:" in ser()[-4000:] or not faulted

    p("---- verdict ----")
    p("  page fault observed :", faulted)
    p("  exit 142 observed   :", exited142)
    for ln in out.splitlines():
        if "fault:" in ln or "exit 1" in ln or "resize started" in ln or "window action" in ln:
            p("   |", ln.strip()[:150])
    if faulted or exited142:
        p("REPRODUCED: the compositor faulted in QEMU on the iron sequence"); rc = 1
    else:
        p("NOT REPRODUCED: the compositor survived the sequence"); rc = 0
finally:
    try: s.sendall(b"quit\n"); time.sleep(0.3)
    except Exception: pass
    qemu.terminate()
    try: qemu.wait(timeout=10)
    except Exception: qemu.kill()
p("serial:", SER)
sys.exit(rc)
