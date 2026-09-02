#!/bin/sh
# check-carveout.sh — the GPU carveout's top-level regions must not overlap, and each must lie inside
# the carveout.
#
# ⛔⛔ WHY THIS EXISTS. `check-arena.sh` gates the *_SUBOFF slots INSIDE the 2 MB compute arena, and its
# own comment records that a value-only check missed a live collision because "two slots do not need
# the same START to collide, only a shared BYTE". The TOP-LEVEL regions — console FB, pan, back
# buffers, PSP TMR, arena, shm, RT — had NO such gate at all. They are hand-placed hex constants in
# gpu_regs.cyr whose disjointness was argued in comments and checked by nobody.
#
# ⚠ VM_CONTEXT0 is disabled for these regions, so there are no page tables: an overlap is not a fault,
# it is two subsystems silently writing each other's bytes. 1.56.44 MOVED the shm region
# (0xA0000000 -> 0x90000000) and doubled it to 512 MB; that is exactly the change this gate should
# have existed for, so it is added with it rather than after the first corruption.
#
# ⚠ Sizes are DERIVED where the kernel derives them. The console FB, pan and back buffers are sized
# from the live GOP geometry at run time (`gpu_blit_arm`, `gpu_pan_arm`), so pan and back are checked
# against their declared LIMIT constants — which is what the kernel itself bounds them by — rather
# than against a resolution this script would have to guess. The console FB declares no such LIMIT,
# so only its BASE is checkable here; see the note at the offset-0 assertion below for why this gate
# refuses to invent an end for it.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REGS="$ROOT/kernel/core/gpu_regs.cyr"

# val <NAME> -> decimal value of `var NAME = 0x...;`
# ⛔ THE EXTRACTION IS ANCHORED ON THE NAME AND TAKES THE FIRST `=`, AND THAT IS NOT STYLE. It used to
# be `sed -E 's/.*=[[:space:]]*(0x[0-9A-Fa-f]+|[0-9]+).*/\1/'`, whose leading `.*=` is GREEDY: it lands
# on the LAST `=` of the line, so a trailing COMMENT containing "= <number>" silently wins over the
# declaration. That is not hypothetical — it is what gpu_regs.cyr:930 looks like:
#     var GPU_PSP_TMR_SIZE        = 0x400000;    # TMR = 4 MB (fixed on gfx9/Renoir)
# The greedy form returns **4**, so the PSP TMR would be gated as a FOUR-BYTE region, overlapping
# nothing and proving nothing, while the gate printed OK. A parse that rots does not announce itself;
# it turns the assertion into a no-op and keeps the green line. Measured 2026-09-02: greedy=4,
# anchored=0x400000, on the tree as shipped.
val() {
    v=$(sed -nE "s/^var $1[[:space:]]*=[[:space:]]*(0x[0-9A-Fa-f]+|[0-9]+).*/\1/p" "$REGS" | head -1)
    [ -n "$v" ] || { echo "check-carveout: constant $1 not found in gpu_regs.cyr" >&2; exit 1; }
    printf '%d\n' "$v"
}

CARVEOUT=3221225472          # 3 GB — archaemenid's aperture (RCC_CONFIG_MEMSIZE); the bound every region shares

PAN_OFF=$(val GPU_FB_PAN_OFF);      PAN_LIM=$(val GPU_FB_PAN_LIMIT)
BACK_OFF=$(val GPU_FB_BACK_OFF);    BACK_LIM=$(val GPU_FB_BACK_LIMIT)
TMR_OFF=$(val GPU_PSP_TMR_OFF);     TMR_SZ=$(val GPU_PSP_TMR_SIZE)
ARENA_OFF=$(val GPU_VM_ARENA_OFF);  ARENA_SZ=$(val GPU_ARENA_SIZE)
SHM_OFF=$(val GPU_SHM_REGION_OFF);  SHM_SZ=$(val GPU_SHM_REGION_SIZE); SLOT=$(val GPU_SHM_SLOT_SIZE)
RT_OFF=$(val GPU_RT_REGION_OFF);    RT_SZ=$(val GPU_RT_REGION_SIZE)

fail=0
note() { echo "  FAIL: $1"; fail=1; }

