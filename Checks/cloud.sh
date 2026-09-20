#!/bin/bash
# Compile and run Checks/cloud.swift against the real cloud.js.
#
#   Checks/cloud.sh [path/to/cloud.js]
#
# The sync, held against its source: `sigOf` byte for byte over 220 task
# fixtures, the two copies of `sigOf` (CloudBook's and LegacyImport's)
# against each other, `stamp`, and the `merge`/`outbound` decision tables
# replayed out of the real cloud.js in JavaScriptCore over 48
# row-and-local combinations. Then the wire — a URLProtocol stub asserting
# the exact PostgREST paths, headers and array bodies — and the
# microsecond test, that PostgREST's six fractional digits parse to the
# same millisecond `Date.parse` gives.
#
# See the header of Checks/cloud.swift for what each section proves and
# why it is the one that stands between a rename and somebody's task
# disappearing on their other phone.
#
# One time zone per process, as the other parity scripts do: nothing in
# the sync formats a local date, but `toISOString` and `Date.parse` both
# read the process zone through the C library, and a run that only ever
# happened in UTC would not notice a port that reached for a local
# formatter.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLOUDJS="${1:-/Users/User/Desktop/Claude Code/My.adhd/cloud.js}"

# Built outside the repo on purpose. This checkout lives on an iCloud-synced
# Desktop, and the file provider keeps re-applying com.apple.quarantine to the
# folder; macOS then SIGKILLs (137) anything executed from inside it, which
# reads as a failing check rather than a blocked one. TMPDIR has no such flag.
BUILD="${CLOUD_BUILD:-${TMPDIR:-/tmp}/myadhd-checks}"
mkdir -p "$BUILD"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# -wmo for the same reason storefile.sh and migration.sh pass it: without it
# the driver names each object file after its input basename, and this check
# is `cloud.swift` beside the app's own `CloudSync.swift`/`CloudBook.swift`.
# One module, one object, no collision.
#
# LegacyImport.swift is in the list although nothing in the sync calls it:
# it carries the second copy of `sigOf`, and section 2 is the assertion that
# the two agree. It brings AppStore and StoreFile with it, which section 4
# needs anyway.
xcrun swiftc -O -wmo -o "$BUILD/cloud" \
  Checks/cloud.swift \
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
  MyADHD/Core/Reachability.swift \
  MyADHD/Sync/CloudBook.swift \
  MyADHD/Sync/Session.swift \
  MyADHD/Sync/Supabase.swift \
  MyADHD/Sync/CloudSync.swift \
  MyADHD/Bridge/LegacyImport.swift \
  MyADHD/Bridge/LegacyStorageFile.swift \
  Shared/TaskSnapshot.swift

# tz                  epoch ms         what it is
runs=(
  "Asia/Kuala_Lumpur  1789000000000    +08, no DST ever — the control"
  "America/New_York   1789000000000    a zone with an offset and a DST rule"
  "UTC                1789000000000    the zone the server is in"
)

bad=0
for run in "${runs[@]}"; do
  read -r tz ms _ <<<"$run"
  echo
  if ! "$BUILD/cloud" --tz "$tz" --now "$ms" --cloud-js "$CLOUDJS"; then
    bad=$((bad + 1))
  fi
done

echo
if [ "$bad" -eq 0 ]; then
  echo "cloud: all ${#runs[@]} zones clean"
else
  echo "cloud: $bad of ${#runs[@]} zones had divergences"
fi
exit "$bad"
