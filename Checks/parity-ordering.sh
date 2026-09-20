#!/bin/bash
# Compile and run Checks/parity-ordering.swift against the real app.js.
#
#   Checks/parity-ordering.sh [path-to-My.adhd]
#
# swiftc over MyADHD/Core/*.swift plus Shared/TaskSnapshot.swift — the
# same sources the app compiles, so there is no second copy of anything —
# linked against JavaScriptCore, which evaluates the DOM-free slices of
# app.js itself.
#
# The run is repeated under three timezones. Nothing in Ordering.swift
# formats a date, but `dayKey()` and `new Date()` both read TZ, and a
# half-hour zone and a DST zone are where a wrong one shows up.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WEB_ROOT="${1:-$(dirname "$ROOT")/My.adhd}"
# Set PARITY_BUILD to put the binary somewhere else. An agent sandbox that
# refuses to execute anything under the repo's own path (SIGKILL on launch,
# the same way Checks/roundtrip.sh is refused) needs this pointed at its
# scratch directory.
# Built outside the repo on purpose. This checkout lives on an iCloud-synced
# Desktop, and the file provider keeps re-applying com.apple.quarantine to the
# folder; macOS then SIGKILLs (137) anything executed from inside it, which
# reads as a failing check rather than a blocked one. TMPDIR has no such flag.
BUILD="${PARITY_BUILD:-${TMPDIR:-/tmp}/myadhd-checks}"
mkdir -p "$BUILD"

if [ ! -f "$WEB_ROOT/app.js" ]; then
  echo "parity-ordering.sh: no app.js under $WEB_ROOT" >&2
  echo "parity-ordering.sh: pass the My.adhd checkout as the first argument" >&2
  exit 2
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -O -o "$BUILD/parity-ordering" \
  Checks/parity-ordering.swift \
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
  Shared/TaskSnapshot.swift \
  -framework JavaScriptCore || exit 2

bad=0
for TZ_NAME in America/New_York Asia/Kuala_Lumpur Pacific/Chatham; do
  echo
  echo "=== TZ=$TZ_NAME ==="
  TZ="$TZ_NAME" "$BUILD/parity-ordering" "$WEB_ROOT" || bad=$((bad + 1))
done

echo
if [ "$bad" -gt 0 ]; then
  echo "parity-ordering: $bad of 3 timezone runs FAILED"
  exit 1
fi
echo "parity-ordering: all 3 timezone runs OK"
exit 0
