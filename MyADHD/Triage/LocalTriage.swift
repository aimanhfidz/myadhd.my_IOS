/* ============================================================
   LocalTriage — the offline parser, ported rule for rule

   Source: app.js 738-1031, in the order it is written there. This is
   `parseLocally()` and everything it leans on: the month tables,
   `parseClock`, `parseDay`, `parseMinutes`, `CATEGORY_HINTS` and
   `guessCategory`, `QUALIFIER`, `tidyTitle`, `TRAILING_WHEN`,
   `tidyWhen`, `SHORT_VERB`, `SPLIT_ON`, `splitDump`, and the
   QUICK/BIG/URGENT/WEIGHTY table that turns a line into a task.

   It runs only when `/api/triage` is unreachable, and it is a guess —
   but a guess that reads the words in front of it rather than
   defaulting everything to 20 minutes and one bucket. Tasks it
   produces carry `local: true` so the lists can say so and offer to
   re-sort, and the offline first step rather than the placeholder.

   Two standing rules, both of them the web's:

   - **No time is invented.** "morning" and "soon" give a day at most;
     a clock time only ever comes out of a clock time. A wrong time on
     the calendar is worse than no time at all.
   - **A time with no day is dropped**, because `parseLocally` passes
     `at: day ? parseClock(line) : null` — the day rule already gives
     a bare time its next occurrence, so if there is no day there was
     no time either.

   Every regex here is rebuilt out of `JSRE`, never written with `\b`,
   `\d`, `\s` or the `i` flag directly. JSRegex.swift says why at
   length; the short version is that ICU and JavaScript disagree about
   all four and the disagreement shows up on real dumps.
   ============================================================ */

import Foundation

enum LocalTriage {

    // MARK: - The offline first step (app.js:1021)

    /// What every offline task gets instead of the model's own first
    /// step. Not `Normalize.defaultFirstStep` — that is the
    /// placeholder `normalizeTask` writes when the model sent none,
    /// and this is a different sentence on purpose.
    static let firstStep = "Open whatever you need for this and look at it for 2 minutes. Nothing more."

    // MARK: - Months (app.js:735-737)

    static let monthRE = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t|tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"

    static let monthIndex: [String: Int] = [
        "jan": 0, "feb": 1, "mar": 2, "apr": 3, "may": 4, "jun": 5,
        "jul": 6, "aug": 7, "sep": 8, "oct": 9, "nov": 10, "dec": 11,
    ]

    // MARK: - parseClock (app.js:739-756)

    private static let reNoon = JSRegex(JSRE.b + "noon" + JSRE.b + "|" + JSRE.b + "midday" + JSRE.b)
    private static let reMidnight = JSRegex(JSRE.b + "midnight" + JSRE.b)
    private static let reAmPm = JSRegex(
        JSRE.b + "(" + JSRE.d + "{1,2})(?:[:.](" + JSRE.d + "{2}))?" + JSRE.s + "*(am|pm)" + JSRE.b)
    private static let reBare24 = JSRegex(
        JSRE.b + "(" + JSRE.d + "{1,2}):(" + JSRE.d + "{2})" + JSRE.b)

    /// "4pm", "4.30pm", "9:15 am", "16:00", noon and midnight — and
    /// nothing else. A bare 24-hour time needs its colon, so "1 5
    /// things" and "RM9.30" cannot become times.
    static func parseClock(_ line: String) -> String? {
        // app.js lower-cases the line and runs plain regexes over it,
        // so this is `toLowerCase()` and not the ASCII fold.
        let t = line.lowercased()

        if reNoon.test(t) { return "12:00" }
        if reMidnight.test(t) { return "00:00" }

        if let m = reAmPm.firstMatch(in: t) {
            var h = (Int(m[1] ?? "") ?? 0) % 12
            if m[3] == "pm" { h += 12 }
            let mins = Int(m[2] ?? "0") ?? 0
            return WebDates.pad2(h) + ":" + WebDates.pad2(mins)
        }

        if let m = reBare24.firstMatch(in: t),
           let h = Int(m[1] ?? ""), let mins = Int(m[2] ?? ""),
           h <= 23, mins <= 59 {
            return WebDates.pad2(h) + ":" + WebDates.pad2(mins)
        }
        return nil
    }

