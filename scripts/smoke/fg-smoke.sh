#!/bin/sh
# fg-smoke.sh — 1.57.7 (Path 2, S3b): FOREGROUND EXEC ON PATH 2. docs/architecture/foreground-exec.md.
#   execwait#37 is a BLOCKING WAIT: the child is an ordinary scheduled IF=1 process (it accrues ticks, its siblings
#   run, it may yield / spawn / nest / fault / migrate) and the caller blocks in the kernel (#99 state 6).
#   kmain's `run` (the emergency shell, boot selftests after the scheduler) launches a scheduled child the same way.
#
# DEFAULT MODE — PLAIN kernel, tests/fg/fgx seeded as /bin/agnsh (kybernet launches it IF=1, D19) and tests/fg/fgc as
# /bin/fgc. Boots -smp 1 (-cpu max) THEN -smp 4 (smoke_accel: KVM when /dev/kvm is writable, else multi-threaded TCG —
# printed); BOTH GATED. Per boot it REQUIRES every FG-*-OK line, FG-DONE with fail=0, the kernel witness
# `execwait: first scheduled child` (the #37 route really ran), FG-EW-REDIR-PARENT-STDOUT and FG-HELLO-FROM-CHILD on
# serial, then — in this order after FG-DONE — `kybernet: shell exited`, `power: filesystems flushed`,
# `power: stopped` (agnsh exits while its FG-BGEXIT writer is still alive), and afterwards dumpe2fs -h of the ext2
# partition must read `Filesystem state: clean` (dumpe2fs is the oracle, not e2fsck's exit code — shutdown-smoke).
# DENIES FG-FAIL, PANIC, `emergency shell` and the shared SMOKE_INVARIANT_DENY (qemu-dwell.sh).
#
# RECOVERY MODE (--recovery, and run after the default mode by default) — /bin/agnsh = fgc with NO role (exit 3, so
# kybernet drops into its emergency shell, DEP-4), /bin/fgc = fgc. QEMU with a usb-kbd and an HMP monitor; an
# embedded Python driver types `run /bin/fgc ...` (shutdown-smoke's typ/type_verified) and waits for each result:
# memfree (M0) · exit 7 · tickself 400 (a kmain child accrues ticks) · fault (142) then exit 7 · orphanwrite then
# `help` then exit 7 (an orphan writing concurrently with kmain's console output) · storm x5 (INV-FG-2: a slot is
# never reused under kmain's unread status) · memfree (M1): M0 - M1 <= 6 orphans x (6 MiB + 64 KiB). Whole `ow\n` lines (the
# orphan writer) are deleted from the serial text before every match. DENIES PANIC and SMOKE_INVARIANT_DENY.
#
# Every boot is banner-gated (no "AGNOS kernel v" = VOID, never scored). Env: FG_SMP (default "1 4"),
# FG_MODE (default "default recovery"; `--recovery` = recovery only, `--default` = default only), QEMU_TIMEOUT
# (default-mode dwell, default 150). Exit: 0 every check PASS · 1 any FAIL · 2 VOID. Leaves a PLAIN build/agnos.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

MODES="${FG_MODE:-default recovery}"
case "${1:-}" in
    --recovery) MODES="recovery" ;;
    --default)  MODES="default" ;;
    "") ;;
    *) echo "usage: $0 [--default|--recovery]"; exit 1 ;;
esac

echo "=== fg smoke (foreground exec on Path 2: #37 blocks, kmain run) — modes: $MODES ==="
ring3_seed_init || exit 1
command -v cyrius >/dev/null 2>&1 || { echo "  ERROR: cyrius not found — this gate measured NOTHING"; exit 1; }
for t in python3 dumpe2fs; do
    command -v "$t" >/dev/null 2>&1 || { echo "  ERROR: missing tool '$t' — this gate measured NOTHING"; exit 1; }
done

