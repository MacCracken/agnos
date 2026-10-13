#!/usr/bin/env python3
# zfs-fatzap.py (agnos 1.57.12, bite B8) — an INDEPENDENT Python port of OpenZFS 2.4.2's fat-ZAP mutation, written from
# module/zfs/zap.c, zap_leaf.c and zap_micro.c (mzap_upgrade), over a dict of blocks {blkid: bytearray(2^bs)}: the
# expected side of check.sh gate 37's fat-ZAP vectors (scripts/check/zfs-codec-vectors.py) for kernel/core/zfs_wenc.cyr
# zfs_zf_* / zfs_zl_*, and the structure rules the image oracle holds every fat ZAP to (FatZap.check).
# ⭐ PROVEN ON OPENZFS'S OWN BYTES: replaying the creation history of the fixture's agnoswr/fat (an empty microzap
# upgraded by one 60-byte name, then f0..f9) and agnostank/dir3000 (f0000..f2046 in a 128 KiB microzap, the upgrade at
# the 2048th add, then f2047..f2999 — 16 leaves) reproduces every block FreeBSD 15.1 wrote, byte for byte; the vector
# generator re-checks that on every run (REAL_FAT), so this model cannot drift from OpenZFS unnoticed.
# Not modelled (as the kernel): zap_shrink (an emptied leaf is kept), ZAP_FLAG_*, u8_textprep beyond ASCII.
# ⭐ (B8 review) Where agnos's rule differs from OpenZFS's, the model follows agnos's, NAMED: zap_put_leaf_maybe_
# grow_ptrtbl ignores only a grow refused before it changed anything (nospc; nogrow — the caller's refusal, a MOS ZAP
# in the kernel) — any other failure is the op's (OpenZFS ignores them all); and zap_table_grow's switch frees the old
# table first (kill: all or nothing) and only then writes the header — OpenZFS's own end state either way. Two knobs
# stand for the kernel's refusals: killfail (every kill fails) and nogrow.
import struct

M64 = (1 << 64) - 1
CHAIN_END = 0xFFFF
T_ENTRY, T_ARRAY, T_FREE = 252, 251, 253
ZBT_LEAF, ZBT_HEADER, ZBT_MICRO = (1 << 63), (1 << 63) + 1, (1 << 63) + 3
ZAP_MAGIC, LEAF_MAGIC = 0x2F52AB2AB, 0x2AB1EAF
LOW_WATER = 20

_CRC = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = (_c >> 1) ^ (0xC96C5795D7870F42 if _c & 1 else 0)
    _CRC.append(_c)


def zap_hash(salt, name, bits=28):
    h = salt
    for c in name:
        h = (h >> 8) ^ _CRC[(h ^ c) & 0xFF]
    return h & ~((1 << (64 - bits)) - 1) & M64


class Err(Exception):
    def __init__(self, code):
        Exception.__init__(self, code)
        self.code = code


def u16(b, o): return struct.unpack_from("<H", b, o)[0]
def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]
def p16(b, o, v): struct.pack_into("<H", b, o, v & 0xFFFF)
def p32(b, o, v): struct.pack_into("<I", b, o, v & 0xFFFFFFFF)
def p64(b, o, v): struct.pack_into("<Q", b, o, v & M64)


