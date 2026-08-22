#!/usr/bin/env python3
# puka-child-stdout-test.py — does a program agnsh LAUNCHES reach puka's window?
#
# Derived from puka-terminal-test.py (same boot + oracle). ⛔ Exits INCONCLUSIVE (2) rather than
# passing when the scene did not set up — a harness must not score a test it did not perform.
#
# aethersafha hosts /bin/puka; puka opens a setu window, mints a PTY on the `#97` channel band, spawns
# /bin/agnsh onto it, and paints the shell's output as glyphs into the window it presents.
#
# ⛔ THIS IS NOT THE DESKTOP GATE, AND ITS ORACLE IS DIFFERENT ON PURPOSE. It began as a copy of
# aethersafha-clients-test.py, whose framebuffer oracle counts setu `present_probe`'s bright-green
# border and bars — and puka REPLACES present_probe in the /bin/puka slot, so that oracle asks the
# wrong question here and reported "FEWER THAN 2" on a run where everything worked. The oracle below
# counts puka's own GLYPH colour instead.
#
# ⭐ THE ORACLE IS EXACT RGB (192,192,192) — puka's default foreground (`fb_def_fg`, xterm light grey).
# Negative control, measured: the same desktop WITHOUT puka has **0** such pixels; with puka it has
# ~5000. Nothing else on screen uses it — the compositor's chrome is dark greys and cyan — so a
# nonzero count means glyphs were rasterised and composited, not merely that a window appeared.
import os, socket, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GNOBOOT = os.environ.get("GNOBOOT_ROOT", os.path.join(ROOT, "../gnoboot")) + "/build/BOOTX64.EFI"
AGNOS = os.path.join(ROOT, "build/agnos")
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK = os.path.join(ROOT, "build/puka-term")
IMG = os.path.join(WORK, "agnos-puka-term.img")
SEED = os.path.join(WORK, "seed")
SER = os.path.join(WORK, "serial.log")
MON = "/tmp/agnos-puka-term.sock"
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
# ⭐ OVERRIDE /bin/puka WITH THE REAL TERMINAL, IN THIS SEED ONLY.
# ⛔ The shared rootfs stages setu's slim `present_probe` under the name `/bin/puka` — the
# "first-resident slot", reserved back when full puka could not build for agnos at all (a `mabda` dep
# whose DRM path needs `SYS_IOCTL`, which agnos does not have; removed in puka 0.6.8). The compositor
# spawns `/bin/puka` by that literal name, so hosting the real terminal means overriding the slot.
# ⚠ Deliberately NOT changed in stage-tools.sh: aethersafha-clients-test.py's framebuffer oracle
# counts present_probe's own bright-green border and bars, so swapping the shared rootfs would
# silently invalidate a green gate. One harness, one override.
_puka = os.path.join(ROOT, "../puka/build/puka_agnos")
if not os.path.exists(_puka):
    print("FAIL: missing", _puka, "(cd ../puka && cyrius build --agnos src/main.cyr build/puka_agnos)")
    sys.exit(1)
