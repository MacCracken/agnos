# 2026-09-23 — no per-process resource limits: a parent cannot cap a child's memory or CPU time

**Status:** ✅ **RESOLVED 1.57.7 (2026-09-25)** — step S8: `spawn_limits`#107 `(mem_pages, cpu_ms)` arms one-shot caps for the caller's next `spawn`#3 / `execwait`#37 / `spawn_path`#43; the loaders refuse an image over the memory cap (`#43` −7 `SPAWN_E_LIMIT`, `#3`/`#37` −1) and `mmap`#27 returns 0 past it; at the CPU cap the child dies by SIGXCPU (24), wait status **280**. Gates: `scripts/smoke/lifecycle-smoke.sh` (MEM*, CPU*, ARM*, ELFOVERLAP, FORK*, HIGH at `-smp 1` and `-smp 4`) and `ktest` `[limits]` K1–K5 (40 assertions). Built, gated, NOT burned. See § Resolution.
**Filed by:** daimon (the AGNOS agent orchestrator). Every agent it starts runs under a memory cap and
a CPU-time cap. This is daimon's VULN-010 fix; the defaults are 1 GiB and 1 hour.
**Checked against:** agnos **1.57.5**, `kernel/`, read in the working tree.
**Consumer impact:** on agnos daimon cannot apply the caps. By the operator's ruling of 2026-09-23 it
starts agents there without them, documented and audited at each start, until this exists.

> There is no rlimit equivalent: `grep -ci rlimit` over `kernel/` finds 0 lines, and no syscall in
> 0–104 sets a per-process limit. The accounting already exists: `proclist`#99 reports each process's
> CPU ticks and resident pages. Enforcement does not.

---

## 1. What daimon does on Linux, for reference

- `RLIMIT_AS` (address space) and `RLIMIT_CPU` (seconds) are set in the child between fork and exec.
- A start whose limits cannot be applied is refused.
- Past `RLIMIT_AS` an allocation fails. Past `RLIMIT_CPU` the process gets SIGXCPU, then SIGKILL.

## 2. The ask

1. **The parent sets the limits for the child it spawns.** Either:
   - a one-shot arm before `spawn_path`#43, the same shape as `exec_redirect`#62 and `CH_ENDOW`
     (per-CPU, consumed by the next spawn); or
   - extra `#43` arguments, if you prefer.
2. **Memory:** a cap on the child's mappable memory. Past it, `mmap`#27 (and the loader) refuse and
   return -1, as they do on OOM.
3. **CPU time:** a cap in ticks or milliseconds of the child's CPU. Past it, the kernel ends the
   process, and `waitpid`#4 can tell that apart. This needs the unconditional end asked for in
   `2026-09-23-parent-cannot-end-stop-or-continue-a-child.md`.
4. **Inheritance:** whether a child's own spawns inherit the caps is for you to decide. On Linux they
   do. daimon cares only about the agent it spawns and what that agent starts.

## 3. Not asked

- A scheduler-side share or priority. daimon's quota is a ceiling, not a share.
- Reading the limits back. daimon knows what it set.

## Resolution (1.57.7, 2026-09-25)

**What shipped:** ask 1 a one-shot arm, per-PROCESS (not per-CPU), consumed on every return; ask 2 the memory cap
at 2 MB granularity; ask 3 the CPU cap at the tick (ceil(ms/10) ticks); ask 4 inheritance — a child's cap is
`min(creator's own cap, arm)`, so an arm can only lower it, and `fork`#96 copies the caps, never the arm. Honest
limits (ABI row 107): budgets are per process, so a capped agent can hand work to a fresh child; kernel time is
under-charged while a syscall holds the CPU; shm, GPU slots, channel rings, pipe buffers, page tables and kernel
stacks are not counted. Probe support with `#107(0, 0)`.

**What the change broke — checked before archiving:** an ELF whose PT_LOAD segments share a 2 MB page is now
refused (`#43` −5, `#3`/`#37` −1) — it used to leak 2 MB per spawn; `mmap` no longer overwrites a present
mapping; `#99` RSS now includes the high arena (larger numbers in chakshu). To stay under the 2 MiB size grant
without moving it, three GPU shader selftests compile only into their own flag builds. Seen during S8's regression
run, not caused by it, filed for 1.57.8: `2026-09-25-nvme-poll-timeout-leaves-the-cq-one-behind.md`.

**Evidence:** `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.7/steps/S8-report.json`.
