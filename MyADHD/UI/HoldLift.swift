/* ============================================================
   MyADHD/UI/HoldLift.swift — hold still, then carry it

   The press-and-hold that lifts a task, for every place that has one: a
   row in a matrix quadrant, a row in the month's agenda, and a chip in
   the month's undated tray. `MatrixDrag` and `MonthTaskDrag` are the
   state; this is only the finger.

   **Why this is UIKit.** It used to be a SwiftUI
   `DragGesture(minimumDistance: 0)` with the 320ms timer run beside it,
   and a zero-distance drag recognises on touch-DOWN. A recognised SwiftUI
   gesture takes the touch off `UIScrollView`'s pan, and calling the lift
   off 8pt later did not give it back — so a quadrant whose rows were
   nearly all title could not be scrolled at all, and the month agenda
   would not flick. `SwipeRow` met the same wall and the same fix is
   written up at the top of that file.

   `UILongPressGestureRecognizer` is the web's `LIFT_MS` and `SLOP` as a
   recogniser: it claims nothing until the finger has been still for
   `MatrixDrag.lift`, and fails outright once it moves further than
   `MatrixDrag.slop` first. A flick moves further than 8pt long before
   320ms, so the recogniser has already failed by the time the scroller
   wants the touch — it was never ours.

   **Why it hit-tests to nothing, and where it hangs.** `SwipePanHost`'s
   reasoning, mostly: SwiftUI draws rows into a shared layer, so the
   recogniser goes on a view the touch really reaches — here the nearest
   scroll view, see `HoldLiftHost.scroller()` for why not the first
   bigger ancestor — and `shouldReceive` keeps it to this view's own
   rectangle, because every row's recogniser is on that same view.

   **The point it reports** is in the drag's named coordinate space, not
   UIKit's: the view hands in where its own top-left sits in that space,
   and the finger is added to it. Every frame and hit test in the two drag
   controllers keeps working in the space it was written for.
   ============================================================ */

