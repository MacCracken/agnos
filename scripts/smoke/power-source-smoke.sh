#!/bin/sh
# power-source-smoke — agnos 1.57.18: power_source#114, the boot-time ACPI namespace scan's cached answer, end to end
# on a PLAIN kernel: tests/telemetry/psrc seeded as /bin/agnsh (ring 3, where daimon runs) reads the word and decodes
# it; the kernel's own boot line `power: source <state> (<why>; dsdt D ssdt S battery B absent A ids I ac C) word 0x<w>`
# must agree with it, and both must be the answer the scenario was BUILT for.
#
# Issue: docs/development/issues/archived/2026-11-06-no-way-to-read-the-power-source.md (daimon 2.5.4 — crab's index "pauses
# on battery"). Operator ruling 2026-11-08: a namespace scan, no AML interpreter, no EC driver. The rule (power.cyr
# psrc_scan): no battery declared -> MAINS; every battery's _STA a constant with bit 0 clear -> MAINS; any other
# battery -> CANNOT SAY; no tables / a failed bound check -> CANNOT SAY; an AC adapter alone is reported, never
# decisive -> MAINS. QEMU 11 has no battery device, so every battery here is an SSDT this smoke COMPILES (iasl, into
# its own WORK dir) and hands to the guest with `-acpitable file=`; OVMF installs it beside QEMU's own tables.
#
# Scenarios (one -smp 1 boot each; `q35-smp4` repeats the plain q35 boot at -smp 4, KVM when /dev/kvm is writable):
#   q35            plain QEMU q35: no battery              -> mains (no battery declared)            word 0x1101
#   pc             plain QEMU pc (i440fx, rev-1 FADT)      -> mains (no battery declared)            word 0x1101
#   noacpi         q35,acpi=off: no ACPI tables reach the kernel -> cannot say (no usable ACPI tables)  word 0x0
#   bat            PNP0C0A as EISAID, no _STA              -> cannot say (a battery may be present)  word 0x700
#   bat-str        PNP0C0A as a STRING _HID                -> cannot say                             word 0x700
#   sta0           the battery + Name(_STA, Zero)          -> mains (every battery absent ...)       word 0x1301
#   sta1f          the battery + Method(_STA){Return(0x1F)} -> cannot say                            word 0x700
#   mzero          the battery + Method(_STA, 0, Serialized){Return(Zero)} — PkgLength 0x08, so its bytes also read
#                  as Name(_STA, <0x08>): the method must be stepped over  -> mains                 word 0x1301
#   cid            _HID "AGNS0002", _CID Package{"AGNS0003", EISAID PNP0C0A}, Name(_STA, Zero)
#                                                          -> mains (attributed through _CID)        word 0x1301
#   nest           EC0 (_STA Return(0x0F)) holding BAT0 (Name(_STA, Zero)) -> mains (the nested battery's own
#                  _STA, not its parent's)                                                           word 0x1301
#   store          Name(_STA, Zero) + Method(_INI){Store(0x1F, _STA)} -> cannot say (not a constant) word 0x700
#   mhid           Method(_HID){Return(EISAID PNP0C0A)} + Name(_STA, Zero) -> cannot say (an id no Name(_HID) accounts
#                  for)                                                                              word 0x700
#   ac             ACPI0003 alone                          -> mains, AC bit                          word 0x1901
#   malformed      a non-battery Device whose PkgLength runs past its table's end (checksum re-fixed) -> cannot say
#                  (a table failed a bound check), the boot completes, no fault                      word 0x2100
# Per boot: the kernel line (state, reason, counts, word), the probe's word == the kernel's, PSRC-SUPPORTED,
# PSRC-ARGS-IGNORED (garbage a1..a4), PSRC-CACHED (100,000 calls), PSRC-SHAPE ok, PSRC-DONE; no fault / PANIC / latched
# invariant (SMOKE_INVARIANT_DENY).
# NEGATIVES (1.57.18; each applied to the kernel source, built, booted on the named scenarios, the source restored
# byte-identical against a sha256; every control scenario stayed green). In power.cyr unless named:
#   psrc_id_kind's DWordConst id 0x0A0CD041 -> ...42 (bat, sta0: the battery vanishes -> mains); the string
#   "PNP0C0A" -> "PNP0C0B" (bat-str -> mains); "ACPI0003" -> "ACPI0004" (ac: word 0x1101, the AC bit gone);
#   the Name(_STA) bit test `(v & 1) == 0` -> `== 1` (sta0 -> cannot say); psrc_d_method counting every exact
#   Method(_STA) absent (sta1f -> mains); the exact-method step-over removed (mzero -> cannot say: its 0x08 PkgLength
#   reread as Name(_STA, <0x08>)); the _CID Package walk returning at once (cid -> cannot say); the nested-Device skip
#   removed (nest -> cannot say); the one-"_STA" guard `== 1` -> `>= 1` (store -> mains); the flat-vs-attributed
#   mismatch rule removed (mhid -> mains); the overrun check `dov == 1` -> `== 2` (malformed -> mains); the MAINS
#   gate without `psrc_dsdt == 1` (noacpi -> 0x1001, SHAPE BAD); MAINS never set (q35, pc -> 0x1100); main.cyr calling
#   psrc_report twice ("printed once", q35 and store); in syscall.cyr the #114 arm `+ (arg1 & 1)` (ARGS-READ),
#   `| ((timer_ticks >> 1) & 1) * 0x800` (NOT-CACHED) and `| 0x4000` (SHAPE BAD, ring 3 0x5101 vs the kernel's 0x1101).
#   acpi_init without psrc_clear() is tsc-smoke.sh's T7p (TSC_SELFTEST: `acpi-power: FAIL acpi_init with no RSDP left
#   a stale power-source word`).
# Env: PS_ONLY (an ERE over the scenario names, e.g. 'sta0|mzero'), PS_KERNEL (a prebuilt kernel: the falsification
#      hook, skips the build), QEMU_TIMEOUT (default 240), QEMU_TRIES.
# Exit 0 only when every check of every boot passes; 2 when a boot never reached the kernel (firmware VOID).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/smoke/lib/qemu-dwell.sh"
. "$ROOT/scripts/smoke/lib/ring3-seed.sh"

