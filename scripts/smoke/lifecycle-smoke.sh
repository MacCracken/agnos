#!/bin/sh
# lifecycle-smoke.sh — 1.57.7 (S7): THE PROCESS LIFECYCLE, + (S8) PER-PROCESS RESOURCE LIMITS (spawn_limits#107: memory/CPU
#   caps, the one-shot arm, inheritance, the loader overlap refusal, the fork+mmap no-overwrite rule — the S8 phases
#   run after every S7 phase, HIGH last). docs/architecture/process-lifecycle.md.
#   kill#16 ENDS (9), STOPS (19) and CONTINUES (18) a child and — with KILL_TREE (0x100) — every epoch-validated
#   descendant, through the four boundaries (claim, tick, B1 at syscall exit, a blocked wait's signal point); the wait
#   status (265 SIGKILL · 142 a fault · code & 0xFF); #99 states 5 STOPPED and 7 ZOMBIE; orphans reap themselves.
#
# PLAIN kernel (built first), tests/lifecycle/lifex seeded as /bin/agnsh (kybernet launches it — D19) and
# tests/lifecycle/spinner as /bin/spinner, plus /lf and /lf2 (4 KB flock targets) and, when LIFE_PHASES is set,
# /life/phases. Boots -smp 1 (-cpu max) THEN -smp 4 (smoke_accel: KVM when /dev/kvm is writable, else multi-threaded
# TCG — printed; LIFE_KVM=0 by default, see the boot loop); BOTH GATED. Extra QEMU args both boots: a virtio-net NIC on user networking (the PING phase's silent
# host and the loopback TCP phases). Per boot it REQUIRES a PASS line per marker (filtered by LIFE_PHASES and -smp:
# SIGBIT / KILLTICK / KLOGSTORM / STOPTICK are -smp 4 only, STOP-LONE -smp 1 only), `LIFEX-DONE pass=N fail=0` and
# `kybernet: shell exited`. DENIES `-BAD`, `LIFE-KLOG-UNPARSED`, `LIFE-SELFKILL-SURVIVED`, PANIC, `emergency shell`
# and the shared SMOKE_INVARIANT_DENY (qemu-dwell.sh — S7 adds `proc: orphan zombie recycled`, `lifecycle: park
# refused`, `lifecycle: signal point with preempt held`, `lifecycle: claimed a kernel continuation`).
#
# Env: LIFE_PHASES (space/comma separated phase names; unknown names are REJECTED before booting), LIFE_SMP
# (default "1 4"), QEMU_TIMEOUT (per boot, default 600 s). Every boot is banner-gated (no "AGNOS kernel v" = VOID,
# re-run, never scored). Exit: 0 every check PASS · 1 any FAIL · 2 VOID. Leaves a PLAIN build/agnos.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

ALL_PHASES="SETUP FAULTBG SIGBIT WSTAT ZOMBIE AUTH RECYCLEDPARENT ZPARENTEXIT ORPHAN ORPHANRACE KILLSYS SELFKILL
ZOMBIENOOP KILLSPIN KILLTICK SIGTERM RELEASE LEAK ZPARENTKILL KILLNOTREE KLOGSTORM KILLBLOCKED KBDNEXT FLOCKCYCLE
NETBLOCKED EW37 EW37RACE STOP STOPTICK KILLSTOPPED SELFSTOP STOPBLOCKED KILLSTOPPEDINPLACE SELFUNSTOPPABLE
STOPUNSTOPPABLE STOPPEDORPHAN RACE TREE TREENOESCAPE TREESTOPNOESCAPE STOPEW37TREE STOPZPARENT KLOGFORMAT
LIMARGS MEMEXACT MEMLOADER MEMSPAWN3 MEM37 MEMINHERIT MEMLOWER MEMFORK ARMONESHOT ARMPERPROC ARMRECYCLE FORKNOARM
FORKREMAP ELFOVERLAP CPUXCPU CPUSYS CPUINHERIT CPULOWER CPUEW37 CPUFORK ARMMIGRATE HIGH"