    // MARK: - parseDay (app.js:758-838)

    private static let reToday = JSRegex(
        [JSRE.b + "today" + JSRE.b,
         JSRE.b + "tonight" + JSRE.b,
         JSRE.b + "this evening" + JSRE.b,
         JSRE.b + "this morning" + JSRE.b,
         JSRE.b + "this afternoon" + JSRE.b].joined(separator: "|"))

    private static let reDayAfter = JSRegex(JSRE.b + "day after tomorrow" + JSRE.b)

    private static let reTomorrow = JSRegex(
        [JSRE.b + "tomorrow" + JSRE.b,
         JSRE.b + "tmr" + JSRE.b,
         JSRE.b + "tmrw" + JSRE.b].joined(separator: "|"))

    private static let reInDays = JSRegex(
        JSRE.b + "in" + JSRE.s + "+(" + JSRE.d + "{1,3})" + JSRE.s + "+days?" + JSRE.b)

    private static let reInWeek = JSRegex(
        JSRE.b + "in" + JSRE.s + "+a" + JSRE.s + "+week" + JSRE.b
        + "|" + JSRE.b + "next" + JSRE.s + "+week" + JSRE.b)

    private static let reWeekday = JSRegex(
        JSRE.b + "(next" + JSRE.s + "+)?(sun|mon|tues?|wed(?:nes)?|thur?s?|fri|sat(?:ur)?)(?:day)?" + JSRE.b)

    private static let reDayMonth = JSRegex(
        JSRE.b + "(" + JSRE.d + "{1,2})(?:st|nd|rd|th)?" + JSRE.s + "+(?:of" + JSRE.s + "+)?("
        + monthRE + ")" + JSRE.b)

    private static let reMonthDay = JSRegex(
        JSRE.b + "(" + monthRE + ")" + JSRE.s + "+(" + JSRE.d + "{1,2})(?:st|nd|rd|th)?" + JSRE.b)

    private static let weekdayKeys = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// The day a line names, or nil. Every named day beats the bare
    /// clock-time rule at the bottom, so "Friday 9am" is still Friday.
    static func parseDay(_ line: String, now: Date = Date()) -> String? {
        let t = line.lowercased()
        let cal = WebDates.calendar
        let midnight = cal.dateComponents([.year, .month, .day], from: now)
        guard let today = cal.date(from: midnight) else { return nil }

        if reToday.test(t) { return WebDates.dayKey(today) }
        if reDayAfter.test(t) { return WebDates.dayKey(WebDates.addDays(today, 2)) }
        if reTomorrow.test(t) { return WebDates.dayKey(WebDates.addDays(today, 1)) }

        if let m = reInDays.firstMatch(in: t), let n = Int(m[1] ?? "") {
            return WebDates.dayKey(WebDates.addDays(today, n))
        }
        if reInWeek.test(t) { return WebDates.dayKey(WebDates.addDays(today, 7)) }

        // A weekday name: the next one, or the one after that when
        // "next" leads it.
        if let m = reWeekday.firstMatch(in: t), let raw = m[2] {
            let head = String(raw.prefix(3))
                .replacingFirst("tues", with: "tue")
                .replacingFirst("thur", with: "thu")
            if let want = weekdayKeys.firstIndex(of: head) {
                // getDay() is 0 for Sunday; Foundation's weekday is 1.
                let dow = cal.component(.weekday, from: today) - 1
                var step = (want - dow + 7) % 7
                if step == 0 { step = 7 }   // "Friday" said on a Friday means the next one
                if m[1] != nil { step += (step <= 6 ? 7 : 0) }
                return WebDates.dayKey(WebDates.addDays(today, step))
            }
        }

        // "9 March" / "March 9" / "9th of March"
        let m = reDayMonth.firstMatch(in: t) ?? reMonthDay.firstMatch(in: t)
        if let m, let g1 = m[1], let g2 = m[2] {
            let numFirst = g1.unicodeScalars.first.map { $0.value >= 48 && $0.value <= 57 } ?? false
            let dayText = numFirst ? g1 : g2
            let monText = String((numFirst ? g2 : g1).prefix(3))
            if let day = Int(dayText), day >= 1, day <= 31, let mon = monthIndex[monText] {
                let year = cal.component(.year, from: today)
                if let key = calendarDay(year: year, monthIndex: mon, day: day, cal: cal) {
                    if key.date < today {
                        if let next = calendarDay(year: year + 1, monthIndex: mon, day: day, cal: cal),
                           next.month == mon {
                            return WebDates.dayKey(next.date)
                        }
                    } else if key.month == mon {
                        return WebDates.dayKey(key.date)
                    }
                }
            }
        }

        /* A clock time and no day named at all. "dentist 3pm" is not
           someday — the time IS the timing. The next one, not today's:
           "8am" written at five in the afternoon means tomorrow
           morning, and dating it to this morning would hand somebody a
           task that arrives already late.

           Deliberately last. */
        if let clock = parseClock(line) {
            let parts = clock.split(separator: ":")
            let h = Int(parts[0]) ?? 0
            let mi = Int(parts[1]) ?? 0
            var c = cal.dateComponents([.year, .month, .day], from: today)
            c.hour = h; c.minute = mi; c.second = 0; c.nanosecond = 0
            let at = cal.date(from: c) ?? today
            return WebDates.dayKey(at > now ? today : WebDates.addDays(today, 1))
        }

        return nil
    }

