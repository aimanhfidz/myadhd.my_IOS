/* ============================================================
   WebDates — the web app's date and label helpers, ported

   Source: app.js 640-760 (the `---- dates ----` block), plus
   minutesLabel (app.js:1091), utcDay (app.js:2654) and noteWhen
   (app.js:4455). Every rule here is the web's rule; where a line
   reads oddly, app.js reads the same way and the comment says so.

   A task carries two separate fields, not one instant: `when` is a
   day (YYYY-MM-DD) and `at` is a clock time (HH:MM), either of which
   can be null. Folding them into one timestamp would force a fake
   time onto every dateless day, and storing that as UTC would shunt
   half of them onto the wrong date. Everything below is deliberately
   local-time — the one exception is utcDay(), which is UTC on
   purpose and says why.

   DayKey (Shared/TaskSnapshot.swift) already carries the calendar,
   of/date/adding/between, timeLabel, dayLabel and minutes, already
   pinned to Gregorian + TimeZone.current, and the widgets compile
   against it. This file does NOT re-implement any of that: it is a
   thin, web-named surface over DayKey plus the pieces DayKey has
   never needed — dayPhrase, whenLabel, minutesLabel, noteWhen,
   utcDay, and the two public name tables.

   Gregorian, always. Never Calendar.current: a device on the
   Japanese, Buddhist or Hijri calendar reports year 8, 2569 or 1448,
   and a key built from that never matches a key app.js wrote.
   ============================================================ */

import Foundation

enum WebDates {

    // MARK: the calendar

    /// The one calendar every date in this app is read through.
    /// Gregorian, device time zone — DayKey's, not a second opinion.
    static var calendar: Calendar { DayKey.calendar }

