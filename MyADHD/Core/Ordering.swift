/* ============================================================
   MyADHD/Core/Ordering.swift — where a task lands and in what order

   A line-for-line port of app.js's ordering layer: `dueAt` (1118-1121),
   `BUCKETS`/`bucketOf`/`sortBucket`/`bucketize` (1128-1162),
   `QUADRANTS`/`quadrantOf`/`quadrantize` (1169-1200), `catKey` and
   `groupByCategory` (1099, 1202-1219), `scheduled` (745), `tasksOn` and
   `overdueTasks` (2255-2267), and the home card's next-three walk
   (`paintToday`, 4176-4192).

   Three things in here are load-bearing and easy to get wrong in Swift:

   1. **`Array.prototype.sort` is stable** (ES2019 mandates it) and
      Swift's `sort` is not. Every comparator below runs through
      `stableSorted`, which decorates with the original index, so two
      rows that tie keep the order the store put them in. Without it the
      lists reshuffle under the reader on every repaint.

   2. **NaN falls through, it does not throw.** `dueAt` returns
      `Infinity` for an undated task, and JS `Infinity - Infinity` is
      `NaN`; a comparator returning `NaN` is treated as `0`, so the
      comparison moves on to the next key. `compareNumbers` reproduces
      that exactly — a `<`/`>` pair with a fall-through, never a
      three-way `if` on a Double that could trap.

   3. **Two different string comparisons, and they disagree.** JS `<` and
      `<=` on strings compare UTF-16 code units; `localeCompare` is an
      ICU collation that weights punctuation differently. `"9:00" <
      "99:99"` is false while `"9:00".localeCompare("99:99")` is -1. So
      `bucketOf` and `quadrantOf` go through `jsLess` (code units, which
      is what `<` is) and `tasksOn` and `overdueTasks` go through
      `localeCompare` (`String.localizedCompare`, which is the same ICU),
      because that is what each one calls in app.js. Swift's own `<` on
      String is neither of those, and is not used here at all.

   The two late boundaries the inventory warns about (§627) both live
   here, and they are NOT the same:

   - **strict `when < today`** — `overdueTasks`, the home card, the stats
     card, the lists mark. Today is not late yet.
   - **`when <= today`** — `quadrantOf`'s `urgent`. A thing due today IS
     urgent, and that is the whole reason the matrix disagrees with the
     Late heading.

   Labels are not here. They are in `Copy` (`Copy.Buckets`,
   `Copy.Quadrants`, `Copy.Categories`), because copy is checked against
   the web by `Checks/copy.sh` and ordering is checked against it by
   `Checks/parity-ordering.swift`.
   ============================================================ */

import Foundation

enum Ordering {

    // MARK: - JavaScript comparison primitives

    /// `a < b` the way a JS relational operator does it: by UTF-16 code
    /// unit. NOT `localeCompare` — see below.
    static func jsLess(_ a: String, _ b: String) -> Bool {
        jsCompare(a, b) < 0
    }

    /// `a.localeCompare(b)` — and it is **not** the same as `<`.
    ///
    /// `localeCompare` is an ICU collation: punctuation is weighted
    /// differently from a code point, so `"9:00".localeCompare("99:99")`
    /// is -1 while `"9:00" < "99:99"` is false. For the zero-padded
    /// `HH:MM` and `YYYY-MM-DD` that `normalizeTime` and `normalizeDay`
    /// produce the two agree, which is what "the zero padding is
    /// load-bearing" means; they part company on a hand-edited store, and
    /// there the web's answer is the collation's.
    ///
    /// `String.localizedCompare` is the same ICU on the same system, and
    /// `Checks/parity-ordering.swift` asserts the two agree pair by pair.
    static func localeCompare(_ a: String, _ b: String) -> Int {
        a.localizedCompare(b).rawValue
    }

    /// `a < b`, `a <= b` — a raw UTF-16 code-unit comparison, which is
    /// what a JS relational operator on two strings does. `bucketOf` and
    /// `quadrantOf` use this; `tasksOn` and `overdueTasks` use
    /// `localeCompare` above, because that is what app.js calls.
    static func jsCompare(_ a: String, _ b: String) -> Int {
        var x = a.utf16.makeIterator()
        var y = b.utf16.makeIterator()
        while true {
            switch (x.next(), y.next()) {
            case (nil, nil):            return 0
            case (nil, _):              return -1
            case (_, nil):              return 1
            case let (l?, r?):
                if l < r { return -1 }
                if l > r { return 1 }
            }
        }
    }

