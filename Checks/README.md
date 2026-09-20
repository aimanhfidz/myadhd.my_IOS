# Checks

Ten scripts. None of them is a unit test in the usual sense — there is no
Xcode test target and no package here. Each one compiles the **real**
`MyADHD/` and `Shared/` sources with `swiftc`, the same files the app target
compiles, and then holds their answers against something outside the port:
the web app's own JavaScript, the web app's own strings, or the bytes the
old WKWebView shell used to write.

That is the whole point. A native rewrite of a web app has no compiler error
to catch a rule that was ported slightly wrong, and no widget on somebody's
home screen will say so either — it will just draw a blank day. These
scripts are the thing that says so.

Run them all:

```sh
cd "/Users/User/Desktop/Claude Code/myadhd.my_IOS"
for c in roundtrip copy parity-triage parity-ordering bridge store storefile migration wav cloud; do
  ./Checks/$c.sh || echo "FAILED: $c"
done
```

Each exits 0 on success and non-zero with the divergence named.

---

## Where they build, and why not here

Every script builds its binary under `$TMPDIR`, not inside the repo. This
checkout lives on an iCloud-synced Desktop; the file provider keeps
re-applying `com.apple.quarantine` to the folder, and macOS then SIGKILLs
(137) anything executed from inside it. That reads as a failing check when
it is really a blocked one. Override with `ROUNDTRIP_BUILD`, `PARITY_BUILD`
or `BRIDGE_BUILD` if you need it somewhere specific.

`DEVELOPER_DIR` defaults to `/Applications/Xcode.app/Contents/Developer`,
because `xcode-select` on this machine points elsewhere.

`storefile.sh`, `migration.sh` and `wav.sh` also pass `-wmo`, and not for speed. Without
it the driver names each object file after its input's basename, and
`Checks/storefile.swift` sits beside the app's own `MyADHD/Core/StoreFile.swift`
— on a case-insensitive filesystem the second object lands on the first, takes
the entry point with it, and the link fails with an undefined `_main` that has
nothing to do with the code. One module, one object, no collision. Worth
knowing before naming the next check after the file it checks.

---

## `roundtrip.sh` — the store survives a read and a write

```sh
./Checks/roundtrip.sh
```

**Proves:** `StoreDocument.load()` followed by re-encoding gives back byte
-identical JSON — same values, same key order, same `null`s written rather
than omitted, same unknown keys carried through untouched.

Reads each fixture in `Checks/fixtures/`, loads it through the real
`StoreDocument`, writes it back out, and compares. Then, if node is at
`~/.local/node/bin/node`, it re-checks every output with `JSON.parse` /
`JSON.stringify` — which also asserts that each file is canonical
`JSON.stringify` output in the first place, so `WebJSON` is being held
against the real encoder and not against itself.

`legacy-notes.json` is skipped in the deep-equal pass because `load()`
migrates it on purpose; it is still required to come back as canonical JSON.

**Last run:** 172 checks, 0 failed; node cross-check OK.

---

## `copy.sh` — every user-facing string is the web app's own

```sh
./Checks/copy.sh [path-to-My.adhd]
```

**Proves:** no string in `MyADHD/Core/Copy.swift` was paraphrased. Copy is
the product, so this greps every literal back against the web sources —
`app.js`, `app.html` (HTML entities decoded first), `theme.js`, and
`BridgeScript.swift` for the native titles the shell already draws.

A straightened em-dash, a dropped full stop, a capitalisation slip or a
reworded line fails the run and is printed. Where the web builds a line out
of parts, `Copy.swift` reproduces the construction as a function and the
script checks each fragment either side of the interpolation separately —
which is why every interpolation in `Copy.swift` holds a bare identifier and
nothing else. Fragments that are only whitespace and ASCII punctuation are
skipped.

Defaults to `../My.adhd`; pass the checkout if it lives elsewhere.

**Last run:** 191 fragments checked, 19 skipped, 0 missing.

---

## `parity-triage.sh` — the offline parser reads a dump the way app.js does

```sh
./Checks/parity-triage.sh [path/to/app.js]
```

**Proves:** `LocalTriage` and `DatePreview` return exactly what the web's own
parser returns, over a 374-dump corpus — the split into fragments, each
task's title and fields, the day and time parsed out of it, the preview
chips, and `knownNames()`.

It loads three DOM-free slices of the **real** `app.js` into JavaScriptCore
and runs both sides on the same input. Nothing is reimplemented or
paraphrased for comparison.

Three runs, one time zone each — one zone per process, because
`DayKey.calendar` captures the zone the first time it is touched and keeps
it, so a loop inside the program would test one zone three times:

