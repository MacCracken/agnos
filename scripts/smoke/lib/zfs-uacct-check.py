#!/usr/bin/env python3
# zfs-uacct-check — the host RECOUNT of what no zfs tool checks (agnos 1.57.12 bite B4; design
# docs/development/proposals/2026-10-09-zfs-write.md § e.1, § e.3, § k.14): on a pool image, for every head ZPL dataset
#   dnused  every dnode's dn_used (DN_USED_BYTES: bytes under DNODE_FLAG_USED_BYTES, else 512-byte sectors) == the sum
#           of the dsize (Σ DVA asize, 0 for an embedded BP) of every BP in its tree — every level, holes skipped —
#           plus its spill block (dnode.c:2473-2498, dbuf.c:5004-5006). zdb never checks it, and its object rows print
#           dn_used itself, so a wrong dn_used and the matching wrong user delta agree with each other there (§ k.14);
#   ref     ds_referenced_bytes == Σ dn_used of every object (the meta-dnode and the user / group / project-used
#           objects included) + the objset block's asize — the guest's A5 identity, here before any boot;
#   uacct   the user / group / project-used ZAPs (objects -1 / -2 / -3, the dnodes at objset_phys +1024 / +1536 /
#           +2048) == a recount over every dnode: DNODE_MIN_SIZE (512) + DN_USED_BYTES under "%llx"(id) for a dnode
#           with DNODE_FLAG_USERUSED_ACCOUNTED (bit 1), 1 under "obj-%llx"(id) with USEROBJUSED_ACCOUNTED (bit 3); ids
#           only from an SA (44) or znode (17) bonus — or the spill block of a spill-held SA — at zpl_get_file_info's
#           fixed offsets (uid +24, gid +32, flags +48, projid +128 under ZFS_PROJID, after the SA header;
#           zfs_quota.c:42-110); the project ZAP only where project quota is enabled (project_quota enabled on the pool
#           and a 4 KiB objset_phys, dmu_objset.c:1813-1818). Keys whose value is 0 do not exist (zap_increment
#           removes them, zap.c:1274-1291).
#   dirs    every dsl_dir whose head dataset has no snapshot of its own and is no clone: dd_compressed_bytes ==
#           ds_compressed_bytes of the head + Σ dd_compressed_bytes of its child dirs ($MOS / $FREE / $LEAK / $ORIGIN
#           included), and the same for uncompressed — born / kill move a dataset's compressed / uncompressed and every
#           dir above it by the same PSIZE / UCSIZE (dsl_dataset.c:150-210, :318-373; dsl_dir.c:1616-1663), and nothing
#           else checks them (zfs get shows `logicalused` alone, with no identity: a missing parent propagation of a
#           change that moved no USED bytes — a write absorbed by a reservation, a rewrite of equal dsize — was
#           invisible to every other oracle; B4's negative N2 on `wr`)
#   resv    (B4 review, MAJOR: a wrong refreservation split moved bytes between a dir's HEAD / REFRSRV and the root's
#           used / Σ usedbyrefreservation, which every other identity — the guest's B-acct included — sums back
#           together; only a later `zfs destroy` of THAT dataset tripped over it, and the root dataset is never
#           destroyed) every dsl_dir with DD_FLAG_USED_BREAKDOWN, straight from the MOS:
#             Σ dd_used_breakdown == dd_used_bytes (the ZFS_DEBUG assert of dsl_dir_diduse_transfer_space,
#             dsl_dir.c:1643-1651); CHILD == Σ dd_used_bytes of its child dirs ($MOS / $FREE / $LEAK / $ORIGIN included)
#             and CHILD_RSRV == Σ max(0, dd_reserved - dd_used_bytes) over them (the parent's half of every
#             transfer, :1656-1660, and of dsl_dir_set_reservation_sync, :1886-1914); a dir with a head dataset:
#             REFRSRV == max(0, refreservation - ds_unique_bytes) (dsl_dataset.c parent_delta, :121-136 — the
#             property from dd_props_zapobj in dsl_prop_get_dd's order: local, else $recvd unless $inherit, else 0),
#             and a non-clone head's HEAD == ds_referenced_bytes (born and every kill move both by the same dsize,
#             :150-376 — the guest's B-acct identity 5, here on the image); a dir without one: REFRSRV == 0
#           and every head's ds_unique_bytes against its blocks: a snapshot-free non-clone head's == ds_referenced_bytes;
#           any other (a snapshot, a clone; not encrypted) == Σ dsize of every BP of its objset — the objset block, the
#           meta-dnode's and every dnode's tree, spills, the special dnodes — whose logical birth is past
#           ds_prev_snap_txg (exactly what born adds and kill branch A removes; a subtree born no later is skipped whole)
#   fbpo    (1.57.12 B7, design § e.2) the pool's free_bpobj — the kills a writer DEFERRED (gang / dedup / clone blocks:
#           bpobj_enqueue, dsl_dataset.c:298-331): Σ dsize / PSIZE / UCSIZE of its entries == its header's bpo_bytes /
#           bpo_comp / bpo_uncomp (when its bonus has them), every entry with fill 0 and — not dedup — a zeroed checksum,
#           and $FREE's dd_used == bpo_bytes (OpenZFS's async destroy debits $FREE by exactly what it frees; these pools
#           hold no destroyed-dataset bptree); with --freeing B, == B too: the writer's own Σ (its plan lines' fbpo=)
# ⭐ A RECOUNT, not a delta: it holds on every pool OpenZFS wrote (validated on every pristine fixture image first) and
# must still hold after agnos's txgs — a skipped user delta, a wrong dn_used, a referenced off by a block all show.
# The pool reader is the B0 image tool's (scripts/tool/zfs-damage.py, read-only use; ZFS_POOL_LIB overrides).
# Datasets left out, by name: encrypted (no key), and ZVOLs (no ZPL objects).
#
# usage: zfs-uacct-check.py IMG [--space ACCT] [--freeing BYTES]   (IMG a pool-only image: the fixture's, or a writer's)
#   --space ACCT  also hold OpenZFS's OWN reading of those ZAPs — the verify guest's `zfs userspace / groupspace /
#                 projectspace -Hp` capture, the `space <kind> <dataset> <name> <used> <objused>` lines of
#                 <lane>.B.acct (scripts/tool/zfs-fixture-guest.sh acct_capture) — to the recount: every line's used and
#                 objused == the recount's for that id (a name is numeric, or root / wheel = 0, the fixtures' only
#                 owners), and every recounted id of a captured dataset has its line (design § k.34)
# Exit 0 every check holds · 1 a mismatch (named) · 2 unusable input
import importlib.util, os, struct, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


