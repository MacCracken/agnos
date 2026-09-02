---
name: Vacuous gates — 33 assertions that pass by enumerating nothing
description: Tree-wide sweep of the vacuous-pass class, found while closing the klug (string,length) class at 1.56.57. Every finding independently verified against source.
type: issue
---

# Vacuous gates — 33 confirmed, 39 fixed at 1.56.58

**Status: MOSTLY FIXED at 1.56.58. 39 fixed / 1 declined / surfaces still unswept — STAYS OPEN.**
Filed 2026-09-02 at 1.56.57 with none acted on; swept the same day at 1.56.58, one agent per file,
each fix mutation-proven against its own empty-input case and then adversarially re-verified.

**Why it is not archived.** Three reasons, and none of them is bookkeeping:

1. **One finding was examined and DECLINED, not fixed** — `scripts/smoke/tonegen-smoke.sh` carried a
   second vacuity beyond the assigned one; the assigned one is fixed, the second is recorded there.
2. **The sweep surface was a floor, not a total.** It covered `scripts/smoke/*.sh`, `check.sh`,
   `check/*.sh`, `harness/*.py`, `probe/*`, `tool/*` and `ktest.sh`. It did **NOT** cover
   `.github/workflows/*.yml`, `scripts/burn/*`, or the `tests/*/` per-project harnesses. Closing this
   file requires sweeping those.
3. ⛔ **Two fixes moved the vacuity one level up rather than removing it, and adversarial verification
   caught both.** `scripts/harness/agnsh-kvm-test.py` GATE 2 scores `if new.strip()` over serial
   growth — but the kernel log writes to the SAME COM1 asynchronously, so ordinary kernel chatter
   inside the ~5 s typing window satisfies it with **zero keystrokes delivered**. A floor that any
   unrelated producer can satisfy is not a floor. Re-verify before trusting that gate.

**What shipped alongside.** Six more vacuities were found *while proving* the assigned ones and fixed
in the same pass — `modeset-latch-smoke.sh` had 4 of the same shape, `check-carveout.sh` 3,
`chan-semantics-check.sh` 2 — which is why 33 findings produced 39 fixes.

⚠ **A regression was introduced and then closed during this work, and it is worth recording because
it is the same class.** `kprint-len-check.sh`'s new corpus floor was first written to apply to every
invocation, which broke the documented single-file usage (`[file ...]`, line 13); exempting single-file
mode then re-opened the hole from the other side, since a **missing** file enumerated 0 literals and
scored PASS. A literal COUNT cannot discriminate there at all: `kernel/core/kprint.cyr` legitimately
holds zero matching literals, because it is where the emitters are *defined*. The floor that works is
**"did I read every file I was handed?"**, which is true of a healthy single file, a healthy tree, and
nothing else.

## What this is

A **vacuous pass** is an assertion whose success condition is satisfied when its input set is
EMPTY. It is this tree's own named failure mode — `ci.yml`'s security job calls out "a gate that
passed by enumerating nothing", `toolchain-pin-check.sh` carries an explicit VACUITY FLOOR for
exactly this reason, and the 1.56.44 cut records three gates found unrunnable or unfalsifiable.

Two instances were closed at 1.56.57 as part of the klug work:

* `scripts/check/kprint-len-check.sh` — gained a floor (`total < 3000` is now an error, not a
  green "0 mismatched"). Mutation-proven.
* `scripts/smoke/klug-spill-smoke.sh` — its "independent oracle" enumerated `grep -a "^klug: "`
  and compared **1 line out of 83**; at zero matches it would have scored PASS having compared
  nothing. Replaced with a self-calibrating invariant that compares 82. Mutation-proven on 4 axes.

The sweep that found those two was then run tree-wide. The 33 below are what it returned, each
one adversarially re-verified against source by a second reader.

## Why the count is a floor, not a total

The sweep covered `scripts/smoke/*.sh`, `scripts/check.sh`, `scripts/check/*.sh`,
`scripts/harness/*.py`, `scripts/probe/*`, `scripts/tool/*` and `scripts/ktest.sh`. It did **not**
cover `.github/workflows/*.yml`, `scripts/burn/*`, or the `tests/*/` per-project harnesses.

## The five shapes

| | shape | why it passes on nothing |
|---|---|---|
| V1 | count-of-failures == 0 over an unfloored enumeration | empty set -> 0 failures -> PASS |
| V2 | negative assertion over a producer whose success is unchecked | producer died -> no output -> nothing to match -> PASS |
| V3 | a missing prerequisite degrades to skip, not fail | tool absent -> exit 0 |
| V4 | a parse that rots turns the assertion into a no-op | `[ -n "$X" ] && check` with X empty |
| V5 | the oracle is derived from the artifact under test | build flag absent -> the check is not compiled -> lane retired |

## Findings

### `scripts/ktest.sh:170` — CRITICAL

**The kernel functional test suite reports ALL TESTS PASSED when the in-kernel suite enumerated ZERO tests. Only the failure count is parsed; no minimum pass count is ever asserted.**

Source: line 169 `FAILURES=$(echo "$TOTAL_LINE" | sed 's/.*passed, //' | sed 's/ failed.*//' | tr -d '[:space:]')`; line 170 `if [ "$FAILURES" = "0" ]; then` -> line 171 `echo "RESULT: ALL TESTS PASSED"`; line 172 `exit 0`. Proof: the producer is kernel/user/test.cyr:464-468 `serial_print("TOTAL: ",7); ... serial_print(" passed, ",9); ... serial_println(" failed",7)`. Feed it a suite that ran nothing and the line is `TOTAL: 0 passed, 0 failed`; the sed pair yields FAILURES="0", the equality at :170 holds, and the harness exits 0 announcing a full pass. The only guard above it (line 164 `if [ -z "$TOTAL_LINE" ]`) fires on a MISSING line, never on a line reporting zero tests. The pass count is never compared to anything — this script's own header at line 134 records the known-good tally ("the suite runs: 97 passed, 6 failed") and nothing in the script reads it. Scenario: any `#ifdef` change that compiles the seven check bodies out of sh_cmd_test (all seven are `#ifdef TEST`-gated per lines 87-92) leaves the reporter intact, prints 0/0, and ktest.sh certifies the kernel green having executed no test.

