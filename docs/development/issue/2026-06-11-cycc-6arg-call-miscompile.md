# cycc: layout-sensitive miscompile suspected on a 6-arg call with in-arg arithmetic (agnos 1.44.19 dev)

**Status:** surfaced upstream (cyrius is hands-off from agnos sessions); agnos works around it.
**Toolchain:** the agnos pin, cyrius **6.0.56** (`cyrius.cyml`).
**Severity for agnos:** none after the workaround (the 6-arg shape was removed); blocks re-introducing
>4-arg calls on the syscall dispatch path until cleared.

## Symptom

Extending `elf_load_from_file(path, namelen, argv_src, argv_len)` to SIX params
(`…, env_src, env_len`) and calling it from `ksyscall`'s #37/#43 handlers with arithmetic in
arg1 (`elf_load_from_file(spp + sp_ps, sp_plen, spp, arg2, sp_env, sp_elen)`) produced
**per-binary-deterministic, layout-sensitive failures**: `vfs_file_size(path, namelen)` returned
-1 for files that exist on ext2 (i.e. the `path`/`namelen` values arriving in the callee were
corrupted), with the **victim call site shifting between binaries** as unrelated code was
added/removed elsewhere:

| Build (source delta only) | /bin/envprop exec (#37 path) | spawnpath selftest (#43 path) |
|---|---|---|
| 6-arg shape, build 1 | OK (exit 81) | **FAIL** (load -1 → SPcode=1) |
| 6-arg shape + 2 unrelated kprints in the callee | OK | OK |
| 6-arg shape, rebuilt w/o the kprints | **FAIL** (silent load -1) ×4 runs | OK |
| 4-arg + globals workaround | OK ×3 runs | OK ×3 runs |

Each binary's behavior was **stable across runs** (so not a runtime race; QEMU TCG's rdrand is
deterministic, making the boot allocation order per-binary-fixed) — the failure flips only with
code layout. This is the cc5/cycc regalloc-sensitivity class agnos already documents at several
sites (`sched.cyr` "an extra call can clobber a live reg", `proc.cyr` `cr3_load`'s `[rbp-8]`
idiom, the exec_ctx `var ctxp = &exec_ctx` idiom), and is adjacent to the cycc argv-capture
emission-order bug the attn11 session isolated (2026-06-11).

## Hypothesis (unverified — for the cyrius agent)

The 5th/6th argument setup of a compiled 6-arg call (SysV r8/r9), combined with in-argument
arithmetic (`spp + sp_ps` needing scratch) inside a very large function (`ksyscall`, agnos's
syscall dispatcher) under auto-regalloc, clobbers a live register holding another argument's
value before it is moved into its slot. 6-PARAM functions exist and work (`syscall_handler`);
the suspect is specifically the compiled 6-ARG CALL EMISSION shape under register pressure.

## Repro sketch

agnos @ the 1.44.19 dev tree, pin 6.0.56: restore the 6-arg `elf_load_from_file` signature +
the two ksyscall call sites (`git log` for the 1.44.19 cycle shows the exact reverted shape),
build `EXEC_SELFTEST=1 EXT2_WRITE_SELFTEST=1 RING3_SELFTEST=1`, run `scripts/exec-smoke.sh`
repeatedly: one of {`run: exit 81`, `ring3: spawnpath OK`} fails deterministically per binary;
add/remove any statement in the callee and the victim moves.

## agnos workaround (shipped, 1.44.19)

Env flows via `exec_env_src`/`exec_env_len` module globals with **consume-at-entry** discipline
(the loader copies them to locals and zeroes them as its first statements, so no stale env can
survive any early-reject path). The loader stays 4-arg.
