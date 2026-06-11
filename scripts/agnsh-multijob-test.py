#!/usr/bin/env python3
# agnsh-multijob-test (1.44.15) — prove MULTIPLE concurrent agnsh `&` background jobs with an
# OUT-OF-ORDER reap. Two busy-loop sleepers: /bin/sleep1 (short) launched first → LOWER proc-table
# slot; /bin/sleep2 (long) launched second → HIGHER slot. sleep1 finishes FIRST, so reaping it is a
# NON-TOP reap (the slot below a still-live one) — exactly the case the 1.44.12 non-LIFO reclaim +
# the 1.44.14 exec_resume_pid gate must handle. Sequence (HMP sendkey, ASSIST mode):
#   sleep1 &   -> "[1] <pid>"
#   sleep2 &   -> "[2] <pid>"   (both live, prompt returns)
#   (wait)     -> "SLEEP1-DONE" then "[1] Done"  (job 1 reaped OUT OF ORDER while job 2 runs)
#   version    -> agnsh responds WHILE job 2 still runs (prompt live + job table compacted)
#   (wait)     -> "SLEEP2-DONE" then "[2] Done"  (job 2 reaped)
# PASS = both launched + both DONE + both reaped (in order [1] then [2]) + version responded mid-run.
import socket, subprocess, sys, time, os, struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GNOBOOT = os.environ.get("GNOBOOT_ROOT", os.path.join(ROOT, "../gnoboot")) + "/build/BOOTX64.EFI"
AGNOS = os.path.join(ROOT, "build/agnos")
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK = os.path.join(ROOT, "build/agnsh-multijob")
IMG = os.path.join(WORK, "agnos-mj.img")
SEED = os.path.join(WORK, "seed")
SER = os.path.join(WORK, "serial-mj.log")
MON = "/tmp/agnos-mj.sock"
PART_OFFSET = 33 * 1048576
PART_BLOCKS = (67 * 1048576) // 4096
EXT2_FEATURES = os.environ.get("EXT2_SMOKE_FEATURES",
                               "^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg")
N1 = int(os.environ.get("N1", "60000000"))    # sleep1: SHORT (exits first → out-of-order reap)
N2 = int(os.environ.get("N2", "400000000"))   # sleep2: LONG  (outlives sleep1 + the version probe)

def need(*paths):
    for p in paths:
        if not os.path.exists(p):
            print("FAIL: missing", p, "(build the kernel + stage-agnsh.sh first)"); sys.exit(1)
need(GNOBOOT, AGNOS, os.path.join(ROOTFS, "bin/agnsh"))

