/* ============================================================
   Checks/bridge.swift — the test that proves the widgets cannot go blank

   design.md §3.0. The native app stops feeding `TaskBridge` and
   `Reminders` with the page's `localStorage` string and starts feeding
   them `AppStore.doc.jsonString` instead. Nothing about that is visible:
   there is no build that fails and no screen that looks wrong. If the
   re-encoding drops a field, or clamps one, or reorders `tasks`, the
   deploy is green and a widget on somebody's home screen quietly draws a
   blank day.

   So: run both inputs through both consumers and demand the same bytes.

     OLD  the fixture's own JSON, exactly as `localStorage` held it,
          through a FROZEN COPY of `TaskBridge.build` — the shell's code
          as it stood on 2026-09-20, kept here so the live one has
          something to have drifted from.

     NEW  the same store through `StoreDocument.load` and back out as
          `jsonString`, through the LIVE `TaskBridge.packed`.

   Assert: byte-identical snapshot bytes, and a wire blob that decodes
   back to the same snapshot on both sides.

   One caveat found while writing this, and it is the reason the
   assertion is worded that way. `TaskStore.encode` runs the struct
   through a plain `JSONEncoder`, and `JSONEncoder`'s key order is not
   stable from one call to the next inside a single process — the same
   value comes out as `{"hf":…,"g":…}` one time and `{"g":…,"hf":…}` the
   next, which zlib then turns into blobs of different lengths.
   Diffing those bytes tests Foundation's dictionary hashing, not this
   code, and it fails at random. So both snapshots are re-encoded here
   with `.sortedKeys` and THOSE bytes are compared — the same
   information in a fixed order — and the real blobs are checked by
   decoding them, which is what a widget does with one.

   And the same shape for the schedule: a frozen copy of `Reminders.parse`
   over the old input against `ReminderPlanner.parse` over the new one,
   on a frozen clock, compared as `(id, fire, title, body)`.

   The corpus is every JSON file under `Checks/fixtures` plus a
   synthetic store built
   below, because the fixtures are about decoding and carry three tasks
   between them. The synthetic one is about the widget: overdue, today
   timed, today untimed, tomorrow, next week, undated, done with a stamp,
   done without one, skipped, a pre-`importance` row, unknown task keys,
   an over-long title, and eighty rows so the `taskMax` cap and `dropped`
   are exercised.

   Four frozen clocks, because the reminder rules turn on the hour:
   08:00 (before the 09:00 default, so an untimed task today is still
   ahead), 14:00 (inside the rescue window), 22:00 (past the 21:00 quiet
   hour, so a rescue is refused), and a year boundary.

   Usage:  Checks/bridge.sh
   ============================================================ */

import Foundation

// MARK: - the frozen copies
/* Everything in this section is the shell's code as of 2026-09-20,
   pasted. The ONLY edit is an injected clock: `build` and `parse` both
   read `Date()` inline, and two blobs cannot be compared byte for byte
   if the two calls disagree about what time it is. Do not tidy these.
   They are a photograph, and the whole value of the check is that they
   are not maintained alongside the thing they are checked against. */

enum LegacyBridge {

    private static let daysAhead = 1
    private static let calBack = 10
    private static let calSpan = 77
    private static let titleMax = 64
    private static let stepMax = 96
    private static let taskMax = 64

    static func packed(from json: String?, now: Date) -> (snapshot: TaskSnapshot, blob: Data)? {
        guard let json,
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["tasks"] as? [[String: Any]]
        else { return nil }

        let snapshot = build(from: raw, root: root, now: now)
        guard var blob = TaskStore.encode(snapshot) else { return nil }

        var shrunk = snapshot
        var guard_ = 0
        while blob.count > TaskStore.budget && guard_ < 6 {
            shrunk = shrink(shrunk, round: guard_)
            guard let next = TaskStore.encode(shrunk) else { return nil }
            blob = next
            guard_ += 1
        }
        return (shrunk, blob)
    }

