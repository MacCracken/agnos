#!/usr/bin/env python3
# zfs-sa-check — the ZPL attributes a write or truncation STAMPS, held on the host (agnos 1.57.12 bite B5 review, finding
# 7(1); design docs/development/proposals/2026-10-09-zfs-write.md § a.1, § i.1): the manifest is size + SHA-256, so no
# oracle read MTIME, CTIME or FLAGS — a wrong SA offset or a missing ZFS_ARCHIVE | ZFS_AV_MODIFIED went unseen unless it
# damaged SIZE. Here, for every file a write / burst / trunc op of the serial log SUCCEEDED on, its dnode's SA bonus in
# the written image against the image the boot mounted:
#   · MTIME == CTIME == {ts0 + n, 0} — the op list's deterministic clock (core/zfs_write.cyr zfs_wf_now): ts0 = the
#     mounted uberblock's timestamp (read here off the start image), n = the number of the file's LAST such op in the
#     list (the ub-only commit is op 1; every `… begin` line — dataset cow, write, trunc, burst, null txg — one more)
#   · FLAGS == the start's | ZFS_ARCHIVE | ZFS_AV_MODIFIED (zfs_tstamp_update_setup, CONTENT_MODIFIED); ZFS_SPARSE is not
#     judged after a truncation to 0, which clears it only when the file shrank (zfs_trunc)
#   · SIZE == the expected manifest's
#   · MODE, GEN, UID, GID, PARENT, ATIME, CRTIME, LINKS unchanged — a write touches nothing else
# and every file only a dataset COW rewrote (B4: identical content) has its SA bonus byte-identical to the start's.
# ⭐ (B6) Every object a create / mkdir / symlink op of the log made, found in FINAL by its path (the expected manifest's
# mounts, each dataset's ROOT, the directory ZAPs), against what FreeBSD's zfs_mknode + zfs_link_create write
# (core/zfs_write.cyr's B6 section header):
#   · its dnode: type 19 (file, symlink) / 20 (directory), indirect shift 17, one blkptr, an SA bonus, checksum and
#     compress inherit, one slot, flags USERUSED | USEROBJUSED accounted (+ USED_BYTES once it has a block)
#   · its SA: the layout's attribute array by REGISTRY name == zfs_mknode's bulk order (MODE SIZE GEN UID GID PARENT
#     FLAGS ATIME MTIME CTIME CRTIME LINKS [PROJID] DACL_COUNT DACL_ACES [SYMLINK]), the bonus length its last
#     attribute's end; MODE 0100644 / 040755 / 0120755; SIZE the manifest's / 2 + the entries / the target's length; GEN
#     the txg of its create; UID 0; GID and PARENT its parent directory's; ATIME == CRTIME == the create's clock, MTIME ==
#     CTIME == the clock of the last op that changed it (a write; a directory's last new entry); LINKS 1 / 2 + its
#     subdirectories / 1; PROJID 0; the trivial ACL of its mode (3 ACEs) and the flags it implies; SYMLINK the target
#   · and against a FreeBSD TWIN in the START image — an object FreeBSD created in the same dataset with the same type and
#     mode, as it was created (only creation-time flags, no xattr since; a non-root one first): the same layout NUMBER,
#     attribute array, FLAGS, DACL_COUNT and DACL_ACES bytes
# and every PRE-EXISTING directory such an op added to: SIZE + the entries added, LINKS + the subdirectories, MTIME ==
# CTIME == the clock of its last new entry, FLAGS | ARCHIVE | AV_MODIFIED, every other SA byte unchanged.
# ⭐ (B7) One NAMESPACE MODEL carries all of it: the start image's paths (the objects list; hard links one object) and every
# successful op in order — a write stamps MTIME / CTIME and FLAGS; a create makes an object and stamps its parent; an
# unlink / rmdir drops a name (the parent's SIZE - 1, LINKS - 1 for a directory, its stamp; the object's LINKS - 1 and
# CTIME / FLAGS | ARCHIVE while names remain — zfs_link_destroy); a rename moves the name and its subtree (the target
# dropped first; the object's PARENT := the new directory, CTIME, FLAGS | ARCHIVE | AV_MODIFIED; both parents stamped);
# a link adds one (LINKS + 1, PARENT := its directory, CTIME, FLAGS | ARCHIVE). Then every object any op touched is held
# to it: a start object that is still there in EVERY SA attribute (what the model moved, and nothing else); a created one
# as above, its LINKS / SIZE / PARENT / MTIME / CTIME the model's (a later op may move them); an object whose last name
# went — FREED: its slot holds no dnode (unless a later create took the number: first fit), or LAZY (the kernel's where
# line says "on the DELETE_QUEUE"): LINKS 0 and "%x"(obj) -> obj in its dataset's DELETE_QUEUE (design § f.5, k.54) —
# unless (1.57.12 B10, k.63) a later DRAIN op freed it (`zfs-wtest: drain <path> object N: freed ...`): then FREED.
# The attributes are decoded through the image's own REGISTRY and LAYOUTS by name (class Sa — Python, not agnos's
# zfs_sa_find), so agreement is evidence. The expected ACL is OpenZFS's own
# acl_trivial_access_masks + zfs_acl_chmod's entry order (aces below), written from their C, NOT from agnos's
# zfs_wc_mask — which (B6 review, finding 1) this copy once repeated, formula and all, so it could not catch it.
# ⭐ (B6 review, finding 7(3)) The RING-3 form: the objects zfsx made through the syscalls (scripts/harness/
# zfs-ring3-test.py), where the clock is the PRODUCTION one (zfs_wf_now: ntp_now — the RTC seed + ticks) and no op list
# prints lines: the ops come from an op file (zfs-expect.py's syntax, every op ONE txg — the i-th at T0 + i), and every
# time an op stamped is held to the run's wall-clock window [LO, HI], whole seconds (nanoseconds 0), ONE value per op
# across everything it stamped (the object's four times, its parent's MTIME / CTIME), and non-decreasing in op order.
#
# usage: zfs-sa-check.py START FINAL MANIFEST OBJECTS LOG   (pool-only images; MANIFEST = the EXPECTED manifest, for
#        sizes and the M lines; OBJECTS = the fixture's <lane>.objects; LOG = the lane's serial log)
#        zfs-sa-check.py START FINAL MANIFEST OBJECTS --ops OPS --t0 T0 --clock LO HI   (the ring-3 form)
# Exit 0 every attribute right · 1 a wrong one (named) · 2 unusable input
import importlib.util, os, re, stat, struct, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
ARCHIVE, AVMOD, SPARSE = 0x800000000, 0x40000000000, 0x200000000000
TRIVIAL, AUTOI, NOEXD, PROJID = 0x4, 0x40, 0x100, 0x800000000000
BULK = ["MODE", "SIZE", "GEN", "UID", "GID", "PARENT", "FLAGS", "ATIME", "MTIME", "CTIME", "CRTIME", "LINKS"]
MODES = {"create": 0o100644, "mkdir": 0o40755, "symlink": 0o120755}
KEEP = ((0, 8), (16, 48), (56, 72), (104, 128))                  # MODE · GEN UID GID PARENT · ATIME · CRTIME LINKS


