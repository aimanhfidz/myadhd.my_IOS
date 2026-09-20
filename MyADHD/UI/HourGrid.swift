/* ============================================================
   MyADHD/UI/HourGrid.swift — the Day and Week views

   BridgeScript.swift:855-1087 and the CSS at 346-390. Two shapes over one
   grid: Day is a week strip and a single column at 56pt an hour, Week is
   seven columns at 40pt an hour. Both carry the chips for whatever is on
   the day with no clock on it, and a red line across today at the hour it
   actually is.

   **One scroller, not two.** The grid used to scroll inside itself,
   inside the page, and a finger never knew which one it had. The page is
   the only scroller and the grid is simply tall — 24 hours at 56pt is
   1344pt of it — which is why entering the view scrolls to the working
   hours rather than starting at midnight. Keyed on the view alone: moving
   to another day keeps the hour you were reading.

   **What is drawn and what is not.** A block is a task on that day WITH a
   clock on it and not skipped — including finished ones, at 45% and
   struck through, because a day you have already worked through should
   look worked through. Everything on the day with no clock is a chip
   above the grid instead, six of them and then a count: they have no
   position in an hour grid and inventing one would be a lie about when
   they are.

   **`min(20)` on the length** is the web's: a zero-minute task still has
   to be tall enough to read, and the block never draws shorter than half
   an hour whatever the minutes say.
   ============================================================ */

import SwiftUI

// MARK: - the numbers

enum HourGridMetrics {
    /// `HH` — Day.
    static let day: CGFloat = 56
    /// `HHW` — Week.
    static let week: CGFloat = 40
    /// `GLIDE` on `cubic-bezier(.2,.8,.2,1)`, the same 220ms the month
    /// scroller uses.
    static let glideMS: TimeInterval = 0.220
    static var glide: Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: glideMS) }
    /// `Math.abs(moved) < 60` springs back.
    static let swipeCommit: CGFloat = 60
    /// The left edge belongs to the back gesture.
    static let edge: CGFloat = 22
    /// The hours column.
    static let gutter: CGFloat = 44
}

// MARK: - Day

struct CalDayPane: View {

    let tasks: [TaskItem]
    let today: String
    let session: CalendarSession

    @State private var dx: CGFloat = 0
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CalWeekStrip(base: session.picked, today: today) { session.pick($0) }
                .padding(.top, 2)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 0) {
                AnytimeChips(tasks: tasks, days: [session.picked])
                HourGridView(days: [session.picked],
                             tasks: tasks,
                             today: today,
                             hourHeight: HourGridMetrics.day,
                             compact: false)
            }
            .offset(x: dx)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CalSideSwipe(step: 1, session: session, dx: $dx, busy: $busy))
    }
}

// MARK: - Week

struct CalWeekPane: View {

    @Environment(\.theme) private var theme

    let tasks: [TaskItem]
    let today: String
    let session: CalendarSession

    @State private var dx: CGFloat = 0
    @State private var busy = false

    private var days: [String] { CalDays.week(of: session.picked) }

