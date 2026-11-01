# my.adhd for iOS

my.adhd as a native iPhone app: the same brain dump, triage and one next
task as [myadhd.my](https://myadhd.my), plus what only an iPhone can do —
ring at the right time, take a thought from Siri or the share sheet, sit on
the home screen and the lock screen.

> **This is a SwiftUI app, not a web view.** It was a `WKWebView` around
> myadhd.my/app until 2026-09-20 (`b910230` "every screen, in Swift",
> `f72814c` "the app is Swift now"). Every screen is drawn natively, the
> lists live in a JSON file on the phone, and the app opens, triages and
> reminds with no connection at all. If a comment in here still talks about
> "the page" or "the shell", it is from before; believe the code.
>
> **The web app lives in a different repository**:
> [aimanhfidz/my.adhd](https://github.com/aimanhfidz/my.adhd), checked out
> beside this one as `../My.adhd`. It used to be the parent directory of
> this one. `CLAUDE.md` in here is the standing rules.

## How it is put together

**The web app is the specification, ported rather than reimagined.** Every
rule that decides what a person sees — how a dump is split into tasks, the
order the lists come out in, which task is "now", what `markDone` stamps,
how the sync settles a conflict, what each event on Google Calendar looks
like — is a Swift translation of the JavaScript that does it on the web,
with the `app.js` / `cloud.js` / `gcal.js` line numbers written beside it.
`Checks/` compiles the real sources and holds them against the web's own
code and strings, because a rule ported slightly wrong has no compiler
error and no crash; it just draws a different day.

The shape of it:

- **One document, one writer.** `Core/StoreFile.swift` keeps
  `Library/Application Support/myadhd/myadhd.v1.json` — exactly the bytes
  `JSON.stringify(state)` would have put in the web's `localStorage`,
  written atomically and protected until first unlock. `Core/AppStore.swift`
  holds it and is the only thing allowed to change it; every mutation is a
  method there.
- **`UI/AppShell.swift` is the spine.** It owns the store, decides which
  screen is up, runs the boot order from the bottom of `app.js` (read,
  migrate once, prune, stamp), and runs the one flow that crosses every
  screen: a dump goes in, triage happens, the lists come back.
- **Triage works on a plane.** `Triage/TriageClient.swift` asks
  `/api/triage`; a dead network, a bad status or an empty answer all fall
  back to `Triage/LocalTriage.swift`, the web's own offline parser ported
  rule for rule, and the tasks it makes say so.
- **`Bridge/StoreBridge.swift` pushes the document out to iOS** after each
  write settles (1.5 s), on the way out and on the way back: the keychain
  snapshot the widgets and wallpaper read (`TaskBridge`), the notification
  schedule (`Reminders`), and the Live Activity (`LiveNow`).
- **The account is optional.** The app works fully signed out. Signing in
  with Google (`Sync/`) makes the lists follow you to the website and other
  devices through Supabase, and lets dated tasks reach Google Calendar.
- **The old shell's data comes with it.** `Bridge/LegacyImport.swift` lifts
  the old web view's `localStorage` out on the first launch after the
  update — read straight from WebKit's SQLite file, with a hidden web view
  only as the fallback — and refuses to believe an empty read until it is
  corroborated, so nobody's lists vanish in the upgrade.

What an iPhone gets that a browser tab could not:

| | why it needed the native side |
|---|---|
| **Reminders** | A task carries a day and often a clock time. iOS web push needs a server pushing it and a permission a home-screen icon rarely gets; the times are already on the device, so `Reminders.swift` turns every dated, open task into a local notification. The body is the task's **first step**, not its title — the title is what you already knew. Nudges at the pace you choose, and note bells, ride on the same schedule. |
| **Widgets and the lock screen** | Seven widgets, the Now card as a Live Activity, a Control Centre / Action Button dump, and a wallpaper kept current by a Shortcut. They have a section of their own below. |
| **Share sheet** | The thought that arrives already written, inside somebody else's app. Share from Safari or Mail and the text is queued without my.adhd ever coming to the front — so the home screen, and every badge on it, is never shown. Photos are read for their words on the phone. |
| **Siri / Shortcuts** | *"Hey Siri, dump a thought into my.adhd."* The argument `voice.js` makes about the bus, carried one step further back: holding the mic still costs unlocking the phone and finding the icon. |
| **Offline, all of it** | The lists, triage (by the local parser), reminders, widgets and wallpaper need no connection. Only voice transcription, sync and Google Calendar do. |

## The web app is not this project's to change

Nothing in the web repository has to change for an iOS feature, and nothing
in it is edited from here. That keeps myadhd.my deployable without a build,
and keeps the two repos moving at their own speeds.

So when an iOS change looks like it needs the website or the server changed
— a new field in the store, a different answer from an endpoint, a sentence
that is not in the web's copy — **stop and ask first.** Changing the web app
is a decision about the website, not a step in an iOS task. In-app account
deletion was one of those and shipped on the web side, by a decision about
the website, which is the shape the rest should take too.

## Running it on your iPhone

Xcode 27.1 is on this machine, with iOS 26.5, 27.0 and 27.1 simulator
runtimes. There is no package manager step and no dependency to fetch; the
project builds as-is.

```bash
open MyADHD.xcodeproj
```

1. Plug the iPhone in and unlock it. Pick it in the device menu at the top
   of the window, next to the scheme.
2. **MyADHD** target → **Signing & Capabilities** → tick *Automatically
   manage signing* and choose your **Team**. A free Apple ID works: add it
   under *Xcode → Settings → Accounts* and it appears as `<your name>
   (Personal Team)`.

   The team you pick is written to `Local.xcconfig`, which is
   git-ignored — that file is the only place a team id is meant to exist, and
   `Signing.xcconfig` `#include?`s it. Writing it yourself does the same job:

   ```bash
   echo 'DEVELOPMENT_TEAM = YOURTEAMID' > Local.xcconfig
   ```

3. If Xcode says the bundle identifier is taken, change
   `PRODUCT_BUNDLE_IDENTIFIER` from `my.adhd.ios` to anything unique —
   `my.adhd.ios.aiman` will do.
4. Press ⌘R.
5. The first run stops with *Untrusted Developer*. On the phone:
   **Settings → General → VPN & Device Management →** your Apple ID **→
   Trust**. Then ⌘R again.

**A free personal team signs for seven days.** After that the app refuses to
launch until you plug in and press ⌘R again. A paid Apple Developer
membership ($99/yr) raises that to a year and is also what TestFlight and the
App Store need.

**That expiry costs more than it looks.** It hits three targets rather
than one, and an expired widget is *removed* from the home screen rather than
left blank — so a weekly re-sign is also a weekly re-add. Each target is also
its own App ID against the ten a free account gets per seven days, which is
worth knowing before renaming one on a whim.

To check it compiles without opening Xcode:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MyADHD.xcodeproj -scheme MyADHD -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Most of the app can be checked in the simulator. The device is still the
better test: Siri, the keychain handover between the app and its widgets, and
the wallpaper shortcut are only real there.

**The haptics confirm a gesture, and none of them decorates an outcome.**
The web-view shell's haptics — a buzz on a tick, a knock on Clear my head —
were all removed on 2026-09-18 at the owner's call. What came back with the
Swift port is narrower: **a gesture with a timer in it, or with a threshold
you cannot see, has no other way of telling you it has happened.**

- the matrix lifting a task off its quadrant (`MatrixDrag.swift`)
- a swipe crossing the point where letting go would do something
  (`SwipeRow.swift`)
- the month grid taking hold of a day, so the agenda can be dragged across
  it (`MonthDrag.swift`)

And one that bends the rule: a tap that picks a different wallpaper design
on the Home shelf (`WallpaperShelf.swift`), because the preview changes
under the finger and the lock screen does not change until later.

Nothing buzzes for finishing a task, and nothing should. `git log` has the
ones that did.

## Signing in, and what the server side has to be

`Sync/AuthFlow.swift` is `auth.js`'s sign-in, native. It builds Supabase's
`/auth/v1/authorize` URL for Google and hands it to `GoogleSignIn.swift`,
which opens it in an `ASWebAuthenticationSession` — Safari, because Google
refuses OAuth in an embedded browser (`disallowed_useragent`). An https
redirect cannot be handed back to an app without an Associated Domains
entitlement, which needs the paid account, so the redirect is
`myadhd://auth`, and Supabase will only redirect to somewhere on its
allow-list.

**Supabase dashboard → Authentication → URL Configuration → Redirect URLs →
`myadhd://auth`.** The owner confirmed this is in place on 2026-09-20. It
cannot be checked from outside: `/auth/v1/authorize` answers 302 to Google
whatever you ask it to redirect to, and the destination is carried in an
opaque server-side `state`, so the only proof is a real sign-in on a device.

The session lives in the Keychain (`Sync/Session.swift`). Google's refresh
token, which renews the calendar link, is posted straight to
`/api/link-google` and never written to the phone.

The rest of the server side WAS checked, on 2026-09-20, and is recorded here
so it is not guessed at again:

| | |
|---|---|
| `tasks`, anonymous select | HTTP 200 and `[]` — the policy exists and filters; nothing leaks |
| `tasks`, anonymous insert | HTTP 401, `42501 new row violates row-level security policy` |
| the `(id, user_id)` unique key `on_conflict` needs | present — an upsert naming it reaches the row check (`42501`), where a missing constraint would have failed at planning with `42P10`. The control, `on_conflict=id,nosuchcolumn`, fails earlier still with `42703`, which is what proves the target is validated before the row check |
| `/api/triage`, `/api/feedback`, `/api/transcribe` | live, and reject an empty body with 400 |
| `/api/link-google` | live, and refuses an unauthenticated call with 401 |

What none of that proves is the other direction: that the authenticated
policies **admit** a signed-in person to their own rows. Too strict a policy
fails exactly like too loose a one is dangerous — silently — and the only way
to see it is to sign in on a device and watch a row make the round trip.

## What is where

```
myadhd.my_IOS/
├── Info.plist              bundle identity, the myadhd:// scheme, mic wording
├── Signing.xcconfig        who signs this build. #includes Local.xcconfig,
│                           which is git-ignored, so no team id is committed
├── Local.xcconfig          DEVELOPMENT_TEAM, one line, untracked. Xcode writes
│                           it when you pick a team, or echo it in yourself
├── MyADHD.entitlements     one keychain access group, written as
│                           $(AppIdentifierPrefix)my.adhd.shared
├── DumpShare.entitlements  the same group, spelled the same way — which is
│                           the whole mechanism behind the share sheet
├── DumpShare-Info.plist    the extension's bundle keys and activation rule
├── MyADHDWidgets.entitlements
│                           the same keychain group again, spelled the same way
├── MyADHDWidgets-Info.plist
│                           NSExtensionPointIdentifier = widgetkit-extension,
│                           which is the whole of what makes it a widget
├── CLAUDE.md               the standing rules. AGENTS.md is a symlink to it
├── Checks/                 swiftc scripts holding the port to the web app.
│                           Its README says what each one proves
├── reference/              BridgeScript.swift, the retired injection: not
│                           built, kept as the only spec for the screens the
│                           website never had. Its README says when it may go
├── WHATSNEW.md             What's New for every build, newest first — see
│                           "Every build, its What's New"
├── tools/shortcut/         build.py generates the lock-screen shortcut
├── tools/release/          bump.sh (the next build number, in every target)
│                           and whatsnew.sh (the build phase's check)
├── icons/                  render.py draws the app icon at 1024 straight into
│                           the asset catalogue; icon-source.svg is the
│                           readable definition. A copy of the web app's
│                           script — see the promises below
├── MyADHD.xcodeproj/       no build settings worth hiding; INFOPLIST_FILE and
│                           synchronised file groups, so a new .swift file in
│                           MyADHD/, DumpShare/ or MyADHDWidgets/ is picked up
│                           with no project edit — Shared/ is NOT one of them,
│                           and a file there needs a build-file entry per target
├── DumpShare/              the share extension — one file
│   └── ShareViewController.swift
│                           SLComposeServiceViewController: the box, the
│                           Cancel and the button, for none of the code
├── Shared/                 compiled into more than one target, by hand
│   ├── DumpQueue.swift     the share extension's handover, and why it is in
│   │                       the keychain
│   ├── TaskSnapshot.swift  the model, DayKey, and the one keychain item the
│   │                       app leaves for anything that runs without it
│   ├── OpQueue.swift       the other direction: what a widget did, waiting
│   │                       for the app. Never writes the snapshot
│   ├── PhotoWords.swift    Vision, reading the words in a photo on the phone
│   ├── TaskRows.swift      a task as one row, a day as one column, and the
│   │                       whole Today checklist
│   ├── MonthGrid.swift     six weeks of it, off the day counts
│   ├── DoneGraph.swift     the contribution grid, and why it is not green
│   ├── ListenIntent.swift  what the Dump control runs; in the app too, so
│   │                       iOS can open the app to run it
│   ├── NowActivity.swift   the Live Activity's model and its Done / Not now
│   │                       intents; app and widget both compile it
│   └── TimelineBand.swift  the day as one band. No WidgetKit import, so the
│                           wallpaper can draw the same chart
├── MyADHDWidgets/          the widget extension
│   ├── MyADHDWidgets.swift Next Up, Today Timeline, the bundle, SnapProvider,
│   │                       and the gallery's fabricated day
│   ├── TodayChecklistWidget.swift
│   │                       the checklist, and a tile with a button in it
│   ├── AgendaWidget.swift  today and tomorrow, two columns
│   ├── MonthWidget.swift   the month, and Ink's "Month & Tasks" at large
│   ├── MatrixWidget.swift  the four boxes, with a tick on every row
│   ├── NowLiveActivity.swift
│   │                       the Now card on the lock screen and the Island
│   ├── DumpControl.swift   Control Centre / Action Button: opens
│   │                       myadhd://listen. iOS 18 only
│   ├── DoneGraphWidget.swift
│   │                       the only tile that looks backwards
│   ├── TickIntent.swift    the button. Appends to OpQueue and asks for a
│   │                       redraw; nothing comes to the front
│   ├── DayProvider.swift   a timeline for the tiles with no now-line in them
│   ├── Baloo2-Variable.ttf the second copy in this repo, so the tiles are set
│   │                       in the app's own face rather than in SF
│   ├── PrivacyInfo.xcprivacy
│   │                       deliberately declares nothing — see below
│   └── Assets.xcassets/    AccentColor and WidgetBackground, nothing else
└── MyADHD/                 the app
    ├── MyADHDApp.swift     the entry point, and nothing else
    ├── RootView.swift      the app, and the wallpaper setup sheet over it
    ├── AppConfig.swift     the handful of constants: the site's address,
    │                       the auth callback, the store key, the shortcut
    ├── Core/               the store and the rules. AppStore (the one
    │                       writer), StoreFile (the document on disk),
    │                       StoreDocument / TaskItem / NoteItem (its shape),
    │                       Ordering (the lists' order and the Now pick),
    │                       Copy (every user-facing string), WebDates and
    │                       WebJSON (Date and JSON.stringify, byte for byte),
    │                       Meetings, CalendarPush, Reachability
    ├── UI/                 every screen. AppShell is the spine; the rest
    │                       draw one thing each from the store. Theme
    │                       mirrors BRAND.md's tokens
    ├── Triage/             TriageClient (/api/triage) and LocalTriage, the
    │                       offline parser it falls back to
    ├── Voice/              the mic: the recorder, a WAV writer proved
    │                       byte-identical to voice.js, /api/transcribe
    ├── Sync/               the account: AuthFlow, Session, Supabase,
    │                       CloudSync (cloud.js's pass), CalendarSync (the
    │                       Google Calendar push), GoogleMeetings
    ├── Bridge/             the document going out to iOS: StoreBridge,
    │                       ReminderPlan / NudgePlan / NoteReminderPlan,
    │                       and LegacyImport, which brings an old shell's
    │                       data across once
    ├── Net/                FeedbackClient
    ├── Reminders.swift     the document → UNNotificationRequest
    ├── NotificationRouter.swift
    │                       a tapped notification → the right screen
    ├── TaskBridge.swift    the document → the keychain snapshot
    ├── OpDrain.swift       the widget's ticks → AppStore
    ├── DoneLedger.swift    the Done graph's history, kept past pruneDone()
    ├── LiveNow.swift       the Live Activity, kept on the same task as Home
    ├── GoogleSignIn.swift  ASWebAuthenticationSession, and why
    ├── Inbox.swift         text arriving from a Shortcut or a myadhd:// link,
    │                       written down so a cold launch cannot drop it
    ├── DumpIntent.swift    the Siri phrases, and the AppShortcutsProvider
    │                       the intents are registered in
    ├── ShellState.swift    the remembered theme, for the headless wallpaper
    ├── Wallpaper*.swift    the lock-screen picture, its designs, the intents
    │                       the shortcut calls, and its setup — see below
    ├── Media/              the splash's morph, light and dark
    ├── Baloo2-Variable.ttf a copy of the web app's fonts/Baloo2-Variable.ttf.
    │                       A second copy sits under MyADHDWidgets/ — three
    │                       files across two repos, replaced together
    ├── PrivacyInfo.xcprivacy
    │                       the required-reason API declaration. Without it
    │                       an upload bounces as ITMS-91053 before a human
    └── Assets.xcassets/    the icon, rendered by icons/render.py at 1024
```

### Things worth knowing before changing it

**The app icon is generated, not drawn.** `icons/render.py` draws the mark
from its geometry rather than rasterising the SVG, and writes the 1024 tile
straight into the asset catalogue:

```bash
python3 icons/render.py
```

That script is a **copy** of the web app's `icons/render.py`, which uses the
same `draw_icon()` for the favicons, the apple-touch-icon and the OAuth
consent logo. It was copied rather than imported when the repos split: a build
step that needs somebody else's checkout is a build step that stops working.
The cost is that the mark's geometry now exists in two places and can drift —
it is in the promises list below for that reason. `icons/icon-source.svg`
beside it stays the readable definition.

**The copy is the web's, word for word.** Every user-facing string is in
`Core/Copy.swift`, and `Checks/copy.sh` fails on any sentence it cannot find
in the web app's sources or in `reference/BridgeScript.swift`, naming it. A
screen that needs a new sentence needs it written on the web first.

**There is no donate tin.** The website asks in two places; this app asks in
neither, and has no Plans screen. An external payment link is the least
settled corner of App Review, and it is not worth spending a first submission
on (`SettingsScreen.swift` and `FeedbackScreen.swift` say where each one
would have been).

**Values here are promises about the web app**, which lives in
[a different repository](https://github.com/aimanhfidz/my.adhd). They break
quietly if either side moves, and a build here cannot catch it — only the
checks can, and only for what they cover:

- **The store's shape.** `myadhd.v1` — the document's name on disk, the key
  the web keeps it under, and `AppConfig.storeKey` — and every field in it,
  read and written by name: the task fields, `doneCounts`,
  `signupOfferHidden`, the notes. `CloudSync` meets the browsers through the
  same Supabase rows, so a field the web renames is a field this app drops
  on the floor, and a field this app invents is one the web overwrites.
  `Checks/roundtrip.sh` holds that an unknown key survives a read and a
  write.
- **The ported rules.** `AppStore` (`app.js`'s mutations), `Ordering`
  (`paintToday`, `pickNow`, `quadrantOf`), `LocalTriage` (`parseLocally`),
  `CloudSync` (`cloud.js`'s pass), `CalendarSync` (`gcal.js`). Each cites
  the lines it came from, and `parity-triage`, `parity-ordering`, `store`,
  `cloud` and `calendar` in `Checks/` hold them to those lines. A rule
  changed on the web keeps running the old way here until somebody ports it.
- **The server.** `/api/triage`, `/api/transcribe`, `/api/feedback`,
  `/api/link-google`, `/api/gcal-token` (200 / 404 not linked / 409
  revoked), `/api/gcal-calendar` (claim-if-empty, and since 2026-11-01 its
  `replaces` claim for a calendar deleted in Google) and
  `/api/delete-account`, plus Supabase's auth and `tasks` table.
- **The Google Calendar push** (`Sync/CalendarSync.swift`, since
  2026-10-31). It shares the account's one `my.adhd` calendar with every
  browser, so `eventSig()`'s exact output matters — `gcal.sig` travels
  between devices, and a difference would have the phone and the web
  rewrite each other's events for ever (`Checks/calendar.sh` holds it
  against `app.js`) — and so does `extendedProperties.private.myadhdId` on
  every event, which is how this app finds an event a browser already made
  before that browser's id has synced.
- **`doneAt`**, a millisecond epoch stamped by `markDone`. `TaskBridge`
  buckets it into local days to fill the Done graph, and `DoneLedger` keeps
  the result because `pruneDone()` deletes the task itself after seven days.
  A rename breaks the graph silently, not loudly.
- **The matrix box.** `TaskBridge` picks `quadrant` out of each task and
  the snapshot carries it as `q`. Where a task has none,
  `SnapTask.quadrant(on:)` re-derives it with `quadrantOf`'s rule — urgency 5
  or more, or due today or earlier, is urgent; `importance == "high"` is
  important — and `Checks/parity-ordering.swift` holds the copy.
- **`CategoryTint` in `Shared/TimelineBand.swift`.** Eight hues for the eight
  categories, sampled between `--blue` and `--violet`. `theme.css` has no
  per-category colour at all, so this is an iOS invention; if the web app
  ever ships its own, the two will not match.
- **`MyADHD/Baloo2-Variable.ttf` and `MyADHDWidgets/Baloo2-Variable.ttf`** are
  copies of the web app's `fonts/Baloo2-Variable.ttf`. Its PostScript name is
  `Baloo2-Regular`, which is what `Font.baloo` asks for. Three files in two
  repos; replace one, replace all three.
- **`icons/render.py`** is a copy of the web app's script of the same name, and
  `draw_icon()`'s geometry is the shared part. The mark changing on the website
  does not change the app icon until somebody runs this one too.
- **`UI/Theme.swift`** mirrors `BRAND.md`'s token table value for value.

No count is given on purpose: a number in prose goes stale. Before renaming
anything on the web side, grep this repo for it — it is a separate checkout,
so the grep has to be deliberate. This list is a signpost, not a guarantee
that it is complete.

## The share extension, and the keychain

A second target, `DumpShare`, appearing in the system share sheet. It cannot
write a task: it runs in its own sandbox, and the tasks live in the app's own
container. So it queues the text and the app drains it on the way back to the
front.

The usual place to queue it is an App Group container, which needs an
entitlement a free account is not given. **This uses the keychain instead** —
the development profile already grants the whole team prefix, so both targets
can declare one shared access group and share a drawer with nothing bought and
nothing hacked. Neither names the group in code: an unspecified access group
means "the first one in my entitlement", and both entitlements list exactly one
and the same — spelled `$(AppIdentifierPrefix)my.adhd.shared`, which Xcode
expands at build time.

That spelling is the point. The team id is a fact about a machine and an Apple
ID, so it lives in `Local.xcconfig`, which is git-ignored, and nothing tracked
here ever writes it down — including this file, which used to.

It is an odd drawer for a queue and the right one for the contents: a brain
dump is private speech, and these are short strings that exist for the seconds
between sharing something and opening the app.

Rough edges:

- The button says **Add**, set on the navigation item in `viewWillAppear`.
  `SLComposeServiceViewController` does not offer to rename it, so this
  leans on its layout, and an iOS update could put **Post** back.
- A shared page becomes `Title — url`. The title comes from what Safari puts
  in the item's content text rather than from reading the page, so a site that
  does not supply one leaves just the address.
- Up to four images are accepted, and only their words are kept: Vision
  reads them on the phone (`Shared/PhotoWords.swift`, one line per photo),
  and a photo with no words says so and leaves the box for the person to
  fill. The composer's photo button uses the same reader.

## Getting it onto the App Store

**Guideline 4.2 is no longer the risk it was.** It exists to reject apps that
are a website in a frame, and until 2026-09-20 this was one. It is now a
native app that runs with no connection, and the review notes below make
that case plainly rather than defending a wrapper.

The 26-step plan written for the web-view submission was a checklist
artifact (`claude.ai/code/artifact/49e4c687…`); on 2026-11-01 it could no
longer be opened from this account, so this section is the record now.

**Done:**

- **`PrivacyInfo.xcprivacy`**, required since May 2024. Without it the
  upload bounces as `ITMS-91053` before a human sees anything. It declares
  `UserDefaults` (CA92.1) and, since 2026-11-01, file timestamps (C617.1)
  for `StoreFile`'s check of its own document's modification date — that
  one arrived with the native store and was missing until then. The widget
  extension's declares nothing; `DumpShare` touches no required-reason API.
  Run this before every upload, since a new call to one of these APIs is
  an automatic rejection:

  ```bash
  grep -rnE 'UserDefaults|ModificationDate|CreationDate|attributesOfItem|volumeAvailableCapacity|systemUptime|mach_absolute_time|activeInputModes' MyADHD Shared DumpShare MyADHDWidgets
  ```

- **`TARGETED_DEVICE_FAMILY = 1`** — iPhone only. Shipping to iPad obliges a
  set of 13" screenshots and a layout for landscape split view.
- **`MARKETING_VERSION = 1.0`** in every target — an extension must carry the
  same version and build as its host or the upload is rejected.
  `CURRENT_PROJECT_VERSION` (2 today) is the build number and has to increase
  on every upload, forever, including ones that get rejected.
- **What's New on every build** (Guideline 2.3.12: an update must describe
  what changed). See "Every build, its What's New" below.
- **In-app account deletion** (Guideline 5.1.1(v)). The three-stage delete in
  `UI/AccountCard.swift` calls `/api/delete-account`, the same endpoint the
  website's control uses (web `26f7d21`).
- **No external payment link** — see "There is no donate tin" above.
- **The `myadhd://auth` redirect** is on Supabase's allow-list — see the
  sign-in section for what that does and does not prove.

**Left, and it lives on the server side too, so it is not this project's to
start without asking:**

- **Sign in with Apple** (Guideline 4.8). Google is the only provider, and a
  third-party login setting up the primary account needs a companion that
  collects only name and email. There is a real argument the rule does not
  apply, since the app works fully signed out — but Sign in with Apple ends
  the argument rather than having it. It needs the paid membership (the
  capability and a Services ID), the Apple provider switched on in Supabase,
  and a button in `AccountCard` beside Google's.

**Left, and the copy rule makes it a web decision: the "v0.1.0 Beta" line
at the foot of Settings** (`Copy.Settings.version` / `versionTag`, from
`app.html:844`). Guideline 2.2 keeps betas off the App Store, and a reviewer
who sees the word may stop there; the number also disagrees with
`MARKETING_VERSION = 1.0`. Either the web drops the tag, or this app stops
drawing that line — ask which.

**Left, and nothing to do with code:** the paid membership; screenshots
(6.9" iPhone); the privacy nutrition label; a demo path for the reviewer
(below); and `NSPrivacyCollectedDataTypes` in `MyADHD/PrivacyInfo.xcprivacy`,
which is still empty from the web-view days and should be filled in to match
the label.

### Every build, its What's New

`WHATSNEW.md` is the text App Store Connect shows under **What's New in This
Version**, one entry per build — `## <version> (<build>)`, an `Uploaded:`
line, then exactly what gets pasted. The routine:

1. **`sh tools/release/bump.sh`** (or `bump.sh 1.1` for a new version). It
   moves the build number — and the version, when given — in all six build
   configurations at once, opens an empty entry, and prints the commits
   since `WHATSNEW.md` last moved to write it from.
2. **Write the entry.** What a person can now do, what works better, what
   was broken and is not. English, like the app; no clinical claims.
3. **Archive and upload.** Then change `Uploaded: no` to the date and
   commit it.

Held two ways. The MyADHD target's first build phase, **What's New**, runs
`tools/release/whatsnew.sh` with the target's own version and build: on an
ordinary build a problem is a warning and the build goes on; on an archive
it is an error and the archive stops, before anything can be uploaded.
`Checks/release.sh` checks that every target agrees, that the phase is
still there, and that the script still refuses what it should. What it
refuses: no entry for this build, an empty one, a placeholder, "bug fixes
and performance improvements" with nothing else, over 4,000 characters, a
build already uploaded or below one that was, and one build number on two
versions.

The phase declares `WHATSNEW.md` and the script as its inputs because user
script sandboxing is on — a file it does not declare, it cannot read.

### The privacy label, drafted from the code

What the app itself sends, now that the code that sends it ships in the app.
None of it is used for tracking or advertising; all of it is App
Functionality. Check every line against `privacy.html` before submitting —
the three have to tell the same story.

| Data type | Where it goes | Linked to the person |
|---|---|---|
| Email address, name | Google sign-in → Supabase (only if they sign in) | Yes |
| Other user content: tasks and notes | Supabase `tasks`, for sync (only if signed in) | Yes |
| Other user content: the dump text | `/api/triage`, to be sorted into tasks | No — the route is unauthenticated and sends no id |
| Audio data: a voice dump | `/api/transcribe`, turned into text | No — the same |
| Customer support: feedback | `/api/feedback`, the typed text only | No — the same |

Not collected: photos (read for their words on the phone; nothing is sent),
the phone's calendars (read on the phone), location, contacts, identifiers,
usage data, diagnostics. Google Calendar events go between the phone and
Google directly, with a token minted by `/api/gcal-token`.

### Review notes (draft)

For App Store Connect → App Review Information → Notes. Plain, short, and
every claim checkable in the app:

```
my.adhd is a native SwiftUI app for getting thoughts out of your head and
into one next step. Type or say everything on your mind; the app sorts it
into tasks, each with a two-minute first step, and shows you one thing to
do now.

No account is needed. Everything works signed out and offline: the lists
are stored on the device, tasks are sorted by an on-device parser when
there is no connection, and reminders are local notifications. To review
the core flow, open the app, type a few thoughts into the box (for example
"call the bank tomorrow at 10, buy milk, finish the report by Friday") and
tap "Clear my head".

Signing in with Google is optional. It syncs the lists with the website
(myadhd.my) and lets dated tasks appear in Google Calendar. Accounts can be
deleted inside the app: Settings → Delete account (shown once signed in).

What it does on iPhone:
- Local reminders at a task's time, showing its first step
- Widgets (Today, Next up, Timeline, Agenda, Month, Matrix, Done), a Live
  Activity for the current task, and a Control Centre button that opens
  the app listening
- Siri and Shortcuts: "Dump a thought into my.adhd"
- A share extension that adds shared text, links or the words in a photo
  (read on the device with Vision)
- An optional lock-screen wallpaper of today's tasks, kept current by a
  Shortcut the app helps you add

Network use: the text of a dump is sent to our server to be sorted, and a
voice dump to be transcribed; neither is used for anything else. The app
has no ads, no analytics and no tracking.
```

Before pasting it, check two things against the build: that Delete account
sits where the line above says (it is in `AccountCard`, drawn on Settings,
and appears once signed in), and whether a reviewer can reach every feature
signed out. If anything they need sits
behind sign-in, App Review will ask for a demo account, and a Google login
cannot be handed over the way a username and password can — so the answer
has to be that nothing is behind it.

## The widgets, and the wallpaper

Both of them draw the same thing — the next task and its two-minute first
step — because that is the whole product, and a lock screen is the one place
a person looks eighty times a day without deciding to.

**Neither can reach the app.** A widget's timeline provider runs in its own
process on iOS's schedule; the wallpaper intent runs headless from a
Shortcut. So the app pushes a snapshot out to somewhere both can read, and
`Shared/TaskSnapshot.swift` is that: one upserted keychain item, the same
unspecified-access-group trick `DumpQueue` uses, because a free account gets
no App Group. Sixty-four trimmed tasks compress to about a kilobyte.

`MyADHD/TaskBridge.swift` fills it, from the bytes `AppStore` just wrote, each
time `StoreBridge` pushes. `StoreBridge` calls it **before** `Reminders.sync`
and unconditionally, deliberately: `Reminders` returns early for anyone who
declined notifications, and a widget has nothing to do with notifications.
Putting the snapshot behind it is a silent, total failure for those users.

| | families | |
|---|---|---|
| **Today** | `systemSmall`, `systemMedium`, `systemLarge` | The checklist, with a button on every row. Rows come off `paintToday()`'s rule — anything late, then anything dated today, then whatever is open — two of them at small, three at medium, eight at large. |
| **Next Up** | `systemSmall`, `accessoryCircular`, `accessoryInline` | One task and its two-minute step. |
| **Today Timeline** | `systemMedium`, `systemLarge`, `accessoryRectangular` | The band. Rectangular is six hours around now rather than twenty-four — a 160×72pt tile cannot carry a day. Large is the band, then the checklist, then a tomorrow strip. |
| **Agenda** | `systemSmall`, `systemMedium`, `systemLarge` | Today and tomorrow as two columns, with anything late folded into the top of the Today one. Hiding late in a tile that is looking at tomorrow would be the exact failure this app exists to prevent. |
| **Month** | `systemMedium`, `systemLarge` | The month, a mark on every day the list has something dated to, today ringed in the accent and a past day with something still open marked in Vivid Orange. Large is the grid over the checklist. |
| **Done** | `systemMedium`, `systemLarge` | A contribution grid of what has been finished. See the caveat below — it is the one tile whose content is thin on day one. |
| **Matrix** | `systemMedium`, `systemLarge` | Do now, Plan, Delegate, Drop, with a tick on every row. |

Beside them in the same bundle: **the Now card as a Live Activity** on the
lock screen and in the Dynamic Island (`NowLiveActivity.swift`, with Done and
Not now buttons), and **the Dump control** for Control Centre and the Action
Button (`DumpControl.swift`, iOS 18).

**The counts the Month and Done tiles draw are swept from the whole store,
before the task list is trimmed** — so they stay true when `dropped > 0`. A
month grid derived from `tasks` would under-count every day past tomorrow and
lose the rest once the cap bit, which is a calendar being wrong quietly.

The band's window is computed from the data rather than fixed at 0–24, which
is worth about fifty per cent more pixels per hour. Untimed tasks never go on
it; they are counted as "N anytime", because placing them at a made-up nine
o'clock would be an invention.

**The widget target touches neither `UserDefaults` nor the filesystem**, so
`MyADHDWidgets/PrivacyInfo.xcprivacy` declares no accessed APIs at all.
`SecItem*` is not a required-reason API; `UserDefaults` (CA92.1), file
timestamps (C617.1) and free disk space (E174.1) are. Keep it that way.

### Ticking one off from a tile, and what it costs

The Today checklist, the Matrix, the large timeline and the large Month tile
carry a `Button(intent: TickIntent(...))`. A wallpaper cannot have a button
in it, which is the whole argument for a widget over a picture.

The widget's process cannot reach the app's memory, so:

1. `TickIntent` appends a `done` op to `Shared/OpQueue.swift` — its own
   keychain service, one item per op, `SecItemAdd` only.
2. `SnapProvider.current()` lays the pending ops over the snapshot it reads,
   so the row strikes through in the time WidgetKit takes to reload.
3. The next time the app comes to the front, `OpDrain` hands each queued id
   to `AppStore.landTick`, **before** `StoreBridge` pushes the snapshot —
   the other order writes the un-ticked row back over the tile.

`landTick` is `markDone` with the tap's own time: it stamps `doneAt` with the
moment the tile was tapped, not the moment the app opened, and calls
`save()`, so the cloud stamp, the file, the calendar and the sync all follow
exactly as for a tick in the app. A task already done elsewhere is dropped
without being stamped again.

What that costs, plainly:

- **The tile ticks in well under a second. The store catches up whenever the
  app is next opened** — which could be days. This is inherent to a widget
  process that cannot write the document, not to this design.
- **One "Done" toast appears on that next open**, however many ticks landed.
- **The sync stamp is from drain time, not tap time.** On a two-device
  conflict the tick wins as though it happened when you opened the app. A
  small lie about *when*, never about *what*.
- **An op that lands nowhere is swept after 48 hours and the tile un-ticks.**
  That is the honest outcome — better a row that comes back than one that
  pretends.

### The Done graph reads the store's own ledger

`pruneDone()` deletes any finished task older than `DONE_TTL` — seven days —
so the store's `tasks` can never hand over more than a week. Since 2026-09-18
it counts before it deletes: `doneCounts[dayKey]` goes up by one for each task
it prunes, bounded at 400 days, and it syncs like the rest of the store, on
the web and here alike. `TaskBridge` reads that map beside `tasks`, and
`MyADHD/DoneLedger.swift` merges it with the week of stamped tasks still in
the store (and keeps its own copy bounded at the same 400, so a phone that has
not opened the app in a while still has a history).

What it cannot do is reach back before the counting started. A store that
predates 2026-09-18 has a graph that begins there, and the header says
**"Since Fri 18 Sep."** rather than drawing half a year of empty squares and
letting them read as half a year of doing nothing.

### Proven on a device

`WallpaperIntent` returns the PNG as an `IntentFile`, and Shortcuts' **Set
Wallpaper Photo** takes it — from a locked phone too, since `2e574d5`, as
long as the picture goes over as bytes and never as a file URL (see the
shortcut's notes below). The photo-library fallback that used to be written
here is not needed, and would have meant a Photos permission and a change to
`privacy.html`.

**The most likely support question:** Set Wallpaper Photo silently does
nothing when the current lock screen is **Photo Shuffle** rather than
**Photo**. `WallpaperSetup.swift` says so, first.

### The shortcut itself

**"my.adhd Lock Screen" is generated, not hand-built:**
`python3 -I tools/shortcut/build.py --open` writes it into `build/` (git-ignored,
because it carries the team id from `Local.xcconfig`), signs it with
`shortcuts sign --mode anyone` — Apple's signature, so any iPhone imports
it — and opens it in Shortcuts on this Mac. The flow is in the header of
`MyADHD/WallpaperIntent.swift`; the shape is Ink's "Refresh Lock Screen V2",
taken apart on 2026-10-26:

- **The app decides, the shortcut branches.** `WallpaperModeIntent` answers
  `skip`, `set` or `redraw` (`MyADHD/WallpaperMode.swift`, held to it by
  `Checks/wallpaper-mode.sh`), so a later build can change what a run does
  without anyone reinstalling the shortcut.
- **Skip is what pays for frequent triggers.** It answers `skip` only when
  the board's digest matches the last *confirmed* picture, and the day is
  in the digest, so one run a day always really sets.
- **Redraw is Ink's repaint**: set, set again on the wallpaper that came
  back. Opt-in, from **Force a redraw** on the setup page.
- **v3 (2026-11-01) is Ink's V2 as re-cut since**, decoded from the link
  the user shared that day. After `set`/`redraw` the answer names the
  screens: `same` (one picture on Lock and Home Screen) or `pair` (Lock
  Screen, then the plain ground on the Home Screen of that wallpaper),
  plus `blur` for Legibility Blur on the Home Screen half. Every run ends
  by switching to the wallpaper it set, not only a redraw. The answer
  still says `home` beside `pair`, so a phone still on v2 keeps working.
  `Checks/wallpaper-mode.sh` holds the words, including that none hides
  inside another (the shortcut tests with "contains").
- **The design is a library.** `WallpaperStyle.design` picks what the band
  draws: the matrix, One Thing (the Now card's task), Today, Month or the
  Done Graph (`MyADHD/WallpaperDesigns.swift`, which says how to add one).
  They are chosen on Home from `MyADHD/UI/WallpaperShelf.swift`, Ink's
  Discover row: your own tasks and photo in every preview, **Set as
  current**, and **Update** on the current one, which runs the shortcut
  by `AppConfig.wallpaperShortcutName`. `build.py` refuses to build a
  version that constant does not name.
- **The automations ride inside it** (`WFWorkflowTriggers`: sunrise,
  my.adhd closed, a notification from my.adhd) **but iOS does not install
  them.** Seen on iOS 27.0.1 on 2026-10-26: the shortcut imported, the
  Automation tab stayed empty, and the lock screen never moved after a new
  task. `ShortcutSetupPage` therefore keeps hand-built steps: two of them,
  07:00 and the notification one, with "Is Closed" as the fallback for
  anyone with notifications off (tested with it switched off: swipe home
  and side button both updated the lock screen).
- **Locking the phone inside the app is not "closed".** So on
  `willResignActive`, if the board has moved since the last drawing and the
  shortcut has confirmed at least once, `MyADHD/WallpaperPing.swift` posts
  one passive notification ("Updating your lock screen"). The notification
  automation (Body contains "lock screen") runs the shortcut, and
  `WallpaperModeIntent`, its first step, takes the notification down
  again. Change that body text and every hand-made automation stops
  matching.
- **The picture goes to Shortcuts as bytes, never as a file URL.** From
  a locked phone, a file URL arrived empty ("Unable to Set Wallpaper.
  Please provide an image").

`AppConfig.wallpaperShortcutURL` takes the iCloud link shared from that
copy (Share → Copy iCloud Link).

## Not done yet

- **Sign in with Apple**, before the App Store — see above.
- **A corrupt store is set aside, not restored.** Since `d2feee1` a document
  that will not parse is moved aside and its last good `.bak` is copied to
  `rescue-<stamp>.json`, so nothing is lost; but the app starts fresh and
  nothing offers to bring the rescue back. That is a decision for the owner,
  not a fix.
- **Comments from the web-view days.** The headers of `TaskBridge`,
  `OpDrain`, `Reminders`, `GoogleSignIn`, `ShellState`, `AppConfig` and
  `WallpaperIntent` still describe a page, `localStorage` and
  `evaluateJavaScript`; `OpDrain`'s promises a "web route" that is gone.
  `AppConfig` still carries web-view constants nothing reads
  (`inAppPaths`, `ownHosts`, `dumpBoxID`, `userAgentSuffix`), and
  `ShellState` its `painted` / `offline` flags. Several files cite a
  `design.md` that is in neither repo.
- **The Live Activity cannot start itself.** iOS only starts one with the
  app in front and ends it after about eight hours, so after a night it is
  gone until the app is next opened. Keeping it alive longer would need a
  push-updated one, and APNs is a paid capability.
- **The Dump control is iOS 18 only.** `ControlWidget` does not exist on
  17.0, so it is the one member of the bundle behind `@available`. Drop
  the fence with 17.
