#!/bin/sh
# syscall-harden-smoke.sh — runs SYSCALL_HARDEN_SELFTEST and gates on its verdict.
#
# ⛔ THIS SELFTEST EXISTED SINCE 1.41.5 WITH NO RUNNER. `SYSCALL_HARDEN_SELFTEST` appeared only in
# scripts/build.sh's compile-gate list — no smoke drove it, so nothing in check.sh or sweep.sh ever
# executed it. It is the ONLY coverage the epoll / timerfd / signalfd syscalls have (its own header
# says so), and it was dark. Written 2026-08-05 alongside the channel-band bite 0, which added a
# regression lock to it that would have been equally dark.
#
# What it asserts, from the kernel side via ksyscall():
#   - epoll / timerfd / signalfd fd type-confusion REJECTIONS (the 1.41.5 security fixes)
#   - epoll_ctl watch-fd bounds (vs a vfs_table OOB index)
#   - ⭐ epoll_wait on a real epoll fd with an UNEXPIRED timerfd RETURNS 0 rather than hanging the box
#   - ext2 basename 255-cap refusal
#
# ⛔ THE BITE-0 CASE'S ORACLE IS A TIMEOUT, NOT AN ASSERTION. On a kernel carrying the old bare
# `arch_wait()` (hlt with no sti, inside an IF=0 handler) that epoll_wait never returns, the boot dies
# mid-selftest, and this script sees NO `shsys:` line at all. So "no verdict" is reported here as the
# hang it is, distinctly from "verdict says FAIL" — the two mean different things and a single
# grep-for-PASS would collapse them.
#
# Leaves the tree at a plain production kernel.
set -e
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=== syscall-harden (epoll/timerfd/signalfd + the bite-0 hang lock) smoke ==="
echo "Building SYSCALL_HARDEN_SELFTEST kernel..."
SYSCALL_HARDEN_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/dev/null 2>&1

echo "Booting (via the agnsh-smoke NVMe harness)..."
sh "$ROOT/scripts/smoke/agnsh-smoke.sh" >/dev/null 2>&1 || true

LOG="$ROOT/build/agnsh-smoke-logs/agnsh.log"
rc=0

if ! strings "$LOG" 2>/dev/null | grep -q "shsys:"; then
    echo "  FAIL: the selftest produced NO verdict line at all."
    echo "        That is the HANG signature, not a missing assertion — on a kernel with the bare"
    echo "        arch_wait() restored, epoll_wait never returns and the boot stops inside the"
    echo "        selftest. Check the tail of the log for where it stopped."
    strings "$LOG" 2>/dev/null | tail -5
    rc=1
else
    if strings "$LOG" 2>/dev/null | grep -q "shsys: epoll_wait returned, no hang"; then
        echo "  PASS: epoll_wait on an unexpired timerfd RETURNED (channel-band bite 0)"
    else
        echo "  FAIL: the epoll_wait no-hang line is absent, but other shsys: output exists —"
        echo "        the selftest reached a verdict without getting that far. Not the hang; look above it."
        strings "$LOG" 2>/dev/null | grep "shsys:" || true
        rc=1
    fi

    for want in "shsys: shm owner gate OK|shm #74 owner gate + release-at-death (bite 1)" \
                "shsys: proc_epoch bumps on reuse OK|proc_epoch increments when a slot is recycled (bite 2)"; do
        line="${want%%|*}"; desc="${want#*|}"
        if strings "$LOG" 2>/dev/null | grep -q "$line"; then
            echo "  PASS: $desc"
        else
            echo "  FAIL: $desc"
            strings "$LOG" 2>/dev/null | grep "shsys:" || true
            rc=1
        fi
    done

    if strings "$LOG" 2>/dev/null | grep -q "shsys: ALL PASS"; then
        echo "  PASS: every syscall-hardening assertion (type-confusion, bounds, basename cap)"
    else
        echo "  FAIL: syscall-hardening assertions did not all pass"
        strings "$LOG" 2>/dev/null | grep "shsys:" || true
        rc=1
    fi
fi

echo "Restoring production kernel (selftest gated off)..."
sh "$ROOT/scripts/build.sh" >/dev/null 2>&1

if [ "$rc" -eq 0 ]; then echo "syscall-harden-smoke: PASS"; else echo "syscall-harden-smoke: FAIL"; fi
exit $rc
