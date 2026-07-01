# agnos — pipe buffer leaked on close (`vfs_close` has no `VFS_PIPE` arm)

**Status**: ✅ **RESOLVED at 1.47.0 (bite 2c) — closed 2026-06-30, archived.** `vfs_close` gained the `VFS_PIPE` arm with an **owner-keyed refcount (`pipe_rc_*`)**: each pipe buffer is owned by its creator, only the owner's two closes decrement, freed at 0 — killing the prior 4 KB-per-pipeline leak (a child closing an inherited copy is a no-op; the owner's reap also frees). Proven by the new `PIPE_RC_SELFTEST` (buffer frees on the owner's LAST close, heap-frees witness; double-close-safe) + `pipe-smoke` PASS. (Original status: *Filed (follow-on to the 1.46.x two-stage shell-pipe feature); a per-pipeline 4096-byte heap leak.*)

## Symptom
`vfs_create_pipe` (`kernel/core/vfs.cyr:824`) `kmalloc(4096)`s **one** shared buffer for the pipe's read-end + write-end fds. `vfs_close_inner` (`vfs.cyr:942`) has arms for `VFS_EXT2_FILE` (flock release) and `VFS_SEC_WFILE` (flush), then `ktag_clear` — but **no `VFS_PIPE` arm**. So closing the rfd and wfd zeroes the two 32-byte fd-table slots and **never `kfree`s the 4096-byte pipe buffer**. Each `cmd1 | cmd2` pipeline leaks 4096 bytes.

Verified: there is **no double-free** (the failure mode is a leak, not corruption) — the original concern was over-stated; the buffer is simply never freed.

## Why not just free-on-first-close
The rfd and wfd **share one buffer**. A naive `kfree` on the first close dangles the other end. Correct fix = a small **refcount** (2 at create, −1 per close, `kfree` on the last close) stored in the buffer header or a side table keyed by the buffer address. This is the **same machinery streaming pipes need** — an open-write-end count is also how a streaming reader would distinguish "empty, writer still open" from genuine EOF (see the SMP/streaming follow-on issue).

## Impact
- MVP `iam | anuenue`: harmless (one pipeline; the shell + procs are short-lived). 
- PMM is 128 MB, so thousands of pipelines would eventually matter.

## Fix sketch
Add a `VFS_PIPE` arm to `vfs_close_inner`: decrement a refcount carried in the pipe-buffer header (the first 8 bytes already hold the write head — reserve a slot, or use a side table), `kfree(pipe_buf)` at 0. Fold in with the streaming write-end refcount so both land together.
