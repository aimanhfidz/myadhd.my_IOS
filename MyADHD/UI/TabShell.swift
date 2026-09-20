/* ============================================================
   MyADHD/UI/TabShell.swift — the five-button pill

   app.html:1058-1076, app.js:426-473, styles.css:1452-1544, inventory §1.1.

   Five buttons: home, calendar, +, lists, notes. The + is an action and
   never becomes current — it opens the composer over whatever you were
   reading and hands the screen back on cancel.

   **The two marks do not share a boundary, and that is deliberate.**

   - The **lists mark** counts what is *late*: `when < today`, strictly.
     Today is not late yet, so a task due this afternoon puts no number on
     the lists tab. With nothing late it is a plain accent dot — "there is
     something over there" — and the moment something has gone past its day
     it becomes an orange count, because how many you have missed is worth
     a number where merely having tasks is not.
   - The **calendar badge** counts everything *dated*, and colours itself
     on `when <= today`: today **does** count here. The number answers "how
     much is scheduled" and the colour answers "does any of it want me
     now", and a thing due today wants you now.

   `Ordering.lateCount` and `Ordering.anyDueByToday` are those two
   boundaries, each written down once; nothing in this file compares a day
   itself.

   Both marks hide when their own tab is current, and the lists mark also
   hides when there is nothing open at all.
   ============================================================ */

import SwiftUI

// MARK: - where you can be

/// The four places. The + is not one of them — see the header.
enum AppTab: String, CaseIterable, Identifiable {
    case home, calendar, lists, notes

    var id: String { rawValue }

    /// app.html's aria-labels, which are the only names these buttons have.
    var label: String {
        switch self {
        case .home:     return Copy.Tabs.home
        case .calendar: return Copy.Tabs.calendar
        case .lists:    return Copy.Tabs.lists
        case .notes:    return Copy.Tabs.notes
        }
    }

    var symbol: String {
        switch self {
        case .home:     return "house"
        case .calendar: return "calendar"
        case .lists:    return "list.bullet"
        case .notes:    return "doc.text"
        }
    }

    /// `#tab-home.is-on, #tab-notes.is-on { --icon-fill: currentColor }`.
    /// The calendar is left outlined on purpose — a filled one is an
    /// unreadable slab.
    var fillsWhenCurrent: Bool { self == .home || self == .notes }
}

// MARK: - the bar

struct TabBar: View {

    @Environment(\.theme) private var theme

    let current: AppTab
    /// Every task, done ones included — the marks are counted here off the
    /// store rather than handed in as numbers, so there is exactly one
    /// place a boundary could be got wrong and it is `Ordering`.
    let tasks: [TaskItem]
    var today: String = WebDates.dayKey()

    var select: (AppTab) -> Void
    var add: () -> Void

    /// `animation: tabIn .3s var(--ease) both` — 14px down and invisible,
    /// once, when the bar first appears.
    @State private var landed = false

    /// styles.css:1468.
    static let maxWidth: CGFloat = 440

    var body: some View {
        HStack(spacing: 0) {
            button(.home)
            button(.calendar)
            addButton
            button(.lists)
            button(.notes)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(theme.tabBG))
                .overlay(Capsule().strokeBorder(theme.tabEdge, lineWidth: 1.5))
        }
        .compositingGroup()
        .shadow(color: theme.tabShadowFar.color,
                radius: theme.tabShadowFar.radius,
                y: theme.tabShadowFar.y)
        .shadow(color: theme.tabShadowNear.color,
                radius: theme.tabShadowNear.radius,
                y: theme.tabShadowNear.y)
        .frame(maxWidth: Self.maxWidth)
        .padding(.horizontal, 14)
        .opacity(landed ? 1 : 0)
        .offset(y: landed ? 0 : 14)
        .onAppear { withAnimation(Theme.ease(0.3)) { landed = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Tabs.navAria)
    }

    // MARK: one of the four

