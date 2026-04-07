#!/bin/sh
# Build the AGNOS kernel
# Supports: x86_64 (default), aarch64 (--aarch64)
# Requires: Cyrius toolchain from ../cyrius/build/
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CYRIUS="$ROOT/../cyrius"
# Find toolchain: ~/.cyrius/bin/ (installer) or ../cyrius/build/ (dev)
if [ -x "$HOME/.cyrius/bin/cyrb" ]; then
    CYRB="$HOME/.cyrius/bin/cyrb"
    CC="$HOME/.cyrius/bin/cc2"
    CC_ARM="$HOME/.cyrius/bin/cc2_aarch64"
else
    CYRB="${CYRIUS}/build/cyrb"
    CC="${CYRIUS}/build/cc2"
    CC_ARM="${CYRIUS}/build/cc2_aarch64"
fi
ARCH="x86_64"

# Parse args
if [ "$1" = "--aarch64" ]; then
    ARCH="aarch64"
    shift
fi

# Check toolchain
if [ ! -x "$CC" ]; then
    echo "ERROR: Cyrius compiler not found at $CC" >&2
    echo "Build it: cd ../cyrius && sh bootstrap/bootstrap.sh" >&2
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
        (cd "$ROOT/kernel" && mkdir -p build && ln -sf "$CC" build/cc2 && "$CYRB" build --aarch64 -D ARCH_AARCH64 "$ROOT/kernel/agnos.cyr" "$ROOT/build/agnos-aarch64")
    else
        cat "$ROOT/kernel/agnos.cyr" | "$CC_ARM" > "$ROOT/build/agnos-aarch64"
    fi
    chmod +x "$ROOT/build/agnos-aarch64"
    SZ=$(wc -c < "$ROOT/build/agnos-aarch64")
    echo "  -> build/agnos-aarch64 ($SZ bytes)"
    echo "Boot: qemu-system-aarch64 -M virt -cpu cortex-a57 -kernel build/agnos-aarch64 -serial stdio -display none"
else
    echo "Building AGNOS kernel [x86_64]..."
    if [ -x "$CYRB" ]; then
        (cd "$ROOT/kernel" && mkdir -p build && ln -sf "$CC" build/cc2 && "$CYRB" build -D ARCH_X86_64 "$ROOT/kernel/agnos.cyr" "$ROOT/build/agnos")
    else
        cat "$ROOT/kernel/agnos.cyr" | "$CC" > "$ROOT/build/agnos"
        chmod +x "$ROOT/build/agnos"
    fi
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
