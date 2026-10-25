/* ============================================================
   my.adhd for iOS — telling Shortcuts the lock screen is out of date

   The shortcut can only run when an automation fires, and the obvious
   one — "my.adhd is closed" — misses the commonest exit of all: adding a
   task and pressing the side button with the app still open. The lock
   screen then shows the list from before the task, which is the exact
   moment it was supposed to be right.

   So on the way out, if what the picture would show has moved since the
   last one was drawn, the app posts one quiet notification. A
   "When my.adhd sends a notification" automation (iOS 27) catches it and
   runs the shortcut; the shortcut's confirm step takes the notification
   back down again. Ink does the same thing with a "·".

   It stays quiet for anyone it cannot help:

   - **Never confirmed** — no shortcut, or a broken one. A notification
     that triggers nothing is just noise.
   - **Nothing moved** — the digest matches the last drawing, so the
     wallpaper is already right.
   - **Notifications declined** — `add` fails silently, and the
     "is closed" automation still covers the swipe home.

   Passive, so it never lights the screen or buzzes, and one fixed id, so
   leaving twice replaces it rather than stacking a second.
   ============================================================ */

import Foundation
import UserNotifications

enum WallpaperPing {

    static let id = "myadhd.wallpaper.refresh"

    /// What the automation matches on: "Body contains lock screen".
    /// Change it and every hand-made automation stops firing.
    static let body = "Updating your lock screen"

    /// From `StoreBridge.leaving()`, once the store's last write has landed.
    @MainActor
    static func sendIfStale(file: StoreFile) {
        guard Wallpaper.lastConfirmed != nil else { return }
        guard let board = WallpaperBoard.current(file: file),
              let digest = Wallpaper.digest(of: board),
              digest != Wallpaper.lastDrawnDigest
        else { return }

        let content = UNMutableNotificationContent()
        content.title = "my.adhd"
        content.body = body
        content.interruptionLevel = .passive
        content.threadIdentifier = id

        /* A second, not zero: a trigger of nil delivers while the app is
           still technically active, and the router would show it as a
           banner over the app being left. */
        let request = UNNotificationRequest(
            identifier: id, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    /// The shortcut got to its end, or the app is back in front: the
    /// notification has done its job, or no longer needs to.
    static func clear() {
        let centre = UNUserNotificationCenter.current()
        centre.removePendingNotificationRequests(withIdentifiers: [id])
        centre.removeDeliveredNotifications(withIdentifiers: [id])
    }
}
