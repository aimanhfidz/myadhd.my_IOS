/* ============================================================
   MyADHD/Core/Meetings.swift — the part of the day you did not choose

   A task is something you decided to do. A meeting is something that
   happened to you: somebody sent an invitation, you accepted it, and now
   an hour of Thursday is gone. The lists never knew about any of that,
   so a day that was full could still read as empty.

   **Why this is EventKit and not Google.** The web app's calendar link
   asks for `calendar.app.created`, a scope that can only touch the
   secondary `my.adhd` calendar it made — Google will not serve it a read
   of a real diary, by design. Reading one from a browser means a
   sensitive scope, a verification review, a hundred-user cap and a
   diary-reading token sitting in `localStorage`. None of that applies
   here: the account is already in iOS Settings, the invitation is
   already in the phone's own calendar database, and one system prompt
   reads it. It also picks up iCloud, Exchange and work calendars, which
   the Google path never could.

   **Nothing here is stored.** Meetings are not tasks, are not written to
   `myadhd.v1`, are not synced to Supabase and are not in the widget
   snapshot. EventKit is local and instant, so a cache buys nothing; and
   the store round-trips to the web app and to every other device, where
   this phone's diary has no business going.

   **EventKit stays behind `MeetingSource`.** The views take meetings,
   never an event store, so they can still be rendered to a PNG on a Mac
   by `swiftc` and `ImageRenderer` with a fixture source — which is how
   every widget tile in this project was checked. A view that reached for
   `EKEventStore` would take the whole calendar screen out of that
   harness.
   ============================================================ */

import Foundation
import EventKit
import Observation

// MARK: - one meeting

/// Deliberately the store's own shape for a day and a time: `when` is a
/// local `YYYY-MM-DD` and `at` an `HH:MM`, exactly as `TaskItem.when` and
/// `TaskItem.at` are (TaskItem.swift:146-156). That is what lets
/// `WebDates` and every day-bucket helper in `Ordering` read a meeting
/// without learning a second date format.
struct Meeting: Equatable, Identifiable {

    /// `EKEvent.eventIdentifier`. Stable for the event, and the same for
    /// every occurrence of a repeating one — so it is a handle on the
    /// series, not on the Thursday.
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

/// The seam. `EventKitMeetings` is the real one; a check or a PNG render
/// hands in a fixture instead.
protocol MeetingSource {
    /// Every meeting between two day keys, inclusive.
    func meetings(from: String, to: String) -> [Meeting]

    /// How many of this phone's calendars a read actually draws from.
    /// Nothing decides anything on it — it is the number the switch
    /// shows, so that "on, and still empty" can be told apart from "on,
    /// and there is nothing on this phone to read". The second is an
    /// account missing from iOS Settings and not a fault in here, and
    /// until this line existed there was no way to see which one it was.
    func calendarsRead() -> Int
}

/// What iOS will let us do, flattened to the three cases the UI has a
/// different sentence for.
enum MeetingAccess {
    /// Never asked. The switch may still ask.
    case notDetermined
    /// Asked and given.
    case granted
    /// Asked and refused, or refused by a profile. iOS will not show the
    /// prompt a second time, so the only way back is Settings.
    case denied
}

// MARK: - EventKit

struct EventKitMeetings: MeetingSource {

    /// The calendar the web app writes YOUR OWN dated tasks to. Reading
    /// it back in would turn every task into a meeting and draw the whole
    /// list twice — once as itself and once as somebody else's booking.
    /// It is matched by name because that is all EventKit can see of it:
    /// the `myadhdId` the web app stamps on each event lives in
    /// `extendedProperties`, which is Google's API and not the phone's.
    static let ownCalendarTitle = "my.adhd"

    /// Built once. `EKEventStore` is expensive to make and holds the
    /// change notification we listen to.
    let store: EKEventStore

    init(store: EKEventStore) { self.store = store }

