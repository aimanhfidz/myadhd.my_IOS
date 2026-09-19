/* ============================================================
   my.adhd for iOS — handing the wallpaper to Shortcuts

   Only Shortcuts can set a wallpaper, so the automation is the last step
   and this is what feeds it:

       Automation: Time of Day, 07:00, Run Immediately
         -> Update my.adhd wallpaper     (this intent, returns a PNG)
         -> Set Wallpaper Photo          (Apple's, with Show Preview off)

   Two things about this intent are load-bearing.

   openAppWhenRun is false. The whole point is that it runs at seven in
   the morning without bringing an app to the front, which means it runs
   with no scene, no window and no web view — and therefore cannot ask the
   page anything. It reads the keychain snapshot the app left behind
   instead. That is why TaskSnapshot came first.

   It never clears the wallpaper. Every failure throws, and a throw leaves
   whatever is on the lock screen where it is. A phone rebooted overnight
   and not yet unlocked cannot open the keychain at all
   (kSecAttrAccessibleAfterFirstUnlock), and yesterday's wallpaper is a
   great deal better than a blank one.
   ============================================================ */

import AppIntents
import SwiftUI
import UniformTypeIdentifiers

struct WallpaperIntent: AppIntent {
    static var title: LocalizedStringResource = "Update my.adhd wallpaper"
    static var description = IntentDescription(
        "Draws your next task as a picture and hands it back, for Set Wallpaper Photo to put on the lock screen."
    )

    /// The reason this exists at all. See the note at the top.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        /* The same read as every tile: the snapshot the app last wrote,
           with anything ticked on a widget since laid over it. Without the
           overlay a task ticked at ten last night is still "NEXT" on the
           seven o'clock lock screen, because the app has not been opened
           to drain the tick yet. */
        guard let snapshot = TaskStore.read()?.applying(OpQueue.peek().map(\.op))
        else { throw WallpaperError.noData }
        let url = try Wallpaper.render(snapshot)
        return .result(value: IntentFile(fileURL: url, filename: "myadhd-lock.png", type: .png))
    }
}

/// The same picture, for anyone who would rather drive it from the Photos
/// app or check it by hand. Opens the app on the setup sheet, which is
/// where the preview and the instructions are.
struct WallpaperSetupIntent: AppIntent {
    static var title: LocalizedStringResource = "Set up my.adhd wallpaper"
    static var description = IntentDescription("Opens the wallpaper instructions and a preview of your own.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Inbox.openWallpaperSetup()
        return .result()
    }
}
