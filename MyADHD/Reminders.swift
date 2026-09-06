/* ============================================================
   my.adhd for iOS — a task with a time on it should say something

   The web app puts a day and sometimes a clock time on a task, shows it
   as a chip, sorts by it, and pushes it to Google Calendar. What it can
   never do from a home-screen icon on an iPhone is tap you on the
   shoulder at the time: iOS web push only fires for a site the user has
   installed and permitted, and it needs a server pushing it. This app has
   neither, and does not need them — the times are already on the device.

   So this reads the store the web app has already written and turns every
   dated, open task into a local notification. Nothing is invented and
   nothing is stored twice: localStorage stays the truth, and the whole
   schedule is thrown away and rebuilt on each pass, which is what keeps a
   removed task from ringing.

   The body is the task's first step rather than its title, because the
   title is what you already knew and the first step is the thing that
   gets you moving. A notification that says "Renew the road tax" is a
   reminder; one that says "Open the JPJ site and find the plate number"
   is a start.
   ============================================================ */

import UIKit
import UserNotifications
import WebKit

enum Reminders {

    /// The key app.js writes its whole state under.
    private static let storeKey = "myadhd.v1"

    /// Ours, so a rebuild never touches a notification somebody else set.
    private static let idPrefix = "myadhd.task."

    /// iOS keeps 64 pending notifications per app and silently drops the
    /// rest. Soonest first, and leave a few spare.
    private static let limit = 56

    /// A task with a day but no clock time rings mid-morning rather than at
    /// midnight, which is when the day technically starts and nobody is
    /// awake to act on it.
    private static let defaultHour = 9

    /// A task dated today and written at two in the afternoon used to fall
    /// straight through this: nine o'clock had been and gone, so the only
    /// time it had was in the past and it was dropped without a sound. You
    /// dated it today, so it rings today — an hour out, far enough not to
    /// be startling and near enough to still be today.
    ///
    /// Only for a task that never named a time. An explicit half past four
    /// that has already gone is genuinely past, and moving it would be
    /// inventing an appointment the user did not make.
    private static let rescueDelay: TimeInterval = 60 * 60

    /// And nothing rescued rings after this, because the whole point of the
    /// rescue is a task you can still act on. Nine at night is late enough
    /// to catch an afternoon's work and early enough not to be a phone
    /// going off in a dark room.
    private static let quietHour = 21

    private struct Item {
        let id: String
        let title: String
        let step: String
        let fire: Date
        let parts: DateComponents
    }

    // MARK: - the pass

    /// Reads the store out of the page and rebuilds the schedule from it.
    ///
    /// The read and the three notification-centre round trips after it are
    /// every one of them asynchronous, and the most valuable moment to run
    /// this is the moment the app is being put away — which is also the
    /// moment iOS stops giving it time. Hence the background task: without
    /// it the chain gets frozen somewhere in the middle and the schedule is
    /// left half rebuilt.
    static func sync(from web: WKWebView) {
        var ticket = UIBackgroundTaskIdentifier.invalid
        ticket = UIApplication.shared.beginBackgroundTask(withName: "myadhd.reminders") {
            UIApplication.shared.endBackgroundTask(ticket)
            ticket = .invalid
        }
        let finish = {
            guard ticket != .invalid else { return }
            UIApplication.shared.endBackgroundTask(ticket)
            ticket = .invalid
        }

        web.evaluateJavaScript("localStorage.getItem('\(storeKey)')") { value, error in
            /* No page to ask means no answer, not an empty store. Rebuilding
               from that would cancel every reminder the app has — which is
               exactly what a sync fired on launch, before the first load,
               would otherwise do. */
            guard error == nil else { finish(); return }

            let items = parse(value as? String)
            authorize(forItems: items) { allowed in
                guard allowed else { finish(); return }
                replaceSchedule(with: items, then: finish)
            }
        }
    }

    // MARK: - reading what the web app wrote

    private static func parse(_ json: String?, now: Date = Date()) -> [Item] {
        guard let json,
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tasks = root["tasks"] as? [[String: Any]] else { return [] }

        var out: [Item] = []

        for task in tasks {
            if task["done"] as? Bool == true { continue }
            if task["skipped"] as? Bool == true { continue }

            guard let id = task["id"] as? String,
                  let title = task["title"] as? String,
                  let day = task["when"] as? String,
                  let stamp = components(day: day, at: task["at"] as? String),
                  let asked = Calendar.current.date(from: stamp.parts) else { continue }

            var fire = asked
            var parts = stamp.parts

            if fire <= now {
                /* Yesterday stays gone, and so does a time the user actually
                   named. Only an untimed task dated today gets a second
                   chance — and only if there is still a civil hour to take
                   it in. */
                guard !stamp.timed,
                      Calendar.current.isDateInToday(asked),
                      let rescued = rescue(from: now) else { continue }
                fire = rescued
                parts = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: rescued)
            }

            let step = (task["firstStep"] as? String) ?? ""
            out.append(Item(id: id, title: title, step: step, fire: fire, parts: parts))
        }

        return Array(out.sorted { $0.fire < $1.fire }.prefix(limit))
    }

    /// "2026-03-09" and "16:30", the two shapes normalizeDay/normalizeTime
    /// in app.js guarantee. Anything else is skipped rather than guessed at.
    private static func components(day: String, at clock: String?)
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
    private static func rescue(from now: Date) -> Date? {
        let calendar = Calendar.current
        let when = now.addingTimeInterval(rescueDelay)
        guard let cutoff = calendar.date(bySettingHour: quietHour, minute: 0, second: 0, of: now),
              when <= cutoff else { return nil }
        return when
    }

    // MARK: - permission

    /// Never asked on launch. The prompt only makes sense once there is a
    /// dated task to ring about, and asking before that is how an app gets
    /// a permanent no.
    private static func authorize(forItems items: [Item], then: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                then(true)
            case .notDetermined:
                guard !items.isEmpty else { then(false); return }
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in then(granted) }
            default:
                then(false)
            }
        }
    }

    // MARK: - writing the schedule

    private static func replaceSchedule(with items: [Item], then done: @escaping () -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let ours = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)

            let pen = DispatchGroup()
            for item in items {
                let content = UNMutableNotificationContent()
                content.title = item.title
                if !item.step.isEmpty { content.body = item.step }
                content.sound = .default

                let trigger = UNCalendarNotificationTrigger(dateMatching: item.parts, repeats: false)
                let request = UNNotificationRequest(
                    identifier: idPrefix + item.id,
                    content: content,
                    trigger: trigger
                )
                pen.enter()
                center.add(request) { _ in pen.leave() }
            }
            pen.notify(queue: .main) { done() }
        }
    }
}
