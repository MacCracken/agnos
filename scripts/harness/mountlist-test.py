# mountlist-test — can ring 3 enumerate the mount table (#104, 1.56.59)?
#
# ⭐ THE GATE. crab (the AGNOS file manager) can already ask `statfs("/mnt/fat", …)` whether ONE
# string is mounted. What it could not do is ENUMERATE, and the case that forces the difference is
# ALIASING: `vfs_mount_init` (core/vfs.cyr:396) gives an ext2-less boot the SAME backend under BOTH
# "/" and its "/mnt/..." prefix — its own comment calls them "harmless redundant aliases". Harmless
# to routing; to a sidebar they are one volume listed twice, and no probe can tell them apart. #104
# returns the backend id alongside the prefix, so a consumer can.
#
# ⛔ THE ORACLE LIVES IN THE RING-3 PROGRAM, NOT HERE. `tests/mountlist/mlist.cyr` asserts the
# table's SHAPE — backend in range, prefix NUL-padded past its length, root present, the `max`
# budget honoured, and a wrapping `max` refused. A harness that merely checked "it printed some
# mounts" would pass for a stub returning one zeroed record.
#
# ⚠ THE EXIT CODE IS THE RESULT (the blkprobe convention): 95 = the whole contract holds; 80-92
# pinpoint which clause broke. agnsh echoes `run: exit N`.
import os, re, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")

WORK   = os.path.join(ROOT, "build/mountlist")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-mlist.img")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-mlist.sock"
AGNOS  = os.path.join(ROOT, "build/agnos")
GNOBOOT= os.path.join(ROOT, "../gnoboot/build/BOOTX64.EFI")
MLIST  = os.path.join(ROOT, "tests/mountlist/build/mlist")
DISK_MB, PART_OFFSET, PART_BLOCKS = 512, 34603008, 122880
EXT2_FEATURES = "^resize_inode,^dir_index,^ext_attr,^huge_file,^64bit,^metadata_csum"

def p(*a): print(*a, flush=True)
def sh(c): subprocess.run(c, shell=True, check=True)

for need in (AGNOS, GNOBOOT, ROOTFS, MLIST):
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
subprocess.run(["cp", MLIST, os.path.join(SEED, "bin", "mlist")])
subprocess.run(["chmod", "+x", os.path.join(SEED, "bin", "mlist")])

EXP_BIN = len(os.listdir(os.path.join(SEED, "bin")))
p(f"seed: /bin/mlist <- {MLIST} ({os.path.getsize(MLIST)} bytes)")
p(f"seed: /bin has {EXP_BIN} entries (rdat pages it 5 at a time)")

sh(f"dd if=/dev/zero of={IMG} bs=1M count={DISK_MB} status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100%")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-MLST -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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
    "-device", "nvme,drive=disk0,serial=AGNOS-MLS",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
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
    def typ(t, settle=0.14):
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
    typ("mlist\n")
    time.sleep(20.0)
    out = ser()[mark:]

    m = re.findall(r"run: exit (\d+)", out)
    code = int(m[-1]) if m else None
    p("mlist exit code:", code if code is not None else "(never reported)")
    WHY = {
        80: "#104 returned < 1 mount — every boot mounts at least \"/\"",
        81: "#104 returned MORE records than the buffer was sized for",
        82: "a record carried backend id 0 (FS_NONE) — never emitted by a correct arm",
        83: "a record carried a backend id above FS_EXFAT(3)",
        84: "a record carried prefixlen < 1",
        85: "a record carried prefixlen > 64 — it would not fit the slot",
        86: "a prefix was NOT NUL-padded past its length — ring 3 can read a stale tail byte",
        87: "a prefix did not begin with '/' — mounts are absolute",
        88: "no 1-byte prefix in the table — root is not reported as mounted",
        89: "asking for ONE record did not return exactly one — the max budget is not honoured",
        90: "a wrapping max was ACCEPTED — is_user_array is not guarding the product (the #99 bug)",
        91: "max < 1 was accepted instead of refused",
        92: "a kernel pointer was accepted instead of refused",
    }
    faulted = "fault: pid=" in out
    p("kernel/userland fault:", faulted)
    p("---- verdict ----")
    if faulted:
        p("FAIL: a fault occurred during the run"); rc = 1
    elif code is None:
        p("INCONCLUSIVE: mlist never ran or never reported"); p(out[-1200:]); rc = 2
    elif code == 95:
        p("PASS: #104 enumerates — every record is structurally sound, prefixes are NUL-padded,")
        p("      root is present, the max budget is honoured, and a wrapping max is refused.")
        rc = 0
    else:
        p(f"FAIL: {WHY.get(code, 'unrecognised exit code')}"); rc = 1
finally:
    try: qemu.kill()
    except Exception: pass
p("serial:", SER)
sys.exit(rc)
