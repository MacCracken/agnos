# QEMU harnesses — what they are, and when to reach for one instead of a burn

These drive a **real agnos kernel in QEMU** through an emulated xHCI keyboard (HMP `sendkey`), building
their own disk image from `build/rootfs` + `build/agnos`. They are **not** run by `scripts/sweep.sh` —
that gate runs `scripts/smoke/*` only. Harnesses are manual, because typing at 10 keys/second makes them
far too slow for a pre-burn gate.

## ⭐ The rule these exist to enforce: userland questions do not cost a burn

An iron boot costs the operator a reboot of their only machine. A QEMU run costs a minute. On 2026-08-11
the roadmap's *"Uncertain — verify on the next burn"* list had been riding burns for weeks without
producing outcomes — and **three of its four items were pure userland** (a shell reaction, a syscall
wrapper, a version string). `sweep-test.py` settled all three in one QEMU boot, and one of them turned out
to be a real kernel bug that a burn would only have re-confirmed without localising.

⇒ **Before putting a question on a burn card, ask where the answer actually lives.** Only what needs
archaemenid's own silicon — the real xHCI HID path, a real disk, real DCN timing, real SMP — belongs on
iron. Everything else belongs here.

⚠ **The converse also holds and has cost a burn's worth of confusion**: QEMU is *not* a control for a
timing- or pressure-dependent bug. A lossy-queue failure that killed a client on iron reproduced not at
all here — the *unmodified broken code* passed identically. When a fix targets a timing regime, say out
loud that the harness is not the evidence.

## Making a harness prove something

Two traps, both paid for in this repo:

- **The first keystroke of a session is swallowed.** It triggers `hid: first keyboard report dispatched
  via the endpoint registry` and never reaches the line editor. On its first run `sweep-test.py` lost the
  `r` of `run /bin/iam`, agnsh saw `un /bin/iam`, and the check reported FAIL — looking exactly like an
  `iam` bug while measuring nothing. **Send a bare Enter to absorb the window before any check that
  carries meaning.**
- **A passing test that would also pass when broken is worthless.** Mutate the code under test and watch
  the assertion go red. `hid-mouse-deferred-test.py` was validated this way (disable the flush call → the
  one-shot assertion fails), and `hid-cc-inject-test.py` ships with an explicit control arm.

## The harnesses