# ⚠ VACUITY / COVERAGE FLOOR. Until 1.56.58 the list below was a HAND-WRITTEN `set --` of FIVE rows
# while the header of this very file named SEVEN regions, and nothing compared the two. The PSP TMR —
# the one region whose own constant (gpu_regs.cyr:936) is annotated "unrecoverable if corrupted" — was
# simply not in the list, so it was gated by nobody. MEASURED on a copy of the tree with
# `var GPU_VM_ARENA_OFF = 0x60000000;`, i.e. the 2 MB compute arena placed exactly on top of the 4 MB
# TMR: this gate printed "OK — regions disjoint" and exited 0. A gate whose oracle is a hand-kept
# SUBSET of the thing it checks does not fail, it looks away — the same shape check-arena.sh records
# one level down, where an unannotated slot had to be REPORTED because "silence is not evidence of
# disjointness".
# ⭐ SO THE LIST IS DERIVED, NOT DECLARED. Every top-level carveout region in gpu_regs.cyr is spelled
# `var <NAME>_OFF = 0x…;`; the arena's INTERNAL slots are `_SUBOFF` and belong to check-arena.sh, and
# `_SUBOFF` does not match `_OFF`, so the two gates cannot steal each other's constants. That
# enumeration DRIVES the loop below, so a region added to gpu_regs.cyr and not to the `case` is
# reported by name rather than silently skipped.
# ⚠ AND THE ENUMERATION IS ITSELF FLOORED AND PRINTED, because a derived list rots the same silent way
# a hand-kept one does: rename gpu_regs.cyr, move the constants behind an `#ifdef`, or let the `^var`
# anchor drift, and a zero-row enumeration compares nothing and scores PASS exactly like the five-row
# one did. Six is the count today; a run that reports fewer is reporting that its own enumeration
# broke, not that the carveout is clean.
NAMES=$(sed -nE 's/^var ([A-Za-z0-9_]+_OFF)[[:space:]]*=.*/\1/p' "$REGS" | sort -u)
NREG=$(printf '%s\n' "$NAMES" | grep -c . || true)
if [ "$NREG" -lt 6 ]; then
    echo "check-carveout: FAILED — enumerated $NREG top-level region constant(s) in gpu_regs.cyr;" >&2
    echo "  this gate is vacuous below 6 (pan, back, PSP TMR, arena, shm and RT each declare a *_OFF)." >&2
    echo "  Finding fewer means the enumeration broke, not that the regions are disjoint." >&2
    exit 1
fi

# Regions as "name start end". Pan and back use their LIMIT as the end, because that is the bound the
# kernel enforces on the run-time-derived span; the rest carry an explicit SIZE.
# ⚠ NOT `for n in $NAMES`. That leans on unquoted word splitting, which ZSH DOES NOT DO by default —
# toolchain-pin-check.sh records its newline-separated list collapsing into ONE word under zsh and the
# gate then reporting a clean tree as drift. The heredoc reads the list the same way in every shell,
# and (unlike a pipe into `while read`) runs the body in THIS shell, so `set --` and `note` stick.
set --
while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$n" in
        GPU_FB_PAN_OFF)     set -- "$@" "pan $PAN_OFF $PAN_LIM" ;;
        GPU_FB_BACK_OFF)    set -- "$@" "back $BACK_OFF $BACK_LIM" ;;
        GPU_PSP_TMR_OFF)    set -- "$@" "psp_tmr $TMR_OFF $((TMR_OFF + TMR_SZ))" ;;
        GPU_VM_ARENA_OFF)   set -- "$@" "arena $ARENA_OFF $((ARENA_OFF + ARENA_SZ))" ;;
        GPU_SHM_REGION_OFF) set -- "$@" "shm $SHM_OFF $((SHM_OFF + SHM_SZ))" ;;
        GPU_RT_REGION_OFF)  set -- "$@" "rt $RT_OFF $((RT_OFF + RT_SZ))" ;;
        *) note "$n is a top-level carveout region with no extent rule in this gate — UNCHECKED" ;;
    esac
done <<REGIONS
$NAMES
REGIONS