WORK="$ROOT/build/fg-smoke"; LOGS="$ROOT/build/fg-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

# ⛔ The PLAIN kernel FIRST, then the test programs — fresh every run (the stale-artifact lesson).
echo "Building the PLAIN kernel..."
sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
KERNEL="$WORK/agnos-plain"
cp "$ROOT/build/agnos" "$KERNEL"
echo "Building tests/fg (fgx, fgc; --agnos)..."
( cd "$ROOT/tests/fg" && cyrius build --agnos fgx.cyr build/fgx && cyrius build --agnos fgc.cyr build/fgc ) \
    > "$LOGS/fg-build.log" 2>&1 || { echo "  ERROR: tests/fg build failed (see $LOGS/fg-build.log)"; exit 1; }

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qF -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }
# First line number of a fixed string in the log (0 = absent).
lno()  { strings "$LOG" | grep -nF -- "$1" | head -1 | cut -d: -f1; }

# ════════════════════════════════════════ DEFAULT MODE ════════════════════════════════════════
run_default() {
    SEED="$WORK/seed-default"; mkdir -p "$SEED/bin"
    cp "$ROOT/tests/fg/build/fgx" "$SEED/bin/agnsh"
    cp "$ROOT/tests/fg/build/fgc" "$SEED/bin/fgc"
    ring3_seed_image "$WORK/D.img" "$KERNEL" "$SEED" "AGNOS-FG" || { echo "  ERROR: image"; exit 1; }
    for smp in ${FG_SMP:-1 4}; do
        LOG="$LOGS/fg-default-smp$smp.log"
        if [ "$smp" -gt 1 ]; then R3_ACCEL="$(smoke_accel "$smp")"; else R3_ACCEL="-cpu max"; fi
        export R3_ACCEL
        echo ""
        echo "Default boot -smp $smp  accel: $R3_ACCEL"
        cp "$WORK/D.img" "$WORK/D-$smp.img"
        ring3_seed_boot "$WORK/D-$smp.img" "$LOG" "power: stopped" "${QEMU_TIMEOUT:-150}" "$WORK" -smp "$smp"
        if [ $? -eq 2 ]; then void=$((void + 1)); continue; fi
        strings "$LOG" | grep -E "FG-|execwait: first|kybernet: (exec|shell|emergency)|power: (filesystems|stopped)" \
            | grep -v "^ow$" | sed 's/^/    /'
        echo "  -- -smp $smp verdicts --"
        for m in FG-KYB FG-EW-BASIC FG-EW-LATENCY FG-EW-TICKS FG-EW-SIBLING FG-EW-YIELD FG-EW-NEST FG-EW-FAULT \
                 FG-EW-REDIR FG-EW-ENV FG-EW-LAUNCHFAIL FG-EW-FP FG-EW-MIGRATE; do
            want "$m-OK" "[smp$smp] $m"
        done
        want "execwait: first scheduled child" "[smp$smp] FG-EW-WITNESS: the kernel took the scheduled #37 route"
        want "FG-EW-REDIR-PARENT-STDOUT"       "[smp$smp] the caller's own fd 1 is still the console after a redirected #37"
        want "FG-HELLO-FROM-CHILD"             "[smp$smp] LAUNCHFAIL's hello reached serial (a failed #37 consumed the redirect)"
        if strings "$LOG" | grep -qE "FG-DONE pass=[0-9]+ fail=0"; then ok "[smp$smp] FG-DONE with fail=0"; else bad "[smp$smp] FG-DONE with fail=0 (missing or fail > 0)"; fi
        l_done=$(lno "FG-DONE"); l_exit=$(lno "kybernet: shell exited"); l_fl=$(lno "power: filesystems flushed"); l_st=$(lno "power: stopped")
        if [ -n "$l_done" ] && [ -n "$l_exit" ] && [ -n "$l_fl" ] && [ -n "$l_st" ] \
            && [ "$l_done" -lt "$l_exit" ] && [ "$l_exit" -lt "$l_fl" ] && [ "$l_fl" -lt "$l_st" ]; then
            ok "[smp$smp] FG-DONE -> kybernet: shell exited -> power: filesystems flushed -> power: stopped (agnsh exit with a live bg job)"
        else
            bad "[smp$smp] the agnsh-exit shutdown order (FG-DONE=${l_done:-none} shell-exited=${l_exit:-none} flushed=${l_fl:-none} stopped=${l_st:-none})"
        fi
        deny "FG-FAIL"                  "[smp$smp] no FG-FAIL line"
        deny "PANIC"                    "[smp$smp] no PANIC line"
        deny "emergency shell"          "[smp$smp] no emergency shell (fgx exited 0)"
        deny "$SMOKE_INVARIANT_DENY"    "[smp$smp] no latched kernel invariant line (the shared SMOKE_INVARIANT_DENY)"
        dd if="$WORK/D-$smp.img" bs=1M skip=33 count=67 of="$WORK/part-$smp.img" status=none
        dumpe2fs -h "$WORK/part-$smp.img" > "$LOGS/dumpe2fs-smp$smp.log" 2>&1 || true
        FSSTATE="$(grep -i '^Filesystem state:' "$LOGS/dumpe2fs-smp$smp.log" | sed 's/.*: *//')"
        case "$FSSTATE" in
            clean*) ok "[smp$smp] dumpe2fs: Filesystem state: clean" ;;
            *) bad "[smp$smp] dumpe2fs: Filesystem state '${FSSTATE:-<unreadable>}' (the shutdown flush did not take)" ;;
        esac
        echo "  report: $(strings "$LOG" | grep -oE 'FG-EW-(BASIC|LATENCY) rtt_us=[0-9]+' | tr '\n' ' ') $(strings "$LOG" | grep -oE 'FG-EW-MIGRATE-WITNESS=[01]' | head -1)"
    done
}

