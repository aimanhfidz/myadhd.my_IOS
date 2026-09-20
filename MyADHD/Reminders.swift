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
   Two doors in, one room behind them (design.md §2.2).

   `sync(json:)` is the native one: the caller already has the store's
   bytes — `StoreBridge` hands it exactly what `AppStore` just wrote — so
   there is nothing to ask a page for.

   `sync(from: WKWebView)` is the shell's, and it is the one that goes
   away at the cutover. It exists only to do the read; everything after
   the read is the same code, and `Checks/bridge.swift` proves the two
   inputs produce the same schedule.

   What is deliberately NOT symmetrical: the web route also calls
   `TaskBridge.write`, because it is riding the one `evaluateJavaScript`
   the shell gets and the widget's copy must come off the same read. The
   native route does not, because `StoreBridge` calls `TaskBridge` itself,
   with the same bytes, in the same pass. Calling it here as well would
   be two keychain writes of one snapshot.

   The rules — which tasks ring, at what time, in what order, how many —
   are in `Bridge/ReminderPlan.swift`, unchanged and testable off-device.
   ============================================================ */

import UIKit
import UserNotifications
import WebKit

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

    // MARK: - the web pass (deleted at the cutover, with WebScreen)

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

            /* The widget's copy, taken from the same read and taken HERE —
               above the permission gate below, which returns early for
               anyone who declined notifications. A widget has nothing to do
               with notifications and must not be starved by that answer.
               The write is a few milliseconds of keychain, well inside the
               background task this is already holding. */
            TaskBridge.write(from: value as? String)

            let items = parse(value as? String)
            authorize(forItems: items) { allowed in
                guard allowed else { finish(); return }
                replaceSchedule(with: items, then: finish)
            }
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
