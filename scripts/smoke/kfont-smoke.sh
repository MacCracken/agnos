#!/bin/sh
# kfont-smoke.sh — ring-3 proof of the kernel-embedded default TrueType face (1.57.2).
#
# Stages /bin/kfont (tests/kfont/, built --agnos) onto the agnos-fs ext2 root, boots
# gnoboot+OVMF+NVMe with a KFONT_RING3_SELFTEST kernel that runs `/bin/kfont` from disk, and
# asserts the /fonts namespace (core/kfont.cyr — rekha's Liberation Sans, kashi-style embed)
# works end to end FROM RING 3: open#7 by name, every one of the 410,820 bytes through read#5,
# FNV-1a-64 of what the client GOT == rekha's generator hash, a TrueType sfnt header with
# 'glyf'+'cmap' in the table directory, close#6, the read-only gate ONE PROBE PER MASK BIT
# (WRONLY/RDWR/CREAT/TRUNC/DIRECTORY), two non-names refused, stat#33 AND lstat#102 each filling
# st_mode 0100444 / st_nlink 1 / st_size 410820, and the provenance alias serving the same bytes.
# Exit 95.
#
# Gates: the kernel's own "kfont: /fonts/default.ttf 410820 bytes OK" (verify passed under the
#        kernel CR3), "exec: running /bin/kfont" (dispatched), "run: exit 95" (the contract),
#        "exec: kfont returned" (no hang/crash), no "run: exit 128+vector" (a ring-3 fault kill),
#        and no ring-0 PANIC line.
# Diagnostic exits: 80=open fail, 81=read err, 82=short total, 83=HASH MISMATCH (wrong bytes),
#        84=not sfnt 0x00010000, 85=glyf/cmap missing, 86=close!=0, 87=WRONLY accepted,
#        88=/fonts/nope.ttf accepted, 89=/fonts accepted, 90=stat#33 rc/mode/nlink/size wrong,
#        91=alias mismatch, 92=lstat#102 rc/mode/nlink/size wrong, 93=RDWR accepted,
#        94=CREAT accepted, 96=TRUNC accepted, 97=DIRECTORY accepted.
# VOID (exit 2, neither PASS nor FAIL) when the kernel banner never appeared: UEFI did not hand
# off, so nothing in the log describes the kernel under test.
#
# ⭐ MUTATION-PROVEN at 1.57.2 (all restored; see the exerciser header for the oracle argument):
#   (a) kfont_init treats verify as 1 AND store8(va + 100, 0xFF) right after the copy (against the
#       LOCAL va — kfont_va is assigned only after verify, so `kfont_va + 100` at that point is
#       VA 0x64, not the face). ⚠ 0xFF, NOT 0: byte 100 of Liberation Sans is 0x00, so storing 0
#       there is a no-op that hashes clean and scores 95 — this record said `0` until the 2026-09-13
#       review and was irreproducible as written. Pick a value that differs from the source byte.
#         -> "run: exit 83", FAIL: hash mismatch          (the length gate alone would not see it)
#   (b) kfont_open drops the (flags & 0xB03) refusal
#         -> "run: exit 87", FAIL: AO_WRONLY accepted
#   (c) kfont_open's mask shrunk to 0x1 (WRONLY only — the regression (b) alone could not see)
#         -> "run: exit 93", FAIL: AO_RDWR accepted
#   (d) kfont_stat stores 0x4000 (directory) at +0
#         -> "run: exit 90", FAIL: st_mode wrong          (size alone passed it before the review)
#   (e) the lstat#102 intercept line in core/syscall.cyr deleted
#         -> "run: exit 92", FAIL: lstat#102 failed
#   (f) the exerciser itself stores to 0xFFFFFFFF80000000 (a supervisor page) before step 1
#         -> "run: exit 142", FAIL: FAULT-KILLED (#PF)  — the 128+vector arm is live; the old
#            "#PF|#GP|#UD" grep printed PASS on this same log, see the note at the fault gate
#
# Requires: qemu-system-x86_64, OVMF, parted, mtools, sgdisk, mkfs.ext2, + cyrius (+ ../rekha
# or the REKHA_REF clone, which scripts/build.sh resolves).
set -u
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
KFONT_ROOT="$ROOT/tests/kfont"

