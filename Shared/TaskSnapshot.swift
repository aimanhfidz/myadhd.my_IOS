/* ============================================================
   my.adhd for iOS — what the widget is allowed to know

   A widget's timeline provider runs in its own process, on iOS's
   schedule, with no web view anywhere near it. Reminders.swift can ask
   the page for the task list because it runs inside the app while the
   page is alive; nothing here can. So the app pushes a snapshot out to
   somewhere both processes can reach, and the widget reads that.

   Somewhere is the keychain, for the same reason DumpQueue is there: an
   App Group container needs an entitlement a free developer account is
   not given, and the development profile already allows a shared
   keychain group across the team prefix. No access group is named in
   this file either — an unspecified group means "the first one in my
   entitlement", and all three targets list exactly one and the same.

   Two differences from DumpQueue, both deliberate:

   - It is ONE item, upserted, not a queue. A queue is right for shares,
     where two in quick succession must both survive. This is a picture
     of the list as it stands, and the newest one is the only one worth
     having.

   - Its own service string, so DumpQueue.drain() — which matches on
     service and deletes as it reads — can never eat it.
   ============================================================ */

import Foundation
import Security

// MARK: - the model

/// One task, trimmed to what a widget can actually draw. Deliberately not
/// the web app's whole task: `steps`, `gcal`, `local` and the rest are of
/// no use on a 160pt tile and would spend the size budget.
struct SnapTask: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let minutes: Int
    let when: String?        // "YYYY-MM-DD", or nil when it is on no day
    let at: String?          // "HH:MM", or nil when it is not booked into a time
    let category: String
    let energy: String
    let urgency: Int         // 1...5
    let importance: String?  // "low" | "high". Optional on purpose — see below.
    let firstStep: String?
    let done: Bool

    /// Short keys because every byte here is a byte of a keychain item.
    enum CodingKeys: String, CodingKey {
        case id = "i", title = "n", minutes = "m", when = "w", at = "a", category = "c"
        case energy = "e", urgency = "u", importance = "p", firstStep = "f", done = "d"
    }

    /// The day this is dated to, as an absolute key rather than an offset
    /// from the snapshot's own day. A snapshot is allowed to be stale —
    /// isStale() says so, and the 07:00 wallpaper Shortcut reads yesterday's
    /// on purpose — and an offset read a day late is wrong by a day with
    /// nothing to reveal it.
    func isOverdue(on day: String) -> Bool {
        guard !done, let when else { return false }
        return when < day
    }
}

/* "YYYY-MM-DD" in the device's own zone, which is what app.js writes and
   what every `when` here is. Local days, never ISO8601 with a Z on it —
   a task dated today in Kuala Lumpur is dated yesterday in UTC for most of
   the working day, and that is the whole bug this format avoids.

   Gregorian, always. app.js writes getFullYear()/getMonth()/getDate(),
   which is the proleptic Gregorian calendar whatever the phone is set to.
   Calendar.current is not: a device on the Japanese, Buddhist or Hijri
   calendar reports year 8, 2569 or 1448, and a key built from that never
   matches a key the page wrote — every tile goes blank and every reminder
   is scheduled centuries off. The zone is still the device's own. */
