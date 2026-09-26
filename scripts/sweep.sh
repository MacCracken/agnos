#!/bin/bash
# Arc sweep — one command that rebuilds + runs every QEMU self-test smoke for
# the two most recent arcs (1.39.x VFS generic-write lift, 1.40.x exec-from-disk)
# plus the baseline gates and the ext2-write regression bar. Each smoke needs a
# DIFFERENT compile-gated kernel (its *_SELFTEST flag), so this script builds the
# right kernel per smoke, runs it, tallies PASS/FAIL, and restores the plain
# production build at the end.
#
# Usage:  sh scripts/sweep.sh                     # 4 workers (1.57.9) — see the PARALLEL block below
#         SWEEP_JOBS=1 sh scripts/sweep.sh        # the serial sweep, exactly as before 1.57.9
#         SWEEP_ONLY='<ERE>' sh scripts/sweep.sh  # only the matching rows (exit 3 = clean, never a verdict)
#         SWEEP_ROW_TIMEOUT=<s> (parallel row ceiling, default 1500) · SWEEP_EXCLUSIVE=0 (pool the exclusive rows)
# Exit 0 iff every gate passes (1 otherwise; 2 = bad SWEEP_JOBS; 130/143 = interrupted). Per-smoke logs under
# build/<smoke>-logs/ (serial) or build/sweep-logs/w<K>/<smoke>-logs/ (parallel: copied back from worker K).
#
# This is the automated half of the last-two-arcs verification; the MANUAL
# (on-iron) half is the rubric in
#   agnosticos/docs/development/iron-nuc-zen-log.md#tracker-139-cycle  (VFS)
#   agnosticos/docs/development/exec-iron-manual-tests.md              (exec)

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ⭐ 1.57.9 (PSWEEP) — THE SWEEP RUNS ITS ROWS IN PARALLEL. SWEEP_JOBS=<N> (default 4) spreads the rows over N
# private COPIES of the current working tree (uncommitted and untracked files included), each with its own build/;
# SWEEP_JOBS=1 is the serial sweep exactly as before (the table calls run_gate -> gate_exec directly and nothing
# below the `--- parallel ---` marker runs). The design and its prior art (GNU make -j/-O, GNU parallel --keep-order/
# {%}/--joblog, pytest-xdist loadgroup, pytest-rerunfailures, Bazel `exclusive`, CTest RESOURCE_LOCK, kselftest
# timeouts) are in docs/development/build.md "Arc sweep". The load-bearing rules:
#   · ISOLATION: every row writes $ROOT/build/agnos (and tests/*/build helpers), so two rows can never share a tree.
#     Worker K is an rsync of $ROOT (minus build/, .git, tmp/) at $ROOT/../.<tree>.sweep.<pid>.w<K> — a SIBLING,
#     so every `${X_ROOT:-$ROOT/../x}` sibling default (gnoboot, agnoshi, kashi, rekha, naad, cyrius-doom) still
#     resolves; the absolute paths are also exported. The baseline build runs once in the main tree first, so a
#     kashi/rekha clone-if-absent never races N ways.
#   · GROUPS: run_gate's optional 4th argument is a group key; rows sharing a key run on ONE worker, in table order
#     (xdist loadgroup). Keyless rows are singleton groups. Workers PULL the next group with an atomic
#     `mkdir claim.<group>`, longest-first by the previous run's build/sweep-logs/durations.tsv.
#     Keys: `hostport` (two rows that pick a host port by bind(0) and release it before QEMU binds — a TOCTOU
#     window), `naad` (the one row that writes a sibling repo's build dir), `waits` (two rows that build
#     tests/waits), and `exclusive` — a row whose oracle is a ratio against wall time runs ALONE, serially, in the
#     main tree after the parallel phase (Bazel `exclusive`; SWEEP_EXCLUSIVE=0 pools them instead).
#     The CHECK row (check.sh needs .git) runs in the MAIN tree, concurrently with the workers, which never
#     touch the main build/.
#   · RESULTS THROUGH FILES: a worker is another process, so run_gate's pass/fail/results globals cannot be
#     updated from it. Each row leaves <n>.out (its section text) and <n>.res (rc, seconds, worker); the main
#     process prints the sections in ROW ORDER (make -O / parallel --keep-order) and tallies. Summary, exit codes
#     and SWEEP_ONLY are unchanged.
#   · SERIAL RETRY, NEVER SILENT: a row that fails in the parallel phase is re-run ONCE through gate_exec in the
#     main tree after it (its own two attempts included) and, if it passes there, is scored
#     `PASS  <label>  (passed on serial retry; parallel log: …)`; the count is printed even when it is 0.
#   · CEILING + CLEANUP: each parallel row runs under `timeout ${SWEEP_ROW_TIMEOUT:-1500}` (expiry = FAIL, named).
#     Workers run in their own sessions (setsid); on exit, INT or TERM every process in those sessions — QEMU
#     under a smoke's own `timeout`, which leaves the process group but not the session — is TERMed, then KILLed,
#     worker logs are copied back to build/sweep-logs/w<K>/, and the copies are removed.
#   · FENCED RUNS (1.57.9 ENDFIX PSWEEP-R1): a controller killed WITHOUT its traps (SIGKILL/OOM) no longer leaks — the
#     queue is run-scoped (build/sweep-queue.<pid>), each worker's lifeline (sweep_lifeline) ends its session when the
#     controller is gone, and every run starts by reaping a dead run's queue and copies (sweep_reap_stale).
#     Proof: scripts/check/sweep-orphan-test.sh.
SWEEP_JOBS="${SWEEP_JOBS:-4}"
case "$SWEEP_JOBS" in ''|*[!0-9]*|0) echo "sweep.sh: SWEEP_JOBS must be a positive integer (got '$SWEEP_JOBS')" >&2; exit 2;; esac
SWEEP_ROW_TIMEOUT="${SWEEP_ROW_TIMEOUT:-1500}"
SWEEP_EXCLUSIVE="${SWEEP_EXCLUSIVE:-1}"

# gate_exec "<label>" "<build env>" "<smoke script | CHECK>" "<log slug>"
# Runs ONE row in $ROOT (the tree this copy of the script lives in) and prints its section. Returns 0 = PASS,
# 1 = FAIL, 2 = the row's BUILD failed. This is run_gate's body from before 1.57.9, unchanged except that the
# scratch log is $ROOT/build/sweep-gate.log: the old fixed /tmp/sweep-gate.log collided between workers (and
# between two trees sweeping at once — HARNESS-BACKLOG, SMOKES3). Each attempt is still kept under $SWEEP_LOGS.
# Each smoke runs ONCE per attempt (captured to a log); a single retry covers
# transient host-load / QEMU-timing flakes (a real failure fails both attempts).
gate_exec() {
    g_label="$1"; g_env="$2"; g_smoke="$3"; g_slug="$4"
    mkdir -p "$ROOT/build"
    GATE_LOG="$ROOT/build/sweep-gate.log"
    printf '\n=== %s ===\n' "$g_label"
    ok=0
    if [ "$g_smoke" = "CHECK" ]; then
        if sh "$ROOT/scripts/check.sh" > "$GATE_LOG" 2>&1; then ok=1; tail -1 "$GATE_LOG"; else tail -3 "$GATE_LOG"; fi
        cp "$GATE_LOG" "$SWEEP_LOGS/$g_slug.attempt1.log"
    else
        # ⛔ MEASURED 2026-08-28 (1.56.51): A FAILED BUILD USED TO BE PRINTED AND THEN IGNORED.
        # The old form was `… || { echo "  BUILD FAILED"; }` — the `||` consumed the status, `ok`
        # was untouched, and the loop below went on to run the smoke against WHATEVER build/agnos
        # was left on disk from a previous gate. A gate whose build failed could therefore still be
        # recorded PASS, on a binary built with a DIFFERENT $buildenv than the one it is testing.
        # Every gate here exists to test one specific compile-gated configuration; running the
        # previous gate's kernel is not a degraded test, it is a different test wearing this one's
        # name. A build failure is now the gate's verdict.
        if ! env $g_env sh "$ROOT/scripts/build.sh" >/dev/null 2>&1; then
            echo "  BUILD FAILED ($g_env) — gate not run"
            return 2
        fi
        for attempt in 1 2; do
            # ⚠ smokes live in scripts/smoke/ since the 1.56.22 split. The gate table below still
            # names them bare (that is the readable form), so resolve here rather than editing 30
            # table rows — and fall back to the old flat location so a not-yet-moved smoke still runs.
            SMOKE_PATH="$ROOT/scripts/smoke/$g_smoke"
            [ -f "$SMOKE_PATH" ] || SMOKE_PATH="$ROOT/scripts/$g_smoke"
            # ⛔⛔ MEASURED 2026-08-28 (1.56.51): THE OLD DETECTOR RECORDED TOTAL FAILURE AS PASS.
            # It was `grep -qiE "smoke.*PASS|smoke \(.*\): PASS"`. The `-i` makes the literal PASS
            # match the substring "pass" inside the word "passed" — so a smoke whose FAILURE verdict
            # reads `=== fp-nm-smoke: 0 passed, 7 failed ===` satisfies `smoke.*pass` and was scored
            # a PASS. Fed the real runtime strings, the old pattern says PASS to all of these:
            #     === fp-area-smoke: 3 passed, 5 failed ===
            #     === fp-nm-smoke: 0 passed, 7 failed ===
            #     === fp-ctxsw-smoke: 1 passed, 2 failed ===
            #     === fp-selftest-smoke: 4 passed, 9 failed ===
            # Those are FOUR of the twelve gates this sweep runs. A "15/15" or "16/16" from the old
            # sweep did not mean what it said for any smoke reporting in the "N passed, M failed"
            # form — it meant only that the smoke reached its verdict line at all.
            # ⭐ AND THE CORRECT ORACLE WAS ALREADY THERE, BEING THROWN AWAY: every one of these
            # smokes exits 0 on success and 1 on failure (`[ "$fail" -eq 0 ] && { …; exit 0; }; …;
            # exit 1`). The status is now primary. The log grep is kept only as a SECOND, narrow
            # assertion against the exact trap above — a smoke that exits 0 while printing
            # "N passed, M failed" with M>0 is itself broken, and must not be scored a pass.
            sh "$SMOKE_PATH" > "$GATE_LOG" 2>&1 && smoke_rc=0 || smoke_rc=$?
            cp "$GATE_LOG" "$SWEEP_LOGS/$g_slug.attempt$attempt.log"
            if [ "$smoke_rc" = 0 ] \
               && ! grep -qE 'passed, [1-9][0-9]* failed' "$GATE_LOG"; then
                ok=1; break
            fi
            echo "  (attempt $attempt: rc=$smoke_rc — log kept: $SWEEP_LOGS/$g_slug.attempt$attempt.log)"
        done
        # ⛔ MEASURED 2026-08-29 (1.56.52): THIS FILTER HID THE ONE LINE THAT LOCALISES A FAILURE.
        # It was `grep -iE "PASS:|FAIL:|smoke:"`, and several smokes report a LAUNCH failure with a
        # line that matches none of those — `ERROR: QEMU produced NO boot output (0-byte log) —
        # launch failure, not an exFAT result.` is the exact wording in exfat-write-smoke.sh. So the
        # gate printed a completely EMPTY section and then scored FAIL, and the sweep transcript told
        # the operator only that something went wrong, with no way to tell a kernel regression from a
        # firmware hand-off that never happened. That distinction is the subject of its own state.md
        # heading ("A QEMU BOOT THAT NEVER HAPPENS READS AS A KERNEL FAILURE"), and this filter was
        # quietly erasing the evidence for it. ⚠ SCORING IS UNCHANGED — a launch failure is still a
        # FAIL here, deliberately: downgrading it to VOID inside run_gate would give every real
        # failure a way to hide. The fix is to make the diagnostic VISIBLE, not to forgive it.
        grep -iE "PASS:|FAIL:|smoke:|ERROR|SKIP|VOID|handed off" "$GATE_LOG" | sed 's/^/  /' || true
        [ "$ok" = 1 ] && [ "${attempt:-1}" = 2 ] && echo "  (passed on retry — transient host-load timing)"
    fi
    [ "$ok" = 1 ] && return 0
    return 1
}

