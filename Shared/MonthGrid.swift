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

    private let calendar = Calendar.current

    @Environment(\.colorScheme) private var scheme

    private var today: String { DayKey.of(now) }

    /// Sunday-first, which is what app.js's DAY_NAMES assumes.
    private var weekdayInitials: [String] { ["S", "M", "T", "W", "T", "F", "S"] }

    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
    }

    private var monthLabel: String {
        let f = DateFormatter()
        f.calendar = calendar
        f.dateFormat = "MMMM yyyy"
        return f.string(from: monthStart)
    }

    /// Six rows of seven, always — a grid that changes height between
    /// months makes the whole tile jump.
    private var cells: [Date?] {
        let lead = (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7
        let days = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        var out: [Date?] = Array(repeating: nil, count: lead)
        for d in 0..<days {
            out.append(calendar.date(byAdding: .day, value: d, to: monthStart))
        }
        while out.count < 42 { out.append(nil) }
        return Array(out.prefix(42))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showHeader {
                Text(monthLabel)
                    .font(.baloo(13, .bold))
            }

            HStack(spacing: 0) {
                ForEach(Array(weekdayInitials.enumerated()), id: \.offset) { _, letter in
                    Text(letter)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(0..<6, id: \.self) { row in
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
    private func cell(_ date: Date?) -> some View {
        if let date {
            let key = DayKey.of(date)
            let count = snapshot?.count(on: key) ?? 0
            let isToday = key == today
            /* A day gone by that still has something open on it is late,
               and late is the one thing Vivid Orange is for. */
            let late = key < today && count > 0

            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: cellSize * 0.46, weight: isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? AnyShapeStyle(scheme == .dark ? Color.black : Color.white)
                                             : AnyShapeStyle(key < today ? .tertiary : .primary))
                    .frame(width: cellSize * 0.88, height: cellSize * 0.88)
                    .background(
                        Circle().fill(isToday ? CategoryTint.accent(scheme) : .clear)
                    )

                HStack(spacing: 1.5) {
                    ForEach(0..<min(3, count), id: \.self) { _ in
                        Circle()
                            .fill(late ? CategoryTint.urgent : CategoryTint.accent(scheme))
                            .frame(width: 3, height: 3)
                    }
                }
                .frame(height: 3)
            }
            .frame(height: cellSize)
        } else {
            Color.clear.frame(height: cellSize)
        }
    }
}
