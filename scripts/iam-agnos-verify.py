#!/usr/bin/env python3
# iam-agnos-verify — prove iam (fastfetch-equivalent) renders its system card on
# the real agnos kernel in QEMU, exercising the mihi agnos sysinfo/uname probes.
# Boots gnoboot+OVMF over an NVMe ext2 rootfs holding /bin/iam + /bin/agnsh, drives
# agnsh via HMP sendkey (ASSIST mode), types `iam`, polls serial for the card.
#
# PASS = the card prints with "Distro" + "AGNOS" (mihi_distro agnos branch) AND a
#        "Memory" line (mihi_mem_total via sysinfo#35) AND "Uptime"/"CPU"/"Kernel".
#
# Prereqs:  sh scripts/build.sh           (plain kernel)
#           cp <iam>/build/iam_agnos build/rootfs/bin/iam ; agnsh staged
# Modeled on scripts/agnsh-delegation-test.py.
import socket, subprocess, sys, time, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GNOBOOT = os.environ.get("GNOBOOT_ROOT", os.path.join(ROOT, "../gnoboot")) + "/build/BOOTX64.EFI"
AGNOS = os.path.join(ROOT, "build/agnos")
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK = os.path.join(ROOT, "build/iam-verify")
IMG = os.path.join(WORK, "agnos-iam.img")
SEED = os.path.join(WORK, "seed")
SER = os.path.join(WORK, "serial-iam.log")
MON = "/tmp/agnos-iam.sock"
PART_OFFSET = 33 * 1048576
PART_BLOCKS = (67 * 1048576) // 4096
FEAT = os.environ.get("EXT2_SMOKE_FEATURES", "^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg")

def need(*paths):
    for p in paths:
        if not os.path.exists(p):
            print("FAIL: missing", p, "(build kernel + stage /bin/iam + /bin/agnsh first)"); sys.exit(1)
need(GNOBOOT, AGNOS, os.path.join(ROOTFS, "bin/iam"), os.path.join(ROOTFS, "bin/agnsh"))

OVMF_CODE = OVMF_VARS = None
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd","/usr/share/edk2/x64/OVMF_CODE.fd","/usr/share/OVMF/OVMF_CODE.fd","/usr/share/OVMF/OVMF_CODE_4M.fd"):
    if os.path.exists(c): OVMF_CODE = c; break
for c in ("/usr/share/edk2/x64/OVMF_VARS.4m.fd","/usr/share/edk2/x64/OVMF_VARS.fd","/usr/share/OVMF/OVMF_VARS.fd","/usr/share/OVMF/OVMF_VARS_4M.fd"):
    if os.path.exists(c): OVMF_VARS = c; break
if not OVMF_CODE or not OVMF_VARS: print("FAIL: OVMF not found"); sys.exit(1)

def sh(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if r.returncode != 0: print("FAIL build step:", cmd, "\n", r.stderr.decode("latin1")[:400]); sys.exit(1)

subprocess.run(["rm","-rf",WORK]); os.makedirs(WORK, exist_ok=True)
subprocess.run(["cp","-a",ROOTFS,SEED])
sh(f"dd if=/dev/zero of={IMG} bs=1M count=128 status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100MiB")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F"); sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI"); sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-IAM -b 4096 -m 0 -O {FEAT} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
subprocess.run(["cp",OVMF_VARS,os.path.join(WORK,"vars.fd")]); subprocess.run(["chmod","+w",os.path.join(WORK,"vars.fd")])
open(SER,"w").close()
try: os.unlink(MON)
except FileNotFoundError: pass
print("built iam-verify image:", IMG)

qemu = subprocess.Popen([
    "qemu-system-x86_64","-machine","q35","-m","512M","-cpu","max",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device","nvme,drive=disk0,serial=AGNOS-IAM",
    "-device","qemu-xhci,id=xhci","-device","usb-kbd,bus=xhci.0",
    "-serial", f"file:{SER}","-display","none","-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def p(*a): print(*a, flush=True)
rc = 1
try:
    s = None
    for _ in range(60):
        try: s = socket.socket(socket.AF_UNIX); s.connect(MON); break
        except OSError: time.sleep(0.2)
    if s is None: p("FAIL: no monitor"); sys.exit(1)
    s.settimeout(1.0)
    def drain():
        try:
            while True: s.recv(65536)
        except OSError: pass
    def ser():
        try: return open(SER,"rb").read().decode("latin1")
        except OSError: return ""
    km = {' ':'spc','\n':'ret','-':'minus','.':'dot','/':'slash'}
    def typ(word, settle=2.0):
        for ch in word:
            key = km.get(ch, ch)
            if ch.isupper(): key = "shift-"+ch.lower()
            s.sendall(("sendkey "+key+"\n").encode()); time.sleep(0.10); drain()
        time.sleep(settle)

    ok = False
    for _ in range(480):
        if "agnoshi" in ser(): ok = True; break
        time.sleep(0.25)
    p("agnsh banner seen:", ok)
    if not ok: p("FAIL: no agnsh banner"); sys.exit(1)

    m = len(ser())
    typ("iam\n", settle=1.0)                       # bareword iam -> /bin/iam (402 KB ELF off ext2, TCG-slow)
    deadline = time.time() + 60
    seg = ""
    while time.time() < deadline:
        seg = ser()[m:]
        if "Memory" in seg and "AGNOS" in seg: break
        time.sleep(0.5)
    p("=========== iam output on agnos ==========="); p(seg if seg.strip() else "(empty / wedged)"); p("===========================================")

    distro_ok = "AGNOS" in seg                     # mihi_distro agnos branch
    mem_ok    = "Memory" in seg                    # mihi_mem_total via sysinfo#35
    up_ok     = "Uptime" in seg                    # mihi_uptime_secs via sysinfo
    cpu_ok    = "CPU" in seg                        # card rendered
    kern_ok   = "Kernel" in seg
    p("Distro: AGNOS (mihi_distro agnos branch):", distro_ok)
    p("Memory line (mihi_mem_total via sysinfo):", mem_ok)
    p("Uptime line (mihi_uptime_secs via sysinfo):", up_ok)
    p("CPU + Kernel lines (card rendered):", cpu_ok and kern_ok)
    if distro_ok and mem_ok and cpu_ok and kern_ok:
        p("iam-agnos-verify: PASS — iam renders the system card on agnos via mihi's sysinfo/uname probes")
        rc = 0
    else:
        p("iam-agnos-verify: FAIL")
    s.sendall(b"quit\n"); time.sleep(0.2)
finally:
    qemu.terminate()
    try: qemu.wait(timeout=3)
    except subprocess.TimeoutExpired: qemu.kill()
sys.exit(rc)
