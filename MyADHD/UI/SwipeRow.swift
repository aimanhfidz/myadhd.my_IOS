/* ============================================================
   MyADHD/UI/SwipeRow.swift — the gesture

   app.js:2880-3110, ported constant for constant. This is the one piece
   of the lists people use without looking, so it is the one piece where a
   number moved by ten percent is felt.

   **Which way is which.** A push to the LEFT is Done; a push to the RIGHT
   is Remove. app.js:3060 is the whole argument:

       if (armed || flick) leaveSwipe(track, card, task, after, dx < 0);

   and `leaveSwipe`'s last parameter is named `done`. So `dx < 0` — a
   negative translation, a leftward push — is the tick. The rails agree
   with it and are the other half of the proof: `.swipe-rail--remove` is
   `justify-content:flex-start` and shows on `.is-right`, so it reads from
   the LEFT edge and is uncovered by a card pushed right; `--done` is
   `flex-end` on `.is-left`, uncovered by a card pushed left
   (styles.css:1289-1299). A rail is revealed on the side the card came
   away from, which is the side opposite the push.

   **The five constants.**

   - `SLOP 12` — how far across before this stops being a scroll. Below it
     the list owns the finger; a move that is more down than across gives
     up on the spot, and more than 12px of down kills the gesture outright.
   - `ARM .20`, capped at `96` — a fifth of the row, and never more than
     96pt of it. A bare share reads right on a phone and turns into a haul
     on anything wider, because the column runs to 720pt.
   - `LIMIT .58`, and past it every further pixel is worth `0.3` — the row
     follows the finger and then resists, so it cannot be thrown off the
     side and left there.
   - `FLICK .55 px/ms` — 550 pt/s, which is what `DragGesture.Value`
     reports in. A short fast flick counts even short of the mark; a slow
     short push is a change of mind.
   - `OUT 180ms` — the card is off the screen before the store is touched.
     The wait is the movement, not a spinner over a decision already made.

   **What is not the web's, and why.**

   - The web watches `pointerup` on the document because a pointer can be
     taken off a row mid-gesture. SwiftUI delivers `onEnded` to the gesture
     that started, wherever the finger lands, so there is nothing to catch.
   - `swipeGuard` (the 350ms window that stops a finished swipe opening the
     row's detail on the way back) is kept even though SwiftUI will not
     usually fire a tap after a drag: it costs one `Date` comparison and the
     failure it prevents is a row flapping open under a thumb that just
     ticked something off.
   - **`touch-action: pan-y` is a `UIPanGestureRecognizer`, not a
     `DragGesture`.** It used to be the latter, attached with
     `simultaneousGesture` and told to give up in `onChanged` when the
     move turned out to be vertical. That stopped the CARD moving and did
     not give the list its finger back: by the time the closure runs the
     gesture has already recognised, and a SwiftUI gesture that recognises
     beats `UIScrollView`'s pan. The symptom was a flick that did nothing
     — measured on a fresh launch, a 320pt pull started on a card scrolled
     the list at 0.9s and did not at 0.6s or faster, while the same pull
     started on a heading scrolled at any speed. A slow drag worked
     because the scroller got there first.

     The decision has to be made BEFORE recognition, which is what
     `gestureRecognizerShouldBegin` is for: sideways and this row takes
     it, otherwise the recogniser fails and the touch was never ours. The
     recogniser also declares itself simultaneous with everything, so the
     scroller is not cancelled on the way past.
   ============================================================ */

import SwiftUI
import UIKit

// MARK: - the numbers

enum SwipeMetrics {
    /// `SWIPE_SLOP` — across, before this is a swipe and not a scroll.
    static let slop: CGFloat = 12
    /// `SWIPE_ARM` — of the row's width; past this, letting go acts.
    static let arm: CGFloat = 0.20
    /// `SWIPE_ARM_MAX` — and never further than this, whatever the width.
    static let armMax: CGFloat = 96
    /// `SWIPE_LIMIT` — as far as the card will travel under the finger.
    static let limit: CGFloat = 0.58
    /// What a pixel past the limit is worth.
    static let beyond: CGFloat = 0.3
    /// `SWIPE_FLICK` — .55 px/ms, which is 550 pt/s.
    static let flick: CGFloat = 550
    /// `Math.abs(dx) > SWIPE_SLOP * 3` — a flick still has to have moved.
    static let flickMinTravel: CGFloat = slop * 3
    /// `SWIPE_OUT` — the card leaves in this, then the list redraws.
    static let out: TimeInterval = 0.180
    /// `.swipe.is-settling .swipe-card{transition:transform .22s}`.
    static let settle: TimeInterval = 0.220
    /// `swipeGuard = { card, until: Date.now() + 350 }`.
    static let tapGuard: TimeInterval = 0.350

