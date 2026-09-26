#!/usr/bin/env python3
# run37-smp4-test (1.46.7 STEP-2 #3; REWRITTEN 1.57.7 S3b-F0) — agnsh's FOREGROUND execwait#37 under -smp 4.
# ⭐ WHAT IT DRIVES (1.57.7). agnoshi >= 1.9.x runs a plain `run X` through spawn_path#43 + a poll, so typing it no
# longer reaches #37 at all (this harness typed `run /bin/bnrmr X` and so tested #43 for a whole release). Pipelines and
# `>` redirects STAY on #37 in both 1.9.11 and 2.0.0 (agnoshi src/run_agnos.cyr), so this drives
#     bnrmr AGNOS > /r37a    owl -p /r37a    bnrmr OS > /r37b    owl -p /r37b    version
# (agnsh has no `cat`: "AGNOS reads files with owl" — `owl -p` is the plain read-back.)
# i.e. #62 arms (1 <- the file) and #37 runs bnrmr with its stdout in the file. Since S3b the #37 child is an ordinary
# scheduled IF=1 process and agnsh BLOCKS in the kernel until it exits; the redirect is applied into the child's
# private fd table (strict shape — refused if the child could only get the global table) and dies with it.
# PASS = BOTH read-backs (`owl -p`) print the banner art (the capture really landed in each file: >= 8 art chars in each read-back),
#        both prompts return, `version` prints the STAGED agnsh's version string (read from build/rootfs/bin/agnsh,
#        never hard-coded — the old check waited for a stale "agnoshi 1.7.0" and could never see it), the kernel witness
#        `execwait: first scheduled child` is on serial (the #37 route was really taken — S3b-F2+; set
#        RUN37_WITNESS=optional only for a pre-conversion run, which then says so), and no SMOKE_INVARIANT_DENY line.
# ⚠ HMP `sendkey` drops keystrokes on long lines: every command is typed with type_verified (re-typed until its echo
# is seen, shutdown-smoke's recipe). Builds its own image from build/rootfs (stage-agnsh.sh first; never re-staged
# here — that builds inside ../agnoshi, a read-only sibling).
import socket, subprocess, sys, time, os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GNOBOOT = os.environ.get("GNOBOOT_ROOT", os.path.join(ROOT, "../gnoboot")) + "/build/BOOTX64.EFI"
AGNOS = os.path.join(ROOT, "build/agnos")

# ⛔ 1.57.1 — REFUSE A STALE KERNEL. This harness resolved build/agnos as a PATH and never
# checked it was current, so an edited-but-not-rebuilt kernel scored green having asserted
# nothing new. Every harness here exists to test KERNEL behaviour, so this is the half that
# matters most. See scripts/harness/_freshness.py for the measurement that produced it.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _freshness import refuse_stale_kernel
refuse_stale_kernel(ROOT)
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK = os.path.join(ROOT, "build/run37")
IMG = os.path.join(WORK, "agnos-run37.img")
SEED = os.path.join(WORK, "seed")
SER = os.path.join(WORK, "serial-run37.log")
MON = "/tmp/agnos-run37.sock"
PART_OFFSET = 33 * 1048576
PART_BLOCKS = (67 * 1048576) // 4096
EXT2_FEATURES = os.environ.get("EXT2_SMOKE_FEATURES",
                               "^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg")
NCPU = os.environ.get("RUN37_SMP", "4")

def need(*paths):
    for p in paths:
        if not os.path.exists(p):
            print("FAIL: missing", p, "(build the kernel + stage-agnsh.sh first)"); sys.exit(1)
need(GNOBOOT, AGNOS, os.path.join(ROOTFS, "bin/agnsh"), os.path.join(ROOTFS, "bin/bnrmr"))
# The version string `version` must print: read from the STAGED binary (1.9.11 at 1.57.7), never hard-coded.
STAGED_VER = ""
try:
    _sv = subprocess.run(["strings", os.path.join(ROOTFS, "bin/agnsh")], stdout=subprocess.PIPE).stdout.decode("latin1")
    for _ln in _sv.splitlines():
        if _ln.startswith("agnoshi ") and len(_ln) > 8 and _ln[8].isdigit():
            STAGED_VER = _ln.split()[0] + " " + _ln.split()[1]; break
