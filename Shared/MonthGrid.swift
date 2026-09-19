/* ============================================================
   my.adhd for iOS — the month, and how much of it is spoken for

   Ink's Calendar tile draws a month grid off EventKit. This one draws it
   off the counts TaskBridge sweeps out of the store, which is a different
   thing and says so: these are the days your own list has something dated
   to, not your calendar.

   Two decisions worth keeping.

   The grid follows the CLOCK, not the snapshot. A tile rendered at 00:01
   on the 1st is looking at a month the snapshot was written before, which
   is why `cal` spans ten days back and seventy-seven forward — the grid
   can roll over without anybody rewriting the keychain.

   Days outside that window draw plain. Not zero, not empty — plain, with
   no dots at all, because "no dots" and "I was not told" look the same and
   only one of them is honest.

   No WidgetKit, no UIKit, so ImageRenderer can check it on a Mac.
   ============================================================ */

import SwiftUI

struct MonthGrid: View {

    let snapshot: TaskSnapshot?
    let now: Date
    var cellSize: CGFloat = 20
    var showHeader: Bool = true
    var rowGap: CGFloat = 5
    /// Digits only, no dot row: a day with something on it is marked by
    /// the digit itself going bold in the accent (orange if it has gone
    /// past). What the medium tile needs when the grid has half a tile.
    var compact: Bool = false

    private let calendar = DayKey.calendar

    @Environment(\.colorScheme) private var scheme

    private var today: String { DayKey.of(now) }

    /// Sunday-first, which is what app.js's DAY_NAMES assumes.
    private var weekdayInitials: [String] { ["S", "M", "T", "W", "T", "F", "S"] }

    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
    }

    /// "SEPTEMBER" — the month alone, tracked caps, the way the app's own
    /// eyebrows are set and the way Google Calendar's tile does it. The
    /// year is not information anyone needs on a home screen.
    static func monthName(_ date: Date, _ calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.dateFormat = "MMMM"
        return f.string(from: date).uppercased()
    }

    /// Six rows of seven, always — a grid that changes height between
    /// months makes the whole tile jump. The lead and trail cells are the
    /// real neighbouring days, drawn faint, rather than blanks: a grid
    /// that starts at "1" on a Wednesday with three holes before it reads
    /// as broken, and 30 · 31 · 1 · 2 is how every printed calendar does it.
    private var cells: [(date: Date, inMonth: Bool)] {
        let lead = (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7
        let days = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        return (0..<42).map { i in
            let offset = i - lead
            let date = calendar.date(byAdding: .day, value: offset, to: monthStart) ?? monthStart
            return (date, offset >= 0 && offset < days)
        }
    }

    /* Six rows, always, on the large tile — a grid that changes height
       between months makes the list under it jump. Compact drops a
       trailing row that is entirely next month: half a tile has no room
       to spend on seven faint digits that say nothing, and the height it
       saves is the difference between the chip fitting and not. */
    private var rows: Int {
        guard compact else { return 6 }
        let all = cells
        var n = 6
        while n > 4 && !all[(n - 1) * 7 ..< n * 7].contains(where: { $0.inMonth }) { n -= 1 }
        return n
    }

    var body: some View {
        VStack(alignment: .leading, spacing: rowGap) {
            if showHeader {
                Text(Self.monthName(monthStart, calendar))
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
            }

            HStack(spacing: 0) {
                ForEach(Array(weekdayInitials.enumerated()), id: \.offset) { _, letter in
                    Text(letter)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        cell(cells[row * 7 + col])
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ item: (date: Date, inMonth: Bool)) -> some View {
        let key = DayKey.of(item.date)
        let count = item.inMonth ? (snapshot?.count(on: key) ?? 0) : 0
        let isToday = key == today
        /* A day gone by that still has something open on it is late,
           and late is the one thing Vivid Orange is for. */
        let late = key < today && count > 0
        let marked = compact && count > 0
        /* fixedSize so a bold two-digit day never becomes "…" — the frame
           below is the today-ring's size, not a width the text must fit. */
        let digit = Text("\(calendar.component(.day, from: item.date))")
            .font(.system(size: max(9, cellSize * 0.5), weight: (isToday || marked) ? .bold : .regular))
            .lineLimit(1)
            .fixedSize()

        VStack(spacing: 2) {
            digit
                .foregroundStyle(
                    isToday ? AnyShapeStyle(scheme == .dark ? Color.black : Color.white)
                    : !item.inMonth ? AnyShapeStyle(.quaternary)
                    : marked ? AnyShapeStyle(late ? CategoryTint.urgent : CategoryTint.accent(scheme))
                    : key < today ? AnyShapeStyle(.tertiary)
                    : AnyShapeStyle(.primary))
                .frame(width: cellSize * 0.88, height: cellSize * 0.88)
                .background(Circle().fill(isToday ? CategoryTint.accent(scheme) : .clear))

            if !compact {
                HStack(spacing: 1.5) {
                    ForEach(0..<min(3, count), id: \.self) { _ in
                        Circle()
                            .fill(late ? CategoryTint.urgent : CategoryTint.accent(scheme))
                            .frame(width: 3, height: 3)
                    }
                }
                .frame(height: 3)
            }
        }
        .frame(height: cellSize)
    }
}

// MARK: - the month beside what is next

/* Google Calendar's medium tile: the grid on the left, and on the right
   the one thing coming up, as a chip with a dot. Two questions a glance
   at a home screen actually asks — where am I in the month, and what is
   next — and nothing else. The grid is the compact one: digits only, a
   day with something on it in bold accent, because half a tile has no
   room for a dot row and the digit can carry the mark itself. */
struct MonthWithNext: View {

    let snapshot: TaskSnapshot?
    let now: Date

    @Environment(\.colorScheme) private var scheme

    private var day: String { snapshot?.effectiveDay(now) ?? DayKey.of(now) }
    private var next: SnapTask? { snapshot?.next(now: now) }
    private var moreToday: Int {
        guard let snapshot else { return 0 }
        return max(0, snapshot.ordered(now: now).filter { $0.when == day }.count - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(MonthGrid.monthName(now))
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                chip
            }

            HStack(alignment: .top, spacing: 12) {
                MonthGrid(snapshot: snapshot, now: now, cellSize: 14,
                          showHeader: false, rowGap: 2, compact: true)
                    .frame(width: 170)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 3) {
                    if let next {
                        if let t = DayKey.timeLabel(next.at) {
                            Text(next.when == day ? t
                                 : "\(DayKey.dayLabel(next.when ?? day, today: day)) \u{00B7} \(t)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        if moreToday > 0 {
                            Text("+\(moreToday) more today")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /* The chip: a dot in the task's category tint, then the title. When
       there is nothing, the chip says so in the three-nothings register
       rather than vanishing — an empty right half looks like a bug. */
    private var chip: some View {
        HStack(spacing: 7) {
            if let next {
                Circle()
                    .fill(next.isOverdue(on: day) ? CategoryTint.urgent : CategoryTint.of(next.category))
                    .frame(width: 9, height: 9)
                Text(next.title)
                    .font(.baloo(13.5, .semibold))
                    .lineLimit(1)
            } else {
                Text(Nothing.line(snapshot))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.secondary.opacity(scheme == .dark ? 0.18 : 0.10)))
        .frame(maxWidth: 190, alignment: .trailing)
    }
}
