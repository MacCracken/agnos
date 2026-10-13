#!/usr/bin/env python3
# vtd-iommu-test.py — agnos 1.57.10 (VTD): boot kernel/arch/x86_64/iommu.cyr with Intel VT-d DMA translation ON and prove
# every DMA engine the kernel drives keeps working through it. Wrapped by scripts/smoke/vtd-smoke.sh (a sweep row), which
# builds the VTD_SELFTEST kernel this boots and hands it over in VTD_KERNEL.
#
# ⛔ WHY IT EXISTS (issue 2026-09-26-vt-d-xhci-never-granted-and-iommu-never-booted). Until 1.57.10 no boot had ever turned
# translation on: QEMU q35 + `-device intel-iommu` publishes a DMAR, and iommu_init returned -1 at its first step. So the
# pre-init grant log (xHCI / HID / MSC grant BEFORE iommu_init), the post-TE invalidation (Caching Mode), the table walker,
# the per-bus context tables, the ECAP.C clflush path and every driver's grants were gated by nothing but reading.
#
# ⭐ TWO BOOTS, each a different corner of the unit (QEMU 11.1 intel-iommu, intremap=off; every virtio device is modern-only
# with iommu_platform=on — QEMU refuses it on a transitional device, and WITHOUT it virtio DMA bypasses VT-d entirely):
#   A  -smp 1 (TCG)   caching-mode=on  aw-bits=39 -> 3-level tables, CM=1: a new leaf after TE must be PSI-invalidated.
#      NVMe root disk, qemu-xhci with usb-kbd + usb-storage (seeded MSCLBA0!), ich9-ahci + a SATA disk (seeded AHCIVTD!),
#      virtio-blk (a whole-disk exFAT), virtio-net (SLiRP DHCP), intel-hda + hda-duplex.
#   B  -smp 4 (KVM, else multi-threaded TCG)  caching-mode=off  aw-bits=48 -> 4-level tables, CM=0: no invalidation.
#      NVMe root disk, the xHCI BEHIND a pcie-root-port (bus 1: the per-bus context tables — until 1.57.10 iommu_init
#      REFUSED any device off bus 0) with usb-kbd, virtio-blk (exFAT), virtio-net.
# Each boot: banner-gated (a boot whose log never shows "AGNOS kernel v" is VOID, retried up to QEMU_TRIES, never scored);
# then agnsh (ring 3, loaded from NVMe under translation) is driven through the xHCI keyboard with HMP `sendkey`.
#
# WHAT IS CHECKED (per boot):
#   kernel  the unit line (levels / cm / buses / replayed >= 1), "VT-d enabled"; the VTD_SELFTEST arms (blocked PASS —
#           an ungranted page untouched + the fault recorded against the NVMe; grant PASS — exactly one new leaf and
#           exactly the invalidation CM needs; allowed PASS — byte-exact); the boot DMA check: faults=0, late=1, psi/dsi/wbf
#           as CM dictates, inv_fail=0, refused=0; every device's own evidence (typed lines answered 3/3, the stick's and
#           the SATA disk's LBA 0 byte-exact, exFAT mounted on virtio-blk, DHCP ACK over virtio-net, HDA LPIB advancing,
#           agnsh's banner); no "iommu: FAULT", no refusal, no latched invariant line (SMOKE_INVARIANT_DENY, _invdeny.py).
#   QEMU    its OWN trace (-D, never the kernel's word): vtd_dmar_enable 1; every vtd_dmar_fault is the selftest's (the
#           NVMe, the selftest page) and there is one; a vtd_iotlb_page_update for EVERY device's requester id (its DMA
#           was translated, not bypassed); GCMD written exactly SRTP 0x40000000 then TE 0x80000000 (the GSTS-based command,
#           no stale one-shot bits); the IVA/IOTLB registers (0xF0/0xF8): CM=1 -> the init global flush + ONE PSI whose
#           IVA names the selftest page with AM 9; CM=0 -> the global flush only. QEMU's stderr: a "translation failure"
#           only for the selftest page.
#   ⚠ QEMU never caches a failed translation, so a deleted CM invalidation is invisible to the DEVICES; the register trace
#     above is what catches it (mutation M2 in the 1.57.10 VTD report).
# ⭐ 1.57.13 (QI) — BOTH INVALIDATION INTERFACES (issue 2026-09-26-vt-d-queued-invalidation). QEMU's unit offers ECAP.QI,
# so A and B now run the QUEUE (inv=queued) and a third boot, AR (A's devices, CM=1), runs the REGISTER fallback from a
# kernel built VTD_REGISTER_INV=1 (VTD_KERNEL_REG). The oracle for the queue is QEMU's own descriptor trace, as
# vtd_reg_write is for the registers: vtd_inv_qi_setup names the kernel's queue page (256 entries) and IQA was written
# with it; the processed invalidation descriptors (vtd_inv_desc) are EXACTLY the global context-cache (low 0x11), the
# global IOTLB (low 0xd2: G=01 DR DW) and, under CM=1, ONE page-selective IOTLB (low 0x100f2: G=11 DR DW DID 1, high =
# the selftest page | AM 9); every wait's status write (vtd_inv_desc_wait_sw) goes to the kernel's status page with the
# sequence the kernel issued (the selftest's IQE recovery shows its sequence twice: the copy, then the original wait);
# NO register invalidation (CCMD 0x28, IVA 0xf0, IOTLB 0xf8) is written while the queue is on; GCMD is QIE, then
# SRTP|QIE, then TE|QIE; QEMU's stderr carries exactly the one "invalid inv desc ... (unknown type)" the selftest's
# malformed descriptor causes. AR: the 1.57.10 register checks, and no queue event at all.
# ⭐ 1.57.13 (the VTD review) — FOUR BOOTS: BR (B's machine: -smp 4 under KVM, CM=0, 4-level, the xHCI behind a root port)
# runs the register interface too, so the fallback is booted in its CM=0 / SMP / 4-level form and the "global flush ONLY"
# register check is reached again (with A and B both on the queue it had become dead code). THE UNIT'S OWN MEMORY: the
# kernel names its own chunk (`IOMMU: own structures - chunk 0x…`) and QEMU's trace must show RTADDR, IQA and every wait's
# status write inside it, and NO translation through it (no vtd_iotlb_page_update whose IOVA or SL leaf lies in it) —
# until the review the root table, the queue and the status page sat inside the 2 MB region the replayed xHCI grant had
# opened to every device. Selftest arm E (`vtdst: own structures`) walks the tables in the kernel and makes the boot's ONE
# deliberate refused grant (at an own address — required exactly once); arm F (`vtdst: qi stall`, the queue only) lets one
# wait outlast a short bound (the queue STALLS, not dies) and settles it at the next submission. The boot DMA check gains
# ` stall=`; neither `DEAD` nor `STALLED` may be printed.
# Env: VTD_KERNEL (the kernel to boot; default build/agnos), VTD_KERNEL_REG (the VTD_REGISTER_INV kernel for AR / BR),
#      VTD_CONFIGS (default "A B AR BR"), SMOKE_KVM (0 = TCG for B / BR), QEMU_TRIES (default 6), AGNSH_BIN /
#      AGNOSHI_ROOT, GNOBOOT_ROOT.
# Exit: 0 every check passed on every boot · 1 a check failed · 2 VOID (a boot never handed off, nothing failed) or setup.
import os, re, shutil, socket, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _freshness import refuse_stale_kernel
from _invdeny import smoke_invariant_deny
from _qsock import qsock

