/* ============================================================
   my.adhd for iOS — what the widget did, waiting for a page to tell

   A widget's AppIntent runs in the widget's own process. There is no web
   view there, so a tick cannot be written to the store the moment it
   happens; all it can do is leave a note somewhere the app will look, the
   way DumpQueue does for the share extension. Same drawer, same reason,
   same absence of a named access group.

   Two things here are deliberately NOT like DumpQueue.

   - Nothing in this file writes the snapshot. myadhd.task.snapshot has
     exactly one writer — TaskBridge, in the app — and it must stay that
     way. The snapshot is one upserted item, so a widget that read it,
     patched it and wrote it back would drop whatever the app wrote in
     between, and TaskBridge's change stamp would then compare equal to
     what IT last wrote and skip the repair. The widget would have quietly
     taken ownership of the item. Instead the widget appends here and the
     provider lays these ops over what it reads, so the tile is right
     immediately without anybody writing over anybody.

   - Reading does not delete. A dump is text that can go into a box
     unconditionally; a tick needs a live page to land in, and if the drain
     finds no page the op has to still be here afterwards. So: peek, apply,
     then drop exactly what the page confirmed.
   ============================================================ */

import Foundation
import Security

struct TaskOp: Codable, Equatable {

    enum Kind: String, Codable {
        case done = "d"
    }

    let kind: Kind
    let id: String
    let at: Date

    enum CodingKeys: String, CodingKey {
        case kind = "o", id = "i", at = "t"
    }

    static func done(_ id: String) -> TaskOp { TaskOp(kind: .done, id: id, at: Date()) }
}

enum OpQueue {

    /// Its own service. DumpQueue.drain() matches every item on ITS
    /// service and deletes what it reads, and TaskStore keeps a third —
    /// share a string with either and opening the app eats this.
    private static let service = "myadhd.op.queue"

    private static let accessible = kSecAttrAccessibleAfterFirstUnlock

    /// A queue nobody drains is a queue that has stopped meaning anything,
    /// and it should not be allowed to grow without limit in a drawer the
    /// user cannot see. Well above any plausible session of tapping.
    private static let ceiling = 64

    // MARK: - the widget's end

    /// One item per op, added under a fresh account and never updated.
    /// No read-modify-write anywhere in the widget process, so two taps in
    /// the same second are two items rather than one lost one.
    @discardableResult
    static func push(_ op: TaskOp) -> Bool {
        guard let data = try? JSONEncoder.op.encode(op) else { return false }
        guard count() < ceiling else { return false }

        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: UUID().uuidString,
            kSecAttrAccessible as String: accessible,
            kSecValueData as String: data,
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - reading, without taking

    /// Everything waiting, oldest first, still in the queue afterwards.
    /// Both processes call this: the app to apply, the widget to lay the
    /// pending ticks over the snapshot it just read.
    static func peek() -> [(account: String, op: TaskOp)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]] else { return [] }

        return rows.sorted {
            let a = $0[kSecAttrCreationDate as String] as? Date ?? .distantPast
            let b = $1[kSecAttrCreationDate as String] as? Date ?? .distantPast
            return a < b
        }.compactMap { row in
            guard let account = row[kSecAttrAccount as String] as? String,
                  let data = row[kSecValueData as String] as? Data,
                  let op = try? JSONDecoder.op.decode(TaskOp.self, from: data)
            else { return nil }
            return (account, op)
        }
    }

    // MARK: - the app's end

    /// Exactly the ones the page said it had taken. Anything the page did
    /// not confirm stays, and is tried again on the next foreground.
    static func drop(_ accounts: [String]) {
        for account in accounts {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        }
    }

    /// An op that has been sitting here for two days is not going to land:
    /// the task it names has very likely been pruned, and re-ticking
    /// something the user finished on Tuesday is worse than forgetting it.
    static func sweep(olderThan seconds: TimeInterval = 48 * 60 * 60) {
        let cutoff = Date().addingTimeInterval(-seconds)
        drop(peek().filter { $0.op.at < cutoff }.map(\.account))
    }

    private static func count() -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]] else { return 0 }
        return rows.count
    }
}

private extension JSONEncoder {
    static let op: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
}

private extension JSONDecoder {
    static let op: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

// MARK: - laying them over what was read

extension TaskSnapshot {

    /// The pending ticks, drawn as if they had already landed. Pure, and
    /// idempotent — an op for a task the snapshot already calls done
    /// changes nothing, which is what makes the moment the app drains
    /// invisible: the op disappears and the fresh snapshot says the same
    /// thing, in the same instant.
    func applying(_ ops: [TaskOp]) -> TaskSnapshot {
        guard !ops.isEmpty else { return self }
        let ticked = Set(ops.filter { $0.kind == .done }.map(\.id))
        guard !ticked.isEmpty else { return self }

        var flipped = 0
        let next = tasks.map { t -> SnapTask in
            guard ticked.contains(t.id), !t.done else { return t }
            flipped += 1
            return SnapTask(id: t.id, title: t.title, minutes: t.minutes, when: t.when,
                            at: t.at, category: t.category, energy: t.energy,
                            urgency: t.urgency, importance: t.importance,
                            firstStep: t.firstStep, done: true)
        }
        guard flipped > 0 else { return self }

        return TaskSnapshot(generated: generated, day: day, tasks: next, dropped: dropped,
                            doneToday: doneToday + flipped,
                            calFrom: calFrom, cal: cal, histFrom: histFrom, hist: hist)
    }
}
