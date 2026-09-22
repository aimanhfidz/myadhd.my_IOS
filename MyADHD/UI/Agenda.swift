/* ============================================================
   MyADHD/UI/Agenda.swift — what is on the day you picked

   `renderAgenda` and `agendaGroup` (app.js:2378-2451), `.cal-group` and
   `.cal-item` (styles.css:1777-1812), and the shell's List view
   (BridgeScript.swift:938-956).

   **Overdue rides on today and nowhere else.** Anything already missed
   goes on top of today's list rather than staying buried on the day it
   was for, where you would have to go looking for it. Pick any other day
   and the group is not drawn — it is not news about that day.

   **A row here is not a lists row.** `ListTaskRow` draws the lists' card:
   the chips, the detail, the first step, the two repairs. What the
   calendar draws is `.cal-item` — a fixed 62pt time column so every title
   starts on the same line, and one meta line that says something
   different depending on whether the row is late. They are two different
   cards on purpose, so the row below is its own view. What it does NOT
   re-implement is the gesture: `SwipeRow` is the lists' swipe, exactly,
   with the same directions and the same commits (LEFT is Done, RIGHT is
   Remove), which is what `swipeRow(card, task, renderCalendar)` gets on
   the web by wrapping the same helper.

   **`any time` is not midnight.** A day with no clock on it is not a
   00:00 appointment and must not read as one.
   ============================================================ */

import SwiftUI

// MARK: - the day's groups

struct CalendarAgenda: View {

    @Environment(\.theme) private var theme

    let tasks: [TaskItem]
    let picked: String
    let today: String
    let store: AppStore
    let toasts: ToastCenter
    /// The month grid above this list is what a row can be dropped on.
    var dayDrag: MonthTaskDrag? = nil
    /// nil wherever meetings have not been wired in, and empty whenever
    /// the switch is off or the permission was refused. Both cases draw
    /// the agenda exactly as it was before any of this existed.
    var meetings: MeetingReader? = nil