    private func button(_ tab: AppTab) -> some View {
        let on = tab == current
        return Button { select(tab) } label: {
            ZStack {
                Image(systemName: tab.symbol)
                    .symbolVariant(on && tab.fillsWhenCurrent ? .fill : .none)
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 23, height: 23)
                    .foregroundStyle(on ? theme.ink : theme.muted)

                mark(for: tab)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            /* the current section: the same soft slab, not a colour */
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(on ? theme.wash2 : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(TabPressStyle())
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// The + never marks itself current — it is an action, not a place.
    private var addButton: some View {
        Button(action: add) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 23, height: 23)
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
        .accessibilityLabel(Copy.Tabs.add)
    }

    // MARK: the two marks

    @ViewBuilder
    private func mark(for tab: AppTab) -> some View {
        switch tab {
        case .lists:    listsMark
        case .calendar: calendarBadge
        default:        EmptyView()
        }
    }

    private var openCount: Int { tasks.filter { !$0.done }.count }
    private var lateCount: Int { Ordering.lateCount(tasks, today: today) }
    private var datedCount: Int { Ordering.datedCount(tasks) }
    private var calendarIsLate: Bool { Ordering.anyDueByToday(tasks, today: today) }

    /// A dot until something is late, then a count.
    @ViewBuilder
    private var listsMark: some View {
        if openCount > 0 && current != .lists {
            if lateCount == 0 {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 8, height: 8)
                    .ringed(theme.surface, 2.5)
                    /* top:8px; left:calc(50% + 7px) on a 46px button whose
                       middle is 23px down: the dot's centre is 11px right
                       of the icon's and 11px above it. */
                    .offset(x: 11, y: -11)
                    .allowsHitTesting(false)
            } else {
                badge(Copy.Tabs.listsMark(late: lateCount), late: true)
            }
        }
    }

    /// Always a count. Orange the moment any of what it counts is due today
    /// or already past.
    @ViewBuilder
    private var calendarBadge: some View {
        if datedCount > 0 && current != .calendar {
            badge(Copy.Tabs.calendarBadge(dated: datedCount), late: calendarIsLate)
        }
    }

    /// `.tab-badge` — sized to its digits, ringed in the surface so it
    /// reads as sitting above the glyph rather than on it.
    private func badge(_ text: String, late: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .monospacedDigit()
            .foregroundStyle(late ? Color(hex: 0xFFFFFF) : theme.onAccent)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(late ? theme.orange : theme.accent, in: Capsule())
            .ringed(theme.surface, 2, shape: Capsule())
            .fixedSize()
            .offset(x: 12, y: -10)   // top:5px; left:calc(50% + 4px)
            .allowsHitTesting(false)
    }
}

/// `.tab:active{transform:scale(.92); transition-duration:0s}` — the dent
/// is the receipt for the tap, so it lands instantly and only eases back
/// out on release.
private struct TabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(configuration.isPressed ? nil : Theme.ease(0.16),
                       value: configuration.isPressed)
    }
}

private extension View {
    /// CSS's `box-shadow: 0 0 0 Npx <colour>`: a solid ring *outside* the
    /// shape. SwiftUI has no outset stroke, so the ring is a larger filled
    /// shape behind it — which is the same picture for an opaque colour,
    /// and every use of it here is the opaque surface.
    func ringed<S: Shape>(_ colour: Color, _ width: CGFloat, shape: S) -> some View {
        padding(width)
            .background(shape.fill(colour))
            .padding(-width)
    }

    func ringed(_ colour: Color, _ width: CGFloat) -> some View {
        ringed(colour, width, shape: Circle())
    }
}

// MARK: - the bar over a screen

/// What a tab screen is put inside: the screen, the bar hovering over its
/// last line, and the room the bar needs reserved underneath.
///
/// `body.has-tabbar .screen { padding-bottom: 96px + safe-bottom }` — the
/// bar hovers *over* the page rather than sitting on top of its content, so
/// the room is padding inside the screen and not a frame under the bar.
struct TabShell<Content: View>: View {

    @Environment(\.theme) private var theme

    let current: AppTab
    let tasks: [TaskItem]
    var today: String = WebDates.dayKey()
    var select: (AppTab) -> Void
    var add: () -> Void
    @ViewBuilder var content: () -> Content

    /// styles.css:1546.
    static var reservedHeight: CGFloat { 96 }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                theme.surface.ignoresSafeArea()

                content()
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: Self.reservedHeight)
                    }

                TabBar(current: current, tasks: tasks, today: today,
                       select: select, add: add)
                    /* bottom: max(8px, safe-bottom − 4px), measured from the
                       glass. The inset reserves more room than the home
                       indicator occupies — a ~5pt bar about 8pt off the
                       floor — so the pill sits a little way into that strip
                       and still clears it. max() keeps a sane gap where
                       there is no inset at all. */
                    .padding(.bottom, max(8, geo.safeAreaInsets.bottom - 4))
                    .ignoresSafeArea(.container, edges: .bottom)
                    .ignoresSafeArea(.keyboard)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
