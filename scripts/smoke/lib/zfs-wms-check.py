#!/usr/bin/env python3
# zfs-wms-check — the host half of the ZFS write gate's state-load check (agnos 1.57.12 bite B1; design
# docs/development/proposals/2026-10-09-zfs-write.md § h B1: "per-metaslab allocated bytes printed == zdb -mmm").
# The fixture summaries carry no `zdb -mmm`, and a fixture rebuild is a FreeBSD guest boot — so the oracle is an
# INDEPENDENT replay of the pool image here, in OpenZFS's own model, diffed line for line against the kernel's
# ZFS_WRITE_SELFTEST dump (core/zfs_write.cyr zfs_wd_log / zfs_wd_ms / zfs_wd_pool):
#   * a metaslab space map is loaded as a FREE set (space_map_load: ALLOC removes, FREE adds — both strict), and its
#     smp_alloc must equal the entries' net (zdb's "INCONSISTENT");
#   * the logs are replayed in txg order REMOVE-XOR-ADD into per-metaslab unflushed allocs / frees, skipping a log
#     whose txg < U[ms] (spa_ld_log_sm_cb, spa_log_spacemap.c:1092-1130); metaslab_load then takes the allocs out of
#     the free set (each must be free) and puts the frees back (each must be allocated);
#   * deferred = FREE units in a log with txg >= T0 - 2 ((1.57.12 B10, design k.108) an SM append is never deferred by
#     itself: a destroyed log's FREEs stay deferred through its ghost, in memory — on an image every log is >= T0 - 2's
#     own window or gone with the boot);
#   * (1.57.12 B10, design § c.5) the LOG HYGIENE rules OpenZFS keeps and a flushing writer can break: every entry of a
#     metaslab's space map under a debug word is of that word's type (space_map_write_intro_debug + the tree it writes,
#     space_map.c:515-760 — an ALLOC written as a FREE shows); no debug txg of a metaslab's space map passes its U when U
#     != 0 (metaslab_flush appends at txg F and sets U = F, metaslab_flush_update -> metaslab_unflushed_bump: an append
#     past U is replayed AGAIN from the logs >= U — the import's "overlapping"); and no log is older than every U != 0
#     (spa_cleanup_old_sm_logs, spa_log_spacemap.c:911-940, destroys it in the txg the last U passes it);
#   * (1.57.12 B3b) the import's two rules about U[]: every nonzero U[i] names a log that exists
#     (spa_ld_log_sm_metadata, spa_log_spacemap.c:1042-1066 — else ENOENT), and no log holds an entry for a metaslab
#     whose U is 0 (spa_ld_log_sm_cb -> spa_log_summary_dirty_flushed_metaslab(spa, 0), spa_log_spacemap.c:1123-1127
#     -> :611-622: no summary row starts at or below txg 0, so the row is NULL and `target->lse_msdcount++` stores
#     through it — undefined behaviour whose outcome is the BUILD's: a debug or INVARIANTS build ASSERTs, a build that
#     keeps the store page-faults (a crash at import), and FreeBSD 15.1's production kernel survived it. Only a
#     WRITABLE import runs it: zdb loads read-only and spa_ld_log_sm_data returns before the replay, :1139-1142. The
#     damage that stays either way: such a metaslab is not in spa_metaslabs_by_flushed, so it is never flushed and its
#     log-only changes are LOST when those logs are destroyed). zdb and every import phase of the guest PASSED a pool
#     written that way (B3b's negative N3), so this host replay is that rule's oracle;
#   * spacemap_histogram's refcount == SMs with a 320-byte bonus (metaslabs, the leaf's DTL) + every log (zdb's
#     verify_spacemap_refcounts, zdb.c:1541-1567);
#   * (1.57.12 B7, design k.68) every metaslab's space map HISTOGRAM claims no more than the replayed space holds: the
#     segment weight read from smp_histogram — its highest nonzero bucket (sm_shift = the vdev's ashift), then that
#     bucket's count (metaslab_weight_from_spacemap) — is never above the weight of the metaslab's free segments after
#     the replay (metaslab_weight_from_range_tree). metaslab_load_impl ASSERTs exactly that on every load
#     (metaslab.c:2670) — a debug build's import panics, and zdb -mmmm after an export aborts (B7: the wr lane's
#     C-zdbm). OpenZFS cannot break it (it allocates only in a loaded metaslab and rewrites a loaded one's histogram at
#     every sync); a writer that allocates from its own bitmaps and leaves the histogram can. A metaslab completely
#     free or full is weighed without its histogram (metaslab_segment_weight), so it is skipped.
# The kernel's model is the OPPOSITE one (strict set/clear bitmaps, the logs applied in file order), so agreement is
# evidence, not an echo. The pool reader is the B0 image tool's (scripts/tool/zfs-damage.py, read-only use;
# ZFS_POOL_LIB overrides the path).
#
# usage: zfs-wms-check.py IMG LOG   (IMG: the fixture's whole-disk pool image · LOG: the lane's serial log)
#        zfs-wms-check.py --replay IMG   (the replay alone, on any pool image — a WRITER's result: zfs-write-smoke's
#                                        `space` check, zfs-image-audit.py --space's h6)
# Exit 0 identical / consistent · 1 the dump differs, is missing, or the host replay finds the pool inconsistent ·
# 2 unusable input
import importlib.util, os, struct, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


