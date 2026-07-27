#!/bin/sh
# doom-directmap-smoke.sh — verify the AGNOS in-game 3D renderer WITHOUT keyboard.
#
# Builds the DOOM_SELFTEST kernel with DOOM_DIRECTMAP=1 so the boot runs
# `/bin/doom /DOOM1.WAD E1M1`; doom's direct_map path then skips menu_run() and
# renders E1M1 at spawn. The floor-band textured gate (in doom-smoke.sh) confirms
# the live 3D view. This is the keyboard-independent counterpart to
# doom-ingame-smoke.py — use it when you want to prove the wall/flat renderer on
# AGNOS without depending on QEMU sendkey cadence at all.
#
# Env passthrough: DOOM_RENDER_WAIT (title/scene render wait, default 10s).
exec env DOOM_DIRECTMAP=1 sh "$(dirname "$0")/doom-smoke.sh" "$@"
