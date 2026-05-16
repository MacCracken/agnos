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
    # ELF64 multiboot2 emit (cyrius 5.11.43+). Routes through
    # EMITELF64_KERNEL: ELF64 header + multiboot2 + EFI64-entry tag.
    # GRUB-EFI hands off in long mode without long-mode-exit, so the
    # kernel must be 64-bit code. Diagnosis + plan in
    # agnosticos/docs/development/iron-nuc-zen-log.md § Diagnosis
    # 2026-05-13 and path-a-elf64-multiboot2.md.
    export CYRIUS_ELF64_KERNEL=1
    PREPPED="$ROOT/build/agnos_x86.cyr"
    # `#define ELF64_KERNEL` is the *source-side* gate (kernel shim selects
    # 64-bit entry under `#ifdef ELF64_KERNEL`); `CYRIUS_ELF64_KERNEL=1`
    # above is the *cyrius-backend* gate (selects EMITELF64_KERNEL emit
    # path). Both must be set in lockstep. Prepended rather than `-D`'d
    # because `-D` doesn't propagate into included files (cyrius caveat
    # — same reason `ARCH_X86_64` is prepended, not `-D`'d).
    (echo '#define ARCH_X86_64' && echo '#define ELF64_KERNEL' && cat "$ROOT/kernel/agnos.cyr") > "$PREPPED"
    (cd "$ROOT/kernel" && "$CYRB" build --no-deps "$PREPPED" "$ROOT/build/agnos")
    rm -f "$PREPPED"
    SZ=$(wc -c < "$ROOT/build/agnos")
    echo "  -> build/agnos ($SZ bytes)"

    # Validate. EI_CLASS at byte 4: 1=ELF32 (legacy multiboot1 path),
    # 2=ELF64 (multiboot2 + EFI64). Multiboot header position differs:
    # ELF32 file offset 84 (after 52+32 = ELF32+PH32), ELF64 file offset
    # 120 (after 64+56 = ELF64+PH64). Entry is e_entry low 32 bits in
    # both classes — ELF32 e_entry is u32 at offset 24; ELF64 e_entry
    # is u64 at offset 24, low half also at offset 24.
    python3 -c "
import struct
with open('$ROOT/build/agnos','rb') as f: d=f.read()
eic = d[4]
if eic == 1:
    mb_off, exp_mb, exp_entry, label = 84, 0x1badb002, 0x100060, 'multiboot1 (ELF32)'
elif eic == 2:
    mb_off, exp_mb, exp_entry, label = 120, 0xe85250d6, 0x1000a8, 'multiboot2 (ELF64)'
else:
    print('WARN: unknown EI_CLASS'); exit(1)
mb = struct.unpack_from('<I',d,mb_off)[0]
entry = struct.unpack_from('<I',d,24)[0]
if mb != exp_mb: print('WARN: bad multiboot magic (got 0x{:x} at file offset {}, expected 0x{:x})'.format(mb, mb_off, exp_mb)); exit(1)
if entry != exp_entry: print('WARN: bad entry point (got 0x{:x}, expected 0x{:x})'.format(entry, exp_entry)); exit(1)
print('  ' + label + ': OK')
print('  entry: 0x{:x}'.format(entry))
" 2>/dev/null || echo "  (python3 not available, skipping validation)"

    # ELF64 build: kernel will not run yet. The bytes at the entry
    # point are still 32-bit-protected-mode Cyrius output; GRUB-EFI
    # delivers a long-mode CPU; first instruction decodes as 64-bit
    # → triple-fault. Shim rewrite (Path A step 5) is the prereq for
    # a bootable kernel. QEMU `-kernel -cpu max` (Linux-protocol entry,
    # delivers 32-bit-protected-mode) still won't run an ELF64 binary.
    # The UEFI emulation path is QEMU `-bios OVMF.fd` + boot from
    # disk image (see path-a-elf64-multiboot2.md § Test plan).
    echo "Boot: pending shim rewrite — see agnosticos/docs/development/path-a-elf64-multiboot2.md"
fi
