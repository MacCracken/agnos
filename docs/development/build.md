# Building AGNOS

> **TL;DR**: `./scripts/build.sh` produces `build/agnos` (x86_64 ELF64 multiboot2 kernel for the gnoboot Path-C handoff). Optional gates `KTEST=1` and `XHCI_VERBOSE=1` opt into developmental output that's off by default in production.
>
> Toolchain pin: see `cyrius.cyml` (`cyrius = "..."`) for the current version. The build script invokes `~/.cyrius/bin/cyrius` (the wrapper, not `cycc` directly). Wrapper auto-resolves the pin.

---

## Quick start

```sh
# Default x86_64 production build
./scripts/build.sh

# Output: build/agnos (multiboot2 ELF64, entry = 0x1000A8)
# Boot via gnoboot + OVMF (QEMU) or install-usb.sh (iron) — Path C handoff.
```

```sh
# Aarch64 cross-build (Linux-protocol kernel, no multiboot)
./scripts/build.sh --aarch64

# Output: build/agnos-aarch64
# Boot: qemu-system-aarch64 -M virt -cpu cortex-a57 -kernel build/agnos-aarch64 ...
```

The script:

1. Resolves the cyrius toolchain (`$CYRIUS_HOME/bin/cyrius`, defaulting to `~/.cyrius/bin/cyrius`).
2. Prepends source-side defines (`ARCH_X86_64`, `ELF64_KERNEL`, plus any opt-in flags below) to a temporary copy of `kernel/agnos.cyr`.
3. Sets the cyrius-backend env (`CYRIUS_ELF64_KERNEL=1` for x86_64) so the compiler selects the right emit path.
4. Runs `cyrius build --no-deps`, producing the kernel binary in `build/`.
5. Validates the ELF + multiboot header (Python sanity check on EI_CLASS, multiboot magic, entry point).

Both source-side defines and backend env vars must be in lockstep — they gate different layers (source-level `#ifdef` vs cyrius-backend emit mode).

---

## Build flags

The architecture + ELF64 flags are mandatory and set by the script automatically. The rest are opt-in development gates set via env var (all default-off; production boots stay lean).

