# Changelog

All notable changes to AGNOS are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## What an entry may contain

**MAY**: what changed · the version it shipped in · the benchmark number that justifies any
performance claim · exact ABI numbers (syscall numbers, struct offsets, bit positions, flag values, exit codes) · a
`Breaking` section with a migration guide · the build size.

**MAY NOT**: hypothesis narrative · burn-by-burn story · the reasoning that produced the change ·
a restatement of a falsified lead · retrospective, apology or self-criticism.

**Measured register values, falsified hypotheses and per-burn evidence live in
`agnosticos/docs/development/prior-art/` and `agnosticos/docs/development/iron-log.md`, NOT here.** A falsified lead
is named in one line only where a future session would otherwise re-attempt it.

A removed syscall number, struct offset or measured value is a fact deletion. Numbers stay verbatim.

---


## [1.56.59] — 2026-09-02 — two consumers asked for the same thing, and the one told not to prioritise it was right

### Added — `mountlist` #104: the mount table, enumerated

- `mountlist(buf, max) -> count / -1`. **80-byte** records, all-u64 header per ABI §4.1:
  `backend` @0 (`FsBackend` — 1 ext2 · 2 FAT · 3 exFAT; 0 `FS_NONE` never emitted), `prefixlen` @8,
  `prefix` @16 (**64 B, NUL-padded**). `max` is a record count.
- ⭐ **FILED BY TWO CONSUMERS ON THE SAME DAY, WITH OPPOSITE PRIORITIES, AND THE MINORITY WAS RIGHT.**
  chakshu (the system monitor) listed it as its §6 and said **"do not prioritise this"** — a monitor
  can `statfs` the three known prefixes. crab (the file manager) called it "the only thing we actually
  need". crab wins on a case chakshu did not have: **aliasing**. `vfs_mount_init` (`core/vfs.cyr:396`)
  gives an ext2-less boot the SAME backend under BOTH `/` and its `/mnt/…` prefix — its own comment
  calls them "harmless redundant aliases", harmless to routing but **one volume listed twice** in a
  sidebar. `statfs` answers *is this string mounted*; it cannot answer *are these two the same volume*.
  ⇒ A "do not prioritise" from one consumer is not a verdict on the capability.
- ⚠ **A new number, not a widening of `mount`#11** — #11 takes no arguments, and unused argument
  registers carry **stale values, not zero** (the measured `#100`/`#101` rule), so widening it would
  hand every shipped caller an arbitrary pointer.
- ⛔ **The arm takes NO LOCK, and that is only safe while `mount`#11 and `umount`#24 are no-ops.** Both
  are unconditional `return 0;`, so the table is written once by `vfs_mount_init` and immutable after.
  The day `mount` becomes real this needs `fs_spin_lock`, or it hands ring 3 a torn prefix.
- ⛔ Validated with `is_user_array`, not `is_user_range(buf, max * 80)` — the product wraps, verbatim
  the `#99` defect fixed at 1.56.51.
- **Boot-proven**: `scripts/harness/mountlist-test.py` + `tests/mountlist/mlist.cyr`, exit **95**. The
  oracle is the table's SHAPE, not `count > 0` — a stub returning one zeroed record would pass a count
  check. Mutation-proven: removing the `max` budget reddens it with the right message.
- ⚠ **One assertion in that gate CANNOT CURRENTLY FAIL, and it says so in-file.** The NUL-padding check
  was mutation-tested by copying all 64 bytes unconditionally and still passed — `vfs_mnt_prefix` is
  zero-initialised and written once per boot, so there is no stale tail yet. It is a regression guard
  for when `mount` becomes real, not a live oracle. Recorded rather than left to look like coverage.
- ⭐ **THE CROSS-REPO LOOP CLOSED INSIDE THE CUT, AND THAT IS WORTH RECORDING.** #104 was minted here,
  the peer was filed as an issue in cyrius's own tree
  (`docs/development/issues/2026-09-02-agnos-syscall-104-mountlist-wrapper.md`) per the NEVER-TOUCH
  ruling — no cyrius code edited from here — and **cyrius 6.5.43 shipped `SYS_MOUNTLIST` +
  `sys_mountlist`** and archived the filing. `syscall ABI` reads `kernel 105 · abi-doc 105 · cyrius
  105`: **32/0 green**.
  ⚠ It was **31/1 mid-cut** and that red was correct, not a defect — `symlink`#63 and `readlink`#70
  both shipped in exactly that state. The gate is designed to be red between minting and the peer
  landing. Do not "fix" a future one by editing cyrius, and do not weaken the gate.

### Fixed — 38 more vacuous gates: the three surfaces the 1.56.58 sweep never reached

- `.github/workflows/` **18** · `scripts/burn/` **12** · host GPU oracles **3** · the three named
  residuals **5**. With 1.56.58's 39, that is **77** across the two cuts, and every filed finding in
  [`2026-09-02-vacuous-gates-sweep.md`](docs/development/issues/2026-09-02-vacuous-gates-sweep.md)
  is now resolved.
- ⛔ **`release.yml` would have SHIPPED on a failed changelog parse.** A header drifting from
  `## [1.56.59] —` to `## 1.56.59 —` produced a release body reading *"No changelog entry for this
  release."* and exited 0. Worse: the awk pattern interpolated the tag as a **regex**, so a changelog
  holding only `## [1x56x59]` satisfied the extractor for tag `1.56.59` — it would have published
  **another version's notes** as this one's.
- ⛔ **A SKIPPED `boot-test` satisfied `needs: [ci]`.** GitHub counts a skipped job as success for a
  called workflow — the same structure `ci.yml:283-291` already records as having once shipped every
  release with zero boot verification, where only the ref condition was repaired. A new `ci-gate` job
  requires boot-test to have actually RUN on a push.
- ⛔ **`burn-verify.sh` said "Safe to flash" with `kernel/` absent**, and printed an empty `ARM:` line
  from a blank stamp. It is the last gate before writing the operator's only machine.
- ⛔ **`ci.yml`'s format check exempted files by SUBSTRING**: a file named `ll.cyr` was silently
  skipped because that string occurs inside `kernel/user/shell.cyr`. Measured — the same file renamed
  `zz.cyr` was caught.
- ✅ The 1.56.58 **declined** finding is fixed: tonegen's reason to decline had expired, since the
  1.56.58 floor already refuses the verdict unless a sustained tone was located. And both
  "moved the vacuity up a level" items are closed — `agnsh-kvm-test.py` GATE 2 scored serial growth
  that the kernel log itself satisfies with **zero keystrokes delivered** (reproduced against a stub
  guest), and now uses the sibling's ANSWERS oracle.
- ⚠ **A CEILING THE SWEEP ADDED WAS REVERTED IN REVIEW.** The workflows fix imported check.sh gate 32's
  **2 MiB size ceiling** into CI beside the 50000 floor. Only the floor is an anti-vacuity assertion;
  the ceiling is a BUDGET, had never been a CI gate, and the binary sits **4% under it** — so it would
  have turned every push red AND blocked releases on the next shader blob, with no local warning, and
  the fix would have been to edit the number. **A floor that asserts more than "something was
  enumerated" is scope creep wearing a floor's clothes.**
- ⛔ **Two residual limits, stated because they are not closable here:** `ci-gate`'s logic is proven
  over a 9-row `needs.*.result` matrix including the load-bearing skipped row, but GitHub actually
  setting that result was never executed (no runner, no `act`); and tonegen's 400-480 Hz band was
  never sampled against real captures, so its WARN→FAIL promotion bets on an unmeasured tolerance.

### Added — the telemetry counters a system monitor is built from (chakshu §1/§2/§3/§4)

- **§4 per-process CPU time — the section the filing calls "the one that changes what a system monitor
  can be on AGNOS".** Live in `proclist`#99's `+56` **low u32**, in 100 Hz ticks (one tick = 10 ms, the
  unit `uptime_ms`#40 already reports in, so a consumer differences two samples exactly as it does
  Linux jiffies).
  - ⚠ **A parallel array, not a `struct Process` field, and that is forced.** The struct is 22 fields ×
    8 B == the 176-byte stride `proc_table` is indexed by, all of it register state. Widening it would
    move the stride and silently invalidate every `proc_table + i * 176 + N` in the tree.
  - ⛔ **Charged OUTSIDE the BSP-only gate in `timer_handler`, and that is the whole correctness
    argument.** That gate exists because `timer_ticks` is one global wall clock and the NIC ring has
    one consumer. CPU time is the opposite shape: each CPU runs a **different** process and must charge
    its own. Gating it would attribute every AP's work to nobody — and the bug would present as "the
    monitor says the box is idle while it is busy", which is the hardest kind to trace to an
    accounting line.
  - ⛔ **Zeroed at slot ALLOC, not at exit or reap.** Clearing at exit would let a monitor sampling
    between exit and reap see a live process with 0 ticks — indistinguishable from one that just
    started. Alloc is the single moment the old value provably means nothing.
  - ⚠ **Saturates at 2^32-1, does not wrap.** A wrap gives a consumer a NEGATIVE delta and a nonsense
    CPU%. Saturating is wrong-but-monotonic; wrapping is wrong-and-non-monotonic.
- **§1 packet counters + §2 network byte counters** — `net_config`#61 fields **8-11**.
  - ⭐ **Counted at `nic_send`/`nic_poll`, NOT at the virtio ring indices the filing offered.** Those
    exist only on the QEMU path, so a counter built on them reads 0 on iron where r8169 runs. Those two
    functions are the one place both drivers meet. Loopback is excluded by construction — it calls
    `net_demux_frame` directly and never reaches them.
  - ⭐ **Extended #61 rather than minting, so it shipped to consumers the same day**:
    `sys_net_config(field)` already passes an arbitrary field id, so there is **no cyrius peer to wait
    for**. That is the difference between landing in this cut and landing in a toolchain release.
  - ⚠ Only a transfer the driver **accepted** is counted; both send paths return <0 on refusal, and
    counting a refused frame makes tx drift above what the wire ever carried.
- **§3 per-device disk I/O — `blkstats`#105** `(tag, field) -> sectors`, keyed by `blk_enum`#75's
  existing tag list. This one was *implement* counters, not *expose* them: `block.cyr` held **zero**
  statistics, and the only accumulator in the whole block path was NVMe-only, counted submissions not
  bytes, and is **reset by `bench.cyr`** — which is exactly what makes it unusable as telemetry.
  - ⚠ **Sectors, not bytes.** This layer moves exactly one sector per call; a byte figure needs the
    per-device LBA size, which can be **4096** — a live latent path (`blk_lba_bytes_ok` admits it), so
    a kernel-side byte count would be wrong the moment a 4Kn device appears.
  - ⛔ **No `blk_registered` gate**: an unregistered device legitimately reports 0, and refusing it
    would collapse "has done no I/O" and "does not exist" into one answer.
- **§5 per-process RSS — LANDED.** `proclist`#99's `+56` **high u32**, in 4 KiB pages.
  - ⭐ **COMPUTED, not accounted** — exactly what the filing predicted (*"recording a number it
    computes"*). Walks the process's page directory counting PDEs that are **present AND user**,
    512 pages (2 MB) each.
  - ⛔ **The incremental version was built first and cannot work.** The ELF loaders map every segment
    into the new `cr3` **before** `proc_set_cr3` binds it to a slot (`elf.cyr` — the mapping loop is
    ~250 lines above the bind), so no slot owns that cr3 at charge time and every charge is dropped.
  - ⭐ **The measured topology, because finding it was the work.** A probe build dumped the walk per
    live slot: `pid=6 cr3=ffd7000 pml4e=ffd6027 pdpte=ffd5027 pd=ffd5000 present=129 user=3`.
    `PML4[0] → PDPT[0] → PD` is right; `present` is ~129 because `proc_create_address_space` fills
    PD[0..7] kernel-identity and PD[8..63] identity-**supervisor** (`0x83`, no US bit). **Only the
    loader's `0x87`/`0x85` carry US**, so the US test is the entire discriminator — a walk without it
    reports ~258 MB of kernel window as every process's RSS. The gate's ceiling catches exactly that,
    mutation-proven.
  - ⚠ **An intermediate report in this cut said §5 "did not land — the walk finds zero present PDEs".
    That was a stale-build measurement, not a result.** The walk was correct throughout. Recorded
    rather than quietly dropped: a wrong measurement written down as fact is the failure this tree
    keeps finding, and it is no better when it is mine.
- **Boot-proven** — `scripts/harness/telemetry-test.py` + `tests/telemetry/tlm.cyr`, exit **95**.
  ⛔ **The oracle is "the counter MOVED", not "the counter is readable."** Every one of these would
  read 0 on a kernel that declared the variable and never incremented it, and 0 is a plausible-looking
  answer — so a gate that merely called the syscalls would pass on exactly the defect worth catching.
  Each assertion samples, generates real load, and requires an increase; monotonicity is asserted
  separately, because "never decreases" is a different claim from "increases".
  ⚠ **Its first run FAILED at §1 and the gate was right** — the harness had no `-netdev`, so
  `nic_send` correctly returned -1 and counted nothing. A correct kernel scoring a red because the
  harness was wrong is the gate working. Mutation-proven on two axes afterwards (killing the tick
  increment yields 84; wiring tx bytes to the packet increment yields 89).

### Added — the HID iron burn finally has an oracle (issue residual #1)

- ⛔⛔ **THE ROADMAPPED BURN WAS UNFALSIFIABLE, AND THAT IS WHY THIS IS THE ITEM THAT MATTERED.**
  `hid_recover_halted` cleared `hid_ep_needs_reset` **before** the EP-state check and had no else
  branch. So a provoked halt whose state read came back non-Halted left **zero trace**, and
  *"no stall ever reached the driver"* and *"a stall did and recovery DECLINED"* were the same silence
  — with the second reading as a passing run. A burn that cannot fail honestly is a trip to the machine
  that produces a feeling, not a gate.
- The EP state is now read **once into a local**, so the branch that declines can report what the
  controller actually answered; an `else` branch prints it with a `flagged/confirmed/declined` tally.
- ⚠ **Counters at the flag-set site, not a log line — the context decides it.** The flag is set inside
  `hid_poll`, which the 100 Hz timer ISR calls, so `kprint` is forbidden there (`console_spin_lock` is
  a bare non-recursive xchg). Even `klug_append` would be wrong: it mutates the ring head OUTSIDE that
  lock, so an ISR append can interleave mid-line with a locked `kprint` on another CPU and garble the
  very log this instrument exists to produce. A plain integer add has neither problem.
  **The ISR counts; thread context reports.**
- ⚠ `kprintln`, not `klug_append`, for the decline line: archaemenid **has no serial port** — the build
  host is the target — so the operator reads the framebuffer console, and the one line that decides the
  burn has to be on it.
- ⭐ **REACHABLE IN-TREE FOR THE FIRST TIME.** New `HID_CC_INJECT_HALT=1` injects **6 (Stall)**, a
  halting code; the existing `HID_CC_INJECT` injects a deliberately non-halting **2** and therefore
  could never set the flag — which is why this file's own reachability claim rested on a hand-modified
  build, and why turning that flag on and seeing nothing was the *expected* result all along.
- ⛔ **NOT the build-gated stub seam withdrawn at 1.56.57.** Nothing fabricates the controller's
  verdict: `xhci_ep_state()` still reads the real Output EP Context, QEMU's controller never halted, so
  recovery **correctly declines** — which is precisely the branch being proven. It proves the ORACLE.
  The Reset/Set-TR-Dequeue sequence has still never executed anywhere and still needs real silicon.
- **Measured on a live boot** — `scripts/harness/hid-halt-oracle-test.py`, keystrokes driven through the
  QEMU monitor because `usb-kbd` emits no interrupt-IN completion until a key is actually pressed
  (a boot-and-grep run exercises nothing, measured):
  `hid: endpoint flagged HALTED but the controller reports EP state 0 -- recovery DECLINED, input from
  it stays dead (flagged/confirmed/declined 3/0/1)`
- ⚠ **THE NEW GATE CAUGHT ITSELF BEING VACUOUS.** Its first precondition keyed on the SAME string it
  asserts, so deleting the decline line made it **SKIP instead of FAIL** — the oracle derived from the
  artifact under test, the V5 shape, inside the gate written to prove an oracle. It now keys on a
  separate `hid: HALT INJECTION ARMED` banner (which also warns the operator never to flash that
  build), and is mutation-proven: removing the decline line yields **exit 1**, not a skip.
- ⇒ **The burn is now worth slotting. It was not before.**

### Fixed — the console is somebody else's stdout

- `proclist`#99 and `ptrscan`#98's first-call one-shots now `klug_append` to the log ring instead of
  `kprintln` to the console. Filed by chakshu: the line landed **inside** the monitor's output, between
  its header and its process table, corrupting `shu -p` (its pipe-safe mode) and scribbling over a TUI
  frame. ⚠ 1.56.58 made it worse, not better — the line had gained a `[   37.727698] ` uptime prefix.
  The diagnostic is kept in full and still reachable with `run /bin/klug`.

### Fixed — `proclist`'s `+56` promised two fields for one slot

- The record is exactly 64 B with `name[32]` at +24..+55, so **+56 IS the final 8 bytes** — yet the
  comment read "reserved — room to add rss/utime". Telemetry §4 (cpu time) and §5 (rss) both claim it.
  Whichever shipped first would have taken the whole u64 and forced the other to a new syscall number.
- **Split now as two u32 halves** — low @+56 = cpu ticks, high @+60 = rss pages — while the value is
  still 0 and nothing reads it. A u64 zero-check still means "neither present", so consumers written
  against the old wording keep working. That compatibility is why this is free today and an ABI break
  after the first reader. u32 is not a ceiling: 2^32 ticks @100 Hz is ~1.36 years; 2^32 pages is 16 TiB.

### Fixed — comments that would have sent the next author down a dead path

- **`hid.cyr:1016-1017` claimed `HID_CC_INJECT with ccode 6` reproduces an endpoint halt. It cannot.**
  The shipped inject block forces `ccode = 2` and calls it "NOT a halting code" (`:1177`), while the
  flag needs 4/6/8 (`:1189-1192`). Turning the flag on and seeing nothing is the EXPECTED result — but
  the comment made that read as "no stall occurred". The reachability claim rests on a hand-modified
  build the tree does not contain, and now says so.
- **`syscall.cyr`'s `statfs` comment** said FAT/exFAT were "filed as a follow-on rather than half-built"
  while both arms sat 20 lines beneath it. chakshu reports this nearly made it file a phantom gap —
  the cost of a stale comment stated exactly: not confusion, but work done twice in two repos.

### Changed — cyrius pin 6.5.41 -> 6.5.44, and the cross-repo loop closed TWICE inside one cut

- All **12** manifests plus sibling **klug** (37/37). ⭐ **Both peers filed here landed upstream the
  same day**: `#104 mountlist` in 6.5.43, then `#105 blkstats` **and** the stale `#61` field-range
  comment (`counter (4..7)` → `4..11`) in 6.5.44. `syscall ABI` reads
  `kernel 106 · abi-doc 106 · cyrius 106` — **32/0**.
- ⚠ It was **31/1 twice** during the cut and both reds were correct: the gate is designed to read
  `kernel N · abi-doc N · cyrius N-1` between minting and the peer landing. ⛔ Do not "fix" a future
  one by editing cyrius; file the issue in `cyrius/docs/development/issues/` and let it land.

- All **11** manifests (the root, nine `tests/*`, and the new `tests/mountlist`), plus sibling **klug**.
  `toolchain-pin-check.sh` 11/11. klug rebuilt and 37/37.

### Changed — issues/ reviewed against live code; one archived, three headers corrected

- ⛔ **Only ONE of five was archivable, and the two that LOOKED closest to done were the furthest.**
  The P1 backlog reads 23/26 closed and is **21** — two items were fixed at the line named in the
  finding's *title* but not at the sites the finding's own *Mechanism* paragraph enumerates. And the
  vacuous-gates file carried a corrected "39 fixed" header over its **unedited 273-line body**, which
  still describes all 33 findings as open. **Both would have archived cleanly on their own status
  text** — the failure that cost this repo eleven cuts on `#98` and four on `#97`.
- ✅ **Archived**: the crab mount-enumeration filing, resolved by #104, with its status rewritten first
  and what-it-broke recorded (the expected ABI-gate red). Archived count 50 → **51**.
- Headers corrected in place on all three that stay open. The HID record understated itself: not merely
  "#3 has never executed" but **no in-tree build can even set its flag**, and the 1.56.58 iron slot
  passed with no HID entry at all — so the gate is UNSLOTTED, not scheduled. Three residuals there are
  in-tree and none is the withdrawn stub seam; the sharpest is that the early-out is **silent**, so the
  roadmapped burn currently has **no oracle that can fail honestly**.
- The vacuous-gates header said "two fixes moved the vacuity up a level" and named **one**. The second
  (`scripts/probe/rbp-repro.sh`) is now named.
- **aarch64 counts corrected in four places**: 30 fns + 18 vars → **32 + 46**. The surface has GROWN.
  A count that only ever gets copied forward is the same rot class as a stale status header.


## [1.56.58] — 2026-09-02 — the kernel log gets a clock, and 39 gates that could not fail now can

### Added — a Linux-style uptime prefix on every kernel log line

- Every **kernel-origin** line now carries a fixed-width 15-byte field in `printk` shape —
  `[    4.123456] ` — built by `klog_build_prefix` (`core/kprint.cyr`): seconds right-aligned in 5
  columns space-padded, microseconds in 6 columns zero-padded. Emitted to **serial, framebuffer and
  the klug ring**, in the order `kprint` already used.
- ⛔⛔ **RING-3 OUTPUT IS NOT PREFIXED, AND THAT IS THE WHOLE DESIGN.** `kprint` is *also* the userland
  stdout/stderr path — fd 0/1/2 are `VFS_DEVICE` 0, so `write(1,…)` walks `vfs_write` -> `dev_write`
  -> `serial_dev_write` -> `kprint`. Decorating unconditionally would have stamped timestamps into
  `ls` output, into every pipe stage, and into ~330 harness assertions that parse program text.
  `serial_dev_write` raises `klog_raw_depth` around its whole chunk loop and those bytes pass through
  byte-exact. ⚠ **Around the loop, not inside it** — it chunks at 4096, so a per-chunk raise would
  re-decorate mid-stream every 4 KB, which is the same bug in a smaller disguise.
- ⚠ **`klog_at_bol` tracks EVERY byte, raw ring-3 bytes included.** Ring-3 output is 23.5% of the ring
  under a pty and 82.6% in a desktop session; if a program writes a partial line and a kernel line
  follows, we are not at column 0 and a prefix there would split the operator's visible line.
- ⚠ **`kputc` tracks the line position but never emits a prefix** — it carries the keystroke ECHO, so
  a prefix there would land inside the operator's own command line. Same reason the `fb_oob` live-line
  bracket already skips it.
- ⚠ **The fb copy of the prefix sits INSIDE the `fb_oob_begin`/`fb_oob_end` window.** Outside it,
  `fb_line_note` captures the prefix into `fb_line_buf` and `fb_oob_end` replays it as part of the
  operator's typed line — the exact corruption `harness/console-line-preserve-test.py` exists to catch.

### Added — a log timebase measured 4,400 statements earlier, for free

- ⭐ **`timer_ticks` was unusable and `tsc_calibrate()` was far too late.** `sti` is at
  `main.cyr:4532`, so a tick-derived clock reads `0.000000` for essentially the whole boot log — and
  `timer_ticks` additionally FREEZES inside a foreground `run`, because ring 3 executes with IF=0.
  `tsc_calibrate()` produces a good number but not until `main.cyr:4565`.
- `lapic_calibrate` (`arch/x86_64/apic.cyr`) **already** measures a known wall interval — 8
  free-running PIT ch0 periods, ~80 ms, needing no interrupts — at `main.cyr` ~line 128. Two `rdtsc`
  reads inside that existing window yield cycles-per-microsecond at **no added boot time**.
- ⚠ **Writes `klog_tsc_per_us`, NOT `tsc_per_us`, and the separation is load-bearing three ways:**
  `uptime_us`#95 is specified against `tsc_base` meaning "since CALIBRATION" (re-pointing it would
  silently change a shipped syscall); and `core/hda.cyr:323` and `core/gpu.cyr:280` **depend** on
  reading `tsc_per_us == 0` before `main.cyr` so they take their documented pre-calibration fallback —
  setting it early would silently retune GPU and audio delays.
- ⭐ **CROSS-CHECKED, AND THAT IS THE PROOF IT IS SOUND.** `tsc_calibrate()` now compares the early
  number against its own (50 ms of live ticks, interrupts on) and prints a verdict. Two independent
  methods, same physical quantity. **Measured on a real boot: early 3193, late 3193 — exact.** A
  refusal or a >12% disagreement prints a named warning instead of shipping a skewed divisor.
- ⛔ **`klog_tsc_boot` is captured as a STATEMENT, not a `var … = rdtsc()` initialiser.** In kmode
  `EMIT_GVAR_INITS` runs after `PARSE_PROG`, which is the boot sequence and never returns — so a
  non-foldable module-scope initialiser reads 0 forever with no diagnostic (two archived filings).
- ⛔ **`klog_uptime_us()` is a function with an aarch64 no-op twin**, because `core/kprint.cyr` is
  included at `agnos.cyr:57` — OUTSIDE both `#ifdef ARCH_X86_64` blocks — so it compiles on aarch64
  while `rdtsc`/`klog_tsc_*` are x86-only. Same seam `proc.cyr` uses. ⚠ The aarch64 twin returns 0 on
  purpose: that arch's `timer_read_freq`/`timer_read_count` store through `[sp,#0]` (frame padding)
  and return a constant 0 — an open P1. A stub that *looked* live would print fabricated timestamps.

### Changed — 110 anchored assertions made prefix-tolerant

- 110 `^`-anchored greps across 34 smoke scripts became `^\(\[[^]]*\] \)\{0,1\}` (BRE) /
  `^(\[[^]]*\] )?` (ERE). Anchoring is preserved — a mid-line occurrence still does not match — and
  the same pattern now matches both prefixed kernel lines and bare ring-3 lines, so no classification
  of which is which was needed.
- Verified by boot: `exec-smoke` **PASS** (16 transformed patterns), `ext2-write-smoke` **PASS**,
  `klug-spill-smoke` **7/7**, `agnsh-smoke` **3/3**.
- Binary **1,994,672 -> 1,997,536 B** (+2,864 for the whole feature); 99,616 B under the 2 MiB ceiling.

### Fixed — 39 gates that could not fail, across 30 files

- The tree-wide sweep of [`2026-09-02-vacuous-gates-sweep.md`](docs/development/issues/2026-09-02-vacuous-gates-sweep.md),
  one agent per file, each fix mutation-proven against its own empty-input case then adversarially
  re-verified. **39 fixed / 1 declined.** Six were found *while proving* the assigned ones
  (`modeset-latch-smoke.sh` had 4 more of the same shape, `check-carveout.sh` 3,
  `chan-semantics-check.sh` 2), which is why 33 findings produced 39 fixes.
- ⛔ **`ktest.sh` announced `ALL TESTS PASSED` on a suite that enumerated ZERO tests.** It parsed only
  the failure count, so `TOTAL: 0 passed, 0 failed` — what a mis-scoped `#ifdef TEST` produces — scored
  green. It now asserts an executed-check floor and prints the count: `110 checks executed (floor 64)`.
- ⛔ **`ext2-write-smoke.sh` never ran its seven metadata_csum assertions.** They were wrapped in an
  `if` fed by the kernel's own log line, and the smoke's DEFAULT mkfs profile disables checksums —
  with no `else`. The lane now declares itself: `SKIP: csum lane OFF — 0/7 checksum assertions ran`,
  with the exact command to prove them, and cross-checks the host image against the kernel's report.
- ⛔ **`check.sh` gate 22 ("call arity") passed whenever the build FAILED** — a dead build emits no
  arity warnings, so the negative assertion had nothing to match. Gate 32 then weighed whatever
  `build/agnos` fossil was on disk. Both now key off the captured build exit status.
- ⛔ **Two harnesses had no exit code at all** (`agnsh-type-test.py`, `agnsh-kvm-test.py`): a guest that
  triple-faulted printed `banner seen: False` and exited 0. `kriya-crash-probe.py` set `rc = 0`
  unconditionally three lines below its hang detector.
- ⚠ **Two fixes moved the vacuity up a level rather than removing it, and adversarial verification
  caught both** — recorded in the issue file, which STAYS OPEN. `.github/workflows/`, `scripts/burn/`
  and `tests/*/` were not swept; the count is a floor.

### Changed — cyrius pin 6.5.41; klug 0.1.6 in lockstep

- Nine `tests/*/cyrius.cyml` + the root manifest already moved to **6.5.41** at 1.56.57.
- Sibling **klug 0.1.6** ships beside this: pin 6.5.35 -> 6.5.41, and `klug_time_prefix_len` so the
  severity lens steps over the new uptime field. ⛔ **Without it the lens fails SILENTLY** — it tests
  `[` at byte 0 and `]` at byte 2, so under a prefix byte 0 still matches but byte 2 is a space, every
  line scores level 0, and `klug -w` prints nothing and exits 0. klug's tests **12 -> 37**, including
  `test_time_prefix_needs_all_four_anchors` (byte 0 alone false-positives on a real `[E]` line).
- ⚠ **klug 0.1.6 also stops `-w`/`-e` lying**: a production kernel emits ZERO leveled lines
  (`klug_info`/`warn`/`err` have three call sites, all inside `#ifdef EXEC_SELFTEST`), so the filters
  legitimately match nothing. It now says so on stderr rather than printing nothing and exiting 0.

### Docs

- `agnos-userland-abi.md` §4.5 corrected and extended: it said the klug ring was **16 KB** in three
  places (it is 64 KB, and has been since the ring was raised), and it described the leveled-tag
  contract as live when no production build emits one. Now carries the line format, the ring-3
  exemption, and the BRE/ERE anchors a consumer must use.


## [1.56.57] — 2026-09-01 — statfs answers on all three filesystems, and the mount root was refused on two of them

### Fixed — 22 (string, length) mismatches, in three emitter families the gate never looked at

- `scripts/check/kprint-len-check.sh` covered `kprint`/`kprintln`, `ea_expect`/`ea_expect_valid`
  and `serial_print`/`serial_println`. It now also covers **`klug_append`/`klug_info`/`klug_warn`/
  `klug_err`** and **`sh_exec`/`test_assert`/`test_assert_eq`**. Literals checked: **3,776 -> 4,084**.
- ⭐ **The gate's own header predicted this for the third time and was right for the third time.**
  It states that a length-checking gate must enumerate EVERY (string,length) API in the tree
  "because the ones it omits are exactly where the bug survives". The omitted families held **22**
  live mismatches; the covered ones held **0**.
- Fixed: `kernel/core/proc.cyr:1624` declared 15 for the 16-byte `" DESTROYED_LIVE\n"` (truncating
  its newline, so the next line ran on) — `ELF_PDE_PROBE` diagnostic, whose output is read with
  `run /bin/klug`, i.e. a length bug in the log you enabled the probe to read. Plus **21** in
  `kernel/user/test.cyr` (20) and `kernel/core/main.cyr` (1).
- ⚠ **Most were `declared == actual + 1`** — someone counting the NUL. That over-reads one byte and
  truncates nothing, so every one printed a plausible label. Three were the other direction and
  visibly truncated on every `ktest.sh` run: `fmt_hex_buf negative correc`,
  `getpid == proc_current`, `memfile create returns f`.
- ⛔ **`sh_exec` is not a printer**, which is why it earns its own regex rather than being waved off
  as cosmetic: `kernel/user/shell.cyr:501` computes `arglen = len - cmd_end`, so an over-long length
  lengthens the **argv string** handed to the exec path. `main.cyr:3586` declared 38 for 37 bytes.
- ⛔ **THE PATTERN HAD TO BE TAIL-ANCHORED, AND MEASURING THAT IS WHY IT IS.** The `(name, nlen)` pair
  is the last two arguments, and these calls routinely carry an earlier `(string, int)` pair that is
  NOT a length — `test_assert_eq(memchr("hello", 108, 5), 2, "memchr 'l' at 2", 15)`, where 108 is a
  character code. A non-greedy prefix (the shape `ea_expect` uses) produced **5 false positives and
  missed `test.cyr:403`**, whose line also carries a correct `memeq(&hbuf, "8000000000000000", 16)`.
- Gate mutation-proven on three axes: each family reddens on a reintroduced mismatch, the char-code
  trap stays quiet, and an empty file list now errors instead of reporting a green "0 mismatched".

### Fixed — klug's strongest oracle was comparing 1 line out of 83, and 0 would have scored PASS

- `scripts/smoke/klug-spill-smoke.sh` enumerated `grep -a "^klug: "` and required zero misses. A
  `KLUG_SPILL_SELFTEST` boot puts exactly **one** `klug: `-tagged line in the spill (`spill file
  ready`; `spilled N bytes` is printed *after* the snapshot). So the "independent oracle" compared
  **1 of 83 lines** — and at zero matches the while-loop emits nothing, `miss` is 0, and it scores
  PASS having compared nothing.
- ⚠ **The obvious widening is wrong, and measuring it is why the replacement has the shape it does.**
  "Every spill line appears in the serial capture" is FALSE BY DESIGN at the head: `klug_putc` is a
  pure `store8` path running from the first instruction while `serial_putc` no-ops until the UART is
  up. Measured on a live boot, spill line 1 (`fb: w=0x800 h=0x800 ...`) is in the ring and **not** on
  serial — 82 of 83 match, and an all-lines check would fail a correct kernel.
- The invariant that IS true, and is what now runs: find the first spill line that reached serial,
  and from there require every line to. Self-calibrating (no hardcoded pre-UART head count),
  compares **82** lines, and is **format-agnostic** — no anchor, so a prefixed log cannot empty it.
  Mutation-proven on 4 axes including a simulated `[    4.123456] ` prefix on both sides.

### Fixed — `klug -w` / `klug -e` reported "no warnings" on a kernel that has no lens at all (klug 0.1.5)

- ⛔ The agnos kernel's `klug_info`/`klug_warn`/`klug_err` have **three call sites and all three are
  inside `#ifdef EXEC_SELFTEST`** (`main.cyr:2737-2739`, guarded `2589-3038`), which is off in every
  production build. A real boot log therefore carries **zero** tagged lines, every line scores level
  0, and `klug -w` printed nothing and exited 0 — indistinguishable from "this box logged no
  warnings".
- Added `klug_has_level_tag` (sibling repo `klug`, `src/klug.cyr`), which answers a question
  `klug_level_of` structurally cannot: that fn returns level 0 for a real `[I] ` *and* for an
  untagged line, because both must appear in a bare dump. `klug_dump` now counts tagged lines and,
  when a filter ran against zero of them, says so on **stderr** — stdout stays byte-exact and the
  exit code stays 0, because this is a statement about the corpus, not a failed dump.
- Tests **12 -> 24**, including a deliberate regression pin: `[    4.123456] [W] low memory` asserts
  that a prepended field collapses the lens to level 0. The lens is a fixed-offset test (`[` at byte
  0, `]` at byte 2), so the uptime-prefix proposal disarms it — pinned now as a known, tested
  consequence rather than a surprise, and as a red test for whoever implements the prefix.
- ⚠ Not staged. `scripts/burn/stage-tools.sh` refuses to build sibling repos by design, so the
  rebuilt `build/klug_agnos` must be committed in the klug repo before staging. The klug manifest
  still pins cyrius **6.5.35**.

### Filed — 33 vacuous gates, tree-wide, unfixed

- [`docs/development/issues/2026-09-02-vacuous-gates-sweep.md`](docs/development/issues/2026-09-02-vacuous-gates-sweep.md).
  The sweep that found the two vacuous checks fixed above was run across `scripts/smoke/*.sh`,
  `check.sh`, `check/*.sh`, `harness/*.py`, `probe/*`, `tool/*` and `ktest.sh`; each finding was
  adversarially re-verified against source.
- ⛔ **`ktest.sh:170` is the sharpest**: it parses only the failure count, so a suite that enumerated
  **zero tests** prints `TOTAL: 0 passed, 0 failed` and the harness announces `ALL TESTS PASSED` and
  exits 0. All seven check bodies are `#ifdef TEST`-gated; the pass count is never compared to
  anything, and the script's own header records the known-good tally without reading it.
- ⛔ Three more scored CRITICAL: `ext2-write-smoke.sh:147` (seven metadata_csum assertions wrapped in
  an `if` the smoke's own default mkfs feature set makes false — no `else`, never run in the sweep),
  `exec-smoke.sh:235` (the `spawn_path #43` lane is gated on a string in the binary under test, which
  the sweep's build env does not produce), and two harnesses that have no exit code at all.
- Count is a **floor**: `.github/workflows/*.yml`, `scripts/burn/*` and `tests/*/` were not swept.

### Changed — cyrius pin 6.5.36 -> 6.5.41, across all 10 manifests

- Pin raised in the root `cyrius.cyml` and the nine `tests/*/cyrius.cyml`
  (`scripts/check/toolchain-pin-check.sh`: 10 manifests, all 6.5.41).
- ⛔ **The tree was RED before this and the cause was the manifest, not the source.**
  `cyriusly` was already on 6.5.41, so `build.sh`'s 1.56.51 pin-enforcement block hard-exited
  with `toolchain drift — cyrius.cyml pins 6.5.36 but the build would use 6.5.41`, taking
  `check.sh` gate `x86_64 build` down with it (31 passed / 1 failed).
- ⭐ **`build/agnos` is BYTE-IDENTICAL across the bump — sha256 `cc5d8a2e…`, 1,994,672 B both
  sides.** The pin has never been enforced at the `cycc` level (cyrius
  `issues/2026-08-22-versioned-wrapper-does-not-pin-cycc.md`, unlanded), so every artifact in
  this tree was already compiled by 6.5.41's cycc. This edit makes the manifest tell the truth;
  it does not change the compiler.
- Delta 6.5.37..6.5.41 carries no AGNOS-facing breakage: this tree declares `[deps] stdlib = []`
  and uses no `Result`, no payload-carrying enum variant and no `private`, so the lib-side work
  (hash seeding, `Result` allocator, `private` collisions, TLS slot leak) is unreachable from
  here. 6.5.40 is compiler-internal limits only. The one gain is 6.5.37's AGNOS syscall peers
  (`#96 fork`, `#102 lstat`, `#103 statfs`), which make `syscall-abi-check.sh` green against the
  pinned snapshot rather than only against the sibling checkout.
- ⚠ The "v6.5.36 enum Critical" named in cyrius's 6.5.41 entry is the `>= 2^62` constant
  corruption that shipped in 6.5.31–6.5.35 and was **fixed at** 6.5.36 — this tree was already
  past it and gains nothing there.
- Verified: `check.sh` **32 / 0**, `test.sh` (x86) **4 / 4**, `agnsh-smoke` **3 / 3** to the
  `[ASSIST] >` prompt, `klug-spill-smoke` **7 / 7** on a real gnoboot+OVMF boot,
  `ktest.sh` **107 / 3** — the three FAILs are pre-existing initrd checks, identical before and
  after the bump (isolated by rebuilding under the old pin with `AGNOS_ALLOW_PIN_DRIFT=1`).
- ⚠ Doc counts corrected in the same edit: `state.md` said **9** manifests (10), and CLAUDE.md
  said a **30**-gate `check.sh` / **30/30** (32).

### Withdrawn — the proposed HID gate was going to prove a stub, not the kernel

- ⛔⛔ **1.56.56 recorded that HID `#3` "needs a build-gated seam stubbing the three hardware calls" so a
  selftest could drive the real `hid_recover_halted`. That recommendation is WITHDRAWN** on an operator
  correction. Faking `xhci_ep_state`s verdict, Reset Endpoint and Set TR Dequeue in order to test the
  code that talks to the controller inverts this repo`s first rule — *only a boot verifies kernel
  correctness* — and would have produced exactly the thing three cuts of this arc have been removing: a
  gate that passes because the harness agrees with itself.
- ⭐ **THE PREMISE WAS ALSO WRONG. THE BUILD HOST *IS* THE IRON TARGET.** archaemenid carries two AMD
  Renoir/Cezanne xHCI controllers (`04:00.3`, `04:00.4`) — the exact silicon this code drives. The
  constraint was never "agnos has no hardware to stall"; it was that the 2026-08-30 burn happened not
  to stall. An endpoint halt is **provokable** on real USB (a device pulled mid-transfer, one that
  STALLs its interrupt-IN endpoint, a port reset under load), and provoking one is a burn procedure,
  not a kernel change.
- ⇒ Roadmapped as **1.56.58 item #1**: burn, provoke a halt, and assert not merely that the recovery
  line prints but that **input actually resumes** — which is the whole point of the 16-deep re-arm,
  since a 1-deep ring re-stalls at the next polling gap. ⚠ A stall that never comes is VOID, not a pass.
- ⚠ **Nothing about the 1.56.56 fix is in doubt** — it is correct code in a path that has not executed.
  What was wrong was the plan for proving it.

### Added — `statfs`#103 on FAT and exFAT

- `#103` shipped ext2-only at 1.56.56. All three backends answer it now, each filling the same §4.7
  record with its own allocation unit as `f_bsize` — an ext2 **block**, a FAT or exFAT **cluster** —
  so `f_blocks * f_bsize` is the volume size on all three.
- ⛔⛔ **NEITHER FAT NOR exFAT KEEPS A FREE COUNT, AND FAT`s HINT IS UNUSABLE BY agnos`s OWN DESIGN.**
  FAT32 has an FSInfo free-cluster hint at offset 0x1E8 — and `fat_fsinfo_mark_unknown` stamps it
  `0xFFFFFFFF` from **twelve** mutation sites. agnos declares that hint stale rather than maintaining
  it, so reading it back would be reading our own "unknown" marker and reporting it as a count. exFAT
  has no such field at all: allocation state lives only in the **allocation bitmap**. ⇒ Both scan. FAT
  walks the FAT counting raw `0` entries (one block read per FAT sector, via the existing one-sector
  cache); exFAT popcounts zero bits in the bitmap (one read per 512 B). Both return -1 on a read error
  rather than reporting a guess.
- ⭐ **THE FAT SCAN MUST READ RAW ENTRIES, AND THAT IS THE TRAP.** `fat_get_entry` is a chain-follow
  accessor: it maps every end-of-chain marker to `0` so a walker stops cleanly. Through it, a FREE
  cluster and THE LAST CLUSTER OF EVERY FILE are indistinguishable — counting zeros that way overstates
  free space by one cluster per file. Plausible, wrong in the flattering direction, and invisible
  without a host cross-check.
- ⚠ `f_bavail == f_bfree` on both — neither format has a reservation concept. Asserted as an equality,
  not left to coincidence.

### Fixed — `statfs("/")` was REFUSED on a root-mounted FAT, and the first gate was green over it

- ⛔ `fatfs_resolve_parent("/")` finds the slash at index 0, computes `leaf_len = 0`, and its own
  `if (fatfs_leaf_len < 1) { return 0 - 1; }` guard then bails — so the empty-leaf accept downstream
  was **unreachable for any leading-slash path**. `statfs("/")` failed on a root-mounted FAT, which is
  the normal configuration whenever ext2 is absent, and the likeliest path a capacity query ever takes.
  exFAT had the identical shape. Both now detect a path that is empty or all-slashes as the mount point
  **before** calling `resolve_parent`.
- ⭐ **THE FIRST VERSION OF THE GATE ASKED ONLY ABOUT `/mnt/fat`** — the one spelling that works, since
  a mount-relative remainder of length 0 takes `resolve_parent`s no-slash arm. It passed. The bug was
  found by an independent read of the code, not by the test written for it. The gate now asks about
  `/` and about a trailing slash as well; removing the fix turns both arms red by name.

### Verified — against independent oracles, not self-reports

- **FAT**: `bsize=1024 blocks=129023`, cross-checked against `fsck.fat -n -v` on a rebuilt copy of the
  same image — *"1024 bytes per cluster"*, *"129023 data clusters"*, bit-for-bit. The smoke also
  captures mtools `minfo`s `free clusters=` **on the pristine image before boot**, because agnos
  invalidates FSInfo during the run and a post-boot capture silently yields an empty string (measured).
  The kernel`s count must not EXCEED that baseline — which is precisely what the `fat_get_entry` trap
  would produce.
- **exFAT**: `bsize=512` against the harness`s `mkfs.exfat -c 512`; `blocks=133120` × 512 = the 68 MiB
  partition; free `133052 → 133046` after a 3000-byte write — **exactly 6 clusters** at 512 B each.
- ⚠ **exFAT has NO host free-count oracle** (`fsck.exfat -v` reports geometry only, unlike FAT`s
  `minfo` and ext2`s `debugfs`), so its gate rests on the in-kernel live arm. Stated in the smoke
  itself, because a reader comparing the three gates should know which is weakest and why.
- **Mutations, each caught by its own named arm**: inverting the exFAT bitmap polarity reports
  `free=68` and it rises to `74` after the write → `f_bfree did not drop after a write`; removing the
  FAT mount-root detection → `Wstatfs REFUSED the mount root /` plus the trailing-slash arm.


## [1.56.56] — 2026-08-31 — two syscalls shipped, a ruling found in the repo that owns it, and 7 open issues → 2

### Added — `AO_EXCL = 0x2000` on `open`#7

- With `AO_CREAT`, refuse a final component that already resolves. POSIX `O_EXCL`, completing the
  check-then-write pair `AO_NOFOLLOW` opened at 1.56.53. Consumer: **crab**`s copy/move overwrite guard,
  which on agnos was falling back to `AO_TRUNC` and destroying the destination.
- ⛔⛔ **THE POSITION OF THE CHECK IS THE FEATURE.** The arm sits ABOVE the `AO_TRUNC` one. Below it, an
  `AO_CREAT|AO_TRUNC|AO_EXCL` open — exactly what the consumer sends — would zero the file and *then*
  refuse it, destroying what the flag exists to protect. So the gate asserts the surviving SIZE, not
  just the refusal. **Measured**: moving the check below the truncate reports
  `ext2w: Wexcl TRUNC|EXCL TRUNCATED the file it refused`, plus a second arm.
- Five arms, because a flag that refused everything — or nothing — would satisfy a lesser test.
  FAT/exFAT answer it through `fatfs_create`/`exfat_create`s existing-name refusal, whose return is
  discarded *without* the flag because `touch <existing>` depends on that.
- ⚠ **Returns -1, not -17** — agnos has no `-errno`; the translation belongs in the cyrius wrapper.
- ⭐ **The filed bit was wrong and the reason generalises**: `0x400` is `AO_APPEND`, declared in the ABI
  and set at runtime by cyrius `lib/io.cyr` on every append-open. The kernel tests no `0x400`, so
  reading the kernel alone made it look free. **The kernel is canonical for the syscall NUMBER set but
  not for the FLAG set.**

### Added — `statfs`#103, volume capacity for a path

- `sys_statfs(path, pathlen, buf)` fills a 32-byte record (§4.7): `f_bsize`/`f_blocks`/`f_bfree`/
  `f_bavail`, u64 LE at 0/8/16/24. Path-based and mount-routed like `stat`#33. Consumer: **crab**`s M6
  sidebar, which had every widget it needed and no way to ask how big a filesystem is.
- ⭐ **The free count is LIVE** — read from the resident superblock the allocator maintains, not a
  mount-time snapshot. **Measured** on the gate`s own image (67 MiB, `-b 4096 -m 0`):
  `bsize=4096 blocks=17152 free=16042 avail=16042`, dropping to `16041` after a 23-byte write.
  `avail == free` because the image reserves nothing; `blocks` is 67 MiB / 4096 exactly.
- ⛔ **Two mutations, each caught by its own named arm**: total-as-free →
  `f_bfree did not drop after a write`; no path lookup → `answered for a NONEXISTENT path`. The second
  is the one that matters — an arm ignoring its path would answer the root volume and pass every check
  about the numbers themselves.
- ⚠ **ext2-only and it says so**: a non-ext2 mount returns -1, the posture `stat`#33 shipped with.
  FAT/exFAT can answer it, but that is a second backend and a second set of controls — filed, not
  half-built. ⚠ **The record size is frozen ABI**: 3-arg, no length parameter, so widening needs a new
  number. ⚠ `f_bavail` is clamped at zero — a filesystem can legitimately run below its reservation, and
  an unclamped subtraction hands ring 3 a negative that a progress bar renders as full.

### Fixed — both defects inside `hid_recover_halted`, and it ships UNGATED

- One change fixes both: it now bumps `hid_ep_rearm[i]` by **16** and lets `hid_service_rearms` do the
  ring work under `hid_poll_lock`, instead of arming inline.
  **(1) Depth** — it called `hid_row_arm(i)` once, arming a 1-deep ring, against the file`s own rule
  that *"a 1-deep interrupt-IN ring goes empty the moment polling pauses and the EP stalls"*: recovery
  recovered INTO the condition that produces halts. **(2) Locking** — it armed from thread context with
  interrupts enabled, which the reclaim banner forbids in the imperative. Taking the lock inline was
  rejected: it would be held across two `xhci_cmd_wait` spins in a path the 100 Hz tick also takes.
- ⛔⛔ **AND IT HAS NO GATE — SAYING SO IS THE POINT.** The body is behind an `XHCI_EP_STATE_HALTED`
  check that a software-fabricated completion code cannot satisfy, so none of it executes. The
  *mechanism* the fix now depends on IS covered (`hid-reclaim-smoke.sh`, in the sweep, passes).
  ⛔ The cheap gate was considered and **rejected as one that cannot fail**: extracting the arm and
  calling it from a selftest would gate the arithmetic but not the wiring — reverting to
  `hid_row_arm(i)` would leave it green. A real gate needs a build-gated seam stubbing the three
  hardware calls so a selftest can drive the real function.

### Corrected — 1.56.55 reported two `ring3-smoke` defects that do not exist

### Corrected — 1.56.55 reported two `ring3-smoke` defects that do not exist

- ⛔⛔ **BOTH WERE ONE HARNESS BUG WEARING TWO DISGUISES, AND THE 1.56.55 NOTES ARE WRONG ABOUT THEM.**
  That entry reads *"`ring3-smoke.sh` is not in `sweep.sh`, and two of its assertions are red … `ring3:
  gate held` fails deterministically on HEAD too … `ring3: yield OK` is a load-sensitive timing ratio
  that flakes on both trees."* The kernel is fine. `ring3-smoke.sh`s `qemu_dwell` was **40 s** and
  `RING3_SELFTEST` does not finish in 40 s, so the last three markers — `ring3: yield OK`,
  `ring3: gate held`, `ring3: done` — fell off the end of the captured log. `gate held` is the LAST
  assertion before `done`, so it never printed at all and looked deterministic; `yield OK` printed only
  when a boot happened to get that far, so it looked flaky.
- ⭐ **THE TELL WAS IN THE LOG THE WHOLE TIME.** `ring3: Y=54 A=38284` satisfies the `A > Y*10` ratio by
  70x, and the very next statement in `main.cyr` is the `yield OK` kprintln. ⇒ **A missing marker whose
  precondition is visible on the line above it is a truncated log, not a failed assertion.**
- ⛔ **AND THE CONTROL THAT LOOKED DECISIVE PROVED THE WRONG THING.** "It also fails on HEAD" was
  measured (`git stash push -- kernel/`, rebuild, run) and was TRUE — but the dwell was 40 s on HEAD
  too, so the control reproduced the harness bug rather than isolating a kernel one. Six QEMU boots
  went into a flake table for a defect that was not there. A baseline that shares the suspect
  condition is not a baseline.
- **Dwell raised to 120 s: 8/8 assertions pass and `ring3: done` prints.**

### Added — `ring3-smoke.sh` is a sweep gate

- It carries the **only** regression test for `proc_alloc_slot`s reuse scan (`ring3: nonlifo reuse OK`)
  — the code 1.56.55 changed to stop reusing an exited-but-unreaped child`s slot — plus the ring-3
  preempt gate and `sched_yield`#44 slice donation, and it was in **no** sweep row. The 1.56.55
  allocator change therefore had to be verified by hand. `sweep.sh` is now **26 gates, 25 passed /
  1 failed**; the single red is `check.sh`s syscall-ABI gate, which reports `#96 fork` and `#102 lstat`
  absent from cyrius and stays red by design until those peers land in that repo.

### Resolved — the shakti privilege ruling existed all along, in the repo where architecture is ruled

- ⛔⛔ **`issues/2026-06-16-shakti-privilege-model-kernel-gap.md` ASKED FOR A RULING THAT WAS MADE FIVE
  WEEKS BEFORE IT WAS FILED.** Every revision of that file said the ask was *"a RULING, NOT CODE"* and
  that none was recorded; the 2026-08-31 re-audit went further and asserted *"a full grep of `docs/`
  finds only restatements of the open question, never an answer."* **That grep covered agnos only.**
  This is a cross-repo architectural question and the answer lives in the **agnosticos** genesis repo:
  `docs/development/planning/identity-and-authorization-model.md` — *"Identity & Authorization Model —
  Recognition Over Interrogation"*, **2026-05-12**, against an issue filed **2026-06-16**.
- **The ruling answers both P0s "no", by commitment rather than by default.** Its rejection table names
  them: **"Account/uid as multi-user primitive"** → *"Permissions are fine-grained by capability
  (`kavach`, `t-ron`)"*, and **"Sudo-and-retype-password for privilege"** → *"Physical presence +
  capability token = intent verification"*. And: *"**Multi-user via avatara overlay, not via uid.** Same
  kernel process space, different identity contexts."*
  ⇒ agnos **does** grow an identity model covering **users and agents** both — `sigil` roots the user,
  `t-ron` gates the agent, `avatara` carries the overlay, `kavach` holds per-action capability — and it
  **does not** grow a per-process `uid`/`gid`. `getuid`#15 returning 0 is the decision, not a gap
  awaiting one; `planning/ipc.md`s *"No uid/gid anywhere"* and `proc.cyr`s guardrail are downstream of
  it, which earlier audits read as doctrine with no authority behind it.
- **shakti is N/A on agnos by architecture**, not merely unbuilt: it is uid-de-escalation, and that
  shape is explicitly rejected. 0.8.x re-scopes to Linux + aarch64 — the outcome the issue itself
  listed as legitimate. The `#75-80` aegis capability gate is unblocked with it; it rides on `kavach`.
- **Two kernel comments named the wrong successor and are corrected.** `syscall.cyr`s `#75-80` band
  said its `BLK_RW_ARM_MAGIC` placeholder awaits *"when agnos grows per-proc caps"*, and `power.cyr`s
  reboot gate said *"a uid check would be a gate that is always open"* as if provisionally. Both
  placeholders are correct and stay; their successor is a **kavach capability gate in userland**, not a
  kernel credential. Comment-only — no codegen change.
- ⛔ **THE METHOD ERROR IS THE POINT.** A cross-repo question was answered from one repo, and the
  negative result was recorded as fact in an issue header, a state.md rollup and a CHANGELOG entry. ⇒
  **Before writing "no decision exists", search the genesis repo.** agnos is not where AGNOS
  architecture is ruled.

### Changed — the issues folder: 7 open → 3 by archiving, then → 2 as the two syscalls above shipped

- ✅ **ARCHIVED, each with its Status header rewritten to a resolution note first**: `syscall-96-fork`,
  `open-ao-nofollow`, `tri-corner-bound-coordinate-frame`, and `shakti-privilege-model-kernel-gap`
  (see the section above). All three were **complete on the agnos side**
  at 1.56.55 and were being held open waiting on **cyrius** peers. ⛔ That was the wrong reason to keep
  a record open: agnos does not modify cyrius, and those asks are filed and tracked *in cyrius*, so an
  open agnos issue for them is another repo`s backlog double-counted in this one.
- ⛔ **TWO FINDINGS WERE WRITTEN UP AS NEW ISSUE FILES AND SHOULD NOT HAVE BEEN.** The `#92` ABI-table
  gap is fully characterised known work with nothing to investigate — it belongs in `roadmap.md`s OPEN
  table, and is now a row there. The `ring3-smoke` one described two defects that turned out not to
  exist (above). Both files removed. ⇒ **A finding is not automatically a file.** Fix it, or put it
  where the work is already tracked; an issues folder that grows on every audit stops being a list of
  what is wrong and becomes a list of what was noticed.
- **The 3 that remain**: HID `#3`s halted-endpoint recovery (needs a genuine hardware stall), the P-1
  backlog`s two-item aarch64 tail (the port does not compile), and `AO_EXCL` (unbuilt; its requested
  flag bit was corrected from `0x400` — which is `AO_APPEND` — to `0x2000` at 1.56.55). None is blocked
  on a decision; all three are blocked on hardware, a port, or unwritten code.

⚠ **No `kernel/` source changed in this cut.** The 1.56.55 release binary is unaffected; everything
here is harness, gate wiring and records.


## [1.56.55] — 2026-08-31 — fork was correct by accident three times over, and four gates could not fail

### Fixed — the `#92` corner-bound fix had no coverage on the op the ruling was about

- ⛔⛔ **1.56.55 corrected `gpo_validate_tri` (op `0x09`) to the rect-local frame and shipped it with a
  battery that could not tell.** Every op-0x09 record sat at `dstxy 0` — including the frame-skew case
  that same cut MOVED to the origin — except `tri: dst runs off the framebuffer`, which returns
  `GPO_E_DIM` ~90 lines before the corner loop. At `dx=dy=0` the screen and rect-local corner sets are
  identical by construction, so reverting the bound left the battery **green**. The only discriminating
  case was op `0x0A`s, which routes to `gpo_validate_trilist` and never to `gpo_validate_tri`: the
  unburned sibling had the test, the **burned** primary did not.
- **Two cases added (battery 175 → 177), and the mutation now fails by name**:
  `edge-abi: FAIL tri: a tiny triangle FAR from the origin clears the bound (rect-local) want 29 got 23`
  — `GPO_E_NOTIMPL` (bound accepted) against `GPO_E_FRAME` (old bound rejected). Derived, not tuned: a
  1 px triangle gives `a2 = 65536` (clears `GPU_TRI_AREA_MIN` at equality) and `lim = 67,108,864`; a
  64x64 rect at (1024, 900) puts `|E|` at 4.16M rect-local and 71.27M in screen coordinates. It needs
  **both** a tiny triangle and a far rect.
- ⚠ **Three load-bearing false comments swept**, all calling the vertex frame screen-space when the
  shader never receives an origin: `syscall.cyr:2725` (inside the corrected function) and the op
  `0x0A`/`0x0B` per-triangle record layouts at `:1650`/`:1684` — the normative text a ring-3 caller
  reads. Verified at source: `gpu_tri_prep` takes no `dx`/`dy`, `gpu_tri_dispatch` folds the origin
  into the destination address only, and `tri_rgba.s` bounds `px` by `s6 = w` and `py` by `s7 = h`.

### Known — filed, not fixed

> ⚠ **CORRECTED AT 1.56.56 — the second bullet below is WRONG and is left as tagged.** `ring3-smoke.sh`
> had no red assertions: its 40 s `qemu_dwell` truncated the selftest before its last three markers
> printed. `gate held` never printed at all (so it looked deterministic) and `yield OK` printed only
> when a boot got far enough (so it looked flaky) — on HEAD too, which is why the control agreed. At a
> 120 s dwell all 8 pass. The first bullet still stands, except that the `#92` gap is carried as a
> `roadmap.md` row rather than an issue file. See the 1.56.56 section.

- **The `#92` ABI table is nine ops and nine reason codes behind the kernel.** It documents ops
  `0x00`-`0x08` and reasons `1`-`20`; the kernel ships `0x00`-`0x10` and `1`-`29`, and
  `GPU_OP_SUPPORTED = 0x1FF5F` advertises all of them to ring 3 — including `0x09`, which is burned.
  The gap is now stated in the doc above the op table; the rows are not written, because deriving nine
  op contracts from `gpo_validate*` is its own piece of work. ⇒ The durable fix is a **gate** that
  diffs `GPU_OP_*` and `GPO_E_*` against the tables — `syscall-abi-check.sh` compares syscall NUMBERS
  and cannot see inside an op-dispatched one. Filed as
  `issues/2026-08-31-gpu-op-92-abi-table-nine-ops-behind.md`.
- **`ring3-smoke.sh` is not in `sweep.sh`, and two of its assertions are red.** It carries the only
  regression test for `proc_alloc_slot`s reuse scan — the code this cut changed — so that change was
  verified by hand. `ring3: gate held` fails **deterministically on HEAD too** (measured with the
  kernel changes stashed), and `ring3: yield OK` is a load-sensitive timing ratio that flakes on both
  trees (HEAD 2/3 pass, patched 1/3 — not meaningful at n=3). ⚠ A single baseline run would have
  supported the wrong conclusion, that the allocator change broke `sched_yield`; it did not. Adding a
  knowingly-red gate to the sweep on release eve is an operator call. Filed as
  `issues/2026-08-31-ring3-smoke-not-in-sweep-two-red-assertions.md`.

### Fixed — `fork`#96 was broken for every case with more than one child

- ⛔⛔ **TWO INDEPENDENT DEFECTS, AND THE SECOND ONE HID THE FIRST.** Adding a second forked child to
  `tests/fork/forker.cyr` — the only shape that actually exercises wait-any — turned up both:
  - **`proc_alloc_slot` reused an exited-but-UNREAPED child's slot.** agnos has no zombie state:
    `exit`#0 sets `state = 0` and deliberately does **not** reap, so the row survives for the parent's
    `waitpid`. That makes `state == 0` mean both *"free"* and *"waiting for its parent"*, and the scan
    reused either. Forking twice returned **the same pid twice** (`FORK-MULTI-P1 pid=3` /
    `FORK-MULTI-P2 pid=3`); child 2 was allocated straight over child 1's exit status before anyone
    collected it. ⭐ The function's own banner stated the premise fork invalidated: *"safe today
    because reuse only follows a reap done BY the reaper AFTER it captured the exit code"* — true while
    every child was reaped synchronously by its spawner, false the moment fork produced the first
    unreaped child. This is the allocator-side face of the rule the 1.44.15 multi-collapse revert
    established from the reap side: *"a proc's slot must persist until ITS OWN waitpid reaps it."*
  - **A reaped slot stayed its parent's child.** `proc_ppid` was cleared in exactly ONE place —
    `proc_alloc_slot`'s recycle scrub — which runs at slot REUSE, not at reap. A reaped **non-top**
    slot therefore kept `ppid == parent` + `state == 0`, verbatim the predicate wait-any scans for, so
    the next `waitpid(-1)` re-matched it, returned its stale code again, and never advanced to the
    parent's other children. Both `-2` (children live) and `-1` (no children) became unreachable.
- **The fixes.** `proc_ppid` is cleared on **both** reap doors (`proc_reap`, `proc_reap_child`) — the
  invariant is *"a reaped slot is nobody's child"*, and it has to hold on both or it returns through
  the other one, since agnsh reaps foreground jobs via `proc_reap` and is itself a wait-any caller.
  `proc_alloc_slot` then reuses a dead row only when it is reaped, orphaned, or its parent slot is
  gone. ⚠ **The orphan clause is load-bearing, not defensive**: nothing in agnos reaps an orphan (the
  table-full banner says so), so without it a zombie whose parent died unreaping would pin its slot
  until reboot and march a 16-slot table to full.
- ⭐ **MUTATION-TESTED ACROSS THREE KERNELS, AND PHASE 1 WAS GREEN IN ALL THREE** — which is exactly how
  both defects survived: neither fix → `FORK-MULTI-EARLY-NOCHILD` (pid 3 twice); alloc guard only →
  `FORK-MULTI-DUP` (pids 3 and 4, code 21 returned twice); both → **PASS**. ⛔ Note the masking: while
  slots were being handed out twice the phantom could not form, so fixing the phantom alone changes
  nothing observable. A first draft of the record predicted `DUP` for the unfixed kernel; the
  measurement said `EARLY-NOCHILD`, and the record was corrected from the log rather than the reverse.

### Fixed — four gates that could not fail, three of them green on nothing

- ⛔⛔ **`fork-smoke.sh` WAS MEASURING THE PREVIOUS COMMAND'S KERNEL.** It ran
  `mcopy … build/agnos ::boot/agnos` at line 64 and `FORK_SELFTEST=1 build.sh` at line 71 — so the ESP
  received whatever kernel happened to be lying around, and the FORK_SELFTEST kernel the smoke exists
  to boot was compiled *after* the disk it should have been written to. A standalone run on a tree
  whose `build/agnos` was a plain kernel reported **all five markers absent**. ⭐ **It read green
  because `sweep.sh` gives each smoke one retry**: attempt 1 failed while building the correct kernel,
  attempt 2 booted it and passed. The gate was passing on its own retry, not on its subject. Build now
  precedes image assembly — and `/bin/forker` is rebuilt too, which it never was, so an edit to
  `forker.cyr` silently did not reach the boot.
- ⛔ **`scripts/check/syscall-abi-check.sh` WAS BLIND TO `#96`.** It scans only `kernel/core/syscall.cyr`
  for the kernel number set, and fork dispatches from `arch/x86_64/syscall_hw.cyr` (the ring-3 entry
  stub, like `#44`/`#14`). So the kernel set excluded 96, the ABI doc had no `| 96 |` row, cyrius had no
  `SYS_FORK` — and **all three sources agreed by mutual absence** while a shipped, sweep-gated syscall
  was undocumented on both sides. The gate's own comment already said *"if the stub gains or loses a
  number, this is where to add it"*; the instruction was right and was simply not followed. Its
  `ENTRY_STUB_ONLY` map now carries `96`, and the check reads `kernel 103 · abi-doc 103 · cyrius 101`.
- ⛔ **`ext2-write-smoke.sh` NEVER ASSERTED THE `AO_NOFOLLOW` MARKER.** `ext2.cyr` prints
  `ext2w: Wlstat no-follow OK` / `... MISMATCH`, and the smoke asserted every other `ext2w:` marker but
  not that one — so the gate the 1.56.53 entry and the issue header both cite as proof of the flag was
  never an assertion, and a kernel ignoring the flag entirely would have scored a PASS. Added, with the
  MISMATCH arm grepped separately so *failing* and *absent* do not share a message.
- ⛔ **THIRTEEN SKIP GUARDS ACROSS SIX SMOKES SCORED AS PASSES.** `sweep.sh` scores a gate on exit
  status alone, and these guards `exit 0` when a prerequisite is missing — so *"this gate measured
  NOTHING"* rendered as a green tick, in five gates that are in the sweep table
  (`chan-ring3`, `userwin`, `net-csum`, `msc-short`, `hid-reclaim`, plus `dhcp-opt`). All now exit 1,
  per the doctrine `syscall-abi-check.sh` already states: *a check that quietly passes when it could
  not find one of its inputs is a false green.*

### Fixed — the ABI doc was three rows behind its own kernel

- **`| 96 | fork |` added** — a shipped, sweep-gated syscall had no row at all (see the blind gate above).
- **`#4 waitpid` rewritten.** It documented *"busy-waits until `state==0`"* and a two-valued return; it
  is neither. It is a **non-blocking three-valued poll** (`exit_code` / `-2` WOULD_BLOCK / `-1`), and
  `pid < 0` has been **wait-any** since 1.56.54. The row was never touched when that shipped.
- **`AO_NOFOLLOW = 0x1000` added to §3.3.** The flag shipped at 1.56.53 and reached no doc and no cyrius
  constant, so the one artifact ring-3 authors read stopped at `AO_DIRECTORY`. ⚠ Its cyrius peer is
  still owed and, unlike `#63`/`#70`/`#96`/`#102`, was never even filed.
- ⛔ **`AO_APPEND` (0x400) now carries its hazard.** It is declared in the ABI and in cyrius, **set at
  runtime today** (cyrius `lib/io.cyr` bridges `O_APPEND` → `0x400` on every append-open), and honoured
  by **no backend** — the ext2 path never tests the bit and the FAT/exFAT arm says *"AO_APPEND TODO"*.
  A 2026-08-31 request proposed minting `AO_EXCL` on `0x400` after reading the kernel, where nothing
  tests it; that would have turned every existing append-open into `EEXIST`. Corrected to `0x2000`.



### Fixed — `fork`#96 wrote the child's return value into `r11`

- 1.56.54 shipped fork **working by coincidence.** It wrote the child's `0` to `p+32`, which
  `struct Process`'s doc-comment labels `rax`. It is not. `sched.cyr` carries the invariant:
  *"REVERSED-LABEL SLOT MAP (load-bearing): the proc-slot caller-saved fields restore into the REVERSE
  of their labels … p+32→r11 … p+112→rax. So the rax=0 return value goes to p+112 (NOT p+32)."*
  The labels are right for the save side and for the symmetric timer round-trip, which is why nothing
  had noticed — they are wrong for any row written **by hand**, which is exactly what fork does. The
  child still read 0 only because the preceding `memset` zeroes `p+112` too.
  ⭐ **Found by mutation, not by reading.** Setting `p+32` to 99 left the child reading 0 and the gate
  green; setting `p+112` to 99 makes the child read 99 and the gate fail. The tell was a passing test
  that could not fail — which is why the gate was held out of `sweep.sh` until this was answered.
  ⇒ `fork-smoke.sh` is now in the sweep, and the cyrius `SYS_FORK`#96 peer is filed.

### Fixed — the `#92` corner bound was evaluated in the wrong coordinate frame

- Both `gpo_validate_tri` (op 0x09) and `gpo_validate_trilist` (op 0x0A) evaluated the frame-skew bound
  at **screen**-coordinate rect corners `(dx, dy)`, while the shader samples **rect-local** ones —
  `tri_rgba.s` computes `px = tgid_x*64 + lane` bounded by `s6 = w`, and `gpu_tri_prep` takes no
  `dx`/`dy` at all. So the bound measured `|E|` over points the hardware never visits and not over the
  ones it does: it could reject a record the GPU would render, and admit one that overflows.
  ⚠ **op 0x09 is shipped and burned**, so this changes what a burned op accepts. Taken on an explicit
  ruling, not folded in silently by the cut that found it.

- ⛔ **The battery could not see the fix, twice, and both misses are the interesting part.** The two
  existing frame-skew cases produced their skew from **distance** — the exact quantity the corrected
  bound ignores — so they stopped tripping and had to be re-derived from arithmetic rather than tuned:
  a 1 px triangle gives `lim = 65536 * 1024 = 67,108,864` and `|E|` at the far corner is about
  `(w-1)<<16`, so the bound trips for `w >= 1026` (both now use 1088x512 at the origin). Then **every**
  case sat at the origin, where the two frames coincide — and reverting the bound to `dx`/`dy` left the
  battery **green**. A new case supplies the discrimination: a tiny triangle under a 64x64 rect at
  `(1024, 900)`, accepted rect-locally (`|E|` ≈ 4.1M) and rejected in screen coordinates (≈ 71.2M).
  ⚠ It needs **both** a small triangle and a far rect — the 64 px fixture triangle makes `lim` about
  1000x larger than either corner value and proves nothing. Battery **174 → 175**.


## [1.56.54] — 2026-08-30 — the issues folder swept: 17 open → 6, and what archiving would have buried

### Added — `waitpid`#4 wait-any, `proc_dup_address_space`, and `fork`#96 (PARTIAL)

- **`waitpid`#4 gained wait-any (`arg1 < 0`)** — the prerequisite the fork issue named. Scans for a
  dead child of the caller, reaps the lowest such pid and returns its exit code; **-2** while children
  live, **-1** when there are none. ⚠ That split is the whole contract: collapsing them would make
  *"all my children are still running"* indistinguishable from *"I have none"*, and a
  fork-per-connection server would leave its accept loop the first time no child had finished.

- **`proc_dup_address_space`** — full copy of PD[1..510] plus the high-arena PDPT[128..511] PDs.
  ⛔ Full copy, **not** copy-on-write, and that is a decision: CoW needs a write-fault unshare path,
  and agnos's `#PF` handler routes CPL3 faults to `fault_kill_current` and CPL0 to a halt — a CoW page
  would present as a killed process. It reuses `proc_map_page`/`_nx`/`_hi` rather than writing PDEs by
  hand, so the `0x87` bits, NX bit 63 and the KPTI entry-511 stash stay in one place. ⚠ PD[511] is the
  user-CR3 stash, not a mapping — copying it would point the child's KPTI user CR3 at the parent's PML4.

- **`fork`#96 — the hard part is built and MEASURED.** Dispatched from `syscall_handler`, **not**
  `ksyscall`, for the same reason `#44`/`#14` are: the child's resume context comes from
  `pcpu_sc_entry_regs`, which the entry stub fills and which is valid only on a path reached from the
  ring-3 stub. ⭐ **A first draft added two new per-CPU cells and two stores to the hand-assembled
  SYSCALL stub before finding that `sched_yield`#44 already captures exactly this set** — rcx (user
  RIP), r11 (RFLAGS) and rbx/rbp/r12-r15. All of that was reverted; no stub change was needed.
  ⭐ **Proven in QEMU** by a new ring-3 program `/bin/forker`: `FORK-CHILD` and `FORK-CHILD-OK` both
  print — a second process resumes at the parent's post-SYSCALL RIP with `rax == 0`, sees the parent's
  pre-fork stack value, and writes its **own** copy — and `FORK-PARENT` prints, so the parent survives
  with a positive pid.
  ⚠ **PARTIAL: `FORK-PARENT-OK` does not print.** The parent's `waitpid(-1)` loop times out and never
  observes the exited child. `exit`#0 sets state 0 without reaping, so the child should be findable;
  the failure is in the parent/child handoff, not in the copy or the resume.
  ⛔ **The harness question is the real one, because agnos has almost nowhere a forked child can run.**
  Two shapes were tried and both are structurally wrong — as properties of this kernel, not of `#96`:
  foreground `exec_and_wait` runs its child **IF=0** (*"their no-context-switch model is
  load-bearing"*), and the boot thread cannot safely be switched away from (*"restoring it would
  time-travel kmain"*). ⇒ The one context where a forked child can be scheduled alongside its parent
  is a proc spawned from agnsh via `spawn_path`#43 after boot — which is also the shape agora runs in.
  ⚠ `scripts/smoke/fork-smoke.sh` is **deliberately not wired into `sweep.sh`** while it is red on that
  last marker, and the cyrius `SYS_FORK` peer is **not** filed — the issue's own rule is *"do not mint
  the number before the kernel arm exists"*, and it does not fully yet.

### Fixed — the SYSCALL stub emitter had no bound check at all

- `syscall_stub_build` writes into `syscall_entry_buf`, which is `var …[256]` at module scope =
  **2048 bytes**, and `eoff` was never compared against it anywhere. Every byte past the end would
  land in whatever `.bss` follows — silently, on the one path every syscall in the system runs
  through, presenting as an unrelated global going wrong long after boot. It has never overflowed;
  nothing said so. Now bounded, and the size is **printed**: `syscall: stub 258 bytes of 2048`.
  ⚠ Measured because this cut nearly grew the stub by 16 bytes, and the buffer's own comment records
  an earlier enlargement for IBRS — growth here has a history of finding a ceiling nobody watches.

⚠ **The syscall-ABI gate cannot see `#96` (or `#44`).** It scans for `if (num == N)` in `ksyscall`,
and both dispatch from `syscall_handler` instead — so neither appears in its kernel number set, and
`#44` has been invisible to it since the gate was written. Not fixed here; recorded so the next ABI
change does not trust a green gate over the dispatch chain.

### Fixed — the pipe contract change of 1.56.39–40 was never swept into its callers

*ipc bites 10/11* made pipes streaming: the ring short-writes at `PIPE_RING` = 4080 instead of
wrapping-and-overwriting, and an empty ring returns **-2 WOULD_BLOCK** while any writer is open,
returning **0** only once every writer has closed. That split is what lets a reader tell *"nothing
yet"* from *"end of stream"*. **Nothing that depended on the old contracts was updated**, and the
record looked like a clean ship — archiving it in that state was the thing to avoid.

- **`BOTE_SELFTEST` could hang the boot.** Its own header says bote is run *"to EOF (empty stdin pipe
  → read 0)"*, and `wfd_in` is written and **never closed** — it lives in proc 0's table, so
  `pipe_writers_open` finds it and bote's terminating read gets `-2`, not `0`. Under
  run-to-completion `exec_and_wait` a bote that retries on `-2` does not fail the gate, it **hangs**.
  Now closed before the exec, which is what the contract requires — agnoshi's own pipeline already
  does the same `sys_close(wfd)` between its two `#43` spawns, and `pipe_read`'s header calls that
  close mandatory.
  ⚠ **Reasoned, not measured**: `bote-mcp-smoke.sh` needs `../bote/build/bote-agnos`, which is not
  built in this tree, so the gate could not be run to confirm. The kernel-side contract is unambiguous
  either way.

- **Four published ABI rows still described the pre-bites kernel.** `read`#5 said `bytes / -1` with no
  mention of `-2` — on the one fd type that now returns it — four cuts after the kernel changed;
  `write`#1 documented no short-write, so a caller writing `len` and assuming `len` was taken
  **silently loses the tail**; `pipe`#25 said nothing about the ring, WOULD_BLOCK or the mandatory
  close. ⛔ Worst, `exec_redirect`#62 asserted *"a save/swap/restore of the **global** `vfs_table`
  entry"* and, in bold, *"**NOT applied to the non-blocking `spawn`#3**"* — **both false since
  1.56.39**: fd tables are per-process, `#37` resolves the child's table, and `spawn_redirect_apply`
  applies the redirect to `spawn_path`#43. This is the contract agnoshi, bote and cyrius are authored
  against.

### Changed — the issues folder, swept end to end

**17 open → 6.** Eleven were resolved records whose *headers* had gone stale, which is the failure
mode here rather than missing files: `#98 ptrscan` still read **"DESIGNED, UNBUILT"** eleven cuts
after it shipped; `#97 chan_op` read **"bites 0-7 done"** four cuts after bite 11 landed. Each got its
Status rewritten with a resolution note *before* being moved to `archived/`.

⛔ **Every "already fixed" verdict was adversarially refuted before being acted on, and the refutations
earned their keep three times** — the pipes record above, the `#99` guarantee that was false (fixed
1.56.53), and the `mmap` low-arena rollback (fixed 1.56.53). A clean-looking ship is exactly when to
check what it broke.

**The six that remain, and what each is actually waiting on:**

| issue | waiting on |
|---|---|
| `shakti-privilege-model-kernel-gap` | **an operator ruling**, not code — does agnos ever grow a privilege model? The repo's own doctrine (`ipc.md` §Identity: *"No uid/gid anywhere"*) leans toward declining, but doctrine is not an answer to a sibling repo. Either answer unblocks shakti; silence does not. The `#75-80` band's aegis capability gate depends on the same ruling. |
| `syscall-96-fork` | slotting. Reserved and unbuilt; `waitpid` wait-any must land first (it forces the `proc_ppid[16]` array fork also needs). LARGE. |
| `hid-drain-rearm-and-isr-console-lock` | **a genuine hardware stall.** ⚠ 1.56.52 *changed* that code, so what a future stall exercises is no longer what was reviewed there; the 2026-08-30 burn ran a real keyboard for a whole session without stalling. |
| `open-ao-nofollow-flag` | `AO_EXCL` only — `AO_NOFOLLOW` shipped 1.56.53. |
| `p1-audit-sweep-backlog` | **now a two-item aarch64 tail**, and the second item is *why* `--aarch64` does not compile. The aarch64 arc is the thing to slot, not this file. |
| `tri-corner-bound-coordinate-frame` | **an operator ruling** — op 0x09 is shipped **and burned**, so changing what its validator accepts is an ABI-semantics change to a burned op. |

⚠ **`CLAUDE.md` said `archive/`; the directory is `archived/`.** Corrected, along with the two rules
this sweep paid for: rewrite the Status header before moving a file, and check what the shipped change
*broke* before archiving it.


## [1.56.53] — 2026-08-30 — cycle OPEN: staged for the seven-cut iron validation burn

### Verified — the seven-cut span is on iron, and the chain holds

`#tracker-iron-v1` burned 2026-08-30 on archaemenid (62 GB, 2560x1440 boot_info surface). Capture:
`agnosticos/basictests.txt`. All three subjects confirmed in one boot:

```
AGNOS kernel v1.56.53                                  <- kernel
tss: I/O map base at 0x66 OK - no ring-3 port access   <- 1.56.52, first iron run
tss: #DF has IST1 on the direct map OK                 <- 1.56.52, first iron run
kybernet: starting init / 5 processes / exec /bin/agnsh <- kybernet (in-kernel PID 1)
agnoshi 1.9.10                                         <- agnoshi, in ring 3
[ASSIST] >
```

⭐ **The network changes survived real traffic**, which QEMU's SLIRP cannot prove: `whirl
https://google.com` returned Google's 301 and `dig` resolved through 192.168.1.1 in 20 ms — so the
IPv4 fragment reject, the ICMP/TCP destination gates and the DHCP option-length rule did not break a
real lease, a real resolver, or a real TCP connection. `aethersafha` ran 100 frames.
⚠ **No `fb: scanout match REFUSED`** — the 1.56.52 extent bound did not decline the override on the
quiet-boot path, which was this cut's one new diagnostic and the burn's highest-risk watch item.
⚠ A hexdump disproved a suspected input defect: garbled command lines in the capture are `08 20 08`
backspace-space-backspace erase sequences — the operator correcting typos. Echo and backspace are
correct on iron.

### Fixed — `lstat`#102, minted off the burn

- **Two root-filesystem entries could be listed but neither stat'd nor removed.** `/sl_s` (a slow
  symlink whose 70-byte target does not exist) and `/lp` (a deliberate self-referential ELOOP link)
  are leftover `EXT2_WRITE_SELFTEST` fixtures the bare burn kernel never cleans up; every `ls` and
  every `rm` printed `operation not permitted`, five times in one capture.
  ⭐ **`unlink`#30 was never the problem** — it resolves the parent and calls
  `ext2_unlink(parent, basename)`, which refuses only directories, and the selftest's own cleanup
  removes both happily. What failed is that kriya's `rm` is written to **never** follow a symlink and
  classifies every operand with `fs_lstat_at` first, which on agnos routed to path-based `stat`#33 and
  followed the link into nothing. kriya's own source names it: *"agnos has no lstat peer at all …
  agnos roadmap carries `lstat` as unslotted-pending-a-consumer; **this is that consumer**."*
  ⇒ A correct no-follow userland could not be correct on agnos.
  ⛔ **A new number, not a flag on #33**: a 4th argument rides `ksyscall_a4` = **r10**, which the entry
  stub sets from whatever r10 held at the call — **garbage** for every existing 3-argument caller, not
  0. Same measured fact #100 and #101 both cite.
  ⚠ **Two-sided**: needs the cyrius `sys_lstat`#102 peer before ring 3 can call it by name, so
  `check.sh`'s syscall-ABI gate reads `kernel 102 · abi-doc 102 · cyrius 101` and is the tree's one
  red gate — exactly how `symlink`#63 and `readlink`#70 shipped. Filed as
  [cyrius `issues/2026-08-30-agnos-sys-lstat-102-peer.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-08-30-agnos-sys-lstat-102-peer.md) — ⚠ filed in the **cyrius** repo, which agnos never modifies.

- **`AO_NOFOLLOW` (0x1000) on `open`(7)** — the filed hardening ask. `open` had no way to write a file
  without following a link at the final component, and no `AO_EXCL` either, so neither standard way to
  make a check-then-write safe existed. The lookup mode already existed; this plumbs the flag that
  selects it. Additive — no existing caller sets the bit.
  ⭐ Both gated by `ext2w: Wlstat no-follow OK`, six arms, which reproduces the **exact iron
  condition** (dangling target, ELOOP loop) plus three controls: a resolvable link must give *different*
  inodes to `stat` and `lstat`, a plain file must give the *same* through both, and `AO_NOFOLLOW` must
  still open a plain file. Mutation-tested both ways — making `lstat` follow reports *"lstat FAILED on
  a dangling link — the iron bug"* by name.

### Fixed — a published `#99` guarantee that was false, and its fix was dead code

- **`proc_names` was the one member of the per-slot family missing from the recycle scrub.**
  `#99 proclist`'s contract — in its record *and* in the published ABI — reads *"the name field is
  NUL-padded to the full 32 bytes **so ring 3 can never read a stale byte left by a previous occupant
  of the slot**"*. That is a slot-**recycle** guarantee, a pid **is** a slot index here, and
  `proc_alloc_slot` reuses the first dead slot. Every other per-slot shadow is reset there — signals,
  sigmask, rsp0, on_cpu, idle_owner, ppid, epoch, the FPU area — each with a comment saying why a
  recycled slot must not inherit it. `proc_names` arrived at 1.56.47 and never joined the pattern, so
  a fresh process could report the **dead** one's name to ring 3.
  ⛔ **And the fix had already been written and never called.** `proc_clear_name` sits twenty lines
  above with the comment *"Clear a slot's name when it is reused, so a dead process's name can never be
  read back against a live pid that happens to land on the same slot"* — and `cyrius build` listed it
  as **dead code**. A guarantee, a function written to provide it, and no edge between them.

### Fixed — `munmap` could rewind the global arena cursor past a span it never mapped

- The LIFO rollback was gated on **VA arithmetic alone** — `addr + len == mmap_next_vaddr` — against a
  cursor global to every process, with no check that the caller owns or has ever mapped the span, and
  it ran whether or not the loop above unmapped a single page. A process that has never called `mmap`
  has nothing present in the low arena (`proc_create_address_space` zeroes `PD[128..510]`), so its
  `munmap` frees nothing, skips every page, and falls straight into the rollback.
  ⚠ Across processes that is harmless (separate CR3s). **Within one it is not**: rewind, then `mmap`
  twice, and `proc_map_page_nx`'s blind `store64` overwrites the first mapping's PDE — its physical
  pages become unreachable from any PDE, so `proc_free_address_space`'s present+user sweep cannot
  reclaim them either. Leaked until reboot, 2 MB at a time, ring-3 reachable with two integers.
  Now gated on `freed == npages`: the honest test of the property the rollback assumes.

### Fixed — two ktest gates that could not pass, both on record as "unexplained"

`ktest.sh` **97 passed / 6 failed → 107 passed / 3 failed.** `state.md` called those six
"pre-existing" and "Unexplained". Two were neither — they asserted contracts the tree had changed:

- **`empty pipe read = 0`** was correct until the streaming-pipe work (*ipc bites 10/11*, 1.56.39–40)
  made an empty pipe return **-2 WOULD_BLOCK** while any writer is open, and 0 only once every writer
  has closed. The test's own `wfd` is open on the next line, so it could never again read 0. It now
  asserts **both** halves — and the EOF arm matters: without it, a pipe that *always* returned -2 would
  pass, and a reader would spin instead of terminating.
- **`set page 4096 rejected`** asserted a 4096-page bitmap. `pmm_bitmap` is 8 KB = **65536** pages, and
  `pmm_migrate_bitmap` grows it to full RAM on a big box, so setting page 4096 is legal. The bound is
  now **derived from `pmm_bitmap_pages`** rather than written down, so it follows the allocator instead
  of going stale again.
- ⚠ The remaining **3 are environmental, not defects**: all three are `[initrd]` tests, and gnoboot
  passes no initramfs — the iron boot log reads `boot_info: initramfs=0x0 sz=0x0`. They cannot pass in
  this harness and should be recorded that way rather than as failures.

### Added — one diagnostic, so a burn cannot come back ambiguous

- **`gpu_scanout_matchgeom` now says when it DECLINES the override.** 1.56.52 bounded it by the real
  framebuffer extent (`fb_size_or_fallback()`), and a declined override is otherwise indistinguishable
  on iron from "the viewport already matched" — while the visible symptom, a banded or wrong-geometry
  console, would get attributed to anything but a bound added the cut before. Two refusal reasons print
  distinctly: extent unknown, and register geometry exceeding the real framebuffer. Serial-only cost.
  ⚠ This is the archaemenid quiet-boot path specifically (a 2560x1440 `boot_info` surface against the
  firmware's true 800x600), which is why it is worth a line rather than a comment.

### Fixed — the burn-prep staleness gate covered 4 of the 18 tools it iterates

- **`burn-prep.sh`'s stale-staged-tool check set `_src` for only `aethersafha`, `puka`, `crab` and
  `agnsh`.** The loop walks eighteen; the other fourteen fell through the `case` with `_src` empty and
  skipped the `cmp` entirely, so they were checked for **presence** and never for **staleness**.
  ⇒ Measured the day it was found: `kriya` was stale by **27,688 bytes** and the prep printed nothing —
  on a burn whose subject is agnoshi, whose file built-ins (`cp mv rm ls mkdir rmdir touch echo wc find
  grep`) are **all symlinks to kriya**. `crab` was stale by 12,632 and `whirl` by 16.
  ⛔ This is verbatim the failure the comment fifteen lines above it already describes — *"the gate
  existed, verified the tools it knew about, and did not know about the one the burn was for"* — written
  about `gputex`, while twelve rows including `gputex`'s own siblings sat uncovered below it. Every one
  had a resolvable `<repo>/build/<name>_agnos`; the list was short because nobody extended it.

### Fixed — the sweep's `#92` battery assertion drifted from the count it asserts

- The battery's case count lives in **two** places — the kernel's `of N cases correct` literal and the
  smoke's `chk` pattern — and the 173 → 174 move updated the literal and the smoke's *prose* but not the
  **pattern**, so the gate failed against a kernel that was right. Both now read 174. ⚠ The failure is
  loud (the gate goes red), which is the only reason a two-place count is tolerable here.

### Changed — the iron baseline in `state.md` was wrong by two cuts

- That row read *"1.56.44 … nothing from 1.56.45-1.56.51 has been on iron"*. The iron log records
  **1.56.46 `6c557484…` flashed 2026-08-19** (`#tracker-desktop-b3`), and every tracker after it says
  "kernel unchanged" — which is exactly how the rollup drifted, since b4–b9 were tool-side only.
  **The machine has been running 1.56.46 for eleven days.**
  ⚠ A wrong baseline here mis-aims a bisect: a regression found on the next burn would have been
  attributed to work that has in fact been running on that machine since the 19th.
  ⇒ The genuinely unburned span is **1.56.47 → 1.56.53** (seven cuts), plus **agnoshi 1.8.9 → 1.9.10**
  (eleven cuts). Staged as [`#tracker-iron-v1`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/iron-nuc-zen-log.md).


## [1.56.52] — 2026-08-29 — the audit backlog's two P0s, and a ring-3 port-I/O hole nobody had filed

### Security — ring 3 could reach the platform through the TSS

- **`tss_init_cpu` wrote the I/O-map base to TSS offset 100 instead of 102** (`kernel/arch/x86_64/gdt.cyr`).
  Offset `0x64` is the reserved u16; `0x66` is `I/O map base address`. The intended 104 therefore landed
  in the reserved field and the real base stayed **0** from the zeroing loop. Per SDM Vol 3 §19.5.2 a
  bitmap is absent only when the base is `>=` the TSS limit — the descriptor sets limit 103, so `0 < 103`
  meant the CPU believed an I/O permission bitmap started at `TSS+0`. Ring 3 runs IOPL=0, so CPL 3 > IOPL
  and the bitmap **is** consulted on every `IN`/`OUT`: for port N the CPU reads `TSS + base + (N>>3)`, and
  a **zero bit means allowed**. TSS bytes 0..103 are almost entirely zero, so ports `0x000-0x33F` were
  open to ring 3 — including `0x64` (`out 0x64, 0xFE` pulses the CPU reset line), `0x70`/`0x71` (CMOS and
  the NMI mask), the 8259 masks and the PIT. Ports `>= 0x340` read past the limit and correctly `#GP`,
  which is why COM1 at `0x3F8` still faulted: a **silent partial** failure, and the reason this survived
  twelve subsystem auditors. It is not in the 1.56.51 backlog at all.
  ⚠ No userland regressed — nothing in agnoshi/kriya/agnova/ark or `tests/` executes `IN`/`OUT`.
  ⭐ A boot gate now asserts the field placement (`tss: I/O map base at 0x66 OK`), because an offset typo
  in a hardware structure has no signal of its own. Mutation-tested: the old offset reports `MISPLACED`.

### Security — four ring-0 stack overflows in the in-kernel shell, one of them remote

- **A function-local `var x[N]` is N BYTES; the N-u64 rule is MODULE scope only** — and four buffers in
  `kernel/user/shell.cyr` were sized as if the module rule applied, while being passed the larger length:

  | site | declared | written by | overflow |
  |---|---|---|---|
  | `cat` | `cbuf[64]` | `vfs_read(fd, &cbuf, 512)` | 448 B on any file ≥ 64 B |
  | `recv` | `rbuf[64]` | `net_recv_udp(&rbuf, 512)` | 448 B, **remotely triggered** |
  | pipe test | `pbuf[16]` | `vfs_read(rfd, &pbuf, 128)` | 112 B |
  | block dump | `rbuf[64]` | `blk_read(sector, &rbuf)` | 448 B at 512 B/LBA, **4032 B at 4096** |

  All four are ring-0 stack in the in-kernel emergency shell. The `recv` one is driven end-to-end by an
  attacker: send one oversized UDP datagram, wait for the operator to run `recv`.
  ⛔ **The block-dump one has no literal length at the call site at all** — `blk_read` writes one whole
  LBA, and the LBA size is the *device's*. It is 4096 on a 4K-LBA NVMe, a size the block layer began
  honouring in this same cut, so the 4032-byte case is live rather than hypothetical. The hexdump below
  it only *reads* 64 bytes, which is what kept it invisible.

- ⛔⛔ **1.56.51 REASONED FROM A FALSE COMMENT ABOUT THE `recv` BUFFER AND FIXED THE SMALLER HALF.** Its
  note in `net_ingress.cyr` quoted the site as `var rbuf[64];  # 64 u64 slots = 512 bytes` — the module
  rule applied to a function-local declaration. The over-READ it closed (returning the untruncated
  datagram length, disclosing up to 504 bytes of kernel stack including the canary) was real and the fix
  stands. But because the buffer was believed to be 512 bytes, the over-WRITE underneath it could not be
  seen. Comment corrected at the site so the next reader inherits the right rule.

- ⚠ **Established by measurement, not by reading the compiler.** Under the pinned toolchain, writing 512
  bytes into a function-local `var a[64]` SIGSEGVs while 64 and 65 do not. That check was worth running:
  `main.cyr` already records the sizing being **non-uniform** at module scope (`var fpctxsw_payload[24]`
  measured 24 bytes while a sibling `var fpu_state[1026]` measured 8208), with the standing advice to
  "verify by `&next-&this` and OVER-size" — so neither rule can be applied from memory.

### Security — P0: `sys_munmap` could free live kernel memory

- **`length` had no ingress cap and every comparison is signed** (`kernel/core/proc.cyr`).
  `length = 0x7FFFFFFFFFD00000` rounds to a positive `len`; `addr + len` then wraps **negative**, so the
  signed `(addr + len) > 0x40000000` ceiling test passes. `npages` becomes 4,398,046,511,103 and
  `pd_idx = (vaddr >> 21) & 0x1FF` simply **cycles**, walking out of the arena into the kernel identity
  window. Because the free site tested only the *present* bit and never the *user* bit,
  `pmm_free_2mb` marked physical **2–256 MB free while live** — the SYSCALL kstack, the boot TSS RSP0
  seeds, the direct-map PD pages — after which `pmm_alloc` hands those frames to the next caller. The
  loop then spins ~4.4e12 more iterations with IF=0, so the box wedges too. Two integers through
  syscall 28, no privilege, no crafted input.
  Fixed four ways: a negative-length reject, a 64 GB cap mirroring `sys_mmap`, an explicit wrap check,
  and the **user-bit guard** at the free site that `proc_unmap_2mb_hi` had always carried.
- **The low ceiling was `0x40000000`, six MB above the arena's real top.** `sys_mmap` stops at
  `0x3FA00000`, deliberately below the fixed user stack at `0x3FC00000`, so PD slots 509/510/511 — the
  guard page, **the user stack**, and the user-CR3 stash — were inside the range ring 3 could name.
  Now `0x3FA00000`, the constant `sys_mmap` actually allocates under.

### Security — P0: `#92` op 0x0C validated one copy of the primitive array and drew from another

- **The TOCTOU is closed by snapshotting** (`kernel/core/syscall.cyr`). Pass 1 validated the per-primitive
  array in the shm slot; `gpu_texl_build` then re-read every field from that same slot and derived each
  primitive's **destination byte offset** from the second read. The slot stays ring-3-writable throughout:
  `shm_write#72` permits cross-owner writes by design, and with `smp_sched_aps=1` a second CPU can rewrite
  it between the passes. Pass 2 also re-resolved `shm_kva` without re-checking validity, non-null or size,
  so a slot freed (`#74`) or re-created smaller since pass 1 yielded a null or undersized pointer.
  ⛔ **And nothing downstream clips.** The comment claiming "the shader clips to the union anyway" was a
  second false load-bearing comment — the union never reaches the shader, and the shipped prologue applies
  no framebuffer bound at all. On the 2560x1440 verification host (pitch 10240) one primitive with
  `pw=1, ph=39323, py=65535` reaches past the back buffer into the GPU compute arena at `0x80000000` — the
  ring buffer, the MQD and every resident shader blob — while still passing the launched-wave cap.
  Fix: the per-primitive validator is extracted so one implementation serves both passes; pass 2 copies
  the array into a per-CPU 64 KB window, re-validates the **copy**, and builds only from the copy.
  `fbw`/`fbh` are now threaded from `gpu_shader_op_sys` rather than re-derived, which also removes a bare
  divide and makes pass 2 use exactly pass 1's bounds. New `GPO_E_RACE = 36` (additive; 36 < 256, so the
  packed `-((idx << 8) | reason)` encoding is unchanged).
  ⚠ Reachable **on iron only** — `gpu_texl_arm` refuses when `gpu_present == 0`, so QEMU never dispatches
  op 0x0C. The `#92` battery is therefore the only place this can be exercised, which is why the staging
  region is taken unconditionally at boot rather than behind a `gpu_present` gate: a gate there would make
  both the fix and its test dead code.
  ⚠ **This does not make op 0x0C SMP-safe.** The shared prep slot and the global `gpu_texl_maxw/maxh/
  colmajor` latches are untouched and pre-existing; two CPUs in op 0x0C still stomp each other's build.

### Security — ring-3 memory exhaustion in both ELF loaders

- **Every post-creation failure path leaked the address space** (`kernel/core/elf.cyr`). Both loaders
  create the per-process PML4/PDPT/PD, map 2 MB user pages into it, and on any later error did a bare
  `return 0 - 1`. `proc_free_address_space` is the only reclaimer and is reached exclusively through
  `proc_reap`/`proc_reap_child` **with a pid** — none was created, so the pages are unreachable from any
  CR3 chain and lost until reboot. Worse, the `proc_create_user` tails had **no failure arm at all**: fill
  the 16-slot process table with spinning children, then loop `spawn`, and each call drops a fully
  populated address space — 4,206,592 B minimum, 35,663,872 B for a binary at the loaders' own 32 MB
  ceiling. The `pmm_alloc_2mb` arm is self-reinforcing. Now centralised through `elf_bail` across 25 sites
  plus both tails.
- **`sys_mmap` leaked a 2 MB region on two failure paths** (`kernel/core/proc.cyr`). The high arm's
  `proc_map_page_hi` failure returned without freeing; the low arm discarded `proc_map_page_nx`'s return
  entirely. The high one is deterministically reachable because the two allocators have different
  ceilings: `pmm_alloc` stops at 256 MB while `pmm_alloc_2mb` scans all RAM, so a process that first
  consumes every 2 MB region below 256 MB makes the PD allocation fail while the page allocation keeps
  succeeding — every subsequent high mmap then leaks 2 MB.

### Fixed — the formatting helpers the crash record depends on

- **`fmt_hex_buf` returned an empty string for any negative value** (`kernel/klib/kfmt.cyr`). The loop gate
  was a signed `> 0`, so bit 63 set meant the digit loop never ran and the function returned length 0 —
  which three sites in `fault_kill_current` read as "the value was zero" and printed a fabricated `0`.
  **Ring-3 reachable and it falsifies the crash record**: a load from any canonical high-half address sets
  CR2 with bit 63 set, so the kernel's own post-mortem reported `HWCR2=0x0` — a null dereference that never
  happened. Worse for PDEs, since `proc_map_page_nx` writes `phys | 0x8000000000000087`, making every W^X
  data/stack PDE negative and an all-zero neighbour set read as "the page's memory was destroyed".
- **`fmt_hex_buf` writes 17 bytes and all seven callers supplied 16.** A one-byte out-of-bounds stack
  write. ⛔ The two fixes were interlocked: before the first, `len == 16` was essentially unreachable;
  after it, every NX PDE and every high-half CR2 renders 16 digits, so the overflow goes from never-fires
  to fires-on-every-page-fault. All seven buffers widened to `[24]`, and the two comments asserting
  "16 hex digits exactly" — which is precisely the off-by-one — corrected.
- **`fmt_int_buf` rendered the most-negative i64 as a bare `"-"`**: two's-complement negation is an
  identity on `INT64_MIN`, so the signed digit loop never ran. Now peels one digit while the value is
  still negative. Six regression locks added to the in-kernel suite.

### Fixed — the SysV init-stack pointer array could overrun into the strings

- The array is `[ELF_INIT_BLOCK+8, ELF_INIT_STR)` and the loader's last write is the auxv AT_NULL value at
  index `argc + 3 + envc`. `argc` was raised 8 → 16 at 1.46.x while the window stayed 31 slots, so
  `argc + envc >= 28` wrote past `ELF_INIT_STR` and clobbered the argv strings the array points at.
  ⚠ Severity, stated honestly: the spill lands in the child's **own** 2 MB stack page (the loader writes
  through `stack_kva`), so this corrupts the child's argv — it is not a kernel-memory escape.
  `ELF_INIT_STR` widened to `0x1FF200` (63 slots), the combined bound now asserted in the env loop —
  the only scope holding both counts — and written **from the constants** rather than as a hand-derived
  number. ⛔ The invariant had already rotted in **three** separate comments ("~27 ptr slots", "31 slots",
  "the 2-entry envp", the last wrong since 1.44.19); all three corrected.
- ⭐ **New gate `scripts/check/check-initstack.sh`** re-derives the arithmetic from the live constants, so
  raising either cap without widening the window fails the build. This is the durable half: with the
  widened array the runtime guard is unreachable under the shipped caps by construction, so a static
  check is the only form that can actually fail. Mutation-tested — the old `ELF_INIT_STR` reports
  `slots=31` against top index 35, exactly the overflow. `check.sh` is now **31 gates**.

### Fixed — a short USB data phase was reported as success, and the whole MSC driver had no coverage

- **`msc_bbb_exec` discarded the transferred byte count.** `xhci_wait_transfer_for_trb` returns 1 for
  SHORT_PACKET as well as SUCCESS, setting `xhci_last_xfer_bytes = expected - residue`; the transport
  tested only the 0/1 and then **clobbered that global** with the CSW wait. A device returning fewer
  bytes than asked therefore reported full success, and the caller consumed whatever was already in
  the destination page — which `pmm_alloc` does not zero. `dCSWDataResidue` appeared nowhere in the
  file. Both are now recorded per-slot (row +88 / +92) and `READ(10)` refuses a short transfer.
  ⚠ **Enforced at the SCSI layer, not in the transport.** A blanket "moved == asked" inside
  `msc_bbb_exec` would break enumeration: REQUEST SENSE asks 18 and a spec-legal fixed-format reply is
  14; INQUIRY asks 36 and SPC-4 permits the lesser of allocation length and available data. Both zero
  their destination first, so short is harmless there. `READ(10)` is where short means wrong.
  ⚠ **The check uses the xHCI count, not the residue** — the controller's own measurement, free of the
  `US_FL_IGNORE_RESIDUE` quirk class that would brick sticks which merely misreport. The residue is
  *logged* beside it, which is the datum that decides whether a quirk is in play.
  ⚠ **No check on the WRITE path, deliberately** — `msc_bulk_enqueue` sets ISP only for IN, and the
  controller transmits exactly `length` on a bulk-OUT, so `got != bytes` there is unreachable by
  construction. Documented rather than added, so it is not dead code plus a literal that never prints.

- ⭐ **NEW `scripts/smoke/msc-short-smoke.sh` — the tree's FIRST usb-storage coverage**, wired into
  `sweep.sh`. Before this, **not one QEMU invocation anywhere under `scripts/` attached a usb-storage
  device** — every one is `qemu-xhci` plus `usb-kbd`/`usb-mouse`. So the entire MSC transport (~1500
  lines, five block-layer entry points) had zero automated coverage, and every gate passed identically
  whether its short-read handling was correct, inverted or absent.
  ⛔ **The absence was in the harness, not the capability.** Attaching `-device usb-storage,bus=xhci.0`
  enumerates and registers on the first boot that tries it — the one catch is that OVMF then offers the
  stick as a boot option and stops at its menu, so the NVMe drive needs an explicit `bootindex=0` or
  nothing boots at all. Measured: `msc: READ(10) short data phase 448 of 512 B, device residue 0`.
  The smoke runs both arms — injected (`MSC_SHORT_INJECT`, which shortens the recorded IN count) must
  REFUSE, and plain must SUCCEED. Without the second arm any unconditional refusal would pass while
  breaking every real stick.

### Security — a raw-block read handed the caller another process's staged write data

- **`blk_read#77` / `blk_write#78` used the ACTIVE backend's LBA size for a read of ANY handle**
  (`kernel/core/block.cyr`, `kernel/core/syscall.cyr`). `blk_lba_bytes` is documented as "bytes per LBA
  on the active backend", but `blk_read_on(h, …)` reads from handle `h`, which may be a different
  backend with a different sector size. On an NVMe-primary box reporting 4096 B/LBA, a ring-3 read of a
  registered 512 B USB stick filled 512 bytes of `blk_sc_bounce` and copied **4096** out — 3584 stale
  bytes of a buffer that `blk_write_sys` stages other processes' **user data** through. No device
  misbehaviour required.
  ⛔ **And `blk_enum#75` reported that same global for every handle**, so the ABI actively told the
  caller to size its buffer at 4096 for a 512 B device: the disclosure was the *documented* usage, not
  an edge case.
  Fixed with a per-tag LBA table written by all five registration paths; `#75` now reports each
  handle's own size, and both syscalls take their stride from the handle.
  ⚠ **The validators had to move with the copy.** `is_user_array(buf, nsec, blk_lba_bytes)` was still
  the active backend's — so a handle with the *larger* size (active 512, device 4096) would have
  cleared `nsec*512` and copied `nsec*4096`, straight past the 1 GB user ceiling. Both validators now
  use the same stride the copy does.
  ⚠ The bounce is also scrubbed before every read, so a backend that under-fills yields zeros rather
  than the previous caller's bytes.

### Fixed — TLB shootdown targeted a dense prefix, not the online set

- **`tlb_shootdown_all` walked `0..cpu_count-1` and handed the loop index to `apic_send_ipi_one`**,
  which writes `target << 24` into ICR_HI — so the loop index was used as a **physical APIC id**. But
  `cpu_count` is only the *cardinality* of the online set; the set itself is `{0} ∪ {i : bit i of
  ap_online_mask}`. They agree only for a dense prefix. If AP 3 checks in and APs 1–2 do not, the old
  loops armed and IPI'd APIC id 1 — which does not exist — while id 3, the CPU actually running procs,
  was never armed. `want` was `cpu_count-1`, acks stayed 0, and every shootdown burned the full
  2,000,000-pause timeout then proceeded with the flush unperformed on the one CPU that needed it —
  the exact stale-TLB-across-address-spaces failure the mechanism exists to prevent.
  Now iterates the mask via a new `cpu_online_mask()`, counts `want` **during the arm pass** so it can
  never disagree with what was armed, and bounds every loop by the array size (4) rather than a count.
  The boot gate asserts the mask invariants; mutation-tested.

### Fixed — VT-d could write through a 1 GB PDPTE, and enabled translation it had not described

- **`iommu_map_mmio` tested only the present bit, then treated the PDPTE as a page-directory address.**
  `pt_init` installs PDPT[3] as a **1 GB page** (`0xC0000000 | 0x83`, PS set), and IOMMU register
  blocks live at exactly that index (`0xFED90000 >> 30 == 3`) — the common case, not a corner. The old
  code took `0xC0000000` as a PD base and stored through it: a wild supervisor write into the 3–4 GB
  window, which on real hardware is device MMIO. Now refuses a PS=1 entry.
- **Root entries and contexts existed for bus 0 only**, with bus and func hardcoded at the single call
  site — which also made `iommu_set_context`'s own `if (bus != 0)` guard vacuous. A device at 01:00.0
  (the ordinary NVMe-behind-a-root-port layout) got a context written for the host bridge instead, and
  the moment GCMD.TE went up every NVMe DMA would be rejected with no root entry. Now takes func from
  `pci_busfunc` and **refuses to enable translation** when any enumerated device is off bus 0.
  ⚠ **Refusal, not per-bus tables.** Per-bus contexts are the right end state, but this file has
  **never executed** — it needs a DMAR table (Intel VT-d), archaemenid is AMD, and nothing under
  `scripts/` or `tests/` references it. A refusal is checkable by inspection and leaves the machine
  exactly as it ships; the rework would be unverifiable here.

### Fixed — the legacy UDP buffer was filled by every datagram that arrived

- `net_handle_udp` wrote `net_udp_buf` unconditionally, before and independent of the listener lookup:
  no port match, no destination check. Any inbound UDP — a broadcast, a stray datagram, or traffic for
  a port a listener had already claimed — overwrote what `recv` was about to show the operator, and a
  bound listener's data was duplicated into a second buffer nothing asked for. Now gated on *no
  listener claimed the port* **and** *the destination is ours*, with the destination threaded down from
  `net_demux_frame`. ⚠ The address set must include limited and subnet broadcast and pre-lease traffic
  — DHCP OFFER/ACK arrive at 255.255.255.255 while `net_ip` is still 0, and gating those out would
  break the one thing this path must not break. Verified: loopback / DNS / NTP / ICMP smokes all pass.

### Security — P0: "user pointer" meant *a low address*, not *a page the caller owns*

- **`is_user_ptr` / `is_user_range` were pure VA bounds checks**, and their comment reasoned entirely
  about what lies *above* the 1 GB ceiling — device BARs, the 1–4 GB PDPT mirror — and never asked what
  lies *inside* it. Under every per-process CR3 the answer is: the kernel.
  `proc_create_address_space` copies kernel `PD[0..127]` (0–256 MB, identity, **U/S=0**) into each new
  address space and explicitly rewrites `PD[8..127]` as `(hi * 0x200000) | 0x83` so the kernel can
  reach the whole PMM pool. Measured on a freshly created address space:

  | VA | `is_user_range` | PDE | present | user |
  |---|---|---|---|---|
  | `0x300000` — kernel image | **1** | `0x2000e3` | 1 | **0** |
  | `0xE00000` — `proc_rsp0` pool | **1** | `0xE00083` | 1 | **0** |
  | `0xF10000` — CPU0 SYSCALL kernel stack | **1** | `0xE00083` | 1 | **0** |
  | `0x8000000` — identity window interior | **1** | `0x8000083` | 1 | **0** |

  A syscall runs at CPL0 on the caller's CR3 with **AC=1** (the entry `STAC`), so SMAP is inert and a
  supervisor page is freely accessible. Every arm that does a raw `load8`/`store8` on a validated
  pointer — rather than going through `proc_copy_to_user` / `proc_copy_from_user`, which *do* check the
  user bit — therefore read or wrote kernel physical memory on ring 3's behalf:
  - `write(1, (void*)0x300000, 4096)` → 4 KB of the kernel image to stdout (**disclosure**)
  - `read(fd, (void*)0xF08000, 0x8000)` → file bytes over CPU0's syscall kernel stack (**ring-0 execution**)

  Unprivileged, deterministic, no crafted input, and every syscall taking a buffer is a candidate.
  ⭐ **The check is now a page-table walk** (`user_range_mapped`) requiring PRESENT + **U/S=1** on every
  2 MB page in the range, under the **live** CR3 (`dm_read_cr3()`, not `proc_get_cr3(current)` — the two
  can disagree, which is why `fault_kill_current` prints both). The window survives only as a cheap
  pre-filter. `is_user_ptr(p)` is now `is_user_range(p, 1)`.
  ⚠ **The boot-CR3 exemption is not a hole**: boot self-tests drive syscall arms from kernel context
  under CR3 `0x1000`, where the whole low window is supervisor identity and every walk would refuse.
  Ring 3 cannot reach that branch — the SYSCALL stub runs on the calling process's CR3, and the one
  place the kernel switches to `0x1000` mid-syscall (`spawn#3`) does so strictly *after* its
  `is_user_range` call.

### Fixed — P1: the high mmap arena was unreachable through the syscall ABI

- **`sys_mmap` spills allocations too big for the ~768 MB low arena into `[128 GB, 512 GB)`, and the
  1 GB ceiling then rejected every pointer into that region** — a process could obtain high memory and
  never pass it to a syscall. `is_user_range` now admits `[himmap_floor(), HIMMAP_CEILING)`.
  ⛔ **Widening the window alone would have been catastrophic**, which is why this could not ship before
  the walk above. The kernel direct map owns `PDPT[8..511]` — VA 8 GB upward, the same PDPT range the
  high arena lives in — so a hardcoded 128 GB floor on a box with more than ~120 GB of RAM hands ring 3
  a name for arbitrary physical memory. Two independent things make it safe and both must stay: the
  floor is **derived** from what `pmm_setup_directmap` actually installed (`himmap_floor()`, never the
  `USER_HIMMAP_BASE` constant), and the walk refuses any page whose U/S bit is clear — which every
  direct-map entry's is. Belt and braces, because the floor is a computation and U/S is hardware truth.
  ⚠ The wrap check runs **first**, before any window comparison: Cyrius comparisons are signed, so a
  length of `-1` would otherwise satisfy `ptr + len <= ceiling` while naming the whole address space.

- **`proc_copy_to_user` / `proc_copy_from_user` hardcoded `PML4[0]` and `PDPT[0]`**, which is correct
  only below 1 GB — survivable while the ceiling *was* 1 GB, not once a high VA is a legal pointer. A
  high VA walked through entry 0 lands on `(va >> 21) & 0x1FF` of the **low** page directory: `0x2010000000`
  aliases to `PD[128]`, the low mmap arena. The copy would silently read or write a different page of
  the same process than the caller named. Both now index every level from the VA, and both reject a
  supervisor PDPT entry and a 1 GB page outright.
  ⭐ Gated by the **aliasing** case specifically, not by a plain "does a high VA work" arm: the gate
  maps a second high page at `himmap_floor() + 0x10000000` — PD index 128, the *same slot* as its low
  probe page — writes a marker through `proc_copy_to_user`, and asserts the marker landed in the high
  frame **and** that the low page is untouched. Mutation-tested by restoring the hardcoded PDPT index:
  the copy lands in the aliased low page and `proc_copy_to_user` still returns **success**, which is
  exactly why a does-it-work arm would have scored a pass while corrupting.

⚠ **`is_user_array` still bounds its count against the LOW window** (`count > 0x40000000 / stride`),
so a high-arena buffer with a very large element count is rejected even though the range would fit.
That fails **closed** — a conservative refusal, not a hole — and is left alone deliberately: the bound
is a division specifically so it cannot itself overflow, and re-deriving it per-window would trade a
provably-safe check for one that has to be re-argued. Named here so it is a known limit rather than a
future surprise.

⚠ **Cross-arch**: `user_range_mapped` is x86 page-table shaped (PML4/PDPT/PD, U/S, PS) and lives in the
unconditionally-included `syscall.cyr`. It adds **no new aarch64 dangler** — `dm_read_cr3`,
`pmm_kva_for_access` and `directmap_pdpt_top` are already referenced from `pmm.cyr`, `acpi.cyr` and
`proc.cyr`, all unconditionally included, so that port was already depending on `core/vmm.cyr` symbols
it does not get. It does mean the aarch64 port will need a real answer here, not a stub that returns 1.

⭐ **`scripts/smoke/userwin-smoke.sh`** runs under a **real per-process CR3** — under the boot CR3
`is_user_range` takes its exemption and every arm would score a meaningless pass, so the gate builds an
address space, `cr3_load`s it, collects verdicts as flags, restores CR3, and only then prints. It checks
**both directions**: kernel image, `proc_rsp0` pool, SYSCALL kernel stack, identity-window interior, an
unmapped arena VA and a direct-map VA are all **rejected**; pages the address space genuinely owns — one
in the low arena *and* one in the high arena — are **accepted**. Without those accept arms, "reject
everything" would pass. Negative length and a range running past the end of the one mapped page are
rejected too. Mutation-tested: removing the U/S check on the PDE — i.e. the pre-1.56.52 behaviour —
reports all four kernel-memory arms by name.
⚠ **What this gate does not cover**: the *derived* floor has no observable effect below ~120 GB of RAM,
where `himmap_floor()` returns exactly `USER_HIMMAP_BASE`. A mutation swapping the derivation for the
constant scores a PASS here, and that was measured, not assumed. The gate asserts the derivation itself
instead — `himmap_floor() >= (directmap_pdpt_top + 1) * 0x40000000` — which holds on any box.

### Fixed — a HID endpoint could run dry because another consumer ate its events

- **The xHCI event ring is shared, and only `hid_poll` knew what a Transfer Event on an interrupt-IN
  endpoint means** — that one armed TRB was consumed and another must be armed. The three synchronous
  waiters (`xhci_wait_transfer_for_trb`, `xhci_wait_transfer_event`, `xhci_drain_transfer_events`)
  spin on that same ring for *their* TRB and consume everything else to keep it moving. Each such
  consume cost the owning HID ring one of its **16** armed TRBs, permanently. ⇒ Type while a USB disk
  is doing bulk I/O and the keyboard degrades one TRB per keystroke; at 16 the endpoint has none left,
  the controller posts nothing further, and input is dead for the rest of the boot with no error
  anywhere. The reverse direction was already known and mitigated by ordering — `main.cyr` defers
  arming the xHCI MSI-X vector until after `hid_kbd_configure` precisely so `hid_poll` cannot steal
  EP0 completions from `xhci_wait_transfer_event` — but the forward direction was never handled.
  The waiters now call `hid_reclaim_event(slot, dci)` before consuming a Transfer Event.
  ⚠ **Re-arm only, never fold**: the report bytes are dropped. Folding them would run
  `hid_process_report` from inside an MSC spin loop without `hid_poll_lock`, racing the real drain over
  `hid_mouse_dx` and `kb_buf`. A keystroke lost during disk I/O beats a corrupted accumulator.
  ⛔ **And it defers rather than arming**: the waiters run in thread context with interrupts **on**, so
  the ISR could interrupt `hid_arm_row_trb` mid-update and corrupt `hid_ep_idx`/`hid_ep_cycle` —
  trading a slow leak for ring corruption. The waiter bumps `hid_ep_rearm[row]`; `hid_service_rearms`
  does the ring work under `hid_poll_lock`, driven by the 100 Hz tick, so a dry endpoint is paid back
  within 10 ms even though no MSI-X will ever arrive to wake it.

- **`hid_ep_idx` / `hid_ep_cycle` on a KEYBOARD row are a decoy, and `hid_recover_halted` read them.**
  `hid_kbd_configure` registers the keyboard with the *same* ring and buffer as the `hid_kbd_*` globals
  but a *separate* idx/cycle pair, and nothing in the steady-state path advances that pair — `hid_poll`
  arms the keyboard through `hid_arm_xfer_trb`, which walks `hid_kbd_xfer_idx`/`hid_kbd_xfer_cycle`. So
  the row's copy reads **0 / 1 forever**. Keyboard halt recovery therefore issued
  `Set TR Dequeue Pointer` at ring slot **0** with cycle **1** while the real producer sat elsewhere:
  the endpoint resumed on stale TRBs, or on a cycle mismatch halted again immediately. One ring with
  two independent producer indices is the underlying hazard; `hid_row_arm` / `hid_row_idx` /
  `hid_row_cycle` now route every caller to whichever pair is real for that row.

⭐ **`scripts/smoke/hid-reclaim-smoke.sh`** — hermetic, and needs no USB hardware: the selftest brings
its own event ring, transfer ring, doorbell landing pad and a synthetic HID row it registers and then
un-registers, all under `hid_poll_lock` (which is what makes swapping `xhci_evt_ring_phys` and
`xhci_mmio_base` safe — every `hid_poll` caller bails at its own try-lock before reading either).
Reproducing the real thing needs a HID device *and* a USB disk *and* an operator typing during the
transfer, sixteen times, which is why it survived to 1.56.52. Four arms: a foreign `(slot, dci)` is a
silent miss; our event is claimed and **deferred**, not armed inline; the service pass arms exactly one
IOC-bearing Normal TRB and rings the doorbell for the right DCI; and a **real waiter** drives the whole
path — the arm that proves the reclaim is wired in rather than merely present. Mutation-tested three
ways, each caught by the arm built for it: dropping the call site → `a real waiter consumed a HID event
without reclaiming it`; claiming every event → `a foreign event was claimed as ours`; arming inline →
`the ring was armed from the waiter, not deferred`.

### Security — three "P2" items that were not P2

The 1.56.51 P2 table was re-derived against the tree on 2026-08-30 — every entry read at its site,
every *already-fixed* claim then adversarially refuted before being recorded, because a false ✅ buries
a live defect where nobody looks again. 14 survived as genuinely fixed, 15 were open, 0 were stale.
**Three of the 15 were mis-graded**, and all three are below. ⛔ That is now the third time this
backlog's severity labels have been wrong in the dangerous direction.

- **`dhcp_find_option` validated that an option's declared length FITS, never that it is big enough
  for its reader** (`kernel/core/net_dhcp.cyr`). All five call sites read a fixed width off the
  returned offset: 1 byte for option 53, and 4 bytes for options 54 / 1 / 3 / 6 through
  `dhcp_load_u32_be`, which is four unguarded `load8`s. A server — or anyone able to spoof one on-link
  during the boot exchange, the xid/chaddr match being the only barrier — sends a 1024-byte reply
  whose **last** option declares `len 0`. That option sits at `i = opts_len - 2`, the old bound
  `i + 2 + olen > opts_len` passes *exactly*, and the returned offset **is** `opts_len` — so the
  4-byte read starts at `&rx + 240 + (n - 240)` = `&rx + n`, up to 4 bytes past the end of
  `var rx[1024]`, which is **function-local and therefore 1024 bytes**. Those bytes become
  `net_gateway` / `net_dns_server` and are **printed** to the console and into the klug ring.
  Remotely-triggered ring-0 stack disclosure — the same class as the 1.56.51 `net_recv_udp` fix.
  ⚠ Even in bounds it mis-parsed silently: a 1-byte option 3 made `assigned_gw` one real byte plus
  three bytes of the *next* option.
  ⭐ The bound went in the **helper**, not at each site — `dhcp_find_option(opts, len, tag, need)` —
  for the reason written out above `is_user_array`: five callers exist today and each new arm would
  otherwise have to remember. A refusal looks to every caller exactly like "option absent", which they
  all already handle.

- **IPv4 fragments were neither reassembled nor rejected** (`kernel/core/net_ingress.cyr`). Grep the
  whole net stack for `frag` before this cut and there is nothing: `net_demux_frame` decoded ihl,
  total length, protocol, src and dst, and never touched bytes +6/+7 where the flags and the 13-bit
  offset live. The body of a **non-first fragment** was handed to the L4 handlers as though it were an
  L4 header. ⚠ The receive checksums added earlier in this same cut are **not** a filter: the IPv4
  header sum does not cover the payload, and the attacker owns the fragment body — for UDP, two zero
  bytes at `l4+6/+7` take the RFC 768 "not computed" skip; for ICMP and TCP a sum can simply be
  computed over what is sent. The TCP arm is the sharp end: a crafted body becomes a TCP header, and a
  SYN to a listening port allocates two `kmalloc` buffers. Unauthenticated, remote, and an allocation
  trigger as well as parse confusion. Now refused and counted (`net_drop_ip_frag`).
  ⛔ **The test is `& 0x3FFF`, not `& 0x7FFF`.** Bytes 6–7 are flags(3) + offset(13): `0x8000`
  reserved, `0x4000` DF, `0x2000` MF, `0x1FFF` offset. A datagram is unfragmented iff MF == 0 **and**
  offset == 0. Folding DF into the test would drop nearly every packet the box receives — path-MTU
  discovery sets it on most real traffic — while passing both fragment arms and looking correct.
  ⚠ Placed after the header checksum so a corrupt header is reported as a checksum drop, not
  miscounted as a fragment. Legitimate oversized traffic (a >MTU DNS reply) is now dropped rather than
  mis-parsed; reassembly is a separate piece of work.

- **No tagged release has ever had its kernel booted by CI** (`.github/workflows/ci.yml`).
  `release.yml` fires only on tag refs and gates the release on `ci: uses: ./.github/workflows/ci.yml`
  — a job it names *"CI Gate (must pass before release)"*. Under `workflow_call` the called workflow
  evaluates `github.ref` as the **caller's** ref, which for a tag push is `refs/tags/v1.56.52` and
  never `refs/heads/main`. Both self-hosted jobs (`boot-test`, `benchmarks`) carried
  `if: … && github.ref == 'refs/heads/main'`, so both were skipped on every release; and `release.yml`
  has no boot of its own — grep it for qemu/boot/smoke/ktest and the only hit is a prose comment.
  ⚠ CLAUDE.md's Closeout step 2 ("Boot sweep") assumed that gate existed.
  ⭐ **`scripts/check/check-ci-release-gate.sh`** (check.sh 31 → 32) is the durable half: the property
  cannot be tested from a developer machine — there is no way to dispatch a tag-triggered reusable
  workflow locally — so the fix would otherwise be asserted and never exercised. Mutation-tested both
  ways: reverting a guard names the job, and **breaking the parser fails rather than passing green**,
  which is the specific trap this repo has now hit four times.

### Fixed — what an adversarial review of this cut's own P2 batch found

Every change in the P2 batch was then attacked by an independent reviewer told to break it, and every
problem claimed was independently confirmed before being acted on. **15 were real** (11 dismissed).
They are listed because the shape of them is the useful part: none was in the *finding*, all were in
the *fix*.

- ⛔ **A gate I had just written could not fail.** `tss_ist_selftest`'s "the timer must stay on RSP0"
  arm reads IDT vector 32 — but the call sat beside `exc_handlers_init`, twelve lines *before*
  `idt_set_gate(&idt + 32 * 16, …)`. It was reading `idt_init`'s default gate, whose byte 4 is
  hardcoded 0, so it passed unconditionally and could never have caught the regression it names.
  Moved below the timer install; mutation-tested by actually adding `idt_set_ist(32, 1)`, which now
  reports `#DF HAS NO IST`. ⇒ **A check placed before the thing it inspects is not a weak check, it is
  no check** — and this is the same class this cut spent a day fixing in the harness.

- ⛔ **The `acpi_va` fix for the ACPI reset register was inert.** `acpi_va` only takes its
  `DIRECTMAP_BASE` branch when the live CR3 is the kernel PML4 (`0x1000`), and `power_reset` is reached
  through syscall #13 running on the *calling process's* CR3 — so it fell to `return phys` and handed
  back exactly the address it was called to translate. And even under CR3 `0x1000` it would not have
  helped: the direct map covers `pmm_memmap_ram_top`, which is EfiConventionalMemory only, while a
  SystemMemory RESET_REG at ≥ 4 GB is by construction a device register *outside* type-7 RAM. Replaced
  with a refusal that falls through to CF9, following `iommu.cyr`'s precedent.

- ⛔ **The ICMP destination fix reopened its own hole.** Admitting `127/8` "for loopback" let a frame
  arriving *off the NIC* with IPv4 dst `127.0.0.1`, sent to the broadcast MAC, take the reply path —
  the same amplifier, one address over. `net_demux_frame` is the shared demux for both the lo queue and
  the wire and passes no discriminator. Removed: the only in-tree ICMP loopback consumer is
  `icmp_ping(net_ip, 0)`, which the unicast test already admits.

- ⛔ **The sibling site was left alone.** `ip_dst` was threaded into the ICMP and UDP arms but not TCP,
  and TCP is the worse case: with any listener bound, a broadcast-addressed SYN took the passive-open
  path — two `kmalloc`s, a slot from the 8-entry conn table, and a SYN-ACK to the *spoofed* source.
  Eight frames exhaust the table. Now gated on unicast-to-us.

- ⛔ **The MSC Link-TRB fix lasted until the first stall.** `msc_reset_recovery`'s step-8 ring rewind
  re-established `C == PCS == 1` on the same two ring pages `msc_alloc_bulk_ring` had just been fixed to
  get right, and every subsequent recovery would have undone it again. ⇒ A fix that only holds until the
  error path runs is not a fix, and that path exists *because* errors happen.

- ⛔ **The new CI gate had two ways to pass wrongly.** It line-parsed YAML, so an `if:` whose
  `github.ref` test sat on a *continuation* line read as "does not test github.ref" — an affirmatively
  wrong PASS for the exact guard the gate exists to catch. And its vacuity check only fired when *all*
  self-hosted jobs vanished, so dropping one of two stayed green. Now absorbs continuation lines and
  asserts an expected job count. Both mutation-tested.

- **`#92` op 0x0A's new corner bound is evaluated in the wrong coordinate frame** — screen, where the
  shader samples rect-local. Measured: a well-formed batch at a non-origin rect is still **accepted**,
  so it rejects nothing realistic, and that measurement is now a permanent battery case (174 cases).
  ⚠ **Not fixed here, deliberately**: the bound was copied from op 0x09, which is *shipped and burned*,
  so changing what it accepts is an ABI-semantics change to a burned op and wants an operator ruling.
  Filed as [`issues/2026-08-30-tri-corner-bound-coordinate-frame.md`](docs/development/issues/2026-08-30-tri-corner-bound-coordinate-frame.md).

- Five comment defects, each a statement that was simply false: two blobs in the DHCP selftest whose
  annotated arithmetic described a *different* blob; an archaemenid surface given as 2560×1600 when
  every other statement in the tree says 2560×1440; "both call sites" for a function with six, naming
  an `inb` path deleted with the i8042; and a `check.sh` back-reference reading "the gate above" that
  the new gate's insertion silently repointed. ⇒ Reference gates by filename, not by position.

### Fixed — the rest of the P2 tail (12 items)

- **`#DF` had no IST stack, so its diagnostic was unreachable in its own failure mode**
  (`kernel/arch/x86_64/idt.cyr`, `gdt.cyr`). `idt_set_gate` hardcoded byte 4 — the IST-index byte of a
  64-bit gate — to 0 for all 288 gate installs and took no parameter for it, and `tss_init_cpu` zeroed
  the TSS and then wrote exactly two fields, leaving IST1..IST7 at 0. With IST = 0 the CPU performs
  **no unconditional stack switch** on vector 8; it delivers on the current stack, or on `TSS.RSP0` for
  a CPL3→CPL0 transition. ⇒ In the commonest cause of `#DF` — a bad or overflowed RSP0, which is
  exactly what idt.cyr's own vector-8 comment says the CMOS diagnostic exists for — the `#DF` frame
  cannot be pushed either, and the CPU triple-faults to a silent reset. Now `TSS.IST1` (offset 0x24)
  carries a per-CPU stack and `idt_set_ist(8, 1)` points vector 8 at it.
  ⚠ **The direct-map VA, not the identity VA** — region 7's identity VA (14–16 MB) is inside the
  user-segment range, so a large binary overriding `PD[7]` in its per-proc CR3 would take the `#DF`
  stack with it. Same reasoning `syscall_kstack_reserve` records for the same region.
  ⚠ **Placement is exact**: region 7 already holds the proc_rsp0 pool (`0xE00000`–`0xF00000`), the
  primary syscall kstacks (`0xF00000`–`0xF40000`) and the nested ones (`0xF80000`–`0xFC0000`). The free
  window is `[0xF40000, 0xF80000)` — 256 KB, which is 4 CPUs × 64 KB with nothing left over.
  ⭐ `tss_ist_selftest` asserts **both** halves plus the negative: `#PF` and the timer must **not** have
  been given an IST, since an unconditional stack switch on a re-entrant vector would have every nested
  delivery reuse one stack. Mutation-tested three ways — no IST1, an identity VA, and calling
  `idt_set_ist` *before* `idt_set_gate` (which silently rewrites byte 4 to 0).
  ⛔ **The gate earned itself immediately**: placed beside the other TSS selftest it reported a correct
  configuration as broken, because `idt_init()` had not run yet and the gate it inspects did not exist.
  An asserted-only fix would have shipped looking fine.

- **`iommu_allow_dma_2mb` aliased any address ≥ 1 GB onto an existing grant.** `(phys >> 21) & 0x1FF`
  masks to 512 entries — one 4 KB second-level table = exactly 1 GB — and the context entry hardcodes
  AGAW=1/30-bit, so the table genuinely spans 1 GB. An address at or above that wrapped onto an
  existing index and **overwrote it**, with no present-bit test and no error: the earlier grant is
  destroyed *and* the caller does not get the grant it asked for, since translation is identity so the
  device DMAs at IOVA == phys while the table now maps `phys mod 1 GB`. Now refused.
  ⚠ Latent on archaemenid (AMD — no DMAR, `iommu_active` stays 0) and live on any Intel VT-d box. That
  is a reason to fix it blind, not to leave it: nothing on this bench can produce it, so it would
  surface first on somebody else's hardware.

- **The ACPI SystemMemory reset register was written as a raw physical address** (`kernel/core/power.cyr`).
  `acpi_reset_addr` comes straight from the FADT GAS and is never translated; the arming logic gates on
  FADT revision, `RESET_REG_SUP` and non-zero, but never on `< 4 GB`. All four `acpi_load*` helpers
  route through `acpi_va` and there was no store counterpart. Firmware advertising a SystemMemory
  RESET_REG at or above 4 GB lands on a VA the kernel PML4 does not map, turning the last-ditch reboot
  rung into a CPL0 `#PF` hang. Now `store8(acpi_va(acpi_reset_addr), …)` — a no-op below 4 GB.

- **`net_handle_icmp` answered echo requests without checking the destination** — a smurf amplifier.
  Broadcast reception is required for ARP, so a frame addressed to `255.255.255.255` reached it
  normally, and the type-8 arm replied with `icmp_len < 8` as its only precondition: one broadcast
  request, one unicast reply from every agnos box on the segment. `ip_dst` is now threaded in and the
  reply is gated on unicast-to-us or loopback.
  ⚠ Deliberately a **narrower** address set than `net_handle_udp`'s: that one must admit broadcast
  because DHCP OFFER/ACK arrive at `255.255.255.255` while `net_ip` is still 0. An echo reply has no
  such requirement. Loopback stays admitted — `loopback_selftest` pings `net_ip` and asserts the reply.

- **The MSC bulk ring's Link TRB was created with C == PCS** (`kernel/arch/x86_64/usb/msc.cyr`). The
  initial Link C bit must be the *opposite* of the producer cycle (xHCI 1.2 §4.9.3.1) so hardware does
  not follow it before software has filled the ring; `msc_configure_endpoints` seeds both directions at
  PCS = 1 and this wrote C = 1. That is the exact polarity `xhci_ring.cyr` documents as wrong in its
  "Repair (LL) 2026-05-17" note — the **command** ring was corrected then and the MSC bulk rings were
  missed. Nothing downstream compensated: `msc_bulk_enqueue` only rewrites the Link C bit at the wrap,
  63 TRBs later. Taken on its precedent's own reasoning ("defensive fix even though the first Enable
  Slot doesn't reach wrap"); a divergence between two rings in one driver is worse than either polarity
  applied consistently. Verified against `msc-short-smoke`, both A/B arms.

- **`gpu_scanout_matchgeom` overrode the console geometry without bounding it by the real framebuffer.**
  Every guard was a plausibility check on the register values themselves; none compared the result to
  how much framebuffer exists. `fb_set_geom` is a bare three-field store, and afterwards
  `fb_pitch()`/`fb_width()`/`fb_height()` are what **every paint site** computes its address from. A
  pitch register reading up to 16383 px (the `0x3FFF` mask) with a 4096-px height describes a 268 MB
  surface. Now bounded by `fb_size_or_fallback()` — the function whose own comment calls itself the
  single source of truth "so the WC remap site and any future verify paths agree", and which until now
  had only its two WC-remap callers.
  ⚠ Read **before** `fb_set_geom` or it is circular: its fallback arm is `fb_pitch() * fb_height()`.
  ⚠ The real archaemenid case *shrinks* the extent (a 2560×1600 boot_info surface overridden to the
  panel's true 800×600), so it passes with room to spare — the bound only catches the growth direction.

- **`gpu_caps#89` bit3 promised that `#92` would not then return `E_NOGPU`, and did not check two of
  its four preconditions.** `gpu_shader_op_sys` gates on `gpu_present`, `gpu_matmul_ok`,
  `gpu_blit_arm()` **success** and `gpu_bb_pitch != 0`; the caps gate tested `gpu_present`,
  `gpu_arena_mc`, `gpu_ring_wptr`, `gpu_matmul_ok` — and the bare `gpu_blit_arm();` call **discarded its
  return value**. The two omissions are independently reachable: `gpu_blit_arm` returns 0 on
  `gpu_display_ok != 1`, a bad pipe or surface, a null `boot_info_ptr`, zero pitch or height, or the
  back-buffer TMR bound — none of which touch the three the caps gate did test. On such a box bit3 read
  SET and the next `#92` returned `E_NOGPU`: the exact "call it and read the error" shape `#86` already
  proved wrong. ⚠ The two extra conditions are kept rather than dropped, because the invariant to hold
  is `bit3 set ⇒ #92 will not refuse`, not set-iff.

- **`#92` op 0x0A (TRI_LIST) had no frame-skew corner bound**, which op 0x09 documents as mandatory —
  and this is not a stylistic sibling: op 0x0A reaches the **same shader**
  (`gpu_tri_list` → `gpu_tri_rgba` → `gpu_tri_prep`), so it was the unguarded door to code op 0x09
  guards. Added per triangle, bounding the ratio rather than clamping E (clamping breaks gradient
  reproduction at the far corner instead of merely bounding it).
  ⭐ **Battery 171 → 173**: the reject, plus the origin **control** that keeps it honest — without the
  control, a bound that rejected every TRI_LIST record would score a pass. The count is asserted, not
  printed, so adding a case without updating it fails the gate. Mutation-tested: removing the bound
  reports `list: frame skew beyond the ratio want 23 got 0`.

- **`#93 mdo_validate` had no operand block for `MDO_OP_CRCCAL`** — the one advertised op that
  accepted-and-ignored its record fields. Bit 10 is set in `MDO_OP_SUPPORTED`, the dispatch runs
  `mdo_crccal()`, and that function takes no arguments and reads nothing, so dwords +8/+12/+16/+20 were
  silently ignored. Every other op refuses a dword it does not define, for the reason written out
  repeatedly in that function: a field ignored today is a field a caller starts populating, and it
  becomes load-bearing ABI the moment a revision gives it meaning. Refusing now costs nothing, because
  no caller can depend on a value that has never been read.

- **`net_handle_tcp`'s stack canary was checked on 2 of 23 exits, and had nothing to protect.**
  Twenty-one exits — every early drop and every hot ESTABLISHED/SYN_RCVD path — skipped it, and the
  function declares **zero** local arrays: every local is a scalar. A canary guards a local *buffer*;
  with no buffer there is no mechanism it could catch on any exit. It was not free either —
  `stack_canary_check` halts the CPU on mismatch — so what stood there was an incoherent,
  mostly-unreachable panic path in the hottest function of the receive stack that *read as protection*.
  ⇒ **Removed rather than completed.** Adding it to all 23 exits would spend real work making a
  mechanism with nothing to detect look thorough.

- **`scancode_to_ascii`'s "Bounds check" was vacuous** (`kernel/arch/x86_64/keyboard.cyr`). The release
  branch above it opens with `if (sc > 127)` and every path inside returns, so `if (sc >= 128)` could
  never fire. The index it *failed* to screen is a **negative** `sc` — Cyrius has no unsigned types, so
  `sc > 127` and `sc >= 128` are both false and `load8(&sc_normal + sc)` reads below the table. No
  current caller can produce one, so this is latent rather than live; closing it costs one compare.

- **`timer_handler`'s comment named two guarantees that do not exist** (`kernel/arch/x86_64/pic.cyr`).
  It claimed `hid_poll` "self-gates (hid_kbd_slot_id==0 → no-op pre-enum)" — that guard was **deleted**,
  and hid.cyr records why: on a box with a mouse and no keyboard it drained nothing and never cleared
  `IMAN.IP`, so every device went quiet. And "is cli-first RX-only, so it is … non-re-entrant" is false
  on SMP — already corrected 165 lines below in the same file, on the MSI-X arm, without this copy
  being touched. `hid_poll` is re-entrancy-safe because it takes its own try-lock, not because of `cli`.
  ⚠ A comment promising a guard that was removed is worse than no comment: it tells the next reader the
  caller is already protected, which is the reasoning that leaves the real protection out.

⭐ **The P2 table itself said `0 FIXED` while 14 of its items were already done.** The P0/P1 sections
carry inline ✅ markers; this one never got them, so the header count and the lines below disagreed
with the code for two days — long enough for a session to redo finished work. Now marked inline, with
the three mis-gradings flagged ⛔ in place.

### Security — nothing verified a receive checksum, at any layer

- **`net_demux_frame` accepted every frame the NIC handed it.** No IPv4 header checksum, no ICMP
  checksum, no UDP checksum, no TCP checksum was ever computed on ingress — the only checksum code in
  the tree was `tcp_checksum_compute`, used on **transmit** only. A corrupted segment whose `seq`
  happened to land on `RCV.NXT` was appended to the receive ring and then **ACKed to the peer as
  delivered**, which is worse than dropping it: the sender is told the bytes arrived and never
  retransmits. A corrupted IPv4 header was parsed for its length and protocol fields regardless.
  All four are now verified in `net_ingress.cyr` before the payload is acted on, each with its own
  drop counter (`net_drop_ip_csum`, `net_drop_icmp_csum`, `net_drop_udp_csum`, `net_drop_tcp_csum`).
  ⚠ A UDP checksum of **0** means *not computed* (RFC 768) and is skipped rather than treated as a
  mismatch — agnos's own TX path emits exactly that, so failing it would have dropped loopback.
  ⭐ `l4_pseudo_csum` is a deliberate near-duplicate of `tcp_checksum_compute` rather than a shared
  helper: the TX path is load-bearing for every smoke in the suite and was left untouched.

⭐ **`scripts/smoke/net-csum-smoke.sh`** is the first gate anywhere in the tree that presents a
**corrupt** frame. Every other network gate proves good frames still pass, which a check that was
inverted, absent, or dropping everything would also satisfy. `NET_CSUM_SELFTEST` drives
`net_demux_frame` with a synthetic IPv4/UDP frame and asserts three arms: good frame **accepted**,
one-bit-corrupt IPv4 header **dropped and counted**, non-zero-but-wrong UDP checksum **dropped and
counted**. The accept arm is what keeps the other two honest. The UDP arm is the only exercise the
non-zero verification branch gets, since agnos never transmits a non-zero UDP checksum.
Mutation-tested: removing the IPv4 check reports `corrupt IP header ACCEPTED` and fails the gate.

### Fixed — device-supplied values that were trusted

- **Both virtio queue sizes were taken from the device with only a zero check**
  (`kernel/core/virtio_blk.cyr`, `kernel/core/virtio_net.cyr`), while each ring gets exactly one 4 KB
  page. The used ring binds it: `6 + 8N <= 4096` gives `N <= 511`, and split rings need a power of two,
  so 256 is the ceiling — the figure the surrounding comments already asserted and nothing enforced.
  The spec permits up to 32768; at `N = 512` the descriptor table alone is 8192 B, double its page.
  `QUEUE_SIZE` is read-write in modern virtio (1.2 §4.1.4.3), so both now shrink it, **re-read rather
  than assume the write took**, reject a device that will not comply, and reject a non-power-of-two.
  virtio-net additionally enforces a **lower** bound of 16, because `vnet_rx_prime` publishes 16 avail
  entries unconditionally.
- **virtio-net trusted the RX used-ring `desc_id` and length.** `buf_off = desc_id * 1536` indexes a
  16-slot buffer, so any id the device invents reads at an arbitrary displacement; and the length was
  clamped only against the *caller's* `maxlen`, never against the 1536-byte slot the data lives in.
  Both bounded now, consume-then-drop so a bad entry is discarded rather than spun on.
- **`ramdisk` bounds were signed and admitted negative sectors.** `sector >= capacity` passes for any
  negative sector, which then indexes `&ramdisk_pages + (sector >> 3) * 8` at a negative displacement.
  `start + count > capacity` could also wrap. Both rewritten operand-wise so no sum is evaluated.
- **SuperSpeed interrupt `Interval` had neither the zero-guard nor the clamp the HS path has**
  (`kernel/arch/x86_64/usb/xhci_ctx.cyr`) — from a device descriptor byte, where 0 produced -1 and
  anything above 16 overran the 4-bit field into its neighbours. The doc comment already described the
  clamped behaviour; it described the fixed code, not the shipped code.
- **`_S5_` decode latched `acpi_s5_valid` on a FAILED SLP_TYPb read** (`kernel/core/acpi.cyr`). The
  guard tested `bb <= 7` but not `bb >= 0`, and `acpi_aml_read_int` signals failure with a negative —
  which the next line then clamped to 0, contradicting the comment two lines above that refuses exactly
  that "mask it down" policy. Now symmetric with `a`, and the dead clamp removed.

### Removed — a W+X primitive with no consumers

- `vmm_map_user_exec` mapped a user page `0x87` = P | RW | US | PS: **writable and executable, NX
  clear** — the state W^X exists to prevent, and the same hole 1.56.51 had just closed in the ELF
  loaders. It had no callers; the whole `vmm_alloc_user_exec -> vmm_map_user_exec -> vmm_map` chain was
  unreachable. Deleted along with the NX-only twin, since removing `vmm_alloc_user` is what made
  `vmm_map_user` dead and a lone user mapper invites reintroducing the pair. Ring-3 mapping goes
  through `proc_map_page` / `_rx` / `_nx`, which are per-process and W^X-correct. The unreachable-fn
  count fell 189 → 185, confirming all four were dead.

Build: `build/agnos` **1,969,400 B** (multiboot2/ELF64, entry `0x1000a8`). `check.sh` **31/31** (new
`check-initstack.sh` gate), `test.sh` (x86) 4/4, `sweep.sh` 19/19, `ktest.sh` 103 passed / 6 failed
(those 6 pre-existing). ⚠ `fp-nm-smoke` is a PRE-EXISTING ~50%% flake — measured 2 of 4 failures on the
RELEASED 1.56.51 — so a red on that sweep gate means nothing without an A/B of several runs per arm.

### Harness — 7 sweep gates reported a boot that never happened as a wall of failures

- **`qemu_dwell_kernel` exists precisely to prevent this, and only 3 of 38 smokes used it.** The helper
  retries when the firmware never hands off and then says *"treat this run as VOID, not as a failure"*;
  its own header records that the unguarded form once *"cost a wrong bisect during the 1.56.51 sweep"*.
  Of the sweep's 22 gate smokes, **2** were guarded and **7 were not**: `chan-ring3`, `exfat-write`,
  `fat`, `fat-write`, `fp-area`, `fp-nm`, `fp-selftest`.
  ⛔ **Captured in the act.** `chan-ring3` failed in two of three 1.56.52 sweeps and passed standalone
  both times. Its serial log from the failing run:

  ```
  gnoboot v0.7.1: handing off to kernel
  gnoboot: fail @ EBS
  BdsDxe: loading Boot0000 "BootManagerMenuApp"
  ```

  gnoboot failed at `ExitBootServices`, so the kernel never executed and UEFI fell back to its boot
  menu. The nine `FAIL:` lines that followed — including *"kill criterion 1: the 2 MB region resolves
  from a RING-3 proc's CR3"* — were the smoke reporting missing markers from a kernel that never ran.
  A reader would have concluded that nine ring-3 isolation properties had regressed.
  All seven are now on `qemu_dwell_kernel`.
  ⚠ **The retry is sound only because it is gated on the kernel banner** — "the kernel never started"
  and "the kernel started and failed" are different events and only the first may be retried. It is
  *not* a blind re-run; once the banner is in the log the run stands whatever the assertions say.

- **`QEMU_TRIES` default 3 → 6**, because the rate the 3 was chosen against is not the real one. The
  helper's header says *"roughly 1 boot in 4"* never leaves OVMF. Measured by running one smoke four
  times and counting attempts: **3 kernel banners in 10 attempts** — a retry needed on every run and
  one run exhausting all three tries. The cost of a higher budget is paid only by a kernel that cannot
  boot at all, which `check.sh` and `test.sh` catch first and far more cheaply.

- ⭐ **`fp-nm-smoke` is not a coin flip, and never was an FP defect.** `state.md` recorded it as a
  **~50% coin flip** — *"2 of 4 runs FAIL on the RELEASED 1.56.51, same build, same host, no code
  difference"* — and warned future sessions not to bisect against it. It is on the unguarded list, and
  its recorded failure shape (*"`fp: #NM serviced` absent + `boot did not reach shell`"*) is precisely
  what an empty log produces. With the guard: **6 runs, 6 passes**, two of which needed a retry and
  would have been reds before. The gate was fine; the harness was reporting a boot that never happened.
  ⚠ Not a claim that it can never fail — a run exhausting all six tries still scores red. It now says
  so in words (`treat this run as VOID, not as a failure`) instead of naming an FP property.

- ⭐ **Confirmed in a single green sweep, which is the measurement that closes this.** With every gate
  guarded and the retry line visible, `sweep.sh` returned **23 passed, 0 failed** — the first fully
  green sweep of the cut — while printing **7 retry events across 5 distinct gates**:

  | gate | retries needed |
  |---|---|
  | `1.53.x FP-#NM (lazy save/restore serviced)` | 2 |
  | `1.40.x exec-from-disk (run /bin/prog2 + ENOEXEC)` | 2 |
  | `1.56.44 #92 ABI battery (171 cases)` | 1 |
  | `1.53.x FP-area (per-proc FXSAVE state)` | 1 |
  | `1.39.x FAT write (touch/echo/rm/mkdir/mv + subdir)` | 1 |

  Three of those five were on the unguarded list and would have been reported FAIL in that same run —
  and the gate needing the most retries is `FP-#NM`, the one recorded as a "~50% coin flip". The
  sweep's flakiness was the harness, measured rather than inferred.


### Harness — a failing sweep gate that printed nothing at all

- **`run_gate`'s display filter was `grep -iE "PASS:|FAIL:|smoke:"`**, and several smokes report a
  *launch* failure with a line matching none of those — `ERROR: QEMU produced NO boot output (0-byte
  log) — launch failure, not an exFAT result.` is the exact wording in `exfat-write-smoke.sh`. So the
  gate emitted a completely **empty** section and then scored FAIL: the transcript told the operator
  that something went wrong and gave no way to tell a kernel regression from a firmware hand-off that
  never happened. That distinction has its own `state.md` heading — *"A QEMU BOOT THAT NEVER HAPPENS
  READS AS A KERNEL FAILURE"* — and this filter was erasing the evidence for it. Now also passes
  `ERROR`, `SKIP`, `VOID` and `handed off`.
  ⚠ The `handed off` term was added on a **second** pass: the first fix missed `qemu_dwell_kernel`'s
  own retry line, so the first all-green sweep after the conversion reported `23 passed, 0 failed`
  while saying nothing about how many gates had needed two or three attempts to get there. A gate that
  passes on its fourth try is passing, but an operator should be able to see it.
  ⚠ **Scoring is deliberately unchanged**: a launch failure is still a FAIL here. Downgrading it to
  VOID inside `run_gate` would hand every real failure a way to hide. The fix is to make the
  diagnostic visible, not to forgive it.
  ⭐ This is the third defect found in `run_gate` in two cuts, all the same shape — the gate ran, and
  what it reported was not what it measured. (1.56.51 found a build failure being printed and ignored,
  and an `-i` grep scoring `0 passed, 7 failed` as a PASS.)

### Fixed — `#92` ABI battery: 167 → 171 cases

- Four op-0x0C TOCTOU cases: a baseline, two post-validation mutations that must answer `GPO_E_RACE`, and
  a **control** proving an unmutated list still reaches dispatch — without which a refusal that fired
  unconditionally would satisfy the other two while breaking every real caller. Mutation-tested: disarming
  the re-validation makes both mutation cases fail while baseline and control stay green.

## [1.56.51] — 2026-08-28 — P-1 sweep: the size-multiply overflow class, and four gates that could not fail

### Security — ring-3 and remote memory-safety fixes

- **`is_user_array(ptr, count, stride)`** (`kernel/core/syscall.cyr`) — the range validator for a
  COUNT of fixed-size records. `is_user_range`'s wrap check guards the ADDITION and cannot guard a
  multiplication performed in the caller's argument list: by then the wrapped product IS the length
  it was handed. The new helper bounds `count` against `0x40000000 / stride` — a division, so it
  cannot itself overflow — before multiplying. Rejecting a count above that bound costs nothing a
  caller could want: the honest product would not fit the 1 GB user window either.
- **`#81 readdir` / `#101 readdir_at`** (`kernel/core/ext2.cyr`) — `is_user_range(buf,
  max_entries * 64)` with a ring-3 `max_entries` checked only for `<= 0`. `max_entries = 2^58` makes
  the product exactly `2^64 == 0`, so the validator passed a zero-length window; `2^58 + 1` validated
  64 bytes. The same unsanitised `max_entries` was the loop's only bound, so records written were
  limited by the DIRECTORY's entry count, at `buf + count * 64`, past the `0x40000000` ceiling into
  the 1–4 GB range the per-process CR3 mirrors. Record contents are the caller's own filenames, so
  this was a controlled-content kernel write. Both arms now use `is_user_array`.
- **`#99 proclist`** (`kernel/core/syscall.cyr`) — the same wrap on `arg2 * 64`, with the fill loop
  bounded by the process count rather than `arg2`. Kernel-side records, so a disclosure as well as a
  write.
- **`#77 blk_read` / `#78 blk_write`** (`kernel/core/syscall.cyr`) — two composing defects. `total =
  nsec * blk_lba_bytes` wrapped (`nsec = 2^55` at 512 B/LBA gives `2^64 == 0`), and `lba + nsec` in
  the capacity check could itself overflow to a negative value, so a signed `>` bound passed on an
  out-of-range request. `nsec` is now capped at `0x100000` and `lba` at `2^48` before the sum, and
  the range check goes through `is_user_array`. `#78` is additionally gated on `blk_rw_armed`.
- **`net_recv_udp`** (`kernel/core/net_ingress.cyr`) — returned `net_udp_buf_len`, the datagram's
  UN-TRUNCATED length, after copying only `min(len, maxlen)`. `user/shell.cyr`'s `recv` verb sizes
  its `kprint` by that return: a 512-byte stack buffer, a return of up to 1016, and up to **504
  bytes of adjacent kernel stack** — saved registers, return addresses, the canary copy — printed to
  the console and the klug ring. An oversized UDP datagram is the remote half of the trigger. Now
  returns the bytes actually copied; truncation is deliberately not signalled (see the note at the
  site).
- Three further arithmetic-length call sites were audited and are correct as written — `#21
  epoll_wait` (clamps to 16), `#39 blit` (8192x8192), `#66 snd_write` (1048576). Each already
  carried a comment saying so; the four that were exploitable carried none.

### Security — second P0 batch (audit sweep, all verified against the code before fixing)

- **`elf_load` / `elf_load_from_file`: a NEGATIVE `p_offset` was accepted.** All three file-offset
  checks are upper bounds and every comparison is signed, so a negative offset passed each one: it is
  not `>= elf_size`, and adding a small positive `p_filesz` keeps the sum below it. The mapping loop
  computes its copy source as `elf_addr + p_offset + (lo - p_vaddr)` and `memcpy` is unchecked, so a
  crafted PT_LOAD read kernel memory *below* the image and delivered it into a page the child maps at
  ring 3 — an arbitrary kernel-memory disclosure through `spawn#3`. A non-negative floor is now
  applied at all four check sites (both loaders, pre-pass and mapping loop).
- **`ext2_readlink`: the fast-symlink path had no 60-byte cap.** `tlen` is `i_size` off the disk and
  the only gates were `tlen < 1` and `tlen > cap` — where `cap` is the *caller's* buffer, never the
  source's. A fast symlink's target lives in the 60-byte `i_block[]` area inside a 512-byte scratch
  of which at most 256 is filled, so an inode with `i_blocks == 0` and `i_size = 4096` made
  `readlink#70` copy ~3.6 KB of adjacent kernel BSS out to ring 3. Bound now comes from the format.
- **`ext2_dir_try_insert` / `ext2_dir_remove` skipped `ext2_dirent_valid`.** All four read-side
  walkers gate every record on it; the two write-side walkers did not, so `off` could sit anywhere
  in `[0, lim)` with no requirement that a record fits. Case B writes at `off + e_real` where
  `e_real` derives from the on-disk `name_len` and reaches 264 — a block with a live entry at 4080
  and `name_len = 255` writes 248 bytes past the 4096-byte `ext2_dir_buf`, carrying an
  attacker-influenced filename. Both walkers now use the predicate, and both insert sites bound the
  write against `lim`.
- **`shm_create` and `shm_create_gpu` handed ring 3 unscrubbed memory.** `pmm_alloc_2mb` only flips
  bitmap bits and `pmm_free_2mb` only clears them, so a region carries whatever the previous owner
  left. Every other consumer already compensates (`sys_mmap`, both ELF loaders, `chan_region_reserve`
  — the last with the rationale spelled out); these two arms did not. The GPU variant is worse in
  kind: a carveout slot lives at a fixed offset per index, so client A's freed framebuffer reaches
  client B verbatim. Both scrub now.
- **Direct-DMA destinations in `ext2_read_at` / `ext2_write_at` are now opt-in.** Both coalescing
  paths hand `dst` / `srcp` to `blk_{read,write}_sectors_direct`, which passes the value through to
  the controller **as a physical address**. The gates tried to prove that with
  `(p & 0xFFF) == 0 && p + bs <= 0x10000000` on the belief that 0-256 MB is identity under the
  per-process CR3 — but `elf.cyr` overwrites exactly those PD slots with `pmm_alloc_2mb()` frames for
  every PT_LOAD, so for a ring-3 address `VA != phys`. `read#5` passes the ring-3 buffer straight
  through with no bounce, and `ext2_read_coalesce_max` is 16, so the path was live. Now default-deny
  behind `ext2_read_at_dma` / `ext2_write_at_dma` wrappers that cannot leak the armed state; the
  kernel-buffer callers (`vfs_read_file`, `vfs_read_file_at`, the klug spill) opt in, and the ring-3
  arms of `vfs_read` / `vfs_write` deliberately do not.
- **Device-reported LBA size is now validated at registration.** `blk_lba_bytes` is the per-LBA copy
  length for both raw-block syscalls and the buffer is a fixed 4096-byte `blk_sc_bounce`, yet every
  backend stored the device's claim verbatim — MSC decodes the SCSI READ CAPACITY(10) u32 and
  rejected only `== 0`; NVMe computes `1 << lbads` from 8 device bits. `blk_lba_bytes_ok()` now gates
  all four device-fed `blk_register_*` arms to {512, 4096} and logs its refusal. ⚠ The check is
  **also** applied in `msc_register_block_dev` before its policy branches, because the NVMe-primary
  and AHCI-primary arms call `blk_mark_registered(BLK_USB_MS)` directly and skip registration
  entirely — the registered bit is what `blk_read_on` gates on, so those two paths bypassed the gate.
- **`gpu_fill#85`: the band bound was a signed add that itself wrapped.** `y0` and `h` arrive as raw
  syscall registers. With `pitch = 10240`, `y0 = h = 2^51` gives `off = span = 2^62` (both positive,
  so `off < 0` and `span <= 0` both pass) and `off + span` reaches `2^63`, reading as
  `INT64_MIN` — so `> gpu_bb_fbsize` is false and the guard passes. The fill then issued at
  `tgt_mc + 2^62` for a byte count `gpu_cp_dma_fill` masks rather than rejects. Operands are now
  bounded against the row count before any multiply.
- **`#92` op 0x09 (TRI_RGBA): the edge slot id was never validated.** With DERIVE clear, `gpo_execute`
  resolves `rec + 12` as `load64(&shm_mc + (id - 1) * 8)` into a 16-entry (128-byte) table using a
  ring-3 u32 — `id = 0xFFFFFFFF` loads ~34 GB past it, `id = 0` loads 8 bytes before it, and the
  result becomes a GPU MC address handed to the rasteriser. Seven sibling validators carry the slot
  check; only this path lacked it, and its DERIVE alternative is rejected as `NOTIMPL`, so the
  unchecked route was the only accepted one.
- **`iommu.cyr`: `iommu_base` was added twice.** `iommu_write64`/`iommu_read64` take a bare register
  offset and add the base themselves; the IOTLB invalidate pair passed `iommu_base + iro + 8`,
  making the effective address `iommu_base * 2 + iro + 8` — a 64-bit store ~8.5 GB outside the mapped
  window. The global IOTLB invalidate therefore never reached the hardware and translation was
  enabled with a stale IOTLB. Latent on AMD Zen (`iommu_active` stays 0), live on Intel VT-d.

### Fixed — the QEMU boot flake that was corrupting verification

- **`qemu_dwell_kernel`** (`scripts/smoke/lib/qemu-dwell.sh`) — roughly 1 boot in 4 on this box (far
  more under load) never leaves OVMF: the serial log ends in "Please select boot device" and the
  kernel banner never appears, so the run measured nothing while its assertions reported a wall of
  failures. Raising `QEMU_TIMEOUT` does not help — the menu is terminal, not slow. The new helper
  retries **only when the kernel banner is absent**, which is what makes it sound: a real regression
  gets no second chance, unlike `sweep.sh`'s unconditional double-run. Adopted by `agnsh-smoke`,
  `exec-smoke` and `edge-abi-smoke`. ⚠ This flake cost a wrong bisect during this sweep — a kernel
  change was blamed for a boot failure, then found to pass 2 of 3 re-runs on the identical binary.
- **`edge-abi-smoke` now exits VOID (2) instead of faking 22 ABI failures** when the kernel never
  started. Its own header already stated the principle for the truncated case; a never-booted run is
  the stronger form of it.
- **`edge-abi-smoke` could not boot at all on this box, from TWO independent causes**, isolated by a
  2x2 over {ESP geometry} x {block device}, one QEMU run per cell — neither variable alone explains
  the failure and neither alone fixes it:

  | ESP geometry | device | kernel ran? |
  |---|---|---|
  | agnsh-style (1..33 MiB on 128 MB) | nvme | **yes** |
  | agnsh-style | virtio-blk | no |
  | this smoke's (1 MiB..100% on 64 MB) | nvme | no |
  | this smoke's | virtio-blk | no |

  `mkpart ESP fat32 1MiB 100%` on a 64 MB disk yields a 63 MiB FAT32 at **1 sector/cluster** (129024
  clusters) that OVMF's FAT driver will not boot; 1..33 MiB yields 2 sectors/cluster and boots. The
  image was never the obvious suspect — `mdir` confirms `BOOTX64.EFI` and `boot/agnos` are both
  present and correct in it. Both changed to match `agnsh-smoke`'s proven recipe. **The 167-case
  battery now runs and PASSES 23/23**, which is what verifies the `#92` op 0x09 fix above.
  ⚠ 26 of the 83 smokes still attach `virtio-blk-pci`, which does not boot on this box under either
  geometry. They are presumed unrunnable here and were not audited.

### Security — third batch: W^X actually enforced, plus two media parsers

- **W^X was only ever half enforced, and the comments said otherwise.** 1.50.6 made data
  non-executable and stopped there; code kept using `proc_map_page`, whose PDE flag word is
  `0x87` = P | **RW** | US | PS with NX clear. Every ELF text page was therefore mapped **writable
  and executable** — the exact state W^X exists to prevent. New `proc_map_page_rx` (`0x85`: RW
  cleared, NX clear) is a *third* mode rather than a change to `proc_map_page`, because that
  function is still correct for the data pages that legitimately need RW (`ring3.cyr`'s selftest
  stack, `main.cyr`'s counter/witness pages) and flipping its bits would have broken them silently.
  Both ELF loaders now map `PF_X` read-only. ⚠ An RWX segment is **reported, not refused**: refusing
  it regressed `ring3-smoke` from 4 PASS to 0, and an A/B against the pre-change tree isolated that
  to the refusal — "RWX allowed + R-X read-only" scores identically to the baseline, so the
  read-only mapping costs nothing while the refusal costs the test. The tree still holds stale RWX
  binaries from an older cyrius; everything the current toolchain emits is R-X/RW-. The loader now
  prints `elf: W^X violation - RWX segment mapped writable+executable`, which is exactly the signal
  that says when the refusal can be turned on.
  ⭐ **The result is verifiable from the build**: `proc_map_page` is now reported `dead` by
  `CYRIUS_DCE=1` in the production configuration — no page in the shipped kernel is writable *and*
  executable, and the writable-executable mapping routine is unreachable.
  ⚠ Measured across 166 agnos-target binaries before landing: the toolchain emits `R-X @0x400000`
  and `RW- @0x600000`/`0x800000`, so segment permissions never share a 2 MB page — which is what
  makes this enforceable at PDE granularity. The RWX binaries in the tree are stale builds from an
  older cyrius. Verified: `agnsh-smoke`, `exec-smoke`, `check.sh` 30/30.
- **GPT: `SizeOfPartitionEntry` came off the disk unvalidated and was used as a DIVISOR.**
  `entries_per_chunk = 4096 / gpt_partition_entry_size` at three sites, so a crafted header carrying
  `0` is a kernel divide-by-zero; it is also the stride in `gpt_array_buf + i * entry_size` at two
  more, walking out of a 4 KB buffer. Now bounded by the UEFI spec's own rule (multiple of 128,
  ≥ 128, ≤ one chunk) with `NumberOfPartitionEntries` capped at what the 4-chunk walk can read.
  ⚠ **`gpt_decode_header`'s return was discarded at both call sites**, so validating inside it would
  have been inert — the globals are assigned before the check and the walk used them regardless.
  Both callers now honour the verdict.
- **ext2 extent header: `eh_max` was itself unvalidated, so `eh_entries > eh_max` bounded nothing.**
  Both are u16 off the disk; a header setting both to 65535 satisfies the comparison and the walkers
  then iterate 65535 × 12 = 786,420 bytes out of either the 60-byte `i_block[]` area or a 4096-byte
  scratch. The check compared the header against *itself*; the missing comparison is against the
  container, which only the caller knows — so `ext2_extent_header_validate` now takes a capacity, and
  all seven call sites pass their real one (4 for a root, `ext2_extent_cap_block()` for a node, itself
  clamped to the 4 KB scratch so a 64 KB-block filesystem cannot imply a 5460-entry walk).
  Verified against `ext2-write-smoke` and `ext-extent-smoke` (depth-2 tree: inline index → index
  block → leaves), both PASS.

- **FAT: the next-cluster value was never range-checked.** `fat_next_cluster` returned whatever the
  on-disk FAT said, filtered only for the EOC and BAD sentinels, and that value flows into
  `fatfs_first_sector_of_cluster` = `data_start + (clus - 2) * sectors_per_cluster` — read as a
  partition-relative LBA. A crafted entry naming a cluster beyond the volume is an arbitrary-offset
  disk read driven by mounted media. Now wrapped (the body became `fat_next_cluster_raw`) so every
  caller is covered and a future arm cannot forget the check; a self-referencing entry also ends the
  chain instead of spinning. Verified against `fat-write-smoke` (3a-3e + LFN content + subdir), PASS.

### Fixed — an ISR that allocates, and 24 smokes that could not boot

- **The RX drain reaches `kmalloc` from interrupt context — a same-CPU self-deadlock.** Four comments
  across `net_ingress.cyr` and `pic.cyr` asserted the drain is "RX-only ... issues no TX from
  interrupt context". It is not: `net_demux_frame` dispatches to `net_handle_arp`, which builds and
  `nic_send`s an ARP reply, and to `net_handle_tcp`, whose **passive-open path calls `kmalloc`
  twice** — and `kmalloc` takes `heap_spin_lock`. A timer tick landing on a CPU already inside the
  heap critical section, with an inbound SYN to a listening port in the ring, spins on a lock its own
  CPU holds. `net_rx_lock` guards the *ring*; it says nothing about the *heap*. Remotely triggerable
  by raising the SYN rate against a listener.
  ⭐ This is the hazard `net_handle_icmp` **already documents one file over** for `console_lock`
  ("MUST NOT call the console_lock'd line emitters — a timer tick ... would same-CPU DEADLOCK on the
  re-acquire"). The discipline was applied to the console and not to the heap.
  Fixed with `net_rx_drain_isr()`, a latching wrapper (cleared on its single exit, so no ISR path can
  leave it set) that both `pic.cyr` call sites now use; the passive open declines when latched.
  **Dropping the SYN is correct TCP** — the peer retransmits and `net_poll()` picks it up from
  syscall context. Established-connection delivery is untouched. The four false comments are
  corrected. Verified: `tcp-smoke` 4/0.
- **24 smokes could not boot at all, and the failure looked like the kernel every time.** They shared
  a copy-pasted ESP recipe — 64 MB disk, `mkpart ESP fat32 1MiB 100%`, `virtio-blk-pci` — and the
  2x2 isolated at `edge-abi-smoke` applies to all of them: only {1MiB..33MiB on 128 MB} x {nvme}
  hands off. The visible symptom was never "no boot"; it was each smoke's assertions grepping an
  empty log and reporting a wall of red naming real regression guards. **Four of the 24 are gates in
  `sweep.sh`** (`fp-area`, `fp-nm`, `fp-ctxsw`, `fp-selftest`) — the same four whose "N passed, M
  failed" output the old PASS detector scored as PASS, so a never-booted run was being counted green
  twice over. All 24 converted; `ext2-smoke` skipped (multi-partition + ext2 overlay, needs its own
  treatment). Now running and passing: `tcp-smoke` 4/0, `dns-smoke` 3/0, `fp-nm` 3/0, `fp-area` 2/0,
  `fp-selftest` 4/0, `fp-ctxsw` 8/0.
- **The literal-length gate did not cover `serial_print`/`serial_println`**, which carry the identical
  unchecked `(string, length)` contract. The gate's own header already stated the lesson — "a
  length-checking gate must enumerate EVERY (string, length) API in the tree, because the ones it
  omits are exactly where the bug survives" — and this was the one API left out. First scan found
  **two live off-by-ones** (`fb_console.cyr:313` declaring 47 for 46 bytes; `test_procs.cyr:48`
  declaring 11 for 10), each printing a byte past its literal. Both fixed; the gate now checks 3,576
  literals and is mutation-proven. ⚠ A mismatch introduced during this very sweep passed `check.sh`
  30/30 before the extension — the gap demonstrating itself.

### Fixed — verification gates that could not fail

- **`scripts/sweep.sh`'s PASS detector scored total failure as PASS.** `grep -qiE "smoke.*PASS"` —
  the `-i` makes `PASS` match the substring inside "**pass**ed", so `=== fp-nm-smoke: 0 passed, 7
  failed ===` satisfied it. Four of the twelve gates the sweep runs (`fp-area`, `fp-nm`, `fp-ctxsw`,
  `fp-selftest`) report in that form. The smokes' own `exit 0`/`exit 1` was being discarded; it is
  now the oracle, with a narrow log assertion against the exact trap.
- **`scripts/sweep.sh` ignored a failed build** and ran the smoke against whichever `build/agnos` was
  left on disk from a previous gate — a different compile-gated configuration wearing this gate's
  name. A build failure is now the gate's verdict.
- **`scripts/bench.sh` had exited 1 on every invocation since 2026-07-19.** Its launch-site guard
  searched for `kybernet(); arch_halt();`; `power_quiesce_devices()` was inserted between the two on
  that date. `scripts/ktest.sh` carried the identical guard, hit the identical break, and was fixed
  at 1.56.44 — this verbatim copy was not. The rewrite is now asserted to have landed, not merely
  its precondition checked.
- **`scripts/test.sh`'s aarch64 half could not produce a failure, by two independent routes.** Its
  cross-compiler probe named `cc5_aarch64`, dropped at cyrius v6.1.0, so it took a bare `return` on
  every run; and past that probe a compile FAILURE printed "SKIP" and recorded nothing. `--all`
  reported "4 passed, 0 failed" with the aarch64 half inert.
- **`scripts/test.sh` built and validated a kernel the project does not ship.** `build.sh` prepends
  `#define ELF64_KERNEL` and exports `CYRIUS_ELF64_KERNEL=1`; `test.sh` set neither, producing
  multiboot1/ELF32 (entry `0x100060`) while `build/agnos` is multiboot2/ELF64 (entry `0x1000a8`).
  The ELF assertion was pinned to the former and passed. It now builds the shipped configuration and
  derives the expected shape from `EI_CLASS`, as `build.sh` does.
- **`build.sh`'s multiboot/ELF validation could not fail the build**, and reported every validation
  failure as "python3 not available" — a `||` consumed the status. The two conditions are now
  distinct: a missing interpreter is a soft skip, a bad boot header is fatal.
- **The CI "Security Scan" job could not fail**, and all 8 hits it reported were false positives.
  `WARN=1` was assigned and then only echoed; `grep -rn 'syscall('` had no left word boundary and
  matched `test_hw_syscall(`. The raw-syscall check is now precise and gating, with a vacuity floor
  on the source count; the two undecidable checks are printed as INFO and explicitly do not gate.
- **`scripts/build.sh --aarch64` left a stale artifact on failure.** `build/agnos-aarch64` on the dev
  box was a **May 12** binary while every build since had failed. The output is deleted before the
  compile, so a failure leaves nothing.

### Fixed — release tooling

- **`scripts/version-bump.sh` reported updating `CHANGELOG.md` while doing nothing.** It anchored on
  `## [Unreleased]`, a heading this file does not have; `sed` matching nothing exits 0. The section
  is now inserted above the first `## [` heading and the result is asserted.
- **`scripts/build.sh` now enforces the toolchain pin.** The kernel compiles from `$ROOT/kernel`,
  which has no manifest, and the cyrius wrapper resolves `cyrius.cyml` at the compile cwd with no
  ancestor walk-up — so the root pin was read by nothing during a kernel build and the wrapper's
  drift warning was structurally unreachable. Measured: pin `6.3.9` and pin `6.5.36` produced the
  byte-identical `build/agnos` with no warning, twelve minors apart. `build.sh` now compares the pin
  against the toolchain the compile will actually use and fails on drift; `AGNOS_ALLOW_PIN_DRIFT=1`
  is the deliberate override.
- **`KASHI_REF` re-diverged across the three scripts** (build 1.0.6, test 1.0.4, bench 1.0.4, with a
  comment naming 1.0.0). All three now default **1.0.6**, matching `../kashi/VERSION`. Invisible
  locally because `[deps.kashi] path` wins; it decides which kashi a clean checkout gets.

### Changed

- **cyrius pin 6.5.28 -> 6.5.36** across all nine manifests (`toolchain-pin-check.sh` 9/9).
- **`arch/aarch64`** — `stubs.cyr`'s `ksyscall` and `main.cyr` still used the bare `proc_current`
  global, removed at 1.46.x SMP sub-bite 2 with the stated intent that "any unconverted read fails to
  COMPILE". It did fail to compile; the aarch64 build was ungated, so nothing read the failure. Both
  converted to `proc_current_get()` / `proc_current_set()`.
- **`CLAUDE.md`** — the documented boot command `qemu-system-x86_64 -kernel build/agnos` does not
  work and has not since the kernel became ELF64/multiboot2: QEMU rejects it for want of a PVH note.
  Replaced with the gnoboot + OVMF path in both places, and in `kernel/agnos.cyr`'s header. Gate
  counts corrected: `check.sh` is 30 gates, not 11; `test.sh --all` tops out at 5 checks, not 7.

### Security — P0: the ELF PT_LOAD identity-shadowing class, closed

- **Every kernel page-table dereference now goes through the DIRECT MAP** (`DIRECTMAP_BASE + phys`,
  kernel PDPT[8+]), never through a phys==VA identity address. Both ELF loaders bound a `PT_LOAD`
  only by `p_vaddr >= 0x400000` and `p_vaddr + p_memsz <= 0x10000000` — exactly PD[2..127] of the
  per-process page directory — while `proc_map_page`'s only index math is `(virt >> 21) & 0x1FF`.
  A crafted segment at 0xC00000 therefore overwrote PD[6] with a ring-3-writable page and shadowed
  the identity mapping of physical 12–14 MB *in that process's own address space*, which is where
  its PML4/PDPT/PD and the whole kernel heap live (`pmm_alloc` hands out [0x400000, 0xFFFF000], a
  strict subset of the same window). The next `load64(cr3)` under that CR3 then read attacker bytes
  as a page-table entry and stored through the result: **ring 3 to arbitrary kernel write**.
  `pmm.cyr` asserted the opposite as a load-bearing invariant and conceded on the next line that the
  heap was clear "only by luck of placement".
  Converted: new `ptw_pd_kva()` walk helper; `proc_map_page` / `_rx` / `_nx` / `_hi`;
  `proc_unmap_page` / `proc_unmap_2mb_hi`; `proc_get_user_cr3`; `proc_create_address_space`
  (zero + build of all three tables); `proc_free_address_space` (low sweep, high PDPT sweep, high PD
  sweep); `proc_copy_from_user` / `_to_user` (walk **and** byte copy); `sys_munmap`;
  `fault_kill_current`'s forensics walk; all five `ELF_PDE_PROBE` walks and the himem selftests.
  Only the ADDRESS moves — a PDE's value stays a raw physical page number.
- **`kmalloc` hands out direct-map pointers.** Slab pages come from the same `pmm_alloc` window, so a
  kmalloc'd fd table or epoll watch list was equally shadowable. Transparent to callers (audited site
  by site: every DMA path allocates from `pmm_alloc` directly and does not come through the heap).
  The `vmm_map(page, page, 0x83)` that stood there is removed — it wrote only the boot PD, so it
  never propagated into a per-process CR3, and was a no-op in practice.
- `proc_get_user_cr3` returns `kernel_cr3`, never 0, on a broken chain: its value is loaded straight
  into CR3 by the SYSCALL exit stub, where 0 is a guaranteed triple fault.

### Security — P1: SMP scratch, unvalidated input, unchecked returns

- **`open#7`'s `sc_open_abs` is per-CPU.** Its banner ended "Single-threaded per syscall ⇒ one shared
  buffer is safe"; that premise died when APs began scheduling ring-3 procs. Both the write and the
  `vfs_resolve_mount` that consumes it sit outside `fs_spin_lock`, so two CPUs in this arm produced
  **path confusion** — CPU 0 opening the file CPU 1 named.
- **`blit#39`'s `fb_scale_rowbuf` is per-CPU**, and moved from `.bss` to one boot-time 2 MB region
  sliced four ways. Its own comment named the SMP arc as the unwind and the arc shipped without it:
  a compositor and a game on two CPUs cross-painted, a **cross-process pixel disclosure**. Net −31 KB
  of image (the old 32 KB static array is gone); `check.sh`'s 2 MiB ceiling is not moved.
- **`enter_ring3`'s iretq frame is per-CPU** (`0x7000 + cpu*0x40`). The five params feeding it were
  converted for SMP in 1.46.x; the frame they feed was left shared, so CPU A could `iretq` to CPU B's
  RIP on B's RSP — and because every agnos ELF links at 0x400000, that does not fault cleanly.
  `exec_preempt` is per-CPU too (one CPU could consume another's IF=1 arm).
- **`boot_info` is validated before use** — magic `0x41474E4F` and `struct_size >= 0x78` — and copies
  `min(struct_size, 128)` rather than a fixed 128 that over-read the 120-byte struct by 8. On failure
  `boot_info_ptr` is left 0 so downstream guards engage. The only magic check in the tree was a
  diagnostic print 370 lines *after* `pmm_probe_memmap` had already walked the struct.
- **TLB shootdown handshake serialised.** Atomic `lock inc` ack (it was a plain read-modify-write run
  by up to three APs), a dedicated leaf lock (a second sender wiped the first's tally mid-flight), and
  inline self-service so an IF=0 sender can answer a peer instead of both timing out and proceeding
  with the flush unperformed. A boot-time gate asserts the hand-asm `[rbp-N]` contracts actually move
  the memory they name (`tlb: handshake primitives OK`); mutation-tested.
- **SYSCALL exit stub's IBRS-clear block moved** above the RSP/CR3 restore. It pushed three qwords
  through a fully user-controlled RSP at CPL0, after `clac` had re-armed SMAP.
- `acpi_parse_dmar` bounds each entry against the table (the DRHD register base was read up to 12
  bytes past the end, then used as an MMIO base).
- `pci_bar_64`'s documented `0 = malformed cap` return is checked at **both** sites; MSI-X now falls
  through to the MSI fallback instead of returning early.
- MSC per-slot rows bounded to the 16 that fit the page (the header claimed 1..64 and enumeration
  probed to 64, writing device-supplied bytes into the next PMM page); slots above the bound are
  reported, not silently skipped. Table addressed through the direct map.
- xHCI scratchpad array refuses `MaxScratchpadBufs > 512` (one 4 KB page = 512 entries; the field is
  10 bits and the same comment said so).
- SuperSpeed `bMaxPacketSize0` decoded as the log2 exponent it is — EP0 was being programmed with
  Max Packet Size **9** and an Evaluate Context actively replaced the correct 512 with it.
- `nvme_blk_read` / `_write` copy the device's real LBA size, not a hardcoded 512 (4 K-LBA namespaces
  silently short-copied 3584 bytes); `nvme_blk_flush` takes `nvme_spin_lock` (it submitted into the
  shared SQ and reaped the shared CQ with no lock).
- ACPI S5 retry uses PM1a's own base — it was re-issuing the PM1a pulse with the value read from
  PM1b, which is what the read-modify-write comment above it forbids.
- High mmap arena floor derived from the real `directmap_pdpt_top`; `proc_map_page_hi` refuses a
  present-but-supervisor PDPT entry rather than writing a per-process PDE into a shared kernel PD.
  The "the direct map tops at PDPT[71]" claim appeared three times and was never enforced.
- `blk_rw_armed` cleared on `blk_close` (it survived the whole boot), and the band's banner no longer
  claims a non-destructive read-path with a capability-gated write.
- Corrected load-bearing false comments: ring-3 CS/SS were documented inverted (`0x1B`/`0x23` where
  the GDT, `proc_set_ring3` and `sel_pair_consistent` all say `0x23`/`0x1B`); the `#NM` vector was
  described as inert when four production paths set CR0.TS on every switch; `sysinfo#35` still
  claimed "exactly ONE CPU (the BSP) ever schedules".

### Harness — two gates that could not fail

- **`ktest.sh` booted nothing.** Its ESP image was 64 MB, outside the only measured-working cell
  (`1MiB..33MiB` on a **128 MB** disk × nvme) that 1.56.51 established for the other 24 smokes. Every
  invocation reported "kernel may have crashed or not reached boot_finish" — a harness failure wearing
  the kernel's name. The suite now runs: **97 passed, 6 failed**, the six measured identical on a
  clean tree (pmm ×2, vfs pipe ×1, initrd ×3) and therefore pre-existing.
- **`agnsh-smoke` passed a wedged kernel.** Its two gates checked that *kybernet attempted the exec*
  and that the emergency-shell fallback did not run — both satisfied by a box that died at agnsh's
  first syscall, the second one precisely *because* it was already dead. It now requires agnsh's own
  banner. Mutation-tested against a deliberately broken exit stub.

### Consequence of the kmalloc move — two selftests were passing kernel pointers to user syscalls

- `chan_ring3_selftest` and `syscall_harden_selftest`'s ipc bite 9 called
  `ksyscall(97, CH_MINT, kmalloc(64), 0)`. `CH_MINT` validates its destination with `is_user_range`
  — `[0x200000, 0x40000000)` — and a kernel heap pointer satisfied that **only by accident**, because
  `pmm_alloc` hands out [4 MB, 256 MB), which overlaps the user VA window. With the heap on the
  direct map those pointers are correctly refused, and both selftests began failing at their mint.
  Fixed by giving them user-window scratch, which every sibling assertion in the same functions
  already used (`chan MINT` at `u + 704`, `chan endow MINT` at `u + 896`). ⚠ No PRODUCTION path was
  affected — audited: every non-selftest `ksyscall` caller passes a string literal or a `.bss`
  global, never heap memory.

### Known — not fixed in this cut

- **aarch64 does not compile**: 30 reachable undefined functions and 18 undefined variables;
  `arch/aarch64/stubs.cyr` has not kept up with `core/`. `test.sh --all` is now RED because of it,
  which is the honest state.
- **`#77 blk_read` on a registered non-active handle is still unbounded in LBA** — `blk_capacity` is
  the active backend's alone (`block.cyr:38`) and `blk_info#79` already reports 0 for other handles.
  Closing it needs per-handle capacity, a `block.cyr` registration change.
- **The UEFI boot flake is contained, not cured.** `qemu_dwell_kernel` retries it away for
  `agnsh-smoke` / `exec-smoke` / `edge-abi-smoke`; the ~30 other smokes still call `qemu_dwell`
  directly and will keep reporting a never-booted run as a wall of failures. The root cause — OVMF
  dropping to the boot-device menu instead of the removable-media path — is unexplained.
- **`ext2_readlink`'s SLOW path** is unaudited; only the fast-symlink branch was capped.
- **`ktest.sh`'s in-kernel suite has 6 pre-existing failures** (pmm x2, vfs empty-pipe x1, initrd x3),
  visible for the first time now that the harness boots at all. Measured identical on a clean tree.
- **`ring3-smoke` has 4 pre-existing failures** (preempt gate, parent spawn+wait, stress, yield).
  They are NOT from this work — measured identical against `ffdb611`, before any of it. They were
  invisible until the virtio-blk conversion above made the smoke runnable, which is the point:
  converting these gates did not create failures, it revealed them.
- **`ext2-smoke` still uses the non-booting ESP recipe** — it carries a second partition and an ext2
  overlay, so it was deliberately excluded from the blanket conversion.
- **FAT multi-node cluster cycles are still a hang.** The single-step wrapper cannot see `A -> B -> A`
  with both in range, and the thirteen walk sites have differing loop shapes (some carry a `last`
  cursor, some return, some break, some do post-loop work), so a blanket transform is unsafe. The
  `fat_chain_overrun()` predicate and the exact per-site form are in place at the wrapper for
  whoever does that work — including why a module-global step counter is the *wrong* shape for it.
- **The raw-block write gate (`blk_rw_armed` / `BLK_RW_ARM_MAGIC`) is still a plain magic constant
  any ring-3 caller can send.** Left as-is deliberately: the code already states this and names the
  seam ("the arm call is the exact seam where an aegis/shakti installer-capability check lands when
  agnos grows per-proc caps"). It is a documented posture pending per-process capabilities, not an
  oversight — closing it needs the capability model, not a bigger constant. ⚠ The WINDOW is no longer
  unbounded: `blk_rw_armed` now clears on `blk_close` (below). Moving the arm below tag validation
  was tried and REVERTED — it breaks the shipped `blk_open(0, MAGIC)` ABI.
- **`#92`'s primitive/vertex TOCTOU is unfixed** — it needs the per-primitive array copied into
  kernel staging before validation, the same discipline `gpu_shader_op_sys` already applies to the
  64-byte records. It is the one P0 of the two that did not land.

Build: `build/agnos` **1,965,592 B** (multiboot2/ELF64, entry `0x1000a8`) — 27,376 B SMALLER than the
mid-cut 1,992,968 B, because `blit#39`'s 32 KB scale rowbuf left `.bss` for a boot-time PMM region
rather than growing to 128 KB as a per-CPU array. `check.sh` 30/30, `test.sh` (x86) 4/4,
`sweep.sh` 19/19, `ktest.sh` 97/6 (those 6 pre-existing).


## [1.56.50] — 2026-08-28 — `#101 readdir_at`: a directory listing that can resume

### Added

- **`#101 readdir_at(path, buf, max, cursor_uva) -> count`** — `#81 readdir` with a cursor, so a
  directory with more entries than the caller's buffer can be read in batches instead of being
  silently truncated at `max`. Kernel leg `ext2_readdir_at_sys` (`kernel/core/ext2.cyr`).
- **The cursor is the byte offset into the directory file** — POSIX `telldir`'s cookie, and the only
  value that survives ext2 directories being a chain of variable-length records. An entry INDEX would
  force a re-walk from the top on every call, which is the O(n²) resumability exists to avoid.
- **Protocol**: `*cursor` is `0` to start; on return it is the offset to resume from, or **`-1` when
  the directory is exhausted**. Callers loop `while (cur != -1)`. Passing `-1` back in returns `0`
  and changes nothing, so a loop that overruns by one is harmless rather than an infinite restart.
- **Errors**: `-1` bad pointer / not ext2, `-2` not found, `-4` not a directory, **`-5` a cursor that
  is not 4-byte aligned**.

⛔ **`#81` IS UNTOUCHED, AND THIS IS A SEPARATE NUMBER RATHER THAN A 4th ARGUMENT ON IT.** `#81`'s
callers pass three arguments; the 4th register holds whatever the caller happened to leave there, and
this argument is a **pointer the kernel writes through**. An opt-in "only if it looks valid" test on
garbage is not a test. (`#96` is likewise held for `fork`.)

⛔ **The cursor is user data and is validated as such** — rejected unless 4-byte aligned and inside
the directory, since a misaligned offset would parse a record header out of the middle of a filename.
`ext2_dirent_valid` still bounds every record to its block, so the worst a valid-looking wrong offset
can do is yield nonsense names, never a read outside `ext2_dir_buf`.

### Testing

- **`tests/readdir/rdat.cyr`** — ring-3 exerciser; exit `95` iff the contract holds, `90`-`97`
  pinpoint the clause that broke. **`scripts/harness/readdir-at-test.py`** boots it under QEMU.
- ⭐ **The oracle is "paged == single-shot", not "paged > 0"**: the program compares its batched total
  against what one `#81` call reports. A walk returning the first batch forever would still terminate
  and still return entries; a walk skipping one record per batch would still look plausible. One
  comparison catches omissions and duplicates together.
- Mutation-proven four ways, each a full kernel rebuild and boot: resuming at the block start instead
  of mid-block (exit 93 — never terminates), the budget checked after the record is consumed (92 —
  a batch overruns `max`), exhaustion writing `0` instead of `-1` (93), and the alignment guard
  removed (97).

## [1.56.49] — 2026-08-27 — mouse wheel: byte [3] is read, `#98 ptrscan` grows to 20 bytes

### Added

- **`#98 ptrscan` record field +16 `s32 wheel`** — the wheel delta summed since the last drain, sign
  of the HID report byte (positive = wheel-up on the tested device). **Opt-in per call**: pass
  `max >= 20` to receive a 20-byte record; `max == 16` returns the 16-byte record unchanged. The
  syscall now returns the number of bytes written (16 or 20) rather than a literal 16.
- **`hid_mouse_wheel`** — the accumulator behind that field. Folded per report like `dx`/`dy`, reset
  on every drain including drains by 16-byte callers.
- **`hid: wheel byte seen, b3=<byte> resid=<residual>`** — one-shot diagnostic on the first report
  carrying a non-zero wheel byte. Printed from the `#98` arm (thread context), flagged from the fold.
- **`scripts/harness/hid-wheel-test.py`** — injects wheel events over **QMP** `input-send-event`
  (HMP has no wheel verb) and asserts the kernel line above.

### Fixed

- **`hid_process_mouse_report` discarded byte [3] of every boot-mouse report.** The layout comment
  documented it as `wheel (s8, optional)`; only bytes [1] and [2] were read. A wheel field existed
  nowhere above this point either — `#98`'s record had no slot for it.
- **A wheel-only report no longer reads as idle.** `hid_mouse_take`'s idle test checked `dx`, `dy`
  and both button fields; a scroll with no motion and no button was dropped.

### ABI

- `#98 ptrscan(buf, max)` → bytes written: **16** when `max` is 16..19, **20** when `max >= 20`, `0`
  when idle, `-1` on a bad range or `max < 16`. Record: `+0 s32 dx` · `+4 s32 dy` (positive = down) ·
  `+8 u32 buttons` · `+12 u32 buttons_seen` · **`+16 s32 wheel`** (only when 20 bytes were written).
- `hid_process_mouse_report(report_phys, bi, resid)` and `hid_mouse_take(out, cap)` take one further
  argument each. Both are kernel-internal; `hid_mouse_take` has one caller.

### Measured

- QEMU `usb-mouse`, boot protocol, xHCI: `b3=1` on wheel-up, `resid=0`. Byte [3] is present although
  USB HID boot protocol specifies a 3-byte mouse report, matching this file's existing SHORT_PACKET
  note about 4-byte boot-mouse reports. The wheel read is therefore ungated by length; the residual is
  recorded by the diagnostic so the assumption is checkable per device.
- Kernel build: 1,985,472 bytes.

## [1.56.48] — 2026-08-26 — `icmp_echo_ex`#100, ICMP counters, id+seq reply matching, klug-ring header

### Added

- **`#100 icmp_echo_ex(dst_ip, timeout_ms)` → RTT ms (≥0) / -1** — `#55` with a caller-chosen
  deadline. `timeout_ms <= 0` selects the kernel default (~3 s); clamped to 60 s. Resolution is the
  100 Hz tick, so the bound rounds down to whole ticks with a floor of 1. Unblocks `yo -W` on AGNOS.
- **`icmp_ping(dst_ip, timeout_ticks)`** — the kernel-side parameter behind `#100`. `0` selects the
  historical 300-tick bound; all four in-kernel callers pass `0` and are behaviourally unchanged.
- **`net_config`#61 fields 4..7 — ICMP counters.** 4=`icmp_tx` · 5=`icmp_rx` · 6=`icmp_replies_sent`
  · 7=`icmp_timeouts`. Free-running, monotonic, never reset. Written without a lock
  (`net_handle_icmp` is reachable from the timer ISR), so a torn read costs one count — diagnostics
  only. ⚠ `0` is a legitimate value here, unlike fields 0..3 where `0` means "unset".
- cyrius peer: `SYS_ICMP_ECHO_EX = 100`, `sys_icmp_echo_ex(dst_ip, timeout_ms)`, and
  `sys_net_icmp_tx` / `_rx` / `_replies_sent` / `_timeouts`.
  → [ticket](docs/development/issues/2026-08-26-syscall-100-icmp-echo-ex.md)

### Fixed

- **An echo reply was matched on the ICMP identifier alone, so a stale reply satisfied the wrong
  wait.** `icmp_id` is a per-kernel constant (`0x4147`), so a late reply to a *previous* ping — one
  whose deadline had already expired — set `icmp_reply_seen` for whatever wait was currently open.
  The RTT was then measured from the wrong start, and a host that had stopped answering could still
  read as reachable. `net_handle_icmp` now requires the **sequence** to match as well; `icmp_ping`
  already bumped `icmp_seq` per call, so the discriminator existed and was simply not being read.

### Breaking

- **`fn icmp_ping` takes two arguments.** In-kernel callers only — the ring-3 ABI is unchanged, and
  `#55`'s arity is explicitly frozen at one argument. Pass `0` for the previous behaviour.
- ⛔ **`#55 icmp_echo` did NOT gain a second argument, deliberately.** Unused syscall argument
  registers are not zeroed by cyrius 6.5.35 — the compiler pops only as many as the call site passes
  — so reading `a2` there would have handed every already-shipped one-argument caller a garbage
  bound. **Widening a live syscall's arity is not backward compatible on this ABI.**

### Verification

QEMU, ring-3, against a booted kernel: `icmp_echo_ex(black_hole, 200)` returned -1 after
**elapsed_ms=200** (was ~3000); counters closed as `tx=4 rx=3 repl=0 to=1`, i.e. `tx = rx + to`; an
unknown `net_config` field still returns -1; `#55` unchanged. Regression: `yo`'s AGNOS smoke passes
against this kernel — 2/2 replies, 0% loss through the unchanged `#55` path.

Build: 1,984,736 B (x86_64).

### Also fixed in this release

- **`kernel/core/klug.cyr`'s header claimed the kernel stops feeding the klug ring at the kybernet
  userland handoff, so the ring's newest byte was ~kybernet.** There is no handoff gate. The tap in
  `kputc`/`kprint`/`kprintln` (`core/kprint.cyr`) is unconditional, and ring-3 console output reaches
  it through `vfs_write` (`core/vfs.cyr:960`) → `dev_write` → `serial_dev_write` (`core/devs.cyr:71`)
  → `kprint` → `klug_append`. The newest byte is the last thing anyone printed, kernel or userland.
  ⇒ Dumping the log to the console re-appends the log to itself: `klug`#36 returns up to 65536 bytes
  and the ring is exactly 65536, so a console dump re-appends the whole log, and on a ring still short
  of full it doubles the contents and the next dump wraps out the boot head. `run /bin/klug > /f.txt`
  is required, not convenient — the instruction already stood at `core/syscall.cyr:444`. A pipe is
  equally safe: a pipe fd takes `vfs_write`'s `VFS_PIPE` arm and never reaches `kprint`.
  Comment only — no code change, and the 64 KB sizing verdict is unaffected.
- The self-append mechanism is unfixed by decision. Two seams, named so they are not re-attempted:
  a `klug`#36 op dumping console-side from the kernel through a no-tap emitter (ABI surface for a
  hazard `>` already avoids), and `serial_dev_write` emitting through a no-tap `kprint` (kills the
  class, but strips ring-3 lines from the ring, which `klug_spill_covered_console()` exists to
  preserve). The kernel cannot special-case klug's own write: the dump is an ordinary `write(1,…)`
  from a separate ring-3 instruction, indistinguishable from any other program's output.

## [1.56.47] — 2026-08-24 — `#99 proclist`: AGNOS can enumerate its own processes

### Added — `#99 proclist(buf, max)`, the first process-enumeration primitive

AGNOS had no way to enumerate processes. The ring-3 surface offered `getpid`, `spawn`, `waitpid` and
`kill`, and there is no procfs, so nothing could answer "what is running on this machine?". A system
monitor was not degraded on AGNOS, it was impossible — chakshu's `--agnos` build rendered its column
header and zero rows on every boot, correctly, because there was nothing to ask.

```
proclist(buf, max) -> records written, -1 on a bad user range or max < 1
```

64-byte record, one per live slot, dead slots skipped:

| off | type | field |
|---|---|---|
| +0 | u64 | `pid` |
| +8 | u64 | `state` — 1 ready · 2 running · 3 claiming |
| +16 | u64 | `ppid` — 0 = init |
| +24 | u8[32] | `name` — NUL-terminated basename |
| +56 | u64 | `reserved` — always 0 |

The walk runs under `preempt_disable`; the name field is NUL-padded to the full 32 bytes so ring 3
cannot read a byte left by a previous occupant of the slot. Number chosen as `#99` because 0-95 and
97-98 have arms and `99` had none; `#96` stays reserved for `fork` per the 2026-08-05 ruling.

⚠ The `reserved` field is a decision, not slack. Per-process rss and cpu time are **not tracked by
this kernel**, so they are not invented here. When they are, they land at `+56` and the record size
does not change.

### Added — per-process names (`proc_names[]`, `proc_set_name`, `proc_name_ptr`, `proc_clear_name`)

`struct Process` is pure register state and `proc_create_user(entry, stack_top)` never saw a path, so
a ring-3 process's only identity was its pid number. 1.56.47 records the basename at ELF load, in
`elf_load_from_file` immediately after `proc_create_user` returns — the one point where a path and a
pid are both in hand. Basename, not full path: `/bin/shu` tells a reader nothing that `shu` does not.

16 processes × 32 bytes, declared `var proc_names[64]` — module-scope `var X[N]` is N × u64, the trap
this tree has now hit three times.

### Peer

`cyrius` carries `SYS_PROCLIST = 99` + `fn sys_proclist(buf, max)` in
`lib/syscalls_x86_64_agnos.cyr`, gated by `tests/gates/platform/syscall_wrapper_pass.sh` axis 5.
Consumers must call it by name — a raw `syscall(99, …)` is the bug class where raw Linux numbers
compile clean on agnos and dispatch a different arm. Issue records filed in both repos.

⚠ A kernel older than 1.56.47 has no `#99` arm. A negative return means "this kernel cannot
enumerate", which is a different fact from "no processes are running", and consumers must not
conflate them.

Build: `build/agnos` 1,983,648 B.

## [1.56.46] — 2026-08-17 — cycle OPEN

### Fixed — CI: seven nested `cyrius.cyml` pinned a toolchain no runner installs

`.github/workflows/ci.yml` installs exactly one toolchain, read from the ROOT manifest
(`export CYRIUS_VERSION="$(grep -oP '(?<=^cyrius = ")[^"]+' cyrius.cyml)"`, at lines 37/84/169/233/417
and `release.yml:44`). The root pins **6.5.28**; `tests/{audio,blk,chan,fault,fp,gpu,symlink}/cyrius.cyml`
all pinned **6.5.27**.

The wrapper resolves `cyrius.cyml` from the compile CWD with no ancestor walk-up and no merge
(`cyrius cbt/deps.cyr:203-245`), and `_try_redirect_to_pinned` (`cbt/cyrius.cyr:113-175`) hard-errors when
the pinned version is absent from `$CYRIUS_HOME/versions/`. So `scripts/check/host-gpu-oracles.sh:179`
(`cd "$GPU" && cyrius build "$t.cyr"`) failed on its first oracle:

```
host-gpu-oracles: FAIL -- texlist.cyr does not BUILD
error: cyrius.cyml pins version 6.5.27 but cyrius binary is not installed at
       /home/runner/.cyrius/versions/6.5.27/bin/cyrius
```

All seven are now **6.5.28**. Measured: all 61 `.cyr` files across the seven dirs compile to
byte-identical binaries under 6.5.27 and 6.5.28, and all 18 oracles the runner iterates exit 95 under
both — the 6.5.27/6.5.28 stdlib snapshots differ in one file (`freelist.cyr`), which no test dir vendors.
Verified end to end against a synthetic runner containing only 6.5.28: 18/18 oracles PASS; reverting
`tests/gpu` to 6.5.27 reproduces the failure above verbatim.

Blast radius: 14 invocation sites `cd` into a nested-manifest dir; only `host-gpu-oracles.sh` is
CI-wired, so the other 13 fail identically the moment they run on any single-toolchain box. Release is
gated too — `release.yml` job `ci` uses `ci.yml`.

### Added — `scripts/check/toolchain-pin-check.sh`, gating the pin across the tree

Prior history: `362abd2` hand-synced all seven nested manifests to the then-root 6.5.27; `ae46d32`
moved the root to 6.5.28 two days later and stranded all seven. One number, eight hand-maintained
copies, bumped in separate commits. `tests/gpu/cyrius.cyml` and the root manifest each instruct a
human to move the other in the same edit; that is the whole mechanism, and it has now failed.

The gate asserts every `cyrius.cyml` in the tree pins the ROOT value, using CI's exact PCRE
extraction so the two can never disagree about what the root pin is.

**It never invokes `cyrius`.** A dev box caches every version, so a stale nested pin resolves there and
degrades to `warning: ... toolchain drift`; the runner has one version and it is an error. The warning
also compares the pin against the installed cycc rather than the root pin, so a correct manifest warns
in identical words. Any gate that built something to test the pin would inherit that green-local /
red-CI asymmetry. This one compares strings in files.

Enumeration is `git ls-files --cached --others --exclude-standard` (so `.gitignore` owns the `build/`
and `.claude/` exclusions, and a new sub-project's manifest is gated the moment it is written, before
it is committed) minus the tracked vendored `*/lib/` snapshots. Wired at `ci.yml` in both `check` and
`test` — in `check` it runs BEFORE the toolchain install, since it needs no toolchain — and registered
in `scripts/check.sh` as `--- Toolchain ---`, ahead of `--- Build ---`.

Falsified in-file, all five directions confirmed red: reverse drift (one nested reverted), forward
drift (root bumped alone — the `ae46d32` shape), a nested manifest with no pin at all, fewer than two
manifests found (vacuous enumeration), and an unreadable root pin.

### Fixed — `vani-tone-smoke.sh` generated an eighth manifest pinning 6.4.2

`scripts/smoke/vani-tone-smoke.sh:63-73` wrote a `cyrius.cyml` containing `cyrius = "6.4.2"` into
`build/` (gitignored) and built from that directory — invisible to any manifest grep and to the new
gate. The generated manifest now carries no `cyrius` key, so it resolves the active toolchain, which
on a runner is the one installed from the root manifest.

`scripts/check.sh` 29 passed (was 28); `scripts/test.sh` 4 passed. `build/agnos` 1,981,096 B.

### Fixed — 88 vendored stdlib files + 12 build artifacts were tracked under `tests/*/`

`.gitignore`'s `/lib/` is root-anchored, so it never covered `tests/*/lib/`. 88 vendored stdlib files
were tracked across the seven test projects.

`tests/symlink/lib/` and `tests/blk/lib/` (7 `syscalls*.cyr` each) matched **no** installed snapshot —
not the 6.5.28 pin, not the 6.5.27 they had just moved off, not the 6.5.35 on the dev box. Both predate
**v6.4.51**: no `signal_ignore`, no `signal_default`. Last written by `ca3219c` ("1.51.0 work") and
`afa9808` ("move folders"). The other five dirs matched 6.5.28 byte for byte.

The committed copies could not affect a build in either direction:

- `cyrius deps` runs on every `cyrius build` **by default** and rewrites `lib/` from the pin, so the
  snapshot is overwritten before it is read. Building `tests/symlink` rewrote all 7 files.
- `--no-deps` does not read `lib/` either — it skips the stdlib include injection entirely, so
  `tests/symlink` fails `undefined function 'sys_symlink'` against a **fresh** `lib/` exactly as against
  a stale one. There is no build mode in which a committed snapshot is what gets compiled.
- No `cyrius.lock` is written for stdlib-only manifests (the lock covers `[deps.NAME]` git deps), so
  untracking strands nothing.

`error: 'sys_symlink' expects 2 arguments, got 4` at `symtest.cyr:38` is **not** a staleness symptom: it
is a host-target build of an `--agnos`-only program, and it reproduces verbatim against the fresh 6.5.28
snapshot. `sys_symlink` is 2-arg in `syscalls_x86_64_linux.cyr` and 4-arg (a4 in r10) in
`syscalls_x86_64_agnos.cyr`. Build it with `--agnos`.

Twelve binaries were tracked under `tests/*/build/` — audio 2, blk 3, chan 4, fault 1, fp 1, symlink 1.
The 1.56.44 purge covered `tests/gpu/build/` only. Unlike the 11 gpu tools, these were **not**
byte-identical to a rebuild at the 6.5.28 pin:

| binary | committed | rebuilt |
|---|---|---|
| `tests/symlink/build/symtest` | 13,856 B | 18,552 B |
| `tests/blk/build/gptwr` | 93,368 B | 97,880 B |
| `tests/blk/build/blkprobe` | 17,920 B | 18,328 B |
| `tests/blk/build/blkwr` | 17,920 B | 18,328 B |

`stage_one`'s build-if-absent (`scripts/burn/stage-tools.sh`, `[ -f "$bin" ] || _autobuild=1`) could
never fire for `faulter_agnos` or `tonegen_agnos`: a tracked fossil is always present. The 1.56.44
repair was inert for the two in-tree rows outside `tests/gpu`.

Both classes are now untracked (`git rm -r --cached`; files stay on disk). `.gitignore` `tests/gpu/build/`
widened to `tests/*/build/`, plus `tests/*/lib/`.

Verified: with `lib/` and `build/` deleted in all seven dirs and no network (`unshare -rn`), every
project builds — the stdlib resolves from `$CYRIUS_HOME/versions/6.5.28/lib/`, a local path, and
repopulates byte-identical to the pin. `git status --porcelain` is empty after builds in all seven, and
after `scripts/check.sh` + `scripts/test.sh`.

### Added — `scripts/check/vendored-artifact-check.sh`, gating both classes

Asserts two properties: nothing tracked under `tests/*/{lib,build}/`, and both paths ignored. The second
is not decoration — `git rm --cached` without a matching ignore converts 100 tracked files into 100
untracked ones, and every build leaves the tree dirty.

**It never invokes `cyrius`.** Its verdict comes from the git index and the ignore rules, so it answers
identically on a box caching every toolchain version and on a runner with one — the same property
`toolchain-pin-check.sh` is built around.

Falsified in-file, all four directions confirmed red: a tracked artifact (`git add -f`), a narrowed
ignore rule, fewer than 20 tracked files under `tests/` (vacuous enumeration), and a `tests/*/` glob
matching nothing (vacuous probe). Wired at `ci.yml` in `check` — before the toolchain install, since it
needs no toolchain — and in `scripts/check.sh` under `--- Toolchain ---`.

### Fixed — `pty-host-test.py` required binaries it refused to build

`scripts/harness/pty-host-test.py` exited 1 with `FAIL: missing .../tests/chan/build/ptyhost` and printed
the build command for a human to type. That branch was unreachable while the binaries were tracked. It now
builds-if-absent, mirroring `stage_one`'s `agnos/*` rows (in-tree, so it compiles under this repo's own
pin). At 6.5.28: `ptyhost` 55,896 B, `ptyx` 55,728 B.

`scripts/check.sh` 30 passed (was 29); `scripts/test.sh` 4 passed. `build/agnos` 1,981,096 B.

### Fixed — ring-3 initial stack: 12 KB usable -> 2,093,056 B (`elf.cyr`)

Both ELF loaders map a full 2 MB page for the user stack (`pmm_alloc_2mb` + `proc_map_page_nx` at
`stack_base` 0x3FC00000), then set the entry `rsp` near the BOTTOM of that page: `stack_base + 0x3000`
in `elf_load_from_file`, `stack_base + 0x4000` in `elf_load`. Downward growth was therefore capped at
12 KB / 16 KB while ~2.03 MB of the same mapped page sat above `rsp`, unused.

A ring-3 program whose frames exceeded that cap ran off the bottom into the guard page and was killed
with exit code **142** (128 + 14, #PF). No fault line is printed for this path, so the only symptom was
`run: exit 142`.

The SysV init block (control word, argv/envp pointer array, strings) is self-contained, so it moved to
the top of the page:

| constant | value | region |
|---|---|---|
| `ELF_STACK_SIZE` | 0x200000 | mapped stack page; also the string-region ceiling |
| `ELF_INIT_BLOCK` | 0x1FF000 | `[argc][argv..][NULL][envp..][NULL][auxv]` — entry `rsp` |
| `ELF_INIT_STR` | 0x1FF100 | argv/envp strings, up to `ELF_STACK_SIZE` |

Region sizes are byte-identical to the previous layout — pointer array 0xF8 (31 slots), string region
0xF00 (3840 B) — so the argv cap (16), envc cap (16) and total command-line length are unchanged. The
guard page at `stack_base - 0x200000` stays unmapped. Usable stack below `rsp` is now 0x1FF000
(2,093,056 B) for both loaders.

Measured under QEMU (q35, 512M, nvme): a probe taking 16 KB, 64 KB, 256 KB and 1 MB single-frame
locals returns 1 from each and prints `survived all`; 16 KB was `run: exit 142` before. `agnsh` boots
and `run /bin/shu -p` receives its `-p` argument, so the relocated argv/envp block still parses.
chakshu's `-p` snapshot and its TUI both run on AGNOS as of this fix.

Build: `build/agnos` 1,981,096 B. `scripts/test.sh` 4 passed; `scripts/check.sh` 28 passed.

### Fixed — `edge-abi-smoke` boot dwell 40 s -> 180 s (the battery outgrew its timeout)

The `#92` ABI battery reached 167 cases plus tper-prep (128) and trid-prep (256), each kprinting over
serial. At a 40 s dwell the guest was still mid-battery when the timeout fired: the log ended inside
the TRI_PERSP section and `chk` reported every case not yet reached as WRONG — 10 FAIL lines
including the aethersafha chrome-text regression guard ("a real colour at dword 9 was REFUSED") and
"the well-formed BLEND_ALPHA record did not validate". `gpo_validate` was never at fault.

The companion failure `AGNOS shell — boot did not reach shell` is the tell that the run was truncated
and every case after the cut is unindicted. Measured 2026-08-22: PASS at 180 s and 240 s.
`ARC SWEEP: PASS (19 passed, 0 failed)`; `burn-prep.sh` exits 0.

### Fixed — a PTY endpoint is now usable by the owner's DESCENDANTS (`#97`)

`chan_auth` accepted only `chan_end_owner[e] == proc_current_get()`, so a program launched by a shell
whose stdio is an endowed `#97` endpoint had every `read`/`write` on fd 0/1/2 refused with
`CH_E_BADFD`. Under `/bin/puka` this made agnsh builtins render and every launched program silent.

- New `chan_end_pty[32]`: 1 when the endpoint was endowed with `a4 == CH_ENDOW_STDIO` (1000).
  Cleared at mint, `CH_CLOSE` and `chan_release_pid`, alongside `chan_end_open`.
- `chan_auth` accepts a caller that is a descendant of the owner **only** when that flag is 1. The
  owner's `chan_end_oepoch` is compared against `proc_epoch_get(owner)`; the parent walk uses
  `proc_get_ppid`, bounded to 16 steps with a self-parent guard.
- `CH_ENDOW` additionally requires `chan_end_owner[ne] == proc_current_get()`. Endowment MOVES
  ownership, so descendant authority is a use-right, not a transfer-right.

Display channels are unaffected: the arm is gated on the PTY flag, and an inherited display claim
stays inert.

Measured, QEMU, `scripts/harness/puka-child-stdout-test.py`, glyph px at RGB (192,192,192):
`ls` **266 -> 1560**; `kriya ls /bin` 266 -> negative (the window scrolls). Builtin control `help`
unchanged at +11,186. Before the fix `ls`, `ls /`, `kriya ls` and `kriya ls /bin` all rendered an
identical 266 — agnsh's prompt.

### Changed — cyrius pin 6.5.27 -> **6.5.28**; 9 kernel files reformatted

`cyrfmt` did not track parentheses before 6.5.28: continuation lines inside an unclosed `(` were
emitted at the enclosing statement's indent, so the formatter's own output failed its own
`--check` — exit 1 with no file, no line, no diff. Canonical is now **2 spaces per open-paren
level**, 4 accepted, deeper rejected.

Reformatted, whitespace only (`git diff -w` is empty), 137 lines each way:
`kernel/core/{virtio_net,virtio_blk,gpu,ext2,syscall}.cyr`,
`kernel/arch/x86_64/usb/{xhci,hid,msc,xhci_ctx}.cyr`.

x86_64 kernel **1,987,576 B**, multiboot2 ELF64 OK, entry `0x1000a8`. `scripts/test.sh` 4/0;
syscall-abi, dup-symbols, kprint-len, array-sizing all PASS; boot to agnsh with xhci + hid + ext2 +
gpu live and no fault. The pin is what CI installs (`cyrius.cyml` is the source of truth), so the
bump and the reformat are one change: 6.5.27's checker does not accept 6.5.28's output.

### Fixed — `scripts/check/fmt-fix.sh` rewrote files it then reported as failures

⚠ BREAKING in cyrius 6.5.28: `cyrius fmt <f>` REWRITES THE FILE and prints nothing; `--dry` is the
old stdout form. The body here was `cyrius fmt "$f" > "$tmp"`, so under 6.5.28 it rewrote `$f` as a
side effect, left `$tmp` empty, failed the `[ -s "$tmp" ]` guard, and printed
`ERROR: could not format` for a file it had already changed. Now formats in place against a
backup copy and rolls back if the result fails `--check`.

### Fixed — `scripts/build.sh --aarch64` probed a binary name dropped at cyrius v6.1.0

`CC_ARM` was `$CYRIUS_HOME/bin/cc5_aarch64`. The backend was renamed to `cycc_aarch64` at v6.0.0
and the back-compat symlink dropped at v6.1.0, so every aarch64 build since exited
`ERROR: aarch64 cross-compiler not in toolchain` while the compiler sat in that same directory
under its current name. Prefers `cycc_aarch64`, accepts the legacy name.

⚠ `release.yml` wraps this build in `|| echo "aarch64 not yet portable"`, so the failure never
surfaced. With the probe fixed the target compiles and reports its real state: **30 reachable
undefined functions** (`ntp_now`, `exec_env_src_set`, `exec_env_len_set`, …) — x86-only symbols
that accumulated with no aarch64 stub while the target could not be built. Not addressed here.

### Changed — kashi clone fallback 1.0.5 -> **1.0.6**

`scripts/build.sh` pins `KASHI_REF` for the case where the sibling checkout is absent — which is
exactly CI. The manifest itself uses `path = "../kashi"` and always takes the sibling, so a stale
`KASHI_REF` does not show up on a devbox at all: **CI silently builds the kernel against a different
kashi than you do.** kashi 1.0.6 adds a publishable library face (`dist/kashi.cyr`); the freestanding
core this kernel consumes is unchanged.

⭐ **The kashi bump itself is byte-neutral** — rebuilt against 1.0.6 the kernel was still
`6f8578cc4189ab9d`, 1,987,576 bytes, because 1.0.6 changed packaging, not glyph data, and this kernel
takes only `src/font_data.cyr`.

⚠ The shipped 1.56.46 binary is `6c557484a46a8526` — same 1,987,576 bytes, differing only in the
embedded version string that `scripts/version-bump.sh --regen` writes into `kernel/version.cyr` and
the `kernel/agnos.cyr` banner — **exactly 3 bytes differ** from the 1.56.45 build, measured with `cmp -l`. Stated separately so the kashi claim above is not read as covering a
change it does not: no functional code moved in this cycle.

## [1.56.45] — 2026-08-16 (RELEASED 2026-08-17)

### Changed — cyrius pin 6.5.21 -> **6.5.27**

Part of the stack-wide toolchain sweep: aethersafha, dhancha, crab, puka, setu, rupa, sadish, rekha
and kashi all move to 6.5.27, and the kernel goes with them so kernel and desktop keep declaring one
language version — the same reason the pin moved to 6.5.21 in the first place.

⭐ **The kernel binary is BYTE-IDENTICAL across the bump** — `6f8578cc4189ab9d`, 1,987,576 bytes
before and after. The pin selects the stdlib snapshot under `~/.cyrius/versions/<pin>/lib`, and for
the modules this kernel uses 6.5.21 and 6.5.27 emit the same code.

⚠ **So no re-burn is required for this change.** 1.56.45's existing boot evidence covers these exact
bytes; a burn would be testing an artifact it has already tested. That is worth stating rather than
scheduling iron time out of caution.


### Fixed — an asynchronous log no longer eats the line the operator is typing

⛔⛔ **The signature, from the 1.56.45 burn.** A one-shot landed inside a command as it was typed:

```
[ASSIST] > ahid: first mouse report accumulated
ether      aethersafha --opacity 128 --client /present_probe
```

The `a` of `aethersafha` is stranded before the log and the rest resumes on the next row.

**`fb_console.cyr` now keeps the current row's drawn bytes** (`fb_line_buf`, 512 B, recorded at the DRAW
so it always matches the glass), and `fb_oob_begin`/`fb_oob_end` **save, erase, print, replay** around the
framebuffer write in `kprint` and `kprintln`. ⚠ Framebuffer ONLY — `serial` and `klug` are cursorless
transcripts, and replaying into them would print the prompt twice and corrupt the log. `kputc` is
deliberately unwrapped: it carries the keystroke echo, which is part of the line, not an interruption.
Both `kprint` and `kprintln` are wrapped, because ring 3 reaches the console through `kprint`
(`devs.cyr:71`), so a second process printing over the operator's typing is the same defect.

⛔ **This was previously ruled "working as intended" and that ruling is reversed.**
`issues/2026-08-11-hid-drain-rearm-and-isr-console-lock.md` argued a fix would mean muting logs at boot.
It would not: save-erase-replay hides nothing and defers nothing. The ticket is corrected in place.

### Added — `console-line-preserve-test.py`, the sweep's first FRAMEBUFFER oracle (gate 19)

Types a partial command at the prompt, fires the mouse one-shot **while it is on screen**, and requires
the last console row to be **pixel-identical** before and after — the row is expected to move, so content
is compared, not position. No glyph decoding: OCR would need a second copy of the kashi font in Python,
which is the "two implementations of the same idea" trap.

⛔ **It must be a framebuffer oracle.** In serial a log line and a typed line are two ordered writes and
look perfectly correct — **which is exactly how this defect was diagnosed from a serial log and mis-ruled
for two months.** Mutation-tested: reverting the `kprintln` wrap fails it with 10,296 differing bytes.
⚠ Two non-vacuity gates: the one-shot must actually have fired (else INCONCLUSIVE, never a pass), and the
framebuffer must have changed at all (else a kernel that dropped the log entirely would pass). The
row-COUNT check that seemed obvious is wrong and was red on first run — the console is already scrolling
by the time the prompt appears (57 text rows, last row pinned at 63 of 64), so a printed line shifts the
screen up and never changes the count.

### Nothing else has been started in this cut.

⚠ Edits carrying this version exist, and they are all consequences of the 1.56.44 burn rather than new
work: six sites across `kernel/core/`, `kernel/shaders/`, `tests/gpu/` and `scripts/check/` asserted
*"`blend_alpha` HAS NOT BEEN BURNED"* / *"these bytes have never run on hardware"* — false as of
2026-08-16 — and the gate promotion those sites describe (crossasm → shaderasm, plus the partition
assertion that keeps the emptied list from passing vacuously) is the burn's direct result. Both are
recorded under **1.56.44**, where the evidence belongs, not restated as 1.56.45 deliverables.

⛔ **Kernel state is UNCHANGED.** No `.cyr` edit in this cut alters emitted code — the only executable
difference from 1.56.44 is `kernel/version.cyr`'s banner literal, which the bump regenerates.

---

## [1.56.44] — 2026-08-13 — the sovereign shader pipeline, and `#92` op 0x06 on iron (RELEASED 2026-08-16)

### Iron-proven — `#92` op 0x06 `GPU_OP_BLEND_ALPHA`, archaemenid 2026-08-16

`#89 gpu_caps` byte +28 reported **`0x1FF5F`** (bit 6 set; `GPU_OP_NOTIMPL_MASK` is `0x0000`). Ring 3
issued op 0x06 and `blend_alpha`'s 69 dwords composited a translucent client surface across **244** and
**537** frames, no `GPO_E_*`, no demotion. `gpu.cyr`'s `blend_alpha_write` is committed, burned hex.

Gate moved with the evidence: `blend_alpha` leaves `scripts/check/shader-crossasm.sh` (two host
assemblers agreeing) for `tests/gpu/shaderasm.cyr` (emit list vs the burned hex) — **69/69 dwords
byte-identical, VGPR 13/14, SGPR 21+1 == 22 exact**. `shader-crossasm.sh`'s `UNBURNED` list is now
empty and asserts that every `kernel/shaders/emit/*.emit.cyr` is gated exactly once, so an emit list
added and wired to neither gate fails instead of passing through an empty loop.

⛔ **The rounding tie is NOT settled by this burn.** 5,905 in-range premultiplied ties exist and
round-half-even vs round-half-away differ on 3,010 outputs; nothing visible on a desktop distinguishes
±1 on a channel. `blend_alpha.s`'s RTNE assumption stands on `.amdhsa_float_round_mode_32 0` and on no
hardware evidence.

### New — `tests/gpu/shaderexec.cyr`: the first thing in agnos that EXECUTES a shader

A single-lane GFX9 interpreter over a shader's own dword stream. ~20 opcodes, 4 gates, 0.4 s.

⛔⛔ **Every other gate in this tree is about ENCODING.** `shaderasm` proves an emit list packs the same
bits as committed hex; `shader-crossasm` proves two assemblers agree. **Neither computes a pixel.** For `blend_alpha` that meant
14 dwords changed and the number constrained *semantically* by any host gate was **zero**.

The sharpest demonstration: deleting `blend_alpha`'s entire 4-dword prologue and re-running the
arithmetic model at α=255 scores **0 mismatches over all 16,777,216 cases** — because at α=255 the
correct answer *is* `blend_rect`'s, so "equals blend_rect" is satisfied by "the feature is absent".
shaderexec refuses that shader at byte **+112** on an uninitialised `v13`.

⭐ **The calibration is the tree's first with independent provenance on both sides**: `blend_rect`'s
iron-burned hex, interpreted, against `blend_ref_px` — **pure integer** arithmetic
(`sc + ((dc*ia)*2 + 255)/510`) written years earlier for the kernel's own self-test. Neither derived
from the other, so an interpreter bug fails there before it can flatter an unburned shader.

⭐ **Gate 3 runs `blend_alpha` from its EMIT LIST**, so this is the only artifact whose verdict depends
on what that list actually encodes rather than on what it equals.

**Four findings from building it, each a defect in my own work first:**

1. ⛔ **Whole-register initialisation tracking rejected a shipped shader.** It faulted at `+144` of
   `blend_rect` on `v_cvt_pk_u8_f32 v11, v9, 0, v11`, which reads `v11` before anything writes it. The
   read is real and benign — the four channel packs each replace one byte. Tracking is now **per byte**,
   which states the property that matters: *the store must not write an undefined byte*. The coarse
   model being wrong about a shader we know is right is exactly the calibration's job.
2. ⛔ **`var x = <f64 expression>` without an explicit `: f64` compiles to INTEGER semantics, silently.**
   `var frac = x - f64_from(n)` ran in integers, `frac` came out 0 instead of 0.8666, and `sx_cvt_u8`
   returned 49 where 50 was correct. The f32 arithmetic around it was bit-exact throughout, so it
   looked like a rounding disagreement rather than a type error. The only signal is a
   `comparison mixes f64 and integer operands` warning — which I had been filtering out of build output.
3. ⛔ **A function-local `var b[16]` overran its frame** — 16 BYTES, not 16 slots — and SIGSEGV'd.
   `check-array-sizing.sh` named it exactly: *"LOCAL var b[16] = 16 BYTES but a store64 reaches byte
   18"*. The gate doing its job on the person who should have known better.
4. ⛔ **The harness's address path was degenerate and a mutation exposed it.** With tgid pinned to
   (0,0) and both pitches 0, `s_mul_i32 s11, s9, s4` computed `0*0`, and replacing that multiply with
   an ADD left the oracle **fully green**. That is the exact code path `blend_alpha`'s `s9 → s15`
   relocation exists to protect. Now `tgid_y = 1`, `pitch = 16`, and the base pixels are poisoned with
   `0xDEADBEEF` so an address collapsing to its base reads garbage instead of accidentally reading
   right. The same mutation now reports **58,412 mismatches**.

**Mutation-tested, all five red:**

| mutation | caught by | reported |
|---|---|---|
| the fatal `s15 → s9` clobber in the emit list | gate 3 | 59,319 / 59,319 mismatches |
| emit list scales dst instead of src | gate 3 | 59,319 mismatches |
| `s_mul_i32` → `s_add` | gate 1 | 58,412 mismatches |
| `s_add_u32` → `s_sub` | gate 1 | 59,319 mismatches |
| `v_cvt_f32_ubyteN` reads the wrong byte | gate 1 | 59,319 mismatches |

### New — gate 4: the rounding tie, which nothing else in the tree reaches

⛔ **Added because a mutation FAILED to fire.** Deleting the ties-to-even branch left gates 1 and 3
fully green — correctly, since `blend_rect` provably never produces a half-integer and gate 3 drives
only α=255 (identical to blend_rect) and α=0 (no rounding). **The tie rule was exercised by nothing.**

`blend_alpha` does reach it. Gate 4 pins the documented witness — α=4, sa=64, sc=64, dc=128, where
`t = 128.5` exactly — and asserts RTNE gives **128**. With the tie branch removed it reports 129 and
exits 90. ⚠ This **pins an assumption so a burn can refute it** rather than leaving it unstated; there
is no hardware evidence either way, because the tree's only datum (249 → 250) is a tie where 250 is even.

⚠ **Corpus is STRIDED and the reduction is printed, not hidden**: 39 values/axis (stride 8 + boundary
set) = 59,319 cases/gate. The exhaustive 256³ run was done once — **0 mismatches on all three gates,
119 s**. It is not what ships, because 119 s against this runner's 3 s makes a gate people skip. Set
`SX_STRIDE` to 1 to reproduce. ⚠ The tie is the one genuinely input-sparse property, which is why its
witnesses are pinned explicitly rather than left to the stride.

### New — the `blend_alpha` worker: blob, arm, surface, and a generalised dispatch primitive

`blend_alpha_write` (69 dwords, **generated by llvm-mc and pasted mechanically, never typed**),
`gpu_blend_alpha_arm`, `gpu_blend_alpha_surface`, and the `gpo_execute` branch. Kernel 1,981,080 →
**1,985,672 B · `d8079e80e1cd3284`**. Arena slot `GPU_BALPHA_SHADER_SUBOFF = 0x5F000` — proven free by
walking sorted extents (`TRID` ends exactly there, `BR_SRC` starts at `0x60000`), the method this tree
mandates after two by-eye collisions.

⭐ **ONE dispatch implementation, two arities.** blend_alpha needs an **eighth** USER_DATA dword (alpha
at `s7`) and `RSRC2 = 0x190` instead of `0x18E`, and `gpu_grid7_run` hardcoded both. Rather than clone
40 lines of iron-proven PM4 into a never-burned path, both arities now route through
`gpu_grid_dispatch`. ⚠ `gpu_grid7_run` keeps its exact signature, so all **seven** existing callers —
every one on a burned path — are untouched by construction.

⚠ **The 7-dword emission is unchanged BY CONSTRUCTION, NOT BY MEASUREMENT**, and that distinction is
the honest one: `n_user == 7` takes the identical branch with the identical constants, but **no host
gate observes what this function actually puts in the ring.** See the pm4lint note below.

⚠ The PM4 count lives in the packet **header** as well as the payload — `N7` and `N8` are different
packets, so emitting `N7` then 8 dwords would desynchronise the ring for everything after it.

⛔ **The branch is unreachable and lands anyway**, per this file's own rule at the EDGE_COV branch:
*"so this file never contains a supported op with no execution path, which is how GPO_E_BADOP would
surface as a mystery at the wrong layer."* With bit 6 in NOTIMPL, pass 1 refuses every record before
`gpo_execute_all` runs.

### Fixed — the committed hex had no gate tying it to anything

Three artifacts now describe `blend_alpha`: the `.s`, the emit list, and the committed hex.
`shader-crossasm.sh` ties the `.s` to the emit list; `shaderexec.cyr` executes the emit list. **Nothing
tied the committed HEX to either** — it could have drifted silently. `blend_alpha` added to
`shader-blob.sh`'s list, which is hex-vs-`.s`. ⚠ Verified by corrupting one committed dword *before*
adding it: `check.sh` stayed fully green at 28/28. After: 27 passed, 1 failed.

⚠ Also caught by the extractor rather than by me: the generated blob was first emitted with the offset
**left-padded** (`dst_phys + 0  ,`), and `shader-tables.sh`'s regex requires digits immediately before
the comma — so only 3-digit offsets matched and it reported *"dword 0 is at offset 100"*. Padding goes
after the comma, as every other table does.

### New — `pm4lint` wired: the third oracle this cut found sitting unwired

A mutation-calibrated host PM4 decoder, written (its own header) so that *"every later rung in this arc
emits packets, and each one wants to say 'the stream is well-formed' before it costs a burn"*. It
self-reports **"all 12 mutants rejected"** — genuinely falsified — and nothing had ever run it. 17 → 18
oracles.

⛔ **Honest scope, and it decided how the worker was built.** pm4lint checks a stream **transcribed by
hand from `gpu_matmul_run`**, not the live emission. It validates the decoder and the packet
invariants; it does **not** observe what `gpu_grid_dispatch` puts in the ring, and would not move if
that were wrong. A gate on dispatch emission does not exist — building one needs a host-side ring stub
the kernel's kmode build cannot currently provide. That absence is precisely why the 7-arity call sites
were left untouched instead of refactored.

### New — the `#92` ABI battery now RUNS, and gained its first coverage of ops `0x01`-`0x04`

⛔⛔ **It was not merely unrun — it was BLIND.** `edge_abi_selftest` sits behind
`#ifdef EDGE_ABI_SELFTEST`; nothing set it; `edge-abi-smoke.sh` is one of **68 of 83** smoke scripts
missing from `sweep.sh`'s table. And **zero of its 152 cases constructed an op in `0x00`-`0x04`**, so
`gpo_validate`'s shared generic tail — reserved sweep, dimensions, bounds, slot, slot-size, arming —
was executed by no case at all, while four shipped ops depend on it.

**152 → 167 cases.** Two are the first coverage that tail has ever had; thirteen exercise op `0x06`.
Wired into `sweep.sh` and verified end to end under QEMU: **167 of 167, smoke exit 0.**

⭐ **The regression guard.** A well-formed `GLYPH_1BPP` record carrying a real title colour
(`0xFF3060A0`) at dword 9. Had the alpha range check been written unguarded in the shared tail, this
case fails — and without it, aethersafha's chrome text would have fallen to the CPU permanently while
the battery printed `152 of 152 cases correct`.

⛔ **And wiring it in would have created a gate that reports PASS while failing.** `sweep.sh:40`
detects success with `grep -qiE "smoke.*PASS"` — **case-insensitive** — and the old failure line read
`edge-abi-smoke: 150 passed, 18 failed`, which matches. Verified by feeding sweep's exact grep the old
string. Success now says `PASS`; failure says `FAILED … N correct, M wrong`, so no substring can be
mistaken for a verdict.

⚠ **Three defects of my own, each caught by an existing gate rather than by me:**
- `kprint-len-check.sh` caught **4** wrong string lengths in the new cases.
- The first draft used **slot id 14** for a 1024-byte source. Slot IDs are **1-based**
  (`shm_slot_valid: slot = id - 1`), so id 14 is index 13 — a **256 B** slot — and the well-formed
  case took a `GPO_E_SLOTSIZE` reject I initially read as a bug in the op. The file warns about the
  1-based convention at exactly that spot. It also needed a **reseed**: an earlier restore loop zeroes
  slots 10-15 before this section runs.
- I claimed 16 new cases; there are **15**. The battery reported `167 of 168` and corrected me.

### New — `#92` op **`0x06 GPU_OP_BLEND_ALPHA`** minted (validator half); worker still to come

Premultiplied src-over with a **uniform per-surface alpha 0..255** — the kernel side of aethersafha's
M6-C3 per-window opacity. `GPU_OP_SUPPORTED` `0x1FF1F` → **`0x1FF5F`**, `GPU_OP_NOTIMPL_MASK` →
**`0x0040`**. Field mask `0x0237` (BLEND_RECT's `0x0037` plus dword 9), slot rules identical to
BLEND_RECT. Kernel 1,980,696 → **1,981,080 B** (+384).

⭐ **`0x06`, not `0x11`** (operator's call, and it is the better one). `0x11` is mechanically free but
sits inside the reserved `0x10-0x17` CP-DMA lane, and `gpu.cyr` states that minting `0x10`/`0x11`
requires a domain state machine that was never written. This op is a **shader dispatch** and adds no
engine-domain transition, so it belongs in the composite lane `0x00-0x07` with its siblings. ⚠ Crucially
`0x06`'s "cov-modulated source" reservation has **zero blob behind it**, whereas `0x05` and `0x07` have
`perm_write` and `blend_pk_write` — already-committed, iron-proven blobs — waiting for their codes.
Taking either of those would have displaced a burned shader.

⛔ **The alpha range check is OP-GUARDED, and that is not defensive style.** `gpo_validate`'s generic
tail is **shared** by `0x01`-`0x04` (the delegation block only redirects `0x08`+), and for
`0x02`/`0x03`/`0x04` dword 9 is `color0`, a full 32-bit ARGB. aethersafha writes a real title colour
there (`src/gpu.cyr:670`). An unguarded `> 255` reject would refuse every non-near-black glyph run,
latch `ae_text_gpu_disable()`, and drop **all chrome text to the CPU permanently, every boot**.

⚠ **The check and the shader's byte lane are load-bearing on each other.** blend_alpha reads alpha with
`v_cvt_f32_ubyte0` — **byte 0**. Without the reject, `alpha = 0x100` (a caller meaning "opaque", off by
one) silently drops bits 8..31 and renders **fully transparent**. New `GPO_E_ARANGE = 35`, its own code
rather than `GPO_E_RESERVED` — dword 9 is a *defined* field here, just out of range.

⭐ **NOTIMPL is now read from the mask instead of hard-coded.** Every prior NOTIMPL op returned a literal
from its own validator, leaving the mask and the return as two hand-edited facts with nothing diffing
them — a discipline that has already slipped in this file (`:3505` still claims bit 15 is masked; it
cleared when `tri_persp` landed). BLEND_ALPHA has no dedicated validator, so its refusal reads
`GPU_OP_NOTIMPL_MASK` directly: clearing bit 6 when the burn lands removes it in the **same edit**.
Both moves or neither, enforced by construction rather than by memory.

Caps arithmetic verified: `SUPPORTED & ~NOTIMPL` = `0x1FF1F`, **bit 6 clear** — the validator reaches
the op so its field rules are testable, and `#89` never tells ring 3 it works.

### ⛔ Not done, and both matter

1. **No worker and no `gpo_execute` branch.** With NOTIMPL set, pass 1 refuses every record before
   `gpo_execute_all` runs, so nothing is reachable — but `syscall.cyr:4154` records the tree's rule
   that a branch is written anyway *"so this file never contains a supported op with no execution
   path, which is how GPO_E_BADOP would surface as a mystery at the wrong layer."* That needs
   `blend_alpha_write` (the 69 committed dwords), `gpu_blend_alpha_arm` and `gpu_blend_alpha_surface`.
   ⚠ The USER_SGPR 7 → 8 change means the arming path pushes an eighth USER_DATA dword — check whether
   a shared helper is involved before copying `gpu_blend_arm`.
2. ⛔ **The ABI battery is BLIND, not merely unrun.** `edge_abi_selftest` sits behind
   `#ifdef EDGE_ABI_SELFTEST`; nothing sets it, and `edge-abi-smoke.sh` is one of **68 of 83** smoke
   scripts absent from `sweep.sh`'s table. Worse: **zero of its 152 cases construct an op in
   `0x00`-`0x04`**, which is precisely the shared tail this change edits. A kernel carrying the
   *unguarded* range check would have printed `152 of 152 cases correct` and shipped. Wiring and
   calibrating it is the next bite, not a follow-up.

### Fixed — `scripts/check/shader-derive.sh` was cited in five files and never written

⛔ **A gate named in the present tense that does not exist.** `blend_alpha.s:12` said *"The derivation is
machine-checked by `scripts/check/shader-derive.sh`"*; `blend_alpha.emit.cyr`, `host-gpu-oracles.sh`,
`shaderexec.cyr` and an earlier entry in this very changelog all repeated it. **The script was never
created.** This is the identical defect this cycle found twice in older work — `edgeasm`/`asmagree`
cited by `shader-blob.sh` while unbuildable, and `stage-tools.sh` staging a fossil — committed here by
the same hand that found those.

⚠ **Corrected by naming what actually runs, not by writing the script.** `shader-crossasm.sh` (two
independent assemblers, 69/69 dwords) and `shaderexec.cyr` (executes the bytes; the `s9` clobber shows
as 59,319 mismatches) already cover the correctness a derive gate would have. The 9-inserted/5-changed
decomposition is now labelled **documentation, verified once by machine diff on 2026-08-13 and not
re-checked per build** — which is what it always was. Building a gate to make a stale comment true
would have been building the wrong thing.

### New — `blend_alpha`: the shader for per-window opacity, authored and cross-checked, NOT burned

`kernel/shaders/blend_alpha.s` + `kernel/shaders/emit/blend_alpha.emit.cyr` — blend_rect plus a uniform
per-surface alpha. **55 instructions, 69 dwords, 276 B.** Zero new instruction formats. The kernel does
not include it and there is no committed `blend_alpha_write`; `build/agnos` is byte-identical.

⛔⛔ **THE FIFTH CHANGED DWORD, WHICH TWO ANALYSES MISSED.** Taking `s7` for `alpha` pushes USER_SGPR
7 → 8, moving the TGIDs `s7`/`s8` → `s8`/`s9`. Four dwords **read** a TGID and obviously follow. The
fifth **writes** `s9` as the column scratch — and under the new layout **`s9` IS tgid_y**, so it would
destroy the row index before the two `s_mul_i32 …, s9, pitch` reads consume it. Column group 0 would
write row 0 for every y. **It assembles clean, matches its own blob byte for byte, and faults nothing.**
The scratch moves to **s15**, the only unused SGPR below the saved-EXEC pair (blend_rect touches
s0–s14, s16–s20, skipping 15 so `s[16:17]` lands even-aligned).

⚠ The prior design said the diff was "9 inserted, **0 changed**"; a first correction made it 9 + 4 by
grepping for TGID *sources*. Both were wrong because a **destination register number** can collide with
a relocated TGID. Measured decomposition: **55 equal · 9 inserted · 5 changed · 0 deleted.**

⚠ **SCC is load-bearing between the address pairs** — `s_add_u32` sets it, `s_addc_u32` consumes it,
and `s_lshl_b32` also writes it. All nine insertions are placed outside those pairs; inserting between
`s12`/`s13` or `s18`/`s19` would drop a 64-bit carry silently.

⭐ RSRC1 is **`0x002C00C3` — bit-identical to blend_rect's**, so no new constant. VGPR high-water
v12 → v13 and SGPR s20 → s21, both inside their granules. RSRC2 becomes `0x00000190`, which already
exists as `GPU_COMPUTE_RSRC2_COV`. Read out of llvm-mc's emitted kernel descriptor, not derived.

### New — `scripts/check/shader-crossasm.sh`: two independent assemblers, for a shader with no hex

`shaderasm` checks an emit list against **committed, iron-proven** hex — evidence about reality. An
unburned shader has no such expectation, and reaching for shaderasm anyway would compare two host
artifacts written the same week from the same story.

⭐ So `blend_alpha` is assembled **twice**: the `.s` through **llvm-mc**, the emit list through
**mabda's Cyrius encoder**. Two implementations by different people for different projects, neither
derived from the other. **All 69 dwords identical**, zero wrapper faults, register high-waters exact
(v13 vs declared 14, s21 vs declared 22).

Mutation-tested from **both** sides, each red: perturbing the `.s` to scale dst instead of src
(`0a14150d` vs `0a12130d`), and reverting the emit list's `s15` back to the fatal `s9`
(`8e098608` vs `8e0f8608`) — that second one is the collision above, caught mechanically. Forced red
*through `check.sh`* to confirm the run still reaches `27 passed, 1 failed` rather than aborting under
`set -e`, per that file's own standing requirement.

⚠ **This is an ENCODING gate and nothing more.** Both sides encode the same instruction sequence; if
that sequence is semantically wrong, they agree and are both wrong. It narrows a burn's search space,
it does not replace one.

### Open — two `blend_alpha` questions only a burn can settle

⛔ **The tie rule is newly reachable.** blend_rect never had to answer round-half-even vs half-away —
`gpu.cyr` states the tie is unreachable for it (`t = 255k + 127.5` is never an integer). blend_alpha
**reaches it**: 5,905 in-range premultiplied ties, on which the two rules differ for **3,010** outputs
(e.g. α=4, sa=64, sc=64, dc=128 → `t = 128.5` exactly; RTNE → 128, half-away → 129). ⚠ The tree's only
burn evidence does **not** discriminate: burn 1's 249 → 250 is a tie where 250 is even, so both rules
agree there. This assumes RTNE, matching `.amdhsa_float_round_mode_32 0`.

⚠ **The α=255 zero-tolerance oracle is powerful on IRON and vacuous on the host.** Deleting the entire
prologue from the CPU model still scores **0 mismatches / 16,777,216**, as does a 1-ULP-low reciprocal —
because at α=255 the shader is *supposed* to equal blend_rect, and "equals blend_rect" is satisfied by
"the alpha feature is absent". On hardware it exercises the real s7/s8/s9 plumbing and is a genuine
zero-tolerance gate; as a host check it carries no information about the feature.

### New — SGPR high-water tracking in `asmlib.cyr`, with an equality calibration that can actually fail

The peer of the VGPR tracker, and harder in three measured ways.

⛔ **Destination width is per-(format, opcode), and the opcode spaces overlap.** Raw op `0x20` is
`s_and_saveexec_b64` in SOP1 (writes **2**) and `s_ashr_i32` in SOP2 (writes **1**) — both live in this
tree, in the same function 27 lines apart. One shared `is_pair_op(op)` helper is wrong for one of them
by construction, and guessing "single" under-counts `s_and_saveexec_b64`, the sole high-water setter on
`edge_cov` and `glyph_1bpp`. **Two separate tables.** No parity shortcut exists either: SOP2 `0x28`
(`s_bfe_i64`) is even and writes 2.

⛔ **Reads count.** `next_free_sgpr` is a file allocation, not a write set — `matmul_copy` writes zero
numbered SGPRs (s0..s3 arrive as user SGPRs, read only) yet declares nfs=4. A write-only tracker reports
−1 there and authorises declaring 0.

⛔ **Reserved codes must not raise the watermark.** Six live call sites pass `126` (EXEC_LO) or `106`
(VCC) in the destination field. Tracking 106 would demand `next_free_sgpr ≥ 108` against a measured
maximum of **102** (llvm-mc rejects 103). The filter is on the **value**, not the spelling — the tree
passes both the bare literal `106` and the symbol `VCC` for the same thing.

⚠ Every width was **decoded, not recalled**: each opcode synthesised, its `sdst` field varied 20→40,
and the operand that *responded* read out of `llvm-mc 22.1.8 -disassemble`. Reading the first printed
operand instead is wrong and was tried first — `s_setpc_b64` prints a source there and would be classed
a 2-wide destination. VOP3's scalar/vector boundary is exactly `op < 0x100`, swept with zero violations
either side.

⭐ **A live defect this found:** `e_vop3` ran `ea_vtrack(vdst)` unconditionally, so `edge_setup`'s
`v_cmp_ne_u32_e64 s[24:25], 0, v16` recorded **SGPR 24 as v24** — in the wrong register file. Masked
only because edge_setup was budgeted against another shader's 56-VGPR descriptor.

**Calibration asserts equality, not `<`.** ⛔ `<` structurally cannot detect an under-counting tracker:
a tracker that misses registers reports a *lower* high-water, which passes `<` more easily.

⛔⛔ **And the RSRC1 derivation cannot substitute for it — measured, this is why the derivation was
descoped.** A width-blind tracker (exactly the pair-write bug this instrumentation exists to prevent)
moves the RSRC1 SGPRS field on **0 of 20 shaders**. Largest width-blind error in the corpus is 3
(`tri_depth`) against a granule slack of 5; `blend_rect`'s slack is 2. Separately, **E=5 and E=6 both
fit all 20 shipped constants**, because no shipped shader has `nfs ≡ 3 (mod 8)` — so a `+5` derivation
would pass 20/20 and under-declare by a full granule for one in eight future shaders, in the corrupting
direction. A green derivation would have been read as calibrating the tracker and shipped the bug.

**Three rules have a natural witness, each proven red by mutation, each naming a different shader:**

| mutation | goes red on | reported |
|---|---|---|
| `ea_sop1_dwidth(0x20)` → 1 | `edge_cov` | `high-water s20 => next_free_sgpr 21, but the shader declares 22` |
| `ea_sop2_dwidth(0x0B)` → 1 | `tri_rgba` | `s46 => 47, declares 48` |
| revert `e_vop3`'s `op < 0x100` | `edge_setup` | `s24 => 25, declares 26` |

### New — `edgeasm` gate 6: the five tracker rules the shipped corpus cannot witness

SMEM `sdata` width, SMEM `sbase` pair, VOP3b `sdst` pair, `S()` read folding, `S2()` 64-bit reads,
`e_sop1_lit`, `v_readfirstlane_b32`, and the reserved-code filter are exercised by **nothing** in the
20 shaders — tri_rgba's widest `s_load_dwordx4` tops out at s43 under a high-water of 47, all seven
SMEM call sites pass base 0, and every carry-out in the corpus goes to VCC. A rule with no witness is
an assumption wearing a test's clothes.

10 synthetic cases, **each falsified**: deleting any one instrumentation line moves exactly one number
(`SMEM x4: s40 want s43` · `sbase: s3 want s31` · `VOP3b: s-1 want s31` · `S(): s-1 want s37` ·
`S2(): s62 want s63` · `e_sop1_lit: s-1 want s20` · `readfirstlane: s-1 want s7` · `reserved filter:
s126 want s101`).

### New — `scripts/check/shader-decls.sh`; oracles no longer type a number they also check

Register budgets are extracted from `kernel/shaders/*.s` into a generated, gitignored
`tests/gpu/gen/shader_decls.cyr`. ⚠ A typed budget is a second copy of the `.s`, and **`edgeasm`
shipped exactly that drift** — see the `edge_setup` fix below. Refuses rather than defaults on a shader
with no declaration: emitting 0 would hand every oracle a budget that always passes.

### Fixed — ⛔ `edgeasm`'s tri_rgba gate passed a shader with NO `s_endpgm`

`tri_check` loops `while (i < n)` where `n` is the emitted length, and the **only** place `n` was ever
compared to the 269-dword table was an exemption block that `return 1`-ed whenever `n < TRI_N_TOTAL`.
So a short emit checked fewer dwords, found no divergence, and passed. Measured — deleting the trailing
`s_endpgm` from `tri_emit`:

```
tri_rgba: 268 of 269 dwords re-emitted, 268 agree
exit=95
```

**A shader missing its program terminator, which on hardware runs off the end of its blob, was green.**

⚠ The exemption's rationale was real — a forward branch cannot match until its target exists, so during
authoring a partial emit legitimately differs in the offset field — and its own comment said it
*"expires on its own"* once complete. It has emitted 269 of 269 for some time. **An expiry nobody
executes never happens.** Length is now a hard assertion; the same mutation exits 90 with
`LENGTH MISMATCH (a short emit is not a partial pass)`.

### Fixed — `edgeasm` budgeted `edge_setup` against a different shader's descriptor

`ea_vgpr_check(56, "edge_setup")` under a comment claiming edge_setup and edge_cov *"SHARE RSRC1
(0x002C00CD, 56 VGPRs)"*. They do not: `gpu_regs.cyr:1408` `_ESET = 0x002C00C7` → VGPRS field 7 = **32
granted**; `:1409` `_EDGE = 0x002C00CD` → field 13 = **56**. The `.s` files agree (32 vs 56) and the two
dispatch separately. ⇒ 24 registers of untested growth, in the file about to become the template for
the SGPR gate. Now checked against **32** — and that budget has **zero slack**: it holds at 32 and goes
red at 31, because edge_setup's true high-water is **v31**.

### New — `scripts/check/check-dup-symbols.sh`, and `edgeasm` now shares `asmlib.cyr`

`edgeasm.cyr` carried its own copy of the print helpers, asserting wrappers, VGPR tracker and
label/fixup pass — **236 lines** that `asmlib.cyr` now owns and `shaderasm.cyr` shares. Two copies of a
verification layer is the one duplication that cannot be tolerated: they drift, and the drift is
invisible precisely because both files are what you would use to detect drift. Output after the swap is
identical to before, modulo `** edgeasm:` → `** asmlib:` on the refusal lines.

⛔ **The gate exists because cycc's duplicate-symbol behaviour is not uniform.** A duplicate `fn` warns;
a duplicate **`var` produces no diagnostic at all**, even at conflicting array sizes (probed directly,
cycc 6.5.20). The two files shared **46 top-level symbols, 13 of them `var`** (four arrays: `isa`,
`lab_off`, `patch_off`, `patch_tgt`). Measured on the collided tree: cycc mentioned **33** and reported
**OK** — and `host-gpu-oracles.sh` discards build output on success, so in practice all 46 were
invisible. ⚠ **Honest limit:** I could not demonstrate that this corrupts memory — several probe shapes
left the adjacent symbol intact. The justification is silent, undiagnosed duplication with a layout the
source does not determine, which is disqualifying on its own for a verification tool.

⚠ Sibling of `check-array-sizing.sh`, different scope — that one inspects function-LOCAL arrays and
structurally cannot see this class.

### Changed — `MABDA_REF` 4.0.8 → **4.0.9**; all three sovereign-encoder oracles hold across the bump

Verified a real remote tag against mabda's own `VERSION` on a clean tree. `edgeasm`, `asmagree` and
`shaderasm` all still exit 95 — independent cross-repo confirmation of 4.0.9's own claim that no encoder
output changed, from a tree that did not write the release.

⚠ The pin comment previously anticipated **4.1.0** landing `gfx9_rsrc1_ex` "because agnos's corpus found
that `gfx9_rsrc1` under-allocates SGPRs". **That finding was false and is retracted** (see below); 4.0.9
is what an actual investigation produced instead. The four opcode constants agnos holds under `AG_` in
`asmlib.cyr` were not part of it and remain agnos-local.

### Measured — the uniform-alpha blend model, exhaustively, before any shader exists

Host-side determination of the three properties that decide whether `blend_alpha` (M6-C3's `#92` op
`0x11`) can be burned against a **zero-tolerance** oracle or needs a ULP budget. All exhaustive, not
sampled:

| property | space | result |
|---|---|---|
| `alpha=255` output bit-identical to `blend_rect` | 256³ = **16,777,216** | **0 differing** |
| `alpha=0` leaves dst byte-untouched | 256³ | **0 perturbed** |
| premultiplication `c ≤ a` survives scaling | 5 alphas × 256² | **0 violations** |

⭐ The identity holds because `0x3B808081` is the correctly-rounded f32 nearest 1/255 (rel err +5.9e-8)
and **`255 × 0x3B808081` rounds to exactly `1.0f`** — so `v_mul_f32(x, fa)` at alpha=255 is the exact
identity and every channel falls through unchanged. ⇒ **the iron burn gets a zero-tolerance gate for
free**, rather than blend_cov's `≤ 1 ULP, max printed` discipline.

⭐ Also settled, because the model implementation depends on it: **f64-multiply-add-then-narrow is
bit-identical to true single-rounding f32 FMA over this shader's entire input space** — verified against
an 80-bit reference across **all 4,294,967,296** `(alpha, dc, ia, sc)` combinations, 0 mismatches. So a
Cyrius model can use `f64` plus the `f32_from` narrowing builtin and be exact, with no FMA emulation.

⚠ **These are host determinations, not yet a committed gate.** `tests/gpu/alphamodel.cyr` — the Cyrius
oracle that puts them in `check.sh` — lands with the shader itself.

### Fixed — the `+6 = VCC(2) + XNACK(4)` SGPR-granting rationale is wrong, in five files at once

⛔ **agnos has documented a false mechanism for its own RSRC1 constants since rung 17.** Measured with
llvm-mc 22.1.8, solving `E` in `granted = roundup8(next_free_sgpr + E)` **uniquely** over
`next_free_sgpr = 1..39` on gfx90c:

| configuration | E |
|---|---|
| bare `gfx90c`, all defaults — what every agnos `.s` asks for | **6** |
| `.amdhsa_reserve_xnack_mask 0` alone | **6 — UNCHANGED** |
| `.amdhsa_reserve_flat_scratch 0` alone | 4 |
| both waived | 2 |

**XNACK contributes 2, not 4, and is invisible while flat scratch is reserved** — they overlap at the top
of the register file. So for agnos's configuration the dominating term is **FLAT_SCRATCH**, and XNACK is
not the discriminator at all. ⚠ agnos's kernels use **no scratch whatsoever** — no `scratch_`/`flat_`
instruction in any shader, every shipped RSRC2 has bit 0 clear, and `COMPUTE_TMPRING_SIZE` has never been
written — so the +6 is simply LLVM's conservative default for hand-written asm, not a property of the
silicon.

Corrected in `gpu_regs.cyr:1375`, `planning/gpu.md`, `planning/rung17-tri-depth.md`, `tri_persp.s` and
`tri_depth.s`. ⚠ **The rule shape and the "harvest, never hand-count" conclusion both STAND** — only the
cause was false. Also fixed in passing: `gpu_regs.cyr` called `tri_persp` "56 SGPRs" when `0x002C01C7` is
field 7 = **64** (`0x002C0187` is field 6 = 56). Binary byte-identical; `shader blobs match their .s
sources` still passes.

⚠ **This is what a rationale copied between documents rather than re-measured looks like** — one wrong
sentence propagated to five files and then out of the repo entirely, as the retracted mabda finding below.

### Retracted — the reported mabda `gfx9_rsrc1` bug does not exist

An earlier entry in this cycle (and a roadmap row, now marked FALSIFIED) claimed mabda's
`gfx9_rsrc1` under-allocates SGPRs. **It does not. mabda is correct and no PR should be opened.**

The error was using agnos's own committed constants as the oracle for whether another project is wrong.
`llvm-mc` is not an oracle for the *correct* SGPR grant — it emits whichever reservation policy you
declare, and it emits **both** numbers from the same shader file: `0x002C00C3` (SGPRS 3) under bare
gfx90c defaults, `0x002C0083` (SGPRS 2) under `xnack-` + `reserve_flat_scratch 0` — mabda's exact value.
Both are arithmetically correct for their policy.

⇒ **agnos over-declares by one 8-SGPR granule on 5 of 20 shaders** (`blend_pk`, `blend_rect`,
`grad_linear`, `glyph_1bpp`, `edge_cov` — not "3 of 6"). Over-declaration costs occupancy and nothing
else, and nothing can detect it in either direction. **agnos changes nothing.**

⚠ Also corrected: the "562 call sites" figure quoted against `gfx9_rsrc1` was wrong wherever it came
from — `gfx9_rsrc1` has **one** production call site (`mabda/src/gfx9_compile.cyr:958`) plus 5 test
assertions, and `gfx9_enc_*` occurs 218 times in mabda's `src/`.

### Changed — cyrius pin **6.4.78 → 6.5.20**; the kernel was already being built by 6.5.20

⛔ **The pin was documenting nothing and gating nothing.** Every build in this tree emitted
`cyrius.cyml pins 6.4.78 but cycc is 6.5.20 — toolchain drift`, and the rebuild at the corrected pin is
**byte-identical** — 1,980,696 B · `6c256bc62719ec26` before and after. That is the proof, not a null
result: the shipped artifact had been produced by a compiler three minors ahead of the declared floor,
so the manifest described a build that was not happening.

⚠ **This is a recurring failure, not an incident.** The pin's own 6.4.74 comment records the identical
sequence in July — *"The pin had lagged at 6.4.2 while the INSTALLED cycc actually built the kernel
warn-only."* The mechanism is that the warning is tolerated as noise until someone bumps it. Re-check
at every cut.

`tests/gpu/cyrius.cyml` moved in the same edit, as its own header mandates: ring-3 GPU tools built by a
different compiler than the kernel they exercise would surface a codegen difference as a GPU bug.

⭐ **And that re-materialised `tests/gpu/lib/` — 12 stdlib files, +1012/−70 — which was carrying real
defects and real gaps, not cosmetics.** The snapshot had been frozen at a 6.4.78-era stdlib:
- `print_num` mishandled `i64::MIN` (`0 - n` is a no-op there, so the `n > 0` loop emitted **zero
  digits** and printed a bare `-`). Fixed in cyrius 6.5.8; the GPU tools had never had the fix.
- **13 syscall wrappers were missing, including agnos's own bands** — the whole `#97` channel set
  (`sys_chan_mint`/`send`/`recv`/`close`/`endow`/`caps`), `sys_ptrscan` (#98), `sys_gpu_recover_op`,
  `sys_uptime_us` and `sys_spawn_path_env`. Ring-3 GPU tools could not call syscalls this kernel ships.

All 16 host oracles pass on the new snapshot.

⚠ **Six other test manifests were deliberately NOT moved** — `tests/symlink` (6.3.9), `tests/audio` and
`tests/fp` (6.4.2), `tests/blk` (6.4.39), `tests/chan` (6.5.8), `tests/fault` (6.5.18). Each records the
release that landed the syscall peer it exercises (*"The agnos symlink syscall peer landed cyrius
6.3.6"*), which is information a blanket bump would destroy. ⚠ But `tests/gpu`'s argument generalises to
every ring-3 binary that reaches kernel syscalls, so this is a deferred decision, not a settled one.

### Removed — 51 committed binaries under `tests/gpu/build/`, and the second fossil they were hiding

Untracked and gitignored. Verification before removal: all 11 with a live source and a runnable gate
**rebuilt byte-identical** to their committed copies, so tracking them carried no information. ⚠ Four —
`au`, `gpublit_cmp`, `inc_probe`, `szprobe` — had **no `.cyr` source anywhere in the tree** and no
reference from any script or doc: binaries this repo could not regenerate even in principle.

⛔ **`scripts/burn/stage-tools.sh` was the second victim of the same mechanism.** Without `--build` it
copied whatever binary was in git to the rootfs and printed `staged: … bytes`, which reads exactly like
a fresh stage — and `burn-prep`'s cmp loop then compared the fossil **against itself** and reported
MATCH. So a tool staged onto burn media could be built from source that no longer existed, and every
check in the chain agreed it was fine. In-tree `agnos/*` rows now BUILD when the binary is absent.

⚠ **Deliberately scoped to `agnos/*`; sibling rows keep the explicit `--build` contract.** Each sibling
pins its *own* cyrius in its own manifest, so auto-building one here would compile it with whatever
cyrius this repo's PATH resolves — an artifact built against a toolchain that repo never declared.

### Changed — kashi ref aligned to **1.0.4** across all three scripts, which had three different answers

`scripts/build.sh` and `scripts/bench.sh` defaulted `KASHI_REF=1.0.3`, `scripts/test.sh` defaulted
`1.0.0`, and `cyrius.cyml`'s comment claimed a fourth answer (`1.0.0`) — while the sibling working tree
was at **1.0.4** (verified a real tag matching kashi's own `VERSION`, clean tree).

⛔ **None of that is visible on a developer box.** `[deps.kashi]` declares only `path`, and the path
WINS, so every local build silently used the working tree whatever any script said. The divergence bites
only a clean checkout — where the kashi you get depends on which script ran first.

### New — a sovereign emit list for `blend_rect`, gated byte-for-byte against the iron-proven hex

`kernel/shaders/emit/blend_rect.emit.cyr` — 47 calls into agnos's asserting wrappers over mabda's
gfx9 encoder, reproducing all **60 of 60** committed dwords exactly, on a host, with **no llvm, no
C/C++, no assembler and no GPU**. First shader in the tree with a derivation that is agnos's own.

⛔ **The kernel never includes it and `build/agnos` is byte-identical** — 1,980,696 B ·
`6c256bc62719ec26`, compared before and after. The committed hex in `gpu.cyr` remains the authority;
if the two ever disagree, the hex is presumed right because it was burned on archaemenid.

**The two sides are independent, which is the whole value.** `scripts/check/shader-tables.sh` extracts
the expected dwords **mechanically** from `kernel/core/gpu.cyr` into a generated, gitignored
`tests/gpu/gen/oracle_tables.cyr`. `edgeasm.cyr:36-40` states the rule — *"hand-copying and then
diffing marks its own homework, because both sides would share the same mistake"* — and then
hand-copies its own tables anyway; this is what that comment actually asks for. The extractor asserts
**contiguity** (every offset exactly `4*i`, no gaps, no reordering) across all 20 shaders,
**3,243 dwords** total, and rejects a `return` value that is neither the dword count nor the byte
count.

⭐ The emit list was **decoded from the committed dwords through mabda's field formulas in reverse**,
then cross-checked against `blend_rect.s` — not transcribed from the `.s` by eye. All 60 decoded with
**zero unexplained**, including the one non-instruction dword: `+112 = 0xbe9400ff` is SOP1 with
`ssrc0 = 0xFF = GFX9_SRC_LITERAL`, consuming `+116 = 0xbb808081`, the f32 bit pattern of −1/255.

⭐ It also yields four opcode constants **decoded from iron-proven bytes rather than recalled from a
manual** — `v_cvt_f32_ubyte0..3` = `0x11`–`0x14`, `v_add_co_u32` = `0x19`, `v_addc_co_u32` = `0x1C`,
`v_cvt_pk_u8_f32` = `0x1DD` — held agnos-local under an `AG_` prefix pending an upstream mabda 4.1.0.

New `tests/gpu/asmlib.cyr` holds the shared safety layer (asserting wrappers, VGPR high-water tracker,
label/fixup pass, the comparator). ⚠ These refusals stay **local to agnos permanently**: mabda's
encoders are pure bit-packers *by design* — `vsrc1 = 300` silently encodes as `v44` — which is the
right contract for a compiler whose register allocator guarantees the invariant upstream, and the
wrong one for a human writing 47 instructions by hand. Pushing them upstream would change behaviour for
every `gfx9_enc_*` call site in mabda (218 in `src/`) to satisfy agnos's failure model, not mabda's.

Mutation-tested three ways, each red with the correct diagnosis:
- a corrupted dword in `gpu.cyr` → `dword 30 (byte +120) emitted 0xd1cb0008, committed 0xd1cb0009`
- a wrong operand in the emit list (`s20`→`s21`) → `dword 31 (byte +124) emitted 0x03c82b08, committed 0x03c82908`
- a convention violation (`V(12)` where a raw index belongs) → `declares 13 VGPRs but uses v268`.
  ⭐ This one matters most: it **encodes correctly** because mabda masks to 8 bits, while feeding 268
  to the high-water tracker and silently disabling the under-declaration gate. Right output, poisoned
  check — and the only reason it is catchable is that the tracker is a gate rather than a comment.

⛔ A fourth defect was found in the oracle's own verdict ordering by that mutation run: `ea_compare`
latches `ea_fault`, so testing `ea_fault` first reported a corrupted **expected** dword as *"an
asserting wrapper refused an encoding"* — a true failure with a false cause, which sends the next
reader to the wrong file. Concrete failures are now counted and reported first.

⚠ **VGPR high-water is checked, SGPR is not yet.** `blend_rect` measures v12 against a declared 13 —
exact. There is still **no over-declaration check anywhere** in the tree, and no hardware oracle for
either direction: RSRC1 is not GRBM-readable, so nothing on the machine can contradict a wrong
declaration and the failure is corruption at a distance.

### Fixed — agnos's two sovereign-encoder oracles had never compiled, and a committed binary hid it

`tests/gpu/edgeasm.cyr:46` and `tests/gpu/asmagree.cyr:44` both read
`include "../../mabda/src/gfx9_encode.cyr"`. From `tests/gpu/` that resolves to `<agnos>/mabda` — a
directory that has never existed in this repo. Correct is `../../../mabda`. **Neither file had built
on any machine since the day it was written**, neither appeared in `host-gpu-oracles.sh`'s loop, and
nothing under `.github/workflows/` invokes `check.sh` at all — so the runner that would have caught it
was itself never run in CI.

These two files carry agnos's entire "we have a sovereign gfx9 encoder" claim. They are cited **by
name** at `scripts/check/shader-blob.sh:13` and `scripts/check/burn-prep.sh:377` as the proof the tree
can reproduce iron-proven shader bytes without llvm.

⛔ **Why it went unnoticed for so long: `tests/gpu/build/edgeasm` is a committed binary.** Running it
exits 95 and prints *"B4 PASS — the tool reproduces a shipped iron-proven shader byte-for-byte"*. It is
108,784 B; built from the fixed source it is 116,976 B. The artifact in the tree passed while the
source beside it would not compile. 51 binaries are tracked under `tests/gpu/build/`. A committed build
artifact is evidence about whatever source existed when someone last ran a compiler, not about the
source next to it.

Both now build and exit 95, and are in the runner's loop, which **rebuilds before it runs**.
Mutation-tested both directions: one corrupted expected dword → `edgeasm exited 90, want 95`; the
include reverted → `edgeasm.cyr does not BUILD`, correctly reported as tooling rather than as a red
oracle.

⭐ Their passing is also the first *empirical* answer to the mabda/agnos pin question — mabda pins
cyrius 6.5.3, agnos's manifests pin 6.4.78, and `gfx9_encode.cyr` compiles inside agnos's test tree
regardless. That had been argued from the source's simplicity; it is now built.

### New — `scripts/check/mabda-resolve.sh`; host GPU oracles now run in CI

`mabda-resolve.sh` ensures the sibling mabda checkout the oracles include is present, cloning the
pinned tag (**4.0.8**, verified against mabda's own `VERSION` and a live remote tag) when it is not. It
asserts the two included files specifically, not just the directory, so a partial checkout reports as
tooling instead of as an opaque build failure. ⚠ There is deliberately **no `MABDA_DIR` override**:
`include` bakes its relative path into the source, so an env var could not move where the compiler
looks — offering one would be a knob that silently does nothing. Only `MABDA_REF` is overridable.

`.github/workflows/ci.yml` gains a **Host GPU oracles** step running all 15. ⚠ This wires the oracle
runner specifically, not `check.sh` as a whole — `shader-blob.sh:29-31` hard-exits without
`llvm-mc`/`llvm-objcopy`, so full `check.sh` in CI needs an LLVM install and is a separate change.

### Fixed — `scripts/ktest.sh` had been exiting 1 on every invocation for three weeks

Its guard greps for exactly one `kybernet(); arch_halt();` in `boot_finish.cyr`. That line has read
`kybernet(); power_quiesce_devices(); arch_halt();` since 2026-07-19, so the count was **0** and the
script exited before building anything. The guard did its job; nobody ran it. Every QEMU
kernel-test claim in that window rests on nothing.

Guard and `sed` retargeted to the full current launch line, with `power_quiesce_devices()` preserved
across the rewrite so the test path quiesces exactly as production does. ⚠ Matched as the whole line,
not a substring: bare `arch_halt();` appears **twice** in `boot_finish.cyr` (the second is the no-shell
fallback at `:31`), so a loosened pattern would double-match and reject a healthy tree.

### Changed — `#86` GPU shm slots are 32 MB; the region moves to `0x90000000` and doubles to 512 MB

`GPU_SHM_REGION_OFF` `0xA0000000` → **`0x90000000`**, `GPU_SHM_REGION_SIZE` `0x10000000` →
**`0x20000000`** (512 MB), `GPU_SHM_SLOT_SIZE` → **`0x2000000`** (32 MB), `SHM_GPU_MAX_SIZE` →
**33554432**. 16 x 32 MB = 512 MB = the region exactly, ending at `GPU_RT_REGION_OFF` as before.

Covered per slot: 1920x1080 (8,294,400 B), 2560x1440 (14,745,600 B), 3440x1440 (19,814,400 B),
3840x1600 (24,576,000 B), 5120x1440 (29,491,200 B), 3840x2160 (33,177,600 B, 376,832 B spare).
Not covered: 5120x2880 (58,982,400 B) — wants 64 MB slots.

The move is into measured free space: the compute arena is 2 MB at `GPU_VM_ARENA_OFF` and ends at
`0x80200000`; 254 MB stays clear between it and the new base.

### New — `scripts/check/check-carveout.sh`, wired into `check.sh`

`check-arena.sh` gates the `*_SUBOFF` slots inside the 2 MB compute arena. The top-level carveout
regions — console FB, pan, back buffers, PSP TMR, arena, shm, RT — had no gate: hand-placed hex
constants, disjointness argued in comments only, in a region set where `VM_CONTEXT0` is disabled so an
overlap is silent mutual corruption rather than a fault.

Checks half-open extent overlap between every region pair, each region against the 3 GB aperture,
`SHM_MAX * GPU_SHM_SLOT_SIZE <= GPU_SHM_REGION_SIZE`, `SHM_GPU_MAX_SIZE <= GPU_SHM_SLOT_SIZE` (or
`#89 +24` over-advertises), and that a slot is a whole number of 2 MB pages (or the WC remap loop
leaves a tail). Mutation-tested three ways — overlapping region, unaligned slot, slot count outrunning
the region — each fails.

### Changed — `#86` GPU shm slots: the first bite (2 MB → 16 MB)

`GPU_SHM_SLOT_SIZE` 0x200000 → **0x1000000**. `SHM_MAX_SIZE` (2 MB) is split into two constants: it now
caps `#71` only, where `pmm_alloc_2mb` is genuinely one page; `#86` is capped by the new
**`SHM_GPU_MAX_SIZE` = 16777216**.

At 32bpp a 2 MB slot held 524,288 px (~724x724). A client surface at the native 2560x1440 is 14,745,600 B,
so `shm_create_gpu` refused it and the client fell back to `shm_create#71` — system RAM, which the GPU
cannot read (bus-master off by design) — putting that surface on the CPU path. A 16 MB slot holds
2560x1440 with 2,031,616 B spare.

⚠ **16 MB covers 1920x1080 and 2560x1440 and stops there.** Not covered: 3440x1440 ultrawide
(19,814,400 B), 3840x1600 (24,576,000 B), 5120x1440 (29,491,200 B), 3840x2160 4K (33,177,600 B).
32 MB slots cover all of them with 376,832 B spare at 4K; 16 x 32 MB = 512 MB against a 256 MB region,
so it needs the region relocated or `SHM_MAX` halved. Next stage — roadmap OPEN.

New `GPU_SHM_REGION_SIZE` = 0x10000000 (256 MB, 0xA0000000 → 0xB0000000 = `GPU_RT_REGION_OFF`).
`SHM_MAX * GPU_SHM_SLOT_SIZE` = 16 x 16 MB = 256 MB, checked against it in `shm_create_gpu`, which
refuses rather than allocating past the region.

### Fixed — `shm_create_gpu` WC-mapped only the first 2 MB of a slot

`vmm_remap_wc_2mb` remaps one 2 MB page. One call covered a 2 MB slot exactly; at 16 MB it left 14 MB of
every slot on the direct map's attributes, so the write-combining `shm_write`'s sequential store run
depends on held for the first eighth of the slot and not the rest. Now loops over `GPU_SHM_SLOT_SIZE` in
0x200000 steps.

### Changed — `#87 gpu_blit_shm` issues ONE CP-DMA packet for a contiguous blit

`gpu_cp_dma_blit` issues one packet per row, each arming a fence, kicking the ring and spin-waiting.
The 1.56.30 burn measured that shape: an 800x600 clear = 600 packets = 89 ms, two-point fit
**91.5 us per row**, dispatch-shaped not bandwidth-shaped (`kernel/core/gpu.cyr:884-888`).

At 1440 rows that is ~132 ms for a fullscreen composite against the ~10.58 ms CPU fallback. Raising the
slot to 16 MB admitted a fullscreen surface to this path for the first time, so the two changes must
ship together.

`gpu_blit_shm_sys` now collapses to a single `gpu_cp_dma` when `dx == 0` and `w * 4 == gpu_bb_pitch`
and `w * 4 * h <= GPU_CPDMA_MAX` (26-bit BYTE_COUNT, ~64 MiB). Partial-width rects keep the per-row
path — all three conditions are required, not just `dx`. Same collapse `gpu_depth_clear` already makes.

### Fixed — `shm_create_gpu` discarded `vmm_remap_wc_2mb`'s return value

`vmm_remap_wc_2mb` returns 0 when its `pmm_alloc()` fails on the high path a carveout address always
takes (`kernel/core/vmm.cyr:157-158, :188-189`). The slot was stamped and a valid id returned over a
partly-mapped window. Now returns -1.

### Changed — `gpu_caps#89` +24 reports the GPU slot cap

Was `SHM_MAX_SIZE` (the `#71` pmm cap), now `SHM_GPU_MAX_SIZE`. Ring 3 sizes `#86` requests from this
field; reporting the pmm cap understated the GPU slot by 8x. Additive for consumers that only compare
against it — aethersafha's `ae_gpu_wp_fits` reads it at runtime and needs no change.

**Build**: 1,980,424 B. 4/4 kernel tests.
⚠ **Unburned.** QEMU exposes no AMD PCI device, so `gpu_find` never matches and no `#86`/`#87` path
executes there. First execution is an iron burn.

## [1.56.43] — 2026-08-11 — the audio leg shelved, the Uncertain backlog emptied, three HID defects fixed (CLOSED)

✅ **Cycle closed 2026-08-11.** It opened on the HDMI-audio leg and ended somewhere else, which is worth
stating plainly rather than retitling away: the audio leg was **shelved again** after five burns established
that every source-side observable says PLAYING and there is still no sound; the cycle's value came from what
followed. **Three arcs shipped**: the ext2 timestamp fix (files no longer stamp 1970), the *Uncertain — ride
the next burn* backlog cleared to empty (three of its four items were userland and never needed a burn at
all), and three HID input-path defects found and fixed while explaining a single log line at the shell prompt.

⏸ **Opened for the audio leg, which has been PARKED under operator hold since 2026-08-07.** The desktop arc
closed with 1.56.42 and its forward work moved into aethersafha's own roadmap (M6, userland), so the kernel's
next question is the one that has been waiting longest: **HDMI audio has never made a sound on this box.**

⚠ **Nothing is being re-derived here.** The parked playbook in agnosticos `iron-log.md` cost four burns to
produce — the required flag set (`HDA_HDMI` + `HDMI_ATOM` + `HDA_TONE` + `GPU_AUDIO_PROBE`) and the
pre-registered outcome table — and it stands. This cycle is a **review and audit first**: establish what is
actually proven, what is falsified, and what is merely untested, before spending another boot.

### Fixed — a rejected HID completion code left the endpoint dead (input froze, CPU alive)

`hid_poll`'s drain set `bi = -1` on any completion code other than SUCCESS/SHORT_PACKET, with the
comment *"re-arm below, fold nothing"*. `hid_ep_kind_at(-1)` is `HID_KIND_NONE`, so both kind-gated
blocks were skipped — and those blocks contained the only `hid_arm_xfer_trb()` / `hid_arm_row_trb()`
calls and the only doorbell writes. The event was consumed unconditionally regardless, so every
rejected completion permanently spent one TRB of the 16 armed at init. Sixteen cumulative errors
emptied the ring and the controller stalled the endpoint.

The drain now keeps the endpoint row (`row`) separate from the fold gate (`cc_ok`): re-arm and
doorbell are unconditional inside each kind arm, and only report processing is gated.

**Measured** via `HID_CC_INJECT=1` (new, build-gated; forces the first 20 completions to a
non-halting Data Buffer Error — more than the 16 armed TRBs): with the fix the keyboard recovers and
the shell answers; with the pre-fix gating restored as a control, input is dead for the remainder of
the boot. `scripts/harness/hid-cc-inject-test.py`.

### Fixed — the two `hid` one-shots called `kprintln` from interrupt context

`hid.cyr`'s first-keyboard-report and first-mouse-report messages printed from inside `hid_poll`,
which runs in the 100 Hz timer ISR (`pic.cyr:79`) and the xHCI MSI-X handler (`pic.cyr:258`).
`kprintln` takes `console_spin_lock` — an unbounded `xchg` spin with no `cli` and no owner check.
Ring-3 `write(1)` holds that lock with IF=0 and cannot be preempted, but the keystroke echo path
enables interrupts around `kputc`; an interrupt landing there re-entered `hid_poll` → `kprintln` and
spun forever on a lock its own CPU held. The window is widened by a line wrap, since `fb_scroll_up`
runs inside the held lock (a 14.7 MB copy at 2560x1440).

Both are now flags drained by `hid_service_deferred()` from thread context — `kb_has_key()` and the
`#98` ptrscan arm. `hid_poll` is console-silent. The messages are unchanged and still one line per
boot; only where they print moved. This restores the invariant already documented in `kprint.cyr`
and `smp.cyr` ("no ISR calls kprint").

**Measured**: `scripts/harness/hid-mouse-deferred-test.py` attaches a QEMU USB mouse, injects motion
and asserts the one-shot arrives **without any typing** (the shell's `kb_has_key` poll loop drives
the flush). Mutation-tested — disabling the flush call turns that assertion red.

### Added — halted-endpoint recovery on the HID path (`hid_recover_halted`)

Completion codes 4 / 6 / 8 (Transaction Error, Stall, Babble) leave the endpoint Halted with its
dequeue pointer pinned, so a bare re-arm is inert. The drain now flags the row and
`hid_recover_halted()` issues Reset Endpoint + Set TR Dequeue from thread context (they block on a
Command Completion Event and cannot run in an ISR), mirroring the mass-storage recovery in
`msc.cyr`. Previously `hid.cyr` had zero uses of either command.

⚠ **Reachable, not validated.** An injected halting code shows the flag is set, the function runs
and the system survives — but the controller never actually halted, so `xhci_ep_state()` reports
Running and the body early-outs before issuing a command. The Reset/Set-TR-Dequeue pair has not
executed anywhere; validating it needs a genuine hardware stall.

### Verified on iron — Backspace, and file timestamps on the real volume

Burned PASS 2026-08-11 on archaemenid (bare 1.56.43). Backspace reaches the line editor at the
`[ASSIST] >` prompt. Files created on the NVMe agnos-fs carry real dates (`2026-08-12 01:27` UTC),
and `mtime` advances on write (`01:27` → `01:29` after an append), so `ext2_stamp_mtime` fires on
the write path and not only at create. Pre-existing files still read `1970-01-01`, which is the
negative control.

### Fixed — `uname`#34 returned EMPTY `nodename` and `release`

`sysinfo_put_str` was handed the `kernel_hostname` and `_AGNOS_VERSION` **gvars**; the gvar pointers are
not live on the ring-3 syscall path, so both fields came back all-zero. `sysname` and `machine` — inline
string literals in the same arm, through the same helper — were unaffected. Both now read through
program-body-safe function accessors: the existing `agnos_version_str()` (`kernel/version.cyr`) and a new
`kernel_hostname_str()` (`kernel/core/syscall.cyr`), which bake the rodata pointer into the function at
compile time.

Observable: `iam` prints `Kernel: AGNOS 1.56.43` and `Host: agnos`, where it previously printed a bare
`AGNOS` with a trailing space and an empty `Host:`. ABI unchanged — 64-byte struct, four 16-byte
NUL-padded fields at offsets 0/16/32/48 (sysname / nodename / release / machine).

### Added — `tests/fault/faulter.cyr`, a deliberate-`#PF` stimulus

A minimal `--agnos` program that writes `FAULTER-ALIVE` to fd 1 and then stores to address 0. Staged to
`/bin/faulter` by `stage-tools.sh`. Exists because the roadmap's `bg-fault` item had no stimulus in the
rootfs at all, so it could not be tested by any burn it "rode".

### Added — `scripts/harness/sweep-test.py`

One QEMU boot that settles the userland half of the roadmap's Uncertain list: the `iam` Kernel line,
`kriya ln -s`, `kriya readlink` no-follow, and shell survival of a faulted `&` job. Builds its own image
from `build/rootfs` + `build/agnos`. The faulting check runs last so it cannot perturb the readings taken
before it, and a warm-up keystroke absorbs the first-key-of-session drop that otherwise eats the leading
character of the first command.

`burn-prep.sh`'s staged-tool freshness gate now also covers `kriya`, `iam` and `faulter`.

New: `scripts/harness/README.md` indexes all 16 QEMU harnesses (there was no index), records that
`sweep.sh` runs `scripts/smoke/*` and never `harness/*.py`, and states the rule the sweep harness
embodies — a question whose answer lives in userland does not cost an iron boot.

### Fixed — every file agnos created was dated 1970-01-01, because the driver believed there was no RTC

⛔⛔ **MEASURED, from outside agnos**: with the agnos-fs mounted on Linux, every file the kernel had ever
written read `mtime=0 ctime=0` — 94 of them at the volume root. Linux renders that as **1970-01-01** (or
*Dec 31 1969* in a negative-offset timezone, which is how the operator first saw it).
⚠ **`atime` is a decoy and must not be read as a working timestamp**: the mount is `relatime`, which
refreshes atime on read whenever atime < mtime — and mtime was 0, so every read set it. It looked like one
of the three fields worked. None did.

⭐ **The cause is a stale belief written into the driver**, in `ext2_unlink`'s i_dtime comment: *"We have no
RTC → fixed epoch sentinel."* **agnos has an RTC.** `net_clock_seed_rtc()` reads the CMOS at boot and the
console prints `Wall clock: RTC seed Unix …` at boot line ~67, where the ext2 mount is line ~143 — the clock
has been available before any filesystem existed for the entire life of this driver, and `ext2.cyr` contained
exactly ONE timestamp reference: a *read* of i_mtime for `stat`. Nothing ever wrote one.

⇒ `ext2_stamp_new()` (i_atime/i_ctime/i_mtime, offsets 8/12/16) on every inode-creating path —
`ext2_create`, `ext2_mkdir`, `ext2_symlink` — and `ext2_stamp_mtime()` (i_ctime + i_mtime) in
`ext2_write_at`'s **shared flush tail**, beside the i_size / i_blocks updates, so every write path that
reaches that flush is stamped and a new one cannot forget to.
⛔ **Guarded on the clock being real.** `ntp_now()` returns **0 when never synced**; on that path the fields
stay zero, exactly as before. Writing a plausible-but-wrong date would be worse than 1970 — a wrong date is
harder to notice than an absurd one. ⚠ `ntp_now()` advances with ticks, so files do not all share one second.
⚠ Cheap enough for the fault path: `klug_spill` rewrites 64 KB from `fault_kill_current`, and this adds two
stores and a tick read — no allocation, no I/O.

⭐ **VERIFIED END-TO-END BEFORE IT GOES NEAR IRON, by an oracle outside agnos.** `ext2-write-smoke` (W1-W5)
passes unchanged, and `debugfs` reading the resulting on-disk image shows regular files, a directory, a
hardlink and a symlink all carrying `ctime/atime/mtime = Tue Aug 11 09:48:15 2026` — the wall-clock second
the smoke ran, against a pre-image whose own timestamps read 09:48:11. Not agnos's claim about itself.

### ⏸ SHELVED 2026-08-11 — the HDMI-audio leg, after four burns in one day

⭐ **Every source-side observable agnos possesses now says PLAYING, and there is no sound.** Link in HDMI
mode 3 and holding · packet block byte-identical to a playing amdgpu link, measured **with the HDMI block
ON** · `AFMT_STATUS 40000010` stable across a 90 s untouched hold · **samples measured traversing the
encoder output live** · the sink's amp demonstrably energised (the shutdown release pop).

**Retired this round:** *"the sink needs a long stable lock"* (90 s untouched, amp armed, silent) and **the
audio-DTO literal** — `DCCG_AUDIO_DTO0_MODULE` now writes the live-derived `gpu_pixclk_100hz` (241.5026 MHz)
instead of amdgpu's hardcoded `0x24D998` (241.5000 MHz), because the register is documented *"= actual pixel
clock in 100 Hz units"* and hardcoding a foreign clock is the reasoning §2.3 already killed for CTS.
⚠ **The revert is KEPT on correctness grounds only. It produced no measured audio effect and is NOT a fix.**

⛔⛔ **The bisect's leading candidate died on its own test, and that is the useful part.** tap 1 reads
`4dc450` across **five burns and two different audio-DTO clock values**, 16 sweep profiles, two tone bands
and two quiet holds. Changing the audio clock derivation should perturb a live packetised stage; it did not
move one bit. ⇒ *"tap 1 is a stuck instrument"* now outranks *"the packetiser emits constant data"*, the
July→August freeze is most likely an **instrument** regression, and **tap 1 must not be cited as evidence
until it is re-validated** — including in the ~24 silent burns that already lean on it.

⚠ Also re-opened by the audit: **arm 1 was never a valid control** (it unmutes with the front end detached
and the OTG stopped, `syscall.cyr:6163` vs `:6238`), so no arm1-vs-arm2 result can retire sequencing.

⇒ Surviving: **(a)** sequencing · **(b)** a write that does not latch (weakened) · **(c)** the bare metal.
⛔ **Do not resume by re-running any instrument in that ledger.** This leg needs an oracle it does not have:
one that observes the **wire** rather than the source. Everything agnos owns sits at or before the AFMT
output tap, and that half is exhaustively green.

### Audited — the HDMI-audio leg, zero burns. Full findings in `planning/gpu.md` §2.3.

⛔⛔ **The blocking finding is a CONTRADICTION IN OUR OWN RECORD, not a hardware unknown.** Two load-bearing
claims about `DIG_MODE`=3 on the same sink cannot both be unconditionally true: the *standing finding a
resumption starts from* says **`DIG_MODE`=3 ⇒ no signal for the whole run**, while the 2026-07-14 green
screen — labelled *"this arc's single most load-bearing positive result"* — says **DIG_MODE=3 took and the
sink honoured agnos's AVI InfoFrame.** A panel rendering green/pink is a lit panel decoding a signal.
⇒ The leg is parked pointing at the pessimistic one, so a resumption would hunt a link-mode rejection the
other result says does not exist — while the gap the document itself flags (*"AVI egresses does NOT prove
ASPs egress"*, different generators) goes unexamined. ⭐ **Settle it from the captures, not a boot**; both
events are on disk. A live candidate needing no sink theory at all: ATOM **`#76` ENABLE resets `DIG_MODE`
back to 2 itself**, which alone yields "mode 3 never held".

**What the audit cleared, so a resumption does not re-derive it:**
- ✅ **The code survived nine cycles of desktop work.** `MDO_OP_CRCCAL` + `mdo_crccal()`,
  `hda_hdmi_feed_running()`, `gpu_hdmi_audio_enable`/`_preflight`, the three `modeset` arms, and
  `CRCCAL_REQUIRE` still asserted in `burn-prep.sh`. Nothing needs rebuilding.
- ✅ **The PS/2 excision did not break the feed.** `hda_stream_service()` runs from the **timer ISR** as a
  polled drain (`pic.cyr:73`), so `pic_init`'s 0xFC→**0xFF** mask cannot reach it. Checked because `pic.cyr`
  is the file that arc rewrote and it names `HDA_TONE`.
- ⭐ **The native-modeset arc did not invalidate the transmitter findings — and that was the real risk**,
  since 1.56.36/37/38 rewrote the display bring-up *after* the audio work was parked. The 2026-08-10 capture
  settles it for free: the link reads **identically before and after** the modeset (`display link 2560x1440
  total 2720x1481 blanking 160x41`, `pixel clock 241503 kHz`). Native changed the **scanout surface**, not
  the **link** — the link was always native, because the panel is.
- ⚠ **The Audio InfoFrame is driven** (`AFMT_AUDIO_INFO_UPDATE` at three sites), so *"the sink mutes because
  no AIF arrives"* is not available as a free explanation on resumption.

⇒ **The capture-read was done the same day. See below.**

### Fixed — the standing finding was FALSIFIED by our own capture, and the arc's question changed

⭐⭐⭐ **`DIG_MODE`=3 IS ACHIEVED AND IT HOLDS.** `prior-art/dcn-modeset-m9-audio-arm-iron-0724.txt`, twice
(once per arm): `DIG_MODE 2 -> 3` → ATOM `#76` reverts it (`w=566f v=10020200`) → agnos **re-asserts 3** →
**`DIG_MODE 3 -> 3`** in the second arm, panel alive, both arms run, `klug` captured after. ⇒ **The sink
does not reject agnos's HDMI signalling.** Corroborated: amdgpu-playing writes `0x566f = 0x10030200` four
times; agnos's *inherited GOP* state is `0x10020200`, which is what the arc kept measuring before the flip
existed.
⚠⚠ **The run that proves it is M9 — the retracted null experiment.** Its ear result stays void (both arms
fed digital silence); its **register trace is a different oracle** and is untouched by that retraction. The
evidence that unblocks the arc sat unread for two weeks inside a capture labelled "null". ⇒ **Scope a
retraction to the evidence it actually killed.**
⚠ Neither prose claim was ever in the burn ledger — no entry, no capture, for either — so the arc was
parked pointing at whichever was written last.

### Added — `gpu_hdmi_asp_probe()`: the packet block, read in mode 3 with the feed live

⛔⛔ **The instrument gap, stated plainly: no register comparison in this arc was ever taken with the HDMI
block switched ON.** `gpu: audio probe` runs at **boot**, where M9's own log records `dig1 … mode=2`, and
every `HDMI_*` register is **inert while `DIG_MODE == 2`**. The mode-3 flip happens later, inside the arm,
and nothing re-read the packet block afterwards. ⇒ The corpus behind *"every AFMT register is byte-identical
to a working amdgpu"* was measured against a block that was off.

⇒ New probe called from **inside the audio arm's listening window** — the one moment mode 3 and the feed are
simultaneously live. It prints `HDMI_STATUS`, `HDMI_AUDIO_PACKET_CONTROL`, `HDMI_ACR_PACKET_CONTROL`,
`HDMI_INFOFRAME_CONTROL0`, `AFMT_AUDIO_PACKET_CONTROL`, `AFMT_AUDIO_INFO0` and `AFMT_STATUS`, **each with
its known-good amdgpu-playing value inline**, so a mismatch names itself instead of needing a diff.
⚠ The comparison values are **DIG1** from `dcn-audio-known-good-full-0716.txt` — DIG0 is the *unused*
encoder and its block is idle, so comparing against it would "confirm" silence.
⛔ **The NULL is calibrated in the output**: `HDMI_AUDIO_PACKET_ERROR` reads 0 both when packets flow
cleanly and when none are attempted, so the probe says so rather than letting a 0 read as good news.
⛔ **Guarded on `gpu_audio_dig < 0`** — it is −1 without `GPU_AUDIO_PROBE`, which would multiply into a
negative stride and turn a read-only diagnostic into wild MMIO. It refuses and names the missing flag.
⭐⭐⭐ **BURNED 2026-08-10 — it ran, the reading is valid, and it closed the register axis.** `DIG_MODE now 3`
in both arms. **Seven of eight registers byte-identical to a PLAYING amdgpu link**; the eighth
(`AFMT_STATUS 41000010` vs `40000010`) is the sticky bit24 residue of the arm's own mute→unmute, which
amdgpu also shows while still playing — **explained, not a lead.** ⛔⛔ **RETRACTED THE SAME DAY — the framing above was FALSE.** It claimed the prior corpus was taken in
mode 2 where those registers are inert, and that this was "the first measurement that means anything".
**Both are wrong and measurably so:** all nine 2026-07-16→07-20 audio burns ran the `DIG_MODE` 2→3 flip at
boot and dumped afterwards — `hdmi-audio-burn3-iron-0716.txt` has `switched to HDMI signalling` at line 174,
the dump at 186, and `DIG_BE_CNTL 10030200` (**mode 3**) at 227. ⇒ The register axis was already closed with
the block ON three weeks earlier, **at 105 registers, not 8**, and this probe is a **subset
re-confirmation**. ⭐ What survives is what was true all along: the packet block is configured exactly like a
link that plays, and it is silent. ⚠ The error was an INFERENCE from two true facts (the mode-2 inertia
rule; `gpu: audio probe` really does run at boot in mode 2) that was never checked against a capture — one
grep for the flip line caught it.
⭐⭐ **New positive from the ear**: *"speakers did sound like they lost power when tests were over"* — the
**release pop**, which this arc rules is evidence the sink's amp was **energised and driven**.
⛔ **And the burn found a defect in its own procedure**: `--crccal`'s *"inert in every phase"* verdict is
**VOID**, because each arm restores `DIG_MODE`=2 on exit and `--crccal` therefore always measures a **DVI**
link — the same class of error the probe was built to catch. Arm 2's taps completed in mode 3 (`crc ff590d`),
proving the probe is fine. The parked playbook's ordering is wrong; `--crccal` belongs inside the mode-3
window. ⇒ Surviving: **(b) a write that does not latch · (c) the bare metal.**

### Reviewed — what the audit cleared, so a resumption does not re-derive it

## [1.56.42] — 2026-08-08 — ⛔ PS/2 IS DELETED, the pointer lands, and a covered console stops losing its log (RELEASED)

⭐ **Closed 2026-08-10.** What the cycle turned out to be, beyond the PS/2 excision it opened for: the
`AE-7` pointer's whole kernel half (`#98 ptrscan`, per-endpoint mouse binding, the `hid_poll` try-lock), a
process table that **names** its own exhaustion instead of refusing in silence, and a full-screen app's log
finally reaching the disk. All four burned PASS on archaemenid — the last of them four compositor launches
in one boot, with the spill verified byte-exact off the partition.

### Added — a full-screen app's log now reaches the DISK when it exits, because nobody could ever see it

⛔⛔ **A failed desktop run was unreadable by construction.** A process that owns the scanout draws over the
console, so every line it printed — and every kernel line printed while it ran — landed on a surface nobody
was looking at. `klug_spill()` was called only from the boot, modeset and GPU-arc paths, so the desktop had
**no spill site at all**: the 2026-08-09 burn printed `spawn_path_env FAILED` twice into a ring that reached
no disk and produced no evidence of any kind. ⚠ And there is no interactive recovery on this hardware — the
iron target *is* the dev host, so booting agnos reboots the machine any log would be read on; by the time
anyone can look, RAM is gone. Evidence must reach the disk while the run is live or it does not exist.

⇒ `klug_spill_covered_console()`, called from `gpu_release_pid`. That function's existing ownership test is
exactly the right gate and costs nothing to reuse: reaching it means this pid **held the scanout**. It fires
once per full-screen app exit, never on a shell command, and covers **both** ways out — `exit#0` and
`fault_kill_current` both route through it, so a crashed compositor gets it free. ⛔ Boot CR3 for the disk
write, restored after: the live CR3 at the call site is the dying process's, under which the NVMe BAR is not
mapped. Reports the byte count, because a silent spill returning 0 leaves `/klug.txt` holding a STALE BOOT —
the "looks fine, is wrong" failure the whole mechanism exists to prevent.

⛔ **Factored into `klug.cyr` rather than left inline, and that is the load-bearing decision.**
`gpu_scanout_pid` is set only by `gpu_blit_present` (`#84`, DCN register writes), so the production call site
is **unreachable in QEMU** — inline, this code would have flown to iron with zero executions, exactly how the
window mover shipped as dead code and how the GPU cursor first ran on a burn. New
`KLUG_SPILL_SCANOUT_TEST=1` calls it directly at boot: **PASS in QEMU, 2945 bytes spilled**, box boots on to
the prompt. ⭐ **Mutation-verified** — forcing the count to 0 turns it red. ⚠ The test's CR3 assertion is
honestly weak (at boot the entry CR3 already *is* boot CR3); the byte count is what it proves.

⭐⭐⭐ **BURNED PASS 2026-08-10 — it ran at its production site, on iron, first execution anywhere**, on all
four compositor exits of one boot: **11065 → 13924 → 18346 → 21809 bytes**. ⭐ Externally corroborated: the
operator's own `klug` ring dump came out **21962 B**, the last spill plus the lines emitted after it, and the
monotone growth is what an unwrapped boot-cumulative ring should show. **No wedge at Esc** — the boot-CR3
window was the one genuinely new risk in that path.
⭐⭐⭐ **AND THE FILE IS VERIFIED EXACT.** Pulled off the agnos-fs partition from Linux: `/klug.txt` holds
**21809 bytes — the printed number to the byte** — and they are **BIT-IDENTICAL** to the first 21809 of the
independently-captured `klug` ring dump. The dump's 153-byte remainder is precisely the three lines emitted
*after* the write returned (the `spilled …` line itself among them), which is the documented property: the
count line lands in the ring after the write, so it is correctly absent from the rescued file.
⚠ Both channels read the same ring, so what this proves is the **write path** — an ext2/NVMe write under
boot CR3 landing exactly the bytes it claimed — not the ring's own fidelity, which is klug's pre-existing
property. ⚠ The file is 65536 B (21809 log + 43727 NUL): `klug_spill_prepare` pre-allocates the full ring
size and a spill overwrites only the first N, so there is **no truncation and no length marker** and a
reader must strip the tail.
⭐ **The latch-blocked redirect paid off for real, unplanned.** The burn left the modeset latch armed, so the
next boot came up blocked and `klug_spill_prepare`'s H2/S7 branch spilled it to **`/klug-2.txt`** instead.
Prepare writes 64 KB over its target at every mount — without that branch the next boot would have destroyed
the burn record before anyone looked for it. ⇒ **Pull both files after a burn.**
⚠ The hook is `gpu_release_pid`, so this covers a run that EXITS — a compositor that WEDGES never reaches it
and still writes nothing.

### Fixed — a full process table refused every spawn in SILENCE, and it took down the desktop on iron

⛔⛔ `proc_alloc_slot()` caps at **16** processes (`proc.cyr:275`) and returned **−1 with no diagnostic** —
from four call sites, through `elf_load_from_file`, out of `spawn_path #43`, all mute. The only thing that
ever spoke was the CALLER: aethersafha printing `spawn_path_env FAILED`, which names the symptom and not
one word of the cause. ⇒ On the 2026-08-09 iron burn the desktop came up, drew its chrome and **hosted
nothing**, with no line anywhere saying why — reported as *"just FB lines"*.

⚠ **Nothing reaps an orphan.** A parent that exits without closing its children leaves them alive holding
their process-table rows for the rest of the boot, so repeated desktop launches march the count to the cap
in four cycles. The compositor half of that is fixed in aethersafha (`comp_close_all_clients`); this is the
kernel half — **an absent resource must say it is absent and why**, the rule that already produced
`hda: ctl1 NOT PROBED` and `gpu_hdmi_preflight`'s self-naming early returns.

⇒ Latched, two lines: *"the process table is full and this spawn was refused"* and *"nothing reaps a
process whose parent exited without closing it"*. ⚠ **Latched and deliberately uncounted** — the first
refusal is the one that explains the boot, and an unlatched print inside an allocation failure is a storm
waiting for a caller that retries. Reproduced and confirmed in QEMU by
`AE_CLIENTS_MODE=relaunch` (new mode in `harness/aethersafha-clients-test.py`), which runs the operator's
five-step sequence and then relaunches until something breaks: **#4 before the fixes, 8/8 clean after**.

⭐⭐ **BURNED PASS 2026-08-10**: four compositor launches in one boot, two clients presented on every one,
and this refusal never fired — `proc: the process table is full` is absent from the capture, as is
`spawn_path_env FAILED`. ⚠ That makes it a **corrected latent path, not an exercised one**: the fix works by
the table never filling. The diagnostic itself has still only run under a deliberately-exhausted table.

### Fixed — `hid_poll` and `hid_mouse_take` are serialised; `cli` was never a lock on four CPUs

⛔⛔ `hid_poll` has two callers that can run simultaneously — the `#98 ptrscan` / `#42 kbscan` syscall arms
in ring 3, and `xhci_rx_handler` in the MSI-X ISR — and it dequeues the shared xHCI event ring and folds
into a shared accumulator with **no serialisation of any kind**. `pic.cyr`'s claim that this path was
"self-guarded (input_lock, cli-first)" was **false**: `input_lock` is taken only by `hid_kb_push` and
`kb_read_scancode` and guards `kb_buf` alone. On SMP, `cli` on one CPU excludes nothing on another, so two
drains could advance `xhci_evt_ring_idx` over the same event or interleave a read-modify-write on
`hid_mouse_dx`.
⇒ `hid_poll_lock`, an `xchg` **TRY**-lock mirroring `input_spin_lock`. Try rather than spin is the safety
argument: a spin would deadlock the moment the ISR interrupted a holder on the same CPU, which is the
common case since the syscall arm enables interrupts around its drain. Failing to acquire means another
context is already draining, so returning is correct rather than lossy.
⚠ `hid_mouse_take` takes it too. Its banner said "CALLER MUST HOLD IF=0" was sufficient; the syscall runs
wherever agnsh migrated to while the interrupt lands on another CPU, so a whole report's delta could be
lost between its read and its reset. The accumulator persists on a failed acquire, so nothing is dropped.
⚠ The false `pic.cyr` comment is corrected — a comment asserting a lock that does not exist is worse than
no comment, because the next reader stops looking.

### Fixed — an errored USB transfer re-folded the stale report as phantom motion

⛔ `hid_poll` never checked the Transfer Event completion code. A Transaction Error, Babble, Stall or Data
Buffer Error still posts a Transfer Event with IOC set — the TRB completed, it just carried no data — and
leaves the shared report page holding the PREVIOUS successful report. Folding it again re-adds the last
dX/dY as if the user had moved: a phantom cursor jump on every USB hiccup, of exactly the size of the last
real motion. `xhci.cyr` checks this code on the command ring; the HID drain did not.
⇒ SUCCESS (1) and SHORT_PACKET (13) are accepted, everything else folds nothing. ⚠ Short packet must be
accepted or a boot mouse's 4-byte report on an 8-byte endpoint would be dropped as an error.

### Fixed — mouse buttons are per-endpoint, so one device cannot release another's

⛔ `hid_process_mouse_report` assigned the shared `hid_mouse_btn` from whichever interface reported LAST.
archaemenid binds **two** boot-mouse interfaces — the real mouse, and the Keychron K2's phantom mouse on
its interface 1 — so a single idle (all-zero) report from the keyboard cleared a button the user was
physically holding, dropping a titlebar drag mid-gesture and handing ring 3 a release that never happened.
⇒ `hid_ep_btn[]` keeps each endpoint's own bitmap and `hid_mouse_btn` is their union over bound mouse
endpoints; a device can now only ever clear its own buttons. `hid_process_mouse_report` takes the endpoint
index. Build 1 973 288 → 1 973 640 B.

### Added — `#98 ptrscan`: ring 3 can read the pointer (`AE-7` P3, kernel half)

`ptrscan(buf, max)` → **16** on activity, **0** idle, **−1** on a bad range or `max < 16`. Record:
`+0` s32 dx · `+4` s32 dy (**positive = DOWN**) · `+8` u32 buttons (current level) · `+12` u32
buttons_seen (OR since the last drain).

⭐ **One merged sample, not a byte stream** — that is the design, not an optimisation. `kbscan #42` hands
back raw scancodes because keys are discrete events; pointer motion is a **relative delta**, so the
useful unit is the sum since you last asked. The kernel folds every report and this returns the fold.
Streaming raw reports would have pushed the coalescing hazard into ring 3, where keeping only the last
report of a gap **amplifies** motion ~2-3x. ⚠ `buttons_seen` is what lets a click that starts *and
finishes* inside one frame survive.

⚠ **The take runs inside the IF=0 window**, deliberately: `hid_poll` also runs from the xHCI MSI-X ISR,
so read-and-clear of the accumulator with interrupts enabled can lose a whole report.
⚠ **No 256-iteration spin**, unlike `#42` as it was written — that spin existed to catch a PS/2 IRQ1,
which no longer exists, and `hid_poll` already loops to 64 events internally.

⛔ **It must not share `kbscan #42`'s ring**: `dX = 0x01` decodes through the Set-1 table to HID `0x29`
= **Escape**, so a one-pixel move on that pipe would quit the compositor — and that pipe also feeds
cyrius-doom's `input_poll`.

⚠ **Scope: the ring-3 dispatch is UNPROVEN.** The arm is written, the ABI gate agrees three ways
(kernel ↔ `agnos-userland-abi.md` ↔ cyrius 6.5.13's `SYS_PTRSCAN`), and bhumi's decode is unit-tested —
but nothing in ring 3 calls it yet, so "a user program can read pointer motion" is **not** demonstrated.
`AE-7` P4's cursor is the first consumer and proves it. Do not record P3 as proven before then.

### Added — the USB mouse is bound and its reports accumulate (`AE-7` P2, kernel half)

⭐ `hid_mouse_enumerate()` probes **every** addressed slot with no early exit and binds **every**
HID-boot-mouse interface it finds — ring, `SET_PROTOCOL=boot`, endpoint added to the input context,
Configure Endpoint, registry row, 16-deep pre-arm, doorbell.

⛔ **"Find the first protocol-0x02 interface" would have bound the KEYBOARD.** archaemenid's Keychron K2
advertises a boot mouse (interface 1, EP `0x82`) alongside its keyboard (interface 0, EP `0x81`) — *in
the same slot*. A first-match search binds that, sees no motion, and presents as "mouse enumerated,
cursor dead". Binding every such interface and merging motion into one pointer is what Linux's usbhid
does anyway: all mice are one seat. ⚠ The walker therefore takes `want_proto` **and a `skip` count**, so
a caller can reach the second matching interface on one device.

⚠ **The composite case needs no separate code path**, which is worth stating because it looks like it
should: `xhci_input_ctx_add_interrupt_in` sets Add Flags to `A0 | A_thisDCI`, and Configure Endpoint only
acts on flagged contexts — so adding the mouse EP leaves the keyboard's running EP untouched. What the
binder *must* do is skip `SET_CONFIGURATION` when the slot already has a bound endpoint; re-issuing it
would reset the keyboard out from under itself. Hence `hid_ep_slot_bound()`.

⚠ **The registry gained per-ENDPOINT ring state** (`ring`/`buf`/`idx`/`cycle`/`mps`) rather than
per-device: two endpoints in one slot cannot share a ring cursor.

### Fixed — relative motion no longer AMPLIFIES (D3)

All 16 armed TRBs point at one report buffer, and the keyboard's own comment accepts that "a gap that
coalesces >1 report keeps only the LAST". ⭐ **True for a keyboard, false for a mouse.** A keyboard report
is idempotent state; a mouse report is a *relative delta*, so keeping the last and applying it N times is
lossy **and amplifying** — at 8 ms reports against a 16 ms frame, a systematic ~2-3x motion multiplier
that would present as "the cursor is too fast" and get tuned with a sensitivity constant instead of
fixed. The drain now **folds** every event: dX/dY summed with explicit sign-extension (Cyrius has no i8),
buttons OR'd *and* latched so a click inside one gap is not swallowed, plus a sequence counter so ring 3
can tell "no motion" from "no poll".

⚠ **Scope: the accumulation is written, not yet observable.** Nothing in ring 3 can read it until
`#98 ptrscan` lands (P3), so "it accumulates rather than latches" is correct by construction and
**unproven by measurement**. Do not record it as proven.

⭐ **QEMU-verified end to end** (`-device usb-mouse` on the same `qemu-xhci`): two devices enumerate,
`hid: mouse configured, boot protocol on, EP=129 interface=0`, `boot-mouse interfaces bound: 1`, injected
motion produces `hid: first mouse report accumulated`, and the keyboard keeps typing on the same
controller. Arc sweep **17/17**. ⚠ QEMU attaches the mouse as a SEPARATE device — the composite
same-slot case is **iron-only** and must not be called proven from a green run here.

### Removed — every trace of i8042 / PS/2, by operator ruling

⛔ **Zero i8042 port I/O remains in the kernel.** Gone: `kb_isr_build()` (54 lines that hand-assembled 83
bytes of machine code whose middle instruction was `in al, 0x60`), the `var kb_isr[96]` .bss buffer, the
**IDT gate on vector 33**, `pic_mask_pit()` and its call site, and the 8042 pulse-reset rung in
`power_reset()`. `pic_init`'s master mask goes **0xFC → 0xFF**.

⚠ **The mask change is not cosmetic and had to land in the same commit as the gate removal.** With vector
33 unhooked, a delivered IRQ1 would reach `idt_init`'s default `isr_stub` — a bare `iretq` that sends **no
EOI** — and the 8259's in-service bit would latch forever. QEMU's q35 always has a real i8042 that can
assert it.

⚠ **What deliberately SURVIVES, because it is not PS/2**: `kb_buf`/`kb_head`, the `input_lock` family,
`kbd_irq_enable`/`disable`/`save`/`restore` (bare `sti`/`cli` — the xHCI producer itself uses the
save/restore pair), and **`scancode_to_ascii` with its Set-1 tables**. Set-1 is the USB path's *wire
format*: `hid_translate.cyr` maps HID usages to Set-1 and `hid_kb_push` writes them into that same ring.
Deleting them would have deleted the keyboard. The reboot ladder keeps ACPI RESET_REG (live on
archaemenid) and CF9.

⭐ **It was dead on the target and alive in the emulator — the worst combination.** archaemenid has no PS/2
port and its firmware does not emulate PS/2 over xHCI after ExitBootServices (CHANGELOG 1.30.9, iron
attempt 68); agnos itself disarms the SMM route during xHCI init, since `xhci_usblegsup_claim()` clears
the USBLEGCTLSTS SMI enables including "SMI on USB IRQ". But q35's i8042 is real, so in QEMU the path did
deliver keys — which is how ~15 minor versions of comments came to assert IRQ1 was "the archaemenid
keystroke path". The kernel contradicted itself in four places about this; those comments are corrected.

### Changed — one drain, dispatched on a bound-endpoint registry (`AE-7` P1)

⛔ **`hid_poll` consumed every event it looked at, matched or not**, so a second HID device could never be
served by a second poller — whichever ran first ate the other's Transfer Events. Endpoints now register
`(slot, DCI, kind)` and the single drain dispatches. Adding a device class is a row and a `kind` arm.
⚠ **The unit is an ENDPOINT, not a device**: archaemenid's Keychron K2 exposes a boot keyboard on EP 0x81
*and* a boot mouse on EP 0x82 **in the same slot**, so a slot-keyed table would collide.
⛔ `hid_poll`'s guard was `hid_kbd_slot_id == 0` — "no *keyboard*, do nothing" — which on a mouse-only box
drains nothing **and never re-arms `IMAN.IP`**. Now gated on the registry being non-empty.

### Changed — `kbscan #42`'s 256-iteration spin is one `hid_poll()`

That spin existed to give the CPU post-`sti` instructions to take a pending **IRQ1**. With PS/2 gone there
is nothing to wait for, and `hid_poll` already loops to 64 events internally. ⚠ It was ~256 posted MMIO
writes to `IMAN` per syscall on DOOM's per-frame input path. Cost: a report landing *during* the poll is
picked up next frame — one frame at 35 Hz.

### Added — the keyboard path names itself

`hid: first keyboard report dispatched via the endpoint registry`, once per boot. ⚠ Added because a
mutation test of that very dispatch read **green three times running** while the keyboard kept working,
and there was no way to tell from a log which producer had delivered. Now any boot says so.

⛔ **Verified honestly at the fourth attempt, and the first three were my error.** `agnsh-type-test.py`
builds **no image** — it boots whatever `scripts/smoke/agnsh-smoke.sh` last left in
`build/agnsh-smoke/agnos-agnsh.img`, so `build.sh` alone tests a stale kernel. The tell was the serial log
still printing the OLD boot banner. Correct order is `build.sh` → `agnsh-smoke.sh` → harness, and the
proof is a unique string in the **serial log**, not in the source or the binary. With that fixed: clean
build types and prints the marker; the mutant prints neither. Arc sweep **17/17**.
## [1.56.41] — 2026-08-07 — the desktop's window management on iron (RELEASED)

⭐ **1.56.40 shipped the whole ipc line — bites 0 through 11 are closed.** The channel band replaced
TCP-on-loopback, the desktop runs on it, an unmodified program's stdio rides it as a PTY, and pipelines
stream. `planning/ipc.md` §9.6's twelve-bite table has no open rows.

### Changed — `puka-terminal-test.py` gates the terminal's INPUT in three captures, not two

⛔ **Its two-capture oracle stopped meaning what it said.** The block reasoned that "agnsh does NOT echo
here", so any change in the glyph count had to be the shell answering. puka now owns the line discipline and
**echoes locally**, so typing alone moves the count — a two-capture test would have reported PASS on a run
where the shell never answered, the exact false green this harness exists to prevent.

Three captures, each half gated on its own: `before → mid` proves the typed characters were **echoed**
(puka's half); `mid → after` proves Enter made the shell **write back** (agnsh's half). ⭐ CR and LF paint
no pixels, so every pixel of the second delta is the shell's own output. The floor is **derived from the
run** — the first delta is 7 glyphs' worth of pixels, so two glyphs is `(mid - before) / 7 * 2` in this
boot's own font and scale, rather than a typed-in pixel constant.

### Added — the harness counts DELIVERED keys, so a lost keystroke names its own layer

⛔ **A lost keystroke and a broken line discipline were indistinguishable, and one masqueraded as the
other.** puka prints one `puka: key received` per decoded keycode; the harness counts them against what it
typed and reports `keys DELIVERED to puka: N of 9`. When no line reaches the shell it now separates two
different bugs: keys missing ⇒ **input delivery, and the terminal is untested by that run**; all keys
present ⇒ **the line discipline**, with the CR-vs-LF rule named in the failure text.

⚠ **A USB HID keyboard reports state on poll; it does not queue events.** The xHCI HID ring is drained only
inside `kbscan #42`'s bounded `sti` window (`kernel/core/syscall.cyr:8746-8757`) and the compositor calls
that once per frame, so a key pressed and released inside one frame is **never sampled**. Measured on the
QEMU CPU composite path at QEMU's ~100 ms default hold: **0 of 9**, **4 of 9**, **4 of 9** delivered — and
the 4-of-9 runs still completed a line and got an answer. Keys are now sent with an explicit
`PUKA_KEY_HOLD_MS` (default 500) hold: **9 of 9**, deterministic across repeats. ⛔ The delivery count stays
in the output either way, so the underlying loss cannot hide behind a passing gate. A human holds a key
~100 ms and would lose keys on this same path; the fix is a faster frame or IRQ-buffered HID reports, and
neither is test work.

### Added — the terminal gate counts TEXT ROWS, because a pixel count is blind to layout

⛔⛔ **This harness passed a build whose output was a STAIRCASE, before and after the fix, with
byte-identical numbers** (4991 → 5176 → 6032 both times). The 2026-08-07 iron burn rendered agnsh's help
with every line starting where the previous one ended — puka had no ONLCR — and the gate could not see it,
**by construction**: a staircase draws exactly the same characters and only puts them in the wrong places.
The operator's eye was the only oracle that could tell.

It now bins glyph pixels into 16-px bands from the topmost glyph — self-calibrating against the window's
unknown y origin — and gates on the count. Calibrated on **both arms of the same build** in QEMU:
**ONLCR present = 6 rows · ONLCR removed = 8 rows · ceiling 7**, the only integer between them, so a correct
run keeps one row of slack and a staircase still fails. ⚠ In the mutant run the shell still "ANSWERED",
which is exactly why the pixel count could not carry this.

### Added — `agnsh` in the burn staleness gate

⛔ **The 1.56.41 burn's whole claim was "the hosted SHELL answers", and nothing verified which shell was
staged.** `agnsh` is staged by `stage-agnsh.sh` rather than `stage-tools.sh`, and living in a different
script is exactly why it was missing from `burn-prep.sh`'s loop — the third instance of the failure that
loop's own comment names: *a tool absent from here is a tool that can be silently stale, and a stale oracle
does not fail, it agrees.* Now compared against `../agnoshi/build/agnsh_agnos`.

⚠ **Related but NOT staleness, and it produced a false finding on the way:** `agnsh` prints
`agnoshi 1.8.6` while agnoshi's `VERSION` says **1.8.8**, because `src/agnsh.cyr:47` hardcodes the string.
The staged binary is **byte-identical** to a fresh build, so the burn ran current code and the version line
simply lies. ⇒ **A burn log cannot be used to tell whether the staged shell is current.**

### Added — `PUKA_TERMINAL=1`: which binary occupies `/bin/puka` is a DECLARED choice

⛔ **Two harnesses need different binaries in the same slot, and that is two questions, not a bug.**
`aethersafha-clients-test.py`'s framebuffer oracle counts **present_probe's own** bright-green border and red
bar; `puka-terminal-test.py` needs the real terminal and overrides the slot in its own seed. The compositor
spawns the literal name `/bin/puka`, so exactly one can be staged.

`scripts/burn/stage-tools.sh` keeps **present_probe as the default**, so every existing gate keeps measuring
what it was calibrated against, and stages the **real terminal** under `PUKA_TERMINAL=1`. ⭐ That is what makes
an `AE-T2` iron burn possible at all: **a burn cannot override a seed the way a QEMU harness can.**

`scripts/burn/burn-prep.sh`'s staleness gate now accepts either occupant and **prints which one is in the
slot** (`/bin/puka is the REAL TERMINAL (1537640 bytes) -- AE-T2 is burnable`, or the present_probe line with
the command to change it). ⛔ It is not weakened: a binary matching **neither** source is still stale and still
aborts the prep. What it buys is that the prep says what is about to be flashed — that slot has misled every
reader of `stage-tools.sh` since it was created, and a burn card assuming the wrong occupant sends the operator
looking for a terminal that was never staged.

Nothing in the kernel is claimed in this cycle yet.

⚠ **Carried in, unresolved:** the `VFS_CHAN` close leak — `vfs_close_inner` has arms for
`VFS_EXT2_FILE`, `VFS_SEC_WFILE`, `VFS_PIPE` and `VFS_SOCK` but **none for `VFS_CHAN`**, so closing a
channel fd zeroes the slot and leaves the endpoint claimed until the process dies. Whoever takes it
must re-derive authority first: an inherited (non-owned) channel fd in a child must NOT release its
parent's endpoint on `close()`, which is exactly the violation the band exists to prevent. `chan_auth`
already implements the rule and `VFS_PIPE`'s owner-aware release is the shape to copy. ⚠ `vfs.cyr` is
included ahead of the chan state, so the fix belongs at the `SYS_CLOSE` dispatch, not in
`vfs_close_inner`.

⛔ **Still never burned.** Every result since bite 7 is QEMU. The 2026-08-03 iron proof at
`cpus online: 4` was the **TCP** path and is not evidence about the channel band.

---

## [1.56.40] — 2026-08-05 — the local-IPC channel band (RELEASED)

Scope: the desktop arc's remaining architectural item — replacing TCP-on-loopback as the display
control transport with a kernel-owned channel band on `#97`. Design, twelve-bite migration and kill
criteria: [`planning/ipc.md`](docs/development/planning/ipc.md) §9. Bites land in order; 0–5 land no
consumer, so everything up to the cutover reverts by not landing the next bite.

### Added — pipelines STREAM: 185191 bytes through a 4080-byte pipe (ipc bite 11)

⭐⭐ **`grep . /etc/ssl/cert.pem | wc` now returns 3112 lines / 185191 bytes — BYTE-EXACT against the
host's own `grep | wc`, through a ring 45x smaller than the payload.** Producer and consumer are alive
together for the first time. Before this the same pipeline reported **4080** — the ring size, to the
byte, because stage 1 ran to completion before stage 2 existed.

Three things had to be true at once, and each was measured failing on its own:

1. **Both stages spawned.** `#37` runs a child inside agnsh's syscall frame with IF cleared and the
   child non-schedulable, so nothing else on the box runs; `#43`-with-poll fixes scheduling but still
   waits to completion. Either leaves exactly one stage alive. (agnoshi)
2. **Producers must handle short writes.** kriya's 542 raw `syscall(1, …)` sites ignored the return, so
   a producer faster than its consumer silently dropped everything past a ring: measured **70347 of
   185311 bytes** — streaming, but 62% missing behind a plausible-looking answer. (kriya)
3. **A dead-but-unreaped proc is not an open write end.** Its fd table survives until `waitpid`, so
   counting it made the consumer wait for an EOF that only arrives when the shell reaps the producer —
   while the shell waits for the consumer. Measured as a hard hang. ⛔ **pid 0 is exempt**: it is the
   boot context, not a spawned proc, and skipping it hid a genuinely open write end from the selftest.

### Added — a pipe distinguishes "nothing yet" from EOF (ipc bite 11)

⛔ **`pipe_read` RETURNED 0 FOR BOTH, AND THAT IS WHAT CONFINED PIPES TO STORE-AND-FORWARD.** A
consumer scheduled alongside a live producer saw `0` the first time it out-ran the writer and quit, so
the only safe shape was to finish stage 1 entirely before starting stage 2. An empty pipe whose write
end is still open now answers **-2 (WOULD_BLOCK)**; **0 means EOF** and only that. Same convention as
the channel band and the cooked-line read, so a caller that handles one handles this.

A per-buffer **write-end count** (`pipe_rc_wcnt`, beside the existing total) is decremented when a
write end closes, at **both** death sites — `vfs_close` and proc teardown. ⚠ An untracked buffer (the
rc table holds 8) answers "no writers" rather than "writers open": that ends a read, where the other
direction would hang a reader forever on a pipe nobody can close.

**Mutation-proven in BOTH directions**, which single assertions cannot be: removing the writers check
fails "empty with a live writer was not WOULD_BLOCK"; freezing the count so it never decrements fails
"after the last writer closed was not EOF". Either assertion alone would pass on a constant — only the
*transition* proves a real count.

⚠ **Requires the shell to close the write end** (agnoshi, next release): `cmd1` exiting does not close
it, because the SHELL owns that fd, not cmd1. Leaving it open means the drain reads -2 forever.

### Verified closed by inspection — ipc bite 11's other two gaps

- **Gap 2 (`spawn_path#43` applies no redirect)** — closed at **1.56.39**: `spawn_redirect_apply(sp_pid)`
  is wired into the `#43` path, apply-only into the child's private table.
- **Gap 4 (N-stage tail state discarded on redirect restore)** — closed by **bite 10**: the read tail
  moved into the shared pipe buffer, so it is no longer carried in the swapped-in fd copy at all.

⚠ **Consumers must handle -2 to benefit.** Programs that branch on `read() <= 0` treat it as EOF and
stop at the first moment they out-run the writer — so kriya's `k_read` now retries on -2, which covers
every applet through one chokepoint. The loop needs no timeout: the kernel returns 0 the instant the
last write end closes, which is exactly Linux's blocking-`read` semantic.

⚠ `harness/pipe-stream-test.py`'s oracle is **derived from the host file at runtime**, not a constant.
The first version asserted the file's 3232 lines and failed a byte-exact run, because `grep .`
correctly drops its 120 blank lines — the guessed constant was wrong, not the kernel.

### Added — a live agnsh over the channel PTY (ipc bite 9)

⭐⭐ **THE REAL SHELL RUNS ON THE BAND.** `ptyhost agnsh` mints a channel, endows it in PTY mode and
spawns `/bin/agnsh` — which predates this band by years, was not adapted for it, and reads fd 0 with a
plain `sys_read`. It printed its `[ASSIST] >` prompt, received a command typed into the host's endpoint,
and answered with its Intent/Command/Risk block: **21 records** off the channel. Prompt out, keystrokes
in, answer out.

### Changed — `write(2)` on a channel fd is a SHORT WRITE, not an error

⛔ **WITHOUT THIS A PTY IS UNUSABLE.** agnsh's banner exceeds 64 bytes in a single `write`, and erroring
would make a shell fail to print its own greeting — "the terminal is broken" would be indistinguishable
from "the shell crashed".

`write(2)` is a **byte stream**; `CH_SEND` is a **record**. The difference is deliberate and now
asserted both ways: a `#97` caller asking to send more than one record is making a framing error and
still gets `-CH_E_ARG`; a `write(2)` caller is doing something ordinary and gets the POSIX answer —
accept what fits, return the short count, caller loops. ⚠ This does not smuggle stream semantics into
the band: record boundaries still hold on every `#97` path and a reader still receives whole records.
A stream writer's bytes simply arrive as several records, which is exactly what a tty does.

### Added — an UNMODIFIED program's stdio rides a channel: the PTY plumbing (ipc bite 9)

⭐ A PTY decomposes into (i) a bidirectional local channel, (ii) an end handed to a child at spawn,
(iii) a line discipline — and only (iii) is terminal-specific (`planning/ipc.md` §1). The band already
gave (i) and (ii). **What was missing is that a child born holding a channel could not `read`/`write`
it**: neither `vfs_read` nor `vfs_write` had a `VFS_CHAN` arm, so every program would have needed
rewriting against `#97`. ⛔ A channel every program must be rewritten for is an API, not a PTY — and
agnsh reads fd 0 with a plain `sys_read`, so it would never have worked.

- `CH_SEND`/`CH_RECV` factored into `chan_queue`/`chan_deliver`; `read(2)`/`write(2)` route through the
  same code, so the two paths cannot drift.
- **`CH_ENDOW` gains a PTY mode** (a4 = `CH_ENDOW_STDIO`): the endowed endpoint is installed at the
  child's fd **0, 1 and 2**. One endpoint behind several fds mirrors a real tty, where 0/1/2 are one
  device. Opt-in — a compositor endowing a display channel must not have its client's stdio replaced.
- Inert-by-construction holds on the new paths: `chan_fd_endpoint` returns -1 for "not mine" as well as
  "not a channel", so an inherited fd falls through to `vfs_read`, which has no `VFS_CHAN` arm.

**Two return values are the entire contract**, and both are asserted: empty → **-2 (WOULD_BLOCK)**,
never 0, or every `while (read(fd) > 0)` exits the moment the peer is slow; peer gone → **0 (EOF)**, so
that same loop terminates. ⛔ **The kernel does not block, and that is the design** — §9.4: *"No blocking
in v1, and the reason is the STACK, not a policy"*, one SYSCALL stack per CPU. It is doubly wrong here:
a channel's producer is a **peer process**, so `preempt_disable`-and-spin starves the very thing being
waited on. That is why `kbd_read_blocking` may spin and this may not — the keyboard's producer is an IRQ.

### Fixed — `chan_release_pid` matched the pid but not the INCARNATION

⛔ Authority was epoch-aware while **revocation was not**, so the check was decorative on the death
path. Matching on `pid` alone released endpoints belonging to a different incarnation of the same slot.
Not hypothetical: at boot the spawning context is pid 0 and the first user process is also slot 0, so a
parent that minted a channel and endowed one end had **both ends torn down when its child exited**, and
its own `CH_RECV` then answered BADFD on an endpoint nothing had closed. Now compares `chan_end_oepoch`
against `proc_epoch_get(pid)` — the same comparison `chan_auth` already made.

### Fixed — `CH_ENDOW` read its mode from stale `ksyscall_a4`

⛔ `ksyscall_a4` is shared staging: SEND and RECV use it as a **length**, and it is not cleared between
ops. The first cut of PTY mode read `a4 != 0`, so a caller that had just done `ksyscall_a4_set(8)` for a
SEND silently endowed in PTY mode and replaced an unrelated child's stdio. `CH_ENDOW_STDIO` is
deliberately larger than `CHAN_REC_BYTES` so no legal length can ever collide with it.

**Proof — `scripts/harness/pty-host-test.py`.** `/bin/ptyhost` (ring 3) mints, queues a record, endows
in PTY mode and spawns `/bin/ptyx`, which **never calls `chan_op`**: it reads fd 0 and writes fd 1 with
plain `read(2)`/`write(2)`. The host pumps its output back. Mutation-proven — disabling the stdio
placement fails it, and the harness names *which direction* broke.

⛔ **There is deliberately NO boot selftest for this, and the reason is a finding.** A parent holding a
channel across a spawn cannot be the boot context: pid 0 collides with the first child's slot (above),
and `sh_exec` is run-to-completion under IF=0 so the spawned child is never **scheduled** — the first
cut spun its whole retry budget against a peer that had not executed one instruction, with no trace of
the child in the log. The harness drives `ptyhost &` under agnsh so both processes actually run.

⚠ **Scope, honestly:** this is the PTY *plumbing*, not "a live agnsh prompt in a composited window".
Still open in bite 9: puka's agnos `pty_*` arm (all six functions are `#ifdef CYRIUS_TARGET_LINUX`
today, stubbed to -1 on agnos), agnsh's blocking read learning to retry on -2, and key forwarding.

### Fixed — `pipe_write` silently overwrote unread bytes (ipc bite 10)

⛔ **IT RETURNED THE FULL COUNT WHILE DESTROYING DATA.** `pipe_write` wrapped `write_head % 4088` with
**no reference to the reader at all**, so once the writer got a ring ahead it overwrote bytes the
reader had not consumed — and reported success. Same defect class as the `CH_RECV` truncation fixed
above: a local IPC primitive losing data behind a success return.

⛔ **The root cause was structural, not a missing bounds check.** The writer could not bound itself
against the reader **because it could not see the reader**: the read tail lived in the READ END's fd
slot (`base + 8`), and the writer holds the other fd — with per-proc fd tables the read end may not
even be in the same table. The read tail now lives in the **shared buffer**, visible to both ends:
`[0..8)` write head · `[8..16)` read tail · `[16..4096)` ring. `pipe_write` refuses once
`write_head - read_tail >= PIPE_RING` and returns short, which a caller can act on.

⛔ **The old `if (written >= 4088) { break; }` was not a bound** — it capped a single call, not the
ring. Two 3000-byte writes wrapped and corrupted, and each call individually looked in range.

### Breaking — pipe capacity is 4080 bytes, was 4088

Eight bytes bought the shared read tail. Any consumer or doc quoting the store-and-forward MVP's
"≤ 4088 B" should read 4080. **Migration:** none for correct callers — a write larger than the ring now
returns short instead of silently corrupting. A caller that ignored the return value and assumed 4088
went through was already losing data; it now sees a short count.

⭐ This is the prerequisite bite 11 (concurrent pipelines) needed regardless: a both-ends-visible tail
is what makes a *streaming* pipe possible. The store-and-forward MVP only worked because the reader
never ran concurrently with the writer.

**Proof, mutation-tested.** Assertions live in `syscall_harden_selftest`, and the load-bearing one is
deliberately last: a short write and a zero-length write **both pass on a wrapping ring** — a
corrupting ring reports "full" too. Only reading back a byte the writer tried to clobber and finding
the ORIGINAL value discriminates refusal from overwrite. With the refusal removed all three assertions
fire; restored, `sweep.sh` 17/17 and `exec-redirect-smoke` 4/4 (which includes a pipe-backed stdin read).

### Closed by verification — the loopback carve-outs were already gone (ipc bite 8)

**No code change.** Both items the bite names were re-derived live and found absent from the boot path:
the `net_ip == 0` DHCP wait is inside `loopback_selftest()`, whose only caller is `#ifdef
LOOPBACK_SELFTEST` and off by default; and the kernel **never reserved** ports 7700/7701 — all four
references are comments and tombstones. `planning/ipc.md` §10.1's claim that the wait was "in the boot
path" was stale and is corrected at §10.5.

⛔ **Recorded because it was nearly done by mistake: bite 8 is not "remove TCP from the kernel".** The
TCP stack, `lo_ring`/`net_is_loopback` loopback delivery, and `net_src_for` are general networking and
stay. A general-purpose kernel having TCP is not a display protocol riding on it.

### Added — a real desktop: two independent clients composited over endowed channels (bite 7)

⭐⭐ **THE CUTOVER IS COMPLETE END TO END.** `aethersafha --clients` no longer listens on anything. For
each client it **mints** a channel, **endows** one end (`CH_ENDOW`, which returns the fd number the
child will hold), stages `AGNOS_CHAN=<fd>` into the `#43` env blob, and spawns the client **already
holding a connected end**. `setu_srv_listen` and the accept block are gone, not bypassed. The client's
`setu_connect` dials nothing: it checks the kernel floor via `CH_CAPS`, reads `AGNOS_CHAN`, returns
that fd — four lines.

Proven under QEMU `-smp 4`: `present_probe` and `crab` both connect, complete the CREATE/ATTACH/COMMIT
handshake, and present — `placed: 2`, `presented: 2`, and the external framebuffer oracle counts 3500
client-coloured pixels (threshold 200). `sweep.sh` 17/17, `check.sh` 25/25.

### Fixed — `CH_RECV` silently truncated a record that did not fit the caller's buffer

`syscall.cyr` — RECV copied `min(rlen, rcap)` bytes and advanced the read cursor **past the whole
record**. A caller asking for a 16-byte prefix of a 24-byte record therefore got 16 plausible bytes and
lost the remaining 8 forever, with a success return. That is the failure mode a record transport exists
to make impossible, and it turned a client-side framing bug in setu into an unexplained handshake
failure two repos away.

RECV now refuses with `-CH_E_ARG` and **leaves the record queued**, so a caller with an
under-sized buffer gets an immediate, local, retryable error instead of silent data loss.

### Fixed — the diagnostic that ate the evidence

⛔ Worth recording as a pattern, not just a fix. The compositor's poll-failure branch called
`sys_chan_recv` to report *which* kernel error class it hit. On a record transport **a read is not a
peek**: that probe consumed the very handshake record it was trying to explain, so the instrumented
build failed differently from the build being diagnosed. Removed, with a comment at the site.

### Fixed — `epoll_wait` could halt the CPU permanently (bite 0)

`syscall.cyr` — the `found == 0` path ran a bare `arch_wait()`. That is `hlt` with **no `sti`**
(`arch/x86_64/io.cyr:143`), and every syscall handler runs **IF=0** (SYSCALL SFMASK). A `hlt` with
interrupts masked is not a nap: no timer tick, no IRQ, nothing can retire it. The CPU stops there and
the machine is gone.

It sat on the ordinary not-ready return — so an `epoll_wait` on an **unexpired timerfd** or an
unsignalled signalfd hung the box. The design note that proposed keeping it argued no consumer could
reach that path; that was wrong, it is the normal return.

Deleted; the handler falls through to `return found;`. `epoll_wait` is a **poll**, matching every other
agnos not-ready answer (`waitpid #4`, `sock_recv #49`, `sock_accept #57`, `flock #59` all return rather
than block). A truly blocking form needs a new proc state, a `sched_next` that skips it, a ready-edge,
**and** a relaxation of `do_context_switch`'s unconditional ready-reset — a scheduler arc, to be named
as one rather than smuggled in behind a `hlt`.

### Fixed — `SYSCALL_HARDEN_SELFTEST` had no runner, and had stopped compiling

⛔ **It shipped in 1.41.5 and nothing ever built it.** `SYSCALL_HARDEN_SELFTEST` appeared only in
`scripts/build.sh`'s compile-gate list — no smoke, no `check.sh` entry, no `sweep.sh` row. Two things
followed, both invisible for ~15 minor versions:

- It is, by its own header, the **only** coverage `epoll` / `timerfd` / `signalfd` have.
- It **did not compile**. Two `ksyscall` calls passed **3 arguments to a 4-arity function**
  (`ksyscall(9, u + 1024, 257)` and `ksyscall(30, u + 0, 4)`) — an error since cyrius made arity hard.
  Discovered only by building it for the first time.

New `scripts/smoke/syscall-harden-smoke.sh`, wired into `sweep.sh`. **A selftest nothing runs is not
coverage; it is a comment.**

### Added — a regression lock for the hang, whose oracle is a timeout

The selftest now drives `epoll_wait` on a **real** epoll fd watching a timerfd re-armed to 60 s, and
asserts it returns 0. ⛔ Every pre-existing epoll assertion in that file drove a **rejection** path (a
non-epoll fd, an out-of-range watch fd), all of which return long before reaching the `found == 0`
line — which is exactly how a box-hang survived inside a selftest that already "covered epoll".
**Coverage of the refusals is not coverage of the success path.**

⛔ **The oracle is that the next line prints at all.** On the unfixed kernel the call never returns, the
boot dies mid-selftest, and the smoke sees no `shsys:` verdict — so it reports "no verdict" as the hang
signature, distinctly from "verdict says FAIL". The two mean different things and a grep-for-PASS would
collapse them.

**Negative control, run:** restoring the bare `arch_wait()` makes the smoke exit 1 with the hang
signature; removing it again restores PASS.

### Added — shm gets an owner and a generation, and is released when its owner dies (bite 1)

⛔ **The shm table had NO owner field.** `shm_slot_valid` checked bounds and a non-zero phys, so **any
process could read, write or FREE any other's live buffer** — the desktop's pixel surfaces and mishran's
PCM among them. And **nothing released shm at all**: a client that exited left its slot claimed for the
rest of the boot, while `shm_create` calls `pmm_alloc_2mb()` unconditionally *regardless of requested
size*, so 16 exits of any size exhausted the 16-slot table.

`shm_owner[16]` + `shm_epoch[16]`, stamped by a shared `shm_claim(slot)` from **both** create paths
(`#71` pmm-backed and `#86` GPU-carveout, so the two cannot drift on who owns what) and cleared on free.
New `shm_release_pid(pid)` — sibling of `flock_release_pid` / `snd_release_pid` / `gpu_release_pid` —
called from **both** death sites, the `exit #0` path and the fault-kill path.

**`#74 shm_free` is now gated on the owner; a non-owner gets −1.** It is the only op gated. `#72`/`#73`
get a **warn counter** (`shm_xown_warns`) and are still permitted, because a cross-owner read is what
the compositor does every frame — refusing it would break the working desktop to enforce a rule nothing
can yet satisfy. The flip to enforcement waits until every client holds a channel to hang a grant on,
and will then be made against a measured number rather than a guess.

⚠ **The epoch is not decoration.** pids are recycled slot indices, so "pid 4 owns slot 2" goes stale the
moment pid 4 dies and the row is reused. `shm_epoch` is a per-slot generation bumped on every create.

### Added — `proc_epoch[16]`: the process generation counter, written and never read (bite 2)

Bumped in `proc_alloc_slot` — the single point every user proc is born through, and deliberately *not*
on the death path, since a slot that is never reused must still not alias the proc that last held it.
`(pid, epoch)` identifies a process **incarnation** rather than a table row, which is what makes an
inherited handle inert by construction at bite 4 instead of merely unlikely to collide.

⛔ **Unread on purpose.** Landing the write first means the counter is already correct and already
exercised across a full boot before anything gates on it — so if bite 4's authority check ever refuses
wrongly, the epoch is not one of the suspects.

### Added — selftest coverage for both, with negative controls

`SYSCALL_HARDEN_SELFTEST` gains: owner+epoch stamped on create · cross-owner **free refused** and the
slot surviving the attempt · cross-owner **read allowed AND counted** (both halves, because "allowed on
purpose" and "forgot to gate it" look identical from outside) · `shm_release_pid` reclaiming a slot ·
and `proc_epoch` bumping across a genuine **slot reuse** (allocate, mark the row dead, allocate again),
since a non-zero field would prove nothing about the property that matters.

**Negative controls, run:** removing the `#74` owner gate fails the refusal assertions; removing the
`proc_epoch` bump fails the reuse assertion. Both restore to green.

⛔ **`shm_release_pid` is INERT in the desktop workload — measured, not assumed.** Instrumented, it
frees nothing across a full `AE_CLIENTS_MODE=desktop` run: neither client exits inside the capture
window. The desktop therefore cannot validate it and must not be cited as evidence it works — the boot
selftest is the coverage, and it drives the release directly.

⛔ **`AE_CLIENTS_MODE=desktop` is FLAKY, and a flaky run was briefly misattributed to bite 1.** Three
repeat runs on one unchanged kernel produced two different failure shapes: serial "presented 2+" with
**0** client pixels and a console-sized framebuffer, and serial "FEWER THAN 2" with a perfectly good
**3,500** client pixels and a full-screen desktop. The first was initially blamed on `shm_release_pid`
and a disable-it bisect appeared to confirm that — **wrong, and the instrumentation disproved it: a
function that never executes cannot change an outcome.** The bisect was a false positive from the flake
itself. ⭐ Note which oracle held: the **framebuffer** was right in the run where the compositor's own
serial claim was wrong, which is the whole argument for gating on the panel rather than on the program
under test. Do not gate CI on `desktop` mode until the flake is understood.

### Added — `#97 chan_op` exists, with a region and a caps op (bite 4a)

The first kernel half of retiring TCP-on-loopback as the desktop's control transport. One number,
op-dispatched, in the `#93` / `MDO_OP_SUPPORTED` style that grew a whole arc with no ABI break.
⛔ `#96` remains `fork`'s — the operator assigned both, and whichever lands first does not take the
other's number.

**The 2 MB region**, reserved at boot and carved into 32 × 4096 B pages. ⛔ Reserved **after**
`pmm_setup_directmap`: the design rests on `DIRECTMAP_BASE`, the only alias every per-proc CR3 mirrors,
so reserving earlier would stamp a VA that means something else. Zeroed once at reserve, so a channel
page can never hand a new owner the previous occupant's bytes. A failed reserve is non-fatal —
`chan_op` answers `CH_E_NOREGION` rather than refusing to boot over a band nothing consumes yet.

⭐ **Static region rather than 32 `kmalloc`s** (§9.2): creation cannot OOM · it sidesteps the 4096-byte
slab ceiling · and decisively, **because channel pages are never `kmalloc`'d or `kfree`'d, a destructive
op inside a validate-then-execute batch cannot produce a kernel-heap use-after-free** — the exact bug a
judge found in the rejected shared-region design.

**`CH_CAPS` (0x00)** writes `+0` op mask · `+4` region pages · `+8` region-reachable. ⛔ The reachable
word is a **live probe under the CALLER's CR3**, not a boot-time cache: the claim under test is that the
region resolves from a client's page tables, and a value stamped at boot under the kernel CR3 would say
nothing about that. The probe writes the region's **last** 8 bytes, not the first — page 0 is what a
real mint hands out, and a probe that scribbles on it would test the region by corrupting it.

⛔ **Reserved ops read 0 in the mask.** `CH_HANDOFF` (0x0A) and `CH_DIAL` (0x0B) return `−CH_E_BADOP`
with their caps bits clear; the kernel will never dial. `CH_ENUM` is absent from v1 (§9.7 item 5 — the
one op with no consumer). A client negotiates on that mask, so advertising an op the kernel does not run
is exactly how a client "works" against a kernel that cannot serve it.

Selftest asserts CAPS, the mask, the region, and refusal of a short out-buffer, both reserved ops and an
unknown op; gated in `syscall-harden-smoke`.

⚠ **THE KILL CRITERION IS ONLY HALF-MET, AND THE GATE SAYS SO.** §9.9 names reachability *from a spawned
client's CR3*. The selftest runs from the boot path and proves the **kernel-CR3 half only** — the region
exists, is direct-map addressable, and survives a write/read round trip. The spawned-client half needs a
ring-3 caller. The smoke's own label carries that caveat rather than reading like the criterion is met.

🔴 **BLOCKED, and `check.sh` is red on it by design:** the cyrius peer has no `SYS_CHAN_OP = 97`, so the
ABI gate reports `kernel 97 · abi-doc 97 · cyrius 96`. That is the gate added earlier this cut doing
precisely its job — holding a new syscall to landing its constant in the same change as its dispatch
arm. cyrius 6.5.7 shipped today but carried repair work (hisab's allocator, agnosai's wrappers, `include`
resolution), not this. The ring-3 test is blocked behind the same two lines. ⛔ A raw `syscall(97, …)`
was deliberately **not** used to route around it — raw numbers on agnos paths are a confirmed shipping
defect class in this ecosystem, and the gate exists to stop exactly that.

### Fixed — `CH_RECV` silently truncated a record that did not fit, and consumed the rest

It did `if (rlen > rcap) { rlen = rcap; }` — delivering a prefix and advancing the cursor past the
remainder. **That is stream semantics smuggled into a record channel**, and it makes all-or-nothing a
lie the caller cannot detect. A too-small buffer now returns `-CH_E_ARG` and the record **stays
queued**.

⛔ **It cost a real diagnosis, in another repo.** setu's `setu_read_msg` reads a 16-byte header and then
the body separately — correct for a stream. Against this truncation the header read consumed the ENTIRE
message and the body read found nothing, surfacing as an unexplained handshake failure inside
aethersafha, two layers away. Refusing here makes it immediate and local.

Selftest asserts **both** halves — the refusal, and that a full-size read afterwards still returns all
8 bytes intact. A refusal that quietly consumed the record would pass the first assertion alone.

⚠ setu's read path is still stream-shaped and must be fixed there; this only stops the kernel lying
about it. Filed: setu `issues/2026-08-06-read-msg-is-stream-shaped-on-a-record-transport.md`.

### Added — the band's objects, and BOTH of §9.9's kill criteria closed (bite 4)

`CH_MINT` / `CH_SEND` / `CH_RECV` / `CH_CLOSE` (mask `0x1F`; `CH_HANDOFF`/`CH_DIAL` still reserved with
their bits clear). 32 endpoints → 16 channels, `e` paired with `e ^ 1`, each owning one 4096 B page of
the region as its **inbox** — a sender writes into its peer's.

⛔ **Cursors live in kernel arrays, not in the page.** Ring 3 cannot address a cursor, so forging
occupancy, rewinding a peer's consumption, and injection are all gone by construction — the rejected
shared-region design put them in userland-visible memory and its own judge found keystroke capture and
injection on the display channel with *"NO MITIGATION IN v1"*. Ring 3 never addresses the page either;
it copies through the syscall. Cursors are monotonic and never wrap, so equality means genuinely
drained.

Bounded-queue with **drop-oldest**, not back-pressure — §3 measured presents as idempotent overwrites
and input as droppable, and a blocking send would starve the peer it waits on. Drops are counted.

### Fixed — channel endpoints were never released at process death

`chan_release_pid` at **both** death sites, beside `flock_`/`snd_`/`gpu_`/`shm_release_pid`. The first
cut of the band shipped without it and nothing caught it: the boot selftest closes its channels by hand,
so a leak on the death path is invisible there. With 16 channels, the sixteenth client crash exhausts
the table. ⚠ It deliberately does **not** close the peer — peer-gone is derived from
`chan_end_open[e ^ 1]`, so the survivor must keep its own endpoint open in order to be *told* its peer
died.

### Added — `tests/chan/chanx.cyr` + `chan-ring3-smoke.sh`: the kill criteria, actually tested

⭐ **Kill criterion 1 — the 2 MB region resolves from a RING-3 proc's CR3.** `CH_CAPS` re-probes live on
every call, so calling it from ring 3 *is* the test. The boot selftest runs under the kernel CR3 and
could never have closed this.

⭐⭐ **Kill criterion 2 — an INHERITED channel fd is inert.** The **kernel** mints the channel and queues
a record *before* exec'ing chanx; `elf_load_from_file` copies the creator's whole fd table (agnos has no
CLOEXEC), so the child holds a real, open, live handle owned by a proc that outlives it. Both SEND and
RECV are refused, while the same proc's **own** channel works — because "refused" and "refused for the
right reason" are different claims, and a kernel that blanket-refused every `chan_op` from a second
process would pass the first assertion while being badly wrong.

⛔ **Three "waits" that did not wait, all predicted by the design doc I was implementing.** The first
shape had a parent spawn a child and wait: `sched_yield` is a documented no-op under a foreground `run`
(§9.4); `waitpid #4` answers 0 for "not yet", so a `>= 0` loop exits instantly; and `sleep_ms` holds
preempt disabled and **starves the very child it waits for** — §9.4 names that as "the poison that made
TCP toxic". Minting in the kernel before exec removes the need for concurrency entirely.

⛔ **The smoke's negative assertions were passing on SILENCE.** "No record accepted from an inherited
fd" is satisfied just as well by a child that never ran — which is exactly what was happening. Every
`deny` now requires positive evidence the arm executed and reports **VACUOUS** otherwise. On the primary
kill criterion that is the difference between a proof and a decoration.

⛔ **And the dwell marker truncated the test.** `CHANX-INH-` matched the *first* verdict line and killed
QEMU before the second assertion ran, so a cut-off log read as a failing one. The marker is now
`CHANX-DONE`, a line that can only be last — the exact hazard `qemu-dwell.sh`'s own header warns about,
met in practice.

**Mutation-proven, and the first attempt was not enough.** Removing the owner check alone did **not**
break the test — the two identity checks (owner, and the bite-2 proc-epoch stamp) are **redundant**, so
either alone suffices. Only removing **both** makes the inherited fd accept records, and the smoke then
fails. ⚠ That run also exposed a confound: with an empty queue, RECV "refused" merely because there was
nothing to read. The kernel now queues a record first, so a RECV refusal can only be the authority
check — re-controlled, and with both checks removed **both** SEND and RECV are accepted.

### Added — endowment: a child can be BORN holding a channel (bite 5)

`CH_ENDOW` (0x05, mask now `0x3F`) arms an endpoint; `chan_place_into_child` in `proc_create_user`
places it into the next child. ⭐ **This is what makes inert-by-construction usable rather than merely
safe** — without placement, "an inherited fd does nothing" would mean a child could never hold a
channel at all. A sandbox is DESCRIBED (a list of endowments), not CARVED (a list of denials).

⭐ **Placement is a MOVE, not a share.** Ownership transfers to the child and is re-stamped with the
child's proc epoch, so the parent's own fd goes inert by exactly the rule that makes an inherited copy
inert. A share would leave both usable and quietly defeat the model.

⛔ **You can only endow what you currently own** — `CH_ENDOW` re-derives authority first, so an
inherited (inert) claim cannot be used to hand a channel onward. Otherwise inertness would leak through
the grant path.

⛔ **Refuses if the child is on the GLOBAL fd table.** `vfs_fd_inherit` returns success on `kmalloc`
failure, leaving `proc_fd_base[child] == 0` — "use the global table". Placing there would write a live
channel fd into the table proc 0, every kthread and every future global-table user shares. The test is
the RESOLVED table, not `proc_fd_base_get(pid) == 0`, because proc 0's base is set explicitly to
`&vfs_table` — the same trap that bit `spawn_redirect_apply` at 1.56.39.

⛔ **The arm is stored as endpoint+1 so that 0 means UNARMED.** Module-scope globals zero-init, so a −1
sentinel would need a boot-time init — and until it ran, the hook would read 0 as "endpoint 0 is armed"
and place a channel nobody endowed into the first process in the system. Caught before first boot;
biasing by one removes the init-order dependency instead of adding a step a future reorder could move.

**The no-op path was proven first, as §9.6 requires for "the highest-risk bite."** The hook sits on the
birth path of *every* user process, so it landed behind `chan_endow_enabled = 0` — present and
returning immediately — and a full sweep was **17/17** in that state before it was turned on. Setting
that back to 0 is the intended rollback if placement is ever implicated.

**Proven in `chanx`, one process holding both kinds of handle:** fd 3 **inherited** → refuses SEND and
RECV; fd 5 **endowed** → works; its own minted channel → works. Together those separate "the kernel
refuses this proc" from "the kernel refuses this CLAIM", which is the distinction the whole model rests
on. ⚠ The endowed fd is found by SCAN, not announcement — the design routes announcement through `#43`'s
`KEY=VALUE` env blob (Wayland's `WAYLAND_SOCKET` trick) and that plumbing is not built; scanning proves
the property without pretending otherwise.

⛔ **One assertion was REMOVED from the boot selftest rather than left to mislead.** "The parent's own
fd is now inert" cannot be tested there: at that point in boot `proc_current_get()` and the slot
`proc_create_user` returns are the **same index**, so parent and child are one pid and the check passes
trivially — measured, the parent's send returned 8. A degenerate fixture, not a defect. The property is
asserted in `chanx`, where the two procs genuinely differ. Same reason kill criterion 2 could not live
in the boot selftest either.

### Added — announcement: `CH_ENDOW` returns the fd the child will hold

A child must be able to FIND the channel it was born holding, or endowment is useless. `CH_ENDOW` now
returns that fd index instead of 0, and the parent puts it in the child's environment — **exactly
Wayland's `WAYLAND_SOCKET` shape, where the compositor sets the variable, not the kernel.**

⛔ **And the kernel could not do it anyway, which settles the design rather than merely favouring it.**
`elf_load_from_file` bakes the env strings into the child's init stack at `elf.cyr:417-451` and calls
`proc_create_user` — where placement happens — only at `:473`. By the time the kernel knows the fd, the
env is already written. So the number is decided at **arm** time and handed back.

⛔ **Placement uses the number decided at arm time and REFUSES if it is no longer free** — it does not
re-scan. A re-scan could land the endowment somewhere other than the index already announced to the
child, which would leave the child looking at an empty slot: far harder to diagnose than a refusal, and
precisely the divergence announcement exists to prevent.

**Proven end-to-end in `chanx`:** the parent announced fd **7**, the child used fd **7** *directly* and
it worked, while its inherited fd 3 stayed inert. ⛔ The test no longer SCANS for a working fd — scanning
proves only that *some* fd works, which cannot catch a placement that lands somewhere other than the
announced number. The kernel selftest additionally asserts the placed slot carries `VFS_CHAN` at exactly
the announced index.

### Added — the channel band's contract is executable before the band exists (bite 3)

`tests/chan/chantest.cyr` + `scripts/check/chan-semantics-check.sh`, wired into `check.sh`. Host-side,
no kernel, no QEMU, milliseconds.

⭐ **Why a proof before an implementation.** §9.8 of the design says it outright — *"NOTHING HERE HAS
BEEN BUILT OR BOOTED"*; every claim is read-only static analysis. That makes the contract its own only
specification, and a kernel written against a spec nobody executed gets measured against itself. This
runs the contract on a substrate that already implements the hard part correctly — Linux
`socketpair(SOCK_SEQPACKET)`, where message boundaries are the kernel's job — so the `chan_*` arms have
something **external** to be wrong against when they land.

**18 assertions across the four properties the design actually rests on:**
- **Record framing is all-or-nothing** — two 40 B sends arrive as two 40 B receives, never coalesced,
  never split. The AF_UNIX debt §9.5 names first.
- **The batch IS the poll** — 3 channels with data on 1 returns COUNT **1**, and the two idle ones
  yield per-record `WOULD_BLOCK` **without aborting the batch**.
- **Peer-gone is a per-record result, derived not stored** — closing one writer gives `PEER_GONE` on
  *its* record while a live channel in the same batch still delivers. A design that surfaced peer death
  as a batch error would take a whole compositor rotation down with one client exit.
- **Cursor equality means genuinely drained** — every sent record received exactly once, then
  `WOULD_BLOCK`.

⭐ **Negative control, and it is the design's own claim turned into a test:** building the same file
over **`SOCK_STREAM`** instead of `SOCK_SEQPACKET` fails exactly the **6** framing/ordering assertions
and passes the other 12 — so the proof discriminates the specific property it names rather than merely
passing.

⛔ **What it deliberately does not cover:** the authority model — an inherited handle being INERT by
construction (§9.3) — has no Linux analogue, since SEQPACKET fds inherit and work normally. That is
bite 5's selftest and its kill criterion. Do not cite this check for it.

⛔ **No repo was minted for this.** It is a proof; a repo is what would earn it a name.

### Changed — the arc sweep stops waiting for a clock: ~20 min → **395 s**, 16/16

⛔ **The problem was dead air, not slowness, and it had been measured and left.** `state.md` recorded on
2026-07-23 that **QEMU never exits on its own** — the kernel boots, prints, halts, and sits — so every
smoke consumed its entire `QEMU_TIMEOUT` even when the work finished in two seconds. Proven then by
shrinking one: `fp-selftest-smoke` returned identically at 40 / 15 / 8 / 5 s.

New `scripts/smoke/lib/qemu-dwell.sh`: background QEMU, poll the log for a marker, SIGTERM, **and wait
for the process to actually exit** before returning. That last step is the point — `hda-smoke.sh`
documents why the synchronous form was chosen (*"the file is fully written once QEMU has exited"*), and
`wait` preserves that guarantee instead of discarding it; a bare kill plus an immediate `grep` would
reintroduce exactly the flush race. The timeout is unchanged and still backstops a hung boot.
**35 smokes converted.**

⛔ **Marker choice is where this goes wrong, so it was made structural rather than per-file.** Stopping
on a line printed *before* something a smoke asserts builds a truncation bug that reads as a kernel
regression. Verified that **no sweep gate feeds stdin** — every one is boot-phase-only, and boot
selftests run from `main.cyr` before kybernet execs the shell, so the prompt provably follows anything
they printed. A smoke that DRIVES the shell must pass its own last expected line instead.

⚠ `hda-smoke` / `hda-dual-smoke` still use fixed dwells: they take `-serial file:` (QEMU owns the file)
rather than `-serial stdio`, which the helper does not yet cover.

⛔ **Recorded because it cost a full sweep and hid itself.** The first cut of the helper referenced a
bare `$QEMU_DWELL_DEBUG`; the smokes run under `set -eu`, so that is an unbound-variable **abort** on
every run that does not set it, and 7 gates failed. It was invisible because **the run used to validate
the change was the only one with that variable set** — the debug flag added to observe the fix was the
single configuration that dodged its own bug. Re-verified afterwards with the variable *unset*, which is
the case that broke. A neighbouring `set -e` hazard went with it: `kill -0 X && kill -KILL X` returns
non-zero when the process has already exited, which is the common case here.

## [1.56.39] — 2026-08-05 — three kernel items the desktop has been owed (RELEASED)

Scope: the 1.56.35 cut named eight things the sovereign desktop needs from the kernel and closed with
the SMP fault (K1) and the `net_src_for` documentation (K6). Three of the remainder are small,
self-contained and independent of the local-IPC band that lands at 1.56.40. They are those three.
`build/agnos` **1,952,640 B**.

### Added — `spawn_path #43` consumes an armed `exec_redirect #62`

New `spawn_redirect_apply(pid)` (`kernel/core/syscall.cyr`), called from the `#43` handler between
`proc_set_ring3` and `proc_set_state(pid, 1)`. Before this, only `execwait #37` consumed the one-shot
redirect, so a **background** child's `stdout` could not be pointed anywhere and every concurrent proc
wrote to the console at once. Measured cost of that on 2026-08-02: three interleaved desktop procs
produced `a11y nodes synced:run: exit 142` mid-line, and the klug dump was skipped on the boot that
carried the evidence.

**Apply-only, and the asymmetry with `#37` is structural.** `#37` is run-to-completion — the parent is
suspended, the child runs on the parent's own `vfs_table` entry, and `exec_redirect_restore` has to put
it back. `#43` returns immediately with the parent still live, and the child was created holding its
**own private fd table** (`vfs_fd_inherit`, from `proc_create_user`), so the swap goes into that copy,
is private to that child for its whole life, and dies with the table at reap. No backup slot is taken,
so a `#43` redirect cannot collide with a `#37` redirect armed on another CPU.

⛔ **Refuses when the child has no private table.** `proc_fd_base[pid] == 0` means the child fell back to
the global `vfs_table`, which is what happens when `vfs_fd_inherit`'s `kmalloc` fails — and
`vfs_fd_inherit` returns 0 on success *and* on that failure, so no caller can distinguish them. Writing
the redirect there would repoint fd 1 for proc 0, every kthread and every later global-table user,
permanently, with nothing to restore it. The refusal prints
`spawn: no private fd table for the child -- redirect skipped`.

The one-shot is cleared on **every** exit path — applied, refused, and on a failed load (`sp_pid < 0`) —
so an arm can never survive into a later exec it was not meant for.

⛔ **The refusal tests the RESOLVED table, not `proc_fd_base_get(pid) == 0`.** Two different states mean
"this proc uses the global table" and only one of them is a zero base: the implicit fallback
(`proc_fd_base[pid] == 0`, what a failed `vfs_fd_inherit` leaves), and an **explicit**
`proc_fd_base_set(0, &vfs_table)` for proc 0 at `vfs.cyr:264`. A `== 0` guard passes the second one
through and writes the global table. That is not hypothetical — it is what the first build of this
function did, and the boot selftest below caught it on proc 0. The test is now
`vfs_fd_table_of(pid) == &vfs_table`, the same shape `proc_destroy_fd_table` uses at `vfs.cyr:234-235`.

### Added — `spawn_redirect_apply` boot selftest, under the existing `EXEC_REDIRECT_SELFTEST` gate

Nothing in the tree arms `#62` before a `#43` yet, so the apply path had no caller and would have
shipped with only its no-arm early return ever executed. `spawn_redirect_selftest()`
(`kernel/core/main.cyr`) drives both halves directly and asserts the invariant the refusal exists to
protect — that a redirect never reaches the global table:

- **negative control** — a redirect aimed at proc 0 must return −1, must leave the one-shot cleared
  rather than armed, and the global `vfs_table` entry must be byte-identical afterwards;
- **positive** — `vfs_fd_inherit(15, 0)` (the same call `proc_create_user` makes) gives a pid its own
  table; after apply, that copy's entry 20 equals its own entry `dst`, **and** the global is still
  byte-identical.

`scripts/smoke/exec-redirect-smoke.sh` gains both assertions: **4 passed, 0 failed**.

### Changed — the ELF loader's user-image floor is `0x400000`, not `0x200000`

`kernel/core/elf.cyr`, at **all four** sites: `e_entry` and the `PT_LOAD` `p_vaddr` check in **both**
`elf_load` (the in-memory `#3` path) and `elf_load_from_file` (the `#37` / `#43` path). The roadmap item
named only the two in `elf_load_from_file`; the in-memory path carried the byte-identical hazard.

PD[1] covers 2–4 MB and holds the boot TSS RSP0 seeds (`gdt.cyr:45-48`), so a crafted on-disk `p_vaddr`
in that range could have mapped a **user** page over the stack pointer the CPU loads on the next
ring-3 → ring-0 transition.

Measured before changing it: **all 44 staged binaries** in `build/rootfs/bin/` base their first `PT_LOAD`
at `0x400000` with `e_entry` `0x4000b0`, zero exceptions. The floor costs nothing and retires the class.

### Changed — `pmm_kva_for_access` returns the direct-map alias for every physical address

`kernel/core/vmm.cyr`. It used to split at 256 MB — identity below, `DIRECTMAP_BASE + phys` above — and
the split was the hazard rather than the fix. The direct map covers **all** RAM (`pmm_setup_directmap`'s
loop starts at phys 0) and every CR3 inherits it, because `proc.cyr` mirrors kernel PDPT[1..511]. The low
identity map does not survive per-proc: PD[0..7] (phys < 16 MB) is where a per-proc CR3 puts the **user
image**, and PD[128..510] above 256 MB is the user's own mmap arena. An identity VA handed back from here
is therefore a VA that means something else under the CR3 the caller is running on.

`hda.cyr:1594-1602` already wrote `DIRECTMAP_BASE + pcm` by hand, with a nine-line comment, to route
around this function's low answer. That carve-out is now what the function does.

The dropped `vmm_map(phys, phys, 0x83)` was a **side effect, not a result** — every call site
(`elf.cyr:123/304/348`, `proc.cyr:1664/1676`, `syscall.cyr:823`, `hda.cyr:1579`) uses only the returned
handle and none re-derives an identity VA from `phys` afterwards; verified site by site.

⛔ **Ordering constraint, now load-bearing:** the direct map is installed at `main.cyr:232`. The earliest
call site is `hda_probe` at `main.cyr:661`. Do not add a caller ahead of line 232.

### Fixed — the desktop harness reported on launch paths it never ran

`scripts/harness/aethersafha-clients-test.py`. One mode runs per boot, so one of `fg_code`/`bg_code`
is `None` on almost every run purely because that arm was never launched — and the verdict block
tested the codes alone. Measured against this kernel at `AE_CLIENTS_SMP=4`, while **both** arms
independently reached exit 95:

| mode | printed | reality |
|---|---|---|
| `bg` | "Backgrounded (`&`) works; **FOREGROUND does not**" + "⇒ agnsh's blocking execwait #37 frame prevents the spawned clients being scheduled" | foreground was never launched; the cause was invented |
| `fg` | "Both clients present on **BOTH** launch paths" | one path ran |

A false red and a false green out of the same block. It now records `ran_fg` / `ran_bg` **at the
launch sites** rather than re-deriving them from `MODE` at verdict time, prints
`— (not run in this mode)` for an unrun arm, reports each arm that ran on its own, and gates the
cross-path comparison on both having run. `None` now means exactly one thing — **ran and produced no
exit code** — which is a failure.

### Added — `desktop` mode gates on the framebuffer, not on the compositor's own claim

The harness printed framebuffer colour counts and advised *"judge this on the FRAMEBUFFER counts"*
while `rc` rested entirely on the serial line the compositor prints about itself — a shared-premise
oracle, since the program making the claim is the program under test. `desktop` mode now fails unless
the panel carries client pixels, and fails outright when no screendump was produced (`None` evidence
is not zero evidence).

⛔ **The gate excludes dim-green deliberately.** Measured with both clients presented: dim-green
**952,731 px** of a 2048x2048 capture — 22.7% of the screen, which a client's 1-px border cannot be,
so that count is dominated by compositor chrome in the same dark range. Gating on it would pass a
desktop **hosting nothing**. The gate is present_probe's own bars + bright border: **signal 3,500 px
· console null 0 px** (measured twice), floor **200**, overridable via `AE_CLIENTS_FBMIN`.
**Negative control:** forcing the floor above the signal makes the harness **exit 1** — the gate is
wired to the exit code, not printed beside it.

⚠ Two gaps stated rather than hidden: bright-green reads **0 even on a passing run**, so the red bar
carries the gate alone; and dim-green was excluded by reasoning from the pixel count, **not** from a
measured hosting-nothing control.

⛔ **Also fixed: the counts mean different things per mode, and that was never printed.** `--clients`
stops ~1.09 s in, so in `fg`/`bg`/`both`/`armed` the screendump lands after the run ended and is a
picture of the **console** — zero client pixels there is the expected result. Every mode now says
which case it is in.

### Changed — syscalls `#96` and `#97` are reserved, and the local-IPC band has no codename

`docs/development/roadmap.md`: **`#96` = `fork`**, **`#97` = `chan_op`** (operator assignment, 2026-08-05).
The next free number is `#98`. Neither `#96` nor `#97` is minted yet; neither is available to anything
else.

`docs/development/planning/ipc.md` §9: the local-IPC design ships as the kernel band **`chan_*`** on
`#97`, VFS tag `VFS_CHAN = 11`, ops `CH_*` — in the convention `pipe_*`, `shm_*`, `sock_*` and `net_*`
already use. The design's working codename is dropped; the candidate names stay in §5 as the record of
the judging and appear nowhere in the kernel. Both of §9.7's remaining operator questions are closed.

## [1.56.38] — 2026-08-04 — the latch closes its own loop, and the console boots native (RELEASED)

Scope: the two things the display arc left behind. **(1)** The modeset latch never auto-disarms after a
successful modeset, so every boot in the 1.56.36/37 arc opened with `previous attempt did not disarm --
SKIPPED` and needed a manual `rm /.modeset-armed`. **(2)** The boot console is still 800x600 upscaled —
`MDO_OP_NATIVE` is iron-proven, so the native modeset can move to boot time, behind the latch that (1)
makes usable.

### Fixed — a second `gpu_display_probe()` retracted a working display, breaking the compositor

`gpu_display_probe()` now returns early when `gpu_display_ok == 1`. It runs from two sites since the boot
modeset moved early; by the time the later one runs the console has legitimately moved to the pan buffer,
so its `fb_phys` match cannot succeed and it was setting `gpu_display_ok = -1`.

Not cosmetic: `gpu_blit_arm()` gates on `gpu_display_ok == 1`, so the double buffer never armed,
aethersafha could not page-flip, and it rendered into the console's own buffer while `fb_console` kept
painting there. Measured on iron 2026-08-04: `gpu: display pipe surface not matched` at log line 159, with
the shell visibly flashing through the running desktop.

### Changed — the boot pan arms BEFORE the boot log replay

`klug_replay_fb()` repaints ~116 captured lines; at 2560x1440 a 45-row console scrolls ~71 times to do it.
Running it before `mdo_pan()` cost 71 x 14,400 KB ≈ **1 GB of WC stores** — the single most expensive
operation in the boot. Arming the pan first makes the same replay ~22 MB, a ~45x reduction. Order is now
`mdo_native()` → `mdo_pan()` → `fb_defer_off()` → `fb_console_clear()` → `klug_replay_fb()`.

### Changed — the boot modeset moved to the earliest point its preconditions allow

The block now runs immediately after `klug_spill_prepare()` (log line ~116) instead of after
`gpu_pixclk_discover()` (~141), and calls `gpu_display_probe()` itself rather than waiting for the call
site behind `gpu_fw_load` / `gpu_fw_load_set` / `gpu_vm_setup` — none of which is display. The floor is the
**latch**: `modeset_arm` needs ext2, so nvme → GPT → mount → `modeset_latch_check`.

Because `fb_console` is still deferred at that point, the panel's first agnos content is already native and
already panned, with the boot log replayed into it — there is no 800x600 phase.

### Changed — the boot modeset no longer waits ~2 s for a number it already has

New `gpu_raster_derive()` (`kernel/core/gpu.cyr`), extracted from `gpu_pixclk_discover()`: the OTG reads
that set `gpu_h_active` / `gpu_v_active` / `gpu_h_total` / `gpu_v_total`, without the ~2 s refresh
measurement (five ~0.33 s windows in `gpu_refresh_ticks`) that follows them. `gpu_pixclk_discover()` now
calls it and keeps the measurement half; both call sites can run in the same boot.

The boot native+pan block moves from after `gpu_pixclk_discover()` to immediately after
`gpu_scanout_matchgeom()`, ahead of `gpu_display_vblank()` and the measurement. Measured consequence of
the old placement (iron, 2026-08-04): the console switched to native at the very end of boot, after ~55
log lines at 800x600 and a stall with nothing printing. The firmware/compute tail and the refresh
measurement now run on an already-native, already-panned console.

### Added — the console boots at native resolution AND hardware-panned

`main.cyr` calls `mdo_native()` after `gpu_pixclk_discover()`, then `mdo_pan()`, then `klug_replay_fb()`.
Ordering is forced: `mdo_native` refuses unless the target equals the link's active raster, and
`gpu_h_active` / `gpu_v_active` are not derived until `gpu_pixclk_discover`; `mdo_pan` refuses unless the
pipe is already native.

**Both are needed together.** Measured on iron, `Timer ticks before sched`: **28** (1.56.37, 800x600) →
**149** (native with the software scroll, two consecutive boots) → **11** (native + pan). The middle
number is the 14,400 KB-per-scrolled-line cost the pan exists to remove, reintroduced by taking the
console native without taking it panned; the last is the pan paying for itself against even the 800x600
baseline.

Neither is gated on success: a refusal (no GPU, latch armed, pipe != 0, raster mismatch) leaves the
console on the inherited geometry and scroll, which is a correct outcome.

### Changed — `MDO_OP_PAN` now arms the latch (site 12)

It did not before, on the argument that it writes only the surface-address group — the same live write
that page-flips DOOM every frame — so it cannot hang or blank the pipe, and a reboot undoes it. All of
that remains true, and it stopped being sufficient when the pan began running at boot: a pan that leaves
the console unreadable would repeat every boot. Site 12 is distinct from native's 11 so the latch record
names which was in flight. `/bin/modeset --pan` gains exit **98** (latch would not arm).

`modeset-latch-smoke` gains two more guards — a no-GPU boot must not arm at site 12 and must not claim
`gpu: boot console PANS in hardware`. 32 passed, 0 failed.

`main.cyr` calls `mdo_native()` after `gpu_pixclk_discover()`, then `klug_replay_fb()` and logs
`gpu: boot console is NATIVE -- 2560x1440 scanout, scaler bypassed`. It must sit after
`gpu_pixclk_discover` because `mdo_native` refuses unless the target equals the link's active raster, and
`gpu_h_active` / `gpu_v_active` are not derived until then.

Not gated on success: a refusal (no GPU, latch armed, pipe != 0, raster mismatch) leaves the console on
the inherited geometry, which is a correct outcome. The replay runs only when the geometry changed.

### Fixed — the modeset latch is released at clean shutdown, not by the operator

New `modeset_disarm_on_shutdown()` (`kernel/core/modeset_latch.cyr`), called from `power_sys()` before
`power_quiesce_devices()` — so it covers `reboot`, `poweroff` and `halt` alike, and runs while the block
device is still live. Once per boot, silent when nothing is armed.

⛔ Deliberately **not** disarmed on modeset success: the OTG frame counter free-runs off the PLL and reads
healthy on a black panel, so that would auto-clear the exact failure the latch exists to catch. Reaching
`power_sys` means the operator drove the machine to a deliberate stop — the display worked well enough to
use it. A blanked panel makes that unreachable; they hold the power button, the latch survives, and the
next boot refuses the modeset.

**Breaking (operator-visible):** the boot-time stale-latch message no longer reads
`recover by typing: rm /.modeset-armed`. It now reads
`last session did not end cleanly -- modeset SKIPPED this boot` plus
`this boot runs the inherited mode; a clean shutdown clears it`. The latch state means one thing — the
previous session did not end cleanly — and is no longer a file the operator is instructed to manage.
`rm /.modeset-armed` still works as an escape hatch; it is simply no longer the routine path.

`modeset-latch-smoke` gains two guards — a no-GPU boot must not arm the latch at site 11, and must not
claim `gpu: boot console is NATIVE` — and its recovery assertion now targets the new guidance line.
30 passed, 0 failed.

## [1.56.37] — 2026-08-03 — the initial scanout (RELEASED)

Scope: the boot console's first ~87 lines. agnos paints them at **boot_info's** geometry (2560x1440,
pitch 10240) while DCN is still scanning the firmware's **800x600 pitch-832** surface and upscaling it, so
2560-wide rows are read as 832-px rows and smear — the banding at the top of every boot photo. At ~line 88
the register aperture maps and `gpu_scanout_matchgeom` corrects the geometry, but it only *cleared*, so
those lines were erased rather than repaired.

### Fixed — the panel is held until the geometry is verified, so banded lines are never drawn

`fb_console_init()` calls `fb_defer_begin()`; `fb_putc` drops the draw while deferred. serial and klug are
unaffected, so nothing is lost — only the panel waits. `gpu_scanout_matchgeom()` calls `fb_defer_off()`
once the DCN read verifies the geometry, then clears and replays, so the panel's first content is already
correct.

`fb_defer_rescue()` is called unconditionally from `main.cyr` past every geometry decision: if painting is
still deferred, it accepts boot_info's geometry, paints, and logs
`fb: geometry unverified -- painting at boot_info geometry`. This is what covers QEMU / headless / gated-
pipe boots, where a permanent defer would blank the panel for the whole session.

`fb_defer` starts at 0, so a build that never calls `fb_defer_begin` behaves exactly as before.

### Fixed — the boot log's first ~87 lines are repainted, not discarded

New `klug_replay_fb()` (`kernel/core/klug.cyr`): repaint the captured ring to the **framebuffer only**.
Every early line is already in klug — it is fed from the earliest boot by a pure `store8` path that runs
before any console backend exists — so once the geometry is known the log is simply drawn again, correctly.
`gpu_scanout_matchgeom()` calls it immediately after its `fb_console_clear()`.

⛔ FB only, never serial and never back into the ring: `fb_print` reaches `fb_putc`, which does not tap
klug (only `kprint`/`kprintln` do), so the ring cannot grow by its own contents.

## [1.56.36] — 2026-08-03 — native-resolution scanout (RELEASED)

Scope: the desktop rendered at **800x600 into a 2560x1440 panel** — a small window in the upper-left
quadrant, not an upscale. This cycle made the scanout surface match the display link the kernel had
already trained. See [`planning/gpu.md`](planning/gpu.md) for the register-level plan.

**Iron-confirmed across four burns**: native 2560x1440 with the scaler in bypass; a console that scrolls
15x cheaper via a hardware pan; the exit path no longer destroying its own result code; and the pan not
contending with a full-screen compositor.

### Fixed — the console pan stole the scanout from full-screen apps

`gpu_pan_commit()` now returns early when `gpu_scanout_pid >= 0`. `fb_scroll_up` calls it on every console
scroll, and the console keeps painting while a full-screen app owns the display — the app's own stdout and
the `read(fd=0)` line discipline's keystroke echo both land there. Before the pan that painting was
invisible; committing a surface address made each such scroll yank the scanout to the console for one
frame until the app's next present flipped it back.

Measured on iron 2026-08-03 with aethersafha: one flash during startup (the compositor's startup lines)
and one per key press (the echo).

`gpu_display_restore_console()` releases ownership (`gpu_scanout_pid = -1`) **before** calling
`gpu_pan_commit()`, or the new guard would make the restore a no-op. `mdo_pan` refuses to arm while
`gpu_scanout_pid >= 0` (new use of reason **30** `NOPAN`).

### Fixed — `exit(2)` returned to ring 3 and the spurious #PF overwrote the exit code

`kernel/core/syscall.cyr`, the `num == 0` handler. When the `kernel_resume` gate did not fire (any exit
where `proc_current_get() != exec_resume_pid_get()`), exit fell through to `return 0` — back into a
process already at state 0. `_entry`'s `syscall(SYS_EXIT, r)` is the last instruction a Cyrius program
emits, so control ran into the zero padding after `.text`, where `00 00` decodes as `add %al,(%rax)` with
`rax = 0`: a write to address 0, then `fault_kill_current`.

`proc_set_exit_code` had already stored the real value; `fault_kill_current` then overwrote it with
`128 + 14` = **142**. Tools reported 142 regardless of what they returned. Measured on iron 2026-08-03:
`/bin/modeset --native` and `--pan` both completed, printed every line and returned 95, and were both
recorded as `run: exit 142`, faulting at `rip=0x407e96` — the two padding bytes after their own `syscall`
(`.text` ends at `0x407e98`).

Exit now takes the same `while (1) { asm { sti; hlt; } }` tail `fault_kill_current` already uses for a
proc dying with no armed resume. The endpoint is unchanged — the old path reached that same loop via the
fault — so this removes the detour, not the mechanism.

### Fixed — `blit`(#39) fallback rendered at the firmware surface, not where the console paints

`bl_fb_direct` now comes from `fb_draw_base()` instead of `fb_fb_phys()`. With the console redirected or
the hardware pan armed, the no-double-buffer fallback would have rendered into a buffer nothing was
scanning. Identical to the old value when neither is active.

### Fixed — `PAN ARMED` printed a hardcoded reset interval

The line said "reset every 90 lines", the `fb_scale()`==1 answer. The 2026-08-03 iron run was at scale 2
(320 KB/line), where the interval is 45. Now derived from `fb_height() / (16 * fb_scale())`.

### Added — `MDO_OP_PAN` (#93 op `0x0C`): hardware-scrolled console

The console moves into an agnos-owned VRAM buffer `GPU_FB_PAN_HEIGHT_MUL` (2) times the screen height and
scrolls by moving the scanout start one text row, instead of copying the console region.

Measured cost per scrolled line at 2560×1440, pitch 10240: **14,400 KB of WC stores → 320 KB** (`cell_h ×
pitch`, iron-measured at `fb_scale` 2) plus one `DCSURF_PRIMARY_SURFACE_ADDRESS` write. One full-frame
reset copy per `slack / cell_h` = **45 scrolled lines** at scale 2 (90 at scale 1), giving an amortized
960 KB/line — a **15× reduction** (30× at scale 1). At the old 800×600 surface the
software scroll cost ~2.0 MB/line, which is why this was not needed before 1.56.36.

New VRAM region `GPU_FB_PAN_OFF` = `0x20000000` (512 MB into the carveout), bounded by `GPU_FB_PAN_LIMIT`
= `0x40000000`; a buffer that would not fit refuses and leaves the software scroll in place. Separate from
the A/B back buffers at `GPU_FB_BACK_OFF` so console panning and full-screen page-flips cannot contend for
the address register.

`fb_console.cyr`: `fb_pan_bytes` / `fb_pan_limit`, `fb_pan_arm()` / `fb_pan_disarm()` / `fb_pan_armed()` /
`fb_pan_bytes_get()`; `fb_draw_base()` now returns `fb_scanout_base + fb_pan_bytes`, so every existing
writer follows the pan without a call-site change. `gpu.cyr`: `gpu_pan_arm()`, `gpu_pan_commit(off)`.

`gpu_display_restore_console()` now restores to the pan target at the current offset when the pan is
armed, instead of `gpu_display_surf` — otherwise quitting a full-screen app left the console painting into
the pan buffer while the hardware scanned the firmware surface (an invisible console).

No latch: the op writes only the surface-address group — the same live write `gpu_blit_present` issues
every frame — so it cannot hang or blank the pipe, and all its state is in RAM.

New reason: **30** `NOPAN` (buffer would not fit below the back buffers). Reuses **28** `ALREADY` and
**29** `RASTER` (pipe is not native — run `--native` first).

`MDO_OP_SUPPORTED` **`0xE7F` → `0x1E7F`** (plain) and **`0xFFF` → `0x1FFF`** (`MODESET_AUDIO_ARMS`).
`modeset-tool-smoke` opmask expectations move **3711 → 7807** and **4095 → 8191**.

`/bin/modeset --pan` exit codes: **95** armed · **87** already armed · **84** pipe not native · **82**
buffer would not fit (console left on the software scroll) · **96** no GPU.

`MODESET_TOOL_SELFTEST` runs `--pan`; the smoke asserts it dispatches and that it arms nothing with no GPU
present. 28 passed, 0 failed.

### Added — `MDO_OP_NATIVE` (#93 op `0x0B`): retarget the pipe to the full-size surface

Runtime modeset op behind the `/.modeset-armed` latch (`modeset_arm` site **11**). Reads the target
geometry from the boot_info handoff, reconciles the live HUBP surface address against `fb_phys`, then
runs one OTG envelope: `OTG_MASTER_EN=0` → `DSCL_MODE`→bypass, viewport, pitch, surface address →
`OTG_MASTER_EN=1`. Restores the saved HUBP group and re-enables if the pipe does not resume. On success
calls `fb_set_geom(w, h, pitch*4)` + `fb_console_clear()`.

Registers written, all BASE_IDX 2 (`GPU_BASE_DCN_2` = `0x34C0`), pipe 0 only:

| Offset | Register | From | To |
|---|---|---|---|
| `0x0CEC` | `DSCL0_SCL_MODE` `DSCL_MODE` [2:0] | 1 (`SCALING_444_RGB_ENABLE`) | **6** (`DSCL_BYPASS`) |
| `0x5EA` | `DCSURF_PRI_VIEWPORT_DIMENSION` W[15:0] H[31:16] | `0x02580320` (800x600) | `(h << 16) \| w` |
| `0x607` | `DCSURF_SURFACE_PITCH` [13:0] px | 832 | boot_info pitch / 4 |
| `0x60A`/`0x60B` | `DCSURF_PRIMARY_SURFACE_ADDRESS` / `_HIGH` | — | written back in the encoding the pipe already uses |

New constants: `GPU_R_DSCL_SCL_MODE` = `0x0CEC`, `GPU_DSCL_MODE_MASK` = `0x7`,
`GPU_DSCL_MODE_BYPASS` = `6` (`kernel/core/gpu_regs.cyr`).

New `MDO_E_*` reasons: **26** `NOTNATIVE` (boot_info has no usable full-size 32bpp surface) · **27**
`SURFADDR` (the live HUBP surface reconciles with neither `fb_phys` nor its MC form) · **28** `ALREADY`
(the viewport already reads the target) · **29** `RASTER` (the target is not the link's active raster).

`MDO_OP_SUPPORTED` **`0x67F` → `0xE7F`** (plain) and **`0x7FF` → `0xFFF`** (`MODESET_AUDIO_ARMS`) — bit
11 in both. `modeset-tool-smoke` opmask expectations move **1663 → 3711** and **2047 → 4095**.

`/bin/modeset --native` exit codes: **95** envelope survived (the panel, not this code, is the oracle) ·
**86** already native · **85** no usable boot_info surface · **84** target is not the raster · **83**
surface address did not reconcile · **89** disable did not stop the pipe (HUBP untouched) · **91** did
not resume, rollback ran · **96** no GPU · **98** latch would not arm.

`MODESET_TOOL_SELFTEST` runs `--native`; the smoke asserts it dispatches (reason 1 under QEMU) and that
it arms nothing and writes no `OTG_MASTER_EN` with no GPU present. 26 passed, 0 failed.

## [1.56.35] — 2026-08-03 — the desktop's kernel half (RELEASED)

Scope: what the sovereign desktop needs from the kernel to host real client windows. Opened the day
1.56.34 closed, because the desktop's remaining blocker turned out to be a kernel fault that
reproduces in QEMU — not, as assumed when the iron burn was scheduled, a hardware-only question.

Full rationale per item, and the substrate matrix that decides what each proof is worth, live in
aethersafha [`docs/development/planning/desktop.md`](https://github.com/MacCracken/aethersafha/blob/main/docs/development/planning/desktop.md).

### Fixed — the APs never enabled `EFER.NXE`, so every NX page was a reserved-bit `#PF` on an AP

`kernel/arch/x86_64/smp.cyr:514` — the AP trampoline set `EFER |= 0x100` (LME only). The BSP sets
`0x900` (LME | **NXE**) in `boot_shim.cyr:100`. `EFER.NXE` is what makes bit 63 of a paging-structure
entry mean *no-execute*; with it clear, **bit 63 is RESERVED**. `proc_map_page_nx` sets exactly that
(`0x8000000000000087`) on every W^X data page and every user stack, so the first touch of any NX page on
an AP raised a reserved-bit page fault. One line: `0x100` → `0x900`.

This was the `-smp 4` desktop blocker: `run /bin/aethersafha` (15.6 MB) fault-killed with `exit 142`
under 4 CPUs while passing under 1. It explains the whole symptom set — SMP-only (APs), large-image-only
(more NX pages, more chance of landing on an AP), a victim address that moved between runs (whichever NX
page the AP touched first), and why the **code** page never faulted (`proc_map_page`, no NX bit).

Verified in QEMU at `-smp 1/4/8/16` (8 and 16 match archaemenid's core and thread counts; agnos parks
APIC id >= 4 and reports `cpus online: 4` in all of them). ⭐ **Then verified on IRON 2026-08-03**:
archaemenid boots to `smp: cpus online: 4` and the desktop hosts **two real client windows** —
`present_probe` and `crab`'s dual-pane file manager, both composited on the panel, 278 frames, keys
delivered to the client, clean Esc quit. → [`docs/development/issues/2026-08-02-large-image-ptload-pde-absent-smp.md`](docs/development/issues/2026-08-02-large-image-ptload-pde-absent-smp.md)

⚠ The error code carried `RSVD` (bit 3) from the first capture on 2026-08-02. It was missed for a day
because `fmt_hex_buf` emits **zero characters** for a value with bit 63 set, so the fault recorder
printed `pde=0x` — read as "the PDE is zero" when it meant "the PDE has NX set and cannot be printed".
`epp_hex` and the fault recorder now split bit 63 and render `NX|<rest>`.

### Added — cross-CPU TLB shootdown (vector 0xF0)

agnos had **no** cross-CPU TLB invalidation at all: every `invlpg_va()` flushed only the executing CPU,
while address spaces are recycled by LIFO `pmm_alloc` and, without PCID, a CR3 value is the only TLB tag.
`apic.cyr` gains `tlb_shootdown_all()` (local CR3 reload → IPI all-but-self → bounded ack spin, so a
wedged CPU degrades to stale-TLB risk rather than hanging), `apic_send_ipi_allbutself()`,
`tlb_isr_build()` and `tlb_shootdown_handler()`; the vector is installed in `main.cyr`. Called from
`proc_free_address_space`, `proc_unmap_page` and `proc_unmap_2mb_hi`. Inert single-core (`cpu_count < 2`
short-circuits to a local flush). Verified running: `TLBSHOOT want=3 ack=3 cpus=4 apic=1`, and clean on
iron 2026-08-03 (no wedge on any process exit, which was the named burn risk).

⚠ It targets APIC ids `0..cpu_count-1` individually — **deliberately not the all-but-self shorthand**.
archaemenid is 8c/16t and `smp.cyr:398` parks every AP with id >= 4 in `hlt` *before* that AP programs
its LAPIC; a broadcast would reach those parked cores. Targeting is also ~50x cheaper in ack spins.

Found while investigating the fault above; it is **not** that bug, but a real latent hole under SMP.

### Added — `ELF_PDE_PROBE` kernel diagnostics (build flag, off by default)

Per-PDE write verification in `elf_load_from_file` (both the kernel PD and the PD[511]-stashed user
mirror), a live page-table registry consulted by `pmm_alloc` **and** `pmm_alloc_2mb`, whole-PD audits at
load and spawn, subject-controlled CR3-install and timer-tick watches, and hardware CR3/CR2 captured by
the `#PF` stub itself before any kernel code runs. `AE_CLIENTS_KLUG=1` makes
`aethersafha-clients-test.py` dump the klug ring on a **passing** run, so a probe can be validated
against a known-good boot before its output is trusted.

### Open — the cut's work, none of it landed yet

- **A large binary reaches ring 3 with one of its own PT_LOAD PDEs absent, under SMP only.**
  `run /bin/aethersafha` (15.6 MB) is fault-killed — `exit 142` (128 + vector 14) — after it binds its
  setu listener, at or just after the nested `spawn_path #43`. Reproduces at `-smp 4`, passes at
  `-smp 1`, same kernel and same binaries. Page is **absent** (error bit 0 = 0), proc is on its **own**
  address space (`cr3 == own`), and the victim slot **moves** between runs (`idx=3` image data,
  `idx=0x1fe` user stack). Probe: instrument the PT_LOAD mapping loop of `elf_load_from_file` — the
  **#43** path, not the in-memory `#3` path — reading each PDE back through `cr3 → PML4[0] → PDPT[0] → PD`
  immediately after `proc_map_page`. Tracked at
  [`issues/2026-08-02-large-image-ptload-pde-absent-smp.md`](docs/development/issues/2026-08-02-large-image-ptload-pde-absent-smp.md).
- **`spawn_path #43` never calls `exec_redirect_apply`** (`syscall.cyr:7618-7701`; `#37` does, at
  `:7166`), so concurrent desktop procs interleave on the console unserialised. This has already
  corrupted one verdict — `a11y nodes synced:run: exit 142` landed mid-line and the klug dump was
  skipped on a boot that carried the evidence. Arm per-CPU, one-shot, applied to the **child's private**
  fd table between `proc_set_ring3` and `proc_set_state(pid, 1)`.
- **Raise the ELF loader's user-image floor** `0x200000` → `0x400000` (`elf.cyr:253`, `:277`). Today a
  segment could override PD[1], where the boot TSS RSP0 seeds live (`gdt.cyr:45-48`). Measured: every
  binary in the tree already bases its first PT_LOAD at `0x400000`, so the change costs nothing and
  retires the class.
- **A terminal needs a controlling-channel primitive — an agnos PTY "of sorts".** `pty|ptmx|devpts|
  termios|TIOC` across `kernel/` returns **zero hits**, so a terminal emulator on the desktop has
  nothing to host. Not a POSIX PTY port: the shape is agnos-native and it converges with the local-IPC
  question below — a pty is a channel plus inheritance plus a line discipline, and agnos is missing the
  first two for a `spawn_path` child.
- **Local IPC / what an agnos socket is.** The sovereign display protocol currently runs its control
  channel over **TCP on loopback:7700**, which drags a DHCP dependency into a local display protocol, a
  `net_ip == 0` case unfixable from ring 3, and a `sock_connect #47` that holds preempt disabled for the
  whole attempt. Design call, not a patch. Any kernel half lands here. **Decided 2026-08-03: `anu`** —
  one syscall `#96 an_op`, VFS tag `VFS_ANU = 11`, kernel band `an_*`, ops `0x00`–`0x09` with `0x0A`
  `ND_HANDOFF` / `0x0B` `ND_DIAL` reserved and their caps bits clear. ⚠ `#96` is contested with `fork`
  (`docs/development/roadmap.md:41`); whichever lands first takes it and the other takes `#97`. Design,
  migration and kill criteria: [`planning/ipc.md`](docs/development/planning/ipc.md) §9.
- **`epoll_wait`'s zero-result path halts the CPU with interrupts off.** `syscall.cyr:6695` runs a bare
  `arch_wait()` — `hlt` with no `sti` (`arch/x86_64/io.cyr:143`) — inside an IF=0 syscall handler, on a
  path taken regardless of watch type, so an `epoll_wait` on an unexpired timerfd or an unsignalled
  signalfd hangs the box. Fix is to delete the call and fall through to `return found;`.
- **`net_config #61`**: surface `lo_dropped` (`net.cyr:22`, incremented at `:210`) and `lo_count`.
  `lo_dropped` is currently incremented and **never printed anywhere**, while a lo-ring drop costs a
  full 1 s TCP RTO.
- **A ring-3 socket read has no non-blocking form, and every setu client polls one every frame.** A
  tagged socket fd's `sys_read` routes to the cyrius stdlib's `_agnos_sock_recv_block`, which polls
  `sock_recv #49` under a **30 s wall-clock deadline** and a 6000-spin backstop, returning 0 for both
  EOF **and** timeout. There is no way for ring 3 to ask "is there a byte waiting?" and get an
  immediate answer, so a client's per-frame input poll is a blocking call wearing a non-blocking name.
  ⚠ Measured state: the desktop runs at ~10 ms/frame in QEMU, so in practice data is pending on the
  polls that matter — this is a latent hazard, not an observed stall, and the fix wants a measurement
  before a design. Kernel-side options: a `sock_pending`-style query, or a documented non-blocking
  recv the stdlib can expose without the deadline wrapper.

## [1.56.34] — 2026-07-31 — HDMI audio: CRC null-case calibration

### Added — `net_src_for`: an outbound segment's source is derived from its destination

`net_src_for` (`kernel/core/net.cyr:203-206`) picks the source address for an outbound segment from the
destination it is headed to, instead of stamping `net_ip` on everything. A loopback SYN therefore goes
out `src = dst = 127.0.0.1`, its SYN-ACK comes back on a 4-tuple the client's own conn matches, and
`tcp_find_conn` finds it.

Before this, a ring-3 client dialling `127.0.0.1` got `sock_connect #47` returning **-1 instantly** with
its own conn slot zeroed — not a handshake timeout, which is what made it read as a client bug for so
long. It is what setu 0.7.2 worked around from userland by dialling `sys_net_ip()`; with `net_src_for`
that workaround is unnecessary and setu 0.7.3 reverts it.

⚠ Recorded retroactively at the 1.56.34 close: the function landed during this cycle (2026-08-02) but
was never written up, so consumers had no version to name and setu's client comments cited 1.56.34 and
1.56.35 inconsistently. **`>= 1.56.34` is the correct requirement.**

⚠ Unchanged and still a kernel-side gap: `net_ip == 0` (no NIC ⇒ no DHCP) remains unfixable from ring 3,
because a reply's destination would be 0, which `net_is_loopback` explicitly excludes.

### Fixed — ⛔ A COMPLETED FOREGROUND `run` LEFT THE CPU'S SYSCALL STACK AT AN ADDRESS LARGE PROGRAMS OVERWRITE

`syscall_kstack_reserve` deliberately places each CPU's SYSCALL kernel stack at its **direct-map** VA
(`DIRECTMAP_BASE + 0xF10000 + cpu*0x10000`), because region 7's identity VA (14-16 MB) lies **inside** the
user-segment range — `elf_load` maps PT_LOADs up to 256 MB, and `proc_map_page` overrides the per-proc PD
entries it covers. That is the same class as the "ark won't run" bug fixed for `TSS.RSP0` at 1.51.x.

The `execwait #37` handler's step (h) restored it to the **raw** `0xF10000 + cpu*0x10000` instead. Step (f),
three lines above, copies from `pcpu_syscall_kstack_top2` — which *is* direct-mapped — so the two halves of
the same swap disagreed, and only the restore was wrong.

Effect: a fresh boot is safe, and **every completed foreground `run` re-armed the fault for the rest of the
boot**. Any process whose image reaches past `0xF10000` (15.06 MB) then took its next SYSCALL with `RSP`
pointing into a page its own segments had overwritten → `#PF` at CPL0 → `#DF` → triple fault.
`/bin/aethersafha` (14.87 MB, loaded at ≥ 2 MB) is the first binary in this system large enough to be in
range, which is why nothing else ever tripped it.

⭐ **Demonstrated with a control, not argued.** New `AE_CLIENTS_MODE=armed` in
`scripts/harness/aethersafha-clients-test.py` runs a small foreground program to completion **first**, then
launches the compositor — the sequence every prior mode skipped by launching it as the boot's first command.
On the unfixed kernel that sequence **kills the machine** (serial stops at the command echo, QEMU monitor
gone); on the fixed kernel it reaches **2 clients connected and presented**. Plain `bg` mode passes on both,
which is exactly why this hid.

⚠ Very likely the `run: exit 142` that caused agnoshi 1.8.6 to revert foreground `spawn_path` routing — the
mechanism and symptom class match — but **not yet re-confirmed on iron**.

Verification: `check.sh` 23/23 · `sweep.sh` 15/15 (incl. exec-from-disk, FP ring-3, two-proc FP context
switch) · foreground `aethersafha` in QEMU reaches `exit 95`.

### Added — HDMI audio (the open bite)
- Added `MDO_OP_CRCCAL` (`#93` op `0x0A`) + `/bin/modeset --crccal`: three-phase CRC null control in one boot — feed
  STOPPED → RUNNING → STOPPED again, both taps each phase, feed restored as found. Needs no ear; source-side and
  self-controlled.
- Added `hda_hdmi_feed_running()` — reads SD_CTL's RUN bit (the hardware, not the `hda_stream_on` bookkeeping flag).
- `MDO_OP_SUPPORTED` 639 → 1663 (un-armed) and 1023 → 2047 (armed); `modeset-tool-smoke` mask assertions updated to
  match.
- Fixed: `--pixclk` (shipped 1.56.33) was never in the selftest list and never gated in the smoke. Both `--pixclk`
  and `--crccal` now run in the selftest and are gated, mutation-checked.
- Fixed `modeset_disarm()`: it deleted the latch file, printed `verified good, latch cleared`, and left arming dead
  for the rest of the boot two ways — the boot-lifetime `blocked` flag was never cleared, and the latch inode was
  zeroed without being re-created. Both fixed; the QEMU disarm lane now asserts arming works after the `rm`,
  mutation-tested to fail without the fix.
- Flash gate: `build/agnos` **1,985,728 B**; `/bin/modeset` **41,800 B** (md5 prefix `c16a0f3b…`; 41,720 B was the
  stale size the gate now catches). Build-size discriminators: bare kernel **1,926,416 B** vs `HDMI_ATOM=1`
  **1,965,624 B** (+39 KB); three-flag build **1,969,096 B**; `+HDA_TONE` **1,984,072 B**; bare 1,927,144 B carries
  no marker.
- Required flag set for any HDMI-audio burn, enforced by a per-arm assertion (`CRCCAL_REQUIRE="HDA_HDMI HDMI_ATOM
  HDA_TONE GPU_AUDIO_PROBE"` checked against `BUILD_ENV`): **HDA_HDMI** (2nd HDA controller probe) + **HDMI_ATOM**
  (the `gpu_hdmi_audio_enable` call site) + **GPU_AUDIO_PROBE** (the only thing that sets `gpu_audio_dig`) +
  **HDA_TONE** (fills the PCM ring). A string check cannot discriminate a bare kernel from an `HDMI_ATOM` one — only
  the size can.
- Blinded ear protocol: `--audio-pre` sweeps 300→600 Hz, `--audio-post` sweeps 1000→1400 Hz — non-overlapping, ~1.5
  octaves apart. The operator reports WHICH band, never yes/no.
- ⛔ RETRACTED — "sequencing eliminated by M9". Both M9 arms streamed digital silence (no HDA_TONE, no ring-3 feed),
  so M9 was a null experiment. Sequencing is REOPENED.
- ⛔ RETRACTED — "`AFMT_STATUS` bit24 is SET on agnos, CLEAR on amdgpu". agnos reads `0x40000010` in all eleven iron
  captures, byte-identical to amdgpu-while-playing.
- Retracted: bare `modeset --x` and `run /bin/modeset --x` are iron-proven identical (both forms in one boot,
  byte-identical output, same exit 95).
- Standing finding: the sink rejects agnos's HDMI signalling, not merely its audio. Surviving candidates: (b) a
  write that does not latch · (c) the bare-metal environment. Arc PARKED by operator decision 2026-07-31.
- ⚠ Every `gpu_audio_probe`-dependent burn from 1.56.25 onward was built without HDA_HDMI and is void as audio
  evidence (grep `hda: found`: 2 hits in 07-18 captures, 1 in every capture from 07-24 on).

## [1.56.33] — 2026-07-30 — MODESET: the COLD case; ATOM `#12` programs the DTO, not a PLL
- Added `MDO_OP_PIXCLK` (`#93` op `0x09`) + `/bin/modeset --pixclk`: measures `pixclk_100hz` 2415014–2415020 on crtc
  0, then REFUSES with `MDO_E_NOPLL` — refusal IS the pass (`#93 pixclk idx=0 reason=24`, exit 95).
- ⭐ MEASURED: ATOM `#12 SetPixelClock` programs the **DTO**, not a PLL. With a complete iron seed, `pll_id` 3-19 and
  255 all run clean with **byte-identical** writes (no discriminator exists) and `pll_id` 20 and 21 both STORM
  (eliminated on evidence). There was never an instance to derive. `gpu_pll_discover` renamed
  `gpu_pixclk_source_check`.
- The three `#12` writes, identical across eighteen `pll_id` values: `0x0140 <- 0x00000000` (OTG_PIXEL_RATE_CNTL,
  clear DP_DTO_ENABLE) · `0x0141 <- 0x0E650730` (DP_DTO_PHASE = 241,502,000 = the pixel clock in Hz) · `0x0140 <-
  0x00000010` (SET DP_DTO_ENABLE). Write 2 tracks the target: 241.502 / 148.5 / 270.0 MHz → `0x0E650730` /
  `0x08D9EE20` / `0x1017DF80`. Live `DP_DTO_MODULO` = 598,875,000 = DPREFCLK; DPREFCLK × PHASE/MODULO reproduces the
  target exactly.
- Register identity corrected: BASE_IDX 1 `+0x80` = `GPU_R_OTG_PIXEL_RATE_CNTL` (bit 4 DP_DTO_ENABLE), `+0x81` =
  `GPU_R_DP_DTO_PHASE`, `+0x82` = `GPU_R_DP_DTO_MODULO`. ⚠ `0x0140`/ `0x0141`/`0x0142` are valid ONLY on BASE_IDX 1;
  on BASE_IDX 2 they are negative offsets.
- `pll_id` parameter map (seeded dry-run): 0-2 = 9 opcodes, bails · 3-19 = 55 opcodes / 5 reads / 3 writes (benign
  DCCG) · 20 = 509,839 opcodes / 78,432 reads / 98 writes (0x5DF1-0x5E12) · 21 = 354,983 / 177,422 / 3 · 22 =
  350,563 / 175,201 / 40 (0x5FA1-0x5FC2) · 23 = 187,313 / 93,584 / 40 (0x6079-0x609A) · 24 = 175,657 / 87,756 / 40
  (0x6151-0x6172) · 25-254 bail · 255 = 49 opcodes. Blocks 20-24 sit on a 0xD8 per-instance PHY/RDPCS stride — there
  `pll_id` names a TRANSMITTER instance and `#12` calls ATOM table 77. `atom_run_set_pixel_clock` now refuses 20-24
  by name.
- ⛔ SETTLED by operator decision: `#12` is NOT to be fired at the live pipe — it sets DP_DTO_ENABLE, which on a
  DTO-off pipe MOVES the clock source. A cold path needs a different target; pipe 1 is dark (`OTG1_CONTROL` abs
  `0x5081` = `0x80000300` vs pipe 0's `0x80011301`).
- ⛔ RETRACTED: "`#12`'s blast radius is DISJOINT from `#76`'s" — false for `pll_id` 20-24, where `#12` writes 22 PHY
  registers to `#76`'s one.
- ⛔ APERTURE POISON: reading register `0x5FA5` (instance 2, offset +05) returns `0xFFFFFFFF` and every read after it
  for the rest of the boot also returns `0xFFFFFFFF`. Reachability must be established PER-REGISTER on iron; a
  dry-run read set does not establish it.
- Added the raster program (`mode_raster.cyr`): 10 registers COMPUTED from published CVT-RB timing, bit-identical to
  the firmware's, **+ 4 CARRIED verbatim** (the DML watermarks no mode description can yield). The modeset
  watchdog's restore widened 6/20 → 20/20 registers.
- Dump-header tag fixed: `(offset value, both decimal; rd=+0x34C0 rd1=+0xC0 rda=absolute)`. The M12-pixclk group
  moved from `rd` (BASE_IDX-2-relative, 6 registers, read ZERO at dword 320) to `rda` (absolute, all 10 with correct
  DPREFCLK).
- `--pllblk` groups: narrow 9 registers (dump 120 total) · safe 49 (160) · wide 95 (206 — this is the dump that
  poisoned the aperture).
- Builds: 1,917,616 B → 1,920,992 B → 1,921,904 B; `ATOM_RUN_PIXCLK=1` 1,960,464 B then 1,961,864 B. `check.sh`
  23/23; `modeset-tool-smoke` 20/0; `host-gpu-oracles` 13/13.
- Known: `modeset-tool-smoke` intermittently WEDGES — pre-existing, A/B-proven not this change (3 of 6 failures each
  side); raising `QEMU_TIMEOUT` 40 → 70 does not fix it.

## [1.56.32] — 2026-07-30 — Rung 19 mine-cart: the 3D consumer closes, and finds a kernel arena race
- ⭐ RUNG 19 CLOSED ON IRON 2026-07-30: `mine-cart --verify` frame 120, 64 triangles in ONE op `0x0F` record at dstxy
  (80,96) — reference drew 250,536 px, GPU buffer untouched at 0 of 256,000, **DIFFER: 0 of 256000 px**. RIDE 600
  frames PRESENTED / 600 drawn / 0 dropped, run twice identical.
- `--check` host gate: 420 frames (240 ride + 120 at real screen offsets + 60 extremes), 19,162 triangles, 64 of 64
  per frame, peak |D| 260,066,240 of 2,147,483,647 permitted (8× margin). Burn 1's `--check`: 300 frames, 19,762
  triangles, 66 of 66, dropped coord 0 / w-band 0 / oversize 0 / degenerate 38 (cross exactly 0), peak |N|
  6,424,821,699,405,760 against a 2^62 bound, peak |D| 259,600,320, MUTATION gate caught a single fraction bit as
  `GPO_E_SUBPIXEL`.
- Two new gates added after burn 1: the frame is ONE op `0x0F` record (0 frames emitted a second list) — **op `0x0F`
  REPLACES its rect, so records cannot be layered**; and vertices are FRAMEBUFFER-ABSOLUTE (moving dstxy by (80,96)
  moves every vertex with it).
- ⛔ Fixed — the op-to-op PREP-ARENA RACE (real kernel bug): `gpo_execute_all` holds `gpu_batch_active` across the
  whole `#92` array and `gpu_blend_cov_run` early-returns without fencing when batched, so any op building a
  per-record prep table at ONE fixed arena slot has record N+1 overwrite record N's table before the GPU reads it.
  `gpu_tex_list` (0x0C) and `gpu_tri_list` (0x0A) already carried the suspend/restore fix; `gpu_tri_persp` (0x0F)
  and `gpu_tri_depth` (0x0E) did not, and were fixed together.
- ⚠ `#92` carries TWO incompatible `dstxy` conventions: op `0x0A` is RECT-LOCAL; ops `0x0E` and `0x0F` are
  FRAMEBUFFER-ABSOLUTE.
- Fixed — `/bin/gpumm` was two binaries under one rootfs name: tentib's **154,384 B** ternary crown won the copy
  over the **36,816 B** `#82`/`#83` seam. tentib's crown is now `/bin/gputern`, alongside `gpulayer` (rupantara) and
  `gpuattn` (attn11). ⚠ Any record from 1.54.x–1.56.31 saying `/bin/gpumm` for tentib means `/bin/gputern`.
- Frame path: `#86` carveout slots (2 vertex, 2 texture, 1 readback — 1.16 MB) → `#72` upload → one `#92` dispatch →
  `#84` present. No `#90`/`#73`/`#39`.
- Also corrected: the frustum was using half the available depth.

## [1.56.31] — 2026-07-29 — Rung 18: perspective-correct texturing (op `0x0F`), iron-closed exit 95
- Added `#92` op `0x0F GPU_OP_TRI_PERSP` + `kernel/shaders/tri_persp.s` (196 dwords). CLOSED on iron: byte-identical
  to the PERSPECTIVE reference at every covered pixel on a corpus whose two references provably differ at **731 of
  1541 covered px** — so the per-pixel divide demonstrably ran.
- Burn ladder: burn 1 exit 100 (banner, no comparison emitted) → burn 2 exit 86 (buffer touched 4096 of 4096 px; vs
  PERSPECTIVE 748 of 1541 differ, vs AFFINE 769 — differs from BOTH, so it is not falling back to affine) → burn 3
  exit 87 (vs PERSPECTIVE 0 of 1541, vs AFFINE 731, but the `covered nothing` guard fired) → closed exit 95.
- ⛔ `v_rcp_f32` REJECTED despite the plan prescribing it — using the hardware's own reciprocal in the reference
  would make the reference a MODEL OF THE HARDWARE. Replaced by an exact 56-iteration restoring divide.
- Fixed — two undersized buffers in `gputri.cyr` (burn 1, exit 100). Module-scope `var X[N]` is N × u64 = 8N bytes:
  `pp_tex` was `[16384]` = 131,072 B for a 262,144 B texture; `pp_got` was `[512]` = 4,096 B for a 16,384 B
  readback.
- Fixed — a 32-byte prep/shader skew (burn 2), and six defects in the rung-18 ABI and prep, one of them a divide by
  zero. `C_D` does not fit a 32-bit field and is stored as a residue on purpose.
- Added `perspmodel.cyr` / `perspcore.cyr` / `perspgate.cyr` / `perspdiv.cyr` / `perspbits.cyr` (host, zero burns)
  and `scripts/check/triper-contract.sh`. Powers of two are now enforced.

## [1.56.30] — 2026-07-28 — Rung 17: depth clear (op `0x0D`) + depth test (op `0x0E`), both iron-closed
- Added `#92` op `0x0D GPU_OP_DEPTH_CLEAR`, op `0x0E GPU_OP_TRI_DEPTH` (`tri_depth.s`, 116 dwords), op `0x10
  GPU_OP_RT_READ` (readback so the burn can FAIL), and rung 6 `arena-audit`.
- ⭐ DEPTH CLEAR — the TIME oracle caught two defects on a target ring 3 cannot read back. Failing burn (exit 94, 3
  of 4 predictions falsified): 800x600 (1.92 MB) ×20 = **491,461 µs**; 4096x2048 (32 MB) ×20 = **17,465 µs** — bytes
  ratio **17×** against a time ratio of 0.0–1.0×, so the worker was a no-op even though both clears returned 0.
  Validated burn (exit 95): 800x600 ×20 = **2,602 µs**; 4096x2048 ×20 = **16,958 µs** — bytes ratio 17×, time ratio
  **6.5×**, cost scales with size. An intermediate run read 1,788,344 µs / 4,437,491 µs at ratio 2.4× because the
  instrument was timing its own rung-6 audit (`gpu_rt_arm` → 64 KB `klug_spill` to ext2/NVMe inside the first timed
  loop, ~490 ms amortised over 20 iterations); fixed by a throwaway 64×64 clear before any timer starts.
- Clear arc totals: burn 1 (per-row + contaminated) 1,788,344 µs → burn 2 (linear + contaminated) 491,461 µs → burn
  3 (linear + warm) **2,602 µs = 687×**. 32 MB ×20: 221,875 → 848 µs per clear = **262×**. Root cause:
  `gpu_cp_dma_fill_rect` issued ONE CP-DMA packet per row, each with its own fence wait (600 packets for 800×600;
  2048 for 32 MB) and every row ADJACENT; CP-DMA BYTE_COUNT is 26 bits (~64 MiB) so the whole 32 MB handle fits in
  ONE packet. Per-row cost confirmed to 0.1%: 64,894 µs / 600 rows = 108.2 µs/row; 221,875 µs / 2048 rows = 108.3
  µs/row.
- Final clear cost model: FIXED **86.5 µs/dispatch** + **22.7 ps/byte** → 44.1 GB/s marginal; fixed share 67% at
  1.92 MB, 10% at 32 MB. ⚠ The previously published "89 ms per clear, ~21 MB/s" was CONTAMINATED; the true per-clear
  cost was 64.9 ms (~30 MB/s).
- ⭐ DEPTH TEST — the failing burn is the important one (exit 91): witness 0 poison / 0 mislabelled / 0 stray word-1
  writes; colour buffer touched at 1024 of 1024 px; **both submission orders — colour differs at 0 px, z differs at
  0 px** — perfectly order-independent and deterministic — yet vs the CPU reference **colour 1024 px differ, z 1024
  px differ**. A wave-uniform kernarg misread is deterministic, so no order/determinism test can see one. CLOSED
  exit 95: both orders byte-identical in colour AND depth, both match the CPU reference at 0 px differ, all 1024
  lane witnesses self-consistent. The depth test runs on gfx90c deterministically with no atomics and no binning.
- Arena/RT audit numbers: `MC_VM_FB_OFFSET` raw f70 ⇒ carveout phys base `0xF70000000`; arena phys `0xFF0000000` mc
  `0xF480000000` size `0x200000`; highest published slot `0xC0000`, sacrificial slot `0x1F0000`; RT region offset
  `0xB0000000` size `0x10000000` ends `0xC0000000`; rt phys `0x1020000000` mc `0xF4B0000000`; live scanout mc
  `0xF400000000`; region ends at `0x1030000000` = exactly the `top=1030000000` the boot path reports from an
  independent source. RT AUDIT PASS.
- ⛔ Fixed — `gpuwedge --audit` claimed "READ-ONLY, writes nothing" and then fired an unguarded write. Renamed
  `--slot-audit`.

## [1.56.29] — 2026-07-28 — Rung 15: integer bilinear, and a half-texel offset a GREEN result hid
- Added `GPU_TEX_FLAG_BILINEAR = 0x10` + `kernel/shaders/tex_bilin.s` (580 → **584 dwords**, no new VGPR, RSRC1
  unchanged), plus `bicore` / `bigate` / `bimodel` and `scripts/check/texbi-body-identity.sh` (a four-stage drift
  gate).
- ⭐ FIRST BURN WAS GREEN AND WRONG: BILINEAR 5 of 5 EXACT vs `bicore` with 751 px separating it from nearest — but
  frame 0 (1:1 identity) reported `vs NEAREST: 35 px differ`, falsifying the pre-registered prediction of 0. The
  taps were `floor(u)`; they must be `floor(u-0.5)`. `biprobe.cyr` census over the 8×8 block: fraction `fx==0`: 0,
  `fx==128`: 64 as shipped; with the −0.5 texel bias, 0 of 64 differ.
- Proof with no reference to GL or D3D: for texel i's centre at i + c, ANY c, correct nearest = `floor(u − c + 0.5)`
  and correct linear taps = `floor(u − c)` — they differ by exactly 0.5 for every c. AGNOS shipped floor/floor, a
  difference of zero, so "a different but self-consistent convention" was never available.
- Fix: `v_add_u32 v23, 0xFFFF8000, v23` per axis; `BI_HALF` in `bicore.cyr`; matching bias in `texcore.cyr`
  `tex_fetch_bilin` and `bimodel.cyr` `bm_sample`. Validated burn: BILINEAR 5 of 5 EXACT, **680 px** separate it
  from nearest, frame 0 `vs NEAREST: 0` (was 35).
- ⛔ REJECTED — folding the bias into `gpu_tex_prep`'s `mu`/`mv`: `gpu.cyr` derives `limu = (tw * 65536 - mu) * a2`
  FROM `mu`, so biasing `mu` shifts the out-of-domain predicate by half a texel, and `mu` is shared with op `0x0C`.
- Scoped: ONE blob, op `0x0B` only.

## [1.56.28] — 2026-07-28 — `gpu_tex_prep`: 40 uncached stores → 20 (`store64` pairs)
- ⭐ MEASURED (iron): `build` slope **2.487 µs/prim** against a predicted 2.50 (band 2.1–2.9). Slope ladder across
  the three cuts: **7.29 → 4.21 → 2.487 µs/prim**. 640-column DOOM frame CPU predicted ~1.62 ms, measured **1.61
  ms**. Total `#92` at n=256: **3248 → 1421 µs = 2.29×**.
- Seven pairs were already one 64-bit quantity split lo/hi (`cov_mc`, `a2`, `k0b`, `k0c`, `tex_mc`, `lut_mc`,
  `limu`, `limv`) — same bytes, half the UC transactions.
- Refitted model: **85.6 ns per uncached store + 0.79 µs of genuine per-primitive arithmetic** (fitted across 76
  stores/7.29 µs and 40 stores/4.21 µs). ⚠ Two points only.
- ⛔ THE PRE-REGISTERED CONTROL FAILED, logged as a failure: `wait` was required to hold ~5.1 µs/prim (a CPU-only
  change) and moved to 2.487 (−51%). A global GPU speed-up is ruled out by an independent instrument — `gputex`'s
  pure-GPU bench is unchanged (32×32 52.0 → 50.0 µs/dispatch −4%; 256×256 158.0 → 158.2 µs, 0%). The drop
  concentrates at high n (wait@32 193→205 µs +6%; wait@256 1329→762 µs −43%). Most likely CPU-side memory-controller
  backlog bleeding into the drain window: the control was badly designed, not violated.
- ⚠ UNEXPLAINED, not papered over: at 1.56.28 the `build` and `wait` deltas from n=32 to n=256 are exactly equal,
  both **557 µs** (they were 1633/1151 at 1.56.26 and 943/1136 at 1.56.27, so this is not a structural identity).
  Needs a third primitive count. Do not build on it.
- Corroboration, two tools two code paths: `gputex`'s op `0x0C` window (32 primitives) 216 → 160 µs = 56 µs over 32
  = **1.75 µs/prim** against a build-slope delta of 1.72 µs/prim.
- ⛔ REMOVED FROM THE PLAN — "cached scratch + bulk copy" does not work: `memcpy` (`klib/kstring.cyr:35`) copies its
  aligned bulk with `store64`, so it would produce exactly the same 20 UC transactions plus an extra pass.
- ⇒ `gpu_tex_prep` is DONE: 2.487 µs/prim against a 0.79 µs arithmetic floor. The remaining 20 UC stores need
  128-bit stores, barred by the FP-free kernel posture.
- Fixed: `gputri`/`gpuwedge` no-arg exit was 96 — the same code as "shader not resident". Now exit 83.
- Added `tests/gpu/packcheck.cyr`, a host oracle for the one way this can be wrong.

## [1.56.27] — 2026-07-28 — `gpu_tex_prep`: stop zero-filling 40 uncached words to preserve 4
- MEASURED: `build` slope **4.21 µs/prim** against a pre-registered ~3.84 (band 3.4–4.3). CONFIRMED. 640-column DOOM
  frame CPU **4.71 → 2.71 ms**. The pre-registered CONTROL HELD: `wait` 5.14 → 5.07 µs/prim (+1%).
- The 36 explicit stores cover words 0..35 contiguously with no gaps, so the zero-fill loop was writing 40 words to
  preserve 4. Narrowed to q = 36..40 (the Q9 extension point, which still needs zeroing because the prep table is
  ONE fixed 512-record region reused across calls).

## [1.56.26] — 2026-07-28 — Decompose `F`: the fixed term is PER-PRIMITIVE, 7.353 µs each
- ⭐ MEASURED (iron, `gpuprof`, exit 95). LO n=32: copyin 0 / validate 2 / build 248 / wait 200 / cpu 250 µs, grid
  32x32, **1024 waves** (predicted 1024). HI n=256: validate 16 / build 1881 / wait 1351 / cpu 1897 µs, grid 256x32,
  **8192 waves** (predicted 8192). CPU(hi)/CPU(lo) = **7.5×** against 8.0× if per-primitive and 1.0× if per-dispatch
  ⇒ **PER-PRIMITIVE, 7.353 µs each**.
- Slopes: `validate` **0.0625 µs/prim** · `build` **7.29 µs/prim** (intercept 14.7) · `wait` **5.14 µs/prim**
  (intercept 35.6). BUILD is 117× the validate slope — optimising validation buys ~0.9%.
- ⇒ A 640-column DOOM frame carries **4.71 ms of CPU** — 16.5% of a 28.6 ms budget — and NO transpose removes any of
  it. Frame totals: row-major 4.71 CPU + 4.60 GPU = 9.31 ms; col-major 4.71 + 0.09 = 4.80 ms. Col-major demoted from
  50× to ~1.9× at the frame level. **The GPU is not the bottleneck — the CPU prep is, by 52×.**
- Root cause of `gpu_tex_prep`: not arithmetic but WHERE it writes. `rec_phys` is in the UC-mapped GPU arena; an
  uncached 32-bit store goes to DRAM and waits. 40 zero-fill + 36 explicit = 76 UC stores per primitive; 7.29 µs ÷
  76 = **96 ns per store**.
- Added per-phase `#92` profiling with an OBSERVED grid. Fixed: the self-drain was billed to `BUILD`, which would
  have made the measurement meaningless.

## [1.56.25] — 2026-07-28 — Boot hygiene: dead code, one burn trap, one refuted register story
- Removed three functions with zero call sites and the `EDGE_CAP_PROBE` burn trap.
- `gpu_audio_probe` is now `#ifdef GPU_AUDIO_PROBE`. ⚠ It is the only thing that sets `gpu_audio_dig`; without the
  flag `gpu_audio_dig` stays −1 and the HDMI path refuses silently.
- Fixed the refuted `0x607` story before MODESET writes DCN again.

## [1.56.24] — 2026-07-28 — Truth-up: four correctness defects a full GPU review found (zero burns)
- Fixed: op `0x09` accepted two things its own worker refuses.
- Fixed: `gpu_fence`'s ring append could write past the ring — `gpu_ring_put` appended at `gpu_arena_phys +
  (gpu_ring_wptr << 2)` with a monotonic UNMASKED cursor; the PQ is 64 KB (QUEUE_SIZE 0xD = 16384 dwords), so a
  repeated producer walks off the end and scribbles the rptr-report/EOP slots that follow the ring in the arena.
- Fixed: the ATOM FB-scratch guard was off by one dword.
- Added `proc_copy_to_user`; `#82`/`#83` now write back through it.
- `#89 gpu_caps` gains a length-gated 64-byte tail; callers passing 32 are bit-identical to before.
- Removed a hardware-purchase proposal that should never have been written down.

## [1.56.23] — 2026-07-27 — Rung 14b: `GPU_TEX_FLAG_COLMAJOR`, and the cost model is INVERTED
- ⭐ RUNG 14 (op `0x0C GPU_OP_TEX_LIST`) CLOSED ON IRON, burn 2, exit 95: `texl` RGBA8 / IDX8 / ragged / seam all
  byte-IDENTICAL to 32 individual op `0x0B` dispatches, and CM == RM. Rung 13 unregressed 17/17 (5 RGBA8 · 5 IDX8 ·
  5 FULLCOV · 2 WRAP).
- MEASURED (rung 14, 1.56.23): 32 × op `0x0B` = **706–858 µs** vs 1 × op `0x0C` = **136–312 µs** ⇒ speedup
  **2.7×–5.1×**. Wave counts: row-major **1504–1536 waves** vs col-major **64 waves** (**23–24× fewer**); 1 × `0x0C`
  col-major = 108–272 µs vs row-major, 1.0×–1.4×.
- ⛔ THE COST MODEL IS INVERTED, and rung 14's own conclusion is RETRACTED. Three-parameter fit `cost = F +
  a·launched + b·working` gives **a = −5 ns per launched wave (statistically zero)**, **b = 36 ns per working
  wave**, **F = 264 µs fixed**. A launched-but-exiting wave is FREE. Per-pair ns/working-wave is one number (27–35
  ns) across every pair; ns/launched splits in two (~17 ns ragged vs ~27–35 uniform, because ragged launches 1504
  waves of which only **940** work).
- ⛔ RETRACTED — "177 ns/launched wave", and with it "row-major cannot draw a DOOM frame — 128,000 waves = 24.5 ms of
  a 28.6 ms budget". That was a two-point fit with no constant term and two free parameters: zero degrees of
  freedom, so F had nowhere to go but the launched coefficient (1536 × 177 ns ≈ 272 µs ≈ F). At the measured 36
  ns/working wave a DOOM frame is **4.6 ms** and fits. Col-major is 2,560 waves ≈ 0.09 ms — a 50× GPU reduction,
  kept because it is 50× cheaper, not because the alternative is impossible.
- Burn 1 exit 89: the SOLO list-B call was REJECTED, so the two-op seam case — the only case exercising op `0x0C`
  with the batch OPEN across two dispatches, i.e. the shape a DOOM frame has — could not run. Closed in burn 2 with
  `texl seam IDENTICAL batched and alone`.
- ⛔ THE UNITS TRAP, third occurrence, second time on iron: `gputri.cyr`'s `var sizes[8]` held six u64s at offsets
  0..40 — a **40-byte overrun** across saved registers and the return address, printing every number correctly and
  returning **exit 142**. Also `var o1[16]` passed to `tl_op0c()` which writes SIXTEEN DWORDS = 64 bytes = a 48-byte
  smash, twice, plus `var q[32]` for a two-op 128-byte array = a 96-byte smash.
- `check-array-sizing.sh` was GREEN on that bug (it only sees stores written directly to the named array). Extended
  with a second rule — `f(&buf, LEN)` with a literal LEN must fit — plus two precision fixes: skip `store*`/`load*`
  call sites (where the "LEN" is a byte VALUE), and scope to the declaration's enclosing block.
- ⛔ The plan's "walls as textured quads" premise is REFUTED by measurement; batch by DISPATCH, not by GEOMETRY. ⭐ A
  DOOM wall column IS an op `0x0B` quad bit for bit, proven on the host.
- The staged tool copy was 90 minutes stale: **213,672 B against the fresh 255,424 B**. `burn-prep` had been broken
  by the 1.56.22 `scripts/` split. Bare kernel 1,840,760 B stamped.

## [1.56.22] — 2026-07-27 — `GPU_TEX_FLAG_FULLCOV` + WRAP addressing, both correct on iron
- ⭐ FULLCOV MEASURED: shaped 32x32 = **56.3 µs** / 256x256 = **159.1 µs**; FULLCOV 32x32 = **27.0 µs** / 256x256 =
  **62.6 µs** ⇒ saving **29 µs (52%)** at 32x32 and 96.5 µs (61%) at 256x256; budget **521 → 1057 dispatches/frame**
  at 35 Hz, byte-identical on all 5 frames. FULLCOV cuts the per-pixel SLOPE by 65% (1.59 → 0.55 ns/px), not merely
  the intercept. The coverage pair is the expensive half and its share GROWS with rect size.
- Two-point texture fit: 32×32 = 54.4 µs, 256×256 = 160.2 µs ⇒ fixed **52.7 µs/dispatch**, slope **1.64 ns/px**,
  ≥3680 MB/s. Later consistent run: fixed ~53 µs, slope 1.58 ns/px, 1022 dispatches/frame at 35 Hz. ⇒ Rung 14 is
  DISPATCH-bound, not bandwidth-bound: 542 submissions per 35 Hz frame before a single pixel is shaded, against 17.4
  Mpx/frame of pixel headroom. ⚠ MB/s is a LOWER BOUND (texel traffic counted one dword per covered pixel).
- ⛔ The first bandwidth number — "200 dispatches of 32x32 in 11284 us → 56 us/dispatch, ≥163 MB/s" — was
  overhead-dominated and wrong to publish: a 32×32 rect is 1024 px and fixed dispatch overhead is ~28.8 µs, so 56 µs
  is almost entirely intercept. Replaced with the two-point fit.
- ⭐ WRAP CORRECT ON IRON: 2 of 2 exact, 17 cases green. `GPU_TEX_FLAG_WRAP` (bit 2) added with POWER-OF-TWO
  dimensions enforced as a REJECT (`GPO_E_TEXDIM`, code 26) — a general modulo is an integer divide per pixel; a
  power-of-two wrap is one AND. First red was edit placement: the WRAP branch sat AFTER `v_max_i32`/`v_min_i32` and
  AND-ed an already-clamped index (constant `0xff073815` = texel 7 = saturation). Rung 13 wrap defect on the way
  (exit 87): case 0 wrap-3x-tile 903 differing px, case 1 wrap-negative-UV 923 — the negative index was CLAMPED
  rather than AND-ed.
- ⭐ The deleted floor-divide came back on its own written expiry and had to earn it twice: restoring `tx_floordiv`
  was insufficient because arms W1–W4 call `tex_fetch` directly while `tx_floordiv` lives in `tex_uv_at`. New arm W5
  places u(0,0) at −1/16 ULP — floor and truncate diverge only for u ∈ (−1 ULP, 0), and in a DOOM wall column u is
  constant, so a column in that window renders ENTIRELY from the wrong texel.
- Changed: `scripts/` split into groups, `gpu-test/` → `tests/gpu/`, top-level test trees moved under `tests/`,
  `boot/grub` removed, `scripts/iso.sh` retired with its CI step.
- The sovereign encoder now agrees on every class `tex_rgba` uses — 65 of 65.

## [1.56.21] — 2026-07-27 — Rung 13 texturing CLOSED on iron; rung 12 batch defect CLOSED
- ⭐ RUNG 13 (op `0x0B TRI_TEX`, nearest-neighbour affine) CLOSED on burn 3: RGBA8 **5 of 5** and IDX8 **5 of 5**
  byte-identical to `texcore`. Case 0 (1:1 identity) is the ABSOLUTE test — the render is byte-identical to THE
  SOURCE TEXTURE, the only gate that can catch reference and shader being wrong together. Cases: 0 1:1-identity, 1
  non-integer-scale, 2 magnified-3tex, 3 skewed, 4 negative-UV.
- Burn 1: 3 of 4 exact each format, 26 px differ total (exit 85) — case 1 non-integer-scale, 13 px each format, a
  consistent one-LSB-per-channel offset (`@ x=6 y=0 cov=255 want=0xff043b0c got=0xff033c09`). The 96-bit comparisons
  read the wrong dword pair.
- Burn 2 REGRESSED to 0 of 10: the fix clobbered a live register — v19 held the stashed U index and the V axis's
  correction wrote `lo(q1·A2hi)` (0 whenever the frame area fits 32 bits) over it. Moved to v18 and converted two
  per-lane conditions from `s_cbranch_vccz`/`vccnz` to `v_cndmask` predicates.
- Rung 13 cost model (five burns, consistent): 32x32 = **49.8–56.3 µs/dispatch**, 256x256 = **157.1–162.5
  µs/dispatch** ⇒ FIXED overhead ~48–54 µs/dispatch, SLOPE ~1582–1677 ps/px (1.5–1.6 ns/px), ≥3629–3753 MB/s at
  256x256 (lower bound). Rung-14 budget @35 fps: 521–593 dispatches/frame before any pixels, or 17–18 Mpx/frame
  fused. FULLCOV path: 32x32 = 23.4–28.7 µs, 256x256 = 58.5–62.8 µs ⇒ 25–29 µs saved at 32x32 (46–53%), budget
  992–1218 dispatches/frame.
- ⭐ RUNG 12 CLOSED — batched triangles composite byte-exactly: gpu digest `0xfc6f8c42` == reference, 0 px differ,
  every prefix n=1..6 matches, probe P2 now EXACT, exit 95.
- ⭐ ROOT CAUSE: `gpu_tri_list` looped inside `gpo_execute_all`'s batch while reusing three fixed arena slots
  (`GPU_TRI_EDGE_SUBOFF`, `GPU_TRI_PREP_SUBOFF`, `GPU_TRI_COV_SUBOFF`), so all 3N dispatches queued first and EVERY
  dispatch read the LAST triangle's edges, prep record and coverage mask. Not a cache fault; not the fence sequence
  — the PM4 per dispatch (ACQUIRE_MEM(INV) → DISPATCH → CS_PARTIAL_FLUSH → ACQUIRE_MEM(TCWB) → fence) was correct
  throughout.
- The rung-12 bisect (10 burns): 6 overlapping triangles from ONE vertex slot, ONE record → gpu digest `0xda27e77a`
  vs reference `0x9697fa43`, 3186 px differ, worst delta 249; re-run under a moved corpus (`0x3433f179`) → 3188 px
  differ, worst delta 237, gpu digest still `0xda27e77a`, reference `0xfc6f8c42`. Singleton sweep: all 6 EXACT alone
  ⇒ the defect is in COMPOSITION. Prefix bisect: n=1 ref `0x7dfa3797` gpu `0x7dfa3797` differing **0** · n=2 ref
  `0xbbde4a03` gpu `0xa70d44e9` differing **1711** · n=3 ref `0x7aec2899` gpu `0xb2854731` **2884** · n=4 ref
  `0xa15be882` gpu `0xef01eb26` **3124** · n=5 ref `0x670b2364` gpu `0x4742417e` **2824** · n=6 ref `0xfc6f8c42` gpu
  `0xefd67dae` **3188** ⇒ first divergence at n=2, triangle 1, vertices (60,2) (60,60) (2,60). P1: six separate n=1
  calls with no refill = EXACT ⇒ the defect is inside `gpu_tri_list`'s loop. P3: a bare op `0x08` coverage dispatch
  after a rendered rect = EXACT ⇒ the coverage pass is innocent. P2: an n=2 whose second triangle covers nothing
  still lost 1711 px ⇒ blending and overlap exonerated. Located diffs `diff @ x=2 y=2 cov[last]=0 want=0xfffb0202
  got=0xff101010` — `got` is the clear colour.
- ⛔ Ruled out along the way, do not re-chase: submission order · the geometry/attribute frame of any triangle · the
  shader writing outside its mask (`v_cmp_ne_u32 vcc, 0, v4` masks zero-coverage lanes before any store) · the
  reference skipping triangles (6 of 6 drawn) · the arena (51 slots, 0 overlaps) · all TWELVE offline variants swept
  in `trimodel` (order / first-only / last-only / shared-mask / no-RMW × the signed-multiply mutation) — none
  reproduced `0xda27e77a`.
- ⛔ "The shader is writing dead/constant content" — killed on the host with no burn: the GPU digest was identical
  across burns 3 and 4 while the reference moved, and the degenerate-buffer digests (untouched fill `0x29c31dc5`,
  prefill `0x1969ddc5`, zeros `0x38699dc5`) are none of them `0xda27e77a`.
- Added `texmodel.cyr` / `texgate.cyr` / `texcore.cyr` / `texref.cyr`; the 32-bit model primitives moved into
  `tricore.cyr`, shared not copied.

## [1.56.20] — 2026-07-26 — Rung 11: barycentric RGBA interpolation, byte-exact on iron
- ⭐ RUNG 11 CLOSED ON IRON, exit 95: pixels exact AND every negative control fired. 15-case corpus via `#92` op
  `0x09`, per-case (distinct/rowspan/digest): 0 tri3col-xvary 64/63 `0x4cdd2ec5` · 1 tri3col-rotated 64/63
  `0x4cdd2ec5` · 2 tri3col-mirrored 97/206 `0x65a5e485` · 3 flat-CONTROL 1/0 `0xcec31dc5` · 4 grad-even-h64 17/0
  `0x80f53ab5` · 5 grad-odd-h200 6/0 `0xe54f56c5` · 6 quad-one-record 64/31 `0x00650105` · 7 quad-other-frame 1/0
  `0x29c31dc5` · 8 decoupled-frame 12/11 `0x5d024b9d` · 9 skew-frame 11/8 `0x1f9f5f6f` · 11 small-frame-low-t 32/0
  `0xb77a7a0d` · 12 large-frame-high-t 5/4 `0xfac1caea` · 13 alpha-varying 18/6 `0x0a466bc3` · 14 premul-boundary
  74/30 `0x4bbee402` · 15 extrapolation-premul 11/46 `0xf195816b`. Corpus digests seen across burns: `0x8aed72de`,
  `0x3433f179`, `0x3b53f44d`.
- ⭐ ROOT CAUSE: `tri_rgba.s` multiplied a SIGNED edge weight as UNSIGNED. Every failing pixel had E_A =
  **−2097152**; the agreeing neighbour at x=61 had **+2097152**. The 96-bit accumulator used `v_mul_hi_u32` on the
  HIGH dword, adding a spurious 2^64·p for negative weights. Fix = 3 instructions × 3 terms; blob **269 → 278
  dwords**, RSRC1 unchanged. Convicted on the host by a `tm_ehi_unsigned` mutation reproducing all four iron pixels
  bit-exactly (`0xff120012`, `0xff070007`, `0xff110011`, `0xff060006`).
- Negative controls and counts: N9 comparator distinguishes a one-byte poison · N10 prefill sentinel survives
  read-back · N11 5–6 cases carry ≥64 distinct values · N12 4–5 cases vary ≥32 levels along a row · N13 rounding
  correction fired **120,684 / 122,808 / 145,886** times depending on corpus · N14 premultiplied restore fired
  **12,096** times (and FAILED once — `min(q_ch, q_a) never fired`, exit 86) · N15 same case twice in one boot is
  byte-identical · N16 corpus digest must equal the host `triref` digest.
- ⛔ N16 was DECORATIVE through seven burns: it printed the dispatched-coverage fold (`dg_all`) while the host
  `triref` prints `tc_corpus_digest()` at coverage 255 — different functions of different inputs (`0x3b53f44d` vs
  `0x8aed72de`). Fixed to call the same function; host value to match is `0x8aed72de`.
- ⛔ N14 never fired for a STRUCTURAL reason: the restore only fires outside the attribute frame, but every case
  dispatched coverage built from THE FRAME'S OWN EDGES, so a pixel outside the frame always had coverage 0. Op
  `0x09`'s headline capability (decoupling shape from attribute frame) shipped UNTESTED — every case had shape ==
  frame.
- ⛔ `trimodel`'s gate had a hole exactly where iron failed: it sampled `px = x*11+2`, so x=62 was unreachable. New
  gate 1b sweeps every pixel × six coverages.
- ⛔ Two iron burns were spent on a defect in the INSTRUMENT, not the shader: `tri_cov_capture(tc_get (i,…))` inside
  a loop indexed by `gi` — `i` belonged to the printing loop above and was parked at `TC_N`, so every case captured
  coverage one row past the end of the corpus table, fifteen times over. And N15 called the 4-argument
  `tri_ref_fill` with THREE arguments (w landed in covbuf, h in w); because N15 compares the reference against
  itself, both halves were equally wrong and the control PASSED VACUOUSLY through every burn to date. Cyrius warns
  rather than errors on arity.
- Added the byte oracle (`#90` capture wired into `--tri`) and located pixel diffs.

## [1.56.19] — 2026-07-25 — EDGE_CAP replaced by a measured WORK bound; `--bench` stack smash fixed
- ⭐ EDGE SWEEP MEASURED (128x128 fixed, `n_edges` varied): ne 4 covered 6384 gpu 66 µs (**9.50 µs/edge**) · ne 8
  covered 9060 105 µs (9.62) · ne 16 covered 9776 186 µs (9.87) · ne 32 covered 9976 342 µs (9.81) · ne 64 covered
  10012 655 µs (9.79) · ne 128 covered 10016 1278 µs (9.76) · ne 256 covered 10016 2525 µs (9.75). µs-per-edge is
  FLAT to ~2.6% across a 64× range; cost is linear in E. Least squares: `cost_us = 28.8 + 0.0005953 * (w*h) *
  n_edges`. The 28.8 µs intercept independently agrees with rung 10's ~28 µs from a different sweep.
- ⇒ THE EDGE CAP WAS THE WRONG KNOB: it permitted 4096²×E=64 (~639 ms, six times over the ~94 ms watchdog) and
  forbade 64²×E=256 (~0.65 ms). Replaced by `GPU_EDGE_WORK_MAX = 2^26` on `w*h*n_edges` (~40 ms = 42.6% of the
  watchdog); `GPU_EDGE_CAP` raised to the ABI max **256**; `GPO_E_WORK` minted as its own reason code. The cap is
  now self-reporting.
- ⛔ Fixed — `--bench` exit 142 was a **40-BYTE STACK SMASH**. Every printed number was correct.
- Added `scripts/check-array-sizing.sh`, wired into `check.sh` (now 15 gates).
- ⭐ GPU timing now uses the measured clock: `GPU_TSC_PER_US` 3000 → calibrated. HDA likewise: `HDA_TSC_MHZ` 3000 →
  calibrated.
- ⛔ GPU ARENA: a shipped slot COLLISION, and the gate that structurally could not see it. Plan-step codenames
  removed from the GPU constant namespace.
- ⛔ `check.sh` could not report a failure — 8 of 9 gates aborted the run instead.
- Fixed: `kernel/version.cyr` stale at 1.56.17, and the documented way to fix it was a no-op.

## [1.56.18] — 2026-07-25 — Rung 10: the coverage kill gate MEASURED, and it does not fire
- ⭐ MEASURED crossover **1751 covered px** for BOTH unbatched and batched-16, against a pre-registered prediction of
  ~12,000 (unbatched) and ~50,000 (batched) covered px/frame — the GPU wins ~7× EARLIER than predicted. 1751 px is a
  42×42 region, about two glyphs. `tsc: 3194 cycles per microsecond` at boot.
- Full sweep (CPU / unbatched GPU / batched-16): 32x32 423 px 27 µs / 33 µs / 28 µs (CPU wins, gpu 122% and 103% of
  cpu) · 64x64 **1751** 100–101 µs / 35 µs (285%) / 31 µs (322%) · 96x96 3968 218–219 µs / 50 µs (436%) / 46 µs
  (473%) · 128x128 7156 384 µs / 58 µs (662%) / 54 µs (711%) · 192x192 16128 843–844 µs / 87 µs (968%) / 84 µs
  (1004%) · 256x256 28851 1484–1485 µs / 124 µs (1197% = 12.0×) / 117 µs (1270% = 12.7×). Timed via `uptime_us` #95
  (rdtsc), each point repeated to ≥100 ms and divided; both sides same boot, same geometry, same edge list.
- ⚠ Pre-registered MODEL correction from the same measurement: decomposing the 32x32 point gives FENCE ≈ **5.3 µs**
  and FIXED PER-DISPATCH ≈ **27.7 µs** — the fence is ~5 µs, NOT the ~60 µs S12 modelled. Batching 16-to-1 buys only
  **6%** at 256x256. Any future rung citing "87% overhead" must cite this measurement instead.
- ⭐ Added `uptime_us`#95 — rdtsc-backed, calibrated at boot against 50 ms of live ticks, returns **−1** rather than
  a plausible 0 when calibration is refused. `uptime_ms`#40 is FROZEN inside a foreground `run` (it reads
  `timer_ticks`, and a foreground program starts with IF cleared), which cost two iron burns. `gputri --bench`
  retimed onto `#95`.
- ⭐ Fixed — A RING-3 DIVIDE BY ZERO HARD-LOCKED THE KERNEL. `idt.cyr` listed vector 0 (#DE) among "deliberately NOT
  installed: 0-5, 7, 9, 15-31", so the bare-iretq default returned to the faulting `idiv` forever with interrupts
  enabled. Vector 0 now joins the installed set AND the {6,13,14} ring-3 kill set. `scripts/de-smoke.sh` 3/3 (`run:
  exit 128`, slot reclaimed), mutation-calibrated.
- Added `scripts/tsc-smoke.sh` (a differential proof, zero burns). Rung 9b re-confirmed at 1.56.18.

## [1.56.17] — 2026-07-25 — Rung 9b: agnos has a GPU triangle rasteriser (20 of 20 byte-identical)
- ⭐ BURN 2: **20 of 20 byte-identical to `refraster.cyr`**, every negative control N1–N8 fired, exit 95. Reference
  digests (must match the host `./build/cpuref` line for line): 1 plain triangle `0x4b493a41` · 2 zero-area
  collinear `0x76efddc5` · 3 backfacing CW `0xc07c1e5d` · 4 sliver 1px tall `0x4b657786` · 5 off-screen negative
  coords `0x5440139d` · 6 fully outside `0x76efddc5` · 7 pixel-centre straddle `0x3b0a2060` · 8 full-canvas cover
  `0x86576a9c` · 9 bowtie self-intersecting `0xe8e91315` · 10 overlap pair + sub-pixel-gap pair (14 edges)
  `0xb3e825b3` · 11 shared-edge quad axis-aligned `0xa10bd985` · 12 shared-edge quad skewed `0x78e67f69` · 13
  shared-edge quad near-full `0xe3686670` · 14 OPEN 3-edge path `0xec955771` · 15 x-asymmetric 128x64 `0x470faff1` ·
  16 width not a multiple of 64 (37x29) `0x8afb5563` · 17 tile boundary edge on x=64 `0x93bedd65` · 18 tile boundary
  corner `0x69681bb5` · 19 WIDE mask 200x64 `0x34eee961` · 20 regular 64-gon at the edge cap `0x97161ddd`. The
  `--cov` gate must still read 20/20 before anything else in a later burn is believed.
- Two blobs, 167 hand-authored gfx90c instructions: `edge_setup` 58 dwords + `edge_cov` 133→135 dwords, 64×1 one
  lane per pixel, NO sort, NO LDS, NO cross-lane op, and a 25-instruction branch-free divider that performs no
  division. `v_mul_hi_u32` and `global_store_byte` — neither of which had ever executed on agnos silicon — are
  retired as suspects.
- Burn 1 fault 1 (the TOOL): `refraster.cyr`'s `edge_add` dropped `y0 == y1` at ingest, so the five cases with a
  horizontal edge (4, 7, 8, 11, 18) held only 2 edges and the ABI requires ne ≥ 3 → `GPO_E_EDGEBUF`. All 20 digests
  unchanged after the fix — the proof the oracle did not move.
- Burn 1 fault 2 (a real SHADER bug, case 14, the OPEN path): the model's breakpoint walk breaks PER LANE; the
  shader rendered it as a WAVE-level `s_cbranch_vccz`, which only branches when NO lane has work. A lane with
  `any==0` fell through with vmin still INF, computed `v = min(INF, pr) = pr` and filled to the end of its row. Hid
  on 19 of 20 cases because a CLOSED path has winding 0 once crossings are exhausted. 631 of 4096 bytes wrong, worst
  delta 255. Reproduced exactly by emulating wave-level fall-through in `edgemodel.cyr`.
- ⭐ RUNG 5 (hang/recovery battery, 2026-07-25): THE CONSOLE SURVIVES A DEAD GPU. Arm A wedged the GPU as designed (a
  WAIT_REG_MEM that can never be satisfied) and the forensic block fired automatically: `command ring not
  responding`, `rptr 529 wptr 529 hqd_active 1 · grbm_status 3028 grbm_status2 8 cp_stat 0 · fence expected c2f0d02e
  saw 0 · breadcrumb NEVER WRITTEN` + a 16-dword ring dump. Arm B ladder: `recover R-2 FAILED — CP_HQD_ACTIVE stuck
  at 1` → `R-3 MEC halt/un-halt cycled` → R-2 FAILED again → `R-4 GIVING UP. gpu_wedged=1; GPU syscalls will refuse`
  (exit 91). Arm C after: `rptr 534 wptr 614 hqd_active 1 · grbm_status a0003028 grbm_status2 10100008 · fence
  expected c2f0d02e saw deadbeef · breadcrumb seq 1 of 2`, `matmul dispatch did not complete`, exit 89. Arm D:
  console and shell alive on the CPU blit path with `gpu_wedged=1 recover_rung=4`. ⇒ agnos can DETECT a GPU hang and
  SURVIVE it; it cannot CLEAR one. Shipped behaviour is detect → give up → degrade, and **R-4 must be the default on
  any ambiguity**. ⚠ Arm C-after is NOT evidence that recovery corrupts the GPU — the GPU was still wedged
  (`hqd_active 1`) because R-4 had already given up. That branch remains UNTESTED.
- Added rung 6 `arena-audit` (iron, read-only; the audit now ASSERTS containment rather than printing it), rung 16
  `tile-own` (host), rung 8 oracle (i) byte-identical to sadish (host), and a full-width BAND for `#85 gpu_fill`.
  Fixed `gpu_forensic_dump` racing the submission and reporting the wrong cause. `gpu-test/cyrius.cyml` pin 6.4.74 →
  6.4.78.
- ⛔ SHADER STATE REGISTERS ARE NOT READABLE ON gfx90c (structural, confirmed by re-read): the probe reports `rsrc1
  221 vgpr 29 sgpr 3 · rsrc2 0 usersgpr 0 tgid_x 0 tgid_y 0 · threads 0 l2cntl 525827 · scratch ring 0` then either
  `shader state reported (SH regs not readable; L2 on)` or `shader state probe DISAGREES`.

## [1.56.16] — 2026-07-25 — Hang forensics + recovery, PM4 lint, ASM agreement (host-complete)
- Added rung 2 `pm4-lint` (mutation-calibrated PM4 validator, host, 0 burns), rung 7 `asm-agree` (mabda's encoder vs
  agnos's shipped bytes, host, 0 burns), rung 8 `cpu-ref` (host, ⚠ PARTIAL), and rungs 4 + 5 — GPU hang forensics
  and recovery, with new syscall **`#94 gpu_recover_op(arm)`** and the ring-3 tool `/bin/gpuwedge` carrying five
  arms.
- Fixed `DIG_MODE` restore-on-exit (carried from 1.56.15).

## [1.56.15] — 2026-07-25 — M9 audio-arm result
- Fixed: `DIG_MODE` is restored on exit, so the audio arms are independent.
- The M9 burn (2026-07-24/25) ran both arms in ONE boot, both exit 95: `DIG_MODE 2→3` readback-verified, ATOM `#4`
  rc 0, `#76` DISABLE+ENABLE rc 0, both SILENT. ⛔ Its recorded conclusion ("sequencing is eliminated") is RETRACTED
  at 1.56.34 — both arms streamed digital silence, so the experiment carried no information.

## [1.56.14] — 2026-07-24 — M9: the audio path splits around the transmitter edge; phyid derived live
- Added M9a·M9b·M9c·M9d (`MODESET_AUDIO`) + M9e `/bin/modeset --audio-pre` / `--audio-post` and two `#93` ops:
  **`MDO_OP_AUDIO_PRE` (0x07)** and **`MDO_OP_AUDIO_POST` (0x08)**, plus the staging gate that was missing.
- ⭐ Fixed — ATOM `#76`'s `phyid` is now DERIVED FROM LIVE HARDWARE, never hardcoded. The live rule: the phyid is the
  DIG that is LIVE with `DIG_MODE != 0` — DIG1 on this box. Per-instance DIG back end at 1.56.14 `--dump` (101
  registers, exit 95): inst 0/2/3/4 all `BE=0x00010000 mode=1 FE_SOURCE=0x00 EN=0x00000100 enable=0`; inst 1
  `BE=0x10020200 mode=2 FE_SOURCE=0x02 EN=0x00000101 enable=1`. Exactly ONE live instance, closed-loop across three
  independent implementations (`gpu_phy_discover`, `m1-decode.py`, `atom-interp.py`).
- At the correct phyid, ATOM `#76 ENABLE` is nearly a NO-OP: with a full iron seed it collapses from 21r/17w/5d to
  **4r/2w/0d** — it reads `DIG_BE_EN_CNTL[1] = 0x00000101` and exits, writing ZERO PHY registers. The historical
  double-blanking is explained: those runs used phyid=0, where instance 0 reads not-enabled, so the table ran its
  full 17-write bring-up on a DEAD PHY.
- ⭐ Fixed — ATOM `#76 ENABLE` RESETS `DIG_MODE` ITSELF: the trace reads `566f v=10030200` then writes `566f
  v=10020200` (back to DVI), so an HDMI flip made at the disconnect does not survive the edge. The audio arms now
  re-assert `DIG_MODE` after `#76`. ⚠ amdgpu ftrace could never show this — amdgpu drives the PHY through native
  link_enc code and never calls ATOM `#76`.
- M8e's BE↔FE bracket was inverted around the PHY block; the verdict read a stale routing.
- M8e re-scoped to the REAL transmitter edge (`#76 DISABLE → ENABLE`, flag `ATOM_TX_CYCLE`). M8e write set, all
  instance-1: 5635 566f 5670 56a1 56c8 56d8 5d2f 5d30 5ec1 5ec8 5edb 5ede 5ee7 5ee8 5ee9 5eea — ZERO writes to 556F,
  UNIPHYA (5D2D/5D2E) or RDPCSTX0 (5DE9/5DF0/5E00-5E12). RDPCSTX1 lane enables step DOWN
  `0xd1f000→0xd0e000→0xd0c000→0xd08000→0xd00000` and back UP; perfect round-trip 5ec8 `0xd1f000` · 5ec1 `0x1c000` ·
  5ede `0x1d4444` · 5d30 `0x11000302` · 5670 `0x101` · 56a1 `0x10f`. exit 95; the operator kept typing afterwards.
- D8 answered: the PHY does NOT need a running pixel clock to lock — the `#76` cycle ran with the OTG DISABLED and
  came back (`ENABLE rc 0`, `resumed 1`, refresh exact).

## [1.56.13] — 2026-07-24 — M8: the enveloped transmitter op + the `#76` read-set capture
- Added M8a (`#93` op `MODESET_OP_TRANSMIT` + `/bin/modeset --transmitter`), M8b (the ATOM `#76` read-set capture +
  H5 snapshot-seed tooling), M8c (the infoframe / stream-attribute block is now REPLAYABLE).
- ⭐ Fixed — MD-2 OVERTURNED: ATOM `#76`'s `phyid` is **1**, not 0; M8e had been pointed at a dead PHY. Replaying
  `#76` against the H5 iron snapshot shows phyid=0 produces an **87,292-read POLL STORM** while phyid=1 is clean at
  **21 reads / 17 writes / 5 delays**. The `phyid=0` value came from a best-effort VBIOS object-info derivation
  (`enc_enum − 1`) that carried its own `[TODO confirm on iron]` and was hardcoded at `atom.cyr:971`.
- M8d encoder-only edge (93-register dump, exit 95): pre-state dig 1 `be_cntl 268567040 (0x10020200)` v_total 1481 →
  envelope open → frame 3201→0 stopped 1 → ATOM `#4` rc 0 → stream attributes + infoframes → ATOM `#76` SKIPPED
  (built without `ATOM_RUN_TRANSMITTER`) → envelope close → resumed 1, 59951 mHz; `be_cntl` unchanged, DIG_MODE 2 →
  2.

## [1.56.12] — 2026-07-24 — M6: the same-mode OTG envelope re-commit
- Added `#93` op `MODESET_OP_RECOMMIT` + `/bin/modeset --recommit`. Iron exit 95: pre-state v_total 1481, ctrl
  `2147554049` (0x80011301), otg_clk `65793` (0x10101), optc_clk `6`; `OTG_MASTER_EN 0` → frame count 2615 → 0,
  `stopped 1` → reprogram → `OTG_MASTER_EN 1` → `resumed 1`, frame count 115, refresh **59951 mHz = predicted**.
  Panel blanked then relit.
- ⚠ `OTG_CLOCK_CONTROL` was 65793 not 0x3 and `OPTC_INPUT_CLOCK_CONTROL` was 6 not 0x3 on the GOP-inherited pipe;
  writing back the SAVED values is why it relit. Forcing 0x3 would very likely have left the panel dark.
- ⚠ The instrument is BLIND to a black screen — a green exit 95 with a black screen is the underflow-dark case.

## [1.56.11] — 2026-07-24 — M1/M2/M3 read-only DCN dump, M4 OTG lock, M5 the first REAL modeset
- Added `#93` ops `MODESET_OP_DUMP` / `MODESET_OP_LOCK` / `MODESET_OP_VTOTAL` with `/bin/modeset --dump` / `--lock`
  / `--vtotal`.
- ⭐ M5 — THE FIRST REAL MODESET, exit 95: v_total 1481 → 1501 → 1481 at constant pixel clock and constant H timing
  moved the frame-counted refresh **59951 → 59152 → 59951 mHz**, landing on the prediction to the milliHz — a
  ~13,300 ppm step against a 12–17 ppm noise floor. Proves shadow→VUPDATE→live commit. Walk timings T+1931 ms →
  T+4053 ms → T+6151 ms; pre-state v_total 1481 h_total 2720 ctrl 0 pixclk_100hz 2415020.
- M4 (lock cycle acked, readback 1480, hold 120 ms, frames 1683→1694): a green M4 does NOT prove a write commits —
  V_TOTAL written back to its own value makes committed / shadow-only / never-left-shadow indistinguishable.
- Fixed: the M1 dump's M2 (PHY/RDPCS) offsets double-folded the IP base; `#93` caps `v_active` was always 0.
- ⛔ DECODE M1 DUMPS WITH `scripts/m1-decode.py`, NEVER BY EYE — decoding by eye cost a burn.

## [1.56.10] — 2026-07-24 — `#93 gpu_modeset_op`, the arm-once latch, and `klug_spill`
- Added H3 `/bin/modeset` + syscall **`#93 gpu_modeset_op(desc_uva, len)`** — one syscall number, an array of
  64-byte records, the operation named inside the payload.
- Added H2 the arm-once modeset latch: a failed modeset costs ONE bad boot, not a reflash. Mechanics: `modeset:
  latch ready ino=<n>` · `latch consts BLOCKED=1 ARMED=1 TOKEN=1297040453` · `latch armed at site=<N> ticks=<n>`.
  Disarm is `rm /.modeset-armed` → `modeset: verified good, latch cleared`. The latch deliberately SURVIVES reboots
  (`modeset: previous attempt did not disarm -- SKIPPED`), and is deliberately NOT auto-disarmed at boot: too early
  gives an unbounded, filesystem-invisible re-attempt loop escapable only by reflash; too late costs one `rm`.
- Added H1 `klug_spill` — the kernel can persist its own log ring to agnos-fs.
- Modeset exit codes: **95** OK (the writes went out — NOT that sound came out) · 98 latch already blocked this boot
  · 96 arm-first / display DARK (QEMU's answer) / no GPU carveout · 93 an ATOM step failed · 92 off-rate · 91
  watchdog fired · 90 every CPU phase read 0 µs (VOID, not "instant") · 89 disable never stopped the pipe or a
  `#92`/`#86` call failed · 88 BE↔FE · 87 the kernel predates the `#89` profile tail ⇒ a STALE kernel was flashed ·
  84/83 usage / no-arg.
- Changed cyrius pin 6.4.2 → 6.4.74 (const-fold gvar fix + `_cfo=0` codegen fix + `#92`/`#93` wrappers).

## [1.56.9] — 2026-07-23 — `#90`/`#91` land; the MODESET harness (H0, H7, H6, H4)
- Added **`#90 gpu_readback_shm(id, wh, srcxy)`** — GPU-copies a rect OUT of the blit back buffer into a client shm
  slot (screen capture) — and **`#91 gpu_blit_bb(srcxy, wh, dstxy)`** — copies a rect WITHIN the back buffer (window
  move / scroll), overlap-safe (downward moves copy bottom-up). Both on the proven MEC compute ring: no SDMA, no
  doorbell, no new firmware. This closes the `#89`→`#92` numbering hole.
- ⛔ A real readback-coherence bug found and fixed: reading into a REUSED shm slot returned a stale cache-line ghost.
  CP-DMA writes fresh DRAM (done-sentinel + WR_CONFIRM) but the CPU's WC `shm_kva` read is shadowed by the previous
  read's line. `gpu_readback_shm_sys` now `clflush`es the destination window `[shm_kva, +row*h)` before issuing the
  CP-DMA, via a new disassembly-verified `clflush(addr)` primitive in `io.cyr` (compiled bytes: `mov
  -0x8(%rbp),%rax; clflush (%rax)`). Burn ladder 84 → 76 → 51 → 95 → 95; burn 4 used a whole-cache `wbinvd()`, burn
  5 replaced it with the scoped per-line `clflush`.
- Added H4 the ATOM instrument pack (`rc = 0` now means "a table ran", and nothing else does), H6 the ATOM
  DIV32/MUL32 sweep, the H7 anchored DCN register table (30 modeset constants, derived and gate-verified), and
  `gpu_refresh_measure()` (the off-GPU refresh oracle, I2).
- Default kernel `cmp`-identical to 1.56.8 — all four selftests are opt-in build flags. Gates: ARC SWEEP 15/15 ·
  `check.sh` 14/14 · `kprint-len-check` 2533/0 · `atom-instr-smoke` 7/7 · `atom-math-smoke` 4/4 · `dcn-reg-derive`
  12/12 anchors.

## [1.56.8] — 2026-07-23 — llvm-mc removed: the build no longer touches a C/C++ toolchain
- Deleted `scripts/gfx9-asm.sh` and `scripts/gfx9-asm-check.sh` and the ISA-gate line in `check.sh` (back to 14
  gates). The committed hex tables ARE the shader — iron-proven on archaemenid, the authority — and the `.s` files
  are human-readable reference. The sovereign gfx90c assembler is mabda's Cyrius gfx9 encoder
  (`mabda/src/gfx9_encode.cyr`). No kernel behaviour changed; the ISA bytes are byte-for-byte what 1.56.7 shipped.
- Ratified D-1 (llvm-mc REJECTED), D-2 (`#92` blend semantics = PREMULTIPLIED f32, frozen; consumed end-to-end
  sadish `sd_premul` → setu `SETU_SURF_PREMULTIPLIED` → aethersafha `#92` op `0x01` → kernel `out = src + dst*(1 -
  a/255)`; straight-alpha `rend_blend` is dead code), D-4 (whole-surface translucency stays a real deferred
  requirement, ~50–70 register writes / 4–6 iron bites).
- The GPU crown's three ML consumers were iron-proven in this window (2026-07-23, exit 95): rupantara 0.4.1 f64 MLP
  up-projection via `#83` **byte-identical** to rosnet `linear_fwd` (4 tiles; bit-exact, not tolerance, for
  bias-free K≤8 because both sides compute `round(round(x·W)+acc)` k-ascending) · tentib 1.0.1 ternary INTEGER
  matmul via `#82`, M=8/K=16/N=32, 8 tiles, **bit-exact** at K=16 cross-tile and the first negative-integer proof of
  `#82` · attn11 1.14.1 `qlinear_fwd` routing to rupantara's `linear_fwd_gpu` via `#83`.

## [1.56.7] — 2026-07-23 — the four hand-typed 1.54.x compute kernels get `.s` sources (ISA gate 11/11)
- `matmul_copy` (C2g-2 kernargs), `matmul_dot` (C2g-3 reduction loop), `matmul_i32` (the C2g-4 integer crown) and
  `matmul_f64` had been hand-typed as hex before the emitter existed.

## [1.56.6] — 2026-07-23 — the D lane REMOVED (it was finished), and its five burns written up
- Removed the D lane, code and flag — it was FINISHED and had been re-armed. Fixed: the iron log had no record of
  the five D-lane burns, so a later session rebuilt the finished lane.
- D-lane durable findings, banked: DCN registers latch ONLY under the OTG lock with a VUPDATE trigger — a bare write
  lands in shadow, the pipe keeps scanning the previously-latched values, and **the readback returns the shadow**,
  so a write looks applied while changing nothing (needs the OTG master update lock plus a surface-address re-arm,
  HI then LO, the LO write being the flip trigger) · `OPTC0_UNDERFLOW` bit10 is STICKY and already reads 1 at boot
  on this pipe, so only a before/after DELTA check is valid and the instrument is degraded here · the GOP's
  `MPCC_CONTROL` is `0xFFFF0461` (MPCC_MODE=1 TOP_LAYER_PASSTHROUGH, ALPHA_MULTIPLIED_MODE=1) vs amdgpu's known-good
  `0xFFFF0422` · the MPCC BACKGROUND is the bottom blend operand and agnos had never read or written it ·
  `MPCC_ALPHA_BLND_MODE` mode 0 on the GOP's XRGB surface makes the screen BLACK.
- ⛔ The burn-3 wrong theory came from decoding a register BY EYE: `4294902881` read as `0xFFFF0A61` when it is
  `0xFFFF0461`, and the two differ in exactly the field that decides whether the blender runs.
- ⛔ D-lane burns 1 and 2 were unwinnable by arithmetic: their stimulus was the white-on-black console where every
  pixel is `0x00FFFFFF` or `0x00000000` — R == G == B, so ANY permutation of the colour crossbar is the identity.
- Post-mortem defect: both D bites wrote HUBPRET0 / MPCC0 / OPTC0 as BARE offsets (instance 0) while correctly
  indexing `DCSURF_SURFACE_CONFIG` two lines away. All five burns ran on pipe 0.
- Fixed: module-global initialisers that are EXPRESSIONS never ran; a `burn-verify` marker that verified nothing;
  the D-lane underflow check could never fire. Added `scripts/gfx9-asm-check.sh`. GPU planning consolidated from
  seven documents to one.

## [1.56.5] — 2026-07-22 — plan-S12: one submission per frame; S4 packed blend; S3 coherence
- ⭐ S12 IRON-PROVEN: `gpu: batch frame seq **107 us** batched **60 us**` (1.78×), and `batched frame pixel-identical
  to op-by-op (6 ops, 1 submission)`. ⚠ Residual: those six ops move ~240 KB ≈ 8 µs of real memory traffic at ~30
  GB/s, yet the batched frame still costs 60 µs — ~87% fixed cost even batched. What remains is six per-dispatch
  whole-L2 invalidates and six CS_PARTIAL_FLUSHes each stalling the CP on a coherency ack.
- ⭐ S4 IRON-PROVEN: `v_perm_b32` byte crossbar + RGBX↔BGRX swap + VOP3P `packed blend bit-identical to float blend
  (64 px)` at **27 VALU per pixel packed vs 31 float**. NEW HARDWARE FACT: `v_cvt_pk_u8_f32` CLAMPS NEGATIVE INPUTS
  TO 0.
- ⭐ S3 COMPLETE (four arms, iron): S3-A shader→fb WB=on cpu-read 4096/4096 COHERENT · S3-B shader→fb WB=off 0/4096
  STALE · S3-C shader→cpdma WB=on 4096/4096 COHERENT, WB=off 0/4096 STALE · S3-D cpdma→shader INV=on new 4096/4096
  COHERENT stale 0. ⚠ THE INVALIDATE ARM IS NOT STABLE ACROSS RUNS: run 1 read S3-D INV=off new 4096/4096 COHERENT
  stale 0; run 2 (same 1.56.4, `S3-D primes executed 3 of 3`) read **S3-D INV=off new 0/4096 STALE, stale 4096**,
  plus `S3-D CONTROL cpu-wr INV=off new 0 of 4096 STALE`. Keep both captures — the pair IS the evidence.
- Fixed: S3 arm D was confounded by construction (both rows VOID, not a pass); arm B's PANEL half was confounded in
  the permissive direction; the doc error that caused the arm-D design.
- Binary size ceiling 1.7M → 1.8M; the arc closed on 1.7M at **1,700,472 B** (472 B over).

## [1.56.4] — 2026-07-22 — `#92` iron-proven end to end; three P0 defects fixed
- ⭐ IRON-PROVEN: the `#92` descriptor ABI works from ring 3. `#92`/`#93`/`#94` collapse into ONE descriptor syscall
  (plan S8, decision D-3): one number, an array of 64-byte op records, opcode inside the payload.
- ⛔ P0 — THE SHADER ARENA WAS INSIDE THE VM PROTECTION-FAULT SINK PAGE: `GPU_BLEND_SHADER_SUBOFF ==
  GPU_VM_DUMMY_SUBOFF == 0x15000`, which `gpu_vm_setup()` zeroes at boot and the hardware writes faults into. Five
  shader kernels had been polling a done-marker in that page. Relocated to a strided residency table at `0x50000`.
- ⛔ P0 — coverage dispatched with a garbage RSRC1 and a wild kernel store: both call sites passed 11 args to a
  12-parameter dispatcher, so RSRC1 was whatever `gx` happened to be (≈20 VGPRs / 8 SGPRs where the kernel needs 32)
  and `done_phys` was undefined, making the function's first statement a wild kernel store. **The 1.56.3 coverage
  proof is therefore VOID.** Cyrius warns rather than errors on arity.
- ⛔ `SHADER_COV` / `SHADER_RECT` without `SHADER_BLEND` was a SILENT NO-OP that cost a burn (`gpu_shader_cov_test`
  early-returns unless `gpu_blend_ok == 1`, set only by `gpu_shader_blend_test` under `#ifdef SHADER_BLEND`).
  `scripts/build.sh` now HARD-FAILS on the combination, negative-tested against the exact flag set that produced it.
- Added: gradient reaches ring 3 for the first time; `#89` gains discovery; two build gates each verified to fail on
  the defect that shipped; the arc's missing `BURN_*` arms.
- First iron for the glyph/gradient pair: `shader glyph expand online (1bpp text, bit-exact, 558 px set)` — the
  panel shows "AGNOS SHADER GPU" unmirrored, confirming MSB-first bit order — and `shader gradient online (row 0
  exact, max dev 1)`. `#92` op `0x02` (coverage): four overlapping translucent discs, curved edges with no
  staircase, exit 95.

## [1.56.3] — 2026-07-22 — the drawing-primitive list completes: glyphs + gradients + coverage blend
- Added S8 1bpp glyph expansion (`#94 gpu_glyph_shm`), S9 linear gradient, S7 coverage blending (`#93
  gpu_blend_cov_shm`) — anti-aliased shapes and the text path. (These numbers are the pre-1.56.4 assignment; 1.56.4
  collapsed them into `#92`.)
- Changed: one ring program per kernarg shape, not one per kernel.
- Precision, measured not assumed: row 0 asserted bit-exact; elsewhere the bound is **2**, not `blend_cov`'s 1,
  because `t` comes through a different path. `cov = 0` and `cov = 255` must both be bit-exact. The gradient kernel
  is NOT claimed bit-exact and the test says so.

## [1.56.2] — 2026-07-22 — translucency reaches ring 3 (`#92 gpu_blend_shm`) + arbitrary rect width
- Added S6 arbitrary rect width (the EXEC bounds guard) and `#92 gpu_blend_shm`.

## [1.56.1] — 2026-07-22 — the first alpha blend on the shader cores; shaders stop being hand-typed
- Shaders are now MACHINE-ASSEMBLED. `shader alpha blend online (64 px, bit-correct vs CPU)` — the first bit-correct
  shader arithmetic on the CUs, bit-exact against the CPU reference on all 64 test pixels. Rounding settled on iron.
- S3 grid blend into the scanout back buffer: `shader rect blend online (256x64 grid, bit-correct, presented)` — all
  16,384 pixels bit-exact and visually confirmed (green left / red right). `shader blend width guard ok (200 px, 56
  px tail untouched)`.
- First blend attempt stored 64 of 64 lanes but `MISMATCH at lane 1 got 4294638330`.
- S1 / D0 probes are now honest reports rather than false gates.

## [1.56.0] — 2026-07-22 — ✳ CYCLE OPEN: the SHADER arc (alpha, translucency, text)

## [1.55.32] — 2026-07-22 — the GPU compositor seam `#86`-`#89`: a whole frame with zero per-pixel CPU work
- ⭐ IRON-PROVEN: `run /bin/gpublit` → exit 95 — a whole mock compositor frame with zero per-pixel CPU work:
  `gpu_caps`#89 → `gpu_fill`#85 → `gpu_fill_rect`#88 ×3 → `shm_create_gpu`#86 + `shm_write`#72 → `gpu_blit_shm`#87
  ×2 → `present`#84. The window was positioned from the geometry `#89` itself reported.
- **`#86 shm_create_gpu(size)`** — the GPU-VISIBLE peer of `shm_create`#71. Same table, same
  `shm_write`/`shm_read`/`shm_free`; the page is carved from the GPU carveout (2.5 GB in, clear of console FB / back
  buffers / PSP TMR / compute arena) so it has an MC address CP-DMA can read. Not an optimisation: `#71` uses
  `pmm_alloc_2mb()` → system RAM, which the GPU cannot reach at all. Returns −1 with no carveout (QEMU) → caller
  falls back to `#71` + the CPU path.
- **`#87 gpu_blit_shm(id, wh, dstxy)`** — composites that surface into the blit back buffer via `gpu_cp_dma_blit`.
  `blit`#39 packing (`wh=(h<<16)|w`, `dstxy=(dy<<16)|dx`). REJECTS (does not clip) off-screen rects.
- **`#88 gpu_fill_rect(color, wh, dstxy)`** — the rect peer of `gpu_fill`#85 (which only cleared the whole back
  buffer), via `gpu_cp_dma_fill_rect`, one CP-DMA constant-fill per row.
- **`#89 gpu_caps(buf, len)`** — capability + back-buffer geometry probe: 8× u32 (32 B) — flags (GPU present /
  double-buffer armed / carveout available), `bb_pitch`, `bb_width`, `bb_height`, shm slots total + free,
  `shm_max_size`. Geometry and counts only; no MC address crosses the boundary. ⚠ `fbinfo`#38 reports the CONSOLE
  framebuffer, a different surface.
- Fixed: `#89` reported width=0/height=0 on a cold probe (geometry derived from `gpu_bb_pitch` / `gpu_bb_fbsize`,
  populated only by `gpu_blit_arm()`), so the natural probe-then-clip order always saw zeros and every subsequent
  blit would have failed. `#89` now arms lazily (idempotent).
- Fixed: `shm_free` would have handed a carveout address to `pmm_free_2mb`, corrupting the page allocator's bitmap
  with memory it never owned. Carveout slots now reclaim by clearing the entry.

## [1.55.31] — 2026-07-21 — `/bin/gpufill`: the ring-3 consumer of the CP-DMA fill syscall
- IRON: `run /bin/gpufill` → exit 95, all three colours displayed.

## [1.55.30] — 2026-07-21 — P9: first hardware 2D on agnos — CP-DMA copy VERIFIED on iron
- All three 2D primitives green in one boot: `CP-DMA hardware copy verified (4KB, dst==src)` · `CP-DMA hardware fill
  verified (4KB, all=pattern)` · `CP-DMA hardware blit verified (8 rows, strides differ)`. The blit ran 8 rows × 128
  bytes with src pitch 256 B → dst pitch 320 B and the destination's inter-row PADDING UNTOUCHED — proof of real
  per-row stride addressing, not a linear copy.
- Mechanism: a 7-dword PM4 `DMA_DATA` (op `0x50`) on the proven MEC compute ring. MC-direct SRC/DST_SEL=0 gives
  CPU-visible DRAM with NO ACQUIRE_MEM. FILL = `DMA_DATA` constant-fill (SRC_SEL=2 DATA, CONTROL `0xC0000000`,
  dw2=value, dw3=0). Added syscall **`#85 gpu_fill`**.
- ⚠ `gpu_cpdma_submit` MASKS the byte count (`bytes & GPU_CPDMA_MAX`) rather than rejecting it, so a count past 64
  MiB silently truncates and reports success.

## [1.55.29] — 2026-07-21 — P9 checkpoint: the SDMA engine rings up on iron (first-packet fetch WIP)
- Ring up FIRST TRY: `SDMA firmware loaded (PSP-validated)` (fw_type SDMA0=9 from `/fw/sdma.bin`, F32 un-halted
  HALT→0), `sdma halt 0 idle 1 rptr 0 wptr 0`, `sdma ring ready (F32 running, idle)`.
- Then `sdma halt 0 idle 1 rptr 0 wptr 0 cntl 262146` → `sdma copy TIMEOUT rptr 0 wptr 44 cnt 266269 base 4102029824
  halt 0 cap 0 cntl 262146`. Neither the NBIO-routed doorbell (CAPTURED=0) nor a bare register-wptr made the engine
  fetch, even with AUTO_CTXSW set (`cntl 0x40002` proves b18 latched; `cap 0` proves the doorbell never reached the
  engine).
- SDMA is PARKED after six burns, all TIMEOUT at rptr 0: P9.2a register-wptr · P9.2b wptr-poll · P9.2c doorbell
  (first with the wrong index `0x08`, then corrected to `0x1E0` = `AMDGPU_DOORBELL64_sDMA_ENGINE0 0xF0 << 1`, byte
  0x780) · P9.2d NBIO route `GDC0_BIF_SDMA0_DOORBELL_RANGE` written+verified `0x40780` · P9.2f AUTO_CTXSW · P9.2g
  register-wptr with the doorbell disabled. P9.0 read-only probe of `gpu_reg32(0x1260, 0..0x100)` did NOT hang; base
  `0x1260` maps 1:1; `STATUS_REG = 0x25` (IDLE b0). ⚠ This is an agnos SETUP gap, NOT a hardware limit — Linux and
  Windows drive SDMA on this box. Resume state: `rptr 0 wptr 44 cnt 266269 base 4102029824 halt 0 cap 0 cntl
  262146`.
- ⚠ Related correction: the MEC compute doorbell does NOT advance rptr on this iron either; agnos falls back to a
  direct `CP_HQD_PQ_WPTR_LO` register write.

## [1.55.28] — 2026-07-20 — P4: the AMD-Zen quiet-boot scanout banding FIXED (iron-validated)
- ⭐ ROOT CAUSE: the firmware leaves an **800×600 surface DCN-scaled up to 2560×1440** while `boot_info` reports the
  OUTPUT geometry, so `fb_console` rendered 2560-wide and smeared. It was NOT tiling and NOT DCC. Measured: HUBP
  viewport abs `0x5EA` = `0x02580320` = 800 (0x320) × 600 (0x258); real pitch `0x607` = **832 px** (800 aligned up
  to 64); `SCL_MODE 0x0CEC = 1` (active, not bypass=6). The 1.33×-wide-ellipse artifact is exactly
  (2560/800)/(1440/600) = 1.333.
- Fix = `gpu_scanout_matchgeom`: read the real viewport and pitch and override `fb_console`'s geometry via
  `fb_set_geom`. READ-ONLY, no register writes. Interactive console clean on iron.
- Burn 4 diagnostic: `scanout sw_mode 0 dcc 0 hubp_pitch_px 832 fb_pitch_by 10240 pixfmt 8`.
- ⛔ Burn 3: writing the "correct" pitch 2560 to `0x607` under the OTG lock BLACKED THE PIPE AND HUNG THE BOX. Never
  re-attempt.
- ⛔ Neither parked option was needed: a HUBP `clear_tiling` port, or a simpledrm-style shadow-buffer FB console. The
  OSDev #57150 tiled/DCC thesis is FALSIFIED.
- Residual, accepted by operator decision: the ~84 kernel boot lines painted BEFORE the register aperture maps
  (~log-line 85 in `gpu_probe`) still band.

## [1.55.27] — 2026-07-20 — A4: the register-VALUE class is exhausted; the ACR/CTS path
- ⭐ At 1.55.26 agnos's dump became byte-identical to the amdgpu-playing answer key on the last three diverging
  registers — `DCCG_AUDIO_DTO0_MODULE` **0x24d998** (was 0x24d9b2), `HDMI_ACR_STATUS_0` **0x3af5c000** (was
  0x3af5e000), and `HDMI_ACR_48_0` / `44_0` / `32_0` all **0x3af5c000** (were 0) — the kernel logged `gpu: hdmi acr
  cts programmed (241500, amdgpu-match)`, and the sink was STILL SILENT with tap1 reading silence. ⇒
  **Register-value equality with a working driver does not produce sound. The entire register-poke class of fix is
  CLOSED.**
- P4 HUBP read-only anchor dump (1.55.27): kernel printed `scanout sw_mode 0 dcc 0 hubp_pitch_px 832 fb_pitch_by
  10240 pixfmt 8`, `reg603 pitch_px 0 reg609 prim_hi 0 reg60b sec_hi 244`, `real pitch 0x603 differs from fb stride
  -- narrow/scaled surface, fix 0x603`, plus 24 raw register reads. This read-only-anchor idiom ended ~8 burns of
  derived-offset guessing.
- `cmp`-verified that the flag changes the artifact: 1,604,232 B off / 1,607,424 B on.

## [1.55.26] — 2026-07-19 — ★ AGNOS POWERS ITSELF OFF (ACPI S5, iron-validated)
- `poweroff` at the agnsh prompt runs the full ACPI S5 sequence and the power LED goes out. ACPI ground truth on
  archaemenid: `acpi: sleep type a 5 b 0`, matching `iasl`. AMI DSDT 36,097 bytes, revision 2, OEM `ALASKA A M I `;
  `_S5_` is `Package(0x04){0x05, Zero, Zero, Zero}` ⇒ SLP_TYPa = 5, SLP_TYPb = 0.
- ⛔ HAZARD: on the AMD FCH a CF9 write of `0x0E` is a real S5 POWER-CYCLE, not a warm reset (QEMU advertises 0xf).
- First execution anywhere of four functions QEMU structurally cannot reach: `ahci_port_stop()`, `hda_quiesce_all()`
  (two controllers), `r8169_quiesce()`, `gpu_quiesce()`.

## [1.55.25] — 2026-07-19 — orderly shutdown (`reboot` resets the machine on iron) + the A4 control
- Ten of eleven shutdown bites closed. Binary crossed 1.5M at **1,600,712 B** (712 B over).

## [1.55.24] — 2026-07-19 — ATOM interpreter PROVEN ON IRON; the audio clock is ALIVE
- ⭐ SOVEREIGN ATOM INTERPRETER BIT-CORRECT ON IRON (DRY build, no MMIO, no amdgpu): `atom: rom=188 cmd=93fa
  data=94a0`. The encoder run emitted exactly the oracle's **5 writes** with `reads=5 writes=5 delays=2` rc=0; the
  transmitter run emitted exactly the oracle's **17 writes** with `reads=21 writes=17 delays=5` rc=0. VBIOS acquired
  from ACPI VFCT: `vbios VFCT vid=1002 did=1638 len=55296`, `sig=aa55 atomhdr=188`.
- ⭐ THE AUDIO CLOCK IS ALIVE — the arc's first counted instrument: `gpu: acr cts 241502 -> 483006 -> 241502 (n
  doubled then restored)`, EXACTLY 2×. A dead or stalled read clock cannot produce a stable 241502 that tracks the
  pixel clock to 11 ppm and doubles precisely with N. ⇒ **THE ENTIRE CLOCK HYPOTHESIS CLASS IS DEAD.** Free echo
  test in the same dump: `HDMI_ACR_48_0`/`44_0`/`32_0` all read 0 (ACR_SOURCE=0 = HW-measured), so
  `HDMI_ACR_STATUS_0` is a genuine measurement, not an echo.
- ⛔ THE DCCG SYMCLK LEAD IS FALSIFIED BY MEASUREMENT. In-boot A/B: window A (symclk OFF) `159=0 15a=0 15b=0 15c=0
  176=0` vs window B (symclk ON) `159=0xd000d 15a=0xd000a 15b=0xd000a 15c=0xd000a 176=0x1111`, two passes each. The
  writes demonstrably LANDED and the sound was unchanged. Independent kill: abs `0x159`–`0x15C` are
  `DPPCLK0..3_DTO_PARAM` and abs `0x176` is `DPPCLK_DTO_CTRL` (display-pipe clock DTO parameters, not symbol-clock
  enables); the real `SYMCLKA_CLOCK_ENABLE` is abs `0x160`, and amdgpu writes ZERO SYMCLK registers anywhere in the
  11,582-entry modeset capture. Also: abs `0x159` reads 0 while the display is lit and working.

## [1.55.23] — 2026-07-18 — Sovereign ATOM BIOS interpreter: the HDMI transmitter bring-up (A2/A3/A4)
- `gpu_vbios_acquire()` pulls the VBIOS ATOM image from the ACPI VFCT table (Cezanne is an APU — no discrete flash
  ROM) and verifies VendorID `0x1002`. Commands driven: `DIGxEncoderControl(#4, STREAM_SETUP, HDMI)` then
  `DIG1TransmitterControl(#76, ENABLE, HDMI)`.
- ⛔ FALSIFIED: "the ATOM ENCODER setup is the missing step". An encoder-setup-only run (`atom: transmitter SKIPPED
  (encoder-only, PHY untouched)`, `atom: encoder rc=0`, `reads=5 writes=5 delays=2`, `HDMI bringup OK`) was
  display-SAFE (reached the shell) but STILL SILENT, with the register file byte-identical to the silent baseline.

## [1.55.22] — 2026-07-18 — HDMI transmitter mechanism resolved; DMCUB is DORMANT
- ⭐ Read-only DMCUB attach probe: `dmcub: CC_DC_PIPE_DIS 0x10000` · `CNTL 0x20000` · `SCRATCH0 0` · `INBOX1 base 0
  size 0 wptr 0 rptr 0` · `NOT attach-ready -> Path B (PSP-load fw)`. The GOP leaves DMCUB in soft-reset with no
  ring and no firmware. ⇒ **The whole T-series (DMCUB-mediated bring-up) is RETIRED**; the arc redirected to
  host-ATOM. This reading overturned the cut's own headline conclusion.
- ⭐ The feed is PROVEN correct — a Linux userspace reproduction of agnos's feed plays sound.

## [1.55.21] — 2026-07-17 — HDMI audio: the register + format class CLOSED; magnitude EXONERATED
- ⛔ FALSIFIED — sample MAGNITUDE. The HDMI instance was driven at **−0.8 dBFS (amp 30000)** with the full `tonegen`
  battery (SINE / SQUARE / SAW / TRIANGLE 440 Hz 2 s each, then a 220–990 Hz sweep) and was still silent.
  `AFMT_AUDIO_CRC` is amplitude-blind and the sink's amp was armed, so magnitude was the last never-measured
  quantity. Exonerated.
- The DIG register file is now compared EXHAUSTIVELY against the known-good capture; two fixes reverted. The codec +
  AZ + ELD captures land — two more fixes falsified.

## [1.55.20] — 2026-07-16 — HDMI audio: unmute AFTER the feed is live (amdgpu's trigger→unmute order)
- Fixed: the AVMUTE unmute edge fired over an EMPTY FIFO, before the codec feed started.
  `HDMI_AUDIO_PACKETS_PER_LINE` now explicitly programmed (was implicit 0 after the live flip).
- ⛔ FALSIFIED — the AFMT RAMP hypothesis: Radeon-lineage `AFMT_RAMP_CONTROL0-3` values were programmed (`0xffffff` /
  `0x7fffff` / 1 / 1, confirmed in the dump) and the result was still silent AND the shutdown release pop
  DISAPPEARED — non-zero envelope values actively WORSEN DCN 2.1. Reverted; NEVER RE-PROPOSE.

## [1.55.19] — 2026-07-16 — HDMI audio: the FIFO was fed before the drain was armed
- Fixed (a real driver-class ordering bug): `hda_stream_arm` set SD_RUN seconds before `gpu_hdmi_audio_enable`
  opened the AFMT drain. Instrument-confirmed; still inaudible.
- From 1.55.19 onward agnos's own dump reads `AFMT_STATUS 0x40000010` — bit24 CLEAR, byte-identical to
  amdgpu-playing — and the kernel logs `gpu: hdmi AFMT drain steady after feed (bit24 clear)` in every burn
  0716–0720.
- Added `HDMI_AUDIO_SWEEP` (an in-boot fix-profile matrix, so a hypothesis no longer costs a reflash).
  `HDMI_DB_CONTROL` now matches amdgpu.

## [1.55.18] — 2026-07-15 — audit the audio arc: seven-dimension adversarial pass
- Fixed: the s16→24-bit packing was wrong, on a path that no longer runs; the HDMI converter format reverted to
  16-bit (24-bit never had a basis); three sites chose the stream format independently and could disagree; the
  stream log reported a tag the hardware never had; bind-single could re-mute the live converter on a
  shared-converter codec; a failed bind stranded the box on a dead digital sink; a dead route hook that only looked
  like it steered the codec.
- Fixed: the receiver ran unserviced for the entire pre-`sti` boot window (the DHCP regression).

## [1.55.17] — 2026-07-15 — bind ONE pin, match amdgpu's format; CRC Model A confirmed by mute
- Fixed: the digital BROADCAST was the bug. ALSA device↔pin map on this box is not sequential and not the pin nid —
  derive from `pcmNp/info` id `HDMI <k>` == `eld#0.<k>`: hw:0,3 = HDMI 0 = eld#0.0 = pin 0x03 cvt 0x02
  (monitor_present 0) · **hw:0,7 = HDMI 1 = eld#0.1 = pin 0x05 cvt 0x04 = the Acer XB323U** · hw:0,8 = HDMI 2 = pin
  0x07 cvt 0x06 · hw:0,9 = HDMI 3 = pin 0x09 cvt 0x08. agnos logs the same enumeration then `hda: hdmi bound pin
  0x05 cvt 0x04 only (others unbound)`.
- ⭐ CRC MODEL A CONFIRMED by the mute experiment (prediction pre-registered before the run). Method: the encoder's
  own mute — `enc1_se_audio_mute_control()` is `REG_UPDATE(AFMT_AUDIO_PACKET_CONTROL, AFMT_AUDIO_SAMPLE_SEND,
  !mute)`; DIG1 `AFMT_AUDIO_PACKET_CONTROL` = dword `0x21AA` BASE_IDX 2 = byte `0x159A8`. Measured: BASELINE tone
  tap0 DONE=1 CRC `0x0d0827`, tap1 DONE=1 CRC `0x81b8cf`, `AFMT_STATUS 0x40000010`. MUTED D1 (bit11 SET, wrote
  `0x00000800`): both taps DONE=0, `AFMT_STATUS 0x41000010`. MUTED D2 (bit11 CLEARED, wrote `0x04000000`): both taps
  DONE=0, same status. RESTORED (`0x04000801`): tap0 `0x57bc7a`, tap1 `0xba4251`. Model B predicted DONE=1/CRC=0
  under mute; BOTH COUNTERS STOPPED DEAD ⇒ the counter is gated PER-TAP. Model A stands.
- ⚠ Muting the WORKING amdgpu path SETS `AFMT_STATUS` bit24 (`0x40000010` → `0x41000010`) and it is STICKY — nothing
  acks it.
- ⚠ NO REPAIR IN THIS CUT. There is no register left to write.

## [1.55.16] — 2026-07-15 — the cut that stopped guessing and built the instruments
- ⭐ Added the audio CRC — the first instrument on this block that answers instead of echoes — plus `HDMI_STATUS`
  (the read-only verdict nobody had ever read), `BURN_HDMI_DUMP` (the measurement-burn recipe), and
  `burn-verify.sh`.
- `AFMT_AUDIO_CRC_SOURCE` is a bare 1-bit field (shift `0x8`, mask `0x100`) with no enum, no prose and no consumer
  anywhere in the Linux tree; the only in-tree writes are legacy DCE parking it disabled (`dce_v8_0.c:1553`,
  `dce_v10_0.c:1601`, `dce_v11_0.c:1650`, all `0x1000`). Calibration (three Linux-side experiments, zero burns):
  CASE A digital silence playing — source=0 RESULT `0x00000001`, source=1 RESULT `0x00000001` (DONE=1 CRC=0) · CASE
  B 440 Hz tone — source=0 RESULT `0x80fd3801` (CRC `0x80fd38`), source=1 RESULT `0x15f00201` (CRC `0x15f002`) ·
  CASE C nothing playing — BOTH sources RESULT `0x3d370600` with CRC_DONE=0 (never completes in ~300 ms) while
  `DIG1_AFMT_CNTL` stayed `0x00000101`, so the audio clock was still ON and the case is conclusive. ⇒ Both taps are
  PCM-CONTENT-SENSITIVE; a zero CRC with DONE=1 means 2048 ZERO SAMPLES.
- ⛔ FALSIFIED — the IEC-60958 FRAMING reading of the taps: if either tap read 60958 framing its CRC would be
  NON-ZERO over an all-zero PCM stream (`AFMT_60958_0/1/2` are programmed non-zero and byte-identical on both
  paths). Digital silence read exactly `0x000000` at BOTH taps. `CRC_SOURCE` selects a STAGE, not a channel (a
  channel selector already exists at CH_SEL [15:12], 0 in every run).
- ⛔ `burn-prep.sh BURN_HDMI_DUMP=1` correctly built the measurement kernel (1,573,656 B), then `check.sh` ran the
  bare production kernel (1,566,336 B) straight over the artifact. Hence `burn-verify.sh`.
- Rejected: `PIN_CONTROL_LPIB` — not the discriminator it looks like.

## [1.55.15] — 2026-07-15 — everything amdgpu does, and the panel is still mute
- Fixed: the Azalia index window has no memory; the slot map is cleared by the AUDIO_ENABLED transition; the AVI
  InfoFrame body was invented; the codec-side verb order, with the slot map behind vendor verbs. Added the PME
  workaround (a new SMU mailbox), the FIFO overflow ack, and sink-select (the parked HDA bite 4).
- ⭐ SINK AUDIBILITY SETTLED 2026-07-15 BY EAR: the Acer XB323U DOES emit sound over HDMI under amdgpu, verified with
  a stimulus the listener could not have guessed (three short 880 Hz beeps, pause, one 300→3000 Hz rising sweep,
  repeated twice, ~9 s) played to hw:0,7 and only then described. Twelve prior agnos burns had ASSUMED this. ⇒
  agnos's silence is agnos's bug.
- ⛔ `state: RUNNING` / advancing `hw_ptr` / advancing `AZ_LPIB` are NOT evidence of audibility — that class read
  green through twelve mute burns. LPIB advanced in EVERY silent burn: burn3 `0x2adc→0x2e60` · burn4 `0x3724→0x3aac`
  · ramp `0x79ac→0x7d34` · symclk-ab `0xd4b8→0xd83c` · acr-cts `0xefa0→0xf328`.
- ⛔ EXONERATED, FINAL, do not re-chase: the entire Azalia-endpoint / codec / HDA-link / DMA / converter /
  stream-tag-binding class, including `CONVERTER_FORMAT` (ix 0x02), `AUDIO_DESCRIPTOR0` (0x28), `SINK_INFO0` (0x3a),
  `MULTICHANNEL_MODE` (0x58), the un-issued verb `0x789`, and the whole `dce_aud_az_configure` gap — all upstream of
  tap 0, and tap 0 carries real samples.
- ⚠ Capture gotchas now encoded in the scripts: `ffmpeg -f lavfi -i sine` emits MONO and an HDMI pin REFUSES a
  1-channel stream (`cannot set channel count to 1`), so `-ac 2` is mandatory — this looks like a hardware finding
  and is not one. PipeWire is unusable on this box (WirePlumber claims no ALSA cards; no alsa-utils). `/proc/asound`
  is world-readable and `/dev/snd/pcmC0D7p` carries an ACL, so the codec half needs no sudo; the BAR5 half does. ELD
  and pin presence are DYNAMIC — they vanish when the panel sleeps, so a capture is only valid with the display
  awake.

## [1.55.14] — 2026-07-14 — the audio was aimed at a pin with nothing plugged into it
- Fixed: audio was aimed at endpoint 0 = codec pin `0x3` with `monitor_present 0`, while the live encoder is DIG1
  whose audio endpoint is **1**. All log criteria met; STILL SILENT.
- Added: the AVI InfoFrame was never transmitted either.
- Fixed a gate this cut had added, which would have eaten the burn.

## [1.55.13] — 2026-07-14 — the Audio InfoFrame was never transmitted

## [1.55.12] — 2026-07-14 — P3b-ii + P3b-iii: display audio, end to end
- The display-audio bite landed at **1,560,016 B — 16 B over** the 1.5M ceiling.
- Every silent-failure trap in the sequence verified against the headers.

## [1.55.11] — 2026-07-14 — P3b-i corrected: the MEASURED pixel clock IS the answer
- Measured on iron: 2560x1440 active, total 2720x1481, blanking 160x41; refresh **59951 mHz** with independent
  windows agreeing within **7–13 ppm**; pixel clock **241502–241503 kHz**, 11–13 ppm from the 241500 kHz step.
  `v_total` field reads 1480 (=1481), `h_total` field 2719 (=2720).
- Rejected: snapping to the 0.25 MHz clock step instead.

## [1.55.10] — 2026-07-14 — P3b-i: pixel-clock discovery
- `DPREFCLK = 598,875,000` (`0x23B21B78`), read at `DP_DTO0_MODULO` (BASE_IDX 1 dword `0x82` / abs dword 322). This
  read is the hardware anchor proving the DCCG BASE_IDX-1 base + offsets are right.
- The refresh is snapped, not the pixel clock. Read-and-refuse gates throughout.

## [1.55.9] — 2026-07-14 — P3a-2: Azalia window discriminator (D3 vs wrong-offset)
- The AZ endpoint INDEX write/readback sticks at `rcd=0x185600f0`, which anchors the AZ window base.

## [1.55.8] — 2026-07-14 — P3a: display-audio state probe (read-only) — DMCUB is NOT gating

## [1.55.7] — 2026-07-14 — Display arc cleanup + hardening pass

## [1.55.6] — 2026-07-14 — `blit`#39 double-buffered: tear-free full-screen apps, no app change

## [1.55.5] — 2026-07-14 — the double-buffered present loop, paced by the display's own clock

## [1.55.4] — 2026-07-14 — P2: vblank pacing (the present-loop primitive)
- Added `present`#84.

## [1.55.3] — 2026-07-14 — P1: the scanout flip (agnos's first DCN write)

## [1.55.2] — 2026-07-14 — P0 fix: the scanout address is BAR0-relative, not carveout-relative

## [1.55.1] — 2026-07-14 — P0 diagnostic: localize the DCN surface no-match

## [1.55.0] — 2026-07-14 — Kernel DISPLAY arc opens (Thrust P) + P0: read-only DCN 2.1 live-pipe probe
- Register bases, used by everything downstream: SEG1 (BASE_IDX 1) = `0xC0`, SEG2 (BASE_IDX 2) = `0x34C0`; byte
  address = (SEG + dword_offset) × 4. amdgpu ftrace prints BAR5-ABSOLUTE dword indices — subtract `0x34C0` for
  BASE_IDX 2 and `0xC0` for BASE_IDX 1 before looking a symbol up in `dcn_2_1_0_offset.h`. Worked examples: abs
  `0x556F` = `DIG0_DIG_BE_CNTL`, abs `0x566F` = `DIG1_DIG_BE_CNTL` (DIG back-end, NOT PHY).
- Platform: archaemenid = AMD Cezanne APU; GPU `1002:1638` at PCI `0000:04:00.0` (gfx90c / DCN 2.1, umr asic
  `green_sardine`), BAR5 size `0x80000`, 3072 MB VRAM. HDMI-audio is a SEPARATE PCI function `1002:1637` at
  `04:00.1`. Panel = Acer XB323U over HDMI.

## [1.54.33] — 2026-07-14 — GPU arc: `#82` pointer hardening + the f64 ring-3 seam (`#83`)
- Added **`#83 gpu_dispatch_f64`** — a userspace program hands the kernel two 8×8 f64 matrices and gets `C = A·B`
  (64 f64) back. This is attn11's path to the GPU from ring 3.

## [1.54.32] — 2026-07-13 — GPU arc f64 fidelity: rosnet-bit-correct matmul (the FMA-vs-mul+add proof)
- ⭐ The GPU f64 matmul is **bit-identical to rosnet's CPU math, including rounding** — both sides compute in the
  same k-ascending order, so a PASS proves bit-identity, not tolerance. This is the fidelity guarantee attn11 needs.
  `gpu: f64 matmul rosnet-bit-correct`.

## [1.54.31] — 2026-07-13 — GPU arc f64: full-precision matmul on the shader cores (attn11's path)
- `gpu: f64 matmul online (8x8, bit-correct vs CPU)` — f64 matmul running on the sovereign AMD GPU shader cores with
  no amdgpu and no ROCm.

## [1.54.30] — 2026-07-13 — GPU arc C2h: ring-3 GPU-compute dispatch (the userspace seam)
- Added **`#82`** integer matmul dispatch. Runs in ring 0 under the caller's CR3.

## [1.54.29] — 2026-07-13 — GPU arc C2g-4 (THE CROWN): integer tiled matmul on the shader cores
- `gpu: integer matmul online (8x8, bit-correct vs CPU)` on a sovereign AMD GPU — no amdgpu, no ROCm. `v_mul_lo_u32`
  + `v_add_u32` is two's-complement sign-transparent (`matmul_i32.s:62`).

## [1.54.28] — 2026-07-13 — GPU arc C2g-3: ALU + reduction loop (matmul's inner loop)
- `reduction-loop compute online (64 dot products)`.

## [1.54.27] — 2026-07-13 — GPU arc C2g-2 (compute kernargs) + GPU boot-log cleanup
- `kernarg compute online (64 operand reads)`.

## [1.54.26] — 2026-07-13 — GPU arc C2g-1 ROOT FIX: pre-dispatch shader I-cache invalidate

## [1.54.25] — 2026-07-13 — GPU arc C2g-1 diagnostic: width-vs-position + hang-vs-no-launch

## [1.54.24] — 2026-07-13 — GPU arc C2g-1: match mabda's HW-proven Cezanne compute preamble

## [1.54.23] — 2026-07-13 — GPU arc C2g-1: FORCE_SIMD_DIST (SIMD round-robin routing)
- ⛔ Burn 6 proved FORCE_SIMD_DIST had ZERO effect — the sweep pattern was bit-identical to burn 5.

## [1.54.22] — 2026-07-13 — GPU arc C2g-1 zero-wave fix (COMPUTE_START/RESTART) + wave-width sweep

## [1.54.21] — 2026-07-13 — `ktest.sh` boot-to-shell smoke harness repaired + kashi 1.0.3 pin

## [1.54.20] — 2026-07-13 — GPU arc C2g-1: multi-thread wave EXEC unmask + per-thread arithmetic
- `parallel compute online (64 threads)`.

## [1.54.19] — 2026-07-13 — GPU arc C2g-1 burn 2 isolation: v0-to-fixed-slot + fresh output slot

## [1.54.18] — 2026-07-13 — GPU arc C2g-1 burn 1 diagnostic: dump raw output values + changed-count

## [1.54.17] — 2026-07-13 — GPU arc C2g-1: first multi-thread compute dispatch (64 threads)

## [1.54.16] — 2026-07-13 — GPU arc C2f burn 2 fix: WPTR write order (LO before HI)

## [1.54.15] — 2026-07-13 — GPU arc C2f burn 1 diagnostic: read HQD state while GRBM-selected

## [1.54.14] — 2026-07-12 — GPU arc C2f: first hand-assembled gfx90c compute shader (DISPATCH_DIRECT)
- `compute shader executed`.

## [1.54.13] — 2026-07-12 — GPU arc C2e: WRITE_DATA fence + kernel-wide `kprint` log hygiene
- `GPU-to-CPU coherence verified` — the MEC executes and a CPU-visible write lands.

## [1.54.12] — 2026-07-12 — GPU arc C2d: first PM4 packet + doorbell (the VM-fetch gate)
- ⚠ The doorbell did NOT advance wptr on this iron; a direct `CP_HQD_PQ_WPTR_LO` write DID. `command ring active`.

## [1.54.11] — 2026-07-12 — log-capture fixes: console-write cap + relative-path creation

## [1.54.10] — 2026-07-12 — GPU arc C2c: map an empty compute queue + `klug` 64 KB log ring
- `compute queue ready (MEC1)`.

## [1.54.9] — 2026-07-12 — GPU arc C2b: GFXHUB GMC setup (FB-aperture compute, zero page tables)
- `no GART page tables` · `memory pipe disabled (enabling caches)` · `memory: UMA carveout via framebuffer aperture`
  · `memory controller ready (L2 on, idle)`.

## [1.54.8] — 2026-07-12 — GPU arc C2a: GMC/GFXHUB VM-state probe (compute dispatch opens)

## [1.54.7] — 2026-07-12 — GPU arc C1d: start the engines (Case-B → Case-A flip)
- `compute engines online`.

## [1.54.6] — 2026-07-12 — GPU arc C1c: the rest of the CP/MEC firmware set
- `CP/MEC firmware loaded (5/5, PSP-validated)`.

## [1.54.5] — 2026-07-12 — GPU arc C1b-2: LOAD_IP_FW RLC_G (the first real firmware into the GPU)
- `RLC firmware loaded (PSP-validated)`. The RLC compute microcode blob `renoir_rlc.bin` is **39,928 B** with a
  **16,896 B** payload.

## [1.54.4] — 2026-07-12 — GPU arc C1b-1 fix: the TMR must live in the VRAM carveout

## [1.54.3] — 2026-07-11 — GPU arc C1b-1: PSP SETUP_TMR (the first ring command / DMA round-trip)
- `PSP secure memory region ready`.

## [1.54.2] — 2026-07-11 — GPU arc C1a: PSP GPCOM ring-create (the first write to the GPU)

## [1.54.1] — 2026-07-11 — GPU arc C0: firmware-reality check (+ the F0 STRAP0/pass-gate iron fix)
- `firmware not resident, loading via PSP`. Size ceiling raised after the build crossed it at **1,401,104 B**.

## [1.54.0] — 2026-07-11 — Kernel GPU arc OPENS: F0 (GPU probe + register-aperture ID dump)
- Target: the archaemenid AMD Cezanne iGPU `04:00.0` `1002:1638` (gfx90c/GCN5 compute + DCN 2.1 display). Boot
  ladder, identical prefix in every later burn: `found 1002:1638 BAR5=0xfcb00000 UC` · `3072MB VRAM` · `register
  aperture mapped` · `console geometry matched to surface 800x600 pitch 3328 bytes`.

## [1.53.14] — 2026-07-10 — xHCI USB-HID keyboard: the AMD FCH `IMAN.IP` re-arm (1.53.x iron closeout)
- ⭐ Fixed: the interrupt-driven keyboard fired exactly ONE MSI-X then died. Per xHCI 1.2 §5.5.2.1 an MSI-X message
  fires on the IP 0→1 EDGE; init sets `IMAN=0x3` (`xhci.cyr:622`) and the ISR (`xhci_rx_handler`) EOI'd the LAPIC
  and updated ERDP.EHB inside `hid_poll` but never W1C-cleared `IMAN.IP`, so the second event found IP already 1 →
  no edge → no message → the `hlt`-blocked shell waited forever. Fix: `xhci_rt_write32(ir0 + XHCI_IR_IMAN, 0x3)` at
  the TOP of `hid_poll` after the slot-id guard, early so a mid-drain event re-sets IP and queues the next message.
  QEMU regenerates the message regardless; real AMD FCH enforces the edge. r8169's MSI (vector 0x50) on the SAME box
  was the analog that DOES clear its status — xHCI was the outlier.
- Iron-validated 2026-07-10 (ESP/kernel-only `--update`): keyboard works and is much snappier, FB rate much better
  (WB-shadow validated), `ls` / `ls -l` functioning.

## [1.53.13] — 2026-07-10 — ring-3 `readdir` syscall (`#81`)
- Added **`readdir`#81** — `ext2_readdir_sys(path, buf, max)`; a file manager lists the real filesystem. Pointer
  validation is the `uname`#34 norm (kernel addresses, wrap, above the 1 GB user ceiling all rejected).

## [1.53.12] — 2026-07-10 — USB-HID arrow / navigation keys reach ring-3 clients (E0-extended)

## [1.53.11] — 2026-07-10 — sovereign GPT/mkfs disk tool (`gptwr`): a disk AGNOS builds itself boots

## [1.53.10] — 2026-07-09 — raw block-device syscalls (`#75`-`#80`): the native-install primitive
- **`blk_enum`#75** `(buf,cap)->count` — list registered backends {tag, capacity, lba_bytes}.
- **`blk_open`#76** `(tag,mode)->handle` — RO (mode 0) always; RW (mode 1) only when armed.
- **`blk_read`#77** `(h,lba,buf,nsec)->nsec` — raw sector read, bounds-checked.
- **`blk_write`#78** `(h,lba,buf,nsec)->nsec` — raw sector write + device-cache flush.
- **`blk_info`#79** `(h,out)->0` — capacity_lbas + lba_bytes.
- **`blk_close`#80**.

## [1.53.9] — 2026-07-09 — on-device setu SHARED-BUFFER present composites end to end on agnos

⛔ **RETRACTED 2026-08-03 — the "end to end on agnos" half of this heading is a FALSE GREEN**, produced by the
`AETHERSAFHA_SETU_SELFTEST` kernel hook's `net_ip = 0x7F000001` assignment. Its only on-agnos evidence was
`aethersafha-setu-smoke.sh` gate 4, which passed solely because that assignment made src == dst == `127.0.0.1`
so `tcp_find_conn` matched. On an ordinary 1.53.9 boot the compositor↔client connect could not complete —
route-derived source selection (`net_src_for`) did not exist until **1.56.34**. The hook and that smoke are
deleted. ⚠ **This retracts the PROOF, not the kernel shm band below**: `shm_create`#71 / `shm_write`#72 /
`shm_read`#73 / `shm_free`#74 shipped, are unaffected, and stand — they need a different citation. See
`docs/development/planning/ipc.md` §10.

⛔ **RETIRED 2026-08-03 (a separate claim from the one above)** — TCP-on-loopback is no longer the desktop
transport, by operator ruling; the replacement is the agnos socket **`anu`** (`planning/ipc.md` §9). Lines in
this entry are marked with whichever applies: *false green* = the evidence was rigged; *retired* = the result
was real but the path is gone.

- Added the kernel shm band: **`shm_create`#71 / `shm_write`#72 / `shm_read`#73 / `shm_free`#74** — a 16-slot table
  over single 2 MB pmm pages, 1-based ids (0 reserved as the setu inline sentinel). The page's `pmm_kva_for_access`
  KVA lives in the kernel mirror so client write and compositor read reach it from their own syscall CR3 — a pure
  COPY, no cross-proc mapping, no lifetime hazard. (MAP-based sharing was abandoned: `proc_free_address_space` frees
  every arena page on proc exit, so a client exiting after presenting would free pages the compositor is still
  reading.)
- The two-proc unblock is entirely USERLAND-cooperative — no kernel logic changed. The four-part recipe: cooperative
  yield (producers non-blocking + `sched_yield`#44) · server-first (bind before the client connects) ·
  post-`sched_active` launch · sub-window TCP chunks (`sock_send`#48 blocks preempt-held above the ~2 KB loopback
  ring, so large frames go on shm).
  ⛔ **PART 4 RETRACTED 2026-08-03 — "sub-window TCP chunks" is FALSIFIED as a recipe step; do not follow it.**
  The measurement under it stands (`sock_send`#48 does block preempt-held above the ~2 KB `TCP_RX_RING`, which is
  why large frames went on shm) — but pixels leaving the wire for shm, and later PCM doing the same in a second
  subsystem, was the TRANSPORT being falsified, not a chunking technique worth keeping. **Parts 1-3 — cooperative
  yield · server-first · post-`sched_active` launch — STAND.** ⚠ The recipe was also only ever exercised against a
  listener on TCP loopback, a transport RETIRED 2026-08-03 in favour of `anu`; see `planning/ipc.md` §9-§10.
- Proof file exactly **245,760 B** (320×192×4); composited PPM had 2,032 green-border and 61,440 non-black pixels.
  ⚠ **QUALIFIED 2026-08-03 — this is the LINUX proof** (`setu_serve_probe` + `present_probe`, file backend). It is
  HONEST, it is unaffected by the selftest hook, and it STANDS. It is not, and never was, on-agnos evidence.

## [1.53.8] — 2026-07-09 — loopback TCP works with no NIC + the on-device setu scaffold
- Fixed: `tcp_send_pkt` dropped every loopback segment. Now gated on `nic_ready()==0 && net_is_loopback(dst)==0`.
  This is what enabled the two-proc setu handshake.
  ⛔ **RETRACTED 2026-08-03 — "This is what enabled the two-proc setu handshake" is a FALSE GREEN**, produced by
  the `AETHERSAFHA_SETU_SELFTEST` kernel hook's `net_ip = 0x7F000001` assignment. The only handshake **this change**
  completed was under that hook. On an ordinary boot every outbound SYN still claimed `net_ip` as its source, the
  SYN-ACK came back on a 4-tuple `tcp_find_conn` could not match, and `sock_connect #47` returned **-1 instantly**.
  An honest loopback connect first became possible at **1.56.34** (`net_src_for`, route-derived source selection) —
  and it **did** happen there: `aethersafha-clients-test.py` reached "connected: 2, presented: 2" un-rigged on
  2026-08-02 (QEMU `-smp 1`; never on iron).
  ⚠ The `tcp_send_pkt` loopback gate itself is a real fix and STANDS — only the enablement claim is withdrawn.
  ⚠ Separately: TCP-on-loopback as the DISPLAY transport is RETIRED 2026-08-03 in favour of `anu`
  (`planning/ipc.md` §9); see §10.
- The two-proc handshake blocker was root-caused via the QEMU monitor as a **console_lock preemption deadlock** (RIP
  spinning on a held lock, IF=0), fixed by flipping the proc READY after kmain's last `kprint` — NOT the stub `#DF`
  the earlier theory named.
  ⚠ **SCOPE-CORRECTED 2026-08-03 — not a retraction.** The console_lock root cause and its fix STAND: they were
  read off the QEMU monitor (RIP spinning on a held lock with IF=0), evidence independent of any selftest hook.
  What does not stand is the implied verdict that the setu handshake therefore worked — that verification came
  off the rigged `AETHERSAFHA_SETU_SELFTEST` smoke. Deadlock: genuinely fixed here. Handshake: not honestly
  demonstrated until 1.56.34.

## [1.53.7] — 2026-07-08 — console-perf closeout: interrupt-driven keyboard + FB RAM shadow buffer
- Added the interrupt-driven USB-HID keyboard (xHCI MSI-X vector `0x51`), the net-RX-IRQ analog.
- Changed: framebuffer console gains a WB RAM shadow buffer, killing the scroll WC read-back.

## [1.53.6] — 2026-07-08 — `readlink`#70: ring-3 symlink introspection
- Added **`readlink`#70** (4-arg). `symlink`#63 let a ring-3 program CREATE a link but never SEE one; `stat`#33
  follows. ABI taste: `readlink` chosen over an `lstat`/`AT_SYMLINK_NOFOLLOW` variant of `#33`. Every other FS
  syscall (open#7 / stat#33 / link#32 / rename / getdents) stays byte-identical.

## [1.53.5] — 2026-07-06 — HDMI-audio arc bites 1–3: multi-instance HDA + 2nd controller + HDMI route
- Bite 1: the HDA driver made instance-aware (behaviour-identical refactor) — default build **1,372,088 B** (+816 B
  from offset-indexing).
- Bite 2: probe + enumerate a second HDA controller as instance 1 — default build **1,373,208 B**; `hda-smoke` /
  `hda-tone` (RMS=5131.3) unchanged.
- Bite 3: HDMI/DP codec route + stream (digital branch; iron-gated).
- HDMI-audio hardware on archaemenid: controller `1002:1637` at `04:00.1`; codec `ATI R6xx HDMI`, Vendor Id
  `0x1002aa01`, Subsystem Id `0x00aa0100`, Revision Id `0x100700`. Node 0x04 [Audio Output] wcaps `0x221` Stereo
  Digital, device=7 name='HDMI 1'. Node 0x05 [Pin Complex] wcaps `0x400381`, Pincap `0x00000094` (OUT Detect HDMI),
  Pin Default `0x185600f0` (Jack Digital Out at Int HDMI), Pin-ctls `0x40` (OUT), Connection: 1 -> 0x04.

## [1.53.4] — 2026-07-06 — FP/SIMD arc B5+B6: two-proc XMM preservation + naad DSP in ring 3

## [1.53.3] — 2026-07-05 — FP/SIMD arc B4: real cyrius f64 runs in ring 3

## [1.53.2] — 2026-07-05 — FP/SIMD arc B3: lazy `#NM` per-proc FP context switch

## [1.53.1] — 2026-07-05 — FP/SIMD arc B2: per-proc FXSAVE state

## [1.53.0] — 2026-07-05 — FP/SIMD arc opens: SSE enabled per core (B1)
- Invariant: the production kernel stays FP-free (two sanctioned XMM leaf sites).

## [1.52.8] — 2026-07-04 — the LAPIC timebase was UNCALIBRATED (~12× slow on real Zen)
- ⭐ ROOT CAUSE of the audio glitches. The LAPIC timer was armed with a hardcoded reload count **10000000**, tuned to
  QEMU's ~1 GHz emulated LAPIC. On real Zen (Ryzen 7 5800H) the LAPIC input is ~12× lower, so 10M yielded **~8.3 Hz,
  not 100 Hz** — the whole system clock ran ~12× slow (a 6-hour soak showed ~30 min uptime), starving the 100 Hz
  `hda_stream_service` against the free-running 48 kHz DAC and making `sleep_ms` ~12× too long. QEMU never showed
  it.
- Fix: `lapic_calibrate()` measures the ÷1 LAPIC input against the still-running PIT channel-0 counter (a
  non-destructive latch read — touches neither port 0x61 nor ch2) over 8 ch0 periods; one ch0 period == 10 ms == one
  100 Hz tick, so LAPIC ticks per period IS the reload — no scaling multiply, no overflow. Falls back to the 10M
  literal on an implausible measure. New boot line `LAPIC: reload=` — **QEMU ~10,000,000 (measured 9,999,814, 0.002%
  off); real Zen ~830,000**. On iron this makes cyrius-doom audio clean and uptime real-time.
- Fixed: `snd_close#67` now silences the ring on close — it previously left the last-written PCM in the ring, so the
  free-running DMA looped the final sound forever after the producer exited.
- Added `/bin/tonegen` — a standalone ring-3 audio-PATH test (blocking, kernel-paced) that isolates the ring/DAC
  path from a producer's timing. It is what pinned the glitch to the timebase, not doom.

## [1.52.7] — 2026-07-04 — Gate 2: the ring-3 `snd_*` band `#64`-`#69`; first cyrius-doom sound
- Added **`snd_open`#64 / `snd_config`#65 / `snd_write`#66 / `snd_close`#67 / `snd_drain`#68 / `snd_avail`#69**.
  `snd_config` takes `fmt_packed = (channels<<16) | (bit_depth<<8) | alsa_fmt`; default 48k/2ch/S16_LE. `snd_write`
  takes `frames*4`; `a4` bit0 = NONBLOCK. Slots `0..3` (one active), auto-released on proc exit at both exit sites.
  Blocking calls use the `sock_connect`#47 sti-window with bounded deadlines.
- Lock-free by design: linear 64-bit counters (`snd_appl` producer head, `snd_hw_frames` consumer head) so
  full-vs-empty is wrap-unambiguous; the 100 Hz timer ISR is the sole writer of `snd_hw_frames`, the handlers the
  sole writer of `snd_appl` — disjoint atomic scalars.
- QEMU-validated: `open→0`, `config(48k/16/2)→0`, bad-rate / foreign-slot / double-open all `→−1`, `avail→14335`
  (the exact free count); a 375 Hz square through `snd_copy_frames` reaches the DAC at **RMS=7344**.
- ⭐ B7 — FIRST cyrius-doom SOUND ON AGNOS. Fixed: the PCM ring's CPU-access VA was a low identity VA absent from
  per-process CR3, so every `snd_*` call from ring 3 `#PF`'d (doom died with `run: exit 142` = 128 + `#PF`). The
  ring lands at `0x600000` (6 MB) and `pmm_kva_for_access` returns the IDENTITY VA for `phys < 256 MB`; low identity
  lives in each process's OWN `PDPT[0]` low PDs and is not in a ring-3 page table. Fix: cache the DIRECT-MAP alias
  `DIRECTMAP_BASE + phys` — mirrored into every CR3. The BDL still hands the controller `hda_pcm_phys`, so DMA is
  unchanged. `SND_SELFTEST` could never catch it: it drives the band from kernel context.
- Validated end-to-end in QEMU: `/bin/doom /DOOM1.WAD --audio-test` from disk in ring 3, all 8 test SFX play,
  capture **PEAK=24287, RMS≈2798** over ~2.1 MB.
- Toolchain pin → 6.4.2 (carries the `sys_snd_*` peer).

## [1.52.6] — 2026-07-03 — B5: streamed PCM double-buffer refill (closes Gate 1)
- `hda_stream_service` polled from the 100 Hz timer tick watches `SD_LPIB`; when the DMA crosses the BDL midpoint it
  refills the just-consumed 32 KB half. The ring is oversized ~17× (a half ≈ 170 ms vs the 10 ms tick), so a missed
  tick cannot underrun. Production/audio-idle boots pay one load+compare (`hda_stream_on=0` until a producer arms
  it).
- QEMU-PASS: sweep streaming, **RMS=5131**, wav frequency-progression gate shows **peak 1102 Hz** — only reachable
  if refill streamed PCM PAST the initial 64 KB fill (which alone tops out ~400 Hz).
- Pre-burn review caught a burn-blocker: the PCM ring was `vmm_remap_wc_2mb`'d, silently WC-ing the IDENTITY alias
  while refill writes go through the WB direct-map alias. The ring is now honestly WB/coherent like the BDL and
  CORB/RIRB — x86 PCIe DMA is cache-coherent, so no WC/sfence is needed.

## [1.52.5] — 2026-07-03 — ★ FIRST SOUND FROM SOVEREIGN AGNOS (iron-validated)
- The B4 375 Hz tone is AUDIBLE out the archaemenid front jack (Realtek ALC897, AMD Ryzen HD Audio `1022:15e3`).
  QEMU's trivial codec (RMS=5135) was necessary-not-sufficient.
- ⭐ THE FIX: jack-detect over config-default. Pin selection now weights the codec's live jack presence
  (`GET_PIN_SENSE` bit31) ABOVE every CONFIG_DEFAULT heuristic. This Beelink BIOS mislabels the physical front jack
  as pin `0x14` ("rear line-out") and tags the EMPTY `0x1b` as "front HP" — the codec reported the plug on `0x14`
  (`sense=1`) and nothing on `0x1b` (`sense=0`).
- Whole-path unmute through the summing mixer: a summing Audio-Mixer (widget type 2, e.g. `0x0c`) has no
  Connection-Select, so `GET_CONNSEL` is meaningless; the enable pass now unmutes EVERY mixer input index
  `0..connlen-1`, so the DAC-carrying input (power-on MUTED on Realtek) is lit whatever its index.
- EAPD broadcast to ALL output-capable pins (verb `0x70C`=2), not the single selected pin — powering the shared
  analog stage (EAPD latches on `0x14`).
- Realtek vendor COEF (index `0x07`, clear bit5 on nid `0x20`) confirmed correct and load-bearing (readback
  `coef7=0xf808`, bit5 clear).
- The decisive datum was the all-output-pins dump showing `sense=1` on `0x14`; the PCM-ring readback
  (`pcm[0]=0xd120`) retired the DMA-delivery hypothesis. Production build **1,350,744 B**.

## [1.52.4] — 2026-07-03 — B4: first tone (build-gated `HDA_TONE`)
- A ~375 Hz integer triangle, 128 frames/period × 128 whole periods in the 64 KB window (click-free BDL loop).
  Default (no-`HDA_TONE`) build is `cmp`-byte-identical to 1.52.3. QEMU-PASS **RMS=5135**.

## [1.52.3] — 2026-07-03 — B3: output stream + BDL DMA-arm
- Output stream descriptor at **`0x80 + ISS*0x20`** (ISS read from live GCAP, never hardcoded — 0x80 itself is SDI0,
  an INPUT descriptor, and arming it drives a capture stream). Sequence: SRST handshake → stream tag → CBL →
  **SDnFMT `0x0011`** → LVI → BDL base → RUN (tag preserved). Codec bound both sides (`SET_CONVERTER_FORMAT` = same
  `0x0011`, `SET_STREAMID` = `tag<<4`).
- ⛔ **SDnFMT `0x4011` is 44.1 kHz, not 48 kHz** — bit14 SET selects the 44.1 base; 48k/16/2ch is `0x0011`. A 48 kHz
  stream programmed `0x4011` plays ~8.1% flat (−1.47 semitones). QEMU's wav-RMS smoke MASKS it entirely (acoustic
  energy is rate-invariant and QEMU resamples silently).
- QEMU-PASS: `hda: stream sd=0x100 tag=1 fifos=256 lpib=196` + `stream running (LPIB advancing)`.
- Spec-verified against Intel HDA 1.0a, 5/5 CONFIRMED, 0 defects.

## [1.52.2] — 2026-07-03 — B2: CORB/RIRB verb ring + full codec graph walk
- 256-entry CORB + RIRB, WB/coherent, the CORBRP two-step reset, verb send/poll with **NO phase bit** (software rp
  vs RIRBWP, manual 256-wrap — RIRB has no phase bit, so the NVMe idiom does not transfer). QEMU-PASS `hda: codec0
  vendor=0x1af40022 nodes=1`.
- Fixed the consecutive-verb stall: QEMU's `intel_hda_corb_run` stops draining once `rirb_count == RINTCNT`, so
  `RINTCNT=1` processed one verb then stalled (`nodes=255`). Now `RINTCNT=0xFF` + a per-verb RIRBSTS ack (W1C
  RINTFL+overrun).
- B2b-1 widget enumeration + CONFIG_DEFAULT dump: `hda: afg 0x01 dacs=1 pins=2 outpins=1`, `hda: pin 0x03 cfg=0x4010
  dev=0 conn=0 loc=0x00`. B2b-2 pin select + DAC trace + output-enable.
- cyrius pin 6.3.9 → 6.3.43; `build/agnos` `cmp`-byte-identical (provenance only).

## [1.52.1] — 2026-07-03 — B1: HDA reset handshake + codec presence
- `GCTL=0` → poll bit0→0 → PLL settle (budget 200 µs) → CRST=1 → poll bit0→1 → codec-discovery settle (budget **1500
  µs**, ≥ the 521 µs / 25-frame §4.3 floor) → STATESTS re-read loop. Branches: `0` (timing suspect) vs `0x7FFF`
  (link down) vs a real mask. QEMU-PASS `codecs=0x0001`.
- Added `hda_write8/16/32` (with the `nvme_mmio_write32` readback flush) and `hda_udelay(us)`, an rdtsc-calibrated
  busy-spin (agnos has no `udelay`), `HDA_TSC_MHZ=3000`.

## [1.52.0] — 2026-07-03 — ✳ OPENS the audio-output (HDA/Azalia) arc; B0 controller probe
- Target: `04:00.6` AMD Ryzen HD Audio `[1022:15e3]` with a Realtek ALC897 codec `[0x10ec0897]`; output = the front
  headphone jack. NOT the ACP DSP (`04:00.5`) or HDMI audio (`04:00.1`).
- Probe order matches both targets: exact `pci_find(0x1022,0x15e3)` → `pci_find(0x8086,0x2668)` →
  `pci_find_by_class(0x04,0x03,0x00)` fallback. A bare class probe is deliberately NOT first because the same-class
  HDMI-audio function at `04:00.1` enumerates before the real controller at `04:00.6`. QEMU-PASS `hda: found
  8086:2668 OSS=4 ISS=4 v1.0`.
- The audio band was planned as `#63–#68` but `symlink`#63 took `#63` at 1.51.0, so it shifted to `#64–#69`.

## [1.51.9] — 2026-07-03 — `BOTE_SELFTEST`: MCP served on the real kernel (arc close)
- `/bin/bote` (cross-built `--agnos`) SERVES JSON-RPC MCP on the real agnos kernel — not just loads. Two kernel
  pipes, an MCP `initialize` + `tools/call bote_echo` preloaded into stdin, child fd0/fd1 pointed at the pipes, run
  to EOF. Exercises the freelist `mmap`#27 path (`libro chain_new → sha256 → fl_alloc`).

## [1.51.8] — 2026-07-02 — trim the busy-poll: `NET_BUSY_SPINS` 20000 → 512
- ~97% less CPU spin per wait. NOT removed, for two things the RX IRQ does not cover: loopback (`127.x` / self
  `net_ip`) rides the `net_lo_drain` SOFTWARE queue, which raises no interrupt — 512 is ~50× the 3–10 `net_poll()`s
  a lo phase needs, and `spins` resets per handshake and per send-chunk so 512 is per-phase; and it still catches a
  near-instant wire reply without the LAPIC→IDT→ISR round trip. Verified: loopback-smoke 5/5, connect bench 500/500
  through virtio.

## [1.51.7] — 2026-07-02 — the RX-IRQ-LIVE latch makes the 1.51.6 burn dispositive
- Neither "net works" nor `r8169: RX MSI armed` proves the MSI FIRED — the busy-poll and the 100 Hz tick drain both
  carry RX regardless, and QEMU cannot run the r8169 path. `nic_rx_handler` sets a single-word flag
  `nic_rx_irq_seen` on first delivery (a safe flag write, NO PRINT in interrupt context) and `net_poll` (non-ISR)
  prints exactly once.
- ⭐ IRON PASS 2026-07-02: `r8169: RX MSI LIVE (first hardware IRQ serviced, vector 0x50)` printed between `dhcp:
  DISCOVER` and `dhcp: OFFER 192.168.1.195` — the MSI serviced the DHCP OFFER's RX on hardware. Real lease `.195`,
  `net: L2 OK`, `yo google.com` 4/4 at 0% loss with three RTTs at sub-tick `0.00 ms`, no storm, no hang. Validated
  both 1.51.6 and 1.51.7 in one artifact.

## [1.51.6] — 2026-07-01 — r8169 RX interrupt (MSI) on IDT vector `0x50`
- Added `pci_enable_msi_vector(idx, vector)` — programs message address `0xFEE00000` (BSP LAPIC, physical/fixed) and
  message data = vector, MME=0; 32/64-bit-address aware (r8169 is 64-bit-capable → Data at cap+0x0C, Addr-Hi = 0 at
  cap+0x08).
- Added `r8169_irq_ack()` — W1C-acks the 16-bit `IntrStatus` (0x3E) by writing back the read snapshot.
  `nic_rx_handler` now ACKs THEN DRAINS, so a frame arriving after the ISR read re-latches RxOK and re-posts a fresh
  MSI (no lost frame).
- `r8169_init_tx` step 12 was pure-poll (`IMR = 0`); now drains stale `IntrStatus`, sets `IMR = RxOK|RxErr`
  (**`R8169_IMR_RXWAKE` = 0x0003**), and calls `pci_enable_msi_vector(pci_idx, 0x50)`. `RxDescUnavail` /
  `RxFIFOOver` are DELIBERATELY EXCLUDED — they do not self-clear on W1C until the drain relieves the condition, so
  masking them into an ack-before-drain edge handler would STORM on exactly the burst-overflow case; overflow
  recovery stays with the timer-tick drain.
- QEMU no-regression: connect bench 2000/2000 at ~1.21 ms/connect.

## [1.51.5] — 2026-07-01 — virtio-net RX interrupt (MSI-X), IDT vector `0x50`
- The NIC now raises vector `0x50` on packet arrival, so a blocked `hlt` wakes on arrival instead of the next 100 Hz
  tick. First interrupt-driven device beyond timer/keyboard.
- `nic_rx_handler` + `nic_rx_isr_build` (`pic.cyr`): RX-only, self-guarded, never schedules, LAPIC-EOI — safe in the
  preempt-held connect/recv window. `vnet_msix_enable_rx` programs MSI-X table entry 0 (BSP LAPIC, vector 0x50,
  per-vector unmasked), clears FuncMask, routes RX queue 0.
- BENCH with the busy-poll DISABLED (so only the IRQ can wake `hlt`): **2000/2000 connects at ~1.2 ms/connect** —
  matching the busy-poll number with no CPU spin. loopback-smoke 5/5.

## [1.51.4] — 2026-07-01 — per-connect ephemeral source port (rapid-reconnect failures)
- `sock_connect`#47 derived the ephemeral port from `timer_ticks` (`49152 + (timer_ticks & 0x3FFF)`), which only
  changes every 10 ms, so multiple sub-ms connects in one tick got the SAME port → the 4-tuple was still in the
  peer's TIME_WAIT → SYN dropped → 8 s timeout. Now from a per-connect counter `tcp_ephemeral_ctr` seeded by
  `timer_ticks`; `(ctr + timer_ticks)` is strictly increasing, no collision until the 14-bit range wraps (16384
  connects).
- BENCH: `N=2000 ok=2000`, avg **≈1.13 ms/connect** (was `ok=5/10`, ~4 s avg). Linux native on the same path is ~38
  µs; the ~30× gap is QEMU SLIRP, not the agnos stack.

## [1.51.3] — 2026-07-01 — TCP connect/send latency floor removed (busy-poll before `hlt`)
- The wait loops polled `net_poll(); arch_wait()` and `arch_wait()` is `hlt`; with no NIC RX interrupt, `hlt` only
  woke on the timer, flooring every TCP round trip at ~one 10 ms tick. Now `NET_BUSY_SPINS` (20000) `net_poll()`s
  before falling back to `hlt`. New `net_wait_backoff`.
- Added `BASESTACK_SELFTEST` + `scripts/basestack-run-smoke.sh` — the "runs, not just builds" gate. Proved hoosh (a
  14.9 MB ELF) loads, runs, prints its version and exits cleanly on agnos.

## [1.51.2] — 2026-06-30 — cyrius pin 6.2.44 → 6.3.9 + ark v2 M3 proven on agnos
- The freestanding kernel is `cmp`-byte-identical across pins (`build/agnos` stays **1,359,960 B**), so this is
  provenance only — but `symlink`#63 (1.51.0) created a HARD FLOOR: its userland peer `sys_symlink` exists only in
  cyrius ≥ 6.3.6.
- `ARK_INSTALL_SELFTEST`: `ark install --root /arkroot /symlink-test.ark` on the real kernel.

## [1.51.1] — 2026-06-30 — large-binary exec UNBLOCKED (kstack VA collision) + symlink round-trip
- The 15.9 MB ark triple-faulted during exec/load (`#PF` ring 0 at `SP−8` = `0xF10000` → `#DF` → triple fault). Root
  cause was NOT binary size — a kstack VA-space collision.
- `symlink`#63 complete two-sided (cyrius peer landed 6.3.6); new `scripts/symlink-smoke.sh`.

## [1.51.0] — 2026-06-29 — ✳ OPENS the sovereign-package-manager kernel surface; `symlink`#63
- **`symlink`#63** `(target, targetlen, linkpath, linkpathlen=a4)` — creates a link whose contents are the TEXT
  `target`, not a path to resolve. ⚠ TWO-SIDED: ring 3 cannot call it until cyrius adds `sys_symlink`#63 (landed
  6.3.6).
- Remaining arc items filed, not started: (b) atomic system-update / boot-slot primitive; (c) nested/recursive exec
  from a spawned proc — `execwait`#37 REFUSES re-entry (`syscall.cyr:1271-1277`, `pcpu_ew37_busy_get()!=0` returns
  −1).

## [1.50.10] — 2026-06-29 — hardening pass over the 1.50.9 fix
- Added an ALWAYS-ON `bitmap-dm` guard: on every boot with RAM > 256 MB, assert `pmm_bitmap_ptr >= DIRECTMAP_BASE` —
  the bitmap is reached via the direct-map, not its per-proc-shadowed identity VA. In a `BOOTCR3_KEEP_GNOBOOT_CR3`
  build the rebase is gated off and the config now warns loudly.
- Sibling audit: the bitmap was the UNIQUE victim of the per-proc-CR3 identity-VA shadow — the only PDE override
  inside `PD[0..127]` is `PD[2]` (ring-3 code at `0x400000`). Validation: `pmm: bitmap-dm OK free2mb=228`.

## [1.50.9] — 2026-06-29 — agnsh `&` background jobs restored (two independent bugs)
- Fixed: `pmm_migrate_bitmap` (RAM > 256 MB) allocated the RAM-backed bitmap from the ≤256 MB pool (`pmm_alloc_2mb`
  returned phys `0x400000`) and pointed at its identity VA, which the ring-3 code VA shadows — so `sys_mmap` saw 0
  free 2 MB regions and agnsh `#PF`'d right after its banner.
- Fixed: `proc_reap_off_cpu_fence` deadlocked reaping a proc that terminated via `kernel_resume` (the box HANG) —
  the SMP fence spins until `on_cpu[pid] == -1`, which a foreground fault/exit path never reaches.

## [1.50.8] — 2026-06-29 — `waitpid`#4 ownership gate
- `waitpid(pid)`#4 had NO ownership check — any proc could reap any dead proc, stealing its exit code and collapsing
  the slot out from under the real parent. Gate = `proc_may_reap`.

## [1.50.7] — 2026-06-29 — bg-job fault teardown + a real `proc_get_ppid`
- `proc_get_ppid` was a stub returning 0 always, leaving `kill`#16's "a non-init proc may signal only itself or its
  children" gate INERT. Added a flat `proc_ppid[16]` (parallel to `proc_cs[16]` / `proc_ss[16]`), filled at
  `proc_create_user` from the creator pid, reset in `proc_alloc_slot`, with the gate extracted into
  `proc_may_signal(caller,target)`.
- A background (`&`) proc's `#PF`/`#GP`/`#UD` previously fell through to the IDT stub and HALTED THE BOX; it now
  `sti;hlt`-yields so the next tick switches to the next ready proc.

## [1.50.6] — 2026-06-29 — PF_X-aware ELF mapping + NX user stack (W^X)
- Both loaders read each `PT_LOAD`'s `p_flags` (offset 4) and map executable only when `PF_X`.
- ⚠ Honest scope: segment-level W^X is blocked by the ELF format, not the kernel — cyrius/cyrld emits ONE `RWE`
  `PT_LOAD` per binary (code + data + bss packed), confirmed on agnsh/kriya/owl. The live win is the NX user stack
  at `0x3FC00000`.

## [1.50.5] — 2026-06-29 — W^X: NX on anonymous mmap-arena pages
- Arena PDEs mapped non-executable (bit 63; `0x8000000000000087`). Every arena-PDE physical-address extraction
  switched to the bit-63-safe mask `0x000FFFFFFFE00000`.

## [1.50.4] — 2026-06-29 — per-process high-arena cursor
- `himmap_next_vaddr` (global) → `proc_himmap_next[16]` indexed by pid; 0 = uninit → 128 GB.

## [1.50.3] — 2026-06-29 — high-range `munmap`
- `sys_munmap` now handles `[128 GB, 512 GB)`. The low arena shares one 0–1 GB PD (a single walk); each high page
  may sit in a different per-proc PDPT entry.

## [1.50.2] — 2026-06-29 — the user mmap-arena full lift (many GB per process)
- Added `proc_map_page_hi(cr3, virt, phys)` for VA ≥ 128 GB. High arena = `[0x2000000000 (128 GB), 512 GB)` in 2 MB
  pages via per-process `PDPT[128..511]`. `PDPT[0..3]` = 0–4 GB kernel identity + the 0–1 GB PD + device BARs +
  framebuffer; `PDPT[8..71]` = the direct-map (`DIRECTMAP_BASE` = 8 GB + phys; the bitmap caps RAM at 64 GB).
  `PDPT[128..511]` being kernel-zero is load-bearing: a present entry there is unambiguously a per-process arena PD.
  Single sanity cap: length ≤ 64 GB.
- Validated end to end: **1.026 GB contiguous (513 × 2 MB)** spanning `PDPT[128]` and `[129]`, free-count drops by
  513 and teardown restores it fully — `mmap-himem-e2e: >1GB map+free PASS` at `qemu -m 4G`; `check.sh` 11/11; 8G
  boot-to-prompt unaffected.

## [1.50.1] — 2026-06-29 — boot-CR3 → own-PML4 switch promoted to DEFAULT-ON (iron-validated)
- Gate inverted from opt-in `#ifdef BOOTCR3_OWN_PML4` to opt-out `#ifndef BOOTCR3_KEEP_GNOBOOT_CR3`.

## [1.50.0] — 2026-06-28 — ✳ RAM full-usage continuation arc opens
- Added the full-RAM stress selftest (up to 16384 2 MB regions ≤32 GB, per-region sentinels through the direct-map),
  the boot-CR3 → own complete PML4 switch (`0x1000`, built by `pt_init`, carrying the direct-map from
  `pmm_setup_directmap`), and the PDPT-guard selftest (forces the shared-1 GB-PDPT cache-type collision that iron FB
  + device BARs hit but QEMU cannot).
- Fixed: `vmm_remap_uc_2mb` was missing the idempotency guard its WC twin has, so re-shattering a shared PDPT entry
  clobbered sibling chunks to WB (FB freeze on iron under the boot-CR3 switch).
- Fixed: PMM bitmap migration left memmap GAPS free above 256 MB, so `pmm_alloc_2mb` handed out unbacked regions
  (latent memory corruption) — 1.49.11 reserved non-conventional memmap ENTRIES but not GAPS.

## [1.49.12] — 2026-06-28 — three raw-physical-address sites `#PF`-halted above 256 MB
- 1.49.9 introduced `pmm_kva_for_access` (identity ≤256 MB / direct-map above); `sys_mmap` and `elf_load` still held
  raw physical addresses and halted the 64 GB iron burn at agnsh launch.
- Fixed the stale `munmap: pmm-reuse` selftest (its out-of-range guard freed `pmm_free_2mb(0x1000000)` = 16 MB
  expecting a rejection, but the pool grew from 16 MB to full RAM).

## [1.49.11] — 2026-06-28 — dynamic RAM-backed PMM bitmap
## [1.49.10] — 2026-06-28 — the >256 MB direct-map WORKS; 1.49.9's "cyrius high-VA limit" was a misdiagnosis
- The blocker was a false-positive boot probe running under the wrong page tables. Cyrius exonerated.

## [1.49.9] — 2026-06-28 — full-RAM bite 3b (held at 256 MB with the groundwork in place)
## [1.49.8] — 2026-06-28 — full-RAM bite 3a: user pages reach the full 256 MB
## [1.49.7] — 2026-06-28 — full-RAM bite 2: the kernel direct-map (past the 256 MB identity ceiling)
## [1.49.6] — 2026-06-28 — full-RAM bite 1: 128 → 256 MB
## [1.49.5] — 2026-06-28 — socket-as-VFS-fd bite 2: `VFS_SOCK` fds are epoll-ready (gap 3 COMPLETE)
## [1.49.4] — 2026-06-27 — socket-as-VFS-fd bite 1: accepted TCP connections are now fds
- `sock_accept`#57 now returns an epoll-able `VFS_SOCK` fd instead of a raw conn_id; `read`#5 / `write` / `close`#6
  dispatch uniformly to the TCP layer.

## [1.49.3] — 2026-06-27 — full RAM init bite 3: PMM extension for PIE/KASLR kernels
## [1.49.2] — 2026-06-27 — full RAM init bite 2: open the 4 KB allocator to discovered RAM (non-PIE)
## [1.49.1] — 2026-06-27 — full RAM initialization bite 1: UEFI memory-map discovery
## [1.49.0] — 2026-06-27 — ✳ opens the kernel-capability-gaps arc
- `pmm_init` had hardcoded `pmm_total=32768`.

## [1.48.2] — 2026-06-27 — FAT/exFAT multi-cluster READ coalescing (closes the other-FS perf set)
## [1.48.1] — 2026-06-27 — FAT/exFAT cluster-WRITE amplification collapse
## [1.48.0] — 2026-06-27 — ✳ other-FS perf review opens: FAT/exFAT cluster-read amplification collapse
- FAT16/FAT32 + exFAT read PER-SECTOR — the same amplification ext2 had pre-1.42.8.

## [1.47.8] — 2026-06-27 — perf: scheduler single-pass round-robin
## [1.47.7] — 2026-06-27 — perf: ext2 multi-block WRITE coalescing
## [1.47.6] — 2026-06-27 — perf: ext2 multi-block READ coalescing
## [1.47.5] — 2026-06-27 — perf: ext2 single-indirect read reuse
## [1.47.4] — 2026-06-27 — full-binary KASLR (Option A): the kernel binary's load base is randomized
- Closes the last ~20% of KASLR value beyond the data-only scope shipped at 1.28.0 — ROP/JOP gadgets can no longer
  be pre-computed against a fixed kernel binary. Pairs with gnoboot 0.6.0.

## [1.47.3] — 2026-06-27 — full-binary KASLR foundation (the PIE kernel boots at a fixed base)
## [1.47.2] — 2026-06-27 — perf: ext2 directory-lookup inode reuse
## [1.47.1] — 2026-06-27 — perf: ext2 block-write batching
## [1.47.0] — 2026-06-27 — fault resilience + per-process fd tables
- proc-teardown-on-fault: a ring-3 (CPL3) fault kills the proc and returns to the agnsh prompt instead of halting
  the box.
- Per-process fd tables (2a seam → 2b storage+inheritance → 2c pipe refcount) replace the single global `vfs_table`.

## [1.46.11] — 2026-06-27 — SMP arc closeout fix
## [1.46.10] — 2026-06-26 — SMP arc closeout change
## [1.46.9] — 2026-06-26 — `input_lock`: the `kb_buf` SMP/ISR serialization lock
- `kb_buf` is a ring with MULTIPLE producers advancing `kb_head` — `kb_isr` (the IRQ1 PS/2 hand-asm ISR) and
  `hid_kb_poll`.

## [1.46.8] — 2026-06-26 — SMP STEP-2 pre-burn review fixes
- A second independent review (6 dimension reviewers + refute-by-default verification) raised **6 findings — all 6
  confirmed, 0 refuted, 0 burn-blockers** (5 distinct: #1==#4). Each is a real SMP-correctness gap the
  `smp_sched_aps=1` flip makes reachable.

## [1.46.6] — 2026-06-26 — SMP STEP-2 part 1: the flip + double-run hardening (clean `-smp 4` boot)
- Flips `smp_sched_aps=1` so woken APs pull real ring-3 procs from `sched_next`. A 6-lens adversarial review (16
  agents) + a QEMU `-smp 4 -d int` repro (single-core = 0 exceptions; `-smp 4` reproduced torn frames + `#UD`/`#DF`)
  surfaced **5 concurrency bugs**.

## [1.46.5] — 2026-06-26 — ★ IF=1 PREEMPTIVE AGNSH ON IRON: the SYSRET SS-RPL bug, fixed in ONE BYTE
- The `#GP` that froze every IF=1-preemptive `agnsh` boot on real Zen since 1.44.14 — the single blocker gating both
  preemptive agnsh and SMP STEP-2 — is root-caused and fixed: `syscall_msr_init` programmed `STAR[63:48] = 0x10`
  (the user CS/SS base). One byte in `kernel/arch/x86_64/syscall_hw.cyr`. archaemenid now boots `exec_preempt=1` to
  a preemptible `[ASSIST] >` prompt.

## [1.46.4] — 2026-06-25 — ★ WORKING COREUTILS: the boot-to-shell `ls`/argv `#PF` fixed
- The 1.46.3 burn reached the shell but the first external-tool exec (`ls`→`kriya`) took a `#PF` (`CR2=0`, CPL3
  read). One-line kernel fix (`pmm.cyr` reserves region 8) for an empty-argv regression introduced by the 1.46.1
  region-7 kstack reservation. Root-caused and validated burn-free in QEMU.

## [1.46.3] — 2026-06-25 — ★ BOOT-TO-SHELL ON IRON
- IF=0 cooperative agnsh (`exec_preempt=0`) reached an interactive shell on real Zen (burn `1461`): past a live DHCP
  lease, kybernet execs `/bin/agnsh`, **agnsh 1.7.0 reaches its `[ASSIST] >` prompt and runs `help` + `version`** —
  with SMP wake left ON (`smp_wake_enabled=1`, STEP-1 `cpus online: 4`).
- Added `sched_fix_live_frame` (`sched.cyr`), the last statement of `do_context_switch` (the GPR pops touch only
  `isr_rsp+0..+112`, so `+128`/`+152` are exactly what the `iretq` consumes).

## [1.46.2] — 2026-06-25 — SMP sub-bite-7 STEP-1: the IF=1 first-preempt `#GP` root-caused
- The 1.46.1 re-burn halted right after the agnsh banner with `#GP` errcode `0x18` (selector idx 3 = user-mode).

## [1.46.1] — 2026-06-25 — SMP sub-bite-7 STEP-1 `#GP` fixed + QEMU-validated burn-free
- The 1.46.0 STEP-1 burn (`smp_wake_enabled=1`, `smp_sched_aps=0`) woke all 4 CPUs (`cpus online: 4`) but agnsh took
  a `#GP` right after its banner (blue FB fault-canary bar, CMOS `0x54=0x0D`). Three real STEP-1 bugs found and
  fixed, all reproduced in QEMU. Builds 1,221,072 B / 1,220,272 B; production (`smp_wake_enabled=0`) **1,220,416
  B**.

## [1.46.0] — 2026-06-24 — ★ the SMP locking foundation
- Per-CPU scheduler identity (`pcpu_*`, APIC-indexed) + the per-CPU SYSCALL stub (per-CPU kernel stack, user-RSP
  save, KPTI CR3 pair, `#44` capture block, `#37` guard — adversarially designed, reviewed and objdump-verified) +
  the subsystem lock set (xchg spinlocks: heap / pmm / vfs / proctab / fs / nvme / ahci / console).
- `net_rx_drain` is the single consumer of the one shared r8169 RX ring and was guarded by the NON-ATOMIC
  `net_poll_busy` flag; replaced with `net_rx_lock`, an ATOMIC `xchg` TRY-lock (`net_rx_trylock` returns 0 =
  acquired / 1 = busy → skip): non-blocking, therefore ISR-safe and re-entry-proof without cli/sti — a spinlock
  there would SELF-DEADLOCK. LEAF lock. ⚠ DEFERRED RESIDUAL: the TX/conn-side mutators
  (`nic_send`/`tcp_send`/`tcp_connect` touching `tcp_conns`/`arp_cache`) are NOT yet cross-CPU locked.
- Build ladder across the sub-bites: 1,210,368 → 1,211,424 → 1,212,336 → 1,212,736 → 1,213,024 → 1,211,472 →
  1,215,232 → 1,215,408 → 1,215,584 → 1,218,464 → 1,218,576 → 1,211,392 B.

## [1.45.17] — 2026-06-23 — the RX ring is drained EVERY TICK, not only while a tool polls
- The same ring-overflow class recurred at a different layer (1.45.16 iron burn): `yo google.com` → 2/4, **50%
  packet loss**; `dig` → "no servers could be reached"; `whirl https://google.com` → connection failed. The RX ring
  was serviced ONLY while a ring-3 tool sat in its own `net_poll()` loop; during `sleep_ms` pacing, between commands
  and at the idle prompt the 64-deep ring went unserviced and LAN chatter overran it. INVISIBLE IN QEMU because
  SLIRP is point-to-point.
- Fix: the 100 Hz `timer_handler` calls a new `net_rx_drain()` EVERY TICK. `net_poll()` keeps its exact prior
  contract (TX retransmits + RX drain); `net_rx_drain()` is the RX-ONLY inner loop, so the ISR issues NO TX from
  interrupt context. A `net_poll_busy` re-entrancy guard makes a tick landing mid-drain a no-op. Drains BEFORE
  `do_context_switch` and is `nic_ready()`-gated.

## [1.45.16] — 2026-06-23 — `net_config`#61
- **`net_config(field)`#61** — non-blocking, buffer-less getter returning a kernel network-config datum in `rax`:
  field 0 = `net_ip`, 1 = `net_netmask`, 2 = `net_gateway`, 3 = `net_dns_server`. Same shape as `uptime_ms`#40 /
  `winsize`#60.

## [1.45.15] — 2026-06-23 — `exec_redirect`#62: fd-redirect for output capture
- Production `build/agnos` **1,207,096 B**.

## [1.45.14] — 2026-06-22 — toolchain: kernel binary byte-identical at 1,204,416 B
## [1.45.13] — 2026-06-20 — `flock`#59 (release-by-pid)
- `flock(fd, op)` with SH=1 / EX=2 / UN=8 / NB=4, backed by `flock_inode/pid/mode[16]` keyed by inode. EX exclusive,
  SH coexist, EX-vs-SH conflict returns −1 (WOULD_BLOCK; ring 3 poll-spins). Released in `vfs_close`#6 AND on proc
  exit via `flock_release_pid`. Binary **1,203,984 B**; size-sanity ceiling bumped 1.2M → 1.4M.

## [1.45.12] — 2026-06-20 — `lseek`#58
- `lseek(fd, offset, whence)` SET/CUR/END sets payload[0]; `VFS_EXT2_FILE` already carried pos at payload[0] and
  size at payload[1]. `#ifdef`-gated → production byte-identical (**1,200,544 B**). Kernel built with 6.2.7 vs
  6.2.30 is `cmp`-byte-identical (1,200,544 B both).

## [1.45.11] — 2026-06-19 — TCP server slot-leak fix + persistent HTTP listen-smoke
- The first founder Docker net-sweep of the kernel TCP server surfaced a real concurrency bug burn-free. The
  rewritten listen-smoke is a persistent HTTP server, so a burn can `curl http://<ip>:8080` for as long as the box
  is up (no 8-second window).

## [1.45.10] — 2026-06-15 — pin → 6.2.7 + the stdlib-completeness missing-syscalls map
- Byte-identical agnos kernel, **1,199,984 B** under both pins — extends the proven `6.0.56 ≡ 6.2.2 ≡ 6.2.5 ≡ 6.2.6
  ≡ 6.2.7` chain. No kernel-source change.

## [1.45.9] — 2026-06-14 — pin 6.2.5 → 6.2.6 (chrono agnos monotonic/sleep fix)
- chrono's agnos `clock_now_*`/`sleep_ms` now bind to the real `uptime_ms`#40 / `sleep_ms`#41.

## [1.45.8] — 2026-06-14 — pin 6.2.2 → 6.2.5 (byte-identical, 1,199,976 B)
## [1.45.7] — 2026-06-14 — pin 6.0.56 → 6.2.2 (byte-identical, 1,199,976 B)
- The iron-validated 6.0.56 artifact IS the 6.2.2 artifact bit for bit — zero re-validation cost.

## [1.45.6] — 2026-06-14 — net-syscall hardening / security sweep (`#45`-`#57`)
- 6-lens multi-agent review (memory-safety / arg-validation / resource-DoS / sti-window / entropy-crypto /
  lifecycle), each finding adversarially verified. **4 real fixes** landed. `build/agnos` **1,199,976 B** (+864 over
  1.45.5); `check.sh` 11/11; tcp 4/4.

## [1.45.5] — 2026-06-14 — Phase-B server sockets: AGNOS can ACCEPT (`#56`/`#57`)
- **`sock_listen(port)`#56** — bind + listen on a local TCP port → listen_id (0..7) in `rax`, or −1 (port already
  bound / conn table full). AGNOS MERGES bind+listen, so BSD `bind()+listen()` both fold onto this one call.
  Non-blocking.
- **`sock_accept(listen_id)`#57** — NON-BLOCKING accept → the conn_id (0..7) of the next ESTABLISHED inbound
  connection, or −1 (none pending = WOULD_BLOCK / bad listen_id / not a LISTEN slot). The handler `net_poll()`s
  FIRST so the passive-open handshake progresses. IF=0-safe, no sti window.
- `tcp_listen` slot allocation moved onto the 1.45.2 reclaim helper. `build/agnos` **1,199,112 B**;
  `tcp-listen-smoke` 2/2.

## [1.45.4] — 2026-06-14 — `icmp_ping`#55 (the `yo`/ping prerequisite)
- `build/agnos` **1,198,792 B** (+176).

## [1.45.3] — 2026-06-14 — UDP-53 ring-3 syscalls `#51`-`#54` (the `dig`/DNS prerequisite)
- **`udp_bind(port)`#51** → listener_id (0..7) or −1. The listener captures the most-recent inbound datagram for
  that port in a kernel mailbox.
- **`udp_send(dst_ip, ports, buf, len)`#52** — the two 16-bit ports are PACKED into one arg (`src_port =
  (arg2>>16)&0xFFFF`, `dst_port = arg2&0xFFFF`) because the 4-arg `ksyscall` ABI cannot pass five separates and
  `dst_ip` needs a full 32 bits; `len` rides `ksyscall_a4`.
- **`udp_recv(listener_id, buf, maxlen, addr_out)`#53** — NON-BLOCKING → byte count (0 = none yet / WOULD_BLOCK) or
  −1. `addr_out` (via `ksyscall_a4`), if non-zero, is a 16-byte user region receiving peer `src_ip`@+0 /
  `src_port`@+8.
- **`udp_unbind(listener_id)`#54** — free the recv buffer + mark the slot reclaimable; idempotent.
- All four non-blocking, no sti window. `build/agnos` **1,198,616 B** (+2,000).

## [1.45.2] — 2026-06-14 — socket review fixes: conn-slot reclaim + `sock_recv` bounds
- `build/agnos` **1,196,616 B** (+208).

## [1.45.1] — 2026-06-14 — the client TCP socket surface `#47`-`#50`
- **`sock_connect(dst_ip, dst_port, src_port)`#47** → conn_id (0..7) or −1 (table full / SYN-ACK timeout ~8 s /
  RST). `dst_ip` is the packed `(o1<<24)|(o2<<16)|(o3<<8)|o4` form; `dst_port` must be 1..65535; `src_port<=0`
  auto-assigns an ephemeral port. `tcp_connect` BLOCKS, so the handler wraps it in the `sleep_ms`#41 window:
  `preempt_disable()` (sched suspended → the timer ISR ticks and EOIs but never context-switches mid-handshake,
  preserving the serial-kstack invariant) + `sti` (IF=1 so `timer_ticks` advances and the `hlt` wakes) + `cli` +
  `preempt_enable()`.
- **`sock_send(conn_id, buf, len)`#48** → bytes accepted (`<len` if the conn drops) or −1. Same IF=1 preempt-held
  window; `is_user_range` validated BEFORE the window.
- **`sock_recv(conn_id, buf, maxlen)`#49** — NON-BLOCKING → count, **0 = nothing yet / WOULD_BLOCK**, **−1 = bad
  user range OR peer fully closed (EOF)**. ⚠ This 0/−1 split is INVERTED from Linux's `EAGAIN = −11`. Backed by the
  new `tcp_conn_dead(conn_id)` helper. Safe IF=0, no sti window.
- **`sock_close(conn_id)`#50** — FIN+ACK if ESTABLISHED, frees per-conn RX/retx buffers. Non-blocking.
- ⚠ While a `#47`/`#48` window is open, preemption is held, so no other proc is scheduled for the call's duration
  (≤8 s ceiling per segment). The 8 global conn slots are not per-process-owned. `build/agnos` **1,196,408 B**
  (+1,528); unreachable-fn count 119 → 116.

## [1.45.0] — 2026-06-14 — ✳ 1.45.x TLS arc OPEN: entropy + wall-clock (`#45`/`#46`)
- `getrandom`#45 and `time_unix`#46. `build/agnos` **1,194,880 B** (+816 over 1.44.26).

## [1.44.26] — 2026-06-14 — strip the kbd-read diagnostic FB markers
## [1.44.25] — 2026-06-14 — production cut: warm-reboot DHCP fix + xHCI keyboard-ring fix
- ⭐ THE KEYBOARD-DEATH ROOT CAUSE: the keyboard transfer ring was armed only **1 TRB deep**; during the IF=0
  command-execution gap it empties, the controller stalls the interrupt-IN endpoint on the empty ring, and a bare
  re-arm plus doorbell does NOT restart a stalled interrupt EP on real xHCI. Endpoint-specific — MSC storage on the
  SAME shared event ring kept working throughout. Fix: `hid_kbd_configure` arms the ring **16 deep**, `hid_poll`
  tops up, plus a read-entry `hid_kbd_kick()` doorbell restart. QEMU cannot model the stall.
- Plain `scripts/build.sh` kernel — boots straight to the agnsh prompt and auto-runs nothing. `build/agnos`
  **1,194,296 B**.
- ⛔ `pic_mask_pit()` (burn-3's fix) is REFUTED three ways and is a NO-OP, not the fix: it predicts a permanent wedge
  but `ls` survived; it would kill `help` mid-line; and legacy i8042 emulation is already torn down by the xHCI
  claim. It stays in the code as harmless.
- ⛔ The 1.44.18 SMP-AP wake is FALSIFIED as the cause (burn 4, 2026-06-13): the boot FB read `smp: AP wake gated
  (MVP single-core)` on a HEAD build and the shell still died after one command.

## [1.44.24] — 2026-06-13 — mask the legacy PIT once the LAPIC timer owns the timebase
## [1.44.23] — 2026-06-12 — BSP TSS.RSP0 relocated out of live kernel `.bss`
- Production build **1,193,424 B** — size-identical to 1.44.22 (same immediate encoding).

## [1.44.22] — 2026-06-11 — arc-closing sweep batch 2 of 2 (comment-only)
- Binary byte-identical to 1.44.21 (**1,193,424 B**) modulo the version banner.

## [1.44.21] — 2026-06-11 — arc-closing sweep batch 1 of 2 (security + iron hardening)
- One genuine ring-3-reachable security bug and one newly-live boot-hang risk. Production build **1,193,424 B**
  (+352 B vs 1.44.20's 1,193,072 B — the two clamp/bound additions). `smp-smoke` 3/3 · `check.sh` 11/11 · arc sweep
  7/7.

## [1.44.20] — 2026-06-11 — kernel-scaled blit: `a4[39:32]` integer scale on `#39`
- `blit`#39 gains an INTEGER SCALE in `a4` bits [39:32] (0 or 1 = the 1:1 path, byte-identical): each src pixel
  becomes a scale×scale block, dst rect clipped exactly as 1:1. Consumer win (cyrius-doom 0.29.0): it drops its
  userland scaler (capped at 3 by its heap budget) — the panel's natural integer scale now applies (**7 on
  2560×1440**), and ring 3 writes 64K pixels/frame instead of scaled. Production **1,193,072 B** (+32 KB rowbuf).

## [1.44.19] — 2026-06-11 — per-process env through `execwait`#37 / `spawn_path`#43
- Wire format: `a3` = user pointer to a flat NUL-separated `KEY=V\0KEY=V\0` blob, `a4` = blob length (**≤1024 B, ≤16
  entries**), on BOTH `#37` and `#43`; the caller env REPLACES the default. `a3==0` and every legacy caller keeps
  the uniform `HOME=/` + `PWD=/`.

## [1.44.18] — 2026-06-11 — SMP-AP wake + park: all 4 CPUs online, single-core invariant untouched
- The BSP wakes APs 1-3 via the SDM INIT-SIPI-SIPI protocol with real tick-timed delays; each AP comes up through
  the 16→32→64-bit trampoline, enables its LAPIC, takes its per-CPU TSS, counts in through the spinlock, and PARKS
  (IF=0 `hlt` — no AP ever takes a timer interrupt or runs the scheduler).

## [1.44.17] — 2026-06-10 — idle deprioritization: idle runs only when nothing else is ready
- The idle kthread was a round-robin PEER, burning a full 10 ms slice whenever real procs were ready. BENCHMARK
  (`agnsh-bg-test.py`, N=2×10⁹, QEMU TCG): **12.3 s → 9.8 s (×1.26)**, stable across 2 runs.

## [1.44.16] — 2026-06-10 — `sched_yield`#44: voluntary end-of-slice from ring 3
- A ring-3 proc donates the REMAINDER of its 10 ms slice to the next ready proc. Consumer: agnsh's bg-job poll loop
  polls once + yields. BENCHMARK (QEMU TCG, same host, `agnsh-bg-test.py` N=2×10⁹ busy-count sleeper): **22.8 s →
  12.8 s wall-clock, ×1.78 faster**.

## [1.44.15] — 2026-06-10 — multiple concurrent `&` jobs validated; out-of-order reap
- Kernel byte-identical to 1.44.14 (**1,147,584 B**) — no fix needed. exec-smoke 16/16.

## [1.44.14] — 2026-06-10 — schedulable agnsh WORKS: the shell stays live while a bg job runs
- End-to-end on the real kernel: `sleeper &` → `[1] 3` (prompt returns immediately) → `version` responds WHILE the
  bg job runs → `SLEEPER-DONE` → `[1] Done`. Production **1,147,584 B**.

## [1.44.13] — 2026-06-10 — schedulable agnsh: both KERNEL halves
- Prompt-preempt is Option B (agnsh polls in ring 3; a yielding blocking read needs per-proc kstacks — deferred).
  Production **1,147,200 B**.

## [1.44.12] — 2026-06-10 — non-LIFO proc-table-slot reclaim (out-of-order background-job exits)
- An out-of-order exit reaped a NON-TOP slot but append-only allocation never reused it, leaking the 16-slot table
  even though the memory was freed. Production **1,141,840 B**. ⚠ PID-RECYCLE caveat documented in the
  `proc_alloc_slot` header.

## [1.44.11] — 2026-06-10 — page-table VA-collision fix: many concurrent ring-3 procs
- The in-memory loaders' per-pid user VAs collided with the kernel's identity-supervisor map of the pmm pool,
  SMAP-faulting on context switch once ≥~6 ring-3 procs coexisted. De-striped to fixed VAs; **≥8 concurrent ring-3
  procs** now run without faulting. Also stages `spawn_path`#43 non-blocking.

## [1.44.10] — 2026-06-10 — ring-3 parent `spawn`#3 + `waitpid`#4, end to end
- The child now runs correctly under the parent's CR3 (the `#UD`-at-child-entry triple fault is gone).

## [1.44.9] — 2026-06-10 — non-blocking `waitpid`#4
## [1.44.8] — 2026-06-10 — real ELF spawn: a scheduled ring-3 proc runs from an actual ELF image
- Found and fixed two latent `elf_load` bugs the never-exercised `spawn`#3 path was carrying.

## [1.44.7] — 2026-06-10 — concurrent ring-3 execution: run to completion + `exit()` while another lives
## [1.44.6] — 2026-06-10 — preemptible ring-3 procs make syscalls safely; the "kstack wall" dissolves
- Two ring-3 procs, each preemptible (IF=1) with its own CR3, make real syscalls in a loop concurrently with no
  corruption. Size unchanged **1,123,624 B**.

## [1.44.5] — 2026-06-10 — two concurrent ring-3 procs time-slice with isolated address spaces
- Size unchanged **1,123,624 B**.

## [1.44.4] — 2026-06-09 — preemptive ring-3: a user proc time-slices under the scheduler
- The first time agnos context-switches INTO ring 3 (every prior switch was ring-0 on the shared CR3 `0x1000`).
- ⛔ The LATENT ALIASING HAZARD bit here: `spawn_user_proc` called `pmm_alloc` for ONE 4 KB page and `proc_map_page`
  mapped the ENCLOSING 2 MB region as a huge page, leaving the other 511 pages free in the PMM and eligible to be
  handed out again — the 4 KB-backed code page aliased to the 2 MB base → zeros → `#PF` with `CR2=0`. Cracked with
  `qemu -d int`; fixed by `pmm_alloc_2mb`.

## [1.44.3] — 2026-06-09 — per-process CS/SS: remove the ring-0 context-switch hardcode
## [1.44.2] — 2026-06-09 — reentrancy gate applied to the FS write-fd slot allocator
## [1.44.1] — 2026-06-09 — unify the ad-hoc preemption-suspends on the `preempt_count` gate
## [1.44.0] — 2026-06-09 — ✳ opens the multi-threading / preemptive-scheduling arc

## [1.43.8] — 2026-06-09 — `kbscan`#42: non-blocking raw-scancode input for ring-3 game loops
- **`kbscan(buf, max)`#42** drains up to `max` raw Set-1 scancodes (make AND break, incl. `0xE0` extended prefixes)
  from `kb_buf` into the user buffer and returns the count — never blocks, never cooks — so the caller keeps its own
  held-key state. Needed because `read`#5 on fd 0 is blocking, line-disciplined and cooked-to-ASCII, which freezes a
  35 Hz frame loop and drops key-up. Opens a brief bounded IRQ1 window (the `sleep_ms`#41 / `kbd_read_blocking`
  recipe, but with NO `hlt`). Validated: `w` advances DOOM past the title to the main menu; `q` quits it.
- Fixed "first-mmap RIP=0" / DOOM locking up via `agnsh`→`execwait`: the fault (`v=0e e=0015 cpl=3 RIP=0`) was NOT a
  first-mmap or SYSRET bug.

## [1.43.7] — 2026-06-08 — `execwait`#37 carries argv
- Iron burn `1436` showed every ring-3 launch WITH an argument failing `run: failed to launch program` (arg-less
  launches worked): the `#37` handler called `elf_load_from_file(pdst, arg2, pdst, arg2)` — using the WHOLE command
  line (e.g. `"/bin/bnrmr AGNOS"`, len 16) as BOTH the file-open name AND the argv source.

## [1.43.6] — 2026-06-08 — ★ DOOM RENDERS ON AGNOS: the first real userland application
- `cyrius-doom --agnos` (0.28.2) execs from disk in ring 3, slurps the 4.2 MB `DOOM1.WAD`, parses it, and blits a
  240-colour title screen via `fbinfo`#38 / `blit`#39.

## [1.43.5] — 2026-06-08 — ring-3 timing: `uptime_ms`#40 + `sleep_ms`#41
- **`uptime_ms()`#40** returns monotonic milliseconds since boot in `rax` (no buffer, like `getpid`#2): `timer_ticks
  * 10` at 100 Hz.
- **`sleep_ms(ms)`#41** blocks ~`ms` ms by halting until `timer_ticks` reaches the target. Because ring 3 runs IF=0
  this needs the `sched_active=0` + `sti` + `hlt` recipe. `/bin/timetest` reads the clock, sleeps 50 ms, reads
  again: the tick delta is exactly 5 (`sl_target = ticks+5`).
- 10 ms granularity is playable for DOOM's 35 Hz (28.57 ms) tics.

## [1.43.4] — 2026-06-08 — graphics path: `fbinfo`#38 + `blit`#39
- **`fbinfo(buf, len)`#38** writes a 24-byte geometry struct (6× u32 LE): `width` / `height` / `pitch` / `bpp` (32)
  / `pixel_format` (0=RGBX, 1=BGRX) / reserved.
- **`blit(src, w, h, dstxy)`#39** where `dstxy = (dst_y<<16)|dst_x`. Copies a `w×h` block of 32bpp pixels from the
  tightly-packed ring-3 buffer. Kernel-mediated copy, NOT FB-mmap — from a 4-source convergent audit (Linux
  fbdev/simpledrm, BSD wsfb, EDK2 GOP, doomgeneric).
- Security: `blit` FAIL-CLOSES on a malformed GOP — the in-bounds write proof needs `pitch >= width*4`.
- `/bin/fbtest` exits `bpp(32) + blit_rc(0) + 56` = **88**.

## [1.43.3] — 2026-06-08 — stdin EOF (Ctrl-D) + `anuenue` banked
- `kbd_read_blocking` gains a Ctrl-D / EOF branch: at line start (`n==0`), `read(fd 0)` returns 0. That is the ONLY
  EOF path on agnos.
- `burn-prep.sh` now defaults to a BARE production kernel.

## [1.43.2] — 2026-06-07 — envp on the exec stack (`getenv()` resolves on agnos)
- `elf_load_from_file` stages a minimal envp (`HOME=/`, `PWD=/`) on the SysV init stack. ABI contract: from the
  captured init rsp, `argc = [rsp]`, `argv[i] = [rsp+8+i*8]`, argv NULL at `[rsp+8+argc*8]`, then `envp[i] =
  [rsp+8+(argc+1)*8 + i*8]`, NULL-terminated. `/bin/envtest` reads `envp[0]` at `[rsp+0x18]` and exits with its
  first byte, `'H'`.

## [1.43.1] — 2026-06-07 — ANSI/CSI/SGR interpreter in the FB console
- `fb_ansi_feed()` — a 3-state CSI parser (normal → ESC → CSI) in front of `fb_putc`'s glyph path. SGR colour
  (reset, 16-colour `30-37`/`40-47` + bright `90-97`/`100-107`), ED `ESC[2J` (clear to current bg + home — fixes
  agnsh `clear`), CUP `ESC[r;cH`/`…f` (1-based → 0-based, clamped). Unsupported sequences no-op rather than
  mis-render.
- Pixel-format-aware colour packing (`fb_pack`) honours EFI BGRX (pf 1) vs RGBX (pf 0) — white and black were
  symmetric, which is why this had never shown.

## [1.43.0] — 2026-06-07 — ✳ 1.43.x arc OPEN: `execwait`#37, the ring-3 blocking-exec primitive
- **`execwait(path, pathlen)`#37** loads a static ELF64 from the active ext2 root and runs it to completion. Two
  hard problems solved: (H1) resume-context preservation — the nested `exec_and_wait` overwrites the single-slot
  resume globals (`exec_ctx` + `kernel_return_*` + `kpti_*` + `kernel_rsp_save`); (H2) a DISJOINT syscall kstack —
  the kernel uses one fixed SYSCALL stack (`0x3F0000`) and the child's own syscalls would grow down through the
  caller's suspended `#37` frame. Runs `elf_load_from_file` under the BOOT CR3 (`0x1000`) because the per-process
  CR3 does not map the NVMe BAR.

## [1.42.14] — 2026-06-06 — hardening / audit / security sweep (pre-burn)
- CRITICAL — ring-3 arbitrary kernel write via signalfd/timerfd reads, FIXED: `read(sigfd, ADDR, 0)` reached
  `vfs_read_signalfd`/`vfs_read_timerfd` with no tag check.
- MEDIUM — SMAP disabled across post-exit kernel work, FIXED: the entry stub's `STAC` was not paired with `CLAC` on
  that path.

## [1.42.13] — 2026-06-06 — the `klug` userland reader ships (a sovereign `dmesg`)
## [1.42.12] — 2026-06-06 — leveled logging (`klog_info`/`klog_warn`/`klog_err`) + `klog`#36
- Adversarial review, 3 independent lenses, 0 findings: the mask bounds every `klug_buf` index and `kl_w < kl_want ≤
  arg2` keeps writes inside the `is_user_range`-validated window. Build **1,096,464 B**.

## [1.42.11] — 2026-06-06 — `klug` bite 1: the unified in-kernel log ring buffer
- Every byte of `kprint`/`kputc`/`kprintln` is tapped into one ring. Build **1,095,568 B**.

## [1.42.10] — 2026-06-06 — the sovereign sysinfo surface: `uname`#34 + `sysinfo`#35
- Split (identity vs counters), NOT combined — a monitor like chakshu polls `sysinfo` repeatedly without re-copying
  the static strings, and each struct is single-shaped.
- `exec-smoke.sh` 8/8 incl. the new `run: exit 66`; `/bin/sysi` is exec **#3** in one boot, confirming the 1.42.4
  reap work lifted the old 2-exec-per-boot ceiling. Build **1,078,176 B**.

## [1.42.9] — 2026-06-06 — perf: `fb_console` glyph blit strength-reduced to add-stride
- Build **1,077,096 B**.

## [1.42.8] — 2026-06-06 — perf: every ext2 block read collapses 8 single-LBA NVMe commands into one
- Build **1,076,952 B**. `sweep.sh` 7/7 — the `/bin/prog2` ELF is read off ext2 through the new multi-LBA path.

## [1.42.7] — 2026-06-06 — perf: PMM bitmap ops inlined, the single-core PMM spinlock retired to a no-op
- Build **1,075,456 B**. `sweep.sh` 7/7 incl. `e2fsck -fn` clean.

## [1.42.6] — 2026-06-06 — ship agnsh 1.4.2 with working FS verbs as the userland shell
- `agnsh-verb-test.py` PASS (`ls /` → `lost+found bin vtest`; `cat /vtest` → `VERBPROOF`). Build **1,074,288 B**.

## [1.42.5] — 2026-06-06 — perf: `kmalloc` is O(1)-zero instead of O(block_size)
- Build **1,074,288 B** (−16 B). First measurement-gated perf cut.

## [1.42.4] — 2026-06-06 — hardening (c): reap leftovers + mmap-arena teardown
- `reap: 6x mmap-arena page reclaimed, free stable OK` — free-page and 2 MB-region counts stable across 6
  map/teardown cycles. Build **1,074,304 B**.

## [1.42.3] — 2026-06-06 — hardening (b): the rare SYSCALL-path RBP smash (`CR2=0x37fed8`)
- User RBP is now preserved across the kstack switch. `scripts/rbp-repro.sh` (N=40 boots under `qemu -d int`,
  scanning for a ring-3 `#PF` with CR2 in the kstack window `0x37fxxx`): **40/40 reached the prompt, 0 RBP-smash
  faults, 0 total `v=0e`.** Build **1,074,304 B**.

## [1.42.2] — 2026-06-06 — hardening (a): the mmap arena is no longer seeded present-supervisor
- `scripts/repro-ring3-pf.sh` (N=20 boots): **0 ring-3 `#PF` / 20 boots, reached-exec 20/20** (signature
  `CR2=0x10000000`: 0, `CR2=0x8`: 0) — holds the 0/52 baseline. Build **1,074,304 B**.

## [1.42.1] — 2026-06-06 — `scripts/bench.sh` reconstructed
## [1.42.0] — 2026-06-06 — ✳ cycle open: kernel perf + hardening (Track A) ∥ userland env (Track B)

## [1.41.15] — 2026-06-05 — agnsh typing on iron: the stuck-shift `Command: D` collapse fixed
- Burn `14114` read the keyboard but every line collapsed to `Command: D`. `agnsh-type-test.py` PASS —
  `help`/`version`/`mode` echo as typed AND dispatch correctly. ⭐ The 1.41.x shell-separation arc is HARDWARE-CLOSED
  here (burn `14115`, 2026-06-06).

## [1.41.14] — 2026-06-05 — `read(fd 0)` re-enables interrupts so IRQ1 delivers
## [1.41.13] — 2026-06-05 — `read(fd 0)` ran interrupts-masked; + a comment-accuracy sweep
## [1.41.12] — 2026-06-04 — ring-3 stdout FB-mirror fix
- The `14111` burn rode clean but its primary bar was UNOBSERVABLE: ring-3 stdout was serial-only and archaemenid
  has no serial, so the agnsh banner was invisible and the boot LOOKED hung at `kybernet: exec /bin/agnsh`. Fixed by
  routing `serial_dev_write` through `kprint` (serial + FB).
- PMM fix: **0 ring-3 `#PF` across 52 fresh QEMU boots** (`qemu -d int`, KASLR per boot) vs ~16/20 on the unfixed
  baseline.

## [1.41.11] — 2026-06-04 — clean + iron-burn prep (the arc is software-complete)
## [1.41.10] — 2026-06-04 — arc-close hardening: audit the write path the 1.41.5 sweep predated
## [1.41.9] — 2026-06-04 — the in-kernel shell shrinks to a recovery REPL
- The permanent kernel↔userland shell boundary is locked. `shell.cyr` 1149 → 813 LOC across 1.41.8/1.41.9. Verb
  split: to agnsh (user-facing) help ps free uptime · cat ls cd pwd echo/echo> touch rm mkdir rmdir mv ln sync · run
  · dns ping ntp date send recv tcp net · halt. To the kernel recovery shell (deep diagnostics with no clean
  syscall): lspci cpus pipe blkread disk parts jbd2 bench test.

## [1.41.8] — 2026-06-04 — decouple the FS-write test harness from the in-kernel shell verbs
## [1.41.7] — 2026-06-04 — FAT/exFAT content-write via the syscall ABI
## [1.41.6] — 2026-06-04 — refactor + exec-hardening (the deferred half of the 1.41.5 sweep)
- Build 1,063,016 → **1,063,944 B**.

## [1.41.5] — 2026-06-03 — syscall-ingress hardening / security sweep
- A 6-dimension multi-agent pass (syscall ingress · FS backends · exec/proc · memory-safety sweep · refactor ·
  net-ingress recheck), each finding adversarially verified for ring-3 reachability. **26 findings survived
  verification, 0 refuted; 15 fixed (all 10 HIGH + 2 MED + 3 LOW), 8 deferred.**
- The four invariants the audit reasoned under: single-threaded, single-core, no preemption during a syscall
  (SYSCALL masks IF via SFMASK) so "a race" is not a valid finding · the per-process CR3 mirrors a SUPERSET of the
  kernel map · EVERY legitimate user address is BELOW 1 GB (ELF segments `p_vaddr ≥ 2 MB`, `p_memsz ≤ 32 MB`;
  per-pid stack `0x800000 + pid*0x400000`, under 72 MB for the 16-proc cap; mmap arena `[0x10000000, 0x40000000)`)
  while MMIO/BARs (NVMe ~`0xC0000000`) sit above it · the trust boundary is `is_user_ptr`/`is_user_range`.
- HIGH fixes: `epoll_ctl`#20 never checked `ktag==VFS_EPOLL` → arbitrary kernel write; `epoll_wait`#21 the same →
  arbitrary kernel read plus an attacker-driven loop count; the watched fd (arg3) was stored unbounded then used as
  `&vfs_table + wfd*32` → OOB kernel read; `is_user_ptr`/`is_user_range` had NO UPPER BOUND (fixed with a **1 GB
  ceiling**); `sigprocmask`#17 and `signalfd`#18 validated a bare pointer then load/stored 8 bytes; an unbounded
  basename overflowed `ext2_dir_buf[512]` (4 KB) during fresh-block directory append (fixed with a **255-byte cap**
  in `vfs_ext2_parent`, one ingress covering every FS-mutation syscall); `spawn`#3 passed user-supplied
  `elf_addr`/`elf_size` into `elf_load` with no `is_user_range` → kernel-memory disclosure.
- MED/LOW: `sys_mmap`'s `length + 0x1FFFFF` wrapped on a near-u64 length, defeating the arena ceiling; ELF `p_vaddr`
  had no upper bound so a segment could alias a future mmap (capped `p_vaddr + p_memsz ≤ 0x10000000` on BOTH load
  paths); `epoll_create`#19 stored `kmalloc(128)` with no null check; `epoll_wait` validated a bare pointer before
  writing up to ~192 B (now `is_user_range(arg2, arg3*12)`); `timerfd_settime`#23 had no tag check;
  `dns_qname_encode` had no overall length cap before its 320 B buffer (255-byte hostname cap); `fatfs_read` lacked
  the FAT-chain cycle guard `exfat_read` already had.
- Principle: a hardening cut must NOT carry behaviour-equivalent rewrites of the file it is hardening.

## [1.41.4] — 2026-06-03 — first boot-to-agnsh-on-disk (PID 1 execs `/bin/agnsh`) + the FS syscalls
- `kybernet_exec_agnsh()`: PID 1 loads `/bin/agnsh` off the ext2 root via `elf_load_from_file` and `exec_and_wait`s
  it in ring 3.
- The mount-routed VFS gets its ring-3 face — nine syscalls against the frozen ABI: **`getdents`(29)** —
  `open(AO_DIRECTORY)` returns a `VFS_EXT2_DIR` fd (type 8); `getdents` walks it from a saved byte offset and emits
  agnos-native dirent records (§4.2: `reclen` u16 / `type` …). **`unlink`(30)** — mount-routed; ext2 via a new
  `vfs_ext2_parent` path split. **`rename`(31)** — within one filesystem; uses **`a4`** for `newlen`. Cross-FS
  rename refused. **`link`(32)** — hard link, ext2-only; FAT/exFAT return −1 (no inodes / hard links). Uses `a4`.
  **`stat`(33)** — fills the 48-byte agnos stat struct (§4.1: `st_mode` / `nlink` / `size` / `ino` / `blocks` /
  `mtime`) from the ext2 inode. FAT/exFAT degrade to −1. **`open`(7)** re-routed from `initrd_open`-only to
  `vfs_resolve_mount` → `ext2_open` / `vfs_open_on`, with initrd as the bare-name fallback; gained the flags arg
  (a3). **`mkdir`(9) / `rmdir`(10) / `sync`(12)** were tier-1 stubs returning 0; now real.
- **`a4=r10` syscall ABI extension (decision O2)**: the entry stub preserves the user's `r10` into `r9` as its FIRST
  instruction, before the CR3-switch scratch clobbers it.
- ⚠ chdir/getcwd are intentionally NOT syscalls — CWD is userland-owned; agnsh tracks its own and passes absolute
  paths.
- Cyrius pin `6.0.14` → `6.0.56`. Build 1,061,944 B.

## [1.41.2] — 2026-06-03 — boot_info consumers: canary + ACPI RSDP fallback (the agnos half of gnoboot 0.5.0)
- The canary reads `initramfs_phys` (0x10), `initramfs_size` (0x18), `cmdline_phys` (0x20), `acpi_rsdp_phys` (0x38).
  `acpi_init` falls back to `boot_info` when the legacy EBDA / `0xE0000` ROM scan returns 0 (the UEFI case).
  End-to-end: `rsdp=0x1fb7e014`.

## [1.41.1] — 2026-05-31 — blocking keyboard stdin from ring 3
- `read(fd=0)` now blocks on the keyboard and returns typed bytes. Production **1,050,824 B**.

## [1.41.0] — 2026-05-31 — ✳ shell-separation arc OPEN: boundary audit + staging mechanism
- The gating prerequisite was CYRIUS-side: agnsh built with `CYRIUS_TARGET_LINUX` emits Linux syscall numbers, Linux
  stat layouts and the openat family and will not execute on the sovereign ABI. The resolution is a
  `CYRIUS_TARGET_AGNOS` stdlib profile — "Cyrius learns to emit agnos syscalls", NOT "agnos learns to answer Linux
  syscalls", which would erase the structural-immunity invariant. Landed cyrius 6.0.55/56.
- Syscall table at arc open: 29 entries, 0-28 — 0 exit · 1 write · 2 getpid · 3 spawn · 4 waitpid · 5 read · 6 close
  · 7 open · 8 dup(stub) · 9 mkdir(stub→0) · 10 rmdir(stub→0) · 11 mount(noop) · 12 sync(stub→0) · 13 reboot · 14
  pause · 15 getuid(0) · 16 kill · 17 sigprocmask · 18 signalfd · 19-21 epoll · 22-23 timerfd · 24 umount(0) · 25
  pipe · 26 write_boot_checkpoint · 27 mmap · 28 munmap.

## [1.40.14] — 2026-05-31 — 1.40.x arc closeout: process teardown / reaping + hardening
- `exec-smoke.sh` 7/7 (both reap assertions OK; boot reaches `AGNOS shell v1.40.14`); `sweep.sh` functional arcs
  6/6.

## [1.40.13] — 2026-05-31 — VFS mount-point namespace: shell verbs route by MOUNT
- FAT/exFAT are reachable through the shell while ext2 owns `/`. Removed the 8 dead `vfs_*_secondary` dispatch
  helpers, superseded by the mount-routed `vfs_*_on` helpers. Build **1,054,936 B**; production **1,050,392 B**.

## [1.40.12] — 2026-05-31 — boot-stack memory-safety fix: the kernel stack grew into its own `.rodata`
- Build **1,046,736 B**.

## [1.40.11] — 2026-05-31 — the "exfatprogs 1.3.2 mkfs format drift" was a MISDIAGNOSIS
- There is no drift.

## [1.40.10] — 2026-05-31 — the scheduler no longer triple-faults with dead exec procs in the table
- ROOT CAUSE: the now-working exec selftest leaves `proc_count >= 2` with `proc_current` pointing at a dead exec
  proc, so the first timer tick after `sched_active=1` (the DHCP `hlt` wait) cleared `do_context_switch`'s old
  `proc_count<2` early return, fell back to the dead proc, `cr3_load`ed its stale per-process CR3 and `iretq`'d into
  a ring-3 RIP while in ring 0 → triple-fault reset. It was NOT DHCP. Fix: register proc 0 as the kernel main thread
  and proc 1 as a `hlt` idle thread, both on boot CR3 `0x1000`, BEFORE `sched_active=1`, so the equal-CR3 guard
  skips `cr3_load` and preemption becomes a pure register save/restore in one address space.

## [1.40.9] — 2026-05-30 — exec-from-disk iron-reset triage: real CPU-exception handlers
- The `1409` first attempt HALTED at `exec: running /bin/prog2` rather than resetting; `read-boot-log.sh --verbose`
  read CMOS[0x55]=0xE5 (the fault-handler magic) + CMOS[0x54]=0x0E → vector 14 = `#PF`. The IDT now catches the
  transition fault instead of triple-faulting into a CPU reset.
- ROOT CAUSE LOCALIZED + FIXED via the full-CR2 capture: gnoboot's high UEFI load address. Build **1,038,304 B**;
  EXEC selftest build **1,042,176 B**.

## [1.40.8] — 2026-05-29 — exec-from-disk bite 8: argv-deref gate + burn prep
- The iron rubric's dispositive bar is **A3 + A4**: `exec: running /bin/prog2` → **EXEC-DISK-OK** and **`run: exit
  42`**. A4b (argv deref): `exec: running /bin/argv Z` → **`run: exit 90`** because argv[1][0]='Z'=0x5A — this
  subsumes the argc≥2 check and proves the argv STRING BYTES reach ring 3 on the SysV init stack. A6 confirms
  `e2fsck -fn` clean from Linux.
- ⚠ KNOWN LIMIT: only TWO real execs per boot succeed. Each exec LEAKS its 2 MB pages (no process teardown yet), so
  a THIRD `run` fails at load with `run: not an executable`. A third-program failure on iron is NOT a regression.
  Build **1,034,704 → 1,034,768 B**.

## [1.40.7] — 2026-05-29 — argv on the SysV init stack
- `elf_load_from_file` builds the init stack (rsp → argc, argv[], NULL, envp NULL, auxv AT_NULL, with strings higher
  and 16-byte alignment); `sh_cmd_run` splits the path token from args. envp and auxv CONTENTS remain deferred
  (slots zeroed / AT_NULL).

## [1.40.6] — 2026-05-29 — multi-`run` in one boot
- `kernel_resume` restores the boot CR3 on program exit because the per-process CR3 does not map the NVMe BAR, so
  the next run's ext2 read faulted; `sh_cmd_run` also sets `proc_current = pid` for per-run exit codes. Build
  **1,033,512 → 1,033,528 B**.

## [1.40.5] — 2026-05-29 — exec bite 5 (arc close): hardening + clean multi-run + arc sweep
- Fixed the ~17% exec flake by reserving the SYSCALL kernel stack immediately after `heap_init` so it lands at phys
  `0x200000`, below user VAs (it had been colliding with a user VA); implemented clean `exec_and_wait` return via a
  full setjmp/longjmp of callee-saved registers plus the caller frame. `sweep.sh` 7/7. Build **1,033,448 → 1,033,512
  B**.

## [1.40.4] — 2026-05-29 — subdir/CWD program paths + ENOEXEC / E2BIG bounds
- `run` refuses non-ELF with ENOEXEC and files over **16 MB** with E2BIG. Build **1,033,304 → 1,033,448 B**.

## [1.40.3] — 2026-05-29 — ring-3 execution (the RUN half) WORKING
- Ring-3 + SYSCALL bring-up cost ten first-run bugs. The core blocker: the SYSCALL stub's `mov cr3, r10` mis-encoded
  with REX.R (byte `0x44` → cr11 → `#UD`) instead of REX.B (`0x41`). The other nine: LSTAR programmed via NX-stack
  bytecode; EFER.SCE not actually in effect; a KPTI dual-CR3 mismatch (collapsed to one full per-process CR3); the
  syscall kernel-stack VA colliding with the user stack; SMAP blocking the user-buffer copy (needed STAC/CLAC); an
  APIC read before the CR3 switch; timer-in-ring-3 with IF masked; a 2 MB-versus-4 KB page-allocation mismatch; fd
  1/2 not wired to the console. `exec-smoke.sh` 6/6. Build **1,033,296 → 1,033,304 B**.

## [1.40.2] — 2026-05-29 — streaming ELF loader (the load half)
- Reads the header into a 4 KB scratch, then streams each `PT_LOAD` segment's bytes DIRECTLY into its physical pages
  via the kernel identity map with NO CR3 switch. Parsed `entry=0x400078`. ⛔ DEAD APPROACH: switching CR3 into a
  half-built address space to load segments — it HUNG. ⚠ Clean for ext2 because `ext2_read_at` takes an offset; FAT
  and exFAT have NO offset-read, so FAT/exFAT exec would need cluster-skipping (deliberately deferred). Build
  **1,024,256 → 1,033,296 B**.

## [1.40.1] — 2026-05-29 — `vfs_read_file`: whole-file read past the 4 KB cap
- ⛔ DEAD PLAN: a whole-ELF `kmalloc` buffer. Both `kmalloc` AND `pmm_alloc` cap at a single 4 KB page (heap slab
  classes top out at 4096; `pmm_alloc` returns one `i*0x1000` page). agnos has NO large-contiguous allocator. Build
  **1,014,528 → 1,024,256 B** (+9,728 B: `vfs_read_file` + an 8 KB `vfs_scratch_buf`).

## [1.40.0] — 2026-05-28 — ✳ exec-from-disk arc: cycle open
- `elf_load(elf_addr, elf_size)` (`elf.cyr:5`, ~120 LOC) is a complete hardened static ELF64 loader: validates magic
  and class=2; requires `entry >= 0x200000`; bounds-checks the program-header table; requires `phnum <= 64` and
  `phentsize >= 56`; per `PT_LOAD` validates offsets/sizes within the file, `p_memsz >= p_filesz`, no overflow,
  `p_vaddr >= 0x200000`, segment ≤ **0x2000000 (32 MB)**; creates a per-process address space, maps 2 MB pages,
  memcpys, zeros BSS, returns a pid.

## [1.39.9] — 2026-05-28 — VFS lift bite 9: FAT/exFAT subdirectory paths
- `fatfs_resolve_parent` + `fatfs_find_in_dir` / `fatfs_find_free_slot_in_dir` using a sentinel `dir_clus==0`
  meaning root that delegates to the existing root finders, so bare names stay byte-identical; `..` now points at
  the real parent. exFAT got the same via `exfat_resolve_parent`. `mv` is bounded to SAME-PARENT; both backends
  reject differing parents. Build **1,007,696 → 1,014,528 B**.

## [1.39.8] — 2026-05-28 — VFS lift bite 8 (arc close): mount-registry consolidation + ingress hardening
- Seven duplicated non-ESP-preference chains folded behind one `vfs_secondary_select()`; `vfs_sec_name_ok` (1..255)
  added at the generic seam to bound `fatfs_build_83`'s unbounded dot-scan and backstop the exFAT create/mkdir
  entries. `exfat_set_buf[80]` = 640 B verified ≥ the 608 B maximum dir-set size; `exfat_name_buf` is 256 B with
  <255 guards. Build **1,008,816 → 1,007,696 B** (−1,120 B net: −1,760 from folding, +640 for the guard).

## [1.39.7] — 2026-05-28 — VFS lift bite 7: `mv` (rename) + `sync` on FAT/exFAT
- Neither FAT nor exFAT has atomic rename; both are content-preserving with no copy — `fatfs_rename` is an in-place
  dirent rewrite, `exfat_rename` re-emits the dir-set at the same clusters and soft-deletes the old one. Build
  **1,008,816 B**.

## [1.39.6] — 2026-05-28 — VFS lift bite 6: `mkdir`/`rmdir` on exFAT
## [1.39.5] — 2026-05-28 — VFS lift bite 5: `mkdir`/`rmdir` on FAT (new backend capability)
- Build **1,002,800 B** (crossed 1 MB; ceiling 1.2 MB).

## [1.39.4] — 2026-05-28 — VFS lift bite 4: `rm` removes FAT/exFAT files
- Build **998,312 B**.

## [1.39.3] — 2026-05-28 — VFS lift bite 3: `touch` + `echo >` write to FAT/exFAT
- Build **997,560 B**.

## [1.39.2] — 2026-05-28 — VFS lift bite 2: `ls` lists FAT/exFAT
- Build **994,824 B**.

## [1.39.1] — 2026-05-28 — VFS lift bite 1: `cat` reaches FAT/exFAT
- Build **993,088 B**.

## [1.39.0] — 2026-05-28 — Cyrius toolchain re-pin `6.0.3` → `6.0.14`

## [1.38.11] — 2026-05-28 — 1.38.x jbd2 arc CLOSE: crash-safe journaling iron-validated
- The `13810_*` five-boot burn on the unmodified CSUM_V3 archaemenid journal. Boot 1 (production): `jbd2: clean
  journal ino=8 size=32760 seq=4`, `fat: mounted FAT32`, DHCP `.151`; host `e2fsck -fn` clean (`agnos-fs: 22/1638400
  files (4.5% non-contiguous), 148271/6553600 blocks`); on-disk journal SB `magic=0xc03b3998 s_start=0
  s_sequence=4`. Boot 2 (integration): `commit_tx: COMMITTED seq=4 n_blocks=1 -- checkpoint applied + journal clean`
  → `integration selftest PASS`; SB `s_sequence=5`. Boot 3 (crash build): stress loop to `100/100 done` → `stress
  loop PASS (clean shutdown)`. Boot 4: POWER CUT mid-cycle. Boot 5 (recovery): `jbd2: clean journal ino=8 size=32760
  seq=142`, shell reached, `e2fsck -fn` clean, SB `s_sequence=142` CLEAN. The journal advanced seq **4 → 142**
  across commit + stress + crash + recovery and landed clean every time.
- Production build byte-identical to 1.38.10 (**992,832 B**).

## [1.38.10] — 2026-05-28 — JBD2 CSUM_V2/V3 write + replay support
- ⛔ FALSIFIED by the 1389 iron burn: "archaemenid's `mkfs.ext4` does not enable CSUM_V2/V3 by default." The real
  agnos-fs journal IS **CSUM_V3 + 64BIT** (journal incompat `0x12`, csum_type 4 / CRC32C), because host e2fsprogs
  1.47.4 enables metadata_csum by default. Consequence: the entire write side of the 1.38.x arc was iron-UNTESTABLE
  on that partition until this landed. What hid it: `jbd2-refusal-smoke.sh`'s "no SB csum to recompute" path only
  ever validated NON-csum QEMU images. Every QEMU smoke image regenerated with `-O metadata_csum,64bit`.
- ⛔ AGNOS BUG found by re-deriving from the live `jbd2.h` (not by trusting a comment): the legacy
  `journal_block_tag_t` read at `ext2.cyr:3956` and write at `4159-4164` placed `t_flags` at +4 and `t_checksum` at
  +6 — **SWAPPED** versus the real struct (`t_checksum` be16@+4, `t_flags` be16@+6). Self-consistent in QEMU (AGNOS
  reads AGNOS, csum=0) but a journal AGNOS leaves dirty is NOT Linux-replayable, because Linux reads the flags from
  the wrong offset and never sees LAST_TAG.
- `j_csum_seed = ext2_crc32c(0xFFFFFFFF, journal_sb + 0x30, 16)` — CRC32c of the JOURNAL superblock's `s_uuid[16]`,
  NOT the ext4 filesystem UUID and NOT `ext2_csum_seed`. Commit-block checksum for CSUM_V2/V3: `h_chksum_type = 0`,
  `h_chksum_size = 0`, and `h_chksum[0] = crc32c(j_csum_seed, entire_commit_block)` with `h_chksum[0]` pre-zeroed,
  covering the WHOLE blocksize. Per-tag: `c = crc32c(j_csum_seed, be32(h_sequence), 4)` then `c = crc32c(c,
  data_block, blocksize)`; V3 stores 32 bits at tag3+12, V2 the low 16 at tag+4. Descriptor tail: reserve the last 4
  bytes at `blocksize-4`, zero it, CRC the whole block, store big-endian. Build 990,232 → **992,832 B**.

## [1.38.9] — 2026-05-28 — CMOS-stamped JBD2 telemetry + host wrappers
- CMOS slots: **0xA0** PROBE_OUTCOME (0=no-journal, 1=clean, 2=dirty, 0xFF=malformed) · **0xA1** REPLAY_ATTEMPT
  (0=not-attempted, 1=ran) · **0xA2** REPLAY_OUTCOME (0=n/a, 1=success, 0xFF=failure) · **0xA3** REPLAY_TX_COUNT
  (saturating byte) · **0xA4** COMMIT_TX_COUNT (saturating byte). Build 986,656 → **987,544 B**.

## [1.38.8] — 2026-05-28 — JBD2 arc-close hardening: replay-side ingress validation
- Build 986,184 → **986,656 B**.

## [1.38.7] — 2026-05-28 — JBD2 crash-injection smoke (end-to-end recovery validated)
- Build 984,632 → **986,184 B**.

## [1.38.6] — 2026-05-28 — JBD2 integration: metadata writes route through the journal
- Narrow scope: only `put_inode`'s inode-table write is journalled; allocator writes stay direct, so a
  grow-then-crash can leave e2fsck-fixable orphan blocks. AGNOS's jbd2 uses a sync-checkpoint model that always
  resets `log_head = 1` after each commit, so no log-fill scenario is reachable. Build 982,576 → **984,632 B**.

## [1.38.5] — 2026-05-28 — JBD2 journal write path: AGNOS PRODUCES journals
- Commit order: allocate log space (wrapping circularly within `[s_first, s_maxlen)`) → descriptor → all data blocks
  → **FLUSH-CACHE barrier** → commit block → **barrier** → in-place checkpoint → update `s_start`. The three
  barriers are the load-bearing safety primitives; without them an SSD's write reordering leaves a valid commit
  block over garbage data and replay corrupts the FS. Build 977,792 → **982,576 B**.

## [1.38.4] — 2026-05-28 — JBD2 transaction lifecycle (in-memory scaffold)
- Build 970,920 → **977,792 B**.

## [1.38.3] — 2026-05-28 — JBD2 replay-on-mount (the unlock)
- Replay walks forward from `s_start`: descriptor → N data blocks → commit; validate the commit checksum; per tag
  (skipping blocks revoked in a LATER sequence) write the data block to its FS position; halt at the FIRST malformed
  sequence — everything before stays applied, everything from there is discarded; then rewrite the journal SB with
  `s_start=0`, `s_sequence=N+1`, and a FLUSH-CACHE barrier. Only after that is the FS mountable read-write. Build
  959,272 → **970,920 B**.

## [1.38.2] — 2026-05-28 — JBD2 log-format reader: descriptor / commit / revoke walker
- ALL jbd2 on-disk fields are BIG-ENDIAN. Journal SB: `h_magic`@0x00 = **0xC03B3998**, `h_blocktype`@0x04 = 4 for
  V2, `s_blocksize`@0x0C, `s_maxlen`@0x10, `s_first`@0x14, `s_sequence` @0x18, `s_start`@0x1C (0 = clean),
  `s_feature_*`@0x24, `s_uuid[16]`@0x30, `s_checksum_type` u8@0x50, `s_checksum`@0xFC. Descriptor `h_blocktype`=1,
  tags at 0x0C. Legacy tag: `t_blocknr` be32@0, `t_checksum` be16@4, `t_flags` be16@6, `t_blocknr_high` be32@8 (8 B
  without 64bit, 12 with). `journal_block_tag3_t` (CSUM_V3, all be32): `t_blocknr`@0, `t_flags`@4 (4 bytes),
  `t_blocknr_high` @8, `t_checksum`@0x0C — always 16 bytes. Tag flags: bit0 ESCAPE, bit1 SAME_UUID, bit2 DELETED,
  bit3 LAST_TAG. Commit block `h_blocktype`=2. Revoke `h_blocktype`=5, `r_count` be32@0x0C, `r_blocks[]` from 0x10.
  Build 956,168 → **959,272 B**.

## [1.38.1] — 2026-05-28 — JBD2 probe deepens: full SB read surface + V2 csum + `jbd2` verb
- Build 952,968 → **956,168 B**.

## [1.38.0] — 2026-05-28 — ✳ jbd2 journaling arc OPENED: SB probe + dirty-mount refusal
- The journal is a regular file referenced by `s_journal_inum` at superblock offset **224**, typically inode 8. A 32
  MiB journal at 4 KiB blocks = 8192 journal blocks; block 0 is the journal superblock. jbd2 replay must exist
  BEFORE AGNOS writes its own journal: mounting a Linux-written FS with unreplayed transactions and writing to it
  would corrupt it beyond e2fsck's reach.

## [1.37.5] — 2026-05-28 — arc-close hand-off: vendor `kashi` 0.6.0 into the kernel
- `fb_console.cyr` consumes kashi instead of carrying its own glyph tables. Build **843,776 → 945,360 B
  (+101,584)**. The growth is kashi vendoring more than agnos uses: the full CP437 range (224 glyphs, `0x20`–`0xFF`)
  for both VGA 8x16 and CGA 8x8 plus a derived `KASHI_FONT_VGA_9X16`, versus agnos's prior 96-glyph `0x20`–`0x7F`
  single-font slice. `CYRIUS_DCE=1` flags 141 unreachable fns (48,203 B) which would reclaim roughly half the delta;
  not enabled, to keep build behaviour identical.

## [1.37.4] — 2026-05-28 — ext-extent selftest: idempotent re-boot skip
- Iron Attempt 1373 boot-2's `no sibling leaf formed FAIL` was a TEST bug, not a filesystem bug — host `e2fsck -fn`
  was clean across BOTH boots. The selftest looped from `lblk=2` and only set `got_sibling` when it observed
  `eh_depth==1` with `eh_entries>=2` DURING the loop, but boot 1 had persisted `/extseed.dat` at `eh_depth==2`. Fix:
  check `eh_depth` right after `ext2_get_inode` and if it is 2 emit `already at depth=2 (prior boot) -- skip PASS` —
  the persisted tree IS the durability proof.

## [1.37.3] — 2026-05-27 — ext4 extent allocation: depth-2 tree growth
- `ext2_extent_grow_indepth2` spills the root's 4 index entries into an INDEX block (`eh_depth=1`), making the root
  `eh_depth=2`. QEMU smoke drove `eh_depth==2` with final depth=2, size 11.1 MB, ~1360 extents, `e2fsck -fn` clean.
- IRON Attempt 1373 (2026-05-28, EXT2_EXTENT_WRITE_SELFTEST build, **843,624 B**, ESP-only flash): boot 1 `ext-ext:
  seeded /extseed.dat` · `ino=18 extent size0=0` · `final depth=2 root_entries=1 size=11149376` · `depth-2 PASS` ·
  `append PASS`; boot 2 `ino=18 extent size0=11149376`, same tree — the file and its depth-2 tree PERSISTED across a
  reboot. Host `e2fsck -fn` under e2fsprogs 1.47.4: all five passes, `agnos-fs: 20/1638400 files (5.0%
  non-contiguous), 148269/6553600 blocks` — CLEAN.
- Depth-3 extent trees are unreachable in practice (~115,000 extents required); sibling index blocks and depth-3 are
  deliberately not implemented.

## [1.37.2] — OPEN (not yet tagged) — ext4 extent allocation: multi-leaf (depth-1 sibling split)
- `ext2_extent_add_sibling_leaf` gives up to 4 leaves (~4 × `eh_max` extents) without depth 2.

## [1.37.1] — OPEN (not yet tagged) — ext4 extent allocation: depth 0→1 tree growth
- `ext2_extent_grow_indepth` spills the 4 root extents into a new leaf block (`eh_max` 340 at 4 KB) and rewrites the
  root as one index entry.

## [1.37.0] — 2026-05-27 — ✳ ext4 extent ALLOCATION arc opened: depth-0 extent append
- Converged algorithm: walk to the rightmost leaf remembering the path; try to extend the last extent (new logical
  == `last.ee_block + last.ee_len` AND new physical == `last_phys + last.ee_len` AND `ee_len < 32768` → `ee_len +=
  1`); else insert `{ee_block, ee_len=1, phys}` if `eh_entries < eh_max`; else split. The block allocator takes a
  goal hint preferring `last_phys+1`.
- Extent commit order: data block → tree-node block(s) → inode, so a yanked write never leaves the inode pointing at
  an extent whose backing block or leaf node is not on disk.

## [1.36.2] — 2026-05-27 — refactor: `main.cyr` selftest extraction
- Production byte-identical (`18e23876…`, **828,528 B**) — selftests are `#ifdef`'d out of production.

## [1.36.1] — 2026-05-27 — `net.cyr` split part 2: app-protocols + ingress (refactor COMPLETE)
- Created `net_dhcp.cyr` (297 LOC), `net_icmp.cyr` (95), `net_dns.cyr` (234), `net_ntp.cyr` (74), `net_rtc.cyr`
  (114), `net_ingress.cyr` (179); `net.cyr` 1244 → 276 LOC. `net_ingress.cyr` holds `net_handle_arp` /
  `net_handle_udp` / `ip_safe_payload_len` / `net_poll` / `net_recv_udp` and had to become a TRAILING module because
  it sat BELOW the protocols in the original file. Include order preserving the original concatenation: `net.cyr →
  net_dhcp → net_icmp → net_dns → net_ntp → net_rtc → net_ingress → net_tcp`. Final layout is 8 files.
- ⭐ BYTE-IDENTICAL BUILD, sha256 **`512734b3d7e1e91037c212bc2c5c8d8c41dc63bc816c732af4ad60b23871b85f`** at **828,528
  B** before vs after — the strongest possible proof of behaviour preservation. Smokes: dns 3/3, icmp 1/1, ntp 1/1,
  rtc 1/1, tcp 4/4, tcp-listen 2/2, `test.sh` 4/4, `check.sh` 11/11.

## [1.36.0] — 2026-05-27 — ✳ refactor cycle open: `net.cyr` split part 1 (TCP extraction)
- TCP state machine + conn table + retransmit + server-side listen/accept (~780 LOC) → `net_tcp.cyr` (785 LOC incl.
  header); `net.cyr` 2019 → 1244 LOC.
- ⭐ THE BYTE-IDENTICAL SPLIT PROPERTY (a general lever): Cyrius `build` CONCATENATES includes into ONE compilation
  unit before compiling, so moving a contiguous block out of file X into a new file `include`d IMMEDIATELY AFTER X
  produces a character-identical compilation unit (comments are ignored by codegen) and therefore a byte-for-byte
  identical binary. Forward references across the split resolve identically because Cyrius resolves symbols across
  the whole unit. Baseline sha256 **`637340698cbdaab4695f216ad00ae93c9e78ae2be6c95282b7470d1dad61afd3`** at
  **828,528 B** == post-split.
- Deliberately NOT split: `ext2.cyr` (3155 LOC, deferred to the 1.39.x VFS-write arc) and `shell.cyr` (1026 LOC, the
  1.41.x slot); driver files are cohesive single subsystems.

## [1.35.7] — 2026-05-27 — arc-close hardening passes 1 + 2
- SECURITY — clamp the IPv4 total-length at the ingress demux. `net_poll` read the IPv4 header's TOTAL-LENGTH field
  (bytes 2-3, fully attacker-controlled) and computed `ip_payload_len = ip_total - ip_ihl`, guarding ONLY underflow
  and never clamping to the bytes actually received. A frame CLAIMING `ip_total = 65535` while physically 60 bytes
  yields a ~65 KB payload length handed to whichever handler the proto byte selects. Three exploit paths: ICMP —
  `icmp_send_echo_reply` copies `icmp_len` bytes and REFLECTS THEM BACK TO THE SENDER, turning an over-read of
  `net_rx_pkt`'s stale/adjacent bytes into a remote INFO-LEAK (its own `> 1024` cap bounds the size but not the
  read); UDP — `udp_data_len = ip_payload_len - 8` capped at 1016, then copied into the receive buffers; TCP — the
  internal guards (`tcp_hdr_len < 20` and `> ip_payload_len`) only hold if `ip_payload_len` is honest.
- FIX: `ip_safe_payload_len(ip_total, ip_ihl, avail)` — reject `ip_ihl < 20`, reject `ip_total < ip_ihl`, CLAMP
  `ip_total` to `avail`, reject if the clamp drops it below `ip_ihl`, else return `ip_total - ip_ihl`. Called with
  `avail = pkt_len - 14`. For VALID frames the result is IDENTICAL to the old arithmetic, including the
  Ethernet-min-padding case. Gate: `hardening: ip-clamp PASS`.
- FIXED — TCP sequence-number wrap. A full sweep of every SND.NXT/RCV.NXT update found ALL of them mask `&
  0xFFFFFFFF` EXCEPT TWO: `net_handle_tcp` ~line 1911 (SYN_SENT → ESTABLISHED, `store64(cb+40, seq+1)`) and ~line
  1994 (FIN_WAIT). Line 1911 is a real ~1-in-2^32-per-connection bug: a peer whose ISN is near 2^32 makes RCV.NXT
  `0x100000000` instead of 0, so the peer's first data segment carries the WRAPPED seq 0, the in-order accept
  silently rejects every segment, and the connection stalls. Both fixed inline; masking is now uniform across all 8
  seq-update sites.
- FIXED — RTC implausible-year upper bound: reject year > 2200 (a corrupt century/year CMOS byte could yield a
  far-future Unix time and seed it as the wall clock until NTP corrects it).
- Reviewed clean, no change: `dns_skip_name` (per-byte `p >= len` + a 128-iteration compression cap),
  `dns_parse_answer`, `tcp_parse_mss`, `net_handle_tcp`'s header bounds, `ntp_parse_unix`, `tcp_rx_append`, the DNS
  cache, the UDP length field, munmap partial range.
- DELIBERATE DEAD CODE, documented so nobody "fixes" it: `sys_mmap` pre-counts free 2 MB regions before the
  allocation loop, so a mid-loop `pmm_alloc_2mb == 0` is UNREACHABLE in the single-core model and the
  partial-rollback path is dead today. Flagged for the future SMP arc.

## [1.35.6] — 2026-05-27 — DNS positive cache (TTL-aware)
- 8 fixed slots (lwIP's `dns.c` model defaults to 4). Parallel arrays `dns_cache_ip` (0 = empty-slot sentinel, never
  a valid host IP), `dns_cache_exp` (expiry in `timer_ticks`, 100 Hz), `dns_cache_len`, plus a 512-byte name region
  with slot i at byte offset `i*64` — names longer than 63 bytes are simply not cached (they still resolve). The A
  record's TTL sits 6 bytes before the RDATA and the 1.35.0 parser had been discarding it; now recorded into
  `dns_last_ttl` and CLAMPED to **[10 s, 3600 s]** — the floor defends against 0-TTL thrash, the ceiling means even
  a misbehaving authoritative TTL self-heals within an hour (the kernel has no cache-flush verb). POSITIVE-ONLY.
  Gates `dns: parse PASS` + `dns: cache PASS`, `dns-smoke.sh` 3/3.

## [1.35.5] — 2026-05-27 — RTC boot clock (CMOS read + `civil_to_unix`)
- MC146818 via ports 0x70 (index) / 0x71 (data). Registers: 0x00 seconds · 0x02 minutes · 0x04 hours · 0x07 day ·
  0x08 month · 0x09 year (2-digit) · 0x32 century · 0x0A Status A bit7 = UIP · 0x0B Status B bit1 = 24h, bit2 =
  binary (else BCD). BCD is the default on most BIOSes (`0x59` means 59: decode `(v & 0x0F) + (v >> 4) * 10`); in
  12h mode bit 7 of hours is the PM flag. UIP is set ~244 µs before each update; the wait MUST be bounded (real
  chips can leave UIP asserted).
- `civil_to_unix` uses the branch-free days-from-civil algorithm. Gates (`rtc: clock PASS`): 2024-01-01 =
  **1704067200**, +3661 s = 01:01:01, 2024-03-01 leap boundary = **1709251200**, epoch = 0, BCD decode `0x59` → 59.
- Clock model: `net_clock_seed_rtc()` sets `net_unix_time`, `net_ntp_synctick = timer_ticks`, `net_ntp_synced = 1`,
  `net_clock_source = 1` (RTC) if not already NTP-synced; a later `ntp_sync` overrides and sets source 2 (NTP wins).
- cyrius pin 6.0.1 → 6.0.3 after a byte-for-byte A/B: identical `build/agnos`, same sha256, **822,864 B**.

## [1.35.4] — 2026-05-27 — `munmap` (syscall 28)
- Validates 2 MB alignment and containment in `[0x10000000, 0x40000000)`, walks PML4→PDPT→PD once, recovers `phys =
  entry & ~0x1FFFFF`, calls `proc_unmap_page` (clearing the entry in BOTH the kernel and the KPTI user PD),
  `invlpg`s the vaddr — otherwise the live process keeps a stale TLB entry into now-freed physical, a use-after-free
  — then `pmm_free_2mb`. Not-present regions are skipped (idempotent, no double-free). LIFO vaddr reclaim rewinds
  the cursor when `addr + len == mmap_next_vaddr`. Gate `munmap: pmm-reuse PASS`.

## [1.35.3] — 2026-05-27 — anonymous `mmap` (syscall 27), 2 MB-granular
- The first new FUNCTIONAL syscall since v1.21.0. ⚠ AGNOS user memory is 2 MB huge pages ONLY — there is no 4 KB PT
  level for user mappings (`proc_map_page` writes a PD entry as `phys | 0x87`), so the smallest mmap is one 2 MB
  huge page and `mmap(4096)` returns a 2 MB region. Inherent to the VMM, not a v1 shortcut.
- `pmm_alloc_2mb` scans the 4 KB-page bitmap for 512 contiguous free pages aligned to 2 MB, marks them used, returns
  the 2 MB-aligned base (0 on failure); `pmm_free_2mb` clears all 512 and refuses misaligned / out-of-range /
  kernel-region addresses.
- Low arena: cursor `mmap_next_vaddr` starting at **0x10000000 (256 MB)**, +2 MB per page, ceiling **0x40000000 (1
  GB)** — the per-process PD covers 0-1 GB, code sits at ~2-34 MB and per-pid stacks at `0x800000 + pid*0x400000`,
  so 256 MB–1 GB is clear: PD slots 128..511, ~768 MB usable. Slot 26 was already taken by
  `write_boot_checkpoint(byte)`.
- ⚠ The CVE-2026-31431 structural-immunity argument is anchored on the ABSENCE of the AF_ALG / socket / splice
  syscalls, not on a raw syscall-table-size invariant — adding a pure memory syscall does not affect it.

## [1.35.2] — 2026-05-27 — NTP/SNTP client: the kernel's first wall clock
- 48-byte UDP/123 packet. Byte 0 for a request = `0x1B` (LI 0, VN 3, Mode 3 client); the response must carry Mode 4
  (`byte0 & 0x07 == 4`). Field offsets: LI/VN/Mode(0), Stratum(1), Poll(2), Precision(3), Root Delay(4-7), Root
  Dispersion(8-11), Reference ID(12-15), Reference Timestamp (16-23), Origin(24-31), Receive(32-39), **Transmit
  Timestamp(40-47) — THE ANSWER** (32-bit seconds big-endian at 40-43 since the NTP epoch 1900-01-01, plus a
  fraction at 44-47 that v1 ignores). `unix_seconds = ntp_seconds - 2208988800`.
- Wall clock: `ntp_now() = net_unix_time + (timer_ticks - net_ntp_synctick) / 100` — free-running, disciplined only
  at sync time, no slewing. Accuracy ≈ the one-way network delay.
- Gate `ntp: parse PASS`: a synthetic response whose offset-40 u32 = **3913056000** (NTP) must return **1704067200**
  (Unix, 2024-01-01 00:00:00 UTC). SLIRP has no NTP server, so live sync is iron-only.

## [1.35.1] — 2026-05-27 — ✳ cycle open: TCP hardening B0–B4
- B0: conn entry grown **80 → 128 bytes** (16 slots). Pre-existing offsets 0-72 preserved: state(0) src_port(8)
  dst_port(16) dst_ip(24) seq_num(32) ack_num(40) rx_buf(48) rx_buf_len(56) rx_buf_head(64) flags(72) — all ten u64
  slots were used, so hardening had to grow it. Added SND.UNA, SND.WND, `rx_read`, and reserved retransmit slots
  (seq / len / tick / count).
- B1 (the keystone): a **2048-byte** per-conn in-order receive ring. ESTABLISHED accepts only `seq == RCV.NXT`,
  appends, advances RCV.NXT, cumulative-ACKs; out-of-order or old segments get a re-ACK of the gap (NO reassembly
  queue in v1). Advertised window = REAL ring free space. Gate `tcp: ring PASS`. This replaced a path that OVERWROTE
  the 256-byte buffer with each segment and set `rx_buf_len` to just that segment, silently truncating ANY
  multi-segment transfer.
- B2: one-in-flight retransmit of SYN / data / FIN. `tcp_retx_rto` = **1 s base, ×2 per retry, capped at ×16**; give
  up → CLOSED after **5 retries**; `tcp_connect` polls an ~8 s deadline. Gate `tcp: retx PASS`.
- B3: `tcp_write_mss_opt` emits the MSS option (kind 2, len 4, value **1460**) on SYN and SYN-ACK; `tcp_eff_mss` =
  min(ours, peer's, **536** if absent); `tcp_send` segments into ≤ eff-MSS chunks. Byte-exact option emit `02 04 05
  B4`. Gate `tcp: mss PASS`.
- B4: the peer's window is captured from EVERY inbound segment at the top of `net_handle_tcp` (so the SYN-ACK's
  initial window counts); `tcp_send_chunk` sizes each segment `min(remaining, MSS, window)`; a zero window triggers
  a 1-byte persist probe. Gate `tcp: wnd PASS`. (G3 was: `tcp_send_pkt` hardcoded the advertised window to 8192
  while the receive buffer held 248.)
- Explicitly OUT OF SCOPE after B0-B4: congestion control (cwnd / slow-start / NewReno / CUBIC), SACK, window
  scaling, timestamps, RTT-estimated RTO, TIME_WAIT / 2MSL, a multi-segment pipelined queue.

## [1.35.0] — 2026-05-27 — DNS stub resolver + ICMP echo/ping + a full documentation sweep
- DNS header is 12 bytes, all multi-byte fields BIG-ENDIAN: ID(2), flags(2), QDCOUNT(2), ANCOUNT(2), NSCOUNT(2),
  ARCOUNT(2). Query flags `0x0100` (RD=1). Response validation: QR=1, RCODE=0, ANCOUNT ≥ 1; TC=1 is treated as
  failure (no TCP fallback in v1). QNAME is length-prefixed labels terminated by a zero byte; each label ≤ 63 bytes,
  total ≤ 255. QTYPE A=1, CNAME=5, PTR=12, AAAA=28; QCLASS IN=1. NAME COMPRESSION: a length byte with the TOP TWO
  BITS SET (`0xC0`) is a pointer whose low 14 bits are an offset from the START OF THE MESSAGE; a stub that only
  wants the A RDATA never needs to decompress, only to SKIP.
- Resolver address: RFC 2132 option 6. The DHCP client already REQUESTED option 6 but the ACK handler parsed only
  options 1 and 3 and DROPPED it — now captured into `net_dns_server`. QEMU SLIRP hands out `10.0.2.3`.
- v1 policy: one in-flight blocking query, no cache initially, no TCP fallback, no EDNS0 (512-byte UDP floor), no
  client-side CNAME chasing (a well-behaved recursive resolver returns the final A record in the SAME response),
  anti-spoof floor = transaction ID match plus the bound source port.
- Gates: `dns: parse PASS` (a hand-built compression-pointer response parses back to `93.184.216.34`), `dns:
  resolver=10.0.2.3`; live path resolved `example.com → 172.66.147.243`.
- Production build 798,936 → **810,560 B** across the two bites.

## [1.34.6] — 2026-05-26 — ESP-write safety guard (1.34.x arc cap)
- FAT/exFAT refuse writes to an ESP-type GPT partition so the boot ESP cannot be corrupted; `FAT_ALLOW_ESP_WRITE` is
  the compile override for QEMU test images.

## [1.34.5] — 2026-05-26 — exFAT Unicode names: real up-case table for NameHash + case-fold
- Build 788,696 → **798,648 B**. `exfat-write-smoke.sh` creates `Café.txt` (byte `0xE9`) → `fsck.exfat -n` CLEAN
  (fsck recomputes the NameHash with the volume up-case table and it matches).

## [1.34.4] — 2026-05-26 — directory growth: root extension + cross-boundary dir-set append
- Both filesystems previously placed each dir-set within a single sector and refused once the root filled. Build
  783,240 → **788,696 B**. Deleted-slot reuse deferred (directories grow append-only).

## [1.34.3] — 2026-05-26 — FAT LFN/truncate completeness
- Build 772,568 → **783,240 B**; `fsck.fat -n` clean throughout.

## [1.34.2] — 2026-05-26 — exFAT write parity
- Build 768,024 → **772,568 B**. Overwrite EXDATA.BIN 3000→2000 byte-exact, arbitrary truncate 2000→1000, ENOSPC (a
  100 MB request on a 67 MB volume) → rc≠0 + file intact.

## [1.34.1] — 2026-05-26 — exFAT: mount + read, then write (create / content / delete / truncate)
- exFAT Main Boot Sector: `JumpBoot`@0 = `EB 76 90`; `FileSystemName`@3(8) = `'EXFAT '` (the probe signature);
  `MustBeZero`@11(53); `PartitionOffset`@64(8); `VolumeLength`@72(8); `FatOffset`@80(4); `FatLength`@84(4);
  `ClusterHeapOffset`@88(4); `ClusterCount`@92(4); `FirstClusterOfRootDirectory`@96(4); `VolumeSerialNumber`@100(4);
  `FileSystemRevision`@104(2) = `0x0100`; `VolumeFlags`@106(2, bit1 = VolumeDirty); `BytesPerSectorShift`@108(1,
  log2, 9 = 512); `SectorsPerClusterShift`@109(1); `NumberOfFats`@110(1); `DriveSelect`@111; `PercentInUse`@112;
  `BootCode`@120(390); `BootSignature`@510 = `0xAA55`. ⚠ `MustBeZero`@11(53) is exactly where a FAT BPB would be,
  which is why fatfs self-excludes exFAT: it reads `BytsPerSec`@11, gets 0, and rejects. The two drivers coexist
  safely.
- Entry types: `0x81` Allocation Bitmap · `0x82` Up-case Table · `0x83` Volume Label · `0x85` File · `0xC0` Stream
  Extension (bit0 AllocationPossible, bit1 **NoFatChain**; `[3]` NameLength, `[4:6]` NameHash, `[8:16]`
  ValidDataLength, `[20:24]` FirstCluster, `[24:32]` DataLength) · `0xC1` File Name (15 UTF-16 chars). A file is a
  SET: one `0x85` + one `0xC0` + `ceil(NameLength/15)` `0xC1`, contiguous, `SecondaryCount = 1 +
  ceil(NameLength/15)`. `SetChecksum` (16-bit) skips byte indices 2 and 3; `NameHash` (16-bit) is over the up-cased
  UTF-16; both use `chk = ((chk << 15) | (chk >> 1)) & 0xFFFF + byte`. Boot checksum (32-bit) over sectors 0..10
  SKIPS offsets 106, 107 and 112.
- Build 740,272 → **759,256 B** (read) → **768,024 B** (write).

## [1.34.0] — 2026-05-26 — ✳ opens the additional-filesystems arc: FAT read parity + FAT write
- FAT type is determined ONLY by `CountOfClus` — the Microsoft spec is emphatic that no other field decides it: <
  4085 → FAT12, < 65525 → FAT16, else FAT32. It must be COMPUTED, never guessed from `RootEntCnt`.
- Four gaps the pre-1.34.0 driver had, found by reading the 249-line `fatfs.cyr` rather than its comments:
  `fatfs_init()` was wired ONLY inside the VirtIO-blk branch, so on real iron it NEVER RAN; it was whole-disk
  absolute-LBA-0 only (on a GPT disk it reads the protective MBR, sees `0x55AA` but `BytsPerSec`@11 = 0, and bails);
  `fatfs_fat_buf[64]` was DECLARED BUT NEVER USED — there was no FAT-chain traversal at all, and `fatfs_open` capped
  the memfile at 512 bytes; and it was FAT16-only (FAT32 sets `FATSz16=0` and `RootEntCnt=0`, so the ESP and most
  USB sticks mis-parsed entirely).
- Build ladder 712,504 → 722,064 (read parity) → 724,048 (3a create) → 729,232 (3b cluster allocator + multi-cluster
  content) → 731,072 (3c delete + truncate) → 738,272 (3d LFN create) → **740,272 B** (3e overwrite + arbitrary
  truncate + ENOSPC rollback).

## [1.33.5] — 2026-05-26 — the `fsync` / FLUSH-CACHE durability barrier
- Device flush opcodes per transport: NVMe FLUSH = NVM opcode `0x00` (NSID 1, no PRP, CDW10-15 = 0); ATA via AHCI =
  FLUSH CACHE EXT `0xEA` (`0xE7` is the 28-bit form); SCSI via USB-MS BBB = SYNCHRONIZE CACHE(10) `0x35` (`0x91` is
  the 16-byte variant); VirtIO-blk = `VIRTIO_BLK_T_FLUSH` type 4 gated on `VIRTIO_BLK_F_FLUSH` bit 9; RAM-disk =
  n/a.
- ⚠ A cache flush is NOT bounded by the normal-I/O timeout — ATA8-ACS permits FLUSH CACHE EXT to take tens of
  seconds (up to ~30 s). The flush path needs its own `*_FLUSH_TIMEOUT_SPINS`; a flush that reports timeout when the
  drive simply needed 3 s would be a false durability failure. A device with no writeback cache may answer
  SYNCHRONIZE CACHE with CHECK CONDITION / INVALID COMMAND OPCODE — treat that as benign.
- `ext2_sync()` sets EXT2_VALID_FS, clears `ext2_fs_dirty`, writes the superblock, THEN calls
  `blk_flush_on(ext2_backend)`.
- Build 707,896 → 710,328 → **712,504 B**.

## [1.33.4] — 2026-05-26 — interactive-lockup fix + uninit_bg materialization + symlink resolution
- Bite 1: HID keyboard transfer-ring Link TRB, reproduced and verified off-iron with `scripts/lockup-repro.sh` +
  `lockup-driver.py` (gnoboot+OVMF, `qemu-xhci` + `usb-kbd`, commands typed over QMP `sendkey`).
- ⛔ WRONG POSTURE, corrected: "refuse write if the group is uninit". A default `mkfs.ext4` does NOT set the
  gdt_csum/uninit_bg ro_compat bit `0x10` (that is the legacy crc16 feature, still refused, different algorithm) but
  it DOES set INODE_UNINIT / BLOCK_UNINIT `bg_flags` under metadata_csum. Because the real partition has
  metadata_csum and not gdt_csum it was already write-enabled, so the refusal never fired and allocating into an
  un-materialized bitmap was a LATENT CORRUPTION RISK. Fix: `ext2_materialize_inode_bitmap` /
  `ext2_materialize_block_bitmap` write the correct all-free-plus-padding bitmap (safe because flex_bg relocates all
  metadata to leader groups, so an uninit group is genuinely empty) and clear the flag on first allocation, with a
  has_super / in-group-metadata guard. Verified on a ~1.1 GiB flex_bg image (9 groups: 8 INODE_UNINIT, 3
  BLOCK_UNINIT), `e2fsck -fn` clean.

## [1.33.3] — 2026-05-25 — dirent-mutation follow-ons: rename / hardlink / symlink / `s_state`
- `mv` (cross-parent dir move + refuse cases), `ln` (hardlink → unlink one name → the other survives, nlink 2→1; dir
  hardlink refused), `ln -s` (fast inline-target symlink with `i_blocks=0` and slow data-block target), and
  `s_state` dirty/clean + the `sync` verb. All verified on the `metadata_csum,64bit,extent` profile with `e2fsck
  -fn` clean.

## [1.33.2] — 2026-05-25 — lockup hardening: bounded serial poll + bench memory guards

## [1.33.1] — 2026-05-25 — ext2/ext4 WRITE on a REAL default `mkfs.ext4` partition (metadata_csum + 64bit)
- ⭐ W5 IRON BURN PASS 2026-05-25: `echo > /persist.txt` → **POWER-CYCLE** → `agnos> ls` returns `./ ../ lost+found/
  hello.txt welcome.txt agnos/ persist.txt` on the UNMODIFIED default `mkfs.ext4` agnos-fs partition, with no
  re-carve. GPT showed `[0] EFI System AGNOS-BOOT` 255 MiB and `[1] Linux FS agnos-fs` 25600 MiB; `ext2: probe
  matched backend=2 partition_lba=524280` → mounted blocksize=4096 inode_size=256 inodes_per_group=8192 with
  `write_ok=1`. Production build **675,152 B**.
- The validation method that made the burn safe: a compute-and-compare pass with writes still gated reproduced, for
  EVERY checksum class, the value e2fsprogs had ALREADY written on disk — superblock, group descriptor, block
  bitmap, inode bitmap, inode and dir leaf all matched, and the UUID-derived `csum_seed` matched the host.
- ext4 metadata checksums use **CRC32c (Castagnoli, poly `0x1EDC6F41`, reflected `0x82F63B78`)** — NOT the IEEE
  CRC32 (`0xEDB88320`) `gpt.cyr` implements. e2fsprogs `ext2fs_crc32c_le` has NO implicit init and NO final XOR — a
  pure running update. Self-test vector: **`crc32c(~0, "123456789", 9) = 0x1CF96D7C`** (the raw non-finalized value;
  the standard finalize-and-reflect value `0xE3069283` is NOT what this code produces).
- `csum_seed`: if incompat CSUM_SEED (`0x2000`) is set → `s_checksum_seed` at SB offset `0x270`; else
  `ext2_crc32c(0xFFFFFFFF, &s_uuid, 16)` with `s_uuid` at SB offset `0x68`. Default mkfs.ext4 does NOT set
  CSUM_SEED. Mount computed `csum on=1 seed=e25418d4`, matching the host.
- Checksum recipes — SUPERBLOCK: seed `~0` (NOT csum_seed), span bytes `[0, 0x3FC)`, store 32 bits at
  `s_checksum`@0x3FC. GROUP DESCRIPTOR: seed csum_seed then the group number as LE32, span `desc[0, 0x1E)` then TWO
  LITERAL ZERO BYTES in place of `bg_checksum`, then (64bit only) resume at `0x20` for `desc_size-0x20`; store low
  16 at `0x1E`. BLOCK BITMAP: seed csum_seed, span `(blocks_per_group+7)/8` bytes, store `0x18` lo / `0x38` hi.
  **INODE BITMAP: span `(inodes_per_group+7)/8` — NOT blocksize.** This is the #1 silent trap: for ipg=8192 the span
  is 1024 B while the block is 4096 B, and the block bitmap's span happens to equal the full 4096-B block for
  bpg=32768, so the two look like they should match and do not. Store `0x1A` lo / `0x3A` hi. INODE: seed csum_seed
  then ino# LE32 then `i_generation` LE32, span the full `inode_size` with `i_checksum_lo`@0x7C and
  `i_checksum_hi`@0x82 zeroed during the CRC; store hi only if `i_extra_isize >= 4`. DIRECTORY LEAF: seed csum_seed
  then dir-ino# LE32 then dir `i_generation` LE32, span dirents `[0, blocksize-12)` plus the tail's first 8 bytes;
  store 32 bits at `blocksize-4`.
- `struct ext4_dir_entry_tail` (12 B at the end of every leaf dir block): `det_reserved_zero1`(4)=0,
  `det_rec_len`(2)=12, `det_reserved_zero2`(1)=0, `det_reserved_ft`(1)=**0xDE**, `det_checksum`(4). Under
  metadata_csum, usable directory space is `blocksize-12`.
- 64BIT write turned out to be nearly a no-op (~25-30 LOC, not the ~200 the scoping doc estimated): on this box
  every `_hi` half is genuinely 0, the `_hi` halves are preserved untouched by the whole-BGDT-block
  read-modify-write, and the `desc_size` stride in `ext2_grp_off` was already correct. The only real work was
  lifting the `incompat & 0x80` refusal.
- Build ladder 667,128 → 667,440 → 669,072 → 671,552 → 672,992 → 674,640 → **675,152 B**.

## [1.33.0] — 2026-05-25 — ✳ ext2/ext4 WRITE arc OPEN (the demo→base maturity exit)
- W1 write primitives + metadata write-back (**629,568 B**) · W2 block + inode allocators + write-safety gate
  (**640,848 B**) · W3 file-data write + sparse allocation + truncate (**648,016 B**) · W4a directory mutation +
  create/unlink (**654,384 B**) · W5 mkdir/rmdir (**659,408 B**) · W4b VFS write arm + shell write verbs (**666,840
  B**).
- Write-safety rule without a journal (converged across FreeBSD `ext2_alloc.c`, the ext2 design papers and the
  e2fsprogs fsck-recovery model): **write the thing being POINTED TO before the POINTER, and the ALLOCATION BIT
  before the USE.** A crash then leaks resources (fsck reclaims) but never dangles a pointer. Commit orders — append
  block: bitmap-set → data → (indirect) → inode → BGDT count → SB count. Free block: inode-clear-ptr →
  (indirect-clear) → bitmap-clear → BGDT → SB. Create file: inode-bitmap-set → inode-init → dirent-insert → counts.
  Unlink: dirent-remove → links-- → (if 0) free blocks → inode-bitmap-clear → counts. Mkdir: inode-bitmap-set →
  alloc dir block (bitmap + data with `.` and `..`) → inode-init → parent links++ → dirent-insert → counts +
  used_dirs++. ACCEPTED failure mode: leaked blocks/inodes or a stale free count, all `e2fsck -fy` fixable.
  FORBIDDEN: a live inode pointer to a block whose bitmap bit is clear, or two inodes on one block.
- Inode write-back must be read-modify-write at BLOCK granularity — never write a bare `inode_size` slice, or you
  clobber adjacent inodes sharing the block. `i_links_count` on create: a regular file starts at 1; a directory
  starts at 2 and the parent goes +1.
- Dirent remove does NOT shift bytes: coalesce the victim's `rec_len` into the previous entry; if the target is
  first in its block, tombstone it (`inode = 0`).
- htree posture: if a dir inode has INDEX_FL (`i_flags & 0x1000`), on first insert CLEAR INDEX_FL and treat it as
  linear — e2fsck rebuilds the index with a benign warning.
- The arc's biggest audit finding: the block-device WRITE primitives already existed and were iron-validated, so
  this was purely the ext2 metadata layer above an already-working block writer — zero driver work, zero DMA work.
- The 1.33.0 iron burn's write failure was NOT a bug: the W2 safety gate fired exactly as designed on a
  metadata_csum + 64bit filesystem (`ext2w: read-only FS -- write checks skipped`).

## [1.32.9] — 2026-05-25 — DHCP re-enabled; a real lease on iron (networking arc CLOSED)
- IRON 2026-05-25 ~17:50 PDT: `dhcp: DISCOVER` → `dhcp: OFFER ip=192.168.1.142` → `dhcp: REQUEST` → `dhcp: ACK
  ip=192.168.1.142 gw=192.168.1.1 mask=255.255.255.0` → `arp: request -> gateway` → `arp: REPLY
  gw_mac=d4:6a:91:ce:70:60` → `net: L2 OK -- gateway MAC cached` → `AGNOS shell v1.32.9`. `.142` is a REAL lease,
  not the `.222` static fallback. The DHCP code was UNCHANGED from the 1.32.0 RFC-2131 implementation; 1.32.9 only
  re-enabled the `dhcp_init()` call site.
- Fixed: network-path logging printed base-16 values in decimal. Production **623,816 B** (+552).

## [1.32.8] — 2026-05-25 — networking closeout cleanup
- Boot net diagnostics gated behind `NET_VERBOSE`; the shell net commands de-hardcoded for iron; the `.121`
  on-LAN-peer discriminator scaffolding removed. Production **623,264 B** (−1,224).

## [1.32.7] — 2026-05-25 — 🎯 r8169 unicast RX SOLVED: the RX ring was 16 deep
- ⭐ ROOT CAUSE of the entire 1.32.x r8169 unicast-RX failure (~13 iron burns): **RX RING DELIVERY CAPACITY.**
  `R8169_RX_RING_SIZE` = 16 was the outlier against all prior art (Linux `NUM_RX_DESC` = 256, FreeBSD/OpenBSD 256).
  LAN broadcast/multicast chatter overran the 16-deep ring between `hlt`-spaced polls → RxMissed FIFO overflow →
  clean unicast frames (gateway ARP reply, TCP SYN+ACK, DHCP OFFER/ACK) dropped for want of a free descriptor.
- ⭐ THE FIX (bite-5): RX ring **16 → 64** (64×16 = 1024 B, still one 4 KB page). `R8169_RING_MASK` (0x0F) split into
  `R8169_RX_RING_MASK` (**0x3F**) + `R8169_TX_RING_MASK` (**0x0F**) since the rings now differ in depth;
  `r8169_rx_bufs[16]` → `[64]`; init_rx loop bound + EOR slot keyed to `R8169_RX_RING_SIZE`; poll error-skip walk
  budget 16 → 64. TX left at 16 (tx_err=0, never overflowed). Build 624,056 → **624,488 B (+432 B)**.
- ⭐ IRON PROOF, the silicon tally line after bite-5: **`r8169: tx_ok=21 rx_ok=103 tx_err=0 rx_err=0 missed=0 align=0
  rx_uc=10 rx_bc=47 rx_mc=46`** with `net: LAN-TCP OK -- on-LAN unicast handshake established` AND `net: L3+TCP OK
  -- outbound TCP handshake established`. **`missed` collapsed 176 → 0.**
- The tally ladder that resolved filter-vs-delivery: bite-3 `tx_ok=5 rx_ok=140 tx_err=0 rx_err=0 missed=158 align=0
  rx_uc=2 rx_bc=82 rx_mc=64` — **`rx_uc=2 > 0` was DISPOSITIVE**: the chip's own silicon counter proved unicast
  frames were ACCEPTED via physical-match, closing the entire L2 accept/filter arc (accept nibble + AAP + CPlusCmd
  Normal_mode + IDR physical-match) by measurement rather than inference, and `missed=158` with `rx_err=0 align=0`
  meant CLEAN frames dropped for no free descriptor. bite-4 (whole-ring drain, budget 64) `tx_ok=9 rx_ok=144
  missed=176 rx_uc=5 rx_bc=74 rx_mc=65` — ⛔ FALSIFIED, `missed` went 158 → **176 (UP)**: a 64-frame drain budget can
  only pull the 16 descriptors that PHYSICALLY EXIST. (The drain loop is correct regardless and was kept.)
- The 1.32.3 `dhcp: OFFER timeout` was THE SAME ring-depth drop, not a DHCP-protocol bug — a DHCP server unicasts
  OFFER and ACK at L2 to the client hardware MAC, exactly the physical-match class the 16-deep ring overflowed.
- Also fixed: the IDR physical-match filter re-asserted post-`CR.RE` (step 11c), build 622,560 → 622,656 B; bite-2's
  on-LAN unicast-TCP discriminator, 622,656 → 623,928 B; bite-3 wired the already-written, never-called
  `r8169_print_stats` / `r8169_dump_stats`, → 623,976 B.

## [1.32.6] — 2026-05-25 — gateway L2 reachability PROVEN on iron (RFC-826 ARP sender-snoop)
- ⭐ THE REAL ARP-LAYER BUG (separate from the ring, and a genuine fix): `net_handle_arp` learned the gateway MAC
  ONLY from a SOLICITED unicast reply (`oper==2` matching the pending request) — a violation of RFC 826, which
  snoops the sender IP→MAC binding from EVERY ARP frame. Fix: snoop the sender from request OR reply, gated on
  `arp_pending_ip`. Because the Araknis gateway broadcasts its own `who-has` frames, the gateway MAC becomes
  learnable with ZERO unicast RX. Zero-burn pre-proof (`arp_snoop_check.cyr`, AF_PACKET, NIC stayed bound to Linux):
  24 ARP frames in 15 s; the gateway appeared as SENDER **10× broadcast + 5× unicast**. IRON-PROVEN same day: `arp:
  REPLY gw_mac=212:106:145:206:112:96` → `net: L2 OK` — the FIRST gateway reachability in the whole arc. Build
  622,496 B.
- ARP retransmit added (~1/sec across the 5 s window, 4 retransmits): AGNOS had sent exactly ONE ARP request and
  never retransmitted, a divergence from ALL prior art. Result `net: L2 RX ALIVE rx=15 arp_in=11 arp_ans=2` — the
  SYSTEMATIC branch fired; transient-elicitation-miss RULED OUT. Build 622,408 → 622,560 B.
- ⛔ FALSIFIED — `rtl_rar_set` write ORDER + a post-`CR.RE` clean RxConfig write (bite-2). Landed: IDR write-back
  reordered to Linux shape (MAC4 high-half first + `rtl_pci_commit` readback, then MAC0 + readback — the low-word
  write latches the 6-byte filter so the high bytes must be resident first) and the post-`CR.RE` RxConfig changed
  from RMW to ONE clean full write (per Linux stable `05212ba8132b`: RxConfig writes while RX-disabled are dropped).
  Build 622,560 → 622,544 B (−16). Result byte-identical: unicast drop isolated BELOW both the accept nibble and the
  IDR filter.
- ⛔ FALSIFIED — CPlusCmd `Normal_mode` (bit 13, `0x2000`), the arc's strongest-looking candidate, derived from the
  live `ethtool -d` dump as the lone source-confirmed never-burned divergence. Burned bite-6 (`0x0008` → `0x2061`,
  RxConfig accept `0x0F` → `0x0E`) → FB byte-identical to the previous burn (`net: L3+TCP FAIL -- SYN sent but no
  SYN+ACK`). Retained as correct (it matches the working Linux dump) but NOT load-bearing.

## [1.32.5] — 2026-05-25 — broadcast + multicast RX PROVEN on iron (post-RX-enable accept re-assert)
- ⭐ THE BROADCAST BREAKTHROUGH (bite-7), the one untried four-source-convergent lever after 7 falsified "RX silent"
  burns: every reference EXCEPT the single FreeBSD branch AGNOS had copied programs the accept filter AT or AFTER
  RX-enable — OpenBSD `re_iff` (RMW post-`CR.RE`), Linux `rtl_set_rx_mode` (post-`hw_start`), Linux stable
  `05212ba8132b` ("RxConfig writes ignored before TX/RX enable"), iPXE (writes RCR after `CR.RE|TE`). AGNOS wrote
  the accept nibble ONLY pre-enable on every burn. Mechanism fit: multicast is programmed via the SEPARATE MAR
  register (which lands) while broadcast/unicast/AAP live in the RxConfig accept nibble (ignored before enable) —
  exactly the observed multicast-passes / broadcast-and-unicast-drop split. Fix = post-`CR.RE` RMW clearing accept
  byte `0x3F` then re-OR `AAP|AB|AM|APM`. Build **621,896 B (+128)**. IRON: AGNOS received the capture host's
  broadcast ARP `who-has 192.168.1.222` and egressed a correct unicast reply.
- The honest L2 RX self-test replaced the flat `net: L1/L2 FAILED` boot print that had concealed a live RX path for
  four days: it counts frames `net_poll()` delivered plus ARP replies the responder TX'd, and on timeout prints
  `net: L2 RX ALIVE rx=N arp_in=M arp_ans=K -- gateway unicast reply pending` (or `... SILENT`). NO driver change
  and NO new instrumentation — it reads `net_poll()`'s existing return code. First burn `rx=10 arp_in=7 arp_ans=1`.
  Build **622,408 B**.
- ⛔ FALSIFIED — RxMaxSize (RMS @0xDA) `0x4000` → `0x05F3`. The theory ("bit-14 sets outside the 13-14-bit RMS field
  → RMS reads 0 → the NIC rejects all inbound frames; TX never consults RMS") matched the TX-works/RX-silent
  signature exactly. Burned 2026-05-24 23:42 → no change, AND internally inconsistent with Attempts 97-99 where
  multicast passed. `0x05F3` = 1523 retained as correct (admits 1518-byte frames). ⚠ Linux deliberately writes 16384
  (`0x4000`) to DISABLE size filtering, comment "Low hurts. Let's disable the filtering."
- ⛔ FALSIFIED — the RXDV-gate settle (clear MISC `0xF0` bit 19, then ~2 ms before `CR.RE`), a very strong candidate:
  Linux pairs the clear with `fsleep(2000)`, OpenBSD has `RL_FLAG_RXDV_GATED`, FreeBSD comments "disable RXDV gate",
  and U-Boot clears it SPECIFICALLY for "DHCP failures after kernel reboots" — archaemenid's exact
  warm-boot-from-Linux signature. Landed as a ~4-8 ms non-posted-MMIO spin (+64 B, 621,704 → 621,768 B). Burned → RX
  still silent.
- ⛔ FALSIFIED — AAP (AcceptAllPhys, RxConfig bit 0), added per iPXE `realtek_open`. Burned Attempt 104 → promiscuous
  accept-all delivered NOTHING. AAP had been PRE-COMMITTED as a BISECTOR, so its falsification branch firing
  EXONERATED the entire L2 accept filter. Corroboration: had AAP engaged, AGNOS would have seen the whole LAN's
  unicast chatter; it saw none. Build 621,704 B (−112 with the FS|LS gate removal).

## [1.32.4] — 2026-05-24 — networking iron-isolation cycle: static-IP + ARP probe
- OUTBOUND L3 ROUTING GAP (real, found this cycle): `udp_send` (`net.cyr:112-124`) and `tcp_send_pkt`
  (`net.cyr:731-758`) BOTH hardcoded `dst_mac = ff:ff:ff:ff:ff:ff` with the comment "For now, use broadcast MAC
  (QEMU user-mode handles it)". Works for DHCP (RFC 2131 mandates broadcast) and for SLIRP; FAILS for off-LAN
  unicast on iron, where the gateway expects the L2 destination to be the GATEWAY's MAC. Classic "works in QEMU,
  fails on iron". Fix shape landed: persistent `net_gateway_mac[8]` + `net_gateway_mac_valid` +
  `route_next_hop_mac(dst_ip, out_mac)`; `udp_send_from` deliberately LEFT as broadcast because DHCP is its only
  caller.
- AGNOS ARP CACHE is a SINGLE SLOT (`arp_cache_ip`, `arp_cache_mac[8]`, `arp_pending_ip`), populated only when a
  REPLY arrives whose sender_ip matches `arp_pending_ip`. No timeout, no replacement policy beyond last-reply-wins;
  there is NO `arp_resolve(ip)` helper.
- Build 617,000 / 617,984 B (1.32.3 close) → **621,816 B** (+4,816 B).

## [1.32.3] — 2026-05-23 — virtio-net modern rewrite (QEMU DHCP full cycle) + the r8169 RX-path audit
- The virtio-net legacy driver had FOUR divergences, all confirmed: (1) six INDEPENDENT module-global arrays at
  linker-determined addresses (`vnet_tx_desc[64]`, `vnet_tx_avail[8]`, `vnet_tx_used[8]`, and the RX trio) while the
  spec fixes ONE contiguous `struct virtq { desc[N]; avail; pad; used; }` — the driver wrote `&vnet_tx_desc / 4096`
  to QUEUE_PFN, so the device computed avail at `desc_base + 16*qsz`, an unrelated BSS symbol, and read `avail.idx
  == 0` forever; (2) sizing — module-scope `var X[64]` = 64 × u64 = 512 bytes = **32 descriptors, not 64**; (3)
  `&vnet_tx_desc` is not page-aligned, so `addr / 4096` truncation put the device's desc base off by `&vnet_tx_desc
  mod 4096`; (4) `tx_qsz = inw(vnet_iobase + 12)` was read and NEVER USED.
- ⛔ THE BUG THE AUDIT MISSED, found during implementation: PCI bus-master was never enabled on the virtio device.
  BAR0 I/O-port writes work WITHOUT bus-master; descriptor reads from system RAM do not. One-line fix matching the
  existing nvme/ahci/virtio_blk pattern.
- Feature-negotiation trap: the driver wrote back ALL device features unfiltered. `VIRTIO_NET_F_MRG_RXBUF` (bit 15),
  which QEMU advertises BY DEFAULT on legacy, grows the virtio-net header from 10 to 12 bytes while AGNOS hardcodes
  `hdr_len = 10`, so accepting it makes every frame off-by-2; `VIRTIO_NET_F_CTRL_VQ` (bit 17) exposes a THIRD queue
  AGNOS never configures. MVP mask: `VIRTIO_NET_F_MAC` (bit 5) only.
- RX secondary bug: the descriptor was only ever re-posted to slot 0, so after the layout fix RX would work for the
  first packet then quietly stop.
- ⛔ FALSIFIED AND DELETED — the full Linux `rtl_hw_start_8168h_1` chip-MCU init body (~250 LOC: EPHY 6-entry table,
  FIFO sizes, pause thresholds, ASPM entry latency, ERI `0xDC`/`0x5F0`/`0xC0`/`0xB8`/ `0x1B0`, DLLPR PFM_EN +
  TX_10M_PS_EN clears, MISC_1 PFM_D3COLD_EN clear, PCIe L2/L3 disable, 4× `mac_ocp_modify` + 4× `mac_ocp_write`
  `0xfc2a..0xfc36`). Killed by 4-source convergence: iPXE `realtek.c` does ZERO MAC-OCP/EPHY/ERI writes and works
  for PXE/DHCP; FreeBSD `if_re.c` has ZERO `rl_ephy_write`/`rl_eri_write`/`rl_mac_ocp_write` anywhere; OpenBSD and
  NetBSD both drive an explicit 8168H/8111H hwrev to working RX with generic PHY-wake only. Build 622,616 →
  **617,192 B (−5,424 B; ~280 LOC deleted)**. CONFIRMED CORRECT TO DELETE — do NOT reopen.
- ⚠ RETRACTED METHODOLOGY: "for chips Linux supports per-revision, prefer the Linux per-rev dispatch over BSD's
  collapsed init" was written as a lesson after Attempt 99 and is WRONG. The correct precedent: when porting a
  per-revision Linux dispatcher, FIRST check whether iPXE plus two or more BSDs converge on a simpler shape; if they
  do, port the BSD/iPXE shape, because those are spec-derived rather than empirically accreted.
- ⚠ UNRESOLVED RESIDUAL: virtio-net STILL FAILS in QEMU after the layout + bus-master + RX-slot fixes (148 → 174
  LOC). Confirmed state: `vnet_tx_base = 0x17B000` (page-aligned), `vnet_tx_qsz = 256`, layout offsets spec-exact,
  device `status=7` (legacy DRIVER_OK), bus-master ON, and `qemu -trace virtio_*` confirms the doorbell REACHES the
  device (`virtio_queue_notify vdev=<net> n=0`) — but `virtio_net_handle_tx` never fires and the pcap captures zero
  AGNOS frames. Candidate next steps: (1) verify `store16(avail.idx,…)` commits before the `outw(notify,0)`; (2)
  diff against the WORKING virtio-blk I/O-port sequence; (3) a modern virtio-net driver (device id `0x1041`, ~400
  LOC); (4) an e1000 driver (~300 LOC).
- Build trajectory: 604,096 (1.32.1) → 605,056 (1.32.2) → **617,000 B** (+11,944).

## [1.32.2] — 2026-05-23 — sweep-hardening DHCP fixes (FIXes 7-9)
- Build **605,056 B** (+960). `tcp-listen-smoke` 1/2 matches the pre-fix 1.32.0 baseline — scenario 1 is the
  pre-existing SLIRP-inbound gap (under QEMU user-mode networking, DHCP DISCOVER egresses fine but the OFFER never
  arrives, and TCP accept-success cannot pass), iron-only.

## [1.32.1] — 2026-05-22 — the six-fix DHCP wiring bundle (five of six were shots in the dark)
- ⭐ FIX #1 (genuinely needed): `nic_mac(out_buf)` in `r8169.cyr`, parallel to `nic_ready`/`nic_send`/ `nic_poll`,
  threaded through SEVEN egress sites that had consumed `vnet_mac` as the kernel's authoritative source MAC —
  `arp_request` Ethernet src (`net.cyr:92`), `arp_request` ARP sender HW (:97), `udp_send` (:116), `udp_send_from`
  (:130), **`dhcp_build_packet` chaddr (:264)**, ARP-reply sender HW (:429), `tcp_send_pkt` (:635). `vnet_mac` is
  declared at `virtio_net.cyr:5` and written ONLY at `virtio_net.cyr:69`, so on iron with r8169 active and virtio
  absent it stayed at module-default ZEROS.
- ⛔ THE 1.32.1 → 1.32.2 REGRESSION, the most expensive self-inflicted wound in the arc: FIX #3 unconditionally wrote
  `BMCR.ANRESTART` (bit 9) on EVERY probe. ANRESTART forces the PHY autoneg state machine back to start; the link
  goes DOWN for 1-3 seconds while renegotiation runs. The kernel then raced forward (non-blocking) through
  `r8169_init_rx` → `r8169_init_tx` → scheduler → `dhcp_init` within ~100 ms, all with the link DOWN — and some
  RTL8168 variants WEDGE their internal TX/RX engines when `CR.RE`/`CR.TE` are set while link is down. Evidence:
  Attempt 94 CMOS `0x5B=0x30` / `0x5E=0x01` (both paths working) → Attempt 95 CMOS `0x5B=0xb0` (TX OWN STUCK) /
  `0x5E=0x00` (NO RX DMA AT ALL).
- ⭐ FIX #10 (the correct shape): read BMSR FIRST with a DOUBLE read — BMSR bit 2 Link Status is LATCHING-LOW per
  IEEE 802.3 §22.2.4.2, so the first read clears the latch and the second returns live state — and if link is UP,
  log and return WITHOUT touching BMCR, preserving the BIOS-established link; only if link is down kick
  `BMCR.ANRESTART`. Every reference treats autoneg restart as a STATE-CHANGE event (resume, media change, link
  drop), never a probe-time default. Result: `r8169: PHY link up (preserved from BIOS)`, CMOS `0x59 = 0x01`.
- ⛔ THE BUSY-WAIT ARITHMETIC ERROR that produced a FALSE NEGATIVE: `r8169_phy_init` looped 300 times, each iteration
  one BMSR read plus `for (j = 0; j < 100000; j++) {}`. The comment claimed ~10 ms per outer iteration → ~3 s total.
  On Zen at ~3.5 GHz an empty cmp+jne+inc loop runs ~1 cycle/iter: 100,000 iters ≈ **28 microseconds**, not 10 ms.
  Real budget = 300 × 28 µs ≈ **8.4 ms**, not 3 seconds — off by ~100×-360×, against a real gigabit copper autoneg
  of 1.5-3 s (IEEE 802.3 cl. 28). So CMOS `0x59 = 2` "autoneg timeout" was a FALSE NEGATIVE; the link was up.
- CMOS discriminator slot map (r8169 took the virgin gap 0x58-0x5F): **0x58** probe done · **0x59** PHY outcome
  (0=not attempted, 1=link up/kicked, 2=autoneg timeout, 3=BMCR-write timeout, 4=BMSR-read timeout, 0xFF=pre-init
  sentinel) · **0x5A** `r8169_send` invocation count (saturating) · **0x5B** TX desc 0 high status byte · **0x5C**
  `r8169_poll` invocation count · **0x5D** RX desc 0 high status byte · **0x5E** first byte of RX desc 0's buffer ·
  **0x5F** reserved. Decode: 0x5E `0x01` = IPv4 multicast `01:00:5e:` (also LLDP/STP), `0x33` = IPv6 multicast,
  `0xFF` = broadcast, `0xB0` = unicast to AGNOS's own MAC. 0x5B/0x5D: `0x80` = OWN still set, `0x30` = FS+LS with
  OWN cleared (healthy), `0x72` = EOR+FS+LS+BAR, `0x78` = EOR+FS+LS+MAR.
- ⚠ MEASURED CMOS-STAMP PERFORMANCE TAX in `r8169_poll`: each `xhci_cmos_stamp` is an `outb 0x70; outb 0x71`
  sequence ≈ **2 µs** on Zen; the poll path did 4 of them plus 2 MMIO reads and a DRAM read per call = **8-10 µs per
  `r8169_poll` call**. At 1 Gb/s the chip DMAs a 1500-byte frame in ~12 µs — the instrumentation is the SAME ORDER
  as frame arrival.
- Build 601,392 → **603,784 B** (+2,392).

## [1.32.0] — 2026-05-22 — ✳ networking arc: TCP/UDP server primitives + DHCP client + r8169 Phases 1-4
- Fixed the DHCP gate predicate (`main.cyr:655`): it gated `dhcp_init()` on `if (vnet_active != 0)` (virtio-net
  only), so on real iron with r8169 `vnet_active == 0` permanently and the gate never fired. Now `if (vnet_active !=
  0 || nic_ready() != 0)`.
- HARDWARE ANCHOR: archaemenid NIC = Realtek `10ec:8168` rev `0x15` at PCI BDF `0000:01:00.0`, Linux iface `enp1s0`,
  MAC `b0:41:6f:0c:e4:25` (decimal `176:65:111:12:228:37`), Subsystem ID `10ec:0123`. Chip = RTL8168h/8111h, XID
  541, `RTL_GIGA_MAC_VER_46`, IRQ 85; AGNOS-read chip-rev byte `0x87`; ethtool header `Unknown RealTek chip
  (TxConfig: 0x57100f80)`. BARs: BAR0 I/O `0xF000` (256 B); **BAR2 MMIO `0xFCF04000` (4 KB, 64-bit) = decimal
  4243603456** — the driver target; BAR4 MMIO `0xFCF00000` (16 KB, MSI-X table). ⚠ The pre-burn audit predicted
  `found at 4243210240`, which is WRONG (= `0xFCEA4000`); the iron print read 4243603456, byte-matching sysfs.
- LAN topology: gateway Araknis `192.168.1.1` MAC `d4:6a:91:ce:70:60`, netmask `255.255.255.0`. AGNOS static
  fallback `192.168.1.222`; real leases `.142` (1.32.9) and `.195` (1.51.7). On-LAN test peer MacBook Pro
  `192.168.1.121` MAC `42:c2:df:db:ee:78`.
- LIVE-LINUX WORKING REGISTER GROUND TRUTH (`ethtool -d enp1s0`, zero-burn, unicast RX fully working): IDR0-5
  `b0:41:6f:0c:e4:25`; MAR (0x08) `40 08 40 02 82 00 c1 00`; ChipCmd/CR (0x37) = `0x0C` (TE|RE); IMR (0x3C) =
  `0x002F`; TxConfig (0x40) = `0x57100F80`; **RxConfig (0x44) = `0x0002CF0E`**; Cfg9346 (0x50) = `0x10`; Config2
  (0x53) = `0xBC`; **CPlusCmd (0xE0) = `0x2061`**; MISC (0xF0) = `0x0000003F`.
- r8169 register map (RTL8168h MMIO): IDR0-5 @0x00 (4-byte-access only per datasheet §2.1) · MAR @0x08 (8 B) · DTCCR
  CounterAddrLow @0x10 (bit3 CounterDump = 0x8, bit0 CounterReset = 0x1), High @0x14 · ChipCmd/CR @0x37 (RST=0x10,
  TE|RE=0x0C) · TPPoll @0x38 (NPQ bit6=0x40, byte write) · IMR @0x3C · TxConfig @0x40 · RxConfig @0x44 · Cfg9346
  @0x50 (unlock 0xC0 / lock 0x00) · Config2 @0x53 · Config5 @0x56 (bit1 ASPM_en) · PHYAR/MDIO @0x60 · PHYStatus
  @0x6C · EPHYAR @0x80 · OCPDR @0xB0 · GPHY_OCP @0xB8 · DLLPR @0xD0 · RxMaxSize/RMS @0xDA (16-bit) · CPlusCmd @0xE0
  (16-bit) · RDSAR lo @0xE4 / hi @0xE8 · MISC @0xF0 (bit19 RXDV_GATED_EN, bit16 EARLY_TALLY_EN).
- RxConfig accept nibble: AAP=0x01, APM=0x02, AM=0x04, AB=0x08, `RX_CONFIG_ACCEPT_OK_MASK`=0x0f; Linux
  `rtl_set_rx_mode` programs `AB|APM|AM = 0x0E`. Profile words per source: Linux modern `0xCF00` = RX128_INT_EN
  (1<<15) | RX_MULTI_EN (1<<14) | RX_EARLY_OFF (1<<11) | RX_DMA_BURST (7<<8); FreeBSD `RL_FLAG_8168G_PLUS` =
  `0xE700` + `RXCFG_EARLYOFFV2` (0x0800) = `0xEF00`; iPXE `0xE78F` in ONE store. ⛔ AGNOS burned `0xE700`, `0xCF00`,
  `0xEF00`, `0xCF00` — ALL falsified; the profile word is not the gate.
- ⚠ CPlusCmd (0xE0) semantics on the gigabit 8168: bits [1:0] are the **INTT interrupt-moderation timer select**
  (Linux `INTT_MASK = GENMASK(1,0)`), NOT "C+ RX/TX enable" — that map (`RL_CPLUSCMD_TXENB=0x0001`, `RXENB=0x0002`,
  `PCI_MRW=0x0008`) belongs only to the legacy 8139C+ `!MACSTAT` branch. RX/TX are gated solely by `CR.RE|CR.TE`.
  Normal_mode = bit13 = 0x2000. Named in-corpus "the nine-burn CPlusCmd trap".
- PHYAR/MDIO protocol (MMIO 0x60): bit 31 = Flag (write trigger / read completion); bits 20:16 = the 5-bit PHY
  register address; bits 15:0 = data. WRITE: set bit31 + reg + data, poll until bit31 CLEAR. READ: clear bit31 +
  reg, poll until bit31 SET. PHY registers: BMCR=0, BMSR=1, ANAR=4, GBCR=9; BMCR bit12 autoneg-enable, bit11
  power-down, bit9 restart (0x1200 = enable|restart); BMSR bit2 LinkStatus (latching-low), bit5 autoneg-complete.
  PHYStatus (0x6C): bits[3:2] speed (00=10M, 01=100M, 10=1000M), bit[4] full-duplex, bit[1] LinkSts.
- 16-byte RX/TX descriptor, byte-identical across Linux + FreeBSD + OpenBSD + NetBSD + Haiku + the datasheet §6.7:
  `opts1`@+0 = OWN[31]=0x80000000 | EOR[30]=0x40000000 | FS[29]=0x20000000 | LS[28]=0x10000000 |
  FRALIGN[27]=0x08000000 | … | length[13:0]; `opts2/vlan`@+4; `buf_addr_lo`@+8; `buf_addr_hi`@+12. Ring alignment
  256 bytes. RX error bits: Linux `RxRWT`=(1<<22), **`RxRES`=(1<<21) = 0x00200000** Receive Error Summary,
  `RxRUNT`=(1<<20), `RxCRC`=(1<<19); FreeBSD `RL_RDESC_STAT_RXERRSUM` = **0x00100000** (bit 20) — the two source
  families DISAGREE on which bit is the summary, and AGNOS's `0x00100000` gate matched BSD. Length mask is 14 bits
  (`GENMASK(13,0)` / FreeBSD `GFRAGLEN`=0x00003FFF; FreeBSD's "13-bit" comment is wrong, the value is right). The
  reported RX length INCLUDES the 4-byte FCS; every reference subtracts it.
- DTCCR tally-counter struct — 64 bytes, 64-byte aligned, little-endian, byte-exact across Linux `rtl8169_counters`
  + FreeBSD `rl_stats` + OpenBSD `re_stats`: 0x00 TxOK(8), 0x08 RxOK(8), 0x10 TxER(8), 0x18 RxER(4), 0x1C
  MissPkt(2), 0x1E FAE(2), 0x20 Tx1Col(4), 0x24 TxMCol(4), 0x28 RxOKPhy/rx_unicast(8), 0x30 RxOKBrd(8), 0x38
  RxOKMul(4), 0x3C TxAbort(2), 0x3E TxUnderrun(2). ⚠ FreeBSD's field name `rl_rx_underruns` at 0x3E is MISNAMED — it
  is TX FIFO underrun. Dump procedure: (1) guard on `ChipCmd & CmdRxEnb` and `ChipCmd != 0xFF`; (2) write phys-addr
  HIGH to 0x14; (3) PCI commit/flush; (4) write phys-addr LOW to 0x10 with bit3 clear; (5) write LOW OR'd with `0x8`
  — the trigger; (6) poll 0x10 for bit3 clear (Linux 10 µs × 1000 = 10 ms; FreeBSD `DELAY(1000)` × 1000 = 1 s; AGNOS
  10 ms with a 100 ms ceiling). ⚠ Do NOT issue `CounterReset` (bit0) during a debug session — it zeroes counters and
  destroys cross-burn deltas. Do NOT flip `EARLY_TALLY_EN` (MISC bit 16) on VER_46.
- DHCP: the magic cookie `0x63,0x82,0x53,0x63` sits at offset **+236** and MUST be compared as a BYTE ARRAY, never
  as a u32 literal (a u32 compare is an endianness bug and a silent drop on x86). Options walker: tag 0 (Pad) → skip
  1 byte, no length; tag 255 (End) → terminate; else read a 1-byte length then `length` bytes, advance `2 + length`;
  bounds-check `ext + 2 + len <= end` at every step. chaddr must be compared over `hlen` = 6 bytes, not the full
  16-byte field. ⚠ DHCP BUFFER SIZING (three coupled limits, all below realistic payloads): `udp_bind` per-listener
  `kmalloc` 256 → **1024**; `net_handle_udp` `udp_data_len` cap 248 → **1016** — this cap is the LOAD-BEARING one;
  `dhcp_init` local `var rx[320]` → `var rx[1024]` at two call sites. A typical OFFER payload is 250-350 bytes, so
  the 248-byte cap left only 8 bytes of options past the fixed header. DHCP TIMEOUT: the OFFER/ACK loops used 200
  iterations of `arch_wait()` (`hlt`) = 200 × 10 ms = **2 seconds** after a SINGLE DISCOVER, against RFC 2131
  §4.4.1's 4 s initial timeout with exponential backoff and at least 4 attempts. Bumped 200 → 800 (~8 s) plus a
  midpoint retransmit at `ti == 400` reusing the same xid.
- Erratum history for VER_46, resolved by reading git rather than picking a source: commit `efa5f1311c49` added a
  force-allmulti workaround ("RTL8168H erroneously filter unicast eapol packets unless allmulti is enabled") and was
  later **REVERTED** by `6a26310273c3` — a correctly-initialized VER_46 receives unicast WITHOUT allmulti, so this
  is an init-protocol bug class, not a missing-workaround class.
- NetBSD `rtl8169.c:916` carves out `RTKQ_TXRXEN_LATER` SPECIFICALLY for `RTK_HWREV_8168H`, deferring `CR = TE|RE`
  until AFTER RxConfig + accept bits. Both orderings ship in production for this chip; ordering is NOT the gate.
- ⚠ QEMU CANNOT VALIDATE THE r8169 PATH AT ALL — AGNOS QEMU smokes use `virtio-net-pci` only, and QEMU's r8169
  emulation models neither RXDV_GATED_EN, nor the Cfg9346 lock, nor any chip-rev quirk. The QEMU surface for every
  r8169 bite is REGRESSION-ONLY.
- ⚠ THE WRONG-VANTAGE TRAP, burned three separate times: a capture host on an ORDINARY SWITCHED PORT cannot see a
  unicast reply, because the switch delivers it straight to AGNOS's port and never floods it. Only a SPAN/mirror
  port, or a host that DIRECTLY probes AGNOS, gives a valid RX vantage.
- The zero-burn Cyrius probe toolkit (`agnosticos/scripts/dhcp-probe/src/`, 6 programs, all still present):
  `dhcp_probe.cyr`, `dhcp_probe_raw.cyr`, `arp_probe_raw.cyr`, `arp_snoop_check.cyr`, `arp_reply_len.cyr`,
  `tcp_syn_probe.cyr` — falsify a wire hypothesis in ~10 s on Linux with no kernel rebuild and no burn. Results:
  `dhcp-probe enp1s0` (POSIX UDP, xid `0x306ff80`) leased `192.168.1.129` from the real gateway, exonerating BOOTP
  packing, option encoding, the option walker, xid round-tripping, magic-cookie validation, the `op==2` gate and the
  whole state machine in ONE run; `dhcp-probe-raw` (AF_PACKET, xid `0x3b891d4f`, 291-byte DISCOVER) built the FULL
  frame from `eth_build`/`ip_build`/`udp_build`/`ip_checksum`/`dhcp_build_packet` copied BYTE-FOR-BYTE from
  `net.cyr:31-89,311-335` and also leased `.129`, proving those wire-correct; `arp_probe_raw` got `gateway
  192.168.1.1 is at d4:6a:91:ce:70:60` from the real `b0` MAC claiming `.222` WHILE Linux held an active `b0` lease,
  killing the duplicate-MAC-suppression theory; `arp_reply_len.cyr` measured EVERY gateway unicast ARP reply at
  exactly **60 bytes**, killing the RUNT-drop theory zero-burn (worth measuring because BSD `if_rlreg.h` AGREES with
  AGNOS's `0x00100000`, so header archaeology could not settle it); `tcp_syn_probe.cyr` sent a byte-faithful AGNOS
  SYN from `.222` to `1.1.1.1:80` and received SYN+ACK with flags `0x12`, killing the gateway-source-guard and
  malformed-SYN theories — bonus finding, `who-has 192.168.1.222` was answered 0 times because the gateway snooped
  `.222`→our-MAC off our outbound SYN, RFC-826-style.
- ⛔ FALSIFIED ZERO-BURN — RxConfig bit 17 (`0x00020000`) and the blind-write-vs-RMW question, by a 3-source audit:
  no Linux code path AUTHORS `0x20000` (it is a chip-set status bit; the RTL8111B/8168B datasheet marks 31:16
  reserved), and FreeBSD `re_set_rxmode` BLIND-WRITES RxConfig without it and receives unicast fine.
- ⛔ FALSIFIED — the whole 1.32.4 DHCP receive-matcher 10-bundle. Items 3 (BOOTP `op==2` gate), 4 (magic-cookie
  byte-by-byte validation), 5 (xid byte-order), 6 (options-walker Pad/End invariants) and 10 (ACK-matcher mirror)
  were ALL proven non-load-bearing by the userland probes; items 1, 2, 7, 8, 9 were instrumentation or static-IP
  fallback only. NONE of the ten was the bug.
- ⛔ FALSIFIED ON RE-DERIVE (no burn) — "bite H removed the IDR0-5 write-back; restore it". Reading the CODE rather
  than the narrative showed the write-back was ALREADY present and correct at `r8169.cyr:520-534`, Cfg9346-wrapped,
  matching Linux `rtl_rar_set`, and was in the burned 1.32.5 build. A STALE NARRATIVE, not stale code.
- ⛔ FALSIFIED by iron — H1 "PHY not configured / no link" (CMOS `0x59 = 0x01`, link UP preserved from BIOS) · H2
  "chip-revision reset quirk" (`reset OK; Phase 1 complete`) · H3 "MAC read returns garbage"
  (`MAC=176:65:111:12:228:37` byte-matched lspci; EEPROM auto-load worked) · H4 "BAR2 mapping wrong" (`found at
  4243603456` byte-matches sysfs) · H6 "PAT/cache attribute wrong for this BAR" (repeated MMIO reads returned clean
  values) · H9 "cross-driver PCIe arbitration starvation with xhci/nvme/ahci" (the storage trio + GPT + ext4 mount +
  shell stayed byte-clean across every burn).
- ⛔ FALSIFIED ZERO-BURN by pcap `1324_tcp_capture.pcapng` — H7 "TX OWN never clears / TX not on the wire":
  `18:55:21.723629 b0:41:6f:0c:e4:25 > ff:ff:ff:ff:ff:ff, ARP Request who-has 192.168.1.1 tell 192.168.1.222` —
  AGNOS's frame on the wire byte-correct. Re-proven twice more. r8169 TX is PROVEN, and every TX-side candidate
  (TPPoll write width, TxConfig RMW-vs-literal, MTPS, descriptor cmdstat packing, Cfg9346 racing TE, TX FIFO
  threshold) dies with it.
- ⛔ DEAD END — the VFIO userland-driver probe: binding `enp1s0` to VFIO kills archaemenid's SOLE network link, i.e.
  the connection the test runs over. Scripts deleted; replaced by the strictly better zero-burn `ethtool -d` dump.
- ⚠ CYRIUS PORT-BLOCKER: the r8169 RX path has NO memory barriers — no `dma_rmb` between the descriptor status read
  and the field reads, no `dma_wmb` between field writes and the OWN store. x86-TSO covers this on Zen so it is
  harmless today, but on RISC-V or ARM64 the descriptor read could be reordered with the buffer read, delivering
  stale contents. Hard blocker for the RISC-V target.
- TCP server primitives (bite A): a listening socket is a passive conn-table entry with state = LISTEN.
  `tcp_listen(port)` sets src_port = port, src_ip = 0 (wildcard), dst_port = dst_ip = 0, returns the index as
  listen_id; bind and listen merged at v1. On an incoming SYN with no exact-match active conn, scan LISTEN entries
  matching dst_port and (dst_ip OR wildcard), allocate a NEW conn in SYN_RCVD, send SYN+ACK, inherit the LISTEN's
  src_port and take the peer's IP/port as dst.
- Build trajectory across the cycle: 578,432 (1.31.7 close) → 582,632 (bite A TCP) → 585,336 (bite F UDP) → 593,096
  (bite G DHCP) → 595,424 (r8169 Phase 1) → 600,432 (Phases 2-4) → **601,392 B**.

## [1.31.6] — 2026-05-22 — storage arc CLOSE: eight cleanup bites + Iron Attempt 90 ext4 victory lap
- IRON Attempt 90 PASS: the multi-backend probe matched backend=2, the partition-aware mount found agnos-fs at LBA
  3898638336 (`ext2: probe matched backend=2 partition_lba=3898638336`), the ext4 extent leaf walker mounted with
  blocksize=4096 inode_size=256 inodes_per_group=8192, and `ls /` against real ext4 on iron NAND returned the full
  dirent list.
- `GPT_TYPE_LINUX_FS_LO` carried a byte typo (`0xC663AF` instead of `0xC63DAF`); before the fix valid Linux-FS
  partitions displayed as "(unknown type)". Iron-validated here: p3 upgraded from `[2] (unknown type) agnos-fs` to
  `[2] Linux FS agnos-fs`.
- `blk_mark_registered(tag)` closed a bypass where the AHCI/USB-MS secondary/tertiary registration paths were not
  setting the `blk_registered` bit; the multi-backend ext2 probe is functional ONLY with this fix.
- Partition gating uses the binary-stable Linux-FS type GUID **0FC63DAF-8483-4772-8E79-3D69D8477DE4**, NOT the
  human-readable partition name — parted and sgdisk write UTF-16LE names differently.
- ext2 probe false-positive gate is three checks: `s_magic == 0xEF53` AND `s_log_block_size <= 2` (1K/2K/4K) AND
  `s_inodes_per_group > 0`. Probe order NVMe → AHCI → USB-MS → VirtIO → RAMDISK, first wins. btrfs uses magic
  `_BHRfS_M` at byte 65,536, so LBA-2 will not accidentally match.
- Build **571,296 B** (+2,336 over 1.31.5). Five iron debuts close the cycle: NVMe @ 80 · SATA @ 81 · USB MS @ 87 ·
  RAM-disk+VirtIO @ 88 · ext4 @ 90.

## [1.31.5] — 2026-05-21 — ext2 / ext4 read-only filesystem driver (Phases 1-4)
- Superblock at byte offset **1024** from partition start (read as two 512-B sectors at `partition_first_lba+2` and
  `+3`). Offsets: `s_blocks_count`@4 · `s_first_data_block`@20 · `s_log_block_size`@24 · `s_blocks_per_group`@32 ·
  `s_inodes_per_group`@40 · `s_magic`@56(u16) · `s_rev_level`@76 · `s_first_ino`@84 · `s_inode_size`@88(u16) ·
  `s_feature_compat`@92 · `s_feature_incompat`@96 · `s_feature_ro_compat`@100 · `s_uuid`@0x68 · `s_journal_inum`@224
  · `s_desc_size`@254(u16) · `s_blocks_count_hi`@0x150 · `s_checksum_seed`@0x270 · `s_checksum`@0x3FC. `s_magic`
  MUST be **0xEF53**. `blocksize = 1024 << s_log_block_size`. `s_first_data_block` is 0 when blocksize ≥ 2048 and
  **1** when blocksize == 1024 — never hard-code "BGDT at block 1", it reads garbage on a 1024-byte-block
  filesystem.
- BGDT fields: `bg_block_bitmap`+0 · `bg_inode_bitmap`+4 · `bg_inode_table`+8 · `bg_free_blocks_count`+12(u16) ·
  `bg_free_inodes_count`+14 · `bg_used_dirs_count`+16 · `bg_block_bitmap_csum_lo`+0x18 ·
  `bg_inode_bitmap_csum_lo`+0x1A · `bg_checksum`+0x1E · the `_hi` halves at
  +0x20/+0x24/+0x28/+0x2C/+0x2E/+0x30/+0x38/+0x3A. 32 bytes legacy, `s_desc_size` (typically 64) with
  INCOMPAT_64BIT.
- Inode fields: `i_mode`@0(u16) · `i_size`@4 · `i_atime`@8 · `i_ctime`@12 · `i_mtime`@16 · `i_links_count`@26(u16) ·
  `i_blocks`@28 · `i_flags`@32 · `i_block[15]`@40 (60 bytes) · `i_checksum_lo`@0x7C · `i_size_high`@108 ·
  `i_checksum_hi`@0x82. File type = `i_mode & 0xF000`: REG=0x8000, DIR=0x4000, LNK=0xA000. `i_flags` bit **0x80000**
  = EXT4_EXTENTS_FL; **0x1000** = INDEX_FL. ⚠ `i_blocks` is in 512-BYTE SECTORS, not filesystem blocks — a 4 KB
  block adds 8.
- Inode location math: `inode_num -= 1`; `block_group = inode_num / s_inodes_per_group`; `index = inode_num %
  s_inodes_per_group`; `byte_offset = index * s_inode_size`; target block = `bg_inode_table +
  byte_offset/blocksize`, offset `byte_offset % blocksize`. Reserved inodes: 1 bad-blocks, **2 root dir**, 3/4
  obsolete ACL, 5 boot loader, 6 undelete, 7 reserved GDs, 8 journal, 11 lost+found.
- dirent v2: `inode` u32@0 · `rec_len` u16@4 · `name_len` u8@6 · `file_type` u8@7 · name@8 (not NUL-terminated).
  `file_type` is only valid if INCOMPAT_FILETYPE (0x0002) is set — otherwise that byte is the high byte of
  `name_len`. Validation predicates, each aborting the walk: `rec_len < 12`; `rec_len & 3`; `rec_len < 8 +
  name_len`; entry spans the block boundary; `inode > s_inodes_count`; **`rec_len == 0`** — the single most
  important defence, without which a corrupt filesystem infinite-loops the kernel.
- Indirect tree: `i_block[0..11]` direct, [12] single, [13] double, [14] triple; `ptrs = blocksize/4` (1024 at 4 KB,
  `ptrs_bits = 10`). Size limits at 4 KB blocks: direct 48 KB; +single 4.05 MB; +double ~4 GB; +triple ~4 TB. Needs
  exactly three 4 KB scratch pages, allocated once at mount.
- `ext4_extent_header` (12 B): `eh_magic` u16@0 = **0xF30A** · `eh_entries`@2 · `eh_max`@4 · `eh_depth`@6 (0 = leaf)
  · `eh_generation`@8. `ext4_extent` (leaf, 12 B): `ee_block`@0 · `ee_len`@4 · `ee_start_hi`@6 · `ee_start_lo`@8.
  `ext4_extent_idx` (12 B): `ei_block`@0 · `ei_leaf_lo`@4 · `ei_leaf_hi`@8 · `ei_unused`@10. Inode-embedded root:
  bytes 0-11 header, 12-59 four entries, `eh_max ≈ (60-12)/12 = 4`; deeper blocks hold `(blocksize-12)/12` = 340
  entries at 4 KB. ⚠ `ee_len > 32768` means UNWRITTEN: `actual_len = ee_len - 32768`, blocks ARE allocated but
  content is undefined — the correct behaviour is to ZERO-FILL and NOT issue `blk_read`; a naive driver returns
  pre-allocation disk garbage. Physical = `(ee_start_hi << 32) | ee_start_lo` (48-bit); Linux writes `<<31<<1`
  rather than `<<32` because `x<<32` is UB when the type is conditionally u32 — the silent failure mode of getting
  it wrong is that extents past block 2^32 read low-32 only, corruption with no error. `EXT4_MAX_EXTENT_DEPTH = 5`.
- `s_feature_incompat` map: 0x0001 COMPRESSION · 0x0002 FILETYPE · 0x0004 RECOVER · 0x0008 JOURNAL_DEV · 0x0010
  META_BG · 0x0040 EXTENTS · 0x0080 64BIT · 0x0100 MMP · 0x0200 FLEX_BG · 0x0400 EA_INODE · 0x1000 DIRDATA · 0x2000
  CSUM_SEED · 0x4000 LARGEDIR · 0x8000 INLINE_DATA · 0x10000 ENCRYPT. AGNOS REFUSES COMPRESSION, JOURNAL_DEV,
  DIRDATA, INLINE_DATA (walkers return garbage), ENCRYPT (`cat` would print ciphertext), BIGALLOC; TOLERATES
  FILETYPE, RECOVER, MMP, FLEX_BG, EA_INODE, CSUM_SEED, LARGEDIR. Supported-incompat masks over time: Phase 1-3
  `0x6502`; Phase 4 (+EXTENTS) `0x6542`; shipped read mask `0x6746`; with 64BIT `0x67C6`.
- Builds: 520,920 → 537,952 (Phase 1) → 552,736 (Phase 2, +12 KB BSS for the three indirect scratch buffers) →
  562,872 (Phase 3, +4 KB `ext2_dir_buf`) → **568,960 B** (Phase 4, +4 KB `ext2_extent_buf`).

## [1.31.4] — 2026-05-21 — RAM-disk backend + VirtIO 1.x modern virtio-blk-pci driver
- VirtIO PCI vendor capability (cap_vndr `0x09`, ≥16 bytes): `cap_vndr`@0 · `cap_next`@1 · `cap_len`@2 ·
  `cfg_type`@3 · `bar`@4 · `id`@5 · pad@6 · `offset` LE32@8 · `length` LE32@12. cfg_type: 1 COMMON_CFG · 2
  NOTIFY_CFG (followed by an extra LE32 `notify_off_multiplier` at cap+16, making the cap 20 bytes) · 3 ISR_CFG · 4
  DEVICE_CFG · 5 PCI_CFG · 8 SHARED_MEMORY_CFG · 9 VENDOR_CFG.
- COMMON_CFG 60-byte block: `device_feature_select`@0 · `device_feature`@4 · `driver_feature_select`@8 ·
  `driver_feature`@12 · `config_msix_vector`@16 · `num_queues`@18 · `device_status`@20 · `config_generation`@21 ·
  `queue_select`@22 · `queue_size`@24 · `queue_msix_vector`@26 · `queue_enable`@28 · `queue_notify_off`@30 ·
  `queue_desc`@32 · `queue_driver`@40 · `queue_device`@48. Status bits: ACKNOWLEDGE=1, DRIVER=2, DRIVER_OK=4,
  FEATURES_OK=8, DEVICE_NEEDS_RESET=64, FAILED=128; progression 0 → 1 → 3 → 11 → 15.
- 8-step modern init: write 0 to `device_status` and SPIN until read-back is 0 (§4.1.4.3.2, mandatory) → ACKNOWLEDGE
  → DRIVER → read 64-bit offered features → set FEATURES_OK → **RE-READ and if FEATURES_OK is clear the device
  rejected the subset: set FAILED and abort with NO retry** (a "renegotiate with reduced bits" loop is a spec
  violation) → per-VQ setup → DRIVER_OK.
- `VIRTIO_F_VERSION_1` = bit 32 (MUST accept). Deliberately NOT accepted: ACCESS_PLATFORM(33), RING_PACKED(34),
  NOTIFICATION_DATA(38), RING_EVENT_IDX(29), INDIRECT_DESC(28), IN_ORDER(35), ORDER_PLATFORM(36),
  NOTIF_CONFIG_DATA(39), RING_RESET(40), SR_IOV(37). Accepted if offered: `VIRTIO_BLK_F_RO`(5). `VIRTIO_BLK_F_FLUSH`
  = bit 9; per §5.2.5.1, if the driver does not ack FLUSH the device commits writes implicitly.
- Split-virtqueue regions: descriptor table 16-byte aligned, `16 × queue_size`; available ring 2-byte aligned, `6 +
  2 × queue_size`; used ring 4-byte aligned, `6 + 8 × queue_size`. At queue_size 256: desc 4 KB, avail 518 B, used
  2054 B. Modern split rings have NO inter-region padding requirement (the legacy 4 KB-aligned-used-ring rule is
  gone) and addresses are written as 64-bit BYTE-physical values with NO PFN shift — contrast the 0.9.5 `QUEUE_PFN =
  addr >> 12` (`VIRTIO_PCI_QUEUE_PFN` = 8 at BAR0, `QUEUE_ADDR_SHIFT` = 12, `VRING_ALIGN` = 4096). Legacy vring
  layout formula: `desc_base = p`; `avail_base = p + 16*num` (`sizeof(vring_desc) == 16` is a hard ABI fact = 8 B
  addr + 4 B len + 2 B flags + 2 B next); `used_base = ALIGN_UP(avail_base + 6 + 2*num, 4096)`.
- Notify address: `notify_addr = notify BAR base + NOTIFY_CFG.offset + (queue_notify_off × notify_off_multiplier)`;
  the multiplier MUST be an even power of 2 or zero (QEMU typically 4).
- `virtio_blk_req`: le32 type (0=IN, 1=OUT, 4=FLUSH, 8=GET_ID), le32 reserved, le64 sector (512-B offset; 0 for
  FLUSH), u8 data[], u8 status (0=OK, 1=IOERR, 2=UNSUPP). Read/write uses a 3-descriptor chain; FLUSH uses 2 (header
  + status, no data). §2.7.4.2 requires all device-readable descriptors to precede device-writable ones.
- Top three cross-implementation pitfalls: a `wmb` between the avail-ring slot write and the `avail->idx` increment,
  and a symmetric `rmb` between the `used->idx` read and the used-ring entry read (flagged explicitly by Linux
  `virtio_ring.c:1230`, FreeBSD `virtqueue.c:979`, OpenBSD `virtio_membar_producer`); offset+length overflow
  validation on the BAR submap (Linux `virtio_pci_modern_dev.c:57-62` errors with "map wrap-around %u+%u"); and a
  cleared FEATURES_OK readback means RESET, not retry. AGNOS emits `mfence` as inline asm `{0x0F; 0xAE; 0xF0}`.
- ⚠ Transitional device ID `0x1001` exposes BOTH the legacy I/O BAR0 and the modern capability list, so the driver
  must decide by CAP-LIST PRESENCE, not device ID. Modern block ID is `0x1042`, vendor `0x1AF4`.
- RAM-disk: preallocate at init, 512-B sectors, `RAMDISK_SIZE_PAGES = 64` (256 KB) default with a hard max of 128.
  Physical addresses in `ramdisk_pages[N]` indexed by `sector >> 3`, offset `(sector & 7) * 512` — O(1), no radix
  tree (the "small kernel" pattern: OpenBSD `rd.c` / NetBSD MD_KMEM_ALLOCATED, not Linux `brd`'s sparse xarray).
  archaemenid's post-boot pmm budget is ~354 free pages (~1.4 MB), so 256 KB = 64 pages = 18%; 512 KB = 36% is the
  recommended max. AGNOS's pmm has no free path, so on partial alloc failure it leaves `ramdisk_npages = 0`, skips
  registration, and logs `ramdisk: pmm exhausted after N pages — disabled` WITHOUT freeing. `blk_register_ramdisk`
  takes the slot only when `blk_active == BLK_NONE`.
- Build **510,536 → 520,920 B** default (`RAMDISK_ENABLE=0`), 520,952 B with the RAM-disk.

## [1.31.3] — 2026-05-21 — USB Mass Storage Phase 2.8: the eight-bug repair stack → Attempt 87 PASS
- ⭐ IRON ATTEMPT 87 PASS (Silicon Motion VID `0x090C` PID `0x1000`): `msc: slot 2 BBB intf=0 bulk-IN=130 bulk-OUT=1
  MPS(in/out)=512/512 MaxLUN=0` → `INQUIRY: vendor='General' product='USB Flash Disk' rev='1100' type=block` → `TEST
  UNIT READY -> ready (Pass)` → `READ CAPACITY: last_lba=252051455 blk=512B -> 123072 MiB` → `1 mass-storage
  device(s) detected`. `xhci: bulk transfer event timeout` ABSENT. Third storage-class iron debut (NVMe @ 80, SATA @
  81).
- BUG 1 (PRIMARY ROOT CAUSE): `XHCI_CMD_TIMEOUT_SPINS` = 10M (~25-50 ms) was being applied to BULK transfers — the
  command-ring timeout abandoned the INQUIRY data phase mid-flight against real silicon. Linux uses
  `USB_CTRL_GET_TIMEOUT` = 5000 ms. Fix: a bulk-specific `XHCI_BULK_TIMEOUT_SPINS` = **200M (~1 s wall)**.
- BUG 2: stale completion events attributed to the wrong TRB — the "CSW tag mismatch on TUR #0" was a LATE INQUIRY
  CSW read as the TUR's. Fix: `xhci_wait_transfer_for_trb(slot_id, expected_trb_phys, expected_len)` for strict
  matching.
- BUG 3 (direct cause of the repeating CSW signature mismatch): no SHORT_PACKET residue check. The device's
  ZLP-then-real-CSW pattern after Reset Recovery left `csw_phys[0..3] = 0`. Fix: read Transfer Event dw2 bits 23:0
  (residue) and reject when `residue >= expected`.
- BUGS 4-8: no entry guard on `msc_bbb_exec` (new `msc_scsi_exec(retries)` wrapper runs Reset Recovery BEFORE the
  first retry when the sticky is set); the event drain was mis-positioned BEFORE Stop Endpoint, but Stop Endpoint ×2
  posts Transfer Events for pinned in-flight TRBs (§4.6.9.1) so the drain must run AFTER; the hand-rolled TUR retry
  loop duplicated the wrapper shape inconsistently (INQUIRY/TUR/RC10/REQUEST SENSE/READ/WRITE all migrated onto it);
  Stop Endpoint on transfer-event timeout was missing; `xhci_cmd_set_tr_dequeue` had `param_hi = 0` hardcoded
  (harmless while PMM stays below 4 GB, malformed for future high-memory placement).
- ⭐ THE STALE-TRANSFER-EVENT MECHANISM: `xhci_wait_transfer_event` (`xhci.cyr:762-812`) spins for a matching
  slot_id, returns 0 on timeout, and DOES NOT FLUSH the event ring. The device then DMAs its late INQUIRY response,
  the xHC posts a Transfer Event, and the next call picks up that stale event as the new CBW's completion, so the
  subsequent CSW read grabs the wrong CSW. Linux avoids this implicitly because Stop Endpoint generates a "Stopped"
  Transfer Event that flushes the TD. Fix: `xhci_drain_transfer_events(slot_id)` walks the event ring consuming
  every Transfer Event for the slot until the cycle bit says empty, called in `msc_reset_recovery` before re-arming.
- Build 475,096 → **502,072 B** (+26,976 B for the eight-patch stack).

## [1.31.2] — 2026-05-21 — USB Mass Storage Phases 1-2.7 + the cyrius pin graduation to 6.0.1
- MSC class triple = interface class `0x08` / subclass `0x06` (SCSI transparent) / protocol `0x50` (Bulk-Only
  Transport); `bDeviceClass = 0x00` is the standard shape, so the walker must drop to the Interface Descriptor.
  GET_MAX_LUN is class-specific: `bmRequestType=0xA1, bRequest=0xFE, wValue=0, wIndex=interface, wLength=1`; many
  real sticks STALL it, which per spec means MaxLUN=0.
- CBW is 31 bytes: `dCBWSignature` = `0x43425355` ('USBC' LE)@0 · host tag@4 (echoed in the CSW) ·
  `dCBWDataTransferLength`@8 · `bmCBWFlags` bit 7 = direction@12 · `bCBWLUN` low nibble@13 · `bCBWCBLength` 5-bit@14
  · CDB from 15. CSW signature is 'USBS' (`0x53425355`).
- xHCI DCI: bulk-IN at endpoint N → `2N+1`; bulk-OUT at N → `2N`; control EP0 → 1. AGNOS stores the precomputed DCI
  at row+40 (in) and row+41 (out).
- Reset Endpoint command TRB (type 14): d3 = `(slot_id<<24) | (ep_index<<16) | (TSP<<9) | (14<<10) | cycle`, TSP
  (bit 9) normally 0. Set TR Dequeue Pointer (type 16): d0 = `(deq_ptr_lo & ~0xF) | DCS`, d1 = `deq_ptr_hi`, d2 =
  `stream_id << 16` (0 for non-stream EPs), d3 = `(slot_id<<24) | (ep_index<<16) | (16<<10) | cycle`.
  `XHCI_CC_CONTEXT_STATE_ERROR = 19`. EP State is Output EP Context dword 0 bits 0-2 (§6.2.3).
- xHCI endpoint state machine: on a Stall PID the endpoint goes Halted, the xHC stops fetching TRBs, posts a
  Transfer Event with STALL_ERROR (6), and updates the EP Context's TR Dequeue Pointer to the halting TRB. **Reset
  Endpoint is legal ONLY from Halted** and moves Halted → Stopped; it MUST be followed by Set TR Dequeue Pointer
  before the endpoint goes Stopped → Running on the next doorbell.
- ⛔ FALSIFIED at Attempt 85 — Phase 2.6's assumption that Reset Endpoint can be issued unconditionally: `msc: Reset
  Endpoint(bulk-IN) failed` fired twice and aborted recovery before Set TR Dequeue could run. The Attempt-84/85
  wedge was a transfer-event TIMEOUT, not a device STALL, so the endpoint never entered Halted; after Stop Endpoint
  it was STOPPED, and Reset Endpoint on Stopped returns Context State Error (CC=19). Fixes: CSE tolerance as a
  backstop, plus the primary fix — `xhci_ep_state(slot_id, dci)` gating Reset Endpoint on HALTED.
- ⛔ FALSIFIED at Attempt 86 — Phase 2.7's multi-source-converged Reset Recovery. It executed CORRECTLY on iron
  (`Reset Recovery OK` ×3, no Reset Endpoint failure, so the Attempt-85 failure path is dead) but every
  post-recovery TUR retry still returned `CSW signature mismatch`.
- Phase 2.7 ordering (four-source convergent, Linux deliberately NOT load-bearing): (1) Bulk-Only MS Reset
  (`0x21`/`0xFF`) → (2) **100 ms stall** → (3-4) CLEAR_FEATURE(ENDPOINT_HALT) (`0x02`/`0x01`) on each bulk EP → (5)
  drain stale events → (6) Stop Endpoint ×2 → (7) Reset Endpoint ×2 gated on Halted → (8) ring rewind → (9) Set TR
  Dequeue ×2 → (10) clear the sticky. Convergent minimum for the post-BOT-Reset delay is 100 ms: EDK2 `UsbMassBot.c`
  stalls 100 ms explicitly quoting BBB §6.7.3 ("the device shall NAK the host's request until the reset is
  complete"), FreeBSD gets ~50 ms implicitly via its state-machine `.interval`, Linux `usb_stor_Bulk_reset` does
  `msleep(100)`. AGNOS Phase 2.6 had ZERO delay. All three non-Linux sources also agree: device-side reset runs
  FIRST; CLEAR_FEATURE is unconditional on both endpoints; Reset Endpoint is gated on Halted; TSP=0; Stream ID = 0.
- Two LATENT ring bugs found while the file was open, neither firing in steady state: `msc_bulk_enqueue`
  (`msc.cyr:526-532`) toggles `cycle` on wraparound but never writes it back, so on the second pass the reloaded
  cycle is wrong; and `msc_alloc_bulk_ring` (`:484-487`) writes the Link TRB with cycle=1 at allocation and never
  updates it, though §4.9.2 requires the Link TRB's cycle to flip in sync each crossing. With 64-TRB rings and ~3
  TRBs per CBW round-trip that is ~21 round-trips per wrap, and Reset Recovery rewinds idx to 0 first.
- Attempt 83 iron enumeration (PARTIAL): port 3, HS, slot=2, VID=2358 (`0x0936`), PID=5096 (`0x13E8`),
  `bDeviceClass=0x00`, intf=0, bulk-IN `0x82`, bulk-OUT `0x01`, MPS 512/512, MaxLUN=0 — every field differs from
  QEMU's emulated `usb-storage` (VID `0x46F4` PID `0x0001` at SuperSpeed, EPs `0x81`/ `0x02`, MPS 1024). ⚠ The print
  `TEST UNIT READY -> not ready / failed (CSW status != 0)` was MISLEADING generic else-branch prose: NO CSW was
  ever decoded. The real trace was `xhci: transfer event timeout` → `msc: CSW transfer timeout` → the sticky
  `transport_failed` byte at row+69. The audit's "NOT_READY on cold insertion" hypothesis was UNVERIFIED, not
  confirmed.
- ⚠ Deferred, still true: SCSI MMC optical drives report block_size 2048 while GPT and fatfs consumers hardcode `*
  512`, so an optical iron burn WILL misparse the partition table. A ≥2 TiB USB HDD saturates READ CAPACITY(10) at
  `last_lba = 0xFFFFFFFF` and needs READ CAPACITY(16), not implemented.
- Build ladder: 474,600 (AHCI carry-forward HEAD) → 478,440 (Phase 1 discovery, +3,840) → 484,992 (Phase 2 BBB
  transport + TUR, +6,552) → 488,984 (Phase 3 INQUIRY + READ CAPACITY, +3,992) → **493,688 B** (Phase 4
  READ/WRITE/register/demo, +4,696). Total USB-MS arc **+19,088 B / +4.0%** for ~990 LOC. Phase 2.5 496,656 B; Phase
  2.6 499,736 B; Phase 2.7 **499,816 B**. Default build (no `MSC_RW_DEMO`) 492,992 B.

## [1.31.1] — 2026-05-20 — GPT Phases 1-3 + AHCI/SATA Phases 1-4 + the SATA iron debut
- GPT layout on a 512-B-sector disk: LBA 0 protective MBR · LBA 1 primary header · LBA 2-33 partition entry array
  (32 LBAs × 512 B = 16 KB = 128 entries × 128 B) · LBA 34..(end-34) data · (end-33)..(end-1) backup array · last
  LBA backup header. LBA 2 = entries 0-3, LBA 3 = 4-7, LBA 33 = 124-127. `gpt.cyr` was 512 LOC; its CRC32 is IEEE
  (`0xEDB88320`) and must NOT be reused for ext4 metadata checksums.
- ⛔ REAL HARM at Attempt 81: the build shipped WITHOUT the `AHCI_RW_DEMO` compile gate, so the LBA-5 sentinel write
  ran on the user's WD Blue SA510. `ahci_rw_demo` wrote 'AHCI-OK!' at bytes 0-7 with 8-511 zero-filled to LBA 5
  (disk bytes 2560-3071), which lands inside GPT partition entries 12-15 — the partition-array CRC32 then fails and
  parted/sgdisk/lsblk may refuse the drive until repaired. Partition DATA (LBAs 34+) is never touched. Attempt 82
  onward defaults the gate OFF.
- AHCI non-data command shape for FLUSH CACHE EXT: H2D Register FIS byte0=`0x27`, byte1=`0x80`, byte2=opcode,
  byte7=`0x40` (LBA bit), rest zero; command header word0 = `CFL(5) | PRDTL(0<<16)` with W=0. `ahci_issue_rw` is
  data-only (requires count>0, PRDTL=1), so FLUSH needs a sibling.
- Iron Attempt 81 PASS-WITH-CAVEAT: the WD Blue SA510 enumerated and the LBA-5 round-trip passed on real silicon,
  but a follow-up IDENTIFY in the registration path timed out (PxCI stuck) so `ahci_register_block_dev` returned
  early and AHCI was NOT registered as a secondary block_dev. Boot continued cleanly to the shell on NVMe. ~1,100
  LOC; PHY handshake, controller bring-up, IDENTIFY decoding and full bidirectional DMA all worked first-iron-try.
- AHCI CMOS checkpoints: 0x4B HBA probe · 0x4C port enumeration · 0x4D HBA reset (NOT in the default boot path) ·
  0x4E per-port init · 0x4F first successful IDENTIFY · 0x50 block-layer registration · 0x51 GPT CRC validation.
  ext2: 0x52 init entry · 0x53 SB magic OK · 0x54 BGDT read OK · 0x55 Phase-3 path lookup ready · 0x56 multi-backend
  probe · 0x57 partition-aware probe · 0x58 mount success. USB-MS: 0x52 Phase 1 · 0x53 Configure Endpoint · 0x54 TUR
  pass · 0x55 INQUIRY · 0x56 READ CAPACITY · 0x57 registered as `blk_active=BLK_USB_MS`. CMOS 0x50-0x7F is virgin
  scratch on archaemenid with no BIOS collision; the stamping primitive is `xhci_cmos_stamp(slot, val)`
  (`usb/xhci_port.cyr:61-70`) — xhci-prefixed but a fully generic two-byte CMOS write (0x70/0x71 for slot < 0x80,
  0x72/0x73 for ≥ 0x80).
- Build ladder: 441,056 → 441,176 (GPT P1) → 443,760 (GPT P2) → 447,568 (AHCI P1) → 455,888 (AHCI P2) → 463,112
  (AHCI P3) → 470,664 (AHCI P4) → **475,096 B** (GPT P3).

## [1.31.0] — 2026-05-20 — ✳ NVMe arc: Phases 1-5 + block-layer dispatch + the Crucial P3 iron debut
- IRON ATTEMPT 80 (2026-05-20) PASS FIRST TRY: the Crucial P3 2 TB enumerated end to end and the kernel walked to
  shell. archaemenid NVMe readouts: controller at 4241489920, NVMe version 1.4.0, MQES=65535 DSTRD=0 TO=255×500 ms
  CSS_NVM=1 MPSMIN=0 MPSMAX=0; VID=49321 SSVID=49321 NN=1 MDTS=6; model `CT2000P3SSD8`, serial `2342E880DED6`,
  firmware `P9CR30A `, ns1 NSZE=3907029168 LBAS=512B, 1,907,729 MB.
- Block-layer effective priority (highest active wins): NVMe > AHCI > USB-MS > VIRTIO > RAMDISK > NONE. Tags:
  `BLK_NONE`, `BLK_VIRTIO`, `BLK_NVME`, `BLK_AHCI`, `BLK_USB_MS`=4, `BLK_RAMDISK`=5. `blk_write` (`block.cyr:164`)
  dispatches to `nvme_blk_write` (NVMe opcode `0x01` with a page-aligned scratch bounce), `ahci_blk_write` (ATA
  WRITE_DMA_EXT `0x35`), `msc_blk_write` (SCSI WRITE(10)), `vblk_blk_write`, `ramdisk_blk_write`.
- Cycle-open production-lean bundle: gating out KTEST inline-test bodies + XHCI_VERBOSE kprint sites took
  `build/agnos` **425,840 → 421,912 B (−3,928 B)** — exactly the gated-out code.
- Build ladder: 421,912 → 424,656 (Phase 1 probe/cap-decode/disable) → 430,168 (Phase 2 admin queue + IDENTIFY
  CONTROLLER/NAMESPACE) → 434,560 (Phase 3 I/O queue + blocking READ) → 438,416 (Phase 4 WRITE + multi-LBA +
  PRP1/PRP2/PRP-list) → **441,056 B** (Phase 5 block_dev dispatch). Net **+19,144 B** for the full driver + dispatch
  layer.

## [1.30.12] — 2026-05-20 — true-font swap: the VGA 8x16 BIOS ROM replaces the hand-drawn CGA 8x8
- `fb_font[768]` (96 glyphs × 8 bytes, hand-coded CGA-style) → `fb_font[1536]` (96 × 16), the public-domain IBM VGA
  BIOS 8×16 ROM font, packed by `fset16(ch, hi, lo)` with hi = rows 0-7 and lo = rows 8-15, MSB-first (bit 7 =
  leftmost pixel), read back as `bits = load8(glyph + row)` and `on = (bits >> (7 - col)) & 1`. Byte-verified
  against Linux `lib/fonts/font_8x16.c`: `fset16(0x41, 0x000010386CC6C6FE, 0xC6C6C6C600000000)` decodes to `00 00 10
  38 6C C6 C6 FE C6 C6 C6 C6 00 00 00 00` — a byte-for-byte match for 'A'.
- THE LOAD-BEARING CHANGE: cell geometry split — `cell_w = 8 * fb_scale()`, `cell_h = 16 * fb_scale()`. Every
  VERTICAL extent uses `cell_h` (`fb_fill_cell`'s outer loop, `fb_scroll_up`'s scroll distance and bottom-clear
  height, `max_rows = (height - FB_CONSOLE_Y0) / cell_h`, and both the newline and backspace Y advances); horizontal
  extents keep `cell_w`. Audited clean across 8 sites in `fb_console.cyr` (lines 469-485, 496-528, 544-545, 550-568,
  590-599).
- `fb_scale()` collapsed from four tiers to two (h ≤1200 → 1, else 2) — with a real 8×16 font, scale=1 is legible at
  1080p (a 16-px glyph is 1.5% of screen height) and scale=2 gives a 16×32 cell at 2K+.
- Removed the MTRR/audit dead code (~150 lines, ~5 KB) plus `pci_cfg_addr`/`pci_cfg_read32`. Build 422,048 →
  **425,840 B (+3,792)**: +font data + `fset16` init calls ~9 KB, −MTRR/audit/PCI ~5 KB.
- Font-source options evaluated: (A) VGA 8×16 BIOS ROM — public domain, in public use since 1981, 16 B/glyph = 1,536
  B for 0x20-0x7F, drop-in shape match — CHOSEN; (B) Spleen 16×32 (BSD-2-Clause with attribution, 64 B/glyph = 6,144
  B); (C) Terminus 16×32 (OFL-1.1 with a RESERVED NAME clause, so a modified version cannot be redistributed under
  the name); (D) Cozette 6×13 (MIT, but a non-power-of-2 width breaks the clean `bits >> (7 - col)` render pattern).
- Attempt 77 result: the VGA-spec path became LEGIBLE (user-confirmed, with a reported slight speed improvement
  consistent with a wider cell amortising fewer scroll-copy iterations per visible row); Quiet Boot remained
  illegible with a DIFFERENT signature — glyphs recognizable as letterforms inside each band, but the bands not
  composing continuous lines.
- ⛔ H1 "the render math still computes 8×8 somewhere" — falsified by the eight-site audit at commit 75914e9. ⛔ H3
  "font data layout mismatch" — falsified by the byte-for-byte `font_8x16.c` cross-reference plus the VGA path
  rendering cleanly.

## [1.30.11] — 2026-05-19 → 2026-05-20 — FB hardening: PixelFormat guard, WC retry, font-density scale
- ⛔ THE MTRR LESSON: `fb_mtrr_install_wc(fb_phys, fb_size)` + `fb_audit_mtrr()` + `fb_audit_pci_bar()` were added on
  the hypothesis that MTRR-UC overrides PAT-WC (Intel SDM Vol 3A §11.5.2.2 / AMD APM Vol 2 §7.7.5 — MTRR-UC always
  wins). Iron falsified BOTH halves at once (Attempt 74): the visual corruption was unchanged AND the system LOCKED
  UP post-`fb_console_init`, suspected AMD `SYS_CFG_MSR` MtrrLock → `#GP(0)` on `wrmsr` to variable-range MTRR MSRs
  (AMD APM Vol 3 §3.3). Attempt 76 removed the call sites, recovering from "garbled visuals AND lockup" to "garbled
  visuals but typeable shell". A nominally diagnostic-plus-repair change locked the box and masked the real failure.
- CMOS FB-geometry channel: `fb_console_init` stamps mode / pf / w / h / pitch / mode# / maxmode plus sentinel
  `0xFB` into CMOS extended-bank slots `[0x90..0x9F]`, decoded by `agnosticos/scripts/src/read-boot-log.cyr`.
  archaemenid has no serial cable, so this is the ONLY iron-readable post-mortem channel for FB geometry. First use
  (Attempt 71) stamped **pf=1 w=2560 h=1440 pitch=10240 under Quiet Boot ON** — pf=1 (BGRX) identical to VGA-spec, ⛔
  FALSIFYING the PixelFormat-asymmetry hypothesis the whole 1.30.11 cycle had opened on.
- `pf==2` (bitmask PixelFormat) is rejected outright by the kernel; gnoboot does not capture the 16-byte
  PixelInformation bitmask because the boot_info ABI would have to grow. Closed as no-consumer since archaemenid
  reports pf=1.
- Attempt 76 cleared 3 of 4 MVP bars under Quiet Boot at native HDMI 2560×1440 — no lockup, live keyboard, live
  refresh — failing only on legibility. Build 414,544 → 416,496 → **422,048 B**.

## [1.30.10] — 2026-05-19 — framebuffer refresh: WC + pitch-aware + u64 block-copy
- Three inner loops in `fb_console.cyr` switched from `store32`/`load32` per-u32 to `store64`/`load64` per-u64.
  Build 413,216 → **414,544 B (+1,328)**; the u64 follow-on did not change size (same MOV instruction widths on
  x86-64).

## [1.30.9] — 2026-05-18 — ★ THE CLOSED-BETA MVP GATE HITS: a typeable shell on iron
- IRON ATTEMPT 68 (~21:30 PDT): `agnos> echo "Assembly Up!"` echoed back from the iron Logitech keyboard (**VID=1452
  PID=591**). Both halves clear on archaemenid — visual (since 1.30.7) and functional (typeable keyboard via xHCI
  HID).
- The bundle: SET_CONFIGURATION + a canonical FS interval + ISP. Build 412,832 → **413,216 B (+384)**.
- ⚠ archaemenid has NO PS/2 port and its firmware does NOT emulate PS/2 over xHCI after ExitBootServices — BIOS
  legacy-USB knobs and every USB-A port swap were exhausted before the native driver was written. archaemenid is
  USB-KEYBOARD-ONLY: keystrokes arrive via `hid_poll`, and IRQ1 / `kb_isr` / the PIC are DEAD CODE on this box.

## [1.30.8] — 2026-05-18 — Attempts 65/66/67: EP0 MPS reconciliation clears HID enumeration
- Attempt 65 (411,280 B, post cyrius-.64 + CSZ helpers + Add-Flags `A0|A_new`): Phase-3 silent-absorb CLEARED on
  iron — Enable Slot, Address Device, GDD-8, GDD-18 all succeed (iron keyboard VID=1452 PID=591).
- Attempt 66 (412,080 B, post Repair RR): ⛔ RR FALSIFIED — GCD-9 still times out; the EP0-ring-conventions diagnosis
  is disproven and ISP / deferred-cycle-Setup / `p_hi` are not the gate.
- Attempt 67 (**412,832 B**, post EP0 MPS reconciliation per xHCI 1.2 §4.6.7 / Linux `xhci_check_maxpacket`): HID
  enumeration clears end to end on iron — `hid: probing iface kbd, slot=1, VID=1452 PID=591, class=0` → `hid:
  keyboard configured, boot protocol on, EP=…`.

## [1.30.7] — 2026-05-18 — Attempt 63 VISUAL BOOT-TO-SHELL ON IRON → typeable shell on QEMU
- ⭐ THE `events_seen=0` ARC ROOT CAUSE WAS A CYRIUS COMPILE-TIME BUG, NOT SILICON. In agnos's `kmode==1` boot the
  cyrius emit order is top-level asm → PARSE_PROG body → EMIT_GVAR_INITS, and the kernel's main body lives in
  PARSE_PROG and never returns, so the post-PROG block that emits gvar literal stores NEVER EXECUTED — top-level
  `var X = INT_LITERAL;` read as 0. The two load-bearing zero-reads: `XHCI_CMD_TIMEOUT_SPINS = 10000000`
  (`xhci_cmd.cyr:60`) read as 0 → `while (wait < 0)` exited immediately → `events_seen=0` every time; and
  `XHCI_EVT_RING_SEGMENT_SIZE = 256` (`xhci_ring.cyr:51`) read as 0 → the ERST entry's Ring Segment Size word was
  planted as 0 → the controller had NO event-ring slot to write Command Completion Events into. Fixed at the
  LANGUAGE level in cyrius v5.11.64 (image-static init for literal-RHS gvars across every backend), regression test
  `tests/tcyr/gvar_static_init.tcyr`.
- ⭐ THE QEMU LANE WAS THE UNLOCK: the identical `events_seen=0` symptom reproduced on a completely different
  controller (qemu-xhci — CSZ=0, no USBLEGSUP, no scratchpad bufs, BAR at 768 GB), which proved silicon could not be
  the cause.
- Three agnos bugs surfaced ONLY by the QEMU lane, all invisible on iron: (1) an xHCI BAR above 4 GB was unmappable
  — `vmm_remap_uc_2mb` only handled PML4[0] (sub-512 GB) while qemu-xhci's BAR lands at `0xC000000000` (768 GB); (2)
  CSZ=1 was hardcoded — `xhci_alloc_input_ctx` wrote Slot Context at offset `0x40` and EP0 at `0x80` (the 64-byte
  layout), but qemu-xhci is CSZ=0 (32-byte contexts) so the controller read Slot Context at `0x20` (all zeros) and
  Address Device returned ccode=5; (3) Add-Flags carry-forward — `xhci_input_ctx_add_interrupt_in` OR'd new Add bits
  onto the stale A1 (EP0) flag, so Configure Endpoint with A1=1 told hardware to reload EP0 from a stale Input
  Context whose TR Dequeue Pointer had not moved since Address Device. Linux's `xhci_init_input_control_ctx` sets
  Add Flags = `A0 | A_new` only.
- Post-fix QEMU chain: Enable Slot → CCE, slot 1 · Address Device → CCE · Get Device Descriptor → 18 bytes, VID=1575
  PID=1 class=0 (QEMU usb-kbd) · Configure Endpoint → CCE, EP3 interrupt-IN · `hid: keyboard configured, boot
  protocol on, EP=129, polling 8-byte reports` · `sendkey` h-e-l-p-ret → `agnos> help` echo plus full output ·
  u-p-t-i-m-e-ret → `2216 ticks`.
- Build **411,216 B**.

## [1.30.6] — 2026-05-18 — the xHCI cmd-path arc: Repairs FF through QQ, all falsified
- ⛔ EVERY REPAIR IN THIS TEN-LETTER LADDER LEFT `events_seen=0` INTACT, and none COULD have been correct because the
  bug was compile-time (see 1.30.7). Recorded so none is re-attempted: **FF** — `IMAN = 0x3` (IP W1C-clear + IE=1)
  instead of `0x1` at `xhci.cyr:541`, per xHCI 1.2 §4.17. **GG** — AMD-Vi global IOMMU disable for Renoir
  `1022:1639`: `amd_iommu_disable()` (`iommu.cyr:269-317`) walks PCI 0:0.2's cap list for ID `0x0F` (Secure Device),
  confirms cap type bits [18:16]==0x3, maps MMIO UC and writes the IOMMU Control Register at MMIO+0x18 = 0. FB
  confirmed `amdvi: cap@64 mmio=4247781376 en=1` then `amdvi: disabled, ctrl_rb=0` — AMD-Vi WAS firmware-enabled and
  the write SUCCEEDED, eliminating the strongest platform-side DMA-gating candidate. **HH** — a post-doorbell
  `load32` readback flush in `xhci_cmd_submit`, matching Linux `xhci_ring_cmd_db`'s writel+readl. **JJ** — a
  universal `load32` readback flush on EVERY operational and runtime register write (`xhci.cyr:354-391`), closing
  host-bridge posted-write deferral across CRCR/DCBAAP/ERSTBA/ERSTSZ/ERDP/IMAN/USBCMD/CONFIG. The whole posted-write
  class is CLOSED. **KK** — a CNR (USBSTS bit 11) poll before any operational write; no "CNR never cleared" line
  ever printed, so CNR was already clear at the first poll iteration. **LL** — Link TRB initial cycle fix
  (`xhci_ring.cyr:179-192`, removing `| 0x1` per §4.9.3.1); defensive only. **MM** — PCI MSI-X Function Mask cleared
  with Enable=1 via `pci_enable_msix_unmasked` (`pci.cyr:216-241`). **NN** — the two convergent divergences (below).
  **OO** — four sub-repairs: USBSTS RW1C-clear at `xhci_start` entry (FreeBSD `xhci.c:1463-66`); the `IMAN.IE` write
  moved to AFTER R/S=1 (Linux `xhci.c:1145-7`, reversing FF); an explicit `mfence` before the doorbell; a cmd-ring
  TRB readback. **QQ + QQ''** — the MSI-X audit found AGNOS had NEVER written the MSI-X Table (every vector's
  Address/Data/Vector Control sat at reset, Vector Control = 1 per PCI 3.0 §6.8.2.5.3) while Linux's
  `msix_capability_init` populates Address/Data for every claimed vector BEFORE clearing FuncMask. Three-phase fix:
  Enable + FuncMask=1 → read Table Offset/BIR from cap+0x04, compute `table_phys = BAR(BIR) + offset`, write vector
  0's Address Lo = **0xFEE00000** (BSP LAPIC, dest CPU 0, physical mode), Address Hi = 0, Data = **0x40** (vector
  0x40, Fixed, Edge), Vector Control = 1 (mask preserved because AGNOS polls) → clear FuncMask. Build 368,568 →
  **368,968 B (+400)**. ⚠ MANDATORY ORDERING: the MSI-X enable must run AFTER `vmm_remap_uc_2mb` so the table writes
  land on the UC-remapped BAR chunk.
- Four-source xHCI register-write-order audit (Linux v6.13 `xhci-mem.c`, FreeBSD HEAD `xhci_start_controller`, Haiku
  `XHCI::Start`, EDK2 `XhciSched.c`), run as a four-source net rather than Linux-only because a Linux-only agreement
  could be a Linux architectural quirk. Convergent divergence A — **ERDP written BEFORE ERSTBA**: 3 of 4 agree
  (FreeBSD `xhci.c:1505-6`, Haiku `xhci.cpp:1744-5`, EDK2 `XhciSched.c:2651-9`); Linux is the outlier (2871 vs
  2867-72). Spec basis §5.5.2.3.3 — once ERSTBA is written the controller may begin posting events, and an invalid
  ERDP at that moment is undefined behaviour. Divergence B — **CRCR written AFTER interrupter setup**: 2 of 4
  (FreeBSD `xhci.c:1517-23`, Haiku `xhci.cpp:1756-7`). Divergence C — an explicit memory flush before ERSTBA:
  FreeBSD only (PR 237666), and its `usb_bus_mem_flush_all` exists for weakly-ordered architectures, so on x86-TSO
  with AMD coherent DMA snoop it is a no-op — deliberately skipped. A and B landed as Repair NN and were burned at
  Attempt 62; `events_seen=0` persisted. Both remain in the code as spec-correct convergent alignment. **Zero-risk
  hygiene is not a fix.**
- Read-only diagnostic after `xhci_start` completes the R/S=1 + HCH=0 wait (`xhci.cyr:583-603`), Attempt 58:
  `CRCR.CRR=0 ERSTSZ=1 IMAN=2 ERDP_lo=5672968`. `IMAN=2` (IE=1, IP W1C-cleared) formally confirmed FF stuck.
  `ERDP_lo = 0x569008` = page-aligned `0x569000` plus the EHB bit 3 set BY HARDWARE — proving the ring
  infrastructure was good and the controller had touched the event handler.
- ⚠ Edit B's per-submit TRB phys + dw3 readback print went MISSING from the framebuffer at Attempt 58 because of a
  STALE USB BUILD — the edit was committed at 20:21 while `build/agnos` was timestamped 20:20 and the USB was
  flashed pre-commit. This incident is the origin of the build-freshness discipline.

## [1.30.5] — 2026-05-17 — ★ Repair EE: the xHCI PORTSC silent-absorb arc closed (a homegrown bug)
- ⭐ THE PORTSC DOUBLE-MASK BUG. `xhci_portsc_write` (`xhci_port.cyr:460`) did `store32(addr, (value &
  XHCI_PORTSC_NEUTRAL) | (w1c_clear & XHCI_PORTSC_W1C))`. Masks (`xhci_regs.cyr:235-238`): `XHCI_PORTSC_RO` =
  **0x40003C09** (CCS|OCA|Speed|DR); `XHCI_PORTSC_RWS` = **0x0E00C3E0** (PLS|PP|PIC|WCE/WDE/WOE);
  `XHCI_PORTSC_NEUTRAL` = **0x4E00FFE9** (RO | RWS); `XHCI_PORTSC_W1C` = **0x00FE0002**. PR (bit 4, RW1S) is
  correctly EXCLUDED from NEUTRAL — but the helper RE-APPLIED `& NEUTRAL` to an already-neutralized-and-OR'd value,
  stripping PR straight back out. Call site `xhci_port.cyr:581`: `((psc1 & NEUTRAL) | 0x10) & 0x4E00FFE9` = `(psc1 &
  NEUTRAL) | (0x10 & 0x4E00FFE9)` = `(psc1 & NEUTRAL) | 0x00`. **EVERY PORTSC.PR write across Attempts 32-54 wrote
  PR=0**, and the controller correctly absorbed each one — it was a valid neutral update requesting no change.
- Every observation explained by that one line: USBSTS = 0x00/0x00 (no CNR/HCH/HSE/HCE — the write was accepted);
  PSCchg = 0x00 (no reset transition so no PRC/PEC); PLS unchanged at Polling (0x07); PR retry = 0x03 (3 silent
  absorbs, deterministic); CMOS `[0x6D]` PLS pre-PR = 0x07 confirming the precondition was met, so the bug is in the
  write itself; CCS bitmap 0x04 (port 3 connected — the connection detection worked, only the reset path was
  broken).
- ⛔ ALL 13 HYPOTHESES (F5 / X / V'' / b / W / b' / c / Z / AA / BB / CC / DD / H1-H4) — five days and 19 iron
  attempts — were falsified because NOT ONE touched `xhci_portsc_write`; every "fix" was downstream of a register
  write that never happened.
- Why convergent prior art surfaced it: EDK2 `XhciDxe/Xhci.c` and Linux `xhci-hub.c` both compute `neutralized =
  (read & RO_MASK) | (read & RWS_MASK)` then `write = neutralized | NEW_RW1S_BITS`. NEITHER re-applies the neutral
  mask after OR-ing in PR — neutralization is a ONE-SHOT operation. AGNOS's helper was correct only for callers
  writing RWS bits (`xhci_ports_power_on` OR-ing PP `0x200`, which IS in NEUTRAL) and broke every RW1S write (PR
  `0x10`, WPR `0x80000000`).
- Phase 4 (Configure Endpoint + SET_PROTOCOL=boot + transfer ring) and Phase 5 (HID→PS/2 translation + report differ
  + event drain + `kb_buf` writer) landed here.

## [1.30.4] — 2026-05-17 — xHCI Linux-diff hardening closeout (Repair BB + follow-ups)
- Device Notification Control + stamp redesigns + a double xfer-ring leak; Phase 4/5 lanes opened in parallel. Build
  ~350,272 B (from 350,008 B).

## [1.30.3] — 2026-05-17 — xHCI Phase 3 deep dive: Repair (AA) scratchpad allocation
## [1.30.2] — 2026-05-16 — `vmm_remap_uc_2mb` lands the xHCI BAR on PA3=UC
- The BAR memtype audit result: AGNOS matches Linux `ioremap_uc()` semantics on archaemenid — PWT=1 + PCD=1 + PAT=0
  selects PAT entry 3 = strict UC under the firmware PAT MSR value **0x0007040600070406**.
- Builds across the cut: 266,312 → 273,816 B (+7,504, bus master + `kcp = 0x30`); 341,864 → 342,408 B; 342,408 →
  343,384 B (+976, R10 PLS gate); a constant fix was binary-size byte-equivalent (343,384 B both sides).

## [1.30.0] — 2026-05-13 (iron-validated 2026-05-15) — ⚠ KERNEL ABI BREAK: multiboot2 → sovereign boot_info

### Breaking

**The kernel entry contract changes from multiboot2 to the AGNOS sovereign `boot_info` struct
(Path C).** GRUB's `grub_relocator64_efi_boot` patches six `movabs %rax,<imm64>` immediates inside its OWN loaded
`.text` (stub `grub_relocator64_efi_start`, `lib/i386/relocator64.S:95-164`; positions verified via `.rela.text`
offsets `0x342B-0x3471` mapping to `grub_relocator64_{rax,rbx,rcx,rdx,rip,rsi}` at `.text 0x8AA-0x8F7`), and under
OVMF 2024+ strict W^X those self-writes `#PF`. The GRUB EFI64 stub also performs NO long-mode-exit sequence — no
`cli`, no `lgdt`, no CR0.PG clear, no CR4.PAE clear, no EFER.LME clear — so an ELF32/EM_386 kernel triple-faults at
its first instruction because 32-bit opcodes are decoded as 64-bit in long mode. Strict-NX policy value:
`PcdDxeNxMemoryProtectionPolicy = 0xC000000000007FD5` (strict) vs `0xC000000000007FD1` (bug-compatible).

**Migration.** The kernel is now loaded by **gnoboot**, a Cyrius-native PE32+ UEFI Application
installed as `EFI/BOOT/BOOTX64.EFI`. At kernel entry **RDI holds the physical address of the `boot_info` struct**
(SysV, arg 0) instead of multiboot2's RBX/EAX pair. The agnos-side swap was six edits: `mbi.cyr` asm byte `0x18` →
`0x38` (`mov [rax],rbx` → `mov [rax],rdi`); `mbi_capture_rbx` → `boot_info_capture_rdi`; `mb_info_ptr` →
`boot_info_ptr`; `boot_shim.cyr` comments + call site; VERSION 1.29.1 → 1.30.0; cyrius pin 5.11.43 → 5.11.53. The
ELF64 long-mode entry base (stack setup, GDT inheritance, segment reload via push-lea-push-retfq) is unchanged.

**The `boot_info` ABI (authoritative source = the gnoboot repo).** `magic` = **0x41474E4F** ('AGNO')
@0x00 · `version` = **2** @0x04 · `struct_size` = **120 (0x78)** @0x08 · `flags` @0x0C (bit0 serial, bit1
framebuffer) · `initramfs_phys` @0x10 · `initramfs_size` @0x18 · `cmdline_phys` @0x20 · `memmap_phys` @0x28 ·
`memmap_count` @0x30 · `memmap_entsize` @0x34 (firmware-reported, `0x30` or `0x38`) · `acpi_rsdp_phys` @0x38 ·
`efi_st_phys` @0x40 · `fb_phys` @0x48 · `fb_pitch` @0x50 · `fb_width` @0x54 · `fb_height` @0x58 · `fb_pixel_format`
@0x5C (0=RGB888x, 1=BGR888x, 2=bitmask, 3=blt-only) · `fb_mode_current` @0x60 · `fb_mode_max` @0x64 · `fb_size`
@0x68 · tag stream / END tag type=0 @0x70. The framebuffer fields are INLINED at fixed offsets rather than living in
the tag stream because the kernel's boot-shim canary reads `fb_phys` from raw asm at entry instruction #1, before
stack setup and before any cyrius fn call — walking a tag stream in raw asm is impractical, and inlining makes the
canary 26 bytes total. Tag types: 0 END, 2 boot_loader_name, 3 uefi_handle;
**type 1 (framebuffer) was RESERVED in v1 and is now inlined — walkers MUST NOT expect a fb tag.**
`memmap_entry` = {`phys_addr` u64, `size_bytes` u64, `type` u32 (1 usable, 2 reserved, 3 ACPI reclaim, 4 ACPI NVS, 5
bad, 6 boot-services now ours, 7 runtime-services), `attributes` u32}. The struct grew 112 (0x70) → 120 (0x78) at
gnoboot 0.4.3 when `fb_size` was added at 0x68 and the END tag moved 0x68 → 0x70; the wire version stayed v2 because
no consumer walks the tag stream, and a pre-0.4.3 gnoboot leaves zero at 0x68 with the kernel's
`fb_size_or_fallback()` falling back to pitch × height.

- Four Path-A workarounds considered and REJECTED: a vendored patched GRUB fork (indefinite maintenance tail); a
  Linux Boot Protocol / bzImage pretender (ties AGNOS's boot protocol to Linux's in perpetuity — anti-sovereignty);
  a loose-W^X OVMF rebuild (diagnostic only); Path B, a hand-rolled long-mode-exit prologue keeping ELF32
  (hand-rolls what GRUB should do, with no path toward Path C). Cyrius was NOT at fault: `EMITELF64_KERNEL` (cyrius
  5.11.43) produced a correct ELF64 multiboot2 kernel that GRUB ACCEPTED (`grub-file --is-x86-multiboot2` PASS, RAX
  magic loaded, handoff prepared), so no cyrius issue was filed from that gate.
- The multiboot2 header AGNOS had emitted (48 bytes, 8-byte aligned, in the first 32 KB): magic `0xE85250D6`@0x00 ·
  architecture `0x00000000`@0x04 · header_length `0x30`@0x08 · checksum `0x17ADAEFA`@0x0C · ENTRY_ADDRESS_EFI64 tag
  type=9 flags=0 size=12 @0x10-0x1C · MODULE_ALIGN tag type=6 size=8 @0x20 · END tag type=0 size=8 @0x28. It
  replaced the multiboot1 header `0x1BADB002` / `0x00000003` / `0xE4524FFB`.
- UEFI post-ExitBootServices entry contract, converged across the Linux EFI stub, FreeBSD `loader.efi`, OpenBSD
  `efiboot`, Windows winload and Limine: long mode, ring 0, paging on with UEFI's identity map for low memory (UEFI
  2.10 §2.3.4); the firmware GDT survives but every kernel reloads its own; the IDT is undefined; CR0 PG=1 PE=1 WP=1
  NE=1; CR4 PAE=1 with OSFXSR/OSXMMEXCPT typically set but **SMEP/SMAP NOT guaranteed**; EFER LME=1 LMA=1 NXE=1;
  interrupts disabled; DF clear; the framebuffer keeps displaying post-EBS; the memory map MUST be captured before
  EBS; the RSDP is located via EFI_CONFIGURATION_TABLE while boot services live; calling convention SysV (RDI =
  arg0) everywhere except Windows.
- ⚠ UEFI 2.x §7.2: `AllocatePages` returns memory with UNDEFINED contents. QEMU OVMF happens to return zeroes; real
  firmware leaves POST scratch, so kernel `.bss` reads garbage on iron and triple-faults at first reference —
  gnoboot zeroes the BSS gap over `[p_filesz, p_memsz)` after the segment read. ⚠ Strict-W^X firmware NX-marks
  `EfiLoaderData`, so a `jmp` into it silently `#PF`s on iron (OVMF runs from LoaderData regardless, masking it) —
  gnoboot allocates the kernel destination as **EfiLoaderCode (1)**, not EfiLoaderData (2).
- Kernel builds across the cut: 253,768 → 266,712 B; 266,712 → 266,312 B (−400, cp_fb call removal); 255,048 →
  253,496 B (−1,552); 253,496 → 253,768 B (+272).

## [1.29.1] — 2026-05-13 — boot-shim portability fix: CPUID-gate SMEP and SMAP
- v1.29.0 ORed CR4 bits 20 (SMEP) and 21 (SMAP) unconditionally alongside PAE, which triggers `#GP` on any CPU that
  does not advertise the feature in CPUID leaf 7 sub-leaf 0 EBX bits 7 and 20. The shim has no exception handlers at
  that point, so `#GP` cascades through `#DF` to triple-fault. PAE (bit 5) remains unconditional — multiboot1
  long-mode handoff requires it. Implementation: build the new CR4 value in EBX (leaving EAX free for CPUID
  features), `push ebx` across `cpuid`, then `test`/`jz` each feature bit before ORing. Shim growth 41 bytes; kernel
  **250,936 → 250,968 B**. ⚠ On Zen (the primary iron target, which advertises both) this is BEHAVIOURALLY IDENTICAL
  to v1.29.0 and is NOT a confirmed causal fix for Attempt 3's silent reset.

## [1.29.0] — 2026-05-11 — 1.28.x arc gate / 1.29.x arc opens (no kernel-source behaviour change)
- `scripts/build.sh` x86_64 **250,704 B** (unchanged from v1.28.3); `--aarch64` **93,288 B**.

## [1.28.3] — 2026-05-11 — struct refactor with `#derive(accessors)` (partial, blocked on a cyrius cap)
- x86_64 **250,704 B** (was 249,984 B); aarch64 **93,288 B** unchanged.

## [1.28.2] — 2026-05-11 — VFS tagged unions ship (`kernel/lib/ktagged.cyr`)
- x86_64 **249,984 B** (was 249,152 B); aarch64 **93,288 B** (was 92,488 B).

## [1.28.1] — 2026-05-11 — the `serial_putc` regression closed (not a real codegen regression)
- Methodology work: `bench-history.csv` extended with provenance columns and re-measured under documented
  conditions.

## [1.28.0] — 2026-05-11 — KASLR (data-only) ships, closing Security Hardening S7
- The kernel binary stays at fixed `0x100000`; dynamically-allocated kernel data (heap, slab pages, per-process
  stacks) now lands at randomized offsets within the 2–16 MB physical window. x86_64 **249,152 B** (was 248,896 B);
  aarch64 **92,488 B** (was 92,216 B).

## [1.27.2] — 2026-05-11 — closeout pass for the 1.27.x arc (no kernel-source behaviour change)
- x86_64 **248,896 B** unchanged; aarch64 **92,216 B** unchanged.

## [1.27.1] — 2026-05-11 — ★ memory isolation: PASS
- Closes the long-running "deeper fault" carry-forward (v1.25.1 → v1.26.0 → v1.27.0). ROOT CAUSE was **SMAP** — the
  boot shim sets `CR4.SMAP` (bit 21, part of the `0x300020` OR-mask) and `proc_map_page` writes US=1 (`0x87`)
  per-process PDEs, so a ring-0 access to a user page faults. x86_64 **248,896 B** (was 247,752 B); aarch64 **92,216
  B** unchanged.

## [1.27.0] — 2026-05-11 — cyrius pin 5.7.22 → 5.10.44; ecosystem realignment
- Dead code that no caller reached was eliminated: the aarch64 binary shrinks **95,328 → 92,216 B**. x86_64
  **247,752 B** (was 247,816 B).

## [1.26.1] — 2026-04-27 — cyrius pin 5.7.19 → 5.7.22
- x86_64 **247,816 B** unchanged. The braces-in-comments formatter fix lets agnos restore natural ``var x = y; asm {
  mov cr3, rax; }`` doc-comment phrasing.

## [1.26.0] — 2026-04-27 — `cr3_load` helper + investigations on residual issues #6 / #7
- x86_64 **247,816 B** (v1.25.1: 247,768 B; +48).

## [1.25.1] — 2026-04-27 — per-process page-table mirror fix + memory-isolation test gated
- x86_64 **247,768 B** (previous 248,848 B; −1080 B).

## [1.25.0] — 2026-04-27 — ACPI identity-map fix (the post-`Devices registered` boot stall)
- x86_64 **248,848 B** (previous 248,720 B; +128 B); aarch64 **95,136 B** untouched (x86_64-only fix).

## [1.24.1] — 2026-04-27 — comments-only patch closing hygiene items H1 + H2
- Kernel binary unchanged at **248,720 B**; same `-cpu max` boot path.

## [1.24.0] — 2026-04-27

## [1.23.0] — 2026-04-27 — Cyrius toolchain bump 3.9.8 → 5.7.12 (cc3 → cc5)

### Breaking

**`cyrius.toml` → `cyrius.cyml`, and `.cyrius-toolchain` is REMOVED.** The package version is now
resolved from `VERSION` via `${file:VERSION}` templating — no in-place version edit in the manifest.
**Migration:** the toolchain pin lives ONLY on the manifest's `cyrius = "5.7.12"` line (single source
of truth, matching kybernet). `scripts/build.sh` / `test.sh` invoke only `cyrius build` — no direct `cc5` /
`cc5_aarch64` calls (`cc5_aarch64`'s existence still gates the aarch64 path); `--no-deps` is passed since `[deps]`
is empty. CI reads the toolchain version from `cyrius.cyml` and asserts `version = "${file:VERSION}"`; the format
check moves from raw `cyrfmt` to `cyrius fmt --check`. The release tag matcher accepts `1.2.3` or `v1.2.3`.
`scripts/version-bump.sh` edits 8 files, not 9.

- `scripts/check.sh` kernel-binary upper bound **150 KB → 350 KB**: cc5 emits more code than cc3 did (~250 KB at
  v1.23.0 vs ~110 KB at v1.22.0), and the previous bound would have made the gate a no-op.
- x86_64 **248,720 B**, multiboot magic `0x1badb002`, entry `0x100060`; aarch64 **95,136 B**. `check.sh` 11/11;
  `test.sh --all` 7/7 (4 x86_64 + 3 aarch64).

## [1.22.0] — 2026-04-13 — ACPI + Intel VT-d IOMMU + the security-hardening block (31 fixes)

### Breaking

**Process table stride 168 → 176 bytes** (added the `exit_code` field at offset 168). Any consumer
indexing `proc_table` by a hardcoded 168-byte stride must be updated. **VirtIO-net RX buffer 256 → 2048 bytes**
(matches the descriptor). **SYSCALL entry stub 128 → 256 bytes** (KPTI + IBRS instructions). **GDT 7 slots → 13
slots** (4 per-CPU TSS descriptors). **Stack spacing 2 MB → 4 MB per process** (guard-page room). User pages are now
mapped with the NX bit (bit 63) by default; the boot shim's CR4 enables SMEP+SMAP and EFER enables NXE, so any user
page that must execute has to be mapped through `vmm_map_user_exec()`.

- Added: ACPI table parsing (RSDP scan, RSDT/XSDT walk, DMAR); an Intel VT-d IOMMU driver (DMA remapping,
  root/context/IO page tables); per-CPU TSS infrastructure (4 TSS descriptors in the GDT, per-CPU kernel stacks,
  APIC-ID routing); a stack-canary framework (RDRAND-seeded secret, checks in `ksyscall`, `elf_load`,
  `net_handle_tcp`); partial KPTI (dual page tables per process, CR3 switching on SYSCALL entry/exit); Spectre v2
  mitigation (IBRS set/clear on SYSCALL entry/exit, CPUID-gated); stack guard pages (an unmapped 2 MB region below
  each user stack); per-process exit codes at offset 168; per-connection TCP RX buffers (heap-allocated, freed on
  close); ARP request tracking (reject unsolicited replies); TCP sequence/ACK validation with a receive-window
  check; randomized TCP ISNs; `proc_unmap_page()`; `vmm_map_user_exec()`; `is_user_ptr`/`is_user_range` in all
  syscalls; a PMM spinlock.
- Fixed (the 31-item security block): a UDP buffer overflow — a 2040-byte copy into a 256-byte buffer, remote and
  unauthenticated; a VirtIO RX DMA overflow (descriptor declared 2048, buffer was 256); arbitrary kernel R/W via
  unvalidated userspace pointers in **8 syscalls**; an ELF loader accepting unbounded
  phoff/phnum/p_offset/p_filesz/p_memsz/entry; PMM negative page index and double-free; a VFS memfile position
  underflow (`fsize - pos` when `pos > fsize`); an IP payload length underflow (`ip_total < ip_ihl`); TCP header
  length underflow and RX buffer overflow; `kill()` allowing any process to signal any other including PID 0;
  unvalidated initrd data offset; an unvalidated FAT16 cluster number; kernel code pages mapped user-accessible in
  per-process page tables. Also: `kfree_sized` zeroes freed blocks; `spin_unlock` uses an atomic `xchg` instead of a
  plain store; `spawn_user_proc` copies code to a separate physical page at the user VA.
- Kernel binary **239 KB → 260 KB (+8.8%)**. 12/13 security roadmap items complete (S1-S6, S8-S13); S7 (KASLR)
  deferred, blocked on Cyrius v4.4.0 PIE support.

## [1.21.0] — 2026-04-13 — kernel stdlib + the P-1 hardening block (14 buffer overflows)

### Breaking

**Fourteen kernel arrays were undersized and are resized.** Any code assuming the old bounds is
wrong. `proc_table[336]` → **[2688]** (16 procs × 168 B — the old value held 2 procs);
`proc_signals[16]`/`proc_sigmask[16]` → **[128]**; `idt[512]` → **[4096]** (256 vectors × 16 B — the old value
overflowed by 3584 bytes); `gdt[8]` → **[56]**; `tss[16]` → **[104]**; `kb_isr[64]` →
**[96]** (an 83-byte ISR); `sc_normal[16]`/`sc_shifted[16]` → **[128]** (128-entry scancode tables);
`vfs_table[128]` → **[1024]** (32 fds × 32 B); `dev_table[64]` → **[512]**; `pci_devs[64]` →
**[1024]**; `sh_buf[16]` → **[128]** (it had been accepting 126 chars into 16 bytes);
`tcp_conns[80]` → **[640]** (8 connections × 80 B). Also: the pipe circular-buffer mask `& 4087` → `% 4088` (4088 is
not a power of two, so the mask was wrong).

- Added: a vendored kernel stdlib — `kstring.cyr` (strlen, streq, memeq, memcpy, memset, memchr, strchr, atoi,
  strstr) and `kfmt.cyr` (fmt_int_buf, fmt_hex_buf, kfmt_int, kfmt_hex, kfmt_hex0x, kfmt_byte) under a new
  `kernel/lib/`; `cyrius.toml` metadata; `.cyrius-toolchain` pinning (3.9.8); a kernel test suite of **106
  assertions across 7 categories** (PMM, heap, VFS, proc, syscall, kstdlib, initrd) with `scripts/ktest.sh` and a
  `#ifdef TEST`-gated shell `test` command; PCI device IDs displayed in hex; CI grown 4 → 7 jobs.
- Fixed alongside: `vfs_create_pipe()` leaked memory on fd-alloc failure; `proc_create_address_space()` had no
  allocation rollback on pmm failure; signal-number bounds checks in `kill` and `proc_send_signal`; an epoll
  watch-list capacity check (max 8 watches in 128 bytes); the ELF loader returned success on `pmm_alloc` failure;
  VFS `read`/`write` now validate `buf != 0` and `count >= 0`; FAT16 rejects `cluster < 2`; the initrd file count is
  capped at 256.
- Metrics: binary **220 KB** (x86_64), **57 KB** (aarch64); ~4,800 lines across 46 files; **26 syscalls**; 33
  subsystems; 19 shell commands; 106 kernel assertions.

## [1.11.0] — 2026-04-07 — GRUB bootable ISO + TCP/IP + VirtIO-blk + FAT16 reader
- Added: a GRUB bootable ISO (`scripts/iso.sh`, `boot/grub/grub.cfg`) with an ELF fixup for GRUB compatibility; a
  TCP/IP stack (connect, send, recv, close, connection table, 3-way handshake); a VirtIO-blk driver (sector
  read/write, DMA-safe buffers, PCI bus mastering); a FAT16 reader (boot sector, directory listing, file open/read);
  shell `tcp`, `blkread`, `ls`, `disk`.
- Fixed: 6 tilde-operator (`~`) replacements with two's complement; 7 string-length off-by-one fixes; the SMP
  trampoline's 32-bit code no longer overruns the 64-bit section (data at 0x8180+).
- Metrics: binary **143 KB** (x86_64), **57 KB** (aarch64); 26 syscalls; 18 shell commands.

## [1.2.0] — 2026-04-07 — VirtIO-net receive path + signal delivery + pipes
- Added: `virtio_net_poll` / `net_poll` / `net_recv_udp` / ARP cache updates; SIGCHLD on process exit with a
  pending-signal check in the scheduler; **pipes as VFS type 6** with a 4 KB circular buffer and the `pipe` syscall
  (**#25**); shell `recv` and `pipe`; `proc_send_signal`, `proc_check_pending_signals`, `proc_get_ppid`;
  `net_handle_arp` / `net_handle_udp`.
- Metrics: binary **115 KB** (was 98 KB); 26 syscalls (was 25); 14 shell commands (was 12).

## [1.1.0] — 2026-04-06 — multi-architecture split + 17 kybernet syscalls + benchmarks

### Breaking

**The monolithic `kernel/agnos.cyr` is split into 33 files**: `arch/x86_64/` (14), `core/` (15),
`user/` (3), plus the main orchestrator. Build with `sh scripts/build.sh --aarch64` using `-D ARCH_AARCH64`. Shared
code is asm-free behind an `arch_wait()` / `arch_halt()` abstraction.
**17 new syscalls take the total from 8 to 25** — dup, mkdir, rmdir, mount, sync, reboot, pause,
getuid, kill, sigprocmask, signalfd, epoll_create, epoll_ctl, epoll_wait, timerfd_create, timerfd_settime, umount.
New VFS types: signalfd (3), epoll (4), timerfd (5).

- Added: an aarch64 port (PL011 UART, GIC, ARM generic timer, keyboard via UART RX, paging stubs) booting to
  PMM+heap init on `qemu-system-aarch64 -M virt`; per-process `proc_signals[]` / `proc_sigmask[]`; `rdtsc()`
  cycle-accurate benchmarks — **PMM 1304 cy/op, syscall 188 cy/op, heap 1207 cy/op**; `scripts/bench.sh`,
  `scripts/check.sh` (11-point validation), `scripts/version-bump.sh`.
- Optimizations: a PMM `next_free` hint for O(1) sequential allocation; PMM init using a 64-byte `memset` instead of
  512 `pmm_set()` calls; `kmalloc` zeroing only the requested size.
- Fixed: `inb`/`outb` had wrong rbp offsets from extra `var p = port` copies; `slab_grow()` flags `0x03` →
  **`0x83`** (the correct 2 MB page flag); global variable initializers not persisting in kernel mode — explicit
  init at boot.

## [1.0.0] — 2026-04-05 — the first release: x86_64 kernel booting to an interactive shell
- Core: full x86_64 kernel with multiboot1 boot, a 32-to-64 shim and serial I/O; GDT (5 segments + TSS descriptor),
  IDT (256 vectors), PIC (8259A remap); TSS for ring-3 transitions with RSP0.
- Interrupts and timers: Local APIC (MMIO at **0xFEE00000**, timer, IPI); an APIC periodic timer at ~100 Hz
  replacing the PIT; PS/2 keyboard with a full US QWERTY scancode map.
- Memory: page tables with a 16 MB identity map using 2 MB huge pages, plus per-process tables; a physical memory
  manager (bitmap allocator, 4096 pages, next-free hint); a virtual memory manager with map/unmap/alloc and TLB
  invalidation; a kernel heap slab allocator with **8 size classes (32-4096 B)**.
- Processes: a 16-slot process table with a **168-byte context** and per-process CR3; full-register context switch;
  round-robin scheduler; SYSCALL/SYSRET with MSR setup and ring-3 transition.
- **Syscalls 0-7: exit(0), write(1), getpid(2), spawn(3), waitpid(4), read(5), close(6), open(7).**
- Filesystem and drivers: a static ELF64 loader with per-process address space; VFS file table with device and
  memfile types; a serial char device; a flat-format initrd with name lookup.
- Networking: PCI config-space scan and device discovery; legacy-PCI VirtIO-Net with virtqueues and Ethernet frames;
  an IP/UDP stack with ARP, IPv4 and UDP send.
- SMP infrastructure (APIC, IPI, trampoline, per-CPU stacks); an interactive shell with 12 commands; kybernet init
  as PID 1.
- Phase 10 audit fixes: PMM bounds checking (`page >= 4096` guard); a process-table overflow guard (`proc_count >=
  16`); ISR full register save (9 caller-saved regs instead of 3); syscall `write` length clamped to 4096 with
  null-pointer rejection; process-state validation in syscall handlers.
- Metrics: binary **106 KB** (x86_64); ~2,980 lines, 122 functions in a single file; 27 subsystems; 8 syscalls;
  boots to an interactive shell on QEMU in **<100 ms**.

