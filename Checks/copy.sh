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
#   My.adhd/cloud.js          (the sync phases and their error sentences)
#   My.adhd/auth.js           (signing in, and what it says when it cannot)
#   My.adhd/gcal.js           (the calendar link's own errors)
#   My.adhd/voice.js          (the mic's hints)
#   My.adhd/config.js
#
# The last five arrived with the port itself: the app used to be app.js and
# a page, so app.js was the whole of the copy. Now that the account card,
# the calendar link and the mic are Swift, the sentences they say are in
# the modules that said them. A needle sourced from cloud.js was failing
# here for no better reason than that this list had not caught up.
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
# One block is exempt, by name: Copy.Meetings. The app reads the meetings
# already on the phone through EventKit, which is a thing the website
# cannot do at all — the scope its Google link holds is allowed to touch
# only the calendar it made itself — so there is no web original to grep
# and no paraphrase to catch. Every fragment of it is listed below and
# every other literal in Copy.swift is still checked exactly as strictly.
#
# NOTHING GOES IN THAT LIST THAT HAS AN ORIGINAL. The point of this check
# is that copy cannot be reworded quietly; an exemption granted to a
# string the web app does say would turn it off for that string for ever.
# Adding a line here should feel like a decision, and it should come with
# the reason the website has no counterpart.

# Usage:  Checks/copy.sh [path-to-My.adhd]
# Exit:   0 every literal found, 1 otherwise.

set -u
export LC_ALL=C

IOS_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WEB_ROOT=${1:-"$(dirname "$IOS_ROOT")/My.adhd"}

COPY="$IOS_ROOT/MyADHD/Core/Copy.swift"
# Retired from the build at the cutover, kept as the spec for the screens
# that came out of it — see reference/README.md.
BRIDGE="$IOS_ROOT/reference/BridgeScript.swift"
APP_JS="$WEB_ROOT/app.js"
APP_HTML="$WEB_ROOT/app.html"
THEME_JS="$WEB_ROOT/theme.js"
CLOUD_JS="$WEB_ROOT/cloud.js"
AUTH_JS="$WEB_ROOT/auth.js"
GCAL_JS="$WEB_ROOT/gcal.js"
VOICE_JS="$WEB_ROOT/voice.js"
CONFIG_JS="$WEB_ROOT/config.js"

for f in "$COPY" "$BRIDGE" "$APP_JS" "$APP_HTML" "$THEME_JS" \
         "$CLOUD_JS" "$AUTH_JS" "$GCAL_JS" "$VOICE_JS" "$CONFIG_JS"; do
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
    "$CLOUD_JS" "$AUTH_JS" "$GCAL_JS" "$VOICE_JS" "$CONFIG_JS" \
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

trim() { printf '%s' "$1" | sed -e 's/^ *//' -e 's/ *$//'; }

NATIVE="$WORK/native-only.txt"
#
# The last five are not whole sentences: they are the pieces
# Copy.Meetings.readNote is built from, split at its interpolations the
# way the loop below splits every other function. Write them without
# their edge spaces — the match trims both sides, for the reason given
# where it happens.
cat > "$NATIVE" <<'NATIVE_ONLY'
Show my meetings
Meetings already on this phone show up beside your tasks.
my.adhd cannot see your calendar. iOS only asks once, so Settings is the way back.
Open Settings
Make this a task
All day
Reading
1 calendar
1 meeting
meetings
in the next 60 days.
NATIVE_ONLY

checked=0
skipped=0
native=0
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

  # Copy.Meetings — no web original exists. See the note at the top.
  #
  # Matched with the edge spaces ignored on both sides. A fragment that
  # sits between two interpolations necessarily begins and ends with one,
  # and a trailing space on a line of the block above does not survive an
  # editor that strips it — which is a silent failure of this file rather
  # than of the copy. The space still matters to the sentence; it just
  # cannot be asserted here. Looser, never wrong, like the two
  # normalisations at the top.
  if grep -qxF -- "$(trim "$frag")" "$NATIVE"; then
    native=$((native + 1))
    continue
  fi

  checked=$((checked + 1))
  if ! grep -qF -- "$frag" "$HAY"; then
    missing=$((missing + 1))
    printf 'NOT IN THE WEB APP: [%s]\n' "$frag"
  fi
done < "$FRAGS"

echo "---"
echo "checked $checked fragments, skipped $skipped, native-only $native, missing $missing"

if [ "$missing" -gt 0 ]; then
  echo "copy.sh FAILED — the lines above are in none of the web app's sources."
  echo "Copy is the product: go and find the real string rather than rewording this one."
  exit 1
fi

echo "copy.sh OK — every literal in Copy.swift is the web app's own."
exit 0
