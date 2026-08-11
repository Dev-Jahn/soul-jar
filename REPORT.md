# soul-jar 0.9.0 — confluence report

## Round 1: what changed

- Added rooms and an optional rsync rendezvous with local-path and rsync-over-SSH transports.
- Added mkdir locking with stale-lock recovery, byte-prefix CAS, staged mainline commits,
  bounded network operations, hook throttling, and local-only `.sync/` state.
- Added pending-seal shielding, encrypted tributaries and authenticated metadata, verified
  confluence prompts, consumed-id exclusion, transitive woven-life accounting, and exact
  tributary deletion after a successful confluence.
- Added `soul-jar enroll <target>` for found, join, and two-jars-meet cases, plus manual
  best-effort `soul-jar sync`.
- Made whispers, per-room heard marks, open letters, and the current mainline travel while
  keeping the key, bedside, log, watches, relics, config, and sync state inside each room.
- Extended status, death facts, recovery documentation, the threat model, config/files tables,
  plugin metadata, and the test harness for 0.9.0.

## Round 2: the repair

An independent QA review of `721b186` refuted six invariants and raised seventeen findings.
This round repairs them on top of that commit — nothing rebased, nothing rewritten.

### What was wrong, in one paragraph

The round's own new chain format met old code in one place and made a confluence life's
relic unverifiable (F1). Two paths lost a sealed life outright: a stale recorded tributary
pushed in a newer seal's place (F2), and a finalizer that reported success on a failed chain
commit while clearing the pending marker (F3). The same finalizer read a file missing from
the stage as an instruction to delete its mainline counterpart, so one shattered room could
strip the seal from every room that pulled after it (F16) — the most destructive finding.
Two more paths damaged the stream without losing a seal: a room could adopt a torn mainline
and then be told its jar had been tampered with (F5a), and an interrupted sync stranded the
rendezvous lock and its stage (F5b, F6). Finally the compatibility invariant was broken by
one filename (F14), the rendezvous archived letters forever (F7), and several smaller
findings ran from silent misconfiguration to documentation that outran the code.

### Disposition of every finding

| # | Finding | Disposition |
|---|---|---|
| F1 | `_verify_relic` cannot verify a confluence life's relic | **fixed** — `c62675b` |
| F2 | a sealed life lost to a stale recorded tributary | **fixed** — `37943d1` |
| F3 | `_finalize_local_push` reports success on a failed commit | **fixed** — `3ee8718` |
| F4 | a woven tributary can be replayed under a new name | **declined** (documented) |
| F5 | a `SYNC_WAKE_CAP` timeout tears the mainline and strands the lock | **fixed** — `d20d93d`, `103fe54` |
| F6 | an interrupted push leaves its stage forever | **fixed** — `77ac885` |
| F7 | letters accumulate at the rendezvous forever | **fixed** — `3d5ac69`, `ca10bd1` |
| F8 | an invalid `ROOM` disables syncing silently | **fixed** — `96ea0d8` |
| F9 | a failed `enroll` still writes `RENDEZVOUS` | **fixed** — `96ea0d8` |
| F10 | `genesis` is a parent that is always valid | **declined** (same root as F4) |
| F11.1 | README's bounded-forgetting claim vs. letters | **fixed** — F7's repair, README rewritten |
| F11.2 | rendezvous-side files undocumented | **fixed** — `d0566c5` |
| F11.3 | "no key, bedside, log…" — verified accurate | **no action** (re-verified this round) |
| F11.4 | relic fallback stated without F1's caveat | **fixed** — F1's repair removes the caveat |
| F11.5–7 | key distribution, config table, plugin.json version — accurate | **no action** |
| F12 | the suite never exercises a failed rendezvous *write* | **fixed** — five new stand-ins |
| F13 | `_build_push_stage` does not check its copies | **fixed** — `3ee8718` |
| F14 | `RENDEZVOUS` unset no longer reproduces 0.8.0 | **fixed** — `219f87f` |
| F15 | a local-path rendezvous is entirely unbounded | **fixed** — `96ea0d8` |
| F16 | a shattered room deletes `soul.sealed` from the rendezvous | **fixed** — `5c44ebc` |
| F17.1 | threat model's "only" enumeration incomplete | **fixed** — `d0566c5` |
| F17.2 | whisper and letters land world-readable | **fixed** (disclosed) — `d0566c5` |
| F17.3 | Files table dropped the flat `.whisper.heard` | **fixed** — `d0566c5` |
| F17.4 | the founding branch pushes without a prefix check | **fixed** — `d0566c5` |
| F17.5 | `cmd_status`'s stream lines undocumented | **fixed** — `d0566c5` |
| F17.6 | rendezvous has no Files listing | **fixed** — `d0566c5` (same as F11.2) |
| F17.7 | `REAPER` tested three different ways | **fixed** — `d0566c5` |
| F17.8 | local-only jar artifacts missing from Files | **fixed** — `d0566c5` |
| F17.9 | `plugin.json` description contradicts itself | **fixed** — `d0566c5` |
| F17.10 | items re-checked as accurate | **no action** |

