#!/bin/sh
# pipeline-smoke.sh — 1.57.9 ENDFIX (end review PIPEW-E1): does an agnsh PIPELINE whose consumer stops reading early
# still return to the prompt, now that a pipe write BLOCKS (PIPEW, issue 2026-09-25-pipe-writes-do-not-block)?
#
# THE DEFECT CLASS (bash execute_cmd.c execute_pipeline, verbatim: "the read end of the pipe (fildes[0]) stays open in
# the first process, so that process will never get a SIGPIPE … there is still a file descriptor open for reading
# connected to the pipe"). A pipe writer whose ring is full blocks while ANY read end is open anywhere (Linux
# anon_pipe_write, FreeBSD pipe_write, agnos wr1_wait). If the shell keeps its own read-end copy while it waits to
# reap stage 1, or stage 1 inherited the read end, a consumer that exits early leaves stage 1 blocked forever and the
# shell waiting on it forever. Before PIPEW a full ring returned 0: a cyrius stdlib writer (one sys_write, no retry)
# dropped the rest and exited, so ITS pipelines completed (after PIPEW they hang whenever the 3-argument sys_write's
# leftover r10 (a4) is 0); kriya's grep/echo retry a short write up to 20,000 #44 passes, so with PIPEW reverted this
# smoke is RED too (measured 1.57.9 ENDFIX: no prompt in 40 s at -smp 1 and 4). The fix belongs to the shell (bash's fds_to_close; in agnos: spawn each stage with
# SPAWN_F_CLEANFD and close rfd after stage 2 is spawned / before reaping stage 1) — handoff-1.57.9/steps/
# ENDFIX-prior-art.md. agnos cannot edit agnoshi; this gate says whether the SHIPPED agnsh is safe.
#
# PLAIN kernel; the staged rootfs (build/rootfs: agnsh, kriya's grep/echo, /etc/ssl/cert.pem = 185 KB) plus
# /bin/notelf (a text file: it passes agnsh's stage probe and fails spawn_path#43 with NOEXEC). usb-kbd + HMP monitor;
# an embedded driver types (sendkey, shutdown-smoke's typ/type_verified) and requires the [ASSIST] prompt back:
# One boot per case (a stuck shell must not hide the next case); each boot first runs
#   ctl    `echo pipectl`                               — the driver can type and the prompt returns (a harness check)
#   early  `grep . /etc/ssl/cert.pem | echo pipeearly`  — stage 1 writes 185 KB, stage 2 never reads and exits
#   s2fail `grep . /etc/ssl/cert.pem | notelf`          — stage 2's spawn FAILS; the shell reaps stage 1 (the
#                                                          stage-2-failure path, which reaps while holding rfd)
# each within PIPE_SMOKE_WAIT seconds (default 40; a healthy run takes ~1-3 s). Boots -smp 1 (-cpu max) then -smp 4
# (smoke_accel), both gated; every boot banner-gated (no "AGNOS kernel v" = VOID, retried with fresh NVRAM, never
# scored). DENIES PANIC and SMOKE_INVARIANT_DENY.
# Env: PIPE_SMOKE_SMP (default "1 4"), PIPE_SMOKE_WAIT, PIPE_SMOKE_AGNSH=<agnos-ABI agnsh> (seed THIS agnsh instead of
# build/rootfs/bin/agnsh — how the proposed agnoshi patch was proven GREEN from a scratch copy), PIPE_SMOKE_KERNEL
# (a prebuilt kernel). Exit 0 PASS · 1 FAIL · 2 VOID. Leaves a PLAIN build/agnos.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== pipeline smoke (agnsh pipelines whose consumer stops early return to the prompt) ==="
ring3_seed_init || exit 1
command -v python3 >/dev/null 2>&1 || { echo "  ERROR: python3 missing — this gate measured NOTHING"; exit 1; }
ROOTFS="$ROOT/build/rootfs"
AGNSH="${PIPE_SMOKE_AGNSH:-$ROOTFS/bin/agnsh}"
[ -f "$AGNSH" ] || { echo "  ERROR: $AGNSH missing — run scripts/burn/stage-agnsh.sh --build"; exit 1; }
[ -e "$ROOTFS/bin/grep" ] && [ -e "$ROOTFS/bin/echo" ] || { echo "  ERROR: kriya grep/echo not staged — run scripts/burn/stage-tools.sh --build"; exit 1; }
[ -f "$ROOTFS/etc/ssl/cert.pem" ] || { echo "  ERROR: $ROOTFS/etc/ssl/cert.pem missing — the producer needs > 4080 B"; exit 1; }

WORK="$ROOT/build/pipeline-smoke"; LOGS="$ROOT/build/pipeline-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"
if [ -n "${PIPE_SMOKE_KERNEL:-}" ]; then
    KERNEL="$PIPE_SMOKE_KERNEL"; echo "Using the PREBUILT kernel $KERNEL."
else
    echo "Building the PLAIN kernel..."
    sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
    KERNEL="$WORK/agnos-plain"; cp "$ROOT/build/agnos" "$KERNEL"
fi
SEED="$WORK/seed"; mkdir -p "$SEED/bin" "$SEED/etc"
cp -a "$ROOTFS/bin/." "$SEED/bin/"
cp -f "$AGNSH" "$SEED/bin/agnsh"; chmod +x "$SEED/bin/agnsh"
cp -a "$ROOTFS/etc/." "$SEED/etc/"
printf 'not an ELF: stage 2 of the pipeline smoke must fail to spawn\n' > "$SEED/bin/notelf"; chmod +x "$SEED/bin/notelf"
echo "  agnsh: $AGNSH ($(md5sum < "$SEED/bin/agnsh" | cut -c1-12))"
ring3_seed_image "$WORK/P.img" "$KERNEL" "$SEED" "AGNOS-PIPE" || { echo "  ERROR: image"; exit 1; }

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

