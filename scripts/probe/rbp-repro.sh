#!/bin/sh
# rbp-repro.sh — boot the agnsh-smoke image N times under `-d int` and scan for
# the SYSCALL-path RBP smash: a ring-3 #PF (v=0e) whose CR2 (== smashed user RBP)
# sits in the SYSCALL kstack window 0x37f000-0x37ffff (just under kstack top
# 0x3F0000), the signature of the user RBP being clobbered with a kernel-stack
# frame value across the mmap syscall. NOT part of the build; harness only.
#
# QEMU -d int prints each exception/interrupt as a block:
#   N: v=XX e=.... i=. cpl=Y IP=... ...
#   ...register dump...
#   CR0=.. CR2=<faulting-addr> CR3=.. CR4=..
# A #PF is v=0e; its CR2 is the faulting linear address. A clean boot takes
# zero v=0e events. The RBP smash shows as a v=0e at cpl=3 with CR2 in 0x37fxxx.
#
# ⚠⚠ VACUITY FLOOR. THIS PROBE MAKES A NEGATIVE CLAIM, AND A NEGATIVE CLAIM OVER AN EMPTY LOG IS
# WORTH NOTHING. Until 1.56.58 the verdict was one line — `[ "$smash" -eq 0 ] && echo "RESULT: NO
# RBP smash across $boots boots"` — with nothing standing between "the awk found no 0x37fxxx CR2"
# and "the smash is gone". The awk finds nothing over an EMPTY file too: on a missing or zero-byte `$INT` its
# `END { printf("PFTOTAL=%d SMASHTOTAL=%d") }` emits `0 0`, the `${sm_n:-0}` default below launders
# a failed awk into the same 0, and the script announces "NO RBP smash across 50 boots" having
# examined 50 empty logs. That is not hypothetical here: state.md records that OVMF "intermittently
# never hands off, ~1 run in 4 idle, far worse under load" — the log ends at "Please select boot
# device", the kernel never runs, and this probe scores the run green. The same hole swallows a
# QEMU build that ignores `-d int`, a `-D` that could not create the file, and a future QEMU whose
# event header stops spelling `v=` (at which point the awk matches nothing and reports a clean tree).
#
# So both counters this probe already computes are now ASSERTED rather than merely printed:
#   · exception records scanned — the enumeration the smash test runs over. Zero means the parse
#     read nothing, not that the kernel faulted nothing. A real boot emits thousands.
#   · boots that reached the `[ASSIST] >` prompt — the `strings | grep '[ASSIST] >'` in the boot
#     loop has computed this since the probe was written and nothing ever tested it. The smash is
#     a SYSCALL-path fault taken by ring-3 code; a boot that never reached the shell never issued
#     the mmap, so "no smash" over such boots is a statement about a syscall that was never made.
#
# ⛔⛔ AND THE 1.56.58 FLOORS ABOVE MOVED THE VACUITY UP A LEVEL RATHER THAN CLOSING IT — twice, and
# both halves are fixed at 1.56.59.
#   (1) THE FLOORS ARE AGGREGATES, THE CLAIM IS ABOUT A BOOT. `ev_total > 0` and `reached > 0` are
#       run-wide sums, so ONE boot can satisfy the records floor and a DIFFERENT boot the prompt
#       floor while NO SINGLE BOOT ever ran ring-3 code under a log this probe could read — which is
#       the entire measurement, since the smash is a ring-3 fault recorded in the -d int stream.
#       MEASURED on the stub-QEMU rig, two boots, the first leaving a full 40-record log but dying
#       before the shell and the second reaching the prompt with no log at all: both floors held and
#       the old form printed "RESULT: NO RBP smash across 2 boots (1 reached the prompt, 40 records
#       scanned)", exit 0, over zero boots that measured anything. Not a contrived pairing either —
#       it is the ordinary shape of a flaky-OVMF run mixed with a QEMU that drops the -D file.
#   (2) THE DENOMINATOR WAS THE REQUESTED BOOT COUNT. `$boots` is `N` — how many boots were ASKED
#       for — so the headline said "across 50 boots" no matter how few produced evidence. Measured:
#       4 boots of which 3 were blind printed "NO RBP smash across 4 boots (1 reached the prompt)".
#       The reader is told the size of the request and has to work out the size of the evidence.
#   ⇒ `evidenced` is the per-boot conjunction — this boot reached the prompt AND left a log with
#     'v=' records in it. It is floored (a run with zero is INCONCLUSIVE, not clean) and it is the
#     denominator the verdict is stated over. `blind`, computed since 1.56.58 and until now only
#     printed, is what keeps a boot OUT of it, so the counter is finally load-bearing.
# ⭐ THE FLOORS GATE ONLY THE AFFIRMATIVE VERDICT. A detected smash is self-evidencing — you found
# the thing — so `smash > 0` still reports STILL PRESENT without consulting them. The floors exist
# to stop the OTHER branch, which is the one that can be true by accident.
# ⚠ The prompt floor is `> 0`, NOT `== boots`, deliberately: with OVMF flaking one boot in four,
# demanding every boot reach userland would make this probe cry wolf about firmware. The ratio is
# printed instead, so a 1/50 reach rate is visible rather than asserted away.
#
# Exit: 0 = proven clean · 1 = smash reproduced · 2 = INCONCLUSIVE (measured nothing). Previously
# every path exited 0 (the status of the trailing echo), so a caller could not tell the three apart.
#
# Usage:  N=50 sh scripts/probe/rbp-repro.sh
set -u
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
N="${N:-50}"
WORK="$ROOT/build/agnsh-smoke"
IMG="$WORK/agnos-agnsh.img"
OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
OVMF_VARS_SRC="${OVMF_VARS_SRC:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}"
[ -f "$IMG" ] || { echo "ERROR: image $IMG not built — run agnsh-smoke.sh first"; exit 1; }

