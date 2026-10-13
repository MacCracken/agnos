#!/usr/bin/env python3
# zfs-hole-check — HOLE BIRTHS, the one block-pointer field no zfs tool checks (agnos 1.57.12 bite B5; design
# docs/development/proposals/2026-10-09-zfs-write.md § k.12, the audit's h8): with hole_birth active, a hole that
# replaces a block — freed by a truncation (free_blocks, dnode_sync.c:140-178), compressed away as zeros (zio.c:
# 2097-2104), an indirect left all holes (dbuf_write_children_ready) — carries the txg it was punched in, and the children
# of a re-materialised birth-B hole indirect carry B (dbuf_handle_indirect_hole). An incremental `zfs send -i` skips a
# birth-0 hole (dmu_traverse.c:249-276), so a writer that punched one leaves a receiver holding data the source freed —
# silently; zdb checks a hole's TYPE and LEVEL only (zdb.c:2683-2696), and only once its birth is non-zero.
#
# The audit: for every head ZPL dataset in both images (by dsl_dir name; encrypted ones left out), every object whose
# dnode CHANGED (same object number, same type — a reused number is a different file; 1.57.12 B7: same ZPL_GEN too, the
# same type is not enough once unlink frees a number a create then reuses) has every hole BP of its tree
# (every level) compared with the PRISTINE image at the same position (level, blkid):
#   · a birth-0 hole where the pristine image had a block, or a hole of birth B != 0 (itself or as the hole an ancestor
#     punched) — FAIL: the punch was not recorded
#   · a hole with birth B != 0: B <= the image's txg, TYPE == the dnode's type, LEVEL == its level (what zdb checks)
# A position the pristine tree never addressed (past its levels / blkptrs), or a birth-0 hole there, may stay birth 0.
# (B5 review, finding 7(4)) Every hole the WRITER punched (birth past the pristine image's txg) also carries the LSIZE
# free_blocks / zio_write_compress keep — the dnode's data block size at level 0, its indirect block size above
# (dnode_sync.c:166-177: the freed BP's own LSIZE, and a file's block size is fixed once it has two) — and, given the
# lane's serial log (--log), no EXTRA birth: every writer-born hole's birth is the txg of an op that FREES or ZEROES that
# file — a truncation, a write of zeros — because only those punch (free_blocks; zio.c:2097-2104 for zeros over a born
# block; an indirect left all holes; and dbuf_handle_indirect_hole copying a punched indirect's birth to its children
# when a later write re-materialises it). A plain write never stamps one: OpenZFS leaves the holes of a sparse
# extension at birth 0, and a birth there would make `zfs send -i` carry FREE records for ranges nothing freed.
# The pool reader is the B0 image tool's (scripts/tool/zfs-damage.py; ZFS_POOL_LIB overrides). Pools without
# hole_birth active are skipped (every hole is birth 0 there by rule).
#
# usage: zfs-hole-check.py FINAL PRISTINE [--log LOG MANIFEST OBJECTS]    (pool-only images; LOG = the lane's serial log,
#        MANIFEST = the expected manifest (its M lines), OBJECTS = the fixture's <lane>.objects)
# Exit 0 every hole is right · 1 a wrong one (named) · 2 unusable input
import importlib.util, os, struct, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


