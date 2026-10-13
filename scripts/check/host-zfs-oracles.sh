#!/bin/sh
# host-zfs-oracles — regenerate the ZFS codec vectors, REBUILD tests/zfscodec, run it, and score it.
#
# What it proves: kernel/core/zfs_codec.cyr — SHA-256 (one-shot and streaming), SHA-512/256,
# fletcher2/4, the ZAP name hash, and the lz4 / lzjb / zle / gzip decoders — agrees with vectors
# that scripts/check/zfs-codec-vectors.py derives from INDEPENDENT producers (hashlib, zlib, the lz4
# CLI, Python ports of the OpenZFS compressors), and that every decoder stays inside its buffers on
# hostile input (each runs against PROT_NONE guard pages at both ends, plus a mutation fuzz).
# ⭐ 1.57.12 B3a — and the WRITER's encoders: zfs_codec.cyr's ZLE compressor (zfs_zle_compress) and BP
# checksum dispatch (zfs_cksum_words), kernel/core/zfs_wenc.cyr's block-pointer words, holes, ZLE decision
# (zio_write_compress's floor + rounding) and space-map entries — against a Python encoder written from
# OpenZFS 2.4.2's spa.h / space_map.c / zio.c AND against bytes OpenZFS itself wrote (REAL_BPS: 14 block
# pointers, 5 physical blocks incl. a ZLE data block whose psize and bytes zfs_wcomp must reproduce;
# REAL_SMS: a log and a metaslab space map of each of two pools, re-encoded entry by entry).
# The oracle INCLUDES the kernel files — there is one implementation, not a mirror of it.
#
# ⭐ MUTATION-PROVEN (1.57.12 B3a, 2026-10-10): 43 one-line mutants of the new code (ZLE compress, the checksum
# dispatch, BP / hole / space-map words, the ZLE decision, the fills), each applied to a scratch copy of the two
# kernel files and the oracle rebuilt — 42 red (exit 90 with named FAIL lines, or a guard-page SIGSEGV: a ZLE
# literal-room check off by one, a space-map cap check off by eight — two of them only after a vector was added
# for them: a put at len == cap, an embedded child whose payload starts with 16 zero bytes), and 1 EQUIVALENT
# (zfs_wcomp keeping ZLE when the rounded size EQUALS lsize returns lsize either way — its caller reads
# psize == lsize as compression off). The list and its results: design § h B3.
# ⭐ RE-RUN AFTER THE B3a REVIEW (2026-10-10): the review found three zfs_wcomp mutants alive — d_len one byte
# tighter / looser, and the round-up off by one at an EXACT multiple of the allocation unit — because no vector
# compressed to exactly s_len - s_len/8 (the floor loop stepped 3 literals) or to exactly k x ma. Vectors now hit both
# edges to the byte (16K and 4K at ashift 9/12/13) and 2 x / 3 x ma at ashift 9 and 12; DMU_OT_IS_VALID type vectors
# came with zfs_ot_valid, and a DVA-word-1-only child for zfs_ind_ready. 55 mutants (the 43, the review's 6, 6 on
# the type check): 54 red, 1 equivalent (the one above).
# ⭐ 1.57.12 B4 — the dataset COW's pure accounting rules in zfs_wenc.cyr: zfs_ot_meta (dmu_ot[]'s metadata column),
# zfs_bp_ucsize / zfs_bp_birth (BP_GET_UCSIZE / BP_GET_BIRTH, embedded and rewritten BPs included), zfs_pdelta
# (parent_delta), zfs_md_copies (dmu_write_policy's metadata copies under every redundant_metadata) and zfs_sa_ids
# (zpl_get_file_info) — against an independent Python model and against 4 block pointers and 2 SA bonuses OpenZFS
# wrote into the `wr` fixture. 276 cases. MUTATION-PROVEN (2026-10-10): 16 one-line mutants of the six functions, 16
# red (one by a guard-page SIGSEGV: the SA length check loosened by 8 bytes read past the bonus). Writing the vectors
# found a real defect first: zfs_bp_birth returned 0 for an embedded BP whose payload word 7 has bit 63 set.
# ⭐ 1.57.12 B5 — agnos-gen-1, the op list's file content (zfs_wenc.cyr zfs_gen_seed / zfs_gen_fill, compiled here by
# defining ZFS_WRITE_OPS): BYTE-IDENTICAL with scripts/smoke/lib/zfs-expect.py's `gen` — the function that predicts the
# expected manifest the guest diffs, imported by the generator, never re-typed — on its reference vectors, word / byte
# edges against the guard page, and (SHA-256) every seed / offset / length the kernel's op list and the ring-3
# exerciser write. 31 cases.
# ⭐ 1.57.12 B8 — the FAT ZAP (zfs_wenc.cyr's zfs_zl_* / zfs_zf_*: leaf chunks, split, pointer table, upgrade), run over a
# flat image by op scripts: the histories of agnoswr/fat and agnostank/dir3000 replayed byte-for-byte against the blocks
# OpenZFS itself wrote (REAL captures, SHA-256-pinned), and scenarios — a leaf emptied, a shared 12-bit prefix driving
# the table external, doubling and a mid-grow across ops, TOUPPER normalisation, a makefs 128 KiB-block ZAP, u16 arrays,
# an upgrade with a hash collision, hostile headers — against an independent Python model (scripts/check/zfs-fatzap.py,
# itself held to the same REAL blocks). 13 cases. MUTATION-PROVEN (2026-10-12): a split that drops an entry, a new
# leaf's prefix without its bit, zap_num_entries not counted, a pointer-table entry left on the old leaf, an upgrade
# that zeroes the salt — 5 red (5, 5, 8, 5, 9 FAIL lines).
# ⭐ 1.57.12 B11 — UTF-8 names on a utf8only dataset (zfs_wenc.cyr zfs_u8_valid): OpenZFS's u8_validate ported from its
# tables (u8_textprep.c — lead-byte classes, the second byte's per-lead range, continuations) AND every vector's verdict
# cross-checked against Python's strict UTF-8 codec; 1,358 cases (every lead byte against eight boundary second bytes,
# overlongs, surrogates, past U+10FFFF, truncations at every length, a 300-string fuzz), each name ending at the guard
# page. MUTATION-PROVEN (2026-10-12): see design § h B11's gate record.
#
# Exit: 0 iff the oracle exited 95 AND scored at least ZFS_ORACLE_FLOOR passing cases; 1 on a red
# oracle (or a vacuous one); 2 on a TOOLING failure (no cyrius / python3 / lz4, or the generator
# could not run) — "the tools are missing" and "the codec is wrong" are different things to be told.
#
# ⚠ THIS REBUILDS BEFORE IT RUNS, and deletes the old binary first. A binary left over from an
# earlier source is evidence about that source, not this one (host-gpu-oracles.sh's header has the
# story of a committed oracle that passed while its source did not compile). Same for the vectors:
# they are regenerated on every run and never committed (tests/zfscodec/gen/ is git-ignored).
#
# ⛔ VACUITY: the oracle's own exit is computed from a failure counter, so an oracle whose case list
# went missing would exit 95 having checked nothing. Two floors stop that: the oracle refuses to
# pass unless it ran exactly the generated count (and >= its own floor), and THIS script counts the
# `PASS ` lines it printed and requires ZFS_ORACLE_FLOOR of them. The number is the count measured
# on 2026-10-12 (2,332: 2,331 generated + 1 local, after B11's 1,358 UTF-8 cases; 974 after the B8 review's two fat-ZAP failure cases — a failed switch's
# free, a table that may not grow; 972 after B8's fat-ZAP vectors; 958 after B5's agnos-gen-1 vectors; 927 after B4's accounting-rule vectors; 651 after the B3a review's edge
# vectors — the ZLE floor's exact edge and exact allocation-unit multiples, DMU_OT_IS_VALID types; 605 at B3a; 249
# before the 1.57.12 writer vectors). Adding vectors raises the real count above it,
# which is fine; if a deliberate removal drops below it, RE-MEASURE and lower it in the same edit.
# Deleting the floor to make the gate quiet puts the hole back.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$ROOT/tests/zfscodec"
LOGD="${CHECK_LOGS:-$ROOT/build/check-logs}"
LOG="$LOGD/host-zfs-zfscodec.log"
ZFS_ORACLE_FLOOR=2332
mkdir -p "$LOGD"

