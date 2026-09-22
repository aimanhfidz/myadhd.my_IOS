/* ============================================================
   MyADHD/UI/HomeScreen.swift — what you land on

   app.html:199-291, app.js:4131-4247, inventory §1.2.

   Two screens in one element, chosen by `coldStart()` — no tasks AND no
   notes. A first visit gets the meme, the question and one button, because
   five zeroes and a heading that says "nothing" is a worse welcome than a
   blank page. Everything else gets the widgets.

   The two widgets are `HOME_WIDGETS = [paintToday, paintStats]`, in that
   order, and both are drawn from `Ordering` rather than from anything
   worked out here:

   - **Today** is `Ordering.homeToday`: late, then what is on today, then
     everything open by deadline — deduped by id, three at most. This is
     the answer to "what now", and a list of ten is the question again.
   - **The five numbers** are `Ordering.stats`.

   Two details that look like bugs and are not:

   - A row's meta prints **raw minutes**, `${t.minutes} min` (app.js:4221),
     where the lists print `minutesLabel`. A 90-minute task therefore reads
     "90 min" here and "1.5 hr" one tab over. `Copy.Home.rowMeta` is the
     only builder of that line so the difference cannot be tidied away by
     accident.
   - A row is **read-only**. A tick here would be a second checkbox with a
     second undo path behind it; the row is a signpost, and tapping it goes
     to the lists where the task can actually be worked on.

   The tab bar stays up on a cold start. It used to hide, back when the
   dump box was on this screen; the + is the only way in now, and hiding it
   would leave a new arrival on a page with no way forward.
   ============================================================ */

import SwiftUI

struct HomeScreen: View {

    @Environment(\.theme) private var theme

    let store: AppStore
    let themeStore: ThemeStore

    /// The meetings already on this phone. Silent until the switch in
    /// Settings is on, and the card is then exactly what it was.
    var meetings: MeetingReader? = nil

    /// `#btn-settings`, `#btn-start-dump` / `#tab-add`, and the row tap
    /// (`goToNext`). Handed in because none of the three is home's to do.
    var openSettings: () -> Void
    var openComposer: () -> Void
    var goToLists: () -> Void

    var today: String = WebDates.dayKey()

    var body: some View {
        VStack(spacing: 0) {
            HomeHeader(themeStore: themeStore, openSettings: openSettings)

            if coldStart {
                ColdStart(openComposer: openComposer)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        TodayCard(card: card,
                                  today: today,
                                  meetings: soon,
                                  goToLists: goToLists)
                        StatRow(stats: stats)
                    }
                    .padding(.top, 26)
                    .frame(maxWidth: Theme.measure)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, Theme.gutter(UIScreen.main.bounds.width))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.surface.ignoresSafeArea())
    }

    /// app.js:4156-4158. Notes count too: somebody who has written a note
    /// and no task has used the app, and should not be shown the front door
    /// again.
    private var coldStart: Bool {
        store.doc.tasks.isEmpty && store.doc.notes.isEmpty
    }

    private var card: Ordering.HomeToday {
        Ordering.homeToday(store.doc.tasks, today: today)
    }

    private var stats: Ordering.Stats {
        Ordering.stats(store.doc.tasks, today: today)
    }

    /// Today's meetings, and today's only. The card is about the next
    /// few hours; a meeting on Friday belongs on the calendar, not in the
    /// answer to what is next.
    private var soon: [Meeting] {
        AgendaEntry.unclaimed(meetings?.on(today) ?? [], by: store.doc.tasks)
    }
}

// MARK: - the header

/// `<header class="brand">`: the only gear in the app and the theme
/// toggle, with the screen's own name where the lockup used to be. The web
/// header carried `my.adhd` and an `<a href="/">` that loses its href in
/// standalone mode (app.js:5076-5086); an app has no site to go back to and
/// says its name on the icon you tapped, so the wordmark is gone and
/// `ScreenHeader` puts "Home" in its place. See that file for the argument.
struct HomeHeader: View {

    @Environment(\.theme) private var theme
    let themeStore: ThemeStore
    var openSettings: () -> Void

