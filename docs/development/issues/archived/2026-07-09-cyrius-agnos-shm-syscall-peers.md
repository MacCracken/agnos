# cyrius stdlib — add the AGNOS `sys_shm_*` peers for kernel shm `#71-74`

**Status**: ✅ **RESOLVED end-to-end (2026-07-09).** cyrius **v6.4.34** added
`SYS_SHM_CREATE/WRITE/READ/FREE` (71-74) + `sys_shm_create`/`_write`/`_read`/`_free` to
`lib/syscalls_x86_64_agnos.cyr`. Downstream flip DONE: setu `buf.cyr`'s agnos branch now calls
the **native `sys_shm_*` wrappers** (0 raw `syscall(71..74)` literals left); setu + aethersafha
pins bumped 6.4.25→**6.4.34** (aethersafha needed a **`cyrius lib sync --full`** — `cyrius deps`
alone left the materialized stdlib stale, the [[reference_stale_vendored_lib_masks_stdlib_fix]]
pattern). Re-proven on BOTH targets: `aethersafha-setu-smoke.sh` gate 4 GREEN with fresh
native-wrapper binaries, and the Linux `setu_serve_probe`+`present_probe` PPM (file backend,
unchanged) still 2032 green px. Nothing left but the git (setu cut). Historical detail below.

> ⛔ **RETRACTED 2026-08-03 — the agnos-side CITED EVIDENCE above is invalid.** The
> `aethersafha-setu-smoke.sh` "gate 4 green" was a **FALSE GREEN**: that gate passed only because
> the `AETHERSAFHA_SETU_SELFTEST` kernel hook assigned `net_ip = 0x7F000001`, making src == dst
> == `127.0.0.1` so `tcp_find_conn` matched. **Before `net_src_for` (agnos 1.56.34)** the
> compositor↔client handshake could not complete on an ordinary boot. That script has been deleted
> and the selftest hook removed. **This retraction is about the PROOF, not the FIX** — the
> `sys_shm_*` wrappers (71-74) themselves are unaffected and are independently exercised by the
> honest `aethersafha-smoke.sh` render proof; only the claim "re-proven on agnos via gate 4" must
> not be cited. See agnos `docs/development/planning/ipc.md` §9-§10.
>
> ⚠ **SCOPE CORRECTION (2026-08-03, same day).** An earlier form of this retraction said the
> transport "never worked on agnos" / "TCP was never the desktop transport". **That is FALSE and is
> withdrawn.** *After* `net_src_for`, the un-rigged
> `scripts/harness/aethersafha-clients-test.py` reached **"connected: 2, presented: 2"** on 1.56.34+
> (2026-08-02) — that harness byte-scans `build/agnos` and hard-exits if the kernel carries any
> selftest hook, and it is what caught the rigging. ⚠ QEMU at `-smp 1` only; never shown on iron,
> `-smp 4` fault-kills. TCP-on-loopback is retired because it is the **wrong primitive** for local
> display IPC (operator ruling), **not** because it was broken. The gate-4 citation above stays
> retracted regardless — it was rigged.

