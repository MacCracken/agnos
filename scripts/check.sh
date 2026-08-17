#!/bin/sh
# AGNOS project check — run all validations
#
# ⛔ EVERY GATE MUST END `&& rc=0 || rc=$?` AND PASS $rc TO check(). NEVER a bare command followed by
# `check "..." $?`. `set -e` is on, and a bare failing command aborts the whole script — so the gate
# never reports its FAIL, every gate after it is skipped, and the "N passed, M failed" summary never
# prints. The run just stops mid-line. That is strictly worse than no gate: a red result renders as a
# truncated log that reads like a crash, not a failure.
#
# ⚠ FOUND 2026-07-26, and only because a mutation test forced a gate red on purpose. Eight of the nine
# gates had the bare form and had simply never failed. A failing command inside an `&&`/`||` list is
# exempt from `set -e`, which is why the kprint gate below — the one gate written that way — was the
# only one that could ever report a failure and let the run continue to its summary.
#
# ⚠⚠ AND IT CAME BACK. The texl-body-identity gate, added by rung 14 AFTER that sweep, shipped in the
# bare form — so from rung 14 until 2026-07-27 the gate that is the entire safety argument for
# tex_list.s carrying tex_rgba.s's proven body could not report a failure. It had simply never failed,
# which is the same reason the original eight went unnoticed. ⇒ A one-time sweep does not hold this
# invariant; only a mutation test does. When you add a gate, force it red on purpose and confirm the
# run reaches "N passed, M failed" — a green run proves nothing about the failure path.
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
sh "$ROOT/scripts/build.sh" > /dev/null 2>&1 && rc=0 || rc=$?
check "x86_64 build" $rc

# Source hygiene
# kprint/kprintln take (string, length) and the compiler does NOT verify the two agree — short truncates the
# line, long runs past the literal. The build stays green either way, so this only ever surfaced by eye, and
# an off-by-one in a burn's PASS line is indistinguishable from a failed burn when you are reading a console
# photo. Wired in 2026-07-19 after a single A4 instrumentation bite introduced four of them (every one of the
# other 913 literals in gpu.cyr + main.cyr was correct). Failures print in full — a bare FAIL line would not
# be actionable.
echo ""
echo "--- Source Hygiene ---"
sh "$ROOT/scripts/check/kprint-len-check.sh" > /tmp/kprint-len-check.log 2>&1 && rc=0 || rc=$?
check "kprint literal lengths" $rc
[ "$rc" = "0" ] || cat /tmp/kprint-len-check.log

# Syscall ABI three-way consistency: kernel dispatch == ABI doc == the cyrius SysNrAgnos peer.
# agnos redefines the syscall numbers (exit is #0, not Linux's 60), so a wrong number COMPILES CLEAN
# and calls a different arm — confirmed shipping in jalwa as `poll`(7) -> `open` PER FRAME and
# `read`(0) -> `exit`. Wired in 2026-08-05 after an audit found the ABI doc individually documented
# 65 of 96 syscalls, with 32 missing entirely and the doc and the cyrius peer each naming the OTHER as
# authoritative — so for a third of the ABI neither file was canonical and a wrong number in either
# could be "verified" against the other. Those gaps accumulated over ~15 minor versions because
# nothing diffed them. Same argument as the kprint gate: a hand-maintained table nothing compares
# will drift, and the drift is invisible until it is a runtime fault in someone else's repo.
sh "$ROOT/scripts/check/syscall-abi-check.sh" > /tmp/syscall-abi-check.log 2>&1 && rc=0 || rc=$?
check "syscall ABI (kernel/doc/cyrius agree)" $rc
[ "$rc" = "0" ] || cat /tmp/syscall-abi-check.log

# Channel-band (#97) semantic proof — host-side, no QEMU, milliseconds. Bite 3 of the local-IPC
# migration: it executes the RECORD/BATCH/LIVENESS contract from planning/ipc.md §9 against Linux
# socketpair(SOCK_SEQPACKET) so the kernel band, when it lands at bite 4, has something EXTERNAL to be
# measured against rather than serving as its own specification (§9.8: every claim in that design is
# currently "read-only static analysis"). Negative control: building it over SOCK_STREAM instead fails
# exactly the 6 framing assertions and passes the rest — the proof discriminates the property it names.
sh "$ROOT/scripts/check/chan-semantics-check.sh" > /tmp/chan-semantics.log 2>&1 && rc=0 || rc=$?
check "channel-band semantics (host socketpair proof)" $rc
[ "$rc" = "0" ] || cat /tmp/chan-semantics.log

