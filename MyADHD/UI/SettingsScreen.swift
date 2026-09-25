/* ============================================================
   MyADHD/UI/SettingsScreen.swift — four things nobody opens twice

   `showSettings` / `paintSettings` (app.js:3944-3964), `paintLocalNote`
   (app.js:3677-3693), `#screen-settings` (app.html:662-850),
   inventory §1.11.

   **What is deliberately not here.** No Subscription group, no Plans
   screen and no donate tin. That is design §4, decision 4: App Store
   guideline 3.1.1 wants any purchase inside the app to go through
   StoreKit, nothing in my.adhd is gated behind a plan, and a payment
   surface for a thing that unlocks nothing is a review rejection in
   exchange for no feature at all. `Copy` carries no strings for them
   either — a literal in that file is a promise that something draws it.

   **Two seams.** The Account card (§1.12) and the Google Calendar card
   (§1.13) are another agent's files, in `MyADHD/Sync/`. They mount
   through `accountCard` and `googleCard` below, and their two facts —
   whether there is an account and whether a calendar is configured —
   come in as flags rather than being guessed at here, because
   `paintLocalNote` picks one of three sentences off exactly those two
   and a screen that invented an answer would tell somebody their lists
   were somewhere they are not. Both default to nothing and false, so
   this screen is correct on its own: no cards, and the note that says
   this device and nowhere else.

   **The captions stay whether or not the cards are there.** That is the
   web: `#gcal-card` and `#acct-card` carry `is-hidden`, the
   `.settings-section` around them never does. A caption over an empty
   space is what the web shows somebody with no Google client id
   configured, so it is what this shows.

   **The version is the web's literal, not the bundle's.** app.html
   writes `v0.1.0` and `Beta` into the markup; `CFBundleShortVersionString`
   is the shell's own number and has never been the one on this line.
   Drawing the bundle here would make the footer disagree with the same
   footer on the web for the same person.
   ============================================================ */

import SafariServices
import SwiftUI

struct SettingsScreen: View {

    @Environment(\.theme) private var theme

    let store: AppStore
    let themeStore: ThemeStore
    let toasts: ToastCenter

    /// `#btn-settings-back` — back to home.
    var onClose: () -> Void

    // MARK: - the seams

    /* SEAM — the Account card, `#acct-card` (inventory §1.12,
       app.html:714-753, app.js:3593-3826). It is being built
       concurrently in `MyADHD/Sync/AccountCard.swift`; wiring it up is
       one line at the call site:

           SettingsScreen(store: store, …, accountCard: { AnyView(AccountCard(…)) },
                          isSignedIn: auth.signedIn)

       It belongs INSIDE the Account section, under the Profile group and
       above the section break — that is where app.html has it, and the
       caption above it is already drawn. */
    var accountCard: (() -> AnyView)?

    /* SEAM — the Google Calendar card, `#gcal-card` (inventory §1.13,
       app.html:757-792, app.js:3447-3568), including the duplicate
       calendar block. Same arrangement, under the `Sync calendars`
       caption. `checkDuplicateCalendars()` runs behind the screen on
       open (app.js:3962) and is that card's business, not this one's. */
    var googleCard: (() -> AnyView)?

    /// `auth.configured() && auth.signedIn()` — the first half of
    /// `paintLocalNote`'s question.
    var isSignedIn: Bool = false

    /// `gcal.configured()` — the second half. Configured, note, not
    /// linked: the web asks whether the card is on the screen at all.
    var isCalendarConfigured: Bool = false

    /// The meetings already on this phone, and the switch that turns them
    /// on. Nothing to do with the Google card above it — that one is a
    /// wiring decision about where your tasks go, and this one is a read
    /// of the calendar iOS already has.
    var meetings: MeetingReader? = nil

    // MARK: - one tap deeper (app.js:4087-4101)

    /// Three screens rather than three panes. `fullScreenCover` is the
    /// same fact `show()` is on the web: while you are on one of these,
    /// the tab bar is down and there is nowhere else to be.
    private enum Deeper: String, Identifiable {
        case profile, feedback
        var id: String { rawValue }
    }
    @State private var deeper: Deeper?

    /// `<a href="/privacy">` and `<a href="/terms">`. Both are pages on
    /// our own host that the shell has always kept inside the app
    /// (`AppConfig.inAppPaths`), so they open in a Safari sheet rather
    /// than throwing somebody out to the browser mid-settings.
    @State private var legal: LegalPage?

