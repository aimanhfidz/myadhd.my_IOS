/* ============================================================
   MyADHD/Core/Meetings.swift — the part of the day you did not choose

   A task is something you decided to do. A meeting is something that
   happened to you: somebody sent an invitation, you accepted it, and now
   an hour of Thursday is gone. The lists never knew about any of that,
   so a day that was full could still read as empty.

   **Why this is Google and not the phone's calendar.** It used to be
   EventKit, which reads the iPhone's own calendar database — and that
   database only hears about a Google change when iOS next fetches the
   account, on a schedule the app cannot see or hurry. An event added in
   Google Calendar did not appear, and a deleted one stayed drawn, until
   iOS got round to it. So this asks Google itself, over the Calendar
   API, every time a refresh is asked for.

   **The token is the one the calendar link already holds.** Signing in
   hands Google's refresh token to `/api/link-google`, and it never comes
   back to this device; `/api/gcal-token` spends it and returns an access
   token that dies in an hour. Reading a diary needs `calendar.readonly`
   on that grant as well as the `calendar.app.created` the push uses
   (`AuthFlow.scopes`). A grant from before that scope was added answers
   403, and the Settings card asks for one more sign-in.

   **Nothing here is stored.** Meetings are not tasks, are not written to
   `myadhd.v1`, are not synced to Supabase and are not in the widget
   snapshot. They live in memory for as long as the app does, and a cold
   launch asks Google again.

   **Google stays behind `MeetingSource`.** The views take meetings,
   never a network client, so they can still be rendered to a PNG on a
   Mac by `swiftc` and `ImageRenderer` with a fixture source — which is
   how every widget tile in this project was checked.
   ============================================================ */

import Foundation
import Observation

// MARK: - one meeting

/// Deliberately the store's own shape for a day and a time: `when` is a
/// local `YYYY-MM-DD` and `at` an `HH:MM`, exactly as `TaskItem.when` and
/// `TaskItem.at` are (TaskItem.swift:146-156). That is what lets
/// `WebDates` and every day-bucket helper in `Ordering` read a meeting
/// without learning a second date format.
struct Meeting: Equatable, Identifiable {

    /// Google's `recurringEventId` for an occurrence of a repeating
    /// event, its own `id` otherwise — so it is a handle on the series,
    /// not on the Thursday, and a task made from one claims by day.
    var id: String

    var title: String

    /// The day it falls on, `YYYY-MM-DD`.
    var when: String

    /// `HH:MM`, or nil when it is an all-day event. nil means the same
    /// thing it means on a task: no clock, not midnight.
    var at: String?

    /// How long it runs. Clamped the way a task's minutes are, so the
    /// hour grid cannot be handed a block of zero or of nine days.
    var minutes: Int

    var isAllDay: Bool

    /// Which calendar it came off — `Work`, `Personal`, the Google
    /// account's address. Shown on the row, because knowing a meeting is
    /// on the work calendar is most of what you need to know about it.
    var calendarTitle: String

    /// A repeating event is one identifier over many days, so the day has
    /// to be part of what makes an occurrence unique — otherwise SwiftUI
    /// reuses one row for the whole series.
    var occurrenceID: String { id + "@" + when + (at ?? "") }
}

// MARK: - where meetings come from

/// The seam. `GoogleMeetings` is the real one; a check or a PNG render
/// hands in a fixture instead.
///
/// A read is two halves on purpose. `fetch` goes to the network and
/// keeps what it found; `meetings(from:to:)` answers from that, at once,
/// so a view never waits on Google to draw.
@MainActor
protocol MeetingSource: AnyObject {
    /// Every meeting between two day keys, inclusive, from the last fetch.
    func meetings(from: String, to: String) -> [Meeting]

    /// How many calendars the last fetch drew from. Nothing decides
    /// anything on it — it is the number the switch shows, so that "on,
    /// and still empty" can be told apart from "on, and there is nothing
    /// to read".
    func calendarsRead() -> Int

    /// What the last fetch was allowed to do.
    var access: MeetingAccess { get }

    /// Go and ask. Returns when the answer is in, or when it failed.
    func fetch(from: String, to: String) async
}

extension MeetingSource {
    /// A fixture has nothing to ask and is always allowed.
    var access: MeetingAccess { .granted }
    func fetch(from: String, to: String) async {}
}

