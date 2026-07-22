# AGNOS Kernel Roadmap

<!--
  TOOLING ANCHOR — DO NOT PUT VOLATILE PROSE ON THE "Current" LINE BELOW.
  scripts/version-bump.sh runs exactly two seds against this file:
      s|> \*\*Current\*\*: v[0-9]+\.[0-9]+\.[0-9]+|> **Current**: v$NEW|
      s|Built with cyrius [0-9]+\.[0-9]+\.[0-9]+|Built with cyrius $CYRIUS_PIN|
  Both replace ONLY the version NUMBER. Any prose you add around them is never
  updated by any tool, so it rots on the very next cut and then lies until a
  human notices. That is exactly how the old line 3 became a 13,771-character
  blob describing an arc that had closed twenty cuts earlier.
  Keep the Current line to a pointer. Volatile state belongs in state.md.
  If you delete either anchor string, the corresponding sed becomes a silent
  no-op — no error, no warning. (The "Built with cyrius" anchor was deleted at
  some point and that sed did nothing for months; restored 2026-07-14.)
-->

> **Current**: v1.55.32 — live state (kernel head, cyrius pin, active burn, sweeps, sizes) lives in [`state.md`](state.md).

> **This file is forward-facing.** Completed arcs are not re-narrated here — each gets one line in the
> [Completed arcs ledger](#completed-arcs-ledger), and the history is the CHANGELOG's job. Per-arc reasoning
> lives in the plan docs under [`planning/`](planning/). This file must not restate `state.md`; it points at
> it. Release criteria (beta, GA, the maturity arc) are not kept here either — those live in the agnosticos
> roadmap.

> Live state: [`state.md`](state.md). Per-version history: [`../../CHANGELOG.md`](../../CHANGELOG.md).
> Normative syscall contract: [`agnos-userland-abi.md`](agnos-userland-abi.md).
> Language roadmap: `../../../cyrius/docs/development/roadmap.md`.

---

## Active — 1.55.x display (Thrust P)

Own the GOP-lit DCN 2.1 pipe on the archaemenid Cezanne iGPU. Plan doc:
[`planning/kernel-display-arc-155x.md`](planning/kernel-display-arc-155x.md).

Landed and iron-passed: reading the pipe (P0), the scanout flip that was agnos's first DCN write (P1),
vblank pacing (P2), the double-buffered present loop, and `blit`#39 double-buffering — DOOM now renders
tear-free through the sovereign display stack on real hardware with no application change. Cleanup and
hardening followed at 1.55.7. See the CHANGELOG entries for 1.55.0 through 1.55.7 for the detail.

**Current bite — A4, HDMI display audio. The DCN audio register class is EXHAUSTED.** Every audio register
agnos writes now matches the live amdgpu known-good
([`dcn-audio-live-amdgpu-known-good-2026-07-15.md`](../../../agnosticos/docs/development/prior-art/dcn-audio-live-amdgpu-known-good-2026-07-15.md),
full BAR5 + all 34 Azalia ordinals × 8 endpoints, captured while the panel was audibly playing)
**byte-for-byte**, and the panel is still silent. Feed, codec, magnitude, and DCN sequence are all
**exonerated**: a Linux userspace driver replaying agnos's *exact* feed on amdgpu's pipe **played sound**.
The sink is confirmed audible under amdgpu on this panel (operator-confirmed by ear, 2026-07-15) — agnos's
silence is agnos's bug, that premise is settled, do not re-open it. The remaining gap is **not** a
display-audio register: it is the **firmware-driven HDMI transmitter/encoder bring-up the GOP does as DVI**.

**A2 / A3 — DONE and PROVEN BIT-CORRECT ON IRON (the strategic prize of the arc).** A2
(`gpu_vbios_acquire` in `gpu.cyr`) acquires the vendor VBIOS; A3 is a sovereign ~700-line Cyrius **ATOM BIOS
interpreter** (`kernel/core/atom.cyr`) that runs the vendor's own VBIOS bytecode. The 1.55.23 DRY trace
matches the `atom-interp.py` oracle **exactly** — encoder 5 writes; transmitter 21 reads / 17 writes / 5
delays; no amdgpu. Iron proof:
[`atom-iron-dry-trace-0718.txt`](../../../agnosticos/docs/development/prior-art/atom-iron-dry-trace-0718.txt)
against the oracle
[`atom-oracle-writes-0718.txt`](../../../agnosticos/docs/development/prior-art/atom-oracle-writes-0718.txt).
This interpreter is the **P6 cold-modeset foundation** — already in hand.

**▶ A4 is OPEN. Current lead — the DCCG symbol-clock re-prime.** agnos omitted the SYMCLKA write
(abs `0x159` = `0x000d000d`) that amdgpu makes for HDMI. Confirmed as DIG1's clock: DIG1 routes to UNIPHYA
(phyid 0), and amdgpu's own HDMI-on-DIG1 set `0x159` active (its AVI landed at `0x564d` = DIG1
`AFMT_GENERIC_0`). Host-visible, display-safe, under test (`BURN_HDMI_DCCG`). Lead was read off
[`amdgpu-hdmi-modeset-writes-0717.txt`](../../../agnosticos/docs/development/prior-art/amdgpu-hdmi-modeset-writes-0717.txt).

**Iron-confirmed A4 findings:**
- The ATOM transmitter-enable #76 **power-cycles the PHY** (`556F` / `5E03` / `5DF0`) and blanks the live
  console pipe **non-recoverably** — not usable as-is on the running pipe.
