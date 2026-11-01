/* ============================================================
   my.adhd for iOS — what the wallpaper actually shows

   The person's own photo (or a colour) with the boxes of the matrix over
   it, and every open task in them. Nothing else.

   iOS owns the top of a lock screen and the bottom of it. The matrix
   lives in the band between them, as fractions of the height:

       0.00 – ~0.30  the date line, the big clock, the widget row
       ~0.30 – 0.875 the matrix — where exactly is the person's to move
       0.875 – 1.00  torch, notifications, camera, the home indicator

   **The matrix is one design of several.** `WallpaperStyle.design` picks
   which one the band draws; the others — one task, today, the month, the
   done graph — are in WallpaperDesigns.swift, and the library on Home
   (UI/WallpaperShelf.swift) is how somebody chooses between them. The
   ground, the veil and the band are shared, so every design sits where
   the matrix did and clears the same clock.

   `WallpaperStyle` is everything the Lock Screen Display page can change:
   where the band starts, how much of the room under it the matrix may
   take, the type size, the ground (photo, blurred or not, darker or
   lighter — or a plain colour), dark or light cards, and which boxes are
   shown. The defaults are the picture as it was before there was a page.

   **Every task, and the band filled.** No box is capped. Each row is as
   tall as its fuller box needs, and whatever height is left over is
   shared out between the rows in proportion, so a light day still fills
   the band and a heavy row gets the room. When the tasks need more
   height than the band has, the type comes down a step at a time until
   they fit — and only past the smallest wrapped size do titles go to one
   line each. A task is never dropped to make room. The person's text
   size is where that ladder starts, not a size it is forced to keep.

   **A veil on any photo.** A wallpaper is somebody's own picture, so the
   cards are a veil — dark with light text, or light with dark — that
   reads on a beach and on a night sky alike. No `.material`:
   ImageRenderer does not draw the blur behind it, and a card that is
   frosted in the preview and flat on the lock screen would be the
   preview lying. The ground's own blur is `.blur`, which it does draw.

   Kept free of UIKit and of the app's own types — it takes a plain
   `WallpaperBoard`, a `WallpaperStyle` and a `CGImage` — so the settings
   page can show it live, and so it compiles on a Mac with swiftc for an
   off-device render.
   ============================================================ */

import SwiftUI

/// Everything the picture draws, and nothing it would have to look up.
/// Built from the store by `WallpaperBoard.current()` (WallpaperBoard.swift).
struct WallpaperBoard: Equatable {

    struct Quad: Equatable {
        let key: String          // "do" | "plan" | "delegate" | "drop"
        let title: String        // two lines, split at "\n"
        let symbol: String       // SF Symbol
        let hue: UInt32          // 0xRRGGBB on dark cards — the matrix's own colour
        let hueLight: UInt32     // the same colour on light cards
        let titles: [String]     // every open task shown, in the matrix screen's order
    }

    let quads: [Quad]

    /* What the other designs draw. Each is filled only when somebody
       asked for that design (`WallpaperBoard.current(designs:)`), so the
       digest of a matrix wallpaper does not move because the done graph
       would have. Codable for that digest, nothing else. */

    /// The one task: `Ordering.pickNow`, the Now card's answer.
    struct Focus: Codable, Equatable {
        let title: String
        let step: String?        // its first step, when it has one
        let meta: String         // "25 min · Today", built by the caller
        let late: Bool
        let hue: UInt32
        let hueLight: UInt32
        let more: Int            // the rest of today and late, behind it
    }

    /// A row of the Today design, or of the month's "next" list.
    struct Row: Codable, Equatable {
        let title: String
        let meta: String         // "09:30", "Late", "Tue 4", "25 min"
        let late: Bool
        let hue: UInt32
        let hueLight: UInt32
    }

    struct Month: Codable, Equatable {
        let title: String        // "November"
        let symbols: [String]    // seven, starting on the calendar's first weekday
        let lead: Int            // blank cells before the 1st
        let counts: [Int]        // open dated tasks, one per day of the month
        let today: Int?          // 1-based, when today is in this month
        let next: [Row]          // the next few dated tasks
    }

    struct Done: Codable, Equatable {
        let counts: [Int]        // completed per day, oldest first, ending today
        let lead: Int            // cells before the first count, so columns are weeks
        let today: Int
        let week: Int            // the last seven days, today included
    }

    var focus: Focus? = nil
    var agenda: [Row] = []
    var month: Month? = nil
    var done: Done? = nil
}

/// What the Lock Screen Display page sets. Plain values, so it can be
/// stored as JSON and rendered off-device.
struct WallpaperStyle: Codable, Equatable {

