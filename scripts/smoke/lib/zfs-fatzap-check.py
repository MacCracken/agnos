#!/usr/bin/env python3
# zfs-fatzap-check — every ZAP of a pool image held to the fat-ZAP structure rules (agnos 1.57.12 bite B8; design
# docs/development/proposals/2026-10-09-zfs-write.md § f.2, § i.2 h9): what zdb never checks whole and OpenZFS ASSERTs
# only on the paths it happens to take. Every ZAP object — every dataset's (directories, the master node, SA REGISTRY /
# LAYOUTS, the DELETE_QUEUE, the user / group / project-used objects) and the MOS's — read through the image tool
# (scripts/tool/zfs-damage.py via zfs-hole-check.py's Img), dirty-nothing, with scripts/check/zfs-fatzap.py's Leaf:
#   · a FAT ZAP's header: ZBT_HEADER, ZAP_MAGIC, zap_flags 0 on everything the writer may touch (reported otherwise),
#     zt_shift in range, zap_freeblk past every block it names
#   · its POINTER TABLE (embedded while zt_blk is 0, else zt_numblks blocks at zt_blk): every entry names a leaf below
#     zap_freeblk whose prefix it is (idx >> (zt_shift - lh_prefix_len) == lh_prefix), each leaf owning exactly its one
#     range of 2^(zt_shift - lh_prefix_len) entries (zap.c:703-705 — so a split that left an entry on the OLD leaf, or a
#     wrong prefix after one, shows), zap_num_leafs == the leaves named; MID-DOUBLING (zt_nextblk): every entry of the new
#     table already written (both halves of a copied block, zap_table_store's dual writes) == the old entry it doubles
#   · every LEAF: ZBT_LEAF, its magic, lh_pad1 0, lh_nfree == its FREE chunks == its free list (walked, no cycle), each
#     FREE chunk's 21 pad bytes zero; lh_nentries == its ENTRY chunks; every entry in exactly ONE hash chain — the bucket
#     LEAF_HASH of its hash — chains in non-decreasing cd (zap_leaf_rehash_entry); its hash's top lh_prefix_len bits the
#     leaf's prefix; its name and value arrays ARRAY chunks owned by it alone, the name NUL-terminated at its length and
#     its 28-bit hash recomputed from it (the salt; ASCII case-folded under U8_TEXTPREP_TOUPPER) == le_hash; no ARRAY chunk
#     nobody owns
#   · zap_num_entries == Σ lh_nentries (sa_setup and zap_count rely on it); (hash, cd) unique across the ZAP
#   · a MICROZAP: (28-bit hash, cd) unique among its entries, every name NUL-terminated within its 50 bytes
#   · every ZAP's SALT non-zero (zap_hash ASSERTs it; mzap_create_impl ORs 1 into it, makefs asserts it) and, given the
#     PRISTINE image, a ZAP that was a microzap there and is fat now carries the microzap's salt (fzap_upgrade copies
#     zap_salt) — judged for the objects nothing re-creates (the MOS's, the user / group / project-used ZAPs) and for a
#     dataset object still holding one of the microzap's (name, value) entries (a writer that freed the object and made a
#     new ZAP at its number holds none of them)
# usage: zfs-fatzap-check.py IMG [PRISTINE]   (pool-only images)   Exit 0 every rule holds · 1 a broken one (named) · 2 unusable
import importlib.util, os, struct, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
ZAPTYPES = {1, 13, 14, 15, 20, 21, 22, 24, 27, 28, 31, 32, 37, 38, 39, 40, 41, 42, 43, 45, 46, 47, 48, 50, 52}


def load(name, rel):
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, rel))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


FZ = load("zfs_fatzap", "scripts/check/zfs-fatzap.py")
u16, u32, u64 = FZ.u16, FZ.u32, FZ.u64


def is_zap(ty):
    return ty in ZAPTYPES or ((ty & 0x80) and (ty & 0x1F) == 4)


def hash_of(salt, nf, name):
    if nf:
        if any(c >= 128 for c in name):
            return None
        if nf & 2:
            name = name.upper()
    return FZ.zap_hash(salt, name)


