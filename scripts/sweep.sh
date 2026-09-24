#!/bin/bash
# Arc sweep — one command that rebuilds + runs every QEMU self-test smoke for
# the two most recent arcs (1.39.x VFS generic-write lift, 1.40.x exec-from-disk)
# plus the baseline gates and the ext2-write regression bar. Each smoke needs a
# DIFFERENT compile-gated kernel (its *_SELFTEST flag), so this script builds the
# right kernel per smoke, runs it, tallies PASS/FAIL, and restores the plain
# production build at the end.
#
# Usage:  sh scripts/sweep.sh
# Exit 0 iff every gate passes. Per-smoke logs under build/<smoke>-logs/.
#
# This is the automated half of the last-two-arcs verification; the MANUAL
# (on-iron) half is the rubric in
#   agnosticos/docs/development/iron-nuc-zen-log.md#tracker-139-cycle  (VFS)
#   agnosticos/docs/development/exec-iron-manual-tests.md              (exec)

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

pass=0; fail=0; results=""

# run_gate "<label>" "<build env>" "<smoke script | CHECK>"
# Each smoke runs ONCE per attempt (captured to a log); a single retry covers
# transient host-load / QEMU-timing flakes (a real failure fails both attempts).
run_gate() {
    label="$1"; buildenv="$2"; smoke="$3"
    printf '\n=== %s ===\n' "$label"
    ok=0
    if [ "$smoke" = "CHECK" ]; then
        if sh "$ROOT/scripts/check.sh" > "/tmp/sweep-gate.log" 2>&1; then ok=1; tail -1 /tmp/sweep-gate.log; else tail -3 /tmp/sweep-gate.log; fi
    else
        # ⛔ MEASURED 2026-08-28 (1.56.51): A FAILED BUILD USED TO BE PRINTED AND THEN IGNORED.
        # The old form was `… || { echo "  BUILD FAILED"; }` — the `||` consumed the status, `ok`
        # was untouched, and the loop below went on to run the smoke against WHATEVER build/agnos
        # was left on disk from a previous gate. A gate whose build failed could therefore still be
        # recorded PASS, on a binary built with a DIFFERENT $buildenv than the one it is testing.
        # Every gate here exists to test one specific compile-gated configuration; running the
        # previous gate's kernel is not a degraded test, it is a different test wearing this one's
        # name. A build failure is now the gate's verdict.
        if ! env $buildenv sh "$ROOT/scripts/build.sh" >/dev/null 2>&1; then
            echo "  BUILD FAILED ($buildenv) — gate not run"
            fail=$((fail+1)); results="$results\n  FAIL  $label (build)"
            return
        fi
        for attempt in 1 2; do
            # ⚠ smokes live in scripts/smoke/ since the 1.56.22 split. The gate table below still
            # names them bare (that is the readable form), so resolve here rather than editing 30
            # table rows — and fall back to the old flat location so a not-yet-moved smoke still runs.
            SMOKE_PATH="$ROOT/scripts/smoke/$smoke"
            [ -f "$SMOKE_PATH" ] || SMOKE_PATH="$ROOT/scripts/$smoke"
            # ⛔⛔ MEASURED 2026-08-28 (1.56.51): THE OLD DETECTOR RECORDED TOTAL FAILURE AS PASS.
            # It was `grep -qiE "smoke.*PASS|smoke \(.*\): PASS"`. The `-i` makes the literal PASS
            # match the substring "pass" inside the word "passed" — so a smoke whose FAILURE verdict
            # reads `=== fp-nm-smoke: 0 passed, 7 failed ===` satisfies `smoke.*pass` and was scored
            # a PASS. Fed the real runtime strings, the old pattern says PASS to all of these:
            #     === fp-area-smoke: 3 passed, 5 failed ===
            #     === fp-nm-smoke: 0 passed, 7 failed ===
            #     === fp-ctxsw-smoke: 1 passed, 2 failed ===
            #     === fp-selftest-smoke: 4 passed, 9 failed ===
            # Those are FOUR of the twelve gates this sweep runs. A "15/15" or "16/16" from the old
            # sweep did not mean what it said for any smoke reporting in the "N passed, M failed"
            # form — it meant only that the smoke reached its verdict line at all.
            # ⭐ AND THE CORRECT ORACLE WAS ALREADY THERE, BEING THROWN AWAY: every one of these
            # smokes exits 0 on success and 1 on failure (`[ "$fail" -eq 0 ] && { …; exit 0; }; …;
            # exit 1`). The status is now primary. The log grep is kept only as a SECOND, narrow
            # assertion against the exact trap above — a smoke that exits 0 while printing
            # "N passed, M failed" with M>0 is itself broken, and must not be scored a pass.
            sh "$SMOKE_PATH" > "/tmp/sweep-gate.log" 2>&1 && smoke_rc=0 || smoke_rc=$?
            if [ "$smoke_rc" = 0 ] \
               && ! grep -qE 'passed, [1-9][0-9]* failed' "/tmp/sweep-gate.log"; then
                ok=1; break
            fi
        done
        # ⛔ MEASURED 2026-08-29 (1.56.52): THIS FILTER HID THE ONE LINE THAT LOCALISES A FAILURE.
        # It was `grep -iE "PASS:|FAIL:|smoke:"`, and several smokes report a LAUNCH failure with a
        # line that matches none of those — `ERROR: QEMU produced NO boot output (0-byte log) —
        # launch failure, not an exFAT result.` is the exact wording in exfat-write-smoke.sh. So the
        # gate printed a completely EMPTY section and then scored FAIL, and the sweep transcript told
        # the operator only that something went wrong, with no way to tell a kernel regression from a
        # firmware hand-off that never happened. That distinction is the subject of its own state.md
        # heading ("A QEMU BOOT THAT NEVER HAPPENS READS AS A KERNEL FAILURE"), and this filter was
        # quietly erasing the evidence for it. ⚠ SCORING IS UNCHANGED — a launch failure is still a
        # FAIL here, deliberately: downgrading it to VOID inside run_gate would give every real
        # failure a way to hide. The fix is to make the diagnostic VISIBLE, not to forgive it.
        grep -iE "PASS:|FAIL:|smoke:|ERROR|SKIP|VOID|handed off" "/tmp/sweep-gate.log" | sed 's/^/  /' || true
        [ "$ok" = 1 ] && [ "${attempt:-1}" = 2 ] && echo "  (passed on retry — transient host-load timing)"
    fi
    if [ "$ok" = 1 ]; then pass=$((pass+1)); results="$results\n  PASS  $label";
    else fail=$((fail+1)); results="$results\n  FAIL  $label"; fi
}

