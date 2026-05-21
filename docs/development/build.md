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

Three of these (architecture, ELF64) are mandatory and set by the script automatically. Two are opt-in development gates set via env var.

| Flag | Defined where | Default | Effect |
|---|---|---|---|
| `ARCH_X86_64` | source-side (prepended) | on (auto, x86_64 build) | Includes the x86_64 platform code path |
| `ARCH_AARCH64` | source-side (prepended) | on (auto, `--aarch64` build) | Includes the aarch64 platform code path |
| `ELF64_KERNEL` | source-side (prepended) | on (auto, x86_64) | Selects the 64-bit entry shim (Path C handoff via gnoboot). Paired with `CYRIUS_ELF64_KERNEL=1` (backend gate) |
| **`KTEST`** | source-side (prepended, env-driven) | **off** | Compiles in the boot-time in-kernel self-tests (Syscall test, Context Switch test, Scheduler test idle loop, VFS/initrd test, Userland Exec test). About 18 lines of test output + several CMOS checkpoints (CP14, CP12-twice, CP14-twice). Off in production so iron boots don't carry test spam |
| **`XHCI_VERBOSE`** | source-side (prepended, env-driven) | **off** | Compiles in xhci developmental debug output: `cmd_submit#` trb-tracking, `evt#` event trace, `drained N events`, `PP=1 asserted bitmap=`, `CRCR.CRR / ERSTSZ / IMAN / ERDP_lo` readback, `enable_slot entry idx=`. High-level confirmation lines (`halted, reset clean`, `dev_notifications enabled`, `controller running, HCH=0, ERDP=`, port-connected, error cases) are unconditional regardless of this flag |
| **`AHCI_RW_DEMO`** | source-side (prepended, env-driven) | **off** | Compiles in the AHCI boot-time sentinel write + read-back round-trip at LBA 5 of the lowest-numbered initialized SATA port. Default-off because LBA 5 on a GPT-formatted disk sits inside the partition-entry array (entries 12-15 at standard `partition_entries_lba=2` layout); writing a sentinel there corrupts the partition-array CRC (recoverable via `sgdisk --load-backup` from the disk's tail backup, but not the right default posture against drives the user cares about). The always-on `ahci_read_demo` (LBA 0 readback, no writes) provides Phase-4-DMA validation on iron without the write hazard. Enable for QEMU smoke (`AHCI_RW_DEMO=1 ./scripts/build.sh`) or known-scratch drives only |
| **`MSC_RW_DEMO`** | source-side (prepended, env-driven) | **off** | Compiles in the USB Mass Storage boot-time sentinel write + read-back round-trip at LBA 100 of `msc_first_slot` (first MSC-BBB device that completes Phase 1-3). Default-off for the same reason as `AHCI_RW_DEMO` — LBA 100 on a typical USB stick may sit inside a filesystem; sentinel writes there are recoverable (8 bytes overwritten) but not the right default posture against drives the user cares about. The always-on `msc_read_demo` (LBA 0 readback, no writes) provides Phase-4-DMA validation on iron without the write hazard. Enable for QEMU smoke (`MSC_RW_DEMO=1 ./scripts/build.sh`) or known-scratch USB devices only |
| **`RAMDISK_ENABLE`** | source-side (prepended, env-driven) | **off** | Compiles in the RAM-disk block backend (`kernel/core/ramdisk.cyr`). At boot, preallocates 64 pages (256 KB) from `pmm_alloc` and registers as the lowest-priority block backend — takes the slot only when no other backend (NVMe / AHCI / USB-MS / VirtIO) holds it. Useful as a development substrate for filesystem work without iron and as a regression target for the block-dispatch policy. Default-off because the 256 KB allocation eats ~18% of archaemenid's post-boot pmm budget (~354 free pages); production boots stay lean. To resize, edit `RAMDISK_NPAGES_DEFAULT` in `ramdisk.cyr` (capped at 128 = 512 KB by `RAMDISK_NPAGES_MAX` until the pmm budget audit reports >1024 free pages post-boot). Multi-source convergent design (OpenBSD `rd.c` MINIROOTSIZE pattern + NetBSD `md.c` MD_KMEM_ALLOCATED preallocation) — see `agnosticos/docs/development/ramdisk-virtio-modern-prior-art.md` § 3 |

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
| Why GRUB MB2-EFI was retired (Path A dead-end) | `agnosticos/docs/development/path-a-elf64-multiboot2.md` |
| Iron bring-up arc on archaemenid (NUC AMD Zen) | `agnosticos/docs/development/iron-nuc-zen-log.md` |

---

## Related repos

- **gnoboot** (`/home/macro/Repos/gnoboot/`): sovereign UEFI bootloader; `CYRIUS_TARGET_EFI=1 cyrius build src/main.cyr build/BOOTX64.EFI` produces the PE32+ EFI Application that loads `build/agnos` from the ESP. Its `CHANGELOG.md` documents the wire-format ABI between gnoboot and the kernel.
- **cyrius** (`/home/macro/Repos/cyrius/`): the toolchain. AGNOS pins a specific version in `cyrius.cyml`; the wrapper at `~/.cyrius/bin/cyrius` honors that pin and dispatches to the right `cycc` snapshot.
