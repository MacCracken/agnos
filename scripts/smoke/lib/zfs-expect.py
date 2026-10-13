#!/usr/bin/env python3
# zfs-expect — the EXPECTED manifest of a pool after a list of write operations (agnos 1.57.12; design
# docs/development/proposals/2026-10-09-zfs-write.md § i.3 B): expected = the fixture's manifest (what OpenZFS
# wrote, scripts/tool/zfs-fixture.sh) + the op list the writer was asked to perform. `zfs-fixture.sh --verify`
# diffs what a read-only OpenZFS import of the written pool shows against this, EXACTLY. An empty op list is the
# identity (bite B0: every pristine lane must come back byte-for-byte as its own manifest).
#
# usage: zfs-expect.py MANIFEST [OPS] [-o OUT] [--orig DIR] [--objects FILE] [--leakok OUT] [--xattrs IN --xattrs-out OUT]
#        zfs-expect.py gen SEED OFFSET LENGTH        raw generator bytes to stdout
#        zfs-expect.py vectors                        the generator's reference vectors (for the Cyrius port)
#   MANIFEST  <lane>.manifest (D / F / L / M lines; see zfs-fixture.sh)
#   OPS       the op list (below); omitted or empty = identity
#   --orig D  original bytes of fixture files the ops modify in place, at D/<manifest path> — each one is checked
#             against the manifest's size + SHA-256 before it is used (the manifest carries hashes, not bytes)
#   --objects <lane>.objects — "<object id> <path>"; names sharing an object id inside one dataset are ONE file
#             (hard links): a write through one name changes them all. Without it every name is its own file.
#   --leakok OUT  the design-k.15 objects, one live manifest path per object: files whose ZPL PARENT names a directory
#             that holds no entry for them after the ops. FreeBSD's zfs_link_create writes PARENT := the new name's
#             directory on EVERY link and rename (zfs_dir.c:640-641) and nothing rewrites it when that name is unlinked,
#             so `link A/f B/g` + `unlink B/g` leaves A/f live with PARENT = B — zdb -ddddd prints "path not found,
#             possibly leaked" for it (zdb.c:3790-3798) on a pool OpenZFS alone would produce. The verify's A5 tolerates
#             EXACTLY these objects (resolved to object ids with zdb -O), never a count: a real orphan cannot stand in.
#   --stat OUT    (B7) what OpenZFS's stat(1) must say in phase B (B-stat) of every object the ops CREATED and that is still
#             there, at its FINAL name: "<path> <mode> <links> <size>" — a file its live names and its size, a directory 2 +
#             its subdirectories and 2 + its entries, a symlink 1 and its target's length (one line per object: the first
#             of its names). It was an awk over the create lines, which a later rename, link or unlink falsified.
#   --xattrs IN --xattrs-out OUT  the expected `X <path> user <name> <len> <sha256>` listing (zfs-fixture.sh's
#             <image>.xattrs format) after the ops: xattrs belong to the object, so they follow renames, appear under
#             every hard link, vanish with the last name; created files have none. B-xattrs diffs the view against it.
# Exit 0 written · 1 the op list is inconsistent with the manifest (writes a missing file, rmdir of a non-empty
# dir, a rename across datasets ...) · 2 usage / unusable input (a needed --orig file is missing or wrong).
#
# ---- the op list ------------------------------------------------------------------------------------------------
# One op per line, single spaces, '#' starts a comment line. Paths are manifest paths (absolute under the import's
# altroot, no whitespace — the manifest contract). Only ops that SUCCEED belong here: a refusal changes nothing.
#   mkdir   PATH                       new empty directory
#   create  PATH                       new empty regular file (AO_CREAT|AO_EXCL)
#   write   PATH OFFSET LENGTH SEED    file bytes [OFFSET, OFFSET+LENGTH) := gen(SEED) bytes [OFFSET, OFFSET+LENGTH)
#                                      (extends the file; a gap past the old EOF reads as zeros — a hole)
#   zero    PATH OFFSET LENGTH         file bytes [OFFSET, OFFSET+LENGTH) := 0 (extends likewise)
#   trunc   PATH                       size := 0 (AO_TRUNC)
#   truncate PATH LENGTH               size := LENGTH, bytes past it gone (the kernel's internal any-length truncation,
#                                      zfs_wtrunc — what an ftruncate would be glue over; LENGTH >= size changes nothing)
#   unlink  PATH                       remove a non-directory name
#   rmdir   PATH                       remove an EMPTY directory
#   rename  FROM TO                    same dataset; TO (if present) replaced by a same-kind entry, a dir only if empty
#   link    EXISTING NEW               hard link to a regular file, same dataset
#   symlink PATH TARGET...             TARGET is the rest of the line, verbatim
# OFFSET / LENGTH are decimal or 0x-hex. The stream is addressed by FILE offset, so a file written with one SEED in any
# chunking (one 1 MiB write, or 16 x 64 KiB) has the same bytes: gen(SEED)[0:size].
#
# ---- the content generator: agnos-gen-1 (byte-exact; ported to Cyrius for ZFS_WRITE_SELFTEST) ---------------------
#   seed64(S)  = FNV-1a-64 over the bytes of S:  h = 0xcbf29ce484222325; for each byte c: h = ((h XOR c) *
#                0x100000001b3) mod 2^64
#   mix64(z)   = z = ((z XOR (z >> 30)) * 0xbf58476d1ce4e5b9) mod 2^64; z = ((z XOR (z >> 27)) * 0x94d049bb133111eb)
#                mod 2^64; return z XOR (z >> 31)          — every >> is a LOGICAL shift of the unsigned 64-bit value
#   word(S, i) = mix64((seed64(S) + (i + 1) * 0x9e3779b97f4a7c15) mod 2^64)      (splitmix64's i-th output)
#   byte(S, x) = (word(S, x >> 3) >> (8 * (x AND 7))) AND 0xff                     (words laid out little-endian)
# splitmix64 because scripts/check/zfs-codec-vectors.py and tests/zfscodec already carry it (the 1 MiB codec buffer),
# so the Cyrius side has a proven mixer; position-addressable so a write at any offset needs no state; incompressible
# so file data is never confused with a hole or squeezed by a compressing reader. `zfs-expect.py vectors` prints the
# reference values; the port must reproduce them before any selftest hash is believed.
import hashlib, os, struct, sys

