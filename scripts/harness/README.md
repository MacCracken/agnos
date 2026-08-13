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
| `sweep-test.py` | The userland half of a roadmap sweep in one boot: `iam`'s uname chain, `kriya ln -s`, `kriya readlink` no-follow, and shell survival of a faulted `&` job. Extend this rather than writing a new one-off. |
| `hid-mouse-deferred-test.py` | The **mouse** one-shot still reaches the console after being deferred out of ISR context. Attaches a QEMU USB mouse and injects motion; asserts the line arrives **without any typing**, which is what proves the `kb_has_key` poll loop drives the flush. |
| `hid-cc-inject-test.py` | The HID drain re-arms its ring on a **rejected** completion code. ⛔ Needs `HID_CC_INJECT=1 sh scripts/build.sh` — inert against a normal kernel, so a green run there means nothing. Run the control arm too. |
| `aethersafha-clients-test.py` | Reproduces, in QEMU, the iron failure where the desktop's setu clients fail to relaunch (the 16-slot process table). |
| `puka-terminal-test.py` | A live agnsh prompt answering inside a **composited window**. |
| `agnsh-bg-test.py` · `agnsh-bg-smp4-test.py` · `agnsh-multijob-test.py` | agnsh `&` background jobs: non-blocking `spawn_path`#43, prompt stays live, jobs reaped. The smp4 and multijob variants add AP scheduling and concurrency. |
| `agnsh-verb-test.py` · `agnsh-delegation-test.py` · `agnsh-type-test.py` · `agnsh-kvm-test.py` | agnsh's FS verbs on the real ext2 root, coreutils delegation to kriya, and basic typed-input paths. |
| `run37-smp4-test.py` | `execwait`#37's save/restore path under `-smp 4`. |
| `pipe-stream-test.py` | Pipeline streaming through the `#97` channel band (byte-exactness through a small ring). |
| `pty-host-test.py` | stdio riding a channel as a PTY. |
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

⛔ Never run two of these at once, and never run one while `check.sh` / `sweep.sh` is running on the same
tree — a gate result taken under concurrent load is un-attributable, and they all rebuild `build/agnos`.