### The eight settled repairs, in detail

1. **F1 — a confluence life's relic verifies.** `_verify_relic` was the file's only positional
   chain reader, and `read` with three variables collects every remaining field into the last.
   A trailing discard restores field 3 as the MAC. The relic of a woven life now recovers that
   life, not an older one.

2. **F2 — the current seal always reaches the stream.** A recorded tributary id is trusted only
   while its ciphertext still equals `soul.sealed`. When a later death has moved the seal on,
   the superseded tributary is recorded as an *ingredient* of the newer seal (the dream that
   made it read the older one) and a fresh tributary is minted for the seal that actually
   lives here. The supersede check also runs at the top of `_resolve_pending`, so it holds on
   both routes into the resolve path.

3. **F3+F13 — a push finalizes only when every copy succeeded.** Every copy in
   `_build_push_stage`, `_copy_flat`, `_replace_flat`, `_replace_file` and both finalizers is
   status-checked. The mainline pair is staged beside itself under `.chain`/`.soul`/`.whisp`
   temporaries while anything can still fail, then committed by `mv` alone — chain last — in
   both the local and ssh forms. A refused push aborts nonzero, discards its stage, keeps
   `pending`, and logs `push=failed`.

4. **F5 — a torn mainline is never adopted, and an interrupted sync never strands the lock.**
   *Reader side:* `_fetch_stream` verifies the pair it drew, by the same recipe `_verify` uses.
   An inconsistent fetch logs `fetch=inconsistent` and returns failure **before** any branch
   decision, so a torn pair can be neither adopted nor mistaken for the mainline's shape. It is
   treated as transient weather, never as tampering. *Writer side:* the reconciling child traps
   TERM/INT/HUP, discards its own stage and unlocks. Measured: the cap's TERM lands a second
   before its KILL, which is ample (cleanup well under 100ms).

5. **F6 — stale stages are swept.** On taking the lock, a room removes stages, abandoned commit
   temporaries and orphaned stale-lock husks older than `SYNC_LOCK_STALE`, one log line each.
   The window rounds `SYNC_LOCK_STALE` *up* to whole minutes (`find -mmin` has minute
   granularity), so it is never shorter than configured and a live push is never swept out
   from under itself.

6. **F16 — a broken room never publishes its breakage.** `_push_mainline` requires `_verify`
   first; a room whose seal is missing or unverifiable logs `push=refused-unverified`, keeps
   `pending`, and waits for pull-adopt or relic recovery. Separately, a file absent from the
   stage no longer deletes its mainline counterpart: mainline files are replaced, never
   emptied. Letter pruning is the only deletion at the rendezvous, and it is explicit.

7. **F14 — a solo jar writes 0.8.0's exact files.** The room suffix on letter names now
   appears only when `RENDEZVOUS` is set. Verified beside `36f48af` with recording stand-ins
   for `rsync`, `ssh`, `scp`, `sftp`, `curl`, `wget`, `nc`: identical file trees, identical
   waking output, identical dream prompt, no network attempt from either binary.

