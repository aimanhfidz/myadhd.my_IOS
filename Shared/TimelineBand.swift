/* ============================================================
   my.adhd for iOS — the day as one band

   Drawn once and used twice: by the Today Timeline widget, and by the
   wallpaper renderer, which is the whole reason it is here rather than
   inside the widget target. Two drawings of the same chart would drift
   apart the first time either was touched.

   No WidgetKit import. This is plain SwiftUI so ImageRenderer can hand it
   to a PNG from inside the app, where WidgetKit views cannot go.
   ============================================================ */

import SwiftUI

// MARK: - colour

/// theme.css has no per-category colour, so the shell invents one. It is
/// sampled between the two brand hues rather than picked out of the air:
/// Vivid Blue #4737FF at one end, Violet #7B3FE4 at the other, so a band
/// full of tasks still reads as this app.
///
/// This palette has no counterpart on the web. It is listed in
/// ios/README.md as a promise, because a future web-side category colour
/// would silently disagree with it.
enum CategoryTint {

    private static let order = ["work", "admin", "money", "health",
                                "home", "social", "errand", "general"]

    /// Vivid Orange, and only for urgency. theme.css keeps it for the mark
    /// and for late; a band that used it as a fill would be saying "urgent"
    /// about everything and therefore about nothing.
    static let urgent = Color(red: 247 / 255, green: 92 / 255, blue: 3 / 255)

    /// Danger Red, and only for the now-line.
    static let now = Color(red: 217 / 255, green: 45 / 255, blue: 32 / 255)

    /// The one brand colour that moves between themes: #4737FF by day,
    /// #8B7DFF by night, because the day value is too dark to read on a
    /// night ground. theme.css moves it for the same reason.
    ///
    /// Written out rather than read from the asset catalogue: an
    /// AccentColor lookup resolves against a bundle, and this file has to
    /// render under swiftc on a Mac where there is no bundle at all.
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x8B / 255, green: 0x7D / 255, blue: 0xFF / 255)
            : Color(red: 0x47 / 255, green: 0x37 / 255, blue: 0xFF / 255)
    }

    static func of(_ category: String) -> Color {
        let i = order.firstIndex(of: category.lowercased()) ?? order.count - 1
        let t = Double(i) / Double(max(1, order.count - 1))
        // #4737FF -> #7B3FE4
        return Color(
            red:   (0x47 + (0x7B - 0x47) * t) / 255,
            green: (0x37 + (0x3F - 0x37) * t) / 255,
            blue:  (0xFF + (0xE4 - 0xFF) * t) / 255
        )
    }

    /// The block itself sits at a fraction of its hue so the label on top
    /// of it stays readable without a second colour.
    static func wash(_ category: String) -> Color { of(category).opacity(0.22) }
}

// MARK: - the window

/// What slice of the day the band covers. A fixed 0–24 spends a third of
/// its width on hours nobody has anything in; 4–24 is that same guess with
/// the worst third removed. Taking it from the data is one function and
/// buys about fifty per cent more pixels per hour.
struct DayWindow {
    let lo: Int
    let hi: Int

    var hours: Int { max(1, hi - lo) }

    init(tasks: [SnapTask], now: Date = Date(), calendar: Calendar = .current) {
        let hourNow = calendar.component(.hour, from: now)

        let starts = tasks.compactMap { TimelineBand.minutes(of: $0.at) }
        let ends = tasks.compactMap { t -> Int? in
            guard let s = TimelineBand.minutes(of: t.at) else { return nil }
            return s + t.minutes
        }

        let earliest = (starts.min().map { $0 / 60 }) ?? 7
        let latest = (ends.max().map { Int(ceil(Double($0) / 60)) }) ?? 23

        lo = max(0, min(7, min(earliest, hourNow - 1)))
        hi = min(24, max(22, max(latest, hourNow + 2)))
    }
}

// MARK: - the band

struct TimelineBand: View {
    let tasks: [SnapTask]
    let now: Date
    var laneHeight: CGFloat = 14
    var laneGap: CGFloat = 2
    var maxLanes: Int = 3
    var showTicks: Bool = true

