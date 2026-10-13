#!/usr/bin/env python3
# zfs-room-check — WHERE A SHORT WRITE STOPPED, bounded on the host (agnos 1.57.12 bite B5 review, finding 7(2); design
# docs/development/proposals/2026-10-09-zfs-write.md § k.36, § k.40). A write the writer cuts SHORT at ENOSPC (the `full`
# fill at OpenZFS's slop; wr's burst at the metaslabs agnos can allocate in) took its length from the kernel's own
# `-> <bytes>` line, so the expected manifest pinned the bytes but not how short the write was. This holds it to the pool's
# space record instead — every log space map the commits wrote, which the host replay (zfs-wms-check.py, the audit's h6)
# has already found consistent — in the writer's rule (core/zfs_write.cyr zfs_wroom / zfs_wphys / zfs_wd_aroom):
#   room(t)  = min(space - slop - deferred(t), synced(t) - deferred(t) - MDRES)        the bytes the pool may hold
#              allocated before user data stops: OpenZFS's dsl_pool_unreserved_space (space = the normal class, slop =
#              spa_get_slop_space) and the metaslabs WITH a space map (the only ones agnos allocates in) less one
#              commit's metadata (MDRES = the metadata arena x 3 copies)
#   alloc(t) = the pool's allocated bytes at mount (the start image's replay) + Σ ALLOC - FREE of logs T0+1 .. t
#   deferred(t) = FREE bytes of the logs inside the deferral window after txg t: txg >= T0 - 2 at the mount (t = T0), txg
#              >= t - 1 once txg t committed (1.57.12 B11, design k.125: the frees of txg u are released when u + 2 is
#              durable — OpenZFS's TXG_DEFER_SIZE; until B11 agnos deferred every free for the boot and this was the whole
#              boot's Σ)
# for a write whose txgs are TF .. TL (each txg's user data fit what was left when it was admitted — the space predicates
# with the txg's in-flight bytes — and since B11 room - alloc can GROW from txg to txg as frees leave the window):
#   UPPER  L x copies <= Σ over t in TF .. TL of max(0, room(t - 1) - alloc(t - 1))   — its user data never went past
#                                                           what each of its txgs had left when it opened
#   ADMIT  alloc(TL - 1) + B <= room(TL - 1)              — its last txg's first block fit when it was admitted (with
#                                                           nothing in flight): the writer never wrote past the room
#                                                           (B = one block's asize x copies)
#   LOWER  alloc(TL) + B > room(TL)                       — the block it was refused really did not fit: it did not
#                                                           stop while room was left
# usage: zfs-room-check.py START FINAL TF TL L B COPIES [MSMAX] [--log LOG]   (pool-only images; START = the image the
#        boot mounted; MSMAX (1.57.12 B9): the op list's allocation cap — zfs_wt_msmax: only the first MSMAX metaslabs
#        with a space map count as synced; LOG (1.57.12 B10): the lane's serial log — the writer DESTROYS the logs every
#        metaslab's U has passed (design § c.5), so a txg whose log is gone from FINAL is taken from its plan line
#        (`zfs-wtest: txg T plan: ... alloc=A free=F ...`, the same ALLOC / FREE bytes its log held), and every txg whose
#        log survives must agree with its plan line — the kernel's figures held to the image where the image still has
#        them)
# Exit 0 both hold · 1 one fails (named) · 2 unusable input
import importlib.util, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
MDRES = 3 * 0x1E0000


def load(name, rel):
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, rel))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def slop(space, lg):
    """spa_get_slop_space (spa_misc.c): MIN(space >> 5, 128 GiB) less MIN(the embedded log class, half of it), at
    least MIN(space / 2, 128 MiB)."""
    s = min(space >> 5, 128 << 30)
    s -= min(lg, s >> 1)
    return max(s, min(space >> 1, 128 << 20))


def logs_of(lines):
    out = {}
    for l in lines:
        m = re.match(r"zfs-wlog: txg=(\d+) obj=\d+ entries=\d+ alloc=(\d+) free=(\d+)$", l)
        if m:
            out[int(m.group(1))] = (int(m.group(2)), int(m.group(3)))
    return out


def plans_of(path):
    out = {}
    with open(path, "rb") as fh:
        for raw in fh.read().split(b"\n"):
            l = raw.decode("ascii", "replace").strip("\r")
            m = re.search(r"zfs-wtest: txg (\d+) plan: .* alloc=(\d+) free=(\d+) ", l)
            if m:
                out[int(m.group(1))] = (int(m.group(2)), int(m.group(3)))
    return out