def load(name, rel):
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, rel))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def sa_of(dn):
    """(SA bytes, header size) of an SA znode's bonus, or None (not an SA bonus, or spill-held)."""
    if dn[4] != 44:
        return None
    blen = struct.unpack_from("<H", dn, 10)[0]
    if blen == 0:
        return None
    data = dn[64 + 128 * dn[3]:64 + 128 * dn[3] + blen]
    if struct.unpack_from("<I", data, 0)[0] != 0x2F505A:
        return None
    return data, ((struct.unpack_from("<H", data, 4)[0] >> 10) & 0x3F) * 8


NSOPS = ("unlink", "rmdir", "rename", "link")


def ops_of(log):
    """The op list's SUCCESSFUL ops from the serial log, in order: [(kind, path, path2, n, txg, z0, where)] — n the op's
    clock step (the ub-only commit is op 1; every `… begin` line, refused ops and null txgs included, one more), z0 a
    truncation to 0, where (B7) what the kernel said became of a removed object: (object, 'freed' | 'dq' | other)."""
    with open(log, "rb") as fh:
        lines = [re.sub(r"^\[[^]]*\] ", "", l.decode("utf-8", "replace").strip("\r\n")) for l in fh.read().split(b"\n")]
    n, pend, out = 1, None, []
    for l in lines:
        m = re.match(r"zfs-wtest: (dataset cow|write|trunc|burst|null txg|create|mkdir|symlink|unlink|rmdir|rename|link|drain) "
                     r"begin txg=(\d+)(?: (\S+))?(.*)$", l)
        if m:
            n += 1
            p2 = None
            if m.group(1) in ("rename", "link"):
                p2 = (m.group(4) or "").strip() or None
            pend = [m.group(1), m.group(3), p2, n, int(m.group(2)), re.search(r" len=0$", m.group(4) or "") is not None, None]
            continue
        m = re.match(r"zfs-wtest: (unlink|rmdir|rename|link) (\S+) object (\d+): (.*)$", l)
        if m and pend and pend[0] == m.group(1) and pend[1] == m.group(2):
            w = m.group(4)
            # a rename's line names the SOURCE object; its target, when it had one, as `(the target object <t> ...)`
            # (B7 review: a target the ops created has no start number, so a lazy one was unfindable without it)
            t = re.search(r"\(the target object (\d+) ", w)
            pend[6] = ((int(t.group(1)) if t else None) if m.group(1) == "rename" else int(m.group(3)),
                       "dq" if "DELETE_QUEUE" in w else "freed" if "freed" in w else "kept")
            continue
        # (1.57.12 B11 review) the race op (core/zfs_write.cyr zfs_wt_race): its write#1 of X has ANOTHER file written
        # in its gap (the yield hook) — during the same op, so on the same clock step
        m = re.match(r"zfs-wtest: b11 race (\S+): .*; (\S+): 4096 bytes written through fd Y in the gap .*: ok$", l)
        if m and pend and pend[0] == "write" and pend[1] == m.group(1):
            out.append(("write", m.group(2), None, pend[3], pend[4], False, None))
            continue
        m = re.match(r"zfs-wtest: (dataset cow|write|trunc|burst|create|mkdir|symlink|unlink|rmdir|rename|link) ok$", l)
        if m and pend and pend[0] == m.group(1):
            out.append(tuple(pend))
            pend = None
    return out


def drains_of(log):
    """(1.57.12 B10, k.63) The objects a DRAIN op freed: {(dataset root path, object)} from `zfs-wtest: drain <path>
    object N: freed ...` (the op list's zfs_wt_dq)."""
    out = set()
    with open(log, "rb") as fh:
        for raw in fh.read().split(b"\n"):
            l = re.sub(r"^\[[^]]*\] ", "", raw.decode("ascii", "replace").strip("\r"))
            m = re.match(r"zfs-wtest: drain (\S+) object (\d+): freed ", l)
            if m:
                out.add((m.group(1), int(m.group(2))))
    return out


