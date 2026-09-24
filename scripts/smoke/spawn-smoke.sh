#!/bin/sh
# spawn-smoke.sh — 1.57.6: spawn_path#43 failure codes, per-process spawn arms (#62 redirects and the
# CH_ENDOW endowment) cleared on every failure kind, SPAWN_F_ARGV, SPAWN_F_CLEANFD capture (stdout +
# stderr, 2>&1, an explicitly passed fd, daimon's full shape), execwait#37 multi-redirect, the table-full
# code, and the pipe buffer "last reference anywhere" lifetime.
#
# Issues (closed 1.57.6): docs/development/issues/archived/2026-09-23-spawn-path-failure-gives-no-reason.md,
#         2026-09-23-spawn-path-args-cannot-contain-spaces.md,
#         2026-09-23-child-inherits-every-fd-and-spawn-arms-leak.md.
#
# THREE BOOTS, each banner-gated (a boot with no "AGNOS kernel v" is VOID, never scored):
#   A  SPAWN_SELFTEST=1 PIPE_RC_SELFTEST=1 kernel — the kernel-side PURE checks (core/selftests.cyr,
#      after the proc-table bootstrap): codes, arm clears, #62 ops, placement re-checks, CLEANFD shaping,
#      the argv validator, per-process isolation + slot reuse, pipe lifetime with address-specific free
#      checks, #37's restore dropping a child-made sole pipe once, an orphan zombie's table released on
#      slot reuse, the CLEANFD global-table teardown, and PIPE_RC_SELFTEST. Dwells on `spawnk: done`.
#   B  PLAIN kernel, -smp 1 — tests/spawn/spawnx.cyr seeded as /bin/agnsh (kybernet runs it IF=1
#      time-sliced, so its #43 children really run concurrently). Dwells on `SPAWNX-DONE`. Also the
#      only deterministic run of SPAWNX-LOADER-CELLS-CLEAN (a stale per-CPU cell needs the same CPU).
#   C  PLAIN kernel, -smp 4 — the same program with the APs scheduling (smp_sched_aps=1): the per-CPU
#      arms this cut replaced leaked exactly under migration, so a -smp 1 pass alone is not enough.
#
# Env: SPAWN_SMP="1 4" (which ring-3 boots to run), SPAWN_KERNEL=<path> (use a PREBUILT kernel for the
# ring-3 boots and skip boot A — how the 1.57.5 control is run), QEMU_TIMEOUT (ring-3 dwell, default 300).
# Exit: 0 all PASS · 1 any FAIL · 2 VOID (a boot never handed off). Leaves a PLAIN build in build/agnos.
set -u
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== spawn smoke (#43 codes / per-process arms / ARGV / CLEANFD / pipe lifetime) ==="
ring3_seed_init || exit 1
command -v cyrius >/dev/null 2>&1 || { echo "  ERROR: cyrius not found — this gate measured NOTHING"; exit 1; }

WORK="$ROOT/build/spawn-smoke"; LOGS="$ROOT/build/spawn-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

# ⛔ REBUILD THE TEST PROGRAM EVERY RUN (the stale-artifact lesson: fork-smoke seeded a stale forker for
# months). One binary plays every role: /bin/agnsh (the parent) and /bin/spawnx (the children).
echo "Building tests/spawn/spawnx (--agnos)..."
( cd "$ROOT/tests/spawn" && cyrius build --agnos spawnx.cyr build/spawnx ) > "$LOGS/spawnx-build.log" 2>&1 \
    || { echo "  ERROR: spawnx build failed (see $LOGS/spawnx-build.log)"; exit 1; }
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$ROOT/tests/spawn/build/spawnx" "$SEED/bin/agnsh"
cp "$ROOT/tests/spawn/build/spawnx" "$SEED/bin/spawnx"
# /bin/notelf: 200 bytes of text (>= 64 B, no ELF magic -> -SPAWN_E_NOEXEC); /bin/tiny: 10 bytes (< 64 B).
i=0; : > "$SEED/bin/notelf"
while [ "$i" -lt 20 ]; do printf 'not an elf' >> "$SEED/bin/notelf"; i=$((i + 1)); done
printf 'tinyfile!\n' > "$SEED/bin/tiny"

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qF -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }
# An EXACT LINE. `want` is a substring match, and a failure line that echoes captured text would satisfy it —
# the 1.57.5 control printed `SPAWNX-ARM-CROSSED-PROCESSES captured=16 text=SPAWNX-HELLO-c1`, and a
# substring check scored "c1 reached the console" PASS on exactly the run where c1's output was stolen.
wantx() { if strings "$LOG" | tr -d '\r' | grep -qxF -- "$1"; then ok "$2"; else bad "$2 (no line that is exactly: $1)"; fi; }

