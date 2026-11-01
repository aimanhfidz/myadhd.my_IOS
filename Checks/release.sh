#!/bin/bash
# Is this build ready to upload, as far as the version and What's New go?
#
#   Checks/release.sh
#
# Four things, all of them about App Store Connect rather than about the
# web app:
#
#   1. Every target carries the same MARKETING_VERSION and
#      CURRENT_PROJECT_VERSION — an extension that differs from its app is
#      rejected on upload.
#   2. WHATSNEW.md has a ready entry for exactly that version and build
#      (tools/release/whatsnew.sh --strict; Guideline 2.3.12).
#   3. The MyADHD target still runs that script as a build phase, so the
#      rule is held on every build and not only when somebody remembers
#      this check.
#   4. The script itself still catches what it says it catches: each
#      failure below is written to a scratch file and must be refused,
#      and a good entry must pass.
#
# Scripts are run as `sh <file>` throughout, never executed directly —
# the same reason the Xcode phase does it (see Checks/README.md).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PBX=MyADHD.xcodeproj/project.pbxproj
WN=tools/release/whatsnew.sh

pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

# 1. the targets agree ------------------------------------------------
builds=$(grep -o 'CURRENT_PROJECT_VERSION = [0-9]*;' "$PBX" | sort -u)
versions=$(grep -o 'MARKETING_VERSION = [0-9.]*;' "$PBX" | sort -u)
[ "$(wc -l <<<"$builds")" -eq 1 ] && ok || bad "targets disagree on the build number: $(tr '\n' ' ' <<<"$builds")"
[ "$(wc -l <<<"$versions")" -eq 1 ] && ok || bad "targets disagree on the version: $(tr '\n' ' ' <<<"$versions")"
build=$(tr -dc 0-9 <<<"$(head -1 <<<"$builds")")
version=$(head -1 <<<"$versions" | sed 's/MARKETING_VERSION = //; s/;//')

# 2. the real entry ---------------------------------------------------
if out=$(sh "$WN" --strict "$version" "$build" </dev/null); then ok
else bad "WHATSNEW.md is not ready for $version ($build):"; echo "$out"; fi

# 3. the build phase --------------------------------------------------
grep -q 'name = "What'"'"'s New";' "$PBX" && ok || bad "the MyADHD target has no \"What's New\" build phase"
grep -q 'tools/release/whatsnew.sh' "$PBX" && ok || bad "the build phase does not run tools/release/whatsnew.sh"
grep -q '1A0000000000000000000060 /\* What'"'"'s New \*/,' "$PBX" && ok || bad "the \"What's New\" phase is not in the MyADHD target's buildPhases"

# 4. the script refuses what it should --------------------------------
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

expect() { # expect <refuse|pass> <label> <build> <file body>
    printf '%s' "$4" > "$scratch/w.md"
    WHATSNEW_FILE="$scratch/w.md" sh "$WN" --strict 1.0 "$3" </dev/null >/dev/null 2>&1
    got=$?
    if [ "$1" = refuse ]; then [ $got -ne 0 ] && ok || bad "accepted: $2"
    else [ $got -eq 0 ] && ok || bad "refused: $2"; fi
}

good=$'# x\n\n## 1.0 (5)\nUploaded: no\n\nThe matrix widget now has a tick on every row.\n'
expect pass   "a good entry"                         5 "$good"
expect refuse "no entry for this build"              6 "$good"
expect refuse "an entry with no text"                5 $'## 1.0 (5)\nUploaded: no\n\n'
expect refuse "no Uploaded line"                     5 $'## 1.0 (5)\n\nReal words here.\n'
expect refuse "only bug fixes and performance"       5 $'## 1.0 (5)\nUploaded: no\n\nBug fixes and performance improvements.\n'
expect refuse "only improvements"                    5 $'## 1.0 (5)\nUploaded: no\n\nImprovements.\n'
expect refuse "a TODO left in"                       5 $'## 1.0 (5)\nUploaded: no\n\nTODO: write this.\n'
expect refuse "this build already uploaded"          5 $'## 1.0 (5)\nUploaded: 2026-11-01\n\nReal words here.\n'
expect refuse "a build below an uploaded one"        4 $'## 1.0 (5)\nUploaded: 2026-11-01\n\nOld.\n\n## 1.0 (4)\nUploaded: no\n\nNew words.\n'
expect refuse "one build number on two versions"     5 $'## 1.1 (5)\nUploaded: no\n\nA.\n\n## 1.0 (5)\nUploaded: no\n\nB.\n'
expect refuse "a heading in the wrong shape"         5 $'## 1.0 build 5\nUploaded: no\n\nWords.\n'
expect refuse "over 4,000 characters"                5 "$(printf '## 1.0 (5)\nUploaded: no\n\n%04001d\n' 0)"
expect pass   "above an uploaded build"              6 $'## 1.0 (6)\nUploaded: no\n\nNew words.\n\n## 1.0 (5)\nUploaded: 2026-11-01\n\nOld.\n'
expect pass   "bug fixes, said with substance"       5 $'## 1.0 (5)\nUploaded: no\n\nBug fixes: a widget tick no longer comes undone.\n'

echo "release: $pass passed, $fail failed ($version ($build))"
[ "$fail" -eq 0 ]