    /// The gap at which the rail's word starts and finishes fading in —
    /// `clamp(0, calc((var(--gap) - 56) / 40), 1)`.
    static let wordFrom: CGFloat = 56
    static let wordOver: CGFloat = 40

    /// `stillMotion()` — the leave is instant rather than animated.
    static var stillMotion: Bool { UIAccessibility.isReduceMotionEnabled }
}

// MARK: - the row on its track

/* The rail words. Everything else the lists say is in `Copy`; these two
   are written into the rail markup rather than into a string table
   (app.js:2914, 2918), so they are quoted here beside the gesture that
   shows them. */
enum SwipeRails {
    static let remove = "Remove"   // app.js:2914
    static let done = "Done"       // app.js:2918
}

/// Which way the row went, once it went. Top level rather than nested in
/// `SwipeRow` so a caller can name it without naming the generic.
enum SwipeOutcome {
    /// Pushed LEFT. app.js:3060, `dx < 0`.
    case done
    /// Pushed RIGHT.
    case remove
}

/// Puts a rendered card on a track and arms the gesture. The card is
/// whatever `content` draws; this owns only the horizontal.
struct SwipeRow<Content: View>: View {

    @Environment(\.theme) private var theme

    /// False while the row's title is being reworded: a drag across a text
    /// field belongs to the field's own selection, and the web refuses the
    /// gesture for the same reason (`e.target.closest('button, input, a')`).
    var isEnabled: Bool = true
    /// `--swipe-radius`, the card's own, so the rail sits inside its edge.
    var cornerRadius: CGFloat = 16
    /// What the card is opaque WITH. The rails live behind it, so this has
    /// to be the ground the row is actually drawn on or one of them shows
    /// through it mid-swipe. The lists and the calendar sit on `--surface`
    /// and leave it nil; a matrix row sits on its quadrant's own wash and
    /// passes that in, because the shell draws no white pill inside a
    /// tinted card — that was a card inside a card (BridgeScript.swift:461).
    var ground: Color?
    /// The tap the card ends with, minus the one a swipe leaves behind.
    var onTap: () -> Void = {}
    let onCommit: (SwipeOutcome) -> Void
    private let content: Content

    init(isEnabled: Bool = true,
         cornerRadius: CGFloat = 16,
         ground: Color? = nil,
         onTap: @escaping () -> Void = {},
         onCommit: @escaping (SwipeOutcome) -> Void,
         @ViewBuilder content: () -> Content)
    {
        self.isEnabled = isEnabled
        self.cornerRadius = cornerRadius
        self.ground = ground
        self.onTap = onTap
        self.onCommit = onCommit
        self.content = content()
    }

    // MARK: what a finger on a row knows

    @State private var width: CGFloat = 1
    /// The card's travel, already through the limit's resistance.
    @State private var dx: CGFloat = 0
    /// Certainly a swipe, rather than a finger that has not decided.
    @State private var live = false
    @State private var armed = false
    /// On its way out; the rails are all gap from here.
    @State private var leaving = false
    /// Where the translation stood when the gesture went live —
    /// `swipe.x += Math.sign(dx) * SWIPE_SLOP`, said the other way round.
    @State private var origin: CGFloat = 0
    @State private var guardUntil = Date.distantPast

    // MARK: derived, every frame

    /// `Math.min(w * SWIPE_ARM, SWIPE_ARM_MAX)`.
    private var armDistance: CGFloat {
        max(1, min(width * SwipeMetrics.arm, SwipeMetrics.armMax))
    }

    /// `p` before the 0.35 floor: 0 at rest, 1 at the mark.
    private var progress: CGFloat {
        leaving ? 1 : min(1, abs(dx) / armDistance)
    }

    /// `--p`, which is what a rail's opacity is set to.
    private var railOpacity: Double {
        Double(0.35 + progress * 0.65)
    }

    /// `--gap` — how much of the row is actually uncovered.
    private var gap: CGFloat {
        leaving ? 999 : abs(dx).rounded()
    }

