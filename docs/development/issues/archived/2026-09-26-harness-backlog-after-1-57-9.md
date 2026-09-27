# 2026-09-26 — harness backlog left by 1.57.9 (all pre-existing; none blocks a gate)

**Status:** ✅ **RESOLVED 1.57.10 (2026-09-26)** — all nine items plus the operator's known-red ask: ktest leaves a plain build; 42 dangling issue pointers fixed and check.sh gate 36 (`issue-pointer-check.sh`) keeps them fixed; per-tree check/sweep logs; `ext2` and `blk-write` sweep rows; console-line names the refused flags; no rootfs copy-back; a missing rootfs is staged; `fg-smoke` split in three (830 s → 393 s longest row); `exclusive` kept on with its reason; known-red rows (`SWEEP_KNOWN_RED` / a table flag) get one attempt and no serial retry. See § Resolution.
**Filed by:** agnos, 1.57.9 release pass.
**Checked against:** agnos **1.57.9**, `scripts/`.

1. `scripts/ktest.sh` builds `TEST=1` and never rebuilds plain, so the next plain-kernel smoke is refused by
   `smoke_require_image`. Rebuild plain on exit (as doom-smoke and fault-kill-smoke do).
2. 53 comments in `scripts/`, `tests/` and `kernel/` still point at `docs/development/issues/<file>.md` files that now live in
   `archived/`. Fix them, and add a check that every such pointer resolves (a new check.sh gate changes the gate count in CLAUDE.md).
3. `sweep.sh`'s `run_gate` writes a fixed `/tmp/sweep-gate.log` (and check's copy): two trees sweeping at once collide. Use a
   per-tree `$SWEEP_LOGS` path.
4. `blk-write-smoke` and `ext2-smoke` are honest now (1.57.9) but are not sweep rows.
5. `console-line-smoke` run standalone after a flag build prints "could not build the agnsh image" and hides the real cause (the
   flagged kernel is refused); say so instead of `>/dev/null`.
6. The parallel sweep copies `build/rootfs/verify-*.png` back into every worker's log folder.
7. A fresh tree with no staged `build/rootfs` fails the shutdown row in both sweep modes; stage it when absent.
8. `fg-smoke` is ~830 s and bounds the parallel sweep's wall-clock (~22 min); split its default and recovery halves into two rows.
9. The parallel sweep's `exclusive` group (tsc, kvm-net-boot run alone after the parallel phase, +114 s) is on by default;
   `SWEEP_EXCLUSIVE=0` pools them. Decide whether to keep it.

## Resolution (1.57.10, 2026-09-26)

Prior art followed: kselftest (per-test results and timeouts), pytest-xdist `loadgroup` + pytest-rerunfailures (retry only unknown
failures), Bazel `flaky` / tags, GNU make `-O`, Linux `scripts/documentation-file-ref-check` (the pointer gate).

What it broke: nothing; the plain image is byte-identical (comment-only kernel edits). Left: `docs/doc-health.md` is excluded from gate
36 until its five old pointers are rewritten; the recovery shell's `run` costs ~21 s of kernel time per command (why the fg recovery
rows are the sweep's longest); 6 smokes still write fixed `/tmp` build logs; `/tmp` is a shared per-user tmpfs, and cyrius's
`/tmp/cyrius-<pid>` build dirs are never cleaned — a full `/tmp` broke every cyrius build on the box once during 1.57.10.