def main(argv):
    log = None
    if len(argv) >= 3 and argv[-2] == "--log":
        log = argv[-1]
        argv = argv[:-2]
    if len(argv) not in (8, 9) or not all(os.path.isfile(a) for a in argv[1:3]) or (log and not os.path.isfile(log)):
        print("usage: zfs-room-check.py START FINAL TF TL L B COPIES [MSMAX] [--log LOG]")
        return 2
    tf, tl, ln, blk, cp = (int(a) for a in argv[3:8])
    msmax = int(argv[8]) if len(argv) == 9 else 0
    wms = load("zfswms", "scripts/smoke/lib/zfs-wms-check.py")
    z = wms.load_lib()
    try:
        sp = z.Pool(argv[1])
        t0, msh = sp.txg, sp.ms_shift
        s_lines, f_lines = wms.replay(z, argv[1]), wms.replay(z, argv[2])
        sms, _u, _l, _tz = sp.space_info(sp.mos())
    except (ValueError, KeyError, z.ToolError) as e:
        print("room: unusable input: %s" % e)
        return 2
    pool = [l for l in s_lines if l.startswith("zfs-wpool: ")][0]
    alloc0 = int(re.search(r" allocated=(\d+)", pool).group(1))
    slogs = logs_of(s_lines)
    nms = len(sms)
    lg = 0
    if nms > 64:
        nms -= 1
        lg = 1 << msh
    space = nms << msh
    nsynced = sum(1 for so in sms if so)
    if msmax > 0:
        nsynced = min(nsynced, msmax)
    synced = nsynced << msh
    fl = logs_of(f_lines)
    if log:
        pl = plans_of(log)
        bad = [t for t in sorted(fl) if t > t0 and t in pl and pl[t] != fl[t]]
        if bad:
            print("room: FAIL — txg %d's plan line (alloc, free) %s differs from its log space map on the image %s"
                  % (bad[0], pl[bad[0]], fl[bad[0]]))
            return 1
        # the ub-only commit (T0 + 1) has neither: it allocates and frees nothing
        gone = [t for t in range(t0 + 2, tl + 1) if t not in fl and t not in pl]
        if gone:
            print("room: unusable input — txg(s) %s have neither a log on the image nor a plan line" % gone[:5])
            return 2
        for t in pl:
            if t > t0 and t not in fl:
                fl[t] = pl[t]
    missing = [t for t in range(tf, tl + 1) if t not in fl]
    if missing:
        print("room: FAIL — the final image has no log space map for the write's txg(s) %s" % missing[:5])
        return 1

    alll = dict(slogs)
    alll.update(fl)

    def state(t):
        a = alloc0
        for u in range(t0 + 1, t + 1):                   # a txg without a log (the ub-only commit) moved nothing
            a += fl.get(u, (0, 0))[0] - fl.get(u, (0, 0))[1]
        lo = t0 - 2 if t <= t0 else t - 1                # (B11) the deferral window after txg t (zfs_wdef_rel)
        d = sum(f for u, (_a, f) in alll.items() if lo <= u <= t)
        room = min(space - slop(space, lg) - d, synced - d - MDRES)
        return a, d, room

    a0, d0, r0 = state(tf - 1)
    am, dm, rm = state(tl - 1)
    a1, d1, r1 = state(tl)
    upper = sum(max(0, state(t - 1)[2] - state(t - 1)[0]) for t in range(tf, tl + 1))
    fails = []
    if am + blk > rm:
        fails.append("ADMIT: before its last txg %d only %d B were left for user data (room %d - allocated %d), less than "
                     "the %d B block it then wrote — the writer went past the room" % (tl, rm - am, rm, am, blk))
    if ln * cp > upper:
        fails.append("UPPER: %d B x %d copies > the %d B its txgs %d..%d had left when each opened (txg %d: allocated %d, "
                     "deferred %d, room %d)" % (ln, cp, upper, tf, tl, tf - 1, a0, d0, r0))
    if a1 + blk <= r1:
        fails.append("LOWER: after txg %d %d B were still free for user data (room %d - allocated %d) and the refused "
                     "block needed only %d — the write stopped early" % (tl, r1 - a1, r1, a1, blk))
    for f in fails:
        print("room:   FAIL " + f)
    v = "PASS" if not fails else "FAIL"
    print("room: %s — %d B in txgs %d..%d: at most the %d B its txgs had left as each opened (%d B at its start); %d B before its last txg (>= a block); then %d B left (< the refused block's %d B)"
          " — space %d, slop %d, synced %d, deferred %d -> %d, allocated %d -> %d"
          % (v, ln, tf, tl, upper, r0 - a0, rm - am, r1 - a1, blk, space, slop(space, lg), synced, d0, d1, a0, a1))
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
