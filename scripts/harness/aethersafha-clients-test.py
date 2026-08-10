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
import os, re, socket, struct, subprocess, sys, time, zlib

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

# ⭐ Find the cursor arrow in a PPM by matching its exact 10x20 two-tone shape. Returns (x, y) of the
# bitmap origin, or None. Mirrors `cursor_fill_at`/`cursor_outline_at` in aethersafha/src/cursor.cyr —
# ⚠ if the arrow's silhouette is deliberately changed there, this pattern must be updated with it, and the
# failure mode is a loud "NO ARROW FOUND" rather than a silent pass.
CURSOR_ART = [
    "o.........",
    "ooo.......",
    "o#oo......",
    "o##o......",
    "o##oo.....",
    "o###o.....",
    "o###oo....",
    "o####o....",
    "o####oo...",
    "o#####o...",
    "o#####oo..",
    "o######o..",
    "o######oo.",
    "o#######o.",
    "o#######o.",
    "o###o###o.",
    "o##oo###o.",
    "o#ooo###o.",
    "ooo.o###o.",
    "....ooooo.",
]

def cursor_arrow_find(path):
    try:
        f = open(path, "rb")
        if f.readline().strip() != b"P6":
            return None
        line = f.readline()
        while line.startswith(b"#"):
            line = f.readline()
        w, h = map(int, line.split())
        f.readline()
        data = f.read(w * h * 3)
    except Exception:
        return None
    WHITE = b"\xff\xff\xff"
    BLACK = b"\x00\x00\x00"
    # Anchor on row 13 -- "o#######o" is a 9-pixel run this theme produces nowhere else, so the expensive
    # full-shape check runs a handful of times instead of once per pixel.
    anchor = BLACK + WHITE * 7 + BLACK
    ah = len(CURSOR_ART)
    aw = len(CURSOR_ART[0])
    for y in range(13, h - (ah - 13)):
        row = data[y * w * 3:(y + 1) * w * 3]
        start = 0
        while True:
            i = row.find(anchor, start)
            if i < 0:
                break
            start = i + 3
            if i % 3 != 0:
                continue
            x0 = i // 3
            y0 = y - 13
            if x0 < 0 or y0 < 0 or x0 + aw > w or y0 + ah > h:
                continue
            ok = True
            for ry in range(ah):
                for rx in range(aw):
                    ch = CURSOR_ART[ry][rx]
                    if ch == ".":
                        continue                       # transparent: whatever is behind it
                    o = ((y0 + ry) * w + (x0 + rx)) * 3
                    got = data[o:o + 3]
                    if ch == "#" and got != WHITE:
                        ok = False
                        break
                    if ch == "o" and got != BLACK:
                        ok = False
                        break
                if not ok:
                    break
            if ok:
                return (x0, y0)
    return None


