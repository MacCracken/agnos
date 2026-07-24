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
    # --- Selftest flag DEPENDENCIES (fail loud; a silent no-op costs an iron burn) -------------------
    # Some selftests refuse to run unless an EARLIER selftest set its proof flag. gpu_shader_cov_test and
    # gpu_shader_rect_test both open with
    #     if (gpu_blend_ok != 1) { "gpu: skipping ... (blend math unproven)"; return 0; }
    # and gpu_blend_ok is set ONLY by gpu_shader_blend_test, which compiles only under SHADER_BLEND. So
    # SHADER_COV=1 or SHADER_RECT=1 WITHOUT SHADER_BLEND=1 builds a kernel that prints "skipping" and
    # proves nothing — indistinguishable from a pass unless you read for an absent line.
    #
    # This cost the first 1.56.4 burn (2026-07-22): glyph and gradient passed, coverage never ran, and the
    # coverage re-proof was the one arm that burn actually owed. Checked HERE rather than in burn-prep.sh
    # because burns have historically been driven by hand-exported defines straight to this script, which
    # bypasses burn-prep entirely.
    if [ -n "${SHADER_COV:-}${SHADER_RECT:-}${SHADER_PERM:-}" ] && [ -z "${SHADER_BLEND:-}" ]; then
        echo "ERROR: SHADER_COV / SHADER_RECT / SHADER_PERM require SHADER_BLEND=1." >&2
        echo "       Their selftests early-return on gpu_blend_ok, which only SHADER_BLEND sets," >&2
        echo "       so this build would print 'gpu: skipping ...' and prove nothing." >&2
        echo "       (SHADER_PERM's packed-blend half uses the f32 kernel as its ORACLE, so it is not" >&2
        echo "        merely gated on it — without SHADER_BLEND there is nothing to compare against.)" >&2
        echo "       Re-run with: SHADER_BLEND=1 ${SHADER_RECT:+SHADER_RECT=1 }${SHADER_COV:+SHADER_COV=1 }${SHADER_PERM:+SHADER_PERM=1 }..." >&2
        exit 1
    fi

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
        # HDMI_DCCG=1 — apply the DCCG symbol-clock re-prime (SYMCLKA on) in gpu_hdmi_audio_enable: the
        # host-visible DCCG writes amdgpu makes for HDMI (abs 0x159-0x15c, 0x176) that agnos omitted, replicated
        # from the amdgpu modeset capture (ground truth). No PHY power-cycle ⇒ display-safe. Requires HDA_HDMI.
        [ -n "$HDMI_DCCG" ]          && echo '#define HDMI_DCCG'
        # HDMI_SYMCLK_AB=1 — the IN-BOOT A/B for the DCCG symbol-clock block (A4 attribution control). Post-sti,
        # while the HDA tone streams, alternate two labelled ~6 s listening windows: symclk RESTORED to the GOP's
        # values (window A) then amdgpu's values APPLIED (window B), twice, each bracketed by a five-register
        # readout — then run the ACR N-scale discriminator. One flash, one sink state, one cable, one volume:
        # the only thing that changes between windows is the five stores. This is the control the 1.55.24 burn
        # lacked, and without which "the symclk armed the sink" could not be told from sink drift. Requires
        # HDA_HDMI + HDA_TONE. Use INSTEAD OF HDMI_DCCG, not with it — HDMI_DCCG applies the write at boot,
        # which would leave window A already-on and destroy the experiment. Display-safe (host DCCG only).
        [ -n "$HDMI_SYMCLK_AB" ]     && echo '#define HDMI_SYMCLK_AB'
        # BURN_AUDIO_TEARDOWN=1 — the metered HDMI-audio teardown ladder (shutdown arc
        # bite 11). Six labelled rungs ~1 s apart on the shutdown path: assert+HOLD
        # AVMUTE, stop SAMPLE_SEND, stop the codec feed, disable the AZ endpoint,
        # stop the packet generators, drop the audio clock. DEFAULT OFF and it must
        # stay that way until A4 closes: the shutdown release-pop is the arc's only
        # sink-side instrument, and this ladder exists to ask WHICH RUNG produces it.
        # A pop at the SD_RUN rung would falsify "the payload is digital silence".
        [ -n "$BURN_AUDIO_TEARDOWN" ] && echo '#define BURN_AUDIO_TEARDOWN'
        # HDMI_ACR_CTS=1 — program the HDMI ACR CTS registers (48/44/32_0) to amdgpu's literal 0x3AF5C000
        # (241500). The one real register-value delta in the full agnos-vs-amdgpu diff: agnos left them 0.
        # In the audio-clock-regeneration path — the exact mechanism for a sink that receives a stream but
        # decodes clean silence. Display-safe (audio only). Requires HDA_HDMI.
        [ -n "$HDMI_ACR_CTS" ]       && echo '#define HDMI_ACR_CTS'
        # SCANOUT_LINEAR=1 — ⚠ RETIRED (v3): wrote the WRONG register (0x607) under the OTG lock and BLACKED the
        # box on iron. gpu_scanout_clear_tiling is now a no-op. Do NOT use this flag; kept for the source gate only.
        [ -n "$SCANOUT_LINEAR" ]     && echo '#define SCANOUT_LINEAR'
        # SCANOUT_PATTERN=1 — P4 bisector (register-truth 2026-07-20): flip scanout to an agnos-owned buffer
        # painted with bars/stripes/checker via the P0-verified address flip ONLY (zero hang risk — byte-identical
        # to gpu_blit_present). A photo splits the banding into scan-geometry (sheared) vs surface-content (crisp).
        # The corrected read-only 0x603/0x609 diagnostic rides in EVERY build regardless of this flag.
        [ -n "$SCANOUT_PATTERN" ]    && echo '#define SCANOUT_PATTERN'
        # SCANOUT_REDIRECT=1 — THE P4 FIX: redirect fb_console onto the agnos buffer the pattern proved scans
        # band-free, via the P0-verified address flip (zero hang risk). The console text is the oracle: legible.
        [ -n "$SCANOUT_REDIRECT" ]   && echo '#define SCANOUT_REDIRECT'
        # SCANOUT_REGDUMP=1 — read-only dump of the live-pipe HUBP register block to klug, to re-anchor the real
        # pitch/viewport offsets against known geometry (the surface is scaled ~800x600→2560x1440). Pure reads.
        [ -n "$SCANOUT_REGDUMP" ]    && echo '#define SCANOUT_REGDUMP'
        # SCANOUT_MATCHGEOM=1 — THE P4 FIX: read the real surface geometry (viewport 0x5EA + pitch 0x607) and
        # override fb_console to render at it (800x600 scaled), instead of boot_info's 2560x1440 output. Pure
        # reads + software geometry switch + console redraw — NO register writes, cannot hang/black. Oracle: the
        # console is LEGIBLE (blocky but clean, bands gone).
        [ -n "$SCANOUT_MATCHGEOM" ]  && echo '#define SCANOUT_MATCHGEOM'
        # SDMA_PROBE=1 — P9.0 read-only SDMA0 register-discovery dump (anchor the ring/status/ucode offsets +
        # report ucode residency before any SDMA write). Read-only; small hang risk if SDMA's clock is gated.
        [ -n "$SDMA_PROBE" ]         && echo '#define SDMA_PROBE'
        # SDMA_RING=1 — P9.1 SDMA0 GFX-ring bring-up: PSP-load SDMA ucode, un-halt the F32, program the ring
        # (regdump-anchored offsets), verify un-halt+idle. NO packet/kick. Needs /fw/sdma.bin on the agnos-fs.
        [ -n "$SDMA_RING" ]          && echo '#define SDMA_RING'
        # SDMA_COPY=1 — P9.2 first SDMA packet: one COPY_LINEAR (4KB carveout→carveout) + FENCE, kick via RB_WPTR,
        # gate on the fence sentinel, verify dst==src. Needs SDMA_RING too (the ring must be up).
        [ -n "$SDMA_COPY" ]          && echo '#define SDMA_COPY'
        # CP_DMA_COPY=1 — P9 (PIVOTED off SDMA): 2D copy via a PM4 DMA_DATA (CP-DMA) packet on the PROVEN
        # MEC compute ring (no SDMA/doorbell/firmware). 4KB carveout→carveout + WRITE_DATA done-marker,
        # register-wptr kick, verify dst==src. Gated on gpu_fence_ok (the compute ring's C2e coherence proof).
        [ -n "$CP_DMA_COPY" ]        && echo '#define CP_DMA_COPY'
        # SHADER_PROBE=1 — 1.56.x S1+D0: read-only compute-state + DCN MPC probes. No writes, no ring traffic;
        # S1's key check is COMPUTE_TMPRING_SIZE (stale scratch ring), D0's is a six-constraint base anchor.
        [ -n "$SHADER_PROBE" ]       && echo '#define SHADER_PROBE'
        # SHADER_BLEND=1 — 1.56.x S2: the first per-pixel alpha blend on the CUs (premultiplied f32).
        [ -n "$SHADER_BLEND" ]       && echo '#define SHADER_BLEND'
        # SHADER_RECT=1 — 1.56.x plan-S5 (grid > 1 workgroup) + the first half of plan-S7: that blend over a
        # 2-D grid, into the scanout back buffer, presented. (Released under the label "S3" at 1.56.1; the
        # plan's S3 is the four-arm coherence characterisation, which has NOT run. See the CHANGELOG erratum.)
        [ -n "$SHADER_RECT" ]        && echo '#define SHADER_RECT'
        # SHADER_COV=1 — 1.56.x plan-S10: coverage (anti-aliased) blend — uniform colour x 8bpp mask.
        # (Released under the label "S7" at 1.56.3.)
        [ -n "$SHADER_COV" ]         && echo '#define SHADER_COV'
        # SHADER_GLYPH=1 — 1.56.x plan-S9: 1bpp -> 32bpp glyph expansion (transparent background).
        # (Released under the label "S8" at 1.56.3.)
        [ -n "$SHADER_GLYPH" ]       && echo '#define SHADER_GLYPH'
        # SHADER_GRAD=1 — 1.56.x plan-S11: vertical linear gradient (no source buffer).
        # (Released under the label "S9" at 1.56.3.)
        [ -n "$SHADER_GRAD" ]        && echo '#define SHADER_GRAD'
        # SHADER_COHERE=1 — 1.56.x plan-S3: the four-arm GL2/scanout/CP-DMA coherence characterisation.
        # The ONLY build in which gpu_cohere_wb / gpu_cohere_inv are ever cleared, and then for exactly one
        # dispatch at a time through gpu_cohere_run, which restores both. Production is unaffected: both
        # default to 1 and decision D-6 keeps the pre-dispatch invalidate unconditional there.
        # Needs no other shader flag — it drives the RUNTIME arm (gpu_blend_arm), not a boot selftest.
        [ -n "$SHADER_COHERE" ]      && echo '#define SHADER_COHERE'
        # SHADER_PERM=1 — 1.56.x plan-S4: the v_perm_b32 byte crossbar (identity + RGBX<->BGRX channel
        # swap) and the VOP3P packed blend. ⚠ REQUIRES SHADER_BLEND — gpu_shader_blend_pk_test gates on
        # gpu_blend_ok because the f32 kernel is its oracle; without it the packed half silently skips.
        # Enforced in the dependency guard above, the same way SHADER_COV/SHADER_RECT are.
        [ -n "$SHADER_PERM" ]        && echo '#define SHADER_PERM'
        # SHADER_BATCH=1 — 1.56.x plan-S12: the one-submission batched frame, compared pixel-for-pixel
        # against the same frame composited op-by-op. Needs no other shader flag: it drives the RUNTIME
        # arms (gpu_*_arm), not the boot selftests.
        [ -n "$SHADER_BATCH" ]       && echo '#define SHADER_BATCH'
        # DCN_DLANE is RETIRED (2026-07-23). D1 (HUBPRET crossbar) + D2 (MPCC global alpha) closed after
        # five iron burns and the code is deleted — there is nothing left for the flag to compile. Do not
        # re-add it; if a future display bite needs the same primitives they are still in gpu.cyr
        # (gpu_otg_lock / gpu_dcn_write_committed).
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
        # ATOM_MATH_SELFTEST=1 — H6 (modeset arc): run the DIV32/MUL32 unit sweep against the
        # atom-interp.py oracle and print pass/fail. PURE ARITHMETIC — no MMIO, no VBIOS, no bytecode, no
        # PHY. Safe anywhere, needs no iron; QEMU is the intended venue. Requires HDMI_ATOM because the
        # helpers live inside that gate. Vectors regenerate with
        # `python3 agnosticos/scripts/atom-math-vectors.py`.
        # KLUG_SPILL_SELFTEST=1 — H1 (modeset arc): late in boot, write the klug ring to /klug.txt on
        # agnos-fs and print the byte count, so a smoke can mount the image from the host and byte-compare
        # the spill against the serial capture. The prepare half runs unconditionally at mount; this flag
        # only adds the test spill.
        [ -n "$KLUG_SPILL_SELFTEST" ] && echo '#define KLUG_SPILL_SELFTEST'
        # KLUG_SPILL_WRAPTEST=1 — H1 wrap exercise: force the ring past 64 KB, plant two ordered markers,
        # re-spill. Proves klug_spill()'s WRAPPED branch reorders to chronological. A normal boot never
        # wraps (QEMU ~2.5 KB, iron ~16-20 KB, ring 64 KB), so this branch is otherwise untested and its
        # failure mode is a silently ROTATED log. Implies KLUG_SPILL_SELFTEST.
        [ -n "$KLUG_SPILL_WRAPTEST" ] && echo '#define KLUG_SPILL_WRAPTEST'
        # MODESET_LATCH_SELFTEST=1 — H2: arm the latch and enter a SYNTHETIC risky step that wedges
        # (cli;hlt;jmp $), placed LATE per the S12 placement rule. Boot the SAME binary twice on the SAME
        # disk: boot 1 arms and wedges, boot 2 must find the latch and REFUSE. Boot 2 must be byte-identical
        # to boot 1, which is why the lane is one flag and not two.
        [ -n "$MODESET_LATCH_SELFTEST" ] && echo '#define MODESET_LATCH_SELFTEST'
        # MODESET_LATCH_DISARM=1 — H2 disarm lane: skip the wedge, then exercise modeset_latch_is_path
        # (positive AND negative) and modeset_disarm. Implies MODESET_LATCH_SELFTEST.
        [ -n "$MODESET_LATCH_DISARM" ] && echo '#define MODESET_LATCH_DISARM'
        [ -n "$ATOM_MATH_SELFTEST" ] && echo '#define ATOM_MATH_SELFTEST'
        # ATOM_INSTR_SELFTEST=1 — H4 (modeset arc): prove every abnormal interpreter exit is DISTINCT and
        # NON-ZERO, by executing four synthetic in-RAM command tables (clean EOT / reserved opcode /
        # out-of-range opcode / impossible header). No real VBIOS, no MMIO reachable, no PHY — safe
        # anywhere, QEMU is the venue. Requires HDMI_ATOM (the interpreter lives inside that gate).
        [ -n "$ATOM_INSTR_SELFTEST" ] && echo '#define ATOM_INSTR_SELFTEST'
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
