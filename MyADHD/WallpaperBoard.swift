/* ============================================================
   my.adhd for iOS — what the wallpaper's matrix is made of

   The picture draws a `WallpaperBoard` (WallpaperView.swift), a plain
   value with no app types in it, so the view still compiles on a Mac for
   an off-device render. This file is the other half: building one from
   the person's store.

   **The store, not the widget snapshot.** The snapshot is trimmed for
   tiles — it carries no `quadrant`, so a task somebody dragged into a box
   would land where it derives to, and it stops at tomorrow, so Plan and
   Drop would under-count. The intent runs in the app's own process, so it
   can read the file the app writes and ask `Ordering` exactly what the
   matrix screen asks. Same boxes, same order, same counts.

   **Read-only.** `StoreFile.peek()` never quarantines and never stamps;
   ticks a widget queued since the app last drained are laid over in
   memory, the way every tile does it, and nothing is written back.
   ============================================================ */

import Foundation

extension WallpaperBoard {

    /// How each box is headed on the lock screen, and the glyph beside it.
    /// Keyed to the matrix's own keys, in `Copy.Quadrants.order`. The line
    /// break is where the heading breaks; WallpaperView says why.
    private static let heads: [String: (title: String, symbol: String)] = [
        "do":       ("Important &\nUrgent", "flame.fill"),
        "plan":     ("Important &\nNot Urgent", "calendar"),
        "delegate": ("Urgent &\nLess Important", "bolt.fill"),
        "drop":     ("Not Urgent &\nLess Important", "list.bullet"),
    ]

    /// The board as the store stands now, or nil when there is no store to
    /// read — missing, locked before the first unlock, or unparseable. The
    /// caller keeps yesterday's wallpaper on nil.
    static func current(style: WallpaperStyle = Wallpaper.style,
                        file: StoreFile = StoreFile(),
                        today: String = WebDates.dayKey()) -> WallpaperBoard?
    {
        guard let json = file.peek() else { return nil }
        var tasks = StoreDocument.load(json).tasks

        let ticked = Set(OpQueue.peek().map(\.op).filter { $0.kind == .done }.map(\.id))
        if !ticked.isEmpty {
            for i in tasks.indices where ticked.contains(tasks[i].id) {
                tasks[i].done = true
            }
        }

        /* Boxes are decided over every open task, so a task sits in the
           same box whatever the scope; the scope only chooses which of
           them are listed. "Today & late" is a date on or before today —
           the same test the matrix uses to call a dated task urgent. */
        let open = tasks.filter { !$0.done }
        let hidden = Set(style.hidden)
        let quads = Ordering.quadrantize(open, today: today)
            .filter { !hidden.contains($0.key) }
            .map { q in
                let head = heads[q.key] ?? (q.label, "circle")
                let shown = style.scope == .all ? q.items : q.items.filter { t in
                    guard let when = t.when, !when.isEmpty else { return false }
                    return when <= today
                }
                return Quad(key: q.key,
                            title: head.title,
                            symbol: head.symbol,
                            hue: QuadrantPalette.hueHex(q.key, dark: true),
                            hueLight: QuadrantPalette.hueHex(q.key, dark: false),
                            titles: shown.map(\.title))
            }
        return WallpaperBoard(quads: quads)
    }
}
