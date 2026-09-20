/* ============================================================
   Checks/parity-ordering.swift — MyADHD/Core/Ordering.swift, proved
   against the real app.js

   Not an Xcode target. `swiftc` over the app target's own sources plus
   `JavaScriptCore`, which evaluates the DOM-free slices of the actual
   web file — not a copy of them, not a paraphrase. The slices are cut by
   anchor line, so a rename or a move in `app.js` fails the run by name
   rather than silently testing the wrong thing.

       Checks/parity-ordering.sh [path-to-My.adhd]

   What is compared, per fixture corpus and per pinned `today`:

     dueAt · bucketOf · sortBucket (both comparators) · bucketize ·
     quadrantOf · quadrantize · catKey · groupByCategory · tasksOn ·
     overdueTasks · the home card's next-three walk · the five stats

   The two boundaries the inventory warns about are both in the corpus:
   a task dated exactly today (late for `quadrantOf`, not late for
   `overdueTasks`) and a task dated yesterday.

   Four honest notes about what this does and does not prove:

   1. **`reify`.** design §2.5 says a reader applies `minutes` and
      `urgency` defaults AT USE — clamp 2…240 to 20 and 1…5 to 3 — while
      `app.js` reads `t.minutes` raw because `normalizeTask` has always
      written it. So the corpus is passed through `reify` in the JS
      before the ordering functions see it, using `normalizeTask`'s own
      clamp (app.js:1041-1043) lifted verbatim. That makes this a test
      of the ordering, and it makes the clamp itself a test of
      `Normalize.clamp` — which it also asserts, value by value, before
      anything is sorted.

   2. **`dayKey` is frozen**, by reassigning the global after the slices
      are evaluated: called with no argument it returns the pinned day,
      called with a Date it is the real one. That is what pins
      `bucketize`, `quadrantize` and `overdueTasks`'s default.

   3. **Two functions are mirrored rather than extracted**, because their
      bodies are half DOM: `paintToday`'s heading (three lines of
      `textContent`, covered by `Checks/copy.sh` instead) and
      `paintStats`'s five counts, which are one expression each and are
      written out in the harness with the app.js line beside them. The
      ORDERING half of `paintToday` — the three groups, the dedupe and
      the cap — IS extracted, and it is the part that could be wrong.

   4. **A `when` that is not a date is checked apart.** It makes `dueAt`
      answer `NaN`, which makes app.js's own comparator inconsistent, and
      the order that comes out of an inconsistent comparator belongs to
      the sort algorithm rather than to the comparator. See
      `Corpus.junkDays`: that corpus is compared on `dueAt`, `bucketOf`,
      `catKey`, `tasksOn` and `overdueTasks`, all of which are defined,
      and not on the comparator-ordered lists, which are not.
   ============================================================ */

import Foundation
import JavaScriptCore

// MARK: - the slices

/// One extracted run of `app.js`, and what has to be in it.
struct Slice {
    var name: String
    var from: String          // the line the slice starts at, matched by prefix
    var to: String?           // the line it stops BEFORE, or nil for one line
    var mustContain: [String]
}

enum Extract {

    static func lines(of path: String) throws -> [String] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return text.components(separatedBy: "\n")
    }

    static func index(_ lines: [String], containing needle: String, from: Int = 0) -> Int? {
        for i in from..<lines.count where lines[i].contains(needle) { return i }
        return nil
    }

    static func cut(_ lines: [String], _ slice: Slice) throws -> String {
        guard let start = index(lines, containing: slice.from) else {
            throw Failure("app.js no longer has a line containing `\(slice.from)` "
                          + "(slice \(slice.name)) — the port has drifted from its source")
        }
        let end: Int
        if let to = slice.to {
            guard let e = index(lines, containing: to, from: start + 1) else {
                throw Failure("app.js no longer has a line containing `\(to)` after "
                              + "`\(slice.from)` (slice \(slice.name))")
            }
            end = e
        } else {
            end = start + 1
        }
        let body = lines[start..<end].joined(separator: "\n")
        for marker in slice.mustContain where !body.contains(marker) {
            throw Failure("slice \(slice.name) no longer contains `\(marker)` — "
                          + "it has moved out of the range this check cuts")
        }
        return body
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
}

