#!/bin/sh
# exec-redirect-smoke.sh — validates the fd-redirect output-capture feature (exec_redirect#62). Builds the
# EXEC_REDIRECT_SELFTEST kernel and boots it via the agnsh-smoke NVMe harness. The boot-time selftest drives the
# redirect the way execwait#37 applies it since 1.57.7 (S3b): into a SCRATCH CHILD's private fd table (the child
# inherits a copy, the shape rewrites the copy, the "child" writes as itself, then its table is destroyed — as the
# reap does; nothing is ever restored). Four markers: `redir: capture OK` (fd 20 -> a pipe write end, "HI"
# captured), `redir: stdin-pipe OK` (the child's fd 0 <- a pipe read end; read#5 reaches pipe_read, not the
# keyboard), `redir: multi capture OK` ((20 <- w) then REDIR_ADD (21 <- 20), the `2>&1` shape, both captured in
# order) and `redir: parent table untouched OK` (the parent's — the global table's — slots 0/20/21 byte-identical
# and its fd base unchanged). Leaves the tree at a plain production kernel.
#
# 1.56.39 also covers the spawn_path#43 arm (spawn_fd_shape since 1.57.6): a redirect aimed
# at the GLOBAL vfs_table must be REFUSED with the table untouched, and one aimed at a
# child holding its own private table must rewrite that copy while the global stays
# byte-identical. A boot with no kernel banner is VOID.
#
# Issue: docs/development/issues/2026-06-15-cyrius-stdlib-missing-syscalls.md
#        group 1 "the high-value one" (fd-redirect for capturing subprocess helpers).
set -e
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=== exec-redirect (fd-redirect capture) smoke ==="
echo "Building EXEC_REDIRECT_SELFTEST kernel..."
EXEC_REDIRECT_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/dev/null 2>&1

echo "Booting (via the agnsh-smoke NVMe harness)..."
# AGNSH_SMOKE_FLAGS (1.57.7 IMG-fix): agnsh-smoke refuses any image but the one it is told to expect.
AGNSH_SMOKE_FLAGS=EXEC_REDIRECT_SELFTEST sh "$ROOT/scripts/smoke/agnsh-smoke.sh" >/dev/null 2>&1 || true

LOG="$ROOT/build/agnsh-smoke-logs/agnsh.log"
rc=0
# ⛔ 1.57.6 — VOID, NOT FAIL, WHEN THE KERNEL NEVER RAN. agnsh-smoke retries a failed firmware hand-off
# 3 times; if all three failed, every assertion below would describe an empty log.
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
if ! qemu_assert_booted "$LOG"; then
    sh "$ROOT/scripts/build.sh" >/dev/null 2>&1
    echo "exec-redirect-smoke: VOID"
    exit 2
fi
if strings "$LOG" 2>/dev/null | grep -q "redir: capture OK"; then
    echo "  PASS: a redirected fd's writes were captured to the dst backend (redir: capture OK)"
else
    echo "  FAIL: capture selftest did not pass"
    strings "$LOG" 2>/dev/null | grep -i "redir:" || echo "  (no redir line — selftest did not run / boot stalled before it)"
    rc=1
fi

if strings "$LOG" 2>/dev/null | grep -q "redir: stdin-pipe OK"; then
    echo "  PASS: a redirected fd 0 read from the pipe, not the keyboard (redir: stdin-pipe OK)"
else
    echo "  FAIL: stdin-from-pipe selftest did not pass (read#5 VFS_DEVICE tag guard)"
    strings "$LOG" 2>/dev/null | grep -i "redir:" || echo "  (no redir line)"
    rc=1
fi

# 1.57.6 — two pairs, the 2>&1 shape, applied in order (into the child's copy since 1.57.7).
if strings "$LOG" 2>/dev/null | grep -q "redir: multi capture OK"; then
    echo "  PASS: two armed pairs (20 <- w, ADD 21 <- 20) both captured, in order"
else
    echo "  FAIL: multi-pair capture did not pass"
    strings "$LOG" 2>/dev/null | grep -i "redir:" || echo "  (no redir line)"
    rc=1
fi

# 1.57.7 (S3b) — the parent's table was never touched: #37 applies into the child's copy and restores nothing.
if strings "$LOG" 2>/dev/null | grep -q "redir: parent table untouched OK"; then
    echo "  PASS: the parent's (global) table slots 0/20/21 and its fd base are byte-identical afterwards"
else
    echo "  FAIL: the parent's table changed (or the check never ran)"
    strings "$LOG" 2>/dev/null | grep -i "redir:" || echo "  (no redir line)"
    rc=1
fi

# 1.56.39 — the spawn_path#43 arm (spawn_fd_shape since 1.57.6). Two assertions, and the NEGATIVE one is
# the load-bearing one: it is what caught a real defect in the first build of that function, which
# guarded on `proc_fd_base_get(pid) == 0` and so sailed past proc 0, whose base is set EXPLICITLY to
# &vfs_table (vfs.cyr:264). Without this arm the whole apply path would have shipped unexercised.
if strings "$LOG" 2>/dev/null | grep -q "spawnredir: global table refused"; then
    echo "  PASS: a redirect aimed at the GLOBAL fd table is refused, and the table is untouched"
else
    echo "  FAIL: spawn_fd_shape did not refuse the global table"
    strings "$LOG" 2>/dev/null | grep -i "spawnredir:" || echo "  (no spawnredir line — selftest did not run)"
    rc=1
fi

if strings "$LOG" 2>/dev/null | grep -q "spawnredir: child table swapped OK"; then
    echo "  PASS: a redirect lands in the CHILD's private fd table, global byte-identical"
else
    echo "  FAIL: spawn_fd_shape did not swap the child's private table"
    strings "$LOG" 2>/dev/null | grep -i "spawnredir:" || echo "  (no spawnredir line)"
    rc=1
fi

echo "Restoring production kernel (selftest gated off)..."
sh "$ROOT/scripts/build.sh" >/dev/null 2>&1

if [ "$rc" -eq 0 ]; then echo "exec-redirect-smoke: PASS"; else echo "exec-redirect-smoke: FAIL"; fi
exit $rc
