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

# Toolchain pins. CI installs ONE cyrius, read from the ROOT manifest (ci.yml:37 and four sibling
# jobs). A nested cyrius.cyml pinning anything else is a claim on a toolchain no runner has — and the
# wrapper resolves the manifest at the COMPILE CWD, so `cd tests/gpu && cyrius build`
# (host-gpu-oracles.sh:179) hard-errors "pins version X but cyrius binary is not installed" and takes
# that whole gate down with it. That is exactly how 2026-08-24 CI broke.
# ⛔ THIS IS THE FIRST GATE HERE THAT IS GREEN-LOCAL / RED-CI BY CONSTRUCTION, WHICH IS WHY IT EXISTS.
# This box caches every cyrius version, so a stale nested pin RESOLVES and degrades to a warning; the
# runner has one version and it is an error. Worse, the warning compares the pin to the INSTALLED
# cycc, not to the root pin — so a CORRECT manifest warns in identical words and the warning cannot
# say which file is broken. ⚠ The gate therefore NEVER INVOKES cyrius: it compares pin strings in
# files, so its verdict does not depend on ~/.cyrius/versions/. A gate that built something to test
# the pin would reproduce the very asymmetry it is meant to catch.
# It runs FIRST because a broken toolchain precondition should report as TOOLING, not as a downstream
# red gate — the same reason host-gpu-oracles.sh runs mabda-resolve.sh before its loop.
echo "--- Toolchain ---"
sh "$ROOT/scripts/check/toolchain-pin-check.sh" > /tmp/toolchain-pin-check.log 2>&1 && rc=0 || rc=$?
check "all cyrius.cyml pins match the root pin" $rc
[ "$rc" = "0" ] || cat /tmp/toolchain-pin-check.log
echo ""

# Regenerated files must not be tracked. Grouped with the toolchain gate because it shares that gate's
# two properties: it invokes NO compiler (its verdict comes from the git index and the ignore rules, so
# it answers the same on a box caching every cyrius version and on a runner with one), and it is a
# precondition — a fossil binary under tests/*/build/ makes every downstream oracle a report about
# whatever source existed when someone last ran a compiler.
# ⛔ 2026-08-24: the 1.56.44 purge that gitignored tests/gpu/build/ swept ONE of seven directories.
# Twelve fossils survived in the other six and were NOT byte-identical to a rebuild (symtest 13,856 B
# committed vs 18,552 B built), and 88 vendored stdlib files under tests/*/lib/ were tracked besides —
# two of those dirs matching NO installed snapshot, missing v6.4.51's signal_ignore. See the script
# header. ⚠ Mutation-tested in all four failure paths (tracked file, missing ignore rule, and both
# vacuity floors); a negative assertion that has never been forced red is not a gate.
sh "$ROOT/scripts/check/vendored-artifact-check.sh" > /tmp/vendored-artifact-check.log 2>&1 && rc=0 || rc=$?
check "no regenerated files tracked under tests/*/{lib,build}" $rc
[ "$rc" = "0" ] || cat /tmp/vendored-artifact-check.log
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
# 1.56.52 — the SysV init-stack pointer array vs the argc/envc caps. Those caps live in two functions
# that never see each other, so nothing in the kernel held the combined invariant and the array was
# silently too small from the moment argc was raised 8 -> 16. The runtime guard added alongside this
# is unreachable under the shipped caps by construction, so a static re-derivation is the only form
# that can actually fail. Mutation-tested: restoring the old ELF_INIT_STR reports slots=31 vs top
# index 35, which is exactly the overflow.
sh "$ROOT/scripts/check/check-initstack.sh" > /tmp/check-initstack.log 2>&1 && rc=0 || rc=$?
check "init-stack pointer array holds argc+envc" $rc
[ "$rc" = "0" ] || cat /tmp/check-initstack.log
# The Cyrius var X[N] units trap: function-local is N BYTES, module-scope is N x u64. Cost the
# rung-10 burn its exit code (a 40-byte stack smash that left every printed number correct).
sh "$ROOT/scripts/check/check-array-sizing.sh" >/dev/null 2>&1 && rc=0 || rc=$?
check "no function-local array overruns" $rc

