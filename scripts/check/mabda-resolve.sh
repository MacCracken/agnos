#!/bin/sh
# mabda-resolve.sh — make sure the sibling mabda checkout the sovereign-encoder oracles include is
# actually there, cloning the pinned tag when it is not.
#
# ⛔ WHY THIS EXISTS. `tests/gpu/edgeasm.cyr` and `tests/gpu/asmagree.cyr` carry agnos's entire
# "we have a sovereign gfx9 encoder" claim — they are cited BY NAME at `shader-blob.sh:13` and
# `burn-prep.sh:377`. Both included `../../mabda/src/gfx9_encode.cyr`, which from `tests/gpu/`
# resolves to `<agnos>/mabda` — a directory that has never existed in this repo. Neither file
# compiled, neither was in `host-gpu-oracles.sh`'s loop, and nothing under `.github/workflows/`
# invokes `check.sh` at all. The claim rested on two files that had never been built. Fixed at
# 1.56.44 together with this script and a CI step, because fixing the path alone would leave the
# same hole: green on this box, unrun everywhere else.
#
# ⚠ THE LOCATION IS FIXED BY THE INCLUDE, so there is deliberately NO `MABDA_DIR` override here.
# `include` bakes its relative path into the source; unlike the kashi block at `scripts/build.sh:22`
# — which cats a file from a shell variable and CAN be redirected — an env var could not move where
# the compiler looks. Offering one would be a knob that silently does nothing. Only the REF is
# overridable, and only for the clone fallback.
#
# ⚠ Pinned at 4.0.8, verified a real git tag matching mabda's own `VERSION` on 2026-08-13. Bump as
# mabda cuts releases — §2 of the shader-pipeline plan lands `gfx9_rsrc1_ex` in 4.1.0, and the four
# named opcode constants with it. Re-verify tag-vs-VERSION at every bump: this tree has shipped a
# manifest declaring a tag whose sibling working copy had already moved past it.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# tests/gpu/*.cyr include "../../../mabda/src/..." — three levels up from tests/gpu is the parent of
# agnos, so the sibling checkout is the only place the compiler will look. Keep these in step.
MABDA_DIR="$ROOT/../mabda"
MABDA_REF="${MABDA_REF:-4.0.8}"

if [ ! -f "$MABDA_DIR/src/gfx9_encode.cyr" ]; then
    echo "  mabda not at $MABDA_DIR — cloning $MABDA_REF for the sovereign-encoder oracles..." >&2
    rm -rf "$MABDA_DIR"
    git clone --quiet --depth 1 --branch "$MABDA_REF" \
        https://github.com/MacCracken/mabda.git "$MABDA_DIR" >&2 || {
        echo "ERROR: mabda clone failed (ref=$MABDA_REF)" >&2
        exit 1
    }
fi

# ⛔ Assert the two files the oracles include, not just the directory. A partial or renamed checkout
# would otherwise pass here and fail as an opaque "cannot open include file" inside a build the
# runner reports as an ORACLE failure — a tooling problem wearing a correctness problem's clothes,
# which is exactly the confusion host-gpu-oracles.sh's own header warns about.
for f in src/gfx9_encode.cyr src/gfx9_abi.cyr; do
    [ -f "$MABDA_DIR/$f" ] || {
        echo "ERROR: mabda checkout at $MABDA_DIR is missing $f" >&2
        exit 1
    }
done

# Report what we actually resolved. A version printed at gate time is how a wrong pin gets noticed;
# `path`-style sibling resolution tracks the local WORKING TREE, so the tag above is a fallback
# default and NOT proof of what just got compiled.
if [ -f "$MABDA_DIR/VERSION" ]; then
    echo "mabda-resolve: OK — $MABDA_DIR (VERSION $(cat "$MABDA_DIR/VERSION"), pin $MABDA_REF)"
else
    echo "mabda-resolve: OK — $MABDA_DIR (no VERSION file, pin $MABDA_REF)"
fi
