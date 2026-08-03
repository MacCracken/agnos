#!/bin/sh
# stage-tools.sh — build + stage the AGNOS-tic userland tools onto the agnos-fs
# rootfs as /bin/<name>, alongside agnsh (stage-agnsh.sh).
#
# These are the first sovereign userland tools that build + run NATIVELY on agnos
# (CYRIUS_TARGET_AGNOS). Today the in-kernel recovery shell's `run /bin/<name>`
# exec-from-disk path (1.40.x) runs them; agnsh execs them once 1.43.x execwait
# lands. Each staged binary MUST be a static x86_64 ELF64 — agnos exec-from-disk
# (elf_load_from_file) loads static ELF64 only.
#
# Usage:
#   scripts/burn/stage-tools.sh            stage the existing <repo>/build/<name>_agnos
#   scripts/burn/stage-tools.sh --build    rebuild each first (cyrius build --agnos)
#
# Tools live in sibling repos at $ROOT/../<repo> (override with SIBLINGS_ROOT).
set -u
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SIBLINGS="${SIBLINGS_ROOT:-$ROOT/..}"
DEST_DIR="$ROOT/build/rootfs/bin"
mkdir -p "$DEST_DIR"

BUILD=0
[ "${1:-}" = "--build" ] && BUILD=1

# Every destination name staged so far, space-delimited — the duplicate guard in
# stage_one reads it. See the guard for why this exists.
STAGED_NAMES=""

# Tool table: <repo> <src-entry> <name>. `name` matches the tool's cyrius.cyml
# [build] output; the agnos binary is staged at <repo>/build/<name>_agnos. Add a
# row here as each tool gains an agnos build. (mihi is a LIBRARY — no standalone
# binary; it is compiled INTO iam. chakshu/shu still pending an agnos build.)
#
# ⚠ The third field is the ROOTFS name and it must be UNIQUE across the whole
# table. It is NOT the source filename: three different repos build a
# `programs/gpumm.cyr` and they stage as three different binaries (gpumm /
# gputern / gpuattn), because what the operator types is `run /bin/<name>`.
stage_one() {
    repo="$1"; src="$2"; name="$3"
    # Two rows claiming the same /bin/<name> is a SILENT overwrite: both print
    # "staged:", both look green, and the image quietly holds whichever ran last.
    # That is how tentib's crown proof displaced the standalone gpumm probe from
    # the day the crown landed (2026-07-23) until this fix — filed as gpu.md
    # §finding 7 on 2026-07-28, fixed 1.56.32. The seam proof was simply not on
    # disk, so any "the seam still works" burn would have measured the wrong
    # binary. Fail on the SECOND row, before it can copy over the first.
    case " $STAGED_NAMES " in
        *" $name "*)
            echo "ERROR: '$name' is already staged — two rows claim $DEST_DIR/$name."
            echo "       The rootfs name (3rd field) must be unique; rename one row."
            return 1 ;;
    esac
    STAGED_NAMES="$STAGED_NAMES $name"
    rdir="$SIBLINGS/$repo"
    [ -d "$rdir" ] || { echo "ERROR: $repo not found at $rdir (set SIBLINGS_ROOT)"; return 1; }
    bin="$rdir/build/${name}_agnos"
    if [ "$BUILD" = "1" ]; then
        echo "Building $name (agnos target) in $repo ..."
        ( cd "$rdir" && cyrius build --agnos "$src" "build/${name}_agnos" ) \
            || { echo "ERROR: $name (agnos) build failed"; return 1; }
    fi
    [ -f "$bin" ] || { echo "ERROR: $bin not present — run with --build (or 'cyrius build --agnos $src build/${name}_agnos' in $repo)"; return 1; }
    DESC="$(file -b "$bin" 2>/dev/null)"
    case "$DESC" in
        *"ELF 64-bit"*"x86-64"*"statically linked"*) : ;;
        *) echo "ERROR: $bin is not a static x86-64 ELF64 ($DESC)"; return 1 ;;
    esac
    cp "$bin" "$DEST_DIR/$name"
    chmod +x "$DEST_DIR/$name"
    echo "staged: $DEST_DIR/$name ($(stat -c%s "$DEST_DIR/$name") bytes) <- $repo"
}

