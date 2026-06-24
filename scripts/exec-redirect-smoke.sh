#!/bin/sh
# exec-redirect-smoke.sh — validates the fd-redirect output-capture feature
# (exec_redirect#62 + the execwait#37 hook, 1.46.x). Builds the
# EXEC_REDIRECT_SELFTEST kernel and boots it via the agnsh-smoke NVMe harness;
# the boot-time selftest creates a pipe, arms a redirect of fd 20 -> the pipe
# write end, applies it, writes "HI" to fd 20 (which must route to the pipe, not
# the console), restores, then reads the pipe's read end and asserts "HI" —
# proving a redirected fd's writes land in the dst backend (the same
# exec_redirect_apply/restore the #37 child run uses). Leaves the tree at a
# plain production kernel.
#
# Issue: docs/development/issues/2026-06-15-cyrius-stdlib-missing-syscalls.md
#        group 1 "the high-value one" (fd-redirect for capturing subprocess helpers).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== exec-redirect (fd-redirect capture) smoke ==="
echo "Building EXEC_REDIRECT_SELFTEST kernel..."
EXEC_REDIRECT_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/dev/null 2>&1

echo "Booting (via the agnsh-smoke NVMe harness)..."
sh "$ROOT/scripts/agnsh-smoke.sh" >/dev/null 2>&1 || true

LOG="$ROOT/build/agnsh-smoke-logs/agnsh.log"
rc=0
if strings "$LOG" 2>/dev/null | grep -q "redir: capture OK"; then
    echo "  PASS: a redirected fd's writes were captured to the dst backend (redir: capture OK)"
else
    echo "  FAIL: capture selftest did not pass"
    strings "$LOG" 2>/dev/null | grep -i "redir:" || echo "  (no redir line — selftest did not run / boot stalled before it)"
    rc=1
fi

echo "Restoring production kernel (selftest gated off)..."
sh "$ROOT/scripts/build.sh" >/dev/null 2>&1

if [ "$rc" -eq 0 ]; then echo "exec-redirect-smoke: PASS"; else echo "exec-redirect-smoke: FAIL"; fi
exit $rc