smash=0; reached=0; pf_total=0; boots=0; ev_total=0; blind=0; evidenced=0
LOGD="$WORK/rbp-repro"; rm -rf "$LOGD"; mkdir -p "$LOGD"
i=1
while [ "$i" -le "$N" ]; do
    boots=$((boots+1))
    cp "$OVMF_VARS_SRC" "$LOGD/vars.fd"; chmod +w "$LOGD/vars.fd"
    SER="$LOGD/ser-$i.log"; INT="$LOGD/int-$i.log"
    timeout "${QEMU_TIMEOUT:-25}" qemu-system-x86_64 \
        -machine q35 -m 512M -cpu max \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$LOGD/vars.fd" \
        -drive "file=$IMG,format=raw,if=none,id=disk0" \
        -device "nvme,drive=disk0,serial=AGNOS-AGNSH" \
        -serial stdio -display none -no-reboot \
        -d int -D "$INT" >"$SER" 2>/dev/null

    # ⚠ Remembered PER BOOT as well as summed, because the sum alone cannot say whether the boot that
    # reached userland is the same boot whose log this probe could read. See (1) in the header.
    this_reached=0
    if strings "$SER" | grep -q '\[ASSIST\] >'; then reached=$((reached+1)); this_reached=1; fi

    # ⚠ BLIND-BOOT GUARD, BEFORE THE AWK RUNS. An absent or zero-byte `-d int` log is not "a boot
    # that took no faults", it is a boot this probe could not read — and the two are indistinguish-
    # able downstream, because awk on a missing file writes to stderr, prints nothing, and leaves
    # `$res` empty, which the `${pf_n:-0}` / `${sm_n:-0}` defaults below turn into a clean score.
    # Count it as blind here so it can never be spent as evidence at the verdict.
    if [ ! -s "$INT" ]; then
        blind=$((blind+1))
        echo "  [boot $i] BLIND: no -d int log at $INT — this boot measured nothing"
        i=$((i+1))
        continue
    fi

    # awk pass: walk each event block. Remember the v= header (vector + cpl),
    # and when we hit the CR2= line inside a v=0e block, test the CR2 value.
    # Emit a line per #PF and flag RBP-smash CR2 (0x37f000-0x37ffff).
    res=$(awk '
        /v=[0-9a-fA-F]+/ {
            # ev is the ENUMERATION COUNT for the assertion below — every event record this pass
            # actually saw. Reported, not implied: a boot that says 0 records is reporting that the
            # parse read nothing (empty log, -d int unsupported, header no longer spelled "v="),
            # which is a different fact from "this boot took no page faults".
            ev++;
            cur_v=""; cur_cpl=""; cur_ip="";
            if (match($0, /v=[0-9a-fA-F]+/))  { cur_v=substr($0,RSTART+2,RLENGTH-2); }
            if (match($0, /cpl=[0-9]+/))      { cur_cpl=substr($0,RSTART+4,RLENGTH-4); }
            if (match($0, /IP=[0-9a-fA-F:]+/)){ cur_ip=substr($0,RSTART+3,RLENGTH-3); }
        }
        /CR2=/ {
            if (cur_v=="0e" || cur_v=="0E") {
                pf++;
                if (match($0, /CR2=[0-9a-fA-F]+/)) {
                    cr2=substr($0,RSTART+4,RLENGTH-4);
                    # strip leading zeros for range test
                    v=strtonum("0x" cr2);
                    if (v>=0x37f000 && v<=0x37ffff) {
                        smash++;
                        printf("SMASH cpl=%s IP=%s CR2=0x%x\n", cur_cpl, cur_ip, v);
                    }
                }
                cur_v="";  # consume
            }
        }
        END { printf("PFTOTAL=%d SMASHTOTAL=%d EVTOTAL=%d\n", pf+0, smash+0, ev+0); }
    ' "$INT")

    pf_n=$(printf '%s\n' "$res" | sed -n 's/.*PFTOTAL=\([0-9]*\).*/\1/p'); pf_n=${pf_n:-0}
    sm_n=$(printf '%s\n' "$res" | sed -n 's/.*SMASHTOTAL=\([0-9]*\).*/\1/p'); sm_n=${sm_n:-0}
    ev_n=$(printf '%s\n' "$res" | sed -n 's/.*EVTOTAL=\([0-9]*\).*/\1/p'); ev_n=${ev_n:-0}
    ev_total=$((ev_total + ev_n))
    if [ "$ev_n" -eq 0 ]; then
        blind=$((blind+1))
        echo "  [boot $i] BLIND: $INT holds no 'v=' event records — the smash scan ran over nothing"
    fi
    # ⭐ THE ONLY BOOTS THIS PROBE MAY SPEND AS EVIDENCE: ones that got ring-3 code running AND left a
    # log the scan could read. Either alone proves nothing about a ring-3 fault recorded in -d int.
    if [ "$ev_n" -gt 0 ] && [ "$this_reached" -eq 1 ]; then evidenced=$((evidenced+1)); fi
    pf_total=$((pf_total + pf_n))
    if [ "$sm_n" -gt 0 ]; then
        smash=$((smash + sm_n))
        echo "  [boot $i] RBP-SMASH #PF x$sm_n (CR2 in 0x37fxxx):"
        printf '%s\n' "$res" | grep '^SMASH' | head -3 | sed 's/^/      /'
    fi
    i=$((i+1))
done

echo ""
echo "=== rbp-repro: $boots boots ==="
echo "  reached [ASSIST] > prompt : $reached / $boots"
echo "  boots with a readable log : $((boots - blind)) / $boots"
echo "  boots that did BOTH       : $evidenced / $boots   <- the evidence this verdict may spend"
echo "  exception records scanned : $ev_total"
echo "  total ring-any #PF (v=0e) : $pf_total"
echo "  RBP-SMASH faults (0x37fxx): $smash"
echo ""

# ⭐ A DETECTED SMASH NEEDS NO FLOOR — finding the thing is its own evidence. Report and get out
# before the vacuity checks, so a run that reproduces the bug on one readable log out of fifty is
# still reported as a reproduction and not downgraded to "inconclusive".
if [ "$smash" -gt 0 ]; then
    echo "RESULT: RBP smash STILL PRESENT ($smash)"
    exit 1
fi

# ⚠ EVERYTHING BELOW EXISTS BECAUSE `smash -eq 0` IS ALSO WHAT AN UNREAD LOG LOOKS LIKE. See the
# VACUITY FLOOR note in the header: 50 boots that die in the OVMF menu produce 50 empty `-d int`
# logs, zero matches, and — before 1.56.58 — the sentence "RESULT: NO RBP smash across 50 boots".
vac=0
if [ "$ev_total" -eq 0 ]; then
    echo "  ⛔ zero exception records were scanned across all $boots boots."
    echo "     The smash test ran over an empty set. Either no -d int log was written (QEMU"
    echo "     rejected -d int, or -D could not create the file), or the event header this pass"
    echo "     greps for ('v=XX') is no longer how this QEMU spells it. Check $LOGD/int-1.log."
    vac=1
fi
if [ "$reached" -eq 0 ]; then
    echo "  ⛔ not one boot reached the [ASSIST] > prompt."
    echo "     The RBP smash is taken by ring-3 code across the mmap syscall. A boot that never"
    echo "     got to agnsh never issued that syscall, so 'no smash' over these boots is a claim"
    echo "     about a code path that did not run. Usual cause: OVMF never handed off (state.md —"
    echo "     ~1 idle run in 4). Check $LOGD/ser-1.log for the kernel banner."
    vac=1
fi
# ⛔ THE FLOOR THE TWO ABOVE CANNOT MAKE BETWEEN THEM. They are run-wide sums: satisfy one from boot 7
# and the other from boot 12 and they both hold while not one boot both ran ring-3 code and produced a
# readable log. The smash is a ring-3 fault RECORDED IN THE -d int STREAM — it takes one boot holding
# both halves at once to be able to see it, and `evidenced` is the count of those. Measured on the
# stub rig (intonly,assistonly): ev_total=40, reached=1, evidenced=0, and the pre-1.56.59 form
# announced "NO RBP smash across 2 boots" over a run in which nothing was observable.
if [ "$evidenced" -eq 0 ]; then
    echo "  ⛔ not one boot BOTH reached the [ASSIST] > prompt AND left a readable -d int log."
    echo "     $reached boot(s) reached the prompt and $((boots - blind)) left a readable log, but no"
    echo "     single boot did both, so no boot was in a position to record the fault being looked"
    echo "     for. The two floors above are aggregates and are satisfied by different boots here."
    vac=1
fi
if [ "$vac" -ne 0 ]; then
    echo "RESULT: INCONCLUSIVE — this run measured nothing about the RBP smash ($boots boots)"
    exit 2
fi

# ⚠ THE DENOMINATOR IS `evidenced`, NOT `$boots`. `$boots` is `N` — the number of boots REQUESTED —
# and stating the verdict over it let 1 useful boot out of 50 read as "NO RBP smash across 50 boots".
# What the reader needs is the size of the evidence, with the size of the request beside it.
if [ "$evidenced" -lt "$boots" ]; then
    echo "  note: the verdict below rests on the $evidenced boot(s) that both reached userland and left a readable log — not on all $boots attempted ($blind blind, $((reached - evidenced)) reached the prompt but were blind)."
fi
echo "RESULT: NO RBP smash across $evidenced boot(s) that measured something (of $boots attempted; $reached reached the prompt, $blind blind, $ev_total records scanned)"
exit 0
