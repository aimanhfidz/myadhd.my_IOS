/* ============================================================
   my.adhd for iOS — what the widget is allowed to know

   A widget's timeline provider runs in its own process, on iOS's
   schedule, with no web view anywhere near it. Reminders.swift can ask
   the page for the task list because it runs inside the app while the
   page is alive; nothing here can. So the app pushes a snapshot out to
   somewhere both processes can reach, and the widget reads that.

   Somewhere is the keychain, for the same reason DumpQueue is there: an
   App Group container needs an entitlement a free developer account is
   not given, and the development profile already allows a shared
   keychain group across the team prefix. No access group is named in
   this file either — an unspecified group means "the first one in my
   entitlement", and all three targets list exactly one and the same.

   Two differences from DumpQueue, both deliberate:

   - It is ONE item, upserted, not a queue. A queue is right for shares,
     where two in quick succession must both survive. This is a picture
     of the list as it stands, and the newest one is the only one worth
     having.

   - Its own service string, so DumpQueue.drain() — which matches on
     service and deletes as it reads — can never eat it.
   ============================================================ */

import Foundation
import Security

// MARK: - the model

/// One task, trimmed to what a widget can actually draw. Deliberately not
/// the web app's whole task: `steps`, `gcal`, `local` and the rest are of
/// no use on a 160pt tile and would spend the size budget.
struct SnapTask: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let minutes: Int
    let at: String?          // "HH:MM", or nil when it is not booked into a time
    let category: String
    let energy: String
    let urgency: Int         // 1...5
    let importance: String?  // "low" | "high". Optional on purpose — see below.
    let firstStep: String?
    let done: Bool

    /// Short keys because every byte here is a byte of a keychain item.
    enum CodingKeys: String, CodingKey {
        case id = "i", title = "n", minutes = "m", at = "a", category = "c"
        case energy = "e", urgency = "u", importance = "p", firstStep = "f", done = "d"
    }
}

struct TaskSnapshot: Codable, Equatable {
    let generated: Date
    let day: String          // "YYYY-MM-DD", the local day this describes
    let tasks: [SnapTask]
    let dropped: Int         // cut for size; drawn as "+N" rather than pretended away

    enum CodingKeys: String, CodingKey {
        case generated = "g", day = "d", tasks = "t", dropped = "x"
    }

    /// The next thing, which is the whole product in one line: soonest
    /// first, then most urgent, then shortest.
    var next: SnapTask? {
        tasks.filter { !$0.done }.min { a, b in
            let ka = a.at ?? "99:99", kb = b.at ?? "99:99"
            if ka != kb { return ka < kb }
            if a.urgency != b.urgency { return a.urgency > b.urgency }
            return a.minutes < b.minutes
        }
    }

    var timed: [SnapTask] { tasks.filter { $0.at != nil } }
    var untimed: [SnapTask] { tasks.filter { $0.at == nil && !$0.done } }

    /// A snapshot nobody has refreshed in a day is still worth drawing —
    /// it is just not worth drawing as if it were current.
    func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(generated) > 24 * 60 * 60
    }
}

// MARK: - the drawer

enum TaskStore {

    /// Not "myadhd.dump.queue". DumpQueue.drain() matches every item on
    /// its own service and deletes what it reads; sharing one would make
    /// opening the app eat the widget's data.
    private static let service = "myadhd.task.snapshot"

    /// One item, always this account.
    private static let account = "current"

    /// A lock-screen widget and a 07:00 wallpaper automation both run
    /// before anybody has touched the phone that morning, so anything
    /// stricter than first unlock would leave both of them blank.
    private static let accessible = kSecAttrAccessibleAfterFirstUnlock

    /// What a snapshot is allowed to weigh once compressed. There is no
    /// documented ceiling on kSecValueData and the undocumented one is not
    /// worth leaning on, so this is a budget rather than a limit — the
    /// trimming in TaskBridge aims at it and the shrink loop enforces it.
    static let budget = 16 * 1024

    // MARK: writing

    @discardableResult
    static func write(_ snapshot: TaskSnapshot) -> Bool {
        guard let blob = encode(snapshot) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let fields: [String: Any] = [
            kSecValueData as String: blob,
            kSecAttrAccessible as String: accessible,
        ]

        let updated = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        var item = query
        item[kSecValueData as String] = blob
        item[kSecAttrAccessible as String] = accessible
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    // MARK: reading

    /// nil means "I could not read it", never "there is nothing". Every
    /// caller treats nil as keep-showing-what-you-had, because the phone
    /// being locked since boot looks exactly like an empty list otherwise.
    static func read() -> TaskSnapshot? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let blob = out as? Data else { return nil }
        return decode(blob)
    }

    @discardableResult
    static func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: the wire format

    /// One version byte, then zlib. The byte is what lets a future shape
    /// be refused rather than half-read: anything that is not a 1 is not
    /// something this build knows how to open.
    private static let version: UInt8 = 1

    static func encode(_ snapshot: TaskSnapshot) -> Data? {
        let coder = JSONEncoder()
        coder.dateEncodingStrategy = .secondsSince1970
        guard let json = try? coder.encode(snapshot),
              let squeezed = try? (json as NSData).compressed(using: .zlib) as Data
        else { return nil }
        return Data([version]) + squeezed
    }

    static func decode(_ blob: Data) -> TaskSnapshot? {
        guard let first = blob.first, first == version, blob.count > 1 else { return nil }
        let body = Data(blob.dropFirst())
        guard let json = try? (body as NSData).decompressed(using: .zlib) as Data else { return nil }
        let coder = JSONDecoder()
        coder.dateDecodingStrategy = .secondsSince1970
        return try? coder.decode(TaskSnapshot.self, from: json)
    }
}