/// What Google will let us do, flattened to the cases the Settings card
/// has a different sentence for.
enum MeetingAccess: Equatable {
    /// Nobody is signed in, so there is no Google account to ask.
    case signedOut
    /// Signed in, and Google will not let us read the diary: the account
    /// never linked a calendar, revoked it, or signed in before the read
    /// scope was asked for. One more sign-in fixes all three.
    case needsGoogle
    /// Asked and given.
    case granted
}

// MARK: - Google's shapes, and what counts

/// Everything about a Google event that is judgement or arithmetic rather
/// than network, apart from `GoogleMeetings` (Sync/GoogleMeetings.swift)
/// so `Checks/meetings.sh` can reach it with no session, no server and no
/// Google. The check decodes real API-shaped JSON into these types and
/// holds each rule to it.
enum GoogleEvents {

    /// The calendar the app writes YOUR OWN dated tasks to. Reading it
    /// back in would turn every task into a meeting and draw the whole
    /// list twice. Matched by the id `/api/gcal-token` returns, and by
    /// name as well for an account where that id was never settled.
    static let ownCalendarTitle = "my.adhd"

    struct CalendarEntry: Decodable {
        var id: String
        var summary: String?
        var summaryOverride: String?
        var accessRole: String?
        var selected: Bool?
        var hidden: Bool?
        var title: String { summaryOverride ?? summary ?? id }
    }

    /// Whether this app looks at a calendar at all. Its own function so
    /// the count in Settings and the read cannot disagree.
    static func reads(_ c: CalendarEntry, own: String?) -> Bool {
        // Your own tasks, mirrored out by the calendar push. See above.
        if c.id == own || c.title == ownCalendarTitle { return false }

        /* Unticked or hidden in Google Calendar: you have already said
           you do not want to look at it. */
        if c.selected == false || c.hidden == true { return false }

        /* Holidays, birthdays, week numbers — Google's own subscribed
           calendars, all under this domain. Facts about the date, not
           things on your day, and they would dot every square. */
        if c.id.hasSuffix("@group.v.calendar.google.com") { return false }

        /* Free/busy only: Google sends no title, and a row with no title
           is not a row (see `make`). */
        if c.accessRole == "freeBusyReader" { return false }

        return true
    }

    struct Event: Decodable {
        struct When: Decodable { var date: String?; var dateTime: String? }
        struct Attendee: Decodable { var `self`: Bool?; var responseStatus: String? }
        var id: String?
        var recurringEventId: String?
        var status: String?
        var summary: String?
        var transparency: String?
        var eventType: String?
        var start: When?
        var end: When?
        var attendees: [Attendee]?
    }

    /// The filter, and the whole of the judgement about one event. Empty
    /// means "this is not a commitment and should not draw"; more than one
    /// is an all-day event that runs over several days, one per day.
    static func meetings(from e: Event, calendarTitle: String) -> [Meeting] {
        guard let first = meeting(from: e, calendarTitle: calendarTitle) else { return [] }
        guard first.isAllDay,
              let s = e.start?.date, let startDay = WebDates.keyToDate(s),
              let t = e.end?.date, let endDay = WebDates.keyToDate(t)
        else { return [first] }

        /* Google's end date is exclusive: a one-day event on the 5th ends
           on the 6th. Each day it covers gets a row of its own, so a
           three-day trip is on all three squares rather than only the
           first. Capped at `longestSpread`. */
        var out = [first]
        var day = WebDates.addDays(startDay, 1)
        while day < endDay && out.count < Self.longestSpread {
            var next = first
            next.when = WebDates.dayKey(day)
            out.append(next)
            day = WebDates.addDays(day, 1)
        }
        return out
    }

    /// A year of days. Counted from the event's own start, not the
    /// window's, so a term that began in the summer still reaches this
    /// week; the reader drops whatever falls outside its window.
    static let longestSpread = 366