echo "=========================================="
echo " AGNOS arc sweep — 1.39.x VFS + 1.40.x exec"
echo "=========================================="

# --- Baseline (plain production build): build + tests + version + size ---
sh "$ROOT/scripts/build.sh" >/dev/null 2>&1
run_gate "baseline check.sh (build/test/version/size)" "" "CHECK"

# --- 1.39.x VFS generic-write lift: FAT + exFAT read & write verb smokes ---
run_gate "1.39.x FAT read (cat/ls reach FAT)"       "FATFS_SELFTEST=1"                         "fat-smoke.sh"
run_gate "1.39.x FAT write (touch/echo/rm/mkdir/mv + subdir)" "FATFS_WRITE_SELFTEST=1 FAT_ALLOW_ESP_WRITE=1" "fat-write-smoke.sh"
run_gate "1.39.x exFAT read"                         "EXFAT_SELFTEST=1"                         "exfat-smoke.sh"
# 1.57.2 — the ONLY gate that presents a MULTI-NODE FAT chain cycle (A -> B -> A, both in range):
# fat-smoke / exfat-smoke prove GOOD chains read, and nothing else in the tree ever hands the kernel
# a chain that never ends. One kernel carries both selftests and one disk carries both cycles (a
# cyclic FAT32 subdir on the ESP + a cyclic exFAT root on p2); the smoke aborts before booting unless
# fsck.fat AND fsck.exfat see the cycles, and it exits 2 (VOID) when the kernel never ran. Mutation-
# proven: it goes RED with either predicate stubbed (see the smoke header for the exact lines).
# ⚠ ~45 s to PASS (the FAT32 budget is 129k fetches of uncached NVMe reads under TCG); a kernel that
# hangs burns the full 180 s dwell, twice, because run_gate retries — that is the RED path, not slack.
run_gate "1.57.2 FAT/exFAT chain-cycle budget"       "FATFS_SELFTEST=1 EXFAT_SELFTEST=1"         "fat-cycle-smoke.sh"
# 1.56.52 — the tree's FIRST usb-storage coverage. The MSC transport had none: no QEMU invocation
# anywhere under scripts/ attached one, so every gate passed regardless of what msc.cyr did. This
# smoke builds BOTH arms itself (injected + plain), so it needs no buildenv from here.
run_gate "1.56.52 MSC short data phase (usb-storage)" ""                                         "msc-short-smoke.sh"
# 1.56.52 — the first coverage of receive-side checksum verification. The other net gates only prove
# GOOD frames pass; this one presents a corrupt frame, which nothing else in the tree does.
run_gate "1.56.52 RX checksum verify (accept + drop)"  ""                                         "net-csum-smoke.sh"
# 1.56.52 — a HID Transfer Event eaten by an xHCI synchronous waiter must be handed back to the ring
# that owned it. Hermetic; no USB hardware required, though the smoke boots a usb-kbd anyway so the
# swapped-globals teardown is exercised against a non-empty endpoint registry.
run_gate "1.56.52 stolen HID event reclaim"            ""                                         "hid-reclaim-smoke.sh"
# 1.56.52 — a "user pointer" must mean a page the CALLER OWNS, not merely a low address. The low
# window is full of supervisor identity mappings of kernel memory; see the smoke header.
run_gate "1.56.52 user-pointer window (owned, not low)" ""                                         "userwin-smoke.sh"
# 1.56.52 — a DHCP option shorter than its reader is a remote ring-0 stack read. Hermetic: the helper
# is a pure function over a blob, which is the only way to test an attack needing a hostile server.
run_gate "1.56.52 DHCP option length vs reader"        ""                                         "dhcp-opt-smoke.sh"
# 1.56.55 — fork#96 end to end from ring 3: the child resumes at the parent's fork site with rax=0,
# gets a PRIVATE copy of its memory, and the parent reaps it via waitpid wait-any. Builds its own
# kernel (FORK_SELFTEST) and seeds /bin/forker, so it needs no buildenv here.
run_gate "1.56.55 fork#96 + waitpid wait-any"          ""                                         "fork-smoke.sh"
# 1.57.2 — the kernel-embedded default TrueType face (core/kfont.cyr, rekha's Liberation Sans) proven
# FROM RING 3: /bin/kfont opens /fonts/default.ttf by name, pulls every byte through read#5 and hashes
# what it got against rekha's generator FNV-1a-64, then the sfnt header, the read-only gate, the exact
# namespace, stat#33 + lstat#102 and the provenance alias (exit 95; 80-94 / 96-97 name the step). The kernel's own boot
# line proves only that the KERNEL sees the bytes under its CR3. Builds its own kernel
# (KFONT_RING3_SELFTEST) and seeds /bin/kfont like the blk-ring3 smoke, so it needs no buildenv here.
# ⚠ There is no blk-ring3 row in this table to sit beside — that smoke is one of the ~68 still unlisted.
run_gate "1.57.2 kernel-embedded face (/fonts/default.ttf, rekha)" ""                             "kfont-smoke.sh"
# 1.57.3 — the AP1-3 boot/TSS stacks relocated OUT of kernel .rodata (the 1.57.2 face put the fixed
# region-1 windows [0x310000, 0x340000) inside the chunk literals) into region 7 via the direct map.
# The runtime half: an SMP_STACK_SELFTEST kernel under -smp 4 prints each AP's live RSP (sampled in
# ap_entry) against [DIRECTMAP_BASE + 0xFC0000, +0x40000) and re-hashes the rekha chunk literals IN
# PLACE after the wake (the load-bearing oracle — a stack anywhere in the image scribbles there on every
# tick, invisible to every -smp 1 gate). Mutation-proven: the old placement trips both. Builds its own
# kernel, so it needs no buildenv here; the image-side bound (LOAD end <= 0x370000) is check.sh gate 34.
run_gate "1.57.3 AP stacks in region 7 (-smp 4, rodata intact after wake)" ""                     "ap-stack-smoke.sh"
# 1.57.6 — the microsecond clock ring 3 uses (uptime_us#95). tsc-smoke existed since 1.56.18 and NO row ran
# it: when it was finally run for 1.57.6 it was RED on a healthy tree (the klog timestamp prefix fed the
# timestamp's seconds to its calibration extraction) and its boot HUNG after the IF=0 ring-3 probe — both
# unseen for months. The plain mode runs here: the FADT PM timer decoded, calibration on the acpi-pm tier,
# the live-tick tier agreeing within 2%, the lost-tick / agreement predicates on synthetic windows AND on
# one live window with a 25 ms IF=0 stall inside it (the call-site wiring), the probe's `run: exit 1` (#95
# advances with interrupts off), both accessors == calibration, the boot going on to the shell, and the
# corrected refusal texts (first attempt and final) in the binary. ⚠ Its TSC_QUOTA=<pct> mode (the daimon
# CPU-quota reproduction, TCG, ~1-2 min, needs systemd user cpu delegation) stays a MANUAL closeout gate.
run_gate "1.57.6 TSC calibration (acpi-pm tier + tick cross-check, uptime_us#95 advances IF=0)" "TSC_SELFTEST=1" "tsc-smoke.sh"
# 1.57.6 — spawn_path#43: distinct failure codes, the per-process #62 / CH_ENDOW arms cleared on EVERY
# failure kind (they were per-CPU and leaked into other processes' children), SPAWN_F_ARGV,
# SPAWN_F_CLEANFD capture (stdout+stderr, 2>&1, an explicitly passed fd, daimon's full shape), execwait#37
# multi-redirect, the table-full code, and the pipe buffer's last-reference lifetime (a ring-3 UAF before).
# Three banner-gated boots: the SPAWN_SELFTEST + PIPE_RC_SELFTEST kernel block (PIPE_RC_SELFTEST's first
# runner ever), then tests/spawn seeded as /bin/agnsh on a PLAIN kernel at -smp 1 AND -smp 4 — both gated;
# the -smp 4 boot is what caught do_context_switch leaving an AP on a reaped proc's freed page tables.
# Builds its own kernels, so no buildenv here.
run_gate "1.57.6 spawn: #43 codes, per-process arms, ARGV/CLEANFD, pipe lifetime (-smp 1 + 4)" "" "spawn-smoke.sh"
# 1.57.6 — exec-redirect-smoke has existed since 1.46.x (extended 1.56.39) and NO row ran it, so the #62/#37
# apply/restore and the #43 global-table refusal were exercised by nothing. It now also proves the
# two-pair `2>&1` apply + byte-identical reverse restore. Builds its own kernel (EXEC_REDIRECT_SELFTEST).
run_gate "1.46.x exec_redirect#62 apply/restore (+1.57.6 multi-pair), #43 global-table refusal" "" "exec-redirect-smoke.sh"
run_gate "1.39.x exFAT write (+ subdir)"             "EXFAT_WRITE_SELFTEST=1"                   "exfat-write-smoke.sh"

