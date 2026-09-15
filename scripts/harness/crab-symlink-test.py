#!/usr/bin/env python3
# crab-symlink-test — DOES DELETING A LINK KILL THE LINK, OR WHAT IT POINTS AT?
#
# ⛔⛔ THIS HARNESS EXISTS BECAUSE THE ADR CLAIMED SOMETHING THE CODE DID NOT DO. crab 0.9.3's
# ADR 0004 states *"delete and move PRESERVE them… `unlink` removes the LINK, never its target"*.
# The single-entry delete verb read `if (ddir != 0)` on the type byte and handed anything non-zero to
# `crab_walk_begin(CRAB_OP_DTREE, …)`, which type-checks NOTHING — it takes the name, builds a path,
# and the walk readdirs it. So a symlink pointing at a DIRECTORY became the ROOT OF A RECURSIVE
# DELETE and the walk enumerated the TARGET's contents: files crab was never pointed at and the
# operator never saw.
#
# ⚠ OLDER THAN THE SYMLINK WORK, and that is why it needs iron rather than a suite. Before the type
# byte had a third value `crab_stat_one` called `stat`, which FOLLOWS a link — so a link to a
# directory was already stored as type 1 and already took this branch. Making links visible did not
# open the hole; it made it findable.
#
# ⛔ AND NO HOST TEST CAN REACH ANY OF IT. `crab_stat_one`, `crab_readdir_into` and the whole delete
# verb are inside `#ifdef CYRIUS_TARGET_AGNOS` with no `#else`. The suite gates `crab_delete_plan`,
# which is the DECISION; this gates the CONSEQUENCE, on a real ext2 symlink, with the image read back
# afterwards by `debugfs` rather than by asking crab whether crab did the right thing.
#
# Oracles:
#     `crab: prompt <text>`        what the operator was ASKED — must say LINK, must not say FOLDER
#     `crab: open <name> -> <msg>` Enter on a link is not silent (it descended and refused before)
#     `crab: delete <name> -> ok`  the link went
#     debugfs, after shutdown:     /bin/zztarget and its three files are STILL THERE
#
#     CRAB_BIN=... AE_BIN=... python3 scripts/harness/crab-symlink-test.py
# Exit: 0 PASS · 1 FAIL · 2 INCONCLUSIVE
import os, re, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/crab-symlink")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-crabln.img")
PART   = os.path.join(WORK, "part.ext2")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-crabln.sock"
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
TDIR, TLINK, KEEP = "zztarget", "zzlink", ["keep1.txt", "keep2.txt", "keep3.txt"]

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

# ⭐ A REAL ext2 SYMLINK, NOT A SIMULATION. `mkfs.ext2 -d` carries a host symlink into the image as a
# genuine ext2 symlink, so what crab lstats on the target is the real thing.
tdir = os.path.join(SEED, "bin", TDIR)
os.makedirs(tdir, exist_ok=True)
for k in KEEP:
    open(os.path.join(tdir, k), "w").write("this file must survive deleting the link\n")
lp = os.path.join(SEED, "bin", TLINK)
if os.path.lexists(lp): os.unlink(lp)
os.symlink(TDIR, lp)                       # relative, pointing at the sibling DIRECTORY
p(f"seed: /bin/{TLINK} -> {TDIR}/ holding {len(KEEP)} files")

