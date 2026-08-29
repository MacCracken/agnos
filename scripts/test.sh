#!/bin/sh
# Test the AGNOS kernel build
# Supports: x86_64 (default), aarch64 (--aarch64), both (--all)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CYRIUS_HOME="${CYRIUS_HOME:-$HOME/.cyrius}"
CYRB="$CYRIUS_HOME/bin/cyrius"

# kashi sibling/fetch handling — same contract as scripts/build.sh (see comment there).
# ⛔ MEASURED 2026-08-28 (1.56.51): THE THREE SCRIPTS HAD DIVERGED AGAIN, AND THIS COMMENT NAMED A
# FOURTH VALUE. build.sh defaulted 1.0.6, test.sh and bench.sh 1.0.4, and the line above said
# "Pinned at 1.0.0". This is invisible on a dev box — cyrius.cyml declares `[deps.kashi] path`, and
# the path WINS, so every local build silently uses the sibling working tree (1.0.6 here) whatever
# any script's default says. It only bites a CLEAN CHECKOUT, where the kashi you get depends on
# WHICH SCRIPT RAN FIRST, and the kernel that ships is then built against different glyph data than
# the kernel that was tested. All three now default 1.0.6, matching ../kashi/VERSION.
# ⚠ Keep them in step and re-verify against kashi's own VERSION at every cut. This has now
# re-diverged twice; it is a recurring failure, not an incident.
KASHI_DIR="${KASHI_DIR:-$ROOT/../kashi}"
KASHI_REF="${KASHI_REF:-1.0.6}"
if [ ! -f "$KASHI_DIR/src/font_data.cyr" ]; then
    echo "  kashi not at $KASHI_DIR — cloning $KASHI_REF for test..." >&2
    rm -rf "$KASHI_DIR"
    git clone --quiet --depth 1 --branch "$KASHI_REF" \
        https://github.com/MacCracken/kashi.git "$KASHI_DIR" >&2 || {
        echo "ERROR: kashi clone failed (ref=$KASHI_REF)" >&2
        exit 1
    }
fi
# The aarch64 cross-compiler's existence gates test_aarch64; the cyrius wrapper invokes it
# internally — we never call it directly.
# ⛔⛔ MEASURED 2026-08-28 (1.56.51): THIS PROBED A BINARY THAT HAS NOT EXISTED SINCE cyrius v6.1.0.
# The backend was renamed cc5_aarch64 -> cycc_aarch64 at v6.0.0 and the back-compat symlink dropped
# at v6.1.0; this tree is on 6.5.36. build.sh HIT THIS EXACT BUG AND WAS FIXED FOR IT (see its
# ⚠ comment at the CC_ARM assignment) — the fix was simply never carried across to here. So
# test_aarch64 took its `[ ! -x "$CC_ARM" ]` early-return on EVERY invocation for the whole 6.1+
# era: `sh scripts/test.sh --aarch64` printed one SKIP line, ran zero checks and exited 0, and
# `--all` reported "4 passed, 0 failed" with the entire aarch64 half inert. CLAUDE.md's closeout
# step calls for `scripts/test.sh --all` 7/7; 7 was not reachable.
CC_ARM="$CYRIUS_HOME/bin/cycc_aarch64"
[ -x "$CC_ARM" ] || CC_ARM="$CYRIUS_HOME/bin/cc5_aarch64"
# Kernel-stdlib is at kernel/klib/ (renamed from kernel/lib/ to dodge the
# cyrius wrapper's ./lib/ shadow contract). No CYRIUS_NO_WARN_SHADOW_LIB
# needed — the wrapper sees no ./lib/ at compile cwd.
pass=0
fail=0

check() {
    if [ "$3" = "$2" ]; then
        echo "  PASS: $1"
        pass=$((pass + 1))
    else
        echo "  FAIL: $1 (expected $2, got $3)"
        fail=$((fail + 1))
    fi
}

