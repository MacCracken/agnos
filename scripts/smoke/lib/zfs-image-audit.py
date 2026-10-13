#!/usr/bin/env python3
# zfs-image-audit — the HOST half of the ZFS write oracle (agnos 1.57.12; design
# docs/development/proposals/2026-10-09-zfs-write.md § i.2): compare a pool image after agnos ran against the
# pristine fixture image it started from, and prove the writer touched ONLY what a txg commit may touch. Seconds,
# no guest. The guest verify (scripts/tool/zfs-fixture.sh --verify) proves the result is a VALID pool; this proves
# HOW it got there — a pool OpenZFS accepts can still have had its labels rewritten or its boot region scribbled on.
#
#   h1  every label's [0, 128 KiB) (pad, boot env, nvlist) byte-identical in all four labels — labels are never written
#   h2  [512 KiB, 4 MiB) (the boot region) identical, and the slack after the last metaslab up to label 2 identical
#   h3  in the four 128 KiB uberblock rings, every slot that differs is a NEW uberblock: native magic, a valid embedded
#       SHA-256 (verifier = the slot's vdev offset), txg > the pristine best txg, sitting in slot txg % N, the same
#       216-byte uberblock_t in all four labels (only the eck differs — its verifier is per-offset), zero from byte
#       216 to the eck, and the fields agnos copies or zeroes as the design § d.4 says (version, guid_sum,
#       raidz_reflow_info copied; software_version 5000, mmp_magic 0xa11cea11, mmp_delay/config 0, checkpoint 0), and
#       a ub_timestamp never below the pristine best's and never decreasing in txg order (design § d.4's
#       max(clock, previous); WPA § 2.1 — the selection tie-break and the rewind report read it; B2 review: a writer
#       that wrote 0 or a backwards timestamp passed every other check); with --same-rootbp, which commits wrote a
#       new MOS (below)
#   h4  --identical: the pool is byte-identical to the pristine image (refused and read-only lanes: G1, "a
#       read-only mount writes not one byte")
#   h5  --offset/--before: MODIFIED is a whole-disk image holding the pool at --offset; every byte outside the pool's
#       partition equals --before (the same disk image as it was before the boot)
#   h6  --space (1.57.12 B3b; a pool-only MODIFIED): the pool's space record replays on the host in OpenZFS's own model
#       (scripts/smoke/lib/zfs-wms-check.py --replay): every space map and log strict, smp_alloc == the entries,
#       spacemap_histogram's refcount == space maps + logs, every nonzero U[i] naming a log, and NO log entry for a
#       metaslab whose U is 0 — a rule zdb and every import phase let through on FreeBSD 15.1 (B3b negative N3): its
#       NULL store at a writable import is build-dependent (another build may ASSERT or fault there), and its damage
#       (a metaslab never flushed, its log-only changes lost) only shows imports later; and (B7, design k.68) no
#       metaslab's space map histogram claiming more than the replayed space holds — the segment weight
#       metaslab_load_impl ASSERTs on every load (metaslab.c:2670), which OpenZFS never breaks and a writer that
#       allocates without rewriting the histogram does
#   h7  --space too (1.57.12 B4): scripts/smoke/lib/zfs-uacct-check.py — every dnode's dn_used == Σ dsize of its tree
#       (design § k.14), every head dataset's referenced == Σ dn_used + its objset block, the user / group /
#       project-used ZAPs == a recount over every dnode (design § e.3), every snapshot-free dsl_dir's compressed /
#       uncompressed == its head's + its child dirs', and (B4 review) every dsl_dir's breakdown (Σ == used, CHILD /
#       CHILD_RSRV from the child dirs, REFRSRV == max(0, refreservation - ds_unique_bytes), HEAD == referenced) and
#       every head's ds_unique_bytes against its blocks. zdb checks none of them; validated on every pristine fixture
#       image (they hold exactly on what OpenZFS wrote)
#   h8  --space too (1.57.12 B5): scripts/smoke/lib/zfs-hole-check.py — with hole_birth active, every hole of an object
#       the writer changed that replaced a block (or a punched hole) of the pristine image carries a birth, <= the
#       pool's txg, with its dnode's type and its level (design § k.12: zdb checks a hole's birth nowhere, and an
#       incremental send skips a birth-0 hole)
#   h9  --space too (1.57.12 B8): scripts/smoke/lib/zfs-fatzap-check.py — every ZAP of the pool (each dataset's and the
#       MOS's) held to the fat-ZAP structure rules: the pointer table's coverage (each leaf exactly the range of its
#       prefix, zap_num_leafs), a mid-doubling table's written entries, every leaf's free list / counts / hash chains /
#       arrays, the hashes recomputed from the names, zap_num_entries == Σ lh_nentries, microzap (hash, cd) uniqueness,
#       every salt non-zero, and an upgraded microzap's salt kept (against PRISTINE)
# 216 is sizeof (uberblock_t) in OpenZFS 2.4.2 include/sys/uberblock_impl.h: five u64 (magic, version, txg,
# guid_sum, timestamp) + the 128-byte blkptr_t + six u64 (software_version, mmp_magic, mmp_delay, mmp_config,
# checkpoint_txg, raidz_reflow_info) = 40 + 128 + 48. The slot is 1 << MIN(MAX(ashift, 10), 13) bytes
# (VDEV_UBERBLOCK_SHIFT) with the 40-byte zio_eck_t at its end (zec_magic 0x0210da7ab10c7a11 + 4 checksum words).
#
# usage: zfs-image-audit.py PRISTINE MODIFIED [--identical] [--offset BYTES [--before DISK]] [--min-txgs N] [--final-txg T]
#        [--same-rootbp T] [--cut-labels K] [--space]
#   PRISTINE   the fixture's whole-disk pool image (scripts/tool/zfs-fixture.sh)
#   MODIFIED   the pool image after the run (same size), or with --offset a whole-disk image holding it
#   --min-txgs N   h3 also requires at least N new uberblock txgs — min(N, the ring's slots): a ring keeps only its last
#              slots-many (a writer lane that committed nothing is a FAIL, not a vacuous PASS); default 0
#   --final-txg T  h3 also requires the rings to END at txg T: T == the pristine best → no new uberblock at all; T above
#              it → the newest new txg is T and every txg of the writer's last min(T - pristine, slots) commits has its
#              slot (agnos writes an uberblock for every txg it commits, design § d). ⛔ Without it a writer whose final
#              uberblock write was lost — the pool consistent at T-1 — passes h3 and the guest's A1/A2 alike
#              (zfs-fixture.sh --verify passes the lane's <lane>.txg here; B0 review).
#   --same-rootbp T  h3 also requires every new uberblock of txg <= T to name the pristine best's ub_rootbp, byte for
#              byte, and every one above T a NEW MOS: a rootbp whose logical birth is that uberblock's own txg and that
#              differs from the one the previous new txg named (pristine's for the first) — a writer whose commits up to
#              T were uberblock-only (1.57.12 B2) and whose later ones each wrote a new MOS (B3b's null txgs;
#              scripts/smoke/zfs-write-smoke.sh). ⚠ The guest would accept a later uberblock that re-published an older
#              rootbp (design § k.1: OpenZFS writes such uberblocks itself), so this is the only oracle of "every null
#              txg advanced the MOS" (B3b review: h3 compared each with the PRISTINE rootbp only)
#   --cut-labels K  (1.57.12 B11, zfs-write-smoke's crash-cut lanes) the final txg's uberblock reached only labels
#              0 .. K-1 before the machine stopped (zfs_cut=ub:K — the commit's slot writes go L0, L1, L2, L3): h3 then
#              requires that slot NEW in exactly those K labels, byte-identical there, and UNCHANGED in the others (every
#              other new slot still in all four) — the torn state vdev_uberblock_load resolves to the best txg of ANY
#              label (vdev_label.c:1495-1527), whose blocks the commit's first flush made durable
# Prints `audit: <check> PASS|FAIL|SKIP <why>` per check and `audit: PASS|FAIL ...` last.
# Exit 0 PASS · 1 FAIL · 2 the inputs are unusable (missing, wrong size, PRISTINE not a ZFS label).
import hashlib, os, struct, sys