class Leaf:
    def __init__(self, buf, bs):
        self.b, self.bs = buf, bs
        self.nh = 1 << (bs - 5)
        self.nc = ((1 << bs) - 2 * self.nh) // 24 - 2

    def ch(self, i):
        assert 0 <= i < self.nc, "chunk %d" % i
        return 48 + 2 * self.nh + 24 * i

    # header fields
    def prefix(self): return u64(self.b, 16)
    def plen(self): return u16(self.b, 32)
    def nfree(self): return u16(self.b, 28)
    def nent(self): return u16(self.b, 30)

    def hoff(self, h):
        return 48 + 2 * ((self.nh - 1) & (h >> (64 - (self.bs - 5) - self.plen())))

    def init(self, sort):
        b = self.b
        b[:] = bytes(len(b))
        for i in range(self.nh):
            p16(b, 48 + 2 * i, CHAIN_END)
        for i in range(self.nc):
            o = self.ch(i)
            b[o] = T_FREE
            p16(b, o + 22, i + 1)
        p16(b, self.ch(self.nc - 1) + 22, CHAIN_END)
        p64(b, 0, ZBT_LEAF)
        p32(b, 24, LEAF_MAGIC)
        p16(b, 28, self.nc)
        if sort:
            b[36] |= 1

    def alloc(self):
        assert self.nfree() > 0
        c = u16(self.b, 34)
        o = self.ch(c)
        assert self.b[o] == T_FREE
        p16(self.b, 34, u16(self.b, o + 22))
        p16(self.b, 28, self.nfree() - 1)
        return c

    def free(self, c):
        o = self.ch(c)
        self.b[o] = T_FREE
        self.b[o + 1:o + 22] = bytes(21)
        p16(self.b, o + 22, u16(self.b, 34))
        p16(self.b, 34, c)
        p16(self.b, 28, self.nfree() + 1)

    def afree(self, c):
        # 2.4: the chain spliced onto the free list in its own order
        tail = 34
        old = u16(self.b, 34)
        while c != CHAIN_END:
            o = self.ch(c)
            assert self.b[o] == T_ARRAY
            p16(self.b, tail, c)
            c = u16(self.b, o + 22)
            self.b[o] = T_FREE
            self.b[o + 1:o + 22] = bytes(21)
            tail = o + 22
            p16(self.b, 28, self.nfree() + 1)
        p16(self.b, tail, old)

    def acreate(self, data):
        # data: the big-endian byte string of the integers (21 bytes a chunk)
        head, prev = CHAIN_END, None
        for k in range(0, len(data), 21):
            c = self.alloc()
            o = self.ch(c)
            self.b[o] = T_ARRAY
            piece = data[k:k + 21]
            self.b[o + 1:o + 1 + len(piece)] = piece
            if prev is None:
                head = c
            else:
                p16(self.b, self.ch(prev) + 22, c)
            prev = c
        if prev is not None:
            p16(self.b, self.ch(prev) + 22, CHAIN_END)
        return head

    def aread(self, c, nbytes):
        out = bytearray()
        while len(out) < nbytes:
            o = self.ch(c)
            out += self.b[o + 1:o + 22]
            c = u16(self.b, o + 22)
        return bytes(out[:nbytes])

    def acopy(self, c, nl):
        head, prev = CHAIN_END, None
        while c != CHAIN_END:
            o = self.ch(c)
            n2 = nl.alloc()
            nl.b[nl.ch(n2):nl.ch(n2) + 24] = self.b[o:o + 24]
            c = u16(self.b, o + 22)
            if prev is None:
                head = n2
            else:
                p16(nl.b, nl.ch(prev) + 22, n2)
            prev = n2
        if prev is not None:
            p16(nl.b, nl.ch(prev) + 22, CHAIN_END)
        return head

    def lookup(self, h, name):
        # returns the offset of the u16 linking the entry, or None
        p = self.hoff(h)
        while u16(self.b, p) != CHAIN_END:
            c = u16(self.b, p)
            o = self.ch(c)
            assert self.b[o] == T_ENTRY
            if u64(self.b, o + 16) == h and u16(self.b, o + 6) == len(name) + 1:
                if self.aread(u16(self.b, o + 4), len(name) + 1) == name + b"\0":
                    return p
            p = o + 2
        return None

    def rehash(self, c):
        o = self.ch(c)
        cd = u32(self.b, o + 12)
        p = self.hoff(u64(self.b, o + 16))
        while u16(self.b, p) != CHAIN_END:
            o2 = self.ch(u16(self.b, p))
            if u32(self.b, o2 + 12) > cd:
                break
            p = o2 + 2
        p16(self.b, o + 2, u16(self.b, p))
        p16(self.b, p, c)

    def create(self, h, cd, name, isz, vals):
        nbytes = len(name) + 1
        vdata = b"".join(v.to_bytes(isz, "big") for v in vals)
        need = 1 + (nbytes + 20) // 21 + (len(vdata) + 20) // 21
        if need > self.nc:
            raise Err("2big")
        if cd is None:
            if self.b[36] & 1:
                cd = 0
                c = u16(self.b, self.hoff(h))
                while c != CHAIN_END:
                    o = self.ch(c)
                    if u32(self.b, o + 12) > cd:
                        break
                    if u64(self.b, o + 16) == h:
                        cd += 1
                    c = u16(self.b, o + 2)
            else:
                cd = 0
                while True:
                    used = False
                    c = u16(self.b, self.hoff(h))
                    while c != CHAIN_END:
                        o = self.ch(c)
                        if u64(self.b, o + 16) == h and u32(self.b, o + 12) == cd:
                            used = True
                            break
                        c = u16(self.b, o + 2)
                    if not used:
                        break
                    cd += 1
        if self.nfree() < need:
            return False
        e = self.alloc()
        o = self.ch(e)
        self.b[o] = T_ENTRY
        self.b[o + 1] = isz
        p16(self.b, o + 4, self.acreate(name + b"\0"))
        p16(self.b, o + 6, nbytes)
        p16(self.b, o + 8, self.acreate(vdata))
        p16(self.b, o + 10, len(vals))
        p32(self.b, o + 12, cd)
        p64(self.b, o + 16, h)
        self.rehash(e)
        p16(self.b, 30, self.nent() + 1)
        return True

    def remove(self, p):
        e = u16(self.b, p)
        o = self.ch(e)
        vc, nmc = u16(self.b, o + 8), u16(self.b, o + 4)
        p16(self.b, p, u16(self.b, o + 2))
        self.afree(vc)
        self.afree(nmc)
        self.free(e)
        p16(self.b, 30, self.nent() - 1)

    def update(self, p, isz, vals):
        o = self.ch(u16(self.b, p))
        vdata = b"".join(v.to_bytes(isz, "big") for v in vals)
        dc = (len(vdata) + 20) // 21 - (u16(self.b, o + 10) * self.b[o + 1] + 20) // 21
        if self.nfree() < dc:
            return False
        self.afree(u16(self.b, o + 8))
        p16(self.b, o + 8, self.acreate(vdata))
        p16(self.b, o + 10, len(vals))
        self.b[o + 1] = isz
        return True

    def xfer(self, e, nl):
        o = self.ch(e)
        c = nl.alloc()
        no = nl.ch(c)
        nl.b[no:no + 24] = self.b[o:o + 24]
        nl.rehash(c)
        p16(nl.b, no + 4, self.acopy(u16(self.b, o + 4), nl))
        p16(nl.b, no + 8, self.acopy(u16(self.b, o + 8), nl))
        self.afree(u16(self.b, o + 8))
        self.afree(u16(self.b, o + 4))
        self.free(e)
        p16(self.b, 30, self.nent() - 1)
        p16(nl.b, 30, nl.nent() + 1)

    def split(self, nl, sort):
        bit = 63 - self.plen()
        p64(self.b, 16, self.prefix() << 1)
        p16(self.b, 32, self.plen() + 1)
        p64(nl.b, 16, self.prefix() | 1)
        p16(nl.b, 32, self.plen())
        for i in range(self.nh):
            p16(self.b, 48 + 2 * i, CHAIN_END)
        if sort:
            self.b[36] |= 1
        for i in range(self.nc):
            o = self.ch(i)
            if self.b[o] != T_ENTRY:
                continue
            if (u64(self.b, o + 16) >> bit) & 1:
                self.xfer(i, nl)
            else:
                self.rehash(i)


