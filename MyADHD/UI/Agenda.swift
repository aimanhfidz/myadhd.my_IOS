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

    private var overdue: [TaskItem] {
        picked == today ? Ordering.overdueTasks(tasks, today: today) : []
    }
    private var items: [TaskItem] { Ordering.tasksOn(tasks, picked) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !overdue.isEmpty {
                AgendaGroupSection(heading: Copy.Calendar.overdueHead(overdue.count),
                                   items: overdue,
                                   today: today,
                                   late: true,
                                   store: store,
                                   toasts: toasts)
            }

            if items.isEmpty {
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
                                   toasts: toasts)
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

    private var from: String { Ordering.jsLess(picked, today) ? picked : today }

    private var overdue: [TaskItem] {
        from == today ? Ordering.overdueTasks(tasks, today: today) : []
    }

    /// Fourteen days from `from`, and only the ones with something on them.
    private var days: [(key: String, items: [TaskItem])] {
        (0..<14).compactMap { offset in
            let key = WebDates.addDays(offset, toKey: from)
            let items = Ordering.tasksOn(tasks, key)
            return items.isEmpty ? nil : (key, items)
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
                                       toasts: toasts)
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
                ForEach(items, id: \.id) { task in
                    CalItemRow(task: task,
                               today: today,
                               late: late,
                               store: store,
                               toasts: toasts)
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

    var body: some View {
        SwipeRow(cornerRadius: Theme.radiusLg, onCommit: commit) {
            card
        }
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
