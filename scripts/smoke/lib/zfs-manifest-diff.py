#!/usr/bin/env python3
# zfs-manifest-diff — the oracle comparison for scripts/smoke/zfs-smoke.sh (agnos 1.57.11).
#
# Inputs: the serial log of a ZFS_SELFTEST boot, and the manifest + summary that FreeBSD's OpenZFS wrote for the
# same image (scripts/tool/zfs-fixture.sh). The manifest is what `zpool import -o readonly=on -R <altroot>` +
# `zfs mount -a` shows: D <path> · F <path> <size> <sha256> · L <path> <target> · M <path> <dataset>.
# The kernel's walk prints D / F / L lines (zfs_selftest) and one "zfs: mount <path> <dataset>" per graft.
#
# ⭐ EXACT, NOT "MOSTLY". Every manifest line must be reproduced byte-for-byte, and the kernel may print nothing
# the manifest lacks. The ONLY tolerated differences are the ones the operator ruled out of scope for 1.57.11,
# and they are DERIVED from the pool's own properties (the summary), never from a hard-coded list of names:
#   · a dataset whose `checksum` is skein / edonr / blake3 must be refused ("not grafted: unsupported checksum
#     algorithm 12/13/14"), and then everything strictly under its mountpoint is absent (its mountpoint dir is
#     still the parent's directory and must still appear);
#   · an encrypted dataset must be refused ("not grafted: encrypted (no keys)") — the manifest never mounted it
#     either (no key loaded), so nothing changes in the tree;
#   · a file in a dataset whose `compression` is zstd* may read as "ERR zstd block unsupported" — with the
#     manifest's SIZE (stat still works: metadata is lz4) — and at least one such ERR must occur when the pool
#     has zstd data, or the refusal is untested.
# Anything else — a missing file, a wrong hash, an extra name, a refusal the properties do not explain — FAILS.
# Exit 0 PASS, 1 FAIL, 2 the inputs were unusable (no walk, no manifest).
import re, sys

TS = re.compile(r'^(\[[^]]*\] )?')
CK_ID = {'skein': 12, 'edonr': 13, 'blake3': 14}


def strip(line):
    return TS.sub('', line.rstrip('\r\n'), count=1)


