/* ============================================================
   my.adhd for iOS — a task, drawn as one row

   Shared for the same reason TimelineBand is: the Today checklist, the
   Agenda columns and the large timeline all draw the same row, and three
   copies of it would drift apart the first time any one of them was
   touched.

   No WidgetKit, no AppIntents, no UIKit — so ImageRenderer can put any of
   this into a PNG on a Mac with no simulator runtime anywhere. That is the
   only way these layouts get checked before they reach a phone, and it is
   why the tick control arrives as a generic slot rather than being built
   in: Button(intent:) needs AppIntents, cannot be rendered, and does not
   belong in the drawing.
   ============================================================ */

import SwiftUI

// MARK: - the three nothings

/// A widget that cannot read the snapshot, a snapshot with no tasks in it,
/// and a list that has been worked all the way down are three different
/// things and want three different sentences. "No tasks" for a phone that
/// has never opened the app is a lie about the app.
enum Nothing {
    static func line(_ snapshot: TaskSnapshot?) -> String {
        guard let snapshot else { return "Open my.adhd once to wake this up." }
        return snapshot.tasks.isEmpty ? "Head's clear." : "Nothing left in the queue."
    }
}

// MARK: - the tick control

/// The box itself, with no button around it. The widget wraps this in
/// Button(intent:); the render harness wraps it in nothing at all.
struct TickBox: View {
    let done: Bool
    var size: CGFloat = 17

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(done ? CategoryTint.accent(scheme) : Color.secondary.opacity(0.5),
                              lineWidth: 1.5)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .fill(done ? CategoryTint.accent(scheme) : .clear)
                )
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(scheme == .dark ? Color.black : Color.white)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - the row

struct TaskRow<Lead: View>: View {

    let task: SnapTask
    /// The day "late" is measured against — snapshot.effectiveDay(now),
    /// not the raw snapshot day, which may be yesterday's.
    let day: String
    var titleSize: CGFloat = 13
    var lines: Int = 1
    var showMeta: Bool = true
    /// False inside a column that is already headed with the day. Saying
    /// "Tomorrow · 8.30am" under a heading that says TOMORROW spends half
    /// the row's width repeating it, and the title pays for it.
    var showDay: Bool = true

    @ViewBuilder var lead: Lead

    private var late: Bool { task.isOverdue(on: day) }

