/* ============================================================
   MyADHD/UI/MonthPage.swift — one month of cells

   `paintMonth` (app.js:2286-2348) and `.cal-day` (styles.css:1710-1746).

   **Weeks start on Monday.** `getDay()` counts from Sunday, so the
   leading blanks are `(day + 6) % 7` and not `day`. Foundation counts
   from 1, so the same rotation is `(weekday + 5) % 7` — and it is the
   Gregorian calendar's weekday, never `Calendar.current`'s, because a
   device set to the Japanese or Hijri calendar reports a year no key
   written by app.js will ever match.

   **Today and the picked day can both be on one cell**, which is why one
   is an outline and the other a fill rather than two colours of the same
   thing.

   **The mark is the earliest TIMED task's time, or a dot.** A day with
   things on it but no clock on any of them gets the dot: there is nothing
   to show, and an invented 12am would read as an appointment. `tasksOn`
   sorts timed ahead of loose, so the first one carrying an `at` is the
   earliest of the day.

   **Late colours the mark and never the digit** (styles.css:1731, 1745).
   The date is not the news; what is sitting on it is.

   The side panes of the pager are drawn by this same view with `live`
   false: nothing to tab into, no aria, and no way to pick a day on a
   month that is half off the edge of the screen.
   ============================================================ */

import SwiftUI

// MARK: - a month, as a value

/// `calCursor` is a `Date` on the 1st; this is the same fact without the
/// 28 other fields, so two months can be compared with `==`.
struct MonthRef: Equatable {

    /// Four digits.
    var year: Int
    /// **0-11**, as `getMonth()` counts — `MONTH_NAMES[m]` is indexed
    /// with it and so is `Copy.Calendar.monthTitle`.
    var month: Int

    init(year: Int, month: Int) {
        /* `new Date(y, m + n, 1)` rolls over, so this does too. */
        let total = year * 12 + month
        self.year = Int((Double(total) / 12).rounded(.down))
        self.month = total - self.year * 12
    }

    /// `YYYY-MM`, which is what the session writes down.
    init?(key: String) {
        let parts = key.split(separator: "-")
        guard parts.count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]),
              (1...12).contains(m) else { return nil }
        self.init(year: y, month: m - 1)
    }

    /// `keyToDate(calPicked.slice(0, 8) + '01')` — the month a day is in.
    init(dayKey: String) {
        let date = WebDates.keyToDate(dayKey) ?? Date()
        let p = WebDates.calendar.dateComponents([.year, .month], from: date)
        self.init(year: p.year ?? 1970, month: (p.month ?? 1) - 1)
    }

    var key: String { String(format: "%04d-%02d", year, month + 1) }
    var title: String { Copy.Calendar.monthTitle(month: month, year: year) }

    func adding(_ n: Int) -> MonthRef { MonthRef(year: year, month: month + n) }

    /// Local midnight on the 1st.
    var firstDate: Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month + 1
        parts.day = 1
        return WebDates.calendar.date(from: parts) ?? Date()
    }

    /// `(first.getDay() + 6) % 7` — how many cells Monday is along by.
    var blanks: Int {
        (WebDates.calendar.component(.weekday, from: firstDate) + 5) % 7
    }

    /// `new Date(y, m + 1, 0).getDate()`.
    var days: Int {
        WebDates.calendar.range(of: .day, in: .month, for: firstDate)?.count ?? 30
    }

    /// How many rows the grid needs — five for most months, six when a
    /// long one starts late, four for a February that starts on a Monday.
    var weeks: Int { Int(ceil(Double(blanks + days) / 7.0)) }

    func dayKey(_ day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month + 1, day)
    }
}

// MARK: - the page

struct MonthPage: View {

    @Environment(\.theme) private var theme

    let month: MonthRef
    /// Every task, done ones included. `tasksOn` drops what it must.
    let tasks: [TaskItem]
    let today: String
    let picked: String
    /// The middle pane of the pager. The two either side are inert.
    let live: Bool
    /// The width one cell is allowed. Measured by the pager, because the
    /// height of the whole page follows from it.
    let cell: CGFloat

    var onPick: (String) -> Void = { _ in }
    /// Passed through to every cell. The two inert pages get it too and
    /// do nothing with it — they neither post a frame nor take a gesture.
    let drag: MonthDrag

    /// Grouped once per page rather than filtered 42 times. `tasksOn`
    /// still does the sort, so the order it produces is untouched.
    private var byDay: [String: [TaskItem]] {
        Dictionary(grouping: tasks.filter { Ordering.scheduled($0) }) { $0.when ?? "" }
    }

    /// `.cal-dow` + `.cal-grid` share `gap: 3px`.
    static let gap: CGFloat = 3
    /// `.cal-dow{margin-bottom:6px}` over an 11.5pt line.
    static let dowHeight: CGFloat = 20

    /// What the pager pins itself to.
    static func height(month: MonthRef, cell: CGFloat) -> CGFloat {
        let rows = CGFloat(month.weeks)
        return dowHeight + rows * cell + max(0, rows - 1) * gap
    }

