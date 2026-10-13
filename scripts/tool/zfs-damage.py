#!/usr/bin/env python3
# zfs-damage — break a COPY of a ZFS fixture image in exactly one named way, so the write oracle can be shown to go red
# (agnos 1.57.12 bite B0; design docs/development/proposals/2026-10-09-zfs-write.md § h B0, § i).
#
# ⭐ WHY THIS EXISTS. An oracle that has only ever said PASS has proven nothing: `zfs-fixture.sh --verify` must also
# FAIL — in the phase the design names — on an image that is wrong in a known way. OpenZFS has no tool that writes a
# wrong `smp_alloc` or drops a log-ZAP entry (zhack's `metaslab leak` writes CONSISTENT leaks through OpenZFS's own
# txg), so the defect is forged here, on the host, at the byte level:
#   flip-data       one byte of a file's L0 data block (--level L: the indirect block at level L on that block's path),
#                   every DVA copy, or only the copies --dvas names. Nothing above it is touched, so its BP checksum no
#                   longer matches. Every copy bad: zdb -cc → "Error counts" + rc 3 (A3); a scrub repairs nothing. Some
#                   copies bad (⛔ B0 review, the multi-copy case): one good copy keeps every read's io_error 0, so zdb
#                   prints NOTHING and exits 0 — only the cksum column of zdb -s's vdev table shows it (A3), and a scrub
#                   repairs it (C-scrub "repaired").
#   flip-mos-root   the same for the MOS objset block (the uberblock's rootbp), default --dvas 1,2: DVA[0] stays good, so
#                   no normal read and no read-write import ever notices (the import re-COWs the MOS root before a scrub).
#   bump-smp-alloc  one metaslab space map's bonus `smp_alloc` += DELTA (default one ashift unit) — the entries are
#                   untouched, so `zdb -mmmm` prints "INCONSISTENT" and zdb -b's class total (Σ smp_alloc +
#                   unflushed) exceeds the traversal: "block traversal size X != alloc Y (leaked DELTA)" (A3).
#   drop-log        remove the log-space-map ZAP entry of a txg that some metaslab's unflushed txg U[i] NAMES — the
#                   import path then cannot find that log: "could not find log spacemap for TXG" → ENOENT, and every
#                   zdb / import of the pool fails (A2). A txg no U[i] names would be silently harmless, so the tool
#                   reads U[] first and refuses such a pick.
#   bump-acct       --dataset DS --add FIELD=DELTA ...: dsl_dir / dsl_dataset accounting fields += DELTA (FIELD: dir.used
#                   dir.compressed dir.uncompressed dir.head dir.snap dir.child dir.child_rsrv dir.refrsrv ds.referenced
#                   ds.compressed ds.uncompressed ds.unique) — a writer's accounting slip. zdb checks none of them; the
#                   oracle's identities do (A5 referenced == Σ dsize + objset block; B-acct; D's per-dataset destroy).
#   tear-ub         a commit's uberblock write TORN by a crash: the first 512-byte sector of uberblock T (the best one
#                   with ub_txg = T; default T = best + 1, the next commit) lands in slot T % N of ONE label (--label,
#                   default 0) and the rest of the slot — its eck included — is what was there, so the copy cannot
#                   verify. OpenZFS skips it (vdev_uberblock_load_done scores only slots whose eck verified); so must
#                   agnos's write gate, and its next commit must rewrite the slot (1.57.12 B2 review, finding 1).
#   zero-u          NOT a defect — a STATE (1.57.12 B3b): U[i] = 0 for every metaslab that has a space map, a U and no
#                   entry in any log space map. With U 0 every log's entries would apply to it, so with none its state
#                   is its space map alone — exactly as before. This is an UPGRADED pool: metaslabs written before
#                   log_spacemap went active and not touched since keep U 0 (metaslab_unflushed_add sets it on first
#                   touch, metaslab.c:4025-4041) — through any number of exports, which flush only the metaslabs that
#                   have a U (spa_metaslabs_by_flushed, spa_log_spacemap.c:771, :1319-1324). The writer must then set
#                   U = T for every such metaslab its txg gives an entry (design § c.3) — zfs-write-smoke's wr@u0 lane
#                   is that path, verified by OpenZFS.
#                   1.57.12 B5: when NO such metaslab exists (a fixture build can put every metaslab with a space map
#                   into the export's last log — the r3 rebuild for B5's payload did), the verb MAKES one first: the
#                   highest metaslab with entries in the one log and none of features_for_write's DVAs gets those
#                   entries flushed into its own space map (debug word + one-word entries, smp_length / smp_alloc
#                   moved; the log loses them) — metaslab_flush, forged — and then U 0 (flush_for_u0).
#                   1.57.12 B7: and when every such metaslab holds a DVA of features_for_write's block (the B7 payload's
#                   wr rebuild has THREE metaslabs with a space map, the block's three copies one in each), one of those
#                   is flushed — pre-defer's FREE + ALLOC of that copy go into its space map with the rest (net 0, so
#                   that copy is no longer deferred) — as long as another copy's metaslab keeps its log entries: the
#                   overlap state pre-defer made stays on disk for the others (`pre>0` still).
#   pre-defer       NOT a defect — a STATE (1.57.12 B3b review): units that are ALLOCATED and, by the writer's rule,
#                   DEFERRED at mount — what a pool OpenZFS last ran at its slop leaves (it does not defer there,
#                   metaslab.c:4573-4577, :4616-4632, so a range freed in T0 - 1 is reallocated in T0) when the logs
#                   T0 - 2 .. T0 survive the export (zfs_keep_log_spacemaps_at_export = 1, spa.c:2073; the default
#                   export flushes and destroys them). One log T0 alive is all a fixture has, so the tool writes the
#                   single-log equivalent: at the END of log T0, a FREE then an ALLOC of every DVA of the block that
#                   holds features_for_write (every commit rewrites it, and its predecessor is killed FIRST, before the
#                   chain's allocations — design § d) — two later sync-pass groups, smp_alloc unchanged (net 0),
#                   smp_length + the entries. Replayed (SM, then the logs, strict) the range is still allocated; the
#                   writer's deferred rule (every FREE in a log >= T0 - 2) defers it. Its first null txg then FREES
#                   units that are already deferred: zfs_wfree_bp's zfs_xl_pre > 0, zfs_wxl_undo's evict-on-undo when
#                   a round is undone (with zero-u), zfs_wxl_apply's re-apply at a reload (one bitmap slot) — design
#                   § c.2's B3a-review note. Refused unless every DVA's metaslab has U in [1, T0] (an entry for a U 0
#                   metaslab is B3b's N3 defect) and log T0 is ONE block with room.
#   info            read-only: best uberblock, metaslab array + every SM's smp_alloc, U[], the log ZAP.
# ⛔ IN-PLACE, NOT COPY-ON-WRITE. bump-smp-alloc, bump-acct and drop-log rewrite the MOS block that holds the field and then every
# block above it (meta-dnode indirects → MOS objset_phys → the best uberblock, all four labels) AT ITS EXISTING DVAs,
# with the same psize: the new content is recompressed (lz4, a greedy encoder below; the ZFS lz4 header keeps the real
# length, so a shorter result is zero-padded to the old psize) and re-checksummed (fletcher4 / sha256), the uberblock's
# embedded SHA-256 is recomputed with its slot offset as the verifier. Writing the chain to FREE space instead would
# add a second defect (blocks the space maps call free → zdb's VERIFY0(zio_claim) abort) and confound the one under
# test. Nothing is allocated, freed or born: the image is the pristine pool with exactly one field changed and the
# checksums made consistent around it. Older uberblocks that share a rewritten block now see a checksum mismatch —
# irrelevant for B0 (zdb -t is run only on images with agnos txgs) and stated here so it is not mistaken for a bug.
# The best uberblock is rewritten AT ITS OWN TXG, so the host audit's h3 says "txg N is not newer than the pristine
# best N" on every such lane — the forgery's fingerprint, not the defect under test: read the phase the class names.
# After every edit the tool re-opens the image and re-walks the edited path with checksum verification; a chain it
# cannot verify is a tool failure (exit 2), not a damaged image.
#
# ⛔ NEVER THE CACHE. Every mutating subcommand refuses a path that resolves into the fixture cache
# (${ZFS_FIXTURE_DIR:-~/.cache/agnos/zfs-fixtures}) or that is the same inode as any cached image (a hard link would
# pass a path test). Copy the lane image out first (`cp --sparse=always`).
#
# usage: zfs-damage.py info IMG
#        zfs-damage.py flip-data IMG --dataset DS --object N [--blkid B] [--level L] [--dvas I,J] [--at BYTE]
#        zfs-damage.py flip-mos-root IMG [--dvas I,J] [--at BYTE]
#        zfs-damage.py bump-smp-alloc IMG [--metaslab I] [--delta BYTES]
#        zfs-damage.py bump-acct IMG --dataset DS --add FIELD=DELTA [--add FIELD=DELTA ...]
#        zfs-damage.py drop-log IMG [--txg T]
#        zfs-damage.py tear-ub IMG [--label L] [--txg T]
#        zfs-damage.py zero-u IMG
#        zfs-damage.py pre-defer IMG
# IMG is a WHOLE-DISK pool image (the pool on the raw device, as the fixture builds it: vdev offset == file offset).
# Exit 0 done · 1 refused (the requested damage does not exist on this image, e.g. no U[i] names any log) · 2 tool or
# input failure. Prints one `zfs-damage: <verb> ...` result line naming what changed (offsets in zdb's DVA notation).
import hashlib, os, struct, sys

