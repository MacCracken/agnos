#!/usr/bin/env python3
# crab-pointer-test — DOES A RIGHT-CLICK REACH CRAB AS A RIGHT-CLICK, AND DOES CRAB'S POPUP TAKE THE
# POINTER? Plus the REFRESH key, and the three keys the compositor claims before crab can see them.
#
# ⭐⭐ WHAT THIS EXISTS TO PROVE, AND WHY NOTHING ELSE COULD. crab 0.8.5 gave every surface a pointer
# route — a RIGHT press on a pane opens the context menu, a LEFT press on a popup row runs the entry,
# a press anywhere else dismisses — on aethersafha 0.16.24's button numbering (`wire = kernel bit + 1`,
# so right = 2). Every line of crab's arm is inside `#ifdef CYRIUS_TARGET_AGNOS`, and aethersafha's
# forwarding loop is inside its frame loop; both suites pin the DECISIONS and neither can reach the
# wire. Until this harness ran, "right-click works" was a claim about five repos that had never been
# exercised end to end (crab handoff.md, 0.8.5: "NOT run on QEMU or iron, on either side").
#
# ⛔ THE ORACLE IS crab's OWN SERIAL LINES, not pixels. A relative `usb-mouse` cannot land on a chosen
# pixel and the compositor places crab wherever it likes, so this harness sweeps for ANY click that
# crab resolves (the crab-resize-test approach), then right-clicks THERE. From that point the popup's
# geometry is known only up to `dh_place_at_point`'s flip/clamp, so the pick is a SEARCH over a few
# candidate offsets, and crab's three distinct lines tell the outcomes apart:
#     `crab: context menu opened by pointer`   the right press arrived as a RIGHT press
#     `crab: menu pick by pointer`             a left press landed on a popup ROW and ran it
#     `crab: popup dismissed by pointer`       a left press landed inside crab but off the popup
#     (nothing)                                 the press was outside crab's content — not forwarded
#
# ⛔⛔ AND IT GATES THE CHROME-KEY CONTRACT. Until aethersafha 0.16.25 `input_map` claimed bare Esc
# (QUIT), Tab (focus-next) and F4-F10 unforwarded — measured here in runs 2-5: crab's `Tab` sidebar
# route, its `F10` menu bar and every `Esc` were unreachable and Esc ended the desktop. 0.16.25 moved
# chrome onto Ctrl (Ctrl+Q / Ctrl+Tab / Ctrl+F4..F10) and forwards the bare keys; ARM 7 asserts both
# halves and sends Ctrl+Q LAST, because the expected answer is the compositor exiting.
#
# Oracles: crab prints `crab: key received` for every KEY event the wire delivered, so "crab did not
# see it" is a COUNT that stayed put, not an absence of a line that might have been lost.
#
#     CRAB_BIN=/path/to/crab_agnos AE_BIN=/path/to/aethersafha_agnos python3 scripts/harness/crab-pointer-test.py
# Exit: 0 PASS · 1 FAIL (a measured arm gave the wrong answer) · 2 INCONCLUSIVE (delivery failed)
import os, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/crab-pointer")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-crabpointer.img")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-crabpointer.sock"
QMP    = "/tmp/agnos-crabpointer-qmp.sock"
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

