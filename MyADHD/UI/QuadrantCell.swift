/* ============================================================
   MyADHD/UI/QuadrantCell.swift — one box of the four

   `renderQuadrant` (app.js:1340-1381) for the shape, and
   BridgeScript.swift:398-484 for everything about how it looks, because
   the 2x2 only ever existed inside the shell: below 560px the website
   stacks the quadrants and its own CSS says why — a task row at ~170px
   wraps its chips onto three lines and truncates the title to nothing.
   The shell's answer was to take the chips off the rows instead, since
   the quadrant has already said how urgent and how important, and keep
   the 2x2. This is that answer, natively.

   **The four hues, and where they come from.** Do now is `--danger`,
   Plan is `--violet`, Delegate is `--orange`, and Drop is `#1F8A45`,
   which is in no stylesheet anywhere: the brand guidelines have no green
   at all, so it was chosen to sit with the other three — mid-saturation,
   similar weight to the orange — with `#4CC47A` for dark grounds the way
   `--danger-ink` is to `--danger`. Do now and Plan lift at night too.
   That is four values and their three dark cuts, all in `QuadrantPalette`
   and nowhere else.

   **The washes are mixed, not chosen.** `color-mix(in srgb, <hue> 13%,
   var(--surface))` — 14% for Delegate, whose orange is lighter — so one
   variable covers both grounds. `in srgb` mixes gamma-encoded channels,
   which is a plain byte-wise blend, so that is what `mix` does.

   **A row here is a line, not the task's page.** Title and tick only:
   the chips, the meta and the whole detail are hidden by the shell
   (`#matrix .quad .task .task-detail{display:none !important}`), because
   opening the first step, the break-it-down button and Edit/Remove inside
   a 165px card is the wrong place for any of it. The list view has the
   room and keeps all of it. What the row does keep is the swipe — the web
   wraps these in `swipeRow` like every other row — and the hold that
   lifts it into `MatrixDrag`.
   ============================================================ */

import SwiftUI

// MARK: - the four hues

/// One table, both themes. Nothing else in the app knows these values.
struct QuadrantPalette {

    var dark: Bool

    /// `--q-do`, `--q-plan`, `--q-delegate`, `--q-drop`
    /// (BridgeScript.swift:436-438).
    static func hueHex(_ key: String, dark: Bool) -> UInt32 {
        switch key {
        case "do":       return dark ? 0xFF8A7E : 0xD92D20   // --danger-ink / --danger
        case "plan":     return dark ? 0xA97BFF : 0x7B3FE4   // --violet
        case "delegate": return 0xF75C03                     // --orange, both grounds
        case "drop":     return dark ? 0x4CC47A : 0x1F8A45
        default:         return dark ? 0xF3F2FB : 0x101018   // --ink
        }
    }

    func hue(_ key: String) -> Color { Color(hex: Self.hueHex(key, dark: dark)) }

    /// The card's ground. 13% of the hue, and 14% for Delegate
    /// (BridgeScript.swift:439-442).
    func wash(_ key: String) -> Color {
        let share = key == "delegate" ? 0.14 : 0.13
        return Color(hex: Self.mix(Self.hueHex(key, dark: dark), surfaceHex, share))
    }

    /// `--surface`, as the number the mix needs.
    var surfaceHex: UInt32 { dark ? 0x101018 : 0xFFFFFF }

    /// `color-mix(in srgb, a <share>, b)`. sRGB means the encoded
    /// channels, so this is the blend and not a detour through linear
    /// light — which would come out visibly darker.
    static func mix(_ a: UInt32, _ b: UInt32, _ share: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 0xFF)
            let y = Double((b >> shift) & 0xFF)
            let v = (x * share + y * (1 - share)).rounded()
            return UInt32(min(255, max(0, v)))
        }
        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }
}

// MARK: - one card

struct QuadrantCell: View {

    @Environment(\.theme) private var theme

    /// `do | plan | delegate | drop`.
    let key: String
    /// Already resolved by `Copy.Quadrants`.
    let label: String
    let sub: String
    let items: [TaskItem]

    let store: AppStore
    let toasts: ToastCenter
    let drag: MatrixDrag

    /// The `+`: `pendingQuadrant = key; openComposer()` (app.js:1364).
    var onAdd: () -> Void

    /// `.myadhd-fit` — the grid's height has been pinned to the screen, so
    /// the cards drop their floor and share whatever there is. Unpinned,
    /// the 204pt floor keeps an empty card the size of a card.
    var fitted: Bool = true

