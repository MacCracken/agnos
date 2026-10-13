#!/usr/bin/env python3
# zfs-orig — the ORIGINAL bytes of the fixture files a writer op list modifies in place (agnos 1.57.12 bite B5; design
# docs/development/proposals/2026-10-09-zfs-write.md § i.3 B): zfs-expect.py predicts a file a write / zero / truncate
# changes in place only from its old bytes (`--orig DIR`), and the fixture manifest carries hashes, not bytes. The
# fixture recipe (scripts/tool/zfs-fixture-guest.sh, its BUILD half) made every file with a deterministic generator, so
# the bytes are REGENERATED here from the same recipe — never read back through a ZFS reader, which would make the
# oracle depend on the code under test. zfs-expect.py checks each one against the manifest's size + SHA-256 before it
# uses it, so a generator that drifted from the recipe is UNUSABLE, never a silent wrong prediction.
#   rand_bytes SEED N   AES-128-CTR keystream, key = the first 32 hex digits of sha256(SEED), IV 0 (openssl enc)
#   text_bytes SEED N   "%s %07d the quick brown fox jumps over the lazy dog %d\n" % (SEED, i, i * 7919 % 10007), cut
#   printf TEXT         the bytes themselves
#
# usage: zfs-orig.py OUTDIR PATH...   writes OUTDIR/<PATH without its leading '/'> for every PATH the table knows
#        (a PATH it does not know is an error: add it from the recipe). Exit 0 · 1 an unknown path · 2 no openssl.
import hashlib, os, subprocess, sys

# path -> how the recipe made it (zfs-fixture-guest.sh build_ashift9 / build_main / build_wr / build_full)
ORIG = {
    "/agnos9/hello.txt": ("printf", b"hello from zfs (ashift 9)\n"),
    "/agnos9/rand-2m.bin": ("rand", "a9-2m", 2097152),
    "/agnos9/dir20/e00": ("printf", b"entry 0\n"),
    "/agnos9/dir20/e01": ("printf", b"entry 1\n"),
    "/agnostank/off/rand-200k.bin": ("rand", "off", 204800),
    "/agnostank/big1m/rand-3m.bin": ("rand", "big1m", 3145728),
    "/agnostank/gz/text-1m.txt": ("text", "gz", 1048576),
    "/agnostank/lzjb/text-1m.txt": ("text", "lzjb", 1048576),
    "/agnostank/zstd/text-1m.txt": ("text", "zstd", 1048576),
    "/agnostank/sha256/rand-256k.bin": ("rand", "sha256", 262144),
    "/agnostank/sha512/text-64k.txt": ("text", "sha512", 65536),
    "/agnostank/gang/gang.bin": ("rand", "gang", 2097152),          # B7: truncated to 1 MiB, then unlinked
    "/agnostank/coff/kid/kid.txt": ("printf", b"child of a canmount=off parent\n"),
    "/somewhere/else/custom.txt": ("printf", b"custom mountpoint\n"),
    "/agnoswr/copies2/c512k.bin": ("rand", "wr-copies2", 524288),
    "/agnoswr/rs4k/r64k.bin": ("rand", "wr-rs4k", 65536),
    "/agnoswr/quota/q.bin": ("rand", "wr-quota", 1048576),
    "/agnosfull/fill-5.bin": ("rand", "full-5", 917504),
    "/agnosfz/uids/u50": ("printf", b"u 50\n"),                     # B8 (RECIPE 7): a write in fat-accounting uids
    # 1.57.12 B9: what the op list and zfsx write in SNAPSHOTTED datasets (agnostank's root @snap1, wr's snap / clone /
    # snap2) — every byte of each still the snapshot's
    "/agnostank/hello.txt": ("printf", b"hello from zfs\n"),
    "/agnostank/small.txt": ("printf", b"embedded block pointer line\n" * 10),
    "/agnostank/rand-1m.bin": ("rand", "rand-1m", 1048576),
    "/agnostank/snap-changed.txt": ("printf", b"after snapshot\n"),
    "/agnostank/big.bin": ("rand", "big", 6291456),
    "/agnostank/tiny.bin": ("rand", "tiny", 100),
    "/agnoswr/snap/keep.txt": ("printf", b"unchanged since the snapshot\n"),
    "/agnoswr/snap/rewritten.bin": ("rand", "wr-snap-new", 131072),
    "/agnoswr/clone/keep.txt": ("printf", b"unchanged since the snapshot\n"),
    "/agnoswr/snap2/a.bin": ("rand", "wr-snap2-a", 8192),
    "/agnoswr/snap2/b.bin": ("rand", "wr-snap2-b", 8192),
    # (RECIPE 8, B9 review) edge / edgec: each rewritten with its own bytes in a later txg — the content is the generator's
    "/agnoswr/edge/p.bin": ("rand", "wr-edge-p", 65536),
    "/agnoswr/edge/e3.bin": ("rand", "wr-edge-e3", 4096),
    "/agnoswr/edge/e4.bin": ("rand", "wr-edge-e4", 4096),
    "/agnoswr/edgec/e4.bin": ("rand", "wr-edge-e4", 4096),
    "/agnoswr/edgec/c1.bin": ("rand", "wr-edgec-c1", 4096),
    "/agnoswr/edgec/t.bin": ("rand", "wr-edge-t", 65536),
}


def rand_bytes(seed, n):
    key = hashlib.sha256(seed.encode()).hexdigest()[:32]
    r = subprocess.run(["openssl", "enc", "-aes-128-ctr", "-K", key, "-iv", "0" * 32], input=bytes(n),
                       capture_output=True, check=True)
    if len(r.stdout) != n:
        raise RuntimeError("openssl gave %d bytes for %s, not %d" % (len(r.stdout), seed, n))
    return r.stdout


def text_bytes(seed, n):
    out, i = [], 0
    while i * 40 < n + 80:
        out.append("%s %07d the quick brown fox jumps over the lazy dog %d\n" % (seed, i, (i * 7919) % 10007))
        i += 1
    return "".join(out).encode()[:n]


def main(argv):
    if len(argv) < 3:
        print("usage: zfs-orig.py OUTDIR PATH...", file=sys.stderr)
        return 1
    out = argv[1]
    for p in argv[2:]:
        if p not in ORIG:
            print("zfs-orig: no recipe entry for %s (add it from scripts/tool/zfs-fixture-guest.sh)" % p, file=sys.stderr)
            return 1
        kind = ORIG[p]
        try:
            if kind[0] == "rand":
                b = rand_bytes(kind[1], kind[2])
            elif kind[0] == "text":
                b = text_bytes(kind[1], kind[2])
            else:
                b = kind[1]
        except (OSError, subprocess.CalledProcessError) as e:
            print("zfs-orig: openssl failed: %s" % e, file=sys.stderr)
            return 2
        dst = os.path.join(out, p.lstrip("/"))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as f:
            f.write(b)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
