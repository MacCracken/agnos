#!/usr/bin/env python3
# gpt-image — write, verify or predict a GUID Partition Table on a disk IMAGE at any logical block size and entry size
# (agnos 1.57.12, scripts/smoke/gpt-geometry-smoke.sh). Host tools cover only part of it: sfdisk --sector-size writes
# a 4096 B-LBA table but only 128-byte entries, and gdisk/sgdisk take the block size from the device (512 for a file).
# UEFI 2.10 §5.3: the protective MBR is LBA 0, the header LBA 1, the entry array from PartitionEntryLBA — every LBA
# field in units of the LOGICAL BLOCK; SizeOfPartitionEntry is 128 x 2^n; both CRC32s are IEEE (zlib.crc32); the
# backup header is the disk's last LBA with its array right below it.
#
# usage:
#   gpt-image.py write IMG --lba N --esize N --nents N --part IDX:TYPE:FIRST:LAST:NAME [--part ...]
#                     [--fill COUNT:TYPE:FIRST:LEN]
#       IMG must exist (its size is the disk size). TYPE = esp | linux | msft | swap. FIRST/LAST in logical blocks.
#       --esize need not be 128 x 2^n: a refusal lane writes 384 on purpose (the CRCs are still right).
#       --fill: entries 0..COUNT-1 = partitions of LEN blocks packed from FIRST, named p0, p1, ...
#   gpt-image.py damage IMG --lba N --at OFF --u32 VAL
#       overwrite the u32 at byte OFF of the PRIMARY header (LBA 1) WITHOUT recomputing its CRC — a damaged primary
#       the kernel must recover from the backup (1.57.12 review M2). --at 32 is AlternateLBA's low half: a garbage
#       backup pointer the kernel must NOT follow (1.57.12 D2 — the backup is the device's last LBA).
#   gpt-image.py verify IMG --lba N
#       re-reads both headers and arrays, checks every CRC, the backup's mirror fields and the entry geometry, prints
#       one line per used entry, `[idx] first-last name`, then `OK ...` (exit 0) or the first fault (`FAIL: ...`, 1).
#   gpt-image.py expect IMG --lba N
#       the lines agnos prints for this disk at boot (gpt.cyr gpt_init / gpt_print_summary / gpt_print_partitions_max
#       with GPT_BOOT_LIST_MAX), one per line — a model of gpt_init: the header CRC first, then the geometry; the
#       backup at the device's LAST LBA when the primary's CRC fails (1.57.12: UEFI 2.10 §5.3.2 — never the failing
#       primary's AlternateLBA), its MyLBA / AlternateLBA cross-checked; an array over 1 MiB walked truncated; the
#       first 16 used entries listed, then "... and N more".
import struct, sys, uuid, zlib

TYPES = {
    'esp':   ('C12A7328-F81F-11D2-BA4B-00A0C93EC93B', 'EFI System '),
    'linux': ('0FC63DAF-8483-4772-8E79-3D69D8477DE4', 'Linux FS '),
    'msft':  ('EBD0A0A2-B9E5-4433-87C0-68B6B72699C7', 'MSFT Basic '),
    'swap':  ('0657FD6D-A4AB-43C4-84E5-0933C84B4F4F', 'Linux swap '),
}
NAMES = {uuid.UUID(g).bytes_le: n for g, n in TYPES.values()}


def die(msg):
    print('FAIL: ' + msg)
    sys.exit(1)


def arg(argv, flag):
    if flag not in argv:
        die('missing ' + flag)
    return argv[argv.index(flag) + 1]


def header(lba, my, alt, first, last, guid, elba, nents, esize, acrc):
    h = struct.pack('<8sIIIIQQQQ16sQIII', b'EFI PART', 0x00010000, 92, 0, 0, my, alt, first, last, guid,
                    elba, nents, esize, acrc)
    h = h[:16] + struct.pack('<I', zlib.crc32(h)) + h[20:]
    return h + b'\0' * (lba - len(h))