def ops_from_list(path, t0):
    """ops_of's list from an op FILE (zfs-expect.py syntax) instead of a serial log: the ring-3 form. Every op is ONE txg
    (the i-th at t0 + i) and op i is clock step i + 1 (an order, not a time: --clock judges the times); a removed object is
    taken as freed (the ring-3 gate's files are small)."""
    n, txg, out = 1, t0, []
    with open(path) as fh:
        for l in fh:
            f = l.split()
            if not f or f[0].startswith("#"):
                continue
            n, txg = n + 1, txg + 1
            if f[0] in MODES or f[0] in ("write", "zero", "trunc", "unlink", "rmdir"):
                out.append(("write" if f[0] == "zero" else f[0], f[1], None, n, txg, f[0] == "trunc", None))
            elif f[0] in ("rename", "link"):
                out.append((f[0], f[1], f[2], n, txg, False, None))
            else:
                raise ValueError("op %r: the --ops form knows create / mkdir / symlink / write / zero / trunc / unlink / "
                                 "rmdir / rename / link" % f[0])
    return out


class Clock:
    """The time an op stamped: exactly ts0 + n (the op list's deterministic clock), or — --clock LO HI, the ring-3 form
    — inside the run's wall-clock window, whole seconds, one value per op, non-decreasing in op order (finish)."""

    def __init__(self, ts0, window):
        self.ts0, self.win, self.seen = ts0, window, {}

    def check(self, got, n, what, bad):
        if self.win is None:
            if got != (self.ts0 + n, 0):
                bad.append("%s %s, the clock says %s (ts0 %d + op %d)" % (what, got, (self.ts0 + n, 0), self.ts0, n))
            return
        lo, hi = self.win
        if got[1] != 0 or not lo <= got[0] <= hi:
            bad.append("%s %s, outside the run's wall-clock window [%d, %d] in whole seconds" % (what, got, lo, hi))
        self.seen.setdefault(n, {}).setdefault(got[0], what)

    def finish(self, fails):
        if self.win is None:
            return ""
        prev = None
        for n in sorted(self.seen):
            if len(self.seen[n]) > 1:
                fails.append("op %d stamped %d different times: %s" % (n, len(self.seen[n]), sorted(self.seen[n].items())))
            if prev is not None and min(self.seen[n]) < prev[1]:
                fails.append("op %d's time %d is before op %d's %d" % (n, min(self.seen[n]), prev[0], prev[1]))
            prev = (n, max(self.seen[n]))
        return "; clock: %d op time(s) in the wall-clock window [%d, %d], one per op, in op order" % (len(self.seen), *self.win)


# acl.h's access-mask bits and zfs_ace_hdr_t's who-flags, for the trivial ACL below
READ_DATA, WRITE_DATA, APPEND_DATA, EXECUTE = 0x1, 0x2, 0x4, 0x20
READ_NAMED_ATTRS, WRITE_NAMED_ATTRS, READ_ATTRIBUTES, WRITE_ATTRIBUTES = 0x8, 0x10, 0x80, 0x100
READ_ACL, WRITE_ACL, WRITE_OWNER, SYNCHRONIZE = 0x20000, 0x40000, 0x80000, 0x100000
ACE_OWNER, OWNING_GROUP, ACE_EVERYONE, ALLOW, DENY = 0x1000, 0x2000 | 0x40, 0x4000, 0, 1


def aces(mode):
    """The ACL zfs_acl_chmod builds for a new object of mode `mode` (FreeBSD zfs_acl.c:1323-1440, over an empty ACL):
    allow0 / deny1 / deny2 when non-zero, then owner@ / group@ / everyone@ ALLOW, each a zfs_ace_hdr_t {u16 type, u16
    flags, u32 mask} — the masks acl_trivial_access_masks computes (module/os/freebsd/spl/acl_common.c:1543-1600)."""
    rd, wr, ex = READ_DATA, WRITE_DATA | APPEND_DATA, EXECUTE
    cls = ((rd, 0o400, 0o040, 0o004), (wr, 0o200, 0o020, 0o002), (ex, 0o100, 0o010, 0o001))
    deny1 = deny2 = allow0 = 0
    for m, u, g, o in cls:
        if not mode & u and mode & (g | o):
            deny1 |= m
        if not mode & g and mode & o:
            deny2 |= m
        if mode & u and not mode & g and mode & o:
            allow0 |= m
    owner = WRITE_ATTRIBUTES | WRITE_OWNER | WRITE_ACL | WRITE_NAMED_ATTRS | READ_ACL | READ_ATTRIBUTES | \
        READ_NAMED_ATTRS | SYNCHRONIZE
    group = everyone = READ_ACL | READ_ATTRIBUTES | READ_NAMED_ATTRS | SYNCHRONIZE
    for m, u, g, o in cls:
        owner |= m if mode & u else 0
        group |= m if mode & g else 0
        everyone |= m if mode & o else 0
    ents = ([(ALLOW, ACE_OWNER, allow0)] if allow0 else []) + ([(DENY, ACE_OWNER, deny1)] if deny1 else []) + \
        ([(DENY, OWNING_GROUP, deny2)] if deny2 else []) + \
        [(ALLOW, ACE_OWNER, owner), (ALLOW, OWNING_GROUP, group), (ALLOW, ACE_EVERYONE, everyone)]
    return b"".join(struct.pack("<HHI", t, f, m) for t, f, m in ents)