    var body: some View {
        let days = self.days
        VStack(alignment: .leading, spacing: 0) {
            colHead(days)
                .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 0) {
                AnytimeChips(tasks: tasks, days: days)
                HourGridView(days: days,
                             tasks: tasks,
                             today: today,
                             hourHeight: HourGridMetrics.week,
                             compact: true)
            }
            .offset(x: dx)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CalSideSwipe(step: 7, session: session, dx: $dx, busy: $busy))
    }

    /// `.myadhd-colhead` — the same 44pt gutter as the grid under it, so
    /// the seven names sit over their own columns.
    private func colHead(_ days: [String]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: HourGridMetrics.gutter, height: 1)
            ForEach(days, id: \.self) { key in
                let date = WebDates.keyToDate(key) ?? Date()
                let index = WebDates.calendar.component(.weekday, from: date) - 1
                let name = String(WebDates.dayNames[max(0, min(6, index))].prefix(3))
                (Text(name + " ").foregroundColor(theme.muted)
                    + Text("\(WebDates.calendar.component(.day, from: date))")
                        .foregroundColor(key == today ? theme.accent : theme.ink)
                        .font(Font.baloo(12, .bold)))
                    .font(Font.baloo(12))
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - swiping sideways

/// `swipeable(pane, step)` — a swipe left is forward in time. Horizontal
/// only: the first dozen points decide whether this is a swipe or a
/// scroll, and after that it is one or the other.
struct CalSideSwipe: ViewModifier {

    let step: Int
    let session: CalendarSession
    @Binding var dx: CGFloat
    @Binding var busy: Bool

    @State private var mode: Character?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard !busy else { return }
                        guard value.startLocation.x > HourGridMetrics.edge else { return }
                        if mode == nil {
                            mode = abs(value.translation.width) > abs(value.translation.height)
                                ? "h" : "v"
                        }
                        guard mode == "h" else { return }
                        dx = value.translation.width
                    }
                    .onEnded { value in
                        let wasHorizontal = mode == "h"
                        mode = nil
                        guard !busy, wasHorizontal else { return }
                        let moved = value.translation.width
                        guard abs(moved) >= HourGridMetrics.swipeCommit else {
                            withAnimation(HourGridMetrics.glide) { dx = 0 }
                            return
                        }
                        commit(moved < 0 ? 1 : -1)
                    }
            )
    }

    /// Out over 220ms, the day changes underneath, and the new one comes
    /// in from the other side over another 220ms.
    private func commit(_ direction: Int) {
        busy = true
        let width = UIScreen.main.bounds.width
        withAnimation(HourGridMetrics.glide) { dx = -CGFloat(direction) * width }
        DispatchQueue.main.asyncAfter(deadline: .now() + HourGridMetrics.glideMS) {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                session.pick(WebDates.addDays(direction * step, toKey: session.picked))
                /* The grid under the thumb is the new day's now; it starts
                   off-screen on the far side. */
                dx = CGFloat(direction) * width
            }
            /* A turn later, not in this one. Two writes to the same state
               in one runloop pass are coalesced, and the far side would
               never be drawn — the new day would slide back the way the
               old one left instead of arriving from the other side. The
               web spends two `requestAnimationFrame`s on exactly this. */
            DispatchQueue.main.async {
                withAnimation(HourGridMetrics.glide) { dx = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + HourGridMetrics.glideMS) {
                    busy = false
                }
            }
        }
    }
}

// MARK: - the week strip

/// `weekStrip(base)` — Monday to Sunday of the picked week. The strip is
/// the frame the days move inside: a swipe changes which one is filled,
/// and the strip itself stays put.
struct CalWeekStrip: View {

    @Environment(\.theme) private var theme

    let base: String
    let today: String
    var onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CalDays.week(of: base), id: \.self) { key in
                button(key)
            }
        }
    }

    private func button(_ key: String) -> some View {
        let date = WebDates.keyToDate(key) ?? Date()
        let index = WebDates.calendar.component(.weekday, from: date) - 1
        let name = String(WebDates.dayNames[max(0, min(6, index))].prefix(3))
        let picked = key == base
        let isToday = key == today

        return Button { onPick(key) } label: {
            VStack(spacing: 3) {
                Text(name)
                    .font(Font.baloo(11, .semibold))
                    .foregroundStyle(picked ? theme.accent : theme.muted)
                Text("\(WebDates.calendar.component(.day, from: date))")
                    .font(Font.baloo(19, .bold))
                    .foregroundStyle(picked ? theme.accent : theme.ink)
                    .underline(isToday)
            }
            .padding(.top, 8)
            .padding(.bottom, 7)
            .frame(maxWidth: .infinity)
            .background {
                if picked {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(hex: QuadrantPalette.mix(accentHex, surfaceHex, 0.14)))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(WebDates.dayLabel(key, today: today))
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : [.isButton])
    }

    private var accentHex: UInt32 { theme.dark ? 0x8B7DFF : 0x4737FF }
    private var surfaceHex: UInt32 { theme.dark ? 0x101018 : 0xFFFFFF }
}

// MARK: - anytime

/// `anytime(days)` — everything on these days with no clock on it, six
/// chips and then a count. Open only: a finished loose task is not
/// waiting for anything.
struct AnytimeChips: View {

    @Environment(\.theme) private var theme

    let tasks: [TaskItem]
    let days: [String]

    private var items: [TaskItem] {
        let want = Set(days)
        return tasks.filter { t in
            guard let when = t.when, want.contains(when) else { return false }
            return !((t.at.map { !$0.isEmpty }) ?? false) && !t.done && !t.skipped
        }
    }

    var body: some View {
        let items = self.items
        if !items.isEmpty {
            ChipFlow(spacing: 6, lineSpacing: 6) {
                Text(Copy.CalViews.anytime)
                    .font(Font.baloo(11))
                    .foregroundStyle(theme.muted)

                ForEach(items.prefix(Copy.CalViews.anytimeMax), id: \.id) { task in
                    Text(task.title)
                        .font(Font.baloo(12))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(theme.wash, in: Capsule())
                        .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
                }

                if items.count > Copy.CalViews.anytimeMax {
                    Text(Copy.CalViews.andMore(items.count - Copy.CalViews.anytimeMax))
                        .font(Font.baloo(11))
                        .foregroundStyle(theme.muted)
                }
            }
            .padding(.bottom, 10)
        }
    }
}

