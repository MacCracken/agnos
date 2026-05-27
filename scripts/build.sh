#!/bin/sh
# Build the AGNOS kernel
# Supports: x86_64 (default), aarch64 (--aarch64)
# Requires: Cyrius toolchain (~/.cyrius/bin/cyrius)
#
# All compilation goes through `cyrius build` — we never invoke cc5
# directly. The cyrius wrapper resolves includes, manages the temp
# tree, and dispatches to cc5 / cc5_aarch64 internally.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CYRIUS_HOME="${CYRIUS_HOME:-$HOME/.cyrius}"
CYRB="$CYRIUS_HOME/bin/cyrius"
CC_ARM="$CYRIUS_HOME/bin/cc5_aarch64"
echo "  toolchain: $CYRB" >&2
ARCH="x86_64"

if [ "$1" = "--aarch64" ]; then
    ARCH="aarch64"
    shift
fi

if [ ! -x "$CYRB" ]; then
    echo "ERROR: cyrius wrapper not found at $CYRB" >&2
    echo "Install: curl -sSf https://raw.githubusercontent.com/MacCracken/cyrius/main/scripts/install.sh | sh" >&2
    exit 1
fi

mkdir -p "$ROOT/build"

if [ "$ARCH" = "aarch64" ]; then
    if [ ! -x "$CC_ARM" ]; then
        echo "ERROR: aarch64 cross-compiler not in toolchain ($CC_ARM)" >&2
        exit 1
    fi
    echo "Building AGNOS kernel [aarch64]..."
    # `cyrius build -D ARCH_AARCH64` does not propagate into nested #ifdef
    # blocks reached via `include`. Workaround: prepend the define.
    PREPPED_ARM="$ROOT/build/agnos_arm.cyr"
    (echo '#define ARCH_AARCH64' && cat "$ROOT/kernel/agnos.cyr") > "$PREPPED_ARM"
    (cd "$ROOT/kernel" && "$CYRB" build --aarch64 --no-deps "$PREPPED_ARM" "$ROOT/build/agnos-aarch64")
    rm -f "$PREPPED_ARM"
    chmod +x "$ROOT/build/agnos-aarch64"
    SZ=$(wc -c < "$ROOT/build/agnos-aarch64")
    echo "  -> build/agnos-aarch64 ($SZ bytes)"
    echo "Boot: qemu-system-aarch64 -M virt -cpu cortex-a57 -kernel build/agnos-aarch64 -serial stdio -display none"
