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

# kashi freestanding font-data core (1.37.5 fold-in). Located via env var
# with a sibling-checkout default — works on a local devbox where both
# repos live under ~/Repos/ AND in CI where actions/checkout only fetches
# this repo. When the sibling is absent we clone the pinned tag (override
# via KASHI_REF=<tag-or-branch>). Pinned at 1.0.3 — kashi's v1 API freeze;
# bump as kashi cuts new 1.x releases (only affects the clone fallback — the
# freestanding font_data.cyr is byte-identical across the 1.0.x toolchain bumps).
KASHI_DIR="${KASHI_DIR:-$ROOT/../kashi}"
KASHI_REF="${KASHI_REF:-1.0.3}"
if [ ! -f "$KASHI_DIR/src/font_data.cyr" ]; then
    echo "  kashi not at $KASHI_DIR — cloning $KASHI_REF for build..." >&2
    rm -rf "$KASHI_DIR"
    git clone --quiet --depth 1 --branch "$KASHI_REF" \
        https://github.com/MacCracken/kashi.git "$KASHI_DIR" >&2 || {
        echo "ERROR: kashi clone failed (ref=$KASHI_REF)" >&2
        exit 1
    }
fi
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
    #   TEST=1          — compile in the kernel `test` shell verb + its suite
    #                     (user/test.cyr: PMM/heap/VFS/proc/syscall/kstdlib/
    #                     initrd assertions, gated by `#ifdef TEST` in agnos.cyr
    #                     + user/shell.cyr). Used by scripts/ktest.sh, which
    #                     rewrites core/boot_finish.cyr to run sh_cmd_test() at
    #                     boot in place of the kybernet launch.
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
    #   HARDENING_SELFTEST=1 — arc-close hardening self-test (1.35.7): hermetic
    #                     ip_safe_payload_len ingress-clamp table. Gated by
    #                     scripts/hardening-smoke.sh.
    {
        echo '#define ARCH_X86_64'
        echo '#define ELF64_KERNEL'
        [ -n "$TEST" ]           && echo '#define TEST'
        [ -n "$KTEST" ]          && echo '#define KTEST'
        [ -n "$XHCI_VERBOSE" ]   && echo '#define XHCI_VERBOSE'
        [ -n "$AHCI_RW_DEMO" ]   && echo '#define AHCI_RW_DEMO'
        [ -n "$MSC_RW_DEMO" ]    && echo '#define MSC_RW_DEMO'
        [ -n "$RAMDISK_ENABLE" ] && echo '#define RAMDISK_ENABLE'
        [ -n "$TCP_LISTEN_SMOKE" ] && echo '#define TCP_LISTEN_SMOKE'
        [ -n "$NET_VERBOSE" ]    && echo '#define NET_VERBOSE'
        [ -n "$EXT2_WRITE_SELFTEST" ] && echo '#define EXT2_WRITE_SELFTEST'
        [ -n "$EXT2_EXTENT_WRITE_SELFTEST" ] && echo '#define EXT2_EXTENT_WRITE_SELFTEST'
        [ -n "$MULTICHUNK_SELFTEST" ] && echo '#define MULTICHUNK_SELFTEST'
        [ -n "$EXEC_SELFTEST" ]      && echo '#define EXEC_SELFTEST'
        [ -n "$SYMLINK_SELFTEST" ]   && echo '#define SYMLINK_SELFTEST'
        [ -n "$ARK_SELFTEST" ]       && echo '#define ARK_SELFTEST'
        [ -n "$ARK_INSTALL_SELFTEST" ] && echo '#define ARK_INSTALL_SELFTEST'
        [ -n "$BASESTACK_SELFTEST" ] && echo '#define BASESTACK_SELFTEST'
        [ -n "$BOTE_SELFTEST" ] && echo '#define BOTE_SELFTEST'
        [ -n "$BENCH_CONNECT_SELFTEST" ] && echo '#define BENCH_CONNECT_SELFTEST'
        [ -n "$FAULT_SELFTEST" ]     && echo '#define FAULT_SELFTEST'
        [ -n "$PIPE_RC_SELFTEST" ]   && echo '#define PIPE_RC_SELFTEST'
        [ -n "$DOOM_SELFTEST" ]      && echo '#define DOOM_SELFTEST'
        [ -n "$DOOM_DIRECTMAP" ]     && echo '#define DOOM_DIRECTMAP'
        [ -n "$AETHERSAFHA_SELFTEST" ] && echo '#define AETHERSAFHA_SELFTEST'
        [ -n "$AETHERSAFHA_SETU_SELFTEST" ] && echo '#define AETHERSAFHA_SETU_SELFTEST'
        [ -n "$DOOM_AUDIO_SELFTEST" ] && echo '#define DOOM_AUDIO_SELFTEST'
        [ -n "$TONEGEN_SELFTEST" ]   && echo '#define TONEGEN_SELFTEST'
        [ -n "$VANITONE_AUDIO_SELFTEST" ] && echo '#define VANITONE_AUDIO_SELFTEST'
        [ -n "$MISHRAN_AUDIO_SELFTEST" ] && echo '#define MISHRAN_AUDIO_SELFTEST'
        [ -n "$MISHRAN_JALWA_SELFTEST" ] && echo '#define MISHRAN_JALWA_SELFTEST'
        [ -n "$MISHRAN_DUPLEX_SELFTEST" ] && echo '#define MISHRAN_DUPLEX_SELFTEST'
        [ -n "$FP_SELFTEST" ]        && echo '#define FP_SELFTEST'
        [ -n "$FP_AREA_SELFTEST" ]   && echo '#define FP_AREA_SELFTEST'
        [ -n "$FP_NM_SELFTEST" ]     && echo '#define FP_NM_SELFTEST'
        [ -n "$FP_RING3_SELFTEST" ]  && echo '#define FP_RING3_SELFTEST'
        [ -n "$FP_CTXSW_SELFTEST" ]  && echo '#define FP_CTXSW_SELFTEST'
        [ -n "$NAAD_RING3_SELFTEST" ] && echo '#define NAAD_RING3_SELFTEST'
        [ -n "$BLK_RING3_SELFTEST" ] && echo '#define BLK_RING3_SELFTEST'
        [ -n "$BLK_WRITE_SELFTEST" ] && echo '#define BLK_WRITE_SELFTEST'
        [ -n "$GPT_WRITE_SELFTEST" ] && echo '#define GPT_WRITE_SELFTEST'
        [ -n "$AGNOVA_INSTALL_SELFTEST" ] && echo '#define AGNOVA_INSTALL_SELFTEST'

        [ -n "$NET_SELFTEST" ]       && echo '#define NET_SELFTEST'
        [ -n "$LOOPBACK_SELFTEST" ]  && echo '#define LOOPBACK_SELFTEST'
        [ -n "$PMM_FULLRAM_SELFTEST" ] && echo '#define PMM_FULLRAM_SELFTEST'
        [ -n "$PMM_HIRAM_SELFTEST" ] && echo '#define PMM_HIRAM_SELFTEST'
        [ -n "$PMM_RAMSTRESS_SELFTEST" ] && echo '#define PMM_RAMSTRESS_SELFTEST'
        # Boot-CR3 → own-PML4 switch is DEFAULT-ON since 1.50.1 (iron-validated). Opt OUT with
        # BOOTCR3_KEEP_GNOBOOT_CR3=1 to keep running boot/idle on gnoboot's transient boot CR3.
        [ -n "$BOOTCR3_KEEP_GNOBOOT_CR3" ] && echo '#define BOOTCR3_KEEP_GNOBOOT_CR3'
        [ -n "$PDPT_GUARD_SELFTEST" ] && echo '#define PDPT_GUARD_SELFTEST'
        [ -n "$FB_ANSI_SELFTEST" ]   && echo '#define FB_ANSI_SELFTEST'
        [ -n "$FB_ANSI_VISUAL" ]     && echo '#define FB_ANSI_VISUAL'
        [ -n "$KLUG_SELFTEST" ]      && echo '#define KLUG_SELFTEST'
        [ -n "$FS_SYSCALL_SELFTEST" ] && echo '#define FS_SYSCALL_SELFTEST'
        [ -n "$EXEC_REDIRECT_SELFTEST" ] && echo '#define EXEC_REDIRECT_SELFTEST'
        [ -n "$SYSCALL_HARDEN_SELFTEST" ] && echo '#define SYSCALL_HARDEN_SELFTEST'
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
        [ -n "$MMAP_HIMEM_SELFTEST" ] && echo '#define MMAP_HIMEM_SELFTEST'
        [ -n "$MMAP_HIMEM_E2E_SELFTEST" ] && echo '#define MMAP_HIMEM_E2E_SELFTEST'
        [ -n "$MMAP_HIMUNMAP_SELFTEST" ] && echo '#define MMAP_HIMUNMAP_SELFTEST'
        [ -n "$MMAP_HIMEM_PERPROC_SELFTEST" ] && echo '#define MMAP_HIMEM_PERPROC_SELFTEST'
        [ -n "$PPID_SELFTEST" ]  && echo '#define PPID_SELFTEST'
        [ -n "$RTC_SELFTEST" ]   && echo '#define RTC_SELFTEST'
        [ -n "$HARDENING_SELFTEST" ] && echo '#define HARDENING_SELFTEST'
        [ -n "$JBD2_LOGDUMP" ]       && echo '#define JBD2_LOGDUMP'
        [ -n "$JBD2_TX_SELFTEST" ]   && echo '#define JBD2_TX_SELFTEST'
        [ -n "$JBD2_WP_SELFTEST" ]   && echo '#define JBD2_WP_SELFTEST'
        [ -n "$JBD2_INT_SELFTEST" ]  && echo '#define JBD2_INT_SELFTEST'
        [ -n "$JBD2_CRASH_SELFTEST" ] && echo '#define JBD2_CRASH_SELFTEST'
        [ -n "$JBD2_NO_REPLAY" ]     && echo '#define JBD2_NO_REPLAY'
        [ -n "$THREAD_SELFTEST" ]    && echo '#define THREAD_SELFTEST'
        [ -n "$RING3_SELFTEST" ]     && echo '#define RING3_SELFTEST'
        [ -n "$SCHED_STRESS_SELFTEST" ] && echo '#define SCHED_STRESS_SELFTEST'
        [ -n "$FLOCK_SELFTEST" ]     && echo '#define FLOCK_SELFTEST'
        [ -n "$WINSIZE_SELFTEST" ]   && echo '#define WINSIZE_SELFTEST'
        [ -n "$NBREAD_SELFTEST" ]    && echo '#define NBREAD_SELFTEST'
        [ -n "$FBSCALE_SELFTEST" ]   && echo '#define FBSCALE_SELFTEST'
        # HDA_TONE=1 — B4 first-tone: hda_stream_arm fills the PCM ring with a
        # ~375 Hz triangle instead of silence. Gated so production boots stay
        # silent. Drives scripts/hda-tone-smoke.sh (QEMU -audiodev wav RMS) and
        # the archaemenid front-jack audible test.
        [ -n "$HDA_TONE" ]           && echo '#define HDA_TONE'
        # SND_SELFTEST=1 — Gate 2 (B6): hermetic snd_* band self-test (hda_snd_selftest
        # in hda.cyr) — drives the #64-69 handlers + fills the ring with a tone the DMA
        # loops. Drives scripts/snd-smoke.sh (QEMU -audiodev wav + serial PASS marker).
        [ -n "$SND_SELFTEST" ]       && echo '#define SND_SELFTEST'
        # HDA_HDMI=1 — HDMI-audio arc bite 2b: probe + enumerate a SECOND HD-Audio
        # controller as instance 1 (archaemenid 04:00.1 HDMI/DP, or a 2nd QEMU
        # -device intel-hda). Instance 0 (analog) stays the default sink. Gated so the
        # production/MVP kernel stays single-controller. Drives scripts/hda-dual-smoke.sh.
        [ -n "$HDA_HDMI" ]           && echo '#define HDA_HDMI'
        # HDMI_AUDIO_DUMP=1 — dump the display-audio register block AFTER the enable path
        # has run, in the exact order + naming of agnosticos/scripts/dump-dcn-audio.py, so
        # the agnos side can be DIFFED against the known-good captured off amdgpu on the
        # same silicon (/tmp/amdgpu-good.txt). Diagnostic-only: this is a raw hex dump and
        # therefore gated OUT of every normal build per the kernel-log rule (plain driver
        # statements, never hex). Capture with: run /bin/klug > dump.txt
        [ -n "$HDMI_AUDIO_DUMP" ]    && echo '#define HDMI_AUDIO_DUMP'
        # HDMI_AUDIO_SWEEP=1 — in-boot HDMI-audio FIX-PROFILE sweep. Post-sti, with the HDA tone
        # already streaming to the HDMI sink, cycle gpu_hdmi_audio_profile(0..N) — each applies a
        # candidate structural/sequencing/clock fix to the live encoder, prints its name, and holds
        # ~3s. The operator watches serial + LISTENS: one boot tests the whole hypothesis matrix
        # instead of one-per-reflash. Requires HDA_HDMI + HDA_TONE (the streaming tone + HDMI sink).
        [ -n "$HDMI_AUDIO_SWEEP" ]   && echo '#define HDMI_AUDIO_SWEEP'
        # HDMI_ATOM=1 — A4 (1.55.x): run the sovereign ATOM interpreter's HDMI transmitter bring-up
        # (DIGxEncoderControl(HDMI) + DIG1TransmitterControl(ENABLE)) before gpu_hdmi_audio_enable(). This
        # is the firmware-driven encoder/PHY setup the GOP did as DVI and the raw DIG_MODE flip cannot
        # reproduce — the missing subsystem the 1.55.x arc converged on. Console-risky (drives the PHY);
        # requires HDA_HDMI. Recovery: flash without it.
        [ -n "$HDMI_ATOM" ]          && echo '#define HDMI_ATOM'
        # ATOM_TRACE=1 — print every MMIO write the ATOM interpreter makes (idx + value) for diffing the
        # live write sequence against the atom-interp.py oracle. Bring-up debug aid; pairs with HDMI_ATOM.
        [ -n "$ATOM_TRACE" ]         && echo '#define ATOM_TRACE'
        # ATOM_DRY=1 — dry-run validation: the interpreter's atom_reg_read() returns 0 and atom_reg_write()
        # SUPPRESSES the store (traced, never applied). Runs the full control flow without touching the PHY, so
        # the console survives. WITHOUT this, HMDI_ATOM drives the PHY live. (Was missing 2026-07-18 — the
        # "DRY" burn built byte-identical to LIVE and drove the PHY, blacking the iron display. The
        # atom_hdmi_transmitter_bringup() banner now prints DRY vs LIVE so the boot log is dispositive.)
        [ -n "$ATOM_DRY" ]           && echo '#define ATOM_DRY'
        # ATOM_HALT=1 — ISOLATION diagnostic: after the ATOM path, halt (freeze the FB for a photo) BEFORE
        # gpu_hdmi_audio_enable()'s DIG_MODE flip. Pairs with ATOM_DRY to isolate ATOM-path vs DIG-flip as the
        # cause of the iron black-screen. Never in a shipping build.
        [ -n "$ATOM_HALT" ]          && echo '#define ATOM_HALT'
        # ATOM_RUN_TRANSMITTER=1 — also run DIG1TransmitterControl(ENABLE) after the encoder setup. OFF by
        # default: on iron (1.55.23) the transmitter's PHY power-cycle blanks the live console pipe non-
        # recoverably. The default HDMI_ATOM build runs the encoder setup ONLY (DIG front-end, PHY-safe).
        # Enable this only with a full modeset (SetPixelClock + OTG recommit) in place.
        [ -n "$ATOM_RUN_TRANSMITTER" ] && echo '#define ATOM_RUN_TRANSMITTER'
        # Freestanding kashi font-data core (1.37.5 fold-in). Inlined here
        # rather than via cyrius dep resolution because `cyrius build` looks
        # for cyrius.cyml at cwd and we cd into kernel/ for relative include
        # resolution. The [deps.kashi] block in cyrius.cyml documents the
        # contract; this cat is the mechanism. Zero-stdlib by construction.
        # KASHI_DIR resolved above (sibling checkout locally, auto-clone in CI).
        cat "$KASHI_DIR/src/font_data.cyr"
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