KERNEL = os.environ.get("VTD_KERNEL", os.path.join(ROOT, "build/agnos"))
refuse_stale_kernel(ROOT, KERNEL)
KERNEL_REG = os.environ.get("VTD_KERNEL_REG", "")          # 1.57.13: the VTD_REGISTER_INV kernel (boot AR)
if KERNEL_REG:
    refuse_stale_kernel(ROOT, KERNEL_REG)
AGNSH = os.environ.get("AGNSH_BIN", os.path.join(os.environ.get("AGNOSHI_ROOT", os.path.join(ROOT, "../agnoshi")),
                                                 "build/agnsh_agnos"))
GNOBOOT = os.environ.get("GNOBOOT_ROOT", os.path.join(ROOT, "../gnoboot")) + "/build/BOOTX64.EFI"
WORK = os.path.join(ROOT, "build/vtd-smoke")
TRIES = int(os.environ.get("QEMU_TRIES", "6"))
INV_DENY = re.compile(smoke_invariant_deny())
EXT2_FEATURES = os.environ.get("EXT2_SMOKE_FEATURES", "^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg")


def p(*a):
    print(*a, flush=True)


for need in (KERNEL, AGNSH, GNOBOOT) + ((KERNEL_REG,) if KERNEL_REG else ()):
    if not os.path.exists(need):
        p("FAIL (setup): missing", need, "— this harness measured NOTHING"); sys.exit(2)
OVMF_CODE = OVMF_VARS = None
for c in ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/edk2/x64/OVMF_CODE.fd",
          "/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_CODE_4M.fd"):
    if os.path.exists(c): OVMF_CODE = c; break
for c in ("/usr/share/edk2/x64/OVMF_VARS.4m.fd", "/usr/share/edk2/x64/OVMF_VARS.fd",
          "/usr/share/OVMF/OVMF_VARS.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"):
    if os.path.exists(c): OVMF_VARS = c; break
if not OVMF_CODE or not OVMF_VARS:
    p("FAIL (setup): OVMF not found — this harness measured NOTHING"); sys.exit(2)
for tool in ("qemu-system-x86_64", "parted", "sgdisk", "mformat", "mmd", "mcopy", "mkfs.ext2", "mkfs.exfat"):
    if shutil.which(tool) is None:
        p("FAIL (setup): missing tool", tool, "— this harness measured NOTHING"); sys.exit(2)