# ───────────────────────── boot A: the kernel block ─────────────────────────
if [ -z "${SPAWN_KERNEL:-}" ]; then
    echo "Building SPAWN_SELFTEST=1 PIPE_RC_SELFTEST=1 kernel..."
    SPAWN_SELFTEST=1 PIPE_RC_SELFTEST=1 sh "$ROOT/scripts/build.sh" > "$LOGS/build-A.log" 2>&1 \
        || { echo "  ERROR: kernel build failed (see $LOGS/build-A.log)"; exit 1; }
    cp "$ROOT/build/agnos" "$WORK/agnos-A"
    ring3_seed_image "$WORK/A.img" "$WORK/agnos-A" "$SEED" "AGNOS-SPAWNK" || { echo "  ERROR: image A"; exit 1; }
    LOG="$LOGS/A-kernel-block.log"
    echo "Boot A (kernel block, -smp 1)..."
    ring3_seed_boot "$WORK/A.img" "$LOG" "spawnk: done" "${QEMU_TIMEOUT_A:-120}" "$WORK"
    if [ $? -eq 2 ]; then void=$((void + 1)); else
        strings "$LOG" | grep -E "spawnk:|piperc:" | sed 's/^/    /'
        want "spawnk: elf codes OK"                                   "loader codes: missing -4, not-ELF -5, <64 B -5, a directory -4"
        want "spawnk: #43 refusal codes + arm clear OK"               "#43 refusals return their codes and clear BOTH arms (11 kinds, PTY flag incl.)"
        want "spawnk: #37 refusal clears arms OK"                     "#37 refusals (long line, bad range, 17 tokens) clear the arms"
        want "spawnk: #62 ops OK"                                     "#62 op 0 replace / ADD / re-point / cap 4 / CLEAR / refusals"
        want "spawnk: redirect onto endowed fd refused OK"            "REDIR_ADD onto the armed endowment fd is refused"
        want "spawnk: CH_ENDOW(-1) disarms OK"                        "CH_ENDOW(-1) disarms"
        want "spawnk: CH_CLOSE of the armed end disarms OK"           "CH_CLOSE of the armed endpoint disarms"
        want "spawnk: placement re-checks owner + epoch OK"           "placement refuses a stolen / re-minted endpoint, places the honest one"
        want "spawnk: clean shape refused on global table OK"         "CLEANFD refuses a child on the global fd table"
        want "spawnk: clean shape + 2>&1 + fd pass + endowed-fd skip OK" "CLEANFD keeps exactly 0/1/2 + passed fds; parent untouched; placed fd skipped"
        want "spawnk: argv blob validator OK"                         "sc_argv_blob_ok + the line-token counter"
        want "spawnk: per-process arms isolated + reset on slot reuse OK" "arms are per-pid and a recycled slot starts empty"
        want "spawnk: caller's own slot keeps its arms OK"            "the boot degenerate case (caller handed its own slot) keeps its arms"
        want "spawnk: pipe outlives owner close OK"                   "a pipe buffer outlives its owner's closes while a child holds it"
        want "spawnk: pipe freed by its last reference, exactly once OK" "every order frees exactly once; create-failure no longer double-frees"
        want "spawnk: #37 restore drops a child-made sole pipe exactly once OK" "#37 restore frees a pipe only the child's redirected slot named, once"
        want "spawnk: orphan zombie's fd table + sole pipe released on slot reuse OK" "an orphan zombie's table and its sole pipe are freed when its slot is reused"
        want "spawnk: CLEANFD child on the global table torn down (-3), legacy kept OK" "#43 step (f): CLEANFD child on the global fallback torn down (-3); legacy kept"
        want "spawnk: ALL PASS"                                       "kernel block verdict"
        deny "spawnk: FAIL"                                           "no kernel-block FAIL line"
        want "piperc: buffer FREED OK"                                "PIPE_RC_SELFTEST (first runner): the last close frees exactly once"
        want "piperc: double-close safe"                              "PIPE_RC_SELFTEST: a double close frees nothing (heap_frees unchanged)"
        deny "piperc: (FAIL|LEAK|freed too EARLY|create FAIL)"        "no PIPE_RC_SELFTEST failure line"
        deny "$SMOKE_INVARIANT_DENY"                                  "no latched kernel invariant line (non-ready pick, out-of-band asserts, kstack_check_entry, #DF)"
    fi
    echo "Building the PLAIN kernel for the ring-3 boots..."
    sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed"; exit 1; }
    RING3_KERNEL="$WORK/agnos-plain"
    cp "$ROOT/build/agnos" "$RING3_KERNEL"
