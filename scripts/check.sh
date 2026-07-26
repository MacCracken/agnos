#!/bin/sh
# AGNOS project check — run all validations
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0

check() {
    if [ "$2" = "0" ]; then
        echo "  PASS: $1"
        pass=$((pass + 1))
    else
        echo "  FAIL: $1"
        fail=$((fail + 1))
    fi
}

echo "=== AGNOS Check ==="
echo ""

# Build
echo "--- Build ---"
sh "$ROOT/scripts/build.sh" > /dev/null 2>&1
check "x86_64 build" $?

# Source hygiene
# kprint/kprintln take (string, length) and the compiler does NOT verify the two agree — short truncates the
# line, long runs past the literal. The build stays green either way, so this only ever surfaced by eye, and
# an off-by-one in a burn's PASS line is indistinguishable from a failed burn when you are reading a console
# photo. Wired in 2026-07-19 after a single A4 instrumentation bite introduced four of them (every one of the
# other 913 literals in gpu.cyr + main.cyr was correct). Failures print in full — a bare FAIL line would not
# be actionable.
echo ""
echo "--- Source Hygiene ---"
sh "$ROOT/scripts/kprint-len-check.sh" > /tmp/kprint-len-check.log 2>&1 && rc=0 || rc=$?
check "kprint literal lengths" $rc
[ "$rc" = "0" ] || cat /tmp/kprint-len-check.log

# GPU arena slot aliasing. Every *_SUBOFF is a byte offset into the ONE compute arena; two constants
# holding the same value means two subsystems own the same memory, and nothing but build-flag
# disjointness keeps them apart. Wired in 2026-07-22 after the 1.56.x audit found SIX live aliases,
# the worst of which put #92's blend shader and the done-marker all five shader kernels poll on top of
# GPU_VM_DUMMY_SUBOFF — the VM protection-fault SINK page, which gpu_vm_setup() zeroes at boot and the
# hardware writes to on every fault. A fault-sink write carrying the sentinel bytes false-signals a
# completed dispatch, which is a FALSE PASS, not a crash. Value-only check by design: it needs no
# knowledge of each slot's extent, so it cannot rot.
DUPS=$(grep -oE "_SUBOFF *= *0x[0-9A-Fa-f]+" "$ROOT/kernel/core/gpu_regs.cyr" \
       | awk -F'0x' '{print toupper($2)}' | sort | uniq -d)
test -z "$DUPS"
check "gpu arena slots unaliased" $?
# The Cyrius var X[N] units trap: function-local is N BYTES, module-scope is N x u64. Cost the
# rung-10 burn its exit code (a 40-byte stack smash that left every printed number correct).
sh "$ROOT/scripts/check-array-sizing.sh" >/dev/null 2>&1
check "no function-local array overruns" $?
[ -z "$DUPS" ] || { echo "  duplicated arena offsets:"; for d in $DUPS; do
    echo "    0x$d:"; grep -nE "_SUBOFF *= *0[xX]0*$d\b" "$ROOT/kernel/core/gpu_regs.cyr" | sed 's/^/      /'; done; }

# Call arity. cycc WARNS on an argument-count mismatch and builds anyway, so a wrong call ships green.
# Wired in 2026-07-22 after the 1.56.x audit found gpu_blend_cov_run declared with 12 parameters and
# called with 11 at BOTH coverage sites — including gpu_cov_surface. (⚠ That worker was described here as
# "behind syscall #93"; that shape was WITHDRAWN at 1.56.4 — coverage is now op code 0x02 inside #92, and
# #93 is unallocated, ratified for gpu_modeset_op by MD-4. The arity lesson below is unaffected.)
# Every argument after the missing one shifted by one position, which made done_phys undefined and turned
# the function's first statement into a wild kernel store32. It had been warning in every build since the
# glyph refactor. This promotes that warning to a build failure.
ARITY=$(sh "$ROOT/scripts/build.sh" 2>&1 | grep -E "expects [0-9]+ arguments, got [0-9]+" || true)
test -z "$ARITY"
check "call arity (no cycc argument-count warnings)" $?
[ -z "$ARITY" ] || echo "$ARITY" | sed 's/^/    /'


# Tests
echo ""
echo "--- Tests ---"
sh "$ROOT/scripts/test.sh" > /dev/null 2>&1
check "test suite" $?

# Required docs
echo ""
echo "--- Documentation ---"
for doc in README.md CHANGELOG.md VERSION CONTRIBUTING.md SECURITY.md LICENSE; do
    test -f "$ROOT/$doc"
    check "doc: $doc" $?
done

