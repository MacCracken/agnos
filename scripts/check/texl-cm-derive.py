#!/usr/bin/env python3
# texl-cm-derive — DERIVE kernel/shaders/tex_list_cm.s from kernel/shaders/tex_list.s.
#
# ⛔ WHY A DERIVATION AND NOT A HAND-COPY. tex_list_cm.s (rung 14b, col-major) is tex_list.s (rung 14)
# with the lane axis transposed. tex_list.s is in turn tex_rgba.s's rung-13 body — iron-proven 17/17
# across nine burns — under a new prologue. A hand-written third copy would put that proof one
# careless paste away from being false, and the failure mode is a shader that agrees with the other
# two on every test anyone bothers to run and disagrees on the one nobody does.
#
# This file IS the specification of the difference. Running it in --check mode is the gate:
# re-derive from tex_list.s and demand the committed tex_list_cm.s match byte for byte. Any edit to
# the shared body of either file, or any drift in the transpose itself, goes red.
#
# THE TRANSPOSE, in two windows and nothing else:
#
#   Window P (prologue, ABOVE the body marker — freely allowed to differ):
#       the packed pwh dword (record +148, (ph<<16)|pw) is unpacked into the two bound registers.
#       s6 is the PER-LANE bound, s7 the WAVE-UNIFORM one. Row-major puts the lanes on X so s6 = pw;
#       col-major puts them on Y so s6 = ph. Swapping which half lands where transposes all three
#       guards at once — the s_cmp_ge_u32 s9,s7 wave exit, the v_cmp_gt_u32 vcc,s6,v1 lane predicate,
#       and the tile decomposition feeding v1 — because every one of them reads s6 or s7 rather than
#       a width or a height by name.
#
#   Window B (INSIDE the body region, and the reason this file exists):
#       the destination byte offset. Row-major forms s9*pitch + v1*4 (uniform row, per-lane column);
#       col-major must form v1*pitch + s9*4 (per-lane row, uniform column). This is an ADDRESS FORM,
#       not texturing arithmetic, so it is not part of what rung 13 proved — but it does sit after
#       the body marker, which is why tex_list_cm.s cannot claim the character-identical-body
#       property that tex_list.s can. It claims the weaker, still-mechanical property this script
#       enforces: identical to tex_list.s EXCEPT these two declared windows.
#
# ⛔ REGISTER SAFETY OF WINDOW B, DERIVED NOT ASSUMED (and re-checked against the real body):
#   v14 — written first. Dead entering L_HAVE_TEXEL: its last body write feeds a global_load whose
#         s_waitcnt vmcnt(0) has already retired. Live across instruction 3, which touches only v7,
#         v1 and s4.
#   v7  — written third. Dead entering L_HAVE_TEXEL for the same reason.
#   v1  — READ, not written. Nothing writes v1 after the prologue forms it, so it still holds the
#         per-lane coordinate.
#   s9  — never written anywhere in the file (it is the system workgroup-id-y SGPR).
#   The VOP3 v_mul_lo_u32 v7, v1, s4 reads exactly ONE SGPR, inside the constant-bus limit.
# ⚠ Rung 13 lost a burn to precisely this class: a scratch write landed on a still-live v19, the
# clobber wrote ZERO, and the shader read like a dead one. Invisible to the assembler, to the blob,
# and to the host model. Re-derive this list after ANY edit to either file.
#
# Usage:
#   scripts/check/texl-cm-derive.py emit    # write kernel/shaders/tex_list_cm.s
#   scripts/check/texl-cm-derive.py check   # re-derive and diff against the committed file
import sys, os, difflib

MODE = sys.argv[1] if len(sys.argv) > 1 else "check"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "kernel/shaders/tex_list.s")
DST = os.path.join(ROOT, "kernel/shaders/tex_list_cm.s")

MARK = "WAVE-UNIFORM BRANCH ON THE FORMAT WORD"

# ---- the declared substitutions. Each is (old_block, new_block, must_be_unique) -------------------
# ⚠ Every one is matched as an EXACT multi-line block and must occur EXACTLY ONCE. A substitution
# that silently matched zero times would produce a tex_list_cm.s that is a plain copy of tex_list.s —
# i.e. a col-major op that renders row-major — and the picture would be wrong in a way that still
# looks like a picture. Zero matches is therefore a hard error, never a no-op.

WINDOW_P_OLD = """    s_and_b32       s6, s17, 0xFFFF         // pw   ⚠ s6 stops being tile_shift HERE; the body
    s_lshr_b32      s7, s17, 16             // ph      reads s6 as the width, exactly as rung 13 does
"""

WINDOW_P_NEW = """    s_lshr_b32      s6, s17, 16             // ph   ⚠ TRANSPOSED vs tex_list.s: s6 is the PER-LANE
    s_and_b32       s7, s17, 0xFFFF         // pw      bound, and col-major lanes walk Y, so it is
                                            //         the HEIGHT here. s7 is the wave-uniform bound
                                            //         and becomes the WIDTH. Every guard downstream
                                            //         reads s6/s7, never a named width or height,
                                            //         so this one swap transposes all of them.
"""

