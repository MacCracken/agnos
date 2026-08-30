# The syscall ABI doc individually documents 65 of 96 syscalls, and names cyrius as its authority while cyrius names it as theirs

**Status:** ✅ **RESOLVED — the three-way gate shipped and the rows were backfilled.** Swept 2026-08-30. `scripts/check/syscall-abi-check.sh` compares kernel/doc/cyrius number sets and names, and the circular authority the issue describes (doc citing cyrius, cyrius citing doc) is cut: **the kernel is canonical**. ⚠ The gate is doing its job right now — it is RED at `kernel 102 · abi-doc 102 · cyrius 101` pending the `lstat`#102 peer, which is exactly the drift this issue existed to make visible.

**Original status:** ✅ **RESOLVED 2026-08-05, same day** — gate built, 32 rows backfilled, circular authority cut.
The one item left open is cyrius's stale provenance stamp (see *Remaining* at the bottom), which is a
cyrius-repo edit.
**Cross-repo:** agnos (`docs/development/agnos-userland-abi.md`) **+ cyrius** (`lib/syscalls_x86_64_agnos.cyr` header).
**Severity:** Medium — nothing is broken at runtime; the *contract* is unowned, which is how a
numbering mistake gets made rather than caught.
**Affects:** agnos 1.56.39 and earlier; cycc 6.5.6 and earlier.

## ⭐ The audit's headline inverts the expected answer: **cyrius is complete. The doc is not.**

The question asked was whether cyrius covers every agnos syscall. Measured at agnos 1.56.39 / cycc 6.5.6:

| | result |
|---|---|
| agnos kernel dispatch arms | **96** — `#0`–`#95`, contiguous, no holes |
| cyrius `SysNrAgnos` constants | **96** — `#0`–`#95`, **complete, zero gaps** |
| cyrius callable wrappers | present for every number with a ring-3 consumer |
| **agnos ABI doc individual rows** | **65 of 96** |

⚠ `#44 sched_yield` is dispatched only from the ring-3 SYSCALL entry stub, never through `ksyscall`, so
a `grep 'if (num == '` over `syscall.cyr` returns 95 and looks like a hole. It is not one — check the
entry stub before filing that as a gap.

⚠ `sys_uname` / `sys_sysinfo` live in cyrius `lib/sys.cyr`, not in the syscall-number file, and both are
correctly `#ifdef CYRIUS_TARGET_AGNOS`-armed onto the agnos numbers. A wrapper audit that greps only
`syscalls_x86_64_agnos.cyr` will report them missing. They are not. The one constant with genuinely no
wrapper is `#26 write_boot_checkpoint`, a kernel diagnostic with no ring-3 consumer — correct as-is.

**So there is no cyrius work here.** What follows is entirely an agnos-side documentation defect.

## The 32 syscalls with no row of their own

⚠ **Filed as 31; the gate measured 32.** The hand audit credited `#48 sock_send` with a row that was
really the **`uname` struct's offset-48 field** (`| 48 | \`machine\` |`) — a whole-file regex cannot tell
a syscall table from a struct-offset table. Corrected here rather than left standing, because the
original figure is what a reader would otherwise carry forward.

| bucket | count | numbers |
|---|---|---|
| Individually documented | **64** | the rest |
| Covered ONLY by a `45–59` *"Doc backfill pending"* placeholder row (then at `agnos-userland-abi.md:191`, since deleted), which listed them in prose | **15** | 45–59 |
| ⛔ **Wholly absent — no row, no placeholder, no prose** | **17** | **64–69** audio (`snd_open`/`config`/`write`/`close`/`drain`/`avail`) · **71–74** shm (`shm_create`/`write`/`read`/`free`) · **75–80** block (`blk_enum`/`open`/`read`/`write`/`info`/`close`) · **81** `readdir` |

⛔ **The 17 are not obscure.** They are the shm path the entire desktop pixel pipeline runs on, the
audio band that produced first sound, and the block-device band the installer needs.

⭐ **The damage is already visible in the doc itself.** `#86 shm_create_gpu` *is* documented, and its
entry explains itself by contrast with `shm_create#71` — a syscall the document never defines. A reader
following that cross-reference lands nowhere.

## ⛔ The authority is circular, and that is the root cause

- **agnos** `agnos-userland-abi.md:191` — *"authoritative map is `kernel/core/syscall.cyr`'s header **+ the cyrius `syscalls_x86_64_agnos.cyr` peer**"*
- **cyrius** `lib/syscalls_x86_64_agnos.cyr:5` — *"**Faithful mirror of** `agnos/docs/development/agnos-userland-abi.md`"*