def load_lib():
    path = os.environ.get("ZFS_POOL_LIB") or os.path.join(ROOT, "scripts", "tool", "zfs-damage.py")
    if not os.path.isfile(path):
        print("wms-check: the pool reader %s is missing (it lands with bite B0)" % path)
        sys.exit(2)
    spec = importlib.util.spec_from_file_location("zfsdamage", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def entries(data, length, blksz):
    """(type, raw offset, raw run, txg of the last debug entry) over a space map's first `length` bytes."""
    txg, off = 0, 0
    while off < length:
        e = struct.unpack_from("<Q", data, off)[0]
        bo = off % blksz
        off += 8
        if e >> 62 == 2:
            if e & ((1 << 50) - 1):
                txg = e & ((1 << 50) - 1)
            continue
        if e >> 63 == 0:
            yield (e >> 15) & 1, (e >> 16) & ((1 << 47) - 1), (e & 0x7FFF) + 1, txg
            continue
        if bo + 8 >= blksz or off >= length:
            raise ValueError("two-word entry straddles a block at byte %d" % (off - 8))
        e2 = struct.unpack_from("<Q", data, off)[0]
        off += 8
        yield e2 >> 63, e2 & ((1 << 63) - 1), ((e >> 24) & ((1 << 36) - 1)) + 1, txg


def sm_form(data, length, blksz):
    """(1.57.12 B10) The highest debug txg of a space map, after checking every entry under a debug word (txg != 0) is
    of that word's type (ALLOC 0 / FREE 1) — space_map_write's form. Raises ValueError."""
    act, txg, hi, off = None, 0, 0, 0
    while off < length:
        e = struct.unpack_from("<Q", data, off)[0]
        bo = off % blksz
        off += 8
        if e >> 62 == 2:
            if e & ((1 << 50) - 1):
                txg = e & ((1 << 50) - 1)
                act = (e >> 60) & 3
                hi = max(hi, txg)
            continue
        if e >> 63 == 0:
            ty = (e >> 15) & 1
        else:
            if bo + 8 >= blksz or off >= length:
                raise ValueError("two-word entry straddles a block at byte %d" % (off - 8))
            ty = struct.unpack_from("<Q", data, off)[0] >> 63
            off += 8
        if act is not None and ty != act:
            raise ValueError("an %s entry under a debug word of type %s (txg %d)" % ("ALLOC" if ty == 0 else "FREE",
                                                                                  "ALLOC" if act == 0 else "FREE", txg))
    return hi


def sm_obj(p, mos, obj):
    h, o = p.dnode(mos, obj)
    b, blen = p.bonus(h, o)
    _o, length, alloc = struct.unpack_from("<QQq", h.content, b)
    blksz = struct.unpack_from("<H", h.content, o + 8)[0] * 512
    return p.object_data(h, o), length, alloc, blksz, blen


def seg_weight(units_free, ash):
    """(highest bucket, its count) of a free-unit set's segments: bucket highbit(run) - 1 in units of 1 << ash, the
    last bucket (31) counting longer runs scaled (space_map_histogram_add)."""
    cnt, run, prev = {}, 0, None
    for u in sorted(units_free):
        if prev is not None and u == prev + 1:
            run += 1
        else:
            if run:
                x = run.bit_length() - 1
                k, c = (31, 1 << (x - 31)) if x > 31 else (x, 1)
                cnt[k] = cnt.get(k, 0) + c
            run = 1
        prev = u
    if run:
        x = run.bit_length() - 1
        k, c = (31, 1 << (x - 31)) if x > 31 else (x, 1)
        cnt[k] = cnt.get(k, 0) + c
    if not cnt:
        return (-1, 0)
    top = max(cnt)
    return (top, cnt[top])


def replay(z, path):
    p = z.Pool(path)
    mos = p.mos()
    sms, U, logs, _tz = p.space_info(mos)
    T0, ash, msh = p.txg, p.ashift, p.ms_shift
    units = 1 << (msh - ash)
    mosdir = p.zap(*p.dnode(mos, 1))
    h, o = p.dnode(mos, mosdir["config"][1])
    cfg = p.object_data(h, o)[:struct.unpack_from("<Q", h.content, p.bonus(h, o)[0])[0]]
    top = z.nvlist(cfg, 4)[0]["vdev_tree"]["children"][0]
    feat = {}
    for key in ("features_for_read", "features_for_write"):
        if key in mosdir:
            feat.update({k: v[1] for k, v in p.zap(*p.dnode(mos, mosdir[key][1])).items()})
    n320 = len(logs) + sum(1 for so in ([top.get("DTL")] + sms) if so and sm_obj(p, mos, so)[4] == 320)
    if feat.get("com.delphix:spacemap_histogram") != n320:
        raise ValueError("spacemap_histogram refcount %s != space maps %d" % (feat.get("com.delphix:spacemap_histogram"), n320))
    for i, u in enumerate(U):
        if u and u not in logs:
            raise ValueError("ms %d: unflushed txg %d names no log space map (the import's ENOENT)" % (i, u))
    minu = min((u for u in U if u), default=0)
    for t in sorted(logs):
        if minu and t < minu:
            raise ValueError("log txg %d is older than every metaslab's unflushed txg (the least is %d): "
                             "spa_cleanup_old_sm_logs destroys it in the txg the last U passes it" % (t, minu))
    free, smalloc, deferred = [], [], [set() for _ in sms]
    for i, so in enumerate(sms):
        f, sa = set(range(units)), 0
        if so:
            data, length, sa, blksz, _bl = sm_obj(p, mos, so)
            try:
                hi = sm_form(data, length, blksz)
            except ValueError as e:
                raise ValueError("ms %d: its space map: %s" % (i, e))
            if U[i] and hi > U[i]:
                raise ValueError("ms %d: its space map holds a debug txg %d past its unflushed txg %d — a flush that did "
                                 "not move U: the logs from U on replay on top of it (the import's overlapping)"
                                 % (i, hi, U[i]))
            net = 0
            for ty, raw, run, txg in entries(data, length, blksz):
                rng = range(raw, raw + run)
                if raw + run > units:
                    raise ValueError("ms %d: an SM entry past the metaslab" % i)
                if ty == 0:
                    if not f.issuperset(rng):
                        raise ValueError("ms %d: SM ALLOC of allocated space" % i)
                    f.difference_update(rng)
                    net += run << ash
                else:
                    if not f.isdisjoint(rng):
                        raise ValueError("ms %d: SM FREE of free space" % i)
                    f.update(rng)
                    net -= run << ash
            if net != sa:
                raise ValueError("ms %d: smp_alloc %d != net %d" % (i, sa, net))
        free.append(f)
        smalloc.append(sa)
    ua, uf, hits = [set() for _ in sms], [set() for _ in sms], [0] * len(sms)
    out = []
    for txg in sorted(logs):
        data, length, la, blksz, _bl = sm_obj(p, mos, logs[txg])
        n = a = fr = 0
        for ty, raw, run, _t in entries(data, length, blksz):
            by, nb = raw << 9, run << 9
            ms = by >> msh
            rng = range((by - (ms << msh)) >> ash, (by - (ms << msh) + nb) >> ash)
            n += 1
            if ty == 0:
                a += nb
            else:
                fr += nb
                if txg >= T0 - 2:
                    deferred[ms].update(rng)
            if U[ms] == 0:
                raise ValueError("log txg %d holds an entry for ms %d, whose unflushed txg is 0 (a metaslab the log "
                                 "summary has no row for: never flushed, its log-only changes lost)" % (txg, ms))
            if txg < U[ms]:
                continue
            hits[ms] += 1
            mine, other = (ua[ms], uf[ms]) if ty == 0 else (uf[ms], ua[ms])
            for u in rng:
                if u in other:
                    other.discard(u)
                elif u in mine:
                    raise ValueError("log txg %d: overlapping %s in ms %d" % (txg, "ALLOC" if ty == 0 else "FREE", ms))
                else:
                    mine.add(u)
        if la != a - fr:
            raise ValueError("log txg %d: smp_alloc %d != net %d" % (txg, la, a - fr))
        out.append("zfs-wlog: txg=%d obj=%d entries=%d alloc=%d free=%d" % (txg, logs[txg], n, a, fr))
    tot = [0, 0, 0]
    for i in range(len(sms)):
        f = free[i]
        if not f.issuperset(ua[i]) or not f.isdisjoint(uf[i]):
            raise ValueError("ms %d: an unflushed entry contradicts the space map" % i)
        fin = (f - ua[i]) | uf[i]
        al = (units - len(fin)) << ash
        if sms[i] and 0 < len(fin) < units:
            h, o = p.dnode(mos, sms[i])
            b, blen = p.bonus(h, o)
            if blen >= 320:
                hist = struct.unpack_from("<32Q", h.content, b + 64)
                top = max((k for k in range(32) if hist[k]), default=-1)
                hw = (top, hist[top]) if top >= 0 else (-1, 0)
                tw = seg_weight(fin, ash)
                if hw > tw:
                    raise ValueError("ms %d: its space map histogram claims more than the space holds — bucket %d count %d "
                                     "above the replayed segments' bucket %d count %d (metaslab_load_impl's ASSERT, "
                                     "metaslab.c:2670, on a debug build; design k.68)"
                                     % (i, hw[0] + ash, hw[1], tw[0] + ash, tw[1]))
        tot[0] += smalloc[i]
        tot[1] += al
        tot[2] += len(deferred[i]) << ash
        out.append("zfs-wms: %d sm=%d alloc=%d U=%d" % (i, sms[i], al, U[i]))
    finals = [(free[i] - ua[i]) | uf[i] for i in range(len(sms))]
    owned_allocated(z, p, mos, mosdir, finals, msh, ash)
    bm = units >> 3
    out.append("zfs-wpool: metaslabs=%d unflushed_ms=%d logs=%d sm_alloc=%d unflushed=%d allocated=%d deferred=%d "
               "bitmap=%d resident=%d smh=%d" % (len(sms), sum(1 for h in hits if h), len(logs), tot[0],
                                                 tot[1] - tot[0], tot[1], tot[2], bm,
                                                 min(len(sms), (1 << 20) // (2 * bm)), n320))
    return out


def owned_allocated(z, p, mos, mosdir, fin, msh, ash):
    """(1.57.12 B9, design § e.2 branch B) what a SNAPSHOT still owns stays allocated after the replay: every DVA of
    every block of every snapshot's objset (its tree walked like zdb's traverse_dataset from the snapshot's own
    ds_prev_snap_txg — what is older is the previous snapshot's, walked there), and of every BP a deadlist or free_bpobj
    holds (a gang DVA by its header's unit). A writer that FREED a block a snapshot owns instead of deadlisting it — or
    deadlisted one it then freed too — leaves it free here. Raises ValueError on the first one."""
    ms_count = len(fin)

    def chk(bp, what):
        if bp.hole or bp.embedded:
            return
        for (v, off, asz, gang) in bp.dvas:
            ms = off >> msh
            if v != 0 or ms >= ms_count:
                raise ValueError("%s: DVA <%d:%x:%x> outside the vdev's metaslabs" % (what, v, off, asz))
            u0 = (off - (ms << msh)) >> ash
            n = 1 if gang else max(1, asz >> ash)
            for u in range(u0, u0 + n):
                if u in fin[ms]:
                    raise ValueError("%s: a block a snapshot still owns is FREE in ms %d (DVA <%d:%x:%x>, birth %d)"
                                     % (what, ms, v, off, asz, bp.gbirth))

    def ds(obj):
        h, o = p.dnode(mos, obj)
        b, _ = p.bonus(h, o)
        return struct.unpack_from("<16Q", h.content, b), z.BP(h.content[b + 128:b + 256])

    def bpobj(obj, what):
        h, o = p.dnode(mos, obj)
        b, blen = p.bonus(h, o)
        num = struct.unpack_from("<Q", h.content, b)[0]
        data = p.object_data(h, o) if num else b""
        for i in range(num):
            chk(z.BP(data[i * 128:i * 128 + 128]), "%s entry %d" % (what, i))

    def tree(osbp, mintxg, what):
        if osbp.hole or osbp.gbirth <= mintxg:      # BP_GET_BIRTH, as traverse's get_birth_time (B9 review)
            return
        chk(osbp, what + " objset")
        osc = p.node(osbp, None).content
        dnodes = [(bytes(osc[0:512]), True)]
        for off in (1024, 1536, 2048):
            if off + 512 <= osbp.lsize and osc[off] != 0:
                dnodes.append((bytes(osc[off:off + 512]), False))
        while dnodes:
            dn, meta = dnodes.pop()
            stack = [z.BP(dn[64 + 128 * i:192 + 128 * i]) for i in range(dn[3])]
            if dn[7] & 4:
                ex = dn[12]
                stack.append(z.BP(dn[(ex + 1) * 512 - 128:(ex + 1) * 512]))
            while stack:
                bp = stack.pop()
                if bp.hole or bp.gbirth <= mintxg:
                    continue
                chk(bp, what)
                if bp.embedded:
                    continue
                if bp.level > 0:
                    c = p.read_bp(bp, verify=False)
                    stack.extend(z.BP(c[j:j + 128]) for j in range(0, len(c), 128))
                elif meta:
                    c = p.read_bp(bp, verify=False)
                    s = 0
                    while s < len(c):
                        if c[s] == 0:
                            s += 512
                            continue
                        ex = c[s + 12]
                        dnodes.append((bytes(c[s:s + (ex + 1) * 512]), False))
                        s += (ex + 1) * 512

    if "free_bpobj" in mosdir:
        bpobj(mosdir["free_bpobj"][1], "free_bpobj")
    seen = set()
    stack = [mosdir["root_dataset"][1]]
    while stack:
        dobj = stack.pop()
        h, o = p.dnode(mos, dobj)
        b, _ = p.bonus(h, o)
        head, czap = struct.unpack_from("<Q", h.content, b + 8)[0], struct.unpack_from("<Q", h.content, b + 32)[0]
        if czap:
            stack.extend(v[1] for v in p.zap(*p.dnode(mos, czap)).values())
        if not head:
            continue
        hp, _hbp = ds(head)
        dls = [hp[8]]
        prev = hp[1]
        while prev and prev not in seen:
            sp, sbp = ds(prev)
            if sp[0] != dobj:                                # the origin's (another dir) or $ORIGIN@$ORIGIN
                break
            seen.add(prev)
            dls.append(sp[8])
            if (sp[15] >> 61) & 1 == 0 and sbp.lsize >= 1024:    # not encrypted: its tree
                tree(sbp, sp[2], "snapshot %d" % prev)
            prev = sp[1]
        for dl in dls:
            dh, do = p.dnode(mos, dl)
            if dh.content[do] == 5:
                bpobj(dl, "deadlist %d" % dl)
            elif dh.content[do] == 50:
                ebo = mosdir["empty_bpobj"][1] if "empty_bpobj" in mosdir else 0
                for k, v in p.zap(dh, do).items():
                    if v[1] != ebo:
                        bpobj(v[1], "deadlist %d entry %s" % (dl, k))


def main(argv):
    if len(argv) == 3 and argv[1] == "--replay" and os.path.isfile(argv[2]):
        z = load_lib()
        try:
            out = replay(z, argv[2])
        except (ValueError, KeyError, z.ToolError) as e:
            print("space: FAIL — the host replay finds %s inconsistent: %s" % (argv[2], e))
            return 1
        print("space: PASS — %d log(s), %d metaslabs replayed in OpenZFS's model; %s"
              % (sum(1 for l in out if l.startswith("zfs-wlog")), sum(1 for l in out if l.startswith("zfs-wms")),
                 out[-1][len("zfs-wpool: "):]))
        return 0
    if len(argv) != 3 or not os.path.isfile(argv[1]) or not os.path.isfile(argv[2]):
        print("usage: zfs-wms-check.py IMG LOG")
        return 2
    z = load_lib()
    try:
        want = replay(z, argv[1])
    except (ValueError, KeyError, z.ToolError) as e:
        print("wms-check: FAIL — the host replay finds %s inconsistent: %s" % (argv[1], e))
        return 1
    with open(argv[2], "rb") as fh:
        got = [l.decode("ascii", "replace").strip("\r\n") for l in fh.read().split(b"\n")]
    got = [l for l in got if l.startswith(("zfs-wlog: ", "zfs-wms: ", "zfs-wpool: "))]
    if got == want:
        print("wms-check: PASS — %d log(s), %d metaslabs and the pool totals: the kernel's dump == the host replay"
              % (sum(1 for l in want if l.startswith("zfs-wlog")), sum(1 for l in want if l.startswith("zfs-wms"))))
        return 0
    print("wms-check: FAIL — the kernel's dump (<) differs from the host replay (>):")
    for i in range(max(len(got), len(want))):
        g = got[i] if i < len(got) else "(none)"
        w = want[i] if i < len(want) else "(none)"
        if g != w:
            print("  < %s\n  > %s" % (g, w))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
