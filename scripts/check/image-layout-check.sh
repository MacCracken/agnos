#!/bin/sh
# image-layout-check.sh — the kernel image vs the FIXED kernel stacks in PMM region 1.
#
# ⛔⛔ WHY THIS EXISTS (2026-09-13, 1.57.2). Three kernel stacks live at hard-coded addresses inside
# the boot shim's 0-4 MB identity map, and every one of them was placed by reading the image end
# off a build and choosing a number above it:
#   · AP1-3 boot stacks + TSS.RSP0     [0x310000, 0x340000)  gdt.cyr tss_get_cpu_stack,
#                                                            smp.cyr trampoline `add eax, 0x310000`
#   · BSP boot stack (grows DOWN)       top 0x380000          boot_shim.cyr step 12 / ELF64 step 1
#   · BSP TSS.RSP0                      top 0x3C0000          gdt.cyr tss_kernel_stack
#   · syscall kstacks                   0x3D0000 / 0x3F0000   (now region 7 per syscall_hw.cyr)
# Nothing re-checked those placements when the image grew. The 1.57.2 rekha face added ~410 KB of
# .rodata and moved the LOAD end from ~0x2FA2xx to 0x35E770 — straight across the AP window, so
# CPUs 1-3 now push their boot frames and every CPL0 timer/scheduler frame INTO kernel .rodata
# (2 MB RW identity pages: no fault, no signal). The only fit check that arc ran was "end < 0x400000",
# which bounds the wrong thing. This tree had already paid for the identical class twice on iron
# (gdt.cyr: RSP0 0x200000 inside live .bss -> triple fault; boot_shim.cyr: the 0x200000 boot stack
# overwrote "exfatu: upcase-checksum OK", found by gdb watchpoint) and both fixes were "pick a
# higher number" with a comment quoting an image end that has been stale ever since.
#
# WHAT IT ASSERTS, from `build/agnos` (the ELF64 the bootloader loads) and the face module the build
# consumed:
#   1. HARD: LOAD end <= 0x370000 — the BSP boot stack keeps at least the same 64 KB every per-CPU
#      window gets (0x380000 - 0x10000). Above that the boot path walks into the image on QEMU AND
#      iron. FAIL, no exception: relocate the stacks (the operator's call — see the issue) rather
#      than raising this.
#   2. The AP window. The real invariant is LOAD end <= 0x310000 and that is what PASSES cleanly.
#      1.57.2 ships with the image OVER the window, tolerated ONLY because the bytes under it are
#      rekha's string-literal chunks, which are read exactly once — rekha_face_default_copy from
#      kfont_init — thousands of lines before smp_start_aps wakes an AP, and never again (the served
#      face is the verified 2 MB direct-map copy). So while the overlap lasts this gate requires:
#        · every byte of [0x310000, min(0x340000, end)) is a rekha chunk byte or a chunk NUL —
#          decoded from face_data.cyr itself, no .ttf needed — and prints the margin from the top
#          AP stack (0x340000) to the first LIVE byte above it (0x113 = 275 B at 1.57.2: any .text or
#          .bss shrink over that slides kernel kprint literals under CPU3's frames, silently);
#        · the chunk literals stay dead after init: rekha_face_default_copy has ONE caller in
#          kernel/ and rekha_face_default_chunk ONE caller in the face module. A second consumer
#          (re-verify, hot reload, a second copy) would read AP stack garbage on any -smp >= 2 boot
#          while every -smp 1 gate stayed green.
#      Anything else under the window — .text, .bss, a live literal — is a FAIL.
#
# ⚠ VACUITY: the caller must hand this the binary THIS run built (check.sh gates it behind the
# arity build's rc exactly as the size gate is). A fossil build/agnos measures a different tree.
# Mutation-tested 2026-09-13 on scratch copies: a chunk byte changed in the face module, a byte
# patched inside the window in the ELF, and p_memsz bumped past 0x370000 each FAIL with the named
# reason; the shipped tree PASSES with the overlap report.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGNOS="${1:-$ROOT/build/agnos}"
REKHA_DIR="${REKHA_DIR:-$ROOT/../rekha}"
FACE="${2:-$REKHA_DIR/fonts/face_data.cyr}"
KFONT="$ROOT/kernel/core/kfont.cyr"

