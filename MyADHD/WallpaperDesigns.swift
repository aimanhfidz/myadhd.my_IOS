/* ============================================================
   my.adhd for iOS — the designs that are not the matrix, and the library

   The wallpaper used to be one picture. It is a library now, chosen on
   Home (UI/WallpaperShelf.swift) the way Ink's Discover tab chooses, and
   each entry is a `WallpaperPreset`: a design and, for the matrix, which
   cards. Adding a design is three steps:

     1. a case on `WallpaperStyle.Design` (WallpaperView.swift) — the raw
        value is what is stored, so never rename one;
     2. a view here, drawn in the band WallpaperView gives it, on
        `WallpaperView.veil`, at `style.textScale`;
     3. what it needs, filled in by `WallpaperBoard.current(designs:)`
        (WallpaperBoard.swift), and a line in `WallpaperPreset.library`.

   The same rules as the matrix hold for every one of them:

   - **The band, and nothing outside it.** iOS owns the clock above and
     the torch below. A design that runs long shrinks or drops rows into
     a "+N more"; it never draws over either.
   - **No `.material`, no lazy stacks.** ImageRenderer draws neither
     faithfully, and the preview has to be what lands.
   - **Orange means late.** BRAND.md §3.3. The rest of a design's colour
     is the matrix's own box colours, so a task is the same colour on
     every design, or the brand blue for things that are no box's.

   Like WallpaperView.swift, nothing here touches UIKit or the app's own
   types, so Checks/wallpaper-mode.sh compiles it on a Mac.
   ============================================================ */

import SwiftUI

// MARK: - the library

/// One entry in the library: a design, and for the two matrices, the
/// cards. The rest leave the cards as the person set them.
struct WallpaperPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let design: WallpaperStyle.Design
    var cards: WallpaperStyle.Cards? = nil

    /// The order the shelf shows them in. The matrix first: it is the
    /// product's own idea, and the one every existing wallpaper already is.
    static let library: [WallpaperPreset] = [
        WallpaperPreset(id: "matrix", name: "Matrix", design: .matrix, cards: .dark),
        WallpaperPreset(id: "matrix-light", name: "Matrix Light", design: .matrix, cards: .light),
        WallpaperPreset(id: "focus", name: "One Thing", design: .focus),
        WallpaperPreset(id: "today", name: "Today", design: .agenda),
        WallpaperPreset(id: "month", name: "Month", design: .month),
        WallpaperPreset(id: "done", name: "Done Graph", design: .done),
    ]

    func applied(to style: WallpaperStyle) -> WallpaperStyle {
        var next = style
        next.design = design
        if let cards { next.cards = cards }
        return next
    }

    /// `auto` counts as whichever it comes out as on this ground, so the
    /// matrix tile that looks like your lock screen is the one ticked.
    func isCurrent(_ style: WallpaperStyle, background: CGImage? = nil) -> Bool {
        guard style.design == design else { return false }
        guard let cards else { return true }
        return WallpaperView.resolvedCards(style, background: background) == cards
    }
}

// MARK: - shared furniture

private enum Ink {
    static let orange: UInt32 = 0xF75C03      // --orange: late, and only late
    static let blue: UInt32 = 0x4737FF        // --blue, on light cards
    static let bluePale: UInt32 = 0xACA5FF    // --blue-pale, on dark ones

    static func text(_ light: Bool) -> Color { light ? WallpaperView.color(0x101018) : .white }
    static func accent(_ light: Bool) -> Color { WallpaperView.color(light ? blue : bluePale) }

    /// Late, as text. Orange as text on a light ground is NEVER (BRAND.md
    /// §3.3: 3.24:1 on white), so light cards set it in ink and the orange
    /// rides on a dot, bar or wash beside it — the Matrix widget's rule.
    static func lateText(_ light: Bool) -> Color { light ? text(true) : WallpaperView.color(orange) }
}

/// "Late" or "Wed 5" for a late task: orange on dark cards; ink after an
/// orange dot on light ones.
private struct LateMeta: View {
    let text: String
    let light: Bool
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.4) {
            if light {
                Circle().fill(WallpaperView.color(Ink.orange)).frame(width: size * 0.5, height: size * 0.5)
            }
            Text(text)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Ink.lateText(light))
                .lineLimit(1)
        }
    }
}

/// The heading every design opens with: a word, and a number beside it.
private struct DesignHead: View {
    let title: String
    let count: String?
    let hue: Color
    let ink: Color
    let s: CGFloat
    /// The count's text, when `hue` may not be text here (orange on a
    /// light card). The wash keeps `hue`.
    var label: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 17 * s, weight: .bold))
                .foregroundStyle(ink)
                .lineLimit(1)
            Spacer(minLength: 6)
            if let count {
                Text(count)
                    .font(.system(size: 12.5 * s, weight: .bold).monospacedDigit())
                    .foregroundStyle(label ?? hue)
                    .padding(.horizontal, 7 * s)
                    .padding(.vertical, 2 * s)
                    .background(hue.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }
}

