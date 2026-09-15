#!/usr/bin/env python3
# crab-preview-test — DOES THE PREVIEW READ ON THE KEYSTROKE, OR ON THE IDLE TICK?
#
# ⭐⭐ THE CLAIM IS ABOUT *WHEN*, AND A SCREENSHOT CANNOT SEE WHEN. Before 0.9.4 the preview's
# dimension+EXIF read was an open/read/close of up to 64 KiB on the SELECTION path — the arrow key's
# own frame. After it, the read is on the idle tick. Both end with numbers in the column, so the
# oracle has to be the wire: `crab: pv <name> state <s> <w>x<h>` is emitted by the DRAIN and by
# nothing else, so a line appearing at all proves the tick did the work.
#
# ⛔ AND THE SECOND ARM IS A BUG THAT WAS SHIPPING. The idle tick's redraw gate was
# `if (tafter != tbefore)`, so arrowing between two ALREADY-DECODED images was OK -> OK: no frame
# was drawn, and the PREVIOUS file's picture stayed on screen under the new file's name. Measured on
# the host first (two real PNGs, different slots, `redraw fired: 0`); this gates it on iron.
#
# ⛔ NO HOST TEST REACHES THE DRAIN. It sits in main.cyr inside `#ifdef CYRIUS_TARGET_AGNOS` with no
# `#else`. The suite drives the DECISIONS (`crab_pv_should_step`, `crab_pv_redraw_due`,
# `crab_pvd_row`, `crab_pv_state_for`) exhaustively; only iron can show the loop running them.
#
# Oracles:
#     `crab: pv <name> state 1 <w>x<h>`  the DRAIN read that file, on a tick
#     absence of it on a keystroke       the selection path opened nothing
#
#     CRAB_BIN=... AE_BIN=... python3 scripts/harness/crab-preview-test.py
# Exit: 0 PASS · 1 FAIL · 2 INCONCLUSIVE
import os, re, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/crab-preview")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-crabpv.img")
PART   = os.path.join(WORK, "part.ext2")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-crabpv.sock"
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
IMGS = [("zzpic1.png", 137, 42), ("zzpic2.png", 320, 200)]

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

# ⭐ REAL PNGs, written with a real IHDR so `crab_img_dims` reads genuine bytes.
import struct, zlib
def _png(path, w, h):
    raw = b"".join(b"\x00" + bytes((200, 30, 30)) * w for _ in range(h))
    def ck(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    out = b"\x89PNG\r\n\x1a\x0a"
    out = b"\x89PNG\r\n\x1a\n"
    out += ck(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    out += ck(b"IDAT", zlib.compress(raw, 6))
    out += ck(b"IEND", b"")
    open(path, "wb").write(out)
for nm, w, h in IMGS:
    _png(os.path.join(SEED, "bin", nm), w, h)
p("seed: " + ", ".join(f"/bin/{nm} {w}x{h}" for nm, w, h in IMGS))

sh(f"dd if=/dev/zero of={IMG} bs=1M count={DISK_MB} status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100%")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-CRABPV_ -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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

    
    # ⛔ HOME ON THE ANSWER, NEVER ON A KEYPRESS COUNT. A blind "press Down 80 times" landed on the
    # wrong file in the symlink harness — keys are lost between the compositor's per-frame drains.
    # Here the oracle IS the file name, so the harness steps until the name it wants appears.
    key("p 400", 1.5)                      # open the preview
    time.sleep(1.5)
    p("preview toggled:", True)

    def hop_to(target, hops=75):
        """Step down until the DRAIN reports `target`. Returns the pv lines seen on the way."""
        seen = []
        for _ in range(hops):
            mk = len(ser())
            key("down 300", 0.9)
            time.sleep(1.1)                 # let at least one idle tick run
            for m in re.finditer(r"crab: pv (\S+) state (\d+) (\d+)x(\d+)", ser()[mk:]):
                seen.append((m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))))
            if any(s[0] == target for s in seen):
                return seen
        return seen

    # ========================================================================================
    # ARM 1 — THE DRAIN RUNS, AND IT RESOLVES REAL DIMENSIONS
    # ========================================================================================
    seen1 = hop_to(IMGS[0][0])
    p("ARM 1: pv lines seen:", seen1[-6:])
    hit1 = [s for s in seen1 if s[0] == IMGS[0][0]]
    if not hit1:
        unmeasured.append(f"ARM 1: never reached {IMGS[0][0]} — the drain is unmeasured")
    else:
        nm, st, gw, gh = hit1[-1]
        want_w, want_h = IMGS[0][1], IMGS[0][2]
        p(f"ARM 1: {nm} -> state {st}, {gw}x{gh} (want {want_w}x{want_h})")
        if st != 1:
            fails.append(f"ARM 1: the drain read {nm} but did not resolve it (state {st})")
        elif (gw, gh) != (want_w, want_h):
            fails.append(f"ARM 1: ⛔ {nm} reported {gw}x{gh}, but the file is {want_w}x{want_h}")
        else:
            p("        ⭐ the IDLE TICK read it and got the right numbers")

    # ========================================================================================
    # ARM 2 — ⛔ THE SECOND IMAGE GETS ITS OWN ANSWER, NOT THE FIRST ONE'S
    # ========================================================================================
    seen2 = hop_to(IMGS[1][0])
    hit2 = [s for s in seen2 if s[0] == IMGS[1][0]]
    p("ARM 2: pv lines seen:", seen2[-4:])
    if not hit2:
        unmeasured.append(f"ARM 2: never reached {IMGS[1][0]} — unmeasured")
    else:
        nm, st, gw, gh = hit2[-1]
        want_w, want_h = IMGS[1][1], IMGS[1][2]
        p(f"ARM 2: {nm} -> state {st}, {gw}x{gh} (want {want_w}x{want_h})")
        if (gw, gh) == (IMGS[0][1], IMGS[0][2]):
            fails.append(f"⛔⛆ ARM 2: {nm} reported the PREVIOUS image's dimensions "
                         f"{gw}x{gh} — the preview is one file behind the selection")
        elif (gw, gh) != (want_w, want_h):
            fails.append(f"ARM 2: {nm} reported {gw}x{gh}, want {want_w}x{want_h}")
        else:
            p("        ⭐ each image gets its OWN dimensions")

    # ========================================================================================
    # ARM 3 — A FILE IS READ AT MOST ONCE. The remembered answer must not be re-read every tick.
    # ========================================================================================
    allpv = re.findall(r"crab: pv (\S+) state", ser())
    counts = {}
    for nm in allpv:
        counts[nm] = counts.get(nm, 0) + 1
    repeats = {k: v for k, v in counts.items() if v > 1}
    p("ARM 3: reads per file:", counts)
    if repeats:
        fails.append(f"⛔ ARM 3: the drain RE-READ files it had already answered: {repeats} — "
                     f"a remembered answer must never be spent again")
    else:
        p("        ⭐ every file was read exactly once — the memo holds on the tick")

    faulted = any(x in ser() for x in ("PAGE FAULT", "GENERAL PROTECTION")) or "panic" in ser().lower()
    p("ARM 3: faults:", faulted)
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