def check_micro(b, bad):
    seen = set()
    salt, nf = u64(b, 8), u64(b, 16)
    if salt == 0:
        bad.append("microzap salt 0 (zap_hash ASSERTs a non-zero salt)")
    n = 0
    for k in range(64, len(b), 64):
        if b[k + 14] == 0:
            continue
        nm = bytes(b[k + 14:k + 64])
        if 0 not in nm:
            bad.append("a microzap entry's name is not NUL-terminated within 50 bytes (chunk %d)" % (k // 64 - 1))
            continue
        nm = nm.split(b"\0")[0]
        h = hash_of(salt, nf, nm)
        key = (h, u32(b, k + 8))
        if h is not None and key in seen:
            bad.append("microzap: two entries with hash %#x cd %d (%r)" % (h, key[1], nm))
        seen.add(key)
        n += 1
    return n


def check_fat(blocks, bs, bad, st):
    hdr = blocks.get(0)
    bsz = 1 << bs
    if u64(hdr, 0) != FZ.ZBT_HEADER or u64(hdr, 8) != FZ.ZAP_MAGIC:
        bad.append("block 0 is not a fat-ZAP header")
        return
    zblk, znb, zsh, znext, zcop = (u64(hdr, o) for o in (16, 24, 32, 40, 48))
    freeblk, nleafs, nent, salt, nf, flags = (u64(hdr, o) for o in (56, 64, 72, 80, 88, 96))
    if flags:
        st["flags"] += 1
        return                                         # HASH64 / UINT64_KEY / PRE_HASHED: not the writer's; not judged
    if salt == 0:
        bad.append("fat-ZAP salt 0 (zap_hash ASSERTs a non-zero salt; fzap_upgrade copies the microzap's)")
    if not 1 <= zsh <= 26:
        bad.append("zt_shift %d" % zsh)
        return
    epb = bsz // 8
    blk = lambda k: blocks.get(k, bytes(bsz))

    def idx2blk(i):
        if znb == 0:
            return u64(hdr, bsz // 2 + 8 * i)
        return u64(blk(zblk + i // epb), 8 * (i % epb))
    if znb == 0 and (zblk != 0 or zsh != bs - 4):
        bad.append("embedded pointer table with zt_blk %d / zt_shift %d (want 0 / %d)" % (zblk, zsh, bs - 4))
        return
    if znb and (1 << zsh) != znb * epb:
        bad.append("external pointer table: 2^%d entries in %d block(s) of %d" % (zsh, znb, epb))
        return
    if znb and zblk + znb > freeblk:
        bad.append("pointer table blocks [%d, %d) past zap_freeblk %d" % (zblk, zblk + znb, freeblk))
    if znext:
        st["midgrow"] += 1
        if znb == 0 or znext + 2 * znb > freeblk or zcop >= znb:
            bad.append("mid-doubling table: nextblk %d, %d of %d copied, freeblk %d" % (znext, zcop, znb, freeblk))
        else:
            for i in range(1 << zsh):
                b2 = blk(znext + (2 * i) // epb)
                a, c = u64(b2, 8 * ((2 * i) % epb)), u64(b2, 8 * ((2 * i) % epb + 1))
                copied = i // epb < zcop
                if (copied or a or c) and not (a == c == idx2blk(i)):
                    bad.append("mid-doubling table: new entries %d / %d = %d / %d, the old entry %d is %d" % (2 * i, 2 * i + 1, a, c, i, idx2blk(i)))
                    break
    owners = {}
    for i in range(1 << zsh):
        lb = idx2blk(i)
        owners.setdefault(lb, []).append(i)
    tot, seen = 0, {}
    for lb, ids in sorted(owners.items()):
        if not 1 <= lb < freeblk or lb not in blocks:
            bad.append("pointer-table entries %d.. name block %d (freeblk %d, or a hole)" % (ids[0], lb, freeblk))
            continue
        lf = FZ.Leaf(bytearray(blocks[lb]), bs)
        b = lf.b
        if u64(b, 0) != FZ.ZBT_LEAF or u32(b, 24) != FZ.LEAF_MAGIC or u64(b, 8) != 0:
            bad.append("block %d is not a leaf" % lb)
            continue
        plen, pref = lf.plen(), lf.prefix()
        want = list(range(pref << (zsh - plen), (pref + 1) << (zsh - plen))) if plen <= zsh else None
        if want != ids:
            bad.append("leaf %d (prefix %#x / %d) owns table entries %d..%d (%d), its prefix says %s" %
                       (lb, pref, plen, ids[0], ids[-1], len(ids), "%d..%d" % (want[0], want[-1]) if want else "nothing"))
        # chunks: FREE ones and the free list, ENTRY ones and their arrays
        free = {c for c in range(lf.nc) if b[lf.ch(c)] == FZ.T_FREE}
        if lf.nfree() != len(free):
            bad.append("leaf %d: lh_nfree %d, %d FREE chunks" % (lb, lf.nfree(), len(free)))
        walked, c = set(), u16(b, 34)
        while c != FZ.CHAIN_END and len(walked) <= lf.nc:
            if c >= lf.nc or c in walked:
                bad.append("leaf %d: the free list reaches chunk %d twice or past the chunks" % (lb, c))
                break
            walked.add(c)
            c = u16(b, lf.ch(c) + 22)
        if walked != free:
            bad.append("leaf %d: the free list holds %d chunk(s), %d are FREE" % (lb, len(walked), len(free)))
        for c in free:
            if any(b[lf.ch(c) + 1:lf.ch(c) + 22]):
                bad.append("leaf %d: FREE chunk %d's pad is not zero" % (lb, c))
                break
        ents = [c for c in range(lf.nc) if b[lf.ch(c)] == FZ.T_ENTRY]
        if lf.nent() != len(ents):
            bad.append("leaf %d: lh_nentries %d, %d ENTRY chunks" % (lb, lf.nent(), len(ents)))
        tot += lf.nent()
        chained = {}
        for bk in range(lf.nh):
            c, prev_cd, n = u16(b, 48 + 2 * bk), -1, 0
            while c != FZ.CHAIN_END:
                if c >= lf.nc or b[lf.ch(c)] != FZ.T_ENTRY or c in chained or n > lf.nc:
                    bad.append("leaf %d bucket %d: chain reaches chunk %d (not an entry, or twice)" % (lb, bk, c))
                    break
                o = lf.ch(c)
                if lf.hoff(u64(b, o + 16)) != 48 + 2 * bk:
                    bad.append("leaf %d: entry chunk %d (hash %#x) chained in bucket %d" % (lb, c, u64(b, o + 16), bk))
                if u32(b, o + 12) < prev_cd:
                    bad.append("leaf %d bucket %d: cd %d after %d (chains keep cd order)" % (lb, bk, u32(b, o + 12), prev_cd))
                prev_cd = u32(b, o + 12)
                chained[c] = bk
                c, n = u16(b, o + 2), n + 1
        owned = set()
        for c in ents:
            o = lf.ch(c)
            h, cd = u64(b, o + 16), u32(b, o + 12)
            if c not in chained:
                bad.append("leaf %d: entry chunk %d is in no hash chain" % (lb, c))
            if (h >> (64 - plen) if plen else 0) != pref:
                bad.append("leaf %d (prefix %#x / %d): entry hash %#x is not its" % (lb, pref, plen, h))
            arrs = []
            for first, nbytes in ((u16(b, o + 4), u16(b, o + 6)), (u16(b, o + 8), u16(b, o + 10) * b[o + 1])):
                cc, data, ok = first, bytearray(), True
                while len(data) < nbytes:
                    if cc >= lf.nc or b[lf.ch(cc)] != FZ.T_ARRAY or cc in owned:
                        bad.append("leaf %d: entry chunk %d's array reaches chunk %d (not an array, or shared)" % (lb, c, cc))
                        ok = False
                        break
                    owned.add(cc)
                    data += b[lf.ch(cc) + 1:lf.ch(cc) + 22]
                    cc = u16(b, lf.ch(cc) + 22)
                if ok and cc != FZ.CHAIN_END:
                    bad.append("leaf %d: entry chunk %d's array runs on past its length" % (lb, c))
                arrs.append(bytes(data[:nbytes]))
            name = arrs[0]
            if not name or name[-1] != 0 or 0 in name[:-1]:
                bad.append("leaf %d: entry chunk %d's name is not one NUL-terminated string" % (lb, c))
                continue
            hh = hash_of(salt, nf, name[:-1])
            if hh is not None and hh != h:
                bad.append("leaf %d: entry %r hash %#x, its name hashes to %#x" % (lb, name[:-1], h, hh))
            if (h, cd) in seen:
                bad.append("two entries with hash %#x cd %d (%r, %r)" % (h, cd, seen[(h, cd)], name[:-1]))
            seen[(h, cd)] = name[:-1]
            st["names"][name[:-1]] = arrs[1]
        stray = {c for c in range(lf.nc) if b[lf.ch(c)] == FZ.T_ARRAY} - owned
        if stray:
            bad.append("leaf %d: %d ARRAY chunk(s) no entry owns (first %d)" % (lb, len(stray), min(stray)))
        st["leaves"] += 1
        st["empty"] += lf.nent() == 0
    if len(owners) != nleafs:
        bad.append("zap_num_leafs %d, the table names %d leaves" % (nleafs, len(owners)))
    if tot != nent:
        bad.append("zap_num_entries %d, the leaves hold %d" % (nent, tot))
    st["entries"] += tot
    st["external"] += znb != 0


def zap_blocks(img, dn):
    blocks = dict(img.l0s(dn))
    return blocks


def all_dnodes(img):
    """[(set name, {object: dnode})] — the MOS and every head dataset, the user / group / project-used objects as -1..-3."""
    sets = [("MOS", img.mos.content)]
    for name, dsphys in sorted(img.heads().items()):
        osc = img.objset(dsphys)
        if osc is not None:
            sets.append((name, osc))
    out = []
    for name, osc in sets:
        dns = dict(img.dnodes(osc))
        if name != "MOS" and len(osc) >= 2048:
            for k, off in ((-1, 1024), (-2, 1536), (-3, 2048)):
                if off + 512 <= len(osc) and osc[off] != 0:
                    dns[k] = bytes(osc[off:off + 512])
        out.append((name, dns))
    return out


def micro_salts(img):
    """{(set, object): (salt, {name: value bytes BE})} of every MICROZAP of the image."""
    out = {}
    for name, dns in all_dnodes(img):
        for obj, dn in dns.items():
            if not is_zap(dn[0]):
                continue
            b0 = dict(img.l0s(dn)).get(0)
            if b0 is None or u64(b0, 0) != FZ.ZBT_MICRO:
                continue
            ents = {}
            for k in range(64, len(b0), 64):
                if b0[k + 14] and 0 in b0[k + 14:k + 64]:
                    ents[bytes(b0[k + 14:k + 64]).split(b"\0")[0]] = struct.pack(">Q", u64(b0, k))
            out[(name, obj)] = (u64(b0, 8), ents)
    return out


def main(argv):
    if len(argv) not in (2, 3) or not all(os.path.isfile(a) for a in argv[1:]):
        print("usage: zfs-fatzap-check.py IMG [PRISTINE]")
        return 2
    hc = load("zfsholes", "scripts/smoke/lib/zfs-hole-check.py")
    z = hc.load_lib()
    try:
        img = hc.Img(z, argv[1])
        pm = micro_salts(hc.Img(z, argv[2])) if len(argv) == 3 else {}
    except (z.ToolError, KeyError, ValueError, struct.error) as e:
        print("fatzap: unusable image: %s" % e)
        return 2
    fails = []
    st = {"micro": 0, "fat": 0, "leaves": 0, "entries": 0, "empty": 0, "external": 0, "midgrow": 0, "flags": 0,
          "upgraded": 0}
    sets = all_dnodes(img)
    for name, dns in sets:
        for obj, dn in sorted(dns.items()):
            if not is_zap(dn[0]):
                continue
            bad = []
            try:
                blocks = zap_blocks(img, dn)
            except (z.ToolError, KeyError, ValueError) as e:
                fails.append("%s object %d: unreadable (%s)" % (name, obj, e))
                continue
            b0 = blocks.get(0)
            bsz = struct.unpack_from("<H", dn, 8)[0] * 512
            if b0 is None:
                continue
            t = u64(b0, 0)
            if t == FZ.ZBT_MICRO:
                st["micro"] += 1
                check_micro(b0, bad)
            elif t == FZ.ZBT_HEADER:
                bs = bsz.bit_length() - 1
                if (1 << bs) != bsz:
                    bad.append("fat ZAP block size %d" % bsz)
                else:
                    st["fat"] += 1
                    st["names"] = {}
                    check_fat({k: bytes(v) for k, v in blocks.items()}, bs, bad, st)
                    if (name, obj) in pm:
                        psalt, pents = pm[(name, obj)]
                        same = name == "MOS" or obj < 0 or any(st["names"].get(k) == v for k, v in pents.items())
                        if same:
                            st["upgraded"] += 1
                            if u64(b0, 80) != psalt:
                                bad.append("upgraded from a microzap of salt %#x, the fat ZAP's is %#x (fzap_upgrade "
                                           "copies it)" % (psalt, u64(b0, 80)))
            else:
                bad.append("block 0 type %#x" % t)
            for x in bad:
                fails.append("%s object %d: %s" % (name, obj, x))
    for f in fails[:20]:
        print("fatzap:   FAIL %s" % f)
    if len(fails) > 20:
        print("fatzap:   FAIL ... and %d more" % (len(fails) - 20))
    print("fatzap: %s — %d dataset(s) + the MOS: %d microzap(s); %d fat ZAP(s): %d leaves (%d empty), %d entries, %d with "
          "an external pointer table, %d mid-doubling%s%s" % ("PASS" if not fails else "FAIL", len(sets) - 1, st["micro"],
          st["fat"], st["leaves"], st["empty"], st["entries"], st["external"], st["midgrow"],
          ", %d with zap_flags (not judged)" % st["flags"] if st["flags"] else "",
          "; %d upgraded since PRISTINE, salts kept" % st["upgraded"] if pm else ""))
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