enum DayKey {

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    static func of(_ date: Date, _ calendar: Calendar = DayKey.calendar) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }

    static func date(_ key: String, _ calendar: Calendar = DayKey.calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        return calendar.date(from: c)
    }

    static func adding(_ days: Int, to key: String, _ calendar: Calendar = DayKey.calendar) -> String {
        guard let d = date(key, calendar),
              let moved = calendar.date(byAdding: .day, value: days, to: d)
        else { return key }
        return of(moved, calendar)
    }

    /// Whole days from `a` to `b`, or nil if either is not a day key.
    static func between(_ a: String, _ b: String, _ calendar: Calendar = DayKey.calendar) -> Int? {
        guard let da = date(a, calendar), let db = date(b, calendar) else { return nil }
        return calendar.dateComponents([.day], from: da, to: db).day
    }

    private static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday",
                                  "Thursday", "Friday", "Saturday"]
    private static let monthNames = ["January", "February", "March", "April", "May", "June",
                                     "July", "August", "September", "October", "November", "December"]

    /// "4pm", "9.30am" — a period, not a colon. timeLabel() in app.js.
    static func timeLabel(_ hhmm: String?) -> String? {
        guard let m = minutes(hhmm) else { return nil }
        let h24 = m / 60, mins = m % 60
        let hour = h24 % 12 == 0 ? 12 : h24 % 12
        let suffix = h24 < 12 ? "am" : "pm"
        return mins == 0 ? "\(hour)\(suffix)" : String(format: "%d.%02d%@", hour, mins, suffix)
    }

    /// "Today", "Tomorrow", "Mon 9 Mar" — relative where that reads faster.
    /// dayLabel() in app.js, including the year only when it is not this one.
    static func dayLabel(_ key: String, today: String, _ calendar: Calendar = DayKey.calendar) -> String {
        if key == today { return "Today" }
        if key == adding(1, to: today, calendar) { return "Tomorrow" }
        if key == adding(-1, to: today, calendar) { return "Yesterday" }
        guard let d = date(key, calendar) else { return key }
        let p = calendar.dateComponents([.year, .month, .day, .weekday], from: d)
        let name = String(dayNames[max(0, min(6, (p.weekday ?? 1) - 1))].prefix(3))
        let month = String(monthNames[max(0, min(11, (p.month ?? 1) - 1))].prefix(3))
        let thisYear = date(today, calendar).map { calendar.component(.year, from: $0) }
        let year = p.year == thisYear ? "" : " \(p.year ?? 0)"
        return "\(name) \(p.day ?? 0) \(month)\(year)"
    }

    /// "9am – 10am", from a start and a length. The end wraps at midnight
    /// rather than reading 25:00, and a task with no clock has no range.
    static func rangeLabel(_ hhmm: String?, minutes: Int) -> String? {
        guard let start = self.minutes(hhmm), let a = timeLabel(hhmm) else { return nil }
        let end = (start + max(0, minutes)) % 1440
        let b = timeLabel(String(format: "%02d:%02d", end / 60, end % 60)) ?? ""
        return b.isEmpty || minutes <= 0 ? a : "\(a) \u{2013} \(b)"
    }

    /// "18 Sep, Friday" — the date line the Today Timeline tile already
    /// uses, so the two agree.
    static func longLabel(_ key: String, _ calendar: Calendar = DayKey.calendar) -> String {
        guard let d = date(key, calendar) else { return key }
        let f = DateFormatter()
        f.calendar = calendar
        f.dateFormat = "d MMM, EEEE"
        return f.string(from: d)
    }

    /// Minutes past midnight for "HH:MM", or nil.
    static func minutes(_ hhmm: String?) -> Int? {
        guard let hhmm else { return nil }
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }
}

struct TaskSnapshot: Codable, Equatable {
    let generated: Date
    let day: String          // "YYYY-MM-DD", the local day this describes
    let tasks: [SnapTask]
    let dropped: Int         // cut for size; drawn as "+N" rather than pretended away

    /* The aggregates below are counted from the whole store before the
       task list is trimmed, so they stay true when `dropped > 0`. A month
       grid derived from `tasks` would quietly under-count the moment the
       cap bit; this one cannot. */

    let doneToday: Int       // ticked off today, including ones `tasks` drops
    let calFrom: String?     // first day `cal` describes
    let cal: [Int]           // open dated tasks, one entry per day from calFrom
    let histFrom: String?    // first day `hist` describes
    let hist: [Int]          // tasks completed, one entry per day from histFrom

    enum CodingKeys: String, CodingKey {
        case generated = "g", day = "d", tasks = "t", dropped = "x"
        case doneToday = "k", calFrom = "cf", cal = "cv", histFrom = "hf", hist = "hv"
    }

    init(generated: Date, day: String, tasks: [SnapTask], dropped: Int,
         doneToday: Int = 0,
         calFrom: String? = nil, cal: [Int] = [],
         histFrom: String? = nil, hist: [Int] = []) {
        self.generated = generated
        self.day = day
        self.tasks = tasks
        self.dropped = dropped
        self.doneToday = doneToday
        self.calFrom = calFrom
        self.cal = cal
        self.histFrom = histFrom
        self.hist = hist
    }

