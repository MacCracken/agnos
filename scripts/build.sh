#!/bin/sh
# Build the AGNOS kernel
# Supports: x86_64 (default), aarch64 (--aarch64)
# Requires: Cyrius toolchain (~/.cyrius/bin/)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CYRIUS_HOME="${CYRIUS_HOME:-$HOME/.cyrius}"
CYRB="$CYRIUS_HOME/bin/cyrius"
CC="$CYRIUS_HOME/bin/cc3"
CC_ARM="$CYRIUS_HOME/bin/cc3_aarch64"
echo "  toolchain: $CYRB" >&2
ARCH="x86_64"

# Parse args
if [ "$1" = "--aarch64" ]; then
    ARCH="aarch64"
    shift
fi

# Check toolchain
if [ ! -x "$CC" ]; then
    echo "ERROR: Cyrius toolchain not found at $CYRIUS_HOME" >&2
    echo "Install: curl -sSf https://raw.githubusercontent.com/MacCracken/cyrius/main/scripts/install.sh | sh" >&2
    exit 1
fi

mkdir -p "$ROOT/build"

if [ "$ARCH" = "aarch64" ]; then
    if [ ! -x "$CC_ARM" ]; then
        echo "ERROR: aarch64 cross-compiler not found at $CC_ARM" >&2
        exit 1
    fi
    echo "Building AGNOS kernel [aarch64]..."
    if [ -x "$CYRB" ]; then
        PREPPED_ARM="$ROOT/build/agnos_arm.cyr"
        (echo '#define ARCH_AARCH64' && cat "$ROOT/kernel/agnos.cyr") > "$PREPPED_ARM"
        (cd "$ROOT/kernel" && "$CYRB" build --aarch64 "$PREPPED_ARM" "$ROOT/build/agnos-aarch64")
        rm -f "$PREPPED_ARM"
    else
        cat "$ROOT/kernel/agnos.cyr" | "$CC_ARM" > "$ROOT/build/agnos-aarch64"
    fi
    chmod +x "$ROOT/build/agnos-aarch64"
    SZ=$(wc -c < "$ROOT/build/agnos-aarch64")
    echo "  -> build/agnos-aarch64 ($SZ bytes)"
    echo "Boot: qemu-system-aarch64 -M virt -cpu cortex-a57 -kernel build/agnos-aarch64 -serial stdio -display none"
else
    echo "Building AGNOS kernel [x86_64]..."
    # Prepend #define so it works regardless of cyrius -D support
    PREPPED="$ROOT/build/agnos_x86.cyr"
    (echo '#define ARCH_X86_64' && cat "$ROOT/kernel/agnos.cyr") > "$PREPPED"
    if [ -x "$CYRB" ]; then
        (cd "$ROOT/kernel" && "$CYRB" build "$PREPPED" "$ROOT/build/agnos")
    else
        cat "$PREPPED" | "$CC" > "$ROOT/build/agnos"
        chmod +x "$ROOT/build/agnos"
    fi
    rm -f "$PREPPED"
    SZ=$(wc -c < "$ROOT/build/agnos")
    echo "  -> build/agnos ($SZ bytes)"

    # Validate multiboot header
    python3 -c "
import struct
with open('$ROOT/build/agnos','rb') as f: d=f.read()
mb = struct.unpack_from('<I',d,84)[0]
entry = struct.unpack_from('<I',d,24)[0]
if mb != 0x1badb002: print('WARN: bad multiboot magic'); exit(1)
if entry != 0x100060: print('WARN: bad entry point'); exit(1)
print('  multiboot: OK')
print('  entry: 0x{:x}'.format(entry))
" 2>/dev/null || echo "  (python3 not available, skipping validation)"

    echo "Boot: qemu-system-x86_64 -kernel build/agnos -serial stdio -display none"
fi
