/* ============================================================
   MyADHD/UI/PaperSheet.swift — seven papers

   `#sheet-paper` (app.html:597-616), `applyLook` (app.js:4343-4353),
   the swatches (styles.css:606-613).

   Washes of the app's own hues, not a rainbow: every one of the seven is
   a token from theme.css at a fraction, mixed against the surface — so a
   note can only ever be a colour the rest of the app already is, and the
   same seven names read on both grounds without a second table. The
   arithmetic is in `NotePaper`; this is the row of buttons.

   Two of the seven are named something other than their colour and both
   are on purpose:

   - **Lavender** is the default and the one with no stored attribute, so
     a note nobody has ever changed still draws the way it did before
     papers existed.
   - **White** is labelled **Plain**, because it is not a colour — it is
     the page itself, which is why it is also the only one that moves the
     edge (to `--line-strong`; a sheet the same colour as the page behind
     it needs a border you can see).
   ============================================================ */

import SwiftUI

struct PaperSheet: View {

    @Environment(\.theme) private var theme

    let note: NoteItem
    var close: () -> Void
    var pick: (String) -> Void

    var body: some View {
        NoteSheetShell(title: Copy.Note.Paper.title, close: close) {
            WrapRow(spacing: 12, lineSpacing: 12) {
                ForEach(NoteLook.papers, id: \.self) { key in
                    swatch(key)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Copy.Note.Paper.group)
            .padding(.top, 4)
            .padding(.bottom, 2)
        }
    }

    private func swatch(_ key: String) -> some View {
        let paper = NotePaper.of(key, theme: theme)
        let on = note.look.paper == key

        return Button { pick(key) } label: {
            Circle()
                .fill(paper.paper)
                .frame(width: 36, height: 36)
                .overlay(Circle().strokeBorder(paper.edge, lineWidth: 2))
                /* `.is-on { box-shadow: 0 0 0 3px surface, 0 0 0 5px ink }`
                   — a gap and then a ring, so the mark reads on a swatch
                   whose own colour is nearly the surface. */
                .overlay(
                    Circle()
                        .strokeBorder(on ? theme.ink : .clear, lineWidth: 2)
                        .padding(-5)
                )
                .scaleEffect(on ? 1.04 : 1)
                .animation(Theme.ease(0.14), value: on)
                .padding(5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.Note.Paper.label(key))
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}
