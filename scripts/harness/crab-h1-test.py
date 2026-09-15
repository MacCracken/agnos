#!/usr/bin/env python3
# crab-h1-test — DOES CANCELLING A MERGE DELETE THE FOLDER IT MERGED INTO?
#
# ⛔⛔⛔ H1 — THE OLDEST CONFIRMED DATA-LOSS DEFECT IN THIS PROJECT, AND ITS OWN CODE PREDICTED IT.
# `crab_walk_reroot_dtree` turns a cancelled tree copy into a RECURSIVE DELETE of the destination
# root. Its comment spelled out the invariant that made that safe — `crab_walk_begin` refused an
# existing destination with EEXIST, so the root was ALWAYS one crab had just made — and then spelled
# out the consequence of losing it:
#     "If that guard in `crab_walk_begin` is ever relaxed to allow merging into an existing
#      destination, THIS FUNCTION BECOMES A DATA-LOSS BUG and must be deleted in the same change."
# 0.8.7 relaxed exactly that guard, to allow the most ordinary thing an operator does with two panes.
# The delete was not touched. ⇒ Cancelling a copy that MERGED into a folder the operator already had
# deleted that folder WHOLESALE, including every file crab never wrote.
#
# ⚠ THE ORACLE IS THE DISK, NOT crab. The image is read back with `debugfs` after shutdown: asking
# crab whether crab destroyed something is not evidence.
#
# The scenario is the ordinary one, which is what makes it serious:
#     /bin/zzkeep/   the SOURCE folder (big files, so the stepped copy takes several ticks)
#     /zzkeep/       a folder of the OPERATOR's OWN files, of the same name, in the other pane
#   select /bin/zzkeep -> `c` (copy to the other pane) -> it MERGES -> `Esc` to cancel.
#   Before 0.9.7 the cancel rerooted a DTREE onto /zzkeep and removed the operator's three files.
#
# Oracles:
#     `crab: transfer cancelled rc 23`   CRAB_FS_EMERGED — crab declined to delete and said so
#     debugfs, after shutdown:           /zzkeep and its three files are STILL THERE
#
#     CRAB_BIN=... AE_BIN=... python3 scripts/harness/crab-h1-test.py
# Exit: 0 PASS · 1 FAIL · 2 INCONCLUSIVE
import os, re, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/crab-h1")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-crabh1.img")
PART   = os.path.join(WORK, "part.ext2")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-crabh1.sock"
AGNOS  = os.path.join(ROOT, "build/agnos")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _freshness import refuse_stale_kernel
refuse_stale_kernel(ROOT)
GNOBOOT= os.path.join(ROOT, "../gnoboot/build/BOOTX64.EFI")
CRAB   = os.environ.get("CRAB_BIN", os.path.join(ROOT, "../crab/build/crab_agnos"))
AE_BIN = os.environ.get("AE_BIN", os.path.join(ROOT, "../aethersafha/build/aethersafha_agnos"))
DISK_MB, PART_OFFSET, PART_BLOCKS = 512, 34603008, 122880
EXT2_FEATURES = "^resize_inode,^dir_index,^ext_attr,^huge_file,^64bit,^metadata_csum"

# ⚠ NAMED `zz*` ON PURPOSE. crab sorts directories first, then files, each by name — so `zztarget`
# is the ONLY directory in /bin and lands at index 0, and `zzlink` sorts last among 48 files and
# lands at the bottom. "Down more times than there are rows" therefore reaches the link without the
# harness needing to know the count, and crab clamps at the last row rather than running off it.
# ⚠ `zz*` so the folder sorts to the BOTTOM of its listing — except that it is the only DIRECTORY
# in /bin, and crab sorts directories FIRST, so it lands at index 0 and needs no arrow keys at all.
MERGE_DIR = "zzkeep"
KEEP = ["keep1.txt", "keep2.txt", "keep3.txt"]      # the OPERATOR's files, in the destination
SRC_FILES = [f"src{i}.bin" for i in range(6)]        # big, so the copy is still running when Esc lands

def p(*a): print(*a, flush=True)
def sh(c): subprocess.run(c, shell=True, check=True)

for need in (AGNOS, GNOBOOT, ROOTFS, CRAB, AE_BIN):
    if not os.path.exists(need):
        p(f"FAIL: missing {need}"); sys.exit(1)
if not subprocess.run("command -v debugfs", shell=True, capture_output=True).stdout:
    p("SKIP: no debugfs — the survival check is the point of this harness"); sys.exit(2)

OVMF = None
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/OVMF/OVMF_CODE.fd"):
    if os.path.exists(c): OVMF = c; break