class Sa:
    """An SA bonus decoded through its dataset's REGISTRY and LAYOUTS: attribute name -> bytes, in layout order."""

    def __init__(self, dn, reg, lays):
        self.ok = False
        if dn[4] != 44:
            return
        blen = struct.unpack_from("<H", dn, 10)[0]
        b = dn[64 + 128 * dn[3]:64 + 128 * dn[3] + blen]
        if blen < 8 or struct.unpack_from("<I", b, 0)[0] != 0x2F505A:
            return
        li = struct.unpack_from("<H", b, 4)[0]
        self.lay, self.hs, self.blen = li & 0x3FF, ((li >> 10) & 0x3F) * 8, blen
        arr = lays.get(self.lay)
        if arr is None:
            return
        self.names, self.attrs, off, vi = [], {}, self.hs, 0
        for a in arr:
            nm, ln = reg.get(a, ("?%d" % a, 8))
            if ln == 0:
                ln = struct.unpack_from("<H", b, 6 + 2 * vi)[0]
                vi += 1
            self.names.append(nm)
            self.attrs[nm] = bytes(b[off:off + ln])
            self.end = off + ln
            off = (off + ln + 7) & ~7
        self.ok = True

    def u64(self, nm):
        return struct.unpack_from("<Q", self.attrs[nm], 0)[0]

    def t(self, nm):
        return struct.unpack_from("<QQ", self.attrs[nm], 0)


class Ds:
    """One dataset of an image: its dnodes, REGISTRY, LAYOUTS, ROOT; path lookups through the directory ZAPs."""

    def __init__(self, img, z, osc):
        self.img, self.z = img, z
        self.dn = img.dnodes(osc)
        mz = self.zap(1)
        self.root = mz["ROOT"][1]
        sz = self.zap(mz["SA_ATTRS"][1])
        self.reg = {}
        for k, v in self.zap(sz["REGISTRY"][1]).items():
            val = v[1]
            self.reg[val & 0xFFFF] = (k.replace("ZPL_", ""), (val >> 24) & 0xFFFF)
        self.lays = {}
        for k, v in self.zap(sz["LAYOUTS"][1]).items():
            if not isinstance(v[1], int):
                self.lays[int(k)] = [int.from_bytes(v[1][i:i + 2], "big") for i in range(0, len(v[1]), 2)]

    def zap(self, obj):
        return self.img.p.zap(self.z.Node(None, None, self.dn[obj]), 0)

    def sa(self, obj):
        return Sa(self.dn[obj], self.reg, self.lays)

    def lookup(self, rel):
        """(object, parent object) of rel (components below the dataset's root), or (None, None)."""
        obj, par = self.root, None
        for c in [x for x in rel.split("/") if x]:
            ent = self.zap(obj).get(c)
            if ent is None:
                return None, None
            par, obj = obj, ent[1] & ((1 << 48) - 1)
        return obj, par


class Obj:
    """One object of the namespace model: a START object (ds, its number in the start image) or one the ops MADE."""

    def __init__(self, ds, start=None, made=None):
        self.ds, self.start, self.made = ds, start, made
        self.isdir = False
        self.mt = self.ct = None            # the clock step of its last MTIME / CTIME stamp (None: unchanged)
        self.fl = 0                         # FLAGS bits the ops added
        self.dl = 0                         # LINKS delta (a directory: its subdirectories' delta)
        self.ds_ = 0                        # a directory's entries delta (SIZE)
        self.par = None                     # the Obj its PARENT was set to (None: unchanged)
        self.written = self.z0 = False
        self.gone = None                    # (clock step, 'freed' | 'dq', its number or None)
        self.touched = False


