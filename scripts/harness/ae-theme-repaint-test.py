#!/usr/bin/env python3
# ae-theme-test — REPRODUCE the 2026-08-18 iron page fault in QEMU.
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
WORK   = os.path.join(ROOT, "build/ae-theme")
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
sh(f"mkfs.ext2 -F -q -L AGNOS-AETHAULT -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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
    "-device", "nvme,drive=disk0,serial=AGNOS-AETH",
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

    SHOT_A = os.path.join(WORK, "a.ppm"); SHOT_B = os.path.join(WORK, "b.ppm")

    def read_ppm(path):
        with open(path, "rb") as f:
            if f.readline().strip() != b"P6": return None
            line = f.readline()
            while line.startswith(b"#"): line = f.readline()
            w, h = map(int, line.split()); f.readline()
            return w, h, f.read(w * h * 3)
    def px(img, x, y):
        w, h, d = img; i = (y * w + x) * 3; return tuple(d[i:i+3])

    # ⭐ EXERCISE THE LAUNCHER FIRST, THEN CLOSE IT. The operator's burn paired F2 with theme
    # cycling, and a launcher that registers no damage leaves the frame partially copied — so the
    # pairing is worth reproducing.
    # ⛔⛔ BUT IT MUST BE CLOSED BEFORE F3, AND THIS HARNESS ORIGINALLY WAS NOT. `lnch_key` SWALLOWS
    # every key it does not itself use (launcher.cyr:119) — deliberately, because a modal chooser
    # that leaks keys types into the window behind it. So with the panel up, F3 never reaches the
    # theme handler: four bursts of eight delivered ZERO switches and the run went INCONCLUSIVE
    # every time. That is a harness that never performed its experiment, not a compositor defect.
    # Esc is the launcher's own close key (`HID_ESC` -> LNCH_K_CONSUMED, `lnch_open = 0`).
    if os.environ.get("LNCH", "1") == "1":
        for _ in range(8):
            s.sendall(b"sendkey f2\n"); time.sleep(0.7); drain()
        time.sleep(2.0)
        p("launcher open:", "launcher opened" in ser()[mark:])
        for _ in range(6):
            s.sendall(b"sendkey esc\n"); time.sleep(0.7); drain()
        time.sleep(2.0)

    mon(f"screendump {SHOT_A}", 3.0)
    before = read_ppm(SHOT_A)
    # ⚠ RETRY THE BURST. QEMU drops keys that land between the compositor's once-per-frame HID
    # drains, so a single burst can deliver ZERO — this run reported "theme switches observed: 0"
    # and correctly went INCONCLUSIVE, which is a test that never ran, not a pass. Same retry shape
    # the spawn in ae-resize-fault-test.py needed for the same reason.
    nsw = 0; kmark = len(ser())
    for attempt in range(4):
        for _ in range(8):
            s.sendall(b"sendkey f3\n"); time.sleep(0.7); drain()
        time.sleep(2.0)
        nsw = ser()[kmark:].count("theme switched")
        if nsw > 0: break
        p(f"  f3 burst {attempt + 1} delivered nothing — retrying")
    mon(f"screendump {SHOT_B}", 3.0)
    after = read_ppm(SHOT_B)
    p("theme switches observed:", nsw)
    if before is None or after is None or nsw == 0:
        p("INCONCLUSIVE: no screendump or no theme switch"); rc = 2
    else:
        w, h, _ = before
        p(f"framebuffer {w}x{h}")
        # ⛔ THREE REGIONS, MEASURED SEPARATELY — the operator reported the titlebar following the
        # theme while the background and the top bar did not. One "did the screen change" check
        # cannot tell those apart.
        panel  = [px(before, x, 6)  != px(after, x, 6)  for x in range(20, w-20, 37)]
        deskbg = [px(before, x, h//2) != px(after, x, h//2) for x in range(10, w-10, 53)]
        p("  top bar  (y=6)      changed pixels:", sum(panel), "/", len(panel))
        p("  desktop bg (y=h/2)  changed pixels:", sum(deskbg), "/", len(deskbg))
        rc = 0 if (sum(panel) and sum(deskbg)) else 1
        p("VERDICT:", "both repaint" if rc == 0 else "AT LEAST ONE REGION DID NOT REPAINT")
    out = ""

finally:
    try: s.sendall(b"quit\n"); time.sleep(0.3)
    except Exception: pass
    qemu.terminate()
    try: qemu.wait(timeout=10)
    except Exception: qemu.kill()
p("serial:", SER)
sys.exit(rc)
