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
#   WRITER (1.57.12 B3a)    ZLE compress / the ZLE decision / BP words / holes / space-map entries:
#                           Python written from OpenZFS 2.4.2 (zle.c, zio.c, spa.h, space_map.c) AND bytes
#                           OpenZFS wrote into the fixture pools (REAL_BPS, REAL_SMS below) — see that section.
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
import base64
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


# ================================================================================================
# 1.57.12 B3a — THE WRITER'S ENCODERS: kernel/core/zfs_codec.cyr zfs_zle_compress + zfs_cksum_words, and
# kernel/core/zfs_wenc.cyr (BP words, holes, the ZLE decision, space-map entries). Expected values from:
#   · zle_compress above (a port of OpenZFS zle.c) — and, on a REAL block, OpenZFS's own physical bytes;
#   · bp_words below, written from include/sys/spa.h (the blkptr layout comment, :120-180, and the BF64 accessors,
#     :386-560) — and REAL BPs OpenZFS 2.4.2 wrote (REAL_BPS): an encoder that agrees with this file but not with
#     OpenZFS fails on those;
#   · zio_decision below, from zio.c zio_write_compress (:1965-2035), zio_get_compression_max_size (:1783-1800) and
#     zio_roundup_alloc_size (:1775-1781) — and the real ZLE block (OpenZFS's psize and bytes);
#   · SmMap below, a port of space_map.c space_map_write_seg (:552-656) / space_map_write_intro_debug (:528-543),
#     run on a 0xA5-filled buffer so a byte the encoder should not write shows — and REAL space maps (REAL_SMS),
#     which re-encoded entry by entry must come back byte-identical;
#   · hashlib / the fletcher loops above for zfs_cksum_words, plus the checksums OpenZFS stored in REAL_BPS.
# Negative fields travel as u64 two's complement (the Cyrius side reads them as i64); s64() reads them back here.
# ================================================================================================
# Captured READ-ONLY on 2026-10-10 from the r3-3d0d98751b16-8dc65342 fixture's main.img (agnostank, txg 98;
# written by OpenZFS 2.4.2 on FreeBSD 15.1) with scripts/tool/zfs-damage.py's Pool reader. Each: (what, BP hex,
# physical block as base64(zlib) or None).
REAL_BPS = [
    ('MOS objset_phys: rootbp of the best uberblock, fletcher4, uncompressed, 3 DVAs',
     '0800000000000000001c030000000000080000000000000098320100000000000800000000000000e0870300000000000700070002070b800000000000000000000000000000000000000000000000006200000000000000af00000000000000c3cc7e35020000002f3c1bc57f080000da5bd5d2245e1000c5ac2e521d5e0915',
     None),
    ('MOS meta-dnode L1, lz4, 3 DVAs',
     '0800000000000000f81b030000000000080000000000000090320100000000000800000000000000d887030000000000ff0007000f070a810000000000000000000000000000000000000000000000006200000000000000af0000000000000084c476beac000000883a286fb139020007809c047b94b3037cc837568ae53824',
     None),
    ('agnostank objset_phys (ds_bp): 2 DVAs, fill 3050',
     '0800000000000000400f0300000000000800000000000000a02e010000000000000000000000000000000000000000000700070002070b800000000000000000000000000000000000000000000000003a00000000000000ea0b000000000000007ccf360d00000095d9e6db8c230000fc3443c0b5043300971aad9a38cee333',
     None),
    ('agnostank meta-dnode L5 (the 6-level ZPL meta-dnode), lz4',
     '0800000000000000300f0300000000000800000000000000902e01000000000000000000000000000000000000000000ff0007000f070a850000000000000000000000000000000000000000000000003a00000000000000ea0b000000000000151aae9b84000000eb7b8cb151e701007e408c77f4e48103bbd7ac0da69ff551',
     None),
    ('agnostank master node: 1 KiB ZAP, uncompressed in a 4 KiB DVA (ashift 12)',
     '0800000000000000080000000000000008000000000000000880010000000000000000000000000000000000000000000100010002071580000000000000000000000000000000000000000000000000040000000000000001000000000000001418d68213000000895f4a285d0b0000252f7068b1c603003372a1c2748ae900',
     (
      'eNpjZgCDhsO1qxkoB3n5RbmJOZlViSWZ+Xlk6C8tSbPIz8upJNf+5MTi1OLUvOLMksyyzBLSjUlJTUsszSkpLU4tKizNL0kkU396'
      'UX5pATkGQPUXFOVnpSaXkG4Ckvvzk7LI1g92PzkGoLqfGBNYUXhhrkHBnv5+JNiogMILdox3DAkJCiZevyIKz8XVxzXENT4w1DXU'
      'lTj9Sii8IH//ENJiXBXV/R6OQa7BDHQEAEdgTUw=')),
    ('agnostank file L0: 128 KiB uncompressed, 1 DVA',
     '000100000000000080040000000000000000000000000000000000000000000000000000000000000000000000000000ff00ff000207138000000000000000000000000000000000000000000000000009000000000000000100000000000000c212c66ffd3f0000cae25a6bdef802108bbc59828274d06a70b0ce15154782b2',
     None),
    ('agnostank file L0: lz4, psize 20 KiB',
     '280000000000000040250000000000000000000000000000000000000000000000000000000000000000000000000000ff0027000f0713800000000000000000000000000000000000000000000000000a00000000000000010000000000000042961d408f040000c94d885c809c2b00ecb3b19b1f5b901230cc33f91d4a8482',
     None),
    ('agnostank directory (fat ZAP) L1, fill 17',
     '080000000000000038450000000000000800000000000000680901000000000000000000000000000000000000000000ff0007000f0714810000000000000000000000000000000000000000000000000f0000000000000011000000000000004fba329ac4000000f0d50998af6d020075ce1004e291e30396d6d37ba29bf934',
     (
      'eNrt0f9PzHEcB/DX5z5Xn6umu+s+1aXNJ3VRJEcX59tdmXYnqWQ2ZH07c76sLyZRJz5DTomxMpGTaCZtaq24jFVsdDkXRsr3zVLm'
      'S+L6omvLq/svzOf58+P13PP9+QC4LAsUAAGB0hgB8EWwUOtGiMGDBycYoEBI0awvuPBAInQHvgp+exW88akUA0BJgEFoXgXwMyhs'
      'JFZzDAIXpKqtxUH1IjkEflS7TVXJlORKcOeBmgEhC9Pt4gbJ5s/5BICLbsOgdxgFidVnXp1XR9GGTWcbv5gUozm4YsX2qdP5Zh4L'
      'EcMieauBzMOL99fX2JQEBbEff1y6Klsh4Ue+nnx2eRQIfy0LzAALCru4NW/CcBCtstvXdEBHQfq1Fx2yN+30ufHTHVvWe+74Cf4h'
      'iDuc2KqbFV+IOCBjs8aupMBSBU0DlVraEX24KJSMfc6CPyC+jviXl8NvxqbdiDW6zN6ZQ64QsXaiMM0YK+lyrJyuD4+LEY0SC6FH'
      '5nw0I3X2m7tV7kfwRGH7QNSkUJCgyq9K83xLD8nLO2w3rctzwH8M+3MQR7Uk31ACaXfb5/lnQ5KegnHtb8vdFzO9t/Ureu7tVbXj'
      'FjML88cIICPsYjKq0+8oNltckzqtSRQInkwrS2/T0W6rd0R/zn5ahLoCeEwI8HHGRv39T+mIG/vqcvQeFJy1v6qPIZfTw82W2tSX'
      'oYOIB4BgQlgCsWzrvLhcxKnSpOrZ2FwT/tZnvOsb3Wvi1X2Q3tmJGD8eI3A+MKUt71EBYmPf/lvVBgrqBx2fWtWF3kENXeI1X2ub'
      'EG9nCUbkbDbGFwxmIR6f1IfJF1NA5gVHXSwx0flee/ulqrQWFuYIglmSYYFQJO7PWtJ/jOXbBevm9hofU2DL3XnqUEqBT0X2hfgJ'
      'zffX2KzEzT3OGX7azOJsbF76I+Hh7aUUXOg+Nc2vpYr28s2Sl+b3VSLeiJvHnPjkxe6SDMT69t2zI1+6QnPcrsTyRUGSfe/uhJhF'
      'Q18RB+DmiqmfLv5TuraIRRysuzKUvo2CPeYHxku5PbQp037cUdbYNkIIeTDJ5f9MciJw4cKFCxcuXLhw4fLP5S+g6hmt')),
    ('agnostank/sha256 file L0: sha256',
     '000100000000000040a70000000000000000000000000000000000000000000000000000000000000000000000000000ff00ff00020813800000000000000000000000000000000000000000000000001f000000000000000100000000000000b6a66dee15ce6a6e82bfbfd5c33b518b5223425d9e29839c919f8867e28ece95',
     None),
    ('agnostank/sha256 file L1: sha256, lz4',
     '080000000000000060a90000000000000800000000000000781501000000000000000000000000000000000000000000ff0007000f0813810000000000000000000000000000000000000000000000001f00000000000000020000000000000048c93aabddf1f63b8332b17938445cd3893d2265cbc1697f377bd8a47ecbaaff',
     (
      'eNpjYGBqMmRgBEJFh+XsDPxMDHz9/xn+MzBxCDdoMrAKy0syMIczfBVi2LYs953ouay8pv37rx62DuwOUnaKnafZPGfi/I70R33n'
      'pjYwCK+wBOnn4W9gkP0vuMNuy5xv2TPWijW5/wub/XV+nr/g27sXrx2xEixZIHkid20+UCETw/9RMKLByQCGUTAKRsEoGAWjYBSM'
      'glEwCkbBKBgF9AAAhDcssg==')),
    ('agnostank/sha512 file L0: sha512',
     '0001000000000000b0ab0000000000000000000000000000000000000000000000000000000000000000000000000000ff00ff00020b1380000000000000000000000000000000000000000000000000210000000000000001000000000000006d3990fee13d510009e8ce1d7550541f992d6cb27f77014380561161918fce8e',
     None),
    ('agnostank/sha512 file L1: sha512, lz4',
     '0800000000000000b0ad0000000000000800000000000000901701000000000000000000000000000000000000000000ff0007000f0b138100000000000000000000000000000000000000000000000021000000000000000200000000000000871224330d84e1215e61d8bbd80d92ae89b487737668f82340b3fd9e729dcf46',
     (
      'eNpjYGBqMmRgBELFDavZGfiZGPj6/zP8Z2DiFm7QZGAVVpRkYA5n+CrEkGs54d9D20AGzhfnZEsDQuRn6uZsqi9ndG4IE0yc2H+u'
      'r4FBeI0lSD8PfwOD7H/BSRLP+GYyetn92cO6VfunHyP35y3Bd1kbl/D26MaFic4oygcqZGL4PwpGNDgZwDAKRsEoGAWjYBSMglEw'
      'CkbBKBgFo4AeAACBuiVa')),
    ('agnostank/zle runs.bin L0 blk 0: ZLE, psize 12 KiB',
     '180000000000000038870000000000000000000000000000000000000000000000000000000000000000000000000000ff0017000e07138000000000000000000000000000000000000000000000000019000000000000000100000000000000c3d992e3900400002cfba497ab7e2100c991ccc3f188008b06d03226d43c2920',
     (
      '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')),
    ('agnostank/off file L0: recordsize 4K, compression off',
     '0800000000000000c889000000000000000000000000000000000000000000000000000000000000000000000000000007000700020713800000000000000000000000000000000000000000000000001b000000000000000100000000000000e2b2546b0a0200008d51b8d0001c04006d2a9d98bd587e055cca166b938e4485',
     None),
]

# Real space maps OpenZFS 2.4.2 wrote (same capture as REAL_BPS; main.img is ashift 12, ashift9.img ashift 9):
# (what, data block size, the map's smp_length bytes as base64(zlib)).
REAL_SMS = [
    ('main: log space map of txg 98 (MOS object 185), two-word entries', 131072, (
        'eNpLYgABlglAgh2IDzgwMIEEGmD8Bcyo/BNQfhKavgVgPkJdhxsqfwOUD9UHEjcHi7czg0XQzfvQxgzTLw7iT4Cow9CfYcSIVf8M'
        'BkYU+3dwofIfoPFXGDKi2OcBMRfDvgvS2N0rII3q3g3SyO7lgKtb0YgangfamLCq29CGGn4vNiGHHwdIPB4sjhJ+YP38EHOZUfRL'
        'tKPyHRB8exA/AE1+BUp4I+xbgBLeCPcm8KOFtxScD3ZPhSGq/AU0/g8EH+weDiNU+QSU+EC4h0MGu/8fSKH6x0IalZ8gjer/AjT5'
        'EyjxxwMX9+hAto8H7v+MZuzqGYwZsaqP0GDEqj5DBrv5AhwQ8wE6C3X3')),
    ("main: metaslab 0's space map (MOS object 136), one-word entries", 131072, (
        'eNpNkrtKA2EQhWfjxt24IYKJuRSKoqBlbBRRoigWIgFfwMZakBTWzhNIFGPaYETEVnwBGyuxEbGIzyGC4GXmM2SL/fbMPyxn5vxp'
        '+XtCzYg/eUmMCXWRKU7mYNXegSyil+EK3IY79NWN6+Eu9bPQeQ4vYBdeO4dujBm5jQb8NCNNeZsmMAfHYNGQ1opxlDkCqeBnws9l'
        '2jgs894hC8y9is9T/LSMG3JvPlLyGXn9G2ZjZy72/xeMJSmha5xvGouyhd6DB/DQOCsN44i04wH/TdES85GHLkHfd6B1NHvU48jr'
        'ncj30TVm1PdZYC+JtEP3eQU77Nv7A7mDX1DM16Rc4vuBOR/RT7Hv6Rn9Al/hG/29eMDH73x5/I/DsuehM56TVqn7fcsq9025Z+p5'
        'Bdpi/g/PR8lHc7AM1yD7V99/oA30kTHSE89DPY9K32+NfuZW5tQeOf73vZve7+usff0AhQhIWQ==')),
    ('ashift9: log space map of txg 23 (MOS object 259), two-word entries', 131072, (
        'eNptkTkOwjAQRR2xKFTgKgVwAxAS0CcUrC3LWSgonBvkCNwBJBBQpIMO0cJNoCG2A8MfYsmW3ng8M//bE3rlVXKUkx37SnxWSfMt'
        'Zc/mRcnh6HjBxj/ZcZ3Y1GkRFzVfUvZYv4VyoN8kdDL71Wzet1+X2NQZEJt+PVvnr99coL6xzNZXFaivI1BfX6C+QP7qc3VcR+IH'
        '+Od+6y/JH8Mr5qcizmmOWP6a3W+JXc0HVu/M3l9V9rwz8J/m3ZK/hvfsP07EOasb81/svhk6MG8nxHpBiO9H8J8071Rm+7sRqHfH'
        '/vMo0L+7i/nPCt43JPrblljPl/h+mPIbCUhm1A==')),
    ("ashift9: metaslab 0's space map (MOS object 136), one-word entries", 131072, (
        'eNpjZQABlgYRBghgZxAD04wMqmBal0EPTHNB1TEyJEDl86F0PZTugtJ9UHMmQ/lzoPRmKL0dYhLHbjDNzHCLA0TzcjwE00IMHwSQ'
        '7JsgDLQRYjPEXcwN+hCHNphA+Y5gmq0hFEyLQ1VLMzALQhQqCELs0QHTYgxGgkjqJjA2QP3TAPVPA9QfDVB/NED90TAHat8eSHg0'
        'PAG7k7MB4l7Ghj9gmqmBAWw+AJcHHiw=')),
]


def s64(v):
    v &= M64
    return v - (1 << 64) if v >> 63 else v


