#!/usr/bin/env python3
# crab-columns-test — DOES THE COLUMNS VIEW'S CONTEXT LISTING ACTUALLY HAPPEN, AND DOES IT HAPPEN
# ONCE PER NAVIGATION RATHER THAN ONCE PER FRAME?
#
# ⭐⭐ WHAT THIS EXISTS TO PROVE, AND WHY THE SUITE CANNOT. crab 0.8.8 added a fourth view: the active
# pane grows a narrow CONTEXT column showing the parent directory with the current one marked. The
# RENDER half is gated by `tests/crab.tcyr` — the column is built, is a LIST, marks the right row,
# never takes focus, is dropped rather than squeezed, and takes its width off the listing. The
# LISTING half cannot be: `crab_readdir_into`'s entire body is inside `#ifdef CYRIUS_TARGET_AGNOS`
# with no `#else`, so on the host it returns 0 entries for every path — `/tmp` included. A first
# draft of the suite built a real tree under `build/` and asserted the listing; every assertion
# failed against an empty listing and a clean error code, which is what that `#ifdef` looks like from
# a host test. ⇒ The listing is gated HERE, on a real agnos kernel, or it is not gated at all.
#
# ⛔⛔ AND THE SECOND ARM IS THE ONE THAT MATTERS MOST. A readdir is not a render-path operation.
# Without `crab_cols_sync`'s memo the columns view would readdir the parent AND stat every entry in
# it on EVERY FRAME — and frames are produced on every keypress, every pointer move and every idle
# tick. The pane listings themselves are taken once per navigation for exactly this reason. A memo
# that silently stopped working would not look like a bug; it would look like a slow file manager.
# ⇒ ARM 3 presses keys that redraw and asserts the listing line count DID NOT MOVE.
#
# Oracles — crab's own serial lines, all of them printed on the MISS path only:
#     `crab: view columns`      the `g` cycle reached the fourth view (ceiling moved off GALLERY)
#     `crab: columns <name>`    the parent was listed, and this is the parent's own name
#     `crab: columns none`      standing at `/`, where there is honestly no context column
#     `crab: cd <path>`         a navigation happened (the existing oracle, used to sequence ARM 4)
#
#     CRAB_BIN=/path/to/crab_agnos AE_BIN=/path/to/aethersafha_agnos python3 scripts/harness/crab-columns-test.py
# Exit: 0 PASS · 1 FAIL (a measured arm gave the wrong answer) · 2 INCONCLUSIVE (delivery failed)
import os, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/crab-columns")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-crabcols.img")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-crabcols.sock"
QMP    = "/tmp/agnos-crabcols-qmp.sock"
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

