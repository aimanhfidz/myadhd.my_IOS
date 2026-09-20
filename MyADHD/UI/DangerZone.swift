/* ============================================================
   MyADHD/UI/DangerZone.swift — "Clear my head", the other meaning

   `resetClear` / `stepClear` (app.js:1615-1657), `.danger-zone`
   (app.html:381-392, styles.css).

   Two confirmations, because there is no undo and no backup. The tick
   feeds a count and the swipe leaves a toast with a way back in it; this
   one does not. Everything goes, finished tasks included — `n` counts ALL
   of them, not the open ones, which is why the second sentence says
   permanently and means it.

   **Three presses, and each one says something different.**

   1. `Clear everything` — quiet, grey, the size of a caption. It is at the
      bottom of the screen under a rule because it is the last thing you
      should find, not the first.
   2. `Delete all N tasks on your lists? This cannot be undone.` with
      `Yes, clear everything`.
   3. `Last check — this permanently deletes all N and there is no backup.`
      with `Delete all N`, on red. The count is in the button because by
      here the number is the thing being agreed to.

   **And it disarms itself after 20 seconds.** A half-pressed confirm
   cannot sit there waiting for a stray tap. On the web it also disarms on
   any repaint, because `goToNext()` ends in `resetClear()` — here a
   repaint happens on every store write and means nothing, so the same
   effect is hung off the thing that actually changed: the task count
   moving under it.
   ============================================================ */

import SwiftUI

struct DangerZone: View {

    @Environment(\.theme) private var theme

    let store: AppStore
    let toasts: ToastCenter

    /// `setTimeout(resetClear, 20000)`.
    static let disarmAfter: TimeInterval = 20

    /// 0 = quiet button, 1 = first ask, 2 = last check.
    @State private var stage = 0
    @State private var disarm: Task<Void, Never>?

    /// `const n = state.tasks.length` — every task, done ones too.
    private var count: Int { store.doc.tasks.count }

    /* What counts as "the lists were repainted". On the web the disarm is
       `resetClear()` at the foot of `goToNext()`, so it fires for a tick,
       an undo, a removal, a re-sort, a new dump and a filter change — and
       NOT for a rewording or a breakdown, because neither of those repaints
       the lists. This is that set, said as a value: which tasks there are
       and which of them are done. */
    private var repaintSignature: [String] {
        store.doc.tasks.map { $0.id + ($0.done ? "1" : "0") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // `border-top:1.5px solid var(--line)`, not a hairline
            theme.line.frame(height: 1.5)
                .padding(.bottom, 20)

            if stage == 0 {
                Button {
                    step()
                } label: {
                    Text(Copy.DangerZone.clearAll)
                        .font(Font.baloo(13.5, .semibold))
                        .foregroundStyle(theme.faint)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                confirm
            }
        }
        .padding(.top, 34)
        .onChange(of: repaintSignature) { _, _ in reset() }
        .onDisappear { disarm?.cancel() }
    }

    /// `.clear-confirm`, and `.is-final` on the second ask.
    private var confirm: some View {
        let final = stage >= 2

        return VStack(alignment: .leading, spacing: 0) {
            Text(final ? Copy.DangerZone.lastAsk(count) : Copy.DangerZone.firstAsk(count))
                .font(Font.baloo(14, .medium))
                .lineSpacing(14 * 0.55)
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 13)

            HStack(spacing: 9) {
                Button {
                    reset()
                } label: {
                    Text(Copy.DangerZone.cancel)
                        .font(Font.baloo(14, .medium))
                        .foregroundStyle(theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(theme.lineStrong, lineWidth: 1.5))
                }
                .buttonStyle(.plain)

                Button {
                    step()
                } label: {
                    Text(final ? Copy.DangerZone.lastGo(count) : Copy.DangerZone.firstGo)
                        .font(Font.baloo(14, .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(theme.danger, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 17)
        .background(final ? theme.dangerWash : theme.wash)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(final ? theme.dangerEdge : theme.lineStrong, lineWidth: 1.5)
        )
        .overlay(alignment: .leading) { theme.dangerInk.frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .transition(.opacity.combined(with: .offset(y: 10)))
    }

    // MARK: -

    private func step() {
        let next = stage + 1
        guard next <= 2 else {
            /* The third press. `clearAll()` orphans every calendar event on
               the way out and writes an empty list; the toast is the only
               thing left that says how much went. */
            let gone = store.clearAll()
            reset()
            toasts.show(Copy.DangerZone.cleared(gone))
            return
        }

        withAnimation(Theme.ease(0.22)) { stage = next }
        arm()
    }

    /// Don't leave it armed.
    private func arm() {
        disarm?.cancel()
        disarm = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.disarmAfter * 1_000_000_000))
            guard !Task.isCancelled else { return }
            reset()
        }
    }

    private func reset() {
        disarm?.cancel()
        disarm = nil
        guard stage != 0 else { return }
        withAnimation(Theme.ease(0.22)) { stage = 0 }
    }
}
