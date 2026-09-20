/* ============================================================
   Checks/parity-triage.swift — the offline parser against the real one

   Not an Xcode target. A `swiftc` program that compiles this repo's
   `MyADHD/Core`, `MyADHD/Triage` and `Shared/TaskSnapshot.swift` —
   the app target's own sources, side by
   side exactly as the app builds them — and then loads the REAL
   `app.js` from the web checkout into a JavaScriptCore context and
   runs both parsers over the same corpus.

       Checks/parity-triage.sh

   What it evaluates is the DOM-free slice of app.js and nothing else:

     lines  637-1070   the dates block, parseClock, parseDay,
                       parseMinutes, CATEGORY_HINTS, QUALIFIER,
                       tidyTitle, TRAILING_WHEN, tidyWhen, SHORT_VERB,
                       SPLIT_ON, splitDump, parseLocally, timing and
                       normalizeTask
     lines 5018-5057   PREVIEW_MAX and previewDates
     lines 5308-5322   knownNames

   Nothing is retyped: the slice is cut out of the file on disk by
   line number every run, so a change to a rule in app.js shows up
   here as a failure rather than as two ports that agree with each
   other and not with the web.

   Three things are pinned so the two sides can be compared at all:

   - **`Date`.** A Proxy over the real constructor answers the pinned
     instant for `new Date()` and `Date.now()`, and forwards every
     other construction. The Swift side takes the same instant as an
     explicit `now:` argument.
   - **`Math.random`.** A tiny LCG, because `normalizeTask` mints an
     id from it. Ids are dropped before comparison either way — two
     runs of the same parser never agree on one, and nothing about
     the id is a rule.
   - **The time zone.** Set with `NSTimeZone.default` before `DayKey`
     is first touched, and with `TZ` + `tzset()` before the JSContext
     exists, so Foundation and JavaScriptCore read the same rules.
     One zone per process — which is why the shell script runs this
     three times rather than looping inside it.

   What is compared, per dump, all three of them:

     1. `splitDump` — the array of fragments, in order
     2. `parseLocally` — every task, as `JSON.stringify` writes it
        with `id` deleted, so field order, null-versus-absent and
        number formatting are all in scope
     3. `previewDates` — the chip strings the composer would draw,
        overflow legend included

   A dump passes only if all three match. `knownNames` is checked
   separately, over whole task lists rather than dumps, because it
   reads the store and not a line of text. The report names every dump
   and every list that diverges, with both sides printed.
   ============================================================ */

import Foundation
import JavaScriptCore

// MARK: - the corpus

/// Dump lines, in the shapes real ones come in. Several are multi-line
/// on purpose: `splitDump` splits on newlines before anything else.
enum Corpus {

    static var all: [String] { handwritten + generated }