sh(f"dd if=/dev/zero of={IMG} bs=1M count={DISK_MB} status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100%")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-CRABLN_ -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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

    # ⛔ DO NOT COUNT KEYPRESSES — HOME ON THE ANSWER. A first run pressed Down 80 times at a 0.06 s
    # settle to "clamp at the bottom", and landed on `whirl`: keys are lost between the compositor's
    # per-frame drains, so N presses are not N rows and a blind count silently aims at the wrong file
    # — then deletes it. The prompt NAMES the entry, so the harness asks where it is instead of
    # assuming: press `d`, read the name, cancel, step, repeat. It cannot delete the wrong thing
    # because it only proceeds once the prompt says the right one.
    def prompt_now():
        mk = len(ser())
        key("d 400", 1.4)
        time.sleep(0.8)
        got = re.findall(r"crab: prompt (.*)", ser()[mk:])
        return got[-1] if got else None

    pt = None
    for hop in range(26):
        pt = prompt_now()
        if pt is None:
            unmeasured.append("ARM 1: no `crab: prompt` line at all — the prompt text is unmeasured")
            break
        if TLINK in pt:
            p(f"ARM 1: homed onto {TLINK} after {hop} steps")
            break
        key("n 400", 0.9)                  # cancel — never confirm a prompt naming the wrong entry
        for _ in range(4):
            key("down 300", 0.35)
        pt = None
    p("ARM 1: prompt:", repr(pt))

    # ========================================================================================
    # ARM 1 — WHAT DOES THE PROMPT SAY IT IS ABOUT TO DELETE?
    # ========================================================================================
    m1 = len(ser())
    if True:
        if pt is None:
            if not unmeasured:
                unmeasured.append(f"ARM 1: never reached {TLINK} in 26 hops — unmeasured")
        else:
            if "LINK" not in pt:
                fails.append(f"ARM 1: the prompt for a symlink never says LINK: {pt!r}")
            else:
                p("        ⭐ the prompt calls it a LINK")
            if "FOLDER" in pt:
                fails.append(f"ARM 1: ⛔ the prompt calls a symlink a FOLDER and offers to delete "
                             f"everything in it: {pt!r}")
            else:
                p("        ⭐ and never a FOLDER")
    cm = len(ser())
    key("n 400", 1.2)                  # cancel — ARM 2 needs the link still there
    time.sleep(1.0)
    p("ARM 1: cancelled:", "crab: delete cancelled" in ser()[cm:])

    # ========================================================================================
    # ARM 2 — ENTER ON A LINK IS NOT SILENT
    # ========================================================================================
    # It used to reach `crab_descend`, which refuses anything whose type byte is not 1, and the site
    # dropped the -1 with no else arm — so the key did nothing and SAID nothing, which the operator
    # cannot tell from a keypress crab never received.
    m2 = len(ser())
    key("ret 400", 1.5)
    time.sleep(1.5)
    seg2 = ser()[m2:]
    opened = re.findall(r"crab: open (\S+) -> (.*)", seg2)
    cds = re.findall(r"crab: cd (\S+)", seg2)
    p("ARM 2: `crab: open` lines:", opened, "| cd lines:", cds)
    if opened: p("        ⭐ Enter on a link answers out loud")
    elif cds:  fails.append(f"ARM 2: Enter DESCENDED INTO a link — crab followed it as a directory: {cds}")
    else:      fails.append("ARM 2: Enter on a link was silent — the key did nothing and said nothing")

    # ========================================================================================
    # ARM 3 — ⛔⛔ THE ONE THAT MATTERS: DELETE THE LINK, AND READ THE DISK
    # ========================================================================================
    m3 = len(ser())
    key("d 400", 1.5)
    key("y 400", 2.0)
    time.sleep(4.0)
    seg3 = ser()[m3:]
    dels = re.findall(r"crab: delete (\S+) -> (.*)", seg3)
    p("ARM 3: `crab: delete` lines:", dels)
    if not dels:
        unmeasured.append("ARM 3: the delete never reported — survival is still checked below")
    elif dels[-1][0] != TLINK:
        unmeasured.append(f"ARM 3: crab deleted {dels[-1][0]!r}, not the link — unmeasured")
    elif "ok" not in dels[-1][1].lower() and "done" not in dels[-1][1].lower():
        # ⛔ Before the fix a link went to `rmdir`, which refuses a non-directory: links were
        # UNDELETABLE. A refusal here is that defect, not a safe outcome.
        fails.append(f"ARM 3: the link could not be deleted at all: {dels[-1][1]!r}")
    else:
        p("        ⭐ the link was deleted")

    faulted = any(x in ser() for x in ("PAGE FAULT", "GENERAL PROTECTION")) or "panic" in ser().lower()
    p("ARM 3: faults:", faulted)
    if faulted: fails.append("ARM 3: the kernel faulted")

    try: s.sendall(b"quit\n")
    except Exception: pass
    try: qemu.wait(timeout=20)
    except Exception: qemu.kill(); time.sleep(2)

    # ---- the disk, read back. Not crab's opinion of what crab did. ----
    time.sleep(1.0)
    tls = ext2_ls(f"/bin/{TDIR}")
    bls = ext2_ls("/bin")
    survived = [k for k in KEEP if k in tls]
    p("")
    p(f"ARM 3: debugfs /bin/{TDIR} -> {len(survived)}/{len(KEEP)} files survived:", survived)
    p(f"ARM 3: /bin/{TLINK} still on disk:", TLINK in bls)
    p(f"ARM 3: /bin/{TDIR} still on disk:", TDIR in bls)
    if len(survived) != len(KEEP):
        fails.append(f"⛔⛔ ARM 3: DELETING THE LINK DESTROYED THE TARGET'S CONTENTS — only "
                     f"{len(survived)}/{len(KEEP)} of {KEEP} survived. This is data loss.")
    if TDIR not in bls:
        fails.append(f"⛔⛔ ARM 3: DELETING THE LINK DELETED THE TARGET DIRECTORY {TDIR} ITSELF.")
    if dels and dels[-1][0] == TLINK and TLINK in bls:
        fails.append(f"ARM 3: crab reported deleting {TLINK} but it is still on disk")

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
