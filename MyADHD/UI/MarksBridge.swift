/* ============================================================
   MyADHD/UI/MarksBridge.swift — marks ↔ attributed runs, and the two
   edits that move marks between blocks

   `paintBlockText` (app.js:4472-4498), `readBlockText` (4508-4547),
   `mergeMarks` (4551-4562) and `blockKey` (4672-4722), ported.

   **Everything in this file counts UTF-16 code units and nothing in it
   counts Characters.** A `NoteMark` holds the offsets `String.prototype`
   handed the contenteditable, an `NSRange` over an `NSAttributedString`
   is the same unit, and the two map onto each other without arithmetic.
   `"🙂"` is two of those units and one Swift `Character`; measuring a
   mark with `String.count` moves every run after the first emoji by one
   and there is no test on the web side that would ever say so — the note
   just comes back with the bold in the wrong place.

   So: no `String.count`, no `String.Index`, no `Character` anywhere
   below. `text.utf16.count`, `NSRange`, and `Array(text.utf16)` are the
   only three ways length is asked for.

   **Why this compiles on the Mac too.** `Checks/notes.sh` builds this
   file with `swiftc` on macOS and holds it against the real `app.js` in
   JavaScriptCore. There is no iOS simulator in that loop and no SwiftUI:
   the conversion has to be reachable from a command-line binary or the
   one piece of the port most likely to be silently wrong is the one
   piece with no check on it. Hence the `canImport(UIKit)` typealiases
   and the absence of any `import SwiftUI` here.

   **What an attributed run carries.** Three things at once, and
   deliberately:

   - the visible attributes — the font from the face, `.underlineStyle`,
     `.strikethroughStyle` — which are what the text view draws;
   - `flagsKey`, the four booleans as a bitmask, which is what `read`
     believes;
   - the block's own base style underneath all of it, which is NOT a mark
     and must never come back as one. A ticked-off checkbox line is
     struck through by its type (`.nb-text.is-done`, styles.css:649), and
     a port that read its own strike back out would write `strike: true`
     over every character of the line on the first keystroke.

   `flagsKey` exists because of that last one and because of the heading:
   `.nb--h .nb-text` is already 700, so "is this run bold" cannot be
   answered by looking at the weight. Text that arrives with no flags key
   at all — pasted from another app — is read the way the web reads
   foreign markup: from what it looks like, minus whatever the base
   already was.
   ============================================================ */

import Foundation

#if canImport(UIKit)
import UIKit
typealias NoteUIFont = UIFont
typealias NoteUIColor = UIColor
#else
import AppKit
typealias NoteUIFont = NSFont
typealias NoteUIColor = NSColor
#endif

// MARK: - the conversion

enum MarksBridge {

    /// The four booleans of a `NoteMark`, as a set.
    struct Flags: OptionSet, Hashable {
        let rawValue: Int
        static let b = Flags(rawValue: 1 << 0)
        static let i = Flags(rawValue: 1 << 1)
        static let u = Flags(rawValue: 1 << 2)
        static let strike = Flags(rawValue: 1 << 3)
    }

    /// The mark flags of one run, kept beside the visible attributes.
    /// Not storage — the store only ever holds text and marks — but the
    /// one attribute `read` trusts, for the reasons in the header.
    static let flagsKey = NSAttributedString.Key("myadhd.noteMarkFlags")

    /// The four fonts one block can draw with. Held as four rather than
    /// derived from one, because a heading's base weight is already 700
    /// and "add bold to it" has no answer.
    struct Face {
        var regular: NoteUIFont
        var bold: NoteUIFont
        var italic: NoteUIFont
        var boldItalic: NoteUIFont

        func font(_ flags: Flags) -> NoteUIFont {
            switch (flags.contains(.b), flags.contains(.i)) {
            case (true, true):   return boldItalic
            case (true, false):  return bold
            case (false, true):  return italic
            case (false, false): return regular
            }
        }
    }

    // MARK: flags

    static func flags(of m: NoteMark) -> Flags {
        var f = Flags()
        if m.b { f.insert(.b) }
        if m.i { f.insert(.i) }
        if m.u { f.insert(.u) }
        if m.strike { f.insert(.strike) }
        return f
    }

    static func mark(_ s: Int, _ e: Int, _ f: Flags) -> NoteMark {
        NoteMark(s: s, e: e,
                 b: f.contains(.b), i: f.contains(.i),
                 u: f.contains(.u), strike: f.contains(.strike))
    }

