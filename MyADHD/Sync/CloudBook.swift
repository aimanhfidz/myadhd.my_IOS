/* ============================================================
   MyADHD/Sync/CloudBook.swift — what this device last said about each task

   `myadhd.cloud.v1`, ported from cloud.js:53, 89-114, 163-212. Three
   fields and no more: `{user, sigs, graves}`.

     user    the account id the other two describe. A different one means
             the bookkeeping is about somebody else's rows and is thrown
             away (cloud.js:375-382).
     sigs    id -> the hash of the task as it was the last time this
             device stamped it. This is what turns "save() was called"
             into "t_abc123 actually changed", so re-rendering, ticking a
             different task or renaming yourself generates no traffic and
             — the part that matters — does not bump a timestamp and beat
             a real edit made on the other device.
     graves  id -> when this device deleted it. A delete has to travel and
             an absent row cannot say anything.

   **`sigOf` is the one function in this file that has to be exactly
   right.** It is FNV-1a 32 over `JSON.stringify(task)` with `updatedAt`
   removed, rendered `h.toString(36) + '.' + s.length` (cloud.js:103-111).
   Two things about it that are easy to get wrong in Swift:

   - `s.length` and `charCodeAt` are UTF-16 code units, so both the hash
     loop and the length walk `s.utf16`. A `String.count` here would
     disagree with the page on every emoji and every Malay word with a
     combining mark.
   - `>>> 0` masks the multiply back to 32 bits. `UInt32` with `&+`/`&<<`
     is the same arithmetic without the mask, because it already wraps.

   The signature does not *have* to match the page byte for byte — the
   book is per device, and only self-consistency is load-bearing. It is
   made to match anyway, because `Checks/cloud.sh` can then hold it
   against the real `cloud.js` and a future hand-back to the web stays
   honest. Byte-identity also means a device that was migrated from the
   old shell and one that was signed in fresh agree about what a row
   looks like.

   **`LegacyImport` holds the same function** (LegacyImport.swift:464) and
   must: it reseals the book on the migration launch, before anything in
   this folder is alive. `Checks/cloud.sh` compiles both and asserts they
   answer the same string for every fixture, which is the only thing that
   stops the two drifting — if they ever disagree, the first pass after an
   upgrade restamps every row and pushes this phone's stale copy over
   another device's real edit.

   **Nothing here talks to the network or to `AppStore`.** `stamp` is
   handed a task list and gives it back; the scheduling, the persisting
   and the `dirty` flag belong to `CloudSync`.
   ============================================================ */

import Foundation

struct CloudBook: Equatable {

    /// How long this device argues for a delete it made (cloud.js:76).
    /// Past this the row is still on the server; what expires is only
    /// our side of the argument, and a device that was off for longer
    /// gets its copy of the task back. That is the failure every sync
    /// has and the harmless direction to fail in.
    static let graveTTL = 90 * 24 * 60 * 60 * 1000

    /// Beside the document, not in it (design §2.4). The same name
    /// `LegacyImport` writes on the migration launch.
    static let fileName = "myadhd.cloud.v1.json"

    /// Kept as a raw JSON value rather than a `String?` so a book written
    /// by something that put anything else here is re-emitted as it was.
    var user: JSONValue = .null

    /// Insertion-ordered, as the JavaScript object is: `book.sigs[id] = …`
    /// appends, `delete` removes, and the file written back has the keys
    /// in the order the page would have had them.
    var sigs = JSONObject()
    var graves = JSONObject()

    init(user: JSONValue = .null, sigs: JSONObject = JSONObject(), graves: JSONObject = JSONObject()) {
        self.user = user
        self.sigs = sigs
        self.graves = graves
    }

    /// `book.user` when it is the id of an account, nil otherwise.
    var userID: String? {
        guard let s = user.stringValue, !s.isEmpty else { return nil }
        return s
    }

    // MARK: - The signature (cloud.js:103-111)

    static func sigOf(_ t: TaskItem) -> String {
        let s = WebJSON.encode(stripUpdatedAt(t.json))

        var h: UInt32 = 0x811c_9dc5
        for unit in s.utf16 {
            h ^= UInt32(unit)
            h = h &+ ((h &<< 1) &+ (h &<< 4) &+ (h &<< 7) &+ (h &<< 8) &+ (h &<< 24))
        }
        return String(h, radix: 36) + "." + String(s.utf16.count)
    }

