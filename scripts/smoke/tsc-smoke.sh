#!/bin/bash
# tsc-smoke — the microsecond clock ring 3 can actually use: TSC calibration + uptime_us#95.
#
# WHAT IT PROVES. A TSC_SELFTEST kernel, booted under gnoboot + OVMF on q35 with an NVMe ext2 disk:
#   · the FADT PM timer is decoded (`acpi: pm timer port ...`, acpi.cyr) and tsc_calibrate measured
#     against it — the success line names its tier: `tsc: N cycles per microsecond (acpi-pm timer, ...)`;
#   · the live-tick tier, run separately by tsc_ticks_selftest, agrees with it within 2% — two
#     independent references cross-checking each other on every run (`ticks-tsc: within 2% OK`);
#   · the pure lost-tick / agreement predicates behave on synthetic windows (`pred-tsc:`, 5 arms), and the
#     lost-tick test is WIRED INTO the live window: one real tick window with a 25 ms IF=0 stall inside it
#     must come back rejected (`ticks-tsc: PASS a window with a 25 ms IF=0 stall was rejected ...`);
#   · ⭐ THE DIFFERENTIAL: a ring-3 probe (/bin/tscp) samples uptime_us#95 around a busy loop run with
#     INTERRUPTS DISABLED and exits 1 when the clock advanced — exactly where uptime_ms#40 is frozen.
#     `run: exit 0` is the failure that cost two iron burns on the rung-10 gate;
#   · gpu_tsc_per_us() / hda_tsc_per_us() report the calibrated value (accessor == calibration);
#   · the boot goes ON past the probe to the shell (see THE IF=0 HANG below);
#   · statically: the old, wrong refusal text (`uptime_us will report 0` — the arm returns -1) is gone
#     from the binary, and both corrected ones are present — the first attempt's (`one more attempt before
#     userland`) and the final one's (`uptime_us#95 returns -1 for the rest of this boot`).
#
# ⛔ 1.57.6 — WHY THE REFERENCE CHANGED (issue 2026-09-23 "tsc-calibration-refused-stops-the-us-clock").
# Through 1.57.5 the calibration counted TSC cycles over ONE window of 5 live ticks. Under a host CPU
# quota the vCPU's periodic ticks coalesce, so the window ran long and the value came out HIGH: daimon
# measured 8319 (true 3192, a 2.6x-slow #95) at CPUQuota=50% and a REFUSAL (#95 = -1 for the whole boot)
# at 25%. The ACPI PM timer needs no interrupt delivery; a throttle only lengthens its window.
#
# MODES / KNOBS
#   (default)          one boot, q35, KVM when /dev/kvm is usable, -smp 1.
#   TSC_QUOTA=<pct>    THE daimon REPRODUCTION. Boot A unthrottled, then boot B with QEMU inside
#                      `systemd-run --user --scope -p CPUQuota=<pct>%`. Requires systemd-run and a user
#                      manager with the cpu controller delegated — it FAILS, never skips, without them.
#                      ⛔ POSITIVE CONTROL: QEMU's own scope reads back its cgroup `cpu.max` before exec,
#                      and B must show `<pct*1000> 100000`. Without it, a quota the user manager accepted
#                      but never enforced would make B a second unthrottled boot that passes vacuously.
#                      B must calibrate on the acpi-pm tier within 2% of A and still give `run: exit 1`.
#                      In B the tick-oracle lines (gpu/hda arm D, ticks-tsc, the klog cross-check) are
#                      INFO: their ORACLE is the lossy tick, and disturbing it is the point.
#                      QEMU_TIMEOUT defaults to 900 here. Pair with DE_NO_KVM=1 for TCG, as reported.
#   TSC_SMP=<n>        -smp n (default 1) — the pre-userland retry runs after the APs are woken.
#   TSC_MACHINE=<m>    -machine m (default q35). `pc` (i440fx) exercises the FADT's LEGACY PM_TMR_BLK path.
#   DE_NO_KVM=1        force TCG (-cpu max).
# Exit: 0 all PASS · 1 any FAIL · 2 VOID (UEFI never handed off, so nothing below describes the kernel).
#
# ⛔ 1.57.6 — THE IF=0 HANG THIS SMOKE NEVER SAW. /bin/tscp is the boot body's only post-`sti` foreground
# `run` before `sched_active = 1` (MODESET_TOOL_SELFTEST's come after it) and the only one followed by an
# arch_wait(); it returned to kmain with IF=0 and that arch_wait() halted forever. The
# 1.57.5 log ENDED at `run: exit 1`, the old smoke still scored its checks green, and the dwell simply ran
# out. main.cyr now restores IF after the probe, and the "boot went ON" check below is what sees it.
# ⛔ AND ITS CALIBRATION EXTRACTION READ THE TIMESTAMP: the first 1.57.6 run of the unmodified 1.57.5
# kernel scored 5 passed, 2 failed — "calibration measured '7'" — on a healthy 3193.
#
# ⭐ MUTATION RECORD (1.57.6, each applied by hand to the named hunk, rebuilt, booted, restored byte-exact
# against a sha256 of main.cyr; KVM unless marked TCG):
#   healthy tree ........ 16 passed, 0 failed: `acpi: pm timer port 608, 24-bit`,
#                         `tsc: 3193 cycles per microsecond (acpi-pm timer, 5 of 5 windows agree)`,
#                         `ticks-tsc: 3193 ... vs 3193`, pred-tsc 5/5, `run: exit 1`, shell reached.
#                         TSC_MACHINE=pc: rev-1 116-byte FADT, `acpi: pm timer port b008` (legacy field),
#                         16/0. TSC_SMP=4: 16/0.
#   TSC_QUOTA=25 (TCG) .. 28/0, cpu.max `25000 100000`; A 3193, B 3193 (acpi-pm); B's tick tier:
#                         `REFUSED -- 0 of 6 windows usable; measured 12275..19163 cycles/us` (INFO).
#   TSC_QUOTA=50 (TCG) .. 28/0, cpu.max `50000 100000`; A 3193, B 3193; tick tier `measured 7898..11267`.
#   the 1.57.5 kernel, TSC_QUOTA=25 (TCG), QEMU_TIMEOUT=150 .. 12/16: THE daimon BUG REPRODUCED ON THIS
#                         HOST — A `tsc: 3193 ... (measured over 50 ms of live ticks)`, B `tsc: calibration
#                         REFUSED -- uptime_us will report 0` and `run: exit 0`; both logs END at `run: exit`.
#   (a) acpi_pm_tmr_port = 0 at the top of tsc_calibrate: `tsc: no ACPI PM timer -- calibrating against
#       live ticks`, `tsc: 3193 cycles per microsecond (live ticks, 3 of 3 windows agree)` -> ONLY the
#       acpi-pm-tier check RED (15/1): the tick tier stands alone and the check discriminates.
#   (a) + TSC_QUOTA=25 (TCG): boot B printed `tsc: live ticks REFUSED -- 0 of 6 windows usable; measured
#       10680..19109 cycles/us`, `tsc: calibration REFUSED -- uptime_us#95 returns -1 for the rest of this
#       boot`, `run: exit 0`, `tsc: second calibration attempt before userland`, a second refusal
#       (`measured 17959..18000`), and still reached the shell — the daimon 25% refusal, now printed.
#   (b) (a) + the usable band's top cut to 1000000 cycles/ms: the same REFUSED/retry sequence
#       deterministically (`measured 3193..3194`), `run: exit 0`, 8/8; at TSC_SMP=4 the retry ran with
#       `smp: cpus online: 4` and its tick tier read 3193 — BSP ticks only, APs awake.
#   (d) acpi_pm_tmr_port = 0x6F8 (undecoded): `tsc: ACPI PM timer at port 6f8 does not count -- ignored`
#       then the live-ticks tier (~0.6 s of dead-port reads under KVM). With the refusal text put back to
#       `uptime_us will report 0` in the same build, both static checks went RED too (13/3).
#   (e1) tsc_tick_uniform's 1.25x test deleted -> only `pred-tsc: FAIL 2x tick interval accepted`.
#   (e2) its burst test deleted            -> only `pred-tsc: FAIL tick burst accepted`.
#   (e3) median_agree's `agree < 3` deleted -> only `pred-tsc: FAIL split windows accepted`.
#   (e4) median_agree's sort skipped       -> only `pred-tsc: FAIL outlier moved the median ...`.
#   (f) the `asm { sti; }` after the probe deleted -> the log ENDS at `run: exit 1`; only the
#       "boot went ON" check RED (15/1), after the full 120 s dwell.
#
# Build first:  TSC_SELFTEST=1 sh scripts/build.sh
set -u

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"

