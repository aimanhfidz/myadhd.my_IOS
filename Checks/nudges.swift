/* ============================================================
   Checks/nudges.swift — what rings, besides a dated task

   Not an Xcode target. A `swiftc` program over the app target's own
   sources.

       Checks/nudges.sh

   `Reminders.swift` imports UIKit and UserNotifications and cannot be
   compiled here; everything it decides is in three Foundation files that
   can — `ReminderPlan`, `NudgePlan` and `NoteReminderPlan` — and this
   holds those to the rules their headers write down:

     1. **A nudge rings only when it has something to say**, never in the
        past, and never on top of a task that is already ringing within
        half an hour of it.
     2. **It says what the Today card says**, as of the day it rings on:
        the card's own title and its first task, and — on the last slot
        of the day only — the line about what is waiting on your lists.
        Its title is the level's, calling the person by name when there
        is one.
     2b. **It rings as often as asked, inside the window** — every hour,
        two or four, from and until two clock times.
     3. **A note's bell becomes the right trigger** for each repeat, a
        repeat that has not started yet rings once on its first day, and
        a note with no words still says something.
     4. **The three kinds fit in iOS's 64** with room to spare.

   There is no web original on the other side of any of it: the website
   sends no notifications. It runs in three zones because every slot is a
   local clock time on a local day.
   ============================================================ */

import Foundation

// MARK: - the report

final class Report {
    private(set) var checks = 0
    private(set) var failures: [String] = []
    private var section = ""

    func open(_ name: String) {
        section = name
        print("\n  \(name)")
    }

    @discardableResult
    func equal(_ what: String, _ got: String, _ want: String) -> Bool {
        checks += 1
        if got == want {
            print("    ok    \(what)")
            return true
        }
        failures.append("\(section) / \(what)")
        print("    FAIL  \(what)")
        print("      want  \(want)")
        print("      got   \(got)")
        return false
    }

    @discardableResult
    func yes(_ what: String, _ value: Bool) -> Bool {
        equal(what, value ? "true" : "false", "true")
    }
}

// MARK: - fixtures

/// Thursday 24 September 2026, half past ten in the morning, wherever the
/// check is running.
let now: Date = {
    var c = DateComponents()
    c.year = 2026; c.month = 9; c.day = 24; c.hour = 10; c.minute = 30
    return DayKey.calendar.date(from: c)!
}()

func at(_ day: String, _ clock: String) -> Date {
    let stamp = ReminderPlanner.components(day: day, at: clock)!
    return DayKey.calendar.date(from: stamp.parts)!
}

let tasksJSON = """
{"tasks":[
 {"id":"t1","title":"Pay the bill","when":"2026-09-22","done":false},
 {"id":"t2","title":"Call the bank","when":"2026-09-24","at":"13:10","done":false},
 {"id":"t3","title":"Renew passport","urgency":5,"done":false},
 {"id":"t4","title":"Sort photos","done":false},
 {"id":"t5","title":"Old thing","when":"2026-09-24","done":true}
]}
"""

/// The three clocks the first version rang at. The cases below that were
/// written against them still pass them, so they hold as they were.
let classic = ["09:00", "13:00", "17:00"]

let notesJSON = """
{"notes":[
 {"id":"n1","title":"Dentist","body":"Bring the card","remindOn":"2026-09-25","remindAt":"08:00","repeat":""},
 {"id":"n2","title":"Gone","body":"","remindOn":"2026-09-20","remindAt":"08:00","repeat":""},
 {"id":"n3","title":"Pills","body":"","remindOn":"2026-09-01","remindAt":"07:30","repeat":"daily"},
 {"id":"n4","title":"Bins","body":"","remindOn":"2026-09-21","repeat":"weekly"},
 {"id":"n5","title":"Rent","body":"","remindOn":"2026-08-15","remindAt":"20:00","repeat":"monthly"},
 {"id":"n6","title":"Stretch","body":"","remindOn":"2026-10-01","remindAt":"06:00","repeat":"daily"},
 {"id":"n7","title":"","body":"Buy milk\\nand eggs","remindOn":"2026-09-26","remindAt":"10:00","repeat":""},
 {"id":"n8","title":"No bell","body":"","repeat":""},
 {"id":"n9","title":"","body":"","remindOn":"2026-09-27","remindAt":"10:00","repeat":""}
]}
"""

// MARK: - the checks

@main
struct NudgeChecks {

