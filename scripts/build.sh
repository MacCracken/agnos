#!/bin/sh
# Build the AGNOS kernel
# Supports: x86_64 (default), aarch64 (--aarch64)
# Requires: Cyrius toolchain (~/.cyrius/bin/cyrius)
#
# All compilation goes through `cyrius build` — we never invoke cc5
# directly. The cyrius wrapper resolves includes, manages the temp
# tree, and dispatches to cc5 / cc5_aarch64 internally.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CYRIUS_HOME="${CYRIUS_HOME:-$HOME/.cyrius}"
CYRB="$CYRIUS_HOME/bin/cyrius"
CC_ARM="$CYRIUS_HOME/bin/cc5_aarch64"
# kernel/lib/ (vendored kstring/kfmt) intentionally shadows the
# version-pinned stdlib snapshot. cyrius 5.10+ emits an info `note`
# about this on every build run; silence it since the shadow is by
# design (`--no-deps` skips the version-pinned tree anyway).
export CYRIUS_NO_WARN_SHADOW_LIB=1
echo "  toolchain: $CYRB" >&2
ARCH="x86_64"

if [ "$1" = "--aarch64" ]; then
    ARCH="aarch64"
    shift
fi

if [ ! -x "$CYRB" ]; then
    echo "ERROR: cyrius wrapper not found at $CYRB" >&2
    echo "Install: curl -sSf https://raw.githubusercontent.com/MacCracken/cyrius/main/scripts/install.sh | sh" >&2
    exit 1
fi

mkdir -p "$ROOT/build"

if [ "$ARCH" = "aarch64" ]; then
    if [ ! -x "$CC_ARM" ]; then
        echo "ERROR: aarch64 cross-compiler not in toolchain ($CC_ARM)" >&2
        exit 1
    fi
    echo "Building AGNOS kernel [aarch64]..."
    # `cyrius build -D ARCH_AARCH64` does not propagate into nested #ifdef
    # blocks reached via `include`. Workaround: prepend the define.
    PREPPED_ARM="$ROOT/build/agnos_arm.cyr"
    (echo '#define ARCH_AARCH64' && cat "$ROOT/kernel/agnos.cyr") > "$PREPPED_ARM"
    (cd "$ROOT/kernel" && "$CYRB" build --aarch64 --no-deps "$PREPPED_ARM" "$ROOT/build/agnos-aarch64")
    rm -f "$PREPPED_ARM"
    chmod +x "$ROOT/build/agnos-aarch64"
    SZ=$(wc -c < "$ROOT/build/agnos-aarch64")
    echo "  -> build/agnos-aarch64 ($SZ bytes)"
    echo "Boot: qemu-system-aarch64 -M virt -cpu cortex-a57 -kernel build/agnos-aarch64 -serial stdio -display none"
else
    echo "Building AGNOS kernel [x86_64]..."
    PREPPED="$ROOT/build/agnos_x86.cyr"
    (echo '#define ARCH_X86_64' && cat "$ROOT/kernel/agnos.cyr") > "$PREPPED"
    (cd "$ROOT/kernel" && "$CYRB" build --no-deps "$PREPPED" "$ROOT/build/agnos")
    rm -f "$PREPPED"
    SZ=$(wc -c < "$ROOT/build/agnos")
    echo "  -> build/agnos ($SZ bytes)"

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

    # `-cpu max` exposes SMEP+SMAP (set by the boot shim's CR4 OR-mask
    # 0x300020). Default qemu64 lacks both → triple fault on cr4 store.
    echo "Boot: qemu-system-x86_64 -kernel build/agnos -cpu max -serial stdio -display none"
fi
