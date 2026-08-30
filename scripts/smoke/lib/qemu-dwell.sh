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

# qemu_dwell_kernel — qemu_dwell, retried when the FIRMWARE never handed off to the kernel.
#
# ⛔⛔ 1.56.51, MEASURED. On this box roughly 1 boot in 4 (far more under load) never leaves OVMF:
# the serial log ends in "Please select boot device" and the kernel banner never appears. The kernel
# under test did not execute, so the run measured NOTHING — yet every assertion afterwards evaluates
# against an empty log and the smoke reports a wall of failures. edge-abi-smoke printed
# "FAILED -- 1 correct, 22 wrong" from exactly this, and agnsh-smoke's version of it cost a wrong
# bisect during the 1.56.51 sweep (a kernel change was blamed, then found to pass on re-run).
# Raising QEMU_TIMEOUT does not help — the boot menu is terminal, not slow.
#
# ⭐ THE RETRY IS GATED ON THE KERNEL BANNER, WHICH IS WHAT MAKES IT SOUND. "The kernel never
# started" and "the kernel started and failed" are different events and only the first may be
# retried. A blind re-run — sweep.sh's unconditional second attempt — gives a REAL regression two
# chances to look like a flake. This gives it none: once the banner is in the log, the run stands
# whatever the assertions say.
#
# Usage (identical to qemu_dwell, plus $4 = the vars.fd to refresh per attempt; pass "" to skip):
#   qemu_dwell_kernel "$LOG" "agnos>" "$TIMEOUT" "$WORK/vars.fd" "$OVMF_VARS_SRC" qemu-system-x86_64 ...
# Env: QEMU_TRIES (default 6).
# ⛔⛔ SIX, NOT THREE — AND THE OLD NUMBER WAS SET AGAINST A RATE THAT IS NOT THE REAL ONE. The header
# above says "roughly 1 boot in 4" never leaves OVMF. MEASURED 2026-08-30 on this host by running one
# smoke four times and counting attempts: **3 kernel banners in 10 attempts, ~30% hand-off success**,
# with a retry needed on every single run and one run exhausting all three tries. At 3 tries that
# leaves ~34% of gates reporting infrastructure as a kernel failure; at 6 it is ~12%, and under sweep
# load (many QEMU launches back to back) the per-attempt rate is worse still, not better.
# ⚠ THE COST IS PAID ONLY BY A KERNEL THAT CANNOT BOOT, which is exactly the case `check.sh` and
# `test.sh` catch first and far more cheaply. A booting kernel stops at its first successful attempt.
# ⚠ Retries are still BANNER-GATED, so raising this gives a real regression no extra chances: once the
# banner is in the log the run stands, whatever the assertions then say.
qemu_dwell_kernel() {
    _qk_log="$1"; _qk_marker="$2"; _qk_max="$3"; _qk_vars="$4"; _qk_varsrc="$5"; shift 5
    _qk_tries="${QEMU_TRIES:-6}"
    _qk_i=1
    while [ "$_qk_i" -le "$_qk_tries" ]; do
        # A fresh NVRAM per attempt: a half-written vars.fd from a killed run is itself a way to
        # land in the boot menu, so the retry must not inherit the previous attempt's state.
        if [ -n "$_qk_vars" ] && [ -n "$_qk_varsrc" ]; then
            cp "$_qk_varsrc" "$_qk_vars" && chmod +w "$_qk_vars"
        fi
        qemu_dwell "$_qk_log" "$_qk_marker" "$_qk_max" "$@"
        if strings "$_qk_log" 2>/dev/null | grep -q "AGNOS kernel v"; then return 0; fi
        if [ "$_qk_i" -lt "$_qk_tries" ]; then
            echo "  (firmware never handed off — kernel did not start; retrying $_qk_i/$((_qk_tries - 1)))" >&2
        else
            echo "  UEFI never handed off to the kernel in $_qk_tries attempts — INFRASTRUCTURE, not the kernel." >&2
            echo "  Any assertion below describes an EMPTY log; treat this run as VOID, not as a failure." >&2
        fi
        _qk_i=$((_qk_i + 1))
    done
    return 0
}

# qemu_assert_booted <log> — did the kernel actually RUN? Call this immediately after a QEMU run and
# BEFORE any assertion, in any smoke that does not go through qemu_dwell_kernel.
#
# ⛔⛔ WHY THIS EXISTS SEPARATELY FROM qemu_dwell_kernel. Measured across four 1.56.52 sweeps: of the
# 24 gate smokes, 2 used the guarded helper, 7 used the bare qemu_dwell (converted 2026-08-30), and
# NINE roll their own `timeout … qemu-system-x86_64 …` with no hand-off check of any kind. Every gate
# that failed in any of those sweeps — FAT read, chan-ring3, exFAT write, fp-selftest, fp-ring3 — was
# from those two unguarded groups, and not one guarded gate ever failed. The signature is always the
# same and it is in the log:
#     gnoboot v0.7.1: handing off to kernel
#     gnoboot: fail @ EBS
#     BdsDxe: loading Boot0000 "BootManagerMenuApp"
# The kernel never executed, so every assertion afterwards evaluates against an EMPTY log and the
# smoke prints a wall of failures naming real properties. fp-ring3 reported "fpex never dispatched";
# chan-ring3 reported NINE ring-3 isolation properties as broken. A reader would conclude the kernel
# regressed.
#
# ⚠ THIS DOES NOT RETRY — the nine callers build their QEMU command inline in nine different shapes,
# and wrapping each in a retry loop is a rewrite of nine working scripts for a benefit sweep.sh's
# run_gate already partly provides (it makes a second attempt on failure). What this DOES give is an
# honest verdict: one VOID line instead of a wall of false property failures, and a non-zero exit so
# run_gate retries. ⇒ These nine effectively get 2 attempts where a qemu_dwell_kernel gate gets 6.
# Converting them properly is worth doing; this is the honest floor until then.
#
# Returns 0 if the kernel banner is present, 1 otherwise (and prints why).
qemu_assert_booted() {
    if strings "$1" 2>/dev/null | grep -q "AGNOS kernel v"; then return 0; fi
    echo "  UEFI never handed off to the kernel — the kernel under test DID NOT EXECUTE."
    echo "  Any assertion below would describe an EMPTY log. Treat this run as VOID, not as a failure."
    if strings "$1" 2>/dev/null | grep -q "fail @ EBS"; then
        echo "  (gnoboot: fail @ EBS — the firmware ExitBootServices hand-off, the known ~1-in-4 flake)"
    fi
    return 1
}
