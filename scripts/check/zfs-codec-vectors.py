#!/usr/bin/env python3
# zfs-codec-vectors — generate tests/zfscodec/gen/vectors.cyr, the reference vectors the host oracle
# (tests/zfscodec/zfscodec.cyr) scores kernel/core/zfs_codec.cyr against.
#
# Run as `python3 -I scripts/check/zfs-codec-vectors.py [OUT]` (default OUT is
# tests/zfscodec/gen/vectors.cyr, git-ignored). scripts/check/host-zfs-oracles.sh regenerates it on
# every run, so the oracle never scores against a stale file.
#
# ⭐ WHERE EACH EXPECTED VALUE COMES FROM — none of it from the code under test:
#   SHA-256, SHA-512/256    hashlib (OpenSSL), over "abc", the empty string, every padding boundary
#                           (55/56/63/64/111/112/127/128 ...) and a 1 MiB pseudo-random buffer;
#                           the streaming SHA-256 (begin/update/end, fed in uneven pieces, once with
#                           one-shot hashes interleaved) must reproduce hashlib's one-shot digest.
#                           sha512 is scored in BOTH word orders (H[i], and the bswapped words a
#                           little-endian OpenZFS writes into blk_cksum).
#   fletcher2 / fletcher4   the textbook loops below, over the same buffer — including sums that wrap.
#   ZAP hash                the TABLE form of the CRC-64 (the kernel runs it bitwise; agreement is the
#                           point), at 28, 48 and 64 kept bits.
#   LZ4                     raw blocks cut out of `lz4` CLI frames (-1 and -12), each re-decoded by
#                           the Python block decoder below and compared to its plaintext before it is
#                           emitted; plus hand-built blocks (overlapping matches, length-extension
#                           edges, a literals-only block) whose output that decoder defines.
#   LZJB, ZLE               Python ports of OpenZFS lzjb_compress / zle_compress, each round-tripped
#                           through a Python port of the matching decompressor before it is emitted.
#   gzip                    zlib (levels 1/6/9, stored, fixed-Huffman, RLE, Huffman-only, a 512-byte
#                           window, a sync-flush mid-stream, ZFS sector padding), each confirmed by
#                           zlib's own inflate; plus hand-built dynamic blocks whose ONLY defect is
#                           an incomplete / over-subscribed code (payload and Adler-32 valid), so
#                           the completeness rule itself is what must refuse them.
# NEGATIVE cases (truncation, offsets before the start of dst, offset 0, a bad Adler-32, a bad
# FCHECK, FDICT, CM/CINFO, block type 3, LEN/NLEN mismatch, a distance too far back,
# over-subscribed and incomplete Huffman codes, output one byte too small ...) carry an expected
# return of -1, and each one's -1 is CONFIRMED here by the independent decoder (zlib for gzip, the
# Python decoders for the rest) — a "negative" vector that a correct decoder would accept is refused
# at generation time rather than shipped as a false expectation.
#
# Deterministic: no clock, no `random` module. Pseudo-random bytes come from splitmix64, which the
# oracle re-implements to build its 1 MiB buffer instead of embedding it; a dedicated case checks the
# two implementations agree before any hash over that buffer is believed.
import hashlib
import os
import struct
import subprocess
import sys
import zlib

M64 = (1 << 64) - 1
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "tests", "zfscodec", "gen", "vectors.cyr")

PRNG_SEED = 0x5A465321C0DEC0DE
PRNG_LEN = 1 << 20


# ------------------------------------------------------------------------------------------------
# deterministic bytes
# ------------------------------------------------------------------------------------------------
class SplitMix:
    def __init__(self, seed):
        self.s = seed & M64

    def next(self):
        self.s = (self.s + 0x9E3779B97F4A7C15) & M64
        z = self.s
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
        return z ^ (z >> 31)

    def below(self, n):
        return self.next() % n


def prng_bytes(seed, n):
    g = SplitMix(seed)
    out = bytearray()
    while len(out) < n:
        out += struct.pack("<Q", g.next())
    return bytes(out[:n])


WORDS = ("the of and to in is was that for it with as his on be at by had are from or this an "
         "which but not they have were one all she when there their what so out up if about who "
         "zfs pool vdev dnode objset uberblock checksum block pointer indirect dataset snapshot "
         "kernel cyrius agnos sovereign compress inflate huffman literal match offset window").split()


def text_bytes(seed, n):
    g = SplitMix(seed)
    out = bytearray()
    while len(out) < n:
        w = WORDS[g.below(len(WORDS))]
        if g.below(9) == 0:
            w = w.capitalize()
        out += w.encode()
        r = g.below(23)
        out += b".\n" if r == 0 else (b", " if r == 1 else b" ")
    return bytes(out[:n])


def zeros_mix(seed, n):
    g = SplitMix(seed)
    out = bytearray()
    while len(out) < n:
        out += b"\0" * (1 + g.below(600))
        out += bytes(1 + g.below(255) for _ in range(1 + g.below(100)))
        if g.below(4) == 0:
            out += b"\0"                              # isolated zero inside a literal run
            out += bytes(1 + g.below(255) for _ in range(1 + g.below(5)))
    return bytes(out[:n])


def mixed(seed, n):
    """Text, far repeats (up to ~65 KB back), long single-byte runs, and noise."""
    g = SplitMix(seed)
    out = bytearray()
    while len(out) < n:
        k = g.below(5)
        if k == 0:
            out += text_bytes(g.next(), 200 + g.below(800))
        elif k == 1 and len(out) > 1024:
            back = 1 + g.below(min(len(out), 65000))
            ln = 4 + g.below(600)
            start = len(out) - back
            for i in range(ln):
                out.append(out[start + i])
        elif k == 2:
            out += bytes([g.below(256)]) * (270 + g.below(700))
        elif k == 3:
            out += prng_bytes(g.next(), 1 + g.below(300))
        else:
            out += text_bytes(g.next(), 20 + g.below(60)) * (2 + g.below(6))
    return bytes(out[:n])