else
    RING3_KERNEL="$SPAWN_KERNEL"
    echo "Using the PREBUILT kernel $RING3_KERNEL for the ring-3 boots (boot A skipped)."
fi

# ───────────────────────── boots B / C: tests/spawn as /bin/agnsh ─────────────────────────
ring3_seed_image "$WORK/R.img" "$RING3_KERNEL" "$SEED" "AGNOS-SPAWNX" || { echo "  ERROR: ring-3 image"; exit 1; }
for smp in ${SPAWN_SMP:-1 4}; do
    LOG="$LOGS/ring3-smp$smp.log"
    echo "Boot (ring 3, -smp $smp)..."
    cp "$WORK/R.img" "$WORK/R-$smp.img"
    ring3_seed_boot "$WORK/R-$smp.img" "$LOG" "SPAWNX-DONE" "${QEMU_TIMEOUT:-300}" "$WORK" -smp "$smp"
    if [ $? -eq 2 ]; then void=$((void + 1)); continue; fi
    strings "$LOG" | grep -E "SPAWNX-|proc: the process table" | sed 's/^/    /'
    echo "  -- -smp $smp verdicts --"
    want "SPAWNX-ENOENT-OK"               "[smp$smp] #43 missing file -> -4 NOENT"
    want "SPAWNX-ENOEXEC-OK"              "[smp$smp] #43 not an ELF -> -5 NOEXEC"
    want "SPAWNX-ENOEXEC-TINY-OK"         "[smp$smp] #43 a 10-byte file -> -5 NOEXEC"
    want "SPAWNX-EARGS-LINE-OK"           "[smp$smp] #43 a 200-byte line -> -6 ARGS"
    want "SPAWNX-EARGS-17TOK-OK"          "[smp$smp] #43 a 17-token line is REFUSED (-6), not truncated"
    want "SPAWNX-37-17TOK-OK"             "[smp$smp] #37 a 17-token line is REFUSED (-1)"
    want "SPAWNX-16TOK-OK"                "[smp$smp] a 16-token line still runs with argc 16"
    for k in ARGS-LONG ARGS-17TOK ARGS-FLAG NOENT NOEXEC 37-LONG 37-17TOK 37-NOENT 37-EMPTY NOPROC; do
        want "SPAWNX-ARMS-CLEARED-$k-OK"   "[smp$smp] failure kind $k clears the redirect AND the endowment"
    done
    for k in 3-SIZE0 3-RANGE 3-TOOBIG 3-NOTELF; do
        want "SPAWNX-ARMS-CLEARED-$k-ENDOW-ONLY-OK" "[smp$smp] failed spawn#3 ($k) clears the endowment and leaves the #62 redirect armed"
    done
    want "SPAWNX-ARM-PER-PROCESS-OK"      "[smp$smp] another process's spawn cannot consume this process's arm"
    wantx "SPAWNX-HELLO-c1"               "[smp$smp] the helper's child printed to the CONSOLE (not the parent's pipe)"
    want "SPAWNX-PTY-ENDOW-OK"            "[smp$smp] PTY-mode endowment + CLEANFD: the child's fd 0/1/2 are the channel"
    want "SPAWNX-ARGV-OK"                 "[smp$smp] ARGV: an argument with a space and an EMPTY argument round-trip"
    want "SPAWNX-ARGV-LONG-OK"            "[smp$smp] ARGV: a 900-byte blob with a 700-byte argument"
    want "SPAWNX-ARGV-REFUSE-17-OK"       "[smp$smp] ARGV: 17 entries -> -6"
    want "SPAWNX-ARGV-REFUSE-NONUL-OK"    "[smp$smp] ARGV: no trailing NUL -> -6"
    want "SPAWNX-ARGV-REFUSE-EMPTY0-OK"   "[smp$smp] ARGV: empty argv[0] -> -6"
    want "SPAWNX-FLAG-REFUSE-OK"          "[smp$smp] an unknown flag bit -> -6"
    want "SPAWNX-ENV-STRICT-OK"           "[smp$smp] flagged form + a bad env blob -> -6 (strict)"
    want "SPAWNX-LOADER-CELLS-CLEAN-OK"   "[smp$smp] that refusal left no stale NUL-split cell: the next #37 line keeps argc 4"
    want "SPAWNX-ENV-ARGV-OK"             "[smp$smp] flagged form + a good env blob reaches the child"
    want "SPAWNX-ENV-LEGACY-FALLBACK-OK"  "[smp$smp] the legacy form keeps the default-env fallback"
    want "SPAWNX-CAPTURE-STDOUT-OK"       "[smp$smp] CLEANFD: stdout captured"
    want "SPAWNX-CAPTURE-STDERR-OK"       "[smp$smp] CLEANFD: stderr captured"
    want "SPAWNX-CLEAN-OK"                "[smp$smp] CLEANFD: the child holds NO other fd (pipes, ext2 fd dropped)"
    want "SPAWNX-LEGACY-INHERITS"         "[smp$smp] control: the legacy form still inherits the parent's fds"
    want "SPAWNX-FDPASS-OK"               "[smp$smp] CLEANFD + an explicitly passed fd (fd 5)"
    want "SPAWNX-DUP21-OK"                "[smp$smp] CLEANFD + 2>&1 (ADD 2 <- 1)"
    want "SPAWNX-DAIMON-SHAPE-OK"         "[smp$smp] daimon's shape: ARGV + CLEANFD + endowment + env + capture"
    want "SPAWNX-ENDOW-DISARM-OK"         "[smp$smp] CH_ENDOW(-1) disarms from ring 3"
    want "SPAWNX-REDIR-CLEAR-OK"          "[smp$smp] #62 REDIR_CLEAR from ring 3"
    want "SPAWNX-37-MULTI-OK"             "[smp$smp] #37 applies two redirects and restores them"
    want "SPAWNX-37-PARENT-STDOUT-OK"     "[smp$smp] #37's caller keeps its own stdout"
    want "SPAWNX-PIPE-NO-CROSSTALK"       "[smp$smp] a child writing into a closed pipe cannot reach the parent's next pipe"
    want "SPAWNX-ENOPROC-OK"              "[smp$smp] a full process table -> exactly -2 NOPROC"
    want "proc: the process table is full and this spawn was refused" "[smp$smp] the kernel said why"
    want "SPAWNX-SLEEPERS-REAPED"         "[smp$smp] closing s_w ended every CLEANFD sleeper; all reaped"
    deny "SPAWNX-ARMS-LEAKED|SPAWNX-[A-Z0-9-]*-BAD|CHANPROBE-ACCEPTED|SPAWNX-ARM-CROSSED|SPAWNX-PIPE-CROSSTALK|SPAWNX-SLEEPERS-TIMEOUT|SPAWNX-VOID|SPAWNX-UNKNOWN-ROLE|SPAWNX-CHILD-NO-ROLE" "[smp$smp] no failure line"
    deny "kybernet: emergency shell"      "[smp$smp] /bin/agnsh (spawnx) exited 0 — no emergency shell"
    deny "$SMOKE_INVARIANT_DENY"          "[smp$smp] no latched kernel invariant line (non-ready pick, out-of-band asserts, kstack_check_entry, #DF)"
    want "SPAWNX-DONE"                    "[smp$smp] the program ran to its end"
    if strings "$LOG" | grep -q "SPAWNX-DONE pass=[0-9]* fail=0"; then ok "[smp$smp] SPAWNX-DONE fail=0"; else bad "[smp$smp] SPAWNX-DONE reports failures (or is absent)"; fi
done

# Leave the tree on a PLAIN production kernel (boot A built a flag kernel).
if [ -z "${SPAWN_KERNEL:-}" ]; then
    sh "$ROOT/scripts/build.sh" >/dev/null 2>&1
fi

echo ""
echo "=== spawn-smoke: $pass passed, $fail failed, $void void ==="
if [ "$fail" -ne 0 ]; then echo "spawn-smoke: FAIL"; exit 1; fi
if [ "$void" -ne 0 ]; then echo "spawn-smoke: VOID (a boot never handed off — infrastructure, not the kernel)"; exit 2; fi
echo "spawn-smoke: PASS"
exit 0