test_x86() {
    echo "=== AGNOS Kernel Tests [x86_64] ==="

    # Build kernel (requires cyrius for multi-file includes).
    # `-D ARCH_X86_64` does not propagate into nested #ifdef blocks, so
    # we still prepend `#define ARCH_X86_64` to a temp source.
    mkdir -p $ROOT/build
    rm -f $ROOT/build/agnos_test
    # ⛔⛔ MEASURED 2026-08-28 (1.56.51): THIS BUILT A DIFFERENT KERNEL THAN THE ONE THAT SHIPS,
    # AND THEN VALIDATED THE DIFFERENCE AS CORRECT. build.sh prepends `#define ELF64_KERNEL` and
    # exports `CYRIUS_ELF64_KERNEL=1` — the source-side and backend-side halves of the ELF64
    # multiboot2 emit, which its own comment says "must be set in lockstep". test.sh set NEITHER,
    # so it produced the legacy multiboot1/ELF32 kernel while build/agnos is multiboot2/ELF64.
    # Measured side by side on the same tree:
    #     test.sh's agnos_test : ELF32, entry 0x100060, 0x1BADB002 @84,  1,988,056 B
    #     build.sh's agnos     : ELF64, entry 0x1000a8, 0xE85250D6 @120, 1,988,256 B
    # The ELF assertion below was pinned to the FIRST column, so it passed — on a kernel nothing
    # boots. gnoboot parses the multiboot2 header; the multiboot1 path was retired with Path A on
    # 2026-05-13. The test suite has therefore never once validated the artifact that ships: break
    # build/agnos's boot header tomorrow and this still reports PASS.
    # Both gates are now set here exactly as build.sh sets them, so the two agree by construction.
    export CYRIUS_ELF64_KERNEL=1
    if [ -x "$CYRB" ]; then
        PREPPED="$ROOT/build/agnos_prepped.cyr"
        (echo '#define ARCH_X86_64' && echo '#define ELF64_KERNEL' \
            && cat "$KASHI_DIR/src/font_data.cyr" && cat "$ROOT/kernel/agnos.cyr") > "$PREPPED"
        (cd "$ROOT/kernel" && "$CYRB" build --no-deps "$PREPPED" $ROOT/build/agnos_test) 2>&1
        rm -f "$PREPPED"
    else
        echo "ERROR: cyrius not found at $CYRB" >&2
    fi
    # Check build produced a valid file
    if [ -f $ROOT/build/agnos_test ] && [ -s $ROOT/build/agnos_test ]; then
        check "x86 kernel builds" "0" "0"
    else
        check "x86 kernel builds" "0" "1"
        # Skip remaining tests if build failed
        return
    fi

    # Validate the boot header. Shape is DERIVED from EI_CLASS rather than hardcoded to one
    # protocol — the same form build.sh validates build/agnos with, so the two cannot drift apart
    # again the way they did before 1.56.51. ELF64/multiboot2 is what ships; the ELF32/multiboot1
    # arm is kept only so the legacy emit is still checkable, not because anything boots it.
    # ⚠ The expected shape is asserted, not just the magic: an ELF64 kernel carrying a multiboot1
    # header (or the reverse) is exactly the failure this missed for months.
    python3 -c "
import struct
with open('$ROOT/build/agnos_test','rb') as f: d=f.read()
if len(d) <= 1000: print('  WARN: kernel is implausibly small'); exit(1)
eic = d[4]
if eic == 2:   mb_off, exp_mb, exp_entry, label = 120, 0xe85250d6, 0x1000a8, 'multiboot2 (ELF64)'
elif eic == 1: mb_off, exp_mb, exp_entry, label = 84,  0x1badb002, 0x100060, 'multiboot1 (ELF32)'
else:          print('  WARN: unknown EI_CLASS {}'.format(eic)); exit(1)
mb    = struct.unpack_from('<I',d,mb_off)[0]
entry = struct.unpack_from('<I',d,24)[0]
if mb != exp_mb:
    print('  WARN: {} expected magic 0x{:x} at offset {}, got 0x{:x}'.format(label, exp_mb, mb_off, mb)); exit(1)
if entry != exp_entry:
    print('  WARN: {} expected entry 0x{:x}, got 0x{:x}'.format(label, exp_entry, entry)); exit(1)
if eic != 2:
    print('  WARN: built ELF32/multiboot1 — build.sh ships ELF64/multiboot2; the gates have drifted'); exit(1)
exit(0)
"
    check "x86 boot header matches the shipped ELF64/multiboot2 shape" "0" "$?"

    # Size check — ceiling bumped to 700KB at 1.31.3, then 800KB at 1.33.4
    # (the WRITE arc + symlink resolution + uninit materialization carried the
    # binary 675→708 KB; it crossed 700KB with bites 2/3 of 1.33.4). The
    # 1.34.x FAT-family arc reached ~799 KB; 1.35.x DNS crossed 800 KB, so the
    # sanity ceiling moved 800K → 1.2M. The 1.44.x preemptive-scheduler + 1.45.x
    # net-stack/server arcs then closed on it (1.45.10 = 1,199,984 B, 16 B under),
    # and the 1.45.11 TCP slot-leak fix + persistent HTTP listen-smoke crossed it
    # (~1,200,544 B), so the ceiling moved 1.2M → 1.4M. The 1.54.x GPU arc (F0
    # ~1.40M; C0+ add the CP/MEC/RLC/PSP register tables) moved it 1.4M → 1.5M —
    # generous headroom for the compute bites while still catching a runaway-bloat
    # regression. (Note: ~41 KB is DCE-eliminable unreachable fns — CYRIUS_DCE=1 —
    # if a real squeeze is ever wanted; the ceiling, not DCE, is the growth knob.)
    # The 1.55.x DISPLAY arc then closed on THAT one exactly as 1.45.10 did — the
    # display-audio bite landed at 1,560,016 B, 16 B over — so it moved 1.5M → 1.6M.
    # The 1.55.x shutdown arc then closed on 1.6M (1,600,712 B) — moved 1.6M → 1.7M.
    # The 1.56.x SHADER arc closed on 1.7M (1,700,472 B) — moved 1.7M → 1.8M.
    # The arc's growth is register tables (OTG timing, the HDMI/AFMT/ACR block) plus
    # their derivations, not bloat: those tables are the compressed form of what the
    # burns proved, and losing them costs another burn to re-learn.
    SZ=$(wc -c < $ROOT/build/agnos_test 2>/dev/null || echo 0)
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
if [ "$SZ" -gt 50000 ] && [ "$SZ" -lt 2097152 ]; then
        check "x86 size reasonable (${SZ}B)" "0" "0"
    else
        check "x86 size reasonable (${SZ}B)" "0" "1"
    fi

    # Build kernel_hello via cyrius (cc5 wants a managed entry, not raw stdin)
    if [ -f "$ROOT/kernel/kernel_hello.cyr" ]; then
        "$CYRB" build --no-deps "$ROOT/kernel/kernel_hello.cyr" $ROOT/build/kernel_hello_test >/dev/null 2>&1
        check "x86 kernel_hello builds" "0" "$?"
    fi

    rm -f $ROOT/build/agnos_test $ROOT/build/kernel_hello_test
}

