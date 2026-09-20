/* ============================================================
   MyADHD/UI/ListTaskRow.swift — one thing, and everything you can do to it

   `renderTask` (app.js:1427-1552), `editTitle` (1754-1793), `breakDown`
   (1846-1873) and `paintSteps` (1554-1562).

   The row is two lines and a tick until it is asked for more. That is the
   whole argument the lists make: a page you can run your eye down beats a
   page that has already answered every question you did not ask. Tapping
   it opens the detail — the first step, the breakdown if there is one, and
   the two repairs.

   **The repairs are not decoration.** The model splits and rewrites, and
   it gets things wrong. Without Edit and Remove the only exits from a bad
   task are lying about it with the tick or clearing the whole store. Both
   live inside the detail so the row itself stays scannable.

   **What the row does NOT let you change.** Nothing in the web app edits
   `when`, `at`, `minutes`, `energy`, `category`, `urgency` or `importance`
   after triage — Edit is a rename and only a rename (inventory §1.7, and
   the stale comment at app.js:2738 that says otherwise). A row that let
   you retype a time would need a second sorter behind it to keep the
   quadrant and the calendar honest, and there is not one.

   **Where the open state lives.** On the web it lives on the DOM node, so
   every `goToNext()` throws it away and collapses every row. Here it is
   `ListsScreen`'s, keyed by task id, because in SwiftUI a repaint happens
   on every store write — ticking a task off in another bucket would
   otherwise shut the detail somebody was reading. Same intent, and the
   web's version of it is an accident of how it redraws.
   ============================================================ */

import SwiftUI

/* Named for the screen it belongs to, not for what it draws: `TaskRow` is
   already taken by Shared/TaskRows.swift, which is the widgets' generic row
   and is compiled into three targets. Shared/ does not move for the app. */
struct ListTaskRow: View {

    @Environment(\.theme) private var theme

    let task: TaskItem
    /// `dayKey()`, resolved once per paint by the screen so every row in
    /// one render agrees about what today is.
    let today: String
    let store: AppStore
    let toasts: ToastCenter

    /// Is the detail down. Held by the screen — see the file header.
    @Binding var isOpen: Bool

    /* The rewording is this row's own, the way `editTitle`'s guard is:
       `if (li.querySelector('.task-edit')) return;` asks about ONE row, so
       two rows can be open for renaming at once and each one commits on its
       own blur. A screen-wide "which row is being edited" would have looked
       tidier and would have thrown away a half-typed title the moment a
       second row was tapped. */
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var breakState = BreakState.idle

    private enum BreakState {
        case idle, working, done
    }

    // MARK: -

