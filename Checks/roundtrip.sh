#!/bin/bash
# Compile and run Checks/roundtrip.swift over the app target's own sources,
# then cross-check every re-encoded store against node.
#
#   Checks/roundtrip.sh
#
# There is no Xcode test target and no package: this is swiftc over
# MyADHD/Core/*.swift plus Shared/TaskSnapshot.swift, which is how the app
# compiles them too, so there is no second copy of anything to drift.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Built outside the repo on purpose. This checkout lives on an iCloud-synced
# Desktop, and the file provider keeps re-applying com.apple.quarantine to the
# folder; macOS then SIGKILLs (137) anything executed from inside it, which
# reads as a failing check rather than a blocked one. TMPDIR has no such flag.
BUILD="${ROUNDTRIP_BUILD:-${TMPDIR:-/tmp}/myadhd-checks}"
OUT="$BUILD/out"
NODE="${NODE:-$HOME/.local/node/bin/node}"
mkdir -p "$BUILD"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -O -o "$BUILD/roundtrip" \
  Checks/roundtrip.swift \
  MyADHD/Core/JSONValue.swift \
  MyADHD/Core/WebJSON.swift \
  MyADHD/Core/JSText.swift \
  MyADHD/Core/Normalize.swift \
  MyADHD/Core/TaskItem.swift \
  MyADHD/Core/NoteItem.swift \
  MyADHD/Core/StoreDocument.swift \
  Shared/TaskSnapshot.swift

"$BUILD/roundtrip" Checks/fixtures --out "$OUT"

if [ -x "$NODE" ]; then
  echo
  "$NODE" -e '
    const fs = require("fs"), path = require("path");
    const [fixtures, out] = process.argv.slice(1);
    // load() migrates these two on purpose; the rest must come back untouched.
    const migrates = new Set(["legacy-notes.json"]);
    let bad = 0;
    const deep = (a, b, at) => {
      if (a === b) return true;
      if (typeof a !== typeof b || a === null || b === null || typeof a !== "object") {
        console.log(`  FAIL  ${at}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`); return false;
      }
      const ka = Object.keys(a), kb = Object.keys(b);
      if (ka.join("\u0000") !== kb.join("\u0000")) {
        console.log(`  FAIL  ${at}: key order ${ka} vs ${kb}`); return false;
      }
      return ka.every(k => deep(a[k], b[k], `${at}.${k}`));
    };
    for (const f of fs.readdirSync(fixtures).filter(f => f.endsWith(".json"))) {
      const src = fs.readFileSync(path.join(fixtures, f), "utf8");
      const dst = fs.readFileSync(path.join(out, f), "utf8");
      const a = JSON.parse(src), b = JSON.parse(dst);
      // the fixtures must themselves be canonical JSON.stringify output
      if (JSON.stringify(a) !== src) { console.log(`  FAIL  ${f}: fixture is not canonical`); bad++; }
      if (JSON.stringify(b) !== dst) { console.log(`  FAIL  ${f}: output is not canonical`); bad++; }
      if (migrates.has(f)) { console.log(`  skip  ${f} (load() migrates it)`); continue; }
      if (deep(a, b, f)) console.log(`  ok    ${f} deep-equal, key order intact`); else bad++;
    }
    console.log(bad ? `\nnode cross-check: ${bad} failed` : "\nnode cross-check OK");
    process.exit(bad ? 1 : 0);
  ' Checks/fixtures "$OUT"
else
  echo
  echo "node not at $NODE — skipping the cross-check"
fi