LABEL = 256 * 1024
RING = 128 * 1024
UB_MAGIC = 0x00bab10c
ZEC_MAGIC = 0x0210da7ab10c7a11
UB_LEN = 216
CHUNK = 1 << 20


def nvpairs(b, off):
    off += 8
    out = {}
    while True:
        esize, dsize = struct.unpack_from(">ii", b, off)
        if esize == 0 and dsize == 0:
            return out
        p = off + 8
        nlen = struct.unpack_from(">I", b, p)[0]; p += 4
        name = b[p:p + nlen].decode(); p += (nlen + 3) & ~3
        dtype, nelem = struct.unpack_from(">ii", b, p); p += 8
        if dtype == 8:
            out[name] = struct.unpack_from(">Q", b, p)[0]
        elif dtype == 9:
            slen = struct.unpack_from(">I", b, p)[0]
            out[name] = b[p + 4:p + 4 + slen].decode()
        elif dtype == 19:
            out[name] = nvpairs(b, p)
        off += esize


def sha256_words(b):
    d = hashlib.sha256(b).digest()
    return [int.from_bytes(d[i:i + 8], "big") for i in range(0, 32, 8)]


def eck_ok(slot, voff):
    e = len(slot) - 40
    if struct.unpack_from("<Q", slot, e)[0] != ZEC_MAGIC:
        return False
    want = list(struct.unpack_from("<4Q", slot, e + 8))
    tmp = bytearray(slot)
    struct.pack_into("<4Q", tmp, e + 8, voff, 0, 0, 0)
    return sha256_words(bytes(tmp)) == want


