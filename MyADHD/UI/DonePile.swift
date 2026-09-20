/* ============================================================
   MyADHD/UI/DonePile.swift — what you already did

   `renderDone` (app.js:1564-1609), `.done-block` (styles.css),
   `#done-toggle` (app.html:373-379).

   Collapsed by default, and that is the whole design of it. The pile is
   proof the day went somewhere, not a second list to read: it opens when
   asked and closes again, and a repaint never touches whether it is open
   — on the web because `renderDone` only writes the count and the rows,
   here because the flag is `@State` on the screen rather than something
   derived from the store.

   **Twenty, and then a sentence.** `DONE_SHOWN` is 20. Nobody undoes the
   fortieth thing they ticked last Tuesday; past that the pile is a wall of
   text to scroll under. The rest get counted in one line that also says
   where they go: finished tasks clear themselves after a week, which is
   `pruneDone()` and is the only reason the pile has a floor at all.

   **Undo here is not the toast's Undo.** The toast's is six seconds long
   and belongs to the tick that just happened. This one has no clock on it
   and belongs to anything still in the pile — it is the same call
   underneath (`done = false`, `doneAt = nil`), and the same reason: a task
   back on the lists is no longer ageing out.
   ============================================================ */

import SwiftUI

struct DonePile: View {

    @Environment(\.theme) private var theme

    /// Every finished task on the store — the count is all of them, the
    /// rows are the most recent twenty.
    let done: [TaskItem]
    let store: AppStore
    @Binding var isOpen: Bool

    /// Newest first, missing stamps last (`b.doneAt || 0`).
    private var recent: [TaskItem] {
        let sorted = Ordering.stableSorted(done) { a, b in
            let d = Double(b.doneAt ?? 0) - Double(a.doneAt ?? 0)
            if d < 0 { return true }
            if d > 0 { return false }
            return nil
        }
        return Array(sorted.prefix(Copy.DonePile.shown))
    }

    private var hidden: Int { done.count - recent.count }

    var body: some View {
        if !done.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                toggle
                if isOpen {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(recent, id: \.id) { task in
                            item(task)
                        }
                        if hidden > 0 {
                            Text(Copy.DonePile.hiddenNote(hidden))
                                .font(Font.baloo(12.5))
                                .lineSpacing(12.5 * 0.45)
                                .foregroundStyle(theme.faint)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                        }
                    }
                    .padding(.top, 10)
                }
            }
            .padding(.top, 30)
        }
    }

    /// `.parked-toggle` — the count, and a chevron that turns over.
    private var toggle: some View {
        Button {
            withAnimation(Theme.ease(0.2)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 7) {
                Text(Copy.DonePile.count(done.count))
                    .font(Font.baloo(13.5, .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .foregroundStyle(theme.faint)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : [.isButton])
    }

    /// `.done-item` — the title struck through, and the way back.
    private func item(_ task: TaskItem) -> some View {
        HStack(spacing: 12) {
            Text(task.title)
                .font(Font.baloo(14.5))
                .strikethrough()
                .foregroundStyle(theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                store.undoDone(task.id)
            } label: {
                Text(Copy.DonePile.undo)
                    .font(Font.baloo(12.5, .bold))
                    .kerning(0.01 * 12.5)
                    .foregroundStyle(theme.orange)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .overlay(Capsule().strokeBorder(theme.orange, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background(theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.line, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
