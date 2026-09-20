/* ============================================================
   my.adhd for iOS — one task

   `TaskItem`, not `Task`: `Task` is Swift Concurrency's, and shadowing
   it inside an app that spawns any would be a very quiet disaster.

   Two rules from app.js, and everything here follows from them.

   1. **Reading never re-normalises.** `load()` (app.js:258-289) runs
      `normalizeNote` over the notes and nothing at all over the tasks.
      A row written before `importance` existed has no `importance` key,
      and it still has none after the page has read it, edited a
      different task and written the store back. So this type stores the
      keys it was given — present, absent, null, all three distinct —
      and applies defaults AT USE, the way every reader already does
      (TaskBridge.swift:145-154 is the existing example: minutes clamped
      2...240 to 20, urgency 1...5 to 3, category 'general', energy
      'medium', importance left optional).

   2. **An unknown key is a field a newer build writes.** The web's merge
      deletes every local key before assigning an arriving payload
      (cloud.js:290-293), so a client that silently drops a key erases it
      for every device the person owns. Unknown keys ride in `fields` and
      are re-emitted between `skipped` and `updatedAt`.

   `firstStep` defaults to the EMPTY STRING here, never to
   normalizeTask's "Open it and look at it for 2 minutes." — that
   placeholder is model output only, and the row renderer does
   `textContent = task.firstStep` with whatever is stored (app.js:1490).
   ============================================================ */

import Foundation

public struct TaskItem: Equatable {

    /// `normalizeTask`'s literal key order (app.js:1044-1068). `updatedAt`
    /// is appended by `cloud.stamp()` and is written last.
    public static let baseKeys = [
        "id", "title", "minutes", "energy", "urgency", "importance", "quadrant",
        "firstStep", "category", "when", "at", "steps", "local", "gcal",
        "done", "doneAt", "skipped",
    ]
    public static let tailKey = "updatedAt"

    /// Every key of this task exactly as stored, in stored order. The
    /// source of truth; the typed properties below are windows onto it.
    public var fields: JSONObject

    public init(fields: JSONObject = JSONObject()) { self.fields = fields }

    /// nil for a JSON value that is not an object — the page would have
    /// carried it and then fallen over on it; we drop it instead.
    public init?(_ value: JSONValue) {
        guard case .object(let o) = value else { return nil }
        self.fields = o
    }

    public var json: JSONValue { .object(encoded()) }

    /// Re-emitted in `normalizeTask` order: the base keys that are
    /// present, then any unknown keys in the order they were stored,
    /// then `updatedAt`. A key that is absent stays absent; a key whose
    /// value is null is written as `null`, never omitted.
    public func encoded() -> JSONObject {
        var out = JSONObject()
        for k in Self.baseKeys {
            if let v = fields[k] { out[k] = v }
        }
        for k in fields.keys where !Self.baseKeys.contains(k) && k != Self.tailKey {
            out[k] = fields[k]
        }
        if let v = fields[Self.tailKey] { out[Self.tailKey] = v }
        return out
    }

    /// The bytes the page would have written for this one task.
    public var jsonString: String { WebJSON.encode(.object(encoded())) }

    /// Keys this build has never heard of, in stored order.
    public var extra: JSONObject {
        var out = JSONObject()
        for k in fields.keys where !Self.baseKeys.contains(k) && k != Self.tailKey {
            out[k] = fields[k]
        }
        return out
    }

    public func has(_ key: String) -> Bool { fields.has(key) }
    public func raw(_ key: String) -> JSONValue? { fields[key] }

    // MARK: - the fields, with the defaults every reader applies

    public var id: String {
        get { fields["id"]?.stringValue ?? "" }
        set { fields["id"] = .string(newValue) }
    }

    public var title: String {
        get { fields["title"]?.stringValue ?? "" }
        set { fields["title"] = .string(newValue) }
    }

    /// Clamped 2...240, default 20 — the same reading TaskBridge does.
    public var minutes: Int {
        get { Normalize.clamp(fields["minutes"], 2, 240, 20) }
        set { fields["minutes"] = .int(newValue) }
    }