def main(argv):
    ring3 = len(argv) == 12 and argv[5] == "--ops" and argv[7] == "--t0" and argv[9] == "--clock"
    files = argv[1:5] + ([argv[6]] if ring3 else argv[5:6])
    if not (len(argv) == 6 or ring3) or not all(os.path.isfile(a) for a in files):
        print("usage: zfs-sa-check.py START FINAL MANIFEST OBJECTS LOG\n"
              "       zfs-sa-check.py START FINAL MANIFEST OBJECTS --ops OPS --t0 T0 --clock LO HI")
        return 2
    hc = load("zfshole", "scripts/smoke/lib/zfs-hole-check.py")
    z = hc.load_lib()
    try:
        fin, sta = hc.Img(z, argv[2]), hc.Img(z, argv[1])
        ts0 = sta.p.ub[2]
        fh, sh = fin.heads(), sta.heads()
    except (z.ToolError, KeyError, ValueError, struct.error) as e:
        print("sa: unusable input: %s" % e)
        return 2
    mounts, sizes, targets = {}, {}, {}
    with open(argv[3]) as fh_:
        for l in fh_:
            f = l.split()
            if len(f) >= 3 and f[0] == "M":
                mounts[f[1]] = f[2]
            elif len(f) >= 4 and f[0] == "F":
                sizes[f[1]] = int(f[2])
            elif len(f) >= 3 and f[0] == "L":
                targets[f[1]] = l.rstrip("\n").split(" ", 2)[2]
    objs = {}
    with open(argv[4]) as fh_:
        for l in fh_:
            f = l.split(None, 1)
            if len(f) == 2:
                objs[f[1].strip()] = int(f[0])
    drained = set()
    try:
        if ring3:
            events = ops_from_list(argv[6], int(argv[8]))
            clock = Clock(ts0, (int(argv[10]), int(argv[11])))
        else:
            events = ops_of(argv[5])
            drained = drains_of(argv[5])
            clock = Clock(ts0, None)
    except ValueError as e:
        print("sa: unusable input: %s" % e)
        return 2
    fails = []
    st = ns_checks(z, fin, sta, fh, sh, clock, mounts, sizes, targets, objs, events, fails, drained)
    ck = clock.finish(fails)
    for f in fails[:20]:
        print("sa:   FAIL " + f)
    if len(fails) > 20:
        print("sa:   FAIL ... and %d more" % (len(fails) - 20))
    v = "PASS" if not fails else "FAIL"
    print("sa: %s — %d written file(s): MTIME == CTIME == the op's clock, FLAGS | ARCHIVE | AV_MODIFIED, SIZE, the rest "
          "unchanged; %d COW-only file(s) SA-identical (ts0 %d%s)" % (v, st["written"], st["cow"], ts0, ck))
    if st["made"] or st["ns"]:
        print("sa: %s — B6: %d created object(s) (dnode, layout, every SA value, ACL; %d held to a FreeBSD twin; %d in a "
              "NEW SA layout, B8), %d pre-existing parent(s) (SIZE, LINKS, MTIME, CTIME, FLAGS, the rest unchanged)"
              % (v, st["made"], st["twins"], st.get("newlays", 0), st["parents"]))
    if st["ns"]:
        print("sa: %s — B7: %d unlink / rmdir / rename / link op(s): %d object(s) freed (the slot zeroed, or its number "
              "reused by a create), %d on a DELETE_QUEUE (LINKS 0, the queue's entry), %d other object(s) relinked / moved "
              "(LINKS, PARENT, CTIME, FLAGS, the rest unchanged)" % (v, st["ns"], st["freed"], st["dq"], st["moved"]))
    return 0 if not fails else 1