[ -f "$AGNOS" ] || { echo "FAIL: $AGNOS not found — no image to measure"; exit 1; }
[ -f "$FACE" ]  || { echo "FAIL: $FACE not found — cannot decode the face chunks the build embedded"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 not available — the ELF cannot be parsed"; exit 1; }

# Source-level half: the chunk literals must have exactly one reader chain (copy <- kfont_init).
# Comment lines are dropped first: both names are mentioned in prose (the face module's own header
# names rekha_face_default_chunk(i)), and a prose mention is not a reader.
NCOPY=$(grep -rh 'rekha_face_default_copy(' "$ROOT/kernel" --include='*.cyr' | grep -v '^[[:space:]]*#' | grep -vc 'fn rekha_face_default_copy' || true)
NCHUNK_CALLS=$(grep 'rekha_face_default_chunk(' "$FACE" | grep -v '^[[:space:]]*#' | grep -vc 'fn rekha_face_default_chunk' || true)
rc=0
if [ "$NCOPY" != "1" ]; then
    echo "FAIL: rekha_face_default_copy( has $NCOPY call sites under kernel/ — the chunk literals must be read ONCE, from kfont_init, before smp_start_aps (they sit under the AP stacks)"; rc=1
fi
if [ "$NCHUNK_CALLS" != "1" ]; then
    echo "FAIL: rekha_face_default_chunk( has $NCHUNK_CALLS call sites in $FACE — expected exactly one (inside rekha_face_default_copy)"; rc=1
fi
grep -q 'kfont_init' "$KFONT" || { echo "FAIL: $KFONT has no kfont_init — the once-at-boot reader this gate reasons about is gone"; rc=1; }

python3 - "$AGNOS" "$FACE" <<'EOF' || rc=1
import re, struct, sys
agnos, face = sys.argv[1], sys.argv[2]
d = open(agnos, 'rb').read()
AP_LO, AP_HI = 0x310000, 0x340000       # AP1 stack floor .. CPU3 stack top (gdt.cyr / smp.cyr)
BSP_BOOT_TOP = 0x380000                 # boot_shim.cyr step 12 / ELF64 step 1
HARD_CEIL = BSP_BOOT_TOP - 0x10000      # the BSP boot stack keeps the per-CPU 64 KB budget
fail = []
if d[:4] != b'\x7fELF' or d[4] != 2:
    print("FAIL: not an ELF64 image"); sys.exit(1)
phoff = struct.unpack_from('<Q', d, 32)[0]
phentsize, phnum = struct.unpack_from('<HH', d, 54)
loads = []
for i in range(phnum):
    o = phoff + i * phentsize
    p_type = struct.unpack_from('<I', d, o)[0]
    if p_type == 1:
        p_offset, p_vaddr, _pa, p_filesz, p_memsz = struct.unpack_from('<QQQQQ', d, o + 8)
        loads.append((p_offset, p_vaddr, p_filesz, p_memsz))
if len(loads) != 1:
    print("FAIL: expected exactly one PT_LOAD, found %d — this gate's VA<->file mapping assumes cycc's flat image" % len(loads)); sys.exit(1)
p_offset, p_vaddr, p_filesz, p_memsz = loads[0]
if p_offset != 0 or p_vaddr != 0x100000:
    print("FAIL: PT_LOAD is offset 0x%x vaddr 0x%x — expected the flat 0 -> 0x100000 mapping (VA = 0x100000 + file offset)" % (p_offset, p_vaddr)); sys.exit(1)
end = p_vaddr + p_memsz
# section spans, for the report
shoff = struct.unpack_from('<Q', d, 40)[0]
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 58)
secs = {}
if shnum:
    so = shoff + shstrndx * shentsize
    stroff, strsz = struct.unpack_from('<QQ', d, so + 24)
    strtab = d[stroff:stroff + strsz]
    for i in range(shnum):
        o = shoff + i * shentsize
        name_off = struct.unpack_from('<I', d, o)[0]
        addr, off, size = struct.unpack_from('<QQQ', d, o + 16)
        name = strtab[name_off:strtab.find(b'\0', name_off)].decode()
        secs[name] = (addr, size)
print("  LOAD 0x%x..0x%x (filesz 0x%x memsz 0x%x)" % (p_vaddr, end, p_filesz, p_memsz))
for n in ('.text', '.bss', '.rodata'):
    if n in secs:
        a, s = secs[n]; print("  %-8s 0x%x..0x%x" % (n, a, a + s))