LABEL = 256 * 1024
VDEV_START = 4 * 1024 * 1024        # VDEV_LABEL_START_SIZE: 2 labels + the 3.5 MiB boot region before DVA offset 0
UB_MAGIC = 0x00bab10c
ZEC_MAGIC = 0x0210da7ab10c7a11
M64 = (1 << 64) - 1
CK_FLETCHER4, CK_SHA256 = 7, 8
COMP_OFF, COMP_ZLE, COMP_LZ4 = 2, 14, 15
CK_NAMES = {2: "off", 6: "fletcher2", 7: "fletcher4", 8: "sha256", 11: "sha512", 12: "skein", 13: "edonr", 14: "blake3"}


class ToolError(Exception):
    pass


class Refused(Exception):
    pass


# ------------------------------------------------------------------------------------------------
# codecs
# ------------------------------------------------------------------------------------------------
def fletcher4(b):
    a = bb = c = d = 0
    for (w,) in struct.iter_unpack("<I", b):
        a = (a + w) & M64
        bb = (bb + a) & M64
        c = (c + bb) & M64
        d = (d + c) & M64
    return [a, bb, c, d]


def sha256_words(b):
    d = hashlib.sha256(b).digest()
    return [int.from_bytes(d[i:i + 8], "big") for i in range(0, 32, 8)]


def checksum(ck, b):
    if ck == CK_FLETCHER4:
        return fletcher4(b)
    if ck == CK_SHA256:
        return sha256_words(b)
    raise ToolError("checksum %s is not implemented here" % CK_NAMES.get(ck, ck))


def lz4_block_decode(b, cap):
    i, n, out = 0, len(b), bytearray()
    while i < n:
        tok = b[i]; i += 1
        lit = tok >> 4
        if lit == 15:
            while True:
                s = b[i]; i += 1; lit += s
                if s != 255:
                    break
        out += b[i:i + lit]; i += lit
        if i >= n:
            break
        off = b[i] | (b[i + 1] << 8); i += 2
        ml = tok & 15
        if ml == 15:
            while True:
                s = b[i]; i += 1; ml += s
                if s != 255:
                    break
        ml += 4
        if off == 0 or off > len(out):
            raise ToolError("lz4: bad match offset")
        for _ in range(ml):
            out.append(out[-off])
        if len(out) > cap:
            raise ToolError("lz4: output overrun")
    return bytes(out)


def lz4_varlen(v):
    out = bytearray()
    while v >= 255:
        out.append(255); v -= 255
    out.append(v)
    return out


def lz4_block_encode(src):
    """Greedy LZ4 block encoder honouring the block-format end rules (last 5 bytes literal, no match starting in the
    last 12) — the ZFS decoder enforces them."""
    n, out, table = len(src), bytearray(), {}
    anchor = i = 0
    limit = n - 12
    while i < limit:
        key = src[i:i + 4]
        cand = table.get(key)
        table[key] = i
        if cand is None or i - cand > 65535:
            i += 1
            continue
        m, maxm = 4, n - 5 - i
        while m < maxm and src[cand + m] == src[i + m]:
            m += 1
        lits = src[anchor:i]
        ll, ml = len(lits), m - 4
        out.append(((15 if ll >= 15 else ll) << 4) | (15 if ml >= 15 else ml))
        if ll >= 15:
            out += lz4_varlen(ll - 15)
        out += lits
        out += struct.pack("<H", i - cand)
        if ml >= 15:
            out += lz4_varlen(ml - 15)
        i += m
        anchor = i
        if i - 2 > 0 and i - 2 < limit:
            table[src[i - 2:i + 2]] = i - 2
    lits = src[anchor:]
    ll = len(lits)
    out.append((15 if ll >= 15 else ll) << 4)
    if ll >= 15:
        out += lz4_varlen(ll - 15)
    out += lits
    return bytes(out)


def zfs_lz4_decode(src, lsize):
    (bufsiz,) = struct.unpack(">I", src[:4])
    if bufsiz + 4 > len(src):
        raise ToolError("lz4: header length %d exceeds the block" % bufsiz)
    out = lz4_block_decode(src[4:4 + bufsiz], lsize)
    if len(out) != lsize:
        raise ToolError("lz4: decoded %d bytes, BP says %d" % (len(out), lsize))
    return out


def zfs_lz4_encode(src):
    blk = lz4_block_encode(src)
    assert lz4_block_decode(blk, len(src)) == src, "lz4 encoder round trip"
    return struct.pack(">I", len(blk)) + blk


# ------------------------------------------------------------------------------------------------
# XDR nvlist (labels, the MOS config object) — read-only
# ------------------------------------------------------------------------------------------------
def zle_decode(src, lsize, n=64):
    """zle_decompress_buf (zle.c), n = 64 (zio_compress.c's ZLE level): a byte < n starts a literal of byte + 1
    bytes, any other a run of byte - n + 1 zeros; it stops once lsize bytes are out (a writer zero-pads its output to
    the allocation unit). agnos writes ZLE MOS blocks (1.57.12 B3)."""
    out, i = bytearray(), 0
    while i < len(src) and len(out) < lsize:
        k = src[i] + 1
        i += 1
        if k <= n:
            if i + k > len(src):
                raise ToolError("ZLE literal past the end of the block")
            out += src[i:i + k]
            i += k
        else:
            out += bytes(k - n)
    if len(out) != lsize:
        raise ToolError("ZLE block decodes to %d bytes, lsize %d" % (len(out), lsize))
    return bytes(out)


def nvlist(b, off):
    """Parse one nvlist at off (version, nvflag, pairs, terminator) -> (dict, end offset)."""
    off += 8
    out = {}
    while True:
        esize, dsize = struct.unpack_from(">ii", b, off)
        if esize == 0 and dsize == 0:
            return out, off + 8
        p = off + 8
        nlen = struct.unpack_from(">I", b, p)[0]; p += 4
        name = b[p:p + nlen].decode(); p += (nlen + 3) & ~3
        dtype, nelem = struct.unpack_from(">ii", b, p); p += 8
        if dtype == 8:                                   # UINT64
            out[name] = struct.unpack_from(">Q", b, p)[0]
        elif dtype == 9:                                 # STRING
            slen = struct.unpack_from(">I", b, p)[0]
            out[name] = b[p + 4:p + 4 + slen].decode()
        elif dtype == 19:                                # NVLIST
            out[name] = nvlist(b, p)[0]
        elif dtype == 20:                                # NVLIST_ARRAY
            arr = []
            for _ in range(nelem):
                v, p = nvlist(b, p)
                arr.append(v)
            out[name] = arr
        off += esize                                     # encoded size covers embedded lists too