# GPU arena slot overlap. Every *_SUBOFF is a byte offset into the ONE compute arena, and two
# subsystems owning the same bytes is a silent corruption — VM_CONTEXT0 is disabled, so there are no
# page tables and an out-of-bounds GPU store lands somewhere REAL.
#
# ⛔ THIS USED TO BE A VALUE-ONLY `sort | uniq -d`, and its own comment defended that as "it needs no
# knowledge of each slot's extent, so it cannot rot". It could not rot because it was not checking the
# thing that matters: two slots do not need the same START to collide, only a shared BYTE. It missed a
# live one — the batched-frame snapshot at 0xC0000 spans 0x20000 bytes to 0xE0000, and the rung-9
# per-edge prep table was allocated at 0xD0000, wholly inside it, and shipped. Different values, so
# `uniq -d` saw nothing. Now extent-aware; see scripts/check/check-arena.sh. Detail prints on failure.
sh "$ROOT/scripts/check/check-arena.sh" > /tmp/check-arena.log 2>&1 && rc=0 || rc=$?
check "gpu arena slots unaliased (extent-aware)" $rc
[ "$rc" = "0" ] || cat /tmp/check-arena.log

# GPU CARVEOUT top-level regions. check-arena.sh gates the *_SUBOFF slots INSIDE the 2 MB arena; the
# regions THEMSELVES — console FB, pan, back buffers, PSP TMR, arena, shm, RT — had no gate at all.
# They are hand-placed hex constants whose disjointness was argued in comments and checked by nobody,
# in a region set where VM_CONTEXT0 is disabled: an overlap is not a fault, it is two subsystems
# silently writing each other's bytes.
# ⚠ Added with 1.56.44's shm relocation (0xA0000000 -> 0x90000000, 256 -> 512 MB), which is exactly the
# class of change it guards. Mutation-tested three ways: an overlapping region, a slot that is not a
# 2 MB multiple, and a slot count that outruns its region — each fails.
sh "$ROOT/scripts/check/check-carveout.sh" > /tmp/check-carveout.log 2>&1 && rc=0 || rc=$?
check "gpu carveout regions disjoint + shm table fits" $rc
[ "$rc" = "0" ] || cat /tmp/check-carveout.log
# The Cyrius var X[N] units trap: function-local is N BYTES, module-scope is N x u64. Cost the
# rung-10 burn its exit code (a 40-byte stack smash that left every printed number correct).
sh "$ROOT/scripts/check/check-array-sizing.sh" >/dev/null 2>&1 && rc=0 || rc=$?
check "no function-local array overruns" $rc

# Module-scope symbol collisions between a tests/gpu oracle and a shared layer it includes. SIBLING of
# the gate above, DIFFERENT scope: that one inspects function-LOCAL arrays, this one cross-file
# module-scope declarations, and neither can see the other's class.
# ⛔ WHY IT IS NEEDED: cycc warns about a duplicate `fn` and says NOTHING AT ALL about a duplicate
# `var`, even at conflicting array sizes (measured, cycc 6.5.20). When edgeasm.cyr and asmlib.cyr both
# declared the layer, 46 symbols collided, cycc reported 33 and built OK, and host-gpu-oracles.sh
# discards build output on success -- so all 46 were invisible in practice.
sh "$ROOT/scripts/check/check-dup-symbols.sh" >/tmp/check-dup.log 2>&1 && rc=0 || rc=$?
check "no duplicate module-scope symbols in tests/gpu" $rc
[ "$rc" = "0" ] || cat /tmp/check-dup.log

# An UNBURNED shader has no iron-proven hex to check against, so it is assembled twice — once by
# llvm-mc from its .s, once by mabda's encoder from its emit list — and the dword streams must match.
# ⚠ This is an ENCODING check only. Both sides encode the same instruction sequence; if that sequence
# is semantically wrong they agree and are both wrong. It narrows a burn's search space, never replaces
# it. Move a shader out of this gate and into shaderasm once it HAS committed, burned hex.
# ⭐ THE LIST IS EMPTY AS OF THE 1.56.44 BURN — `blend_alpha` graduated to shaderasm — so what this gate
# now asserts is the PARTITION: every emit list is gated exactly once, by this script or by shaderasm.
# ⚠ The label says so. An empty cross-assembly loop reporting "shaders encode identically" would be the
# fourth vacuous gate this arc has found, and the label is half of how one gets noticed.
sh "$ROOT/scripts/check/shader-crossasm.sh" >/tmp/check-crossasm.log 2>&1 && rc=0 || rc=$?
check "every shader emit list is gated exactly once (crossasm or shaderasm)" $rc
[ "$rc" = "0" ] || cat /tmp/check-crossasm.log