    /// One key of a JS numeric comparator. `.some(true)` / `.some(false)`
    /// decide it; `nil` means "this key said nothing, try the next one" —
    /// which is what a `NaN` difference does in JS, including the
    /// `Infinity - Infinity` two undated tasks produce.
    private static func compareNumbers(_ a: Double, _ b: Double) -> Bool? {
        let d = a - b
        if d < 0 { return true }
        if d > 0 { return false }
        return nil
    }

    /// A stable sort, because JS's is. Ties keep their stored order.
    static func stableSorted<T>(_ items: [T], _ isBefore: (T, T) -> Bool?) -> [T] {
        items.enumerated()
            .sorted { l, r in
                if let decided = isBefore(l.element, r.element) { return decided }
                return l.offset < r.offset
            }
            .map(\.element)
    }

    // MARK: - scheduled (app.js:745)

    /// `const scheduled = (t) => !t.done && !!t.when;`
    /// The `!!` is a truthiness test, so an empty `when` is not scheduled.
    static func scheduled(_ t: TaskItem) -> Bool {
        guard !t.done, let when = t.when, !when.isEmpty else { return false }
        return true
    }

    /// `if (t.quadrant)` — truthy, so `""` and `null` both derive.
    static func storedQuadrant(_ t: TaskItem) -> String? {
        guard let q = t.quadrant, !q.isEmpty else { return nil }
        return q
    }

    // MARK: - dueAt (app.js:1118-1121)

    /// A deadline as one sortable number. No day means no deadline, which
    /// sorts LAST and not first — an undated task is not due now, it is
    /// undated. A day with no time on it is treated as the end of that
    /// day, so it falls in behind everything actually booked into it.
    ///
    /// `Number("20260920" + "1400")` — the zero padding is what makes the
    /// digits line up, and a junk `when` gives `NaN` here exactly as it
    /// does in the browser.
    static func dueAt(_ t: TaskItem) -> Double {
        guard let when = t.when, !when.isEmpty else { return .infinity }
        /* `when.replace(/-/g, '')` is global; `at.replace(':', '')` is a
           string needle, so JavaScript replaces the FIRST colon only. On a
           normalized "HH:MM" there is just the one, but reading never
           re-normalizes, and a hand-edited "1:2:3" parts the two apart:
           first-only leaves "12:3" and Number() says NaN, while replacing
           all of them leaves "123" and Number() says a real instant. */
        let day = when.replacingOccurrences(of: "-", with: "")
        let clock = (t.at.flatMap { $0.isEmpty ? nil : $0 })
            .map { at -> String in
                guard let r = at.range(of: ":") else { return at }
                return at.replacingCharacters(in: r, with: "")
            } ?? "2359"
        return Normalize.jsNumber(.string(day + clock))
    }

    // MARK: - Buckets (app.js:1128-1162)

    /// `BUCKETS` — four headings, in the order the day presses on you.
    /// Keys and labels live in `Copy.Buckets`.
    static var buckets: [(key: String, label: String)] {
        Copy.Buckets.order.map { ($0, Copy.Buckets.label($0)) }
    }

    /// What puts a task under a heading is its deadline and nothing else.
    /// String compare on local day keys — strict `<` for late.
    static func bucketOf(_ t: TaskItem, today: String) -> String {
        guard let when = t.when, !when.isEmpty else { return "someday" }
        if jsLess(when, today) { return "late" }
        if when == today { return "today" }
        return "soon"
    }

    /// Under a dated heading the clock leads; the heading has already said
    /// these are all late, or all today. Undated has no clock to lead
    /// with, so urgency does, and between two of equal standing the
    /// quicker one.
    ///
    /// `key == "someday"` picks the second comparator; every other key —
    /// including the matrix's `"quad"` — gets the first.
    static func sortBucket(_ key: String, _ items: [TaskItem]) -> [TaskItem] {
        if key == "someday" {
            return stableSorted(items) { a, b in
                compareNumbers(Double(b.urgency), Double(a.urgency))
                    ?? compareNumbers(Double(a.minutes), Double(b.minutes))
            }
        }
        return stableSorted(items) { a, b in
            compareNumbers(dueAt(a), dueAt(b))
                ?? compareNumbers(Double(b.urgency), Double(a.urgency))
                ?? compareNumbers(Double(a.minutes), Double(b.minutes))
        }
    }

    /// Only the headings that have something under them. An empty "Late"
    /// is a worse thing to read than no heading at all.
    static func bucketize(_ tasks: [TaskItem],
                          today: String = WebDates.dayKey())
        -> [(key: String, label: String, items: [TaskItem])]
    {
        var by: [String: [TaskItem]] = [:]
        for key in Copy.Buckets.order { by[key] = [] }
        for t in tasks { by[bucketOf(t, today: today), default: []].append(t) }

        return buckets.compactMap { key, label in
            let items = by[key] ?? []
            guard !items.isEmpty else { return nil }
            return (key, label, sortBucket(key, items))
        }
    }

