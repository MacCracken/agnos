# 2026-09-25 — under KVM, a boot with a virtio-net NIC draws each console line in ~1.45 s

**Status:** ✅ **RESOLVED 1.57.8 (2026-09-25)**. Step KVMCON measured the root cause: PD[0] (phys 0–2 MB) was mapped UC. `pci_bar_64` returned virtio-net's legacy I/O BAR base `0x6060` for the `VIRTIO_PCI_CAP_PCI_CFG` cap, and `vmm_remap_uc_2mb(0x6060)` rewrote PD[0]. `pci_bar_64` is now MMIO-only, and `vmm_remap_uc_2mb` refuses phys < 4 MB with a denied line. `kybernet: exec` under KVM with the NIC went from 80.4 s to 10.8–10.9 s. Gate: `scripts/smoke/kvm-net-boot-smoke.sh` (sweep row, `-smp 1` and `-smp 4`). `lifecycle-smoke` `-smp 4` runs under KVM by default again. Built, gated, NOT burned. See § Resolution.
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

## Resolution (1.57.8, 2026-09-25)

**What shipped:**
- **The root cause.** `info tlb` showed VA 0 as `--PDACT-W` with the NIC and `--PDA---W` without it, and the RIP
  samples fell in fb_console's shadow→fb blit. The "Leads" above (the fb's memory type) were close, but the UC mapping
  was the kernel's own low 2 MB, not the fb.
- **The fix.** `pci_record` stores 0 for an I/O BAR, and both virtio cap walks skip `bar_phys == 0`.
  `vmm_remap_uc_2mb` refuses phys < 4 MB and prints `vmm: UC remap of the kernel low 4 MB refused`, which is now in
  `SMOKE_INVARIANT_DENY`.
- **Measured.** A console line takes ~0.19 s, down from ~1.45 s. `kybernet: exec` arrives at 10.83–10.95 s at
  `-smp 1` and 10.79–10.91 s at `-smp 4`, down from 80.40 / 80.44 s.
- **Mutations.** The old I/O BAR value fires the deny line. Adding the guard's removal as well gives 78.4 s.
- **A second defect in the same investigation.** `chan_region_reserve` zeroed its band through the direct map under
  gnoboot's CR3. The zeroing never landed, and it cost ~2 s of KVM MMIO exits. It is moved after `cr3_load(0x1000)`,
  and the window went from 2,040 ms to 9–10 ms (mutation: 2,065 ms, RED).

**What the change broke — checked before archiving:** nothing found. Every other `vmm_remap_uc_2mb` caller already
rejects a zero BAR, and the only consumer of a BAR value is MMIO, so no path lost a port base it needed. `lifecycle-smoke`
`-smp 4` under KVM passes 90/0. `chan-ring3-smoke` passes with the moved reserve. Two items remain:
- A `BOOTCR3_KEEP_GNOBOOT_CR3` opt-out build gets no channel band (`CH_E_NOREGION`, non-fatal, documented).
- Not a defect: `lifecycle-smoke` `-smp 4` takes 287 s under KVM against 148 s under TCG, bound by the fb console's
  full-surface blit (~94 MB/s WC writes, ~0.19 s per 2048×2048 scroll). It is a roadmap row.

**Evidence:** `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.8/steps/KVMCON-report.json`, `KVMCON-endreview.json`; logs under `logs/KVMCON/`.