import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct HoldLiftGesture: UIViewRepresentable {

    var isEnabled: Bool = true
    /// This view's top-left, measured in the drag's named space.
    var origin: CGPoint
    /// The finger is down on this view. Nothing is decided yet — this is
    /// only what lets the row shrink a hair under the thumb.
    var onPress: () -> Void
    /// Held still for long enough. The point is where the finger is now.
    var onLift: (CGPoint) -> Void
    var onMove: (CGPoint) -> Void
    /// Let go after a lift.
    var onEnd: () -> Void
    /// Everything else: moved off before the lift (a scroll), let go
    /// before it (a tap), or the system took the touch mid-carry.
    var onCancel: () -> Void

    func makeUIView(context: Context) -> HoldLiftHost {
        let host = HoldLiftHost()
        host.coordinator = context.coordinator
        return host
    }

    func updateUIView(_ host: HoldLiftHost, context: Context) {
        let c = context.coordinator
        c.origin = origin
        c.onPress = onPress
        c.onLift = onLift
        c.onMove = onMove
        c.onEnd = onEnd
        c.onCancel = onCancel
        /* On the coordinator and not the recogniser, because this runs
           before `didMoveToWindow` has made one — `SwipePanGesture`'s
           reason, word for word. */
        c.wanted = isEnabled
    }

    static func dismantleUIView(_ host: HoldLiftHost, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {

        var origin: CGPoint = .zero
        var onPress: () -> Void = {}
        var onLift: (CGPoint) -> Void = { _ in }
        var onMove: (CGPoint) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onCancel: () -> Void = {}

        var wanted = true {
            didSet { hold?.isEnabled = wanted }
        }

        private(set) var hold: HoldRecognizer?
        private weak var attachedTo: UIView?
        private weak var row: UIView?

        func attach(to view: UIView, scopedTo row: UIView) {
            guard hold == nil else { return }
            self.row = row
            let recogniser = HoldRecognizer(target: self, action: #selector(handle(_:)))
            recogniser.minimumPressDuration = MatrixDrag.lift
            recogniser.allowableMovement = MatrixDrag.slop
            recogniser.delegate = self
            recogniser.isEnabled = wanted
            recogniser.touchedDown = { [weak self] in self?.onPress() }
            recogniser.gaveUp = { [weak self] in self?.onCancel() }
            view.addGestureRecognizer(recogniser)
            hold = recogniser
            attachedTo = view
        }

        func detach() {
            if let hold, let attachedTo { attachedTo.removeGestureRecognizer(hold) }
            hold = nil
            attachedTo = nil
        }

        /// The finger, in the drag's space: where this view starts in it,
        /// plus where the finger is on this view.
        private func point(_ g: UIGestureRecognizer) -> CGPoint {
            guard let row else { return origin }
            let p = g.location(in: row)
            return CGPoint(x: origin.x + p.x, y: origin.y + p.y)
        }

        @objc func handle(_ g: HoldRecognizer) {
            switch g.state {
            case .began:     onLift(point(g))
            case .changed:   onMove(point(g))
            case .ended:     onEnd()
            case .cancelled: onCancel()
            default:         break
            }
        }

        /// Ours only if it started on our view. Every row on this scroller
        /// has a recogniser on the same ancestor, and each one is asked.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let row, let view = g.view else { return false }
            return row.convert(row.bounds, to: view).contains(touch.location(in: view))
        }

        /// Alone. Once a task is in the air nothing else gets the touch —
        /// not the scroller, which is also told `.scrollDisabled`, and not
        /// the row's tap, which would otherwise open it as the finger
        /// comes up from a drop.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool
        {
            false
        }
    }
}

/// A long press that also says when the finger went down, and when it gave
/// up without ever lifting. The action message covers neither: a
/// recogniser that fails sends nothing, and one still `.possible` has not
/// begun to.
final class HoldRecognizer: UILongPressGestureRecognizer {

    var touchedDown: () -> Void = {}
    var gaveUp: () -> Void = {}

    private var lifted = false

    override var state: UIGestureRecognizer.State {
        didSet { if state == .began { lifted = true } }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if state == .possible { touchedDown() }
    }

    /// Runs once per touch, after the last state. A lift has its own ending
    /// through `.ended` or `.cancelled`; only a press that never got that
    /// far needs telling here.
    override func reset() {
        super.reset()
        if !lifted { gaveUp() }
        lifted = false
    }
}

/// Holds the coordinator until SwiftUI has put it in a window, then hands
/// the recogniser to the nearest view the row's touches actually reach.
final class HoldLiftHost: UIView {

    var coordinator: HoldLiftGesture.Coordinator?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else { return }
        coordinator?.attach(to: scroller() ?? window, scopedTo: self)
    }

    /* **The nearest scroll view, not `SwipePanHost`'s first-bigger
       ancestor.** Every row this hangs on is clipped — `SwipeRow` clips
       its card, the chip is a capsule — and to clip a platform view
       SwiftUI wraps it in a container `UIView` of its own. That container
       is bigger than this view, so the size rule stops on it, and it is
       not on the path a touch is hit-tested down: a recogniser there
       never hears a thing. Measured, not guessed — a held row scrolled
       its quadrant and never lifted.

       The scroll view is an ancestor of whatever the finger lands on
       inside it, so a recogniser there always hears the touch, and
       `shouldReceive` keeps it to this row. Found by class, which is
       UIKit's public type rather than SwiftUI's private wrappers. With no
       scroll view above it, the window, which is above everything. */
    private func scroller() -> UIScrollView? {
        var candidate = superview
        while let view = candidate {
            if let scroll = view as? UIScrollView { return scroll }
            candidate = view.superview
        }
        return nil
    }
}

extension View {

    /// Hang a `HoldLiftGesture` behind this view, measuring where it sits
    /// in `space` so the points it reports are already in that space.
    ///
    /// Not there at all when `enabled` is false, rather than there and
    /// switched off: the List pane's rows share `CalItemRow` and never
    /// lift, and a measured view per row would be paid for nothing.
    func holdToLift(in space: String,
                    enabled: Bool = true,
                    press: @escaping () -> Void,
                    lift: @escaping (CGPoint) -> Void,
                    move: @escaping (CGPoint) -> Void,
                    end: @escaping () -> Void,
                    cancel: @escaping () -> Void) -> some View
    {
        background {
            if enabled {
                GeometryReader { geo in
                    HoldLiftGesture(origin: geo.frame(in: .named(space)).origin,
                                    onPress: press,
                                    onLift: lift,
                                    onMove: move,
                                    onEnd: end,
                                    onCancel: cancel)
                }
            }
        }
    }
}