class FatZap:
    """blocks: dict blkid -> bytearray(2^bs). freed: the blocks dmu_free_range'd (zeroed here)."""

    def __init__(self, bs, blocks=None, limit=None):
        self.bs = bs
        self.bsz = 1 << bs
        self.blocks = blocks if blocks is not None else {}
        self.limit = limit                      # blocks past it cannot be had (the kernel's resolver answers 0: ZZ_IO)
        self.killfail = False                   # zfs_zf_kill fails (changing nothing)
        self.nogrow = False                     # zfs_zf_gok refuses
        self.ev = set()                         # what maybe() met: "maybe-<code>" raised, "skip-<code>" ignored

    def blk(self, k):
        if self.limit is not None and k >= self.limit:
            raise Err("io")
        if k not in self.blocks:
            self.blocks[k] = bytearray(self.bsz)
        return self.blocks[k]

    def free(self, k):
        self.blocks[k] = bytearray(self.bsz)

    def kill(self, k, n):
        if self.killfail or (self.limit is not None and k + n > self.limit):
            raise Err("io")
        for i in range(n):
            self.free(k + i)

    @property
    def hdr(self):
        return self.blk(0)

    def emb(self, idx):
        return (1 << (self.bs - 1)) + 8 * idx

    def hidx(self, h, n):
        return 0 if n == 0 else h >> (64 - n)

    def hash(self, name):
        nf = u64(self.hdr, 88)
        if nf:
            assert all(c < 128 for c in name)
            if nf & 2:
                name = name.upper()
        return zap_hash(u64(self.hdr, 80), name)

    def i2b(self, idx):
        hd = self.hdr
        if u64(hd, 24) == 0:
            return u64(hd, self.emb(idx))
        m = (1 << (self.bs - 3)) - 1
        return u64(self.blk(u64(hd, 16) + (idx >> (self.bs - 3))), (idx & m) * 8)

    def sidx(self, idx, blk):
        hd = self.hdr
        if u64(hd, 16) == 0:
            p64(hd, self.emb(idx), blk)
            return
        m = (1 << (self.bs - 3)) - 1
        b = self.blk(u64(hd, 16) + (idx >> (self.bs - 3)))
        if u64(hd, 40):
            i2 = idx * 2
            b2 = self.blk(u64(hd, 40) + (i2 >> (self.bs - 3)))
            p64(b2, (i2 & m) * 8, blk)
            p64(b2, ((i2 & m) + 1) * 8, blk)
        p64(b, (idx & m) * 8, blk)

    def ablk(self, n):
        hd = self.hdr
        b = u64(hd, 56)
        p64(hd, 56, b + n)
        return b

    @staticmethod
    def transfer(src, so, dst, n):
        for i in range(n):
            v = u64(src, so + 8 * i)
            p64(dst, 16 * i, v)
            p64(dst, 16 * i + 8, v)

    def grow(self):
        hd = self.hdr
        if u64(hd, 32) >= 26:
            raise Err("nospc")
        if self.nogrow:
            raise Err("nogrow")
        hepb = 1 << (self.bs - 4)
        if u64(hd, 24) == 0:
            nb = self.ablk(1)
            self.transfer(hd, 1 << (self.bs - 1), self.blk(nb), hepb)
            p64(hd, 16, nb)
            p64(hd, 24, 1)
            p64(hd, 32, u64(hd, 32) + 1)
            return
        nb = u64(hd, 40)
        if nb == 0:
            nb = self.ablk(u64(hd, 24) * 2)
            p64(hd, 40, nb)
        b = u64(hd, 48)
        if b >= u64(hd, 24):
            raise Err("corrupt")
        n0, n1 = self.blk(nb + 2 * b), self.blk(nb + 2 * b + 1)
        old = self.blk(u64(hd, 16) + b)
        self.transfer(old, 0, n0, hepb)
        self.transfer(old, 8 * hepb, n1, hepb)
        if b + 1 < u64(hd, 24):
            p64(hd, 48, b + 1)
            return
        self.kill(u64(hd, 16), u64(hd, 24))
        p64(hd, 16, nb)
        p64(hd, 24, u64(hd, 24) * 2)
        p64(hd, 32, u64(hd, 32) + 1)
        p64(hd, 40, 0)
        p64(hd, 48, 0)

    def leaf(self, k):
        return Leaf(self.blk(k), self.bs)

    def expand(self, h, lb):
        hd = self.hdr
        l = self.leaf(lb)
        opl = l.plen()
        while opl == u64(hd, 32):
            self.grow()
        pd = u64(hd, 32) - (opl + 1)
        sib = (self.hidx(h, opl + 1) | 1) << pd
        for i in range(1 << pd):
            assert self.i2b(sib + i) == lb
        nb = self.ablk(1)
        nl = self.leaf(nb)
        sort = u64(hd, 88) != 0
        nl.init(sort)
        p64(hd, 64, u64(hd, 64) + 1)
        l.split(nl, sort)
        for i in range(1 << pd):
            self.sidx(sib + i, nb)
        return nb if (h >> (64 - l.plen())) & 1 else lb

    def maybe(self, l):
        hd = self.hdr
        sh = u64(hd, 32)
        if (l.plen() == sh and l.nfree() < LOW_WATER) or u64(hd, 40):
            if u64(hd, 32) == sh:
                try:
                    self.grow()
                except Err as e:
                    if e.code not in ("nospc", "nogrow"):
                        self.ev.add("maybe-" + e.code)
                        raise
                    self.ev.add("skip-" + e.code)

    def op(self, op, name, isz=8, vals=(0,), cd=None):
        """op 'add' (cd None = ZAP_NEED_CD) / 'update' / 'remove'; raises Err('exist' / 'noent' / ...)."""
        hd = self.hdr
        h = self.hash(name)
        lb = self.i2b(self.hidx(h, u64(hd, 32)))
        l = self.leaf(lb)
        assert self.hidx(h, l.plen()) == l.prefix()
        while True:
            p = l.lookup(h, name)
            if op == "remove":
                if p is None:
                    raise Err("noent")
                l.remove(p)
                p64(hd, 72, u64(hd, 72) - 1)
                return
            if p is not None and op == "add":
                raise Err("exist")
            if p is not None:
                ok = l.update(p, isz, vals)
            else:
                ok = l.create(h, cd, name, isz, vals)
                if ok:
                    p64(hd, 72, u64(hd, 72) + 1)
            if ok:
                self.maybe(l)
                return
            lb = self.expand(h, lb)
            l = self.leaf(lb)

    def get(self, name):
        hd = self.hdr
        h = self.hash(name)
        l = self.leaf(self.i2b(self.hidx(h, u64(hd, 32))))
        p = l.lookup(h, name)
        if p is None:
            return None
        o = l.ch(u16(l.b, p))
        isz, n = l.b[o + 1], u16(l.b, o + 10)
        raw = l.aread(u16(l.b, o + 8), isz * n)
        return [int.from_bytes(raw[i * isz:(i + 1) * isz], "big") for i in range(n)]

    def upgrade(self, micro):
        """mzap_upgrade: micro = the microzap block's bytes (64-byte header, 64-byte chunks)."""
        salt, nf = u64(micro, 8), u64(micro, 16)
        hd = self.hdr
        hd[:] = bytes(self.bsz)
        p64(hd, 0, ZBT_HEADER)
        p64(hd, 8, ZAP_MAGIC)
        p64(hd, 32, self.bs - 4)
        p64(hd, 56, 2)
        p64(hd, 64, 1)
        p64(hd, 80, salt)
        p64(hd, 88, nf)
        for i in range(1 << (self.bs - 4)):
            p64(hd, self.emb(i), 1)
        self.leaf(1).init(nf != 0)
        for k in range(64, len(micro), 64):
            if micro[k + 14] == 0:
                continue
            name = bytes(micro[k + 14:k + 64]).split(b"\0")[0]
            self.op("add", name, 8, (u64(micro, k),), u32(micro, k + 8))

    # --- structure check (the image oracle's rules) ---
    def check(self):
        hd = self.hdr
        assert u64(hd, 0) == ZBT_HEADER and u64(hd, 8) == ZAP_MAGIC
        sh = u64(hd, 32)
        leaves = set(self.i2b(i) for i in range(1 << sh))
        tot = 0
        for lb in leaves:
            l = self.leaf(lb)
            assert u64(l.b, 0) == ZBT_LEAF and u32(l.b, 24) == LEAF_MAGIC
            pl, pf = l.plen(), l.prefix()
            for i in range(1 << sh):
                want = (i >> (sh - pl)) == pf
                assert (self.i2b(i) == lb) == want, "ptrtbl %d" % i
            tot += l.nent()
        assert tot == u64(hd, 72), "num_entries %d vs %d" % (u64(hd, 72), tot)
        assert len(leaves) == u64(hd, 64), "num_leafs"
        return True


def micro_block(size, salt, entries, normflags=0):
    """A microzap block: entries [(name bytes, value, cd)] in chunk order."""
    b = bytearray(size)
    p64(b, 0, ZBT_MICRO)
    p64(b, 8, salt)
    p64(b, 16, normflags)
    for i, (nm, v, cd) in enumerate(entries):
        o = 64 + 64 * i
        p64(b, o, v)
        p32(b, o + 8, cd)
        b[o + 14:o + 14 + len(nm)] = nm
    return b
