/* ============================================================
   MyADHD/UI/MatrixDrag.swift — hold a row, then move it

   app.js:2741-2856, ported constant for constant, and `styles.css:1140`
   and `1763-1775` for what it looks like while it is in the air.

   **Why a hold and not a drag.** The quadrants scroll inside themselves,
   so a drag that started on the first pixel of movement would steal every
   upward swipe in the app. The press has to be held still before it lifts
   — `LIFT_MS` 320 — and a move of more than `SLOP` 8 before the hold is
   up is read as what it almost certainly was, a scroll, and calls the lift
   off. Those two numbers are the whole gesture; everything else follows
   from them.

   **Who keeps the time.** `HoldLiftGesture`, a UIKit long press set to
   exactly those two numbers. It used to be a zero-distance SwiftUI
   `DragGesture` with the timer run in here, which got the ghost's
   position right and the scrolling wrong: that gesture recognised on
   touch-down and kept the finger from the quadrant's scroller for the
   whole touch, so a box that was all titles would not scroll at all. The
   long press claims nothing until the hold is up, and it reports where
   the finger is at that moment — within 8pt of where it went down, which
   is the web's `press.x, press.y` for any thumb that can see the chip.

   **What a drop does, and does not do.** `endDrag(true)` commits only
   when the finger came up over a quadrant, and `AppStore.moveToQuadrant`
   then refuses a move onto the quadrant the task already resolves to —
   the silent no-op of app.js:2851, no write and no toast, because the
   person put it where it already was and saying so would be noise. Every
   other landing writes `task.quadrant`, which is a sticky override with
   no UI anywhere in the app to clear it again. That is the web's
   behaviour, not an oversight here.

   This object is the gesture's whole state. The views read it, nothing
   writes to it but the rows, and `frames` is deliberately outside
   observation: it is written during layout by a preference, and a
   published write there would re-run the layout that produced it.
   ============================================================ */

import SwiftUI
import UIKit

@MainActor
@Observable
final class MatrixDrag {

    /// The coordinate space every point in here is measured in. Declared
    /// by `MatrixScreen` on the container that holds both the quadrants
    /// and the ghost, so the two agree without going through the screen.
    static let space = "myadhd.matrix"

    /// `LIFT_MS = 320` (app.js:2741).
    static let lift: TimeInterval = 0.320
    /// `SLOP = 8` (app.js:2742).
    static let slop: CGFloat = 8

    /// A row in the air: which one, what the chip says, and where the
    /// finger is now.
    struct Airborne: Equatable {
        var id: String
        var label: String
        var point: CGPoint
    }

    /// `press` — a finger down, not yet committed to either reading.
    private(set) var pressed: String?
    /// `drag` — a row in the air.
    private(set) var airborne: Airborne?
    /// `drag.cell` — the quadrant under the finger, which wears the ring.
    private(set) var over: String?

    /// Where each quadrant is, in `space`. Written by the cells during
    /// layout — see the file header for why it is not observed.
    @ObservationIgnored var frames: [String: CGRect] = [:]

    init() {}

    // MARK: - what a row asks

    func isPressed(_ id: String) -> Bool { pressed == id }
    func isLifted(_ id: String) -> Bool { airborne?.id == id }
    var isDragging: Bool { airborne != nil }

    /// `${timeLabel(task.at)} · ${task.title}`, or the title alone.
    /// A compact chip rather than a copy of the row: a full-width clone
    /// sits straight on top of the cells you are aiming at and hides the
    /// very ring that says where it would land (app.js:2770-2775).
    static func ghostLabel(_ t: TaskItem) -> String {
        guard let at = WebDates.timeLabel(t.at) else { return t.title }
        return at + Copy.metaSeparator + t.title
    }

    // MARK: - the gesture

    /// `watchPress` — the finger is down. Nothing has been decided yet.
    func touchDown(_ id: String) {
        guard pressed == nil, airborne == nil else { return }
        pressed = id
    }

