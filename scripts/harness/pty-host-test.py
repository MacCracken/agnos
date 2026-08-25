#!/usr/bin/env python3
# agnsh-bg-test (1.44.13 schedulable agnsh) — prove agnsh `&` background jobs on the real
# agnos kernel in QEMU. A trailing `&` launches the program via spawn_path(#43, NON-BLOCKING),
# so the prompt returns immediately + stays live; agnsh polls the bg pid with waitpid(#4) and
# prints "[n] Done" when it exits. The shell-stays-live property the whole 1.44.x arc built to.
#
# Sequence (xHCI keyboard via HMP sendkey, ASSIST mode = no confirm prompts):
#   sleeper &     -> "[1] <pid>" prints + the prompt RETURNS (non-blocking #43, not execwait)
#   version       -> agnsh responds WHILE the bg job runs (prompt is live; 2nd "agnoshi 1.")
#   (wait)        -> "SLEEPER-DONE" (the bg job ran to completion) then "[1] Done" (agnsh reaped it)
# PASS = "[1]" launched + the version response printed BEFORE SLEEPER-DONE (concurrency) +
#        "SLEEPER-DONE" + "[1] Done". Builds its own image from build/rootfs + a seeded /bin/sleeper.
import socket, subprocess, sys, time, os, struct

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GNOBOOT = os.environ.get("GNOBOOT_ROOT", os.path.join(ROOT, "../gnoboot")) + "/build/BOOTX64.EFI"
AGNOS = os.path.join(ROOT, "build/agnos")
ROOTFS = os.path.join(ROOT, "build/rootfs")
WORK = os.path.join(ROOT, "build/pty-host")
IMG = os.path.join(WORK, "agnos-pty.img")
SEED = os.path.join(WORK, "seed")
SER = os.path.join(WORK, "serial-pty.log")
MON = "/tmp/agnos-pty.sock"
PART_OFFSET = 33 * 1048576
PART_BLOCKS = (67 * 1048576) // 4096
EXT2_FEATURES = os.environ.get("EXT2_SMOKE_FEATURES",
                               "^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg")
SLEEP_N = int(os.environ.get("SLEEP_N", "300000000"))   # busy-loop count (bump if it exits too soon)

def need(*paths):
    for p in paths:
        if not os.path.exists(p):
            print("FAIL: missing", p, "(build the kernel + stage-agnsh.sh first)"); sys.exit(1)
need(GNOBOOT, AGNOS, os.path.join(ROOTFS, "bin/agnsh"))

