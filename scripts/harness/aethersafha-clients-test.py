#!/usr/bin/env python3
# aethersafha-clients-test.py — reproduce, IN QEMU, the iron failure where the desktop's setu
# clients spawn and never connect.
#
# ⛔ THE TRANSPORT THIS HARNESS EXERCISES IS RETIRED (2026-08-03). setu over TCP-on-loopback was a
# WRONG PREMISE and is being removed; the desktop transport is the agnos socket (naadi) — see agnos
# docs/development/planning/ipc.md §10. This file is NOT a gate and must not be run as one: a pass
# here would prove nothing about a transport that no longer exists. It is retained as the DIAGNOSIS
# — it is the harness that caught the rigging, and its comments are the record of how the rigging
# worked. Do not resurrect the TCP path on the strength of anything written below.
#
# ⛔ WHY THIS EXISTS. The now-deleted `scripts/smoke/aethersafha-setu-smoke.sh` PASSED: both clients
# connected and presented. That pass was a FALSE GREEN. It launched the compositor from the
# AETHERSAFHA_SETU_SELFTEST kernel hook (also deleted), which assigned net_ip = 0x7F000001 in the
# kernel first — the only reason the loopback handshake ever completed. On iron the operator
# launched it the way a person actually does — `aethersafha` at the agnsh prompt — and `--clients`
# returned 93 with NO output from either client at all. The smoke could never have caught that: it
# did not exercise the launch path a human uses, and it manufactured the address path besides.
#
# ⭐ The clients need NO GPU. `--clients` tests spawn_path + setu + scheduling, every one of which
# QEMU runs faithfully. There was no reason to spend a burn on this question and this harness is the
# apology for having done so.
#
# ⚠ crab's stdout DOES reach the console under the hook path ("crab: stat aethersafha ..."), so a
# client that runs says so. Silence from both clients means neither executed an instruction.
#
# Sequence, both at the agnsh prompt on ONE boot:
#   1. `aethersafha --clients`    -- foreground, via agnsh's blocking exec_and_wait
#   2. `aethersafha --clients &`  -- background, via the non-blocking spawn_path #43 that
#                                    agnsh-bg-test.py proves keeps the prompt live
# Each run self-terminates on its own 30 s budget and prints `run: exit N`.
#   95 both clients presented · 94 one · 93 neither · 92 no listener · 91 spawn refused
#
# PASS is not "the desktop worked" — it is "the two launch paths were compared and the result is
# unambiguous". Read the printed verdict.
import os, socket, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GNOBOOT = os.environ.get("GNOBOOT_ROOT", os.path.join(ROOT, "../gnoboot")) + "/build/BOOTX64.EFI"
AGNOS = os.path.join(ROOT, "build/agnos")
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK = os.path.join(ROOT, "build/ae-clients")
IMG = os.path.join(WORK, "agnos-ae-clients.img")
SEED = os.path.join(WORK, "seed")
SER = os.path.join(WORK, "serial.log")
MON = "/tmp/agnos-ae-clients.sock"
PART_OFFSET = 33 * 1048576
# ⚠ The compositor is ~15 MB and the two clients another ~0.4 MB, so this image is much larger than
# the 128 MB the other agnsh harnesses use. An ext2 that cannot hold /bin/aethersafha fails at
# mkfs time, not at boot, which is at least loud.
# ⛔ ONE MODE PER BOOT. Default is "bg". Running fg then bg in the same boot does NOT work and is
# not a finding: the foreground run leaves its two spawned clients orphaned and spinning (they were
# never scheduled enough to connect, and nothing reaps them), and they interfere with the next run —
# bg then reports "launched: False" on a boot where it reaches 2/2 cleanly on its own.
# Use AE_CLIENTS_MODE=fg / =bg in separate invocations to compare the paths.
MODE = os.environ.get("AE_CLIENTS_MODE", "bg")   # "fg" | "bg" | "both" (both = same-boot, interferes)

