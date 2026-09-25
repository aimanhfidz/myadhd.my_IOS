/* ============================================================
   MyADHD/Bridge/ReminderPlan.swift — which tasks ring, and when

   This is `Reminders.parse` and the two helpers it leans on, lifted out
   of `Reminders.swift` **unchanged**. Not a rewrite and not a tidy-up:
   the bodies below are the shell's, comment for comment, because the
   scheduling rules are the one part of the notification path that a
   person notices when it drifts.

   It moved for two reasons, both of them about being able to prove it
   did not change:

   - `Reminders.swift` imports UIKit and UserNotifications, so nothing on
     a Mac can compile it. `Checks/bridge.swift` has to run `parse()` over
     the fixtures on the old input and the new one and compare the two
     lists; that check is only possible if the rules live somewhere a
     host-side `swiftc` can reach. Everything here is Foundation.
   - At the cutover `Reminders.swift` loses its WKWebView entry point.
     The rules are not part of that, and keeping them in a file that is
     about to be edited is how a rule gets edited with it.

   `Reminders` re-exports `parse` under its old name, so every existing
   caller and every existing description of this code still reads true.
   ============================================================ */

import Foundation

/// One task, resolved to the instant it should ring at. `parts` rather
/// than just `fire` because `UNCalendarNotificationTrigger` wants
/// components, and components carry the calendar they are to be read in.
struct ReminderPlan: Equatable {
    let id: String
    let title: String
    let step: String
    let fire: Date
    let parts: DateComponents
    /// Given "an hour from now" by the rescue below rather than a time of
    /// its own. `Reminders` keeps the hour it was first given, because
    /// "now" moves on every rebuild — see `Reminders.replaceSchedule`.
    var rescued: Bool = false
}

enum ReminderPlanner {

    /// iOS keeps 64 pending notifications per app and silently drops the
    /// rest. Soonest first, and leave a few spare.
    static let limit = 56

    /// A task with a day but no clock time rings mid-morning rather than at
    /// midnight, which is when the day technically starts and nobody is
    /// awake to act on it.
    static let defaultHour = 9

    /// A task dated today and written at two in the afternoon used to fall
    /// straight through this: nine o'clock had been and gone, so the only
    /// time it had was in the past and it was dropped without a sound. You
    /// dated it today, so it rings today — an hour out, far enough not to
    /// be startling and near enough to still be today.
    ///
    /// Only for a task that never named a time. An explicit half past four
    /// that has already gone is genuinely past, and moving it would be
    /// inventing an appointment the user did not make.
    static let rescueDelay: TimeInterval = 60 * 60

    /// And nothing rescued rings after this, because the whole point of the
    /// rescue is a task you can still act on. Nine at night is late enough
    /// to catch an afternoon's work and early enough not to be a phone
    /// going off in a dark room.
    static let quietHour = 21

    // MARK: - reading what the store says

    /* Deliberately still JSONSerialization over the raw text rather than
       `StoreDocument`. The input is the same bytes either way — the page's
       `localStorage` yesterday, `AppStore.doc.jsonString` today — and a
       reader that takes fields by name cannot be broken by a decode rule
       changing somewhere else. `Checks/bridge.swift` holds the two inputs
       to exactly this function and asserts the answers match. */
    static func parse(_ json: String?, now: Date = Date()) -> [ReminderPlan] {
        guard let json,
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tasks = root["tasks"] as? [[String: Any]] else { return [] }

        var out: [ReminderPlan] = []

        for task in tasks {
            if task["done"] as? Bool == true { continue }
            if task["skipped"] as? Bool == true { continue }

            guard let id = task["id"] as? String,
                  let title = task["title"] as? String,
                  let day = task["when"] as? String,
                  let stamp = components(day: day, at: task["at"] as? String),
                  let asked = DayKey.calendar.date(from: stamp.parts) else { continue }

            var fire = asked
            var parts = stamp.parts
            var wasRescued = false

            if fire <= now {
                /* Yesterday stays gone, and so does a time the user actually
                   named. Only an untimed task dated today gets a second
                   chance — and only if there is still a civil hour to take
                   it in. */
                guard !stamp.timed,
                      DayKey.calendar.isDate(asked, inSameDayAs: now),
                      let rescued = rescue(from: now) else { continue }
                fire = rescued
                parts = DayKey.calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: rescued)
                wasRescued = true
            }

            /* The trigger reads these components in whatever calendar they
               name, and in the device's calendar when they name none. They
               are Gregorian — see DayKey.calendar — so they say so. */
            parts.calendar = DayKey.calendar

            let step = (task["firstStep"] as? String) ?? ""
            out.append(ReminderPlan(id: id, title: title, step: step, fire: fire, parts: parts,
                                    rescued: wasRescued))
        }

        return Array(out.sorted { $0.fire < $1.fire }.prefix(limit))
    }

    /// "2026-03-09" and "16:30", the two shapes normalizeDay/normalizeTime
    /// in app.js guarantee. Anything else is skipped rather than guessed at.
    static func components(day: String, at clock: String?)
        -> (parts: DateComponents, timed: Bool)? {
        let ymd = day.split(separator: "-").map(String.init).compactMap(Int.init)
        guard ymd.count == 3, day.count == 10 else { return nil }

        var parts = DateComponents()
        parts.year = ymd[0]
        parts.month = ymd[1]
        parts.day = ymd[2]
        parts.hour = defaultHour
        parts.minute = 0

        var timed = false
        if let clock {
            let hm = clock.split(separator: ":").map(String.init).compactMap(Int.init)
            if hm.count == 2, (0...23).contains(hm[0]), (0...59).contains(hm[1]) {
                parts.hour = hm[0]
                parts.minute = hm[1]
                timed = true
            }
        }

        return (parts, timed)
    }

    /// An hour from now, unless that lands in the quiet part of the evening.
    static func rescue(from now: Date) -> Date? {
        let calendar = DayKey.calendar
        let when = now.addingTimeInterval(rescueDelay)
        guard let cutoff = calendar.date(bySettingHour: quietHour, minute: 0, second: 0, of: now),
              when <= cutoff else { return nil }
        return when
    }
}