M64 = (1 << 64) - 1
GOLDEN = 0x9E3779B97F4A7C15


def seed64(s):
    h = 0xCBF29CE484222325
    for c in s.encode():
        h = ((h ^ c) * 0x100000001B3) & M64
    return h


def mix64(z):
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
    return z ^ (z >> 31)


def gen(seed, off, n):
    """bytes [off, off+n) of the agnos-gen-1 stream for seed."""
    if n <= 0:
        return b""
    s = seed64(seed)
    w0, w1 = off >> 3, (off + n + 7) >> 3
    buf = b"".join(struct.pack("<Q", mix64((s + (i + 1) * GOLDEN) & M64)) for i in range(w0, w1))
    k = off & 7
    return buf[k:k + n]


VECTORS = [("agnos-gen-1", 0, 16), ("", 0, 8), ("wr/a.bin", 1000003, 13), ("x", 7, 3)]


def vectors():
    for s, o, n in VECTORS:
        print("gen(%r, %d, %d) = %s" % (s, o, n, gen(s, o, n).hex()))
    print("seed64(%r) = %#018x" % ("agnos-gen-1", seed64("agnos-gen-1")))
    print("sha256(gen(%r, 0, 1048576)) = %s" % ("agnos-gen-1", hashlib.sha256(gen("agnos-gen-1", 0, 1 << 20)).hexdigest()))
    # self-consistency: chunked == whole, unaligned windows agree
    whole = gen("agnos-gen-1", 0, 4096)
    assert b"".join(gen("agnos-gen-1", o, 100) for o in range(0, 4096, 100))[:4096] == whole
    assert gen("agnos-gen-1", 13, 77) == whole[13:90]


class Inode:
    def __init__(self, kind, data=None, size=0, sha=None, target=None):
        self.kind, self.data, self.size, self.sha, self.target = kind, data, size, sha, target
        self.parent = None          # the directory Inode the on-disk ZPL PARENT names (AMBIG: unknown, never judged)
        self.made = False           # (B7) created by the op list (--stat)
        self.xattrs = None          # [(name, len, sha256)] or None


AMBIG = object()


class Fail(Exception):
    pass


class Unusable(Exception):
    pass


def parse_manifest(path):
    names, mounts = {}, {}
    for raw in open(path, "rb").read().decode("utf-8", "surrogateescape").splitlines():
        t, rest = raw[:1], raw[2:]
        if t == "D":
            names[rest] = Inode("D")
        elif t == "F":
            p, size, sha = rest.rsplit(" ", 2)
            names[p] = Inode("F", size=int(size), sha=sha)
        elif t == "L":
            p, tgt = rest.split(" ", 1)
            names[p] = Inode("L", target=tgt)
        elif t == "M":
            p, ds = rest.rsplit(" ", 1)
            mounts[p] = ds
        else:
            raise Unusable("manifest line %r" % raw)
    return names, mounts


