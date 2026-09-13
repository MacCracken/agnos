#!/usr/bin/env python3
# crab-shift-test — CAN crab WRITE A NAME CONTAINING A CAPITAL LETTER, AND ARE `#` AND `*` TYPEABLE?
#
# ⭐⭐ WHAT THIS EXISTS TO PROVE, AND WHY THE SUITE CANNOT. crab 0.8.9 added a Shift latch:
# `crab_shift_track` folds the raw press/release edge of usages 0xE1/0xE5 into a two-bit mask, and
# the rename/new-folder field asks `crab_shift_held()` instead of passing a hard-coded 0. The suite
# gates the latch's LOGIC exhaustively — the two-key sequence a boolean gets wrong, the stray release
# that must not borrow, the whole shifted number row, and both batch-rename operators pinned to
# `crab_batch_name` itself. What it cannot gate is the two things that only exist on the wire:
#
#   1. ⛔⛔ **THE ORDERING.** In `src/main.cyr` the latch is fed the RAW edge, three lines BEFORE
#      `crab_key_is_modifier` zeroes a modifier's `kacts` so its press cannot answer a delete prompt.
#      Track first, suppress second. Get that backwards and every Shift PRESS arrives at the latch
#      looking like a RELEASE, the latch never sets, and **the suite stays completely green** — every
#      line of that ordering is inside `#ifdef CYRIUS_TARGET_AGNOS` with no `#else`, and nothing
#      includes `main.cyr`. This harness is the only thing that can tell the two orders apart.
#   2. ⚠ **THAT A SHIFT EDGE ARRIVES AT ALL, AND IN THE RIGHT ORDER.** bhumi maps the boot report's
#      modifier byte to usages 0xE0..0xE7. A boot report is a STATE — modifier byte plus up to six
#      keycodes — so "shift down AND 'a' down" can arrive as one report, and whether the modifier
#      event is emitted BEFORE the letter is a claim about bhumi that crab has never tested.
#
# ⭐ THE ORACLE IS ONE LINE, AND 0.8.9 PUT THE NAME IN IT. `crab: edit commit <name> -> <status>`
# previously printed only the status, which says a rename happened and not what it was renamed to.
# ⚠ The success word is `done`, not `ok` (`crab_fs_msg(CRAB_FS_OK)` returns "done") — which is why
# this harness matches the NAME with a non-greedy capture up to ` -> ` and never matches the status.
# An earlier draft of this header said `-> ok`; the regex was already right and the comment was not.
# ⛔ `n` (New folder) is used rather than `r` (Rename) deliberately: `crab_edit_start` PREFILLS a
# rename with the current name and puts the caret at the end, so the line would carry the old name
# plus the typed suffix and the assertion would have to know what crab was pointing at. New folder
# starts empty, so the line carries EXACTLY what was typed and nothing else.
#
#     CRAB_BIN=/path/to/crab_agnos AE_BIN=/path/to/aethersafha_agnos python3 scripts/harness/crab-shift-test.py
# Exit: 0 PASS · 1 FAIL (a measured arm gave the wrong answer) · 2 INCONCLUSIVE (delivery failed)
import os, re, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/crab-shift")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-crabshift.img")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-crabshift.sock"
QMP    = "/tmp/agnos-crabshift-qmp.sock"
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
sh(f"mkfs.ext2 -F -q -L AGNOS-CRABSHF -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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

    # ⚠ A SHIFT EDGE MUST REACH crab BEFORE ANY OF THIS MEANS ANYTHING. `crab: key received` counts
    # every KEY event the wire delivered, gated on nothing — so a shift press that never arrives is
    # a count that did not move, rather than an absence that could be anything.
    smark = ser().count("crab: key received")
    for _ in range(4):
        key("shift 400", 0.8)
    time.sleep(1.5)
    shift_events = ser().count("crab: key received") - smark
    p("shift edges delivered to crab (press+release each):", shift_events)
    if shift_events == 0:
        p("INCONCLUSIVE: no shift edge reached crab — bhumi may not emit the modifier byte")
        try: s.sendall(b"quit\n")
        except Exception: pass
        qemu.terminate(); sys.exit(2)

    # ============================================================================================
    # ARM 1 — A CAPITAL LETTER REACHES A NAME, AND `#` AND `*` ARE TYPEABLE
    # ============================================================================================
    # ⛔⛔ THE ORDERING ARM. If `crab_shift_track` ran AFTER `crab_key_is_modifier` zeroed the
    # modifier's edge, every Shift press would look like a release, the latch would never set, and
    # this line would come back all lower case with the suite still green.
    # ⭐ AND THE SAME LINE CLOSES THE OTHER RECORDED GAP: `#` is Shift+3 and `*` is Shift+8, the two
    # operators the batch-rename sheet advertises and its own field could not produce.
    def newfolder(keys, label):
        """Press `n` until the sheet REPORTS itself open, send `keys`, commit, return the committed name.

        ⛔⛆ THE RETRY MUST BE GATED ON crab SAYING SO, AND THE FIRST RUN OF THIS HARNESS IS WHY. The
        sheet announced nothing until it committed, so this loop pressed `n` up to four times blind —
        and every press that lands while the sheet is ALREADY open types a literal 'n' INTO THE NAME.
        It measured `nnnAB#*`, which is a correct latch reported as a failure by a broken harness.
        crab 0.8.9 prints `crab: edit open <label>`; the retry now reads it."""
        before = len(ser())
        opened = False
        for _try in range(5):
            key("n 400", 1.0)
            time.sleep(0.4)
            if "crab: edit open" in ser()[before:]:
                opened = True; break
            p(f"    (`n` did not open the sheet — retry {_try+1})")
        if not opened:
            p(f"  {label}: the sheet never opened")
            return None
        for k in keys:
            key(k + " 400", 0.6)
        key("ret 400", 1.2)
        time.sleep(1.5)
        names = commits(ser()[before:])
        p(f"  {label}: commits seen={names}")
        if not names: return None
        return names[-1]

    got = newfolder(["shift-a", "shift-b", "shift-3", "shift-8"], "ARM 1 Shift+A Shift+B Shift+3 Shift+8")
    if got is None:
        unmeasured.append("ARM 1: no `crab: edit commit` line — the sheet or Enter never landed")
    else:
        p("ARM 1: crab committed the name:", repr(got))
        if got == "AB#*":
            p("        ⭐ exactly AB#* — latch, ordering, and both batch operators, in one line")
        else:
            if not any(c.isupper() for c in got):
                fails.append(f"ARM 1: no capital letter in {got!r} — the Shift latch never set "
                             f"(check the track/suppress ORDER in src/main.cyr)")
            if "#" not in got:
                fails.append(f"ARM 1: '#' (Shift+3) is not in {got!r} — the batch SEQUENCE operator is still untypeable")
            if "*" not in got:
                fails.append(f"ARM 1: '*' (Shift+8) is not in {got!r} — the batch ORIGINAL-NAME operator is still untypeable")
            if got == "ab38":
                fails.append("ARM 1: the letters arrived unshifted — the latch is dead, not merely mis-mapped")

    # ============================================================================================
    # ARM 2 — THE RELEASE WORKS: SHIFTED THEN UNSHIFTED IN ONE NAME
    # ============================================================================================
    # ⚠ A latch that sets and never clears passes ARM 1 and is still broken: every name after the
    # first Shift would be shouted. This is the arm that says the RELEASE edge arrives and is folded.
    got2 = newfolder(["shift-a", "b", "c"], "ARM 2 Shift+A then b c")
    if got2 is None:
        unmeasured.append("ARM 2: no commit line")
    else:
        p("ARM 2: crab committed the name:", repr(got2))
        if got2 == "Abc":
            p("        ⭐ exactly Abc — the press latched and the release cleared")
        else:
            if got2 == "ABC":
                fails.append("ARM 2: 'ABC' — the latch SET but never CLEARED; a lost or unfolded release")
            elif got2 == "abc":
                fails.append("ARM 2: 'abc' — the latch never set at all")
            else:
                fails.append(f"ARM 2: expected 'Abc', got {got2!r}")

    # ============================================================================================
    # ARM 3 — A SHIFT EDGE IS NOT A KEYSTROKE
    # ============================================================================================
    # ⛔ 0.8.7's rule, re-measured because 0.8.9 now READS the same edge. A modifier is STATE to the
    # latch and must remain INERT to every dispatch gate — `crab: key press` counts what crab acted
    # on, and holding Shift in the main table must not move it. If this regresses, a Shift press
    # would answer a pending delete prompt, which is the exact bug `crab_key_is_modifier` was added
    # for and the one place where getting it wrong destroys a file.
    pmark = ser().count("crab: key press")
    rmark = ser().count("crab: key received")
    for _ in range(5):
        key("shift 400", 0.7)
    time.sleep(1.5)
    acted = ser().count("crab: key press") - pmark
    arrived = ser().count("crab: key received") - rmark
    p("ARM 3: shift edges arrived:", arrived, "| crab acted on:", acted)
    if arrived == 0:
        unmeasured.append("ARM 3: no shift edge arrived — inertness unmeasured")
    elif acted != 0:
        fails.append(f"ARM 3: crab ACTED on {acted} shift edge(s) — a modifier is state, not a keystroke")

    # ============================================================================================
    # ARM 4 — NO FAULTS
    # ============================================================================================
    log = ser()
    faulted = ("PAGE FAULT" in log) or ("GENERAL PROTECTION" in log) or ("panic" in log.lower())
    p("ARM 4: faults:", faulted)
    if faulted: fails.append("ARM 4: the kernel faulted")

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
