/* ============================================================
   my.adhd for iOS — does the lock screen need drawing again?

   The shortcut asks this first (WallpaperModeIntent) and branches on the
   answer, so what it does can change in an app update without anybody
   reinstalling it. That is the one idea worth taking from Ink's shortcut.

       skip     nothing on the board moved since the last picture that
                reached the lock screen — stop before Set Wallpaper Photo
       set      draw, set, switch to it, confirm
       redraw   set, set again on the wallpaper that came back, and switch
                to it — for a lock screen that keeps showing the old picture

   and, after set or redraw, which screens: `answer` below.

   Skip is what makes the frequent triggers affordable. "my.adhd is
   closed" and "a notification from my.adhd" fire many times a day, and
   without it every one of them would flash an identical wallpaper.

   It only skips a picture that was *confirmed* — the confirm stamp at or
   after the drawing. A drawing whose run never reached the confirm step
   never reached the lock screen, so it is drawn again rather than trusted. And the day is in the digest, so
   at least one run a day really sets — which is what keeps the 36-hour
   "stalled" rule in WallpaperHealth.swift honest.

   Pure, and UIKit-free, so Checks/wallpaper-mode.swift can hold it to
   every case on a Mac.
   ============================================================ */

import Foundation

private struct Extras: Encodable {
    let focus: WallpaperBoard.Focus?
    let agenda: [WallpaperBoard.Row]
    let month: WallpaperBoard.Month?
    let done: WallpaperBoard.Done?
}

enum WallpaperMode: String {
    case skip, set, redraw

    /// nil digest means the board could not be read. Never skip on that:
    /// `set` sends the run on to WallpaperIntent, which throws `noData`
    /// and leaves yesterday's wallpaper where it is.
    static func decide(digest: String?, lastDrawn: String?,
                       lastRun: Date?, lastConfirmed: Date?,
                       forceRedraw: Bool) -> WallpaperMode
    {
        /* Confirmed at or after the drawing, with no slack. In a run that
           worked the confirm always comes after the draw; a confirm from
           before it is the previous run's, and this drawing never reached
           the lock screen. Seen on a device: a run started with the phone
           locked drew at 04:34:27, died before the confirm, and the 2-minute
           slack this used to allow read the 04:34:06 confirm as its own. */
        if let digest, digest == lastDrawn,
           let lastRun, let lastConfirmed,
           lastConfirmed >= lastRun {
            return .skip
        }
        return forceRedraw ? .redraw : .set
    }

    /// What WallpaperModeIntent hands the shortcut: words, each tested
    /// with "contains", so they combine. Never more than the mode on a
    /// skip — a skip sets nothing.
    ///
    ///     same    one picture on the Lock Screen and the Home Screen
    ///     pair    the Lock Screen, then the plain ground on the Home
    ///             Screen of the same wallpaper (Lock Screen only)
    ///     blur    that Home Screen blurred (Legibility Blur)
    ///     home    pair's old name, still said for shortcut v2, which
    ///             tests "home" and knows neither of the others
    ///
    /// The shape is Ink's "Refresh Lock Screen V2" as re-cut by 2026-11:
    /// same / pair / blur / redraw, and a switch to the wallpaper it set.
    static func answer(_ mode: WallpaperMode, lockOnly: Bool, homeBlur: Bool = false) -> String {
        guard mode != .skip else { return mode.rawValue }
        var words = [mode.rawValue, lockOnly ? "pair home" : "same"]
        if homeBlur { words.append("blur") }
        return words.joined(separator: " ")
    }

    /// What the picture would show, as a stable string: every box's key
    /// and titles in order, the style with its keys sorted, and the day.
    /// Not hashValue — Swift seeds it per process, and the stamp has to
    /// survive from one run to the next. The background photo is not in
    /// here; saving or clearing it forgets the last digest instead.
    static func digest(_ board: WallpaperBoard, style: WallpaperStyle, day: String) -> String? {
        let coder = JSONEncoder()
        coder.outputFormatting = [.sortedKeys]
        guard let styled = try? coder.encode(style) else { return nil }

        var bytes = Data(day.utf8)
        for q in board.quads {
            bytes.append(0x1D)
            bytes.append(contentsOf: Array(q.key.utf8))
            for t in q.titles {
                bytes.append(0x1E)
                bytes.append(contentsOf: Array(t.utf8))
            }
        }
        bytes.append(0x1D)
        bytes.append(styled)

        /* The other designs' data. Only the asked-for design is ever
           filled in (WallpaperBoard.current), so a matrix wallpaper's
           digest does not move because the done graph would have. */
        if let extra = try? coder.encode(Extras(focus: board.focus, agenda: board.agenda,
                                                month: board.month, done: board.done)) {
            bytes.append(0x1D)
            bytes.append(extra)
        }

        // FNV-1a, as TaskBridge stamps the widget snapshot.
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        return String(h, radix: 16)
    }
}