# ---------------------------------------------------------------------------------------------------------------
# Internal modes of the parallel sweep (never invoked by hand). Both run in the tree this script copy lives in and
# find the run's queue at $SWEEP_Q and the main tree's log dir at $SWEEP_LOGS (exported by the main process).
#   --row <n>       run row n (its record is $SWEEP_Q/<n>.row: label, build env, smoke, slug) and exit gate_exec's code
#   --worker <K>    K = main: the rows in $SWEEP_Q/main.list; K = 1..N: claim groups from $SWEEP_Q/order until none left
# ---------------------------------------------------------------------------------------------------------------
sweep_read_row() {  # $1 = n  ->  r_label r_env r_smoke r_slug
    { IFS= read -r r_label; IFS= read -r r_env; IFS= read -r r_smoke; IFS= read -r r_slug; } < "$SWEEP_Q/$1.row"
}

sweep_run_row() {   # $1 = n — one row under the row ceiling, in this tree; leaves <n>.out and <n>.res
    rr_n="$1"; rr_t0=$(date +%s)
    sweep_read_row "$rr_n"
    # Bazel TEST_TMPDIR / xfstests tmp=: a row's mktemp dirs (several smokes put 8-130 MB disk images there) live in
    # THIS tree's build/sweep-tmp, emptied after every row. Measured 1.57.9: under /tmp — a tmpfs with a per-user
    # quota, shared with every agent on the box — a parallel msc-cdb row died on `dd: Disk quota exceeded`, and a
    # killed row (ceiling, Ctrl-C) leaked its 129 MB image there, because four smokes create it with no EXIT trap.
    TMPDIR="$ROOT/build/sweep-tmp"; export TMPDIR; mkdir -p "$TMPDIR"
    timeout -k 30 "$SWEEP_ROW_TIMEOUT" sh "$ROOT/scripts/sweep.sh" --row "$rr_n" \
        > "$SWEEP_Q/$rr_n.out" 2>&1 < /dev/null && rr_rc=0 || rr_rc=$?
    case "$rr_rc" in
        0|1|2) ;;
        124|137)
            echo "  ROW TIMEOUT: killed after ${SWEEP_ROW_TIMEOUT}s (SWEEP_ROW_TIMEOUT) — scored FAIL" >> "$SWEEP_Q/$rr_n.out"
            # `timeout` killed its own process group; a smoke's inner `timeout` (and the QEMU under it) sits in a
            # group of its own. Everything a row starts has this tree's build/ or smoke dir on its command line;
            # this worker and the row runner (scripts/sweep.sh) do not.
            pkill -TERM -f -- "$ROOT/(build|scripts/smoke)/" 2>/dev/null
            rr_rc=1 ;;
        *)  echo "  row runner exited $rr_rc (signal?) — scored FAIL" >> "$SWEEP_Q/$rr_n.out"; rr_rc=1 ;;
    esac
    rm -rf "${TMPDIR:?}"/* "${TMPDIR:?}"/.[!.]* 2>/dev/null
    rr_dur=$(( $(date +%s) - rr_t0 ))
    printf '%s\t%s\t%s\n' "$rr_rc" "$rr_dur" "$SWEEP_WORKER" > "$SWEEP_Q/$rr_n.res.tmp"
    mv -f "$SWEEP_Q/$rr_n.res.tmp" "$SWEEP_Q/$rr_n.res"
    case "$rr_rc" in 0) rr_v=PASS;; 2) rr_v="FAIL (build)";; *) rr_v=FAIL;; esac
    printf '  [%-4s] %3ss  %-12s row %2s  %s\n' "$SWEEP_WORKER" "$rr_dur" "$rr_v" "$rr_n" "$r_label"
}

if [ "${1:-}" = "--row" ]; then
    sweep_read_row "$2"
    gate_exec "$r_label" "$r_env" "$r_smoke" "$r_slug"
    exit $?
fi
# ⭐ 1.57.9 ENDFIX (end review PSWEEP-R1) — A WORKER DIES WITH ITS CONTROLLER. The controller's traps (EXIT/INT/TERM)
# stop the workers on every exit it SEES; a SIGKILL, an OOM kill or a harness hard-kill runs no trap, and a setsid
# worker used to outlive it — claiming groups, booting QEMU, and (with the queue at a fixed path) claiming rows of the
# NEXT run and scoring them from its stale copy. Prior art (handoff-1.57.9/steps/ENDFIX-prior-art.md): Linux
# prctl(PR_SET_PDEATHSIG) — a child asks to be signalled when its parent dies; pytest-xdist/execnet workers exit on
# channel EOF; GNU parallel --termseq escalates TERM -> KILL. POSIX sh has no death signal, so each worker runs this
# LIFELINE in the background: it polls the controller (SWEEP_MAIN_PID) every 2 s while its worker lives; when the
# controller is gone it TERMs the worker's whole session (the row runner and the QEMU under a smoke's own `timeout` —
# the lifeline ignores TERM itself), KILLs what is left after 10 s, and removes the worker copy (a main-tree worker has
# none). $1 = the worker's pid. The startup reap (sweep_reap_stale) is the backstop for a lifeline killed too.
sweep_lifeline() {
    trap '' TERM INT HUP
    wl_w="$1"; wl_sid=$(ps -o sid= -p "$wl_w" 2>/dev/null | tr -d ' ')
    while kill -0 "$SWEEP_MAIN_PID" 2>/dev/null && kill -0 "$wl_w" 2>/dev/null; do sleep 2; done
    kill -0 "$SWEEP_MAIN_PID" 2>/dev/null && exit 0          # the worker finished normally; the controller reaps
    read -r wl_self _ < /proc/self/stat                        # this lifeline's own pid (a builtin: no fork)
    if [ -n "$wl_sid" ]; then
        # Snapshot the session BEFORE the TERM and wait on that list: a `$(pgrep …)` inside the wait loop would list
        # its own command-substitution subshell, which inherits this lifeline's ignored TERM, and never read empty.
        wl_list=$(pgrep -s "$wl_sid" 2>/dev/null | grep -vx "$wl_self")
        pkill -TERM -s "$wl_sid" 2>/dev/null
        wl_t=0
        while [ "$wl_t" -lt 10 ]; do
            wl_live=0; for wl_p in $wl_list; do kill -0 "$wl_p" 2>/dev/null && wl_live=1; done
            [ "$wl_live" = 0 ] && break
            sleep 1; wl_t=$((wl_t + 1))
        done
        for wl_p in $(pgrep -s "$wl_sid" 2>/dev/null | grep -vx "$wl_self"); do kill -KILL "$wl_p" 2>/dev/null; done
    fi
    case "$ROOT" in */.*.sweep.*.w[0-9]*) rm -rf "$ROOT" ;; esac
    exit 0
}

