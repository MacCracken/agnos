#!/usr/bin/env python3
# ae-wallpaper-load-test — does `--wallpaper <file>` actually OPEN the file on agnos?
#
# ⭐ THE BUG THIS EXISTS FOR (iron, 2026-08-19). `ls` listed the PNG at the rootfs root, argv carried
# the exact path, and the compositor still printed:
#     aethersafha: wallpaper FAILED to load (rc), falling back to the theme:
#     -1
#     /verify-2560x1440.png
# rc -1 is `sys_open() < 0`. The cause was NOT the file and NOT chitra: `sys_open` is ONE NAME with
# TWO CONTRACTS — agnos is open(name, NAMELEN, flags), Linux is open(path, flags, mode). wallpaper.cyr
# passed the Linux form, so agnos received namelen=0 and refused a valid path. Same arity, so nothing
# but the kernel's answer catches it — which is why this harness has to run on agnos, not on Linux.
#
# ⛔ THE ORACLE IS THE CONSOLE LINE, not the framebuffer. The load is reported BEFORE the desktop
# takes the screen, and QEMU has no GPU, so a pixel check here would prove nothing either way.
# PASS requires "wallpaper loaded" AND the decoded 2560x1440; a run that never reached the
# compositor exits INCONCLUSIVE (2) rather than scoring a test that was never performed.
import os, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/ae-wallpaper")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-aewp.img")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-aewp.sock"
AGNOS  = os.path.join(ROOT, "build/agnos")
GNOBOOT= os.path.join(ROOT, "../gnoboot/build/BOOTX64.EFI")
AE_BIN = os.environ.get("AE_BIN", os.path.join(ROOT, "../aethersafha/build/aethersafha_agnos"))
WP     = os.environ.get("AE_WP", "verify-2560x1440.png")
DISK_MB, PART_OFFSET, PART_BLOCKS = 512, 34603008, 122880
EXT2_FEATURES = "^resize_inode,^dir_index,^ext_attr,^huge_file,^64bit,^metadata_csum"

def p(*a): print(*a, flush=True)
def sh(c): subprocess.run(c, shell=True, check=True)

for need in (AGNOS, GNOBOOT, ROOTFS, AE_BIN, os.path.join(ROOTFS, WP)):
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
subprocess.run(["cp", AE_BIN, os.path.join(SEED, "bin", "aethersafha")])
subprocess.run(["chmod", "+x", os.path.join(SEED, "bin", "aethersafha")])
p("seed: /bin/aethersafha <-", AE_BIN, f"({os.path.getsize(AE_BIN)} bytes)")
p("seed: wallpaper /" + WP, os.path.getsize(os.path.join(SEED, WP)), "bytes")

sh(f"dd if=/dev/zero of={IMG} bs=1M count={DISK_MB} status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100%")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-AEWP -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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
    "-device", "nvme,drive=disk0,serial=AGNOS-AEW",
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
    def typ(t, settle=0.10):
        for ch in t:
            s.sendall(("sendkey " + km.get(ch, ch) + "\n").encode()); time.sleep(settle); drain()

    for _ in range(240):
        if "[ASSIST]" in ser(): break
        time.sleep(0.5)
    booted = "[ASSIST]" in ser()
    p("booted to agnsh:", booted)
    if not booted:
        p("INCONCLUSIVE: never reached the shell"); sys.exit(2)

    typ("\n"); time.sleep(1.0)
    mark = len(ser())
    # ⚠ Slow typing. The console echo mangles fast input, and a mangled path would fail the OPEN for
    # a reason that has nothing to do with the bug under test.
    typ(f"aethersafha --wallpaper /{WP}\n", settle=0.16)
    time.sleep(25.0)
    out = ser()[mark:]

    up = "aethersafha:" in out
    p("compositor up:", up)
    if not up:
        p("INCONCLUSIVE: compositor never started"); p(out[-1500:]); sys.exit(2)

    loaded = "wallpaper loaded" in out
    failed = "wallpaper FAILED to load" in out
    # ⚠ NOT a bare `"2560" in out`: the compositor also prints the SCREEN size ("screen size read
    # from the kernel / 2560 / 1440"), so a substring test passes on a run where nothing decoded.
    # The decoded size is the two lines that FOLLOW the load message — read them positionally.
    dims = False
    ls = [l.strip() for l in out.splitlines()]
    for i, l in enumerate(ls):
        if "wallpaper loaded" in l and i + 3 < len(ls):
            dims = (ls[i + 2] == "2560" and ls[i + 3] == "1440")
            break
    p("wallpaper loaded :", loaded)
    p("wallpaper FAILED :", failed)
    p("decoded 2560x1440:", dims)
    for ln in out.splitlines():
        if "wallpaper" in ln or ln.strip() in ("2560", "1440", "-1"): p("  |", ln.rstrip())

    if loaded and not failed and dims:
        p("PASS: sys_open accepted the path and chitra decoded it on agnos"); rc = 0
    else:
        p("FAIL: the wallpaper did not load on agnos"); rc = 1
finally:
    try: qemu.kill()
    except Exception: pass
p("serial:", SER)
sys.exit(rc)
