#!/usr/bin/env python3
# puka-resize-test — does maximizing puka resize the TERMINAL, not just the window frame?
#
# ⭐ THE BUG (iron, 2026-08-19): "fullscreen of puka expands the window but not the terminal display
# itself." Maximize changes the WINDOW; the surface belongs to the client, so only the client can
# grow it. aethersafha 0.16.8 began SENDING `SETU_CONFIGURE` and clamps its blit until the client
# re-attaches — puka never handled the message, so the frame grew and the grid stayed 80x24.
#
# ⛔ THE CONTRACT EXISTED AT THREE LAYERS WITH NO CONSUMER: `WIN_EV_RESIZE` and `win_resize_apply`
# were in the platform ABI (the wayland backend even raises the event), the setu backend stubbed
# `win_resize_apply` to `return 0`, and the engine loop tested for neither. Fixed in puka 0.6.18.
#
# ⛔ THE ORACLE IS THE NEW GRID SIZE, NOT THE EVENT. "resized" on its own only proves a message
# arrived; the defect was that the grid did not follow. puka prints the adopted dims, and this
# asserts they actually GREW past the 80x24 it opened with.
#
# ⚠ Exits INCONCLUSIVE (2) if puka never spawned or the compositor never came up — a resize test
# that never had a window is not a pass.
import os, re, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/puka-resize")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-pukaresize.img")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-pukaresize.sock"
AGNOS  = os.path.join(ROOT, "build/agnos")
GNOBOOT= os.path.join(ROOT, "../gnoboot/build/BOOTX64.EFI")
AE_BIN = os.environ.get("AE_BIN",   os.path.join(ROOT, "../aethersafha/build/aethersafha_agnos"))
PK_BIN = os.environ.get("PUKA_BIN", os.path.join(ROOT, "../puka/build/puka_agnos"))
DISK_MB, PART_OFFSET, PART_BLOCKS = 512, 34603008, 122880
EXT2_FEATURES = "^resize_inode,^dir_index,^ext_attr,^huge_file,^64bit,^metadata_csum"

def p(*a): print(*a, flush=True)
def sh(c): subprocess.run(c, shell=True, check=True)

for need in (AGNOS, GNOBOOT, ROOTFS, AE_BIN, PK_BIN):
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
for src, dst in ((AE_BIN, "aethersafha"), (PK_BIN, "puka")):
    subprocess.run(["cp", src, os.path.join(SEED, "bin", dst)])
    subprocess.run(["chmod", "+x", os.path.join(SEED, "bin", dst)])
    p(f"seed: /bin/{dst} <- {src} ({os.path.getsize(src)} bytes)")

sh(f"dd if=/dev/zero of={IMG} bs=1M count={DISK_MB} status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100%")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-PKRS -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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
    "-device", "nvme,drive=disk0,serial=AGNOS-PKR",
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
    km = {"\n": "ret", " ": "spc", "-": "minus", "/": "slash", ".": "dot"}
    def typ(t, settle=0.12):
        for ch in t:
            s.sendall(("sendkey " + km.get(ch, ch) + "\n").encode()); time.sleep(settle); drain()

    for _ in range(240):
        if "[ASSIST]" in ser(): break
        time.sleep(0.5)
    if "[ASSIST]" not in ser():
        p("INCONCLUSIVE: never reached the shell"); sys.exit(2)
    p("booted to agnsh: True")

    typ("\n"); time.sleep(1.0)
    mark = len(ser())
    typ("aethersafha\n"); time.sleep(18.0)
    if "aethersafha:" not in ser()[mark:]:
        p("INCONCLUSIVE: compositor never started"); sys.exit(2)
    p("compositor up: True")

    # ⚠ RETRY. QEMU drops keys that miss the once-per-frame HID drain; a fixed burst sometimes never
    # reaches Enter. puka is registered FIRST in the launcher, so Enter on a fresh list picks it.
    spawned = False
    for attempt in range(4):
        for _ in range(10):
            s.sendall(b"sendkey f2\n"); time.sleep(0.6); drain()
        time.sleep(1.0)
        for _ in range(10):
            s.sendall(b"sendkey ret\n"); time.sleep(0.6); drain()
        time.sleep(8.0)
        if "puka: terminal up" in ser()[mark:]:
            spawned = True; break
        p(f"  spawn attempt {attempt+1} did not take — retrying")
    p("puka spawned:", spawned)
    if not spawned:
        p("INCONCLUSIVE: puka never started — nothing to resize"); p(ser()[-1500:]); sys.exit(2)

    rmark = len(ser())
    # F5 = maximize the focused window. Repeat: same HID-drain race as the spawn.
    for _ in range(10):
        s.sendall(b"sendkey f5\n"); time.sleep(0.7); drain()
    time.sleep(8.0)
    out = ser()[rmark:]

    m = re.search(r"puka: resized by the compositor -- grid (\d+)x(\d+) cells, (\d+)x(\d+) px", out)
    p("resize handled:", m is not None)
    for ln in out.splitlines():
        if "resiz" in ln or "fb refit" in ln: p("  |", ln.rstrip())
    if m is None:
        p("FAIL: puka never adopted a compositor resize (the 2026-08-19 defect)"); rc = 1
    else:
        cols, rows, pw, ph = (int(x) for x in m.groups())
        p(f"new grid: {cols}x{rows} cells, {pw}x{ph} px   (opened at 80x24)")
        grew   = cols > 80 or rows > 24
        exact  = (pw == cols * 8 and ph == rows * 16)   # surface must be a whole number of cells
        p("grid grew past 80x24 :", grew)
        p("px == cells * 8x16   :", exact)
        if grew and exact and "fb refit FAILED" not in out:
            p("PASS: the terminal reflowed to the maximized window"); rc = 0
        else:
            p("FAIL: the event arrived but the grid did not follow correctly"); rc = 1
finally:
    try: qemu.kill()
    except Exception: pass
p("serial:", SER)
sys.exit(rc)
