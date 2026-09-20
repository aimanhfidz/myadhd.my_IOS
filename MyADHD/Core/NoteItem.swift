/* ============================================================
   my.adhd for iOS — one note

   `normalizeNote` (app.js:4279-4341) and the two normalisers under it,
   ported. Unlike the tasks, notes ARE normalised on every load
   (app.js:271) — which also means the web drops unknown note keys, so
   this type does too rather than inventing a fidelity the page does not
   have.

   Two things that look like details and are not:

   - **`body` is derived, never stored-and-trusted.** It is
     `blocks.map(text).join('\n')` capped at 20000, recomputed on every
     load. A note written before blocks existed has only a body, and it
     becomes ONE BLOCK PER LINE rather than one block holding newlines,
     because that is what the editor would have made of it had it always
     been there.

   - **`Mark.s` and `Mark.e` are UTF-16 code-unit offsets**, because
     that is what `String.prototype` counts and what the contenteditable
     handed the page. "🙂" is two of them. They map straight onto an
     `NSRange` over the block's `NSString` and must never be compared
     with `String.count`.

   Every cap in here (2000, 20000, 160, 300, 60, 3) is a UTF-16 cap or a
   count, exactly as `slice` applies it.
   ============================================================ */

import Foundation

// MARK: - the pieces

/// One run of formatting inside a block. Offsets are UTF-16 code units.
public struct NoteMark: Equatable {
    public var s: Int
    public var e: Int
    public var b: Bool
    public var i: Bool
    public var u: Bool
    public var strike: Bool

    public init(s: Int, e: Int, b: Bool = false, i: Bool = false,
                u: Bool = false, strike: Bool = false) {
        self.s = s; self.e = e; self.b = b; self.i = i; self.u = u; self.strike = strike
    }

    public var json: JSONValue {
        .object(JSONObject([
            ("s", .int(s)), ("e", .int(e)),
            ("b", .bool(b)), ("i", .bool(i)), ("u", .bool(u)), ("strike", .bool(strike)),
        ]))
    }
}

public struct NoteBlock: Equatable {
    /// app.js:4274. 'p' | 'h' | 'ul' | 'ol' | 'check'.
    public static let types = ["p", "h", "ul", "ol", "check"]
    public static let aligns = ["center", "right"]      // anything else is 'left'

    public var type: String
    public var text: String
    public var marks: [NoteMark]
    public var done: Bool
    public var align: String

    public init(type: String = "p", text: String = "", marks: [NoteMark] = [],
                done: Bool = false, align: String = "left") {
        self.type = type; self.text = text; self.marks = marks
        self.done = done; self.align = align
    }

    public var json: JSONValue {
        .object(JSONObject([
            ("type", .string(type)),
            ("text", .string(text)),
            ("marks", .array(marks.map { $0.json })),
            ("done", .bool(done)),
            ("align", .string(align)),
        ]))
    }

    /// app.js:4279-4296.
    public static func normalize(_ b: JSONValue?) -> NoteBlock {
        let text = Normalize.slice(Normalize.jsString(b["text"].orFallback(.string(""))), 2000)
        let length = text.utf16.count
        var marks: [NoteMark] = []
        if let raw = b["marks"]?.arrayValue {
            marks = raw.map { m in
                NoteMark(
                    s: max(0, min(length, toInt32(Normalize.jsNumber(m["s"])))),
                    e: max(0, min(length, toInt32(Normalize.jsNumber(m["e"])))),
                    b: m["b"]?.boolValue == true,
                    i: m["i"]?.boolValue == true,
                    u: m["u"]?.boolValue == true,
                    strike: m["strike"]?.boolValue == true
                )
            }
            .filter { $0.e > $0.s && ($0.b || $0.i || $0.u || $0.strike) }
            marks = Array(marks.prefix(60))
        }
        let t = b["type"]?.stringValue ?? ""
        let a = b["align"]?.stringValue ?? ""
        return NoteBlock(
            type: types.contains(t) ? t : "p",
            text: text,
            marks: marks,
            done: b["done"]?.boolValue == true,
            align: aligns.contains(a) ? a : "left"
        )
    }

    /// `Number(x) | 0` — ToInt32, which truncates towards zero and wraps
    /// at 2^32. NaN and Infinity become 0.
    static func toInt32(_ d: Double) -> Int {
        guard d.isFinite else { return 0 }
        let truncated = d < 0 ? -(-d).rounded(.down) : d.rounded(.down)
        var m = truncated.truncatingRemainder(dividingBy: 4294967296)
        if m < 0 { m += 4294967296 }
        if m >= 2147483648 { m -= 4294967296 }
        return Int(m)
    }
}

public struct NoteFile: Equatable {
    public var id: String
    public var src: String          // a `data:image/...` URL, always

    public init(id: String, src: String) { self.id = id; self.src = src }

    public var json: JSONValue {
        .object(JSONObject([("id", .string(id)), ("src", .string(src))]))
    }
}

/// How the note looks: which paper, which face. Nothing about the words.
public struct NoteLook: Equatable {
    public static let papers = ["lavender", "violet", "blue", "orange", "red", "stone", "white"]
    public static let fonts = ["baloo", "sans", "mono"]

    public var paper: String
    public var font: String

    public init(paper: String = "lavender", font: String = "baloo") {
        self.paper = paper; self.font = font
    }