// MARK: - the fixture corpus

enum Corpus {

    /// A tiny LCG, so the corpus is the same on every machine and in
    /// every run. Nothing here may use `arc4random` or `Date()`.
    struct Random {
        var s: UInt64
        mutating func next(_ n: Int) -> Int {
            s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((s >> 33) % UInt64(n))
        }
    }

    /// Clock times, deliberately including the unpadded one: `tasksOn`
    /// sorts these as strings, so `"9:00"` sorting after `"23:59"` is
    /// the web's behaviour and has to be this app's too.
    static let clocks: [JSONValue] = [
        .null, .string(""), .string("00:00"), .string("07:30"), .string("09:00"),
        .string("9:00"), .string("12:30"), .string("18:05"), .string("23:59"),
    ]

    /// The same, plus a time no `normalizeTime` can produce.
    ///
    /// `dueAt` builds its number with `at.replace(':', '')` — a string
    /// needle, so JavaScript drops the FIRST colon only, leaves "12:3"
    /// and reads `NaN` off it. A port that replaces every colon gets
    /// "123" and a real instant instead, and files the task into the day
    /// rather than leaving it undated. Nothing else in the plain pool has
    /// a second separator to disagree about.
    ///
    /// It lives here rather than in `clocks` for the same reason
    /// `junkDays` does: a `NaN` row makes app.js's own comparator
    /// inconsistent, and what a sort then does is the sort's business.
    /// The junk corpus is compared on `dueAt` itself and not on the
    /// comparator-ordered lists.
    static let junkClocks: [JSONValue] = clocks + [.string("1:2:3")]

    static let categories: [JSONValue] = [
        .string("work"), .string("Work"), .string("WORK"), .string("admin"),
        .string("money"), .string("general"), .string("zzz custom"), .string(""),
        .null,
    ]

    /// Present, absent, null, out of range and junk — every shape a
    /// hand-edited or pre-`importance` store can carry.
    static let minutesValues: [JSONValue?] = [
        .int(5), .int(20), .int(45), .int(90), .int(240), .int(1), .int(9_999),
        .double(12.6), .string("30"), .null, nil,
    ]
    static let urgencyValues: [JSONValue?] = [
        .int(1), .int(3), .int(5), .int(0), .int(9), .double(4.4),
        .string("2"), .null, nil,
    ]
    static let importanceValues: [JSONValue?] = [
        .string("low"), .string("high"), .string("middling"), .null, nil,
    ]
    static let quadrantValues: [JSONValue?] = [
        .null, nil, .string(""), .string("do"), .string("plan"),
        .string("delegate"), .string("drop"),
    ]

    /// The days, relative to the pinned today, plus the awkward literals
    /// that are still real day keys. `-1` and `0` are both in here on
    /// purpose: yesterday and today are the two late boundaries.
    static func days(today: String) -> [JSONValue] {
        var out: [JSONValue] = [.null, .string(""), .string("2026-1-5")]
        for offset in [-370, -181, -8, -2, -1, 0, 1, 2, 9, 40, 200, 400] {
            out.append(.string(WebDates.addDays(offset, toKey: today)))
        }
        return out
    }

    /// The same, with a `when` that is not a date at all.
    ///
    /// `normalizeDay` cannot produce one of these — it is a hand-edited
    /// store, or a payload from something that is not this app — and it
    /// is why this corpus is kept apart: `dueAt` answers `NaN` for it,
    /// which makes app.js's OWN comparator inconsistent (a NaN row
    /// compares by urgency against everything while two dated rows
    /// compare by deadline, so `a < b` and `b < c` no longer imply
    /// `a < c`). What a sort does with an inconsistent comparator is the
    /// sort algorithm's business, not the comparator's: JavaScriptCore's
    /// merge sort and Swift's introsort disagree, and neither is wrong.
    /// So this corpus is checked on everything that IS defined — `dueAt`
    /// itself, `bucketOf`, `catKey`, `tasksOn`, `overdueTasks` — and not
    /// on the comparator-ordered lists.
    static func junkDays(today: String) -> [JSONValue] {
        days(today: today) + [.string("not-a-day"), .string("someday"), .string("2026-13-45")]
    }