else
    echo "Building AGNOS kernel [x86_64]..."
    # ELF64 multiboot2 emit (cyrius 5.11.43+). Routes through
    # EMITELF64_KERNEL: ELF64 header + multiboot2 + EFI64-entry tag.
    # Sovereign UEFI handoff: gnoboot (PE32+ UEFI bootloader) walks
    # the multiboot2 program headers, maps the kernel, then `jmp rax`
    # with RDI = &boot_info (magic 0x41474E4F). The kernel captures
    # RDI in kernel/arch/x86_64/mbi.cyr at entry (v1.30.0+).
    # Design: agnosticos/docs/development/path-c-sovereign-uefi.md.
    # The Path-A GRUB-MB2-EFI approach was retired 2026-05-13 (strict
    # W^X UEFI faults inside grub_relocator64_efi_boot); see
    # agnosticos/docs/development/path-a-elf64-multiboot2.md (archived
    # in place) for the dead-end audit trail.
    export CYRIUS_ELF64_KERNEL=1
    PREPPED="$ROOT/build/agnos_x86.cyr"
    # `#define ELF64_KERNEL` is the *source-side* gate (kernel shim selects
    # 64-bit entry under `#ifdef ELF64_KERNEL`); `CYRIUS_ELF64_KERNEL=1`
    # above is the *cyrius-backend* gate (selects EMITELF64_KERNEL emit
    # path). Both must be set in lockstep. Prepended rather than `-D`'d
    # because `-D` doesn't propagate into included files (cyrius caveat
    # — same reason `ARCH_X86_64` is prepended, not `-D`'d).
    #
    # Optional gates (env-var driven, same prepend mechanism):
    #   KTEST=1         — boot-time in-kernel self-tests (Syscall, Context
    #                     Switch, VFS/initrd, Userland Exec) emit their
    #                     output and CMOS checkpoints. Off by default;
    #                     production boots skip the test spam.
    #   XHCI_VERBOSE=1  — xhci developmental debug detail (cmd_submit#,
    #                     evt# trace, PP=1 bitmap, CRCR.CRR readback,
    #                     enable_slot entry idx). High-level confirmation
    #                     lines (halted/reset clean, dev_notifications,
    #                     controller running, port N connected, error
    #                     cases) stay unconditional.
    #   AHCI_RW_DEMO=1  — boot-time LBA-5 sentinel write + read-back on
    #                     the first initialized SATA port. DEFAULT OFF
    #                     in production iron builds: LBA 5 of a GPT disk
    #                     sits inside the partition-entry array, and a
    #                     write there is recoverable but not the right
    #                     default posture. Enable for QEMU smoke or
    #                     known-scratch drives to validate the WRITE
    #                     DMA EXT path; ahci_read_demo (LBA 0 readback)
    #                     runs unconditionally either way.
    #   NET_VERBOSE=1   — boot net diagnostics: the 1.1.1.1:80 outbound-TCP
    #                     smoke + the r8169 silicon tally readback
    #                     (rx_uc/rx_bc/rx_mc/missed). Off by default — the
    #                     1.32.x unicast-RX arc is closed, so production
    #                     boots end cleanly at "net: L2 OK". Enable to
    #                     re-confirm end-to-end connectivity on iron.
    #   FATFS_SELFTEST=1 — boot-time FAT read self-test (1.34.x): mount the
    #                     FAT, list root, read the seeded multi-cluster
    #                     FATTEST.BIN back via the cluster chain + byte-
    #                     verify. Gated by scripts/fat-smoke.sh.
    #   EXFAT_SELFTEST=1 — boot-time exFAT read self-test (1.34.1): mount,
    #                     locate the bitmap/upcase system files, and read
    #                     the upcase table back over its FAT chain to
    #                     reproduce its TableChecksum (independent oracle,
    #                     no file seeding). Gated by scripts/exfat-smoke.sh.
    #   EXFAT_WRITE_SELFTEST=1 — boot-time exFAT write self-test (1.34.1
    #                     bite 3): create a file by writing its dir-set
    #                     (0x85/0xC0/0xC1 + SetChecksum + NameHash). Gated
    #                     by scripts/exfat-write-smoke.sh (fsck.exfat -n).
    #   FAT_ALLOW_ESP_WRITE=1 — override the ESP-write safety guard (1.34.x):
    #                     FAT/exFAT writes are refused on an ESP-type GPT
    #                     partition by default (the boot ESP is read-only).
    #                     Set this ONLY for the QEMU fat-write-smoke, whose
    #                     ESP image is a throwaway test volume. NEVER on an
    #                     iron build — the burn targets a data volume.
    #   DNS_SELFTEST=1   — boot-time DNS stub self-test (1.35.x): prints the
    #                     DHCP-captured resolver (option 6), runs a hermetic
    #                     RFC 1035 parse test (compression-pointer answer ->
    #                     93.184.216.34), and attempts a live lookup. Gated
    #                     by scripts/dns-smoke.sh.
    #   ICMP_SELFTEST=1  — boot-time ICMP echo self-test (1.35.x): hermetic
    #                     checksum self-verify (a valid ICMP message sums to
    #                     0) + a best-effort gateway ping. Gated by
    #                     scripts/icmp-smoke.sh.
    #   TCP_SELFTEST=1   — boot-time TCP receive-ring self-test (1.35.1 B1):
    #                     hermetic FIFO-order + buffer-wrap reassembly check on
    #                     the in-order ring. Gated by scripts/tcp-smoke.sh.
    #   NTP_SELFTEST=1   — boot-time SNTP parse self-test (1.35.x): hermetic
    #                     transmit-timestamp → Unix epoch conversion + UTC
    #                     breakdown. Gated by scripts/ntp-smoke.sh.
    #   MMAP_SELFTEST=1  — boot-time anonymous-mmap allocator self-test
    #                     (1.35.3): hermetic 2 MB-contiguous alloc/free/count +
    #                     mmap length-rounding. Gated by scripts/mmap-smoke.sh.
    #   RTC_SELFTEST=1   — boot-time RTC boot-clock self-test (1.35.5): hermetic
    #                     civil_to_unix anchors + BCD decode + a live-bounded
    #                     CMOS read sanity. Gated by scripts/rtc-smoke.sh.
    {
        echo '#define ARCH_X86_64'
        echo '#define ELF64_KERNEL'
        [ -n "$KTEST" ]          && echo '#define KTEST'
        [ -n "$XHCI_VERBOSE" ]   && echo '#define XHCI_VERBOSE'
        [ -n "$AHCI_RW_DEMO" ]   && echo '#define AHCI_RW_DEMO'
        [ -n "$MSC_RW_DEMO" ]    && echo '#define MSC_RW_DEMO'
        [ -n "$RAMDISK_ENABLE" ] && echo '#define RAMDISK_ENABLE'
        [ -n "$TCP_LISTEN_SMOKE" ] && echo '#define TCP_LISTEN_SMOKE'
        [ -n "$NET_VERBOSE" ]    && echo '#define NET_VERBOSE'
        [ -n "$EXT2_WRITE_SELFTEST" ] && echo '#define EXT2_WRITE_SELFTEST'
        [ -n "$FATFS_SELFTEST" ] && echo '#define FATFS_SELFTEST'
        [ -n "$FATFS_WRITE_SELFTEST" ] && echo '#define FATFS_WRITE_SELFTEST'
        [ -n "$EXFAT_SELFTEST" ] && echo '#define EXFAT_SELFTEST'
        [ -n "$EXFAT_WRITE_SELFTEST" ] && echo '#define EXFAT_WRITE_SELFTEST'
        [ -n "$FAT_ALLOW_ESP_WRITE" ] && echo '#define FAT_ALLOW_ESP_WRITE'
        [ -n "$DNS_SELFTEST" ]   && echo '#define DNS_SELFTEST'
        [ -n "$ICMP_SELFTEST" ]  && echo '#define ICMP_SELFTEST'
        [ -n "$TCP_SELFTEST" ]   && echo '#define TCP_SELFTEST'
        [ -n "$NTP_SELFTEST" ]   && echo '#define NTP_SELFTEST'
        [ -n "$MMAP_SELFTEST" ]  && echo '#define MMAP_SELFTEST'
        [ -n "$RTC_SELFTEST" ]   && echo '#define RTC_SELFTEST'
        cat "$ROOT/kernel/agnos.cyr"
    } > "$PREPPED"
    (cd "$ROOT/kernel" && "$CYRB" build --no-deps "$PREPPED" "$ROOT/build/agnos")
    rm -f "$PREPPED"
    SZ=$(wc -c < "$ROOT/build/agnos")
    echo "  -> build/agnos ($SZ bytes)"

    # Validate. EI_CLASS at byte 4: 1=ELF32 (legacy multiboot1 path),
    # 2=ELF64 (multiboot2 + EFI64). Multiboot header position differs:
    # ELF32 file offset 84 (after 52+32 = ELF32+PH32), ELF64 file offset
    # 120 (after 64+56 = ELF64+PH64). Entry is e_entry low 32 bits in
    # both classes — ELF32 e_entry is u32 at offset 24; ELF64 e_entry
    # is u64 at offset 24, low half also at offset 24.
    python3 -c "