// MARK: - the grid

struct HourGridView: View {

    @Environment(\.theme) private var theme

    let days: [String]
    let tasks: [TaskItem]
    let today: String
    let hourHeight: CGFloat
    /// Week: tighter blocks, smaller titles, no second line.
    let compact: Bool

    /// The hour a fresh entry into the view scrolls to: two before the
    /// current one when today is on screen, and the start of the working
    /// day when it is not.
    static func focusHour(days: [String], today: String) -> Int {
        guard days.contains(today) else { return 7 }
        let hour = WebDates.calendar.component(.hour, from: Date())
        return max(0, hour - 2)
    }

    /// What `ScrollViewProxy` scrolls to. One id per hour, per view.
    static func anchor(_ hour: Int) -> String { "myadhd.hour.\(hour)" }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            hours
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { key in
                    column(key)
                }
            }
        }
        .overlay(alignment: .top) { theme.line.frame(height: 1) }
    }

    /// `00:00` … `23:00`, lifted 6pt so each label sits on its own line
    /// rather than under it.
    private var hours: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(Font.baloo(10.5))
                    .foregroundStyle(theme.faint)
                    .offset(y: -6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: hourHeight, alignment: .top)
                    .padding(.leading, 2)
                    .id(Self.anchor(hour))
            }
        }
        .frame(width: HourGridMetrics.gutter, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func column(_ key: String) -> some View {
        let blocks = tasks.filter { t in
            guard t.when == key, !t.skipped else { return false }
            return (t.at.map { !$0.isEmpty }) ?? false
        }

        return ZStack(alignment: .topLeading) {
            lines
            ForEach(blocks, id: \.id) { task in
                block(task)
            }
            if key == today { nowLine }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: hourHeight * 24, alignment: .top)
        .overlay(alignment: .leading) { theme.line.frame(width: 1) }
        .clipped()
    }

    private var lines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                VStack(spacing: 0) {
                    theme.line.frame(height: 1)
                    Spacer(minLength: 0)
                }
                .frame(height: hourHeight)
            }
        }
    }

    // MARK: one block

    private func block(_ task: TaskItem) -> some View {
        let start = CGFloat(WebDates.clockMinutes(task.at) ?? 0)
        let length = CGFloat(max(20, task.minutes))
        let height = max(hourHeight * 0.5, length / 60 * hourHeight - 2)
        /* `!task.done && task.when < t` — the strict boundary again. */
        let late = !task.done && Ordering.jsLess(task.when ?? "", today)
        let hue = late ? theme.orange : theme.accent
        let hueHex: UInt32 = late ? 0xF75C03 : (theme.dark ? 0x8B7DFF : 0x4737FF)
        let surfaceHex: UInt32 = theme.dark ? 0x101018 : 0xFFFFFF

        return VStack(alignment: .leading, spacing: 0) {
            Text(task.title)
                .font(Font.baloo(compact ? 9.5 : 12.5, .semibold))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .strikethrough(task.done)

            if !compact, let at = WebDates.timeLabel(task.at) {
                Text(Copy.CalViews.blockMeta(time: at, minutes: Int(length)))
                    .font(Font.baloo(10.5))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, compact ? 5 : 8)
        .padding(.trailing, compact ? 3 : 6)
        .padding(.vertical, compact ? 3 : 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .top)
        .background(Color(hex: QuadrantPalette.mix(hueHex, surfaceHex, 0.15)))
        .overlay(alignment: .leading) { hue.frame(width: compact ? 2 : 3) }
        .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous))
        .opacity(task.done ? 0.45 : 1)
        .padding(.horizontal, 3)
        .offset(y: start / 60 * hourHeight)
        .accessibilityElement(children: .combine)
    }

    /// `.myadhd-now` — 2pt of `--danger` across the day, with a dot on the
    /// hour column's edge.
    private var nowLine: some View {
        let parts = WebDates.calendar.dateComponents([.hour, .minute], from: Date())
        let minutes = CGFloat((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        return theme.danger
            .frame(height: 2)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(theme.danger)
                    .frame(width: 10, height: 10)
                    .offset(x: -5)
            }
            .offset(y: minutes / 60 * hourHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