def main():
    if len(sys.argv) < 4:
        print("usage: zfs-manifest-diff.py <serial.log> <manifest> <summary> [--expect-refusal TEXT]")
        return 2
    log, man, summ = sys.argv[1], sys.argv[2], sys.argv[3]
    expect_refusal = None
    if len(sys.argv) >= 6 and sys.argv[4] == '--expect-refusal':
        expect_refusal = sys.argv[5]
    raw = open(log, 'rb').read().decode('utf-8', 'replace').splitlines()
    lines = [strip(l) for l in raw]

    if expect_refusal is not None:
        # A pool agnos must NOT import (raidz, a dRAID, an unknown feature …): the refusal line must be there, and
        # no pool may have mounted.
        hit = any(expect_refusal in l for l in lines)
        mounted = any(l.startswith('zfs: pool ') for l in lines)
        print("  %s: refusal line containing %r" % ("PASS" if hit else "FAIL", expect_refusal))
        print("  %s: no pool mounted" % ("PASS" if not mounted else "FAIL"))
        return 0 if (hit and not mounted) else 1

    # ---- the pool's properties: which datasets agnos must refuse, which are zstd ----
    props = {}
    for l in open(summ, encoding='utf-8', errors='replace'):
        f = l.rstrip('\n').split('\t')
        if len(f) >= 3 and '@' not in f[0]:
            props.setdefault(f[0], {})[f[1]] = f[2]
    refused_ck = {ds: CK_ID[p.get('checksum', '')] for ds, p in props.items() if p.get('checksum', '') in CK_ID}
    encrypted = {ds for ds, p in props.items() if p.get('encryption', 'off') not in ('off', '-', '')}
    zstd = {ds for ds, p in props.items() if p.get('compression', '').startswith('zstd')}

    # ---- the manifest ----
    mD, mF, mL, mM = set(), {}, {}, {}
    for l in open(man, 'rb').read().decode('utf-8', 'replace').splitlines():
        if l.startswith('D '):
            mD.add(l[2:])
        elif l.startswith('F '):
            p, size, sha = l[2:].rsplit(' ', 2)
            mF[p] = (size, sha)
        elif l.startswith('L '):
            # the path cannot contain a space (fixture rule); the target may
            p, t = l[2:].split(' ', 1)
            mL[p] = t
        elif l.startswith('M '):
            p, ds = l[2:].rsplit(' ', 1)
            mM[ds] = p
    mD.discard('/')
    if not mF:
        print("  FAIL: the manifest lists no files — wrong fixture?")
        return 2

    # ---- the kernel ----
    kD, kF, kE, kL, kM, kRef = set(), {}, {}, {}, {}, {}
    began = done = False
    for l in lines:
        if l.startswith('zfs: mount '):
            p, ds = l[len('zfs: mount '):].rsplit(' ', 1)
            kM[ds] = p
        m = re.match(r'^zfs: dataset (\S+) not grafted: (.*)$', l)
        if m:
            kRef[m.group(1)] = m.group(2)
        if l.startswith('zfs-walk: begin'):
            began = True
        if l.startswith('zfs-walk: done'):
            done = True
        if not l.startswith('zfs-walk: '):
            continue
        b = l[len('zfs-walk: '):]
        if b.startswith('D '):
            kD.add(b[2:])
        elif b.startswith('L '):
            p, t = b[2:].split(' ', 1)
            kL[p] = t
        elif b.startswith('F '):
            m = re.match(r'^(.*) (\d+) ERR (.*)$', b[2:])
            if m:
                kE[m.group(1)] = (m.group(2), m.group(3))
            else:
                p, size, sha = b[2:].rsplit(' ', 2)
                kF[p] = (size, sha)
    if not began or not done:
        print("  FAIL: the kernel walk did not run to completion (begin=%s done=%s)" % (began, done))
        return 1

    fails = []
    # refusals: exactly the ones the properties explain, each for its reason
    for ds, cid in refused_ck.items():
        want = 'unsupported checksum algorithm %d' % cid
        if kRef.get(ds) != want:
            fails.append("dataset %s (checksum %s) should be refused with %r, kernel said %r" % (ds, props[ds]['checksum'], want, kRef.get(ds)))
    for ds in encrypted:
        if ds in mM:
            fails.append("encrypted dataset %s is MOUNTED in the manifest — the fixture loaded a key?" % ds)
        if kRef.get(ds) != 'encrypted (no keys)' and ds in props and props[ds].get('type', 'filesystem') == 'filesystem':
            # an encrypted dataset that would mount (canmount=on) must be refused by name
            if props[ds].get('canmount', 'on') == 'on' and props[ds].get('mountpoint', '') not in ('none', 'legacy'):
                fails.append("encrypted dataset %s not refused as encrypted (kernel: %r)" % (ds, kRef.get(ds)))
    for ds, why in kRef.items():
        if ds not in refused_ck and ds not in encrypted:
            fails.append("kernel refused dataset %s (%s) — nothing in its properties explains that" % (ds, why))

    cut = [mM[ds] for ds in refused_ck if ds in mM]
    def under_refused(p):
        return any(p.startswith(c + '/') for c in cut)

    # mounts
    for ds, p in mM.items():
        if ds in refused_ck:
            continue
        if kM.get(ds) != p:
            fails.append("mount %s at %s: kernel has %r" % (ds, p, kM.get(ds)))
    for ds, p in kM.items():
        if ds not in mM:
            fails.append("kernel grafted %s at %s, which the manifest does not mount" % (ds, p))

    # tree
    eD = {p for p in mD if not under_refused(p)}
    eF = {p: v for p, v in mF.items() if not under_refused(p)}
    eL = {p: v for p, v in mL.items() if not under_refused(p)}
    for p in sorted(eD - kD):
        fails.append("missing dir %s" % p)
    for p in sorted(kD - eD):
        fails.append("extra dir %s" % p)
    for p, t in sorted(eL.items()):
        if kL.get(p) != t:
            fails.append("symlink %s -> %r, kernel %r" % (p, t, kL.get(p)))
    for p in sorted(set(kL) - set(eL)):
        fails.append("extra symlink %s" % p)
    zstd_err = 0
    for p, (size, sha) in sorted(eF.items()):
        if p in kF:
            if kF[p] != (size, sha):
                fails.append("file %s: manifest %s %s, kernel %s %s" % (p, size, sha, kF[p][0], kF[p][1]))
        elif p in kE:
            esize, why = kE[p]
            in_zstd = any(p == mM.get(ds) or p.startswith(mM.get(ds, '\0') + '/') for ds in zstd)
            if why.startswith('zstd block unsupported') and in_zstd and esize == size:
                zstd_err += 1
            else:
                fails.append("file %s read ERR (%s, size %s) — not an expected refusal" % (p, why, esize))
        else:
            fails.append("missing file %s" % p)
    for p in sorted((set(kF) | set(kE)) - set(eF)):
        fails.append("extra file %s" % p)
    if any(ds in mM for ds in zstd) and zstd_err == 0:
        fails.append("the pool has a mounted zstd dataset but no file read as 'zstd block unsupported' — the refusal is untested")

    print("  manifest: %d dirs, %d files, %d symlinks, %d mounts; refused by properties: %s%s" % (
        len(mD), len(mF), len(mL), len(mM),
        ', '.join('%s(%s)' % (ds, props[ds]['checksum']) for ds in sorted(refused_ck)) or 'none',
        (', encrypted: ' + ', '.join(sorted(encrypted))) if encrypted else ''))
    print("  kernel:   %d dirs, %d files (+%d zstd refusals), %d symlinks, %d grafts" % (
        len(kD), len(kF), zstd_err, len(kL), len(kM)))
    if fails:
        for f in fails[:40]:
            print("  FAIL: " + f)
        if len(fails) > 40:
            print("  FAIL: ... and %d more" % (len(fails) - 40))
        return 1
    print("  PASS: every manifest line reproduced (sizes + SHA-256, link targets, mounts); refusals exactly as the properties require")
    return 0


if __name__ == '__main__':
    sys.exit(main())