    // MARK: the flatten

    /// `paintBlockText`'s cut-and-flatten, as an array: one `Flags` per
    /// UTF-16 code unit of `text`.
    ///
    /// app.js cuts the text at every mark boundary and then asks, of each
    /// segment, which marks cover the whole of it (`m.s <= s && m.e >= e`).
    /// Because the cut points include every boundary, a segment is either
    /// wholly inside a mark or wholly outside it, so that test is the
    /// same question as "which marks cover this code unit" — which is
    /// what this answers, one unit at a time.
    static func perUnit(text: String, marks: [NoteMark]) -> [Flags] {
        let n = text.utf16.count
        guard n > 0 else { return [] }
        var out = [Flags](repeating: [], count: n)
        for m in marks {
            let s = max(0, min(n, m.s))
            let e = max(0, min(n, m.e))
            guard e > s else { continue }
            let f = flags(of: m)
            guard !f.isEmpty else { continue }
            for j in s..<e { out[j].formUnion(f) }
        }
        return out
    }

    /// The same marks, flattened and fused: no two overlap, no two
    /// adjacent ones wear the same flags, and none is empty.
    ///
    /// This is what a round trip through the editor returns, so it is the
    /// fixed point the check asserts rather than the input marks — a note
    /// stored with `[(0,5,b), (2,8,i)]` comes back as three runs because
    /// that is what the page makes of it too.
    static func canonical(text: String, marks: [NoteMark]) -> [NoteMark] {
        let units = perUnit(text: text, marks: marks)
        var out: [NoteMark] = []
        var at = 0
        while at < units.count {
            var to = at + 1
            while to < units.count, units[to] == units[at] { to += 1 }
            if !units[at].isEmpty { out.append(mark(at, to, units[at])) }
            at = to
        }
        return out
    }

    /// `mergeMarks` (app.js:4551-4562). Adjacent runs wearing the same
    /// flags are one mark. Walks the array in the order it is given and
    /// only ever fuses a run onto the one before it — it is not a sort,
    /// and a list that is out of order comes back out of order.
    static func mergeMarks(_ marks: [NoteMark]) -> [NoteMark] {
        var out: [NoteMark] = []
        for m in marks {
            if var last = out.last,
               last.e == m.s,
               last.b == m.b, last.i == m.i, last.u == m.u, last.strike == m.strike
            {
                last.e = m.e
                out[out.count - 1] = last
                continue
            }
            out.append(m)
        }
        return out
    }

    // MARK: marks → attributed

    /// One block's text, dressed.
    ///
    /// - `base`: the flags the block's own type already carries — `.strike`
    ///   for a ticked-off checkbox line and nothing else today. Drawn, but
    ///   never written back as a mark.
    static func attributed(text: String,
                           marks: [NoteMark],
                           face: Face,
                           ink: NoteUIColor,
                           base: Flags = [],
                           paragraph: NSParagraphStyle? = nil) -> NSMutableAttributedString
    {
        let out = NSMutableAttributedString(string: text)
        let whole = NSRange(location: 0, length: out.length)
        guard whole.length > 0 else { return out }

        out.addAttributes(baseAttributes(face: face, ink: ink, base: base,
                                         paragraph: paragraph), range: whole)

        let units = perUnit(text: text, marks: marks)
        var at = 0
        while at < units.count {
            var to = at + 1
            while to < units.count, units[to] == units[at] { to += 1 }
            let run = NSRange(location: at, length: to - at)
            out.addAttributes(runAttributes(units[at], face: face, base: base), range: run)
            at = to
        }
        return out
    }

    /// What every character of the block wears before any mark does.
    static func baseAttributes(face: Face,
                               ink: NoteUIColor,
                               base: Flags = [],
                               paragraph: NSParagraphStyle? = nil) -> [NSAttributedString.Key: Any]
    {
        var a: [NSAttributedString.Key: Any] = [
            .font: face.regular,
            .foregroundColor: ink,
            flagsKey: Flags().rawValue,
            .underlineStyle: base.contains(.u) ? NSUnderlineStyle.single.rawValue : 0,
            .strikethroughStyle: base.contains(.strike) ? NSUnderlineStyle.single.rawValue : 0,
        ]
        if let paragraph { a[.paragraphStyle] = paragraph }
        return a
    }