echo "=== power-source smoke (power_source#114: the ACPI namespace scan's answer) ==="
ring3_seed_init || exit 1
for _t in cyrius iasl python3; do
    command -v "$_t" >/dev/null 2>&1 || { echo "  ERROR: missing tool '$_t' — this gate measured NOTHING"; exit 1; }
done

WORK="$ROOT/build/power-source"; LOGS="$ROOT/build/power-source-logs"
rm -rf "$WORK" "$LOGS"; mkdir -p "$WORK/asl" "$LOGS"

if [ -n "${PS_KERNEL:-}" ]; then
    KERNEL="$PS_KERNEL"
    echo "Using the PREBUILT kernel $KERNEL (the falsification hook)."
else
    echo "Building the PLAIN kernel..."
    sh "$ROOT/scripts/build.sh" > "$LOGS/build-plain.log" 2>&1 || { echo "  ERROR: plain build failed (see $LOGS/build-plain.log)"; exit 1; }
    smoke_require_image "$ROOT/build/agnos" ""
    KERNEL="$WORK/agnos-plain"
    cp "$ROOT/build/agnos" "$KERNEL"
fi
# ⛔ REBUILD THE PROBE EVERY RUN (the stale-artifact lesson), into this smoke's own WORK dir.
echo "Building tests/telemetry/psrc (--agnos)..."
( cd "$ROOT/tests/telemetry" && cyrius build --agnos psrc.cyr "$WORK/psrc" ) > "$LOGS/psrc-build.log" 2>&1 \
    || { echo "  ERROR: psrc build failed (see $LOGS/psrc-build.log)"; exit 1; }
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
cp "$WORK/psrc" "$SEED/bin/agnsh"
ring3_seed_image "$WORK/P.img" "$KERNEL" "$SEED" "AGNOS-PSRC" || { echo "  ERROR: image"; exit 1; }

# ---- the SSDTs, compiled here (iasl) — one DefinitionBlock per scenario ----
ssdt() {   # ssdt <name> <body ASL inside Scope(\_SB)>
    printf 'DefinitionBlock ("", "SSDT", 2, "AGNOS", "PSRC%s", 1)\n{\n    Scope (\\_SB)\n    {\n%s\n    }\n}\n' \
        "$(printf '%s' "$1" | cut -c1-4 | tr 'a-z-' 'A-Z_')" "$2" > "$WORK/asl/$1.asl"
    iasl -p "$WORK/asl/$1" "$WORK/asl/$1.asl" > "$LOGS/iasl-$1.log" 2>&1 \
        || { echo "  ERROR: iasl $1 (see $LOGS/iasl-$1.log)"; exit 1; }
}
ssdt bat '        Device (BAT0) { Name (_HID, EisaId ("PNP0C0A")) Name (_UID, One) }'
ssdt bat-str '        Device (BAT0) { Name (_HID, "PNP0C0A") Name (_UID, One) }'
ssdt sta0 '        Device (BAT0) { Name (_HID, EisaId ("PNP0C0A")) Name (_UID, One) Name (_STA, Zero) }'
ssdt sta1f '        Device (BAT0) { Name (_HID, EisaId ("PNP0C0A")) Name (_UID, One) Method (_STA, 0, NotSerialized) { Return (0x1F) } }'
ssdt mzero '        Device (BAT0) { Name (_HID, EisaId ("PNP0C0A")) Name (_UID, One) Method (_STA, 0, Serialized) { Return (Zero) } }'
ssdt cid '        Device (BATX) { Name (_HID, "AGNS0002") Name (_CID, Package () { "AGNS0003", EisaId ("PNP0C0A") }) Name (_STA, Zero) }'
ssdt nest '        Device (EC0) { Name (_HID, EisaId ("PNP0C09")) Method (_STA, 0, NotSerialized) { Return (0x0F) }
            Device (BAT0) { Name (_HID, EisaId ("PNP0C0A")) Name (_UID, One) Name (_STA, Zero) } }'