def dataset_of(path, mounts):
    best = None
    for m in mounts:
        if path == m or path.startswith(m.rstrip("/") + "/") or m == "/":
            if best is None or len(m) > len(best):
                best = m
    return best


def parent(p):
    q = p.rsplit("/", 1)[0]
    return q or "/"


def render(names, mounts):
    out, seen = [], set()
    for p, ino in names.items():
        if ino.kind == "D":
            out.append((p, "D", "D %s" % p))
        elif ino.kind == "L":
            out.append((p, "L", "L %s %s" % (p, ino.target)))
        else:
            if ino.data is not None:
                size, sha = len(ino.data), hashlib.sha256(ino.data).hexdigest()
            else:
                size, sha = ino.size, ino.sha
            out.append((p, "F", "F %s %d %s" % (p, size, sha)))
    for p, ds in mounts.items():
        out.append((p, "M", "M %s %s" % (p, ds)))
    out.sort(key=lambda x: (x[0].encode("utf-8", "surrogateescape"), x[1]))
    return "".join(x[2] + "\n" for x in out)


def set_parents(names):
    """PARENT of every fixture object as OpenZFS left it: the directory of its name — of its first name when a hard-linked
    file's names sit in different directories (none do in the fixture; such an object is AMBIG and never judged)."""
    byid = {}
    for p in sorted(names):
        if p != "/":
            byid.setdefault(id(names[p]), []).append(p)
    for paths in byid.values():
        ino = names[paths[0]]
        dirs = {parent(p) for p in paths}
        ino.parent = names.get(parent(paths[0])) if len(dirs) == 1 else AMBIG


def k15_objects(names):
    """One live path per object whose PARENT directory holds no entry for it (design k.15)."""
    out, seen = [], set()
    for p in sorted(names, key=lambda x: x.encode("utf-8", "surrogateescape")):
        ino = names[p]
        if ino.kind == "D" or id(ino) in seen or p == "/":
            continue
        seen.add(id(ino))
        if ino.parent is AMBIG or ino.parent is None:
            continue
        live = [q for q, v in names.items() if v is ino]
        if not any(names.get(parent(q)) is ino.parent for q in live):
            out.append(min(live, key=lambda x: x.encode("utf-8", "surrogateescape")))
    return out


def load_xattrs(names, path):
    for raw in open(path, "rb").read().decode("utf-8", "surrogateescape").splitlines():
        f = raw.split(" ")
        if len(f) != 6 or f[0] != "X" or f[2] != "user":
            raise Unusable("xattrs line %r" % raw)
        if f[1] not in names:
            raise Unusable("xattrs name %s, which the manifest does not have" % f[1])
        ino = names[f[1]]
        if ino.xattrs is None:
            ino.xattrs = []
        ino.xattrs.append((f[3], f[4], f[5], f[1]))


def render_xattrs(names):
    out = []
    for p, ino in names.items():
        if ino.xattrs:
            first = min(t[3] for t in ino.xattrs)          # hard links list the same set under every name: keep one
            out += ["X %s user %s %s %s" % (p, n, ln, h) for (n, ln, h, src) in ino.xattrs if src == first]
    out.sort(key=lambda x: x.encode("utf-8", "surrogateescape"))
    return "".join(x + "\n" for x in out)


