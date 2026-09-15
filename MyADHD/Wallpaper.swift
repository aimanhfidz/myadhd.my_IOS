/* ============================================================
   my.adhd for iOS — the lock screen, drawn as a picture

   iOS will not let an app repaint a lock screen. What it will let you do
   is hand Shortcuts an image, and Shortcuts can set a wallpaper — so this
   draws one and WallpaperIntent.swift hands it over.

   Rendered with SwiftUI's ImageRenderer rather than by snapshotting a web
   view, which is the house pattern in docs/carousel/render.swift. Four
   reasons, in the order they mattered:

   1. It draws the same views the widget draws. A web-view version would
      be a second design of the same thing, kept in agreement by hand for
      ever.
   2. That renderer is a macOS command-line tool. Offscreen takeSnapshot
      on iOS is unreliable without a window in the hierarchy — blank
      frames, or a paint before layout.
   3. The app already has exactly one WKWebView, holding a live session
      and a page somebody is mid-thought in. A wallpaper must not disturb
      it, and cannot borrow it.
   4. The intent runs headless. At 07:00 there may be no scene at all,
      which rules out anything that needs a window.

   What it costs: the web app's face is a web font. So Baloo 2 is bundled
   here too (Info.plist, UIAppFonts) — a second copy of
   fonts/Baloo2-Variable.ttf that has to move when that one does.
   ============================================================ */

import SwiftUI
import UIKit

enum WallpaperError: Error {
    case noData          // nothing to draw — keep yesterday's rather than blanking it
    case couldNotRender
}

enum Wallpaper {

    /// Where the picture lives. Documents, not caches and not tmp: the
    /// Shortcut may run days after the app was last opened, and both of
    /// those can be reaped in between.
    static var url: URL {
        let dir = URL.documentsDirectory.appendingPathComponent("wallpaper", isDirectory: true)
        return dir.appendingPathComponent("lock.png")
    }

    private static let lastRunKey = "myadhd.wallpaper.lastRun"

    static var lastRun: Date? {
        UserDefaults.standard.object(forKey: lastRunKey) as? Date
    }

    /// Ground truth for whether the automation is actually working, which
    /// is what lets the setup sheet stop nagging once it is.
    ///
    /// It is a UserDefaults date rather than the file's own modification
    /// time on purpose: reading a file timestamp is a required-reason API
    /// (C617.1) and UserDefaults is already declared (CA92.1), so this
    /// keeps PrivacyInfo.xcprivacy exactly as it is. Write the file, never
    /// stat it.
    static func markRun(_ when: Date = Date()) {
        UserDefaults.standard.set(when, forKey: lastRunKey)
    }

    // MARK: - drawing

    @MainActor
    static func render(_ snapshot: TaskSnapshot, theme: String = ShellState.rememberedTheme) throws -> URL {
        let size = UIScreen.main.bounds.size          // points
        let scale = UIScreen.main.scale

        let view = WallpaperView(snapshot: snapshot, dark: theme != "light")
            .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: view)
        /* Size to the actual screen and render at its scale rather than to
           a fixed 1290x2796: iOS crops a wallpaper that does not match
           instead of scaling it, and what it crops is the edges. */
        renderer.scale = scale
        renderer.isOpaque = true

        guard let image = renderer.uiImage, let png = image.pngData() else {
            throw WallpaperError.couldNotRender
        }

        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)

        /* It is a drawing of data the user can see anyway, but it is still
           a picture of their day sitting in a backup. */
        var marked = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? marked.setResourceValues(values)

        markRun()
        return url
    }
}