    /* A blob written before the aggregates existed has none of these keys
       and must still open. Throwing instead would blank the widget until
       the next launch, which is survivable — and would leave the 07:00
       wallpaper Shortcut, which runs with no app anywhere near it, showing
       yesterday's picture to anyone who took the update overnight. Six
       lines to not do that. */
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generated = try c.decode(Date.self, forKey: .generated)
        day       = try c.decode(String.self, forKey: .day)
        tasks     = try c.decode([SnapTask].self, forKey: .tasks)
        dropped   = try c.decode(Int.self, forKey: .dropped)
        doneToday = try c.decodeIfPresent(Int.self, forKey: .doneToday) ?? 0
        calFrom   = try c.decodeIfPresent(String.self, forKey: .calFrom)
        cal       = try c.decodeIfPresent([Int].self, forKey: .cal) ?? []
        histFrom  = try c.decodeIfPresent(String.self, forKey: .histFrom)
        hist      = try c.decodeIfPresent([Int].self, forKey: .hist) ?? []
    }

    // MARK: what the day is made of

    var tomorrow: String { DayKey.adding(1, to: day) }

    /// Dated before the day this snapshot describes, and still open. Kept
    /// by TaskBridge on purpose — late is the one thing that must not fall
    /// off the bottom of a tile.
    var overdue: [SnapTask] { tasks.filter { $0.isOverdue(on: day) } }

    var todayTasks: [SnapTask] { tasks.filter { $0.when == day } }
    var tomorrowTasks: [SnapTask] { tasks.filter { $0.when == tomorrow } }

    /// Everything that belongs on today's band: dated today, and nothing
    /// else. `tasks` also carries tomorrow and whatever is late, and both
    /// draw at the wrong place on a 24-hour band.
    var timed: [SnapTask] { tasks.filter { $0.when == day && $0.at != nil } }

    /// No clock on it. Includes things dated today with no time, which is
    /// what the band means by "N anytime".
    var untimed: [SnapTask] { tasks.filter { $0.at == nil && !$0.done } }

    /// On no day at all — a stricter thing than `untimed`, and the right
    /// count for a tile that has already drawn today and tomorrow in full.
    var undated: [SnapTask] { tasks.filter { $0.when == nil && !$0.done } }

    // MARK: the next thing

    /* The whole product in one line. Five bands, in the order the day
       presses on you, and for the top of the list it is paintToday()'s
       rule from app.js rather than a second opinion about it: anything
       late, then anything dated today in clock order, then whatever is
       simply open.

       The tail differs, knowingly. paintToday() sorts its open tasks by
       dueAt(), where an undated task is Infinity — so the web puts
       tomorrow's dated things ahead of undated ones. Band 3 here is the
       undated and band 4 is tomorrow, the other way round: on a tile with
       nothing today, "the thing with no day" is a better NEXT than "the
       thing that is not until tomorrow", which the tile would otherwise
       claim was now. It only shows when today is empty.

       A time that has already gone is deliberately NOT demoted. Nine
       o'clock at half past ten is the thing you have not done yet, and
       burying it under this afternoon's is how a list starts lying about
       what is pressing. The app does not do it either, and a tile that
       ranked differently from the screen it stands for would be its own
       bug.

       `now` is still taken rather than read, because the day rolls: it is
       what the timeline provider uses to precompute the whole day's
       entries and let the tile advance without spending a reload. */
    func next(now: Date) -> SnapTask? { ordered(now: now).first }

    /* Which day "late" is measured against. Not simply `day`: a snapshot
       written last night and read at seven this morning — which is exactly
       what the wallpaper Shortcut does, on purpose — would otherwise still
       think yesterday's nine o'clock is in the future. Never earlier than
       the day it describes, because a clock set backwards should not
       un-late anything. */
    func effectiveDay(_ now: Date) -> String { max(day, DayKey.of(now)) }

    /// The same ranking as a list. paintToday() takes three off the top of
    /// this and calls it the answer to "what now"; `next` takes one and
    /// calls it the product. One ordering so the two can never disagree.
    func ordered(now: Date) -> [SnapTask] {
        let today = effectiveDay(now)
        return tasks.filter { !$0.done }.sorted { rank($0, today) < rank($1, today) }
    }

    private func rank(_ t: SnapTask, _ today: String) -> (Int, Int, Int, Int) {
        let at = DayKey.minutes(t.at)
        let band: Int
        var within = 0

        if t.isOverdue(on: today) {
            band = 0
            within = -(DayKey.between(t.when ?? today, today) ?? 0)   // longest late first
        } else if t.when == today, let at {
            band = 1
            within = at
        } else if t.when == today {
            band = 2
        } else if t.when == nil {
            band = 3
        } else {
            band = 4
            within = (DayKey.between(today, t.when ?? today) ?? 0) * 1440 + (at ?? 1439)
        }
        return (band, within, -t.urgency, t.minutes)
    }

    // MARK: the aggregates, read back by day

    func count(on key: String) -> Int { at(key, from: calFrom, in: cal) }
    func completed(on key: String) -> Int { at(key, from: histFrom, in: hist) }

    private func at(_ key: String, from anchor: String?, in values: [Int]) -> Int {
        guard let anchor, let i = DayKey.between(anchor, key),
              i >= 0, i < values.count else { return 0 }
        return values[i]
    }

    /// Consecutive days with something ticked off, counting back from the
    /// snapshot's own day. Today counting as zero does not break it —
    /// nothing done yet at nine in the morning is not a broken streak.
    var streak: Int {
        guard histFrom != nil, !hist.isEmpty else { return 0 }
        var run = 0
        var key = day
        if completed(on: key) == 0 { key = DayKey.adding(-1, to: key) }
        while completed(on: key) > 0 {
            run += 1
            key = DayKey.adding(-1, to: key)
        }
        return run
    }

    /// Same snapshot, different task list. The aggregates come along
    /// untouched on purpose: they were counted from the whole store, and
    /// trimming the list for size does not make the month any emptier.
    func with(tasks: [SnapTask], dropped: Int? = nil) -> TaskSnapshot {
        TaskSnapshot(generated: generated, day: day, tasks: tasks,
                     dropped: dropped ?? self.dropped, doneToday: doneToday,
                     calFrom: calFrom, cal: cal, histFrom: histFrom, hist: hist)
    }

    /// A snapshot nobody has refreshed in a day is still worth drawing —
    /// it is just not worth drawing as if it were current.
    func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(generated) > 24 * 60 * 60
    }
}