# Shader blobs vs their sources. Each shipped shader is a store32 table in gpu.cyr that is supposed
# to be exactly what the assembler produced from kernel/shaders/*.s -- and until 1.56.19 nothing
# enforced it. A hand-edited dword, a paste that dropped one, or a .s edited after the table was
# generated all ship green and fail on iron with no pointer back to the cause. Calibrated: it agrees
# with the shipped, iron-proven edge_cov blob, and mutation-tested both ways (a corrupted dword and
# a deleted one both go red).
BLOBDRIFT=""
# ⚠ tex_rgba and tex_list were NOT in this list until rung 14 — the two largest and most
# intricate blobs in the tree were the two nobody was diffing. Both pass; the gap was in the gate,
# not the tables.
# ⚠ blend_alpha ADDED 1.56.44, closing a triangle that would otherwise have a loose corner. THREE
# artifacts describe that shader: the .s, the emit list, and the committed hex in gpu.cyr.
# `shader-crossasm.sh` ties the .s to the emit list (two independent assemblers) and `shaderexec.cyr`
# executes the emit list — but NOTHING tied the committed HEX to either, so it could drift silently.
# Verified by corrupting one committed dword before adding it here: check.sh stayed fully green.
for sb in edge_setup edge_cov tri_rgba tex_rgba tex_list tex_list_cm tex_bilin blend_alpha; do
    sh "$ROOT/scripts/check/shader-blob.sh" check "$ROOT/kernel/shaders/$sb.s" "$sb" >/tmp/shader-blob-$sb.log 2>&1 \
        || BLOBDRIFT="$BLOBDRIFT$sb "
done
test -z "$BLOBDRIFT" && rc=0 || rc=$?
check "shader blobs match their .s sources" $rc
[ -z "$BLOBDRIFT" ] || { for sb in $BLOBDRIFT; do cat /tmp/shader-blob-$sb.log; done; }

# tex_list.s is tex_rgba.s's proven body under a new prologue. A copy is only as good as the proof
# that it IS one: this gate fails the build the moment the two bodies diverge by a single character.
sh "$ROOT/scripts/check/texl-body-identity.sh" >/tmp/texl-body.log 2>&1 && rc=0 || rc=$?
check "rung 14's shader carries rung 13's body verbatim" $rc
[ $rc -eq 0 ] || cat /tmp/texl-body.log

# tex_list_cm.s is tex_list.s with the lane axis transposed, DERIVED by this script rather than
# hand-copied. ⚠ It cannot reuse the gate above: that one asserts the differing dwords form a
# contiguous prefix (true when the only difference is a prologue), and 14b differs in TWO runs by
# construction — the prologue AND a declared 4-instruction address window inside the body region.
python3 "$ROOT/scripts/check/texl-cm-derive.py" check >/tmp/texl-cm.log 2>&1 && rc=0 || rc=$?
check "rung 14b's col-major shader is the declared derivation" $rc
[ $rc -eq 0 ] || cat /tmp/texl-cm.log

# tex_bilin.s (rung 15) shares rung 13's code at BOTH ENDS and diverges in the middle, so it needs
# its own gate rather than the rung-14 one: that gate assumes the shared region is a single
# contiguous SUFFIX. Four stages — head source, tail source, tail dwords, and an assertion that the
# head's only dword differences are branch OFFSETS. ⚠ Mutation-tested four ways; the fourth
# (an edit BEFORE the head marker, outside both source spans) is caught by the dword stage ALONE,
# which is what earns that stage its place.
sh "$ROOT/scripts/check/texbi-body-identity.sh" >/tmp/texbi-body.log 2>&1 && rc=0 || rc=$?
check "rung 15's shader carries rung 13's head and tail verbatim" $rc
[ $rc -eq 0 ] || cat /tmp/texbi-body.log

# rtaudit.cyr mirrors nine constants out of gpu_regs.cyr because a host test cannot include a kernel
# module. ⛔ A mirror nobody diffs is ATOM_DRY: move GPU_RT_REGION_OFF and the host proof keeps
# certifying the OLD placement, green, forever. Mutation-tested (perturb one mirrored value -> DRIFT).
sh "$ROOT/scripts/check/rt-region-derive.sh" >/tmp/rt-region.log 2>&1 && rc=0 || rc=$?
check "rung 6's host proof mirrors the kernel's region constants" $rc
[ $rc -eq 0 ] || cat /tmp/rt-region.log