    // MARK: - Quadrants (app.js:1169-1200)

    /// `QUADRANTS` — all four, always. Copy lives in `Copy.Quadrants`.
    static var quadrants: [(key: String, label: String, sub: String)] {
        Copy.Quadrants.order.map { ($0, Copy.Quadrants.label($0), Copy.Quadrants.sub($0)) }
    }

    /// A placement the person made themselves always wins. Lateness counts
    /// as urgent whatever the model said about it — and note the boundary:
    /// **`when <= today`**, so a thing due today is urgent here even
    /// though `bucketOf` will not call it late until tomorrow.
    static func quadrantOf(_ t: TaskItem, today: String) -> String {
        if let own = storedQuadrant(t) { return own }
        let dated = (t.when.map { !$0.isEmpty && !jsLess(today, $0) }) ?? false
        let urgent = t.urgency >= 5 || dated
        return t.importance == "high"
            ? (urgent ? "do" : "plan")
            : (urgent ? "delegate" : "drop")
    }

    /// Inside a quadrant the clock leads and undated falls in behind,
    /// which is what the dated headings already do — `dueAt` returns
    /// Infinity for an undated task, so the comparator needs no special
    /// case. `'quad'` is not `'someday'`, so it takes the dated branch.
    static func sortQuadrant(_ items: [TaskItem]) -> [TaskItem] {
        sortBucket("quad", items)
    }

    static func quadrantize(_ tasks: [TaskItem],
                            today: String = WebDates.dayKey())
        -> [(key: String, label: String, sub: String, items: [TaskItem])]
    {
        var by: [String: [TaskItem]] = [:]
        for key in Copy.Quadrants.order { by[key] = [] }
        for t in tasks {
            let key = quadrantOf(t, today: today)
            /* The web does `by.get(quadrantOf(...)).push(t)`. A stored
               quadrant of, say, 'later' would throw there; here it would
               silently vanish, which is worse. Anything outside the four
               is drawn where it would have derived to. */
            if by[key] != nil {
                by[key]?.append(t)
            } else {
                var derived = t
                derived.quadrant = nil
                by[quadrantOf(derived, today: today), default: []].append(t)
            }
        }
        return quadrants.map { key, label, sub in
            (key, label, sub, sortQuadrant(by[key] ?? []))
        }
    }

    // MARK: - Categories (app.js:1099, 1202-1219)

    /// `String(t.category || 'general').toLowerCase()`.
    static func catKey(_ t: TaskItem) -> String {
        let raw = t.raw("category")
        let s: String
        if let raw, raw.isTruthy {
            s = raw.stringValue ?? Normalize.jsString(raw)
        } else {
            s = "general"
        }
        return s.lowercased()
    }

    /// Group open tasks by category.
    ///
    /// Inside a group: most urgent first, then shortest. Between groups:
    /// the list holding the most urgent thing goes on top, then the bigger
    /// list — so the pressing pile is the one you see first.
    ///
    /// Insertion order of the `Map` is what breaks a tie between two
    /// groups whose top urgency and size both match, so the grouping walks
    /// the tasks in store order and keeps that order.
    static func groupByCategory(_ tasks: [TaskItem]) -> [(key: String, items: [TaskItem])] {
        var order: [String] = []
        var groups: [String: [TaskItem]] = [:]
        for t in tasks {
            let key = catKey(t)
            if groups[key] == nil { groups[key] = []; order.append(key) }
            groups[key]?.append(t)
        }

        let sortedGroups: [(key: String, items: [TaskItem])] = order.map { key in
            let items = stableSorted(groups[key] ?? []) { a, b in
                compareNumbers(Double(b.urgency), Double(a.urgency))
                    ?? compareNumbers(Double(a.minutes), Double(b.minutes))
            }
            return (key, items)
        }

        return stableSorted(sortedGroups) { a, b in
            /* Math.max(...[]) is -Infinity in JS; a group is never empty
               here, but the arithmetic is written so it would behave the
               same if one were. */
            let ua = a.items.map(\.urgency).max().map(Double.init) ?? -.infinity
            let ub = b.items.map(\.urgency).max().map(Double.init) ?? -.infinity
            return compareNumbers(ub, ua)
                ?? compareNumbers(Double(b.items.count), Double(a.items.count))
        }
    }

    // MARK: - The calendar's two queries (app.js:2255-2267)

