/* ============================================================
   Preview — the typing date chips, and the names the mic is told

   Two small readers that live beside the offline parser because they
   share its regexes:

   - `DatePreview` is `previewDates()` (app.js:5008-5058), the strip
     under the composer that shows what the app has spotted a day in
     while the dump is still being written. It runs the offline date
     reader, not the model — that is the point: it is instant and
     costs nothing, so it can run on every keystroke. It splits with
     `LocalTriage.splitDump` and dates with `LocalTriage.parseDay`, so
     the chips and the offline sort cannot disagree.

     Only days appear. A line the reader finds nothing in stays silent
     rather than getting a chip saying so — the strip is there to
     confirm a date landed, not to nag about the ones that did not.

   - `KnownNames` is `knownNames()` (app.js:5308-5322), the vocabulary
     the transcriber is handed: capitalised runs out of the titles the
     person has kept, never the first word of a title (those are
     verbs, because every title starts with one), capped at 40.

   This file draws nothing. It returns the strings; the composer view
   decides what to do with them.
   ============================================================ */

import Foundation

// MARK: - previewDates

/// One row of the preview: a day, and the time on it when there was one.
struct PreviewDate: Equatable {
    var when: String
    var at: String?
}

enum DatePreview {

    /// app.js:5018.
    static let max = 4

    /// app.js:5022. Cheap on any realistic dump, but the reader runs a
    /// fistful of regexes per line and this fires on every keystroke,
    /// so the input is capped — in UTF-16 units, as `String.slice` is.
    static let inputCap = 4000

    /// Every distinct day-and-time the dump names, in the order the
    /// chips are drawn.
    ///
    /// Deduped on `when|at` (first one wins, which is what a JavaScript
    /// `Map` does), then sorted by day and then by time, with a
    /// timeless entry sorting after every timed one on the same day
    /// because app.js compares against the sentinel "99:99".
    static func dates(in text: String, now: Date = Date()) -> [PreviewDate] {
        let capped = Normalize.slice(text, inputCap)
        var order: [String] = []
        var seen: [String: PreviewDate] = [:]

        if JSText.trim(capped).utf16.count > 2 {
            for line in LocalTriage.splitDump(capped) {
                guard let when = LocalTriage.parseDay(line, now: now) else { continue }
                let at = LocalTriage.parseClock(line)
                let key = when + "|" + (at ?? "")
                if seen[key] == nil {
                    seen[key] = PreviewDate(when: when, at: at)
                    order.append(key)
                }
            }
        }

        let found = order.compactMap { seen[$0] }

        // `Array.prototype.sort` is stable, so equal keys keep the
        // order the Map handed over; `sorted(by:)` is not, hence the
        // index tiebreak.
        return found.enumerated().sorted { a, b in
            if a.element.when != b.element.when {
                return lessThan(a.element.when, b.element.when)
            }
            let ta = a.element.at ?? "99:99"
            let tb = b.element.at ?? "99:99"
            if ta != tb { return lessThan(ta, tb) }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The chips as drawn: up to `max` stamps, plus the overflow
    /// legend when there were more.
    ///
    /// Each chip is `whenLabel({when, at})` — app.js passes the pair
    /// itself to `whenLabel`, so a chip reads "Tomorrow · 4pm" or just
    /// "Tomorrow". `when` is never nil here, so the label never is.
    static func chips(in text: String,
                      now: Date = Date(),
                      today: String = WebDates.dayKey()) -> (chips: [String], more: String?)
    {
        let found = dates(in: text, now: now)
        let shown = found.prefix(max).compactMap {
            WebDates.whenLabel(when: $0.when, at: $0.at, today: today)
        }
        let more = found.count > max ? Copy.Composer.moreChips(found.count - max) : nil
        return (Array(shown), more)
    }

    /// `a.localeCompare(b) < 0`, which is what app.js:5036-5037 calls.
    ///
    /// `Ordering.localeCompare` is the one collation in the port. A
    /// code-unit comparison agrees with it on the zero-padded
    /// "YYYY-MM-DD" and "HH:MM" that `parseDay` and `parseClock`
    /// produce, but not on the `'99:99'` fallback beside an unpadded
    /// time, and the web's answer there is the collation's.
    private static func lessThan(_ a: String, _ b: String) -> Bool {
        Ordering.localeCompare(a, b) < 0
    }
}

// MARK: - knownNames

enum KnownNames {

    /// app.js:5321-5322. Both the early exit and the final slice.
    static let cap = 40

    /// The names this person already uses. A transcriber that has seen
    /// how they spell their own road, their landlord or their clinic
    /// will pick that over whatever the sound rhymed with.
    ///
    /// Capitalised runs only, and never the first word of a title —
    /// those are verbs. A word counts as proper when its first scalar
    /// is General_Category Lu (not merely "uppercase", which would
    /// take in title-case letters and the Other_Uppercase circled
    /// letters that `\p{Lu}` does not) and it is longer than two
    /// UTF-16 units.
    static func from(titles: [String]) -> [String] {
        var order: [String] = []
        var seen: Set<String> = []

        for title in titles {
            var run: [String] = []
            let words = split(title)
            for (i, w) in words.enumerated() {
                let proper = i > 0 && startsUppercase(w) && w.utf16.count > 2
                if proper { run.append(w); continue }
                if !run.isEmpty {
                    let name = run.joined(separator: " ")
                    if seen.insert(name).inserted { order.append(name) }
                    run = []
                }
            }
            if !run.isEmpty {
                let name = run.joined(separator: " ")
                if seen.insert(name).inserted { order.append(name) }
            }
            if seen.count >= cap { break }
        }
        return Array(order.prefix(cap))
    }

    static func from(tasks: [TaskItem]) -> [String] {
        from(titles: tasks.map(\.title))
    }

    /// `split(/[^\p{L}\p{N}'\u{2019}-]+/u).filter(Boolean)`, done on
    /// scalars so the character properties are the same ones ICU and
    /// JavaScript both read off the Unicode tables.
    private static func split(_ s: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if isWordScalar(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                out.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    private static func isWordScalar(_ u: Unicode.Scalar) -> Bool {
        if u == "'" || u == "\u{2019}" || u == "-" { return true }
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter,           // \p{L}
             .decimalNumber, .letterNumber, .otherNumber:   // \p{N}
            return true
        default:
            return false
        }
    }

    private static func startsUppercase(_ w: String) -> Bool {
        guard let first = w.unicodeScalars.first else { return false }
        return first.properties.generalCategory == .uppercaseLetter
    }
}