- The encoder-setup-only #4 is **display-safe but SILENT** (exonerated).
- **Fallback if DCCG fails:** the full HDMI modeset (SetPixelClock #12 + transmitter + OTG re-commit)
  wrapped in a self-recovering OTG-frame-count watchdog; the transmitter is DMCUB for amdgpu (opaque) but
  host-ATOM #76 for agnos.

**Process lesson from this cycle:** a new `#ifdef` mode-flag needs its `build.sh` define line, and you verify
it by `cmp`-ing the two binaries, not by the burn tag — the `ATOM_DRY` flag was a no-op for two burns.

*Superseded:* the fifteen-burn "still mute" register-diff hunt (the DCN audio register class is now
byte-exhausted), and the AFMT_AUDIO_CRC tap-identity zero-burn measurement — the taps were proven
PCM-content-sensitive on the working amdgpu path, closing that branch
([`dcn-audio-crc-tap-identity-2026-07-15.md`](../../../agnosticos/docs/development/prior-art/dcn-audio-crc-tap-identity-2026-07-15.md)).
The search has moved off the display-audio registers and onto the transmitter/encoder bring-up.

### Remaining ladder

| Bite | Scope |
|------|-------|
| **P4 — scanout-residue clear** | Clear the AMD Zen Quiet-Boot scanout residue using the P1 re-point primitive, for a clean first paint. This subsumes the long-parked standalone "AMD Zen scanout residue" item — the two are one bite now that P1 shipped the primitive. It does not block MVP: the VGA path is legible at 1080p and 1440p. The two resumption options remain a HUBP `clear_tiling` port (the Linux `drivers/gpu/drm/amd/display/` analog) or a shadow-buffer FB-console architectural evaluation (simpledrm-style); both forms of another GOP `SetMode` lever were falsified at Attempt 78. Pin: `project_amd_zen_scanout_residue`. |
| **GFX-ring 2D acceleration** | Accelerated `blit`#39 and a GPU-composited aethersafha. |
| **P6+ — 3D and full modeset** | RADV-derived GFX-ring blits over the C1/C2 ring machinery, plus DCN mode-set, DP link-training, and DMCUB. Likely a follow-on arc — but the **cold-modeset foundation is already in hand**: the sovereign Cyrius ATOM BIOS interpreter (`kernel/core/atom.cyr`, the arc's A3) runs the vendor VBIOS bytecode bit-correctly on iron (proven at 1.55.23), so a sovereign modeset does not need DMCUB. It is in the ambition and is not written off. |

Numbering note: this file previously called 2D acceleration "P5". The display-arc plan doc's ladder has no
P5 — it goes from P4 straight to P6+. Reconcile before anyone codes against either. See
[Open questions](#open-questions-for-the-human).

### Carried out of the closed 1.54.x GPU arc

**C6 — run an attn11 or tentib layer on the GPU** (the arc's stated crown) is **still open**. The kernel
seam is proven: integer compute over syscall #82, and f64 over #83, rosnet-bit-correct from ring 3. But no
CHANGELOG entry claims an ML layer has actually executed on the shader cores — every phrase in the record is
about the seam that ML layers *ride onto*. This is a userland and ML-consumer item, not a kernel one. Arc
plan: [`planning/kernel-gpu-arc-154x.md`](planning/kernel-gpu-arc-154x.md).

---

## Near-term (open, unslotted)

| Item | Status | Notes |
|------|--------|-------|
| **Bigger usable user stack (exec-from-disk layout)** | Open | `elf.cyr`'s exec path maps a 2 MB stack page at `stack_base=0x3FC00000` but starts `rsp` at `stack_base + 0x3000`, so a program gets only **~12 KB of usable downward stack** — the ~2 MB above `rsp` is mapped but wasted, since the stack grows down. Any program whose frame exceeds ~12 KB overflows into the unmapped page below `0x3FC00000` and takes a CPL3 page fault. `iam` hit exactly this: `main` had ~17.6 KB of stack buffers, hard-faulted, and never rendered; it was worked around app-side by heap-allocating the big buffers in iam 1.1.5. **Fix:** put the init-stack layout (argc, argv, envp, auxv) near the top of the mapped 2 MB page and set `rsp` there, giving every program ~2 MB of real downward stack in the same already-mapped page, with no new mapping. Low-risk, but it touches every program's entry layout, so validate against the full `exec-smoke`. Trigger: any real program with a >12 KB frame, or just do it — 12 KB is absurdly small. |
| **Socket-as-VFS-fd bridge (VFS-fd unification)** | Open — non-obviously so | Landed at 1.49.4, then partially reverted at 1.53.9: `sock_accept`#57 returns the raw `conn_id` again, because the cyrius `net.cyr` treats the return value as a `conn_id`. Accepted sockets are therefore **not epoll-able**; `vfs_create_sock` exists but nothing consumes it. The goal stands — bridge accepted connections into the per-process fd table under a `VFS_SOCK` tag so `epoll`, `read`, `write`, and `close` work uniformly on sockets. This folds into a broader VFS-fd unification and should be slotted with it. Note for whoever picks this up: the comment at `syscall.cyr:2431` still describes the 1.49.4 behavior and contradicts the code — fix it in passing. |
| **Path 2 — per-proc syscall kernel stacks** | Open, tracked, deferred | Opened 2026-07-10 out of the mishran two-proc audio bring-up; plan doc [`planning/blocking-syscall-concurrency.md`](planning/blocking-syscall-concurrency.md). Path 1 (userland cooperative yield) shipped and is QEMU-validated. The invariant Path 2 would lift is load-bearing and currently constrains the whole userland: every process on a CPU enters syscalls on one shared per-CPU stack (`pcpu_syscall_kstack_top = 0xF10000 + cpu*0x10000`, `syscall_hw.cyr`); only the *interrupt* entry stack went per-process at 1.46.1. That is why `preempt_disable()` guards every blocking sti-window and why `sys_sched_yield`#44 is an abandon-frame yield. |
| **`lstat`** | Open | `readlink`#70 landed at 1.53.6 and its cyrius peer exists, so `lstat` is the only half of the old pair left. Slot when a consumer — kriya `ln -s`, or ark install layouts — demands it. |
| **kriya `ln -s` un-gate on agnos** | Open — userland | Both kernel halves are ready: `symlink`#63 (1.51.0, cyrius peer 6.3.6) and `readlink`#70 (1.53.6). kriya still gates the verbs off at `src/lib/sys.cyr` (`K_HAVE_SYMLINK = 0`), and both `ln.cyr` and `readlink.cyr` refuse cleanly on that gate. The gate is stale, not blocked — flipping it is a clean kriya-repo follow-on. (kriya is at 1.1.7 on cyrius 6.4.20; the older "pinned 6.2.24" note in this file was wrong.) |
| **`ai-hwaccel` ride-along** | Open — userland | The `#89` side, plus a rebuild and re-stage of `iam`; this kills the mirshi ENOSYS. The kernel half (`readlink`#70) is done. |
| **`iam` Kernel line shows `AGNOS <version>`** | Open — verify only | Backlogged 2026-07-05: iam's Kernel line reads a bare `AGNOS` rather than `AGNOS 1.55.x`. The kernel side is done and the whole chain is wired — `kernel/version.cyr` holds `_AGNOS_VERSION`, `uname`#34 writes it to `release@32`, `mihi_uname` calls `sys_uname`, `mihi_kernel_version` returns `uts+UTS_RELEASE`, and `iam_render_kernel` already prints `name version` (the Linux path proves the renderer). A current build should already read the version, so the bare string was almost certainly a stale staged iam. The work is a **verify** in the post-arc userland pass: rebuild iam `--agnos`, re-stage, boot the `iam-agnos-verify` harness, confirm. Only if it is still bare, check whether `release@32` is NUL-terminated in its 16-byte field. No new kernel work expected. |
| **`bg-fault` on-iron survival** | **Uncertain — confirm** | A faulted background job (`&`) halts rather than being torn down; bg-proc fault teardown needs a scheduler-yield-from-fault path. Recorded at 1.50.9 as riding the next burn, with the deterministic bg-fault integration test deferred as heavier than a hermetic selftest. No CHANGELOG entry since claims either that survival was observed on iron or that the yield-from-fault path was written. It may have ridden a later burn silently, or it may never have been exercised. |
| **Backspace on iron** | **Uncertain — free to verify next burn** | A 1.42.x residual. The original diagnosis blamed the delivery layer, not the kernel: Backspace was not arriving as `0x0E` under archaemenid's UEFI USB-legacy emulation. That entire layer has since been replaced by the native interrupt-driven xHCI USB-HID path, iron-closed at 1.53.14, which maps the key explicitly (`hid_translate.cyr`, `0x2A` to `0x0E`). The probable cause is gone, but "probably fixed by a rewrite of the layer underneath" is not evidence of a fix, and no burn has confirmed it. Costs nothing to check: press Backspace at the `[ASSIST] >` prompt. |
| **Bench-history snapshot in repo** | **Uncertain — one command settles it** | Decide whether to check in the last-released `BENCHMARKS.md` and `bench-history.csv` as a tagged-state reference, or leave them CI-only. Both files exist in the working tree, neither is gitignored, and `.github/workflows/ci.yml` already uploads both as a 90-day artifact — so the CI half is live. Whether they are git-tracked could not be determined here (git is off-limits to the agent); `git ls-files BENCHMARKS.md` answers it. Original v1.27.1 carry-forward. |
| **Optical via USB-MS (SCSI MMC profile) or ATAPI** | Open — no slot | The surface is stubbed but not driven: `msc_print_pdt_label` decodes optical PDTs while Phase 4 does not differentiate handling by PDT, and `msc_read_demo` skips silently when the sector size is not 512. AHCI likewise skips ATAPI ports. The HP external USB Blu-ray derps archaemenid at cold boot if it is plugged in before power-on (a USB hand-off or firmware quirk); hot-add support would fix the cold-plug quirk as a side effect. Alternative iron path: the AllInOne internal CD/DVD, likely SATA ATAPI, which would revive the previously-punted ATAPI/AHCI passthrough. The old "folds into 1.35.x plug-and-play" slot is dead; this needs a new one. |
| **Hardware-validation infra** | Open — **needs a new rationale** | An RPi4 and NUC harness on the self-hosted runner. No harness exists and nothing under `.github/workflows/` references one. Its only stated justification was "unblocks SMP-AP-wakeup-on-real-hardware", and that item shipped without it — validated by direct archaemenid burns in the 1.46.x arc. So this either needs a fresh justification or should be re-sited as a 1.6x-decade (Pi) prerequisite. |

---

## Future minors (slotted)

Slot numbers are the intended sequence, not commitments. Each is a feature-class lift in its own right;
confirm scope before opening any.

### Gated on the ark self-host milestones (M5/M6)

Filed out of the 1.51.x sovereign-package-manager arc. Cross-repo plan:
`agnosticos/docs/development/planning/ark-v2-sovereignty-path.md`.

- **Atomic system-update / boot-slot primitive** (ark M4) — the AGNOS-side update mechanism the maturity arc
  names. It is absent in gnoboot, whose "slots" are `boot_info` fields, and absent in agnos, where
  `reboot`#13 is a stub that calls `arch_halt()`. **A design call is owed first:** an A/B image swap that
  gnoboot selects on boot, versus an ark-driven in-place re-materialize from a verified `.ark`.
- **Nested/recursive exec from a spawned proc** — `execwait`#37 refuses re-entry (the
  `pcpu_ew37_busy_get() != 0` guard returns -1, with the comment "out of scope until the multithreading
  arc"). takumi is itself a spawned ELF and must exec N build children, so it must drive `spawn_path`#43
  plus a polling `waitpid`#4 loop.
- **argv/env length caps raise** — `#37` and `#43` cap path and argv at 127 bytes, and env at 1024 bytes
  across 16 entries; build invocations exceed both. Pairs with nested exec. The argv *token* cap was already
  raised from 8 to 16 at 1.46.10, so the byte and entry caps are what remain.
- **Build confinement** — this **converges with the deferred "Native sandbox-confinement primitives"** item
  below. The takumi build sandbox is a *consumer* of that same primitive; **do not build it twice.** The
  alternative is an explicit no-op-with-warning at server bring-up.

### Userland environment and tools

- **Link `commandress` (`cmdrs`, prompt), `bannermanor` (`bnrmr`, MOTD), and `mihi`/`iam` (sysinfo) as agnsh
  builtins.** Each needs its own `CYRIUS_TARGET_AGNOS` build. The kernel side is already there — `uname`#34
  and `sysinfo`#35 both landed in the 1.42.x sysinfo surface, and `sysinfo`#35's `totalram`/`freeram`
  counters are the meminfo need. The old claim that this needs new kernel syscalls was wrong; what remains
  is the userland builds.
- **`ai-hwaccel` agnos compatibility.** `mihi`, `iam`, and `chakshu` sysinfo display is blocked because
  ai-hwaccel's GPU probe pulls `thread`, `atomic`, and Linux `CLONE_VM`. Either it is driven on
  ai-hwaccel's own agent roadmap, or it is made `CYRIUS_TARGET_AGNOS`-compatible so the GPU-probe sysinfo
  items render correctly. The stated precondition — "once agnos *has* threads" — has fired: the 1.44.x
  multi-threading arc closed and AP scheduling is live. This is schedulable now, not blocked.
- **`sit` → AGNOS port** (flagged 2026-06-23; a userland rider, not a kernel item). Unblocks `owl` 1.4.x's
  `bat`-like VCS change-marker gutter on agnos. `owl --agnos` currently fails at the `sit` dep, because
  `sit` calls `syscall(SYS_CHDIR, …)` (`owl/lib/sit.cyr:8640,11787`). **The first blocker is a design
  collision, not a missing syscall:** agnos deliberately has no `chdir` or `getcwd` syscall — CWD is
  userland-owned per ABI §3.2, the 1.41.3 decision — so the port must make `sit`'s object store and wire FS
  operations free of CWD-relative paths, using absolute paths or a userland-tracked CWD, and must **not**
  add a kernel `chdir`. After that, `sit`'s `wire` and `tls` tail rides the 1.45.x net syscalls. The working
  agnos `owl` is 1.3.8 (cat-only, pre-`sit`); owl 1.4.x already gates the gutter *call* off for agnos, but
  the `sit` dep itself will not compile until this lands. (`project_tools_stable_ideas`)
- **`tcsetattr`/`ioctl` no-op stub** may be needed for darshana-class TTY tools. Distinct from `winsize`#60,
  which shipped — do not conflate them.
- **Adopt `winsize`#60 in the remaining consumers.** The kernel half landed at 1.45.13 and `darshana`'s
  `tty_winsize` consumes it on agnos. Still unverified: whether `kii` dropped its 80×24 agnos fallback in
  favor of real-size art, and whether `cyim` and `chakshu` are resize-aware. Per-repo state in three
  consumer repos — confirm before treating as done.
- **Re-stage current kriya on agnos-fs.** The kriya/owl coreutils delegation is itself iron-confirmed — the
  1.46.5 burn ran `ls`, `kriya`, `bnrmr`, and `owl` from the shell with no argv-empty page fault. The older
  form of this item asked for a kriya 1.1.4 mount-copy to clear a stale-cyrius-pin miscompile; kriya has
  since moved to 1.1.7 on cyrius 6.4.20, so that premise is obsolete. What is left is a userland chore:
  re-stage current kriya. Confirm it is still wanted.

### Networking and the server tier

- **Minimal HTTPS client, then `ark` package-fetch over HTTPS.** Descoped from the 1.45.x arc into its own
  arc, and **it has no slot**. The network-tools family tail rides with it. Phase A tools — `yo`, `dig`,
  `whirl`, `taar` — are done per the 1.45.x close.
- **Server-app tier** — userland work on the kernel surface that already shipped at 1.45.5 (`sock_listen`#56
  and `sock_accept`#57). Consumers: **`agora`**, the telnet-served BBS with Sigil-backed Ed25519 auth,
  threaded boards, door games, and Persistent-Universe multiplayer; and **`cyrius-yeomans-descent`**, the
  AGNOS MUD, which agora's planned `descent` door gates into. Together they prove the *server* maturity stage
  on the 1.32.x networking surface (`project_agnos_maturity_arc`). **Blocked, not merely unported:**
  `agora/src/main.cyr:2702` calls `sys_fork()`, and agnos has no fork syscall. agora already carries
  `CYRIUS_TARGET_AGNOS` gates, so the port is underway, but its fork-per-connection concurrency model is
  architecturally incompatible with the spawn/waitpid surface and needs rework. `descent` is
  epoll-adaptable. (`project_server_stage_agnos_adaptation`)
- **LLM / `hoosh` gateway wiring** — its own later arc, explicitly out of scope for the shell work. **It has
  no slot anywhere in this file**, which is a conspicuous hole for an AI-native OS. Confirm scope before
  opening.

### Memory and RAM

- **Multi-region contiguous bitmap for more than 64 GB.** One 2 MB bitmap covers 16,777,216 pages, which
  caps coverage at 64 GB; RAM beyond that is capped and logged, not silently dropped. Fine for the 60 GB
  box, a real ceiling beyond it.
- **`mmap` follow-ons** — 4 KB-granular and partial mapping (needs a 4 KB user-paging level, a large VMM
  arc), file-backed mapping (needs the VFS page cache), and a vaddr free-list to reclaim non-top arena holes
  (only if a consumer shows real fragmentation). `mmap` is still 2 MB-granular at 1.55.14, and neither
  prerequisite exists in the tree. Slot when a consumer's churn demands them.
- **Userland >1 GB mmap program** — live-path validation of the 1.50.2 arena lift, deferred 2026-06-29. The
  kernel mmap full-lift is iron-validated via `MMAP_HIMEM_E2E_SELFTEST`, a 1.026 GB contiguous map-and-free
  on real Zen, but the *live* `sys_mmap`/`sys_munmap` **syscall** path above 1 GB has no ring-3 consumer —
  the selftest drives the mechanism directly. The work: write a userland program that maps more than 1 GB,
  touches every page, and unmaps; stage it on disk and run it as the end-to-end iron test of the live path.
  The per-process cursor (1.50.4) and high-range `munmap` (1.50.3) are already in place for it. **The stated
  trigger has fired** — the item named a desktop-class workload (a large compositor surface, a big
  in-memory dataset) and the desktop is now live on agnos, so this is imminent rather than speculative.

### Cleanup carried out of the 1.44.x arc

Both were deferred at the 1.44.22 audit as not worth perturbing iron-validated code, and neither is
`proc_get_ppid`-blocked (that stub was fixed at 1.50.7). Note the original trigger — "slot when SMP or
loader work opens" — already came and went: the 1.46.x SMP arc opened and closed without touching either, so
they stayed deferred deliberately.

- **MADT AP-enumeration**, versus the hardcoded AP count of 4 in `smp.cyr`. No MADT parsing exists anywhere
  in the kernel.
- **Loader DRY** — share out the in-memory `spawn_user_proc`/`elf_load` path against `elf_load_from_file`.
  Both paths still carry near-duplicate stack-mapping logic. This is a refactor inside the iron-validated
  exec path.

### Later — cyrius-gated

- **agnos 2.0 — clean refactor / rewrite.** Pushed back repeatedly, most recently on 2026-06-29; the pattern
  of deferral is itself the signal worth recording. The rewrite is a 2.0 concern and stays **deferred until
  the base-to-server kernel-surface backlog is worked down** — the additive-surface items above take
  priority over it. **The old "held on Cyrius's cadence" gate is largely cleared:** the type system
  (v5.10.x), closures (v6.x), and userland PIE (v6.1.41) all shipped. The genuinely unshipped prerequisite a
  clean rewrite wants is **native generics and monomorphization**, which cyrius's `roadmap-future.md`
  carries **unpinned** — so the rewrite is **not schedulable until that lands**. Re-confirm against the
  cyrius roadmap when it approaches; do not assume. Cyrius stays hands-off
  (`feedback_cyrius_hands_off`).

---

## Deferred (no slot yet — confirm scope before opening)

| Item | Notes |
|------|-------|
| **HDMI/DP audio residue** | The active A4 bite covers getting sound out the video cable. What it does not cover, and what stays deferred: **ELD and hotplug** — which display is attached and what formats it supports — **per-sink stream routing**, and the **`core/audio/` multi-file driver form** the 1.52.x arc-open note flagged as this item's likely trigger. Two corrections to the old framing: this is no longer "its own later arc, no consumer demand yet" (it is the active bite), and the planned approach of a second-function probe at `04:00.1` with HDMI-codec enumeration is partly superseded by the DCN-side route actually taken (DIG1 and Azalia endpoint 1). |
| **NTFS read + squashfs read** | Split out of the FAT-family decision on 2026-05-26 and deferred at 1.34.0. **NTFS** read gives Windows-volume interop; it is a complex on-disk format ($MFT, attribute runs, B-trees) and multi-source-audit-heavy. **squashfs** read is a compressed read-only FS and leverages `sankoch` (LZ4, DEFLATE, zlib, gzip) decompression in-kernel. Both read-only; each its own minor when slotted. Neither exists in the tree. |
| **HTREE indexed directory support (ext4)** | A linear dirent scan suffices for read, and `ext2.cyr` never creates htree-indexed dirs. HTREE is a performance optimization for huge directories of 10k+ entries. Queue when a real consumer needs it. |
| **Perf tail — syscall entry/exit and context-switch** | Deferred with reason at the 1.47.x perf-series close; the reasoning is the value. **Syscall entry/exit:** the `ksyscall` dispatch is already well-ordered — the hot syscalls (`exit`, `write`, `getpid`, `read`, `close`) sit at depths 1 through 7 of the linear `if (num == N)` chain — so a reorder or fast path is a near-zero real win, and the entry trampoline is hand-asm; not worth a hollow patch. **Context-switch:** the per-tick register save and restore is hand-asm, and the 1.44.22 audit flagged it low-headroom and higher-risk. Both queue behind a profile showing either is actually hot. Note this row supersedes the older, broader "more perf tuning" list — ext2 I/O and the scheduler single-pass both landed in the 1.47.x series, so only these two survive from it. |
| **Perf tail — block-IO batching** | The one remaining item from the 1.42.x perf surface that is neither landed nor covered by the rows above. Queue behind a profile. |
| **Perf tail — other-FS (FAT/exFAT)** | Captured 2026-06-27 so they are not lost; none is worth a patch on its own merits today. **(1) exFAT allocation-bitmap scan** reads the bitmap per sector, but it is metadata and the per-byte bit-counting loop dominates its runtime, so collapsing the I/O buys nearly nothing. **(2) fatfs multi-cluster write coalescing** is structurally blocked: `fatfs_write_file` allocates clusters one at a time via `fat_alloc_cluster` from every write path, so they are not guaranteed contiguous and cannot be coalesced — exFAT already writes its whole extent in one call because `exfat_alloc_contiguous` guarantees contiguity. This would need a contiguous-allocation strategy first. **(3) metadata single-sector I/O** — boot-sector reads (one-time, at mount), FAT-entry updates, and bitmap reads and writes are point updates, not amplified streams; there is no amplification to collapse. Trigger: a profile showing any is actually hot. |
| **Radios — WiFi + USB Bluetooth** | Proposed as its own decade, **1.7x** — see the decade map. Expected to be a multi-cycle "super pain": WiFi needs firmware, a mac80211-equivalent MLME, and a WPA2/WPA3 supplicant via `sigil`; USB Bluetooth needs HCI-over-USB on the xHCI stack, then L2CAP, then RFCOMM and GATT. Deliberately late so it inherits a proven IP/TCP/DHCP stack, battle-tested xHCI bulk and interrupt-endpoint machinery, matured `sigil` crypto, and the post-2.0 cleaner kernel. Confirm whether WiFi and Bluetooth split into separate cycles before opening. Nothing exists yet — no `core/radios/` directory, which is correct per `project_kernel_driver_family_subdirs` (the subdir appears the day wireless opens). |
| **Native sandbox-confinement primitives** | AGNOS-native equivalents of the Linux MAC stack that `kavach` wraps: **FS-confinement** (comparable to Landlock), **syscall-surface filtering** (comparable to seccomp-BPF), and **process isolation** (comparable to namespaces). As of 2026-06-22 `kavach`'s `security.cyr` returns `err_not_supported("LANDLOCK")`, `("SECCOMP")`, and `("NAMESPACES")` on AGNOS, so agnos sandboxes rely entirely on the capability layer for confinement; nothing matching landlock, seccomp, or confinement exists in the kernel tree. Provide native, **capability-scoped**, kernel-enforced confinement so sandboxes get real enforcement beyond capability gates — **not** Landlock, seccomp, or `unshare` ABI emulation, which stays in the compat and interpretive layer per `project_agnos_kernel_growth_rules` and `project_agnos_empire_defense_layers`. Trigger: a native sandboxing workload that needs enforced confinement. The consumer signal is already wired, since `kavach` reports the gap via `err_not_supported` and a daemon can surface "confinement = capability-layer only" today. **Converges with the 1.51.x build-confinement item — build it once.** **Adjacent cyrius-side prerequisite (filed):** the cyrius-stdlib `O_*` open-flag constants (`O_RDONLY`, `O_WRONLY`, `O_CREAT`, `O_TRUNC`, `O_EXCL`) are undefined for the agnos target — only the `AO_*` set exists, and the values differ (`O_CREAT` is 64 on Linux versus `AO_CREAT` at 0x100; `O_EXCL` has no `AO_*` peer), so a naive Linux-value define is wrong. The FS-confinement `sys_open` path and any agnos `open(O_CREAT|O_TRUNC|O_EXCL)` need these mapped to `AO_*`; the precedent is `sakshi.cyr`'s O_-to-AO translation. Tracked with the agnodrm gating in `cyrius/docs/development/issues/2026-06-22-agnosys-stdlib-security-fns-not-agnos-gated.md`. |

---

## Standing policies and boundaries

These are not work items. They are decisions that constrain future work, and they do not expire.

- **The in-kernel emergency shell is permanent, not transitional.** It is the boot fallback when no userland
  shell is reachable. The boundary — kernel is recovery only, userland is full interactive — does not
  collapse.
- **Kernel growth is per native workload.** Cyrius-native syscalls, not POSIX `socket()` emulation and not
  foreign-ABI absorption. (`project_agnos_kernel_growth_rules`)
- **`fb_phys` is never exposed.** Framebuffer access stays kernel-mediated — the hardened posture. The
  double-buffer that shipped at 1.55.6 preserves this.
- **Resample lives in the producer, not the kernel.** `snd_config` accepts native 44100 or 48000 Hz,
  16-bit, stereo only. This binds every future audio consumer.
- **CWD is userland-owned.** There is no `chdir` or `getcwd` syscall, and one is not to be added (ABI §3.2,
  the 1.41.3 decision).
- **`kriya` is the proper standalone `/bin` coreutils set** — the long-term tools refactor — and it
  **supersedes agnoshi's short-term in-process FS-verb builtins**, which were the temporary bridge while
  exec-from-disk-with-args did not exist.
- **`agnsh`'s AI, intent, and `hoosh`-gateway features are out of scope for the shell work.** LLM wiring is
  its own later arc.
- **The frozen syscall contract both sides code against is
  [`agnos-userland-abi.md`](agnos-userland-abi.md)** — the normative kernel spec in this repo; the cyrius
  peer mirrors it.
- **Cyrius is hands-off.** Surface bugs to the cyrius agent; do not edit that repo.
  (`feedback_cyrius_hands_off`)

---

## Explicitly not in the near-term queue

- **Apple Silicon as a kernel-on-iron target.** Userland apps in native Cyrius, and VMs, only; Asahi owns
  that lane.
- **POSIX `socket()` emulation.** See the kernel-growth rule above.
- **Landlock, seccomp, or `unshare` ABI emulation.** Native capability-scoped confinement instead; the
  emulation, if it ever exists, lives in the compat layer.
- **GRUB / multiboot2 boot path.** Superseded by gnoboot, the sovereign UEFI `BOOTX64.EFI`. *(Sourced from
  `project_agnos_bootloader_roadmap`, not from the prior roadmap text — confirm.)*

---

## Platform targets and long-range decade map

> **Speculative beyond the active line.** Slots at 1.5x and beyond are tentative and shift readily — confirm
> before opening any. Cross-session directive: memory `hardware-target-version-lines`. The whole map from
> 1.5x up already shifted one decade versus the original 2026-05-22 plan, because the AMD dev line outgrew a
> single decade.

Each X.Y *decade* carries either a hardware-platform bring-up arc or one big cross-cutting feature arc;
within a decade, the X.Y.Z minors progress through capability classes.

| Decade | Theme | Notes |
|--------|-------|-------|
| **1.3x–1.4x** | **AMD** — the primary dev line | archaemenid. This is the line that has carried every arc from MVP through storage, networking, the filesystems, graphics, multi-threading, audio, GPU compute, and now display. Per-minor history is in the CHANGELOG and in the ledger below. |
| **1.5x** | **Intel** platform | templemount (i9) and other Intel hardware surfaces. Carries the **i225-V NIC driver**, queued out of the 1.32.x networking arc — a separate hardware line, not an AMD blocker. (r8169/RTL8125 is done and iron-verified at 1.32.x.) **Collision: the AMD line is presently at 1.55.x, so it has already consumed the decade this map assigns to Intel.** The map's own caveat — that it shifted once because the AMD line outgrew a decade — has now fired a second time and nobody has renumbered. Unresolved; see [Open questions](#open-questions-for-the-human). |
| **1.6x** | **aarch64 / Pi** platform | Pi-class hardware; other open-ARM SBCs (BeagleBone, ODROID, Rockchip) likely ride here too. |
| **1.7x** | **Radios — WiFi + USB Bluetooth** *(a feature arc, not a platform)* | Gets its own decade because the wireless stack is expected to be a multi-cycle "super pain." Cross-platform. |
| **1.8x** | **RISC-V** platform | RISC-V boards on hand. Shifted from 1.7x when radios claimed that decade. |
| **N/A** | **Apple Silicon** | Not a kernel-on-iron target — userland apps in native Cyrius, and VMs, only; Asahi owns that lane. |

---

## v1.0 criteria

The kernel's release criteria are not maintained in this file. Beta, GA, and the maturity-arc gates live in
the **agnosticos** roadmap (`agnosticos/docs/development/roadmap.md`), which owns the ship milestones for
the system as a whole; the maturity arc itself is pinned in memory `project_agnos_maturity_arc`. This file
covers only what the kernel builds next. Do not fork a second set of criteria here — point at that one.

---

## Completed arcs (ledger)

One line per arc, by design. The CHANGELOG is authoritative for what changed and when, the plan docs under
[`planning/`](planning/) for how each arc was reasoned, and [`state.md`](state.md) for what is true right
now. Arcs before 1.40.x are recorded in the CHANGELOG and in `state.md`'s own closed ledger.

| Minor | Arc | Closed | Iron |
|-------|-----|--------|------|
| **1.40.x** | Exec-from-disk — read an ELF off a VFS path, load it, run it, collect the exit code. | 1.40.14, 2026-05-31 | Validated (burn `14013_final`) |
| **1.41.x** | Shell separation — the in-kernel shell moves to userland agnsh/agnoshi. | 1.41.15, 2026-06-05 | Validated (burn `14115`) |
| **1.42.x** | Kernel perf and hardening in parallel with the userland environment; the klug unified log ring and `klog`#36; the sysinfo syscall surface (`uname`#34, `sysinfo`#35). | 1.42.14, 2026-06-06 | Validated |
| **1.43.x** | Graphics path and the first real userland app — agnsh launches DOOM. Ring-3 blocking exec (`execwait`#37), framebuffer blit, ring-3 timing, envp, `kbscan`#42. | 1.43.8, 2026-06-09 | Validated (burn `1438`) |
| **1.44.x** | Multi-threading and preemptive scheduling. | 1.44.26, 2026-06-14 | Validated |
| **1.45.x** | TLS-prereq syscalls, then net sockets, then net tools: entropy and wall-clock, the four ring-3 socket hooks, UDP-53, ICMP-echo, Phase-B server sockets, `winsize`#60. | 1.45.17, 2026-06-23 | Validated |
| **1.46.x** | SMP locking foundation and per-process kernel stacks; the AMD SYSRET SS.RPL fix at 1.46.5 that unblocked the IF=1 preemptive agnsh on iron. | 1.46.11, 2026-06-27 | Validated 2026-06-26 |
| **1.47.x** | Fault-resilience, per-process fd tables, a six-item perf series, and **full-binary KASLR at 1.47.4** (with gnoboot 0.6.0) — an RDRAND-slid, 2 MB-aligned base in [32 MB, 254 MB) on a relocation-free PIE ET_DYN kernel, closing the value left over from the data-only scope shipped at 1.28.0. | 1.47.8, 2026-06-27 | Validated |
| **1.48.x** | Other-FS perf review — FAT and exFAT cluster-read amplification collapse. | 1.48.2, 2026-06-27 | Validated |
| **1.49.x** | Kernel-capability gaps: full RAM init above 256 MB, and the loopback interface. | 1.49.12, 2026-06-28 | Validated on real 64 GB Zen |
| **1.50.x** | RAM full-usage continuation, boot-CR3 to own PML4, the mmap-arena lift, and process-isolation hardening. | 1.50.10, 2026-06-29 | Validated |
| **1.51.x** | Sovereign package-manager kernel surface — the ark v2 and agnova prerequisites, including `symlink`#63 — plus the NIC RX-interrupt latency fix. ark M3 proven end-to-end on agnos. | 1.51.9, 2026-07-03 | Validated |
| **1.52.x** | Audio output — the HDA/Azalia driver and the ring-3 `snd_*` band, syscalls #64 through #69. First sound from sovereign AGNOS. | 1.52.8, 2026-07-04 | Validated *(no explicit close sentence — see open question 5)* |
| **1.53.x** | Multi-thrust: FP/SIMD in ring 3, console perf, shm and setu, the raw-block install primitives (#75–80), `readlink`#70, `readdir`#81, and native xHCI USB-HID. The 1.53.5 HDMI-audio bites left the backlog the 1.55.x display arc (A4) is working. | 1.53.14, 2026-07-10 | Validated (explicit) |
| **1.54.x** | **GPU compute — the crown.** Sovereign gfx90c compute proven on iron with no amdgpu and no ROCm: firmware load, engines, GPUVM, CP/MEC, PM4, hand-assembled shaders, integer and rosnet-bit-correct f64 matmul, exposed to ring 3 via syscalls #82 and #83. Plan: [`planning/kernel-gpu-arc-154x.md`](planning/kernel-gpu-arc-154x.md). | 1.54.33, 2026-07-14 | Complete end-to-end, iron-proven |

---

## Open questions for the human

Flagged rather than resolved. Each is a place where the sources disagree, or where the CHANGELOG does not
support a claim the previous version of this file made.

1. **SMP-AP wake was claimed three incompatible ways** in the file being replaced — open and gated on
   hardware infra, iron-green with real ring-3 processes on woken APs, and gated off on iron with
   `smp_wake_enabled=0`. **The source resolves it: it is done.** `main.cyr` has `smp_wake_enabled = 1`,
   `smp.cyr` has `smp_sched_aps = 1`, and `smp.cyr` states both are iron-validated in the 1.46.x arc —
   corroborated by the STEP-1 burn `1461` at 1.46.3 (`cpus online: 4`) and by the 1.47.0 opener recording
   STEP-2 as iron-validated on 2026-06-26. It is therefore folded into the 1.46.x ledger row above and is
   **not** carried as an open item. Confirm that reading is right; if it is, memory and any stale
   `state.md` gate lines should follow.
2. **C6 — attn11 or tentib on the GPU.** The kernel seam (#82, #83) is proven by the CHANGELOG. An ML layer
   actually executing on the shader cores is not claimed anywhere — every mention is about the seam ML
   layers ride onto. Kept open per no-invented-status.
3. **P-ladder numbering.** This file called GFX-ring 2D acceleration "P5"; the display-arc plan doc has no
   P5 and goes from P4 to P6+. The plan doc should own the ladder; this file should follow it.
4. **Decade-map collision.** The AMD line is at 1.55.x, but the map assigns 1.5x to Intel. Surfaced, not
   renumbered — renumbering is a user call and would contradict memory
   `project_hardware_target_version_lines`.
5. **1.52.x has no explicit close sentence.** Unlike 1.49.x, 1.50.x, 1.51.x, and 1.54.x — each closed by an
   explicit statement in the next arc's opener — the 1.53.0 opener never says 1.52.x is closed and
   iron-validated. The ledger lists it closed on the authority of memory `project_agnos_audio_arc` plus the
   fact that 1.53.0 opens a new arc, which is the project convention. Confirm the iron claim.
6. **`bg-fault` on-iron survival** was written at 1.50.9 to ride the next burn; many burns have happened
   since, and none records the outcome. It may have ridden one silently or never been exercised.
7. **Backspace on iron** — the probable cause (UEFI USB-legacy emulation) was replaced wholesale by the
   native xHCI HID path with an explicit `0x2A` to `0x0E` mapping, but no burn confirms the key now erases.
8. **Bench-history** needs one `git ls-files BENCHMARKS.md` to settle whether the files are tracked.
9. **`agora` is fork-blocked**, not merely unported — `sys_fork()` at `main.cyr:2702` against a kernel with
   no fork syscall. The old text listed it as an iron-validated agnos server-stage app, which is true of
   agora on its own terms but not of agora *on agnos*. Confirm before slotting the server tier.
10. **Hardware-validation infra** lost its only stated justification when SMP-AP wake shipped without it. It
    needs a new rationale or should move to the 1.6x decade.

### Pointer-health notes (not roadmap items, but they will mislead if left)

- **This repo's `docs/development/state.md` and agnosticos's `state.md` disagree.** Decide which is
  authoritative for kernel head and refresh the other, or the pointer at the top of this file resolves to a
  stale doc.
- **agnosticos `state.md` claims agnos pins cyrius 6.3.43.** The real pin is **6.4.2** (`cyrius.cyml:8`).
- **agnosticos `state.md`'s closed-arc ledger stops at 1.51.x** and does not list 1.52.x, 1.53.x, or
  1.54.x. The ledger above is ahead of it.
- **agnosticos `state.md` still parks "kernel-side FB double-buffer"** as an out-of-scope open item. It
  shipped at 1.55.6 — its stated trigger (observed tearing on iron) fired and was serviced.
- **`agnosticos/docs/development/planning/gpu-arc-handoff.md` is stale** — its "immediate next action" still
  reads C2g-1, which landed at 1.54.26 inside an arc that has since closed. It needs its own refresh before
  anyone follows it.
- **CLAUDE.md marks `naad` as "Ported"** while naad still carries 53 `.rs` files alongside 40 `.cyr` — a
  port in progress, not a completed one. An ecosystem-doc bug that had been parked in this roadmap; it
  belongs in the CLAUDE.md table refresh, not here.
- **`syscall.cyr:2431` documents the reverted 1.49.4 socket-fd behavior** and contradicts the code. Fix it
  whenever the socket-as-VFS-fd item is touched.

---

*Built with cyrius 6.4.2 · The `VERSION` file is the single source of truth for the kernel version; this
file's Current line is maintained by `scripts/version-bump.sh`. Sweep this file at each arc close: collapse
the closed arc to one ledger row, delete its forward-facing prose, and let the CHANGELOG carry the history.
Per-cut prose does not belong in this file — that is what made the last one 46,000 tokens.*
