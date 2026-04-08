#!/usr/bin/env python3
"""Add minimal ELF section header table for GRUB compatibility.

The Cyrius compiler emits a valid multiboot1 ELF32 with program headers
but no section headers (e_shoff=0, e_shnum=0). QEMU's -kernel flag loads
via program headers and works fine, but GRUB's multiboot loader also
parses section headers and rejects ELFs with e_shoff=0.

Fix: append a single null section header (SHN_UNDEF) to the end of the
file and update the ELF header fields. This satisfies GRUB without
changing the kernel's load address or entry point.
"""
import struct
import sys

def fixup(path):
    with open(path, 'rb') as f:
        data = bytearray(f.read())

    # Verify ELF32
    if data[:4] != b'\x7fELF':
        print(f"ERROR: {path} is not an ELF file", file=sys.stderr)
        return 1
    if data[4] != 1:
        print(f"ERROR: {path} is not ELF32", file=sys.stderr)
        return 1

    # Check if section headers already present
    e_shoff = struct.unpack_from('<I', data, 32)[0]
    if e_shoff != 0:
        # Already has section headers, nothing to do
        return 0

    shentsize = 40  # sizeof(Elf32_Shdr)
    shoff = len(data)

    # Append one null section header (SHN_UNDEF)
    data.extend(b'\x00' * shentsize)

    # Update ELF header
    struct.pack_into('<I', data, 32, shoff)      # e_shoff
    struct.pack_into('<H', data, 46, shentsize)   # e_shentsize
    struct.pack_into('<H', data, 48, 1)           # e_shnum
    struct.pack_into('<H', data, 50, 0)           # e_shstrndx

    with open(path, 'wb') as f:
        f.write(data)

    return 0

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <elf-file>", file=sys.stderr)
        sys.exit(1)
    sys.exit(fixup(sys.argv[1]))