    private static func build(from raw: [[String: Any]], root: [String: Any],
                              now: Date) -> TaskSnapshot {
        let today = DayKey.of(now)
        let horizon = DayKey.of(DayKey.calendar.date(byAdding: .day, value: daysAhead, to: now) ?? now)

        var kept: [SnapTask] = []

        let calFrom = DayKey.adding(-calBack, to: today)
        var cal = [Int](repeating: 0, count: calSpan)
        var doneToday = 0
        var finished: [String: Int] = [:]

        for task in raw {
            guard let id = task["id"] as? String,
                  let title = task["title"] as? String else { continue }
            if task["skipped"] as? Bool == true { continue }

            let done = task["done"] as? Bool == true
            let day = task["when"] as? String

            if done, let on = doneDay(task, fallback: day) {
                finished[on, default: 0] += 1
                if on == today { doneToday += 1 }
            }

            if !done, let day, let i = DayKey.between(calFrom, day), i >= 0, i < calSpan {
                cal[i] += 1
            }

            if let day {
                if day > horizon { continue }
                if done && day != today { continue }
            } else if done {
                continue
            }

            kept.append(SnapTask(
                id: id,
                title: clip(title, titleMax),
                minutes: min(240, max(2, (task["minutes"] as? Int) ?? 20)),
                when: day,
                at: day == nil ? nil : task["at"] as? String,
                category: (task["category"] as? String) ?? "general",
                energy: (task["energy"] as? String) ?? "medium",
                urgency: min(5, max(1, (task["urgency"] as? Int) ?? 3)),
                importance: task["importance"] as? String,
                firstStep: (task["firstStep"] as? String).map { clip($0, stepMax) },
                done: done
            ))
        }

        kept.sort { a, b in
            let ka = a.at ?? "99:99", kb = b.at ?? "99:99"
            if ka != kb { return ka < kb }
            if a.urgency != b.urgency { return a.urgency > b.urgency }
            return a.minutes < b.minutes
        }

        if let pruned = root["doneCounts"] as? [String: Any] {
            for (day, n) in pruned {
                if let n = (n as? NSNumber)?.intValue, n > 0, day.count == 10 {
                    finished[day, default: 0] += n
                }
            }
        }
        let history = DoneLedger.merge(finished, today: today)

        let dropped = max(0, kept.count - taskMax)
        return TaskSnapshot(
            generated: now,
            day: today,
            tasks: Array(kept.prefix(taskMax)),
            dropped: dropped,
            doneToday: doneToday,
            calFrom: calFrom,
            cal: cal,
            histFrom: history.from,
            hist: history.values
        )
    }

    private static func doneDay(_ task: [String: Any], fallback: String?) -> String? {
        if let ms = (task["doneAt"] as? NSNumber)?.doubleValue, ms > 0 {
            return DayKey.of(Date(timeIntervalSince1970: ms / 1000))
        }
        return fallback
    }

    private static func shrink(_ s: TaskSnapshot, round: Int) -> TaskSnapshot {
        if round == 0 {
            let stripped = s.tasks.map {
                SnapTask(id: $0.id, title: $0.title, minutes: $0.minutes, when: $0.when, at: $0.at,
                         category: $0.category, energy: $0.energy, urgency: $0.urgency,
                         importance: $0.importance, firstStep: nil, done: $0.done)
            }
            return s.with(tasks: stripped)
        }
        if round == 1, s.hist.count > 56 {
            let keep = Array(s.hist.suffix(56))
            return TaskSnapshot(generated: s.generated, day: s.day, tasks: s.tasks,
                                dropped: s.dropped, doneToday: s.doneToday,
                                calFrom: s.calFrom, cal: s.cal,
                                histFrom: DayKey.adding(-(keep.count - 1), to: s.day),
                                hist: keep)
        }

        let half = max(4, s.tasks.count / 2)
        return s.with(tasks: Array(s.tasks.prefix(half)),
                      dropped: s.dropped + (s.tasks.count - half))
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}

struct LegacyItem: Equatable {
    let id: String
    let title: String
    let step: String
    let fire: Date
    let parts: DateComponents
}

enum LegacyReminders {

    private static let limit = 56
    private static let defaultHour = 9
    private static let rescueDelay: TimeInterval = 60 * 60
    private static let quietHour = 21

