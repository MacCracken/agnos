#!/usr/bin/env python3
# mk-dirty-journal-img.py — set s_start != 0 in an ext4 image's journal,
# recomputing the journal-SB CRC32C if FEATURE_INCOMPAT_CSUM_V2/V3 is set.
# Optional --synth-tx mode synthesizes a one-transaction journal at log
# blocks [1, 2, 3] (descriptor + data + commit) so 1.38.2's log walker
# has real content to parse + 1.38.3's replay has a real tx to apply.
#
# Used by scripts/jbd2-refusal-smoke.sh (parse mode, just s_start != 0)
# and scripts/jbd2-logdump-smoke.sh (--synth-tx, a fully-formed dirty
# journal). Produces an image that on-disk looks "as if a transaction
# committed but a crash hit before checkpoint completed" — replay-able
# by Linux's jbd2.
#
# Usage:
#   mk-dirty-journal-img.py <image> <partition_offset> [s_start]
#   mk-dirty-journal-img.py <image> <partition_offset> --synth-tx [target_fs_block]
#
# Exits 0 on success, nonzero on parse failure.

import struct, sys

CRC32C_POLY_REV = 0x82F63B78  # Castagnoli reflected


def crc32c(data, seed=0xFFFFFFFF):
    crc = seed
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ CRC32C_POLY_REV if (crc & 1) else (crc >> 1)
    return crc & 0xFFFFFFFF


def write_synthetic_transaction(f, part_off, jfp, bs, has_64bit, target_blk, seq, data_source="block", csum_seed=None):
    """Synthesize a one-transaction journal at log blocks [1, 2, 3].

    Layout:
      jfp+1 = descriptor block (one LAST_TAG tag for target_blk, UUID = zero)
      jfp+2 = data block (content depends on data_source: "block" reads
              target_blk's current FS content so replay is a no-op write;
              "fill" uses 0xCC pattern — replay corrupts target_blk, useful
              for negative tests)
      jfp+3 = commit block

    When csum_seed is not None the journal is CSUM_V3: the descriptor uses the
    16-byte journal_block_tag3_t layout (t_flags be32@+4, t_blocknr_high@+8,
    t_checksum@+12), carries a 4-byte tail csum at bs-4, and the commit block
    carries h_chksum[0]. All per fs/jbd2/commit.c — see ext4-jbd2-prior-art.md §8.
    """
    uuid = b"\x00" * 16
    is_v3 = csum_seed is not None

    # Read the data first (the tag data csum covers it).
    if data_source == "block":
        f.seek(part_off + target_blk * bs)
        data = f.read(bs)
        if len(data) < bs:
            data = data + b"\x00" * (bs - len(data))
    else:
        data = b"\xCC" * bs

    # === Descriptor at jfp+1 ===
    desc = bytearray(bs)
    struct.pack_into(">I", desc, 0, 0xC03B3998)   # magic
    struct.pack_into(">I", desc, 4, 1)            # blocktype = DESCRIPTOR
    struct.pack_into(">I", desc, 8, seq)          # transaction sequence
    tag_off = 12
    if is_v3:
        data_csum = crc32c(data, crc32c(struct.pack(">I", seq), csum_seed))
        struct.pack_into(">I", desc, tag_off,      target_blk & 0xFFFFFFFF)
        struct.pack_into(">I", desc, tag_off + 4,  0x08)                       # t_flags LAST_TAG (be32)
        struct.pack_into(">I", desc, tag_off + 8,  (target_blk >> 32) & 0xFFFFFFFF)  # t_blocknr_high
        struct.pack_into(">I", desc, tag_off + 12, data_csum)                  # t_checksum (full 32-bit)
        desc[tag_off + 16 : tag_off + 32] = uuid                              # first-tag UUID
        # descriptor tail csum at bs-4
        struct.pack_into(">I", desc, bs - 4, 0)
        struct.pack_into(">I", desc, bs - 4, crc32c(bytes(desc), csum_seed))
    else:
        struct.pack_into(">I", desc, tag_off,       target_blk & 0xFFFFFFFF)
        struct.pack_into(">H", desc, tag_off + 4,   0)      # t_checksum (legacy @ +4)
        struct.pack_into(">H", desc, tag_off + 6,   0x08)   # t_flags = LAST_TAG (legacy @ +6)
        pos = tag_off + 8
        if has_64bit:
            struct.pack_into(">I", desc, pos, (target_blk >> 32) & 0xFFFFFFFF)
            pos += 4
        desc[pos : pos + 16] = uuid                       # first-tag UUID
    f.seek(part_off + (jfp + 1) * bs); f.write(desc)

    # === Data at jfp+2 === (already read above; "block" mode = no-op replay,
    # so e2fsck stays clean. ESCAPE — first 4 bytes == JBD2 magic — is not
    # handled here; a high target_blk in a fresh mkfs.ext4 never collides.)
    f.seek(part_off + (jfp + 2) * bs); f.write(data)

    # === Commit at jfp+3 ===
    commit = bytearray(bs)
    struct.pack_into(">I", commit, 0, 0xC03B3998)
    struct.pack_into(">I", commit, 4, 2)          # blocktype = COMMIT
    struct.pack_into(">I", commit, 8, seq)
    if is_v3:
        # CSUM_V2/V3 commit csum: type/size = 0, h_chksum[0] @ +0x10 = crc32c
        # over the whole block with that field zeroed (jbd2_commit_block_csum_set).
        commit[12] = 0; commit[13] = 0
        struct.pack_into(">I", commit, 16, 0)
        struct.pack_into(">I", commit, 16, crc32c(bytes(commit), csum_seed))
    # else h_chksum_type at +12 stays 0 (no V1 csum); h_commit_sec / nsec stay 0
    f.seek(part_off + (jfp + 3) * bs); f.write(commit)

    return target_blk


