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

/* These lived in WebScreen.swift, because the web view was the only thing
   that listened for them. It is gone; the two that are still posted live
   here, beside the code that posts them.

   `myadhd.reload` went with it: it was the retry button on the offline
   screen, and there is no offline screen in an app that opens without a
   connection. */
extension Notification.Name {
    /// A myadhd:// link, or the Shortcut, arriving while the app is up.
    /// A cold launch does not need it — `AppShell` drains the same inbox
    /// on boot, which is the whole reason `put` writes before it posts.
    static let myadhdOpen = Notification.Name("myadhd.open")
    /// Asked for by myadhd://wallpaper and by the Shortcuts phrase.
    static let myadhdWallpaper = Notification.Name("myadhd.wallpaper")
    /// myadhd://listen — the Dump control and the Action Button.
    static let myadhdListen = Notification.Name("myadhd.listen")
}

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

    /// Asks for the wallpaper setup sheet. Its own notification rather
    /// than a pending string: there is nothing to deliver, and a dump that
    /// is not a dump would have to be filtered out at the far end.
    ///
    /// `steps` opens it straight on the shortcut steps — the Home card's
    /// tap, for someone who has not set it up and has nothing to style yet.
    static func openWallpaperSetup(steps: Bool = false) {
        NotificationCenter.default.post(name: .myadhdWallpaper, object: steps ? stepsFlag : nil)
    }

    static let stepsFlag = "steps"

    // MARK: - Listening, from the Dump control

    private static let listenKey = "myadhd.pendingListen"

    /// Opens the composer with the mic already on. Written down first, like
    /// a dump, because the press may be what launches the app.
    static func listen() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: listenKey)
        NotificationCenter.default.post(name: .myadhdListen, object: nil)
    }

    /// Whether a press is waiting, without taking it. AppShell opens the
    /// composer on this; the mic takes it.
    static var listenWaiting: Bool { fresh(UserDefaults.standard.double(forKey: listenKey)) }

    /// Reads and clears. Ten seconds old at most: a press nobody acted on
    /// (no mic on this phone, a sort in the way) must not switch the mic
    /// on the next time somebody opens the composer by hand.
    static func takeListen() -> Bool {
        let at = UserDefaults.standard.double(forKey: listenKey)
        UserDefaults.standard.removeObject(forKey: listenKey)
        return fresh(at)
    }

    private static func fresh(_ at: Double) -> Bool {
        at > 0 && Date().timeIntervalSince1970 - at < 10
    }

    /// Three hosts now, and everything else is ignored rather than
    /// guessed at — `myadhd://auth` in particular belongs to
    /// ASWebAuthenticationSession's own callback and must never be
    /// swallowed here.
    ///
    ///   myadhd://dump?text=the%20rent%20thing
    ///   myadhd://open            — the widgets' tap target
    ///   myadhd://wallpaper       — the setup sheet (?steps: at the steps)
    ///   myadhd://listen          — a new dump, mic on (the Dump control)
    static func accept(url: URL) {
        guard url.scheme?.lowercased() == AppConfig.callbackScheme else { return }
        switch url.host?.lowercased() {
        case "dump":
            let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "text" }?.value ?? ""
            put(text)
        case "wallpaper":
            /* `?steps` is where a failed run of the shortcut lands
               (WallpaperShelf.runShortcut): most often a phone still on
               an older version, which needs the steps to get this one. */
            let steps = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains { $0.name == Self.stepsFlag } ?? false
            openWallpaperSetup(steps: steps)
        case "listen":
            listen()
        case "open":
            break   // the app coming to the front is the whole of it
        default:
            break
        }
    }
}
