/* ============================================================
   MyADHD/UI/SettingsScreen.swift — one short list, every answer one tap away

   `showSettings` / `paintSettings` (app.js:3944-3964), `paintLocalNote`
   (app.js:3677-3693), `#screen-settings` (app.html:662-850),
   inventory §1.11.

   **The shape.** One screen of rows, each with its name and what it is set
   to right now ("Every 4 hours", "Off", "On"), and the controls one tap
   behind it. That is the iOS Settings pattern and the HIG's: a top level
   short enough to read without scrolling, the current value where you
   are looking, the detail only for whoever goes in. The old page drew
   every card open — the sign-in, three nudge levels, the waking hours,
   the meetings switch — and ran to two and a half screens; a person
   looking for one switch had to read all of them.

   Three groups and no captions, because the grouping says it: who you
   are, what the app does for you, and about. The fine print — where the
   lists live — moved in with the account it describes.

   **What is deliberately not here.** No Subscription group, no Plans
   screen and no donate tin. That is design §4, decision 4: App Store
   guideline 3.1.1 wants any purchase inside the app to go through
   StoreKit, nothing in my.adhd is gated behind a plan, and a payment
   surface for a thing that unlocks nothing is a review rejection in
   exchange for no feature at all. `Copy` carries no strings for them
   either — a literal in that file is a promise that something draws it.

   **Two seams.** The Account card (§1.12) and the Google Calendar card
   (§1.13) are another agent's files. They mount through `accountCard`
   and `googleCard` below, and their two facts — whether there is an
   account and whether a calendar is configured — come in as flags rather
   than being guessed at here, because `paintLocalNote` picks one of
   three sentences off exactly those two and a screen that invented an
   answer would tell somebody their lists were somewhere they are not.
   Both default to nothing and false, so this screen is correct on its
   own: no cards, and the note that says this device and nowhere else.

   **The version is the web's literal, not the bundle's.** app.html
   writes `v0.1.0` and `Beta` into the markup; `CFBundleShortVersionString`
   is the shell's own number and has never been the one on this line.
   Drawing the bundle here would make the footer disagree with the same
   footer on the web for the same person.
   ============================================================ */

import SafariServices
import SwiftUI
import UserNotifications

/// The row names and values the web has no line for. Native only, so not
/// in `Copy` — copy.sh holds that file to the web word for word.
enum SettingsCopy {
    static let account = "Account"
    static let reminders = "Reminders"
    static let calendar = "Calendar"

    static let signedIn = "Signed in"
    static let thisDevice = "This device"
    static let on = "On"
    static let off = "Off"
    static let notConnected = "Not connected"
    static let needsLook = "Needs a look"
}

struct SettingsScreen: View {

    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    let store: AppStore
    let themeStore: ThemeStore
    let toasts: ToastCenter

    /// `#btn-settings-back` — back to home.
    var onClose: () -> Void

    // MARK: - the seams

    /* SEAM — the Account card, `#acct-card` (inventory §1.12,
       app.html:714-753, app.js:3593-3826), from `MyADHD/UI/AccountCard.swift`.
       It is drawn on the Account page, one tap in, above the note that
       says where the lists live. */
    var accountCard: (() -> AnyView)?

    /* SEAM — the Google Calendar card, `#gcal-card` (inventory §1.13,
       app.html:757-792, app.js:3447-3568), including the duplicate
       calendar block. On the Calendar page, above the meetings switch.
       `checkDuplicateCalendars()` runs behind the screen on open
       (app.js:3962) and is that card's business, not this one's. */
    var googleCard: (() -> AnyView)?

    /// `auth.configured() && auth.signedIn()` — the first half of
    /// `paintLocalNote`'s question.
    var isSignedIn: Bool = false

    /// `gcal.configured()` — the second half. Configured, note, not
    /// linked: the web asks whether the card is on the screen at all.
    var isCalendarConfigured: Bool = false

    /// The meetings on your Google Calendar, and the switch that turns
    /// them on. The Google card above it decides where your tasks go;
    /// this one reads the day you already have.
    var meetings: MeetingReader? = nil

    /// The sign-in, for a switch that is on with no Google to read. The
    /// shell owns `AuthFlow`, so it hands the press in.
    var connectGoogle: (() async -> Void)? = nil

    // MARK: - one tap deeper (app.js:4087-4101)

    /// Screens rather than panes. `fullScreenCover` is the same fact
    /// `show()` is on the web: while you are on one of these, the tab bar
    /// is down and there is nowhere else to be.
    private enum Deeper: String, Identifiable {
        case profile, account, reminders, calendar, lockScreen, feedback
        var id: String { rawValue }
    }
    @State private var deeper: Deeper?

