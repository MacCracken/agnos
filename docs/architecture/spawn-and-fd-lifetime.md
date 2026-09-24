# Spawn arms, child fd tables and pipe-buffer lifetime — invariants

> **Last Updated**: 2026-09-24 (1.57.6 — first written for the spawn repairs)
>
> Code: the per-process arms in [`kernel/core/proc.cyr`](../../kernel/core/proc.cyr) (`proc_redir_*`,
> `proc_endow_*`, `spawn_arms_*`, the reset in `proc_alloc_slot`) · `spawn_path_sys`, `spawn_fd_shape`, `spawn_shape_or_teardown`,
> `exec_redirect_apply/_restore`, `chan_place_into_child`, the `#3` / `#37` / `#43` / `#62` / `#97` arms in
> [`kernel/core/syscall.cyr`](../../kernel/core/syscall.cyr) · `pipe_buf_referenced` / `pipe_buf_put`,
> `vfs_fd_inherit`, `proc_destroy_fd_table`, `vfs_close_inner` in [`kernel/core/vfs.cyr`](../../kernel/core/vfs.cyr)
> · the loader's codes and NUL-separated argv in [`kernel/core/elf.cyr`](../../kernel/core/elf.cyr) · the dead-`old`
> CR3 hand-back in `do_context_switch`, [`kernel/core/sched.cyr`](../../kernel/core/sched.cyr).
> Ring-3 contract: rows 3/37/43/62/97/99 and §4.8 of [`../development/agnos-userland-abi.md`](../development/agnos-userland-abi.md).
> Gates: [`scripts/smoke/spawn-smoke.sh`](../../scripts/smoke/spawn-smoke.sh) (kernel block + `tests/spawn` as
> `/bin/agnsh` at `-smp 1` and `-smp 4`), [`scripts/smoke/exec-redirect-smoke.sh`](../../scripts/smoke/exec-redirect-smoke.sh).
> Origin: daimon's three 2026-09-23 filings (child inherits every fd / spawn arms leak; args cannot contain
> spaces; every failure is -1).

## Invariant 1 — a spawn arm belongs to the process that armed it

An *arm* is state a process sets up in one syscall for a child it creates in a later one: the
`exec_redirect`#62 redirect set (≤ 4 pairs) and the `chan_op`#97 `CH_ENDOW` endowment (endpoint, the fd it
will land on, the PTY flag, the channel epoch at arm time). Arm and spawn are **two syscalls issued from
preemptible IF=1 ring-3 code**, so anything keyed by CPU is shared with whatever else runs on that CPU in
between — through 1.57.5 both arms were per-CPU, and another process's spawn on the same CPU (an agnsh
`&` job, a compositor client) consumed them: its child got the redirected stdout, or was born owning an
endpoint nobody endowed it with. That happened on SUCCESS paths, so no amount of "clear on failure" fixed it.

Rules since 1.57.6:
- Storage is indexed by the **arming pid**; only that process's syscalls, its own spawn's
  `chan_place_into_child`, and `proc_alloc_slot` (slot recycle) ever write a pid's cells — no lock.
