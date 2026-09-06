# my.adhd for iOS

The web app, in a case that can buzz, ring, and be talked to by Siri.

**This project does not duplicate a line of the web app.** It opens
`https://myadhd.my/app` in a full-screen `WKWebView` and adds the four things
a page in a browser cannot do on an iPhone:

| | why it needed the native side |
|---|---|
| **Haptics** | Ticking a task off is the emotional centre of this app and on the web it is silent. Taps get three cases only — a success buzz on `.task-check`, a firmer knock on **Clear my head**, a selection tick on everything else; buzzing on all of them is what a cheap wrapper does. Swipes get the two the app had already written and never got: `navigator.vibrate` is polyfilled, so the mark at the arming threshold and the long-press pick-up finally land, and the commit is felt too — success for done, a thud for remove. |
| **Reminders** | A task carries a day and often a clock time. iOS web push needs a server pushing it and a permission a home-screen icon rarely gets; the times are already on the device, so `Reminders.swift` reads the store the web app wrote and schedules local notifications from it. The body is the task's **first step**, not its title — the title is what you already knew. |
| **Siri / Shortcuts** | *"Hey Siri, dump a thought into my.adhd."* The argument `voice.js` makes about the bus, carried one step further back: holding the mic still costs unlocking the phone and finding the icon. |
| **Google sign-in** | Google refuses OAuth inside an embedded browser. Without the workaround in `GoogleSignIn.swift` there is no signing in at all, so no sync and no calendar. |

Nothing in the web repo had to change for any of it. Everything the page
needs to know is injected from `BridgeScript.swift` at load, so the shell
works against whatever is deployed at myadhd.my — including a version that
has never heard of it.

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
├── Info.plist            bundle identity, the myadhd:// scheme, mic wording
├── MyADHD.xcodeproj/     no build settings worth hiding; INFOPLIST_FILE and
│                         a synchronised file group, so a new .swift file in
│                         MyADHD/ is picked up with no project edit
└── MyADHD/
    ├── MyADHDApp.swift    the entry point, and nothing else
    ├── RootView.swift     ground, page, and the cover that hides the white
    │                      frame before first paint
    ├── WebScreen.swift    the web view and every rule about where a tap may
    │                      go — ours stays, everyone else's gets a Safari
    │                      sheet, /auth/v1/authorize gets GoogleSignIn
    ├── BridgeScript.swift the JavaScript pushed into the page
    ├── Haptics.swift      warm generators, so the first tap is as sharp as
    │                      the rest
    ├── Reminders.swift    localStorage → UNNotificationRequest
    ├── GoogleSignIn.swift ASWebAuthenticationSession, and why
    ├── Inbox.swift        text arriving from a Shortcut or a myadhd:// link,
    │                      written down so a cold launch cannot drop it
    ├── DumpIntent.swift   the Siri phrase
    ├── ShellState.swift   theme, painted, offline
    ├── AppConfig.swift    every promise this project makes about the web app
    └── Assets.xcassets/   the icon, rendered by icons/render.py at 1024
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

**Four values here are promises about the web app** and will break quietly if
either side moves: the two grounds in `AppConfig` (`theme.css`), the
`#dump-input` id (`app.html`), the `myadhd.v1` store key (`app.js`), and the
`.task-check` / `#btn-triage` selectors the haptics hang off.

## Not done yet

- **A Share extension.** Selecting text in any app and sending it to the dump
  box is the natural next native feature, and it needs a second target.
- **Widgets and Live Activities.** "One task" is a home-screen widget waiting
  to happen. Needs a WidgetKit extension and a real read of the task list
  from Swift rather than through the page.
- **App Store review.** Guideline 4.2 rejects webview wrappers that add
  nothing. The four features above are the answer to it, but a submission
  also needs a paid account, screenshots, a privacy nutrition label, and
  review notes that say what the native layer does. None of that is started.