    /// `JSON.stringify(t, (k, v) => (k === 'updatedAt' ? undefined : v))`.
    ///
    /// The replacer is handed every key at every depth, not just the top
    /// one, so this recurses. A task has no nested `updatedAt` today —
    /// the only object inside one is `gcal {id, sig}` — but an unknown
    /// key carried over from a newer web build could hold anything, and
    /// the page would drop it there too.
    private static func stripUpdatedAt(_ v: JSONValue) -> JSONValue {
        switch v {
        case .object(let o):
            var out = JSONObject()
            for (k, value) in o where k != TaskItem.tailKey {
                out[k] = stripUpdatedAt(value)
            }
            return .object(out)
        case .array(let a):
            return .array(a.map(stripUpdatedAt))
        default:
            return v
        }
    }

    // MARK: - Stamping (cloud.js:163-203)

    /// Called by `save()`, before the store is written, on every single
    /// write. It has to be free for the signed-out majority and it is:
    /// one hash per task and no network.
    ///
    /// It runs when signed out too, which is deliberate — a task edited
    /// offline yesterday and an account added today must arrive carrying
    /// yesterday's real timestamps, not a flat row of "now" that would
    /// beat everything already on the server.
    ///
    /// Returns whether anything moved. The caller owns `dirty` and the
    /// write of the book, exactly as cloud.js:201 does.
    @discardableResult
    mutating func stamp(_ tasks: inout [TaskItem], now: Int) -> Bool {
        var seen = Set<String>()
        var moved = false

        for i in tasks.indices {
            let id = tasks[i].id
            /* `if (!t || !t.id) continue` — an id that is absent or the
               empty string is not a task this book can say anything
               about. */
            guard !id.isEmpty else { continue }
            seen.insert(id)

            let sig = Self.sigOf(tasks[i])
            /* The missing-timestamp half matters exactly once per device:
               the first run over a store full of tasks that predate the
               field. Their content has not changed, so the signature
               alone would wave them through with nothing to compare
               against. `t.updatedAt` is a JS truthiness test, so 0 counts
               as missing. */
            let stamped = (tasks[i].updatedAt ?? 0) != 0
            if sigs[id]?.stringValue == sig && stamped { continue }

            /* Two saves inside the same millisecond would otherwise be a
               tie, and a tie is settled by whoever is asked last. Never
               go backwards and never repeat. */
            tasks[i].updatedAt = max(now, (tasks[i].updatedAt ?? 0) + 1)
            sigs.set(id, .string(sig))
            moved = true

            // Back from the dead — an undo, or the same id pulled down again.
            if graves[id]?.isTruthy == true { graves.removeValue(forKey: id) }
        }

        for id in sigs.keys where !seen.contains(id) {
            sigs.removeValue(forKey: id)
            graves.set(id, .int(now))
            moved = true
        }

        for (id, at) in graves.pairs where now - (at.intValue ?? 0) > Self.graveTTL {
            graves.removeValue(forKey: id)
            moved = true
        }

        return moved
    }

    /// Re-record every task as-is, without touching a timestamp
    /// (cloud.js:208-212). Run after a pull, so the copies that just came
    /// down are not read as local edits and pushed straight back.
    mutating func reseal(_ tasks: [TaskItem]) {
        sigs = JSONObject()
        for t in tasks where !t.id.isEmpty {
            sigs.set(t.id, .string(Self.sigOf(t)))
        }
    }

    // MARK: - On disk

    /// `{user, sigs, graves}` in that order — the shape `LegacyImport`
    /// writes and the shape the page kept in `localStorage`.
    var json: JSONValue {
        var o = JSONObject()
        o.set("user", user)
        o.set("sigs", .object(sigs))
        o.set("graves", .object(graves))
        return .object(o)
    }

    var jsonString: String { WebJSON.encode(json) }

    /// A book that will not parse is a book that gets rebuilt on the next
    /// stamp (cloud.js:94), which costs one extra push per task and never
    /// costs an edit.
    static func load(text: String?) -> CloudBook {
        var book = CloudBook()
        guard let text, !text.isEmpty,
              let parsed = try? JSONValue.parse(text),
              let o = parsed.objectValue
        else { return book }

        if let u = o["user"] { book.user = u }
        if let s = o["sigs"]?.objectValue { book.sigs = s }
        if let g = o["graves"]?.objectValue { book.graves = g }
        return book
    }

    static func read(from url: URL) -> CloudBook {
        load(text: try? String(contentsOf: url, encoding: .utf8))
    }

    /// Through a temp file and a replace, with the document's file
    /// protection, so a crash costs the write rather than the file.
    func write(to url: URL) {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])

        let temp = directory.appendingPathComponent(url.lastPathComponent + ".tmp")
        do {
            try Data(jsonString.utf8).write(to: temp, options: [.atomic])
            try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                  ofItemAtPath: temp.path)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.moveItem(at: temp, to: url)
        } catch {
            try? fm.removeItem(at: temp)
        }
    }
}