rc=0
stage_one bannermanor src/main.cyr bnrmr    || rc=1
stage_one commandress  src/main.cyr cmdrs    || rc=1
stage_one klug         src/main.cyr klug     || rc=1
stage_one anuenue      src/main.cyr anuenue  || rc=1
# 1.44.x userland coreutils delegation: agnsh 1.5.0 dropped its in-process file
# verbs and now delegates them to these two. kriya is the BusyBox-style coreutils
# dispatcher; owl is AGNOS's cat.
stage_one kriya        src/main.cyr kriya    || rc=1
stage_one owl          src/main.cyr owl      || rc=1

# 1.45.x network-tools family: the first net consumers of the ring-3 socket /
# UDP / ICMP syscalls (#45-#57, cyrius >= 6.2.5 net peer). dig = DNS resolver
# over udp_bind/send/recv/unbind (#51-54); yo = ICMP ping over icmp_echo (#55);
# whirl = curl+wget (HTTP over sock_connect/send/recv/close #47-50 + DNS via
# taar's udp path; HTTPS via tls_native composed over the sock transport with
# the time_unix#46 cert clock). All three share the taar substrate library.
stage_one dig          src/main.cyr dig      || rc=1
stage_one yo           src/main.cyr yo       || rc=1
stage_one whirl        src/main.cyr whirl    || rc=1

# System-info display: iam (fastfetch-equivalent) reads every fact through the
# mihi probe library (agnos sysinfo#35 / uname#34); mihi has no standalone binary
# — it is compiled into iam. Both agnos-verified at iam 1.1.2 / mihi 1.1.2
# (Distro: AGNOS, Memory via sysinfo#35; agnos scripts/tool/iam-agnos-verify.py).
stage_one iam          src/main.cyr iam      || rc=1

# Terminal display + editing: kii renders PNG → ANSI half-block art, sizing to the
# live console via darshana's tty_winsize over winsize#60; cyim is the modal editor.
# Both agnos-runtime-verified in QEMU (kii 1.0.3 / cyim 1.7.5 — `<tool> --version`
# loads, runs, exits cleanly off ext2). darshana / mihi / kavach are LIBRARIES
# (consumed by kii / iam — no standalone binary to stage).
#
# NOTE: chakshu/shu is deliberately NOT staged — its TUI is built on the Linux
# signalfd + epoll model (SIGWINCH resize), so it has no agnos build yet; agnos-
# native resize/signal handling is tracked as backlog in
# chakshu/docs/development/roadmap.md.
stage_one kii          src/main.cyr kii      || rc=1
stage_one cyim         src/main.cyr cyim     || rc=1

# GPU compute probe: gpumm is the first ring-3 consumer of the C2h GPU-compute
# seam (gpu_dispatch #82). It dispatches an 8x8 integer matmul onto the GPU shader
# cores from userspace and verifies C=A*B bit-for-bit vs a CPU reference —
# `run /bin/gpumm` prints "gpu: userspace matmul OK (64/64 bit-correct vs CPU)".
# The seam mabda/tentib consume for GPU inference. Runs only on real AMD iron
# (the GPU arc is not exercised under QEMU); harmless -1 on non-GPU boots.
stage_one gpumm        src/main.cyr gpumm    || rc=1
# tonegen is IN-TREE (agnos/tests/audio), not a sibling repo — hence the agnos/ prefix,
# which stage_one resolves through $SIBLINGS. It is the ring-3 end of the display-audio
# path: with HDA_HDMI=1 the kernel makes the GPU's HDMI controller the live sink, so
# this streams its tone out over HDMI with no device flag. Without it staged there is
# nothing in /bin to produce samples, and the armed audio path stays silent.
# ⛔ PATH FIXED 1.56.27 — this said `agnos/audio-test`, which HAS NOT EXISTED for some time;
# tonegen lives at `agnos/tests/audio/` (the same `tests/<family>` shape as `tests/gpu`), and
# `scripts/smoke/tonegen-smoke.sh` has been building it from there via `TG_ROOT="$ROOT/tests/audio"`
# the whole while. So the staging entry was resolving to a directory that does not exist, printing
# `ERROR: agnos/audio-test not found`, and making stage-tools.sh **exit 1 on every single run**.
# ⚠ THE COST OF THAT was not the missing binary — it was the exit code. A non-zero exit from staging
# is the one signal that says "a tool did not make it onto the fs", and it was firing unconditionally,
# so it carried no information and got read as background noise. Any tool that genuinely failed to
# stage would have looked exactly the same. Found 2026-07-28 while prepping the 1.56.26 burn, in the
# same pass that caught `gpuprof` never being staged at all — the two are the same failure with
# different symptoms.
stage_one agnos/tests/audio tonegen.cyr tonegen || rc=1