    /// What one run wears on top of that. The base flags are OR-ed in for
    /// drawing — a done line stays struck through under a bold run — and
    /// the key carries the mark's own flags alone.
    private static func runAttributes(_ f: Flags,
                                      face: Face,
                                      base: Flags) -> [NSAttributedString.Key: Any]
    {
        let drawn = f.union(base)
        return [
            .font: face.font(drawn),
            flagsKey: f.rawValue,
            .underlineStyle: drawn.contains(.u) ? NSUnderlineStyle.single.rawValue : 0,
            .strikethroughStyle: drawn.contains(.strike) ? NSUnderlineStyle.single.rawValue : 0,
        ]
    }

    // MARK: attributed → marks

    /// `readBlockText`. Every run of the string, turned back into text
    /// plus offsets, with the block's own base style subtracted.
    ///
    /// The text comes back capped at 2000 UTF-16 units, which is where
    /// `readNoteFromDom` (app.js:4646) puts the cap. The marks are NOT
    /// re-clamped to it: neither does app.js, and `normalizeBlock` does it
    /// on the next load.
    static func read(_ a: NSAttributedString,
                     face: Face,
                     base: Flags = []) -> (text: String, marks: [NoteMark])
    {
        var runs: [NoteMark] = []
        let whole = NSRange(location: 0, length: a.length)
        a.enumerateAttributes(in: whole, options: []) { attrs, range, _ in
            let f = runFlags(attrs, face: face, base: base)
            guard !f.isEmpty else { return }
            runs.append(mark(range.location, range.location + range.length, f))
        }
        return (Normalize.slice(a.string, 2000), mergeMarks(runs))
    }

    /// The flags of one run. The key is believed when it is there; when
    /// it is not — text pasted in from somewhere with no idea this app
    /// exists — the run is read the way `readBlockText` reads foreign
    /// markup, off what it looks like, minus whatever the base already
    /// was.
    static func runFlags(_ attrs: [NSAttributedString.Key: Any],
                         face: Face,
                         base: Flags) -> Flags
    {
        /* The key holds the run's OWN flags and never the base's, so it is
           believed whole. Subtracting the base here would delete a real
           strike mark from a line that happens to be ticked off. */
        if let raw = attrs[flagsKey] as? Int { return Flags(rawValue: raw) }

        var f = Flags()
        if let font = attrs[.font] as? NoteUIFont {
            if font == face.bold || font == face.boldItalic { f.insert(.b) }
            if font == face.italic || font == face.boldItalic { f.insert(.i) }
            #if canImport(UIKit)
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.traitBold) { f.insert(.b) }
            if traits.contains(.traitItalic) { f.insert(.i) }
            #else
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.bold) { f.insert(.b) }
            if traits.contains(.italic) { f.insert(.i) }
            #endif
        }
        if let u = attrs[.underlineStyle] as? Int, u != 0 { f.insert(.u) }
        if let s = attrs[.strikethroughStyle] as? Int, s != 0 { f.insert(.strike) }
        return f.subtracting(base)
    }

    // MARK: applying one of the four to a range

    /// B / I / U / S, which the web hands to `execCommand` and reads
    /// straight back out. The same thing said in the one place the caret
    /// is: flip the flag over the selection, or over the typing
    /// attributes when there is nothing selected.
    ///
    /// The flag is flipped OFF only when every code unit of the range
    /// already carries it — which is what a browser's `queryCommandState`
    /// answers and what makes a part-bold selection go fully bold on the
    /// first press rather than half-clearing.
    static func toggle(_ flag: Flags,
                       in range: NSRange,
                       of a: NSMutableAttributedString,
                       face: Face,
                       base: Flags = [])
    {
        guard range.length > 0, a.length > 0 else { return }
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: a.length))
        guard clipped.length > 0 else { return }

        /* Read the whole selection first and write afterwards: mutating a
           string's attributes from inside its own enumeration is not
           something NSAttributedString promises anything about. */
        var runs: [(NSRange, Flags)] = []
        a.enumerateAttributes(in: clipped, options: []) { attrs, sub, _ in
            runs.append((sub, runFlags(attrs, face: face, base: base)))
        }
        let allOn = runs.allSatisfy { $0.1.contains(flag) }

        for (sub, was) in runs {
            var f = was
            if allOn { f.remove(flag) } else { f.insert(flag) }
            a.addAttributes(runAttributes(f, face: face, base: base), range: sub)
        }
    }

    /// The same flip for an empty caret: what the next character typed
    /// will wear.
    static func toggled(_ flag: Flags,
                        in typing: [NSAttributedString.Key: Any],
                        face: Face,
                        base: Flags = []) -> [NSAttributedString.Key: Any]
    {
        var f = runFlags(typing, face: face, base: base)
        if f.contains(flag) { f.remove(flag) } else { f.insert(flag) }
        var out = typing
        for (k, v) in runAttributes(f, face: face, base: base) { out[k] = v }
        return out
    }
}

