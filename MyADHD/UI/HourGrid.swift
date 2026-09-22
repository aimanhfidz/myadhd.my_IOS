/* ============================================================
   MyADHD/UI/HourGrid.swift — the Day and Week views

   BridgeScript.swift:855-1087 and the CSS at 346-390. Two shapes over one
   grid: Day is a week strip and a single column at 56pt an hour, and the
   columned view is `CalDays.columns` of them at 52pt. Both carry the chips
   for whatever is on the day with no clock on it, and a red line across
   today at the hour it actually is.

   **The columned view draws three days, and the mode is still called
   `week`.** Seven columns is what the web did and what a desktop can
   afford; on a phone it was seven titles clipped at five characters each.
   The name is a storage key — see `CalMode` — and the pill's icon was
   always `rectangle.split.3x1`, so this is the first build where the two
   agree.

   **One scroller, not two.** The grid used to scroll inside itself,
   inside the page, and a finger never knew which one it had. The page is
   the only scroller and the grid is simply tall — 24 hours at 56pt is
   1344pt of it — which is why entering the view scrolls to the working
   hours rather than starting at midnight. Keyed on the view alone: moving
   to another day keeps the hour you were reading.

   **The day header is not in this file's views any more.** The strip and
   the column head were inside that one scroller, so the same jump to the
   working hours that made the grid useful took them off the top of the
   screen and nothing ever brought them back. They were `position: sticky`
   on the web (BridgeScript.swift:361-362); they are a `safeAreaInset` on
   the scroller in `CalendarScreen` now, which is the same thing and also
   makes the jump land below them rather than behind them.

   **What is drawn and what is not.** A block is a task on that day WITH a
   clock on it and not skipped — including finished ones, at 45% and
   struck through, because a day you have already worked through should
   look worked through. Everything on the day with no clock is a chip
   above the grid instead, six of them and then a count: they have no
   position in an hour grid and inventing one would be a lie about when
   they are.

   **`min(20)` on the length** is the web's: a zero-minute task still has
   to be tall enough to read, and the block never draws shorter than half
   an hour whatever the minutes say.
   ============================================================ */

import SwiftUI

// MARK: - the numbers

enum HourGridMetrics {
    /// `HH` — Day.
    static let day: CGFloat = 56
    /// `HHW` — the columned pane. The web's was 40, sized for seven
    /// columns; three can afford most of the room a single day gets.
    static let columns: CGFloat = 52
    /// `GLIDE` on `cubic-bezier(.2,.8,.2,1)`, the same 220ms the month
    /// scroller uses.
    static let glideMS: TimeInterval = 0.220
    static var glide: Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: glideMS) }
    /// `Math.abs(moved) < 60` springs back.
    static let swipeCommit: CGFloat = 60
    /// The left edge belongs to the back gesture.
    static let edge: CGFloat = 22
    /// The hours column.
    static let gutter: CGFloat = 44
}

// MARK: - Day

/// The scrolling half of the Day view. **Its week strip is not in here** —
/// see `CalendarScreen`'s `dayHeader`, and the note about sticky in this
/// file's header.
struct CalDayPane: View {

    let tasks: [TaskItem]
    let today: String
    let session: CalendarSession

    @Binding var dx: CGFloat

    var meetings: MeetingReader? = nil

