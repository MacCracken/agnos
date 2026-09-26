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
# Env: QEMU_DWELL_DEBUG=1 prints why the wait ended (marker / self-exit / timeout / void) and how long it took.
# Env: QEMU_DWELL_VOID=<ERE> (1.57.6, OPT-IN, unset = unchanged behaviour for every other caller) ends the
#      wait EARLY when the log matches it — for a firmware hand-off that has already failed. ⛔ WHY: the
#      dwell is sized for the SLOWEST successful boot, and a failed hand-off (`gnoboot: fail @ EBS` ->
#      `BootManagerMenuApp`) is terminal, so it used to burn the whole budget before qemu_dwell_kernel could
#      retry. tsc-smoke's CPU-quota mode needs a 900 s budget (TCG at 25% of a CPU), and its first run
#      sat at the OVMF boot menu for ten minutes (of a 15-minute budget) before it was killed by hand. Pass only a pattern that can NEVER appear in a run
#      where the kernel started — the retry is still gated on the banner, so a match after the banner
#      merely stops the wait early and the caller's assertions decide.

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
        if [ -n "${QEMU_DWELL_VOID:-}" ] && grep -qaE -- "$QEMU_DWELL_VOID" "$_qd_log" 2>/dev/null; then _qd_why="void"; break; fi
        sleep 0.25
        _qd_i=$(( _qd_i + 1 ))
    done

    # ⛔ 1.57.7 (IMG-fix) — A MARKER IS SEEN MID-LINE, SO LET THE LINE FINISH BEFORE THE KILL. The poll above
    # reads the log while the guest is still writing it, and a marker that is the PREFIX of the line a smoke then
    # parses (spawn-smoke's "SPAWNX-DONE" before "pass=46 fail=0") can be matched with the rest of the line still
    # in flight: the IMG-fix sweep's spawn row failed attempt 1 on a log ending "SPAWNX-DONE pass=" and scored
    # "reports failures". So after a marker hit, keep QEMU running until the log has stopped growing and ends in a
    # newline (0.2 s stable), or has stopped growing for 1 s (a prompt such as "agnos> " never ends in one), for
    # at most QEMU_DWELL_GRACE seconds (default 2). Only the marker path pays this; timeouts and self-exits don't.
    if [ "$_qd_why" = "marker" ]; then
        _qd_gmax=$(( ${QEMU_DWELL_GRACE:-2} * 5 )); _qd_gi=0; _qd_still=0
        _qd_sz=$(wc -c < "$_qd_log" 2>/dev/null || echo 0)
        while [ "$_qd_gi" -lt "$_qd_gmax" ]; do
            sleep 0.2
            _qd_gi=$(( _qd_gi + 1 ))
            _qd_nsz=$(wc -c < "$_qd_log" 2>/dev/null || echo 0)
            if [ "$_qd_nsz" = "$_qd_sz" ]; then _qd_still=$(( _qd_still + 1 )); else _qd_still=0; _qd_sz="$_qd_nsz"; fi
            if [ "$_qd_still" -ge 1 ] && [ "$(tail -c 1 "$_qd_log" 2>/dev/null | od -An -c | tr -d ' ')" = '\n' ]; then break; fi
            if [ "$_qd_still" -ge 5 ]; then break; fi
        done
    fi

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
    rm -f "$_qk_log".attempt*
    _qk_i=1
    while [ "$_qk_i" -le "$_qk_tries" ]; do
        # A fresh NVRAM per attempt: a half-written vars.fd from a killed run is itself a way to
        # land in the boot menu, so the retry must not inherit the previous attempt's state.
        if [ -n "$_qk_vars" ] && [ -n "$_qk_varsrc" ]; then
            cp "$_qk_varsrc" "$_qk_vars" && chmod +w "$_qk_vars"
        fi
        qemu_dwell "$_qk_log" "$_qk_marker" "$_qk_max" "$@"
        # booted -> the run stands; died -> qemu_attempt_verdict exits the smoke 1 (never retried);
        # VOID -> the attempt's log is kept as $_qk_log.attempt$_qk_i and the next attempt runs.
        if qemu_attempt_verdict "$_qk_log" "$_qk_i"; then return 0; fi
        if [ "$_qk_i" -lt "$_qk_tries" ]; then
            echo "  (retrying $_qk_i/$((_qk_tries - 1)))" >&2
        else
            echo "  UEFI never handed off to the kernel in $_qk_tries attempts — INFRASTRUCTURE, not the kernel." >&2
            echo "  Any assertion below describes an EMPTY log; treat this run as VOID, not as a failure." >&2
        fi
        _qk_i=$((_qk_i + 1))
    done
    return 0
}

