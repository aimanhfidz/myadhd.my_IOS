/* ============================================================
   my.adhd for iOS — what the wallpaper's matrix is made of

   The picture draws a `WallpaperBoard` (WallpaperView.swift), a plain
   value with no app types in it, so the view still compiles on a Mac for
   an off-device render. This file is the other half: building one from
   the person's store.

   **The store, not the widget snapshot.** The snapshot is trimmed for
   tiles — it carries no `quadrant`, so a task somebody dragged into a box
   would land where it derives to, and it stops at tomorrow, so Plan and
   Drop would under-count. The intent runs in the app's own process, so it
   can read the file the app writes and ask `Ordering` exactly what the
   matrix screen asks. Same boxes, same order, same counts.

   **Read-only.** `StoreFile.peek()` never quarantines and never stamps;
   ticks a widget queued since the app last drained are laid over in
   memory, the way every tile does it, and nothing is written back.
   ============================================================ */

import Foundation

extension WallpaperBoard {

    /// How each box is headed on the lock screen, and the glyph beside it.
    /// Keyed to the matrix's own keys, in `Copy.Quadrants.order`. The line
    /// break is where the heading breaks; WallpaperView says why.
    private static let heads: [String: (title: String, symbol: String)] = [
        "do":       ("Important &\nUrgent", "flame.fill"),
        "plan":     ("Important &\nNot Urgent", "calendar"),
        "delegate": ("Urgent &\nLess Important", "bolt.fill"),
        "drop":     ("Not Urgent &\nLess Important", "list.bullet"),
    ]

    /// The board as the store stands now, or nil when there is no store to
    /// read — missing, locked before the first unlock, or unparseable. The
    /// caller keeps yesterday's wallpaper on nil.
    ///
    /// `designs` says which pictures to fill in. The shortcut asks for the
    /// one it is about to draw; the library on Home asks for all of them.
    static func current(style: WallpaperStyle = Wallpaper.style,
                        file: StoreFile = StoreFile(),
                        today: String = WebDates.dayKey(),
                        designs: Set<WallpaperStyle.Design>? = nil) -> WallpaperBoard?
    {
        guard let json = file.peek() else { return nil }
        var tasks = StoreDocument.load(json).tasks

        /* Ticks taken on a widget and not drained yet, stamped with when
           they were taken, as markDone would have: without a doneAt the
           Done graph counts one on the day it was due, or not at all. */
        var ticked: [String: Date] = [:]
        for queued in OpQueue.peek() where queued.op.kind == .done {
            ticked[queued.op.id] = queued.op.at
        }
        if !ticked.isEmpty {
            for i in tasks.indices {
                guard let at = ticked[tasks[i].id], !tasks[i].done else { continue }
                tasks[i].done = true
                tasks[i].doneAt = Int(at.timeIntervalSince1970 * 1000)
            }
        }
        return build(tasks, style: style, today: today, designs: designs)
    }

    /// The board from tasks already in hand. The library on Home draws
    /// its previews from the store in memory, which can be a moment ahead
    /// of the file the shortcut reads.
    static func build(_ tasks: [TaskItem],
                      style: WallpaperStyle = Wallpaper.style,
                      today: String = WebDates.dayKey(),
                      designs: Set<WallpaperStyle.Design>? = nil) -> WallpaperBoard
    {
        let wanted = designs ?? [style.design]

        /* Boxes are decided over every open task, so a task sits in the
           same box whatever the scope; the scope only chooses which of
           them are listed. "Today & late" is a date on or before today —
           the same test the matrix uses to call a dated task urgent. */
        let open = tasks.filter { !$0.done }
        let hidden = Set(style.hidden)
        let quads = Ordering.quadrantize(open, today: today)
            .filter { !hidden.contains($0.key) }
            .map { q in
                let head = heads[q.key] ?? (q.label, "circle")
                let shown = style.scope == .all ? q.items : q.items.filter { t in
                    guard let when = t.when, !when.isEmpty else { return false }
                    return when <= today
                }
                return Quad(key: q.key,
                            title: head.title,
                            symbol: head.symbol,
                            hue: QuadrantPalette.hueHex(q.key, dark: true),
                            hueLight: QuadrantPalette.hueHex(q.key, dark: false),
                            titles: shown.map(\.title))
            }
        var board = WallpaperBoard(quads: wanted.contains(.matrix) ? quads : [])

        /* The rest colour a task by the box the matrix puts it in, so a
           task is the same colour whichever design it turns up on. */
        var box: [String: String] = [:]
        for q in Ordering.quadrantize(open, today: today) {
            for t in q.items { box[t.id] = q.key }
        }
        func hue(_ t: TaskItem) -> (UInt32, UInt32) {
            let key = box[t.id] ?? "drop"
            return (QuadrantPalette.hueHex(key, dark: true), QuadrantPalette.hueHex(key, dark: false))
        }
        func row(_ t: TaskItem, meta: String) -> Row {
            let (dark, light) = hue(t)
            return Row(title: t.title, meta: meta, late: Ordering.rowIsLate(t, today: today),
                       hue: dark, hueLight: light)
        }

        /* Late, then today: the Today card's first two groups. */
        let late = Ordering.overdueTasks(tasks, today: today)
        let due = Ordering.tasksOn(tasks, today)

        if wanted.contains(.focus), let now = Ordering.pickNow(tasks, passed: [], today: today) {
            let (dark, light) = hue(now)
            let isLate = Ordering.rowIsLate(now, today: today)
            var meta = [WebDates.minutesLabel(now.minutes)]
            if let when = now.when, !when.isEmpty {
                meta.append(isLate ? "Late" : DayKey.dayLabel(when, today: today))
            }
            if let at = DayKey.timeLabel(now.at) { meta.append(at) }
            let step = now.firstStep.trimmingCharacters(in: .whitespacesAndNewlines)
            board.focus = Focus(title: now.title,
                                step: step.isEmpty ? nil : step,
                                meta: meta.joined(separator: " · "),
                                late: isLate, hue: dark, hueLight: light,
                                more: (late + due).filter { $0.id != now.id }.count)
        }

        if wanted.contains(.agenda) {
            board.agenda = late.map { row($0, meta: "Late · " + DayKey.dayLabel($0.when ?? today, today: today)) }
                + due.map { t in
                    row(t, meta: [DayKey.timeLabel(t.at), WebDates.minutesLabel(t.minutes)]
                        .compactMap { $0 }.joined(separator: " · "))
                }
        }

        if wanted.contains(.month) {
            board.month = month(open, today: today, row: row)
        }

        if wanted.contains(.done) {
            board.done = done(tasks, today: today)
        }
        return board
    }

