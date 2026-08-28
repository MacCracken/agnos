#!/usr/bin/env python3
# crab-resize-test — DOES CRAB ACTUALLY ADOPT A `WINDOW_CONFIGURE`, AND IS IT STILL ALIVE AFTER?
#
# ⭐⭐ WHAT THIS EXISTS TO PROVE, AND WHY NOTHING ELSE COULD. crab handles `WINDOW_CONFIGURE` as of
# M2: it resizes its DhSurface, closes and re-creates its `#86` shm slot, and re-ATTACHes. Every line
# of that is inside `#ifdef CYRIUS_TARGET_AGNOS` in `crab/src/main.cyr`, which **no host test can
# reach** — crab's suite covers the POLICY (`crab_resize_wanted`, `crab_surface_bytes`) and stops at
# the syscalls. Until this harness existed, "resize works" was an unverifiable claim.
#
# ⛔ AND IT SETTLES A SECOND QUESTION OPEN SINCE crab 0.5.0. The loop-lifetime fix (the event loop no
# longer ends itself after ~2 s of spinning) has never been proven on agnos, because every existing
# harness has the compositor close crab's window quickly — and the BUGGY 0.4.15 baseline exits the
# same way, so neither distinguishes the fix from the bug. This one leaves crab running on a live
# desktop and asks it to answer a keystroke AFTER the resize. ⛔ Silence is not liveness; an ANSWER is.
#
# ⛔ THE PATH THAT WORKS IS THE F2 LAUNCHER, AND TWO OTHERS ARE ALREADY RULED OUT (crab handoff):
#   · typing `crab &` at agnsh — the compositor OWNS the console once running, so the line never
#     reaches the shell; and crab cannot start from a shell anyway, because it needs `AGNOS_CHAN`,
#     which only the compositor sets when it mints and endows a channel.
#   · `AE_CLIENTS_MODE=desktop` — that is launcher mode with no `--clients`: it spawns NOTHING.
# ⭐ The launcher registry is `/bin/puka` at index 0 and `/bin/crab` at index 1
# (aethersafha `src/main.cyr`: two `lnch_register` calls), and `lnch_openp` resets the selection to 0.
# ⇒ **F2, then DOWN, then Enter** is what starts crab specifically. A harness that skipped the DOWN
# would launch puka and score whatever puka did.
#
# ⭐ IT HAS BEEN PROVEN TO GO RED, and the two arms are distinguishable — which matters here because
# under QEMU the honest outcome is a REFUSAL, not an adoption, so "did not resize" is ambiguous
# unless the log separates them. Measured 2026-08-27, same image, only the binary changed:
#     real crab      -> `crab: cannot back a surface of 2048x2018`, 6 keys answered  -> PARTIAL (rc 0)
#     branch removed -> no CONFIGURE line at all, "F5 burst 1/2/3 produced no CONFIGURE" -> FAIL (rc 1)
# ⇒ The discriminator is that crab SAW the ask and said so. A build that ignores `WINDOW_CONFIGURE`
# is silent, and silence is what this scores red.
#     CRAB_BIN=/path/to/crab_agnos_without_resize python3 scripts/harness/crab-resize-test.py
import json, os, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/crab-resize")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-crabresize.img")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-crabresize.sock"
QMP    = "/tmp/agnos-crabresize-qmp.sock"
AGNOS  = os.path.join(ROOT, "build/agnos")
GNOBOOT= os.path.join(ROOT, "../gnoboot/build/BOOTX64.EFI")
CRAB   = os.environ.get("CRAB_BIN", os.path.join(ROOT, "../crab/build/crab_agnos"))
AE_BIN = os.environ.get("AE_BIN", os.path.join(ROOT, "../aethersafha/build/aethersafha_agnos"))
DISK_MB, PART_OFFSET, PART_BLOCKS = 512, 34603008, 122880
EXT2_FEATURES = "^resize_inode,^dir_index,^ext_attr,^huge_file,^64bit,^metadata_csum"