# phase -> "marker:smp-filter ..." (filter: b = both, 4 = -smp 4 only (NA at 1), 1 = -smp 1 only)
markers_of() {
    case "$1" in
        SETUP) echo "LIFE-SETUP:b" ;;
        FAULTBG) echo "LIFE-FAULT-BG:b" ;;
        SIGBIT) echo "LIFE-SIGBIT:4" ;;
        WSTAT) echo "LIFE-WSTAT-MASK:b" ;;
        ZOMBIE) echo "LIFE-ZOMBIE-LISTED:b" ;;
        AUTH) echo "LIFE-AUTH:b" ;;
        RECYCLEDPARENT) echo "LIFE-RECYCLED-PARENT:b" ;;
        ZPARENTEXIT) echo "LIFE-ZOMBIE-OF-EXITED:b" ;;
        ORPHAN) echo "LIFE-ORPHAN-REAP:b" ;;
        ORPHANRACE) echo "LIFE-ORPHAN-RACE:b" ;;
        KILLSYS) echo "LIFE-KILL-SYS:b" ;;
        SELFKILL) echo "LIFE-SELFKILL:b" ;;
        ZOMBIENOOP) echo "LIFE-KILL-ZOMBIE-NOOP:b" ;;
        KILLSPIN) echo "LIFE-KILL-SPIN:b" ;;
        KILLTICK) echo "LIFE-KILL-TICK:4" ;;
        SIGTERM) echo "LIFE-SIGTERM-NODEFAULT:b" ;;
        RELEASE) echo "LIFE-KILL-RELEASE-FLOCK:b LIFE-KILL-RELEASE-CHAN:b LIFE-KILL-RELEASE-TCP:b" ;;
        LEAK) echo "LIFE-LEAK:b" ;;
        ZPARENTKILL) echo "LIFE-ZOMBIE-OF-KILLED:b" ;;
        KILLNOTREE) echo "LIFE-KILL-NOTREE:b" ;;
        KLOGSTORM) echo "LIFE-KLOG-STORM:4" ;;
        KILLBLOCKED) echo "LIFE-KILL-BLOCKED-SLEEP:b LIFE-KILL-BLOCKED-FLOCK:b LIFE-KILL-BLOCKED-KBD:b" ;;
        KBDNEXT) echo "LIFE-KILL-BLOCKED-KBD-NEXT:b" ;;
        FLOCKCYCLE) echo "LIFE-FLOCK-CYCLE:b" ;;
        NETBLOCKED) echo "LIFE-KILL-BLOCKED-CONNECT:b LIFE-KILL-BLOCKED-SEND:b LIFE-KILL-BLOCKED-PING:b" ;;
        EW37) echo "LIFE-KILL-EW37:b" ;;
        EW37RACE) echo "LIFE-EW37-RACE:b" ;;
        STOP) echo "LIFE-STOP:b LIFE-CONT:b" ;;
        STOPTICK) echo "LIFE-STOP-TICK:4" ;;
        KILLSTOPPED) echo "LIFE-KILL-STOPPED:b" ;;
        SELFSTOP) echo "LIFE-SELFSTOP:b LIFE-STOP-LONE:1" ;;
        STOPBLOCKED) echo "LIFE-STOP-BLOCKED:b" ;;
        KILLSTOPPEDINPLACE) echo "LIFE-KILL-STOPPED-INPLACE:b" ;;
        SELFUNSTOPPABLE) echo "LIFE-SELF-UNSTOPPABLE:b" ;;
        STOPUNSTOPPABLE) echo "LIFE-STOP-UNSTOPPABLE:b" ;;
        STOPPEDORPHAN) echo "LIFE-STOPPED-ORPHAN:b" ;;
        RACE) echo "LIFE-RACE:b" ;;
        TREE) echo "LIFE-TREE-STOP:b LIFE-TREE-CONT:b LIFE-TREE:b" ;;
        TREENOESCAPE) echo "LIFE-TREE-NOESCAPE:b" ;;
        TREESTOPNOESCAPE) echo "LIFE-TREE-STOP-NOESCAPE:b" ;;
        STOPEW37TREE) echo "LIFE-STOP-EW37-TREE:b" ;;
        STOPZPARENT) echo "LIFE-STOP-ZPARENT:b" ;;
        KLOGFORMAT) echo "LIFE-KLOG-FORMAT:b" ;;
        # 1.57.7 (S8) — per-process resource limits (spawn_limits#107); HIGH (the low-arena burn) runs LAST.
        LIMARGS) echo "LIFE-LIM-ARGS:b" ;;
        MEMEXACT) echo "LIFE-MEM-EXACT:b" ;;
        MEMLOADER) echo "LIFE-MEM-LOADER:b" ;;
        MEMSPAWN3) echo "LIFE-MEM-SPAWN3:b" ;;
        MEM37) echo "LIFE-MEM-37:b" ;;
        MEMINHERIT) echo "LIFE-MEM-INHERIT:b" ;;
        MEMLOWER) echo "LIFE-MEM-LOWER-ONLY:b" ;;
        MEMFORK) echo "LIFE-MEM-FORK:b" ;;
        ARMONESHOT) echo "LIFE-ARM-ONESHOT-43:b LIFE-ARM-ONESHOT-37:b LIFE-ARM-ONESHOT-3:b LIFE-ARM-ONESHOT-43OK:b LIFE-ARM-ONESHOT-CPU:b LIFE-ARM-ONESHOT:b" ;;
        ARMPERPROC) echo "LIFE-ARM-PER-PROCESS:b" ;;
        ARMRECYCLE) echo "LIFE-ARM-RECYCLE:b" ;;
        FORKNOARM) echo "LIFE-FORK-NO-ARM:b" ;;
        FORKREMAP) echo "LIFE-FORK-REMAP:b" ;;
        ELFOVERLAP) echo "LIFE-ELF-OVERLAP:b" ;;
        CPUXCPU) echo "LIFE-CPU-XCPU:b" ;;
        CPUSYS) echo "LIFE-CPU-SYSCALL:b" ;;
        CPUINHERIT) echo "LIFE-CPU-INHERIT:b" ;;
        CPULOWER) echo "LIFE-CPU-LOWER-ONLY:b" ;;
        CPUEW37) echo "LIFE-CPU-EW37-XCPU:b" ;;
        CPUFORK) echo "LIFE-CPU-FORK:b" ;;
        ARMMIGRATE) echo "LIFE-ARM-MIGRATION:b" ;;
        HIGH) echo "LIFE-HIGH-BURN:b LIFE-MEM-HIGH:b LIFE-FORK-HIMAP:b LIFE-HIMAP-RECYCLE:b" ;;
        *) echo "" ;;
    esac
}