### `scripts/smoke/exec-smoke.sh:235` — CRITICAL

**The spawn_path #43 gate and its EXEC-DISK-OK corroboration are gated on a string read out of the binary under test; the sweep's build env omits RING3_SELFTEST, so this block always skips in the release sweep.**

Source: line 235 `if strings "$AGNOS" | grep -q "ring3: spawnpath OK"; then` enclosing the two checks at lines 236-241 and 243-248, closing at line 249 with no else. The oracle is the artifact under test: kernel/core/main.cyr:5603 `if (spcode == 42) { kprintln("ring3: spawnpath OK", 19); } else { kprintln("ring3: FAIL spawnpath", 21); }` is behind RING3_SELFTEST. The script's own comment at lines 230-234 states it: "The default EXEC-only build lacks the 'ring3: spawnpath OK' string, so this whole block is skipped there." Proof it is skipped in practice: scripts/sweep.sh:132 `run_gate "1.40.x exec-from-disk (run /bin/prog2 + ENOEXEC)" "EXEC_SELFTEST=1 EXT2_WRITE_SELFTEST=1" "exec-smoke.sh"` — no RING3_SELFTEST. Scenario: spawn_path#43 or poll-waitpid#4 breaks; the sweep's exec gate stays green because the check was never compiled into the kernel it built, and the smoke silently agrees.

### `scripts/smoke/ext2-write-smoke.sh:147` — CRITICAL

**Seven metadata_csum assertions (csum seed, superblock, group-0, block-bitmap, inode-bitmap, inode, dir-leaf) are wrapped in an if whose condition comes from the kernel's own log line, and the smoke's DEFAULT mkfs feature set disables checksums — so all seven never run, including in the sweep. There is no else branch.**

Source: line 147 `if strings "$LOG" | grep -q "ext2w: csum on=1"; then` opening a block that closes at line 206 `fi` with NO else, containing the checks at lines 162, 170, 175, 182, 187, 194, 201. Proof of emptiness: line 76 `EXT2_SMOKE_FEATURES="${EXT2_SMOKE_FEATURES:-^resize_inode,^dir_index,^metadata_csum,^64bit,^uninit_bg}"` — the leading `^` on metadata_csum turns checksums OFF at mkfs (line 92 passes it to mkfs.ext2). The producer is kernel/core/ext2.cyr:3807 `kprint("ext2w: csum on=", 15); kprint_num(ext2_csum_on);`, which on such an image emits `ext2w: csum on=0`, so the grep at :147 never matches. scripts/sweep.sh:129 runs this smoke as `run_gate "ext2 WRITE regression (W1-W5)" "EXT2_WRITE_SELFTEST=1" "ext2-write-smoke.sh"` and sets no EXT2_SMOKE_FEATURES override, so in the release sweep this block has never executed. Scenario: crc32c/superblock/inode checksum computation can regress arbitrarily and ext2-write-smoke prints its full green wall and exits 0.

### `scripts/harness/agnsh-kvm-test.py:53` — CRITICAL

**Same shape as agnsh-type-test.py: no rc, no sys.exit, banner printed but never gated — always exits 0.**

Line 53-54: `ok = False / for _ in range(100): if "agnoshi" in ser(): ok = True; break` then `p("banner seen:", ok)` with no `if not ok:` branch. File is 77 lines and ends at line 77 with `except subprocess.TimeoutExpired: qemu.kill()`; `grep -n 'rc =\|sys.exit'` yields only line 39 `if s is None: p("FAIL: no monitor"); sys.exit(1)`. SUCCESS CONDITION: reaching end of file. EMPTY-INPUT SCENARIO: QEMU starts under `-enable-kvm -cpu host` (line 20) but the guest never boots — the monitor socket connects (so the sys.exit(1) at 39 does not fire), every `ser()` returns "", line 71 prints the NO-new-output banner, exit 0.

### `scripts/harness/agnsh-type-test.py:57` — CRITICAL

**Harness has no verdict and no exit code — it always exits 0, including on a boot that produced zero serial output.**

Line 57-58: `p("banner seen:", ok)` — the banner result is PRINTED and never gated (contrast every sibling, e.g. sweep-test.py:149 `if not ok: p("FAIL: no agnsh banner"); sys.exit(1)`). The file is 98 lines and ends at line 98 with `except subprocess.TimeoutExpired: qemu.kill()`; there is no `rc` variable and no `sys.exit()` anywhere (`grep -n 'rc =\|sys.exit' harness/agnsh-type-test.py` returns only line 44 `if s is None: ... sys.exit(1)`). SUCCESS CONDITION: falling off the end of the script. EMPTY-INPUT SCENARIO: the guest triple-faults or the image at build/agnsh-smoke/agnos-agnsh.img is stale — `ser()` (lines 52-54) swallows OSError and returns "" on every call, `ok` stays False, line 92 prints `(((NO new output — keystrokes did not register)))`, and the process exits 0. README.md lists this harness as proving "basic typed-input paths".

### `scripts/probe/kriya-crash-probe.py:89` — CRITICAL

**`rc = 0` is set unconditionally after the hang detector, so a probe that detected and reported a hang still exits 0.**

Lines 79-89: ``` for cmd in ['bnrmr hi\n', 'kriya true\n', 'owl -p /hello.txt\n', 'echo Hello\n']:     seg = run(cmd, timeout=35)     ...     if "ASSIST" not in seg:         p(f">>> HUNG at {cmd.strip()!r} — no prompt returned, halting probe")         break p("=== full serial tail ===") p(ser()[-3000:]) rc = 0 ``` Line 39 initialises `rc = 1`; line 89 overwrites it to 0 outside the loop, unconditionally; line 95 `sys.exit(rc)`. SUCCESS CONDITION: reaching line 89. EMPTY-INPUT SCENARIO: every command wedges (or `ser()` returns "" because the serial log is unreadable) — `seg` is "" for the first command, `"ASSIST" not in seg` is True, ">>> HUNG" prints, break, and the probe exits 0. The banner gate at line 76 (`if not ok: ... sys.exit(1)`) covers only a boot that never printed "agnoshi", not one that printed it and then hung.