WINDOW_B_OLD = """    v_mov_b32       v7, s9                  // py
    v_mul_lo_u32    v7, v7, s4              // py * pitch (BYTES)
    v_lshlrev_b32   v14, 2, v1
    v_add_u32       v7, v7, v14
"""

WINDOW_B_NEW = """    v_mov_b32       v14, s9                 // px  (wave-uniform under COLMAJOR)
    v_lshlrev_b32   v14, 2, v14             // px * 4
    v_mul_lo_u32    v7, v1, s4              // py * pitch (BYTES)  -- py is PER-LANE here
    v_add_u32       v7, v7, v14
"""

SYMBOL_SUBS = [
    (".globl tex_list\n", ".globl tex_list_cm\n"),
    (".type tex_list,@function\n", ".type tex_list_cm,@function\n"),
    ("\ntex_list:\n", "\ntex_list_cm:\n"),
    (".amdhsa_kernel tex_list\n", ".amdhsa_kernel tex_list_cm\n"),
]

HEADER_OLD_FIRST_LINE = "// tex_list.s — RUNG 14: N textured primitives in ONE dispatch, op 0x0C GPU_OP_TEX_LIST.\n"
HEADER_NEW_FIRST_LINE = """// tex_list_cm.s — RUNG 14b: op 0x0C GPU_OP_TEX_LIST with the LANE AXIS TRANSPOSED.
//
// ⛔⛔ DO NOT EDIT THIS FILE. It is DERIVED from tex_list.s by scripts/check/texl-cm-derive.py,
// which is also the gate that proves the derivation still holds. Edit tex_list.s (or the two
// declared windows in the derive script) and re-run `texl-cm-derive.py emit`.
//
// ⭐⭐ WHY IT EXISTS, MEASURED NOT ASSUMED. Rung 14's burn (1.56.23) measured 177 ns per LAUNCHED
// wavefront against 22 ns per additional WORKING one — launch dominates 8:1, so the cost is the grid
// you launch, not the pixels you shade. Row-major puts the 64 lanes on X, so a 1-px DOOM wall column
// lights ONE lane and launches ph wavefronts: a 640-column frame is 128000 waves = 24.5 ms of a
// 28.6 ms budget, which cannot draw DOOM. With lanes on Y the same column is ceil(200/64) = 4 waves
// and the frame is 2560 waves = 0.51 ms.
//
// ⛔ THE GUARD BELOW IS NOT FREE, AND THAT IS THE POINT. A wave whose lanes all fail the bound
// still costs a launch — exiting a wave does not make it free. That is why the fix is fewer waves
// rather than a cheaper early-out.
"""


def die(msg):
    print("texl-cm-derive: FAIL -- " + msg)
    sys.exit(1)


def subst(text, old, new, label):
    n = text.count(old)
    if n != 1:
        die("substitution %s matched %d times, expected exactly 1.\n"
            "  A zero match would emit a plain COPY of tex_list.s -- a col-major op rendering\n"
            "  row-major, which still produces a picture. Re-sync the window against tex_list.s."
            % (label, n))
    return text.replace(old, new)


def derive():
    src = open(SRC).read()
    if MARK not in src:
        die("body marker not found in tex_list.s: " + MARK)

    body_start = src.index(MARK)
    # ⚠ PRESENCE FIRST, POSITION SECOND. str.index raises on a miss, and an uncaught traceback is a
    # strictly worse failure than a FAIL line: it reads like the tool broke rather than like the
    # check failed, which is the same defect check.sh's header spends ten lines warning about. Found
    # by mutating tex_list.s on purpose — the first version of this gate crashed instead of failing.
    for blk, label in ((WINDOW_P_OLD, "window P (bound unpack)"),
                       (WINDOW_B_OLD, "window B (destination address)")):
        if blk not in src:
            die("%s no longer appears in tex_list.s VERBATIM.\n"
                "  The shared source drifted under the derivation. Re-sync the window in this script\n"
                "  against tex_list.s, then re-run `texl-cm-derive.py emit`. Expected block:\n%s"
                % (label, "".join("    | " + ln + "\n" for ln in blk.rstrip("\n").split("\n"))))

    # The body-region assertion. Window P must lie ABOVE the marker (it is prologue, free to differ)
    # and window B BELOW it (it is the declared body exception). If either ever migrates across the
    # marker the identity gate's whole story changes, so pin it here rather than discovering it as a
    # confusing diff later.
    if src.index(WINDOW_P_OLD) > body_start:
        die("window P is below the body marker; the transpose story no longer holds")
    if src.index(WINDOW_B_OLD) < body_start:
        die("window B is above the body marker; it would not need declaring as a body exception")

    out = subst(src, HEADER_OLD_FIRST_LINE, HEADER_NEW_FIRST_LINE, "header")
    out = subst(out, WINDOW_P_OLD, WINDOW_P_NEW, "window P (bound unpack)")
    out = subst(out, WINDOW_B_OLD, WINDOW_B_NEW, "window B (destination address)")
    for old, new in SYMBOL_SUBS:
        out = subst(out, old, new, "symbol %r" % old.strip())
    return out


