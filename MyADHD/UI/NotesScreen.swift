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

   **Two shapes, not one list that can be empty.** Both are under the same
   header, which says `Notes` where the web said it twice — once in the
   eyebrow and once in the count line, both of which are gone with it.

   - With notes: the cards, the hint — and the `New note` button has moved
     to the bottom right as a 60pt `+`. That is the shell's doing
     (`#btn-note-new` restyled by `:has(#notes-list > *)`), and it is kept
     because it is right: a full-width primary CTA above a list of notes is
     a banner for the one thing the screen is already about.
   - With none: the empty state alone, centred in what is left below the
     header, with its own button. The hint, the list and the `+` are all
     absent — `renderNotes` hides each of them by name.

   **The `+` is the only way to a second note, so it has to be reachable.**
   The tab bar's `+` opens the composer, not a note, and the empty state's
   button is gone the moment there is one note. It sat behind the tab bar
   for as long as nothing reserved the bar's room — see `AppShell`.

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

        VStack(alignment: .leading, spacing: 0) {
            /* The eyebrow this replaces said `NOTES.` in small caps, and
               the line under it said how many — the screen's own name in a
               second size, and a count. The header says the name once, and
               the reasoning is the shell's
               (reference/BridgeScript.swift:176-186). */
            ScreenHeader(title: Copy.ScreenTitle.notes)
                .padding(.horizontal, 20)

            if notes.isEmpty {
                /* Not in a scroller. There is one screenful here and it
                   never grows, so the block is centred in what is left
                   between the header and the bar rather than pinned to the
                   top of a `ScrollView` that has nothing to scroll. */
                empty
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
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
                        .frame(maxWidth: Theme.measure, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        /* `.notes-wrap { padding-bottom: safe + 160px }`
                           once the `+` is floating over the list — the last
                           card has to be reachable from under it.
                           `AppShell` already reserves the bar's own 96. */
                        .padding(.bottom, 74)
                    }

                    addButton
                }
            }
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

    /// `#notes-empty`. Violet-outlined, with the one thing to press. It
    /// carries no padding of its own — where it sits is the caller's, and
    /// the caller centres it in the whole screen.
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
