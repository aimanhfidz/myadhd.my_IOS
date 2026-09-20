/* ============================================================
   MyADHD/UI/BucketSection.swift — one WHEN heading and its rows

   `renderBucket` (app.js:1319-1381) and `.bucket` (styles.css).

   Each card already carries its exact day. The heading is there so the
   shape of what is coming reads without having to read any of them —
   four of them at most, and only the ones with something underneath
   (`bucketize` drops the empties, because an empty "Late" is a worse
   thing to read than no heading at all).

   Late is the only heading that shouts, and it earns it: the name and the
   count both go orange, which is the one other place in the app that
   colour is allowed (the other is the asterisk in the mark). Today gets
   full-strength ink; Coming up and No date yet stay muted, because they
   are not asking for anything yet.

   The order of the four and what falls under each is `Ordering`'s, not
   this file's. This draws whatever it is handed, in the order it is
   handed it.
   ============================================================ */

import SwiftUI

struct BucketSection<Row: View>: View {

    @Environment(\.theme) private var theme

    /// `'late' | 'today' | 'soon' | 'someday'` — only ever used to decide
    /// how loud the heading is.
    let key: String
    /// Already resolved by `Copy.Buckets.label`.
    let label: String
    let items: [TaskItem]
    @ViewBuilder let row: (TaskItem) -> Row

    init(key: String,
         label: String,
         items: [TaskItem],
         @ViewBuilder row: @escaping (TaskItem) -> Row)
    {
        self.key = key
        self.label = label
        self.items = items
        self.row = row
    }

    private var isLate: Bool { key == "late" }
    private var isToday: Bool { key == "today" }

    private var nameColour: Color {
        if isLate { return theme.orange }
        return isToday ? theme.ink : theme.muted
    }

    private var countColour: Color {
        isLate ? theme.orange : theme.faint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Text(label)
                    .font(Font.baloo(15, .bold))
                    .kerning(-0.01 * 15)
                    .foregroundStyle(nameColour)

                Text("\(items.count)")
                    .font(Font.baloo(11, .bold))
                    .foregroundStyle(countColour)
                    .frame(minWidth: 18)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(theme.wash, in: Capsule())
            }
            .accessibilityElement(children: .combine)

            /* `.list-items` — the rows, 8pt apart. `animation:rise .18s` on
               the web is a whole-list fade-up on every repaint; here the
               list is not rebuilt on every store write, so the rise belongs
               to a row arriving rather than to the container, and SwiftUI's
               own insertion transition does that job. */
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.id) { task in
                    row(task)
                }
            }
        }
    }
}
