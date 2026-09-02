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
# ⛔⛔ 1.56.52 — THE GLOB WAS THE GATE'S BLIND SPOT, NOT THE RULES. It covered tests/gpu, kernel/core
# and kernel/arch/x86_64 ONLY — so `kernel/user/`, `kernel/klib/` and every SUBDIRECTORY
# (kernel/arch/x86_64/usb/, ...) were never scanned. That is where the bugs were: shell.cyr held FOUR
# ring-0 stack overflows of exactly the second rule's shape (`var cbuf[64]` handed to
# `vfs_read(fd, &cbuf, 512)`), one of them remotely triggered, and kfmt.cyr's callers held a 17-byte
# write into 16-byte buffers. Both rules below would have flagged them on the day they were written.
# A gate that is right and not pointed at the code is indistinguishable from no gate.
tests_f=sorted(glob.glob(root+'/tests/**/*.cyr', recursive=True))
kernel_f=sorted(glob.glob(root+'/kernel/**/*.cyr', recursive=True))
files=sorted(tests_f+kernel_f)
# ⚠ VACUITY FLOOR — THE GLOB IS ALSO HOW THIS GATE PASSES ON NOTHING, AND THE 1.56.52 REPAIR ABOVE
# ADDED PATHS WITHOUT ADDING ONE. `bad` starts 0, so an EMPTY `files` walks straight to sys.exit(0)
# and the shell below prints "PASS: no function-local var X[N] overruns" — the identical green line a
# clean 265-file sweep prints. Two concrete ways that already exist here:
#   · ROOT IS COMPUTED TWO LEVELS UP FROM $0 (line 21, and the 1.56.22 split is exactly the edit that
#     changed how many levels that is). Move, copy or symlink this script one directory over and ROOT
#     lands on a tree with no kernel/ and no tests/ — both globs return [], and the gate reports the
#     kernel clean. Measured 2026-09-02: this script, unmodified, sitting at scripts/check/ in a tree
#     whose two-levels-up ROOT holds neither directory printed the PASS line and exited 0 having
#     opened zero files.
#   · DROP THE `**/` (or rename/move either half) and the enumeration collapses to the 3 top-level
#     kernel/*.cyr files across 1 directory, tests/ contributing 0 — a 99%-blind gate that still
#     prints PASS. That is the SAME failure the header records costing four ring-0 stack overflows in
#     kernel/user/, one remotely triggered.
# So the enumeration is asserted and PRINTED rather than implied: a run that says "3 files across 1
# directory" is reporting that its own glob broke, not that the kernel is clean. Floors are
# STRUCTURAL, not hand-tuned counts that would rot as the tree grows — each half must contribute, and
# the sweep must reach SUBDIRECTORIES, which is the entire content of the 1.56.52 fix.
# ⚠ AND HERE IS WHAT THIS FLOOR DOES **NOT** CATCH, MEASURED 2026-09-02 SO NOBODY RE-DERIVES IT:
# deleting only `recursive=True` does NOT empty the sweep — bare `**` degrades to `*`, so the globs
# still return 114 files across 12 directories (of 265 across 27) and pass every floor here. A floor
# is an anti-vacuity assertion, not a coverage assertion: it proves this run READ SOMETHING, never
# that it read everything. Do not raise these numbers toward the live counts to chase that — a floor
# tuned to today's tree fails on the day a subsystem is legitimately retired, and a gate that cries
# wolf gets muted, which the header above already records this file learning the hard way.
ndirs=len(set(os.path.dirname(p) for p in files))
if len(tests_f)<1 or len(kernel_f)<1 or ndirs<4:
    sys.stderr.write(
        "  VACUOUS: enumerated %d .cyr file(s) across %d director(ies) "
        "(tests/ %d, kernel/ %d) under %s\n"
        %(len(files),ndirs,len(tests_f),len(kernel_f),root))
    sys.stderr.write("  This gate is vacuous below one file per half and 4 directories: the tree has\n")
    sys.stderr.write("  kernel/{core,klib,user,arch/*,shaders/emit} plus one tests/* project per\n")
    sys.stderr.write("  subsystem. Finding fewer means the glob or ROOT broke, not that the code is clean.\n")
    sys.exit(2)
nlocal=0
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
            nlocal+=1
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
# ⚠ SECOND FLOOR — THE FILES CAN BE THERE AND THE RULES STILL RUN ON NOTHING. Both rules hang off
# ONE regex, `^\s+var (\w+)\[(\d+)\]`, which is indentation-sensitive BY DESIGN (the leading \s+ is
# what distinguishes a function-local — N bytes — from a module-scope declaration at column 0 — 8N
# bytes; that distinction is this gate's entire subject). So the day the formatter, a syntax change,
# or a `let`/`var` rename moves that shape, every one of the 359 declarations here stops matching,
# both rules iterate zero times, and the gate prints PASS over a fully-populated 265-file sweep. That
# is a rot no file count can see, so the count of declarations ACTUALLY EXAMINED is asserted too.
if nlocal<1:
    sys.stderr.write("  VACUOUS: scanned %d .cyr file(s) but matched ZERO function-local "
                     "`var X[N]` declarations\n"%len(files))
    sys.stderr.write("  Both rules key off that one regex; zero matches means the parse rotted, not\n")
    sys.stderr.write("  that the kernel declares no local arrays. Real tree: 359 declarations.\n")
    sys.exit(2)
print("  scanned %d .cyr file(s) across %d director(ies) (tests/ %d, kernel/ %d), "
      "%d function-local var X[N] declaration(s) examined"
      %(len(files),ndirs,len(tests_f),len(kernel_f),nlocal))
sys.exit(bad)
PY
rc=$?
if [ "$rc" -eq 0 ]; then echo "  PASS: no function-local var X[N] overruns"; exit 0; fi
# ⚠ A VACUOUS RUN IS NOT A CLEAN RUN, AND MUST NOT BORROW THE OVERRUN WORDING. check.sh:153 invokes
# this as `>/dev/null 2>&1` and keeps only the exit status, so the exit code is the ONLY channel that
# survives — both floors therefore fail CLOSED (rc=2 -> exit 1) rather than warning.
if [ "$rc" -eq 2 ]; then
    echo "  FAIL: check-array-sizing enumerated nothing — this run verified NO code (see stderr)"
    exit 1
fi
echo "  FAIL: a function-local array is sized in SLOTS where Cyrius allocates BYTES"
exit 1