    /// The stored value verbatim, 'medium' when absent. An unrecognised
    /// value is kept and re-emitted; rendering it as the default is the
    /// renderer's business, not the store's (the avatar rule, app.js:3881).
    public var energy: String {
        get { fields["energy"]?.stringValue ?? "medium" }
        set { fields["energy"] = .string(newValue) }
    }

    /// Clamped 1...5, default 3.
    public var urgency: Int {
        get { Normalize.clamp(fields["urgency"], 1, 5, 3) }
        set { fields["urgency"] = .int(newValue) }
    }

    /// 'low' unless told otherwise — a task sorted before `importance`
    /// existed was never told it mattered (app.js:1051-1054).
    public var importance: String {
        get { fields["importance"]?.stringValue ?? "low" }
        set { fields["importance"] = .string(newValue) }
    }

    /// The person's own placement, or nil to derive it.
    public var quadrant: String? {
        get { fields["quadrant"]?.stringValue }
        set { fields["quadrant"] = newValue.map { .string($0) } ?? .null }
    }

    public var firstStep: String {
        get { fields["firstStep"]?.stringValue ?? "" }
        set { fields["firstStep"] = .string(newValue) }
    }

    public var category: String {
        get { fields["category"]?.stringValue ?? "general" }
        set { fields["category"] = .string(newValue) }
    }

    /// "YYYY-MM-DD", or nil for a task on no day.
    public var when: String? {
        get { fields["when"]?.stringValue }
        set { fields["when"] = newValue.map { .string($0) } ?? .null }
    }

    /// "HH:MM", or nil for a day with no clock on it.
    public var at: String? {
        get { fields["at"]?.stringValue }
        set { fields["at"] = newValue.map { .string($0) } ?? .null }
    }

    public var steps: [String]? {
        get {
            guard let a = fields["steps"]?.arrayValue else { return nil }
            return a.map { $0.stringValue ?? Normalize.jsString($0) }
        }
        set {
            fields["steps"] = newValue.map { .array($0.map { .string($0) }) } ?? .null
        }
    }

    /// Sorted by the offline parser rather than the model.
    public var local: Bool {
        get { fields["local"]?.boolValue == true }
        set { fields["local"] = .bool(newValue) }
    }

    public var done: Bool {
        get { fields["done"]?.boolValue == true }
        set { fields["done"] = .bool(newValue) }
    }

    /// Stamped by markDone, read by pruneDone. Epoch milliseconds.
    public var doneAt: Int? {
        get { fields["doneAt"]?.intValue }
        set { fields["doneAt"] = newValue.map { .int($0) } ?? .null }
    }

    /// Dead — nothing ever sets it true — but `TaskBridge` and
    /// `Reminders` test it by name and old web readers expect the shape,
    /// so `normalizeTask` writes `false` and we never drop it.
    public var skipped: Bool {
        get { fields["skipped"]?.boolValue == true }
        set { fields["skipped"] = .bool(newValue) }
    }

    /// `{ id, sig }` once this one has been pushed to Google.
    public var gcal: GCalRef? {
        get {
            guard let o = fields["gcal"]?.objectValue,
                  let id = o["id"]?.stringValue else { return nil }
            return GCalRef(id: id, sig: o["sig"]?.stringValue ?? "")
        }
        set {
            guard let newValue else { fields["gcal"] = .null; return }
            fields["gcal"] = .object(JSONObject([
                ("id", .string(newValue.id)),
                ("sig", .string(newValue.sig)),
            ]))
        }
    }

    /// Epoch milliseconds, written by `cloud.stamp()`. Absent on a task
    /// that has never been through a sync pass.
    public var updatedAt: Int? {
        get { fields[Self.tailKey]?.intValue }
        set { fields[Self.tailKey] = newValue.map { .int($0) } ?? .null }
    }

    public struct GCalRef: Equatable {
        public var id: String
        public var sig: String
        public init(id: String, sig: String) { self.id = id; self.sig = sig }
    }
}
