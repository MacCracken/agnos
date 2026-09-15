#!/usr/bin/env python3
# crab-button-test — WHICH BUTTONS REACH CRAB, AND DOES MIDDLE MARK THE ROW UNDER IT?
#
# ⛔⛔ A MEASUREMENT, NOT A FEATURE TEST — AND IT IS THE PRECONDITION FOR 0.9.5. The roadmap asks crab
# to "use the middle button". Every repo in the chain CLAIMS it is carried: agnos captures the full
# HID bitmap (bit0 left, bit1 right, bit2 middle — kernel/arch/x86_64/usb/hid.cyr:311), aethersafha
# 0.16.24 forwards bits 0..2 as `wire = kernel_bit + 1` so 1=left 2=right 3=middle
# (src/input.cyr:302-314, "Filed by crab"), setu carries `button` opaque, dhancha hands it to the app.
# ⚠ NONE OF THAT HAS BEEN EXERCISED FOR THE MIDDLE BUTTON. crab-pointer-test proved button 2 (right)
# arrives; button 3 has never been observed anywhere in this stack. Designing a binding on a button
# that does not arrive would be building on a claim about five repos.
#
# ⚠ QEMU's HMP `mouse_button` takes a BITMASK and its own docs say `1=L, 2=R, 4=M`
# (/usr/share/doc/qemu/qemu/system/monitor.html). The harness still presses each mask and reports
# what crab SAW rather than trusting that — but the expectation is documented, not a guess. MEASURED
# 2026-09-14: mask 1 -> wire 1, mask 2 -> wire 2 (right), mask 4 -> wire 3 (MIDDLE). Mask 8 is inert
# (QEMU's legacy WHEELUP) and is kept only as a negative control.
#
# Oracle — new in crab 0.9.5, and it exists because absence was ambiguous before:
#     `crab: press btn <n> no action`   a press reached crab carrying button <n>, and no surface took it
#     `crab: click` / `crab: context menu opened by pointer`   a surface DID take it (1 and 2)
#
#     CRAB_BIN=... AE_BIN=... python3 scripts/harness/crab-button-test.py
# Exit: 0 PASS (a mask maps to button 3) · 1 FAIL · 2 INCONCLUSIVE
import os, re, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/crab-buttons")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-crabbtn.img")
PART   = os.path.join(WORK, "part.ext2")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-crabbtn.sock"
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
sh(f"mkfs.ext2 -F -q -L AGNOS-CRABBTN_ -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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

    # ⛔⛆ THE AIMING IS COPIED FROM crab-pointer-test.py, NOT REINVENTED — a first draft of this
    # harness used a -2000 home and 0.3 s settles and found NOTHING, which is the same wall
    # crab-door-test.py hit. Two facts, both learned there the expensive way:
    #   1. THE PIN NEEDS ITS OWN FRAME. The kernel ACCUMULATES deltas between drains and the
    #      compositor clamps the NET move, so a pin (-4000) and a walk (+200) folded into one drain
    #      land the cursor at (0,0) — crab's titlebar — and the press finds no client content.
    #   2. SETTLE AFTER MOTION. A press sent before the motion's frame has run is resolved at the OLD
    #      position. 0.8 s outlasts a slow TCG frame.
    # ⚠ The compositor creates every client at (0,0) and crab asks for 380x220, so the grid stays
    # inside the top-left of the screen.
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
        p("INCONCLUSIVE: no left click reached crab — the button comparison has nothing to stand on")
        try: s.sendall(b"quit\n")
        except Exception: pass
        qemu.terminate(); sys.exit(2)

    # ---- press each single-bit mask and record the button number crab reports -------------------
    BTNNAME = {1: "left", 2: "right", 3: "middle"}
    results = {}
    # ⛔⛆ MIDDLE FIRST, AND THE ORDER IS THE WHOLE TEST. aethersafha's own diagnostic is ONE-SHOT —
    # `ae_btnx_first` guards `"aethersafha: forwarded a non-left button press, wire number: N"`
    # (src/main.cyr:653-658) — so whichever non-left button arrives FIRST is the only one it ever
    # names. A first run pressed right before middle, spent the one-shot on wire 2, and could not
    # tell "middle was dropped" from "middle was forwarded silently".
    # ⇒ Press mask 4 before mask 2. If the compositor says wire number 3, it forwarded middle and any
    # loss is downstream of it; if it says 2, middle never reached the forwarding loop.
    for mask in (4, 1, 2, 8):
        mon("mouse_move -4000 -4000", 0.8)
        mon(f"mouse_move {spot[0]} {spot[1]}", 0.8)
        mk = len(ser())
        mon(f"mouse_button {mask}", 0.30)
        mon("mouse_button 0", 0.60)
        time.sleep(0.8)
        seg = ser()[mk:]
        nums = [int(m) for m in re.findall(r"crab: press btn (\d+) no action", seg)]
        took = []
        if "crab: click" in seg: took.append("click(left,pane)")
        if "crab: mark by middle click" in seg: took.append("mark(middle,pane)")
        if "context menu opened by pointer" in seg: took.append("context-menu(right)")
        if "popup dismissed by pointer" in seg: took.append("dismiss")
        if "bar click" in seg: took.append("bar")
        if "switcher click" in seg: took.append("switch")
        results[mask] = (nums, took)
        # ⛔⛆ DISMISS ANY POPUP THIS MASK OPENED, OR THE NEXT MASK IS DECIDED IN THE WRONG BRANCH.
        # A first run pressed right (mask 2), left the context menu up, and every later middle press
        # resolved to CRAB_PA_DISMISS instead of CRAB_PA_MARK — the harness measured crab correctly
        # and the SCENARIO was wrong. Esc twice: one for a drop-down, one for the menu.
        for _ in range(2):
            key("esc 400", 0.7)
        time.sleep(0.4)
        p(f"QEMU mask {mask:>2} -> crab reported button(s) {nums or '-'} ; surfaces that took it: {took or '-'}")

    # ---- what did we learn? --------------------------------------------------------------------
    # ========================================================================================
    # ARM 2 — ⭐ DOES A MIDDLE PRESS ON A PANE ACTUALLY MARK THE ROW? (0.9.5)
    # ========================================================================================
    # `crab: mark by middle click` is emitted by the CRAB_PA_MARK arm and by nothing else, so the
    # line appearing proves the press reached that arm — and the arm synthesises Space, so the mark
    # itself is the one `crab_mark_toggle` the keyboard already drives.
    for _ in range(2):
        key("esc 400", 0.7)
    time.sleep(0.5)
    mon("mouse_move -4000 -4000", 0.8)
    mon(f"mouse_move {spot[0]} {spot[1]}", 0.8)
    m2 = len(ser())
    mon("mouse_button 4", 0.30)
    mon("mouse_button 0", 0.60)
    time.sleep(0.8)
    seg2 = ser()[m2:]
    marked = "crab: mark by middle click" in seg2
    p("ARM 2: middle press on a pane -> `crab: mark by middle click`:", marked)
    if marked:
        p("        ⭐ middle reaches the MARK arm on a pane")
    else:
        fails.append("ARM 2: a middle press on a pane did not reach the mark arm")

    # ========================================================================================
    # ARM 3 — ⛔ MIDDLE MUST NOT FIRE A POPUP ROW (the X11-Delete guard)
    # ========================================================================================
    # X11 numbers buttons left/MIDDLE/right, so X11 muscle memory aims middle where crab's RIGHT
    # lives — and right opens a menu with `Delete` in it. A middle press on a popup row must run
    # nothing.
    mon("mouse_move -4000 -4000", 0.8)
    mon(f"mouse_move {spot[0]} {spot[1]}", 0.8)
    mon("mouse_button 2", 0.30)                 # right: open the context menu here
    mon("mouse_button 0", 0.60)
    time.sleep(1.0)
    m3 = len(ser())
    # the menu is anchored at the pointer; step a little way into it and middle-press
    mon("mouse_move 0 30", 0.8)
    mon("mouse_button 4", 0.30)
    mon("mouse_button 0", 0.60)
    time.sleep(1.0)
    seg3 = ser()[m3:]
    fired = ("crab: delete" in seg3) or ("crab: edit commit" in seg3) or ("crab: open " in seg3)
    p("ARM 3: middle inside the open popup fired a verb:", fired)
    if fired:
        fails.append(f"⛔⛔ ARM 3: A MIDDLE PRESS RAN A POPUP VERB — the X11-Delete hazard: {seg3[-200:]!r}")
    else:
        p("        ⭐ nothing fired — middle is refused where the thing under it is a verb")
    for _ in range(2):
        key("esc 400", 0.8)

    # ========================================================================================
    # ARM 4 — ⭐ DOES THE POPUP HIGHLIGHT FOLLOW THE POINTER? (0.9.5)
    # ========================================================================================
    # `crab: hover menu <n>` is emitted only when the highlight actually CHANGES — bounded by
    # crab_motion_redraw_due, not by the motion stream — so the lines are the moves themselves.
    # ⛔ AND THE FIRST ONE PROVES THE ARM, NOT JUST THE MOTION: the popup is placed AT the pointer and
    # may be FLIPPED above it, so a hover that engaged immediately would emit a line before the
    # pointer had travelled. The first press below opens the menu and moves nothing.
    for _ in range(2):
        key("esc 400", 0.7)
    time.sleep(0.5)
    mon("mouse_move -4000 -4000", 0.8)
    mon(f"mouse_move {spot[0]} {spot[1]}", 0.8)
    m4 = len(ser())
    mon("mouse_button 2", 0.30)                 # right: open the context menu at the pointer
    mon("mouse_button 0", 0.60)
    time.sleep(1.0)
    opened_seg = ser()[m4:]
    hov_at_open = re.findall(r"crab: hover (menu|drop) (\d+)", opened_seg)
    p("ARM 4: hover lines BEFORE the pointer moved:", hov_at_open or "none")
    if hov_at_open:
        fails.append(f"⛔ ARM 4: the highlight moved before the pointer did — the popup opens UNDER "
                     f"the cursor and crab_hover_armed should have refused: {hov_at_open}")
    else:
        p("        ⭐ nothing moved — the hover is not armed until the pointer travels")
    # ⛔⛆ SWEEP BOTH WAYS — `dh_place_at_point` FLIPS the popup ABOVE the anchor when it would
    # overhang the window, and at crab's shipped 380x220 a 7-row menu usually does. So the menu may
    # lie entirely ABOVE the cursor that opened it, and a purely downward sweep walks straight off
    # it. A run that swept down only measured 3 rows once and 0 the next time, from the same code —
    # the flake was the harness assuming one placement.
    m5 = len(ser())
    for step in range(6):
        mon("mouse_move 0 -22", 0.45)           # up, for a FLIPPED menu
    for step in range(12):
        mon("mouse_move 0 22", 0.45)            # and back down through it, for the unflipped case
    time.sleep(1.0)
    hov = re.findall(r"crab: hover (menu|drop) (\d+)", ser()[m5:])
    p("ARM 4: hover lines while sweeping down the menu:", hov)
    if not hov:
        unmeasured.append("ARM 4: the pointer swept the popup and no hover line appeared — either the "
                          "motion missed the popup rect or the hover is not wired")
    else:
        vals = [v for _, v in hov]
        if len(set(vals)) < 2:
            unmeasured.append(f"ARM 4: the highlight moved but never changed row twice: {hov}")
        else:
            p(f"        ⭐ the highlight followed the pointer across {len(set(vals))} distinct rows")
    for _ in range(2):
        key("esc 400", 0.8)

    # ---- what did the COMPOSITOR say? Its one-shot names the first non-left button it forwarded. ----
    ae_wire = re.findall(r"aethersafha: forwarded a non-left button press, wire number:\s*\n?(\d+)", ser())
    ae_nowin = "a non-left button press had NO client content under the cursor" in ser()
    p("")
    p("aethersafha one-shot — first non-left wire number forwarded:", ae_wire or "none")
    p("aethersafha — a non-left press landed outside any client:", ae_nowin)

    seen_nums = sorted({n for nums, _ in results.values() for n in nums})
    took_any = sorted({t for _, tk in results.values() for t in tk})
    p("")
    p("buttons crab OBSERVED (from 'no action' lines):", seen_nums or "none")
    p("surfaces that consumed a press:", took_any or "none")

    mid_mask = [m for m, (nums, tk) in results.items() if (3 in nums) or ("mark(middle,pane)" in tk)]
    if (not mid_mask) and marked:
        mid_mask = [4]          # ARM 2 observed the mark arm: middle reached crab
    if (not mid_mask) and ae_wire and ae_wire[0] == "3":
        p("⭐ THE COMPOSITOR FORWARDED WIRE 3 (middle). Any loss is between setu and crab, not in the")
        p("  kernel or aethersafha — which is the half of the chain crab owns.")
    if ae_wire and ae_wire[0] != "3":
        p(f"⚠ the one-shot named wire {ae_wire[0]}, not 3 — middle did not reach the forwarding loop first")
    if mid_mask:
        p(f"⭐ BUTTON 3 (middle) ARRIVES — QEMU mask {mid_mask[0]} maps to it. 0.9.5 can bind it.")
    else:
        # A press that IS taken by a surface emits no "no action" line, so absence is only
        # conclusive if at least one mask produced an unclaimed press to compare against.
        if seen_nums:
            fails.append(f"⛔ BUTTON 3 NEVER ARRIVED. Masks tried: {sorted(results)}; crab saw only "
                         f"{seen_nums}. Either QEMU's usb-mouse does not emit HID bit 2, or a repo in "
                         f"the chain drops it. 0.9.5's middle-button half is BLOCKED until this is "
                         f"traced — do not design a binding on a button that does not arrive.")
        else:
            # ⚠ NOT A GAP ANY MORE, AND THE CHECK HAD TO LEARN THAT. Before 0.9.5 a middle press was
            # taken by no surface, so `crab: press btn 3 no action` was the only evidence it arrived.
            # Now every forwarded button IS consumed — left clicks, right opens the menu, middle
            # marks — so the ABSENCE of that line is the feature working. ARM 2 is the proof instead.
            p("  (no 'no action' line: every forwarded button is now consumed — see ARM 2)")

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
