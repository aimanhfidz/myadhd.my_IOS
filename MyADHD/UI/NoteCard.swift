/* ============================================================
   MyADHD/UI/NoteCard.swift — one note on the index, and the paper it is
   written on

   `noteCard` (app.js:4397-4450) and the paper tokens (styles.css:440-467,
   578-604).

   **The washes, resolved.** The web writes each paper as
   `color-mix(in srgb, <token> N%, var(--surface))`, and `--surface` is
   white by day and #101018 by night — so the same seven names are seven
   different pairs of colours and none of them is written down anywhere as
   a hex value. `NotePaper` does that mix here, in the same space CSS does
   it in (plain sRGB, gamma-encoded, not linear), so the answer is the
   stylesheet's answer rather than something matched by eye.

   Two of the seven are not mixes and are easy to get wrong:

   - **lavender** is the default and is `--pale` (#D1CDFF) by day and a
     flat #26233A by night. It carries no `data-paper` attribute at all,
     which is why a note written before papers existed still draws the way
     it always did — and why the card wears the plain surface for it
     rather than a wash of it (`.note-card[data-paper]`, styles.css:598,
     only matches the other six).
   - **white** is `--surface` itself, is labelled `Plain`, and is the one
     paper that also moves the edge — to `--line-strong`, because a sheet
     the same colour as the page behind it needs a border you can see.

   **The card is not a preview of the note, it is a way back into it.**
   Title, at most two lines of what is under the title, and a foot. The
   preview deliberately skips whatever is already serving as the title:
   with no `title` field the first line of the body IS the title, so the
   preview starts at the second line and the card does not say the same
   thing twice.
   ============================================================ */

import SwiftUI

// MARK: - the paper

/// The five note tokens, resolved for one paper on one ground.
struct NotePaper: Equatable {

    /// `--note-paper`: the sheet itself.
    var paper: Color
    /// `--note-edge`: its border.
    var edge: Color
    /// `--note-dot`: the grain.
    var dot: Color
    /// `--note-ink`: what is written on it.
    var ink: Color
    /// `--note-faint`: the placeholder, the bullet, a ticked-off line.
    var faint: Color
    /// The index card's ground — `color-mix(--note-paper 55%, --surface)`
    /// for the six that carry an attribute, and the plain surface for
    /// lavender, which does not.
    var card: Color

    /// sRGB, 0...1 per channel. Plain doubles rather than `Color`,
    /// because `color-mix` is arithmetic and `Color` will not be read
    /// back out.
    private struct RGB {
        var r: Double, g: Double, b: Double
        init(_ hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255
            g = Double((hex >> 8) & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
        }
        init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
        var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
    }

    /// `color-mix(in srgb, a p%, b)`. CSS mixes in the *encoded* sRGB
    /// channels for `in srgb` — no linearisation — so this is the whole
    /// of it.
    private static func mix(_ a: RGB, _ p: Double, _ b: RGB) -> RGB {
        RGB(r: a.r * p + b.r * (1 - p),
            g: a.g * p + b.g * (1 - p),
            b: a.b * p + b.b * (1 - p))
    }

    static func of(_ key: String, theme: Theme) -> NotePaper {
        let dark = theme.dark
        let surface = RGB(dark ? 0x101018 : 0xFFFFFF)

        let sheet: RGB
        switch key {
        case "violet": sheet = mix(RGB(0x7B3FE4), 0.22, surface)                 // styles.css:579
        case "blue":   sheet = mix(RGB(dark ? 0x8B7DFF : 0x4737FF), 0.18, surface)   // :580
        case "orange": sheet = mix(RGB(0xF75C03), 0.20, surface)                 // :581
        case "red":    sheet = mix(RGB(0xD92D20), 0.15, surface)                 // :582
        case "stone":  sheet = mix(RGB(0x5E5E6A), 0.16, surface)                 // :583
        case "white":  sheet = surface                                           // :584
        default:       sheet = RGB(dark ? 0x26233A : 0xD1CDFF)                   // lavender, :447/463
        }

        let edge: Color = key == "white"
            ? theme.lineStrong
            : (dark ? Color(hex: 0xFFFFFF, opacity: 0.08) : Color(hex: 0x101018, opacity: 0.09))

        return NotePaper(
            paper: sheet.color,
            edge: edge,
            dot: dark ? Color(hex: 0xFFFFFF, opacity: 0.10) : Color(hex: 0x101018, opacity: 0.10),
            ink: dark ? Color(hex: 0xF3F2FB) : Color(hex: 0x101018),
            faint: dark ? Color(hex: 0xF3F2FB, opacity: 0.45) : Color(hex: 0x101018, opacity: 0.42),
            /* `.note-card[data-paper]` — lavender has no attribute, so the
               card keeps the plain surface for it. */
            card: key == "lavender" ? theme.surface : mix(sheet, 0.55, surface).color
        )
    }
}

// MARK: - the words on the card

/// `noteTitleOf` / `firstLine` (app.js:4364-4375), and the preview rule.
enum NoteText {

    /// `n.title.trim() || firstLine(n.body) || 'Untitled'`.
    static func title(_ n: NoteItem) -> String {
        let t = JSText.trim(n.title)
        if !t.isEmpty { return t }
        let first = firstLine(n.body)
        return first.isEmpty ? Copy.Notes.untitled : first
    }

    /// The first line of the body, trimmed, and cut at 80 — `slice(0, 79)`
    /// plus an ellipsis, so the cut string is 80 units long including it.
    static func firstLine(_ body: String) -> String {
        let line = JSText.trim(JSText.trim(body).components(separatedBy: "\n").first ?? "")
        guard line.utf16.count > 80 else { return line }
        return Normalize.slice(line, 79) + "…"
    }

    /// What goes under the title: the whole body when the note has a
    /// title of its own, and everything after the first line when the
    /// first line IS the title. Empty means no preview at all, not an
    /// empty one.
    static func preview(_ n: NoteItem) -> String {
        let rest = JSText.trim(n.title).isEmpty
            ? JSText.trim(n.body).components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            : n.body
        return JSText.trim(rest)
    }
}

// MARK: - the card

struct NoteCard: View {

    @Environment(\.theme) private var theme

    let note: NoteItem
    var open: () -> Void

    var body: some View {
        let paper = NotePaper.of(note.look.paper, theme: theme)
        let preview = NoteText.preview(note)

        Button(action: open) {
            VStack(alignment: .leading, spacing: 5) {
                Text(NoteText.title(note))
                    .font(Font.baloo(15.5, .bold))
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)

                if !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 13.5))
                        .lineSpacing(13.5 * 0.45)
                        .foregroundStyle(theme.muted)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }

                foot
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(paper.card, in: RoundedRectangle(cornerRadius: Theme.radiusLg,
                                                         style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// When it was last touched, then a paperclip with a count and a bell
    /// with a day — each only when there is one.
    private var foot: some View {
        HStack(spacing: 10) {
            Text(WebDates.noteWhen(note.updatedAt))
                .font(.system(size: 11.5))
                .foregroundStyle(theme.faint)

            if !note.files.isEmpty {
                tag("paperclip", "\(note.files.count)")
            }
            if let on = note.remindOn,
               let label = WebDates.whenLabel(when: on, at: note.remindAt)
            {
                tag("bell", label)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tag(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
            Text(label)
                .font(.system(size: 11.5))
        }
        .foregroundStyle(theme.faint)
    }
}