# GPU display/compositing proofs — the ring-3 ends of the 1.55.x/1.56.x band. IN-TREE
# (agnos/tests/gpu), same agnos/ prefix as tonegen. These were staged BY HAND for every burn
# through 1.56.3, which is why nothing in scripts/ referenced them; wired in at 1.56.4 so a
# burn cannot silently run yesterday's binary against today's kernel.
#
#   gpufill  — #85 whole-buffer CP-DMA fill + #84 present
#   gpublit  — #86/#87/#88/#89: a whole compositor frame, zero per-pixel CPU work
#   gpublend — #92 op 0x01, per-pixel alpha src-over through the SHADER cores
#   gpucov   — #92 op 0x02, 8bpp coverage mask (the anti-aliased edge CP-DMA cannot draw)
#   gpucopy  — #90 gpu_readback_shm + #91 gpu_blit_bb, verified by reading captured pixels BACK
#              to userland (#73) and comparing — a fully PROGRAMMATIC oracle (#90 fails silently)
#
# Each is SELF-VALIDATING and the result IS the exit code, read as `run: exit N` — 95 = all
# pass. gpublend/gpucov decode #92's packed failure as 110 + reason (111 no-GPU .. 123
# envelope-unproven), so a failed burn names WHY without needing a photo. gpucopy names its
# failure directly (70-73 readback, 81-84 blit_bb). Real AMD iron only; on a non-GPU boot they
# exit early rather than faulting (gpucopy: exit 100 = no GPU, informational).
stage_one agnos/tests/gpu gpufill.cyr  gpufill  || rc=1
stage_one agnos/tests/gpu gpublit.cyr  gpublit  || rc=1
stage_one agnos/tests/gpu gpublend.cyr gpublend || rc=1
stage_one agnos/tests/gpu gpucov.cyr   gpucov   || rc=1
stage_one agnos/tests/gpu gpucopy.cyr  gpucopy  || rc=1
# modeset — #93 gpu_modeset_op, the H3 modeset seam. `run /bin/modeset --caps` (or bare) prints the modeset
# surface caps and exits: 95 = display lit + seam live · 96 = seam live, no lit display (QEMU / dark port,
# informational) · 97 = #93 ABI error · 98 = latch BLOCKED this boot (recover: rm /.modeset-armed). The
# actual modeset (M-lane) is new op codes on this same #93, behind the H2 arm-once latch. Real AMD iron
# lights the panel; QEMU exercises the ABI + caps path (exit 96).
stage_one agnos/tests/gpu modeset.cyr  modeset  || rc=1
# gpuwedge — 3D arc rung 5: the GPU hang/recovery battery. `run /bin/gpuwedge --wedge` asks the
# kernel to hang its own GPU so rung 4's bracket can be proven to localise it and the R-2/R-3/R-4
# ladder proven to clear it. ⛔ The wedge arms are compiled out unless the kernel was built with
# GPU_RECOVER=1 — a production kernel refuses with exit 96 and says why. This tool NEVER acts
# without an explicit argument.
stage_one agnos/tests/gpu gpuwedge.cyr gpuwedge || rc=1

# gputri — 3D arc rung 9b: the edge rasteriser's oracle. `run /bin/gputri --cov` rasterises the
# 20-case corpus on the GPU and byte-diffs every mask against refraster.cyr, with negative
# controls N1-N8 that must all fire before it will report success.
# ⛔ IT WAS IN NEITHER THIS FILE NOR burn-prep UNTIL 9b B8, so a burn would have flashed a fresh
# kernel next to an absent or hand-copied binary. `run /bin/gputri --digest` FIRST: if its
# reference digests differ from the host `cpuref`'s, the tool is comparing against the wrong
# answer and nothing else it prints means anything.
stage_one agnos/tests/gpu gputri.cyr gputri || rc=1