OVMF_CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done
[ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ] && { echo "ERROR: OVMF not found"; exit 1; }
for tool in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings cyrius; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing tool '$tool'"; exit 1; }
done

echo "[1/4] Building kfont (--agnos) + the KFONT_RING3_SELFTEST kernel..."
( cd "$KFONT_ROOT" && CYRIUS_NO_WARN_PIN_DRIFT=1 cyrius build kfont.cyr build/kfont --agnos ) >/tmp/kfont-build.log 2>&1 || { echo "  BUILD-FAIL (kfont)"; tail -8 /tmp/kfont-build.log; exit 1; }
if ! env KFONT_RING3_SELFTEST=1 sh "$ROOT/scripts/build.sh" >/tmp/kfont-kbuild.log 2>&1; then
    echo "  BUILD-FAIL (kernel, see /tmp/kfont-kbuild.log)"; tail -8 /tmp/kfont-kbuild.log; exit 1
fi

GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
AGNOS="$ROOT/build/agnos"
KFONT="$KFONT_ROOT/build/kfont"
[ -f "$GNOBOOT" ] || { echo "ERROR: gnoboot not built at $GNOBOOT"; exit 1; }
[ -f "$KFONT" ]   || { echo "ERROR: kfont not built at $KFONT"; exit 1; }
echo "  build/agnos $(stat -c %s "$AGNOS") B   /bin/kfont $(stat -c %s "$KFONT") B"

WORK="$ROOT/build/kfont-smoke"; rm -rf "$WORK"; mkdir -p "$WORK"
IMG="$WORK/agnos-kfont.img"; SLOG="$WORK/serial.log"
PART_OFFSET=$(( 33 * 1048576 )); PART_BYTES=$(( 200 * 1048576 )); PART_BLOCKS=$(( PART_BYTES / 4096 ))
EXT2_FEATURES="^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg"

echo "[2/4] Seeding a GPT disk (parted) with /bin/kfont..."
SEED="$WORK/seed"; mkdir -p "$SEED/bin"; cp "$KFONT" "$SEED/bin/kfont"
dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on mkpart agnos-fs ext2 33MiB 240MiB
sgdisk -t 2:8300 "$IMG" >/dev/null
mformat -i "$IMG"@@1048576 -F
mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG"@@1048576 "$AGNOS" ::boot/agnos
mkfs.ext2 -F -q -L AGNOS-KFONT -b 4096 -m 0 -O "$EXT2_FEATURES" -d "$SEED" -E offset=$PART_OFFSET "$IMG" $PART_BLOCKS

echo "[3/4] Booting gnoboot+OVMF+NVMe, running /bin/kfont..."
KVM_ARGS=""; [ -e /dev/kvm ] && KVM_ARGS="-enable-kvm -cpu host"; [ -z "$KVM_ARGS" ] && KVM_ARGS="-cpu max"
HARD=60; [ -e /dev/kvm ] || HARD=120
# ⚠ qemu_dwell_kernel, NOT blk-ring3-smoke's bare background-and-poll loop: the very first run of
# this smoke landed on `gnoboot: fail @ EBS` (the ~1-in-4 firmware hand-off flake the helper's header
# measures) and would have scored an empty log. The helper retries ONLY while the kernel banner is
# absent, refreshes vars.fd per attempt, and waits for QEMU to exit before the log is read. The
# marker is the selftest's own last line, which is printed after everything asserted below.
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
qemu_dwell_kernel "$SLOG" "exec: kfont returned" "$HARD" "$WORK/vars.fd" "$OVMF_VARS_SRC" \
    qemu-system-x86_64 -machine q35 -m 512M $KVM_ARGS \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
    -drive "file=$IMG,format=raw,if=none,id=disk0" -device "nvme,drive=disk0,serial=AGNOS-KFONT" \
    -serial stdio -display none -no-reboot