    /// `<a href="/privacy">` and `<a href="/terms">`. Both are pages on
    /// our own host that the shell has always kept inside the app
    /// (`AppConfig.inAppPaths`), so they open in a Safari sheet rather
    /// than throwing somebody out to the browser mid-settings.
    @State private var legal: LegalPage?

    /* What the rows say they are set to. Read again whenever a page
       closes or the app comes back, since iOS Settings can take the
       notification permission away while this screen is underneath. */
    @State private var nudgesOn = NudgeSettings.enabled
    @State private var nudgeLevel = NudgeSettings.level
    @State private var nudgeStatus: UNAuthorizationStatus = .notDetermined
    @State private var lockHealth = SetupHealth(drawn: Wallpaper.lastRun,
                                                confirmed: Wallpaper.lastConfirmed)

    var body: some View {
        VStack(spacing: 0) {
            SettingsBar(themeStore: themeStore,
                        backLabel: Copy.Settings.back,
                        backAria: Copy.Settings.backAria,
                        title: Copy.Settings.title,
                        onBack: onClose)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    you
                    features
                    about
                    version
                }
                .frame(maxWidth: Theme.measure, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            #if DEBUG
            .defaultScrollAnchor(Self.debugAnchor)
            #endif
        }
        .padding(.horizontal, Theme.gutter(UIScreen.main.bounds.width))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.surface.ignoresSafeArea())
        .toastLayer(toasts, hasTabBar: false)
        .task {
            await refresh()
            #if DEBUG
            deeper = Self.debugPage
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
        .fullScreenCover(item: $deeper, onDismiss: { Task { await refresh() } }) { which in
            deeperScreen(which)
                .environment(\.theme, theme)
                .preferredColorScheme(themeStore.colorScheme)
        }
        .sheet(item: $legal) { page in
            SafariSheet(url: page.url)
                .ignoresSafeArea()
        }
    }

    #if DEBUG
    /// `-myadhdSettingsAnchor center|bottom`, for screenshots of the rest
    /// of the page on a simulator nobody can scroll.
    private static var debugAnchor: UnitPoint {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-myadhdSettingsAnchor"), i + 1 < args.count else { return .top }
        switch args[i + 1] {
        case "center": return .center
        case "bottom": return .bottom
        default: return .top
        }
    }