# gputex — 3D arc rungs 13 AND 14. `run /bin/gputex` renders four frames in each of the two
# supported formats and byte-compares every rendered rect against texcore.cyr through #90. Its FIRST
# case is the absolute test: at 1:1 with integer UV the output must equal the SOURCE TEXTURE, an
# artifact the reference never produced.
# ⭐ 1.56.23 adds RUNG 14: the same 32 columns drawn as 32 individual op 0x0B dispatches and as ONE
# op 0x0C TEX_LIST dispatch, into the same cleared rect, demanded BYTE-IDENTICAL — plus the timing
# of both windows, which is the number that justifies the op existing. Exit 88 means op 0x0C drew a
# different picture; 95 means both rungs green.
stage_one agnos/tests/gpu gputex.cyr gputex || rc=1

# gpuprof — 1.56.26: DECOMPOSE `F`. Rung 14b's refit left 264 us of cost FIXED IN WAVE COUNT but
# measured only at 32 primitives, and the two surviving readings differ by 17x: per-PRIMITIVE
# (~7.4 us each => a 640-column DOOM frame carries ~4.7 ms of CPU that NO transpose removes) or
# per-DISPATCH (0.27 ms, irrelevant). `run /bin/gpuprof` issues op 0x0C at n=32 and n=256 and reads
# the kernel's own per-phase timings back through the 64-byte #89 tail (copyin / validate / build /
# wait), so the SLOPE of CPU cost against primitive count answers it directly.
# ⭐ It also prints OBSERVED vs PREDICTED wave counts. Every wave figure in this arc before 1.56.26
# was computed ring-3-side from a model of the kernel; gpu_prof_gx/_gy are captured inside
# gpu_blend_cov_run itself. A disagreement is a finding in its own right.
# EXIT: 95 = both points ran, verdict printed (READ THE TABLE, the code only says the run was valid)
#       96 = no GPU/carveout (QEMU's honest answer)  90 = every CPU phase read 0us => instrument or
#       TSC broken, NOT "instant"   89 = a #92 failed   88 = #86 slot failed   87 = kernel predates
#       the #89 profile tail.
stage_one agnos/tests/gpu gpuprof.cyr gpuprof || rc=1

# gpudepth — RUNG 17 (1.56.30): op 0x0D DEPTH_CLEAR on TD-3's render-target region.
# ⚠ Its oracle is TIME, not a byte-compare: the depth buffer is kernel-owned and ring 3 cannot read
# it, so a zero return code proves only that the syscall returned. It clears 800x600 and then a full
# 32 MB handle and demands the cost SCALE. Run it only AFTER `gpuwedge --rt-audit` passes — if the
# region is not proven free the worker refuses with GPO_E_ARM and nothing is written, by design.
stage_one agnos/tests/gpu gpudepth.cyr gpudepth || rc=1

# rupantara gpulayer — the ML-layer-on-GPU crown proof (1.54.x C6). A real bias-free MLP up-projection matmul
# (rosnet linear_fwd 8x8x32) run on the gfx90c shader cores via #83, tiled 8x8 and byte-compared against
# rupantara's CPU linear_fwd. Exit 95 = byte-identical AND all 4 tiles on the GPU (crown); 96 = identical but
# 0 GPU tiles (QEMU/host — tiling proven, no GPU); 90 = byte mismatch. Real AMD iron only.
stage_one rupantara programs/gpulayer.cyr gpulayer || rc=1