if OVMF is None: p("SKIP: no OVMF"); sys.exit(2)
OVMF_VARS = None
for c in ("/usr/share/edk2/x64/OVMF_VARS.4m.fd", "/usr/share/OVMF/OVMF_VARS.fd"):
    if os.path.exists(c): OVMF_VARS = c; break

subprocess.run(["rm", "-rf", WORK]); os.makedirs(WORK, exist_ok=True)
subprocess.run(["cp", "-a", ROOTFS, SEED])
subprocess.run(["cp", CRAB, os.path.join(SEED, "bin", "crab")])
subprocess.run(["chmod", "+x", os.path.join(SEED, "bin", "crab")])
subprocess.run(["cp", AE_BIN, os.path.join(SEED, "bin", "aethersafha")])
subprocess.run(["chmod", "+x", os.path.join(SEED, "bin", "aethersafha")])

# ⭐ THE SOURCE: /bin/zzkeep, the only DIRECTORY in /bin, so crab's left pane opens with it selected.
srcdir = os.path.join(SEED, "bin", MERGE_DIR)
os.makedirs(srcdir, exist_ok=True)
for nm in SRC_FILES:
    open(os.path.join(srcdir, nm), "wb").write(os.urandom(700000))
# ⭐ THE DESTINATION: /zzkeep, the same name, holding the OPERATOR's files. crab's RIGHT pane opens
# on "/", so `c` from the left pane merges into exactly this.
dstdir = os.path.join(SEED, MERGE_DIR)
os.makedirs(dstdir, exist_ok=True)
for nm in KEEP:
    open(os.path.join(dstdir, nm), "w").write("the operator put this here. crab never wrote it.\n")
p(f"seed: /bin/{MERGE_DIR}/ = {len(SRC_FILES)} x 700 KB (source)")
p(f"seed: /{MERGE_DIR}/     = {KEEP} (the operator's own files, in the destination)")

sh(f"dd if=/dev/zero of={IMG} bs=1M count={DISK_MB} status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100%")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-CRABH1_ -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
if OVMF_VARS:
    subprocess.run(["cp", OVMF_VARS, os.path.join(WORK, "vars.fd")])
    subprocess.run(["chmod", "+w", os.path.join(WORK, "vars.fd")])
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass

def ext2_ls(path):
    """Read the image back with debugfs — the survival oracle. Asking crab whether crab deleted the
    right thing is not evidence; reading the filesystem is."""
    sh(f"dd if={IMG} of={PART} bs=512 skip={PART_OFFSET // 512} count={PART_BLOCKS * 8} status=none")
    r = subprocess.run(["debugfs", "-R", f"ls -l {path}", PART], capture_output=True, text=True)
    return r.stdout + r.stderr

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "2048M", "-cpu", "max", "-smp", "4",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-CRB",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0", "-device", "usb-mouse,bus=xhci.0",
    "-serial", f"file:{SER}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def ser():
    try: return open(SER, "r", errors="replace").read()
    except FileNotFoundError: return ""

