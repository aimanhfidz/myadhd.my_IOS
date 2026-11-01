#!/bin/sh
# ============================================================
# tools/release/whatsnew.sh — is WHATSNEW.md ready for this build?
#
#   whatsnew.sh [--strict] <MARKETING_VERSION> <CURRENT_PROJECT_VERSION>
#
# Run by the MyADHD target's "What's New" build phase on every build,
# with --strict when archiving (ACTION=install), and by
# Checks/release.sh. Without --strict every problem is a warning and it
# exits 0, so ⌘R is never blocked; with it they are errors and the
# archive stops before anything reaches App Store Connect.
#
# What it holds, and why:
#
#   - An entry "## <version> (<build>)" exists for this exact build.
#     Guideline 2.3.12: an update's What's New must describe what changed,
#     so every build that could be uploaded carries its own text.
#   - The text is there, real, and fits: not empty, no TODO/TBD/lorem,
#     not only "bug fixes and performance improvements", and under the
#     4,000 characters App Store Connect accepts (counted in bytes, which
#     is never fewer).
#   - The build has not been uploaded already, and is above every build
#     that has. App Store Connect refuses a build number it has seen, for
#     ever, including ones that were rejected.
#   - No build number is used by two entries.
#
# WHATSNEW_FILE overrides the file, for Checks/release.sh's self-test.
# ============================================================

set -u

here=$(cd "$(dirname "$0")/../.." && pwd)
file=${WHATSNEW_FILE:-"$here/WHATSNEW.md"}

strict=0
if [ "${1:-}" = "--strict" ]; then strict=1; shift; fi
version=${1:-}
build=${2:-}

level=warning
[ "$strict" = 1 ] && level=error

report() {
    # Xcode shows "error: …" / "warning: …" lines in the issue navigator.
    printf '%s\n' "$1" | while IFS= read -r line; do
        [ -n "$line" ] && printf '%s: WHATSNEW.md: %s\n' "$level" "$line"
    done
    [ "$strict" = 1 ] && exit 1
    exit 0
}

[ -n "$version" ] && [ -n "$build" ] || report "usage: whatsnew.sh [--strict] <version> <build>"
case $build in *[!0-9]*) report "build \"$build\" is not a whole number" ;; esac
[ -f "$file" ] || report "missing — every build needs its What's New entry ($file)"

problems=$(awk -v want_v="$version" -v want_b="$build" '
function trim(s) { sub(/^[ \t\n]+/, "", s); sub(/[ \t\n]+$/, "", s); return s }
function close_entry() { if (key != "") texts[key] = trim(body) }

/^## / {
    close_entry()
    line = $0; sub(/[ \t]+$/, "", line)
    if (line !~ /^## [0-9]+(\.[0-9]+)* \([0-9]+\)$/) {
        print "heading \"" line "\" is not \"## <version> (<build>)\""
        key = ""; next
    }
    v = $2; b = $3; gsub(/[()]/, "", b)
    key = v " (" b ")"
    if (key in seen) print "\"" key "\" appears twice"
    seen[key] = 1
    if ((b in buildv) && buildv[b] != v) print "build " b " is used by both " buildv[b] " and " v
    buildv[b] = v
    up[key] = ""; body = ""
    next
}
key != "" && up[key] == "" && /^Uploaded:/ {
    u = $0; sub(/^Uploaded:[ \t]*/, "", u); u = trim(u)
    up[key] = (u == "" ? "no" : u)
    if (up[key] != "no" && b + 0 > maxup) maxup = b + 0
    next
}
key != "" { body = body $0 "\n" }

END {
    close_entry()
    for (k in seen) if (up[k] == "") print "\"" k "\" has no \"Uploaded:\" line (write \"Uploaded: no\" until it is)"

    want = want_v " (" want_b ")"
    if (!(want in seen)) {
        print "no entry for " want " — add \"## " want "\", then \"Uploaded: no\", then the text App Store Connect will show"
        exit
    }
    t = texts[want]
    if (t == "") { print want " has no text — say what changed in this build (Guideline 2.3.12)"; exit }
    if (length(t) > 4000) print want " is " length(t) " bytes; App Store Connect takes 4,000 characters"

    low = tolower(t)
    if (low ~ /(^|[^a-z])(todo|tbd|lorem)([^a-z]|$)/ || low ~ /xxx/) print want " still has a placeholder (TODO / TBD / lorem / xxx)"

    g = low; gsub(/[^a-z ]/, " ", g); gsub(/ +/, " ", g); g = trim(g)
    if (g ~ /^(minor )?(bug ?fixes|fixes)( and (minor )?(performance|stability) improvements)?$/ || g ~ /^((performance|stability) )?improvements$/)
        print want " says only \"" t "\" — Guideline 2.3.12 wants what actually changed"

    if (up[want] != "no" && up[want] != "") print "build " want_b " was already uploaded (" up[want] ") — run tools/release/bump.sh for the next one"
    else if (want_b + 0 <= maxup) print "build " want_b " is not above build " maxup ", which was already uploaded — run tools/release/bump.sh"
}
' "$file")

[ -n "$problems" ] && report "$problems"
exit 0