    private var window: DayWindow { DayWindow(tasks: tasks, now: now) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let win = window
            let laid = Self.lay(tasks, maxLanes: maxLanes)

            ZStack(alignment: .topLeading) {
                ForEach(laid.placed, id: \.task.id) { item in
                    block(item, width: w, win: win)
                }
                nowLine(width: w, win: win)
            }
            /* Width as well as height. Without it the ZStack is only as
               wide as the blocks inside it happen to reach, and the
               overflow pip — aligned to the trailing edge — lands in the
               middle of the day instead of at the end of it. */
            .frame(width: w, height: bandHeight, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                if laid.overflow > 0 { pip(laid.overflow) }
            }
        }
        .frame(height: bandHeight + (showTicks ? 14 : 0))
        .overlay(alignment: .bottom) {
            if showTicks { ticks(win: window) }
        }
    }

    private var bandHeight: CGFloat {
        CGFloat(maxLanes) * laneHeight + CGFloat(maxLanes - 1) * laneGap
    }

    // MARK: pieces

    private func block(_ item: Placed, width: CGFloat, win: DayWindow) -> some View {
        let x0 = Self.x(item.start, in: win, width: width)
        let x1 = Self.x(item.start + item.task.minutes, in: win, width: width)
        /* A fifteen-minute task is two pixels wide at this scale and might
           as well not be drawn. Six points overlaps its neighbour slightly
           and that is the better lie: being wrong about a length is
           recoverable, losing a task is not. */
        let w = max(6, x1 - x0)

        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(CategoryTint.wash(item.task.category))
            .overlay(alignment: .leading) {
                if item.task.urgency >= 4 {
                    Rectangle().fill(CategoryTint.urgent).frame(width: 3)
                }
            }
            .overlay(alignment: .leading) {
                if w > 44 {
                    Text(item.task.title)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(CategoryTint.of(item.task.category))
                        .padding(.leading, item.task.urgency >= 4 ? 7 : 5)
                        .padding(.trailing, 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .frame(width: w, height: laneHeight)
            .opacity(item.task.done ? 0.35 : 1)
            .offset(x: x0, y: CGFloat(item.lane) * (laneHeight + laneGap))
    }

    private func nowLine(width: CGFloat, win: DayWindow) -> some View {
        let m = Self.minutesOfDay(now)
        let x = Self.x(m, in: win, width: width)
        let inside = m >= win.lo * 60 && m <= win.hi * 60
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(CategoryTint.now)
                .frame(width: 1.5, height: bandHeight)
            Circle()
                .fill(CategoryTint.now)
                .frame(width: 5, height: 5)
                .offset(y: -2)
        }
        .offset(x: x - 0.75)
        .opacity(inside ? 1 : 0)
    }

    private func pip(_ n: Int) -> some View {
        Text("+\(n)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.thinMaterial, in: Capsule())
    }

    private func ticks(win: DayWindow) -> some View {
        let marks = stride(from: win.lo, through: win.hi, by: 3).map { $0 }
        return GeometryReader { geo in
            ForEach(marks, id: \.self) { h in
                Text("\(h)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .offset(x: Self.x(h * 60, in: win, width: geo.size.width) - 4)
            }
        }
        .frame(height: 12)
    }

    // MARK: geometry

    static func minutes(of hhmm: String?) -> Int? {
        guard let hhmm else { return nil }
        let bits = hhmm.split(separator: ":")
        guard bits.count == 2, let h = Int(bits[0]), let m = Int(bits[1]) else { return nil }
        return h * 60 + m
    }

    static func minutesOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let p = calendar.dateComponents([.hour, .minute], from: date)
        return (p.hour ?? 0) * 60 + (p.minute ?? 0)
    }

    static func x(_ minute: Int, in win: DayWindow, width: CGFloat) -> CGFloat {
        let span = CGFloat(win.hours * 60)
        let from = CGFloat(win.lo * 60)
        return max(0, min(width, (CGFloat(minute) - from) / span * width))
    }

    // MARK: lanes

    struct Placed {
        let task: SnapTask
        let start: Int
        let lane: Int
    }

    /// Greedy interval partition. Anything that will not fit in the lanes
    /// available is counted rather than drawn on top of something else.
    static func lay(_ tasks: [SnapTask], maxLanes: Int) -> (placed: [Placed], overflow: Int) {
        let timed = tasks
            .compactMap { t -> (SnapTask, Int)? in
                guard let s = minutes(of: t.at) else { return nil }
                return (t, s)
            }
            .sorted { $0.1 < $1.1 }

        var laneEnds = [Int](repeating: Int.min, count: maxLanes)
        var placed: [Placed] = []
        var overflow = 0

        for (task, start) in timed {
            if let lane = laneEnds.firstIndex(where: { $0 <= start }) {
                laneEnds[lane] = start + task.minutes
                placed.append(Placed(task: task, start: start, lane: lane))
            } else {
                overflow += 1
            }
        }
        return (placed, overflow)
    }
}

// MARK: - the app's own face

/* Baloo 2 is the app's typeface and the wordmark's, so a tile drawn in SF
   beside the app icon is visibly a different product. The file is bundled
   into both the app and the widget extension — two copies under ios/, and
   a third upstream at fonts/Baloo2-Variable.ttf, all replaced together.

   Font.custom falls back to the system face on its own when the file is
   missing, which is what lets this whole file render off-device with no
   UIFont lookup anywhere in it. */
extension Font {

    /// The PostScript name inside Baloo2-Variable.ttf, which is not the
    /// family name and is what Font.custom actually wants.
    private static let balooFace = "Baloo2-Regular"

    static func baloo(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(balooFace, size: size).weight(weight)
    }
}
