#!/bin/bash
# Compile and run Checks/meetings.swift over the app target's own sources.
#
#   Checks/meetings.sh
#
# The meetings read off the phone: the local day and the local clock, the
# height a block is drawn at, the order a day is put in, the meeting that
# has become a task, and the task it becomes.
#
# This is the one check in the folder with no web original on the other
# side of it. The website cannot read a diary at all — the Google scope
# its calendar link holds is allowed to touch only the calendar it made
# itself — so there is no app.js to be held against, and what stands in
# for it is written out at the top of Checks/meetings.swift.
#
# Run in three zones, like the other date-sensitive checks. Half past
# midnight on the far side of the dateline is where a mapping that
# reached for an ISO8601 string would part company with the store's own
# day key, and it would be right in Europe while being wrong here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Built outside the repo: this checkout is on an iCloud-synced Desktop and
# the file provider keeps re-applying com.apple.quarantine, after which
# macOS SIGKILLs (137) anything run from inside it. That reads as a failing
# check when it is a blocked one.
BUILD="${MEETINGS_BUILD:-${TMPDIR:-/tmp}/myadhd-checks}"
mkdir -p "$BUILD"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# -wmo for the reason storefile.sh gives: Checks/meetings.swift sits beside
# the app's own MyADHD/Core/Meetings.swift, and on a case-insensitive
# filesystem the second object file lands on the first and takes the entry
# point with it.
xcrun swiftc -O -wmo -o "$BUILD/meetings" \
  Checks/meetings.swift \
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
  MyADHD/Core/Meetings.swift \
  Shared/TaskSnapshot.swift

status=0
for zone in Asia/Kuala_Lumpur UTC America/Los_Angeles; do
  echo
  echo "=== TZ=$zone ==="
  TZ="$zone" "$BUILD/meetings" || status=1
done

echo
if [ "$status" -eq 0 ]; then
  echo "meetings: all 3 zones clean"
else
  echo "meetings: FAILED"
fi
exit "$status"
