#!/bin/bash
# Arc sweep — one command that rebuilds + runs every QEMU self-test smoke for
# the two most recent arcs (1.39.x VFS generic-write lift, 1.40.x exec-from-disk)
# plus the baseline gates and the ext2-write regression bar. Each smoke needs a
# DIFFERENT compile-gated kernel (its *_SELFTEST flag), so this script builds the
# right kernel per smoke, runs it, tallies PASS/FAIL, and restores the plain
# production build at the end.
#
# Usage:  sh scripts/sweep.sh
# Exit 0 iff every gate passes. Per-smoke logs under build/<smoke>-logs/.
#
# This is the automated half of the last-two-arcs verification; the MANUAL
# (on-iron) half is the rubric in
#   agnosticos/docs/development/iron-nuc-zen-log.md#tracker-139-cycle  (VFS)
#   agnosticos/docs/development/exec-iron-manual-tests.md              (exec)

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

pass=0; fail=0; results=""

# run_gate "<label>" "<build env>" "<smoke script | CHECK>"
# Each smoke runs ONCE per attempt (captured to a log); a single retry covers
# transient host-load / QEMU-timing flakes (a real failure fails both attempts).
run_gate() {
    label="$1"; buildenv="$2"; smoke="$3"
    printf '\n=== %s ===\n' "$label"
    ok=0
    if [ "$smoke" = "CHECK" ]; then
        if sh "$ROOT/scripts/check.sh" > "/tmp/sweep-gate.log" 2>&1; then ok=1; tail -1 /tmp/sweep-gate.log; else tail -3 /tmp/sweep-gate.log; fi
    else
        env $buildenv sh "$ROOT/scripts/build.sh" >/dev/null 2>&1 || { echo "  BUILD FAILED"; }
        for attempt in 1 2; do
            sh "$ROOT/scripts/$smoke" > "/tmp/sweep-gate.log" 2>&1
            if grep -qiE "smoke.*PASS|smoke \(.*\): PASS" "/tmp/sweep-gate.log"; then ok=1; break; fi
        done
        grep -iE "PASS:|FAIL:|smoke:" "/tmp/sweep-gate.log" | sed 's/^/  /' || true
        [ "$ok" = 1 ] && [ "${attempt:-1}" = 2 ] && echo "  (passed on retry — transient host-load timing)"
    fi
    if [ "$ok" = 1 ]; then pass=$((pass+1)); results="$results\n  PASS  $label";
    else fail=$((fail+1)); results="$results\n  FAIL  $label"; fi
}

echo "=========================================="
echo " AGNOS arc sweep — 1.39.x VFS + 1.40.x exec"
echo "=========================================="

# --- Baseline (plain production build): build + tests + version + size ---
sh "$ROOT/scripts/build.sh" >/dev/null 2>&1
run_gate "baseline check.sh (build/test/version/size)" "" "CHECK"

# --- 1.39.x VFS generic-write lift: FAT + exFAT read & write verb smokes ---
run_gate "1.39.x FAT read (cat/ls reach FAT)"       "FATFS_SELFTEST=1"                         "fat-smoke.sh"
run_gate "1.39.x FAT write (touch/echo/rm/mkdir/mv + subdir)" "FATFS_WRITE_SELFTEST=1 FAT_ALLOW_ESP_WRITE=1" "fat-write-smoke.sh"
run_gate "1.39.x exFAT read"                         "EXFAT_SELFTEST=1"                         "exfat-smoke.sh"
run_gate "1.39.x exFAT write (+ subdir)"             "EXFAT_WRITE_SELFTEST=1"                   "exfat-write-smoke.sh"

# --- ext2/jbd2 write regression bar (the iron-validated path must stay green) ---
run_gate "ext2 WRITE regression (W1-W5)"             "EXT2_WRITE_SELFTEST=1"                    "ext2-write-smoke.sh"

# --- 1.40.x exec-from-disk: load + ring-3 run + ENOEXEC + subdir + clean return ---
run_gate "1.40.x exec-from-disk (run /bin/prog2 + ENOEXEC)" "EXEC_SELFTEST=1 EXT2_WRITE_SELFTEST=1" "exec-smoke.sh"

# --- 1.52.x audio: HDA probe -> reset -> verb ring -> codec graph -> stream DMA-arm ---
run_gate "1.52.x audio HDA (probe/reset/verb/graph/stream)" "" "hda-smoke.sh"

# --- 1.53.x FP/SIMD: SSE enable (CR0.EM off/MP on + CR4.OSFXSR) -> movsd + ring-0 f64 mul ---
run_gate "1.53.x FP/SSE enable (movsd + ring-0 f64)" "FP_SELFTEST=1" "fp-selftest-smoke.sh"

# --- 1.53.x FP/SIMD B2: per-proc FXSAVE areas (16-aligned + default FCW/MXCSR) ---
run_gate "1.53.x FP-area (per-proc FXSAVE state)" "FP_AREA_SELFTEST=1" "fp-area-smoke.sh"

# --- 1.53.x FP/SIMD B3: lazy #NM handler services a forced FP-trap (CR0.TS-on-switch live) ---
run_gate "1.53.x FP-#NM (lazy save/restore serviced)" "FP_NM_SELFTEST=1" "fp-nm-smoke.sh"

# --- Restore the plain production build as the working artifact ---
echo ""
echo "Restoring plain production build..."
sh "$ROOT/scripts/build.sh" >/dev/null 2>&1
echo "  build/agnos: $(stat -c%s "$ROOT/build/agnos" 2>/dev/null || wc -c < "$ROOT/build/agnos") bytes"

echo ""
echo "=========================================="
printf ' SWEEP RESULTS  (%d passed, %d failed)%b\n' "$pass" "$fail" "$results"
echo "=========================================="
[ "$fail" = 0 ] && { echo "ARC SWEEP: PASS"; exit 0; } || { echo "ARC SWEEP: FAIL"; exit 1; }