    var body: some View {
        let days = [session.picked]
        let onDays = MeetingDays.on(days, from: meetings, tasks: tasks)
        VStack(alignment: .leading, spacing: 0) {
            AnytimeChips(tasks: tasks, days: days, meetings: onDays)
            HourGridView(days: days,
                         tasks: tasks,
                         today: today,
                         hourHeight: HourGridMetrics.day,
                         compact: false,
                         meetings: onDays)
        }
        .offset(x: dx)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - the columned pane

/// Three days side by side. The column head is drawn by `CalendarScreen`
/// so it can stay on screen; everything here scrolls.
struct CalColumnsPane: View {

    let tasks: [TaskItem]
    let today: String
    let session: CalendarSession

    @Binding var dx: CGFloat

    var meetings: MeetingReader? = nil

    var body: some View {
        let days = CalDays.window(from: session.picked, count: CalDays.columns)
        let onDays = MeetingDays.on(days, from: meetings, tasks: tasks)
        VStack(alignment: .leading, spacing: 0) {
            AnytimeChips(tasks: tasks, days: days, meetings: onDays)
            HourGridView(days: days,
                         tasks: tasks,
                         today: today,
                         hourHeight: HourGridMetrics.columns,
                         /* Seven columns had to be compact — 9.5pt titles
                            and no second line — because there was no room
                            to be anything else. Three have the room, so a
                            block here says what a block on the Day view
                            says. */
                         compact: false,
                         meetings: onDays)
        }
        .offset(x: dx)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `.myadhd-colhead` — the same 44pt gutter as the grid under it, so the
/// names sit over their own columns.
struct CalColumnHead: View {

    @Environment(\.theme) private var theme

    let days: [String]
    let today: String

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: HourGridMetrics.gutter, height: 1)
            ForEach(days, id: \.self) { key in
                let day = CalDayName.of(key)
                (Text(day.name + " ").foregroundColor(theme.muted)
                    + Text(day.number)
                        .foregroundColor(key == today ? theme.accent : theme.ink)
                        .font(Font.baloo(12, .bold)))
                    .font(Font.baloo(12))
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - a day key, read once

/// `Mon` and `14`, worked out from a `YYYY-MM-DD` key.
///
/// Both the strip and the column head used to do this inline in their own
/// bodies — a `keyToDate` and two `calendar.component` calls per day, on
/// every pass, and a body pass happens on every frame of a swipe. It is
/// the same three calls either way; the point is that they now happen
/// where they can be hoisted out of a loop rather than inside one.
struct CalDayName {
    var name: String
    var number: String

    static func of(_ key: String) -> CalDayName {
        let date = WebDates.keyToDate(key) ?? Date()
        let index = WebDates.calendar.component(.weekday, from: date) - 1
        return CalDayName(
            name: String(WebDates.dayNames[max(0, min(6, index))].prefix(3)),
            number: "\(WebDates.calendar.component(.day, from: date))"
        )
    }
}

// MARK: - swiping sideways

/// `swipeable(pane, step)` — a swipe left is forward in time. Horizontal
/// only: the first dozen points decide whether this is a swipe or a
/// scroll, and after that it is one or the other.
struct CalSideSwipe: ViewModifier {

    /// Days per swipe — and **zero means there is no swipe here at all.**
    /// The modifier sits on the calendar's one scroller now rather than
    /// inside a pane, so it is along for Month and List too, and Month has
    /// a sideways gesture of its own on the month pager. Rather than
    /// attach and detach the modifier — which would change the scroller's
    /// identity every time the view mode changed, and throw away its
    /// offset with it — it stays put and does nothing.
    let step: Int
    let session: CalendarSession
    @Binding var dx: CGFloat
    @Binding var busy: Bool

    @State private var mode: Character?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard step != 0, !busy else { return }
                        guard value.startLocation.x > HourGridMetrics.edge else { return }
                        if mode == nil {
                            mode = abs(value.translation.width) > abs(value.translation.height)
                                ? "h" : "v"
                        }
                        guard mode == "h" else { return }
                        dx = value.translation.width
                    }
                    .onEnded { value in
                        let wasHorizontal = mode == "h"
                        mode = nil
                        guard step != 0, !busy, wasHorizontal else { return }
                        let moved = value.translation.width
                        guard abs(moved) >= HourGridMetrics.swipeCommit else {
                            withAnimation(HourGridMetrics.glide) { dx = 0 }
                            return
                        }
                        commit(moved < 0 ? 1 : -1)
                    }
            )
    }

    /// Out over 220ms, the day changes underneath, and the new one comes
    /// in from the other side over another 220ms.
    private func commit(_ direction: Int) {
        busy = true
        let width = UIScreen.main.bounds.width
        withAnimation(HourGridMetrics.glide) { dx = -CGFloat(direction) * width }
        DispatchQueue.main.asyncAfter(deadline: .now() + HourGridMetrics.glideMS) {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                session.pick(WebDates.addDays(direction * step, toKey: session.picked))
                /* The grid under the thumb is the new day's now; it starts
                   off-screen on the far side. */
                dx = CGFloat(direction) * width
            }
            /* A turn later, not in this one. Two writes to the same state
               in one runloop pass are coalesced, and the far side would
               never be drawn — the new day would slide back the way the
               old one left instead of arriving from the other side. The
               web spends two `requestAnimationFrame`s on exactly this. */
            DispatchQueue.main.async {
                withAnimation(HourGridMetrics.glide) { dx = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + HourGridMetrics.glideMS) {
                    busy = false
                }
            }
        }
    }
}

// MARK: - the week strip

/// `weekStrip(base)` — Monday to Sunday of the picked week. The strip is
/// the frame the days move inside: a swipe changes which one is filled,
/// and the strip itself stays put.
struct CalWeekStrip: View {