rc = 2
fails, unmeasured = [], []
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
    # ⛔ `sendkey <key> <hold_ms>`, ALWAYS — a press and its release landing between two of the
    # compositor's per-frame drains leave only the release to be seen.
    def key(name, wait=0.7):
        s.sendall(("sendkey " + name + "\n").encode()); time.sleep(wait); drain()
    km = {"\n": "ret", " ": "spc", "-": "minus", "/": "slash", ".": "dot"}
    def typ(t, settle=0.10):
        for ch in t:
            s.sendall(("sendkey " + km.get(ch, ch) + "\n").encode()); time.sleep(settle); drain()

    for _ in range(240):
        if "[ASSIST]" in ser(): break
        time.sleep(0.5)
    if "[ASSIST]" not in ser():
        p("INCONCLUSIVE: no shell prompt"); qemu.terminate(); sys.exit(2)
    p("booted to agnsh: True")
    time.sleep(2.0)
    key("ret", 1.0)
    typ("aethersafha\n")
    time.sleep(18.0)
    p("compositor up:", "aethersafha:" in ser())

    themed = 0
    for probe in range(4):
        kmark = len(ser())
        for _ in range(10):
            key("f3", 0.5)
        time.sleep(2.0)
        themed = ser()[kmark:].count("theme switched")
        p(f"key-delivery probe {probe+1}: F3 x10 ->", themed, "theme switches")
        if themed > 0: break
    if themed == 0:
        p("INCONCLUSIVE: no key reached the compositor in 4 probes")
        try: s.sendall(b"quit\n")
        except Exception: pass
        qemu.terminate(); sys.exit(2)

    launched = False
    for attempt in range(10):
        lmark = len(ser())
        for _ in range(6):
            key("f2 400", 0.8)
            if "launcher opened" in ser()[lmark:]: break
        if "launcher opened" not in ser()[lmark:]:
            p(f"  launch attempt {attempt+1}: F2 never opened the launcher — retrying"); continue
        dmark = len(ser())
        key("down 400", 0.8)
        key("ret 400", 0.8)
        got = None
        for _w in range(20):
            seg = ser()[dmark:]
            if "crab: dual-pane file-manager UI presented over setu" in seg: got = "crab"; break
            if "present_probe: surface established" in seg: got = "probe"; break
            time.sleep(0.5)
        if got == "crab": launched = True; break
        p(f"  launch attempt {attempt+1}: nothing presented — retrying")
    p("crab launched and presented:", launched)
    if not launched:
        p("INCONCLUSIVE: crab never presented")
        try: s.sendall(b"quit\n")
        except Exception: pass
        qemu.terminate(); sys.exit(2)


    # ⭐ NO AIMING AT ALL. crab's left pane opens on /bin and sorts directories first, so `zzkeep` —
    # the only directory there — is already selected. The whole scenario is two keys.
    time.sleep(2.0)
    m1 = len(ser())
    key("c 400", 0.8)                     # copy the selected folder to the OTHER pane -> a MERGE
    time.sleep(1.2)
    seg_start = ser()[m1:]
    started = ("copying" in seg_start) or ("crab: " in seg_start)
    p("ARM 1: `c` pressed; transfer started:", started)

    # ⛔ CANCEL WHILE IT IS STILL RUNNING. 6 x 700 KB through a stepped copy takes many idle ticks
    # under TCG; Esc after ~1.5 s lands mid-tree with directories already created and files written.
    key("esc 400", 1.0)
    time.sleep(3.0)
    seg1 = ser()[m1:]
    rcs = re.findall(r"crab: transfer cancelled rc (\d+)", seg1)
    cancelled = "transfer cancelled" in seg1
    p("ARM 1: cancel seen:", cancelled, "| rc:", rcs or "-")
    if "23" in rcs:
        p("        ⭐ rc 23 = CRAB_FS_EMERGED — crab declined to delete the merged root and said so")
    elif rcs:
        unmeasured.append(f"ARM 1: cancelled with rc {rcs}, not 23 — the copy may have finished "
                          f"before Esc landed, or it was not treated as a merge")
    elif not cancelled:
        unmeasured.append("ARM 1: no cancel line at all — the transfer may never have started")

    time.sleep(3.0)
    faulted = any(x in ser() for x in ("PAGE FAULT", "GENERAL PROTECTION")) or "panic" in ser().lower()
    p("ARM 1: faults:", faulted)
    if faulted: fails.append("the kernel faulted")

    try: s.sendall(b"quit\n")
    except Exception: pass
    try: qemu.wait(timeout=20)
    except Exception: qemu.kill(); time.sleep(2)

    # ---- ⛔⛔ THE DISK, READ BACK. This is the whole test. ----
    time.sleep(1.0)
    dls = ext2_ls("/" + MERGE_DIR)
    rootls = ext2_ls("/")
    survived = [k for k in KEEP if k in dls]
    p("")
    p(f"ARM 1: debugfs /{MERGE_DIR} -> {len(survived)}/{len(KEEP)} of the OPERATOR's files survived:", survived)
    p(f"ARM 1: /{MERGE_DIR} itself still on disk:", MERGE_DIR in rootls)
    if MERGE_DIR not in rootls:
        fails.append(f"⛔⛔⛔ H1: CANCELLING THE MERGE DELETED /{MERGE_DIR} ITSELF — a folder the "
                     f"operator made, that crab merged into. This is the data-loss defect.")
    if len(survived) != len(KEEP):
        fails.append(f"⛔⛔⛔ H1: CANCELLING THE MERGE DESTROYED THE OPERATOR'S FILES — only "
                     f"{len(survived)}/{len(KEEP)} of {KEEP} survived. crab deleted files it never "
                     f"wrote, in a folder it did not create.")
    else:
        p("        ⭐ every file the operator put there survived the cancel")

    p("")
    p("==== verdict ====")
    for f in fails: p("  FAIL:", f)
    for u in unmeasured: p("  UNMEASURED:", u)
    rc = 1 if fails else (2 if unmeasured else 0)
    p({0: "PASS", 1: "FAIL", 2: "INCONCLUSIVE"}[rc])
finally:
    try: qemu.terminate(); qemu.wait(timeout=10)
    except Exception:
        try: qemu.kill()
        except Exception: pass
sys.exit(rc)