def write(argv):
    img = argv[0]
    lba = int(arg(argv, '--lba')); esize = int(arg(argv, '--esize')); nents = int(arg(argv, '--nents'))
    with open(img, 'rb') as f:
        f.seek(0, 2); size = f.tell()
    nlba = size // lba
    alba = (nents * esize + lba - 1) // lba          # array length in logical blocks
    first = 2 + alba; last = nlba - 2 - alba
    arr = bytearray(nents * esize)
    parts = []
    for i in range(len(argv)):
        if argv[i] == '--part':
            idx, typ, pf, pl, name = argv[i + 1].split(':', 4)
            parts.append((int(idx), typ, int(pf), int(pl), name))
        elif argv[i] == '--fill':
            cnt, typ, f0, ln = argv[i + 1].split(':', 3)
            for k in range(int(cnt)):
                parts.append((k, typ, int(f0) + k * int(ln), int(f0) + (k + 1) * int(ln) - 1, 'p%d' % k))
    for (idx, typ, pf, pl, name) in parts:
        if not (first <= pf <= pl <= last) or idx >= nents:
            die('partition %d [%d, %d] outside the table or the usable range [%d, %d]' % (idx, pf, pl, first, last))
        e = uuid.UUID(TYPES[typ][0]).bytes_le + uuid.uuid4().bytes_le + struct.pack('<QQQ', pf, pl, 0)
        e += name.encode('utf-16-le')[:72].ljust(72, b'\0')
        arr[idx * esize: idx * esize + 128] = e
    acrc = zlib.crc32(bytes(arr))
    dguid = uuid.uuid4().bytes_le
    pad = bytes(arr) + b'\0' * (alba * lba - len(arr))
    mbr = bytearray(lba)
    mbr[446:462] = struct.pack('<BBBBBBBBII', 0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF, 1, min(nlba - 1, 0xFFFFFFFF))
    mbr[510:512] = b'\x55\xaa'
    with open(img, 'r+b') as f:
        f.seek(0); f.write(mbr)
        f.write(header(lba, 1, nlba - 1, first, last, dguid, 2, nents, esize, acrc))
        f.write(pad)
        f.seek((nlba - 1 - alba) * lba); f.write(pad)
        f.write(header(lba, nlba - 1, 1, first, last, dguid, nlba - 1 - alba, nents, esize, acrc))
    print('wrote: lba=%d esize=%d nents=%d array LBAs 2-%d usable %d-%d' % (lba, esize, nents, 1 + alba, first, last))


def read_gpt(f, lba, at, strict=True):
    f.seek(at * lba); h = f.read(lba)
    if h[:8] != b'EFI PART':
        die('no "EFI PART" at LBA %d' % at)
    hs = struct.unpack_from('<I', h, 12)[0]
    if not (92 <= hs <= lba):
        die('header size %d at LBA %d' % (hs, at))
    crc = struct.unpack_from('<I', h, 16)[0]
    if zlib.crc32(h[:16] + b'\0\0\0\0' + h[20:hs]) != crc:
        die('header CRC at LBA %d' % at)
    my, alt, first, last = struct.unpack_from('<QQQQ', h, 24)
    elba, nents, esize, acrc = struct.unpack_from('<QIII', h, 72)
    if my != at:
        die('MyLBA %d != %d' % (my, at))
    if strict and (esize < 128 or esize & (esize - 1)):
        die('entry size %d is not 128 x 2^n' % esize)
    f.seek(elba * lba); arr = f.read(nents * esize)
    if zlib.crc32(arr) != acrc:
        die('array CRC (header at LBA %d)' % at)
    return dict(alt=alt, first=first, last=last, elba=elba, nents=nents, esize=esize, arr=arr, guid=h[56:72])


def entries(g):
    out = []
    for i in range(g['nents']):
        e = g['arr'][i * g['esize']: i * g['esize'] + 128]
        if e[:16] == b'\0' * 16:
            continue
        pf, pl = struct.unpack_from('<QQ', e, 32)
        out.append((i, e[:16], pf, pl, e[56:128].decode('utf-16-le').split('\0')[0]))
    return out


def verify(argv):
    img = argv[0]; lba = int(arg(argv, '--lba'))
    with open(img, 'rb') as f:
        f.seek(0, 2); nlba = f.tell() // lba
        f.seek(510)
        if f.read(2) != b'\x55\xaa':
            die('no protective MBR signature')
        p = read_gpt(f, lba, 1, strict=False)
        if p['alt'] != nlba - 1:
            die('AlternateLBA %d != last LBA %d' % (p['alt'], nlba - 1))
        b = read_gpt(f, lba, nlba - 1, strict=False)
    for k in ('first', 'last', 'nents', 'esize', 'arr', 'guid'):
        if p[k] != b[k]:
            die('backup header/array differs from the primary in %s' % k)
    if p['elba'] != 2:
        die('primary array at LBA %d' % p['elba'])
    for (i, t, pf, pl, name) in entries(p):
        print('  [%d] %d-%d %s' % (i, pf, pl, name))
    print('OK: lba=%d esize=%d nents=%d usable %d-%d, %d used entries' % (lba, p['esize'], p['nents'], p['first'],
          p['last'], len(entries(p))))


def damage(argv):
    img = argv[0]; lba = int(arg(argv, '--lba')); at = int(arg(argv, '--at'), 0); val = int(arg(argv, '--u32'), 0)
    if not (0 <= at <= 88):
        die('--at %d is not a header field offset' % at)
    with open(img, 'r+b') as f:
        f.seek(lba + at); f.write(struct.pack('<I', val))
    print('damaged: primary header u32 @%d = %d (CRC not recomputed)' % (at, val))


ARRAY_MAX = 0x100000     # gpt.cyr GPT_ARRAY_MAX_BYTES
BOOT_LIST_MAX = 16       # gpt.cyr GPT_BOOT_LIST_MAX