- **Every `spawn_path`#43 and `execwait`#37 return clears the caller's whole arm state**, success or
  refusal (#43 has one exit for exactly this reason). `spawn`#3 consumes / clears the endowment only.
- `proc_alloc_slot` resets a recycled slot's arms — **except the caller's own slot**. Before the proc-table
  bootstrap the boot context is pid 0 and the first user process it creates is also handed slot 0; resetting
  there wiped the creator's endowment one line before placement. The bootstrap resets all 16 instead.
- Placement re-checks that the spawner **still owns** the endpoint and that `chan_epoch` is unchanged, so a
  closed-and-re-minted endpoint can never follow the arm into the child. `CH_CLOSE` of the armed endpoint
  disarms; `CH_ENDOW(-1)` and `#62 REDIR_CLEAR` disarm explicitly.
- A redirect whose src is the fd the endowment was placed on is skipped (the endowment wins); `REDIR_ADD`
  and the `CH_ENDOW` fd picker keep the two apart in either arm order.

## Invariant 2 — a child's fd table is a COPY, and a copy is dropped raw

`vfs_fd_inherit` gives every child a byte copy of its creator's table (`fork`#96 too). `SPAWN_F_CLEANFD`
then keeps only 0/1/2, the redirect srcs and the placed endowment. The scrub is `ktag_clear` of the child's
slot, **never `vfs_close`**: a close runs side effects on the SHARED object — `tcp_close` of the parent's
connection for a `VFS_SOCK`, a flush + pool release of the parent's `VFS_SEC_WFILE` — and the child never
owned those. The same holds for every slot a redirect overwrites.

`vfs_fd_inherit` first **destroys** any private table an orphan zombie left in the slot (the orphan is
dead and nobody will reap it, so nothing else ever would), then clears the child's base **before** its
kmalloc, so a failure falls back to the global table (which `chan_place_into_child` and `spawn_fd_shape`
detect and refuse), never to a dead stranger's table. A CLEANFD child that cannot get a private table is torn
down unrun (`-SPAWN_E_NOMEM`, `spawn_shape_or_teardown`); a legacy one runs unredirected, as before.

## Invariant 3 — a pipe buffer lives until the LAST reference anywhere

A pipe's 4 KB buffer is freed when no fd slot in **any** table — the global `vfs_table`, every
`proc_fd_base` table (dead-but-unreaped ones included), or a `#37` redirect backup — still names it. It is
decided by a scan (`pipe_buf_referenced`), not a counter, because references are copied at inherit, at every
redirect apply and by fork, and a counter needs every copy site to remember.

Through 1.57.5 the buffer was freed on its **creator's** second close, justified by "children always finish
and are reaped before the creator closes". That is false for every `#43` child: a child still holding an
inherited or redirected end then wrote into a freed slab block, and the next `kmalloc(4096)` — the parent's
next pipe — was the same memory: cross-process data in the wrong pipe, and the heap's free-list word written
through (`tests/spawn`'s `SPAWNX-PIPE-NO-CROSSTALK` reproduces it on 1.57.5). `proc_reap_child` also skipped
pipes entirely, so a reaped child's references were simply dropped.

Rules:
- A path that can drop a **possibly-sole** reference clears the slot **and** scans in **one**
  `fs_spin_lock` hold, bracketed by `preempt_disable` (proc 0 is preemptible and the lock neither disables
  preemption nor nests): `vfs_close_inner`, `proc_destroy_fd_table` (for **both** `do_flush` values) and
  `exec_redirect_restore`. The slot is cleared **before** the scan, or the scan counts the reference being
  dropped.
- "Clear it lock-free, then lock and re-check" is **not** equivalent. The first 1.57.6 build did that in
  `exec_redirect_restore`: a `#37` child that handed a pipe to a still-running `#43` grandchild had its slot
  overwritten while the lock was free, the grandchild's last close on another CPU then scanned, found nothing
  and freed, and the restore's late `pipe_buf_put` found nothing too and freed **again** — a double push on the
  4096 slab free list, so two later `kmalloc(4096)`s alias. One hold makes the two droppers serialize so that
  exactly one sees "no other reference".
- A path may drop a reference **without** the lock only if it drops a duplicate of an entry its creator
  still holds and cannot close meanwhile: the CLEANFD scrub and the `#43`/`#37` redirect **apply** (the creator
  is the caller, inside that spawn). A kernel creator on the shared global table is the one soft spot — a
  kthread closing the same global fd at that instant can turn the raw drop into a leak, never a free.
- `pipe_writers_open` (EOF) still skips dead tables — that rule is for EOF, the opposite of this one.
- An orphan zombie's slot (its parent died unreaping) is handed out again by `proc_alloc_slot` with its fd
  table still attached; `vfs_fd_inherit` destroys that table (sweeping its pipe references) before the new
  child gets its own, so the orphan's pipe buffers are released rather than leaked.

## Invariant 4 — a CPU must leave a dead process's CR3 before the reap fence opens

`proc_reap_child` detaches the dead proc's table CR3 (`-> 0x1000`), spins in `proc_reap_off_cpu_fence`
until `on_cpu == -1`, and then frees the PML4/PDPT/PD. `do_context_switch` sets `on_cpu(old) = -1` under
the scheduler lock and loaded the next proc's CR3 only in the lock-free tail — and compared the new CR3
against `proc_get_cr3(old)`, a table cell the reaper had already rewritten to `0x1000`. Switching from a dead
proc to an idle kthread (also `0x1000`) therefore skipped the load, and the AP idled on freed page tables
until a TLB miss fetched kernel code through them: `#PF e=0x10` at a kernel RIP, then the fault path's
framebuffer paint faulting recursively → `#DF` → triple fault (QEMU `-smp 4`, `-d int`; the pre-1.57.6
kernel does it too). Since 1.57.6 a dead `old` hands the CPU back to the boot CR3 **before** `on_cpu` is
cleared, and the tail compares against the CR3 actually loaded (`dm_read_cr3`). Any new path that lets a
dying process's CPU go idle must keep the same order.

## Invariant 5 — refuse, never drop, and say why

- More than 16 argv tokens (line form) or entries (`SPAWN_F_ARGV`) is **refused** by `#43` (−6) and `#37`
  (−1) before anything is loaded; the loader's own cap stays only as a backstop and must equal
  `SPAWN_ARGC_MAX` (`check-initstack.sh`).
- `#43` returns distinct codes (§4.8); `#37` folds them to −1 because its success value is the child's
  exit code; `#3` is unchanged. An exited, unreaped child holds a slot but is not listed by `#99`, so
  `-SPAWN_E_NOPROC` is the authoritative "table full".
- Every refusal happens **before** the per-CPU loader cells (`exec_env_src/_len`, `exec_argv_nul`) are set —
  they are consumed only at `elf_load_from_file` entry, and a stale one would reach the next `#37`/init load.
