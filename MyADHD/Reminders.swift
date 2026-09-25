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

   ---------------------------------------------------------------------
   Two more kinds ride the same pass, and share the same 64 slots:

   - **Nudges** (`Bridge/NudgePlan.swift`) — through the waking day, what
     is next, as often as the level chosen in Settings asks. On unless
     switched off there (`NudgeSettings`).
   - **Note reminders** (`Bridge/NoteReminderPlan.swift`) — the bell in
     the Notes editor, which until now saved a time and never rang.

   Each kind has its own id prefix, so each pass clears exactly what it
   is about to rewrite and nothing another app — or iOS — put there.
   `NotificationBudget` decides how many task reminders fit beside them.
   ============================================================ */

import UIKit
import UserNotifications

enum Reminders {

    /// The key app.js writes its whole state under.
    private static let storeKey = AppConfig.storeKey

    /// Ours, so a rebuild never touches a notification somebody else set.
    private static let idPrefix = "myadhd.task."

    /// Every prefix a pass rewrites — all three are rebuilt together.
    private static let ours = [idPrefix, NudgePlanner.idPrefix, NoteReminderPlanner.idPrefix]

    /// Which screen a tap on each kind opens. Read by `NotificationRouter`.
    static let tabKey = "myadhd.tab"

    /// Which tasks ring and when. `ReminderPlanner.parse` is this file's
    /// old `parse()`, moved rather than rewritten — see that file's header.
    static func parse(_ json: String?, now: Date = Date()) -> [ReminderPlan] {
        ReminderPlanner.parse(json, now: now)
    }

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

        let plan = schedule(json)
        /* Only a dated task or a note's bell earns the prompt — something
           the person set a time on. The nudges alone never ask: they are
           on by default, and asking because of them put the prompt over
           the splash for anybody with an open task, which is how an app
           gets a permanent no. They ring once permission is given, by a
           dated task's prompt or by the switch in Settings. */
        authorize(asking: !plan.tasks.isEmpty || !plan.notes.isEmpty) { allowed in
            guard allowed else { finish(); return }
            replaceSchedule(with: plan, then: finish)
        }
    }

    /// The three kinds, read off the same bytes and fitted into iOS's 64.
    struct Schedule {
        var tasks: [ReminderPlan]
        var notes: [NoteReminderPlan]
        var nudges: [NudgePlan]
        var isEmpty: Bool { tasks.isEmpty && notes.isEmpty && nudges.isEmpty }
    }

    static func schedule(_ json: String, now: Date = Date()) -> Schedule {
        let doc = StoreDocument.load(text: json)
        let tasks = parse(json, now: now)
        let notes = NoteReminderPlanner.plan(notes: doc.notes, now: now)
        let nudges = NudgeSettings.enabled
            ? NudgePlanner.plan(tasks: doc.tasks,
                                slots: NudgeSettings.slots,
                                level: NudgeSettings.level,
                                name: doc.profile.name,
                                taskFires: tasks.map(\.fire),
                                now: now)
            : []
        let room = NotificationBudget.tasks(given: notes.count, nudges.count)
        return Schedule(tasks: Array(tasks.prefix(room)), notes: notes, nudges: nudges)
    }

    // MARK: - permission

    /// Never asked on launch. The prompt only makes sense once there is a
    /// dated task to ring about, and asking before that is how an app gets
    /// a permanent no.
    private static func authorize(asking: Bool, then: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                then(true)
            case .notDetermined:
                guard asking else { then(false); return }
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in then(granted) }
            default:
                then(false)
            }
        }
    }

    // MARK: - writing the schedule

    private static func replaceSchedule(with plan: Schedule, then done: @escaping () -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
          center.getDeliveredNotifications { delivered in
            let stale = pending.map(\.identifier).filter { id in ours.contains { id.hasPrefix($0) } }
            center.removePendingNotificationRequests(withIdentifiers: stale)

            /* **A rescued reminder keeps the hour it was first given.** The
               rescue is "an hour from now", and this runs on every write
               and every return to the app — so an untimed task dated today
               slid an hour later each time the app was touched, and a
               person using it never heard it; once it had rung, the next
               rebuild set it off again an hour on. So: still pending and
               still ahead, it keeps that trigger; already delivered today,
               it has said its piece. */
            let now = Date()
            var heldFor: [String: DateComponents] = [:]
            for request in pending where request.identifier.hasPrefix(idPrefix) {
                guard let trigger = request.trigger as? UNCalendarNotificationTrigger,
                      let next = trigger.nextTriggerDate(), next > now else { continue }
                heldFor[request.identifier] = trigger.dateComponents
            }
            let rangToday = Set(delivered
                .filter { $0.request.identifier.hasPrefix(idPrefix)
                    && DayKey.calendar.isDate($0.date, inSameDayAs: now) }
                .map(\.request.identifier))

            var requests: [UNNotificationRequest] = []

            for item in plan.tasks {
                var parts = item.parts
                if item.rescued {
                    if let kept = heldFor[idPrefix + item.id] {
                        parts = kept
                    } else if rangToday.contains(idPrefix + item.id) {
                        continue
                    }
                }
                let content = UNMutableNotificationContent()
                content.title = item.title
                if !item.step.isEmpty { content.body = item.step }
                content.sound = .default
                content.threadIdentifier = "myadhd.tasks"
                content.userInfo = [tabKey: AppTab.home.rawValue]
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                requests.append(UNNotificationRequest(identifier: idPrefix + item.id,
                                                      content: content, trigger: trigger))
            }

            /* Grouped on their own, so a day's worth stacks as one pile
               in Notification Centre rather than burying a task that is
               actually due. */
            for item in plan.nudges {
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.body
                content.sound = .default
                content.threadIdentifier = "myadhd.nudges"
                content.userInfo = [tabKey: AppTab.home.rawValue]
                let trigger = UNCalendarNotificationTrigger(dateMatching: item.parts, repeats: false)
                requests.append(UNNotificationRequest(identifier: item.id,
                                                      content: content, trigger: trigger))
            }

            for item in plan.notes {
                let content = UNMutableNotificationContent()
                content.title = item.title
                if !item.body.isEmpty { content.body = item.body }
                content.sound = .default
                content.threadIdentifier = "myadhd.notes"
                content.userInfo = [tabKey: AppTab.notes.rawValue]
                let trigger = UNCalendarNotificationTrigger(dateMatching: item.parts,
                                                            repeats: item.repeats)
                requests.append(UNNotificationRequest(identifier: item.id,
                                                      content: content, trigger: trigger))
            }

            let pen = DispatchGroup()
            for request in requests {
                pen.enter()
                center.add(request) { _ in pen.leave() }
            }
            pen.notify(queue: .main) { done() }
          }
        }
    }
}

