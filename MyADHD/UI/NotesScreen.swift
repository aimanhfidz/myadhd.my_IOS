/* ============================================================
   MyADHD/UI/NotesScreen.swift — the index

   `renderNotes` / `showNotes` (app.js:4379-4395, 5000-5003),
   `#screen-notes` (app.html:456-506), and the shell's own two changes to
   it (BridgeScript.swift:286-299, 616-618).

   **Nothing sorts a note.** No pinning, no search, no folders, no
   archive, no filter row — one list, `updatedAt` descending, because the
   thing you touched last is the thing you are most likely to want. The
   tab bar's `+` still opens the dump composer here rather than making a
   note: `+` means sort this out for me, and not being sorted is what a
   note is for.

   **Two shapes, not one list that can be empty.**

   - With notes: eyebrow, count, the cards, the hint — and the `New note`
     button has moved to the bottom right as a 60pt `+`. That is the
     shell's doing (`#btn-note-new` restyled by `:has(#notes-list > *)`),
     and it is kept because it is right: a full-width primary CTA above a
     list of notes is a banner for the one thing the screen is already
     about.
   - With none: the empty state alone, centred, with its own button. The
     count, the hint, the list and the `+` are all absent — `renderNotes`
     hides each of them by name.

   The editor opens over this screen rather than beside it. On the web it
   is a screen of its own that the tab bar stands down for
   (`#screen-note` is not in `TAB_FOR`); here that is a full-screen cover,
   which is the same fact — while you are writing, there is nowhere else
   to be.
   ============================================================ */

import SwiftUI

struct NotesScreen: View {

    @Environment(\.theme) private var theme

    let store: AppStore
    let toasts: ToastCenter

    /// Which note is being written, if any. `openNoteId` on the web,
    /// wrapped because `fullScreenCover(item:)` wants an identity and a
    /// bare `String` has no business having one module-wide.
    struct Open: Identifiable { let id: String }
    @State private var openNote: Open?

    var body: some View {
        let notes = store.notesByRecent

        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if notes.isEmpty {
                        empty
                    } else {
                        Text(Copy.Notes.eyebrow.uppercased())
                            .font(Font.baloo(11, .bold))
                            .kerning(0.13 * 11)
                            .foregroundStyle(theme.faint)
                            .padding(.bottom, 12)

                        Text(Copy.Notes.summary(notes.count))
                            .font(Font.baloo(13.5))
                            .foregroundStyle(theme.faint)
                            .padding(.bottom, 22)

                        VStack(spacing: 10) {
                            ForEach(notes, id: \.id) { note in
                                NoteCard(note: note) { open(note.id) }
                            }
                        }

                        Text(Copy.Notes.hint)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.faint)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 14)
                    }
                }
                .frame(maxWidth: Theme.measure, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                /* `.notes-wrap { padding-bottom: safe + 160px }` once the
                   `+` is floating over the list — the last card has to be
                   reachable from under it. `TabShell` already reserves the
                   bar's own 96. */
                .padding(.bottom, notes.isEmpty ? 8 : 74)
            }

            if !notes.isEmpty { addButton }
        }
        .background(theme.surface.ignoresSafeArea())
        .fullScreenCover(item: $openNote) { open in
            NoteEditor(store: store, toasts: toasts, noteID: open.id) { openNote = nil }
                .environment(\.theme, theme)
                .preferredColorScheme(theme.dark ? .dark : .light)
        }
    }

    // MARK: opening one

    private func open(_ id: String) {
        openNote = Open(id: id)
    }

    /// `newNote()` — the note is on the store and saved before the editor
    /// is on screen, so a crash between the two leaves a blank note and
    /// not a lost one. It is `closeNote` that takes the blank away again.
    private func newNote() {
        openNote = Open(id: store.newNote().id)
    }

    // MARK: the two shapes

    /// `#notes-empty`. Centred, violet-outlined, with the one thing to
    /// press.
    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(theme.violet)
                .frame(width: 54, height: 54)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(theme.violet, lineWidth: 2)
                )
                .padding(.bottom, 4)

            Text(Copy.Notes.emptyTitle)
                .font(Font.baloo(17, .bold))
                .foregroundStyle(theme.ink)

            Text(Copy.Notes.emptyBody)
                .font(.system(size: 13.5))
                .lineSpacing(13.5 * 0.5)
                .foregroundStyle(theme.muted)
                .frame(maxWidth: 260)

            Button(action: newNote) {
                Text(Copy.Notes.emptyGo)
                    .font(Font.baloo(16.5, .bold))
                    .kerning(-0.01 * 16.5)
                    .foregroundStyle(Color(hex: 0xFFFFFF))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 13)
                    .background(theme.brandGradient, in: Capsule())
                    .shadow(color: Color(hex: 0x4737FF, opacity: 0.55), radius: 17, y: 8)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.top, 60)
    }

    /// The same button and the same handler as the empty state's, wearing
    /// the shape the shell gave it: 60pt, ink, bottom right, above the
    /// tab bar.
    private var addButton: some View {
        Button(action: newNote) {
            Image(systemName: "plus")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(theme.surface)
                .frame(width: 60, height: 60)
                .background(theme.ink, in: Circle())
                .shadow(color: Color(hex: 0x101018, opacity: 0.22), radius: 13, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.Notes.newNote)
        .padding(.trailing, 18)
        .padding(.bottom, 12)
    }
}