OVMF_CODE_CANDIDATES="
    /usr/share/edk2/x64/OVMF_CODE.4m.fd
    /usr/share/edk2/x64/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE_4M.fd
"
OVMF_VARS_CANDIDATES="
    /usr/share/edk2/x64/OVMF_VARS.4m.fd
    /usr/share/edk2/x64/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS_4M.fd
"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }

for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$AGNOS" ]   || { echo "ERROR: agnos not built — run TSC_SELFTEST=1 ./scripts/build.sh"; exit 1; }
# ⛔ VERIFY THE FLAG LANDED, not merely that a build exists. A mode flag whose #define was never
# emitted ships a silent no-op. ⚠ NECESSARY BUT NOT SUFFICIENT — the string lives in the
# function body, so it appears as soon as the function COMPILES even if nothing CALLS it. That
# is exactly how the first run of this smoke passed the guard while the hook never ran (it was
# called ~450 lines too early, before ext2 was mounted). The log assertions are the real gate.
if ! strings "$AGNOS" | grep -q "tsc: ring-3 probe"; then
    echo "ERROR: kernel not built with TSC_SELFTEST=1 — rebuild:"
    echo "       TSC_SELFTEST=1 sh scripts/build.sh"
    exit 1
fi

QUOTA="${TSC_QUOTA:-}"
SMP="${TSC_SMP:-1}"
MACHINE="${TSC_MACHINE:-q35}"
if [ -n "$QUOTA" ]; then
    case "$QUOTA" in ''|*[!0-9]*) echo "ERROR: TSC_QUOTA must be a whole percentage (got '$QUOTA')"; exit 1 ;; esac
    command -v systemd-run >/dev/null 2>&1 || { echo "ERROR: TSC_QUOTA needs systemd-run -- not skipping silently"; exit 1; }
    DWELL="${QEMU_TIMEOUT:-900}"
