# 2026-09-23 — `spawn_path`#43 cannot pass an argument that contains a space

**Status:** ✅ **RESOLVED 1.57.6 (2026-09-24)** — `spawn_path`#43 gains an argv form, `SPAWN_F_ARGV` (`a2 = len | 0x10000`; a1 = `argv0\0argv1\0…\0`, ≤ 1024 B, ≤ 16 entries, entries may contain spaces), and a line or blob with more than 16 entries is **refused** (#43 −6, #37 −1), never dropped. The line form is kept for the shell. Gate: `scripts/smoke/spawn-smoke.sh` (sweep row; `SPAWNX-ARGV-OK`, `-ARGV-LONG-OK`, `-ARGV-REFUSE-17-OK`, `-EARGS-17TOK-OK`, `-16TOK-OK`, `-37-17TOK-OK` at `-smp 1` and `-smp 4`). Built, gated, NOT burned. See § Resolution.
**Filed by:** daimon (the AGNOS agent orchestrator). It starts an agent as
`<exe> --agent-id <id> --agent-name <name>`, and an agent's name is the operator's to choose.
**Checked against:** agnos **1.57.5**: `kernel/core/syscall.cyr` (the `#43` arm at `:10487`) and
`kernel/core/elf.cyr`, read in the working tree.
**Consumer impact:** on agnos daimon must refuse to start an agent whose name contains a space, or
whose command line is longer than 127 bytes.

> `#43` takes one line, splits it on spaces (byte 32) with no quoting (`elf.cyr`, the argv loop
> around `:555`), caps the line at 127 bytes (the `#43` arm's `if (arg2 > 127)`), and keeps at most
> 16 arguments, silently dropping the rest. So no argument can contain a space, and a long argument
> does not fit.

---

## The ask

- **An argv form with explicit boundaries:** NUL-separated arguments plus a total length, the same
  shape as the env blob `#43` already accepts in a3/a4. For example, a flag, or a sibling call.
- **Keep the current line form** for the shell.
- A limit on the total size is fine. daimon's lines are about 60 bytes plus the name.
- **Refuse rather than drop:** an argument past the count limit is a caller error. Today it
  disappears.

## A small thing found on the way

`sc_env_blob_ok`'s comment (`syscall.cyr`, above the function) still says *"with argc<=8"*. The
cap has been 16 since 1.46.x (`elf.cyr:555`).

---

## Resolution (1.57.6, 2026-09-24)

**What shipped** (ABI §4.8, normative; `spawn_path_sys` in `kernel/core/syscall.cyr`, the NUL mode of
`elf_load_from_file`):

- **An argv form with explicit boundaries:** `SPAWN_F_ARGV` = `0x10000` in a2. a1 is
  `argv0\0argv1\0…argvN\0` (last byte NUL), 2..1024 B (`SPAWN_ARGV_MAX`), 1..16 entries
  (`SPAWN_ARGC_MAX`); argv[0] (1..255 B) is the path opened; later entries may contain spaces or be empty.
  The blob is copied with the fault-proof page-walking copy. It combines with `SPAWN_F_CLEANFD` and takes the
  env blob in a3/a4 as before (a flagged form refuses a bad env blob with −6).
- **The line form is kept** (≤ 127 B, `SPAWN_LINE_MAX`; split on spaces, no quoting).
- **Refuse rather than drop:** more than 16 tokens (line) or entries (blob) → `#43` −6
  (`SPAWN_E_ARGS`), `#37` −1, counted in each arm before any per-CPU loader cell is set. ⚠ This is a
  BREAKING change for any caller that relied on the silent drop (CHANGELOG 1.57.6 § Breaking).
- The "argc<=8" comment above `sc_env_blob_ok` now says 16 (the cap since 1.46.x).

**What the change broke — checked before archiving:** nothing observed across the sweep, `ktest`,
`agnsh-smoke`, the pipe-stream / run37-smp4 / agnsh-bg-smp4 / pty-host / puka-child-stdout harnesses.
16-token lines still run (`SPAWNX-16TOK-OK`). The 1.57.5 control ran the 17-token line with the extra token
dropped (`EARGS-17TOK-BAD rc=3`). A loader-cell ordering test (`SPAWNX-LOADER-CELLS-CLEAN-OK`) proves a
refused flagged spawn leaves no stale argv mode for the next `#37`.

**Consumer notes:** daimon can pass `--agent-name` with spaces through the argv form. agnoshi's
`run_agnos.cyr` comment "#37 has no such cap" is now wrong — lines over 16 words fail (split them or use the
argv form). cyrius peer constants/wrapper (`SPAWN_F_ARGV`, `sys_spawn_argv`) are filed in cyrius
`docs/development/issues/2026-09-24-agnos-spawn-flags-redirect-ops-and-uptime-us-peer.md`.
