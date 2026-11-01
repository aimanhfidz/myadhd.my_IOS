#!/bin/bash
# Compile and run Checks/calendar.swift against the real app.js.
#
#   Checks/calendar.sh [path-to-My.adhd]
#
# The calendar push: which tasks go on Google Calendar, the signature that
# says an event is still right, and the event built from a task. The
# signature travels between devices on `gcal.sig`, so this build and the
# web disagreeing about it would have them rewrite each other's events
# for ever.
#
# Run in three zones. `eventBody` builds local wall-clock stamps, and the
# New York run carries two cases across its DST changes.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WEB_ROOT="${1:-$(dirname "$ROOT")/My.adhd}"
# Built outside the repo: this checkout is on an iCloud-synced Desktop and
# the file provider keeps re-applying com.apple.quarantine, after which
# macOS SIGKILLs (137) anything run from inside it.
BUILD="${CALENDAR_BUILD:-${TMPDIR:-/tmp}/myadhd-checks}"
mkdir -p "$BUILD"

if [ ! -f "$WEB_ROOT/js/app.js" ]; then
  echo "calendar.sh: no app.js under $WEB_ROOT" >&2
  exit 2
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# -wmo for the reason storefile.sh gives: one module, one object, so a
# check named like an app file cannot overwrite it on this filesystem.
xcrun swiftc -O -wmo -o "$BUILD/calendar" \
  Checks/calendar.swift \
  MyADHD/Core/JSONValue.swift \
  MyADHD/Core/WebJSON.swift \
  MyADHD/Core/JSText.swift \
  MyADHD/Core/Normalize.swift \
  MyADHD/Core/TaskItem.swift \
  MyADHD/Core/NoteItem.swift \
  MyADHD/Core/StoreDocument.swift \
  MyADHD/Core/WebDates.swift \
  MyADHD/Core/Copy.swift \
  MyADHD/Core/CalendarPush.swift \
  Shared/TaskSnapshot.swift \
  -framework JavaScriptCore || exit 2

bad=0
for TZ_NAME in America/New_York Asia/Kuala_Lumpur Pacific/Chatham; do
  echo
  echo "=== TZ=$TZ_NAME ==="
  TZ="$TZ_NAME" "$BUILD/calendar" "$WEB_ROOT" || bad=$((bad + 1))
done

echo
if [ "$bad" -gt 0 ]; then
  echo "calendar: $bad of 3 timezone runs FAILED"
  exit 1
fi
echo "calendar: all 3 timezone runs OK"