    public var json: JSONValue {
        .object(JSONObject([("paper", .string(paper)), ("font", .string(font))]))
    }

    /// app.js:4346-4351.
    public static func normalize(_ l: JSONValue?) -> NoteLook {
        let p = l?["paper"]?.stringValue ?? ""
        let f = l?["font"]?.stringValue ?? ""
        return NoteLook(paper: papers.contains(p) ? p : "lavender",
                        font: fonts.contains(f) ? f : "baloo")
    }
}

// MARK: - the note

public struct NoteItem: Equatable {

    public static let fileMax = 3               // pictures per note
    public static let repeats = ["daily", "weekly", "monthly"]

    public var id: String
    public var title: String                    // ≤160 UTF-16 units
    public var body: String                     // derived from blocks, ≤20000
    public var blocks: [NoteBlock]              // 1...300
    public var remindOn: String?                // "YYYY-MM-DD"
    public var remindAt: String?                // "HH:MM"
    /// `repeat` is a Swift keyword; the JSON key is still "repeat".
    public var repeatRule: String               // '' | daily | weekly | monthly
    public var files: [NoteFile]                // ≤3, all `data:image/`
    public var look: NoteLook
    public var createdAt: Double                // epoch milliseconds
    public var updatedAt: Double                // epoch milliseconds

    public init(id: String, title: String = "", blocks: [NoteBlock] = [NoteBlock()],
                remindOn: String? = nil, remindAt: String? = nil, repeatRule: String = "",
                files: [NoteFile] = [], look: NoteLook = NoteLook(),
                createdAt: Double, updatedAt: Double)
    {
        self.id = id
        self.title = title
        self.blocks = blocks
        self.body = Normalize.slice(blocks.map(\.text).joined(separator: "\n"), 20000)
        self.remindOn = remindOn
        self.remindAt = remindAt
        self.repeatRule = repeatRule
        self.files = files
        self.look = look
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Recompute `body` after the blocks have moved. The page does this
    /// implicitly by re-normalising; here it is a method so nothing has
    /// to remember to.
    public mutating func refreshBody() {
        body = Normalize.slice(blocks.map(\.text).joined(separator: "\n"), 20000)
    }

    /// `normalizeNote`'s literal key order (app.js:4310-4340).
    public var json: JSONValue {
        .object(JSONObject([
            ("id", .string(id)),
            ("title", .string(title)),
            ("body", .string(body)),
            ("blocks", .array(blocks.map { $0.json })),
            ("remindOn", remindOn.map { .string($0) } ?? .null),
            ("remindAt", remindAt.map { .string($0) } ?? .null),
            ("repeat", .string(repeatRule)),
            ("files", .array(files.map { $0.json })),
            ("look", look.json),
            ("createdAt", .double(createdAt)),
            ("updatedAt", .double(updatedAt)),
        ]))
    }

    public var jsonString: String { WebJSON.encode(json) }

    /// app.js:4298-4341, ported. `now` is `Date.now()` in milliseconds.
    public static func normalize(_ n: JSONValue?,
                                 now: Double = Date().timeIntervalSince1970 * 1000,
                                 mintID: () -> String = Normalize.newNoteID,
                                 mintFileID: () -> String = Normalize.newFileID) -> NoteItem
    {
        let nowMS = now.rounded(.down)
        let body = Normalize.slice(Normalize.jsString(n["body"].orFallback(.string(""))), 20000)

        let blocks: [NoteBlock]
        if let raw = n["blocks"]?.arrayValue, !raw.isEmpty {
            blocks = raw.prefix(300).map { NoteBlock.normalize($0) }
        } else {
            /* One block per line, not one block holding newlines. */
            blocks = body.components(separatedBy: "\n").map {
                NoteBlock.normalize(.object(JSONObject([("text", .string($0))])))
            }
        }

        let idValue = n["id"].orFallback(.string(mintID()))
        let rep = n["repeat"]?.stringValue ?? ""

        var files: [NoteFile] = []
        if let raw = n["files"]?.arrayValue {
            files = raw.prefix(fileMax).compactMap { f in
                guard let src = f["src"]?.stringValue, src.hasPrefix("data:image/") else { return nil }
                let fid = f["id"].orFallback(.string(mintFileID()))
                return NoteFile(id: Normalize.jsString(fid), src: src)
            }
        }

        let created = firstNumber(n["createdAt"], fallback: nowMS)
        let updated = firstNumber(n["updatedAt"],
                                  fallback: firstNumber(n["createdAt"], fallback: nowMS))

        var note = NoteItem(
            id: Normalize.jsString(idValue),
            title: Normalize.slice(Normalize.jsString(n["title"].orFallback(.string(""))), 160),
            blocks: blocks,
            remindOn: Normalize.normalizeDay(n["remindOn"]),
            remindAt: Normalize.normalizeTime(n["remindAt"]),
            repeatRule: repeats.contains(rep) ? rep : "",
            files: files,
            look: NoteLook.normalize(n["look"]),
            createdAt: created,
            updatedAt: updated
        )
        note.refreshBody()
        return note
    }

    /// `Number(v) || fallback` — 0 and NaN both fall through.
    private static func firstNumber(_ v: JSONValue?, fallback: Double) -> Double {
        let d = Normalize.jsNumber(v)
        return (d.isNaN || d == 0) ? fallback : d
    }
}