ssdt store '        Device (BAT0) { Name (_HID, EisaId ("PNP0C0A")) Name (_STA, Zero) Method (_INI, 0, NotSerialized) { Store (0x1F, _STA) } }'
ssdt mhid '        Device (BAT0) { Method (_HID, 0, NotSerialized) { Return (EisaId ("PNP0C0A")) } Name (_STA, Zero) }'
ssdt ac '        Device (ADP0) { Name (_HID, "ACPI0003") Method (_PSR, 0, NotSerialized) { Return (One) } }'
ssdt malformed '        Device (XDEV) { Name (_HID, "AGNS0001") Name (_UID, One) }'
# The malformed table: XDEV's one-byte PkgLength raised to 0x3F (past the table's end), the checksum re-fixed so the
# bound check is the ONLY thing wrong with it (OVMF re-sums installed tables anyway).
cat > "$WORK/malform.py" <<'PY'
import sys
p = sys.argv[1]
b = bytearray(open(p, "rb").read())
i = b.find(b"\x5b\x82")
assert i > 0 and b[i + 3:i + 7] == b"XDEV" and b[i + 2] < 0x40, "XDEV DeviceOp with a 1-byte PkgLength not found"
b[i + 2] = 0x3F
assert i + 2 + 0x3F > len(b), "the new PkgLength does not overrun the table"
b[9] = 0
b[9] = (-sum(b)) & 0xFF
open(p, "wb").write(bytes(b))
print("malformed: XDEV at %d, PkgLength 0x3f, end %d > table %d" % (i, i + 2 + 0x3F, len(b)))
PY
python3 -I "$WORK/malform.py" "$WORK/asl/malformed.aml" > "$LOGS/malform.log" 2>&1 \
    || { echo "  ERROR: could not build the malformed SSDT (see $LOGS/malform.log)"; exit 1; }
# ⚠ A bad header CHECKSUM cannot be delivered this way: measured 2026-11-08 (QEMU 11.1.3 + OVMF), sta0's table with
# its checksum byte off by one reached the guest re-summed and answered mains (0x1301). psrc_table_ok's length and
# checksum refusals are therefore code-reviewed, not booted; the AML PkgLength overrun above is the booted malformed case.

