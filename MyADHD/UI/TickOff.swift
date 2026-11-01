/* ============================================================
   MyADHD/UI/TickOff.swift — a task leaves the list; it does not blink out

   iOS-only. The web's `markDone` (app.js:2068) saves and repaints, and
   the row is simply not there on the next frame. On a phone that read as
   the tap having missed: the thing under your thumb vanished and the rows
   below jumped up into its place.

   So a tick does two things before the store is touched:

   1. **The ring fills and the check pops in** (`TickCircle`), with a light
      tap of haptics — the "yes, that one" moment.
   2. **A beat later the row folds away** — it fades and shrinks a little
      while the rows under it slide up to close the gap (`TickOff.animate`
      around the store write, `TickOff.row` on the row).

   Removing (swipe right, or Remove in the detail) and Undo go through the
   same `animate`, so a row comes back the way it left.

   Reduce Motion: no pop and no shrink. The fill is instant and the row
   fades, the way the splash screen drops to a short linear fade.
   ============================================================ */

import SwiftUI
import UIKit

enum TickOff {

    /// How long the filled tick stays on screen before the row goes —
    /// long enough to be seen, short enough not to feel like waiting.
    static let hold: Double = 0.28

    static var stillMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// The fold: the row fades out and the list closes up under it.
    static var leave: Animation {
        stillMotion ? .linear(duration: 0.15) : Theme.ease(0.34)
    }

    /// How a task row leaves the list, and how Undo brings it back.
    static var row: AnyTransition {
        guard !stillMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)),
            removal: .opacity.combined(with: .scale(scale: 0.94)))
    }

    /// A store write that adds or removes rows, animated.
    @discardableResult
    static func animate<T>(_ change: () -> T) -> T {
        withAnimation(leave) { change() }
    }

    /// The tap: fill now, hand over to `commit` after `hold`.
    /// A second tap on a check that is already filled does nothing.
    static func tick(_ ticked: Binding<Bool>, then commit: @escaping () -> Void) {
        guard !ticked.wrappedValue else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(stillMotion ? nil : Theme.pop(0.3)) {
            ticked.wrappedValue = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: commit)
    }
}

/// The round check on a task row: an empty ring until it is tapped, then
/// filled, with the check popping in.
struct TickCircle: View {

    let ticked: Bool
    var size: CGFloat = 24
    var lineWidth: CGFloat = 2
    var glyph: CGFloat = 13
    /// The ring while it is empty.
    let ring: Color
    /// The fill, and the ring once it is ticked.
    let fill: Color
    /// The check on the fill.
    let ink: Color

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(ticked ? fill : ring, lineWidth: lineWidth)
            Circle()
                .fill(fill)
                .scaleEffect(ticked ? 1 : 0.3)
                .opacity(ticked ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: glyph, weight: .heavy))
                .foregroundStyle(ink)
                .scaleEffect(ticked ? 1 : 0.4)
                .opacity(ticked ? 1 : 0)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}