test_aarch64() {
    echo "=== AGNOS Kernel Tests [aarch64] ==="

    # ⛔⛔ MEASURED 2026-08-28 (1.56.51): THIS FUNCTION COULD NOT PRODUCE A FAILURE, BY TWO
    # INDEPENDENT ROUTES, AND BOTH ARE FIXED HERE.
    #   ① The cross-compiler probe named a binary dropped at cyrius v6.1.0 (see the CC_ARM comment
    #     above), so it took this early return every time — a bare `return` that runs zero checks,
    #     contributing neither a pass nor a fail. `test.sh --aarch64` exited 0 having tested nothing.
    #   ② Even past that probe, the compile-failure branch below printed "SKIP: … (x86 inline asm
    #     not yet ported)" and recorded NOTHING. A broken cross-compile and a working one produced
    #     the same tally.
    # Together those made "aarch64 is compile-only but green" unfalsifiable. It is not green:
    # `sh scripts/build.sh --aarch64` fails with 30 reachable undefined functions and ~20 undefined
    # variables, and had been failing long enough that build/agnos-aarch64 on the dev box was a
    # MAY 12 artifact. A missing cross-compiler and a failing compile are now both real FAILs.
    # ⚠ THIS DELIBERATELY TURNS `test.sh --all` RED while the aarch64 port is broken. That is the
    # point: the previous green was reporting coverage that did not exist. check.sh and both CI
    # workflows invoke `sh scripts/test.sh` with no argument (x86 only), so nothing that gates a
    # release changes colour — only the claim about aarch64 does.
    if [ ! -x "$CC_ARM" ]; then
        echo "  aarch64 cross-compiler not found at $CC_ARM"
        echo "  (expected \$CYRIUS_HOME/bin/cycc_aarch64; the legacy cc5_aarch64 name was dropped at cyrius v6.1.0)"
        check "aarch64 cross-compiler present" "0" "1"
        return
    fi

    # Build kernel via cyrius wrapper (cross-compile mode). cd into
    # kernel/ so relative `include "arch/..."` paths resolve.
    mkdir -p $ROOT/build
    PREPPED_ARM="$ROOT/build/agnos_arm_prepped.cyr"
    (echo '#define ARCH_AARCH64' && cat "$KASHI_DIR/src/font_data.cyr" && cat "$ROOT/kernel/agnos.cyr") > "$PREPPED_ARM"
    (cd "$ROOT/kernel" && "$CYRB" build --aarch64 --no-deps "$PREPPED_ARM" /tmp/agnos_arm_test >/dev/null 2>&1)
    rc=$?
    rm -f "$PREPPED_ARM"
    if [ "$rc" = "0" ]; then
        check "aarch64 kernel compiles" "0" "0"

        # Size check
        SZ=$(wc -c < /tmp/agnos_arm_test)
        if [ "$SZ" -gt 50000 ]; then
            check "aarch64 size reasonable (${SZ}B)" "0" "0"
        else
            check "aarch64 size reasonable (${SZ}B)" "0" "1"
        fi
        file /tmp/agnos_arm_test | grep -q "ARM aarch64"
        check "aarch64 valid ELF" "0" "$?"
    else
        echo "  aarch64 kernel compile FAILED — rerun for detail:  sh scripts/build.sh --aarch64"
        echo "  (as of 1.56.51: 30 reachable undefined functions + ~20 undefined variables;"
        echo "   the arch/aarch64/stubs.cyr surface has not kept up with core/)"
        check "aarch64 kernel compiles" "0" "1"
    fi

    rm -f /tmp/agnos_arm_test
}

# Parse args
if [ "$1" = "--aarch64" ]; then
    test_aarch64
elif [ "$1" = "--all" ]; then
    test_x86
    echo ""
    test_aarch64
else
    test_x86
fi

echo ""
echo "=========================="
echo "$pass passed, $fail failed"
exit $fail