else
    DWELL="${QEMU_TIMEOUT:-120}"
fi

KVM_ARGS="-enable-kvm -cpu host"
[ -n "${DE_NO_KVM:-}" ] && KVM_ARGS="-cpu max"
[ -e /dev/kvm ] || { echo "  (no /dev/kvm — falling back to TCG; the 16 MB load will be slow)"; KVM_ARGS="-cpu max"; }

WORK="$ROOT/build/tsc-smoke"
LOGS="$ROOT/build/tsc-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
# A failed firmware hand-off is terminal: end that attempt at once instead of burning the (900 s in
# quota mode) dwell, so qemu_dwell_kernel's banner-gated retry comes round in seconds. Neither string
# can appear once the kernel is running (OVMF is gone by then).
QEMU_DWELL_VOID="${QEMU_DWELL_VOID:-gnoboot: fail @ EBS|BootManagerMenuApp}"

pass=0; fail=0; info=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }
note() { echo "INFO: $1"; info=$((info+1)); }

# ---- static: the corrected refusal text (ask 3 of the issue) ------------------------------------------
# ⛔ The 1.57.5 line said "uptime_us will report 0" while the #95 arm returned -1. A consumer reading the
# log was told the wrong sentinel. Both halves are checked: the wrong text is gone AND the right text is in.
if strings "$AGNOS" | grep -q "uptime_us will report 0"; then
    bad "the binary still carries 'uptime_us will report 0' -- the #95 arm returns -1, not 0"
else
    ok "the wrong refusal text ('uptime_us will report 0') is gone from the binary"
fi
if strings "$AGNOS" | grep -q "uptime_us#95 returns -1 for the rest of this boot"; then
    ok "the corrected refusal text ('uptime_us#95 returns -1 for the rest of this boot') is in the binary"
else
    bad "the corrected refusal text is missing from the binary"
fi
# ⛔ And the FIRST attempt must not claim permanence: a retry follows it, and a retry that succeeds would
# print a calibration after a line that had already declared the clock gone for the boot.
if strings "$AGNOS" | grep -q "tsc: calibration REFUSED -- one more attempt before userland"; then
    ok "the first attempt's refusal text says a retry follows ('one more attempt before userland')"
else
    bad "the first attempt's refusal text ('one more attempt before userland') is missing from the binary"
fi

