# There is no proportional font on AGNOS — a client that wants one has nothing to load

**Status:** ✅ **RESOLVED — SHIPPED 1.57.2 as the kernel-owned `/fonts` namespace (`kernel/core/kfont.cyr`), boot-proven from ring 3. Archived 2026-09-13.**
The ask was "a TrueType face that a client can `open()` on the target, at a path it can know", and it
deliberately declined to pick the mechanism. The operator picked it the same day: **rekha** is the
answer and the face is **kernel-embedded, kashi-style** — not a staged asset, not a mount.
**Filed:** 2026-09-13, by **crab**. **Resolved:** 2026-09-13 (same day), agnos 1.57.2 + rekha 0.3.8.

**What shipped.** rekha 0.3.8 generates `fonts/face_data.cyr` — **Liberation Sans Regular 2.1.5,
UNMODIFIED, 410,820 bytes, SIL OFL 1.1** (licence text at `../rekha/fonts/LICENSE-LiberationFonts`,
which must travel with any redistribution) — as a freestanding Cyrius module of 101 × 4 KB string-literal
chunks, and `scripts/build.sh` / `test.sh` / `bench.sh` cat it into the prepped kernel source exactly as
they cat kashi's `src/font_data.cyr` (`[deps.rekha]` in `cyrius.cyml` documents the contract;
`REKHA_REF=0.3.8` is the CI clone fallback, the sibling path wins locally). At boot `kfont_init` assembles
the chunks into one 2 MB direct-map region, **verifies them by FNV-1a-64 against the generator's hash of
the source `.ttf`**, and only on a match opens the namespace — boot line
`kfont: /fonts/default.ttf 410820 bytes OK`. ⛔ The verify is load-bearing: cyrius 6.6.3 silently
corrupts even-length string literals ≥ 64 KB (found while generating this face; filed in cyrius as
`issues/2026-09-13-agnos-large-string-literal-loses-first-byte.md`), so the kernel never exposes bytes it
has not hashed.

**The path, and the two names.** `open`#7 / `stat`#33 / `lstat`#102 intercept, **before the mount
table**, exactly two absolute names (exact byte compare — no wildcard, no directory listing, `/fonts`
itself is -1):
- **`/fonts/default.ttf`** — the stable contract; code against this one.
- **`/fonts/LiberationSans-Regular.ttf`** — the same bytes; the real name documents provenance.

Read-only by construction (`AO_WRONLY`/`AO_RDWR`/`AO_CREAT`/`AO_TRUNC`/`AO_DIRECTORY` each → -1), a
`VFS_MEMFILE` fd (`read`#5 to EOF returns all 410,820 bytes then 0; `write` and `lseek`#58 are -1 — read
it front-to-back in one pass), `stat`/`lstat` fill `st_mode 0100444`, `st_nlink 1`, `st_size 410820`.
Full contract: `agnos-userland-abi.md` **§3.5**; invariants: `architecture/kernel-font-namespace.md`.

