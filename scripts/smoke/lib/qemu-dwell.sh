# qemu-dwell.sh — sourced helper: run QEMU until a marker appears, not until a clock runs out.
#
# ⛔ THE PROBLEM THIS SOLVES IS DEAD AIR, NOT SLOWNESS. Measured 2026-07-23 and recorded in
# docs/development/state.md: `scripts/sweep.sh` takes ~10-20 min and almost all of it is waiting for
# nothing. **QEMU never exits on its own** — the kernel boots, prints, halts, and sits there — so every
# smoke consumes its ENTIRE `QEMU_TIMEOUT` even when the work finished in two seconds. Proven by
# shrinking one: `fp-selftest-smoke` returns "4 passed, 0 failed" IDENTICALLY at 40 / 15 / 8 / 5 s. The
# kernel build itself is ~1 s.
#
# ⛔ AND THE OBVIOUS FIX IS THE WRONG ONE. "Just lower the timeouts" trades dead air for FLAKY
# TRUNCATION — a slower host, a TCG (no-KVM) run, or one extra selftest and the log is cut off
# mid-assertion, which reads as a failed gate. The timeout must stay generous; what changes is that we
# stop waiting once the thing we are waiting FOR has happened.
#
# ⛔ THE FLUSH RACE IS REAL AND IS HANDLED. `hda-smoke.sh` documents why the synchronous form was
# chosen: *"Running synchronously under `timeout` (no background/poll/kill) avoids the serial-file
# flush race — the file is fully written once QEMU has exited."* That guarantee is preserved here, not
# discarded: on a marker hit we SIGTERM and then **wait for the process to actually exit** before
# returning, so every caller still reads a log written by a QEMU that is gone. `wait` is the whole
# trick; a bare `kill` and an immediate `grep` would reintroduce exactly that race.
#
# ⛔ CHOOSING A MARKER IS THE DANGEROUS PART. Stop on a line that is printed BEFORE something the smoke
# asserts, and you have built a truncation bug that looks like a kernel regression. The safe marker for
# a BOOT-TIME selftest is the shell prompt (`agnos>` / `[ASSIST] >`): every boot selftest runs from
# main.cyr before kybernet execs the shell, so anything it printed is already in the log. A smoke that
# drives the shell INTERACTIVELY (feeding commands and asserting on their output) must NOT use the
# prompt — its output comes after. Pass that smoke's own last expected line instead.
#
# Usage:
#   . "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
#   qemu_dwell "$LOG" "agnos>" "${QEMU_TIMEOUT:-30}" \
#       qemu-system-x86_64 -machine q35 ... -serial stdio -display none -no-reboot
#
# The QEMU command is run with stdout redirected to $LOG and stderr discarded — matching the
# `2>/dev/null > "$LOG"` form the smokes already use. Returns 0 always (like the `|| true` the
# synchronous form carried): the smoke's own assertions decide pass/fail, never this helper.
#
# Env: QEMU_DWELL_DEBUG=1 prints why the wait ended (marker / self-exit / timeout) and how long it took.

qemu_dwell() {
    _qd_log="$1"; _qd_marker="$2"; _qd_max="$3"; shift 3

    : > "$_qd_log"
    "$@" 2>/dev/null > "$_qd_log" &
    _qd_pid=$!

    # Poll at 4 Hz. The ceiling is the SAME budget the synchronous form had, so a genuinely slow or
    # hung boot fails exactly as before — this only shortens the success case.
    _qd_ticks=$(( _qd_max * 4 ))
    _qd_i=0
    _qd_why="timeout"
    while [ "$_qd_i" -lt "$_qd_ticks" ]; do
        if ! kill -0 "$_qd_pid" 2>/dev/null; then _qd_why="self-exit"; break; fi
        # -a: the serial log carries NUL bytes and grep would otherwise call it binary and stay silent.
        if grep -qa -- "$_qd_marker" "$_qd_log" 2>/dev/null; then _qd_why="marker"; break; fi
        sleep 0.25
        _qd_i=$(( _qd_i + 1 ))
    done

    # Stop it, then WAIT — this is what preserves the "log is complete once QEMU has exited" guarantee
    # the synchronous form relied on. TERM first; KILL only if it ignores that.
    if kill -0 "$_qd_pid" 2>/dev/null; then
        kill -TERM "$_qd_pid" 2>/dev/null || true
        _qd_g=0
        while [ "$_qd_g" -lt 20 ]; do
            kill -0 "$_qd_pid" 2>/dev/null || break
            sleep 0.1
            _qd_g=$(( _qd_g + 1 ))
        done
        # ⛔ `|| true`: under `set -e` a bare `A && B` that short-circuits returns non-zero and aborts
        # the calling smoke. Already-exited is the COMMON case here, not an error.
        if kill -0 "$_qd_pid" 2>/dev/null; then kill -KILL "$_qd_pid" 2>/dev/null || true; fi
    fi
    wait "$_qd_pid" 2>/dev/null || true
    sync

    # ⛔ `${VAR:-}`, NOT `$VAR`. The smokes run under `set -eu`; a bare `$QEMU_DWELL_DEBUG` is an
    # unbound-variable ABORT on every run that does not set it. That shipped for one iteration and
    # broke 7 sweep gates, and it hid itself: the only run that passed was the one where the debug
    # variable WAS set, i.e. the measurement taken to validate the change was the single
    # configuration that dodged the bug.
    if [ -n "${QEMU_DWELL_DEBUG:-}" ]; then
        echo "  [qemu-dwell] ended on $_qd_why after $(( _qd_i / 4 ))s (budget ${_qd_max}s)"
    fi
    return 0
}