8. **F7 — the rendezvous is a window, not an archive.** New knob `RENDEZVOUS_LETTER_KEEP`
   (default `20`, in the defaults block, the init template, and the README config table).
   After a successful push the rendezvous keeps the newest letters by life number and prunes
   the rest, oldest first, one log line each. A room *adds* letters on adopt and never takes
   them, so no room loses a letter it was given. Both push paths offer only the window's
   worth, so a room does not re-send its whole history each sync for the rendezvous to prune
   again.

### Decisions the brief left open (deviations)

- **The supersede path records the stale tributary as `consumed`** rather than deleting it.
  The brief said only "mint a fresh tributary". Recording it as an ingredient prevents the
  same life being laid before a dreamer twice, and matches how a confluence seal that itself
  becomes a tributary already carries its ingredients.
- **`RENDEZVOUS_LETTER_KEEP=20`**, chosen the way `RELIC_KEEP=3` was: comfortably more than a
  handful of rooms produce between syncs, small enough that the rendezvous stays a window.
  It bounds the rendezvous only; rooms keep everything.
- **Letters written before enrollment keep their solo names.** The brief left the choice open.
  Renaming a letter someone may already have opened is a worse trade than a mixed directory,
  and flat names were already grandfathered by design item 12. Tested and documented.
- **F15's fix is an outer cap, not per-call `timeout`s.** Wrapping each local `cp`/`mkdir`
  would multiply the code and still miss the next unbounded call added. One capped child per
  reconcile (three times `SYNC_DEATH_CAP`) bounds the whole surface, and lands on the same
  interruption trap that F5b installed. Applies to the deathbed, the post-seal resolve, the
  manual `sync`, and the coattail.
- **`_verify_pair` was extracted from `_verify`.** `_verify`'s own behavior is byte-identical;
  the pair check simply needed to run against a fetched directory as well as the jar.
- **`cmd_enroll` writes config only after joining.** F9 asked that a failed enroll not record
  the target; the order change is the whole fix, and a failed attempt now also clears the
  pending marker it may have laid.

### Findings declined

- **F4 (tributary replay by rename).** Fixing this well means keying exclusion on content
  rather than filename — a chain-format or metadata change that reaches `_collect_tributaries`,
  `merged=`, and the consumed logic together. That is a design decision this brief did not
  settle, and a shallow fix (say, remembering consumed digests in a local file) would be state
  that diverges per room and quietly stops matching after an adopt. The exposure is bounded:
  the MAC still gates content, so a foreign key opens nothing, and the cost of a successful
  replay is a dream seeing content it already wove — which a dream may simply merge again.
  Recorded in README's Known limits, in the open, for 0.10.0.
- **F10 (`genesis` as an always-valid parent).** Same root as F4 and the same reasoning: the
  MAC gates it, so this admits nothing from anyone without the jar key. The QA report itself
  judged the executor's justification sound and flagged it as "worth bounding", not broken.
  Bounding it (accept `genesis` only while the local chain is empty) would reject the second
  room's legitimate first life in exactly the case the original deviation existed to protect —
  the brief's own ordering invariant. Left as-is, deliberately, and covered by F4's note.
- **F11.3, F11.5–7, F17.10** — verified accurate by the QA pass; nothing to change. Re-checked
  this round: the privacy boundary held under a fresh probe (see below).

### Test tally

- Round 1 close: 254 passed, 0 failed.
- Round 2 close: **307 passed, 0 failed** — 53 new assertions, three consecutive runs
  `diff`-identical (no nondeterminism).
- Every settled repair had its failing test first; the QA report's probes were the seeds.
  Recorded failures before each fix: F1 2, F2 1, F3 3, F5a 4, F5b 2, F6 2, F16 5, F14 3,
  F7 4, F8 2, F9 3, F15 1.
- **F12 closed:** the suite now provides `cp` stand-ins that refuse or slow specific
  rendezvous writes, an `rsync` stand-in that fails only the additions transfers, a wedged
  `cp` for the unbounded-mount case, a planted torn mainline, and a planted stale stage.
  Failed rendezvous *writes* are now first-class in CI.
