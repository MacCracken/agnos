#!/bin/bash
# ZFS ring-3 smoke (agnos 1.57.11) — the sweep row for scripts/harness/zfs-ring3-test.py: the PLAIN production
# kernel boots to agnsh with an ext2 root and the fixture's OpenZFS pool as a third partition, and agnsh runs
# tests/zfs/zfsx FROM the pool (/mnt/zfs/agnostank/payload/zfsx) — exec-from-ZFS plus every read-side syscall
# over /mnt/zfs and every write verb refused. The exit code of zfsx is the verdict (95 = PASS); the harness
# names the failed clause otherwise. Exit 0 PASS · 1 FAIL · 2 VOID / infrastructure (no fixture, no shell).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOGS="$ROOT/build/zfs-ring3-logs"; rm -rf "$LOGS"; mkdir -p "$LOGS"
echo "=== ZFS ring-3 smoke (zfsx exec'd from /mnt/zfs; plain kernel) ==="
python3 "$ROOT/scripts/harness/zfs-ring3-test.py" > "$LOGS/harness.log" 2>&1
rc=$?
cat "$LOGS/harness.log"
[ -f "$ROOT/build/zfs-ring3/serial.log" ] && cp "$ROOT/build/zfs-ring3/serial.log" "$LOGS/serial.log"
if [ "$rc" = 0 ]; then echo "zfs-ring3-smoke: PASS"; exit 0; fi
if [ "$rc" = 2 ]; then echo "zfs-ring3-smoke: VOID (no fixture, or agnsh never came up) — logs $LOGS"; exit 2; fi
echo "zfs-ring3-smoke: FAIL — logs $LOGS"
exit 1
