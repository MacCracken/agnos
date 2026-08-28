#!/usr/bin/env python3
# crab-listing-cap-test — does a crab pane list a directory COMPLETELY?
#
# ⭐ THE BUG (iron, 2026-08-19). `/` held 114 entries; crab's pane showed 32 and dropped 82 with no
# indication, so a file the shell's `ls` listed was simply absent from crab. `crab_readdir_into`
# passed a literal 32 as `sys_readdir`'s max. Reads as a filesystem or staging fault; it is a cap.
#
# ⭐ NO COMPOSITOR NEEDED. crab does BOTH pane readdirs (and stats every entry) in main() before it
# touches setu, and `crab_stat_all` emits one `crab: stat <name> <size>` line per entry. So running
# /bin/crab bare from agnsh — where it later fails to connect — still exercises the listing path in
# full, and the serial line count IS the oracle. This is why the test is seconds, not a launcher dance.
#
# ⛔ THE ORACLE IS AN EXACT COUNT AGAINST THE STAGED TREE, not "more than before". A cap raised from
# 32 to 256 shows "more" for any directory over 32 whether or not it is now COMPLETE; only counting
# the real entries in the seed distinguishes complete from merely-larger.
import os, re, socket, subprocess, sys, time

ROOT   = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK   = os.path.join(ROOT, "build/crab-listing")
SEED   = os.path.join(WORK, "seed")
IMG    = os.path.join(WORK, "agnos-crablist.img")
SER    = os.path.join(WORK, "serial.log")
MON    = "/tmp/agnos-crablist.sock"
AGNOS  = os.path.join(ROOT, "build/agnos")
GNOBOOT= os.path.join(ROOT, "../gnoboot/build/BOOTX64.EFI")
CRAB   = os.environ.get("CRAB_BIN", os.path.join(ROOT, "../crab/build/crab_agnos"))
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
subprocess.run(["cp", CRAB, os.path.join(SEED, "bin", "crab")])
subprocess.run(["chmod", "+x", os.path.join(SEED, "bin", "crab")])

# The panes default to /bin (left) and / (right). Count what the SEED actually holds — the
# expectation has to come from the tree under test, not from a number typed here.
EXP_BIN  = len(os.listdir(os.path.join(SEED, "bin")))
EXP_ROOT = len(os.listdir(SEED))

# ⭐ A DIRECTORY LARGER THAN THE PANE CAP (crab M3 *#02*, agnos 1.56.50 `#101 readdir_at`).
# ⛔ THE CAP ONLY MISBEHAVES ABOVE ITSELF, so a seed of 46 entries cannot test it at all. crab's cap
# is 1024; this directory is deliberately larger, so the listing MUST be truncated and crab must say
# by how much — "showing 1024 of 1200", not "there are more".
BIG_N = 1200
BIG = os.path.join(SEED, "big")
os.makedirs(BIG, exist_ok=True)
for i in range(BIG_N):
    open(os.path.join(BIG, f"f{i:05d}"), "w").close()
EXP_BIG = len(os.listdir(BIG))
p(f"seed: /bin/crab <- {CRAB} ({os.path.getsize(CRAB)} bytes)")
p(f"seed: /bin has {EXP_BIN} entries, / has {EXP_ROOT}, /big has {EXP_BIG}")
p(f"expect the /bin pane to report {EXP_BIN} entries")