    /// Gregorian in UTC. Only utcDay() uses it.
    static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return c
    }()

    // MARK: the name tables (app.js:705-707)

    static let monthNames = ["January", "February", "March", "April", "May", "June",
                             "July", "August", "September", "October", "November", "December"]

    static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday",
                           "Thursday", "Friday", "Saturday"]

    // MARK: pad2 (app.js:644)

    static func pad2(_ n: Int) -> String { String(format: "%02d", n) }

    // MARK: dayKey / keyToDate / addDays (app.js:647-660)

    /// The local calendar day as YYYY-MM-DD. Never an ISO8601 string —
    /// that is UTC, and a task dated today in Kuala Lumpur is dated
    /// yesterday in UTC for most of the working day.
    static func dayKey(_ d: Date = Date()) -> String { DayKey.of(d) }

    /// Local midnight for a day key, or nil if the key is not one.
    /// app.js returns an Invalid Date for junk; nil is that, typed.
    static func keyToDate(_ key: String) -> Date? { DayKey.date(key) }

    /// app.js: `out.setDate(out.getDate() + n)` — a calendar day, so the
    /// wall-clock time of day survives a DST boundary rather than
    /// sliding by an hour.
    static func addDays(_ d: Date, _ n: Int) -> Date {
        calendar.date(byAdding: .day, value: n, to: d) ?? d
    }

    /// The same move expressed on a key, which is what nearly every
    /// caller in app.js actually wants: dayKey(addDays(keyToDate(k), n)).
    static func addDays(_ n: Int, toKey key: String) -> String {
        DayKey.adding(n, to: key)
    }

    /// Whole days from `a` to `b`, positive when `b` is the later one.
    static func daysBetween(_ a: String, _ b: String) -> Int? {
        DayKey.between(a, b)
    }

    // MARK: clockMinutes (app.js:687)

    /// Minutes past midnight for a normalised HH:MM, or nil.
    static func clockMinutes(_ at: String?) -> Int? { DayKey.minutes(at) }

    // MARK: timeLabel (app.js:710-716)

    /// 4pm, 9.30am — a period, not a colon. nil for a day with no time
    /// on it. Midnight reads 12am and noon reads 12pm, because app.js
    /// takes `h % 12 === 0 ? 12 : h % 12` and `h < 12 ? am : pm`.
    static func timeLabel(_ at: String?) -> String? { DayKey.timeLabel(at) }

    /// The same label for a real instant. app.js writes
    /// `timeLabel(at.toTimeString().slice(0, 5))`, which is the LOCAL
    /// hour and minute of that instant — so this reads them the same way.
    static func timeLabel(of date: Date) -> String? {
        let p = calendar.dateComponents([.hour, .minute], from: date)
        guard let h = p.hour, let m = p.minute else { return nil }
        return timeLabel(pad2(h) + ":" + pad2(m))
    }

    // MARK: dayLabel / dayPhrase (app.js:722-742)

    /// Today, Tomorrow, Mon 9 Mar — relative where that reads faster,
    /// and the year only when it is not this one.
    static func dayLabel(_ key: String, today: String = WebDates.dayKey()) -> String {
        DayKey.dayLabel(key, today: today)
    }

    /// The same label, fit for the middle of a sentence. Today wants
    /// lowercasing there; Thu 27 Aug does not — lowercasing the lot
    /// turns it into thu 27 aug.
    static func dayPhrase(_ key: String, today: String = WebDates.dayKey()) -> String {
        let label = dayLabel(key, today: today)
        switch label {
        case "Today", "Tomorrow", "Yesterday": return label.lowercased()
        default: return label
        }
    }

    // MARK: whenLabel (app.js:745-749)

    /// The whole stamp as one string: Tomorrow · 4pm. nil when the task
    /// is on no day at all — a time with no day prints nothing here,
    /// exactly as the web does, because everything downstream keys off
    /// `when`.
    ///
    /// Takes the two fields rather than a task so the date layer does
    /// not depend on the model layer.
    static func whenLabel(when: String?, at: String?,
                          today: String = WebDates.dayKey()) -> String? {
        guard let when, !when.isEmpty else { return nil }
        let day = dayLabel(when, today: today)
        guard let t = timeLabel(at) else { return day }
        return day + " · " + t
    }

    // MARK: minutesLabel (app.js:1091-1093)

    /// `m < 60 ? m min : round(m / 60 * 10) / 10 hr`, with JavaScript's
    /// number printing: 120 reads 2 hr, not 2.0 hr, and 75 reads 1.3 hr.
    ///
    /// This is NOT what the home screen prints. paintToday writes
    /// `${t.minutes} min` raw (app.js:4221), so a 90-minute task reads
    /// 90 min on home and 1.5 hr on the lists. Copy.homeRowMeta keeps
    /// that difference.
    static func minutesLabel(_ m: Int) -> String {
        if m < 60 { return "\(m) min" }
        let tenths = Int((Double(m) / 60.0 * 10.0).rounded(.toNearestOrAwayFromZero))
        let whole = tenths / 10
        let rest = tenths % 10
        return rest == 0 ? "\(whole) hr" : "\(whole).\(rest) hr"
    }

    // MARK: utcDay (app.js:2654-2656)

    /// The day the feedback allowance is spent against, and it is UTC on
    /// both sides on purpose: a local day would let anyone with a
    /// timezone get a second go, and would drift out of step with the
    /// server index that does the real work.
    static func utcDay(_ d: Date = Date()) -> String {
        let p = utcCalendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }

    // MARK: noteWhen (app.js:4455-4466)

    /// Relative for the first week, because 3 days ago is what you
    /// actually remember about a note, and a date after that, because
    /// 23 days ago is not.
    ///
    /// `ms` is the note's updatedAt: milliseconds since the epoch, the
    /// unit the store keeps.
    static func noteWhen(_ ms: Double) -> String {
        let at = Date(timeIntervalSince1970: ms / 1000)
        let day = dayKey(at)
        let today = dayKey()
        if day == today { return timeLabel(of: at) ?? "Today" }

        let gap = daysBetween(day, today) ?? 0
        if gap == 1 { return "Yesterday" }
        if gap > 1 && gap < 7 { return "\(gap) days ago" }
        return dayLabel(day, today: today)
    }
}