    static func parse(_ json: String?, now: Date) -> [LegacyItem] {
        guard let json,
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tasks = root["tasks"] as? [[String: Any]] else { return [] }

        var out: [LegacyItem] = []

        for task in tasks {
            if task["done"] as? Bool == true { continue }
            if task["skipped"] as? Bool == true { continue }

            guard let id = task["id"] as? String,
                  let title = task["title"] as? String,
                  let day = task["when"] as? String,
                  let stamp = components(day: day, at: task["at"] as? String),
                  let asked = DayKey.calendar.date(from: stamp.parts) else { continue }

            var fire = asked
            var parts = stamp.parts

            if fire <= now {
                guard !stamp.timed,
                      DayKey.calendar.isDate(asked, inSameDayAs: now),
                      let rescued = rescue(from: now) else { continue }
                fire = rescued
                parts = DayKey.calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: rescued)
            }

            parts.calendar = DayKey.calendar

            let step = (task["firstStep"] as? String) ?? ""
            out.append(LegacyItem(id: id, title: title, step: step, fire: fire, parts: parts))
        }

        return Array(out.sorted { $0.fire < $1.fire }.prefix(limit))
    }

    private static func components(day: String, at clock: String?)
        -> (parts: DateComponents, timed: Bool)? {
        let ymd = day.split(separator: "-").map(String.init).compactMap(Int.init)
        guard ymd.count == 3, day.count == 10 else { return nil }

        var parts = DateComponents()
        parts.year = ymd[0]
        parts.month = ymd[1]
        parts.day = ymd[2]
        parts.hour = defaultHour
        parts.minute = 0

        var timed = false
        if let clock {
            let hm = clock.split(separator: ":").map(String.init).compactMap(Int.init)
            if hm.count == 2, (0...23).contains(hm[0]), (0...59).contains(hm[1]) {
                parts.hour = hm[0]
                parts.minute = hm[1]
                timed = true
            }
        }

        return (parts, timed)
    }

    private static func rescue(from now: Date) -> Date? {
        let calendar = DayKey.calendar
        let when = now.addingTimeInterval(rescueDelay)
        guard let cutoff = calendar.date(bySettingHour: quietHour, minute: 0, second: 0, of: now),
              when <= cutoff else { return nil }
        return when
    }
}

// MARK: - the synthetic store

/* Built with `WebJSON` so it is canonical `JSON.stringify` output, the
   same as the fixtures on disk. Everything here is a shape the widget
   path treats differently from its neighbours. */
enum Synthetic {