For `45–59` the chain is doc → cyrius → doc. **Neither file is canonical and each believes the other
is.** That is not a formatting nit: it means a wrong number can be introduced in either file and
"verified" against the other. The roadmap already records this class shipping for real — raw
`syscall(N,…)` with **Linux** numbers on agnos paths, confirmed live in jalwa (`mkdir`(83) → GPU f64
dispatch, `poll`(7) → `open` **per frame**, `read`(0) → **`exit`**) and latent in agnostik's
`_fill_random`. Tracked separately at
[`jalwa/.../2026-08-03-agnos-raw-syscall-wrong-numbers.md`](https://github.com/MacCracken/jalwa/blob/main/docs/development/issues/2026-08-03-agnos-raw-syscall-wrong-numbers.md)
— **not** duplicated here.

⚠ cyrius's header also stamps its provenance as *"(agnos 1.41.x)"*. The kernel is at **1.56.39**. The
file's *contents* are current — it is the provenance line that is 15 minor versions stale, which is
worse than no stamp, because it invites a reader to distrust a file that is actually right.

## What closing this looks like

1. **Declare the kernel canonical, in both files.** cyrius's own §5 re-freeze rule already says *"the
   agnos kernel is canonical"* — the doc's line 191 contradicts it. One sentence each, and the loop is
   cut.
2. **Backfill the 32 rows** from `syscall.cyr` + the cyrius enum, and delete the placeholder row.
3. **Refresh cyrius's provenance stamp** to the agnos version actually mirrored.
4. ⭐ **Add a mechanical gate — this is the part that keeps it closed.** A
   `scripts/check/syscall-abi-check.sh` that extracts the three lists (kernel dispatch arms + entry
   stub, ABI-doc rows, cyrius `SysNrAgnos`) and fails on any disagreement in number *or* name. agnos
   already has the precedent: `scripts/check/kprint-len-check.sh` exists for exactly this shape of
   defect, is wired into `check.sh`, and catches an entire class the compiler cannot. **A hand-written
   table that nothing diffs will drift again** — this audit found 32 gaps that accumulated without
   anyone noticing, which is the argument for the gate rather than for one more manual backfill.

⚠ Step 4 is the only one that has to happen. Steps 1–3 without it buy one clean snapshot.

## ✅ What was done — 2026-08-05

**Step 4 first, deliberately**, so the backfill was verified by the gate rather than by eye:
`scripts/check/syscall-abi-check.sh`, wired into `check.sh` beside `kprint-len-check.sh`.

⭐ **The gate corrected this ticket's own numbers.** It reports **32** undocumented syscalls, not 31:
the hand audit had credited `#48 sock_send` with a row that was actually the **`uname` struct's
offset-48 field** (`| 48 | \`machine\` |`), matched by a whole-file regex. Six other "name
disagreements" in the first draft of the gate came from the same class — §3.4 GPU op codes, §4.1
`stat`, §4.2 `getdents`. **A gate's own false positives are indistinguishable from the defect it
hunts**, so it now parses only the syscall-table sections, and that filter is load-bearing.

**What it checks**, and why it is not a naive three-way name diff — the kernel is canonical for the
NUMBER SET (`if (num == N)` is unambiguous) but is *not* a reliable source of NAMES, because the
dispatch comments are free-form (`# gpu_present() —`, `# epoll_create`, `# exit — halt…`, and three
arms with no comment at all). Hard-failing on comment prose would make the gate cry wolf, and a gate
that cries wolf gets disabled:

| | check | verdict |
|---|---|---|
| A | number sets: kernel == doc == cyrius, both directions | hard fail |
| B | names: doc == cyrius, every number | hard fail |
| C | kernel comment names | hard fail on disagreement; **NOTE** where a comment is absent — currently covers all 96 |
| D | syscall rows sitting in a NON-syscall section | hard fail |

**D exists because a negative control exposed a blind spot in the gate itself.** A planted `#96 fork`
row appended past §4 was silently ignored and the gate passed — the control was badly built, but the
hole was real: the section filter that fixes the false positives also makes a row in the wrong section
invisible. D detects it exactly rather than heuristically (a row outside the sections is flagged only
when its number is one the kernel implements *and* its name matches cyrius's for that number, which a
struct field can never satisfy).

**Four negative controls, all confirmed detecting:**

| control | result |
|---|---|
| delete a doc row (`#73 shm_read`) | exit 1 — *absent from abi-doc* |
| rename a row (`#81 readdir` → `fchdir`, the real Linux collision) | exit 1 — *name disagreement* |
| add a row with no kernel arm (`#96 fork`) | exit 1 — *no kernel arm; caller reads the fall-through value as data* |
| move a real row into a struct section | exit 1 — *row in a NON-syscall section* |

**Then the content:** all **32** rows backfilled with signatures, return conventions and consumers;
the `45–59` placeholder deleted; `#84` corrected from `present` to **`gpu_present`** (kernel and cyrius
both said `gpu_present`; the doc alone disagreed, and the gate caught it).

⭐ **The circular authority is cut** — it lived entirely in the deleted placeholder row. The doc's own
header (*"The canonical source is `kernel/core/syscall.cyr`"*) and §5.3 (*"The kernel is canonical; the
doc tracks it; the peer tracks the doc"*) were already correct and are now uncontradicted.

**Result: `kernel 96 · abi-doc 96 · cyrius 96`, exit 0.**

## Remaining

- ⚠ **cyrius's provenance stamp still reads `(agnos 1.41.x)`** on a kernel at 1.56.39. Contents are
  current; only the stamp is stale. Cyrius-repo edit — tracked in
  [that repo's ticket](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-08-05-agnos-syscall-peer-two-new-numbers-and-a-circular-authority.md).
- ✅ **Done in the same change:** `#2`, `#6` and `#63` gained the `# name` comment they lacked, so check
  C now covers **all 96** arms and the gate emits no NOTE.

## Sequencing against the new numbers

`#96 fork` ([ticket](2026-08-05-syscall-96-fork.md)) and `#97 chan_op` ([ticket](2026-08-05-syscall-97-chan-op.md))
both add a syscall **and** a cyrius peer constant. Landing the gate (step 4) **before** either of them
means the first thing it ever checks is a change that must not get its number wrong — which is the
cheapest possible time to have it.