# --- ext2/jbd2 write regression bar (the iron-validated path must stay green) ---
run_gate "ext2 WRITE regression (W1-W5)"             "EXT2_WRITE_SELFTEST=1"                    "ext2-write-smoke.sh"

# --- 1.41.3 FS syscalls through ksyscall(), on-disk effects checked by host debugfs + e2fsck ---
# ⛔ FS_SYSCALL_SELFTEST shipped at 1.41.3 with NO RUNNER while docs/development/build.md said "gated by
# scripts/sweep.sh" — the same shape as SYSCALL_HARDEN_SELFTEST below, and it cost more: cyrius 6.5.1 made
# a wrong argument count a hard error, four 3-arg ksyscall() calls in the selftest made the flag build
# refuse to emit a binary, and nothing ran it for the next 25 pins. Found by a static arity scan in the
# 6.6.6 pin audit (1.57.5), fixed there, and this row is what keeps the next one from hiding.
run_gate "1.41.3 FS syscalls (mkdir/open/stat/rename/getdents/unlink/rmdir/sync via ksyscall)" "FS_SYSCALL_SELFTEST=1" "fssys-smoke.sh"

# --- 1.40.x exec-from-disk: load + ring-3 run + ENOEXEC + subdir + clean return ---
run_gate "1.40.x exec-from-disk (run /bin/prog2 + ENOEXEC)" "EXEC_SELFTEST=1 EXT2_WRITE_SELFTEST=1" "exec-smoke.sh"

