#!/bin/sh
# ============================================================
# tools/release/bump.sh — the next build, and a What's New to write for it
#
#   tools/release/bump.sh            build number + 1, same version
#   tools/release/bump.sh 1.1        build number + 1, version 1.1
#
# Moves CURRENT_PROJECT_VERSION (and MARKETING_VERSION, when given) in
# every target at once — an extension must match its app or the upload is
# rejected — and opens an empty "## <version> (<build>)" entry at the top
# of WHATSNEW.md. Empty on purpose: the build phase warns on every build
# and refuses to archive until somebody writes what changed. The commits
# since WHATSNEW.md last moved are printed to write it from.
#
# Edits two files and commits nothing. Stage the hunks yourself.
# ============================================================

set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
pbx="$root/MyADHD.xcodeproj/project.pbxproj"
notes="$root/WHATSNEW.md"

builds=$(grep -o 'CURRENT_PROJECT_VERSION = [0-9]*;' "$pbx" | sort -u)
versions=$(grep -o 'MARKETING_VERSION = [0-9.]*;' "$pbx" | sort -u)
if [ "$(printf '%s\n' "$builds" | wc -l)" -ne 1 ] || [ "$(printf '%s\n' "$versions" | wc -l)" -ne 1 ]; then
    echo "The targets disagree — fix this by hand first:" >&2
    printf '%s\n%s\n' "$builds" "$versions" >&2
    exit 1
fi

old_build=$(printf '%s' "$builds" | tr -dc 0-9)
old_version=$(printf '%s' "$versions" | sed 's/MARKETING_VERSION = //; s/;//')
new_build=$((old_build + 1))
new_version=${1:-$old_version}

case $new_version in
    *[!0-9.]*|.*|*.|*..*|'') echo "\"$new_version\" is not a version like 1.1" >&2; exit 1 ;;
esac

sed -i '' "s/CURRENT_PROJECT_VERSION = $old_build;/CURRENT_PROJECT_VERSION = $new_build;/" "$pbx"
sed -i '' "s/MARKETING_VERSION = $old_version;/MARKETING_VERSION = $new_version;/" "$pbx"

# The new entry goes above the first existing one, under the preamble.
tmp=$(mktemp)
awk -v head="## $new_version ($new_build)" '
    !done && /^## / { print head; print "Uploaded: no"; print ""; done = 1 }
    { print }
    END { if (!done) { print ""; print head; print "Uploaded: no" } }
' "$notes" > "$tmp"
cat "$tmp" > "$notes"
rm -f "$tmp"

echo "$old_version ($old_build) → $new_version ($new_build), in every target."
echo
echo "Write what changed under \"## $new_version ($new_build)\" in WHATSNEW.md."
echo "Commits since it last moved:"
since=$(git -C "$root" log -1 --format=%H -- WHATSNEW.md 2>/dev/null || true)
if [ -n "$since" ]; then
    git -C "$root" log --oneline --no-merges "$since..HEAD"
else
    git -C "$root" log --oneline --no-merges -20
fi