    var body: some View {
        VStack(spacing: 0) {
            SettingsBar(themeStore: themeStore,
                        backLabel: Copy.Settings.back,
                        backAria: Copy.Settings.backAria,
                        title: Copy.Settings.title,
                        onBack: onClose)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    account
                    sync
                    reminders
                    about
                    localNote
                    version
                }
                .frame(maxWidth: Theme.measure, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, 22)      // .settings-wrap padding-top
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, Theme.gutter(UIScreen.main.bounds.width))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.surface.ignoresSafeArea())
        .toastLayer(toasts, hasTabBar: false)
        .fullScreenCover(item: $deeper) { which in
            deeperScreen(which)
                .environment(\.theme, theme)
                .preferredColorScheme(themeStore.colorScheme)
        }
        .sheet(item: $legal) { page in
            SafariSheet(url: page.url)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func deeperScreen(_ which: Deeper) -> some View {
        switch which {
        case .profile:
            ProfileScreen(store: store, themeStore: themeStore) { deeper = nil }
        case .feedback:
            FeedbackScreen(store: store, themeStore: themeStore, toasts: toasts) {
                deeper = nil
            }
        }
    }

    // MARK: - the groups, in app.html's order

    /// `Account`: the profile row, and the account card behind it.
    private var account: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCaption(Copy.Settings.capAccount)

            SettingsGroup {
                SettingsRow(mark: .face(Avatars.face(store.doc.profile.avatar)),
                            title: Copy.Settings.profileRow,
                            note: greeting) { deeper = .profile }
            }

            if let accountCard {
                accountCard()
                    .padding(.top, 14)
            }
        }
    }

    /// `paintProfile`'s half of the row: the greeting under `Profile`,
    /// drawn from the same name the profile screen writes (app.js:3923).
    private var greeting: String {
        let name = store.doc.profile.name
        return name.isEmpty ? Copy.Settings.greetingPlain : Copy.Settings.greeting(name: name)
    }

    /// `Sync calendars`. A group of its own rather than a row in the one
    /// above it: both are Google and they look alike on purpose, but one
    /// is who you are and the other is a wiring decision (app.html:755).
    private var sync: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCaption(Copy.Settings.capSync)
            if let googleCard { googleCard() }
            if let meetings {
                MeetingsCard(meetings: meetings)
                    .padding(.top, googleCard == nil ? 0 : 14)
            }
        }
        .padding(.top, 26)      // .settings-section + .settings-section
    }

    /// The nudges, and the one permission every notification here shares.
    /// Its own group: nothing to do with an account or a calendar, and
    /// the web has no section like it to line up with.
    private var reminders: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCaption(Copy.Nudges.caption)
            RemindersCard(store: store)
        }
        .padding(.top, 26)      // .settings-section + .settings-section
    }

    /// `About`: two screens, two pages, one share sheet.
    private var about: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCaption(Copy.Settings.capAbout)

            SettingsGroup {
                SettingsRow(mark: .symbol("heart"),
                            title: Copy.Settings.feedbackRow,
                            note: Copy.Settings.feedbackNote) { deeper = .feedback }

                SettingsRow(mark: .symbol("square.and.arrow.up"),
                            title: Copy.Settings.shareRow,
                            note: Copy.Settings.shareNote,
                            divider: true) { ShareApp.present() }

                SettingsRow(mark: .symbol("lock.shield"),
                            title: Copy.Settings.privacyRow,
                            divider: true) { legal = .privacy }

                SettingsRow(mark: .symbol("doc.text"),
                            title: Copy.Settings.termsRow,
                            divider: true) { legal = .terms }
            }
        }
        .padding(.top, 26)
    }

    // MARK: - the footer

    /// `paintLocalNote` (app.js:3677-3693). Three readings of where the
    /// lists actually live, and the true one depends on the two flags
    /// above.
    private var localNote: some View {
        Text(localNoteText)
            .font(.system(size: 13))
            .lineSpacing(13 * 0.5)
            .foregroundStyle(theme.faint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 18)      // .settings-wrap .hint
    }

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
        .padding(.top, 16)
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

/// `.eyebrow.settings-cap` — 11px uppercase, nudged 4px in from the card
/// edge below it (styles.css:767).
struct SettingsCaption: View {

