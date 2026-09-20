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

   ---------------------------------------------------------------------
   One door in: `sync(json:)`. The caller already has the store's bytes —
   `StoreBridge` hands it exactly what `AppStore` just wrote — so there
   is nothing to ask anyone for.

   There were two until the cutover. The other one read the store out of
   the page with `evaluateJavaScript` and went when the page did; only
   the read ever differed, and `Checks/bridge.swift` proved the two
   inputs produced the same schedule before the web one was removed.

   This route deliberately does NOT call `TaskBridge.write`. The web one
   did, because it was riding the single read it got and the widget's
   copy had to come off the same one. Here `StoreBridge` calls
   `TaskBridge` itself, with the same bytes, in the same pass — doing it
   again would be two keychain writes of one snapshot.

   The rules — which tasks ring, at what time, in what order, how many —
   are in `Bridge/ReminderPlan.swift`, unchanged and testable off-device.
   ============================================================ */

import UIKit
import UserNotifications

enum Reminders {

    /// The key app.js writes its whole state under.
    private static let storeKey = AppConfig.storeKey

    /// Ours, so a rebuild never touches a notification somebody else set.
    private static let idPrefix = "myadhd.task."

    /// Which tasks ring and when. `ReminderPlanner.parse` is this file's
    /// old `parse()`, moved rather than rewritten — see that file's header.
    static func parse(_ json: String?, now: Date = Date()) -> [ReminderPlan] {
        ReminderPlanner.parse(json, now: now)
    }

    private typealias Item = ReminderPlan

    // MARK: - the native pass

    /// Rebuilds the schedule from bytes the caller already has.
    ///
    /// The background task is here for the same reason it is on the web
    /// route below: the most valuable moment to run this is the moment the
    /// app is being put away, which is also the moment iOS stops giving it
    /// time, and the three notification-centre round trips underneath are
    /// every one of them asynchronous.
    ///
    /// A nil `json` is "I could not read the store", never "the store is
    /// empty" — rebuilding from that would cancel every reminder the app
    /// has. It returns without touching the schedule, exactly as the web
    /// route does when the page does not answer.
    static func sync(json: String?) {
        guard let json else { return }

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

        let items = parse(json)
        authorize(forItems: items) { allowed in
            guard allowed else { finish(); return }
            replaceSchedule(with: items, then: finish)
        }
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