    /// `-myadhdSettingsPage reminders|account|calendar|…`, to open one
    /// page in for the same screenshots.
    private static var debugPage: Deeper? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-myadhdSettingsPage"), i + 1 < args.count else { return nil }
        return Deeper(rawValue: args[i + 1])
    }
    #endif

    private func refresh() async {
        nudgesOn = NudgeSettings.enabled
        nudgeLevel = NudgeSettings.level
        lockHealth = SetupHealth(drawn: Wallpaper.lastRun, confirmed: Wallpaper.lastConfirmed)
        nudgeStatus = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    @ViewBuilder
    private func deeperScreen(_ which: Deeper) -> some View {
        let back = { deeper = nil }
        switch which {
        case .profile:
            ProfileScreen(store: store, themeStore: themeStore, onClose: back)
        case .feedback:
            FeedbackScreen(store: store, themeStore: themeStore, toasts: toasts, onClose: back)
        case .lockScreen:
            WallpaperSetup()
        case .account:
            SettingsPage(themeStore: themeStore, title: SettingsCopy.account,
                         note: localNoteText, onBack: back) {
                if let accountCard { accountCard() }
            }
        case .reminders:
            SettingsPage(themeStore: themeStore, title: SettingsCopy.reminders, onBack: back) {
                RemindersCard(store: store)
            }
        case .calendar:
            SettingsPage(themeStore: themeStore, title: SettingsCopy.calendar, onBack: back) {
                if let googleCard { googleCard() }
                if let meetings { MeetingsCard(meetings: meetings, connect: connectGoogle) }
            }
        }
    }

    // MARK: - the three groups

    /// Who you are: the face and the name, then where your lists live.
    private var you: some View {
        SettingsGroup {
            SettingsRow(title: Copy.Settings.profileRow,
                        value: greeting,
                        face: Avatars.face(store.doc.profile.avatar)) { deeper = .profile }

            SettingsRow(title: SettingsCopy.account,
                        value: isSignedIn ? SettingsCopy.signedIn : SettingsCopy.thisDevice,
                        divider: true) { deeper = .account }
        }
    }

    /// `paintProfile`'s half of the row: the greeting beside `Profile`,
    /// drawn from the same name the profile screen writes (app.js:3923).
    private var greeting: String {
        let name = store.doc.profile.name
        return name.isEmpty ? Copy.Settings.greetingPlain : Copy.Settings.greeting(name: name)
    }

    /// What the app does for you while it is closed.
    private var features: some View {
        SettingsGroup {
            SettingsRow(title: SettingsCopy.reminders,
                        value: remindersValue) { deeper = .reminders }

            if meetings != nil || googleCard != nil {
                SettingsRow(title: SettingsCopy.calendar,
                            value: calendarValue,
                            divider: true) { deeper = .calendar }
            }

            SettingsRow(title: LockScreenCopy.row,
                        value: lockScreenValue,
                        divider: true) { deeper = .lockScreen }
        }
    }

    /// "Off" when iOS says no, whatever the switch was left at: a level
    /// beside a refused permission would promise nudges that never ring.
    private var remindersValue: String {
        let allowed = [.authorized, .provisional, .ephemeral].contains(nudgeStatus)
        return nudgesOn && allowed ? nudgeLevel.note : SettingsCopy.off
    }

    private var calendarValue: String? {
        guard let meetings else { return nil }
        guard meetings.enabled else { return SettingsCopy.off }
        return meetings.access == .granted ? SettingsCopy.on : SettingsCopy.notConnected
    }

    private var lockScreenValue: String {
        switch lockHealth.state {
        case .working: return SettingsCopy.on
        case .never: return SettingsCopy.off
        case .noConfirm, .unfinished, .stalled: return SettingsCopy.needsLook
        }
    }

    /// `About`: two screens, two pages, one share sheet.
    private var about: some View {
        SettingsGroup {
            SettingsRow(title: Copy.Settings.feedbackRow) { deeper = .feedback }

            SettingsRow(title: Copy.Settings.shareRow,
                        divider: true,
                        disclosure: false) { ShareApp.present() }

            SettingsRow(title: Copy.Settings.privacyRow,
                        divider: true) { legal = .privacy }

            SettingsRow(title: Copy.Settings.termsRow,
                        divider: true) { legal = .terms }
        }
    }

    // MARK: - the footer

    /// `paintLocalNote` (app.js:3677-3693). Three readings of where the
    /// lists actually live, and the true one depends on the two flags
    /// above. It sits under the Account card now, beside what it is about.
    private var localNoteText: String {
        if isSignedIn { return Copy.Settings.localSignedIn }
        if isCalendarConfigured { return Copy.Settings.localCalendar }
        return Copy.Settings.localAlone
    }

    /// `.version` — the last line on the last screen. Stone, never
    /// orange: it is a label, not a signal to act on.
    private var version: some View {
        HStack(spacing: 7) {
            Text(Copy.Settings.version)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(theme.faint)

            Text(Copy.Settings.versionTag.uppercased())
                .font(Font.baloo(10.5, .bold))
                .kerning(0.07 * 10.5)
                .foregroundStyle(theme.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .overlay(Capsule().strokeBorder(theme.lineStrong, lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - a page one tap in

/// The bar, back to Settings, and whatever the row opened. The note under
/// it is fine print, the way a footer sits under a group in iOS Settings.
struct SettingsPage<Content: View>: View {

    @Environment(\.theme) private var theme

    let themeStore: ThemeStore
    let title: String
    var note: String? = nil
    var onBack: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            SettingsBar(themeStore: themeStore,
                        backLabel: Copy.Profile.back,
                        backAria: Copy.Profile.backAria,
                        title: title,
                        onBack: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content

                    if let note {
                        Text(note)
                            .font(.system(size: 13))
                            .lineSpacing(13 * 0.5)
                            .foregroundStyle(theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                    }
                }
                .frame(maxWidth: Theme.measure, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, Theme.gutter(UIScreen.main.bounds.width))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.surface.ignoresSafeArea())
    }
}

// MARK: - the bar all three of these screens wear

/// `header.brand.brand--sm` (app.html:663-673). Where you came from at the
/// left, where you are in the middle, and the theme toggle at the right.
///
/// The title is centred on the SCREEN and not on what the other two left
/// over — `.screen-title` is absolutely positioned for exactly that reason
/// (styles.css:914), and a `ZStack` is the same decision.
struct SettingsBar: View {

    @Environment(\.theme) private var theme

    let themeStore: ThemeStore
    let backLabel: String
    let backAria: String
    let title: String
    var onBack: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(Font.baloo(17, .heavy))
                .kerning(-0.02 * 17)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .allowsHitTesting(false)

            HStack(spacing: 10) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                        Text(backLabel)
                            .font(Font.baloo(14.5, .semibold))
                    }
                    .foregroundStyle(theme.muted)
                    .padding(.leading, 4)
                    .padding(.trailing, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(backAria)

                Spacer(minLength: 10)

                Button { themeStore.toggle() } label: {
                    Image(systemName: themeStore.toggleSymbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.muted)
                        .frame(width: 34, height: 34)
                        .overlay(
                            Circle().strokeBorder(
                                themeStore.isDark ? theme.accent : theme.orange,
                                lineWidth: 1.5
                            )
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(themeStore.toggleLabel)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 12)      // .brand--sm
    }
}

// MARK: - the furniture

/// `.settings-group` — one tinted block, rows inside it, hairlines between
/// them, and the radius on the block rather than on any row. No border:
/// the wash against the white page is the edge.
struct SettingsGroup<Content: View>: View {

    @Environment(\.theme) private var theme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(theme.wash)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
    }
}

/// `.set-row`, as a plain list row: the name on the left, what it is set
/// to on the right, then the chevron. No icon tiles — the words are the
/// row — except the face on Profile, so the way into it looks like the
/// thing it opens (app.js:3921).
struct SettingsRow: View {

    @Environment(\.theme) private var theme

    let title: String
    var value: String? = nil
    var face: String? = nil
    /// Every row but the first draws the hairline above it, inset to
    /// where the text starts.
    var divider: Bool = false
    /// A chevron means another screen. The share sheet is not one.
    var disclosure: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let face {
                    Text(face)
                        .font(.system(size: 22))
                        .frame(width: 34, height: 34)
                }

                Text(title)
                    .font(Font.baloo(16, .semibold))
                    .foregroundStyle(theme.ink)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                if let value {
                    Text(value)
                        .font(Font.baloo(15, .medium))
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if disclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.faint)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: face == nil ? 52 : 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .overlay(alignment: .top) {
            if divider {
                Rectangle()
                    .fill(theme.line)
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
    }
}

// MARK: - meetings

/// The switch that reads your Google Calendar, under `Sync calendars`
/// and beside the Google card rather than inside it.
///
/// **They are two different decisions and they only look alike.** The
/// Google card settles where your tasks go; this settles whether the app
/// may look at the day you already have. One writes, one reads.
///
/// On, with no Google to read — signed out, or signed in on a grant that
/// predates the read scope — the row under it says so and offers the one
/// sign-in that fixes it, rather than a switch that is on and draws
/// nothing.
struct MeetingsCard: View {

    @Environment(\.theme) private var theme

    let meetings: MeetingReader
    var connect: (() async -> Void)? = nil

    @State private var connecting = false

    var body: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: 0) {
                Toggle(isOn: Binding(get: { meetings.enabled },
                                     set: { meetings.enabled = $0 })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Copy.Meetings.switchTitle)
                            .font(Font.baloo(15.5, .bold))
                            .kerning(-0.015 * 15.5)
                            .foregroundStyle(theme.ink)

                        Text(Copy.Meetings.switchNote)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .tint(theme.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if meetings.enabled {
                    switch meetings.access {
                    case .granted:     readRow
                    case .signedOut:   connectRow(Copy.Meetings.signedOutNote)
                    case .needsGoogle: connectRow(Copy.Meetings.needsGoogleNote)
                    }
                }
            }
        }
    }

    private var readRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Copy.Meetings.readNote(meetings.calendars, meetings.found))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.faint)
            Text(Copy.Meetings.footnote)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.faint)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(meetings.fetching ? 0.5 : 1)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.line).frame(height: 1.5)
        }
    }

    private func connectRow(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let connect {
                Button {
                    connecting = true
                    Task {
                        await connect()
                        connecting = false
                    }
                } label: {
                    Text(Copy.Meetings.connect)
                        .font(Font.baloo(13.5, .bold))
                        .foregroundStyle(theme.accent)
                        .underline()
                }
                .buttonStyle(.plain)
                .disabled(connecting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.line).frame(height: 1.5)
        }
    }
}

// MARK: - the two pages that are pages

/// `/privacy` and `/terms`, which on the web are ordinary links and in the
/// shell have always stayed inside the app (`AppConfig.inAppPaths`). A
/// Safari sheet keeps them there without this project growing a second
/// browser: the address bar is Apple's, the cookies are not ours, and the
/// Done button comes back here.
enum LegalPage: String, Identifiable {
    case privacy, terms
    var id: String { rawValue }

    var url: URL {
        URL(string: "/\(rawValue)", relativeTo: AppConfig.home)!.absoluteURL
    }
}

/// `SFSafariViewController` in a sheet. Apple's own chrome, so the person
/// can see whose page they are reading — which is the same reason
/// `WebScreen` hands every off-host link to Safari.
struct SafariSheet: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.preferredControlTintColor = AppConfig.accent
        vc.dismissButtonStyle = .done
        return vc
    }

    /// Nothing about a Safari sheet is worth updating in place: a new url
    /// is a new sheet.
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
