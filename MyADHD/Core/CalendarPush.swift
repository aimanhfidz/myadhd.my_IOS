/* ============================================================
   MyADHD/Core/CalendarPush.swift — what belongs on Google Calendar

   The pure half of the calendar push (app.js:3386-3478): which tasks go
   on the calendar, the signature that says whether an event is still
   right, the event built from a task, and the plan a pass works through.
   No network and no store writes, which is what lets `Checks/calendar.sh`
   hold every one of them against the real app.js in JavaScriptCore.
   `Sync/CalendarSync.swift` is the half that talks to Google.

   **The signature has to match the web's to the byte.** It is stored on
   the task as `gcal.sig`, and the task travels between devices. If this
   build wrote "20" where app.js writes "20" for one task and something
   else for another, each device would read the other's signature as
   stale, patch the event, store its own, and push it back up — two
   devices taking turns rewriting one event for ever. So `eventSig` reads
   the raw stored values the way `Array.prototype.join` does (absent and
   null are the empty string) rather than the typed getters, which
   clamp and default.
   ============================================================ */

import Foundation

enum CalendarPush {

    /// `syncable` (app.js:3416): still to do, and pinned to a day.
    /// `!!t.when` — the empty string is no day.
    static func syncable(_ t: TaskItem) -> Bool {
        guard !t.done else { return false }
        guard let when = t.when else { return false }
        return !when.isEmpty
    }

    /// `eventSig` (app.js:3422-3424):
    /// `[t.title, t.when, t.at || '', t.minutes, t.firstStep || ''].join(' :: ')`.
    static func eventSig(_ t: TaskItem) -> String {
        [joined(t.raw("title")),
         joined(t.raw("when")),
         orEmpty(t.raw("at")),
         joined(t.raw("minutes")),
         orEmpty(t.raw("firstStep"))].joined(separator: " :: ")
    }

    /// One element of `Array.prototype.join`: undefined and null are "".
    private static func joined(_ v: JSONValue?) -> String {
        guard let v, !v.isNull else { return "" }
        return Normalize.jsString(v)
    }

    /// `x || ''`: every falsy value is "", everything else is `String(x)`.
    private static func orEmpty(_ v: JSONValue?) -> String {
        guard let v, v.isTruthy else { return "" }
        return Normalize.jsString(v)
    }

    // MARK: - The event (app.js:3430-3461)

    /// `eventBody(t)`, as the JSON object the Calendar API is sent. Key
    /// order is app.js's: summary, description, extendedProperties, then
    /// start and end.
    static func eventBody(_ t: TaskItem, timeZone: String) -> JSONValue {
        var body = JSONObject()
        body.set("summary", .string(t.title))

        /* The first step is the whole point of the app, so it travels with
           the event: seeing "Open the letter and read the first line" in a
           phone notification is worth far more than the title again. */
        var lines: [String] = []
        if !t.firstStep.isEmpty { lines.append(Copy.GoogleCalendar.firstStep(t.firstStep)) }
        lines.append(Copy.GoogleCalendar.meta(minutes: WebDates.minutesLabel(t.minutes),
                                              energy: t.energy,
                                              category: Copy.Categories.label(t.category)))
        lines.append("")
        lines.append(Copy.GoogleCalendar.addedBy)
        body.set("description", .string(lines.joined(separator: "\n")))

        /* Stamped so an event can be traced back to its task from the
           Google side. `CalendarSync` leans on this: it is how a device
           finds an event another device already made for the same task. */
        body.set("extendedProperties", .object(JSONObject([
            ("private", .object(JSONObject([("myadhdId", .string(t.id))]))),
        ])))

        let when = t.when ?? ""
        if let at = t.at, !at.isEmpty, let start = startOf(day: when, at: at) {
            let end = start.addingTimeInterval(TimeInterval(t.minutes) * 60)
            body.set("start", .object(JSONObject([
                ("dateTime", .string(localStamp(start))), ("timeZone", .string(timeZone)),
            ])))
            body.set("end", .object(JSONObject([
                ("dateTime", .string(localStamp(end))), ("timeZone", .string(timeZone)),
            ])))
        } else {
            /* A day with no time is an all-day event, not an invented 9am.
               The end date of an all-day event is exclusive, hence the +1. */
            body.set("start", .object(JSONObject([("date", .string(when))])))
            body.set("end", .object(JSONObject([
                ("date", .string(WebDates.addDays(1, toKey: when))),
            ])))
        }
        return .object(body)
    }

    /// `keyToDate(t.when)` then `setHours(h, m, 0, 0)`, in this device's zone.
    private static func startOf(day: String, at: String) -> Date? {
        let parts = at.split(separator: ":").map { Int($0) ?? 0 }
        guard parts.count >= 2, let midnight = WebDates.keyToDate(day) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: midnight)
    }

    /// `localStamp` (app.js:3426): `YYYY-MM-DDTHH:MM:00`, local, no offset —
    /// the offset is the `timeZone` beside it.
    static func localStamp(_ d: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.hour, .minute], from: d)
        return WebDates.dayKey(d) + "T" + pad2(c.hour ?? 0) + ":" + pad2(c.minute ?? 0) + ":00"
    }

    private static func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    // MARK: - The plan (app.js:3493-3502)

    enum Step: Equatable {
        case add(String)       // a task id
        case edit(String)
        case drop(String)
        case kill(String)      // an event id whose task is gone
    }

    /// What a pass has to do, worked out before anything is awaited. A
    /// snapshot: each step re-reads its task before acting, because the
    /// store can change while a request is in the air.
    static func plan(tasks: [TaskItem], orphans: [String]) -> [Step] {
        var out: [Step] = []
        for t in tasks where !t.id.isEmpty {
            if syncable(t) {
                if let ref = t.gcal {
                    if ref.sig != eventSig(t) { out.append(.edit(t.id)) }
                } else {
                    out.append(.add(t.id))
                }
            } else if t.gcal != nil {
                out.append(.drop(t.id))   // ticked off, or its day was taken away
            }
        }
        for id in orphans { out.append(.kill(id)) }
        return out
    }

    /// How many open tasks carry a day — the number the card quotes.
    static func dated(_ tasks: [TaskItem]) -> Int {
        tasks.filter(syncable).count
    }
}