    static let handwritten: [String] = [
        // --- plain English, no timing ---------------------------------
        "buy milk",
        "call the dentist",
        "email the landlord about the leak",
        "sort out the bins",
        "write the quarterly report",
        "research a new phone plan",
        "book the car in for a service",
        "reply to the vendor",
        "pay the electricity bill",
        "renew my passport",
        "fix the wobbly shelf",
        "clean the bathroom properly",
        "organise the photos from last year",
        "draft the deck for the client",
        "refactor the auth module",
        "plan next month",
        "deep work on the pitch",
        "rsvp to the wedding",
        "confirm the booking",
        "cancel the gym membership",

        // --- SHORT_VERB splits ----------------------------------------
        "buy milk, pay rent, get petrol",
        "do the dishes, go to the post office",
        "ask mum about sunday, fix the tap",
        "eat, run, log the miles",
        "put the bins out, top up the card, tag the photos",
        "see the doctor, add it to the calendar",
        "try the new route, cut the grass, mow the verge",
        "set the alarm, pop to the shop, dry the washing",
        "bin the old files, use up the leftovers",
        "get the parcel, return the jumper",

        // --- the comma-with-connective rule ---------------------------
        "call the bank, and then email the accountant",
        "finish the slides, and book the room",
        "pick up the parcel, then drop off the return",
        "write the intro, and then send it to the client",
        "wash the car, then do the shopping",

        // --- QUALIFIER fold-backs -------------------------------------
        "file the tax return, deadline is tomorrow",
        "pay rent, friday",
        "book the flights, before the end of the month",
        "email the school, urgent",
        "sort the invoice, due monday",
        "renew the insurance, at 4pm",
        "call grandma, this sunday",
        "send the contract, next week",
        "clean the oven, takes 40 minutes",
        "collect the prescription, on tuesday",
        "call the clinic, asap",
        "return the parcel, no rush",
        "book the dentist, sometime",
        "do the laundry, maybe",
        "draft the email, i think tomorrow",
        "check the boiler, apparently urgent",
        "text back sara, whenever",
        "buy a card, her birthday is on the 12th",
        "pay the fine, 14 march",
        "post the forms, morning",

        // --- explicit durations ---------------------------------------
        "review the doc in 2 hours",
        "review doc in 2 hours",
        "clean the kitchen, takes about 45 min",
        "write the report, roughly an hour",
        "call the client for 20m",
        "deep clean the flat all day",
        "sort the garage all morning",
        "answer emails half an hour",
        "answer emails half hour",
        "study 1h30",
        "study 2h",
        "walk 90 min",
        "walk 45 minutes",
        "meditate a couple of hours",
        "read a few hours",
        "nap half an hour",
        "gym 1.5 hr",
        "gym 1.5 hours",
        "workout six hours",
        "stretch 15m",

        // --- days -----------------------------------------------------
        "dentist tomorrow",
        "dentist tmr",
        "dentist tmrw",
        "day after tomorrow, pick up the keys",
        "call the vet today",
        "finish the deck tonight",
        "run this morning",
        "shop this afternoon",
        "dinner this evening",
        "in 3 days the rent is due",
        "in 14 days renew the licence",
        "in a week, book the flights",
        "next week send the invoice",
        "9 march the exam",
        "9th of march the exam",
        "march 9 the exam",
        "the interview is on 31 february",
        "the visa expires 1 jan",
        "party on 25 dec",
        "submit by 30 sept",

        // --- times ----------------------------------------------------
        "gym 1pm",
        "gym at 1pm",
        "dentist 3pm",
        "eat at 8am",
        "standup 9:15 am",
        "call at 16:00",
        "lunch at noon",
        "deploy at midnight",
        "meeting at midday",
        "dinner with sara tonight at 7.30pm",
        "friday 9am the review",
        "monday at 08:30 the handover",
        "pick up the kids 4.15pm",
        "RM9.30 for the parking",
        "1 5 things to buy",
        "half nine at the clinic",
        "half nine",
        "coffee at half past nine",
        "train at 06:05",
        "train at 23:59",

        // --- weekday roll-over ----------------------------------------
        "pay rent friday",
        "pay rent next friday",
        "gym on wednesday",
        "gym next wednesday",
        "call on tues",
        "call on thurs",
        "call on thu",
        "sat: clean the car",
        "satur: clean the car",
        "see the physio wednes",

        // --- Malay ----------------------------------------------------
        "bayar bil api esok",
        "hantar borang cukai",
        "jumpa doktor gigi hari khamis",
        "beli barang dapur",
        "basuh baju",
        "telefon mak petang ini",
        "hantar anak ke sekolah 7am",
        "bayar sewa rumah sebelum 5 haribulan",
        "buat kerja rumah, lepas tu tidur",
        "pergi pejabat pos, ambil parcel",

        // --- code-switched --------------------------------------------
        "call Encik Rahman pasal invoice esok",
        "email boss pasal cuti, urgent",
        "book appointment dengan dentist 3pm",
        "settle the bill kat bank tomorrow",
        "pergi gym at 6am then breakfast",
        "reply client punya email, deadline friday",
        "beli groceries, and then pick up the parcel",
        "renew roadtax before 30 jun",
        "hantar laptop repair, takes 2 hours",
        "meeting dengan team at 10:30",

        // --- multi-line dumps -----------------------------------------
        "buy milk\ncall the dentist\npay the rent friday",
        "write the report\n- book the room\n- 2. send the invite",
        "• clean the kitchen • do the laundry • take the bins out",
        "email the client; call the bank; pay the invoice",
        "sort the tax return, deadline is tomorrow\ngym 1pm\nbuy a birthday card for mum",
        "tidy the desk\n\n\nread the contract\n",
        "   \n  buy stamps  \n   ",
        "a\nb\nc",
        "ok\nno\nyes",

        // --- awkward edges --------------------------------------------
        "",
        "   ",
        "hi",
        "hiya",
        ",,,,",
        "1. 2. 3.",
        "-- buy milk",
        "— pay rent",
        "– call mum",
        "*** deploy the site",
        "10) renew the licence",
        "café pay the bill",
        "MEETING AT 4PM",
        "Pay The Rent Friday",
        "pAy ThE rEnT tOmOrRoW",
        "buy milk," ,
        ", buy milk",
        "buy milk, and then",
        "takes 25 min, tomorrow",
        "tomorrow, takes 25 min",
        "review the contract in 2 hours, tomorrow",
        "call the clinic tonight at 7, takes 10 min",
        "🙂 buy milk",
        "ßeta test the build",
        "the deadline is the deadline",

        // --- the four engine differences JSRegex exists for ----------
        // Each of these parses one way in JavaScript and the other way
        // under ICU's own \b, \d, \s and case folding. They are the
        // negative control: swap JSRE.b for "\\b" and this block is
        // what starts failing.
        "cafépay the bill",              // \b: e-acute is a word char to ICU
        "naïvepay the rent",
        "münchengym at 6am",
        "ドイツpay the invoice",
        "walk ٩٠ min",                   // \d: Arabic-Indic digits
        "train at ٩:٣٠",
        "renew the licence in ٣ days",
        "beli barang, ٩٠٩٠ ringgit",     // \w inside SPLIT_ON's lookahead
        "beli barang, ドイツ barang lagi",
        "buy milk,\u{FEFF}pay the rent",  // \s: BOM is white space to JS only
        "buy milk,\u{00A0}pay the rent",
        "buy milk,\u{0085}pay the rent",  // and NEL is, to ICU only
        "boo\u{212A} the flight",         // U+212A, which /i must NOT fold
        "\u{017F}end the invoice",        // U+017F, likewise
    ]

