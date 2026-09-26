# 2026-09-25 — under KVM, a boot with a virtio-net NIC draws each console line in ~1.45 s

**Status:** 🟡 **OPEN** — planned for **1.57.8**. Pre-existing (reproduced on the MERGE tree and earlier); found by
1.57.7's S6 and S7, not fixed there. Worked around in `lifecycle-smoke.sh` (its `-smp 4` half runs under
multi-threaded TCG by default; `LIFE_KVM=1` selects KVM).
**Filed by:** agnos, from the 1.57.7 S7 step report and `steps/HARNESS-BACKLOG.md` (S7 row); S6 saw the same.
**Checked against:** agnos **1.57.7** under QEMU/KVM with `-netdev user -device virtio-net-pci`.
**Severity:** a test-time and (possibly) iron-time slowdown of the framebuffer console path; no wrong output.

## What happens

Under KVM (not TCG), a boot with a virtio-net-pci device spends ~1.45 s per console line, with the BSP sampled in the
framebuffer console path throughout: `kybernet: exec /bin/agnsh` arrives at ~80 s instead of ~10 s (MERGE's
sock-wait `-smp 4` log: 81.68 s; S6's `TCP_SELFTEST` boot: a 32 s gap after `modeset: no latch surface`). KVM
without the NIC, and TCG with it, boot in ~10 s. It does not depend on `romfile=` or the PCI address, and happens at
`-smp 1` and `-smp 4`. A smoke that prints a lot (lifecycle-smoke re-prints every trace line) runs past its dwell.

## Leads (unverified)

The framebuffer mapping's memory type once a virtio-net-pci BAR is present — BAR placement against the GOP
framebuffer, the MTRR/PAT type the fb pages end up with under KVM (an uncached fb makes every glyph store a VM exit
class cost), or an MMIO access in the console path that traps. Measure before assuming: time one `fb_console` line
with and without the NIC, and dump the PAT/MTRR state for the fb range in both boots.

## Gate

`lifecycle-smoke` `-smp 4` under KVM (`LIFE_KVM=1`) within its TCG dwell, and a boot-time assertion in a net
smoke: `kybernet: exec` within 20 s under KVM with the NIC (RED today).

## Evidence (operator-local)

`~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.7/logs/S7/dev/r2` (KVM, timed out at 506 s), `r3` (per-line timestamps), `r4` (TCG, PASS 148 s); `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.7/steps/S6-report.json`.
