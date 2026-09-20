/* ============================================================
   MyADHD/UI/MatrixScreen.swift — the same tasks, grouped by what they are

   `paintMatrixBody` (app.js:1293-1298), `paintViewToggle` (1301-1308) and
   the shell's `fitMatrix` (BridgeScript.swift:1152-1197).

   The lists answer "when"; the matrix answers "does this matter". They
   are two readings of exactly the same open tasks — `quadrantize` takes
   the same filtered array `bucketize` does, and the category filter feeds
   both — so nothing is a second copy of anything: this file draws four
   boxes and `Ordering` decides what goes in them.

   **All four are always drawn, empty or not** (app.js:1290-1292). A 2x2
   with a hole in it stops being a 2x2, and an empty Do now is worth
   reading.

   **Where a task lands.** `quadrantOf`: a `quadrant` the person set by
   dropping it somewhere always wins; otherwise urgent is
   `urgency >= 5 || when <= today` — and that boundary is NOT the lists'.
   Today IS urgent here, while `bucketOf` will not call it late until
   tomorrow. Both are in `Ordering`, both are deliberate, and reproducing
   only one of them would make the matrix disagree with the tab badge.

   **The height.** `fitMatrix` measures the room between the chip bar and
   the tab bar and pins the grid to it, so the two rows are equal and a
   full card scrolls inside itself; under 240pt of room it gives up, the
   cards take their 204pt floor back and the screen scrolls instead. A
   `GeometryReader` is that measurement, without the scroll-position
   correction the web needed because `#app` was the scroller.

   **The toggle names the view you are not in**, because that is what
   pressing it gets you (app.js:1301-1308), and `view` is persisted on the
   document — unlike the category filter, which is where you are looking
   right now rather than how you think.
   ============================================================ */

import SwiftUI

struct MatrixScreen: View {

    @Environment(\.theme) private var theme

    let store: AppStore
    let toasts: ToastCenter

    /// A quadrant's `+`: pin the quadrant, then open the composer. The
    /// pin is `AppStore.pendingQuadrant`, which the dump reads once and
    /// clears whether it landed or was abandoned.
    var openComposer: () -> Void = {}

    var today: String = WebDates.dayKey()

    /// False once the cutover puts `MatrixTools` in a screen header of its
    /// own; true while this screen is the whole of what is on show.
    var showsTools: Bool = true

    /// `catFilter` is one variable on the web and the lists own it here,
    /// so a screen that shows both can hand its own binding in. Left nil,
    /// the matrix keeps its own and behaves exactly the same.
    var filter: Binding<String>?

    @State private var ownFilter = "all"
    @State private var drag = MatrixDrag()
    @State private var helping = false

    // MARK: what one paint is looking at

    private var open: [TaskItem] { store.doc.tasks.filter { !$0.done } }
    private var groups: [(key: String, items: [TaskItem])] {
        Ordering.groupByCategory(open)
    }

    private var filterBinding: Binding<String> { filter ?? $ownFilter }

    /// A filter has to survive a repaint but not the list it was
    /// filtering: drop the last thing out of Money and the screen must not
    /// sit there showing an empty Money.
    private func resolved(_ groups: [(key: String, items: [TaskItem])]) -> String {
        let want = filterBinding.wrappedValue
        guard want != "all" else { return "all" }
        return groups.contains { $0.key == want } ? want : "all"
    }

    // MARK: -

    var body: some View {
        let groups = self.groups
        let chosen = resolved(groups)
        let shown = chosen == "all" ? open : open.filter { Ordering.catKey($0) == chosen }

        VStack(alignment: .leading, spacing: 0) {
            if showsTools {
                MatrixTools(store: store, showHelp: { helping = true })
                    .padding(.bottom, 6)
            }

            CategoryBar(groups: groups,
                        filter: Binding(get: { chosen },
                                        set: { filterBinding.wrappedValue = $0 }))
                .padding(.bottom, groups.count >= 2 ? 12 : 0)

            grid(Ordering.quadrantize(shown, today: today))
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.surface)
        /* The quadrants and the chip they are aiming at have to agree
           about where a point is, and this is the space they agree in. */
        .coordinateSpace(name: MatrixDrag.space)
        .onPreferenceChange(QuadrantFramesKey.self) { frames in
            drag.frames = frames
        }
        .overlay {
            if let air = drag.airborne {
                MatrixGhost(label: air.label, point: air.point)
            }
        }
        .fullScreenCover(isPresented: $helping) {
            MatrixHelp(onClose: { helping = false })
        }
        .onChange(of: groups.map(\.key)) { _, keys in
            let want = filterBinding.wrappedValue
            if want != "all" && !keys.contains(want) { filterBinding.wrappedValue = "all" }
        }
        .onDisappear {
            /* A gesture that never got its `pointerup` — the screen went
               away under a finger — would otherwise leave a chip in the
               air for as long as the app runs. */
            drag.cancel()
        }
    }