    /// One event, on the day it starts. nil means it does not draw.
    static func meeting(from e: Event, calendarTitle: String) -> Meeting? {
        if e.status == "cancelled" { return nil }

        /* Marked Free: on the calendar, deliberately not blocking time —
           for a timed event. **Not for an all-day one.** Google marks
           every new all-day event Free unless you change it, so reading
           that as a choice hid almost every all-day event anybody made.
           A day off, a trip, a deadline: all of those are things on the
           day, whatever the availability says. */
        if e.transparency == "transparent" && e.start?.dateTime != nil { return nil }

        /* Where you are working from, and a contact's birthday: Google
           keeps both as events, and neither is a thing on your day. */
        if e.eventType == "workingLocation" || e.eventType == "birthday" { return nil }

        // Invited and declined. It is not your Thursday any more.
        if e.attendees?.first(where: { $0.`self` == true })?.responseStatus == "declined" { return nil }

        guard let id = e.recurringEventId ?? e.id, !id.isEmpty else { return nil }

        let isAllDay: Bool
        let start: Date
        let end: Date?
        if let s = e.start?.dateTime, let d = parseInstant(s) {
            isAllDay = false
            start = d
            end = e.end?.dateTime.flatMap(parseInstant)
        } else if let s = e.start?.date, let d = WebDates.keyToDate(s) {
            /* A day, not an instant — read as local midnight so it lands
               on the same square it has in Google whatever the zone. */
            isAllDay = true
            start = d
            end = e.end?.date.flatMap(WebDates.keyToDate)
        } else {
            return nil
        }

        return make(id: id, title: e.summary ?? "", start: start, end: end,
                    isAllDay: isAllDay, calendarTitle: calendarTitle)
    }

    static func parseInstant(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }

    /// The half of the mapping that is arithmetic rather than API
    /// semantics, over plain values so `Checks/meetings.sh` can reach it.
    static func make(id: String,
                     title rawTitle: String,
                     start: Date,
                     end: Date?,
                     isAllDay: Bool,
                     calendarTitle: String) -> Meeting?
    {
        let title = JSText.trim(rawTitle)
        guard !title.isEmpty else { return nil }

        /* The local day and the local clock, never an ISO8601 string:
           a 9am meeting in Kuala Lumpur is on the day before in UTC for
           most of the working day. WebDates says the same thing at more
           length. */
        let at = isAllDay
            ? nil
            : WebDates.pad2(part(.hour, of: start)) + ":" + WebDates.pad2(part(.minute, of: start))

        return Meeting(id: id,
                       title: Normalize.slice(title, 160),
                       when: WebDates.dayKey(start),
                       at: at,
                       minutes: length(start: start, end: end, isAllDay: isAllDay),
                       isAllDay: isAllDay,
                       calendarTitle: calendarTitle)
    }

    /// Clamped 2...240 like a task's, for the same reason: the hour grid
    /// draws a block this tall, and neither a zero nor a fortnight is a
    /// height. 20 is `normalizeTask`'s own default, for an event with no
    /// end at all.
    static func length(start: Date, end: Date?, isAllDay: Bool) -> Int {
        guard !isAllDay, let end else { return 20 }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        return min(240, max(2, minutes))
    }

    private static func part(_ unit: Calendar.Component, of d: Date) -> Int {
        WebDates.calendar.component(unit, from: d)
    }
}

// MARK: - what the screens hold

/// One of these lives in the shell and is handed to home, the calendar
/// and Settings. It holds the window the source last fetched and answers
/// by day.
@MainActor
@Observable
final class MeetingReader {

    /// How far back and forward a read goes. Yesterday, because the
    /// agenda's overdue group rides on today; sixty days forward, because
    /// the month pager can be swiped and an empty month you have
    /// scrolled to reads as a bug.
    static let daysBack = 1
    static let daysForward = 60

    /// A fetch nobody asked for — launch, the front, the calendar tab —
    /// is skipped if the last one is younger than this. A pull or `Sync
    /// now` always goes.
    static let quietInterval: TimeInterval = 60

    private var byDay: [String: [Meeting]] = [:]
    private(set) var access: MeetingAccess

    /// How many calendars the last read drew from. Zero until a read has
    /// happened, and zero again the moment the switch goes off.
    private(set) var calendars = 0

    /// A fetch is out. Settings shows it rather than a stale number.
    private(set) var fetching = false