def main():
    if len(sys.argv) < 3:
        print("usage: mk-dirty-journal-img.py <image> <partition_offset> [s_start | --synth-tx [target_blk]] [--csum-v3]", file=sys.stderr)
        sys.exit(1)

    img = sys.argv[1]
    part_off = int(sys.argv[2])
    synth_tx = False
    target_blk = 100
    new_start = 1
    # --csum-v3: upgrade the journal to JBD2 CSUM_V3 + 64BIT (incompat 0x12,
    # csum_type=4) — mirrors what the Linux kernel stamps on the first RW mount
    # of a metadata_csum FS. Lets the smokes match the archaemenid iron journal.
    # Standalone (clean upgrade) or combined with --synth-tx (dirty V3 tx).
    upgrade_v3 = "--csum-v3" in sys.argv
    rest = [a for a in sys.argv[3:] if a != "--csum-v3"]
    if rest:
        if rest[0] == "--synth-tx":
            synth_tx = True
            if len(rest) > 1:
                target_blk = int(rest[1])
        else:
            new_start = int(rest[0])
    elif not upgrade_v3:
        new_start = 1   # legacy default when no flags at all

    with open(img, "r+b") as f:
        # === 1. FS superblock at partition_offset + 1024 ===
        f.seek(part_off + 1024)
        sb = f.read(1024)
        log_bs = struct.unpack_from("<I", sb, 24)[0]
        bs = 1024 << log_bs
        first_data_block = struct.unpack_from("<I", sb, 20)[0]
        blocks_per_group = struct.unpack_from("<I", sb, 32)[0]
        inodes_per_group = struct.unpack_from("<I", sb, 40)[0]
        inode_size = struct.unpack_from("<H", sb, 88)[0] or 128
        j_inum = struct.unpack_from("<I", sb, 224)[0]
        feature_incompat = struct.unpack_from("<I", sb, 96)[0]
        desc_size = struct.unpack_from("<H", sb, 254)[0] or 32
        is_64bit = bool(feature_incompat & 0x80)

        if j_inum == 0:
            print("no journal inode (s_journal_inum=0)", file=sys.stderr)
            sys.exit(2)

        # === 2. Resolve the journal inode's first data block ===
        j_index = j_inum - 1
        j_group = j_index // inodes_per_group
        j_idx_in_group = j_index % inodes_per_group

        bgdt_block = first_data_block + 1
        bgdt_off = part_off + bgdt_block * bs + j_group * desc_size
        f.seek(bgdt_off)
        bgdt = f.read(desc_size)
        inode_table_lo = struct.unpack_from("<I", bgdt, 8)[0]
        inode_table_hi = struct.unpack_from("<I", bgdt, 32)[0] if (is_64bit and desc_size >= 64) else 0
        inode_table_block = (inode_table_hi << 32) | inode_table_lo

        inode_off = part_off + inode_table_block * bs + j_idx_in_group * inode_size
        f.seek(inode_off)
        inode = f.read(inode_size)

        flags = struct.unpack_from("<I", inode, 32)[0]
        if flags & 0x80000:  # EXTENTS_FL — parse inline extent at offset 40
            eh_magic = struct.unpack_from("<H", inode, 40)[0]
            if eh_magic != 0xF30A:
                print(f"journal inode: bad extent header magic 0x{eh_magic:x}", file=sys.stderr)
                sys.exit(2)
            eh_depth = struct.unpack_from("<H", inode, 46)[0]
            if eh_depth != 0:
                print(f"journal extent depth > 0 (eh_depth={eh_depth}) -- not supported", file=sys.stderr)
                sys.exit(2)
            ee_block = struct.unpack_from("<I", inode, 52)[0]
            ee_start_hi = struct.unpack_from("<H", inode, 58)[0]
            ee_start_lo = struct.unpack_from("<I", inode, 60)[0]
            if ee_block != 0:
                print(f"journal first extent ee_block={ee_block} != 0", file=sys.stderr)
                sys.exit(2)
            first_phys = (ee_start_hi << 32) | ee_start_lo
        else:
            first_phys = struct.unpack_from("<I", inode, 40)[0]

        # === 3. Read the journal SB (first 1024 bytes of journal block 0) ===
        jsb_byte_off = part_off + first_phys * bs
        f.seek(jsb_byte_off)
        jsb = bytearray(f.read(1024))

        jmagic = struct.unpack_from(">I", jsb, 0)[0]
        if jmagic != 0xC03B3998:
            print(f"journal SB bad magic 0x{jmagic:08x}", file=sys.stderr)
            sys.exit(2)
        j_incompat = struct.unpack_from(">I", jsb, 40)[0]

        # === Optional CSUM_V3 + 64BIT upgrade (mirrors Linux first-RW-mount) ===
        if upgrade_v3:
            j_incompat |= 0x12                       # 64BIT (0x02) | CSUM_V3 (0x10)
            struct.pack_into(">I", jsb, 40, j_incompat)
            jsb[80] = 4                              # s_checksum_type = CRC32C
        has_64bit = bool(j_incompat & 0x02)
        is_v3 = bool(j_incompat & 0x10)
        # j_csum_seed = crc32c(~0, journal s_uuid[16] @ +0x30) — only meaningful
        # when csum_v2/v3 is set; passed to synth so its tags/commit are valid.
        csum_seed = crc32c(bytes(jsb[0x30:0x40])) if (j_incompat & 0x18) else None

        # Whether to advance s_start. A pure --csum-v3 clean upgrade leaves the
        # journal clean (s_start untouched); dirty/synth modes set it.
        write_start = synth_tx or bool(rest and rest[0] != "--synth-tx")

        # === 4a. (Optional) synthesize a one-transaction journal ===
        if synth_tx:
            seq = struct.unpack_from(">I", jsb, 24)[0] or 1   # next-expected seq
            write_synthetic_transaction(f, part_off, first_phys, bs, has_64bit, target_blk, seq, csum_seed=csum_seed)
            new_start = 1   # journal head now points at the descriptor we just wrote

        # === 4. Set s_start = new_start (offset 28, BE u32) when in a dirty mode ===
        if write_start:
            struct.pack_into(">I", jsb, 28, new_start)

        # === 5. Recompute SB CSUM if CSUM_V2 (0x8) or CSUM_V3 (0x10) is set ===
        CSUM_V2_V3 = 0x18
        if j_incompat & CSUM_V2_V3:
            # crc32c over the SB with s_checksum (offset 252) zeroed.
            saved = struct.unpack_from(">I", jsb, 252)[0]
            struct.pack_into(">I", jsb, 252, 0)
            new_csum = crc32c(bytes(jsb))
            struct.pack_into(">I", jsb, 252, new_csum)
            csum_note = f", new csum=0x{new_csum:08x} (was 0x{saved:08x})"
        else:
            csum_note = " (no SB csum to recompute)"

        # === 6. Write the modified SB back ===
        f.seek(jsb_byte_off)
        f.write(jsb)

    print(f"journal inode: {j_inum}")
    print(f"journal first block: {first_phys}  (byte offset 0x{first_phys * bs:x} within partition)")
    if upgrade_v3:
        print(f"upgraded journal to CSUM_V3 + 64BIT (incompat=0x{j_incompat:08x}, csum_type=4, seed=0x{csum_seed:08x})")
    if synth_tx:
        kind = "V3" if is_v3 else "legacy"
        print(f"synthesized 1-tx {kind} journal: target FS block {target_blk}")
    if write_start:
        print(f"s_start written: {new_start} at image byte 0x{jsb_byte_off + 28:x}{csum_note}")
    else:
        print(f"journal left clean (s_start unchanged){csum_note}")


if __name__ == "__main__":
    main()