print("  fixed stacks: AP1-3 [0x%x, 0x%x)  BSP boot top 0x%x  hard ceiling 0x%x" % (AP_LO, AP_HI, BSP_BOOT_TOP, HARD_CEIL))
if end > HARD_CEIL:
    fail.append("LOAD end 0x%x exceeds the hard ceiling 0x%x: the BSP boot stack at 0x%x would have under 64 KB before it walks into the image. Relocate the fixed stacks; do not raise the ceiling." % (end, HARD_CEIL, BSP_BOOT_TOP))
else:
    print("  PASS: LOAD end 0x%x <= 0x%x (BSP boot stack headroom 0x%x = %d B)" % (end, HARD_CEIL, BSP_BOOT_TOP - end, BSP_BOOT_TOP - end))
if end <= AP_LO:
    print("  PASS: LOAD end 0x%x is below the AP stack floor 0x%x — the image and the AP stacks are disjoint (the real invariant)" % (end, AP_LO))
else:
    # decode the chunks the build embedded, straight from the face module
    src = open(face, 'r', encoding='utf-8', errors='surrogateescape').read()
    chunks = {}
    for m in re.finditer(r'if \(i == (\d+)\) \{ return "((?:\\x[0-9a-fA-F]{2})*)"; \}', src):
        chunks[int(m.group(1))] = bytes(int(h, 16) for h in re.findall(r'\\x([0-9a-fA-F]{2})', m.group(2)))
    n = max(chunks) + 1 if chunks else 0
    if n == 0 or any(i not in chunks for i in range(n)):
        print("FAIL: could not decode the chunk literals from %s (%d found)" % (face, len(chunks))); sys.exit(1)
    off0 = d.find(chunks[0])
    if off0 < 0 or d.find(chunks[0], off0 + 1) >= 0:
        print("FAIL: chunk 0 not found exactly once in the image (off0=%d)" % off0); sys.exit(1)
    # cycc emits each literal NUL-terminated, back to back, in source order: stride = 4096 + 1
    stride = len(chunks[0]) + 1
    pos = off0
    for i in range(n):
        c = chunks[i]
        if d[pos:pos + len(c)] != c:
            fail.append("chunk %d does not match the face module at file offset 0x%x (VA 0x%x) — the literal layout is not what this gate assumes, or the literal is corrupt" % (i, pos, 0x100000 + pos)); break
        if i + 1 < n and d[pos + len(c)] != 0:
            fail.append("no NUL after chunk %d at VA 0x%x — literal stride assumption broken" % (i, 0x100000 + pos + len(c))); break
        pos += len(c) + 1
    span_lo = 0x100000 + off0
    span_hi = 0x100000 + off0 + sum(len(chunks[i]) + 1 for i in range(n)) - 1   # last chunk's NUL excluded
    ov_lo, ov_hi = AP_LO, min(AP_HI, end)
    print("  rekha chunks: %d x %d B at VA 0x%x..0x%x (stride %d)" % (n, len(chunks[0]), span_lo, span_hi, stride))
    print("  AP window overlap with the image: [0x%x, 0x%x) = %d B" % (ov_lo, ov_hi, ov_hi - ov_lo))
    if not fail:
        if span_lo <= ov_lo and ov_hi <= span_hi:
            margin = span_hi - AP_HI
            print("  PASS (TOLERATED OVERLAP): every byte under the AP stacks is a dead rekha chunk byte; first live byte above CPU3's stack top is at 0x%x, margin 0x%x = %d B" % (span_hi + 1, margin, margin))
            print("        ⚠ this is not the invariant — it is the 1.57.2 accommodation; see docs/development/issues/2026-09-13-ap-stacks-inside-kernel-rodata.md")
        else:
            fail.append("the AP stack window [0x%x, 0x%x) is not covered by the rekha chunk span 0x%x..0x%x: LIVE kernel bytes (.text/.bss/a kernel literal) sit under an AP kernel stack and will be overwritten on any -smp >= 2 boot" % (ov_lo, ov_hi, span_lo, span_hi))
for f in fail:
    print("FAIL: " + f)
sys.exit(1 if fail else 0)
EOF
exit $rc
