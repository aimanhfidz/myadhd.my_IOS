/* ============================================================
   Checks/meetings.swift — the day read off the phone

   Not an Xcode target. A `swiftc` program over the app target's own
   `MyADHD/Core` sources.

       Checks/meetings.sh

   **What this can check and what it deliberately cannot.** An `EKEvent`
   cannot be built by hand: its identifier and its attendee list are
   read-only and arrive from a saved row, so the five guards in
   `EventKitMeetings.meeting(from:)` — cancelled, marked free, declined,
   the birthday and subscription calendars, and the app's own mirrored
   calendar — are only ever exercised against a real event store. They
   are one line each and they are assertions about Apple's API rather
   than about arithmetic. Everything below them is arithmetic, and that
   is what is here.

   There is no app.js to hold this against. The website cannot read a
   diary at all — the Google scope its calendar link holds is allowed to
   touch only the calendar it made itself — so this is the one check in
   the folder with no other implementation on the far side of it. What it
   is held against instead is the four things that would go wrong
   silently:

     1. **The local day and the local clock.** An event at 9am in Kuala
        Lumpur is on the day before in UTC for most of the working day.
        If the mapping ever reached for an ISO8601 string, every meeting
        would land on the wrong square of the month for half the world
        and on the right one here, which is the bug that ships.

     2. **The day is one list.** A task and a meeting interleave by the
        clock. An all-day meeting sorts to the top because it is already
        true at breakfast; a task with no clock sorts to the bottom
        because it is merely unscheduled. Those two look like the same
        case and are opposites.

     3. **A meeting that has become a task stops drawing.** Otherwise
        the same hour is on screen twice, once tickable and once not.

     4. **The task it becomes is an ordinary task.** It goes through
        `normalizeTask`, it carries `fromEvent` where an unknown key
        goes, and the document it lands in still re-encodes byte for
        byte — which is what stops this feature from quietly corrupting
        a store the web app and every other device also read.
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

/// A source that answers from a fixture, so the reader can be driven with
/// no event store anywhere near it.
struct FakeMeetings: MeetingSource {
    var all: [Meeting]
    /// What the phone would say it is reading. Set per fixture, because
    /// the interesting case is a healthy count beside an empty `all`.
    var calendars = 1
    /// Every call is recorded, so a check can prove a read did NOT happen.
    final class Log: @unchecked Sendable { var calls: [(String, String)] = [] }
    var log = Log()

    func meetings(from: String, to: String) -> [Meeting] {
        log.calls.append((from, to))
        return all.filter { $0.when >= from && $0.when <= to }
    }

    func calendarsRead() -> Int { calendars }
}

func meeting(_ id: String,
             _ when: String,
             _ at: String?,
             minutes: Int = 30,
             title: String? = nil,
             calendar: String = "Work") -> Meeting
{
    Meeting(id: id,
            title: title ?? id,
            when: when,
            at: at,
            minutes: minutes,
            isAllDay: at == nil,
            calendarTitle: calendar)
}

func task(_ id: String, _ when: String?, _ at: String?, urgency: Int = 3) -> TaskItem {
    var f = JSONObject()
    f["id"] = .string(id)
    f["title"] = .string(id)
    f["minutes"] = .int(20)
    f["urgency"] = .int(urgency)
    f["when"] = when.map { .string($0) } ?? .null
    f["at"] = at.map { .string($0) } ?? .null
    f["done"] = .bool(false)
    return TaskItem(fields: f)
}

/// A date built in the runtime's own local calendar — the same one
/// `WebDates` reads, so a check of "the local day" means the local day
/// and not the one this machine happens to sit in.
func local(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 0, _ mm: Int = 0) -> Date {
    var parts = DateComponents()
    parts.year = y; parts.month = m; parts.day = d
    parts.hour = hh; parts.minute = mm
    return WebDates.calendar.date(from: parts)!
}

func ids(_ entries: [AgendaEntry]) -> String {
    entries.map { entry in
        switch entry {
        case .task(let t):    return t.id
        case .meeting(let m): return m.id
        }
    }.joined(separator: ",")
}

@main
struct MeetingChecks {

    static func main() {
        let r = Report()
        print("meetings")
        print("  zone     \(TimeZone.current.identifier)")

        mapsTheLocalDayAndClock(r)
        clampsTheLength(r)
        refusesWhatCannotBeDrawn(r)
        ordersTheDayAsOneList(r)
        dropsWhatHasBecomeATask(r)
        readsOnlyWhenItMay(r)
        becomesAnOrdinaryTask(r)

        print("\n---")
        if r.failures.isEmpty {
            print("meetings OK — \(r.checks) checks, all passed")
            exit(0)
        }
        print("meetings FAILED — \(r.failures.count) of \(r.checks) checks:")
        for f in r.failures { print("  - \(f)") }
        exit(1)
    }

    // MARK: - 1. the local day and the local clock

    static func mapsTheLocalDayAndClock(_ r: Report) {
        r.open("the local day and the local clock")

        let start = local(2026, 9, 24, 9, 30)
        let made = EventKitMeetings.make(id: "e1",
                                         title: "Sprint review",
                                         start: start,
                                         end: start.addingTimeInterval(3600),
                                         isAllDay: false,
                                         calendarTitle: "Work")

        r.equal("the day is the store's own key shape", made?.when ?? "nil", "2026-09-24")
        r.equal("the clock is zero-padded HH:MM", made?.at ?? "nil", "09:30")
        r.equal("and it is the day WebDates would give", made?.when ?? "nil",
                WebDates.dayKey(start))

        /* Half past midnight is the case an ISO8601 string gets wrong
           everywhere east of Greenwich, and gets right here — so it is
           the one worth stating. */
        let early = local(2026, 9, 24, 0, 30)
        let atMidnight = EventKitMeetings.make(id: "e2", title: "Oncall handover",
                                               start: early,
                                               end: early.addingTimeInterval(1800),
                                               isAllDay: false,
                                               calendarTitle: "Work")
        r.equal("00:30 is on its own local day", atMidnight?.when ?? "nil", "2026-09-24")
        r.equal("and reads as half past midnight", atMidnight?.at ?? "nil", "00:30")

        let allDay = EventKitMeetings.make(id: "e3", title: "Offsite",
                                           start: local(2026, 9, 25),
                                           end: local(2026, 9, 26),
                                           isAllDay: true,
                                           calendarTitle: "Work")
        r.equal("an all-day event has no clock", allDay?.at ?? "nil", "nil")
        r.yes("and says so", allDay?.isAllDay ?? false)

        r.equal("the title is trimmed the way a task's is",
                EventKitMeetings.make(id: "e4", title: "   Standup  ",
                                      start: start, end: nil, isAllDay: false,
                                      calendarTitle: "Work")?.title ?? "nil",
                "Standup")

        let long = String(repeating: "a", count: 300)
        r.equal("and capped at normalizeTask's 160",
                String(EventKitMeetings.make(id: "e5", title: long, start: start,
                                             end: nil, isAllDay: false,
                                             calendarTitle: "Work")?.title.count ?? -1),
                "160")

        r.equal("the calendar it came off is kept",
                made?.calendarTitle ?? "nil", "Work")
    }

    // MARK: - 2. the length

    static func clampsTheLength(_ r: Report) {
        r.open("the length a block is drawn at")

        let start = local(2026, 9, 24, 9, 0)
        func length(_ minutes: Double?, allDay: Bool = false) -> Int {
            EventKitMeetings.length(start: start,
                                    end: minutes.map { start.addingTimeInterval($0 * 60) },
                                    isAllDay: allDay)
        }

        r.equal("an hour is sixty minutes", String(length(60)), "60")
        r.equal("a zero-length event still has a height", String(length(0)), "2")
        r.equal("and a nine-day one is not nine days tall", String(length(9 * 24 * 60)), "240")
        r.equal("no end at all is normalizeTask's own default",
                String(length(nil)), "20")
        r.equal("an all-day event is not measured in hours",
                String(length(24 * 60, allDay: true)), "20")
        r.equal("a half hour survives the rounding", String(length(30)), "30")
    }

    // MARK: - 3. what is not drawn

    static func refusesWhatCannotBeDrawn(_ r: Report) {
        r.open("what never becomes a row")

        let start = local(2026, 9, 24, 9, 0)
        let blank = EventKitMeetings.make(id: "e6", title: "   ", start: start,
                                          end: nil, isAllDay: false,
                                          calendarTitle: "Work")
        /* A nameless block on an hour grid says nothing and cannot be
           made into a task with a title, so it is not a row. */
        r.equal("an event with no title at all", blank == nil ? "nil" : "drawn", "nil")

        r.equal("the calendar the web app writes to is named here once",
                EventKitMeetings.ownCalendarTitle, "my.adhd")
    }

    // MARK: - 4. the day is one list

    static func ordersTheDayAsOneList(_ r: Report) {
        r.open("a day interleaves by the clock")

        let day = "2026-09-24"
        let tasks = Ordering.tasksOn([
            task("t-none", day, nil),
            task("t-1400", day, "14:00"),
            task("t-0900", day, "09:00"),
        ], day)

        let meetings = [
            meeting("m-1030", day, "10:30"),
            meeting("m-allday", day, nil),
        ]

        r.equal("all-day first, then the clock, then the unscheduled",
                ids(AgendaEntry.merge(tasks: tasks, meetings: meetings)),
                "m-allday,t-0900,m-1030,t-1400,t-none")

        r.equal("with no meetings the order is exactly tasksOn's",
                ids(AgendaEntry.merge(tasks: tasks, meetings: [])),
                tasks.map(\.id).joined(separator: ","))

        /* Stability is what keeps `tasksOn`'s second key — most urgent
           first — meaning anything after the merge has run over it. */
        let tied = Ordering.tasksOn([
            task("t-low", day, "09:00", urgency: 1),
            task("t-high", day, "09:00", urgency: 5),
        ], day)
        r.equal("a clock tie keeps the order it arrived in",
                ids(AgendaEntry.merge(tasks: tied, meetings: [])),
                "t-high,t-low")

        r.equal("a meeting and a task at the same minute both survive",
                ids(AgendaEntry.merge(tasks: Ordering.tasksOn([task("t-0900", day, "09:00")], day),
                                      meetings: [meeting("m-0900", day, "09:00")])),
                "t-0900,m-0900")

        r.equal("an occurrence is identified by its day, not just its event",
                meeting("m", "2026-09-24", "09:00").occurrenceID,
                "m@2026-09-2409:00")
        r.yes("so two days of one repeating event are two rows",
              meeting("m", "2026-09-24", "09:00").occurrenceID
                != meeting("m", "2026-09-25", "09:00").occurrenceID)
    }

    // MARK: - 5. claimed meetings

    static func dropsWhatHasBecomeATask(_ r: Report) {
        r.open("a meeting that has become a task")

        let day = "2026-09-24"
        let one = meeting("m-1", day, "09:00")
        let two = meeting("m-2", day, "11:00")

        var made = one.asTask()
        made.id = "t-from-m1"

        r.equal("drops out of the day",
                AgendaEntry.unclaimed([one, two], by: [made]).map(\.id).joined(separator: ","),
                "m-2")

        r.equal("and out of the whole window at once",
                AgendaEntry.unclaimed([day: [one, two]], by: [made])[day]?
                    .map(\.id).joined(separator: ",") ?? "nil",
                "m-2")

        r.equal("a store with no such task changes nothing",
                AgendaEntry.unclaimed([one, two], by: [task("t-x", day, "09:00")])
                    .map(\.id).joined(separator: ","),
                "m-1,m-2")

        /* Ticked off is still claimed. The hour is accounted for either
           way, and a meeting reappearing the moment its task is done
           would be the row coming back from nowhere. */
        var done = made
        done.done = true
        r.equal("a finished task still holds its meeting",
                AgendaEntry.unclaimed([one, two], by: [done]).map(\.id).joined(separator: ","),
                "m-2")
    }

    // MARK: - 6. the reader

    @MainActor
    static func readsOnlyWhenItMay(_ r: Report) {
        r.open("the reader asks only when it may")

        let today = "2026-09-24"
        let clock = { local(2026, 9, 24, 12, 0) }
        let fixture = FakeMeetings(all: [
            meeting("m-today", today, "09:00"),
            meeting("m-soon", "2026-10-01", "09:00"),
            meeting("m-far", "2027-01-01", "09:00"),
        ])

        func reader(_ access: MeetingAccess) -> MeetingReader {
            MeetingReader(source: fixture,
                          clock: clock,
                          authorize: { access },
                          defaults: UserDefaults(suiteName: "myadhd.checks.\(UUID().uuidString)")!)
        }

        let off = reader(.granted)
        r.yes("off until it is turned on", !off.enabled)
        off.refresh()
        r.equal("and reads nothing at all while it is off",
                String(fixture.log.calls.count), "0")
        r.equal("so a day is empty", String(off.on(today).count), "0")

        let denied = reader(.denied)
        denied.enabled = true
        r.equal("a refusal reads nothing either", String(fixture.log.calls.count), "0")
        r.equal("and draws nothing", String(denied.on(today).count), "0")

        let live = reader(.granted)
        live.enabled = true
        r.equal("granted and on, it reads once", String(fixture.log.calls.count), "1")
        r.equal("from yesterday", fixture.log.calls.last?.0 ?? "nil", "2026-09-23")
        r.equal("to sixty days out", fixture.log.calls.last?.1 ?? "nil", "2026-11-23")
        r.equal("today's meeting is on today",
                live.on(today).map(\.id).joined(separator: ","), "m-today")
        r.equal("and one outside the window never arrived",
                live.days["2027-01-01"]?.count.description ?? "nil", "nil")
        r.yes("a day with something on it says so", live.any(on: today))
        r.yes("and one without does not", !live.any(on: "2026-09-26"))

        live.enabled = false
        r.equal("turning it off forgets what was read",
                String(live.days.count), "0")

        let mixed = reader(.granted)
        mixed.enabled = true
        r.equal("timed and all-day are asked for separately",
                "\(mixed.timed(on: today).count)/\(mixed.allDay(on: today).count)",
                "1/0")

        /* The line under the switch. It is the only thing that can tell
           "this phone has nothing to read" apart from "read fine, found
           nothing", and those two send you to opposite places. */
        let counting = reader(.granted)
        r.equal("nothing is counted before the switch goes on",
                String(counting.calendars), "0")
        counting.enabled = true
        r.equal("on and granted, the calendars are counted",
                String(counting.calendars), "1")
        r.equal("and so is everything in the window",
                String(counting.found), "2")
        counting.enabled = false
        r.equal("off puts the calendar count back to zero",
                String(counting.calendars), "0")
        r.equal("and forgets the count of what it found",
                String(counting.found), "0")

        let shut = reader(.denied)
        shut.enabled = true
        r.equal("a refusal counts no calendars", String(shut.calendars), "0")
        r.equal("and no meetings", String(shut.found), "0")
    }

    // MARK: - 7. the task it becomes

    static func becomesAnOrdinaryTask(_ r: Report) {
        r.open("the task a meeting becomes")

        let one = meeting("ev-1", "2026-09-24", "09:30", minutes: 45, title: "Sprint review")
        let made = one.asTask()

        r.equal("carries the title", made.title, "Sprint review")
        r.equal("the day", made.when ?? "nil", "2026-09-24")
        r.equal("the clock", made.at ?? "nil", "09:30")
        r.equal("and the length", String(made.minutes), "45")
        r.equal("it remembers the event it came from", made.fromEvent ?? "nil", "ev-1")
        r.yes("with a minted id, not the event's", made.id.hasPrefix("t_"))
        r.yes("open", !made.done)
        r.equal("and it is not marked as the offline parser's",
                made.local ? "true" : "false", "false")

        /* `firstStep` is normalizeTask's placeholder and not something
           invented here: nobody has said what the first step of somebody
           else's meeting is. */
        r.equal("the first step is the model's own placeholder",
                made.firstStep, Normalize.defaultFirstStep)

        /* The key that matters most, and the one with no compiler behind
           it: `fromEvent` is a field no other build has heard of, so it
           has to ride where an unknown key rides — after the base keys
           and before `updatedAt` — or the web app and every older phone
           drop it on the next write. */
        let keys = Array(made.encoded().keys)
        r.equal("fromEvent is re-emitted where an unknown key goes",
                keys.suffix(2).joined(separator: ","), "skipped,fromEvent")
        r.yes("and the base keys are all still in front of it",
              Array(keys.prefix(TaskItem.baseKeys.count)) == TaskItem.baseKeys)

        var doc = StoreDocument()
        doc.tasks = [made]
        let once = doc.jsonString
        guard let parsed = try? JSONValue.parse(once),
              case .object = parsed else {
            r.equal("the document parses", "no", "yes")
            return
        }
        let again = StoreDocument.load(parsed, inShell: true, now: 0).jsonString
        r.equal("a document holding one survives a read and a write", again, once)
        r.yes("and the key is still there afterwards",
              again.contains("\"fromEvent\":\"ev-1\""))

        let allDay = meeting("ev-2", "2026-09-25", nil, title: "Offsite").asTask()
        r.equal("an all-day meeting becomes a task on that day",
                allDay.when ?? "nil", "2026-09-25")
        r.equal("with no clock invented for it", allDay.at ?? "nil", "nil")
    }
}
