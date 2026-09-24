# 2026-09-23 — no per-process resource limits: a parent cannot cap a child's memory or CPU time

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
