#!/bin/sh
# placeholder-check.sh — refuse a kernel image that carries cycc's UNRESOLVED-CALL PLACEHOLDERS (1.57.13).
#
# Usage: sh scripts/check/placeholder-check.sh IMAGE [COMPILE_STDERR_LOG]
#   exit 0  the executable sections were scanned and hold no placeholder (and the log names no undefined function)
#   exit 1  placeholders found — each one's address is printed — or the log carries `warning: undefined function`
#   exit 2  the image could not be scanned (not ELF64, no section table, no executable section, unknown machine,
#           a log path that does not exist, no python3). FAIL-CLOSED: a scan that cannot run never scores green.
# First output line: `PASS: …` or `FAIL: …` (build.sh and test.sh print it beside their verdicts).
#
# ⛔⛔ WHY THIS EXISTS — "THE COMPILER SAID OK" IS NOT "EVERY CALL RESOLVED". cycc 6.6.6 (both backends) refuses a
# build over a REACHABLE undefined function, but counts a name as reachable only when its FIRST reference sits in a
# reachable function: a name first called from a dead fn is dropped from the refusal even when a LATER call site is
# live. cycc_aarch64 does not even warn; x86 cycc warns (`warning: undefined function 'NAME'`) and does not refuse.
# Either way every call to the name is emitted as a placeholder and the build prints OK:
#     x86_64   `0F 0B 0F 0B 90`  (ud2; ud2; nop — replacing the 5-byte `call rel32`)
#     aarch64  `00 00 00 00`     (udf #0, at a 4-aligned word — replacing the `bl`)
# Repro (2026-10-13): `fn d() { u(1); return 0; }  fn l() { u(2); return 0; }  l();` -> OK, two placeholders, on both
# backends. In the aarch64 kernel it hid 40 names behind the 32 the compiler reported: with only those 32 stubbed the
# image said OK over 103 placeholders — kprint's fb_print among them, a trap on the first kernel line. All x86_64 images
# measured that day carried 0. The upstream filing is owed (CHANGELOG [1.57.13] § Fixed).
#
# WHAT IS SCANNED. Only section-table PROGBITS + SHF_EXECINSTR sections (cycc emits one, `.text`, flags AX). There is
# deliberately NO program-header fallback: cycc's PT_LOAD is RWX and spans .rodata, whose zero words and byte runs are
# data, not calls — a fallback scan would read false placeholders, and a scan that silently found nothing would read a
# false PASS (the 1.57.13 review measured exactly that on an e_shnum=0 copy of a holed image). No section table = exit 2.
#   aarch64: every 4-aligned all-zero word, except at most 3 trailing zero words — the alignment pad cycc may leave
#            after the program's final exit `svc` (measured 0 or 1 word, moving with the image layout).
#            No emitted instruction is all-zero: inline-asm blocks are padded to a word with their own bytes first,
#            so even a 2-byte x86 PAUSE assembles to 0x000090f3.
#   x86_64:  every occurrence of the 5-byte sequence, at any alignment.
#   COMPILE_STDERR_LOG (x86_64): its `warning: undefined function` lines are failures too — that line NAMES the
#            function, which the image scan cannot. (cycc_aarch64 prints none; the scan is the whole gate there.)
#
# Wired: scripts/build.sh runs it after EVERY build (x86_64 with the compile's stderr; aarch64 image only) and moves a
# refused image to build/agnos{,-aarch64}.placeholder-refused (exit 1) — so release.yml's aarch64 compile test cannot
# record `compiled` over a hole; scripts/test.sh --aarch64 scores the same scan; check.sh's
# "aarch64 compiles with no unresolved calls" row runs build.sh --aarch64.
# Mutation record (1.57.13): drop `fn ext2_path_lookup` from arch/aarch64/stubs.cyr -> build.sh refuses, FAIL 9;
# a dead fn followed by a live call to an undefined name in a shared file (x86) -> FAIL (placeholders + the named
# warning); the holed aarch64 image with e_shnum = 0 -> exit 2.
IMG="${1:-}"
LOG="${2:-}"
[ -n "$IMG" ] || { echo "FAIL: usage: placeholder-check.sh IMAGE [COMPILE_STDERR_LOG]"; exit 2; }
[ -f "$IMG" ] || { echo "FAIL: no image at $IMG — nothing to scan"; exit 2; }
if [ -n "$LOG" ] && [ ! -f "$LOG" ]; then echo "FAIL: compile log $LOG does not exist — cannot read its warnings"; exit 2; fi
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 not available — the image cannot be scanned for unresolved-call placeholders"; exit 2; }

