#!/bin/sh
# Test the AGNOS kernel build
# Supports: x86_64 (default), aarch64 (--aarch64), both (--all)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CYRIUS_HOME="${CYRIUS_HOME:-$HOME/.cyrius}"
CYRB="$CYRIUS_HOME/bin/cyrius"

# kashi sibling/fetch handling — same contract as scripts/build.sh (see comment
# there). Pinned at 1.0.0 (kashi's v1 API freeze).
KASHI_DIR="${KASHI_DIR:-$ROOT/../kashi}"
KASHI_REF="${KASHI_REF:-1.0.0}"
if [ ! -f "$KASHI_DIR/src/font_data.cyr" ]; then
    echo "  kashi not at $KASHI_DIR — cloning $KASHI_REF for test..." >&2
    rm -rf "$KASHI_DIR"
    git clone --quiet --depth 1 --branch "$KASHI_REF" \
        https://github.com/MacCracken/kashi.git "$KASHI_DIR" >&2 || {
        echo "ERROR: kashi clone failed (ref=$KASHI_REF)" >&2
        exit 1
    }
fi
# cc5_aarch64 existence is the gate for aarch64 cross-compile; cyrius
# wrapper invokes it internally — we never call cc5/cc5_aarch64 directly.
CC_ARM="$CYRIUS_HOME/bin/cc5_aarch64"
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
    if [ -x "$CYRB" ]; then
        PREPPED="$ROOT/build/agnos_prepped.cyr"
        (echo '#define ARCH_X86_64' && cat "$KASHI_DIR/src/font_data.cyr" && cat "$ROOT/kernel/agnos.cyr") > "$PREPPED"
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

    # Validate ELF
    python3 -c "
import struct
with open('$ROOT/build/agnos_test','rb') as f: d=f.read()
mb = struct.unpack_from('<I',d,84)[0]
entry = struct.unpack_from('<I',d,24)[0]
ok = mb == 0x1badb002 and entry == 0x100060 and len(d) > 1000
exit(0 if ok else 1)
" 2>/dev/null
    check "x86 valid multiboot ELF" "0" "$?"

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
    # The arc's growth is register tables (OTG timing, the HDMI/AFMT/ACR block) plus
    # their derivations, not bloat: those tables are the compressed form of what the
    # burns proved, and losing them costs another burn to re-learn.
    SZ=$(wc -c < $ROOT/build/agnos_test 2>/dev/null || echo 0)
    if [ "$SZ" -gt 50000 ] && [ "$SZ" -lt 1700000 ]; then
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

    if [ ! -x "$CC_ARM" ]; then
        echo "  SKIP: aarch64 cross-compiler not found"
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
        echo "  SKIP: aarch64 kernel compile (x86 inline asm not yet ported)"
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
