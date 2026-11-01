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

    private static let lastConfirmedKey = "myadhd.wallpaper.lastConfirmed"

    /// When the shortcut last got all the way to its end — past Set
    /// Wallpaper Photo — and ran `WallpaperConfirmIntent`. `lastRun` only
    /// proves the picture was drawn; this proves it was put on the lock
    /// screen, because Shortcuts stops a shortcut at the first action that
    /// fails and never reaches the confirm step.
    static var lastConfirmed: Date? {
        UserDefaults.standard.object(forKey: lastConfirmedKey) as? Date
    }

    static func markConfirmed(_ when: Date = Date()) {
        UserDefaults.standard.set(when, forKey: lastConfirmedKey)
    }

    // MARK: - what the last picture showed

    private static let lastDrawnKey = "myadhd.wallpaper.lastDrawn"

    /// WallpaperMode's digest of the board as it was last drawn, so the
    /// next run can tell that nothing moved and skip. WallpaperMode.swift.
    static var lastDrawnDigest: String? {
        UserDefaults.standard.string(forKey: lastDrawnKey)
    }

    /// The digest the board would be drawn with now.
    static func digest(of board: WallpaperBoard) -> String? {
        WallpaperMode.digest(board, style: style, day: WebDates.dayKey())
    }

    /// The photo is not in the digest, so a new one has to be forgotten
    /// into it — or the next run would see an unchanged board and skip.
    private static func forgetDrawn() {
        UserDefaults.standard.removeObject(forKey: lastDrawnKey)
    }

    private static let forceRedrawKey = "myadhd.wallpaper.forceRedraw"

    /// The page's escape hatch for a lock screen that keeps the old
    /// picture: the shortcut sets it, sets it again on the wallpaper that
    /// came back, and switches to that one. Off unless somebody needs it.
    static var forceRedraw: Bool {
        get { UserDefaults.standard.bool(forKey: forceRedrawKey) }
        set { UserDefaults.standard.set(newValue, forKey: forceRedrawKey) }
    }

    // MARK: - what the Lock Screen Display page set

    private static let styleKey = "myadhd.wallpaper.style"

    /// Read on every run, so a change on the page lands the next time the
    /// Shortcut fires — the app cannot repaint a lock screen any sooner.
    /// Anything unreadable is the defaults, which are the picture as it
    /// was before the page existed.
    static var style: WallpaperStyle {
        get {
            guard let data = UserDefaults.standard.data(forKey: styleKey),
                  let style = try? JSONDecoder().decode(WallpaperStyle.self, from: data)
            else { return WallpaperStyle() }
            return style
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: styleKey)
        }
    }

    // MARK: - drawing

    @MainActor
    static func render(_ board: WallpaperBoard) throws -> URL {
        try draw(board, to: url)
        markRun()
        UserDefaults.standard.set(digest(of: board), forKey: lastDrawnKey)
        return url
    }

    /// The Home Screen half of the pair, for Lock Screen only: the same
    /// ground with no boxes, so the icons sit on the person's own photo.
    /// Stamps nothing — the lock screen picture is what the health page
    /// and the skip are about.
    static var homeURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("home.png")
    }

    @MainActor
    static func renderHome() throws -> URL {
        try draw(WallpaperBoard(quads: []), to: homeURL)
    }

    @MainActor
    private static func draw(_ board: WallpaperBoard, to url: URL) throws -> URL {
        let size = UIScreen.main.bounds.size          // points
        let scale = UIScreen.main.scale

        let view = WallpaperView(board: board, background: loadBackground(), style: style)
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
        return url
    }

    // MARK: - the person's own photo

    /* The matrix is drawn over a picture the person chose, because the
       lock screen is theirs: Set Wallpaper Photo replaces the photo
       outright, so without this it would replace their wallpaper with
       ours. Picked once in the setup sheet, kept beside lock.png, and read
       on every run — the Shortcut never has to pass it in. */

    static var backgroundURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("background.jpg")
    }

    /// Takes whatever the picker handed over, sizes it to this screen's
    /// pixels (filled, not fitted, the way the wallpaper draws it) and
    /// keeps a JPEG. A 48MP original would otherwise be decoded on every
    /// run, inside an intent's memory budget.
    @MainActor
    @discardableResult
    static func saveBackground(_ data: Data) -> Bool {
        guard let jpeg = sized(data) else { return false }

        let dir = backgroundURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? jpeg.write(to: backgroundURL, options: .atomic)) != nil else { return false }

        /* Their photo is already in their library; this copy can be made
           again from there and has no business in a backup. */
        noBackup(backgroundURL)
        forgetDrawn()
        return true
    }

    /// A picked photo as a JPEG at this screen's pixels, filled not fitted.
    @MainActor
    private static func sized(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let target = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale

        let ratio = max(target.width / image.size.width, target.height / image.size.height)
        let drawn = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let sized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(x: (target.width - drawn.width) / 2,
                                  y: (target.height - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
        }
        return sized.jpegData(compressionQuality: 0.88)
    }

    private static func noBackup(_ url: URL) {
        var marked = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? marked.setResourceValues(values)
    }

    static func clearBackground() {
        try? FileManager.default.removeItem(at: backgroundURL)
        forgetDrawn()
    }

    /// The photo behind today's design: today's pick from the daily set
    /// when that is on and has anything in it, otherwise the one photo.
    /// Every reader goes through here — the shelf, the setup page and
    /// the 07:00 shortcut — so they cannot disagree about which.
    static func loadBackground(on day: String = WebDates.dayKey()) -> CGImage? {
        let url = dailyPhotoURL(on: day) ?? backgroundURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)?.cgImage
    }

    // MARK: - a new photo every day

    /* Ink's "New photo every day", from photos the person picks rather
       than stock ones. They are kept beside background.jpg, sized the
       same way, and taken in turn: day N of the calendar shows photo
       N mod count, so the order is stable, nothing has to remember which
       came last, and the 07:00 run needs no app to have opened first.

       The board digest already has the day in it (WallpaperMode), so each
       morning's first run draws again on its own; changing the set
       forgets the last digest like a new single photo does. */

    private static let dailyKey = "myadhd.wallpaper.dailyPhoto"
    private static let dailySetKey = "myadhd.wallpaper.dailyPhotos"

    static var dailyPhoto: Bool {
        get { UserDefaults.standard.bool(forKey: dailyKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: dailyKey)
            forgetDrawn()
        }
    }

    /// File names, in the order they were picked.
    static var dailyPhotoNames: [String] {
        UserDefaults.standard.stringArray(forKey: dailySetKey) ?? []
    }

    private static var dailyDir: URL {
        url.deletingLastPathComponent().appendingPathComponent("daily", isDirectory: true)
    }

    /// Which of the set a day shows, or nil when there is none to show.
    static func dailyIndex(on day: String, count: Int) -> Int? {
        guard count > 0, let n = DayKey.between("2026-01-01", day) else { return nil }
        return ((n % count) + count) % count
    }

    static func dailyPhotoURL(on day: String) -> URL? {
        guard dailyPhoto else { return nil }
        let names = dailyPhotoNames
        guard let i = dailyIndex(on: day, count: names.count) else { return nil }
        return dailyDir.appendingPathComponent(names[i])
    }

    /// Replaces the whole set. Photos that will not decode are skipped;
    /// returns how many were kept.
    @MainActor
    @discardableResult
    static func saveDailyPhotos(_ picked: [Data]) -> Int {
        let fm = FileManager.default
        try? fm.removeItem(at: dailyDir)
        try? fm.createDirectory(at: dailyDir, withIntermediateDirectories: true)
        var names: [String] = []
        for data in picked {
            guard let jpeg = sized(data) else { continue }
            let name = UUID().uuidString + ".jpg"
            let file = dailyDir.appendingPathComponent(name)
            guard (try? jpeg.write(to: file, options: .atomic)) != nil else { continue }
            noBackup(file)
            names.append(name)
        }
        UserDefaults.standard.set(names, forKey: dailySetKey)
        forgetDrawn()
        return names.count
    }

    /// The set as small pictures for the setup page, in order.
    static func dailyThumbnails(limit: Int) -> [CGImage] {
        dailyPhotoNames.prefix(limit).compactMap { name in
            guard let data = try? Data(contentsOf: dailyDir.appendingPathComponent(name)) else { return nil }
            return UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 120, height: 240))?.cgImage
        }
    }
}