    /// Off until somebody turns it on. Persisted beside the calendar's
    /// other per-phone preferences (CalendarModes.swift:10-16).
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.key)
            if enabled {
                refresh()
                Task { await pull() }
            } else {
                byDay = [:]; calendars = 0
            }
        }
    }

    static let key = "myadhd.native.showMeetings"

    @ObservationIgnored private let source: MeetingSource
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let authorize: () -> MeetingAccess
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastFetch: Date?

    /// `authorize` and `defaults` are seams for `Checks/meetings.sh`.
    /// Left out, `authorize` is whatever the source last found.
    init(source: MeetingSource,
         clock: @escaping () -> Date = Date.init,
         authorize: (() -> MeetingAccess)? = nil,
         defaults: UserDefaults = .standard)
    {
        self.source = source
        self.clock = clock
        self.authorize = authorize ?? { [source] in source.access }
        self.defaults = defaults
        self.enabled = defaults.bool(forKey: Self.key)
        self.access = self.authorize()
        refresh()
    }

    /// Re-read what the source holds. No network — see `pull()`.
    func refresh() {
        access = authorize()
        guard enabled, access == .granted else { calendars = 0; return }

        let (from, to) = window()
        calendars = source.calendarsRead()
        byDay = Dictionary(grouping: source.meetings(from: from, to: to)) { $0.when }
    }

    /// Ask Google, and redraw on the answer. What a pull, `Sync now` and
    /// turning the switch on call — they wait for it, so the spinner
    /// comes down on the new day rather than on the old one.
    func pull() async {
        guard enabled else { return }
        let (from, to) = window()
        fetching = true
        lastFetch = clock()
        await source.fetch(from: from, to: to)
        fetching = false
        refresh()
    }

    /// The same, for a moment nobody asked for — so it does not wait, and
    /// it does not go at all if a fetch landed in the last minute.
    func fetchRemote() {
        guard enabled else { return }
        if let lastFetch, clock().timeIntervalSince(lastFetch) < Self.quietInterval { return }
        Task { await pull() }
    }

    private func window() -> (String, String) {
        let today = WebDates.dayKey(clock())
        return (WebDates.addDays(-Self.daysBack, toKey: today),
                WebDates.addDays(Self.daysForward, toKey: today))
    }

    // MARK: reading

    /// The whole window, grouped by day, for the month grid.
    var days: [String: [Meeting]] {
        guard enabled, access == .granted else { return [:] }
        return byDay
    }

    /// The meetings on a day, earliest first, all-day ones ahead of the
    /// clock — an all-day thing is true of the whole day and so it is
    /// true before nine.
    func on(_ key: String) -> [Meeting] {
        guard enabled, access == .granted else { return [] }
        return (byDay[key] ?? []).sorted { a, b in
            let sa = a.at ?? ""
            let sb = b.at ?? ""
            if sa == sb { return a.title < b.title }
            return sa < sb
        }
    }

    /// Everything the window holds, counted — the other half of the line
    /// under the switch.
    var found: Int {
        guard enabled, access == .granted else { return 0 }
        return byDay.values.reduce(0) { $0 + $1.count }
    }

    /// Whether a day has anything on it — what the month grid's dot asks.
    func any(on key: String) -> Bool {
        guard enabled, access == .granted else { return false }
        return !(byDay[key] ?? []).isEmpty
    }

    /// The timed ones, for the hour grid.
    func timed(on key: String) -> [Meeting] {
        on(key).filter { $0.at != nil }
    }

    /// The all-day ones, which join the chips above the grid.
    func allDay(on key: String) -> [Meeting] {
        on(key).filter { $0.at == nil }
    }
}

// MARK: - what a day is made of

/* Not in the view that draws it, on purpose. How a day is ordered is a
   fact about the day and not about SwiftUI — and `Checks/meetings.sh`
   has to be able to reach it without compiling the whole screen. */

/// A day holds two different kinds of thing and one list of them. A task
/// is something you decided to do; a meeting is something that happened
/// to you. They interleave by the clock rather than sitting in two
/// stacks, because at nine in the morning the question is what is next,
/// not which of two systems it came out of.
enum AgendaEntry: Identifiable {
    case task(TaskItem)
    case meeting(Meeting)

    var id: String {
        switch self {
        case .task(let t):    return "t:" + t.id
        /* A repeating meeting is one identifier over many days, so the
           day has to be part of what makes a row unique or SwiftUI
           reuses one view for the whole series. */
        case .meeting(let m): return "m:" + m.occurrenceID
        }
    }

