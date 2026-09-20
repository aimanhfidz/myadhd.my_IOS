#!/bin/bash
# Compile and run Checks/parity-triage.swift against the real app.js,
# at three pinned instants in three time zones.
#
#   Checks/parity-triage.sh [path/to/app.js]
#
# One time zone per process on purpose: DayKey.calendar captures the
# current zone the first time it is touched and keeps it, so a loop
# inside the program would test one zone three times.
#
# The three runs, and why each one is here:
#
#   1  Asia/Kuala_Lumpur, a Monday afternoon. No DST ever, which makes
#      it the control: every difference the other two show is a zone
#      rule and not a parser rule.
#   2  Europe/London, the evening the clocks go forward. addDays()
#      crosses the boundary, the bare-time rule compares an instant
#      against a wall clock that is about to skip an hour, and
#      "in 1 days" has 23 real hours in it.
#   3  America/New_York, New Year's Eve. Every "in N days", every
#      weekday roll-over and every "9 march" resolves across the year
#      boundary, which is the one place normalizeDay and parseDay can
#      disagree about which year they are in.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APPJS="${1:-/Users/User/Desktop/Claude Code/My.adhd/app.js}"
# Built outside the repo: on this machine a binary executed from the
# Desktop tree is killed before main() runs, and a scratch directory is
# the one place both a person and an agent can run it from.
# Built outside the repo on purpose. This checkout lives on an iCloud-synced
# Desktop, and the file provider keeps re-applying com.apple.quarantine to the
# folder; macOS then SIGKILLs (137) anything executed from inside it, which
# reads as a failing check rather than a blocked one. TMPDIR has no such flag.
BUILD="${PARITY_BUILD:-${TMPDIR:-/tmp}/myadhd-checks}"
mkdir -p "$BUILD"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -O -o "$BUILD/parity-triage" \
  Checks/parity-triage.swift \
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
  MyADHD/Triage/JSRegex.swift \
  MyADHD/Triage/LocalTriage.swift \
  MyADHD/Triage/Preview.swift \
  Shared/TaskSnapshot.swift

# tz                  epoch ms         what it is
runs=(
  "Asia/Kuala_Lumpur  1773039600000    Mon 2026-03-09 15:00 +08"
  "Europe/London      1774744200000    Sun 2026-03-29 00:30 GMT, 30 min before BST"
  "America/New_York   1767224700000    Wed 2025-12-31 18:45 EST"
)

bad=0
for run in "${runs[@]}"; do
  read -r tz ms _ <<<"$run"
  echo
  if ! "$BUILD/parity-triage" --tz "$tz" --now "$ms" --app-js "$APPJS"; then
    bad=$((bad + 1))
  fi
done

echo
if [ "$bad" -eq 0 ]; then
  echo "parity-triage: all three runs clean"
else
  echo "parity-triage: $bad of ${#runs[@]} runs had divergences"
fi
exit "$bad"