# ------------------------------------------------------------------------------------------------
# block pointers
# ------------------------------------------------------------------------------------------------
class BP:
    def __init__(self, raw):
        self.raw = bytes(raw)
        self.w = list(struct.unpack("<16Q", self.raw))
        prop = self.w[6]
        self.embedded = (prop >> 39) & 1
        self.comp = (prop >> 32) & 0x7F
        self.type = (prop >> 48) & 0xFF
        self.level = (prop >> 56) & 0x1F
        self.dedup = (prop >> 62) & 1
        self.birth = self.w[10]
        # (1.57.12 B9 review) BP_GET_BIRTH (spa.h): the PHYSICAL birth under blk_prop2's rewrite flag (bit 63 of word 7)
        # — 0 there means the logical one — never for an embedded BP; what a kill, a deadlist entry and a traversal
        # compare (dsl_dataset_block_kill, dsl_deadlist_insert, get_birth_time) and the writer's zfs_bp_birth
        self.gbirth = self.w[10] if ((prop >> 39) & 1) or not (self.w[7] >> 63) else (self.w[9] or self.w[10])
        self.fill = self.w[11]
        if self.embedded:
            self.lsize = (prop & 0x1FFFFFF) + 1
            self.psize = ((prop >> 25) & 0x7F) + 1
            self.cksum = 2
            self.dvas = []
        else:
            self.lsize = ((prop & 0xFFFF) + 1) << 9
            self.psize = (((prop >> 16) & 0xFFFF) + 1) << 9
            self.cksum = (prop >> 40) & 0xFF
            self.dvas = []
            for d in range(3):
                w0, w1 = self.w[2 * d], self.w[2 * d + 1]
                if w0 == 0 and w1 == 0:
                    continue
                self.dvas.append(((w0 >> 32) & 0xFFFFFFFF, (w1 & ((1 << 63) - 1)) << 9,
                                  (w0 & 0xFFFFFF) << 9, w1 >> 63))
        self.hole = (not self.embedded) and self.w[0] == 0 and self.w[1] == 0

    def dva_str(self):
        return " ".join("DVA[%d]=<%d:%x:%x>" % (i, v, o, a) for i, (v, o, a, _g) in enumerate(self.dvas))

    def embedded_payload(self):
        words = [0, 1, 2, 3, 4, 5, 7, 8, 9, 11, 12, 13, 14, 15]   # every word but blk_prop (6) and logical birth (10)
        b = b"".join(struct.pack("<Q", self.w[i]) for i in words)
        return b[:self.psize]

    def with_embedded_payload(self, payload, psize):
        if psize > 112:
            raise ToolError("re-embedded payload is %d bytes, BPE_PAYLOAD_SIZE is 112" % psize)
        w = list(self.w)
        prop = w[6] & ~(0x7F << 25)
        w[6] = prop | ((psize - 1) << 25)
        buf = payload + bytes(112 - len(payload))
        for k, i in enumerate([0, 1, 2, 3, 4, 5, 7, 8, 9, 11, 12, 13, 14, 15]):
            w[i] = struct.unpack_from("<Q", buf, 8 * k)[0]
        return struct.pack("<16Q", *w)

    def with_cksum(self, ck):
        w = list(self.w)
        w[12:16] = ck
        return struct.pack("<16Q", *w)


# ------------------------------------------------------------------------------------------------
# the image
# ------------------------------------------------------------------------------------------------
class Node:
    """A block read through its BP; `ref` says where that BP lives: ('ub',) or (parent Node, byte offset)."""

    def __init__(self, bp, ref, content):
        self.bp, self.ref, self.content = bp, ref, bytearray(content)