**What crab needs to do: nothing but the load — as this filing predicted.** Open one of the two names
read-only, `file_read_all` to EOF (the existing loop-to-short-read is right; the face needs no seek),
`rekha_font_open` the buffer. ⭐ **Keep the `if (flen > 0)` guard**: `open` returning -1 is a real,
designed state (a pre-1.57.2 kernel, a failed boot-time verify, a `BOOTCR3_KEEP_GNOBOOT_CR3` build), and
the correct response is the bitmap-face fallback crab already has. But **measure it on QEMU** — this
filing's own trap paragraph is what makes that guard quiet, and it still is. The constraints it listed
hold: `sfntVersion 0x00010000`, `glyf` outlines, a `cmap` table (the gate asserts both tables present;
the format-4 requirement is rekha's to assert). The host Arch path in `setu_demo_client.cyr` is not an
AGNOS path and never will be; the client should try `/fonts/default.ttf` on AGNOS.

**Boot-proven, not merely compiled.** `scripts/smoke/kfont-smoke.sh` + `tests/kfont/kfont.cyr`
(`scripts/sweep.sh` row) — a real ring-3 process, exec'd from disk, opens the face by name, pulls every
byte through `read`#5, and requires **FNV-1a-64 `== 0xbb32949696578ce6`** — ⭐ the oracle is the hash,
not the length: the kernel's own `OK` line kept printing under a mutant that corrupted one byte after
the copy, and only the ring-3 hash caught it. Also probes each refused flag bit, both non-names, `stat`
and `lstat` field-for-field, and the alias. **Exit 95**; six mutants each fail it and were restored
byte-exact.

⚠ **WHAT THIS SHIPPED CHANGE BROKE, checked before archiving per the folder rule.**
1. **`mountlist`#104 is unchanged.** `/fonts` is a prefix intercept, not a mount: `kernel/core/vfs.cyr`
   (`vfs_mount_init`, `FsBackend`) is byte-unchanged, `tests/mountlist/mlist.cyr` is byte-unchanged and
   its `be > 3 → 83` rule at `:33` still passes — the table still emits backend ids 1..3 only. crab's
   VOLUMES sidebar sees no phantom disk. `statfs`#103 on the face path is not intercepted and answers
   -1 on a root without the file, as before.
2. **The two 2 MiB size gates went red** (`check.sh` `binary size`, `test.sh` `x86 size reasonable`;
   `build/agnos` 1,999,616 → 2,418,896 B). The cap is documented as "a grant, not a measurement — do not
   simply move it again", so it was **not raised**: each gate now weighs the kernel *minus* the face length
   read live from the face module the build consumed (2,008,076 B weighed, 89 KB under). Both green.
3. **A layout hazard the design's fit check did not see — filed, not fixed.** "Image end under the 4 MB
   identity map" holds (`LOAD` end `0x35E770`), but the AP1–3 boot/TSS stacks at `0x310000–0x340000` now
   sit **inside kernel `.rodata`**, on rekha chunks ~52..100. Inert today (the chunks are read once at
   ~0.3 s, the APs wake at ~5.2 s; an extra `-smp 4` boot confirmed it) and locked by a new check.sh gate
   34 (`scripts/check/image-layout-check.sh`: dead-bytes-only under the AP window, single reader chain,
   `LOAD` end ≤ `0x370000`, 275 B margin reported). Relocating the stacks is the operator's decision:
   `issues/archived/2026-09-13-ap-stacks-inside-kernel-rodata.md` (resolved 1.57.3).
4. **aarch64: no worse.** 33 reachable undefined functions / 46 undefined variables both before and
   after; no `kfont_*`/`rekha_*` diagnostics.
5. **CI cannot clone rekha 0.3.8 until the operator cuts the tag** — `../rekha` is at `VERSION` 0.3.8
   uncommitted with tags to 0.3.7. Local builds use the sibling path. The clone fallback now refuses to
   `rm -rf` a git checkout (rekha and kashi blocks alike), so a sibling with the sentinel untracked is
   an error, not a deletion.
6. Nothing else: `check.sh` 34/34, `test.sh` 4/4, `fmt-check` and `kprint-len-check` clean, the agnsh
   smoke unchanged.

⛔ **THE SECOND BLOCKER ON THE SAME CLIENT ITEM IS NOT OURS AND REMAINS OPEN.**
`dhancha/docs/development/issues/2026-09-13-scalable-text-allocates-per-call-outside-the-frame-arena.md`
— dhancha's scalable draw allocates a full-surface canvas per label per frame outside its arena. This
filing said both must clear, and that "a face arriving without that fix would ship a memory leak". The
face has arrived; the leak is dhancha's to close before crab's proportional-text item ships. Nothing in
this repo tracks it; it is recorded here so the next reader does not mistake "face shipped" for "item
unblocked".

⭐ **AND THE PART WORTH KEEPING: DECLINING TO APPROXIMATE WORKED A SECOND TIME.** This filing could
have staged a `.ttf` onto `build/rootfs` beside `cert.pem` and been done in an hour. It filed instead,
and the answer that came back was one it explicitly did not anticipate — a kernel-embedded face behind
a verify gate — which is the only shape that makes the face present on every boot of every image,
including the bare burn kernel, with its bytes checked before anyone reads them. Same posture as
`mountlist`#104; same result.

---

**Original filing follows, verbatim.**

**Status (as filed):** 🔴 **OPEN — a gap, not a bug. Nothing on AGNOS is broken.**
**Filed:** 2026-09-13, by **crab**.
**Affects:** the shipped filesystem and whatever AGNOS decides owns fonts. Not the kernel's HID,
console or FS paths, all of which already do what is needed.
**Severity:** **Low and patient.** One roadmap item in one client is blocked; the client has already
done everything it can do without it.

⭐ **OPERATOR RULING, 2026-09-13:** *"rekha is that thing... but has yet to get Kernel support."*
⇒ **rekha is the designated answer for proportional text**, and this is therefore **not** a "choose a
font" question. It is an AGNOS-side arc that has not been walked yet.

## The need, in one sentence

**A TrueType face that a client can `open()` on the target, at a path it can know.**

That is the whole ask, and it is deliberately not a design. Whether the answer is a staged asset, a
kernel-owned font service, a rekha integration, or something this filing does not anticipate is
AGNOS's call.

⚠ **This filing declines to approximate on purpose, and there is a precedent for why.** When crab
needed volume enumeration it *could* have shipped a probe — three fixed prefixes and `statfs` to
validate them. It deliberately did not, because a probe hardcodes AGNOS's namespace into a client
binary, can only confirm strings the client already guessed, and cannot see the aliasing that lists
one volume twice. It filed instead, and AGNOS took **both** halves of the advice: that this was *"an
enumeration because a probe cannot answer it"*, and that the answer should **mint `mountlist`#104
rather than widen `mount`#11**. ⇒ *Declining to approximate is what got the right primitive built.*
Same posture here.

## What was checked

⛔ **Stack-wide, across nineteen first-party repos: zero `*.ttf`, `*.otf`, `*.ttc`, `*.woff*`.** The
only TrueType files on the development machine belong to host distro packages and to an unrelated
project's `node_modules`.

⛔ **This repo contains no occurrence of "ttf", "truetype" or "sfnt"** in any script, manifest or
document. `build/rootfs` is `bin/` (first-party ELF binaries), `etc/ssl/cert.pem`, an empty `fw/` and
a verification PNG — no `/usr`, no `/share`, no font directory. `grep -i font scripts/burn/` is empty.

⚠ **Two things that would be easy to assume are missing are NOT missing**, and saying so keeps the
ask pointed at the real gap rather than at work already done:

- **Reading a large file works.** A client's `file_read_all` loops to a short read with no cap, and
  `file_open` already carries the `AO_*`/namelen bridge. A 410 KB face is an ordinary read.
- **A staging path exists and already carries a non-binary asset.** `scripts/burn/stage-tools.sh`
  populates `build/rootfs`, and fs-population copies it whole — `mke2fs -d build/rootfs` for QEMU,
  `install-media.sh` by label for iron. `etc/ssl/cert.pem` (185 KB) is delivered by exactly that
  route today.

⇒ The gap is **not** "a client cannot read it" and **not** "there is no mechanism to place a file".
It is that the face, and whatever owns it, do not exist yet.

## ⛔⛆ One trap worth recording, because it would look like success

The only caller in the whole stack that feeds `rekha_font_open` real file bytes is
`dhancha/programs/setu_demo_client.cyr`:

```
var fontpath = "/usr/share/fonts/liberation/LiberationSans-Regular.ttf";
var flen = file_read_all(fontpath, fbuf, 1048576);
if (flen > 0) { font = rekha_font_open(fbuf, flen); }
```

That is a **host Arch path**. It does not exist on AGNOS, and `flen` comes back negative there. The
`if (flen > 0)` is a correct guard, and it is exactly what makes the failure **quiet**: a client
copying this pattern works on its host build, falls back silently to the bitmap face on the target
that ships, and looks finished. ⇒ Any client-side font load must be **measured on QEMU**, not
observed to compile.

## Constraints on whichever face is chosen

From rekha 0.3.7, and cheap to check up front:

- **`glyf` outlines only.** CFF/OpenType is rejected outright — `rekha_font_open` accepts sfntVersion
  `0x00010000` or `'true'` and nothing else.
- **A format-4 BMP `cmap`.**

⚠ **kashi is not an alternative.** It owns AGNOS's *bitmap console* fonts by design — PSF/BDF/PCF
import and three built-in CP437 tables — and has no scalable face. rekha's own README states the
split: *kashi — bitmap glyph sources; rekha — outline / Bézier glyph sources.*

## What the client already did rather than wait

crab **0.8.10** shipped every half of its proportional-text item that does not need the face: all
seven character-count widths are now **derived from the font** rather than written as pixel literals
at kashi's 9 px advance, and its suite **builds a synthetic proportional face** (unequal advances) and
watches every derived width move.

⇒ **When a face arrives, crab expects to need nothing but the load itself.** That is why this half was
done first, and it is the reason this filing is patient rather than urgent.

## Related

- `dhancha/docs/development/issues/2026-09-13-scalable-text-allocates-per-call-outside-the-frame-arena.md`
  — the **second, independent** blocker on the same client item: dhancha's scalable draw allocates a
  full-surface canvas per label per frame outside its arena. Both must clear. A face arriving without
  that fix would ship a memory leak.