| Flag | Defined where | Default | Effect |
|---|---|---|---|
| `ARCH_X86_64` | source-side (prepended) | on (auto, x86_64 build) | Includes the x86_64 platform code path |
| `ARCH_AARCH64` | source-side (prepended) | on (auto, `--aarch64` build) | Includes the aarch64 platform code path |
| `ELF64_KERNEL` | source-side (prepended) | on (auto, x86_64) | Selects the 64-bit entry shim (Path C handoff via gnoboot). Paired with `CYRIUS_ELF64_KERNEL=1` (backend gate) |
| **`KTEST`** | source-side (prepended, env-driven) | **off** | Compiles in the boot-time in-kernel self-tests (Syscall test, Context Switch test, Scheduler test idle loop, VFS/initrd test, Userland Exec test). About 18 lines of test output + several CMOS checkpoints (CP14, CP12-twice, CP14-twice). Off in production so iron boots don't carry test spam |
| **`XHCI_VERBOSE`** | source-side (prepended, env-driven) | **off** | Compiles in xhci developmental debug output: `cmd_submit#` trb-tracking, `evt#` event trace, `drained N events`, `PP=1 asserted bitmap=`, `CRCR.CRR / ERSTSZ / IMAN / ERDP_lo` readback, `enable_slot entry idx=`. High-level confirmation lines (`halted, reset clean`, `dev_notifications enabled`, `controller running, HCH=0, ERDP=`, port-connected, error cases) are unconditional regardless of this flag |
| **`AHCI_RW_DEMO`** | source-side (prepended, env-driven) | **off** | Compiles in the AHCI boot-time sentinel write + read-back round-trip at LBA 5 of the lowest-numbered initialized SATA port. Default-off because LBA 5 on a GPT-formatted disk sits inside the partition-entry array (entries 12-15 at standard `partition_entries_lba=2` layout); writing a sentinel there corrupts the partition-array CRC (recoverable via `sgdisk --load-backup` from the disk's tail backup, but not the right default posture against drives the user cares about). The always-on `ahci_read_demo` (LBA 0 readback, no writes) provides Phase-4-DMA validation on iron without the write hazard. Enable for QEMU smoke (`AHCI_RW_DEMO=1 ./scripts/build.sh`) or known-scratch drives only |
| **`MSC_RW_DEMO`** | source-side (prepended, env-driven) | **off** | Compiles in the USB Mass Storage boot-time sentinel write + read-back round-trip at LBA 100 of `msc_first_slot` (first MSC-BBB device that completes Phase 1-3). Default-off for the same reason as `AHCI_RW_DEMO` — LBA 100 on a typical USB stick may sit inside a filesystem; sentinel writes there are recoverable (8 bytes overwritten) but not the right default posture against drives the user cares about. The always-on `msc_read_demo` (LBA 0 readback, no writes) provides Phase-4-DMA validation on iron without the write hazard. Enable for QEMU smoke (`MSC_RW_DEMO=1 ./scripts/build.sh`) or known-scratch USB devices only |
| **`RAMDISK_ENABLE`** | source-side (prepended, env-driven) | **off** | Compiles in the RAM-disk block backend (`kernel/core/ramdisk.cyr`). At boot, preallocates 64 pages (256 KB) from `pmm_alloc` and registers as the lowest-priority block backend — takes the slot only when no other backend (NVMe / AHCI / USB-MS / VirtIO) holds it. Useful as a development substrate for filesystem work without iron and as a regression target for the block-dispatch policy. Default-off because the 256 KB allocation eats ~18% of archaemenid's post-boot pmm budget (~354 free pages); production boots stay lean. To resize, edit `RAMDISK_NPAGES_DEFAULT` in `ramdisk.cyr` (capped at 128 = 512 KB by `RAMDISK_NPAGES_MAX` until the pmm budget audit reports >1024 free pages post-boot). Multi-source convergent design (OpenBSD `rd.c` MINIROOTSIZE pattern + NetBSD `md.c` MD_KMEM_ALLOCATED preallocation) — see `agnosticos/docs/development/prior-art/ramdisk-virtio-modern-prior-art.md` § 3 |
| **`NET_VERBOSE`** | source-side (prepended, env-driven) | **off** | Compiles in boot net diagnostics: the 1.1.1.1:80 outbound-TCP smoke + the r8169 silicon tally readback. Gated out of production at 1.32.8 once the r8169 unicast-RX arc reached CONNECTED — the per-burn diagnostics it accreted are developmental noise, not validation signal |
| **`EXT2_WRITE_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time ext2/ext4 **write** self-test (1.33.x WRITE arc): create / write / truncate / unlink against the mounted ext2/4 FS, with `e2fsck -fn` as the host-side oracle on the resulting image |
| **`EXT2_EXTENT_WRITE_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time ext4 **extent-tree** write self-test (1.37.x): depth-2 extent-tree growth + append + cross-boot skip-if-present, `e2fsck -fn` clean. Gated by `scripts/ext-extent-smoke.sh` |
| **`EXEC_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time **exec-from-disk** self-test (1.40.x exec arc, `core/main.cyr`): the kernel hand-builds a minimal static ELF64 (`write(1,"EXEC-DISK-OK\n",13)` then `exit(42)`), writes it to ext2 (`/prog`, plus `/bin/prog2` + `/bin/argv` at 1.40.x close), then `run`s it through `elf_load_from_file` → `exec_and_wait` (RING 3, SYSCALL/SYSRET/iretq). Also exercises `proc_reap` (the `reap: slot reclaim OK (pc stable)` + `reap: 6x AS+page cycle, free stable OK` no-leak assertions). Gated by `scripts/exec-smoke.sh` / `scripts/sweep.sh` on `EXEC-DISK-OK` + `run: exit 42` + `e2fsck -fn` clean |
| **`FS_SYSCALL_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time **FS-syscall** self-test (1.41.3, `core/main.cyr`): drives all nine 1.41.3 FS syscalls (`getdents`/`unlink`/`rename`/`link`/`stat` + the real `mkdir`/`rmdir`/`sync` + mount-routed `open`) through `ksyscall` with a `pmm_alloc_2mb` user-range scratch and verifies the side effects on disk. Emits `fssys: ALL PASS`; gated by `scripts/sweep.sh` |
| **`SYSCALL_HARDEN_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time **syscall-ingress hardening** self-test (1.41.6, `core/main.cyr`): regression-locks the 1.41.5 security fixes by driving the rejection paths through `ksyscall` — the `is_user_range`/`is_user_ptr` 1 GB user-VA ceiling, epoll_ctl/epoll_wait/timerfd_settime fd type-confusion rejection (+ the watched-fd out-of-range bound), signalfd, and the ext2 256-byte basename rejection. First regression coverage for the epoll/timerfd/signalfd syscalls. Emits `shsys: ALL PASS`; gated by `scripts/sweep.sh` |
| **`FATFS_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time FAT **read** self-test (1.34.x): mount the FAT12/16/32 volume + cluster-chain read + directory listing |
| **`FATFS_WRITE_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time FAT **write** self-test (1.34.x): create / multi-cluster write / overwrite / truncate / delete / LFN; `fsck.fat -n` + `mtools` as the host-side oracle |
| **`EXFAT_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time exFAT **read** self-test (1.34.1): mount + typed dir-set read + multi-cluster chain read |
| **`EXFAT_WRITE_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time exFAT **write** self-test (1.34.1+): dir-set create (SetChecksum + NameHash) / bitmap-allocator content write / overwrite / truncate / delete / root extension / Unicode names; `fsck.exfat -n` as the host-side oracle |
| **`FAT_ALLOW_ESP_WRITE`** | source-side (prepended, env-driven) | **off** | Overrides the ESP-write safety guard (1.34.6). By default FAT/exFAT refuse writes to a partition whose GPT type-GUID is the EFI System Partition, so the boot ESP can't be clobbered. This flag lifts that refusal for QEMU FAT/exFAT **test images** whose backing partition happens to carry an ESP-type GUID. **Never** set this on real boot media |
| **`DNS_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time DNS stub self-test (1.35.x): prints the DHCP-captured resolver (option 6), runs a hermetic RFC 1035 compression-pointer parse (`dns: parse PASS`), and attempts a live SLIRP lookup. Gated by `scripts/dns-smoke.sh` |
| **`ICMP_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time ICMP echo self-test (1.35.x): hermetic checksum self-verify (`icmp: build PASS`) + a best-effort gateway ping. Gated by `scripts/icmp-smoke.sh` |
| **`TCP_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time TCP receive-ring self-test (1.35.1): hermetic FIFO-order + buffer-wrap reassembly check (`tcp: ring PASS`). Gated by `scripts/tcp-smoke.sh` |
| **`TCP_LISTEN_SMOKE`** | source-side (prepended, env-driven) | **off** | Boot-time TCP passive-open / accept round-trip smoke (handshake → accept → send → receive). Gated by `scripts/tcp-listen-smoke.sh` |
| **`NTP_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time SNTP parse self-test (1.35.x): hermetic transmit-timestamp → Unix-epoch + UTC breakdown (`ntp: parse PASS`). Gated by `scripts/ntp-smoke.sh` |
| **`MMAP_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time anonymous-mmap allocator self-test (1.35.3): hermetic 2 MB-contiguous `pmm_alloc_2mb`/`pmm_free_2mb` alloc/free/count + mmap length-rounding (`mmap: pmm2mb PASS`, `munmap: pmm-reuse PASS`). Gated by `scripts/mmap-smoke.sh` |
| **`RTC_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time RTC boot-clock self-test (1.35.5): hermetic `civil_to_unix` anchors + BCD decode + a live-bounded CMOS read (`rtc: clock PASS`). Gated by `scripts/rtc-smoke.sh` |
| **`HARDENING_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time net-arc-close hardening self-test (1.35.7): hermetic `ip_safe_payload_len` ingress-clamp table (`hardening: ip-clamp PASS`). Gated by `scripts/hardening-smoke.sh` |
| **`JBD2_TX_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time jbd2 transaction self-test (1.38.x journaling arc): the three positive begin/log/commit paths + three negative-path error responses, plus a real commit at 1.38.5+. Gated by `scripts/jbd2-tx-smoke.sh` |
| **`JBD2_WP_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time jbd2 **write-path** self-test (1.38.x): end-to-end read-FS-block → log → commit → `ext2_sync`, leaving the FS byte-identical so the host `e2fsck` sees `VALID_FS`. Gated by `scripts/jbd2-writepath-smoke.sh` |
| **`JBD2_INT_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time jbd2 **integration** self-test (1.38.x): a real `commit_tx` against the mounted journal (CSUM_V2/V3 at 1.38.10+), `COMMITTED seq=N … journal clean`. Gated by `scripts/jbd2-int-smoke.sh` |
| **`JBD2_CRASH_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time jbd2 **crash-recovery** self-test (1.38.x): 100 commits with `rdtsc` busy-waits (~3 s window) for a host-driven mid-cycle SIGKILL, then replay-to-clean on the next boot; progress markers every 25 iterations. Gated by `scripts/jbd2-crash-smoke.sh` |
| **`JBD2_LOGDUMP`** | source-side (prepended, env-driven) | **off** | Diagnostic jbd2 journal log-walk dump (descriptor/commit/revoke trace). Developmental visibility only — not a pass/fail gate |
| **`JBD2_NO_REPLAY`** | source-side (prepended, env-driven) | **off** | Regression-escape gate (added 1.38.x): suppresses journal replay at mount so a smoke can inspect the pre-replay on-disk state. Test-only |
| **`KLUG_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time klug **log-ring** self-test (1.42.x sysinfo/klug group): re-emits the captured boot-log ring between `KLUG-DUMP-BEGIN`/`KLUG-DUMP-END` markers so a smoke can confirm the boot log was unified into the klug ring (backing `klug` syscall #36). Validated inline (no dedicated smoke script). QEMU-validated, iron-pending |
| **`FB_ANSI_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time **ANSI/CSI/SGR parser** self-test (1.43.1): feeds escape sequences through `fb_ansi_feed()` and asserts the resulting colour/cursor state (deterministic, no pixel inspection), emitting one `fb-ansi: PASS/FAIL <case>` line per check to serial. Gated by `scripts/fb-ansi-smoke.sh` |
| **`FB_ANSI_VISUAL`** | source-side (prepended, env-driven) | **off** | Companion to `FB_ANSI_SELFTEST` (1.43.1): paints colour swatches through the real render path then **halts** (does not continue boot) so a QEMU screendump can capture them. Visual diagnostic, not a pass/fail gate; see `scripts/fb-ansi-screendump.sh` |
| **`DOOM_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time **DOOM render smoke** (1.43.x — the first real userland app): runs the seeded `/bin/doom` ELF from the ext2 root in ring 3, rendering to the framebuffer via `fbinfo` #38 / `blit` #39 and pacing via `uptime_ms` #40 / `sleep_ms` #41; the boot intentionally parks here while DOOM renders. Gated by `scripts/doom-smoke.sh` (live-framebuffer screendump). **IRON-COMPLETE** — burn 1439 plays DOOM in-game on real Zen, keyboard-driven (`kbscan` #42) |
| **`THREAD_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time **preemptive kernel-thread** self-test (1.44.0, opening bite of the multi-threading arc): two `kthread_create`'d threads tight-loop bumping their own counters and never yield — if both advance, the timer preempted + round-robined them on the shared kernel AS; then verifies the `preempt_disable()` gate freezes the counters (`thr: preempt OK` / `thr: gate held`). Gated by `scripts/thread-smoke.sh`. QEMU-validated, iron-pending |
| **`RING3_SELFTEST`** | source-side (prepended, env-driven) | **off** | Boot-time **preemptive ring-3** self-test (1.44.4+): spawns two ring-3 procs, each with its OWN per-process CR3 + IF=1, running the same getpid-SYSCALL + counter-increment loop — two advancing counters prove the scheduler round-robins ring-3↔ring-3 across distinct CR3s, per-proc address-space isolation, and a preemptible ring-3 proc can SYSCALL safely (1.44.5 two procs · 1.44.6 syscalls · later bites add concurrent exec + real ELF spawn). Gated by `scripts/ring3-smoke.sh`. QEMU-validated, iron-pending |

### Enabling the gates

```sh
# Run the boot-time kernel self-tests
KTEST=1 ./scripts/build.sh

# Get the xhci developmental trace
XHCI_VERBOSE=1 ./scripts/build.sh

# Compile in the AHCI LBA-5 sentinel write demo (QEMU smoke only — see notes)
AHCI_RW_DEMO=1 ./scripts/build.sh

# Compile in the USB MS LBA-100 sentinel write demo (QEMU smoke or scratch device only)
MSC_RW_DEMO=1 ./scripts/build.sh

# Compile in the RAM-disk block backend (256 KB preallocated at boot)
RAMDISK_ENABLE=1 ./scripts/build.sh

# Boot-time filesystem write self-tests (paired with the QEMU smoke harnesses)
FATFS_WRITE_SELFTEST=1 ./scripts/build.sh        # scripts/fat-write-smoke.sh
EXFAT_WRITE_SELFTEST=1 FAT_ALLOW_ESP_WRITE=1 ./scripts/build.sh   # scripts/exfat-write-smoke.sh on an ESP-typed test image

# Full developmental output
KTEST=1 XHCI_VERBOSE=1 ./scripts/build.sh
```

### Why prepend instead of `cyrius build -D`?

The cyrius wrapper's `-D` flag defines a macro at the top-level entry file only — it **does not propagate into nested `#ifdef` blocks reached via `include`**. Since `KTEST` is referenced from `kernel/core/main.cyr` (an included file) and `XHCI_VERBOSE` from the xhci files under `kernel/arch/x86_64/usb/` (also included), `-D` alone would silently leave them undefined. The script prepends `#define` lines to a temporary build-tree copy of `agnos.cyr` so the defines are present at the top of the unified preprocessed unit — same workaround the script already uses for `ARCH_X86_64` and `ELF64_KERNEL`.

---

## Build outputs

```
build/agnos              # x86_64 ELF64 multiboot2 kernel (default build)
build/agnos-aarch64      # aarch64 ELF for QEMU virt-machine
build/agnos_x86.cyr      # transient preprocessed source (deleted after build)
build/agnos_arm.cyr      # transient preprocessed source (deleted after build, aarch64)
build/agnos_ktest        # produced by scripts/ktest.sh (separate flow — see below)
```

The validation step at the end of `build.sh` checks:

- `EI_CLASS` byte (1 = ELF32, 2 = ELF64; expects 2 for the default Path-C build)
- Multiboot header magic at the correct file offset (`0xe85250d6` at offset 120 for ELF64+multiboot2)
- Entry point (`0x1000A8` for ELF64, matching what gnoboot jumps to with `RDI = &boot_info`)

A WARN from validation is a structural-mismatch — fix before booting.

---

## Smoke testing

| Script | Purpose | Reads gated output? |
|---|---|---|
| `scripts/ktest.sh` | Runs the dedicated **shell-command** test suite under QEMU. Builds a separate `build/agnos_ktest` binary with `-D TEST` (which gates `include "user/test.cyr"` in `agnos.cyr`) and greps output for `PASS:` / `FAIL:` / `TOTAL:` lines from the assertion framework. **Different from the `KTEST` flag** described above — `TEST` enables the shell-side `test` command (assertion framework), `KTEST` enables boot-time inline tests | No (uses its own `TEST` gate) |
| `scripts/test.sh` | Cyrius `check.sh` style structural gate — checks kernel source compiles cleanly for both archs | No |
| `agnosticos/scripts/qemu-fb-smoke.sh` | End-to-end QEMU boot test via gnoboot + OVMF. Default `EXPECT="AGNOS shell"` matches the unconditional kybernet banner — runs cleanly on the default lean build | No |
| `gnoboot/tests/ovmf_smoke.sh` | gnoboot-side smoke; matches the `"gnoboot v<VERSION>"` banner | No |

None of the smoke harnesses depend on `KTEST` or `XHCI_VERBOSE` output being present; the gated lines are developmental noise, not validation signal.

---

## Architecture / handoff context

| Topic | Reference |
|---|---|
| Path C sovereign-struct handoff (gnoboot → kernel) | `agnosticos/docs/development/path-c-sovereign-uefi.md` |
| Boot info struct layout (`magic 'AGNO'`, `RDI = &boot_info`) | `gnoboot/docs/architecture/001-sovereign-handoff-contract.md` |
| Why GRUB MB2-EFI was retired (Path A dead-end) | `agnosticos/docs/development/prior-art/path-a-elf64-multiboot2.md` |
| Iron bring-up arc on archaemenid (NUC AMD Zen) | `agnosticos/docs/development/iron-nuc-zen-log.md` |

---

## Related repos

- **gnoboot** (`/home/macro/Repos/gnoboot/`): sovereign UEFI bootloader; `CYRIUS_TARGET_EFI=1 cyrius build src/main.cyr build/BOOTX64.EFI` produces the PE32+ EFI Application that loads `build/agnos` from the ESP. Its `CHANGELOG.md` documents the wire-format ABI between gnoboot and the kernel.
- **cyrius** (`/home/macro/Repos/cyrius/`): the toolchain. AGNOS pins a specific version in `cyrius.cyml`; the wrapper at `~/.cyrius/bin/cyrius` honors that pin and dispatches to the right `cycc` snapshot.