def p(*a): print(*a, flush=True)
def sh(c): subprocess.run(c, shell=True, check=True)

for need in (AGNOS, GNOBOOT, ROOTFS, CRAB):
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
# ⚠ The crab under test — NOT whatever stage-tools last left in the shared rootfs. A stale binary
# here produces a confidently wrong result, and the sizes are close enough to look identical.
subprocess.run(["cp", CRAB, os.path.join(SEED, "bin", "crab")])
subprocess.run(["chmod", "+x", os.path.join(SEED, "bin", "crab")])
p("seed: /bin/crab <-", CRAB, f"({os.path.getsize(CRAB)} bytes)")
if os.path.exists(AE_BIN):
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
sh(f"mkfs.ext2 -F -q -L AGNOS-CRABRSZ -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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

    # ⚠ THE FIRST KEYSTROKE OF A SESSION IS SWALLOWED (harness README): it triggers the endpoint-registry
    # dispatch and never reaches the line editor. A bare Enter absorbs that window.
    typ("\n"); time.sleep(1.0)
    typ("aethersafha\n"); time.sleep(18.0)      # launcher mode: no --clients, nothing pre-loaded
    mark = len(ser())
    p("compositor up:", "aethersafha:" in ser())

    # ⚠ PROBE KEY DELIVERY BEFORE ANYTHING THAT CARRIES MEANING. QEMU drops keys that land between the
    # compositor's once-per-frame HID drains, so a sequence that delivered nothing would produce a
    # meaningless negative. F3 logs on every press, so it is the cheap oracle. Bursts beat patience.
    # ⚠ RETRY THE PROBE ITSELF. Measured across runs: F3 x8 @0.7 s delivered 3 switches once and
    # **0** the next, on the same image — the compositor drains HID once per FRAME and a burst that
    # lands between drains is simply gone. Aborting on the first empty probe throws away a good boot
    # for a flaky measurement; aborting after several is a real signal about key delivery.
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
        p("INCONCLUSIVE: no key reached the compositor in 4 probes — nothing below can be trusted")
        try: s.sendall(b"quit\n")
        except Exception: pass
        qemu.terminate(); sys.exit(2)

    # ⭐ LAUNCH CRAB SPECIFICALLY: F2 opens the launcher with the selection reset to index 0 (puka),
    # DOWN moves to index 1 (crab), Enter spawns it. ⚠ RETRY — a fixed burst sometimes never reaches
    # Enter, and a run with no crab cannot exercise a resize at all.
    launched = False
    for attempt in range(6):
        lmark = len(ser())
        for _ in range(8):
            key("f2", 0.6)
        time.sleep(1.0)
        for _ in range(6):
            key("down", 0.6)                    # index 0 (puka) -> index 1 (crab)
        time.sleep(1.0)
        for _ in range(8):
            key("ret", 0.6)
        time.sleep(8.0)
        if "presented over setu" in ser()[lmark:]:
            launched = True; break
        p(f"  launch attempt {attempt+1} did not present — retrying")
    p("crab launched and presented:", launched)
    if not launched:
        p("INCONCLUSIVE: crab never presented — F5 had nothing to resize, verdict withheld")
        try: s.sendall(b"quit\n")
        except Exception: pass
        qemu.terminate(); sys.exit(2)

    # ⭐⭐ THE EXPERIMENT. F5 is the compositor's MAXIMIZE, which is what makes it send SETU_CONFIGURE.
    # ⚠ SAME DRAIN PROBLEM, SAME ANSWER: repetition beats patience. F5 is idempotent (maximize on an
    # already-maximized window is a no-op), so extra presses cost nothing and buy delivery odds.
    rmark = len(ser())
    resized = False
    for burst in range(3):
        for _ in range(8):
            key("f5", 0.7)
        time.sleep(4.0)
        if "crab: resized" in ser()[rmark:] or "cannot back a surface" in ser()[rmark:]:
            break
        p(f"  F5 burst {burst+1} produced no CONFIGURE — retrying")
    after_resize = ser()[rmark:]
    resized = "crab: resized" in after_resize
    refused = "cannot back a surface" in after_resize
    if refused:
        p("⚠ crab REFUSED the ask (kernel could not back that extent) — it stayed at its old size")
    p("crab adopted the CONFIGURE (`crab: resized`):", resized)

    # ⛔⛔ LIVENESS AFTER THE RESIZE — and this is the half that settles the 0.5.0 loop question.
    # A crab that re-attached and then died, or one whose loop ended itself, would leave the log
    # looking identical to a success up to this point. Only an ANSWERED keystroke separates them.
    lmark2 = len(ser())
    for _ in range(8):
        key("j", 0.6)                            # 'j' = Down in crab's own keymap
    time.sleep(3.0)
    answered = ser()[lmark2:].count("crab: key received")
    p("keystrokes answered AFTER the resize:", answered)

    # ⭐⭐⭐ THE MOUSE WHEEL, END TO END ACROSS FIVE REPOS. agnos reads HID report byte [3] (1.56.49)
    # -> bhumi carries `BHUMI_EV_SCROLL` (1.4.3) -> setu `SETU_INPUT_PTR_SCROLL` (0.8.8) -> dhancha
    # `POINTER_SCROLL` (0.9.18) -> aethersafha forwards it (0.16.21) -> crab scrolls the pane under
    # the cursor. Every layer is host-tested; THIS is the only thing that exercises the wire.
    # ⛔ QMP, NOT HMP. `sendkey` is keys and `mouse_button` is a 1/2/4 bitmask — HMP has no wheel verb
    # at all, which is why no existing harness could have driven this.
    # ⚠ Park the cursor over crab first: the compositor forwards a scroll to the window UNDER THE
    # CURSOR, so a wheel sent while the pointer is over empty desktop is correctly delivered nowhere.
    qs = None
    wheel_scrolls = 0
    try:
        for _ in range(60):
            try: qs = socket.socket(socket.AF_UNIX); qs.connect(QMP); break
            except OSError: time.sleep(0.25)
        if qs is not None:
            qs.settimeout(3.0)
            qs.recv(65536)
            qs.sendall(b'{"execute":"qmp_capabilities"}\n')
            qs.recv(65536)
            wmark = len(ser())
            for gx, gy in ((300, 250), (500, 350), (700, 200), (400, 450)):
                mon("mouse_move -4000 -4000", 0.15)
                mon(f"mouse_move {gx} {gy}", 0.25)
                for direction in ("wheel-down", "wheel-up"):
                    for _ in range(4):
                        ev = {"execute": "input-send-event", "arguments": {"events": [
                            {"type": "btn", "data": {"down": True,  "button": direction}},
                            {"type": "btn", "data": {"down": False, "button": direction}}]}}
                        qs.sendall((json.dumps(ev) + "\n").encode())
                        try: qs.recv(65536)
                        except Exception: pass
                        time.sleep(0.2)
                time.sleep(1.5)
                if "crab: scroll" in ser()[wmark:]: break
            time.sleep(2.0)
            wheel_scrolls = ser()[wmark:].count("crab: scroll")
    except Exception as e:
        p("  wheel arm error:", e)
    p("wheel: crab resolved", wheel_scrolls, "scroll(s)")

    # ⭐⭐ POINTER ARM (M2, *deferral #05*). crab is the FIRST client to decode `SETU_INPUT_PTR_MOVE`
    # — aethersafha's own note says "no shipped client decodes PTR_MOVE yet" — so nothing else has
    # ever exercised this wire end to end.
    # ⛔ THE ORACLE IS DELIBERATELY COARSE, AND HERE IS WHY. The emulated device is `usb-mouse`, which
    # is RELATIVE: QEMU's `mouse_move` sends deltas, so a harness cannot land the cursor on a chosen
    # pixel. On top of that the compositor places crab's window wherever it likes and hands the client
    # CONTENT-relative coordinates, so the harness does not know where crab's rows are on screen.
    # ⇒ Pin the cursor to the top-left with a large negative delta, then sweep a grid clicking as we
    # go, and assert crab logged **at least one** `crab: click`. That proves the whole wire —
    # compositor forwards, dhancha maps, `crab_hit` resolves a pane. WHICH row a pixel belongs to is
    # asserted on the host against the real rendered tree (`tests/crab.tcyr`), where it can be exact.
    # ⚠ A harness that claimed row-level precision from a relative mouse would be inventing evidence.
    pmark = len(ser())
    mon("mouse_move -4000 -4000", 0.4)          # pin to the top-left corner
    clicked = 0
    for gx in (200, 400, 600, 800):
        for gy in (150, 300, 450):
            mon("mouse_move -4000 -4000", 0.15)
            mon(f"mouse_move {gx} {gy}", 0.25)
            mon("mouse_button 1", 0.20)
            mon("mouse_button 0", 0.25)
            if "crab: click" in ser()[pmark:]:
                clicked = 1; break
        if clicked: break
    time.sleep(2.0)
    clicks = ser()[pmark:].count("crab: click")
    p("pointer: crab resolved", clicks, "click(s) to a pane")

    # ⛔ AND IT MUST STILL BE ALIVE AFTER A CLICK. A click drives a descend path on a double, which
    # re-readdirs and re-stats — the most work any input causes. If that wedged crab, the log would
    # look identical to a success up to this point.
    amark = len(ser())
    NKEY = 6
    for _ in range(NKEY):
        key("j", 0.6)
    time.sleep(2.5)
    alive_after_click = ser()[amark:].count("crab: key received")
    acted = ser()[amark:].count("crab: key press")
    p("keystrokes answered AFTER the click sweep:", alive_after_click, "· acted on:", acted)

    # ⭐⭐ FULL_KEYS (M2 *#06*). crab asks for `SETU_SURF_FULL_KEYS`, so the compositor forwards BOTH
    # edges — `mods` 1 on press, 0 on release. Two counters, two different claims:
    #   `crab: key received` — every KEY event the wire delivered. Should be ~2x the keystrokes.
    #   `crab: key press`    — the ones crab ACTED on. Should be ~1x.
    # ⛔ WITHOUT THE GATE THESE TWO ARE EQUAL, and that is the bug: two rows per Down, Enter
    # descending twice. The compositor measured exactly this on its own chrome on 2026-08-18.
    # ⚠ A RATIO, NOT AN EXACT COUNT. QEMU drops keys that land between the compositor's once-per-frame
    # HID drains, so the absolute numbers vary run to run — what must hold is received > acted.
    if alive_after_click > 0:
        if acted > 0:
            p(f"  FULL_KEYS ratio: received/acted = {alive_after_click}/{acted}"
              + ("  ✅ releases delivered AND gated" if alive_after_click > acted
                 else "  ⚠ equal — releases either absent or NOT gated"))
        else:
            p("  ⚠ events arrived but crab acted on none — the gate may be inverted")

    p("compositor forwarded a scroll:", "forwarded a scroll" in ser())
    # ⭐⭐ HELD-KEY REPEAT (M2 *#06* second half). HMP `sendkey` sends a press AND a release, so it can
    # never hold anything — which is why this needs QMP's `input-send-event` with `down: true` and no
    # matching up until later. crab requests `SETU_SURF_FULL_KEYS`, so it sees both edges and can know
    # the key is still down; `sys_pause` (#14) is already a bounded wait (measured 0-4 ms on a real
    # kernel, because a device IRQ or the 100 Hz timer wakes its single hlt), so the idle path runs
    # often enough to drive repeat from a clock check alone.
    # ⚠ EXPECTED SHAPE, not an exact count: hold ~1.6 s with a 400 ms delay and a 60 ms interval is
    # roughly (1600-400)/60 ~ 20 repeats. QEMU timing varies; what must hold is "many, not zero, and
    # then it STOPS on release".
    rep = 0
    rep_after_release = 0
    if qs is not None:
        try:
            rmark2 = len(ser())
            def qkey(down):
                ev = {"execute": "input-send-event", "arguments": {"events": [
                    {"type": "key", "data": {"down": down,
                     "key": {"type": "qcode", "data": "down"}}}]}}
                qs.sendall((json.dumps(ev) + "\n").encode())
                try: qs.recv(65536)
                except Exception: pass
            qkey(True)                      # press and HOLD
            time.sleep(1.6)
            # ⚠ DID THE HELD KEY EVEN ARRIVE? Without this, "0 repeats" cannot separate a crab bug
            # from a harness that never delivered the key — and QMP `input-send-event` holding a key
            # down is the one thing here that has no other confirmation.
            hold_window = ser()[rmark2:]
            arrived = hold_window.count("crab: key press")
            released = hold_window.count("crab: key received") - arrived
            p(f"  hold window: {arrived} press(es), {released} release(s) seen by crab")
            rep = hold_window.count("crab: key repeat")
            qkey(False)                     # release
            time.sleep(1.2)
            # ⛔ THE RELEASE MUST STOP IT. A latch that is not cleared on the release edge repeats
            # forever — the stuck-key failure FULL_KEYS exists to make avoidable.
            settle = len(ser())
            time.sleep(1.5)
            rep_after_release = ser()[settle:].count("crab: key repeat")
        except Exception as e:
            p("  repeat arm error:", e)
    p("held-key repeat: fired", rep, "time(s) while held ·", rep_after_release, "after release")
    if rep > 0 and rep_after_release == 0:
        p("  ✅ repeat works AND stops on release")
    elif rep > 0:
        p("  ⛔ repeat did not stop on release — the held latch is not cleared")
    else:
        p("  ⚠ no repeat observed (the key may never have reached crab)")

    faulted = "fault: pid=" in ser()[mark:]
    p("kernel/userland fault:", faulted)

    p("---- verdict ----")
    if faulted:
        p("FAIL: a fault occurred during the sequence"); rc = 1
    elif refused and not resized:
        # ⛔ NOT A PASS AND NOT A CRASH. Under QEMU there is no GPU carveout, so `setu_buf_create`
        # falls back to the 2 MB pmm slot and a fullscreen ask cannot be backed at all. What this
        # arm proves is that crab SURVIVES the refusal — which is the bug the first run found, where
        # it had already closed its only buffer and exited.
        if answered > 0:
            p("PARTIAL: the extent was unbackable here (2 MB pmm slot, no GPU carveout under QEMU),")
            p(f"         and crab correctly stayed at its old size and answered {answered} keys after.")
            p("         ⇒ the REFUSAL path is proven; the ADOPT path needs a machine with a carveout.")
            p(f"         pointer: {clicks} click(s) resolved, {alive_after_click} keys answered after them.")
            rc = 0
        else:
            p("FAIL: crab refused the ask and then stopped answering keys"); rc = 1
    elif not resized:
        p("FAIL: crab never logged `crab: resized` — the CONFIGURE was not adopted"); rc = 1
    elif answered == 0:
        p("FAIL: crab answered no key after the resize — re-attach left it dead or wedged"); rc = 1
    elif clicks == 0:
        p("PARTIAL: resize adopted, but no click reached crab — a relative mouse may never have")
        p("         crossed its window. Not a failure of crab; the sweep is best-effort.")
        rc = 0
    else:
        p(f"PASS: crab adopted the resize, resolved {clicks} click(s), and answered {answered} keystrokes")
        p("      ⇒ this also demonstrates the event loop is still turning well past 0.4.15's ~2 s cap")
        rc = 0
    p("serial:", SER)
finally:
    try: s.sendall(b"quit\n")
    except Exception: pass
    try: qemu.wait(timeout=10)
    except Exception: qemu.kill()
sys.exit(rc)