### `scripts/smoke/exfat-smoke.sh:170` — HIGH

**The seeded-file read-back gates run only when SEEDED=1, which requires EXFAT_SEED to be set; the sweep never sets it. Worse, when EXFAT_SEED IS set and the loop mount fails, the script prints WARNING, leaves SEEDED=0, and the gates are skipped — the smoke passes precisely because the setup it needed failed.**

Source: line 101 `SEEDED=0`; line 102 `if [ -n "${EXFAT_SEED:-}" ]; then`; line 110 `if sudo mount -t exfat -o loop "$EXPART" "$MNT"; then` ... line 113 `SEEDED=1` ... line 119 `else` line 120 `echo "  WARNING: seed mount failed — continuing without a seeded file."` (no rc, no exit). Consumers: line 170 `if [ "$SEEDED" = "1" ]; then` guarding the byte-exact file-set read gate (lines 171-175), and line 190 `if [ "$SEEDED" = "1" ]; then` guarding the exFAT ls-name gate (lines 191-195). Neither has an else that fails. Line 178-179 turns the absent case into `echo "  (info) no seeded file — file-set read path compiled, run EXFAT_SEED=1 to exercise it"`. Proof it never runs in the sweep: scripts/sweep.sh:104 `run_gate "1.39.x exFAT read" "EXFAT_SELFTEST=1" "exfat-smoke.sh"` sets no EXFAT_SEED, and `grep -rn EXFAT_SEED scripts/` matches only inside exfat-smoke.sh itself. Scenario: the 0x85/0xC0/0xC1 file-set read path — the thing this smoke is named for — is never exercised by any automated run, and a stale loop mount on the host silently converts an explicitly-seeded run into an unseeded one that still passes.

### `scripts/smoke/jbd2-crash-smoke.sh:154` — HIGH

**The only scored gate is per-iteration e2fsck-clean. Whether journal replay ever fired is counted and printed but never asserted; a run where every crash landed before the kernel wrote anything scores 4/4 PASS having exercised no recovery.**

Source: line 154 `if [ "$pass_count" -eq "$ITERATIONS" ]; then` -> line 155 `echo "=== jbd2-crash-smoke: PASS ($pass_count/$ITERATIONS clean) ==="; exit 0`, where pass_count is incremented only at line 138 inside `if e2fsck -fn "$WORK/part-iter-$iter.img" ...` (line 136). The recovery classification at lines 123-131 sets `crash_count_dirty` / `crash_count_clean` / the string `recovery="boot 2 didn't reach mount (boot hang?)"` and NONE of the three branches touches pass_count or fail_count — they are only echoed at lines 151-152. Failure scenario: line 73 `KILL_TIMES="2.0 2.7 3.4 4.1"` SIGKILLs boot 1 at 2.0-4.1 s. On this host OVMF hand-off is itself unreliable (scripts/smoke/lib/qemu-dwell.sh:109-111 measured "3 kernel banners in 10 attempts"), and there is no banner guard anywhere in this script. A kill before any journal write leaves the image byte-identical to the template, boot 2 changes nothing, e2fsck is trivially clean on all four iterations, and the script prints `boot-2 saw dirty: 0  (replay actually fired)` immediately above `PASS (4/4 clean)`. The crash-recovery path under test executed zero times.

### `scripts/smoke/modeset-latch-smoke.sh:97` — HIGH

**A build flag detected from the binary under test selects which of two lanes runs; the unselected lane prints SKIP and contributes nothing. When the disarm marker is present, the entire wedge/control/read-only lane is retired — including the fail-CLOSED HARD gate, the only assertion that can set hard=1 and exit 2.**

Source: line 88 `strings "$AGNOS" | grep -q "modeset: pathmatch positive OK" && DISARM_BUILD=1`; line 97 `if [ "$DISARM_BUILD" = 1 ]; then` -> line 98 `echo "SKIP: wedge/control/read-only lanes (this binary is the MODESET_LATCH_DISARM build)"` with `else` at 99 and the whole lane (lines 100-219, ~30 P/F assertions) inside it. The retired lane contains the only fail-open detector: lines 207-217 `if has "$LOGS/ro.log" "modeset: RISKY STEP entered"; then ... echo "## FAIL-OPEN: the risky step ran with NO usable latch." ... fail=$((fail+1)); hard=1`, and line 255 `[ "$hard" = 1 ] && { echo "=== modeset-latch-smoke: HARD FAIL (fail-open) ==='; exit 2; }`. The SKIP at line 98 adds nothing to `fail`, so line 256 `[ "$fail" -eq 0 ] && { echo "...$pass passed, 0 failed ==="; exit 0; }` reports a clean pass. Mirror shape at line 251 `else echo "SKIP: rebuild with MODESET_LATCH_DISARM=1 to exercise the disarm lane"` — in the default build the entire disarm lane (lines 224-249, 8 assertions) scores nothing. No single invocation can ever assert both halves, and neither skip is visible in the verdict line. Secondary: lines 158-163, when boot1's arm line does not survive the wedge the two-independent-channel ticks agreement prints `NOTE:` and is neither passed nor failed — it is silently skipped exactly in the case its own comment says the capture is untrustworthy.

### `scripts/smoke/shutdown-smoke.sh:358` — HIGH

**e2fsck's exit status is explicitly discarded, and the structural-damage assertion that replaces it is wrapped in an if whose condition is a format match over that same fsck output — so an fsck that did not run, crashed, or changed format silently reports neither PASS nor FAIL.**