def ns_checks(z, fin, sta, fh, sh, clock, mounts, sizes, targets, objs, events, fails, drained=frozenset()):
    """Every object the ops touched — written, COW'd, created, linked, renamed, unlinked — against the namespace model
    the ops imply (the header's ⭐ B6 / B7 paragraphs). Returns the counts for the summary lines."""
    dsc = {}
    st = {"written": 0, "cow": 0, "made": 0, "twins": 0, "parents": 0, "ns": 0, "freed": 0, "dq": 0, "moved": 0}

    def DS(img, heads, tag, name):
        if (tag, name) not in dsc:
            o = img.objset(heads[name]) if name in heads else None
            try:
                dsc[(tag, name)] = Ds(img, z, o) if o is not None else None
            except KeyError:
                dsc[(tag, name)] = None                        # no SA registry: a ZPL < 5 dataset, never written
        return dsc[(tag, name)]

    def ds_of(path):
        mp = max((m for m in mounts if path == m or path.startswith(m.rstrip("/") + "/")), key=len, default=None)
        return (None, None) if mp is None else (mounts[mp], path[len(mp.rstrip("/")):])

    def parent(path):
        return path.rsplit("/", 1)[0] or "/"

    # the start namespace: every path of the objects list, hard links one Obj
    cur, byid = {}, {}
    for path, oid in objs.items():
        name, _rel = ds_of(path)
        if name is None:
            continue
        key = (name, oid)
        if key not in byid:
            byid[key] = Obj(name, start=oid)
            S = DS(sta, sh, "s", name)
            byid[key].isdir = S is not None and oid in S.dn and S.dn[oid][0] == 20
        cur[path] = byid[key]
    made = []
    sta_links = {}

    def start_links(o):
        if o.start is None:
            return 2 if o.isdir else 1
        if (o.ds, o.start) not in sta_links:
            S = DS(sta, sh, "s", o.ds)
            sa = S.sa(o.start) if S is not None and o.start in S.dn else None
            sta_links[(o.ds, o.start)] = sa.u64("LINKS") if sa is not None and sa.ok else 1
        return sta_links[(o.ds, o.start)]

    def stamp_dir(d, delta, sub, n):
        d.ds_ += delta
        d.dl += sub
        d.mt = d.ct = n
        d.fl |= ARCHIVE | AVMOD
        d.touched = True

    def lose(o, n, where):
        """o loses a name (link_destroy): links left -> CTIME, ARCHIVE; the last -> gone."""
        if o.isdir:
            o.gone = (n, where[1] if where else "freed", where[0] if where else None)
            return
        o.dl -= 1
        if start_links(o) + o.dl > 0:
            o.ct = n
            o.fl |= ARCHIVE
        else:
            o.gone = (n, where[1] if where and where[1] in ("freed", "dq") else "freed", where[0] if where else None)

    for kind, a, b, n, txg, z0, where in events:
        if kind == "dataset cow":
            if a in cur:
                cur[a].touched = True
                cur[a].cowed = True
            continue
        if kind in ("write", "trunc", "burst"):
            o = cur.get(a)
            if o is None:
                fails.append("%s: written, but not in the namespace model" % a)
                continue
            o.touched = o.written = True
            o.mt = o.ct = n
            o.fl |= ARCHIVE | AVMOD
            o.z0 = o.z0 or (kind == "trunc" and z0)
            continue
        if kind in MODES:
            name, _rel = ds_of(a)
            o = Obj(name, made=(kind, n, txg))
            o.isdir = kind == "mkdir"
            o.mt = o.ct = n
            o.touched = True
            o.par = cur.get(parent(a))
            cur[a] = o
            made.append((a, o))
            if o.par is not None:
                stamp_dir(o.par, 1, 1 if o.isdir else 0, n)
            continue
        st["ns"] += 1
        if kind in ("unlink", "rmdir"):
            o = cur.pop(a, None)
            d = cur.get(parent(a))
            if o is None or d is None:
                fails.append("%s %s: the name is not in the namespace model" % (kind, a))
                continue
            o.touched = True
            stamp_dir(d, -1, -1 if o.isdir else 0, n)
            lose(o, n, where)
        elif kind == "rename":
            src = cur.get(a)
            if src is None or b is None or parent(b) not in cur:
                fails.append("rename %s %s: not in the namespace model" % (a, b))
                continue
            if cur.get(b) is src:
                continue                                       # two names of one object: nothing changed
            if b in cur:
                tgt = cur.pop(b)
                tgt.touched = True
                stamp_dir(cur[parent(b)], -1, -1 if tgt.isdir else 0, n)
                lose(tgt, n, where)
            tp, sp = cur[parent(b)], cur[parent(a)]
            stamp_dir(tp, 1, 1 if src.isdir else 0, n)
            src.par, src.ct, src.touched = tp, n, True
            src.fl |= ARCHIVE | AVMOD
            stamp_dir(sp, -1, -1 if src.isdir else 0, n)
            for q in [q for q in cur if q == a or q.startswith(a + "/")]:
                cur[b + q[len(a):]] = cur.pop(q)
        elif kind == "link":
            o = cur.get(a)
            if o is None or b is None or parent(b) not in cur:
                fails.append("link %s %s: not in the namespace model" % (a, b))
                continue
            o.dl += 1
            o.par, o.ct, o.touched = cur[parent(b)], n, True
            o.fl |= ARCHIVE
            stamp_dir(cur[parent(b)], 1, 0, n)
            cur[b] = o
    # where every live Obj sits now, and its number in the written image
    paths = {}
    for q, o in cur.items():
        paths.setdefault(id(o), []).append(q)

    def final_num(o):
        if o.start is not None:
            return o.start
        ps = paths.get(id(o))
        if not ps:
            return None
        name, rel = ds_of(sorted(ps)[0])
        F = DS(fin, fh, "f", name)
        return F.lookup(rel)[0] if F is not None else None

    # (B10, k.63) an object queued by a lazy unlink and then freed by a later DRAIN op of its dataset is FREED from here
    # on — before the slots are mapped (a drained object no longer keeps its slot)
    for o in list(byid.values()) + [o for (_q, o) in made]:
        if o.gone is not None and o.gone[1] == "dq":
            qn = o.start if o.start is not None else o.gone[2]
            if qn is not None and any(ds_of(dp)[0] == o.ds and dn_ == qn for (dp, dn_) in drained):
                o.gone = (o.gone[0], "freed", o.gone[2])
    reused = {}
    for q, o in made:
        if o.gone is None:
            fn = final_num(o)
            if fn is not None:
                reused[(o.ds, fn)] = q
        elif o.gone[1] == "dq" and o.gone[2] is not None:
            reused[(o.ds, o.gone[2])] = q                      # (B7 review) a LAZY one keeps the slot it took
    allobj = list(byid.values()) + [o for (_q, o) in made]
    for o in allobj:
        if not o.touched:
            continue
        F, S = DS(fin, fh, "f", o.ds), DS(sta, sh, "s", o.ds)
        label = "%s object %s" % (o.ds, o.start if o.start is not None else "(made %s)" % (o.made,))
        if F is None or S is None:
            fails.append("%s: no dataset %s" % (label, o.ds))
            continue
        if o.gone is not None and o.gone[1] == "freed":
            num = o.start if o.start is not None else o.gone[2]
            st["freed"] += 1
            if num is None:
                continue
            if (o.ds, num) in reused:
                continue                                       # a later create took the number (first fit)
            if num in F.dn:
                fails.append("%s: removed at op %d (freed), but its slot %d still holds a dnode of type %d"
                             % (label, o.gone[0], num, F.dn[num][0]))
            continue
        num = final_num(o) if o.gone is None else (o.start if o.start is not None else o.gone[2])
        if num is None or num not in F.dn:
            fails.append("%s: not found in the written image (object %s)" % (label, num))
            continue
        fs = F.sa(num)
        if not fs.ok:
            fails.append("%s: its SA bonus does not decode (spill-held?)" % label)
            continue
        if o.gone is not None:                                 # the lazy path: LINKS 0 and on the DELETE_QUEUE
            st["dq"] += 1
            bad = []
            if fs.u64("LINKS") != 0:
                bad.append("LINKS %d (the lazy unlink leaves 0)" % fs.u64("LINKS"))
            try:
                dq = F.zap(1)["DELETE_QUEUE"][1]
                ent = F.zap(dq).get("%x" % num)
                if ent is None or ent[1] != num:
                    bad.append("not on its dataset's DELETE_QUEUE (object %d, key %x)" % (dq, num))
            except (KeyError, z.ToolError) as e:
                bad.append("DELETE_QUEUE unreadable: %s" % e)
            if bad:
                fails.append("%s (object %d): %s" % (label, num, "; ".join(bad)))
            continue
        if o.made is not None:
            made_check(z, F, S, num, o, paths, cur, final_num, clock, sizes, targets, start_links, fails, st, parent,
                       lambda: [(nm, DS(sta, sh, "s", nm)) for nm in sorted(sh)])
            continue
        # a start object that is still there: every attribute the model says moved, and nothing else
        ss = S.sa(o.start)
        if not ss.ok or ss.names != fs.names or ss.lay != fs.lay:
            fails.append("%s: its SA layout changed (or does not decode)" % label)
            continue
        if o.written:
            st["written"] += 1
        elif getattr(o, "cowed", False) and not (o.par or o.ct or o.mt or o.dl or o.ds_):
            st["cow"] += 1
        elif o.isdir:
            st["parents"] += 1
        else:
            st["moved"] += 1
        bad = []
        want = {}
        if o.isdir:
            want["SIZE"] = ss.u64("SIZE") + o.ds_
            want["LINKS"] = ss.u64("LINKS") + o.dl
        else:
            want["LINKS"] = ss.u64("LINKS") + o.dl
            if o.written:
                ps = paths.get(id(o), [])
                want["SIZE"] = sizes.get(sorted(ps)[0]) if ps else ss.u64("SIZE")
        mask = ~SPARSE if o.z0 else ~0
        if o.par is not None:
            want["PARENT"] = final_num(o.par)
        for a2, w in want.items():
            if fs.u64(a2) != w:
                bad.append("%s %s, expected %s" % (a2, fs.u64(a2), w))
        wfl = ss.u64("FLAGS") | o.fl
        if (fs.u64("FLAGS") & mask) != (wfl & mask):
            bad.append("FLAGS %#x, expected %#x (the start's %#x | %#x)" % (fs.u64("FLAGS"), wfl, ss.u64("FLAGS"), o.fl))
        for a2, nn in (("MTIME", o.mt), ("CTIME", o.ct)):
            if nn is None:
                if fs.attrs[a2] != ss.attrs[a2]:
                    bad.append("%s changed, no op stamped it" % a2)
            else:
                clock.check(fs.t(a2), nn, "%s %s" % (label, a2), bad)
        for a2 in fs.names:
            if a2 not in want and a2 not in ("FLAGS", "MTIME", "CTIME") and fs.attrs[a2] != ss.attrs[a2]:
                bad.append("%s changed" % a2)
        if bad:
            fails.append("%s %s: %s" % (label, sorted(paths.get(id(o), ["(gone)"]))[0], "; ".join(bad)))
    return st