# --- 1.41.5 syscall hardening + the 1.56.40 epoll no-hang lock ---
# ⛔ SYSCALL_HARDEN_SELFTEST shipped in 1.41.5 with NO RUNNER — it appeared only in build.sh's
# compile-gate list, so nothing in check.sh or sweep.sh ever built or ran it. Two consequences went
# unnoticed for ~15 minor versions: it is the ONLY coverage epoll/timerfd/signalfd have, and it had
# stopped COMPILING (two `ksyscall` calls passed 3 args to a 4-arity function, which cyrius made a hard
# error). Both fixed 2026-08-05. A selftest nothing runs is not coverage; it is a comment.
run_gate "1.41.5 syscall hardening + epoll no-hang"  "SYSCALL_HARDEN_SELFTEST=1"                "syscall-harden-smoke.sh"
# ⛔ 1.56.55 — ADDED. This smoke carries the ONLY regression test for `proc_alloc_slot`s reuse scan
# (`ring3: nonlifo reuse OK`), plus the ring-3 preempt gate and `sched_yield`#44 slice donation, and it
# was in NO sweep row — so the 1.56.55 allocator change had to be verified by hand. It was also red
# for a harness reason (a 40 s dwell that truncated its own tail); fixed in the smoke, 8/8 now.
run_gate "1.44.x ring-3 procs, preempt gate, slot reuse, yield#44" "RING3_SELFTEST=1"           "ring3-smoke.sh"
# 1.57.6 (Path 2, S3.3) — per-process kernel stacks. A KSTACK_SELFTEST kernel, booted -smp 1 THEN -smp 4 (KVM
# `-cpu host` when /dev/kvm is writable, else multi-threaded TCG — the log names it), both gated: the SYSRET
# frame is per-process (four probes with distinct RSP / sentinels / XMM survive >= 20 probe syscalls each), a
# syscall can be switched out MID-FLIGHT at CPL0 and resumed — on another CPU at -smp 4 — the deferred on_cpu
# release holds under a retire-while-running storm, a console_lock holder at IF=1 is not preempted into a
# same-CPU deadlock, sched_next's nothing-ready fallback answers the idle and never kmain's stale slot, every
# timer ISR body runs non-preemptible, and region 7 carries 32 not-present guard pages. Also the stub-size
# oracle (280 bytes, ibrs=0). Builds its own kernel and leaves a plain one, so no buildenv here.
run_gate "1.57.6 per-process kernel stacks, CPL0 switch windows, lock holders, guard pages (-smp 1 + 4)" "" "kstack-smoke.sh"

