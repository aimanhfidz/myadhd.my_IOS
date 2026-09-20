/* ============================================================
   MyADHD/UI/FormatSheet.swift — Aa

   `#sheet-format` (app.html:565-595), `paintFormatSheet` (app.js:4767-4775),
   `setBlockType` / `setBlockAlign` (4778-4800), `applyMark` (4806-4816).

   Four rows: the line's type, the four emphases, the note's face, the
   line's alignment. Three of the four describe ONE LINE — the one the
   caret was last in, `fmtBlock` — and the typeface row describes the
   whole note, because it is a property of the paper rather than of a
   sentence. That asymmetry is app.js's and it is why the font row reads
   `look.font` while the other three read `blocks[fmtBlock]`.

   **The type buttons toggle.** Choosing the type a line already is puts
   it back to Body. That is what makes Checkbox a single button rather
   than a pair, and it is why leaving `check` has to unset `done`
   explicitly — a paragraph cannot be ticked off, and a line that kept a
   stale `done` would come back struck through the next time it was made a
   checkbox again.

   **B/I/U/S are the odd ones out**: they are the only controls in the
   note that work on the live selection rather than on the line. They are
   not lit, because what they would be lit from is the selection, and the
   selection is in another view.
   ============================================================ */

import SwiftUI

struct FormatSheet: View {

    @Environment(\.theme) private var theme

    let note: NoteItem
    /// `blocks[fmtBlock]` — the last block to have held the caret.
    let block: NoteBlock

    var close: () -> Void
    var setType: (String) -> Void
    var setAlign: (String) -> Void
    var setFont: (String) -> Void
    var applyMark: (String) -> Void

    var body: some View {
        NoteSheetShell(title: Copy.Note.Format.title, close: close) {
            VStack(alignment: .leading, spacing: 8) {
                row(Copy.Note.Format.typeGroup) {
                    ForEach(Copy.Note.Format.types, id: \.self) { type in
                        FormatPill(label: Copy.Note.Format.typeLabel(type),
                                   on: block.type == type) { setType(type) }
                    }
                }

                row(Copy.Note.Format.markGroup) {
                    ForEach(Copy.Note.Format.marks, id: \.self) { kind in
                        FormatPill(label: Copy.Note.Format.markLabel(kind),
                                   on: false,
                                   style: Self.pillStyle(kind)) { applyMark(kind) }
                    }
                }

                row(Copy.Note.Format.fontGroup) {
                    ForEach(NoteLook.fonts, id: \.self) { font in
                        FormatPill(label: Copy.Note.Format.fontLabel(font),
                                   on: note.look.font == font) { setFont(font) }
                    }
                }

                row(Copy.Note.Format.alignGroup) {
                    ForEach(Copy.Note.Format.aligns, id: \.self) { align in
                        FormatPill(label: Copy.Note.Format.alignLabel(align),
                                   on: block.align == align) { setAlign(align) }
                    }
                }
            }
        }
    }

    /// `.fmt-row` — wrapping, because five type pills do not fit across a
    /// phone and the row is allowed to take two lines.
    private func row<Content: View>(_ label: String,
                                    @ViewBuilder content: () -> Content) -> some View
    {
        WrapRow(spacing: 6, lineSpacing: 6) { content() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .padding(.top, 8)
    }

    private static func pillStyle(_ kind: String) -> FormatPill.Style {
        switch kind {
        case "b":      return .bold
        case "i":      return .italic
        case "u":      return .underline
        case "strike": return .strike
        default:       return .plain
        }
    }
}

// MARK: - flex-wrap

/// `display:flex; flex-wrap:wrap` for a handful of pills. SwiftUI has no
/// wrapping stack before iOS 16's `Layout`, and this is that Layout — as
/// small as it can be, because it only ever holds four rows of at most
/// five buttons.
struct WrapRow: Layout {

    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = lay(subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } +
            CGFloat(max(0, rows.count - 1)) * lineSpacing
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ())
    {
        let rows = lay(subviews, in: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lay(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty && next > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
