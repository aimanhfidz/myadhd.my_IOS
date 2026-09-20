/* ============================================================
   MyADHD/UI/DateChips.swift — what the app has already spotted a day in

   app.js:5008-5058, app.html:1102-1105, styles.css:286-300, inventory §1.3.

   The strip under the composer's text. It is a receipt, not a control:
   nothing here can be tapped, and the days it shows are the days the
   *offline* reader found — `parseDay` and `parseClock`, never the model.
   That is what makes it honest to draw it on every keystroke, and it is
   also why a chip can disagree with what comes back from `/api/triage`.

   All of the reading is `DatePreview`, which already caps the input at
   4000 characters, requires more than two characters of content, dedupes
   on `when|at`, sorts by day and then by time with an untimed entry
   sorting last, and stops at `PREVIEW_MAX` with a `+N more` legend. This
   file draws the answer and nothing else.
   ============================================================ */

import SwiftUI

struct DateChips: View {

    @Environment(\.theme) private var theme

    /// What is in the box right now, untrimmed.
    let text: String
    var now: Date = Date()
    var today: String = WebDates.dayKey()

    var body: some View {
        let found = DatePreview.chips(in: text, now: now, today: today)

        /* `#composer-dates` is hidden outright when there is nothing — the
           label is part of the strip, not a heading over an empty one. */
        if !found.chips.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Copy.Composer.datesLabel.uppercased())
                    .font(Font.baloo(11.5, .bold))
                    .kerning(0.05 * 11.5)
                    .foregroundStyle(theme.faint)
                    .fixedSize()

                WrappingChips(spacing: 6) {
                    ForEach(found.chips, id: \.self) { chip in
                        whenChip(chip)
                    }
                    if let more = found.more {
                        Text(more)
                            .font(Font.baloo(12))
                            .foregroundStyle(theme.faint)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            /* aria-live: the strip announces itself when it changes, and
               announcing every chip separately would read the whole week
               out on every keystroke. */
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Copy.Composer.datesLabel)
        }
    }

    /// `.chip.chip--when`: solid edge, ink-soft text, and it stays on one
    /// line — 'Thu 27 Aug' broken across two is not a stamp any more.
    private func whenChip(_ label: String) -> some View {
        Text(label)
            .font(Font.baloo(12.5, .semibold))
            .foregroundStyle(theme.inkSoft)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.lineStrong, lineWidth: 1.5))
    }
}

// MARK: - a row of chips that wraps

/// `display:flex; flex-wrap:wrap`. `HStack` does not wrap and `Grid` wants
/// a column count, so the chips are laid out by hand: one pass over the
/// subviews, breaking to a new line when the next one would not fit.
struct WrappingChips: Layout {

    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } +
            spacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, max(widest, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ())
    {
        let rows = arrange(subviews, in: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                  proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty && needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