    /// One corpus. `ties` forces a run of tasks that are equal on every
    /// sort key, which is the only way to see whether the sort is stable.
    static func build(today: String, count: Int, seed: UInt64, ties: Int,
                      junk: Bool = false) -> [TaskItem]
    {
        var rng = Random(s: seed)
        let dayPool = junk ? junkDays(today: today) : days(today: today)
        let clockPool = junk ? junkClocks : clocks
        var out: [TaskItem] = []

        for i in 0..<count {
            var f = JSONObject()
            f.set("id", .string(String(format: "t_%04d", i)))
            f.set("title", .string("task \(i)"))
            if let m = minutesValues[rng.next(minutesValues.count)] { f.set("minutes", m) }
            f.set("energy", .string(["low", "medium", "high"][rng.next(3)]))
            if let u = urgencyValues[rng.next(urgencyValues.count)] { f.set("urgency", u) }
            if let imp = importanceValues[rng.next(importanceValues.count)] {
                f.set("importance", imp)
            }
            if let q = quadrantValues[rng.next(quadrantValues.count)] { f.set("quadrant", q) }
            f.set("category", categories[rng.next(categories.count)])
            f.set("when", dayPool[rng.next(dayPool.count)])
            f.set("at", clockPool[rng.next(clockPool.count)])
            let done = rng.next(5) == 0
            f.set("done", .bool(done))
            f.set("doneAt", done ? .int(1_758_000_000_000 + i) : .null)
            f.set("skipped", .bool(false))
            out.append(TaskItem(fields: f))
        }

        /* A block that ties on every key, in a single category, so a
           comparator that falls through to nothing has to keep the
           stored order — and a non-stable sort will scramble it. */
        for i in 0..<ties {
            var f = JSONObject()
            f.set("id", .string(String(format: "tie_%03d", i)))
            f.set("title", .string("tie \(i)"))
            f.set("minutes", .int(30))
            f.set("energy", .string("medium"))
            f.set("urgency", .int(3))
            f.set("importance", .string("low"))
            f.set("quadrant", .null)
            f.set("category", .string("work"))
            f.set("when", i % 2 == 0 ? .null : .string(today))
            f.set("at", .null)
            f.set("done", .bool(false))
            f.set("doneAt", .null)
            f.set("skipped", .bool(false))
            out.append(TaskItem(fields: f))
        }

        return out
    }
}

// MARK: - the run

@main
struct ParityOrdering {

    static var checks = 0
    static var failures: [String] = []

    static func eq(_ got: String, _ want: String, _ what: String) {
        checks += 1
        guard got != want else { return }
        failures.append(what)
        print("  FAIL  \(what)")
        print("          swift  \(got)")
        print("          app.js \(want)")
    }

    static func main() {
        let args = CommandLine.arguments
        let webRoot = args.count > 1
            ? args[1]
            : (URL(fileURLWithPath: args[0]).deletingLastPathComponent().path + "/../../My.adhd")
        let appJS = webRoot + "/app.js"

        print("parity-ordering")
        print("  app.js   \(appJS)")
        print("  timezone \(TimeZone.current.identifier)")

        let context: JSContext
        do {
            context = try buildContext(appJS: appJS)
        } catch {
            print("  FATAL  \(error)")
            exit(2)
        }

        /* Pinned days: a US DST start and end, both sides of two year
           boundaries, a leap-adjacent end of February, and an ordinary
           midsummer day to catch anything that only works at an edge. */
        let todays = ["2026-03-08", "2026-11-01", "2025-12-31", "2026-01-01",
                      "2026-12-31", "2027-02-28", "2026-06-15"]

        assertClampAgrees(context)
        assertStringComparesAgree(context)

        for today in todays {
            for (name, corpus) in [
                ("wide", Corpus.build(today: today, count: 120, seed: 0x5EED, ties: 12)),
                ("dense", Corpus.build(today: today, count: 40, seed: 0xC0FFEE, ties: 24)),
                ("tiny", Corpus.build(today: today, count: 3, seed: 0xBEEF, ties: 0)),
            ] {
                run(context, corpus, today: today, label: "\(name)@\(today)")
            }
            /* Sorted lists excluded — see Corpus.junkDays. */
            run(context, Corpus.build(today: today, count: 60, seed: 0xD15EA5E, ties: 6,
                                      junk: true),
                today: today, label: "junk@\(today)", sorted: false)
        }

        print("---")
        if failures.isEmpty {
            print("parity-ordering OK — \(checks) comparisons, all matched app.js")
            exit(0)
        }
        print("parity-ordering FAILED — \(failures.count) of \(checks) comparisons disagreed")
        exit(1)
    }