// MARK: - the nudges' three settings

/// Whether the nudges ring, how often, and between which hours. The
/// phone's own business, so it lives in UserDefaults beside the calendar's
/// `myadhd.native.*` keys, never on the document — a synced "every hour"
/// would ring on every device somebody owns at once. App target only, like
/// every other default here.
enum NudgeSettings {

    static let enabledKey = "myadhd.native.nudges"
    static let levelKey = "myadhd.native.nudgeLevel"
    static let windowKey = "myadhd.native.nudgeWindow"

    /// On until somebody turns it off. Asked for, not imposed: nothing
    /// rings until iOS has been given permission.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// It's Okay I Know until somebody asks for more — the gentlest one,
    /// and the nearest to the three a day this started as.
    static var level: NudgeLevel {
        get { UserDefaults.standard.string(forKey: levelKey).flatMap(NudgeLevel.init) ?? .okay }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: levelKey) }
    }

    /// "From" and "until", two "HH:MM" clocks. Anything else stored there
    /// is ignored and the default window comes back.
    static var window: (from: String, until: String) {
        get {
            let saved = UserDefaults.standard.stringArray(forKey: windowKey) ?? []
            guard saved.count == 2,
                  NudgePlanner.minutes(saved[0]) != nil,
                  NudgePlanner.minutes(saved[1]) != nil else {
                return (NudgePlanner.defaultFrom, NudgePlanner.defaultUntil)
            }
            return (saved[0], saved[1])
        }
        set { UserDefaults.standard.set([newValue.from, newValue.until], forKey: windowKey) }
    }

    /// The clocks the level rings at inside the window.
    static var slots: [String] {
        NudgePlanner.slots(every: level.hours, from: window.from, until: window.until)
    }
}