def sh(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if r.returncode != 0:
        p("FAIL (setup): image step failed:", cmd, "\n", r.stderr.decode("latin1")[:400]); sys.exit(2)


def accel(smp):
    if smp <= 1: return ["-cpu", "max"]
    if os.access("/dev/kvm", os.W_OK) and os.environ.get("SMOKE_KVM", "1") == "1": return ["-enable-kvm", "-cpu", "host"]
    return ["-accel", "tcg,thread=multi", "-cpu", "max"]


# requester ids (bus << 8 | dev << 3 | fn) of the devices each boot drives; every one must show a vtd_iotlb_page_update.
# devs = the device set make_images builds; qi = the invalidation interface the boot must run (1.57.13).
CONFIGS = {
    "A": dict(smp=1, iommu="intel-iommu,intremap=off,caching-mode=on,aw-bits=39", levels=3, cm=1, buses=1, devs="A", qi=1,
              sids={"xhci 00:03.0": 0x18, "nvme 00:04.0": 0x20, "virtio-blk 00:05.0": 0x28, "virtio-net 00:06.0": 0x30,
                    "hda 00:07.0": 0x38, "ahci 00:08.0": 0x40}),
    "B": dict(smp=4, iommu="intel-iommu,intremap=off,aw-bits=48", levels=4, cm=0, buses=2, devs="B", qi=1,
              sids={"xhci 01:00.0 (behind the root port)": 0x100, "nvme 00:04.0": 0x20, "virtio-blk 00:05.0": 0x28,
                    "virtio-net 00:06.0": 0x30}),
}
CONFIGS["AR"] = dict(CONFIGS["A"], qi=0)                    # A's machine, the register interface (VTD_REGISTER_INV)
CONFIGS["BR"] = dict(CONFIGS["B"], qi=0)                    # B's machine (CM=0, SMP, 4-level), the register interface
TRACE = ["vtd_dmar_enable", "vtd_dmar_fault", "vtd_frr_new", "vtd_iotlb_page_update", "vtd_reg_write",
         "vtd_switch_address_space", "vtd_inv_qi_enable", "vtd_inv_qi_setup", "vtd_inv_desc", "vtd_inv_desc_wait_sw"]
VOID_RE = re.compile(r"gnoboot: fail @|BootManagerMenuApp|Please select boot device")
KEYS = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot'}
# agnsh's own ANSWER to each typed line (agnsh-type-test.py's set: the answer, never the echo, is the evidence). ⚠ Not its
# "agnoshi 1." for `version`: agnsh is 2.x (measured "agnoshi 2.0.3", 1.57.10), and only text AFTER the mark is searched,
# so the banner's own "agnoshi " (printed before the mark) cannot answer for the typed line.
ANSWERS = (("help", "show this help"), ("version", "agnoshi "), ("mode", "Current mode:"))


def make_images(cfg, w, KERNEL):
    seed = os.path.join(w, "seed")
    os.makedirs(os.path.join(seed, "bin"))
    shutil.copy(AGNSH, os.path.join(seed, "bin", "agnsh"))
    root = os.path.join(w, "root.img")
    sh(f"dd if=/dev/zero of={root} bs=1M count=128 status=none")
    sh(f"parted -s {root} mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 100MiB")
    sh(f"sgdisk -t 2:8300 {root} >/dev/null")
    sh(f"mformat -i {root}@@1048576 -F")
    sh(f"mmd -i {root}@@1048576 ::EFI ::EFI/BOOT ::boot")
    sh(f"mcopy -i {root}@@1048576 {GNOBOOT} ::EFI/BOOT/BOOTX64.EFI")
    sh(f"mcopy -i {root}@@1048576 {KERNEL} ::boot/agnos")
    sh(f"mcopy -n -i {root}@@1048576 ::boot/agnos {w}/agnos.readback")
    if open(f"{w}/agnos.readback", "rb").read() != open(KERNEL, "rb").read():
        p("FAIL (setup): the kernel read back from the ESP is not the kernel under test"); sys.exit(2)
    sh(f"mkfs.ext2 -F -q -L AGNOS-VTD -b 4096 -m 0 -O {EXT2_FEATURES} -d {seed} -E offset={33 * 1048576} {root} "
       f"{(67 * 1048576) // 4096}")
    exf = os.path.join(w, "exfat.img")                       # virtio-blk: a whole-disk exFAT (exfat_init probes it)
    sh(f"dd if=/dev/zero of={exf} bs=1M count=8 status=none")
    sh(f"mkfs.exfat -c 512 -L VTDEXF {exf} >/dev/null")
    args = ["-drive", f"file={root},format=raw,if=none,id=d0", "-device", "nvme,drive=d0,serial=AGNOS-VTD,addr=0x4",
            "-drive", f"file={exf},format=raw,if=none,id=vb0",
            "-device", "virtio-blk-pci,drive=vb0,disable-legacy=on,iommu_platform=on,addr=0x5",
            "-netdev", "user,id=n0",
            "-device", "virtio-net-pci,netdev=n0,disable-legacy=on,iommu_platform=on,romfile=,addr=0x6"]
    if CONFIGS[cfg]["devs"] == "A":
        stick = os.path.join(w, "stick.img")
        sh(f"dd if=/dev/zero of={stick} bs=1M count=8 status=none")
        sh(f"printf 'MSCLBA0!' | dd of={stick} bs=1 conv=notrunc status=none")
        sata = os.path.join(w, "sata.img")
        sh(f"dd if=/dev/zero of={sata} bs=1M count=8 status=none")
        sh(f"printf 'AHCIVTD!' | dd of={sata} bs=1 conv=notrunc status=none")
        args += ["-device", "qemu-xhci,id=xhci,addr=0x3", "-device", "usb-kbd,bus=xhci.0",
                 "-drive", f"file={stick},format=raw,if=none,id=stick", "-device", "usb-storage,bus=xhci.0,drive=stick",
                 "-drive", f"file={sata},format=raw,if=none,id=sd0", "-device", "ich9-ahci,id=ahci0,addr=0x8",
                 "-device", "ide-hd,drive=sd0,bus=ahci0.0",
                 "-audiodev", "none,id=snd0", "-device", "intel-hda,id=hda0,addr=0x7",
                 "-device", "hda-duplex,bus=hda0.0,audiodev=snd0"]
    else:
        args += ["-device", "pcie-root-port,id=rp1,bus=pcie.0,chassis=1,slot=1,addr=0x3",
                 "-device", "qemu-xhci,id=xhci,bus=rp1", "-device", "usb-kbd,bus=xhci.0"]
    return args


class Boot:
    def __init__(self, cfg, attempt):
        c = CONFIGS[cfg]
        self.w = os.path.join(WORK, f"{cfg}{attempt}")
        shutil.rmtree(self.w, ignore_errors=True)
        os.makedirs(self.w)
        self.ser = os.path.join(self.w, "serial.log")
        self.trace = os.path.join(self.w, "trace.log")
        self.err = os.path.join(self.w, "qemu-stderr.log")
        self.mon = qsock(os.path.join(self.w, "mon.sock"))  # 1.57.13: short + per-tree (_qsock.py)
        vars_fd = os.path.join(self.w, "vars.fd")
        shutil.copy(OVMF_VARS, vars_fd); os.chmod(vars_fd, 0o644)
        devs = make_images(cfg, self.w, KERNEL if c["qi"] else KERNEL_REG)
        open(self.ser, "w").close()
        cmd = (["qemu-system-x86_64", "-machine", "q35", "-m", "512M"] + accel(c["smp"]) + ["-smp", str(c["smp"]),
               "-device", c["iommu"],
               "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
               "-drive", f"if=pflash,format=raw,file={vars_fd}"] + devs +
               ["-serial", f"file:{self.ser}", "-display", "none", "-no-reboot",
                "-monitor", f"unix:{self.mon},server,nowait", "-D", self.trace] +
               sum([["-trace", f"enable={t}"] for t in TRACE], []))
        self.cmd = cmd
        self.q = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=open(self.err, "wb"))
        self.s = None
        for _ in range(100):
            try:
                self.s = socket.socket(socket.AF_UNIX); self.s.connect(self.mon); break
            except OSError:
                self.s = None; time.sleep(0.1)
        if self.s: self.s.settimeout(0.5)

    def text(self):
        try: return open(self.ser, "rb").read().decode("latin1")
        except OSError: return ""

    def wait(self, pat, timeout):
        dl = time.time() + timeout
        while time.time() < dl:
            m = re.search(pat, self.text())
            if m: return m
            if self.q.poll() is not None: return re.search(pat, self.text())
            time.sleep(0.1)
        return None

    def drain(self):
        if not self.s: return
        self.s.setblocking(False)
        try:
            while True:
                if not self.s.recv(65536): break
        except OSError: pass
        self.s.settimeout(0.5)

    def typ(self, word):
        for ch in word:
            self.s.sendall(("sendkey " + KEYS.get(ch, ch) + "\n").encode())
            time.sleep(0.12); self.drain()
        time.sleep(1.4)

    def stop(self):
        try:
            if self.s:
                self.s.sendall(b"quit\n"); time.sleep(0.3)
        except OSError: pass
        try: self.q.wait(5)
        except subprocess.TimeoutExpired:
            self.q.kill()
            try: self.q.wait(5)
            except subprocess.TimeoutExpired: pass
        try: self.s and self.s.close()
        except OSError: pass
        for n in os.listdir(self.w):                             # the disks are ~150 MB a boot; the logs stay
            if n.endswith(".img") or n == "seed" or n == "agnos.readback":
                fp = os.path.join(self.w, n)
                shutil.rmtree(fp, ignore_errors=True) if os.path.isdir(fp) else os.remove(fp)