    private var palette: QuadrantPalette { QuadrantPalette(dark: theme.dark) }
    private var hue: Color { palette.hue(key) }
    private var ground: Color { palette.wash(key) }
    private var isTarget: Bool { drag.over == key }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            head
            if items.isEmpty { empty } else { rows }
        }
        .padding(.top, 18)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(minHeight: fitted ? 0 : 204, alignment: .top)
        .background(ground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        /* `.quad.is-drop{box-shadow:0 0 0 3px var(--accent)}` — a ring,
           not a fill: the card already carries a ground, and two of the
           four carry the accent on their edge already. */
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(theme.accent, lineWidth: 3)
                .opacity(isTarget ? 1 : 0)
        }
        .animation(Theme.ease(0.16), value: isTarget)
        .background {
            GeometryReader { g in
                Color.clear.preference(
                    key: QuadrantFramesKey.self,
                    value: [key: g.frame(in: .named(MatrixDrag.space))]
                )
            }
        }
    }

    // MARK: the name, what it means, and the way in

    private var head: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(Font.baloo(24, .heavy))
                    .kerning(-0.025 * 24)
                    .foregroundStyle(hue)
                    .fixedSize(horizontal: false, vertical: true)

                Text(sub)
                    .font(Font.baloo(12))
                    .lineSpacing(12 * 0.3)
                    .foregroundStyle(theme.muted)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(hue)
                    .frame(width: 34, height: 34)
                    .background(theme.surface, in: Circle())
                    .shadow(color: Color(hex: 0x101018, opacity: 0.08), radius: 1.5, y: 1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.Quadrants.addAria(label: label))
        }
    }

    // MARK: nothing in it

    /// Centred in whatever height the card has, with a tray above it, and
    /// tinted in the card's own hue because `currentColor` is what the
    /// shell's mask uses.
    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .light))
                .frame(width: 34, height: 34)
                .opacity(0.55)
            Text(Copy.Quadrants.empty)
                .font(Font.baloo(13))
        }
        .foregroundStyle(hue)
        .multilineTextAlignment(.center)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: the rows

    /// A card with more rows than fit scrolls inside itself — and stops
    /// scrolling while a row is in the air, which is what the web's
    /// `holdPageStill` buys by killing `touchmove`.
    private var rows: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(items, id: \.id) { task in
                    QuadrantTaskRow(task: task,
                                    hue: hue,
                                    ground: ground,
                                    store: store,
                                    toasts: toasts,
                                    drag: drag)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(drag.isDragging)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - one line in a box

struct QuadrantTaskRow: View {

    @Environment(\.theme) private var theme

    let task: TaskItem
    let hue: Color
    let ground: Color
    let store: AppStore
    let toasts: ToastCenter
    let drag: MatrixDrag

    /// One touch, one press. Without it a move past the slop would drop
    /// the press and the very next callback would start a fresh one,
    /// which is a hold that can never be called off.
    @State private var gestureLive = false

    private var lifted: Bool { drag.isLifted(task.id) }
    private var pressed: Bool { drag.isPressed(task.id) }

    var body: some View {
        SwipeRow(isEnabled: !lifted,
                 cornerRadius: 8,
                 ground: ground,
                 onCommit: commit) {
            card
        }
        /* `.quad .task.is-lifted{opacity:.3}` — the row fades in place
           rather than leaving, so the quadrant does not reflow under the
           hand mid-drag. */
        .opacity(lifted ? 0.3 : 1)
        .scaleEffect(pressed ? 0.985 : 1)
        .animation(Theme.ease(0.18), value: lifted)
        .animation(Theme.ease(0.14), value: pressed)
    }

    private var card: some View {
        HStack(alignment: .center, spacing: 9) {
            check
            Text(task.title)
                .font(Font.baloo(12.5, .medium))
                .lineSpacing(12.5 * 0.25)
                .foregroundStyle(theme.ink)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                /* The hold is bound here and not on the whole row, because
                   `watchPress` returns on `.task-check`: ticking off is not
                   dragging (app.js:2748). */
                .simultaneousGesture(hold)
        }
        .padding(.vertical, 5)
        .padding(.leading, 1)
    }

    /// 18pt, 1.5pt, and in the quadrant's own hue.
    private var check: some View {
        Button(action: markDone) {
            Circle()
                .strokeBorder(hue, lineWidth: 1.5)
                .frame(width: 18, height: 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.TaskRow.checkAria(title: task.title))
    }

    // MARK: hold, then drag

    private var hold: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(MatrixDrag.space))
            .onChanged { value in
                if !gestureLive {
                    gestureLive = true
                    drag.press(task, at: value.startLocation)
                }
                drag.moved(to: value.location)
            }
            .onEnded { _ in
                gestureLive = false
                land()
            }
    }

    /// `endDrag(true)`. A drop that never lifted, or that came down over
    /// nothing, is nothing; a drop onto the quadrant the task already
    /// resolves to is refused by the store and says nothing either.
    private func land() {
        guard let to = drag.release() else { return }
        guard store.moveToQuadrant(task.id, to: to) else { return }
        toasts.show(Copy.Quadrants.movedTo(label: Copy.Quadrants.label(to)))
    }

    // MARK: the swipe, which is the lists' swipe

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
