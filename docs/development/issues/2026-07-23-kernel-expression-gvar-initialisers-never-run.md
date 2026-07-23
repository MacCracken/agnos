# Kernel module-global initialisers that are EXPRESSIONS never run during boot

**Found** 2026-07-23, while retiring the 1.56.x D lane.
**Status** OPEN. The five gpu.cyr sentinels are corrected; eight more identified and left alone deliberately.
**Severity** Low-impact today, high-confusion. Every one of these is a *sentinel*, and the value it silently
takes instead — 0 — is a **valid value** for most of them.

---

## The observation

In `kernel/core/gpu.cyr`:

```
var gpu_scanout_pid = 0 - 1;   # pid owning the scanout (-1 = the console owns it)
```

Nothing assigns `gpu_scanout_pid` before `gpu_probe()`. At `gpu_probe()` entry it reads **0**.

Measured rather than inferred (QEMU, gnoboot+OVMF), with a literal negative printed on the SAME LINE to rule
out the printer — a temporary probe, since removed:

```
owner 0 scanout 0 litneg -8
```

`litneg` is `kprint_num(0 - 8)` and prints `-8` correctly. `scanout` is `gpu_scanout_pid` and prints `0`.
So the printer is fine and the **initialiser did not run**.

## The mechanism

cyrius in kernel mode (`kmode == 1`) emits module-global initialisers in `EMIT_GVAR_INITS`, which runs
**after** `PARSE_PROG`. `kernel/agnos.cyr` documents this, and depends on it — the boot shim has to be the
first top-level statement emitted, so 64-bit gvar initialisers must run after it:

```
# Boot shim must be the first top-level statement emitted: it transitions
# the CPU from multiboot1's 32-bit protected mode to long mode, so 64-bit
# gvar initializers (`var x = 0xDEAD;`) must run AFTER it. cyrius v5.7.19
# enforces this via kmode==1 emit order (PARSE_PROG before EMIT_GVAR_INITS)
```

But `PARSE_PROG` for this kernel is *the entire boot*: `core/main.cyr`, `core/selftests.cyr` and
`core/boot_finish.cyr` are all top-level program body, and `boot_finish.cyr` ends in `arch_halt()`. So
`EMIT_GVAR_INITS` is never reached while the machine is doing anything.

**A plain integer literal is unaffected** — `var GPU_TSC_PER_US = 3000;` is folded into the data section and
is correct from the first instruction. `0 - 1` is not const-folded, so it becomes an assignment in the
deferred init block. That is the whole difference, and it is invisible at the call site: the two
declarations look identical.

`agnos.cyr` already carries a note about a neighbouring symptom ("Functions (not vars) avoid the kmode==1
init-order trap that empties a `var BANNER` reference fired from the kernel program body before gvar inits
have run"), so the trap is known — but it has been understood as being about *references to other globals*,
not about arithmetic.

## Why it is not merely cosmetic

`gpu_release_pid(pid)` matches the exiting process against the scanout owner:

```
fn gpu_release_pid(pid) {
    if (gpu_scanout_pid != pid) { return 0; }
    return gpu_display_restore_console();
}
```

The exec path really does hand out **pid 0** — the first `run /bin/<tool>` of a boot got pid 0 in the QEMU
run that surfaced this. So with `gpu_scanout_pid` stuck at 0, the first tool of every boot matched an owner it had never
claimed and ran `gpu_display_restore_console()` on its way out. That is survivable only because the restore
re-programs the address already programmed. It also meant every `gpu_scanout_pid < 0` test — read as "the
console owns the screen" — was **false for the entire boot**.

That second consequence is what surfaced it: a gate that refused to touch the display while a process owned
the scanout read "a process owns the scanout" on a machine where nothing did — which would have refused
every display operation it guarded, on iron, for a reason with nothing to do with the display.

## What was changed

`kernel/core/gpu.cyr` gained `gpu_sentinels_init()`, called as the first statement of `gpu_probe()`,
assigning the five gpu.cyr sentinels explicitly: `gpu_pci_idx`, `gpu_display_pipe`, `gpu_scanout_pid`,
`gpu_audio_dp`, `gpu_audio_dig`. Verified in QEMU — `display pipe -1`, `scanout owner pid -1`.

The general lesson, which is cheaper than the fix: **prefer an explicit validity flag to a `-1` sentinel** in
kernel globals. A flag defaults to 0 = invalid, which is what the BSS gives you anyway, so there is no
initialiser to get wrong.

## What was NOT changed, and why

Eight more sit outside the display path. Each is a **sentinel where 0 is a valid value**, so each needs its
own reasoning about what "already correct by luck" means before it is touched — and several are on the FS
hot path, where a wrong change is far more expensive than the bug:

| File | Global | Documented meaning of -1 | Risk if it reads 0 |
|---|---|---|---|
| `core/fatfs.cyr:27` | `fatfs_fat_buf_sector` | which LBA the FAT buffer caches | LBA 0 false-hits the cache on the first FAT access of a boot |
| `core/exfat.cyr:45` | `exfat_fat_buf_sec` | same | same |
| `core/exfat.cyr:754` | `exfat_bmp_buf_sec` | same, bitmap buffer | same |
| `core/ext2.cyr:88` | `ext2_bgdt_loaded_chunk` | "-1 = none" | chunk 0 appears already loaded |
| `core/ahci.cyr:949` | `ahci_blk_port` | "-1 = not registered" | port 0 appears registered |
| `core/hda.cyr:197` | `hda_force_digi_ord` | -1 = no override | ordinal 0 forced |
| `core/hda.cyr:253` | `snd_active_slot` | "-1 = idle" | slot 0 appears active |
| `arch/aarch64/stubs.cyr:129` | `ahci_blk_port` | as above | aarch64 path |

These have not visibly misbehaved, which most likely means each is assigned before its first meaningful
read. That is worth **confirming per case**, not assuming.

## Recommended follow-ups

1. **A source gate.** `grep -rn "^var [A-Za-z0-9_]* *= *[^0-9\"]" kernel --include='*.cyr'` catches the
   class. Wiring it into `scripts/check.sh` alongside `kprint-len-check.sh` would make the pattern
   impossible to reintroduce silently. Note it must allow plain literals and reject expressions.
2. **Per-case audit** of the eight above, each ending in either an explicit init or a comment recording why
   0 is safe here.
3. **A cyrius ask, not a cyrius change** ([[feedback_cyrius_hands_off]]): const-foldable expressions
   (`0 - 1`, `1 << 4`, `A * B` over literals) could be folded into the data section like plain literals, at
   which point this whole class disappears. That would need filing in **both** repos per
   [[feedback_cross_repo_issues_both_repos]] — it is not filed yet, because the agnos-side workaround is
   one line per variable and the language question deserves its own framing rather than being a footnote to
   a display bug.