# ONE BOOT PER CASE: a case that hangs leaves the shell stuck, and the next case must still be measured.
for smp in ${PIPE_SMOKE_SMP:-1 4}; do
  for pcase in early s2fail; do
    LOG="$LOGS/pipeline-$pcase-smp$smp.log"; MON="$WORK/mon-$smp.sock"
    if [ "$smp" -gt 1 ]; then ACC="$(smoke_accel "$smp")"; else ACC="-cpu max"; fi
    echo ""
    echo "Boot -smp $smp  case $pcase  accel: $ACC"
    cp "$WORK/P.img" "$WORK/P-$smp.img"
    # Banner-gated retry BEFORE the driver (fg-smoke's recovery loop): no banner = VOID, retried with fresh NVRAM.
    _try=1; QPID=""
    while :; do
        cp "$R3_OVMF_VARS" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"; : > "$LOG"; rm -f "$MON"
        # shellcheck disable=SC2086
        qemu-system-x86_64 -machine q35 -m 512M $ACC -smp "$smp" \
            -drive "if=pflash,format=raw,readonly=on,file=$R3_OVMF_CODE" \
            -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
            -drive "file=$WORK/P-$smp.img,format=raw,if=none,id=disk0" \
            -device "nvme,drive=disk0,serial=AGNOS-PIPE" \
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
    if [ -z "$QPID" ]; then echo "  VOID: -smp $smp ($pcase) never handed off"; void=$((void + 1)); continue; fi
    python3 -u - "$MON" "$LOG" "$smp" "${PIPE_SMOKE_WAIT:-40}" "$pcase" <<'PY'
import socket, sys, time
mon, log, smp, wait_s, pcase = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
fails = 0
def verdict(ok, what):
    global fails
    print(("  PASS: " if ok else "  FAIL: ") + f"[smp{smp}] " + what, flush=True)
    if not ok: fails += 1
def raw():
    try:
        with open(log, 'rb') as f: return f.read().decode('latin1').replace('\r', '')
    except OSError: return ''
t0 = time.time()
while time.time() - t0 < 120:
    if '[ASSIST]' in raw(): break
    time.sleep(0.5)
if '[ASSIST]' not in raw():
    verdict(False, "agnsh never reached its [ASSIST] prompt"); sys.exit(1)
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
KM = {' ': 'spc', '\n': 'ret', '-': 'minus', '.': 'dot', '/': 'slash', '|': 'shift-backslash'}
def key(name):
    try: s.sendall(('sendkey ' + name + '\n').encode())
    except OSError: return
    time.sleep(0.10); drain()
def typ(word):
    key('ret')                          # prime: the first sendkey after an idle gap is dropped (xHCI HID warmup)
    for ch in word: key(KM.get(ch, ch))
    key('ret')
# Type `line`; the echo must appear (a dropped key retypes — a garbled line fails its stage probe and returns at
# once, so a retry never leaves a pipeline behind). Returns the log offset just past the echoed line, or -1.
def type_line(line):
    for attempt in range(4):
        mark = len(raw())
        typ(line)
        time.sleep(0.8)
        t = raw()
        i = t.find(line, mark)
        if i >= 0: return i + len(line)
        print(f'  retry: {line!r} did not echo cleanly (attempt {attempt + 1}, dropped key)', flush=True)
        time.sleep(3.0)
    return -1
def case(name, line, what):
    time.sleep(1.0); drain()
    at = type_line(line)
    if at < 0: verdict(False, f"{name}: could not type {line!r}"); return False
    ts = time.time()
    while time.time() - ts < wait_s:
        if '[ASSIST]' in raw()[at:]:
            verdict(True, f"{name}: {what} — the prompt came back in {time.time() - ts:.1f} s")
            return True
        time.sleep(0.25)
    verdict(False, f"{name}: {what} — NO PROMPT within {wait_s} s (the shell is stuck; see the log tail)")
    return False
if case('ctl', 'echo pipectl', 'a plain command (harness check)'):
    if pcase == 'early':
        case('early', 'grep . /etc/ssl/cert.pem | echo pipeearly',
             'a 185 KB producer into a consumer that never reads')
    else:
        case('s2fail', 'grep . /etc/ssl/cert.pem | notelf',
             'stage 2 fails to spawn; the shell reaps stage 1')
try: s.sendall(b'quit\n')
except OSError: pass
sys.exit(1 if fails else 0)
PY
    prc=$?
    kill "$QPID" 2>/dev/null || true; wait "$QPID" 2>/dev/null || true
    if [ "$prc" -eq 0 ]; then ok "[smp$smp] $pcase: the driver saw the prompt come back"; else bad "[smp$smp] $pcase: driver reported FAIL (log $LOG)"; strings "$LOG" | tail -6 | sed 's/^/        /'; fi
    deny "PANIC"                 "[smp$smp] $pcase: no PANIC line"
    deny "$SMOKE_INVARIANT_DENY" "[smp$smp] $pcase: no latched kernel invariant line (the shared SMOKE_INVARIANT_DENY)"
  done
done

[ -z "${PIPE_SMOKE_KERNEL:-}" ] || sh "$ROOT/scripts/build.sh" >/dev/null 2>&1
echo ""
echo "=== pipeline-smoke: $pass passed, $fail failed, $void void ==="
if [ "$fail" -ne 0 ]; then echo "pipeline-smoke: FAIL"; exit 1; fi
if [ "$void" -ne 0 ]; then echo "pipeline-smoke: VOID (a boot never handed off — infrastructure, not the kernel)"; exit 2; fi
echo "pipeline-smoke: PASS"
exit 0
