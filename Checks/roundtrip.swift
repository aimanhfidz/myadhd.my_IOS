/* ============================================================
   Checks/roundtrip.swift — the store codec, proved

   Not an Xcode target. A `swiftc` program over the app target's own
   sources, so it compiles the `MyADHD/Core` sources and
   `Shared/TaskSnapshot.swift` side by side exactly as the app does and
   there is no second copy of anything.

       Checks/roundtrip.sh

   What it asserts, fixture by fixture:

   1. **Byte identity.** `JSONValue.parse` then `WebJSON.encode` returns
      the fixture's bytes unchanged. The fixtures are written by node's
      `JSON.stringify`, so this is the real claim — key order, number
      formatting, escaping and all — not a Swift-to-Swift tautology.

   2. **Document identity.** For a store that `load()` does not migrate,
      `StoreDocument.load(...).jsonString` is also byte-identical: no
      key added, none dropped, none moved. Unknown top-level keys and
      unknown TASK keys survive, which is the requirement that stops
      this phone erasing a newer web build's field for every other
      device the person owns (cloud.js:290-293).

   3. **Stability.** For the fixture `load()` DOES migrate — legacy
      `{title, body}` notes, and the dead `energy` key — loading the
      output again reproduces it exactly. A migration that is not a
      fixed point would rewrite the store on every launch.

   4. The encoder's number and string rules against the values node
      prints, because `sigOf` hashes these bytes.

   Run `Checks/roundtrip.sh` for the node cross-check as well: it
   re-parses every output and asserts deep equality with the fixture.
   ============================================================ */

import Foundation

@main
struct Roundtrip {

    // Frozen, so a fixture that needs `Date.now()` is reproducible.
    static let frozenNow: Double = 1_758_355_200_000     // 2026-09-20T08:00:00Z

    static var failures: [String] = []
    static var checks = 0

    static func ok(_ condition: Bool, _ what: String) {
        checks += 1
        if !condition {
            failures.append(what)
            print("  FAIL  \(what)")
        }
    }