| Harness | Proves |
|---|---|
| `sweep-test.py` | The userland half of a roadmap sweep in one boot: `iam`'s uname chain (`agnos_version_str()` → uname#34 release; the `_AGNOS_VERSION` gvar the chain once named was deleted at 1.57.14 — an x86 kernel build never ran its initializer), `kriya ln -s`, `kriya readlink` no-follow, and shell survival of a faulted `&` job (the `version` oracle matches any `agnoshi N.M` since 1.57.14 — the literal `agnoshi 1.` scored agnoshi 2.0.3 as dead, here and in six more harnesses). Extend this rather than writing a new one-off. |
| `hid-mouse-deferred-test.py` | The **mouse** one-shot still reaches the console after being deferred out of ISR context. Attaches a QEMU USB mouse and injects motion; asserts the line arrives **without any typing**, which is what proves the `kb_has_key` poll loop drives the flush. |
| `hid-cc-inject-test.py` | The HID drain re-arms its ring on a **rejected** completion code. ⛔ Needs `HID_CC_INJECT=1 sh scripts/build.sh` — inert against a normal kernel. **Since 1.57.1 it refuses to run without the flag** (it witnesses the `CC INJECTION ARMED` banner and exits 2), so it can no longer score green against an ordinary kernel. Run the control arm too. |
| `hid-halt-oracle-test.py` | ⭐ **The ORACLE for the roadmapped HID iron burn — not the burn itself.** Proves a *halting* completion code (6) reaches `hid_recover_halted` and that the endpoint is recovered, which `hid-cc-inject-test.py` structurally cannot: that flag forces ccode 2, which is not a halting code. ⛔ Needs `HID_CC_INJECT_HALT=1 sh scripts/build.sh`, and refuses to run without it. Drives keystrokes through the **QEMU monitor**, because `usb-kbd` emits no completion at all until a key is actually pressed. **Mutation-proven.** ⚠ Correctly absent from `sweep.sh` — harnesses are manual by design; it was absent from *this table*, which is what made it undiscoverable. |
| `aethersafha-clients-test.py` | Reproduces, in QEMU, the iron failure where the desktop's setu clients fail to relaunch (the 16-slot process table). |
| `puka-terminal-test.py` | A live agnsh prompt answering inside a **composited window**. |
| `agnsh-bg-test.py` · `agnsh-bg-smp4-test.py` · `agnsh-multijob-test.py` | agnsh `&` background jobs: non-blocking `spawn_path`#43, prompt stays live, jobs reaped. The smp4 and multijob variants add AP scheduling and concurrency. |
| `agnsh-delegation-test.py` · `agnsh-type-test.py` · `agnsh-kvm-test.py` | Coreutils delegation to kriya on the real ext2 root (`/bin/<verb>` symlinks, `owl`, the `cat` nudge), and basic typed-input paths. ⚠ `agnsh-verb-test.py` was RETIRED at 1.57.14: it drove agnoshi 1.4.2's in-process `echo`/`ls`/`cat` verbs, which agnoshi 1.5.0 removed (agnsh delegates to `/bin/kriya`; `cat` nudges to `owl`), so on any current agnsh it could only fail — measured: `ls /` → "not a known command here", `cat` → the owl hint. `agnsh-delegation-test.py` is its successor and, since 1.57.14, carries its distinctive half too: `echo VERBPROOF > /vtest` (agnsh output redirection) read back with `owl -p /vtest`; `scripts/tool/redirect-smoke.py` drives the same redirect with `owl` as the writer. |
| `run37-smp4-test.py` | `execwait`#37's save/restore path under `-smp 4`. |
| `pipe-stream-test.py` | Pipeline streaming through the `#97` channel band (byte-exactness through a small ring). |
| `pty-host-test.py` | stdio riding a channel as a PTY. |
| `crab-resize-test.py` | crab adopts (or **survives refusing**) a real `SETU_CONFIGURE`, resolves a real **pointer click**, and is **still answering keys afterwards**. The only harness that both starts crab and leaves it running: Ctrl+F2 → **DOWN** → Enter picks `/bin/crab` specifically (the launcher registry is puka at 0, crab at 1, and `lnch_openp` resets the selection to 0 — a harness that skipped the DOWN would launch puka and score whatever puka did). ⛔ It found a real bug on its first run: crab closed its only shm buffer before knowing the replacement existed, and exited. ⚠ Under QEMU there is no GPU carveout, so `setu_buf_create` falls back to the 2 MB `#71` pmm slot and a fullscreen ask (measured: 2048x2018 ≈ 16.5 MB) **cannot be backed** — that arm proves the refusal path; the adopt path needs a machine with a carveout. ⭐ The pointer arm proved the PTR_MOVE/PTR_BTN wire end to end (crab is the first client to decode it); its oracle is deliberately coarse — `usb-mouse` is RELATIVE, so a harness cannot land on a chosen pixel, and row-level precision is asserted on the host against the real rendered tree instead. |
| `wait-kbd-test.py` | ⭐ **1.57.7 (S3d) — the keyboard read blocks only its caller, and ONE reader owns each cooked line.** Seeds `tests/waits/waitx` as `/bin/agnsh` in mode `kbd` and types over HMP: K0 warm-up, K1 whole lines (shift, backspace, Ctrl-D EOF), K2 spinners keep the CPU while a read waits, K3 the NB prompt poll yields a line to a blocking child, K4 two blocking children get one whole line each, K5 an NB partial line is never split. Boots `-smp 1` then `-smp 4`, banner-gated. **Wrapped by `scripts/smoke/wait-kbd-smoke.sh`, which IS a sweep row** — the one harness here that is. ⚠ Types at one key per 0.15 s with a NON-blocking monitor drain (a blocking `recv` with a 0.5 s timeout made every key cost 0.6 s). Its first run found a real kernel defect: every keyboard TRB shared ONE report buffer, so a key pressed and released inside one IF=0 stretch was lost (`abc` read `bc`) — fixed with per-TRB report slots (hid.cyr), which is also the likely cause of `agnsh-bg-smp4`'s "ersion". |
| `_invdeny.py` | Not a harness — the ONE loader of `SMOKE_INVARIANT_DENY` for Python harnesses (1.57.7): it reads the value out of `scripts/smoke/lib/qemu-dwell.sh` and refuses (exits) if that line is missing or not one double-quoted value. **New harnesses MUST use it** instead of pasting the pattern. |
| `_siblings.py` | Not a harness — ⭐ **1.57.14: where a harness finds a sibling repo.** `sibling("<repo>", "<NAME>_ROOT")` = `$<NAME>_ROOT` if set and non-empty, else `${SIBLINGS_ROOT:-<tree>/..}/<repo>` — the rule the smokes, `stage-tools.sh` and `syscall-abi-check.sh` follow. From a worktree `<tree>/..` holds no sibling, and most harnesses used to read `os.path.join(ROOT, "../gnoboot")` with no variable at all. **New harnesses MUST use it**; `check.sh` gate 40 (`scripts/check/smoke-hygiene-check.sh`) refuses any other sibling default. Siblings are READ-ONLY: a harness reads a built binary, never builds there. |
| `_qsock.py` | Not a harness — where a harness binds QEMU's UNIX sockets (1.57.13): `qsock(os.path.join(WORK, "<name>.sock"))` gives a short (`sun_path` is 108 bytes), per-tree path under `$XDG_RUNTIME_DIR` (the Python twin of `smoke_qsock`). Every harness binds its `-monitor` / `-qmp` there since 1.57.14 — the fixed `/tmp/agnos-*.sock` names were shared by every tree, so two trees running one harness drove each other's QEMU. Gate 40 refuses a `unix:{X}` whose `X` is not a `qsock(...)`. |
| `doom-input-test.py` | `kbscan`#42 end-to-end — a keypress reaching a client. ⚠ Note agnos has **two** keyboard syscalls: `read`#5 cooks and drops keys with no ASCII (every F-key); `kbscan`#42 drops nothing. They share one ring, so consumers compete. |