    // MARK: - the JavaScript side

    static func buildContext(appJS: String) throws -> JSContext {
        let lines = try Extract.lines(of: appJS)

        let dates = try Extract.cut(lines, Slice(
            name: "dates",
            from: "const pad2 = (n) =>",
            to: "function keyToDate(key) {",
            mustContain: ["function dayKey"]))

        let scheduled = try Extract.cut(lines, Slice(
            name: "scheduled",
            from: "const scheduled = (t) =>",
            to: nil,
            mustContain: ["!t.done", "!!t.when"]))

        let ordering = try Extract.cut(lines, Slice(
            name: "ordering",
            from: "const CATEGORY_LABELS = {",
            to: "function goToNext() {",
            mustContain: [
                "function dueAt", "const BUCKETS", "function bucketOf",
                "function sortBucket", "function bucketize", "const QUADRANTS",
                "function quadrantOf", "function quadrantize",
                "function groupByCategory", "const catKey",
            ]))

        let calendar = try Extract.cut(lines, Slice(
            name: "calendar",
            from: "function tasksOn(key) {",
            to: "function showCalendar() {",
            mustContain: ["function tasksOn", "function overdueTasks"]))

        // paintToday, ordering half only: everything before the heading.
        guard let paintAt = Extract.index(lines, containing: "function paintToday() {") else {
            throw Extract.Failure("app.js no longer has paintToday()")
        }
        guard let walkEnd = (paintAt..<lines.count).first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces) == "}));"
        }) else {
            throw Extract.Failure("paintToday()'s dedupe walk no longer ends in `}));`")
        }
        let homeWalk = lines[(paintAt + 1)...walkEnd].joined(separator: "\n")
        for marker in ["const late = overdueTasks(today)", "const now = tasksOn(today)",
                       "next.length < 3", "seen.has(t.id)"] {
            guard homeWalk.contains(marker) else {
                throw Extract.Failure("paintToday's walk no longer contains `\(marker)`")
            }
        }

        let context = JSContext()!
        var thrown: String?
        context.exceptionHandler = { _, value in
            thrown = value?.toString() ?? "unknown JS exception"
        }

        let prelude = """
        var state = { tasks: [] };
        var __TODAY = null;
        """

        let epilogue = """
        /* dayKey with no argument answers the pinned day; with one it is
           still the real thing, so nothing that formats a Date changes. */
        var __REAL_DAYKEY = dayKey;
        dayKey = function (d) { return d === undefined ? __TODAY : __REAL_DAYKEY(d); };

        /* normalizeTask's own clamp (app.js:1041-1043), applied at read
           the way design §2.5 says a native reader applies it. */
        function __clamp(n, lo, hi, d) {
          const v = Number(n);
          return Number.isFinite(v) ? Math.min(hi, Math.max(lo, Math.round(v))) : d;
        }
        function __reify(t) {
          const out = Object.assign({}, t);
          out.minutes = __clamp(t.minutes, 2, 240, 20);
          out.urgency = __clamp(t.urgency, 1, 5, 3);
          return out;
        }
        function __compares(json) {
          const w = JSON.parse(json), out = [];
          for (const a of w) for (const b of w) {
            out.push(a + '|' + b + '|' + (a < b ? 1 : 0) + '|' + Math.sign(a.localeCompare(b)));
          }
          return out.join('\\n');
        }
        function __clampProbe(json) {
          const v = JSON.parse(json);
          return [__clamp(v, 2, 240, 20), __clamp(v, 1, 5, 3)].join('|');
        }

        function __setStore(json, today) {
          __TODAY = today;
          state = { tasks: JSON.parse(json).map(__reify) };
          return state.tasks.length;
        }
        function __open() { return state.tasks.filter(t => !t.done); }
        function __ids(list) { return list.map(t => t.id).join(','); }

        function __dueAt()      { return state.tasks.map(t => String(dueAt(t))).join('|'); }
        function __bucketOf()   { return state.tasks.map(t => bucketOf(t, __TODAY)).join('|'); }
        function __quadrantOf() { return state.tasks.map(t => quadrantOf(t, __TODAY)).join('|'); }
        function __catKey()     { return state.tasks.map(catKey).join('|'); }

        function __sortBucket(key) { return __ids(sortBucket(key, __open())); }
        function __bucketize() {
          return bucketize(__open()).map(g => g[0] + ':' + g[1] + ':' + __ids(g[2])).join('||');
        }
        function __quadrantize() {
          return quadrantize(__open())
            .map(q => q[0] + ':' + q[1] + ':' + q[2] + ':' + __ids(q[3])).join('||');
        }
        function __groups() {
          return groupByCategory(__open()).map(g => g[0] + ':' + __ids(g[1])).join('||');
        }
        function __tasksOn(day) { return __ids(tasksOn(day)); }
        function __overdue()    { return __ids(overdueTasks(__TODAY)); }

        function __home() {
        \(homeWalk)
          return __ids(next) + '#' + late.length + '#' + now.length
               + '#' + (open.length > next.length);
        }

        /* paintStats (app.js:4229-4246), one expression each. */
        function __stats() {
          const open = state.tasks.filter(t => !t.done);
          return [
            open.length,
            state.tasks.filter(t => t.done).length,
            groupByCategory(open).length,
            open.filter(t => t.when).length,
            overdueTasks().length,
          ].join('|');
        }
        """

        for chunk in [prelude, dates, scheduled, ordering, calendar, epilogue] {
            context.evaluateScript(chunk)
            if let thrown {
                throw Extract.Failure("JavaScriptCore threw while loading a slice: \(thrown)")
            }
        }
        context.exceptionHandler = { _, value in
            print("  JS EXCEPTION  \(value?.toString() ?? "?")")
        }
        return context
    }

    static func call(_ context: JSContext, _ fn: String, _ args: [Any] = []) -> String {
        guard let f = context.objectForKeyedSubscript(fn) else { return "<missing \(fn)>" }
        return f.call(withArguments: args)?.toString() ?? "<nil \(fn)>"
    }

    // MARK: - Normalize.clamp against normalizeTask's own clamp

    static func assertClampAgrees(_ context: JSContext) {
        let probes: [JSONValue] = [
            .int(0), .int(1), .int(2), .int(5), .int(240), .int(241), .int(9_999),
            .double(12.4), .double(12.5), .double(-3.7), .string("30"), .string(""),
            .string("  8 "), .string("nope"), .null, .bool(true), .bool(false),
            .array([]), .array([.int(7)]),
        ]
        for p in probes {
            let js = call(context, "__clampProbe", [WebJSON.encode(p)])
            let swift = "\(Normalize.clamp(p, 2, 240, 20))|\(Normalize.clamp(p, 1, 5, 3))"
            eq(swift, js, "clamp(\(WebJSON.encode(p)))")
        }
    }

    // MARK: - `<` and localeCompare, which are not the same function

    /// `Ordering.jsLess` against JS `<`, and `Ordering.localeCompare`
    /// against JS `localeCompare`, over every pair of a small set that
    /// includes the one shape where the two disagree (`"9:00"` beside
    /// `"99:99"` — the unpadded clock a hand-edited store can carry).
    static func assertStringComparesAgree(_ context: JSContext) {
        let words = ["", "00:00", "07:30", "09:00", "9:00", "12:30", "18:05",
                     "23:59", "99:99", "not-a-day", "someday",
                     "2026-1-5", "2026-03-08", "2026-03-09", "2027-01-01"]
        var swift: [String] = []
        for a in words {
            for b in words {
                swift.append("\(a)|\(b)|\(Ordering.jsLess(a, b) ? 1 : 0)|"
                             + "\(Ordering.localeCompare(a, b).signum())")
            }
        }
        let js = call(context, "__compares", [WebJSON.encode(.array(words.map(JSONValue.string)))])
        eq(swift.joined(separator: "\n"), js, "string comparison (< and localeCompare)")
    }

    // MARK: - one corpus, one day

    static func run(_ context: JSContext, _ tasks: [TaskItem], today: String,
                    label: String, sorted: Bool = true)
    {
        let json = WebJSON.encode(.array(tasks.map(\.json)))
        let loaded = call(context, "__setStore", [json, today])
        eq("\(tasks.count)", loaded, "\(label) corpus size")

        // dueAt — Infinity and NaN printed the way JS prints them.
        let swiftDueAt = tasks.map { jsNumberString(Ordering.dueAt($0)) }.joined(separator: "|")
        eq(swiftDueAt, call(context, "__dueAt"), "\(label) dueAt")

        eq(tasks.map { Ordering.bucketOf($0, today: today) }.joined(separator: "|"),
           call(context, "__bucketOf"), "\(label) bucketOf")

        eq(tasks.map { Ordering.quadrantOf($0, today: today) }.joined(separator: "|"),
           call(context, "__quadrantOf"), "\(label) quadrantOf")

        eq(tasks.map { Ordering.catKey($0) }.joined(separator: "|"),
           call(context, "__catKey"), "\(label) catKey")

        let open = tasks.filter { !$0.done }

        // Every day the corpus can actually be on, plus the two edges.
        var days = Set(tasks.compactMap(\.when))
        days.insert(today)
        days.insert(WebDates.addDays(1, toKey: today))
        for day in days.sorted() {
            eq(ids(Ordering.tasksOn(tasks, day)),
               call(context, "__tasksOn", [day]), "\(label) tasksOn(\(day))")
        }

        eq(ids(Ordering.overdueTasks(tasks, today: today)),
           call(context, "__overdue"), "\(label) overdueTasks")

        guard sorted else { return }

        // Both comparators, over the same list, so neither branch hides.
        for key in ["late", "today", "soon", "someday", "quad"] {
            eq(ids(Ordering.sortBucket(key, open)),
               call(context, "__sortBucket", [key]), "\(label) sortBucket(\(key))")
        }

        let swiftBuckets = Ordering.bucketize(open, today: today)
            .map { "\($0.key):\($0.label):\(ids($0.items))" }
            .joined(separator: "||")
        eq(swiftBuckets, call(context, "__bucketize"), "\(label) bucketize")

        let swiftQuads = Ordering.quadrantize(open, today: today)
            .map { "\($0.key):\($0.label):\($0.sub):\(ids($0.items))" }
            .joined(separator: "||")
        eq(swiftQuads, call(context, "__quadrantize"), "\(label) quadrantize")

        let swiftGroups = Ordering.groupByCategory(open)
            .map { "\($0.key):\(ids($0.items))" }
            .joined(separator: "||")
        eq(swiftGroups, call(context, "__groups"), "\(label) groupByCategory")

        let home = Ordering.homeToday(tasks, today: today)
        eq("\(ids(home.next))#\(home.late.count)#\(home.now.count)#\(home.showsMore)",
           call(context, "__home"), "\(label) paintToday walk")

        let s = Ordering.stats(tasks, today: today)
        eq("\(s.open)|\(s.done)|\(s.lists)|\(s.dated)|\(s.overdue)",
           call(context, "__stats"), "\(label) paintStats")
    }

    static func ids(_ list: [TaskItem]) -> String {
        list.map(\.id).joined(separator: ",")
    }

    /// `String(n)` for the doubles `dueAt` returns.
    static func jsNumberString(_ x: Double) -> String {
        if x.isNaN { return "NaN" }
        if x.isInfinite { return x > 0 ? "Infinity" : "-Infinity" }
        return WebJSON.number(x)
    }
}