    enum Ground: String, Codable { case photo, color }
    /// `auto` is Ink's "Match colors to photo": light cards on a bright
    /// ground, dark on a dark one, decided at drawing time by
    /// `WallpaperView.resolvedCards`, so a new photo needs no new choice.
    enum Cards: String, Codable { case dark, light, auto }
    enum Scope: String, Codable { case all, today }
    /// Which picture the band draws. Raw values are stored; never rename one.
    enum Design: String, Codable, CaseIterable { case matrix, focus, agenda, month, done }

    var design: Design = .matrix

    /// 0…1 — where the matrix starts, from just under the widget row (0)
    /// down to the middle of the screen (1).
    var position: Double = 0.4
    /// 0.4…1 — how much of the room between the start and the torch the
    /// matrix may take.
    var size: Double = 1.0
    /// 0.8…1.3 — the largest the type is allowed to be.
    var textScale: Double = 1.0
    /// 0…20 points of blur on the photo.
    var blur: Double = 0
    /// -0.6…0.4 — darker below zero, lighter above.
    var brightness: Double = 0

    var ground: Ground = .photo
    var color: UInt32 = 0x101018
    var cards: Cards = .dark
    var scope: Scope = .all
    /// Box keys turned off on the page. Empty is all four.
    var hidden: [String] = []
    /// The matrix on the Lock Screen only. iOS pairs a Home Screen with
    /// every lock screen, and on "Original" it copies whatever photo the
    /// lock screen gets — so on, the shortcut also sets the Home Screen of
    /// the same pair to the ground alone, with no boxes behind the icons.
    var lockOnly: Bool = true
    /// The Home Screen half blurred — Set Wallpaper Photo's Legibility
    /// Blur, on the screen behind the icons. Shortcut v3 and later.
    var homeBlur: Bool = false

    /// The fractions the view lays out with.
    var bandTop: Double { 0.22 + position * 0.2 }
    var bandBottom: Double {
        let room = Self.floor - bandTop
        return bandTop + room * min(1, max(0.4, size))
    }
    /// Torch and camera start here, on every phone with them.
    static let floor = 0.875

    /// Decoding field by field, so a style saved by an older build — or
    /// one missing a field this build added — still loads, with the
    /// missing part at its default rather than the whole style lost.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WallpaperStyle()
        position = (try? c.decode(Double.self, forKey: .position)) ?? d.position
        size = (try? c.decode(Double.self, forKey: .size)) ?? d.size
        textScale = (try? c.decode(Double.self, forKey: .textScale)) ?? d.textScale
        blur = (try? c.decode(Double.self, forKey: .blur)) ?? d.blur
        brightness = (try? c.decode(Double.self, forKey: .brightness)) ?? d.brightness
        ground = (try? c.decode(Ground.self, forKey: .ground)) ?? d.ground
        color = (try? c.decode(UInt32.self, forKey: .color)) ?? d.color
        cards = (try? c.decode(Cards.self, forKey: .cards)) ?? d.cards
        scope = (try? c.decode(Scope.self, forKey: .scope)) ?? d.scope
        hidden = (try? c.decode([String].self, forKey: .hidden)) ?? d.hidden
        lockOnly = (try? c.decode(Bool.self, forKey: .lockOnly)) ?? d.lockOnly
        homeBlur = (try? c.decode(Bool.self, forKey: .homeBlur)) ?? d.homeBlur
        design = (try? c.decode(Design.self, forKey: .design)) ?? d.design
    }
}

struct WallpaperView: View {
    let board: WallpaperBoard
    /// The person's chosen photo. nil, or a colour ground, draws no photo.
    var background: CGImage? = nil
    var style = WallpaperStyle()
    /// False for the Home Screen half of the pair: the ground alone. Every
    /// design but the matrix draws an empty state when it has nothing, and
    /// "Nothing due today" behind the app icons would be a false message.
    var showsBand = true

    private let gutter: CGFloat = 12
    private let gap: CGFloat = 10

    /// The sizes tried, largest first: type scale, and lines per title.
    /// Wrapped titles all the way down to 0.62, then one line apiece.
    private static let steps: [(scale: CGFloat, lines: Int)] =
        [1.3, 1.2, 1.1, 1.0, 0.93, 0.86, 0.8, 0.74, 0.68, 0.62].map { ($0, 2) }
        + [0.62, 0.55, 0.5, 0.45].map { ($0, 1) }

    /// The ladder from the person's own size down.
    private var ladder: [(scale: CGFloat, lines: Int)] {
        let top = CGFloat(style.textScale) + 0.001
        return Self.steps.filter { $0.scale <= top }
    }

    private var light: Bool { cards == .light }

    /// `style.cards` with `auto` decided against this ground.
    private var cards: WallpaperStyle.Cards { Self.resolvedCards(style, background: background) }

