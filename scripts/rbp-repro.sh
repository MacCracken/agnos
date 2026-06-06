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
# Usage:  N=50 sh scripts/rbp-repro.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
N="${N:-50}"
WORK="$ROOT/build/agnsh-smoke"
IMG="$WORK/agnos-agnsh.img"
OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
OVMF_VARS_SRC="${OVMF_VARS_SRC:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}"
[ -f "$IMG" ] || { echo "ERROR: image $IMG not built — run agnsh-smoke.sh first"; exit 1; }

smash=0; reached=0; pf_total=0; boots=0
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

    if strings "$SER" | grep -q '\[ASSIST\] >'; then reached=$((reached+1)); fi

    # awk pass: walk each event block. Remember the v= header (vector + cpl),
    # and when we hit the CR2= line inside a v=0e block, test the CR2 value.
    # Emit a line per #PF and flag RBP-smash CR2 (0x37f000-0x37ffff).
    res=$(awk '
        /v=[0-9a-fA-F]+/ {
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
        END { printf("PFTOTAL=%d SMASHTOTAL=%d\n", pf+0, smash+0); }
    ' "$INT")

    pf_n=$(printf '%s\n' "$res" | sed -n 's/.*PFTOTAL=\([0-9]*\).*/\1/p'); pf_n=${pf_n:-0}
    sm_n=$(printf '%s\n' "$res" | sed -n 's/.*SMASHTOTAL=\([0-9]*\).*/\1/p'); sm_n=${sm_n:-0}
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
echo "  total ring-any #PF (v=0e) : $pf_total"
echo "  RBP-SMASH faults (0x37fxx): $smash"
[ "$smash" -eq 0 ] && echo "RESULT: NO RBP smash across $boots boots" || echo "RESULT: RBP smash STILL PRESENT ($smash)"
