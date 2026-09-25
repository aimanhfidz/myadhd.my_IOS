#!/bin/bash
# Compile and run Checks/nudges.swift over the app target's own sources.
#
#   Checks/nudges.sh
#
# What rings besides a dated task: the nudges a few times a day, the bell
# on a note, and how the three kinds share iOS's 64 pending slots. The
# website sends no notifications, so there is no app.js on the other side
# of this one — what it is held to is written at the top of the .swift.
#
# Run in three zones, like the other date-sensitive checks: every slot is
# a local clock time on a local day.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Built outside the repo, for the quarantine reason meetings.sh gives.
BUILD="${NUDGES_BUILD:-${TMPDIR:-/tmp}/myadhd-checks}"
mkdir -p "$BUILD"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -O -wmo -o "$BUILD/nudges" \
  Checks/nudges.swift \
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
  MyADHD/Bridge/ReminderPlan.swift \
  MyADHD/Bridge/NudgePlan.swift \
  MyADHD/Bridge/NoteReminderPlan.swift \
  Shared/TaskSnapshot.swift

status=0
for zone in Asia/Kuala_Lumpur UTC America/Los_Angeles; do
  echo
  echo "=== TZ=$zone ==="
  TZ="$zone" "$BUILD/nudges" || status=1
done

echo
if [ "$status" -eq 0 ]; then
  echo "nudges: all 3 zones clean"
else
  echo "nudges: FAILED"
fi
exit "$status"