The agnos kernel shm half (`shm_create`#71 / `shm_write`#72 / `shm_read`#73 / `shm_free`#74)
shipped + QEMU-proven (agnos 1.53.9). The cyrius ring-3 wrapper was the ABI-completeness half —
now landed in 6.4.34. Originally the first consumer (setu `buf.cyr`) called #71-74 via **raw
`syscall(71..74)` literals** inside its `#ifdef CYRIUS_TARGET_AGNOS` branch — worked, but the
numbers were invisible to other programs. The peer makes
the call native (`sys_shm_create(...)` etc.) and, crucially, **canonical**: today every
consumer that wants a shared buffer must hardcode the raw numbers `71..74`, so the primitive
does NOT trickle out to programs the way a named wrapper does. The peer is where the numbers
get documented + reused. **The canonical cyrius-side request belongs IN the cyrius repo** at
`docs/development/issues/2026-07-09-agnos-sys-shm-peers.md` (cyrius house format) — the cyrius
language agent picks it up there; this agnos-side copy is the mirror (mirrors the
`sys_readlink`#70 precedent, `2026-07-08-cyrius-agnos-sys-readlink-peer.md`).
**Date**: 2026-07-09
**Priority**: **Low — ABI-completeness.** The kernel + the sole consumer are done and proven;
only the canonical cyrius wrappers are missing. No consumer is blocked (the raw-number path is
proven), unlike the `sys_symlink`#63 peer which *gated* ark M3.
**From**: agnos shm `#71-74` (kernel) vs cyrius `lib/syscalls_x86_64_agnos.cyr` (the file-op /
socket peer bands end at `SYS_READLINK`#70; there is **no `sys_shm_*`** band).
**Related**: agnos `kernel/core/syscall.cyr` (the `shm_create`/`shm_write`/`shm_read`/`shm_free`
helpers + the `#71-74` dispatch), setu `src/buf.cyr` (the consumer — its agnos branch calls the
raw numbers), agnosticos `docs/development/planning/shared-buffer-present.md` (the design + why
COPY-based), `docs/development/agnos-userland-abi.md` (the ABI table — add rows 71-74).

## The gap

The sovereign **shared-buffer present** (the desktop client→compositor pixel path that
sidesteps the single-CPU two-proc TCP flow-control deadlock) needs a way for two ring-3 procs
to hand a pixel buffer across without streaming it over the socket or mapping a shared page
(a mapped-into-the-arena page hits a proc-exit free hazard). The agnos kernel closed that with
COPY-based **kernel-owned** shm buffers `#71-74`; this peer is the ring-3 wrapper band for them.
Right now setu `buf.cyr` calls `syscall(71, size)` / `syscall(72, id, src, size)` / … with bare
literals — it works, but the numbers are invisible to every other program and to the ABI doc.

## The kernel ABI to wire against (verified from `kernel/core/syscall.cyr`, QEMU-proven, 1.53.9)

COPY-based, kernel-owned. A 16-slot table over single 2 MB pmm pages; **ids are 1-based** (0 is
the setu "inline pixels" sentinel, so a real buffer is never 0). The page's `pmm_kva_for_access`
KVA is in the kernel mirror, so `shm_write` (client CR3) and `shm_read` (compositor CR3) both
reach it from their own syscall context with a plain copy — no cross-proc page mapping.

### `shm_create` — syscall **#71**
```
shm_create(size = arg1) -> id (>= 1) / -1
```
- `arg1` = byte size (`> 0`, `<= 2 MB` = one pmm page — the bite-2 cap; multi-page is a follow-up).
- Returns a **1-based** buffer id (`1..16`), or `-1` (bad size / pmm OOM / 16-slot table full).

### `shm_write` — syscall **#72**
```
shm_write(id = arg1, user_src = arg2, size = arg3) -> 0 / -1
```
- Copies `size` bytes from the caller's `src` (validated `is_user_range`) INTO buffer `id`.
  `-1` on bad id / `size <= 0` / `size > the buffer's size` / bad user range.

### `shm_read` — syscall **#73**
```
shm_read(id = arg1, user_dst = arg2, size = arg3) -> 0 / -1
```
- Copies `size` bytes OUT of buffer `id` into the caller's `dst` (validated `is_user_range`). Same `-1`s.

### `shm_free` — syscall **#74**
```
shm_free(id = arg1) -> 0 / -1
```
- Releases the 2 MB page + the slot. `-1` on bad id.
- Numbers **#71-74** = the next free agnos band after `readlink`#70.

### The cyrius peers to add (mirror the `sys_readlink` shape)
```cyrius
# in the agnos Sys enum, after SYS_READLINK = 70:
    SYS_SHM_CREATE = 71;   # shm_create(size) → id (>=1) / -1  — kernel-owned shared buffer
    SYS_SHM_WRITE  = 72;   # shm_write(id, user_src, size) → 0 / -1
    SYS_SHM_READ   = 73;   # shm_read(id, user_dst, size)  → 0 / -1
    SYS_SHM_FREE   = 74;   # shm_free(id) → 0 / -1

# The COPY-based shared-buffer band (agnos shm #71-74). A client shm_write#72s a buffer, hands the
# id over its own IPC, the reader shm_read#73s it — no page mapping, no socket streaming. Backs the
# setu shared-buffer present (buf.cyr). ids are 1-based (0 = the setu "inline" sentinel).
fn sys_shm_create(size): i64        { return syscall(SYS_SHM_CREATE, size); }
fn sys_shm_write(id, src, size): i64 { return syscall(SYS_SHM_WRITE, id, src, size); }
fn sys_shm_read(id, dst, size): i64  { return syscall(SYS_SHM_READ, id, dst, size); }
fn sys_shm_free(id): i64            { return syscall(SYS_SHM_FREE, id); }
```

## Status of the other halves (all done — this is the only open piece)

- **Kernel (agnos)** — `shm_create`/`shm_write`/`shm_read`/`shm_free` `#71-74` + the 16-slot pmm-page
  table (`kernel/core/syscall.cyr`). ~~**QEMU-proven**: `aethersafha-setu-smoke.sh` gate 4 green — a
  setu client `shm_write`s a 320×192 frame, the compositor `shm_read`s + composites it on agnos
  (`setu client CONNECTED + PRESENTED + composited on agnos`).~~ agnos 1.53.9.
  ⛔ **RETRACTED 2026-08-03 — invalid proof, not an invalid fix.** The gate-4 "green" was a FALSE
  GREEN: it passed only because the `AETHERSAFHA_SETU_SELFTEST` kernel hook assigned
  `net_ip = 0x7F000001`. The connection the gate depended on could not complete on an ordinary boot
  **before `net_src_for` (agnos 1.56.34)**, so this line proves nothing about the shm band. The
  kernel shm `#71-74` implementation is not in question — it just needs a different citation.
  ⚠ **Scope, so this is not read as more than it is**: after `net_src_for` an un-rigged client↔
  compositor connect + present *did* land (`aethersafha-clients-test.py`, "connected: 2,
  presented: 2", 2026-08-02, QEMU `-smp 1`, never on iron). TCP-on-loopback is retired as the
  **wrong primitive**, not as a thing that never worked. See
  `docs/development/planning/ipc.md` §9-§10.
- **Consumer (setu `buf.cyr`)** — copy-based backend `setu_buf_create`/`_write`/`_read`/`_close`;
  the agnos branch calls the raw numbers `syscall(71..74)` (setu already links `syscalls`);
  Linux branch = `/dev/shm/setu-buf-<id>` write()/read(). Builds `--agnos` + Linux; the full present
  is proven on both.

## Done-criteria

The peer is done when `sys_shm_create`/`_write`/`_read`/`_free` are in
`lib/syscalls_x86_64_agnos.cyr` and setu `buf.cyr`'s agnos branch calls the **native** wrappers
(not the raw literals) after its next `lib/` re-sync. On landing, flip `buf.cyr`'s four
`syscall(71..74)` sites to `sys_shm_*(...)` and archive this issue. (No mirshi peer is needed
unless a shared-buffer consumer is run under mirshi — the shm band is agnos-kernel-only, no host
equivalent; a mirshi consumer would use the Linux `/dev/shm` file backend instead.)
