/* ============================================================
   my.adhd for iOS — normalizeTask and its helpers

   This is `normalizeTask` (app.js:1040-1069) and the four small
   functions it leans on, ported line for line.

   **It is for MODEL OUTPUT and for new tasks. It is never run on read.**
   `load()` does not call it, and neither does anything here: a stored
   row keeps exactly the keys it arrived with (see `TaskItem`). Running
   it over the store on launch would mint a fresh id for every task,
   which is how you lose a person's whole list in one boot.

   The JavaScript coercions are ported rather than approximated, because
   the model's answer is not typed: `t.minutes` arrives as `25`, as
   `"25"`, as `"about 25"` or as nothing at all, and `clamp` gives three
   different answers to those. `Math.round` is floor(x + 0.5), which
   rounds -2.5 to -2 and is not what `rounded()` does.
   ============================================================ */

import Foundation

public enum Normalize {

    /// app.js:1169-1174. The matrix's four cells, in order.
    public static let quadrantKeys = ["do", "plan", "delegate", "drop"]

    public static let energyValues = ["low", "medium", "high"]
    public static let importanceValues = ["low", "high"]

    /// The placeholder `normalizeTask` writes when the model gave no
    /// first step. Model output only — never a read default.
    public static let defaultFirstStep = "Open it and look at it for 2 minutes."

    // MARK: - ids

    private static let base36 = Array("0123456789abcdefghijklmnopqrstuvwxyz")

    /// `Math.random().toString(36).slice(2, 9)` — seven base-36 digits.
    /// The page occasionally produces fewer when the random draw has
    /// trailing zeros; every reader tolerates both, and seven is the
    /// shape they all expect.
    public static func randomSuffix(_ n: Int = 7) -> String {
        String((0..<n).map { _ in base36[Int.random(in: 0..<36)] })
    }

    public static func newTaskID() -> String { "t_" + randomSuffix() }
    public static func newNoteID() -> String { "n_" + randomSuffix() }
    public static func newFileID() -> String { "f_" + randomSuffix() }

    // MARK: - the JavaScript coercions

    /// `String.prototype.slice(0, n)`, which counts UTF-16 code units and
    /// not Characters. "🙂" is two units; every cap in this file is a
    /// UTF-16 cap. Where a cut would land inside a surrogate pair we take
    /// one unit less rather than mint the lone surrogate JS would — a
    /// Swift String cannot hold one.
    public static func slice(_ s: String, _ n: Int) -> String {
        let u = Array(s.utf16)
        guard u.count > n else { return s }
        var end = max(0, n)
        if end > 0, (0xD800...0xDBFF).contains(u[end - 1]) { end -= 1 }
        return String(decoding: u[0..<end], as: UTF16.self)
    }

    /// `String(v)`. A missing key is `undefined`.
    public static func jsString(_ v: JSONValue?) -> String {
        guard let v else { return "undefined" }
        switch v {
        case .null:          return "null"
        case .bool(let b):   return b ? "true" : "false"
        case .int(let i):    return WebJSON.number(i)
        case .double(let d):
            if d.isNaN { return "NaN" }
            if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
            return WebJSON.number(d)
        case .string(let s): return s
        case .array(let a):
            return a.map { $0.isNull ? "" : jsString($0) }.joined(separator: ",")
        case .object:        return "[object Object]"
        }
    }

    /// `Number(v)`. Returns NaN where JavaScript would.
    public static func jsNumber(_ v: JSONValue?) -> Double {
        guard let v else { return .nan }
        switch v {
        case .null:          return 0
        case .bool(let b):   return b ? 1 : 0
        case .int(let i):    return Double(i)
        case .double(let d): return d
        case .string(let s): return stringToNumber(s)
        case .array(let a):
            if a.isEmpty { return 0 }
            return stringToNumber(jsString(v))
        case .object:        return .nan
        }
    }