    /// `new Date(year, monthIndex, day)` — including its roll-over, so
    /// that "31 February" can be rejected the way app.js rejects it
    /// (by asking the result what month it landed in).
    ///
    /// Written as "the first of the month, plus day - 1 days" because
    /// that is literally what ECMA-262's MakeDay does, and because
    /// `Calendar.date(from:)` is free to clamp an out-of-range day to
    /// the end of the month instead of rolling it into the next one.
    /// Clamping would turn "31 February" into 28 February and hand
    /// back a date app.js refuses.
    private static func calendarDay(year: Int, monthIndex: Int, day: Int, cal: Calendar)
        -> (date: Date, month: Int)?
    {
        var c = DateComponents()
        c.year = year
        c.month = monthIndex + 1
        c.day = 1
        guard let first = cal.date(from: c),
              let d = cal.date(byAdding: .day, value: day - 1, to: first)
        else { return nil }
        return (d, cal.component(.month, from: d) - 1)
    }

    // MARK: - parseMinutes (app.js:847-873)

    /// app.js:841-844.
    static let wordNum: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "half": 0.5, "couple": 2, "few": 3,
    ]

    private static let reHalfHour = JSRegex(
        JSRE.b + "half an hour" + JSRE.b + "|" + JSRE.b + "half hour" + JSRE.b)
    private static let reAllDay = JSRegex(JSRE.b + "all day" + JSRE.b)
    private static let reAllPart = JSRegex(
        JSRE.b + "all morning" + JSRE.b + "|" + JSRE.b + "all afternoon" + JSRE.b)
    private static let reMinutes = JSRegex(
        "(" + JSRE.d + "+)" + JSRE.s + "*(?:min(?:ute)?s?|m)" + JSRE.b)
    private static let reHours = JSRegex(
        "(" + JSRE.d + "+(?:\\." + JSRE.d + "+)?|a|an|one|two|three|four|five|six|couple|few|half)"
        + JSRE.s + "*(?:of" + JSRE.s + "+)?(?:hour|hr)s?" + JSRE.b)
    private static let reHCompact = JSRegex(
        "(" + JSRE.d + "+)" + JSRE.s + "*h(?:" + JSRE.s + "*(" + JSRE.d + "+))?" + JSRE.b)

    /// A real duration when the user wrote one, or nil.
    ///
    /// Note what is NOT here: the minute and hour patterns carry no
    /// leading word boundary, exactly as app.js writes them, so the
    /// "a" in "pizza hours" really does read as one hour in both. The
    /// boundary was never there and adding one would be a fix, not a
    /// port.
    static func parseMinutes(_ line: String) -> Double? {
        let t = line.lowercased()

        if reHalfHour.test(t) { return 30 }
        if reAllDay.test(t) { return 240 }
        if reAllPart.test(t) { return 180 }

        if let m = reMinutes.firstMatch(in: t), let n = Double(m[1] ?? "") { return n }

        if let m = reHours.firstMatch(in: t), let g = m[1] {
            let n = Double(g) ?? wordNum[g] ?? 0
            if n != 0 { return Normalize.jsRound(n * 60) }
        }

        if let m = reHCompact.firstMatch(in: t), let h = Double(m[1] ?? "") {
            let rest = m[2].flatMap { Double($0) } ?? 0
            return h * 60 + rest
        }

        return nil
    }

    // MARK: - guessCategory (app.js:876-886)

    /// `CATEGORY_HINTS`, in order — the first that matches wins, and
    /// the order is the file's order, not alphabetical.
    static let categoryHints: [(String, JSRegex)] = [
        ("money",  hint("bill|pay|paid|invoice|tax|insurance|bank|rent|mortgage|budget|refund|subscription|salary")),
        ("health", hint("dentist|doctor|gp|gym|workout|exercise|run|physio|therapy|prescription|medicine|appointment")),
        ("home",   hint("laundry|washing|dishes|clean|tidy|bin|hoover|vacuum|kitchen|bathroom|garden|fix|repair|bed")),
        ("social", hint("mum|mom|mother|dad|father|friend|birthday|party|dinner|lunch|visit|text back|catch up|wedding")),
        ("errand", hint("pick up|collect|parcel|post office|posting|shop|groceries|drop off|return|delivery|petrol|fuel")),
        ("work",   hint("client|report|meeting|deck|slide|presentation|standup|deploy|ticket|pr" + JSRE.b + "|code|email|boss|contract")),
        ("admin",  hint("renew|form|passport|licence|license|register|cancel|book|schedule|paperwork|apply|sign up")),
    ]

    private static func hint(_ body: String) -> JSRegex {
        JSRegex(JSRE.b + "(" + body + ")" + JSRE.b, folded: true)
    }

    static func guessCategory(_ line: String) -> String {
        for (name, re) in categoryHints where re.test(line) { return name }
        return "general"
    }

    // MARK: - QUALIFIER (app.js:900-901)

    /* Fragments that are qualifiers, not new tasks. "file the tax
       return, deadline is tomorrow" must stay one task, or the urgency
       ends up attached to a fragment with no action in it. Bare days
       belong here too: "pay rent, friday" used to come back as two
       things, the second of them a task called Friday that nobody
       wrote and nothing removes. */
    private static let reQualifier = JSRegex(
        "\\A(?:deadline|due|by" + JSRE.b + "|before|after|at" + JSRE.b + "|on" + JSRE.b
        + "|takes|taking|about|approx|around|roughly|asap|today|tonight|tomorrow|this"
        + JSRE.s + "|next" + JSRE.s
        + "|maybe|probably|ideally|urgent|i think|apparently|sometime|whenever|no rush"
        + "|morning|afternoon|evening"
        + "|(?:mon|tues?|wed(?:nes)?|thur?s?|fri|sat(?:ur)?|sun)(?:day)?" + JSRE.b
        + "|" + JSRE.d + ")",
        folded: true)

    static func isQualifier(_ fragment: String) -> Bool { reQualifier.test(fragment) }

    // MARK: - tidyTitle (app.js:910-915)

    /* Strip a trailing duration clause once it has been read into
       `minutes`. The connective goes with it: without that group the
       clause is peeled off its own preposition and the word is left
       hanging — "review doc in 2 hours" came back as "Review doc in". */
    private static let reTidyTitle = JSRegex(
        "[," + JSRE.sSet + "\u{2014}-]*" + JSRE.b
        + "(?:takes?|taking)?" + JSRE.s + "*"
        + "(?:in|for|over)?" + JSRE.s + "*"
        + "(?:about|approx(?:imately)?|around|roughly)?" + JSRE.s + "*"
        + "(?:" + JSRE.d + "+(?:\\." + JSRE.d + "+)?|a|an|one|two|three|four|five|six|couple|few|half)"
        + JSRE.s + "*(?:of" + JSRE.s + "+)?"
        + "(?:hours?|hrs?|min(?:ute)?s?|m|h)" + JSRE.b + "\\.?\\z",
        folded: true)

    private static let reTrailingPunct = JSRegex("[,;" + JSRE.sSet + "]+\\z")

    static func tidyTitle(_ line: String) -> String {
        JSText.trim(reTrailingPunct.removingFirstMatch(in: reTidyTitle.removingFirstMatch(in: line)))
    }

    // MARK: - TRAILING_WHEN and tidyWhen (app.js:924-943)

    /* Strip a trailing when-clause once it has been read into
       `when`/`at`. The stamp is already shown beside the task, so
       leaving it in the title too gives "Dinner with Sara tonight at
       7.30pm" sitting next to a 7.30pm column. Peeled in a loop
       because a clause can stack, and only ever from the end, so a
       date in the middle of a real sentence is left alone. */
    private static let reTrailingWhen = JSRegex(
        "[,;" + JSRE.sSet + "\u{2014}-]*" + JSRE.b
        + "(?:on|by|before|at|due|this|next)?" + JSRE.s + "*(?:"
        + "today|tonight|tomorrow|tmrw?|this (?:morning|afternoon|evening)|next week"
        + "|in " + JSRE.d + "{1,3} days?|"
        + "(?:next" + JSRE.s + "+)?(?:sun|mon|tues?|wed(?:nes)?|thur?s?|fri|sat(?:ur)?)(?:day)?|"
        + JSRE.d + "{1,2}(?:st|nd|rd|th)?" + JSRE.s + "+(?:of" + JSRE.s + "+)?(?:" + monthRE + ")|"
        + "(?:" + monthRE + ")" + JSRE.s + "+" + JSRE.d + "{1,2}(?:st|nd|rd|th)?|"
        + JSRE.d + "{1,2}(?:[:.]" + JSRE.d + "{2})?" + JSRE.s + "*(?:am|pm)|"
        + JSRE.d + "{1,2}:" + JSRE.d + "{2}|noon|midday|midnight"
        + ")\\.?\\z",
        folded: true)

    static func tidyWhen(_ line: String) -> String {
        var out = line
        for _ in 0..<4 {
            let next = JSText.trim(
                reTrailingPunct.removingFirstMatch(in: reTrailingWhen.removingFirstMatch(in: out)))
            if next == out || next.isEmpty { break }   // never strip a title down to nothing
            out = next
        }
        return out
    }

    // MARK: - splitDump (app.js:951-985)

    /* The 2- and 3-letter verbs a dumped line is allowed to start
       with. The comma rule counts letters to tell an item from a
       trailing clause, and on its own that test threw out the shortest
       instructions people give themselves — "buy milk, pay rent, get
       petrol" arrived as one task. */
    static let shortVerb = "do|go|buy|pay|get|ask|fix|see|put|run|cut|add|try|eat|use|dry|mow|bin|top|log|set|pop|tag"

    private static let reSplitOn = JSRegex(
        "\\n"
        + "|(?:," + JSRE.s + "+(?:and" + JSRE.s + "+then|and|then)" + JSRE.s + "+(?=" + JSRE.w + "))"
        + "|(?:," + JSRE.s + "(?=(?:" + JSRE.w + "{4,}|(?:" + shortVerb + ")" + JSRE.b + ")))"
        + "|(?:" + JSRE.s + "+\u{2022}" + JSRE.s + "+)"
        + "|(?:;" + JSRE.s + "*)")

    private static let reLeadingJunk = JSRegex(
        "\\A[" + JSRE.sSet + "\\-\u{2013}\u{2014}*\u{2022}0-9.)]+")

    /// The cap on one dump (app.js:984).
    static let maxItems = 25

    /// Where one thing ends and the next begins. Shared with the
    /// typing preview so the chips split the dump exactly the way the
    /// parser will — otherwise the chips would promise dates against
    /// lines that never end up being lines.
    static func splitDump(_ text: String) -> [String] {
        let pieces = reSplitOn.split(text)
            .map { JSText.trim(reLeadingJunk.removingFirstMatch(in: $0)) }
            .filter { $0.utf16.count > 2 }

        // Fold qualifier fragments back into the task they describe.
        var acc: [String] = []
        for frag in pieces {
            if !acc.isEmpty, isQualifier(frag) {
                acc[acc.count - 1] += ", " + frag
            } else {
                acc.append(frag)
            }
        }
        return Array(acc.prefix(maxItems))
    }

    // MARK: - parseLocally (app.js:987-1031)

    private static let reUrgentHigh = JSRegex(
        JSRE.b + "(today|tonight|asap|urgent|overdue|deadline|due|now|immediately|last chance|expires?)"
        + JSRE.b, folded: true)
    private static let reUrgentSoon = JSRegex(
        JSRE.b + "(tomorrow|this week|monday|tuesday|wednesday|thursday|friday|saturday|sunday|weekend|soon)"
        + JSRE.b, folded: true)
    private static let reQuick = JSRegex(
        JSRE.b + "(email|reply|text|call|book|order|pay|send|renew|confirm|cancel|rsvp)"
        + JSRE.b, folded: true)
    private static let reBig = JSRegex(
        JSRE.b + "(write|build|plan|report|design|research|clean|organi[sz]e|prepare|refactor|draft|deep)"
        + JSRE.b, folded: true)

    /* Things that cost something real if they never happen.
       Deliberately narrower than the model's own reading: money and
       health only, plus the words below. A heuristic that called half
       the list important would fill Do now with everything, and this
       parser already announces itself as a rough guess. */
    private static let reWeighty = JSRegex(
        JSRE.b + "(bill|rent|tax|insurance|fine|penalty|licen[cs]e|passport|visa|permit|loan|debt"
        + "|invoice|contract|doctor|dentist|hospital|clinic|medicine|prescription|exam|interview)"
        + JSRE.b, folded: true)

    private static let weightyCats: Set<String> = ["money", "health"]

    /// No-backend fallback: split by line, guess size and urgency from
    /// wording. Up to 25 tasks, every one of them `local: true`.
    static func parseLocally(_ text: String, now: Date = Date()) -> [TaskItem] {
        splitDump(text).map { line in
            let stated = parseMinutes(line)
            let day = parseDay(line, now: now)

            /* Both tidiers are anchored to the end of the string, so
               each can uncover a clause for the other: "takes 25 min,
               tomorrow" only offers up its duration once "tomorrow" is
               off. Alternate until neither one bites. */
            var clean = line
            for _ in 0..<3 {
                let before = clean
                if stated != nil {
                    let t = tidyTitle(clean)
                    clean = t.isEmpty ? clean : t
                }
                if day != nil {
                    let t = tidyWhen(clean)
                    clean = t.isEmpty ? clean : t
                }
                if clean == before { break }
            }
            if clean.isEmpty { clean = line }

            let cat = guessCategory(line)
            let isQuick = reQuick.test(line)
            let isBig = reBig.test(line)

            var f = JSONObject()
            f["title"] = .string(JSText.upperFirst(clean))
            f["minutes"] = .double(stated ?? (isQuick ? 10 : isBig ? 45 : 20))
            f["energy"] = .string(isBig ? "high" : isQuick ? "low" : "medium")
            f["urgency"] = .int(reUrgentHigh.test(line) ? 5 : reUrgentSoon.test(line) ? 4 : 3)
            f["importance"] = .string(
                (weightyCats.contains(cat) || reWeighty.test(line)) ? "high" : "low")
            f["firstStep"] = .string(firstStep)
            f["category"] = .string(cat)
            f["when"] = day.map { JSONValue.string($0) } ?? .null
            // A time with no day is a time on no calendar, so it is
            // dropped rather than parked on today and quietly wrong.
            f["at"] = (day != nil ? parseClock(line).map { JSONValue.string($0) } : nil) ?? .null
            f["local"] = .bool(true)

            return Normalize.task(.object(f), now: now)
        }
    }
}

// MARK: -

private extension String {
    /// `String.prototype.replace(literal, replacement)` — the first
    /// occurrence only, which is what app.js's two `.replace('tues',
    /// 'tue')` calls mean.
    func replacingFirst(_ needle: String, with replacement: String) -> String {
        guard let r = range(of: needle) else { return self }
        return replacingCharacters(in: r, with: replacement)
    }
}
