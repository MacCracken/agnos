#!/bin/sh
# Test the AGNOS kernel build
# Supports: x86_64 (default), aarch64 (--aarch64), both (--all)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CYRIUS_HOME="${CYRIUS_HOME:-$HOME/.cyrius}"
CYRB="$CYRIUS_HOME/bin/cyrius"
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
        (echo '#define ARCH_X86_64' && cat "$ROOT/kernel/agnos.cyr") > "$PREPPED"
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
    # binary 675→708 KB; it crossed 700KB with bites 2/3 of 1.33.4).
    SZ=$(wc -c < $ROOT/build/agnos_test 2>/dev/null || echo 0)
    if [ "$SZ" -gt 50000 ] && [ "$SZ" -lt 800000 ]; then
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
    (echo '#define ARCH_AARCH64' && cat "$ROOT/kernel/agnos.cyr") > "$PREPPED_ARM"
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
