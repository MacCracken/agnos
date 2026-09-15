#!/usr/bin/env python3
# crab-face-test — DOES crab ACTUALLY DRAW IN THE KERNEL'S PROPORTIONAL FACE ON THE TARGET?
#
# ⭐⭐ WHAT THIS EXISTS TO PROVE, AND WHY NOTHING ELSE COULD. crab 0.9.0 opens `/fonts/default.ttf` —
# the kernel-owned namespace agnos 1.57.2 added (`kernel/core/kfont.cyr`): Liberation Sans Regular
# 2.1.5, 410,820 bytes, embedded kashi-style and FNV-1a-64 verified at boot. **That path exists on no
# host.** crab's suite can therefore only prove the REFUSAL path, and it says so at the assertion.
#
# ⛔⛔ AND THE FAILURE THIS GATES IS SILENT BY CONSTRUCTION — which is the whole reason the harness
# exists rather than a code review. The only prior art in the stack
# (`dhancha/programs/setu_demo_client.cyr`) reads a HOST path behind `if (flen > 0)`. That guard is
# correct code. Copied into crab it would: work on the host build, fall back to the bitmap face on the
# target that ships, and **look finished**. A green suite and a clean build would both agree with it.
#
# Oracles — crab's own serial lines, printed once, before the first frame:
#     `crab: font /fonts/default.ttf <n> bytes adv=<a> upem=<u>`   the face loaded AND is measuring
#     `crab: font none -- <why>`                                   it did not, and says which step
#
# ⚠ `adv` IS THE HALF THAT MATTERS AS MUCH AS THE BYTE COUNT. A face that loads but whose advance
# comes back 9 would be indistinguishable from the bitmap font in the only way crab cares about —
# every column width is `chars * crab_char_w()`, and `crab_char_w` asks the face about `n` at em 16.
# The byte count says the file arrived whole; the advance says it is really driving the layout.
#
#     CRAB_BIN=/path/to/crab_agnos AE_BIN=/path/to/aethersafha_agnos python3 scripts/harness/crab-face-test.py
# Exit: 0 PASS · 1 FAIL (a measured arm gave the wrong answer) · 2 INCONCLUSIVE (delivery failed)
import os, re, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/crab-face")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-crabface.img")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-crabface.sock"
QMP    = "/tmp/agnos-crabface-qmp.sock"
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
sh(f"mkfs.ext2 -F -q -L AGNOS-CRABFCE -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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
    # ARM 1 — THE FACE LOADED, AND IT IS THE ONE agnos SHIPS
    # ============================================================================================
    log = ser()
    line = None
    for ln in log.split("\n"):
        if ln.startswith("crab: font "):
            line = ln.strip(); break
    p("ARM 1: crab's font line:", repr(line))
    if line is None:
        fails.append("ARM 1: crab printed no `crab: font` line at all — the loader never ran")
    elif line.startswith("crab: font none"):
        fails.append(f"ARM 1: crab fell back to the bitmap face — {line!r}")
    else:
        m = re.search(r"crab: font (\S+) (\d+) bytes adv=(\d+) upem=(\d+) i=(\d+) m=(\d+)", line)
        if not m:
            fails.append(f"ARM 1: the font line did not parse — {line!r}")
        else:
            path, nbytes, adv, upem = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))
            wi, wm = int(m.group(5)), int(m.group(6))
            p(f"        path={path} bytes={nbytes} adv={adv} upem={upem} i={wi} m={wm}")
            if path != "/fonts/default.ttf":
                fails.append(f"ARM 1: crab opened {path}, not the stable contract /fonts/default.ttf")
            # ⛔ THE EXACT SIZE agnos DOCUMENTS. A short read would still parse if it happened to cut
            # on a table boundary, and would then be a face missing glyphs — so the count is asserted,
            # not merely logged.
            if nbytes != 410820:
                fails.append(f"ARM 1: read {nbytes} bytes, not the 410,820 agnos documents — a partial read")
            if upem <= 0:
                fails.append("ARM 1: unitsPerEm is 0 — rekha opened it but the head table is not there")
            # ⛔ THE ADVANCE IS THE ONE THAT SAYS THE FACE IS DRIVING LAYOUT. 0 would mean no hmtx
            # metric reached crab and every width would fall back to the bitmap 9.
            if adv <= 0:
                fails.append("ARM 1: the advance is 0 — crab_char_w would fall back to kashi's 9")
            else:
                p(f"        crab is measuring in the kernel's face: 'n' advances {adv} px at em 16")
            # ⛔⛆ THE ARM THAT SURVIVES A COINCIDENCE. Liberation Sans's 'n' at em 16 rounds to 9 —
            # kashi's bitmap advance exactly — so `adv` alone cannot distinguish "the face loaded"
            # from "the face never loaded". 'i' and 'm' are the narrowest and widest lowercase
            # letters; a monospace face gives them the same advance and a proportional one cannot.
            if wi <= 0 or wm <= 0:
                fails.append(f"ARM 1: i={wi} m={wm} — a glyph reported no advance at all")
            elif wi == wm:
                fails.append(f"ARM 1: 'i' and 'm' both advance {wi} px — that is a MONOSPACE answer; "
                             f"the face did not reach the measurement")
            else:
                p(f"        ⭐⭐ PROPORTIONAL, PROVED: 'i' is {wi} px and 'm' is {wm} px — "
                  f"a monospace face cannot produce that")

    # ============================================================================================
    # ARM 2 — IT LOADED ONCE, NOT PER FRAME
    # ============================================================================================
    # ⛔ `crab_face` is called at all eight render sites. Unmemoised it would open and re-parse a
    # 410 KB file on EVERY frame, from a bump allocator with no `free()` — the session would exhaust
    # the heap. One line in the whole log is the proof that the memo holds.
    nfont = len([x for x in log.split("\n") if x.startswith("crab: font ")])
    p("ARM 2: `crab: font` lines in the whole session:", nfont)
    if nfont > 1:
        fails.append(f"ARM 2: the face was loaded {nfont} times — `crab_face` is not memoised")

    # ============================================================================================
    # ARM 3 — crab STILL WORKS IN IT: navigate, switch views, open a sheet
    # ============================================================================================
    # ⚠ A face that loads and then breaks the app is worse than no face. These are the surfaces whose
    # widths all moved when the advance stopped being 9: the listing, the grid, and a text field.
    amark = len(ser())
    for _ in range(3):
        key("backspace 400", 1.0)
    key("g 400", 1.2)
    key("g 400", 1.2)
    key("b 400", 1.0)
    time.sleep(2.0)
    seg = ser()[amark:]
    nav = seg.count("crab: cd ")
    views = seg.count("crab: view ")
    p("ARM 3: navigations:", nav, "| view changes:", views)
    if nav == 0 and views == 0:
        unmeasured.append("ARM 3: no key reached crab — the in-face interaction is unmeasured")
    elif views == 0:
        fails.append("ARM 3: crab navigated but `g` produced no view change under the face")

    # ============================================================================================
    # ARM 4 — NO FAULTS, AND NO ALLOCATOR DEATH
    # ============================================================================================
    # ⛔ THE ARM dhancha 0.10.0 MADE PASSABLE. Before it, every label allocated a full-surface canvas
    # per frame from a bump allocator with no `free()`; a few hundred frames in a face would have
    # exhausted the heap. crab's suite proves a warm frame costs zero on the host; this proves the
    # session survives on the target.
    log = ser()
    faulted = ("PAGE FAULT" in log) or ("GENERAL PROTECTION" in log) or ("panic" in log.lower())
    oom = ("alloc" in log.lower() and "fail" in log.lower())
    p("ARM 4: faults:", faulted, "| allocator failure text:", oom)
    if faulted: fails.append("ARM 4: the kernel faulted")
    if oom: fails.append("ARM 4: an allocation failure appeared in the log")

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
