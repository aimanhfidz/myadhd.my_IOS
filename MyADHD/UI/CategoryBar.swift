/* ============================================================
   MyADHD/UI/CategoryBar.swift — the lists, as one line

   `renderCatBar` and `catPill` (app.js:1383-1425), `.cat-bar` /
   `.cat-pill` (styles.css).

   Eight categories stacked as headings put a page of furniture in front of
   the first task. As a row they are one line, and picking one narrows what
   is below it.

   **It only appears once there are two.** One list is no choice at all,
   and a filter bar that cannot filter anything is a control that teaches
   people the app has controls that do nothing.

   **The filter is session-only.** `catFilter` is a module variable on the
   web: not in the store, not persisted, not synced — unlike `view`, which
   is. The difference is deliberate. `view` is how you think about your
   lists and it should still be true tomorrow; the filter is where you
   happen to be looking right now, and coming back to the app a day later
   to find it still showing only Money would read as lost tasks.

   The bar also does not survive its own list: tick the last thing off
   Money and it must not sit there showing an empty Money. `ListsScreen`
   handles that by resolving the filter against the groups it actually has
   before it hands them here.
   ============================================================ */

import SwiftUI

struct CategoryBar: View {

    @Environment(\.theme) private var theme

    /// `groupByCategory(open)` — already ordered, most urgent list first.
    let groups: [(key: String, items: [TaskItem])]
    /// `'all'`, or a category key.
    @Binding var filter: String

    /// `el.catBar.classList.toggle('is-hidden', groups.length < 2)`.
    private var isShown: Bool { groups.count >= 2 }

    private var total: Int {
        groups.reduce(0) { $0 + $1.items.count }
    }

    var body: some View {
        if isShown {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    pill(key: "all", label: Copy.Lists.catAll, count: total)
                    ForEach(groups, id: \.key) { group in
                        pill(key: group.key,
                             label: Copy.Categories.label(group.key),
                             count: group.items.count)
                    }
                }
                .padding(.bottom, 2)
            }
            /* The row is its own scroller and keeps its own offset; nothing
               about the pills moves when one is picked, only which one is
               filled, so there is no `scrollLeft` to put back by hand. The
               last pill is meant to be cut by the edge — that is what says
               there is more along there — so the clip stays on. */
            .accessibilityLabel(Copy.Lists.catBarAria)
        }
    }

    private func pill(key: String, label: String, count: Int) -> some View {
        let on = key == filter

        return Button {
            // `if (catFilter === key) return;`
            guard !on else { return }
            filter = key
        } label: {
            HStack(spacing: 7) {
                Text(label)
                    .font(Font.baloo(13, .semibold))
                    .foregroundStyle(on ? theme.onAccent : theme.muted)

                Text("\(count)")
                    .font(Font.baloo(11, .bold))
                    .foregroundStyle(on ? theme.onAccent : theme.faint)
                    .frame(minWidth: 18)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(on ? Color.white.opacity(0.22) : theme.wash, in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(on ? theme.accent : theme.surface, in: Capsule())
            .overlay(
                Capsule().strokeBorder(on ? theme.accent : theme.lineStrong, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : [.isButton])
    }
}