    var body: some View {
        SwipeRow(isEnabled: !isEditing,
                 onTap: { toggleDetail() },
                 onCommit: commit) {
            card
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 13) {
            check
            VStack(alignment: .leading, spacing: 0) {
                titleLine
                    .padding(.bottom, 8)
                ChipFlow(spacing: 6, lineSpacing: 6) {
                    chips
                }
                if isOpen { detail }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(isOpen ? theme.wash : theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isOpen ? theme.accent : theme.line, lineWidth: 1.5)
        )
        /* `.task--urgent` — a 3px orange edge down the left. Drawn over the
           border rather than instead of it, which is what the CSS does. */
        .overlay(alignment: .leading) {
            if task.urgency >= 5 {
                theme.orange.frame(width: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: tick it off

    private var check: some View {
        Button {
            markDone()
        } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Color.clear)
                .frame(width: 24, height: 24)
                .overlay(
                    Circle().strokeBorder(theme.lineStrong, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
        .accessibilityLabel(Copy.TaskRow.checkAria(title: task.title))
    }

    // MARK: the title, and the title while it is being reworded

    @ViewBuilder
    private var titleLine: some View {
        if isEditing {
            /* Sized and weighted exactly like the title it replaces, so the
               row does not jump on either swap. */
            TextField("", text: $draft)
                .font(Font.baloo(15.5, .semibold))
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(false)
                .submitLabel(.done)
                .focused($focused)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.accent, lineWidth: 1.5)
                )
                .accessibilityLabel(Copy.TaskRow.editAria)
                .onSubmit { finishEdit(commit: true) }
                .onChange(of: draft) { _, next in
                    // `input.maxLength = 160`, applied again because a
                    // paste can beat an attribute.
                    let capped = Normalize.slice(next, 160)
                    if capped != next { draft = capped }
                }
                .onChange(of: focused) { _, isFocused in
                    // blur commits, exactly as the web's does
                    if !isFocused { finishEdit(commit: true) }
                }
                .onAppear { focused = true }
        } else {
            Text(task.title)
                .font(Font.baloo(15.5, .semibold))
                .kerning(-0.01 * 15.5)
                .lineSpacing(15.5 * 0.35)
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: the chips

    @ViewBuilder
    private var chips: some View {
        chip(WebDates.minutesLabel(task.minutes),
             fill: theme.accent, edge: theme.accent, ink: theme.onAccent, weight: .semibold)

        chip(Copy.TaskRow.energyChip(task.energy),
             fill: theme.surface, edge: theme.lineStrong, ink: theme.muted, weight: .medium)

        if let stamp = WebDates.whenLabel(when: task.when, at: task.at, today: today) {
            let late = Ordering.rowIsLate(task, today: today)
            chip(stamp,
                 fill: theme.surface,
                 edge: late ? theme.orange : theme.lineStrong,
                 ink: late ? theme.orange : theme.inkSoft,
                 weight: .semibold)
        }

        if task.urgency >= 5 {
            chip(Copy.TaskRow.urgentChip,
                 fill: theme.orange, edge: theme.orange, ink: .white, weight: .semibold)
        }
    }

    private func chip(_ text: String,
                      fill: Color,
                      edge: Color,
                      ink: Color,
                      weight: Font.Weight) -> some View
    {
        Text(text)
            .font(Font.baloo(12, weight))
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(edge, lineWidth: 1.5))
    }

    // MARK: the detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            firstStep
                .padding(.bottom, 12)

            if let steps = task.steps, !steps.isEmpty {
                stepsBlock(steps)
                    .padding(.bottom, 12)
            }

            breakButton

            HStack(spacing: 8) {
                fixButton(Copy.TaskRow.edit, danger: false) { startEdit() }
                fixButton(Copy.TaskRow.remove, danger: true) { remove() }
            }
            .padding(.top, 10)
        }
        .padding(.top, 14)
    }

    /// `.first-step` — a wash panel with the accent down its left edge.
    private var firstStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            blockLabel(Copy.TaskRow.firstStepLabel, ink: theme.accent)
            Text(task.firstStep)
                .font(Font.baloo(15.5))
                .lineSpacing(15.5 * 0.55)
                .foregroundStyle(theme.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.wash)
        .overlay(alignment: .leading) { theme.accent.frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// `.steps-block` — the same panel, quieter, numbered.
    private func stepsBlock(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            blockLabel(Copy.TaskRow.stepsLabel, ink: theme.muted)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 11) {
                        Text("\(i + 1)")
                            .font(Font.baloo(11, .bold))
                            .foregroundStyle(theme.onAccent)
                            .frame(width: 21, height: 21)
                            .background(theme.accent, in: Circle())
                            .padding(.top, 1)
                        Text(step)
                            .font(Font.baloo(15))
                            .foregroundStyle(theme.inkSoft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 7)
                }
            }
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.wash)
        .overlay(alignment: .leading) { theme.lineStrong.frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func blockLabel(_ text: String, ink: Color) -> some View {
        Text(text.uppercased())
            .font(Font.baloo(10.5, .bold))
            .kerning(0.11 * 10.5)
            .foregroundStyle(ink)
    }

    /// `.task-break` — full width, and it stays disabled once it has run.
    private var breakButton: some View {
        Button {
            Task { await breakDown() }
        } label: {
            Text(breakLabel)
                .font(Font.baloo(14, .medium))
                .foregroundStyle(theme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.lineStrong, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(breakState != .idle)
        .opacity(breakState == .idle ? 1 : 0.45)
    }

    private var breakLabel: String {
        switch breakState {
        case .idle:    return Copy.TaskRow.breakDown
        case .working: return Copy.TaskRow.breakingDown
        case .done:    return Copy.TaskRow.brokenDown
        }
    }

    /// `.task-fix-btn` — deliberately the quietest thing in the detail:
    /// these are the exits, not the offer. The CSS only colours them on
    /// `:hover`, which a phone does not have; pressing is the nearest
    /// thing it does have, so that is where the colour goes.
    ///
    /// `--danger` is for the thing that cannot be undone. Removing one task
    /// can be, so the danger variant takes the softer `--danger-ink`.
    private func fixButton(_ title: String,
                           danger: Bool,
                           action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            Text(title)
                .font(Font.baloo(13, .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Capsule())
        }
        .buttonStyle(FixButtonStyle(rest: theme.faint,
                                    pressedInk: danger ? theme.dangerInk : theme.accent,
                                    pressedFill: danger ? theme.dangerWash : theme.wash))
    }

    // MARK: - what the row does

    private func toggleDetail() {
        /* A tap outside the field ends a rewording rather than shutting the
           row under it — the web gets this from the input's own blur. */
        if isEditing { finishEdit(commit: true); return }
        isOpen.toggle()
    }

    /// The swipe landed. Left was Done, right was Remove (app.js:3060).
    private func commit(_ outcome: SwipeOutcome) {
        switch outcome {
        case .done:   markDone()
        case .remove: remove()
        }
    }

    private func markDone() {
        let id = task.id
        guard store.markDone(id) else { return }
        toasts.show(Copy.TaskRow.done) {
            store.undoDone(id)
        }
    }

    private func remove() {
        guard let removal = store.removeTask(task.id) else { return }
        toasts.show(Copy.TaskRow.removed) {
            store.undoRemove(removal)
        }
    }

    // MARK: rewording

    private func startEdit() {
        // `if (li.querySelector('.task-edit')) return;`
        guard !isEditing else { return }
        draft = task.title
        isEditing = true
    }

    /// `finish(commit)` — and it runs once. Enter and blur both land here,
    /// and on a phone they land here together: the keyboard's Done button
    /// submits and then resigns first responder, which is a second blur.
    private func finishEdit(commit: Bool) {
        guard isEditing else { return }
        isEditing = false
        guard commit else { return }
        if store.editTitle(task.id, to: draft) {
            toasts.show(Copy.TaskRow.reworded)
        }
    }

    // MARK: breaking it down

    @MainActor
    private func breakDown() async {
        guard breakState == .idle else { return }
        breakState = .working
        do {
            let answer = try await TriageClient().breakdown(task: task.title)
            store.applyBreakdown(task.id, steps: answer.steps, firstStep: answer.firstStep)
            breakState = .done   // 'Broken down ✓', and it stays disabled
        } catch {
            breakState = .idle
            toasts.show(Copy.TaskRow.breakDownFailed)
        }
    }
}

// MARK: - the two exits

private struct FixButtonStyle: ButtonStyle {
    let rest: Color
    let pressedInk: Color
    let pressedFill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? pressedInk : rest)
            .background(configuration.isPressed ? pressedFill : Color.clear, in: Capsule())
            .animation(Theme.ease(0.18), value: configuration.isPressed)
    }
}

// MARK: - the chips, wrapped

/// `display:flex; gap:6px; flex-wrap:wrap` — a row of chips that runs onto
/// a second line rather than shrinking or clipping. SwiftUI has no wrapping
/// stack, so this is the smallest `Layout` that behaves like one.
struct ChipFlow: Layout {

    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    struct Lines {
        var rows: [[Int]] = []
        var heights: [CGFloat] = []
        var size: CGSize = .zero
    }

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout Void) -> CGSize
    {
        lay(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout Void)
    {
        let lines = lay(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in zip(lines.rows, lines.heights) {
            var x = bounds.minX
            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += height + lineSpacing
        }
    }

    private func lay(width: CGFloat, subviews: Subviews) -> Lines {
        var out = Lines()
        guard !subviews.isEmpty else { return out }

        var row: [Int] = []
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        var total: CGFloat = 0

        func closeRow() {
            guard !row.isEmpty else { return }
            out.rows.append(row)
            out.heights.append(rowHeight)
            widest = max(widest, rowWidth)
            total += rowHeight + lineSpacing
            row = []
            rowWidth = 0
            rowHeight = 0
        }

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = row.isEmpty ? size.width : rowWidth + spacing + size.width
            if !row.isEmpty && next > width {
                closeRow()
                rowWidth = size.width
            } else {
                rowWidth = next
            }
            row.append(index)
            rowHeight = max(rowHeight, size.height)
        }
        closeRow()

        out.size = CGSize(width: min(widest, width.isFinite ? width : widest),
                          height: max(0, total - lineSpacing))
        return out
    }
}