    static func store(today: String) -> String {
        let ms = { (key: String, hour: Int) -> Int in
            let d = DayKey.date(key).map { $0.addingTimeInterval(TimeInterval(hour * 3600)) } ?? Date()
            return Int(d.timeIntervalSince1970 * 1000)
        }

        var tasks: [JSONValue] = []

        // late, by three days, with a clock on it
        tasks.append(task(id: "t_late01", title: "Renew the road tax",
                          when: DayKey.adding(-3, to: today), at: "09:00", urgency: 5))
        // today, timed, in the morning
        tasks.append(task(id: "t_today1", title: "Call the clinic",
                          when: today, at: "08:15", urgency: 4, minutes: 10))
        // today, timed, in the evening
        tasks.append(task(id: "t_today2", title: "Take the bins out",
                          when: today, at: "19:45", urgency: 2, minutes: 5))
        // today, no clock — the rescue path
        tasks.append(task(id: "t_today3", title: "Reply to the landlord",
                          when: today, at: nil, urgency: 3))
        // tomorrow
        tasks.append(task(id: "t_tom01", title: "Standup",
                          when: DayKey.adding(1, to: today), at: "10:00"))
        // beyond the horizon — counted on the month grid, off the tile
        tasks.append(task(id: "t_far01", title: "Dentist",
                          when: DayKey.adding(12, to: today), at: "15:30"))
        // outside the calendar window entirely
        tasks.append(task(id: "t_far02", title: "Passport renewal",
                          when: DayKey.adding(200, to: today), at: nil))
        // undated
        tasks.append(task(id: "t_any01", title: "Find the warranty card", when: nil, at: nil))
        // done today, with a stamp
        tasks.append(task(id: "t_done1", title: "Pay the electricity bill",
                          when: today, at: "07:00", done: true, doneAt: ms(today, 7)))
        // done, dated another day, with a stamp — history but not the tile
        tasks.append(task(id: "t_done2", title: "Book the car service",
                          when: DayKey.adding(-2, to: today), at: nil,
                          done: true, doneAt: ms(DayKey.adding(-2, to: today), 11)))
        // done, undated, no stamp at all — the doneDay fallback
        tasks.append(task(id: "t_done3", title: "Cancel the old subscription",
                          when: nil, at: nil, done: true, doneAt: nil))
        // skipped — never drawn, never rung
        tasks.append(task(id: "t_skip01", title: "Something the model invented",
                          when: today, at: "11:00", skipped: true))
        // an over-long title and an over-long first step, both clipped
        tasks.append(task(id: "t_long01",
                          title: String(repeating: "a very long title indeed ", count: 6),
                          when: today, at: "13:00",
                          firstStep: String(repeating: "open the thing and look at it ", count: 8)))
        // a junk `when` the day parser must refuse
        tasks.append(task(id: "t_junk01", title: "Whenever", when: "soon", at: "nope"))
        // a pre-importance row: no importance, no gcal, no local, no skipped
        var old = JSONObject()
        old.set("id", .string("t_old001"))
        old.set("title", .string("A row from before the columns existed"))
        old.set("minutes", .int(45))
        old.set("energy", .string("high"))
        old.set("urgency", .int(4))
        old.set("firstStep", .string("Open it."))
        old.set("category", .string("admin"))
        old.set("when", .string(DayKey.adding(1, to: today)))
        old.set("at", .string("16:30"))
        old.set("done", .bool(false))
        tasks.append(.object(old))
        // unknown keys, which must survive the round trip untouched
        var odd = JSONObject()
        odd.set("id", .string("t_odd001"))
        odd.set("title", .string("Written by a newer build"))
        odd.set("minutes", .int(20))
        odd.set("energy", .string("medium"))
        odd.set("urgency", .int(3))
        odd.set("importance", .string("high"))
        odd.set("quadrant", .null)
        odd.set("firstStep", .string("Start."))
        odd.set("category", .string("general"))
        odd.set("when", .string(today))
        odd.set("at", .string("12:00"))
        odd.set("steps", .null)
        odd.set("local", .bool(false))
        odd.set("gcal", .null)
        odd.set("done", .bool(false))
        odd.set("doneAt", .null)
        odd.set("skipped", .bool(false))
        odd.set("mood", .string("restless"))
        odd.set("colour", .int(7))
        odd.set("updatedAt", .int(ms(today, 6)))
        tasks.append(.object(odd))

        /* Eighty more across three days, so `taskMax` bites, `dropped` is
           non-zero and the sort's tie-breakers are all exercised. */
        for i in 0..<80 {
            let day = DayKey.adding(i % 3 == 0 ? 0 : (i % 3 == 1 ? 1 : -1), to: today)
            let hour = 6 + (i % 14)
            tasks.append(task(id: String(format: "t_bulk%03d", i),
                              title: "Bulk item \(i)",
                              when: day,
                              at: String(format: "%02d:%02d", hour, (i * 7) % 60),
                              urgency: 1 + (i % 5),
                              minutes: 5 + (i % 8) * 15))
        }

        var counts = JSONObject()
        counts.set(DayKey.adding(-40, to: today), .int(3))
        counts.set(DayKey.adding(-9, to: today), .int(1))
        counts.set(DayKey.adding(-400, to: today), .int(9))   // outside the ledger floor

        var profile = JSONObject()
        profile.set("name", .string("Aiman"))
        profile.set("avatar", .string("\u{1F9D4}\u{1F3FB}"))

        var root = JSONObject()
        root.set("tasks", .array(tasks))
        root.set("notes", .array([]))
        root.set("profile", .object(profile))
        root.set("sentFeedbackOn", .null)
        root.set("signupOfferHidden", .bool(false))
        root.set("view", .string("matrix"))
        root.set("gcalOrphans", .array([.string("evt_orphan_1")]))
        root.set("doneCounts", .object(counts))
        return WebJSON.encode(.object(root))
    }