# tentib gputern — the SECOND ML-layer-on-GPU crown (1.54.x C6, INTEGER path). A real ternary BitLinear
# projection `ternary_matmul_free(qx,sx,Wq,γ,0,y,8,16,32)` run on the gfx90c shader cores via #82, tiled 8x8
# (K=16 = two k-tiles → exercises cross-tile i64 accumulation), signed (negative qx + ternary Wq), byte-
# compared against tentib's CPU ternary_matmul_free. Exit 95 = byte-identical AND all 8 tiles on the GPU
# (crown; bit-exact at ANY K — the integer advantage over the f64 #83 path); 96 = identical, 0 GPU tiles
# (host/QEMU); 90 = mismatch. Real AMD iron only.
#
# ⛔ STAGED AS `gputern`, NOT `gpumm` — renamed 1.56.32. tentib's source file is
# `programs/gpumm.cyr`, and this row used to carry that name straight through to the rootfs, where
# it collided with the standalone `gpumm` repo's probe two rows up (:97). This row runs LAST, so it
# won the copy and `/bin/gpumm` was tentib's 154,384 B crown while the 36,816 B seam probe never
# reached the image at all — both rows printing a green "staged:" line the whole time. The source
# FILENAME is incidental: attn11 builds a `programs/gpumm.cyr` too and has always staged it as
# `gpuattn`. Named for what it proves — the TERNARY integer path — matching gpulayer / gpuattn.
stage_one tentib programs/gpumm.cyr gputern || rc=1

# attn11 gpuattn — the THIRD ML-layer-on-GPU crown (1.54.x C6). attn11's OWN forward-projection hook
# `qlinear_fwd` (src/ops.cyr), wired to route a bias-free K≤8 projection to rupantara's linear_fwd_gpu (#83)
# on agnos. The proof runs a projection three ways (CPU linear_fwd / direct linear_fwd_gpu / qlinear_fwd hook)
# and byte-compares. Exit 95 = all identical AND all 4 tiles on the GPU (crown: attn11's hook ran on gfx90c);
# 96 = identical, 0 GPU tiles (host/QEMU); 90/91 = mismatch (direct/hook). Real AMD iron only.
stage_one attn11 programs/gpumm.cyr gpuattn || rc=1

# ⭐⭐ mine-cart — 1.56.32, THE CONSUMER CLOSE. Not an instrument: an APPLICATION. A ride through a
# curving mine tunnel, textured and perspective-correct, drawn entirely by #92 op 0x0F — the first
# thing outside the kernel's own test tree to draw with the 3D ops, and the reason the rung ladder
# was built. `run /bin/mine-cart` rides it; `run /bin/mine-cart --check` runs the same host gate the
# build already passed, on agnos, and needs no GPU (exit 95 = pass).
# ⛔ Its records are gated on the HOST before any flash: a single bad vertex makes #92 reject the
# WHOLE batch and the frame comes back as whatever was in the slot, which on iron is indistinguishable
# from "no GPU". `cyrius build src/main.cyr build/mine-cart && ./build/mine-cart --check` first.
stage_one cyrius-mine-cart src/main.cyr mine-cart || rc=1

