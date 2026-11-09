#!/usr/bin/env python3
# crab-longname-test — DOES A DELETE AIMED AT A LONG NAME REMOVE THAT FILE?
#
# ⛔⛔ `readdir#81` and `readdir_at#101` cut a name at 62 bytes and say nothing
# (docs/development/issues/archived/2026-11-08-readdir-cuts-a-long-name-and-says-nothing.md). Through crab 0.11.3 a row
# held the cut name, so a delete aimed at a 70-byte file removed a sibling named its first 62 bytes and left
# the file. crab 0.11.4 lists through `getdents#29` and acts on the whole name. This fails on 0.11.3.
#
# ⚠ THE ORACLE IS THE DISK, NOT crab. The image is read back with `debugfs` after shutdown: asking crab
# whether crab deleted the right thing is not evidence.
#
# /bin/zzlong holds a 70-byte name, a sibling named its first 62 bytes, two names sharing their first 100
# bytes, and short.txt. Descend, delete the second row, then delete the second of the pair.
#
#     CRAB_BIN=... AE_BIN=... python3 scripts/harness/crab-longname-test.py
# Exit: 0 PASS · 1 FAIL · 2 INCONCLUSIVE
import os, re, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _qsock import qsock
from _siblings import sibling
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/crab-longn")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-crablong.img")
PART   = os.path.join(WORK, "part.ext2")
SER    = os.path.join(WORK, "serial.log")
MON    = qsock(os.path.join(WORK, "agnos-crablong.sock"))  # 1.57.14: short + per-tree (_qsock.py)
AGNOS  = os.path.join(ROOT, "build/agnos")

from _freshness import refuse_stale_kernel
refuse_stale_kernel(ROOT)
GNOBOOT= os.path.join(sibling("gnoboot", "GNOBOOT_ROOT"), "build/BOOTX64.EFI")
CRAB   = os.environ.get("CRAB_BIN") or os.path.join(sibling("crab", "CRAB_ROOT"), "build/crab_agnos")
AE_BIN = os.environ.get("AE_BIN") or os.path.join(sibling("aethersafha", "AE_ROOT"), "build/aethersafha_agnos")
DISK_MB, PART_OFFSET, PART_BLOCKS = 512, 34603008, 122880
EXT2_FEATURES = "^resize_inode,^dir_index,^ext_attr,^huge_file,^64bit,^metadata_csum"

# ⚠ NAMED `zz*` ON PURPOSE. crab sorts directories first, then files, each by name — so `zztarget`
# is the ONLY directory in /bin and lands at index 0, and `zzlink` sorts last among 48 files and
# lands at the bottom. "Down more times than there are rows" therefore reaches the link without the
# harness needing to know the count, and crab clamps at the last row rather than running off it.
# ⚠ `zz*` so the folder sorts to the BOTTOM of its listing — except that it is the only DIRECTORY
# in /bin, and crab sorts directories FIRST, so it lands at index 0 and needs no arrow keys at all.

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

Z = os.path.join(SEED, "bin", "zzlong")
os.makedirs(Z, exist_ok=True)
A70, A62, B1, B2 = "a" * 70, "a" * 62, "b" * 100 + "-one", "b" * 100 + "-two"
def wf(n, c): open(os.path.join(Z, n), "w").write(c)
wf(A70, "LONG-70"); wf(A62, "SIBLING-62"); wf(B1, "B-ONE"); wf(B2, "B-TWO"); wf("short.txt", "SHORT")

sh(f"dd if=/dev/zero of={IMG} bs=1M count={DISK_MB} status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100%")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-CRABLNG -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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
            key("ctrl-f3", 0.5)
        time.sleep(2.0)
        themed = ser()[kmark:].count("theme switched")
        p(f"key-delivery probe {probe+1}: Ctrl+F3 x10 ->", themed, "theme switches")
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
            key("ctrl-f2 400", 0.8)
            if "launcher opened" in ser()[lmark:]: break
        if "launcher opened" not in ser()[lmark:]:
            p(f"  launch attempt {attempt+1}: Ctrl+F2 never opened the launcher — retrying"); continue
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


    time.sleep(2.0)
    def wait_for(needle, start, secs):
        for _ in range(int(secs * 4)):
            if needle in ser()[start:]: return True
            time.sleep(0.25)
        return False

    m0 = len(ser())
    key("ret 400", 1.0)
    seen = wait_for("entries in /bin/zzlong", m0, 20)
    line = re.search(r"crab: listed (\d+) entries in /bin/zzlong", ser()[m0:])
    p("descended into /bin/zzlong:", seen, "rows:", line.group(1) if line else "?")
    if not seen: unmeasured.append("crab never listed the fixture")
    time.sleep(1.5)

    # ARM 1: the second row is the 70-byte name; its 62-byte sibling sorts first.
    key("down 300", 0.9)
    m1 = len(ser())
    key("d 400", 0.9)
    key("y 400", 1.5)
    time.sleep(2.0)
    d1 = re.search(r"crab: delete (\S+)", ser()[m1:])
    p("ARM 1: crab deleted a name of length:", len(d1.group(1)) if d1 else "?")

    # ARM 2: from the top, row 2 is the second of two names sharing their first 100 bytes.
    for _ in range(6): key("up 300", 0.5)
    key("down 300", 0.8)
    key("down 300", 0.8)
    m2 = len(ser())
    key("d 400", 0.9)
    key("y 400", 1.5)
    time.sleep(2.0)
    d2 = re.search(r"crab: delete (\S+)", ser()[m2:])
    p("ARM 2: crab deleted a name of length:", len(d2.group(1)) if d2 else "?")

    faulted = "kernel fault" in ser().lower() or "#PF" in ser()
    p("faults:", faulted)
    if faulted: fails.append("the kernel faulted")
    try: s.sendall(b"quit\n")
    except Exception: pass
    try: qemu.wait(timeout=20)
    except Exception: qemu.kill(); time.sleep(2)
    time.sleep(1.0)
    o = ext2_ls("/bin/zzlong")
    names = set(o.split())
    for label, n in (("the 62-byte sibling", A62), ("the 70-byte name", A70), ("b...-one", B1), ("b...-two", B2), ("short.txt", "short.txt")):
        p(f"disk: {label} present:", n in names)
    if A62 not in names: fails.append("ARM 1: the delete aimed at the 70-byte name removed its sibling")
    if A70 in names: fails.append("ARM 1: the 70-byte name is still on disk")
    if B1 not in names: fails.append("ARM 2: the wrong name of the pair was removed")
    if B2 in names: fails.append("ARM 2: the -two name is still on disk")
    if "short.txt" not in names: fails.append("short.txt went missing")
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