    /// The style the designs are handed: the same, with `auto` decided,
    /// so none of them has to know it exists.
    private var drawn: WallpaperStyle {
        var s = style
        s.cards = cards
        return s
    }
    private var ink: Color { light ? Self.color(0x101018) : .white }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack(alignment: .topLeading) {
                ground(w, h)

                if showsBand {
                    band
                        .frame(width: w - gutter * 2, height: h * (style.bandBottom - style.bandTop),
                               alignment: .top)
                        .clipped()
                        .offset(x: gutter, y: h * style.bandTop)
                }
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .clipped()
        }
        .ignoresSafeArea()
    }

    // MARK: - the ground

    @ViewBuilder
    private func ground(_ w: CGFloat, _ h: CGFloat) -> some View {
        ZStack {
            if style.ground == .photo, let background {
                Image(decorative: background, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: w, height: h)
                    .blur(radius: style.blur, opaque: true)
                    .clipped()
            } else if style.ground == .color {
                Self.color(style.color)
            } else {
                LinearGradient(
                    colors: [Color(red: 16 / 255, green: 16 / 255, blue: 24 / 255),
                             Color(red: 26 / 255, green: 24 / 255, blue: 46 / 255)],
                    startPoint: .top, endPoint: .bottom
                )
            }

            if style.brightness < 0 {
                Color.black.opacity(-style.brightness)
            } else if style.brightness > 0 {
                Color.white.opacity(style.brightness)
            }
        }
        .frame(width: w, height: h)
    }

    // MARK: - the band

    @ViewBuilder
    private var band: some View {
        switch style.design {
        case .matrix: matrix
        case .focus:  fitted { FocusDesign(board: board, style: $0) }
        case .agenda: AgendaDesign(board: board, style: drawn)   // drops rows itself
        case .month:  fitted { MonthDesign(board: board, style: $0) }
        case .done:   fitted { DoneDesign(board: board, style: $0) }
        }
    }

    /// The matrix's rule for the designs that cannot drop rows: the
    /// person's own text size first, then a step smaller until the whole
    /// design fits the band. Every size in a design is a multiple of
    /// `textScale`, so this shrinks it evenly, never cuts its foot off.
    private func fitted<D: View>(@ViewBuilder _ make: @escaping (WallpaperStyle) -> D) -> some View {
        let top = style.textScale + 0.001
        let sizes = [1.3, 1.2, 1.1, 1.0, 0.92, 0.84, 0.76, 0.68, 0.6, 0.52, 0.45]
            .filter { $0 <= top }
        return ViewThatFits(in: .vertical) {
            ForEach(sizes, id: \.self) { k in
                make({ var s = drawn; s.textScale = k; return s }())
            }
        }
    }

    // MARK: - the matrix

    /// The first size whose natural height fits the band. Every candidate
    /// is the whole matrix, so every box always shares one type size.
    private var matrix: some View {
        ViewThatFits(in: .vertical) {
            ForEach(ladder.indices, id: \.self) { i in
                rows(scale: ladder[i].scale, lines: ladder[i].lines)
            }
        }
    }

    /// Two to a row, in the matrix's order. With a box turned off, the one
    /// left without a partner takes the whole row rather than leaving a
    /// hole where its neighbour was.
    private func rows(scale s: CGFloat, lines: Int) -> some View {
        let q = board.quads
        let pairs = stride(from: 0, to: q.count, by: 2).map { Array(q[$0..<min($0 + 2, q.count)]) }
        return FillRows(spacing: gap) {
            ForEach(pairs.indices, id: \.self) { r in
                HStack(alignment: .top, spacing: gap) {
                    ForEach(pairs[r], id: \.key) { quad in
                        box(quad, s, lines)
                    }
                }
            }
        }
    }

    private func box(_ quad: WallpaperBoard.Quad, _ s: CGFloat, _ lines: Int) -> some View {
        let hue = Self.color(light ? quad.hueLight : quad.hue)
        return VStack(alignment: .leading, spacing: 9 * s) {
            header(quad, hue, s)
            if quad.titles.isEmpty {
                Text("Nothing here.")
                    .font(.system(size: 14 * s))
                    .foregroundStyle(ink.opacity(0.45))
            } else {
                VStack(alignment: .leading, spacing: 6 * s) {
                    ForEach(Array(quad.titles.enumerated()), id: \.offset) { _, title in
                        item(title, hue, s, lines)
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 12 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(card(hue))
    }

    /// The icon, the heading on two lines, and the count beside the first.
    /// Two lines always — "Urgent &" over "Less Important" — so the count
    /// only ever shares a line with the short half, and the long half gets
    /// the whole width of the card. A heading left to wrap on its own
    /// broke wherever the count pushed it, and on a 375pt phone cut
    /// "Less Important" short.
    private func header(_ quad: WallpaperBoard.Quad, _ hue: Color, _ s: CGFloat) -> some View {
        let lines = quad.title.components(separatedBy: "\n")
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: quad.symbol)
                .font(.system(size: 14.5 * s, weight: .semibold))
                .foregroundStyle(hue)
                .frame(width: 18 * s, height: 18 * s)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .top, spacing: 6) {
                    headLine(lines.first ?? "", s)
                    Spacer(minLength: 0)
                    Text("\(quad.titles.count)")
                        .font(.system(size: 12.5 * s, weight: .bold).monospacedDigit())
                        .foregroundStyle(hue)
                        .padding(.horizontal, 7 * s)
                        .padding(.vertical, 2 * s)
                        .background(hue.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
                    headLine(line, s)
                }
            }
        }
    }

    private func headLine(_ text: String, _ s: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 15 * s, weight: .bold))
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func item(_ title: String, _ hue: Color, _ s: CGFloat, _ lines: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(hue).frame(width: 5 * s, height: 5 * s)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 * s }
            Text(title)
                .font(.system(size: 15.5 * s))
                .foregroundStyle(ink.opacity(0.94))
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card(_ hue: Color) -> some View {
        Self.veil(hue, light: light)
    }

    /// The card every design sits on. See "A veil on any photo" above.
    static func veil(_ hue: Color, light: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(light ? Color.white.opacity(0.78) : Color.black.opacity(0.48))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(hue.opacity(light ? 0.35 : 0.28), lineWidth: 1)
            )
    }

    // MARK: - matching the cards to the ground

    /// Dark or light, never auto. A bright ground takes light cards: a
    /// dark veil over a pale photo comes out mid-grey under white text,
    /// while a light one stays near white under dark text. Brightness is
    /// the photo with the page's own brightness slider applied — that
    /// slider is what somebody reaches for to make text readable, and the
    /// cards should follow it rather than fight it.
    static func resolvedCards(_ style: WallpaperStyle, background: CGImage?) -> WallpaperStyle.Cards {
        guard style.cards == .auto else { return style.cards }
        let base: Double
        if style.ground == .color {
            base = luma(style.color)
        } else if style.ground == .photo, let background {
            base = averageLuma(background)
        } else {
            base = 0.08                       // the dark gradient
        }
        let shifted = style.brightness < 0
            ? base * (1 + style.brightness)
            : base + (1 - base) * style.brightness
        return shifted > 0.62 ? .light : .dark
    }

    static func luma(_ hex: UInt32) -> Double {
        let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255
    }

    /* The band, not the whole photo: the cards sit between the clock and
       the torch, and a bright sky above a dark street is a dark ground as
       far as they are concerned. Drawn down to 8x16 and averaged. The
       last answer is kept with the image itself, held, so its address
       cannot be handed to the next photo — the shelf on Home asks six
       times a frame, always about the same one. */
    nonisolated(unsafe) private static var lastLuma: (image: CGImage, luma: Double)?

    static func averageLuma(_ image: CGImage) -> Double {
        if let last = lastLuma, last.image === image { return last.luma }
        let w = 8, h = 16
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let result: Double = px.withUnsafeMutableBytes { buf -> Double in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return 0.5 }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            var sum = 0.0, n = 0.0
            /* Row 0 of the buffer is the top of the picture: skip the top
               fifth (clock) and the bottom eighth (torch and camera). */
            for y in 3..<(h - 2) {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    sum += 0.299 * Double(buf[i]) + 0.587 * Double(buf[i + 1]) + 0.114 * Double(buf[i + 2])
                    n += 1
                }
            }
            return n > 0 ? sum / n / 255 : 0.5
        }
        lastLuma = (image, result)
        return result
    }

    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

/// Rows, stacked, that fill the height they are given.
///
/// Asked for its natural size it answers the rows' own heights added up,
/// which is what ViewThatFits compares against the band. Placed into the
/// band, each row gets its own height plus a share of what is left over,
/// in proportion to that height — so the fuller row keeps the extra room,
/// the way the boxes look in the reference rather than two equal halves
/// with one of them mostly empty.
private struct FillRows: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let natural = heights(width, subviews).reduce(0, +)
            + spacing * CGFloat(max(0, subviews.count - 1))
        return CGSize(width: width, height: max(natural, proposal.height ?? 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let own = heights(bounds.width, subviews)
        let total = own.reduce(0, +)
        let room = bounds.height - spacing * CGFloat(max(0, subviews.count - 1))
        let spare = max(0, room - total)

        var y = bounds.minY
        for (i, row) in subviews.enumerated() {
            let share = total > 0 ? own[i] / total : 1 / CGFloat(subviews.count)
            let h = own[i] + spare * share
            row.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                      proposal: ProposedViewSize(width: bounds.width, height: h))
            y += h + spacing
        }
    }

    private func heights(_ width: CGFloat, _ subviews: Subviews) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
    }
}