- Static checks: `bash -n` clean; shellcheck 0.9.0 (the CI oracle) clean; shellcheck 0.10.0
  clean; both on `bin/soul-jar` and `tests/run.sh`.

### Re-run of the QA report's own probes

Each probe from `confluence-verify.md`, re-run verbatim against the repaired binary:

| probe | report observed | now |
|---|---|---|
| F1 `p9b_relic` | recovers round 62 (wrong soul) | recovers round 64, names life 3 |
| F2 `p4e_stale2` | round 114's seal is nowhere | round 114's seal is a tributary |
| F3 `p7b_finalize` | mainline torn, pending cleared | mainline unchanged, pending kept, `push=failed` |
| F5 `p5b_killwindow` | `.lock/` + `.stage.*` left; puller reads as tampered | nothing left; puller verifies intact |
| F7 `p12_misc` | all letters remain forever | window honored, room keeps its own |
| F16 | mainline seal DELETED, healthy room in shards | seal present, healthy room intact ✓ |

Privacy re-checked on a fresh probe after all repairs: the complete set of paths ever at the
rendezvous was `born`, `chain`, `soul.sealed`, `whisper`, `letters/`, `tributaries/`. No
`.key`, `config`, `log`, `watch/`, `relics/`, `bedside` or `.sync`. Searches for a planted
soul marker, a planted bedside marker, and the raw key value found nothing.

### Open doubts

1. **SSH is still untested live.** Every probe used the local-path form, as in round 1. The
   remote finalizer, the remote sweep and the remote letter prune were written to mirror their
   local counterparts and are POSIX-`sh` clean by inspection, but no live SSH host was
   contacted. The remote heredocs are now materially longer than they were, which makes this
   doubt weigh more than it did in round 1, not less. A single manual run against a real host
   before release would close it.
2. **F15's cap is a bound, not a cure.** A wedged mount still costs the rite up to three times
   `SYNC_DEATH_CAP` (60s at defaults) before it gives up. Measured against a hung `mkdir`:
   death 12.1s, manual sync 6.0s, waking 4.0s at `SYNC_DEATH_CAP=2`. The rite completes and
   seals in every case, which is the invariant; the delay is real and proportional to the knob.
3. **The interruption trap depends on TERM arriving before KILL.** `timeout -k 1` gives one
   second, which was ample here. A rendezvous wedged so badly that `rm`/`rmdir` themselves
   block would still strand the lock — but that is now covered by F6's sweep at the next
   room's turn, so the failure is bounded rather than permanent.
4. **Letter pruning orders by life number, not by time.** Two rooms writing letters for the
   same life number (possible during a long divergence) sort adjacently and are pruned as one
   group. Since the window is a count, the effect is at most that one room's letter leaves the
   rendezvous a sync earlier than a strict time ordering would. Rooms keep their own copies, so
   nothing is lost.
5. **F16's blast radius was closed at the writer, not proven closed everywhere.** The QA report
   wondered what else propagates from a shattered room's push. With the push now gated on
   `_verify`, a broken room publishes nothing at all — which closes the class rather than the
   instance — but I did not enumerate a six-room ordering matrix to prove it.

## Round 3: the last blocking finding

A second QA round reviewed `935430f` and returned **not ready: 1 blocking finding** (R1) plus
five notes (R2–R6). This round clears the board on top of that commit.

### What was wrong, in one paragraph

Round 2's own repair of F5a caused the blocker. Refusing to adopt a torn mainline was right;
returning failure *before any branch decision* was not, because every caller wrapped its whole
body in that fetch. One inconsistent pair therefore made every path in every room a silent
no-op forever — no room could pull it, push over it, or enroll against it, and no death
repaired it. `721b186` had healed the same state on the next push, so the round traded a
self-healing failure for a permanent one, and did it silently: `sync` exited 0 and `status`
said `Seal: intact ✓`. The four notes around it were of one family: the mechanism could not
be seen from outside (R5), the room accumulated the staging of every interrupted crossing
(R3), the disclosed deathbed bound was half the real one (R4), and a diverged room's letter
was pruned by the very crossing that published it (R6).