# boot_once <name> [prefix...] — build a fresh image (the TSC hook writes /bin/tscp into ext2, so every
# boot starts from a pristine disk) and boot it with the given command prefix (empty, or the quota scope).
boot_once() {
    _bn="$1"; shift
    _img="$WORK/agnos-tsc-$_bn.img"
    _seed="$WORK/seed-$_bn"
    rm -rf "$_seed"; mkdir -p "$_seed/bin" "$_seed/etc"
    printf 'archaemenid\n' > "$_seed/etc/hostname"
    PART_OFFSET=$(( 33 * 1048576 ))            # 33 MiB — ESP occupies 1..33 MiB
    PART_BYTES=$(( 95 * 1048576 ))             # 95 MiB ext2
    PART_BLOCKS=$(( PART_BYTES / 4096 ))
    EXT2_SMOKE_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"
    dd if=/dev/zero of="$_img" bs=1M count=160 status=none
    parted -s "$_img" mklabel gpt \
        mkpart ESP fat32 1MiB 33MiB set 1 esp on \
        mkpart agnos-fs ext2 33MiB 128MiB
    sgdisk -t 2:8300 "$_img" >/dev/null
    mformat -i "$_img"@@1048576 -F
    mmd -i "$_img"@@1048576 ::EFI ::EFI/BOOT ::boot
    mcopy -i "$_img"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
    mcopy -i "$_img"@@1048576 "$AGNOS" ::boot/agnos
    mkfs.ext2 -F -q -L AGNOS-ARK -b 4096 -m 0 \
        -O "$EXT2_SMOKE_FEATURES" \
        -d "$_seed" -E offset=$PART_OFFSET "$_img" $PART_BLOCKS
    echo "Booting TSC_SELFTEST kernel [$_bn] (-machine $MACHINE -smp $SMP $KVM_ARGS${QUOTA:+, boot $_bn}) ..."
    # ⚠ The marker is the emergency shell's prompt (no /bin/agnsh is seeded, so kybernet falls back to
    # it). Every assertion below is printed before kybernet runs, and reaching the prompt is itself a
    # check: the 1.57.5 boot never did (see the 1.57.6 note after tsc_selftest's `run /bin/tscp`, main.cyr).
    qemu_dwell_kernel "$LOGS/tsc-$_bn.log" "agnos>" "$DWELL" "$WORK/vars-$_bn.fd" "$OVMF_VARS_SRC" \
        "$@" qemu-system-x86_64 \
        -machine "$MACHINE" -m 1G -smp "$SMP" $KVM_ARGS \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK/vars-$_bn.fd" \
        -drive "file=$_img,format=raw,if=none,id=disk0" \
        -device "nvme,drive=disk0,serial=AGNOS-ARK" \
        -serial stdio -display none -no-reboot
}

# The log's klog timestamp prefix (`[    7.384833] `) is stripped before any NUMBER is extracted.
# ⛔ MEASURED 1.57.6: the 1.57.5 form ran `grep -oE "[0-9]+" | head -1` over the whole prefixed line and
# took the TIMESTAMP's seconds ("7") as the calibration, so both accessor gates below failed on a
# perfectly healthy 3193 — this smoke had not been run since the prefix landed (1.56.58) and nobody saw.
plain() { strings "$1" | sed -E 's/^\[[^]]*\] //'; }
cal_of() { plain "$1" | grep -oE '^tsc: [0-9]+ cycles per microsecond' | head -1 | grep -oE '[0-9]+'; }