    var body: some View {
        ScreenHeader(title: Copy.ScreenTitle.home) {
            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.muted)
                    .frame(width: 34, height: 34)
                    .overlay(Circle().strokeBorder(theme.loudEdge, lineWidth: 1.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.Home.settingsAria)

            Button { themeStore.toggle() } label: {
                Image(systemName: themeStore.toggleSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.muted)
                    .frame(width: 34, height: 34)
                    /* The ring borrows orange in the light theme and the
                       accent at night. The one exception in the app: orange
                       is the signal colour, so the toggle takes it for the
                       ring alone and never for a fill (theme.css). */
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
        .background(theme.surface)
    }
}

/// `#logo-mark`: a four-ray asterisk in Vivid Orange with one short ray,
/// and the capsule's stroke in violet. Four rectangles and a line, at the
/// coordinates app.html:171-179 gives them in a 100-unit box.
///
/// **Nothing draws this any more.** It came out of the header when the
/// screen's own name took that place. It is the mark, written down once in
/// SwiftUI, and it is kept for the next thing that needs it — not dead code
/// somebody forgot.
struct LogoMark: View {

    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 100
            ZStack {
                ray(64, angle: 0, s: s)
                ray(64, angle: 90, s: s)
                ray(64, angle: 45, s: s)
                /* the short one: half the length, and it is what stops the
                   mark reading as a snowflake */
                ray(32, angle: -45, s: s)

                Path { p in
                    p.move(to: CGPoint(x: 64.5 * s, y: 64.5 * s))
                    p.addLine(to: CGPoint(x: 71.5 * s, y: 71.5 * s))
                }
                .stroke(theme.violet, style: StrokeStyle(lineWidth: 7 * s, lineCap: .round))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// `<rect x="46.5" y="18" width="7" height="h" transform="rotate(a 50 50)">`
    ///
    /// `position` places the bar's own centre in the 100-unit box; the
    /// rotation is then about the centre of the box itself, which is the
    /// 50,50 the SVG rotates about.
    private func ray(_ height: CGFloat, angle: Double, s: CGFloat) -> some View {
        Rectangle()
            .fill(theme.orange)
            .frame(width: 7 * s, height: height * s)
            .position(x: 50 * s, y: (18 + height / 2) * s)
            .rotationEffect(.degrees(angle), anchor: .center)
    }
}

// MARK: - the cold start

/// app.html:241-254. The meme, the question, the promise, one button.
struct ColdStart: View {

    @Environment(\.theme) private var theme
    var openComposer: () -> Void

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                /* On a short screen the joke steps out of the way — the
                   button matters more (styles.css @media max-height:720). */
                if geo.size.height > 560, let meme = BundleImage.welcomeMeme {
                    Image(uiImage: meme)
                        .resizable()
                        .aspectRatio(642.0 / 389.0, contentMode: .fit)
                        .frame(maxWidth: 400)
                        .background(theme.wash)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg,
                                                    style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
                                .strokeBorder(theme.line, lineWidth: 1.5)
                        )
                        .padding(.bottom, 20)
                        .accessibilityLabel(Copy.Home.welcomeAlt)
                }

                /* `clamp(23px, 6vw, 38px)`, one line, `text-wrap: nowrap`
                   — it has to survive a 320px phone. */
                let headline = min(38, max(23, geo.size.width * 0.06))
                Text(Copy.Home.headline)
                    .font(Font.baloo(headline, .heavy))
                    .kerning(-0.04 * headline)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 12)

                Text(Copy.Home.startHint)
                    .font(Font.baloo(13))
                    .foregroundStyle(theme.faint)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 22)