def model_header(f, lba, at):
    # (fields, crc_ok, geometry_ok) of the header at LBA `at` the way gpt_decode_header + gpt_validate_header_crc read it.
    f.seek(at * lba); h = f.read(lba)
    if h[:8] != b'EFI PART':
        return None, False, False
    hs, crc = struct.unpack_from('<II', h, 12)
    crc_ok = 92 <= hs <= lba and zlib.crc32(h[:16] + b'\0\0\0\0' + h[20:hs]) == crc
    my, alt, first, last = struct.unpack_from('<QQQQ', h, 24)
    elba, nents, esize, acrc = struct.unpack_from('<QIII', h, 72)
    geo_ok = 128 <= esize <= 4096 and esize & (esize - 1) == 0 and nents >= 1 and elba >= 2
    return dict(my=my, alt=alt, first=first, last=last, elba=elba, nents=nents, esize=esize, acrc=acrc), crc_ok, geo_ok


def expect(argv):
    img = argv[0]; lba = int(arg(argv, '--lba'))
    out = []
    with open(img, 'rb') as f:
        p, crc_ok, geo_ok = model_header(f, lba, 1)
        if p is None:
            die('no "EFI PART" at LBA 1: agnos prints nothing')
        backup = ''
        if crc_ok and not geo_ok:
            print('gpt: header declares an unusable partition-entry geometry')
            return
        if not crc_ok:
            # 1.57.12: the backup is the device's LAST LBA (the image's size; the kernel's blk_capacity - 1) — the
            # failing primary's AlternateLBA is not read.
            f.seek(0, 2); dev_last = f.tell() // lba - 1
            out.append("gpt: primary header CRC mismatch, trying backup @ LBA %d (the device's last LBA)" % dev_last)
            p, crc_ok, geo_ok = model_header(f, lba, dev_last)
            if p is None or not crc_ok:
                die('the backup does not verify either: agnos finds no GPT')
            if p['my'] != dev_last:
                out.append("gpt: the backup header's MyLBA is %d, not the LBA it was read from -- no GPT" % p['my'])
                print('\n'.join(out)); return
            if p['alt'] != 1:
                out.append("gpt: the backup header's AlternateLBA is %d, not the primary's LBA 1 -- no GPT" % p['alt'])
                print('\n'.join(out)); return
            if not geo_ok:
                out.append('gpt: backup header declares an unusable partition-entry geometry')
                print('\n'.join(out)); return
            out.append('gpt: recovered via backup header'); backup = ' [backup hdr]'
        nbytes = p['nents'] * p['esize']; walk = min(nbytes, ARRAY_MAX)
        f.seek(p['elba'] * lba); arr = f.read(walk)
        if nbytes > ARRAY_MAX:
            out.append('gpt: table truncated -- the first %d of %d entries are read (1 MiB walk bound); the array '
                       'CRC32 covers them all and is NOT verified' % (walk // p['esize'], p['nents']))
            acrc = 'arr-CRC-UNVERIFIED'
        elif zlib.crc32(arr) == p['acrc']:
            acrc = 'arr-CRC-OK'
        else:
            out.append('gpt: partition array CRC mismatch -- proceeding (trust degraded)'); acrc = 'arr-CRC-BAD'
    # gpt.cyr counts and lists an entry whose type GUID's FIRST 8 bytes are non-zero.
    used = []
    for i in range(walk // p['esize']):
        e = arr[i * p['esize']: i * p['esize'] + 128]
        if e[:8] != b'\0' * 8:
            pf, pl = struct.unpack_from('<QQ', e, 32)
            used.append((i, e[:16], pf, pl, e[56:128].decode('utf-16-le', 'replace').split('\0')[0]))
    out.append('gpt: present, first=%d last=%d parts=%d/%d%s hdr-CRC-OK %s' % (p['first'], p['last'], len(used),
               p['nents'], backup, acrc))
    out.append('partitions (%d active / %d reserved):' % (len(used), p['nents']))
    for (i, t, pf, pl, name) in used[:BOOT_LIST_MAX]:
        out.append('  [%d] %s%s  LBA %d-%d (%d MiB)' % (i, NAMES.get(t, '(unknown type) '), name, pf, pl,
                   (pl - pf + 1) * lba // 1048576))
    if len(used) > BOOT_LIST_MAX:
        out.append('  ... and %d more -- the `parts` command lists every entry' % (len(used) - BOOT_LIST_MAX))
    elif nbytes > ARRAY_MAX:
        out.append('  (table truncated: entries %d and up are past the 1 MiB walk bound, not read)' % (walk // p['esize']))
    print('\n'.join(out))


if __name__ == '__main__':
    if len(sys.argv) < 3 or sys.argv[1] not in ('write', 'damage', 'verify', 'expect'):
        die('usage: gpt-image.py write|damage|verify|expect IMG ...')
    {'write': write, 'damage': damage, 'verify': verify, 'expect': expect}[sys.argv[1]](sys.argv[2:])