    /// Title lists for `knownNames`. Each one is a whole `state.tasks`.
    ///
    /// The cap gets its own set, because app.js breaks out of the loop
    /// on `seen.size >= 40` and then slices to 40 again — a run that
    /// pushes the set past 40 inside one title keeps its whole run and
    /// is then cut, which is a different answer from stopping at 40.
    static var titleSets: [[String]] {
        var out: [[String]] = [
            [],
            ["buy milk"],
            ["Buy milk"],                                  // first word never counts
            ["call Encik Rahman about the invoice"],
            ["drop the keys at Vista Komanwel Block B"],
            ["email Sara Jane Thompson the contract"],
            ["pay JKR and TNB before Friday"],             // two-letter runs are too short
            ["meet Ah Seng at Kedai Kopi Lai Foong"],
            ["renew the Perodua Myvi roadtax"],
            ["send Dr O'Brien the referral"],              // apostrophe is a word character
            ["post the form to Kuala-Lumpur City Hall"],   // so is the hyphen
            ["ask Mum, Dad and Aunty Rose about Sunday"],
            ["book the İstanbul flight"],                  // Lu, and two UTF-16 units of it
            ["email ᏣᎳᎩ about the design"],                 // Lu outside Latin
            ["file the ΑΒΓ paperwork"],                    // Greek capitals
            ["chase the 2024 invoice"],                    // digits are word characters
            ["中文 title with no capitals at all"],
            ["🙂 buy milk from Tesco Extra"],
            ["", "   ", "Ok"],
            ["call Bob"],                                  // a two-letter run does not count
            ["call Robert"],
        ]
        // One set that runs past the cap, and one that lands on it.
        out.append((1...60).map { "call Person\($0) about it" })
        out.append((1...40).map { "call Person\($0) about it" })
        return out
    }

