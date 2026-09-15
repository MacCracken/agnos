#!/usr/bin/env python3
# crab-drop-test — CAN A DROP STILL MOVE A FILE WHILE A DELETE PROMPT IS ON SCREEN?
#
# ⛔⛔ THE DATA-LOSS PATH 0.9.6 CLOSES, DRIVEN END TO END. The release arm was gated on the LEFT
# BUTTON AND NOTHING ELSE — neither `crab_pointer_blocked` nor `crab_pointer_modal` was asked, though
# the click has asked since 0.8.0 and the wheel since 0.8.5. And nothing gates the KEY dispatch on
# drag state either. So:
#   press a row and hold -> move 4 px (dragging = 1) -> press `d`, which opens the delete prompt for
#   the SELECTED entry -> release. The drop MOVES a file, RELISTS BOTH PANES, clears every mark and
#   CLAMPS both selections. The `y` that follows answers a question about an entry that is no longer
#   there: THE PROMPT NAMED ONE THING AND THE DELETE TAKES ANOTHER.
#
# ⛔ NO HOST TEST CAN REACH IT. The whole release arm is inside main.cyr's `#ifdef
# CYRIUS_TARGET_AGNOS` with no `#else`. The suite drives the DECISION (`crab_drop_ok`) exhaustively;
# only iron shows the loop asking it.
#
# ⚠ THE AIM DOES NOT MATTER FOR ARM 1, AND THAT IS DELIBERATE. `crab_drop_ok` asks `blocked` BEFORE
# it asks the target, so a blocked drop reports the QUESTION whatever the pointer is over — which is
# itself the contract (an operator with a prompt on screen must not be told "dropped nowhere").
#
# Oracles — new in 0.9.6:
#     `crab: drop refused 2`   CRAB_DROP_BLOCKED — a question outranked the drag
#     `crab: drop refused 3`   CRAB_DROP_MOVED   — the source listing changed under it
#     `crab: drag-move <name>` the drop PROCEEDED and moved something
#
# ⚠ ARM 1 IS THE ONE THAT CONVERGES. Its retry loop re-presses in the same directory, so a missed
# press can be retried. ARM 2 ascends as part of its own scenario, so every retry starts from a
# different listing — it reliably shows that NOTHING MOVED, and does not reliably reach the name
# check. That half is proven in the suite instead, by mutation.
#
#     CRAB_BIN=... AE_BIN=... python3 scripts/harness/crab-drop-test.py
# Exit: 0 PASS · 1 FAIL · 2 INCONCLUSIVE
import os, re, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/crab-drop")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-crabdrop.img")
PART   = os.path.join(WORK, "part.ext2")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-crabdrop.sock"
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
# ⚠ `zz*` so they sort to the BOTTOM of /bin's 48 files, and DIFFERENT sizes so a wrong answer is
# not merely stale but demonstrably the OTHER file's.


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
subprocess.run(["cp", AE_BIN, os.path.join(SEED, "bin", "aethersafha")])
subprocess.run(["chmod", "+x", os.path.join(SEED, "bin", "aethersafha")])

