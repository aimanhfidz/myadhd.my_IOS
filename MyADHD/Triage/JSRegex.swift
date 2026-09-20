/* ============================================================
   JSRegex — JavaScript regular-expression semantics on ICU

   The offline parser is regexes almost all the way down, and the two
   engines do NOT agree. `NSRegularExpression` is ICU; the web app is
   JavaScript with no `u` flag. Four differences matter here, and every
   one of them changes what a real dump parses to:

   1. **`\b`.** JavaScript's word character is ASCII: `[0-9A-Za-z_]`.
      ICU's is Unicode — a letter, a mark, a decimal digit or a
      connector. So `/\bpay\b/` matches the `pay` in `cafepay` in
      neither engine, but it matches the `pay` in `cafe\u{301}pay`
      (combining acute) in JavaScript and not in ICU, because ICU calls
      the combining mark a word character and sees no boundary. Malay
      and code-switched dumps carry plenty of non-ASCII letters, so
      this is not theoretical. `JSRE.b` below is the exact
      ASCII-worded boundary, written out as the pair of lookarounds it
      is defined to be.

   2. **`\d`.** ICU's `\d` is `\p{Nd}`, which includes Arabic-Indic and
      Devanagari digits; JavaScript's is `[0-9]`. A dump written with
      Arabic-Indic numerals would get a duration out of ICU and none
      out of the browser. `JSRE.d` is `[0-9]`.

   3. **`\s`.** JavaScript's white space includes U+FEFF and excludes
      U+0085; ICU's does the reverse. `JSRE.sSet` spells out
      JavaScript's set, code point by code point, and is used inside
      character classes as well as on its own.

   4. **The `i` flag.** JavaScript without `u` canonicalises by
      `toUpperCase` and then throws the result away when it turned a
      non-ASCII character into an ASCII one — which is what stops
      U+017F (long s) matching `s` and U+212A (Kelvin sign) matching
      `k`. ICU case-insensitive matching uses full case folding and
      matches both. So nothing here is compiled `.caseInsensitive`:
      a `/i` regex is written in lower case and run against
      `JSText.asciiLowered(subject)`, which maps only A-Z to a-z and
      therefore cannot change a single UTF-16 offset. Offsets found in
      the folded copy address the original string exactly.

   Two more small ones, handled at the point of use:

   - `$` in ICU also matches before a final line terminator, the way
     Java's does; JavaScript's matches only at the very end. Every
     end-anchor in this port is written `\z`.
   - `^` is written `\A` for the same reason.

   Nothing in this file is my.adhd-specific. It is the translation
   layer, and `LocalTriage` reads like the JavaScript because of it.
   ============================================================ */

import Foundation

// MARK: - Pattern fragments

/// The pieces a JavaScript pattern is rebuilt from.
enum JSRE {

    /// JavaScript's `\b`, written out. A position is a word boundary
    /// when exactly one side of it is an ASCII word character — which
    /// is the two lookaround pairs below, and is true at the ends of
    /// the string because a lookbehind that runs off the front fails.
    static let b = #"(?:(?<=[0-9A-Za-z_])(?![0-9A-Za-z_])|(?<![0-9A-Za-z_])(?=[0-9A-Za-z_]))"#

    /// JavaScript's `\d`.
    static let d = "[0-9]"

    /// JavaScript's `\w`.
    static let w = "[0-9A-Za-z_]"

    /// JavaScript's `\s`, as the inside of a character class so it can
    /// be spliced into one. WhiteSpace plus LineTerminator, per the
    /// spec: tab, LF, VT, FF, CR, space, NBSP, Ogham space mark, the
    /// U+2000-U+200A run, LS, PS, narrow NBSP, medium mathematical
    /// space, ideographic space and the byte-order mark.
    static let sSet = #"\t\n\x{000B}\f\r \x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}"#

    /// JavaScript's `\s`.
    static let s = "[" + sSet + "]"
}

// MARK: - The regex itself

/// One match, with its capture groups as JavaScript hands them over:
/// `groups[0]` is the whole match and an unparticipating group is nil.
struct JSMatch {
    let range: NSRange
    let groups: [String?]

    subscript(i: Int) -> String? { i < groups.count ? groups[i] : nil }
}

/// A compiled JavaScript regular expression.
///
/// `folded` is the `i` flag: the subject is run through
/// `JSText.asciiLowered` before matching, and because that is a
/// unit-for-unit map the ranges that come back still address the
/// string that was passed in.
struct JSRegex {

    private let re: NSRegularExpression
    private let folded: Bool

    /// Compiles or traps. Every pattern in this app is a literal, so a
    /// bad one is a programming error and not a runtime condition —
    /// exactly as an invalid regex literal is in JavaScript.
    init(_ pattern: String, folded: Bool = false) {
        do {
            self.re = try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            preconditionFailure("JSRegex could not compile /\(pattern)/: \(error)")
        }
        self.folded = folded
    }

    private func subject(_ s: String) -> String {
        folded ? JSText.asciiLowered(s) : s
    }

    /// `re.test(s)`.
    func test(_ s: String) -> Bool {
        let hay = subject(s)
        let ns = hay as NSString
        return re.firstMatch(in: hay, options: [], range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// `s.match(re)` for a regex with no `g` flag.
    func firstMatch(in s: String) -> JSMatch? {
        let hay = subject(s)
        let source = s as NSString
        let ns = hay as NSString
        guard let m = re.firstMatch(in: hay, options: [], range: NSRange(location: 0, length: ns.length))
        else { return nil }
        var groups: [String?] = []
        groups.reserveCapacity(m.numberOfRanges)
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? nil : source.substring(with: r))
        }
        return JSMatch(range: m.range, groups: groups)
    }

    /// `s.replace(re, '')` for a regex with no `g` flag: the FIRST
    /// match only, cut out of the original (not the folded) string.
    func removingFirstMatch(in s: String) -> String {
        guard let m = firstMatch(in: s) else { return s }
        let ns = s as NSString
        return ns.replacingCharacters(in: m.range, with: "")
    }

    /// `s.split(re)`.
    ///
    /// Every pattern this is used with is capture-group free, which is
    /// what lets the result be the pieces alone: JavaScript's `split`
    /// interleaves the captures of a capturing separator into the
    /// output, and none of ours has one. Matches are leftmost and
    /// non-overlapping, a separator at either end yields the empty
    /// string beside it, and a subject with no match comes back whole.
    func split(_ s: String) -> [String] {
        let hay = subject(s)
        let source = s as NSString
        let ns = hay as NSString
        let all = re.matches(in: hay, options: [], range: NSRange(location: 0, length: ns.length))
        guard !all.isEmpty else { return [s] }
        var out: [String] = []
        var cursor = 0
        for m in all {
            // A zero-width match cannot advance the cursor; JavaScript
            // skips it rather than splitting on nothing. None of our
            // separators is zero-width, but the guard is free.
            if m.range.length == 0 { continue }
            out.append(source.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            cursor = m.range.location + m.range.length
        }
        out.append(source.substring(from: cursor))
        return out
    }
}