    @Environment(\.theme) private var theme
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Font.baloo(11, .bold))
            .kerning(0.13 * 11)
            .foregroundStyle(theme.faint)
            .padding(.leading, 4)
            .padding(.bottom, 10)
    }
}

/// `.settings-group` — one card, rows inside it, hairlines between them,
/// and the radius on the card rather than on any row.
struct SettingsGroup<Content: View>: View {

    @Environment(\.theme) private var theme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1.5)
            )
    }
}

/// `.set-row`. A 34pt rounded glyph — or the chosen face — then the title
/// and its note, then the chevron.
struct SettingsRow: View {

    @Environment(\.theme) private var theme

    /// `.set-row-mark` carries an icon; `.set-row-mark--face` carries the
    /// avatar instead, so the way into the profile screen looks like the
    /// thing it opens (app.js:3921).
    enum Mark {
        case symbol(String)
        case face(String)
    }

    let mark: Mark
    let title: String
    var note: String?
    /// `.set-row + .set-row::before` — every row but the first draws the
    /// hairline above it, inset to where the text starts (16 + 34 + 13).
    var divider: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                glyph

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Font.baloo(15.5, .bold))
                        .kerning(-0.015 * 15.5)
                        .foregroundStyle(theme.ink)

                    if let note {
                        Text(note)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(theme.faint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.lineStrong)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if divider {
                Rectangle()
                    .fill(theme.line)
                    .frame(height: 1.5)
                    .padding(.leading, 63)
            }
        }
    }

    private var glyph: some View {
        Group {
            switch mark {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.accent)
            case .face(let face):
                Text(face)
                    .font(.system(size: 17))
            }
        }
        .frame(width: 34, height: 34)
        .background(theme.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.lineStrong, lineWidth: 1.5)
        )
    }
}

// MARK: - meetings

/// The switch that reads this phone's calendar, under `Sync calendars`
/// and beside the Google card rather than inside it.
///
/// **They are two different decisions and they only look alike.** The
/// Google card settles where your tasks go; this settles whether the app
/// may look at the day you already have. One writes, one reads, and
/// neither needs the other — somebody with no Google account at all can
/// turn this on, because what it reads is whatever iOS has.
///
/// The switch asks for the permission the first time it is moved, and
/// puts itself back if the answer is no. It has to: iOS shows its prompt
/// exactly once, so a switch left standing on after a refusal would be a
/// control that says the feature is on while it draws nothing.
struct MeetingsCard: View {

    @Environment(\.theme) private var theme

    let meetings: MeetingReader

    @State private var asking = false

    var body: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: 0) {
                Toggle(isOn: binding) {
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
                .disabled(asking)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if denied { deniedRow } else if reading { readRow }
            }
        }
    }

    /// Refused once, and iOS will not ask again. The row is shown only
    /// when the switch is on, because somebody who has left it off is not
    /// being blocked by anything and does not need to be told about
    /// Settings.
    private var denied: Bool {
        meetings.enabled && meetings.access == .denied
    }

    /// On and allowed — so the switch is doing its job, and the only
    /// question left is why the day looks the way it does. Off needs no
    /// numbers, and refused has a row of its own that says more, which is
    /// why this is the `else` of that one rather than a second row under it.
    private var reading: Bool {
        meetings.enabled && meetings.access == .granted
    }

    private var readRow: some View {
        Text(Copy.Meetings.readNote(meetings.calendars, meetings.found))
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(theme.faint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .overlay(alignment: .top) {
                Rectangle().fill(theme.line).frame(height: 1.5)
            }
    }

    private var deniedRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Copy.Meetings.deniedNote)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: openSettings) {
                Text(Copy.Meetings.openSettings)
                    .font(Font.baloo(13.5, .bold))
                    .foregroundStyle(theme.accent)
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.line).frame(height: 1.5)
        }
    }

    /// Turning it on is an async question with a refusal for an answer,
    /// which a plain `$meetings.enabled` cannot express.
    private var binding: Binding<Bool> {
        Binding(
            get: { meetings.enabled },
            set: { want in
                guard want else { meetings.enabled = false; return }
                /* On before the prompt, so the switch does not sit still
                   under a finger while iOS decides — and off again below
                   if the answer is no. */
                meetings.enabled = true
                guard meetings.access == .notDetermined else { return }
                asking = true
                Task {
                    let answer = await meetings.requestAccess()
                    asking = false
                    if answer == .denied { meetings.enabled = false }
                }
            }
        )
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
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