    static func main() {
        let r = Report()
        print("nudges")
        print("  zone     \(TimeZone.current.identifier)")

        saysWhatIsNext(r)
        ringsAsOftenAsAsked(r)
        staysQuietWhenItShould(r)
        ringsNotes(r)
        startsAndEndsRepeatsRight(r)
        fitsInSixtyFour(r)

        print("\n---")
        print("checked \(r.checks), \(r.failures.count) failed")
        if !r.failures.isEmpty {
            for f in r.failures { print("  FAIL \(f)") }
            exit(1)
        }
        print("nudges OK")
        exit(0)
    }

    static func saysWhatIsNext(_ r: Report) {
        r.open("what a nudge says")

        let tasks = StoreDocument.load(text: tasksJSON).tasks
        let fires = ReminderPlanner.parse(tasksJSON, now: now).map(\.fire)
        r.equal("the one dated task ahead rings at its own time",
                "\(fires.count) \(fires.first == at("2026-09-24", "13:10"))", "1 true")

        let plan = NudgePlanner.plan(tasks: tasks, slots: classic, taskFires: fires, now: now)
        let undatedLine = Copy.Calendar.undated(2)!

        r.equal("today keeps only 17:00, then three a day for four days",
                "\(plan.count)", "13")
        r.equal("09:00 has gone and 13:00 sits under the bank's 13:10",
                plan.first?.id ?? "-", "myadhd.nudge.2026-09-24.17:00")
        r.equal("with no name, titled by the default level alone",
                plan.first?.title ?? "-", Copy.Nudges.okayTitlePlain)
        r.equal("the body is the Today card's title, one late, then the late thing and the lists' line",
                plan.first?.body ?? "-",
                Copy.Home.todayTitle(late: 1, today: 1) + ": Pay the bill\n" + undatedLine)

        let tomorrow = plan.first { $0.id == "myadhd.nudge.2026-09-25.09:00" }
        r.equal("tomorrow the bank is late too, and the morning has no lists' line",
                tomorrow?.body ?? "-", Copy.Home.todayTitle(late: 2, today: 0) + ": Pay the bill")

        r.yes("only the last slot of each day carries the lists' line",
              plan.allSatisfy { $0.body.contains("\n") == $0.id.hasSuffix(".17:00") })
        r.yes("every id is its own",
              Set(plan.map(\.id)).count == plan.count)
        r.yes("soonest first",
              zip(plan, plan.dropFirst()).allSatisfy { $0.fire < $1.fire })
        r.yes("none of them in the past",
              plan.allSatisfy { $0.fire > now })
        r.yes("each rings at the slot its id names",
              plan.allSatisfy { p in
                  let parts = p.id.dropFirst(NudgePlanner.idPrefix.count).split(separator: ".")
                  return at(String(parts[0]), String(parts[1])) == p.fire
              })

        let one = NudgePlanner.plan(tasks: tasks, slots: ["25:00", "08:00", "08:00"],
                                    taskFires: fires, now: now)
        r.equal("a slot that is not a clock is dropped, a repeated one kept once",
                "\(one.count) \(Set(one.map { $0.id.suffix(5) }).sorted())", "4 [\"08:00\"]")
        r.yes("and a day's only slot is its last, so it carries the line",
              one.allSatisfy { $0.body.hasSuffix(undatedLine) })

        let long = NudgePlanner.plan(tasks: tasks, taskFires: fires, now: now, days: 10)
        r.equal("ten days ahead is still capped", "\(long.count)", "\(NudgePlanner.limit)")
    }

