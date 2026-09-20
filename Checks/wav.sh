#!/bin/bash
# Compile and run Checks/wav.swift against the real voice.js.
#
#   Checks/wav.sh [path/to/voice.js]
#
# One file of the app target — MyADHD/Voice/WAV.swift — compiled exactly
# as the app compiles it, so there is no second copy of the writer to
# drift. It is the only file in Voice/ that can be built for a Mac at
# all: VoiceRecorder needs AVAudioSession, and TranscribeClient reaches
# AppConfig, which is UIKit. That is why the writer and the two sample
# rules live in WAV.swift rather than beside the engine.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VOICEJS="${1:-/Users/User/Desktop/Claude Code/My.adhd/voice.js}"

# Built outside the repo on purpose. This checkout lives on an iCloud-synced
# Desktop, and the file provider keeps re-applying com.apple.quarantine to the
# folder; macOS then SIGKILLs (137) anything executed from inside it, which
# reads as a failing check rather than a blocked one. TMPDIR has no such flag.
BUILD="${WAV_BUILD:-${TMPDIR:-/tmp}/myadhd-checks}"
mkdir -p "$BUILD"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# -wmo for the same reason storefile.sh uses it: Checks/wav.swift sits
# beside the app's own MyADHD/Voice/WAV.swift, and on a case-insensitive
# filesystem the second object file lands on the first and takes the
# entry point with it. One module, one object, no collision.
xcrun swiftc -O -wmo -o "$BUILD/wav" \
  Checks/wav.swift \
  MyADHD/Voice/WAV.swift

"$BUILD/wav" --voice-js "$VOICEJS" --recorder MyADHD/Voice/VoiceRecorder.swift