# ════════════════════════════════════════ RECOVERY MODE ════════════════════════════════════════
run_recovery() {
    SEED="$WORK/seed-recovery"; mkdir -p "$SEED/bin"
    cp "$ROOT/tests/fg/build/fgc" "$SEED/bin/agnsh"
    cp "$ROOT/tests/fg/build/fgc" "$SEED/bin/fgc"
    ring3_seed_image "$WORK/R.img" "$KERNEL" "$SEED" "AGNOS-FGR" || { echo "  ERROR: image"; exit 1; }
    for smp in ${FG_SMP:-1 4}; do
        LOG="$LOGS/fg-recovery-smp$smp.log"
        MON="$WORK/mon-$smp.sock"
        if [ "$smp" -gt 1 ]; then ACC="$(smoke_accel "$smp")"; else ACC="-cpu max"; fi
        echo ""
        echo "Recovery boot -smp $smp  accel: $ACC"
        cp "$WORK/R.img" "$WORK/R-$smp.img"
        # Banner-gated retry BEFORE the driver (shutdown-smoke's loop): a firmware hand-off that never happens is
        # VOID, retried with fresh NVRAM; a kernel that took control and died before its banner FAILS at once.
        _try=1; QPID=""
        while :; do
            cp "$R3_OVMF_VARS" "$WORK/vars-r.fd"; chmod +w "$WORK/vars-r.fd"; : > "$LOG"; rm -f "$MON"
            # shellcheck disable=SC2086
            qemu-system-x86_64 -machine q35 -m 512M $ACC -smp "$smp" \
                -drive "if=pflash,format=raw,readonly=on,file=$R3_OVMF_CODE" \
                -drive "if=pflash,format=raw,file=$WORK/vars-r.fd" \
                -drive "file=$WORK/R-$smp.img,format=raw,if=none,id=disk0" \
                -device "nvme,drive=disk0,serial=AGNOS-FGR" \
                -device "qemu-xhci,id=xhci" -device "usb-kbd,bus=xhci.0" \
                -serial "file:$LOG" -display none -no-reboot \
                -monitor "unix:$MON,server,nowait" &
            QPID=$!
            _w=0
            while [ "$_w" -lt 240 ]; do
                sleep 0.5; _w=$((_w + 1))
                grep -aq "AGNOS kernel v" "$LOG" 2>/dev/null && break
                grep -aqE "gnoboot: fail @|BootManagerMenuApp|BdsDxe: failed to load" "$LOG" 2>/dev/null && break
                kill -0 "$QPID" 2>/dev/null || break
            done
            grep -aq "AGNOS kernel v" "$LOG" 2>/dev/null && break
            kill "$QPID" 2>/dev/null || true; wait "$QPID" 2>/dev/null || true; QPID=""
            if qemu_attempt_verdict "$LOG" "$_try"; then break; fi
            if [ "$_try" -ge "${QEMU_TRIES:-6}" ]; then qemu_assert_booted "$LOG" || true; break; fi
            _try=$((_try + 1))
        done
        if [ -z "$QPID" ]; then echo "  VOID: -smp $smp recovery boot never handed off"; void=$((void + 1)); continue; fi
        python3 -u - "$MON" "$LOG" "$smp" <<'PY'
import socket, sys, time, re
mon, log, smp = sys.argv[1], sys.argv[2], sys.argv[3]
fails = 0
def verdict(ok, what):
    global fails
    print(("  PASS: " if ok else "  FAIL: ") + f"[smp{smp}] recovery: " + what, flush=True)
    if not ok: fails += 1
def raw():
    try:
        with open(log, 'rb') as f: return f.read().decode('latin1')
    except OSError: return ''
def clean(t):
    # the orphan writer's whole `ow\n` lines interleave with everything; drop them before any match
    return t.replace('\r', '').replace('ow\n', '')
def wait_re(pat, mark, timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        m = re.search(pat, clean(raw()[mark:]))
        if m: return m
        time.sleep(0.25)
    return None
t0 = time.time()
while time.time() - t0 < 120:
    if 'agnos>' in raw(): break
    time.sleep(0.5)
verdict('kybernet: emergency shell (exec rc=3)' in raw(), "kybernet: emergency shell (exec rc=3) (/bin/agnsh exited 3)")
if 'agnos>' not in raw():
    verdict(False, "the recovery prompt agnos> never appeared"); sys.exit(1)
s = None
for _ in range(80):
    try:
        s = socket.socket(socket.AF_UNIX); s.connect(mon); break
    except OSError: time.sleep(0.25)
if s is None: verdict(False, "no QEMU monitor"); sys.exit(1)
s.settimeout(1.0)
def drain():
    try:
        while True:
            if s.recv(65536) == b'': return
    except OSError: pass
KM = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '/': 'slash'}
def key(name):
    try: s.sendall(('sendkey ' + name + '\n').encode())
    except OSError: return
    time.sleep(0.10); drain()
def typ(word):
    key('ret')                          # prime: the first sendkey after an idle gap is dropped (xHCI HID warmup)
    for ch in word: key(KM.get(ch, ch))
    key('ret')
def type_verified(word):
    for attempt in range(4):
        mark = len(raw())
        typ(word)
        time.sleep(1.0)
        if word in clean(raw()[mark:]): return mark
        print(f'  retry: {word!r} did not echo cleanly (attempt {attempt + 1}, dropped key)', flush=True)
    return -1
def run(cmd, pat, timeout, what):
    time.sleep(0.8); drain()
    mark = type_verified(cmd)
    if mark < 0: verdict(False, f"could not type {cmd!r}"); return None
    m = wait_re(pat, mark, timeout)
    verdict(m is not None, what + ('' if m else f' (no {pat!r} within {timeout}s)'))
    return m
m0 = run('run /bin/fgc memfree', r'FG-MEMFREE (\d+)', 15, 'memfree M0')
M0 = int(m0.group(1)) if m0 else 0
run('run /bin/fgc exit 7', r'run: exit 7(?!\d)', 15, 'run /bin/fgc exit 7 -> run: exit 7')
run('run /bin/fgc tickself 400', r'run: exit 0(?!\d)', 15, 'tickself: a kmain `run` child accrues ticks (run: exit 0)')
run('run /bin/fgc fault', r'run: exit 142(?!\d)', 15, 'fault: run: exit 142')
run('run /bin/fgc exit 7', r'run: exit 7(?!\d)', 15, 'after the fault kmain resumed and the slot was reaped (run: exit 7)')
run('run /bin/fgc orphanwrite', r'run: exit 0(?!\d)', 15, 'orphanwrite: run: exit 0 (the writer lives on)')
run('help', r'agnos>', 15, 'help while the orphan writes')
run('run /bin/fgc exit 7', r'run: exit 7(?!\d)', 15, 'run with an orphan writing concurrently (run: exit 7)')
time.sleep(6.0)                                        # the writer's 5 s run ends
for i in range(5):
    run('run /bin/fgc storm', r'run: exit 11(?!\d)', 15, f'storm {i + 1}/5 (run: exit 11)')
    time.sleep(1.5)                                    # the churners' 800 ms run ends before the next storm
m1 = run('run /bin/fgc memfree', r'FG-MEMFREE (\d+)', 15, 'memfree M1')
M1 = int(m1.group(1)) if m1 else 0
lost = M0 - M1
print(f'  report: [smp{smp}] recovery free RAM M0={M0} M1={M1} lost={lost} per_orphan={lost // 6} (6 orphans: 5 hubs + 1 writer)', flush=True)
# The bound: 6 orphans (5 hubs + 1 writer; nothing reaps an orphan before the lifecycle step, S7 §2.4) x one orphan's
# address space = 3 x 2 MiB huge pages (code, data, stack) + its 3 page-table pages + its 1 KiB fd table. MEASURED at
# S3b-F0 (pre-conversion kernel): 6,305,109 B per orphan — 6 MiB + 13.6 KiB, i.e. just OVER a flat 6 MiB. The bound
# is therefore stated as 6 MiB + 64 KiB per orphan (the page-table pages were not in the spec's round figure; raised
# openly and recorded in the S3b report, never silently). S7 tightens this to <= 1 MB once orphans self-reap.
verdict(m0 is not None and m1 is not None and lost <= 6 * (6 * 1048576 + 65536), f'free RAM: M0 - M1 = {lost} <= 6 orphans x (6 MiB + 64 KiB)')
try: s.sendall(b'quit\n')
except OSError: pass
sys.exit(1 if fails else 0)
PY
        prc=$?
        kill "$QPID" 2>/dev/null || true; wait "$QPID" 2>/dev/null || true
        if [ "$prc" -eq 0 ]; then ok "[smp$smp] recovery driver: every step PASS"; else bad "[smp$smp] recovery driver reported FAIL (see above; log $LOG)"; fi
        deny "PANIC"                    "[smp$smp] recovery: no PANIC line"
        deny "$SMOKE_INVARIANT_DENY"    "[smp$smp] recovery: no latched kernel invariant line (the shared SMOKE_INVARIANT_DENY)"
    done
}

for mode in $MODES; do
    case "$mode" in
        default)  run_default ;;
        recovery) run_recovery ;;
    esac
done

echo ""
echo "=== fg-smoke: $pass passed, $fail failed, $void void ==="
if [ "$fail" -ne 0 ]; then echo "fg-smoke: FAIL"; exit 1; fi
if [ "$void" -ne 0 ]; then echo "fg-smoke: VOID (a boot never handed off — infrastructure, not the kernel)"; exit 2; fi
echo "fg-smoke: PASS"
exit 0