if [ "${1:-}" = "--worker" ]; then
    SWEEP_WORKER="$2"
    # The session id this worker really got (the main process also records setsid's pid), for the cleanup kill.
    ps -o sid= -p $$ 2>/dev/null | tr -d ' ' > "$SWEEP_Q/sid.$SWEEP_WORKER"
    sweep_lifeline $$ < /dev/null > /dev/null 2>&1 &
    if [ "$SWEEP_WORKER" = main ]; then
        for n in $(cat "$SWEEP_Q/main.list" 2>/dev/null); do sweep_run_row "$n"; done
        exit 0
    fi
    while IFS= read -r g; do
        # ENDFIX PSWEEP-R1: claim nothing for a dead controller or a queue that is not there any more (xdist: a
        # worker whose channel closed stops pulling work).
        kill -0 "$SWEEP_MAIN_PID" 2>/dev/null || exit 0
        [ -d "$SWEEP_Q" ] || exit 0
        mkdir "$SWEEP_Q/claim.$g" 2>/dev/null || continue
        for n in $(cat "$SWEEP_Q/g.$g"); do sweep_run_row "$n"; done
    done < "$SWEEP_Q/order"
    exit 0
fi

pass=0; fail=0; results=""
# ⭐ 1.57.7 (IMG-fix, review B3) — EVERY ATTEMPT'S LOG IS KEPT. Both attempts used to go to the one
# /tmp/sweep-gate.log, so a row that "passed on retry" had its first failure overwritten and nobody could say
# whether it was a firmware VOID or a real failure (the IMG sweep's ext2 WRITE row was exactly that). Now each
# attempt is also copied to build/sweep-logs/<NN>-<label>.attempt<K>.log (cleared per sweep) and a failed
# attempt names its log. Scoring is unchanged: a non-zero exit is still a failed attempt (see run_gate).
SWEEP_LOGS="$ROOT/build/sweep-logs"
# The previous runs' per-row durations (`<seconds>\t<label>`, the joblog) order the parallel dispatch; fold the
# last run's into the history before the wipe (the last run wins per label, so a SWEEP_ONLY run keeps the rest).
SWEEP_PREV_DUR="$ROOT/build/sweep-durations.prev.tsv"
if [ -f "$SWEEP_LOGS/durations.tsv" ]; then
    [ -f "$SWEEP_PREV_DUR" ] || : > "$SWEEP_PREV_DUR"
    awk -F'\t' '{ d[$2] = $1 } END { for (k in d) printf "%s\t%s\n", d[k], k }' \
        "$SWEEP_PREV_DUR" "$SWEEP_LOGS/durations.tsv" > "$SWEEP_PREV_DUR.new" && mv -f "$SWEEP_PREV_DUR.new" "$SWEEP_PREV_DUR"
fi
rm -rf "$SWEEP_LOGS"; mkdir -p "$SWEEP_LOGS"
export SWEEP_LOGS
gate_n=0; skipped=0
# SWEEP_ONLY=<ERE> (1.57.7 IMG-fix) runs only the rows whose label matches — for reproducing ONE row with this
# exact harness. A filtered run is never a sweep verdict: it ends "SWEEP_ONLY … NOT A SWEEP VERDICT" and exits 3
# when nothing failed (1 when something did), so it cannot be mistaken for ARC SWEEP: PASS.
SWEEP_ONLY="${SWEEP_ONLY:-}"

