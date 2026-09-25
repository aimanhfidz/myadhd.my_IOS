/* ============================================================
   MyADHD/UI/UndatedTray.swift — the things with no day, under the month

   `#cal-undated` (app.js:2369-2374) was one line at the foot of the
   calendar: how many open tasks have no day, and that they are waiting on
   your lists. It said so and could do nothing about it. Here the same
   line sits straight under the grid and opens, and what it opens is those
   tasks as chips you can hold and drop onto a day.

   **Why under the grid and not at the foot.** The drop target is the
   grid, and the scroller stands still while a task is in the air — so a
   tray at the bottom of a long agenda could lift a chip with no day on
   screen to put it on. Directly under the grid, one row high and
   scrolling sideways, it never pushes the grid off the top.

   **What a drop writes.** The day, and 8am (`MonthTaskDrag.undatedAt`)
   — see `AppStore.scheduleUndated` for why only where there was no clock,
   and why its Undo is not `moveToDay`'s. The day that was dropped on is
   then picked, so the agenda under the tray shows the task arriving.

   **Its words are the web's.** The toggle is the old line with a chevron
   that turns over, as the done pile's is (`DonePile`), and a drop says
   the matrix's and the agenda's `Moved to …` — so there is no sentence
   here without an original for `Checks/copy.sh` to find. Open or shut is
   remembered under `myadhd.native.calTray`, shut to begin with.
   ============================================================ */

import SwiftUI

struct UndatedTray: View {

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var stillMotion

    /// Open and undated, in the order the lists' `No date yet` uses.
    let tasks: [TaskItem]
    let today: String
    let store: AppStore
    let toasts: ToastCenter
    let drag: MonthTaskDrag
    /// A task came down on this day.
    var landed: (String) -> Void = { _ in }

    static let openKey = "myadhd.native.calTray"

    @State private var isOpen = UserDefaults.standard.bool(forKey: UndatedTray.openKey)

    var body: some View {
        if let line = Copy.Calendar.undated(tasks.count) {
            VStack(alignment: .leading, spacing: 0) {
                toggle(line)
                if isOpen {
                    strip
                        .transition(.opacity)
                }
            }
            .padding(.top, 14)
        }
    }

    // MARK: the line, which is the button

    private func toggle(_ line: String) -> some View {
        Button {
            let next = !isOpen
            withAnimation(stillMotion ? nil : Theme.ease(0.2)) { isOpen = next }
            UserDefaults.standard.set(next, forKey: Self.openKey)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(line)
                    .font(Font.baloo(13))
                    .lineSpacing(13 * 0.55)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .foregroundStyle(theme.faint)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(theme.wash, in: RoundedRectangle(cornerRadius: Theme.radiusLg,
                                                         style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : [.isButton])
    }

    // MARK: the chips

    /// One row, sideways. It stands still while a chip is in the air, as
    /// the calendar's own scroller does.
    private var strip: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(tasks, id: \.id) { task in
                    chip(task)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(drag.isDragging)
        .padding(.top, 10)
    }

    private func chip(_ task: TaskItem) -> some View {
        let lifted = drag.isLifted(task.id)
        return Text(task.title)
            .font(Font.baloo(13.5, .semibold))
            .foregroundStyle(theme.ink)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 200, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.lineStrong, lineWidth: 1.5))
            .contentShape(Capsule())
            .holdToLift(in: MonthTaskDrag.space,
                        press: { drag.touchDown(task.id) },
                        lift: { drag.raise(task, at: $0) },
                        move: { drag.moved(to: $0) },
                        end: { land(task) },
                        cancel: { drag.abandon(task.id) })
            .opacity(lifted ? 0.3 : 1)
            .scaleEffect(drag.isPressed(task.id) ? 0.97 : 1)
            .animation(Theme.ease(0.18), value: lifted)
            .animation(Theme.ease(0.14), value: drag.isPressed(task.id))
            .accessibilityLabel(task.title)
    }

    // MARK: the drop

    /// Down between the cells, or never lifted, is nothing. Anywhere else
    /// is that day at 8am, with the way back on the toast.
    private func land(_ task: TaskItem) {
        guard let day = drag.release(task.id) else { return }
        let id = task.id
        let clock = MonthTaskDrag.undatedAt
        guard let was = store.scheduleUndated(id, on: day, at: clock) else { return }
        let at = (task.at ?? "").isEmpty ? clock : task.at
        let label = WebDates.whenLabel(when: day, at: at, today: today)
            ?? WebDates.dayLabel(day, today: today)
        toasts.show(Copy.Calendar.movedTo(label: label)) {
            store.restoreTiming(id, when: was.when, at: was.at)
        }
        landed(day)
    }
}