| Zone | Instant | Why |
|---|---|---|
| `Asia/Kuala_Lumpur` | Mon 2026-03-09 15:00 +08 | No DST ever — the control. Every difference the other two show is a zone rule, not a parser rule. |
| `Europe/London` | Sun 2026-03-29 00:30 GMT | 30 minutes before BST. `addDays()` crosses the boundary and "in 1 days" has 23 real hours in it. |
| `America/New_York` | Wed 2025-12-31 18:45 EST | New Year's Eve: every "in N days", weekday roll-over and "9 march" resolves across the year boundary. |

The slices are cut by line number **and anchored by content** — each one must
still contain the functions it is supposed to hold (`parseDay`,
`parseClock`, `normalizeTask`, `splitDump`, `previewDates`, `knownNames`).
Without the anchors a line range silently slides onto whatever moved into it
and the run can report a clean pass on code that is no longer under test.
Verified by shifting a scratch copy of `app.js` down 40 lines: the run fails
naming the missing anchor.

**Last run:** all three zones clean — 374/374 dumps, 408 fragments, 408
tasks (198 with a day, 61 with a time), 198 chips, 23/23 name lists.

---

## `parity-ordering.sh` — the lists come out in app.js's order

```sh
./Checks/parity-ordering.sh [path-to-My.adhd]
```

**Proves:** `Ordering` — `dueAt`, `bucketOf`, both sort comparators,
`bucketize`, `quadrantOf`, `quadrantize`, `catKey`, `groupByCategory`,
`tasksOn`, `overdueTasks`, `homeToday`, `stats` — agrees with `app.js` task
for task, including sort *stability*, which is the part a rewrite usually
loses.

Same method: DOM-free slices of the real `app.js` in JavaScriptCore. Here the
slices are anchored by content from the start, and `dayKey` is frozen after
loading so both sides read one clock.

Repeated under three zones — `America/New_York`, `Asia/Kuala_Lumpur`,
`Pacific/Chatham` (a 12:45 offset). Nothing in `Ordering.swift` formats a
date, but `dayKey()` and `new Date()` both read `TZ`.

Corpora, each at seven pinned "today"s (both US DST switches, two year
boundaries, a leap-adjacent end of February, an ordinary midsummer day):

- **wide / dense / tiny** — 120, 40 and 3 tasks, each with a block of rows
  that tie on every sort key, which is the only way to see whether the sort
  is stable.
- **junk** — the same, plus a `when` that is not a date and an `at` with two
  colons. Both make `dueAt` answer `NaN`, and a `NaN` row makes app.js's
  *own* comparator inconsistent: it ties with everything while two dated
  rows compare by deadline, so `a < b` and `b < c` stop implying `a < c`.
  What a sort does with an inconsistent comparator is the sort algorithm's
  business, not the comparator's — JavaScriptCore's merge sort and Swift's
  introsort disagree and neither is wrong. So this corpus is compared on
  everything that **is** defined (`dueAt` itself, `bucketOf`, `catKey`,
  `tasksOn`, `overdueTasks`) and the comparator-ordered lists are excluded.

  Do not "fix" that exclusion by asserting a sort order here. It would be
  asserting unspecified behaviour, and it fails the moment either engine
  changes its sort.

The two-colon time is in the junk corpus specifically to pin
`at.replace(':', '')` — a *string* needle, so JavaScript drops the **first**
colon only. Replacing every colon turns a `NaN` into a real instant and
files an undated task into the day.

**Last run:** all 3 zones OK — 741 comparisons each, all matched `app.js`.

---

## `bridge.sh` — the widgets cannot go blank

```sh
./Checks/bridge.sh
```

**Proves:** the store as `localStorage` held it, and the same store read
through `StoreDocument`, produce **byte-identical** widget snapshots and
identical notification schedules. This is the check that stands behind the
promises list in the repo README: the widgets and the wallpaper pick task
fields out by name, and nothing else in the build fails when one is renamed.

Compares the real `TaskBridge` / `ReminderPlanner` output against frozen
copies of what the old shell produced — the one deliberate second copy in
the Checks tree, which is the point of it.

Four instants per zone, across three zones
(`America/New_York`, `Asia/Kuala_Lumpur`, `Pacific/Chatham`): 08:00 before
the default reminder hour, 14:00 inside the rescue window, 22:00 past the
quiet hour, and a year boundary.

Each run gets its own `HOME`, because `DoneLedger` keeps its tally in
`UserDefaults` and `merge()` writes as it reads — a run must not leave a
tally behind in the real user's defaults.

