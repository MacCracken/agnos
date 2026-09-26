#!/bin/sh
# msc-cdb-smoke — the 16-byte SCSI CDB buffer at all seven msc.cyr builders, measured at run time (1.57.7).
#
# ⛔⛔ WHY THIS EXISTS. Until 1.57.7 every CDB builder in kernel/arch/x86_64/usb/msc.cyr declared
# `var cdb_buf[2]` — a function-local `var x[N]` is N BYTES, so that is ONE 8-byte frame slot — and then
# zeroed 16 bytes into it (a `while (k < 16)` loop through an alias, or msc_build_rw10_cdb). Bytes 8-15
# landed on the local declared just before cdb_buf. Measured under cycc 6.6.6 that victim was dead in all
# seven frames, which is the ONLY reason nothing broke; an `asm {}` in any of those bodies would have
# made INQUIRY DMA into phys 0 and READ(10) ask for count & 0xFF bytes. Nothing ran the question at all:
# the static gate could not see an alias, a loop bound or a callee, and no smoke looked at the frames.
#
# THE INSTRUMENT (MSC_CDB_CANARY, compiled out of production — control C below proves it): each builder
# declares an address-taken `cdb_canary` immediately before cdb_buf, i.e. in exactly the slot a
# too-small cdb_buf overflows into, and records whether it survived the CDB build. msc_cdb_canary_run
# (main.cyr, BSP, before the APs and the scheduler) drives all seven builders — TUR, INQUIRY, READ
# CAPACITY, REQUEST SENSE, READ(10), WRITE(10), SYNCHRONIZE CACHE — against a QEMU usb-storage stick and
# prints `msc-cdb: PASS sites=7 clobbered=0`. On the [2] code it prints `clobbered=7` (RED); on [16], 0.
# A WRITE(10)+SYNC+READ(10) round-trip at LBA 100 of the scratch stick is the control that the instrument
# does not break a transfer.
#
# BOOTS: the canary kernel at -smp 1 and -smp 4 (GATED — ${MSC_CDB_SMP:-1 4}), then boot P at the same SMP
# counts: an MSC_RW_DEMO + MSC_BOUNCE_SELFTEST kernel (no canary) that runs the FIXED PRODUCTION frames through
# READ(10) and a WRITE(10)/READ(10) round-trip, and then the [bounce] arm.
#
# ⛔ 1.57.9 [bounce] (issue 2026-09-25-msc-puts-the-caller-buffer-in-a-data-trb): msc_blk_read/_write/_read_sectors
# used to store the CALLER'S buffer pointer in the bulk data TRB — a CPU VA taken by the xHC as a PHYSICAL
# address. msc_bounce_selftest drives all three with kmalloc and direct-map buffers (rows A-C, each checked
# against the phys-taking reference primitive) plus a .bss control (row D, identity VA == phys, GREEN on the old
# code too, so a RED in A-C is the buffer class). A row passes only on err=0 AND bad=0; a FAIL line prints both.
# Measured on the pre-fix msc_blk_* (the key hunk reverted): see the 1.57.9 MSCBUF report. ⚠ The -smp 4 boot proves the same frames under a 4-CPU topology and boot
# path; the driver runs on the BSP before smp_start_aps, so it says nothing about concurrent MSC I/O.
#
# ⚠ Kernel lines on COM1 carry the klog prefix `[    s.uuuuuu] ` (kprint.cyr); `wantk` strips it before an
# exact-line match. `wantx`-style exact matching on the raw line is only for undecorated ring-3 lines, and
# this smoke has none.
#
# ⛔ 1.57.7 fix pass — FOUR WAYS THIS SMOKE COULD REPORT THE WRONG THING, EACH MEASURED BEFORE IT WAS FIXED:
#   · A HARNESS FAULT READ AS A FIRMWARE FLAKE. No image step was checked: with the kernel copy onto the ESP
#     failing, every boot burned 6 banner-gated tries and the run ended "VOID ... INFRASTRUCTURE, not the
#     kernel" (195 s, exit 2). Every step now fails fast as ERROR (exit 1), and the kernel copy and the
#     LBA-0 seed are read back before any boot.
#   · "-smp 4" NEVER CHECKED 4 CPUs. With QEMU forced to one CPU the -smp 4 variant scored 14/0 PASS
#     (`smp: cpus online: 1` in its log). The topology is the whole content of that variant; it is asserted.
#   · THE CANARY'S PLACEMENT WAS ONLY A COMMENT. A local inserted between `cdb_canary` and a regressed
#     `var cdb_buf[2]` took the overrun and the smoke printed PASS over a real 14-byte smash. The kernel
#     now records the gap per site (MISPLACED unless 8..24 bytes above cdb_buf) and C3 below checks the
#     source adjacency statically — see the msc.cyr instrument banner for the one residual the run-time
#     check cannot see and C3 does.
#   · THE LBA-0 ASSERTION WAS UNANCHORED. `LBA0 first 8 bytes:` is printed by nvme.cyr and ahci.cyr too, so
#     a bare substring match is satisfied by another driver's line (the spec's all-zero form matched the
#     NVMe boot disk's `nvme: ns1 LBA0 first 8 bytes: 0 0 0 0 0 0 0 0` on every boot, MSC line or not). It
#     is now an exact kernel-line match on the MSC emitter, `msc: slot N LBA0 first 8 bytes: ...`.
#
# Exit: 1 on any FAIL; else 2 if any boot was VOID (the firmware never handed off in 6 banner-gated
# tries — qemu-dwell.sh); else 0. sweep.sh still scores exit 2 as FAIL, by design (sweep.sh:83-85).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
GNOBOOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}/build/BOOTX64.EFI"
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd
# A missing prerequisite exits 1, never 0: "measured nothing" must not read as a green tick (1.56.55).
[ -f "$GNOBOOT" ]   || { echo "ERROR: gnoboot not built at $GNOBOOT — this gate measured NOTHING"; exit 1; }
[ -f "$OVMF_CODE" ] || { echo "ERROR: OVMF_CODE not found at $OVMF_CODE — this gate measured NOTHING"; exit 1; }
[ -f "$OVMF_VARS" ] || { echo "ERROR: OVMF_VARS not found at $OVMF_VARS — this gate measured NOTHING"; exit 1; }
for t in qemu-system-x86_64 parted mformat mmd mcopy strings; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: $t not installed — this gate measured NOTHING"; exit 1; }
done
LOGS="$ROOT/build/msc-cdb-logs"; rm -rf "$LOGS"; mkdir -p "$LOGS"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT INT TERM