    /// ECMA-262 StringToNumber, to the extent this app can meet one.
    private static func stringToNumber(_ raw: String) -> Double {
        /* `JSText.trim`, not `.whitespacesAndNewlines`: Number() strips the
           same WhiteSpace + LineTerminator that trim() does, which keeps
           U+200B-U+200D (so "\u{200B}5" is NaN, not 5) and removes U+FEFF. */
        let s = JSText.trim(raw)
        if s.isEmpty { return 0 }
        if s == "Infinity" || s == "+Infinity" { return .infinity }
        if s == "-Infinity" { return -.infinity }
        let lower = s.lowercased()
        func radix(_ prefix: String, _ r: Int) -> Double? {
            guard lower.hasPrefix(prefix) else { return nil }
            let body = String(s.dropFirst(2))
            guard !body.isEmpty, let n = UInt64(body, radix: r) else { return .nan }
            return Double(n)
        }
        if let d = radix("0x", 16) { return d }
        if let d = radix("0o", 8)  { return d }
        if let d = radix("0b", 2)  { return d }
        /* Swift's Double(_:) accepts "inf", "nan" and hex floats, none of
           which JavaScript's Number() does. Require a plain decimal. */
        var seenDigit = false, seenDot = false, seenExp = false
        var i = s.startIndex
        if s[i] == "+" || s[i] == "-" { i = s.index(after: i) }
        while i < s.endIndex {
            let c = s[i]
            if c.isNumber && c.isASCII { seenDigit = true }
            else if c == "." && !seenDot && !seenExp { seenDot = true }
            else if (c == "e" || c == "E") && seenDigit && !seenExp {
                seenExp = true
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "+" || s[next] == "-" { i = next }
            } else { return .nan }
            i = s.index(after: i)
        }
        guard seenDigit else { return .nan }
        return Double(s) ?? .nan
    }

    /// `Math.round(x)` — floor(x + 0.5). Not `rounded()`: JS sends -2.5
    /// to -2, `rounded(.toNearestOrAwayFromZero)` sends it to -3.
    public static func jsRound(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        return (x + 0.5).rounded(.down)
    }

    /// app.js:1041-1044. `Number(n)` finite ? min(hi, max(lo, round(v))) : d
    public static func clamp(_ v: JSONValue?, _ lo: Int, _ hi: Int, _ fallback: Int) -> Int {
        let n = jsNumber(v)
        guard n.isFinite else { return fallback }
        let r = jsRound(n)
        return Int(Swift.min(Double(hi), Swift.max(Double(lo), r)))
    }

    public static func clamp(_ v: Double, _ lo: Int, _ hi: Int, _ fallback: Int) -> Int {
        clamp(.double(v), lo, hi, fallback)
    }

    // MARK: - days and clock times

    /// app.js:691-695. A real date on a real calendar day: rejects
    /// "2026-02-31", the wrong shape, and anything that does not come
    /// back out of `new Date(y, m-1, d)` as the same key.
    ///
    /// Years below 100 answer nil, as the page does: `new Date(26, 0, 1)`
    /// is 1926 in JavaScript, so "0026-01-01" can never round-trip.
    public static func normalizeDay(_ v: JSONValue?) -> String? {
        guard let s = v?.stringValue else { return nil }
        return normalizeDay(s)
    }

    public static func normalizeDay(_ s: String?) -> String? {
        guard let s, s.utf16.count == 10 else { return nil }
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        if y < 100 { return nil }
        guard m >= 1, m <= 12, d >= 1 else { return nil }
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        guard let date = DayKey.calendar.date(from: c), DayKey.of(date) == s else { return nil }
        return s
    }

    /// app.js:697-703. "9:5" is not a time; "9:05" is, and comes back
    /// padded as "09:05".
    public static func normalizeTime(_ v: JSONValue?) -> String? {
        guard let s = v?.stringValue else { return nil }
        return normalizeTime(s)
    }

