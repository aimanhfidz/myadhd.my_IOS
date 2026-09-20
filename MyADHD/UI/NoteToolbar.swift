/* ============================================================
   MyADHD/UI/NoteToolbar.swift — five tools, on the right

   `#note-tools` (app.html:540-558; app.js:5176-5228), restyled as a rail
   by the shell (BridgeScript.swift:279-312).

   **Why it is a rail and not a pill along the bottom.** On the web it sat
   where the tab bar sits, and the keyboard's accessory bar drew straight
   over it — the tools were unreachable exactly while you were writing,
   which is the only time they are wanted. A vertical rail at mid-height
   on the right is out of the keyboard's way and inside the thumb's, and
   that is the shape the shell has shipped for long enough that changing
   it back would be the change.

   **The paper button is a swatch and not a gear**, because the colour it
   changes is the note's own and the button should look like the thing it
   changes. It is also the one button here that does not keep the caret:
   app.js cancels `pointerdown` on the other four so the text never loses
   focus, and leaves paper alone. Natively nothing steals focus from a
   text view by being tapped, so all five keep it — the distinction has no
   effect here and is written down rather than reproduced as ceremony.

   The bell lights up while a reminder is set (`.is-on`), which is the
   only state any of the five carries.
   ============================================================ */

import SwiftUI

struct NoteToolbar: View {

    @Environment(\.theme) private var theme

    let note: NoteItem
    let paper: NotePaper
    /// Which sheet is up, so the tool that opened it can light.
    let open: NoteEditor.NoteSheet?

    var onPaper: () -> Void
    var onType: () -> Void
    var onCheck: () -> Void
    var onClip: () -> Void
    var onBell: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button(action: onPaper) {
                Circle()
                    .fill(paper.paper)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(paper.edge, lineWidth: 2))
                    .frame(width: 44, height: 44)
                    .background(open == .paper ? theme.wash2 : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.Note.toolPaper)

            tool("textformat", Copy.Note.toolType, on: open == .format, action: onType)
            tool("checklist", Copy.Note.toolCheck, on: false, action: onCheck)
            tool("paperclip", Copy.Note.toolClip, on: false, action: onClip)
            tool("bell", Copy.Note.toolBell, on: note.remindOn != nil, action: onBell)
        }
        .padding(.vertical, 10)
        .frame(width: 54)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(theme.surface.opacity(0.84)))
                .overlay(Capsule().strokeBorder(theme.line.opacity(0.70), lineWidth: 1))
        }
        .compositingGroup()
        .shadow(color: Color(hex: 0x101018, opacity: 0.14), radius: 14, y: 8)
    }

    private func tool(_ symbol: String, _ label: String,
                      on: Bool, action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(on ? theme.accent : theme.muted)
                .frame(width: 44, height: 44)
                .background(on ? theme.wash2 : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - what all three sheets sit in

/// `.note-sheet`, as the shell shapes it: full width, rounded on top,
/// sitting on the safe area, with a grab handle and a titled bar.
///
/// It is NOT a `.sheet`. A presented sheet takes the keyboard down and the
/// first responder with it, and every one of these three is meant to be
/// used while the caret is still in the writing — the format sheet in
/// particular has nothing to format once the caret has gone.
struct NoteSheetShell<Content: View>: View {

    @Environment(\.theme) private var theme

    let title: String
    var close: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(theme.lineStrong)
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)

            HStack(spacing: 0) {
                Text(title)
                    .font(Font.baloo(16, .bold))
                    .foregroundStyle(theme.ink)
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .frame(width: 36, height: 36)
                        .background(theme.wash, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Note.closeSheet)
            }
            .padding(.bottom, 12)

            content()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 26, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0, topTrailingRadius: 26,
                                   style: .continuous)
                .fill(theme.surface)
                .overlay(alignment: .top) {
                    Rectangle().fill(theme.line).frame(height: 1.5)
                }
                .shadow(color: Color(hex: 0x101018, opacity: 0.18), radius: 20, y: -6)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

// MARK: - the pill buttons the format sheet is made of

/// `.fmt-btn` — sized to its own word rather than stretched to fill the
/// row, because five buttons across two rows leaves one of them a mile
/// wide otherwise.
struct FormatPill: View {

    @Environment(\.theme) private var theme

    let label: String
    var on: Bool
    /// `.fmt-b` / `.fmt-i` / `.fmt-u` / `.fmt-s` — the four emphasis
    /// buttons wear what they do.
    var style: Style = .plain
    var action: () -> Void

    enum Style { case plain, bold, italic, underline, strike }

    var body: some View {
        Button(action: action) {
            text
                .foregroundStyle(on ? theme.onAccent : theme.muted)
                .frame(minWidth: 52)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(on ? theme.accent : theme.surface, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(on ? theme.accent : theme.lineStrong, lineWidth: 1.5)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    @ViewBuilder
    private var text: some View {
        switch style {
        case .plain:
            Text(label).font(.system(size: 13, weight: .semibold))
        case .bold:
            Text(label).font(.system(size: 13, weight: .heavy))
        case .italic:
            Text(label).font(.system(size: 13, weight: .semibold)).italic()
        case .underline:
            Text(label).font(.system(size: 13, weight: .semibold)).underline()
        case .strike:
            Text(label).font(.system(size: 13, weight: .semibold)).strikethrough()
        }
    }
}