⚠ **`pipe-stream-test.py` and `pty-host-test.py` carry a stale copy-pasted `agnsh-bg-test` header.** Their
*behaviour* is as described above; only the comment block is wrong. Fix the header before trusting a
skim of either file — noted 2026-08-11 rather than silently corrected, since neither was under test.

## Running one

```sh
sh scripts/build.sh                       # or a flag-gated build the harness names
sh scripts/burn/stage-tools.sh --build    # harnesses seed from build/rootfs — stage first
python3 scripts/harness/<name>.py
```

Siblings (gnoboot, agnoshi, crab, aethersafha, puka) resolve through `_siblings.py`: export `SIBLINGS_ROOT` (or the
harness's `<NAME>_ROOT`) when running from a worktree, whose parent holds no sibling. A new harness follows the same
rules or `check.sh` gate 40 (`scripts/check/smoke-hygiene-check.sh`, 1.57.14) refuses it: siblings through `sibling()`,
an `X_BIN` / `X_ROOT` override read as `os.environ.get("X") or …` (an exported-empty variable is unset), every
`-monitor` / `-qmp` socket through `qsock(os.path.join(WORK, …))`, no fixed `/tmp/<name>` (a path inside the guest
carries `# guest path`), and no build inside a sibling.

⛔ Never run two of these at once, and never run one while `check.sh` / `sweep.sh` is running on the same
tree — a gate result taken under concurrent load is un-attributable, and they all rebuild `build/agnos`.