def klines(t):
    return [re.sub(r"^\[ *[0-9]+\.[0-9]+\] ", "", ln.rstrip("\r")) for ln in t.split("\n")]


npass = nfail = nvoid = 0


def ok(m):
    global npass; npass += 1; p("  PASS:", m)


def bad(m):
    global nfail; nfail += 1; p("  FAIL:", m)


def check(cond, m):
    ok(m) if cond else bad(m)


for cfg in os.environ.get("VTD_CONFIGS", "A B AR BR").split():
    c = CONFIGS[cfg]
    if not c["qi"] and not KERNEL_REG:
        bad(f"[{cfg}] no VTD_KERNEL_REG (a VTD_REGISTER_INV=1 kernel) — the register interface was NOT booted"); continue
    p(f"\n=== boot {cfg}: -smp {c['smp']}  accel: {' '.join(accel(c['smp']))}  -device {c['iommu']} ===")
    b = None
    died = False
    for attempt in range(1, TRIES + 1):
        b = Boot(cfg, attempt)
        m = b.wait(r"AGNOS kernel v|gnoboot: fail @|BootManagerMenuApp|Please select boot device", 120)
        t = b.text()
        if "AGNOS kernel v" in t: break
        b.stop()
        # qemu-dwell.sh's qemu_boot_class: a hand-off line with no "fail @" and no banner is the KERNEL dying, never a VOID
        if "handing off to kernel" in t and "gnoboot: fail @" not in t and "BootManagerMenuApp" not in t:
            bad(f"[{cfg}] attempt {attempt}: gnoboot handed off and the kernel never printed its banner "
                f"(the kernel under test died — not a VOID, not retried; log {b.ser})")
            died = True; b = None; break
        why = VOID_RE.search(t)
        p(f"  (VOID attempt {attempt}: {why.group(0) if why else 'no banner'} — the kernel never ran; log kept: {b.ser})")
        b = None
    if b is None:
        if not died:
            p(f"  VOID: [{cfg}] the firmware never handed off in {TRIES} attempts — not scored"); nvoid += 1
        continue
    typed = []
    try:
        dwell = 240 if c["smp"] == 1 else 150
        if not b.wait(r"agnoshi ", dwell):
            bad(f"[{cfg}] agnsh never printed its banner (ring 3 from the NVMe root, under translation) — nothing typed")
        else:
            prev, quiet = -1, 0
            for _ in range(40):                                  # let COM1 go quiet before marking (agnsh-type-test)
                cur = len(b.text()); quiet = quiet + 1 if cur == prev else 0; prev = cur
                if quiet >= 4: break
                time.sleep(0.25)
            mark = len(b.text())
            b.typ("\n")                                          # the first key of a session is swallowed (known)
            for cmd, _ in ANSWERS: b.typ(cmd + "\n")
            time.sleep(1.0)
            new = b.text()[mark:]
            typed = [cmd for cmd, ans in ANSWERS if ans in new]
    finally:
        b.stop()
    t = b.text()
    kl = klines(t)
    joined = "\n".join(kl)
    tr = open(b.trace, errors="replace").read() if os.path.exists(b.trace) else ""
    err = open(b.err, errors="replace").read() if os.path.exists(b.err) else ""
    p(f"  logs: {b.ser}  {b.trace}  {b.err}")
    for ln in kl:
        if re.match(r"(IOMMU|iommu|vtdst|ACPI: DMAR)", ln): p("       |", ln)

    # --- the kernel's own lines
    m = re.search(r"^ACPI: DMAR at \d+ IOMMU base=4275634176 units=1 rmrr=0$", joined, re.M)
    check(m, f"[{cfg}] the DMAR was parsed: one unit at 0xFED90000, no RMRR")
    inv = "queued" if c["qi"] else "register"
    m = re.search(r"^IOMMU: VT-d unit 0xfed90000 ver 1\.0 levels=(\d+) cm=(\d+) rwbf=0 coherent=0 sp2m=1 buses=(\d+) "
                  r"rmrr=0 replayed=(\d+) iotlb=0xf8 inv=(queued|register)$", joined, re.M)
    check(m and int(m.group(1)) == c["levels"] and int(m.group(2)) == c["cm"] and int(m.group(3)) == c["buses"]
          and m.group(5) == inv,
          f"[{cfg}] the unit came up with levels={c['levels']} cm={c['cm']} buses={c['buses']} inv={inv} "
          f"(got {m.group(0) if m else 'no unit line'})")
    check(m and int(m.group(4)) >= 1, f"[{cfg}] the pre-init grants (xHCI/HID/MSC, before iommu_init) were REPLAYED "
                                      f"(replayed={m.group(4) if m else '?'} >= 1)")
    check("IOMMU: VT-d enabled, DMA restricted" in kl, f"[{cfg}] translation is ON (GSTS.TES latched)")
    check(not re.search(r"iommu: translation NOT enabled|IOMMU: init failed", joined), f"[{cfg}] no init refusal")
    for arm in ("blocked", "grant", "allowed"):
        check(f"vtdst: {arm} PASS" in kl, f"[{cfg}] VTD_SELFTEST {arm} arm")
    # 1.57.13 — arm D: the queue's IQE recovery (the queue only; the register boot must SKIP it, not pass it)
    if c["qi"]:
        check("vtdst: qi recovery PASS" in kl, f"[{cfg}] VTD_SELFTEST qi recovery arm: a malformed descriptor raised IQE, "
                                               f"was recovered (NOT performed, one IQE), the queue drained and kept working")
    else:
        check("vtdst: qi recovery SKIP the register interface is in use" in kl,
              f"[{cfg}] VTD_SELFTEST qi recovery arm SKIPPED (the register interface is in use)")
        check("iommu: queued invalidation OFF - forced by VTD_REGISTER_INV (test build): register interface" in kl,
              f"[{cfg}] the kernel says the queue was turned off by the VTD_REGISTER_INV knob")
    # 1.57.13 (the VTD review) — arm E: the unit's own structures out of every device's reach; arm F: a slow wait stalls
    check("vtdst: own structures PASS" in kl, f"[{cfg}] VTD_SELFTEST own structures arm: root / context / SL tables and the "
                                             f"queue pages all in the own chunk, which no grant can open")
    if c["qi"]:
        check("vtdst: qi stall PASS" in kl, f"[{cfg}] VTD_SELFTEST qi stall arm: a wait that outlasted the bound STALLED the "
                                           f"queue (not dead) and the next submission settled it")
    else:
        check("vtdst: qi stall SKIP the register interface is in use" in kl,
              f"[{cfg}] VTD_SELFTEST qi stall arm SKIPPED (the register interface is in use)")
    check("vtdst: PASS" in kl and "vtdst: done" in kl, f"[{cfg}] VTD_SELFTEST ran to its last line and passed")
    want_psi = 1 if c["cm"] else 0
    m = re.search(r"^vtdst: grant after TE new_leaf=(\d+) psi=\+(\d+) dsi=\+(\d+) wbf=\+(\d+) cm=(\d+) rwbf=0$", joined, re.M)
    check(m and (m.group(1), m.group(2), m.group(3), m.group(4)) == ("1", str(want_psi), "0", "0"),
          f"[{cfg}] a grant after TE: one new leaf and {'ONE page-selective invalidation (CM=1)' if c['cm'] else 'NO invalidation (CM=0)'}"
          f" (got {m.group(0) if m else 'no grant line'})")
    m = re.search(r"^IOMMU: boot DMA check - faults=(\d+) leaves=(\d+) late=(\d+) psi=(\d+) dsi=(\d+) wbf=(\d+) "
                  r"inv_fail=(\d+) refused=(\d+) qi=(\d+) iqe=(\d+) ite=(\d+) ice=(\d+) stall=(\d+)$", joined, re.M)
    check(m and m.group(1) == "0", f"[{cfg}] the boot DMA check drained NO fault after every boot DMA user "
                                   f"(got {m.group(0) if m else 'no check line'})")
    check(m and (m.group(3), m.group(4), m.group(5), m.group(6), m.group(7), m.group(8)) ==
          ("1", str(want_psi), "0", "0", "0", "1"),
          f"[{cfg}] the grant path's counters: late=1 psi={want_psi} dsi=0 wbf=0 inv_fail=0 refused=1 (arm E's deliberate one)")
    # queue submissions: the init context-cache + IOTLB flushes, the CM=1 PSI, the recovery arm's bare wait (its malformed
    # submission is NOT performed and not counted), the stall arm's second wait (its held one is NOT performed); exactly the
    # one deliberate IQE and the one deliberate stall; never an ITE / ICE (no device TLB).
    want_q = (2 + want_psi + 2, 1, 1) if c["qi"] else (0, 0, 0)
    check(m and (int(m.group(9)), int(m.group(10)), m.group(11), m.group(12), int(m.group(13))) ==
          (want_q[0], want_q[1], "0", "0", want_q[2]),
          f"[{cfg}] the queue's counters: qi={want_q[0]} iqe={want_q[1]} ite=0 ice=0 stall={want_q[2]} "
          f"(got {' '.join(m.groups()[8:]) if m else 'no check line'})")
    check(not re.search(r"iommu: queued invalidation (DEAD|STALLED)", joined), f"[{cfg}] the queue never died, and no stall "
                                                                              f"was left standing")
    check(not re.search(r"iommu: FAULT", joined), f"[{cfg}] no fault printed")
    # --- the unit's OWN memory (1.57.13, the VTD review)
    om = re.search(r"^IOMMU: own structures - chunk 0x([0-9a-f]+) chunks=(\d+) pages=(\d+) - never granted$", joined, re.M)
    own = int(om.group(1), 16) if om else -1
    def in_own(a): return own >= 0 and own <= a < own + 0x200000
    check(om and om.group(2) == "1" and own % 0x200000 == 0 and own >= 0x1000000 and int(om.group(3)) >= 3,
          f"[{cfg}] the kernel names ONE own chunk, 2 MB-aligned, above the default 16 MB grant "
          f"(got {om.group(0) if om else 'no own-structures line'})")
    refl = re.findall(r"iommu: DMA grant REFUSED for phys 0x([0-9a-f]+) - a device DMA there will fault", joined)
    check(len(refl) == 1 and in_own(int(refl[0], 16)) and len(re.findall(r"iommu: DMA grant REFUSED", joined)) == 1,
          f"[{cfg}] exactly ONE grant refused, and it is arm E's grant of an own-chunk page: {refl}")    # every DMA engine's own evidence, all AFTER translation went on
    check("hid: keyboard configured" in t, f"[{cfg}] the xHCI keyboard bound (its rings were granted BEFORE iommu_init)")
    check(len(typed) == len(ANSWERS), f"[{cfg}] typed lines reached agnsh through the xHCI keyboard under translation: "
                                      f"{len(typed)}/{len(ANSWERS)} answered {typed}")
    check("kybernet: exec /bin/agnsh" in t and "agnoshi " in t and "kybernet: emergency shell" not in t,
          f"[{cfg}] agnsh loaded from the NVMe root disk and ran (NVMe DMA under translation)")
    check(re.search(r"^exfat: mounted backend=1 whole-disk", joined, re.M),
          f"[{cfg}] exFAT mounted from virtio-blk (backend 1): virtio-blk DMA with ACCESS_PLATFORM")
    check(re.search(r"^dhcp: ACK ip=10\.0\.2\.15", joined, re.M), f"[{cfg}] DHCP ACK over virtio-net (RX + TX DMA)")
    if c["devs"] == "A":
        check("msc: slot 1 LBA0 first 8 bytes: 77 83 67 76 66 65 48 33" in joined,
              "[A] the USB stick's LBA 0 read byte-exact (xHCI bulk DMA; MSC granted before iommu_init)")
        check("ahci: port 0 LBA0 first 8 bytes: 65 72 67 73 86 84 68 33" in joined,
              "[A] the SATA disk's LBA 0 read byte-exact (AHCI DMA, granted after TE)")
        check("hda: stream running (LPIB advancing)" in joined, "[A] the HDA stream DMA advances")
    dn = [ln for ln in kl if INV_DENY.search(ln)]
    check(not dn, f"[{cfg}] no latched kernel invariant line fired" + (f": {dn[:3]}" if dn else ""))

    # --- QEMU's own trace
    check(re.search(r"^vtd_dmar_enable enable 1$", tr, re.M), f"[{cfg}] QEMU: DMA remapping enabled (vtd_dmar_enable 1)")
    sm = re.search(r"^vtdst: blocked status=0x[0-9a-f]+ dirty=\d+ faults=\d+ sid=0x[0-9a-f]+ nvme=0x([0-9a-f]+) "
                   r"addr=0x([0-9a-f]+) ", joined, re.M)
    region = int(sm.group(2), 16) if sm else -1
    nvme_sid = int(sm.group(1), 16) if sm else -1
    faults = re.findall(r"^vtd_dmar_fault sid 0x([0-9a-f]+) fault (\d+) addr 0x([0-9a-f]+) write (\d)$", tr, re.M)
    stray = [f for f in faults if not (int(f[0], 16) == nvme_sid and region <= int(f[2], 16) < region + 4096
                                       and f[3] == "1")]
    check(faults and not stray, f"[{cfg}] QEMU: every DMAR fault is the selftest's blocked write (NVMe, page "
                                f"0x{region:x}) — {len(faults)} fault event(s), {len(stray)} stray {stray[:3]}")
    upd = set(int(s, 16) for s in re.findall(r"^vtd_iotlb_page_update IOTLB page update sid 0x([0-9a-f]+) ", tr, re.M))
    for name, sid in c["sids"].items():
        check(sid in upd, f"[{cfg}] QEMU translated {name}'s DMA (vtd_iotlb_page_update sid 0x{sid:x})")
    regw = re.findall(r"^vtd_reg_write addr 0x([0-9a-f]+) size 0x[0-9a-f]+ value 0x([0-9a-f]+)$", tr, re.M)
    tin = re.findall(r"^vtd_iotlb_page_update IOTLB page update sid 0x[0-9a-f]+ iova 0x([0-9a-f]+) slpte 0x([0-9a-f]+) ",
                     tr, re.M)
    leafreg = set(int(sl, 16) & 0x000FFFFFFFE00000 for io, sl in tin)    # every 2 MB region a device translated through
    rta = [int(v, 16) for a, v in regw if a == "20"]
    check(rta and all(in_own(a) and (a & ~0x1FFFFF) not in leafreg for a in rta),
          f"[{cfg}] QEMU: RTADDR (the root table) written inside the own chunk 0x{own:x}, in no region a device translated "
          f"through: {[hex(a) for a in rta]}")
    thru = [(i, s) for i, s in tin if in_own(int(i, 16)) or in_own(int(s, 16) & 0x000FFFFFFFE00000)]
    check(tin and not thru, f"[{cfg}] QEMU: no device DMA translated into or through the own chunk "
                            f"({len(tin)} IOTLB updates, {len(thru)} touching it {thru[:3]})")
    gcmd = [v for a, v in regw if a == "18"]
    want_gcmd = ["4000000", "44000000", "84000000"] if c["qi"] else ["40000000", "80000000"]
    check(gcmd == want_gcmd, f"[{cfg}] QEMU: GCMD written exactly "
                             f"{'QIE, then SRTP|QIE, then TE|QIE' if c['qi'] else 'SRTP then TE'} "
                             f"(GSTS & 0x96FFFFFF | bit, no stale one-shot bits): {gcmd}")
    iva = [v for a, v in regw if a in ("f0", "f4")]
    iotlb = [v for a, v in regw if a in ("f8", "fc")]
    ccmd = [v for a, v in regw if a in ("28", "2c")]
    qregs = [(a, v) for a, v in regw if a in ("88", "8c", "90", "94")]
    qen = re.findall(r"^vtd_inv_qi_enable enabled (\d)$", tr, re.M)
    qset = re.findall(r"^vtd_inv_qi_setup addr 0x([0-9a-f]+) size (\d+)$", tr, re.M)
    descs = re.findall(r"^vtd_inv_desc invalidate desc type (.+?) high 0x([0-9a-f]+) low 0x([0-9a-f]+)$", tr, re.M)
    waits = re.findall(r"^vtd_inv_desc_wait_sw wait invalidate status write addr 0x([0-9a-f]+) data 0x([0-9a-f]+)$",
                       tr, re.M)
    qerr = re.findall(r"invalid inv desc: hi=0, lo=0 \(unknown type\)", err)
    if c["qi"]:
        # 1.57.13 — the QUEUE, with QEMU's descriptor trace as the oracle
        qm = re.search(r"^IOMMU: queued invalidation - queue 0x([0-9a-f]+) status 0x([0-9a-f]+) submitted=(\d+)$",
                       joined, re.M)
        qp = int(qm.group(1), 16) if qm else -1
        sp = int(qm.group(2), 16) if qm else -1
        check(qm and qm.group(3) == "2", f"[{cfg}] the queue line: both init invalidations went through the queue "
                                         f"(got {qm.group(0) if qm else 'no queue line'})")
        check(in_own(qp) and in_own(sp) and (qp & ~0x1FFFFF) not in leafreg and (sp & ~0x1FFFFF) not in leafreg,
              f"[{cfg}] the queue page 0x{qp:x} and the status page 0x{sp:x} are own-chunk pages, in no region a device "
              f"translated through (no device can forge a descriptor or write the status word)")
        check(qen == ["1"] and qset == [(f"{qp:x}", "256")],
              f"[{cfg}] QEMU: the queue enabled once, at the kernel's queue page 0x{qp:x}, 256 descriptors: "
              f"enable {qen} setup {qset}")
        check([v for a, v in regw if a == "90"] == [f"{qp:x}"],
              f"[{cfg}] QEMU: IQA written once, with the queue page (DW 0, QS 0): {[v for a, v in regw if a == '90']}")
        check(not iva and not iotlb and not ccmd,
              f"[{cfg}] QEMU: NO register invalidation while the queue is on: CCMD {ccmd} IVA {iva} IOTLB {iotlb}")
        got = [(ty, hi, lo) for ty, hi, lo in descs if ty != "wait"]
        want = [("context-cache", "0", "11"), ("iotlb", "0", "d2")]
        if c["cm"]:
            want.append(("iotlb", f"{region | 9:x}", "100f2"))
        check(got == want, f"[{cfg}] QEMU: the invalidation descriptors processed are exactly the init global context-cache "
                           f"+ global IOTLB" + (" + ONE page-selective IOTLB of the selftest page (DID 1, DR DW, AM 9)"
                                                 if c["cm"] else " — none after TE on a CM=0 unit") + f": {got}")
        n0 = 2 + want_psi
        # ... then arm D (the copy over the malformed slot, its wait, the bare wait behind it), then arm F (the held wait,
        # written when the selftest hands it over late, then the wait of the submission that settled it)
        want_seq = list(range(1, n0 + 2)) + [n0 + 1, n0 + 2] + [n0 + 3, n0 + 4]
        seqs = [int(d, 16) for a, d in waits]
        check(waits and all(int(a, 16) == sp for a, d in waits) and seqs == want_seq,
              f"[{cfg}] QEMU: every wait wrote its status to the kernel's status page 0x{sp:x}, in the sequence issued "
              f"{want_seq} (the recovery arm's sequence twice: the copy over the malformed slot, then the wait; the stall "
              f"arm's held wait, then the one that settled it): {waits}")
        wd = [(hi, lo) for ty, hi, lo in descs if ty == "wait"]
        check(wd == [(f"{sp:x}", f"{(s << 32) | 0x25:x}") for s in want_seq],
              f"[{cfg}] QEMU: every wait descriptor is type 5 | SW only (no IF, no fence), status data = its sequence: "
              f"{wd[:6]}")
        check(len(qerr) == 1, f"[{cfg}] QEMU stderr: exactly ONE 'invalid inv desc: hi=0, lo=0 (unknown type)' — the "
                              f"recovery arm's malformed descriptor, and no other queue error ({len(qerr)})")
    elif c["cm"]:
        check(iva == [f"{region | 9:x}"] and iotlb == ["9003000000000000", "b003000100000000"],
              f"[{cfg}] QEMU: the init global IOTLB flush, then ONE page-selective invalidation of the selftest page "
              f"(IVA 0x{region | 9:x} = page | AM 9; IOTLB 0xb003000100000000 = IVT|PSI|DR|DW|DID 1): IVA {iva} IOTLB {iotlb}")
    else:
        check(iva == [] and iotlb == ["9003000000000000"],
              f"[{cfg}] QEMU: the init global IOTLB flush ONLY — no invalidation after TE on a CM=0 unit: "
              f"IVA {iva} IOTLB {iotlb}")
    if not c["qi"]:
        check(not qen and not qset and not descs and not waits and not qregs and not qerr,
              f"[{cfg}] QEMU: no queue event at all on the register interface: enable {qen} setup {qset} "
              f"descriptors {len(descs)} waits {len(waits)} IQT/IQA writes {qregs[:4]} queue errors {len(qerr)}")
    tf = re.findall(r"detected translation failure \(dev=([0-9a-f:]+), iova=0x([0-9a-f]+)\)", err)
    tstray = [x for x in tf if not (region <= int(x[1], 16) < region + 4096)]
    check(not tstray, f"[{cfg}] QEMU stderr: a translation failure only for the selftest page {tstray[:3]}")

p(f"\n=== vtd-iommu-test: {npass} passed, {nfail} failed" + (f", {nvoid} VOID boot(s)" if nvoid else "") + " ===")
if nfail: sys.exit(1)
if nvoid: sys.exit(2)
sys.exit(0)