class Img:
    def __init__(self, path, base=0, length=None):
        self.f = open(path, "rb")
        self.base = base
        self.length = length if length is not None else os.path.getsize(path) - base

    def read(self, off, n):
        self.f.seek(self.base + off)
        b = self.f.read(n)
        if len(b) != n:
            raise IOError("short read at %#x" % (self.base + off))
        return b


def first_diff(a, b, off, n):
    """First differing byte offset in [off, off+n) or None."""
    pos = off
    while pos < off + n:
        k = min(CHUNK, off + n - pos)
        x, y = a.read(pos, k), b.read(pos, k)
        if x != y:
            for i in range(k):
                if x[i] != y[i]:
                    return pos + i
        pos += k
    return None


def raw_first_diff(fa, fb, off, n):
    pos = off
    while pos < off + n:
        k = min(CHUNK, off + n - pos)
        fa.seek(pos); fb.seek(pos)
        x, y = fa.read(k), fb.read(k)
        if x != y:
            for i in range(min(len(x), len(y))):
                if x[i] != y[i]:
                    return pos + i
            return pos + min(len(x), len(y))
        pos += k
    return None


def main(argv):
    args, opts, i = [], {}, 1
    while i < len(argv):
        a = argv[i]
        if a == "--identical":
            opts["identical"] = True
        elif a == "--space":
            opts["space"] = True
        elif a in ("--offset", "--before", "--min-txgs", "--final-txg", "--same-rootbp", "--cut-labels"):
            if i + 1 >= len(argv):
                print("audit: %s needs a value" % a); return 2
            opts[a[2:]] = argv[i + 1]; i += 1
        elif a.startswith("--"):
            print("audit: unknown option %s" % a); return 2
        else:
            args.append(a)
        i += 1
    if len(args) != 2:
        print("usage: zfs-image-audit.py PRISTINE MODIFIED [--identical] [--offset BYTES [--before DISK]] [--min-txgs N] [--final-txg T] [--same-rootbp T] [--cut-labels K] [--space]")
        return 2
    pristine, modified = args
    for p in (pristine, modified):
        if not os.path.isfile(p):
            print("audit: %s is not a file" % p); return 2
    plen = os.path.getsize(pristine)
    off = int(opts.get("offset", "0"), 0)
    mlen = os.path.getsize(modified)
    if off == 0 and "before" not in opts and mlen != plen:
        print("audit: MODIFIED is %d bytes, PRISTINE %d — a bare pool image must be the same size (or pass --offset)" % (mlen, plen))
        return 2
    if off + plen > mlen:
        print("audit: the pool [%#x, %#x) does not fit in MODIFIED (%d bytes)" % (off, off + plen, mlen)); return 2
    P, M = Img(pristine), Img(modified, off, plen)
    size = plen // LABEL * LABEL
    lab0 = P.read(0, LABEL)
    if lab0[16384:16388] != b"\x01\x01\x00\x00":
        print("audit: PRISTINE has no XDR nvlist in label 0 — not a ZFS whole-disk image"); return 2
    vt = nvpairs(lab0, 16388).get("vdev_tree", {})
    ashift = vt.get("ashift", 9)
    ms_end = 4 * 1024 * 1024 + ((vt.get("asize", 0) >> vt.get("metaslab_shift", 63)) << vt.get("metaslab_shift", 0)) \
        if vt.get("metaslab_shift") else None
    bases = (0, LABEL, size - 2 * LABEL, size - LABEL)
    slot = 1 << min(max(ashift, 10), 13)
    nslots = RING // slot

    fails, lines = 0, []

    def report(check, ok, why):
        nonlocal fails
        tag = "PASS" if ok is True else ("SKIP" if ok is None else "FAIL")
        if ok is False:
            fails += 1
        lines.append("audit: %s %s %s" % (check, tag, why))
        print(lines[-1], flush=True)

    # ---- h4: whole pool identical (refused / read-only lanes) ----
    if opts.get("identical"):
        d = first_diff(P, M, 0, plen)
        report("h4", d is None, "pool image byte-identical to the pristine fixture (%d bytes)" % plen if d is None
               else "pool image differs from the pristine fixture first at byte %#x" % d)

    # ---- h1: label fronts ----
    bad = []
    for l, b in enumerate(bases):
        d = first_diff(P, M, b, RING)
        if d is not None:
            bad.append("L%d first at %#x" % (l, d))
    report("h1", not bad, "label [0, 128K) identical in all 4 labels" if not bad else "label front changed: " + ", ".join(bad))

    # ---- h2: boot region + post-metaslab slack ----
    d = first_diff(P, M, 2 * LABEL, 4 * 1024 * 1024 - 2 * LABEL)
    why = "boot region [512K, 4M) identical" if d is None else "boot region changed first at %#x" % d
    ok = d is None
    if ms_end is not None and ms_end < size - 2 * LABEL:
        d2 = first_diff(P, M, ms_end, size - 2 * LABEL - ms_end)
        why += "; slack [%#x, %#x) after the last metaslab %s" % (ms_end, size - 2 * LABEL,
                                                                  "identical" if d2 is None else "changed first at %#x" % d2)
        ok = ok and d2 is None
    report("h2", ok, why)

    # ---- h3: uberblock rings ----
    pbest = None                                       # pristine best (txg, timestamp, ub bytes)
    for b in bases:
        for s in range(nslots):
            o = b + RING + s * slot
            sb = P.read(o, slot)
            if struct.unpack_from("<Q", sb, 0)[0] == UB_MAGIC and eck_ok(sb, o):
                t = struct.unpack_from("<QQQQQ", sb, 0)
                if pbest is None or (t[2], t[4]) > (pbest[0], pbest[1]):
                    pbest = (t[2], t[4], sb[:UB_LEN])
    if pbest is None:
        print("audit: PRISTINE has no valid uberblock"); return 2
    p_txg = pbest[0]
    p_ver, p_guidsum = struct.unpack_from("<QQ", pbest[2], 8)[0], struct.unpack_from("<Q", pbest[2], 24)[0]
    p_reflow = struct.unpack_from("<Q", pbest[2], 208)[0]
    p_ts = pbest[1]
    problems, new_txgs, new_ts, new_rbp = [], set(), {}, {}
    per_slot = {}                                      # slot index -> {label: ub bytes}
    for l, b in enumerate(bases):
        for s in range(nslots):
            o = b + RING + s * slot
            ps, ms = P.read(o, slot), M.read(o, slot)
            if ps == ms:
                continue
            where = "L%d slot %d (@%#x)" % (l, s, o)
            magic = struct.unpack_from("<Q", ms, 0)[0]
            if magic != UB_MAGIC:
                problems.append("%s changed but carries magic %#x" % (where, magic)); continue
            if not eck_ok(ms, o):
                problems.append("%s: embedded SHA-256 does not verify (verifier %#x)" % (where, o)); continue
            txg = struct.unpack_from("<Q", ms, 16)[0]
            if txg <= p_txg:
                problems.append("%s: txg %d is not newer than the pristine best %d" % (where, txg, p_txg))
            if txg % nslots != s:
                problems.append("%s: txg %d belongs in slot %d" % (where, txg, txg % nslots))
            if any(ms[UB_LEN:slot - 40]):
                problems.append("%s: non-zero bytes between %d and the eck" % (where, UB_LEN))
            ver, _t, guidsum = struct.unpack_from("<QQQ", ms, 8)
            sw, mmpm, mmpd, mmpc, ckpt, reflow = struct.unpack_from("<6Q", ms, 168)
            for name, got, want in (("ub_version", ver, p_ver), ("ub_guid_sum", guidsum, p_guidsum),
                                    ("ub_software_version", sw, 5000), ("ub_mmp_magic", mmpm, 0xa11cea11),
                                    ("ub_mmp_delay", mmpd, 0), ("ub_mmp_config", mmpc, 0),
                                    ("ub_checkpoint_txg", ckpt, 0), ("ub_raidz_reflow_info", reflow, p_reflow)):
                if got != want:
                    problems.append("%s: %s = %#x, want %#x" % (where, name, got, want))
            if "same-rootbp" in opts:
                same = ms[40:168] == pbest[2][40:168]
                if txg <= int(opts["same-rootbp"], 0) and not same:
                    problems.append("%s: txg %d's ub_rootbp differs from the pristine best's (--same-rootbp %s: "
                                    "uberblock-only commits up to it)" % (where, txg, opts["same-rootbp"]))
                elif txg > int(opts["same-rootbp"], 0) and same:
                    problems.append("%s: txg %d names the pristine best's ub_rootbp (--same-rootbp %s: every later "
                                    "commit writes a new MOS)" % (where, txg, opts["same-rootbp"]))
            if txg > p_txg:
                new_txgs.add(txg)
                new_ts[txg] = struct.unpack_from("<Q", ms, 32)[0]
                new_rbp[txg] = ms[40:168]
            per_slot.setdefault(s, {})[l] = ms[:slot - 40]
    cut_slot, cut_k = -1, 4
    if "cut-labels" in opts:
        cut_k = int(opts["cut-labels"], 0)
        if "final-txg" not in opts or not 1 <= cut_k <= 3:
            problems.append("--cut-labels %d needs --final-txg and 1 <= K <= 3" % cut_k)
        else:
            cut_slot = int(opts["final-txg"], 0) % nslots
    for s, labs in sorted(per_slot.items()):
        if s == cut_slot:
            if sorted(labs) != list(range(cut_k)):
                problems.append("slot %d (the cut txg's) changed in label(s) %s — --cut-labels %d wants exactly L0..L%d"
                                % (s, ",".join(map(str, sorted(labs))), cut_k, cut_k - 1))
            elif len(set(labs.values())) != 1:
                problems.append("slot %d differs between the labels that hold it (beyond the per-offset eck)" % s)
        elif len(labs) != 4:
            problems.append("slot %d changed in label(s) %s only — a committed uberblock is written to all four"
                            % (s, ",".join(map(str, sorted(labs)))))
        elif len(set(labs.values())) != 1:
            problems.append("slot %d differs between the four labels (beyond the per-offset eck)" % s)
    if cut_slot >= 0 and cut_slot not in per_slot:
        problems.append("--cut-labels %d: the cut txg's slot %d is new in no label" % (cut_k, cut_slot))
    last = None
    for t in sorted(new_ts):
        if new_ts[t] < p_ts:
            problems.append("txg %d: ub_timestamp %d is below the pristine best's %d" % (t, new_ts[t], p_ts))
        if last is not None and new_ts[t] < last[1]:
            problems.append("txg %d: ub_timestamp %d is below txg %d's %d (the clock went backwards)"
                            % (t, new_ts[t], last[0], last[1]))
        last = (t, new_ts[t])
    if "same-rootbp" in opts:
        # every commit above T wrote a NEW MOS: born in its own txg (blk_birth_word[1], the logical birth — BP word 10,
        # include/sys/spa.h:494) and not the rootbp the commit before it published
        T, prev, prevt = int(opts["same-rootbp"], 0), pbest[2][40:168], p_txg
        for t in sorted(new_rbp):
            if t > T:
                birth = struct.unpack_from("<Q", new_rbp[t], 80)[0]
                if birth != t:
                    problems.append("txg %d: its ub_rootbp has logical birth %d — a commit above --same-rootbp %d writes "
                                    "its own MOS objset" % (t, birth, T))
                if new_rbp[t] == prev:
                    problems.append("txg %d re-publishes txg %d's ub_rootbp (the MOS did not advance)" % (t, prevt))
            prev, prevt = new_rbp[t], t
    # (1.57.12 merge, design k.107) a ring holds nslots uberblocks: a lane that committed more than that shows only its
    # last nslots — so at least min(N, nslots) new txgs (--final-txg then holds every one of those slots to its txg)
    need = min(int(opts.get("min-txgs", "0")), nslots)
    if len(new_txgs) < need:
        problems.append("only %d new uberblock txg(s), the lane must have committed at least %d" % (len(new_txgs), need))
    if "final-txg" in opts:
        T = int(opts["final-txg"], 0)
        if T < p_txg:
            problems.append("the lane's final txg %d is below the pristine best %d" % (T, p_txg))
        elif T == p_txg:
            if new_txgs:
                problems.append("the lane names no commit (final txg %d == the pristine best) but the rings hold new "
                                "txg(s) %s" % (T, ",".join(map(str, sorted(new_txgs)[:8]))))
        else:
            top = max(new_txgs) if new_txgs else None
            if top != T:
                problems.append("the newest new uberblock is txg %s, the lane's final txg is %d (a lost final uberblock "
                                "write leaves the pool at T-1)" % (top, T))
            miss = sorted(set(range(max(p_txg, T - nslots) + 1, T + 1)) - new_txgs)
            if miss:
                problems.append("txg(s) %s of the writer's last %d commit(s) have no uberblock in their slot"
                                % (",".join(map(str, miss[:8])), min(T - p_txg, nslots)))
    if problems:
        for p in problems[:12]:
            print("audit:   h3 " + p)
        if len(problems) > 12:
            print("audit:   h3 ... and %d more" % (len(problems) - 12))
    rng = ("new txgs %d..%d (%d)" % (min(new_txgs), max(new_txgs), len(new_txgs))) if new_txgs else "no new txgs"
    report("h3", not problems, "uberblock rings: pristine best txg %d, %d-byte slots x %d; %s%s"
           % (p_txg, slot, nslots, rng, "" if not problems else "; %d problem(s)" % len(problems)))

    # ---- h5: outside the partition ----
    if "before" in opts:
        before = opts["before"]
        if not os.path.isfile(before) or os.path.getsize(before) != mlen:
            print("audit: --before %s is missing or not %d bytes" % (before, mlen)); return 2
        with open(before, "rb") as fb, open(modified, "rb") as fm:
            d = raw_first_diff(fb, fm, 0, off)
            if d is None:
                d = raw_first_diff(fb, fm, off + plen, mlen - off - plen)
        report("h5", d is None, "disk outside the pool partition [%#x, %#x) unchanged" % (off, off + plen) if d is None
               else "disk changed OUTSIDE the pool partition, first at byte %#x" % d)
    elif off:
        report("h5", None, "no --before image given; bytes outside the partition not compared")

    # ---- h6: the space record, replayed on the host ----
    if opts.get("space"):
        if off:
            report("h6", False, "--space needs a pool-only image (MODIFIED at offset 0)")
        else:
            import importlib.util
            lib = os.path.join(os.path.dirname(os.path.abspath(__file__)), "zfs-wms-check.py")
            spec = importlib.util.spec_from_file_location("zfswms", lib)
            w = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(w)
            z = w.load_lib()
            try:
                out = w.replay(z, modified)
                report("h6", True, "space record replays in OpenZFS's model: %s" % out[-1][len("zfs-wpool: "):])
            except (ValueError, KeyError, z.ToolError) as e:
                report("h6", False, "space record inconsistent: %s" % e)
            # ---- h7 (1.57.12 B4): what no zfs tool checks, recounted from every dnode (zfs-uacct-check.py) ----
            lib7 = os.path.join(os.path.dirname(os.path.abspath(__file__)), "zfs-uacct-check.py")
            spec7 = importlib.util.spec_from_file_location("zfsuacct", lib7)
            u = importlib.util.module_from_spec(spec7)
            spec7.loader.exec_module(u)
            import io, contextlib
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc7 = u.main(["zfs-uacct-check.py", modified])
            last = [l for l in buf.getvalue().splitlines() if l.startswith("uacct: ")]
            bad7 = [l.strip()[len("uacct:"):].strip() for l in buf.getvalue().splitlines() if "FAIL" in l]
            if rc7 == 0:
                report("h7", True, "dn_used / referenced / user-group-project accounting recounted: %s" % (last[-1][len("uacct: PASS — "):] if last else "?"))
            else:
                report("h7", False, "accounting recount: %s" % ("; ".join(bad7[:3]) or (last[-1] if last else "no output")))
            # ---- h8 (1.57.12 B5): hole births against the pristine image (zfs-hole-check.py, design § k.12) ----
            lib8 = os.path.join(os.path.dirname(os.path.abspath(__file__)), "zfs-hole-check.py")
            spec8 = importlib.util.spec_from_file_location("zfsholes", lib8)
            hc = importlib.util.module_from_spec(spec8)
            spec8.loader.exec_module(hc)
            buf8 = io.StringIO()
            with contextlib.redirect_stdout(buf8):
                rc8 = hc.main(["zfs-hole-check.py", modified, pristine])
            last8 = [l for l in buf8.getvalue().splitlines() if l.startswith("holes: ")]
            bad8 = [l.strip()[len("holes:"):].strip() for l in buf8.getvalue().splitlines() if "FAIL" in l]
            if rc8 == 0:
                report("h8", True, "hole births: %s" % (last8[-1][len("holes: "):] if last8 else "?"))
            else:
                report("h8", False, "hole births: %s" % ("; ".join(bad8[:3]) or (last8[-1] if last8 else "no output")))
            # ---- h9 (1.57.12 B8): every ZAP's fat-ZAP structure (zfs-fatzap-check.py, design § f.2) ----
            lib9 = os.path.join(os.path.dirname(os.path.abspath(__file__)), "zfs-fatzap-check.py")
            spec9 = importlib.util.spec_from_file_location("zfsfatzap", lib9)
            fz = importlib.util.module_from_spec(spec9)
            spec9.loader.exec_module(fz)
            buf9 = io.StringIO()
            with contextlib.redirect_stdout(buf9):
                rc9 = fz.main(["zfs-fatzap-check.py", modified, pristine])
            last9 = [l for l in buf9.getvalue().splitlines() if l.startswith("fatzap: ")]
            bad9 = [l.strip()[len("fatzap:"):].strip() for l in buf9.getvalue().splitlines() if "FAIL" in l]
            if rc9 == 0:
                report("h9", True, "ZAP structure: %s" % (last9[-1][len("fatzap: PASS — "):] if last9 else "?"))
            else:
                report("h9", False, "ZAP structure: %s" % ("; ".join(bad9[:3]) or (last9[-1] if last9 else "no output")))

    print("audit: %s — %s vs %s%s" % ("PASS" if fails == 0 else "FAIL (%d check(s))" % fails, modified, pristine,
                                       " @%#x" % off if off else ""))
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (IOError, OSError, struct.error) as e:
        print("audit: unusable input: %s" % e)
        sys.exit(2)
