#!/bin/sh
# rt-region-derive — prove tests/gpu/rtaudit.cyr's MIRRORED constants still equal the kernel's.
#
# ⛔ THE RISK THIS CLOSES. `rtaudit.cyr` proves TD-3's placement arithmetic on the host, and to do
# that it must restate values that live in `kernel/core/gpu_regs.cyr` — a host test cannot include a
# kernel module that drags in the whole GPU register world. So there are two copies of the numbers
# that decide whether the render-target region overlaps the PSP TMR.
#
# **A mirror nobody diffs is the ATOM_DRY defect class**: two artifacts differing in name but not in
# intent, where the only real defence is that there is exactly one implementation — or, failing that,
# a mechanical proof that the second is identical. Without this gate, moving `GPU_RT_REGION_OFF` in
# the kernel leaves `rtaudit` cheerfully proving the OLD placement safe, in green, forever.
#
# ⚠ THIS IS THE SAME SHAPE AS THE BUG RUNG 15 SHIPPED, one level up: an oracle that agrees with a
# stale copy of its own premise. [[feedback_oracle_must_test_external_invariant]]
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
K="$ROOT/kernel/core/gpu_regs.cyr"
T="$ROOT/tests/gpu/rtaudit.cyr"
for f in "$K" "$T"; do
    [ -f "$f" ] || { echo "rt-region-derive: missing $f"; exit 2; }
done

python3 - "$K" "$T" <<'PY'
import sys, re
kpath, tpath = sys.argv[1], sys.argv[2]
ksrc = open(kpath).read()
tsrc = open(tpath).read()

# kernel constant -> mirrored name in the host test
PAIRS = [
    ("GPU_RT_REGION_OFF",  "K_RT_REGION_OFF"),
    ("GPU_RT_REGION_SIZE", "K_RT_REGION_SIZE"),
    ("GPU_RT_HANDLES",     "K_RT_HANDLES"),
    ("GPU_RT_HANDLE_SIZE", "K_RT_HANDLE_SIZE"),
    ("GPU_FB_BACK_LIMIT",  "K_FB_BACK_LIMIT"),
    ("GPU_PSP_TMR_OFF",    "K_PSP_TMR_OFF"),
    ("GPU_PSP_TMR_SIZE",   "K_PSP_TMR_SIZE"),
    ("GPU_VM_ARENA_OFF",   "K_VM_ARENA_OFF"),
    ("GPU_ARENA_SIZE",     "K_ARENA_SIZE"),
]

def grab(src, name):
    m = re.search(r'^var\s+' + re.escape(name) + r'\s*=\s*(0[xX][0-9a-fA-F]+|\d+)\s*;', src, re.M)
    return int(m.group(1), 0) if m else None

bad = 0
checked = 0
for kname, tname in PAIRS:
    kv = grab(ksrc, kname)
    tv = grab(tsrc, tname)
    if kv is None:
        print(f"rt-region-derive: FAIL -- {kname} not found in gpu_regs.cyr"); bad += 1; continue
    if tv is None:
        print(f"rt-region-derive: FAIL -- {tname} not found in rtaudit.cyr"); bad += 1; continue
    checked += 1
    if kv != tv:
        print(f"rt-region-derive: DRIFT -- {kname} = 0x{kv:X} but rtaudit's {tname} = 0x{tv:X}")
        bad += 1

# ⚠ A zero-comparison run would pass vacuously -- the exact defect class this tree keeps finding.
if checked < len(PAIRS):
    print(f"rt-region-derive: FAIL -- only {checked} of {len(PAIRS)} constants were comparable")
    sys.exit(1)

if bad:
    print("rt-region-derive: the host proof is validating a placement the kernel no longer uses.")
    sys.exit(1)
print(f"rt-region-derive: PASS -- all {checked} mirrored constants match the kernel")
PY