# ⭐ 1.57.9 ENDFIX (end review PSWEEP-R1) — FENCE EVERY RUN. (1) The queue is RUN-SCOPED, build/sweep-queue.<pid> (xfstests
# tmp=/tmp/$$, Bazel TEST_TMPDIR): a worker of a dead run can never mkdir a claim in, read the rows of, or write a
# result into a later run's queue — at the old fixed path build/sweep-queue it did all three, and the new run scored
# that row from the dead run's stale copy. (2) STARTUP REAP (the pidfile rule: trust a recorded pid only after
# `kill -0`): a queue or a ../.<tree>.sweep.<pid>.w<K> copy whose <pid> is not a live sweep.sh belongs to a run that
# died without its traps — its recorded worker sessions are KILLed and the directories removed. Both modes run it.
sweep_is_live_sweep() {   # $1 = pid -> 0 when that pid is a running scripts/sweep.sh
    [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q 'sweep\.sh'
}
sweep_reap_stale() {
    rs_me=$(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')
    for rs_q in "$ROOT"/build/sweep-queue "$ROOT"/build/sweep-queue.*; do
        [ -d "$rs_q" ] || continue
        rs_p="${rs_q##*/sweep-queue}"; rs_p="${rs_p#.}"
        [ -n "$rs_p" ] && sweep_is_live_sweep "$rs_p" && continue       # a live sweep of this tree owns it
        for rs_s in $(cat "$rs_q"/sid.* "$rs_q"/pid.* 2>/dev/null | sort -u); do
            [ -n "$rs_s" ] && [ "$rs_s" != "$rs_me" ] && pkill -KILL -s "$rs_s" 2>/dev/null
        done
        echo "sweep: reaped a dead run's queue $rs_q (its worker sessions killed)"
        rm -rf "$rs_q"
    done
    for rs_c in "$(dirname "$ROOT")/.$(basename "$ROOT").sweep."*; do
        [ -d "$rs_c" ] || continue
        rs_p="${rs_c##*.sweep.}"; rs_p="${rs_p%%.w*}"
        sweep_is_live_sweep "$rs_p" && continue
        echo "sweep: removed a dead run's worker copy $rs_c"
        rm -rf "$rs_c"
    done
}
sweep_reap_stale

if [ "$SWEEP_JOBS" -gt 1 ]; then
    SWEEP_Q="$ROOT/build/sweep-queue.$$"; rm -rf "$SWEEP_Q"; mkdir -p "$SWEEP_Q"
    : > "$SWEEP_Q/main.list"; : > "$SWEEP_Q/exclusive.list"; : > "$SWEEP_Q/groups"; : > "$SWEEP_Q/rowmap"
    SWEEP_MAIN_PID=$$
    export SWEEP_Q SWEEP_ROW_TIMEOUT SWEEP_MAIN_PID
fi

# run_gate "<label>" "<build env>" "<smoke script | CHECK>" ["<group key>"]
# SWEEP_JOBS=1: runs the row now (gate_exec) and tallies it. SWEEP_JOBS>1: records the row for the parallel
# dispatch below (the number and slug are fixed here, in table order). The group key is ignored serially.
run_gate() {
    label="$1"; buildenv="$2"; smoke="$3"; group="${4:-}"
    if [ -n "$SWEEP_ONLY" ] && ! printf '%s' "$label" | grep -qE -- "$SWEEP_ONLY"; then skipped=$((skipped+1)); return; fi
    gate_n=$((gate_n+1))
    gate_slug=$(printf '%02d-%s' "$gate_n" "$label" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80)
    if [ "$SWEEP_JOBS" -gt 1 ]; then
        printf '%s\n%s\n%s\n%s\n' "$label" "$buildenv" "$smoke" "$gate_slug" > "$SWEEP_Q/$gate_n.row"
        if [ "$smoke" = "CHECK" ]; then
            echo "$gate_n" >> "$SWEEP_Q/main.list"
        elif [ "$group" = "exclusive" ] && [ "$SWEEP_EXCLUSIVE" != 0 ]; then
            echo "$gate_n" >> "$SWEEP_Q/exclusive.list"
        else
            [ -n "$group" ] && [ "$group" != "exclusive" ] || group="row$gate_n"
            [ -f "$SWEEP_Q/g.$group" ] || echo "$group" >> "$SWEEP_Q/groups"
            echo "$gate_n" >> "$SWEEP_Q/g.$group"
            printf '%s\t%s\t%s\n' "$gate_n" "$group" "$label" >> "$SWEEP_Q/rowmap"
        fi
        return
    fi
    g_t0=$(date +%s)
    gate_exec "$label" "$buildenv" "$smoke" "$gate_slug" && g_rc=0 || g_rc=$?
    printf '%s\t%s\n' "$(( $(date +%s) - g_t0 ))" "$label" >> "$SWEEP_LOGS/durations.tsv"   # the joblog (dispatch order)
    if [ "$g_rc" = 0 ]; then pass=$((pass+1)); results="$results\n  PASS  $label";
    elif [ "$g_rc" = 2 ]; then fail=$((fail+1)); results="$results\n  FAIL  $label (build)";
    else fail=$((fail+1)); results="$results\n  FAIL  $label"; fi
}

SWEEP_T0=$(date +%s)
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
# 1.57.2 — the ONLY gate that presents a MULTI-NODE FAT chain cycle (A -> B -> A, both in range):
# fat-smoke / exfat-smoke prove GOOD chains read, and nothing else in the tree ever hands the kernel
# a chain that never ends. One kernel carries both selftests and one disk carries both cycles (a
# cyclic FAT32 subdir on the ESP + a cyclic exFAT root on p2); the smoke aborts before booting unless
# fsck.fat AND fsck.exfat see the cycles, and it exits 2 (VOID) when the kernel never ran. Mutation-
# proven: it goes RED with either predicate stubbed (see the smoke header for the exact lines).
# ⚠ ~45 s to PASS (the FAT32 budget is 129k fetches of uncached NVMe reads under TCG); a kernel that
# hangs burns the full 180 s dwell, twice, because run_gate retries — that is the RED path, not slack.
run_gate "1.57.2 FAT/exFAT chain-cycle budget"       "FATFS_SELFTEST=1 EXFAT_SELFTEST=1"         "fat-cycle-smoke.sh"
# 1.56.52 — the tree's FIRST usb-storage coverage. The MSC transport had none: no QEMU invocation
# anywhere under scripts/ attached one, so every gate passed regardless of what msc.cyr did. This
# smoke builds BOTH arms itself (injected + plain), so it needs no buildenv from here. 1.57.9: both arms at
# -smp 1 and -smp 4 (${MSC_SHORT_SMP:-1 4}), each variant asserting its topology.
run_gate "1.56.52 MSC short data phase (usb-storage, -smp 1 + 4)" ""                                 "msc-short-smoke.sh"
# 1.57.7 — the 16-byte CDB at all seven SCSI builders (issue 2026-09-24-msc-cdb-buffer-is-two-bytes). A
# MSC_CDB_CANARY kernel puts an address-taken canary in the slot a too-small cdb_buf overflows into and drives
# all seven sites against QEMU usb-storage; RED (clobbered=7) on the [2] code, GREEN on [16]. -smp 1 + 4 gated,
# plus one MSC_RW_DEMO boot of the canary-free production frames. Builds its own kernels.
# 1.57.9 — boot P also runs MSC_BOUNCE_SELFTEST at -smp 1 + 4: msc_blk_* never put a caller pointer in a TRB
# (issue 2026-09-25-msc-puts-the-caller-buffer-in-a-data-trb).
run_gate "1.57.7 MSC CDB canary: 16-byte CDB at all 7 SCSI sites + 1.57.9 msc_blk_* bounce (usb-storage, -smp 1 + 4)" "" "msc-cdb-smoke.sh"
# 1.57.8 — the xHCI half of issue 2026-09-25-dma-cpu-pointers-still-use-identity-vas: an XHCI_SHADOW_SELFTEST
# kernel runs a No-Op command, an EP0 GET_DESCRIPTOR, an MSC READ(10) and a keyboard TRB arm + report fold under a
# CR3 whose whole pool window is shadowed by junk; each must be byte-exact and the junk untouched. RED on each
# converted site reverted. usb-kbd + usb-storage, -smp 1 + 4 gated. Builds its own kernels.
run_gate "1.57.8 xHCI/HID/MSC DMA pages via the direct map (shadowed pool window, -smp 1 + 4)" "" "xhci-shadow-smoke.sh"
# 1.57.8 — issue 2026-09-25-hid-mouse-reports-share-one-buffer: a HID_MOUSE_DEFER_SELFTEST kernel holds the drain
# (IF=0 + hid_poll_lock) while the harness injects four usb-mouse reports over the monitor; ONE drain must then see
# dx 5, dy 7, the press and the release. RED (dx 0 dy 0, no click) on the shared report buffer. -smp 1 + 4 gated.
run_gate "1.57.8 HID mouse per-TRB report slots (deferred drain, usb-mouse, -smp 1 + 4)" "" "hid-mouse-deferred-smoke.sh"
# 1.56.52 — the first coverage of receive-side checksum verification. The other net gates only prove
# GOOD frames pass; this one presents a corrupt frame, which nothing else in the tree does.
run_gate "1.56.52 RX checksum verify (accept + drop)"  ""                                         "net-csum-smoke.sh"
# 1.56.52 — a HID Transfer Event eaten by an xHCI synchronous waiter must be handed back to the ring
# that owned it. Hermetic; no USB hardware required, though the smoke boots a usb-kbd anyway so the
# swapped-globals teardown is exercised against a non-empty endpoint registry.
run_gate "1.56.52 stolen HID event reclaim"            ""                                         "hid-reclaim-smoke.sh"
# 1.56.52 — a "user pointer" must mean a page the CALLER OWNS, not merely a low address. The low
# window is full of supervisor identity mappings of kernel memory; see the smoke header.
run_gate "1.56.52 user-pointer window (owned, not low)" ""                                         "userwin-smoke.sh"
# 1.56.52 — a DHCP option shorter than its reader is a remote ring-0 stack read. Hermetic: the helper
# is a pure function over a blob, which is the only way to test an attack needing a hostile server.
run_gate "1.56.52 DHCP option length vs reader"        ""                                         "dhcp-opt-smoke.sh"
# 1.56.55 — fork#96 end to end from ring 3: the child resumes at the parent's fork site with rax=0,
# gets a PRIVATE copy of its memory, and the parent reaps it via waitpid wait-any. Builds its own
# kernel (FORK_SELFTEST) and seeds /bin/forker, so it needs no buildenv here.
run_gate "1.56.55 fork#96 + waitpid wait-any (-smp 1 + 4)" ""                                     "fork-smoke.sh"
# 1.57.2 — the kernel-embedded default TrueType face (core/kfont.cyr, rekha's Liberation Sans) proven
# FROM RING 3: /bin/kfont opens /fonts/default.ttf by name, pulls every byte through read#5 and hashes
# what it got against rekha's generator FNV-1a-64, then the sfnt header, the read-only gate, the exact
# namespace, stat#33 + lstat#102 and the provenance alias (exit 95; 80-94 / 96-97 name the step). The kernel's own boot
# line proves only that the KERNEL sees the bytes under its CR3. Builds its own kernel
# (KFONT_RING3_SELFTEST) and seeds /bin/kfont like the blk-ring3 smoke, so it needs no buildenv here.
# ⚠ There is no blk-ring3 row in this table to sit beside — that smoke is one of the ~68 still unlisted.
run_gate "1.57.2 kernel-embedded face (/fonts/default.ttf, rekha)" ""                             "kfont-smoke.sh"
# 1.57.3 — the AP1-3 boot/TSS stacks relocated OUT of kernel .rodata (the 1.57.2 face put the fixed
# region-1 windows [0x310000, 0x340000) inside the chunk literals) into region 7 via the direct map.
# The runtime half: an SMP_STACK_SELFTEST kernel under -smp 4 prints each AP's live RSP (sampled in
# ap_entry) against [DIRECTMAP_BASE + 0xFC0000, +0x40000) and re-hashes the rekha chunk literals IN
# PLACE after the wake (the load-bearing oracle — a stack anywhere in the image scribbles there on every
# tick, invisible to every -smp 1 gate). Mutation-proven: the old placement trips both. Builds its own
# kernel, so it needs no buildenv here; the image-side bound (LOAD end <= 0x390000 since 1.57.7 moved the
# BSP boot stack top 0x380000 -> 0x3A0000; 0x370000 before) is check.sh gate 34 for the plain image and
# scripts/build.sh's flag-build guard for every buildenv row here (an over-bound flag image is a BUILD FAILED).
run_gate "1.57.3 AP stacks in region 7 (-smp 4, rodata intact after wake)" ""                     "ap-stack-smoke.sh"
# 1.57.6 — the microsecond clock ring 3 uses (uptime_us#95). tsc-smoke existed since 1.56.18 and NO row ran
# it: when it was finally run for 1.57.6 it was RED on a healthy tree (the klog timestamp prefix fed the
# timestamp's seconds to its calibration extraction) and its boot HUNG after the IF=0 ring-3 probe — both
# unseen for months. The plain mode runs here: the FADT PM timer decoded, calibration on the acpi-pm tier,
# the live-tick tier agreeing within 2%, the lost-tick / agreement predicates on synthetic windows AND on
# one live window with a 25 ms IF=0 stall inside it (the call-site wiring), the probe's `run: exit 1` (#95
# advances with interrupts off), both accessors == calibration, the boot going on to the shell, and the
# corrected refusal texts (first attempt and final) in the binary. ⚠ Its TSC_QUOTA=<pct> mode (the daimon
# CPU-quota reproduction, TCG, ~1-2 min, needs systemd user cpu delegation) stays a MANUAL closeout gate.
# 1.57.7 (S1b): one invocation boots the MATRIX q35 -smp 1, q35 -smp 4 (KVM, else multi-threaded TCG) and pc -smp 1
# (the i440fx rev-1 FADT through the early probe) and scores T1-T10 on each — the spawn/kstack precedent, so run_gate
# needs no env column. `DE_NO_KVM=1 TSC_QUOTA=25|50 sh scripts/smoke/tsc-smoke.sh` (A/B reload within 1% + the halted
# tick-rate checks in B) stays the MANUAL closeout gate: it needs a systemd user manager with cpu delegated.
# ⚠ Group `exclusive` (1.57.9 PSWEEP): T1-T10 are ratios against wall time (tick period within 1-3%, calibration
# agreement within 2%) — under N parallel QEMUs they measure the host. Runs alone, main tree, after the parallel phase.
run_gate "1.57.6/1.57.7 TSC + LAPIC tick on the ACPI PM timer (acpi-pm tiers, tick rate BSP+AP, FADT purity, uptime_us#95 IF=0; q35 -smp 1 + 4, pc)" "TSC_SELFTEST=1" "tsc-smoke.sh" "exclusive"
# 1.57.6 — spawn_path#43: distinct failure codes, the per-process #62 / CH_ENDOW arms cleared on EVERY
# failure kind (they were per-CPU and leaked into other processes' children), SPAWN_F_ARGV,
# SPAWN_F_CLEANFD capture (stdout+stderr, 2>&1, an explicitly passed fd, daimon's full shape), execwait#37
# multi-redirect, the table-full code, and the pipe buffer's last-reference lifetime (a ring-3 UAF before).
# Three banner-gated boots: the SPAWN_SELFTEST + PIPE_RC_SELFTEST kernel block (PIPE_RC_SELFTEST's first
# runner ever), then tests/spawn seeded as /bin/agnsh on a PLAIN kernel at -smp 1 AND -smp 4 — both gated;
# the -smp 4 boot is what caught do_context_switch leaving an AP on a reaped proc's freed page tables.
# Builds its own kernels, so no buildenv here.
run_gate "1.57.6 spawn: #43 codes, per-process arms, ARGV/CLEANFD, pipe lifetime (-smp 1 + 4)" "" "spawn-smoke.sh"
# 1.57.7 (S7) — the process lifecycle (docs/architecture/process-lifecycle.md): kill#16 ends (9), stops (19) and
# continues (18) a child and its descendants (KILL_TREE 0x100) through the claim / tick / B1 / wait boundaries; the wait
# status; #99 states 5 and 7; orphans reap themselves. tests/lifecycle (lifex as /bin/agnsh, spinner) on a PLAIN
# kernel, -smp 1 and -smp 4 (KVM when /dev/kvm is writable since 1.57.8 — LIFE_KVM=0 forces TCG), BOTH GATED. The label keeps
# "limits": S8 extends this smoke. Builds its own kernel, so no buildenv here.
run_gate "1.57.7 lifecycle (kill/stop/cont/tree/limits) -smp 1 + -smp 4" "" "lifecycle-smoke.sh"
# 1.57.8 (KVMCON) — a PLAIN kernel + virtio-net under KVM reaches `kybernet: exec` within 20 s (kernel clock) at -smp 1
# and -smp 4, with no direct-map dead air before the console. Through 1.57.7 the virtio cap walk UC-remapped the
# kernel's own first megabyte of code (an I/O BAR's port base taken as a phys) and every console line took ~1.45 s.
# Needs a writable /dev/kvm (an ERROR otherwise — the gate is about KVM). Builds its own kernel.
# ⚠ Group `exclusive` (1.57.9 PSWEEP): the pre-console window is <= 500 ms of KVM guest time, which vCPU
# descheduling under a loaded host stretches. Runs alone, main tree, after the parallel phase.
run_gate "1.57.8 virtio-net under KVM boots at normal speed (-smp 1 + 4)" "" "kvm-net-boot-smoke.sh" "exclusive"
# 1.57.7 (S4) — the TCP stack under the net lock chain (docs/architecture/net-concurrency.md). The three flagged
# smokes existed and were never run by the sweep (D15); S4.1 gave them the banner-gated retry + the invariant deny.
run_gate "1.57.7 TCP hermetic (ring/retx/mss/wnd + locks/lo-inplace/txslots/claim/gen/syncap/eof/halfclose + S6 net waits/graceful close; -smp 1 + -smp 4)" "TCP_SELFTEST=1" "tcp-smoke.sh"
run_gate "1.57.7 loopback lo (UDP/ICMP/TCP/sockfd/epoll/close-wait)" "LOOPBACK_SELFTEST=1" "loopback-smoke.sh"
# Group `hostport` (1.57.9 PSWEEP): tcp-listen and tcp-inbound pick a host port with bind(0) and CLOSE it before
# QEMU's hostfwd binds it — a TOCTOU window, so the two never run at the same time (CTest RESOURCE_LOCK).
run_gate "1.57.7 tcp_listen accept-one (TCP_LISTEN_SMOKE)" "TCP_LISTEN_SMOKE=1" "tcp-listen-smoke.sh" "hostport"
# 1.57.7 (S4) — inbound TCP served in interrupt context, #49 EOF after the peer's FIN, FIN-before-accept half-close,
# and a cross-CPU loopback mix: tests/tcpin as /bin/agnsh on a PLAIN kernel, three GATED variants.
run_gate "1.57.7 inbound TCP in interrupt context (+ #49 EOF, half-close; -smp 1 msix/vectors0 + -smp 4)" "" "tcp-inbound-smoke.sh" "hostport"
run_gate "1.57.7 socket ownership (TCP+UDP), loopback-only listen, 127/8, sock_peer#106 (kernel arms + ring 3 -smp 1/4)" "" "sock-owner-smoke.sh"
run_gate "1.57.7 sock/icmp waits block only the caller (ring 3; -smp 1 + -smp 4)" "" "sock-wait-smoke.sh"
run_gate "ICMP echo (hermetic slots + wake; -smp 1 + -smp 4)" "ICMP_SELFTEST=1" "icmp-smoke.sh"
# 1.57.7 — ADDED AFTER S6 BROKE IT UNSEEN. doom-smoke had no row, so S6 (the net waits) shipped with /bin/doom hung
# forever in #47: its setu probe dials 127.0.0.1:7700, nobody answers, and a PRE-SCHEDULER caller (DOOM_SELFTEST
# runs doom before sched_active = 1, IF=0) had lost the arm's sti window — the legacy hlt never ended, the screendump
# read 3 colours. This is also the only row that runs a real app's #47 against an unanswered port before the
# scheduler. Builds its own DOOM_SELFTEST kernel and restores a plain one (needs ../cyrius-doom built + its WAD).
run_gate "1.43.x cyrius-doom renders from disk (pre-scheduler ring 3; #47 to an unanswered port times out)" "" "doom-smoke.sh"
# 1.57.6 — exec-redirect-smoke has existed since 1.46.x (extended 1.56.39) and NO row ran it, so the #62/#37
# apply and the #43 global-table refusal were exercised by nothing. It also proves the two-pair `2>&1` shape. 1.57.7
# (S3b): #37 applies into the child's private table exactly as #43 does (no restore), so the selftest drives a
# scratch child and checks the parent's table is untouched. Builds its own kernel (EXEC_REDIRECT_SELFTEST).
run_gate "1.46.x exec_redirect#62 apply into the child's private table (+ multi-pair), #43 global-table refusal" "" "exec-redirect-smoke.sh"
run_gate "1.39.x exFAT write (+ subdir)"             "EXFAT_WRITE_SELFTEST=1"                   "exfat-write-smoke.sh"

# --- ext2/jbd2 write regression bar (the iron-validated path must stay green) ---
run_gate "ext2 WRITE regression (W1-W5)"             "EXT2_WRITE_SELFTEST=1"                    "ext2-write-smoke.sh"

# --- 1.41.3 FS syscalls through ksyscall(), on-disk effects checked by host debugfs + e2fsck ---
# ⛔ FS_SYSCALL_SELFTEST shipped at 1.41.3 with NO RUNNER while docs/development/build.md said "gated by
# scripts/sweep.sh" — the same shape as SYSCALL_HARDEN_SELFTEST below, and it cost more: cyrius 6.5.1 made
# a wrong argument count a hard error, four 3-arg ksyscall() calls in the selftest made the flag build
# refuse to emit a binary, and nothing ran it for the next 25 pins. Found by a static arity scan in the
# 6.6.6 pin audit (1.57.5), fixed there, and this row is what keeps the next one from hiding.
run_gate "1.41.3 FS syscalls (mkdir/open/stat/rename/getdents/unlink/rmdir/sync via ksyscall)" "FS_SYSCALL_SELFTEST=1" "fssys-smoke.sh"

# --- 1.40.x exec-from-disk: load + ring-3 run + ENOEXEC + subdir + clean return ---
run_gate "1.40.x exec-from-disk (run /bin/prog2 + ENOEXEC)" "EXEC_SELFTEST=1 EXT2_WRITE_SELFTEST=1" "exec-smoke.sh"

# --- 1.47.x ring-3 fault kills the process, the box survives (1.57.7 HAR: a row at last) ---
# fault-kill-smoke builds its OWN FAULT_SELFTEST+EXT2_WRITE_SELFTEST kernel (smoke_require_image refuses any other)
# and restores a plain build/agnos on exit, so the row's build env is empty. Before 1.57.7 it was no row and booted
# whatever build/agnos was on disk (S7 scored a plain kernel as "faulter never dispatched").
run_gate "1.47.x ring-3 #PF kills the proc (exit 142), box survives" "" "fault-kill-smoke.sh"

# --- 1.41.5 syscall hardening + the 1.56.40 epoll no-hang lock ---
# ⛔ SYSCALL_HARDEN_SELFTEST shipped in 1.41.5 with NO RUNNER — it appeared only in build.sh's
# compile-gate list, so nothing in check.sh or sweep.sh ever built or ran it. Two consequences went
# unnoticed for ~15 minor versions: it is the ONLY coverage epoll/timerfd/signalfd have, and it had
# stopped COMPILING (two `ksyscall` calls passed 3 args to a 4-arity function, which cyrius made a hard
# error). Both fixed 2026-08-05. A selftest nothing runs is not coverage; it is a comment.
run_gate "1.41.5 syscall hardening + epoll no-hang"  "SYSCALL_HARDEN_SELFTEST=1"                "syscall-harden-smoke.sh"
# ⛔ 1.56.55 — ADDED. This smoke carries the ONLY regression test for `proc_alloc_slot`s reuse scan
# (`ring3: nonlifo reuse OK`), plus the ring-3 preempt gate and `sched_yield`#44 slice donation, and it
# was in NO sweep row — so the 1.56.55 allocator change had to be verified by hand. It was also red
# for a harness reason (a 40 s dwell that truncated its own tail); fixed in the smoke, 8/8 now.
run_gate "1.44.x ring-3 procs, preempt gate, slot reuse, yield#44 park (-smp 1 + 4)" "RING3_SELFTEST=1" "ring3-smoke.sh"
# 1.57.6 (Path 2, S3.3) — per-process kernel stacks. A KSTACK_SELFTEST kernel, booted -smp 1 THEN -smp 4 (KVM
# `-cpu host` when /dev/kvm is writable, else multi-threaded TCG — the log names it), both gated: the SYSRET
# frame is per-process (four probes with distinct RSP / sentinels / XMM survive >= 20 probe syscalls each), a
# syscall can be switched out MID-FLIGHT at CPL0 and resumed — on another CPU at -smp 4 — the deferred on_cpu
# release holds under a retire-while-running storm, a console_lock holder at IF=1 is not preempted into a
# same-CPU deadlock, sched_next's nothing-ready fallback answers the idle and never kmain's stale slot, every
# timer ISR body runs non-preemptible, and region 7 carries 32 not-present guard pages. Also the stub-size
# oracle (174 bytes since the 1.57.7 stub bite C, ibrs=0). Builds its own kernel and leaves a plain one, so no buildenv here.
run_gate "1.57.6 per-process kernel stacks, CPL0 switch windows, lock holders, guard pages; 1.57.7 voluntary switch, block/wake, clac (-smp 1 + 4)" "" "kstack-smoke.sh"
# 1.57.7 (Path 2, S3b) — FOREGROUND EXEC: execwait#37 is a blocking wait (the child an ordinary scheduled IF=1
# process: ticks, siblings, yield, nesting, fault, redirect, env, FP, migration) and kmain's `run` is a scheduled
# child (recovery mode: tickself, fault, an orphan writer, spawn storms, free RAM). PLAIN kernel, tests/fg seeded as
# /bin/agnsh; -smp 1 then -smp 4, both gated; the default mode also checks agnsh-exit-with-a-live-bg-job + dumpe2fs.
run_gate "1.57.7 foreground exec on Path 2 (#37 blocks, kmain run) -smp 1+4 + recovery" "" "fg-smoke.sh"

# 1.57.7 (Path 2, S3c) — the in-kernel blocking waits FROM RING 3 (tests/waits/waitx.cyr seeded as /bin/agnsh on a
# PLAIN kernel; -smp 1 then -smp 4, both gated): sleep_ms#41 blocks only its caller (spinners get the CPU, a child
# runs during the sleep), waitpid#4 WAIT_BLOCK (0x100|pid, 0x1FF any), flock#59 waits without LOCK_NB (-2 = table
# full; a blocking conversion drops the old lock; a 4-child increment stress ends exactly at 600), sched_yield#44
# donates, and an execwait#37 child blocks like any process (P13 `ew37`, flipped by S3b-F2).
# Group `waits` (1.57.9 PSWEEP): wait-ring3 and wait-kbd both build tests/waits (per-copy trees already isolate it).
run_gate "1.57.7 in-kernel blocking waits: sleep_ms, waitpid WAIT_BLOCK, flock, #37 child blocks (ring 3; -smp 1 + 4)" "" "wait-ring3-smoke.sh" "waits"
# 1.57.8 — issue 2026-09-25-nvme-poll-timeout-leaves-the-cq-one-behind: a forced late NVMe completion must not shift the
# CQ (consume by CID), its buffer must not be reused before it is reaped, and a lost one must disable the controller.
run_gate "1.57.8 NVMe late completion: no CQ shift, no buffer reuse, lost -> controller off (-smp 1 + -smp 4)" "NVME_SELFTEST=1" "nvme-late-smoke.sh"
# 1.57.9 — issue 2026-09-25-ahci-timeout-abandons-an-in-flight-command: a timed-out AHCI command is recovered (§6.2.2.1:
# ST=0, wait CR=0) before its buffer / slot 0 / CT is reused, a PxIS error does not wedge the port, and an engine that
# will not stop ends in GHC.HR with every port offline. (The NVMe admin half rides nvme-late-smoke's `admin` arm.)
run_gate "1.57.9 AHCI timed-out command: recovered before reuse, TFES recovers, lost -> HBA reset + offline (-smp 1 + -smp 4)" "AHCI_SELFTEST=1" "ahci-late-smoke.sh"
# 1.57.8 — issue 2026-09-25-dma-cpu-pointers-still-use-identity-vas: virtio-blk / NVMe / AHCI / HDA reach their pmm DMA
# pages through the DIRECT MAP, so block I/O and HDA verbs stay byte-exact under a CR3 whose identity window is shadowed.
# 1.57.9 (CPUVA) — issue 2026-09-25-cpu-only-pmm-buffers-still-use-identity-vas: + fb_console's shadow and the ramdisk
# (hence RAMDISK_ENABLE in this row's build), and the 0xA5 window must be untouched after every arm; iommu.cyr is static.
run_gate "1.57.8/1.57.9 DMA + CPU-only pmm pointers: block/HDA/fb shadow/ramdisk under a shadowed identity window (-smp 1 + -smp 4)" "DMA_SHADOW_SELFTEST=1 RAMDISK_ENABLE=1" "dma-shadow-smoke.sh"
# 1.57.7 (Path 2, S3d) — the KEYBOARD read blocks only its caller and ONE reader owns each cooked line (a second
# blocking reader waits for the line; the NB prompt poll answers -2 without draining while another live process owns
# it, and keeps the line while its partial line is live). waitx in mode `kbd` as /bin/agnsh, keys typed over HMP by
# scripts/harness/wait-kbd-test.py (wrapped by the smoke), -smp 1 then -smp 4, both gated. It also carries the
# per-TRB HID report slots' gate (a key pressed AND released inside one IF=0 gap used to be lost: `abc` read `bc`).
run_gate "1.57.7 keyboard line ownership (blocking + NB readers; -smp 1 + 4)" "" "wait-kbd-smoke.sh" "waits"
# 1.57.8 — BLOCKING pipe and channel reads (read#5 a4 = 0 waits; a4 != 0 keeps -2) (issue
# 2026-09-25-cross-cpu-poll-and-yield-loops-are-tick-bound) and 1.57.9 — the DIRECTED yield sched_yield_to#108 with a
# quiet #44 (issue 2026-09-25-any-two-sched-yield-loops-kick-each-other): tests/ipcw as /bin/agnsh on a PLAIN kernel,
# -smp 1 then -smp 4, both gated — pipe and channel ping-pongs and the #108 yield_peer < 1 ms per round; two #44 (and
# #14) loops that do not name each other send <= 30 kicks per 300 ms and sleep >= 1 ms per call at -smp 4; #108's
# refusals; EOF by close and by death; SIGKILL ends a reader blocked in a pipe wait (#99 state 6 -> 265).
run_gate "1.57.8/1.57.9 blocking pipe/channel reads + blocking pipe writes, #108 directed yield, quiet #44 (-smp 1 + 4)" "" "ipc-wait-smoke.sh"
# 1.57.9 ENDFIX (end review PIPEW-E1) — an agnsh PIPELINE whose consumer stops early (`grep . cert.pem | echo`, and a
# stage 2 that fails to spawn) must return to the prompt now that a full pipe BLOCKS its writer. Drives the staged
# agnsh (build/rootfs) by sendkey, one boot per case, -smp 1 + 4. ⛔ RED with the agnsh staged at 1.57.9: the shell
# keeps its read end and spawns stage 1 without SPAWN_F_CLEANFD (bash execute_pipeline's fds_to_close case) — the
# cross-repo agnoshi fix, handoff-1.57.9/steps/ENDFIX-report.json; GREEN with that patch applied.
run_gate "1.57.9 agnsh pipeline with an early-exiting consumer returns to the prompt (-smp 1 + 4)" "" "pipeline-smoke.sh"
# 1.44.x (S3d: gated at last) — the NB cooked-line read's -2 / -3 / line contract, pre-scheduler, plus (1.57.7) the
# completed line releases the keyboard line. It had no row since it was written.
run_gate "1.44.x NB cooked-line read (-2/-3/line, line released)" "NBREAD_SELFTEST=1" "nbread-smoke.sh"
# 1.44.0 (S3d: gated at last) — kernel threads: timer preemption round-robins two never-yielding kthreads, and the
# preempt gate freezes them. Boots -smp 1 then -smp 4 in one invocation, banner-gated (it had no row since 1.44.0).
run_gate "1.44.0 kernel threads: preempt + gate (-smp 1 + 4)" "THREAD_SELFTEST=1" "thread-smoke.sh"

# --- 1.56.40 channel band (#97): the RING-3 half, and the only place §9.9's kill criteria can be met ---
# ⛔ The boot selftest structurally cannot close either: it runs under the KERNEL's CR3 (so it says
# nothing about region reachability from a client's page tables) and it can only FAKE an inherited fd by
# corrupting the owner field, which tests the check rather than the inheritance.
run_gate "1.56.40 chan #97 ring-3 kill criteria"     "CHAN_RING3_SELFTEST=1"                    "chan-ring3-smoke.sh"

# ⛔⛔ ADDED 1.56.44, AND UNTIL NOW THE #92 ABI BATTERY RAN NOWHERE AT ALL. `edge_abi_selftest` is
# behind `#ifdef EDGE_ABI_SELFTEST`; the define comes only from `EDGE_ABI_SELFTEST=1 sh
# scripts/build.sh`; its only consumer is `scripts/smoke/edge-abi-smoke.sh`; and NOTHING invoked that
# script — not this file, not check.sh, not CI. 168 ABI cases that could not fail, guarding the surface
# ring 3 reaches the GPU through.
# ⚠ This file's own header calls that out for selftests generally; the ABI battery was simply never
# added to the table. It is one of 68 of 83 smokes still missing from it — a separate, larger problem.
run_gate "1.56.44 #92 ABI battery (177 cases, ops 0x01-0x10)" "EDGE_ABI_SELFTEST=1" "edge-abi-smoke.sh"

# --- 1.52.x audio: HDA probe -> reset -> verb ring -> codec graph -> stream DMA-arm ---
run_gate "1.52.x audio HDA (probe/reset/verb/graph/stream)" "" "hda-smoke.sh"

# --- HDMI-audio arc bite 2b: multi-instance probe/enum (2nd HDA controller as instance 1) ---
# (hda-dual-smoke self-builds HDA_HDMI=1 + boots QEMU with two -device intel-hda)
run_gate "HDMI-audio bite 2b (dual-HDA instance-1 probe/enum)" "" "hda-dual-smoke.sh"

# --- 1.53.x FP/SIMD: SSE enable (CR0.EM off/MP on + CR4.OSFXSR) -> movsd + ring-0 f64 mul ---
run_gate "1.53.x FP/SSE enable (movsd + ring-0 f64)" "FP_SELFTEST=1" "fp-selftest-smoke.sh"

# --- 1.53.x FP/SIMD B2: per-proc FXSAVE areas (16-aligned + default FCW/MXCSR) ---
run_gate "1.53.x FP-area (per-proc FXSAVE state)" "FP_AREA_SELFTEST=1" "fp-area-smoke.sh"

# --- 1.53.x FP/SIMD B3: lazy #NM handler services a forced FP-trap (CR0.TS-on-switch live) ---
run_gate "1.53.x FP-#NM (lazy save/restore serviced)" "FP_NM_SELFTEST=1" "fp-nm-smoke.sh"

# --- 1.53.x FP/SIMD B4: real cyrius f64 runs in ring 3 (exec /bin/fpex from disk → run: exit 84) ---
run_gate "1.53.x FP-ring3 (real f64 in ring 3)" "FP_RING3_SELFTEST=1" "fp-ring3-smoke.sh"
run_gate "1.53.x FP-ctxsw (two-proc XMM preservation)" "FP_CTXSW_SELFTEST=1" "fp-ctxsw-smoke.sh"
# Group `naad` (1.57.9 PSWEEP): the only row that writes a SIBLING repo's build dir (../naad/build/naadex).
run_gate "1.53.x naad-ring3 (real DSP library f64 in ring 3, arc end-proof)" "NAAD_RING3_SELFTEST=1" "naad-ring3-smoke.sh" "naad"

# --- 1.56.45 the console's live line: an async log must not alter what the operator is typing ---
# ⛔ THE ONLY FRAMEBUFFER-ORACLE GATE IN THIS SWEEP, and it has to be. The defect it guards is INVISIBLE
# in serial — a log line and a typed line are just two ordered writes there — which is exactly how it was
# once diagnosed from a serial log and ruled "working as intended". Only the fb has a cursor to corrupt.
# ⚠ Plain production build (no selftest env): the stimulus is a real USB mouse one-shot, not a hook.
run_gate "1.56.45 console live line (async log vs. the typed prompt, FB oracle)" "" "console-line-smoke.sh"

# ⭐ 1.56.60 — SHUTDOWN. THIS SMOKE EXISTED SINCE THE 1.55.x ARC AND NOTHING HAS EVER RUN IT:
# `grep -rn shutdown-smoke` over scripts/, scripts/check.sh and .github/workflows/ returned exactly
# one hit tree-wide, inside a docs issue. So even its working arms — the dirty-then-flush barrier
# and the post-shutdown e2fsck — had never gated a release. It is registered now because it finally
# has a real STOP oracle: before 1.56.60 the non-exiting arms asserted only "filesystems flushed"
# and "storage quiesced", both of which the BUGGY spin-halt path emitted, so this smoke reported
# PASS on precisely the defect the 2026-09-03 archaemenid burn found by hand.
# ⚠ THIS ROW DRIVES THE DEFAULT ARM ONLY (agnsh `exit` -> boot_finish -> power_stop_final).
# run_gate passes $buildenv to build.sh, NOT to the smoke, so the reboot/poweroff arms — which are
# the ones QEMU's process-exit oracle covers — cannot be selected from this table as it stands.
# Run those by hand until run_gate can carry smoke-time env:
#     SHUTDOWN_SMOKE_VERB=poweroff sh scripts/smoke/shutdown-smoke.sh
#     SHUTDOWN_SMOKE_VERB=reboot   sh scripts/smoke/shutdown-smoke.sh
# ⛔ A GREEN poweroff ARM UNDER QEMU PROVES PLUMBING ONLY — QEMU's _S5_ package is all zeroes, so
# SLP_TYP=0 is what it wants and a totally broken decode passes by construction. The S5 decode's
# only ground truth is real firmware: agnosticos prior-art/acpi-s5-known-good-archaemenid-0719.txt
# and an iron burn. Do not let a green sweep be read as decode coverage.
run_gate "1.55.x shutdown (flush barrier, named stop terminus, post-shutdown e2fsck)" "" "shutdown-smoke.sh"

# --- parallel --- (SWEEP_JOBS > 1 only: the table above only RECORDED the rows) ---------------------------------
retry_passes=0
if [ "$SWEEP_JOBS" -gt 1 ]; then
    SWEEP_MAIN_SID=$(ps -o sid= -p $$ | tr -d ' ')
    SWEEP_COPY_BASE="$(dirname "$ROOT")/.$(basename "$ROOT").sweep.$$"
    SWEEP_JOBS_USED=0; SWEEP_PIDS=""; SWEEP_CLEANED=0
    # Absolute sibling roots for the copies (their `$ROOT/../x` defaults resolve to the same place anyway).
    export GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}" AGNOSHI_ROOT="${AGNOSHI_ROOT:-$ROOT/../agnoshi}" \
           KASHI_DIR="${KASHI_DIR:-$ROOT/../kashi}" REKHA_DIR="${REKHA_DIR:-$ROOT/../rekha}" \
           NAAD_ROOT="${NAAD_ROOT:-$ROOT/../naad}" DOOM_ROOT="${DOOM_ROOT:-$ROOT/../cyrius-doom}"

    # Copy a worker's logs (never its disk images) back under build/sweep-logs/w<K>/, then delete the copy.
    sweep_reap_copies() {
        k=1
        while [ "$k" -le "$SWEEP_JOBS_USED" ]; do
            c="$SWEEP_COPY_BASE.w$k"
            if [ -d "$c" ]; then
                if [ -d "$c/build" ]; then
                    rsync -a --prune-empty-dirs --exclude=/sweep-tmp/ --include='*/' --include='*.log*' --include='*.txt' --include='*.out' \
                        --include='*.png' --include='*.ppm' --exclude='*' "$c/build/" "$SWEEP_LOGS/w$k/" 2>/dev/null || true
                fi
                rm -rf "$c"
            fi
            k=$((k+1))
        done
    }
    # make .DELETE_ON_ERROR + parallel --termseq: stop every row runner (TERM, up to 10 s, then KILL), then reap.
    # A worker is a session leader (setsid), and the QEMU a smoke starts under its own `timeout` leaves the
    # PROCESS GROUP but never the session, so `pkill -s` is what reaches it. Our own session is never signalled.
    sweep_cleanup() {
        [ "$SWEEP_CLEANED" = 1 ] && return 0
        SWEEP_CLEANED=1
        sids=$(cat "$SWEEP_Q"/sid.* "$SWEEP_Q"/pid.* 2>/dev/null | sort -u)
        live_sids=""
        for s in $sids; do
            [ -n "$s" ] && [ "$s" != "$SWEEP_MAIN_SID" ] && pgrep -s "$s" >/dev/null 2>&1 && live_sids="$live_sids $s"
        done
        if [ -n "$live_sids" ]; then
            echo "  stopping row runners (sessions:$live_sids)"
            for s in $live_sids; do pkill -TERM -s "$s" 2>/dev/null; done
            t=0
            while [ "$t" -lt 10 ]; do
                left=0; for s in $live_sids; do pgrep -s "$s" >/dev/null 2>&1 && left=1; done
                [ "$left" = 0 ] && break
                sleep 1; t=$((t+1))
            done
            for s in $live_sids; do pkill -KILL -s "$s" 2>/dev/null; done
        fi
        for p in $SWEEP_PIDS; do kill -TERM "$p" 2>/dev/null; done   # no-setsid fallback: at least the workers
        sweep_reap_copies
        rm -rf "$ROOT/build/sweep-tmp"   # the main-tree row runner's TMPDIR (the copies' go with the copies)
    }
    sweep_interrupted() {
        echo ""; echo "sweep: interrupted — stopping workers, removing worker copies, restoring a plain build/agnos"
        sweep_cleanup
        sh "$ROOT/scripts/build.sh" >/dev/null 2>&1
        rm -rf "$SWEEP_Q"
        exit "$1"
    }
    trap 'sweep_cleanup; rm -rf "$SWEEP_Q"' EXIT
    trap 'sweep_interrupted 130' INT
    trap 'sweep_interrupted 143' TERM

    # Dispatch order: groups longest-first by the previous run's durations (unknown rows weigh 60 s), ties in
    # table order — so the tail is not one five-minute row picked up last.
    [ -f "$SWEEP_PREV_DUR" ] || : > "$SWEEP_PREV_DUR"
    awk -F'\t' -v dur="$SWEEP_PREV_DUR" '
        BEGIN { while ((getline l < dur) > 0) { split(l, a, "\t"); d[a[2]] = a[1] } }
        { w[$2] += (($3 in d) ? d[$3] : 60); if (!($2 in first)) first[$2] = $1 }
        END { for (g in w) printf "%d\t%d\t%s\n", w[g], first[g], g }' "$SWEEP_Q/rowmap" \
        | sort -t "$(printf '\t')" -k1,1nr -k2,2n | cut -f3 > "$SWEEP_Q/order"
    n_groups=$(wc -l < "$SWEEP_Q/order" | tr -d ' ')
    n_main=$(wc -l < "$SWEEP_Q/main.list" | tr -d ' ')
    n_excl=$(wc -l < "$SWEEP_Q/exclusive.list" | tr -d ' ')
    SWEEP_JOBS_USED=$SWEEP_JOBS; [ "$n_groups" -lt "$SWEEP_JOBS_USED" ] && SWEEP_JOBS_USED=$n_groups
    echo ""
    echo "parallel sweep: $gate_n rows — $n_groups pooled groups over $SWEEP_JOBS_USED worker copies (SWEEP_JOBS=$SWEEP_JOBS),"
    echo "  $n_main in the main tree alongside them, $n_excl exclusive after them (serially, main tree); row ceiling ${SWEEP_ROW_TIMEOUT}s"
    [ -s "$SWEEP_PREV_DUR" ] && echo "  dispatch order: longest-first from the previous run's durations" \
                             || echo "  dispatch order: table order (no previous build/sweep-logs/durations.tsv)"
    SETSID=""; command -v setsid >/dev/null 2>&1 && SETSID="setsid" \
        || echo "  ⚠ setsid not found — workers share this session; an interrupt can orphan a QEMU until its own timeout"

    k=1
    while [ "$k" -le "$SWEEP_JOBS_USED" ]; do
        c="$SWEEP_COPY_BASE.w$k"
        # The CURRENT tree, uncommitted and untracked files included; not build/ (each copy builds its own) EXCEPT
        # build/rootfs/, the staged agnos-fs (stage-agnsh.sh / stage-tools.sh) — the one build/ INPUT a row reads
        # (shutdown-smoke seeds from it; without it the row fails in every copy and "passes on serial retry");
        # not .git (no row needs it — check.sh, which does, runs in the main tree), not the gitignored tmp/.
        if ! rsync -a --delete --exclude=/.git --exclude=/tmp/ --include=/build/ --include='/build/rootfs/***' \
                --exclude='/build/*' "$ROOT/" "$c/"; then
            echo "sweep.sh: could not create worker copy $c" >&2; exit 1
        fi
        mkdir -p "$c/build"
        k=$((k+1))
    done
    echo "  worker copies: $SWEEP_COPY_BASE.w1..w$SWEEP_JOBS_USED"
    echo ""

    if [ "$n_main" -gt 0 ]; then
        $SETSID sh "$ROOT/scripts/sweep.sh" --worker main < /dev/null &
        echo $! > "$SWEEP_Q/pid.main"; SWEEP_PIDS="$SWEEP_PIDS $!"
    fi
    k=1
    while [ "$k" -le "$SWEEP_JOBS_USED" ]; do
        $SETSID sh "$SWEEP_COPY_BASE.w$k/scripts/sweep.sh" --worker "w$k" < /dev/null &
        echo $! > "$SWEEP_Q/pid.w$k"; SWEEP_PIDS="$SWEEP_PIDS $!"
        k=$((k+1))
    done
    for p in $SWEEP_PIDS; do wait "$p"; done
    SWEEP_PIDS=""
    sweep_reap_copies
    SWEEP_T_PAR=$(date +%s)

    # Bazel `exclusive`: the wall-time-ratio rows, alone and serially, in the main tree — as SWEEP_JOBS=1 runs them.
    for n in $(cat "$SWEEP_Q/exclusive.list"); do
        sweep_read_row "$n"; x_t0=$(date +%s)
        gate_exec "$r_label" "$r_env" "$r_smoke" "$r_slug" > "$SWEEP_Q/$n.out" 2>&1 && x_rc=0 || x_rc=$?
        x_dur=$(( $(date +%s) - x_t0 ))
        printf '%s\t%s\t%s\n' "$x_rc" "$x_dur" "excl" > "$SWEEP_Q/$n.res"
        case "$x_rc" in 0) x_v=PASS;; 2) x_v="FAIL (build)";; *) x_v=FAIL;; esac
        printf '  [%-4s] %3ss  %-12s row %2s  %s\n' "excl" "$x_dur" "$x_v" "$n" "$r_label"
    done

    # Sections in ROW ORDER (make -O / parallel --keep-order), each also kept as <slug>.parallel.log.
    : > "$SWEEP_LOGS/durations.tsv"; : > "$SWEEP_Q/failed"
    n=1
    while [ "$n" -le "$gate_n" ]; do
        sweep_read_row "$n"
        if [ -f "$SWEEP_Q/$n.res" ]; then
            IFS="$(printf '\t')" read -r p_rc p_dur p_w < "$SWEEP_Q/$n.res"
        else
            p_rc=1; p_dur=0; p_w="none"
            printf '\n=== %s ===\n  NO RESULT — the row never reported (worker lost or interrupted) — scored FAIL\n' "$r_label" > "$SWEEP_Q/$n.out"
        fi
        # A worker copy is gone by now; its logs were copied back to build/sweep-logs/w<K>/, so name them there.
        # Only LOG paths are rewritten; any other copy path is left as is, naming the (deleted) worker copy.
        { sed -E "s#$SWEEP_COPY_BASE\.w([0-9]+)/build/([^[:space:]]*log)#$SWEEP_LOGS/w\1/\2#g" "$SWEEP_Q/$n.out" 2>/dev/null
          printf '  [ran on %s, %ss]\n' "$p_w" "$p_dur"; } > "$SWEEP_LOGS/$r_slug.parallel.log"
        cat "$SWEEP_LOGS/$r_slug.parallel.log"
        [ "$p_w" != none ] && printf '%s\t%s\n' "$p_dur" "$r_label" >> "$SWEEP_LOGS/durations.tsv"
        echo "$p_rc" > "$SWEEP_Q/$n.final"
        # pytest-rerunfailures / Bazel FLAKY: every row that failed IN PARALLEL gets ONE serial re-run below.
        # An exclusive row already ran serially — its verdict is the serial verdict, as with SWEEP_JOBS=1.
        [ "$p_rc" != 0 ] && [ "$p_w" != "excl" ] && echo "$n" >> "$SWEEP_Q/failed"
        n=$((n+1))
    done

    if [ -s "$SWEEP_Q/failed" ]; then
        echo ""
        echo "--- serial retry (main tree, one at a time) of the $(wc -l < "$SWEEP_Q/failed" | tr -d ' ') row(s) that failed in parallel ---"
        for n in $(cat "$SWEEP_Q/failed"); do
            sweep_read_row "$n"
            gate_exec "$r_label" "$r_env" "$r_smoke" "$r_slug.serial-retry" && s_rc=0 || s_rc=$?
            if [ "$s_rc" = 0 ]; then echo "retry-pass" > "$SWEEP_Q/$n.final"; else echo "$s_rc" > "$SWEEP_Q/$n.final"; fi
        done
    fi

    n=1
    while [ "$n" -le "$gate_n" ]; do
        sweep_read_row "$n"; f_rc=$(cat "$SWEEP_Q/$n.final")
        case "$f_rc" in
            0)          pass=$((pass+1)); results="$results\n  PASS  $r_label" ;;
            retry-pass) pass=$((pass+1)); retry_passes=$((retry_passes+1))
                        results="$results\n  PASS  $r_label  (passed on serial retry; parallel log: $SWEEP_LOGS/$r_slug.parallel.log)" ;;
            2)          fail=$((fail+1)); results="$results\n  FAIL  $r_label (build)" ;;
            *)          fail=$((fail+1)); results="$results\n  FAIL  $r_label" ;;
        esac
        n=$((n+1))
    done