def load_lib():
    path = os.environ.get("ZFS_POOL_LIB") or os.path.join(ROOT, "scripts", "tool", "zfs-damage.py")
    spec = importlib.util.spec_from_file_location("zfsdamage", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Img:
    def __init__(self, z, path):
        self.z = z
        self.p = z.Pool(path)
        base = self.p.read_bp
        self.p.read_bp = lambda bp, verify=True: base(bp, verify=verify and bp.cksum in (7, 8))
        self.cache = {}
        self.mos = self.p.mos()
        self.mosdir = self.p.zap(*self.p.dnode(self.mos, 1))

    def content(self, bp):
        key = (bp.w[0], bp.w[1], bp.w[10], bp.w[6])
        if key not in self.cache:
            self.cache[key] = bytes(self.p.read_bp(bp))
        return self.cache[key]

    def heads(self):
        """{dsl_dir name: dsl_dataset_phys bytes} of every head dataset."""
        p, mos = self.p, self.mos
        out = {}
        stack = [(self.mosdir["root_dataset"][1], p.label.get("name", "pool"))]
        while stack:
            dobj, name = stack.pop()
            h, o = p.dnode(mos, dobj)
            b, _ = p.bonus(h, o)
            ddp = bytes(h.content[b:b + 256])
            head, czap = struct.unpack_from("<Q", ddp, 8)[0], struct.unpack_from("<Q", ddp, 32)[0]
            if czap:
                for cn, (_k, cv, _n, _p) in p.zap(*p.dnode(mos, czap)).items():
                    if not cn.startswith("$"):
                        stack.append((cv, name + "/" + cn))
            if head:
                hd, hdo = p.dnode(mos, head)
                hb, _ = p.bonus(hd, hdo)
                out[name] = bytes(hd.content[hb:hb + 320])
        return out

    def objset(self, dsphys):
        bp = self.z.BP(dsphys[128:256])
        if bp.hole or (bp.w[6] >> 61) & 1:
            return None
        c = self.content(bp)
        if struct.unpack_from("<Q", c, 704)[0] != 2:
            return None                                            # a zvol
        return c

    def dnodes(self, osc):
        """{object: 512-byte dnode bytes (its slots)} of an objset, walked through the meta-dnode."""
        md = osc[0:512]
        out = {}
        per = struct.unpack_from("<H", md, 8)[0]                   # 512-byte slots per dnode block
        for blkid, blk in self.l0s(md):
            s = 0
            while s < per:
                t = blk[s * 512]
                if t == 0:
                    s += 1
                    continue
                ex = blk[s * 512 + 12]
                out[blkid * per + s] = bytes(blk[s * 512:(s + 1 + ex) * 512])
                s += 1 + ex
        return out

    def l0s(self, dn):
        """(blkid, content) of every non-hole L0 of the dnode's tree."""
        nl, ibs, nbp = dn[2], dn[1], dn[3]
        epbs = ibs - 7
        stack = [(self.z.BP(dn[64 + 128 * i:192 + 128 * i]), nl - 1, i) for i in range(nbp)]
        while stack:
            bp, lv, bid = stack.pop()
            if bp.hole:
                continue
            c = self.content(bp)
            if lv == 0:
                yield bid, c
                continue
            for j in range(0, len(c), 128):
                stack.append((self.z.BP(c[j:j + 128]), lv - 1, (bid << epbs) + j // 128))

    def state(self, dn, lv, bid):
        """What the tree of dnode dn holds at (lv, bid): ('data', birth) · ('hole', birth) · ('none', 0) never addressed."""
        nl, ibs, nbp = dn[2], dn[1], dn[3]
        epbs = ibs - 7
        if lv >= nl:
            # a block above this tree's top: it covers top entries [bid << ..., ...) — data if any is
            first = bid << (epbs * (lv - nl + 1))
            last = ((bid + 1) << (epbs * (lv - nl + 1))) - 1
            best = ("none", 0)
            for i in range(first, min(last, nbp - 1) + 1):
                bp = self.z.BP(dn[64 + 128 * i:192 + 128 * i])
                if not bp.hole:
                    return ("data", bp.birth)
                if bp.birth and (best[0] == "none" or bp.birth > best[1]):
                    best = ("hole", bp.birth)
            return best
        top = bid >> (epbs * (nl - 1 - lv))
        if top >= nbp:
            return ("none", 0)
        bp = self.z.BP(dn[64 + 128 * top:192 + 128 * top])
        level = nl - 1
        while level > lv:
            if bp.hole:
                return ("hole", bp.birth) if bp.birth else ("none", 0)
            c = self.content(bp)
            level -= 1
            i = (bid >> (epbs * (level - lv))) & ((1 << epbs) - 1)
            bp = self.z.BP(c[128 * i:128 * i + 128])
        if bp.hole:
            return ("hole", bp.birth) if bp.birth else ("none", 0)
        return ("data", bp.birth)

    def holes(self, dn):
        """(lv, bid, BP) of every hole BP of the dnode's tree (the dn_blkptr[] and every indirect's entries)."""
        nl, ibs, nbp = dn[2], dn[1], dn[3]
        epbs = ibs - 7
        stack = [(self.z.BP(dn[64 + 128 * i:192 + 128 * i]), nl - 1, i) for i in range(nbp)]
        while stack:
            bp, lv, bid = stack.pop()
            if bp.hole:
                yield lv, bid, bp
                continue
            if lv == 0 or bp.embedded:
                continue
            c = self.content(bp)
            for j in range(0, len(c), 128):
                stack.append((self.z.BP(c[j:j + 128]), lv - 1, (bid << epbs) + j // 128))


def gen_of(dn):
    """ZPL_GEN of an SA znode (the fixed ZPL layout: MODE SIZE GEN — zfs_sa.h), or None (not an SA bonus)."""
    if dn[4] != 44:
        return None
    b = 64 + 128 * dn[3]
    if struct.unpack_from("<H", dn, 10)[0] < 24 or struct.unpack_from("<I", dn, b)[0] != 0x2F505A:
        return None
    hs = ((struct.unpack_from("<H", dn, b + 4)[0] >> 10) & 0x3F) * 8
    return struct.unpack_from("<Q", dn, b + hs + 16)[0]


def punch_txgs(log, manifest, objects):
    """{(dataset name, object): {txg}} — the txgs of the ops that free or zero each file: every SUCCESSFUL `trunc` and every
    `write` of zeros (seed `zeros`), from their `begin txg=T` and `-> r txgs=k` lines; (B7) and object 0, the meta-dnode,
    of the dataset of every unlink / rmdir / rename / link: a removal can leave a dnode block with no dnode in it, which
    becomes a hole of birth T (an all-zero metadata block, zio.c:2097-2104)."""
    import re
    mounts, objs, out = {}, {}, {}
    with open(manifest) as fh:
        for l in fh:
            f = l.split()
            if len(f) >= 3 and f[0] == "M":
                mounts[f[1]] = f[2]
    with open(objects) as fh:
        for l in fh:
            f = l.split(None, 1)
            if len(f) == 2:
                objs[f[1].strip()] = int(f[0])
    with open(log, "rb") as fh:
        lines = [re.sub(r"^\[[^]]*\] ", "", l.decode("utf-8", "replace").strip("\r\n")) for l in fh.read().split(b"\n")]
    pend = None
    for l in lines:
        m = re.match(r"zfs-wtest: (unlink|rmdir|rename|link) begin txg=(\d+) (\S+)", l)
        if m:
            pend = (m.group(1), int(m.group(2)), m.group(3), "ns")
            continue
        m = re.match(r"zfs-wtest: (unlink|rmdir|rename|link) (\S+) -> -?\d+ txgs=(\d+)$", l)
        if m and pend and pend[3] == "ns" and pend[0] == m.group(1) and pend[2] == m.group(2):
            mp = max((q for q in mounts if m.group(2) == q or m.group(2).startswith(q.rstrip("/") + "/")), key=len, default=None)
            if mp is not None:
                out.setdefault((mounts[mp], 0), set()).update(range(pend[1], pend[1] + int(m.group(3))))
            pend = None
            continue
        m = re.match(r"zfs-wtest: (write|trunc|burst) begin txg=(\d+) (\S+)(.*)$", l)
        if m:
            pend = (m.group(1), int(m.group(2)), m.group(3), m.group(1) == "trunc" or " seed=zeros" in m.group(4))
            continue
        m = re.match(r"zfs-wtest: (write|trunc|burst) (\S+) -> -?\d+ txgs=(\d+)$", l)
        if m and pend and pend[0] == m.group(1) and pend[2] == m.group(2):
            if pend[3] and m.group(2) in objs:
                mp = max((q for q in mounts if m.group(2) == q or m.group(2).startswith(q.rstrip("/") + "/")), key=len, default=None)
                if mp is not None:
                    out.setdefault((mounts[mp], objs[m.group(2)]), set()).update(range(pend[1], pend[1] + int(m.group(3))))
            pend = None
    return out


def main(argv):
    pt = None
    if len(argv) == 7 and argv[3] == "--log":
        if not all(os.path.isfile(a) for a in argv[4:]):
            print("usage: zfs-hole-check.py FINAL PRISTINE [--log LOG MANIFEST OBJECTS]")
            return 2
        pt = punch_txgs(argv[4], argv[5], argv[6])
        argv = argv[:3]
    if len(argv) != 3 or not all(os.path.isfile(a) for a in argv[1:]):
        print("usage: zfs-hole-check.py FINAL PRISTINE [--log LOG MANIFEST OBJECTS]")
        return 2
    z = load_lib()
    try:
        fin, pri = Img(z, argv[1]), Img(z, argv[2])
        hb = None                                                  # hole_birth is not read-only compatible:
        for zk in ("features_for_read", "features_for_write"):     #   features_for_read holds it
            hb = hb or fin.p.zap(*fin.p.dnode(fin.mos, fin.mosdir[zk][1])).get("com.delphix:hole_birth")
        fh, ph = fin.heads(), pri.heads()
    except (z.ToolError, KeyError, ValueError, struct.error) as e:
        print("holes: unusable input: %s" % e)
        return 2
    if not hb or hb[1] == 0:
        print("holes: SKIP — hole_birth is not active on this pool (every hole is birth 0 by rule)")
        return 0
    txg, ptxg = fin.p.txg, pri.p.txg
    fails, nds, nobj, nh, nb, nw = [], 0, 0, 0, 0, 0
    for name in sorted(fh):
        if name not in ph:
            continue
        try:
            fo, po = fin.objset(fh[name]), pri.objset(ph[name])
            if fo is None or po is None:
                continue
            nds += 1
            fd, pd = fin.dnodes(fo), pri.dnodes(po)
            fd[0], pd[0] = fo[0:512], po[0:512]                   # the meta-dnode's own tree
            for obj in sorted(fd):
                f = fd[obj]
                p = pd.get(obj)
                if p is None or p[0] != f[0] or p == f or gen_of(p) != gen_of(f):
                    continue
                nobj += 1
                for lv, bid, bp in fin.holes(f):
                    nh += 1
                    if bp.birth == 0:
                        st = pri.state(p, lv, bid)
                        if st[0] != "none":
                            fails.append("%s object %d L%d blkid %d: a hole of birth 0 where the pristine image had %s of "
                                         "birth %d — the punch is not recorded (hole_birth)" % (name, obj, lv, bid,
                                         "a block" if st[0] == "data" else "a hole", st[1]))
                        continue
                    nb += 1
                    if bp.birth > txg:
                        fails.append("%s object %d L%d blkid %d: hole birth %d is past the pool's txg %d" % (name, obj, lv, bid, bp.birth, txg))
                    if bp.type != f[0] or bp.level != lv:
                        fails.append("%s object %d L%d blkid %d: hole of birth %d has type %d level %d (the dnode: type %d, "
                                     "level %d)" % (name, obj, lv, bid, bp.birth, bp.type, bp.level, f[0], lv))
                    if bp.birth <= ptxg:
                        continue
                    nw += 1                                    # punched by the writer: LSIZE, and no extra birth
                    ls = (struct.unpack_from("<H", f, 8)[0] << 9) if lv == 0 else (1 << f[1])
                    if bp.lsize != ls:
                        fails.append("%s object %d L%d blkid %d: hole of birth %d has LSIZE %d, the dnode's %s block size "
                                     "is %d" % (name, obj, lv, bid, bp.birth, bp.lsize, "data" if lv == 0 else "indirect", ls))
                    if pt is not None and bp.birth not in pt.get((name, obj), ()):
                        fails.append("%s object %d L%d blkid %d: a hole of birth %d, a txg in which no op freed or zeroed "
                                     "this file — an extra birth (OpenZFS leaves 0)" % (name, obj, lv, bid, bp.birth))
        except (z.ToolError, KeyError, ValueError, struct.error) as e:
            fails.append("%s: unreadable: %s" % (name, e))
    for f in fails[:30]:
        print("holes:   FAIL " + f)
    if len(fails) > 30:
        print("holes:   FAIL ... and %d more" % (len(fails) - 30))
    v = "PASS" if not fails else "FAIL"
    print("holes: %s — %d dataset(s), %d changed object(s), %d hole BP(s), %d with a birth (%d punched by the writer: LSIZE%s), "
          "txg %d" % (v, nds, nobj, nh, nb, nw, ", births from frees / zeros only" if pt is not None else "", txg))
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
