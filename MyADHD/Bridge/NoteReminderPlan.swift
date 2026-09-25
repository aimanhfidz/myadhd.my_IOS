/* ============================================================
   MyADHD/Bridge/NoteReminderPlan.swift — the bell on a note, ringing

   The Notes editor has had a bell since the port (`RemindSheet`): a day,
   a time and a repeat, saved on the note as `remindOn`, `remindAt` and
   `repeat`, and shown on the paper as "Reminder …". Nothing ever rang.
   The web cannot ring either, which is why the port stopped there; the
   phone can, so this turns those three fields into notifications.

   **What each repeat becomes.** A calendar trigger that repeats matches
   components, not a start date:

   - none    — the day and time, once. Gone once it has passed.
   - daily   — hour and minute.
   - weekly  — the weekday of `remindOn`, hour and minute.
   - monthly — the day of the month of `remindOn`, hour and minute.

   A repeating trigger cannot be told to wait for its first day. When
   the first day is also the trigger's next match — the usual case, "every
   day from tomorrow" — it repeats from the start. When the first day is
   further off, it rings once on it, and the first rebuild after that day
   installs the repeat. A monthly day past the 28th is scheduled a month
   at a time instead, clamped to shorter months.

   **No time means nine**, `ReminderPlan.defaultHour`, for that file's
   reason. The title is the note's title, or its first line when it has
   none, or the sheet's own word, `Reminder`; a titled note's first line
   is the body.

   Foundation and `Core/` only, for `Checks/nudges.sh`.
   ============================================================ */

import Foundation

struct NoteReminderPlan: Equatable {
    let id: String
    let noteID: String
    let title: String
    let body: String
    /// The next time it rings, for the soonest-first cut.
    let fire: Date
    let parts: DateComponents
    let repeats: Bool
}

enum NoteReminderPlanner {

    static let idPrefix = "myadhd.note."

    /// A handful. Notes are not where the day's work lives, and every one
    /// of these is a slot a dated task cannot have.
    static let limit = 6

    static func plan(notes: [NoteItem], now: Date = Date()) -> [NoteReminderPlan] {
        let calendar = DayKey.calendar
        var out: [NoteReminderPlan] = []

        for note in notes {
            guard let day = note.remindOn, !day.isEmpty,
                  let stamp = ReminderPlanner.components(day: day, at: note.remindAt),
                  let first = calendar.date(from: stamp.parts) else { continue }

            var parts = DateComponents()
            var repeats = true
            switch note.repeatRule {
            case "daily":
                parts.hour = stamp.parts.hour
                parts.minute = stamp.parts.minute
            case "weekly":
                parts.weekday = calendar.component(.weekday, from: first)
                parts.hour = stamp.parts.hour
                parts.minute = stamp.parts.minute
            case "monthly":
                parts.day = stamp.parts.day
                parts.hour = stamp.parts.hour
                parts.minute = stamp.parts.minute
            default:
                repeats = false
            }

            var fire = first

            if repeats, note.repeatRule == "monthly", (stamp.parts.day ?? 0) > 28 {
                /* A trigger matching `day: 31` only fires in months that
                   have one — seven a year — and `day: 30` skips February.
                   So past the 28th it is scheduled a month at a time, on
                   the day or the month's last if it is shorter; the
                   schedule is rebuilt on every write and return, which
                   is what brings the next one. */
                guard let next = monthlyClamped(day: stamp.parts.day ?? 1,
                                                hour: stamp.parts.hour ?? ReminderPlanner.defaultHour,
                                                minute: stamp.parts.minute ?? 0,
                                                from: first, after: now,
                                                calendar: calendar) else { continue }
                parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)
                fire = next
                repeats = false
            } else if repeats {
                /* A repeating trigger cannot be told to wait for its first
                   day. Right when that first day is also its next match —
                   "every day from tomorrow", set in the afternoon — so it
                   repeats from the start rather than ringing once and then
                   waiting for somebody to open the app. When the first day
                   is further off than that, it rings once on it, and the
                   rebuild after that day installs the repeat. */
                let next = calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime)
                if first > now, next != first {
                    parts = stamp.parts
                    repeats = false
                } else {
                    fire = next ?? first
                }
            } else {
                /* Once: the day and the time, and gone once it has passed. */
                guard first > now else { continue }
                parts = stamp.parts
            }
            parts.calendar = calendar

            let words = wording(note)
            out.append(NoteReminderPlan(id: idPrefix + note.id,
                                        noteID: note.id,
                                        title: words.title,
                                        body: words.body,
                                        fire: fire,
                                        parts: parts,
                                        repeats: repeats))
        }

        return Array(out.sorted { $0.fire < $1.fire }.prefix(limit))
    }

    /// The next month's `day`, or its last day when it has fewer, at the
    /// time given — the first such moment after `now` and not before the
    /// reminder's own first day.
    static func monthlyClamped(day: Int, hour: Int, minute: Int,
                               from first: Date, after now: Date,
                               calendar: Calendar) -> Date? {
        var month = calendar.dateComponents([.year, .month], from: max(first, now))
        for _ in 0..<14 {
            guard let start = calendar.date(from: DateComponents(year: month.year,
                                                                 month: month.month, day: 1)),
                  let length = calendar.range(of: .day, in: .month, for: start)?.count
            else { return nil }
            var c = DateComponents()
            c.year = month.year
            c.month = month.month
            c.day = min(day, length)
            c.hour = hour
            c.minute = minute
            if let date = calendar.date(from: c), date > now, date >= first { return date }
            guard let after = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
            month = calendar.dateComponents([.year, .month], from: after)
        }
        return nil
    }

    /// The note's title and its first line, or its first line and nothing,
    /// or the sheet's word for what this is.
    static func wording(_ note: NoteItem) -> (title: String, body: String) {
        let lines = note.body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return (title, clip(lines.first ?? "")) }
        if let line = lines.first { return (clip(line), "") }
        return (Copy.Note.Remind.title, "")
    }

    private static func clip(_ s: String) -> String {
        s.count > 140 ? String(s.prefix(139)) + "…" : s
    }
}
