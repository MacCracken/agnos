#!/bin/sh
# check-array-sizing — the Cyrius var X[N] UNITS trap, gated.
#
# ⛔ FUNCTION-LOCAL `var X[N]` allocates N **BYTES**. MODULE-SCOPE `var X[N]` allocates N x u64
# (8N bytes). Same syntax, 8x difference, and the compiler says nothing.
#
# ⭐ THIS EXISTS BECAUSE IT COST AN IRON BURN'S CREDIBILITY. `gputri.cyr` declared a
# function-local `var sizes[8]` and stored six u64s into it at offsets 0..40 — 48 bytes into 8,
# a 40-byte smash over the saved registers. Every number the tool printed was CORRECT; only the
# EXIT CODE was wrong (142 instead of 95), because the corruption bit on the way out. A quieter
# version of the same bug corrupts a neighbouring buffer and reads as a hardware fault.
#
# ⚠ WIDTH-AWARE. The first version of this gate assumed every store was 8 bytes and reported 13
# false positives across the kernel — `store8(&candidates + 4, ..)` into `var candidates[5]` is
# perfectly correct. A gate that cries wolf gets muted, which is worse than no gate.
#
# Conservative: only literal offsets are visible to it, so a clean run is not proof of absence —
# but every hit is real.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import re,sys,glob,os
root=sys.argv[1]; bad=0
files=sorted(glob.glob(root+'/gpu-test/*.cyr')+glob.glob(root+'/kernel/core/*.cyr')
             +glob.glob(root+'/kernel/arch/x86_64/*.cyr'))
for p in files:
    src=open(p).read(); depth=0
    for i,l in enumerate(src.split('\n')):
        m=re.search(r'^\s+var (\w+)\[(\d+)\]', l)
        if m and depth>0:
            name,n=m.group(1),int(m.group(2))
            worst=0; worst_w=0
            for w,off in re.findall(r'store(8|16|32|64)\(&%s \+ (\d+)'%re.escape(name), src):
                need=int(off)+int(w)//8
                if need>worst: worst,worst_w=need,int(w)
            if worst>n:
                print("  %s:%d  LOCAL var %s[%d] = %d BYTES but a store%d reaches byte %d"
                      %(os.path.basename(p),i+1,name,n,n,worst_w,worst))
                bad=1
        depth += l.count('{')-l.count('}')
sys.exit(bad)
PY
if [ $? -eq 0 ]; then echo "  PASS: no function-local var X[N] overruns"; exit 0; fi
echo "  FAIL: a function-local array is sized in SLOTS where Cyrius allocates BYTES"
exit 1
