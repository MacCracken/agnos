# 2026-11-06 — a program's relative path is rooted at /, and each program has to know that

**Status:** ✅ **RESOLVED in agnos 1.57.18** (operator ruling 2026-11-08: the kernel keeps a working directory per process —
it reverses ABI § 3.2's "CWD is userland-owned"). **`chdir`#112** / **`getcwd`#113**; inherited across `spawn`#3,
`spawn_path`#43, `execwait`#37 and `fork`#96, and a #43 / #37 child is seeded from a valid `PWD=` in its env, so agnsh's
children land where agnsh is with no agnsh change. Every relative path any syscall takes resolves from it through one
ingress (`sc_path_take`, a kernel copy cleaned lexically, never truncated: 4096+ in or 4095+ out is -1). The issue's own
case — `etc/secret.txt` from a cwd that is not `/` — no longer reads `/etc/secret.txt`. Gate `scripts/smoke/cwd-smoke.sh`
(ext2, ZFS, FAT; -smp 1 + 4). Design `docs/architecture/working-directory.md`. ⚠ The cyrius `sys_chdir` / `sys_getcwd` peer
is pending (`cyrius/docs/development/issues/2026-11-08-agnos-sys-chdir-getcwd-112-113-peer.md`); thoth's `fs_path` stays
correct either way.
*(Filed from thoth **0.55.1**, whose hostile pass on AGNOS found the cost.)*
**Checked against:** agnos **107ad763** (1.57.17), `kernel/core/syscall.cyr:569`; cyrius **6.7.18**, `sys_chdir` returns -38; agnoshi `src/cwd.cyr`.
**Severity:** a security defect in thoth, now fixed there, and the same trap for every other program.

## What happens

The userland ABI says: "CWD is userland-owned: agnsh tracks its own CWD and passes absolute paths to every syscall", and a relative name is rooted at `/`. So every program must resolve its own relative operands against `$PWD`. Nothing tells it to, and on any other target the kernel does it.

thoth did not know. Its `read_file` jail is "relative, with no `..`", which on Linux means the project. On agnos it meant the disk: `read_file("etc/secret.txt")` returned the file, `search` walked every directory, and `create_file("etc/x")` was stopped only by a missing checkpoint directory.

agnoshi's `cwd.cyr` records the same trap elsewhere: kriya and owl do not read `$PWD`, so a typed `ls notes` means `/notes`.

## The ask

A working directory the kernel holds per process: `chdir`, inherited across `spawn_path#43` and `fork#96`, and seeded from a `PWD=` in the spawn's environment so nothing that exists today has to change. Relative paths already meet one place, the rooting at `syscall.cyr:569`, which would prefix the process's directory instead of `/`.

## What it costs, and why it is a ruling

It reverses § 3.2 and adds per-process state. The alternative is the status quo, where each program carries a copy of this logic and a program that forgets it reads the wrong file, silently. thoth's took a seam, `fs_path`, and 33 call sites, and no test on any other platform could have caught it.

## What thoth does meanwhile

Since 0.55.1 it resolves every relative path against `$PWD` itself, as the ABI asks. That stays correct either way: with a kernel cwd, `fs_path` would become the identity and could go.