# --- 1.56.40 channel band (#97): the RING-3 half, and the only place §9.9's kill criteria can be met ---
# ⛔ The boot selftest structurally cannot close either: it runs under the KERNEL's CR3 (so it says
# nothing about region reachability from a client's page tables) and it can only FAKE an inherited fd by
# corrupting the owner field, which tests the check rather than the inheritance.
run_gate "1.56.40 chan #97 ring-3 kill criteria"     "CHAN_RING3_SELFTEST=1"                    "chan-ring3-smoke.sh"

# ⛔⛔ ADDED 1.56.44, AND UNTIL NOW THE #92 ABI BATTERY RAN NOWHERE AT ALL. `edge_abi_selftest` is
# behind `#ifdef EDGE_ABI_SELFTEST`; the define comes only from `EDGE_ABI_SELFTEST=1 sh
# scripts/build.sh`; its only consumer is `scripts/smoke/edge-abi-smoke.sh`; and NOTHING invoked that
# script — not this file, not check.sh, not CI. 168 ABI cases that could not fail, guarding the surface
# ring 3 reaches the GPU through.
# ⚠ This file's own header calls that out for selftests generally; the ABI battery was simply never
# added to the table. It is one of 68 of 83 smokes still missing from it — a separate, larger problem.
run_gate "1.56.44 #92 ABI battery (177 cases, ops 0x01-0x10)" "EDGE_ABI_SELFTEST=1" "edge-abi-smoke.sh"

# --- 1.52.x audio: HDA probe -> reset -> verb ring -> codec graph -> stream DMA-arm ---
run_gate "1.52.x audio HDA (probe/reset/verb/graph/stream)" "" "hda-smoke.sh"

# --- HDMI-audio arc bite 2b: multi-instance probe/enum (2nd HDA controller as instance 1) ---
# (hda-dual-smoke self-builds HDA_HDMI=1 + boots QEMU with two -device intel-hda)
run_gate "HDMI-audio bite 2b (dual-HDA instance-1 probe/enum)" "" "hda-dual-smoke.sh"

# --- 1.53.x FP/SIMD: SSE enable (CR0.EM off/MP on + CR4.OSFXSR) -> movsd + ring-0 f64 mul ---
run_gate "1.53.x FP/SSE enable (movsd + ring-0 f64)" "FP_SELFTEST=1" "fp-selftest-smoke.sh"