import struct
with open('$ROOT/build/agnos','rb') as f: d=f.read()
eic = d[4]
if eic == 1:
    mb_off, exp_mb, exp_entry, label = 84, 0x1badb002, 0x100060, 'multiboot1 (ELF32)'
elif eic == 2:
    mb_off, exp_mb, exp_entry, label = 120, 0xe85250d6, 0x1000a8, 'multiboot2 (ELF64)'
else:
    print('WARN: unknown EI_CLASS'); exit(1)
mb = struct.unpack_from('<I',d,mb_off)[0]
entry = struct.unpack_from('<I',d,24)[0]
if mb != exp_mb: print('WARN: bad multiboot magic (got 0x{:x} at file offset {}, expected 0x{:x})'.format(mb, mb_off, exp_mb)); exit(1)
if entry != exp_entry: print('WARN: bad entry point (got 0x{:x}, expected 0x{:x})'.format(entry, exp_entry)); exit(1)
print('  ' + label + ': OK')
print('  entry: 0x{:x}'.format(entry))
" 2>/dev/null || echo "  (python3 not available, skipping validation)"

    # ELF64 kernel boot — gnoboot maps the kernel, sets RDI=&boot_info,
    # and jmp rax's into the 64-bit entry (kernel/arch/x86_64/mbi.cyr
    # captures RDI as the first instruction). Iron-validated on
    # archaemenid NUC AMD Zen 2026-05-15 (boot-to-shell MVP cleared the
    # kernel-init layer). QEMU: use OVMF + gnoboot (see
    # gnoboot/tests/ovmf_smoke.sh). Legacy `qemu -kernel` is gone —
    # ELF64 has no PVH note; QEMU rejects it on the Linux-protocol path.
    echo "Boot: gnoboot + OVMF (QEMU) or install-usb.sh (iron)"
fi