    /// The rail's word waits on the gap: a narrow gap gets the icon and
    /// nothing cut in half.
    private var wordOpacity: Double {
        Double(min(1, max(0, (gap - SwipeMetrics.wordFrom) / SwipeMetrics.wordOver)))
    }

    private var pushedRight: Bool { dx > 0 }
    private var pushedLeft: Bool { dx < 0 }

    // MARK: -

    var body: some View {
        content
            /* Opaque and clipped to its own edge, so the rails are only
               ever visible in the gap the card has left behind it. */
            .background(ground ?? theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .offset(x: dx)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onTapGesture {
                // the click a swipe ends with, not a tap
                guard Date() >= guardUntil else { return }
                onTap()
            }
            /* Behind, and behind where the card WAS: `.offset` leaves the
               layout frame where it stood, so a background attached after
               it is drawn in the unmoved frame and is exactly the size of
               the row. A `ZStack` would have had the rails arguing with the
               card about how tall the row is. */
            .background { rails }
            .background {
                GeometryReader { g in
                    Color.clear.preference(key: SwipeWidthKey.self, value: g.size.width)
                }
            }
            .onPreferenceChange(SwipeWidthKey.self) { w in
                if w > 0 { width = w }
            }
            /* Behind everything and hit-testing to nothing: the view
               exists only to hang a recogniser on the row's host. See
               `SwipePanGesture`. */
            .background {
                SwipePanGesture(isEnabled: isEnabled,
                                onBegan: began,
                                onChanged: moved,
                                onEnded: ended)
            }
    }

    // MARK: the two rails

    /* Both lie across the whole row and only the one the gap has uncovered
       is ever shown. Sizing a rail to the gap instead would be a second
       thing to keep in step with the card, for a band nobody can see past
       it. */
    private var rails: some View {
        ZStack {
            // Remove reads from the LEFT edge, because a card pushed RIGHT
            // is what uncovers it.
            rail(alignment: .leading,
                 word: SwipeRails.remove,
                 symbol: "trash",
                 symbolWeight: .semibold,
                 fill: armed ? theme.danger : theme.dangerWash,
                 ink: armed ? Color.white : theme.dangerInk,
                 iconLeads: true)
                .opacity(pushedRight ? railOpacity : 0)

            // Done is the mirror of that.
            rail(alignment: .trailing,
                 word: SwipeRails.done,
                 symbol: "checkmark",
                 symbolWeight: .heavy,
                 fill: armed ? theme.accent : theme.wash2,
                 ink: armed ? theme.onAccent : theme.accent,
                 iconLeads: false)
                .opacity(pushedLeft ? railOpacity : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func rail(alignment: Alignment,
                      word: String,
                      symbol: String,
                      symbolWeight: Font.Weight,
                      fill: Color,
                      ink: Color,
                      iconLeads: Bool) -> some View
    {
        let icon = Image(systemName: symbol)
            .font(.system(size: 19, weight: symbolWeight))
            .scaleEffect(armed ? 1.14 : 1)
            .animation(Theme.ease(0.16), value: armed)

        let label = Text(word)
            .font(Font.baloo(14, .bold))
            .kerning(-0.01 * 14)
            .opacity(wordOpacity)

        return HStack(spacing: 8) {
            if iconLeads { icon; label } else { label; icon }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .background(fill)
        .animation(Theme.ease(0.16), value: armed)
    }

    // MARK: the gesture

    /* Three callbacks instead of one closure, because the recogniser has
       three phases and the middle one is the only one that paints.

       `live` and `origin` survive from the old gesture and mean the same
       things: the row does not move until the finger has gone
       `SwipeMetrics.slop` across, and when it does start moving it starts
       from rest rather than jumping the slop. `dead` is gone — a move
       down the page now fails the recogniser outright, so there is no
       state to sit in while a gesture we do not want runs to completion. */

    private func began() {
        live = false
        origin = 0
    }

    private func moved(_ translation: CGSize) {
        guard !leaving else { return }

        if !live {
            /* The recogniser has already ruled the move sideways; this is
               the row's own threshold on top of that, so a small sideways
               wobble inside a tap does not shift the card. */
            guard abs(translation.width) >= SwipeMetrics.slop else { return }
            live = true
            // carry on from here, not from a jump
            origin = translation.width
        }

        paint(translation.width - origin)
    }

    private func ended(_ translation: CGSize, _ velocity: CGSize) {
        let wasLive = live
        let travel = dx
        live = false
        guard wasLive, !leaving else { return }

        guardUntil = Date().addingTimeInterval(SwipeMetrics.tapGuard)

        /* A short, fast flick reads as decided; it is the slow short
           push that is a change of mind. A row held still before the
           finger came off is neither, whatever it was doing on the
           way there — and `velocity` is already a reading off the
           last few frames, which is what the web's 90ms freshness
           test was buying. */
        let vx = velocity.width
        let flick = abs(vx) > SwipeMetrics.flick
            && (vx < 0) == (travel < 0)
            && vx != 0
            && abs(travel) > SwipeMetrics.flickMinTravel

        if armed || flick {
            leave(done: travel < 0)
        } else {
            settle()
        }
    }

    /// `paintSwipe` — follows the finger to the limit and then resists, so
    /// the row cannot be thrown off the side and left there. The gesture
    /// stays reversible right up to the moment it is not.
    private func paint(_ raw: CGFloat) {
        let limit = width * SwipeMetrics.limit
        let past = abs(raw) - limit
        let magnitude = past > 0 ? limit + past * SwipeMetrics.beyond : abs(raw)
        let signed = raw < 0 ? -magnitude : (raw > 0 ? magnitude : 0)
        dx = signed

        let nextArmed = abs(signed) / armDistance >= 1
        if nextArmed != armed {
            armed = nextArmed
            // the mark, felt rather than read — navigator.vibrate(8)
            if nextArmed {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    /// Short of the mark: back where it was, and the rail goes out with it.
    private func settle() {
        armed = false
        withAnimation(Theme.ease(SwipeMetrics.settle)) { dx = 0 }
    }

    /// Past it: the card leaves the way it was pushed, and the list redraws
    /// without it. The row is off the screen before the store is touched.
    private func leave(done: Bool) {
        leaving = true
        armed = true
        let travel = (width + 40).rounded()
        let duration = SwipeMetrics.stillMotion ? 0 : SwipeMetrics.out

        if duration > 0 {
            withAnimation(.timingCurve(0.4, 0, 1, 1, duration: duration)) {
                dx = done ? -travel : travel
            }
        } else {
            dx = done ? -travel : travel
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            onCommit(done ? .done : .remove)
            /* If the row survives the commit — an id that is no longer on
               the store, which `markDone` and `removeTask` both tolerate —
               it must not be left parked off the side. */
            leaving = false
            armed = false
            dx = 0
        }
    }
}

// MARK: -

private struct SwipeWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

// MARK: - the recogniser

/* ============================================================
   `touch-action: pan-y`, which SwiftUI has no spelling for.

   **Why this is UIKit.** A `DragGesture` decides nothing until its
   `onChanged` runs, and by then it has recognised — and a recognised
   SwiftUI gesture takes the touch off `UIScrollView`'s pan. There is no
   way to un-recognise, so the old code's "this is vertical, stand down"
   branch could stop the card moving but could not give the list its
   finger back. `gestureRecognizerShouldBegin` is the hook that runs
   BEFORE recognition, and returning false there fails the recogniser for
   that whole touch — which is exactly "this was never mine".

   **Why it hit-tests to nothing.** A recogniser fires for touches landing
   on its own view or any descendant, so this view attaches its pan to its
   SUPERVIEW — the host that also holds the card — and then makes itself
   untouchable, so it neither covers the card nor steals its taps. The
   card is drawn in front and the tick button inside it keeps working.
   ============================================================ */

struct SwipePanGesture: UIViewRepresentable {

    var isEnabled: Bool
    var onBegan: () -> Void
    var onChanged: (CGSize) -> Void
    var onEnded: (CGSize, CGSize) -> Void

    func makeUIView(context: Context) -> SwipePanHost {
        let host = SwipePanHost()
        host.coordinator = context.coordinator
        return host
    }

    func updateUIView(_ host: SwipePanHost, context: Context) {
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        /* Disabled rather than detached. A row being reworded is enabled
           again a moment later, and re-attaching would mean finding the
           host a second time.

           Held on the coordinator rather than written straight to the
           recogniser, because this runs before `didMoveToWindow` has made
           one: a row that arrives already disabled — a title being edited
           when the list redraws — would otherwise come back swipeable. */
        context.coordinator.wanted = isEnabled
    }

    static func dismantleUIView(_ host: SwipePanHost, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {

        var onBegan: () -> Void = {}
        var onChanged: (CGSize) -> Void = { _ in }
        var onEnded: (CGSize, CGSize) -> Void = { _, _ in }

        /// What `isEnabled` last asked for, whether or not there was a
        /// recogniser to tell at the time.
        var wanted = true {
            didSet { pan?.isEnabled = wanted }
        }

        private(set) var pan: UIPanGestureRecognizer?
        private weak var attachedTo: UIView?
        /// The row this recogniser speaks for. The recogniser sits on a
        /// view shared with every other row in the list, so without this
        /// a swipe anywhere would move every card at once.
        private weak var row: UIView?

        func attach(to view: UIView, scopedTo row: UIView) {
            guard pan == nil else { return }
            self.row = row
            let recogniser = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            recogniser.delegate = self
            /* One finger, and a trackpad's two-finger scroll is the
               list's, never a row's. */
            recogniser.minimumNumberOfTouches = 1
            recogniser.maximumNumberOfTouches = 1
            recogniser.isEnabled = wanted
            view.addGestureRecognizer(recogniser)
            pan = recogniser
            attachedTo = view
        }

        func detach() {
            if let pan, let attachedTo { attachedTo.removeGestureRecognizer(pan) }
            pan = nil
            attachedTo = nil
        }

        @objc func handle(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            let t = g.translation(in: view)

            switch g.state {
            case .began:
                onBegan()
                onChanged(CGSize(width: t.x, height: t.y))
            case .changed:
                onChanged(CGSize(width: t.x, height: t.y))
            case .ended:
                let v = g.velocity(in: view)
                onEnded(CGSize(width: t.x, height: t.y),
                        CGSize(width: v.x, height: v.y))
            case .cancelled, .failed:
                /* The system took the touch — an edge swipe, a call
                   arriving. The row is not left parked where it stood. */
                onEnded(CGSize(width: t.x, height: t.y), .zero)
            default:
                break
            }
        }

        /// **The whole fix.** Sideways and the row takes it; anything else
        /// and this recogniser fails, leaving the touch where it was — with
        /// the scroller.
        ///
        /// A pan is asked this once, at the moment it wants to begin, so
        /// the answer is made on the first few points of travel. That is
        /// the same one-shot reading the old code made; the difference is
        /// that a no here costs nothing, where before it cost the scroll.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let view = pan.view else { return false }

            /* Ours only if it started on our row. Every row in the list
               has a recogniser on this same view, and each one is asked. */
            if let row {
                let here = pan.location(in: view)
                guard row.convert(row.bounds, to: view).contains(here) else { return false }
            }

            let t = pan.translation(in: view)
            /* Ties go to the list. A perfectly diagonal move is not a
               swipe anybody meant, and the list is the safer reading of
               it — the same way round as the old `abs(dy) >= abs(across)`. */
            return abs(t.x) > abs(t.y)
        }

        /// Never cancel anything else on the way past — not the scroller,
        /// not the tap, not the calendar's press-and-hold.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool
        {
            true
        }
    }
}

/// Holds the coordinator until SwiftUI has put it in a window, then hands
/// the recogniser to the nearest view that the row's touches actually
/// reach, and gets out of the way.
final class SwipePanHost: UIView {

    var coordinator: SwipePanGesture.Coordinator?

    /// Untouchable, always. Without this the view would sit over the row
    /// and eat the tap that opens it.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, let host = sharedAncestor() else { return }
        coordinator?.attach(to: host, scopedTo: self)
    }

    /* **Not `superview`.** SwiftUI gives a representable a wrapper of its
       own — `UIKitPlatformViewHost<PlatformViewRepresentableAdaptor<…>>` —
       sized exactly to it, and that wrapper holds nothing else. A
       recogniser there never fires, because the card is not a view at all:
       SwiftUI draws rows into a shared layer and only a representable gets
       a real `UIView`. So the touch lands on the SCROLLER's content view,
       and that is the one to hang the recogniser on.

       Found by size rather than by class name, because the class names
       above are SwiftUI's private business and have changed before: our
       own wrapper matches our bounds exactly, and the first ancestor that
       is bigger is the shared one. `scopedTo` is then what keeps this
       row's recogniser to this row's rectangle — see `shouldBegin`. */
    private func sharedAncestor() -> UIView? {
        var candidate = superview
        var hops = 0
        while let view = candidate, hops < 6 {
            if view.bounds.width > bounds.width || view.bounds.height > bounds.height {
                return view
            }
            candidate = view.superview
            hops += 1
        }
        return superview
    }
}