# ⛔ THE RELEASE GATE THAT NEVER BOOTED A KERNEL. release.yml gates every release on a job it calls
# "CI Gate (must pass before release)", but under workflow_call the called workflow sees the CALLER's
# ref — a tag, never refs/heads/main — so both self-hosted jobs were skipped on every release run.
# This property is untestable from a developer machine (no way to dispatch a tag-triggered reusable
# workflow locally), so a static re-read is the only form that can fail. Mutation-tested both ways:
# reverting a guard reports the job by name, and breaking the parser FAILS rather than passing green.
sh "$ROOT/scripts/check/check-ci-release-gate.sh" > /tmp/check-ci-gate.log 2>&1 && rc=0 || rc=$?
check "self-hosted CI jobs run on release tags" $rc
[ "$rc" = "0" ] || cat /tmp/check-ci-gate.log

# Module-scope symbol collisions between a tests/gpu oracle and a shared layer it includes. SIBLING of
# check-array-sizing.sh, DIFFERENT scope: that one inspects function-LOCAL arrays, this one cross-file
# module-scope declarations, and neither can see the other's class.
# ⚠ NAMED, NOT "the gate above" — 1.56.52 inserted check-ci-release-gate.sh between the two and a
# positional back-reference silently started pointing at the wrong gate. Reference gates by filename.
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
BLOBN=0
BLOBVAC=""
# ⚠ tex_rgba and tex_list were NOT in this list until rung 14 — the two largest and most
# intricate blobs in the tree were the two nobody was diffing. Both pass; the gap was in the gate,
# not the tables.
# ⚠ blend_alpha ADDED 1.56.44, closing a triangle that would otherwise have a loose corner. THREE
# artifacts describe that shader: the .s, the emit list, and the committed hex in gpu.cyr.
# `shader-crossasm.sh` ties the .s to the emit list (two independent assemblers) and `shaderexec.cyr`
# executes the emit list — but NOTHING tied the committed HEX to either, so it could drift silently.
# Verified by corrupting one committed dword before adding it here: check.sh stayed fully green.
for sb in edge_setup edge_cov tri_rgba tex_rgba tex_list tex_list_cm tex_bilin blend_alpha; do
    BLOBN=$((BLOBN + 1))
    sh "$ROOT/scripts/check/shader-blob.sh" check "$ROOT/kernel/shaders/$sb.s" "$sb" >/tmp/shader-blob-$sb.log 2>&1 \
        || BLOBDRIFT="$BLOBDRIFT$sb "