Source: line 339 `e2fsck -fn "$WORK/part-post.img" > "$LOGS/fsck-post.log" 2>&1 || true` — the canonical damage signal (non-zero exit) is thrown away, unlike every other e2fsck site in the tree (compare ext2-write-smoke.sh:366 `if e2fsck -fn ...; then PASS else FAIL; rc=1 fi`). It is replaced by line 358 `if grep -qiE "^(Pass 5|.*: [0-9]+/[0-9]+ files)" "$LOGS/fsck-post.log"; then` wrapping the only damage check at line 359 `if grep -qiE "FIXED|UNEXPECTED|corrupt|Inode .* is invalid" ...; then ... rc=1`, closing at 364 with NO else. Failure scenario: e2fsck aborts early on a badly-damaged superblock and writes only `e2fsck: Attempt to read block from filesystem resulted in short read while trying to open ...` — that matches neither `^Pass 5` nor `.*: N/M files`, so the outer if is false, the inner damage grep never runs, and the script prints nothing at all between the FSSTATE line and the verdict. rc is untouched. The only surviving gate is the dumpe2fs FSSTATE case at lines 350-356, which reads a single superblock field and says nothing about structural integrity — the very thing this smoke exists to prove after a shutdown.

### `scripts/smoke/whirl-smoke.sh:157` — HIGH

**The HTTPS gate treats INCONCLUSIVE as a pass: when all 12 typing attempts drop keys, the result is NOCLEAN, the case arm prints WARN and leaves rc untouched. This directly contradicts the rule stated in console-line-smoke.sh.**

Source: line 128 `return "NOCLEAN"` (reached when the `for attempt in range(tries)` loop at python line 117 exhausts without a clean type); shell lines 154-158 `case "$HTTPS_R" in` / `OK) ... ;;` / `CONNFAIL) ... rc=1;;` / `*)        echo "  WARN: whirl HTTPS never got a clean-typed attempt (keyboard drops) — inconclusive, see serial.log";;` — the catch-all arm, which absorbs NOCLEAN and also the empty string produced when $RES does not exist at all (line 151 `HTTPS_R="$(grep '^HTTPS=' "$RES" 2>/dev/null | cut -d= -f2)"`, whose `2>/dev/null` swallows a missing file). Neither sets rc. Failure scenario: the python driver at line 133 makes 12 attempts through QEMU `sendkey`; under host load every attempt drops a character, fetch() returns NOCLEAN, and whirl-smoke exits 0 having never established a TLS connection. The tree already wrote the rule this violates — scripts/smoke/console-line-smoke.sh:15-17: "INCONCLUSIVE (harness exit 2) IS NOT A PASS ... 'we could not test it' and 'it works' must never be the same colour" — and console-line-smoke.sh:42 implements it (`exit 1`).

### `scripts/check.sh:274` — HIGH

**Gate 22 "call arity" is a negative assertion over a producer whose success is never checked: a build that FAILS for any reason emits no arity warnings, so $ARITY is empty and the gate scores PASS (shape V2).**

L274-276 verbatim: `ARITY=$(sh "$ROOT/scripts/build.sh" 2>&1 | grep -E "expects [0-9]+ arguments, got [0-9]+" || true)` / `test -z "$ARITY" && rc=0 || rc=$?` / `check "call arity (no cycc argument-count warnings)" $rc`. Simulated with a stub build that prints the real toolchain-pin error and exits 1: ARITY='' rc=0 -> PASS. Three aggravators: (a) `|| true` launders the pipeline status so even `set -e` cannot see the failure; (b) check.sh ALREADY knows the answer — gate 3 at L78-79 ran the same build and reported it — but never consults that rc; (c) it re-runs the entire build a second time, and that second run is what leaves build/agnos for gate 32 at L355.

### `scripts/check.sh:207` — HIGH

**Gate 14 "shader blobs match their .s sources" runs a hand-typed 8-name list against 21 committed blobs. Thirteen shipped shader tables are never diffed against their .s, and an empty list would score PASS because BLOBDRIFT starts empty (V1+V5). Unlike its sibling shader-crossasm.sh there is no partition assertion.**

L198 `BLOBDRIFT=""`; L207 `for sb in edge_setup edge_cov tri_rgba tex_rgba tex_list tex_list_cm tex_bilin blend_alpha; do`; L211 `test -z "$BLOBDRIFT" && rc=0 || rc=$?`. kernel/shaders/ holds 21 .s files and kernel/core/gpu.cyr defines 21 `fn <name>_write(dst_phys)` tables. Ungated: blend_cov, blend_pk, blend_premul, blend_rect, glyph_1bpp, grad_linear, matmul_copy, matmul_dot, matmul_f64, matmul_i32, perm, tri_depth, tri_persp. tri_depth and tri_persp are the two shaders check.sh spends gates 19-20 (L252-258) protecting against a kernarg swap that 'cost a burn' — their committed hex is diffed against their .s by nothing. The comment block at L199-206 has been amended three times to add names by hand, which is precisely the maintenance-by-care shape shader-tables.sh:2-9 exists to remove.

### `scripts/check/check-arena.sh:103` — HIGH

**check-arena.sh (check.sh gate 7, L127-128) prints its enumeration count but never asserts it. Zero `_SUBOFF` matches leaves ANNOT and BARE empty, fail stays 0, and the gate exits 0 while comparing no slots (V1).**

L101-103: `nannot=$(printf '%s\n' "$ANNOT" | grep -c . || true)` / `echo "  checked $nannot slot(s) with declared extents, $nbare without"` / `exit $fail`. Ran the script against a gpu_regs.cyr containing no _SUBOFF lines: output `checked 0 slot(s) with declared extents, 0 without`, exit=0 PASS. Real tree enumerates 62 lines matching `^var [A-Z0-9_]*_SUBOFF`. The greps at L31-35 depend on the exact literal `-> ends 0x`, the `_SUBOFF` suffix and column-0 `var`; any one of those moving silently empties both lists. Its sibling toolchain-pin-check.sh:112-118 carries exactly the floor this file lacks, for the same reason, and says so at its L47-50.

