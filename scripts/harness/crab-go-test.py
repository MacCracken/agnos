#!/usr/bin/env python3
# crab-go-test — DOES `Go` NAVIGATE, AND DOES AN OPEN MENU STOP `d` FROM DELETING UNDERNEATH IT?
#
# ⭐⭐ `Go` SAT ON THE BAR AND EMPTY SINCE 0.8.0 — the canvas draws it and crab had no honest way to
# fill it. crab 0.9.2 fills it with the sidebar's destinations, picked through one navigator
# (`synth_goto`) rather than a second implementation of navigation. The suite gates the model, the
# height cap and the key contract; this gates the wire.
#
# ⛔⛔ ARM 2 IS THE ONE THAT MATTERS. The roadmap recorded *"`d` is not consumed by the drop arm — so
# the delete prompt would draw UNDERNEATH the menu"*, and reading the arm it was worse: it handled
# six keys and let **every other key through with `u` intact**, so `c`, `m`, `r`, `n`, Backspace and
# Space all acted under a popup painted over them. The delete case defeats `crab_del_prompt`'s whole
# reason for existing — *"THE PROMPT NAMES WHAT DIES"*, written after five system binaries left an
# iron box. A prompt drawn under an opaque menu names what dies to nobody.
#
# ⚠ DRIVEN BY THE KEYBOARD, DELIBERATELY. 0.9.1 spent seven runs failing to aim a pointer at a rect:
# the monitor moves a RELATIVE mouse in screen coordinates and homing is unreliable. `F10` → Right →
# Enter is the same shape `crab-columns-test.py` already drives successfully.
#
# Oracles:
#     `crab: menu bar`      F10 revealed the bar
#     `crab: place <path>`  a destination was picked and the pane was sent there
#     `crab: cd <path>`     ...and the listing followed
#
#     CRAB_BIN=... AE_BIN=... python3 scripts/harness/crab-go-test.py
# Exit: 0 PASS · 1 FAIL · 2 INCONCLUSIVE
import os, re, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/crab-go")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-crabgo.img")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-crabgo.sock"
QMP    = "/tmp/agnos-crabgo-qmp.sock"
AGNOS  = os.path.join(ROOT, "build/agnos")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _freshness import refuse_stale_kernel
refuse_stale_kernel(ROOT)
GNOBOOT= os.path.join(ROOT, "../gnoboot/build/BOOTX64.EFI")
CRAB   = os.environ.get("CRAB_BIN", os.path.join(ROOT, "../crab/build/crab_agnos"))
AE_BIN = os.environ.get("AE_BIN", os.path.join(ROOT, "../aethersafha/build/aethersafha_agnos"))
DISK_MB, PART_OFFSET, PART_BLOCKS = 512, 34603008, 122880
EXT2_FEATURES = "^resize_inode,^dir_index,^ext_attr,^huge_file,^64bit,^metadata_csum"

def p(*a): print(*a, flush=True)
def sh(c): subprocess.run(c, shell=True, check=True)