# score_boot <log> <role>   role = plain | A | B (B = the throttled boot: tick-oracle lines are INFO)
score_boot() {
    _log="$1"; _role="$2"
    if ! qemu_assert_booted "$_log"; then
        echo "=== tsc-smoke: VOID [$_role] -- the kernel under test never ran ==="
        exit 2
    fi
    echo ""
    echo "  --- tsc lines from the [$_role] boot log ---"
    # ⛔ `[a-z-]*tsc:`, NOT `tsc:` — gpu-tsc:/hda-tsc:/ticks-tsc:/pred-tsc: carry a prefix, and a dump that
    # filters out the arm lines leaves a red gate with no evidence (it cost a fresh boot once already).
    plain "$_log" | grep -E "^[a-z-]*tsc:|^run: exit|^acpi: (pm timer|no pm timer)|^klog: (log timebase|TIMEBASE|NO LOG)|^Timer ticks before sched|^smp: cpus online|agnos>" | sed 's/^/  /'
    echo ""
    _cal=$(cal_of "$_log")
    _sfx=" [$_role]"

    if [ -n "$_cal" ]; then ok "the TSC calibrated: $_cal cycles per microsecond$_sfx"
    else bad "no calibration succeeded -- uptime_us#95 returns -1 for this whole boot$_sfx"; fi

    if plain "$_log" | grep -qE '^acpi: pm timer port [0-9a-f]+, (24|32)-bit'; then
        ok "the FADT PM timer was decoded ($(plain "$_log" | grep -oE '^acpi: pm timer port [0-9a-f]+, (24|32)-bit' | head -1))$_sfx"
    else bad "no 'acpi: pm timer port' line -- the FADT PM_TMR_BLK / X_PM_TMR_BLK decode found nothing$_sfx"; fi

    # ⭐ The tier IS the fix: a q35 / i440fx FADT advertises a PM timer, so a live-ticks calibration here
    # means the PM tier was never used, and the CPU-quota bias is back.
    if plain "$_log" | grep -qE '^tsc: [0-9]+ cycles per microsecond \(acpi-pm timer, [0-9]+ of [0-9]+ windows agree\)'; then
        ok "calibrated on the acpi-pm tier (the reference that needs no interrupt delivery)$_sfx"
    else bad "did NOT calibrate on the acpi-pm tier -- '(acpi-pm timer, ' is missing from the tsc: line$_sfx"; fi

    if plain "$_log" | grep -q "^tsc: second calibration attempt"; then
        bad "the pre-userland retry ran -- the first calibration refused on a machine with a PM timer$_sfx"
    else ok "the first calibration held (no pre-userland retry needed)$_sfx"; fi

    if plain "$_log" | grep -q "^tsc: ring-3 probe"; then ok "the ring-3 probe actually RAN (string present is not code called)$_sfx"
    else bad "the probe never ran -- check ext2_active and the call site, not the #define$_sfx"; fi

    # ⭐ THE DIFFERENTIAL. The probe exits 1 iff uptime_us#95 advanced across a busy loop run with
    # INTERRUPTS DISABLED. `run: exit 0` = the clock did not advance — what uptime_ms#40 does here.
    if plain "$_log" | grep -qE '^run: exit 1$'; then
        ok "⭐ uptime_us#95 ADVANCED with interrupts off ($(plain "$_log" | grep -oE '^run: exit [0-9]+' | tail -1))$_sfx"
    else
        bad "uptime_us#95 measured ZERO across the busy loop ($(plain "$_log" | grep -oE '^run: exit [0-9]+' | tail -1)) --"
        echo "      the clock does NOT advance with interrupts off, so it is no better than uptime_ms#40."
    fi

    # ⛔ 1.57.6 — THE BOOT MUST GO ON. Through 1.57.5 the probe returned to kmain with IF=0 and the next
    # arch_wait() halted forever: the log ENDED at `run: exit 1` and every check above still passed.
    if plain "$_log" | grep -q "^Timer ticks before sched" && strings "$_log" | grep -q "agnos>"; then
        ok "the boot went ON past the IF=0 probe to the shell (the retry point was reached)$_sfx"
    else bad "the boot STOPPED after the probe -- no 'Timer ticks before sched' / shell prompt (IF left 0?)$_sfx"; fi

    _p5=$(plain "$_log" | grep -c '^pred-tsc: PASS')
    if [ "$_p5" = 5 ] && ! plain "$_log" | grep -q '^pred-tsc: FAIL'; then
        ok "lost-tick + agreement predicates: 5/5 synthetic arms$_sfx"
    else bad "lost-tick / agreement predicates: $_p5/5 synthetic arms PASS -- see the pred-tsc: lines$_sfx"; fi

    # ⭐ THE WIRING, LIVE. The pred-tsc arms test the predicate alone, and an unthrottled window is uniform
    # whether or not tsc_tick_window tests it, so only this arm sees the call site. Strict in EVERY role:
    # it asserts a REJECTION, which a throttle can only make more likely.
    if plain "$_log" | grep -q "^ticks-tsc: PASS a window with a 25 ms IF=0 stall was rejected"; then
        ok "the lost-tick test is wired into the live tick window (a 25 ms IF=0 stall inside one is rejected)$_sfx"
    else bad "the live lost-tick arm did not pass ($(plain "$_log" | grep -E '^ticks-tsc: (PASS|FAIL|SKIP)' | head -1))$_sfx"; fi

    # Tick-oracle lines: strict unthrottled, INFO under the quota (their oracle is what the quota breaks).
    _tk=bad; [ "$_role" = B ] && _tk=note
    if plain "$_log" | grep -q "^ticks-tsc: within 2% OK"; then ok "the live-tick tier agrees with the calibration within 2%$_sfx"
    else $_tk "the live-tick tier did not agree within 2% ($(plain "$_log" | grep -E '^ticks-tsc:' | tail -1))$_sfx"; fi
    if plain "$_log" | grep -q "^klog: log timebase OK"; then ok "the early klog timebase agrees with the calibration$_sfx"
    else $_tk "the early klog timebase does not agree ($(plain "$_log" | grep -E '^klog:' | head -1))$_sfx"; fi
    if plain "$_log" | grep -q "^gpu-tsc: PASS"; then ok "gpu_tsc_per_us(): all 4 arms$_sfx"
    else $_tk "gpu_tsc_per_us() selftest did not pass -- see the gpu-tsc: lines (arm D is timed on ticks)$_sfx"; fi
    if plain "$_log" | grep -q "^hda-tsc: PASS"; then ok "hda_tsc_per_us(): all 4 arms$_sfx"
    else $_tk "hda_tsc_per_us() selftest did not pass -- see the hda-tsc: lines (arm D is timed on ticks)$_sfx"; fi

    # ⭐ THE ACCESSORS TRACK THE MEASURED CLOCK: each accessor's per_us must equal the calibration, compared
    # ACROSS LINES in the harness, independently of the kernel's own arm C. Each extraction is anchored to
    # its own line.
    for _t in gpu-tsc hda-tsc; do
        _got=$(plain "$_log" | grep -oE "^${_t}: [0-9]+/4 arms; per_us [0-9]+" | grep -oE "[0-9]+$" | head -1)
        if [ -n "$_cal" ] && [ -n "$_got" ] && [ "$_cal" = "$_got" ]; then
            ok "⭐ ${_t%-tsc} timing uses the CALIBRATED clock (accessor $_got == calibrated $_cal)$_sfx"
        else
            bad "${_t%-tsc} accessor reports '$_got' but calibration measured '$_cal' -- its timing paths do not track the clock$_sfx"
        fi
    done
}

