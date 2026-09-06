/* ============================================================
   my.adhd for iOS — the handover between two processes

   A share extension runs in its own sandbox and cannot see the app's
   web view, so it cannot write a task. All it can do is leave the text
   somewhere the app will look, and the app has to drain that on its way
   back to the front.

   The usual place is an App Group container, which needs an entitlement
   a free developer account is not given. This uses the keychain instead,
   which the development profile already allows across the whole team
   prefix — so the extension and the app share a queue with nothing
   bought and nothing hacked.

   No access group is named anywhere in here on purpose. An unspecified
   group means "the first one in my entitlement", and both targets list
   exactly one and the same, so they land in the same drawer without a
   team id ever appearing in tracked source.

   The keychain is for secrets rather than queues, which is a fair thing
   to raise — but a brain dump is private speech, and this is a handful
   of short strings that exist for the seconds between sharing something
   and opening the app. It is the right drawer for the contents even if
   it is an unusual one for the shape.
   ============================================================ */

import Foundation
import Security

enum DumpQueue {

    /// Everything queued shares this, so draining is one query.
    private static let service = "myadhd.dump.queue"

    /// Written by an extension that may be running while the phone is
    /// locked, read by an app that may be woken in the background — so
    /// the item has to survive both, and first unlock is the weakest
    /// accessibility that does.
    private static let accessible = kSecAttrAccessibleAfterFirstUnlock

    // MARK: - the extension's end

    /// One item per share. A single item holding an array would need a
    /// read, a merge and a write, and two shares in quick succession
    /// would lose one of them.
    @discardableResult
    static func add(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }

        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: UUID().uuidString,
            kSecAttrAccessible as String: accessible,
            kSecValueData as String: data,
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - the app's end

    /// Everything waiting, oldest first, and gone from the queue by the
    /// time this returns. Read and delete together: a drain that left
    /// them behind would re-dump the same thought on every foreground.
    static func drain() -> [String] {
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

        let ordered = rows.sorted {
            let a = $0[kSecAttrCreationDate as String] as? Date ?? .distantPast
            let b = $1[kSecAttrCreationDate as String] as? Date ?? .distantPast
            return a < b
        }

        var out: [String] = []
        for row in ordered {
            if let data = row[kSecValueData as String] as? Data,
               let text = String(data: data, encoding: .utf8) {
                out.append(text)
            }
            if let account = row[kSecAttrAccount as String] as? String {
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                ] as CFDictionary)
            }
        }
        return out
    }

    /// What the app puts in the dump box. Separate lines because
    /// splitDump() in app.js treats a line as a thought, so three things
    /// shared before the app was next opened stay three things.
    static func drainedText() -> String? {
        let all = drain()
        return all.isEmpty ? nil : all.joined(separator: "\n")
    }
}