# ⛔ THE FRAMEBUFFER GATE FOR `desktop` MODE — how many pixels carrying a CLIENT's own colours must
# be on the panel before this harness will exit 0. Only `desktop` mode uses it, because it is the
# only mode that still has a compositor on screen when the screendump fires (see the FRAMEBUFFER
# block). Calibrated against a measured null and a measured signal on this box; both numbers are
# recorded beside the gate below. Override with AE_CLIENTS_FBMIN to re-calibrate on other hardware
# rather than editing this line — and if you raise it to make a run pass, you have broken the gate.
# Signal 3,500 · null 0 (both measured 2026-08-05, agnos 1.56.39, this box). 200 sits ~17x under
# the signal and well clear of the null. ⚠ bright-green reads 0 even on a PASSING run, so the red
# bar is currently carrying this gate alone — if present_probe ever stops animating it, the gate
# goes dark rather than red, and this comment is the only warning of that.
FB_CLIENT_PX_MIN = int(os.environ.get("AE_CLIENTS_FBMIN", "200"))
DISK_MB = 512
PART_BLOCKS = ((DISK_MB - 33) * 1048576) // 4096
EXT2_FEATURES = os.environ.get("EXT2_SMOKE_FEATURES", "^resize_inode,^dir_index,^huge_file,^metadata_csum,^64bit")

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

# ⛔ THE KERNEL MUST BE BARE, and this check exists because the first run of this harness silently
# tested the wrong thing. The retired `aethersafha-setu-smoke.sh` rebuilt build/agnos with
# AETHERSAFHA_SETU_SELFTEST=1 — a kernel that auto-runs the compositor at boot, never reaches agnsh,
# and assigns net_ip = 0x7F000001 so the loopback handshake succeeds. The harness booted it, saw no
# banner, and reported "no agnsh banner" as if the boot were broken. That define and that smoke are
# GONE (2026-08-03) and must not return; this guard stays as the tripwire, because a kernel carrying
# any such hook does not fail this test, it INVALIDATES it.
# ⚠ It also means running any smoke after burn-prep clobbers the staged burn artifact — re-run
# burn-prep before flashing.
with open(AGNOS, "rb") as _f:
    _blob = _f.read()
if b"run /bin/aethersafha" in _blob or b"setu-e2e" in _blob:
    print("FAIL: build/agnos carries an AETHERSAFHA selftest hook — it auto-runs the compositor and")
    print("      never reaches agnsh, so this harness would test nothing. Rebuild bare:")
    print("        sh scripts/build.sh")
    sys.exit(1)

for need in (AGNOS, os.path.join(ROOTFS, "bin", "aethersafha"),
             os.path.join(ROOTFS, "bin", "puka"), os.path.join(ROOTFS, "bin", "crab")):
    if not os.path.exists(need):
        print(f"FAIL: missing {need} — run scripts/burn/stage-tools.sh"); sys.exit(1)

subprocess.run(["rm", "-rf", WORK]); os.makedirs(WORK, exist_ok=True)
subprocess.run(["cp", "-a", ROOTFS, SEED])
sh(f"dd if=/dev/zero of={IMG} bs=1M count={DISK_MB} status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100%")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-AEC -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
subprocess.run(["cp", OVMF_VARS, os.path.join(WORK, "vars.fd")])
subprocess.run(["chmod", "+w", os.path.join(WORK, "vars.fd")])
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass
print(f"built image: {IMG}")