    static func authorization() -> MeetingAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:              return .granted
        case .notDetermined:           return .notDetermined
        /* `.writeOnly` is a real answer on iOS 17 and it is a no for us:
           it can add an event and cannot see one. Treated as a refusal
           rather than as "ask again", because asking again shows
           nothing. */
        default:                       return .denied
        }
    }

    /// There is no read-only request. Full access IS the read one on
    /// iOS 17 — write-only is the lesser grant, and it cannot read.
    static func requestAccess() async -> MeetingAccess {
        let store = EKEventStore()
        do {
            let ok = try await store.requestFullAccessToEvents()
            return ok ? .granted : .denied
        } catch {
            return .denied
        }
    }

    func meetings(from: String, to: String) -> [Meeting] {
        guard Self.authorization() == .granted,
              let start = WebDates.keyToDate(from),
              let endDay = WebDates.keyToDate(to) else { return [] }

        /* The predicate's end is an instant, and `to` is a whole day, so
           it runs to the start of the day after — otherwise everything
           after midnight on the last day is missed. */
        let end = WebDates.addDays(endDay, 1)

        let found = store.events(
            matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)
        )

        var out: [Meeting] = []
        for event in found {
            guard let one = Self.meeting(from: event) else { continue }
            out.append(one)
        }
        return out
    }

    func calendarsRead() -> Int {
        guard Self.authorization() == .granted else { return 0 }
        return store.calendars(for: .event).filter(Self.reads).count
    }

    /// Whether this app looks at a calendar at all — the judgement that
    /// is about the calendar rather than about one event on it.
    ///
    /// It is its own function so that the count above and the filter
    /// below cannot disagree. A diagnostic that counts a calendar this
    /// app then ignores is worse than no diagnostic: it says the phone
    /// is being read when it is not.
    static func reads(_ calendar: EKCalendar) -> Bool {
        // Your own tasks, mirrored back by the web app. See above.
        if calendar.title == ownCalendarTitle { return false }

        /* Birthdays and a subscribed holiday feed are facts about the
           date, not things on your day. They are also the two that would
           put something on every single square of the month. */
        if calendar.type == .birthday || calendar.type == .subscription { return false }

        return true
    }

    /// The filter, and the whole of the judgement in this file.
    ///
    /// nil means "this is not a commitment and should not draw". Each
    /// case is a different kind of not-a-commitment, and the order is
    /// cheapest first.
    static func meeting(from event: EKEvent) -> Meeting? {
        guard let calendar = event.calendar, reads(calendar) else { return nil }

        if event.status == .canceled { return nil }

        // Marked Free: on the calendar, deliberately not blocking time.
        if event.availability == .free { return nil }

        // Invited and declined. It is not your Thursday any more.
        if let me = event.attendees?.first(where: { $0.isCurrentUser }),
           me.participantStatus == .declined { return nil }

        guard let start = event.startDate else { return nil }
        guard let id = event.eventIdentifier, !id.isEmpty else { return nil }

        return make(id: id,
                    title: event.title ?? "",
                    start: start,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarTitle: calendar.title)
    }

    /// The half of the mapping that is arithmetic rather than API
    /// semantics, over plain values so `Checks/meetings.sh` can reach it.
    /// An `EKEvent` cannot be built by hand — its identifier and its
    /// attendees are read-only and arrive from a saved row — so the guards
    /// above are only ever exercised against a real store, and everything
    /// that could be quietly wrong lives down here instead.
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
    /// height. A meeting that really does run all afternoon is drawn as a
    /// long one rather than as the rest of the week.
    ///
    /// 20 is `normalizeTask`'s own default, used here for an event with
    /// no end at all — the same number the app already means by we were
    /// not told.
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

/// One of these lives on the calendar screen and one on home. It holds
/// the window it has read, re-reads when iOS says the database moved, and
/// answers by day.
///
/// **A read only happens when it can succeed.** `refresh()` returns
/// before asking whenever the switch is off or the permission is not
/// there, so an empty answer from the source is never ambiguous: it comes
/// from a store we were allowed to read, and it means there is nothing in
/// the window. That is what makes it safe to write straight over what was
/// held — the widget snapshot's never clear on a failed read rule exists
/// because a keychain read cannot tell those two apart, and this can.
@MainActor
@Observable
final class MeetingReader {

    /// How far back and forward a read goes. Yesterday, because the
    /// agenda's overdue group rides on today and a meeting you missed is
    /// worth the same glance; sixty days forward, because the month
    /// pager can be swiped and an empty month you have scrolled to reads
    /// as a bug.
    static let daysBack = 1
    static let daysForward = 60

    /// Private, so nothing can read the window without going through a
    /// guard. `days`, `on(_:)` and the rest are the way in.
    private var byDay: [String: [Meeting]] = [:]
    private(set) var access: MeetingAccess

    /// How many calendars the last read drew from. Zero until a read has
    /// happened, and zero again the moment the switch goes off, so it is
    /// never a number left over from a state the app is no longer in.
    private(set) var calendars = 0

