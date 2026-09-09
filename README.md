# my.adhd for iOS

The web app, in a case that can buzz, ring, and be talked to by Siri.

> **The web app is the public beta; this shell is not.** myadhd.my is open to
> anyone now and is where development focus sits. This directory is a case
> around that deployed page — it still builds and still works, but it is not
> on a release track, and nothing wanted here is a reason to change the
> website. The web app's own README is [`../README.md`](../README.md).

**This project does not duplicate a line of the web app.** It opens
`https://myadhd.my/app` in a full-screen `WKWebView` and adds the four things
a page in a browser cannot do on an iPhone:

| | why it needed the native side |
|---|---|
| **Haptics** | Ticking a task off is the emotional centre of this app and on the web it is silent. Taps get three cases only — a success buzz on `.task-check`, a firmer knock on **Clear my head**, a selection tick on everything else; buzzing on all of them is what a cheap wrapper does. Swipes get the two the app had already written and never got: `navigator.vibrate` is polyfilled, so the mark at the arming threshold and the long-press pick-up finally land, and the commit is felt too — success for done, a thud for remove. |
| **Reminders** | A task carries a day and often a clock time. iOS web push needs a server pushing it and a permission a home-screen icon rarely gets; the times are already on the device, so `Reminders.swift` reads the store the web app wrote and schedules local notifications from it. The body is the task's **first step**, not its title — the title is what you already knew. |
| **Share sheet** | The thought that arrives already written, inside somebody else's app. Share from Safari or Mail and the text is queued without my.adhd ever coming to the front — so the home screen, and every badge on it, is never shown. A proof of concept; see below. |
| **Siri / Shortcuts** | *"Hey Siri, dump a thought into my.adhd."* The argument `voice.js` makes about the bus, carried one step further back: holding the mic still costs unlocking the phone and finding the icon. |
| **Google sign-in** | Google refuses OAuth inside an embedded browser. Without the workaround in `GoogleSignIn.swift` there is no signing in at all, so no sync and no calendar. |

Nothing in the web repo had to change for any of it. Everything the page
needs to know is injected from `BridgeScript.swift` at load, so the shell
works against whatever is deployed at myadhd.my — including a version that
has never heard of it.

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
open "ios/MyADHD.xcodeproj"
```

1. Plug the iPhone in and unlock it. Pick it in the device menu at the top
   of the window, next to the scheme.
2. **MyADHD** target → **Signing & Capabilities** → tick *Automatically
   manage signing* and choose your **Team**. A free Apple ID works: add it
   under *Xcode → Settings → Accounts* and it appears as `<your name>
   (Personal Team)`.

   The team you pick is written to `ios/Local.xcconfig`, which is
   git-ignored — that file is the only place a team id is meant to exist, and
   `Signing.xcconfig` `#include?`s it. Writing it yourself does the same job:

   ```bash
   echo 'DEVELOPMENT_TEAM = YOURTEAMID' > ios/Local.xcconfig
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

To check it compiles without opening Xcode:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ios/MyADHD.xcodeproj -scheme MyADHD -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

The Simulator itself has no runtimes installed on this machine. `xcodebuild
-downloadPlatform iOS` fetches one (several GB) if you want it; the device is
the better test anyway, because haptics and Siri are the point and neither is
real in a simulator.

## Signing in needs one change in Supabase

`auth.js` sends Google an `redirect_to` of `https://myadhd.my/app`. An https
address cannot be handed back to an app without an Associated Domains
entitlement, which needs the paid account — so `GoogleSignIn.swift` rewrites
it on the way out to `myadhd://auth`, and Supabase will only redirect to
somewhere on its allow-list.

**Supabase dashboard → Authentication → URL Configuration → Redirect URLs →
add `myadhd://auth`.** One line, once.

Everything else about the flow is unchanged. The tokens come back in the
fragment exactly as they always did and reach the page as a fresh load of
`/app#access_token=…`, which `absorbRedirect()` in `auth.js` already knows how
to read. Until that line is added, sign-in opens Safari and comes back with
nothing; the app itself works, because it always did without an account.

## What is where

```
ios/
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
├── MyADHD.xcodeproj/       no build settings worth hiding; INFOPLIST_FILE and
│                           a synchronised file group, so a new .swift file in
│                           MyADHD/ is picked up with no project edit
├── DumpShare/              the share extension — one file
│   └── ShareViewController.swift
│                           SLComposeServiceViewController: the box, the
│                           Cancel and the button, for none of the code
├── Shared/                 compiled into both targets
│   └── DumpQueue.swift     the handover, and why it is in the keychain
└── MyADHD/
    ├── MyADHDApp.swift        the entry point, and nothing else
    ├── RootView.swift         ground, page, and the cover that hides the white
    │                          frame before first paint
    ├── WebScreen.swift        the web view and every rule about where a tap may
    │                          go — ours stays, everyone else's gets a Safari
    │                          sheet, /auth/v1/authorize gets GoogleSignIn
    ├── OfflineView.swift      the first-launch-with-no-signal screen, and only
    │                          then — once the page has painted, offline is the
    │                          service worker's problem and it handles it
    ├── BridgeScript.swift     the JavaScript pushed into the page
    ├── Haptics.swift          warm generators, so the first tap is as sharp as
    │                          the rest
    ├── Reminders.swift        localStorage → UNNotificationRequest
    ├── GoogleSignIn.swift     ASWebAuthenticationSession, and why
    ├── Inbox.swift            text arriving from a Shortcut or a myadhd:// link,
    │                          written down so a cold launch cannot drop it
    ├── DumpIntent.swift       the Siri phrase
    ├── ShellState.swift       theme, painted, offline
    ├── AppConfig.swift        every promise this project makes about the web app
    ├── PrivacyInfo.xcprivacy  the required-reason API declaration. Without it
    │                          an upload bounces as ITMS-91053 before a human
    └── Assets.xcassets/       the icon, rendered by icons/render.py at 1024
```

### Things worth knowing before changing it

**The app icon is generated, not drawn.** `icons/render.py` in the repo root
draws the mark from its geometry; the 1024 tile here came out of the same
function, so it cannot drift from the favicons:

```bash
python3 -c "import sys; sys.path.insert(0,'icons'); import render; render.draw_icon(1024).save('ios/MyADHD/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png', optimize=True)"
```

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

**Values here are promises about the web app** and will break quietly if
either side moves: the two grounds in `AppConfig` (`theme.css`), the
`#dump-input` id (`app.html`), the `myadhd.v1` store key (`app.js`, read again
in `Reminders.swift`), and the `.task-check`, `#btn-triage` and `#composer-mic`
selectors the haptics hang off (`BridgeScript.swift`).

No count is given on purpose. The old "four" counted groups rather than
values, and the selector group quietly became three when `#composer-mic` was
added without the sentence above it changing. Before renaming anything on the
web side, grep `ios/` for it: this list is a signpost, not a guarantee that it
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

Also outstanding, and nothing to do with code: a paid membership, the
`myadhd://auth` line in Supabase's redirect allow-list without which sign-in
dead-ends inside the shell, screenshots, the privacy nutrition label, and the
review notes.

## Not done yet

- **Widgets and Live Activities.** "One task" is a home-screen widget waiting
  to happen. Needs a WidgetKit extension and a real read of the task list
  from Swift rather than through the page.