/// A task as a line: a bar in its box's colour, the title, and under it
/// when — marked late with LateMeta.
private struct DesignRow: View {
    let row: WallpaperBoard.Row
    let light: Bool
    let s: CGFloat
    var lines: Int = 2

    var body: some View {
        let ink = Ink.text(light)
        let hue = WallpaperView.color(light ? row.hueLight : row.hue)
        VStack(alignment: .leading, spacing: 2 * s) {
            Text(row.title)
                .font(.system(size: 15.5 * s, weight: .semibold))
                .foregroundStyle(ink.opacity(0.95))
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
            if row.late, !row.meta.isEmpty {
                LateMeta(text: row.meta, light: light, size: 12.5 * s)
            } else if !row.meta.isEmpty {
                Text(row.meta)
                    .font(.system(size: 12.5 * s))
                    .foregroundStyle(ink.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .padding(.leading, 11 * s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            Capsule().fill(hue).frame(width: 3.5 * s)
        }
    }
}

// MARK: - One Thing

/// The Now card, on the lock screen: the one task, big, with its first
/// step under it. The product in one picture — and the design that asks
/// least of somebody glancing at a phone.
struct FocusDesign: View {
    let board: WallpaperBoard
    let style: WallpaperStyle

    var body: some View {
        let s = CGFloat(style.textScale)
        let light = style.cards == .light
        let ink = Ink.text(light)

        if let f = board.focus {
            let hue = WallpaperView.color(light ? f.hueLight : f.hue)
            VStack(alignment: .leading, spacing: 12 * s) {
                HStack(spacing: 7) {
                    Circle().fill(hue).frame(width: 8 * s, height: 8 * s)
                    /* In ink on light cards: the box's hue can be
                       Delegate's orange, and the dot already carries it. */
                    Text("Now")
                        .font(.system(size: 14 * s, weight: .bold))
                        .foregroundStyle(light ? ink : hue)
                    Spacer(minLength: 6)
                    if f.more > 0 {
                        Text("+\(f.more) today")
                            .font(.system(size: 13 * s, weight: .semibold))
                            .foregroundStyle(ink.opacity(0.6))
                    }
                }
                Text(f.title)
                    .font(.system(size: 30 * s, weight: .bold))
                    .foregroundStyle(ink)
                    .lineLimit(4)
                    .minimumScaleFactor(0.5)
                    .fixedSize(horizontal: false, vertical: true)
                if let step = f.step {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "arrow.turn.down.right")
                        Text(step).lineLimit(3)
                    }
                    .font(.system(size: 16 * s))
                    .foregroundStyle(ink.opacity(0.85))
                }
                if f.late {
                    LateMeta(text: f.meta, light: light, size: 13.5 * s)
                } else {
                    Text(f.meta)
                        .font(.system(size: 13.5 * s, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.6))
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WallpaperView.veil(hue, light: light))
        } else {
            EmptyDesign(text: "Nothing open. The day is yours.", style: style)
        }
    }
}

// MARK: - Today

/// Late, then today, as rows. As many as the band holds at the person's
/// size, then fewer at a time with the rest counted — never smaller type
/// than the matrix would use, because these are read at arm's length.
struct AgendaDesign: View {
    let board: WallpaperBoard
    let style: WallpaperStyle

    private static let limits = [12, 10, 8, 7, 6, 5, 4, 3, 2, 1]

    var body: some View {
        let rows = board.agenda
        if rows.isEmpty {
            EmptyDesign(text: "Nothing due today.", style: style)
        } else {
            /* Every row first, then fewer. The last candidate is the one
               ViewThatFits falls back to when nothing fits. */
            let tries = [rows.count] + Self.limits.filter { $0 < rows.count }
            ViewThatFits(in: .vertical) {
                ForEach(tries, id: \.self) { n in
                    card(Array(rows.prefix(n)), more: max(0, rows.count - n))
                }
            }
        }
    }

    private func card(_ rows: [WallpaperBoard.Row], more: Int) -> some View {
        let s = CGFloat(style.textScale)
        let light = style.cards == .light
        let ink = Ink.text(light)
        let late = board.agenda.contains(where: \.late)
        let hue = late ? WallpaperView.color(Ink.orange) : Ink.accent(light)
        return VStack(alignment: .leading, spacing: 11 * s) {
            DesignHead(title: "Today", count: "\(board.agenda.count)", hue: hue, ink: ink, s: s,
                       label: late && light ? ink : nil)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                DesignRow(row: row, light: light, s: s)
            }
            if more > 0 {
                Text("+\(more) more")
                    .font(.system(size: 13 * s, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.6))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WallpaperView.veil(hue, light: light))
    }
}

// MARK: - Month

/// The month, with a dot under every day that has something on it, today
/// filled, and the next three dated tasks underneath. A grid, not lazy:
/// see the header.
struct MonthDesign: View {
    let board: WallpaperBoard
    let style: WallpaperStyle

    var body: some View {
        let s = CGFloat(style.textScale)
        let light = style.cards == .light
        let ink = Ink.text(light)
        let accent = Ink.accent(light)

        if let m = board.month {
            let cells: [Int?] = Array(repeating: nil, count: m.lead) + m.counts.indices.map { Optional($0) }
            let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }

            VStack(alignment: .leading, spacing: 10 * s) {
                DesignHead(title: m.title, count: "\(m.counts.reduce(0, +))", hue: accent, ink: ink, s: s)

                Grid(horizontalSpacing: 2, verticalSpacing: 4 * s) {
                    GridRow {
                        ForEach(0..<7, id: \.self) { i in
                            Text(m.symbols[i])
                                .font(.system(size: 11 * s, weight: .semibold))
                                .foregroundStyle(ink.opacity(0.5))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(weeks.indices, id: \.self) { w in
                        GridRow {
                            ForEach(0..<7, id: \.self) { d in
                                let i = d < weeks[w].count ? weeks[w][d] : nil
                                day(i.map { ($0 + 1, m.counts[$0]) }, today: m.today, accent: accent,
                                    ink: ink, light: light, s: s)
                            }
                        }
                    }
                }

                if !m.next.isEmpty {
                    Rectangle().fill(ink.opacity(0.14)).frame(height: 1)
                    ForEach(Array(m.next.enumerated()), id: \.offset) { _, row in
                        DesignRow(row: row, light: light, s: s, lines: 1)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WallpaperView.veil(accent, light: light))
        }
    }

    @ViewBuilder
    private func day(_ cell: (n: Int, count: Int)?, today: Int?, accent: Color,
                     ink: Color, light: Bool, s: CGFloat) -> some View {
        if let cell {
            let isToday = cell.n == today
            VStack(spacing: 2 * s) {
                Text("\(cell.n)")
                    .font(.system(size: 13.5 * s, weight: isToday ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(isToday ? (light ? .white : WallpaperView.color(0x101018)) : ink.opacity(0.9))
                    .frame(width: 26 * s, height: 26 * s)
                    .background { if isToday { Circle().fill(accent) } }
                Circle()
                    .fill(cell.count > 0 ? accent : .clear)
                    .frame(width: 4.5 * s, height: 4.5 * s)
            }
            .frame(maxWidth: .infinity)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
        }
    }
}

// MARK: - Done Graph

/// Seventeen weeks of what got done, a square a day, ending today. The
/// one design that is about what is behind you rather than ahead — for
/// the mornings when the list is the problem.
struct DoneDesign: View {
    let board: WallpaperBoard
    let style: WallpaperStyle

    var body: some View {
        let s = CGFloat(style.textScale)
        let light = style.cards == .light
        let ink = Ink.text(light)
        let accent = Ink.accent(light)

        if let d = board.done {
            let cells: [Int?] = Array(repeating: nil, count: d.lead) + d.counts.map { Optional($0) }
            let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }

            VStack(alignment: .leading, spacing: 12 * s) {
                DesignHead(title: "Done", count: "\(d.today) today", hue: accent, ink: ink, s: s)

                HStack(alignment: .top, spacing: 3) {
                    ForEach(weeks.indices, id: \.self) { w in
                        VStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { i in
                                let n = i < weeks[w].count ? weeks[w][i] : nil
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(fill(n, accent: accent, ink: ink))
                                    .aspectRatio(1, contentMode: .fit)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                Text(d.week == 1 ? "1 done in the last 7 days" : "\(d.week) done in the last 7 days")
                    .font(.system(size: 13 * s, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.65))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WallpaperView.veil(accent, light: light))
        }
    }

    /// Four steps, like the widget's graph: none, one, two, three or more.
    private func fill(_ n: Int?, accent: Color, ink: Color) -> Color {
        guard let n else { return .clear }
        switch n {
        case 0: return ink.opacity(0.10)
        case 1: return accent.opacity(0.4)
        case 2: return accent.opacity(0.7)
        default: return accent
        }
    }
}

// MARK: - nothing to draw

/// A design with nothing in it still says so, on the same card, rather
/// than leaving a bare photo that looks like the shortcut failed.
private struct EmptyDesign: View {
    let text: String
    let style: WallpaperStyle

    var body: some View {
        let s = CGFloat(style.textScale)
        let light = style.cards == .light
        Text(text)
            .font(.system(size: 16 * s, weight: .semibold))
            .foregroundStyle(Ink.text(light).opacity(0.8))
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WallpaperView.veil(Ink.accent(light), light: light))
    }
}
