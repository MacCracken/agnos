# readdir-at-test — does agnos's RESUMABLE readdir (#101, 1.56.50) actually resume?
#
# ⭐ THE GATE. `#81 readdir(path, buf, max)` always starts at the top of the directory and stops at
# `max`, so a directory with more entries than the caller's buffer is silently truncated. crab's
# `CRAB_MAX_ENTRIES = 256` is exactly that ceiling (crab roadmap *deferral #02*). `#101` adds a
# cursor — the byte offset into the directory file, POSIX `telldir`'s cookie — so the same directory
# can be read in batches.
#
# ⛔ THE ORACLE LIVES IN THE RING-3 PROGRAM, NOT HERE. `tests/readdir/rdat.cyr` compares the PAGED
# total against what `#81` reports in ONE call, which is the only comparison that catches both an
# omission and a duplicate. A harness that merely checked "it printed some entries" would pass for a
# walk that returned the first batch forever.
#
# ⚠ THE EXIT CODE IS THE RESULT (the blkprobe convention): 95 = the whole contract holds; 90-97
# pinpoint which clause broke. agnsh echoes `run: exit N`.
import os, re, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/readdir-at")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-rdat.img")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-rdat.sock"
AGNOS  = os.path.join(ROOT, "build/agnos")
GNOBOOT= os.path.join(ROOT, "../gnoboot/build/BOOTX64.EFI")
RDAT   = os.path.join(ROOT, "tests/readdir/build/rdat")
DISK_MB, PART_OFFSET, PART_BLOCKS = 512, 34603008, 122880
EXT2_FEATURES = "^resize_inode,^dir_index,^ext_attr,^huge_file,^64bit,^metadata_csum"

def p(*a): print(*a, flush=True)
def sh(c): subprocess.run(c, shell=True, check=True)

for need in (AGNOS, GNOBOOT, ROOTFS, RDAT):
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
subprocess.run(["cp", RDAT, os.path.join(SEED, "bin", "rdat")])
subprocess.run(["chmod", "+x", os.path.join(SEED, "bin", "rdat")])

# ⚠ `rdat` lists /bin, which now contains rdat itself. The count comes from the tree under test,
# not from a number typed here — but the ring-3 program derives its own expectation from #81, so the
# harness does not need to agree on a number at all.
EXP_BIN = len(os.listdir(os.path.join(SEED, "bin")))
p(f"seed: /bin/rdat <- {RDAT} ({os.path.getsize(RDAT)} bytes)")
p(f"seed: /bin has {EXP_BIN} entries (rdat pages it 5 at a time)")

sh(f"dd if=/dev/zero of={IMG} bs=1M count={DISK_MB} status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100%")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-RDAT -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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
    "-device", "nvme,drive=disk0,serial=AGNOS-RDT",
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
    typ("rdat\n")
    time.sleep(20.0)
    out = ser()[mark:]

    m = re.findall(r"run: exit (\d+)", out)
    code = int(m[-1]) if m else None
    p("rdat exit code:", code if code is not None else "(never reported)")
    WHY = {
        90: "no reference listing — #81 returned < 1 entry for /bin",
        91: "readdir_at returned an error mid-walk",
        92: "a batch returned MORE entries than its budget",
        93: "the cursor never reached -1 — the walk does not terminate",
        94: "the paged total does NOT equal the single-shot total (omission or duplicate)",
        96: "an exhausted cursor RESTARTED the directory instead of being a no-op",
        97: "a misaligned cursor was accepted instead of refused",
    }
    faulted = "fault: pid=" in out
    p("kernel/userland fault:", faulted)
    p("---- verdict ----")
    if faulted:
        p("FAIL: a fault occurred during the run"); rc = 1
    elif code is None:
        p("INCONCLUSIVE: rdat never ran or never reported"); p(out[-1200:]); rc = 2
    elif code == 95:
        p("PASS: #101 resumes — the paged walk sees exactly what one #81 call sees,")
        p("      the cursor terminates, an exhausted cursor is a no-op, and a misaligned one is refused.")
        rc = 0
    else:
        p(f"FAIL: {WHY.get(code, 'unrecognised exit code')}"); rc = 1
finally:
    try: qemu.kill()
    except Exception: pass
p("serial:", SER)
sys.exit(rc)
