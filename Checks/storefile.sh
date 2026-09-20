#!/bin/bash
# Compile and run Checks/storefile.swift over the app target's own sources.
#
#   Checks/storefile.sh
#
# The persistence rules, against a real directory: an atomic replacement
# that a racing reader never catches half-done, the rotation to the .bak,
# the quarantine that is never written over, and the coalescing of a burst
# of writes. See the header of Checks/storefile.swift.
#
# Nothing here needs app.js — localStorage had none of these rules. What
# it is held against is design §2.4 and the filesystem.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Built outside the repo on purpose. This checkout lives on an iCloud-synced
# Desktop, and the file provider keeps re-applying com.apple.quarantine to the
# folder; macOS then SIGKILLs (137) anything executed from inside it, which
# reads as a failing check rather than a blocked one. TMPDIR has no such flag.
#
# The scratch directories the run makes are under $TMPDIR for the same
# reason, and because a few of them are chmod-ed to 0 and 0500 on purpose.
BUILD="${STOREFILE_BUILD:-${TMPDIR:-/tmp}/myadhd-checks}"
mkdir -p "$BUILD"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# -wmo, and not for speed: without it the driver names each object file after
# its input basename, and this check is `storefile.swift` beside the app's own
# `StoreFile.swift`. On a case-insensitive filesystem the second object lands on
# the first, the entry point goes with it, and the link fails with an
# undefined `_main` that has nothing to do with the code. One module, one
# object, no collision.
xcrun swiftc -O -wmo -o "$BUILD/storefile" \
  Checks/storefile.swift \
  MyADHD/Core/JSONValue.swift \
  MyADHD/Core/WebJSON.swift \
  MyADHD/Core/JSText.swift \
  MyADHD/Core/Normalize.swift \
  MyADHD/Core/TaskItem.swift \
  MyADHD/Core/NoteItem.swift \
  MyADHD/Core/StoreDocument.swift \
  MyADHD/Core/StoreFile.swift \
  Shared/TaskSnapshot.swift

"$BUILD/storefile"