# ⛔⛔ 1.57.7 (IMG-fix, review A2) — "NO BANNER" IS TWO DIFFERENT EVENTS, AND ONLY ONE OF THEM IS A VOID.
# Until 1.57.7 every retry here was gated on the banner ALONE and each attempt's log was overwritten by
# the next. So a kernel that died before its banner — a triple fault on the boot stack's first push, the
# exact window the 1.57.7 IMG step moved — was retried as "firmware never handed off", and an
# INTERMITTENT pre-banner death would never have shown: the seven IMG-era retries could not be told
# apart after the fact. The serial log DOES tell them apart, because gnoboot's last act before
# ExitBootServices is to print its hand-off line (gnoboot src/main.cyr efi_main step 12) and the only
# things that can follow it are (a) `gnoboot: fail @ EBS` — EBS refused the map key, gnoboot returned to
# the firmware, the boot menu comes up: the MEASURED ~1-in-4 flake, and the kernel NEVER RAN — or (b) the
# `jmp rax` into the kernel (step 13; nothing between EBS success and the jump can print or fail). So:
#   booted  the banner "AGNOS kernel v" is in the log;
#   died    the hand-off line is there, NO "gnoboot: fail @" line, and no banner: the KERNEL took control
#           and never reached its banner. That is a FAILURE of the kernel under test — never retried,
#           never VOID. qemu_attempt_verdict exits the calling smoke 1 with the kept log's path.
#   void    anything else — no hand-off line (OVMF never ran gnoboot, or was still in firmware when the
#           dwell ended), a "gnoboot: fail @ XXXX" line, an empty log: the kernel never executed.
# ⚠ Residual, stated rather than hidden: a firmware that HANGS inside ExitBootServices (never returns)
# would read as "died". No such hang has been observed; the kept attempt log shows it if it ever happens.
qemu_boot_class() {
    if strings "$1" 2>/dev/null | grep -q "AGNOS kernel v"; then echo booted; return 0; fi
    if strings "$1" 2>/dev/null | grep -q "handing off to kernel"; then
        if ! strings "$1" 2>/dev/null | grep -q "gnoboot: fail @"; then echo died; return 0; fi
    fi
    echo void
    return 0
}

# qemu_void_why <log> — the evidence for a VOID classification, as one phrase.
qemu_void_why() {
    _qv_f=$(strings "$1" 2>/dev/null | grep -o "gnoboot: fail @ [A-Z]*" | head -1)
    if [ -n "$_qv_f" ]; then echo "$_qv_f"; return 0; fi
    if [ ! -s "$1" ]; then echo "empty log — QEMU produced no output"; return 0; fi
    if strings "$1" 2>/dev/null | grep -q "BdsDxe: failed to load"; then
        echo "OVMF could not load the boot image (BdsDxe: failed to load) — gnoboot never ran"; return 0
    fi
    if strings "$1" 2>/dev/null | grep -qE "Please select boot device|BootManagerMenuApp"; then
        echo "OVMF boot menu with no gnoboot hand-off line — gnoboot never ran"; return 0
    fi
    echo "no gnoboot hand-off line — still in firmware when the dwell ended"
    return 0
}

# qemu_attempt_verdict <log> <attempt#> — one retry-loop step, for qemu_dwell_kernel AND for the smokes that
# roll their own retry loop. Returns 0 when the kernel booted (stop retrying); returns 1 for a VOID attempt
# (retry), after keeping its log as <log>.attempt<N> and saying WHY it is a VOID; for a "died" attempt it
# keeps the log the same way, prints the FAIL and EXITS THE SMOKE 1 (these helpers are sourced, so `exit`
# ends the caller) — a kernel that ran and died is never another attempt's business.
qemu_attempt_verdict() {
    _qa_c=$(qemu_boot_class "$1")
    [ "$_qa_c" = "booted" ] && return 0
    cp "$1" "$1.attempt$2" 2>/dev/null || true
    if [ "$_qa_c" = "died" ]; then
        echo "  FAIL: attempt $2 — gnoboot handed off (no 'fail @' line) and the kernel never printed its banner:" >&2
        echo "        the KERNEL took control and died before 'AGNOS kernel v'. Not a firmware VOID; not retried." >&2
        echo "        log: $1.attempt$2" >&2
        echo "  FAIL: kernel died before its banner (attempt $2, log $1.attempt$2)"
        exit 1
    fi
    echo "  (VOID attempt $2: $(qemu_void_why "$1") — the kernel never ran; log kept: $1.attempt$2)" >&2
    return 1
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
    # 1.57.7 (IMG-fix, A2): a kernel that took control and died before its banner is a FAIL, not a VOID —
    # qemu_attempt_verdict prints it and exits the smoke 1 (see qemu_boot_class).
    if [ "$(qemu_boot_class "$1")" = "died" ]; then qemu_attempt_verdict "$1" "final"; fi
    echo "  UEFI never handed off to the kernel — the kernel under test DID NOT EXECUTE ($(qemu_void_why "$1"))."
    echo "  Any assertion below would describe an EMPTY log. Treat this run as VOID, not as a failure."
    if strings "$1" 2>/dev/null | grep -q "fail @ EBS"; then
        echo "  (gnoboot: fail @ EBS — the firmware ExitBootServices hand-off, the known ~1-in-4 flake)"
    fi
    return 1
}