sh(f"dd if=/dev/zero of={IMG} bs=1M count={DISK_MB} status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100%")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-CRABDROP_ -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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

    

    def mon(cmd, wait=0.25):
        s.sendall((cmd + "\n").encode()); time.sleep(wait); drain()

    def mon(cmd, wait=0.25):
        s.sendall((cmd + "\n").encode()); time.sleep(wait); drain()

    # ⛔ THE PIN NEEDS ITS OWN FRAME (-4000, 0.8 s) — see crab-button-test.py's note; a -2000 home
    # with 0.3 s settles finds nothing and invites a false conclusion.
    pmark = len(ser())
    spot = None
    mon("mouse_move -4000 -4000", 0.8)
    for gx in (200, 100, 300):
        for gy in (130, 80, 180, 220):
            mon("mouse_move -4000 -4000", 0.8)
            mon(f"mouse_move {gx} {gy}", 0.8)
            mon("mouse_button 1", 0.20)
            mon("mouse_button 0", 0.25)
            time.sleep(0.6)
            if "crab: click" in ser()[pmark:]:
                spot = (gx, gy); break
        if spot: break
    p("left click resolved to a pane at:", spot)
    if spot is None:
        p("INCONCLUSIVE: no left click reached crab — the drop arms have nothing to stand on")
        try: s.sendall(b"quit\n")
        except Exception: pass
        qemu.terminate(); sys.exit(2)

    # ========================================================================================
    # ARM 1 — ⛔⛔ A DROP WHILE A DELETE PROMPT IS UP
    # ========================================================================================
    # ⛔ RETRIED, BECAUSE THE AIM IS FLAKY AND THE BEHAVIOUR IS NOT. A relative pointer cannot be
    # landed on a chosen pixel and the compositor places crab where it likes, so a press may miss a
    # row entirely — one run produced a full trace and the next produced no `crab: click` at all,
    # from identical code. The drag either arms or it does not; retry until it does, and report
    # UNMEASURED only if every attempt missed. This is the wall crab-door-test.py closed ARM 1 on.
    def drag_probe(mid_key, cross):
        """press-hold, arm the drag, press a key mid-drag, cross the window, release.
        -> (verdicts, drag-move names, the crab lines seen)"""
        for _ in range(2):
            key("esc 400", 0.6)
        time.sleep(0.4)
        mon("mouse_move -4000 -4000", 0.8)
        mon(f"mouse_move {spot[0]} {spot[1]}", 0.8)
        mk = len(ser())
        mon("mouse_button 1", 0.40)               # press and HOLD
        # ⛔ TWO MOVES, NOT ONE, AND GENEROUSLY. `crab_drag_started` needs only 4 px, but the
        # promotion happens in the POINTER_MOVE arm — so it needs a motion EVENT to be delivered
        # while the button is down, and aethersafha dedupes motion. A single 20 px nudge armed the
        # drag on some runs and not others from identical code; two larger moves make the delivery
        # the likely case rather than the lucky one.
        mon("mouse_move 40 0", 0.7)
        mon("mouse_move 40 0", 0.7)               # past CRAB_DRAG_THRESHOLD -> dragging = 1
        if mid_key:
            key(mid_key + " 400", 1.4)
        mon(f"mouse_move {cross} 0", 0.8)
        mon("mouse_button 0", 0.8)
        time.sleep(1.4)
        seg = ser()[mk:]
        return (re.findall(r"crab: drop refused (\d+)", seg),
                re.findall(r"crab: drag-move (\S+)", seg),
                [l for l in seg.splitlines() if l.startswith("crab:")])

    refused = []; moved = []; lines1 = []
    for attempt in range(5):
        refused, moved, lines1 = drag_probe("d", 120)
        if refused or moved: break
        p(f"  ARM 1 attempt {attempt+1}: the press missed a row — retrying")
        key("n 400", 0.8)
    p("ARM 1: drop verdicts:", refused or "-", "| drag-move lines:", moved or "-")
    p("ARM 1: crab lines seen:", lines1[-8:])
    if moved:
        fails.append(f"⛔⛔ ARM 1: THE DROP MOVED A FILE WITH A DELETE PROMPT ON SCREEN: {moved} — "
                     f"the prompt now names an entry that is no longer selected. This is the "
                     f"data-loss path 0.9.6 exists to close.")
    elif "2" in refused:
        p("        ⭐ refused with CRAB_DROP_BLOCKED — the question outranked the drag")
    elif refused:
        unmeasured.append(f"ARM 1: refused for reason {refused}, not 2 (BLOCKED)")
    else:
        unmeasured.append("ARM 1: no verdict line in 5 attempts — the press never landed on a row")
    key("n 400", 1.0)
    time.sleep(0.5)

    # ========================================================================================
    # ARM 2 — ⛔ THE SOURCE LISTING CHANGES UNDER THE DRAG
    # ========================================================================================
    # Backspace ascends the pane being dragged FROM while the button is still down, so `drag_row`
    # indexes a directory the operator never dragged from.
    # ⛔ THE DROP MUST LAND IN THE **OTHER** PANE, or `crab_drag_targets` refuses first and the name
    # check is never reached. A run that nudged +150 px from a spot already in the right half stayed
    # in the same pane and reported CRAB_DROP_NONE — a refusal, but not the one this arm is for.
    refused2 = []; moved2 = []; lines2 = []
    for attempt in range(4):
        refused2, moved2, lines2 = drag_probe("backspace", -(spot[0] - 60))
        if refused2 or moved2: break
        p(f"  ARM 2 attempt {attempt+1}: the press missed a row — retrying")
    p("ARM 2: drop verdicts:", refused2 or "-", "| drag-move lines:", moved2 or "-")
    p("ARM 2: crab lines seen:", lines2[-8:])
    if moved2:
        fails.append(f"⛔⛆ ARM 2: THE DROP MOVED {moved2} AFTER THE SOURCE PANE WAS RE-LISTED — the "
                     f"row index named a file in a directory the operator never dragged from.")
    elif "3" in refused2:
        p("        ⭐ refused with CRAB_DROP_MOVED — the name no longer matched the row")
    elif refused2:
        # ⚠ RECORDED HONESTLY. A refusal for another reason still proves the OUTCOME — nothing moved
        # after the source listing changed — but not that the NAME CHECK was what caught it. The
        # suite proves that exhaustively (drop the name check and the assertion goes red).
        p(f"        (refused for reason {refused2}: nothing moved, but an earlier gate caught it)")
        unmeasured.append(f"ARM 2: refused for reason {refused2}, not 3 — the NAME check is unproven "
                          f"on iron here; the suite proves it")
    else:
        # ⚠ AND RETRYING CANNOT FIX THIS ONE, WHICH IS WORTH SAYING RATHER THAN HIDING. ARM 2's own
        # action is to ASCEND the source pane, so every attempt starts from a DIFFERENT directory
        # with a different number of rows — the spot the sweep found may be below the last row of
        # `/`. Unlike ARM 1, the retry loop does not converge. ⇒ The OUTCOME is what matters and is
        # covered: nothing moved in any attempt. The name check itself is proven exhaustively in the
        # suite, where dropping it turns the assertion red.
        unmeasured.append("ARM 2: no verdict line — its own Backspace re-lists the pane, so each "
                          "retry starts from a different layout and the loop does not converge. "
                          "Nothing moved; the NAME check is proven in the suite, not here.")

    faulted = any(x in ser() for x in ("PAGE FAULT", "GENERAL PROTECTION")) or "panic" in ser().lower()
    p("faults:", faulted)
    if faulted: fails.append("the kernel faulted")

    p("")
    p("==== verdict ====")
    for f in fails: p("  FAIL:", f)
    for u in unmeasured: p("  UNMEASURED:", u)
    rc = 1 if fails else (2 if unmeasured else 0)
    p({0: "PASS", 1: "FAIL", 2: "INCONCLUSIVE"}[rc])
    try: s.sendall(b"quit\n")
    except Exception: pass
finally:
    try: qemu.terminate(); qemu.wait(timeout=10)
    except Exception:
        try: qemu.kill()
        except Exception: pass
sys.exit(rc)
