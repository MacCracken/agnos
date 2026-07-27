#!/usr/bin/env python3
"""Patch aarch64 kernel ELF to set up SP before Cyrius entry.

The Cyrius aarch64 compiler doesn't emit stack setup for kernel mode.
This script appends a small trampoline (movz x9, #0x4080, lsl #16;
mov sp, x9; b original_target) and patches the initial branch to
go through the trampoline first.
"""
import struct, sys

if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <input.elf> <output.elf>")
    sys.exit(1)

with open(sys.argv[1], 'rb') as f:
    d = bytearray(f.read())

# Entry at file offset 0x78 (ELF entry = 0x40000078)
orig = struct.unpack_from('<I', d, 0x78)[0]
imm26 = orig & 0x3FFFFFF
# +4: aarch64 compiler has off-by-one in kernel entry (lands on trailing ret)
target_off = 0x78 + imm26 * 4 + 4

# Append trampoline
end = len(d)
d += struct.pack('<I', 0xD2A81009)  # movz x9, #0x4080, lsl #16 (SP = 0x40800000)
d += struct.pack('<I', 0x9100013F)  # mov sp, x9
back = (target_off - (end + 8)) // 4
d += struct.pack('<I', 0x14000000 | (back & 0x3FFFFFF))  # b original_target

# Patch initial branch to trampoline
fwd = (end - 0x78) // 4
struct.pack_into('<I', d, 0x78, 0x14000000 | (fwd & 0x3FFFFFF))

# Update ELF segment sizes
ph_off = struct.unpack_from('<Q', d, 0x20)[0]
struct.pack_into('<Q', d, ph_off + 0x20, len(d))
struct.pack_into('<Q', d, ph_off + 0x28, len(d))

import os
# Debug
print(f"  original branch imm26={imm26} target_file_off=0x{target_off:x}", file=os.sys.stderr)
print(f"  trampoline at file_off=0x{end:x} back_offset={back} instructions", file=os.sys.stderr)
fwd_check = fwd
print(f"  initial branch fwd={fwd_check} instructions", file=os.sys.stderr)

with open(sys.argv[2], 'wb') as f:
    f.write(d)
print(f"  aarch64 SP patch: {len(d)} bytes")
