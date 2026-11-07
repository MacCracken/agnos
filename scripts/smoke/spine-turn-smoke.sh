#!/bin/bash
# spine-turn-smoke — a real agentic turn on agnos: thoth, hoosh and daimon on one image, a model on the host.
#
# basestack-run-smoke proves a binary loads and prints its version in ring 3. This is the rung above it: the consumer
# drives the spine, native, on the real kernel, end to end. tests/spine-turn/launcher.cyr, seeded as /bin/agnsh on a
# PLAIN kernel, starts hoosh and daimon as background processes and runs three one-shot thoth turns:
#   1  a plain reply: thoth -> hoosh on loopback -> a provider on the host, over QEMU's network -> SSE back to thoth.
#      daimon's manifest is read too, and thoth has no pin store yet, so it writes one on ext2 from daimon's record.
#   2  a tool round: the model calls daimon's libro_verify, t-ron allows it, daimon runs it, and the result reaches
#      the model on the next round. Read off the provider's log, so it is what the wire carried and not what thoth said.
#   3  --json, on a store that now exists: it must load, so nothing more is taken from daimon.
# The provider is thoth's scripts/live/stubhoosh.py on the host (the guest sees the host's loopback as 10.0.2.2), which
# answers by prompt. A real provider is not the point: every byte of what is being tested stays on the guest's side of it.
#
# Usage:   scripts/smoke/spine-turn-smoke.sh
#   Needs the three --agnos binaries, which this reads and never builds (a smoke does not build in a sibling):
#     HOOSH_BIN   default <hoosh>/build/hoosh_agnos    cyrius build --agnos src/main.cyr build/hoosh_agnos   (in hoosh)
#     DAIMON_BIN  default <daimon>/build/daimon_agnos  cyrius build --agnos src/main.cyr build/daimon_agnos  (in daimon)
#     THOTH_BIN   default <thoth>/build/thoth_agnos    scripts/build.sh agnos                                (in thoth)
#   thoth's scripts/agnos-run.sh --turn builds all three in copies and calls this.
# Env: SPINE_KERNEL (a prebuilt kernel, skips the build), STUB_PROVIDER (the host-side provider), QEMU_TIMEOUT (default
#      180), SIBLINGS_ROOT, HOOSH_ROOT, DAIMON_ROOT, THOTH_ROOT, R3_ACCEL.
# Exit 0 only when every gate passes; 1 a gate failed; 2 the kernel never started (firmware VOID, nothing was run).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

HOOSH_BIN="${HOOSH_BIN:-${HOOSH_ROOT:-${SIBLINGS_ROOT:-$ROOT/..}/hoosh}/build/hoosh_agnos}"
DAIMON_BIN="${DAIMON_BIN:-${DAIMON_ROOT:-${SIBLINGS_ROOT:-$ROOT/..}/daimon}/build/daimon_agnos}"
THOTH_BIN="${THOTH_BIN:-${THOTH_ROOT:-${SIBLINGS_ROOT:-$ROOT/..}/thoth}/build/thoth_agnos}"
STUB_PROVIDER="${STUB_PROVIDER:-${THOTH_ROOT:-${SIBLINGS_ROOT:-$ROOT/..}/thoth}/scripts/live/stubhoosh.py}"

echo "=== spine turn smoke (thoth, hoosh and daimon on one image, a turn to a model on the host) ==="
ring3_seed_init || exit 1
for t in cyrius python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "  ERROR: $t not found — this gate measured NOTHING"; exit 1; }
done
for b in "$HOOSH_BIN" "$DAIMON_BIN" "$THOTH_BIN" "$STUB_PROVIDER"; do
    [ -f "$b" ] || { echo "  ERROR: $b not found — this gate measured NOTHING (the header says how to build it)"; exit 1; }
done

WORK="$ROOT/build/spine-turn-smoke"; LOGS="$ROOT/build/spine-turn-smoke-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

if [ -n "${SPINE_KERNEL:-}" ]; then
    KERNEL="$SPINE_KERNEL"
    echo "Using the PREBUILT kernel $KERNEL."
else
    echo "Building the PLAIN kernel..."
    sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
    KERNEL="$WORK/agnos-plain"
    cp "$ROOT/build/agnos" "$KERNEL"
fi
echo "Building tests/spine-turn/launcher (--agnos)..."
( cd "$ROOT/tests/spine-turn" && cyrius build --agnos launcher.cyr "$WORK/launcher" ) > "$LOGS/launcher-build.log" 2>&1 \
    || { echo "  ERROR: launcher build failed (see $LOGS/launcher-build.log)"; exit 1; }

# The provider, on a port nothing else holds: a sweep worker may run this beside another tree's copy.
PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
PROVIDER_LOG="$LOGS/provider.log"
python3 -I -u "$STUB_PROVIDER" "$PORT" > "$PROVIDER_LOG" 2>&1 &
PROVIDER=$!
trap 'kill "$PROVIDER" 2>/dev/null' EXIT

