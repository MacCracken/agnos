# telemetry-test — are the 1.56.59 telemetry counters LIVE, or merely present? (chakshu §1/§2/§3/§4)
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

WORK   = os.path.join(ROOT, "build/telemetry")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-tlm.img")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-tlm.sock"
AGNOS  = os.path.join(ROOT, "build/agnos")
GNOBOOT= os.path.join(ROOT, "../gnoboot/build/BOOTX64.EFI")
TLM  = os.path.join(ROOT, "tests/telemetry/build/tlm")
DISK_MB, PART_OFFSET, PART_BLOCKS = 512, 34603008, 122880
EXT2_FEATURES = "^resize_inode,^dir_index,^ext_attr,^huge_file,^64bit,^metadata_csum"

def p(*a): print(*a, flush=True)
def sh(c): subprocess.run(c, shell=True, check=True)

for need in (AGNOS, GNOBOOT, ROOTFS, TLM):
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
subprocess.run(["cp", TLM, os.path.join(SEED, "bin", "tlm")])
subprocess.run(["chmod", "+x", os.path.join(SEED, "bin", "tlm")])

EXP_BIN = len(os.listdir(os.path.join(SEED, "bin")))
p(f"seed: /bin/tlm <- {TLM} ({os.path.getsize(TLM)} bytes)")
p(f"seed: /bin has {EXP_BIN} entries (rdat pages it 5 at a time)")

sh(f"dd if=/dev/zero of={IMG} bs=1M count={DISK_MB} status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100%")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-TLM -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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
    "-device", "nvme,drive=disk0,serial=AGNOS-TLM",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
    # ⛔ A NIC IS REQUIRED, AND ITS ABSENCE IS WHY THE FIRST RUN OF THIS GATE FAILED AT §1. Without
    # `-netdev` the kernel reports `r8169: no controller found`, no virtio-net binds, `nic_send`
    # correctly returns -1 and nothing is counted — a CORRECT kernel scoring a FAIL. The gate was
    # right to be red; the harness was wrong. virtio-net-pci is what every other net smoke in this
    # tree uses, and SLIRP always answers the gateway, so icmp_echo has a reliable target.
    "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0",
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
    typ("tlm\n")
    time.sleep(20.0)
    out = ser()[mark:]

    m = re.findall(r"run: exit (\d+)", out)
    code = int(m[-1]) if m else None
    p("tlm exit code:", code if code is not None else "(never reported)")
    WHY = {
        80: "proclist(#99) returned no processes",
        81: "our own pid is absent from the process table",
        82: "our pid vanished from the table between two samples",
        83: "§4 per-process CPU ticks went BACKWARDS — something resets them; unusable as a rate",
        84: "§4 per-process CPU ticks NEVER MOVED — the counter is declared but dead",
        85: "§1/§2 a net_config counter field (8-11) is not implemented",
        86: "§1 tx packet counter went BACKWARDS",
        87: "§2 tx byte counter went BACKWARDS",
        88: "§1 tx packet counter NEVER MOVED under real traffic — declared but dead",
        89: "§2 tx BYTES did not outpace tx PACKETS — the byte counter is wired to the packet increment",
        90: "§3 no block device reports ANY sector read — the disk counters are dead",
        91: "§3 sectors-read went BACKWARDS",
        92: "§3 an out-of-range tag or unknown field was ACCEPTED instead of refused",
    }
    faulted = "fault: pid=" in out
    p("kernel/userland fault:", faulted)
    p("---- verdict ----")
    if faulted:
        p("FAIL: a fault occurred during the run"); rc = 1
    elif code is None:
        p("INCONCLUSIVE: mlist never ran or never reported"); p(out[-1200:]); rc = 2
    elif code == 95:
        p("PASS: every 1.56.59 telemetry counter is LIVE and MONOTONIC under real load —")
        p("      §4 per-process CPU ticks advanced, §1/§2 network packets+bytes advanced on real")
        p("      wire traffic (and bytes outpaced packets), §3 per-device disk sectors are counted")
        p("      and out-of-range tags refused. None of this is provable by reading a counter once:")
        p("      a declared-but-never-incremented variable reads 0, which looks like a valid answer.")
        rc = 0
    else:
        p(f"FAIL: {WHY.get(code, 'unrecognised exit code')}"); rc = 1
finally:
    try: qemu.kill()
    except Exception: pass
p("serial:", SER)
sys.exit(rc)
