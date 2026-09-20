# Checks

Five scripts. None of them is a unit test in the usual sense — there is no
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
for c in roundtrip copy parity-triage parity-ordering bridge; do
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
