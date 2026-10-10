# zfs-ring3-test — the read-only ZFS mount through RING 3 (agnos 1.57.11): syscalls, and exec FROM the pool.
#
# ⭐ THE GATE. zfs-smoke.sh proves the kernel READS the pool (an in-kernel walk diffed against OpenZFS's
# manifest). This proves a PROCESS can: tests/zfs/zfsx.cyr is staged INTO the pool by the fixture
# (agnostank/payload) and agnsh is told to run `/mnt/zfs/agnostank/payload/zfsx` — so spawn#43 loads the
# ELF through vfs_file_size + vfs_read_file_at on FS_ZFS before the program's first instruction, and the
# program then drives open/read/lseek/close, stat/lstat/readlink, getdents (AO_DIRECTORY), readdir_at, statfs
# and mountlist over /mnt/zfs, and checks that every write verb is refused.
# ⚠ THE EXIT CODE IS THE RESULT (the blkprobe / mlist convention): 95 = the whole contract holds; 60..91 name
# the clause that broke (WHY below). agnsh echoes `run: exit N`.
# Disk: ESP (gnoboot + agnos) · the agnos-fs ext2 root (agnsh + the rootfs) · the fixture's main.img as a
# third GPT partition. The kernel is the PLAIN production build.
import os, re, socket, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _freshness import refuse_stale_kernel
refuse_stale_kernel(ROOT)

ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK = os.path.join(ROOT, "build/zfs-ring3")
IMG = os.path.join(WORK, "agnos-zfs.img")
SER = os.path.join(WORK, "serial.log")
MON = os.path.join(WORK, "mon.sock")
AGNOS = os.path.join(ROOT, "build/agnos")
GNOBOOT = os.path.join(os.environ.get("GNOBOOT_ROOT", os.path.join(ROOT, "../gnoboot")), "build/BOOTX64.EFI")
EXT2_FEATURES = "^resize_inode,^dir_index,^ext_attr,^huge_file,^64bit,^metadata_csum"


def p(*a): print(*a, flush=True)
def sh(c): subprocess.run(c, shell=True, check=True)


if not os.path.exists(os.path.join(ROOTFS, "bin/agnsh")):
    # a fresh tree has no staged rootfs: stage it with the smokes' own recipe (qemu-dwell.sh smoke_stage_rootfs)
    subprocess.run(["bash", "-c", '. "$1/scripts/smoke/lib/qemu-dwell.sh"; smoke_stage_rootfs "$1"', "_", ROOT])
for need in (AGNOS, GNOBOOT, ROOTFS):
    if not os.path.exists(need):
        p(f"FAIL: missing {need}"); sys.exit(1)
flags = open(AGNOS + ".flags").read() if os.path.exists(AGNOS + ".flags") else ""
if re.search(r"^flags=\S", flags, re.M):
    p("REFUSED: this harness boots the PLAIN production kernel, but build/agnos carries flags — run: sh scripts/build.sh")
    sys.exit(1)
