# my.adhd — iOS

The `WKWebView` shell around [myadhd.my](https://myadhd.my). Read **`README.md`**
first — it has the full picture: what the native features are and why each
needed the native side, how to build and sign on a device, the keychain
handover, the widgets and the wallpaper, and where the App Store submission
stands. This file is standing rules for working in here.

## The other repo

The web app is **[aimanhfidz/my.adhd](https://github.com/aimanhfidz/my.adhd)**,
and it is not in this checkout. It used to be: this directory was `ios/` inside
it until the two were split.

That split is why the oldest rule in this project no longer needs enforcing.
It used to read *"no file outside `ios/` is edited to make an iOS feature
work"*, and it was the thing most likely to get quietly broken when an iOS task
was blocked. Now the web app's files are not here to edit. The rule is the
filesystem.

What has not changed is how this shell reaches the page, and there are still
only two routes:

- **Injection.** `MyADHD/BridgeScript.swift` pushes JavaScript into the page at
  load, so the shell works against whatever is deployed — including a version
  that has never heard of it. That property is the point, and it is what lets
  these two repos move at different speeds.
- **The snapshot.** Anything running headless — a widget's timeline provider,
  the wallpaper intent — has no web view to ask, so the app writes a keychain
  snapshot (`Shared/TaskSnapshot.swift`) for them to read. That is a second
  coupling to the web app's store, by field name.

**If an iOS change looks like it needs the website changed, stop and ask.** Say
what the web change would be and why neither route above will do it. It is now
a pull request against a different repository, which is exactly the amount of
friction that decision deserves.

`README.md` lists what this shell is quietly depending on over there. Read them
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
7. Check light and dark. The app follows its own toggle, not the OS.
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
  on every upload, for ever, including ones that get rejected.
- **`MyADHDWidgets` touches neither `UserDefaults` nor the filesystem.** That is
  what keeps `MyADHDWidgets/PrivacyInfo.xcprivacy` declaring no accessed APIs at
  all: `SecItem*` is not a required-reason API, but `UserDefaults` (CA92.1),
  file timestamps (C617.1) and free disk space (E174.1) are. State belongs in
  the app target.
- **`TaskBridge.write` sits above the notification-permission gate in
  `Reminders.sync`.** That gate returns early for anyone who declined
  notifications. Below it, the widget is silently and permanently empty for
  those users — the worst kind of bug, because it looks like nothing.
- **The app is the only writer of the task snapshot.** It is one upserted
  keychain item, so a widget that read it, patched it and wrote it back would
  drop whatever the app wrote in between — and `TaskBridge`'s change stamp
  would then agree with its own last write and never repair it. Widgets append
  to `Shared/OpQueue.swift` and the provider lays those ops over what it reads.
- **Never clear the snapshot or the wallpaper on a failed read.** No page, an
  unparseable store, a phone rebooted overnight and not yet unlocked — none of
  those means "the list is empty". Yesterday's data beats a blank tile, and a
  cold launch reads before the page has painted.
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

**The shell's promises about the web app are listed in `README.md`.** Read them
there. They have grown — the grounds and ids and selectors, the task field
names `TaskBridge` reads, the page functions `OpDrain` calls, the invented
category palette, and the bundled copies of the web app's font and icon
geometry. No count is given on purpose.

## Git

- **Never stage whole files.** Unfinished work lives in the same files as
  finished work here; `git add <file>` and `commit -am` have shipped something
  broken twice. Stage hunks.
- **Commits go straight to `main`.** A branch here only gets merged back.
- `AGENTS.md` is a symlink to this file. One set of house rules, two names.