# --- 1.53.x FP/SIMD B2: per-proc FXSAVE areas (16-aligned + default FCW/MXCSR) ---
run_gate "1.53.x FP-area (per-proc FXSAVE state)" "FP_AREA_SELFTEST=1" "fp-area-smoke.sh"

# --- 1.53.x FP/SIMD B3: lazy #NM handler services a forced FP-trap (CR0.TS-on-switch live) ---
run_gate "1.53.x FP-#NM (lazy save/restore serviced)" "FP_NM_SELFTEST=1" "fp-nm-smoke.sh"

# --- 1.53.x FP/SIMD B4: real cyrius f64 runs in ring 3 (exec /bin/fpex from disk → run: exit 84) ---
run_gate "1.53.x FP-ring3 (real f64 in ring 3)" "FP_RING3_SELFTEST=1" "fp-ring3-smoke.sh"
run_gate "1.53.x FP-ctxsw (two-proc XMM preservation)" "FP_CTXSW_SELFTEST=1" "fp-ctxsw-smoke.sh"
run_gate "1.53.x naad-ring3 (real DSP library f64 in ring 3, arc end-proof)" "NAAD_RING3_SELFTEST=1" "naad-ring3-smoke.sh"

# --- 1.56.45 the console's live line: an async log must not alter what the operator is typing ---
# ⛔ THE ONLY FRAMEBUFFER-ORACLE GATE IN THIS SWEEP, and it has to be. The defect it guards is INVISIBLE
# in serial — a log line and a typed line are just two ordered writes there — which is exactly how it was
# once diagnosed from a serial log and ruled "working as intended". Only the fb has a cursor to corrupt.
# ⚠ Plain production build (no selftest env): the stimulus is a real USB mouse one-shot, not a hook.
run_gate "1.56.45 console live line (async log vs. the typed prompt, FB oracle)" "" "console-line-smoke.sh"

# ⭐ 1.56.60 — SHUTDOWN. THIS SMOKE EXISTED SINCE THE 1.55.x ARC AND NOTHING HAS EVER RUN IT:
# `grep -rn shutdown-smoke` over scripts/, scripts/check.sh and .github/workflows/ returned exactly
# one hit tree-wide, inside a docs issue. So even its working arms — the dirty-then-flush barrier
# and the post-shutdown e2fsck — had never gated a release. It is registered now because it finally
# has a real STOP oracle: before 1.56.60 the non-exiting arms asserted only "filesystems flushed"
# and "storage quiesced", both of which the BUGGY spin-halt path emitted, so this smoke reported
# PASS on precisely the defect the 2026-09-03 archaemenid burn found by hand.
# ⚠ THIS ROW DRIVES THE DEFAULT ARM ONLY (agnsh `exit` -> boot_finish -> power_stop_final).
# run_gate passes $buildenv to build.sh, NOT to the smoke, so the reboot/poweroff arms — which are
# the ones QEMU's process-exit oracle covers — cannot be selected from this table as it stands.
# Run those by hand until run_gate can carry smoke-time env:
#     SHUTDOWN_SMOKE_VERB=poweroff sh scripts/smoke/shutdown-smoke.sh
#     SHUTDOWN_SMOKE_VERB=reboot   sh scripts/smoke/shutdown-smoke.sh
# ⛔ A GREEN poweroff ARM UNDER QEMU PROVES PLUMBING ONLY — QEMU's _S5_ package is all zeroes, so
# SLP_TYP=0 is what it wants and a totally broken decode passes by construction. The S5 decode's
# only ground truth is real firmware: agnosticos prior-art/acpi-s5-known-good-archaemenid-0719.txt
# and an iron burn. Do not let a green sweep be read as decode coverage.
run_gate "1.55.x shutdown (flush barrier, named stop terminus, post-shutdown e2fsck)" "" "shutdown-smoke.sh"

# --- Restore the plain production build as the working artifact ---
echo ""
echo "Restoring plain production build..."
sh "$ROOT/scripts/build.sh" >/dev/null 2>&1
echo "  build/agnos: $(stat -c%s "$ROOT/build/agnos" 2>/dev/null || wc -c < "$ROOT/build/agnos") bytes"

echo ""
echo "=========================================="
printf ' SWEEP RESULTS  (%d passed, %d failed)%b\n' "$pass" "$fail" "$results"
echo "=========================================="
[ "$fail" = 0 ] && { echo "ARC SWEEP: PASS"; exit 0; } || { echo "ARC SWEEP: FAIL"; exit 1; }
