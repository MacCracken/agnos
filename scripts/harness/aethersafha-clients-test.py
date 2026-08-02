#!/usr/bin/env python3
# aethersafha-clients-test.py — reproduce, IN QEMU, the iron failure where the desktop's setu
# clients spawn and never connect.
#
# ⛔ WHY THIS EXISTS. `scripts/smoke/aethersafha-setu-smoke.sh` PASSES: both clients connect and
# present. But it launches the compositor from the AETHERSAFHA_SETU_SELFTEST kernel hook, as a
# background proc ("loading compositor bg", "ae pid=2"). On iron the operator launched it the way a
# person actually does — `aethersafha` at the agnsh prompt — and `--clients` returned 93 with NO
# output from either client at all. The smoke could never have caught that, because it does not
# exercise the launch path a human uses.
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
# tested the wrong thing. `scripts/smoke/aethersafha-setu-smoke.sh` rebuilds build/agnos with
# AETHERSAFHA_SETU_SELFTEST=1 — a kernel that auto-runs the compositor at boot and never reaches
# agnsh. The harness booted it, saw no banner, and reported "no agnsh banner" as if the boot were
# broken. A selftest kernel here does not fail this test, it INVALIDATES it: the whole point is to
# exercise the agnsh launch path, which that kernel never gets to.
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
    "qemu-system-x86_64", "-machine", "q35", "-m", "2048M", "-cpu", "max",
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
    # ⚠ `AETHERSAFHA_SETU_SELFTEST` hides this by assigning `net_ip = 0x7F000001` in the kernel hook
    # before it launches the compositor. That fixup exists ONLY in that selftest, so the smoke has
    # never exercised the address path a real boot takes — and a harness without a NIC reproduces
    # the workaround's absence rather than any desktop fault.
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
        for line in seg.splitlines():
            t = line.strip()
            if t.startswith("run: exit "):
                try: code = int(t.split()[-1])
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
    if MODE in ("fg", "both"):
        # FOREGROUND: agnsh execwait #37 — the blocking primitive, the path the iron burn used.
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
    if MODE in ("bg", "both"):
        # BACKGROUND: agnsh routes a trailing `&` to spawn_path #43 (run_agnos.cyr:172), so the
        # compositor becomes an independently scheduled proc — the same shape as the kernel hook.
        # ⚠ There is no `run: exit` here: execwait is what prints that. agnsh prints "[1] <pid>" and
        # the compositor reports its own verdict, so gate on the compositor's exit print instead.
        p("background `aethersafha --clients &` (agnsh spawn_path #43)...")
        bg = run_wait("aethersafha --clients &\n", "probe ran for milliseconds", timeout=180)
        bg_code = verdict(bg, "bg")

    # ⛔ SERIAL IS THE COMPOSITOR'S OWN CLAIM, NOT EVIDENCE OF PIXELS. "setu client presented
    # surface" is printed by the same program being judged — a shared-premise oracle. The setu smoke
    # already reported "0 green-border pixels ... NOTE: green border not detected" and dismissed it
    # as "serial gate is dispositive", which is precisely backwards: the FRAMEBUFFER is the external
    # invariant here. Capture it and count present_probe's own colours.
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
        except Exception as e:
            p("screendump parse failed:", e)
    else:
        p("NO SCREENDUMP PRODUCED")

    p("")
    p("=== VERDICT ===")
    if MODE == "desktop":
        # ⛔ Do not reuse the fg/bg comparison here — desktop mode runs neither, and printing that
        # line anyway produced a verdict that flatly contradicted the run it came from.
        ok = (bg_code == 95)
        p(f"  foreground desktop (no &): clients presented = {'2+' if ok else 'FEWER THAN 2'}")
        p("  Judge this on the FRAMEBUFFER counts above and the PPM, not on the serial alone.")
        rc = 0 if ok else 1
        raise SystemExit(rc)
    p(f"  foreground exit {fg_code} · background exit {bg_code}")
    if fg_code == 95 and (bg_code == 95 or bg_code is None):
        p("  Both clients present on BOTH launch paths.")
        rc = 0
    elif bg_code == 95 and fg_code != 95:
        p("  Backgrounded (`&`) works; FOREGROUND does not.")
        p("  ⇒ agnsh's blocking execwait #37 frame prevents the spawned clients being scheduled.")
        rc = 0
    else:
        p("  Neither path reached 95 — the fault is not (only) the launch path.")
        rc = 1
finally:
    try: qemu.terminate(); qemu.wait(timeout=10)
    except Exception:
        try: qemu.kill()
        except Exception: pass
p(f"serial: {SER}")
sys.exit(rc)
