/* ============================================================
   my.adhd for iOS — the permissive JSON tree

   The native app's compatibility target is not "a task list". It is
   `myadhd.v1`: one JSON document, written by `JSON.stringify(state)` in
   app.js, read by the web app, by `TaskBridge`, by `Reminders`, and —
   through Supabase — by every other device the person owns. A key this
   build has never heard of is not noise. It is a field a newer web build
   writes, and the web's own merge deletes every local key before it
   assigns an arriving payload (cloud.js:290-293), so a client that drops
   a field erases it for everybody.

   So: decode into a tree that keeps everything, in order.

   - Objects keep INSERTION ORDER. `JSON.stringify` walks an object's own
     keys in insertion order, and `sigOf` (cloud.js:106-114) hashes the
     resulting text. A dictionary would reshuffle the bytes and make the
     web see every task as edited exactly once.
   - Numbers keep the int/double distinction. JS has one number type and
     prints `20` for 20.0; a decoder that promoted everything to Double
     and printed "20.0" would break byte-identity with the page.
   - Duplicate keys follow JS: the first occurrence fixes the position,
     the last occurrence wins the value.

   The one thing this cannot carry is a LONE SURROGATE inside a string.
   A Swift `String` cannot hold one. Every string in this document comes
   from `JSON.stringify` of a well-formed JS string or from a text field,
   so none can occur in practice; `\uD800` on its own would arrive as
   U+FFFD. Written down rather than pretended away.
   ============================================================ */

import Foundation

// MARK: - an object that remembers what order it was written in

/// A JSON object: string keys in insertion order, JSON values.
public struct JSONObject: Equatable, Sequence {

    /// The keys, in the order they were first seen or first set.
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}

    public init(_ pairs: [(String, JSONValue)]) {
        for (k, v) in pairs { self[k] = v }
    }

    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                if let i = keys.firstIndex(of: key) { keys.remove(at: i) }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public func has(_ key: String) -> Bool { storage[key] != nil }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> JSONValue? {
        let old = storage.removeValue(forKey: key)
        if old != nil, let i = keys.firstIndex(of: key) { keys.remove(at: i) }
        return old
    }

    /// Append `value` under `key`, or update it in place if the key is
    /// already there — `obj[k] = v` in JavaScript, exactly.
    public mutating func set(_ key: String, _ value: JSONValue) {
        self[key] = value
    }

    public var pairs: [(String, JSONValue)] {
        keys.map { ($0, storage[$0] ?? .null) }
    }

    public func makeIterator() -> AnyIterator<(String, JSONValue)> {
        var i = 0
        let ks = keys, st = storage
        return AnyIterator {
            guard i < ks.count else { return nil }
            defer { i += 1 }
            return (ks[i], st[ks[i]] ?? .null)
        }
    }

    public static func == (a: JSONObject, b: JSONObject) -> Bool {
        a.keys == b.keys && a.storage == b.storage
    }
}

// MARK: - the tree

public enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

public extension JSONValue {

    var isNull: Bool { if case .null = self { return true }; return false }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// The number as an `Int`, whichever way it was stored. A double with
    /// a fractional part is not an integer and answers nil.
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d):
            guard d.isFinite, d == d.rounded(.towardZero),
                  d >= -9007199254740992, d <= 9007199254740992 else { return nil }
            return Int(d)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// JavaScript truthiness. `0`, `-0`, `NaN`, `""`, `false`, `null` and
    /// a missing key are falsy; everything else, including `[]` and `{}`,
    /// is truthy. Used wherever app.js writes `x || fallback`.
    var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0 && !d.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

// MARK: - reading

public extension JSONValue {

    enum ParseError: Error, CustomStringConvertible {
        case unexpectedEnd
        case unexpected(UInt8, at: Int)
        case badNumber(String, at: Int)
        case badEscape(at: Int)
        case trailing(at: Int)

        public var description: String {
            switch self {
            case .unexpectedEnd: return "unexpected end of input"
            case .unexpected(let b, let i):
                return "unexpected byte \(b) (\(Character(UnicodeScalar(b)))) at \(i)"
            case .badNumber(let s, let i): return "bad number \(s) at \(i)"
            case .badEscape(let i): return "bad escape at \(i)"
            case .trailing(let i): return "trailing content at \(i)"
            }
        }
    }

    /// Strict JSON, as `JSON.parse` is strict: no trailing commas, no
    /// comments, no unquoted keys. Written by hand rather than handed to
    /// `JSONSerialization` because the two things this tree exists for —
    /// key order and int-versus-double — are the two things
    /// `JSONSerialization` throws away.
    static func parse(_ data: Data) throws -> JSONValue {
        var p = Parser(bytes: [UInt8](data))
        let v = try p.value()
        p.skipWhitespace()
        guard p.i == p.bytes.count else { throw ParseError.trailing(at: p.i) }
        return v
    }

    static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }
}

private struct Parser {
    let bytes: [UInt8]
    var i = 0