pass=0; fail=0; void=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
# kernel lines carry the klug timestamp (`[    0.274698] power: source ...`); ring-3 lines do not (tsc-smoke's plain)
plain() { strings "$1" | sed -E 's/^\[[^]]*\] //'; }
want() { if plain "$LOG" | grep -qE -- "$1"; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
deny() { if plain "$LOG" | grep -qE -- "$1"; then bad "$2"; plain "$LOG" | grep -E -- "$1" | head -5 | sed 's/^/        /'; else ok "$2"; fi; }

# scenario <name> <machine> <smp> <aml or -> <kernel-line ERE after "power: source "> <word hex>
scenario() {
    _n="$1"; _m="$2"; _smp="$3"; _aml="$4"; _line="$5"; _w="$6"
    if [ -n "${PS_ONLY:-}" ] && ! printf '%s\n' "$_n" | grep -qE -- "^(${PS_ONLY})\$"; then return 0; fi
    LOG="$LOGS/psrc-$_n.log"; : > "$LOG"
    R3_ACCEL="$(smoke_accel "$_smp")"; export R3_ACCEL
    R3_MACHINE="$_m"; export R3_MACHINE
    set --
    [ "$_aml" != "-" ] && set -- -acpitable "file=$WORK/asl/$_aml.aml"
    echo ""
    echo "Boot [$_n] -machine $_m -smp $_smp  accel: $R3_ACCEL  ssdt: $_aml"
    cp "$WORK/P.img" "$WORK/P-$_n.img"
    ring3_seed_boot "$WORK/P-$_n.img" "$LOG" "PSRC-DONE" "${QEMU_TIMEOUT:-240}" "$WORK" -smp "$_smp" "$@"
    brc=$?
    rm -f "$WORK/P-$_n.img"
    if [ "$brc" -eq 2 ]; then echo "  VOID: [$_n] never booted"; void=$((void + 1)); return 0; fi
    plain "$LOG" | grep -E "^power: source|^ACPI: (RSDP|no RSDP)|^PSRC" | sed 's/^/    /'
    want "^power: source $_line\\) word 0x$_w\$"   "[$_n] kernel: power: source $(printf '%s' "$_line" | tr -d '\\')) word 0x$_w"
    KW="$(plain "$LOG" | grep -oE '^power: source .* word 0x[0-9a-f]+$' | head -1 | sed 's/.* word 0x//')"
    PW="$(plain "$LOG" | grep -oE '^PSRC word=0x[0-9a-f-]+' | head -1 | sed 's/.*=0x//')"
    if [ -n "$KW" ] && [ "$KW" = "$PW" ] && [ "$PW" = "$_w" ]; then ok "[$_n] #114 from ring 3 returned the kernel's word (0x$PW)"
    else bad "[$_n] #114 from ring 3 returned the kernel's word (kernel 0x${KW:-none}, ring 3 0x${PW:-none}, want 0x$_w)"; fi
    want "^PSRC-SUPPORTED"                        "[$_n] the word is >= 0 (the support probe)"
    want "^PSRC-ARGS-IGNORED"                     "[$_n] a1..a4 are never read"
    want "^PSRC-CACHED calls=100000"              "[$_n] 100,000 calls, one answer"
    want "^PSRC-SHAPE ok"                         "[$_n] the word's shape (state <= 1, no undefined bit, MAINS = TABLES + INFERRED without PRESENT / MALFORMED, no INFERRED on cannot say)"
    want "^PSRC-DONE"                             "[$_n] the probe ran to the end"
    deny "fault: pid=|#GP|#PF|PANIC"              "[$_n] no fault / PANIC"
    deny "$SMOKE_INVARIANT_DENY"                  "[$_n] no latched invariant"
    if [ "$(plain "$LOG" | grep -c '^power: source')" -eq 1 ]; then ok "[$_n] the boot line printed once"
    else bad "[$_n] the boot line printed once"; fi
    return 0
}

N0='battery 0 absent 0 ids 0 ac 0'
scenario q35       q35          1 -         "mains \\(no battery declared; dsdt 1 ssdt [0-9]+ $N0"                                    1101
scenario pc        pc           1 -         "mains \\(no battery declared; dsdt 1 ssdt [0-9]+ $N0"                                    1101
scenario noacpi    q35,acpi=off 1 -         "cannot say \\(no usable ACPI tables; dsdt 0 ssdt 0 $N0"                                  0
scenario bat       q35          1 bat       "cannot say \\(a battery may be present; dsdt 1 ssdt [1-9][0-9]* battery 1 absent 0 ids 1 ac 0"     700
scenario bat-str   q35          1 bat-str   "cannot say \\(a battery may be present; dsdt 1 ssdt [1-9][0-9]* battery 1 absent 0 ids 1 ac 0"     700
scenario sta0      q35          1 sta0      "mains \\(every battery absent by a constant _STA; dsdt 1 ssdt [1-9][0-9]* battery 1 absent 1 ids 1 ac 0" 1301
scenario sta1f     q35          1 sta1f     "cannot say \\(a battery may be present; dsdt 1 ssdt [1-9][0-9]* battery 1 absent 0 ids 1 ac 0"     700
scenario mzero     q35          1 mzero     "mains \\(every battery absent by a constant _STA; dsdt 1 ssdt [1-9][0-9]* battery 1 absent 1 ids 1 ac 0" 1301
scenario cid       q35          1 cid       "mains \\(every battery absent by a constant _STA; dsdt 1 ssdt [1-9][0-9]* battery 1 absent 1 ids 1 ac 0" 1301
scenario nest      q35          1 nest      "mains \\(every battery absent by a constant _STA; dsdt 1 ssdt [1-9][0-9]* battery 1 absent 1 ids 1 ac 0" 1301
scenario store     q35          1 store     "cannot say \\(a battery may be present; dsdt 1 ssdt [1-9][0-9]* battery 1 absent 0 ids 1 ac 0"     700
scenario mhid      q35          1 mhid      "cannot say \\(a battery may be present; dsdt 1 ssdt [1-9][0-9]* battery 0 absent 0 ids 1 ac 0"     700
scenario ac        q35          1 ac        "mains \\(no battery declared; dsdt 1 ssdt [1-9][0-9]* battery 0 absent 0 ids 0 ac 1"                1901
scenario malformed q35          1 malformed "cannot say \\(a table failed a bound check; dsdt 1 ssdt [1-9][0-9]* $N0"                 2100
scenario q35-smp4  q35          4 -         "mains \\(no battery declared; dsdt 1 ssdt [0-9]+ $N0"                                    1101

echo ""
echo "=== power-source-smoke: $pass passed, $fail failed, $void void ==="
[ "$fail" -gt 0 ] && exit 1
[ "$void" -gt 0 ] && exit 2
exit 0