text = derive()

if MODE == "emit":
    open(DST, "w").write(text)
    print("texl-cm-derive: wrote %s (%d lines)" % (DST, text.count("\n")))
    sys.exit(0)

if not os.path.exists(DST):
    die("kernel/shaders/tex_list_cm.s does not exist -- run `texl-cm-derive.py emit`")

have = open(DST).read()
if have == text:
    print("texl-cm-derive: PASS -- tex_list_cm.s is exactly tex_list.s under the two declared windows")
    # ⭐⭐ STAGE 2: THE SHIPPED DWORDS, not just the source text. Identical-except-two-windows source
    # assembled by the same tool SHOULD produce identical-except-two-runs machine code — but "should"
    # is the entire reason the blob-drift gate exists. This proves the two declared source windows
    # produced exactly two dword runs and that NOTHING ELSE MOVED, which is the claim that lets rung
    # 14b inherit rung 13's iron-proven machine code rather than merely its source text.
    #
    # ⛔ THIS CANNOT REUSE texl-body-identity.sh's COMPARATOR. That one asserts the differing dwords
    # form a contiguous PREFIX (len(diff) == hi+1), which is true when the only difference is a
    # prologue. Here there are TWO runs by construction, so that comparator FAILS this pair on a
    # correct pair of files. Reusing it and then "fixing" the failure would mean deleting the check.
    EXPECT_RUNS = [(29, 31), (385, 388)]
    import shutil, subprocess, tempfile, struct
    if shutil.which("llvm-mc") and shutil.which("llvm-objcopy"):
        wd = tempfile.mkdtemp()
        try:
            bins = {}
            for n in ("tex_list", "tex_list_cm"):
                o = os.path.join(wd, n + ".o")
                subprocess.run(["llvm-mc", "-triple=amdgcn-amd-amdhsa", "-mcpu=gfx90c",
                                "-filetype=obj", os.path.join(ROOT, "kernel/shaders", n + ".s"),
                                "-o", o], check=True, capture_output=True)
                b = os.path.join(wd, n + ".bin")
                subprocess.run(["llvm-objcopy", "-O", "binary", "--only-section=.text", o, b],
                               check=True, capture_output=True)
                raw = open(b, "rb").read()
                bins[n] = [struct.unpack_from("<I", raw, i)[0] for i in range(0, len(raw), 4)]
                r = os.path.join(wd, n + ".rod")
                subprocess.run(["llvm-objcopy", "-O", "binary", "--only-section=.rodata", o, r],
                               check=True, capture_output=True)
                bins[n + ".rod"] = open(r, "rb").read()
            a, c = bins["tex_list"], bins["tex_list_cm"]
            if len(a) != len(c):
                die("blob lengths differ: tex_list %d dwords, tex_list_cm %d" % (len(a), len(c)))
            d = [i for i in range(len(a)) if a[i] != c[i]]
            runs = []
            for i in d:
                if runs and i == runs[-1][1] + 1:
                    runs[-1][1] = i
                else:
                    runs.append([i, i])
            runs = [tuple(x) for x in runs]
            if runs != EXPECT_RUNS:
                die("shipped dwords differ in runs %r, expected %r.\n"
                    "  Something moved outside the two declared windows -- the shared body did NOT\n"
                    "  assemble identically, so rung 13's proven machine code is no longer inherited."
                    % (runs, EXPECT_RUNS))
            # ⚠ RSRC1/RSRC2 live in .rodata. If the transpose changed the register footprint the
            # descriptor would move, the PM4 packet would need re-deriving, and "same dispatch path"
            # would quietly become false.
            if bins["tex_list.rod"] != bins["tex_list_cm.rod"]:
                die("the kernel descriptors differ -- RSRC1/RSRC2 moved, so the dispatch path is "
                    "NOT shared and the PM4 setup needs re-deriving")
            shared = len(a) - len(d)
            print("texl-cm-derive: PASS -- %d of %d SHIPPED DWORDS bit-identical to tex_list "
                  "(2 runs: %r), .rodata identical" % (shared, len(a), runs))
        finally:
            shutil.rmtree(wd, ignore_errors=True)
    else:
        print("texl-cm-derive: (dword stage skipped -- llvm-mc/llvm-objcopy absent)")
    sys.exit(0)

print("texl-cm-derive: FAIL -- tex_list_cm.s is NOT the declared derivation of tex_list.s")
print("  Either the shared body drifted, or the transpose was hand-edited. Fix tex_list.s (or the")
print("  windows in this script) and re-run `scripts/check/texl-cm-derive.py emit`.")
print("-" * 64)
for line in list(difflib.unified_diff(text.splitlines(True), have.splitlines(True),
                                      "derived", "committed"))[:60]:
    sys.stdout.write(line)
sys.exit(1)