if [ -z "$QUOTA" ]; then
    boot_once plain
    score_boot "$LOGS/tsc-plain.log" plain
else
    # Positive control, captured from INSIDE the scope QEMU runs in, just before exec.
    CPUMAX="$WORK/cpu.max-B"
    boot_once A
    score_boot "$LOGS/tsc-A.log" A
    CAL_A=$(cal_of "$LOGS/tsc-A.log")
    boot_once B systemd-run --user --scope --quiet -p "CPUQuota=${QUOTA}%" \
        sh -c 'cat "/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/cpu.max" > "$0" 2>&1; exec "$@"' "$CPUMAX"
    score_boot "$LOGS/tsc-B.log" B
    CAL_B=$(cal_of "$LOGS/tsc-B.log")
    echo ""
    _want="$(( QUOTA * 1000 )) 100000"
    _got=$(cat "$CPUMAX" 2>/dev/null)
    if [ "$_got" = "$_want" ]; then ok "⭐ positive control: QEMU's own scope had cpu.max '$_got' -- the quota was ENFORCED"
    else bad "positive control: QEMU's scope cpu.max is '$_got', want '$_want' -- the quota was NOT in force, boot B proves nothing"; fi
    if [ -n "$CAL_A" ] && [ -n "$CAL_B" ]; then
        _d=$(( CAL_B - CAL_A )); [ "$_d" -lt 0 ] && _d=$(( 0 - _d ))
        if [ $(( _d * 100 )) -le $(( CAL_A * 2 )) ]; then
            ok "⭐ throttled to ${QUOTA}%: $CAL_B vs unthrottled $CAL_A cycles/us -- within 2% (1.57.5: 8319 at 50%, REFUSED at 25%)"
        else
            bad "throttled to ${QUOTA}%: $CAL_B vs unthrottled $CAL_A cycles/us -- more than 2% apart"
        fi
    else
        bad "throttled comparison impossible -- a boot did not calibrate (A='$CAL_A' B='$CAL_B')"
    fi
    # INFO: was the OLD reference actually disturbed in B? (Evidence the throttle bit, not a gate.)
    if plain "$LOGS/tsc-B.log" | grep -q "^ticks-tsc: within 2% OK"; then
        note "the live-tick oracle was NOT disturbed in B (the cpu.max control above is the gate)"
    else
        note "the live-tick oracle WAS disturbed in B: $(plain "$LOGS/tsc-B.log" | grep -E '^(ticks-tsc|tsc: live ticks)' | tr '\n' ' ')"
    fi
fi

echo ""
[ "$fail" -eq 0 ] && { echo "=== tsc-smoke: $pass passed, 0 failed ($info info) ==="; exit 0; }
echo "=== tsc-smoke: $pass passed, $fail failed ($info info) ==="; exit 1