    /// `HH:MM`, or the `99:99` sentinel `Ordering.tasksOn` uses so an
    /// untimed thing sorts behind every timed one.
    var slot: String {
        switch self {
        case .task(let t):    return (t.at?.isEmpty == false) ? t.at! : "99:99"
        /* An all-day meeting sorts FIRST, not last. It is true of the
           whole day, so it is already true at nine — unlike a task with
           no clock, which is merely unscheduled. */
        case .meeting(let m): return m.at ?? "00:00"
        }
    }
}

extension AgendaEntry {

    /// The day's one list. Tasks arrive already in `Ordering.tasksOn`
    /// order and meetings already sorted, and the merge is stable, so
    /// neither loses the order it came in with where the clock ties.
    static func merge(tasks: [TaskItem], meetings: [Meeting]) -> [AgendaEntry] {
        let entries = tasks.map(AgendaEntry.task) + meetings.map(AgendaEntry.meeting)
        return Ordering.stableSorted(entries) { a, b in
            let c = Ordering.localeCompare(a.slot, b.slot)
            return c == 0 ? nil : c < 0
        }
    }

    /// Meetings that have not already been turned into a task. Once one
    /// has, the task is the row — showing both would be the same hour
    /// twice, and the tickable copy is the useful one.
    ///
    /// **One occurrence, not the series.** `fromEvent` holds the event's
    /// identifier, which every occurrence of a repeating meeting shares —
    /// matched on that alone, making a task of this Monday's stand-up hid
    /// every stand-up there was. So a claim is the event AND the day the
    /// task is on. (A task dragged to another day lets its meeting show
    /// again on the day it really is, which is true.)
    static func unclaimed(_ meetings: [Meeting], by tasks: [TaskItem]) -> [Meeting] {
        guard !meetings.isEmpty else { return [] }
        let claimed = claims(tasks)
        guard !claimed.isEmpty else { return meetings }
        return meetings.filter { !claimed.contains(claim($0.id, $0.when)) }
    }

    private static func claims(_ tasks: [TaskItem]) -> Set<String> {
        var out = Set<String>()
        for t in tasks {
            if let from = t.fromEvent { out.insert(claim(from, t.when ?? "")) }
        }
        return out
    }

    private static func claim(_ event: String, _ day: String) -> String { event + "@" + day }

    /// The same, for a caller holding the whole window — the month grid,
    /// which would otherwise rebuild the claimed set once per cell.
    static func unclaimed(_ byDay: [String: [Meeting]],
                          by tasks: [TaskItem]) -> [String: [Meeting]]
    {
        guard !byDay.isEmpty else { return [:] }
        let claimed = claims(tasks)
        guard !claimed.isEmpty else { return byDay }
        return byDay.mapValues { day in day.filter { !claimed.contains(claim($0.id, $0.when)) } }
    }
}

// MARK: - turning one into a task

extension Meeting {

    /// The key stamped on a task made from this meeting.
    ///
    /// `TaskItem` carries keys it has never heard of and re-emits them in
    /// place (TaskItem.swift:64-74), precisely so a build that does not
    /// know a field cannot erase it — which means this survives a round
    /// trip through Supabase and the web app untouched. It is read back
    /// to drop the meeting from the agenda once it has become a task, so
    /// the two never draw side by side.
    static let sourceKey = "fromEvent"

    /// `normalizeTask` with the meeting's own day, time and length. The
    /// first step is left to the default: nobody has said what the first
    /// step of somebody else's meeting is, and inventing one would put
    /// words in the row that no one wrote.
    func asTask(now: Date = Date()) -> TaskItem {
        var fields = JSONObject()
        fields["title"] = .string(title)
        fields["when"] = .string(when)
        fields["at"] = at.map { .string($0) } ?? .null
        fields["minutes"] = .int(minutes)

        var task = Normalize.task(.object(fields), now: now)
        task.fields[Meeting.sourceKey] = .string(id)
        return task
    }
}

extension TaskItem {

    /// The event this task was made from, if it was made from one.
    var fromEvent: String? { fields[Meeting.sourceKey]?.stringValue }
}