    static func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) {
        checks += 1
        if a != b {
            failures.append(what)
            print("  FAIL  \(what)\n          got      \(a)\n          expected \(b)")
        }
    }

    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        var outDir: String?
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
            outDir = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        let dir = args.first ?? "Checks/fixtures"

        encoderRules()
        normalizerRules()

        for c in cases {
            print("\n\(c.file)")
            let path = dir + "/" + c.file
            guard let data = FileManager.default.contents(atPath: path) else {
                failures.append("\(c.file): not found at \(path)")
                print("  FAIL  not found at \(path)")
                continue
            }
            let text = String(decoding: data, as: UTF8.self)

            // 1 — the tree itself
            guard let parsed = try? JSONValue.parse(data) else {
                failures.append("\(c.file): will not parse")
                print("  FAIL  will not parse")
                continue
            }
            eq(WebJSON.encode(parsed), text, "\(c.file): JSONValue re-encodes byte for byte")

            // 2 / 3 — the document
            let doc = StoreDocument.load(parsed, inShell: true, now: frozenNow)
            let out = doc.jsonString
            if c.identity {
                eq(out, text, "\(c.file): StoreDocument re-encodes byte for byte")
            } else {
                ok(out != text, "\(c.file): load() is expected to migrate this one")
            }
            let again = StoreDocument.load(text: out, inShell: true).jsonString
            eq(again, out, "\(c.file): load() is a fixed point")

            c.check(doc, out)

            if let outDir {
                try? FileManager.default.createDirectory(atPath: outDir,
                                                         withIntermediateDirectories: true)
                try? Data(out.utf8).write(to: URL(fileURLWithPath: outDir + "/" + c.file))
            }
        }

        print("\n\(checks) checks, \(failures.count) failed")
        if !failures.isEmpty {
            print("\nfailures:")
            for f in failures { print("  - \(f)") }
            exit(1)
        }
        print("roundtrip OK")
    }

    // MARK: - the fixtures

    struct Case {
        let file: String
        /// true when `load()` should change nothing at all.
        let identity: Bool
        let check: (StoreDocument, String) -> Void
    }

    static let cases: [Case] = [

        Case(file: "fresh.json", identity: true) { doc, _ in
            ok(doc.tasks.isEmpty, "fresh: no tasks")
            ok(doc.notes.isEmpty, "fresh: no notes")
            eq(doc.view, "list", "fresh: view")
            eq(doc.profile.name, "", "fresh: profile name")
            eq(doc.profile.avatar, "🧔🏻", "fresh: profile avatar")
            eq(doc.sentFeedbackOn, nil, "fresh: sentFeedbackOn is null, and is written")
            ok(doc.extra.isEmpty, "fresh: nothing unknown")
        },

        Case(file: "pre-importance.json", identity: true) { doc, _ in
            eq(doc.tasks.count, 2, "pre-importance: two tasks")
            let t = doc.tasks[0]
            // the keys really are missing, and reading did not add them
            ok(!t.has("importance"), "pre-importance: importance stays absent")
            ok(!t.has("quadrant"), "pre-importance: quadrant stays absent")
            ok(!t.has("skipped"), "pre-importance: skipped stays absent")
            ok(!t.has("doneAt"), "pre-importance: doneAt stays absent")
            ok(!t.has("updatedAt"), "pre-importance: updatedAt stays absent")
            // and the defaults are applied at use
            eq(t.importance, "low", "pre-importance: importance reads 'low'")
            eq(t.quadrant, nil, "pre-importance: quadrant reads nil")
            eq(t.skipped, false, "pre-importance: skipped reads false")
            eq(t.doneAt, nil, "pre-importance: doneAt reads nil")
            eq(t.updatedAt, nil, "pre-importance: updatedAt reads nil")
            eq(t.minutes, 20, "pre-importance: minutes")
            eq(t.when, "2026-09-21", "pre-importance: when")
            eq(t.at, "09:30", "pre-importance: at")
            eq(t.steps, nil, "pre-importance: steps null reads nil")
            let u = doc.tasks[1]
            eq(u.steps ?? [], ["Fill the bucket", "Do the wheels first"], "pre-importance: steps")
            eq(u.done, true, "pre-importance: done")
            eq(u.local, true, "pre-importance: local")
            eq(u.firstStep, "", "pre-importance: an empty firstStep is NOT the placeholder")
            eq(doc.doneCount("2026-09-18"), 3, "pre-importance: doneCounts")
            eq(doc.sentFeedbackOn, "2026-09-19", "pre-importance: sentFeedbackOn")
        },

        Case(file: "unknown-keys.json", identity: true) { doc, out in
            // the native app IS the shell, so a saved 'matrix' is honoured
            eq(doc.view, "matrix", "unknown: a stored 'matrix' survives in the shell")
            let inBrowser = StoreDocument.load(text: out, inShell: false)
            eq(inBrowser.view, "list", "unknown: outside a shell it would be forced to 'list'")

            eq(doc.extra.keys, ["labs", "streak"], "unknown: top-level keys ride along in order")
            eq(doc.extra["streak"]?.intValue, 7, "unknown: unknown top-level value")
            eq(doc.extra["labs"]?["rollout"]?.doubleValue, 0.25, "unknown: a nested double")
            ok(out.contains("\"rollout\":0.25"), "unknown: 0.25 is written as JS writes it")

            let t = doc.tasks[0]
            eq(t.extra.keys, ["pinned", "colour", "snoozeUntil"], "unknown: task keys ride along")
            ok(out.contains("\"skipped\":false,\"pinned\":true"),
               "unknown: unknown task keys sit between skipped and updatedAt")
            ok(out.contains("\"snoozeUntil\":null,\"updatedAt\":1758355200000"),
               "unknown: updatedAt stays last")
            eq(t.gcal, TaskItem.GCalRef(id: "gc_441", sig: "a1b2c3.128"), "unknown: gcal")
            eq(t.updatedAt, 1_758_355_200_000, "unknown: updatedAt is an integer, not 1.75e12")

            eq(doc.profile.name, "Aiman", "unknown: profile name")
            eq(doc.profile.extra["theme"]?.stringValue, "dark", "unknown: profile keeps its extras")
            eq(doc.gcalOrphans, ["evt_9912", "evt_9913"], "unknown: gcalOrphans")
            eq(doc.signupOfferHidden, true, "unknown: signupOfferHidden")

            let n = doc.notes[0]
            eq(n.repeatRule, "weekly", "unknown: note repeat")
            eq(n.remindOn, "2026-09-22", "unknown: note remindOn")
            eq(n.look.paper, "violet", "unknown: note paper")
            eq(n.body, "Milk\nEggs", "unknown: note body is derived from the blocks")
        },

        Case(file: "legacy-notes.json", identity: false) { doc, out in
            // the one key deliberately lost
            ok(!doc.extra.has("energy"), "legacy: the dead `energy` key is deleted")
            ok(!out.contains("\"energy\""), "legacy: and never written back")

            let n = doc.notes[0]
            eq(n.blocks.count, 3, "legacy: one block per line, trailing line included")
            eq(n.blocks.map(\.text), ["Blocked on signing", "Ask about the profile", ""],
               "legacy: the lines")
            eq(n.blocks.map(\.type), ["p", "p", "p"], "legacy: all plain paragraphs")
            eq(n.blocks.map(\.align), ["left", "left", "left"], "legacy: all left")
            eq(n.body, "Blocked on signing\nAsk about the profile\n",
               "legacy: body is the blocks joined back")
            eq(n.look.paper, "lavender", "legacy: the paper every note has always had")
            eq(n.look.font, "baloo", "legacy: the face every note has always had")
            eq(n.remindOn, nil, "legacy: no reminder")
            eq(n.repeatRule, "", "legacy: no repeat")
            ok(n.files.isEmpty, "legacy: no pictures")
            eq(n.createdAt, 1_757_000_000_000, "legacy: createdAt kept")
            eq(n.updatedAt, 1_757_000_001_000, "legacy: updatedAt kept")

            let m = doc.notes[1]
            ok(m.id.hasPrefix("n_"), "legacy: a note with no id is given one")
            eq(m.id.count, 9, "legacy: n_ plus seven base36")
            eq(m.blocks.count, 1, "legacy: an empty body is one empty block")
            eq(m.blocks[0].text, "", "legacy: and it is empty")
            eq(m.createdAt, frozenNow, "legacy: createdAt falls back to now")
            eq(m.updatedAt, frozenNow, "legacy: updatedAt follows createdAt")
        },

        Case(file: "emoji-marks.json", identity: true) { doc, out in
            let n = doc.notes[0]
            let b = n.blocks[0]
            eq(b.text.utf16.count, 17, "emoji: the block is 17 UTF-16 units")
            eq(b.marks.count, 3, "emoji: three marks")
            eq(b.marks[0].s, 0, "emoji: mark 0 start")
            eq(b.marks[0].e, 4, "emoji: mark 0 end")
            ok(b.marks[0].b, "emoji: mark 0 is bold")
            eq(b.marks[2].s, 12, "emoji: the mark over the sun starts at 12")
            eq(b.marks[2].e, 14, "emoji: and ends at 14 — two code units, one emoji")
            ok(b.marks[2].strike, "emoji: and it is a strike")
            eq(b.align, "center", "emoji: align survives")
            eq(n.blocks[1].done, true, "emoji: a ticked check block")

            // JSON.stringify does not \u-escape non-ASCII, and neither do we
            ok(out.contains("🌞"), "emoji: the sun is written raw, not as \\ud83c\\udf1e")
            ok(out.contains("☕"), "emoji: so is the coffee")
            ok(!out.contains("\\u"), "emoji: nothing in this store needs a \\u escape")
            eq(doc.profile.avatar, "👩🏽‍💻", "emoji: a ZWJ sequence survives as the avatar")
            eq(doc.profile.name, "Aīman 🧠", "emoji: and a combining-free non-ASCII name")

            eq(n.files.count, 1, "emoji: the picture is kept")
            eq(n.files[0].src, "data:image/png;base64,iVBORw0KGgo=", "emoji: its src")
        },
    ]

    // MARK: - the encoder, against what node prints

    static func encoderRules() {
        print("WebJSON")
        // numbers — every expectation here is node's own output
        eq(WebJSON.number(0.0), "0", "number: 0")
        eq(WebJSON.number(-0.0), "0", "number: -0 prints as 0")
        eq(WebJSON.number(3.0), "3", "number: an integral double has no fraction")
        eq(WebJSON.number(1.5), "1.5", "number: 1.5")
        eq(WebJSON.number(0.25), "0.25", "number: 0.25")
        eq(WebJSON.number(0.1), "0.1", "number: 0.1")
        eq(WebJSON.number(-2.5), "-2.5", "number: -2.5")
        eq(WebJSON.number(100.0), "100", "number: 100")
        eq(WebJSON.number(1e20), "100000000000000000000", "number: 1e20 is twenty zeros")
        eq(WebJSON.number(1e21), "1e+21", "number: 1e21 turns the corner")
        eq(WebJSON.number(1e-6), "0.000001", "number: 1e-6")
        eq(WebJSON.number(1e-7), "1e-7", "number: 1e-7 turns the other corner")
        eq(WebJSON.number(1.2345e-8), "1.2345e-8", "number: a small one with digits")
        eq(WebJSON.number(1_758_355_200_000), "1758355200000", "number: an epoch stamp")
        eq(WebJSON.number(Double.nan), "null", "number: NaN is null")
        eq(WebJSON.number(Double.infinity), "null", "number: Infinity is null")
        eq(WebJSON.number(5e-324), "5e-324", "number: the smallest one there is")

        // strings
        eq(WebJSON.quoted("a/b"), "\"a/b\"", "string: a slash is not escaped")
        eq(WebJSON.quoted("é😀"), "\"é😀\"", "string: non-ASCII is raw")
        eq(WebJSON.quoted("\u{01}"), "\"\\u0001\"", "string: a control char")
        eq(WebJSON.quoted("a\nb\tc"), "\"a\\nb\\tc\"", "string: the short escapes")
        eq(WebJSON.quoted("say \"hi\"\\"), "\"say \\\"hi\\\"\\\\\"", "string: quote and backslash")
        eq(WebJSON.quoted("\u{2028}"), "\"\u{2028}\"", "string: U+2028 is raw in JSON")

        // no whitespace anywhere
        let o = JSONObject([("a", .int(1)), ("b", .array([.int(2), .null]))])
        eq(WebJSON.encode(.object(o)), "{\"a\":1,\"b\":[2,null]}", "shape: no spaces")

        // duplicate keys: first position, last value — as JSON.parse does
        let dup = try? JSONValue.parse("{\"a\":1,\"b\":2,\"a\":3}")
        eq(dup.map { WebJSON.encode($0) } ?? "", "{\"a\":3,\"b\":2}", "shape: duplicate keys")
    }

    // MARK: - the normalisers

    static func normalizerRules() {
        print("Normalize")
        eq(Normalize.normalizeDay(.string("2026-09-20")), "2026-09-20", "day: a real day")
        eq(Normalize.normalizeDay(.string("2026-02-31")), nil, "day: 31 February is not a day")
        eq(Normalize.normalizeDay(.string("2026-13-01")), nil, "day: nor is month 13")
        eq(Normalize.normalizeDay(.string("2026-9-20")), nil, "day: nor is the wrong shape")
        eq(Normalize.normalizeDay(.string("0026-01-01")), nil, "day: nor is year 26")
        eq(Normalize.normalizeDay(.int(20260920)), nil, "day: nor is a number")
        eq(Normalize.normalizeDay(.string("2028-02-29")), "2028-02-29", "day: a leap day is")

        eq(Normalize.normalizeTime(.string("9:05")), "09:05", "time: padded")
        eq(Normalize.normalizeTime(.string("23:59")), "23:59", "time: the last minute")
        eq(Normalize.normalizeTime(.string("24:00")), nil, "time: there is no 24:00")
        eq(Normalize.normalizeTime(.string("09:60")), nil, "time: nor a 60th minute")
        eq(Normalize.normalizeTime(.string("0930")), nil, "time: nor a colonless one")

        eq(Normalize.clamp(.int(500), 2, 240, 20), 240, "clamp: high")
        eq(Normalize.clamp(.int(0), 2, 240, 20), 2, "clamp: low")
        eq(Normalize.clamp(.string("25"), 2, 240, 20), 25, "clamp: a numeric string")
        eq(Normalize.clamp(.string("about 25"), 2, 240, 20), 20, "clamp: prose falls back")
        eq(Normalize.clamp(nil, 2, 240, 20), 20, "clamp: a missing key falls back")
        eq(Normalize.clamp(.double(24.5), 2, 240, 20), 25, "clamp: Math.round is half-up")
        eq(Normalize.clamp(.double(-2.5), -10, 10, 0), -2, "clamp: and half-up downwards too")
        eq(Normalize.clamp(.null, 1, 5, 3), 1, "clamp: Number(null) is 0, then clamped")

        // normalizeTask, over the shape a model answer really has
        let raw = try! JSONValue.parse("""
        {"title":"Call the clinic","minutes":"15","urgency":9,"energy":"wired",
         "importance":"high","quadrant":"nowhere","first_step":"Find the number.",
         "category":"health","when":"2026-09-21","at":"9:5","steps":[1,2,3,4,5,6,7,8],
         "local":true,"id":"t_theirs","done":true}
        """)
        let t = Normalize.task(raw, now: Date(timeIntervalSince1970: 1_758_355_200), id: "t_fixed1")
        eq(t.fields.keys, TaskItem.baseKeys, "task: normalizeTask's literal key order")
        eq(t.id, "t_fixed1", "task: the incoming id is ignored and a new one minted")
        eq(t.minutes, 15, "task: a numeric string is a number")
        eq(t.urgency, 5, "task: urgency clamps to 5")
        eq(t.energy, "medium", "task: an energy nobody offers falls back")
        eq(t.importance, "high", "task: importance is kept when it is one of the two")
        eq(t.quadrant, nil, "task: a quadrant nobody offers becomes null")
        eq(t.firstStep, "Find the number.", "task: first_step is read as firstStep")
        eq(t.when, "2026-09-21", "task: when")
        eq(t.at, nil, "task: '9:5' is not a time")
        eq(t.steps?.count, 7, "task: seven steps at most")
        eq(t.local, true, "task: local")
        eq(t.done, false, "task: a new task is never done, whatever the model said")
        eq(t.skipped, false, "task: skipped is always written")
        ok(t.has("doneAt") && t.raw("doneAt")!.isNull, "task: doneAt is written as null")
        ok(t.has("gcal") && t.raw("gcal")!.isNull, "task: gcal is written as null")
        ok(!t.has("updatedAt"), "task: updatedAt is cloud.stamp's job, not normalizeTask's")

        let bare = Normalize.task(try! JSONValue.parse("{}"),
                                  now: Date(timeIntervalSince1970: 1_758_355_200),
                                  id: "t_fixed2")
        eq(bare.title, "Untitled", "task: an empty answer is Untitled")
        eq(bare.firstStep, Normalize.defaultFirstStep, "task: and gets the placeholder step")
        eq(bare.category, "general", "task: and lands in general")
        eq(bare.minutes, 20, "task: and takes twenty minutes")
        eq(bare.when, nil, "task: with no clock there is no day")

        // a clock time with no day gets the NEXT occurrence of it
        let noon = Date(timeIntervalSince1970: 1_758_355_200)   // fixed instant
        let cal = DayKey.calendar
        let today = DayKey.of(noon, cal)
        let mins = cal.component(.hour, from: noon) * 60 + cal.component(.minute, from: noon)
        let earlier = String(format: "%02d:%02d", max(0, mins - 60) / 60, max(0, mins - 60) % 60)
        let later = String(format: "%02d:%02d", min(1439, mins + 60) / 60, min(1439, mins + 60) % 60)
        eq(Normalize.dayForTime(later, now: noon), today, "dayForTime: later today is today")
        eq(Normalize.dayForTime(earlier, now: noon), DayKey.adding(1, to: today, cal),
           "dayForTime: a time already past is tomorrow")
        eq(Normalize.dayForTime(nil, now: noon), nil, "dayForTime: no clock, no day")

        // the UTF-16 caps
        eq(Normalize.slice("🙂🙂🙂", 4), "🙂🙂", "slice: counts UTF-16 units")
        eq(Normalize.slice("🙂🙂🙂", 3), "🙂", "slice: and will not split a pair")
        eq(Normalize.slice("abc", 10), "abc", "slice: a short string is untouched")
    }
}