SEED="$WORK/seed"; mkdir -p "$SEED/bin" "$SEED/etc" "$SEED/d" "$SEED/.thoth"
cp "$WORK/launcher" "$SEED/bin/agnsh"
cp "$HOOSH_BIN" "$SEED/bin/hoosh"
cp "$DAIMON_BIN" "$SEED/bin/daimon"
cp "$THOTH_BIN" "$SEED/bin/thoth"
cat > "$SEED/etc/hoosh.cyml" <<CFG
[server]
bind = "127.0.0.1"
port = 8088
strategy = "priority"
health_check_interval_secs = 0

[[providers]]
type = "OpenAi"
base_url = "http://10.0.2.2:$PORT"
api_key = "smoke"
priority = 1
models = ["stub*"]
catalog = "static"
CFG
cat > "$SEED/etc/tron-policy.toml" <<'CFG'
[agent."thoth"]
allow = ["libro_verify"]

[agent."thoth".rate_limit]
calls_per_minute = 120
CFG
cat > "$SEED/.thoth/config.cyml" <<'CFG'
[hoosh]
url = "http://127.0.0.1:8088"
model = "stub-model"
stream = true
timeout_ms = 15000

[daimon]
url = "http://127.0.0.1:8090"

[tron]
policy = "/etc/tron-policy.toml"
agent = "thoth"
CFG
ring3_seed_image "$WORK/S.img" "$KERNEL" "$SEED" "AGNOS-SPINE" || { echo "  ERROR: image"; exit 1; }

# A >15 MB load under TCG is slow, and nothing here is about the CPU model.
R3_ACCEL="${R3_ACCEL:-$(smoke_accel 2)}"; export R3_ACCEL
echo "  accel: $R3_ACCEL"
LOG="$LOGS/spine-turn.log"
ring3_seed_boot "$WORK/S.img" "$LOG" "SPINE-TURN DONE" "${QEMU_TIMEOUT:-180}" "$WORK" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0
booted=$?
[ "$booted" -eq 2 ] && { echo "spine-turn-smoke: VOID — the kernel never started, nothing was run"; exit 2; }
sleep 0.2

echo ""
echo "  --- the guest's console ---"
strings "$LOG" | grep -E '^SPINE|^TURN |hello from stub|^done$|"response"|taken from daimon|the gateway|hoosh gateway|#PF|PANIC|^fault:' | sed 's/^/  /' | cut -c1-170
echo "  --- what reached the provider ---"
grep -E '^POST|^TOOLRESULT' "$PROVIDER_LOG" | sed 's/^/  /' | cut -c1-120
echo ""

rc=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; rc=1; }
turn_ok() { strings "$LOG" | grep -q "^TURN $1 exit 0"; }

# Gate 1: a turn crossed the guest, out to the host and back.
if ! grep -q '^POST /v1/chat/completions stream True' "$PROVIDER_LOG"; then
    fail "no request reached the provider — hoosh did not forward a turn (a listening hoosh that never reads its socket looks like this)"
elif turn_ok 1 && strings "$LOG" | grep -q 'hello from stub'; then
    pass "turn 1: thoth -> hoosh -> the host's provider -> a streamed reply on the console, exit 0"
else
    fail "turn 1: the provider was asked, and no reply reached thoth's stdout with exit 0"
fi
# Gate 2: the tool round, read off the wire.
if turn_ok 2 && grep -q '^TOOLRESULT {"ok":true}' "$PROVIDER_LOG" && strings "$LOG" | grep -q '^done$'; then
    pass "turn 2: libro_verify ran through t-ron and daimon, and its result reached the model"
else
    fail "turn 2: the tool round did not complete"
fi
# Gate 3: the machine channel, and a store that outlives a run.
if turn_ok 3 && strings "$LOG" | grep -q '"response":"hello from stub"'; then
    pass "turn 3: --json printed its object"
else
    fail "turn 3: no --json object"
fi
taken="$(strings "$LOG" | grep -c "taken from daimon's record")"
if [ "$taken" -eq 1 ]; then
    pass "the pin store written on ext2 by turn 1 loaded on the turns after it"
else
    fail "expected one run to take pins from daimon's record, saw $taken"
fi
# Gate 4: the box survived.
if strings "$LOG" | grep -qE '#PF|PANIC|^fault:'; then
    fail "a fault/panic marker appeared:"
    strings "$LOG" | grep -E '#PF|PANIC|^fault:|CR2|RIP' | sed 's/^/        /' | head
else
    pass "no fault/panic"
fi

echo ""
if [ "$rc" = 0 ]; then
    echo "spine-turn-smoke: PASS — a real turn ran on agnos, through hoosh and daimon"
else
    echo "spine-turn-smoke: FAIL (serial: $LOG; provider: $PROVIDER_LOG)"
fi
exit $rc
