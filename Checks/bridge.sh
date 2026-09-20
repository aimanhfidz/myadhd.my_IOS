#!/bin/bash
# Compile and run Checks/bridge.swift over the app target's own sources.
#
#   Checks/bridge.sh
#
# The test that proves the widgets cannot go blank: the store as
# localStorage held it, and the same store through StoreDocument, must
# produce byte-identical widget snapshots and identical notification
# schedules. See the header of Checks/bridge.swift.
#
# There is no Xcode test target and no package: this is swiftc over the
# real MyADHD/ and Shared/ sources, so there is no second copy of
# anything to drift — except the deliberate frozen copies inside
# bridge.swift, which is the point.
#
# TaskBridge.swift compiles here because its one UIKit import was
# vestigial and is gone; WidgetKit is available on macOS and nothing in
# the run reaches WidgetCenter (packed() does the work, write() does the
# writing).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Built outside the repo on purpose. This checkout lives on an iCloud-synced
# Desktop, and the file provider keeps re-applying com.apple.quarantine to the
# folder; macOS then SIGKILLs (137) anything executed from inside it, which
# reads as a failing check rather than a blocked one. TMPDIR has no such flag.
BUILD="${BRIDGE_BUILD:-${TMPDIR:-/tmp}/myadhd-checks}"
mkdir -p "$BUILD"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -O -o "$BUILD/bridge" \
  Checks/bridge.swift \
  MyADHD/Core/JSONValue.swift \
  MyADHD/Core/WebJSON.swift \
  MyADHD/Core/JSText.swift \
  MyADHD/Core/Normalize.swift \
  MyADHD/Core/TaskItem.swift \
  MyADHD/Core/NoteItem.swift \
  MyADHD/Core/StoreDocument.swift \
  MyADHD/Bridge/ReminderPlan.swift \
  MyADHD/TaskBridge.swift \
  MyADHD/DoneLedger.swift \
  Shared/TaskSnapshot.swift || exit 2

# DoneLedger keeps its tally in UserDefaults and merge() writes as it reads.
# Both sides of every comparison see the same ledger within a run, so the
# result is deterministic either way — but a run should not leave a tally
# behind in the user's own defaults, so it gets its own HOME.
LEDGER="$BUILD/home"
rm -rf "$LEDGER"
mkdir -p "$LEDGER/Library/Preferences"

# DayKey.calendar takes the device's zone, and both the day arithmetic and
# the reminder rules turn on it. A half-hour zone and a DST zone are where a
# wrong one shows up.
bad=0
for TZ_NAME in America/New_York Asia/Kuala_Lumpur Pacific/Chatham; do
  echo
  echo "############ TZ=$TZ_NAME ############"
  rm -rf "$LEDGER/Library/Preferences"
  mkdir -p "$LEDGER/Library/Preferences"
  HOME="$LEDGER" TZ="$TZ_NAME" "$BUILD/bridge" "$ROOT/Checks/fixtures" || bad=$((bad + 1))
done

echo
if [ "$bad" -gt 0 ]; then
  echo "bridge: $bad of 3 timezone runs FAILED"
  exit 1
fi
echo "bridge: all 3 timezone runs OK"
exit 0