    /* Meta on the trailing edge rather than under the title, which is what
       keeps a row one line high. Three rows plus a header and a footer do
       not fit in a 158pt tile any other way, and a footer that says how
       much is left is worth more than a second line saying "anytime". */
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            lead
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - titleSize * 0.19 }

            Text(task.title)
                .font(.baloo(titleSize, .semibold))
                .lineLimit(lines)
                .strikethrough(task.done, color: .secondary)
                .foregroundStyle(task.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))

            Spacer(minLength: 5)

            /* Vivid Orange, and only here. theme.css keeps it for the mark
               and for late; a row that spent it on anything else would
               stop the word meaning anything. */
            if pip {
                Circle().fill(CategoryTint.urgent).frame(width: 5, height: 5)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + titleSize * 0.13 }
            }

            if showMeta, let meta {
                Text(meta)
                    .font(.system(size: titleSize - 3, weight: .semibold))
                    .foregroundStyle(late ? AnyShapeStyle(CategoryTint.urgent)
                                          : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /* A small tile has no room for a trailing label — 158pt minus a box
       minus "9am" leaves about four characters of title, which is not a
       task, it is a rumour of one. There the meta comes off and the dot
       carries what is left of the urgency. A row whose meta already says
       "late" in words does not also need a dot. */
    private var pip: Bool {
        if task.done { return false }
        if late { return !showMeta }
        return task.urgency >= 5
    }

    /// "late" for something that has slipped, "9.30am" for a booked time,
    /// "Tomorrow · 8.30am" for another day, and how long it takes for
    /// something on no clock at all. The words the app uses, from the app's
    /// own formatter — except "anytime", which was a line of nothing.
    private var meta: String? {
        if late { return "late" }
        if let t = DayKey.timeLabel(task.at) {
            guard showDay, task.when != day else { return t }
            return "\(DayKey.dayLabel(task.when ?? day, today: day)) · \(t)"
        }
        if showDay, let when = task.when, when != day {
            return DayKey.dayLabel(when, today: day)
        }
        return minutesLabel(task.minutes)
    }

    private func minutesLabel(_ m: Int) -> String {
        m < 60 ? "\(m) min" : String(format: "%.1f hr", Double(m) / 60)
    }
}

extension TaskRow where Lead == EmptyView {
    /// A row with nothing to tick — the agenda columns, the large timeline.
    init(task: SnapTask, day: String, titleSize: CGFloat = 13,
         lines: Int = 1, showMeta: Bool = true, showDay: Bool = true) {
        self.init(task: task, day: day, titleSize: titleSize,
                  lines: lines, showMeta: showMeta, showDay: showDay) { EmptyView() }
    }
}

// MARK: - an agenda row

/* Ink's Agenda row: a bar in the item's colour, the title, the time range
   beneath it. Different from TaskRow on purpose — that row is a checklist
   line with its meta on the trailing edge; this is a calendar line, and a
   calendar reads down the left. The bar is the category tint, or Vivid
   Orange once the task is late, which is the one thing that colour is for. */
struct AgendaRow: View {

    let task: SnapTask
    let day: String
    var titleSize: CGFloat = 12.5

    private var late: Bool { task.isOverdue(on: day) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(late ? CategoryTint.urgent : CategoryTint.of(task.category))
                .frame(width: 3)
                .padding(.vertical, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.baloo(titleSize, .semibold))
                    .lineLimit(1)
                    .strikethrough(task.done, color: .secondary)
                    .foregroundStyle(task.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Text(sub)
                    .font(.system(size: titleSize - 2.5, weight: .medium))
                    .foregroundStyle(late ? AnyShapeStyle(CategoryTint.urgent) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sub: String {
        if late { return "\(DayKey.dayLabel(task.when ?? day, today: day)) \u{00B7} late" }
        return DayKey.rangeLabel(task.at, minutes: task.minutes) ?? "anytime \u{00B7} \(task.minutes) min"
    }
}

// MARK: - a column of them

/// One day as a short list. Used twice by the Agenda tile and once under
/// the large band.
struct TaskColumn: View {

    let title: String
    let tasks: [SnapTask]
    let day: String
    var limit: Int = 4
    var titleSize: CGFloat = 12.5
    var emptyLine: String = "Nothing booked."
    var late: Bool = false
    var showDay: Bool = true
    /// Agenda rows — bar, title, time beneath — instead of checklist rows.
    var agenda: Bool = false

    private var heading: String {
        /* On an agenda column the overflow rides on the heading — "TODAY · +1"
           — rather than taking a row of its own. A medium tile has room for
           the date, two headings and three rows each, and not one line more. */
        agenda && tasks.count > limit ? "\(title) · +\(tasks.count - limit)" : title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: agenda ? 5 : 6) {
            Text(heading.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(late ? AnyShapeStyle(CategoryTint.urgent)
                                      : AnyShapeStyle(.secondary))

            if tasks.isEmpty {
                Text(emptyLine)
                    .font(.system(size: titleSize - 1.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            } else {
                ForEach(tasks.prefix(limit)) { t in
                    if agenda {
                        AgendaRow(task: t, day: day, titleSize: titleSize)
                    } else {
                        TaskRow(task: t, day: day, titleSize: titleSize, showDay: showDay)
                    }
                }
                if tasks.count > limit && !agenda {
                    Text("+\(tasks.count - limit) more")
                        .font(.system(size: titleSize - 2.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - two days, side by side

/* Ink's Agenda tile, which is the one widget of theirs that earns its
   place here unchanged: today and tomorrow as two columns. The snapshot
   already carried both — TaskBridge keeps a day ahead — and until `when`
   existed there was no way to tell them apart inside it.

   Late folds into the top of the Today column rather than getting a
   column of its own. Hiding it in a tile that is looking at tomorrow
   would be the exact failure this app exists to prevent. */
struct AgendaPair: View {

    let snapshot: TaskSnapshot?
    let now: Date
    var limit: Int = 4
    var titleSize: CGFloat = 12.5

    private var day: String { snapshot?.effectiveDay(now) ?? DayKey.of(now) }

    private var todayColumn: [SnapTask] {
        guard let snapshot else { return [] }
        return snapshot.ordered(now: now).filter { $0.isOverdue(on: day) || $0.when == day }
    }

    private var tomorrowColumn: [SnapTask] {
        guard let snapshot else { return [] }
        let next = DayKey.adding(1, to: day)
        return snapshot.ordered(now: now).filter { $0.when == next }
    }

    private var lateCount: Int {
        todayColumn.filter { $0.isOverdue(on: day) }.count
    }

    var body: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 6) {
                Text(DayKey.longLabel(day))
                    .font(.baloo(12.5, .bold))
                    .lineLimit(1)

                HStack(alignment: .top, spacing: 14) {
                    TaskColumn(title: lateCount > 0 ? "Today · \(lateCount) late" : "Today",
                               tasks: todayColumn, day: day, limit: limit,
                               titleSize: titleSize,
                               emptyLine: "Nothing booked today.",
                               late: lateCount > 0, agenda: true)

                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 1)

                    TaskColumn(title: DayKey.dayLabel(DayKey.adding(1, to: day), today: day),
                               tasks: tomorrowColumn, day: day, limit: limit,
                               titleSize: titleSize,
                               emptyLine: "Nothing booked yet.",
                               showDay: false, agenda: true)
                }

                if !snapshot.undated.isEmpty || snapshot.dropped > 0 {
                    HStack(spacing: 8) {
                        if !snapshot.undated.isEmpty {
                            Text("\(snapshot.undated.count) on no day")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        if snapshot.dropped > 0 {
                            Text("+\(snapshot.dropped) more")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text(Nothing.line(nil))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - the whole checklist

/* The Today tile's body, kept here rather than in the widget target so
   ImageRenderer can put the real thing into a PNG — not an approximation
   of it assembled out of the same parts, which is the version of this that
   passes while the tile it stands for is broken.

   `lead` is how the tick gets in. The widget passes a Button(intent:); the
   render harness passes the box on its own. Nothing about AppIntents or
   WidgetKit reaches this file. */
struct TodayList<Lead: View>: View {

    let snapshot: TaskSnapshot?
    let now: Date
    var rows: Int = 3
    var titleSize: CGFloat = 13.5
    var rowGap: CGFloat = 9
    var rowLines: Int = 1
    var showMeta: Bool = true
    @ViewBuilder var lead: (SnapTask) -> Lead

    @Environment(\.colorScheme) private var scheme

    private var tasks: [SnapTask] {
        snapshot?.ordered(now: now).prefix(rows).map { $0 } ?? []
    }

    private var late: Int {
        guard let snapshot else { return 0 }
        let today = snapshot.effectiveDay(now)
        return snapshot.tasks.filter { $0.isOverdue(on: today) }.count
    }

    /* The heading carries the bad news, because it is the line that gets
       read whether or not the rows below it do. Same words as the app's
       own Today card, and the same single use of Vivid Orange. */
    private var title: String {
        guard let snapshot else { return "MY.ADHD" }
        if late > 0 { return late == 1 ? "1 LATE" : "\(late) LATE" }
        return snapshot.todayTasks.contains { !$0.done } ? "TODAY" : "NEXT UP"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title)
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(late > 0 ? AnyShapeStyle(CategoryTint.urgent)
                                              : AnyShapeStyle(.secondary))
                Spacer(minLength: 0)
                if snapshot?.isStale(now: now) == true {
                    Text("old").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }

            if tasks.isEmpty {
                Spacer(minLength: 0)
                Text(Nothing.line(snapshot))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: rowGap) {
                    ForEach(tasks) { task in
                        TaskRow(task: task,
                                day: snapshot?.effectiveDay(now) ?? DayKey.of(now),
                                titleSize: titleSize,
                                lines: rowLines,
                                showMeta: showMeta) { lead(task) }
                    }
                }
                .padding(.top, 7)

                Spacer(minLength: 4)
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let snapshot {
                let left = snapshot.tasks.filter { !$0.done }.count
                Text(left == 1 ? "1 left" : "\(left) left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if snapshot.doneToday > 0 {
                    Text("· \(snapshot.doneToday) done")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CategoryTint.accent(scheme))
                }
                if snapshot.dropped > 0 {
                    Text("· +\(snapshot.dropped)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - one day, small

/* Ink's small Agenda: the date, then today's items as agenda rows. Three
   fit; anything past that is a count, because a small tile that scrolls
   in the mind is a tile that does not get read. */
struct AgendaDay: View {

    let snapshot: TaskSnapshot?
    let now: Date
    var limit: Int = 3

    private var day: String { snapshot?.effectiveDay(now) ?? DayKey.of(now) }
    private var rows: [SnapTask] {
        guard let snapshot else { return [] }
        return snapshot.ordered(now: now).filter { $0.isOverdue(on: day) || $0.when == day }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(DayKey.longLabel(day))
                .font(.baloo(12.5, .bold))
                .lineLimit(1)

            if snapshot == nil || rows.isEmpty {
                Spacer(minLength: 0)
                Text(snapshot == nil ? Nothing.line(nil) : "Nothing booked today.")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Spacer(minLength: 0)
            } else {
                ForEach(rows.prefix(limit)) { t in
                    AgendaRow(task: t, day: day, titleSize: 12)
                }
                if rows.count > limit {
                    Text("+\(rows.count - limit) more")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