# Version consistency
echo ""
echo "--- Version Consistency ---"
VERSION=$(cat "$ROOT/VERSION" | tr -d '[:space:]')
echo "  VERSION file: $VERSION"
# Version drift in the kernel. Pre-2026-07-26 this gate grepped kernel/agnos.cyr
# alone — a COMMENT on line 1 — and never read kernel/version.cyr, where every
# string the running kernel actually emits lives. So the two non-banner sites in
# that generated file sat at 1.56.17 on a 1.56.19 kernel across two releases with
# check.sh green, and both are user-visible, not cosmetic: _AGNOS_VERSION fills
# uname#34's release field (syscall.cyr), so mihi -> iam printed "Kernel: 1.56.17"
# to every ring-3 reader, and agnos_version_str() feeds the TCP_LISTEN_SMOKE HTTP
# banner, which served "AGNOS 1.56.17 tcp_listen smoke" over the wire. The banner
# literals are covered too — the scan asserts EVERY version token on a non-comment
# line of version.cyr equals VERSION, so a new site added to that file is gated
# the day it lands rather than the day someone notices. Comment lines are skipped
# because version.cyr's header legitimately cites historical versions (v1.30.2).
# Kept as ONE check with a detail dump, matching the arena/arity gates above.
VDRIFT=""
grep -q "AGNOS kernel v$VERSION" "$ROOT/kernel/agnos.cyr" 2>/dev/null \
    || VDRIFT="$VDRIFT    kernel/agnos.cyr: banner comment is not v$VERSION\n"
VFN=$(sed -n 's/^ *return "\([0-9][^"]*\)";$/\1/p' "$ROOT/kernel/version.cyr" 2>/dev/null)
[ "$VFN" = "$VERSION" ] \
    || VDRIFT="$VDRIFT    kernel/version.cyr: agnos_version_str() returns '$VFN' (feeds the tcp_listen HTTP banner)\n"
VGV=$(sed -n 's/^var _AGNOS_VERSION = "\([^"]*\)";$/\1/p' "$ROOT/kernel/version.cyr" 2>/dev/null)
[ "$VGV" = "$VERSION" ] \
    || VDRIFT="$VDRIFT    kernel/version.cyr: _AGNOS_VERSION is '$VGV' (feeds uname#34 release -> iam's Kernel: line)\n"
for v in $(grep -vE '^[[:space:]]*#' "$ROOT/kernel/version.cyr" 2>/dev/null \
           | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?' || true); do
    [ "$v" = "$VERSION" ] || VDRIFT="$VDRIFT    kernel/version.cyr: stale version token $v\n"
done
test -z "$VDRIFT"
check "version in kernel" $?
[ -z "$VDRIFT" ] || { echo "  VERSION is $VERSION — regenerate with: sh scripts/version-bump.sh --regen"; printf "$VDRIFT"; }
grep -q "$VERSION" "$ROOT/CHANGELOG.md" 2>/dev/null
check "version in changelog" $?

# Binary size sanity. The 350KB bound dated to the v1.22.0 / ~250KB era and
# went stale across the storage (1.31.x), networking (1.32.x), ext2/4-write
# (1.33.x), FAT-family (1.34.x), and DNS (1.35.x) arcs — the kernel is ~806KB.
# Ceiling moved to 1.2M, then 1.4M: the 1.44.x scheduler + 1.45.x net arcs closed
# on 1.2M and the 1.46.x lseek/flock syscalls crossed it (~1,203,984 B), so the
# bound moved 1.2M → 1.4M. The 1.54.x GPU arc (F0 landed ~1.40M; C0+ add the
# CP/MEC/RLC/PSP register tables) moved it 1.4M → 1.5M — still catching a
# runaway-bloat regression. The 1.55.x DISPLAY arc's display-audio bite then closed
# on 1.5M (1,560,016 B — 16 B over, the same way 1.45.10 closed on 1.2M), so the
# bound moved 1.5M → 1.6M; that arc's growth is the OTG-timing and HDMI/AFMT/ACR
# register tables, not bloat. Matches scripts/test.sh (bumped in lockstep).
# The 1.55.x SHUTDOWN arc then closed on 1.6M (1,600,712 B — 712 B over, the
# same way 1.45.10 closed on 1.2M and the display-audio bite closed on 1.5M),
# so the bound moved 1.6M -> 1.7M. That arc's growth is the ACPI FADT/_S5
# decode plus the per-subsystem quiesce paths, not bloat.
# The 1.56.x SHADER arc then closed on 1.7M (1,700,472 B — 472 B over, the same
# way 1.45.10 closed on 1.2M and the display-audio bite closed on 1.5M), so the
# bound moved 1.7M -> 1.8M. That arc's growth is the seven .s-backed shader ISA
# tables (plus the four 1.54.x matmul kernels reconstructed at 1.56.7 = 11 total), the
# #92 descriptor validation layer, and the plan-S3 coherence harness — note DCE is
# OFF by default here, so every *_test fn ships whether or not its #ifdef is set.
# Matches scripts/test.sh (bumped in lockstep).
echo ""
echo "--- Binary ---"
SZ=$(wc -c < "$ROOT/build/agnos")
test "$SZ" -gt 50000 && test "$SZ" -lt 1800000
check "binary size ($SZ bytes)" $?

echo ""
echo "=========================="
echo "$pass passed, $fail failed"
test $fail -eq 0