    // MARK: the 2x2

    /// Two equal rows, 12pt apart, as tall as the space allows. Under
    /// 240pt of room it is not worth pinning: the cards take their floor
    /// back and the screen scrolls.
    private func grid(_ quads: [(key: String, label: String, sub: String, items: [TaskItem])])
        -> some View
    {
        GeometryReader { geo in
            let fits = geo.size.height > 240
            let cell = max(0, (geo.size.height - 12) / 2)

            if fits {
                rows(quads, height: cell, fitted: true)
            } else {
                ScrollView {
                    rows(quads, height: nil, fitted: false)
                        .padding(.bottom, 10)
                }
                .scrollIndicators(.hidden)
            }
        }
        /* `window.innerHeight - top - bar - 10` — the 10 is the web's, and
           the tab bar's room is already reserved by TabShell. */
        .padding(.bottom, 10)
    }

    private func rows(_ quads: [(key: String, label: String, sub: String, items: [TaskItem])],
                      height: CGFloat?,
                      fitted: Bool) -> some View
    {
        VStack(spacing: 12) {
            ForEach(Array(stride(from: 0, to: quads.count, by: 2)), id: \.self) { i in
                HStack(spacing: 12) {
                    cell(quads[i], fitted: fitted)
                    if i + 1 < quads.count { cell(quads[i + 1], fitted: fitted) }
                }
                .frame(height: height)
            }
        }
    }

    private func cell(_ q: (key: String, label: String, sub: String, items: [TaskItem]),
                      fitted: Bool) -> some View
    {
        QuadrantCell(key: q.key,
                     label: q.label,
                     sub: q.sub,
                     items: q.items,
                     store: store,
                     toasts: toasts,
                     drag: drag,
                     onAdd: {
                         store.pendingQuadrant = q.key
                         openComposer()
                     },
                     fitted: fitted)
    }
}

// MARK: - the two buttons in the lists header

/// `#btn-view` and the `?` the shell adds beside it
/// (app.html:326, BridgeScript.swift:536-548). A separate view because
/// both screens need them: the lists show the way to the matrix and the
/// matrix shows the way back, and the walkthrough is reachable from
/// either.
struct MatrixTools: View {

    @Environment(\.theme) private var theme

    let store: AppStore
    /// The `?`. Left out where there is nothing to show it in.
    var showHelp: (() -> Void)?

    /// `state.view !== 'matrix'` — what pressing the button would get you.
    private var toMatrix: Bool { store.doc.view != "matrix" }

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            if let showHelp {
                Button(action: showHelp) {
                    Text("?")
                        .font(Font.baloo(16, .bold))
                        .foregroundStyle(theme.muted)
                        .frame(width: 34, height: 34)
                        .overlay(Circle().strokeBorder(theme.loudEdge, lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Walkthrough.title)
            }

            Button { store.toggleView() } label: {
                HStack(spacing: 6) {
                    Image(systemName: toMatrix ? "square.grid.2x2" : "list.bullet")
                        .font(.system(size: 13, weight: .semibold))
                    Text(toMatrix ? Copy.Lists.viewToMatrix : Copy.Lists.viewToList)
                        .font(Font.baloo(13, .semibold))
                }
                .foregroundStyle(theme.muted)
                .padding(.leading, 11)
                .padding(.trailing, 13)
                .padding(.vertical, 7)
                .overlay(Capsule().strokeBorder(theme.lineStrong, lineWidth: 1.5))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(toMatrix ? Copy.Lists.viewAriaToMatrix : Copy.Lists.viewAriaToList)
        }
    }
}