    /// Generated, but not filler: every one of these is a rule this
    /// port could get wrong on its own.
    static var generated: [String] {
        var out: [String] = []

        // Every clock hour, am and pm — the bare-time rule has to pick
        // today or tomorrow against the pinned instant, and half of
        // these fall either side of it.
        for h in 1...12 {
            out.append("gym \(h)am")
            out.append("gym \(h)pm")
        }
        // The same, with minutes, in both of the separators app.js reads.
        for h in [1, 5, 9, 11] {
            out.append("call at \(h).30pm")
            out.append("call at \(h):45am")
        }
        // 24-hour, including the ones that are out of range and must
        // come back as no time at all.
        for h in [0, 6, 9, 13, 18, 23, 24, 25] {
            out.append("train at \(h):00")
            out.append("train at \(h):61")
        }
        // Every weekday, bare and with "next" leading it.
        for d in ["sun", "mon", "tue", "tues", "wed", "wednes", "thu", "thur",
                  "thurs", "fri", "sat", "satur"] {
            out.append("pay rent \(d)")
            out.append("pay rent next \(d)")
            out.append("pay rent \(d)day")
        }
        // Every month, both orders, with and without the ordinal.
        for m in ["jan", "february", "mar", "april", "may", "jun", "jul",
                  "august", "sept", "oct", "nov", "december"] {
            out.append("the exam on 9 \(m)")
            out.append("the exam on 9th of \(m)")
            out.append("the exam on \(m) 9")
            out.append("the exam on \(m) 31st")
        }
        // "in N days", across the week and the month boundary.
        for n in [0, 1, 2, 3, 6, 7, 13, 30, 31, 100, 365] {
            out.append("renew the licence in \(n) days")
        }
        // Durations, every shape parseMinutes reads.
        for n in [1, 2, 5, 15, 45, 90, 240, 600] {
            out.append("write the report \(n) min")
            out.append("write the report \(n)m")
        }
        for w in ["a", "an", "one", "two", "three", "four", "five", "six",
                  "couple", "few", "half"] {
            out.append("study \(w) hours")
            out.append("study \(w) of hours")
        }
        return out
    }
}

// MARK: - the JavaScript side

struct WebSide {

    let context: JSContext
    private let probe: JSValue
    private let names: JSValue

    /// The three slices of app.js, by 1-based line number.
    static let parserLines = 637...1070
    static let previewLines = 5018...5057
    static let namesLines = 5308...5322

    /// What each slice has to still contain.
    ///
    /// A line range alone is a silent trap: insert forty lines above
    /// `parseDay` and the range slides onto whatever now sits there,
    /// and the run either throws something unreadable or — worse —
    /// evaluates a slice that no longer holds the rule under test and
    /// reports a clean pass. `parity-ordering.swift` anchors its slices
    /// by content for exactly this reason; these do the same, so a
    /// moved function fails the check by name instead of by accident.
    static let parserAnchors = ["function parseDay(", "function parseClock(",
                                "function normalizeTask(", "function splitDump("]
    static let previewAnchors = ["function previewDates(", "PREVIEW_MAX"]
    static let namesAnchors = ["function knownNames("]

    init(appJS path: String, nowMS: Double) throws {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw Failure("cannot read \(path)")
        }
        let lines = source.components(separatedBy: "\n")
        func slice(_ r: ClosedRange<Int>, _ anchors: [String]) throws -> String {
            guard r.upperBound <= lines.count else {
                throw Failure("app.js has \(lines.count) lines, needs \(r.upperBound)")
            }
            let body = lines[(r.lowerBound - 1)...(r.upperBound - 1)].joined(separator: "\n")
            for anchor in anchors where !body.contains(anchor) {
                throw Failure("app.js \(r) no longer contains `\(anchor)` — the line "
                              + "numbers have drifted from their source; re-cut the slice")
            }
            return body
        }

        guard let ctx = JSContext() else { throw Failure("no JSContext") }
        self.context = ctx
        var trouble: String?
        ctx.exceptionHandler = { _, e in trouble = e?.toString() ?? "unknown" }

        func run(_ js: String, _ what: String) throws {
            trouble = nil
            ctx.evaluateScript(js)
            if let trouble { throw Failure("\(what): \(trouble)") }
        }

        try run(Self.prelude(nowMS: nowMS), "prelude")
        try run(try slice(Self.parserLines, Self.parserAnchors),
                "app.js \(Self.parserLines)")
        try run(try slice(Self.previewLines, Self.previewAnchors),
                "app.js \(Self.previewLines)")
        try run(try slice(Self.namesLines, Self.namesAnchors),
                "app.js \(Self.namesLines)")
        try run(Self.postlude, "postlude")