    var body: some View {
        let byDay = self.byDay

        VStack(spacing: 0) {
            dow
                .frame(height: Self.dowHeight, alignment: .bottom)

            VStack(spacing: Self.gap) {
                ForEach(0..<month.weeks, id: \.self) { week in
                    HStack(spacing: Self.gap) {
                        ForEach(0..<7, id: \.self) { column in
                            let index = week * 7 + column
                            let day = index - month.blanks + 1
                            if day >= 1 && day <= month.days {
                                dayCell(day, byDay: byDay)
                            } else {
                                /* `span.cal-day.is-blank` — inert, and it
                                   still takes a cell so the month keeps
                                   its shape. */
                                Color.clear.frame(height: cell)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }

    /// `M T W T F S S`, static, Monday first.
    private var dow: some View {
        HStack(spacing: Self.gap) {
            ForEach(Array(Copy.Calendar.dayInitials.enumerated()), id: \.offset) { _, letter in
                Text(letter)
                    .font(Font.baloo(11.5, .bold))
                    .kerning(0.06 * 11.5)
                    .foregroundStyle(theme.faint)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private func dayCell(_ day: Int, byDay: [String: [TaskItem]]) -> some View {
        let key = month.dayKey(day)
        let items = Ordering.tasksOn(byDay[key] ?? [], key)
        return MonthDayCell(day: day,
                            key: key,
                            items: items,
                            today: today,
                            picked: picked,
                            live: live,
                            size: cell,
                            onPick: onPick,
                            drag: drag)
    }
}

// MARK: - one day

struct MonthDayCell: View {

    @Environment(\.theme) private var theme

    let day: Int
    let key: String
    /// Already `tasksOn`-ordered, so the first one carrying a clock is the
    /// earliest of the day.
    let items: [TaskItem]
    let today: String
    let picked: String
    let live: Bool
    let size: CGFloat
    var onPick: (String) -> Void
    /// The hold-and-drag this cell takes part in — it posts its frame so
    /// the drag can find it, and wears a ring while the finger is on it.
    let drag: MonthDrag

    /// `QuadrantCell`'s flag, and for its reason: without it a move past
    /// the slop drops the press and the very next callback starts a fresh
    /// one, which is a hold that can never be called off.
    @State private var gestureLive = false

    private var isToday: Bool { key == today }
    private var isPicked: Bool { key == picked }
    private var hasItems: Bool { !items.isEmpty }
    /// `key < today` — the strict boundary, on the mark alone.
    private var isLate: Bool { Ordering.jsLess(key, today) }
    private var firstTimed: TaskItem? {
        items.first { ($0.at.map { !$0.isEmpty }) ?? false }
    }

    private var digit: Color {
        if isPicked { return theme.onAccent }
        return isToday ? theme.ink : theme.inkSoft
    }

    private var markColour: Color {
        if isPicked { return theme.onAccent }
        return isLate ? theme.orange : theme.accent
    }

    var body: some View {
        ZStack {
            Text("\(day)")
                .font(Font.baloo(14.5, isToday || isPicked ? .heavy : .semibold))
                .foregroundStyle(digit)

            if hasItems {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    mark
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: size)
        .background(isPicked ? theme.accent : Color.clear)
        /* Only the live page posts, so a key that exists in two of the
           three months on screen cannot overwrite itself with the wrong
           rectangle. */
        .background {
            if live {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: MonthFramesKey.self,
                        value: [key: geo.frame(in: .named(MonthDrag.space))]
                    )
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(isPicked ? theme.accent : (isToday ? theme.lineStrong : .clear),
                              lineWidth: 1.5)
        )
        /* `.is-drop` — the cell the finger is over, while it is over it.
           The fill has already moved here, because crossing a cell picks
           it; the ring is what says the gesture is still in your hand. */
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(drag.isOver(key) ? theme.accent : .clear, lineWidth: 2.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture { if live { onPick(key) } }
        .simultaneousGesture(live ? hold : nil)
        .allowsHitTesting(live)
        .accessibilityHidden(!live)
        /* `aria-pressed` on a button is `.isSelected` here: the same fact,
           said the way VoiceOver says it. */
        .accessibilityAddTraits(live ? (isPicked ? [.isButton, .isSelected] : [.isButton]) : [])
        .accessibilityLabel(live ? aria : "")
    }

    /// Press, wait, then scrub. `minimumDistance: 0` so the press starts
    /// on touch-down rather than after the finger has already moved; the
    /// timer inside `MonthDrag` is what decides this was a hold and not a
    /// scroll, and the tap above still fires for anything shorter.
    private var hold: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(MonthDrag.space))
            .onChanged { value in
                if !gestureLive {
                    gestureLive = true
                    drag.press(key, at: value.startLocation)
                }
                drag.moved(to: value.location)
            }
            .onEnded { _ in
                gestureLive = false
                drag.release()
            }
    }

    /// The earliest time that day, in the dot's place; otherwise the dot.
    @ViewBuilder
    private var mark: some View {
        if let at = firstTimed?.at, let label = WebDates.timeLabel(at) {
            Text(label)
                .font(Font.baloo(Self.timeSize, .bold))
                .kerning(-0.02 * Self.timeSize)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(markColour)
                .padding(.bottom, 3)
        } else {
            Circle()
                .fill(markColour)
                .frame(width: 5, height: 5)
                .padding(.bottom, 6)
        }
    }

    /// `clamp(8px, 2.4vw, 9px)` — the widest label is 12.30pm, and that is
    /// what sizes it.
    private static var timeSize: CGFloat {
        min(9, max(8, UIScreen.main.bounds.width * 0.024))
    }

    private var aria: String {
        Copy.Calendar.dayAria(label: WebDates.dayLabel(key, today: today),
                              count: items.count,
                              from: firstTimed.flatMap { WebDates.timeLabel($0.at) })
    }
}
