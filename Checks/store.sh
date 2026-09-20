#!/bin/bash
# Compile and run Checks/store.swift against the real app.js, at three
# pinned instants in three time zones.
#
#   Checks/store.sh [path/to/app.js]
#
# Every AppStore mutation, seeded from the same bytes on both sides and
# compared as whole documents — plus the trail of what save() poked and
# what persistOnly() did not. See the header of Checks/store.swift.
#
# One time zone per process on purpose: DayKey.calendar captures the
# current zone the first time it is touched and keeps it, so a loop
# inside the program would test one zone three times.
#
# The three runs, and why each one is here:
#
#   1  Asia/Kuala_Lumpur, 01:30 local on the 10th — 17:30 UTC on the
#      9th. The local day and the UTC day are DIFFERENT strings, so a
#      pruneDone that counted on UTC, or a sentFeedbackOn that stamped
#      the local day, cannot pass.
#   2  America/New_York, 21:30 local on the 8th — 02:30 UTC on the 9th.
#      The same straddle from the other side of the line, so a rule that
#      was merely off by one in one direction shows up here.
#   3  Pacific/Chatham, a 12:45 offset, midsummer. Nothing about a
#      quarter-hour zone should matter to a store, and this is what says
#      so.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APPJS="${1:-/Users/User/Desktop/Claude Code/My.adhd/app.js}"

# Built outside the repo on purpose. This checkout lives on an iCloud-synced
# Desktop, and the file provider keeps re-applying com.apple.quarantine to the
# folder; macOS then SIGKILLs (137) anything executed from inside it, which
# reads as a failing check rather than a blocked one. TMPDIR has no such flag.
BUILD="${STORE_BUILD:-${TMPDIR:-/tmp}/myadhd-checks}"
mkdir -p "$BUILD"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -O -o "$BUILD/store" \
  Checks/store.swift \
  MyADHD/Core/JSONValue.swift \
  MyADHD/Core/WebJSON.swift \
  MyADHD/Core/JSText.swift \
  MyADHD/Core/Normalize.swift \
  MyADHD/Core/TaskItem.swift \
  MyADHD/Core/NoteItem.swift \
  MyADHD/Core/StoreDocument.swift \
  MyADHD/Core/WebDates.swift \
  MyADHD/Core/Copy.swift \
  MyADHD/Core/Ordering.swift \
  MyADHD/Core/StoreFile.swift \
  MyADHD/Core/AppStore.swift \
  Shared/TaskSnapshot.swift

# tz                  epoch ms         what it is
runs=(
  "Asia/Kuala_Lumpur  1773077400000    Tue 2026-03-10 01:30 +08 — 2026-03-09 UTC"
  "America/New_York   1773023400000    Sun 2026-03-08 21:30 EST — 2026-03-09 UTC"
  "Pacific/Chatham    1781955900000    Sun 2026-06-21 00:30 +12:45 — 2026-06-20 UTC"
)

bad=0
for run in "${runs[@]}"; do
  read -r tz ms _ <<<"$run"
  echo
  echo "############ TZ=$tz ############"
  if ! "$BUILD/store" --tz "$tz" --now "$ms" --app-js "$APPJS"; then
    bad=$((bad + 1))
  fi
done

echo
if [ "$bad" -eq 0 ]; then
  echo "store: all ${#runs[@]} runs clean"
  exit 0
fi
echo "store: $bad of ${#runs[@]} runs had divergences"
exit 1