def periodic():
    out = bytearray()
    for per in (1, 2, 3, 4, 5, 6, 7, 9, 13):
        pat = bytes(97 + (i * 7) % 26 for i in range(per))
        out += b"|" + pat * (1 + 900 // per)
    return bytes(out)


P = {}
P["abc"] = b"abc"
P["a"] = b"a"
P["empty"] = b""
P["text4k"] = text_bytes(1, 4096)
P["zeros8k"] = zeros_mix(2, 8192)
P["rand1k"] = prng_bytes(3, 1024)
P["mixed64k"] = mixed(4, 65536)
P["run10k"] = b"xyz" + b"A" * 9997
P["period"] = periodic()
P["text128k"] = text_bytes(5, 131072)
P["zero4k"] = b"\0" * 4096
P["text70k"] = text_bytes(6, 70000)


# ------------------------------------------------------------------------------------------------
# reference algorithms (textbook forms, deliberately not shaped like the Cyrius)
# ------------------------------------------------------------------------------------------------
def fletcher4(b):
    a = bb = c = d = 0
    for (w,) in struct.iter_unpack("<I", b):
        a = (a + w) & M64
        bb = (bb + a) & M64
        c = (c + bb) & M64
        d = (d + c) & M64
    return [a, bb, c, d]


def fletcher2(b):
    a0 = a1 = b0 = b1 = 0
    for (w0, w1) in struct.iter_unpack("<QQ", b):
        a0 = (a0 + w0) & M64
        a1 = (a1 + w1) & M64
        b0 = (b0 + a0) & M64
        b1 = (b1 + a1) & M64
    return [a0, a1, b0, b1]


CRC64_POLY = 0xC96C5795D7870F42
CRC_T = []
for _i in range(256):
    _v = _i
    for _ in range(8):
        _v = (_v >> 1) ^ (CRC64_POLY if (_v & 1) else 0)
    CRC_T.append(_v)


def zap_hash(salt, name, bits):
    crc = salt
    for c in name:
        crc = (crc >> 8) ^ CRC_T[(crc ^ c) & 0xFF]
    if bits >= 64:
        return crc
    return crc & ~((1 << (64 - bits)) - 1) & M64


def sha256_words(b):
    d = hashlib.sha256(b).digest()
    return [int.from_bytes(d[i:i + 8], "big") for i in range(0, 32, 8)]


def sha512_256_digest(b):
    return hashlib.new("sha512_256", b).digest()


def sha512_256_words(b):
    d = sha512_256_digest(b)
    return [int.from_bytes(d[i:i + 8], "big") for i in range(0, 32, 8)]


def sha512_256_le_words(b):
    d = sha512_256_digest(b)
    return [int.from_bytes(d[i:i + 8], "little") for i in range(0, 32, 8)]


# --- LZ4 block (lz4 Block_format.md), with the decoder contract kernel/core/zfs_codec.cyr states ---
def lz4_block_decode(b, cap):
    n = len(b)
    if n == 0:
        return None
    i = 0
    out = bytearray()
    while i < n:
        tok = b[i]
        i += 1
        lit = tok >> 4
        if lit == 15:
            while True:
                if i >= n:
                    return None
                s = b[i]
                i += 1
                lit += s
                if s != 255:
                    break
        if lit > n - i or lit > cap - len(out):
            return None
        out += b[i:i + lit]
        i += lit
        if i == n:
            return bytes(out)
        if n - i < 2:
            return None
        off = b[i] | (b[i + 1] << 8)
        i += 2
        if off == 0 or off > len(out):
            return None
        ml = tok & 15
        if ml == 15:
            while True:
                if i >= n:
                    return None
                s = b[i]
                i += 1
                ml += s
                if s != 255:
                    break
        ml += 4
        if ml > cap - len(out):
            return None
        for _ in range(ml):
            out.append(out[-off])
    return None


def zfs_lz4_decode(src, cap):
    if len(src) < 4:
        return None
    bufsiz = struct.unpack(">I", src[:4])[0]
    if bufsiz + 4 > len(src) or bufsiz == 0:
        return None
    return lz4_block_decode(src[4:4 + bufsiz], cap)


def lz4_cli_block(data, level):
    """Compress with the lz4 CLI and cut the single data block out of the frame."""
    fr = subprocess.run(["lz4", "-c", "-q", "-B4", "-BI", "--no-frame-crc", "-%d" % level],
                        input=data, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True).stdout
    assert fr[:4] == b"\x04\x22\x4d\x18", "not an LZ4 frame"
    flg = fr[4]
    assert (flg >> 6) == 1, "unknown LZ4 frame version"
    i = 6                                           # FLG, BD
    if flg & 0x08:
        i += 8                                      # content size
    if flg & 0x01:
        i += 4                                      # dictionary id
    i += 1                                          # header checksum
    blocks = []
    while True:
        (bs,) = struct.unpack("<I", fr[i:i + 4])
        i += 4
        if bs == 0:
            break
        raw = bool(bs & 0x80000000)
        bs &= 0x7FFFFFFF
        blocks.append((raw, fr[i:i + bs]))
        i += bs
        if flg & 0x10:
            i += 4                                  # block checksum
    assert len(blocks) == 1, "expected exactly one block (input <= 64 KiB)"
    raw, blk = blocks[0]
    assert not raw, "lz4 stored this block uncompressed"
    assert lz4_block_decode(blk, len(data)) == data, "lz4 CLI block does not decode to its input"
    return blk


def zfs_lz4_frame(blk):
    return struct.pack(">I", len(blk)) + blk


def lz4_varlen(v):
    out = bytearray()
    while v >= 255:
        out.append(255)
        v -= 255
    out.append(v)
    return bytes(out)


def lz4_seq(lits, off=None, mlen=None):
    """One sequence. off/mlen None = the literals-only last sequence."""
    ll = len(lits)
    tok_l = 15 if ll >= 15 else ll
    if off is None:
        return bytes([tok_l << 4]) + (lz4_varlen(ll - 15) if ll >= 15 else b"") + lits
    m = mlen - 4
    tok_m = 15 if m >= 15 else m
    out = bytes([(tok_l << 4) | tok_m])
    if ll >= 15:
        out += lz4_varlen(ll - 15)
    out += lits + struct.pack("<H", off)
    if m >= 15:
        out += lz4_varlen(m - 15)
    return out


# --- LZJB (OpenZFS lzjb.c), compressor and decompressor ports ---
def lzjb_compress(src, d_len):
    MATCH_MAX = (1 << 6) + 2
    lempel = [0] * 1024
    dst = bytearray()
    copymap = 0
    copymask = 1 << 7
    s = 0
    n = len(src)
    while s < n:
        copymask <<= 1
        if copymask == 256:
            if len(dst) >= d_len - 1 - 16:
                return None
            copymask = 1
            copymap = len(dst)
            dst.append(0)
        if s > n - MATCH_MAX:
            dst.append(src[s])
            s += 1
            continue
        h = (src[s] << 16) + (src[s + 1] << 8) + src[s + 2]
        h += h >> 9
        h += h >> 5
        slot = h & 1023
        off = (s - lempel[slot]) & 0x3FF          # the C does this on a pointer; a base of 0 here
        lempel[slot] = s & 0xFFFF
        cpy = s - off
        if cpy >= 0 and cpy != s and src[s:s + 3] == src[cpy:cpy + 3]:
            dst[copymap] |= copymask
            mlen = 3
            while mlen < MATCH_MAX and src[s + mlen] == src[cpy + mlen]:
                mlen += 1
            dst.append(((mlen - 3) << 2) | (off >> 8))
            dst.append(off & 0xFF)
            s += mlen
        else:
            dst.append(src[s])
            s += 1
    return bytes(dst)


def lzjb_decode(src, dlen):
    """OpenZFS lzjb_decompress, plus the s_len bound and the offset-0 refusal zfs_codec.cyr adds."""
    si = di = 0
    out = bytearray()
    copymap = 0
    copymask = 1 << 7
    while di < dlen:
        copymask <<= 1
        if copymask == 256:
            if si >= len(src):
                return None
            copymask = 1
            copymap = src[si]
            si += 1
        if copymap & copymask:
            if len(src) - si < 2:
                return None
            mlen = (src[si] >> 2) + 3
            off = ((src[si] << 8) | src[si + 1]) & 0x3FF
            si += 2
            if off == 0 or off > di:
                return None
            for _ in range(min(mlen, dlen - di)):
                out.append(out[-off])
                di += 1
        else:
            if si >= len(src):
                return None
            out.append(src[si])
            si += 1
            di += 1
    return bytes(out)


# --- ZLE (OpenZFS zle.c), compressor and decompressor ports ---
def zle_compress(src, d_len, n=64):
    s = 0
    S = len(src)
    dst = bytearray()
    while s < S and len(dst) < d_len - 1:
        first = s
        lp = len(dst)
        dst.append(0)
        if src[s] == 0:
            last = s + (256 - n)
            while s < min(last, S) and src[s] == 0:
                s += 1
            dst[lp] = s - first - 1 + n
        else:
            last = s + n
            if d_len - len(dst) < n:
                break
            while s < min(last, S) - 1 and (src[s] | src[s + 1]):
                dst.append(src[s])
                s += 1
            if src[s]:
                dst.append(src[s])
                s += 1
            dst[lp] = s - first - 1
    return bytes(dst) if s == S else None


def zle_decode(src, dlen, n=64):
    si = 0
    out = bytearray()
    while si < len(src) and len(out) < dlen:
        ln = 1 + src[si]
        si += 1
        if ln <= n:
            if ln > len(src) - si or ln > dlen - len(out):
                return None
            out += src[si:si + ln]
            si += ln
        else:
            ln -= n
            if ln > dlen - len(out):
                return None
            out += b"\0" * ln
    return bytes(out) if len(out) == dlen else None


# --- zlib ---
def zlib_stream(data, level=6, wbits=15, strategy=zlib.Z_DEFAULT_STRATEGY):
    c = zlib.compressobj(level, zlib.DEFLATED, wbits, 8, strategy)
    return c.compress(data) + c.flush()


def zlib_decode(src, dlen):
    """zlib's verdict under the kernel contract: complete stream, Adler OK, output fits in dlen."""
    d = zlib.decompressobj()
    try:
        out = d.decompress(src)
    except zlib.error:
        return None
    if not d.eof:
        return None
    if len(out) > dlen:
        return None
    return out


def fix_fcheck(cmf, flg):
    flg &= 0xE0
    flg |= (31 - ((cmf << 8) | flg) % 31) % 31
    assert ((cmf << 8) | flg) % 31 == 0
    return bytes([cmf, flg])


class BitWriter:
    def __init__(self):
        self.out = bytearray()
        self.acc = 0
        self.n = 0

    def bits(self, v, n):                          # LSB first (RFC 1951 §3.1.1)
        self.acc |= v << self.n
        self.n += n
        while self.n >= 8:
            self.out.append(self.acc & 0xFF)
            self.acc >>= 8
            self.n -= 8

    def huff(self, code, n):                       # Huffman codes go MSB first
        for i in range(n - 1, -1, -1):
            self.bits((code >> i) & 1, 1)

    def done(self):
        if self.n:
            self.out.append(self.acc & 0xFF)
            self.acc = self.n = 0
        return bytes(self.out)


def fixed_lit(bw, sym):
    if sym < 144:
        bw.huff(0x30 + sym, 8)
    elif sym < 256:
        bw.huff(0x190 + sym - 144, 9)
    elif sym < 280:
        bw.huff(sym - 256, 7)
    else:
        bw.huff(0xC0 + sym - 280, 8)


# ------------------------------------------------------------------------------------------------
# emission
# ------------------------------------------------------------------------------------------------
blobs = []            # list of bytes
blob_ix = {}


def blob(b):
    b = bytes(b)
    if b not in blob_ix:
        blob_ix[b] = len(blobs)
        blobs.append(b)
    return blob_ix[b]


def fnv1a(b):
    h = 0xCBF29CE484222325
    for c in b:
        h = ((h ^ c) * 0x100000001B3) & M64
    return h


def cyr_lit(b):
    s = []
    for c in b:
        if 0x20 <= c < 0x7F and c not in (0x22, 0x5C, 0x24, 0x23, 0x7B, 0x7D):
            s.append(chr(c))
        else:
            s.append("\\x%02x" % c)
    return '"' + "".join(s) + '"'


cases = []            # Cyrius statements, one case each
ncases = 0


def h64(v):
    return "0x%016X" % (v & M64)


def add(stmt):
    global ncases
    cases.append(stmt)
    ncases += 1


def name_ok(name):
    assert all(0x20 <= ord(ch) < 0x7F and ch not in '"\\$#{}' for ch in name), name
    return name


# kind numbers shared with tests/zfscodec/zfscodec.cyr
K_SHA256, K_SHA512, K_SHA512LE, K_FL4, K_FL2 = 1, 2, 3, 4, 5
D_LZ4, D_LZJB, D_ZLE, D_GZIP = 1, 2, 3, 4
SRC_PRNG = -1


def sum_case(kind, name, data_sel, data, expect_rc, words):
    w = words if words is not None else [0, 0, 0, 0]
    add('    zt_e4(%s, %s, %s, %s); zt_sum(%d, "%s", %d, %d, %d);'
        % (h64(w[0]), h64(w[1]), h64(w[2]), h64(w[3]), kind, name_ok(name), data_sel, len(data), expect_rc))


def dec_case(kind, name, comp, plain, dcap):
    """Expected verdict from the independent decoder; plain is what success must reproduce."""
    if kind == D_LZ4:
        ref = zfs_lz4_decode(comp, dcap)
    elif kind == D_LZJB:
        ref = lzjb_decode(comp, dcap)
    elif kind == D_ZLE:
        ref = zle_decode(comp, dcap)
    else:
        ref = zlib_decode(comp, dcap)
    if plain is None:
        assert ref is None, "negative vector %r decodes under the reference" % name
        rc, pid = -1, -1
    else:
        assert ref == plain, "positive vector %r does not reproduce its plaintext" % name
        rc, pid = 0, blob(plain)
    add('    zt_dec(%d, "%s", %d, %d, %d, %d);' % (kind, name_ok(name), blob(comp), pid, dcap, rc))


PRNG = prng_bytes(PRNG_SEED, PRNG_LEN)

# --- 0: the PRNG agreement check, which every hash over the 1 MiB buffer depends on ------------------
add('    zt_prng_check(%s, %s);' % (h64(fnv1a(PRNG)), h64(struct.unpack("<Q", PRNG[:8])[0])))

# --- SHA-2 ---
SHA_LENS = [0, 1, 3, 55, 56, 57, 63, 64, 65, 111, 112, 113, 119, 120, 127, 128, 129, 191, 192, 1000,
            4096, 131072, PRNG_LEN]
abc = blob(b"abc")
sum_case(K_SHA256, "sha256 abc", abc, b"abc", 0, sha256_words(b"abc"))
sum_case(K_SHA512, "sha512/256 abc", abc, b"abc", 0, sha512_256_words(b"abc"))
sum_case(K_SHA512LE, "sha512/256 abc le-words", abc, b"abc", 0, sha512_256_le_words(b"abc"))
for n in SHA_LENS:
    d = PRNG[:n]
    sum_case(K_SHA256, "sha256 prng %d" % n, SRC_PRNG, d, 0, sha256_words(d))
    sum_case(K_SHA512, "sha512/256 prng %d" % n, SRC_PRNG, d, 0, sha512_256_words(d))
sum_case(K_SHA512LE, "sha512/256 prng 4096 le-words", SRC_PRNG, PRNG[:4096], 0, sha512_256_le_words(PRNG[:4096]))
t = P["text4k"]
sum_case(K_SHA256, "sha256 text4k", blob(t), t, 0, sha256_words(t))

# --- streaming SHA-256 (begin / update in uneven pieces / end) must equal the one-shot digest ---
for n in [0, 1, 55, 56, 63, 64, 65, 200, 4097, PRNG_LEN]:
    d = PRNG[:n]
    w = sha256_words(d)
    add('    zt_e4(%s, %s, %s, %s); zt_stream("sha256 stream %d uneven pieces", %d, 0);'
        % (h64(w[0]), h64(w[1]), h64(w[2]), h64(w[3]), n, n))
w = sha256_words(PRNG)
add('    zt_e4(%s, %s, %s, %s); zt_stream("sha256 stream 1MiB, one-shots interleaved", %d, 1);'
    % (h64(w[0]), h64(w[1]), h64(w[2]), h64(w[3]), PRNG_LEN))

# --- fletcher ---
for n in [0, 4, 8, 12, 16, 28, 4096, 131072, PRNG_LEN]:
    d = PRNG[:n]
    sum_case(K_FL4, "fletcher4 prng %d" % n, SRC_PRNG, d, 0, fletcher4(d))
for n in [0, 16, 32, 48, 4096, 131072, PRNG_LEN]:
    d = PRNG[:n]
    sum_case(K_FL2, "fletcher2 prng %d" % n, SRC_PRNG, d, 0, fletcher2(d))
ff = b"\xff" * 65536                           # all-ones: every one of the four sums wraps
sum_case(K_FL4, "fletcher4 all-ones 64k wraps", blob(ff), ff, 0, fletcher4(ff))
sum_case(K_FL2, "fletcher2 all-ones 64k wraps", blob(ff), ff, 0, fletcher2(ff))
assert (0xFFFFFFFF * (16387 * 16386 * 16385 * 16384 // 24)) >> 64 != 0   # d really does wrap
for bad in (1, 2, 3, 6, 4094):
    sum_case(K_FL4, "fletcher4 len %d refused" % bad, SRC_PRNG, PRNG[:bad], -1, None)
for bad in (8, 24, 4095):
    sum_case(K_FL2, "fletcher2 len %d refused" % bad, SRC_PRNG, PRNG[:bad], -1, None)

# --- ZAP hash ---
names = [b"ROOT", b"hello.txt", b"", b"a", b"lost+found", "café-über".encode(),
         bytes(range(1, 256)), (b"N" * 200 + b"0123456789" * 5 + b"tail!")[:255]]
assert len(names[6]) == 255 and len(names[7]) == 255
salts = [0x1234, 0x8000000000000001, 0xDEADBEEFCAFEBABE, 0x0123456789ABCDEF]
for i, nm in enumerate(names):
    for j, salt in enumerate(salts):
        if (i + j) % 2 == 1 and i not in (0, 6):
            continue
        for bits in (28, 48):
            add('    zt_zap("zap %d/%d bits %d", %d, %s, %d, %s);'
                % (i, j, bits, blob(nm), h64(salt), bits, h64(zap_hash(salt, nm, bits))))
add('    zt_zap("zap 1/1 bits 64", %d, %s, 64, %s);'
    % (blob(names[1]), h64(salts[1]), h64(zap_hash(salts[1], names[1], 64))))

# --- LZ4 ---
for key in ("text4k", "zeros8k", "mixed64k", "run10k", "period", "zero4k"):
    pl = P[key]
    for lvl in (1, 12):
        comp = zfs_lz4_frame(lz4_cli_block(pl, lvl))
        dec_case(D_LZ4, "lz4 %s -%d" % (key, lvl), comp, pl, len(pl))
pl = P["text4k"]
blk = lz4_cli_block(pl, 1)
comp = zfs_lz4_frame(blk)
dec_case(D_LZ4, "lz4 text4k dst roomy (tail left as-is)", comp, pl, len(pl) + 300)
dec_case(D_LZ4, "lz4 text4k + ZFS sector padding", comp + b"\0" * 12, pl, len(pl))
dec_case(D_LZ4, "lz4 text4k dst one byte short", comp, None, len(pl) - 1)
dec_case(D_LZ4, "lz4 bufsiz claims 1 more than slen", struct.pack(">I", len(blk) + 1) + blk, None, len(pl))
dec_case(D_LZ4, "lz4 slen 3", comp[:3], None, len(pl))
dec_case(D_LZ4, "lz4 bufsiz 0", b"\0\0\0\0" + blk, None, len(pl))
for cut in (1, 2, 7, len(blk) // 2):
    tb = blk[:len(blk) - cut]
    if lz4_block_decode(tb, len(pl)) is None:
        dec_case(D_LZ4, "lz4 truncated by %d (header rewritten)" % cut, zfs_lz4_frame(tb), None, len(pl))
dec_case(D_LZ4, "lz4 truncated payload, header intact", comp[:len(comp) - 5], None, len(pl))
r1k = P["rand1k"]
dec_case(D_LZ4, "lz4 literals-only 1k (len ext 255,255,255,244)", zfs_lz4_frame(lz4_seq(r1k)), r1k, 1024)
dec_case(D_LZ4, "lz4 single literal", zfs_lz4_frame(lz4_seq(b"a")), b"a", 1)
dec_case(D_LZ4, "lz4 empty last sequence", zfs_lz4_frame(b"\x00"), b"", 16)
# overlapping matches at every short offset, plus length-extension edges
hand = (lz4_seq(b"ab", 2, 30) + lz4_seq(b"", 1, 20) + lz4_seq(b"xyz", 3, 19)
        + lz4_seq(b"12345", 5, 23) + lz4_seq(b"abcdefg", 7, 41) + lz4_seq(b"QRSTUVWXY", 9, 274)
        + lz4_seq(b"z" * 15, 6, 18) + lz4_seq(b"!", 300, 4) + lz4_seq(b"tail."))
hp = lz4_block_decode(hand, 1 << 16)
assert hp is not None and len(hp) > 400
dec_case(D_LZ4, "lz4 hand overlapping offsets 1..9 + ext edges", zfs_lz4_frame(hand), hp, len(hp))
dec_case(D_LZ4, "lz4 hand, dst exact minus 1", zfs_lz4_frame(hand), None, len(hp) - 1)
dec_case(D_LZ4, "lz4 offset reaches before dst", zfs_lz4_frame(lz4_seq(b"abcd", 5, 4) + lz4_seq(b"e")),
         None, 64)
dec_case(D_LZ4, "lz4 offset 0", zfs_lz4_frame(lz4_seq(b"abcd", 0, 4) + lz4_seq(b"e")), None, 64)
dec_case(D_LZ4, "lz4 block ends after a match", zfs_lz4_frame(lz4_seq(b"abcd", 4, 8)), None, 64)
dec_case(D_LZ4, "lz4 literal length runs off the block", zfs_lz4_frame(b"\xf0\xff\xff"), None, 4096)
dec_case(D_LZ4, "lz4 literal count past block end", zfs_lz4_frame(b"\x50abc"), None, 64)
dec_case(D_LZ4, "lz4 match length ext runs off the block",
         zfs_lz4_frame(b"\x1fa\x01\x00\xff\xff"), None, 4096)
dec_case(D_LZ4, "lz4 offset cut in half", zfs_lz4_frame(b"\x10a\x01"), None, 64)

# --- LZJB ---
for key in ("text4k", "zeros8k", "mixed64k", "run10k", "period", "text128k", "rand1k"):
    pl = P[key]
    comp = lzjb_compress(pl, 2 * len(pl) + 64)
    assert comp is not None
    dec_case(D_LZJB, "lzjb %s" % key, comp, pl, len(pl))
pl = P["text4k"]
comp = lzjb_compress(pl, 2 * len(pl) + 64)
dec_case(D_LZJB, "lzjb text4k dst 10 short (prefix)", comp, pl[:len(pl) - 10], len(pl) - 10)
dec_case(D_LZJB, "lzjb text4k truncated half", comp[:len(comp) // 2], None, len(pl))
dec_case(D_LZJB, "lzjb text4k truncated by 1", comp[:len(comp) - 1], None, len(pl))
dec_case(D_LZJB, "lzjb empty input, dlen 1", b"", None, 1)
dec_case(D_LZJB, "lzjb match before dst start", b"\x01\x00\x05", None, 16)
dec_case(D_LZJB, "lzjb offset 0", b"\x02a\x00\x00", None, 16)
dec_case(D_LZJB, "lzjb match cut in half", b"\x02a\x00", None, 16)

# --- ZLE ---
for key in ("zeros8k", "text4k", "rand1k", "zero4k", "mixed64k", "text128k"):
    pl = P[key]
    comp = zle_compress(pl, 2 * len(pl) + 64)
    assert comp is not None
    dec_case(D_ZLE, "zle %s" % key, comp, pl, len(pl))
pl = P["zeros8k"]
comp = zle_compress(pl, 2 * len(pl) + 64)
dec_case(D_ZLE, "zle zeros8k dlen + 1 (input ends short)", comp, None, len(pl) + 1)
dec_case(D_ZLE, "zle zeros8k truncated half", comp[:len(comp) // 2], None, len(pl))
cut = comp[:len(comp) - 1]
if zle_decode(cut, len(pl)) is None:
    dec_case(D_ZLE, "zle zeros8k truncated by 1", cut, None, len(pl))
dec_case(D_ZLE, "zle literal run past input", b"\x05ab", None, 64)
dec_case(D_ZLE, "zle zero run past dst", b"\xff", None, 100)
dec_case(D_ZLE, "zle literal run past dst", b"\x07abcdefgh", None, 4)
dec_case(D_ZLE, "zle trailing input after full dst", b"\x02abc\x41", b"abc", 3)

# --- gzip (zlib) ---
for key in ("text4k", "mixed64k", "text128k", "zeros8k", "period", "run10k"):
    pl = P[key]
    for lvl in (1, 6, 9):
        if key in ("zeros8k", "period", "run10k") and lvl != 6:
            continue
        dec_case(D_GZIP, "gzip %s -%d" % (key, lvl), zlib_stream(pl, lvl), pl, len(pl))
for key in ("text4k", "rand1k", "text70k"):
    pl = P[key]
    dec_case(D_GZIP, "gzip %s stored" % key, zlib_stream(pl, 0), pl, len(pl))
for key in ("text4k", "period"):
    pl = P[key]
    dec_case(D_GZIP, "gzip %s fixed-huffman" % key, zlib_stream(pl, 6, 15, zlib.Z_FIXED), pl, len(pl))
pl = P["mixed64k"]
dec_case(D_GZIP, "gzip mixed64k rle", zlib_stream(pl, 6, 15, zlib.Z_RLE), pl, len(pl))
dec_case(D_GZIP, "gzip mixed64k huffman-only", zlib_stream(pl, 6, 15, zlib.Z_HUFFMAN_ONLY), pl, len(pl))
dec_case(D_GZIP, "gzip mixed64k 512-byte window", zlib_stream(pl, 9, 9), pl, len(pl))
dec_case(D_GZIP, "gzip empty", zlib_stream(b"", 6), b"", 0)
dec_case(D_GZIP, "gzip single byte", zlib_stream(b"a", 9), b"a", 1)
dec_case(D_GZIP, "gzip all-zero 4k", zlib_stream(P["zero4k"], 9), P["zero4k"], 4096)
c = zlib.compressobj(6)
pl = P["text4k"]
sync = c.compress(pl[:1000]) + c.flush(zlib.Z_SYNC_FLUSH) + c.compress(pl[1000:]) + c.flush()
dec_case(D_GZIP, "gzip sync-flush mid-stream (empty stored block)", sync, pl, len(pl))
good = zlib_stream(pl, 6)
dec_case(D_GZIP, "gzip text4k + ZFS sector padding", good + b"\0" * 20, pl, len(pl))
dec_case(D_GZIP, "gzip text4k dst roomy", good, pl, len(pl) + 512)
dec_case(D_GZIP, "gzip text4k dst one byte short", good, None, len(pl) - 1)
dec_case(D_GZIP, "gzip stored dst one byte short", zlib_stream(pl, 0), None, len(pl) - 1)
dec_case(D_GZIP, "gzip bad adler", good[:-1] + bytes([good[-1] ^ 1]), None, len(pl))
dec_case(D_GZIP, "gzip adler missing", good[:-4], None, len(pl))
dec_case(D_GZIP, "gzip truncated half", good[:len(good) // 2], None, len(pl))
dec_case(D_GZIP, "gzip bad fcheck", bytes([good[0], good[1] ^ 1]) + good[2:], None, len(pl))
dec_case(D_GZIP, "gzip fdict set", fix_fcheck(0x78, 0x20) + good[2:], None, len(pl))
dec_case(D_GZIP, "gzip cm 7", fix_fcheck(0x77, 0x80) + good[2:], None, len(pl))
dec_case(D_GZIP, "gzip cinfo 8", fix_fcheck(0x88, 0x80) + good[2:], None, len(pl))
dec_case(D_GZIP, "gzip slen 1", good[:1], None, len(pl))
dec_case(D_GZIP, "gzip block type 3", b"\x78\x01\x07" + b"\0" * 8, None, 64)
dec_case(D_GZIP, "gzip stored LEN/NLEN mismatch",
         b"\x78\x01\x01\x05\x00\x00\x00hello" + struct.pack(">I", zlib.adler32(b"hello")), None, 64)
dec_case(D_GZIP, "gzip stored LEN past input", b"\x78\x01\x01\x05\x00\xfa\xffhel", None, 64)
bw = BitWriter()
bw.bits(1, 1)
bw.bits(1, 2)                                   # BFINAL, fixed
fixed_lit(bw, 257)                              # length 3 ...
bw.huff(0, 5)                                   # ... distance 1, with nothing written yet
fixed_lit(bw, 256)
dec_case(D_GZIP, "gzip distance too far back", b"\x78\x01" + bw.done() + b"\0\0\0\1", None, 64)
bw = BitWriter()
bw.bits(1, 1)
bw.bits(1, 2)
fixed_lit(bw, 286)                              # a length symbol that never exists
dec_case(D_GZIP, "gzip fixed lit/len 286", b"\x78\x01" + bw.done() + b"\0" * 6, None, 64)
bw = BitWriter()
bw.bits(1, 1)
bw.bits(1, 2)
fixed_lit(bw, ord("x"))
fixed_lit(bw, 257)
bw.huff(30, 5)                                  # distance symbol 30 never exists
fixed_lit(bw, 256)
dec_case(D_GZIP, "gzip fixed distance 30", b"\x78\x01" + bw.done() + b"\0" * 6, None, 64)
bw = BitWriter()                                # dynamic, code-length code over-subscribed
bw.bits(1, 1)
bw.bits(2, 2)
bw.bits(0, 5)
bw.bits(0, 5)
bw.bits(15, 4)                                  # all 19 code-length lengths ...
for _ in range(19):
    bw.bits(1, 3)                               # ... of length 1: 19 codes in 2 slots
dec_case(D_GZIP, "gzip code-length code over-subscribed", b"\x78\x01" + bw.done() + b"\0" * 8, None, 64)
bw = BitWriter()                                # dynamic, lit/len code incomplete (two 2-bit codes)
bw.bits(1, 1)
bw.bits(2, 2)
bw.bits(0, 5)                                   # hlit 257
bw.bits(0, 5)                                   # hdist 1
bw.bits(14, 4)                                  # hclen 18: up to code-length symbol 1 (order slot 17)
cl = {0: 1, 2: 1}                               # code-length symbols 0 and 2, each a 1-bit code
order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
for s in order[:18]:
    bw.bits(cl.get(s, 0), 3)
# canonical: symbol 0 -> code 0, symbol 2 -> code 1. lens: 'a' and 256 get 2, the rest 0.
for i in range(257 + 1):
    v = 2 if i in (97, 256) else 0
    bw.huff(1 if v == 2 else 0, 1)
dec_case(D_GZIP, "gzip lit/len code incomplete", b"\x78\x01" + bw.done() + b"\0" * 8, None, 64)
bw = BitWriter()                                # dynamic, repeat-previous with nothing before it
bw.bits(1, 1)
bw.bits(2, 2)
bw.bits(0, 5)
bw.bits(0, 5)
bw.bits(0, 4)                                   # hclen 4: symbols 16, 17, 18, 0
for v in (1, 0, 0, 1):
    bw.bits(v, 3)                               # 16 -> code 1, 0 -> code 0
bw.huff(1, 1)                                   # symbol 16 first
bw.bits(0, 2)
dec_case(D_GZIP, "gzip repeat-previous at index 0", b"\x78\x01" + bw.done() + b"\0" * 8, None, 64)

# Dynamic blocks built by hand, each OTHERWISE VALID (a real payload and a correct Adler-32), so the
# only thing that can refuse a negative one is the code-completeness rule itself — a vector that
# also runs out of input proves nothing about that rule (a mutation that dropped it survived the
# first version of the vector above).
def canon(lens):
    """RFC 1951 §3.2.2 canonical codes for {symbol: length}."""
    bl = [0] * 16
    for v in lens.values():
        if v:
            bl[v] += 1
    nxt = [0] * 16
    code = 0
    for b in range(1, 16):
        code = (code + bl[b - 1]) << 1 if b > 1 else 0
        nxt[b] = code
    out = {}
    for s in sorted(lens):
        if lens[s]:
            out[s] = (nxt[lens[s]], lens[s])
            nxt[lens[s]] += 1
    return out


def dyn_stream(lit, nlit, dist, ndist, payload, plain):
    """BFINAL dynamic block + Adler-32. The code-length code gives symbols 0..7 three bits each
    (complete, and canonical code == symbol), so each length is written as itself."""
    bw = BitWriter()
    bw.bits(1, 1)
    bw.bits(2, 2)
    bw.bits(nlit - 257, 5)
    bw.bits(ndist - 1, 5)
    bw.bits(19 - 4, 4)                          # all 19 code-length lengths
    for s in [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]:
        bw.bits(3 if s < 8 else 0, 3)
    for i in range(nlit):
        bw.huff(lit.get(i, 0), 3)
    for i in range(ndist):
        bw.huff(dist.get(i, 0), 3)
    lc = canon(lit)
    dc = canon(dist)
    for kind, v in payload:
        c, n = (lc if kind == "L" else dc)[v]
        bw.huff(c, n)
    return b"\x78\x01" + bw.done() + struct.pack(">I", zlib.adler32(plain))


AAAA = [("L", 97), ("L", 257), ("D", 0), ("L", 256)]   # 'a', then length 3 at distance 1, EOB
dec_case(D_GZIP, "gzip lit/len code incomplete, payload valid",
         dyn_stream({97: 2, 256: 2}, 257, {}, 1, [("L", 97), ("L", 256)], b"a"), None, 64)
dec_case(D_GZIP, "gzip distance code incomplete (two 2-bit codes), payload valid",
         dyn_stream({97: 1, 256: 2, 257: 2}, 258, {0: 2, 1: 2}, 2, AAAA, b"aaaa"), None, 64)
dec_case(D_GZIP, "gzip distance code over-subscribed, payload valid",
         dyn_stream({97: 1, 256: 2, 257: 2}, 258, {0: 1, 1: 1, 2: 1}, 3, AAAA, b"aaaa"), None, 64)
dec_case(D_GZIP, "gzip single 1-bit distance code (allowed)",
         dyn_stream({97: 1, 256: 2, 257: 2}, 258, {0: 1}, 1, AAAA, b"aaaa"), b"aaaa", 4)
dec_case(D_GZIP, "gzip single 1-bit lit/len code: EOB only (allowed)",
         dyn_stream({256: 1}, 257, {}, 1, [("L", 256)], b""), b"", 0)
dec_case(D_GZIP, "gzip no end-of-block code",
         dyn_stream({97: 1, 98: 1}, 257, {}, 1, [("L", 97)], b"a"), None, 64)

# --- fuzz: hostile mutations of valid streams, decoded against guard pages --------------------------
fz = [(D_LZ4, "lz4", zfs_lz4_frame(lz4_cli_block(P["mixed64k"][:16384], 1)), 16384),
      (D_LZJB, "lzjb", lzjb_compress(P["mixed64k"][:16384], 40000), 16384),
      (D_ZLE, "zle", zle_compress(P["zeros8k"], 20000), 8192),
      (D_GZIP, "gzip dynamic", zlib_stream(P["mixed64k"][:16384], 6), 16384),
      (D_GZIP, "gzip fixed", zlib_stream(P["text4k"], 6, 15, zlib.Z_FIXED), 4096)]
for kind, nm, comp, cap in fz:
    add('    zt_fuzz(%d, "fuzz %s", %d, %d, 600, %s);' % (kind, nm, blob(comp), cap, h64(fnv1a(comp))))

# ------------------------------------------------------------------------------------------------
L = []
L.append("# GENERATED by scripts/check/zfs-codec-vectors.py — do not edit; regenerated on every run of")
L.append("# scripts/check/host-zfs-oracles.sh. Git-ignored (tests/zfscodec/gen/).")
L.append("")
L.append("fn zv_prng_seed() { return %s; }" % h64(PRNG_SEED))
L.append("fn zv_prng_len() { return %d; }" % PRNG_LEN)
L.append("fn zv_case_count() { return %d; }" % ncases)
L.append("")
CH = 4096
for i, b in enumerate(blobs):
    L.append("# blob %d: %d bytes" % (i, len(b)))
    L.append("fn zv_blob_%d(p) {" % i)
    for off in range(0, len(b), CH):
        piece = b[off:off + CH]
        L.append("    memcpy(p + %d, %s, %d);" % (off, cyr_lit(piece), len(piece)))
    L.append("    return %d;" % len(b))
    L.append("}")
L.append("")
L.append("# zv_blob(id, p): copy blob `id` to p; returns its length, or -1 for an unknown id.")
L.append("fn zv_blob(id, p) {")
for i in range(len(blobs)):
    L.append("    if (id == %d) { return zv_blob_%d(p); }" % (i, i))
L.append("    return 0 - 1;")
L.append("}")
L.append("")
L.append("# zv_blob_fnv(id): FNV-1a 64 of blob `id` as Python computed it — the embedding is verified")
L.append("# before any codec sees it (cyrius once corrupted >= 64 KB literals silently).")
L.append("fn zv_blob_fnv(id) {")
for i, b in enumerate(blobs):
    L.append("    if (id == %d) { return %s; }" % (i, h64(fnv1a(b))))
L.append("    return 0;")
L.append("}")
L.append("")
L.append("fn zv_run() {")
L.extend(cases)
L.append("    return 0;")
L.append("}")
os.makedirs(os.path.dirname(OUT), exist_ok=True)
tmp = OUT + ".tmp"
with open(tmp, "w") as f:
    f.write("\n".join(L) + "\n")
os.replace(tmp, OUT)
print("zfs-codec-vectors: %d cases, %d blobs (%d bytes) -> %s"
      % (ncases, len(blobs), sum(len(b) for b in blobs), os.path.relpath(OUT, ROOT)))