    mutating func skipWhitespace() {
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { i += 1 } else { break }
        }
    }

    mutating func value() throws -> JSONValue {
        skipWhitespace()
        guard i < bytes.count else { throw JSONValue.ParseError.unexpectedEnd }
        switch bytes[i] {
        case 0x7B: return try object()
        case 0x5B: return try array()
        case 0x22: return .string(try string())
        case 0x74: try literal("true");  return .bool(true)
        case 0x66: try literal("false"); return .bool(false)
        case 0x6E: try literal("null");  return .null
        default:   return try number()
        }
    }

    mutating func literal(_ word: String) throws {
        let w = [UInt8](word.utf8)
        guard i + w.count <= bytes.count, Array(bytes[i..<(i + w.count)]) == w else {
            throw JSONValue.ParseError.unexpected(bytes[i], at: i)
        }
        i += w.count
    }

    mutating func object() throws -> JSONValue {
        i += 1                                  // '{'
        var out = JSONObject()
        skipWhitespace()
        if i < bytes.count, bytes[i] == 0x7D { i += 1; return .object(out) }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == 0x22 else {
                throw i < bytes.count ? JSONValue.ParseError.unexpected(bytes[i], at: i)
                                      : JSONValue.ParseError.unexpectedEnd
            }
            let key = try string()
            skipWhitespace()
            guard i < bytes.count, bytes[i] == 0x3A else {
                throw i < bytes.count ? JSONValue.ParseError.unexpected(bytes[i], at: i)
                                      : JSONValue.ParseError.unexpectedEnd
            }
            i += 1
            out[key] = try value()              // duplicate: last value, first position
            skipWhitespace()
            guard i < bytes.count else { throw JSONValue.ParseError.unexpectedEnd }
            if bytes[i] == 0x2C { i += 1; continue }
            if bytes[i] == 0x7D { i += 1; return .object(out) }
            throw JSONValue.ParseError.unexpected(bytes[i], at: i)
        }
    }

    mutating func array() throws -> JSONValue {
        i += 1                                  // '['
        var out: [JSONValue] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == 0x5D { i += 1; return .array(out) }
        while true {
            out.append(try value())
            skipWhitespace()
            guard i < bytes.count else { throw JSONValue.ParseError.unexpectedEnd }
            if bytes[i] == 0x2C { i += 1; continue }
            if bytes[i] == 0x5D { i += 1; return .array(out) }
            throw JSONValue.ParseError.unexpected(bytes[i], at: i)
        }
    }

    mutating func string() throws -> String {
        i += 1                                  // '"'
        var units: [UInt16] = []
        var plain: [UInt8] = []

        func flush() {
            guard !plain.isEmpty else { return }
            units.append(contentsOf: Array(String(decoding: plain, as: UTF8.self).utf16))
            plain.removeAll(keepingCapacity: true)
        }

        while i < bytes.count {
            let b = bytes[i]
            if b == 0x22 {
                i += 1
                flush()
                return String(decoding: units, as: UTF16.self)
            }
            if b == 0x5C {
                flush()
                i += 1
                guard i < bytes.count else { throw JSONValue.ParseError.unexpectedEnd }
                switch bytes[i] {
                case 0x22: units.append(0x22); i += 1
                case 0x5C: units.append(0x5C); i += 1
                case 0x2F: units.append(0x2F); i += 1
                case 0x62: units.append(0x08); i += 1
                case 0x66: units.append(0x0C); i += 1
                case 0x6E: units.append(0x0A); i += 1
                case 0x72: units.append(0x0D); i += 1
                case 0x74: units.append(0x09); i += 1
                case 0x75:
                    guard i + 4 < bytes.count else { throw JSONValue.ParseError.unexpectedEnd }
                    var u: UInt16 = 0
                    for k in 1...4 {
                        guard let d = hex(bytes[i + k]) else {
                            throw JSONValue.ParseError.badEscape(at: i)
                        }
                        u = u << 4 | UInt16(d)
                    }
                    units.append(u)
                    i += 5
                default: throw JSONValue.ParseError.badEscape(at: i)
                }
                continue
            }
            plain.append(b)
            i += 1
        }
        throw JSONValue.ParseError.unexpectedEnd
    }

    private func hex(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x61...0x66: return b - 0x61 + 10
        case 0x41...0x46: return b - 0x41 + 10
        default: return nil
        }
    }

    mutating func number() throws -> JSONValue {
        let start = i
        if i < bytes.count, bytes[i] == 0x2D { i += 1 }
        while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
        var fractional = false
        if i < bytes.count, bytes[i] == 0x2E {
            fractional = true
            i += 1
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
        }
        if i < bytes.count, bytes[i] == 0x65 || bytes[i] == 0x45 {
            fractional = true
            i += 1
            if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
        }
        let text = String(decoding: bytes[start..<i], as: UTF8.self)
        guard !text.isEmpty, text != "-" else {
            throw JSONValue.ParseError.unexpected(bytes[min(start, bytes.count - 1)], at: start)
        }
        if !fractional, let n = Int(text), abs(n) <= 9007199254740992 { return .int(n) }
        guard let d = Double(text) else { throw JSONValue.ParseError.badNumber(text, at: start) }
        /* `1e2` is 100 in JavaScript and prints as "100"; only the
           fraction-free-and-small case above is safe to keep as an Int,
           but an exponent that lands on a whole number is still a whole
           number and `WebJSON` will print it as one. */
        return .double(d)
    }
}
