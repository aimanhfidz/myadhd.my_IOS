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
   - The gesture is `simultaneousGesture`, which is the native reading of
     `touch-action: pan-y`. It only claims the row once the move is plainly
     sideways, so a vertical drag scrolls the list and never moves a card.
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
    /// It went down the page first, so the list has it and we never will.
    @State private var dead = false
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
            .simultaneousGesture(drag, including: isEnabled ? .all : .subviews)
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

    private var drag: some Gesture {
        DragGesture(minimumDistance: SwipeMetrics.slop, coordinateSpace: .local)
            .onChanged { value in
                guard !leaving else { return }
                guard !dead else { return }

                if !live {
                    /* Down the page belongs to the list and stays there:
                       only a move that is plainly sideways takes the row. */
                    let dy = value.translation.height
                    let across = value.translation.width
                    if abs(dy) >= abs(across) {
                        if abs(dy) > SwipeMetrics.slop { dead = true }
                        return
                    }
                    live = true
                    // carry on from here, not from a jump
                    origin = across
                }

                paint(value.translation.width - origin)
            }
            .onEnded { value in
                let wasLive = live
                let travel = dx
                live = false
                dead = false
                guard wasLive, !leaving else { return }

                guardUntil = Date().addingTimeInterval(SwipeMetrics.tapGuard)

                /* A short, fast flick reads as decided; it is the slow short
                   push that is a change of mind. A row held still before the
                   finger came off is neither, whatever it was doing on the
                   way there — and `velocity` is already a reading off the
                   last few frames, which is what the web's 90ms freshness
                   test was buying. */
                let vx = value.velocity.width
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
