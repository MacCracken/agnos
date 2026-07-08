#!/usr/bin/env python3
# redirect-smoke.py — validates agnsh output redirection `cmd > file` on agnos.
#
# Boots the rootfs image with the freshly-built agnsh (the sh_run_redirect driver) +
# owl, seeds /hello.txt=OWLPROOF, and drives two commands via xHCI sendkey:
#
#   owl -p /hello.txt > /outfile   -> owl's stdout ("OWLPROOF") is redirected into the
#       FILE, NOT the console (exec_redirect#62 arms fd 1 -> the file fd agnsh opened
#       with AO_WRONLY|AO_CREAT|AO_TRUNC). So OWLPROOF must NOT appear on this line.
#   owl -p /outfile                -> reads the file back; OWLPROOF NOW appears, proving
#       the redirect wrote owl's output to the ext2 file (not a pipe, no 4088 cap).
#
# PASS = the redirect line shows no OWLPROOF (went to the file) AND the readback shows
# OWLPROOF (the file holds it). Single-core, store-and-nothing (direct file fd).
#
# Builds its own image from build/rootfs (stages the fresh agnsh over it).
import socket, subprocess, sys, time, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GNOBOOT = os.environ.get("GNOBOOT_ROOT", os.path.join(ROOT, "../gnoboot")) + "/build/BOOTX64.EFI"
AGNOS = os.path.join(ROOT, "build/agnos")
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK = os.path.join(ROOT, "build/redirect-smoke")
IMG = os.path.join(WORK, "agnos-redirect.img")
SEED = os.path.join(WORK, "seed")
SER = os.path.join(WORK, "serial-redirect.log")
MON = "/tmp/agnos-redirect.sock"
PART_OFFSET = 33 * 1048576
PART_BLOCKS = (67 * 1048576) // 4096
EXT2_FEATURES = os.environ.get("EXT2_SMOKE_FEATURES",
                               "^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg")
AGNSH_SRC = os.environ.get("AGNSH_BIN", os.path.join(ROOT, "../agnoshi/build/agnsh_agnos"))

def need(*paths):
    for p in paths:
        if not os.path.exists(p):
            print("FAIL: missing", p, "(build the kernel + stage-tools.sh + agnoshi --agnos first)"); sys.exit(1)
need(GNOBOOT, AGNOS, AGNSH_SRC, os.path.join(ROOTFS, "bin/owl"))

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

# ---- build the redirect-test image: rootfs /bin + fresh agnsh + /hello.txt ----
subprocess.run(["rm", "-rf", WORK]); os.makedirs(WORK, exist_ok=True)
subprocess.run(["cp", "-a", ROOTFS, SEED])
subprocess.run(["cp", AGNSH_SRC, os.path.join(SEED, "bin/agnsh")])      # the redirect driver
open(os.path.join(SEED, "hello.txt"), "w").write("OWLPROOF\n")
sh(f"dd if=/dev/zero of={IMG} bs=1M count=128 status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100MiB")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-RDR -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
subprocess.run(["cp", OVMF_VARS, os.path.join(WORK, "vars.fd")])
subprocess.run(["chmod", "+w", os.path.join(WORK, "vars.fd")])
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass
print("built redirect-smoke image:", IMG, "(fresh agnsh, /hello.txt=OWLPROOF)")

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-cpu", "max",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-RDR",
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
    # '>' is shift+'.' on a US layout → "shift-dot".
    km = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '/': 'slash', '>': 'shift-dot'}
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

    # Warm up the xHCI keyboard — the first post-banner keystroke is often dropped.
    typ("\n", settle=2.0)

    # 1. Redirect owl's output to a file. OWLPROOF should go to /outfile, NOT the console.
    rdir_seg = ""
    for attempt in range(2):
        rdir_seg = run_wait("owl -p /hello.txt > /outfile\n", None, timeout=20)
        # If the command line didn't echo the tail we typed, a keystroke dropped — retry.
        if "outfile" in rdir_seg: break
        typ("\n", settle=1.5)
    time.sleep(0.8)
    p("=========== owl -p /hello.txt > /outfile ==========="); p(rdir_seg[-400:])
    p("====================================================")

    # 2. Read the file back — OWLPROOF must appear now (proving the redirect wrote it).
    # Retry on a dropped keystroke (the xHCI kbd occasionally eats one, same as stage 1);
    # re-reading is idempotent since stage 1 already wrote the file.
    read_seg = ""
    for _ in range(3):
        read_seg = run_wait("owl -p /outfile\n", "OWLPROOF", timeout=20)
        if "OWLPROOF" in read_seg: break
        typ("\n", settle=1.5)
    time.sleep(0.6)
    p("=========== owl -p /outfile (readback) ==========="); p(read_seg[-400:])
    p("==================================================")

    # The redirect line must NOT echo OWLPROOF (it went to the file, not the console).
    rdir_clean = re.sub(r"\x1b\[[0-9;]*m", "", rdir_seg)
    redirected_away = "OWLPROOF" not in rdir_clean
    read_clean = re.sub(r"\x1b\[[0-9;]*m", "", read_seg)
    file_has_it = "OWLPROOF" in read_clean
    p("redirect kept OWLPROOF off the console (went to the file):", redirected_away)
    p("readback shows OWLPROOF (the file holds owl's output):", file_has_it)
    if redirected_away and file_has_it:
        p("redirect-smoke: PASS — agnsh `cmd > file` works on agnos (stdout -> ext2 file via exec_redirect#62)")
        rc = 0
    else:
        p("redirect-smoke: FAIL")
    s.sendall(b"quit\n"); time.sleep(0.2)
finally:
    qemu.terminate()
    try: qemu.wait(timeout=3)
    except subprocess.TimeoutExpired: qemu.kill()
sys.exit(rc)
