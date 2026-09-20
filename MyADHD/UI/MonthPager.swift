/* ============================================================
   MyADHD/UI/MonthPager.swift — three months abreast

   `#cal-months` and the scroller behind it (app.js:2453-2642,
   styles.css:1686-1708).

   The web builds this out of a scroll-snapping element with three panes
   and a settle handler: `CAL_SETTLE_MS` 110 to decide the finger has
   stopped, `CAL_GLIDE_MS` 220 to tween the arrows, a height pinned to the
   middle pane, and a `scrollend` path for the browsers that have it. Most
   of that machinery is there because a browser will not tell you when a
   scroll is over. Here the gesture is the gesture, so what carries across
   is the behaviour and the two numbers that are felt:

   - **an arrow is one month**, and it glides over 220ms on
     `cubic-bezier(0, 0, .2, 1)` — the same tween the web uses, so the
     frame and the month still arrive together;
   - **a sideways swipe is one month**, with the neighbour already drawn
     so it is pulled in rather than appearing once it lands;
   - **the height is the middle pane's**, animated on the same curve, so
     a five-week month is five rows and not six with a gap, and a month
     that needs the extra row opens into it.

   Reduced motion takes the web's own escape hatch: `slideMonth` falls
   straight through to `stepMonth`, no tween at all.

   The two outer panes are inert (`MonthPage(live: false)`). Only the
   middle one has buttons in it, which is what stops a day being picked on
   a month that is half off the edge of the screen.
   ============================================================ */

import SwiftUI
import UIKit

struct MonthPager: View {

    @Environment(\.theme) private var theme

    let tasks: [TaskItem]
    let today: String
    let session: CalendarSession

    /// The pane's width, which decides the cell size and so the height.
    /// Seeded from the screen so the first frame is not zero-high.
    @State private var width: CGFloat = max(1, UIScreen.main.bounds.width - 40)
    @State private var dx: CGFloat = 0
    /// A glide is in flight; a second swipe on top of it would land on a
    /// month that is halfway to somewhere.
    @State private var busy = false

    /// `CAL_GLIDE_MS`.
    private static let glideMS: TimeInterval = 0.220
    /// `cubic-bezier(0, 0, .2, 1)`.
    private static var glide: Animation { .timingCurve(0, 0, 0.2, 1, duration: glideMS) }

    private var cursor: MonthRef { session.cursor }

    /// `aspect-ratio: 1; max-height: 48px` on a 7-column grid.
    private var cell: CGFloat {
        let column = (width - 6 * MonthPage.gap) / 7
        return min(48, max(1, column))
    }

    private var height: CGFloat { MonthPage.height(month: cursor, cell: cell) }

    var body: some View {
        HStack(spacing: 0) {
            pane(cursor.adding(-1), live: false)
            pane(cursor, live: true)
            pane(cursor.adding(1), live: false)
        }
        .frame(width: width * 3, alignment: .leading)
        .offset(x: -width + dx)
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(swipe)
        .animation(Self.glide, value: height)
        .frame(maxWidth: .infinity, alignment: .center)
        .background {
            GeometryReader { g in
                Color.clear.preference(key: MonthWidthKey.self, value: g.size.width)
            }
        }
        .onPreferenceChange(MonthWidthKey.self) { measured in
            if measured > 0 { width = measured }
        }
    }

    private func pane(_ month: MonthRef, live: Bool) -> some View {
        MonthPage(month: month,
                  tasks: tasks,
                  today: today,
                  picked: session.picked,
                  live: live,
                  cell: cell,
                  onPick: { session.pick($0) })
            .frame(width: width, alignment: .top)
    }

    // MARK: sideways

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !busy else { return }
                /* A mostly vertical move is the page's scroll, not this. */
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dx = value.translation.width
            }
            .onEnded { value in
                guard !busy, dx != 0 else { return }
                let travel = value.translation.width
                let flung = abs(value.velocity.width) > 400
                if abs(travel) > width * 0.25 || flung {
                    slide(travel < 0 ? 1 : -1)
                } else {
                    withAnimation(Self.glide) { dx = 0 }
                }
            }
    }

    /// `slideMonth(n)` — tween the panes across, then step the month
    /// underneath them. The swap is invisible because the pane that
    /// arrives is drawn from the same month the one leaving showed.
    func slide(_ n: Int) {
        guard !busy else { return }
        if UIAccessibility.isReduceMotionEnabled {
            session.step(n)
            dx = 0
            return
        }
        busy = true
        withAnimation(Self.glide) { dx = -CGFloat(n) * width }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.glideMS) {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                session.step(n)
                dx = 0
            }
            busy = false
        }
    }
}

private struct MonthWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}