    @Environment(\.theme) private var theme

    let base: String
    let today: String
    var onPick: (String) -> Void

    var body: some View {
        /* Mixed once for the row, not once per button: the same colour
           seven times over, and the seven were being remixed on every
           frame of a swipe. */
        let fill = Color(hex: QuadrantPalette.mix(accentHex, surfaceHex, 0.14))
        HStack(spacing: 4) {
            ForEach(CalDays.week(of: base), id: \.self) { key in
                button(key, fill: fill)
            }
        }
    }

    private func button(_ key: String, fill: Color) -> some View {
        let day = CalDayName.of(key)
        let picked = key == base
        let isToday = key == today

        return Button { onPick(key) } label: {
            VStack(spacing: 3) {
                Text(day.name)
                    .font(Font.baloo(11, .semibold))
                    .foregroundStyle(picked ? theme.accent : theme.muted)
                Text(day.number)
                    .font(Font.baloo(19, .bold))
                    .foregroundStyle(picked ? theme.accent : theme.ink)
                    .underline(isToday)
            }
            .padding(.top, 8)
            .padding(.bottom, 7)
            .frame(maxWidth: .infinity)
            .background {
                if picked {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(WebDates.dayLabel(key, today: today))
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : [.isButton])
    }

    private var accentHex: UInt32 { theme.dark ? 0x8B7DFF : 0x4737FF }
    private var surfaceHex: UInt32 { theme.dark ? 0x101018 : 0xFFFFFF }
}

// MARK: - the days a pane is showing

/// The one place that turns a reader into the meetings a pane needs.
/// Both panes ask the same question about a handful of days, and neither
/// should have to remember to drop the ones that have become tasks.
enum MeetingDays {
    /// `MeetingReader` is main-actor state, and so is every view that
    /// asks this.
    @MainActor
    static func on(_ days: [String],
                   from reader: MeetingReader?,
                   tasks: [TaskItem]) -> [Meeting]
    {
        guard let reader else { return [] }
        let want = Set(days)
        let found = reader.days.filter { want.contains($0.key) }.flatMap(\.value)
        return AgendaEntry.unclaimed(found, by: tasks)
    }
}

// MARK: - anytime

/// `anytime(days)` — everything on these days with no clock on it, six
/// chips and then a count. Open only: a finished loose task is not
/// waiting for anything.
struct AnytimeChips: View {

    @Environment(\.theme) private var theme

    let tasks: [TaskItem]
    let days: [String]

    /// The all-day ones join the chips rather than the grid. This row is
    /// already the place for everything true of the day but not of an
    /// hour, which is exactly what an all-day event is.
    var meetings: [Meeting] = []

    private var allDay: [Meeting] {
        meetings.filter { $0.at == nil }
    }

    private var items: [TaskItem] {
        let want = Set(days)
        return tasks.filter { t in
            guard let when = t.when, want.contains(when) else { return false }
            return !((t.at.map { !$0.isEmpty }) ?? false) && !t.done && !t.skipped
        }
    }

    var body: some View {
        let items = self.items
        let allDay = self.allDay
        if !items.isEmpty || !allDay.isEmpty {
            ChipFlow(spacing: 6, lineSpacing: 6) {
                Text(Copy.CalViews.anytime)
                    .font(Font.baloo(11))
                    .foregroundStyle(theme.muted)

                /* The meetings lead. An all-day event is true of the day
                   whether you like it or not; a task with no clock is
                   merely unscheduled, and that is the softer fact. */
                ForEach(allDay, id: \.occurrenceID) { meeting in
                    chip(meeting.title, mine: false)
                }

                ForEach(items.prefix(Copy.CalViews.anytimeMax), id: \.id) { task in
                    chip(task.title, mine: true)
                }

                if items.count > Copy.CalViews.anytimeMax {
                    Text(Copy.CalViews.andMore(items.count - Copy.CalViews.anytimeMax))
                        .font(Font.baloo(11))
                        .foregroundStyle(theme.muted)
                }
            }
            .padding(.bottom, 10)
        }
    }

    /// One shape, two fillings. Yours is the washed chip it has always
    /// been; somebody else's is hollow, which is the same distinction the
    /// blocks below make and costs no new colour.
    private func chip(_ title: String, mine: Bool) -> some View {
        Text(title)
            .font(Font.baloo(12))
            .foregroundStyle(mine ? theme.ink : theme.inkSoft)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(mine ? theme.wash : theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(mine ? theme.line : theme.lineStrong,
                                            lineWidth: mine ? 1 : 1.5))
    }
}

// MARK: - the grid

struct HourGridView: View {

    @Environment(\.theme) private var theme

    let days: [String]
    let tasks: [TaskItem]
    let today: String
    let hourHeight: CGFloat
    /// Week: tighter blocks, smaller titles, no second line.
    let compact: Bool

    /// The hours somebody else booked. Only the timed ones draw here; the
    /// all-day ones are chips above the grid.
    var meetings: [Meeting] = []

    /// The hour a fresh entry into the view scrolls to: two before the
    /// current one when today is on screen, and the start of the working
    /// day when it is not.
    static func focusHour(days: [String], today: String) -> Int {
        guard days.contains(today) else { return 7 }
        let hour = WebDates.calendar.component(.hour, from: Date())
        return max(0, hour - 2)
    }

    /// What `ScrollViewProxy` scrolls to. One id per hour, per view.
    static func anchor(_ hour: Int) -> String { "myadhd.hour.\(hour)" }

    /// Every task that belongs in a column, bucketed by its day, once.
    ///
    /// `column(_:)` used to run this filter itself — so the whole task list
    /// was walked once per column, per body pass, and a body pass happens
    /// on every frame of a swipe. One walk now, and each column is handed
    /// its own.
    private var byDay: [String: [TaskItem]] {
        let want = Set(days)
        var out: [String: [TaskItem]] = [:]
        for task in tasks {
            guard let when = task.when, want.contains(when), !task.skipped else { continue }
            guard (task.at.map { !$0.isEmpty }) ?? false else { continue }
            out[when, default: []].append(task)
        }
        return out
    }

    /// The same bucketing for meetings, timed ones only.
    private var meetingsByDay: [String: [Meeting]] {
        let want = Set(days)
        var out: [String: [Meeting]] = [:]
        for meeting in meetings {
            guard want.contains(meeting.when), meeting.at != nil else { continue }
            out[meeting.when, default: []].append(meeting)
        }
        return out
    }

    var body: some View {
        let byDay = self.byDay
        let meetingsByDay = self.meetingsByDay
        HStack(alignment: .top, spacing: 0) {
            hours
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { key in
                    column(key,
                           blocks: byDay[key] ?? [],
                           meetings: meetingsByDay[key] ?? [])
                }
            }
        }
        .overlay(alignment: .top) { theme.line.frame(height: 1) }
    }

    /// `00:00` … `23:00`, lifted 6pt so each label sits on its own line
    /// rather than under it.
    private var hours: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(Font.baloo(10.5))
                    .foregroundStyle(theme.faint)
                    .offset(y: -6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: hourHeight, alignment: .top)
                    .padding(.leading, 2)
                    .id(Self.anchor(hour))
            }
        }
        .frame(width: HourGridMetrics.gutter, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func column(_ key: String,
                        blocks: [TaskItem],
                        meetings: [Meeting]) -> some View
    {
        ZStack(alignment: .topLeading) {
            lines
            /* Meetings go down first so a task you scheduled on top of one
               draws over it. Both are true; the one you can act on is the
               one worth reading. */
            ForEach(meetings, id: \.occurrenceID) { meeting in
                meetingBlock(meeting)
            }
            ForEach(blocks, id: \.id) { task in
                block(task)
            }
            if key == today { nowLine }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: hourHeight * 24, alignment: .top)
        .overlay(alignment: .leading) { theme.line.frame(width: 1) }
    }

    /// The 24 hour rules, as one drawing.
    ///
    /// This was a `VStack` of 24 nested `VStack`s — 48 views per column,
    /// and there are three columns, all of it built eagerly inside a
    /// non-lazy scroller. On the web it was a single
    /// `repeating-linear-gradient` (reference/BridgeScript.swift:369),
    /// which is what a `Canvas` is: one view, one pass, no layout.
    private var lines: some View {
        Canvas { context, size in
            let rule = Path { p in
                for hour in 0..<24 {
                    let y = CGFloat(hour) * hourHeight
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            context.stroke(rule, with: .color(theme.line), lineWidth: 1)
        }
        .frame(height: hourHeight * 24)
        .allowsHitTesting(false)
    }

    // MARK: one block

    private func block(_ task: TaskItem) -> some View {
        let start = CGFloat(WebDates.clockMinutes(task.at) ?? 0)
        let length = CGFloat(max(20, task.minutes))
        let height = max(hourHeight * 0.5, length / 60 * hourHeight - 2)
        /* `!task.done && task.when < t` — the strict boundary again. */
        let late = !task.done && Ordering.jsLess(task.when ?? "", today)
        let hue = late ? theme.orange : theme.accent
        let hueHex: UInt32 = late ? 0xF75C03 : (theme.dark ? 0x8B7DFF : 0x4737FF)
        let surfaceHex: UInt32 = theme.dark ? 0x101018 : 0xFFFFFF

        return VStack(alignment: .leading, spacing: 0) {
            Text(task.title)
                .font(Font.baloo(compact ? 9.5 : 12.5, .semibold))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .strikethrough(task.done)

            if !compact, let at = WebDates.timeLabel(task.at) {
                Text(Copy.CalViews.blockMeta(time: at, minutes: Int(length)))
                    .font(Font.baloo(10.5))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, compact ? 5 : 8)
        .padding(.trailing, compact ? 3 : 6)
        .padding(.vertical, compact ? 3 : 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .top)
        .background(Color(hex: QuadrantPalette.mix(hueHex, surfaceHex, 0.15)))
        .overlay(alignment: .leading) { hue.frame(width: compact ? 2 : 3) }
        .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous))
        .opacity(task.done ? 0.45 : 1)
        .padding(.horizontal, 3)
        .offset(y: start / 60 * hourHeight)
        .accessibilityElement(children: .combine)
    }

    /// A meeting, on the same rail and in the same geometry as a task —
    /// and hollow rather than filled.
    ///
    /// **No new colour is spent on it.** Violet on this grid means a
    /// thing you decided to do and orange means one you have missed;
    /// giving an hour somebody else booked either of them would stop both
    /// meaning anything. So the difference is the treatment: a task is a
    /// tinted block with a solid rail, a meeting is the page showing
    /// through inside a drawn edge. It reads at a glance without reading
    /// the words, which is the whole job of a block on an hour grid.
    private func meetingBlock(_ meeting: Meeting) -> some View {
        let start = CGFloat(WebDates.clockMinutes(meeting.at) ?? 0)
        let length = CGFloat(max(20, meeting.minutes))
        let height = max(hourHeight * 0.5, length / 60 * hourHeight - 2)

        return VStack(alignment: .leading, spacing: 0) {
            Text(meeting.title)
                .font(Font.baloo(compact ? 9.5 : 12.5, .semibold))
                .foregroundStyle(theme.inkSoft)
                .lineLimit(1)
                .truncationMode(.tail)

            if !compact, let at = WebDates.timeLabel(meeting.at) {
                Text(Copy.CalViews.blockMeta(time: at, minutes: Int(length)))
                    .font(Font.baloo(10.5))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, compact ? 5 : 8)
        .padding(.trailing, compact ? 3 : 6)
        .padding(.vertical, compact ? 3 : 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .top)
        .background(theme.surface)
        .overlay(alignment: .leading) { theme.lineStrong.frame(width: compact ? 2 : 3) }
        /* `lineStrong` and not `line`. On a dark page the block's ground
           IS the page — that is what makes it read as hollow — so the
           edge is the only thing drawing it, and the hairline used
           between rows on a white card disappears here. */
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous)
                .strokeBorder(theme.lineStrong, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous))
        .padding(.horizontal, 3)
        .offset(y: start / 60 * hourHeight)
        .accessibilityElement(children: .combine)
    }

    /// `.myadhd-now` — 2pt of `--danger` across the day, with a dot on the
    /// hour column's edge.
    ///
    /// **And it moves.** The web re-rendered the calendar every 60s
    /// (reference/BridgeScript.swift:1087) and the port kept the `Date()`
    /// read without the thing that re-read it, so the line sat wherever it
    /// was when the view was built and only ever moved if something else
    /// happened to invalidate the body. A `TimelineView` around this line
    /// alone is the missing interval — around the line, not the grid, so
    /// the minute tick costs one redraw of a 2pt bar rather than of 24
    /// hours × three columns.
    private var nowLine: some View {
        TimelineView(.periodic(from: .now, by: 60)) { tick in
            let parts = WebDates.calendar.dateComponents([.hour, .minute], from: tick.date)
            let minutes = CGFloat((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            theme.danger
                .frame(height: 2)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(theme.danger)
                        .frame(width: 10, height: 10)
                        .offset(x: -5)
                }
                .offset(y: minutes / 60 * hourHeight)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