# ⭐⭐ aethersafha — THE DESKTOP, and the first time any of it reaches an iron image.
# ⛔ Until this row, NO desktop binary appeared in this file at all. The sovereign compositor has
# composited on the GPU since aethersafha 0.9.6 — `#87 gpu_blit_shm` straight out of a client's
# GPU-visible `#86` slot, `#92` op 0x01 for premultiplied surfaces, `#39` DEFER for the chrome layer,
# one `#84` flip — and not one line of that has ever executed on silicon. QEMU cannot substitute and
# never could: it exposes no AMD PCI device, so `gpu_find` never matches, `gpu_caps` reports flags 0,
# `ae_gpu_probe` answers 0, and every GPU branch is dead for the whole run. A green desktop smoke
# proves the CPU fallback, which was never the part in doubt.
#
# `run /bin/aethersafha --selftest` is the SELF-VALIDATING form, same contract as the gpu* proofs
# above: it seeds a window's shared buffer with a four-band sentinel pattern, drives the REAL
# `ae_gpu_frame_plan` -> `render_desktop` -> `ae_gpu_present_frame` sequence the live desktop runs,
# captures the finished frame through `#90 gpu_readback_shm` BEFORE the `#84` flip, pulls it back to
# userland with `#73`, and compares. One process — no setu client, no `spawn_path`, no loopback TCP,
# no two-proc scheduling — so a non-95 exit points at the compositing path and nothing else.
# ⭐ AS OF 2026-08-03 THIS IS THE DESKTOP'S ONLY IRON ORACLE. The client-transport rows further down
# are retired (TCP-on-loopback is the wrong primitive — see the banner above `stage_one setu`), so
# `--selftest` is the whole of what a burn should read the desktop's verdict from.
#
# ⚠ THE CAPTURE MUST PRECEDE THE FLIP AND THE TOOL ENFORCES THAT INTERNALLY. `#84` toggles
# `gpu_bb_back`, so a readback taken after the present samples the buffer the frame did NOT draw
# into and returns the previous frame in full, with no error. On a static desktop that looks almost
# right — the worst failure an instrument can have.
#
# EXIT: 95 = the GPU composited the client surface at the client's coordinates, verified against
#            sentinels no compositor state can produce, with nothing leaked outside the window.
#       96 = no GPU / not armed / no carveout. QEMU's honest answer and NOT a pass — it means the
#            run proved nothing about hardware, which is what should be reported.
#       90 backend · 91 screen too small · 92/93 `#86` slot · 94 `#72` seed
#       80 the frame plan refused (admissibility, pre-syscall) · 81 the GPU declined and demoted
#       82 the capture hook never ran ⇒ the frame never reached the flip — upstream of the readback,
#          and hunting the GPU would be the wrong search · 83 `#90` rejected · 84 `#73` failed
#       70-73 band 1-4 wrong (shift / short copy / row order / stride)
#       74 sentinel found OUTSIDE the window · 75 sentinel found 300px away · 76 the capture buffer
#          was contaminated before the run, so nothing downstream of it means anything.
#
# ⚠ Bare `run /bin/aethersafha` (no flag) starts the REAL DESKTOP and never returns — it takes the
# screen and runs its frame loop until quit. That is the visual demo, not the oracle; read the
# verdict from `--selftest`.
# ⚠ ~15.5 MB, by far the largest staged binary. That is the full sigil link and is expected, not a
# regression — `run` (sh_exec) is proven on ELFs this size; `spawn_path` is the one that is not.
stage_one aethersafha  src/main.cyr aethersafha || rc=1

# ⛔⛔⛔ RETIRED TRANSPORT — DO NOT AIM A BURN AT THIS, AND DO NOT DIAGNOSE FROM IT. ⛔⛔⛔
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# Operator ruling 2026-08-03: TCP-on-loopback is the WRONG PRIMITIVE for local display IPC. The
# setu client transport below (connect back to 127.0.0.1:7700) is ARCHITECTURALLY RETIRED and is
# being removed; the replacement is the agnos socket — `naadi`, agnos docs/development/planning/
# ipc.md §9, with the removal inventory in §10.
#
# ⛔ THE DISCRIMINATION RUBRIC THAT USED TO LIVE HERE IS DELETED, NOT MOVED. It read "both present
# => client path and crab both work; probe only => the setu/two-proc path is fine and crab is the
# variable; neither => the fault is the client path itself". Following it on a burn sends the
# session hunting for a bug in a path that is being deleted. AN IRON BURN IS EXPENSIVE AND
# SERIALISING — a no-present here indicts the RETIRED TRANSPORT, not the client, not crab, not
# spawn_path, not the compositor. There is nothing to fix and nothing to learn. Do not schedule a
# burn for it, and if you get it as a side effect of some other burn, record it and move on.
#
# ⚠ CALIBRATION — the transport being retired is NOT the same claim as the transport never having
# worked, and the second claim is FALSE. scripts/harness/aethersafha-clients-test.py is an honest
# harness (it byte-scans build/agnos and hard-exits if the kernel carries a selftest hook, and it
# attaches a virtio NIC so DHCP yields a real net_ip); its 2026-08-02 "connected: 2, presented: 2"
# on 1.56.34+ is a REAL result and STANDS. Two setu clients did connect and did present. That is a
# true result about a path we are retiring on design grounds, not a false green. What was never
# established is the same thing on IRON — and it now never will be, because the path is going away.
#
# ⇒ THE DESKTOP'S IRON ORACLE IS `run /bin/aethersafha --selftest` (the block above), which is
# single-process and touches no network state at all. That is the one to burn.
#
# STAGING IS RETAINED ON PURPOSE, and staging is all this is now:
#   · burn-prep.sh's staleness gate (the `for _t in ... puka crab` loop, ~line 1174) hard-exits with
#     "STAGING GAP" if either is missing, so deleting these two rows would break every burn-prep run
#     rather than remove a hazard.
#   · `crab` is the real dhancha file manager (sadish raster + rekha text) and outlives the
#     transport — it is a naadi client the moment naadi lands. `puka` here is setu's slim
#     `present_probe` and IS a transport artifact; it stays only as the compositor's first-resident
#     slot filler until the naadi probe replaces it.
# Neither is a burn objective. Nothing below is an instruction to test anything.
#
# ⚠ `/bin/puka` is the FIRST-RESIDENT SLOT, not the puka terminal: full puka needs a mabda `--agnos`
# GPU backend that does not exist yet. The name is what the compositor spawns, so the slot keeps it.
# The two paths are both 9 characters, which is the length aethersafha passes to spawn_path.
#
# ⚠ SIZE IS LOAD-BEARING FOR `spawn_path`, unlike `run`/sh_exec — kept because it is a spawn_path
# fact, not a transport fact, and it will apply unchanged to naadi clients. spawn_path is proven on
# small children (these are 101 KB and 323 KB) and is NOT proven on large ones: a 2.5 MB jalwa
# spawned this way never ran, while 15 MB binaries exec fine through `run`.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
stage_one setu         programs/present_probe.cyr puka || rc=1
stage_one crab         src/main.cyr crab        || rc=1

