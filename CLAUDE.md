# my.adhd — iOS

The native SwiftUI app for [myadhd.my](https://myadhd.my). Read **`README.md`**
first — it has the full picture: how the app is put together, how to build and
sign on a device, the keychain handover, the widgets and the wallpaper, and
where the App Store submission stands. This file is standing rules for working
in here.

**It is not a web view.** It was one until 2026-09-20 (`f72814c`, "the app is
Swift now"); every screen is SwiftUI under `MyADHD/UI/`, the store is a JSON
file on the phone, and nothing loads a page. The one `import WebKit` left is
`Bridge/LegacyImport.swift`, a fallback for reading an old shell's
`localStorage` on a first launch. If a comment or a doc in here still talks
about "the page", "the shell" or `evaluateJavaScript`, it is out of date —
believe the code.

## The other repo

The web app is **[aimanhfidz/my.adhd](https://github.com/aimanhfidz/my.adhd)**,
and it is not in this checkout. It used to be: this directory was `ios/` inside
it until the two were split. Its files are not here to edit, so *"no web-app
file is edited to make an iOS feature work"* is a fact about the filesystem.

The two are one product, and they meet in three places:

- **The store's shape.** `myadhd.v1.json` holds exactly the bytes
  `JSON.stringify(state)` would have put in the web's `localStorage`, and
  `CloudSync` meets the browsers through the same Supabase rows. A field
  renamed over there is a field this app silently stops understanding.
- **The rules, ported line for line.** `AppStore`, `Ordering`, `LocalTriage`,
  `CloudSync`, `CalendarSync` and the copy cite the `app.js` / `cloud.js` /
  `gcal.js` lines they came from, and `Checks/` holds them to the web's own
  sources. A rule changed on the web is a rule this app still runs the old way
  until somebody ports it.
- **The server.** `/api/triage`, `/api/transcribe`, `/api/feedback`,
  `/api/link-google`, `/api/gcal-token`, `/api/gcal-calendar` and
  `/api/delete-account` on myadhd.my, and Supabase's auth and `tasks` table.

**If an iOS change looks like it needs the website or the server changed, stop
and ask.** Say what the change would be and why it cannot be done from here.
It is a pull request against a different repository, which is exactly the
amount of friction that decision deserves.

`README.md` lists what this app is quietly depending on over there. Read them
there rather than trusting a summary — no count is given on purpose.

## Brand

**The canonical brand guideline is `BRAND.md` in the web repo**
(`../My.adhd/BRAND.md`). Read it before any visual or copy change here.
`MyADHD/UI/Theme.swift` mirrors its token table value-for-value. Where this
app departs from it, that is listed in its §15 as drift, not as precedent.
The ten rules it never bends:

1. ".adhd" is violet #7B3FE4 in both themes, everywhere. Never re-tint it.
2. The mark and the Focus submark are locked: #F75C03 arms, #7B3FE4 capsule /
   case / crown, #2A2D33 tile. `icons/render.py` must stay identical to the web's.
3. Orange = the mark, or press / late / urgent (named list in BRAND.md §3.3).
4. `theme.danger` is for destructive actions only.
5. Use `Theme` colours, never a new `Color(hex:)`. `python3 ../My.adhd/tools/brand-check.py` scans this repo too.
6. Baloo 2 is the app's face; no fourth face.
7. Check light and dark. The app follows its own toggle, not the OS — except
   the Live Activity, which follows the phone's setting (the app sends it as
   `ContentState.dark`; the lock screen alone would always draw it dark).
8. No clinical claims (diagnose / treat / cure / fix).
9. Copy is the web's, verbatim (`Checks/copy.sh`). Malay is in `awak`; never `anda`, `aku`, `kau`.
10. No photos, no characters; every visual carries information; honour Reduce Motion.

## Hard rules

- **The team id lives only in `Local.xcconfig`**, which is git-ignored.
  Nothing tracked writes it down, including prose. `Signing.xcconfig`
  `#include?`s it. It has leaked into the project file once already, by
  xcodebuild resolving automatic signing and writing it back.
- **Every new target's build configs need
  `baseConfigurationReference = Signing.xcconfig`.** There is no
  `DEVELOPMENT_TEAM` anywhere in the pbxproj — it arrives only through that
  xcconfig, attached per target rather than to the project. Omit it and the
  other targets sign while the new one fails with an error that names nothing
  useful.
- **An extension must carry the same `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` as the app**, and the build number has to increase
  on every upload, for ever, including ones that get rejected. **Never edit
  either by hand: run `sh tools/release/bump.sh`** (or `bump.sh 1.1`), which
  moves every target at once and opens the build's entry in `WHATSNEW.md`.
- **Every build has its What's New, written before it is archived.**
  Guideline 2.3.12: an update must say what actually changed. The MyADHD
  target's first build phase runs `tools/release/whatsnew.sh` — a warning on
  ⌘R, an error that stops an archive — and `Checks/release.sh` holds the
  rest. Write it for a person, not as a commit log; never "bug fixes and
  performance improvements" alone. After an upload, set that entry's
  `Uploaded:` to the date and commit it: the build number is spent.
- **Scripts in this checkout run as `sh <file>` / `bash <file>`**, never
  executed directly. A freshly written one was SIGKILLed (137) on exec.
- **`MyADHDWidgets` touches neither `UserDefaults` nor the filesystem.** That is
  what keeps `MyADHDWidgets/PrivacyInfo.xcprivacy` declaring no accessed APIs at
  all: `SecItem*` is not a required-reason API, but `UserDefaults` (CA92.1),
  file timestamps (C617.1) and free disk space (E174.1) are. State belongs in
  the app target.
- **`StoreBridge.push` calls `TaskBridge.write` before `Reminders.sync`, and
  unconditionally.** `Reminders` returns early for anyone who declined
  notifications. Put the snapshot behind it and the widget is silently and
  permanently empty for those users — the worst kind of bug, because it looks
  like nothing.
- **`AppStore` is the only writer of the document.** Every mutation is a
  method on it, ported from `app.js` with the line number beside it; screens,
  `OpDrain`, `CloudSync` and `StoreBridge` call those methods or read
  `doc`, never assign it.
- **User-facing copy is the web's, verbatim.** Every string lives in
  `Core/Copy.swift`, and `Checks/copy.sh` fails on any sentence it cannot
  find in the web app's sources or in `reference/BridgeScript.swift`. Find
  the real sentence; never write a new one here.
- **The app is the only writer of the task snapshot.** It is one upserted
  keychain item, so a widget that read it, patched it and wrote it back would
  drop whatever the app wrote in between — and `TaskBridge`'s change stamp
  would then agree with its own last write and never repair it. Widgets append
  to `Shared/OpQueue.swift` and the provider lays those ops over what it reads.
- **Never clear the snapshot or the wallpaper on a failed read.** An
  unparseable store, a phone rebooted overnight and not yet unlocked — none of
  those means "the list is empty". Yesterday's data beats a blank tile.
- **The Live Activity is updated locally, never by push.** It is the Now card
  pinned to the lock screen (`LiveNow.swift`, `Shared/NowActivity.swift`); the
  app and its two intents update it. A push-updated one needs paid APNs, so
  don't add `pushType` without deciding that first.
- **`DumpControl` is the one widget behind `@available(iOS 18)`**, because
  `ControlWidget` does not exist on 17.0, the deployment target. When 17 is
  dropped, take the fence out rather than adding a second one beside it.
- **Images reach the share extension only to be read.** Vision turns the
  words in up to four photos into text on the phone; no image is stored or
  sent. A photo with no words asks the person to say what it was about.

## Building it

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project MyADHD.xcodeproj -scheme MyADHD -sdk iphonesimulator \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

`xcode-select` points somewhere else on this machine, so `DEVELOPER_DIR` is not
optional. A simulator build will **not** catch a missing
`baseConfigurationReference`, because that failure is signing-only — build to a
device before believing a new target works.

**`Local.xcconfig` is git-ignored and no clone carries it.** Simulator builds
work without one; device and signed builds fail with an error that names
nothing useful. Recreate it before the first device build, or pick a team in
Xcode under Signing & Capabilities, which writes the same file.

**A SwiftUI view that avoids UIKit can be compiled for macOS and rendered
straight to a PNG** with `swiftc` and `ImageRenderer`, which is how the
wallpaper, the timeline band and every widget tile were checked. Keep views
UIKit-free where it is free to do so — `Font.custom` already falls back to the
system face, so no `UIFont` lookup is needed. Register the bundled `.ttf` in
the harness with `CTFontManagerRegisterFontsForURL` or it silently renders in
SF and reports a pass on type it never drew.

**The keychain handover cannot be tested in the simulator.** Ad-hoc
"Sign to Run Locally" drops `keychain-access-groups` entirely, because
`$(AppIdentifierPrefix)` only expands with a provisioning profile — so the app
and the widget fall back to separate default groups and cannot see each other's
items. Everything else about a widget checks out in the simulator; the handover
itself is device-only.

**Signing expires weekly on a free team, and it expires across all three
targets.** Re-running from Xcode is also a re-add for the widget, because iOS
removes an expired one rather than blanking it. `README.md` has what that costs
day to day, and why renaming a target is not free.

## Two things that are easy to get wrong

**`Shared/` is not a synchronised group.** A new `.swift` in `MyADHD/`,
`DumpShare/` or `MyADHDWidgets/` is picked up with no project edit; one in
`Shared/` needs a `PBXFileReference` plus one `PBXBuildFile` per consuming
target, added to that target's Sources phase by hand.

**The app's promises about the web app are listed in `README.md`.** Read them
there. They have grown — the store's field names, the ported rules and the
checks that hold them, the server endpoints, the invented category palette,
and the bundled copies of the web app's font and icon geometry. No count is
given on purpose.

## Run the checks

There is no Xcode test target. `Checks/` compiles the real sources with
`swiftc` and holds them against the web app's JavaScript, its strings, and
the bytes the old shell wrote; `Checks/README.md` says what each one proves
and has the loop that runs them all. Several of them read
`../My.adhd`, so the web checkout has to sit beside this one.

## Git

- **Never stage whole files.** Unfinished work lives in the same files as
  finished work here; `git add <file>` and `commit -am` have shipped something
  broken twice. Stage hunks.
- **Commits go straight to `main`.** A branch here only gets merged back.
- `AGENTS.md` is a symlink to this file. One set of house rules, two names.