def apply_ops(names, mounts, ops_path, orig):
    num = lambda v: int(v, 0)

    def need(p, kind=None):
        if p not in names:
            raise Fail("%s does not exist" % p)
        if kind and names[p].kind != kind:
            raise Fail("%s is not %s" % (p, {"D": "a directory", "F": "a regular file", "L": "a symlink"}[kind]))
        return names[p]

    def fresh(p):
        if p in names or p in mounts:
            raise Fail("%s already exists" % p)
        need(parent(p), "D")

    def content(ino, p):
        if ino.data is None:
            if ino.size == 0:
                ino.data = bytearray()
            else:
                src = os.path.join(orig, p.lstrip("/")) if orig else None
                if not src or not os.path.isfile(src):
                    raise Unusable("op modifies %s in place but no original bytes were given (--orig DIR/%s)" % (p, p.lstrip("/")))
                b = open(src, "rb").read()
                if len(b) != ino.size or hashlib.sha256(b).hexdigest() != ino.sha:
                    raise Unusable("--orig %s does not match the manifest's size/SHA-256 for %s" % (src, p))
                ino.data = bytearray(b)
        return ino.data

    def children(d):
        pre = d.rstrip("/") + "/"
        return [p for p in names if p.startswith(pre) and "/" not in p[len(pre):]] + \
               [m for m in mounts if m.startswith(pre) and "/" not in m[len(pre):]]

    n = 0
    for lineno, raw in enumerate(open(ops_path, encoding="utf-8", errors="surrogateescape"), 1):
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        f = line.split(" ")
        op = f[0]
        try:
            if op == "mkdir" and len(f) == 2:
                fresh(f[1]); names[f[1]] = Inode("D"); names[f[1]].parent = names[parent(f[1])]; names[f[1]].made = True
            elif op == "create" and len(f) == 2:
                fresh(f[1]); names[f[1]] = Inode("F", data=bytearray()); names[f[1]].parent = names[parent(f[1])]
                names[f[1]].made = True
            elif op in ("write", "zero") and len(f) == (5 if op == "write" else 4):
                ino = need(f[1], "F")
                off, ln = num(f[2]), num(f[3])
                d = content(ino, f[1])
                if len(d) < off + ln:
                    d.extend(bytes(off + ln - len(d)))
                d[off:off + ln] = gen(f[4], off, ln) if op == "write" else bytes(ln)
            elif op == "trunc" and len(f) == 2:
                need(f[1], "F").data = bytearray()
            elif op == "truncate" and len(f) == 3:
                ino = need(f[1], "F")
                ln = num(f[2])
                d = content(ino, f[1])
                if ln < len(d):
                    del d[ln:]
            elif op == "unlink" and len(f) == 2:
                if need(f[1]).kind == "D":
                    raise Fail("unlink of directory %s" % f[1])
                del names[f[1]]
            elif op == "rmdir" and len(f) == 2:
                need(f[1], "D")
                if f[1] in mounts or children(f[1]):
                    raise Fail("rmdir of non-empty or mounted %s" % f[1])
                del names[f[1]]
            elif op == "rename" and len(f) == 3:
                a, b = f[1], f[2]
                src = need(a)
                if names.get(b) is src:
                    n += 1                                       # two names of one object: nothing to do (POSIX)
                    continue
                if dataset_of(a, mounts) != dataset_of(b, mounts):
                    raise Fail("rename %s -> %s crosses datasets (EXDEV)" % (a, b))
                if a in mounts or b in mounts:
                    raise Fail("rename of a mount point")
                if src.kind == "D" and (b + "/").startswith(a + "/"):
                    raise Fail("rename of %s into its own subtree" % a)
                need(parent(b), "D")
                if b in names:
                    dst = names[b]
                    if (dst.kind == "D") != (src.kind == "D"):
                        raise Fail("rename %s over %s: kind mismatch" % (a, b))
                    if dst.kind == "D" and children(b):
                        raise Fail("rename over non-empty directory %s" % b)
                    del names[b]
                moved = {p: v for p, v in names.items() if p == a or p.startswith(a + "/")}
                for p in moved:
                    del names[p]
                for p, v in moved.items():
                    names[b + p[len(a):]] = v
                if src.parent is not AMBIG:
                    src.parent = names[parent(b)]                # zfs_rename -> zfs_link_create: PARENT := new dir
            elif op == "link" and len(f) == 3:
                ino = need(f[1], "F")
                if dataset_of(f[1], mounts) != dataset_of(f[2], mounts):
                    raise Fail("link %s -> %s crosses datasets (EXDEV)" % (f[1], f[2]))
                fresh(f[2]); names[f[2]] = ino
                if ino.parent is not AMBIG:
                    ino.parent = names[parent(f[2])]             # zfs_link_create writes PARENT on every link
            elif op == "symlink" and len(f) >= 3:
                fresh(f[1]); names[f[1]] = Inode("L", target=line.split(" ", 2)[2]); names[f[1]].parent = names[parent(f[1])]
                names[f[1]].made = True
            else:
                raise Fail("unknown or malformed op")
        except Fail as e:
            raise Fail("%s:%d: %s — %s" % (ops_path, lineno, line, e))
        n += 1
    return n


def stat_lines(names, mounts):
    """(B7) "<path> <mode> <links> <size>" of every created object still there (--stat), at the first of its names."""
    out, seen = [], set()
    kids, subs = {}, {}
    for p, ino in names.items():
        if p != "/":
            kids[parent(p)] = kids.get(parent(p), 0) + 1
            if ino.kind == "D":
                subs[parent(p)] = subs.get(parent(p), 0) + 1
    for p in sorted(names, key=lambda x: x.encode("utf-8", "surrogateescape")):
        ino = names[p]
        if not ino.made or id(ino) in seen:
            continue
        seen.add(id(ino))
        if ino.kind == "F":
            live = sum(1 for v in names.values() if v is ino)
            size = len(ino.data) if ino.data is not None else ino.size
            out.append("%s 100644 %d %d" % (p, live, size))
        elif ino.kind == "D":
            out.append("%s 40755 %d %d" % (p, 2 + subs.get(p, 0) + sum(1 for m in mounts if parent(m) == p and m not in names),
                                           2 + kids.get(p, 0)))
        else:
            out.append("%s 120755 1 %d" % (p, len(ino.target.encode("utf-8", "surrogateescape"))))
    return "".join(x + "\n" for x in out)