// MARK: - the two edits that move marks between blocks

/// `blockKey` (app.js:4672-4722), without the event or the DOM.
///
/// Both of these are pure functions of the block list so that
/// `Checks/notes.sh` can run them against the real `blockKey` in
/// JavaScriptCore, table for table. They are the two places in the whole
/// app where a mark's offsets are arithmetic rather than a copy, and the
/// asymmetry between them is app.js's and is deliberate:
///
/// - **Enter drops the tail's marks.** The new block is built by
///   `normalizeBlock({ text, type, align })` with no `marks` key at all,
///   so formatting that was after the caret is gone. The head keeps its
///   own, filtered to those that start before the cut and clamped to it.
/// - **Backspace keeps everything.** The joined block gets the second
///   block's marks shifted by the first's length and then `mergeMarks`
///   run over the lot, which is the only call site where a mark from one
///   block can fuse onto a mark from another.
enum NoteEdit {

    /// Where a caret may sit. A UTF-16 offset that would land between the
    /// two halves of a surrogate pair is moved back onto the pair's
    /// start: `String(decoding:as: UTF16.self)` cannot hold the lone
    /// surrogate JavaScript's `slice` would leave there, and a text view
    /// never puts a caret inside an emoji anyway.
    static func caretSafe(_ text: String, _ offset: Int) -> Int {
        let u = Array(text.utf16)
        var at = max(0, min(u.count, offset))
        if at > 0, at < u.count,
           (0xD800...0xDBFF).contains(u[at - 1]), (0xDC00...0xDFFF).contains(u[at])
        {
            at -= 1
        }
        return at
    }

    struct Result: Equatable {
        var blocks: [NoteBlock]
        /// Which block the caret lands in, and how far into it.
        var caret: Int
        var offset: Int
    }

    /// Enter, with no Shift. app.js:4676-4711.
    static func split(_ blocks: [NoteBlock], at i: Int, offset: Int) -> Result? {
        guard blocks.indices.contains(i) else { return nil }
        var out = blocks
        let b = out[i]

        /* Enter on an empty bullet ends the list rather than making
           another one — and makes no new block at all. */
        let carry = (b.type == "ul" || b.type == "ol" || b.type == "check")
        if carry && b.text.isEmpty {
            out[i].type = "p"
            out[i].done = false
            return Result(blocks: out, caret: i, offset: 0)
        }

        let units = Array(b.text.utf16)
        let at = caretSafe(b.text, offset)
        let head = String(decoding: units[0..<at], as: UTF16.self)
        let tail = String(decoding: units[at...], as: UTF16.self)

        out[i].text = head
        out[i].marks = b.marks
            .filter { $0.s < at }
            .map { m in
                var m = m
                m.e = min(m.e, at)
                return m
            }

        /* `normalizeBlock({ text, type, align })`: no marks key, so no
           marks — and `done` defaults to false however the line above it
           was ticked. */
        out.insert(NoteBlock.normalize(.object(JSONObject([
            ("text", .string(tail)),
            ("type", .string(carry ? b.type : "p")),
            ("align", .string(b.align)),
        ]))), at: i + 1)

        return Result(blocks: out, caret: i + 1, offset: 0)
    }

    /// Backspace with the caret at 0 and a block above it. app.js:4713-4722.
    static func merge(_ blocks: [NoteBlock], at i: Int) -> Result? {
        guard i > 0, blocks.indices.contains(i) else { return nil }
        var out = blocks
        let here = out[i]
        var prev = out[i - 1]

        let at = prev.text.utf16.count
        prev.text = Normalize.slice(prev.text + here.text, 2000)
        for m in here.marks {
            prev.marks.append(NoteMark(s: m.s + at, e: m.e + at,
                                       b: m.b, i: m.i, u: m.u, strike: m.strike))
        }
        prev.marks = MarksBridge.mergeMarks(prev.marks)

        out[i - 1] = prev
        out.remove(at: i)
        return Result(blocks: out, caret: i - 1, offset: at)
    }
}