                Button(action: openComposer) {
                    Text(Copy.Home.startButton)
                        .font(Font.baloo(16.5, .bold))
                        .kerning(-0.01 * 16.5)
                        .foregroundStyle(Color(hex: 0xFFFFFF))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .padding(.horizontal, 24)
                        .background(theme.brandGradient, in: Capsule())
                        .shadow(color: theme.loudCast.color,
                                radius: theme.loudCast.radius,
                                y: theme.loudCast.y)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(.top, 26)
            .frame(maxWidth: Theme.measure)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - what is actually next

struct TodayCard: View {

    @Environment(\.theme) private var theme
    let card: Ordering.HomeToday
    let today: String
    /// Today's, already filtered of any that has become a task.
    var meetings: [Meeting] = []
    var goToLists: () -> Void

    /// **`Ordering.homeToday` is not touched.** It is checked line for
    /// line against the web's own `paintToday`
    /// (`Checks/parity-ordering.sh`), and a meeting is a thing the web has
    /// never heard of — teaching that function about one would put the
    /// port and its original permanently out of step for no gain.
    ///
    /// So the merge happens here instead, and it is the same rule
    /// `homeToday` already sorts by: the deadline. A meeting at nine sits
    /// ahead of a task due at five, something already late stays on top
    /// of both, and a task with no day at all still sorts last. The cap
    /// is the same three, so a morning full of meetings can push a task
    /// off the card — which is the truth the card exists to tell.
    private var rows: [AgendaEntry] {
        guard !meetings.isEmpty else { return card.next.map(AgendaEntry.task) }
        let entries = card.next.map(AgendaEntry.task) + meetings.map(AgendaEntry.meeting)
        let sorted = Ordering.stableSorted(entries) { a, b in
            let l = Self.due(a), r = Self.due(b)
            if l == r { return nil }
            return l < r
        }
        return Array(sorted.prefix(Ordering.homeNextMax))
    }

    /// `Ordering.dueAt`'s number, for either kind of row. An all-day
    /// meeting sorts from the start of its day, because it is already
    /// true at breakfast; an undated task sorts last, because it is not
    /// due at all.
    private static func due(_ entry: AgendaEntry) -> Double {
        switch entry {
        case .task(let t):
            return Ordering.dueAt(t)
        case .meeting(let m):
            let day = m.when.replacingOccurrences(of: "-", with: "")
            let clock = m.at?.replacingOccurrences(of: ":", with: "") ?? "0000"
            return Double(day + clock) ?? .infinity
        }
    }

    private var showsEmpty: Bool { rows.isEmpty }

    /// The card is showing everything only when nothing is left over on
    /// either side.
    private var showsMore: Bool {
        card.open.count + meetings.count > rows.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(card.title)
                    .font(Font.baloo(17, .heavy))
                    /* The one place on this screen orange is allowed: the
                       heading says "3 late" or it says "Today", and only the
                       first of those is news. */
                    .foregroundStyle(card.isLate ? theme.orange : theme.ink)

                Spacer(minLength: 10)

                if showsMore {
                    Button(action: goToLists) {
                        Text(Copy.Home.more)
                            .font(Font.baloo(13, .semibold))
                            .foregroundStyle(theme.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 14)

            if showsEmpty {
                Text(Copy.Home.empty)
                    .font(Font.baloo(14))
                    .foregroundStyle(theme.muted)
            } else {
                VStack(spacing: 8) {
                    ForEach(rows) { row in
                        switch row {
                        case .task(let t):
                            HomeTaskRow(task: t, today: today, tap: goToLists)
                        case .meeting(let m):
                            HomeMeetingRow(meeting: m, today: today)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                        .fill(theme.loudGlass)
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(theme.loudEdge, lineWidth: 1.5)
        )
        .shadow(color: theme.loudCast.color,
                radius: theme.loudCast.radius,
                y: theme.loudCast.y)
    }
}

/// A signpost, not a task row: no tick, no swipe, no chips.
struct HomeTaskRow: View {

    @Environment(\.theme) private var theme
    let task: TaskItem
    let today: String
    var tap: () -> Void

    private var late: Bool { Ordering.rowIsLate(task, today: today) }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 0) {
                /* A 2.5px rule down the left, drawn as its own shape rather
                   than a one-sided border: under a corner radius a
                   border-left is tapered around all four corners and reads
                   as four stray arcs. */
                Capsule()
                    .fill(late ? theme.orange : theme.lineStrong)
                    .frame(width: 2.5)
                    .padding(.vertical, 9)

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(Font.baloo(14.5, .semibold))
                        .foregroundStyle(theme.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(meta)
                        .font(Font.baloo(12.5))
                        .foregroundStyle(late ? theme.orange : theme.faint)
                }
                .padding(.leading, 13.5)
                .padding(.trailing, 12)
                .padding(.vertical, 9)

                Spacer(minLength: 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// `[whenLabel(t, today), `${t.minutes} min`].filter(Boolean).join(' · ')`
    /// — and the minutes are raw. See the file header.
    private var meta: String {
        Copy.Home.rowMeta(
            when: WebDates.whenLabel(when: task.when, at: task.at, today: today),
            minutes: task.minutes
        )
    }
}

/// The same signpost for an hour you did not choose. Not a button: a
/// task row goes to the lists because there is something to do about it
/// there, and there is nothing my.adhd can do about a meeting.
struct HomeMeetingRow: View {

    @Environment(\.theme) private var theme
    let meeting: Meeting
    let today: String

    var body: some View {
        HStack(spacing: 0) {
            /* The rule is `lineStrong` and never orange. A meeting cannot
               be late — it happens whether or not you are ready — and
               orange on this screen has exactly one meaning. */
            Capsule()
                .fill(theme.lineStrong)
                .frame(width: 2.5)
                .padding(.vertical, 9)

            VStack(alignment: .leading, spacing: 3) {
                /* **The glyph is not decoration.** A task row here is a
                   button into the lists and this one is not, so the two
                   have to be tellable apart before they are tapped —
                   otherwise the difference between them is a tap that
                   silently does nothing. It is the same mark the agenda
                   puts where the tick would be, for the same reason. */
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.muted)
                        .accessibilityHidden(true)

                    Text(meeting.title)
                        .font(Font.baloo(14.5, .semibold))
                        .foregroundStyle(theme.inkSoft)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(meta)
                    .font(Font.baloo(12.5))
                    .foregroundStyle(theme.faint)
            }
            .padding(.leading, 13.5)
            .padding(.trailing, 12)
            .padding(.vertical, 9)

            Spacer(minLength: 0)
        }
    }

    /// The calendar it came off leads, then the row's usual when and how
    /// long — `Work · Today · 9.30am · 60 min`. Both halves are already
    /// `metaSeparator` joins, so this is composition and not a new
    /// sentence.
    private var meta: String {
        guard !meeting.isAllDay else {
            return Copy.Meetings.allDayMeta(calendar: meeting.calendarTitle)
        }
        return Copy.Meetings.meta(
            calendar: meeting.calendarTitle,
            minutes: Copy.Home.rowMeta(
                when: WebDates.whenLabel(when: meeting.when, at: meeting.at, today: today),
                minutes: meeting.minutes
            )
        )
    }
}

// MARK: - the five numbers

/// Pinned to two columns at every width, with overdue across the foot.
/// `auto-fit` was picking three at 430px and one at 320px off the same
/// rule, which made the same five numbers a different shape on every phone.
struct StatRow: View {

    @Environment(\.theme) private var theme
    let stats: Ordering.Stats

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                tile(stats.open, Copy.Home.statOpen)
                tile(stats.done, Copy.Home.statDone)
            }
            HStack(spacing: 10) {
                tile(stats.lists, Copy.Home.statLists)
                tile(stats.dated, Copy.Home.statDated)
            }
            /* Overdue takes the whole row: it is the odd one out of five and
               the only card here that is ever bad news, so it reads better
               as its own line than as a stray fifth tile. Shown at zero
               rather than hidden — a card that only appears when things have
               gone wrong makes its own arrival alarming. */
            tile(stats.overdue, Copy.Home.statOverdue, late: stats.overdueIsLate)
        }
    }

    private func tile(_ n: Int, _ label: String, late: Bool = false) -> some View {
        VStack(spacing: 4) {
            Text(String(n))
                .font(Font.baloo(26, .heavy))
                .kerning(-0.03 * 26)
                .foregroundStyle(late ? theme.orange : theme.ink)
            Text(label)
                .font(Font.baloo(12.5))
                .foregroundStyle(theme.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .background(late ? theme.dangerWash : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
                .strokeBorder(late ? theme.orange : theme.line, lineWidth: 1.5)
        )
    }
}

// MARK: - the two pictures that ship in the bundle

/// `welcome-meme.jpg` and the two morph clips are loose files under
/// `MyADHD/Media/`, not asset-catalogue entries — they are copies of the
/// web app's own files and they are replaced by copying them again, which
/// an `.imageset` wrapper would only get in the way of.
enum BundleImage {
    static let welcomeMeme: UIImage? = {
        guard let url = Bundle.main.url(forResource: "welcome-meme", withExtension: "jpg"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return UIImage(data: data)
    }()
}
