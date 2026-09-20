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

    /// `#btn-settings`, `#btn-start-dump` / `#tab-add`, and the row tap
    /// (`goToNext`). Handed in because none of the three is home's to do.
    var openSettings: () -> Void
    var openComposer: () -> Void
    var goToLists: () -> Void

    var today: String = WebDates.dayKey()

    var body: some View {
        VStack(spacing: 0) {
            BrandHeader(themeStore: themeStore, openSettings: openSettings)

            if coldStart {
                ColdStart(openComposer: openComposer)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        TodayCard(card: card, today: today, goToLists: goToLists)
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
        .background(theme.surface)
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
}

// MARK: - the header

/// `<header class="brand">`: the lockup, the only gear in the app, and the
/// theme toggle. On the web the lockup is an `<a href="/">` that loses its
/// href in standalone mode (app.js:5076-5086) — there is no site to go back
/// to from inside an app, so here it is simply never a link.
struct BrandHeader: View {

    @Environment(\.theme) private var theme
    let themeStore: ThemeStore
    var openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                LogoMark()
                    .frame(width: 26, height: 26)
                wordmark
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Copy.Home.brandAria)

            Spacer(minLength: 10)

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
        .padding(.bottom, 10)
        .frame(maxWidth: Theme.measure)
        .frame(maxWidth: .infinity)
        .background(theme.surface)
    }

    /// 16px / 700 / -.03em, with `.adhd` in `--violet` in both themes.
    private var wordmark: some View {
        (Text("my").foregroundColor(theme.ink)
            + Text(".adhd").foregroundColor(theme.violet))
            .font(Font.baloo(16, .bold))
            .kerning(-0.03 * 16)
    }
}

/// `#logo-mark`: a four-ray asterisk in Vivid Orange with one short ray,
/// and the capsule's stroke in violet. Four rectangles and a line, at the
/// coordinates app.html:171-179 gives them in a 100-unit box.
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
    var goToLists: () -> Void

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

                if card.showsMore {
                    Button(action: goToLists) {
                        Text(Copy.Home.more)
                            .font(Font.baloo(13, .semibold))
                            .foregroundStyle(theme.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 14)

            if card.showsEmpty {
                Text(Copy.Home.empty)
                    .font(Font.baloo(14))
                    .foregroundStyle(theme.muted)
            } else {
                VStack(spacing: 8) {
                    ForEach(card.next, id: \.id) { t in
                        HomeTaskRow(task: t, today: today, tap: goToLists)
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
