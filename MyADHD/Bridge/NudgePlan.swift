/* ============================================================
   MyADHD/Bridge/NudgePlan.swift — a tap on the shoulder, as often as asked

   A dated task rings once, at its time (`ReminderPlan`). That leaves the
   day in between silent, and it leaves everything with no day on it
   silent for ever — which, for most people's lists, is most of them.

   So through the waking day (08:00 to 22:00 unless changed in Settings)
   the app says what is next, as often as the person asked for it: every
   hour for HELP ME!!, every two for Please Remind Me, every four for It's
   Okay I Know (`NudgeLevel`). What it says is the same pick the home
   screen's Today card makes, `Ordering.homeToday` — late first, then
   today, then whatever is most due — asked as of the day the nudge rings
   on.

   **The body is the screen's own words.** The card's title ("2 late",
   "Today", "Next up"), then the first thing on it; the last nudge of the
   day also carries the calendar's line about the things waiting on your
   lists, when there are any. **The title is the person's own ask**: one
   tone per level, calling them by the name the profile screen keeps, and
   simply leaving the name out when it keeps none.

   **A slot is skipped** when it has already gone, when the day has nothing
   on the card at all, or when a task is already ringing within half an
   hour of it — two buzzes for one thing is how notifications get turned
   off.

   **Built ahead, rebuilt often.** A notification's words are fixed when
   it is scheduled, so these are written out as far ahead as `limit`
   reaches — a day and a half of every hour, five days of every four —
   and thrown away and rewritten on every store write and every return to
   the app, exactly as the task reminders are. Days without opening the
   app run out of nudges, which is also the right answer to days without
   opening the app.

   Foundation and `Core/` only, so `Checks/nudges.sh` can run it on a Mac.
   ============================================================ */

import Foundation

struct NudgePlan: Equatable {
    let id: String
    let title: String
    let body: String
    let fire: Date
    let parts: DateComponents
}

/// How hard the person asked to be nudged. The raw values are what
/// `NudgeSettings` stores, so they are names, not the labels on screen.
enum NudgeLevel: String, CaseIterable {
    case help, please, okay

    /// Hours between two nudges inside the window.
    var hours: Int {
        switch self {
        case .help: return 1
        case .please: return 2
        case .okay: return 4
        }
    }

    var label: String {
        switch self {
        case .help: return Copy.Nudges.helpLabel
        case .please: return Copy.Nudges.pleaseLabel
        case .okay: return Copy.Nudges.okayLabel
        }
    }

    var note: String {
        switch self {
        case .help: return Copy.Nudges.everyHour
        case .please: return Copy.Nudges.every2Hours
        case .okay: return Copy.Nudges.every4Hours
        }
    }

    /// A name that is nothing but spaces is no name.
    func title(name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .help: return name.isEmpty ? Copy.Nudges.helpTitlePlain : Copy.Nudges.helpTitle(name: name)
        case .please: return name.isEmpty ? Copy.Nudges.pleaseTitlePlain : Copy.Nudges.pleaseTitle(name: name)
        case .okay: return name.isEmpty ? Copy.Nudges.okayTitlePlain : Copy.Nudges.okayTitle(name: name)
        }
    }
}

enum NudgePlanner {

    static let idPrefix = "myadhd.nudge."

    /// The waking window. Nothing rings outside it, whatever the level.
    static let defaultFrom = "08:00"
    static let defaultUntil = "22:00"

    /// It's Okay I Know over the default window: 08:00, 12:00, 16:00, 20:00.
    static let defaultSlots = slots(every: NudgeLevel.okay.hours, from: defaultFrom, until: defaultUntil)

    /// How far ahead the schedule is written, at most. `limit` usually
    /// stops it sooner.
    static let days = 5

    /// A task ringing this close to a slot has the slot to itself.
    static let clearance: TimeInterval = 30 * 60

    /// A fixed share of iOS's 64, see `NotificationBudget`. HELP ME!! is
    /// fifteen a day over the default window, so this is a day and a half
    /// of it, three days of every two hours, and five of every four.
    static let limit = 24

    /// "HH:MM" every `hours` from `from`, for as long as it is not past
    /// `until`, minutes kept (08:30, 09:30, …). A window that ends before
    /// it starts is its first clock alone; one that is not two clock times
    /// is the default window, rather than a guess.
    static func slots(every hours: Int, from: String, until: String) -> [String] {
        var start = minutes(defaultFrom) ?? 0
        var end = minutes(defaultUntil) ?? 0
        if let a = minutes(from), let b = minutes(until) { (start, end) = (a, b) }
        let step = max(1, hours) * 60
        return stride(from: start, through: max(start, end), by: step).map {
            String(format: "%02d:%02d", $0 / 60, $0 % 60)
        }
    }

    /// Minutes past midnight for "HH:MM", read the way a task's time is.
    static func minutes(_ clock: String) -> Int? {
        guard let stamp = ReminderPlanner.components(day: "2000-01-01", at: clock),
              stamp.timed,
              let hour = stamp.parts.hour, let minute = stamp.parts.minute else { return nil }
        return hour * 60 + minute
    }

    static func plan(tasks: [TaskItem],
                     slots: [String] = defaultSlots,
                     level: NudgeLevel = .okay,
                     name: String = "",
                     taskFires: [Date] = [],
                     now: Date = Date(),
                     days: Int = days) -> [NudgePlan]
    {
        /* In the order they ring, each once. A slot that is not a clock
           time is dropped rather than guessed at, as a task's is. */
        let clocks = Array(Set(slots)).sorted().filter {
            ReminderPlanner.components(day: "2000-01-01", at: $0)?.timed == true
        }
        guard !clocks.isEmpty else { return [] }

        let today = DayKey.of(now)
        let undated = tasks.filter { !$0.done && !Ordering.scheduled($0) }.count
        let title = level.title(name: name)
        var out: [NudgePlan] = []

        for offset in 0..<max(0, days) {
            let day = DayKey.adding(offset, to: today)
            let card = Ordering.homeToday(tasks, today: day)
            guard let first = card.next.first else { continue }

            for (i, clock) in clocks.enumerated() {
                guard let stamp = ReminderPlanner.components(day: day, at: clock),
                      let fire = DayKey.calendar.date(from: stamp.parts),
                      fire > now else { continue }
                if taskFires.contains(where: { abs($0.timeIntervalSince(fire)) < clearance }) {
                    continue
                }

                var body = card.title + ": " + first.title
                if i == clocks.count - 1, let line = Copy.Calendar.undated(undated) {
                    body += "\n" + line
                }

                var parts = stamp.parts
                parts.calendar = DayKey.calendar
                out.append(NudgePlan(id: idPrefix + day + "." + clock,
                                     title: title,
                                     body: body,
                                     fire: fire,
                                     parts: parts))
            }
        }

        return Array(out.sorted { $0.fire < $1.fire }.prefix(limit))
    }
}

// MARK: - sharing iOS's 64

/// iOS keeps 64 pending notifications for an app and silently drops the
/// rest, and three kinds now share them. The two small ones have fixed
/// caps; the task reminders, which were here first and matter most, get
/// everything else up to their own limit — never fewer than
/// `total - NudgePlanner.limit - NoteReminderPlanner.limit`, which is 30.
enum NotificationBudget {

    /// 64, less a few spare — `ReminderPlanner.limit`'s own reasoning.
    static let total = 60

    static func tasks(given notes: Int, _ nudges: Int) -> Int {
        max(0, min(ReminderPlanner.limit, total - notes - nudges))
    }
}