**Last run:** all 3 zones OK — 48 comparisons each, 0 failed.

---

## `store.sh` — every mutation does what app.js's does

```sh
./Checks/store.sh [path/to/app.js]
```

**Proves:** each of `AppStore`'s mutations leaves the same document behind,
byte for byte, as the same mutation in the real `app.js` — and schedules the
same things. `markDone`, `undoDone`, `removeTask`/`undoRemove`, `clearAll`,
`editTitle`, `breakDown`'s apply, `setQuadrant`, the view toggle,
`applyTriage`, `settleForOffline`, `applyResort`, `pruneDone`,
`stampTimeOnly`, the note life cycle and `touchNote`, the profile name and
avatar, `signupOfferHidden`, `sentFeedbackOn`, and `save()` versus
`persistOnly()`.

One seed store goes into both sides — a temp `myadhd.v1.json` read through
`AppStore`'s boot path, and `localStorage` read through app.js's own `load()`
— and then each side runs the same mutation. Two things are compared:
`JSON.stringify(state)` against `AppStore.doc.jsonString`, and the **trail**:
which of `cloud.stamp()`, the write, `syncSoon()` and `cloud.soon()` ran, in
order.

Every rule is cut out of `app.js` by content, never retyped. Most are whole
functions; six are statement runs inside a DOM handler, cut by their first and
last line and wrapped in a function header written in the check — listed by
name and line in the file's header.

Three zones, and the instants are chosen so the LOCAL day and the UTC day are
different strings: `pruneDone` counts on the local one and `sentFeedbackOn` is
the UTC one, and a check that had them the wrong way round could not pass.

Two divergences are deliberate and are pinned rather than hidden — the check
names each one and asserts the exact shape of it:

- a key the page appends where the assignment lands (`doneAt` on a row that
  never had one) goes in `normalizeTask`'s place here (design §2.5). Same
  values, one key in a different position — and the reason `LegacyImport`
  reseals the cloud sigs rather than copying the page's.
- a cap landing inside a surrogate pair: the page keeps the orphaned half and
  a Swift `String` cannot hold one, so `Normalize.slice` takes one unit less
  (Normalize.swift:53-56). The check asserts the native text is the page's
  *less exactly that half*.
- `saveRemind`/`clearRemind` write twice on the web (`touchNote()` then
  `save()`); `saveNote` folds them into one. Both trails are written down, so
  the check fails if either moves.

**Last run:** all three zones clean — 472 comparisons each.

---

## `storefile.sh` — the document on disk

```sh
./Checks/storefile.sh
```

**Proves:** design §2.4's persistence rules, against a real directory.

- **Atomic replacement.** A reader running flat out beside a writer: 400
  documents of 400 different lengths written while another loop reads the file
  as fast as it can. Every read has to parse *and* be one of the documents that
  was actually written. A `write(to:)` without the rename fails this in
  a few hundred reads.
- **One rotation behind.** The previous document goes to `myadhd.v1.bak.json`
  before the new bytes land, and it is the previous one, not one of a burst.
- **Quarantine, never overwrite.** A document that will not parse is moved to
  `myadhd.v1.corrupt-<stamp>.json` with the bytes verbatim; a second corrupt
  document in the same millisecond gets the next free name; nothing ever writes
  over either.
- **Coalescing.** The queue is suspended, three documents are handed over, and
  the *backup* proves only one write was performed.

Plus two failure modes: an **unreadable** file (a phone not unlocked since a
reboot) must not be quarantined — it is a good document that will read fine
later — and a write that fails must leave the document already there alone.

**Last run:** 47 checks, all passed. 2,239 reads raced 400 writes; none torn.

---

## `migration.sh` — the existing user, brought across for real

```sh
./Checks/migration.sh
```

**Proves:** `LegacyImport` — the file itself, compiled for the Mac — against a
real `WKWebView` on the real `https://myadhd.my` origin, with real
`localStorage`, a real keychain and real files. No network: the document is the
string `<html></html>` and the base URL only decides the origin.

The import: tasks, notes, profile, `view: 'matrix'`, unknown top-level and
unknown task keys, the theme into `myadhd.ground`, the calendar view into
`myadhd.native.calView`, the cloud book's `user` and `graves`, the Google link
trimmed to two fields, the Supabase session into the keychain. Nothing written
back to `localStorage` — all six keys are read again afterwards and compared.