PHASES="$ALL_PHASES"
if [ -n "${LIFE_PHASES:-}" ]; then
    PHASES="$(echo "$LIFE_PHASES" | tr ',' ' ')"
    for p in $PHASES; do
        if [ -z "$(markers_of "$p")" ]; then echo "  ERROR: unknown LIFE_PHASES name '$p' (known: $(echo $ALL_PHASES))"; exit 1; fi
    done
    case " $PHASES " in *" SETUP "*) ;; *) PHASES="SETUP $PHASES" ;; esac
fi

echo "=== lifecycle smoke (kill / stop / cont / KILL_TREE / orphans) — phases: $(echo $PHASES | wc -w) ==="
ring3_seed_init || exit 1
command -v cyrius >/dev/null 2>&1 || { echo "  ERROR: cyrius not found — this gate measured NOTHING"; exit 1; }

WORK="$ROOT/build/lifecycle-smoke"; LOGS="${LIFE_LOGS:-$ROOT/build/lifecycle-smoke-logs}"
rm -rf "$WORK"; mkdir -p "$WORK" "$LOGS"

# ⛔ The PLAIN kernel FIRST, then the test programs — fresh every run (the stale-artifact lesson).
echo "Building the PLAIN kernel..."
sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
KERNEL="$WORK/agnos-plain"
cp "$ROOT/build/agnos" "$KERNEL"
echo "Building tests/lifecycle (lifex, spinner; --agnos)..."
( cd "$ROOT/tests/lifecycle" && cyrius build --agnos lifex.cyr build/lifex && cyrius build --agnos spinner.cyr build/spinner ) \
    > "$LOGS/lifecycle-build.log" 2>&1 || { echo "  ERROR: tests/lifecycle build failed (see $LOGS/lifecycle-build.log)"; exit 1; }

SEED="$WORK/seed"; mkdir -p "$SEED/bin" "$SEED/life"
cp "$ROOT/tests/lifecycle/build/lifex" "$SEED/bin/agnsh"
cp "$ROOT/tests/lifecycle/build/spinner" "$SEED/bin/spinner"
dd if=/dev/zero of="$SEED/lf" bs=4096 count=1 status=none
dd if=/dev/zero of="$SEED/lf2" bs=4096 count=1 status=none
# 1.57.7 (S8) — the two 187-byte ELFs (S8.md §4.3a): exit(95) at 0x4000B0; PH0 R|X at 0x400000; PH1 R|W memsz 0x1000
# at 0x401000 (/bin/ovl: the SAME 2 MB page as PH0 -> the loaders refuse it) or 0x600000 (/bin/ovlok: its own page,
# the control). lifex builds the same bytes in memory for #3.
python3 - "$SEED/bin" <<'PYEOF' || { echo "  ERROR: ovl/ovlok generation"; exit 1; }
import struct, sys
for name, ph1 in (("ovl", 0x401000), ("ovlok", 0x600000)):
    e = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8)
    e += struct.pack("<HHIQQQIHHHHHH", 2, 0x3E, 1, 0x4000B0, 64, 0, 0, 64, 56, 2, 0, 0, 0)
    e += struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, 0xBB, 0xBB, 0x200000)
    e += struct.pack("<IIQQQQQQ", 1, 6, 0, ph1, ph1, 0, 0x1000, 0x1000)
    e += bytes.fromhex("bf5f00000031c00f05ebfe")
    assert len(e) == 187
    open(sys.argv[1] + "/" + name, "wb").write(e)
