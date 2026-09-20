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

   **Why not `LongPressGesture.sequenced(before: DragGesture)`**, which is
   the idiomatic shape and would give 320/8 for free: the sequence hands
   over no location at the moment the press succeeds, only on the first
   drag change after it. The web places the ghost at the point the finger
   went DOWN (`lift()` reads `press.x, press.y`), so the chip appears
   under the thumb that is not moving yet. A `DragGesture` with a zero
   minimum distance reports `startLocation` from the first callback, which
   is that point, so the timer is run here instead.

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

    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var origin: CGPoint = .zero
    @ObservationIgnored private var held: (id: String, label: String)?

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
    func press(_ task: TaskItem, at point: CGPoint) {
        guard pressed == nil, airborne == nil else { return }
        pressed = task.id
        origin = point
        held = (task.id, Self.ghostLabel(task))
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.lift * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.raise()
        }
    }

    /// `pointermove`. Before the lift this is the only thing that can call
    /// it off; after it, it is what moves the chip.
    func moved(to point: CGPoint) {
        if airborne != nil {
            airborne?.point = point
            over = quadrant(at: point)
            return
        }
        guard pressed != nil else { return }
        // Enough movement before the hold is up means this was a scroll.
        if hypot(point.x - origin.x, point.y - origin.y) > Self.slop { dropPress() }
    }

    /// `dropPress` — the hold was called off. Nothing happened.
    func dropPress() {
        timer?.cancel()
        timer = nil
        pressed = nil
        held = nil
    }

    /// `pointerup` → `endDrag(true)`. Returns the quadrant the row was
    /// dropped on, or nil — which covers both "it never lifted" and
    /// "it came down over nothing".
    func release() -> String? {
        let landed = airborne != nil ? over : nil
        cancel()
        return landed
    }

    /// `pointercancel` → `endDrag(false)`. The row goes back where it was.
    func cancel() {
        timer?.cancel()
        timer = nil
        pressed = nil
        held = nil
        airborne = nil
        over = nil
    }

    // MARK: -

    /// `lift()`. The chip appears at the point the finger went down, not
    /// at wherever it has wandered to — it has not wandered, that is the
    /// whole condition of getting here.
    private func raise() {
        guard let held, pressed == held.id else { return }
        pressed = nil
        airborne = Airborne(id: held.id, label: held.label, point: origin)
        over = quadrant(at: origin)
        /* `navigator.vibrate?.(8)` — only some phones on the web, every
           phone here. The receipt for a gesture that has no other way of
           saying it has started. */
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

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