echo "[4/4] Checks..."
# ⛔ NON-VACUITY FLOOR: did the kernel run at all? If the banner never appeared, UEFI did not hand
# off and nothing below describes the kernel under test. VOID is neither PASS nor FAIL — say so,
# and exit non-zero so a caller cannot score it green.
if ! strings "$SLOG" 2>/dev/null | grep -q "AGNOS kernel v"; then
    echo "  VOID: kernel banner never appeared — UEFI did not hand off; the kernel under test did not execute."
    echo "        Not a /fonts result. Log: $SLOG"
    echo ""
    echo "kfont-smoke: VOID (kernel never ran)"
    exit 2
fi
echo "  --- kfont serial lines ---"
strings "$SLOG" | grep -aE "kfont:|exec: (running )?/bin/kfont|exec: kfont|run: exit|PANIC|fault: pid=" | sed 's/^/  /' | head -12
rc=0
strings "$SLOG" | grep -q "kfont: /fonts/default.ttf 410820 bytes OK" \
    && echo "  PASS: kernel assembled + verified the face (kfont: /fonts/default.ttf 410820 bytes OK)" \
    || { echo "  FAIL: no 'kfont: ... 410820 bytes OK' boot line — the kernel did not expose the face (no 2 MB region, or verify FAILED)"; rc=1; }
strings "$SLOG" | grep -q "exec: running /bin/kfont" \
    && echo "  PASS: /bin/kfont dispatched (exec'd from disk in ring 3)" \
    || { echo "  FAIL: kfont never dispatched"; rc=1; }
if strings "$SLOG" | grep -q "run: exit 95"; then
    echo "  PASS: run: exit 95 — /fonts/default.ttf reachable from ring 3 end to end (open#7 → 410,820 B via read#5 → FNV-1a-64 == 0xbb32949696578ce6 → sfnt + glyf/cmap → close#6 → RO gate, all 5 mask bits → non-names refused → stat#33 + lstat#102 mode/nlink/size → alias same bytes)"
elif strings "$SLOG" | grep -q "run: exit 80"; then
    echo "  FAIL: run: exit 80 — open(\"/fonts/default.ttf\") failed (kfont_ready 0 / prefix intercept not reached)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 81"; then
    echo "  FAIL: run: exit 81 — read#5 returned an error on the memfile fd"; rc=1
elif strings "$SLOG" | grep -q "run: exit 82"; then
    echo "  FAIL: run: exit 82 — total bytes read != 410820 (memfile bounds / short-read contract)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 83"; then
    echo "  FAIL: run: exit 83 — HASH MISMATCH: the client got 410,820 bytes that are NOT the face (FNV-1a-64 != 0xbb32949696578ce6 — wrong region, unverified/corrupt copy, or a shifted literal)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 84"; then
    echo "  FAIL: run: exit 84 — sfntVersion != 0x00010000 (not a TrueType face)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 85"; then
    echo "  FAIL: run: exit 85 — 'glyf' or 'cmap' missing from the table directory"; rc=1
elif strings "$SLOG" | grep -q "run: exit 86"; then
    echo "  FAIL: run: exit 86 — close(fd) != 0"; rc=1
elif strings "$SLOG" | grep -q "run: exit 87"; then
    echo "  FAIL: run: exit 87 — READ-ONLY GATE BROKEN: open(\"/fonts/default.ttf\", AO_WRONLY=1) was accepted"; rc=1
elif strings "$SLOG" | grep -q "run: exit 88"; then
    echo "  FAIL: run: exit 88 — open(\"/fonts/nope.ttf\") was accepted (namespace is not exact)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 89"; then
    echo "  FAIL: run: exit 89 — open(\"/fonts\") was accepted (the bare prefix is not a name)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 90"; then
    echo "  FAIL: run: exit 90 — stat#33 failed, or the record is wrong: st_mode != 0x8124 (0100444), st_nlink != 1, or st_size != 410820"; rc=1