    public static func normalizeTime(_ s: String?) -> String? {
        guard let s else { return nil }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let h = Int(parts[0]), let m = Int(parts[1]),
              h <= 23, m <= 59
        else { return nil }
        return String(format: "%02d:%02d", h, m)
    }

    /// app.js:674-680. A clock time with no day gets the NEXT occurrence
    /// of that time — "8am" written at five in the afternoon means
    /// tomorrow morning, because dating it to this morning hands somebody
    /// a task that arrives already late.
    public static func dayForTime(_ at: String?, now: Date = Date()) -> String? {
        guard let mins = DayKey.minutes(at) else { return nil }
        let cal = DayKey.calendar
        var c = cal.dateComponents([.year, .month, .day], from: now)
        c.hour = mins / 60
        c.minute = mins % 60
        c.second = 0
        c.nanosecond = 0
        let todayKey = DayKey.of(now, cal)
        guard let when = cal.date(from: c) else { return todayKey }
        return when > now ? todayKey : DayKey.adding(1, to: todayKey, cal)
    }

    /// app.js:1036-1038. `when` and `at` settled together, because that
    /// is what they are: `at` without `when` is not "sometime", it is a
    /// time nobody wrote the day of.
    public static func timing(_ when: String?, _ at: String?, now: Date = Date())
        -> (when: String?, at: String?)
    {
        (when ?? dayForTime(at, now: now), at)
    }

    // MARK: - normalizeTask

    /// app.js:1040-1069, for one item of the model's answer. Always mints
    /// a fresh id — `normalizeTask` ignores whatever came in.
    public static func task(_ t: JSONValue,
                            now: Date = Date(),
                            id: String? = nil) -> TaskItem
    {
        let title = slice(jsString(t["title"].orFallback(.string("Untitled"))), 160)
        let energyRaw = t["energy"]?.stringValue
        let importanceRaw = t["importance"]?.stringValue
        let quadrantRaw = t["quadrant"]?.stringValue

        let step = t["firstStep"].orFallback(t["first_step"])
            .orFallback(.string(defaultFirstStep))

        let pair = timing(normalizeDay(t["when"]), normalizeTime(t["at"]), now: now)

        var f = JSONObject()
        f["id"] = .string(id ?? newTaskID())
        f["title"] = .string(title)
        f["minutes"] = .int(clamp(t["minutes"], 2, 240, 20))
        f["energy"] = .string(energyValues.contains(energyRaw ?? "") ? energyRaw! : "medium")
        f["urgency"] = .int(clamp(t["urgency"], 1, 5, 3))
        f["importance"] = .string(importanceValues.contains(importanceRaw ?? "") ? importanceRaw! : "low")
        f["quadrant"] = quadrantKeys.contains(quadrantRaw ?? "") ? .string(quadrantRaw!) : .null
        f["firstStep"] = .string(slice(jsString(step), 240))
        f["category"] = .string(slice(jsString(t["category"].orFallback(.string("general"))), 40))
        f["when"] = pair.when.map { .string($0) } ?? .null
        f["at"] = pair.at.map { .string($0) } ?? .null
        if let steps = t["steps"]?.arrayValue {
            f["steps"] = .array(steps.prefix(7).map { .string(jsString($0)) })
        } else {
            f["steps"] = .null
        }
        f["local"] = .bool(t["local"]?.boolValue == true)
        f["gcal"] = .null
        f["done"] = .bool(false)
        f["doneAt"] = .null
        f["skipped"] = .bool(false)
        return TaskItem(fields: f)
    }
}

public extension Optional where Wrapped == JSONValue {

    /// `a || b` in JavaScript: keep the left side only when it is truthy.
    func orFallback(_ other: JSONValue?) -> JSONValue? {
        if let self, self.isTruthy { return self }
        return other
    }

    /// `v.key` where `v` may be missing or may not be an object — which
    /// in JavaScript is `undefined`, not a crash.
    subscript(key: String) -> JSONValue? {
        guard case .some(.object(let o)) = self else { return nil }
        return o[key]
    }
}