done
# ⚠ VACUITY FLOOR, 2026-09-02. The verdict below is `test -z "$BLOBDRIFT"` over a variable that
# STARTS EMPTY, so the gate's success condition is satisfied by a loop that never ran a single
# iteration. Delete the names from the `for` list — during a rebase, while extracting them to a
# generated list, or by a stray edit to a line nobody re-reads — and check.sh prints
# "PASS: shader blobs match their .s sources" having assembled nothing and diffed nothing. The
# iteration count is therefore asserted (>= 8, the number this gate is written around) and, with the
# committed .s count beside it, PRINTED: a run that says "1 of 21 committed .s checked" is reporting
# that its own list broke, not that the tables are clean.
# ⚠ The second number is DERIVED, not typed, and it is not a pass condition — it is the coverage gap
# in the open. 8 of 21 is what this hand-kept list covers; blend_cov, blend_pk, blend_premul,
# blend_rect, glyph_1bpp, grad_linear, matmul_{copy,dot,f64,i32}, perm, tri_depth and tri_persp have
# committed hex that nothing here diffs against their source. Closing that is a scope decision, not a
# vacuity fix — but the number now appears on every run rather than living only in an issue doc.
# (A NAMED shader whose .s is missing is already non-vacuous: shader-blob.sh:26 exits 2 on an absent
# source, which lands the name in BLOBDRIFT. It is the empty LIST that scored green.)
BLOBTOTAL=$(ls "$ROOT"/kernel/shaders/*.s 2>/dev/null | grep -c . || true)
[ "$BLOBN" -ge 8 ] || BLOBVAC="enumerated $BLOBN blob name(s), not the 8 this gate is written around — the list broke, the tree did not"
[ -z "$BLOBVAC" ] && [ -z "$BLOBDRIFT" ] && rc=0 || rc=$?
check "shader blobs match their .s sources ($BLOBN of $BLOBTOTAL committed .s checked)" $rc
[ -z "$BLOBVAC" ] || echo "    VACUOUS: $BLOBVAC"
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
# ⚠ VACUITY FLOOR, 2026-09-02. THE PRODUCER'S EXIT STATUS USED TO BE UNREADABLE HERE, THREE TIMES
# OVER. The gate was one line —
#     ARITY=$(sh "$ROOT/scripts/build.sh" 2>&1 | grep -E "expects ... arguments, got ..." || true)
# — and this is a NEGATIVE assertion, so everything that makes the build produce no output makes it
# pass. A pipeline's status is the LAST command's, i.e. grep's, never build.sh's; the `|| true` then
# launders even that, so `set -e` cannot see the failure either; and check() is handed the status of
# `test -z` on an empty string. Measured on this tree 2026-09-02: point CYRIUS_HOME at a directory
# with no wrapper and build.sh exits 1 after three lines ("ERROR: cyrius wrapper not found"), $ARITY
# is empty, and the gate printed "PASS: call arity (no cycc argument-count warnings)" having compiled
# nothing. Every way the build can die early — a stale nested cyrius.cyml pin (the exact 2026-08-24
# CI break the first gate in this file exists for), an unreachable kashi checkout, a cycc that is not
# on PATH — reads here as a clean tree. That is the same shape as the 1.56.44 gates found unrunnable.
# The build rc is now captured and asserted, and the number of build-output lines grep actually
# scanned is PRINTED beside the verdict: a healthy x86_64 build emits 8 non-empty lines (measured), a
# build that died before invoking the compiler emits 3, so a run reporting "3 build lines scanned" is
# reporting that its own producer died rather than that the tree is clean. Floor set at 5 — three
# lines of headroom under the healthy count, two above the dead one.
# ⚠ NOT resolved by reusing the "x86_64 build" gate's rc from further up this file. That gate is a
# separate invocation and its own comment does not promise to stay one; this gate must be able to
# fail on its own producer, in its own run, without a positional dependency on a gate above it.
ARITY_LOG=/tmp/check-arity-build.log
sh "$ROOT/scripts/build.sh" > "$ARITY_LOG" 2>&1 && ARITY_BUILD_RC=0 || ARITY_BUILD_RC=$?
ARITY=$(grep -E "expects [0-9]+ arguments, got [0-9]+" "$ARITY_LOG" || true)
ARITY_LINES=$(grep -c . "$ARITY_LOG" || true)
ARITY_VAC=""
[ "$ARITY_BUILD_RC" = "0" ] \
    || ARITY_VAC="build.sh exited $ARITY_BUILD_RC — a build that did not compile emits no arity warnings, so an empty result here is not evidence"
[ -n "$ARITY_VAC" ] || [ "$ARITY_LINES" -ge 5 ] \
    || ARITY_VAC="build.sh produced $ARITY_LINES non-empty line(s); this gate is vacuous below 5 (a healthy build emits 8)"
[ -z "$ARITY_VAC" ] && [ -z "$ARITY" ] && rc=0 || rc=$?
check "call arity (no cycc argument-count warnings; $ARITY_LINES build lines scanned)" $rc
[ -z "$ARITY_VAC" ] || echo "    VACUOUS: $ARITY_VAC — see $ARITY_LOG"
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
# ⚠ VACUITY FLOOR, 2026-09-02. THE PATTERN WAS THE INPUT SET, AND AN EMPTY ONE MATCHED EVERYTHING.
# The gate was `grep -q "$VERSION" CHANGELOG.md`, and with $VERSION empty that is `grep -q ""`, which
# matches every line of every file — so a VERSION file that was truncated, half-written by an
# interrupted version-bump.sh, or unreadable scored this gate GREEN while asserting nothing about the
# changelog at all. Nothing upstream catches it either: the `doc: VERSION` gate above is `test -f`,
# which passes on a 0-byte file, and sibling gate "version in kernel" is immune only by accident (its
# VFN/VGV equality comparisons happen to fail against ""). Verified 2026-09-02: `VERSION="" ; grep -q
# "" CHANGELOG.md` returns 0. The token is now shape-checked BEFORE it is used as a pattern.
# ⚠ And matched with -F. The dots in 1.56.58 were regex wildcards in an unanchored match, so a
# changelog containing `1x56x58` — or `v1.56.580` for a VERSION of 1.56.58 — satisfied it. -F makes
# the pattern mean the string it looks like; `-e` guards a VERSION that starts with a dash.
VCLOG=""
case "$VERSION" in
    "")                   VCLOG="VERSION file is empty — 'grep -q \"\"' matches every line, so this gate could not fail" ;;
    [0-9]*.[0-9]*.[0-9]*) : ;;
    *)                    VCLOG="VERSION file does not hold an X.Y.Z token (read: '$VERSION') — refusing to use it as a pattern" ;;
esac
[ -n "$VCLOG" ] || grep -qF -e "$VERSION" "$ROOT/CHANGELOG.md" 2>/dev/null \
    || VCLOG="CHANGELOG.md contains no literal '$VERSION'"
test -z "$VCLOG" && rc=0 || rc=$?
check "version in changelog" $rc
[ -z "$VCLOG" ] || echo "    $VCLOG"

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
# ⚠ VACUITY FLOOR, 2026-09-02. THIS GATE MEASURED WHATEVER FILE HAPPENED TO BE ON DISK, AND NOTHING
# TIED THAT FILE TO A BUILD IN THIS RUN. It opened `SZ=$(wc -c < "$ROOT/build/agnos")`, which failed
# two ways:
#   · FOSSIL. build.sh does NOT `rm -f build/agnos` before an x86_64 build — it does exactly that for
#     aarch64 (build.sh:133, added because a stale artifact was being re-measured after a failed
#     cross-compile), and the x86_64 path never got the same treatment. So when the build gates above
#     fail, yesterday's binary is still sitting there, and this gate weighed it and passed. Measured
#     2026-09-02: `CYRIUS_HOME=<empty> sh scripts/build.sh` exits 1 and leaves the previous
#     1,997,536-byte build/agnos untouched. Same class as vendored-artifact-check.sh:6-8 — a
#     regenerated file left over from an earlier run is not evidence about the source beside it.
#   · ABORT. With the file absent the command substitution fails, and `set -e` kills the whole script
#     ON THIS LINE: no FAIL line, no "N passed, M failed" summary, just a log that stops mid-run. That
#     is precisely the truncated-log failure the header at the top of this file forbids.
# The size is now read only when the build that WRITES that file is known to have succeeded in this
# run, and the absent-file case reports a FAIL instead of killing the run before the summary.
# ⚠ ARITY_BUILD_RC, not the "x86_64 build" gate's rc, because the arity gate's invocation is the LAST
# writer of build/agnos before this line — that is the build whose output this gate is weighing. If a
# future edit moves this gate above that one, the variable is unset, `[ "" = "0" ]` is false, and the
# gate fails closed rather than silently returning to measuring a fossil.
SZ=0
SZWHY=""
if [ ! -f "$ROOT/build/agnos" ]; then
    SZWHY="build/agnos does not exist — there is no binary to weigh"
else
    SZ=$(wc -c < "$ROOT/build/agnos")
    [ "$ARITY_BUILD_RC" = "0" ] \
        || SZWHY="the build that writes build/agnos exited $ARITY_BUILD_RC above, and build.sh does not remove the old x86_64 artifact first — this $SZ-byte file is a fossil from an earlier run, not this run's output"
fi
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
[ -z "$SZWHY" ] && test "$SZ" -gt 50000 && test "$SZ" -lt 2097152 && rc=0 || rc=$?
check "binary size ($SZ bytes)" $rc
[ -z "$SZWHY" ] || echo "    VACUOUS: $SZWHY"

echo ""
echo "=========================="
echo "$pass passed, $fail failed"
test $fail -eq 0