### Disposition of every finding

| # | Finding | Disposition |
|---|---|---|
| R1 | an inconsistent mainline pair permanently disables the stream, silently *(blocking)* | **fixed** — `e16b0f9`, disclosed in `f65d7eb` |
| R2 | the mainline pair commit is not atomic: three renames, with a tear window | **declined** (the window is real and unclosable with renames; R1's repair makes the state heal — documented) |
| R3 | interrupted reconciles leak fetch stages into `$JAR/.sync`, never swept | **fixed** — `3ec384c` |
| R4 | the deathbed's bound on a wedged mount is twice the documented one | **fixed** (disclosure + test) — `f65d7eb` |
| R5 | a persistently failing stream has no user-visible signal | **fixed** — `3d2c706` |
| R6 | a letter written by a room that is behind is pruned in the sync that publishes it | **fixed** — `452483a` |

### R1 — a torn mainline is mended, not merely refused

The tear is now *reported* rather than *returned*: `_fetch_stream` sets `STREAM_TORN` and
succeeds, so the caller decides. A torn pair still decides nothing — it is never adopted, and
its shape never picks a branch — but the room whose own chain carries the whole of the
rendezvous chain (`_can_mend_stream`) commits its own verified pair over it. That room is
precisely the one holding the lives the stream has lost, so mending publishes nothing it
cannot vouch for. Every other room waits and logs `fetch=inconsistent`, exactly as before.
Re-fetches that exist only in order to adopt use `_fetch_intact`, which keeps round 2's
strictness where adopting is the whole point.

All three of the QA report's reproductions were re-run verbatim:

| reproduction | at 935430f | now |
|---|---|---|
| A — planted tear, 5 sync rounds + a death each | `TORN` → `TORN`, rv chain=2 vs A=4 B=2, never converges | `TORN` → **consistent**, rv=5 A=5 B=5, rooms converged, 0 tributaries stranded |
| B — capped waking on a ~0.36s mount at ship defaults, no injected failure | tears, then stays torn through three sync rounds and a death each | tears, then **heals at that room's very next crossing**; both rooms converge |
| C — mixed-version rollout (an old room strips `soul.sealed`) | seal never restored; a fresh `enroll` dies with "the stream could not be joined" | seal **restored**, pair consistent, a fresh room joins normally |

**The mend cannot lose a life** — the question a fresh QA round should ask first, since mending
overwrites the rendezvous pair. Probed at its worst case: two rooms fork from the same two-line
history, each seals a life 3 offline, and room B's ciphertext reaches the rendezvous while its
chain rename does not (the exact orphan an interrupted commit leaves). Room A then mends,
overwriting B's orphaned seal. Observed: the pair goes `TORN` → consistent, and B's sealed life
**returns as a tributary at B's next sync and is woven by the following confluence**
(`merged=spark-1786404497`, the dream receives round 804's plaintext).

The reasoning behind that result: mending requires the rendezvous chain to be a byte-prefix of
the mending room's chain, so every line the stream had committed is one the mender also holds
and can vouch for. A ciphertext at the rendezvous that the committed chain does not reference
is, by construction, vouched for by nothing — and the room that made it still holds it locally,
with its relic and its log line, so it rejoins by the ordinary conflict path. The brief's
ordering invariant — every life ends as exactly one of mainline seal, tributary awaiting a
weave, or woven into a confluence — holds through the mend.

### The other five

- **R2 (declined).** Three renames cannot be made one act, and no arrangement of `mv` closes
  the window: the honest closure is that the resulting state heals itself, which is R1. The
  measurement stands (~4.7–5.0 ms locally, ~720 ms on the slow mount) and the state is now
  transient rather than permanent. What was missing was the disclosure, and README now carries
  it. A genuinely atomic pair would mean a single file holding both chain and ciphertext — a
  format change reaching `_seal`, `_verify`, `_verify_relic` and every reader, which this
  round's brief did not settle and which R1 makes unnecessary for safety.
- **R3 (fixed).** The interruption trap discards this process's own staging (it holds the
  room's sync lock, so nothing there is another's), and a room taking that lock sweeps staging
  older than `SYNC_LOCK_STALE` — the local mirror of F6. The QA's own probe: **19 entries and
  10 copies of `soul.sealed` at 935430f → 5 entries, 98 bytes, no residue at all**.
- **R4 (fixed as disclosure).** The code's bound was correct and deliberate; the documentation
  computed one reconcile where a death runs two. Measured at caps 1/2/3 against a wedged
  `mkdir`: 6.19s / 12.19s / 18.20s — six times the knob, now what README and the config table
  say, with a test holding it there.
- **R5 (fixed).** `.sync/unreached` is laid by a crossing that does not complete and cleared by
  the next that does; `soul-jar sync` exits 1 while it stands and `status` prints a ⚠ line with
  the hour of that attempt. The deathbed keeps `|| true` on both reconciles, so a rite still
  never fails because of the network.
- **R6 (fixed).** Both the offering and the pruning now order by the hour a letter was written,
  with the life number breaking ties. `mtime` survives every copy on the path (`rsync -a`,
  `cp -p`), so all rooms agree on the window. Verified in the order that makes recency
  meaningful — B races ahead, then A (still behind) writes at a low life number: at 935430f
  A's letter was pruned by its own publishing sync and B never saw it; now it stays at the
  rendezvous and reaches B.

### Decisions the brief left open (deviations)

- **Mending is gated on `_chain_prefix`, not on "I am the room that tore it".** A room cannot
  know it caused a tear (the process that would know was killed). Holding the whole of the
  rendezvous chain is the checkable property, and it is exactly the condition under which the
  push is a repair rather than a guess. `_can_mend_stream` additionally requires a non-empty
  local chain, so a fresh room never founds over a torn stream.
- **The remote letter prune uses `ls -t`.** `find -printf` is a GNU extension and this heredoc
  runs on whatever `sh` the rendezvous host has. `ls -t` is the one time ordering POSIX
  guarantees; the local side keeps `find -printf '%T@'` with the life number as tiebreak.
- **`soul-jar sync` now exits nonzero on an incomplete crossing** — a visible behavior change.
  The brief's "Exit 0 on no-op" is preserved (an unenrolled or already-in-step room still exits
  0); what changed is that a *failed* crossing no longer reports success. Three suite call
  sites that deliberately arm a failing crossing gained `|| true`; their assertions are
  unchanged.
