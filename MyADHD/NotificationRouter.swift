/* ============================================================
   MyADHD/NotificationRouter.swift — what happens when one is tapped

   Without a delegate iOS does two unhelpful things: a notification that
   arrives while the app is open is thrown away unseen, and tapping one
   only opens the app wherever it was left. This is the delegate.

   - **In the foreground** it is shown as a banner, as it would be
     anywhere else — the nudge at one o'clock is no less true because the
     app happens to be open.
   - **A tap** opens the screen the notification was about: Home for a
     task or a nudge, Notes for a note's bell. `Reminders` writes which
     into `userInfo` under `Reminders.tabKey`.

   The tab is handed over twice on purpose. A tap on a running app posts
   `.myadhdOpenTab` and `AppShell` hears it; a tap that launched the app
   arrives before `AppShell` is listening, so it is also kept as `pending`
   for `boot()` to take.

   Set in `MyADHDApp.init`, which is before launch finishes — the only
   moment a delegate hears about the tap that did the launching.
   ============================================================ */

import Foundation
import UserNotifications

extension Notification.Name {
    /// `object` is an `AppTab.rawValue`.
    static let myadhdOpenTab = Notification.Name("myadhd.openTab")
}

final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationRouter()

    /// The tab a launching tap asked for, until `AppShell` takes it.
    @MainActor private var pending: AppTab?

    @MainActor func takePending() -> AppTab? {
        defer { pending = nil }
        return pending
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void)
    {
        done([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void)
    {
        let raw = response.notification.request.content.userInfo[Reminders.tabKey] as? String
        let tab = raw.flatMap(AppTab.init(rawValue:)) ?? .home
        Task { @MainActor in
            self.pending = tab
            NotificationCenter.default.post(name: .myadhdOpenTab, object: tab.rawValue)
            done()
        }
    }
}
