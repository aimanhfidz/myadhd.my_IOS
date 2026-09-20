/* ============================================================
   my.adhd for iOS — the whole of `myadhd.v1`

   The document, not a translation of it. app.js:222-256 is the literal
   that fixes the key order; app.js:258-289 is `load()`, which is ported
   here rule for rule including the two that look like tidying and are
   not:

   - `Object.assign(state, saved)` copies EVERY saved top-level key,
     known or not, and `JSON.stringify(state)` writes them all back. A
     key this build has never heard of is a key a newer web build wrote,
     and dropping it would erase it for every device on the next sync.
     `extra` carries them, in saved order, after `doneCounts` — which is
     exactly where `Object.assign` puts them, since the eight known keys
     already have their places from the literal.

   - `delete state.energy` — the fuel selector is gone, but a store
     written while it existed still carries the choice, and the assign
     would copy it straight back in. It comes off once, here. It is the
     ONE key deliberately lost.

   The `view` rule, and why it reads the way it does: the page forces
   `'list'` unless it is running inside the shell AND the saved value is
   `'matrix'`. **The native app IS the shell**, so a saved `'matrix'` is
   honoured. Anything else — including a value neither word — becomes
   `'list'`, which is a real write-back, not a render default.

   Tasks are NOT normalised on load and ids are never minted on read.
   Notes ARE (app.js:271), which is also where the web drops unknown
   note keys.
   ============================================================ */

import Foundation

/// `profile` — this device only; there is no account behind it.
public struct Profile: Equatable {
    public static let defaultAvatar = "🧔🏻"

    public var nameValue: JSONValue
    public var avatarValue: JSONValue
    /// Profile keys this build has never heard of, in saved order.
    public var extra: JSONObject

    public init(name: String = "", avatar: String = Profile.defaultAvatar) {
        self.nameValue = .string(name)
        self.avatarValue = .string(avatar)
        self.extra = JSONObject()
    }

    /// ≤24 on the way in (app.js:5570).
    public var name: String {
        get { nameValue.stringValue ?? "" }
        set { nameValue = .string(Normalize.slice(newValue, 24)) }
    }

    /// An emoji this build cannot draw is still the person's choice:
    /// `avatarFace` renders an unknown one as the default and never
    /// writes it back (app.js:3881). So is this.
    public var avatar: String {
        get { avatarValue.stringValue ?? Profile.defaultAvatar }
        set { avatarValue = .string(newValue) }
    }

    public var json: JSONValue {
        var o = JSONObject()
        o["name"] = nameValue
        o["avatar"] = avatarValue
        for (k, v) in extra where k != "name" && k != "avatar" { o[k] = v }
        return .object(o)
    }

    /// `Object.assign({ name: '', avatar: '🧔🏻' }, saved.profile || {})`
    public static func load(_ v: JSONValue?) -> Profile {
        var p = Profile()
        guard let o = v?.objectValue else { return p }
        if let n = o["name"] { p.nameValue = n }
        if let a = o["avatar"] { p.avatarValue = a }
        for (k, value) in o where k != "name" && k != "avatar" { p.extra[k] = value }
        return p
    }
}

public struct StoreDocument: Equatable {

    /// The localStorage key the web app writes, and the one the shell's
    /// `Storage.prototype.setItem` patch listens for. The version is the
    /// key name; there is no version field inside the JSON.
    public static let storeKey = "myadhd.v1"

    /// app.js:222-256, in order.
    public static let baseKeys = [
        "tasks", "notes", "profile", "sentFeedbackOn",
        "signupOfferHidden", "view", "gcalOrphans", "doneCounts",
    ]

    /// Dropped on load and never written again.
    public static let deadKeys = ["energy"]

    public var tasks: [TaskItem] = []
    public var notes: [NoteItem] = []
    public var profile = Profile()
    /// The UTC day of the last note sent from this device (`utcDay()`,
    /// app.js:2654) — UTC so a timezone cannot buy a second go.
    public var sentFeedbackOn: String?
    /// The onboarding offer, once turned down, stays turned down.
    public var signupOfferHidden = false
    /// 'list' or 'matrix'.
    public var view = "list"
    /// Google event ids whose task no longer exists to hang them off.
    public var gcalOrphans: [String] = []
    /// "YYYY-MM-DD" (LOCAL day) -> n, written only by pruneDone, ≤400 keys.
    public var doneCounts = JSONObject()
    /// Unknown top-level keys, in saved order, re-emitted after `doneCounts`.
    public var extra = JSONObject()