And the assertion the cloud story hangs on: **the sigs are resealed from the
native encoding, not restamped.** After the import the check runs `stamp()`'s
own comparison (`sigOf(task) != book.sigs[id]`) over every task and requires it
to move nothing, and asserts every `updatedAt` is the millisecond the page had.
A copied book would have restamped two of the three fixture rows — the ones
saved before `importance`/`skipped`/`gcal`/`local`/`doneAt` existed — and
last-write-wins would then have pushed this phone's stale copy over another
device's real edit.

**The null-read guard, both directions**, which is what the file is careful
about:

| | localStorage | UserDefaults stamp | keychain snapshot | must |
|---|---|---|---|---|
| App Store update | kept | kept | kept | import, or hold if the read fails |
| delete + reinstall | **gone** | **gone** | **kept** | mark migrated, open the empty app |
| never installed | none | none | none | mark migrated, open the empty app |

iOS keeps keychain items when an app is deleted, so `myadhd.task.snapshot`
outlives the data it was vouching for. While it was a witness, a reinstalling
person's app held on `Bringing your lists over…` behind a `Try again` that
could not ever succeed — every launch, for ever. `oldShellLeftTraces` now
reads one witness, `myadhd.snapshot.stamp`, which lives in the same container
as the WebKit storage and dies with it. The keychain is still read into the
reason line of a hold that something else decided, where it cannot decide
anything.

Restoring the two-witness version fails exactly three checks in the case named
`the keychain alone is not a trace`, which is how that case earns its keep.

**Not covered:** the two branches that need the read itself to fail — a
JavaScript evaluation error and the 12-second timeout. Both land in the same
`settle(read: nil, failed:)` the empty-read cases exercise, but the
`holding` -with-no-trace branch is only reachable through them and there is no
way to force either from outside the class.

**What the run touches and puts back:** a throwaway `UserDefaults` suite, a
temp directory, the six `myadhd` keys on that origin, and two keychain items
(`myadhd.task.snapshot`, `myadhd.auth.session`) — all removed on the way out.
Nothing in the repo is written.

**Last run:** 63 checks, all passed.

---

## `wav.sh` — the recording is the same file the web would have sent

```sh
./Checks/wav.sh [path/to/voice.js]
```

**Proves:** `WAV.encode`, `WAV.resample` and `WAV.heardAnything` — the app's
own `MyADHD/Voice/WAV.swift`, compiled for the Mac — against the real
`voice.js` running in a `JSContext`. Four slices are cut out of that file by
line number every run and anchored by content: `RATE` (54), `resample`
(222-234), `toWav` (240-262) and `heardAnything` (278-285).

Two seconds of synthetic 440 Hz at 48 kHz goes through both sides. The header
is then read back field by field — RIFF / WAVE / `fmt ` / PCM / mono / 16 kHz
/ 32000 bytes per second / block align 2 / 16 bits / a `data` size of 64000 —
and every one of the 64044 bytes is compared with what `voice.js` wrote from
the identical `Float32` samples. Seven more cases cover the fractional ratio a
44.1 kHz input gives, the identity path, full-scale clipping, a ramp through
±1.2 (the clamp and the asymmetric 0x8000-down / 0x7fff-up scale), exactly ±1,
an input too short to make one output frame, and silence.

Then the floor: `heardAnything` over digital silence, a 1e-6 tap, a 0.008 hold
in a pocket, exactly 0.01, 0.0101, a quiet-but-real 0.05, a negative-only
signal and an empty buffer — each required to agree with `voice.js` *and* with
the answer written down here. Near-silence is a tapped button or a hold in a
pocket, and paying for a round trip to be told so is the one cost this saves.

Finally, that the floor is actually in the upload path. `VoiceRecorder` needs
`AVAudioSession` and cannot be built for a Mac, so its guard is read rather
than run: `stop()` must contain exactly one call to `WAV.encode`, the floor
must appear above it, and there must be a `return` in between. Agreeing about
a rule nothing obeys would be the easiest way for this check to pass and the
app to still upload silence.

Why the writer and the two sample rules live in `WAV.swift` and not beside the
engine: it is the only file in `Voice/` that builds for a Mac at all.
`VoiceRecorder` is `AVAudioSession`, and `TranscribeClient` reaches
`AppConfig`, which is UIKit. A writer that could only be built for the phone
would be a writer nobody could check.

**Last run:** 35 checks, all passed. 8 files compared byte for byte.

---

## `cloud.sh` — the sync cannot lose a task

```sh
./Checks/cloud.sh [path/to/cloud.js]
```

**Proves:** `CloudBook`, `CloudSync` and `Supabase` decide what
`cloud.js` decides — the signature, the stamp, the merge, what goes up,
and the bytes on the wire.

