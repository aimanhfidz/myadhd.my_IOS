/* ============================================================
   MyADHD/UI/SheetPan.swift — pulling the composer down, in UIKit

   The composer is a sheet with a scrolling body inside it, and both want a
   vertical drag. It used to be a SwiftUI `DragGesture(minimumDistance: 0)`
   on the sheet, which recognises the moment a finger lands — and a
   recognised SwiftUI gesture keeps the touch from `UIScrollView` for the
   rest of it (the finding `SwipeRow` and `HoldLift` are both built on). So
   a long dump could not be dragged back down through, only flicked up a
   little: the sheet had the finger, decided it was not its drag, and the
   scroller never got it.

   Here the decision is made BEFORE anything is claimed, in
   `gestureRecognizerShouldBegin` — the sheet asks the composer whether this
   pull is its, and a no fails the recogniser for the whole touch. And every
   scroll view's pan in the window waits for that answer
   (`shouldBeRequiredToFailBy`), so a downward pull on a body already at its
   top moves the sheet instead of rubber-banding the scroller, while any
   other move goes to the scroller a single touch event later.

   The host covers the composer's root and hit-tests to nothing; the
   recogniser hangs on the window, which every touch in the cover passes
   through. Points are in the host's own coordinates, which are the
   composer's named space, since the host is that view's background.
   ============================================================ */

import SwiftUI
import UIKit

struct SheetPanGesture: UIViewRepresentable {

    /// Asked once, when the finger has moved far enough to be a pan: is it
    /// the sheet's? `start` is where the finger went down.
    var shouldClaim: (_ start: CGPoint, _ translation: CGSize) -> Bool
    var onBegan: (_ y: CGFloat) -> Void
    var onChanged: (_ y: CGFloat) -> Void
    /// Let go: where, and how fast downward in points per second.
    var onEnded: (_ y: CGFloat, _ velocity: CGFloat) -> Void
    /// The system took the touch. Nothing was decided.
    var onCancelled: () -> Void

    func makeUIView(context: Context) -> SheetPanHost {
        let host = SheetPanHost()
        host.coordinator = context.coordinator
        return host
    }

    func updateUIView(_ host: SheetPanHost, context: Context) {
        let c = context.coordinator
        c.shouldClaim = shouldClaim
        c.onBegan = onBegan
        c.onChanged = onChanged
        c.onEnded = onEnded
        c.onCancelled = onCancelled
    }

    static func dismantleUIView(_ host: SheetPanHost, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {

        var shouldClaim: (CGPoint, CGSize) -> Bool = { _, _ in false }
        var onBegan: (CGFloat) -> Void = { _ in }
        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: (CGFloat, CGFloat) -> Void = { _, _ in }
        var onCancelled: () -> Void = {}

        private var pan: UIPanGestureRecognizer?
        private weak var attachedTo: UIView?
        weak var host: UIView?

        func attach(to window: UIView, host: UIView) {
            guard pan == nil else { return }
            self.host = host
            let recogniser = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            recogniser.delegate = self
            recogniser.maximumNumberOfTouches = 1
            window.addGestureRecognizer(recogniser)
            pan = recogniser
            attachedTo = window
        }

        func detach() {
            if let pan, let attachedTo { attachedTo.removeGestureRecognizer(pan) }
            pan = nil
            attachedTo = nil
        }

        @objc func handle(_ g: UIPanGestureRecognizer) {
            guard let host else { return }
            let y = g.location(in: host).y
            switch g.state {
            case .began:     onBegan(y)
            case .changed:   onChanged(y)
            case .ended:     onEnded(y, g.velocity(in: host).y)
            case .cancelled: onCancelled()
            default:         break
            }
        }

        /// Only touches inside the composer, which covers the window while
        /// it is up.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let host else { return false }
            return host.bounds.contains(touch.location(in: host))
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let host else { return false }
            let t = pan.translation(in: host)
            let now = pan.location(in: host)
            let start = CGPoint(x: now.x - t.x, y: now.y - t.y)
            return shouldClaim(start, CGSize(width: t.x, height: t.y))
        }

        /// Every scroller waits for the sheet to say no first — which it
        /// does on the first movement for anything that is not a pull
        /// down from the top. Not the text box's own: a `UITextView` is a
        /// scroll view, but this one does not scroll.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool
        {
            guard other is UIPanGestureRecognizer,
                  let view = other.view as? UIScrollView,
                  !(view is UITextView) else { return false }
            return view.window === host?.window
        }
    }
}

final class SheetPanHost: UIView {

    var coordinator: SheetPanGesture.Coordinator?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else { return }
        coordinator?.attach(to: window, host: self)
    }
}