        guard let fn = ctx.objectForKeyedSubscript("__probe"), !fn.isUndefined,
              let nf = ctx.objectForKeyedSubscript("__names"), !nf.isUndefined
        else { throw Failure("the probes did not define") }
        self.probe = fn
        self.names = nf
    }

    /// `knownNames()` over one whole `state.tasks`.
    func knownNames(_ titles: [String]) throws -> [String] {
        guard let out = names.call(withArguments: [titles]), !out.isUndefined,
              let text = out.toString()
        else { throw Failure("__names returned nothing") }
        return (try JSONValue.parse(text).arrayValue ?? []).compactMap(\.stringValue)
    }

    /// `{split, tasks, chips}` for one dump, as the web computes it.
    func probe(_ dump: String) throws -> Reading {
        guard let out = probe.call(withArguments: [dump]), !out.isUndefined,
              let text = out.toString()
        else { throw Failure("__probe returned nothing") }
        let v = try JSONValue.parse(text)
        return Reading(
            split: (v["split"]?.arrayValue ?? []).compactMap(\.stringValue),
            tasks: (v["tasks"]?.arrayValue ?? []).compactMap(\.stringValue),
            chips: (v["chips"]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    /// Date pinned, Math.random stubbed, and the handful of globals the
    /// slice reaches for that live elsewhere in app.js.
    static func prelude(nowMS: Double) -> String {
        """
        (function () {
          var Real = Date;
          var FIXED = \(String(format: "%.0f", nowMS));
          globalThis.Date = new Proxy(Real, {
            construct: function (target, args) {
              return args.length === 0 ? new target(FIXED) : new target(...args);
            },
            apply: function () { return new Real(FIXED).toString(); },
            get: function (target, prop, recv) {
              if (prop === 'now') return function () { return FIXED; };
              return Reflect.get(target, prop, recv);
            }
          });
          var seed = 1;
          Math.random = function () {
            seed = (seed * 1103515245 + 12345) % 2147483648;
            return seed / 2147483648;
          };
        })();

        /* app.js:1176 — normalizeTask reads it, and it is derived from
           QUADRANTS (app.js:1169-1174), which is outside the slice. */
        const QUADRANT_KEYS = ['do', 'plan', 'delegate', 'drop'];

        /* knownNames walks the live store. Each call replaces it. */
        globalThis.state = { tasks: [] };

        /* previewDates builds real elements. Nothing here pretends to be
           a DOM beyond the four things it touches. */
        globalThis.document = {
          createElement: function () { return { className: '', textContent: '' }; }
        };
        """
    }

    static let postlude = """
    function __preview(text) {
      var out = [];
      var src = { value: text };
      var box = { classList: { toggle: function () {} } };
      var chips = {
        set innerHTML(v) { out.length = 0; },
        get innerHTML() { return ''; },
        appendChild: function (el) { out.push(el.textContent); }
      };
      previewDates(src, box, chips);
      return out;
    }

    function __names(titles) {
      state.tasks = titles.map(function (t) { return { title: t }; });
      return JSON.stringify(knownNames());
    }

    function __probe(text) {
      var tasks = parseLocally(text).map(function (t) {
        var o = Object.assign({}, t);
        delete o.id;                 // minted from Math.random; never a rule
        return JSON.stringify(o);
      });
      return JSON.stringify({ split: splitDump(text), tasks: tasks, chips: __preview(text) });
    }
    """
}

// MARK: - the Swift side

struct Reading: Equatable {
    var split: [String]
    var tasks: [String]
    var chips: [String]
}

enum NativeSide {
    static func probe(_ dump: String, now: Date) -> Reading {
        let tasks = LocalTriage.parseLocally(dump, now: now).map { t -> String in
            var o = t.encoded()
            o.removeValue(forKey: "id")
            return WebJSON.encode(o)
        }
        let preview = DatePreview.chips(in: dump, now: now, today: WebDates.dayKey(now))
        return Reading(split: LocalTriage.splitDump(dump),
                       tasks: tasks,
                       chips: preview.chips + (preview.more.map { [$0] } ?? []))
    }
}

// MARK: -

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

@main
struct ParityTriage {

    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        func take(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let v = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return v
        }

        let tz = take("--tz") ?? "UTC"
        let nowMS = Double(take("--now") ?? "") ?? 0
        let appJS = take("--app-js")
            ?? "/Users/User/Desktop/Claude Code/My.adhd/app.js"
        let verbose = args.contains("--verbose")

        /* Before anything reads a date. `DayKey.calendar` captures
           `.current` the first time it is touched and keeps it for the
           life of the process, so the zone has to be in place now — and
           `TZ` has to be set before the JSContext is built, because
           JavaScriptCore asks the C library. */
        guard let zone = TimeZone(identifier: tz) else {
            FileHandle.standardError.write(Data("unknown time zone \(tz)\n".utf8))
            exit(2)
        }
        NSTimeZone.default = zone
        setenv("TZ", tz, 1)
        tzset()

        let now = Date(timeIntervalSince1970: nowMS / 1000)
        let stamp = ISO8601DateFormatter()
        stamp.timeZone = zone
        stamp.formatOptions = [.withInternetDateTime]

        print("parity-triage")
        print("  zone     \(tz)")
        print("  pinned   \(stamp.string(from: now))  (\(WebDates.dayKey(now)))")
        print("  app.js   \(appJS)")

        let web: WebSide
        do {
            web = try WebSide(appJS: appJS, nowMS: nowMS)
        } catch {
            FileHandle.standardError.write(Data("cannot load app.js: \(error)\n".utf8))
            exit(2)
        }

        let corpus = Corpus.all
        var passed = 0
        var failures: [(dump: String, web: Reading, native: Reading)] = []

        /* Counted and printed because a comparison that compared
           nothing would also pass. These are what the pass rate is a
           rate over. */
        var fragments = 0, tasks = 0, chips = 0, dated = 0, timed = 0

        for dump in corpus {
            let native = NativeSide.probe(dump, now: now)
            let theirs: Reading
            do {
                theirs = try web.probe(dump)
            } catch {
                FileHandle.standardError.write(Data("__probe failed on \(show(dump)): \(error)\n".utf8))
                exit(2)
            }
            fragments += theirs.split.count
            tasks += theirs.tasks.count
            chips += theirs.chips.count
            dated += theirs.tasks.filter { !$0.contains("\"when\":null") }.count
            timed += theirs.tasks.filter { !$0.contains("\"at\":null") }.count

            if native == theirs {
                passed += 1
                if verbose { print("  ok    \(show(dump))") }
            } else {
                failures.append((dump, theirs, native))
            }
        }

        print("  corpus   \(corpus.count) dumps")
        print("  compared \(fragments) fragments, \(tasks) tasks "
              + "(\(dated) with a day, \(timed) with a time), \(chips) chips")
        let rate = corpus.isEmpty ? 100.0 : Double(passed) / Double(corpus.count) * 100
        print(String(format: "  passed   %d/%d  (%.2f%%)", passed, corpus.count, rate))

        // knownNames, over whole task lists rather than dumps.
        var namesPassed = 0
        var namesFailed: [(titles: [String], web: [String], native: [String])] = []
        for titles in Corpus.titleSets {
            let native = KnownNames.from(titles: titles)
            let theirs: [String]
            do {
                theirs = try web.knownNames(titles)
            } catch {
                FileHandle.standardError.write(Data("__names failed: \(error)\n".utf8))
                exit(2)
            }
            if native == theirs { namesPassed += 1 } else { namesFailed.append((titles, theirs, native)) }
        }
        let nameSets = Corpus.titleSets.count
        print(String(format: "  names    %d/%d lists  (%.2f%%)",
                     namesPassed, nameSets,
                     nameSets == 0 ? 100 : Double(namesPassed) / Double(nameSets) * 100))

        if !namesFailed.isEmpty {
            print("\nknownNames divergences:")
            for f in namesFailed {
                print("\n  titles  \(f.titles)")
                print("    web     \(f.web)")
                print("    native  \(f.native)")
            }
        }

        if !failures.isEmpty {
            print("\ndivergences:")
            for f in failures {
                print("\n  dump    \(show(f.dump))")
                if f.web.split != f.native.split {
                    print("    split  web    \(f.web.split)")
                    print("           native \(f.native.split)")
                }
                if f.web.chips != f.native.chips {
                    print("    chips  web    \(f.web.chips)")
                    print("           native \(f.native.chips)")
                }
                if f.web.tasks != f.native.tasks {
                    let n = max(f.web.tasks.count, f.native.tasks.count)
                    for i in 0..<n {
                        let a = i < f.web.tasks.count ? f.web.tasks[i] : "(missing)"
                        let b = i < f.native.tasks.count ? f.native.tasks[i] : "(missing)"
                        if a != b {
                            print("    task \(i) web    \(a)")
                            print("           native \(b)")
                        }
                    }
                }
            }
        }

        exit(failures.isEmpty && namesFailed.isEmpty ? 0 : 1)
    }

    /// A dump on one line, so a multi-line one still reads in a report.
    static func show(_ s: String) -> String {
        WebJSON.quoted(s)
    }
}