This is the most data-sensitive check in the tree. A conflict rule ported
slightly wrong fails no build and reddens no test: it deletes somebody's
task on their other phone, or resurrects one they threw away, weeks later.
So every rule is **cut out of the real `cloud.js` by content** — anchored
on the lines that carry it, so a rename fails the run by name rather than
sliding onto whatever moved into a line range — and run in JavaScriptCore
beside the Swift.

Seven sections:

1. **`sigOf`, byte for byte**, over 220 task fixtures: unicode titles,
   emoji that straddle surrogate pairs, quotes and backslashes, control
   characters, null fields, `gcal` refs, unknown keys, rows with and
   without `updatedAt`. Plus the two properties on their own — that
   `s.length` counts UTF-16 code units (a surrogate pair is two), and that
   `updatedAt` is not part of the hash.

2. **The two copies of `sigOf` agree.** `LegacyImport` carries its own
   (LegacyImport.swift:464) because the migration launch reseals the book
   before anything in `MyADHD/Sync` is alive. If those two ever drift, the
   first pass after an upgrade restamps every row and pushes this phone's
   stale copy over another device's real edit — the exact failure the
   reseal exists to prevent, and nothing but this assertion stops it.

3. **`stamp`**, over 9 cases: the sig unchanged, the sig moved, a row with
   no timestamp at all, a stamp already in the future, an id that
   disappeared, a grave at the TTL and a grave past it, and a grave dug up
   by an undo.

4. **`merge` and `outbound`, replayed** over 48 row-and-local
   combinations — 192 comparisons of the merged list, the book and the
   upsert body. Remote-deleted on `<=`, on `==` and on `>`; an arrival
   with no grave, with an older one, with one at the same millisecond and
   with a newer one; in-place replacement on strict `>` and the refusal on
   `==`; a tombstone pushed and one skipped because the server already has
   it; an unknown payload key carried through untouched; a payload that is
   `null`; a row with no `deleted` key; the same id held twice locally.

5. **The wire**, through a `URLProtocol` stub: the exact PostgREST paths,
   `apikey` **and** `Bearer`, `Prefer:
   resolution=merge-duplicates,return=minimal`, an ARRAY body compared
   byte for byte, the assertion that the pull **never** sends a `user_id`
   filter while every pushed row carries one, and that a status becomes
   cloud.js's own `the server answered N`.

6. **The microsecond test.** PostgREST renders `updated_at` with six
   fractional digits and `Date.parse` keeps three, **truncating**. A
   millisecond decides `rts > mine.updatedAt`, and that decides which
   device's edit survives — so `.789999` and `.789000` must be the same
   instant, and `toISOString` must round trip.

7. **The liveness rule** — the one thing in this file that is not a port.
   A transport failure and a 5xx keep the session; a 400, 401, 403 or 422
   from `/auth/v1/token` ends it; a live session answers from the record
   without asking anybody; and two callers arriving together make one
   refresh, not two. auth.js:159-165 drops the session in every one of
   those cases (design §4, decision 7), which is a sign-out on a train.

Three zones (`Asia/Kuala_Lumpur`, `America/New_York`, `UTC`) because
`toISOString` and `Date.parse` both read the process zone through the C
library, and a run that only ever happened in UTC would not notice a port
that reached for a local formatter.

**Not covered:** live sign-in. `myadhd://auth` is not on Supabase's
redirect allow-list yet and the `tasks` table's RLS policies are
unverified — both dashboard work (design §4, decision 14). Everything
below the fragment is tested; the redirect itself is not, and cannot be
from here.

**Last run:** all 3 zones clean — 748 checks each, 0 failed.

---

## Fixtures

`Checks/fixtures/` holds five stores, all canonical `JSON.stringify` output:

| File | What it is for |
|---|---|
| `fresh.json` | A new, empty store. |
| `pre-importance.json` | A store written before the `importance` field existed. |
| `unknown-keys.json` | Keys this build has never heard of, which must round-trip verbatim. |
| `legacy-notes.json` | The old notes shape; `load()` migrates it on purpose. |
| `emoji-marks.json` | Notes whose marks straddle surrogate pairs. |

`bridge.sh` additionally builds a 64-task `synthetic.json` in memory.

---

## If a check fails

Fix the code, not the check. These scripts are held against the web app
because the web app is the specification — if Swift and `app.js` disagree,
`app.js` is right by definition, however odd its answer looks.

The one legitimate reason to change a check is that it is asserting
something JavaScript does not actually define (see the junk corpus above),
or that a slice's line numbers have drifted and the anchors are telling you
to re-cut them. Never widen a tolerance or drop a case to get to green.