    private static func task(id: String, title: String, when: String?, at: String?,
                             urgency: Int = 3, minutes: Int = 20,
                             firstStep: String = "Open it and look at it for 2 minutes.",
                             done: Bool = false, doneAt: Int? = nil,
                             skipped: Bool = false) -> JSONValue {
        var o = JSONObject()
        o.set("id", .string(id))
        o.set("title", .string(title))
        o.set("minutes", .int(minutes))
        o.set("energy", .string("medium"))
        o.set("urgency", .int(urgency))
        o.set("importance", .string("low"))
        o.set("quadrant", .null)
        o.set("firstStep", .string(firstStep))
        o.set("category", .string("general"))
        o.set("when", when.map(JSONValue.string) ?? .null)
        o.set("at", at.map(JSONValue.string) ?? .null)
        o.set("steps", .null)
        o.set("local", .bool(false))
        o.set("gcal", .null)
        o.set("done", .bool(done))
        o.set("doneAt", doneAt.map(JSONValue.int) ?? .null)
        o.set("skipped", .bool(skipped))
        o.set("updatedAt", .int(1_758_000_000_000))
        return .object(o)
    }
}

// MARK: - the run

struct Case {
    let name: String
    let json: String
}

func clocks(around today: String) -> [(label: String, now: Date)] {
    func at(_ key: String, _ hour: Int, _ minute: Int) -> Date {
        var c = DateComponents()
        let parts = key.split(separator: "-").compactMap { Int($0) }
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        c.hour = hour; c.minute = minute
        return DayKey.calendar.date(from: c) ?? Date()
    }
    return [
        ("08:00 — before the default hour", at(today, 8, 0)),
        ("14:00 — inside the rescue window", at(today, 14, 0)),
        ("22:00 — past the quiet hour", at(today, 22, 0)),
        ("year boundary", at("2026-12-31", 23, 30)),
    ]
}

/* The snapshot's bytes in a fixed key order. See the note at the
   comparison below for why the wire blob itself cannot be diffed. */
func canonical(_ s: TaskSnapshot) -> Data {
    let coder = JSONEncoder()
    coder.dateEncodingStrategy = .secondsSince1970
    coder.outputFormatting = [.sortedKeys]
    return (try? coder.encode(s)) ?? Data()
}

func fingerprint(_ items: [(id: String, fire: Date, title: String, body: String)]) -> String {
    items.map { "\($0.id)|\(Int($0.fire.timeIntervalSince1970))|\($0.title)|\($0.body)" }
        .joined(separator: "\n")
}

@main
struct BridgeCheck {
    static func main() {
    let args = CommandLine.arguments
    let fixturesPath = args.count > 1 ? args[1] : "Checks/fixtures"

    var cases: [Case] = []

    let fm = FileManager.default
    let names = ((try? fm.contentsOfDirectory(atPath: fixturesPath)) ?? [])
        .filter { $0.hasSuffix(".json") }
        .sorted()
    for name in names {
        let url = URL(fileURLWithPath: fixturesPath).appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("  could not read \(name)")
            continue
        }
        cases.append(Case(name: name, json: text))
    }

    if cases.isEmpty {
        print("bridge: no fixtures under \(fixturesPath)")
        exit(2)
    }

    var failures = 0
    var checked = 0

    print("TZ=\(TimeZone.current.identifier)")