command -v cyrius  >/dev/null 2>&1 || { echo "host-zfs-oracles: TOOLING -- cyrius not on PATH"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "host-zfs-oracles: TOOLING -- python3 not on PATH"; exit 2; }
command -v lz4     >/dev/null 2>&1 || { echo "host-zfs-oracles: TOOLING -- the lz4 CLI is not installed (the LZ4 vectors come from it)"; exit 2; }

gen="$(python3 -I "$ROOT/scripts/check/zfs-codec-vectors.py" 2>&1)" || {
    echo "host-zfs-oracles: TOOLING -- zfs-codec-vectors.py failed; no vectors, nothing tested"
    echo "$gen" | tail -20
    exit 2
}
echo "host-zfs-oracles: $gen"

# The oracle includes ../../kernel/..., which the wrapper refuses by default.
CYRIUS_ALLOW_PARENT_INCLUDES=1
export CYRIUS_ALLOW_PARENT_INCLUDES
rm -f "$T/build/zfscodec"
out="$(cd "$T" && cyrius build zfscodec.cyr build/zfscodec 2>&1)" || {
    echo "host-zfs-oracles: FAIL -- tests/zfscodec/zfscodec.cyr does not BUILD"
    echo "$out" | tail -20
    exit 1
}
[ -x "$T/build/zfscodec" ] || { echo "host-zfs-oracles: FAIL -- the build reported OK but left no binary"; exit 1; }

"$T/build/zfscodec" > "$LOG" 2>&1
got=$?
pass=$(LC_ALL=C grep -ac '^PASS ' "$LOG" 2>/dev/null || true)
pass=${pass:-0}
case "$pass" in *[!0-9]*) pass=0 ;; esac
fail=$(LC_ALL=C grep -ac '^FAIL ' "$LOG" 2>/dev/null || true)
fail=${fail:-0}
case "$fail" in *[!0-9]*) fail=0 ;; esac

if [ "$got" -ne 95 ]; then
    echo "host-zfs-oracles: FAIL -- zfscodec exited $got, want 95 ($pass case(s) passed, $fail failed before it stopped)"
    [ "$got" -gt 128 ] && echo "    a SIGNAL ($((got - 128))): a decoder or checksum touched a guard page — an out-of-bounds access"
    LC_ALL=C grep -a '^FAIL \|^  ' "$LOG" | head -30
    tail -5 "$LOG"
    exit 1
fi
if [ "$pass" -lt "$ZFS_ORACLE_FLOOR" ]; then
    echo "host-zfs-oracles: FAIL -- zfscodec exited 95 over $pass passing case(s), floor $ZFS_ORACLE_FLOOR"
    echo "    VACUOUS: the oracle reports success by finding no failures, and it scored too few cases"
    echo "    to have looked for many."
    tail -5 "$LOG"
    exit 1
fi
echo "host-zfs-oracles: PASS -- zfscodec exit 95, $pass case(s) scored (floor $ZFS_ORACLE_FLOOR), 0 failed"
exit 0