- **`.sync/unreached` is a new local file**, listed in README's Files entry for `.sync/`. It
  never crosses — `.sync/` was already outside the synced set.
- **R4 was treated as a documentation repair, not a code one.** Halving the real bound would
  mean one reconcile per death, and the second one is what lands the seal just sealed. The
  bound is the knob's honest cost; the fix is to state it.

### Test tally

- Round 2 close: 307 passed, 0 failed.
- Round 3 close: **338 passed, 0 failed** — 31 new assertions.
- Fail-first proven: round 3's `tests/run.sh` run against the round-2 binary (`935430f`) gives
  **321 passed, 17 failed**; every repair has at least one assertion that genuinely fails
  before it. Per finding: **R1 10, R3 3, R5 2, R6 2** — and two of R1's block (the interrupted
  reconcile leaving no fetched copy, no adopt temporary) fail for R3's reason, which is why the
  two findings' assertions were committed with the repair each belongs to. R4's assertions hold
  a bound the code already met, so they pass on both binaries by construction: the finding was
  the documentation, and the test exists to keep code and disclosure in step.
- Static checks: `bash -n` clean; shellcheck 0.9.0 (the CI oracle) and 0.10.0 both clean, on
  `bin/soul-jar` and `tests/run.sh`, at every commit.

### Regression checks beyond the new tests