sh(f"dd if=/dev/zero of={IMG} bs=1M count={DISK_MB} status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100%")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-CRABL -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
    "-serial", f"file:{SER}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
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
    km = {"\n": "ret", " ": "spc", "-": "minus", "/": "slash", ".": "dot"}
    def typ(t, settle=0.14):
        for ch in t:
            s.sendall(("sendkey " + km.get(ch, ch) + "\n").encode()); time.sleep(settle); drain()

    for _ in range(240):
        if "[ASSIST]" in ser(): break
        time.sleep(0.5)
    if "[ASSIST]" not in ser():
        p("INCONCLUSIVE: never reached the shell"); sys.exit(2)
    p("booted to agnsh: True")

    typ("\n"); time.sleep(1.0)
    mark = len(ser())
    typ("crab\n")
    time.sleep(20.0)
    out = ser()[mark:]

    # ⭐ THE ORACLE IS THE SUMMARY LINE, NOT A COUNT OF PER-ENTRY LINES. crab used to narrate every
    # entry, and this harness counted those lines — which made the diagnostic the thing being
    # measured, and 114 console writes per navigation is what made crab feel slow on iron
    # (2026-08-19). crab 0.4.14 prints one `crab: listed <n> entries in <path>` per readdir and
    # keeps the per-entry trace behind CRAB_STAT_TRACE=1.
    listed = {}
    for lm in re.finditer(r"crab: listed (\d+) entries in (\S+)", out):
        listed[lm.group(2)] = int(lm.group(1))
    stats = [l for l in out.splitlines() if l.startswith("crab: stat ")]
    ran   = len(listed) > 0
    p("crab produced a listing:", ran)
    if not ran:
        p("INCONCLUSIVE: crab produced no listing at all"); p(out[-1200:]); sys.exit(2)

    trunc = "listing truncated at the entry cap" in out
    p("truncation warning:", trunc)
    # Per-entry lines are OFF by default since crab 0.4.14 — 0 here is correct and is the point.
    p(f"per-entry stat lines: {len(stats)} (0 expected unless CRAB_STAT_TRACE=1)")

    # /bin is the left pane and is the one over the old 32 cap. Its entries are what must all appear.
    # ⚠ `crab_stat_all` prints the BARE NAME (`crab: stat <name> <size>`), not the joined path — both
    # panes land in one undifferentiated stream. So the oracle is name membership, not a path prefix.
    binnames = set(os.listdir(os.path.join(SEED, "bin")))
    seen = set(l[len("crab: stat "):].rsplit(" ", 1)[0] for l in stats)
    missing = sorted(binnames - seen)
    p("listings reported:", ", ".join(f"{k}={v}" for k, v in sorted(listed.items())))
    binlisted = listed.get("/bin", -1)
    # ⚠ `seen` holds BOTH panes; the /bin figure is the intersection. Printing len(seen) overstated
    # it (39 of 45 when only 32 /bin entries were listed — the other 7 were root entries).
    if stats:
        p(f"/bin names seen in the trace: {len(binnames & seen)}/{len(binnames)}")
        if missing: p("  MISSING:", " ".join(missing[:12]), "..." if len(missing) > 12 else "")

    # /bin is the pane that exceeds the old 32 cap; its reported count must equal the real tree.
    p(f"/bin listed count: {binlisted}  (tree has {EXP_BIN})")
    if binlisted == EXP_BIN and not trunc:
        p("PASS: the pane listed every /bin entry and nothing was truncated"); rc = 0
    else:
        p("FAIL: the pane did not list the directory completely"); rc = 1

    # ⭐ ARGV REACHES crab ON agnos (crab M3, unreleased, *deferral #11*). `/bin` and `/` were hardcoded, and
    # `args` sat declared in crab's manifest and never called.
    # ⛔ THE ORACLE IS AN ABSENCE, NOT A PRESENCE. Launching `crab /bin /bin` must list `/bin` TWICE
    # and `/` NOT AT ALL — and `/` is exactly what the default run lists. A presence oracle ("did
    # /bin appear?") passes whether or not argv landed, because /bin is also the default left pane.
    # ⚠ THIS RIDES THE SAME BOOT as the run above; a second boot costs ~2 min for one launch. crab
    # exits on its own (it has no compositor to connect to here), so agnsh takes another command.
    # ⚠ argv on agnos is NOT the Linux mechanism: lib/args_agnos.cyr reads the init rsp that cycc
    # parks in r15 at entry. It is compiler plumbing, so a green host test says nothing about here.
    # ⭐ THE ORACLE IS PROVEN DISCRIMINATING BY THE RUN ABOVE, at no extra cost: the bare `crab`
    # launch in this same boot reports `/=7, /bin=45`, which is precisely the shape that trips the
    # `"/" in l2` FAIL branch. So the broken-argv output is on record, in this log, every run.
    mark2 = len(ser())
    typ("crab /bin /bin\n")
    time.sleep(20.0)
    out2 = ser()[mark2:]
    l2 = {}
    for lm in re.finditer(r"crab: listed (\d+) entries in (\S+)", out2):
        l2.setdefault(lm.group(2), []).append(int(lm.group(1)))
    p("argv run listed:", ", ".join(f"{k}x{len(v)}={v[0]}" for k, v in sorted(l2.items())) or "(nothing)")
    if not l2:
        p("INCONCLUSIVE: the argv run produced no listing at all"); rc = rc or 2
    elif "/" in l2:
        p("FAIL: argv did NOT reach crab — it fell back to the hardcoded / pane"); rc = 1
    elif len(l2.get("/bin", [])) == 2:
        p("PASS: argv reached crab — both panes took /bin and the default / never appeared")
    else:
        p("FAIL: unexpected argv listing shape"); rc = 1

    # ⭐⭐ A DIRECTORY LARGER THAN THE PANE CAP IS TRUNCATED **AND SAYS BY HOW MUCH** (*#02*).
    # ⛔ THE OLD MESSAGE WAS "has more entries than are shown", WHICH IS NOT AN ANSWER. `#81 readdir`
    # stops at `max` and cannot see past it, so crab could not know the real number. `#101 readdir_at`
    # carries a cursor, so once the pane buffer is full crab keeps walking WITHOUT storing, purely to
    # count — which is what turns the warning into "showing 1024 of 1200".
    # ⚠ The expectation comes from the seeded tree, not a number typed here.
    markb = len(ser())
    typ("crab /big /\n")
    time.sleep(45.0)
    outb = ser()[markb:]
    mb = re.search(r"listing truncated at the entry cap -- /big showing (\d+) of (\d+)", outb)
    p("big-directory warning:", mb.group(0)[-28:] if mb else "(not found)")
    if not mb:
        p("FAIL: no counted truncation warning for /big"); rc = 1
        p("  saw:", " | ".join(l for l in outb.splitlines() if "crab:" in l)[:400])
    else:
        shown, total = int(mb.group(1)), int(mb.group(2))
        p(f"  shown={shown} total={total}  (tree has {EXP_BIG})")
        if total != EXP_BIG:
            p(f"FAIL: crab counted {total}, the directory holds {EXP_BIG}"); rc = 1
        elif shown != 1024:
            p(f"FAIL: crab showed {shown}, the cap is 1024"); rc = 1
        else:
            p("PASS: the pane filled to its cap and crab reported the directory's TRUE size")

    # ⛔ AND A REFUSED PATH IS ANNOUNCED, not silently swapped for the default. An empty pane with no
    # message reads as a broken filesystem rather than as a rejected argument.
    mark3 = len(ser())
    typ("crab relative\n")
    time.sleep(20.0)
    out3 = ser()[mark3:]
    said = "left path unusable" in out3
    p("refusal announced on the console:", said)
    if not said:
        p("FAIL: an unusable path was swallowed"); rc = 1
finally:
    try: qemu.kill()
    except Exception: pass
p("serial:", SER)
sys.exit(rc)