# ⛔ AE_BIN IS REQUIRED HERE, unlike crab-resize-test. The whole right-click chain depends on the
# compositor forwarding bit 1; an aethersafha older than 0.16.24 discards it silently and the failure
# would read as a crab bug. A missing AE_BIN is refused rather than tolerated.
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
sh(f"mkfs.ext2 -F -q -L AGNOS-CRABPTR -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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
    def key(name, wait=0.7):
        s.sendall(("sendkey " + name + "\n").encode()); time.sleep(wait); drain()
    def mon(cmd, wait=0.25):
        s.sendall((cmd + "\n").encode()); time.sleep(wait); drain()
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
    key("ret", 1.0)                               # the first keystroke of a session is swallowed
    typ("aethersafha\n")
    time.sleep(18.0)
    p("compositor up:", "aethersafha:" in ser())

    # key-delivery probe — F3 logs on every press (see crab-resize-test.py for the measurements)
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

    # F2 -> DOWN -> Enter launches /bin/crab (index 1; puka is index 0).
    # ⛔⛔ ONE ENTER, ONE DOWN, EACH HELD — AND THE OUTCOME READ, NOT ASSUMED. Three lessons from the
    # first two runs of this harness:
    #   · crab-resize-test's Enter x8 burst: the launcher eats the first Enter that arrives and every
    #     later one reaches crab as ITS Enter — descend-or-OPEN on the selected row. crab starts in
    #     /bin, whose first row is `aethersafha`, and Open SPAWNS it: run 1 put a SECOND compositor on
    #     the desktop and the pointer arms measured two compositors sharing one mouse.
    #   · a DOWN burst is a coin flip: the launcher WRAPS, so an even number of delivered DOWNs lands
    #     back on puka. Run 2 launched the present_probe first and crab second.
    #   · keys are lost because the boot-keyboard report is a STATE: a press and its release that both
    #     land between two of the compositor's per-frame drains leave only the release to be seen.
    #     `sendkey <key> <hold_ms>` keeps the press state up across several frames.
    # The oracle is crab's own `presented` line vs the probe's `surface established` — the launcher's
    # own "launching from the launcher:" line prints the app name's ADDRESS, not the name.
    desktops0 = ser().count("desktop up")
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
        key("down 400", 0.8)                      # index 0 (puka) -> index 1 (crab); ONE, held
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
    time.sleep(3.0)
    if ser().count("desktop up") > desktops0:
        p("INCONCLUSIVE: a SECOND compositor came up after launch (a stray Enter opened /bin/aethersafha) — every pointer measurement below would be of two compositors")
        try: s.sendall(b"quit\n")
        except Exception: pass
        qemu.terminate(); sys.exit(2)
    if "crab: open " in ser():
        p("INCONCLUSIVE: crab OPENED something during launch (`crab: open`) — the launch burst leaked into crab")
        try: s.sendall(b"quit\n")
        except Exception: pass
        qemu.terminate(); sys.exit(2)

    # ================================================================================
    # ARM 0 — ASCEND TO `/` FIRST. crab starts in /bin, where row 0 is `aethersafha`, and the
    # context menu's row 0 is Open — which on a FILE spawns it. Run 3 picked Open by pointer and
    # started a second compositor. In `/` every entry is a directory, so Open means descend and
    # the oracle is `crab: cd`. Backspace is not a compositor-claimed key.
    # ================================================================================
    bmark = len(ser())
    for _ in range(10):
        key("backspace 400", 0.9)
        if "crab: cd /" in ser()[bmark:]: break
    at_root = "crab: cd /" in ser()[bmark:]
    p("ascended to /:", at_root)
    if not at_root:
        p("INCONCLUSIVE: Backspace never reached crab — the pick arm would run Open on a file")
        unmeasured.append("ascend: Backspace not delivered")

    # ================================================================================
    # ARM 1 — find crab with a LEFT click (the resize harness's sweep), remember where.
    # ================================================================================
    # ⭐ AIMED, NOT BLIND: the compositor creates every client window at (0, 0) (setu_dispatch.cyr,
    # `comp_create_window(comp, 0, 0, …)`), crab asks for 380x220, and the last-created window is on
    # top. So crab's content is the top-left ~380x250 of the screen and the sweep stays inside it.
    pmark = len(ser())
    where = None
    mon("mouse_move -4000 -4000", 0.4)
    for gx in (200, 100, 300):
        for gy in (130, 80, 180, 220):
            mon("mouse_move -4000 -4000", 0.15)
            mon(f"mouse_move {gx} {gy}", 0.25)
            mon("mouse_button 1", 0.20)
            mon("mouse_button 0", 0.25)
            if "crab: click" in ser()[pmark:]:
                where = (gx, gy); break
        if where: break
    time.sleep(1.0)
    p("left click resolved to a pane at:", where)
    if where is None:
        p("INCONCLUSIVE: no left click reached crab — the pointer arms have nothing to stand on")
        unmeasured.append("pointer: no click resolved")
    if not at_root:
        where = None
    if where is None:
        gx = gy = None
    else:
        gx, gy = where

    # ⚠ SETTLE AFTER MOTION. The kernel accumulates mouse deltas and the compositor drains once per
    # frame; a press sent before the motion's frame has run is resolved at the OLD pointer position
    # (run 6: a right press "had NO client content under the cursor" right after crab relisted /bin
    # and the frame ran long). 0.6 s covers a slow frame under TCG.
    # ⛔ THE PIN NEEDS ITS OWN FRAME. The kernel ACCUMULATES deltas between drains and the compositor
    # clamps the NET move, so a pin (-4000) and a walk (+200) folded into one drain land the cursor at
    # (0, 0) — crab's titlebar — and the press that follows "had NO client content under the cursor"
    # (runs 6 and 12). 0.8 s after each move outlasts a slow TCG frame.
    def goto(x, y):
        mon("mouse_move -4000 -4000", 0.8)
        mon(f"mouse_move {x} {y}", 0.8)

    def right_click_here():
        goto(gx, gy)
        mon("mouse_button 2", 0.20)
        mon("mouse_button 0", 0.30)

    # ================================================================================
    # ARM 2 — RIGHT CLICK: does it arrive as button 2, and does crab open the menu?
    # ================================================================================
    menus = 0
    if where:
        rmark = len(ser())
        for _ in range(3):
            right_click_here()
            time.sleep(0.6)
            if "crab: context menu opened by pointer" in ser()[rmark:]: break
        seg = ser()[rmark:]
        menus = seg.count("crab: context menu opened by pointer")
        fwd = "forwarded a non-left button press, wire number:" in seg
        wire = None
        if fwd:
            # `println_int` lands on its own line and crab's serial output interleaves with the
            # compositor's, so the number is the first bare-integer LINE after the marker.
            after = seg.split("forwarded a non-left button press, wire number:", 1)[1].split("\n")
            for ln in after[:6]:
                t = ln.strip()
                if t.isdigit(): wire = t; break
        p("right click: compositor forwarded a non-left button:", fwd, "wire number:", wire,
          "| crab opened the context menu:", menus, "time(s)")
        if menus == 0:
            fails.append("right-click: crab never opened the context menu"
                         + (" (compositor never forwarded a non-left button either)" if not fwd else ""))
        if fwd and wire != "2":
            fails.append(f"right-click: wire number was {wire}, expected 2 (kernel bit 1 + 1)")

    # ================================================================================
    # ARM 3 — PICK: a LEFT press on a popup row runs the entry. The popup sits at the
    # pointer unless dh_place_at_point flipped it above (window is 220 px tall, popup ~157);
    # search the candidate offsets and let crab's lines say which happened.
    # ================================================================================
    picks = dismisses = 0
    if where and menus > 0:
        cands = [(30, 16), (-105, 16), (30, -141), (-105, -141)]
        cands += [(30, dy) for dy in range(-60, -201, -20)]
        cands += [(-105, dy) for dy in range(-60, -201, -20)]
        menu_open = True
        for (dx, dy) in cands:
            if not menu_open:
                rmark2 = len(ser())
                right_click_here(); time.sleep(0.5)
                if "crab: context menu opened by pointer" not in ser()[rmark2:]:
                    continue
                menu_open = True
            cmark = len(ser())
            goto(gx + dx, gy + dy)
            mon("mouse_button 1", 0.20)
            mon("mouse_button 0", 0.30)
            time.sleep(0.4)
            seg = ser()[cmark:]
            if "crab: menu pick by pointer" in seg:
                picks += 1; menu_open = False
                # ⚠ WHICH verb ran is reported, not assumed: the popup's placement under
                # `dh_place_at_point` is not known from here, so the row under the press is not
                # either. Run 4 aimed at Open (row 0) and ran Copy (row 1) — refused, because the
                # destination existed. On this throwaway image a mis-aimed pick costs nothing; a
                # harness that claimed "Open ran" from the pick line alone would be inventing it.
                verb = "?"
                tail = seg.split("crab: verb by pointer", 1)[1] if "crab: verb by pointer" in seg else ""
                for ln in tail.split("\n")[:12]:
                    t = ln.strip()
                    if t.startswith("crab: ") and "key " not in t and "listed" not in t:
                        verb = t; break
                if verb == "?": verb = "(no crab line — Rename…/New folder… opened a sheet, or Delete asked; Esc clears it below)"
                p(f"pick: a left press at offset ({dx},{dy}) ran a menu entry",
                  "| verb by pointer:", "crab: verb by pointer" in seg, "| what ran:", verb)
                break
            if "crab: popup dismissed by pointer" in seg:
                dismisses += 1; menu_open = False
                p(f"  offset ({dx},{dy}) landed inside crab but off the popup — dismissed; re-opening")
                continue
            p(f"  offset ({dx},{dy}) reached nothing (outside crab's content) — popup still open")
        if picks == 0:
            # ⚠ A pick needs a popup ROW under a derived offset, and after ARM 2's own menu is
            # consumed the retries must re-open one — lossy under TCG. Distinguish "no row was ever
            # hit" (setup, unmeasured) from a row hit that did not run (would be a real fail, but the
            # arm breaks on the first pick, so reaching here means setup).
            unmeasured.append("pick: no candidate offset landed on a popup row (menu re-open lossy)")

    # ⛔ RESET crab's MODAL STATE AFTER THE PICK. The row under the press is not knowable from here,
    # and Rename…/New folder… open a SHEET whose scrim BLOCKS the pointer (`crab_pointer_blocked`) —
    # run 9's dismiss arm could not even open the menu. Bare Esc reaches crab as of aethersafha
    # 0.16.25: with a sheet open it abandons it, with a prompt up it answers no, otherwise nothing.
    if where and menus > 0:
        for _ in range(2): key("esc 400", 0.8)
        time.sleep(0.6)

    # ================================================================================
    # ARM 4 — DISMISS on purpose: open, then press at the right-click point itself, which is
    # the popup's own top-left padding when unflipped and pane content when flipped.
    # ================================================================================
    # ⚠ WHERE TO PRESS IS DERIVED, NOT GUESSED. The popup is 210 px wide and opens at the pointer
    # or flips LEFT of it (`dh_place_at_point`), so a press at the pointer's own x is inside it
    # either way — runs 6-7 picked instead of dismissing. Far left (x=40) is off an unflipped popup
    # and far right (x=350) is off a flipped one; both are inside crab's 380 px content. Try both.
    if where and menus > 0:
        amark = len(ser())
        for dx_abs in (40, 350):
            dmark = len(ser())
            right_click_here()
            opened = False
            for _w in range(8):                      # a slow frame after a relist can take > 1 s under TCG
                if "crab: context menu opened by pointer" in ser()[dmark:]: opened = True; break
                time.sleep(0.3)
            if not opened:
                continue
            goto(dx_abs, gy)
            mon("mouse_button 1", 0.20)
            mon("mouse_button 0", 0.30)
            time.sleep(0.8)
            seg = ser()[dmark:]
            if "crab: popup dismissed by pointer" in seg: dismisses += 1; break
            elif "crab: menu pick by pointer" in seg: picks += 1
        # ⚠ Counted over the whole arm: run 11's menu line landed after the check window, the next
        # right-press met an OPEN popup and dismissed it, and a per-attempt read credited nothing.
        dismisses = max(dismisses, ser()[amark:].count("crab: popup dismissed by pointer"))
        dismiss_menus = ser()[amark:].count("crab: context menu opened by pointer")
        p("dismiss: presses off the popup dismissed it", dismisses, "time(s); picks total", picks,
          "| menus opened for the dismiss arms:", dismiss_menus)
        if dismisses == 0:
            # ⛔ A REAL FAIL ONLY IF A MENU WAS OPEN TO DISMISS. After the pick descends into /bin the
            # dismiss arms' right-clicks are lossy under TCG (menu re-open landed after the poll
            # window, or a delta folded the cursor onto the titlebar) — that is setup, not crab
            # dropping a dismiss. Dismiss itself was proven in runs 4-5; here it is unmeasured.
            if dismiss_menus > 0:
                fails.append("dismiss: a menu was open and NO press dismissed it")
            else:
                unmeasured.append("dismiss: no menu could be re-opened to dismiss (menu re-open lossy under TCG)")

    # ⛔ RESET crab's MODAL STATE BEFORE THE KEY ARMS. A pointer pick lands on whichever row is under
    # the press, and two of the six rows open a SHEET (Rename…, New folder…) while one opens a
    # confirmation (Delete) — run 8 picked a sheet and every key below was typed into it. Bare Esc
    # reaches crab as of aethersafha 0.16.25: with a sheet open it abandons it, with a prompt up it
    # answers no, with nothing open it does nothing. Two, held.
    for _ in range(2): key("esc 400", 0.8)
    time.sleep(0.6)

    # ================================================================================
    # ARM 5 — the REFRESH key `u` (crab 0.8.7): both panes relist, models rebuilt.
    # ================================================================================
    umark = len(ser())
    for _ in range(6):
        key("u", 0.5)
    time.sleep(2.5)
    seg = ser()[umark:]
    refreshes = seg.count("crab: refresh")
    listed = seg.count("crab: listed")
    p("refresh: `u` x6 ->", refreshes, "refresh(es),", listed, "listing line(s)")
    if refreshes == 0:
        if "crab: key received" in seg:
            fails.append("refresh: keys reached crab but no `crab: refresh` line — the binding is dead")
        else:
            unmeasured.append("refresh: no key reached crab during the burst")
    elif listed < 2 * refreshes:
        fails.append(f"refresh: {refreshes} refresh(es) produced only {listed} listing lines (expected 2 per refresh)")

    # ================================================================================
    # ARM 6 — `g` and `b`: the display keys View mirrors, as a liveness check after the popup work.
    # ================================================================================
    gmark = len(ser())
    for _ in range(4): key("g", 0.5)
    time.sleep(1.5)
    views = ser()[gmark:].count("crab: view ")
    bmark = len(ser())
    for _ in range(4): key("b", 0.5)
    time.sleep(1.5)
    sb = ser()[bmark:].count("crab: sidebar ")
    p("display keys: g ->", views, "view line(s); b ->", sb, "sidebar line(s)")
    if views == 0 and sb == 0:
        unmeasured.append("display keys: neither g nor b produced a line")

    # ================================================================================
    # ARM 7 — THE CHROME KEYS ARE Ctrl CHORDS (aethersafha 0.16.25). Bare Esc / Tab / F10 are the
    # client's now: crab must ACT on them (`crab: key press` moves; F10 prints `crab: menu bar`), the
    # compositor must NOT (no `TAB reached`, no `moved the focused window`, no quit). Ctrl+Tab and
    # Ctrl+F10 must be the compositor's, and Ctrl+Q — sent LAST — must end the desktop. Runs 2–5 of
    # this harness measured the OLD contract (bare keys consumed, bare Esc quitting); this arm gates
    # on the new one.
    # ================================================================================
    def crab_keys(): return ser().count("crab: key press")
    # bare F10 → the menu bar, then Right x3 → View, Enter → its drop-down, Enter → Cycle view.
    # ⚠ `View` was reachable by NOBODY before 0.16.25: F10 was the bar's only door and the compositor ate it.
    fmark = len(ser()); k0 = crab_keys()
    key("f10 400", 0.8)
    time.sleep(0.8)
    bar = "crab: menu bar" in ser()[fmark:]
    f10_comp = ser()[fmark:].count("F7-F10 moved the focused window")
    p("bare F10: crab opened the menu bar:", bar, "| compositor moved the window:", f10_comp)
    if not bar and (crab_keys() - k0) == 0:
        unmeasured.append("bare F10: no key reached anything")
    elif not bar:
        fails.append("bare F10 reached crab but did not open the menu bar")
    if f10_comp > 0:
        fails.append("bare F10 moved the window — the compositor still claims it")
    views0 = ser().count("crab: view ")
    if bar:
        for _ in range(3): key("right 400", 0.8)
        key("ret 400", 0.8)                    # open View's drop-down onto item 0 (Cycle view)
        key("ret 400", 0.8)                    # run it
        time.sleep(1.0)
        vpick = ser().count("crab: view ") - views0
        p("View via the keyboard: F10 → Right x3 → Enter → Enter ->", vpick, "view change(s)")
        if vpick == 0:
            unmeasured.append("View via keyboard: the Right/Enter chain did not all land (lossy) — not a verdict")
    # bare Esc: crab acts, the compositor does NOT quit
    emark = len(ser()); k1 = crab_keys()
    for _ in range(3): key("esc 400", 0.8)
    time.sleep(1.0)
    esc_quit = "quit on a key" in ser()[emark:]
    esc_crab = crab_keys() - k1
    p("bare Esc x3: crab acted on", esc_crab, "| compositor quit:", esc_quit)
    if esc_quit: fails.append("bare Esc ended the compositor — the claim was not moved")
    if esc_crab == 0: unmeasured.append("bare Esc: no press reached crab")
    # bare Tab: crab acts (sidebar focus toggle), the compositor does not cycle
    tmark = len(ser()); k2 = crab_keys()
    for _ in range(3): key("tab 400", 0.8)
    time.sleep(1.0)
    tab_comp = ser()[tmark:].count("a TAB reached the compositor")
    tab_crab = crab_keys() - k2
    p("bare Tab x3: crab acted on", tab_crab, "| compositor claimed", tab_comp)
    if tab_comp > 0: fails.append("bare Tab reached the compositor's focus-next — still claimed")
    if tab_crab == 0: unmeasured.append("bare Tab: no press reached crab")
    # Ctrl+Tab and Ctrl+F10: the compositor's, and crab sees NOTHING of the chord
    cmark = len(ser()); k3 = crab_keys()
    for _ in range(3): key("ctrl-tab 400", 0.8)
    time.sleep(1.0)
    ctab_comp = ser()[cmark:].count("a TAB reached the compositor")
    ctab_crab = crab_keys() - k3
    p("Ctrl+Tab x3: compositor answered", ctab_comp, "| crab acted on", ctab_crab)
    if ctab_crab > 0: fails.append("a Ctrl+Tab chord reached crab as a key press — the chord was not swallowed")
    if ctab_comp == 0: unmeasured.append("Ctrl+Tab: no chord reached the compositor")
    gmark = len(ser()); k4 = crab_keys()
    for _ in range(3): key("ctrl-f10 400", 0.8)
    time.sleep(1.0)
    cf10_comp = ser()[gmark:].count("F7-F10 moved the focused window")
    cf10_crab = crab_keys() - k4
    p("Ctrl+F10 x3: compositor answered", cf10_comp, "(one-shot) | crab acted on", cf10_crab)
    if cf10_crab > 0: fails.append("a Ctrl+F10 chord reached crab as a key press")
    # Ctrl+Q LAST: the desktop ends
    qmark = len(ser()); k5 = crab_keys()
    for _ in range(3): key("ctrl-q 400", 0.8)
    time.sleep(3.0)
    q_quit = "quit on a key" in ser()[qmark:]
    q_crab = crab_keys() - k5
    p("Ctrl+Q x3: compositor quit:", q_quit, "| crab acted on", q_crab)
    if not q_quit: fails.append("Ctrl+Q did not end the compositor")
    if q_crab > 0: fails.append("the Ctrl+Q chord reached crab as a key press")

    faulted = "fault: pid=" in ser()
    p("faults:", faulted)
    if faulted: fails.append("a process faulted during the run")
    # A SECOND COMPOSITOR AT ANY POINT INVALIDATES EVERYTHING AFTER IT (runs 1 and 3 of this harness).
    if ser().count("desktop up") > desktops0:
        p("INCONCLUSIVE: a second compositor came up during the run — arms after it measured two desktops")
        unmeasured.append("a second compositor came up mid-run")

    p("")
    p("==== verdict ====")
    for f in fails: p("  FAIL:", f)
    for u in unmeasured: p("  UNMEASURED:", u)
    if fails:
        p("FAIL"); rc = 1
    elif unmeasured or where is None:
        p("INCONCLUSIVE"); rc = 2
    else:
        p(f"PASS — right-click menus {menus}, picks {picks}, dismisses {dismisses}, refreshes {refreshes}; bare F10/Esc/Tab crab's, Ctrl chords the compositor's"); rc = 0
    try: s.sendall(b"quit\n")
    except Exception: pass
finally:
    try: qemu.terminate(); qemu.wait(timeout=10)
    except Exception:
        try: qemu.kill()
        except Exception: pass
sys.exit(rc)
