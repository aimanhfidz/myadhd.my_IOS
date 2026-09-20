/* ============================================================
   my.adhd for iOS — JSON.stringify, in Swift, byte for byte

   Bytes matter here for one concrete reason: `sigOf` (cloud.js:106-114)
   is FNV-1a over `JSON.stringify(task)` and its rendered form ends in
   `'.' + json.length`. If this encoder puts a space after a colon, or
   escapes a slash, or prints `20.0` where the page prints `20`, then
   every task's signature changes, `cloud.stamp()` restamps every row to
   `now`, and the next device's genuinely newer edit loses the
   last-write-wins. That is not "one extra push"; it is lost work.

   So this is not "some JSON writer". It is `JSON.stringify(value)` with
   no replacer and no space:

   - no whitespace at all, anywhere
   - `/` is NOT escaped (that is a JS-source habit, not a JSON one)
   - non-ASCII is emitted RAW — no `\uXXXX`. `JSON.stringify('é😀')`
     is `"é😀"`. U+2028 and U+2029 are left raw too; escaping those is
     something JS source needs and JSON does not.
   - only `"`, `\` and the C0 controls are escaped, and the controls use
     the short forms `\b \t \n \f \r` where they have one, lowercase
     `\u00xx` otherwise
   - numbers use ECMA-262's Number::toString, so integers have no
     fraction, `1e20` is twenty zeros and `1e21` is `1e+21`
   - NaN and Infinity serialise as `null`, as JSON.stringify does
   ============================================================ */

import Foundation

public enum WebJSON {

    // MARK: - the whole tree

    public static func encode(_ value: JSONValue) -> String {
        var out = ""
        out.reserveCapacity(1024)
        write(value, into: &out)
        return out
    }

    public static func encode(_ object: JSONObject) -> String {
        encode(.object(object))
    }

    public static func data(_ value: JSONValue) -> Data {
        Data(encode(value).utf8)
    }

    private static func write(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null:          out += "null"
        case .bool(let b):   out += b ? "true" : "false"
        case .int(let i):    out += number(i)
        case .double(let d): out += number(d)
        case .string(let s): out += quoted(s)
        case .array(let a):
            out += "["
            for (n, item) in a.enumerated() {
                if n > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            var first = true
            for (k, v) in o {
                if !first { out += "," }
                first = false
                out += quoted(k)
                out += ":"
                write(v, into: &out)
            }
            out += "}"
        }
    }

    // MARK: - strings

    /// The quoted, escaped form — including the surrounding `"`.
    public static func quoted(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf8.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"":  out += "\\\""
            case "\\":  out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{09}": out += "\\t"
            case "\u{0A}": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\u{0D}": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: - numbers

    /// JavaScript loses exactness above 2^53, so an Int that large is
    /// printed the way the page would print it, not the way Swift can.
    public static func number(_ i: Int) -> String {
        abs(i) <= 9007199254740992 ? String(i) : number(Double(i))
    }

    /// ECMA-262 Number::toString(x), radix 10.
    ///
    /// Swift's own `description` is the shortest round-tripping decimal,
    /// which is the hard half of the job — but it formats the easy half
    /// differently (`1e+20` where JS writes twenty zeros, `1e-06` where
    /// JS writes `0.000001`). So: take Swift's digits, then re-apply the
    /// spec's five cases.
    public static func number(_ x: Double) -> String {
        if x.isNaN || x.isInfinite { return "null" }
        if x == 0 { return "0" }                       // -0 prints as "0" too
        if x < 0 { return "-" + number(-x) }

        // value == 0.<digits> * 10^n, digits with no leading or trailing zero
        var mantissa = "\(x)"
        var exponent = 0
        if let e = mantissa.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(mantissa[mantissa.index(after: e)...]) ?? 0
            mantissa = String(mantissa[..<e])
        }
        var intPart = mantissa, fracPart = ""
        if let dot = mantissa.firstIndex(of: ".") {
            intPart = String(mantissa[..<dot])
            fracPart = String(mantissa[mantissa.index(after: dot)...])
        }
        var digits = Array(intPart + fracPart)
        var n = intPart.count + exponent
        while let f = digits.first, f == "0" { digits.removeFirst(); n -= 1 }
        while let l = digits.last, l == "0" { digits.removeLast() }
        if digits.isEmpty { return "0" }
        let k = digits.count
        let d = String(digits)

        if k <= n && n <= 21 {
            return d + String(repeating: "0", count: n - k)
        }
        if 0 < n && n <= 21 {
            let cut = d.index(d.startIndex, offsetBy: n)
            return String(d[..<cut]) + "." + String(d[cut...])
        }
        if -6 < n && n <= 0 {
            return "0." + String(repeating: "0", count: -n) + d
        }
        let e = n - 1
        let sign = e >= 0 ? "+" : "-"
        if k == 1 { return d + "e" + sign + String(abs(e)) }
        let head = d.index(after: d.startIndex)
        return String(d[..<head]) + "." + String(d[head...]) + "e" + sign + String(abs(e))
    }
}
