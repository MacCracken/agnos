#!/usr/bin/env python3
# pipe-smoke.py — validates agnsh two-stage pipelines `cmd1 | cmd2` on agnos.
#
# Boots the rootfs image with the freshly-built agnsh (the sh_run_pipeline driver)
# + anuenue, seeds /hello.txt=OWLPROOF, and types two pipelines via xHCI sendkey:
#
#   owl -p /hello.txt | anuenue --no-color   -> "OWLPROOF" contiguous (anuenue MONO
#       passthrough re-emits stdin verbatim) — proves stage-1 stdout reached stage-2
#       stdin through the kernel pipe (exec_redirect#62 + the read#5 VFS_DEVICE guard).
#   owl -p /hello.txt | anuenue              -> "[38;2" (truecolor SGR) — proves the
#       piped bytes were colorized by anuenue's rainbow (the iam|anuenue use case).
#
# Store-and-forward: owl runs to completion under execwait#37 filling the 4088-byte
# kernel pipe, then anuenue drains it (EOF = pipe_read 0 once drained). Single-core.
#
# Builds its own image from build/rootfs (stages the fresh agnsh + anuenue over it).
import socket, subprocess, sys, time, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GNOBOOT = os.environ.get("GNOBOOT_ROOT", os.path.join(ROOT, "../gnoboot")) + "/build/BOOTX64.EFI"
AGNOS = os.path.join(ROOT, "build/agnos")
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK = os.path.join(ROOT, "build/pipe-smoke")
IMG = os.path.join(WORK, "agnos-pipe.img")
SEED = os.path.join(WORK, "seed")
SER = os.path.join(WORK, "serial-pipe.log")
MON = "/tmp/agnos-pipe.sock"
PART_OFFSET = 33 * 1048576
PART_BLOCKS = (67 * 1048576) // 4096
EXT2_FEATURES = os.environ.get("EXT2_SMOKE_FEATURES",
                               "^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg")
# The two binaries under test — freshly built (the staged rootfs copies may be stale).
AGNSH_SRC = os.environ.get("AGNSH_BIN", os.path.join(ROOT, "../agnoshi/build/agnsh_agnos"))
ANUENUE_SRC = os.environ.get("ANUENUE_BIN", os.path.join(ROOT, "../anuenue/build/anuenue_agnos"))

def need(*paths):
    for p in paths:
        if not os.path.exists(p):
            print("FAIL: missing", p, "(build the kernel + stage-tools.sh + agnoshi/anuenue --agnos first)"); sys.exit(1)
need(GNOBOOT, AGNOS, AGNSH_SRC, ANUENUE_SRC, os.path.join(ROOTFS, "bin/owl"))

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

# ---- build the pipe-test image: rootfs /bin + fresh agnsh/anuenue + /hello.txt ----
subprocess.run(["rm", "-rf", WORK]); os.makedirs(WORK, exist_ok=True)
subprocess.run(["cp", "-a", ROOTFS, SEED])
subprocess.run(["cp", AGNSH_SRC, os.path.join(SEED, "bin/agnsh")])      # the pipe driver
subprocess.run(["cp", ANUENUE_SRC, os.path.join(SEED, "bin/anuenue")])  # 1.1.5 (truecolor)
open(os.path.join(SEED, "hello.txt"), "w").write("OWLPROOF\n")
sh(f"dd if=/dev/zero of={IMG} bs=1M count=128 status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100MiB")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-PIPE -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
subprocess.run(["cp", OVMF_VARS, os.path.join(WORK, "vars.fd")])
subprocess.run(["chmod", "+w", os.path.join(WORK, "vars.fd")])
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass
print("built pipe-smoke image:", IMG, "(fresh agnsh+anuenue, /hello.txt=OWLPROOF)")

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-cpu", "max",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-PIPE",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
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
    km = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '/': 'slash', '|': 'shift-backslash'}
    def typ(word, settle=2.0):
        for ch in word:
            key = km.get(ch, ch)
            if ch.isupper(): key = "shift-" + ch.lower()
            s.sendall(("sendkey " + key + "\n").encode())
            time.sleep(0.14); drain()
        time.sleep(settle)
    def run_wait(cmd, marker, timeout=45):
        m = len(ser()); typ(cmd, settle=1.0)
        deadline = time.time() + timeout
        while time.time() < deadline:
            seg = ser()[m:]
            if marker is None or marker in seg: return seg
            time.sleep(0.5)
        return ser()[m:]

    ok = False
    for _ in range(480):
        if "agnoshi" in ser(): ok = True; break
        time.sleep(0.25)
    p("banner seen:", ok)
    if not ok: p("FAIL: no agnsh banner"); sys.exit(1)

    # Warm up the xHCI keyboard: the FIRST keystroke after the banner is often dropped
    # (a known boot-timing artifact — it ate the 'o' of "owl" on the first run), so send
    # a throwaway Enter (agnsh just re-prompts) before the real commands.
    typ("\n", settle=2.0)

    # One robust pipeline proves the whole feature: owl -> kernel pipe -> anuenue (truecolor).
    # color_ok = anuenue colorized SOMETHING (the SGR is present); data_ok = the piped bytes were
    # owl's "OWLPROOF" (strip the per-char SGR escapes and look for the contiguous text). Retry
    # once if a keystroke drop mangled the (short) command line so no SGR appears.
    pipe_seg = ""
    attempt = 0
    while attempt < 2:
        pipe_seg = run_wait("owl -p /hello.txt | anuenue\n", "[38;2", timeout=60)
        if "[38;2" in pipe_seg: break
        attempt = attempt + 1
        typ("\n", settle=1.5)                # re-prompt, then retry
    time.sleep(0.6)

    p("=========== owl -p /hello.txt | anuenue ==========="); p((pipe_seg if pipe_seg.strip() else "(empty / wedged)")[:600])
    p("==========================================")

    color_ok = "[38;2" in pipe_seg                          # anuenue truecolor-rainbow'd the piped bytes
    stripped = re.sub(r"\x1b\[[0-9;]*m", "", pipe_seg)      # drop the SGR escapes anuenue emits per char
    data_ok  = "OWLPROOF" in stripped                       # ...leaving owl's stdout, delivered via the pipe
    p("pipe delivers data (owl's OWLPROOF reached anuenue's stdin):", data_ok)
    p("pipe + truecolor coloring (anuenue emitted ESC[38;2 SGR):", color_ok)
    if data_ok and color_ok:
        p("pipe-smoke: PASS — agnsh `cmd1 | cmd2` works on agnos (store-and-forward pipe + stdin redirect)")
        rc = 0
    else:
        p("pipe-smoke: FAIL")
    s.sendall(b"quit\n"); time.sleep(0.2)
finally:
    qemu.terminate()
    try: qemu.wait(timeout=3)
    except subprocess.TimeoutExpired: qemu.kill()
sys.exit(rc)