def unz(parts):
    return None if parts is None else zlib.decompress(base64.b64decode("".join(parts)))


# --- block pointers ---------------------------------------------------------------------------------
def bp_fields(raw):
    """Decode a plain written BP (spa.h layout) into the fields zfs_wenc.cyr encodes from."""
    w = struct.unpack("<16Q", raw)
    prop = w[6]
    assert (prop >> 39) & 1 == 0 and prop >> 61 == 4, "not a plain little-endian non-embedded BP"   # E 0; X D 0, B 1
    assert w[7] == 0 and w[8] == 0 and w[9] == 0, "blk_prop2 / blk_pad / physical birth set"
    dvas = []
    for d in range(3):
        w0, w1 = w[2 * d], w[2 * d + 1]
        if w0 == 0 and w1 == 0:
            continue
        assert len(dvas) == d and w1 >> 63 == 0 and (w0 >> 24) & 0xFF == 0 and w0 >> 56 == 0
        dvas.append(((w0 & 0xFFFFFF) << 9, (w0 >> 32) & 0xFFFFFF, (w1 & (M64 >> 1)) << 9))
    return dict(dvas=dvas, lsize=((prop & 0xFFFF) + 1) << 9, psize=(((prop >> 16) & 0xFFFF) + 1) << 9,
                comp=(prop >> 32) & 0x7F, ck=(prop >> 40) & 0xFF, ty=(prop >> 48) & 0xFF, lv=(prop >> 56) & 0x1F,
                birth=w[10], fill=w[11], cks=list(w[12:16]))


def ot_valid(ty):
    """DMU_OT_IS_VALID (dmu.h:124-126): a legacy type < DMU_OT_NUMTYPES (54, dmu.h:251), or a DMU_OTN_* type (bit 7)
    whose byteswap, bits 0-4, is < DMU_BSWAP_NUMFUNCS (10, dmu.h:104). zfs_blkptr_verify refuses any other TYPE, holes
    included (zio.c:1171), and OpenZFS runs it with BLK_VERIFY_HALT on every child of every block it writes."""
    if not 0 <= ty < 256:
        return False
    return (ty & 0x1F) < 10 if ty & 0x80 else ty < 54


def bp_words(f):
    """The 16 words of a written BP from its fields (spa.h DVA_SET_* / BP_SET_*), or None where zfs_wenc.cyr refuses."""
    w = [0] * 16
    for d, (asize, vdev, off) in enumerate(f["dvas"]):
        asize, vdev, off = s64(asize), s64(vdev), s64(off)
        if asize <= 0 or asize % 512 or (asize >> 9) >= (1 << 24) or not 0 <= vdev < (1 << 24):
            return None
        if off < 0 or off % 512:
            return None
        w[2 * d] = (vdev << 32) | (asize >> 9)              # DVA_SET_VDEV (32, 24 bits), DVA_SET_ASIZE (SB 0, 24, 9, 0)
        w[2 * d + 1] = off >> 9                             # DVA_SET_OFFSET (SB 0, 63, 9, 0); gang 0
    ls, ps = s64(f["lsize"]), s64(f["psize"])
    comp, ck, ty, lv = s64(f["comp"]), s64(f["ck"]), s64(f["ty"]), s64(f["lv"])
    if not (512 <= ls <= (1 << 24) and ls % 512 == 0):     # SPA_MAXBLOCKSIZE
        return None
    if not (512 <= ps <= ls and ps % 512 == 0):
        return None
    if not (0 <= comp < 17 and 0 <= ck < 15 and ot_valid(ty) and 0 <= lv < 32):
        return None
    prop = (ls >> 9) - 1                                    # BP_SET_LSIZE: SB 0, 16, 9, 1
    prop |= ((ps >> 9) - 1) << 16                           # BP_SET_PSIZE: SB 16, 16, 9, 1
    prop |= comp << 32                                      # BP_SET_COMPRESS: 32, 7
    prop |= ck << 40                                        # BP_SET_CHECKSUM: 40, 8
    prop |= ty << 48                                        # BP_SET_TYPE: 48, 8
    prop |= lv << 56                                        # BP_SET_LEVEL: 56, 5
    prop |= 1 << 63                                         # BP_SET_BYTEORDER(ZFS_HOST_BYTEORDER = 1)
    w[6] = prop
    w[10] = f["birth"] & M64                                # BP_SET_BIRTH(T, T): logical T, physical stored 0
    w[11] = f["fill"] & M64
    w[12:16] = [c & M64 for c in f["cks"]]
    return w


def hole_words(lsize, ty, lv, birth):
    """BP_ZERO, then (hole_birth) BP_SET_LSIZE / TYPE / LEVEL and BP_SET_BIRTH(birth, 0) — dnode_sync.c:156-170."""
    lsize, ty, lv, birth = s64(lsize), s64(ty), s64(lv), s64(birth)
    if birth == 0:
        return [0] * 16
    if birth < 0 or not (512 <= lsize <= (1 << 24) and lsize % 512 == 0) or not ot_valid(ty) or not 0 <= lv < 32:
        return None
    w = [0] * 16
    w[6] = ((lsize >> 9) - 1) | (ty << 48) | (lv << 56)
    w[10] = birth
    return w


BP_RECS = []          # 40-u64 records; one blob, one case per record (zt_bp in tests/zfscodec/zfscodec.cyr)


def bp_case(name, kind, f):
    expect = bp_words(f) if kind == 0 else hole_words(f["lsize"], f["ty"], f["lv"], f["birth"])
    dv = list(f.get("dvas", []))
    r = [kind, len(dv)]
    for a, v, o in dv + [(0, 0, 0)] * (3 - len(dv)):
        r += [a & M64, v & M64, o & M64]
    r += [f["lsize"] & M64, f.get("psize", 0) & M64, f.get("comp", 0) & M64, f.get("ck", 0) & M64, f["ty"] & M64,
          f["lv"] & M64, f["birth"] & M64, f.get("fill", 0) & M64]
    r += [c & M64 for c in f.get("cks", [0, 0, 0, 0])]
    r += [0 if expect is not None else M64]
    r += expect if expect is not None else [0] * 16
    assert len(r) == 40
    BP_RECS.append((name, struct.pack("<40Q", *r)))
    return expect


# (1) REAL: OpenZFS's own bytes — decode with this file, re-encode with zfs_wenc.cyr, must be byte-identical; and the
# checksum OpenZFS stored must be zfs_cksum_words' over the physical block where it was captured
for what, hx, z in REAL_BPS:
    raw = bytes.fromhex(hx)
    f = bp_fields(raw)
    assert bp_words(f) == list(struct.unpack("<16Q", raw)), "this file's encoder disagrees with OpenZFS: " + what
    bp_case("bp real: " + what, 0, f)
    phys = unz(z)
    if phys is not None:
        assert len(phys) == f["psize"]
        want = {7: fletcher4, 8: sha256_words, 11: sha512_256_le_words}[f["ck"]](phys)
        assert want == f["cks"], "the reference checksum disagrees with OpenZFS's: " + what
        sum_case(20 + f["ck"], "cksum real (ck %d): %s" % (f["ck"], what), blob(phys), phys, 0, f["cks"])

# (2) synthetic, every field at random across its whole range (splitmix64 — deterministic)
_g = SplitMix(0xB3A0B9E5)
for i in range(48):
    nd = 1 + _g.below(3)
    dv = [((1 + _g.below((1 << 24) - 1)) << 9, _g.below(1 << 24) if i % 3 else 0, _g.below(1 << 54) << 9)
          for _ in range(nd)]
    ls = (1 + _g.below(1 << 15)) << 9
    ps = (1 + _g.below(ls >> 9)) << 9
    ty = _g.below(256)
    while not ot_valid(ty):                                 # every VALID type, legacy and DMU_OTN_*
        ty = _g.below(256)
    f = dict(dvas=dv, lsize=ls, psize=ps, comp=_g.below(17), ck=_g.below(15), ty=ty, lv=_g.below(32),
             birth=_g.below(1 << 63), fill=_g.next(), cks=[_g.next() for _ in range(4)])
    assert bp_case("bp random %d (%d DVA)" % (i, nd), 0, f) is not None
# the edges of every field
EDGE = dict(dvas=[(512, 0, 0)], lsize=512, psize=512, comp=2, ck=7, ty=19, lv=0, birth=1, fill=1, cks=[1, 2, 3, 4])
for nm, ch in [("max sizes 16 MiB", dict(lsize=1 << 24, psize=1 << 24)),
               ("max asize, max vdev, max offset", dict(dvas=[(((1 << 24) - 1) << 9, (1 << 24) - 1, ((1 << 54) - 1) << 9)])),
               ("three DVAs, level 31, type 0xE9 (the last valid), comp 16, cksum 14", dict(dvas=[(4096, 0, 8192), (4096, 0, 1 << 30), (8192, 0, 1 << 40)], lv=31, ty=0xE9, comp=16, ck=14)),
               ("type 53 (the last legacy type)", dict(ty=53)), ("type 0xC4 (DMU_OTN_ZAP_METADATA)", dict(ty=0xC4)),
               ("type 0x80 (DMU_OTN_UINT8_DATA)", dict(ty=0x80)), ("type 0x89 (byteswap 9, the last)", dict(ty=0x89)),
               ("birth and fill all ones but the sign", dict(birth=M64 >> 1, fill=M64))]:
    f = dict(EDGE)
    f.update(ch)
    assert bp_case("bp edge: " + nm, 0, f) is not None
for nm, ch in [("lsize 0", dict(lsize=0)), ("lsize 513", dict(lsize=513)), ("lsize 16 MiB + 512", dict(lsize=(1 << 24) + 512, psize=512)),
               ("psize > lsize", dict(psize=1024)), ("psize 0", dict(psize=0)), ("comp 17", dict(comp=17)),
               ("cksum 15", dict(ck=15)), ("type 256", dict(ty=256)), ("level 32", dict(lv=32)), ("level -1", dict(lv=-1)),
               ("type 54 (DMU_OT_NUMTYPES)", dict(ty=54)), ("type 127", dict(ty=127)), ("type 0x8A (byteswap 10)", dict(ty=0x8A)),
               ("type 0x9F", dict(ty=0x9F)), ("type 0xFF", dict(ty=0xFF)), ("type 0xCA (metadata, byteswap 10)", dict(ty=0xCA)),
               ("type 0x184 (a valid DMU_OTN_* pattern past 8 bits)", dict(ty=0x184)),
               ("asize 0", dict(dvas=[(0, 0, 0)])), ("asize 511", dict(dvas=[(511, 0, 0)])),
               ("asize 2^24 sectors", dict(dvas=[(1 << 33, 0, 0)])), ("asize -512", dict(dvas=[(-512, 0, 0)])),
               ("vdev 2^24 (SM_NO_VDEVID)", dict(dvas=[(512, 1 << 24, 0)])), ("vdev -1", dict(dvas=[(512, -1, 0)])),
               ("offset 511", dict(dvas=[(512, 0, 511)])), ("offset -512", dict(dvas=[(512, 0, -512)])),
               ("third DVA bad", dict(dvas=[(512, 0, 0), (512, 0, 4096), (512, 0, 100)]))]:
    f = dict(EDGE)
    f.update(ch)
    assert bp_case("bp refused: " + nm, 0, f) is None
# holes
for nm, (ls, ty, lv, bi) in [("birth 0: BP_ZERO", (131072, 19, 0, 0)),
                             ("L0 data hole with birth", (131072, 19, 0, 1234)),
                             ("L2 indirect hole with birth", (131072, 20, 2, 99)),
                             ("dnode block hole, birth 2^62", (16384, 10, 0, 1 << 62)),
                             ("birth 0 with nonsense fields is still BP_ZERO", (513, 999, 99, 0)),
                             ("DMU_OTN_ZAP_METADATA hole with birth", (16384, 0xC4, 0, 7)),
                             ("type 53 hole with birth", (512, 53, 0, 7))]:
    assert bp_case("bp hole: " + nm, 1, dict(lsize=ls, ty=ty, lv=lv, birth=bi)) is not None
for nm, (ls, ty, lv, bi) in [("lsize 0", (0, 19, 0, 5)), ("lsize 1000", (1000, 19, 0, 5)), ("type 256", (512, 256, 0, 5)),
                             ("type 54", (512, 54, 0, 5)), ("type 0x8A", (512, 0x8A, 0, 5)), ("type 0x9F", (512, 0x9F, 0, 5)),
                             ("type 0x184", (512, 0x184, 0, 5)),
                             ("level 32", (512, 19, 32, 5)), ("birth -1", (512, 19, 0, -1))]:
    assert bp_case("bp hole refused: " + nm, 1, dict(lsize=ls, ty=ty, lv=lv, birth=bi)) is None
_bp_blob = blob(b"".join(r for _n, r in BP_RECS))
for k, (nm, _r) in enumerate(BP_RECS):
    add('    zt_bp("%s", %d, %d);' % (name_ok(nm), _bp_blob, k))

# --- checksum dispatch (zfs_cksum_words): kind 20 + ck --------------------------------------------
for ln in (0, 4, 512, 4096, 131072):
    d = PRNG[:ln]
    sum_case(27, "cksum dispatch 7 (fletcher4) prng %d" % ln, SRC_PRNG, d, 0, fletcher4(d))
    sum_case(28, "cksum dispatch 8 (sha256) prng %d" % ln, SRC_PRNG, d, 0, sha256_words(d))
    sum_case(31, "cksum dispatch 11 (sha512 = SHA-512/256, LE words) prng %d" % ln, SRC_PRNG, d, 0, sha512_256_le_words(d))
    if ln % 16 == 0:
        sum_case(26, "cksum dispatch 6 (fletcher2) prng %d" % ln, SRC_PRNG, d, 0, fletcher2(d))
sum_case(27, "cksum dispatch 7: length not a multiple of 4", blob(b"abcdef"), b"abcdef", -1, None)
for ck in (0, 1, 2, 3, 4, 5, 9, 10, 12, 13, 14, 15, 99):
    sum_case(20 + ck, "cksum dispatch %d: not implemented (-2)" % ck, blob(b"abcd"), b"abcd", -2, None)

# --- ZLE compressor (zfs_zle_compress) ---------------------------------------------------------------
def zle_case(name, src, dlen):
    out = zle_compress(src, dlen)
    if out is not None:
        assert zle_decode(out, len(src)) == src, "the Python ZLE port does not round-trip: " + name
        add('    zt_zlec("%s", %d, %d, %d, %d);' % (name_ok(name), blob(src), dlen, blob(out), len(out)))
    else:
        add('    zt_zlec("%s", %d, %d, -1, -1);' % (name_ok(name), blob(src), dlen))
    return out


ZIN = [("zeros8k", P["zeros8k"]), ("text4k", P["text4k"]), ("rand1k", P["rand1k"]),
       ("mixed16k", P["mixed64k"][:16384]), ("zero4k", P["zero4k"]), ("one byte", b"\x07"), ("one zero", b"\0"),
       ("zeros 191", b"\0" * 191), ("zeros 192", b"\0" * 192), ("zeros 193", b"\0" * 193), ("zeros 385", b"\0" * 385),
       ("literal 63", bytes(range(1, 64))), ("literal 64", bytes(range(1, 65))), ("literal 65", bytes(range(1, 66))),
       ("literal 129", bytes((i % 255) + 1 for i in range(129))),
       ("lone zeros stay literal", b"a\0b\0c\0d\0e\0f\0g" * 20), ("zero pairs end a literal", b"ab\0\0cd\0\0\0ef" * 30),
       ("ends in one zero", b"xyz\0"), ("ends in a lone byte after zeros", b"\0" * 300 + b"q"),
       ("zero then literal at the 64 boundary", b"\0" + bytes(range(1, 70)) + b"\0" * 7)]
