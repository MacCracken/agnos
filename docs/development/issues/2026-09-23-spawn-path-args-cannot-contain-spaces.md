# 2026-09-23 — `spawn_path`#43 cannot pass an argument that contains a space

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