### `scripts/check/check-array-sizing.sh:32` — HIGH

**check-array-sizing.sh (check.sh gate 10, L153-154) prints 'PASS: no function-local var X[N] overruns' over an empty file list (V1). No floor on len(files), and check.sh discards its output to /dev/null so even a silent zero is invisible.**

L32-33: `files=sorted(glob.glob(root+'/tests/**/*.cyr', recursive=True) + glob.glob(root+'/kernel/**/*.cyr', recursive=True))`; L98 `sys.exit(bad)` with bad initialised 0 at L24; L100 `if [ $? -eq 0 ]; then echo "  PASS: no function-local var X[N] overruns"; exit 0; fi`. Ran with ROOT pointed at a tree holding empty kernel/ and tests/: printed `  PASS: no function-local var X[N] overruns`, exit=0. check.sh:153 invokes it as `>/dev/null 2>&1`. Aggravating: this script's own header at L25-31 records that THE GLOB WAS THE GATE'S BLIND SPOT at 1.56.52 — it covered three directories and missed kernel/user/ where four ring-0 stack overflows lived — yet the repair added paths without adding a floor.

### `scripts/check/check-carveout.sh:43` — HIGH

**check-carveout.sh (check.sh gate 8, L139-140) claims 'regions disjoint' over a hand-written 5-region list while its own header names SEVEN regions. The PSP TMR and the console FB are absent from the comparison, so an overlap with the TMR — 'unrecoverable if corrupted' per gpu_regs.cyr:936 — scores PASS (V5).**

Header L7-9 names 'console FB, pan, back buffers, PSP TMR, arena, shm, RT'. The `set --` at L43-48 lists only pan, back, arena, shm, rt. GPU_PSP_TMR_OFF (gpu_regs.cyr:936 = 0x60000000) and GPU_PSP_TMR_SIZE (:930 = 0x400000) are never read by this script. MUTATION TEST: copied the tree, set `var GPU_VM_ARENA_OFF = 0x60000000;` (gpu_regs.cyr:996, from 0x80000000) so the 2 MB arena lands exactly on the PSP TMR; check-carveout.sh printed `OK — regions disjoint, shm table fits its region, slot is 2 MB-aligned`, exit=0. rt-region-derive.sh does not cover it either — it only proves rtaudit's MIRRORED copies equal the kernel's values, not that the regions are disjoint.

### `scripts/check/check-dup-symbols.sh:47` — HIGH

**check-dup-symbols.sh (check.sh gate 12, L175-176) has two unfloored enumerations; zero includers or zero *.cyr both leave fail=0 and print the OK line (V1).**

L47-54: `for pair in "asmlib.cyr"; do` ... `for f in "$GPU"/*.cyr; do` ... `grep -qE "^include \"$pair\"" "$f" || continue`. The include grep is anchored and requires that exact spelling, so `include  "asmlib.cyr"` or a pathed include silently matches nothing. L71-76's array-size half globs `"$GPU"/*.cyr` with the same exposure. Ran a copy with GPU pointed at a directory holding only an empty asmlib.cyr: printed `check-dup-symbols: OK — no shared-layer symbol collisions in tests/gpu`, exit=0, having compared nothing. Real tree has 3 includers (edgeasm.cyr, shaderasm.cyr, shaderexec.cyr). The header at L42-46 already concedes the list is hand-kept — 'a shared file with no row here is ungated' — so both the row list AND the enumeration are unasserted.

### `scripts/check/shader-crossasm.sh:61` — HIGH

