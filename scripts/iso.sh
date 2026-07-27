#!/bin/sh
# iso.sh — RETIRED. AGNOS is not distributed as a GRUB ISO and has not been since gnoboot.
#
# ⛔ THIS SCRIPT IS DEAD FOR TWO INDEPENDENT REASONS, and it is kept as a refusal rather than
# deleted so that anyone who finds it referenced in an old CHANGELOG entry gets the reason instead
# of a missing file.
#
#   1. GRUB's multiboot2 path is DEAD on AGNOS — it cannot load the kernel under W^X.
#      gnoboot (the sovereign UEFI bootloader) replaces it. See the bootloader roadmap.
#   2. The AGNOS medium is a GPT disk with a FAT ESP carrying gnoboot — NOT ISO9660, not
#      grub-mkrescue, not xorriso. The sovereign image builder targets that layout.
#
# It also read `boot/grub/grub.cfg`, a directory that no longer exists: the boot/grub tree was
# removed during the 1.56.22 repo tidy. This script would fail at that `cp` regardless.
#
# ⚠ The real flashing path is `agnosticos/scripts/install-media.sh --update-all`, and the CI step
# that used to call this script was removed with it.
echo "iso.sh: RETIRED — AGNOS does not ship a GRUB ISO." >&2
echo "  GRUB multiboot2 cannot load the kernel under W^X; gnoboot replaced it." >&2
echo "  The medium is GPT + FAT ESP with gnoboot, not ISO9660." >&2
echo "  Flash with: sudo ./scripts/install-media.sh --update-all  (in agnosticos)" >&2
exit 2