class Pool:
    def __init__(self, path, write=False):
        self.path = path
        self.f = open(path, "r+b" if write else "rb")
        self.size = os.path.getsize(path) // LABEL * LABEL
        self.writes = []
        lab0 = self.read(0, LABEL)
        if lab0[16384:16388] != b"\x01\x01\x00\x00":
            raise ToolError("%s: label 0 has no XDR nvlist — not a ZFS whole-disk image" % path)
        self.label = nvlist(lab0, 16388)[0]
        vt = self.label.get("vdev_tree", {})
        self.ashift = vt.get("ashift", 9)
        self.ms_shift = vt.get("metaslab_shift")
        self.ms_array = vt.get("metaslab_array")
        self.asize = vt.get("asize")
        self.ub_shift = min(max(self.ashift, 10), 13)
        self.ub_size = 1 << self.ub_shift
        self.best_ub()

    def label_base(self, l):
        return (0, LABEL, self.size - 2 * LABEL, self.size - LABEL)[l]

    def read(self, off, n):
        self.f.seek(off)
        b = self.f.read(n)
        if len(b) != n:
            raise ToolError("short read at %#x" % off)
        return b

    def write(self, off, b):
        self.f.seek(off)
        self.f.write(b)
        self.writes.append((off, len(b)))

    # --- uberblocks --------------------------------------------------------------------------
    def slot_ok(self, off, slot):
        if struct.unpack_from("<Q", slot, 0)[0] != UB_MAGIC:
            return False
        e = len(slot) - 40
        if struct.unpack_from("<Q", slot, e)[0] != ZEC_MAGIC:
            return False
        want = list(struct.unpack_from("<4Q", slot, e + 8))
        tmp = bytearray(slot)
        struct.pack_into("<4Q", tmp, e + 8, off, 0, 0, 0)
        return sha256_words(bytes(tmp)) == want

    def best_ub(self):
        best = None
        self.ub_slots = []
        for l in range(4):
            base = self.label_base(l) + 128 * 1024
            for s in range(128 * 1024 // self.ub_size):
                off = base + s * self.ub_size
                slot = self.read(off, self.ub_size)
                if not self.slot_ok(off, slot):
                    continue
                txg, ts = struct.unpack_from("<Q", slot, 16)[0], struct.unpack_from("<Q", slot, 32)[0]
                self.ub_slots.append((off, txg, ts, slot))
                if best is None or (txg, ts) > (best[1], best[2]):
                    best = (off, txg, ts, slot)
        if best is None:
            raise ToolError("no valid uberblock in any label")
        self.ub = best
        self.txg = best[1]
        self.rootbp = BP(best[3][40:168])

    def write_rootbp(self, newbp):
        """Rewrite every copy of the best uberblock (same txg + timestamp + bytes) with a new rootbp and its eck."""
        n = 0
        for off, txg, ts, slot in self.ub_slots:
            if txg != self.txg or slot[:self.ub_size - 40] != self.ub[3][:self.ub_size - 40]:
                continue
            s = bytearray(slot)
            s[40:168] = newbp
            e = self.ub_size - 40
            struct.pack_into("<Q4Q", s, e, ZEC_MAGIC, off, 0, 0, 0)
            ck = sha256_words(bytes(s))
            struct.pack_into("<4Q", s, e + 8, *ck)
            self.write(off, bytes(s))
            n += 1
        if n == 0:
            raise ToolError("no uberblock copy to rewrite")
        return n

    # --- blocks ------------------------------------------------------------------------------
    def read_bp(self, bp, verify=True):
        if bp.hole:
            raise ToolError("read of a hole")
        if bp.embedded:
            phys = bp.embedded_payload()
        else:
            if any(g for (_v, _o, _a, g) in bp.dvas):
                raise ToolError("gang block on the path — not supported")
            phys, err = None, "no DVA"
            for (_v, o, _a, _g) in bp.dvas:
                b = self.read(VDEV_START + o, bp.psize)
                if not verify or bp.cksum == 2 or checksum(bp.cksum, b) == bp.w[12:16]:
                    phys = b
                    break
                err = "checksum mismatch at <0:%x:%x>" % (o, bp.psize)
            if phys is None:
                raise ToolError("block unreadable: %s" % err)
        if bp.comp == COMP_LZ4:
            return zfs_lz4_decode(phys, bp.lsize)
        if bp.comp == COMP_ZLE:
            return zle_decode(phys, bp.lsize)
        if bp.comp == COMP_OFF or (bp.comp == 0 and not bp.embedded):
            return phys[:bp.lsize]
        raise ToolError("compression %d is not implemented here" % bp.comp)

    def node(self, bp, ref):
        return Node(bp, ref, self.read_bp(bp))

    def commit(self, node):
        """Write node.content back in place (same DVAs, same psize) and propagate the new BP up to the uberblock."""
        bp = node.bp
        content = bytes(node.content)
        if bp.embedded:
            if bp.comp != COMP_LZ4:
                raise ToolError("embedded BP with compression %d" % bp.comp)
            enc = zfs_lz4_encode(content)
            newbp = bp.with_embedded_payload(enc, len(enc))
        else:
            if bp.comp == COMP_LZ4:
                enc = zfs_lz4_encode(content)
            elif bp.comp == COMP_OFF:
                enc = content
            else:
                raise ToolError("compression %d is not implemented here" % bp.comp)
            if len(enc) > bp.psize:
                raise ToolError("re-encoded block is %d bytes, its psize is %d — cannot rewrite in place"
                                % (len(enc), bp.psize))
            phys = enc + bytes(bp.psize - len(enc))
            for (_v, o, _a, _g) in bp.dvas:
                self.write(VDEV_START + o, phys)
            newbp = bp.with_cksum(checksum(bp.cksum, phys))
        if node.ref[0] == "ub":
            self.write_rootbp(newbp)
        else:
            parent, off = node.ref
            parent.content[off:off + 128] = newbp
            self.commit(parent)

    # --- dnodes and objects --------------------------------------------------------------------
    def mos(self):
        return self.node(self.rootbp, ("ub",))

    def walk(self, holder, dn_off, blkid, want=0):
        """The level-`want` block on L0 block `blkid`'s path (want 0: that L0) of the object whose dnode sits at
        holder.content[dn_off:]; None for a hole."""
        dn = holder.content[dn_off:dn_off + 512]
        nlevels, nblkptr, ibs = dn[2], dn[3], dn[1]
        if not 0 <= want < nlevels:
            raise Refused("level %d does not exist: the object has %d level(s)" % (want, nlevels))
        epbs = ibs - 7
        top = blkid >> (epbs * (nlevels - 1))
        if top >= nblkptr:
            return None
        ref = (holder, dn_off + 64 + 128 * top)
        bp = BP(holder.content[ref[1]:ref[1] + 128])
        for level in range(nlevels - 1, want, -1):
            if bp.hole:
                return None
            nd = self.node(bp, ref)
            i = (blkid >> (epbs * (level - 1))) & ((1 << epbs) - 1)
            ref = (nd, 128 * i)
            bp = BP(nd.content[128 * i:128 * i + 128])
        if bp.hole:
            return None
        return self.node(bp, ref)

    def dnode(self, os_node, obj):
        """(holder Node, offset) of object obj's dnode in the objset whose objset_phys is os_node.content."""
        md = os_node.content[0:512]
        blksz = struct.unpack_from("<H", md, 8)[0] * 512
        per = blksz // 512
        blk = self.walk(os_node, 0, obj // per)
        if blk is None:
            raise ToolError("object %d: its meta-dnode block is a hole" % obj)
        off = (obj % per) * 512
        if blk.content[off] == 0:
            raise ToolError("object %d is not allocated" % obj)
        return blk, off

    def object_data(self, holder, off):
        dn = holder.content[off:off + 512]
        blksz = struct.unpack_from("<H", dn, 8)[0] * 512
        maxblkid = struct.unpack_from("<Q", dn, 16)[0]
        out = bytearray()
        for b in range(maxblkid + 1):
            nd = self.walk(holder, off, b)
            out += nd.content if nd is not None else bytes(blksz)
        return bytes(out)

    def bonus(self, holder, off):
        dn = holder.content[off:off + 512]
        nblkptr, bonuslen = dn[3], struct.unpack_from("<H", dn, 10)[0]
        return off + 64 + 128 * nblkptr, bonuslen

    # --- ZAP ---------------------------------------------------------------------------------
    def zap(self, holder, off):
        """name -> (value bytes, intlen); plus the micro entries' locations for in-place removal."""
        dn = holder.content[off:off + 512]
        blksz = struct.unpack_from("<H", dn, 8)[0] * 512
        maxblkid = struct.unpack_from("<Q", dn, 16)[0]
        b0 = self.walk(holder, off, 0)
        if b0 is None:
            raise ToolError("ZAP block 0 is a hole")
        btype = struct.unpack_from("<Q", b0.content, 0)[0]
        out = {}
        if btype == (1 << 63) + 3:                                   # ZBT_MICRO
            for e in range(64, len(b0.content), 64):
                val, cd = struct.unpack_from("<QI", b0.content, e)
                name = bytes(b0.content[e + 14:e + 64]).split(b"\0")[0]
                if name:
                    out[name.decode()] = ("micro", val, b0, e)
            return out
        if btype != (1 << 63) + 1:                                   # ZBT_HEADER
            raise ToolError("ZAP block 0 type %#x" % btype)
        for blkid in range(1, maxblkid + 1):
            lf = self.walk(holder, off, blkid)
            if lf is None:
                continue
            c = lf.content
            if struct.unpack_from("<Q", c, 0)[0] != (1 << 63) or struct.unpack_from("<I", c, 24)[0] != 0x2AB1EAF:
                continue
            bs = blksz.bit_length() - 1
            nhash = 1 << (bs - 5)
            base = 48 + 2 * nhash
            nchunks = (blksz - 2 * nhash) // 24 - 2

            def chunk(i):
                return base + 24 * i

            def array(first, nbytes):
                b, i = bytearray(), first
                while len(b) < nbytes:
                    p = chunk(i)
                    b += c[p + 1:p + 22]
                    i = struct.unpack_from("<H", c, p + 22)[0]
                return bytes(b[:nbytes])
            for i in range(nchunks):
                p = chunk(i)
                if c[p] != 252:
                    continue
                vint, _nx, nch, nnum, vch, vnum = struct.unpack_from("<BHHHHH", c, p + 1)
                name = array(nch, nnum).rstrip(b"\0").decode()
                val = array(vch, vint * vnum)
                v = int.from_bytes(val[:8], "big") if vint == 8 and vnum >= 1 else val
                out[name] = ("fat", v, lf, p)
        return out

    def zap_u64(self, holder, off, name):
        z = self.zap(holder, off)
        if name not in z:
            raise ToolError("ZAP has no %r" % name)
        return z[name][1]

    # --- DSL ---------------------------------------------------------------------------------
    def dataset_objset(self, mos, name):
        """objset Node of the head dataset `name` (pool/child/...)."""
        parts = name.strip("/").split("/")
        dirobj = self.zap_u64(*self.dnode(mos, 1), "root_dataset")
        for child in parts[1:]:
            h, o = self.dnode(mos, dirobj)
            b, _ = self.bonus(h, o)
            czap = struct.unpack_from("<Q", h.content, b + 32)[0]
            dirobj = self.zap_u64(*self.dnode(mos, czap), child)
        h, o = self.dnode(mos, dirobj)
        b, _ = self.bonus(h, o)
        dsobj = struct.unpack_from("<Q", h.content, b + 8)[0]
        h, o = self.dnode(mos, dsobj)
        b, _ = self.bonus(h, o)
        ref = (h, b + 128)
        return self.node(BP(h.content[b + 128:b + 256]), ref)

    # --- space ---------------------------------------------------------------------------------
    def space_info(self, mos):
        ms_count = self.asize >> self.ms_shift
        h, o = self.dnode(mos, self.ms_array)
        arr = self.object_data(h, o)
        sms = [struct.unpack_from("<Q", arr, 8 * i)[0] for i in range(ms_count)]
        cfg_obj = self.zap_u64(*self.dnode(mos, 1), "config")
        h, o = self.dnode(mos, cfg_obj)
        b, _ = self.bonus(h, o)
        cfg_len = struct.unpack_from("<Q", h.content, b)[0]
        cfg = self.object_data(h, o)[:cfg_len]
        if cfg[:4] != b"\x01\x01\x00\x00":
            raise ToolError("MOS config is not an XDR nvlist")
        config = nvlist(cfg, 4)[0]
        top = config["vdev_tree"]["children"][0]
        topzap = top.get("com.delphix:vdev_zap_top")
        U = [0] * ms_count
        if topzap:
            z = self.zap(*self.dnode(mos, topzap))
            if "com.delphix:ms_unflushed_phys_txgs" in z:
                h, o = self.dnode(mos, z["com.delphix:ms_unflushed_phys_txgs"][1])
                ua = self.object_data(h, o)
                U = [struct.unpack_from("<Q", ua, 8 * i)[0] for i in range(ms_count)]
        mosdir = self.zap(*self.dnode(mos, 1))
        logs = {}
        if "com.delphix:log_spacemap_zap" in mosdir:
            for name, (_k, v, _n, _p) in self.zap(*self.dnode(mos, mosdir["com.delphix:log_spacemap_zap"][1])).items():
                logs[int(name, 16)] = v
        return sms, U, logs, topzap


# ------------------------------------------------------------------------------------------------
# safety: never a cached fixture image
# ------------------------------------------------------------------------------------------------
def refuse_cache(path):
    cache = os.environ.get("ZFS_FIXTURE_DIR") or os.path.join(os.path.expanduser("~"), ".cache/agnos/zfs-fixtures")
    rp = os.path.realpath(path)
    if os.path.isdir(cache):
        rc = os.path.realpath(cache)
        if rp == rc or rp.startswith(rc + os.sep):
            raise ToolError("%s is inside the fixture cache %s — copy the image out first" % (path, rc))
        st = os.stat(rp)
        for dp, _dn, fn in os.walk(rc):
            for f in fn:
                if f.endswith(".img"):
                    s2 = os.stat(os.path.join(dp, f))
                    if (s2.st_dev, s2.st_ino) == (st.st_dev, st.st_ino):
                        raise ToolError("%s is a hard link to the cached %s" % (path, os.path.join(dp, f)))


def reverify(path, check):
    p = Pool(path)
    check(p)


# ------------------------------------------------------------------------------------------------
# verbs
# ------------------------------------------------------------------------------------------------
def cmd_info(path):
    p = Pool(path)
    mos = p.mos()
    sms, U, logs, topzap = p.space_info(mos)
    print("image %s: pool %s ashift %d, best uberblock txg %d (slot %d, %d valid slots), metaslab_shift %s, %d metaslabs"
          % (path, p.label.get("name"), p.ashift, p.txg, (p.ub[0] % LABEL - 128 * 1024) // p.ub_size,
             len(p.ub_slots), p.ms_shift, len(sms)))
    print("rootbp %s birth %d fill %d" % (p.rootbp.dva_str(), p.rootbp.birth, p.rootbp.fill))
    for i, sm in enumerate(sms):
        if sm == 0:
            print("  ms %3d  no space map            unflushed txg %d" % (i, U[i]))
            continue
        h, o = p.dnode(mos, sm)
        b, _ = p.bonus(h, o)
        _obj, length, alloc = struct.unpack_from("<QQq", h.content, b)
        print("  ms %3d  sm obj %-5d smp_length %-6d smp_alloc %-10d unflushed txg %d" % (i, sm, length, alloc, U[i]))
    print("vdev top ZAP %s; log space maps (txg -> obj): %s" % (topzap, ", ".join("%d->%d" % kv for kv in sorted(logs.items())) or "none"))
    named = sorted({u for u in U if u})
    print("txgs named by some U[i]: %s" % (", ".join(map(str, named)) or "none"))
    return 0


def flip_copies(p, bp, which, at):
    """XOR byte `at` of the DVAs `which` (indexes; None = every copy); then read EVERY copy raw and re-checksum it.
    Returns ("DVA[i]=ok|BAD ...", set of bad indexes)."""
    which = range(len(bp.dvas)) if which is None else which
    for i in which:
        if not 0 <= i < len(bp.dvas):
            raise Refused("DVA[%d] does not exist: the BP has %d copy(ies) (%s)" % (i, len(bp.dvas), bp.dva_str()))
        _v, off, _a, _g = bp.dvas[i]
        b = p.read(VDEV_START + off + at, 1)
        p.write(VDEV_START + off + at, bytes([b[0] ^ 0xFF]))
    p.f.flush()
    res, bad = [], set()
    for i, (_v, off, _a, _g) in enumerate(bp.dvas):
        ok = checksum(bp.cksum, p.read(VDEV_START + off, bp.psize)) == bp.w[12:16]
        res.append("DVA[%d]=%s" % (i, "ok" if ok else "BAD"))
        if not ok:
            bad.add(i)
    return " ".join(res), bad


def cmd_flip(path, ds, obj, blkid, at, level, which):
    refuse_cache(path)
    p = Pool(path, write=True)
    mos = p.mos()
    osn = p.dataset_objset(mos, ds)
    h, o = p.dnode(osn, obj)
    nd = p.walk(h, o, blkid, level)
    if nd is None:
        raise Refused("%s object %d blkid %d level %d is a hole" % (ds, obj, blkid, level))
    bp = nd.bp
    if bp.embedded or not bp.dvas:
        raise Refused("%s object %d blkid %d is an embedded BP — no data block to flip" % (ds, obj, blkid))
    if bp.cksum not in (CK_FLETCHER4, CK_SHA256):
        raise Refused("the block's checksum is %s — this tool verifies fletcher4 / sha256 only" % CK_NAMES.get(bp.cksum, bp.cksum))
    at = bp.psize // 2 if at is None else at
    if not 0 <= at < bp.psize:
        raise ToolError("--at %d is outside the block's psize %d" % (at, bp.psize))
    res, bad = flip_copies(p, bp, which, at)
    want = set(range(len(bp.dvas))) if which is None else set(which)
    if bad != want:
        raise ToolError("after the flip the copies read %s, wanted exactly DVA%s bad" % (res, sorted(want)))
    p.f.close()
    if bad == set(range(len(bp.dvas))):
        # every copy bad: an ordinary read must now fail outright
        q = Pool(path)
        h, o = q.dnode(q.dataset_objset(q.mos(), ds), obj)
        try:
            q.walk(h, o, blkid, level)
            raise ToolError("after the flip the block still verifies — nothing was damaged")
        except ToolError as e:
            if "checksum mismatch" not in str(e) and "unreadable" not in str(e):
                raise
    print("zfs-damage: flip-data %s object %d L%d (blkid %d path) %s [%s %s] byte %d of %d XOR 0xff -> %s%s"
          % (ds, obj, level, blkid, bp.dva_str(), CK_NAMES.get(bp.cksum, bp.cksum),
             "lz4" if bp.comp == COMP_LZ4 else "comp %d" % bp.comp, at, bp.psize, res,
             "" if len(bad) == len(bp.dvas) else " — a good copy remains: only a read of EVERY copy (zdb -cc, scrub) sees it"))
    return 0


def cmd_flip_root(path, which, at):
    refuse_cache(path)
    p = Pool(path, write=True)
    bp = p.rootbp
    which = [1, 2] if which is None else which
    if len(bp.dvas) < 2:
        raise Refused("the MOS objset block has %d copy(ies) — no ditto copy to damage" % len(bp.dvas))
    which = [i for i in which if i < len(bp.dvas)]
    at = bp.psize // 2 if at is None else at
    res, bad = flip_copies(p, bp, which, at)
    if bad != set(which):
        raise ToolError("after the flip the copies read %s, wanted exactly DVA%s bad" % (res, sorted(which)))
    p.f.close()
    Pool(path).mos()                      # the chain still reads (through the good copy)
    print("zfs-damage: flip-mos-root uberblock txg %d rootbp %s byte %d of %d XOR 0xff -> %s — DVA[0] stays good: a normal "
          "read never notices, only zdb -cc's scrub-flagged read of every copy does"
          % (p.txg, bp.dva_str(), at, bp.psize, res))
    return 0


# dsl_dir_phys_t / dsl_dataset_phys_t (include/sys/dsl_dir.h:69-92, dsl_dataset.h:140-158): bonus byte offsets
ACCT_FIELDS = {
    "dir.used": ("dir", 40), "dir.compressed": ("dir", 48), "dir.uncompressed": ("dir", 56),
    "dir.head": ("dir", 104), "dir.snap": ("dir", 112), "dir.child": ("dir", 120), "dir.child_rsrv": ("dir", 128),
    "dir.refrsrv": ("dir", 136),
    "ds.referenced": ("ds", 72), "ds.compressed": ("ds", 80), "ds.uncompressed": ("ds", 88), "ds.unique": ("ds", 96),
}


def cmd_bump_acct(path, ds, adds):
    refuse_cache(path)
    for f, _d in adds:
        if f not in ACCT_FIELDS:
            raise ToolError("unknown field %r (one of %s)" % (f, ", ".join(sorted(ACCT_FIELDS))))
    p = Pool(path)
    mos = p.mos()
    parts = ds.strip("/").split("/")
    dirobj = p.zap_u64(*p.dnode(mos, 1), "root_dataset")
    for child in parts[1:]:
        h, o = p.dnode(mos, dirobj)
        b, _ = p.bonus(h, o)
        dirobj = p.zap_u64(*p.dnode(mos, struct.unpack_from("<Q", h.content, b + 32)[0]), child)
    h, o = p.dnode(mos, dirobj)
    b, _ = p.bonus(h, o)
    dsobj = struct.unpack_from("<Q", h.content, b + 8)[0]
    p.f.close()
    out, nwrites = [], 0
    for kind, obj in (("dir", dirobj), ("ds", dsobj)):
        mine = [(ACCT_FIELDS[f][1], d, f) for f, d in adds if ACCT_FIELDS[f][0] == kind]
        if not mine:
            continue
        # a FRESH pool per object: the dsl_dir and dsl_dataset dnodes can share a meta-dnode block, and the first
        # commit rewrote it — a stale in-memory copy would undo that edit
        q = Pool(path, write=True)
        h, o = q.dnode(q.mos(), obj)
        b, _ = q.bonus(h, o)
        for off, d, f in mine:
            old = struct.unpack_from("<Q", h.content, b + off)[0]
            new = (old + d) & M64
            struct.pack_into("<Q", h.content, b + off, new)
            out.append("%s %d -> %d" % (f, old, new))
        q.commit(h)
        nwrites += len(q.writes)
        q.f.close()
    r = Pool(path)                        # chain re-reads with checksums, fields as written
    rm = r.mos()
    for kind, obj in (("dir", dirobj), ("ds", dsobj)):
        h, o = r.dnode(rm, obj)
        b, _ = r.bonus(h, o)
    print("zfs-damage: bump-acct %s (dsl_dir obj %d, dsl_dataset obj %d): %s; rewrote %d block(s)/label slot(s) in place, "
          "chain re-verified at txg %d" % (ds, dirobj, dsobj, "; ".join(out), nwrites, r.txg))
    return 0


def cmd_bump(path, ms, delta):
    refuse_cache(path)
    p = Pool(path, write=True)
    mos = p.mos()
    sms, U, logs, _ = p.space_info(mos)
    delta = (1 << p.ashift) if delta is None else delta
    if ms is None:
        ms = next((i for i, s in enumerate(sms) if s), None)
        if ms is None:
            raise Refused("no metaslab has a space map")
    if not 0 <= ms < len(sms) or sms[ms] == 0:
        raise Refused("metaslab %s has no space map object" % ms)
    h, o = p.dnode(mos, sms[ms])
    b, blen = p.bonus(h, o)
    if blen < 24:
        raise ToolError("space map %d bonus is %d bytes" % (sms[ms], blen))
    old = struct.unpack_from("<q", h.content, b + 16)[0]
    struct.pack_into("<q", h.content, b + 16, old + delta)
    p.commit(h)
    p.f.close()

    def check(q):
        hh, oo = q.dnode(q.mos(), sms[ms])
        bb, _ = q.bonus(hh, oo)
        now = struct.unpack_from("<q", hh.content, bb + 16)[0]
        if now != old + delta:
            raise ToolError("re-read smp_alloc %d, wanted %d" % (now, old + delta))
        if q.txg != p.txg:
            raise ToolError("best uberblock moved from txg %d to %d" % (p.txg, q.txg))
    reverify(path, check)
    print("zfs-damage: bump-smp-alloc metaslab %d space map obj %d smp_alloc %d -> %d (+%d); rewrote %d block(s)/label slot(s) in place, chain re-verified at txg %d"
          % (ms, sms[ms], old, old + delta, delta, len(p.writes), p.txg))
    return 0


def cmd_droplog(path, txg):
    refuse_cache(path)
    p = Pool(path, write=True)
    mos = p.mos()
    sms, U, logs, _ = p.space_info(mos)
    named = sorted({u for u in U if u})
    if txg is None:
        pick = [t for t in named if t in logs]
        if not pick:
            raise Refused("no metaslab's unflushed txg names a log space map (U[] = %s, logs = %s) — dropping any log "
                          "entry would be harmless, so this damage class does not exist on this image"
                          % (named or "all zero", sorted(logs) or "none"))
        txg = pick[-1]
    if txg not in logs:
        raise Refused("txg %d has no log space map entry (logs: %s)" % (txg, sorted(logs)))
    if txg not in named:
        raise Refused("no U[i] names txg %d (named: %s) — dropping it would not be detected by design" % (txg, named))
    mosdir = p.zap(*p.dnode(mos, 1))
    zobj = mosdir["com.delphix:log_spacemap_zap"][1]
    z = p.zap(*p.dnode(mos, zobj))
    kind, val, nd, pos = z["%x" % txg]
    if kind != "micro":
        raise Refused("the log ZAP is a fat ZAP — removing a fat entry (chunk free + hash chain) is not built here")
    nd.content[pos:pos + 64] = bytes(64)
    p.commit(nd)
    p.f.close()

    def check(q):
        qm = q.mos()
        _s, _u, qlogs, _t = q.space_info(qm)
        if txg in qlogs:
            raise ToolError("re-read log ZAP still names txg %d" % txg)
        if sorted(qlogs) != sorted(t for t in logs if t != txg):
            raise ToolError("re-read log ZAP lost more than one entry: %s" % sorted(qlogs))
    reverify(path, check)
    ms_named = [i for i, u in enumerate(U) if u == txg]
    print("zfs-damage: drop-log removed log ZAP entry %x -> obj %d (txg %d, named by U[] of metaslab(s) %s); log ZAP obj %d, %s; rewrote %d block(s)/label slot(s) in place"
          % (txg, val, txg, ",".join(map(str, ms_named)), zobj, "embedded BP" if nd.bp.embedded else "micro block",
             len(p.writes)))
    return 0


def cmd_tear_ub(path, label, txg):
    refuse_cache(path)
    p = Pool(path, write=True)
    l = 0 if label is None else label
    if not 0 <= l < 4:
        raise Refused("label %d does not exist (0-3)" % l)
    t = p.txg + 1 if txg is None else txg
    if t <= p.txg:
        raise Refused("txg %d is not above the best uberblock's %d — a torn copy of it would tear nothing new" % (t, p.txg))
    n = 128 * 1024 // p.ub_size
    off = p.label_base(l) + 128 * 1024 + (t % n) * p.ub_size
    if (t % n) == (p.txg % n):
        raise Refused("txg %d shares slot %d with the best uberblock %d" % (t, t % n, p.txg))
    sec = bytearray(p.ub[3][:512])
    struct.pack_into("<Q", sec, 16, t)
    p.write(off, bytes(sec))
    p.f.flush()
    if p.slot_ok(off, p.read(off, p.ub_size)):
        raise ToolError("the torn slot at %#x still verifies" % off)
    p.f.close()

    def check(q):
        if q.txg != p.txg:
            raise ToolError("best uberblock moved from txg %d to %d" % (p.txg, q.txg))
    reverify(path, check)
    print("zfs-damage: tear-ub L%d slot %d (@%#x): the first 512 B of uberblock txg %d over the old slot, eck stale; "
          "best uberblock still txg %d" % (l, t % n, off, t, p.txg))
    return 0


def cmd_zero_u(path):
    refuse_cache(path)
    p = Pool(path, write=True)
    mos = p.mos()
    sms, U, logs, topzap = p.space_info(mos)
    hit = set()
    for t, o in logs.items():
        h, off = p.dnode(mos, o)
        b, _ = p.bonus(h, off)
        length = struct.unpack_from("<Q", h.content, b + 8)[0]
        data = p.object_data(h, off)
        k = 0
        while k < length:
            e = struct.unpack_from("<Q", data, k)[0]
            k += 8
            if e >> 62 == 3:
                e2 = struct.unpack_from("<Q", data, k)[0]
                k += 8
                hit.add(((e2 & ((1 << 63) - 1)) << 9) >> p.ms_shift)
            elif e >> 63 == 0:
                raise ToolError("log txg %d holds a one-word entry" % t)
    pick = [i for i, sm in enumerate(sms) if sm and U[i] and i not in hit]
    flushed = []
    if not pick:
        # 1.57.12 B5: a fixture build may leave NO untouched metaslab (the r3 rebuild for B5's payload put agnoswr on four
        # metaslabs, each with an entry in the export's last log). Then make one: FLUSH a metaslab's log entries into
        # its own space map — what metaslab_flush writes — and drop them from the log, so it reads as a metaslab whose
        # space map predates log_spacemap and that nothing touched since: the upgraded-pool state this verb exists for.
        # The metaslabs holding features_for_write's block are left alone (pre-defer's FREE + ALLOC overlap lives in
        # their log entries — the wr@u0 lane runs pre-defer first).
        p.f.close()
        flushed = flush_for_u0(path)
        p = Pool(path, write=True)
        mos = p.mos()
        sms, U, logs, topzap = p.space_info(mos)
        pick = flushed
        hit -= set(flushed)
    if not pick:
        raise Refused("every metaslab with a space map has an entry in some log (or U 0 already) — no such state here")
    uobj = p.zap_u64(*p.dnode(mos, topzap), "com.delphix:ms_unflushed_phys_txgs")
    h, off = p.dnode(mos, uobj)
    blksz = struct.unpack_from("<H", h.content, off + 8)[0] * 512
    blocks = {}
    for i in pick:
        blocks.setdefault((8 * i) // blksz, []).append(i)
    for blkid, mss in sorted(blocks.items()):
        nd = p.walk(h, off, blkid)
        if nd is None:
            raise ToolError("U[] block %d is a hole" % blkid)
        for i in mss:
            struct.pack_into("<Q", nd.content, (8 * i) % blksz, 0)
        p.commit(nd)
    p.f.close()

    def check(q):
        _s, qu, _l, _t = q.space_info(q.mos())
        if any(qu[i] != 0 for i in pick) or any(qu[i] != U[i] for i in range(len(U)) if i not in pick):
            raise ToolError("re-read U[] is %s" % qu)
        if q.txg != p.txg:
            raise ToolError("best uberblock moved from txg %d to %d" % (p.txg, q.txg))
    reverify(path, check)
    print("zfs-damage: zero-u U[] of metaslab(s) %s: %s -> 0 (no entry in any log%s; with entries: %s); rewrote %d "
          "block(s)/label slot(s) in place, chain re-verified at txg %d"
          % (",".join(map(str, pick)), ",".join(str(U[i]) for i in pick),
             " — FLUSHED into its space map first" if flushed else "", ",".join(map(str, sorted(hit))) or "none",
             len(p.writes), p.txg))
    return 0


def flush_for_u0(path):
    """zero-u's fallback: metaslab_flush, forged. The highest metaslab with a space map, U != 0, entries in exactly ONE
    log (the last: one block) and none of features_for_write's DVAs (B7: else the highest that holds one, when another
    of the block's metaslabs keeps its entries) gets those entries APPENDED to its own space map —
    a debug word (action, the log's pass, txg) per run of one action, then one-word entries relative to the metaslab's
    start in allocation units, as space_map_write writes a metaslab space map — smp_length / smp_alloc moved with them;
    the entries (and a debug word left with none) are REMOVED from the log, its smp_length / smp_alloc moved back. The
    histogram is left as it is (OpenZFS lets it drift, metaslab.c:4469-4476). Returns [metaslab] or []."""
    p = Pool(path, write=True)
    mos = p.mos()
    sms, U, logs, _tz = p.space_info(mos)
    if len(logs) != 1:
        p.f.close()
        return []
    T0, lobj = list(logs.items())[0]
    ffw = p.zap_u64(*p.dnode(mos, 1), "features_for_write")
    fh, fo = p.dnode(mos, ffw)
    fb = p.walk(fh, fo, 0)
    keep = {o >> p.ms_shift for (_v, o, _a, _g) in (fb.bp.dvas if fb is not None else [])}
    lh, lo = p.dnode(mos, lobj)
    ldn = lh.content[lo:lo + 512]
    if struct.unpack_from("<Q", ldn, 16)[0] != 0 or ldn[2] != 1:
        p.f.close()
        return []
    lb, _ = p.bonus(lh, lo)
    _lo, llen, lalloc = struct.unpack_from("<QQq", lh.content, lb)
    lnode = p.walk(lh, lo, 0)
    data = bytes(lnode.content)
    # the log as groups: [debug word, [(w0, w1, ms, free, off, size)]]
    groups, k = [], 0
    while k < llen:
        e = struct.unpack_from("<Q", data, k)[0]
        k += 8
        if e >> 62 == 2:
            groups.append([e, []])
        elif e >> 62 == 3:
            e2 = struct.unpack_from("<Q", data, k)[0]
            k += 8
            off, size = (e2 & ((1 << 63) - 1)) << 9, (((e >> 24) & ((1 << 36) - 1)) + 1) << 9
            groups[-1][1].append((e, e2, off >> p.ms_shift, e2 >> 63, off, size))
        elif e != 1 << 63:
            raise ToolError("log txg %d holds a one-word entry" % T0)
    cand = [i for i, sm in enumerate(sms) if sm and U[i] and i not in keep
            and any(x[2] == i for _d, es in groups for x in es)]
    if not cand and len(keep) >= 2:
        # (B7) every candidate holds a copy of features_for_write's block: flush one of them, the others keep
        # pre-defer's overlap in the log
        cand = [i for i, sm in enumerate(sms) if sm and U[i] and i in keep
                and any(x[2] == i for _d, es in groups for x in es)][-1:]
    if not cand:
        p.f.close()
        return []
    ms = cand[-1]
    unit = 1 << p.ashift
    mstart = ms << p.ms_shift
    smw, net = [], 0
    for d, es in groups:
        mine = [x for x in es if x[2] == ms]
        if not mine:
            continue
        smw.append((2 << 62) | (((d >> 60) & 3) << 60) | (((d >> 50) & 0x3FF) << 50) | T0)
        for (_w0, _w1, _m, fr, off, size) in mine:
            run = size // unit
            if run > 1 << 15 or (off - mstart) % unit or size % unit:
                p.f.close()
                return []
            smw.append((((off - mstart) // unit) << 16) | (fr << 15) | (run - 1))
            net += -size if fr else size
    # the metaslab's space map: append, in place
    sh, so = p.dnode(mos, sms[ms])
    sdn = sh.content[so:so + 512]
    sblk = struct.unpack_from("<H", sdn, 8)[0] * 512
    sb, _ = p.bonus(sh, so)
    _so, slen, salloc = struct.unpack_from("<QQq", sh.content, sb)
    if (slen + 8 * len(smw)) // sblk != slen // sblk or struct.unpack_from("<Q", sdn, 16)[0] != slen // sblk:
        p.f.close()
        return []                                           # the append would cross a block: not forged here
    snode = p.walk(sh, so, slen // sblk)
    for j, w in enumerate(smw):
        struct.pack_into("<Q", snode.content, slen % sblk + 8 * j, w)
    struct.pack_into("<Qq", sh.content, sb + 8, slen + 8 * len(smw), salloc + net)
    p.commit(snode)
    p.f.close()
    # the log: the metaslab's entries (and a debug word left empty) gone, in place
    p = Pool(path, write=True)
    mos = p.mos()
    lh, lo = p.dnode(mos, lobj)
    lb, _ = p.bonus(lh, lo)
    lnode = p.walk(lh, lo, 0)
    out = []
    for d, es in groups:
        rest = [x for x in es if x[2] != ms]
        if es and not rest:
            continue
        out.append(d)
        for x in rest:
            if (len(out) * 8) % ldn_blksz(ldn) == ldn_blksz(ldn) - 8:
                out.append(1 << 63)
            out += [x[0], x[1]]
    body = b"".join(struct.pack("<Q", w) for w in out)
    lnode.content[0:len(lnode.content)] = body + bytes(len(lnode.content) - len(body))
    struct.pack_into("<Qq", lh.content, lb + 8, len(body), lalloc - net)
    p.commit(lnode)
    p.f.close()
    nent = sum(1 for _d, es in groups for x in es if x[2] == ms)
    print("zfs-damage: zero-u flushed ms %d's %d log entr%s (net %+d B) from log txg %d into its space map (smp_length "
          "%d -> %d, smp_alloc %d -> %d); log smp_length %d -> %d"
          % (ms, nent, "y" if nent == 1 else "ies", net, T0, slen,
             slen + 8 * len(smw), salloc, salloc + net, llen, len(body)))
    return [ms]


def ldn_blksz(dn):
    return struct.unpack_from("<H", dn, 8)[0] * 512


def cmd_pre_defer(path):
    refuse_cache(path)
    p = Pool(path, write=True)
    mos = p.mos()
    sms, U, logs, _tz = p.space_info(mos)
    T0 = p.txg
    if T0 not in logs:
        raise Refused("no log space map for the best txg %d (logs: %s)" % (T0, sorted(logs)))
    ffw = p.zap_u64(*p.dnode(mos, 1), "features_for_write")
    fh, fo = p.dnode(mos, ffw)
    if fh.content[fo + 2] != 1:
        raise Refused("features_for_write has %d levels — the tool forges one L0 block" % fh.content[fo + 2])
    blk = p.walk(fh, fo, 0)
    if blk is None or blk.bp.embedded or not blk.bp.dvas:
        raise Refused("features_for_write's block has no DVA (a hole or embedded)")
    tgt = []
    for (v, off, asz, g) in blk.bp.dvas:
        ms = off >> p.ms_shift
        if g or ms >= len(sms) or not sms[ms]:
            raise Refused("DVA <%d:%x:%x> is a gang DVA or lies in a metaslab without a space map" % (v, off, asz))
        if not 1 <= U[ms] <= T0:
            raise Refused("DVA <%d:%x:%x>: ms %d has unflushed txg %d — log T0's entries for it would %s"
                          % (v, off, asz, ms, U[ms], "be B3b's N3 defect (U 0)" if U[ms] == 0 else "not apply"))
        tgt.append((v, off, asz))
    tgt.sort(key=lambda d: d[1])
    lh, lo = p.dnode(mos, logs[T0])
    dn = lh.content[lo:lo + 512]
    blksz, maxblkid = struct.unpack_from("<H", dn, 8)[0] * 512, struct.unpack_from("<Q", dn, 16)[0]
    if maxblkid != 0 or dn[2] != 1:
        raise Refused("log T0 (object %d) is %d block(s) at %d level(s) — the tool appends to ONE block"
                      % (logs[T0], maxblkid + 1, dn[2]))
    b, _bl = p.bonus(lh, lo)
    lobj, length, lalloc = struct.unpack_from("<QQq", lh.content, b)
    node = p.walk(lh, lo, 0)
    data = node.content
    if any(data[length:]):
        raise ToolError("log T0 has nonzero bytes past smp_length %d" % length)
    npass, k = 0, 0
    while k < length:
        e = struct.unpack_from("<Q", data, k)[0]
        k += 8
        if e >> 62 == 2:
            npass = max(npass, (e >> 50) & 0x3FF)
        elif e >> 62 == 3:
            k += 8
    words = []

    def put(w, two=False):
        if two and (length + 8 * len(words)) % blksz == blksz - 8:
            words.append(1 << 63)                             # the pad word: a two-word entry never straddles a block
        words.append(w)
    for ty, ps in ((1, npass + 1), (0, npass + 2)):        # FREE in a later pass, then ALLOC again in the next
        put((2 << 62) | (ty << 60) | (ps << 50) | T0)
        for (v, off, asz) in tgt:
            put((3 << 62) | (((asz >> 9) - 1) << 24) | v, True)
            put((ty << 63) | (off >> 9))
    add = 8 * len(words)
    if length + add > blksz:
        raise Refused("log T0 has %d of %d bytes used — no room for %d more" % (length, blksz, add))
    for j, w in enumerate(words):
        struct.pack_into("<Q", data, length + 8 * j, w)
    struct.pack_into("<Q", lh.content, b + 8, length + add)
    p.commit(node)                                         # the log block, then its dnode block (the same Node) and up
    p.f.close()

    def check(q):
        qm = q.mos()
        _s, qu, ql, _t = q.space_info(qm)
        h2, o2 = q.dnode(qm, ql[T0])
        b2, _ = q.bonus(h2, o2)
        _o, l2, a2 = struct.unpack_from("<QQq", h2.content, b2)
        if (l2, a2) != (length + add, lalloc) or q.txg != p.txg or qu != U:
            raise ToolError("re-read log T0 length/alloc %d/%d (want %d/%d), txg %d, U %s"
                            % (l2, a2, length + add, lalloc, q.txg, qu))
        d2 = q.object_data(h2, o2)
        if d2[length:length + add] != b"".join(struct.pack("<Q", w) for w in words):
            raise ToolError("re-read log T0 does not end with the forged entries")
    reverify(path, check)
    print("zfs-damage: pre-defer log txg %d (obj %d): + FREE then ALLOC of features_for_write's block %s (ms %s, "
          "passes %d/%d), smp_length %d -> %d, smp_alloc %d unchanged; rewrote %d block(s)/label slot(s) in place, "
          "chain re-verified at txg %d"
          % (T0, logs[T0], " ".join("<%d:%x:%x>" % d for d in tgt), ",".join(str(d[1] >> p.ms_shift) for d in tgt),
             npass + 1, npass + 2, length, length + add, lalloc, len(p.writes), p.txg))
    return 0


def main(argv):
    if len(argv) < 3 or argv[1] not in ("info", "flip-data", "flip-mos-root", "bump-smp-alloc", "bump-acct", "drop-log",
                                        "tear-ub", "zero-u", "pre-defer"):
        print(__doc__ if __doc__ else "usage: see the header of zfs-damage.py", file=sys.stderr)
        print("usage: zfs-damage.py info|flip-data|flip-mos-root|bump-smp-alloc|bump-acct|drop-log|tear-ub|zero-u|pre-defer IMG [options]", file=sys.stderr)
        return 2
    verb, path = argv[1], argv[2]
    opts, adds, i = {}, [], 3
    while i < len(argv):
        if argv[i] not in ("--dataset", "--object", "--blkid", "--at", "--metaslab", "--delta", "--txg", "--level", "--dvas",
                           "--add", "--label") or i + 1 >= len(argv):
            print("zfs-damage: unknown or incomplete option %r" % argv[i], file=sys.stderr)
            return 2
        if argv[i] == "--add":
            f, _, d = argv[i + 1].partition("=")
            try:
                adds.append((f, int(d, 0)))
            except ValueError:
                print("zfs-damage: --add wants FIELD=DELTA, got %r" % argv[i + 1], file=sys.stderr)
                return 2
        else:
            opts[argv[i][2:]] = argv[i + 1]
        i += 2
    dvas = [int(x) for x in opts["dvas"].split(",")] if "dvas" in opts else None
    num = lambda k: (int(opts[k], 0) if k in opts else None)
    try:
        if verb == "info":
            return cmd_info(path)
        if verb == "flip-data":
            if "dataset" not in opts or "object" not in opts:
                print("zfs-damage: flip-data needs --dataset DS --object N", file=sys.stderr)
                return 2
            return cmd_flip(path, opts["dataset"], num("object"), num("blkid") or 0, num("at"), num("level") or 0, dvas)
        if verb == "flip-mos-root":
            return cmd_flip_root(path, dvas, num("at"))
        if verb == "bump-acct":
            if "dataset" not in opts or not adds:
                print("zfs-damage: bump-acct needs --dataset DS and at least one --add FIELD=DELTA", file=sys.stderr)
                return 2
            return cmd_bump_acct(path, opts["dataset"], adds)
        if verb == "bump-smp-alloc":
            return cmd_bump(path, num("metaslab"), num("delta"))
        if verb == "tear-ub":
            return cmd_tear_ub(path, num("label"), num("txg"))
        if verb == "zero-u":
            return cmd_zero_u(path)
        if verb == "pre-defer":
            return cmd_pre_defer(path)
        return cmd_droplog(path, num("txg"))
    except Refused as e:
        print("zfs-damage: REFUSED %s: %s" % (verb, e))
        return 1
    except (ToolError, OSError, KeyError, IndexError, struct.error) as e:
        print("zfs-damage: ERROR %s: %s: %s" % (verb, type(e).__name__, e), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
