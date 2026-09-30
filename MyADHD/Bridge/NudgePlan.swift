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

   **Two kinds of nudge, taking turns.** Every other slot is the Today
   card's pick — and not always its first thing: the card holds up to
   three, and the slots walk through them, so an urgent task at the top no
   longer takes every buzz of the day. The slots between them ASK about
   one of the other open tasks, chosen in a shuffled order: "is this one
   urgent?", with a button that says it is and one that says it can wait.
   Somebody whose list has one urgent thing in it was hearing about that
   one thing fifteen times a day while the rest went unmentioned, and
   some of the rest may be urgent too — nobody has said. The shuffle is
   seeded by the day, so rebuilding the schedule on every write does not
   reshuffle it.

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
    /// The "is this one urgent?" kind, which carries the two answers.
    var asks = false
    /// The task it asks about. Only set when `asks` is.
    var taskID: String? = nil
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

    /// The question's title. One tone for all three levels: it is a
    /// question, not a push, and the level already set how often it comes.
    static func askTitle(name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? Copy.Nudges.askTitlePlain : Copy.Nudges.askTitle(name: name)
    }

    /// What a question can be about: open, not already on the card, and
    /// not already urgent by the matrix's own rule — urgency 5, or due on
    /// or before the day. Asking whether an urgent thing is urgent is
    /// noise, and the card already rings about it.
    static func askable(_ tasks: [TaskItem], today: String, besides card: [TaskItem]) -> [TaskItem] {
        let onCard = Set(card.map(\.id))
        return tasks.filter { t in
            guard !t.done, !onCard.contains(t.id), t.urgency < 5 else { return false }
            if let when = t.when, !when.isEmpty, when <= today { return false }
            return true
        }
    }

    /// A Fisher–Yates shuffle driven by the day, so the order is random
    /// across days and the same all day long. `hashValue` would not do:
    /// Swift seeds it per launch, and the schedule is rebuilt constantly.
    static func shuffled(_ items: [TaskItem], seed: String) -> [TaskItem] {
        var state: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 { state = (state ^ UInt64(byte)) &* 0x100000001b3 }
        func next() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }
        var out = items
        guard out.count > 1 else { return out }
        for i in stride(from: out.count - 1, to: 0, by: -1) {
            let j = Int(next() % UInt64(i + 1))
            out.swapAt(i, j)
        }
        return out
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
        let askTitle = askTitle(name: name)
        var out: [NudgePlan] = []

        for offset in 0..<max(0, days) {
            let day = DayKey.adding(offset, to: today)
            let card = Ordering.homeToday(tasks, today: day)
            guard !card.next.isEmpty else { continue }
            let asking = shuffled(askable(tasks, today: day, besides: card.next), seed: day)

            /* Counted over the slots that actually ring, so the first one
               left in a day is always the card's first thing. */
            var told = 0
            var asked = 0

            for (i, clock) in clocks.enumerated() {
                guard let stamp = ReminderPlanner.components(day: day, at: clock),
                      let fire = DayKey.calendar.date(from: stamp.parts),
                      fire > now else { continue }
                if taskFires.contains(where: { abs($0.timeIntervalSince(fire)) < clearance }) {
                    continue
                }

                var parts = stamp.parts
                parts.calendar = DayKey.calendar
                let id = idPrefix + day + "." + clock

                /* The odd slots ask, whenever there is something to ask
                   about. A list with nothing but the card's three on it
                   rings the card every time, as it always did. */
                if i % 2 == 1, !asking.isEmpty {
                    let task = asking[asked % asking.count]
                    asked += 1
                    out.append(NudgePlan(id: id,
                                         title: askTitle,
                                         body: task.title + "\n" + Copy.Nudges.askHint,
                                         fire: fire,
                                         parts: parts,
                                         asks: true,
                                         taskID: task.id))
                    continue
                }

                let task = card.next[told % card.next.count]
                told += 1
                var body = card.title + ": " + task.title
                if i == clocks.count - 1, let line = Copy.Calendar.undated(undated) {
                    body += "\n" + line
                }
                out.append(NudgePlan(id: id,
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