// MARK: - the drawer

enum TaskStore {

    /// Not "myadhd.dump.queue". DumpQueue.drain() matches every item on
    /// its own service and deletes what it reads; sharing one would make
    /// opening the app eat the widget's data.
    private static let service = "myadhd.task.snapshot"

    /// One item, always this account.
    private static let account = "current"

    /// A lock-screen widget and a 07:00 wallpaper automation both run
    /// before anybody has touched the phone that morning, so anything
    /// stricter than first unlock would leave both of them blank.
    private static let accessible = kSecAttrAccessibleAfterFirstUnlock

    /// What a snapshot is allowed to weigh once compressed. There is no
    /// documented ceiling on kSecValueData and the undocumented one is not
    /// worth leaning on, so this is a budget rather than a limit — the
    /// trimming in TaskBridge aims at it and the shrink loop enforces it.
    static let budget = 16 * 1024

    // MARK: writing

    @discardableResult
    static func write(_ snapshot: TaskSnapshot) -> Bool {
        guard let blob = encode(snapshot) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let fields: [String: Any] = [
            kSecValueData as String: blob,
            kSecAttrAccessible as String: accessible,
        ]

        let updated = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        var item = query
        item[kSecValueData as String] = blob
        item[kSecAttrAccessible as String] = accessible
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    // MARK: reading

    /// nil means "I could not read it", never "there is nothing". Every
    /// caller treats nil as keep-showing-what-you-had, because the phone
    /// being locked since boot looks exactly like an empty list otherwise.
    static func read() -> TaskSnapshot? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let blob = out as? Data else { return nil }
        return decode(blob)
    }

    @discardableResult
    static func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: the wire format

    /* One version byte, then zlib. The byte refuses a change of FORMAT —
       a different compressor, a different envelope, a re-keyed struct —
       so a blob written by a newer build beside an older one is turned
       away rather than half-read.

       It is not spent on added fields. Those are handled by
       decodeIfPresent and a default in TaskSnapshot's own init(from:),
       which is why 1 is still readable: the wallpaper Shortcut runs at
       07:00 with no app around to rewrite the item, and refusing an old
       one there means a lock screen frozen on yesterday for everybody who
       took the update overnight.

       So: write the current number, keep reading every number whose body
       still parses, and only drop one when it genuinely stops parsing. */
    private static let version: UInt8 = 2
    private static let readable: ClosedRange<UInt8> = 1...2

    static func encode(_ snapshot: TaskSnapshot) -> Data? {
        let coder = JSONEncoder()
        coder.dateEncodingStrategy = .secondsSince1970
        guard let json = try? coder.encode(snapshot),
              let squeezed = try? (json as NSData).compressed(using: .zlib) as Data
        else { return nil }
        return Data([version]) + squeezed
    }

    static func decode(_ blob: Data) -> TaskSnapshot? {
        guard let first = blob.first, readable.contains(first), blob.count > 1 else { return nil }
        let body = Data(blob.dropFirst())
        guard let json = try? (body as NSData).decompressed(using: .zlib) as Data else { return nil }
        let coder = JSONDecoder()
        coder.dateDecodingStrategy = .secondsSince1970
        return try? coder.decode(TaskSnapshot.self, from: json)
    }
}
