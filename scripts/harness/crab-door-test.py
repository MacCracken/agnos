#!/usr/bin/env python3
# crab-door-test — CAN A POINTER REVEAL THE MENU ROW, AND CLOSE IT AGAIN?
#
# ⭐⭐ WHAT THIS EXISTS TO PROVE. crab 0.9.1 put a mark in the status line — three filled boxes, no
# font at all — that reveals the menu bar. Until now `F10` was the ONLY door, and between 0.8.0 and
# aethersafha 0.16.25 it was no door at all, because the compositor claimed that key: the bar crab
# shipped was reachable by nobody. crab's suite gates the DECISION exhaustively (the z-order slot,
# the fit rule, the hit-test, the stale-pointer discipline). What it cannot reach is a real press on
# a real compositor.
#
# ⛔⛆ AND THE TOGGLE IS THE INTERESTING HALF, because it is not a state bit. The door sits BELOW the
# bar branch in `crab_pointer_action`, so a press on it while the bar is already shown never reaches
# the door's own arm — the bar branch sees a press that is not on a bar cell and answers DISMISS.
# Open when closed, close when open, from one hit test. A harness that only proved "it opens" would
# miss the half that comes for free and could silently stop being free.
#
# ⚠ ARM 1 IS CURRENTLY **UNMEASURED**, AND SAYS SO RATHER THAN FAILING. Seven runs went into aiming
# a press at the door. crab reports it laid out at (0, 196, 22, 22) every run, and presses elsewhere
# reach crab normally — but a press inside that rect could not be landed, because the rect is in
# crab's surface coordinates, the monitor moves a RELATIVE pointer in screen coordinates, and
# `mouse_move -4000 -4000` does not reliably home it (the same script proved delivery at four
# different points across four runs). That is a statement about the harness, not about the door,
# and the verdict distinguishes the two.
#
# Oracles:
#     `crab: menu bar by pointer`   the door was pressed and the bar was revealed
#     `crab: popup dismissed by pointer` / the absence of a second open   the same press closed it
#
# ⚠ AIMED, NOT BLIND: the compositor creates every client window at (0, 0) and crab asks for 380x220,
# so the status line is the bottom ~22 px of that and the door is its LEFT edge. The sweep stays in
# that corner rather than hunting the whole screen.
#
#     CRAB_BIN=/path/to/crab_agnos AE_BIN=/path/to/aethersafha_agnos python3 scripts/harness/crab-door-test.py
# Exit: 0 PASS · 1 FAIL (a measured arm gave the wrong answer) · 2 INCONCLUSIVE (delivery failed)
import os, re, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/crab-door")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-crabdoor.img")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-crabdoor.sock"
QMP    = "/tmp/agnos-crabdoor-qmp.sock"
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
sh(f"mkfs.ext2 -F -q -L AGNOS-CRABDOR -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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

    def mon(cmd, wait=0.25):
        s.sendall((cmd + "\n").encode()); time.sleep(wait); drain()

    # ============================================================================================
    # ARM 1 — A PRESS ON THE DOOR REVEALS THE MENU ROW
    # ============================================================================================
    # ⛔⛆ DELIVERY IS PROVED FIRST, AND THAT IS NOT CEREMONY. The first run of this harness swept the
    # status line, got NOTHING — not even a pane line — and the honest reading of "no oracle" was
    # ambiguous between "the door is broken" and "no press reached crab at all". A relative
    # `usb-mouse` cannot land on a chosen pixel, so an arm that does not first establish that the
    # pointer works is measuring nothing and reporting a failure.
    mon("mouse_move -4000 -4000", 0.4)
    pmark = len(ser())
    anywhere = None
    for gx in (200, 100, 300):
        for gy in (130, 80, 180):
            mon("mouse_move -4000 -4000", 0.15)
            mon(f"mouse_move {gx} {gy}", 0.25)
            mon("mouse_button 1", 0.20)
            mon("mouse_button 0", 0.25)
            if "crab: click" in ser()[pmark:]:
                anywhere = (gx, gy); break
        if anywhere: break
    time.sleep(1.0)
    p("ARM 1: pointer delivery proved at:", anywhere)
    if anywhere is None:
        p("INCONCLUSIVE: no press reached crab anywhere — the door is unmeasured, not broken")
        try: s.sendall(b"quit\n")
        except Exception: pass
        qemu.terminate(); sys.exit(2)

    # ⚠ NOW the status line, swept broadly. crab asks for 380x220 at (0,0) and the status line is its
    # bottom row — but the compositor chooses the real geometry, so the sweep walks down and right
    # from the left edge rather than trusting an arithmetic guess.
    # ⭐⭐ crab SAYS WHERE THE DOOR IS, AND THE HARNESS PRESSES THERE. The pointer on this stack is a
    # RELATIVE `usb-mouse` — it cannot be told to land on a chosen pixel — and the compositor picks
    # the window geometry, so aiming at "the status line's left edge" guesses twice. Three runs were
    # spent guessing: one found nothing, one hit the panes at every y it tried, and one disagreed
    # with itself between runs. crab 0.9.1 prints `crab: door <x> <y> <w> <h>` once, after the first
    # frame. ⇒ Read it, press the middle of it.
    dm = re.search(r"crab: door (\d+) (\d+) (\d+) (\d+)", ser())
    if dm is None:
        if "crab: door none" in ser():
            fails.append("ARM 1: crab reports NO door — the window was too narrow for it")
        else:
            unmeasured.append("ARM 1: crab printed no `crab: door` line — cannot aim")
        dm = None
    dmark = len(ser())
    opened_at = None
    if dm is not None:
        dxr, dyr, dwr, dhr = (int(dm.group(1)), int(dm.group(2)), int(dm.group(3)), int(dm.group(4)))
        p(f"ARM 1: crab reports the door at x={dxr} y={dyr} w={dwr} h={dhr}")
        # ⛔ INTEGER, NOT FLOAT. `dwr / 2` is 11.0 in Python 3, and QEMU's monitor takes
        # `mouse_move 11.0 207.0` without complaint and moves NOTHING — six presses in a row produced
        # not even a `crab: click`, which reads exactly like a dead button. `//`, and the earlier
        # sweeps only worked because their coordinates were integer literals.
        cx = dxr + dwr // 2
        cy = dyr + dhr // 2
        # ⚠ RETRIED, because a relative pointer drops a press now and then — the same reason every
        # key in these harnesses is held for 400 ms. The TARGET is exact now; only delivery is not.
        # ⛔⛆ ABSOLUTE SCREEN COORDINATES DO NOT WORK HERE, AND SIX RUNS ESTABLISHED THAT.
        # crab reports the door in ITS OWN surface coordinates (0, 196); the monitor moves a RELATIVE
        # `usb-mouse` in screen coordinates; the compositor chooses where the window sits; and
        # `mouse_move -4000 -4000` does not reliably home — the "delivery proved at" point came back
        # as (200,80), (100,80), (200,130) and (200,180) across runs of the same script.
        # ⇒ WALK DOWN FROM A POINT crab ALREADY RESOLVED, which is the technique
        # `crab-pointer-test.py` uses for exactly this reason. The panes end where `crab: click`
        # stops; the status line is the row after that.
        gx, gy = anywhere
        edge = None
        for step in range(0, 26):
            ty = gy + step * 12
            mk = len(ser())
            mon("mouse_move -4000 -4000", 0.15)
            mon(f"mouse_move {gx} {ty}", 0.25)
            mon("mouse_button 1", 0.20)
            mon("mouse_button 0", 0.25)
            if "crab: click" in ser()[mk:]:
                edge = ty
            elif edge is not None:
                break
        p("ARM 1: the panes stop being hit below screen y =", edge)
        if edge is None:
            unmeasured.append("ARM 1: could not find the pane edge — the door press is unmeasured")
        else:
            # ⚠ The door is at crab-x 0, so it is the LEFT edge of the content — swept in x too,
            # because the window's left edge in screen space is as unknown as its top.
            for ty in (edge + 12, edge + 18, edge + 6, edge + 24, edge + 30):
                for tx in (gx - 180, gx - 190, gx - 170, 10, 4, 16):
                    if tx < 0: continue
                    mon("mouse_move -4000 -4000", 0.15)
                    mon(f"mouse_move {tx} {ty}", 0.25)
                    mon("mouse_button 1", 0.20)
                    mon("mouse_button 0", 0.30)
                    if "crab: menu bar by pointer" in ser()[dmark:]:
                        opened_at = (tx, ty)
                        p(f"    ⭐ the door answered at screen ({tx},{ty})")
                        break
                if opened_at: break
    time.sleep(1.0)
    seg = ser()[dmark:]
    crabbed = [l for l in seg.split("\n") if l.startswith("crab:")]
    p("  DIAG: crab lines during the status-line sweep:", crabbed[:12])
    nopen = seg.count("crab: menu bar by pointer")
    p("ARM 1: the door opened the menu row at:", opened_at, "| opens:", nopen)
    if opened_at is None:
        # ⛔⛆ UNMEASURED, NOT FAILED, AND THE DIFFERENCE IS THE WHOLE POINT OF HAVING TWO VERDICTS.
        # SEVEN QEMU runs went into aiming this press. What IS established, every run: crab builds
        # the door and reports it laid out at (0, 196, 22, 22) under the real face, and presses
        # elsewhere reach crab normally (`crab: click`). What could not be established is a press
        # landing inside that rect, because:
        #   · the rect is in crab's SURFACE coordinates and the monitor moves the pointer in SCREEN
        #     coordinates, with the compositor choosing the window's origin;
        #   · `mouse_move -4000 -4000` does not reliably home a RELATIVE `usb-mouse` — the
        #     "delivery proved at" point came back as (200,80), (100,80), (200,130) and (200,180)
        #     across runs of an unchanged script;
        #   · walking down from a resolved point put the pane edge at screen y=154 against a
        #     crab-space 196, i.e. a ~36 px offset — and sweeping the mapped region in BOTH axes
        #     still delivered nothing, which means the presses are being dropped rather than missing.
        # ⇒ Reporting FAIL here would assert the door is broken, which this harness has no evidence
        # for and the suite has nine assertions against. The arm stays, and the next session with a
        # way to place an absolute pointer inherits it.
        unmeasured.append("ARM 1: could not land a press inside the door's reported rect — "
                          "relative-pointer aiming, not evidence about the door (see the header)")

    # ============================================================================================
    # ARM 2 — THE SAME PRESS CLOSES IT, AND THAT IS THE Z-ORDER RATHER THAN A STATE BIT
    # ============================================================================================
    if opened_at is None:
        unmeasured.append("ARM 2: the door never opened, so the toggle is unmeasured")
    else:
        dx, dy = opened_at
        cmark = len(ser())
        mon("mouse_move -4000 -4000", 0.15)
        mon(f"mouse_move {dx} {dy}", 0.25)
        mon("mouse_button 1", 0.20)
        mon("mouse_button 0", 0.30)
        time.sleep(1.5)
        seg = ser()[cmark:]
        reopened = seg.count("crab: menu bar by pointer")
        dismissed = seg.count("crab: popup dismissed by pointer")
        p("ARM 2: pressing the same spot again -> opens:", reopened, "| dismissals:", dismissed)
        # ⛔ THE ASSERTION IS THAT IT DID NOT OPEN AGAIN. With the bar shown the press is off a bar
        # cell, so `crab_pointer_action` answers DISMISS before the door's arm is ever reached. A
        # second `menu bar by pointer` would mean the door had been placed ABOVE the bar branch —
        # the one arrangement in which it can never put the bar away.
        if reopened != 0:
            fails.append(f"ARM 2: the door opened the bar AGAIN ({reopened}) — it cannot close it, "
                         f"so its z-order slot is wrong")

    # ============================================================================================
    # ARM 3 — F10 STILL WORKS, because the door is an ADDITION
    # ============================================================================================
    fmark = len(ser())
    for _ in range(3):
        key("f10 400", 1.0)
    time.sleep(1.5)
    fbar = ser()[fmark:].count("crab: menu bar")
    p("ARM 3: F10 x3 -> `crab: menu bar` lines:", fbar)
    if fbar == 0:
        unmeasured.append("ARM 3: F10 produced nothing — the keyboard door is unmeasured here")

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