# ---- a minimal static ELF64 /bin/sleeper: busy-count SLEEP_N, write SLEEPER-DONE, exit(0), spin.
# Busy-count (NOT sleep_ms#41 — that sets sched_active=0 and would FREEZE the scheduler + agnsh);
# a ring-3 busy loop stays preemptible so agnsh time-slices alongside it.
def build_sleeper(path):
    MSG = b"SLEEPER-DONE\n"
    code = b""
    code += b"\x48\xC7\xC1" + struct.pack("<I", SLEEP_N)      # mov rcx, N
    code += b"\x48\xFF\xC9"                                    # .loop: dec rcx
    code += b"\x75\xFB"                                        # jnz .loop (rel -5)
    code += b"\x48\xC7\xC0\x01\x00\x00\x00"                    # mov rax,1 (write)
    code += b"\x48\xC7\xC7\x01\x00\x00\x00"                    # mov rdi,1 (fd)
    msg_vaddr = 0x400078 + (len(b"") )                         # placeholder; fixed below
    # code length up to the movabs is fixed; compute the msg vaddr from the final layout.
    # write: mov rax,1(7) mov rdi,1(7) movabs rsi(10) mov rdx,len(7) syscall(2)
    # exit:  mov rax,0(7) xor edi,edi(2) syscall(2)  spin: jmp $(2)   -> then MSG
    head_len = 7 + 3 + 2 + 7 + 7                               # mov rcx + loop + write rax/rdi so far
    rest_len = 10 + 7 + 2 + 7 + 2 + 2 + 2                      # movabs + rdx + syscall + exit + spin
    msg_off = 120 + head_len + rest_len                        # file offset of MSG
    msg_vaddr = 0x400000 + msg_off
    code += b"\x48\xBE" + struct.pack("<Q", msg_vaddr)         # movabs rsi, msg_vaddr
    code += b"\x48\xC7\xC2" + struct.pack("<I", len(MSG))      # mov rdx, len
    code += b"\x0F\x05"                                        # syscall (write)
    code += b"\x48\xC7\xC0\x00\x00\x00\x00"                    # mov rax,0 (exit)
    code += b"\x31\xFF"                                        # xor edi,edi
    code += b"\x0F\x05"                                        # syscall (exit)
    code += b"\xEB\xFE"                                        # jmp $ (scheduled-safe spin)
    code += MSG
    filesz = 120 + len(code)
    eh = bytearray(64)
    eh[0:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<H", eh, 16, 2)        # e_type = ET_EXEC
    struct.pack_into("<H", eh, 18, 0x3E)     # e_machine = x86-64
    struct.pack_into("<I", eh, 20, 1)        # e_version
    struct.pack_into("<Q", eh, 24, 0x400078) # e_entry
    struct.pack_into("<Q", eh, 32, 64)       # e_phoff
    struct.pack_into("<H", eh, 52, 64)       # e_ehsize
    struct.pack_into("<H", eh, 54, 56)       # e_phentsize
    struct.pack_into("<H", eh, 56, 1)        # e_phnum
    ph = bytearray(56)
    struct.pack_into("<I", ph, 0, 1)         # p_type = PT_LOAD
    struct.pack_into("<I", ph, 4, 5)         # p_flags = R+X
    struct.pack_into("<Q", ph, 16, 0x400000) # p_vaddr
    struct.pack_into("<Q", ph, 24, 0x400000) # p_paddr
    struct.pack_into("<Q", ph, 32, filesz)   # p_filesz
    struct.pack_into("<Q", ph, 40, filesz)   # p_memsz
    struct.pack_into("<Q", ph, 48, 0x1000)   # p_align
    blob = bytes(eh) + bytes(ph) + code      # ehdr(64) + phdr(56) = 120, then code
    with open(path, "wb") as f: f.write(blob)
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
# ⭐ ipc BITE 9: stage the ring-3 PTY host and the unmodified child it hosts.
# ⚠ BUILD-IF-ABSENT, mirroring stage_one's `agnos/*` rows (scripts/burn/stage-tools.sh). These two
# binaries were TRACKED until 2026-08-24, so this branch could never fire and the "missing" error it
# printed was unreachable — the harness always found a fossil and staged it. .gitignore's
# `tests/*/build/` block has the measurements; the short version is that a committed --agnos binary is
# evidence about whatever source existed when someone last ran a compiler, and a stale oracle does not
# fail, it agrees. Building here makes the absence produce a BUILD, not an error telling a human to go
# type the command that is right there in the string. In-tree row, so it compiles under agnos's own
# pin — the same reason stage_one scopes its auto-build to `agnos/*` and not to sibling repos.
for _b in ("ptyhost", "ptyx"):
    _src = os.path.join(ROOT, "tests/chan/build", _b)
    if not os.path.exists(_src):
        print("building", _b, "(--agnos) — no build present ...")
        _r = subprocess.run("cyrius build --agnos %s.cyr build/%s" % (_b, _b),
                            shell=True, cwd=os.path.join(ROOT, "tests/chan"),
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if _r.returncode != 0 or not os.path.exists(_src):
            print("FAIL: could not build", _src, "\n", _r.stderr.decode("latin1")[:400])
            sys.exit(1)
    subprocess.run(["cp", _src, os.path.join(SEED, "bin", _b)])
    subprocess.run(["chmod", "+x", os.path.join(SEED, "bin", _b)])
sh(f"dd if=/dev/zero of={IMG} bs=1M count=128 status=none")
sh(f"parted -s {IMG} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100MiB")
sh(f"sgdisk -t 2:8300 {IMG} >/dev/null")
sh(f"mformat -i {IMG}@@1048576 -F")
sh(f"mmd -i {IMG}@@1048576 ::EFI ::EFI/BOOT ::boot")
sh(f"mcopy -i {IMG}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
sh(f"mcopy -i {IMG}@@1048576 {AGNOS} ::boot/agnos")
sh(f"mkfs.ext2 -F -q -L AGNOS-PTY -b 4096 -m 0 -O {EXT2_FEATURES} -d {SEED} -E offset={PART_OFFSET} {IMG} {PART_BLOCKS}")
subprocess.run(["cp", OVMF_VARS, os.path.join(WORK, "vars.fd")])
subprocess.run(["chmod", "+w", os.path.join(WORK, "vars.fd")])
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass
print(f"built pty image: {IMG} (/bin/ptyhost + /bin/ptyx)")

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-cpu", "max",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
    "-drive", f"if=pflash,format=raw,file={WORK}/vars.fd",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-PTY",
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
    # ⛔ EVERY CHARACTER THE TEST TYPES NEEDS A KEY NAME. A missing entry does not error — QEMU
    # silently drops the sendkey, so the GUEST RECEIVES A DIFFERENT COMMAND than the test thinks
    # it sent. '|' was absent here: `grep . /etc/ssl/cert.pem | wc` arrived as
    # `grep . /etc/ssl/cert.pem  wc`, grep prefixed every line with a filename (which it only
    # does for MULTIPLE files), and the run looked like a broken pipeline redirect for an hour.
    km = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '/': 'slash', '&': 'shift-7',
          '|': 'shift-backslash', '>': 'shift-dot', '<': 'shift-comma', '_': 'shift-minus',
          ',': 'comma', ':': 'shift-semicolon', '=': 'equal', '*': 'shift-8'}
    def typ(word, settle=2.0):
        for ch in word:
            key = km.get(ch, ch)
            if ch.isupper(): key = "shift-" + ch.lower()
            s.sendall(("sendkey " + key + "\n").encode())
            time.sleep(0.10); drain()
        time.sleep(settle)
    def run_wait(cmd, marker, timeout=30):
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
    time.sleep(1.0)

    # ⛔ IT MUST RUN IN THE BACKGROUND, AND THAT IS NOT A CONVENIENCE. A foreground command is
    # run-to-completion under IF=0, so the child `ptyhost` spawns would never be SCHEDULED — the host
    # would spin its whole retry budget against a peer that has not executed a single instruction.
    # That is exactly how the first cut of this test failed: zero records, and no trace of the child.
    seg = run_wait("ptyhost &\n", "PTYHOST-DONE", timeout=90)

    ran      = "PTYHOST-START"   in seg
    spawned  = "PTYHOST-SPAWNED" in seg
    stdin_ok = "PTYHOST-OUT PTYX-STDIO-OK" in seg
    done_ok  = "PTYHOST-OUT PTYX-DONE"     in seg
    passed   = "PTYHOST-PASS"    in seg

    p("host ran            :", ran)
    p("endowed + spawned   :", spawned)
    p("child read its stdin:", stdin_ok)
    p("child stdout arrived:", done_ok)
    p("host verdict        :", passed)

    # ⛔ ptyx REPORTS ITS FAILURES ON ITS STDOUT, WHICH IS THE CHANNEL — so seeing one at all proves
    # the WRITE direction worked and only the READ direction failed. Separating those is most of the
    # diagnostic value here.
    if "PTYX-STDIN-READ-FAILED" in seg:
        p("  -> read(2) on fd 0 FAILED: the VFS_CHAN read arm or the PTY-mode placement is missing")
    if "PTYX-STDIN-CONTENT-WRONG" in seg:
        p("  -> fd 0 delivered the WRONG bytes: record framing or endpoint pairing is wrong")

    # ⭐ PHASE 2 — host the REAL SHELL. agnsh predates this band by years and reads fd 0 with a
    # plain `sys_read`; nothing in it was adapted for a channel. If it prints its banner and answers
    # a command over the endowed channel, the PTY is real rather than a shape that only toys fit.
    shell_seg = run_wait("ptyhost agnsh &\n", "PTYHOST-DONE", timeout=120)
    shell_ran   = "PTYHOST-SHELL-MODE" in shell_seg
    shell_spoke = "agnoshi" in shell_seg
    p("")
    p("shell hosted        :", shell_ran)
    p("agnsh spoke over PTY:", shell_spoke)

    if not ran:
        p("pty-host-test: FAIL — /bin/ptyhost never ran (VACUOUS: nothing below proves anything)")
    elif ran and spawned and stdin_ok and done_ok and passed and shell_ran and shell_spoke:
        p("pty-host-test: PASS — an UNMODIFIED program's stdio rode a channel, and so did AGNSH: "
          "plain read(2) on fd 0 returned the host's record, plain write(2) on fd 1 reached the "
          "host's endpoint, and the real shell spoke over the PTY")
        rc = 0
    else:
        p("pty-host-test: FAIL")
    p("serial:", SER)
finally:
    qemu.terminate()
    try: qemu.wait(timeout=3)
    except subprocess.TimeoutExpired: qemu.kill()
sys.exit(rc)
