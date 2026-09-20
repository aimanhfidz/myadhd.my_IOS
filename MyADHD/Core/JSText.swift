/* ============================================================
   JSText — the String.prototype edges the port leans on

   Three small operations that Swift and JavaScript disagree about,
   written once so nothing in the port has to keep a private copy.
   This lives in Core/ rather than beside JSRegex because it is not a
   regex concern: `Normalize.jsNumber` coerces with the same trim, and
   `AppStore` trims titles with it, and neither of those compiles the
   offline parser.

   Moved here from MyADHD/Triage/JSRegex.swift when three separate
   `trim()`s turned out to exist. This one is the faithful one: it
   trims exactly WhiteSpace + LineTerminator, which means it removes
   U+FEFF (Swift's `.whitespacesAndNewlines` does not) and keeps
   U+200B-U+200D (Swift's set removes them, JavaScript keeps them).
   ============================================================ */

import Foundation

// MARK: - String helpers with JavaScript's edges

enum JSText {

    /// Lower-cases A-Z and nothing else, so the result has exactly the
    /// same UTF-16 length and every offset in it addresses the same
    /// unit of the original. This is what stands in for the `i` flag.
    ///
    /// It is deliberately NOT `lowercased()`: that is full Unicode
    /// lowercasing, which can change length (U+0130 becomes two units)
    /// and would fold characters JavaScript's `i` flag refuses to.
    static func asciiLowered(_ s: String) -> String {
        var units = Array(s.utf16)
        var touched = false
        for i in units.indices where units[i] >= 65 && units[i] <= 90 {
            units[i] += 32
            touched = true
        }
        return touched ? String(decoding: units, as: UTF16.self) : s
    }

    /// The characters `String.prototype.trim` removes: WhiteSpace and
    /// LineTerminator. Not `.whitespacesAndNewlines`, which trims the
    /// zero-width joiners U+200B-U+200D that JavaScript keeps and keeps
    /// the U+FEFF that JavaScript trims.
    static let trimScalars: Set<Unicode.Scalar> = {
        var out: Set<Unicode.Scalar> = []
        for v in 0x09...0x0D { out.insert(Unicode.Scalar(UInt8(v))) }
        for v in 0x2000...0x200A { out.insert(Unicode.Scalar(UInt32(v))!) }
        for v in [0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF] {
            out.insert(Unicode.Scalar(UInt32(v))!)
        }
        return out
    }()

    /// `String.prototype.trim()`.
    static func trim(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var lo = 0, hi = scalars.count
        while lo < hi, trimScalars.contains(scalars[lo]) { lo += 1 }
        while hi > lo, trimScalars.contains(scalars[hi - 1]) { hi -= 1 }
        if lo == 0 && hi == scalars.count { return s }
        var out = String.UnicodeScalarView()
        for i in lo..<hi { out.append(scalars[i]) }
        return String(out)
    }

    /// `s.charAt(0).toUpperCase() + s.slice(1)`.
    ///
    /// `charAt` is one UTF-16 unit, so a leading emoji hands JavaScript
    /// a lone high surrogate, `toUpperCase` returns it unchanged and
    /// the concatenation puts the pair back together. Swift cannot hold
    /// a lone surrogate in a String, so a surrogate first unit is left
    /// alone — the same answer, reached without minting one.
    ///
    /// The upper-casing itself is full Unicode, as JavaScript's is:
    /// "\u{00DF}eta" becomes "SSeta" in both.
    static func upperFirst(_ s: String) -> String {
        let units = Array(s.utf16)
        guard let first = units.first else { return s }
        if first >= 0xD800 && first <= 0xDFFF { return s }
        let head = String(decoding: [first], as: UTF16.self).uppercased()
        let tail = String(decoding: units[1...], as: UTF16.self)
        return head + tail
    }
}
