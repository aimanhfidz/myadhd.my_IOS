# my.adhd for iOS

The web app, in a case that can ring, be talked to by Siri, and sit on the
home screen as a widget.

> **The web app ships; this shell does not.** This repo is a case around the
> deployed page — it still builds and still works, but it is not on a release
> track, and nothing wanted here is a reason to change the website.
>
> **The web app lives in a different repository**:
> [aimanhfidz/my.adhd](https://github.com/aimanhfidz/my.adhd). It used to be
> the parent directory of this one. Splitting them made the old boundary rule
> — *no file outside `ios/` is edited to make an iOS feature work* — a fact
> about the filesystem instead of a rule somebody had to keep: those files are
> simply not in this checkout. `CLAUDE.md` in here is the standing rules.

**This project does not duplicate a line of the web app.** It opens
`https://myadhd.my/app` in a full-screen `WKWebView` and adds what a page in a
browser cannot do on an iPhone — the table below, plus the widgets and the
wallpaper, which have a section of their own further down. No count is given
here on purpose; the list has grown twice and a number in prose goes stale:

| | why it needed the native side |
|---|---|
| **Reminders** | A task carries a day and often a clock time. iOS web push needs a server pushing it and a permission a home-screen icon rarely gets; the times are already on the device, so `Reminders.swift` reads the store the web app wrote and schedules local notifications from it. The body is the task's **first step**, not its title — the title is what you already knew. |
| **Share sheet** | The thought that arrives already written, inside somebody else's app. Share from Safari or Mail and the text is queued without my.adhd ever coming to the front — so the home screen, and every badge on it, is never shown. A proof of concept; see below. |
| **Siri / Shortcuts** | *"Hey Siri, dump a thought into my.adhd."* The argument `voice.js` makes about the bus, carried one step further back: holding the mic still costs unlocking the phone and finding the icon. |
| **Google sign-in** | Google refuses OAuth inside an embedded browser. Without the workaround in `GoogleSignIn.swift` there is no signing in at all, so no sync and no calendar. |

Nothing in the web repo had to change for any of it. Everything the page
needs to know is injected from `BridgeScript.swift` at load, so the shell
works against whatever is deployed at myadhd.my. The one thing the page does
know is that it is inside the shell — it reads the user agent, not anything
injected — and the one thing it does with that is show the matrix. See the
promises list below; that one is the largest promise in the repo now.

**The shell is not pinned to a web-app version.** No cache name
(`myadhd-vNN`), no `?v=` and no version number from the web repo appears
here. What it depends on is structural — ids, class names, a dozen page
globals, the store key and the task field names — and every one of those is
in the promises list.

## The web app is not this project's to change

**Everything in this directory is a wrapper or an injection.** The shell reads
the page, hides things from it, and adds what only iOS can do — but no file
outside `ios/` is edited to make an iOS feature work. That is not tidiness. It
is what keeps myadhd.my deployable without a build, and keeps this shell
working against a version of the site that has never heard of it.

So when an iOS change looks like it needs the website edited — a selector
added, a button removed, an endpoint changed — **stop and ask first.** There
is almost always an injection that does it from this side; and when there is
not, changing the web app is a decision about the website, not a step in an
iOS task. The App Store items that genuinely do live on the web side are
listed at the bottom of this file as exactly that. In-app account deletion
was one of them and has since shipped — on the web side, by a decision about
the website, which is the shape the rest of them should take too.

## Running it on your iPhone

Xcode 26.6 and the iOS 26.5 SDK are already on this machine. There is no
package manager step and no dependency to fetch; the project builds as-is.

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
App Store need — none of which this build is waiting on.

**That expiry now costs more than it used to.** It hits three targets rather
than one, and an expired widget is *removed* from the home screen rather than
left blank — so a weekly re-sign is also a weekly re-add. Each target is also
its own App ID against the ten a free account gets per seven days, which is
worth knowing before renaming one on a whim.

To check it compiles without opening Xcode:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MyADHD.xcodeproj -scheme MyADHD -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

There is an iOS 26.5 simulator runtime on this machine now, and most of the
shell can be checked in it. The device is still the better test: Siri and the
keychain handover between the app and its widgets are only real there.

**There are three haptics, and for two days there were none.** They were the
first native feature — a buzz on a tick, a knock on Clear my head, the two
swipe moments `app.js` had asked for — and every one of them was removed on
2026-09-18 at the owner's call, generators and `navigator.vibrate` polyfill
and all.

What came back with the Swift port is narrower, and the line dividing it
from what was taken out is worth stating: **a gesture with a timer in it, or
with a threshold you cannot see, has no other way of telling you it has
happened.** So all three confirm a gesture, and none of them decorates an
outcome:

- the matrix lifting a task off its quadrant (`MatrixDrag.swift`)
- a swipe crossing the point where letting go would do something
  (`SwipeRow.swift`)
- the month grid taking hold of a day, so the agenda can be dragged across
  it (`MonthDrag.swift`)

Nothing buzzes for finishing a task, and nothing should. `git log` has the
ones that did.

## Signing in, and what the server side has to be

`auth.js` sends Google a `redirect_to` of `https://myadhd.my/app`. An https
address cannot be handed back to an app without an Associated Domains
entitlement, which needs the paid account — so `GoogleSignIn.swift` rewrites
it on the way out to `myadhd://auth`, and Supabase will only redirect to
somewhere on its allow-list.

**Supabase dashboard → Authentication → URL Configuration → Redirect URLs →
`myadhd://auth`.** The owner confirmed this is in place on 2026-09-20. It
cannot be checked from outside: `/auth/v1/authorize` answers 302 to Google
whatever you ask it to redirect to, and the destination is carried in an
opaque server-side `state`, so the only proof is a real sign-in on a device.

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
├── icons/                  render.py draws the app icon at 1024 straight into
│                           the asset catalogue; icon-source.svg is the
│                           readable definition. A copy of the web app's
│                           script — see the promises below
├── MyADHD.xcodeproj/       no build settings worth hiding; INFOPLIST_FILE and
│                           synchronised file groups, so a new .swift file in
│                           MyADHD/ or MyADHDWidgets/ is picked up with no
│                           project edit — Shared/ is NOT one of them, and a
│                           file there needs a build-file entry per target
├── DumpShare/              the share extension — one file
│   └── ShareViewController.swift
│                           SLComposeServiceViewController: the box, the
│                           Cancel and the button, for none of the code
├── Shared/                 compiled into more than one target, by hand
│   ├── DumpQueue.swift     the share extension's handover, and why it is in
│   │                       the keychain
│   ├── TaskSnapshot.swift  the model, DayKey, and the one keychain item the
│   │                       app leaves for anything that cannot reach the page
│   ├── OpQueue.swift       the other direction: what a widget did, waiting
│   │                       for a page to tell. Never writes the snapshot
│   ├── TaskRows.swift      a task as one row, a day as one column, and the
│   │                       whole Today checklist
│   ├── MonthGrid.swift     six weeks of it, off the day counts
│   ├── DoneGraph.swift     the contribution grid, and why it is not green
│   └── TimelineBand.swift  the day as one band. No WidgetKit import, so the
│                           wallpaper can draw the same chart
├── MyADHDWidgets/          the widget extension
│   ├── MyADHDWidgets.swift Next Up, Today Timeline, the bundle, SnapProvider,
│   │                       and the gallery's fabricated day
│   ├── TodayChecklistWidget.swift
│   │                       the checklist, and the only tile with a button
│   ├── AgendaWidget.swift  today and tomorrow, two columns
│   ├── MonthWidget.swift   the month, and Ink's "Month & Tasks" at large
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
└── MyADHD/
    ├── MyADHDApp.swift        the entry point, and nothing else
    ├── RootView.swift         ground, page, and the cover that hides the white
    │                          frame before first paint
    ├── WebScreen.swift        the web view and every rule about where a tap may
    │                          go — ours stays, everyone else's gets a Safari
    │                          sheet, /auth/v1/authorize gets GoogleSignIn
    ├── OfflineView.swift      the no-signal screen, on every cold launch with no
    │                          connection — the page's service worker never runs
    │                          in this web view (its header says why), so there
    │                          is no offline install to fall back on
    ├── BridgeScript.swift     the JavaScript pushed into the page
    ├── Reminders.swift        localStorage → UNNotificationRequest
    ├── GoogleSignIn.swift     ASWebAuthenticationSession, and why
    ├── Inbox.swift            text arriving from a Shortcut or a myadhd:// link,
    │                          written down so a cold launch cannot drop it
    ├── DumpIntent.swift       the Siri phrases, and the AppShortcutsProvider
    │                          all three intents are registered in
    ├── TaskBridge.swift       localStorage → the keychain snapshot, riding on
    │                          the read Reminders.sync already does
    ├── OpDrain.swift          the widget's ticks → the page's own markDone()
    ├── DoneLedger.swift       what the web app forgets after seven days, kept
    │                          natively so the Done graph has a history
    ├── Wallpaper.swift        ImageRenderer → a PNG in Documents
    ├── WallpaperView.swift    what that PNG shows. UIKit-free on purpose, so
    │                          it renders off-device and previews in the sheet
    ├── WallpaperIntent.swift  the two App Intents Shortcuts calls
    ├── WallpaperSetup.swift   the setup sheet, and the three states that stop
    │                          it nagging once the automation works
    ├── ShellState.swift       theme, painted, offline
    ├── AppConfig.swift        every promise this project makes about the web app
    ├── Baloo2-Variable.ttf    a copy of the web app's fonts/Baloo2-Variable.ttf,
    │                          so the wallpaper is drawn in the app's own face.
    │                          A second copy sits under MyADHDWidgets/ — three
    │                          files across two repos, replaced together
    ├── PrivacyInfo.xcprivacy  the required-reason API declaration. Without it
    │                          an upload bounces as ITMS-91053 before a human
    └── Assets.xcassets/       the icon, rendered by icons/render.py at 1024
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

**The web view is transparent and ignores the safe area, on purpose.**
`styles.css` already pads for `env(safe-area-inset-*)` on every screen, so
letting iOS inset the view as well pads it twice. The ground behind it is
painted from the theme the page last reported, remembered across launches —
which is the only reason a dark-theme launch does not flash white.

**`localStorage` is the database.** `configuration.websiteDataStore =
.default()` is written out rather than left implicit for that reason. Every
task lives there; an ephemeral store would empty the app on each launch.

**The donation link is closed on iOS, from this side.** `app.html` carries two
asks — the tin in the thanks card and the quiet line above it — and
`paintFeedback()` renders neither when `MYADHD_DONATE_URL` is empty. So
`BridgeScript.swift` defines that global as a permanently empty property
before `config.js` runs, and the web app hides both by its own "no link, no
ask" path. The website keeps its tin; the shell simply never shows it. Why: an
external payment link is the least settled corner of App Review, and it is not
worth spending a first submission on. No file outside `ios/` was touched.

**Values here are promises about the web app**, which since the split lives in
[a different repository](https://github.com/aimanhfidz/my.adhd). They will
break quietly if either side moves, and nothing in this checkout can catch it —
there is no `app.js` here to grep, and no build that fails. That is the price
of the split, and it is why this list is worth keeping accurate: the two grounds in `AppConfig` (`theme.css`), the
`#dump-input` id (`app.html`), the `myadhd.v1` store key — now
`AppConfig.storeKey`, substituted into `BridgeScript` as `__STOREKEY__` and
read by `Reminders.swift`.

More arrived with the widgets, and one with the matrix. They are promises in
a looser sense — nothing on the web side will break, but it will silently
disagree with this:

- **The user-agent suffix, `MyADHD-iOS/<version>`** (`AppConfig.userAgentSuffix`,
  set on the web view's configuration in `WebScreen.swift`). `app.js` tests
  `/MyADHD-iOS\//` on `navigator.userAgent` to decide it is inside the shell
  (`IN_SHELL`), and the matrix — the four quadrants, the toggle in the lists
  header, and the "?" walkthrough `BridgeScript` builds on top of them —
  exists only when that test passes. It came out of the web app on
  2026-09-18 and came back the next day for the shell alone. Rename the
  prefix and the matrix disappears from the app with no error anywhere.

- **The task shape `TaskBridge` reads.** It picks `id`, `title`, `minutes`,
  `when`, `at`, `category`, `energy`, `urgency`, `importance`, `firstStep`,
  `done`, `doneAt` and `skipped` out of `myadhd.v1` by name, and the
  top-level `doneCounts` map beside `tasks`. `importance` is decoded as
  optional on purpose, so a store written before it existed still works;
  nothing draws it yet. A renamed field elsewhere would leave the widget
  drawing a blank day rather than failing, which is the worst way for this
  to go wrong — a version number on the web store would let it refuse
  instead, and is the one change on the site that would make this feature
  safer.
- **`CategoryTint` in `Shared/TimelineBand.swift`.** Eight hues for the eight
  categories, sampled between `--blue` and `--violet`. `theme.css` has no
  per-category colour at all, so this is a shell invention; if the web app
  ever ships its own, the two will not match.
- **`doneAt`**, a millisecond epoch stamped by `markDone` in `app.js`.
  `TaskBridge` buckets it into local days to fill the Done graph, and
  `DoneLedger` keeps the result because `pruneDone()` deletes the task itself
  after seven days. A rename breaks the graph silently, not loudly.
- **`window.markDone(id, after)` and `window.repaintLists()`.** `OpDrain`
  calls both by name to land a tick taken on a widget. They are reachable only
  because `app.js` is a classic script with no module wrapper — wrap it in one,
  or rename either, and the drain falls back to editing `localStorage` and
  reloading, which works but throws away the screen the user was on.
- **`MyADHD/Baloo2-Variable.ttf` and `MyADHDWidgets/Baloo2-Variable.ttf`** are
  copies of the web app's `fonts/Baloo2-Variable.ttf`, so the wallpaper and the
  widget tiles are drawn in the app's own face rather than in SF. Its
  PostScript name is `Baloo2-Regular`, which is what `WallpaperView` and
  `Font.baloo` ask for. Three files in two repos; replace one, replace all
  three. Both copies the build needs are tracked here, so nothing breaks on a
  fresh clone — what breaks is the day somebody changes the typeface and only
  one repo hears about it.
- **`icons/render.py`** is a copy of the web app's script of the same name, and
  `draw_icon()`'s geometry is the shared part. The mark changing on the website
  does not change the app icon until somebody runs this one too.

No count is given on purpose. The old "four" counted groups rather than
values, and the selector group quietly became three when `#composer-mic` was
added without the sentence above it changing. Before renaming anything on the
web side, grep this repo for it — it is a separate checkout now, so the grep
has to be deliberate. This list is a signpost, not a guarantee that it
is complete.

## The share extension, and the keychain

A second target, `DumpShare`, appearing in the system share sheet. It cannot
write a task: it runs in its own sandbox and the tasks live in `localStorage`
inside the app's web view. So it queues the text and the app drains it on the
way back to the front.

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

Rough edges, this being a proof of concept:

- The button says **Post**. `SLComposeServiceViewController` gives the box,
  the Cancel and the button already looking like the system for none of the
  code, and does not offer to rename it. First thing to replace.
- A shared page becomes `Title — url`. The title comes from what Safari puts
  in the item's content text rather than from reading the page, so a site that
  does not supply one leaves just the address.
- Images are not accepted, deliberately: nothing in the app can read one, so
  offering it would be a button that captures nothing.

## Getting it onto the App Store

Guideline 4.2 exists to reject webview wrappers, and this is one. The features
in the table at the top are the answer to it, and the review-notes field is
where that answer gets made — for this app it is the most important text in
the submission, not a formality.

The full 26-step plan, in dependency order, is a checklist here:
<https://claude.ai/code/artifact/49e4c687-f514-4d37-ae1a-15ef3ade0e3c>

**Done, in this directory only:**

- `PrivacyInfo.xcprivacy` — required since May 2024. Without it the upload
  bounces as `ITMS-91053` before a human sees anything. It declares
  `UserDefaults` (`ShellState.swift`, `Inbox.swift`) with reason `CA92.1`.
  The synchronised file group picks it up with no project edit; a Release
  build puts it at the root of `MyADHD.app`. `DumpShare` touches no
  required-reason API, so it needs none of its own — check that again if the
  extension ever grows.
- `TARGETED_DEVICE_FAMILY = 1` — iPhone only. Shipping to iPad obliges a set
  of 13" screenshots and invites a reviewer to open a one-column web app in
  landscape split view. The dead `UISupportedInterfaceOrientations~ipad` key
  went with it.
- `MARKETING_VERSION = 1.0`, in both targets — an extension must carry the
  same version and build as its host or the upload is rejected.
  `CURRENT_PROJECT_VERSION` is the build number and has to increase on every
  upload, forever, including ones that get rejected.
- The donation link, closed from `BridgeScript.swift` — see above.

**Done since, and in the web app rather than here:**

- **In-app account deletion.** Guideline 5.1.1(v): an app offering accounts
  must let people delete them inside it, and says pointing at an email
  address does not count. `/api/delete-account` and the control beside
  **Sign out** landed in `26f7d21`. Nothing in `ios/` was needed for it, and
  nothing in `ios/` was changed.

**Left, and it lives in the web app too, so it is not this project's to start
without asking:**

- **Sign in with Apple.** Guideline 4.8: Google is the only provider, and a
  third-party login setting up the primary account needs a companion that
  collects only name and email. There is a real argument the rule does not
  apply here, since the app works fully signed out — but Sign in with Apple
  ends the argument rather than having it.

Also outstanding, and nothing to do with code: a paid membership,
screenshots, the privacy nutrition label, and the review notes. The
`myadhd://auth` redirect line, which used to be on this list, is in place —
see the sign-in section above for what that does and does not prove.

## The widgets, and the wallpaper

Both of them draw the same thing — the next task and its two-minute first
step — because that is the whole product, and a lock screen is the one place
a person looks eighty times a day without deciding to.

**Neither can reach the web view.** A widget's timeline provider runs in its
own process on iOS's schedule; the wallpaper intent runs headless at seven in
the morning. So the app pushes a snapshot out to somewhere both can read, and
`Shared/TaskSnapshot.swift` is that: one upserted keychain item, the same
unspecified-access-group trick `DumpQueue` uses, because a free account gets
no App Group. Sixty-four trimmed tasks compress to about a kilobyte.

`MyADHD/TaskBridge.swift` fills it, riding on the `evaluateJavaScript` that
`Reminders.sync` already does at all four lifecycle moments. It sits **above**
the notification-permission gate in `Reminders.sync` deliberately: that gate
returns early for anyone who declined notifications, and a widget has nothing
to do with notifications. Moving it below is a silent, total failure for
those users.

| | families | |
|---|---|---|
| **Today** | `systemSmall`, `systemMedium`, `systemLarge` | The checklist, and the only one with a button in it. Rows come off `paintToday()`'s rule — anything late, then anything dated today, then whatever is open — two of them at small, three at medium, eight at large. |
| **Next Up** | `systemSmall`, `accessoryCircular`, `accessoryInline` | One task and its two-minute step. |
| **Today Timeline** | `systemMedium`, `systemLarge`, `accessoryRectangular` | The band. Rectangular is six hours around now rather than twenty-four — a 160×72pt tile cannot carry a day. Large is the band, then the checklist, then a tomorrow strip. |
| **Agenda** | `systemMedium`, `systemLarge` | Today and tomorrow as two columns, with anything late folded into the top of the Today one. Hiding late in a tile that is looking at tomorrow would be the exact failure this app exists to prevent. |
| **Month** | `systemMedium`, `systemLarge` | The month, a mark on every day the list has something dated to, today ringed in the accent and a past day with something still open marked in Vivid Orange. Large is the grid over the checklist. |
| **Done** | `systemMedium`, `systemLarge` | A contribution grid of what has been finished. See the caveat below — it is the one tile whose content is thin on day one. |

Six of them, against the seven Ink ships. Theirs are all read-only, because a
wallpaper cannot have a button in it; ours is the same gallery with the one
thing they structurally cannot answer added to it.

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

The Today checklist, the large timeline and the large Month tile all carry a
`Button(intent: TickIntent(...))`. Ink has nothing like it; a wallpaper cannot
have a button in it, which is the whole argument for a widget over a picture.

The path is not direct, and cannot be. The widget's process has no web view,
so:

1. `TickIntent` appends a `done` op to `Shared/OpQueue.swift` — its own
   keychain service, one item per op, `SecItemAdd` only.
2. `SnapProvider.current()` lays the pending ops over the snapshot it reads,
   so the row strikes through in the time WidgetKit takes to reload.
3. The next time the app is in front of somebody, `OpDrain` calls the page's
   own `window.markDone(id, function () {})` for each queued id and drops only
   the ones the page confirmed.

**Through `markDone`, not through `localStorage`.** `markDone` stamps `doneAt`,
calls `save()` — which is `cloud.stamp()`, `persistOnly()`, `syncSoon()` and
`cloud.soon()` — and offers the same Undo the app offers. Editing the store
directly would get four of those five wrong and the live page would overwrite
the fifth on its next save. The empty `after` is load-bearing: the default is
`goToNext`, which would yank the user to another screen for something they did
an hour ago on the home screen.

What that costs, plainly:

- **The tile ticks in well under a second. The web store catches up whenever
  the app is next opened** — which could be days. This is inherent to a widget
  process that cannot reach a web view, not to this design.
- **An "Undo" toast appears for something done an hour ago**, once per drained
  op, because `markDone` always toasts. Three ticks on the widget are three
  toasts on next open. Accepted: it is an undo affordance, and suppressing it
  means shimming another internal.
- **The tick carries a `cloud.stamp()` from drain time, not tap time.** On a
  two-device conflict it wins as though it happened when you opened the app. A
  small lie about *when*, never about *what*.
- **An op that lands nowhere is swept after 48 hours and the tile un-ticks.**
  That is the honest outcome — better a row that comes back than one that
  pretends.
- **The drain runs at `pageReady()`, at `returning()`, and on the page's
  `refresh` message** — a pull on a tab screen, which is the one gesture
  meant to bring every surface up to date at once. Nowhere else: not on the
  1.5s store debounce, which `markDone`'s own `save()` triggers —
  that is re-entrancy for no gain. Not on `leaving()`, where the background
  window is already tight and nobody would see the repaint. And not on a
  `returning()` that has queued share text, because `dump()` reloads the page
  and `pageReady()` will catch it after the load.

### The Done graph reads the page's own ledger

`pruneDone()` in `app.js` deletes any finished task older than `DONE_TTL` —
seven days — so the store's `tasks` can never hand over more than a week.
Since 2026-09-18 it counts before it deletes: `state.doneCounts[dayKey]`
goes up by one for each task it prunes, bounded at 400 days, and it syncs
through `cloud.js` like the rest of the store. `TaskBridge` reads that map
out of `myadhd.v1` beside `tasks`, and `MyADHD/DoneLedger.swift` merges it
with the week of stamped tasks still in the store (and keeps its own copy
bounded at the same 400, so a phone that has not opened the app in a while
still has a history).

What it cannot do is reach back before the counting started. A phone whose
store predates 2026-09-18 has a graph that begins there, and the header says
**"Since Fri 18 Sep."** rather than drawing half a year of empty squares and
letting them read as half a year of doing nothing.

### The one thing still to prove

`WallpaperIntent` returns the PNG as an `IntentFile`, on the assumption that
Shortcuts' **Set Wallpaper Photo** will accept it as its image input. That is
likely and unconfirmed — it needs a device and the Shortcuts app, and nothing
on a Mac can answer it.

If it is refused, the fallback is the photo library: `Find Photos → Recently
Added → Limit 1 → Set Wallpaper Photo`, which needs
`NSPhotoLibraryAddUsageDescription` and add-only authorization. Note that
add-only cannot create or fetch a named album, so the camera roll gains one
image per run — a reason to keep the automation daily. A named album needs
full read-write Photos access, which changes the App Store privacy
questionnaire **and `privacy.html`, which is outside `ios/`**. That is the
strongest argument for making the `IntentFile` path work.

**The most likely support question:** Set Wallpaper Photo silently does
nothing when the current lock screen is **Photo Shuffle** rather than
**Photo**. `WallpaperSetup.swift` says so, first.

`AppConfig.wallpaperShortcutURL` is `nil` until somebody builds the shortcut
once on a device and pastes its iCloud link in. That link roughly halves the
setup. Shipping a signed `.shortcut` file instead is a dead end — iOS only
accepts Apple-signed ones.

## Not done yet

- **Live Activities.** Not attempted. They need `NSSupportsLiveActivities` in
  the app's `Info.plist`, and a push-updated one needs APNs, which is a paid
  capability. Nothing declares it today and nothing should until there is a
  reason.
- **A Control Center control.** "Dump a thought" belongs there, and
  `ControlWidget` is iOS 18 while this project targets 17.0. Worth doing when
  17 is dropped rather than fencing one member of a `WidgetBundle` behind
  `@available`.
