#!/bin/sh
# Test the AGNOS kernel build
# Supports: x86_64 (default), aarch64 (--aarch64), both (--all)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CYRIUS="$ROOT/../cyrius"
# Find toolchain: ~/.cyrius/bin/ (CI/installer) then ../cyrius/build/ (dev)
if [ -x "$HOME/.cyrius/bin/cyrb" ]; then
    CC="$HOME/.cyrius/bin/cc2"
    CC_ARM="$HOME/.cyrius/bin/cc2_aarch64"
    CYRB="$HOME/.cyrius/bin/cyrb"
elif [ -x "${CYRIUS}/build/cyrb" ]; then
    CC="${CYRIUS}/build/cc2"
    CC_ARM="${CYRIUS}/build/cc2_aarch64"
    CYRB="${CYRIUS}/build/cyrb"
fi
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

    # Build kernel (requires cyrb for multi-file includes)
    # cyrb looks for cc2 at ./build/cc2 relative to CWD
    rm -f /tmp/agnos_test
    if [ -x "$CYRB" ]; then
        PREPPED="/tmp/agnos_prepped.cyr"
        (echo '#define ARCH_X86_64' && cat "$ROOT/kernel/agnos.cyr") > "$PREPPED"
        (cd "$ROOT" && cd kernel && mkdir -p build && ln -sf "$CC" build/cc2 && "$CYRB" build "$PREPPED" /tmp/agnos_test) 2>&1
        rm -f "$PREPPED"
    else
        echo "ERROR: cyrb not found at $CYRB" >&2
    fi
    # Check build produced a valid file
    if [ -f /tmp/agnos_test ] && [ -s /tmp/agnos_test ]; then
        check "x86 kernel builds" "0" "0"
    else
        check "x86 kernel builds" "0" "1"
        # Skip remaining tests if build failed
        return
    fi

    # Validate ELF
    python3 -c "
import struct
with open('/tmp/agnos_test','rb') as f: d=f.read()
mb = struct.unpack_from('<I',d,84)[0]
entry = struct.unpack_from('<I',d,24)[0]
ok = mb == 0x1badb002 and entry == 0x100060 and len(d) > 1000
exit(0 if ok else 1)
" 2>/dev/null
    check "x86 valid multiboot ELF" "0" "$?"

    # Size check
    SZ=$(wc -c < /tmp/agnos_test 2>/dev/null || echo 0)
    if [ "$SZ" -gt 50000 ] && [ "$SZ" -lt 150000 ]; then
        check "x86 size reasonable (${SZ}B)" "0" "0"
    else
        check "x86 size reasonable (${SZ}B)" "0" "1"
    fi

    # Build kernel_hello
    if [ -f "$ROOT/kernel/kernel_hello.cyr" ]; then
        cat "$ROOT/kernel/kernel_hello.cyr" | "$CC" > /tmp/kernel_hello_test 2>/dev/null
        check "x86 kernel_hello builds" "0" "$?"
    fi

    rm -f /tmp/agnos_test /tmp/kernel_hello_test
}

test_aarch64() {
    echo "=== AGNOS Kernel Tests [aarch64] ==="

    if [ ! -x "$CC_ARM" ]; then
        echo "  SKIP: aarch64 cross-compiler not found"
        return
    fi

    # Build kernel (aarch64 kernel has x86 inline asm — expected to fail until ported)
    (cat "$ROOT/kernel/agnos.cyr" | "$CC_ARM" > /tmp/agnos_arm_test 2>/dev/null) 2>/dev/null
    rc=$?
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
