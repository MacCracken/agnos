# Kernel GPU arc — pixels AND data through the silicon (slotted 1.54.x)

**Status (2026-07-13): ◐ EXECUTING — F0..C2f all iron-PASS (kernel 1.54.18; 1.54.19 cutting).**
The **C1 firmware-load + engine-start sub-arc is COMPLETE**; the **C2 compute-dispatch sub-arc** has
proven the full path — GMC/FB-aperture → compute queue → PM4 fetch → WRITE_DATA fence (GPU→CPU
coherence) → **first hand-assembled gfx90c shader RAN (C2f, 1.54.16)**. Now on **C2g (rosnet matmul,
the crown)**, decomposed g-1..g-4; C2g-1 (first 64-thread dispatch) is mid-debug (1.54.17/18; 1.54.19
= a store-landing isolation diagnostic). Live status → `agnosticos/docs/development/state.md` +
`gpu-arc-handoff.md`; per-burn detail → `iron-nuc-zen-log.md#tracker-154x-*`. *(History: opened
2026-07-10 as a plan-only deliverable right after the 1.53.x console-perf arc iron-closed (1.53.14);
the first landed bite cut agnos 1.54.0.)* Target: **archaemenid AMD Zen** (Beelink SER, Ryzen 7
5800H — Cezanne APU). **NOT Cyrius-gated** — 6.4.x is plenty ([[project_gpu_arc_not_cyrius_gated]]).

**Size is NOT a constraint (user, 2026-07-10):** this is a large, multi-phase arc spanning many
minors. The bar is *"push pixels AND data through the GPU"* — anything less is not a GPU arc. Do
NOT under-scope it to framebuffer flips.

---

## Thesis — the GPU is a compute device, not just a scanout

An AI-native OS that can't run its own ML on its own GPU is theater. This arc makes agnos **drive
the AMD GPU as a first-class compute + display processor**: submit command rings, address memory
through GPUVM, dispatch sovereign shader kernels on the CU/shader array, AND own the display pipe.
Two thrusts run this arc — **push pixels** and **push data** — and **data is the headline**.

### Thrust C — push DATA (compute — the crown)

Bring up the GFX/compute engine so **sovereign Cyrius-emitted shaders run on the gfx90c shader
cores**, and wire a ring-3 dispatch band so the ML stack (rosnet matmul → attn11 / tentib /
prajna) executes on the GPU. This is the **mabda-native-compute theme made real at the kernel
level** — the roadmap's "attn11/tentib move off CPU onto the GPU" only happens once the *kernel*
can submit compute work. The end-proof: **a rosnet f64/int8 matmul kernel dispatched on the GPU
returns bit-correct results vs the CPU reference**, then a real attn11/tentib layer runs on it.

What that requires (each a bite-group below):
- **GPUVM** — per-VMID page tables so the GPU MMU can address kernel + ring-3 buffers (GMC/gfx9).
- **CP firmware load** — the MEC (MicroEngine Compute) command processor needs its signed
  microcode; on gfx9 the **PSP** loads CP/RLC/SDMA ucode. **This is the honest hard gate** (see
  Risks) — the arc's first real investigation is whether the BIOS/PSP left usable ucode resident
  or whether agnos must drive the PSP load path.
- **Compute ring + HQD/MQD + doorbell** — a compute queue: MQD in memory holds the queue state,
  the CP loads it into an HQD, ring-3 (or kernel) writes PM4 packets + rings the doorbell.
- **PM4 submission** — build indirect buffers + `DISPATCH_DIRECT`/`INDIRECT_BUFFER` packets;
  fence/wait for completion.
- **Shader path** — emit a gfx90c (GCN5 / Vega ISA) compute kernel (LLVM AMDGPU documents the ISA
  fully; a hand-assembled kernel is the MVP, a Cyrius→gfx90c backend the ambition), load it into
  GPU-addressable memory, point the dispatch at it.
- **Ring-3 `gpu_*` compute syscall band** — submit-buffer / alloc-gpu-mem / dispatch / wait, so
  mabda/rosnet consume it. (First real justification for a `gpu_*` band — the second-consumer bar
  is met by the whole ML family.)

