#!/bin/bash
# sock-owner-smoke — agnos 1.57.7 step S5: socket ownership (TCP + UDP), held dead-connection slots, the
# loopback-only listen class, 127/8 + net_ip TCP admission, the wire martian filter and sock_peer#106.
#
# Issues: docs/development/issues/2026-09-23-socket-ids-have-no-owner.md,
#         docs/development/issues/2026-09-23-tcp-server-cannot-be-loopback-only.md.
# Design: docs/architecture/socket-ownership-and-loopback.md.
#
#   static  net_rx_drain's body calls net_wire_frame(&net_rx_pkt ...) exactly once and net_demux_frame never
#           (the martian filter is the ONLY wire entry)
#   boot A  TCP_ADDR_SELFTEST=1 kernel: the IF=0 kernel arms (`tcpaddr:` / `udpown:` lines, ids below); the flag
#           image must pass scripts/check/image-layout-check.sh first (not booted otherwise)
#   boot B  PLAIN kernel, -smp 1: tests/sock/sockown seeded as /bin/agnsh (D19), the SOCK-* markers
#   boot C  PLAIN kernel, -smp 4 under smoke_accel (KVM if /dev/kvm is writable, else tcg,thread=multi) — GATED
# Kernel arm ids (kernel/core/net_tcp.cyr tcp_addr_selftest):
#   O0 owner stamp on a LISTEN (kernel LISTEN = tag 0)      A6  passive child inherits the listener's stamp + lip
#   A9 tcp_auth incarnation (epoch bump, stranger, tag 0)    A12 Q1 held slot vs an unaccepted passive child
#   A12b passive-reserve counts reusable slots only          A15 release_if by gen + the unstamping release tail
#   A13 live duplicate 4-tuple refused                       A14 the gen alone is part of the snapshot (owned + tag 0)
#   A7a release_pid is epoch-aware                           A7c LISTEN close reaps its child = released, not held
#   A7b death releases held/listen/child slots, pool kept    A1  wire SYN to 127/8 = martian
#   A2 lo-only admits 127/8 (child speaks from 127.0.0.1)    A6c dial 127.0.0.2 is answered FROM 127.0.0.2
#   A6d the same tuple to 127.0.0.3 is a NEW child (the demux keys on the local address, +168; ENDFIX S5-R1)
#   A3a lo-only refuses a SYN to net_ip (in the claim)       A3b the same bytes to an ANY listener are admitted
#   A4 broadcast dst refused by the TCP gate                 A5a/A5b/A5d wire src 127/8, own address, >= 224
#   A5c a legit wire SYN still passes                        A2z closing LO reaps its children
#   A10 a non-owner's VFS_SOCK fd is inert                   A16 accept returns only listener-stamped children
#   A8 sock_peer encoding + owner check                      U1 UDP stamp + udp_auth   U2 lo #52 frame length + take
#   U3 #52 source-port rule                                  U4 udp_release_pid (pool kept, kernel port untouched)
# Exit 0 = every check of every boot PASSED; 1 = any FAIL; 2 = a boot never booted (firmware VOID).
# Env: SOCK_SMP (default "1 4") selects the ring-3 boots; SOCK_KERNEL=<path> uses a prebuilt kernel for B/C and
#      skips A and the image check (the falsification hook); QEMU_TRIES; QEMU_TIMEOUT (default 300).
# Leaves a PLAIN build in build/agnos.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== sock-owner smoke (socket ownership, lo-only listen, 127/8, sock_peer#106, UDP ownership) ==="
ring3_seed_init || exit 1
command -v cyrius >/dev/null 2>&1 || { echo "  ERROR: cyrius not found — this gate measured NOTHING"; exit 1; }