    /// Off until somebody turns it on. Persisted beside the calendar's
    /// other per-phone preferences — which view you like is not a task
    /// and neither is this (CalendarModes.swift:10-16).
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.key)
            if enabled { refresh() } else { byDay = [:]; calendars = 0 }
        }
    }

    static let key = "myadhd.native.showMeetings"

    @ObservationIgnored private let source: MeetingSource
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let authorize: () -> MeetingAccess
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var watching: NSObjectProtocol?

    /// `authorize` and `defaults` are seams for `Checks/meetings.sh`,
    /// which has no event store to ask and no business writing this
    /// machine's preferences. Everything else uses the defaults and is
    /// the real thing.
    init(source: MeetingSource = EventKitMeetings(store: EKEventStore()),
         clock: @escaping () -> Date = Date.init,
         authorize: @escaping () -> MeetingAccess = EventKitMeetings.authorization,
         defaults: UserDefaults = .standard)
    {
        self.source = source
        self.clock = clock
        self.authorize = authorize
        self.defaults = defaults
        self.enabled = defaults.bool(forKey: Self.key)
        self.access = authorize()

        /* iOS tells us when anything in the database moved — an invitation
           arriving, an organiser moving the hour, another app writing.
           That is the whole refresh story; there is nothing to poll. */
        watching = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        /* **The first read has to happen here.** Everything else that
           triggers one is a change: the switch moving, the event store
           telling us it moved, the scene becoming active. A cold launch
           with the switch already on is none of those — `onChange(of:
           scenePhase)` does not fire for the value a scene starts in — so
           without this line the day draws empty until something else
           happens to it, which is the failure that looks like nothing. */
        refresh()
    }

    deinit {
        if let watching { NotificationCenter.default.removeObserver(watching) }
    }

    /// Re-read the window. Cheap enough to call on every foreground: it
    /// is a local database query, not a network round trip.
    func refresh() {
        access = authorize()
        /* Off or refused draws nothing, so it counts nothing either — a
           leftover count under a switch that is doing nothing would be
           the one lie this line exists to prevent. */
        guard enabled, access == .granted else { calendars = 0; return }

        let today = WebDates.dayKey(clock())
        let from = WebDates.addDays(-Self.daysBack, toKey: today)
        let to = WebDates.addDays(Self.daysForward, toKey: today)

        calendars = source.calendarsRead()
        byDay = Dictionary(grouping: source.meetings(from: from, to: to)) { $0.when }
    }

    /// Ask for the permission, then read. Returns what iOS decided, so
    /// the switch can put itself back if the answer was no.
    @discardableResult
    func requestAccess() async -> MeetingAccess {
        let answer = await EventKitMeetings.requestAccess()
        access = answer
        if answer == .granted { refresh() }
        return answer
    }

    // MARK: reading

    /// The whole window, grouped by day, for a caller that would
    /// otherwise ask about forty-two days one at a time — the month grid.
    /// Empty whenever `on(_:)` would be, so the guard is in one place.
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

    /// Everything the window holds, counted. The other half of the line
    /// under the switch: a healthy calendar count beside a zero here is
    /// a real read that found nothing, which sends the reader to the
    /// window and the filters rather than to iOS Settings.
    var found: Int {
        guard enabled, access == .granted else { return 0 }
        return byDay.values.reduce(0) { $0 + $1.count }
    }

    /// Whether a day has anything on it — what the month grid's dot asks,
    /// and cheaper than sorting the day to find out.
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
    static func unclaimed(_ meetings: [Meeting], by tasks: [TaskItem]) -> [Meeting] {
        guard !meetings.isEmpty else { return [] }
        var claimed = Set<String>()
        for t in tasks {
            if let from = t.fromEvent { claimed.insert(from) }
        }
        guard !claimed.isEmpty else { return meetings }
        return meetings.filter { !claimed.contains($0.id) }
    }

    /// The same, for a caller holding the whole window — the month grid,
    /// which would otherwise rebuild the claimed set once per cell.
    static func unclaimed(_ byDay: [String: [Meeting]],
                          by tasks: [TaskItem]) -> [String: [Meeting]]
    {
        guard !byDay.isEmpty else { return [:] }
        var claimed = Set<String>()
        for t in tasks {
            if let from = t.fromEvent { claimed.insert(from) }
        }
        guard !claimed.isEmpty else { return byDay }
        return byDay.mapValues { day in day.filter { !claimed.contains($0.id) } }
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