OVMF = next((c for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/OVMF/OVMF_CODE.fd") if os.path.exists(c)), None)
OVMF_VARS = next((c for c in ("/usr/share/edk2/x64/OVMF_VARS.4m.fd", "/usr/share/OVMF/OVMF_VARS.fd") if os.path.exists(c)), None)
if OVMF is None or OVMF_VARS is None:
    p("SKIP: no OVMF"); sys.exit(2)

subprocess.run(["rm", "-rf", WORK]); os.makedirs(WORK, exist_ok=True)
# The exerciser — rebuilt every run; it IS the payload, so the fixture is keyed on its bytes.
r = subprocess.run("cd tests/zfs && rm -f build/zfsx && cyrius build --agnos zfsx.cyr build/zfsx",
                   shell=True, cwd=ROOT, capture_output=True, text=True)
if r.returncode != 0:
    p("FAIL: tests/zfs did not build"); p(r.stdout[-800:] + r.stderr[-800:]); sys.exit(1)
os.makedirs(os.path.join(WORK, "payload"))
sh(f"cp {ROOT}/tests/zfs/build/zfsx {WORK}/payload/zfsx")
r = subprocess.run(["bash", os.path.join(ROOT, "scripts/tool/zfs-fixture.sh"), "--ensure", "--payload",
                    os.path.join(WORK, "payload")], capture_output=True, text=True)
fix = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
if r.returncode != 0 or not os.path.exists(os.path.join(fix, "DONE")):
    p("INCONCLUSIVE: no fixture (scripts/tool/zfs-fixture.sh)"); p(r.stderr[-1200:]); sys.exit(2)
pool = os.path.join(fix, "main.img")
psec = os.path.getsize(pool) // 512
p(f"fixture: {fix}  (payload zfsx {os.path.getsize(WORK + '/payload/zfsx')} bytes)")

# ESP 1-33 MiB · ext2 448 MiB · ZFS right after, exactly the pool's size
EXT_START, EXT_SEC = 67584, 917504
Z_START = EXT_START + EXT_SEC
sh(f"truncate -s {(Z_START + psec + 2048) * 512} {IMG}")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on "
   f"mkpart agnos-fs ext2 {EXT_START}s {EXT_START + EXT_SEC - 1}s mkpart zfs {Z_START}s {Z_START + psec - 1}s")
sh(f"sgdisk -t 2:8300 -t 3:a504 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-ZFS -b 4096 -m 0 -O {EXT2_FEATURES} -d {ROOTFS} -E offset={EXT_START * 512} {IMG} {EXT_SEC // 8}")
sh(f"dd if={pool} of={IMG} bs=512 seek={Z_START} conv=notrunc status=none")
sh(f"cp {OVMF_VARS} {WORK}/vars.fd && chmod +w {WORK}/vars.fd")
open(SER, "w").close()

accel = ["-enable-kvm", "-cpu", "host"] if os.access("/dev/kvm", os.W_OK) and os.environ.get("SMOKE_KVM", "1") == "1" else ["-cpu", "max"]
p("accel:", " ".join(accel))
qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "2048M", *accel, "-smp", "4",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-ZFS3",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
    "-serial", f"file:{SER}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def ser():
    try: return open(SER, "r", errors="replace").read()
    except FileNotFoundError: return ""


WHY = {
    60: "open of /mnt/zfs/agnostank/hello.txt failed", 61: "read did not return 'hello from zfs\\n'",
    62: "a second read at EOF did not return 0", 63: "lseek SEEK_SET on a ZFS fd failed",
    64: "read after lseek returned the wrong bytes", 65: "lseek SEEK_END did not land on the size",
    66: "stat failed", 67: "stat: not a regular file", 68: "stat: wrong size", 69: "stat: nlink is not 2 (hard link)",
    70: "lstat of a symlink did not report a symlink", 71: "stat through a symlink did not reach the file",
    72: "readlink returned the wrong target", 73: "open(AO_DIRECTORY) of dir3000 failed",
    74: "getdents did not list 3000 names + '.' + '..'", 75: "getdents' first record is not '.'",
    76: "readdir_at did not list 3000 names", 77: "readdir_at's cursor did not end at -1",
    78: "statfs failed", 79: "statfs bsize is not 4096 (ashift 12)", 80: "statfs numbers are inconsistent",
    81: "AO_CREAT was accepted on a read-only pool", 82: "AO_WRONLY was accepted", 83: "mkdir was accepted",
    84: "unlink was accepted", 85: "rename was accepted", 86: "mountlist has no backend-4 /mnt/zfs record",
    87: "big.bin did not stream to exactly 6 MiB", 88: "write(2) to a ZFS fd was accepted",
    89: "stat of a missing name succeeded", 90: "readdir_at returned a wrong or duplicated name",
}
rc = 2
try:
    s = None
    for _ in range(120):
        try:
            s = socket.socket(socket.AF_UNIX); s.connect(MON); break
        except OSError:
            time.sleep(0.25)
    if s is None:
        p("FAIL: no monitor"); sys.exit(2)
    s.settimeout(1.0)

    def drain():
        try:
            while True:
                if not s.recv(65536): break
        except Exception:
            pass
    km = {"\n": "ret", " ": "spc", "-": "minus", "/": "slash", ".": "dot"}

    def typ(t, settle=0.14):
        for ch in t:
            s.sendall(("sendkey " + km.get(ch, ch) + "\n").encode()); time.sleep(settle); drain()

    for _ in range(240):
        if "[ASSIST]" in ser(): break
        time.sleep(0.5)
    if "[ASSIST]" not in ser():
        p("INCONCLUSIVE: never reached the shell"); p(ser()[-1500:]); sys.exit(2)
    out0 = ser()
    p("booted to agnsh: True")
    for l in out0.splitlines():
        if re.search(r"zfs: (pool|mount|dataset)", l): p("  " + l.strip())
    if "zfs: pool agnostank" not in out0:
        p("FAIL: the kernel did not mount the pool"); rc = 1; sys.exit(1)
    typ("\n"); time.sleep(1.0)
    mark = len(ser())
    # agnsh runs an ABSOLUTE path only through its `run` builtin (agnoshi run_agnos.cyr: "absolute path → use the run builtin")
    typ("run /mnt/zfs/agnostank/payload/zfsx\n")
    code = None
    for _ in range(240):
        m = re.findall(r"run: exit (\d+)", ser()[mark:])
        if m: code = int(m[-1]); break
        time.sleep(0.25)
    out = ser()[mark:]
    p("zfsx exit code:", code if code is not None else "(never reported)")
    faulted = "fault: pid=" in out
    p("---- verdict ----")
    if faulted:
        p("FAIL: a fault occurred during the run"); rc = 1
    elif code is None:
        p("INCONCLUSIVE: zfsx never ran or never reported (exec from ZFS failed?)"); p(out[-1500:]); rc = 2
    elif code == 95:
        p("PASS: a ring-3 process exec'd from ZFS reads, seeks, stats, lists and statfs's /mnt/zfs, and every")
        p("      write verb is refused.")
        rc = 0
    else:
        p(f"FAIL: zfsx exit {code}: {WHY.get(code, 'unrecognised exit code')}"); rc = 1
finally:
    try: qemu.kill()
    except Exception: pass
p("serial:", SER)
sys.exit(rc)
