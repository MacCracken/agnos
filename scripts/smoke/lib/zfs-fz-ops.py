#!/usr/bin/env python3
# zfs-fz-ops.py (agnos 1.57.12, bite B8) — the expected ops of the fat-ZAP pool's op list (core/zfs_write.cyr zfs_wt_b8,
# fixture RECIPE 7's agnosfz) as scripts/smoke/lib/zfs-expect.py ops, in the kernel's order: what the guest's phase B
# and the walk are held to. The plan is the kernel's, re-derived here independently:
#   · b8/'s names are CHOSEN by their ZAP hash under the list's salt (zfs_wc_fsalt 0x5A17B9) — 255-byte `b` names with the
#     top 2 bits 0b00, `a` names sharing the top 12 bits 0x5A3 — with scripts/check/zfs-fatzap.py's zap_hash (the CRC-64 the
#     kernel's codec computes, held equal on gate 37), and the `a` count — "until the pointer table began doubling" —
#     from that model run over the same adds
#   · dir3000/'s SMALLEST leaf is found on the PRISTINE image (scripts/tool/zfs-damage.py's Pool reads the directory's
#     blocks) after the model applies the ops that reach dir3000 first (a rename in, one out, a link in, a 255-byte name
#     in and out — dummy values: they do not move chunks), its names in chunk order: what the kernel unlinks
# usage: zfs-fz-ops.py FZ-IMG          prints the ops; `# a-names N`, `# small-leaf ...` on stderr
import importlib.util, os, struct, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


def _load(name, rel):
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, rel))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


FZ = _load("zfs_fatzap", "scripts/check/zfs-fatzap.py")
ZD = _load("zfsdamage", "scripts/tool/zfs-damage.py")
SALT = 0x5A17B9
LONG = b"b8-long-name-".ljust(60, b"y")
PAIR = (b"c85912", b"c140200")


def gen(letter, bits, want):
    """The kernel's zfs_wt_gname: "<letter><7 digits>-" padded with q to 255 bytes, its hash's top bits want."""
    i = 0
    while True:
        nm = (letter + b"%07d-" % i).ljust(255, b"q")
        i += 1
        if bits == 0 or FZ.zap_hash(SALT, nm) >> (64 - bits) == want:
            yield nm


def b8_plan():
    """The b8/ adds in the kernel's order, and the number of `a` names until zt_nextblk != 0."""
    z = FZ.FatZap(14)
    micro = [(b"s0", 1, 0), (b"s1", 2, 0), (PAIR[0], 3, 0), (b"s2", 4, 0), (PAIR[1], 5, 1), (b"s3", 6, 0)]
    assert FZ.zap_hash(SALT, PAIR[0]) == FZ.zap_hash(SALT, PAIR[1]), "the collision pair does not collide"
    z.upgrade(FZ.micro_block(512, SALT, micro))
    z.op("add", LONG, 8, (7,))
    gb, ga = gen(b"b", 2, 0), gen(b"a", 12, 0x5A3)
    bn = [next(gb) for _ in range(42)]
    for nm in bn:
        z.op("add", nm, 8, (1,))
    an = []
    while not FZ.u64(z.hdr, 40):
        nm = next(ga)
        an.append(nm)
        z.op("add", nm, 8, (2,))
        assert len(an) < 400, "the pointer table never began doubling"
    bn2 = [next(gb) for _ in range(2)]
    return bn, an, bn2