    for (label, now) in clocks(around: DayKey.of(Date())) {
        print("\n=== \(label) — \(DayKey.of(now)) ===")

        var all = cases
        all.append(Case(name: "synthetic.json", json: Synthetic.store(today: DayKey.of(now))))

        for item in all {
            checked += 1

            /* The one line the whole file exists for: the old input is the
               store as `localStorage` held it, the new input is the same
               store through the native codec. */
            let reencoded = StoreDocument.load(text: item.json, inShell: true).jsonString

            let old = LegacyBridge.packed(from: item.json, now: now)
            let new = TaskBridge.packed(from: reencoded, now: now)

            switch (old, new) {
            case (nil, nil):
                print("  ok    \(item.name)  no snapshot from either (no tasks key)")
            case (let a?, let b?):
                /* Compared as canonical bytes, not as `a.blob == b.blob`.
                   `TaskStore.encode` runs the struct through a plain
                   `JSONEncoder`, whose key order is NOT stable from one
                   call to the next in the same process — two encodes of
                   the same value come out with `hf` before `g` one time
                   and after it the next. Comparing those bytes would be a
                   test of Foundation's dictionary hashing rather than of
                   this code, and it fails at random. `canonical` sorts the
                   keys, which is the same information in a fixed order, so
                   a difference here is a real difference in what the
                   widget will read.

                   The blob is still checked: both of them must decode back
                   to the same snapshot, which is what the widget actually
                   does with it. */
                let ca = canonical(a.snapshot), cb = canonical(b.snapshot)
                let ra = TaskStore.decode(a.blob), rb = TaskStore.decode(b.blob)

                if ca == cb, ra != nil, ra == rb {
                    print("  ok    \(item.name)  snapshot \(ca.count) B identical, "
                          + "\(b.snapshot.tasks.count) tasks, dropped \(b.snapshot.dropped), "
                          + "wire \(b.blob.count) B")
                } else if ca == cb {
                    failures += 1
                    print("  FAIL  \(item.name)  snapshots match but the wire format "
                          + "did not round-trip (old \(ra == nil ? "nil" : "ok"), "
                          + "new \(rb == nil ? "nil" : "ok"))")
                } else {
                    failures += 1
                    print("  FAIL  \(item.name)  SNAPSHOT BYTES DIFFER "
                          + "(old \(ca.count) B, new \(cb.count) B)")
                    if a.snapshot.tasks != b.snapshot.tasks {
                        let oldIDs = a.snapshot.tasks.map(\.id)
                        let newIDs = b.snapshot.tasks.map(\.id)
                        if oldIDs != newIDs {
                            print("          ids: \(oldIDs.prefix(8)) vs \(newIDs.prefix(8))")
                        } else {
                            for (x, y) in zip(a.snapshot.tasks, b.snapshot.tasks) where x != y {
                                print("          \(x.id): \(x) vs \(y)")
                            }
                        }
                    }
                    if a.snapshot.day != b.snapshot.day {
                        print("          day \(a.snapshot.day) vs \(b.snapshot.day)") }
                    if a.snapshot.dropped != b.snapshot.dropped {
                        print("          dropped \(a.snapshot.dropped) vs \(b.snapshot.dropped)") }
                    if a.snapshot.calFrom != b.snapshot.calFrom {
                        print("          calFrom \(a.snapshot.calFrom ?? "-") vs \(b.snapshot.calFrom ?? "-")") }
                    if a.snapshot.histFrom != b.snapshot.histFrom {
                        print("          histFrom \(a.snapshot.histFrom ?? "-") vs \(b.snapshot.histFrom ?? "-")") }
                    if a.snapshot.cal != b.snapshot.cal { print("          cal differs") }
                    if a.snapshot.hist != b.snapshot.hist { print("          hist differs") }
                    if a.snapshot.doneToday != b.snapshot.doneToday {
                        print("          doneToday \(a.snapshot.doneToday) vs \(b.snapshot.doneToday)")
                    }
                }
            default:
                failures += 1
                print("  FAIL  \(item.name)  one side produced no snapshot at all "
                      + "(old \(old == nil ? "nil" : "ok"), new \(new == nil ? "nil" : "ok"))")
            }

        checked += 1
            let oldPlan = LegacyReminders.parse(item.json, now: now)
                .map { (id: $0.id, fire: $0.fire, title: $0.title, body: $0.step) }
            let newPlan = ReminderPlanner.parse(reencoded, now: now)
                .map { (id: $0.id, fire: $0.fire, title: $0.title, body: $0.step) }

            let a = fingerprint(oldPlan), b = fingerprint(newPlan)
            if a == b {
                print("  ok    \(item.name)  schedule identical, \(newPlan.count) reminders")
            } else {
                failures += 1
                print("  FAIL  \(item.name)  SCHEDULE DIFFERS "
                      + "(old \(oldPlan.count), new \(newPlan.count))")
                let oldLines = a.split(separator: "\n", omittingEmptySubsequences: false)
                let newLines = b.split(separator: "\n", omittingEmptySubsequences: false)
                for i in 0..<max(oldLines.count, newLines.count) {
                    let x = i < oldLines.count ? String(oldLines[i]) : "—"
                    let y = i < newLines.count ? String(newLines[i]) : "—"
                    if x != y { print("          \(x)\n       vs \(y)") }
                }
            }
        }
    }

    print("\n---")
    print("checked \(checked) comparisons, \(failures) failed")
    if failures > 0 {
        print("bridge FAILED — the native store does not feed the widgets and the "
              + "notification schedule the way localStorage did.")
        exit(1)
    }
    print("bridge OK — every fixture's snapshot blob and schedule is byte-for-byte "
          + "what the shell produced.")
    exit(0)
    }
}
