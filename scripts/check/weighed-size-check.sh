#!/bin/sh
# weighed-size-check.sh — the WEIGHED-SIZE TRIPWIRE: (file size - embedded face) < GRANT, with GRANT
# derived from the image-layout wall so that gate 34 (image-layout-check.sh) always binds first.
#
# Usage: sh scripts/check/weighed-size-check.sh <elf-image>     (REKHA_DIR honoured, default ../rekha)
# Callers: scripts/check.sh "binary size" (build/agnos, behind the ARITY_BUILD_RC fossil guard) and
# scripts/test.sh "x86 size reasonable" (build/agnos_test). ONE copy of the grant, one derivation —
# until 1.57.9 each caller carried its own number and its own subtraction "in lockstep", and the
# test.sh copy had already drifted (its unreadable-face path set FACE=0 and passed only because the
# raw size happened to exceed the grant).
# Output: line 1 is the one-line summary the caller puts in its row; any further lines are FAIL
# reasons. Exit 0 = PASS, 1 = FAIL. Fails closed on every unreadable input.
#
# ⭐⭐ 1.57.9 (SIZEGATE) — OPERATOR RULING: THIS GATE "IS NOT A HARD LIMIT — IT CAN BE EXPANDED". The
# hard limit is the layout: image-layout-check.sh (check.sh gate 34, build.sh after every build, CI)
# — LOAD end <= CEIL = BSP_BOOT_TOP - 64 KB = 0x390000. Before 1.57.9 the 2 MiB grant here (2,097,152)
# was an arbitrary absolute ceiling that fired FIRST: at 1.57.8 the plain image weighed 2,092,452 B,
# 4,700 B under the grant, while its LOAD end 0x373108 still had 118,520 B to the wall. A taste
# number binding ~114 KB before the physical one is the inversion the ruling removes.
#
# PRIOR ART (handoff-1.57.9/steps/SIZEGATE-prior-art.md). Every established system separates the two:
#   · Linux arch/x86/kernel/vmlinux.lds.S ASSERT((_end - LOAD_OFFSET <= KERNEL_IMAGE_SIZE)) — a hard
#     limit DERIVED FROM THE LAYOUT; nothing bounds vmlinux size for its own sake. scripts/bloat-o-meter
#     reports growth (Total: Before/After) and always exits 0.
#   · GNU ld MEMORY regions (Zephyr): "region `FLASH' overflowed" is the hard limit; rom_report is
#     a report. U-Boot's size_check fails hard, but its limits are the flash/SRAM slot — a layout.
#   · Chromium's android-binary-size trybot is the only one that fails on growth, and it gates a
#     per-change DELTA against a baseline, with a visible override footer.
# So: the layout ASSERT (gate 34) is the one hard limit; the grant is placed deliberately ABOVE the
# plain image's layout-equivalent size.
# ⛔ 1.57.9 ENDFIX (end review SG-1) — WHAT THIS ROW DOES AND DOES NOT DO. FOR GROWTH IT IS REPORT-ONLY
# (the bloat-o-meter model): with the ORDERING check holding (GRANT > WALL, WALL computed from the SAME
# image), SZK >= GRANT implies SZK > WALL implies LOAD end > CEIL — gate 34 is already red. So the "bloat"
# line below can never fire first, on build/agnos or on agnos_test; growth is caught by gate 34 alone. What
# the row ENFORCES is (a) the face subtraction is readable, (b) the 50,000-byte floor, (c) the ORDERING
# check — a forced re-derivation whenever CEIL, the zero-fill, the trailer or the face moves. What it
# REPORTS is the weighed size, the headroom and the distance to the wall (read that line for growth).
# DEPARTURES, and why: (1) the SIZEGATE prior-art note s.1 (vidya kernel_topics "benchmark every
# toolchain upgrade") wanted this row kept as an EARLY toolchain-codegen-bloat tripwire; that is GIVEN UP:
# by the operator ruling any absolute number that fires before the wall is the old inversion, and the one
# prior-art mechanism that catches growth early without it — Chromium's per-change DELTA against a stored
# baseline, with an override footer — needs state check.sh does not keep; out of 1.57.x scope. (2) it
# keeps weighing file size minus face rather than memsz — gate 34 already measures memsz. (Until ENDFIX
# this header claimed the row "still hard-fails rather than only reporting" on growth — it cannot.)
#
# THE ARITHMETIC (measured on the 1.57.8 plain build, md5 b4f99882…; each step holds only while its
# condition holds, which is why the ORDERING check below recomputes the wall LIVE from the image):
#     LOAD end = 0x100000 + p_memsz                 flat single PT_LOAD at 0x100000 (gate 34 asserts it)
#     p_memsz  = p_filesz + ZF                      ZF = cycc's zero-fill, 65,536 (2,568,456 - 2,502,920)
#     SZ       = p_filesz + TR                      TR = trailing shdrs + shstrtab, 352 (2,503,272 - 2,502,920)
#     LOAD end <= 0x390000 <=> p_memsz <= 0x290000 <=> p_filesz <= 0x280000 (2,621,440)
#                          <=> SZ <= 2,621,792 <=> SZK = SZ - FACE <= 2,621,792 - 410,820 = 2,210,972 (WALL)
#     GRANT    = 0x220000 = 2,228,224 (2.125 MiB) = WALL + 17,252
# Between WALL and GRANT the plain image fails gate 34 while this row still passes — gate 34 binds
# first, by construction; at and above GRANT both are red. So below WALL this row never fails on size:
# it REPORTS the headroom (~115 KB to the wall at 1.57.9) and gate 34 is what goes red on growth.
# ⛔ A RAISE IS LEGITIMATE ONLY WHEN THE WALL MOVES (BSP_BOOT_TOP moves, as at 1.57.7, or the face or
# the zero-fill changes). Recompute with the arithmetic above; never nudge GRANT past a red row.
# ⛔ ORDERING CHECK: the wall depends on FACE, ZF and TR. A SMALLER face (a subset rekha: FACE <=
# 393,568 B at today's GRANT; at equality this row trips at a weight gate 34 still passes) or a smaller
# zero-fill RAISES the wall to or above GRANT, and this row would once again fire before the physical
# limit. So the wall is recomputed live from the image being weighed (CEIL parsed from
# image-layout-check.sh, the one source; p_filesz/p_memsz from the ELF; FACE from rekha) and the row
# FAILS if GRANT <= WALL, telling the next editor to re-derive rather than letting the inversion come
# back silently (the analogue of image-layout-check.sh's "constants inconsistent" assert).
# Scope: the PLAIN build only. Flag builds are refused past 0x390000 by build.sh's per-build layout run
# and carry selftest code by design.
#
# Mutation record (1.57.9 SIZEGATE; each RED, then restored GREEN on the same image):
#   M1 GRANT = 2,092,000 (< SZK) -> check.sh "binary size" FAIL and test.sh "x86 size reasonable" FAIL.
#      (check.sh also scores its "test suite" row red, since that row runs test.sh.) M1 < WALL too, so the
#      ORDERING line fires with it.
#   M2 GRANT = 2,200,000 (SZK < GRANT < WALL: headroom positive) -> the ORDERING FAIL alone, helper and test.sh.
#   M3 REKHA_DIR unreadable -> "could not read rekha_face_default_len()" FAIL (test.sh's old copy PASSED here
#      whenever the raw size happened to be under its grant's reach — it set FACE=0 and weighed on).
#   M4 a stand-in face module of 390,000 B (< 393,568) -> WALL 2,231,792 >= GRANT -> ORDERING FAIL; the same
#      stand-in at 393,600 B -> PASS (WALL 2,228,192), at exactly 393,568 B -> FAIL (WALL == GRANT). The
#      face-sensitivity boundary is where the header says.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMG="${1:-}"
REKHA_DIR="${REKHA_DIR:-$ROOT/../rekha}"
LAYOUT="$ROOT/scripts/check/image-layout-check.sh"
GRANT=2228224   # 0x220000 — derived above; the ordering check re-proves GRANT > WALL on every run