qemu = subprocess.Popen([
    # ⛔ CPU COUNT IS A LIVE VARIABLE, and it was silently 1 for every run of this harness while
    # archaemenid reports `smp: cpus online: 4`. The 2026-08-02 desktop burn died at the nested
    # spawn_path with `exit 142` where this harness reaches 2/2 — and SMP was one of only three
    # differences (the others being a real GPU and 62 GB of RAM). A single-CPU harness cannot see
    # a scheduling or per-CPU-state race, which is precisely the class that shows up when a
    # scheduler-entered proc spawns another. AE_CLIENTS_SMP=4 matches iron.
    "qemu-system-x86_64", "-machine", "q35", "-m", "2048M", "-cpu", "max",
    "-smp", os.environ.get("AE_CLIENTS_SMP", "1"),
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-AEC",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
    # ⛔ THE NIC IS LOAD-BEARING FOR A LOOPBACK TEST, which is not obvious and cost a cycle.
    # agnos picks the SOURCE address for an outbound SYN from `net_ip`. With no NIC there is no
    # DHCP, `net_ip` stays 0, and the peer's SYN-ACK goes to dst=0 — which fails `net_is_loopback`
    # (it wants dst>>24==127, or dst==net_ip which is 0 and explicitly excluded) — so the reply is
    # handed to `nic_send` and dropped. The connect then fails for a reason that has nothing to do
    # with the desktop.
    # ⛔ THIS IS THE RIGGING ITSELF. `AETHERSAFHA_SETU_SELFTEST` hid the above by assigning
    # `net_ip = 0x7F000001` in the kernel hook before it launched the compositor. That fixup existed
    # ONLY in that selftest, so the smoke NEVER exercised the address path a real boot takes — an
    # ordinary boot's compositor↔client handshake could not complete at all. Every green tied to that
    # smoke was a false green, and it is why setu-over-TCP is retired in favour of naadi. The define,
    # the hook and the smoke were deleted 2026-08-03; nothing here is a reason to restore them.
    # ⭐ archaemenid has a live r8169 and DHCPs to a real address, so a NIC here matches iron.
    "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0",
    "-serial", f"file:{SER}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

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
    km = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '/': 'slash', '&': 'shift-7'}
    def typ(word, settle=2.0):
        for ch in word:
            key = km.get(ch, ch)
            if ch.isupper(): key = "shift-" + ch.lower()
            s.sendall(("sendkey " + key + "\n").encode())
            time.sleep(0.10); drain()
        time.sleep(settle)
    def run_wait(cmd, marker, timeout=90):
        m = len(ser()); typ(cmd, settle=1.0)
        deadline = time.time() + timeout
        while time.time() < deadline:
            seg = ser()[m:]
            if marker is not None and marker in seg:
                # ⚠ Let the tail land. `run: exit` and its NUMBER arrive as separate writes, and
                # returning on the marker alone captured "run: exit" with no code — which the parser
                # then reported as exit None, i.e. "it never finished", for a run that had finished.
                time.sleep(2.0)
                return ser()[m:]
            time.sleep(0.5)
        return ser()[m:]

    ok = False
    for _ in range(600):
        if "agnoshi" in ser(): ok = True; break
        time.sleep(0.25)
    p("banner seen:", ok)
    if not ok: p("FAIL: no agnsh banner"); sys.exit(1)
    time.sleep(1.5)

    def verdict(seg, label):
        code = None
        # ⛔ DO NOT ANCHOR THIS TO THE START OF A LINE. agnos prints from several procs onto one
        # console with no locking, so `run: exit 142` routinely lands MID-LINE — a real capture
        # read `aethersafha: a11y nodes synced:run: exit 142`, which `startswith` missed, so the
        # run reported exit=None, the klug dump was skipped, and the fault evidence was discarded
        # on a boot that had produced it. Search anywhere in the segment instead.
        import re as _re
        for m in _re.finditer(r"run: exit (-?\d+)", seg):
            try: code = int(m.group(1))
            except ValueError: pass
        p(f"  [{label}] launched   :", "launched setu client #1" in seg)
        p(f"  [{label}] connected  :", seg.count("setu client connected"))
        p(f"  [{label}] presented  :", seg.count("setu client presented surface"))
        p(f"  [{label}] client says:", ("crab:" in seg) or ("present_probe:" in seg))
        p(f"  [{label}] exit       :", code)
        # ⚠ The BACKGROUND path has no `run: exit` — that line is execwait's. agnsh prints
        # "[1] Done" and the compositor reports itself, so judge bg on presented surfaces.
        if code is None and seg.count("setu client presented surface") >= 2: return 95
        if code is None and seg.count("setu client presented surface") == 1: return 94
        return code

    fg_code = None
    bg_code = None
    # ⛔ WHICH ARMS ACTUALLY RAN — set at the launch sites below, never re-derived from MODE at
    # verdict time. `fg_code is None` is AMBIGUOUS on its own: it means "this arm was not run in
    # this mode" AND "this arm ran and never produced an exit code". Those are opposite facts and
    # the verdict block used to conflate them, which is how a bg-only run printed a confident
    # causal claim about the foreground path (see the verdict block for the full case).
    ran_fg = False
    ran_bg = False
    if MODE in ("fg", "both"):
        # FOREGROUND: agnsh execwait #37 — the blocking primitive, the path the iron burn used.
        ran_fg = True
        p("foreground `aethersafha --clients` (agnsh execwait #37)...")
        fg = run_wait("aethersafha --clients\n", "run: exit", timeout=150)
        fg_code = verdict(fg, "fg")
        time.sleep(3.0)
    if MODE == "desktop":
        # ⛔ THE ONLY TEST THAT CAN SHOW A DESKTOP. `--clients` STOPS as soon as both clients
        # connect (1.09 s in practice), so any screendump taken after it is a picture of the
        # console, not of a desktop — that is how a "0 client pixels" reading got produced from a
        # run that had already ended. Launch the REAL desktop, which never exits, and capture it
        # while it is still on screen.
        # ⚠ Backgrounded, so agnsh keeps the console and keeps writing to the SAME framebuffer.
        # Whatever this shows, it is a desktop competing with a live console for the screen.
        # ⛔ NO `&`. Backgrounding the desktop was a workaround for agnsh holding the scheduler in
        # execwait #37, and asking a person to background their desktop is not a fix. agnsh now
        # launches the foreground via spawn_path + a non-blocking waitpid poll, so this is the
        # invocation a human actually types.
        p("desktop `aethersafha` (FOREGROUND, no &) — capture WHILE it runs...")
        typ("aethersafha\n", settle=1.0)
        for _w in range(24):
            if "setu client presented surface" in ser(): break
            time.sleep(1.0)
        time.sleep(6.0)
        bg = ser()
        bg_code = verdict(bg, "desktop")
    if MODE == "armed":
        # ⭐ THE ARMED-STATE TEST, and the reason every other mode in this file was blind to a real
        # kernel defect: they all launch the compositor as the FIRST command of the boot.
        #
        # `syscall_kstack_reserve` (syscall_hw.cyr) sets each CPU's SYSCALL kstack to the DIRECT-MAP
        # VA, deliberately, because region 7's identity VA (14-16 MB) lies inside the user-segment
        # range and a large binary's PT_LOADs override that PD entry in its own per-proc CR3. Until
        # 1.56.35 the execwait #37 handler's step (h) restored the RAW identity VA instead, so a
        # completed FOREGROUND run silently re-armed the pre-1.51.x fault for the rest of the boot.
        # Any proc whose image reaches past 0xF10000 (15.06 MB) then #PF'd at CPL0 on its next
        # syscall. /bin/aethersafha is 14.87 MB loaded at >= 2 MB — the first binary in this system
        # big enough to be in range, which is why nothing else ever tripped it.
        #
        # So: run a SMALL program to completion through #37 first (arming the pointer), THEN launch
        # the compositor. On a kernel without the fix this is expected to fault where plain "bg"
        # mode passes; that difference IS the test.
        # ⛔ The marker must be something the ARMING PROGRAM prints. The first cut waited for
        # "run: exit", which agnsh emits ONLY on a non-zero code — so a SUCCESSFUL `iam` printed
        # nothing, the step reported "completed: False", and the run could not testify that the
        # pointer was ever armed. The verdict was unfalsifiable in the direction that mattered.
        p("arming: foreground `iam` via execwait #37 (restores the CPU's syscall kstack)...")
        arm = run_wait("iam\n", "Distro: AGNOS", timeout=90)
        armed_ok = "Distro: AGNOS" in arm
        p("  [arm] foreground run completed:", armed_ok)
        if not armed_ok:
            p("  ⛔ ARMING DID NOT RUN — this boot tests nothing. Do not read the verdict below.")
        time.sleep(2.0)
        p("background `aethersafha --clients &` AFTER a completed foreground run...")
        bg = run_wait("aethersafha --clients &\n", "probe ran for milliseconds", timeout=180)
        bg_code = verdict(bg, "armed")
    if MODE in ("bg", "both"):
        # BACKGROUND: agnsh routes a trailing `&` to spawn_path #43 (run_agnos.cyr:172), so the
        # compositor becomes an independently scheduled proc — the same shape as the kernel hook.
        # ⚠ There is no `run: exit` here: execwait is what prints that. agnsh prints "[1] <pid>" and
        # the compositor reports its own verdict, so gate on the compositor's exit print instead.
        ran_bg = True
        p("background `aethersafha --clients &` (agnsh spawn_path #43)...")
        bg = run_wait("aethersafha --clients &\n", "probe ran for milliseconds", timeout=180)
        bg_code = verdict(bg, "bg")

    # ⭐ IF ANYTHING WAS FAULT-KILLED, GET THE ADDRESS. `fault_kill_current` records
    # `fault: pid=.. vec=.. cr2=0x..` into the klug ring and CANNOT print it (the FB may be
    # unmapped under the faulting proc's CR3), so the ring is the only copy. Dumping it costs one
    # command and turns `exit 142` — which names only the vector — into a located fault.
    # ⭐ AE_CLIENTS_KLUG=1 dumps the ring on a PASSING run too. Added 2026-08-03 for ELF_PDE_PROBE:
    # a diagnostic must be provable against a KNOWN answer before its output is trusted, and the
    # known answer here is the -smp 1 boot that passes. Without this the probe's PDE lines only ever
    # surface on the failing run — i.e. exactly the run whose output you cannot yet believe.
    want_klug = (fg_code == 142) or (bg_code == 142) or os.environ.get("AE_CLIENTS_KLUG") == "1"
    if want_klug:
        p("dumping the klug ring...")
        typ("klug\n", settle=1.0)
        time.sleep(8.0)
        n_match = 0
        n_mismatch = 0
        for line in ser().splitlines():
            kl = line.strip()          # ⚠ NOT `s` — that name is the monitor socket further down
            if kl.startswith("fault: pid="):
                p("  ⇒", kl)
            if "DESTROYED_LIVE" in kl:
                p("  ⛔", kl)
            if "PD510 " in kl:
                p("  ●", kl)
            if "CR3INST" in kl:
                p("  ◆", kl)
            if "CR3BAD" in kl:
                p("  ⛔", kl)
            if "PDWATCH" in kl:
                p("  ◉", kl)
            if "MMAPHI" in kl:
                p("  ⛔", kl)
            if "TLBSHOOT" in kl:
                p("  ⚑", kl)
            if "PDTRIP" in kl:
                p("  ⛔", kl)
            if "pdaudit" in kl:
                p("  ▣", kl)
            if "PTSELFTEST" in kl:
                p("  ✔", kl)
            if "PTREISSUE" in kl or "PTREISSUE2M" in kl:
                p("  ⛔", kl)
            if ("asalloc" in kl) or ("asfree" in kl):
                p("  ‖", kl)
            if "pdeprobe" in kl:
                p("  ·", kl)
                if kl.endswith("MATCH"):
                    n_match += 1
                else:
                    n_mismatch += 1
                    p("  ⇒", kl)
        if (n_match + n_mismatch) > 0:
            p("  pdeprobe: %d MATCH, %d MISMATCH" % (n_match, n_mismatch))

    # ⛔ SERIAL IS THE COMPOSITOR'S OWN CLAIM, NOT EVIDENCE OF PIXELS. "setu client presented
    # surface" is printed by the same program being judged — a shared-premise oracle. The setu smoke
    # already reported "0 green-border pixels ... NOTE: green border not detected" and dismissed it
    # as "serial gate is dispositive", which is precisely backwards: the FRAMEBUFFER is the external
    # invariant here. Capture it and count present_probe's own colours.
    # None means "no framebuffer evidence at all" — a missing or unparsable screendump. Kept
    # distinct from 0, which means "captured, and there were no client pixels in it". The desktop
    # gate must not pass on the first and must not confuse it for the second.
    fb_client_px = None
    time.sleep(2.0)
    PPM = os.path.join(WORK, "screen.ppm")
    s.sendall((f"screendump {PPM}\n").encode()); time.sleep(4.0); drain()
    if os.path.exists(PPM):
        with open(PPM, "rb") as f: raw = f.read()
        # P6 header: magic, w h, maxval, then RGB triples
        parts = raw.split(b"\n", 3)
        try:
            wh = parts[1].split()
            pw, ph = int(wh[0]), int(wh[1])
            px = parts[3]
            def hits(pred):
                n = 0
                for i in range(0, min(len(px), pw*ph*3) - 2, 3):
                    if pred(px[i], px[i+1], px[i+2]): n += 1
                return n
            # present_probe: bright-green border 0x0000FF00, dim-green 0x00003000,
            # red bar 0x00FF0000, blue bar 0x000000FF, dark grid 0x00202020.
            green  = hits(lambda r,g,b: g > 180 and r < 80 and b < 80)
            dimgrn = hits(lambda r,g,b: 30 <= g <= 80 and r < 40 and b < 40)
            redbar = hits(lambda r,g,b: r > 180 and g < 80 and b < 80)
            bluebar= hits(lambda r,g,b: b > 180 and r < 80 and g < 80)
            nonblk = hits(lambda r,g,b: r+g+b > 24)
            p("")
            p(f"=== FRAMEBUFFER ({pw}x{ph}) ===")
            p(f"  bright-green border px : {green}")
            p(f"  dim-green border px    : {dimgrn}")
            p(f"  red bar px             : {redbar}")
            p(f"  blue bar px            : {bluebar}")
            p(f"  non-black px           : {nonblk}")
            p(f"  PPM: {PPM}")
            # ⛔ dimgrn IS DELIBERATELY EXCLUDED, and this is the whole design of the gate.
            # Measured on this box 2026-08-05, MODE=desktop with both clients presented:
            # dim-green 952,731 px of a 2048x2048 capture (22.7% of the screen). A client's 1-px
            # BORDER cannot be 22.7% of the panel, so that count is dominated by something that is
            # not the client — almost certainly the compositor's own chrome, which sits in the same
            # dark-green range. Gating on it would pass a desktop that came up and hosted NOTHING,
            # and that is not hypothetical: aethersafha 0.12.0 fixed exactly that state (a leaked
            # listener made run 2 host nothing while looking completely healthy — desktop.md §4).
            # ⚠ I did not produce a hosting-nothing desktop to measure dim-green against, so this is
            # reasoned from the pixel count, not from a measured negative control. Stated as such.
            # What survives is present_probe's own BARS and bright border — colours the chrome does
            # not use. Measured: signal 3,500 px (red bar), console null 0 px across two runs
            # (MODE=fg and MODE=bg, where the capture is of the console after --clients exited).
            fb_client_px = green + redbar + bluebar
            # ⛔ WHAT THESE NUMBERS MEAN DEPENDS ENTIRELY ON THE MODE, AND A BARE ZERO READS AS A
            # FAILURE IN EVERY MODE. `--clients` STOPS the instant both clients have presented
            # (~1.09 s), so in fg/bg/both/armed the screendump lands seconds AFTER the run ended and
            # is a picture of the CONSOLE. Zero client pixels there is the EXPECTED result and says
            # nothing about the desktop — that exact reading was once taken as evidence of failure.
            # Only `desktop` mode keeps a compositor on screen while this fires, so only there are
            # these counts an oracle. Say which case this is, every time.
            if MODE == "desktop":
                p("  ⇒ THIS is the mode these counts are an oracle for — a live desktop is on screen.")
            else:
                p(f"  ⇒ MODE={MODE}: `--clients` had ALREADY EXITED when this was captured, so this is a")
                p("    picture of the console, not of a desktop. Zero client pixels here is EXPECTED")
                p("    and is NOT evidence about the desktop. Use AE_CLIENTS_MODE=desktop for pixels.")
        except Exception as e:
            p("screendump parse failed:", e)
    else:
        p("NO SCREENDUMP PRODUCED")

    p("")
    p("=== VERDICT ===")
    if MODE == "desktop":
        # ⛔ Do not reuse the fg/bg comparison here — desktop mode runs neither, and printing that
        # line anyway produced a verdict that flatly contradicted the run it came from.
        serial_ok = (bg_code == 95)
        p(f"  serial (the compositor's own claim): clients presented = {'2+' if serial_ok else 'FEWER THAN 2'}")
        # ⛔ AND NOW GATE ON THE FRAMEBUFFER, which this block previously only told the reader to
        # "judge on" — advice, not a gate, so the exit code still rested entirely on the serial line
        # the compositor prints about itself. Serial is a shared-premise oracle: the program being
        # judged is the program making the claim. The framebuffer is the external invariant, and in
        # THIS mode (and only this mode) a live desktop is still on screen when it is captured.
        # A run whose serial says "presented" while the panel carries none of the client's own
        # colours has not shown a desktop, and must not exit 0.
        if fb_client_px is None:
            p("  ⛔ NO FRAMEBUFFER EVIDENCE — screendump missing or unparsable. Cannot pass on serial alone.")
            rc = 1
        else:
            fb_ok = (fb_client_px >= FB_CLIENT_PX_MIN)
            p(f"  framebuffer (external): {fb_client_px} client-coloured px "
              f"(need >= {FB_CLIENT_PX_MIN}) -> {'PASS' if fb_ok else 'FAIL'}")
            if serial_ok and not fb_ok:
                p("  ⛔ SERIAL SAYS PRESENTED, THE PANEL DOES NOT. Believe the panel — the compositor")
                p("     is the thing under test and its own claim cannot corroborate itself.")
            rc = 0 if (serial_ok and fb_ok) else 1
        raise SystemExit(rc)
    if MODE == "armed":
        # ⛔ Do NOT fall through to the fg/bg comparison — this mode runs neither of those, and the
        # shared verdict block reports "Neither path reached 95" for a single-mode run, which reads
        # as a desktop failure when it only means "the other mode was not run in this boot".
        ok = (bg_code == 95)
        p(f"  after a completed foreground #37, backgrounded clients presented: {'2 (PASS)' if ok else 'FEWER THAN 2 (FAIL)'}")
        p("  Compare against AE_CLIENTS_MODE=bg on the same kernel: bg passing while armed fails")
        p("  means the completed foreground run — not the compositor — broke the following proc.")
        rc = 0 if ok else 1
        raise SystemExit(rc)
    # ⛔ AN ARM THAT DID NOT RUN IS NOT AN ARM THAT FAILED, AND MUST NOT APPEAR IN A CONCLUSION.
    # The default mode is "bg" and fg/bg are meant to be run in SEPARATE invocations, so on almost
    # every run one of these two codes is None purely because that arm was never launched. The
    # earlier block tested the codes alone and produced two false verdicts, both observed on
    # 2026-08-05 against agnos 1.56.39 while BOTH arms independently reached 95:
    #   AE_CLIENTS_MODE=bg -> "Backgrounded works; FOREGROUND does not." plus the causal claim
    #                         "⇒ agnsh's blocking execwait #37 frame prevents the spawned clients
    #                         being scheduled" — invented for an arm that was never launched.
    #   AE_CLIENTS_MODE=fg -> "Both clients present on BOTH launch paths." — from one path.
    # This is the same defect the `desktop` and `armed` guards above were each added to fix, in the
    # one block those guards jump over. An instrument that overstates its own coverage is worse than
    # no instrument: it is a false green and a false red from the same run.
    p("  foreground exit " + (str(fg_code) if ran_fg else "— (not run in this mode)")
      + " · background exit " + (str(bg_code) if ran_bg else "— (not run in this mode)"))

    rc = 0
    for ran, code, name, how in ((ran_fg, fg_code, "FOREGROUND", "agnsh execwait #37"),
                                 (ran_bg, bg_code, "BACKGROUND", "agnsh spawn_path #43")):
        if not ran:
            continue
        if code == 95:
            p(f"  {name} ({how}): both clients connected and presented.")
            continue
        rc = 1
        if code is None:
            # RAN and produced nothing — a real failure, and a different one from "not run".
            p(f"  {name} ({how}): FAILED — ran, but never reported an exit code (stall or timeout).")
            continue
        p(f"  {name} ({how}): FAILED — exit {code}. 93/91 point at different repos; see §7 of "
          "aethersafha planning/desktop.md.")

    # The cross-path comparison is the ONLY claim that needs both arms, so it is the only one gated
    # on both having run. One mode per boot is the documented way to use this harness, so this line
    # is normally absent — and its absence is not a result.
    if ran_fg and ran_bg:
        if fg_code == 95 and bg_code == 95:
            p("  ⇒ Both launch paths work. (⚠ MODE=both runs them in ONE boot and they interfere; "
              "the file documents this. Prefer separate fg/bg invocations.)")
        elif bg_code == 95 and fg_code != 95:
            p("  ⇒ Backgrounded works and foreground does not, IN THE SAME BOOT — consistent with "
              "agnsh's blocking execwait #37 frame holding the spawned clients off the scheduler, "
              "but MODE=both is known to interfere. Confirm with separate fg and bg runs before "
              "believing it.")
    elif rc == 0:
        p(f"  ⇒ Only the {'foreground' if ran_fg else 'background'} path was exercised. "
          "The other says nothing either way — run it separately to cover it.")
finally:
    try: qemu.terminate(); qemu.wait(timeout=10)
    except Exception:
        try: qemu.kill()
        except Exception: pass
p(f"serial: {SER}")
sys.exit(rc)
