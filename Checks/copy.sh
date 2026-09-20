#!/bin/bash
#
# Checks/copy.sh — copy is the product, so prove it was copied.
#
# Pulls every string literal out of MyADHD/Core/Copy.swift and greps each
# one back against the web app's own sources. A paraphrase, a straightened
# em-dash, a dropped full stop or a capitalisation slip fails the run and
# gets named.
#
# Haystack:
#   My.adhd/app.js
#   My.adhd/app.html          (HTML entities decoded first: &#39; is an
#                              apostrophe on screen, not four characters)
#   myadhd.my_IOS/MyADHD/BridgeScript.swift
#                             (the native titles the shell already draws)
#   My.adhd/theme.js          (the one pair of strings app.html cannot
#                              carry: the theme toggle relabels itself)
#
# Two normalisations, both of which only make matching looser, never
# wrong:
#   - the haystack is flattened to one line and its runs of whitespace
#     squeezed to single spaces, because app.html wraps a paragraph over
#     four indented lines and the string on screen has none of that;
#   - the same squeeze is applied to each needle.
#
# Where the web builds a line out of parts, Copy.swift reproduces the
# construction as a function; this script splits such a literal on its
# interpolations and checks each fragment separately. That is why every
# interpolation in Copy.swift holds a bare identifier and nothing else.
#
# Fragments that are empty, or nothing but ASCII whitespace and
# punctuation, are skipped — there is no sense asserting that a full stop
# appears in app.js.
#
# Usage:  Checks/copy.sh [path-to-My.adhd]
# Exit:   0 every literal found, 1 otherwise.

set -u
export LC_ALL=C

IOS_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WEB_ROOT=${1:-"$(dirname "$IOS_ROOT")/My.adhd"}

COPY="$IOS_ROOT/MyADHD/Core/Copy.swift"
BRIDGE="$IOS_ROOT/MyADHD/BridgeScript.swift"
APP_JS="$WEB_ROOT/app.js"
APP_HTML="$WEB_ROOT/app.html"
THEME_JS="$WEB_ROOT/theme.js"

for f in "$COPY" "$BRIDGE" "$APP_JS" "$APP_HTML" "$THEME_JS"; do
  if [ ! -f "$f" ]; then
    echo "copy.sh: missing $f" >&2
    echo "copy.sh: pass the My.adhd checkout as the first argument" >&2
    exit 2
  fi
done

WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT

HAY="$WORK/haystack.txt"
FRAGS="$WORK/fragments.txt"

# ---- the haystack -----------------------------------------------------
# Decode the handful of HTML entities app.html actually uses, then flatten.
# &amp; is decoded last so &amp;#39; cannot turn into an apostrophe.
cat "$APP_JS" "$APP_HTML" "$THEME_JS" "$BRIDGE" \
  | sed -e "s/&#39;/'/g" \
        -e 's/&quot;/"/g' \
        -e 's/&times;/\xc3\x97/g' \
        -e 's/&lt;/</g' \
        -e 's/&gt;/>/g' \
        -e 's/&amp;/\&/g' \
  | tr '\n\t' '  ' \
  | tr -s ' ' > "$HAY"

# ---- the needles ------------------------------------------------------
# 1. every double-quoted run in Copy.swift, escapes included
# 2. drop the surrounding quotes
# 3. cut each literal at its interpolations, one fragment per line
# 4. unescape \" and \\
grep -oE '"([^"\\]|\\.)*"' "$COPY" \
  | sed -e 's/^"//' -e 's/"$//' \
  | sed -e 's/\\([A-Za-z_][A-Za-z0-9_]*)/\n/g' \
  | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g' \
  | tr -s ' ' > "$FRAGS"

checked=0
skipped=0
missing=0

while IFS= read -r frag; do
  # nothing to assert about whitespace and ASCII punctuation
  case "$frag" in
    '') skipped=$((skipped + 1)); continue ;;
  esac
  if printf '%s' "$frag" | grep -qE '^[[:space:][:punct:]]*$'; then
    skipped=$((skipped + 1))
    continue
  fi

  checked=$((checked + 1))
  if ! grep -qF -- "$frag" "$HAY"; then
    missing=$((missing + 1))
    printf 'NOT IN THE WEB APP: [%s]\n' "$frag"
  fi
done < "$FRAGS"

echo "---"
echo "checked $checked fragments, skipped $skipped, missing $missing"

if [ "$missing" -gt 0 ]; then
  echo "copy.sh FAILED — the lines above are not in app.js, app.html or BridgeScript.swift."
  echo "Copy is the product: go and find the real string rather than rewording this one."
  exit 1
fi

echo "copy.sh OK — every literal in Copy.swift is the web app's own."
exit 0