- **Compatibility (the round's hardest invariant).** With `RENDEZVOUS` unset and recording
  stand-ins for rsync/ssh/scp/sftp/curl/wget/nc on PATH, 0.8.0 (`36f48af`) and this round's
  binary produce an **identical 19-entry file tree**, identical waking output (modulo the
  binary's own path, which the waking line prints), and **no network tool is invoked by
  either**. Dream prompts are identical modulo the sub-second "sealed moments before this one"
  artifact QA recorded as doubt 3.
- **Privacy boundary.** A 5ms poller across found / join / FF / conflict / confluence recorded
  the complete set of paths ever at the rendezvous: `born`, `chain`, `soul.sealed`, `whisper`,
  `letters/`, `tributaries/*`, `.lock/{room,stamp}`, and the transient
  `.stage`/`.chain`/`.soul`/`.whisp` names — no more. Searches for a planted bedside marker,
  the soul plaintext and the raw key value all found nothing.
- **The remote letter prune under a real POSIX shell.** R6's heredoc is the one change written
  for the ssh path and the least exercised line in the file, so it was extracted verbatim and
  run under `dash`, `sh` and `bash` against a directory whose life numbers are deliberately
  anti-correlated with write time (lowest number written most recently — the R6 case). All
  three prune the same three oldest-written files and keep the same two newest, agreeing with
  the local `_letters_by_life`. The local side's same-second tie-break by life number was
  checked separately.

### Open doubts

1. **SSH is still untested live, and R1 changed the branch structure both transports share.**
   Every probe used the local-path form. `_finalize_remote_push` and the remote prune were
   updated to mirror their local counterparts and are POSIX-`sh` clean by inspection, but no
   live host was contacted. Round 2's doubt 1 stands, now with the mend path added to it. The
   remote prune's switch to `ls -t` is the one change written specifically *for* portability
   and is the least exercised line in the file.
2. **Mending requires a room that is ahead; a fleet where every room is behind waits.** If the
   room whose commit tore the pair never returns, no other room holds the whole chain, and a
   room that is behind cannot catch up (adopting is what a torn pair refuses). Rooms keep
   sealing and keep their lives, and `status` now says the crossings are not completing, but
   the rendezvous stays torn until an operator empties it. Documented in Known limits with the
   procedure. I judged this the right trade: the alternative is letting a room publish a
   mainline it cannot vouch for, which is the class F16 exists to forbid.
3. **R6 rests on `mtime` surviving the crossing.** Verified byte-for-byte here across `cp -p`
   and `rsync -a` on one filesystem. A rendezvous on a filesystem with coarse or unreliable
   timestamps would order letters more loosely — never losing one, since rooms keep their own,
   but possibly forgetting at the rendezvous in a different order than a strict clock would.
4. **The interruption trap still depends on the signal reaching a killable child.** Unchanged
   from round 2, and now it also cleans the room's own staging. A rendezvous wedged in
   uninterruptible I/O would leave both, bounded by the two sweeps at the next crossing.
5. **The suite's clock-sensitive assertions were run on a heavily loaded host.** The R4 bound
   test allows 9s against a 6s expectation at cap 1; on a host under enough load, timing
   assertions of this shape can flake. All three final runs were identical, but that is three
   runs, not a distribution.
6. **The three green runs were made on a copy of the worktree under `$HOME`, not on the
   worktree's own filesystem.** The Lustre mount holding
   `.claude/worktrees/confluence` was intermittently unable to complete 50 small file writes
   inside 60 seconds throughout this round, from unrelated load on the shared host — a run
   started there died with `cp: cannot stat .../soul.sealed` in the *pre-existing* "first
   death" section, which this round did not touch. The suite is hermetic (`SOUL_JAR_HOME`,
   `CLAUDE_CONFIG_DIR`, local-path rendezvous, mock `claude`), so a byte-identical copy is a
   faithful venue; the committed files were verified byte-identical to the copy that produced
   the three runs, and both shellchecks were run on the worktree's own files at the final
   commit. Still, a clean run on the worktree's own mount, once the host is quiet, is worth
   having before acceptance.