pass=0; fail=0; void=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
klines() { strings "$1" | tr -d '\r' | sed -E 's/^\[ *[0-9]+\.[0-9]+\] //'; }   # strip the klog prefix
want()   { if strings "$LOG" | grep -qF -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
wantk()  { if klines "$LOG" | grep -qxF -- "$1"; then ok "$2"; else bad "$2 (no kernel line that is exactly: $1)"; fi; }
wantkre() { if klines "$LOG" | grep -qxE -- "$1"; then ok "$2"; else bad "$2 (no kernel line that is exactly: $1)"; fi; }
die()    { echo "ERROR: $1 — a harness fault, not the kernel; this gate measured NOTHING"; exit 1; }
deny()   { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

echo "=== MSC CDB canary smoke (16-byte CDB at all 7 SCSI builders; usb-storage on qemu-xhci) ==="

# ---- 1. builds (copies isolate every boot from the later builds; the last build leaves the tree plain)
echo "[build] MSC_CDB_CANARY=1, MSC_RW_DEMO=1 MSC_BOUNCE_SELFTEST=1, plain"
MSC_CDB_CANARY=1 sh "$ROOT/scripts/build.sh" > "$LOGS/build-canary.log" 2>&1 \
    || { echo "ERROR: MSC_CDB_CANARY build failed ($LOGS/build-canary.log) — this gate measured NOTHING"; exit 1; }
cp "$ROOT/build/agnos" "$WORK/agnos-canary"
MSC_RW_DEMO=1 MSC_BOUNCE_SELFTEST=1 sh "$ROOT/scripts/build.sh" > "$LOGS/build-rwdemo.log" 2>&1 \
    || { echo "ERROR: MSC_RW_DEMO+MSC_BOUNCE_SELFTEST build failed ($LOGS/build-rwdemo.log) — this gate measured NOTHING"; exit 1; }
cp "$ROOT/build/agnos" "$WORK/agnos-rwdemo"
sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 \
    || { echo "ERROR: plain build failed ($LOGS/build-plain.log) — this gate measured NOTHING"; exit 1; }

# ---- 2. C: static control — the probe can see the instrument, and production does not carry it
echo "[C] the instrument is present in the canary kernel and absent from production"
if strings "$WORK/agnos-canary" | grep -qF 'msc-cdb:' && strings "$WORK/agnos-canary" | grep -qF 'CDCANARY'; then
    ok "the canary kernel carries the instrument (msc-cdb: strings + the CDCANARY immediate) — the probe can see it"
else
    bad "the canary kernel does NOT carry the instrument — MSC_CDB_CANARY never reached the source, nothing below is measured"
fi
if strings "$ROOT/build/agnos" | grep -qE 'msc-cdb:|CDCANARY'; then
    bad "the PLAIN production kernel carries the canary instrument"
else
    ok "the canary instrument is compiled out of production"
fi
if strings "$WORK/agnos-rwdemo" | grep -qF 'msc-bounce:'; then
    ok "the boot-P kernel carries the [bounce] instrument (msc-bounce: strings) — the probe can see it"
else
    bad "the boot-P kernel does NOT carry the [bounce] instrument — MSC_BOUNCE_SELFTEST never reached the source"
fi
if strings "$ROOT/build/agnos" | grep -qF 'msc-bounce:'; then
    bad "the PLAIN production kernel carries the [bounce] instrument"
else
    ok "the [bounce] instrument is compiled out of production"
fi
# C3: the canary's placement in the SOURCE (A8). Each `var cdb_canary = ..;` must be followed by exactly its
# `#endif` and then the site's `var cdb_buf[..]` — nothing may be declared between them — and every note
# must hand the kernel cdb_p so it can measure the gap at run time.
MSCSRC="$ROOT/kernel/arch/x86_64/usb/msc.cyr"
adj=$(awk 'st==2 { if ($0 ~ /^[ \t]*var cdb_buf\[/) n++; st=0; next }
           st==1 { st = ($0 ~ /^[ \t]*#endif[ \t]*$/) ? 2 : 0; next }
           /^[ \t]*var cdb_canary = / { st=1 }
           END { print n+0 }' "$MSCSRC")
ncan=$(grep -c '^[[:space:]]*var cdb_canary = ' "$MSCSRC")
nbuf=$(grep -c '^[[:space:]]*var cdb_buf\[' "$MSCSRC")
nnote=$(grep -c 'msc_cdb_canary_note(&cdb_canary, cdb_p, ' "$MSCSRC")
if [ "$adj" = 7 ] && [ "$ncan" = 7 ] && [ "$nbuf" = 7 ] && [ "$nnote" = 7 ]; then
    ok "C3: all 7 canaries are declared immediately before their cdb_buf and every note passes cdb_p"
else
    bad "C3: canary placement in msc.cyr is not 7 x (canary, #endif, cdb_buf) + 7 notes with cdb_p (adjacent=$adj canaries=$ncan cdb_buf=$nbuf notes=$nnote) — the run-time canary may be watching the wrong slot"
fi

# ---- 3/4. one GPT image + fresh zero stick per boot, then the banner-gated dwell
boot() {   # $1 kernel copy, $2 smp, $3 label; sets LOG; returns 1 on VOID
    W="$WORK/$3"; mkdir -p "$W"
    IMG="$W/d.img"; USB="$W/usb.img"; LOG="$LOGS/$3.log"
    # The measured-working ESP recipe (msc-short-smoke, 1.56.51): 128 MB GPT, ESP 1..33 MiB, nvme bootindex=0
    # (OVMF otherwise offers the stick as a boot option and stops at the menu).
    dd if=/dev/zero of="$IMG" bs=1M count=128 status=none                              || die "[$3] image: dd of the 128 MB disk failed"
    parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on >/dev/null 2>&1 || die "[$3] image: parted failed"
    mformat -i "$IMG"@@1048576 -F                                                      || die "[$3] image: mformat of the ESP failed"
    mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot                                     || die "[$3] image: mmd failed"
    mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI                         || die "[$3] image: copying gnoboot onto the ESP failed"
    mcopy -i "$IMG"@@1048576 "$1" ::boot/agnos                                         || die "[$3] image: copying the kernel onto the ESP failed"
    mcopy -n -i "$IMG"@@1048576 ::boot/agnos "$W/agnos.readback" && cmp -s "$W/agnos.readback" "$1" \
        || die "[$3] image: the kernel read back from the ESP is not the kernel under test"
    rm -f "$W/agnos.readback"
    dd if=/dev/zero of="$USB" bs=1M count=8 status=none                                || die "[$3] stick: dd of the 8 MB stick failed"
    # ⛔ SEED LBA 0 WITH A KNOWN NON-ZERO PATTERN. On an all-zero stick `LBA0 first 8 bytes: 0 0 0 0 0 0 0 0`
    # is also what a READ(10) that moved NO data prints: the kernel zeroes the page first, and QEMU's
    # usb-storage pads a data phase the CDB did not ask for (measured 1.57.7 with the transfer-length byte
    # removed from msc_build_rw10_cdb — the zero assertion stayed green). "MSCLBA0!" = 77 83 67 76 66 65 48 33.
    printf 'MSCLBA0!' | dd of="$USB" bs=1 conv=notrunc status=none                   || die "[$3] stick: seeding LBA 0 failed"
    [ "$(head -c 8 "$USB")" = "MSCLBA0!" ] || die "[$3] stick: LBA 0 does not read back as the MSCLBA0! seed"
    ACC=$(smoke_accel "$2")
    [ "$2" -gt 1 ] && echo "  accel: $ACC"
    # shellcheck disable=SC2086
    qemu_dwell_kernel "$LOG" "agnos>" "${QEMU_TIMEOUT:-90}" "$W/vars.fd" "$OVMF_VARS" \
        qemu-system-x86_64 -machine q35 -m 512M $ACC -smp "$2" \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$W/vars.fd" \
        -drive "file=$IMG,format=raw,if=none,id=d0" \
        -device "nvme,drive=d0,serial=AGNOS-MSCC,bootindex=0" \
        -device qemu-xhci,id=xhci \
        -drive "file=$USB,format=raw,if=none,id=stick" \
        -device "usb-storage,bus=xhci.0,drive=stick" \
        -serial stdio -display none -no-reboot
    rm -f "$IMG" "$USB"
    if ! qemu_assert_booted "$LOG"; then echo "  VOID: [$3] the kernel never ran — no assertion scored"; void=1; return 1; fi
    return 0
}

for SMP in ${MSC_CDB_SMP:-1 4}; do
    echo "[smp$SMP] canary kernel, -smp $SMP — all seven builders must leave their canary intact"
    if boot "$WORK/agnos-canary" "$SMP" "canary-smp$SMP"; then
        want  "mass-storage device(s) detected"                   "[smp$SMP] the usb-storage stick enumerated (nothing below is measured without it)"
        wantk "msc-cdb: WRITE(10)+SYNC+READ(10) round-trip PASS"  "[smp$SMP] control: WRITE(10)+SYNC+READ(10) round-trip intact under the instrument"
        wantk "msc-cdb: PASS sites=7 clobbered=0"                  "[smp$SMP] all seven CDB builders ran and no canary was touched"
        wantk "msc-cdb: done"                                      "[smp$SMP] the canary driver completed"
        wantk "smp: cpus online: $SMP"                             "[smp$SMP] all $SMP CPU(s) came online (the topology this variant exists for)"
        deny  "msc-cdb: canary CLOBBERED"                          "[smp$SMP] no builder wrote past a 16-byte cdb_buf"
        deny  "msc-cdb: canary MISPLACED"                          "[smp$SMP] every canary sat 8..24 bytes above its cdb_buf (it watches the overrun slot)"
        deny  "msc-cdb: FAIL"                                      "[smp$SMP] no msc-cdb FAIL line"
        deny  "$SMOKE_INVARIANT_DENY"                              "[smp$SMP] no latched kernel invariant fired (whole boot)"
        klines "$LOG" | grep -E '^msc-cdb: (results|canary|PASS|FAIL)' | sed 's/^/        /'
    fi
done

for SMP in ${MSC_CDB_SMP:-1 4}; do
    echo "[prod-smp$SMP] MSC_RW_DEMO + MSC_BOUNCE_SELFTEST kernel (no canary), -smp $SMP — production frames move real data; msc_blk_* bounce"
    if boot "$WORK/agnos-rwdemo" "$SMP" "prod-smp$SMP"; then
        want  "mass-storage device(s) detected"              "[prod-smp$SMP] the usb-storage stick enumerated"
        wantkre "msc: slot [0-9]+ LBA0 first 8 bytes: 77 83 67 76 66 65 48 33" "[prod-smp$SMP] production READ(10) of LBA 0 returned the seeded bytes (the MSC line, not nvme/ahci's)"
        wantk "msc: LBA100 write-then-read round-trip PASS"  "[prod-smp$SMP] production WRITE(10) + READ(10) round-trip at LBA 100"
        wantk "msc-bounce: A kmalloc blk_read PASS"          "[bounce-smp$SMP] A: msc_blk_read into a kmalloc block (direct-map VA) returns the sector"
        wantk "msc-bounce: B direct-map blk_read_sectors(16) PASS" "[bounce-smp$SMP] B: msc_blk_read_sectors(16) into an unaligned direct-map buffer (2 bounce chunks)"
        wantk "msc-bounce: C direct-map blk_write(x8) PASS"  "[bounce-smp$SMP] C: msc_blk_write from an unaligned direct-map buffer lands on the stick"
        wantk "msc-bounce: D control .bss blk_write+blk_read PASS" "[bounce-smp$SMP] D: control — .bss buffers (identity VA == phys) still round-trip"
        wantk "msc-bounce: PASS rows=4"                      "[bounce-smp$SMP] all four rows passed"
        wantk "msc-bounce: done"                             "[bounce-smp$SMP] the [bounce] driver completed"
        wantk "smp: cpus online: $SMP"                       "[prod-smp$SMP] all $SMP CPU(s) came online"
        deny  "msc-bounce: FAIL"                             "[bounce-smp$SMP] no msc-bounce FAIL line"
        deny  "msc-cdb:"                                     "[prod-smp$SMP] the canary instrument is absent from this boot"
        deny  "$SMOKE_INVARIANT_DENY"                        "[prod-smp$SMP] no latched kernel invariant fired (whole boot)"
        klines "$LOG" | grep -E '^msc-bounce: ' | sed 's/^/        /'
    fi
done

echo "=== msc-cdb-smoke: $pass passed, $fail failed$( [ "$void" = 1 ] && echo ', VOID boot(s)') — logs in $LOGS ==="
if [ "$fail" -gt 0 ]; then echo "msc-cdb-smoke: FAIL"; exit 1; fi
if [ "$void" = 1 ]; then echo "msc-cdb-smoke: VOID"; exit 2; fi
echo "msc-cdb-smoke: PASS"
exit 0