elif strings "$SLOG" | grep -q "run: exit 91"; then
    echo "  FAIL: run: exit 91 — /fonts/LiberationSans-Regular.ttf did not open, or its first 12 bytes differ from default.ttf's"; rc=1
elif strings "$SLOG" | grep -q "run: exit 92"; then
    echo "  FAIL: run: exit 92 — lstat#102 failed or disagrees with stat#33 (the #102 intercept in core/syscall.cyr is missing/misplaced, or its record is wrong)"; rc=1
elif strings "$SLOG" | grep -q "run: exit 93"; then
    echo "  FAIL: run: exit 93 — READ-ONLY GATE BROKEN: open(\"/fonts/default.ttf\", AO_RDWR=2) was accepted"; rc=1
elif strings "$SLOG" | grep -q "run: exit 94"; then
    echo "  FAIL: run: exit 94 — READ-ONLY GATE BROKEN: open(\"/fonts/default.ttf\", AO_CREAT=0x100) was accepted"; rc=1
elif strings "$SLOG" | grep -q "run: exit 96"; then
    echo "  FAIL: run: exit 96 — READ-ONLY GATE BROKEN: open(\"/fonts/default.ttf\", AO_TRUNC=0x200) was accepted"; rc=1
elif strings "$SLOG" | grep -q "run: exit 97"; then
    echo "  FAIL: run: exit 97 — READ-ONLY GATE BROKEN: open(\"/fonts/default.ttf\", AO_DIRECTORY=0x800) was accepted"; rc=1
elif strings "$SLOG" | grep -qE "run: exit 1(2[89]|3[0-9]|4[0-9])"; then
    echo "  FAIL: run: exit $(strings "$SLOG" | grep -oE "run: exit 1(2[89]|3[0-9]|4[0-9])" | head -1 | sed 's/run: exit //') — /bin/kfont was FAULT-KILLED (exit = 128 + vector: 142 = #PF, 141 = #GP, 134 = #UD, 128 = #DE); the fault record is in the klug ring, not on serial"; rc=1
else
    echo "  FAIL: no 'run: exit 95' — kfont crashed before exit (bad syscall wiring / unmapped-buffer fault) or was never exec'd"; rc=1
fi
strings "$SLOG" | grep -q "exec: kfont returned" \
    && echo "  PASS: exec: kfont returned (no hang)" \
    || { echo "  FAIL: 'exec: kfont returned' never printed — hang or crash inside the run"; rc=1; }
# ⚠ TWO fault signals, because the kernel emits NEITHER "#PF" NOR "#GP" on serial for a CPU exception
# (2026-09-13 review). A CPL3 fault in /bin/kfont takes idt.cyr's ring-3 branch into
# fault_kill_current, which records `fault: pid=...` ONLY via klug_append (a kernel-resident ring, never
# serial) and resumes the shell, whose only trace is `run: exit 128+vector` — caught by the elif arm
# above. A CPL0 fault (e.g. inside vfs_read's memfile memcpy) CMOS-stamps, paints the FB bar and
# cli;hlt's with NO serial write at all — caught by the missing 'run: exit 95' / 'exec: kfont
# returned' arms. The grep below therefore covers exactly one thing, the ring-0 stack-smash PANIC
# (syscall.cyr's `PANIC: stack smash detected`, the only serial literal in the tree it can match); it
# was labelled "no #PF/#GP/#UD/PANIC — the /fonts read-path is fault-free" until the review, which
# printed PASS on precisely the fault it claimed to cover.
strings "$SLOG" | grep -qE "PANIC|Double Fault" \
    && { echo "  FAIL: a ring-0 PANIC (stack smash) appeared in the log"; rc=1; } \
    || echo "  PASS: no ring-0 PANIC / stack-smash line (ring-3 fault kills are gated by the 'run: exit 128+vector' arm above)"

echo ""
[ "$rc" -eq 0 ] && echo "kfont-smoke: PASS — /fonts/default.ttf (rekha, kernel-embedded) is reachable and byte-exact from ring 3 (1.57.2)" || echo "kfont-smoke: FAIL"
exit $rc