    static func ringsAsOftenAsAsked(_ r: Report) {
        r.open("how often, and what it calls you")

        let hourly = NudgePlanner.slots(every: 1, from: "08:00", until: "22:00")
        r.equal("every hour from eight until ten at night is fifteen",
                "\(hourly.count) \(hourly.first ?? "-") \(hourly.last ?? "-")", "15 08:00 22:00")
        let twoly = NudgePlanner.slots(every: 2, from: "08:00", until: "22:00")
        r.equal("every two hours is eight", "\(twoly.count) \(twoly.last ?? "-")", "8 22:00")
        r.equal("every four is four, and none past ten",
                NudgePlanner.slots(every: 4, from: "08:00", until: "22:00").joined(separator: ","),
                "08:00,12:00,16:00,20:00")
        r.equal("which is what an untouched Settings rings at",
                NudgePlanner.defaultSlots.joined(separator: ","), "08:00,12:00,16:00,20:00")
        r.equal("the minutes are kept",
                NudgePlanner.slots(every: 1, from: "08:30", until: "10:00").joined(separator: ","),
                "08:30,09:30")
        r.equal("a window that ends before it starts is its first clock alone",
                NudgePlanner.slots(every: 1, from: "20:00", until: "09:00").joined(separator: ","),
                "20:00")
        r.equal("a window that is not two clocks is the default one",
                NudgePlanner.slots(every: 4, from: "later", until: "22:00").joined(separator: ","),
                "08:00,12:00,16:00,20:00")
        r.equal("the three levels ring every 1, 2 and 4 hours",
                NudgeLevel.allCases.map { "\($0.hours)" }.joined(separator: ","), "1,2,4")

        r.equal("HELP ME!! calls you by name",
                NudgeLevel.help.title(name: "Aiman"), "Aiman, let's do this one now")
        r.equal("so does Please Remind Me",
                NudgeLevel.please.title(name: "Aiman"), "Hey Aiman, reminding you")
        r.equal("and It's Okay I Know",
                NudgeLevel.okay.title(name: "Aiman"), "Just so you know, Aiman")
        r.equal("no name, no name in it",
                NudgeLevel.allCases.map { $0.title(name: "") }.joined(separator: "|"),
                "Let's do this one now|Reminding you|Just so you know")
        r.equal("a name of spaces is no name, and a name is trimmed",
                NudgeLevel.please.title(name: "   ") + "|" + NudgeLevel.okay.title(name: " Aiman "),
                "Reminding you|Just so you know, Aiman")

        let tasks = StoreDocument.load(text: tasksJSON).tasks
        let fires = ReminderPlanner.parse(tasksJSON, now: now).map(\.fire)
        let help = NudgePlanner.plan(tasks: tasks, slots: hourly, level: .help, name: "Aiman",
                                     taskFires: fires, now: now)
        let today = help.filter { $0.id.contains("2026-09-24.") }.map { String($0.id.suffix(5)) }

        r.equal("every hour is held to the limit", "\(help.count)", "\(NudgePlanner.limit)")
        r.equal("today: eleven o'clock on, 13:00 left to the bank's 13:10",
                today.joined(separator: ","),
                "11:00,12:00,14:00,15:00,16:00,17:00,18:00,19:00,20:00,21:00,22:00")
        r.equal("and the limit runs out tomorrow evening",
                help.last?.id ?? "-", "myadhd.nudge.2026-09-25.20:00")
        r.yes("every one titled by the level, with the name",
              help.allSatisfy { $0.title == "Aiman, let's do this one now" })
        r.yes("only ten at night carries the lists' line today",
              help.filter { $0.id.contains("2026-09-24.") }
                  .allSatisfy { $0.body.contains("\n") == $0.id.hasSuffix(".22:00") })
        r.yes("soonest first",
              zip(help, help.dropFirst()).allSatisfy { $0.fire < $1.fire })
        r.yes("none of them outside eight until ten",
              help.allSatisfy { p in
                  let c = DayKey.calendar.dateComponents([.hour, .minute], from: p.fire)
                  let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                  return m >= 8 * 60 && m <= 22 * 60
              })
    }

    static func staysQuietWhenItShould(_ r: Report) {
        r.open("when a nudge stays quiet")

        let done = StoreDocument.load(text: """
            {"tasks":[{"id":"a","title":"Finished","when":"2026-09-24","done":true}]}
            """).tasks
        r.equal("nothing open, nothing said",
                "\(NudgePlanner.plan(tasks: done, now: now).count)", "0")
        r.equal("an empty store says nothing either",
                "\(NudgePlanner.plan(tasks: [], now: now).count)", "0")

        let tasks = StoreDocument.load(text: tasksJSON).tasks
        let crowded = NudgePlanner.plan(tasks: tasks,
                                        slots: classic,
                                        taskFires: [at("2026-09-25", "08:40"),
                                                    at("2026-09-25", "13:31")],
                                        now: now)
        let ids = Set(crowded.map(\.id))
        r.yes("a task ringing twenty minutes before a slot takes it",
              !ids.contains("myadhd.nudge.2026-09-25.09:00"))
        r.yes("one ringing thirty-one minutes after does not",
              ids.contains("myadhd.nudge.2026-09-25.13:00"))
    }