# kriya dispatches on basename(argv[0]), so each delegated verb needs a
# /bin/<verb> NAME resolving to the kriya binary. Create them as RELATIVE
# symlinks (-> kriya) in the rootfs: install-media.sh's `cp -a` preserves them
# into the ext2 image, and the agnos ext2 open path follows the symlink inode to
# the dispatcher (so exec'ing /bin/cp loads kriya with argv[0]="/bin/cp"). These
# 11 are exactly the verbs agnsh 1.5.0 removed; `cat` is intentionally absent
# (owl is AGNOS's cat — agnsh nudges `cat` -> owl). The rest of kriya's surface
# (head/tail/sort/stat/ln/...) stays reachable via `kriya <applet>`; add more
# names here if they earn a bareword. NB `ln` would ENOSYS until symlink#43.
if [ -f "$DEST_DIR/kriya" ]; then
    for u in cp mv rm mkdir rmdir touch echo wc find grep ls; do
        ln -sf kriya "$DEST_DIR/$u"
    done
    echo "linked: $DEST_DIR/{cp,mv,rm,mkdir,rmdir,touch,echo,wc,find,grep,ls} -> kriya"
fi

# CA trust store for the verifying HTTPS clients (whirl). tls_native verifies the
# server chain fail-closed (CVE-18) against /etc/ssl/cert.pem on the agnos-fs —
# without it, every https:// handshake fails with no roots. Stage the host's
# bundle at the path tls_native probes first. (whirl 0.6.2's _agnos_ca_hook reads
# it with the correct agnos sys_open ABI — see the cyrius set-ca-system issue.)
CA_DEST="$ROOT/build/rootfs/etc/ssl/cert.pem"
for ca in /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/ca-bundle.pem; do
    if [ -f "$ca" ]; then
        mkdir -p "$(dirname "$CA_DEST")"
        # A previous run leaves cert.pem mode 0444 (read-only), which a plain `cp`
        # can't reopen for writing → "Permission denied". `cp -f` removes the
        # read-only dest first (the dir is writable, so no sudo needed); we then
        # chmod it 0644 so re-runs don't hit the same wall. Verify the result
        # instead of reporting "staged" unconditionally (the old `cp; echo` printed
        # success even when the cp failed, masking the error).
        if cp -fL "$ca" "$CA_DEST" 2>/dev/null && chmod 0644 "$CA_DEST" 2>/dev/null; then
            echo "staged: $CA_DEST ($(stat -c%s "$CA_DEST") bytes) <- $ca"
        else
            echo "ERROR: could not stage CA bundle $ca -> $CA_DEST"; rc=1
        fi
        break
    fi
done
[ -f "$CA_DEST" ] || echo "WARNING: no host CA bundle found — whirl HTTPS will fail (no trust roots on the agnos-fs)"
exit $rc
