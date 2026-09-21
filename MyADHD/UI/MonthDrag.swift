/* ============================================================
   MyADHD/UI/MonthDrag.swift — hold a day, then drag across the month

   Press a cell in the month grid, hold it for a third of a second, and the
   picked day follows your finger from there: the fill moves cell to cell
   and the agenda under the grid rewrites itself as it goes. Let go and you
   are on whatever day you stopped over.

   **This is not a port, and should not be described as one.** The gesture
   existed on the website — `MatrixDrag`'s ghost is still called `.cal-ghost`
   and its comment still says "named for the calendar, where the drag was
   born" — but it lived in `app.js`, which is a different repository, and
   `reference/BridgeScript.swift` deliberately never touched the month view
   ("the page's own month and agenda are untouched", :1089). So there is no
   written specification for it in this checkout. What there is, is the
   machinery it left behind: `MatrixDrag` is that same gesture, inherited by
   the quadrants after the calendar stopped using it. This takes it back.

   Everything structural is `MatrixDrag`'s and the reasoning is in that
   file's header, which is worth reading before changing this one:

   - **A hold, not a drag**, because the grid lives inside a vertical
     scroller. 320ms with 8pt of slop means a flick is a scroll and only a
     deliberate press is a drag, and the scroller never has to be told to
     stand down before the gesture has committed.
   - **A plain `Task` timer**, not `LongPressGesture.sequenced(before:)`.
     The sequence hands over no location when the press succeeds, and this
     needs to know which cell the finger went down on at the moment it
     lifts, not on the first move afterwards.
   - **`frames` is `@ObservationIgnored`.** It is written by the cells
     during layout through a `PreferenceKey`; publishing it would invalidate
     the layout that produced it, every layout.

   **What is different from the matrix.** There is no ghost chip. A lifted
   row needs one because it is being moved out of a list and the list closes
   behind it; here nothing moves — the day cell under your finger simply
   fills, which is the same feedback the tap gives and is already drawn. And
   there is no "drop": every cell the finger crosses is picked as it is
   crossed, so releasing commits nothing that has not already happened. That
   is the point of the gesture — the agenda scrubs.
   ============================================================ */

import SwiftUI
import UIKit

@MainActor
@Observable
final class MonthDrag {

    /// The coordinate space the cells' frames and the finger are both
    /// measured in. Declared by `MonthPager` on the view that clips the
    /// three pages, so a frame from a cell and a point from the gesture
    /// mean the same thing.
    static let space = "myadhd.month"

    /// The same two numbers the matrix lifts on — `LIFT_MS` and `SLOP`.
    static let lift: TimeInterval = MatrixDrag.lift
    static let slop: CGFloat = MatrixDrag.slop

    /// A finger down on this day key, with nothing decided yet.
    private(set) var pressed: String?
    /// Dragging, and this is the cell under the finger.
    private(set) var over: String?

    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var origin: CGPoint = .zero
    @ObservationIgnored private var held: String?
    @ObservationIgnored private var dragging = false

    /// Where each day cell is, in `space`. Written by the cells during
    /// layout — see the file header for why it is not observed.
    @ObservationIgnored var frames: [String: CGRect] = [:]

    /// Called with a day key every time the finger crosses into a new
    /// cell. `MonthPager` points this at `session.pick`.
    @ObservationIgnored var onPick: ((String) -> Void)?

    init() {}

    // MARK: - what the grid and its neighbours ask

    var isDragging: Bool { dragging }
    func isOver(_ key: String) -> Bool { dragging && over == key }

    // MARK: - the gesture

    /// The finger is down. This is not yet a drag and may never be one.
    func press(_ key: String, at point: CGPoint) {
        guard pressed == nil, !dragging else { return }
        pressed = key
        held = key
        origin = point
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.lift * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.raise()
        }
    }

    /// Before the lift this is the only thing that can call it off; after
    /// it, it is the gesture.
    func moved(to point: CGPoint) {
        if dragging {
            guard let key = cell(at: point), key != over else { return }
            over = key
            /* Only on a change of cell. `CalendarSession.pick` writes
               `UserDefaults` every call, and a finger crossing a month
               grid produces a point every frame. */
            onPick?(key)
            return
        }
        guard pressed != nil else { return }
        // Enough movement before the hold is up means this was a scroll.
        if hypot(point.x - origin.x, point.y - origin.y) > Self.slop { dropPress() }
    }

    /// The hold was called off. Nothing happened, and the tap that would
    /// otherwise have fired is still allowed to.
    func dropPress() {
        timer?.cancel()
        timer = nil
        pressed = nil
        held = nil
    }

    /// The finger came up. Whatever day it was over is already picked, so
    /// there is nothing to commit — this only tidies up.
    ///
    /// Returns whether a drag was in progress, which is how the cell knows
    /// to swallow the tap that a release would otherwise also count as.
    @discardableResult
    func release() -> Bool {
        let was = dragging
        cancel()
        return was
    }

    func cancel() {
        timer?.cancel()
        timer = nil
        pressed = nil
        held = nil
        over = nil
        dragging = false
    }

    // MARK: -

    /// The lift. The first pick happens here rather than on the first
    /// move, so a press-and-hold with no movement at all still selects the
    /// day you are holding.
    private func raise() {
        guard let held, pressed == held else { return }
        pressed = nil
        dragging = true
        over = cell(at: origin) ?? held
        if let over, over != held { onPick?(over) }
        /* The same light tap the matrix lifts with, and for the same
           reason: a gesture with a timer in it has no other way of saying
           it has started. */
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// `elementFromPoint`, from the frames the cells posted. Day cells in
    /// a month grid never overlap, so the first hit is the only hit.
    private func cell(at point: CGPoint) -> String? {
        frames.first { $0.value.contains(point) }?.key
    }
}

// MARK: - where the day cells are

/// Each live day cell puts its own frame in, measured in `MonthDrag.space`.
/// Only the middle month posts: the two side pages are not hittable, and a
/// key that appears in more than one month would otherwise collide.
struct MonthFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect],
                       nextValue: () -> [String: CGRect])
    {
        value.merge(nextValue()) { _, new in new }
    }
}