for nm, src in ZIN:
    full = zle_compress(src, 2 * len(src) + 64)
    assert full is not None
    zle_case("zle compress %s, room" % nm, src, 2 * len(src) + 64)
    zle_case("zle compress %s, OpenZFS floor (s_len - s_len/8)" % nm, src, len(src) - (len(src) >> 3))
    for dl in sorted({len(full) - 1, len(full), len(full) + 1, len(full) + 63, len(full) + 64}):
        if dl >= 0:
            zle_case("zle compress %s, dlen %d (output %d)" % (nm, dl, len(full)), src, dl)
zle_case("zle compress empty input", b"", 16)
zle_case("zle compress, dlen 0", b"abc", 0)
zle_case("zle compress, dlen 1", b"abc", 1)
zle_case("zle compress, dlen 2: one zero run", b"\0" * 9, 2)

# --- the ZLE decision (zfs_wcomp) --------------------------------------------------------------------
def zio_decision(src, ma):
    lsize = len(src)
    if not any(src):
        return 0, b""                                       # abd_cmp_zero -> psize 0, a hole
    c = zle_compress(src, lsize - (lsize >> 3))             # zio_get_compression_max_size: ZLE skips the gcd round
    if c is None:
        return lsize, b""                                   # s_len: compress OFF
    r = ma if len(c) <= ma else -(-len(c) // ma) * ma       # zio_roundup_alloc_size
    if r >= lsize:
        return lsize, b""
    return r, c + bytes(r - len(c))                         # abd_zero_off of the tail


def wcomp_case(name, src, ma):
    ps, out = zio_decision(src, ma)
    add('    zt_wcomp("%s", %d, %d, %d, %d);' % (name_ok(name), blob(src), ma, blob(out) if 0 < ps < len(src) else -1, ps))
    return ps


def bp_array(seed, n, used):
    """An indirect block's shape: `used` plausible BPs, then holes (what ZLE meets in real metadata)."""
    g = SplitMix(seed)
    out = bytearray(n)
    for k in range(used):
        w = [g.below(1 << 30) << 9 | 8, g.below(1 << 40) >> 9, 0, 0, 0, 0,
             0x8007020000000000 | (19 << 48) | g.below(256), 0, 0, 0, 1 + g.below(1000), 1] + [g.next() for _ in range(4)]
        struct.pack_into("<16Q", out, 128 * k, *[x & M64 for x in w])
    return bytes(out)


WIN = [("all zero 16K", b"\0" * 16384), ("all zero 512", b"\0" * 512), ("text4k", P["text4k"]),
       ("zeros8k", P["zeros8k"]), ("mixed16k", P["mixed64k"][:16384]), ("512 B, one byte set", b"\x01" + b"\0" * 511),
       ("4K, one byte set", b"\0" * 4095 + b"\x01"), ("16K, one byte set", b"\x01" + b"\0" * 16383),
       ("L1 128K, 3 BPs", bp_array(11, 131072, 3)), ("L1 128K, 700 BPs", bp_array(12, 131072, 700)),
       ("L1 128K, 1024 BPs", bp_array(13, 131072, 1024)), ("16K, 7/8 + 1 literal", bytes(range(1, 256)) * 57 + b"\0" * 1849)]
for nm, src in WIN:
    for sh in (9, 12, 13):
        wcomp_case("zle decision %s, ashift %d" % (nm, sh), src, 1 << sh)
# the floor's edge, both sides: the smallest literal count whose ZLE output no longer fits s_len - s_len/8
_floor_hit = 0
for lit in range(3500, 3700, 3):
    src = bytes((i % 255) + 1 for i in range(lit)) + b"\0" * (4096 - lit)
    c = zle_compress(src, 4096 - 512)
    if c is None and _floor_hit == 0:
        _floor_hit = 1
        wcomp_case("zle decision 4K at the 12.5%% floor, %d literals (OFF)" % lit, src, 512)
        src2 = bytes((i % 255) + 1 for i in range(lit - 3)) + b"\0" * (4096 - lit + 3)
        assert zle_compress(src2, 4096 - 512) is not None
        wcomp_case("zle decision 4K under the floor, %d literals (ZLE)" % (lit - 3), src2, 512)
assert _floor_hit == 1


# the floor's EXACT edge and the rounding's exact multiples (design § k.7; the 3-literal steps above never land on
# them). Shape: p nonzero bytes, a zero run, 64 nonzero bytes — the output ends in a FULL literal chunk, the only way
# zle_compress fills d_len to the byte (a literal needs n = 64 bytes of room, zle.c:58-60), and p (with it the zero
# run) is varied ONE byte at a time until the output is exactly the length wanted: the output length never falls as p
# grows (+1 per literal byte, +1 per 64 of them, -1 per 192 zeros fewer), so a bisection finds the first p that
# reaches it, and that p must hit it exactly.
def zle_shape(lsize, want):
    def mk(p):
        return bytes((i % 255) + 1 for i in range(p)) + b"\0" * (lsize - p - 64) + bytes(range(1, 65))

    lo, hi = 0, lsize - 64
    while lo < hi:
        mid = (lo + hi) // 2
        if len(zle_compress(mk(mid), 2 * lsize)) >= want:
            hi = mid
        else:
            lo = mid + 1
    src = mk(lo)
    assert len(zle_compress(src, 2 * lsize)) == want, "no shape compresses %d bytes to exactly %d" % (lsize, want)
    return src


for ls in (4096, 16384):
    dl = ls - (ls >> 3)
    src = zle_shape(ls, dl)                                 # exactly d_len: fits (c_len > d_len is the test, zio_compress.c:148)
    assert zle_compress(src, dl) is not None and zle_compress(src, dl - 1) is None
    zle_case("zle compress %dK, output exactly s_len - s_len/8" % (ls >> 10), src, dl)
    for sh in (9, 12, 13):
        wcomp_case("zle decision %dK, output exactly s_len - s_len/8, ashift %d" % (ls >> 10, sh), src, 1 << sh)
    src = zle_shape(ls, dl + 1)                             # one byte over: compression OFF
    assert zle_compress(src, dl) is None and zle_compress(src, dl + 1) is not None
    zle_case("zle compress %dK, output s_len - s_len/8 + 1" % (ls >> 10), src, dl)
    for sh in (9, 12, 13):
        wcomp_case("zle decision %dK, output s_len - s_len/8 + 1 (OFF), ashift %d" % (ls >> 10, sh), src, 1 << sh)
assert zio_decision(zle_shape(16384, 14336), 512)[0] == 14336 and zio_decision(zle_shape(16384, 14337), 512)[0] == 16384
# outputs of exactly 2 and 3 allocation units: zio_roundup_alloc_size keeps an exact multiple as it is
for ls, ma in ((4096, 512), (16384, 4096)):
    for k in (2, 3):
        src = zle_shape(ls, k * ma)
        for sh in (9, 12, 13):
            wcomp_case("zle decision %dK, output exactly %d x %d, ashift %d" % (ls >> 10, k, ma, sh), src, 1 << sh)
# (3) REAL: OpenZFS's own ZLE block — decompress it, and zfs_wcomp must reproduce OpenZFS's psize AND bytes
for what, hx, z in REAL_BPS:
    f = bp_fields(bytes.fromhex(hx))
    phys = unz(z)
    if f["comp"] != 14 or phys is None:
        continue
    plain = zle_decode(phys, f["lsize"])
    assert plain is not None
    ps, out = zio_decision(plain, 4096)                     # main.img is ashift 12
    assert ps == f["psize"] and out == phys, "this file's ZLE decision disagrees with OpenZFS: " + what
    wcomp_case("zle decision real (OpenZFS's psize and bytes): " + what, plain, 4096)
    zle_case("zle compress real block at OpenZFS's d_len: " + what, plain, f["lsize"] - (f["lsize"] >> 3))

# --- space maps (zfs_sm_dbg / zfs_sm_put / zfs_sm_seg) ----------------------------------------------
class SmMap:
    """space_map_write_seg + the intro debug entry, on a cap-byte buffer pre-filled with 0xA5."""

    def __init__(self, blksz, cap):
        self.blksz, self.cap, self.len = blksz, cap, 0
        self.b = bytearray(b"\xa5" * cap)

    def word(self, at, w):
        struct.pack_into("<Q", self.b, at, w & M64)
        return at + 8

    def put(self, w):
        if self.len + 8 > self.cap:
            return -1
        self.len = self.word(self.len, w)
        return self.len

    def seg(self, ty, start, size, vdev, words):
        ty, start, size, vdev, words = s64(ty), s64(start), s64(size), s64(vdev), s64(words)
        if self.blksz < 16 or self.blksz % 8 or not 0 <= ty <= 1 or start < 0 or size <= 0:
            return -1
        if words == 1:
            rmax = 1 << 15                                  # SM_RUN_MAX
            if start >= (1 << 47) or size > (1 << 47) - start:
                return -1
        elif words == 2:
            rmax = 1 << 36                                  # SM2_RUN_MAX
            if not 0 <= vdev < (1 << 24) or size - 1 > (M64 >> 1) - start:
                return -1
        else:
            return -1
        ln = self.len               # a refused op leaves the caller's length where it was (its bytes stay written)
        while size:
            if words == 2 and (ln // 8 + 1) % (self.blksz // 8) == 0:   # next_entry == block_end
                if ln + 8 > self.cap:
                    return -1
                ln = self.word(ln, 2 << 62)                 # SM_DEBUG_PREFIX, act = syncpass = txg = 0
                continue
            r = min(size, rmax)
            if ln + 8 * words > self.cap:
                return -1
            if words == 1:
                ln = self.word(ln, (start << 16) | (ty << 15) | (r - 1))        # SM_OFFSET / SM_TYPE / SM_RUN_ENCODE
            else:
                ln = self.word(ln, (3 << 62) | ((r - 1) << 24) | vdev)          # SM2_PREFIX / SM2_RUN / SM2_VDEV
                ln = self.word(ln, (ty << 63) | start)                          # SM2_TYPE / SM2_OFFSET
            start += r
            size -= r
        self.len = ln
        return ln


def sm_dbg(act, pss, txg):
    act, pss, txg = s64(act), s64(pss), s64(txg)
    if not (0 <= act <= 1 and 0 <= pss < 1024 and 0 <= txg < (1 << 50)):
        return None
    return (2 << 62) | (act << 60) | (pss << 50) | txg       # SM_PREFIX / ACTION / SYNCPASS / TXG _ENCODE


def sm_case(name, blksz, cap, ops):
    """ops: ('put', w) | ('dbg', act, pass, txg) | ('seg', ty, start, size, vdev, words)"""
    m = SmMap(blksz, cap)
    recs = []
    for op in ops:
        if op[0] == "put":
            rc = m.put(op[1])
            recs.append([1, op[1] & M64, 0, 0, 0, 0, 0, rc & M64])
        elif op[0] == "dbg":
            w = sm_dbg(*op[1:])
            rc = -1 if w is None else m.put(w)
            recs.append([3, op[1] & M64, op[2] & M64, op[3] & M64, 0, 0, 0, rc & M64])
        else:
            rc = m.seg(*op[1:])
            recs.append([2] + [x & M64 for x in op[1:]] + [0, rc & M64])
    hdr = struct.pack("<4Q", blksz, cap, len(recs), m.len)
    body = b"".join(struct.pack("<8Q", *r) for r in recs)
    add('    zt_sm("%s", %d);' % (name_ok(name), blob(hdr + body + bytes(m.b))))
    return m


# (4) REAL maps: decode every entry (space_map.h) and re-encode it as one op; the result must be OpenZFS's bytes
for what, bs, z in REAL_SMS:
    data = unz(z)
    ops, i = [], 0
    while i < len(data):
        e = struct.unpack_from("<Q", data, i)[0]
        i += 8
        if e >> 62 == 2:
            ops.append(("dbg", (e >> 60) & 3, (e >> 50) & 0x3FF, e & ((1 << 50) - 1)))
        elif e >> 63 == 0:
            ops.append(("seg", (e >> 15) & 1, (e >> 16) & ((1 << 47) - 1), (e & 0x7FFF) + 1, 0, 1))
        else:
            e2 = struct.unpack_from("<Q", data, i)[0]
            i += 8
            ops.append(("seg", e2 >> 63, e2 & (M64 >> 1), ((e >> 24) & ((1 << 36) - 1)) + 1, e & 0xFFFFFF, 2))
    m = sm_case("space map real: " + what, bs, len(data) + 64, ops)
    assert bytes(m.b[:m.len]) == data, "this file's space-map writer disagrees with OpenZFS: " + what
# (5) synthetic: the pad at a block's last word, run splits, the cap, refusals
T = 0x1234567
sm_case("space map log-style, 32 B blocks (pads)", 32, 512,
        [("dbg", 0, 1, T), ("seg", 0, 0x2000, 8, 0, 2), ("seg", 0, 0x9000, 24, 0, 2), ("seg", 0, 0x10000, 1, 0, 2),
         ("dbg", 1, 1, T), ("seg", 1, 0x400, 8, 0, 2), ("seg", 1, 0x800, 16, 0, 2)])
sm_case("space map 24 B blocks: every two-word entry pads", 24, 400,
        [("seg", 0, 1, 1, 0, 2), ("seg", 1, 2, 2, 0, 2), ("seg", 0, 3, 3, 5, 2), ("put", 0x8000000000000005)])
sm_case("space map one-word run split at 2^15", 4096, 256, [("dbg", 0, 1, 7), ("seg", 0, 100, (1 << 15) * 3 + 5, 0, 1)])
sm_case("space map two-word run split at 2^36", 4096, 256, [("seg", 1, 9, (1 << 36) + 77, 3, 2)])
sm_case("space map one-word offset at the 2^47 edge", 4096, 256, [("seg", 0, (1 << 47) - 2, 2, 0, 1)])
sm_case("space map two-word offset near 2^63", 4096, 256, [("seg", 0, (M64 >> 1) - 10, 10, 0, 2), ("seg", 1, M64 >> 1, 1, 0, 2)])
sm_case("space map cap reached mid-split (partial append, -1)", 4096, 40,
        [("dbg", 0, 1, 9), ("seg", 0, 0, (1 << 15) * 8, 0, 1)])
sm_case("space map cap reached at a pad", 32, 24, [("seg", 0, 0, 1, 0, 2), ("seg", 0, 8, 1, 0, 2)])
sm_case("space map refusals", 4096, 512,
        [("seg", 2, 0, 1, 0, 2), ("seg", 0, 0, 0, 0, 2), ("seg", 0, 0, -1, 0, 2), ("seg", 0, -8, 1, 0, 2),
         ("seg", 0, 0, 1, 1 << 24, 2), ("seg", 0, 0, 1, -1, 2), ("seg", 0, 0, 1, 0, 3), ("seg", 0, 0, 1, 0, 0),
         ("seg", 0, 1 << 47, 1, 0, 1), ("seg", 0, (1 << 47) - 1, 2, 0, 1), ("seg", 0, M64 >> 1, 2, 0, 2),
         ("dbg", 2, 1, 1), ("dbg", 0, 1024, 1), ("dbg", 0, 1, 1 << 50), ("dbg", -1, 1, 1),
         ("dbg", 1, 1023, (1 << 50) - 1), ("seg", 1, 5, 1, 0xFFFFFF, 2)])
sm_case("space map bad block size (8) and a 16 B block", 8, 64, [("seg", 0, 0, 1, 0, 2)])
sm_case("space map 16 B blocks: pad, entry, pad", 16, 128, [("put", 1 << 63), ("seg", 0, 4, 4, 0, 2), ("seg", 0, 8, 1, 0, 1)])
sm_case("space map put at a full map (len == cap)", 16, 24, [("put", 1), ("put", 2), ("put", 3), ("put", 4)])
sm_case("space map put into a ragged cap (20 B)", 4096, 20, [("put", 1), ("put", 2), ("put", 3), ("dbg", 0, 1, 5)])


# --- fills (zfs_fill_dnodes / zfs_ind_ready) -------------------------------------------------------
# Meta-dnode L0 blocks (dnode blocks) from the same capture: (what, BP hex, physical block as base64(zlib)).
REAL_DNBLKS = [
    ('MOS meta-dnode L0 blk 0: dnode block, fill 1',
     '0800000000000000f01b030000000000080000000000000088320100000000000800000000000000d0870300000000001f0007000f070a80000000000000000000000000000000000000000000000000620000000000000001000000000000000df34bcc1e000000eecc9693f77400006d66607e596cde00424d2e51819b5d1a',
     (
      'eNpjYGA0kWdgZPj/djKjICMzAwMDowIHkzATB4MKwwROBn4mBm5hDnkGpQY3TgYWAQbDDVyMgiCG0gzmKIZGeQZ2Bn52xgZZkEIG'
      'YSERBiY7hgQGhtY/eYwiDF84FSWfPVjjxsBQGL58i82tLgbbHm5OcTO+bQkMCjekjzOwFTAoFRg5MbAoMCjtaFdg4G9g4BVIcmVg'
      'EGRkZGP4IszAoFzfd7EP6KgV/Wd2/g5jZDi2kFnjcsEzxpuH70xo/t76K4FB+kUDg3RDA4P8iQYGlQ+CCT8aWeYBNbxPl7U5UszI'
      'oD1Jnuf0Ok4mI7l9p/85tkkuAbn0PwUgIYBhFIyCUTAKRsEoGAWjYBSMglEwCkbBKBhqAADNt3u8')),
    ('agnostank meta-dnode L0 blk 0: dnode block, fill 31',
     '0800000000000000684500000000000008000000000000009809010000000000000000000000000000000000000000001f0007000f070a800000000000000000000000000000000000000000000000000f000000000000001f0000000000000061ef473b4a00000090232f0a1ff300001066a65541d294014fc6c882952981c8',
     (
      'eNrtU+9vU2UYPe973/66Lb23vRsUgmvtwJWl2e1dt7nOwKqBUE3MFv0gGo0zgTG3ERAcEEhkEA1umjBEyBQNOo2ZWQXGB5nDyGKQ'
      'gCiZUQE/gB1DZB/AJsIYQZ3P7cJ29W/o86E/zvu855zn3OcCtpEgGCavv1foYxIAN3fy+SEfFA5Jc87BLCeK29k8yBydjDq5o7B9'
      'NuwcmnBDLMGfakHg3A6NbnY8/1jkOTewUF/X1H9SQnz9h1+/3DlWZlJNRo5rPsaixM9weBlbOOmaP8maVrW2rg01rl+7JrSlcYNs'
      '+vilvh582yTDkl3QwO1BRxU4ETh6nqnXIYkAPt6+AH7FASUFuxYOAU283fkqcHXdt80akkMv9lQ7IVSEu26o0MZCSHV1XpgdgojB'
      'Uy3hcUniGFIPsCKynAx1wK9BSzpNk1sk8KAMHqHfzR5wwaGA35fozhwhDyoKRa+Ywg74OESY/IoC/TQWhBpk874sJmxhdXGJqR5N'
      'SfMY59gwCbLq0A5KXopMJq2YE//4DmrDg+UMaCh74WjLaY7Wi0uffnP0iJQeW9OyS9n4ETgfgOZKwmPqCVsyudeoiUL7PSuFs98N'
      'waNChASNxB8wnwVZ+qxgzhkEP3hEstGTElkWnqgN5IxERM4Itczyu0tQjIBpoPMbZecIJbD6ndLRtw5zdJSk9z4bKBd/71zu6I+e'
      'bSMDNVykOOmbSWSYkbpS128SGhnxxxlGcdhInlXCwc3PnIL9bRlCGWcahbHJC+5T38cUB6nbksNvnLRFTW+1TRfPqxRXLGdcKwDX'
      'QrRgSxiOOhF20W1F0KDVy6K5CZpcuQlorGAB7HYx5PL7dNz0o26w/N0TNET2Z1f3oTUcbWdVcXn3qLTv3I9be/bfqQAPX3/YgDZ4'
      'h0kOzCICQpYyUs4yY3jVlWNkxmWcemVP1kWBekw7sks7Dln7FLJ0bydkBZ5FL/m3NcZisYpxd/DyuFuizOtoSUvhcSkDzEaNNuIW'
      '8Gj2ReZm2kRG4BIHPGKYGZGhQNxJk9Q2yHOn5vZc5RTXAQXeMnqldCMO3peY+HJHlumb76pwT0UzHqw28V7nV9QTWW7BEyY+cP0U'
      'eG176PR0lrf08liOaflPxHRho+WGYeLt+34lpsAP0/gtPU7Prs+4tml73E/29fYjlrOKB82zgUtS3EvT1ToXimmlcQolnViR9pJO'
      '/fkZnRx87Ym5JNPdYaGqrIK9L9F9bCUdNNyYOQhWwZtODN/uIv7u0t1WfsKT3+8n/tBfljnKTZ7Yyk+IR90zjd/UjXKIdDITX+x9'
      'aL6AV+9qtpoS6UT37RRpNJQ+atUoSic2r36SNFbss7aH04nU/Q0kMfGUFQ6kE69PtJiZF7fOZB6sJHpjXc2hrREBWXe2/U8YI1/Q'
      'lVPaoFV4djqRqT9Bwl07re1FFarnNYXWKaAgajMXyfw2YlWNd8sE7Hpm7L/d95aP/lcmsp/Ta6sP/zbd0luPfOUrX/nKV77yla98'
      '5ctS/wKCpTvx')),
    ('agnostank/dnode meta-dnode L0 blk 0: dnode block, fill 16',
     '0800000000000000b0be00000000000008000000000000007021010000000000000000000000000000000000000000001f0007000f070a800000000000000000000000000000000000000000000000002c00000000000000100000000000000068197176420000007e2b38e420db0000841ba104aa936f01d5db45f4282deaa1',
     (
      'eNrt0+9rW1UYB/DvuffkR9O4e9ObulHCctYMU0Pd7k2apZdqenHIqq8ConbFF8tsZprOJNYsditjm6gohW44kb1QFLaxOmFzir7R'
      'Ql840QlSBXFDkAhOV0SYFUF9E5+T2RXfxP4B93lxTm7uOZ/7vfecA3iWomBo/vp6d4ipADoVvxIRIWgKVMO/Eb3FhQ5wHclBwUJ0'
      'F7OMxiu+7qMb4VFgJALgWfyu1x4aes6g+Z+PvTf3eCfwwlf28vinKlKvfOv5o7q8TYLNvk+MEGP99BQGodQY/RdpdkSabLxcGS+I'
      'fRP7C6JsmgGZ6FpuF5QjTYbscRhQvNH+HVBogu/kWG47VP8mFBfQe+ZYP7o0H7QcvEavwCKnDP7ngeXqlZIBpy8/l/LL/AnzfR12'
      '45uPBLgJ9YgMj0dUVcGi/ibbTLMc8TK6DOiOH3cyCwjAiEypppK3YjhGV4BSN4MwRjksJZ/UgQimnHzyHlOYDL/polYsiKcPTDwx'
      'KfZOVZ4ti32VaVE68FT1GVGpF6aiuLQ/f+igGK88KczAEHYS2ODYouS/Bqth+LN8ahRx7xBCVg3aSXSPZGzLziKazKJnJD2YsrII'
      'pbJgCfnZmiEN3Ila4G9bg8WFDSoHT/x5mV6x+vH11ivisupXQKOSSpBT55GD47r1vU9eaKO4i55FP2P84K0uK7tmJZok0y7+8FND'
      'tZdiP+tw9mzrHLihcsFJpSH3KzdbhBwYl01HGywlsbd2BRtqQrxI6U69arbSSYcdkrm8ckxcNu2cAeksXrLIcW6Sc/TCo2tOCS1n'
      'QDoD7Z20/GDzXzxWV3mj09Y3jJJ19fqMvmrp6VKwhaUllm6P7ZChbngPU6jcgwSJH0/fDiVvBmQTl007JSMV3HFWKg+TYm65sqZk'
      'pJKRSqadUqZ1EOetPWf/rvs4gol3f9Fh9R3e/Bot27+WY6n1JBMawrRyTPRhbJOGiNwIcd+9dDp5zDMDTaVuGKwRlnvM0CCGSY6c'
      't829D1C+U2co3/T0xKq5E+dUDbo3nFzpCZkrvVo51s3YVuxuLYhMK2nwrXzmVjfcSjupSbL6RonIedph9lL/8dskYxENfi9f6aGr'
      '+/7HyBVOkLF0moyR7R+sGZO6DLA+46WRD8m4OkeG89e1/+ZYr3HC/o4MfZpOy/yXGNzdxRFedWbD63XeuTuvyINyUW7wbHwtyixf'
      'D2Hk4JZbbrnllltuueWWW+3qH9VQDa0=')),
]


def dnode_fill(b):
    """dbuf_write_ready's DMU_OT_DNODE count (dbuf.c:5036-5062): allocated slots, a multi-slot dnode once."""
    fill, i = 0, 0
    while i < len(b):
        dn = b[i:i + 512]
        i += 512
        if dn[0] != 0:
            fill += 1
            i += dn[12] * 512
    return fill


def ind_ready(b):
    """dbuf_write_children_ready (all holes -> zeroed) then dbuf_write_ready's indirect fill (Σ BP_GET_FILL)."""
    ws = [struct.unpack_from("<16Q", b, i) for i in range(0, len(b), 128)]
    live = [w for w in ws if (w[6] >> 39) & 1 or w[0] or w[1]]          # !BP_IS_HOLE
    if not live:
        return 0, bytes(len(b))
    return sum(1 if (w[6] >> 39) & 1 else w[11] for w in live) & M64, b


def fill_case(name, blk, kind, want=None):
    if kind == 1:
        f, after = dnode_fill(blk), blk
    else:
        f, after = ind_ready(blk)
    if want is not None:
        assert f == want, "this file's fill disagrees with OpenZFS's: %s (%d != %d)" % (name, f, want)
    add('    zt_fill("%s", %d, %d, %d, %d);' % (name_ok(name), blob(blk), kind, s64(f), blob(after) if kind == 2 else -1))


# REAL: the fill OpenZFS stored in the BP of each captured block is what its content must give
for what, hx, z in REAL_DNBLKS:
    f = bp_fields(bytes.fromhex(hx))
    plain = zfs_lz4_decode(unz(z), f["lsize"])
    assert plain is not None and len(plain) == f["lsize"]
    fill_case("fill real: " + what, plain, 1, f["fill"])
for what, hx, z in REAL_BPS:
    f = bp_fields(bytes.fromhex(hx))
    if f["lv"] == 0 or unz(z) is None:
        continue
    plain = zfs_lz4_decode(unz(z), f["lsize"])
    assert plain is not None
    fill_case("fill real indirect: " + what, plain, 2, f["fill"])
# synthetic dnode blocks: interior slots of a multi-slot dnode carry a NONZERO first byte (garbage), so counting them
# — or not stepping over them — shows
_g = SplitMix(0xF111B10C)
for k in range(6):
    blk = bytearray(16384)
    i = 0
    while i < 32:
        if _g.below(3) == 0:
            i += 1
            continue
        ex = min(_g.below(4) if k % 2 else 0, 31 - i)
        blk[512 * i] = 1 + _g.below(200)
        blk[512 * i + 12] = ex
        for j in range(1, ex + 1):
            blk[512 * (i + j)] = 0x55                         # interior: never a dnode
        i += 1 + ex
    fill_case("fill dnode block synthetic %d" % k, bytes(blk), 1)
fill_case("fill dnode block all free", bytes(16384), 1)
fill_case("fill dnode block 512 B, one dnode", b"\x13" + bytes(511), 1)
# synthetic indirects
def bpw(*kv):
    w = [0] * 16
    for i, v in kv:
        w[i] = v & M64
    return struct.pack("<16Q", *w)
HOLE0 = bytes(128)
HOLEB = bpw((6, (255 << 0) | (19 << 48)), (10, 77))           # a hole with birth: still a hole
EMB = bpw((0, 0x1122), (6, (1 << 39) | (19 << 48) | 63), (10, 5), (11, 0xDEAD))   # embedded: fill counts 1
EMB0 = bpw((2, 0x77), (6, (1 << 39) | (19 << 48) | 63), (10, 5), (11, 0xBEEF))       # embedded, payload words 0-1 zero
LIVE = lambda fl, o: bpw((0, 8), (1, o), (6, 0x8007020000000000 | (19 << 48) | 7), (10, 9), (11, fl))
fill_case("fill indirect all zero (stays zero, 0)", bytes(131072), 2)
fill_case("fill indirect only holes with birth (zeroed, 0)", HOLEB * 1024, 2)
fill_case("fill indirect holes and births mixed (zeroed, 0)", (HOLE0 + HOLEB) * 512, 2)
fill_case("fill indirect one embedded child (1, untouched)", HOLEB * 7 + EMB + HOLE0 * 1016, 2)
fill_case("fill indirect one embedded child, payload words 0-1 zero (not a hole)", HOLEB * 3 + EMB0 + HOLE0 * 1020, 2)
fill_case("fill indirect live fills summed", LIVE(3, 100) + HOLEB + LIVE(1 << 40, 200) + EMB + HOLE0 * 1020, 2)
fill_case("fill indirect 1024 live, fill wraps", b"".join(LIVE(M64 >> 3, i) for i in range(1024)), 2)
fill_case("fill indirect 4K (32 children), last live", HOLE0 * 31 + LIVE(5, 1), 2)
# DVA_IS_EMPTY (spa.h) needs BOTH words of DVA 0 zero: a child whose word 0 is 0 and word 1 is not is no hole
fill_case("fill indirect a child with only DVA word 1 set (not a hole, 4)",
          HOLE0 * 5 + bpw((1, 0x40), (6, 0x8007020000000000 | (19 << 48) | 7), (10, 9), (11, 4)) + HOLE0 * 1018, 2, 4)

# --- 1.57.12 B4: the dataset COW's accounting rules (zfs_wenc.cyr zfs_ot_meta / zfs_pdelta / zfs_md_copies /
# zfs_bp_ucsize / zfs_bp_birth / zfs_sa_ids), against an independent model written from OpenZFS 2.4.2 — dmu.c's
# dmu_ot[] metadata column, spa.h's BP_GET_UCSIZE / BP_GET_BIRTH, dsl_dataset.c / dsl_dir.c parent_delta,
# dmu.c dmu_write_policy's metadata copies, zfs_quota.c zpl_get_file_info — and against bytes OpenZFS wrote
# (REAL_B4_*: block pointers and SA bonuses captured from the fixture's `wr` pool with scripts/tool/zfs-damage.py).
# dmu_ot[] (dmu.c:105-160), the ot_metadata column, one letter per legacy type 0 .. 53
DMU_OT_META = "TTTTTTTTTTTTTTTTTTTFTTTFTFFTTTTTTTTTTTTTTTTTTTTTTFTTTT"
assert len(DMU_OT_META) == 54


def ot_meta(ty):                                   # DMU_OT_IS_METADATA (dmu.h:131-133)
    if ty & 0x80:
        return 1 if ty & 0x40 else 0
    return 1 if DMU_OT_META[ty] == "T" else 0


def acct(name, kind, a, b, c, d, want):
    add('    zt_acct("%s", %d, %d, %d, %d, %d, %d);' % (name_ok(name), kind, a, b, c, d, want))


for ty in list(range(54)) + [0x80, 0x84, 0x89, 0xC0, 0xC4, 0xC9, 0xE0, 0xE4]:
    acct("ot_meta type %d" % ty, 1, ty, 0, 0, 0, ot_meta(ty))


def pdelta(used, delta, resv):                     # parent_delta (dsl_dataset.c:121-136 / dsl_dir.c:1155-1162)
    if resv == 0:
        return delta
    return max(used + delta, resv) - max(used, resv)


PD = [(98304, 4096, 0), (98304, 4096, 8388608), (98304, -4096, 8388608), (8388608 - 2048, 4096, 8388608),
      (8388608 + 2048, -4096, 8388608), (8388608, 0, 8388608), (10 << 20, 4096, 8388608), (10 << 20, -(3 << 20), 8388608),
      (0, 0, 0), (0, 512, 1), (1 << 40, -(1 << 39), 1 << 41), (16777216, -16777216, 16777216), (7, -7, 0)]
for u, dl, r in PD:
    acct("parent_delta used %d delta %d resv %d" % (u, dl, r), 2, u, dl, r, 0, pdelta(u, dl, r))
_g4 = SplitMix(0xB4ACC7)
for i in range(24):
    u = _g4.below(1 << 30); r = _g4.below(1 << 30) if i % 4 else 0; dl = _g4.below(1 << 28) - (1 << 27)
    if u + dl < 0:
        dl = -u
    acct("parent_delta random %d" % i, 2, u, dl, r, 0, pdelta(u, dl, r))


def md_copies(c, rm, ty, lv):                      # dmu_write_policy, metadata (dmu.c:2381-2424, :2531)
    n = c
    if rm == 0:
        n += 1
    elif rm == 1:
        if lv >= 2 or ot_meta(ty):
            n += 1
    elif rm == 2:
        critical = ot_meta(ty) and (ty != 10 or lv > 0) and ty != 20 and ty != 44
        if critical:
            n += 1
    return min(n, 3)


for c in (1, 2, 3):
    for rm in (0, 1, 2, 3):
        for ty, lv in ((19, 1), (19, 2), (19, 3), (10, 0), (10, 1), (11, 0), (20, 0), (20, 1), (44, 0), (39, 0), (21, 0), (0xC4, 0)):
            acct("md copies c %d rm %d type %d level %d" % (c, rm, ty, lv), 3, c, rm, ty, lv, md_copies(c, rm, ty, lv))

# BP_GET_UCSIZE / BP_GET_BIRTH (spa.h:494-559)
def bp_ucs_birth(raw):
    w = struct.unpack("<16Q", raw)
    emb = (w[6] >> 39) & 1
    if not emb and w[0] == 0 and w[1] == 0:
        ucs = 0
    else:
        md = ((w[6] >> 56) & 0x1F) > 0 or ot_meta((w[6] >> 48) & 0xFF)
        if emb:
            ucs = 0 if md else (w[6] & 0x1FFFFFF) + 1
        else:
            ucs = ((((w[6] >> 16) & 0xFFFF) + 1) << 9) if md else (((w[6] & 0xFFFF) + 1) << 9)
    rewrite = 0 if emb else (w[7] >> 63) & 1
    if not rewrite:
        birth = w[10]
    else:
        birth = w[9] if w[9] else w[10]
    return ucs, birth


def bpacct(name, raw):
    u, b = bp_ucs_birth(raw)
    add('    zt_bpacct("%s", %d, %d, %d);' % (name_ok(name), blob(raw), u, b))
    return u, b


REAL_B4_BPS = [
    ("resv/r.txt L0: embedded data (lz4, 29 of 512 B) - UCSIZE = lsize", "00000022f7027265736572766174696f6e202b2072656611002f0a000100ffcb50000000000000000000000000000000ff01004a8f001380000000000000000000000000000000000000000000000000180000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000", 512, 24),
    ("text-300k.txt L1: an lz4 indirect - UCSIZE = psize", "0800000000000000d00c0000000000000800000000000000700301000000000000000000000000000000000000000000ff0007000f071381000000000000000000000000000000000000000000000000090000000000000003000000000000009f538f7b8f000000f936b24a990602002244e2ec924fac0390eb997d0fb76574", 4096, 9),
    ("text-300k.txt L0: lz4 data (128 KiB to 20 KiB) - UCSIZE = lsize", "280000000000000030030000000000000000000000000000000000000000000000000000000000000000000000000000ff0027000f0713800000000000000000000000000000000000000000000000000900000000000000010000000000000052b6d6e07f040000a2a2ec026e3c2b00e612c99197fac9110bc1cdb935febce1", 131072, 9),
    ("quota/q.bin L0: random data written OFF - UCSIZE = lsize = psize", "000100000000000020170000000000000000000000000000000000000000000000000000000000000000000000000000ff00ff000207138000000000000000000000000000000000000000000000000014000000000000000100000000000000737bc0bbfa3f0000049b73fffe17ff0f2b39e9af1a94bc97c4b7380a4226225e", 131072, 20),
]
for what, hx, wu, wb in REAL_B4_BPS:
    u, b = bpacct("bp acct real: " + what, bytes.fromhex(hx))
    assert (u, b) == (wu, wb), "this file's UCSIZE / birth model disagrees with the captured BP: %s (%d %d)" % (what, u, b)


def bpw4(**kw):
    w = [0] * 16
    for k, v in kw.items():
        w[int(k[1:])] = v & M64
    return struct.pack("<16Q", *w)


DATA = (1 << 63) | (19 << 48) | (2 << 32) | (7 << 40) | (255 << 16) | 255         # 128K lsize/psize, plain file
bpacct("bp acct: a hole (0, birth 0)", bytes(128))
bpacct("bp acct: a hole with birth 77", bpw4(w6=(19 << 48) | 255, w10=77))
bpacct("bp acct: data, rewrite flag clear, physical 50 ignored", bpw4(w0=256, w1=8, w6=DATA, w9=50, w10=60))
bpacct("bp acct: data, rewrite flag set, physical 90 wins", bpw4(w0=256, w1=8, w6=DATA, w7=1 << 63, w9=90, w10=60))
bpacct("bp acct: data, rewrite flag set, physical 0 to logical", bpw4(w0=256, w1=8, w6=DATA, w7=1 << 63, w10=60))
bpacct("bp acct: embedded, word 7 (payload) bit 63 set to logical", bpw4(w0=0x55, w6=(1 << 39) | (19 << 48) | 511, w7=1 << 63, w9=7, w10=61))
bpacct("bp acct: embedded metadata (a ZAP) moves no UCSIZE", bpw4(w0=0x55, w6=(1 << 39) | (20 << 48) | 511, w10=62))
bpacct("bp acct: level 1 of a data type is metadata (psize)", bpw4(w0=8, w1=8, w6=DATA | (1 << 56) | (7 << 16), w10=63))
bpacct("bp acct: DMU_OTN data (0x80) lsize, DMU_OTN metadata (0xC4) psize", bpw4(w0=8, w1=8, w6=((DATA & ~(0xFF << 48)) | (0x80 << 48)) & ~(0xFFFF << 16) | (7 << 16), w10=64))
bpacct("bp acct: DMU_OTN metadata (0xC4) psize", bpw4(w0=8, w1=8, w6=((DATA & ~(0xFF << 48)) | (0xC4 << 48)) & ~(0xFFFF << 16) | (7 << 16), w10=65))
bpacct("bp acct: DVA word 1 only (not a hole)", bpw4(w1=8, w6=DATA, w10=66))


# zpl_get_file_info (zfs_quota.c:42-110)
def sa_ids(bt, data):
    if bt == 17:
        if len(data) < 144:
            return -1, (0, 0, 0)
        return 0, (struct.unpack_from("<Q", data, 128)[0], struct.unpack_from("<Q", data, 136)[0], 0)
    if bt != 44:
        return 1, (0, 0, 0)
    if len(data) < 8:
        return -1, (0, 0, 0)
    mg = struct.unpack_from("<I", data, 0)[0]
    if mg == 0:
        return 0, (0, 0, 0)
    if mg != 0x2F505A:
        return -1, (0, 0, 0)
    hs = ((struct.unpack_from("<H", data, 4)[0] >> 10) & 0x3F) * 8
    if hs < 8 or hs + 56 > len(data):
        return -1, (0, 0, 0)
    uid, gid = struct.unpack_from("<QQ", data, hs + 24)
    fl = struct.unpack_from("<Q", data, hs + 48)[0]
    pj = 0
    if fl & (1 << 47):
        if hs + 136 > len(data):
            return -1, (0, 0, 0)
        pj = struct.unpack_from("<Q", data, hs + 128)[0]
    return 0, (uid, gid, pj)


def said(name, bt, data, want=None):
    rc, ids = sa_ids(bt, data)
    if want is not None:
        assert (rc, ids) == want, "this file's zpl_get_file_info model disagrees: %s %r" % (name, (rc, ids))
    add('    zt_said("%s", %d, %d, %d, %d, %d, %d);' % (name_ok(name), blob(data), bt, rc, s64(ids[0]), s64(ids[1]), s64(ids[2])))


REAL_B4_SA = [
    ("resv/r.txt (layout 2, 8-byte header, ZFS_PROJID set: project 0)", "5a502f0002041800a4810000000000001d0000000000000018000000000000000000000000000000000000000000000022000000000000000400000008840000b171ca6a00000000b8e2a22100000000b171ca6a000000007840a32100000000b171ca6a000000007840a32100000000b171ca6a00000000b8e2a22100000000010000000000000000000000000000000300000000000000000000109f011e0000004020890012000000004089001200"),
    ("text-300k.txt (layout 3)", "5a502f0003041800a48100000000000000b004000000000009000000000000000000000000000000000000000000000022000000000000000400000008840000b171ca6a00000000703dcf1400000000b171ca6a00000000b0fa081500000000b171ca6a00000000b0fa081500000000b171ca6a00000000703dcf1400000000010000000000000000000000000000000300000000000000000000109f011e0000004020890012000000004089001200"),
]
for what, hx in REAL_B4_SA:
    said("sa ids real: " + what, 44, bytes.fromhex(hx), (0, (0, 0, 0)))
# synthetic, each id distinct so a swapped offset shows; variable-length headers (16 / 24 bytes) shift every field
def sa_blob(hs_units, uid, gid, flags, pj, n=176):
    b = bytearray(max(n, 256))                     # built whole, then cut to n bytes
    struct.pack_into("<IH", b, 0, 0x2F505A, (hs_units << 10) | 2)
    hs = hs_units * 8
    struct.pack_into("<QQ", b, hs + 24, uid, gid)
    struct.pack_into("<Q", b, hs + 48, flags)
    struct.pack_into("<Q", b, hs + 128, pj)
    return bytes(b[:n])


said("sa ids: 8-byte header, uid 1001 gid 20, no ZFS_PROJID (project 0, +128 ignored)", 44, sa_blob(1, 1001, 20, 0x0000000400000008, 77), (0, (1001, 20, 0)))
said("sa ids: ZFS_PROJID, project 4242", 44, sa_blob(1, 5, 6, 1 << 47, 4242), (0, (5, 6, 4242)))
said("sa ids: 16-byte header shifts every field", 44, sa_blob(2, 7, 8, 1 << 47, 9), (0, (7, 8, 9)))
said("sa ids: 24-byte header, ids near 2^32", 44, sa_blob(3, 0xFFFFFFFE, 0x80000000, 0, 0), (0, (0xFFFFFFFE, 0x80000000, 0)))
said("sa ids: zero magic (not filled in yet): ids 0", 44, bytes(64), (0, (0, 0, 0)))
said("sa ids: byte-swapped magic refused", 44, b"\x00\x2f\x50\x5a" + bytes(60), (-1, (0, 0, 0)))
said("sa ids: header size 0 refused", 44, struct.pack("<IH", 0x2F505A, 2) + bytes(122), (-1, (0, 0, 0)))
said("sa ids: too short for the flags (hdr + 56 > len)", 44, sa_blob(1, 1, 2, 0, 0, n=63), (-1, (0, 0, 0)))
said("sa ids: exactly hdr + 56 bytes, no projid", 44, sa_blob(1, 1, 2, 0, 0, n=64), (0, (1, 2, 0)))
said("sa ids: ZFS_PROJID but too short for it", 44, sa_blob(1, 1, 2, 1 << 47, 0, n=143), (-1, (0, 0, 0)))
said("sa ids: ZFS_PROJID at exactly hdr + 136", 44, sa_blob(1, 1, 2, 1 << 47, 3, n=144), (0, (1, 2, 3)))
said("sa ids: 7 bytes refused", 44, bytes(7), (-1, (0, 0, 0)))
_zn = bytearray(264)
struct.pack_into("<QQ", _zn, 128, 31, 32)
said("sa ids: znode_phys_t (zp_uid @128, zp_gid @136)", 17, bytes(_zn), (0, (31, 32, 0)))
said("sa ids: znode_phys_t too short", 17, bytes(143), (-1, (0, 0, 0)))
said("sa ids: bonus type 0 (no ids: not accounted)", 0, bytes(64), (1, (0, 0, 0)))
said("sa ids: bonus type 21 (a ZAP master node: not accounted)", 21, bytes(64), (1, (0, 0, 0)))

# ------------------------------------------------------------------------------------------------
# 1.57.12 B11 — UTF-8 names on a utf8only dataset (kernel/core/zfs_wenc.cyr zfs_u8_valid): OpenZFS's u8_validate
# (module/unicode/u8_textprep.c:337-446, U8_VALIDATE_ENTIRE) PORTED here from its tables — u8_number_of_bytes (I_ = EILSEQ
# for 0x80-0xC1, O_ = ERANGE for 0xF5-0xFF), u8_valid_min_2nd_byte / _max_2nd_byte (E0 A0.., ED ..9F, F0 90.., F4 ..8F),
# U8_ILLEGAL_NEXT_BYTE_COMMON — and every vector's verdict CROSS-CHECKED against Python's own strict UTF-8 codec (valid
# iff it decodes: two independent producers). zt_u8 places the name against the guard page (a read past its end faults)
# and wants u8_validate's class: 0 valid · 1 EILSEQ · 2 ERANGE · 3 EINVAL (the bytes left cannot hold the sequence).
_U8NB = [1] * 0x80 + [-1] * 0x42 + [2] * 0x1E + [3] * 0x10 + [4] * 5 + [-2] * 0x0B
assert len(_U8NB) == 256 and _U8NB[0xC1] == -1 and _U8NB[0xC2] == 2 and _U8NB[0xF4] == 4 and _U8NB[0xF5] == -2


def u8_validate(b):
    i = 0
    while i < len(b):
        c = b[i]
        sz = _U8NB[c]
        if sz == -1:
            return 1
        if sz == -2:
            return 2
        if len(b) - i < sz:
            return 3
        if sz > 1:
            lo = {0xE0: 0xA0, 0xF0: 0x90}.get(c, 0x80)
            hi = {0xED: 0x9F, 0xF4: 0x8F}.get(c, 0xBF)
            if not lo <= b[i + 1] <= hi:
                return 1
            for k in range(2, sz):
                if not 0x80 <= b[i + k] <= 0xBF:
                    return 1
        i += sz
    return 0


_U8 = []              # every vector's bytes, in ONE blob (zv_blob's dispatcher holds < 1,024 blobs): (name, off, bytes, want)


def u8_case(name, b):
    want = u8_validate(b)
    try:
        b.decode("utf-8")
        ok = True
    except UnicodeDecodeError:
        ok = False
    assert (want == 0) == ok, (name, b, want)
    _U8.append((name, sum(len(x[2]) for x in _U8), b, want))


u8_case("u8: empty", b"")
u8_case("u8: ASCII with a NUL (a valid one-byte character)", b"a\0b")
for _nm, _b in (("2-byte U+0080", b"\xc2\x80"), ("2-byte U+07FF", b"\xdf\xbf"), ("3-byte U+0800", b"\xe0\xa0\x80"),
                ("3-byte U+D7FF", b"\xed\x9f\xbf"), ("3-byte U+E000", b"\xee\x80\x80"), ("3-byte U+FFFF", b"\xef\xbf\xbf"),
                ("4-byte U+10000", b"\xf0\x90\x80\x80"), ("4-byte U+10FFFF", b"\xf4\x8f\xbf\xbf"),
                ("4-byte U+1F600", b"\xf0\x9f\x98\x80"), ("cafe-acute", "caf\u00e9.txt".encode()),
                ("unicode.txt (the fixture's)", "\u00fcnicode.txt".encode()),
                ("overlong 2-byte C0 AF", b"\xc0\xaf"), ("overlong 2-byte C1 BF", b"\xc1\xbf"),
                ("overlong 3-byte E0 9F BF", b"\xe0\x9f\xbf"), ("overlong 4-byte F0 8F BF BF", b"\xf0\x8f\xbf\xbf"),
                ("surrogate ED A0 80", b"\xed\xa0\x80"), ("surrogate ED BF BF", b"\xed\xbf\xbf"),
                ("past U+10FFFF F4 90 80 80", b"\xf4\x90\x80\x80"), ("lead F5", b"\xf5\x80\x80\x80"),
                ("lead FF", b"\xff"), ("lead FE", b"x\xfe"), ("lone continuation 80", b"\x80"),
                ("lone continuation BF after ASCII", b"ab\xbf"), ("truncated 2-byte", b"a\xc3"),
                ("truncated 3-byte", b"truncated-\xe2\x82"), ("truncated 4-byte", b"\xf0\x9f\x98"),
                ("bad 2nd byte of 2 (7F)", b"\xc3\x7f"), ("bad 2nd byte of 2 (C0)", b"\xc3\xc0"),
                ("bad 3rd byte of 3", b"\xe2\x82\x41"), ("bad 4th byte of 4", b"\xf0\x9f\x98\xc0"),
                ("valid then truncated", "\u00e9\u00e9".encode() + b"\xe2"), ("valid then lead F8", "\u00e9".encode() + b"\xf8")):
    u8_case("u8: " + _nm, _b)
# every lead byte with every boundary continuation pair: the whole second-byte table, exactly
for _c in range(0x80, 0x100):
    for _b2 in (0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0):
        u8_case("u8: lead %02X second %02X" % (_c, _b2), bytes([_c, _b2, 0x80, 0x80]))
# a fuzz of short strings over the bytes that matter, every one cross-checked
_ur = SplitMix(0x5538_C0DE)
_ua = [0x00, 0x2F, 0x41, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC1, 0xC2, 0xDF, 0xE0, 0xE1, 0xEC, 0xED, 0xEE, 0xEF,
       0xF0, 0xF1, 0xF3, 0xF4, 0xF5, 0xFF]
for _i in range(300):
    _n = _ur.below(9) + 1
    u8_case("u8: fuzz %03d" % _i, bytes(_ua[_ur.below(len(_ua))] for _ in range(_n)))
_u8b = blob(b"".join(x[2] for x in _U8) + b"\0")
for _nm, _off, _b, _w in _U8:
    add('    zt_u8("%s", %d, %d, %d, %d);' % (name_ok(_nm), _u8b, _off, len(_b), _w))

# ------------------------------------------------------------------------------------------------
# 1.57.12 B5 — agnos-gen-1, the op list's file content (kernel/core/zfs_wenc.cyr zfs_gen_seed / zfs_gen_fill under
# ZFS_WRITE_OPS). The REFERENCE is scripts/smoke/lib/zfs-expect.py's own `gen` — the function that predicts the
# expected manifest the guest diffs — imported here, never re-typed: byte-identity with IT is the claim. Small windows
# are compared byte for byte (zt_gen: the output ends at the guard page, 64 canary bytes before it); the op list's
# real writes (every seed / offset / length zfs_wt_b5 and the ring-3 exerciser use) by SHA-256 (zt_gensha).
import importlib.util as _ilu
_es = _ilu.spec_from_file_location("zfs_expect", os.path.join(ROOT, "scripts", "smoke", "lib", "zfs-expect.py"))
_ex = _ilu.module_from_spec(_es)
_es.loader.exec_module(_ex)


def gen_case(name, seed, off, n):
    sb = seed.encode()
    add('    zt_gen("%s", %d, %d, %d, %d, %d, %s);' % (name_ok(name), blob(sb if sb else b"\0"), len(sb), off, n,
        blob(_ex.gen(seed, off, n) if n else b"\0"), h64(_ex.seed64(seed))))


def gensha_case(name, seed, off, n):
    w = sha256_words(_ex.gen(seed, off, n))
    add('    zt_e4(%s, %s, %s, %s); zt_gensha("%s", %d, %d, %d, %s);' % (h64(w[0]), h64(w[1]), h64(w[2]), h64(w[3]),
        name_ok(name), blob(seed.encode()), off, n, h64(_ex.seed64(seed))))


for _s, _o, _n in _ex.VECTORS:
    gen_case("gen1: zfs-expect.py vector %r @%d +%d" % (_s, _o, _n), _s, _o, _n)
for _o, _n in ((0, 1), (7, 1), (8, 8), (5, 11), (13, 77), (16, 24), (1, 64), (4093, 7), (65530, 13)):
    gen_case("gen1: window @%d +%d (aligned words / byte edges)" % (_o, _n), "agnos-gen-1", _o, _n)
gen_case("gen1: an empty window writes nothing", "x", 3, 0)
for _seed, _o, _n in (("b5/tiny", 3, 10), ("b5/rec", 393216, 131072), ("b5/multi", 0, 300000),
                      ("b5/sparse", 1048581, 777), ("b5/off", 29672, 6000), ("b5/big1m", 1052897, 10000),
                      ("b5/gz", 1047576, 5000), ("b5/lzjb", 500000, 100), ("b5/empty", 0, 1000), ("b5/c2", 100, 50),
                      ("b5/rs4k", 4194404, 100), ("b5/q", 524288, 4096), ("b5/fill", 917504, 1048576),
                      ("zfsx/w1", 0, 40), ("zfsx/w2", 40, 1000), ("zfsx/w3", 300000, 100), ("zfsx/w4", 0, 10),
                      ("b8/u50", 0, 10)):
    gensha_case("gen1: op %s @%d +%d (SHA-256)" % (_seed, _o, _n), _seed, _o, _n)

# ------------------------------------------------------------------------------------------------
# 1.57.12 B8 — the FAT ZAP (kernel/core/zfs_wenc.cyr zfs_zf_* / zfs_zl_*: zap.c / zap_leaf.c / mzap_upgrade, run by
# tests/zfscodec over a flat image — zt_zops). The expected side is scripts/check/zfs-fatzap.py, an independent Python
# port of the same OpenZFS 2.4.2 source, which is first held to OpenZFS's OWN bytes: the creation history of the
# fixture's agnoswr/fat and agnostank/dir3000 (captured READ-ONLY on 2026-10-12 from r6-2224d22f2185-30e0e306 with
# scripts/tool/zfs-damage.py's Pool — the salt, every entry's object, type and cd, every block's SHA-256) is replayed
# and must reproduce every block FreeBSD 15.1 wrote; the kernel then replays the same history against the same
# digests. Then model-predicted scripts: removes (a leaf emptied), updates, 255-byte names, the embedded pointer table
# moving out and the external one DOUBLING — at once and incrementally (zap_put_leaf_maybe_grow_ptrtbl: a mid-grow
# state across ops, every zap_table_store writing both tables) — a normalised (TOUPPER) ZAP with CDSORTED leaves and
# case-folded collisions, makefs's 128 KiB blocks, u16-array values (SA LAYOUTS) growing past a leaf, the micro ->
# fat upgrade with collisions and 49-byte names, every result code; and hostile leaves (a free list, a chain, a bucket
# pointing outside the leaf, a bad magic) — refused ZZ_CORRUPT, nothing written outside the image (guard page,
# canary); (B8 review) and what the resolvers' knobs (op 9) force: a doubling's switch whose old-table free fails
# (ZZ_IO through the maybe-grow, never swallowed) and a table that may not grow (ZZ_NOGROW; the maybe-growth skipped).
# A vector is emitted only when the model's own structure check (FatZap.check) holds on its result.
_fzs = _ilu.spec_from_file_location("zfs_fatzap", os.path.join(ROOT, "scripts", "check", "zfs-fatzap.py"))
FZ = _ilu.module_from_spec(_fzs)
_fzs.loader.exec_module(FZ)
ZZ = {"io": -1, "noent": -2, "exist": -3, "corrupt": -4, "nospc": -5, "2big": -6, "notsup": -7, "nogrow": -8}


class ZapScript:
    """One zt_zops case: ops recorded for the kernel AND run on the model, which predicts every result code and
    the final blocks."""

    def __init__(self, bs, nmax):
        self.bs, self.nmax = bs, nmax
        self.z = FZ.FatZap(bs, limit=nmax)
        self.ops = bytearray()
        self.micro = None
        self.n = 0
        self.saw = set()                      # states the script reached (asserted by its caller)

    def _rec(self, op, want, name, isz, vals, cd):
        self.ops += struct.pack("<Bb", op, want) + struct.pack("<H", len(name)) + name
        self.ops += struct.pack("<BH", isz, len(vals)) + b"".join((v & ((1 << (8 * isz)) - 1)).to_bytes(isz, "little")
                                                                 for v in vals)
        self.ops += struct.pack("<i", -1 if cd is None else cd)
        self.n += 1

    def stage(self, size, salt, entries, nf=0):
        """A microzap of size bytes (salt, normflags nf, entries [(name, value, cd)] in chunk order) — then upgraded."""
        self.ops += struct.pack("<BbIQQ", 7, 0, size, salt, nf)
        for i, (nm, v, cd) in enumerate(entries):
            self.ops += struct.pack("<BbHQIB", 6, 0, i, v, cd, len(nm)) + nm
        self.ops += struct.pack("<Bb", 3, 0)
        self.z.upgrade(FZ.micro_block(size, salt, entries, nf))
        self.n += 1

    def op(self, kind, name, isz=8, vals=(0,), cd=None):
        k = {"add": 0, "update": 1, "remove": 2}[kind]
        try:
            if u64z(self.z.hdr, 88) and any(c >= 128 for c in name):
                raise FZ.Err("notsup")
            self.z.op(kind, name, isz, vals, cd)
            want = 0
        except FZ.Err as e:
            want = ZZ[e.code]
        self._rec(k, want, name, isz, vals, cd)
        st = self.z.hdr
        if u64z(st, 40):
            self.saw.add("midgrow")
        if u64z(st, 24):
            self.saw.add("external")
        return want

    def get(self, name, isz=8):
        v = self.z.get(name)
        if v is None:
            self._rec(4, ZZ["noent"], name, isz, (), None)
        else:
            self._rec(4, 0, name, isz, v, None)

    def poke(self, off, val):
        self.ops += struct.pack("<BbIB", 5, 0, off, val)
        self.n += 1

    def knobs(self, kill=0, grow=0):
        """Op 9 (B8 review): the resolvers' knobs — kill 1: every zfs_zf_kill fails (changing nothing); grow 1:
        zfs_zf_gok refuses (a MOS ZAP in the kernel)."""
        self.ops += struct.pack("<BbBB", 9, 0, kill, grow)
        self.z.killfail, self.z.nogrow = bool(kill), bool(grow)
        self.n += 1

    def checkpoint(self, digests=None):
        """Op 8: the model's blocks so far (and, given, OpenZFS's digests of them: the model must agree first)."""
        self.z.check()
        nd = max(self.z.blocks) + 1
        assert nd <= self.nmax
        dig = [bytes(self.z.blocks.get(b, bytearray(1 << self.bs))) for b in range(nd)]
        if digests is not None:
            assert [hashlib.sha256(d).hexdigest() for d in dig] == digests, "the MODEL does not reproduce OpenZFS's blocks"
        self.ops += struct.pack("<BbH", 8, 0, nd) + b"".join(struct.pack("<4Q", *sha256_words(d)) for d in dig)
        self.n += 1

    def emit(self, title, digests=None, hostile=False):
        if not hostile:
            self.checkpoint(digests)
        raw = bytes(self.ops)
        add('    zt_zops("%s", %d, %d, %d, %d);' % (name_ok(title), blob(zlib_stream(raw, 9)), len(raw), self.bs, self.nmax))


def u64z(b, o):
    return struct.unpack_from("<Q", b, o)[0]


# --- OpenZFS's own fat ZAPs (the fixture; see the header above) ---
WR_FAT_SALT = 0x3a342f29
WR_FAT_ENTRIES = [("a-name-of-sixty-bytes-yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy", 141, 8, 0), ("f0", 142, 8, 0),
                  ("f1", 143, 8, 0), ("f2", 10, 8, 0), ("f3", 390, 8, 0), ("f4", 391, 8, 0), ("f5", 11, 8, 0),
                  ("f6", 12, 8, 0), ("f7", 13, 8, 0), ("f8", 14, 8, 0), ("f9", 15, 8, 0)]
WR_FAT_SHA256 = ["4b451ae92792265389aa2864df65ba8f988288875417786df7fba39f93980491",
                 "ffee5eaf82822759f469ca39eca89a4c52f2445161c6bd4613c62d11a34bb875"]
DIR3000_SALT = 0xf95491
DIR3000_OBJS = (
    "78da0d9783021838100593cd6e369bd4b66ddbb66ddbb66ddbb66ddbb6eddeb5e7bb5e3f62decc1bae46a891cae8a11a3569ab5993b28a9553a2bc"
    "1aa586e9e17ab40a6a841ea99d161d41455491546415454555d1547415438d5163d5283d5a8fd163f538ed75d0e3f5043d514fd293f538355e4d50"
    "13d524154147d49174641d4547d59355341d53c55253d454354d45d731746c355dcd5033d52c355b4dd153f5343d5dcfd033f52c1d53c7d271545c"
    "155bc7d171753c1d5f27d00975229d5827d173d46c3d57cdd1f1547c95402554895462954aa55669d43c355f25d5c974729d42a7d469553a955ea5"
    "d20bd4423557cfd3a9f57cbd482d560b741a9d56a7d3e975069d5167d24bd452b54c2d579975169d5567d319d40ab5502fd28bf512bd5467542bd5"
    "32bd5c67d79954669545e5d02bf44abd4aafd66bf45abd4aad566bd45ab54ee5d4b9746e9d47e7d5f9747e5d4017d4595536955de55039552e955b"
    "15d2ebf47abd416fd49bf466bd456fd5dbf476bd5e6d501bd5269547e555f9547e554015543bf466b5456d55857511bd4d6d573b54515d4c17d725"
    "74495d48edd4bbf44eb54bed567bd46ebd47efd5fbf47e7d401fd4a5f45e75481fd647f4515d5a97d16575395d5e57d01575255d5957d155f531bd"
    "4fed5707d4717d429fd4d5f44175481d5647546155441555c5547155429554a55469555dd7d035752d5d5bd7d175753d5d5f37d00d7523dd5837d1"
    "4d7533dd5c9fd2a7f551754c9dd167751955569553e5550b7d4e9fd717f47175519f5027d529755a9d5197f4657d455fd5d7f4757d43b7d4ad746b"
    "dd46b7d537753bdd5edfd2b7f51d5d41555467d539755e5d50955407dd515f5477f5257559ddd3f775277d455d55d7d475d55977d15d75375d5955"
    "510ff443fd483fd6dd750fdd535755d5d40d7553555735544d554bd55675545d554f3dd14ff5337d4bdd5677542fdd5bd7570d5443d54835564dd4"
    "73fd42bfd4aff46bdd54dd55f7d47df5403553cdd543d5423d522d552bd55ab5517df41bfd56bfd36d553bd55ef5d5fdf47bfd4177501dd563f544"
    "3d559d5467d55f0fd01ff527fd597fd103f5203d587fd50a343c53bfe85f7517d5557553dd550ff54df754bd14c077dd5bf5517d553fd55f0d5003"
    "d5206500e137fdbbfe43ffa9ffd2cfd50bf552bd527feb7f3481857ff57ffa871e024361180c87c1ea27ba068c3168c858c3c69911301246c16878"
    "addea8b7ea9d7aaf3ea88f4a8c37c18c81b110c13038f8a4229a4826b28962c6c17810980013c1c324980c53602a4c83a8269a896e6298982696f9"
    "acbea8af2ac02fea57f54d458088301dbeabdfd4efea0ff5a78a6dfe52714c5c13cfcc8099300b66c31c886f224164f85bfda3fe55094c4293c824"
    "3651202a4483e8100362422c980bf3603e2c8085b00862431cf84ffd5043cc5033cc24318b61092c8565101796c30a580949cd7033c28c34a34c3c"
    "186dc698b1669c196fe2c304b30a9299d590dc4c340920212482c49004924232480e292025a4821426a54965529b3426ad496752431a480be9203d"
    "64808c9009d29b0c26a3c90c59202b6483ec900372422ec80d994c66b306f2405ec807f9a10014844250188a40512806c5a10494844966b22905a5"
    "a10c948572501ea698a9669aa900d3cd0c53112a4165a80233cd2c33dbcc31734d55a806d5218bc96ae699f96681590beba006d4845a501bea4036"
    "93dde43039cd42b3c8ac870db01136c166d8025b611b6c875c26b7c963f29a7ca62ee43705cc62b3c4d483fad00076c04ed8050da111348626d014"
    "76c31ed80bfb603f143407e0201c8266d01c5a404b586a0ec311380ac7a0151432854d11731c4ec0493805a7e10c9c8573701e8a9a6566b959615a"
    "433153dc943017e0225c82cb7005aec235b80e37e026dc82db7007eec23db80f6da02db48307b0d2ac32abcd1ab3d6ac33ebcd0653d29432eda1b4"
    "2963ca9a0ed0113a4167d8683699cd668bd96ab699eda69cd9611ec223780c4fe0293c839d6697296f2a982e50d1ec367bcc5e53c95436554c5553"
    "cd74856ed01d7ac07378012fe115f484d7f006dec23ba86e6a989aa696a96df699fde68039680e995ed01bfa405fe807fd61000c844150c7d43583"
    "41a146c0f7f0013ec227f80c5fe02bd433f54d03d3d0fc02bfc237f80ebfc1eff007fc097fc1dff00f1cfe095423d3d834314d4d33d3dcb4302dcd"
    "1173d41c33ad0c22a145468782c7cdbfd0da9c3027cd7ff0034e99d3e68c396bce198f6dcc7973c10cc1a1380c87e345330247e2281c8d63702c8e"
    "c3f1380127e2249c8c6d4dc00818112361648c8251311ab633edcd2573d944c71878c574301d4d27d3d974315d4d37d3ddf430313116c6c6381817"
    "a7e0548c87d3b0a7e965ae9a6be6ba998ef1f186b9696e99dbe68eb96b66e04c9c85b3710ef6367d4c024c8889303126c1b9380fef99fbe681e96b"
    "fa99fe668079689262324c8e03cd2033d83c328fcd13f3d4a4c0f9a848534a5c800b3115a6c6349816810c211159627224e42950044a87e9310366"
    "c44c9819b360567c669e9b881489225314ca86d9310746a568b40817e30bf3d244a757e6b57963de9a25b81497e13b138372624c8a45efcd07f3d1"
    "7c329fcd17f3d5fc6272616ecc83793136fd6abe997c981fbf9bdfccefe60f1387e2523c8a4f09282125a2c4f4a7f9cbfc6dfe31ff9affcc0f3384"
    "8652124a4ac92839a5a094948a96e30a1c46c36925aec2d5b80653531a1a41236914adc575b81e37e046dc8405b02016c2c2b8198b60512c86c5b1"
    "0496c4d1b405b7e236dc8ea5b03496c1b2580ecb6305ac8895b032eec02a5815ab6175ac813571278ea1b1348e6ae12edc8db5713c4da03d5807eb"
    "623dac8f69291da5a706d8101b6106ca4899682feec3fd78000fe2219c489368324da1a9348da6d30c9a49b36836cda1b99499b250569a47f3291b"
    "65a71c94930ee3113c8ac73017e5a63c9497f2517e2a400b68212da2c5b4841ae3522a4885a83015a1a2548c8a53092a49a5e8389ec0d2b48c9653"
    "136c8a65a82c95a3f2b4829ae14a5a45ab690dada5757412d7d3066a8e2db025b6c2d6d806db623b6c8f1db00255a44ad4113b6167dc489b68339d"
    "c22d741acfe0593c87e7f1025ec4ca5485ba6057ec86ddb1076ea56db49d765055aa4697f0325ec1ab780dafe30dbc89d5a906eda49eb88b76d31e"
    "da4bfb683ff5c2de780b6fe31dbc8bf7f03ef6c19a548b6a531d7a8007e8201da2c374848ed2313a4e27e8249da2ba548fead3693a4367e91c35a0"
    "86d4881ad379ba4017e9213ec2c7f804fb623fec8f0370205ea2cb7485aed235ba4e37e8293ec341f81c07a3b2dabec097d8849a52336a4e37e916"
    "b5a057f81ac1dea63b74f7a764d192b5966d4bba47f7e901bdc1b7f80e1fd2236a45ada90db5a576d49e3a5047ea44efd159b18fe909791b6c041b"
    "d146b21ff02346b6516c54fb093fe317fc8abfe0aff80dbfe36f18cd46b7316c67ea42316d2c1bdbc6b1bfe31ff827fe857fe33ff82ffe874fe919"
    "fdc02176a87d4e2fa82b75a3ee34cc0eb723ec483bca8eb663ec58fb925ed1383bde4eb013ed243bd94eb1536d0fea49bda837bda637d487e2dabe"
    "14cfc6b7fda83f25b0096d229bd84eb349ec001a48836830bda577f49e92da6436b94df1f30e684e6953d9d476ba9d613f10f04c3bcbcefe991bc8"
    "696c5a9bcea6b7196c46fb913ed167fa4273ecdc9fd360799e9d6f17d8853693cd6c99bfd22fb4c82eb64bac63e15fe91b7da7a576995d6e57d895"
    "76955d6dd7d8b5368bcd6ab3d9ec3687cd697359cfb9ed3abbde6eb01bed26bbd9e6b179ed6ff43bfd417fd25ff437e5b3ffd0bf1438026fb15bed"
    "36bbddeeb03bed2ebbdbeeb17bed3ebbdf46e4487cc0e6b7ffd10f1ac243791847e6281c95a371748ec1317938c7e2833636c7e1b85cc016b4f138"
    "3e27e0849c881373121ec12379148fe6313c96c7f1789ec01379124fe643f6b03d628fdaa45cc84ee1a93c8da7f30c9ec9b3783617b645ec313b87"
    "8fdb13f6a43d654fdb33762e9fb5e7ec799b8ce7f17c5ec00b79112fe6255cd45eb017ed255bcc16b7256c725ecacbb8a44dc1293915a7e6347cd9"
    "5eb1a56c695bc696b5697939a7e3f47cd55eb3e56c797bdddeb037ed2d7bdb56b0156d255bd966e08c9c89337316cecad9383be7e09c5cc5aee03b"
    "3617e7e6bbf69ebd6f1fd8aab69a5dc9ab783557b7356c4d5bcbd6b675ec1a7e681fd9c7b6aead67ebdb27f6a96d601bda46b6b16d629bda66b6b9"
    "6d615bda67f6b9cdc36b791dbfb02fed2bfbdabeb16fed3bfbdeaee7bc9c8f37f046dec49b790b7fb01fed56dec69fec67fbc57eb5bfd85fed37db"
    "cab6b6dfed6ff677fb87ddcef97907efe4025c900b71612ec245f94ffb976d63dbda76b6bded608b71712ec1257917efe63dbc97f7f1dff61ffbaf"
    "fdcf96e2d25c863bdab2fcc32ad7c976b65d6c57bb9f0f7037dbdd1ee443ac5d392ecf15b887ed697bd9c33f93d7b88a5c892b7315aecad5b83ad7"
    "e09adcdbf6b1e8c859578b6bf3113ecac7f8389fe0beb69fed6f07d88176901d6c873876ce89f32eb8a1ee249fe23a5c97eb717d3ecd0d78983bc3"
    "67f91c9fe70b7c912ff1651eee22b888ae214772915d1417d54573d1dd15becad7f83adfe0182ea66bc48db90937e566dc9c5bf00837d2dde496dc"
    "8a5b731b6ecbed78948be562bb382eae8be7daf32dbecda3dd1dbecb1db82377e2cedc85e3bbaedc8dc7b87bdc9d7b704feec5bdb90ff7e57e9cc0"
    "dde707fc901ff1637ec24ff9193fe717fc925ff158d79f07704297c8bde637fc9613bb242ea94be692bb142ea51bc8837830bfe3f7fc8153fdbcff"
    "5a408ca07ce44ffc99bff03837de7de5096ee24fe55b61f9857fe56ffc9d7fe3496eb2fb9da7b8a96e9a9beefee03ff92f4eedd2b8b42e9d4bef32"
    "b8bfd9898897201124a24492c81245a24a34892e3124a6cc7033dd2c37dbcd71fff0bffc1fffe08c2e938b25b1258e6476595c5c89274364a80c93"
    "e13242e6baac2e9b1b29a324be8c96313256c6497637cfcd770b5c0e9740c6cb0499289364b24c919c6eaae472b9dd42b7c84d93c56e89cbe3f2ba"
    "7c2ebf2be0a6cb0c9929b364b6cc9182ae902bec8ab8a56e995bee124a5157ccad702b5d2259e556bb356ead2beed6b9c49244924a32492e2924a5"
    "ac771bdc4657c29574a5dc5c9927f365812c9445b25896c8524925a9258d6c729bdd16b7d56d73dbdd32592e2b6487dbe976b9d2ae8c5b29655d39"
    "57de5570155d25b74a564b5a4927bbdd1eb7d7ed73fbdd01b746d6ca3aa9ecaab8aaae9a3be80eb9c36ebd6c908db249d2cb1177d4659063eeb83b"
    "e14eba53eeb43be3aabb1aaea6abe56abbcdb245b64a1d57d76d93edb24376ca5977ce9d7717dc4577c9d573f55d03d7d035728d5d13d7d45d7657"
    "dc5577cded9266eebabbe16eba8cb25bf6c85ed927fbe5803477b75c26c92c5924ab6493ec924372ca4169e15abadbee8ebbeb0ec961c925b9258f"
    "e4957c925f5ab9d6ae8d6bebdab9f6ae83ebe83ab9ceae8b2b2005a590dc73f7dd03d7d5757385e588747745a4a81493e2d2c31d9563f2d0f57425"
    "a4a4f472a5a4b49491b2524eca4b05a92895a4b7ebe3faba7eaebf1be006ba416eb0535e7bf08fdc63f7c43d75cfdc73f7c2bd74afdcf19f6717fd"
    "4fe57af627e4a49c92d37246ceca3939ff1362f117e4a2bc766fdc5bf7ce5d92cb5259aa4855a926d5a586781f7c04ffde7d701fdd2717d147f291"
    "7d141fd55f91ab724da2f99a524baecb0db929b724ba8fe163fada5247ea4a2c1fdbdf963bf2d97d715fdd2fee57574fea4b036928dfdc77f79bfb"
    "dddd957b725f1ec84389e3ff707fbabfdc23792c4fe4a93c93e7f2425eca2b792d6fa4913496bf5d5c1fcfbf95f8fe1fd744fe75ffb91f6e886f2a"
    "efe4bd7c908ff2493e4b029fd027f2897d129fd427f3cda4b9b49096d24a5a4b1b49ee53f8943e954fed87fa61beadb493f6d2413a4a27e92c5da4"
    "ab7493eef245beca709fc6a7f5e97c7a9fc167f43da4a764f2bfc8aff24dbecb6ff2bbfc217fca5f32c28ff4a3fc68ffb7fc23ffca7ff24354d001"
    "8209bd040385ded247fa4a3fe92f03648c1feb33ff8c1d0e03258bcfea07c9383fde67f3d97d0e3f5826f8897e929ffc734825f810428430240c0d"
    "c342c41029440e5142d430c54ff5d3fc743fc3cff4d142f410230c0f23c2c890d3e7f2b9fd2c3fdbcff1797c5e9fcfe7f7057c415fc8c70ca3c2e8"
    "3026ccf5f3fc7c3f36c40ab1c302bfd02ff28bfdb8303ec4097143bc30214c0c93c212bfd42ff3cbfd0abfd2c70f0942c29028acf2abfd1abfd6af"
    "f3ebfd063f394c091b7de230354c0bd3c38c30336cf2857d115fd417f3c5fdac303bcc094942d2902c240f9bfddc302fa4082943aa303f2c080bc3"
    "a2b0382c094b4309bf2c94f4cb43ea902694f2a57d19bfc56ff5dbfc76bfc3eff4bbfc6ebfc797f57bfd3ebfdf1ff007fd217fd8af082bc3aab03a"
    "94f3e57d05bf2654f4957c655fc5a70de942fa50d557f3d5fdda70c41ff5c7fc719f21640c9942e69025640dd942f670c2d7f0ebc2fa9023e40cb9"
    "42ee9027e40df942fe5020140c85424d7fd29ff2a7fd195f3814094543b1503c94082543a9b0216c0ca5439970d6d7f2b57d1d5fd7d7f3e7fc795f"
    "df37f0177cd9502e5cf497fc65dfd037f28d7d135f3e5408577c53dfcc37f71543a5b029540e55420bdfd2b7f25543b5503d5cf59bc396b0356c0b"
    "db438d5033d40a3bc2ceb02bec0e7bc2deb02fec0fad7d1bdfd6b7f3ed7d075f3bd4091d7ddd502fd40fd7fc757fc31f080d4227dfd9dff40d43a3"
    "d03834094d4317dfd577f307c3a17038340bcdc32d7fdbdff1777d77dfc3f7f4f77c8bd032dcf7bd7cabd03ab409bd7d1fdf36b40bed4387d0d73f"
    "f047c2d1d0cf1f0bc7c38970329c0aa7c39970369c0be7c385f0d03ff21d43a7f0d8f7f74ffc533fc00ff4837ce7d0255c0c97c2e570255c0dd7c2"
    "33df350cf6cffd0bffd2bff2affd1bdf2d740f3d42cff0d65f0f3742afd03bf409effc7bffc1f70dfd42ffa0227cf49ffc673f200c0c83c2e03024"
    "c2d008c3220c8ff03f369f027b")
DIR3000_SHA256 = ["2eee84f7714338442f44f8dce1a99e1d3ac8025c9510f876023f148311bfa83d",
                  "927e74789550fd81f342040ee76885d693c1a3bb0a31f4c49d838fca75d9fe95",
                  "b889f89278908ef35974103b83d994401b0544f4cf5c70bc3b4ffa7ebf256adf",
                  "9cbe7b664f68660ca02a6b7ab026a6c170d508cde7c15f89f94343253b6e1004",
                  "40a27adb26713afd5dc15276d5ebff3d75caae710542936c9dfca8e5a95a7acc",
                  "ccaa7bdf24bf1a4acfdea3ab22b7f38f0a9ca3260419ebd2b973c390d9c00d0e",
                  "5511ed572b2cc47a45f19ca16161170660f4ba8a29caf0cf2362b842f5aca7b0",
                  "1ffa90ee364e3f4e40cabc6254878b9c0b3bd5e5f1db6ddc77f175fc026f0a41",
                  "ae39e9e58e179fca76652229b4b94e8a370e1a91d4a299e04b81a94789519e89",
                  "4eab1598ad811b6c89a6269b4d4c4cecbc508f2a3a0b167ae1f136910693a850",
                  "4cb9e4ffd1ee704f923793311c13230ab1d5bd7704f47f69ca96cf738d272480",
                  "01363893b09b28ec95deeeb7dcbc2322db41c790d5f6d96f0626d7e013eb6565",
                  "ac8b3f778a21ae57d8f8f39efdae97de1c909a4588d0b7525a7b1b526e6e179f",
                  "42559599212fa90b642aa0ed05e1c0b089f4d6322fb66a7cdeba2afffd64d84a",
                  "cc9531a68604a4ecb35532581f973ca428cbf7c55b6eaf52571660957b184fb2",
                  "a12b7e8599bdf1ba1e276f8adfa122aba82ea53d14670f053909c63442fac493",
                  "172eb5c649ad4a0b1679febeac907bebe03607a65ed9f3fdf6333224c187c336"]


def dir3000_history(s):
    objs = struct.unpack("<3000H", zlib.decompress(bytes.fromhex(DIR3000_OBJS)))
    ents = [(b"f%04d" % i, (8 << 60) | objs[i], 0) for i in range(3000)]
    s.stage(131072, DIR3000_SALT, ents[:2047])           # 128 KiB microzap: the 2048th add upgrades it
    for nm, v, _cd in ents[2047:]:
        assert s.op("add", nm, 8, (v,)) == 0
    return ents


# agnoswr/fat: an empty 512-byte microzap upgraded by the 60-byte name, then f0..f9 — OpenZFS's bytes
_s = ZapScript(14, 4)
_s.stage(512, WR_FAT_SALT, [])
for _n, _o, _t, _cd in WR_FAT_ENTRIES:
    assert _s.op("add", _n.encode(), 8, ((_t << 60) | _o,)) == 0
_s.emit("fat zap: agnoswr/fat's history == OpenZFS's 2 blocks", WR_FAT_SHA256)
# agnostank/dir3000: 2,047 microzap entries, the upgrade, 953 fat adds — OpenZFS's 17 blocks (16 leaves), a checkpoint;
# then every entry of its smallest leaf removed (a leaf EMPTIED — kept, zap_shrink not built), a third of the rest
# removed, re-adds, 255-byte names (13 chunks), updates, gets, EEXIST / ENOENT
_s = ZapScript(14, 40)
_e = dir3000_history(_s)
_s.checkpoint(DIR3000_SHA256)
_lv = {}
for _nm, _v, _cd in _e:
    _lv.setdefault(_s.z.i2b(_s.z.hidx(_s.z.hash(_nm), u64z(_s.z.hdr, 32))), []).append(_nm)
_small = min(_lv.values(), key=len)
for _nm in _small:
    assert _s.op("remove", _nm) == 0
assert any(_s.z.leaf(_b).nent() == 0 for _b in _lv), "no leaf emptied"
for _i in range(0, 3000, 3):
    _s.op("remove", b"f%04d" % _i)
assert _s.op("remove", b"f0000") == ZZ["noent"]
assert _s.op("add", b"f0001", 8, (1,)) == ZZ["exist"]
for _i in range(0, 3000, 7):
    _s.op("add", b"f%04d" % _i, 8, ((8 << 60) | (5000 + _i),))
for _i in range(40):
    _s.op("add", (b"%02d-" % _i) + b"L" * 252, 8, ((8 << 60) | (9000 + _i),))
for _i in range(1, 3000, 11):
    _s.op("update", b"f%04d" % _i, 8, ((4 << 60) | _i,))
for _nm in (b"f0002", b"f0007", b"07-" + b"L" * 252, b"f0003", b"nope"):
    _s.get(_nm)
_s.emit("fat zap: agnostank/dir3000 == OpenZFS's 17 blocks; then a leaf emptied, 1/3 removed, re-adds, 255-byte names, updates, gets")


# the pointer table: names whose hashes share their top `bits` bits, so every split of their leaf sends them one way —
# the leaf's prefix reaches the table's, the embedded table moves out (a block of its own), the external one DOUBLES
# (one source block per zap_table_grow; 2 -> 4 blocks through zap_put_leaf_maybe_grow_ptrtbl, incrementally: a
# mid-grow state across ops, every split's zap_table_store writing both tables)
_PNC = {}


def prefix_names(salt, bits, want, n, ln):
    key = (salt, bits, want, ln)                  # memoised: a longer list extends the shorter one, same order
    out, i = _PNC.get(key, ([], 0))
    while len(out) < n:
        nm = (b"p%06d-" % i).ljust(ln, b"q")
        if FZ.zap_hash(salt, nm) >> (64 - bits) == want:
            out.append(nm)
        i += 1
    _PNC[key] = (out, i)
    return out[:n]


_salt = 0x5A17B8 | 1
_s = ZapScript(14, 64)
_s.stage(512, _salt, [(b"m0", (8 << 60) | 7, 0), (b"m1", (8 << 60) | 8, 0)])
for _i, _nm in enumerate(prefix_names(_salt, 12, 0x5A3, 250, 45)):
    _s.op("add", _nm, 8, ((8 << 60) | (100 + _i),))
assert u64z(_s.z.hdr, 32) >= 13 and "midgrow" in _s.saw and "external" in _s.saw, (u64z(_s.z.hdr, 32), _s.saw)
for _i in range(60):
    _s.op("add", b"spread-%03d" % _i, 8, ((8 << 60) | (1000 + _i),))
for _nm in prefix_names(_salt, 12, 0x5A3, 250, 45)[::5]:
    _s.op("remove", _nm)
_s.emit("fat zap: shared 12-bit prefixes - the table moved out and doubled, a mid-grow across ops, then removes")

# (B8 review) a doubling's SWITCH whose old-table free fails: the prefix names leave a doubling under way with its last
# block still to copy; with every zfs_zf_kill failing, an add elsewhere completes its create and then fails ZZ_IO
# through zap_put_leaf_maybe_grow_ptrtbl — NOT swallowed (the review's repro: the op answered 0 and its txg would have
# committed zt_blks_copied == zt_numblks with zt_nextblk set) — the header still mid-grow, the last block to copy
# (twice: the retry is the same); a prefix add whose split needs the table fails the same way through
# zap_expand_leaf; then, the free working, the next add switches the table and the ZAP goes on
_salt = 0x5A17B8 | 1
_s = ZapScript(14, 64)
_s.stage(512, _salt, [(b"m0", (8 << 60) | 7, 0), (b"m1", (8 << 60) | 8, 0)])
_pn = prefix_names(_salt, 12, 0x5A3, 280, 45)
_i = 0
while not (u64z(_s.z.hdr, 40) and u64z(_s.z.hdr, 48) == u64z(_s.z.hdr, 24) - 1 and u64z(_s.z.hdr, 24) >= 2):
    assert _s.op("add", _pn[_i], 8, ((8 << 60) | (100 + _i),)) == 0
    _i += 1
_nb, _sh = u64z(_s.z.hdr, 24), u64z(_s.z.hdr, 32)
_s.checkpoint()
_s.knobs(kill=1)
_fails, _j = 0, 0
while _fails < 2:
    _r = _s.op("add", b"spread-%03d" % _j, 8, ((8 << 60) | (3000 + _j),))
    _j += 1
    assert _r in (0, ZZ["io"]) and _j < 200
    if _r == ZZ["io"]:
        _fails += 1
        assert u64z(_s.z.hdr, 40) and u64z(_s.z.hdr, 48) == _nb - 1 and u64z(_s.z.hdr, 24) == _nb, "the header moved"
assert "maybe-io" in _s.z.ev, _s.z.ev
_s.checkpoint()
assert _s.op("add", _pn[_i], 8, ((8 << 60) | (100 + _i),)) == ZZ["io"]
_i += 1
_s.checkpoint()
_s.knobs(kill=0)
while u64z(_s.z.hdr, 40):
    assert _s.op("add", b"spread-%03d" % _j, 8, ((8 << 60) | (3000 + _j),)) == 0
    _j += 1
assert u64z(_s.z.hdr, 24) == 2 * _nb and u64z(_s.z.hdr, 32) == _sh + 1, "no switch"
for _k in range(_i, _i + 20):
    _s.op("add", _pn[_k], 8, ((8 << 60) | (100 + _k),))
_s.get(_pn[0])
_s.get(b"spread-000")
_s.emit("fat zap: a doubling's switch whose old-table free fails - ZZ_IO through the maybe-grow (not swallowed), the header still mid-grow; then the switch")

# (B8 review) a ZAP whose pointer table may not grow (zfs_zf_gok: a MOS ZAP in the kernel): the prefix names' leaf
# splits down to the table's prefix, then an add whose split needs the table answers ZZ_NOGROW; an update and a re-add
# into that full leaf succeed with the maybe-growth SKIPPED (OpenZFS's ignored error, nothing changed); allowed again,
# the next add moves the table out
_salt = 0x6B29 | 1
_s = ZapScript(14, 24)
_s.stage(512, _salt, [(b"g0", (8 << 60) | 3, 0)])
_s.knobs(grow=1)
_gn = prefix_names(_salt, 12, 0x2C1, 200, 45)
_i = 0
while True:
    _r = _s.op("add", _gn[_i], 8, ((8 << 60) | (400 + _i),))
    _i += 1
    assert _r in (0, ZZ["nogrow"]) and _i < 200
    if _r == ZZ["nogrow"]:
        break
assert u64z(_s.z.hdr, 24) == 0 and u64z(_s.z.hdr, 32) == 10, "the table changed"
_s.checkpoint()
assert _s.op("update", _gn[0], 8, ((4 << 60) | 1,)) == 0
assert _s.op("remove", _gn[1]) == 0
assert _s.op("add", _gn[1], 8, ((8 << 60) | 401,)) == 0
assert "skip-nogrow" in _s.z.ev, _s.z.ev
_s.checkpoint()
_s.knobs(grow=0)
assert _s.op("add", _gn[_i - 1], 8, ((8 << 60) | (400 + _i - 1),)) == 0
assert u64z(_s.z.hdr, 24) >= 1, "the table did not move out"
_s.get(_gn[0])
_s.emit("fat zap: a table that may not grow (MOS) - ZZ_NOGROW at the split, the maybe-growth skipped; then moved out")

# a normalised (TOUPPER, case-insensitive) ZAP: the hash of the upper-cased name — case variants collide (cd 0, 1, ...),
# leaves CDSORTED (the sorted cd walk); the microzap's collisions survive the upgrade with their own cd; a byte >= 128
_salt = 0x77E1 | 1
_s = ZapScript(14, 16)
_s.stage(1024, _salt, [(b"Abc", (8 << 60) | 3, 0), (b"aBC", (8 << 60) | 4, 1), (b"x" * 49, (4 << 60) | 5, 0)], nf=2)
for _i in range(260):
    _s.op("add", b"Name-%04d-padding-padding" % _i, 8, ((8 << 60) | (200 + _i),))
    _s.op("add", b"nAME-%04d-PADDING-padding" % _i, 8, ((8 << 60) | (900 + _i),))
assert _s.op("add", b"caf\xc3\xa9", 8, (1,)) == ZZ["notsup"]
_s.op("remove", b"aBC")
_s.op("add", b"ABC", 8, ((8 << 60) | 6,))
_s.get(b"ABC")
_s.emit("fat zap: normalised (TOUPPER) - CDSORTED leaves, case-folded collisions, a non-ASCII name refused")

# makefs's 128 KiB fat ZAP blocks (bs 17): 4,096 buckets, 5,118 chunks a leaf — one split
_salt = 0xC0FFEE | 1
_s = ZapScript(17, 8)
_s.stage(512, _salt, [])
for _i in range(2600):
    _s.op("add", b"mk%05d" % _i, 8, ((8 << 60) | (64 + _i),))
_s.emit("fat zap: 128 KiB blocks (makefs) - 2,600 adds, a split")

# u16-array values (an SA LAYOUTS ZAP: "%d" -> the layout's attribute numbers): arrays up to 2 KiB, updates growing
# past what a leaf can hold (zap_entry_update's EAGAIN -> a split, the update retried), gets
_salt = 0x1A70 | 1
_s = ZapScript(14, 16)
_s.stage(512, _salt, [])
for _i in range(2, 200):
    _s.op("add", b"%d" % _i, 2, tuple(range(_i % 40 + 1)))
for _i in range(2, 200, 3):
    _s.op("update", b"%d" % _i, 2, tuple(range(100 + _i % 17)))
for _i in range(2, 200, 7):
    _s.op("update", b"%d" % _i, 2, (5,))
for _nm in (b"5", b"8", b"99", b"500"):
    _s.get(_nm, 2)
_s.op("update", b"1000", 8, (1, 2, 3))
_s.emit("fat zap: u16 arrays (SA LAYOUTS) - growing updates split leaves, gets")

# the upgrade: a full 512-byte microzap (7 chunks) whose entries include a hash collision pair (cd 0 / 1) and a
# 49-byte name, re-added in chunk order with their own cd
_salt = 0x3 | 1
_c = {}
_i = 0
while True:                                    # two short names with one 28-bit hash under this salt
    _nm = b"c%d" % _i
    _h = FZ.zap_hash(_salt, _nm)
    if _h in _c:
        _pair = (_c[_h], _nm)
        break
    _c[_h] = _nm
    _i += 1
_s = ZapScript(14, 8)
_s.stage(512, _salt, [(b"a", 1, 0), (_pair[0], 2, 0), (b"y" * 49, 3, 0), (_pair[1], 4, 1), (b"b", 5, 0)])
_s.get(_pair[1])
_s.op("add", _pair[0] + b"!", 8, (6,))
_s.emit("fat zap: upgrade of a microzap holding a 28-bit collision (cd 1) and a 49-byte name")

# result codes: ZZ_IO when the next block cannot be had (a split past the image), a block's free list / chain /
# bucket pointing outside the leaf and a bad header magic — ZZ_CORRUPT, nothing outside the image written
_s = ZapScript(14, 2)
_s.stage(512, 0x99 | 1, [])
for _i in range(300):
    _s.op("add", b"io-%04d" % _i, 8, (_i,))
assert _s.n > 0
_s.emit("fat zap: a split with no block to be had answers ZZ_IO")
def _hostile(what, pokes):
    s = ZapScript(14, 4)
    s.stage(512, 0x41 | 1, [])
    for i in range(5):
        s.op("add", b"h%d" % i, 8, (i,))
    for off, val in pokes(s):
        s.poke(off, val)
    s.ops += struct.pack("<Bb", 0, ZZ["corrupt"]) + struct.pack("<H", 4) + b"evil" + struct.pack("<BHQi", 8, 1, 7, -1)
    s.emit("fat zap: hostile - %s: ZZ_CORRUPT, nothing written outside" % what, hostile=True)


_LF = 16384                                     # the leaf is block 1
_BK = lambda s, nm: _LF + 48 + 2 * ((511 & (s.z.hash(nm) >> 55)))
_CH = lambda c: _LF + 48 + 1024 + 24 * c
_hostile("its free list head past the chunks", lambda s: [(_LF + 34, 0xF0), (_LF + 35, 0xFF)])
_hostile("every bucket naming a FREE chunk", lambda s: [(_LF + 48 + _b, (600 >> (8 * (_b & 1))) & 0xFF) for _b in range(1024)])
_hostile("a chain looping on itself", lambda s: [(_BK(s, b"evil"), 0), (_BK(s, b"evil") + 1, 0), (_CH(0) + 2, 0), (_CH(0) + 3, 0)])
_hostile("a leaf prefix that is not its hash's", lambda s: [(_LF + 32, 3), (_LF + 16, (s.z.hash(b"evil") >> 61) ^ 1)])
_hostile("a bad header magic", lambda s: [(8, 0)])

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