    /// This month, Monday or Sunday first as the phone has it, with the
    /// open dated tasks on each day and the next three after today.
    private static func month(_ open: [TaskItem], today: String,
                              row: (TaskItem, String) -> Row) -> Month?
    {
        let cal = DayKey.calendar
        guard let now = DayKey.date(today, cal),
              let first = cal.date(from: cal.dateComponents([.year, .month], from: now)),
              let days = cal.range(of: .day, in: .month, for: now)?.count
        else { return nil }

        let firstKey = DayKey.of(first, cal)
        var counts = [Int](repeating: 0, count: days)
        for t in open {
            guard let when = t.when, let i = DayKey.between(firstKey, when, cal),
                  i >= 0, i < days else { continue }
            counts[i] += 1
        }

        let weekday = cal.component(.weekday, from: first)          // 1 = Sunday
        let lead = (weekday - cal.firstWeekday + 7) % 7
        let short = cal.veryShortStandaloneWeekdaySymbols
        let symbols = (0..<7).map { short[($0 + cal.firstWeekday - 1) % 7] }

        let ahead = open
            .filter { ($0.when ?? "") > today }
            .sorted { ($0.when ?? "", $0.at ?? "99:99") < ($1.when ?? "", $1.at ?? "99:99") }
            .prefix(3)
            .map { t in row(t, [DayKey.dayLabel(t.when ?? today, today: today), DayKey.timeLabel(t.at)]
                                .compactMap { $0 }.joined(separator: " · ")) }

        let f = DateFormatter()
        f.calendar = cal
        f.dateFormat = "LLLL"
        return Month(title: f.string(from: now), symbols: symbols, lead: lead, counts: counts,
                     today: cal.component(.day, from: now), next: Array(ahead))
    }

    /// Seventeen weeks of squares, ending today. The ledger remembers
    /// what `pruneDone()` has thrown away; the store has this week. Read,
    /// never merged — DoneLedger.merge writes, and this must not.
    private static func done(_ tasks: [TaskItem], today: String) -> Done {
        let weeks = 17
        let cal = DayKey.calendar
        var seen = DoneLedger.peek()
        var fresh: [String: Int] = [:]
        for t in tasks where t.done {
            let day = t.doneAt.map { DayKey.of(Date(timeIntervalSince1970: Double($0) / 1000), cal) } ?? t.when
            if let day { fresh[day, default: 0] += 1 }
        }
        for (day, n) in fresh { seen[day] = day == today ? n : max(seen[day] ?? 0, n) }

        /* Columns are weeks, so the first column starts on the calendar's
           first weekday and today lands wherever it falls in the last. */
        let todayDate = DayKey.date(today, cal) ?? Date()
        let intoWeek = (cal.component(.weekday, from: todayDate) - cal.firstWeekday + 7) % 7
        let span = (weeks - 1) * 7 + intoWeek + 1
        let start = DayKey.adding(-(span - 1), to: today, cal)
        let counts = (0..<span).map { seen[DayKey.adding($0, to: start, cal)] ?? 0 }
        return Done(counts: counts, lead: 0, today: counts.last ?? 0,
                    week: counts.suffix(7).reduce(0, +))
    }
}