    private var overdue: [TaskItem] {
        picked == today ? Ordering.overdueTasks(tasks, today: today) : []
    }
    private var items: [TaskItem] { Ordering.tasksOn(tasks, picked) }
    private var onDay: [Meeting] {
        AgendaEntry.unclaimed(meetings?.on(picked) ?? [], by: tasks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !overdue.isEmpty {
                AgendaGroupSection(heading: Copy.Calendar.overdueHead(overdue.count),
                                   items: overdue,
                                   today: today,
                                   late: true,
                                   store: store,
                                   toasts: toasts,
                                   dayDrag: dayDrag)
            }

            if items.isEmpty && onDay.isEmpty {
                Text(picked == today
                     ? Copy.Calendar.emptyToday
                     : Copy.Calendar.emptyDay(WebDates.dayPhrase(picked, today: today)))
                    .font(Font.baloo(14.5))
                    .lineSpacing(14.5 * 0.6)
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                    .padding(.horizontal, 10)
            } else {
                AgendaGroupSection(heading: WebDates.dayLabel(picked, today: today),
                                   items: items,
                                   today: today,
                                   late: false,
                                   store: store,
                                   toasts: toasts,
                                   dayDrag: dayDrag,
                                   meetings: onDay)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - the next two weeks (the shell's List view)

/// `renderList` (BridgeScript.swift:938-956). It starts at the picked day
/// when that is in the past, so paging back and switching to List does not
/// silently jump you forward to today.
struct CalendarListPane: View {

    @Environment(\.theme) private var theme

    let tasks: [TaskItem]
    let picked: String
    let today: String
    let store: AppStore
    let toasts: ToastCenter
    var meetings: MeetingReader? = nil

    private var from: String { Ordering.jsLess(picked, today) ? picked : today }

    private var overdue: [TaskItem] {
        from == today ? Ordering.overdueTasks(tasks, today: today) : []
    }

    /// Fourteen days from `from`, and only the ones with something on
    /// them — where something now includes a meeting. A day holding
    /// nothing but meetings used to be skipped, which would have hidden
    /// exactly the day this feature exists to show.
    private var days: [(key: String, items: [TaskItem], meetings: [Meeting])] {
        (0..<14).compactMap { offset in
            let key = WebDates.addDays(offset, toKey: from)
            let items = Ordering.tasksOn(tasks, key)
            let onDay = AgendaEntry.unclaimed(meetings?.on(key) ?? [], by: tasks)
            return items.isEmpty && onDay.isEmpty ? nil : (key, items, onDay)
        }
    }

    var body: some View {
        let days = self.days
        VStack(alignment: .leading, spacing: 18) {
            if !overdue.isEmpty {
                AgendaGroupSection(heading: Copy.Calendar.overdueHead(overdue.count),
                                   items: overdue,
                                   today: today,
                                   late: true,
                                   store: store,
                                   toasts: toasts)
            }

            if days.isEmpty {
                Text(Copy.CalViews.emptyList)
                    .font(Font.baloo(14.5))
                    .lineSpacing(14.5 * 0.6)
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                    .padding(.horizontal, 10)
            } else {
                ForEach(days, id: \.key) { day in
                    AgendaGroupSection(heading: WebDates.dayLabel(day.key, today: today),
                                       items: day.items,
                                       today: today,
                                       late: false,
                                       store: store,
                                       toasts: toasts,
                                       meetings: day.meetings)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - one heading and its rows

struct AgendaGroupSection: View {

    @Environment(\.theme) private var theme

    let heading: String
    let items: [TaskItem]
    let today: String
    /// The overdue group. Orange heading, orange rule, orange edge on
    /// every row under it.
    let late: Bool
    let store: AppStore
    let toasts: ToastCenter
    var dayDrag: MonthTaskDrag? = nil

    /// Read off the phone, interleaved with the tasks by the clock.
    /// Empty in the overdue group and left empty by every caller that has
    /// no reader — the section then draws exactly as it always has.
    ///
    /// **The overdue group never gets any.** Overdue is a list of things
    /// still to do that you have missed; a meeting that has been and gone
    /// is not one of them, and putting it under a heading that counts
    /// what you owe would be a lie about the number.
    var meetings: [Meeting] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading.uppercased())
                .font(Font.baloo(13, .bold))
                .kerning(0.06 * 13)
                .foregroundStyle(late ? theme.orange : theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 9)
                .overlay(alignment: .bottom) {
                    (late ? theme.orange : theme.line).frame(height: 1.5)
                }
                .padding(.bottom, 10)

            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(AgendaEntry.merge(tasks: items, meetings: meetings)) { entry in
                    switch entry {
                    case .task(let task):
                        CalItemRow(task: task,
                                   today: today,
                                   late: late,
                                   store: store,
                                   toasts: toasts,
                                   dayDrag: dayDrag)
                    case .meeting(let meeting):
                        CalMeetingRow(meeting: meeting, store: store, toasts: toasts)
                    }
                }
            }
        }
    }
}

// MARK: - one row

struct CalItemRow: View {

    @Environment(\.theme) private var theme

    let task: TaskItem
    let today: String
    /// Drawn inside the overdue group. It changes the edge and the meta
    /// line, and nothing else.
    let late: Bool
    let store: AppStore
    let toasts: ToastCenter
    /// Present only under the month grid, which is the only place with
    /// days on screen to drop a task onto. The List pane passes nil and
    /// the row behaves exactly as it always has.
    var dayDrag: MonthTaskDrag? = nil

    /// One touch, one press — `QuadrantCell`'s flag, for its reason.
    @State private var gestureLive = false

    private var lifted: Bool { dayDrag?.isLifted(task.id) ?? false }
    private var pressed: Bool { dayDrag?.isPressed(task.id) ?? false }

    var body: some View {
        /* The swipe stands down while the row is in the air: one finger
           cannot both tip a row over and carry it somewhere. */
        SwipeRow(isEnabled: !lifted, cornerRadius: Theme.radiusLg, onCommit: commit) {
            card
        }
        /* It fades in place rather than leaving, so the agenda does not
           reflow under the hand mid-drag. */
        .opacity(lifted ? 0.3 : 1)
        .scaleEffect(pressed ? 0.985 : 1)
        .animation(Theme.ease(0.18), value: lifted)
        .animation(Theme.ease(0.14), value: pressed)
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 11) {
            check
            slot
            VStack(alignment: .leading, spacing: 0) {
                Text(task.title)
                    .font(Font.baloo(15, .semibold))
                    .lineSpacing(15 * 0.35)
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(meta)
                    .font(Font.baloo(12.5))
                    .foregroundStyle(theme.faint)
                    .padding(.top, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            /* Bound to the title and its meta rather than to the whole
               row, so the tick and the time slot stay what they are —
               the line the matrix draws too (`watchPress` returns on
               `.task-check`, app.js:2748). A finished task never lifts;
               `moveToDay` would refuse it anyway. */
            .contentShape(Rectangle())
            .simultaneousGesture(canDrag ? hold : nil)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 15)
        .background(theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
                .strokeBorder(theme.line, lineWidth: 1.5)
        )
        /* `.cal-group--late .cal-item{border-left:3px solid var(--orange)}` */
        .overlay(alignment: .leading) {
            if late { theme.orange.frame(width: 3) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
    }

    private var check: some View {
        Button(action: markDone) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Color.clear)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(theme.lineStrong, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
        .accessibilityLabel(Copy.TaskRow.checkAria(title: task.title))
    }

    /// `.cal-slot` — a fixed 62pt column so every title starts on the same
    /// line, whatever the time in front of it is.
    private var slot: some View {
        let label = WebDates.timeLabel(task.at)
        return Text(label ?? Copy.Calendar.anyTime)
            .font(Font.baloo(13.5, label == nil ? .semibold : .bold))
            .foregroundStyle(label == nil ? theme.faint : theme.ink)
            .frame(width: 62, alignment: .leading)
            .padding(.top, 1)
    }

    private var meta: String {
        let minutes = WebDates.minutesLabel(task.minutes)
        guard late else {
            return Copy.Calendar.itemMeta(minutes: minutes, energy: task.energy)
        }
        return Copy.Calendar.lateMeta(day: WebDates.dayLabel(task.when ?? "", today: today),
                                      minutes: minutes)
    }

    // MARK: hold, then drop it on a day

    private var canDrag: Bool { dayDrag != nil && !task.done }

    /// The matrix's gesture, aimed at a month instead of four quadrants.
    private var hold: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(MonthTaskDrag.space))
            .onChanged { value in
                guard let dayDrag else { return }
                if !gestureLive {
                    gestureLive = true
                    dayDrag.press(task, at: value.startLocation)
                }
                dayDrag.moved(to: value.location)
            }
            .onEnded { _ in
                gestureLive = false
                land()
            }
    }

    /// A drop that never lifted, or that came down between the cells, is
    /// nothing. A drop onto the day the task is already on is refused by
    /// the store and says nothing either.
    private func land() {
        guard let dayDrag, let to = dayDrag.release() else { return }
        let id = task.id
        let from = task.when
        guard store.moveToDay(id, to: to) else { return }
        toasts.show(Copy.Calendar.movedTo(label: WebDates.dayLabel(to, today: today))) {
            store.moveToDay(id, to: from)
        }
    }

    // MARK: what a row does

    private func commit(_ outcome: SwipeOutcome) {
        switch outcome {
        case .done:   markDone()
        case .remove: remove()
        }
    }

    private func markDone() {
        let id = task.id
        guard store.markDone(id) else { return }
        toasts.show(Copy.TaskRow.done) { store.undoDone(id) }
    }

    private func remove() {
        guard let removal = store.removeTask(task.id) else { return }
        toasts.show(Copy.TaskRow.removed) { store.undoRemove(removal) }
    }
}

// MARK: - a meeting's row

/// Deliberately not a `CalItemRow` with a flag on it.
///
/// **No tick, and no swipe.** A task row commits Done on a swipe left and
/// Remove on a swipe right, and neither verb means anything here: you
/// cannot finish somebody else's meeting and deleting it from my.adhd
/// would delete nothing. Giving the row those gestures and then refusing
/// them is worse than not having them — it teaches that a swipe sometimes
/// does nothing.
///
/// **A washed ground instead of a white card.** A task sits on
/// `surface`; this sits on `wash`, which is the same move the app already
/// makes for a thing you are reading rather than acting on. No new colour
/// is spent: orange still means act now and red still means destructive.
///
/// The glyph stands where the tick stands so every title in the day
/// starts on the same line, whichever kind of row it is on.
struct CalMeetingRow: View {

    @Environment(\.theme) private var theme

    let meeting: Meeting
    let store: AppStore
    let toasts: ToastCenter

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            glyph
            slot
            VStack(alignment: .leading, spacing: 0) {
                Text(meeting.title)
                    .font(Font.baloo(15, .semibold))
                    .lineSpacing(15 * 0.35)
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(meta)
                    .font(Font.baloo(12.5))
                    .foregroundStyle(theme.faint)
                    .padding(.top, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                makeTask
                    .padding(.top, 9)
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 15)
        .background(theme.wash)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
                .strokeBorder(theme.line, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
    }

    /// Where the tick would be. Not a button, and it does not look like
    /// one: nothing about this row is yours to press except the one thing
    /// that is.
    private var glyph: some View {
        Image(systemName: "calendar")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.muted)
            .frame(width: 24, height: 24)
            .padding(.top, 1)
            .accessibilityHidden(true)
    }

    /// The same fixed 62pt column a task row uses.
    private var slot: some View {
        let label = WebDates.timeLabel(meeting.at)
        return Text(label ?? Copy.Meetings.allDay)
            .font(Font.baloo(13.5, label == nil ? .semibold : .bold))
            .foregroundStyle(label == nil ? theme.faint : theme.ink)
            .frame(width: 62, alignment: .leading)
            .padding(.top, 1)
    }

    private var meta: String {
        guard !meeting.isAllDay else {
            return Copy.Meetings.allDayMeta(calendar: meeting.calendarTitle)
        }
        return Copy.Meetings.meta(calendar: meeting.calendarTitle,
                                  minutes: WebDates.minutesLabel(meeting.minutes))
    }

    /// The one thing on this row that does something. It COPIES the
    /// meeting into your own lists — the calendar it came from is not
    /// touched, and the meeting is still the meeting.
    private var makeTask: some View {
        Button(action: claim) {
            Text(Copy.Meetings.makeTask)
                .font(Font.baloo(12.5, .bold))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.lineStrong, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    /// `applyTriage` and not a bespoke insert, so a meeting whose title is
    /// already on a list is caught by the same de-dupe every dump gets,
    /// and the toast is the sentence the web already says for it.
    private func claim() {
        let result = store.applyTriage([meeting.asTask()])
        guard let said = Copy.Triage.result(added: result.added, dupes: result.dupes) else { return }
        toasts.show(said)
    }
}
