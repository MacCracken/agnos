# 2026-11-02 — ext2 `rename#31` cannot replace an existing file, so descent never saves a player after creation

**Status:** ✅ RESOLVED in agnos **1.57.17** (track T1) — ext2 `rename#31` replaces an existing destination, atomically
with respect to a crash (one dirent rewritten in place; see the 2026-10-28 file's Status for what shipped and the
crash-cut proof). **descent's own confirmation passes:** `AGNOS_KERNEL=<1.57.17 BENCH_CONNECT_SELFTEST=1 kernel>
SCENARIO=persist scripts/agnos-qemu-smoke.sh` (run in a scratch copy of cyrius-yeomans-descent, KVM) reported
`[PASS] persistence round-trip — inventory survived logout on a real kernel` (3/3 scenarios); with `KEEP=1` the guest's
`data/players/a/` held only `agnosone.cyml` (no stranded `.cyml.tmp`) and `e2fsck -fn` of the partition was clean.
*(Was: 🟡 OPEN.)* This is the same kernel gap as
[`2026-10-28-ext2-rename-cannot-replace-an-existing-file.md`](2026-10-28-ext2-rename-cannot-replace-an-existing-file.md)
("rename-replace is a follow-on bite", `kernel/core/ext2.cyr:3058-3061`). That file records hapi; this one records a
second consumer, for which the gap means **silent loss of player data**.
*(Filed from cyrius-yeomans-descent **1.8.1**, running its `--agnos` build on agnos 1.57.14 booted in QEMU, through
descent's `scripts/agnos-qemu-smoke.sh`.)*
**Checked against:** agnos **bdc587d7** (1.57.14), built with `BENCH_CONNECT_SELFTEST=1`. `ext2_rename` returns -1
when `ext2_dir_lookup(dst_parent, dst_name)` finds the destination.
**Severity:** high for the consumer. Every AGNOS player keeps only their character-creation record. descent will
**not** work around it; it is waiting on this fix.

## What happens

descent (a MUD server) writes each player record crash-safely, per its ADR 0006:

1. Write `data/players/<shard>/<name>.cyml.tmp`.
2. `rename(<name>.cyml.tmp, <name>.cyml)` (`file_rename` → `rename#31`, 4-arg).

The **first** save of a character works, because `<name>.cyml` does not exist yet. **Every later save fails at step
2**, because now it does: the save on `quit`, the periodic autosave sweep, and the login stamp. descent's
`player_save` returns -1, and the failure is written to its audit log as `save.fail.disconnect` /
`save.fail.sweep`. Nothing reaches the console, and the player is not told.

**Measured** on 2026-11-02, with the same probe run against descent 1.8.0 and 1.8.1 (both the same result) and against
a Linux build as a control:

| Step | Linux | agnos 1.57.14 |
|---|---|---|
| create a character, `get notice`, `quit` | ✓ | ✓ |
| reconnect: passphrase verifies, "Last seen moments ago" | ✓ | ✓ |
| `i` after reconnect | carrying the notice | **"You carry nothing."** |

The guest's ext2 root afterwards (the partition extracted and read with `debugfs`):

```
data/players/a/agnosone.cyml        written at character creation
data/players/a/agnosone.cyml.tmp    the latest save, never renamed into place
data/audit.libro                    ... "save.fail.disconnect", "save.fail.sweep"
```

## Why nobody saw it earlier

- **Under mirshi it works,** because mirshi forwards `rename#31` to Linux, where it replaces. descent's earlier sweep
  reported "AGNOS persistence works end to end" from a mirshi run.
- **Until now, nobody could log in on a real kernel.** descent's crash at the first passphrase (its item BU, a
  ring-3 #PF in sigil's first-use TLS install) blocked every login. BU does not reproduce on 1.57.14, and the very
  first real-kernel persistence test found this.

## The fix (agnos's call)

It is the fix the 2026-10-28 issue asks for: `rename#31` on ext2 replacing an existing destination, **atomic with
respect to a crash**, so that after recovery the name refers to either the old inode or the new one. descent needs
nothing beyond that. It does not lock the directory and does not need flock on a directory fd.

The two ring-3 fallbacks (unlink then rename; rewrite in place) each open a crash window in which a player's record
is gone or torn. descent declined both, for the same reason hapi did.

## How to confirm the fix

From a cyrius-yeomans-descent checkout, with an agnos kernel built with `BENCH_CONNECT_SELFTEST=1`:

```sh
AGNOS_KERNEL=<that kernel> SCENARIO=persist scripts/agnos-qemu-smoke.sh
```

Today it reports `[FAIL] persistence round-trip — inventory LOST across logout — the save did not publish`. With
rename able to replace, it should pass. With `KEEP=1`, `data/players/<shard>/` should hold no stranded `.cyml.tmp`.