def main(argv):
    if len(argv) >= 2 and argv[1] == "vectors":
        vectors(); return 0
    if len(argv) >= 2 and argv[1] == "gen":
        if len(argv) != 5:
            print("usage: zfs-expect.py gen SEED OFFSET LENGTH", file=sys.stderr); return 2
        sys.stdout.buffer.write(gen(argv[2], int(argv[3], 0), int(argv[4], 0))); return 0
    args, opts, i = [], {}, 1
    while i < len(argv):
        if argv[i] in ("-o", "--orig", "--objects", "--leakok", "--xattrs", "--xattrs-out", "--stat"):
            if i + 1 >= len(argv):
                print("zfs-expect: %s needs a value" % argv[i], file=sys.stderr); return 2
            opts[argv[i]] = argv[i + 1]; i += 2
        else:
            args.append(argv[i]); i += 1
    if not 1 <= len(args) <= 2:
        print("usage: zfs-expect.py MANIFEST [OPS] [-o OUT] [--orig DIR] [--objects FILE] [--leakok OUT] "
              "[--xattrs IN --xattrs-out OUT]", file=sys.stderr); return 2
    if ("--xattrs" in opts) != ("--xattrs-out" in opts):
        print("zfs-expect: --xattrs and --xattrs-out go together", file=sys.stderr); return 2
    try:
        names, mounts = parse_manifest(args[0])
        if "--objects" in opts:
            # hard links: one Inode per (dataset, object id)
            byobj = {}
            for raw in open(opts["--objects"], encoding="utf-8", errors="surrogateescape"):
                oid, p = raw.rstrip("\n").split(" ", 1)
                if p in names and names[p].kind == "F":
                    key = (dataset_of(p, mounts), oid)
                    if key in byobj:
                        names[p] = byobj[key]
                    else:
                        byobj[key] = names[p]
        set_parents(names)
        if "--xattrs" in opts:
            load_xattrs(names, opts["--xattrs"])
            if render_xattrs(names) != open(opts["--xattrs"], "rb").read().decode("utf-8", "surrogateescape"):
                raise Unusable("identity check: re-rendering %s does not reproduce it" % opts["--xattrs"])
        if k15_objects(names):
            raise Unusable("the fixture itself has stale-PARENT objects %s — the k.15 model's starting point is wrong"
                           % k15_objects(names)[:3])
        nops = apply_ops(names, mounts, args[1], opts.get("--orig")) if len(args) == 2 else 0
        text = render(names, mounts)
        if nops == 0:
            orig_text = open(args[0], "rb").read().decode("utf-8", "surrogateescape")
            if text != orig_text:
                raise Unusable("identity check: re-rendering %s with no ops does not reproduce it (sort order or a "
                               "line the parser does not round-trip)" % args[0])
        leaks = k15_objects(names)
        xtext = render_xattrs(names) if "--xattrs" in opts else None
    except Fail as e:
        print("zfs-expect: FAIL %s" % e, file=sys.stderr); return 1
    except (Unusable, OSError, ValueError) as e:
        print("zfs-expect: UNUSABLE %s" % e, file=sys.stderr); return 2
    data = text.encode("utf-8", "surrogateescape")
    if "-o" in opts:
        open(opts["-o"], "wb").write(data)
    else:
        sys.stdout.buffer.write(data)
    if "--leakok" in opts:
        open(opts["--leakok"], "wb").write("".join(p + "\n" for p in leaks).encode("utf-8", "surrogateescape"))
    if "--stat" in opts:
        open(opts["--stat"], "wb").write(stat_lines(names, mounts).encode("utf-8", "surrogateescape"))
    if xtext is not None:
        open(opts["--xattrs-out"], "wb").write(xtext.encode("utf-8", "surrogateescape"))
    print("zfs-expect: %d op(s) applied to %s -> %d lines, %d k.15 object(s)%s" % (nops, args[0], text.count("\n"),
          len(leaks), "" if xtext is None else ", %d xattr line(s)" % xtext.count("\n")), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
