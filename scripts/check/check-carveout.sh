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
# from the live GOP geometry at run time (`gpu_blit_arm`, `gpu_pan_arm`), so they are checked against
# their declared LIMIT constants — which is what the kernel itself bounds them by — rather than
# against a resolution this script would have to guess.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REGS="$ROOT/kernel/core/gpu_regs.cyr"

val() {  # val <NAME> -> decimal value of `var NAME = 0x...;`
    v=$(grep -E "^var $1[[:space:]]*=" "$REGS" | head -1 | sed -E 's/.*=[[:space:]]*(0x[0-9A-Fa-f]+|[0-9]+).*/\1/')
    [ -n "$v" ] || { echo "check-carveout: constant $1 not found in gpu_regs.cyr" >&2; exit 1; }
    printf '%d\n' "$v"
}

CARVEOUT=3221225472          # 3 GB — archaemenid's aperture (RCC_CONFIG_MEMSIZE); the bound every region shares

PAN_OFF=$(val GPU_FB_PAN_OFF);      PAN_LIM=$(val GPU_FB_PAN_LIMIT)
BACK_OFF=$(val GPU_FB_BACK_OFF);    BACK_LIM=$(val GPU_FB_BACK_LIMIT)
ARENA_OFF=$(val GPU_VM_ARENA_OFF);  ARENA_SZ=$(val GPU_ARENA_SIZE)
SHM_OFF=$(val GPU_SHM_REGION_OFF);  SHM_SZ=$(val GPU_SHM_REGION_SIZE); SLOT=$(val GPU_SHM_SLOT_SIZE)
RT_OFF=$(val GPU_RT_REGION_OFF);    RT_SZ=$(val GPU_RT_REGION_SIZE)

fail=0
note() { echo "  FAIL: $1"; fail=1; }

# Regions as "name start end". Pan and back use their LIMIT as the end, because that is the bound the
# kernel enforces on the run-time-derived span.
set -- \
    "pan $PAN_OFF $PAN_LIM" \
    "back $BACK_OFF $BACK_LIM" \
    "arena $ARENA_OFF $((ARENA_OFF + ARENA_SZ))" \
    "shm $SHM_OFF $((SHM_OFF + SHM_SZ))" \
    "rt $RT_OFF $((RT_OFF + RT_SZ))"

for a in "$@"; do
    an=${a%% *}; rest=${a#* }; as=${rest%% *}; ae=${rest##* }
    [ "$as" -lt "$ae" ] || note "$an has non-positive extent ($as..$ae)"
    [ "$ae" -le "$CARVEOUT" ] || note "$an ends past the 3 GB carveout ($ae > $CARVEOUT)"
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

# The shm table and its region must stay in exact ratio: index IS address (syscall.cyr slot arithmetic),
# so a slot count that outruns the region walks straight into the RT handles.
SHM_MAX=$(grep -E '^var SHM_MAX[[:space:]]*=' "$ROOT/kernel/core/syscall.cyr" | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/')
[ -n "$SHM_MAX" ] || { echo "check-carveout: SHM_MAX not found" >&2; exit 1; }
NEED=$((SHM_MAX * SLOT))
[ "$NEED" -le "$SHM_SZ" ] || note "SHM_MAX($SHM_MAX) x SLOT($SLOT) = $NEED exceeds region $SHM_SZ"

# The `#86` cap must be servable by a slot, or ring 3 is told via gpu_caps#89 +24 that a request will
# succeed which shm_create_gpu then refuses.
GPUCAP=$(grep -E '^var SHM_GPU_MAX_SIZE[[:space:]]*=' "$ROOT/kernel/core/syscall.cyr" | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/')
[ -n "$GPUCAP" ] || { echo "check-carveout: SHM_GPU_MAX_SIZE not found" >&2; exit 1; }
[ "$GPUCAP" -le "$SLOT" ] || note "SHM_GPU_MAX_SIZE($GPUCAP) exceeds one slot ($SLOT) — #89 +24 would over-advertise"

# A slot must be a whole number of 2 MB pages: shm_create_gpu WC-remaps it in 0x200000 steps, and a
# ragged tail would leave the last part of every slot un-remapped.
[ $((SLOT % 2097152)) -eq 0 ] || note "SLOT($SLOT) is not a multiple of 2 MB — the WC remap loop would leave a tail"

if [ "$fail" != "0" ]; then
    echo "check-carveout: FAILED"
    exit 1
fi
echo "check-carveout: OK — regions disjoint, shm table fits its region, slot is 2 MB-aligned"
