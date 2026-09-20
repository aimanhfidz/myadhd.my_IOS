#!/bin/bash
# Compile and run Checks/migration.swift — the real LegacyImport, against a
# real WKWebView on the real https://myadhd.my origin.
#
#   Checks/migration.sh
#
# The riskiest code in the project: the migration gets one chance per
# person. See the header of Checks/migration.swift for what it proves and
# for the table of which traces survive an update and which survive a
# delete-and-reinstall.
#
# No network is involved. The document is the string "<html></html>" and
# the base URL only decides the origin, which is what makes the person's
# own localStorage readable.
#
# What the run touches and puts back: a throwaway UserDefaults suite (removed
# at the end), a temp directory for the store and the sidecars, the six
# myadhd localStorage keys on that origin (cleared at the end), and two
# keychain items — myadhd.task.snapshot and myadhd.auth.session — which are
# what the code under test reads, and which are deleted on the way out.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Built outside the repo on purpose. This checkout lives on an iCloud-synced
# Desktop, and the file provider keeps re-applying com.apple.quarantine to the
# folder; macOS then SIGKILLs (137) anything executed from inside it, which
# reads as a failing check rather than a blocked one. TMPDIR has no such flag.
BUILD="${MIGRATION_BUILD:-${TMPDIR:-/tmp}/myadhd-checks}"
mkdir -p "$BUILD"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# -wmo, and not for speed: without it the driver names each object file after
# its input basename, and a check named the same as an app source (ignoring
# case) silently overwrites that source's object — taking the entry point with
# it and failing the link with an undefined _main. One module, one object.
xcrun swiftc -O -wmo -o "$BUILD/migration" \
  Checks/migration.swift \
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
  MyADHD/Bridge/LegacyImport.swift \
  MyADHD/Bridge/LegacyStorageFile.swift \
  Shared/TaskSnapshot.swift

"$BUILD/migration"