def small_leaf(img, extra_ops):
    p = ZD.Pool(img)
    mos = p.mos()
    osn = p.dataset_objset(mos, "agnosfz")
    root = p.zap_u64(*p.dnode(osn, 1), "ROOT")
    obj = p.zap(*p.dnode(osn, root))["dir3000"][1] & ((1 << 48) - 1)
    h, o = p.dnode(osn, obj)
    dn = h.content[o:o + 512]
    bsz = struct.unpack_from("<H", dn, 8)[0] * 512
    maxblk = struct.unpack_from("<Q", dn, 16)[0]
    blocks = {}
    for b in range(maxblk + 1):
        nd = p.walk(h, o, b)
        blocks[b] = bytearray(nd.content if nd is not None else bytes(bsz))
    z = FZ.FatZap(bsz.bit_length() - 1, blocks)
    for kind, nm in extra_ops:
        z.op(kind, nm, 8, (9,))
    fb = FZ.u64(z.hdr, 56)
    best, bn = None, None
    for k in range(1, fb):
        lf = z.blocks.get(k)
        if lf is None or FZ.u64(lf, 0) != FZ.ZBT_LEAF or FZ.u32(lf, 24) != FZ.LEAF_MAGIC:
            continue
        n = FZ.u16(lf, 30)
        if bn is None or n < bn:
            best, bn = k, n
    l = z.leaf(best)
    names = []
    for c in range(l.nc):
        o2 = l.ch(c)
        if l.b[o2] == FZ.T_ENTRY:
            names.append(l.aread(FZ.u16(l.b, o2 + 4), FZ.u16(l.b, o2 + 6) - 1))
    assert len(names) == bn
    return best, names


def main(argv):
    if len(argv) != 2:
        print("usage: zfs-fz-ops.py FZ-IMG", file=sys.stderr)
        return 2
    out = []
    P = "/agnosfz"
    B8 = P + "/b8"
    out.append("mkdir %s" % B8)
    for n in (b"s0", b"s1", PAIR[0], b"s2", PAIR[1], b"s3", LONG):
        out.append("create %s/%s" % (B8, n.decode()))
    bn, an, bn2 = b8_plan()
    out += ["create %s/%s" % (B8, n.decode()) for n in bn]
    out += ["create %s/%s" % (B8, n.decode()) for n in an]
    out += ["create %s/%s" % (B8, n.decode()) for n in bn2]
    spread = ["spread-%03d" % i for i in range(10)]
    out += ["create %s/%s" % (B8, s) for s in spread]
    n255 = "b8-255-" + "L" * 248
    out.append("create %s/%s" % (B8, n255))
    out += ["unlink %s/%s" % (B8, s) for s in spread]
    out += ["unlink %s/%s" % (B8, n.decode()) for i, n in enumerate(an) if i % 10 == 0]
    out += ["unlink %s/%s" % (B8, n.decode()) for n in bn[:5]]
    out.append("rename %s/s0 %s/s0-renamed-in-its-fat-directory-to-a-name-of-sixty-bytes" % (B8, B8))
    out.append("rename %s/s1 %s/dir3000/s1-from-b8" % (B8, P))
    out.append("rename %s/dir3000/f0001 %s/f0001" % (P, B8))
    out.append("link %s/dir3000/f0002 %s/link-f0002" % (P, B8))
    out.append("link %s/s2 %s/dir3000/link-s2" % (B8, P))
    d255 = "d3k-255-" + "M" * 247
    out.append("create %s/dir3000/%s" % (P, d255))
    out.append("unlink %s/dir3000/%s" % (P, d255))
    best, names = small_leaf(argv[1], [("add", b"s1-from-b8"), ("remove", b"f0001"), ("add", b"link-s2"),
                                      ("add", d255.encode()), ("remove", d255.encode())])
    out += ["unlink %s/dir3000/%s" % (P, n.decode()) for n in names]
    out += ["unlink %s/longn/%s" % (P, ("%02d-" % i) + "L" * 252) for i in range(60)]
    out.append("rmdir %s/longn" % P)
    out.append("create %s/micro/a-name-of-fifty-five-bytes-upgrades-this-microzap-xxxxx" % P)
    out.append("write %s/uids/u50 0 10 b8/u50" % P)
    out.append("unlink %s/uids/u51" % P)
    out.append("create %s/uids/new.txt" % P)
    out.append("create %s/uidm/new.txt" % P)
    out.append("symlink %s/sym hello.txt" % P)
    out.append("symlink %s/sym2 hello.txt" % P)
    print("\n".join(out))
    print("# a-names %d" % len(an), file=sys.stderr)
    print("# small-leaf block %d entries %d" % (best, len(names)), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