for a in "$@"; do
    an=${a%% *}; rest=${a#* }; as=${rest%% *}; ae=${rest##* }
    [ "$as" -lt "$ae" ] || note "$an has non-positive extent ($as..$ae)"
    [ "$ae" -le "$CARVEOUT" ] || note "$an ends past the 3 GB carveout ($ae > $CARVEOUT)"
    # ⚠ THE CONSOLE FB IS THE SEVENTH REGION AND IT HAS NO ROW, DELIBERATELY. It lives at carveout
    # offset 0 and its span is GOP-derived at run time with NO declared LIMIT constant to check it
    # against — unlike pan and back, which have one. Inventing an end for it ("it stops where the pan
    # buffer starts") would make this gate's oracle a NEIGHBOURING region's constant, which is how a
    # check ends up proving only that it agrees with itself. What is checkable without inventing
    # anything is its BASE: offset 0 is the console FB's first byte, so no other region may claim it.
    [ "$as" -gt 0 ] || note "$an starts at carveout offset 0 — that is the console FB's base"
    for b in "$@"; do
        bn=${b%% *}; brest=${b#* }; bs=${brest%% *}; be=${brest##* }
        [ "$an" = "$bn" ] && continue
        # Half-open overlap: a.start < b.end && b.start < a.end. Extent-aware, not value-equality —
        # the exact mistake check-arena.sh records having shipped.
        if [ "$as" -lt "$be" ] && [ "$bs" -lt "$ae" ]; then
            note "$an [$as,$ae) overlaps $bn [$bs,$be)"
        fi
    done
done

# scval <NAME> -> decimal value of `var NAME = <n>;` in syscall.cyr. Anchored for the SAME reason
# `val` above is, and here the greedy form was not a latent hazard but a LIVE no-op: the cap's own
# comment (syscall.cyr:1212) reads
#     var SHM_GPU_MAX_SIZE = 33554432;    # 32 MB — `#86` only: one GPU carveout slot (3840x2160 = 33,177,600 B)
# and the last `=` on that line belongs to "3840x2160 = 33,177,600". The greedy sed captured **33**,
# so the "cap must fit a slot" assertion below has been comparing 33 against 33,554,432 — true for any
# cap ever written, i.e. an assertion that could not fail. Measured 2026-09-02: greedy=33,
# anchored=33554432. SHM_MAX (line 1205, no comment) parsed correctly either way, which is exactly why
# nobody noticed: half the extractor worked.
scval() {
    v=$(sed -nE "s/^var $1[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p" "$ROOT/kernel/core/syscall.cyr" | head -1)
    [ -n "$v" ] || { echo "check-carveout: $1 not found in syscall.cyr" >&2; exit 1; }
    printf '%s\n' "$v"
}

# The shm table and its region must stay in exact ratio: index IS address (syscall.cyr slot arithmetic),
# so a slot count that outruns the region walks straight into the RT handles.
SHM_MAX=$(scval SHM_MAX)
NEED=$((SHM_MAX * SLOT))
[ "$NEED" -le "$SHM_SZ" ] || note "SHM_MAX($SHM_MAX) x SLOT($SLOT) = $NEED exceeds region $SHM_SZ"

# The `#86` cap must be servable by a slot, or ring 3 is told via gpu_caps#89 +24 that a request will
# succeed which shm_create_gpu then refuses.
GPUCAP=$(scval SHM_GPU_MAX_SIZE)
[ "$GPUCAP" -le "$SLOT" ] || note "SHM_GPU_MAX_SIZE($GPUCAP) exceeds one slot ($SLOT) — #89 +24 would over-advertise"

# A slot must be a whole number of 2 MB pages: shm_create_gpu WC-remaps it in 0x200000 steps, and a
# ragged tail would leave the last part of every slot un-remapped.
[ $((SLOT % 2097152)) -eq 0 ] || note "SLOT($SLOT) is not a multiple of 2 MB — the WC remap loop would leave a tail"

if [ "$fail" != "0" ]; then
    echo "check-carveout: FAILED"
    exit 1
fi
# ⚠ THE COUNT IS PRINTED, not implied. "6 top-level regions" is the gate reporting how much it
# actually compared; a green line that says "2 top-level regions" is a broken enumeration confessing.
echo "check-carveout: OK — $NREG top-level regions disjoint (derived from gpu_regs.cyr), shm table fits its region, slot is 2 MB-aligned"
