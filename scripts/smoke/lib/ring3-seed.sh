# ring3-seed.sh — sourced helper (1.57.6): boot a RING-3 TEST PROGRAM as /bin/agnsh on a kernel.
#
# ⭐ WHY THIS SHAPE. kybernet launches /bin/agnsh IF=1 and time-sliced (kernel/user/init.cyr), so a test
# program seeded there runs exactly where agnsh, daimon and every consumer run — and its `spawn_path`#43
# children are ordinary scheduled processes that run CONCURRENTLY with it. A foreground `run` from a
# kernel selftest hook (sh_exec) is IF=0 run-to-completion: a #43 child never runs while its parent
# lives, so anything about concurrent children (redirect consumption, pipe EOF, a child writing into a
# pipe its parent closed) cannot be tested that way at all. On a PLAIN kernel this needs no compile
# flag, so it tests the kernel as it ships.
# ⚠ The program MUST exit 0 at the end (a non-zero exit drops kybernet into the emergency shell) and
# print a DONE marker the caller dwells on.
#
# Usage (after setting ROOT and sourcing qemu-dwell.sh):
#   . "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
#   . "$ROOT/scripts/smoke/lib/ring3-seed.sh"
#   ring3_seed_init || exit 1                       # gnoboot + OVMF + tools; prints what is missing
#   ring3_seed_image IMG KERNEL SEEDDIR LABEL       # the 128 MB GPT image (ESP 1-33 MiB, ext2 33-100 MiB)
#   ring3_seed_boot  IMG LOG MARKER TIMEOUT WORKDIR [extra qemu args, e.g. -smp 4]
#       -> 0 the kernel booted (banner present; the caller's assertions are the verdict)
#       -> 2 VOID: the firmware never handed off in QEMU_TRIES attempts — NOT a kernel failure
#
# ⚠ The recipe is the one agnsh-smoke/fork-smoke proved: a 128 MB disk with the ESP at 1-33 MiB on NVMe
# is the only combination that hands off reliably on this host (virtio-blk does not boot here), and
# the ext2 features match what the kernel mounts. Env: R3_MEM (default 512M), QEMU_TRIES (default 6,
# via qemu_dwell_kernel), GNOBOOT_ROOT, R3_ACCEL (1.57.6 S3; default `-cpu max` = TCG, unchanged — pass
# "$(smoke_accel 4)" for a multi-CPU boot that must really run in parallel, and print it).
# ⚠ Build the kernel BEFORE calling ring3_seed_image and hand it the path you mean: the image copies
# KERNEL at call time (fork-smoke measured a gate booting the previous command's kernel when the build
# ran after the mcopy).

ring3_seed_init() {
    R3_GNOBOOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}/build/BOOTX64.EFI"
    R3_OVMF_CODE=""
    for _r3c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$_r3c" ] && { R3_OVMF_CODE="$_r3c"; break; }
    done
    R3_OVMF_VARS=""
    for _r3c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do
        [ -f "$_r3c" ] && { R3_OVMF_VARS="$_r3c"; break; }
    done
    # ⛔ A MISSING PREREQUISITE IS NOT A PASS (the 1.56.55 doctrine): say so and return 1.
    if [ -z "$R3_OVMF_CODE" ] || [ -z "$R3_OVMF_VARS" ]; then echo "  ERROR: OVMF not found — this gate measured NOTHING"; return 1; fi
    [ -f "$R3_GNOBOOT" ] || { echo "  ERROR: gnoboot not built at $R3_GNOBOOT — this gate measured NOTHING"; return 1; }
    for _r3t in qemu-system-x86_64 parted mformat mmd mcopy sgdisk mkfs.ext2 dd strings; do
        command -v "$_r3t" >/dev/null 2>&1 || { echo "  ERROR: missing tool '$_r3t' — this gate measured NOTHING"; return 1; }
    done
    return 0
}

ring3_seed_image() {
    _r3_img="$1"; _r3_kernel="$2"; _r3_seed="$3"; _r3_label="${4:-AGNOS-R3}"
    [ -f "$_r3_kernel" ] || { echo "  ERROR: kernel $_r3_kernel not found"; return 1; }
    rm -f "$_r3_img"
    dd if=/dev/zero of="$_r3_img" bs=1M count=128 status=none || return 1
    parted -s "$_r3_img" mklabel gpt \
        mkpart ESP fat32 1MiB 33MiB set 1 esp on \
        mkpart agnos-fs ext2 33MiB 100MiB || return 1
    sgdisk -t 2:8300 "$_r3_img" >/dev/null || return 1
    mformat -i "$_r3_img"@@1048576 -F || return 1
    mmd -i "$_r3_img"@@1048576 ::EFI ::EFI/BOOT ::boot || return 1
    mcopy -i "$_r3_img"@@1048576 "$R3_GNOBOOT" ::EFI/BOOT/BOOTX64.EFI || return 1
    mcopy -i "$_r3_img"@@1048576 "$_r3_kernel" ::boot/agnos || return 1
    mkfs.ext2 -F -q -L "$_r3_label" -b 4096 -m 0 \
        -O "${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}" \
        -d "$_r3_seed" -E offset=$(( 33 * 1048576 )) "$_r3_img" $(( 67 * 1048576 / 4096 )) || return 1
    return 0
}

ring3_seed_boot() {
    _r3_img="$1"; _r3_log="$2"; _r3_marker="$3"; _r3_max="$4"; _r3_work="$5"; shift 5
    # ⚠ A FAILED FIRMWARE HAND-OFF IS TERMINAL (the OVMF boot menu), so without this each one burned the
    # whole dwell before the banner-gated retry — measured: 300 s per void attempt on the first
    # spawn-smoke runs. QEMU_DWELL_VOID (qemu-dwell.sh, opt-in) ends the wait as soon as the menu shows.
    # Every pattern here can only appear when the kernel did NOT start, and the retry stays banner-gated.
    QEMU_DWELL_VOID="${QEMU_DWELL_VOID:-gnoboot: fail @ EBS|BootManagerMenuApp|Please select boot device}"
    export QEMU_DWELL_VOID
    qemu_dwell_kernel "$_r3_log" "$_r3_marker" "$_r3_max" "$_r3_work/vars.fd" "$R3_OVMF_VARS" \
        qemu-system-x86_64 -machine q35 -m "${R3_MEM:-512M}" ${R3_ACCEL:--cpu max} "$@" \
        -drive "if=pflash,format=raw,readonly=on,file=$R3_OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$_r3_work/vars.fd" \
        -drive "file=$_r3_img,format=raw,if=none,id=disk0" \
        -device "nvme,drive=disk0,serial=AGNOS-R3" \
        -serial stdio -display none -no-reboot
    qemu_assert_booted "$_r3_log" || return 2
    return 0
}