    public init() {}

    // MARK: - reading

    /// app.js:258-289. `inShell` exists so the check harness can prove
    /// both branches; the app always passes `true`, because it is.
    public static func load(_ saved: JSONValue?,
                            inShell: Bool = true,
                            now: Double = Date().timeIntervalSince1970 * 1000) -> StoreDocument
    {
        var s = StoreDocument()
        guard let o = saved?.objectValue else { return s }

        if let raw = o["tasks"]?.arrayValue {
            s.tasks = raw.compactMap { TaskItem($0) }
        }
        /* Array.isArray(saved.notes) ? map(normalizeNote) : [] — the
           assign above would otherwise leave a stray non-array from a
           hand-edited store for the renderer to fall over on. */
        if let raw = o["notes"]?.arrayValue {
            s.notes = raw.map { NoteItem.normalize($0, now: now) }
        }
        s.profile = Profile.load(o["profile"])
        if let v = o["sentFeedbackOn"] { s.sentFeedbackOn = v.stringValue }
        if let v = o["signupOfferHidden"] { s.signupOfferHidden = v.boolValue == true }
        if let v = o["view"] { s.view = v.stringValue ?? "list" }
        if let raw = o["gcalOrphans"]?.arrayValue {
            s.gcalOrphans = raw.compactMap { $0.stringValue }
        }
        if let counts = o["doneCounts"]?.objectValue { s.doneCounts = counts }

        for (k, v) in o where !baseKeys.contains(k) && !deadKeys.contains(k) {
            s.extra[k] = v
        }

        if !inShell || s.view != "matrix" { s.view = "list" }
        return s
    }

    public static func load(text: String, inShell: Bool = true) -> StoreDocument {
        guard let v = try? JSONValue.parse(text) else { return StoreDocument() }
        return load(v, inShell: inShell)
    }

    /// A corrupt store starts fresh rather than crashing (the try/catch
    /// around `JSON.parse`, app.js:288) — but the caller quarantines the
    /// file first; nothing here overwrites it.
    public static func load(data: Data, inShell: Bool = true) -> StoreDocument {
        guard let v = try? JSONValue.parse(data) else { return StoreDocument() }
        return load(v, inShell: inShell)
    }

    // MARK: - writing

    public var json: JSONValue {
        var o = JSONObject()
        o["tasks"] = .array(tasks.map { $0.json })
        o["notes"] = .array(notes.map { $0.json })
        o["profile"] = profile.json
        o["sentFeedbackOn"] = sentFeedbackOn.map { .string($0) } ?? .null
        o["signupOfferHidden"] = .bool(signupOfferHidden)
        o["view"] = .string(view)
        o["gcalOrphans"] = .array(gcalOrphans.map { .string($0) })
        o["doneCounts"] = .object(doneCounts)
        for (k, v) in extra where !Self.baseKeys.contains(k) { o[k] = v }
        return .object(o)
    }

    /// `JSON.stringify(state)` — the exact bytes that go to disk, to
    /// `TaskBridge.write(from:)` and into `Reminders.sync(json:)`.
    public var jsonString: String { WebJSON.encode(json) }

    public var data: Data { Data(jsonString.utf8) }

    // MARK: - small conveniences the rest of the app will want

    public func task(id: String) -> TaskItem? { tasks.first { $0.id == id } }
    public func index(ofTask id: String) -> Int? { tasks.firstIndex { $0.id == id } }
    public func note(id: String) -> NoteItem? { notes.first { $0.id == id } }
    public func index(ofNote id: String) -> Int? { notes.firstIndex { $0.id == id } }

    /// `doneCounts` as a plain map. The ordered form is the stored one,
    /// because `pruneDone` drops the oldest keys and the order is what
    /// the page writes back.
    public var doneCountsMap: [String: Int] {
        var out: [String: Int] = [:]
        for (k, v) in doneCounts { if let n = v.intValue { out[k] = n } }
        return out
    }

    public func doneCount(_ day: String) -> Int { doneCounts[day]?.intValue ?? 0 }

    public mutating func setDoneCount(_ day: String, _ n: Int) {
        doneCounts[day] = .int(n)
    }

    public mutating func removeDoneCount(_ day: String) {
        doneCounts.removeValue(forKey: day)
    }
}