[ -n "$IMG" ] && [ -f "$IMG" ] || { echo "no image to weigh ('$IMG')"; echo "FAIL: image '$IMG' not found"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 unavailable"; echo "FAIL: python3 not available — the ELF cannot be parsed, the wall cannot be derived"; exit 1; }
FACE=$(sed -n 's/^fn rekha_face_default_len() { return \([0-9][0-9]*\); }.*/\1/p' "$REKHA_DIR/fonts/face_data.cyr" 2>/dev/null | head -1)

python3 - "$IMG" "$LAYOUT" "${FACE:-}" "$GRANT" "$REKHA_DIR" <<'EOF'
import re, struct, sys
img, layout, face, grant, rekha = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
d = open(img, 'rb').read()
SZ = len(d)
fails = []
# FACE: read live from the SAME face module the build cat'd in. Unreadable -> FAIL outright (never weigh
# the raw size and hope it happens to exceed the grant).
FACE = int(face) if face.isdigit() else None
if FACE is None:
    fails.append("FAIL: could not read rekha_face_default_len() from %s/fonts/face_data.cyr — refusing to weigh without the face subtraction" % rekha)
# CEIL: from image-layout-check.sh, the one source of the hard limit.
try:
    src = open(layout, encoding='utf-8').read()
except OSError:
    src = ''
top = re.findall(r'(?m)^BSP_BOOT_TOP = (0x[0-9A-Fa-f]+)\b', src)
bud = re.findall(r'(?m)^CEIL = BSP_BOOT_TOP - (0x[0-9A-Fa-f]+)\b', src)
CEIL = None
if len(top) != 1 or len(bud) != 1:
    fails.append("FAIL: %s: expected one `BSP_BOOT_TOP = 0x...` and one `CEIL = BSP_BOOT_TOP - 0x...`, found %d/%d — teach this gate the new shape rather than dropping the ordering check" % (layout, len(top), len(bud)))
else:
    CEIL = int(top[0], 16) - int(bud[0], 16)
# The image's single flat PT_LOAD (gate 34 asserts the same shape).
loads = []
if d[:4] == b'\x7fELF' and len(d) > 64 and d[4] == 2:
    phoff = struct.unpack_from('<Q', d, 32)[0]
    phentsize, phnum = struct.unpack_from('<HH', d, 54)
    for i in range(phnum):
        o = phoff + i * phentsize
        if struct.unpack_from('<I', d, o)[0] == 1:
            _off, va, _pa, fs, ms = struct.unpack_from('<QQQQQ', d, o + 8)
            loads.append((va, fs, ms))
if len(loads) != 1:
    fails.append("FAIL: expected an ELF64 with exactly one PT_LOAD, found %d — the wall cannot be derived" % len(loads))
SZK = SZ - FACE if FACE is not None else None
WALL = None
if CEIL is not None and len(loads) == 1 and FACE is not None:
    va, fs, ms = loads[0]
    WALL = (CEIL - va - (ms - fs)) + (SZ - fs) - FACE   # the SZK at which LOAD end == CEIL
    if grant <= WALL:
        fails.append("FAIL: ORDERING — GRANT %d <= WALL %d (the weighed size at which LOAD end hits 0x%x; zero-fill %d, trailer %d, face %d): this row would fire before the physical limit, gate 34 would no longer bind first. Re-derive GRANT from the header arithmetic (it must sit above WALL); do not just nudge it" % (grant, WALL, CEIL, ms - fs, SZ - fs, FACE))
if SZK is not None:
    if SZK <= 50000:
        fails.append("FAIL: %d weighed bytes is under the 50,000 floor — too small to be this kernel" % SZK)
    if SZK >= grant:
        # Reached only with gate 34 already red (SZK >= GRANT > WALL): a second name for the layout failure,
        # never an early warning (ENDFIX SG-1, header).
        fails.append("FAIL: %d weighed bytes >= GRANT %d — past the layout wall too (gate 34 is red). Find the growth first; a raise is legitimate only when the WALL moves (see header)" % (SZK, grant))
order = "gate 34 binds first" if (WALL is not None and grant > WALL) else "ORDERING NOT PROVEN"
summary = "%d B; %s weighed = size minus the %s-byte face; grant %d, headroom %s; layout wall at %s weighed (%s, %s B to it)" % (
    SZ, SZK if SZK is not None else '?', FACE if FACE is not None else '?', grant,
    (grant - SZK) if SZK is not None else '?', WALL if WALL is not None else '?', order,
    (WALL - SZK) if (WALL is not None and SZK is not None) else '?')
print(summary)
for f in fails:
    print(f)
sys.exit(1 if fails else 0)
EOF
