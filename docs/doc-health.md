---
name: AGNOS Documentation Health
description: Living state of doc currency in the agnos repo — fresh / stale / archive / open-question, refreshed as docs are touched
type: state
---

# Documentation Health — agnos

> **Last refresh**: 2026-09-26 (**1.57.9 — a quiet `#44` + `sched_yield_to`#108, blocking pipe writes, AHCI recovery, CPU-only buffers and MSC on the direct map, the parallel sweep, the weighed-size tripwire; six issue files closed, three filed; see the 1.57.9 block**).
>
>
> ### 1.57.9 (2026-09-26) — six issues + two operator asks; every step began with a prior-art note
>
> ✅ **`CHANGELOG.md` 1.57.9** — Breaking (`#44` quiet again; `write`#1 on a pipe blocks — EPIPE partial/−1, `PIPE_BUF` 512, the
> agnsh pipeline consequence), Added (`#108`, the parallel sweep with measured 4,297 → 1,328 s, `AHCI_SELFTEST`, pipeline-smoke,
> weighed-size-check.sh), Changed (the weighed gate as a tripwire at `0x220000`, AHCI budgets + recovery, direct-map buffers, the
> MSC bounce), Fixed, Closeout (2,507,728 B; weighed 2,096,908 B; LOAD end `0x374270`), each with a one-line prior-art citation.
>
> ✅ **`state.md`** — Kernel head, on-disk row (new grant), carried-work bullet, open-issue bullet (three open, six archived), the
> direct-map bullet (fb_shadow/ramdisk/VT-d/MSC done; AHCI PRDT open). Held at the 120-line cap.
>
> ✅ **`roadmap.md`** — section "After 1.57.9"; the six shipped rows removed; rows for AHCI PRDT, VT-d, the harness backlog and
> the 256 MB `pmm_alloc_2mb_run` ceiling; the iron-burn row extended with 1.57.9's classes.
>
> ✅ **Issues** — six archived with rewritten Status headers and Resolution blocks (what shipped, the gate, the prior art, what it
> broke). Filed: `2026-09-26-ahci-puts-the-caller-buffer-in-the-prdt`, `-vt-d-xhci-never-granted-and-iommu-never-booted`,
> `-harness-backlog-after-1-57-9`. Sibling filings: agnoshi (pipeline read end, with the tested patch; poll+`#44` loops), kriya
> (`k_write` bound), cyrius (`#108` peer).
>
> ✅ **Written by the steps:** `docs/architecture/ahci-command-recovery.md` (NEW), `blocking-waits.md` (pipe writes, `#108`, the
> handoff), `dma-cpu-pointers.md` (status), ABI rows 1 / 5 / 44 / 108, `build.md` (`AHCI_SELFTEST`, the parallel sweep, the weighed
> tripwire). Prior-art notes live in the operator's `handoff-1.57.9/steps/*-prior-art.md`.
>
> ### 1.57.8 (2026-09-25) — the five 2026-09-25 issues ship; the release pass adds no code (D24)
>
> ✅ **`CHANGELOG.md` 1.57.8** — Breaking (`read`#5 a4 = 0 blocks on a pipe / channel endpoint, the r10 caveat,
> `#25`/`#97` notes, each with a migration note) · Changed (the `#44` directed kick with its price, the wait
> mechanics, the `dma_kva` rename, lifecycle-smoke on KVM, `hid_reclaim_selftest` placement) · Fixed (KVM+virtio UC
> PD[0], `chan_region_reserve` under gnoboot's CR3, NVMe one-behind, virtio-blk abandoned FLUSH, DMA identity VAs,
> HID mouse slots, cross-CPU tick-bound rounds, ENDFIX PIPE-R1) · gates/flags · closeout with sizes (2,503,272 B;
> weighed 2,092,452 B, 4,700 B headroom; LOAD end `0x373108`) and the iron-only risk list. Gate tallies left as
> `{GATES}` for the final-gates run.
>
> ✅ **`state.md`** — Kernel head row rewritten for 1.57.8 (the bump had stamped 1.57.8 over 1.57.7's text), on-disk
> row, the carried-work bullet, the open-issue bullet (six open, five archived), the direct-map bullet (every driver
> DMA structure; what is still identity), aarch64 no-new-names. Held at the 120-line cap.
>
> ✅ **`roadmap.md`** — the five shipped rows removed; the section is now "After 1.57.8"; new rows for the six
> filings plus the fb console blit (not a defect); reparenting marked carried; the iron-burn row extended with
> 1.57.8's iron-only classes.
>
> ✅ **`CLAUDE.md`** — closeout sweep row count 57 (`grep -c '^run_gate "'`), the six 1.57.8 rows named, tallies as
> `{CHECK}`/`{SWEEP}` for the final-gates run; the `pmm_kva_for_access` note gains `chan_region_reserve` and `dma_kva`.
>
> ✅ **Issues** — five → `archived/` with rewritten Status headers (RESOLVED 1.57.8 + what shipped + the proving gate)
> and a Resolution block naming what the change broke: cross-cpu-poll-and-yield (the spawnx a4 = 0 hang, the
> first-form kick on `#14`), dma-cpu-pointers (virtio-blk FLUSH found and fixed), hid-mouse, kvm-virtio-net-console,
> nvme-poll-timeout. NEW, OPEN: `2026-09-25-any-two-sched-yield-loops-kick-each-other.md` (operator ruling),
> `-pipe-writes-do-not-block.md`, `-ahci-timeout-abandons-an-in-flight-command.md`,
> `-msc-puts-the-caller-buffer-in-a-data-trb.md`, `-cpu-only-pmm-buffers-still-use-identity-vas.md`,
> `-three-smokes-score-void-as-fail-or-skip-smp4.md`. ⚠ **Stale path comments left for a code pass** (this pass may
> not touch `kernel/` or `scripts/`): `scripts/smoke/{ipc-wait,dma-shadow,xhci-shadow,nvme-late,hid-mouse-deferred}-smoke.sh`,
> `tests/ipcw/ipcw.cyr:2`, `kernel/core/{nvme.cyr:795,selftests.cyr:2375}` name `docs/development/issues/2026-09-25-*.md`
> paths that are now under `archived/`.
>
> ✅ **cyrius peer** filed in cyrius `docs/development/issues/2026-09-25-agnos-read-blocks-on-pipes-and-channels-and-the-44-kick.md`
> (`sys_read` must pass a4; the pipe/channel blocking contract; `CH_RECV` unchanged; `#44` kick and `#14` backstop
> semantics). The two earlier filings there are still open.
>
> ✅ **Written by the steps (not re-audited here):** NEW `docs/architecture/dma-cpu-pointers.md`,
> `nvme-io-completion.md`; updated `blocking-waits.md`, `kernel-clocks.md`, `net-concurrency.md`, `overview.md`,
> `agnos-userland-abi.md` (rows 5/14/25/44/97), `build.md` (four flags).
>
> ### 1.57.7 (2026-09-25) — the rest of the 1.57.x plan ships; the release pass itself adds no code (D24)
>
> ✅ **`CHANGELOG.md` 1.57.7** — Breaking (kill#16 acts, wait status `0x100|sig`, `#99` states 4–7, blocking `#37`,
> `#43` −3 on the global-fd fallback, the waits, `#48` D6, `#49` EOF, socket ownership, graceful close, `#56`
> class bits, `#52`/`#54` returns, the PT_LOAD page-sharing refusal, `mmap` no-overwrite, `#40` on the TSC — each
> with a migration note) · Added (`#106`, `#107`, `SPAWN_E_LIMIT` 7, `WAIT_BLOCK`, `KILL_TREE`, listen classes,
> flock −2) · Changed (S3c/S3d/S3b/S1b/S4/S6/S7, IMG) · Fixed (MSC CDB, ring-3 `#GP` wedge, HID key loss, inbound
> SYN, virtio TX, ENDFIX ×3) · gates · closeout with sizes, the red-by-design ABI gate and the iron-only risk list.
> Gate tallies filled by the final-gates run.
>
> ✅ **`state.md`** — Kernel head / on-disk rows re-derived for 1.57.7 (2,497,912 B; LOAD end `0x371c18` under
> `0x390000`); aarch64 32 fns / 17 vars; the 1.57.x plan bullet replaced by the 1.57.8 carried list; the issue
> bullet rewritten (five open, ten archived this release). Held at the 120-line cap.
>
> ✅ **`roadmap.md`** — the "§ 1.57.x — the rest of the 1.57.6 plan" table (all shipped) replaced by "§ 1.57.8":
> the five 2026-09-25 issues, reparenting (OQ-9), the dead-code audit (1.57.x closeout), per-OFD flock
> (unslotted), the foreground keyboard owner (OQ-10, later), retiring the out-of-band exec path (OQ-11, 1.58), and
> the Path 2 iron burn. TRUE lines: syscalls 0–107 (next free #108), "the waits still hold their CPU" (false from
> 1.57.7), the rekha row's boot-stack number; the "Nested exec — #37 re-entry" row removed (shipped); the
> ext2-smoke row notes IMG-fix's classified retries.
>
> ✅ **`CLAUDE.md`** — the image-bound note (`0x390000`, BSP boot stack top `0x3A0000`, the boot-time UEFI-map
> check, the gate on every build); closeout sweep row count by `grep -c '^run_gate "'` (49) and the 34/35
> by-design ABI red; aarch64 counts; check/sweep tallies left for the final-gates run.
>
> ✅ **Issues** — ten → `archived/` with rewritten Status headers (RESOLVED 1.57.7 + what shipped + the gate;
> `tcp-server-cannot-be-loopback-only` RESOLVED-KERNEL) and a Resolution block that names what the change broke,
> before the move: msc-cdb, sleep-ms, flock, inbound-tcp-syn, sock-recv-eof, socket-ids-no-owner,
> tcp-server-loopback-only, sock-send-and-connect, parent-cannot-end-stop-continue, no-per-process-resource-limits.
> Kept OPEN: `2026-09-25-cross-cpu-poll-and-yield-loops-are-tick-bound.md`. NEW for 1.57.8:
> `2026-09-25-dma-cpu-pointers-still-use-identity-vas.md`, `-nvme-poll-timeout-leaves-the-cq-one-behind.md`,
> `-hid-mouse-reports-share-one-buffer.md`, `-kvm-virtio-net-console-lines-take-1-4-s.md`.
> `architecture/socket-ownership-and-loopback.md` and `process-lifecycle.md` now point at `archived/`.
>
> ✅ **cyrius peer** filed in cyrius `docs/development/issues/2026-09-25-agnos-sock-peer-spawn-limits-wait-block-kill-tree-peer.md`
> (`#106`/`#107`, `SPAWN_E_LIMIT`, `WAIT_BLOCK`, `KILL_TREE`, the wait-status helpers, `#99` states, `#56` class
> bits, and every comment 1.57.7 made wrong). The 1.57.6 filing there is still open.
>
> ✅ **Written by the steps (not re-audited here):** NEW `docs/architecture/blocking-waits.md`,
> `foreground-exec.md`, `net-concurrency.md`, `socket-ownership-and-loopback.md`, `process-lifecycle.md`;
> updated `kernel-clocks.md`, `kernel-stacks-and-preemption.md` (Region 1 map), `kernel-font-namespace.md`,
> `spawn-and-fd-lifetime.md`, `overview.md`, `agnos-userland-abi.md` (rows 4/5/14/16/25/27/37/40/41/43/44/47–57/59/
> 62/66/68/96/99/100/106/107, §4.8, §4.9), `build.md`, `security-hardening.md`, `planning/blocking-syscall-concurrency.md`,
> `planning/ipc.md`, `scripts/harness/README.md`.
>
> ### 1.57.6 (2026-09-24) — three steps of a nine-step plan ship; the docs say which three
>
> ✅ **`CHANGELOG.md` 1.57.6** — Breaking (`#43` > 16 tokens refused, `−SPAWN_E_*` codes, per-process spawn
> arms, flagged-form env refusal — each with a migration note) · Added (`SPAWN_F_ARGV`/`SPAWN_F_CLEANFD`,
> `#62` `REDIR_ADD`/`REDIR_CLEAR`, `CH_ENDOW(-1)`) · Fixed (the pipe-buffer UAF and five siblings, a `-smp 4`
> triple fault, three ring-0 frame overruns) · Changed (`#95` on the PM timer; Path 2 S3.1–S3.3) · gates ·
> closeout with the measured tallies and the iron-only risk list. `version-bump.sh` minted the header.
>
> ✅ **`state.md`** — Kernel head / on-disk rows re-derived for 1.57.6; the 1.57.2–1.57.4 heads folded to one
> line each (CHANGELOG carries them); a stale "ktest has 6 real failures … unexplained" bullet (107/3 since
> 1.56.53, and a later bullet in the same file says so) replaced by the 1.57.x plan bullet; `ring3-smoke`
> 10/10; the "ZERO OPEN ISSUE FILES" bullet rewritten (ten open, four archived); aarch64 counts re-measured
> (33 fns / 17 vars at 47 sites). Held at the 120-line cap.
>
> ✅ **`roadmap.md`** — new "§ 1.57.x — the rest of the 1.57.6 plan" table: S3c/S3d/S3b/S1b/S4/S5/S6/S7/S8
> in the binding order, each naming the issue it closes, plus the USB MSC `cdb_buf` repair. Superseded rows
> removed: "Path 2 — per-process syscall kernel stacks" (now the ladder) and "SMP TX/conn-side lock
> residual" (folded into S4). Fully shipped rows removed per the file's own forward-only rule: `fork`#96,
> `lstat`#102, `statfs`#103, `waitpid` wait-any (all cyrius peers landed), the P-1 audit row (residuals
> re-homed at 1.57.2). ⛔ Two TRUE lines were FALSE: "Syscalls 0–103 … next free #104" (a mint behind: #104
> `mountlist` shipped at 1.56.59; #105 is withdrawn; #106/#107 are specced) and "Every process on a CPU enters
> syscalls on ONE shared per-CPU stack" (false from 1.57.6). The aarch64 row said "32 + 46" — re-measured.
>
> ✅ **`planning/blocking-syscall-concurrency.md`** — gains "§ Path 2 plan (1.57.x) — the design record": the
> binding contracts C1–C9 (stack map, frame, two switch paths, INV-11, states, preempt points, lock order,
> the API later steps may use), the S3/S3c/S3d/S3b ladder with what shipped in 1.57.6, and the plan's risk
> list. The full working record is cited as a design record only (the operator's `handoff-1.57.6/design/`).
> The old "Path 2 — DEFERRED" sketch is relabelled as history.
>
> ✅ **`CLAUDE.md`** — closeout tallies from this release's real run; the image-layout note's "region 7 is now
> FULL" replaced by the 1.57.6 map; a new load-bearing note for the per-process-kstack invariants; aarch64 counts.
>
> ✅ **`agnos-userland-abi.md`** — verified the S2 rows (3/25/37/43/62/97/99, §4.6, §4.8) and S1's #40/#95 are
> present; row 4's "the blocking form arrives … in a later step of the same cut" corrected (it is step S3c,
> not in 1.57.6).
>
> ✅ **Issues** — `tsc-calibration-refused-…`, `spawn-path-args-cannot-contain-spaces`,
> `spawn-path-failure-gives-no-reason`, `child-inherits-every-fd-and-spawn-arms-leak` → `archived/`, each with
> its Status header REWRITTEN (RESOLVED 1.57.6 + what shipped + the gate) and a Resolution block that says what
> the change broke (nothing observed) BEFORE the move. The other nine carry a new Status header: OPEN, the step
> that fixes it, and that the Path 2 foundation landed in 1.57.6. NEW: `2026-09-24-msc-cdb-buffer-is-two-bytes.md`
> (found by the spawn review; not fixed here because 1.57.6 does not touch `usb/msc.cyr`).
>
> ✅ **cyrius peer** filed in cyrius `docs/development/issues/2026-09-24-agnos-spawn-flags-redirect-ops-and-uptime-us-peer.md`
> (constants + four wrappers + the `#95` permanence note). No new syscall number, so the ABI gate stays green.
>
> ✅ **Written by the steps and verified here:** `docs/architecture/kernel-clocks.md` (NEW, S1),
> `spawn-and-fd-lifetime.md` (NEW, S2), `kernel-stacks-and-preemption.md` (NEW, S3 — carries the region-7
> map), `overview.md` (pointers), `build.md` (`KSTACK_SELFTEST`, `KSTACK_HW`, `SPAWN_SELFTEST`,
> `PIPE_RC_SELFTEST`, `EXEC_REDIRECT_SELFTEST`, `TSC_SELFTEST` rows), `planning/ipc.md` (#62 note).
>
> **Gates behind these docs:** `sweep.sh` **34/35 + 1 VOID** (`naad-ring3`'s surviving attempt never handed off; standalone re-run VOID, then PASS `run: exit 88`) · `check.sh` **35/35** · `test.sh` **4/4** · `ktest` **107/3** (the three environmental `[initrd]` checks, as at 1.57.5) · `agnsh-smoke` PASS · `build/agnos` 2,431,480 B, LOAD end `0x361898` (59,240 B headroom). Built, gated, NOT burned.
>
> ### 1.57.5 (2026-09-21) — a pin move that changed the binary, and the plan that said it would not
>
> ✅ **`roadmap.md`** — the 68-line "Moving the cyrius pin to 6.6.6" pre-move analysis (uncommitted at the
> start of the cut) is REPLACED by a two-row residual table: the AZ audio re-burn (the duplicate
> `GPU_AZ_IX_AUDIO_DESCRIPTOR0` is collapsed; only iron can prove the endpoint write) and the
> `FS_SYSCALL_SELFTEST` sweep gap. Everything the analysis predicted and everything it got wrong went to
> the CHANGELOG. ⚠ It was wrong TWICE in the safe-sounding direction: "a default kernel build is
> byte-identical to the 6.6.4 one" (FALSE — +736 B, 6.6.5's nested-call `rsp` pad, 372 sites) and "both
> spellings say 0x28, so the value is the same either way" (FALSE — through 6.6.4 the kernel read **0**
> from the duplicate, because the redeclaration's only store sat in the post-`arch_halt()` init replay
> that kernel mode never runs; the 6.6.6 changelog even named the agnos ordinal). A pre-move analysis
> is a hypothesis; the 2x2 build and a disassembly diff are what test it. ⛔ The first cut of THIS
> release's `gpu_regs.cyr` comment and CHANGELOG repeated the second falsehood; both were corrected
> from the binaries before ship. The file is 131 lines against its ~120 guideline; the OPEN tables are
> the bulk.
>
> ✅ **`state.md`** — Kernel head / on-disk size / Cyrius pin rows re-derived: 2,419,952 B, pin 6.6.6,
> klug 0.2.0 / kashi 1.0.10 / rekha 0.9.0, 134/134 vendored files, the size gates' `size − face` =
> 2,009,132 B. The 1.57.4 head text is folded into the "Previous head" chain. Still 120 lines.
>
> ✅ **`CHANGELOG.md` 1.57.5** — Changed (the pin move as a 2x2 with every byte accounted for; the
> duplicate global; siblings; the 6.6.6 language changes checked and found clean) + Fixed (the
> un-buildable `FS_SYSCALL_SELFTEST` gate). `version-bump.sh` minted the header.
>
> ✅ **`scripts/{build,test,bench}.sh` refs** — `KASHI_REF=1.0.10` / `REKHA_REF=0.9.0`; the build.sh
> comments carry the dates; all three refs are existing tags. ⛔ The first draft of this block and of the
> CHANGELOG said kashi's `1.0.10` tag was not cut — false: `git tag | tail` sorts lexically and put `1.0.10`
> between `1.0.1` and `1.0.2`. Use `git tag --sort=v:refname` when checking a sibling's tags.
>
> ✅ **`build.md`** — the `FS_SYSCALL_SELFTEST` row claimed "gated by `scripts/sweep.sh`"; no sweep row, smoke
> or harness sets the flag (grepped). The cell now says so and names the consequence (an un-buildable gate
> for every pin since 6.5.1).
>
> ✅ **`CLAUDE.md` closeout step 1** — tallies re-read from real runs: `check.sh` **35/35** (gate 35 =
> `pp-balance-check`, named with its reason), `sweep.sh` **31 rows** (row 31 = `fssys-smoke`), and the
> lesson that a documented gate nothing runs reads as coverage. The Quick Start comment says 35-gate.
>
> ✅ **`build.md`** — the `FS_SYSCALL_SELFTEST` row now names its runner (`fssys-smoke.sh`, six assertions)
> and keeps the history of the false "gated by sweep.sh" claim; a `DHCP_STATIC_IP` row is added for the arm
> `build.sh` could not reach until this cut.
>
> ✅ **`scripts/build.sh` / `scripts/burn/burn-prep.sh`** — `SCANOUT_MATCHGEOM` tombstoned in both (the
> define never had a `#ifdef`; the burn profile verified a marker no kernel printed), `ATOM_MATH_SELFTEST` /
> `ATOM_INSTR_SELFTEST` refuse without `HDMI_ATOM`, `DHCP_STATIC_IP` emitted. Every one measured
> byte-identical on the default build.
>
> ✅ **`issues/2026-08-11-hid-drain-rearm-and-isr-console-lock.md` → `archived/`**, status header rewritten
> OPEN → **CLOSED BY OPERATOR RULING 2026-09-21** before the move (the rule this folder learned the hard
> way), Resolution block names what shipped and what is not owed. `roadmap.md` loses the expired
> "▶ HID iron burn" heading + table AND its duplicate row (the 1.57.1 comment had flagged both) and gains
> one FALSIFIED/closed line so the item is not re-derived; `state.md` row 100 says ZERO open issue files and
> the 1,261-char "previous text" narrative that still scheduled the burn is retired; row 80 drops the
> `hid_recover_halted` clause. Two comment links (`fb_console.cyr`, `console-line-preserve-test.py`) now
> point at the archived path.
>
> ✅ **`tests/{audio,fault,fork,gpu}/cyrius.cyml`** — `[deps].stdlib` now declares the `alloc`/`atomic`/
> `fnptr` closure, so `cyrius lib sync` vendors what the build actually includes (5 files were stale after
> the first sync at this pin).
>
> ### 1.57.4 (2026-09-14) — a defect turned into history, and a peer that stopped being owed
>
> ✅ **`core/kfont.cyr` header, `architecture/kernel-font-namespace.md`, `agnos-userland-abi.md` §3.5** —
> all three described the cyrius string-literal defect as a LIVE constraint ("cyrius 6.6.3 silently
> corrupts…", "chunks at 4 KB to stay clear of it"). 6.6.4 fixed it (a 16-bit length packed into the
> literal's pool offset — the filing's parity narrative was the pool layout, not the mechanism) and it
> was re-measured here: a single 410,820-byte literal compiles byte-exact. The three now record it as
> the defect the verify CAUGHT, and say why the chunks and the verify stay. ⚠ The first re-measurement
> said "still corrupt" because the scratch manifest still pinned 6.6.3 and the 6.6.4 wrapper honoured it
> — a doc-currency lesson in its own right: measure on the compiler the manifest selects.
>
> ✅ **`agnos-userland-abi.md` §3.3** — `AO_NOFOLLOW`'s row said "the cyrius peer is still owed" since
> 1.56.53; 6.6.4's `lib/syscalls_x86_64_agnos.cyr` declares both it and `AO_EXCL`, and `lib/io.cyr` maps
> the POSIX `O_*` names onto them. Closed with the version that shipped it.
>
> ✅ **`state.md` / `CHANGELOG.md` 1.57.4 / `scripts/{build,test,bench}.sh` refs** — pin rows and the
> `KASHI_REF=1.0.8` / `REKHA_REF=0.3.9` clone fallbacks re-derived; sibling versions named.
>
> ### 1.57.3 (2026-09-13) — the AP stacks left the image, and the accommodation that described them went with them
>
> ✅ **`issues/2026-09-13-ap-stacks-inside-kernel-rodata.md` → `archived/`**, header rewritten OPEN →
> **RESOLVED 1.57.3** (operator decision 2026-09-13 — the filing's first option, taken the day it was
> asked). What moved: the AP1–3 boot/TSS stacks, from region 1 `[0x310000, 0x340000)` — inside `.rodata`
> on rekha's chunk literals since the face embed — to the last 256 KB of the region-7 kstack pool,
> reached through the **direct-map alias** (tops `DIRECTMAP_BASE + 0xFD0000 + cpu*0x10000`; slot 0
> unused, the BSP keeps `0x380000` / `0x3C0000`; **region 7 is now FULL**, `gdt.cyr`'s IST1 note carries
> the five-consumer map). The Resolution block carries the before/after table for the three sites
> (trampoline `add eax, 0xFD0000` + `mov rcx, imm64 DIRECTMAP_BASE` + `add rax, rcx` — the section is
> **92 → 105 B**, and its comment had said "77" since 1.46.x; `tss_get_cpu_stack`; `smp_start_aps`
> allocates nothing and probes BOTH aliases of the window before INIT-SIPI), why direct-map and never
> identity (ark's per-proc CR3 overrides PD[7]; an AP idle's stack outlives the boot CR3), why the BSP
> stays in region 1 (live under gnoboot's CR3 before any kernel table — or the direct map — exists;
> "the shim maps only 0–4 MB" is the LEGACY multiboot1 reason), the one image invariant left
> (**`LOAD end <= 0x370000`**, headroom `0x11750` = 71,504 B at LOAD end `0x35E8B0`), the runtime guard
> and both mutants with their evidence lines. ⛔ **Checked what the change BROKE before archiving**, per
> the folder rule: `agnsh-smoke`, `smp-smoke` (production `-smp 4`, `cpus online: 4`), `kfont-smoke`
> (exit 95) green on the plain kernel rebuilt last; `check.sh` **34 passed, 0 failed**; `fmt-check` and
> `kprint-len-check` (4169 literals) clean. ⚠ And what did NOT catch it: the 1.57.2-placement mutant
> still counted four CPUs and reached kybernet — the corruption is silent, a boot-continuity marker is
> not an oracle for this class, and the record says so. Original filing verbatim above the Resolution.
>
> ✅ **`scripts/check/image-layout-check.sh` (check.sh gate 34) is a different gate now** and its label
> moved with it: *"kernel image vs fixed kernel stacks"* → *"kernel image vs BSP boot stack (LOAD end
> <= 0x370000)"*. The chunk-decode / single-reader branch the 1.57.2 block above describes is **gone**
> (no `../rekha` needed, no `FACE` arg); the gate is one number about the IMAGE and says so — where an AP
> stack IS is `scripts/smoke/ap-stack-smoke.sh`'s job (`SMP_STACK_SELFTEST` kernel, `-smp 4`: the live RSP
> sampled in `ap_entry` in the window, TSS.RSP0 read back equal to the trampoline's top, the chunk
> literals re-hashed **in place** after the wake; sweep.sh row 30). Recorded here because every doc that
> names gate 34 by its old label — CLAUDE.md, state.md, CHANGELOG 1.57.2 — is now naming a gate that no
> longer exists under that name.
>
> ✅ **`architecture/kernel-font-namespace.md`** — Invariant 5 rewritten as the 1.57.2 → 1.57.3 arc (the
> measured 1.57.2 table kept as history; the "`0x300000–0x400000` was not empty" finding; the resolution;
> the direct-map rule; the new invariant under the relabelled gate; the three runtime oracles; both
> mutants). Invariant 2's "do not add a second reader" rule marked **retired** — the only other reader is
> `smp_stack_selftest`, `#ifdef SMP_STACK_SELFTEST` only, and it exists to prove nothing is stacked on
> the literals. The Gates table gained the `ap-stack-smoke.sh` row; the stale `0x3D0000`/`0x3F0000`
> syscall-kstack mention corrected (those left region 1 at 1.46.x/1.51.x); the opening sentence now says
> WHICH shim builds the 0–4 MB tables (the legacy one). Header re-dated; 1.57.3 figures are labelled
> where they appear, everything else is still a 1.57.2 measurement.
>
> ✅ **`agnos-userland-abi.md` §3.5** — read for overlap / reader-lock language: it carries neither (it
> was written as a path contract and never described the layout). **No edit**; recorded so the next
> sweep does not re-read it for this.
>
> ⚠ **`development/smp-arc-plan.md`** sub-bite 4/6 still quotes AP1's trampoline stack at
> `0x310000–0x320000`. It is a dated 1.46.x plan and the numbers are its history — a one-line 1.57.3
> pointer was added to that row, nothing rewritten.
>
> ⚠ **Left for the release doc sync (operator-owned; NOT touched here):** `CLAUDE.md` Closeout step 1
> (the 34th gate's label) and the Architecture-Notes bullet that still states the 1.57.2 layout, the
> `0x310000` bound, the byte-for-byte tolerance and the retired single-reader rule in the present tense
> — the 1.57.3 text to paste is `gdt.cyr`'s `tss_kernel_stack` note / the arch note's Invariant 5;
> `state.md` rows 15/17/100 (LOAD end `0x35E770` "tolerated by gate 34" → `0x35E8B0` under the BSP-only
> invariant; `build/agnos` 2,418,896 → **2,419,216 B**; `sweep.sh` 29 → **30** rows; **ONE** open issue
> file, `hid-drain-rearm`, not two); `roadmap.md`; `CHANGELOG.md`'s 1.57.3 entry (`version-bump.sh` mints
> it — the 1.57.2 entry's "tolerated, not fixed" paragraph stays as the history it is). ⛔ These are the
> cheap fields, and the top of this file records three times that the cheap fields are the ones that rot.
>
> ✅ **`CLAUDE.md`** — the Architecture Notes bullet that stated the 1.57.2 layout as a load-bearing
> invariant ("must end below `0x310000`") rewritten to the 1.57.3 truth (`<= 0x370000`, the BSP boot
> stack; AP stacks in region 7 via the direct map; region 7 full); the closeout's 34th-gate label
> re-read from `check.sh`.
>
> ✅ **`state.md`** — Kernel head / on-disk size / open-issue-count rows re-derived for 1.57.3 (ONE open
> file); the 1.57.2 head text kept inline, marked as previous.
>
> ✅ **`roadmap.md`** — the rekha arc finally has a row (it shipped at 1.57.2 without one): what shipped,
> the layout debt and its 1.57.3 payment, and the four follow-ups still open under it (subset face +
> OFL rename, write-protected `.rodata`, the BSP boot stack as a number, the KEEP_GNOBOOT_CR3 build).
>
> ✅ **`CHANGELOG.md` 1.57.3** — one Fixed section; the trampoline byte count is the TRUE one (92 → 105;
> the source comment had said 77 since 1.46.x), both mutation runs are quoted, and the review finding
> against this cut's own first draft (the wake guard probing the identity PD) is on the record.
>
> ### 1.57.2 (2026-09-13) — the embedded face, and a filing that was answered by a shape it did not anticipate
>
> ✅ **NEW: `architecture/kernel-font-namespace.md`** — the invariants behind `/fonts` that reading
> `core/kfont.cyr` alone will not give you: **verify-before-expose is load-bearing** (cyrius 6.6.3
> silently shifts even-length string literals ≥ 64 KB by one byte — filed in cyrius as
> `issues/2026-09-13-agnos-large-string-literal-loses-first-byte.md`; the FNV-1a-64 of the assembled
> face is what found it), the 4 KB chunking and the read-ONCE rule, the 2 MB region reached through
> the **direct-map alias and only after `cr3_load(0x1000)`** (the design's "beside `fb_shadow_init`"
> slot was MEASURED failing: literals hashed clean in place, buffer read back all zeros under gnoboot's
> CR3), why it is a **prefix intercept and not a mount** (`mlist.cyr:33` refuses backend ids > 3;
> crab's sidebar draws a capacity bar per row), the kashi-style fold-in through `build.sh`/`test.sh`/
> `bench.sh` with `REKHA_REF=0.3.8`, and the fit check that was **wrong**: `LOAD` end `0x35E770` is under
> the 4 MB identity map, but the AP1–3 stacks at `0x310000–0x340000` now sit inside `.rodata` on rekha
> chunks ~52..100 (275 B margin; locked by check.sh gate 34, relocation filed as
> `issues/2026-09-13-ap-stacks-inside-kernel-rodata.md`). ⚠ Every number in it is a 1.57.2 measurement
> and says so; re-measure before copying forward.
>
> ✅ **`agnos-userland-abi.md` §3.5 (new)** — the `/fonts` path contract, placed with the `open`#7
> flags rather than as a syscall row because **no number was minted**: two exact-byte names, the
> `0xB03` refusal mask bit by bit, `read`#5 to EOF = 410,820 then 0 (never -2), **`write`#1 and
> `lseek`#58 are -1** on the memfile fd (one pass, no rewind — a fact a client would otherwise learn
> from a -1), `stat`/`lstat` field values, `statfs`#103 NOT intercepted, `mountlist`#104 absence and
> why, the shadowing caveat stated as contract, the four boot lines and what each closes, provenance
> (Liberation Sans Regular **2.1.5**, unmodified, SIL OFL 1.1, sha256 + FNV recorded, the licence file
> that must travel), the client fallback (bitmap face on -1 — with the warning that the same guard is
> what makes a missing face quiet, so measure on QEMU), and the gate (`kfont-smoke.sh`, exit 95).
> §3.1's `open` bullet gained a one-line pointer.
>
> ✅ **`issues/2026-09-13-no-proportional-face-on-the-target.md` → `archived/`**, header rewritten
> OPEN → **RESOLVED 1.57.2** with what shipped, the two names, what crab needs to do (nothing but the
> load, as it predicted), and the dhancha per-call allocation blocker that is **not ours and remains
> open** — recorded so "face shipped" is not read as "item unblocked". ⛔ **Checked what the change
> BROKE before archiving**, per the folder rule: `mountlist`#104 unchanged (`vfs.cyr`, `mlist.cyr`
> byte-unchanged, `be > 3` rule still passes); the two 2 MiB size gates went red and were re-derived
> (face weighed out), not raised; the AP-stack layout hazard filed; aarch64 no worse (33/46 both
> sides); CI cannot clone rekha 0.3.8 until the tag is cut. Filed and resolved the same day — the
> operator's ruling was on the filing itself.
> ⚠ `core/kfont.cyr`'s header comment named the pre-archive path; repointed (comment only, cyim,
> `fmt-check` clean) so the source does not send the next reader to a file that moved.
>
> ✅ **`issues/2026-08-28-p1-audit-sweep-backlog.md` → `archived/`** — CLOSED with a 1.57.2 STATUS block
> (P0 2/2 · P2 29/29 · P1 23/26 + 1 partial-by-ruling + 2 aarch64-gated). ⛔ **Three of its own carried
> notes were stale in the "worse than it is" direction** and are corrected in place: "31 unguarded walk
> sites" (17 real + 14 exFAT walks guarded since 1.34.x), "stale RWX binaries" (rootfs 0/48 — the RWX
> images were two hand-built selftest ELFs), and "`ring3-smoke` has 4 real failures" (8/8 since the
> 1.56.55 dwell fix). A carried note rots exactly like a status header. The four residuals are re-homed
> to named `roadmap.md` rows (aarch64 pair; raw-disk `BLK_RW_ARM_MAGIC` gate → *Native
> sandbox-confinement primitives*; `#92` op 0x0C SMP → *`#92` ABI table*) and `ext2-smoke`'s non-booting
> recipe got its own row, so nothing lives only in the archive.
>
> ✅ **`roadmap.md`** — the audit row rewritten as shipped; the three rows above gained their residuals;
> the Built-with trailer re-synced to 6.6.3 by `version-bump.sh`.
>
> ✅ **`state.md`** — Kernel head / Previous cut / on-disk size / Cyrius pin rows re-derived (the pin row
> now carries the `lib sync` declares-only trap; the size row carries the `size − face` weighing);
> the aarch64 count corrected **32 → 33** (every doc had copied 32 since 1.56.59); the ring3-smoke
> "4 real failures" and "FIVE OPEN ISSUE FILES" bullets corrected (9/9; TWO open files).
>
> ✅ **`CLAUDE.md`** — Quick Start and Closeout tallies re-read from real runs: `check.sh` **34** gates
> (the 34th is `kernel image vs fixed kernel stacks`), aarch64 **33**/46.
>
> ✅ **`CHANGELOG.md` 1.57.2** — three sections (Added: the face; Fixed: the backlog closed; Changed:
> the 6.6.3 pin + the stale vendored libs); every size, count and exit code is a measurement from this
> cut and the two workflow runs that produced it.
>
> ⚠ **Left for the release doc sync (the operator's, per the kernel-half report):** `CHANGELOG.md`,
> `state.md` (kernel size 1,999,616 → 2,418,896 B; check.sh is **34** gates), `roadmap.md`, and
> CLAUDE.md's "33/33" tallies — now stale by one gate.
>
> ### 1.57.1 (2026-09-08) — the backlog closeout, and four documents that were describing it wrongly
>
> ✅ **`issues/` — SIX FILES TO TWO.** Archived with rewritten RESOLVED headers: the chakshu AP-idle
> filing, `agnoshi-power-builtins` (fixed **in agnoshi**, shipped as 1.9.11 — cross-repo means
> switching repos, which is what was done), `harness-exercisers-never-rebuilt` (**30/30** guards, was
> 1/30), and `vacuous-gates-sweep` (**18/18** host GPU oracles floored, every floor mutation-falsified).
> ⛔ **None was archived on its own header text** — each was re-verified item by item first, which is
> the failure mode CLAUDE.md names.
>
> ✅ **`state.md`** — the kernel-head row said "1.57.1 — OPEN" and described the **6.6.0** pin move
> while the tree was on **6.6.1** and the cut was released. Both corrected, plus the burn result.
> ⚠ The `Cyrius pin` row still read 6.6.0 as well; a pin row that lags the manifests is exactly the
> drift `toolchain-pin-check` exists to catch, and no gate covers the *prose*.
>
> ✅ **`agnos-userland-abi.md` §4.4** — told consumers a length-taking `sysinfo` overload was pending
> upstream. It shipped in **cyrius 6.5.45**; as written it sent the next consumer to hand-roll a raw
> syscall and compute band offsets by hand. Row 79 (`blk_info`) was also filled in — it was **empty**
> while being the row §4.4 tells a consumer to multiply by.
>
> ✅ **`roadmap.md`** carried a `▶ 1.56.58 — item #1` heading four cuts in the past, plus a duplicate
> row with line refs rotted by ~60 lines. **`doc-health.md`** (this file) repeated a stale "UNGATED"
> claim about HID whose oracle had shipped at 1.56.59.
>
> ⛔ **SAFETY-CRITICAL ISSUE CORRECTION.** The agnoshi filing claimed `is_privileged_command` was dead
> code and implied deleting it. **That symbol never existed** — the real classifier is
> `is_admin_command` and it is fully live. Acting on the issue's authority would have downgraded
> `reboot`/`poweroff`/`halt` from ADMIN. Corrected in place. ⚠ An issue file is not evidence; verify
> its symbols against the tree before acting on one.
>
> ⚠ **`host-gpu-oracles.sh` claimed 17 missing floors were "filed as one". Nothing filed them.** A
> comment asserting something is tracked, when nothing tracks it, is worse than silence — it stops the
> next reader from filing it.
>
> ### 1.56.60 (2026-09-03) — the shutdown review, and two docs that described a design nobody built

>
> ✅ **`agnos-userland-abi.md`** row 13 — rewritten. It documented the **pre-1.55.25 stub**
> (`| 13 | reboot | — | — | — | (halts) | serial_println + arch_halt |`) **five minors** after the
> kernel became `power_sys(magic1, magic2, cmd, arg)`. Now carries the magic pair, the cmd values
> (1 halt / 2 power off / 3 reboot), the a4 slot, and the -1 return.
> ⛔ **THIS CLASS OF DRIFT IS STRUCTURALLY INVISIBLE TO `check.sh`.** By its own header,
> `scripts/check/syscall-abi-check.sh` checks (A) number sets, (B) doc==cyrius names, (C) kernel
> dispatch-comment names. **Argument and semantics columns are out of scope by design** — so
> `state.md`'s "syscall ABI GREEN: kernel 105 · abi-doc 105 · cyrius 105" is a *count* passing over
> wrong *content*, and no amount of green there covers this. `roadmap.md:32` had already filed the
> identical sentence as FALSIFIED/STALE and fixed only the roadmap. **Open question: nothing gates
> the argument columns of 105 rows.**
>
> ✅ **`architecture/overview.md`** — the recovery-REPL verb list. This file has said since **1.41.9**
> that the in-kernel shell "owns just enough (`…`/`sync`/`reboot` + non-write diagnostics)". ⛔ **It
> never owned `reboot`.** This was not a doc error inventing a verb: agnosticos
> `docs/development/shell-separation-prior-art.md:95-96` assigns `reboot` to the emergency shell in
> the recorded boundary decision, and :90 assigns `halt` to agnsh — **the shipped tree was the exact
> inverse in both directions**. The doc described a design that was written down and never built, so
> the fix was to the CODE (1.56.60), after which the sentence became true. Now also lists `klug`,
> `poweroff` and `halt`.
> ⚠ Note this is the SECOND named instance of "the doc is right, the code is wrong" in this repo.
> Do not reflexively treat an unmatched doc claim as stale prose — check the boundary record first.
>
> ✅ **`issues/archived/2026-07-19-sys-reboot-nullary-vs-agnos-4arg-abi.md`** — header rewritten
> **OPEN → RESOLVED** with the landing version (**cyrius 6.4.68**) and the still-open agnoshi
> follow-up. It had sat in `archived/` carrying an OPEN header, which is precisely the failure mode
> CLAUDE.md names (`#98` read "DESIGNED, UNBUILT" eleven cuts after shipping). ⚠ Verified against the
> **cyrius repo itself**, not agnoshi's vendored `lib/` — a sibling's vendored copy proves what is
> *installed*, not what cyrius *shipped*.
>
> ✅ **NEW: `issues/2026-09-03-agnoshi-power-builtins-history-audit-archguard.md`** — the agnoshi half
> of the review, filed rather than fixed (cross-repo work means switching repos). Records what is
> **not** wrong first: agnsh's `reboot`/`poweroff` are iron-validated and its `halt` semantics are a
> recorded decision.
>
> ⛔ **GATE-COVERAGE FINDING, recorded here because it is a doc-currency fact too:**
> `scripts/smoke/shutdown-smoke.sh` had **never been run by anything** — absent from `check.sh`,
> `sweep.sh` and CI, with its only tree-wide mention inside a docs issue. It is now a `sweep.sh` gate,
> but only after being given a stop oracle: its halt arm asserted `power: filesystems flushed` and
> `power: storage quiesced`, **both emitted by the broken path**, so it scored PASS on the very defect
> this cut fixes.
>
> ### 1.56.58 (2026-09-02) — the log line becomes contract, and a doc that was wrong in three places
>
> ✅ **`agnos-userland-abi.md`** §4.5 — corrected and extended. ⛔ It said the klug ring was **16 KB**
> in three separate places; it is **64 KB** and has been since the ring was raised, so the written
> contract disagreed with both the kernel (`var klug_buf[8192]`, module scope = N×u64) and the
> userland reader (`KLUG_RING_BYTES = 65536`, pinned in klug's own tests). It also described the
> `[I]`/`[W]`/`[E]` lens as live when **no production build emits a single leveled line**. Now carries
> the 1.56.58 line format, the ring-3 exemption, and the BRE/ERE anchors a consumer must use.
> ⚠ **The log LINE FORMAT is now de-facto ABI with no freeze status.** The doc's legend (:16-27) marks
> syscall ROWS 🔒 FROZEN / ✅ DECIDED but says nothing about line shape — and 110 assertions across 34
> smoke scripts now depend on it. Deciding that status is open work.
>
> ✅ **`state.md`** — kernel-head row rewritten for the cut; `build/agnos` row now says plainly that the
> file is an ordinary dev build and that `burn-verify` says **DO NOT FLASH** (the tag is 1.56.53, and
> was already stale before this cut). Bootloader row corrected **0.6.1 → 0.7.1** (the sibling had moved
> and the row had not). Two `Previous cut` rows consolidated into one to stay under the 120-line cap.
>
> ✅ **`issues/2026-09-02-vacuous-gates-sweep.md`** — filed at 1.56.57 UNFIXED, swept at 1.56.58.
> Status header rewritten in place **before** any move, per the folder's own rule; it **stays OPEN**
> because one finding was declined, two fixes moved the vacuity up a level rather than removing it,
> and `.github/workflows/`, `scripts/burn/` and `tests/*/` were never swept.
>
> ⚠ **Still unswept since 1.44.9**, unchanged by this cut and called out again because the note above
> predicted exactly this: `README.md`, `architecture/overview.md`, `syscall-additions.md`, `build.md`,
> `kybernet-bridge.md`. `architecture/overview.md` additionally still says "Built with cyrius 6.0.56".
>
> ### 1.56.56 (2026-08-31) — two syscalls shipped, a ruling found, and the issues folder 7 → 2
>
> ✅ **`agnos-userland-abi.md`** — two new rows and both are load-bearing, not inventory. `| 103 | statfs |`
> (§4.7 record, ext2-only, record size frozen ABI because the call is 3-arg with no length parameter)
> and `AO_EXCL = 0x2000` in §3.3, whose row states the thing the code comment states: the check is
> evaluated BEFORE `AO_TRUNC`, or it destroys what it refuses.
>
> ✅ **`issues/`** — `open-ao-excl-flag` and `no-statfs-for-volume-capacity` both SHIPPED and archived
> with resolution headers carrying their measured numbers and their mutation results.
> ⚠ **1.57.1 CORRECTION — this block's "UNGATED" reading is wrong and was repeated downstream.** The halting-path oracle shipped at 1.56.59 (`HID_CC_INJECT_HALT=1` + `scripts/harness/hid-halt-oracle-test.py`, mutation-proven). What HID `#3` still lacks is an IRON BURN with a provoked stall, which is a hardware procedure. 13 items in that issue remain genuinely open — see its rewritten header.
> ✅ **`issues/2026-08-11-hid-drain-rearm`** — both defects fixed; header records that the fix ships
> **UNGATED** and why the cheap gate was refused. That is the honest state, not a hedge.
>
> ✅ **`roadmap.md`** — syscall line 0–103 / next free #104; FAT+exFAT `statfs` slotted **1.56.57** with
> its real cost named (two fresh sets of controls, and exFAT`s free count lives in the allocation
> bitmap rather than a superblock field).
>
> ### 1.56.56 (2026-08-31) — a correction, and the issues folder actually shrinking
>
> ⛔ **`CHANGELOG.md` 1.56.55 carried a wrong claim and it is corrected, not rewritten.** That entry
> said `ring3-smoke.sh` had "two red assertions"; it had none. Its 40 s `qemu_dwell` truncated the
> selftest before its last three markers printed, which made `gate held` look deterministic (it never
> printed) and `yield OK` look flaky (it printed only when a boot got far enough) — on HEAD too, so the
> control agreed for the wrong reason. The tagged text is left byte-identical with a `⚠ CORRECTED AT
> 1.56.56` pointer above it; the correction itself lives in the 1.56.56 section.
>
> ✅ **`docs/development/issues/` — 7 open → 3 in this pass** (→ 2 once `AO_EXCL` and `statfs` shipped, see the 1.56.56 block above). `syscall-96-fork`, `open-ao-nofollow`,
> `tri-corner-bound` and `shakti-privilege-model-kernel-gap` archived, each with its Status header
> rewritten to a resolution note first. The first three were being held open for **cyrius** peers,
> which is another repo`s backlog counted in this one. ⛔⛔ **The fourth was asking for a ruling that had
> existed since 2026-05-12** — agnosticos `planning/identity-and-authorization-model.md`, which rejects
> "Account/uid as multi-user primitive" and "Sudo-and-retype-password for privilege" by name. The audit
> missed it by grepping **agnos** for a **cross-repo architectural** question. ⇒ **agnos is not where
> AGNOS architecture is ruled; agnosticos is. Search the genesis repo before recording "no decision".**
> ⛔ **Two findings had been written up as new issue files and should not have been** — the `#92`
> ABI-table gap is fully characterised known work (now a `roadmap.md` OPEN row) and the `ring3-smoke`
> one described defects that do not exist. Both removed. ⇒ **A finding is not automatically a file.**
>
> ✅ **`roadmap.md`** — `#92` ABI-table row added. ✅ **`state.md`** — open-issue rollup and the measured
> gate tallies (`sweep.sh` 25/1 over 26 gates, `check.sh` 31/1). ✅ **`scripts/`** — `ring3-smoke.sh`
> dwell 40 s → 120 s and wired into `sweep.sh`, so `proc_alloc_slot`, the ring-3 preempt gate and
> `sched_yield`#44 are covered by the command that gets run.
>
> ### 1.56.55 (2026-08-31) — the open-issue folder re-audited, and four gates that could not fail
>
> ✅ **`docs/development/issues/` — all 7 open files re-verified against the live tree; THREE ARCHIVED
> (`syscall-96-fork`, `open-ao-nofollow`, `tri-corner-bound`), leaving 4.** Each got its Status header
> rewritten to a resolution note before the move, per the archiving rule. ⛔ **Two findings were briefly
> written up as new issue files and should not have been**: the `#92` ABI-table gap is fully
> characterised known work and belongs in `roadmap.md`s OPEN table (an issues file is for something to
> investigate), and the `ring3-smoke` one described two defects that turned out not to exist. Both
> removed. ⇒ **A finding is not automatically a file.** Fix it, or put it where the work is tracked. Two records that read as finished were not: `fork`#96 was hiding two multi-child defects,
> and the `#92` corner-bound fix has no mutation coverage on **op 0x09**, the burned op the operator
> ruling was actually about. Headers rewritten on `syscall-96-fork` (now 🟠, open on the cyrius peer),
> `open-ao-nofollow` (now tracks its three unswept residuals; `AO_EXCL` handed to its own file),
> `hid-drain-rearm` (two live defects found inside the 1.56.52 rewrite), `open-ao-excl` (the proposed
> flag bit was `AO_APPEND`), and `p1-audit-sweep-backlog` (three disagreeing tallies reconciled to 23/26).
>
> ✅ **`CHANGELOG.md`** — 1.56.55 extended: the two fork defects, the four false-green gates, and the
> three ABI-doc rows that were behind the kernel.
>
> ✅ **`agnos-userland-abi.md`** — `| 96 | fork |` added (a shipped, sweep-gated syscall with no row);
> `#4 waitpid` rewritten (it documented a blocking busy-wait and a two-valued return; it is a
> non-blocking three-valued poll with wait-any); `AO_NOFOLLOW = 0x1000` added to §3.3 two cuts late;
> `AO_APPEND` now carries the bit-collision hazard that nearly cost every append-open on agnos.
>
> ✅ **`roadmap.md`** — `fork` and `waitpid` wait-any moved to shipped; the "next free number is #101"
> line corrected to #103, two mints after it stopped being true; the audit-backlog row re-tallied.
>
> ✅ **`state.md`** — the open-issue rollup was written for six issues and a different set of blockers.
>
> ⚠ **This file itself was wrong about the archive directory.** Six references read `issues/archive/`;
> the directory is `issues/archived/`. Fixed — the same error CLAUDE.md carried until 1.56.54.
> ⛔ **Still stale and NOT swept here** (unchanged since v1.44.9, ~12 minors): `README.md`,
> `architecture/overview.md`, `syscall-additions.md`, `build.md`, `kybernet-bridge.md`. Their syscall
> counts, sizes and subsystem tables should be assumed wrong; the surface is now **0-102**.
>
> ### 1.56.52 (2026-08-29) — both audit P0s closed, plus a finding that was in no backlog
>
> ✅ **`CHANGELOG.md`** — full 1.56.52 arc: the TSS I/O-map escalation, the `sys_munmap` P0, the `#92`
> TOCTOU, the ELF loader leaks, the `kfmt` interlocked pair, the init-stack widening, the device-trust
> batch (virtio ×2, ramdisk, xHCI interval, ACPI S5), and the W+X mapper removal.
> ✅ **`issues/2026-08-28-p1-audit-sweep-backlog.md`** — a 1.56.52 STATUS block recording that a second
> pass RE-GRADED the P2 list and found a P0 in it, that `gdt.cyr:82` was in no backlog at all, and that
> two of the audit's own suggested fixes were wrong (the `blk` reorder is an ABI break; the init-stack
> guard is off by one). Inline ✅ markers extended.
> ✅ **`docs/development/state.md`** — kernel-head row rewritten, gate count (31/31 at that point; 32/32 after the second pass), and the OPEN section
> CONSOLIDATED rather than grown (it had crossed the 120-line cap at 125; now exactly 120). New entries:
> the severity labels are unreliable in both directions; three 1.56.52 fixes are asserted-not-exercised;
> op 0x0C is still not SMP-safe; kernel structures are direct-map addressed now.
> ✅ **`docs/development/roadmap.md`** — backlog row re-counted, both P0s marked closed.
> ✅ **NEW `scripts/check/check-initstack.sh`** — the init-stack extent gate; `check.sh` was 31 gates at this point (32 after the second pass added `check-ci-release-gate.sh`).
>
> **Second pass, same day — the P1 tail, and a P0 found underneath one of them:**
> ✅ **`CHANGELOG.md`** — four further sections: receive-checksum verification at every layer (nothing
> verified one before, at any layer); the stolen-HID-event reclaim plus the keyboard-row decoy it
> exposed; the user-pointer window P0 and the high-arena P1 it was blocking; and the `run_gate` display
> filter that made a failing gate print nothing.
> ✅ **`issues/2026-08-28-p1-audit-sweep-backlog.md`** — three items marked ✅ FIXED 1.56.52 with
> RESOLUTION blocks. ⛔ The `proc.cyr:1781` block records that the item **could not be fixed as filed** —
> its suggested fix would itself have been a ring-3 kernel-write primitive. P1 is now 21 of 26.
> ✅ **`docs/development/state.md`** — five new OPEN entries: "is this a user pointer" is a page-table
> question, not an address-range one; a validator gate must run under a real per-process CR3; a derived
> constant with no observable effect on the test box cannot be gated by behaviour; a sweep gate can fail
> and print nothing; the sweep's boot flake moves between gates. Kernel-head row rewritten.
> ✅ **`docs/development/roadmap.md`** — backlog row re-counted to P1 5/26 remaining, and the HID
> halted-endpoint row updated: the sequence it asks a real stall to validate is **no longer the one
> that was reviewed there**, because `hid_recover_halted` was reading decoy producer state.
> ✅ **NEW smokes** — `net-csum-smoke.sh` (the first gate anywhere in the tree that presents a *corrupt*
> frame), `hid-reclaim-smoke.sh` (hermetic; brings its own event ring, transfer ring and doorbell page),
> `userwin-smoke.sh` (runs under a real per-process CR3 — under the boot CR3 every arm scores a
> meaningless pass). All three mutation-tested; `sweep.sh` is now 23 gates.
>
> ### 1.56.52 (2026-08-30) — the P2 tail, closed
>
> ✅ **`CHANGELOG.md`** — two further sections: "three P2 items that were not P2" (the DHCP option
> read past a ring-0 stack buffer, IPv4 fragments reaching the TCP header path, and a release CI gate
> that has never booted a kernel) and "the rest of the P2 tail (12 items)".
> ✅ **`issues/2026-08-28-p1-audit-sweep-backlog.md`** — the **P2 section is CLOSED at 29 of 29**, every
> item now carrying an inline ✅. ⛔ Its header had said `0 FIXED` while 14 were already done, because
> that section — unlike P0/P1 — carried only a total and no per-item markers. Re-derived by reading
> each site, with every already-fixed claim adversarially refuted before being recorded.
> ✅ **`docs/development/state.md`** — the backlog entry rewritten (P0 2/2, P1 21/26, P2 29/29) and a
> new entry: a status count and an item list that *can* disagree eventually *will* — mark items, not
> totals. ⭐ The `fp-nm-smoke` "~50% coin flip" entry was **corrected, not extended**: it was never an
> FP defect, and the note had been telling future sessions not to bisect against a working gate.
> ✅ **`docs/development/roadmap.md`** — backlog row re-titled to name what remains (5 P1s, two of them
> aarch64-gated) rather than what was done.
> ✅ **NEW gate** `scripts/check/check-ci-release-gate.sh` (check.sh 31 → 32) — the release-CI property
> cannot be tested from a developer machine, so a static re-read is the only form that can fail.
> ✅ **NEW smoke** `scripts/smoke/dhcp-opt-smoke.sh`; `net-csum-smoke.sh` extended with three fragment
> arms. `sweep.sh` is now 24 gates, and **all 7 previously unguarded gates were converted to
> `qemu_dwell_kernel`**, which is what turned the sweep from intermittently-red to green.
>
> ✅ **NEW `issues/2026-08-30-tri-corner-bound-coordinate-frame.md`** — `#92` ops 0x09/0x0A validate the
> frame-skew bound in SCREEN coordinates while the shader samples RECT-LOCAL ones. Filed rather than
> fixed: op 0x09 is shipped and BURNED, so changing what its validator accepts wants an operator
> ruling. Measured that it rejects nothing realistic, and that measurement is a permanent battery case.
> ✅ **`CHANGELOG.md`** — a further section recording that an adversarial review of this cut's own P2
> batch found **15 real defects, all of them in the FIXES rather than the findings**, and what shapes
> they took.
>
> ### 1.56.53 (2026-08-30) — cycle OPEN, staged for the iron validation burn
>
> ✅ **`CHANGELOG.md`** — 1.56.53 opened: the scanout-refusal diagnostic, the `burn-prep` staleness gate
> that covered 4 of the 18 tools it iterates, the `#92` battery count that drifted between its two
> assertion sites, and the corrected iron baseline.
> ✅ **`docs/development/state.md`** — TWO corrections, both of which would have mis-aimed a bisect:
> the **Last artifact on iron** row said 1.56.44 when the iron log records **1.56.46 flashed
> 2026-08-19** (the rollup drifted because b4–b9 were tool-side only and said "kernel unchanged"), and
> the **`build/agnos` on disk** row now carries the stamped burn artifact plus a do-not-rebuild warning.
> ✅ **NEW `agnosticos/.../iron-nuc-zen-log.md` `#tracker-iron-v1`** — the burn card: staged versions,
> the dispositive 60-second test, the kernel→kybernet→agnoshi marker chain, and six falsification
> branches ordered by likelihood, one of which (the IPv4 fragment reject) is flagged as an **intended**
> behaviour change that will look like a regression.
> ⚠ **`kybernet-bridge.md` is STALE and was not swept**: it states the kernel syscall surface as 0-33;
> it is 0-101. Left alone deliberately — this cut did not touch the bridge, and rewriting a design doc
> unprompted while a burn is staged is the wrong order.
>
> ### 1.56.53 second pass (2026-08-30) — the iron burn's own findings
>
> ✅ **`CHANGELOG.md`** — the burn result (all three subjects verified, real network held), `lstat`#102
> + `AO_NOFOLLOW`, the `#99` recycle-scrub leak whose fix was dead code, the `munmap` cursor rollback,
> and two ktest gates that could not pass.
> ✅ **NEW `cyrius/docs/development/issues/2026-08-30-agnos-sys-lstat-102-peer.md`** — ⛔ filed in the
> **cyrius** repo, per the operator ruling that cyrius is never-touch and a cross-repo ask belongs in
> that repo's own issues folder. An agnos-side duplicate was written first and **deleted**; the
> roadmap, CHANGELOG and ABI row now point at the cyrius path.
> ✅ **`docs/development/agnos-userland-abi.md`** — row 102, and the two-sided note now says the gate
> stays red by design until the peer lands.
> ✅ **`docs/development/state.md`** — iron row rewritten to the burn result; the ktest line corrected
> from "97/6, six pre-existing" to **107/3** with *why* the two closed ones were never mysteries; and
> three new entries: cyrius is never-touch, "pre-existing/unexplained" is not a diagnosis, and an iron
> burn is a defect source to be read in full.
> ✅ **`issues/2026-08-27-open-ao-nofollow-flag.md`** — marked FIXED; `AO_EXCL` explicitly still open.
> ⚠ **17 issue files triaged with adversarial verification and NONE came back cleanly archivable** —
> every shipped-syscall record carries a stale contract clause or an unswept caller. That is a finding
> about the folder, not a queue of defects, and it wants its own pass.
>
> ### 1.56.54 (2026-08-30) — the issues folder swept end to end
>
> ✅ **`docs/development/issues/`** — **17 open → 6.** Eleven resolved records got their Status headers
> rewritten with resolution notes and moved to `archived/` (44 files there now). The six that remain
> each state what they are actually waiting on; four of the six are waiting on a **ruling, hardware, or
> a slotting decision**, not on code.
> ✅ **`docs/development/agnos-userland-abi.md`** — four rows corrected to the post-*bites 10/11* kernel:
> `read`#5 (`-2` WOULD_BLOCK), `write`#1 (short write, caller retries), `pipe`#25 (streaming, 4080-byte
> ring, mandatory close), and `exec_redirect`#62, whose two bolded clauses had been **false since
> 1.56.39**.
> ✅ **`CHANGELOG.md`** — 1.56.54: the `BOTE_SELFTEST` boot hang, the four ABI rows, and the sweep table.
> ✅ **`CLAUDE.md`** — the issues pointer said `archive/`; the directory is `archived/`. Corrected, plus
> the two rules this sweep paid for.
> ✅ **`docs/development/state.md`** — two new entries: a stale Status header is this folder's failure
> mode, and *check what a shipped change broke before archiving it* — which caught a boot hang.
>
> ⚠ **Still unswept since 1.44.9**: `README.md`, `architecture/overview.md`, `syscall-additions.md`,
> `build.md`, `kybernet-bridge.md`. Unchanged by this cut and still to be assumed stale.
> 🟠 **Body docs still unswept** — unchanged since 1.44.9; the debt below stands.
>
> ### 2026-08-29 — the audit-backlog first pass (inside the 1.56.51 cut)
>
> ✅ **`CHANGELOG.md`** — four new sections under 1.56.51: the P0 identity-shadowing closure, the P1 batch, the two harness gates that could not fail, and the kmalloc consequence. The "Known — not fixed" bullets were reconciled rather than left to rot (the `blk` gate and `#92` entries now say what actually changed).
> ✅ **`docs/development/issues/2026-08-28-p1-audit-sweep-backlog.md`** — a STATUS block at the top and inline ✅ FIXED / 🟠 PARTIAL markers on 19 entries, so the file reports what remains instead of what was once true. Section headings carry running counts.
> ✅ **`docs/development/state.md`** — kernel-head row, gate counts (now including `ktest.sh` 97/6), and four new OPEN items: the identity-VA belief is now false for kernel structures; the IBRS relocation is emit-order-verified only; two smokes do not build their own kernel; do not run `check.sh` during a sweep. Held at 106 lines, under the 120 cap.
> ✅ **`docs/development/roadmap.md`** — the audit-backlog row now carries real counts and records that the `elf.cyr:312` operator ruling was given and executed.
> 🟠 **Body docs still unswept** — unchanged since 1.44.9; the debt below stands.
>
> ### 1.56.51 — what that cut touched
>
> ✅ **`docs/development/state.md`** — the TRUE table was **five patch releases stale** (kernel head 1.56.45, pin 6.5.21, `check.sh` 23/23) because all three of `version-bump.sh`'s state.md seds matched nothing and the script reported the file "Updated" anyway. Patterns fixed against the file's real shape AND asserted; arc narrative compressed back under the 120-line cap (100 lines).
> ✅ **`docs/development/roadmap.md`** — audit-backlog + aarch64 rows added; ⛔ a **literal `\n` inside a table row** was merging the IPv6 and `fork` entries, so the `fork` row had never rendered. Repaired.
> ✅ **`CHANGELOG.md`** — full 1.56.51 arc. ⛔ `version-bump.sh` had never actually opened a release section (it anchored on a `## [Unreleased]` heading this file does not have); fixed and asserted.
> ✅ **`CLAUDE.md`** — the documented boot command (`qemu -kernel build/agnos`) **does not work** and had not since the ELF64/multiboot2 move; gate counts corrected (`check.sh` is 30 gates, not 11; `test.sh --all` tops out at 5, not 7).
> ✅ **NEW `docs/development/issues/2026-08-28-p1-audit-sweep-backlog.md`** — the 2 P0 / 26 P1 / 29 P2 findings that survived adversarial verification and did NOT land.
> 🟠 **Body docs — untouched, and now the largest doc debt in the repo.** A real catch-up sweep is owed.
>
> *Earlier:* 2026-06-10 (**1.42.x→1.44.x catch-up sweep**, at the v1.44.9 cut). **The multi-minor lag happened AGAIN** — the ledger sat at v1.41.11 across the ENTIRE **1.42.x** (perf + hardening + the `uname`/`sysinfo`/`klog` syscalls), **1.43.x** (graphics path: `fbinfo`/`blit`/`uptime_ms`/`sleep_ms`/`kbscan` + `execwait`, culminating in **DOOM** as the first real userland app, iron-complete burn `1439`), and **1.44.x** (multi-threading / **preemptive ring-3 scheduling**) arcs — three feature arcs, ~30 cuts — with state.md/roadmap/CHANGELOG kept current per-cut but the body docs un-swept. This sweep (a 4-agent parallel doc-update workflow + manual README/roadmap follow-up) brought the body docs current through **v1.44.9**, chiefly the **syscall surface 0-33 (34) → 0-42 (43)** (the 1.42.x group 34-36 + the 1.43.x group 37-42; `waitpid`#4 → non-blocking poll at 1.44.9) and the **cooperative → preemptive ring-3** process-model shift, across **README.md** (Status headline + Syscalls table/count + project map + `waitpid`/`sync` rows), **architecture/overview.md** (count + process-model rewrite + new syscall groups + size 1,123,864 B), **syscall-additions.md** (per-slot rows 34-42), **build.md** (the `THREAD_SELFTEST`/`RING3_SELFTEST`/`DOOM_SELFTEST`/`KLUG_SELFTEST`/… gates), **kybernet-bridge.md** (surface → 0-42); plus **roadmap.md** (the 1.44.x descriptions: "opening bite" → landed-through-1.44.9 + remaining; 1.43.x DOOM iron-complete + first-`mmap` repair reconciled). The **agnosticos front-door README** was also bumped 1.43.2 → 1.44.9 in passing (sibling repo, normally out of this ledger's scope). Honesty bar held: 1.42.x/1.44.x = QEMU-validated / iron-pending; only 1.43.x DOOM is iron-complete. **Process miss logged**: the doc-update agents got RELATIVE paths against a cwd in the *sibling* repo, so the README agent first edited `agnosticos/README.md` instead of `agnos/README.md` — caught + corrected (give doc-update agents ABSOLUTE paths). · **earlier 2026-06-04** (1.41.x shell-separation arc-complete sweep). **The multi-minor lag warned about below happened AGAIN** — the ledger sat at v1.38.8 across the **1.39.x** (VFS generic-write lift), **1.40.x** (exec-from-disk + mount routing), and the entire **1.41.x** (shell separation: agnsh-as-interactive-shell, FAT/exFAT write-syscall, three hardening passes, the shell shrink) arcs — three feature arcs, ~20 cuts — with state.md/roadmap/CHANGELOG kept current per-cut but the body docs un-swept. This sweep brought four stale docs current through **v1.41.11** (driven from the per-cut CHANGELOG): **README.md** (Status line extended to exec-from-disk + the shell-separation headline; `## Syscalls (26)`→`(34, 0-33)` with the 1.41.3 FS group + a4=r10; Subsystems rewritten for the userland agnsh shell + in-kernel recovery REPL + exec-from-disk + FAT/exFAT write-fd; build size → 1,070,720 B; shell.cyr 813 LOC), **architecture/overview.md** (shell-separation boot/process model, exec-from-disk, mount-routed VFS, the VFS_SEC_WFILE write-fd; cyrius 6.0.3→6.0.56; 28→34 syscalls), **syscall-additions.md** (the "still 26" claim corrected → 0-33; full per-slot table with landing versions, derived from the ksyscall dispatcher), **build.md** (added the `EXEC_SELFTEST` / `FS_SYSCALL_SELFTEST` / `SYSCALL_HARDEN_SELFTEST` gates). Done via a 4-agent parallel doc-update workflow, every diff independently verified against the dispatcher (0-33), build size, and shell.cyr LOC — and against the honesty bar (the 1.41.x stack is labelled QEMU/`fsck`-validated, iron burn PENDING, NOT iron-validated). | **Refresh cadence**: when a doc is touched, update its row. Full-tree sweep at minor-version closeouts — **fold a doc-health touch into the cycle-OPEN sweep** (the practical fix below), since cycle-closes keep deferring it.
>
> **Scope**: this repo only (`agnos`) — the `docs/` tree plus root-level files (README, CLAUDE.md, CHANGELOG, CONTRIBUTING, SECURITY, LICENSE, VERSION, cyrius.cyml). Sibling-repo docs (kybernet, agnosys, argonaut, agnostik, daimon, libro) are not audited here — each repo carries its own doc-health.md if its size justifies one. Cross-repo Cyrius pin/version drift lives in [`development/state.md`](development/state.md).
>
> **Location**: `docs/doc-health.md` (whole-tree scope) per [first-party-documentation § Development Docs](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/first-party-documentation.md#development-docs-docsdevelopment). **Not** under `docs/development/` — the ledger sweeps the whole tree and the location should match the scope.

This is a **ledger**, not a one-time audit. Rewrite-in-place as docs change. Small repo (13 doc files + 7 root files), so the ledger stays narrow; if `docs/` grows past ~30 files, switch to tier roll-ups like the agnosticos repo's pattern.

---

## At a glance — 2026-05-26 inventory (v1.35.0 cycle open)

**26 tracked files**: 9 root (7 `.md` + `LICENSE` + `VERSION`) + 17 `.md` under `docs/`. Net +1 from the v1.30.7 inventory: `development/build.md` (added at 1.31.0 as part of the production-lean cycle-open; previously unledgered). The 1.31.x → 1.34.x arcs' deliverables are mostly source-side (storage drivers, r8169, ext2/FAT/exFAT modules) — those aren't doc files. Bucket counts after the 2026-05-26 sweep:

| Bucket | Count | What it means |
|---|---|---|
| ✅ **Fresh / refreshed in this sweep** | 10 | Root: README.md (full rewrite to 1.35.0 capability picture), CHANGELOG.md (1.35.0 cycle-open + docs-sweep entry), VERSION (1.35.0), CLAUDE.md (durable-only, no drift), CODE_OF_CONDUCT.md. `docs/`: state.md (body brought forward from frozen 1.31.1), roadmap.md (forward-facing restructure), architecture/overview.md (storage/net/FS + cyrius pin), build.md (flag table completed — all 13 gates), this ledger. |
| 🟡 **Header-refreshed; content confirmed current** | 2 | syscall-additions.md + kybernet-bridge.md — surface (26 syscalls) / design (kybernet 1.2.1 bridge) confirmed unchanged since v1.21.0; headers bumped off the "v1.30.7 cycle" smell. |
| 🟠 **Read-through outstanding** | 1 | `BENCHMARKS.md` (CI-generated; the standing policy decision — checked-in tagged-state reference vs CI-only — never resolved). |
| 🔵 **Probably evergreen** | 3 | `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE` — standard, re-read pass annually. |
| 📦 **Archive — frozen by design** | 5 | `docs/development/issues/archived/` (3 files) + `docs/development/proposals/archive/` (2 files). Verified — nothing misclassified. |
| 🟢 **Live (non-archive)** | 2 | `proposals/2026-05-11-kaslr-scope.md` (Option B shipped v1.28.0; Option A deferred cyrius v6.1.x PIE), `issues/2026-05-15-cyrius-nonzero-gvar-init-not-honored.md` (live upstream cyrius bug; agnos `fn`-wrapper workaround durable). |
| ❓ **Open question** | 0 | No live strategic ambiguity. |
| 📄 **Dated audit** | 1 | `audit/2026-04-13-security-audit.md` — frozen dated artifact; next pass produces a new dated file. |

---

## Tier 1 — Root files

| File | Last touched | Status | Notes |
|---|---|---|---|
| `README.md` | 2026-06-10 | ✅ Fresh | **1.44.9 catch-up sweep (current)**: Status headline (DOOM iron-complete burn 1439 + the 1.44.x preemptive-ring-3 arc), Syscalls heading/table/count 34→43 (0-42) incl. rows 34-42, `waitpid`#4 non-blocking + `sync` made-real, project map + kybernet-init counts, the preemptive-scheduler boot line. **Earlier 1.41.11 sweep**: Status line extended to exec-from-disk (1.40.x, iron-validated) + the shell-separation headline (1.41.x — kybernet execs `/bin/agnsh` in ring 3, the full interactive shell is now userland agnsh, the in-kernel `shell()` is a recovery REPL, FAT/exFAT content-write via the syscall ABI at 1.41.7); `## Syscalls (26)` → `(34, 0-33)` with the 1.41.3 FS group (getdents/unlink/rename/link/stat + open re-route + mkdir/rmdir/sync made-real + a4=r10); Subsystems gained an Exec/process-lifecycle row + rewrote the Shell/kybernet/VFS/FAT-exFAT rows; build size + shell-LOC (813) + Project-Map ext2 range (1.31.x→1.41.x) refreshed. Verified vs the 0-33 dispatcher + the honesty bar (1.41.x = QEMU-validated, iron burn pending). **Earlier 1.38.8 (JBD2 arc-close)**: Status line + capability paragraph rewritten with ext4 extent allocation (1.37.x), JBD2 crash-safe journaling (1.38.x), kashi 1.0.0 vendoring; Subsystems table gained 3 rows (ext2/ext4 ext4-extent-alloc + JBD2 update, new JBD2 row, new Console-font row); architecture diagram + data-flow updated with JBD2 + kashi; Shell verb count 28 → 34 (added `dns`/`ping`/`ntp`/`date` from 1.35.x networking-comms + `jbd2` from 1.38.1); core file count 26 → 35 (net.cyr split into 8 protocol files at 1.36.0/.1 + selftests.cyr extraction at 1.36.2); Size Comparison + capability paragraph mention crash-safe journaling; Project Map's `core/` blurb reflects the split. **Earlier 2026-05-26 (v1.35.0 full rewrite)**: added Status line, Subsystems 36+ → 40+, fixed xHCI/FAT16/VirtIO-Net status, Shell 19 → 28 commands, file counts (core 26 / usb 9). |
| `CHANGELOG.md` | 2026-06-04 | ✅ Fresh | Kept current **per-cut** through `[1.44.9]` (the 1.39.x VFS-lift, 1.40.x exec-from-disk, and the full 1.41.x shell-separation arc each got per-cut entries in-flight). Per-arc history is the at-a-glance ledger the forward-facing roadmap points back to. |
| `CLAUDE.md` | 2026-05-21 | ✅ Fresh | Durable-only structure; volatile state correctly deferred to state.md. SemVer cut at 0.1.0 noted; no rule drift across the 1.31.x → 1.38.x arcs (verified 2026-05-28 incidentally during this sweep — kashi vendoring + jbd2 are all in state.md / CHANGELOG, not CLAUDE.md, which is the intended pattern). |
| `BENCHMARKS.md` | 2026-05-11 (stale) | 🟠 Deferred to 1.42.x | **Resolved as a 1.42.x item (user, 2026-06-04):** not a doc "policy" question — it's a generated artifact, and benchmarks haven't been run because 1.31.x→1.41.x was all *functionality* (storage / net / FS / exec / shell-separation), not perf. Perf is **1.42.x**'s dedicated job, so this stays stale until then. **Finding (2026-06-04): the generator is BROKEN** — `scripts/bench.sh` builds `build/agnos_bench` via `cyrius build -D ARCH_X86_64 kernel/agnos.cyr` WITHOUT prepending `../kashi/src/font_data.cyr`, so it fails on `KASHI_FONT_VGA_8X16` undefined (`fb_console.cyr:485`). It broke at the **1.37.5 kashi fold-in** (when `build.sh`/`test.sh` started prepending the font core) and hasn't run since — hence the 2026-05-11 date. **1.42.x step 1 = fix `bench.sh` to mirror `build.sh`'s kashi prepend, THEN regenerate.** |
| `CONTRIBUTING.md` | (pre-v1.27) | 🔵 Evergreen | Standard contribution guide. Re-read on minor closeout. |
| `SECURITY.md` | (pre-v1.27) | 🔵 Evergreen | Reporting policy. Re-read on minor closeout. |
| `LICENSE` | (genesis) | 🔵 Evergreen | GPL-3.0-only verbatim. |
| `VERSION` | 2026-06-10 | ✅ Fresh | **`1.44.20`**. Bumped by `scripts/version-bump.sh` per-cut; sole source of truth (cyrius.cyml resolves via `${file:VERSION}`). |
| `CODE_OF_CONDUCT.md` | 2026-05-11 | ✅ Fresh | Contributor Covenant v2.1 reference. No drift. |

## Tier 2 — `docs/architecture/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `architecture/kernel-font-namespace.md` | 2026-09-13 | ✅ Fresh | **1.57.3**: Invariant 5 rewritten as the AP-stack arc — the 1.57.2 measurement kept as history, the region-7 direct-map resolution, the one invariant left (`LOAD end <= 0x370000`, gate 34 relabelled), the `ap-stack-smoke.sh` runtime oracles and both mutants; Invariant 2's single-reader rule retired; Gates table +1 row. **NEW at 1.57.2.** The kernel-owned `/fonts` namespace (`core/kfont.cyr`): verify-before-expose and the cyrius even-length ≥ 64 KB literal defect that makes it load-bearing; 4 KB chunks read once; the 2 MB direct-map region and why it is allocated after `cr3_load(0x1000)`; prefix intercept, not a mount; the kashi-style `build.sh`/`test.sh`/`bench.sh` fold-in + `REKHA_REF`; the measured layout (`LOAD` end `0x35E770`, AP stacks inside `.rodata`, gate 34 — the 1.57.2 state, now history). Companion to ABI §3.5. Numbers are 1.57.2 measurements unless labelled 1.57.3 — re-measure, do not copy forward. |
| `architecture/kernel-stacks-and-preemption.md` | 2026-09-24 | ✅ Fresh | **NEW at 1.57.6** (Path 2 bites S3.1–S3.3, extended by the fix pass). Invariants 1–6: a process's kernel stack is its own for syscalls AND interrupts (the `SCF_*` frame, the stub register contract, fail-STOP tops + the `#DF` COM1 line + `kstack_check_entry`); `on_cpu(old) = −1` only from `sched_frame_iretq` (INV-11); READY-only picks; non-preemptible lock holders and ISR bodies; CPL0 frames switched only on their own CR3; the out-of-band entries. The region-7 map and guard pages. Extends with S3.4+ (the voluntary switch, BLOCKED). |
| `architecture/spawn-and-fd-lifetime.md` | 2026-09-24 | ✅ Fresh | **NEW at 1.57.6** (S2 + fix pass). Per-process spawn arms and when they clear; pipe buffers live until the last reference anywhere (the one-`fs_lock`-hold rule for every dropper); CLEANFD's shape; Invariant 4 — a CPU leaves a dying process's CR3 before `on_cpu` is released and compares against the LOADED CR3 (S7 must keep it). |
| `architecture/kernel-clocks.md` | 2026-09-24 | ✅ Fresh | **NEW at 1.57.6** (S1). The three clocks (`timer_ticks`/#40, the TSC/#95, the klog timebase); the PM-timer reference; −1 from `#95` permanent after the pre-userland retry (Invariant 2: kernel code keyed on `tsc_per_us` must handle 0); the `lapic_calibrate` throttle limitation with measured numbers (step S1b fixes it). |
| `architecture/overview.md` | 2026-06-10 | ✅ Fresh | **1.44.9 catch-up sweep (current)**: 34→43 (0-42) everywhere; the cooperative→**preemptive ring-3** process-model rewrite (kthread_create + preempt gate, per-proc CS/SS, timer-sliced, concurrent exec+exit, ELF spawn); new sysinfo/graphics/timing/input syscall subsections; size 1,123,864 B; SMAP/memory-map notes intact. **Earlier 1.41.11**: header cyrius 6.0.3→6.0.56, 28→34 syscalls (0-33); boot/process model rewritten for the shell-separation (kybernet execs `/bin/agnsh` ring 3, in-kernel `shell()` = recovery REPL), exec-from-disk (`elf_load_from_file`→`exec_and_wait`→`proc_reap`, iron-validated 1.40.x), the mount-routed VFS (ext2 at `/`, FAT/exFAT at `/mnt/*`), and the `VFS_SEC_WFILE` write-fd (1.41.7); load-bearing memory-map + SMAP `stac`/`clac` notes kept intact. **Earlier 2026-05-26 (v1.35.0)**: header to 40+ subsystems + cyrius 6.0.1 + iron-validation status; boot sequence + subsystem diagram + Block-I/O and Networking prose rewritten for the storage stack (5-backend block layer + GPT), the r8169/DHCP networking stack, and read+write filesystems; "FAT16 read-only" retired; shell count 19 → 28. Memory-map table + Process Model SMAP/stac/clac notes left intact (still load-bearing). |

## Tier 3 — `docs/audit/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `audit/2026-04-13-security-audit.md` | 2026-04-13 | 🔵 Frozen (dated) | Audit report — dated artifact. Findings should be cross-referenced against current code; next audit pass produces a new `YYYY-MM-DD-*.md`, not an edit to this one. |

## Tier 4 — `docs/development/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `development/roadmap.md` | 2026-06-04 | ✅ Fresh | Kept current **per-cut**: the 1.41.x bite ladder (§ 1.41.x Shell Separation Arc) is maintained through 1.41.11 (arc software-complete, iron burn staged at agnosticos `#tracker-141x-cycle`); the "Current" pointer + arc summary bumped each cut. **Earlier 2026-05-26**: restructured to forward-facing (per user directive): removed the completed "Shipped" arc ledger, the 1.30.x recap, all ✅-closed "Next cycle" rows, and the completed Security-Hardening / Multi-Architecture / Planned tables (history now lives in CHANGELOG). Retained: Current pointer + 1.35.x active theme, the active/near-term table, slotted-future minors (1.37–1.45), deferred items, the platform decade map, and the cyrius-PIE-gated KASLR section. |
| `development/state.md` | 2026-06-10 | ✅ Fresh | Kept current **per-cut** through 1.44.20 (Version table, build size 1,193,072 B, the giant arc-narrative head rolled each cut; the 1.41.x shell-separation arc's per-bite history is in the narrative). **Earlier 2026-05-26**: body un-frozen from its 1.31.1 shape: Build artifacts (475,096 B → 798,936 B; cyrius 5.11.59 → 6.0.1; per-cut trajectory trimmed to a CHANGELOG pointer), source rollup (66 → 71 files, core 22 → 26, usb 8 → 9), subsystem table (added r8169 / DHCP / USB-MS / RAM-disk / ext2-4 / FAT / exFAT / FS-write-guard rows; fixed multiboot label + AHCI iron status + shell count + 5-backend block layer), In-flight + Recently-closed sections, headline to the 1.35.x catchup-tidbits theme. |
| `development/build.md` | 2026-06-10 | ✅ Fresh | **1.44.9 catch-up sweep (current)**: added the gates accreted across 1.42.x-1.44.x — `THREAD_SELFTEST`/`RING3_SELFTEST` (1.44.x), `DOOM_SELFTEST` (1.43.x), `KLUG_SELFTEST` (1.42.x), `FB_ANSI_SELFTEST`, `HARDENING_SELFTEST`. **Earlier 1.41.11**: added the gates `scripts/build.sh` accreted across 1.40.x/1.41.x — `EXEC_SELFTEST` (1.40.x exec-from-disk), `FS_SYSCALL_SELFTEST` (1.41.3 FS-syscall selftest, `fssys: ALL PASS`), `SYSCALL_HARDEN_SELFTEST` (1.41.6 ingress-hardening regression, `shsys: ALL PASS`) — confirmed the documented list now matches build.sh. **Earlier 2026-05-26**: flag table completed: was current through the storage arc (`AHCI_RW_DEMO` / `MSC_RW_DEMO` / `RAMDISK_ENABLE`) but missing the 7 networking/FS gates `scripts/build.sh` accreted since — added `NET_VERBOSE` (1.32.x) + `EXT2_WRITE_SELFTEST` (1.33.x) + `FATFS_SELFTEST` / `FATFS_WRITE_SELFTEST` / `EXFAT_SELFTEST` / `EXFAT_WRITE_SELFTEST` / `FAT_ALLOW_ESP_WRITE` (1.34.x), plus FS-selftest enabling examples. All 13 build.sh gates now documented. |
| `development/agnos-userland-abi.md` | 2026-09-24 | ✅ Fresh | **1.57.6**: rows 3/25/37/43/62/97/99 + §4.6 + a new §4.8 (`#43` flags, `SPAWN_E_*` codes, per-process spawn arms, recipes) from S2; #40/#95 (PM-timer calibration, −1 permanent) from S1; row 4's same-cut claim corrected. **1.57.2**: §3.5 `/fonts` path contract added (no syscall row — no number minted; `syscall-abi-check` unaffected) + a §3.1 `open` pointer. Earlier per-cut corrections are in the dated blocks above (1.57.1 §4.4, 1.56.60 row 13, 1.56.58 §4.5, 1.56.56 rows 103/104, 1.56.55 row 96, 1.56.54 four rows). ⚠ This row did not exist until 1.57.2 although the file is the most-corrected doc in the repo; §2 row 7 (`open`) still carries the pre-1.41.3 "initrd_open ONLY" text and is owed a rewrite. |
| `development/kybernet-bridge.md` | 2026-06-10 | ✅ Fresh | **1.44.9 catch-up sweep**: surface ref 0-33→0-42. **1.41.11 sweep — the stale notes corrected.** The "26-syscall interface" framing now says the kernel surface grew to 0-33 (kybernet's bridge still uses its original 26-call subset). The `open`/`mkdir`/`rmdir`/`sync` "Noop" rows are FIXED — all made real at v1.41.3 (mount-routed). Added a "post-kybernet additions (26-33)" table (mmap/munmap + the v1.41.3 FS group) marked NOT part of the bridge. The bridge *design* (agnosys dual backend) is genuinely unchanged since v1.21.0. |
| `development/security-hardening.md` | 2026-06-04 | ✅ Fresh | **1.41.11 sweep**: the S1-S13 v1.28.0 framework is a HISTORICAL doc (kept verbatim — accurate for what it covers), but it predated the 1.41.x ring-3-ingress hardening. Added a **"Since this was written"** note cross-referencing the second hardening front (1.41.5 type-confusion/ceiling/bounds, 1.41.6 regression net, 1.41.10 write-fd) → agnosticos `kernel-1415-hardening-audit.md`. The S7 Option-A PIE-KASLR deferral still lives in roadmap.md (cyrius v6.1.x). |
| `development/syscall-additions.md` | 2026-06-10 | ✅ Fresh | **1.44.9 catch-up sweep (current)**: surface 38/34 → 0-42 (43); added per-slot rows 34=uname/35=sysinfo/36=klog (1.42.x) + 37=execwait/38=fbinfo/39=blit/40=uptime_ms/41=sleep_ms/42=kbscan (1.43.x); `waitpid`#4 non-blocking note. **Earlier 1.41.11 — the "still 26" claim CORRECTED.** Surface is **0-33 (34)**: mmap(27)/munmap(28) at 1.35.3/.4, then the 1.41.3 FS buildout — getdents(29)/unlink(30)/rename(31)/link(32)/stat(33) + the `open`(7) mount-route + `mkdir`(9)/`rmdir`(10)/`sync`(12) made-real + the **a4=r10** 4th-arg ABI extension (the syscalls userland agnsh needs now that the shell is in ring 3). Full per-slot table with landing versions, derived from the live `ksyscall` dispatcher + cross-checked vs `agnos-userland-abi.md`. (The 2026-05-26 "still 26" was already stale then — mmap/munmap had landed at 1.35.3/.4; the body table is now the canonical-pointer-backed truth.) |

## Tier 5 — `docs/development/issues/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `issues/2026-05-15-cyrius-nonzero-gvar-init-not-honored.md` | 2026-05-15 | 🟢 Live | **NEW since v1.28.4 sweep**. Upstream cyrius bug surfaced via the v1.30.x Path-C kernel/version.cyr design — kmode `var` globals with non-zero initializers don't honor those initializers because PARSE_PROG runs before EMIT_GVAR_INITS, so the kernel program body executes before globals get their non-zero values. Worked around in agnos by wrapping banner literals in `fn` bodies (rodata pointer baked in at compile time, no runtime init dependency). Upstream fix is a cyrius v5.12.x+ concern; agnos workaround is durable. |
| `issues/2026-09-23-*.md` (nine) + `issues/2026-09-24-msc-cdb-buffer-is-two-bytes.md` | 2026-09-24 | 🟢 Live | The daimon/patra filings of 2026-09-23 still open, each with a **Status** header naming its 1.57.x step (S3c: sleep_ms, flock · S4: inbound SYN, recv EOF · S5: socket owner, loopback-only · S6: send/connect hold the CPU · S7: end/stop/continue · S8: limits) and noting the Path 2 foundation landed in 1.57.6. The MSC file is new at 1.57.6 (arising repair, not fixed in the cut). |
| `issues/archived/2026-09-23-{tsc-calibration-refused-stops-the-us-clock,spawn-path-args-cannot-contain-spaces,spawn-path-failure-gives-no-reason,child-inherits-every-fd-and-spawn-arms-leak}.md` | 2026-09-24 | 📦 Archive | **Closed at 1.57.6.** Status headers rewritten (RESOLVED + what shipped + the gate: `tsc-smoke` / `spawn-smoke` markers) and Resolution blocks appended answering each ask and what the change broke (nothing observed; the pipe UAF and a `-smp 4` triple fault were found and fixed on the way), then moved. |
| `issues/archived/2026-09-13-no-proportional-face-on-the-target.md` | 2026-09-13 | 📦 Archive | **Closed at 1.57.2, same day as filed.** crab's ask for an `open()`-able TrueType face; operator ruling → rekha, kernel-embedded. Resolution header: what shipped (`/fonts/default.ttf` + provenance alias, verify-gated), what crab does (the load only), what the change broke (mountlist unchanged; size gates re-derived; AP-stack hazard filed; aarch64 no worse; rekha tag uncut), and the **dhancha** blocker that remains and is not ours. Original filing verbatim below the rule. |
| `issues/archived/2026-09-13-ap-stacks-inside-kernel-rodata.md` | 2026-09-13 | 📦 Archive | **Closed at 1.57.3, same day as filed** (operator decision: the filing's first option). Filed from the 1.57.2 review: the AP1–3 boot/TSS stacks at `0x310000–0x340000` sat inside kernel `.rodata` since the face embed (rekha chunks ~52..100, 275 B margin), tolerated by the 1.57.2 gate 34. Resolution block: relocated to region-7 direct-map windows (tops `DIRECTMAP_BASE + 0xFD0000 + cpu*0x10000`, region 7 now full), the three sites before/after, why direct-map and why the BSP stays, gate 34 reduced to `LOAD end <= 0x370000`, the `-smp 4` selftest + smoke with both mutants' evidence, what was checked for breakage before archiving (three smokes, check.sh 34/34, fmt + kprint-len). Original filing verbatim above it. |
| `issues/archived/2026-04-27-serial-putc-cc5-regression.md` | 2026-05-11 | 📦 Archive | **Closed at v1.28.1**. Resolution section (matched-conditions re-measurement under cyrius 5.10.44 / QEMU 11.0 / Ryzen 7 5800H / TCG; bench delta table showing cc5 broadly equal-or-better than cc3; `serial_putc` outlier explained by QEMU UART-emulation latency, not codegen) prepended to the original body. Frozen. |
| `issues/archived/2026-04-27-memory-isolation-deep.md` | 2026-05-11 | 📦 Archive | **Closed at v1.27.1**. Resolution section (SMAP root cause + observation-to-mechanism table + process note on the hypothesis class that misled triage) prepended to the original body. Frozen — refer back but do not edit. |
| `issues/archived/2026-04-27-cr3-load-helper.md` | 2026-05-11 | 📦 Archive | Closed alongside the memory-isolation fix at v1.27.1 — the v1.26.0 helper was a real fix, just not the whole one. |
| `issues/archived/2026-04-27-cyrius-fmt-tracks-braces-in-comments.md` | 2026-04-27 | 📦 Archive | Closed at v1.26.1 (cyrius 5.7.22 fmt fix). Frozen. |

## Tier 6 — `docs/development/proposals/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `proposals/2026-05-11-kaslr-scope.md` | 2026-05-18 | 🟢 Live | Option B (data-only) **shipped at v1.28.0** — `pmm_next_free` randomization, RDRAND-seeded entropy, sign-mask hygiene, memory-isolation phys-move. Option A (full PIE binary KASLR) deferred to cyrius v6.1.x where PIE codegen lands. The proposal stays live (not archived) because Option A is a real future candidate; archival when full KASLR ships or is permanently retired. Status section confirmed via S1 of the 2026-05-18 doc-staleness audit (security-hardening.md S7 deep-dive section now references this proposal explicitly). |
| `proposals/archive/2026-04-27-acpi-identity-map-ceiling.md` | 2026-04-27 | 📦 Archive | Closed at v1.25.0 (`pt_init` extended to cover 0–4 GB). |
| `proposals/archive/2026-04-27-cc5-kernel-boot-shim-regression.md` | 2026-04-27 | 📦 Archive | Closed at v1.24.0 (cyrius 5.7.19 kmode emit-order fix). |

---

## Next sweep targets

**Sweep status (2026-06-04, 1.41.x arc-complete sweep)**: README, architecture/overview.md, syscall-additions.md (the "still 26" → 0-33 correction), build.md (3 new gates) brought current through v1.41.11 via the 4-agent doc-update workflow; this ledger refreshed; VERSION + CHANGELOG + state.md + roadmap confirmed per-cut-current. `kybernet-bridge.md` + `security-hardening.md` ALSO updated this sweep (follow-up pass): kybernet-bridge's stale `open`/`mkdir`/`rmdir`/`sync` noop notes corrected + the surface-growth framing + the 26-33 additions table added; security-hardening.md got a "Since this was written" cross-reference to the 1.41.x ring-3-ingress hardening front. The only Tier-1 carry-forward left is the **BENCHMARKS.md policy decision** (below). Remaining queue:

1. **`BENCHMARKS.md` → RESOLVED as a 1.42.x item** (no longer a doc "policy" carry-forward). It's a generated artifact; it's stale because 1.31.x→1.41.x was functionality, not perf, and perf is 1.42.x's job. **Prerequisite for 1.42.x: `scripts/bench.sh` is BROKEN** — it doesn't prepend kashi `font_data.cyr` (broke at the 1.37.5 fold-in; `KASHI_FONT_VGA_8X16` undefined), so fix the generator's kashi prepend (mirror `build.sh`) before any perf-band regenerate.
2. **`development/build.md` read-through** — confirm its compile-gate flag list matches the current `scripts/build.sh` (the 1.34.x arc added `EXFAT_SELFTEST` / `EXFAT_WRITE_SELFTEST` / `FAT_ALLOW_ESP_WRITE`).
3. **`scripts/build.sh` cosmetic banner** — still prints stale `multiboot2 (ELF64): OK` + `Boot: pending shim rewrite` labels; should reference Path C (also tracked as a roadmap near-term item).

---

## Forward doc-policy commitments

- **`state.md` is bumped by `scripts/version-bump.sh`** — exercised end-to-end at v1.27.2 / v1.28.0 / v1.29.0 / v1.30.0 / v1.30.7 (Kernel row, Last-refresh date, Released date updated by the script with no manual edits). The sed regexes use `#` as delimiter to avoid the ERE-`|`-alternation bug that surfaced at v1.27.1.
- **Doc-health is refreshed at minor-closeout, AT LATEST** — the 2026-05-18 audit named this after the ledger aged out across THREE minor releases. **It happened again**: this ledger sat at v1.30.7 across the 1.31.x / 1.32.x / 1.33.x / 1.34.x arcs (FIVE minors) until the 2026-05-26 sweep. The commitment ("touch doc-health on every minor cut, even just a header bump confirming nothing moved") is sound but was not honored — the cut flow runs `version-bump.sh` (which does *not* touch this ledger) and the manual body sweep keeps getting deferred to the next cycle-open. **Practical fix**: fold a doc-health touch into the cycle-OPEN sweep (when the body sweep happens anyway), not the cycle-close, since cycle-opens reliably trigger a docs pass and closes don't.
- **Script-fresh / body-stale gap is now named**: `scripts/version-bump.sh` refreshes the cheap fields (VERSION, kernel/agnos.cyr banner comment, state.md header date + Version-table row, roadmap.md "Current" line). Body prose drifts independently. Doc-health audits at minor-cut must specifically inspect body prose against header dates, not trust matching headers.
- **Issue-doc archive on resolution** — when an issue doc closes, move it into `issues/archived/` with a prepended **Resolution (vX.Y.Z)** section. Never delete; the resolution narrative is the audit trail.
- **Proposals graduate or die** — a proposal that sits in `proposals/` for more than one minor without progress should be either accepted (promote to a roadmap item with an ADR if the decision is non-obvious) or archived with a `Status: rejected` note.