# ⛔ THE KERNARG CONTRACT, WHICH COST A BURN. gpu_blend_cov_run puts n_tri in s4 and the framebuffer
# pitch in s5; tri_depth.s read them swapped. It assembled clean, matched its committed blob byte for
# byte, and every host oracle stayed green — none of them can see across the kernarg boundary. Worse,
# the resulting frame was DETERMINISTIC and ORDER-INDEPENDENT, so the rung's own oracle passed too.
# Also gates the loop-carried registers against rung 13's v19 clobber. Both checks mutation-tested.
# The same kernarg contract for rung 18's kernel, gated BEFORE its first burn rather than after one.
sh "$ROOT/scripts/check/triper-contract.sh" >/tmp/triper-contract.log 2>&1 && rc=0 || rc=$?
check "tri_persp.s kernarg contract + loop-carried registers" $rc
[ $rc -eq 0 ] || cat /tmp/triper-contract.log

sh "$ROOT/scripts/check/tridepth-contract.sh" >/tmp/tridepth-contract.log 2>&1 && rc=0 || rc=$?
check "tri_depth.s kernarg contract + loop-carried registers" $rc
[ $rc -eq 0 ] || cat /tmp/tridepth-contract.log

# The host oracle for the op 0x0C grid mapping. ⚠ Until now NOTHING ran tests/gpu/*.cyr — they were
# scanned and cited but never executed, so a red oracle stayed invisible until someone remembered it.
sh "$ROOT/scripts/check/host-gpu-oracles.sh" >/tmp/host-gpu.log 2>&1 && rc=0 || rc=$?
check "host GPU oracles (0x0C grid, r15 bilinear, r6 region, r17 depth order)" $rc
[ $rc -eq 0 ] || cat /tmp/host-gpu.log

# Call arity. cycc WARNS on an argument-count mismatch and builds anyway, so a wrong call ships green.
# Wired in 2026-07-22 after the 1.56.x audit found gpu_blend_cov_run declared with 12 parameters and
# called with 11 at BOTH coverage sites — including gpu_cov_surface. (⚠ That worker was described here as
# "behind syscall #93"; that shape was WITHDRAWN at 1.56.4 — coverage is now op code 0x02 inside #92, and
# #93 is unallocated, ratified for gpu_modeset_op by MD-4. The arity lesson below is unaffected.)
# Every argument after the missing one shifted by one position, which made done_phys undefined and turned
# the function's first statement into a wild kernel store32. It had been warning in every build since the
# glyph refactor. This promotes that warning to a build failure.
ARITY=$(sh "$ROOT/scripts/build.sh" 2>&1 | grep -E "expects [0-9]+ arguments, got [0-9]+" || true)
test -z "$ARITY" && rc=0 || rc=$?
check "call arity (no cycc argument-count warnings)" $rc
[ -z "$ARITY" ] || echo "$ARITY" | sed 's/^/    /'


# Tests
echo ""
echo "--- Tests ---"
sh "$ROOT/scripts/test.sh" > /dev/null 2>&1 && rc=0 || rc=$?
check "test suite" $rc

# Required docs
echo ""
echo "--- Documentation ---"
for doc in README.md CHANGELOG.md VERSION CONTRIBUTING.md SECURITY.md LICENSE; do
    test -f "$ROOT/$doc" && rc=0 || rc=$?
    check "doc: $doc" $rc
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
test -z "$VDRIFT" && rc=0 || rc=$?
check "version in kernel" $rc
[ -z "$VDRIFT" ] || { echo "  VERSION is $VERSION — regenerate with: sh scripts/version-bump.sh --regen"; printf "$VDRIFT"; }
grep -q "$VERSION" "$ROOT/CHANGELOG.md" 2>/dev/null && rc=0 || rc=$?
check "version in changelog" $rc

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
# ⚠ 2 MB, RAISED 2026-07-26 AS DELIBERATE TEMPORARY HEADROOM — NOT a derived bound.
# Every raise above was reactive: an arc closed a few hundred bytes over the line and the ceiling
# moved just past it. That pattern makes the gate a rubber stamp — it can only ever fire once per
# arc, at which point it is raised. The attribute-interpolation rung landed at 1,791,168 B (under
# 9 KB of the old 1.8M), and the next rung adds another shader blob, so it would have tripped again
# within the same release for the same non-reason.
# ⛔ THIS IS A GRANT, NOT A MEASUREMENT, AND IT EXPIRES. The bound that would actually be worth
# gating is "growth attributable to something other than new subsystems" — a runaway-bloat detector
# rather than a high-water mark chased upward. Re-derive it before the 3D arc closes; do not simply
# move it again.
test "$SZ" -gt 50000 && test "$SZ" -lt 2097152 && rc=0 || rc=$?
check "binary size ($SZ bytes)" $rc

echo ""
echo "=========================="
echo "$pass passed, $fail failed"
test $fail -eq 0