# minimal static ELF64: busy-count N, write MSG, exit(0), spin. Busy-loop (NOT sleep_ms#41 — that
# sets sched_active=0 and freezes the scheduler); a ring-3 busy loop stays preemptible.
def build_sleeper(path, MSG, N):
    code = b""
    code += b"\x48\xC7\xC1" + struct.pack("<I", N)             # mov rcx, N
    code += b"\x48\xFF\xC9"                                    # .loop: dec rcx
    code += b"\x75\xFB"                                        # jnz .loop (rel -5)
    code += b"\x48\xC7\xC0\x01\x00\x00\x00"                    # mov rax,1 (write)
    code += b"\x48\xC7\xC7\x01\x00\x00\x00"                    # mov rdi,1 (fd)
    head_len = 7 + 3 + 2 + 7 + 7
    rest_len = 10 + 7 + 2 + 7 + 2 + 2 + 2
    msg_vaddr = 0x400000 + 120 + head_len + rest_len
    code += b"\x48\xBE" + struct.pack("<Q", msg_vaddr)         # movabs rsi, msg_vaddr
    code += b"\x48\xC7\xC2" + struct.pack("<I", len(MSG))      # mov rdx, len
    code += b"\x0F\x05"                                        # syscall (write)
    code += b"\x48\xC7\xC0\x00\x00\x00\x00"                    # mov rax,0 (exit)
    code += b"\x31\xFF"                                        # xor edi,edi
    code += b"\x0F\x05"                                        # syscall (exit)
    code += b"\xEB\xFE"                                        # jmp $ (scheduled-safe spin)
    code += MSG
    filesz = 120 + len(code)
    eh = bytearray(64); eh[0:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<H", eh, 16, 2); struct.pack_into("<H", eh, 18, 0x3E)
    struct.pack_into("<I", eh, 20, 1); struct.pack_into("<Q", eh, 24, 0x400078)
    struct.pack_into("<Q", eh, 32, 64); struct.pack_into("<H", eh, 52, 64)
    struct.pack_into("<H", eh, 54, 56); struct.pack_into("<H", eh, 56, 1)
    ph = bytearray(56)
    struct.pack_into("<I", ph, 0, 1); struct.pack_into("<I", ph, 4, 5)
    struct.pack_into("<Q", ph, 16, 0x400000); struct.pack_into("<Q", ph, 24, 0x400000)
    struct.pack_into("<Q", ph, 32, filesz); struct.pack_into("<Q", ph, 40, filesz)
    struct.pack_into("<Q", ph, 48, 0x1000)
    with open(path, "wb") as f: f.write(bytes(eh) + bytes(ph) + code)
    os.chmod(path, 0o755)

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
build_sleeper(os.path.join(SEED, "bin", "sleep1"), b"SLEEP1-DONE\n", N1)
build_sleeper(os.path.join(SEED, "bin", "sleep2"), b"SLEEP2-DONE\n", N2)
sh(f"dd if=/dev/zero of={IMG} bs=1M count=128 status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100MiB")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-MJ -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
subprocess.run(["cp", OVMF_VARS, os.path.join(WORK, "vars.fd")])
subprocess.run(["chmod", "+w", os.path.join(WORK, "vars.fd")])
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass
print(f"built multijob image (sleep1 N={N1} / sleep2 N={N2})")

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-cpu", "max",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-MJ",
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
    km = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '/': 'slash', '&': 'shift-7'}
    def typ(word, settle=1.5):
        for ch in word:
            key = km.get(ch, ch)
            if ch.isupper(): key = "shift-" + ch.lower()
            s.sendall(("sendkey " + key + "\n").encode()); time.sleep(0.10); drain()
        time.sleep(settle)
    def waitfor(markers, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            t = ser()
            if all(m in t for m in markers): return True
            time.sleep(0.5)
        return False

    ok = False
    for _ in range(480):
        if "agnoshi" in ser(): ok = True; break
        time.sleep(0.25)
    p("banner seen:", ok)
    if not ok: p("FAIL: no agnsh banner"); sys.exit(1)
    time.sleep(1.0)

    typ("sleep1 &\n"); typ("sleep2 &\n")
    launched = waitfor(["[1]", "[2]"], 25)
    # job 1 (short) finishes first -> reaped OUT OF ORDER while job 2 still runs.
    j1 = waitfor(["SLEEP1-DONE", "[1] Done"], 90)
    # prompt LIVE with job 2 still running.
    base = len(ser()); typ("version\n", settle=1.0)
    ver = waitfor(["agnoshi 1.6.0"], 25) and ("agnoshi 1.6.0" in ser()[base:])
    # job 2 finishes + reaped.
    j2 = waitfor(["SLEEP2-DONE", "[2] Done"], 150)

    tail = ser()
    p("=========== final tail ==========="); p(tail[-700:]); p("============================")
    # ordering: [1] Done must precede [2] Done (job 1 reaped before job 2).
    order_ok = ("[1] Done" in tail and "[2] Done" in tail and tail.index("[1] Done") < tail.index("[2] Done"))
    p("both jobs launched ([1] + [2]):", launched)
    p("job 1 ran + reaped OUT OF ORDER ([1] Done while job 2 live):", j1)
    p("prompt LIVE mid-run (version responded):", ver)
    p("job 2 ran + reaped ([2] Done):", j2)
    p("reap order [1] before [2]:", order_ok)
    if launched and j1 and ver and j2 and order_ok:
        p("agnsh-multijob-test: PASS — two concurrent `&` jobs, out-of-order reap, prompt stayed live")
        rc = 0
    else:
        p("agnsh-multijob-test: FAIL")
    s.sendall(b"quit\n"); time.sleep(0.2)
finally:
    qemu.terminate()
    try: qemu.wait(timeout=3)
    except subprocess.TimeoutExpired: qemu.kill()
sys.exit(rc)