# ⛔ AE_BIN IS REQUIRED. crab draws through the compositor; without one it never presents and every
# arm below would be unmeasured rather than failed.
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
sh(f"mkfs.ext2 -F -q -L AGNOS-CRABCOL -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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
    # ⛔ `sendkey <key> <hold_ms>`, ALWAYS. The boot-keyboard report is a STATE: a press and its
    # release that both land between two of the compositor's per-frame drains leave only the release
    # to be seen, and the key is silently lost. This cost the pointer harness four runs to learn.
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
    key("ret", 1.0)                               # the first keystroke of a session is swallowed
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

    # F2 -> DOWN -> Enter launches /bin/crab (index 1; puka is index 0). ⛔ ONE Enter and ONE DOWN,
    # each held, and the OUTCOME read rather than assumed — an Enter burst reaches crab as ITS Enter
    # and Opens the selected row, which in /bin spawns a SECOND compositor. See crab-pointer-test.
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
    # ARM 1 — `g` REACHES THE FOURTH VIEW
    # ============================================================================================
    # ⛔ THE CEILING MOVES WHEN A VIEW IS ADDED. `g` cycles and wraps at the last id; a wrap left at
    # GALLERY would make COLUMNS unreachable by the only key that selects a view — the view would
    # ship, render correctly, and be impossible to open. The cycle is inside the agnos `#ifdef` and
    # no host test can press the key; the ORDERING it depends on is pinned in the suite, the KEY is
    # pinned here.
    gmark = len(ser())
    for _ in range(4):
        key("g 400", 1.2)
    time.sleep(2.0)
    seg = ser()[gmark:]
    views = [v for v in ("list", "grid", "gallery", "columns") if f"crab: view {v}" in seg]
    reached = "crab: view columns" in seg
    p("ARM 1: `g` x4 ->", len(seg.split("crab: view ")) - 1, "view change(s); views seen:", views)
    p("        reached COLUMNS:", reached)
    if not reached:
        if (len(seg.split("crab: view ")) - 1) == 0:
            unmeasured.append("ARM 1: no `g` reached crab at all")
        else:
            fails.append("ARM 1: `g` cycled but never reached COLUMNS — the wrap ceiling did not move")

    # ⭐ PARK THE CYCLE ON COLUMNS. Four presses from LIST land back on LIST, so step forward until
    # the last view line says columns — read, never counted, because a lost key would desynchronise
    # a counted sequence silently.
    parked = False
    for _ in range(8):
        seg = ser()
        last = None
        for v in ("list", "grid", "gallery", "columns"):
            i = seg.rfind(f"crab: view {v}")
            if i >= 0 and (last is None or i > last[1]): last = (v, i)
        if last and last[0] == "columns": parked = True; break
        key("g 400", 1.2)
    p("        parked on COLUMNS:", parked)
    if not parked and reached:
        unmeasured.append("ARM 1: could not park the cycle on COLUMNS — ARMs 2-4 unmeasured")

    # ============================================================================================
    # ARM 2 — THE CONTEXT LISTING HAPPENS, AND NAMES THE RIGHT PARENT
    # ============================================================================================
    # crab starts with pane A on `/bin`, so the parent is `/` — whose own name is nothing, and
    # `crab_cols_sync` titles that case `/`. This is the line no host test can produce.
    if parked:
        time.sleep(2.0)
        listed = ser().count("crab: columns ")
        named_root = "crab: columns /\n" in ser()
        p("ARM 2: `crab: columns` line(s):", listed, "| titled `/` (the parent of /bin):", named_root)
        if listed == 0:
            fails.append("ARM 2: the columns view never listed a parent — the context column has no data")
        elif not named_root:
            fails.append("ARM 2: the parent was listed but not titled `/` — /bin's parent is the root")
    else:
        unmeasured.append("ARM 2: never parked on COLUMNS")

    # ============================================================================================
    # ARM 3 — THE MEMO: FRAMES THAT DO NOT NAVIGATE COST NO LISTING
    # ============================================================================================
    # ⛔⛔ THE ARM THIS HARNESS EXISTS FOR. `b` toggles the sidebar and `u` refreshes — both redraw,
    # neither changes the active pane's PATH. If the listing line count moves here, the memo is not
    # working and the columns view is doing a readdir plus a stat per entry on every frame.
    # ⚠ `u` IS INCLUDED ON PURPOSE even though it re-lists the pane: a refresh calls
    # `crab_relist_keep_thumbs`, which DROPS the context memo — so exactly one further listing is
    # allowed per refresh that actually lands, and zero for the sidebar toggles.
    if parked:
        mmark = ser().count("crab: columns ")
        rmark = ser().count("crab: refresh")
        for _ in range(4):
            key("b 400", 1.0)
        time.sleep(2.0)
        after_b = ser().count("crab: columns ")
        p("ARM 3: sidebar toggles x4 -> listing lines went", mmark, "->", after_b)
        if after_b != mmark:
            fails.append(f"ARM 3: redrawing re-listed the parent ({after_b - mmark} extra) — the memo is dead")
        for _ in range(2):
            key("u 400", 1.0)
        time.sleep(2.0)
        refreshes = ser().count("crab: refresh") - rmark
        after_u = ser().count("crab: columns ")
        p("        refresh x2 ->", refreshes, "refresh(es); listing lines", after_b, "->", after_u)
        if after_u - after_b > refreshes:
            fails.append("ARM 3: a refresh re-listed the parent more than once")
    else:
        unmeasured.append("ARM 3: never parked on COLUMNS")

    # ============================================================================================
    # ARM 4 — NAVIGATING RE-LISTS, AND THE ROOT HONESTLY HAS NO CONTEXT
    # ============================================================================================
    # Backspace ascends /bin -> /. The parent of `/` does not exist, and `crab_cols_sync` says so
    # with `crab: columns none` rather than publishing an empty listing — an empty strip where
    # context should be reads as "this directory has no siblings", which is a different and false
    # statement. ⛔ And the refusal is MEMOISED: standing at `/` must not retry the listing forever,
    # so the `none` line appears ONCE however many redraws follow.
    if parked:
        amark = len(ser())
        for _ in range(3):
            key("backspace 400", 1.2)
            if "crab: cd /\n" in ser()[amark:]: break
        time.sleep(2.0)
        seg = ser()[amark:]
        ascended = "crab: cd /\n" in seg
        nones = seg.count("crab: columns none")
        p("ARM 4: ascended to /:", ascended, "| `columns none` line(s):", nones)
        if not ascended:
            unmeasured.append("ARM 4: Backspace never reached crab — the ascend is unmeasured")
        elif nones == 0:
            fails.append("ARM 4: at the root crab did not report `columns none` — it published something")
        else:
            nmark = ser().count("crab: columns none")
            for _ in range(4):
                key("b 400", 1.0)
            time.sleep(2.0)
            again = ser().count("crab: columns none") - nmark
            p("        redraws at / -> further `none` line(s):", again)
            if again != 0:
                fails.append(f"ARM 4: the root's refusal is not memoised ({again} retries) — a listing attempt per frame")
    else:
        unmeasured.append("ARM 4: never parked on COLUMNS")

    # ============================================================================================
    # ARM 5 — LEAVING THE VIEW STOPS THE LISTING
    # ============================================================================================
    # ⚠ `crab_cols_sync` runs on EVERY path that fills the record, including the ones that are not in
    # columns view — it must CLEAR the fields as well as set them. What it must NOT do is keep
    # listing: outside the view there is nothing to draw and the syscalls would be pure cost.
    if parked:
        lmark2 = ser().count("crab: columns ")
        for _ in range(3):
            key("g 400", 1.2)                     # columns -> list -> grid -> gallery
        time.sleep(2.0)
        for _ in range(4):
            key("b 400", 1.0)
        time.sleep(2.0)
        after = ser().count("crab: columns ")
        p("ARM 5: left the view, then redrew -> listing lines", lmark2, "->", after)
        if after != lmark2:
            fails.append(f"ARM 5: crab kept listing parents outside the columns view ({after - lmark2} extra)")
    else:
        unmeasured.append("ARM 5: never parked on COLUMNS")

    # ============================================================================================
    # ARM 6 — NO FAULTS
    # ============================================================================================
    log = ser()
    faulted = ("PAGE FAULT" in log) or ("GENERAL PROTECTION" in log) or ("panic" in log.lower())
    p("ARM 6: faults:", faulted)
    if faulted: fails.append("ARM 6: the kernel faulted")

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