# SMOKE_INVARIANT_DENY (1.57.6, agnos S3-fix) — the kernel's LATCHED invariant lines. Each prints once per boot to
# klug + COM1 (lock-free) and never to a failing exit code, so a gate that does not grep for them scores PASS while
# they fire. Every production-path smoke denies them (agnsh, exec, fork, spawn, kstack) and so do the Python harnesses
# (run37 / agnsh-bg-smp4 / agnsh-multijob / wait-kbd), which LOAD IT THROUGH scripts/harness/_invdeny.py (1.57.7 S3d) —
# no pasted copy is left to drift. ⚠ Keep it ONE double-quoted assignment on ONE line: _invdeny.py extracts that
# line's quoted value and refuses anything else (a continuation would silently drop alternatives from every harness).
#   sched: refused non-ready pick            do_context_switch's tripwire (sched.cyr)
#   sched: exec_and_wait entered with ...    sched_assert_oob (preempt_count != 0, or IF=1)
#   sched: kernel_resume with ...            sched_assert_oob (preempt_count != 0)
#   syscall: kernel stack is not the caller  kstack_check_entry: a switch path missed kstack_install
#   PANIC: Double Fault                      exc_df_report: the #DF stub (a kernel stack is gone)
#   boot: BSP stack window not free RAM      (1.57.7 IMG-fix) mbi.cyr bootstack_window_check: the UEFI map calls part
#                                            of [0x390000, 0x3C0000) something other than free RAM
#   wq: wait primitive entered ...           (1.57.7 S3c) sched.cyr wq_assert_if0: arm/cancel/sleep reached with IF=1
#   wq: arm from a non-running ...           wq_arm on a proc that is not RUNNING (state != 2, != 0)
#   wq: current is not running ...           wq_can_block: current's on_cpu is not this CPU (INV-RUN)
#   wq: sleep resumed in a non-running ...   wq_sleep came back READY (a pre-lock guard refused after an early wake)
#   PANIC: wq ...                            wq_sleep: the BLOCK switch was refused with state 6 published (halts)
#   sched: resched gate misconfigured        resched_gates_ok: the 0xE0 (S3c) or 0xE1 (S3d) gate is not DPL0/IST0/0x08
#                                            at its stub
#   IDLE REFUSED A READY PICK                (1.57.7 S3d) sched.cyr sched_idle_step: the idle's yield refused READY
#                                            work 1000 times in a row on one CPU (never on a correct kernel)
#   exec: exec_and_wait is boot-only        (1.57.7 S3b) ring3.cyr: an out-of-band exec was attempted after
#                                            `sched_active = 1` (refused, -1)
#   fg: IF=0 ring-3 caller                   (S3b) the INV-FG-1 tripwire at #14/#44: a ring-3 process ran IF=0 after
#                                            the scheduler started
#   fg: kernel_run_child cannot block        (S3b) kmain's launch was refused (preempt held / cannot block)
#   fg: execwait cannot block / fg: execwait wait ended abnormally   (S3b) sys_execwait's refusal / an abnormal wait
#   net: lock overlap                        (1.57.7 S4) tcp_lock / net_tx_begin: two holders inside one net lock
#   net: lock missing                        (1.57.7 S4) nic_send / net_lo_enqueue / tcp_send_pkt_seq reached without
#                                            its lock (net_tx_lock / tcp_tab_lock) — best-effort witnesses
# ⚠ NOT denied (a test requires it): "execwait: first scheduled child" (S3b's #37 witness — fg-smoke, run37-smp4);
#   "virtio-net: TX ring full - frame dropped" (S4: a diagnostic latch, a burst
#   may legitimately fill the ring); "wq: first cross-CPU resume from a kernel wait" (klug-only witness, waitx P8);
#   "kbd: line owner reclaimed from a dead process" (klug-only, S3d; S7's KBDNEXT asserts its absence in its phase).
# kstack-smoke denies this whole pattern too (1.57.7; it carried its own shorter list until then).
SMOKE_INVARIANT_DENY="sched: refused non-ready pick|sched: exec_and_wait entered with|sched: kernel_resume with|syscall: kernel stack is not the caller|PANIC: Double Fault|boot: BSP stack window not free RAM|wq: wait primitive entered|wq: arm from a non-running|wq: current is not running|wq: sleep resumed in a non-running|PANIC: wq|sched: resched gate misconfigured|IDLE REFUSED A READY PICK|exec: exec_and_wait is boot-only|fg: IF=0 ring-3 caller|fg: kernel_run_child cannot block|fg: execwait cannot block|fg: execwait wait ended abnormally|net: lock overlap|net: lock missing|proc: orphan zombie recycled|lifecycle: park refused|lifecycle: signal point with preempt held|lifecycle: claimed a kernel continuation"