python3 - "$IMG" "$LOG" <<'EOF'
import struct, sys
img, log = sys.argv[1], sys.argv[2]
b = open(img, 'rb').read()

def refuse(why):
    print('FAIL: unscannable image (%s) — %s' % (img, why))
    sys.exit(2)

if len(b) < 0x40 or b[:4] != b'\x7fELF': refuse('not an ELF file')
if b[4] != 2 or b[5] != 1: refuse('not ELF64 little-endian (EI_CLASS %d, EI_DATA %d)' % (b[4], b[5]))
mach = struct.unpack_from('<H', b, 0x12)[0]
if mach not in (62, 183): refuse('unknown e_machine %d (62 = x86_64, 183 = aarch64)' % mach)
arch = 'x86_64' if mach == 62 else 'aarch64'
shoff = struct.unpack_from('<Q', b, 0x28)[0]
shentsize, shnum = struct.unpack_from('<HH', b, 0x3A)
if shoff == 0 or shnum == 0:
    refuse('no section table (e_shoff 0x%x, e_shnum %d) — there is no .text to scan, and the RWX PT_LOAD is not one' % (shoff, shnum))
if shentsize < 0x40 or shoff + shnum * shentsize > len(b):
    refuse('section table out of the file (e_shoff 0x%x, %d x %d B)' % (shoff, shnum, shentsize))

spans = []
for i in range(shnum):
    _, typ, flags, addr, off, size = struct.unpack_from('<IIQQQQ', b, shoff + i * shentsize)
    if typ != 1 or not (flags & 0x4): continue
    if off + size > len(b): refuse('executable section %d (0x%x + %d B) runs past the file' % (i, off, size))
    spans.append((addr, off, size))
scanned = sum(s for _, _, s in spans)
if not spans or scanned == 0:
    refuse('no PROGBITS + SHF_EXECINSTR section with bytes in it (%d section headers)' % shnum)

hits = []
pad = 0
for addr, off, size in spans:
    t = b[off:off + size]
    if mach == 62:
        k = t.find(b'\x0f\x0b\x0f\x0b\x90')
        while k >= 0:
            hits.append(addr + k)
            k = t.find(b'\x0f\x0b\x0f\x0b\x90', k + 5)
    else:
        n = len(t) // 4
        end = n
        while end > 0 and n - end < 3 and t[4 * (end - 1):4 * end] == b'\0\0\0\0':
            end -= 1                     # at most 3 words of tail alignment pad after the final exit svc
        pad += n - end
        hits += [addr + 4 * k for k in range(end) if t[4 * k:4 * k + 4] == b'\0\0\0\0']

warns = []
if log:
    warns = [l.rstrip('\n') for l in open(log, errors='replace') if 'warning: undefined function' in l]

desc = '%d executable section(s), %d B scanned' % (len(spans), scanned)
if mach == 183: desc += ', %d tail pad word(s) excluded' % pad
if not hits and not warns:
    print('PASS: %s: 0 unresolved-call placeholders (%s)' % (arch, desc))
    sys.exit(0)
print('FAIL: %s: %d unresolved-call placeholder(s)%s (%s)' % (arch, len(hits),
      (' + %d `warning: undefined function` line(s) in the compile log' % len(warns)) if warns else '', desc))
if hits:
    print('  at: ' + ' '.join('0x%x' % h for h in hits[:24]) + (' ... (+%d more)' % (len(hits) - 24) if len(hits) > 24 else ''))
for w in warns:
    print('  ' + w)
print('  Each is a call to a function no file in this build defines; cycc emitted a placeholder and said OK.')
if mach == 183:
    print("  aarch64: a shared file reached a name that lives in agnos.cyr's x86_64 block - stub it in")
    print("  kernel/arch/aarch64/stubs.cyr (the configured-out shape its § 1.57.13 documents) or guard the x86-only caller.")
sys.exit(1)
EOF
