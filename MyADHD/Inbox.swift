/* ============================================================
   my.adhd for iOS — text arriving from outside the app

   Two doors in: the Shortcut in DumpIntent.swift, and a myadhd://dump link.
   Both hand over a thought that has to survive a cold launch, because both
   can fire while the app is not running and the web view that will hold the
   text does not exist yet.

   So nothing is delivered straight. It is written down first and the
   notification is a nudge; whoever picks it up takes it, and taking it is
   what clears it. A thought is the one thing this app is not allowed to
   drop on the floor.
   ============================================================ */

import Foundation

enum Inbox {

    private static let key = "myadhd.pendingDump"

    static func put(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: key)
        NotificationCenter.default.post(name: .myadhdOpen, object: trimmed)
    }

    /// Reads and clears in one move, so the same thought cannot arrive twice.
    @discardableResult
    static func take() -> String? {
        guard let text = UserDefaults.standard.string(forKey: key) else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        return text
    }

    /// myadhd://dump?text=the%20rent%20thing
    static func accept(url: URL) {
        guard url.scheme?.lowercased() == AppConfig.callbackScheme,
              url.host?.lowercased() == "dump" else { return }
        let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "text" }?.value ?? ""
        put(text)
    }
}
