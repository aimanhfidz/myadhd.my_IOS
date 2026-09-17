/* ============================================================
   my.adhd for iOS — what you actually got done

   Ink's Task Graph, which is a GitHub contribution grid with "2026 · 124
   tasks completed" over it. Worth having and worth being careful with,
   for two reasons.

   It is not green. theme.css has no green, and the one colour this could
   borrow instead — Vivid Orange — means "you are late", which is a strange
   thing to say about work already finished. So the ramp is the accent, at
   five steps of opacity.

   And it does not claim a year it does not have. pruneDone() in app.js
   deletes anything finished more than seven days ago, so the web store can
   only ever hand over a week; everything past that is accrued natively,
   one day at a time, from the day this shipped. The header says which date
   it is counting from rather than drawing a year of empty cells and
   letting them read as a year of doing nothing.
   ============================================================ */

import SwiftUI

struct DoneGraph: View {

    let snapshot: TaskSnapshot?
    let now: Date
    var weeks: Int = 18
    var cell: CGFloat = 9
    var gap: CGFloat = 2.5

    @Environment(\.colorScheme) private var scheme

    private var day: String { snapshot?.effectiveDay(now) ?? DayKey.of(now) }

    /// Columns end on the week the snapshot's day falls in, so the newest
    /// cell is always in the last column rather than drifting.
    private var firstCell: String {
        let weekday = Calendar.current.component(.weekday, from: DayKey.date(day) ?? now)
        let intoWeek = (weekday - Calendar.current.firstWeekday + 7) % 7
        return DayKey.adding(-(intoWeek + (columns - 1) * 7), to: day)
    }

    /* Only as many columns as there is history for. The ledger accrues
       from the day this shipped, so a fixed eighteen weeks would spend its
       first four months drawing empty squares for days nobody was counting
       — which reads as four months of doing nothing, and is the exact lie
       the "since" line underneath exists to avoid. */
    private var columns: Int {
        guard let from = snapshot?.histFrom,
              let span = DayKey.between(from, day), span >= 0 else { return 1 }
        let weekday = Calendar.current.component(.weekday, from: DayKey.date(day) ?? now)
        let intoWeek = (weekday - Calendar.current.firstWeekday + 7) % 7
        return max(1, min(weeks, (span + intoWeek) / 7 + 1))
    }

    private var total: Int { snapshot?.hist.reduce(0, +) ?? 0 }

    private var thisWeek: Int {
        guard let snapshot else { return 0 }
        let weekday = Calendar.current.component(.weekday, from: DayKey.date(day) ?? now)
        let intoWeek = (weekday - Calendar.current.firstWeekday + 7) % 7
        return (0...intoWeek).reduce(0) { $0 + snapshot.completed(on: DayKey.adding(-$1, to: day)) }
    }

    /// The most anyone did in one day, which is what the ramp is scaled
    /// against. A fixed ceiling makes a quiet week look like a failure.
    private var peak: Int { max(3, snapshot?.hist.max() ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(total) done")
                    .font(.baloo(14, .bold))
                if let streak = snapshot?.streak, streak > 1 {
                    Text("· \(streak) day streak")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(CategoryTint.accent(scheme))
                }
                Spacer(minLength: 0)
                Text("\(thisWeek) this week")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: gap) {
                ForEach(0..<columns, id: \.self) { w in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { d in
                            let key = DayKey.adding(w * 7 + d, to: firstCell)
                            RoundedRectangle(cornerRadius: cell * 0.25, style: .continuous)
                                .fill(tint(key))
                                .frame(width: cell, height: cell)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            /* The honest line. Until the native ledger has run long enough
               to mean something, say what it is actually counting rather
               than letting a grid of empty cells imply a year of nothing. */
            Text(since)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func tint(_ key: String) -> Color {
        guard key <= day else { return Color.secondary.opacity(0.06) }
        let n = snapshot?.completed(on: key) ?? 0
        guard n > 0 else { return Color.secondary.opacity(0.13) }
        let steps: [Double] = [0.28, 0.48, 0.72, 1.0]
        let i = min(steps.count - 1, (n - 1) * steps.count / max(1, peak))
        return CategoryTint.accent(scheme).opacity(steps[i])
    }

    private var since: String {
        guard let from = snapshot?.histFrom, snapshot?.hist.isEmpty == false else {
            return "Counting from today."
        }
        let span = DayKey.between(from, day) ?? 0
        if span >= 360 { return "Last twelve months." }
        return "Since \(DayKey.dayLabel(from, today: day))."
    }
}