**The partition assertion added specifically to stop this gate being vacuous is itself vacuous one level up: it enumerates kernel/shaders/emit/*.emit.cyr with no floor, so an empty or renamed emit/ directory yields zero iterations and the gate prints its OK line and exits 0 (V1).**

L58-79: `partition_fail=0` ... `for f in "$SHADERS"/emit/*.emit.cyr; do [ -f "$f" ] || continue; ...` ... `if [ "$partition_fail" != "0" ]`. With UNBURNED="" (L49) the fail loop at L82 is also empty, so control reaches L150-152 `if [ -z "$UNBURNED" ]; then echo "shader-crossasm: OK — no shader currently lacks iron-proven hex; every emit list is gated by shaderasm"; exit 0`. Ran a copy with SHADERS pointed at a directory containing an empty emit/: printed that exact OK line, exit=0. Real tree has 2 emit lists (blend_alpha, blend_rect) and shaderasm.cyr covers exactly those 2. The script's own L51-57 comment asserts the partition 'is a claim with content whether or not this list has anything in it' — true only while the emit enumeration is non-empty, which nothing checks. Contrast its own per-shader guard at L129-131 ('Refuse an empty side... that is the shape of a gate that passes because nothing ran'), which is the floor it applies to the dwords and withholds from the file list.

### `scripts/harness/aethersafha-clients-test.py:1295` — HIGH

**Identical empty-arm-loop vacuous pass — third copy of the same block, again with no AE_CLIENTS_MODE validation.**

Lines 1295-1309: `rc = 0` / `for ran, code, name, how in ((ran_fg, fg_code, ...), (ran_bg, bg_code, ...)): if not ran: continue`. `ran_fg`/`ran_bg` False at lines 376-377, set True only at 378/380 and 1043/1048. `MODE = os.environ.get("AE_CLIENTS_MODE", "bg")` at line 178; `grep -n 'MODE in ('` finds only lines 378 and 1043; the named modes `desktop` (527/1180), `relaunch` (385/1204) and `armed` (1013/1270) each `raise SystemExit` before this block, so any OTHER string reaches line 1295 with both flags False. SUCCESS CONDITION: no arm ran. EMPTY-INPUT SCENARIO: any typo'd mode → 1332-line harness boots QEMU, launches no client, and exits 0. This is the largest harness in the tree (README credits it with reproducing the iron 16-slot process-table failure).

### `scripts/harness/puka-child-stdout-test.py:816` — HIGH

**Identical empty-arm-loop vacuous pass to puka-terminal-test.py:718 — unvalidated AE_CLIENTS_MODE means neither arm runs and rc stays 0.**

Lines 816-830 are a verbatim copy of the puka-terminal block: `rc = 0` then `for ran, code, name, how in ((ran_fg, ...), (ran_bg, ...)): if not ran: continue`. `ran_fg` / `ran_bg` initialised False at lines 243-244, set True only at lines 245/247 (`if MODE in ("fg","both")`) and 315/320 (`if MODE in ("bg","both")`). `MODE = os.environ.get("AE_CLIENTS_MODE", "bg")` at line 40, no validation. SUCCESS CONDITION / EMPTY-INPUT SCENARIO: as above — a mode string outside {fg,bg,both,desktop,armed} boots the guest, types nothing meaningful, and exits 0.

### `scripts/harness/puka-terminal-test.py:718` — HIGH

**The per-arm verdict loop starts at rc=0 and skips every arm that did not run; AE_CLIENTS_MODE is never validated, so an unrecognised mode launches nothing and the harness exits 0.**

Lines 718-733: ``` rc = 0 for ran, code, name, how in ((ran_fg, fg_code, "FOREGROUND", ...),                              (ran_bg, bg_code, "BACKGROUND", ...)):     if not ran:         continue     if code == 95: ...; continue     rc = 1 ``` `ran_fg`/`ran_bg` are initialised False at lines 240-241 and set True ONLY inside `if MODE in ("fg", "both")` (line 242) and `if MODE in ("bg", "both")` (line 299). `MODE = os.environ.get("AE_CLIENTS_MODE", "bg")` at line 37, and `grep -n 'MODE not in\|unknown mode'` finds nothing — there is NO validation. SUCCESS CONDITION: no arm that ran reported a code other than 95. EMPTY-INPUT SCENARIO: `AE_CLIENTS_MODE=BG` / `=background` / `=Desktop` (any typo) matches none of the six branches, no arm launches, the loop body never executes, and `sys.exit(rc)` exits 0 — with line 715-716 printing "foreground exit — (not run in this mode) · background exit — (not run in this mode)" directly above the green exit. The file's own comment at 705-714 warns against exactly this class of overstatement but guards only the fg-vs-bg comparison (line 737 `if ran_fg and ran_bg:`), not the rc.

### `scripts/harness/run37-smp4-test.py:169` — HIGH

**The `-d int` SMP-fault exception census passes on a missing QLOG and reports the affirmative string "0 SMP-fault exceptions", which is appended to the harness's PASS line.**

Lines 162-172: ``` try: qlog = open(QLOG, "r", errors="replace").read() except OSError: qlog = "" bad = {} for mvec in _re.findall(r"v=([0-9a-fA-F]{2})", qlog):     ... dint_ok = (len(bad) == 0) ... dint_report = "0 SMP-fault exceptions" if dint_ok else ... ``` Line 192 then prints `... PASS ...` + `" + 0 SMP-fault exceptions (-d int)" if DINT`. SUCCESS CONDITION: the findall produced no entry in {0x06,0x08,0x0a,0x0b,0x0c,0x0d,0x0e}. EMPTY-INPUT SCENARIO: `QLOG = os.path.join(WORK, "qint.log")` (line 67) is never written — QEMU rejected `-d int -D` (line 79), crashed before the first exception, or could not create the file. `qlog` becomes "", `re.findall` returns [], `bad` is {}, and `dint_ok` is True. This is the same shape as the confirmed klug-spill-smoke.sh:126 defect: a grep that matches zero lines scores as a clean run. There is no check that `qlog` is non-empty, and no check that the vector-count denominator is non-zero (a real boot emits thousands of `v=` records, so `len(qlog) == 0` is a perfect discriminator that is not tested).

### `scripts/probe/rbp-repro.sh:88` — HIGH

**The RBP-smash census reports "NO RBP smash" when the awk pass ran over a missing/empty `-d int` log; the prompt-reached counter is printed but never gated.**

Lines 47-70 run awk over `"$INT"`; line 69 `END { printf("PFTOTAL=%d SMASHTOTAL=%d\n", pf+0, smash+0); }` emits `PFTOTAL=0 SMASHTOTAL=0` for an empty or absent file. Lines 72-73: `sm_n=$(... sed -n 's/.*SMASHTOTAL=\([0-9]*\).*/\1/p'); sm_n=${sm_n:-0}`. Line 88: `[ "$smash" -eq 0 ] && echo "RESULT: NO RBP smash across $boots boots" || echo "RESULT: RBP smash STILL PRESENT ($smash)"`. SUCCESS CONDITION: `smash == 0`. EMPTY-INPUT SCENARIO: all N boots die in OVMF (state.md:68 records that OVMF "intermittently never hands off, ~1 run in 4 idle, far worse under load") — `$INT` holds nothing the awk matches, `smash` stays 0, and the script announces "NO RBP smash across 50 boots" having examined 50 empty logs. Line 42 computes the guard (`if strings "$SER" | grep -q '\[ASSIST\] >'; then reached=$((reached+1)); fi`) and line 85 prints `reached [ASSIST] > prompt : $reached / $boots`, but nothing tests it. Exit status is the trailing echo's, i.e. always 0.

### `scripts/probe/repro-ring3-pf.sh:107` — HIGH

**The ring-3 #PF verdict prints PASS when the `-d int` log does not exist, and the `reached`-the-exec counter it computes never gates the verdict.**

