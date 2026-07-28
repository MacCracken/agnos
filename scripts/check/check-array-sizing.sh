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
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$ROOT" <<'PY'
import re,sys,glob,os
root=sys.argv[1]; bad=0
files=sorted(glob.glob(root+'/tests/gpu/*.cyr')+glob.glob(root+'/kernel/core/*.cyr')
             +glob.glob(root+'/kernel/arch/x86_64/*.cyr'))
for p in files:
    src=open(p).read()
    lines = src.split('\n')
    # ⚠ SCOPE THE SEARCH TO THE ENCLOSING BLOCK, not the whole file. Two functions in one file may
    # each declare a local of the same name at DIFFERENT sizes — gpu.cyr has `var hdr[32]` read with
    # 32 and `var hdr[48]` read with 48, both correct — and a whole-file grep matches one's
    # declaration against the other's use. That false positive is indistinguishable from a real
    # smash by eye, and this gate's whole value is that every hit it reports is real.
    dep = []
    d = 0
    for l in lines:
        dep.append(d)
        d += l.count('{') - l.count('}')
    for i,l in enumerate(lines):
        m=re.search(r'^\s+var (\w+)\[(\d+)\]', l)
        depth = dep[i]
        if m and depth>0:
            name,n=m.group(1),int(m.group(2))
            end = len(lines)
            for k in range(i+1, len(lines)):
                if dep[k] < depth:
                    end = k
                    break
            src_w = '\n'.join(lines[i:end])
            worst=0; worst_w=0
            for w,off in re.findall(r'store(8|16|32|64)\(&%s \+ (\d+)'%re.escape(name), src_w):
                need=int(off)+int(w)//8
                if need>worst: worst,worst_w=need,int(w)
            if worst>n:
                print("  %s:%d  LOCAL var %s[%d] = %d BYTES but a store%d reaches byte %d"
                      %(os.path.basename(p),i+1,name,n,n,worst_w,worst))
                bad=1
            # ⛔⛔ SECOND RULE — THE BUFFER-AND-LENGTH IDIOM, added 2026-07-27 AFTER AN IRON BURN.
            # The rule above can only see stores written DIRECTLY to the named array. It is blind to
            # an array passed BY ADDRESS to something that writes it, which is how the same bug class
            # reached silicon a second time: gputex.cyr's seam case declared `var o1[16]` and handed
            # &o1 to tl_op0c(), which writes a 64-byte op record — a 48-byte smash the gate could not
            # see, and the burn came back `the SOLO list-B call was REJECTED` because the overflow
            # corrupted the locals the NEXT record was built from.
            #
            # `f(&buf, LEN)` with a literal LEN is the one indirect form that states its own size, so
            # it is checkable exactly and with no guessing: the array must hold LEN bytes.
            # ⚠ Still conservative — `f(&buf, n*96)` and a writer that takes no length stay invisible.
            # A clean run remains "no PROVABLE overrun", never "no overrun".
            # ⚠ THE OBVIOUS REGEX IS WRONG, AND IT CRIED WOLF FOUR TIMES BEFORE THIS COMMENT EXISTED.
            # `&name\s*,\s*(\d+)\)` also matches `store8(&msg, 72)`, where 72 is the byte VALUE — so
            # it flagged main.cyr's "HI"/"PI" literals, net_dhcp's option code 53 and a gpu.cyr
            # header read, all correct code. That is precisely the failure the header above records
            # the FIRST version of this gate making. So: parse CALL SITES, skip store*/load*, and
            # require &buf to be the SECOND-TO-LAST argument with a literal length LAST — the real
            # buffer-and-length idiom and nothing else.
            needs = []
            for callee, args in re.findall(r'(\w+)\(([^()]*)\)', src_w):
                if callee.startswith('store') or callee.startswith('load'):
                    continue
                m2 = re.search(r'&%s\s*,\s*(\d+)\s*$' % re.escape(name), args.strip())
                if m2:
                    needs.append(int(m2.group(1)))
            for need in needs:
                if need > n:
                    print("  %s:%d  LOCAL var %s[%d] = %d BYTES but is passed with an explicit "
                          "length of %d" % (os.path.basename(p), i+1, name, n, n, need))
                    bad = 1
                    break
sys.exit(bad)
PY
if [ $? -eq 0 ]; then echo "  PASS: no function-local var X[N] overruns"; exit 0; fi
echo "  FAIL: a function-local array is sized in SLOTS where Cyrius allocates BYTES"
exit 1