### Thrust P — push PIXELS (display + graphics accel)

Own the GOP-lit **DCN 2.1** display pipe, then accelerate 2D:
- **Own the lit pipe** (no firmware/clock reprogram): double-buffer/tear-free flips (re-point HUBP
  surface address), vblank pacing, **HDMI/DP display-audio egress** (closes the 1.53.5 backlog),
  scanout-residue clear.
- **Graphics acceleration** (once Thrust C's ring machinery exists): GFX-ring-driven blits /
  fills (accelerated `blit`#39), then a path toward 3D (RADV-derived) — the desktop (aethersafha)
  present composited on the GPU instead of CPU memcpy.
- **Full modeset** (lighting dark pipes, resolution, hotplug) is the one thing that can spill to a
  *follow-on* arc — it needs DMCUB/DP-link-training territory — but it is explicitly IN the
  ambition, not written off.

Per [[project_agnos_kernel_growth_rules]]: sovereign ML-on-GPU + accelerated desktop are native
workloads — the kernel grows for them, not to mimic a Linux DRM/KFD ABI.

## The gap — measured, not theorized

- `fb.cyr` scans out on the GOP framebuffer; the kernel has **zero** GPU knowledge — no PCI probe
  of `04:00.0`, no register map, no GPUVM, no rings, no CP, no shader dispatch. Everything in both
  thrusts is greenfield.
- ML today: attn11/tentib/rosnet run **f64/int-SIMD on the CPU** (the 1.53.x FP arc). The GPU
  (thousands of ALUs) sits idle. **mabda only helps the core projects on LINUX** (user, 2026-07-10)
  — its GPU surface rides the Linux kernel's driver stack, so every mabda consumer (the attn11 GPU
  move, hoosh inference, aethersafha accel) gets GPU **on Linux only**. On agnos there is **no
  kernel path to submit work to the hardware at all** — this arc IS that path: the kernel bring-up
  + the `gpu_*` band become mabda's **agnos backend**, so the same core projects get the GPU on
  agnos too.
- Display: `blit`#39 CPU-memcpys into live scanout (tears; no second buffer). Display audio is
  GPU-gated (1.53.5 burn 2 dispositive).

## Target hardware facts (verified 2026-07-10; executing agent RE-VERIFIES on iron at F0/C0)

| Fact | Value | Source |
|------|-------|--------|
| iGPU | AMD Cezanne (Ryzen 7 5800H) — **gfx90c** compute (GCN5 / Vega ISA), **DCN 2.1** display | LLVM AMDGPU gfx90c; Phoronix Renoir DCN 2.1; linux-hardware.org `1002:1638` |
| Compute ISA | **gfx90c** — Vega/GCN5, **fully documented in LLVM AMDGPU** (gfx900/902/909/90c share the ISA doc) — sovereign shader emit is tractable | LLVM "Syntax of gfx900…gfx90c Instructions" |
| Command engines | **GFX** ring (graphics) + **MEC** compute pipes (HQD/MQD queues) + **SDMA** copy engines | Linux `gfx_v9_0.c`, `sdma_v4_0.c`; kernel amdgpu ring-buffer docs |
| Memory | **GPUVM** — per-VMID multi-level page tables (VRAM = carved-out system RAM on an APU + snooped system pages) | kernel amdgpu GPUVM docs; `gmc_v9_0.c` |
| Firmware | CP/MEC/RLC/SDMA microcode is **PSP-loaded** on gfx9 — the honest gate | Linux amdgpu PSP path; **investigate resident-vs-load at C0** |
| PCI / regs | GPU `04:00.0` `1002:1638`; BAR5 MMIO reg aperture; Renoir base-segment offset tables (hardcoded, no IP-discovery walk) | 1.53.5 burns; `renoir_ip_offset.h`, `soc15.c` |
| Display | DCN 2.1, GOP-lit linear FB (`fb_phys`); user's display on DP output 2 | `#tracker-153x-hdmi`; `fb.cyr` |

## Prior-art review (multi-source per [[feedback_redesign_dont_reinvent]] — re-derive, don't trust this table)

| Source | Role | What to take |
|--------|------|--------------|
| **tinygrad `7900xtx` MEC reverse-engineering** (github tinygrad/7900xtx, `docs/MEC.md`) | ★ PRIMARY for the sovereign-compute SHAPE | The *whole point*: driving AMD compute **without ROCm/KFD** — MEC/HQD/MQD/doorbell/PM4 from first principles, exactly AGNOS's posture. RDNA3 not gfx9, so register content differs, but the sovereign-submission *method* is the closest cousin that exists |
| **Linux amdkfd** `drivers/gpu/drm/amd/amdkfd/` (`kfd_mqd_manager_v9.c`, `kfd_device_queue_manager.c`) | PRIMARY for gfx9 compute-queue content | gfx9 MQD layout, HQD load/unload sequence, doorbell assignment, VMID/queue mapping — the exact ASIC our silicon is |
| **Linux amdgpu gfx9** `gfx_v9_0.c` · `gmc_v9_0.c` · `sdma_v4_0.c` · `amdgpu_psp.c` | PRIMARY for engine/VM/firmware bring-up | CP/MEC init, RLC, GPUVM page-table format + TLB flush, SDMA ring setup, **the PSP firmware-load sequence** (the gate) |
| **Mesa RADV / radeonsi + `src/amd/common`** | PRIMARY for PM4 + ISA emit | PM4 packet building (`si_pm4_*`), `DISPATCH_DIRECT`, the register/packet encodings; radeonsi's compute path; a reference for what a minimal dispatch actually needs |
| **LLVM AMDGPU backend** (gfx90c ISA docs + assembler) | PRIMARY for the shader leg | Emit/verify gfx90c compute kernels; the long-range Cyrius→gfx90c backend derives from this ISA spec |
| **Linux amdgpu DC `dcn21/`** (+ `dcn20/`, `dce_audio.c`) | PRIMARY for Thrust P | HUBP surface-flip, OTG/vblank, the DCCG-audio + AFMT/SDP display-audio sequence |
| **Linux register headers** `dcn_2_1_0_offset.h`/`_sh_mask.h`, `renoir_ip_offset.h`, `gc_9_*`/`gmc_9_*` | Ground truth for offsets/masks | Extract per-bite register tables into `gpu_regs.cyr`; fetch via **curl** from a kernel.org git mirror (never `gh`) |
| **AMD Vega/GCN5 ISA reference (PDF)** | ISA ground truth | Cross-check the LLVM ISA docs for the shader leg |
| **Haiku `radeon_hd`, FreeBSD/OpenBSD drm-kmod** | Cross-check / reduction reference | "What subset an OS actually needs"; Haiku's firmware-lit-FB piggyback for the display bootstrap. NOT independent register derivations |

⚠ [[feedback_audit_re_derive_dont_validate_comments]]: derive every sequence from the sources, diff
against this plan, source wins. Linux is ONE source — keep tinygrad/Mesa/Haiku cross-checks honest.

## Bite ladder — two interleaved thrusts (each bite = its own cut; NO auto-run — user burns)

**Phase 0 — shared foundation.** First landed bite cuts **1.54.0**.

| Bite | What | Validation |
|------|------|------------|
| **F0** | GPU PCI probe `04:00.0` + BAR5 map (UC) + Renoir/gfx9 reg-base table (`gpu_regs.cyr`) + read-only ID dump (GC/GMC/DCN revisions) | IRON (no QEMU DCN/GFX) — `klug > /f/gpu.txt` |

**Thrust C — push DATA (the crown).**

| Bite | What | Validation |
|------|------|------------|
| **C0** | **Firmware reality check** — is CP/MEC/RLC ucode resident from BIOS/PSP, or must agnos drive the PSP load? Dump `CP_ME_RAM`/version regs; inventory the PSP path. **This gates the whole compute thrust — resolve honestly first.** | IRON dump — decides C1 shape (resident vs PSP-load) |
| **C1** | **GPUVM bring-up** — a per-VMID page table for a compute context; map a scratch VRAM/system buffer; TLB flush; read-back proves the GPU MMU addresses it | IRON — DMA/CP write-through-VM read-back correct |
| **C2** | **CP/MEC + compute ring + doorbell** — init the MEC, build an MQD, load an HQD, stand up one compute ring; a trivial PM4 `NOP`/fence round-trips (rptr advances) | IRON — fence value lands in memory |
| **C3** | **First shader dispatch** — load a hand-assembled gfx90c compute kernel (write-a-constant / vector-add), `DISPATCH_DIRECT`, wait fence; output buffer correct | IRON — GPU wrote the expected bytes |
| **C4** | **rosnet matmul on the GPU** — a real matmul kernel (f64 or int8), dispatched, **bit-correct vs the CPU rosnet reference**; the sovereign-ML-on-silicon proof | IRON — matmul matches CPU + timing |
| **C5** | **ring-3 `gpu_*` compute syscall band** — alloc-gpu-mem / submit-IB / dispatch / wait; `is_user_range`-guarded; a ring-3 test program dispatches a kernel | IRON — ring-3 dispatch works |
| **C6** | **attn11 / tentib layer on the GPU** — a real transformer/ternary layer runs its matmuls on the GPU via mabda→the band; end-to-end correct | IRON — layer output matches CPU; the arc-crown proof |

**Thrust P — push PIXELS.**

| Bite | What | Validation |
|------|------|------------|
| **P0** | Live-pipe read-only dump — OTG walk → lit pipe; HUBP surface addr/pitch/format; **HUBP surf-addr == gnoboot `fb_phys`** (pass gate) | IRON — F0+P0 ride ONE read-only burn |
| **P1** | Double-buffer / tear-free flip — re-point HUBP `DCSURF_PRIMARY_SURFACE_ADDRESS`; wire kernel-mediated double-buffer in `blit`#39 (`fb_phys` unexposed) | IRON FB photo |
| **P2** | Vblank pacing — poll OTG position, flip-on-vblank | IRON — tear-free desktop present |
| **P3** | **Display-audio egress (DP first)** — DCCG audio DTO + AZ endpoint + AFMT/SDP on the lit stream (closes the 1.53.5 backlog); HDMI (ACR/CTS) after | IRON — tone from the display's speakers |
| **P4** | Scanout-residue clear (Quiet-Boot legibility) via the P1 primitive | IRON photo — clean first paint |
| **P5** | **GFX-ring 2D acceleration** — accelerated blit/fill over the GFX ring (needs C1/C2's VM+ring); accelerated aethersafha composite | IRON — accelerated present, correct |
| **P6+** | 3D path (RADV-derived) + full modeset (DCN mode-set / DP link-training / DMCUB) — the deep end; may span a follow-on arc but IS in the ambition | IRON |

**Userland ride-along** (no kernel cut): ai-hwaccel `read_symlink` agnos gate (`#89` →
`sys_readlink`#70) → cut ai-hwaccel → rebuild iam (kills the mirshi ENOSYS; state.md deferred it
here).

Sequencing: **F0 → (C0 gate) → C1/C2 build the ring+VM machinery that BOTH thrusts need → then C
and P proceed in parallel** (P0/P1 can start off F0 alone since flips don't need the compute ring;
P5 needs C1/C2). Batch read-only bites per burn where safe (F0+P0+C0 are read-only).

## Harness

- **Iron-only** — QEMU emulates no AMD GFX/DCN. Read-only bites (F0/P0/C0) ride the first burns to
  de-risk before any write. Per [[feedback_driver_code_is_the_bite]]: write each bite's driver from
  the convergent prior-art BEFORE its burn; the burn validates.
- **Capture**: `klug > /f/*.txt` (agnoshi redirect) for register/result dumps; FB photos for
  visual bites; mount-modify retrieval ([[feedback_prefer_mount_modify_over_reflash]]); ESP-only
  flashes for kernel changes.
- Every bite gets a CONFIRM/FALSIFY tracker entry in agnosticos `iron-nuc-zen-log.md` **before**
  the user flashes ([[feedback_iron_testing_constraints]] — burns block user work).
- **⚠ Build-size ceiling — LIFT IT AT C0.** `scripts/check.sh:61` caps `build/agnos` at
  `< 1,400,000` bytes; F0 (1.54.0) landed at **1,399,536 (only 464 B headroom)**. The compute bites
  (C0's CP/MEC register table onward) WILL cross it — raise the bound when C0 lands. It is a
  size-discipline threshold (last set in the ~250 KB era), NOT a correctness bound. User-confirmed
  2026-07-11 ("you will need to lift that ceiling later").

## Risks / open questions (resolve in bite order; honest, not hidden)

1. **★ CP/MEC firmware (C0) — the genuine hard gate.** gfx9 CP/MEC/RLC ucode is PSP-signed and
   normally PSP-loaded. If the BIOS/PSP leaves usable ucode resident, C1+ proceed; if agnos must
   drive the PSP firmware-load handshake (`amdgpu_psp.c`), that's a substantial sub-arc and C0's
   finding reshapes the ladder. **This is the make-or-break — investigate FIRST, report honestly.**
   Fallback if PSP-load proves ahead-of-its-time: SDMA copy-engine dispatch (simpler CP) may give a
   data path before full MEC — evaluate at C0.
   **✅ RESOLVED 2026-07-11 (iron, agnos 1.54.1):** C0 = **CASE B** — CP/MEC/RLC ucode NOT resident
   (`rlc=0x0` RLC off · `me=0x15000000`/`mec=0x50000000` CP+MEC halted · PSP alive `psp=0x698e82` ·
   GFX powered) — adversarially confirmed vs primary AMD sources. So **C1 = drive the PSP GPCOM
   firmware-load handshake.** **Firmware decision (user, 2026-07-11): "ship blobs + sovereignty
   tier"** — bundle the ~628 KB AMD-signed compute subset (`renoir_*.bin`, hardware-required firmware
   like CPU microcode) + a display-only zero-blob max-sovereignty tier; keep the claim precise
   ("sovereign except the vendor microcode"); firmware-provenance ledger in docs. See
   [[project_firmware_blob_posture]]. **C1 bite ladder:** C1a0 GPU-addressable-memory probe (highest-
   impact unknown — where PSP-DMA buffers live) → C1a PSP-ready + GPCOM ring-create + SETUP_TMR →
   **C1b one-firmware round-trip (RLC_G, the make-or-break)** → C1c full RLC+MEC set (LOAD_IP_FW per
   blob, PSP validates AMD's signature) → C1d start engines (RLC_CNTL bit0, then clear CP_ME_CNTL /
   CP_MEC_CNTL halts) + Case-A re-read (the Case-B→A flip = the compute-thrust gate). **Fold in at
   C1d:** the F0 latent bug — the Case-A guard's `mec_hdr != 0` is defeated by the `0xdef0def0`
   no-ucode sentinel (add `GPU_CP_HEADER_EMPTY = 0xdef0def0`; or replace the FIFO accessor with a
   positive ucode-presence read). Full C1 protocol + firmware-set + load-order + the load-bearing
   unknowns (memory domain, TMR size, per-blob payload byte-range, HDP coherence) → the C0-verify/
   C1-plan workflow output; re-derive against amdgpu `psp_v12_0.c` / `psp_gfx_if.h` before C1b's burn.
   **✅ C1 PROGRESS (iron, archaemenid):** C1a0+C1a (1.54.2) GPCOM ring UP · C1b-1 (1.54.4) SETUP_TMR
   `status=0x0` — memory domain answered (low kernel phys IS PSP-DMA-reachable; TMR must live in the
   VRAM carveout, placed via GFXHUB FB-location regs) · **C1b-2 (1.54.5, 2026-07-12) LOAD_IP_FW RLC_G
   `status=0x0` — the FIRST sovereign-loaded firmware on the GPU; PSP validated AMD's signature.** The
   make-or-break round-trip is DONE. · **C1c (1.54.6, 2026-07-12) ALL CP+MEC ucode LOADED (5/5)** —
   CE/PFP/ME whole-body + MEC1 body+JT split; no MEC2 on gfx9.3.0; the whole compute microcode set
   resident. · **C1d (1.54.7, 2026-07-12) CASE A — the GPU compute engine is RUNNING** (`gpu_engine_
   start()` un-halted CP-gfx `me 0x15000000→0` + MEC1 `mec 0x50000000→0` over the already-running RLC
   `rlc=0x1`; pipe idle `grbm` bit31=0 / `stat=0x0`; the `mec_hdr` guard fixed + widened to the
   `0xdefX_defX` sentinel family — the PSP path leaves the header-dump reg at the sentinel, so the
   verdict rests on halts+RLC+GRBM, not the header). **✅ THE C1 FIRMWARE-LOAD + ENGINE-START SUB-ARC
   IS COMPLETE — the compute-thrust gate is OPEN.** Payload byte-range unknown = CONFIRMED
   (`common_firmware_header` `ucode_size_bytes`@0x14 / `ucode_array_offset_bytes`@0x18).

   **✅ C2 — DISPATCH COMPUTE (executed through C2f, iron-only):** the C2a read-only GMC/GPUVM probe
   answered the make-or-break — **GART=ABSENT**, so the design is compute scratch in the UMA carveout
   addressed via the BIOS FB aperture with **ZERO page tables** (`VM_CONTEXT0` disabled), which designs
   the VM-fault-storm CPU-wedge OUT. The landed + iron-PASS ladder:
   - **C2a** (1.54.8) GMC/VM probe — GART absent, FB carveout MC `[0xF400000000,+3GB)`.
   - **C2b** (1.54.9) GMC ARMED — L2 datapath on, paging off, `0x1FFC` fault-net armed; CPU R/W of the
     carveout DRAM validated.
   - **C2c** (1.54.10) compute QUEUE MAPPED — MEC1/pipe0/queue0 via direct (non-HWS) CP_HQD programming.
   - **C2d** (1.54.12) first PM4 packet FETCHED — `fault=0` proved the ring GPUVA translates through the
     FB aperture with no page tables (no GART). *Residual: the posted BAR2 doorbell didn't advance the
     wptr; the **register-wptr submit works** and is used everywhere.*
   - **C2e** (1.54.13) WRITE_DATA FENCE OK — the MEC executes a packet AND its `DST_SEL=5` memory write
     is **CPU-visible** = GPU→CPU coherence proven.
   - **C2f** (1.54.16) first hand-assembled **gfx90c SHADER RAN** — a single-thread compute kernel
     executed on the cores and its `global_store_dword` result read back on the CPU. *(Took 3 burns —
     the bug was a WPTR **LO-before-HI** submit-order gotcha, not the ISA.)*

   **▷ C2g — rosnet matmul on the cores (THE CROWN), decomposed:** **C2g-1** first multi-thread dispatch
   (64 threads, `out[tid]=tid`) → **C2g-2** kernargs (operand pointers via `COMPUTE_USER_DATA`) →
   **C2g-3** ALU + reduction loop → **C2g-4** rosnet matmul, bit-correct vs the CPU reference. C2g-1 is
   IN PROGRESS (burn 1 1.54.17 PARTIAL; burn 2 1.54.18 the shader's stores don't land — the CPU read
   only a **stale-L2 ghost** of the C2f value; 1.54.19 = a fresh-slot isolation diagnostic to split
   zero-waves vs a wrong-address). Then **C2h** = the ring-3 `gpu_*` band (mabda's agnos backend seam).

   **Key learnings baked in (see `gpu-arc-handoff.md`):** match the proven register-submit sequence
   byte-for-byte (WPTR **LO before HI** — the CP latches on the HI write); the **stale-L2 trap**
   (a CPU UC pre-seed of a GPU-written buffer gets clobbered — use a fresh slot). ⚠ **CORRECTED 2026-07-22:**
   this line used to read "`ACQUIRE_MEM` is write-*back*, not invalidate", and that is **wrong** for the
   post-dispatch variant. `GPU_CP_COHER_CNTL_TCWB = 0x00840000` is `TC_WB_ACTION_ENA(1<<18)` **plus**
   `TC_ACTION_ENA(1<<23)`, and bit 23 is the L2 **INVALIDATE** — settled against a RADV IB decode captured on
   this same Cezanne (`mabda .../radv-triangle.ib.txt:12-27` forces the field mapping; `:1649-1656` shows
   `CACHE_FLUSH_AND_INV_TS_EVENT` carrying exactly `{TC_WB=1, TC=1}`). The stale claim is not academic: it is
   the **root cause of plan-S3 arm D's design**, which primed L2 with a dispatch whose own trailing packet
   then invalidated the lines it had just populated, making both sub-arms unfalsifiable on the 1.56.4 burn.
   The author reasoned about precisely that hazard one comment earlier and reintroduced it four lines later,
   because this doc said the packet could not invalidate; **byte-confirm every ISA/PM4 encoding** (`llvm-mc -mcpu=gfx90c`
   ground-truth + 2 adversarial re-derivations); the **diagnostic-ladder** discipline (localize before
   fixing on iron). Each bite: `gpu-c2*-derive` / `gpu-c2g*-derive` workflow + a CONFIRM/FALSIFY tracker.
2. **GPUVM page-table format** (C1) — gfx9 multi-level PTE/PDE encoding + TLB-flush must be exact;
   a wrong PTE reads garbage. Derive from `gmc_v9_0.c`.
3. **Shader ISA** (C3) — hand-assembled gfx90c kernels are the MVP (LLVM assembler validates); a
   Cyrius→gfx90c codegen backend is the long-range ambition, NOT required to land C3–C6.
4. **Reg-base segments** — Renoir/gfx9 base tables extracted exactly; F0's ID-register check guards.
5. **Flip-lock discipline** (P1), **DMCUB** (P3/P6 — expected NOT needed for lit-pipe flip/audio;
   if P3 proves DMCUB-gated, document + proceed with the rest).
6. **Decade-map note**: 1.5x was pencilled "Intel" ([[project_hardware_target_version_lines]]); AMD
   has owned 1.50–1.53 in practice. 1.54.x stays AMD/archaemenid — flag only.

## Non-goals (this arc)

NVIDIA / Intel-Arc / RDNA-discrete (other vendors/arches) · a Vulkan/OpenGL *API* surface (we emit
sovereign shaders + PM4 directly, not a GL/VK driver) · the NVIDIA PTX-compute leg (separate,
per the agnosticos decade map). Full modeset is in-ambition but may spill to a follow-on arc
(P6+). Everything else — compute AND display — is IN.

## Pointers

- Iron log: `#tracker-153x-hdmi` (the display-audio handoff P3 resumes); F0/C0 trackers written at
  execution open.
- agnosticos state.md (HDMI-audio + mirshi/ai-hwaccel deferrals point here); agnosticos roadmap
  "mabda native compute" + "attn11 GPU move" notes — this arc is the KERNEL half that unblocks them.
- Memories: [[project_gpu_arc_not_cyrius_gated]] · [[project_agnos_kernel_growth_rules]] ·
  [[project_ml_ai_arc_overview]] (rosnet/attn11/tentib — the compute consumers) ·
  [[feedback_driver_code_is_the_bite]] · [[feedback_redesign_dont_reinvent]].
- Web sources (2026-07-10): [tinygrad 7900xtx MEC](https://github.com/tinygrad/7900xtx/blob/master/docs/MEC.md) ·
  [LLVM gfx90c ISA](https://llvm.org/docs/AMDGPU/AMDGPUAsmGFX900.html) ·
  [kernel amdgpu ring-buffer](https://docs.kernel.org/gpu/amdgpu/ring-buffer.html) ·
  [amdgpu driver-core / GPUVM](https://docs.kernel.org/gpu/amdgpu/driver-core.html) ·
  [amdgpu glossary](https://docs.kernel.org/gpu/amdgpu/amdgpu-glossary.html) ·
  [kgd_kfd_interface.h](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/amd/include/kgd_kfd_interface.h) ·
  [DCN 2.1 docs](https://docs.kernel.org/6.9/gpu/amdgpu/display/dcn-blocks.html) ·
  [Phoronix Renoir DCN 2.1](https://www.phoronix.com/news/AMD-Renoir-DCN-2.1-Patches) ·
  [linux-hardware.org Cezanne 1002:1638](https://linux-hardware.org/?id=pci:1002-1638-103c-8895).