PYEOF
if [ -n "${LIFE_PHASES:-}" ]; then for p in $PHASES; do echo "$p"; done > "$SEED/life/phases"; fi
ring3_seed_image "$WORK/L.img" "$KERNEL" "$SEED" "AGNOS-LIFE" || { echo "  ERROR: image"; exit 1; }

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

for smp in ${LIFE_SMP:-1 4}; do
    LOG="$LOGS/lifecycle-smp$smp.log"
    # ⚠ -smp 4 runs MULTI-THREADED TCG by default (LIFE_KVM=1 selects smoke_accel's KVM): under KVM a boot WITH a
    # virtio-net NIC draws every console line in ~1.45 s (pre-existing — the MERGE sock-wait -smp 4 log reaches
    # `kybernet: exec` at 81 s; HARNESS-BACKLOG S7 row), and lifex re-prints every lifecycle line, so a KVM boot runs
    # past any sane dwell. TCG thread=multi still runs the four vCPUs in parallel host threads.
    if [ "$smp" -gt 1 ]; then R3_ACCEL="$(SMOKE_KVM="${LIFE_KVM:-0}" smoke_accel "$smp")"; else R3_ACCEL="-cpu max"; fi
    export R3_ACCEL
    echo ""
    echo "Boot -smp $smp  accel=$R3_ACCEL"
    cp "$WORK/L.img" "$WORK/L-$smp.img"
    T0=$(date +%s)
    ring3_seed_boot "$WORK/L-$smp.img" "$LOG" "power: stopped" "${QEMU_TIMEOUT:-600}" "$WORK" -smp "$smp" \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0
    rc=$?
    T1=$(date +%s)
    if [ $rc -eq 2 ]; then void=$((void + 1)); echo "  VOID (no kernel banner) — not scored"; continue; fi
    echo "  runtime: $((T1 - T0)) s"
    strings "$LOG" | grep -E "^LIFE-[A-Z0-9-]+-(BAD|NA)|LIFEX-DONE|kybernet: (shell|emergency)" | sed 's/^/    /'
    echo "  -- -smp $smp verdicts --"
    for p in $PHASES; do
        for mk in $(markers_of "$p"); do
            m="${mk%%:*}"; f="${mk##*:}"
            if [ "$f" = "4" ] && [ "$smp" -lt 2 ]; then
                if strings "$LOG" | grep -qF -- "$m-NA"; then ok "[smp$smp] $m (NA at -smp 1)"; else bad "[smp$smp] $m (expected $m-NA)"; fi
                continue
            fi
            if [ "$f" = "1" ] && [ "$smp" -gt 1 ]; then continue; fi
            if strings "$LOG" | grep -qE -- "(^|[^A-Z0-9-])$m-OK"; then ok "[smp$smp] $m"; else bad "[smp$smp] $m (missing $m-OK)"; fi
        done
    done
    if strings "$LOG" | grep -qE "LIFEX-DONE pass=[0-9]+ fail=0"; then ok "[smp$smp] LIFEX-DONE fail=0"; else bad "[smp$smp] LIFEX-DONE fail=0 (missing or fail > 0)"; fi
    if strings "$LOG" | grep -qF "kybernet: shell exited"; then ok "[smp$smp] kybernet: shell exited (lifex exited 0)"; else bad "[smp$smp] kybernet: shell exited"; fi
    deny "-BAD( |$)"                    "[smp$smp] no -BAD line"
    deny "LIFE-KLOG-UNPARSED"          "[smp$smp] every lifecycle trace line parsed"
    deny "LIFE-SELFKILL-SURVIVED"      "[smp$smp] a self-kill never returns"
    deny "PANIC"                       "[smp$smp] no PANIC line"
    deny "emergency shell"             "[smp$smp] no emergency shell"
    deny "$SMOKE_INVARIANT_DENY"       "[smp$smp] no latched kernel invariant line (the shared SMOKE_INVARIANT_DENY)"
done

# Leave a PLAIN build/agnos (the kernel built above is plain; rebuild defensively in case a concurrent step changed it).
sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain-final.log" 2>&1 || echo "  WARN: the final plain rebuild failed"

echo ""
echo "=== lifecycle-smoke: $pass passed, $fail failed, $void void ==="
if [ "$fail" -ne 0 ]; then echo "lifecycle-smoke: FAIL"; exit 1; fi
if [ "$void" -ne 0 ]; then echo "lifecycle-smoke: VOID (a boot never handed off — infrastructure, not the kernel)"; exit 2; fi
echo "lifecycle-smoke: PASS"
exit 0