    /// Still to do, on this exact day. Sorted by the clock with an
    /// untimed task behind every timed one (`'99:99'` is the sentinel, and
    /// the zero padding on `HH:MM` is what makes the string compare work),
    /// then most urgent first.
    static func tasksOn(_ tasks: [TaskItem], _ key: String) -> [TaskItem] {
        let matching = tasks.filter { scheduled($0) && $0.when == key }
        return stableSorted(matching) { a, b in
            let at = { (t: TaskItem) -> String in
                guard let v = t.at, !v.isEmpty else { return "99:99" }
                return v
            }
            let c = localeCompare(at(a), at(b))
            if c != 0 { return c < 0 }
            return compareNumbers(Double(b.urgency), Double(a.urgency))
        }
    }

    /// Still to do, and the day has gone. **Strict** `when < today`:
    /// today is not late yet. Oldest first.
    static func overdueTasks(_ tasks: [TaskItem],
                             today: String = WebDates.dayKey()) -> [TaskItem]
    {
        let matching = tasks.filter { scheduled($0) && jsLess($0.when ?? "", today) }
        return stableSorted(matching) { a, b in
            let c = localeCompare(a.when ?? "", b.when ?? "")
            return c == 0 ? nil : c < 0
        }
    }

    // MARK: - The home card (app.js:4176-4192)

    /// What the Today card draws, and the heading that goes over it.
    ///
    /// Late first, then what is on today, then everything open by
    /// deadline — deduped by id, capped at three. The third group is the
    /// catch-all that stops the card being empty on a day with nothing
    /// dated, and it is the only one that includes undated tasks.
    struct HomeToday {
        var next: [TaskItem]
        var late: [TaskItem]
        var now: [TaskItem]
        var open: [TaskItem]

        /// `#home-today-title`, with `is-late` when `late` is non-empty.
        var title: String { Copy.Home.todayTitle(late: late.count, today: now.count) }
        var isLate: Bool { !late.isEmpty }
        /// `#home-today-empty` is shown when nothing made the cut.
        var showsEmpty: Bool { next.isEmpty }
        /// `#home-today-more` ('All lists') is hidden when the card is
        /// already showing everything there is.
        var showsMore: Bool { open.count > next.count }
    }

    static let homeNextMax = 3

    static func homeToday(_ tasks: [TaskItem],
                          today: String = WebDates.dayKey()) -> HomeToday
    {
        let open = tasks.filter { !$0.done }
        let late = overdueTasks(tasks, today: today)
        let now = tasksOn(tasks, today)

        let third = stableSorted(open) { a, b in
            compareNumbers(dueAt(a), dueAt(b))
                ?? compareNumbers(Double(b.urgency), Double(a.urgency))
        }

        var seen = Set<String>()
        var next: [TaskItem] = []
        for group in [late, now, third] {
            for t in group where next.count < homeNextMax && !seen.contains(t.id) {
                seen.insert(t.id)
                next.append(t)
            }
        }

        return HomeToday(next: next, late: late, now: now, open: open)
    }

    /// `is-late` on a home row: the strict boundary again.
    static func rowIsLate(_ t: TaskItem, today: String) -> Bool {
        guard let when = t.when, !when.isEmpty else { return false }
        return jsLess(when, today)
    }

    // MARK: - The five numbers (app.js:4229-4247)

    struct Stats {
        var open: Int
        var done: Int
        var lists: Int
        var dated: Int
        var overdue: Int
        /// The only card here that is ever bad news, so the only one that
        /// changes colour. Shown at zero rather than hidden.
        var overdueIsLate: Bool { overdue > 0 }
    }

    static func stats(_ tasks: [TaskItem],
                      today: String = WebDates.dayKey()) -> Stats
    {
        let open = tasks.filter { !$0.done }
        return Stats(
            open: open.count,
            /* Tasks still in the store with done === true — at most seven
               days of them, because pruneDone ages them out. NOT
               doneCounts. */
            done: tasks.filter(\.done).count,
            lists: groupByCategory(open).count,
            dated: open.filter { ($0.when.map { !$0.isEmpty }) ?? false }.count,
            overdue: overdueTasks(tasks, today: today).count
        )
    }

    // MARK: - The tab bar's two marks (inventory §1.19)

    /// The lists mark counts **strictly** overdue tasks; the calendar
    /// badge counts everything dated and colours itself on `when <= today`.
    static func lateCount(_ tasks: [TaskItem], today: String = WebDates.dayKey()) -> Int {
        overdueTasks(tasks, today: today).count
    }

    static func datedCount(_ tasks: [TaskItem]) -> Int {
        tasks.filter { scheduled($0) }.count
    }

    /// The calendar badge's colour: `when <= today`, the second boundary.
    static func anyDueByToday(_ tasks: [TaskItem], today: String = WebDates.dayKey()) -> Bool {
        tasks.contains { t in
            guard scheduled(t), let when = t.when else { return false }
            return !jsLess(today, when)
        }
    }
}