Line 86: `r3=$(grep -c "v=0e .* cpl=3" "$INT" 2>/dev/null); [ -z "$r3" ] && r3=0`. Lines 93-99: `if [ "$r3" -gt 0 ]; then pf3=$((pf3+1)) ... else clean=$((clean+1)); printf '  run %2d: clean\n' "$run"; fi`. Line 107: `[ "$pf3" -eq 0 ] && echo "REPRO: 0 ring-3 #PF / $N boots — PASS" || ...`. SUCCESS CONDITION: `pf3 == 0`. EMPTY-INPUT SCENARIO: `$INT` never written — QEMU failed to launch, `timeout "${QEMU_TIMEOUT:-40}"` (line 68) killed it during firmware, or this QEMU build lacks `-d int`. `grep -c` on a missing file with stderr suppressed yields 0, so every boot scores "clean" and the run prints PASS having read nothing. The script computes exactly the right non-vacuity counter at lines 78-80 (`strings "$SER" | grep -q "kybernet: exec /bin/agnsh"` → `reached=$((reached+1))`) and PRINTS it at line 105, but never tests it — `reached-exec=0` and "PASS" print from the same run. Also, the script's exit status is that of the trailing `echo`, so it is 0 in both branches and a caller cannot distinguish.

### `scripts/smoke/tonegen-smoke.sh:141` — MEDIUM

**A gate that prints FAIL and scores PASS: the mid-tone dropout check's failure branch never sets rc, so a detected audio dropout leaves the smoke exiting 0.**

Source line 141: `[ "${GP:-1}" -eq 0 ] && echo "  PASS: no silence gap within the sustained tone (continuous)" || echo "  FAIL: silence gap detected mid-tone (a DROPOUT — the path glitches even blocking-paced)"`. Compare the line immediately above it, line 139, which does it correctly: `[ "${PK:-0}" -gt 3000 ] && echo "  PASS: non-silent (peak=$PK)" || { echo "  FAIL: silent (peak=$PK)"; rc=1; }`. Line 141 has no `rc=1` in its else. Verdict at line 144 `[ "$rc" -eq 0 ] && echo "tonegen-smoke: PASS — clean tones stream through the agnos snd_* band"`. Failure scenario: the python analyser at lines 125-131 sets gap=1 on three consecutive 10 ms frames below 5% of peak envelope; the script prints the word FAIL naming a real dropout and then prints `tonegen-smoke: PASS` and exits 0. The dropout property — the whole point of a 'clean tones' gate — is unfalsifiable. Same file, line 140: the ~440 Hz pitch check is WARN-only and likewise cannot fail.

### `scripts/check.sh:328` — MEDIUM

**Gate 31 "version in changelog" passes vacuously on an empty VERSION file: `grep -q ""` matches every line (V2). It is also an unanchored, regex-interpreted substring match.**

L297 `VERSION=$(cat "$ROOT/VERSION" | tr -d '[:space:]')`; L328 `grep -q "$VERSION" "$ROOT/CHANGELOG.md" 2>/dev/null && rc=0 || rc=$?`. Verified: with VERSION="", `grep -q "" CHANGELOG.md` returns 0 -> rc=0 -> PASS. Gate 24-29's `test -f "$ROOT/VERSION"` (L290) passes on a 0-byte file, so nothing upstream catches it. Sibling gate 30 (L312-326) is immune because its VFN/VGV equality comparisons fail against "". Secondary: the dots in 1.56.57 are regex wildcards and the match is unanchored, so a CHANGELOG containing '1x56x57' — or 'v1.56.570' for a VERSION of 1.56.57 — satisfies it.

### `scripts/check.sh:355` — MEDIUM

**Gate 32 "binary size" measures whatever build/agnos happens to be on disk. When both build invocations (L78 and L274) fail, it reports PASS on a fossil from an earlier run; when the file is absent it aborts the entire script under `set -e` before the summary prints (V5).**

L355 `SZ=$(wc -c < "$ROOT/build/agnos")`; L366 `test "$SZ" -gt 50000 && test "$SZ" -lt 2097152 && rc=0 || rc=$?`. Nothing ties this read to the build gate's rc. Verified the absent-file path in a standalone `set -e` script: the assignment fails, the shell aborts at that line, `after` never prints, exit=1 — which is exactly the 'truncated log that reads like a crash, not a failure' the file's own header forbids at L4-8. The stale-artifact path is the same class vendored-artifact-check.sh:6-8 exists for ('a committed copy of a regenerated file is not evidence about the source beside it'). Current build/agnos is 1,994,776 B against the 2,097,152 ceiling — 102,376 B of headroom, and L362-365 already declares the bound 'A GRANT, NOT A MEASUREMENT, AND IT EXPIRES'.

### `scripts/check/chan-semantics-check.sh:21` — MEDIUM

**chan-semantics-check.sh (check.sh gate 6, L113-114) exits 0 when cyrius is not on PATH, so check.sh scores 'channel-band semantics (host socketpair proof)' as PASS having built and run nothing (V3).**

L21 verbatim: `command -v cyrius >/dev/null 2>&1 || { echo "  SKIP: cyrius not on PATH"; exit 0; }`. Verified: `env -i PATH=/usr/bin:/bin sh scripts/check/chan-semantics-check.sh` printed `  SKIP: cyrius not on PATH`, exit=0. check.sh's check() at L27-35 keys only on `[ "$2" = "0" ]`, so the SKIP is indistinguishable from a proof. Contrast syscall-abi-check.sh:46-47, which states the correct policy for this same tree — 'NO SKIP PATH. If neither is present this FAILS. A check that quietly passes when it could not find one of its three inputs is a false green' — and contrast host-gpu-oracles.sh:134, which exits 2 (a FAIL) on the identical condition.

### `scripts/check/check-initstack.sh:56` — MEDIUM

**The third of check-initstack.sh's three assertions (check.sh gate 9, L148-149) silently disappears when its grep pattern rots: BLOB is never validated the way ARGC and ENVC are, and `[ -n "$BLOB" ] &&` turns a failed parse into a no-op with no output (V4).**

L36 `BLOB=$(grep -oE 'if \(entries > [0-9]+\) \{ return 0; \}' "$SYS" | grep -oE '[0-9]+' | head -1)`. L37 validates only ARGC and ENVC: `[ -n "$ARGC" ] && [ -n "$ENVC" ] || { echo "FAIL: could not read the argc/envc caps"; exit 1; }`. L56 `if [ -n "$BLOB" ] && [ "$BLOB" -gt "$ENVC" ]; then`. MUTATION TEST: copied syscall.cyr with one extra space (`if (entries  > 16)`, currently at syscall.cyr:605) — the script printed the identical green line `init-stack: 63 slots, worst top index 35, string region 3584 B`, exit=0, with the sc_env_blob_ok-vs-env-loop comparison gone and nothing said about it. The file's own header (L13-18) is about an invariant that 'rotted in three separate comments before it was caught'; this is that failure mode inside the gate written to prevent it.

