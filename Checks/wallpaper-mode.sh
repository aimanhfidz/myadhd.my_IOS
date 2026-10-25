#!/bin/bash
# Compile and run Checks/wallpaper-mode.swift over the app target's own sources.
#
#   Checks/wallpaper-mode.sh
#
# When the lock-screen shortcut may stop before Set Wallpaper Photo. There
# is no web original on the other side: what it is held to is written at
# the top of the .swift.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Built outside the repo, for the quarantine reason meetings.sh gives.
BUILD="${WALLPAPER_MODE_BUILD:-${TMPDIR:-/tmp}/myadhd-checks}"
mkdir -p "$BUILD"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -O -wmo -parse-as-library -o "$BUILD/wallpaper-mode" \
  Checks/wallpaper-mode.swift \
  MyADHD/WallpaperMode.swift \
  MyADHD/WallpaperView.swift \
  MyADHD/WallpaperHealth.swift

"$BUILD/wallpaper-mode"