def made_check(z, F, S, num, o, paths, cur, final_num, clock, sizes, targets, start_links, fails, st, parent, alls):
    """A created object still there (the header's ⭐ B6): its dnode, its SA in zfs_mknode's order and values — with the
    namespace model's LINKS / SIZE / PARENT / MTIME / CTIME, which later ops (B7) may have moved — and a FreeBSD twin."""
    kind, n, txg = o.made
    path = sorted(paths.get(id(o), ["?"]))[0]
    st["made"] += 1
    dn = F.dn[num]
    want_ty = 20 if kind == "mkdir" else 19
    bad = []
    # (B8) a directory's nlevels is what its ZAP's blocks need: 1 for a microzap, more once it is fat (one block pointer,
    # 128 KiB indirects of 1,024 BPs — dnode_new_blkid's growth); a symlink has no block beyond its bonus
    maxblk = struct.unpack_from("<Q", dn, 16)[0]
    need, cap = 1, 1
    while cap < maxblk + 1:
        need, cap = need + 1, cap * 1024
    if kind != "create" and (dn[0], dn[1], dn[2], dn[3], dn[4], dn[5], dn[6], dn[12]) != (want_ty, 17, need, 1, 44, 0, 0, 0):
        bad.append("dnode type/ibs/nlevels/nblkptr/bonustype/checksum/compress/extra %s (nlevels %d for dn_maxblkid %d)" %
                   (tuple(dn[i] for i in (0, 1, 2, 3, 4, 5, 6, 12)), need, maxblk))
    if kind == "create" and (dn[0], dn[1], dn[3], dn[4], dn[5], dn[6], dn[12]) != (19, 17, 1, 44, 0, 0, 0):
        bad.append("dnode type/ibs/nblkptr/bonustype/checksum/compress/extra %s" % (tuple(dn[i] for i in (0, 1, 3, 4, 5, 6, 12)),))
    if (dn[7] & 0xA) != 0xA or (dn[7] & ~0xB) != 0:
        bad.append("dn_flags %#x (USERUSED | USEROBJUSED accounted, + USED_BYTES only)" % dn[7])
    sa = F.sa(num)
    proj = kind != "symlink" and "PROJID" in sa.names
    names = BULK + (["PROJID"] if proj else []) + ["DACL_COUNT", "DACL_ACES"] + (["SYMLINK"] if kind == "symlink" else [])
    if sa.names != names:
        fails.append("%s (object %d): layout %d is %s, zfs_mknode's order is %s" % (path, num, sa.lay, sa.names, names))
        return
    if sa.blen != sa.end:
        bad.append("bonus length %d, the last attribute ends at %d" % (sa.blen, sa.end))
    mode = MODES[kind]
    par = final_num(o.par) if o.par is not None else None
    psa = F.sa(par) if par is not None and par in F.dn else None
    if kind == "create":
        size = sizes.get(path)
    elif kind == "mkdir":
        size = 2 + len(F.zap(num))
    else:
        size = len(targets.get(path, "").encode())
    fl = ARCHIVE | AVMOD | TRIVIAL | (AUTOI if kind == "mkdir" else 0) | (NOEXD if mode & 0o111 == 0o111 else 0)
    fl |= PROJID if proj else 0
    acl = aces(mode & 0o7777)
    want = {"MODE": mode, "SIZE": size, "GEN": txg, "UID": 0, "GID": psa.u64("GID") if psa is not None and psa.ok else None,
            "PARENT": par, "FLAGS": fl | o.fl, "LINKS": (2 if kind == "mkdir" else 1) + o.dl, "DACL_COUNT": len(acl) // 8}
    if kind == "mkdir":
        want["SIZE"] = 2 + o.ds_
    if proj:
        want["PROJID"] = 0
    for a, w in want.items():
        if sa.u64(a) != w:
            bad.append("%s %#x, expected %s" % (a, sa.u64(a), "%#x" % w if isinstance(w, int) else w))
    for a, w in (("ATIME", n), ("CRTIME", n), ("MTIME", o.mt), ("CTIME", o.ct)):
        clock.check(sa.t(a), w, "%s %s" % (path, a), bad)
    if sa.attrs["DACL_ACES"] != acl:
        bad.append("DACL_ACES %s, zfs_acl_chmod's ACL of %o is %s" % (sa.attrs["DACL_ACES"].hex(), mode & 0o7777, acl.hex()))
    if kind == "symlink" and sa.attrs["SYMLINK"] != targets.get(path, "").encode():
        bad.append("SYMLINK %r, the manifest says %r" % (sa.attrs["SYMLINK"], targets.get(path)))
    # (B8) a NEW SA layout — sa_add_layout_entry's registration in the open txg (core/zfs_write.cyr zfs_wc_layout): the
    # numbers the written image's LAYOUTS holds beyond the start's are exactly count + 2, count + 3, ... (avl_numnodes:
    # the start's entries + the two built-in ZPL layouts), each a distinct array no start layout already had (else
    # sa_find_layout would have reused it) — and this object's is one of them
    newlay = sa.lay not in S.lays
    if newlay:
        st["newlays"] = st.get("newlays", 0) + 1
        extra = sorted(set(F.lays) - set(S.lays))
        if extra != list(range(len(S.lays) + 2, len(S.lays) + 2 + len(extra))):
            bad.append("new SA layout(s) %s, sa_add_layout_entry numbers them from %d (the start's %d + 2)" % (extra, len(S.lays) + 2, len(S.lays)))
        arrs = [tuple(F.lays[k]) for k in extra] + [tuple(v) for v in S.lays.values()]
        if len(set(arrs)) != len(arrs):
            bad.append("a new SA layout repeats an attribute array the dataset already had (sa_find_layout reuses it)")
        if set(S.lays) - set(F.lays) or any(F.lays[k] != S.lays[k] for k in S.lays if k in F.lays):
            bad.append("a start SA layout changed or went")
    # the FreeBSD twin: same type and mode in the START image's same dataset, non-root first, never sparse — (B8) else in
    # another dataset of the pool (a new layout's object has none in its own, by construction: the layout NUMBER is then
    # not compared — numbers are per dataset — the attribute array by name, FLAGS and the ACL are)
    def find_twin(Sd):
        tw = None
        for ob in sorted(Sd.dn):
            if Sd.dn[ob][0] != want_ty:
                continue
            ts = Sd.sa(ob)
            # what FreeBSD wrote AT CREATION: no xattr since (DXATTR, a spill; XATTR, an xattr directory — B7 review), no
            # chflags (only creation-time bits)
            if not ts.ok or ts.u64("MODE") != mode or "DXATTR" in ts.names or "XATTR" in ts.names or Sd.dn[ob][7] & 4 or \
                    ts.u64("FLAGS") & ~(ARCHIVE | AVMOD | TRIVIAL | AUTOI | NOEXD | PROJID | 0x400000000000):
                continue
            if tw is None or (tw[1] and ts.u64("PARENT") != ob):
                tw = (ob, ts.u64("PARENT") == ob)
        return tw
    twin, TS, tds = find_twin(S), S, o.ds
    if twin is None:
        for nm, Sd in alls():
            if Sd is None or nm == o.ds:
                continue
            twin = find_twin(Sd)
            if twin is not None:
                TS, tds = Sd, nm
                break
    if twin is None:
        bad.append("no FreeBSD twin (type %d, mode %o) in %s or any dataset of the pool to compare with" % (want_ty, mode, o.ds))
    else:
        st["twins"] += 1
        ts = TS.sa(twin[0])
        checks = [("FLAGS", sa.u64("FLAGS"), ts.u64("FLAGS")),
                  ("DACL_COUNT", sa.u64("DACL_COUNT"), ts.u64("DACL_COUNT")),
                  ("DACL_ACES", sa.attrs["DACL_ACES"], ts.attrs["DACL_ACES"]),
                  ("attributes", sa.names[:-1] if kind == "symlink" else sa.names,
                   ts.names[:-1] if kind == "symlink" else ts.names)]
        if tds == o.ds and not newlay:
            checks.insert(0, ("layout", sa.lay, ts.lay))
        for a, x, y in checks:
            if x != y:
                bad.append("%s %s, FreeBSD's twin (%s object %d) %s" % (a, x if not isinstance(x, bytes) else x.hex(), tds, twin[0], y if not isinstance(y, bytes) else y.hex()))
    if bad:
        fails.append("%s (object %d): %s" % (path, num, "; ".join(bad)))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