for need in (AGNOS, GNOBOOT, ROOTFS, CRAB, AE_BIN):
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
subprocess.run(["cp", CRAB, os.path.join(SEED, "bin", "crab")])
subprocess.run(["chmod", "+x", os.path.join(SEED, "bin", "crab")])
p("seed: /bin/crab <-", CRAB, f"({os.path.getsize(CRAB)} bytes)")
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
sh(f"mkfs.ext2 -F -q -L AGNOS-CRABGO_ -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
if OVMF_VARS:
    subprocess.run(["cp", OVMF_VARS, os.path.join(WORK, "vars.fd")])
    subprocess.run(["chmod", "+w", os.path.join(WORK, "vars.fd")])
open(SER, "w").close()
for _sk in (MON, QMP):
    try: os.unlink(_sk)
    except FileNotFoundError: pass

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "2048M", "-cpu", "max", "-smp", "4",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-CRB",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0", "-device", "usb-mouse,bus=xhci.0",
    "-serial", f"file:{SER}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
    "-qmp", f"unix:{QMP},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def ser():
    try: return open(SER, "r", errors="replace").read()
    except FileNotFoundError: return ""

COMMIT = re.compile(r"crab: edit commit (.*?) -> ")

def commits(text):
    """Every name crab committed, in order. The capture is non-greedy to the ` -> ` so a name
    containing spaces survives; an EMPTY field yields '' and is reported as such rather than lost."""
    return COMMIT.findall(text)

rc = 2
fails = []
unmeasured = []
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
    # compositor's per-frame drains leave only the release to be seen. Four QEMU runs taught the
    # pointer harness this; it is not rediscovered here.
    def key(name, wait=0.7):
        s.sendall(("sendkey " + name + "\n").encode()); time.sleep(wait); drain()
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
        p("INCONCLUSIVE: no shell prompt"); qemu.terminate(); sys.exit(2)
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
    probes = 0
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
        if got == "crab":
            launched = True; break
        if got == "probe":
            probes += 1
            p(f"  launch attempt {attempt+1}: the DOWN was lost — the probe launched instead; retrying")
        else:
            p(f"  launch attempt {attempt+1}: nothing presented — retrying")
    p("crab launched and presented:", launched, "| stray probe windows:", probes)
    if not launched:
        p("INCONCLUSIVE: crab never presented")
        try: s.sendall(b"quit\n")
        except Exception: pass
        qemu.terminate(); sys.exit(2)

    # ============================================================================================
    # ARM 1 — `Go` OPENS AND NAVIGATES
    # ============================================================================================
    # F10 reveals the bar on File; Right twice reaches Go (File, Edit, Go); Enter opens the drop onto
    # its first destination; Enter again picks it.
    gmark = len(ser())
    opened = False
    for _ in range(4):
        key("f10 400", 1.2)
        if "crab: menu bar" in ser()[gmark:]: opened = True; break
    p("ARM 1: F10 revealed the bar:", opened)
    if not opened:
        p("INCONCLUSIVE: the bar never opened — Go is unmeasured")
        try: s.sendall(b"quit\n")
        except Exception: pass
        qemu.terminate(); sys.exit(2)
    key("right 400", 1.0)
    key("right 400", 1.0)
    key("ret 400", 1.2)
    key("ret 400", 1.5)
    time.sleep(2.0)
    seg = ser()[gmark:]
    # ⚠ `crab: place <path> ok <n> entries` is the oracle — NOT `crab: cd`, which comes from
    # descend/ascend. A goto re-lists in place; it does not log a cd. A first draft asserted `cd` and
    # failed a working pick, which is the harness measuring the wrong line.
    places = re.findall(r"crab: place (\S+) ok (\d+) entries", seg)
    refused = re.findall(r"crab: place (\S+) refused", seg)
    p("ARM 1: `crab: place ... ok` lines:", places, "| refused:", refused)
    if not places:
        # ⚠ A REFUSAL IS A RESULT, NOT A FAILURE. On a model with more destinations than the window
        # has rows, `Go` is refused OUT LOUD and names the sidebar — that is the designed behaviour.
        if "menu" in seg and "wider" in seg:
            p("        (Go was refused for fit — that is the designed answer, not a defect)")
            unmeasured.append("ARM 1: Go was refused for fit on this model — navigation unmeasured")
        else:
            fails.append("ARM 1: Go opened but picked no destination — no `crab: place` line")
    else:
        dest, nent = places[-1]
        p(f"        ⭐ Go sent the pane to {dest} and it listed {nent} entries")
        if refused:
            fails.append(f"ARM 1: a destination was refused: {refused}")

    # ============================================================================================
    # ARM 2 — AN OPEN MENU EATS `d`, SO NO DELETE PROMPT DRAWS UNDERNEATH IT
    # ============================================================================================
    dmark = len(ser())
    bar2 = False
    for _ in range(4):
        key("f10 400", 1.2)
        if "crab: menu bar" in ser()[dmark:]: bar2 = True; break
    if not bar2:
        unmeasured.append("ARM 2: the bar would not reopen — the d-gate is unmeasured")
    else:
        key("ret 400", 1.2)            # open File's drop
        emark = len(ser())
        for _ in range(3):
            key("d 400", 1.0)          # the key that used to raise a delete prompt UNDER the menu
        time.sleep(2.0)
        seg2 = ser()[emark:]
        # crab's delete prompt goes to the status line as a notice; its serial tell is the confirm arm.
        deleted = ("crab: delete" in seg2) or ("delete this" in seg2.lower())
        p("ARM 2: `d` x3 with a drop-down open -> any delete activity:", deleted)
        if deleted:
            fails.append("ARM 2: `d` reached the delete arm with a menu open — the prompt draws underneath it")
        else:
            p("        ⭐ eaten — nothing acted beneath the popup")
        key("esc 400", 1.0)
        key("esc 400", 1.0)

    # ============================================================================================
    # ARM 3 — NO FAULTS
    # ============================================================================================
    log = ser()
    faulted = ("PAGE FAULT" in log) or ("GENERAL PROTECTION" in log) or ("panic" in log.lower())
    p("ARM 3: faults:", faulted)
    if faulted: fails.append("ARM 3: the kernel faulted")

    p("")
    p("==== verdict ====")
    for f in fails: p("  FAIL:", f)
    for u in unmeasured: p("  UNMEASURED:", u)
    if fails: rc = 1
    elif unmeasured: rc = 2
    else: rc = 0
    p({0: "PASS", 1: "FAIL", 2: "INCONCLUSIVE"}[rc])
    try: s.sendall(b"quit\n")
    except Exception: pass
finally:
    try: qemu.terminate(); qemu.wait(timeout=10)
    except Exception:
        try: qemu.kill()
        except Exception: pass
sys.exit(rc)
