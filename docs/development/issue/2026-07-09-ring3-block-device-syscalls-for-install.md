# 2026-07-09 — Ring-3 raw block-device syscalls (native-install primitive)

**Status:** ✅ Phases 1-2 DONE — **cut 1.53.10** (2026-07-09). Read-path + gated write-path
both QEMU-proven from ring 3 (`blk-ring3-smoke` exit 95 · `blk-write-smoke` exit 96,
unarmed writes rejected). Remaining arc: cyrius `sys_blk_*` wrappers (ph.3), userland
GPT-writer + `mkfs` (ph.4), agnova executor port (ph.5), end-to-end install proof (ph.6).
**Driver:** agnova (native OS installer) cannot run on agnos today — it shells out to
Linux `parted`/`mkfs.*`/`cryptsetup` and needs raw disk access agnos doesn't expose.
See the agnova full-install readiness survey (2026-07-09).

## Problem

A native (on-agnos) install must **write a fresh GPT partition table** and **format
filesystems** (`mkfs` ext4 + FAT) on a blank target disk. Today:

- **Block WRITE exists but is kernel-internal** — `blk_write`/`blk_read`
  (`kernel/core/block.cyr`) route NVMe/AHCI/virtio under boot-CR3 for the FS layer.
  **No ring-3 syscall.**
- **GPT is READ-only** — `gpt.cyr` parses/validates the header + entry array; there is
  no partition-table *writer*.
- **The Sys enum tops at #74** (`SYS_SHM_FREE`, 1.53.9). No `SYS_BLK_*`.

So agnova's Phase 1 (partition) and Phase 3 (format) have nowhere to land natively.

## Decision: expose raw block I/O, NOT `mkfs`-in-kernel

`mkfs` is a **userland** concern on every OS (Linux `mkfs.ext4` is a userland tool that
writes sectors through the block device). The kernel's job is to hand a privileged
process **raw sector read/write on a whole disk**; userland (agnova, or sovereign
`partition`/`mkfs` tools) computes the GPT/ext4/FAT structures and writes them.

Rationale: keeps the kernel small; the format logic (superblocks, inode tables, FAT,
CRC32s) lives where it's easy to test/iterate; matches the universal OS split.

## Syscall surface (proposed, #75–80)

| # | Name | Signature → ret | Notes |
|---|------|-----------------|-------|
| 75 | `SYS_BLK_ENUM`  | `blk_enum(buf, cap) → count/-1` | list block devices (name, size, sector-size) |
| 76 | `SYS_BLK_OPEN`  | `blk_open(name, mode) → handle/-1` | mode: 0=RO, 1=RW. **RW is capability-gated** |
| 77 | `SYS_BLK_READ`  | `blk_read(h, lba, buf, nsec) → nsec/-1` | raw sector read |
| 78 | `SYS_BLK_WRITE` | `blk_write(h, lba, buf, nsec) → nsec/-1` | raw sector write — the dangerous one |
| 79 | `SYS_BLK_INFO`  | `blk_info(h, out) → 0/-1` | sectors, sector-size, model, removable |
| 80 | `SYS_BLK_CLOSE` | `blk_close(h) → 0/-1` | flush + release (write-path implies a barrier) |

(Numbers indicative; assign at implementation. A `SYS_BLK_FLUSH` may split out of CLOSE.)

## Security posture (load-bearing — do NOT collapse)

Raw block-write can destroy **any** disk. Per the AGNOS hardened/capability posture
([[project_agnos_auth_posture]], [[project_agnos_empire_defense_layers]]):

- `SYS_BLK_OPEN` in **RW mode requires an explicit capability** (installer-only),
  granted via aegis/shakti — not available to an arbitrary ring-3 process.
- RO enum/open/read may be broadly available (disk detection is not destructive), but
  RW-open + `SYS_BLK_WRITE` are gated.
- The gate is the boundary; never make RW-open ambient.

## Phasing

1. **Read-path (safe)** — `BLK_ENUM` / `BLK_OPEN(RO)` / `BLK_READ` / `BLK_INFO` / `BLK_CLOSE`.
   Unlocks disk detection + GPT *reading* from ring 3. Low risk.
2. **Write-path (gated)** — `BLK_OPEN(RW)` + `BLK_WRITE` behind the capability gate.
3. **Userland GPT writer + `mkfs`** — sovereign Cyrius: build a GPT table (protective
   MBR + primary/backup header + entry array + CRC32) and ext4/FAT metadata; write via
   `BLK_WRITE`. (Lives in agnova, or a shared `mkfs`/`partition` tool.)
4. **agnova port** — replace the `parted`/`mkfs.*` shell-outs (executor.cyr) with the
   above. Separate track; see the agnova port issue.
5. **End-to-end proof** — QEMU: blank disk → partition → mkfs → install base + gnoboot +
   kernel → boot to agnoshi. The v1.0 install criterion.

## Dependencies

- **cyrius** — userland wrappers for #75–80 in `syscalls_x86_64_agnos.cyr`
  (`#ifdef CYRIUS_TARGET_AGNOS`). Filed separately: `2026-07-09-cyrius-block-device-wrappers.md`.
- **agnova** — executor rewrite (Linux-tool shell-outs → native block syscalls + userland mkfs).

## Non-goals (this arc)

- In-kernel filesystem *creation* (stays userland).
- LUKS/encryption path (agnova's `cryptsetup` shell-out; sovereign later).
- Linux `ioctl` porting (agnos has no ioctl framework; these are purpose-built syscalls).