# smoke_accel <smp> — the QEMU accelerator + CPU model for a boot at `-smp <smp>` (1.57.6, agnos S3).
#
# ⛔ A -smp 4 GATE UNDER SINGLE-THREADED TCG PROVES NOTHING ABOUT PARALLELISM. The races the Path-2
# kernel-stack work closes (a CPU resuming a process whose frame another CPU is still popping, a slot
# reused under a CPU still on it) need the vCPUs to really run at once. So a multi-CPU boot prefers
# KVM (`-enable-kvm -cpu host` — the fp-ctxsw-smoke.sh precedent; this AMD host keeps
# ibrs_supported=0 under KVM, so the `syscall: stub` size oracle is unchanged) and otherwise asks for
# MULTI-threaded TCG explicitly. ⚠ -smp 1 keeps `-cpu max` (TCG), byte-for-byte what every caller used
# before, so a single-CPU verdict is comparable with its history.
# ⚠ The caller MUST print what it got (the `accel:` line) — a green multi-CPU mutant is only evidence
# when the log says which accelerator produced it.
# Env: SMOKE_KVM=0 forces the TCG form even when /dev/kvm is writable.
smoke_accel() {
    if [ "${1:-1}" -gt 1 ]; then
        if [ -w /dev/kvm ] && [ "${SMOKE_KVM:-1}" = "1" ]; then echo "-enable-kvm -cpu host"; return 0; fi
        echo "-accel tcg,thread=multi -cpu max"; return 0
    fi
    echo "-cpu max"
    return 0
}

# smoke_require_image <image> <expected flags> (1.57.7 IMG-fix, reviews A6/B6) — refuse to boot a kernel this smoke
# was not written for. ⛔ WHY: doom-smoke leaves a DOOM_SELFTEST kernel in build/agnos, and shutdown-smoke — which
# boots whatever build/agnos is on disk — then booted it and scored all three arms PASS (1.57.7 IMG run, set aside
# by hand). A smoke that cannot tell which kernel it boots passes on the wrong one. scripts/build.sh records every
# x86_64 image's provenance in <image>.flags ("flags=<the #defines beyond ARCH_X86_64/ELF64_KERNEL, space-separated>"
# and "md5=<the image's md5>"; bench.sh marks its rewritten-source image flags=BENCH). This refuses (exit 1) when the
# record is missing, when the image changed after build.sh wrote it (a copy from elsewhere), or when the flags differ
# from <expected flags> ("" = the plain production build). The refusal names the fix.
smoke_require_image() {
    _sr_img="$1"; _sr_want="$2"; _sr_meta="$1.flags"
    if [ ! -f "$_sr_meta" ]; then
        echo "  REFUSED: $_sr_img has no provenance record ($_sr_meta) — rebuild it with scripts/build.sh"
        exit 1
    fi
    _sr_have=$(sed -n 's/^flags=//p' "$_sr_meta" | head -1)
    _sr_md5=$(sed -n 's/^md5=//p' "$_sr_meta" | head -1)
    _sr_now=$(md5sum "$_sr_img" 2>/dev/null | cut -d' ' -f1)
    if [ -z "$_sr_md5" ] || [ "$_sr_md5" != "$_sr_now" ]; then
        echo "  REFUSED: $_sr_img is not the image scripts/build.sh recorded (md5 $_sr_now, record says ${_sr_md5:-none}) — rebuild it"
        exit 1
    fi
    # compared as SETS (build.sh writes them in #define order, a caller names them in any order)
    _sr_have=$(printf '%s\n' $_sr_have | sort | tr '\n' ' ' | sed 's/ *$//')
    _sr_want=$(printf '%s\n' $_sr_want | sort | tr '\n' ' ' | sed 's/ *$//')
    if [ "$_sr_have" != "$_sr_want" ]; then
        if [ -z "$_sr_want" ]; then
            echo "  REFUSED: this smoke boots the PLAIN production kernel, but $_sr_img was built with [$_sr_have] — run: sh scripts/build.sh"
        else
            echo "  REFUSED: this smoke boots a [$_sr_want] kernel, but $_sr_img was built with [${_sr_have:-plain}]"
        fi
        exit 1
    fi
    return 0
}