subprocess.run(["cp", _puka, os.path.join(SEED, "bin", "puka")])
subprocess.run(["chmod", "+x", os.path.join(SEED, "bin", "puka")])
print("seed: /bin/puka overridden with the real terminal")
sh(f"dd if=/dev/zero of={IMG} bs=1M count={DISK_MB} status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100%")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-PUKATERMC -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
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
    "-device", "nvme,drive=disk0,serial=AGNOS-PUKATERMC",
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
        # ⛔ MARKERS UPDATED FOR THE CHANNEL BAND (agnos 1.56.40 bite 7). The old ones were
        # "launched setu client #1" and "setu client connected" — both are strings the TCP cutover
        # DELETED, so this harness reported `launched: False, connected: 0` on a boot where both
        # clients had in fact been spawned on placed channels. A stale marker does not read as a
        # broken measurement; it reads as a broken kernel, which is strictly worse.
        # ⚠ "connected" no longer EXISTS as an event: there is no accept, and a channel is live from
        # the instant it is minted — before the client runs. What can be counted is placement and
        # presentation, so the middle counter now reports placements.
        p(f"  [{label}] launched   :", "client spawned on a placed channel" in seg)
        p(f"  [{label}] placed     :", seg.count("client spawned on a placed channel"))
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
        # ⛔⛔ NOTHING IS PRE-LOADED ANY MORE, AND THIS HARNESS DID NOT KNOW THAT. Bare `aethersafha`
        # only auto-spawns clients under `--clients` (`ae_probe == 1`); since the launcher landed the
        # desktop comes up EMPTY and says so ("launcher ready -- F2 lists the apps, nothing
        # pre-loaded"). The first run of this test typed into a desktop with no client at all and the
        # compositor said exactly that: "TAB ignored -- fewer than two windows".
        # ⛔ `--clients` is NOT the fix: it terminates the moment both clients connect, so there is no
        # desktop left to type into. ⇒ Drive the LAUNCHER, which is the path a person actually uses:
        # F2 opens it, `/bin/puka` is registered FIRST so it is already selected, Enter launches it.
        _boot_hold = int(os.environ.get("PUKA_KEY_HOLD_MS", "500"))
        time.sleep(4.0)
        for _k in ("f2", "ret"):
            s.sendall((f"sendkey {_k} {_boot_hold}\n").encode())
            time.sleep(_boot_hold / 1000.0 + 1.5); drain()
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
    # ⛔ WAIT FOR THE EVENT, DO NOT RACE THE CLOCK. Captured on a fixed delay this gate is FLAKY: one
    # run in three landed the screendump before puka's first present and reported 0 glyph px on a boot
    # where everything worked, which reads as a rendering failure rather than a capture taken too
    # early. Two consecutive re-runs then gave 4991 each. A timing-dependent oracle that sometimes
    # says zero is worse than no oracle — it teaches you to distrust a real red.
    # puka prints "first present ok" exactly once, after its first successful COMMIT, so waiting on
    # that marker makes the capture deterministic instead of hopeful.
    _deadline = time.time() + 60
    while time.time() < _deadline:
        try:
            if "puka: first present ok" in open(SER, "rb").read().decode("latin1"): break
        except OSError: pass
        time.sleep(0.5)
    else:
        p("  ⚠ puka never reported a first present within 60 s — capturing anyway, so the")
        p("    framebuffer count below is evidence about THAT, not about the renderer.")
    time.sleep(1.5)                    # let a frame or two land after the first commit
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
        # ⭐ THREE INDEPENDENT WITNESSES, AND THE LAST ONE IS THE ONLY EXTERNAL ONE.
        #   1. puka's own markers      — it opened a window and put a shell on a PTY
        #   2. the compositor's claim  — it presented a client surface
        #   3. the FRAMEBUFFER         — puka's glyph colour is actually on the panel
        # 1 and 2 are self-reports by the programs under test. 3 is the invariant: a run where both
        # programs claim success and the panel carries no glyphs has not shown a terminal.
        ser = ""
        try: ser = open(SER, "rb").read().decode("latin1")
        except OSError: pass

        term_up   = "puka: terminal up" in ser
        presented = "puka: first present ok" in ser
        comp_saw  = "setu client presented surface" in ser

        p(f"  puka opened a window + PTY : {term_up}")
        p(f"  puka presented its surface : {presented}")
        p(f"  compositor saw a client    : {comp_saw}")

        # ⛔ puka REPORTS ITS OWN FAILURES, and each names a different cause. Surfacing them here is
        # most of this gate's diagnostic value — "no terminal" otherwise looks identical whether the
        # display, the pty, or the shell was the problem.
        for marker, why in (
            ("setuwin: setu connect refused", "setu refused the connection — a pre-0.8.0 setu has no agnos arm at all"),
            ("puka: no display",              "win_open failed — no compositor, or the client was not endowed a channel"),
            ("puka: no pty",                  "pty_open failed — the kernel would not mint a channel"),
            ("puka: shell would not spawn",   "pty_spawn failed — /bin/agnsh missing, or spawn_path refused it"),
            ("puka: first present REFUSED",   "the compositor rejected the surface"),
        ):
            if marker in ser:
                p(f"  -> {why}")

        # ⭐ THE EXTERNAL ORACLE: exact RGB (192,192,192), puka's `fb_def_fg`. Measured negative
        # control — the same desktop WITHOUT puka has 0 of these; with puka, ~5000.
        glyph_px = None
        try:
            d = open(os.path.join(WORK, "screen.ppm"), "rb").read()
            k = d.index(b"255\n") + 4
            hdr = d[:k].split(); gw, gh = int(hdr[1]), int(hdr[2])
            px = d[k:]
            glyph_px = sum(1 for q in range(0, gw * gh * 3 - 3, 3)
                           if px[q] == 192 and px[q + 1] == 192 and px[q + 2] == 192)
        except Exception as e:
            p("  glyph-pixel scan failed:", e)

        # ⭐⭐ INPUT PHASE — does a KEYSTROKE reach the shell? Typing must make the terminal render
        # MORE glyphs than it did at rest, because agnsh echoes and answers. Comparing two captures of
        # the same screen is an external oracle for the whole chain: QEMU key -> compositor ->
        # SETU_INPUT_KEY -> puka's HID->evdev map -> input_from_keycode -> pty_write -> agnsh -> its
        # output back over the PTY -> term_feed -> fb_render -> composited.
        # ⛔ TAB FIRST. The compositor focuses the LAST client it added (crab), and forwards keys only
        # to the focused window — so without cycling focus this types into the wrong client and the
        # count would not move for a reason that has nothing to do with puka's input path.
        def glyphs():
            try:
                d = open(os.path.join(WORK, "screen.ppm"), "rb").read()
                k = d.index(b"255\n") + 4
                hd = d[:k].split(); gw, gh = int(hd[1]), int(hd[2]); q = d[k:]
                return sum(1 for j in range(0, gw * gh * 3 - 3, 3)
                           if q[j] == 192 and q[j + 1] == 192 and q[j + 2] == 192)
            except Exception:
                return None

        # ⛔⛔ A PIXEL COUNT IS BLIND TO LAYOUT, AND THAT BLINDNESS SHIPPED A BUG TO IRON.
        # The 2026-08-07 burn rendered agnsh's output as a STAIRCASE — every line beginning where the
        # previous one ended, then breaking mid-word at the right edge — because puka had no ONLCR and
        # agnos's kernel console had made a bare LF mean newline-and-carriage-return for every program
        # ever written against it. ⭐ THIS HARNESS PASSED THAT RUN with byte-identical counts
        # (4991 -> 5176 -> 6032, before and after the fix), because a staircase draws **exactly the same
        # characters** — it only puts them in the wrong places. The operator's eye caught what the gate
        # structurally could not.
        #
        # ⇒ So count TEXT ROWS, not pixels. Glyph pixels are binned into 16-px bands (puka's cell height)
        # measured from the topmost glyph, which self-calibrates against the window's unknown y origin.
        # ⚠ THE EXPECTATION IS DERIVED, NOT TYPED: agnsh's startup banner is **4 lines** plus a prompt
        # line, so a correctly-wrapped 80-column terminal shows 5 occupied rows. The staircase turns those
        # same 4 lines into 7-8, because two of them (69 and 88 columns) overflow once they start mid-row.
        def glyph_rows():
            try:
                d = open(os.path.join(WORK, "screen.ppm"), "rb").read()
                k = d.index(b"255\n") + 4
                hd = d[:k].split(); gw, gh = int(hd[1]), int(hd[2]); q = d[k:]
                ys = set()
                for y in range(gh):
                    base = y * gw * 3
                    for x in range(gw):
                        j = base + x * 3
                        if q[j] == 192 and q[j + 1] == 192 and q[j + 2] == 192:
                            ys.add(y)
                            break
                if not ys:
                    return None
                top = min(ys)
                return len({(y - top) // 16 for y in ys})
            except Exception:
                return None

        before = glyphs()
        rows_before = glyph_rows()
        # ⛔ THE NEWLINE IS THE WHOLE POINT, AND IT MUST LAND. agnsh's `read_line` accumulates until
        # it sees '\n' — without it the shell has taken the characters and is simply still waiting, so
        # the panel correctly shows nothing and the test would blame the input path. A first run sent
        # `ret` last and only 7 of 8 keys arrived; the missing one was the newline.
        #
        # ⛔⛔ THREE CAPTURES, NOT TWO — BECAUSE `after > before` STOPPED MEANING WHAT IT SAID.
        # This block used to note that "agnsh does NOT echo here", so any change in the glyph count had
        # to be the shell answering. That is no longer true and the note was deleted rather than left to
        # mislead: puka now owns the line discipline (`puka/src/line_discipline.cyr`) and ECHOES locally,
        # because a channel fd has none of the kernel console's echo. So typing alone moves the count,
        # and a two-capture test would report PASS on a run where the shell never answered — the exact
        # false green this harness exists to prevent.
        #
        # The three captures separate the two halves, and each is gated on its own:
        #   before -> mid    the 7 typed characters were ECHOED    (puka's half)
        #   mid    -> after  Enter made the shell WRITE BACK       (agnsh's half — the AE-T2 claim)
        # ⭐ CR and LF paint NO pixels, so every pixel of the second delta is the shell's own output
        # (its `version` reply plus a fresh prompt). The floor is DERIVED from this run, not typed in: the
        # first delta is 7 glyphs' worth of pixels, so `(mid - before) / 7 * 2` is "at least two glyphs"
        # measured in this boot's own font, at this boot's own scale. A hardcoded pixel constant would be
        # the guessed-3232-lines mistake again.
        # ⭐⭐ THIS HARNESS ASKS ONE QUESTION: does a program agnsh LAUNCHES reach the screen?
        # `ls` "not working in puka" while working as the console shell is not one symptom but two
        # candidate mechanisms, and they are distinguished by WHO WRITES:
        #   · `help`  — an agnsh BUILTIN. agnsh writes it. agnsh OWNS the PTY channel endpoint.
        #   · `ls`    — /bin/ls (kriya) via execwait #37. The CHILD writes, through a channel fd it
        #               inherited by fd-table copy, whose `chan_end_owner` is still agnsh.
        # Both echo identically (puka's local line discipline), so the ECHO delta controls for input
        # delivery and the OUTPUT delta is the only thing that differs.
        #   builtin out > 0 AND external out ~ 0  -> the inherited handle is inert (chan_auth)
        #   both > 0                              -> children DO reach the screen; look elsewhere
        #   both ~ 0                              -> keys never arrived; this run decides nothing
        _hold_ms = int(os.environ.get("PUKA_KEY_HOLD_MS", "500"))
        _KEYMAP = {" ": "spc", "/": "slash", "-": "minus", ".": "dot"}

        def _send(k):
            s.sendall((f"sendkey {k} {_hold_ms}\n").encode())
            time.sleep(_hold_ms / 1000.0 + 0.3); drain()

        def _shot(settle):
            time.sleep(settle)
            s.sendall((f"screendump {PPM}\n").encode()); time.sleep(3.0); drain()
            return glyphs()

        # ⛔ TAB FIRST — the compositor focuses the LAST client added (crab). Consumed, not forwarded.
        _send("tab")
        base = _shot(1.0)

        def run_cmd(text):
            for ch in text:
                _send(_KEYMAP.get(ch, ch))
            echoed = _shot(0.5)
            _send("ret")
            out = _shot(6.0)
            return echoed, out

        # ⭐ THREE COMMANDS, ONE BOOT. The first refuted the "inherited handle is inert" theory
        # outright (a launched program DID print), so the question narrows: `ls` printed ~11 glyphs
        # where `help` printed ~460. Bare `ls` vs `ls /` separates the remaining two candidates —
        # the DEFAULT-DIRECTORY path (k_getcwd) versus ls itself failing on this substrate.
        e_builtin, o_builtin = run_cmd("help")
        e_extern,  o_extern  = run_cmd("ls")
        # ⭐ `ls /` came back byte-identical to bare `ls` (266 px both), so the default-directory
        # path is NOT the cause. The remaining candidate is the DISPATCH: /bin/ls is a SYMLINK to
        # kriya, and kriya selects its applet from basename(argv[0]). If the kernel resolves the
        # link before staging argv[0], the dispatcher sees "kriya" — no applet — and prints usage,
        # which would be the same short output for every ls form. `kriya ls` names the applet
        # explicitly and bypasses the whole question.
        # ⛔⛔ 266 px EXACTLY, for `ls`, `ls /` AND `kriya ls` — three commands whose outputs differ
        # wildly, all rendering the same count. A constant is not output; it is agnsh's own PROMPT
        # (agnsh OWNS the channel endpoint, so its writes land). ⇒ the earlier "REFUTED" was a
        # misreading of >0 as evidence of output. This control is the strongest available: a listing
        # of /bin is ~40 entries, hundreds of glyphs. If it ALSO renders 266, no launched program's
        # output reaches the screen and the constant is proven to be the prompt.
        e_slash,   o_slash   = run_cmd("kriya ls /bin")
        p("")
        p(f"  EXTERNAL 'kriya ls' echo delta : {None if (e_slash is None or o_extern is None) else e_slash - o_extern}")
        p(f"  EXTERNAL 'kriya ls' OUT  delta : {None if (o_slash is None or e_slash is None) else o_slash - e_slash}")
        try:
            _lo = o_extern - e_extern
            _so = o_slash - e_slash
            if _so > _lo * 3 and _so > 500:
                p("  -> `kriya ls` LISTS and bare `ls` does not: the SYMLINK/argv[0] DISPATCH is the bug.")
            elif _so <= 500 and _lo <= 500:
                p("  -> Neither form lists: kriya's ls applet itself is not producing output here.")
            else:
                p("  -> Both behave alike; dispatch is not the difference.")
        except Exception:
            pass

        mid = e_builtin
        after = o_builtin

        p("")
        p("=== CHILD-STDOUT DISCRIMINATOR (glyph px @ RGB 192,192,192) ===")
        p(f"  baseline                    : {base}")
        p(f"  BUILTIN  'help'  echo delta : {None if (e_builtin is None or base is None) else e_builtin - base}")
        p(f"  BUILTIN  'help'  OUT  delta : {None if (o_builtin is None or e_builtin is None) else o_builtin - e_builtin}")
        p(f"  EXTERNAL 'ls'    echo delta : {None if (e_extern is None or o_builtin is None) else e_extern - o_builtin}")
        p(f"  EXTERNAL 'ls'    OUT  delta : {None if (o_extern is None or e_extern is None) else o_extern - e_extern}")
        try:
            _bo = o_builtin - e_builtin
            _eo = o_extern - e_extern
            _ee = e_extern - o_builtin
            # ⛔⛔ `_eo > 0` IS NOT EVIDENCE OF OUTPUT, AND READING IT THAT WAY PRODUCED A WRONG
            # VERDICT ON THE FIRST RUN OF THIS HARNESS. agnsh prints a fresh PROMPT after every
            # command, and agnsh OWNS the channel endpoint, so that prompt always renders. The
            # external delta therefore has a nonzero FLOOR that has nothing to do with the program.
            # ⭐ THE REAL TEST IS WHETHER THE DELTA RESPONDS TO HOW MUCH THE PROGRAM PRINTS.
            # Measured, one boot each: `ls`, `ls /`, `kriya ls` and `kriya ls /bin` — a ~40-entry
            # listing — ALL rendered **exactly 266**. A constant across four commands whose outputs
            # differ by orders of magnitude is a prompt, not output.
            _spread = abs(_so - _eo)
            if _ee <= 0:
                p("  -> INCONCLUSIVE: the external command was not even ECHOED — keys did not arrive.")
            elif _bo <= 0:
                p("  -> INCONCLUSIVE: even the BUILTIN produced no output; the shell never answered.")
            elif _spread == 0:
                p("  -> CONFIRMED: the builtin printed and EVERY launched program printed the SAME")
                p(f"     constant ({_eo} px) regardless of how much it should output. That constant is")
                p("     agnsh's prompt. A child's writes to the inherited PTY channel never render.")
            else:
                # ⛔ A WHOLE-SCREEN GLYPH COUNT IS NOT MONOTONIC IN OUTPUT — the terminal SCROLLS.
                # A listing longer than the window pushes earlier glyphs off the top, so a large
                # output can make the count FALL. Measured: after the kernel fix `kriya ls /bin`
                # returned **-2738** while bare `ls` returned **+1560**. Reading the negative as
                # "no output" would invert the verdict on the very run that proves the fix.
                # ⇒ The sound test is that the two external deltas DIFFER: two commands with
                # different output sizes cannot both be sitting on the prompt-only floor.
                p(f"  -> OUTPUT PRESENT: the two external commands differ by {_spread} px, so neither")
                p("     is the prompt-only floor. A launched program's writes reach the terminal.")
                p("     ⚠ A NEGATIVE delta means the window SCROLLED — that is MORE output, not less.")
        except Exception as _e:
            p("  -> INCONCLUSIVE: a capture was unreadable:", _e)

        # ⭐⭐ COUNT WHAT WAS DELIVERED BEFORE JUDGING WHAT WAS DONE WITH IT. puka prints one
        # `puka: key received` per decoded keycode, so this is an exact count of keys that crossed the
        # whole compositor->client seam, independent of anything downstream. ⛔ Without it a lost
        # keystroke is INDISTINGUISHABLE from a broken line discipline — measured, 1 run in 3 loses
        # several keys including Enter, and that run's symptom is "the shell never answered" even though
        # every byte that arrived was handled correctly. Keys are produced by the xHCI HID ring and
        # drained only inside `kbscan #42`'s bounded sti window (kernel/core/syscall.cyr:8746-8757), so a
        # slow compositor frame can miss one. That is an INPUT-DELIVERY defect in the kernel/driver
        # layer, not a terminal one, and this harness must name it as such rather than blame puka.
        _ser = open(SER, "rb").read().decode("latin1")
        keys_got = _ser.count("puka: key received")
        line_sent = "puka: line sent to the shell" in _ser
        refused = _ser.count("puka: byte refused by the line discipline")

        echo_ok = (before is not None) and (mid is not None) and (mid > before)
        answer_ok = False
        answer_floor = None
        if echo_ok and after is not None:
            answer_floor = max(1, int((mid - before) / 7 * 2))
            answer_ok = (after - mid) >= answer_floor
        # ⭐ THE LAYOUT GATE, CALIBRATED AGAINST BOTH ARMS ON THIS BOX, SAME BUILD, SAME BOOT PATH:
        #     ONLCR present (correct)  -> **6** text rows
        #     ONLCR removed (mutant)   -> **8** text rows, and the shell still "ANSWERED" in that run,
        #                                 which is precisely why the pixel count could not see it
        # There is exactly one integer between them, so the ceiling is **7**: a correct run keeps one row
        # of slack (for a wrapped prompt or a stray blank) and the staircase still fails by one.
        # ⛔ If you raise this to make a run pass, you have deleted the only gate that can see a staircase.
        rows_max = int(os.environ.get("PUKA_LAYOUT_ROWS_MAX", "7"))
        layout_ok = (rows_before is not None) and (rows_before <= rows_max)
        typed_ok = echo_ok and answer_ok and layout_ok
        p(f"  banner LAYOUT (text rows used)    : {rows_before} (need <= {rows_max}; correct = 6, "
          f"staircase = 8, both measured) -> {'PASS' if layout_ok else 'FAIL'}")
        if rows_before is not None and not layout_ok:
            p("     ⛔ THE SAME CHARACTERS IN THE WRONG PLACES — a STAIRCASE, not a wrapping bug.")
            p("        Every line is starting where the previous one ENDED, then overflowing the right")
            p("        edge and breaking mid-word. Cause: the child's bare LF is reaching the engine")
            p("        without a carriage return. agnos's kernel console makes LF mean newline+CR")
            p("        (fb_console.cyr:1051), so EVERY agnos program emits bare LF; a real terminal must")
            p("        apply ONLCR in its line discipline — puka/src/line_discipline.cyr `ld_out_feed`.")
            p("        ⛔ Do NOT 'fix' this by widening the grid: agnsh's longest help line is 77 of 80.")
        p(f"  keys DELIVERED to puka           : {keys_got} of {(len("help")+len("ls")+2)} forwarded "
          f"(tab is consumed by the compositor)")
        p(f"  keystrokes ECHOED by puka        : {echo_ok}  (glyph px {before} -> {mid})")
        p(f"  a completed line went to the shell: {line_sent}"
          f"{'' if refused == 0 else f'   ⚠ {refused} byte(s) REFUSED by the discipline'}")
        p(f"  shell ANSWERED over the PTY      : {answer_ok}  (glyph px {mid} -> {after}, "
          f"need +{answer_floor} = 2 glyphs at this run's own scale)")
        if before is not None and mid is not None and mid == before:
            p("     ⛔ typing changed nothing — either focus never reached puka, the compositor did")
            p("        not forward the key, or the HID->evdev map dropped it. Nothing is proven about")
            p("        the shell: this half is puka's, and it failed before agnsh was ever involved.")
        elif echo_ok and not answer_ok and not line_sent:
            # ⭐ THE DISCRIMINATOR. No line reached the shell AND keys went missing ⇒ Enter never
            # arrived, so nothing is proven or disproven about the discipline or about agnsh.
            if keys_got < (len("help")+len("ls")+2):
                p(f"     ⚠ INPUT DELIVERY, NOT THE TERMINAL: only {keys_got} of {(len("help")+len("ls")+2)} keys")
                p("        reached puka, so Enter was among the lost and no line could complete. The")
                p("        line discipline and agnsh are UNTESTED by this run — re-run before drawing")
                p("        any conclusion. Cause: the xHCI HID ring is drained only in kbscan #42's")
                p("        bounded sti window, so a slow compositor frame can miss a key.")
            else:
                p("     ⛔ EVERY KEY ARRIVED AND NO LINE COMPLETED — that IS the line discipline.")
                p("        Enter must arrive as LF (10): agnsh's read_line terminates on nothing else,")
                p("        and the encoder emits CR (13), which puka/src/line_discipline.cyr converts.")
        elif echo_ok and line_sent and not answer_ok:
            p("     ⛔ A COMPLETE LINE REACHED THE SHELL AND IT WROTE NOTHING BACK. That is agnsh's")
            p("        side, and it is the one case where the terminal is exonerated by its own log.")

        GLYPH_MIN = 500
        if glyph_px is None:
            p("  ⛔ NO FRAMEBUFFER EVIDENCE — cannot pass on the programs' own claims alone.")
            rc = 1
        else:
            gok = glyph_px >= GLYPH_MIN
            p(f"  framebuffer (external): {glyph_px} glyph px at exact C0C0C0 "
              f"(need >= {GLYPH_MIN}) -> {'PASS' if gok else 'FAIL'}")
            if term_up and presented and not gok:
                p("  ⛔ BOTH PROGRAMS CLAIM SUCCESS AND THE PANEL SHOWS NO GLYPHS. Believe the panel:")
                p("     a window that presents an empty buffer is not a terminal.")
            rc = 0 if (term_up and presented and comp_saw and gok and typed_ok) else 1

        p("")
        if rc == 0:
            p("puka-terminal-test: PASS — a live agnsh prompt is rendered in a composited window AND "
              "keystrokes reach the shell (window + PTY + channel band + glyphs + input)")
        else:
            p("puka-terminal-test: FAIL")
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