WORK="$ROOT/build/sock-owner"; LOGS="$ROOT/build/sock-owner-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK" "$LOGS"

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
want() { if strings "$LOG" | grep -qE -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
deny() { if strings "$LOG" | grep -qE -- "$1"; then bad "$2"; strings "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

# ── static wiring: the martian filter is the ONLY wire entry ──
echo ""
echo "Static: net_rx_drain wiring"
BODY="$(awk '/^fn net_rx_drain\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$ROOT/kernel/core/net_ingress.cyr")"
NW="$(printf '%s\n' "$BODY" | grep -c 'net_wire_frame(&net_rx_pkt')"
ND="$(printf '%s\n' "$BODY" | grep -c 'net_demux_frame(')"
if [ "$NW" = "1" ] && [ "$ND" = "0" ]; then ok "net_rx_drain calls net_wire_frame once, net_demux_frame never"
else bad "net_rx_drain wiring (net_wire_frame=$NW net_demux_frame=$ND)"; fi

NETDEV="-netdev user,id=u1 -device virtio-net-pci,netdev=u1"

# ── boot A: the kernel arms ──
if [ -z "${SOCK_KERNEL:-}" ]; then
    echo ""
    echo "Boot A: TCP_ADDR_SELFTEST=1 kernel arms"
    TCP_ADDR_SELFTEST=1 sh "$ROOT/scripts/build.sh" > "$LOGS/build-A.log" 2>&1 || { echo "  ERROR: flag build failed (see $LOGS/build-A.log)"; exit 1; }
    cp "$ROOT/build/agnos" "$WORK/agnos-A"
    IMGCHK="$(sh "$ROOT/scripts/check/image-layout-check.sh" "$WORK/agnos-A" 2>&1)"; irc=$?
    echo "  image-layout (flag): $IMGCHK"
    if [ "$irc" -ne 0 ]; then
        bad "flag image over the image-layout bound (boot A NOT booted)"
    else
        ok "flag image within the image-layout bound"
        mkdir -p "$WORK/seedA/bin"
        ring3_seed_image "$WORK/A.img" "$WORK/agnos-A" "$WORK/seedA" "AGNOS-SOCKA" || { echo "  ERROR: image A"; exit 1; }
        LOG="$LOGS/boot-A.log"; : > "$LOG"
        R3_ACCEL="-cpu max"; export R3_ACCEL
        ring3_seed_boot "$WORK/A.img" "$LOG" "tcpaddr: DONE" 120 "$WORK" $NETDEV
        brc=$?
        if [ "$brc" -eq 2 ]; then
            echo "  VOID: boot A never booted"; void=$((void + 1))
        else
            strings "$LOG" | grep -E "tcpaddr:|udpown:" | sed 's/^/    /'
            for id in O0 A6 A9 A12 A12b A15 A13 A14 A7a A7c A7b A1 A2 A6c A6d A3a A3b A4 A5a A5b A5d A5c A2z A10 A16 A8 Z; do
                want "tcpaddr: $id OK" "[A] tcpaddr $id"
            done
            for id in U1 U2 U3 U4; do want "udpown: $id OK" "[A] udpown $id"; done
            want "tcpaddr: ALL OK"                     "[A] all kernel arms passed"
            want "tcpaddr: DONE"                       "[A] block ran to its end"
            deny "tcpaddr: .*FAIL|udpown: .*FAIL"      "[A] no FAIL arm"
            deny "$SMOKE_INVARIANT_DENY"               "[A] no latched invariant (incl. net: lock overlap/missing)"
        fi
    fi
fi

# ── boots B / C: ring 3 on a PLAIN kernel ──
if [ -n "${SOCK_KERNEL:-}" ]; then
    KERNEL="$SOCK_KERNEL"
    echo ""
    echo "Using the PREBUILT kernel $KERNEL (the falsification hook) — boot A and the image check skipped."
else
    echo ""
    echo "Building the PLAIN kernel..."
    sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
    KERNEL="$WORK/agnos-plain"
    cp "$ROOT/build/agnos" "$KERNEL"
fi
# ⛔ REBUILD THE TEST PROGRAM EVERY RUN (the stale-artifact lesson).
echo "Building tests/sock/sockown (--agnos)..."
( cd "$ROOT/tests/sock" && cyrius build --agnos sockown.cyr build/sockown ) > "$LOGS/sockown-build.log" 2>&1 \
    || { echo "  ERROR: sockown build failed (see $LOGS/sockown-build.log)"; exit 1; }
mkdir -p "$WORK/seed/bin"
cp "$ROOT/tests/sock/build/sockown" "$WORK/seed/bin/agnsh"
ring3_seed_image "$WORK/B.img" "$KERNEL" "$WORK/seed" "AGNOS-SOCK" || { echo "  ERROR: image B"; exit 1; }

for smp in ${SOCK_SMP:-1 4}; do
    LOG="$LOGS/sock-smp$smp.log"; : > "$LOG"
    R3_ACCEL="$(smoke_accel "$smp")"; export R3_ACCEL
    P="[smp$smp]"
    echo ""
    echo "Boot $P: -smp $smp  accel: $R3_ACCEL"
    cp "$WORK/B.img" "$WORK/B-$smp.img"
    ring3_seed_boot "$WORK/B-$smp.img" "$LOG" "SOCKOWN-DONE" "${QEMU_TIMEOUT:-300}" "$WORK" -smp "$smp" $NETDEV
    brc=$?
    if [ "$brc" -eq 2 ]; then echo "  VOID: $P never booted"; void=$((void + 1)); continue; fi
    strings "$LOG" | grep -E "SOCK|kybernet: (exec|emergency)" | sed 's/^/    /'
    want "kybernet: exec /bin/agnsh"          "$P kybernet launched sockown"
    want "SOCK-CONNFAIL-RELEASED-OK"          "$P H   a failed connect releases its slot"
    want "SOCK-HELD-OK"                       "$P HELD a dead owned conn keeps its id until closed; double close -1"
    want "SOCK-ANY-LO-OK"                     "$P 0   ANY listener reached at 127.0.0.1"
    want "SOCK-DATA-OK"                       "$P 0   data over loopback"
    want "SOCK-CLOSE-FIN-OK"                  "$P 0   close sends FIN (peer reads EOF)"
    want "SOCK-LO8-OK"                        "$P 0   127.0.0.2 completes (answered from the address dialled)"
    want "SOCK-ANY-NETIP-OK"                  "$P 0   ANY listener reached at net_ip"
    want "SOCK-PEER-OK"                       "$P 0   sock_peer#106 on six ids"
    want "SOCK-DUP-REFUSED-OK"                "$P LO  one listener per port whatever the class"
    want "SOCK-LISTEN-BITS-OK"                "$P LO  #56 reserved bits / class > 1 refused"
    want "SOCK-LISTEN-LO-OK"                  "$P LO  a LOOPBACK listener accepts 127.0.0.1"
    want "SOCK-LO-REFUSES-NETIP-OK"           "$P LO  a LOOPBACK listener refuses a dial to net_ip"
    want "SOCK-CHILD-REFUSED-OK"              "$P 1   a fork child is refused on every parent TCP id"
    want "SOCK-CHILD-PEER-REFUSED-OK"         "$P 1   ... and on #106"
    want "SOCK-CHILD-UDP-REFUSED-OK"          "$P 1   ... and on the parent's UDP listener / bound port"
    want "SOCK-CHILD-OWN-TCP-OK"              "$P 1   the child owns its own listener"
    want "SOCK-CHILD-OWN-UDP-OK"              "$P 1   the child owns its own UDP listener"
    want "SOCK-PARENT-INTACT-OK"              "$P 1   the parent's conns are intact after the child"
    want "SOCK-PENDING-KEPT-OK"               "$P 1   the pending child is still acceptable"
    want "SOCK-RELEASE-TCP-OK"                "$P 1   exit released the child's listener"
    want "SOCK-UDP-INTACT-OK"                 "$P 1   the parent's datagram is intact"
    want "SOCK-RELEASE-UDP-OK"                "$P 1   exit released the child's UDP listener"
    want "SOCK-DEATH-FIN-OK"                  "$P 2   a faulting child's connection FINs"
    want "SOCK-FAULT-RELEASE-TCP-OK"          "$P 2   fault released the child's listener"
    want "SOCK-FAULT-RELEASE-UDP-OK"          "$P 2   fault released the child's UDP listener"
    want "SOCKOWN-DONE"                       "$P SOCKOWN-DONE"
    deny "SOCK-FAIL-|SOCK-CHILD-READ-LEAK"    "$P no FAIL / PRECOND / leak marker"
    deny "$SMOKE_INVARIANT_DENY"              "$P no latched invariant (incl. net: lock overlap/missing)"
done

# Leave a PLAIN build (boot A's flag build overwrote build/agnos).
if [ -z "${SOCK_KERNEL:-}" ]; then
    cmp -s "$ROOT/build/agnos" "$WORK/agnos-plain" || sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain-final.log" 2>&1
fi

echo ""
echo "=== sock-owner-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
