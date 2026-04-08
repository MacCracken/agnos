#!/bin/sh
# Create GRUB-bootable AGNOS ISO
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Check for grub-mkrescue
if ! command -v grub-mkrescue >/dev/null 2>&1; then
    echo "ERROR: grub-mkrescue not found." >&2
    echo "Install it:" >&2
    echo "  Debian/Ubuntu: sudo apt install grub-pc-bin xorriso" >&2
    echo "  Arch Linux:    sudo pacman -S grub xorriso" >&2
    echo "  Fedora:        sudo dnf install grub2-tools-extra xorriso" >&2
    exit 1
fi

if ! command -v xorriso >/dev/null 2>&1; then
    echo "ERROR: xorriso not found." >&2
    echo "Install it:" >&2
    echo "  Debian/Ubuntu: sudo apt install xorriso" >&2
    echo "  Arch Linux:    sudo pacman -S xorriso" >&2
    echo "  Fedora:        sudo dnf install xorriso" >&2
    exit 1
fi

echo "Building kernel..."
sh "$ROOT/scripts/build.sh"

echo "Patching ELF for GRUB compatibility..."
cp "$ROOT/build/agnos" "$ROOT/build/agnos-grub"
python3 "$ROOT/scripts/elf-fixup.py" "$ROOT/build/agnos-grub"

echo "Creating ISO structure..."
mkdir -p "$ROOT/build/iso/boot/grub"
cp "$ROOT/build/agnos-grub" "$ROOT/build/iso/boot/agnos"
cp "$ROOT/boot/grub/grub.cfg" "$ROOT/build/iso/boot/grub/grub.cfg"

echo "Generating ISO..."
grub-mkrescue -o "$ROOT/build/agnos.iso" "$ROOT/build/iso" 2>/dev/null

SZ=$(wc -c < "$ROOT/build/agnos.iso")
echo "  -> build/agnos.iso ($SZ bytes)"
echo ""
echo "Boot: qemu-system-x86_64 -cdrom build/agnos.iso -serial stdio -display none"
echo "Real hardware: dd if=build/agnos.iso of=/dev/sdX bs=4M"

rm -rf "$ROOT/build/iso" "$ROOT/build/agnos-grub"