except OSError:
    pass
print("staged agnsh:", STAGED_VER or "(unknown)")

OVMF_CODE = OVMF_VARS = None
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/edk2/x64/OVMF_CODE.fd",
          "/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_CODE_4M.fd"):
    if os.path.exists(c): OVMF_CODE = c; break
for c in ("/usr/share/edk2/x64/OVMF_VARS.4m.fd", "/usr/share/edk2/x64/OVMF_VARS.fd",
          "/usr/share/OVMF/OVMF_VARS.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"):
    if os.path.exists(c): OVMF_VARS = c; break
if not OVMF_CODE or not OVMF_VARS:
    print("FAIL: OVMF not found"); sys.exit(1)

def sh(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if r.returncode != 0:
        print("FAIL build step:", cmd, "\n", r.stderr.decode("latin1")[:400]); sys.exit(1)

subprocess.run(["rm", "-rf", WORK]); os.makedirs(WORK, exist_ok=True)
subprocess.run(["cp", "-a", ROOTFS, SEED])
sh(f"dd if=/dev/zero of={IMG} bs=1M count=128 status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100MiB")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-R37 -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
subprocess.run(["cp", OVMF_VARS, os.path.join(WORK, "vars.fd")])
subprocess.run(["chmod", "+w", os.path.join(WORK, "vars.fd")])
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass
print(f"built run37 image: {IMG} (-smp {NCPU}, foreground execwait#37 via `bnrmr X > /file`)")

DINT = os.environ.get("RUN37_DINT", "") == "1"
QLOG = os.path.join(WORK, "qint.log")
qargs = [
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-cpu", "max", "-smp", NCPU,
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-R37",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
    "-serial", f"file:{SER}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
]
if DINT:   # TCG (no KVM) + interrupt/exception logging for the SMP-fault exception count
    qargs += ["-accel", "tcg", "-d", "int", "-D", QLOG]
qemu = subprocess.Popen(qargs, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def p(*a): print(*a, flush=True)
rc = 1
try:
    s = None
    for _ in range(60):
        try:
            s = socket.socket(socket.AF_UNIX); s.connect(MON); break
        except OSError: time.sleep(0.2)
    if s is None: p("FAIL: no monitor"); sys.exit(1)
    s.settimeout(1.0)

    def drain():
        try:
            while True: s.recv(65536)
        except OSError: pass
    def ser():
        try: return open(SER, "rb").read().decode("latin1")
        except OSError: return ""
    km = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '/': 'slash', '>': 'shift-dot'}
    def key(k):
        s.sendall(("sendkey " + k + "\n").encode()); time.sleep(0.15); drain()
    def typ(word):
        key('ret')                                  # prime: the first sendkey after an idle gap can be dropped
        for ch in word:
            k = km.get(ch, ch)
            if ch.isupper(): k = "shift-" + ch.lower()
            key(k)
        key('ret')
    def type_verified(word, settle=1.5):
        for attempt in range(4):
            m = len(ser()); typ(word); time.sleep(settle)
            if word in ser()[m:]: return m
            p(f"  retry: {word!r} did not echo cleanly (attempt {attempt + 1}, dropped key)")
        return -1
    # The text AFTER the command's echo (the prime `ret` prints a prompt of its own, so the marker is searched only
    # past the echo). "" when the command never echoed.
    def after(seg, cmd):
        i = seg.find(cmd)
        return seg[i + len(cmd):] if i >= 0 else ""
    def run_wait(cmd, marker, timeout=30):
        time.sleep(1.2); drain()
        m = type_verified(cmd)
        if m < 0: return ""
        deadline = time.time() + timeout
        while time.time() < deadline:
            seg = ser()[m:]
            if marker in after(seg, cmd): return seg
            time.sleep(0.5)
        return ser()[m:]
    def art(seg, cmd):
        return sum(after(seg, cmd).count(c) for c in "#_|\\")

    ok = False
    for _ in range(480):
        if "agnoshi" in ser(): ok = True; break
        time.sleep(0.25)
    p("banner seen:", ok)
    if not ok: p("FAIL: no agnsh banner"); sys.exit(1)
    time.sleep(1.0)

    # 1) FOREGROUND execwait#37 with a `>` redirect, then read the capture back.
    segw1 = run_wait("bnrmr AGNOS > /r37a", "[ASSIST]", timeout=30)
    segc1 = run_wait("owl -p /r37a", "[ASSIST]", timeout=20)
    art1 = art(segc1, "owl -p /r37a"); rendered1 = art1 >= 8
    prompt_back1 = "[ASSIST]" in after(segw1, "bnrmr AGNOS > /r37a") and "[ASSIST]" in after(segc1, "owl -p /r37a")
    # 2) a SECOND #37 — agnsh must have come back intact from the first wait.
    segw2 = run_wait("bnrmr OS > /r37b", "[ASSIST]", timeout=30)
    segc2 = run_wait("owl -p /r37b", "[ASSIST]", timeout=20)
    art2 = art(segc2, "owl -p /r37b"); rendered2 = art2 >= 8
    prompt_back2 = "[ASSIST]" in after(segw2, "bnrmr OS > /r37b") and "[ASSIST]" in after(segc2, "owl -p /r37b")
    # 3) agnsh still answers — `version` prints the STAGED binary's version string.
    ver_seg = run_wait("version", STAGED_VER if STAGED_VER else "agnoshi", timeout=20)
    ver_live = bool(STAGED_VER) and STAGED_VER in after(ver_seg, "version")

    for title, seg in (("bnrmr AGNOS > /r37a", segw1), ("owl -p /r37a", segc1), ("bnrmr OS > /r37b", segw2),
                       ("owl -p /r37b", segc2), ("version", ver_seg)):
        p(f"=========== {title} segment ==========="); p(seg if seg.strip() else "(empty)")
    p("==========================================")
    # -d int exception census: count CPU exception vectors (v=00..1f) in the QEMU int log. The
    # SMP-fault signatures STEP-2 must produce ZERO of: #UD(06) #DF(08) #TS(0a) #NP(0b) #SS(0c)
    # #GP(0d) #PF(0e). (IRQs are v=20+, not counted.) A clean -smp 4 boot+#37s = 0 of these.
    # ⚠ VACUITY FLOOR, 2026-09-02. THE CENSUS IS A NEGATIVE ASSERTION OVER A PRODUCER WHOSE SUCCESS
    # IS NEVER CHECKED, AND UNTIL 1.56.58 AN EMPTY PRODUCER SCORED THE AFFIRMATIVE. `-d int -D QLOG`
    # is appended to the qemu argv above and its outcome is discarded three ways over: qemu's stdout
    # AND stderr go to DEVNULL, nothing ever reads qemu.poll(), and QLOG is read while the guest is
    # still running. So a QEMU that rejected `-d int` on this build, died inside OVMF before the
    # first exception, or could not create the file at all leaves `qlog = ""` — `re.findall` returns
    # [], `bad` stays {}, `len(bad) == 0` is True, and the run printed the affirmative string
    # "0 SMP-fault exceptions" and APPENDED IT TO THE PASS LINE. That is a clean bill of health
    # issued by a census that read zero bytes, and it is the same shape as the grep-that-matched-
    # nothing this sweep found in klug-spill-smoke.sh: an empty input set scoring as a clean run.
    # ⭐ THE DISCRIMINATOR WAS ALREADY IN HAND AND NEVER CONSULTED — IT IS THE DENOMINATOR. Every IRQ
    # is a `v=` record too (v=20+, deliberately NOT in the bad set), so any guest that got as far as
    # the firmware handoff logs them continuously: a timer tick alone is one record per 10 ms of TCG
    # wall clock, and this harness waits up to 120 s for the banner before it counts anything. A
    # total `v=` count near zero therefore says the LOG is broken, never that the kernel is clean.
    # ⚠ THE FLOOR IS DELIBERATELY FAR BELOW ANY REAL RUN rather than at a measured typical count: it
    # is here to separate "nothing was logged" from "something was logged", not to grade the boot, so
    # it can only ever fire on a producer that failed. And the count is PRINTED — into the verdict
    # line and into the PASS line — rather than implied, because "0 SMP-fault exceptions in 7 v=
    # records" is a run reporting that its own -d int producer broke, not that -smp 4 is clean.
    DINT_MIN_VECS = 32
    dint_ok = True
    dint_report = "(skipped — set RUN37_DINT=1)"
    if DINT:
        import re as _re
        try: qlog = open(QLOG, "r", errors="replace").read()
        except OSError: qlog = ""
        vecs = _re.findall(r"v=([0-9a-fA-F]{2})", qlog)
        bad = {}
        for mvec in vecs:
            iv = int(mvec, 16)
            if iv in (0x06, 0x08, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e):
                bad[iv] = bad.get(iv, 0) + 1
        names = {0x06:"#UD",0x08:"#DF",0x0a:"#TS",0x0b:"#NP",0x0c:"#SS",0x0d:"#GP",0x0e:"#PF"}
        if len(vecs) < DINT_MIN_VECS:
            # ⛔ NOT a clean census — an ABSENT one. Fail closed and name the log that is missing.
            dint_ok = False
            dint_report = (f"INCONCLUSIVE — censused {len(vecs)} v= records ({len(qlog)} B in "
                           f"{QLOG}), under the {DINT_MIN_VECS} floor: -d int logged nothing to "
                           "count, so this run proves NOTHING about SMP faults")
        elif bad:
            dint_ok = False
            dint_report = ", ".join(f"{names[k]}(v={k:#04x})x{bad[k]}" for k in sorted(bad)) + \
                          f" in {len(vecs)} v= records"
        else:
            dint_ok = True
            dint_report = f"0 SMP-fault exceptions in {len(vecs)} v= records"

    p("-d int SMP-fault exception census:", dint_report)
    p("staged agnsh version:", STAGED_VER or "(none found in build/rootfs/bin/agnsh)")
    p("1st #37 capture read back by owl -p (art chars):", rendered1, f"({art1})")
    p("2nd #37 capture read back by owl -p (art chars):", rendered2, f"({art2})")
    p("prompts returned after both #37s and both read-backs:", prompt_back1 and prompt_back2)
    p("version prints the staged version after the #37s:", ver_live)
    wit = "execwait: first scheduled child" in ser()
    wit_req = os.environ.get("RUN37_WITNESS", "required") != "optional"
    p("kernel witness 'execwait: first scheduled child' (the scheduled #37 route):", wit,
      "" if wit_req else "(OPTIONAL for this run — a pre-conversion kernel has no such line; scored on the rest)")
    wit_ok = wit or not wit_req
    # ⛔ 1.57.6 (S3-fix): the kernel's LATCHED invariant lines (scripts/smoke/lib/qemu-dwell.sh SMOKE_INVARIANT_DENY —
    # loaded below through _invdeny.py since 1.57.7, never copied) print once to klug + COM1 and change nothing else, so this harness scored PASS
    # with them firing until it grepped for them.
    import re as _re_inv
    # 1.57.7 (S3d): loaded from scripts/smoke/lib/qemu-dwell.sh through _invdeny.py — no pasted copy left to drift.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from _invdeny import smoke_invariant_deny
    INV_DENY = smoke_invariant_deny()
    inv_hits = [ln for ln in ser().splitlines() if _re_inv.search(INV_DENY, ln)]
    inv_ok = not inv_hits
    p("no latched kernel invariant line:", inv_ok, ("" if inv_ok else " -- " + " | ".join(inv_hits[:5])))
    if rendered1 and rendered2 and prompt_back1 and prompt_back2 and ver_live and wit_ok and dint_ok and inv_ok:
        # ⚠ the census verdict goes onto the PASS line VERBATIM (it was the fixed literal "0 SMP-fault
        # exceptions" until 1.56.58) so the record count that earned it travels with the claim.
        p("run37-smp4-test: PASS — two redirected foreground execwait#37s captured into their files and agnsh answered after both" + ("" if wit else " (witness optional: pre-conversion kernel)") + (f" + {dint_report} (-d int)" if DINT else ""))
        rc = 0
    else:
        p("run37-smp4-test: FAIL")
    s.sendall(b"quit\n"); time.sleep(0.2)
finally:
    qemu.terminate()
    try: qemu.wait(timeout=3)
    except subprocess.TimeoutExpired: qemu.kill()
sys.exit(rc)