    /// `lift()` — held still for `lift`, without moving `slop`. The chip
    /// appears under the thumb.
    func raise(_ task: TaskItem, at point: CGPoint) {
        guard airborne == nil else { return }
        pressed = nil
        airborne = Airborne(id: task.id, label: Self.ghostLabel(task), point: point)
        over = quadrant(at: point)
        /* `navigator.vibrate?.(8)` — only some phones on the web, every
           phone here. The receipt for a gesture that has no other way of
           saying it has started. */
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// `pointermove`, once a row is in the air. Before the lift the
    /// recogniser is the one watching the slop.
    func moved(to point: CGPoint) {
        guard airborne != nil else { return }
        airborne?.point = point
        over = quadrant(at: point)
    }

    /// `dropPress`, or `endDrag(false)` — for this row only. A second
    /// finger giving up on some other row must not drop the one that is
    /// being carried.
    func abandon(_ id: String) {
        if pressed == id { pressed = nil }
        if airborne?.id == id {
            airborne = nil
            over = nil
        }
    }

    /// `pointerup` → `endDrag(true)`. Returns the quadrant the row was
    /// dropped on, or nil — which covers both "it never lifted" and
    /// "it came down over nothing".
    ///
    /// **Only for the row in the air.** With two fingers, a second row
    /// held and let go used to take the first one's target — and cancel
    /// the carry — because whichever `.ended` came first was handed
    /// `over`. The two quadrants are separate scroll views, so both holds
    /// can begin.
    func release(_ id: String) -> String? {
        guard airborne?.id == id else { abandon(id); return nil }
        let landed = over
        cancel()
        return landed
    }

    /// `pointercancel` → `endDrag(false)`. The row goes back where it was.
    func cancel() {
        pressed = nil
        airborne = nil
        over = nil
    }

    // MARK: -

    /// `overCell` — `elementFromPoint` closest `.quad[data-quad]`. The
    /// four never overlap, so the first hit is the only hit.
    private func quadrant(at point: CGPoint) -> String? {
        frames.first { $0.value.contains(point) }?.key
    }
}

// MARK: - where the four quadrants are

/// Each cell puts its own frame in, measured in `MatrixDrag.space`.
struct QuadrantFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect],
                       nextValue: () -> [String: CGRect])
    {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - the chip a lifted row becomes

/// `.cal-ghost` (styles.css:1763-1775) — named for the calendar, where the
/// drag was born; the calendar no longer drags and the only rows that lift
/// now are the matrix's.
///
/// Centred on the finger and lifted clear of it, so a fingertip is not
/// parked on top of the answer (`placeGhost`, app.js:2782-2786).
struct MatrixGhost: View {

    @Environment(\.theme) private var theme

    let label: String
    let point: CGPoint

    /// Measured, because the lift is `y - height - 18` and a guess at the
    /// height puts the chip off the thumb by however far it is wrong.
    @State private var height: CGFloat = 36

    var body: some View {
        Text(label)
            .font(Font.baloo(13.5, .semibold))
            .foregroundStyle(theme.ink)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.accent, lineWidth: 1.5))
            /* `0 18px 36px -12px rgba(16,16,24,.6)`. SwiftUI has no
               spread, so the inset is paid for with a shorter radius and
               the colour carries the rest. */
            .shadow(color: Color(hex: 0x101018, opacity: 0.5), radius: 14, y: 12)
            .rotationEffect(.degrees(-1.2))
            .frame(maxWidth: Self.cap)
            .background {
                GeometryReader { g in
                    Color.clear.preference(key: GhostHeightKey.self, value: g.size.height)
                }
            }
            .onPreferenceChange(GhostHeightKey.self) { h in
                if h > 0 { height = h }
            }
            .position(x: point.x, y: point.y - 18 - height / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// `max-width: min(230px, 62vw)`.
    private static var cap: CGFloat {
        min(230, UIScreen.main.bounds.width * 0.62)
    }
}

private struct GhostHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}