fi

# --- Restore the plain production build as the working artifact ---
echo ""
echo "Restoring plain production build..."
sh "$ROOT/scripts/build.sh" >/dev/null 2>&1
echo "  build/agnos: $(stat -c%s "$ROOT/build/agnos" 2>/dev/null || wc -c < "$ROOT/build/agnos") bytes"

echo ""
echo "=========================================="
printf ' SWEEP RESULTS  (%d passed, %d failed)%b\n' "$pass" "$fail" "$results"
if [ "$SWEEP_JOBS" -gt 1 ]; then
    echo "  serial-retry passes: $retry_passes (rows that failed in parallel and passed when re-run alone)"
    SWEEP_T1=$(date +%s)
    echo "  wall clock: $((SWEEP_T1 - SWEEP_T0))s (parallel phase $((SWEEP_T_PAR - SWEEP_T0))s; SWEEP_JOBS=$SWEEP_JOBS, $SWEEP_JOBS_USED copies)"
fi
echo "  per-attempt logs: $SWEEP_LOGS"
echo "=========================================="
if [ -n "$SWEEP_ONLY" ]; then
    echo "SWEEP_ONLY='$SWEEP_ONLY' — $skipped rows skipped: NOT A SWEEP VERDICT"
    [ "$fail" = 0 ] && exit 3 || exit 1
fi
[ "$fail" = 0 ] && { echo "ARC SWEEP: PASS"; exit 0; } || { echo "ARC SWEEP: FAIL"; exit 1; }