    static func ringsNotes(_ r: Report) {
        r.open("a note's bell")

        let notes = StoreDocument.load(text: notesJSON).notes
        let plan = NoteReminderPlanner.plan(notes: notes, now: now)
        func one(_ id: String) -> NoteReminderPlan? { plan.first { $0.noteID == id } }

        r.equal("the past, the unset and the seventh are left out; soonest first",
                plan.map(\.noteID).joined(separator: ","), "n3,n1,n7,n9,n4,n6")

        let once = one("n1")
        r.equal("once: the day and the time, and no repeat",
                "\(once?.repeats ?? true) \(once?.fire == at("2026-09-25", "08:00"))", "false true")
        r.equal("titled by the note, with its first line under",
                "\(once?.title ?? "-")|\(once?.body ?? "-")", "Dentist|Bring the card")

        let daily = one("n3")
        r.equal("daily repeats on the clock alone",
                "\(daily?.repeats ?? false) \(daily?.parts.hour ?? -1):\(daily?.parts.minute ?? -1) "
                + "day \(daily?.parts.day.map(String.init) ?? "none")",
                "true 7:30 day none")
        r.yes("and next rings tomorrow at half seven",
              daily?.fire == at("2026-09-25", "07:30"))

        let weekly = one("n4")
        r.equal("weekly keeps the weekday it was set on, at nine with no time",
                "\(weekly?.repeats ?? false) wd\(weekly?.parts.weekday ?? -1) \(weekly?.parts.hour ?? -1)",
                "true wd2 9")
        r.yes("the Monday after", weekly?.fire == at("2026-09-28", "09:00"))

        let late = one("n6")
        r.equal("a repeat that has not started rings once on its first day",
                "\(late?.repeats ?? true) \(late?.fire == at("2026-10-01", "06:00"))", "false true")

        r.equal("no title: the first line is the title",
                "\(one("n7")?.title ?? "-")|\(one("n7")?.body ?? "-")", "Buy milk|")
        r.equal("no words at all: the sheet's own word",
                one("n9")?.title ?? "-", Copy.Note.Remind.title)

        let all = NoteReminderPlanner.plan(notes: notes,
                                           now: at("2026-10-02", "12:00"))
        let monthly = all.first { $0.noteID == "n5" }
        r.equal("monthly keeps the day of the month",
                "\(monthly?.repeats ?? false) d\(monthly?.parts.day ?? -1) \(monthly?.parts.hour ?? -1)",
                "true d15 20")
        r.yes("once its first day is behind it, the late starter repeats",
              all.first { $0.noteID == "n6" }?.repeats == true)
    }

    static func startsAndEndsRepeatsRight(_ r: Report) {
        r.open("a repeat's first day, and short months")

        let notes = StoreDocument.load(text: """
            {"notes":[
             {"id":"a","title":"Walk","body":"","remindOn":"2026-09-25","remindAt":"08:00","repeat":"daily"},
             {"id":"b","title":"Bills","body":"","remindOn":"2026-08-31","remindAt":"20:00","repeat":"monthly"},
             {"id":"c","title":"Payday","body":"","remindOn":"2027-01-30","remindAt":"09:00","repeat":"monthly"}
            ]}
            """).notes
        let plan = NoteReminderPlanner.plan(notes: notes, now: now)
        func one(_ id: String) -> NoteReminderPlan? { plan.first { $0.noteID == id } }

        let walk = one("a")
        r.equal("every day from tomorrow repeats from the start, not once",
                "\(walk?.repeats ?? false) \(walk?.fire == at("2026-09-25", "08:00"))", "true true")

        let bills = one("b")
        r.equal("monthly on the 31st rings on the 30th in September, once",
                "\(bills?.repeats ?? true) \(bills?.fire == at("2026-09-30", "20:00"))", "false true")

        let later = NoteReminderPlanner.plan(notes: notes, now: at("2027-02-01", "12:00"))
        let payday = later.first { $0.noteID == "c" }
        r.equal("monthly on the 30th lands on February's last day",
                "\(payday?.fire == at("2027-02-28", "09:00"))", "true")
    }

    static func fitsInSixtyFour(_ r: Report) {
        r.open("sharing iOS's 64")

        let most = NotificationBudget.tasks(given: NoteReminderPlanner.limit, NudgePlanner.limit)
        r.equal("with every nudge and note, tasks still get 30", "\(most)", "30")
        r.yes("and the three together leave room under 64",
              most + NoteReminderPlanner.limit + NudgePlanner.limit <= 64)
        r.equal("with neither, tasks get their own old limit",
                "\(NotificationBudget.tasks(given: 0, 0))", "\(ReminderPlanner.limit)")
    }
}