# ⭐ Locate a window TITLEBAR in a PPM by its focused-accent underline: a long run of bright cyan that the
# theme draws along the bottom of the focused window's titlebar and nowhere else. Returns a point INSIDE
# that titlebar, or None.
#
# ⛔ WHY MEASURE INSTEAD OF COMPUTE. The first version of the drag phase aimed at (50, 60) from the
# compositor's cascade arithmetic (`pcx = 30 + pstep * (w/6)`), and it worked once and then silently missed
# — the window is not where that formula says, and a missed press reports "says nothing about the release",
# i.e. the phase quietly stops testing. Deriving the target from the SCREEN cannot drift out of step with
# the compositor's layout, because it is reading the compositor's own output.
def find_titlebar(path):
    try:
        f = open(path, "rb")
        if f.readline().strip() != b"P6":
            return None
        line = f.readline()
        while line.startswith(b"#"):
            line = f.readline()
        w, h = map(int, line.split())
        f.readline()
        data = f.read(w * h * 3)
    except Exception:
        return None
    for y in range(0, h):
        base = y * w * 3
        run = 0
        start = 0
        for x in range(0, w):
            o = base + x * 3
            if data[o] < 80 and data[o + 1] > 150 and data[o + 2] > 150:
                if run == 0:
                    start = x
                run += 1
                if run > 120:
                    # A point inside the titlebar: along the accent run, a little ABOVE the underline.
                    return (start + 40, max(0, y - 10))
            else:
                run = 0
    return None

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
    "-device", "usb-mouse,bus=xhci.0",   # ⭐ AE-7: the pointer under test
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
        # ⛔⛔ PRIME WITH A BARE ENTER FIRST — THE FIRST CHARACTER GETS DROPPED. Measured 2026-08-09: the
        # harness typed `aethersafha --clients &` and agnsh received `ethersafha --clients &`, did not
        # recognise it, handed it to the intent parser ("Intent: 15") and the compositor never launched —
        # reported as `launched: False`, which reads as a code failure and is a TYPING failure. The drop is
        # in the first keystroke after the prompt appears (the HID path is still settling), so spending a
        # throwaway Enter on it costs one redrawn prompt and makes every command land whole.
        # ⚠ This bit `desktop` mode too; it had simply been getting away with it.
        s.sendall(b"sendkey ret\n")
        time.sleep(0.35); drain()
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
        # ⚠ PRIME FIRST. In QEMU the FIRST character of the FIRST typed line is dropped, so `aethersafha`
        # arrived as `ethersafha`, agnsh handed it to the intent parser, and the desktop never launched —
        # after which every later phase measured a boot with no compositor. Not the kbscan spin (the old
        # 256-iteration drain does not fix it): q35's i8042 used to deliver keys in parallel and covered
        # it, so deleting PS/2 made a pre-existing race visible. Iron has no PS/2 producer and has shown
        # no key loss (AE-T2: 19/19), so this is believed emulation-only.
        typ("\n", settle=0.5)
        typ("aethersafha\n", settle=1.0)
        for _w in range(24):
            if "setu client presented surface" in ser(): break
            time.sleep(1.0)
        time.sleep(6.0)
        bg = ser()
        bg_code = verdict(bg, "desktop")

        # ⭐⭐ THE F7-F10 WINDOW-MOVE PHASE — the stimulus `AE-0a` was written for and has never had.
        #
        # `AE-0a` computes its damage band as union(cur, prev) *because* a window that MOVES leaves
        # its old pixels on screen unless the band also covers where it WAS. That reasoning shipped
        # and burned four times with nothing on the system able to move a window — AE-7 pointer input
        # is a kernel xhci item — so the case the band exists for was never once exercised. A keyboard
        # mover is the missing stimulus, and this phase exercises it without spending a burn.
        #
        # ⛔ F7-F10, NOT F1-F4. The 2026-08-08 build bound the mover to F1-F4 and F4 was ALREADY
        # `IA_CLOSE_FOCUSED` — "move down" and "destroy the window" were one keystroke. Bindings live in
        # aethersafha/src/input.cyr's `HidUsage`; read it before adding a key here.
        #
        # ⛔ IT IS ALSO THE ONLY LOCAL TEST FOR THE 2026-08-08 IRON RESULT, in which the compositor
        # printed every other line of that burn and NOT its window-move line. From that
        # log alone TWO explanations are indistinguishable — the keys were never pressed, or they
        # arrived at the compositor and were silently dropped — and the honest reading of a missing
        # marker is the second one, because the default explanation for work not happening is that
        # the code is wrong. This phase separates them.
        #
        # ⭐ WHY THIS REPRODUCES IRON RATHER THAN MERELY RESEMBLING IT: the QEMU line above gives the
        # guest `qemu-xhci` + `usb-kbd`, so the guest keyboard is USB HID on xHCI — the SAME producer
        # archaemenid uses ("xhci: port 2 connected, FS ... hid: keyboard configured, boot protocol
        # on, EP=129, polling 8-byte reports"). This is NOT the i8042 PS/2 path, which reaches the
        # kernel through a different translation table entirely. If a function key is filtered
        # anywhere in the HID path, it is filtered here too.
        #
        # ⚠ HOLD, DO NOT TAP. QEMU's default sendkey hold is ~100 ms while the compositor samples HID
        # state once per frame, so a short press is NEVER SAMPLED rather than "dropped" — the exact
        # confusion that cost a session in puka-terminal-test.py, where key loss was read as a
        # terminal bug and was really poll-vs-frame sampling. 500 ms unless overridden.
        AE_KEY_HOLD_MS = int(os.environ.get("AE_KEY_HOLD_MS", "500"))

        def key_raw(name, hold_ms=None):
            h = AE_KEY_HOLD_MS if hold_ms is None else hold_ms
            s.sendall((f"sendkey {name} {h}\n").encode())
            time.sleep(h / 1000.0 + 0.3); drain()

        # A before-shot, so the after-shot the gate block takes below is a COMPARISON and not just a
        # picture. ⚠ Neither is a gate here: in `desktop` mode a live agnsh console writes to the
        # same framebuffer as the compositor, so a whole-frame pixel measure carries an uncontrolled
        # writer. These are for the eye and for a diff, and the SERIAL MARKER is the oracle.
        SHOT_BEFORE = os.path.join(WORK, "move-before.ppm")
        s.sendall((f"screendump {SHOT_BEFORE}\n").encode()); time.sleep(3.0); drain()

        mv_mark = len(ser())
        p("")
        p(f"=== F1-F4 WINDOW MOVE (USB HID on xHCI, {AE_KEY_HOLD_MS} ms hold) ===")
        # TAB first: focus must land on a window before a move means anything, and TAB is the one
        # compositor key proven to work on iron (it cycled focus four times in the 08-08 burn).
        key_raw("tab")
        MOVE_KEYS = ["f7", "f7", "f7", "f8", "f8", "f9", "f9", "f10", "f10", "f10"]
        for _mk in MOVE_KEYS:
            key_raw(_mk)
        # ⭐⭐ LETTERS, BECAUSE FUNCTION KEYS CANNOT TEST THE FORWARD. Every key above is a COMPOSITOR
        # ACTION (TAB cycles focus, F7-F10 move the window) and `input_handle` consumes any non-IA_NONE
        # action rather than forwarding it — so a phase made only of those reports `forwarded a key: 0`
        # NO MATTER WHAT the forward does. That is a vacuous gate, and it read as a puka failure on the
        # 2026-08-08 burn when the forward had simply never been exercised.
        # ⇒ A letter maps to IA_NONE, so it is the ONLY kind of key that reaches the focused client.
        #
        # ⛔⛔ AND TAB ONE MORE TIME FIRST, BECAUSE OF WHERE THE WRAP LANDS. Each client that completes
        # its handshake calls `comp_focus(comp, comp_count(comp) - 1)`, so after both present focus sits
        # on the LAST one — index 2 of {seeded, puka, crab}. The single TAB above therefore wraps 2 -> 0,
        # onto the COMPOSITOR-SEEDED window, which has no client fd by design. ⚠ MEASURED: the letters
        # reported `focused window has none, usage 11, focus index 0` — the forward was working and the
        # gate was aimed at the one window that cannot receive. A second TAB moves 0 -> 1 = puka, which
        # is the client the 2026-08-08 burn was actually about.
        key_raw("tab")
        FWD_KEYS = ["h", "i"]
        for _fk in FWD_KEYS:
            key_raw(_fk)
        time.sleep(3.0)
        mv = ser()[mv_mark:]

        moved_n   = mv.count("aethersafha: F7-F10 moved the focused window")
        usage_n   = mv.count("aethersafha: key usage seen:")
        fwd_n     = mv.count("aethersafha: forwarded a key to the focused client")
        tabbed_n  = mv.count("aethersafha: focus cycled by TAB")
        nofwd_n   = mv.count("aethersafha: a key reached NO client")
        p(f"  keys injected                    : tab + {len(MOVE_KEYS)} function keys + {len(FWD_KEYS)} letters")
        p(f"  'F7-F10 moved the focused window': {moved_n}")
        p(f"  'focus cycled by TAB'            : {tabbed_n}")
        p(f"  'key usage seen:' traces         : {usage_n}")
        p(f"  'forwarded a key to the client'  : {fwd_n}")
        p(f"  'a key reached NO client'        : {nofwd_n}")
        # ⭐ THE FORWARD GATE. A letter reaching the compositor and NOT reaching a client means the
        # focused window has no client fd — which is exactly the placed-client handshake failing, the
        # 2026-08-08 defect. ⚠ Reported, not fatal: TAB order decides which window is focused, and the
        # compositor-seeded window legitimately has no client, so this is attribution and not a verdict.
        if fwd_n > 0:
            p("  ⭐ A LETTER REACHED A CLIENT: the focused window has a live setu fd, so the")
            p("     placed-client handshake completed and S->C input works.")
        else:
            if nofwd_n > 0:
                p("  ⛔ A LETTER REACHED NO CLIENT — the focused window has cfd 0. If 'presented' above")
                p("     is less than 2 this is the handshake failing; if it is 2, focus was on the")
                p("     compositor-seeded window and TAB simply had not reached a client yet.")
            else:
                p("  ⚠ NEITHER MARKER FIRED — the letters did not reach the compositor at all, so this")
                p("     says nothing about the forward. Check the 'key usage seen:' traces first.")

        # ⭐ THE ATTRIBUTION. ⛔ READ THE SCOPE LINE FIRST: everything below is a statement about
        # THE BINARY THIS RUN BOOTED, not about any binary that was ever flashed. Those are the same
        # claim only when the staged /bin/aethersafha is byte-identical to the flashed one — and the
        # first version of this block quietly assumed they were, so a PASS here would have printed
        # "the iron burn's keys were never pressed" on a tree where the handler had already been
        # fixed. That is a false exoneration of a bug that really existed, generated by a green run.
        # ⇒ If you want this phase to testify about a past burn, boot that burn's artifact.
        if moved_n > 0:
            p("  ⭐ THE MOVER WORKS on the USB HID path IN THIS BUILD: a usage decoded, the handler")
            p("     ran, and a window moved. The chain xHCI HID -> kb_buf -> kbscan#42 -> Set-1")
            p("     decode -> input_map -> input_apply -> win_move is intact end to end.")
            p("     ⚠ SCOPE: this says nothing about a previously flashed binary, and nothing about")
            p("       the GPU path — QEMU has no amdgpu, so the compositor ran its CPU blit here.")
            p("     ⚠ The marker latches on first move, so 1 is the maximum however many keys land.")
            p("       Net displacement for the sequence above is 40 px LEFT and 40 px DOWN; look at")
            p("       the two screendumps to confirm the window moved that far AND left no ghost.")
        else:
            if tabbed_n == 0:
                p("  ⚠ TAB DID NOT CYCLE FOCUS EITHER — so this phase tests nothing about F1-F4.")
                p("    Either no key reached the compositor at all or the desktop was already gone.")
                p("    ⛔ Do NOT read the F1-F4 result below; fix the precondition first.")
            else:
                p("  ⛔ REPRODUCED LOCALLY: TAB reached the compositor and F7-F10 did not move a window.")
                p("     That is a REAL defect, reproducible without hardware. Compare the 'key usage")
                p("     seen:' traces against 64/65/66/67 (0x40-0x43): if the usages are absent the")
                p("     drop is BELOW the compositor (kernel HID filter or the bhumi seam); if they")
                p("     are present the drop is IN the handler.")

        SHOT_AFTER = os.path.join(WORK, "move-after.ppm")
        s.sendall((f"screendump {SHOT_AFTER}\n").encode()); time.sleep(3.0); drain()
        # ⭐ EMIT PNGs TOO, because the ghost question is answered by LOOKING and nothing else here
        # can answer it. ⛔ Do NOT try to settle it by correlating the two frames for a rigid shift:
        # only ONE window moves, so every static pixel of console and of the other windows votes for
        # "no displacement" and the best match is always (0,0). That measurement was run, it returned
        # a confident and completely wrong answer, and the images settled it in one look.
        for _nm in ("move-before", "move-after"):
            try:
                _pp = os.path.join(WORK, _nm + ".ppm")
                with open(_pp, "rb") as _f: _raw = _f.read()
                _parts = _raw.split(b"\n", 3)
                _w, _hh = [int(_v) for _v in _parts[1].split()]
                _px = _parts[3]
                _S = 4                      # 2048x2048 surfaces are unwieldy; quarter-scale is legible
                _ow, _oh = _w // _S, _hh // _S
                _rows = []
                for _y in range(_oh):
                    _r = bytearray(); _base = (_y * _S) * _w * 3
                    for _x in range(_ow):
                        _i = _base + (_x * _S) * 3
                        _r += _px[_i:_i+3]
                    _rows.append(bytes(_r))
                def _chunk(_t, _d):
                    return (struct.pack(">I", len(_d)) + _t + _d
                            + struct.pack(">I", zlib.crc32(_t + _d) & 0xffffffff))
                _ihdr = struct.pack(">IIBBBBB", _ow, _oh, 8, 2, 0, 0, 0)
                _idat = zlib.compress(b"".join(b"\x00" + _r for _r in _rows), 6)
                with open(os.path.join(WORK, _nm + ".png"), "wb") as _f:
                    _f.write(b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", _ihdr)
                             + _chunk(b"IDAT", _idat) + _chunk(b"IEND", b""))
            except Exception as _e:
                p(f"  (png conversion of {_nm} failed: {_e})")
        p(f"  shots: {SHOT_BEFORE} -> {SHOT_AFTER}")
        p(f"  LOOK AT THESE: {os.path.join(WORK, 'move-before.png')} and move-after.png")

        # ⭐⭐ THE POINTER PHASE (`AE-7`) — and this is also the FIRST ring-3 caller of `ptrscan #98`, so
        # it is what proves that syscall at all. Until something called it, "a user program can read
        # pointer motion" was written and unproven.
        # ⚠ QEMU's `mouse_move` drives the usb-mouse attached to the same qemu-xhci as the keyboard, so
        # the whole chain is exercised: HID report -> event ring -> the ONE drain -> registry dispatch ->
        # kernel accumulator -> #98 -> bhumi decode -> kind-tagged event -> the compositor's cursor.
        p("")
        p("=== POINTER (ptrscan #98 -> bhumi -> cursor) ===")
        pt_mark = len(ser())
        # ⚠ SELECT THE USB MOUSE FIRST. q35 also exposes a PS/2 mouse, and HMP `mouse_move` drives
        # whichever pointer QEMU has made current — which is NOT necessarily the usb-mouse on xhci.0 that
        # agnos actually binds. Symptom when this is wrong: button events arrive and motion does not, i.e.
        # the chain looks half-broken when it is entirely fine and the harness is simply talking to the
        # wrong device. `info mice` marks the current one with a '*'.
        try:
            s.sendall(b"info mice\n"); time.sleep(0.4)
            mice = s.recv(65536).decode("latin1", "replace")
            p("  QEMU mice:")
            for _ln in mice.splitlines():
                if "mouse" in _ln.lower() or "index" in _ln.lower(): p("    " + _ln.strip())
            _usb = None
            for _ln in mice.splitlines():
                if "HID Mouse" in _ln or "USB Mouse" in _ln:   # QEMU names it "QEMU HID Mouse"
                    _m = re.search(r"index[=:]\s*(\d+)", _ln)
                    if _m: _usb = _m.group(1)
            if _usb is not None:
                s.sendall(("mouse_set " + _usb + "\n").encode()); time.sleep(0.3); drain()
                p(f"  selected the USB mouse (index {_usb})")
            else:
                p("  ⚠ no USB mouse row parsed; if it is already marked * this is cosmetic")
        except OSError:
            pass
        for _i in range(10):
            s.sendall(b"mouse_move 12 7\n"); time.sleep(0.12); drain()
        s.sendall(b"mouse_button 1\n"); time.sleep(0.2); drain()
        s.sendall(b"mouse_button 0\n"); time.sleep(0.6); drain()

        # ⭐⭐ DRAG: PRESS, MOVE, RELEASE — THE GESTURE NO ONE REMEMBERS TO PERFORM.
        #
        # ⛔ THIS IS AUTOMATED BECAUSE TWO CONSECUTIVE IRON BURNS LEFT IT UNMEASURED. The press-hold-RELEASE
        # transition is the burn blocker `input_btn_transitions` was written for — before it, the kernel's
        # re-seeding of `seen` to the held level made the release edge unreachable and a titlebar drag was
        # entered and never exited. Both burns carried it in their watch steps; both times the operator did
        # not perform the motion, and nothing noticed. A subject whose only oracle is a remembered human
        # gesture is a subject that does not get tested.
        #
        # ⚠ The RELEASE is the assertion, not the movement. `drag started` proves the press hit a titlebar;
        # `drag released` proves the transition that could not previously happen. `drag started` WITHOUT
        # `drag released` is exactly the glued-window failure, so the absence is readable too.
        # ⭐ AIM DETERMINISTICALLY: SLAM TO THE ORIGIN FIRST, THEN STEP ONTO A KNOWN TITLEBAR.
        # A relative mouse has no absolute position to aim with and the first attempt at this missed
        # entirely (it walked up-left from centre by a guessed amount and hit empty desktop). But the
        # pointer CLAMPS at the screen edges, so driving it far past the top-left corner puts it at a
        # KNOWN (0,0) whatever it was doing before — an absolute reference built out of relative moves.
        # From there the first placed client sits at (30, 50) with a 30 px titlebar (aethersafha's cascade:
        # `pcx = 30 + pstep * (w/6)`, `pcy = 50 + pstep * (h/6)`, and pstep = 0 for the first), so (50, 60)
        # is inside its titlebar by 20 px in x and 10 px in y.
        # ⚠ s8 per report: each `mouse_move` delta must stay within [-128, 127] or the HID byte wraps.
        drag_mark = len(ser())
        p("")
        p("=== DRAG (press on a titlebar, move, RELEASE) ===")
        # Slam past the top-left: the pointer CLAMPS, which turns relative moves into a known (0,0).
        for _ in range(40):
            s.sendall(b"mouse_move -100 -60\n"); time.sleep(0.03)
        time.sleep(0.8); drain()
        # Then aim at a titlebar the compositor actually drew, read off the framebuffer.
        SHOT_AIM = os.path.join(WORK, "aim.ppm")
        s.sendall((f"screendump {SHOT_AIM}\n").encode()); time.sleep(2.5); drain()
        tb = find_titlebar(SHOT_AIM)
        # ⚠ RETRY THE MEASUREMENT. Two runs of the same binary gave different answers — one aimed and
        # dragged, one found nothing — because the screendump can catch the panel mid-composite or before
        # the desktop has settled after the slam. A gate that passes intermittently is not a gate: it
        # teaches you to re-run until green, which is the opposite of an oracle.
        aim_try = 0
        while tb is None and aim_try < 3:
            aim_try += 1
            time.sleep(2.0)
            s.sendall((f"screendump {SHOT_AIM}\n").encode()); time.sleep(2.5); drain()
            tb = find_titlebar(SHOT_AIM)
            if tb is not None:
                p(f"  (titlebar found on retry {aim_try} — the first capture caught the panel unsettled)")
        if tb is None:
            p("  ⚠ No focused titlebar accent found after 4 captures — cannot aim, skipping the drag.")
            p("     This says NOTHING about the release edge.")
        else:
            p(f"  aiming at titlebar {tb} (measured from the panel, not computed)")
            tx, ty = tb
            step = 0
            while step < tx or step < ty:        # walk there in s8-safe increments from (0,0)
                mx = min(100, max(0, tx - step))
                my = min(100, max(0, ty - step))
                if mx == 0 and my == 0:
                    break
                s.sendall((f"mouse_move {mx} {my}\n").encode()); time.sleep(0.05)
                step += 100
            time.sleep(0.8); drain()
            s.sendall(b"mouse_button 1\n"); time.sleep(0.4); drain()
            for _ in range(10):                  # drag while held
                s.sendall(b"mouse_move 9 5\n"); time.sleep(0.08)
            time.sleep(0.5); drain()
            s.sendall(b"mouse_button 0\n"); time.sleep(1.2); drain()
        dg = ser()[drag_mark:]
        started  = "aethersafha: drag started" in dg
        released = "aethersafha: drag released" in dg
        # One retry if the press missed: re-measure (the window may have moved) and try the gesture again.
        if tb is not None and not started:
            p("  (press missed the titlebar — re-measuring and retrying the gesture once)")
            s.sendall((f"screendump {SHOT_AIM}\n").encode()); time.sleep(2.5); drain()
            tb2 = find_titlebar(SHOT_AIM)
            if tb2 is not None:
                for _ in range(40):
                    s.sendall(b"mouse_move -100 -60\n"); time.sleep(0.03)
                time.sleep(0.6); drain()
                tx2, ty2 = tb2
                st2 = 0
                while st2 < tx2 or st2 < ty2:
                    mx = min(100, max(0, tx2 - st2)); my = min(100, max(0, ty2 - st2))
                    if mx == 0 and my == 0:
                        break
                    s.sendall((f"mouse_move {mx} {my}\n").encode()); time.sleep(0.05)
                    st2 += 100
                time.sleep(0.6); drain()
                s.sendall(b"mouse_button 1\n"); time.sleep(0.4); drain()
                for _ in range(10):
                    s.sendall(b"mouse_move 9 5\n"); time.sleep(0.08)
                time.sleep(0.5); drain()
                s.sendall(b"mouse_button 0\n"); time.sleep(1.2); drain()
                dg = ser()[drag_mark:]
                started  = "aethersafha: drag started" in dg
                released = "aethersafha: drag released" in dg
        p(f"  'drag started'  : {started}")
        p(f"  'drag released' : {released}")
        if started and released:
            p("  ⭐⭐ THE RELEASE EDGE FIRES — the window stopped when the button came up. This is the")
            p("     transition that was UNREACHABLE before input_btn_transitions: the kernel re-seeds")
            p("     buttons_seen to the held level, so an edge on cur|seen never saw the button rise.")
        if started and not released:
            p("  ⛔⛔ DRAG ENTERED AND NEVER EXITED — the burn blocker is back. The window is now glued to")
            p("     the pointer for the rest of this run. Check input_btn_transitions: RELEASE must test")
            p("     `cur` ALONE, never `cur | seen`.")
        if not started:
            p("  ⚠ The press did not land on a titlebar, so this phase says NOTHING about the release.")
            p("     Not a failure of the fix — a failure of aim. Adjust the walk above; do not read a")
            p("     missing 'drag released' as a defect when 'drag started' is also missing.")
        time.sleep(2.0)
        pt = ser()[pt_mark:]
        moved = "aethersafha: pointer motion received -- the cursor is live" in pt
        clicked = "aethersafha: pointer button click routed" in pt
        # ⛔ PRECONDITION FIRST. The move phase already guards this way and the pointer phase did not —
        # so when the desktop failed to launch, this printed a confident "no pointer motion" diagnosis
        # about a boot that had no compositor in it at all. A verdict whose precondition is unchecked is
        # not a verdict.
        desktop_up = "aethersafha: bhumi backend up" in ser()
        if desktop_up == False:
            p("  ⛔ THE DESKTOP NEVER STARTED — this phase tests NOTHING about the pointer.")
            p("     Fix that first; do not read the lines below as evidence about #98 or bhumi.")
        p(f"  motion reached the compositor : {moved}")
        p(f"  a click was routed            : {clicked}")
        if moved:
            p("  ⭐ THE POINTER CHAIN IS LIVE END TO END, and this is the first ring-3 use of #98.")
        else:
            p("  ⛔ NO POINTER MOTION AT THE COMPOSITOR. Read the layers in order before guessing:")
            p("     'hid: mouse configured'      -> the endpoint bound at all")
            p("     'hid: first mouse report'    -> the kernel accumulator saw a report")
            p("     neither of those + no motion -> the mouse never bound; a QEMU -device usb-mouse issue")
            p("     both of those BUT no motion  -> #98 or the bhumi decode, NOT the kernel HID path")
        p(f"  kernel-side markers: mouse configured={('hid: mouse configured' in ser())} "
          f"first report={('hid: first mouse report accumulated' in ser())}")

        # ⭐⭐ THE CURSOR ORACLE — IS THERE AN ARROW ON THE PANEL, PIXEL FOR PIXEL?
        #
        # ⛔ EVERY EARLIER CURSOR CHECK WAS A SERIAL LINE, AND A SERIAL LINE IS THE COMPOSITOR'S OPINION.
        # "pointer motion received -- the cursor is live" printed on the 1.56.42 burn while the cursor was
        # INVISIBLE: the glyph had been refused and the text path retired, so the log described an intent
        # and the panel showed nothing. The only honest question is what is in the framebuffer.
        #
        # ⭐ The two-tone design makes that answerable exactly. The arrow is pure white (255,255,255) fill
        # inside pure black (0,0,0) outline, and no chrome in this theme uses either — so the FULL 10x20
        # pattern can be matched literally, at whatever position the pointer ended up. Position-independent
        # on purpose: the cursor's location after a sequence of relative mouse deltas is not something this
        # harness should have to predict.
        # ⚠ A SHAPE match, not a pixel count: a count would accept the same pixels rearranged, which is the
        # exact blindness that passed a broken terminal layout earlier in this arc.
        SHOT_CUR = os.path.join(WORK, "cursor.ppm")
        s.sendall((f"screendump {SHOT_CUR}\n").encode()); time.sleep(3.0); drain()
        found_at = cursor_arrow_find(SHOT_CUR)
        if found_at is not None:
            p(f"  ⭐⭐ AN ARROW IS ON THE PANEL at {found_at} -- matched all 200 pixels of the 10x20 shape")
            p("     (white fill inside black outline, exactly as src/cursor.cyr derives it)")
        else:
            p("  ⛔ NO ARROW FOUND IN THE FRAMEBUFFER. This is the check a serial line cannot fake.")
            p("     If 'motion reached the compositor' is True the pointer works and the DRAWING does not:")
            p("     on this path the cursor is CPU-drawn (QEMU has no amdgpu), so suspect render_cursor_cpu")
            p("     or a damage rect that never repainted -- NOT #92, which does not run here.")

        # ⛔⛔ THE F4 CLOSE PHASE. The 2026-08-08 GPU burn reported "closing application with f4 appears
        # to have issues with flashing / not disappearing or closing properly" — TWO defects wearing one
        # sentence, and this phase separates them:
        #
        #   "flashing" / "not disappearing" = the compositor's damage band. Every damage producer walks
        #     the LIVE window list, so a REMOVED window is in neither `cur` nor `prev` and its rows are
        #     never repainted. `#84 present` flips the target, so erasing takes one frame per buffer;
        #     the close got one, so one buffer lost the window and the other kept it. ⇒ Covered by a
        #     mutation-tested unit test (aethersafha tests/render.tcyr, "covered for TWO frames"),
        #     because one framebuffer here cannot show a flip. The eye on iron is the other half.
        #
        #   "not closing properly" = the CLIENT. `SETU_CLOSE` (kind 7) was in the protocol from the
        #     start, never sent and never handled, so the closed client stayed **orphaned alive** with
        #     its `#97` channel end and one of only 16 system-wide `#86` shm slots held for the boot.
        #     ⇒ THAT is what this phase gates, and it gates it on the client's own words.
        #
        # ⚠ Runs AFTER the move phase on purpose: closing a client removes a window the move phase
        # wants. Do not reorder.
        p("")
        p("=== F4 CLOSE (SETU_CLOSE -> the client exits and releases its slot) ===")
        cl_mark = len(ser())
        # ⛔ TAB ONTO A WINDOW THAT HAS A CLIENT FIRST, or this phase tests nothing. The compositor
        # seeds a window of its OWN with no `#97` peer, and `IA_FOCUS_NEXT` wraps 2 -> 0, so the single
        # TAB in the move phase above left focus on exactly that clientless window. The first run of
        # this phase therefore closed the seeded window, correctly notified nobody, and reported a
        # failure that was really a focus-order mistake in the harness.
        # ⚠ Two more TABs walk 0 -> 1 (puka) -> 2 (crab). Read the compositor's own
        # "closed a window ... " line rather than inferring the case from silence.
        key_raw("tab")
        key_raw("tab")
        key_raw("f4")
        time.sleep(3.0)
        cl = ser()[cl_mark:]
        crab_gone = "crab: compositor closed the window -- exiting" in cl
        puka_gone = "puka: compositor closed the window -- exiting" in cl
        told = "aethersafha: closed a window and sent SETU_CLOSE to its client" in cl
        orphan = "aethersafha: closed a window that has no client" in cl
        p(f"  compositor sent SETU_CLOSE   : {told}")
        p(f"  (or closed a clientless one) : {orphan}")
        p(f"  crab acknowledged the close : {crab_gone}")
        p(f"  puka acknowledged the close : {puka_gone}")
        if crab_gone or puka_gone:
            p("  ⭐ THE CLOSE REACHES THE CLIENT and the client exits. Its channel end and its #86 shm")
            p("     slot go back to the kernel on process death — that release is the whole point.")
        else:
            p("  ⛔ NO CLIENT ACKNOWLEDGED THE CLOSE. Either SETU_CLOSE was not sent (compositor side:")
            p("     comp_close_window must setu_send it to win_cfd), or the client is not handling kind")
            p("     7, or the focused window was the compositor-seeded one which HAS no client (cfd 0)")
            p("     and so correctly notifies nobody. ⚠ Check which window had focus before blaming the")
            p("     wire: TAB order decides it, and a clientless window closing silently is CORRECT.")
        SHOT_CLOSED = os.path.join(WORK, "close-after.ppm")
        s.sendall((f"screendump {SHOT_CLOSED}\n").encode()); time.sleep(3.0); drain()
        p(f"  shot: {SHOT_CLOSED} (compare with move-after — the window should be GONE, not doubled)")
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