def load_lib():
    path = os.environ.get("ZFS_POOL_LIB") or os.path.join(ROOT, "scripts", "tool", "zfs-damage.py")
    spec = importlib.util.spec_from_file_location("zfsdamage", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def rd(p, bp):
    """A block's content — checksum-verified where the image tool implements the algorithm (fletcher4, sha256);
    skein / edonr / blake3 / sha512 datasets are read unverified (integrity is zdb's oracle; this one counts)."""
    return p.read_bp(bp)


def dsize(bp):
    return 0 if bp.hole or bp.embedded else sum(a for (_v, _o, a, _g) in bp.dvas)


def tree_dsize(z, p, dn):
    """Σ dsize over every BP of the dnode's tree (all levels) — indirects read once each."""
    nblkptr = dn[3]
    tot = 0
    stack = []
    for i in range(nblkptr):
        stack.append(z.BP(dn[64 + 128 * i:192 + 128 * i]))
    while stack:
        bp = stack.pop()
        if bp.hole:
            continue
        tot += dsize(bp)
        if bp.level > 0 and not bp.embedded:
            c = rd(p, bp)
            for j in range(0, len(c), 128):
                cb = z.BP(c[j:j + 128])
                if not cb.hole:
                    stack.append(cb)
    return tot


def dn_used(dn):
    u = struct.unpack_from("<Q", dn, 24)[0]
    return u if dn[7] & 1 else u << 9


def ids_of(z, p, dn):
    """(uid, gid, projid) or None: zpl_get_file_info over the bonus, or the spill of a spill-held SA."""
    bt = dn[4]
    nblk = dn[3]
    blen = struct.unpack_from("<H", dn, 10)[0]
    if bt not in (17, 44):
        return None
    if blen:
        data = dn[64 + 128 * nblk:64 + 128 * nblk + blen]
    elif bt == 44 and dn[7] & 4:
        ex = dn[12]
        sp = z.BP(dn[(ex + 1) * 512 - 128:(ex + 1) * 512])
        data = rd(p, sp)
    else:
        return None
    if bt == 17:
        return struct.unpack_from("<Q", data, 128)[0], struct.unpack_from("<Q", data, 136)[0], 0
    mg = struct.unpack_from("<I", data, 0)[0]
    if mg == 0:
        return 0, 0, 0
    if mg != 0x2F505A:
        raise ValueError("SA header magic %#x (byte-swapped or damaged)" % mg)
    hs = ((struct.unpack_from("<H", data, 4)[0] >> 10) & 0x3F) * 8
    uid, gid, fl = struct.unpack_from("<QQ", data, hs + 24) + (struct.unpack_from("<Q", data, hs + 48)[0],)
    pj = struct.unpack_from("<Q", data, hs + 128)[0] if fl & (1 << 47) else 0
    return uid, gid, pj


def check_ds(z, p, name, dsphys, feats):
    """Lines describing dataset `name`; raises ValueError on a mismatch."""
    bp = z.BP(dsphys[128:256])
    osn = p.node(bp, None)
    osl = bp.lsize
    if struct.unpack_from("<Q", osn.content, 704)[0] != 2:
        return None                                              # a zvol: no ZPL objects
    ref = struct.unpack_from("<Q", dsphys, 72)[0]
    osc = osn.content
    md = bytes(osc[0:512])
    special = [("meta-dnode", md)]
    useron = osl >= 2048 and osc[1024] == 39
    projon = useron and osl >= 4096 and osc[2048] == 39 and "org.zfsonlinux:project_quota" in feats
    if osl >= 2048:
        for nm, off in (("userused", 1024), ("groupused", 1536), ("projectused", 2048)):
            if off + 512 <= osl and osc[off] != 0:
                special.append((nm, bytes(osc[off:off + 512])))
    bad = []
    sum_used = 0
    # every special dnode's own dn_used
    for nm, dn in special:
        u, t = dn_used(dn), tree_dsize(z, p, dn)
        sum_used += u
        if u != t:
            bad.append("%s dn_used %d != Σ dsize of its tree %d" % (nm, u, t))
    # every object, through the meta-dnode's L0 blocks
    count = {}
    nobj = 0
    stack = [(z.BP(md[64 + 128 * i:192 + 128 * i]), i) for i in range(md[3])]
    l0 = []
    while stack:
        b, bid = stack.pop()
        if b.hole:
            continue
        if b.level == 0:
            l0.append((b, bid))
            continue
        c = rd(p, b)
        stack.extend((z.BP(c[j:j + 128]), bid * (len(c) // 128) + j // 128) for j in range(0, len(c), 128))
    blksz = struct.unpack_from("<H", md, 8)[0] * 512
    for b, blkid in sorted(l0, key=lambda e: e[1]):
        c = rd(p, b)
        s = 0
        while s < len(c):
            dn = bytes(c[s:s + 512])
            if dn[0] == 0:
                s += 512
                continue
            ex = dn[12]
            full = bytes(c[s:s + (ex + 1) * 512])
            nobj += 1
            u = dn_used(full)
            t = tree_dsize(z, p, full)
            if full[7] & 4:
                t += dsize(z.BP(full[(ex + 1) * 512 - 128:(ex + 1) * 512]))
            sum_used += u
            if u != t:
                bad.append("object %d: dn_used %d != Σ dsize of its tree %d" % (blkid * (blksz // 512) + s // 512, u, t))
            if useron and full[7] & 10:
                ids = ids_of(z, p, full)
                if ids is not None:
                    keys = [(0, ids[0]), (1, ids[1])] + ([(2, ids[2])] if projon else [])
                    for kind, i in keys:
                        if full[7] & 2:
                            count[(kind, "%x" % i)] = count.get((kind, "%x" % i), 0) + 512 + u
                        if full[7] & 8:
                            count[(kind, "obj-%x" % i)] = count.get((kind, "obj-%x" % i), 0) + 1
            s += (ex + 1) * 512
    asz = dsize(bp)
    if ref != sum_used + asz:
        bad.append("ds_referenced %d != Σ dn_used %d + objset block %d (off by %d)" % (ref, sum_used, asz, ref - sum_used - asz))
    nz = 0
    if useron:
        for kind, nm, off in ((0, "user", 1024), (1, "group", 1536), (2, "project", 2048)):
            if kind == 2 and not projon:
                continue
            got = {k: (v if isinstance(v, int) else -1) for k, (_t, v, _n, _p) in p.zap(osn, off).items()}
            want = {k: v for (kk, k), v in count.items() if kk == kind and v != 0}
            nz += len(got)
            for k in sorted(set(got) | set(want)):
                g, w = got.get(k), want.get(k)
                if g != w:
                    bad.append("%sused %r = %s, the recount %s" % (nm, k, "absent" if g is None else g, "absent" if w is None else w))
    if bad:
        raise ValueError("%s: %s" % (name, "; ".join(bad[:6]) + (" (+%d more)" % (len(bad) - 6) if len(bad) > 6 else "")))
    RECOUNT[name] = {(kind, k): v for (kind, k), v in count.items() if v != 0} if useron else None
    return "%s: %d objects, dn_used == Σ dsize, referenced %d == Σ dn_used + objset %d, %s" % (
        name, nobj, ref, asz, ("%d accounting key(s) == the recount%s" % (nz, "" if projon else ", no project quota"))
        if useron else "no user accounting")


RECOUNT = {}
HEADS = []


def born_after(z, p, osbp, mintxg):
    """Σ dsize of every BP of the objset osbp names whose birth (BP_GET_BIRTH — the physical one under the rewrite flag,
    B9 review) is > mintxg: the objset block, the meta-dnode's
    tree with every dnode's tree and spill block in its L0 blocks, and the user / group / project-used dnodes' trees.
    A BP born at or before mintxg is skipped with its whole subtree (a parent is rewritten whenever a child is)."""
    if osbp.hole or osbp.gbirth <= mintxg:
        return 0
    tot = [dsize(osbp)]

    def tree(dn, dnode_blocks):
        stack = [z.BP(dn[64 + 128 * i:192 + 128 * i]) for i in range(dn[3])]
        while stack:
            bp = stack.pop()
            if bp.hole or bp.gbirth <= mintxg:
                continue
            tot[0] += dsize(bp)
            if bp.embedded:
                continue
            c = rd(p, bp)
            if bp.level > 0:
                stack.extend(z.BP(c[j:j + 128]) for j in range(0, len(c), 128))
            elif dnode_blocks:
                s = 0
                while s < len(c):
                    if c[s] == 0:
                        s += 512
                        continue
                    ex = c[s + 12]
                    d = bytes(c[s:s + (ex + 1) * 512])
                    tree(d, False)
                    if d[7] & 4:
                        sp = z.BP(d[(ex + 1) * 512 - 128:(ex + 1) * 512])
                        if not sp.hole and sp.gbirth > mintxg:
                            tot[0] += dsize(sp)
                    s += (ex + 1) * 512

    osc = p.node(osbp, None).content
    tree(bytes(osc[0:512]), True)
    for off in (1024, 1536, 2048):
        if off + 512 <= osbp.lsize and osc[off] != 0:
            tree(bytes(osc[off:off + 512]), False)
    return tot[0]


def nonheritable_prop(p, mos, pz, name):
    """A NON-inheritable property (refreservation) at one dsl_dir, dsl_prop_get_dd's order (dsl_prop.c:118-170): the
    local value, else name$recvd unless name$inherit is present; 0 unset."""
    if not pz:
        return 0
    zz = p.zap(*p.dnode(mos, pz))
    v = zz.get(name)
    if v is None and (name + "$inherit") not in zz:
        v = zz.get(name + "$recvd")
    if v is None:
        return 0
    if not isinstance(v[1], int):
        raise ValueError("property %s is not an integer" % name)
    return v[1]


def space_check(acct):
    """OpenZFS's userspace / groupspace / projectspace lines vs the recount. (lines, failures)"""
    kinds = {"user": 0, "group": 1, "project": 2}
    seen, out, bad, n = {}, [], 0, 0
    for l in open(acct, encoding="utf-8", errors="replace"):
        f = l.split()
        if len(f) != 6 or f[0] != "space" or f[1] not in kinds:
            continue
        kind, ds, nm, used, objs = kinds[f[1]], f[2], f[3], f[4], f[5]
        rc = RECOUNT.get(ds)
        if rc is None:
            out.append("FAIL space %s %s %s: the recount has no user accounting for %s" % (f[1], ds, nm, ds)); bad += 1
            continue
        i = int(nm) if nm.isdigit() else {"root": 0, "wheel": 0}.get(nm)
        if i is None:
            out.append("FAIL space %s %s %s: an owner name this check cannot map to an id" % (f[1], ds, nm)); bad += 1
            continue
        seen.setdefault(ds, set()).add((kind, i))
        wu, wo = rc.get((kind, "%x" % i), 0), rc.get((kind, "obj-%x" % i), 0)
        gu = int(used) if used.isdigit() else 0
        go = int(objs) if objs.isdigit() else 0
        n += 1
        if (gu, go) != (wu, wo):
            out.append("FAIL space %s %s %s: OpenZFS reads used %s objused %s, the recount %d / %d" % (f[1], ds, nm, used, objs, wu, wo)); bad += 1
    for ds, ids in seen.items():
        for (kind, k), v in RECOUNT[ds].items():
            if not k.startswith("obj-") and (kind, int(k, 16)) not in ids:
                out.append("FAIL space %s %s: the recount has id %s (%d B) that OpenZFS did not list" % (("user", "group", "project")[kind], ds, k, v)); bad += 1
    if n == 0:
        out.append("FAIL --space: no space line compared"); bad += 1
    return out, bad, n


def fbpo_check(z, p, mos, mosdir, root, want):
    """The free_bpobj / $FREE identity (the header's fbpo). (line, failed)"""
    if "free_bpobj" not in mosdir:
        return "free_bpobj: none on this pool", 0
    h, o = p.dnode(mos, mosdir["free_bpobj"][1])
    b, blen = p.bonus(h, o)
    hdr = bytes(h.content[b:b + 56])
    num, nbytes = struct.unpack_from("<QQ", hdr, 0)
    comp, uncomp = struct.unpack_from("<QQ", hdr, 16) if blen >= 32 else (None, None)
    data = p.object_data(h, o) if num else b""
    su = sc = suc = 0
    bad = []
    for i in range(num):
        bp = z.BP(data[i * 128:i * 128 + 128])
        if bp.hole:
            bad.append("entry %d is a hole" % i)
            continue
        su += dsize(bp)
        sc += 0 if bp.embedded else bp.psize
        # DMU_OT_IS_METADATA (dmu.h:131-133): a DMU_OTN_* type's bit 6, else every legacy type but the five data ones
        meta = bp.level > 0 or (((bp.type >> 6) & 1) if bp.type & 0x80 else bp.type not in (19, 23, 25, 26, 49))
        suc += (bp.psize if meta else bp.lsize) if not bp.embedded else (0 if meta else bp.lsize)
        if bp.fill != 0:
            bad.append("entry %d: fill %d (bpobj_enqueue stores 0)" % (i, bp.fill))
        if not bp.dedup and not bp.embedded and any(bp.w[12:16]):
            bad.append("entry %d: a checksum (bpobj_enqueue zeroes it unless dedup)" % i)
    if su != nbytes:
        bad.append("Σ dsize %d != bpo_bytes %d" % (su, nbytes))
    if comp is not None and (sc, suc) != (comp, uncomp):
        bad.append("Σ PSIZE / UCSIZE %d / %d != bpo_comp / bpo_uncomp %d / %d" % (sc, suc, comp, uncomp))
    rh, ro = p.dnode(mos, root)
    rb, _ = p.bonus(rh, ro)
    fd = p.zap(*p.dnode(mos, struct.unpack_from("<Q", rh.content, rb + 32)[0])).get("$FREE")
    fu = 0
    if fd:
        fh, fo = p.dnode(mos, fd[1])
        fb, _ = p.bonus(fh, fo)
        fu = struct.unpack_from("<Q", fh.content, fb + 40)[0]
    if fu != nbytes:
        bad.append("$FREE dd_used %d != free_bpobj's bpo_bytes %d" % (fu, nbytes))
    if want is not None and fu != want:
        bad.append("$FREE dd_used %d != the %d B the writer deferred (its plan lines' fbpo=)" % (fu, want))
    if bad:
        return "FAIL free_bpobj: " + "; ".join(bad[:4]), 1
    return "free_bpobj: %d entr%s, %d B == bpo_bytes == $FREE dd_used%s" % (num, "y" if num == 1 else "ies", nbytes,
                                                                          "" if want is None else " == the writer's Σ fbpo"), 0


def bpobj_sums(z, p, mos, obj):
    """(entries, Σ dsize, Σ PSIZE, Σ UCSIZE, [bad]) of bpobj obj — its own BPs and, recursively, its subobjs' headers —
    with its header's (num, bytes, comp, uncomp) checked against them and every stored BP held to bpobj_enqueue's form."""
    h, o = p.dnode(mos, obj)
    if h.content[o] != 5 or h.content[o + 4] != 6:
        raise ValueError("object %d is not a BPOBJ (type %d, bonus type %d)" % (obj, h.content[o], h.content[o + 4]))
    b, blen = p.bonus(h, o)
    hdr = bytes(h.content[b:b + blen])
    num, nbytes = struct.unpack_from("<QQ", hdr, 0)
    comp, uncomp = struct.unpack_from("<QQ", hdr, 16) if blen >= 32 else (None, None)
    subobjs, nsub = struct.unpack_from("<QQ", hdr, 32) if blen >= 48 else (0, 0)
    data = p.object_data(h, o) if num else b""
    su = sc = suc = 0
    bps, bad = [], []
    for i in range(num):
        bp = z.BP(data[i * 128:i * 128 + 128])
        if bp.hole:
            bad.append("bpobj %d entry %d is a hole" % (obj, i))
            continue
        bps.append(bp)
        su += dsize(bp)
        sc += 0 if bp.embedded else bp.psize
        meta = bp.level > 0 or (((bp.type >> 6) & 1) if bp.type & 0x80 else bp.type not in (19, 23, 25, 26, 49))
        suc += (bp.psize if meta else bp.lsize) if not bp.embedded else (0 if meta else bp.lsize)
        if bp.fill != 0:
            bad.append("bpobj %d entry %d: fill %d (bpobj_enqueue stores 0)" % (obj, i, bp.fill))
        if bp.embedded:
            if any(bp.w[k] for k in (0, 1, 2, 3, 4, 5, 7, 8, 9, 11, 12, 13, 14, 15)):
                bad.append("bpobj %d entry %d: an embedded BP keeps payload (bpobj_enqueue keeps blk_prop + birth)" % (obj, i))
        elif not bp.dedup and any(bp.w[12:16]):
            bad.append("bpobj %d entry %d: a checksum (bpobj_enqueue zeroes it unless dedup)" % (obj, i))
    if nsub:
        sh, so = p.dnode(mos, subobjs)
        arr = p.object_data(sh, so)
        for k in range(nsub):
            n2, u2, c2, uc2, _bp2, bad2 = bpobj_sums(z, p, mos, struct.unpack_from("<Q", arr, 8 * k)[0])
            su += u2; sc += c2; suc += uc2; bad += bad2
    if su != nbytes:
        bad.append("bpobj %d: Σ dsize %d != bpo_bytes %d" % (obj, su, nbytes))
    if comp is not None and (sc, suc) != (comp, uncomp):
        bad.append("bpobj %d: Σ PSIZE / UCSIZE %d / %d != bpo_comp / bpo_uncomp %d / %d" % (obj, sc, suc, comp, uncomp))
    return num, su, sc, suc, bps, bad


def dl_check(z, p, mos, mosdir, feats_w, heads):
    """(1.57.12 B9, design § e.2 branch B) every DEADLIST of every head and snapshot (and clone livelist) — each
    entry's bpobj recounted (bpobj_sums), every BP in entry K born in (K, next key], dl_used / dl_comp / dl_uncomp == Σ
    its entries; the empty_bpobj refcount (features_for_write) == the deadlist entries naming it, the empty_bpobj itself
    empty; and per snapshotted head, OpenZFS's own space rule over those deadlists: each snapshot's ds_unique_bytes ==
    its next's deadlist entries from its ds_prev_snap_txg on (dsl_dataset_space_wouldfree for one), the dir's
    dd_used_breakdown[SNAP] == every snapshot's after the first and the head's deadlist from the first's ds_prev_snap_txg
    on (for all of them). (lines, failures)"""
    ebo = mosdir["empty_bpobj"][1] if "empty_bpobj" in mosdir else 0
    ebr = feats_w.get("com.delphix:empty_bpobj", (None, 0))[1]
    seen, space, out, bad, refs, nent = set(), {}, [], [], 0, 0

    def one(dlo, owner, full=True, cap=None):
        nonlocal refs, nent
        if dlo in seen:
            return
        seen.add(dlo)
        h, o = p.dnode(mos, dlo)
        t = h.content[o]
        if t == 5:                                           # the old format: one bpobj, no intervals (no identities)
            n, su, sc, suc, _bps, bb = bpobj_sums(z, p, mos, dlo)
            bad.extend("%s: %s" % (owner, x) for x in bb)
            space[dlo] = None
            return
        if not full:                                         # a livelist (ALLOC / FREE records): its empty_bpobj names only
            refs += sum(1 for v in p.zap(h, o).values() if ebo and v[1] == ebo)
            return
        if t != 50 or h.content[o + 4] != 51:
            bad.append("%s: deadlist %d is type %d / bonus %d" % (owner, dlo, t, h.content[o + 4]))
            return
        b, _blen = p.bonus(h, o)
        dlu, dlc, dluc = struct.unpack_from("<3Q", h.content, b)
        ents = sorted((int(k, 16), v[1]) for k, v in p.zap(h, o).items())
        su = sc = suc = 0
        sp = []
        for i, (key, bo) in enumerate(ents):
            nent += 1
            # (B9 review) the newest entry ends at its owner's ds_prev_snap_txg: no block born after it is the snapshot's
            nxt = ents[i + 1][0] if i + 1 < len(ents) else cap
            if ebo and bo == ebo:
                refs += 1
                sp.append((key, 0))
                continue
            n, u, c, uc, bps, bb = bpobj_sums(z, p, mos, bo)
            bad.extend("%s: deadlist %d entry %x: %s" % (owner, dlo, key, x) for x in bb)
            for bp in bps:
                if bp.gbirth <= key or (nxt is not None and bp.gbirth > nxt):
                    bad.append("%s: deadlist %d entry %x holds a BP born %d (its entry is (%d, %s])" % (owner, dlo, key, bp.gbirth, key, nxt))
                    break
            su += u; sc += c; suc += uc
            sp.append((key, u))
        if (su, sc, suc) != (dlu, dlc, dluc):
            bad.append("%s: deadlist %d dl_used / dl_comp / dl_uncomp %d / %d / %d != Σ its entries %d / %d / %d"
                       % (owner, dlo, dlu, dlc, dluc, su, sc, suc))
        space[dlo] = sp

    def ds(obj):
        h, o = p.dnode(mos, obj)
        b, _ = p.bonus(h, o)
        return struct.unpack_from("<16Q", h.content, b)

    nid = 0
    for name, dobj, head in heads:
        dh, do = p.dnode(mos, dobj)
        db, _ = p.bonus(dh, do)
        dd = bytes(dh.content[db:db + 256])
        if dh.content[do] == 0xC4:
            ll = p.zap(dh, do).get("com.delphix:livelist")
            if ll:
                one(ll[1], name + " (livelist)", False)
        hp = ds(head)
        one(hp[8], name, cap=hp[2])
        chain, prev = [(head, hp)], hp[1]
        while prev:                                          # its own snapshots, newest first, then the origin's
            sp_ = ds(prev)
            if sp_[0] != dobj:
                break
            one(sp_[8], "%s@%d" % (name, prev), cap=sp_[2])
            chain.append((prev, sp_))
            prev = sp_[1]
        if len(chain) == 1:
            continue
        if any(space.get(x[8], []) is None for (_o, x) in chain):
            continue
        # per snapshot: unique == its next's deadlist from its prev_snap_txg on
        for i in range(1, len(chain)):
            sobj, sp_ = chain[i]
            nxt = chain[i - 1][1]
            want = sum(u for k, u in space.get(nxt[8], []) if k >= sp_[2])
            nid += 1
            if sp_[12] != want:
                bad.append("%s: snapshot %d ds_unique_bytes %d != its next's deadlist from txg %d on: %d (off by %d)"
                           % (name, sobj, sp_[12], sp_[2], want, sp_[12] - want))
        if dd[96] & 1:
            first = chain[-1][1]
            want = sum(u for (_o, x) in chain[:-1] for k, u in space.get(x[8], []) if k >= first[2])
            snapbd = struct.unpack_from("<Q", dd, 112)[0]
            nid += 1
            if snapbd != want:
                bad.append("%s: dd_used_breakdown[SNAP] %d != every deadlist after its first snapshot from txg %d on: %d (off by %d)"
                           % (name, snapbd, first[2], want, snapbd - want))
    if ebo:
        h, o = p.dnode(mos, ebo)
        b, _ = p.bonus(h, o)
        if struct.unpack_from("<Q", h.content, b)[0] != 0:
            bad.append("empty_bpobj %d is not empty" % ebo)
    if refs != ebr:
        bad.append("features_for_write empty_bpobj refcount %d != the %d deadlist entries naming it" % (ebr, refs))
    if bad:
        return ["FAIL deadlists: " + "; ".join(bad[:4]) + (" (+%d more)" % (len(bad) - 4) if len(bad) > 4 else "")], 1
    return ["deadlists: %d deadlist(s), %d entries recounted (dl_used == Σ entries, every BP in its interval), empty_bpobj"
            " refcount %d == the entries naming it, %d snapshot-unique / SNAP identit(ies)" % (len(seen), nent, ebr, nid)], 0


def main(argv):
    acct = None
    want_free = None
    if len(argv) >= 4 and argv[-2] == "--freeing":
        want_free = int(argv[-1])
        argv = argv[:-2]
    if len(argv) == 4 and argv[2] == "--space" and os.path.isfile(argv[3]):
        acct = argv[3]
        argv = argv[:2]
    if len(argv) != 2 or not os.path.isfile(argv[1]):
        print("usage: zfs-uacct-check.py IMG [--space ACCT]")
        return 2
    z = load_lib()
    try:
        p = z.Pool(argv[1])
        base = p.read_bp
        p.read_bp = lambda bp, verify=True: base(bp, verify=verify and bp.cksum in (7, 8))   # see rd()
        mos = p.mos()
        mosdir = p.zap(*p.dnode(mos, 1))
        feats = set(p.zap(*p.dnode(mos, mosdir["features_for_write"][1])).keys())
        feats |= set(p.zap(*p.dnode(mos, mosdir["features_for_read"][1])).keys())
        root = mosdir["root_dataset"][1]
    except (z.ToolError, KeyError, ValueError, struct.error) as e:
        print("uacct: unusable input: %s" % e)
        return 2
    lines, fails, n, nd = [], 0, 0, 0
    # $ORIGIN@$ORIGIN: every non-clone filesystem's origin and first ds_prev_snap_obj (no snapshot of its own)
    osnap = 0
    try:
        rh, ro = p.dnode(mos, root)
        rb, _ = p.bonus(rh, ro)
        rcz = struct.unpack_from("<Q", rh.content, rb + 32)[0]
        od = p.zap(*p.dnode(mos, rcz)).get("$ORIGIN")
        if od:
            oh, oo = p.dnode(mos, od[1])
            ob, _ = p.bonus(oh, oo)
            hh, ho = p.dnode(mos, struct.unpack_from("<Q", oh.content, ob + 8)[0])
            hb, _ = p.bonus(hh, ho)
            osnap = struct.unpack_from("<Q", hh.content, hb + 8)[0]
    except (z.ToolError, KeyError, struct.error):
        osnap = 0
    stack = [(root, p.label.get("name", "pool"))]
    nr = nu = 0
    while stack:
        dobj, name = stack.pop()
        try:
            h, o = p.dnode(mos, dobj)
            b, _ = p.bonus(h, o)
            ddp = bytes(h.content[b:b + 256])
            head = struct.unpack_from("<Q", ddp, 8)[0]
            czap = struct.unpack_from("<Q", ddp, 32)[0]
            dorg = struct.unpack_from("<Q", ddp, 24)[0]
            dused = struct.unpack_from("<Q", ddp, 40)[0]
            dpz = struct.unpack_from("<Q", ddp, 80)[0]
            dfl = struct.unpack_from("<Q", ddp, 96)[0]
            bd = struct.unpack_from("<5Q", ddp, 104)
            kids_c = kids_u = kids_used = kids_crsv = 0
            if czap:
                for cn, (_k, cv, _n, _p) in sorted(p.zap(*p.dnode(mos, czap)).items()):
                    ch, co = p.dnode(mos, cv)
                    cb, _ = p.bonus(ch, co)
                    kids_c += struct.unpack_from("<Q", ch.content, cb + 48)[0]
                    kids_u += struct.unpack_from("<Q", ch.content, cb + 56)[0]
                    cu, cr = struct.unpack_from("<Q", ch.content, cb + 40)[0], struct.unpack_from("<Q", ch.content, cb + 72)[0]
                    kids_used += cu
                    kids_crsv += max(0, cr - cu)
                    if not cn.startswith("$"):
                        stack.append((cv, name + "/" + cn))
            bad = []
            brk = dfl & 1
            if brk:
                nr += 1
                if sum(bd) != dused:
                    bad.append("dd_used_breakdown sums to %d, dd_used_bytes is %d" % (sum(bd), dused))
                if bd[2] != kids_used:
                    bad.append("CHILD %d != Σ the child dirs' dd_used %d (off by %d)" % (bd[2], kids_used, bd[2] - kids_used))
                if bd[3] != kids_crsv:
                    bad.append("CHILD_RSRV %d != Σ the child dirs' max(0, dd_reserved - dd_used) %d (off by %d)"
                               % (bd[3], kids_crsv, bd[3] - kids_crsv))
                if not head and bd[4] != 0:
                    bad.append("REFRSRV %d in a dir with no head dataset" % bd[4])
            if not head:
                if bad:
                    raise ValueError("%s: %s" % (name, "; ".join(bad)))
                continue
            HEADS.append((name, dobj, head))
            hd, hdo = p.dnode(mos, head)
            hdb, _ = p.bonus(hd, hdo)
            hds = bytes(hd.content[hdb:hdb + 320])
            prev, ptxg = struct.unpack_from("<QQ", hds, 8)
            ref, _hc, _hu, uniq = struct.unpack_from("<4Q", hds, 72)
            encrypted = (struct.unpack_from("<Q", hds, 176)[0] >> 61) & 1
            plain = prev in (0, osnap) and dorg in (0, osnap)
            if plain:
                dc, du = struct.unpack_from("<QQ", ddp, 48)
                hc, hu = struct.unpack_from("<QQ", hds, 80)
                nd += 1
                if (dc, du) != (hc + kids_c, hu + kids_u):
                    bad.append("dsl_dir compressed / uncompressed %d / %d != the head's %d / %d + the child dirs' %d / %d"
                               " (off by %d / %d)" % (dc, du, hc, hu, kids_c, kids_u, dc - hc - kids_c, du - hu - kids_u))
            # ds_unique_bytes against the blocks (born / kill branch A), then the REFRSRV split it drives
            if plain:
                nu += 1
                if uniq != ref:
                    bad.append("ds_unique_bytes %d != ds_referenced_bytes %d of a snapshot-free non-clone head (off by %d)"
                               % (uniq, ref, uniq - ref))
            elif not encrypted:
                nu += 1
                want = born_after(z, p, z.BP(hds[128:256]), ptxg)
                if uniq != want:
                    bad.append("ds_unique_bytes %d != Σ dsize of its blocks born after ds_prev_snap_txg %d: %d (off by %d)"
                               % (uniq, ptxg, want, uniq - want))
            if brk:
                rr = nonheritable_prop(p, mos, dpz, "refreservation")
                if bd[4] != max(0, rr - uniq):
                    bad.append("REFRSRV %d != max(0, refreservation %d - ds_unique_bytes %d) = %d (off by %d)"
                               % (bd[4], rr, uniq, max(0, rr - uniq), bd[4] - max(0, rr - uniq)))
                if dorg in (0, osnap) and bd[0] != ref:
                    bad.append("HEAD %d != ds_referenced_bytes %d of a non-clone head (off by %d)" % (bd[0], ref, bd[0] - ref))
            if bad:
                raise ValueError("%s: %s" % (name, "; ".join(bad)))
            if encrypted:
                lines.append("%s: encrypted — dsl_dir checks only" % name)
                continue
            r = check_ds(z, p, name, hds, feats)
            if r is not None:
                lines.append(r)
                n += 1
        except ValueError as e:
            lines.append("FAIL %s" % e)
            fails += 1
        except (z.ToolError, KeyError, struct.error) as e:
            lines.append("FAIL %s: unreadable: %s" % (name, e))
            fails += 1
    try:
        fl, ff = fbpo_check(z, p, mos, mosdir, root, want_free)
    except (z.ToolError, KeyError, ValueError, struct.error) as e:
        fl, ff = "FAIL free_bpobj: unreadable: %s" % e, 1
    lines.append(fl)
    fails += ff
    try:
        fw = p.zap(*p.dnode(mos, mosdir["features_for_write"][1]))
        dl, df = dl_check(z, p, mos, mosdir, fw, HEADS)
    except (z.ToolError, KeyError, ValueError, struct.error) as e:
        dl, df = ["FAIL deadlists: unreadable: %s" % e], 1
    lines.extend(dl)
    fails += df
    sp = ""
    if acct is not None and fails == 0:
        sl, sb, sn = space_check(acct)
        lines.extend(sl)
        fails += sb
        sp = ", OpenZFS's userspace / groupspace / projectspace: %d line(s)%s" % (sn, " == the recount" if sb == 0 else "")
    for l in lines:
        print("uacct:   %s" % l)
    if fails == 0 and n == 0:
        print("uacct: FAIL — no ZPL dataset was checked")
        return 1
    print("uacct: %s" % fl)
    print("uacct: %s — %d ZPL dataset(s) recounted (dn_used, referenced, user/group/project), %d snapshot-free dsl_dir(s)"
          " compressed / uncompressed == head + child dirs, %d dsl_dir(s) breakdown == used / CHILD / CHILD_RSRV / REFRSRV /"
          " HEAD, %d head(s) ds_unique_bytes recounted%s%s"
          % ("PASS" if fails == 0 else "FAIL", n, nd, nr, nu, sp, "" if fails == 0 else ", %d failed" % fails))
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