### `scripts/check/texl-body-identity.sh:112` — MEDIUM

**texl-body-identity.sh (check.sh gate 15, L217-218) degrades an ASSEMBLY FAILURE into a skipped stage and exits 0. The dword stage is the half that proves rung 14 inherits rung 13's iron-proven MACHINE CODE; a shader that no longer assembles scores PASS (V3/V5). Its sibling texbi-body-identity.sh hard-fails on identical input.**

L71-75 sets `ok=0` when llvm-mc or llvm-objcopy fails; L110-113 `else rm -rf "$WD"; echo "texl-body-identity: (dword stage skipped -- assembly failed)"; fi` then L117 `exit 0`. MUTATION TEST: inserted an invalid instruction identically into copies of tex_rgba.s and tex_list.s (so the source diff still matches) — texl-body-identity.sh printed `PASS -- 475 lines of rung 13's body are character-identical in both shaders` then `(dword stage skipped -- assembly failed)`, exit=0. The same mutation through texbi-body-identity.sh (L90-93 `... || { echo "texbi-body-identity: FAIL -- $n.s did not assemble"; exit 1; }`) printed `FAIL -- tex_rgba.s did not assemble`. Second, weaker vacuity in the same file at L89-91: if the two blobs are wholly identical the python prints `PASS -- all {n} dwords identical (no prologue?) -- check the sources` and exits 0 — a degenerate state the message itself flags as suspicious yet scores green.

### `scripts/harness/ae-resize-fault-test.py:199` — MEDIUM

**The survival verdict is a pure double-negative over a segment that can be empty, and the key-delivery ABORT above it only prints — it does not abort.**

Lines 185-199: ``` out = ser()[mark:] faulted   = "fault: pid=" in out exited142 = "exit 142" in out alive     = "aethersafha:" in ser()[-4000:] or not faulted   # computed, never used ... if faulted or exited142:     p("REPRODUCED: ..."); rc = 1 else:     p("NOT REPRODUCED: the compositor survived the sequence"); rc = 0 ``` SUCCESS CONDITION (rc=0): neither bad string appears in `out`. EMPTY-INPUT SCENARIO: `out == ""` — the serial log stops (QEMU killed, host disk full, the compositor dies without printing) — both negatives hold and the harness asserts the compositor "survived". Compounding it, lines 137-138: ``` if themed == 0:     p("ABORT: no key reached the compositor — the sequence below cannot be trusted") ``` says ABORT and does not `sys.exit`; execution falls straight through to the F6/F5 sequence and the verdict. The only real guard is the `spawned` check at 156-163 (`sys.exit(2)`), which covers a launcher that never spawned but not a compositor that spawned and then went silent. Contrast the sibling ae-theme-repaint-test.py:168 which DOES gate: `if before is None or after is None or nsw == 0: p("INCONCLUSIVE..."); rc = 2`.

### `scripts/harness/crab-resize-test.py:405` — MEDIUM

**Five separately-measured arms (wheel, FULL_KEYS gating, held-key repeat, sort cycling, deferred stat-drain) are printed with ⚠ markers but never enter the exit-code computation, so a run in which all five measured nothing still exits 0 as PASS.**

The verdict at lines 405-441 reads only `faulted` (404), `refused` (206), `resized` (205), `answered` (218) and `clicks` (286). Never referenced: `wheel_scrolls` (256, printed 259), `alive_after_click`/`acted` ratio (297-298, printed 309-315 — the ⚠-equal branch is print-only), `rep`/`rep_after_release` (348/355, printed 358-364 — the `⚠ no repeat observed` branch is print-only), `modes` (375, printed 386-394 — `⚠ no sort line — the key never reached crab` is print-only), `drained` (397, printed 398-402 — `⚠ no drain-complete line` is print-only). SUCCESS CONDITION: `resized and answered>0 and clicks>0 and not faulted`. EMPTY-INPUT SCENARIO: QMP never connects (`qs is None`, lines 231-235 and 329 both silently skip), so `wheel_scrolls = 0` (initialised 230) and `rep = rep_after_release = 0` (initialised 327-328); no `crab: sort` line arrives so `modes == []`; no `crab: stat-drain complete` so `drained == False` — and line 439 still prints `PASS: crab adopted the resize, resolved N click(s), and answered M keystrokes` with rc=0. README.md credits this harness with proving the wheel wire end to end across five repos; nothing in the exit code does.

### `scripts/tool/fb-ansi-screendump.sh:64` — MEDIUM

**The wait-for-paint loop has no failure branch — a 20-second timeout is indistinguishable from the marker arriving, and the script then screendumps the firmware screen and exits 0.**

Lines 62-65: ``` for i in $(seq 1 20); do     sleep 1     grep -aq "fb-ansi-visual: painted" "$W/serial.log" 2>/dev/null && break done ``` Nothing records whether the `break` fired. The only failure gate is line 77 `[ -f "$W/ansi.ppm" ] || { echo "FAIL: no screendump produced" >&2; exit 1; }` — but QEMU's HMP `screendump` always writes a file regardless of what the guest painted. SUCCESS CONDITION: a .ppm exists. EMPTY-INPUT SCENARIO: the kernel triple-faults before `fb_ansi_visual` runs; the loop times out silently, the screendump captures the OVMF splash or a black frame, line 79 prints an empty `serial:` field (`grep -a 'fb-ansi-visual' "$W/serial.log" | head -1` matches nothing), and line 81 tells the operator to "eyeball the colours" — exit 0. `ffmpeg`'s exit status at line 78 is also unchecked, so a failed PPM→PNG conversion leaves line 80's `file -b` reporting on a missing file.

