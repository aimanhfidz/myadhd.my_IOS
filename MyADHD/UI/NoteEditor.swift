/* ============================================================
   MyADHD/UI/NoteEditor.swift — the note, being written

   `openNote` / `closeNote` / `leaveNote` / `deleteNote` (app.js:4944-4998),
   `paintNoteEditor` / `renderBlock` (4570-4635), `touchNote` (4661-4665),
   `setBlockType` / `setBlockAlign` (4778-4800), `#screen-note`
   (app.html:514-655).

   **Two write intents, and they are not interchangeable.** Every
   keystroke, tick, paper, picture and alignment goes through
   `AppStore.editNote` → `touchNote` → `persistOnly()`: the note is on
   disk before the letter is on screen, and nothing is ever lost to a
   closed editor. `save()` — which stamps every task for the cloud and
   pokes both sync timers — runs only where the web runs it: a new note, a
   close, a delete, an undo, and the two reminder buttons. Calling it per
   letter would have the phone rebuild its notification schedule once per
   letter, which is why app.js:4657 says not to.

   **Blank means blank in three fields and no more.** `noteIsBlank` is
   title, body and files. A note carrying nothing but a chosen paper or a
   set reminder IS blank and is deleted when you leave — you picked a
   colour, you did not write anything down. That is `AppStore.closeNote`'s
   rule and it is the web's, and it is the one place in this screen where
   doing the obvious thing instead would quietly keep a screenful of
   coloured blanks.

   **The ordinal restarts.** A numbered line counts up only over
   consecutive `ol` blocks; any other type in between puts it back to
   zero, so a list interrupted by a paragraph begins again at 1. That is
   `paintNoteEditor`'s two lines and it is not what a browser's `<ol>`
   would do, which is why it is written out here rather than left to a
   layout.

   **Nothing here schedules a notification.** A note's reminder is stored
   and drawn and that is all it has ever done — not in app.js, not in
   sw.js, not in the old shell, whose `Reminders.swift` reads tasks only.
   Making it ring is a new feature and it is not this file's to invent.
   ============================================================ */

import SwiftUI
import UIKit

struct NoteEditor: View {

    @Environment(\.theme) private var theme

    let store: AppStore
    let toasts: ToastCenter
    let noteID: String
    /// `leaveNote()` — the index is what is underneath.
    var onLeave: () -> Void

    /// `fmtBlock`: the block the format sheet is pointed at, which is the
    /// last one to have taken the caret.
    @State private var fmtBlock = 0
    @State private var sheet: NoteSheet?
    @State private var focus = NoteFocus()
    @State private var picking = false
    @FocusState private var titleFocused: Bool
    /// The one-shot that puts the caret where `openNote` puts it.
    @State private var opened = false
    /// The one-shot on the way out — see `leaveOnce`.
    @State private var left = false

    /// Which of the three is up. Only ever one: each of the three
    /// toolbar buttons closes the other two (app.js:5183-5228).
    enum NoteSheet: String, Identifiable {
        case format, paper, remind
        var id: String { rawValue }
    }

    private var note: NoteItem? { store.doc.note(id: noteID) }

    // MARK: -

    var body: some View {
        if let note {
            let paper = NotePaper.of(note.look.paper, theme: theme)

            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    header(note)
                    canvas(note, paper: paper)
                }
                .background(theme.surface.ignoresSafeArea())

                NoteToolbar(note: note,
                            paper: paper,
                            open: sheet,
                            onPaper: { toggle(.paper) },
                            onType: { toggle(.format) },
                            onCheck: { setType("check") },
                            onClip: { picking = true },
                            onBell: { toggle(.remind) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 12)

                sheetLayer(note)
            }
            .toastLayer(toasts, hasTabBar: false)
            .notePictures(isPresented: $picking, note: note, store: store, toasts: toasts)
            .task { await openOnce(note) }
        } else {
            /* The note has gone — deleted from under the editor. There is
               nothing to draw and nowhere to be. */
            Color.clear.onAppear(perform: leaveOnce)
        }
    }

    // MARK: the bar

    /// `.sheet-bar`: back, the live heading, and a round confirm. Both
    /// buttons do the same thing — there is no discard.
    private func header(_ note: NoteItem) -> some View {
        HStack(spacing: 10) {
            Button(action: leave) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 38, height: 38)
                    .background(theme.wash, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.Note.back)

            Text(JSText.trim(note.title).isEmpty ? Copy.Note.heading : JSText.trim(note.title))
                .font(Font.baloo(17, .bold))
                .kerning(-0.01 * 17)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)

            Button(action: leave) {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.surface)
                    .frame(width: 36, height: 36)
                    .background(theme.ink, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.Note.done)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: the sheet of paper

    private func canvas(_ note: NoteItem, paper: NotePaper) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    title(note, paper: paper)
                    blocks(note, paper: paper)
                    if !note.files.isEmpty {
                        NotePictureStrip(note: note, store: store)
                            .padding(.top, 16)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
                .background(NoteGrain(paper: paper))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                        .strokeBorder(paper.edge, lineWidth: 1.5)
                )

                remindLine(note)

                Button(action: delete) {
                    Text(Copy.Note.delete)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(theme.faint)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .padding(.top, 18)
            }
            .frame(maxWidth: Theme.measure, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// `<input maxlength=160>` — 24px, 800, and Enter moves to the first
    /// block rather than doing nothing.
    private func title(_ note: NoteItem, paper: NotePaper) -> some View {
        TextField("", text: Binding(
            get: { note.title },
            set: { next in store.editNote(noteID) { $0.title = Normalize.slice(next, 160) } }
        ), prompt: Text(Copy.Note.titlePlaceholder).foregroundColor(paper.faint))
            .font(Font.baloo(24, .heavy))
            .kerning(-0.02 * 24)
            .foregroundStyle(paper.ink)
            .textInputAutocapitalization(.sentences)
            .autocorrectionDisabled(true)     // spellcheck="false", app.html:528
            .submitLabel(.next)
            .focused($titleFocused)
            .onSubmit {
                titleFocused = false
                focus.target = .block(index: 0, offset: 0)
            }
            .padding(.bottom, 6)
    }

    /// One row per block: the lead glyph, then the text.
    private func blocks(_ note: NoteItem, paper: NotePaper) -> some View {
        let ordinals = Self.ordinals(note.blocks)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(note.blocks.enumerated()), id: \.offset) { i, block in
                HStack(alignment: .top, spacing: 8) {
                    lead(block, index: i, ordinal: ordinals[i], paper: paper)
                    BlockTextView(
                        index: i,
                        block: block,
                        face: .block(type: block.type, font: note.look.font),
                        /* A ticked line used to be faded to `paper.faint`
                           *and* struck through, and the two together read
                           as deleted rather than done — the thing you had
                           just finished was the hardest thing on the page
                           to see. The strike stays, because that is the
                           web's and is drawn from `done` rather than
                           stored as a mark (MarksBridge.swift:36-39); the
                           fade goes, and the line takes the accent the
                           box beside it is already filled with. Finished
                           work is worth looking at. */
                        ink: UIColor(block.done ? theme.accent : paper.ink),
                        faint: UIColor(paper.faint),
                        hintText: (i == 0 && block.text.isEmpty) ? Copy.Note.firstBlockHint : nil,
                        focusTarget: focus.target,
                        onEdit: { text, marks in edit(i, text: text, marks: marks) },
                        onSplit: { at in split(i, at: at) },
                        onMergeBack: { merge(i) },
                        onFocused: { fmtBlock = i },
                        onFocusApplied: { focus.target = nil }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minHeight: 220, alignment: .topLeading)
        /* `pointerdown` on `#note-blocks` itself → the last block, caret
           at the end (app.js:5167-5174). Tapping the paper under the
           writing puts you back in the writing. */
        .contentShape(Rectangle())
        .onTapGesture { tapBelow(note) }
    }

    @ViewBuilder
    private func lead(_ block: NoteBlock, index: Int, ordinal: Int, paper: NotePaper) -> some View {
        switch block.type {
        case "check":
            Button {
                store.editNote(noteID) { $0.blocks[index].done.toggle() }
            } label: {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(block.done ? theme.accent : Color.clear)
                    .frame(width: 18, height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(block.done ? theme.accent : paper.faint, lineWidth: 2)
                    )
                    .padding(.top, 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(block.done ? Copy.Note.tickOff : Copy.Note.notDone)
        case "ul":
            leadText("•", paper: paper)
        case "ol":
            leadText("\(ordinal).", paper: paper)
        default:
            EmptyView()
        }
    }

    private func leadText(_ s: String, paper: NotePaper) -> some View {
        Text(s)
            .font(.system(size: 15))
            .foregroundStyle(paper.faint)
            .frame(minWidth: 16, alignment: .leading)
            .padding(.top, 3)
    }

    /// `Reminder Tomorrow · 9am, every day`.
    @ViewBuilder
    private func remindLine(_ note: NoteItem) -> some View {
        if let on = note.remindOn,
           let when = WebDates.whenLabel(when: on, at: note.remindAt)
        {
            HStack(spacing: 6) {
                Image(systemName: "bell")
                    .font(.system(size: 11, weight: .medium))
                Text(Copy.Note.Remind.line(when, Copy.Note.Remind.every(note.repeatRule)))
                    .font(.system(size: 12.5))
            }
            .foregroundStyle(theme.accent)
            .padding(.top, 12)
        }
    }

    // MARK: the three sheets

    @ViewBuilder
    private func sheetLayer(_ note: NoteItem) -> some View {
        switch sheet {
        case .format:
            FormatSheet(note: note,
                        block: note.blocks.indices.contains(fmtBlock)
                            ? note.blocks[fmtBlock] : NoteBlock(),
                        close: { sheet = nil },
                        setType: setType,
                        setAlign: setAlign,
                        setFont: setFont,
                        applyMark: applyMark)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .paper:
            PaperSheet(note: note,
                       close: { sheet = nil },
                       pick: { key in store.editNote(noteID) { $0.look.paper = key } })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .remind:
            RemindSheet(note: note,
                        close: { sheet = nil },
                        save: saveRemind,
                        clear: clearRemind)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .none:
            EmptyView()
        }
    }

    private func toggle(_ which: NoteSheet) {
        withAnimation(Theme.settle(0.22)) { sheet = (sheet == which) ? nil : which }
    }

    // MARK: opening and leaving

    /// `openNote` (app.js:4944-4955): `fmtBlock = 0`, the format and
    /// remind sheets shut — and NOT the paper sheet, which app.js leaves
    /// alone and which therefore cannot be open here either, because this
    /// editor is created fresh each time.
    ///
    /// **The two halves of this need opposite things, which is why they
    /// are not one code path.**
    ///
    /// Going back into a note sets `focus.target`, and that is a *request*
    /// rather than a call: whichever block owns the index answers it and
    /// clears it through `onFocusApplied`, and until one does it simply
    /// waits. It cannot be too early, so it is made immediately.
    ///
    /// A new note's title is a SwiftUI `@FocusState`, and that one can be
    /// too early. The editor arrives as a `fullScreenCover`, whose
    /// `onAppear` fires at the *start* of the presentation transition —
    /// ask then and there is no responder yet to become first, so the
    /// keyboard did not come up at all. A fixed wait long enough to clear
    /// the transition is a wait everybody pays, on a phone that may also
    /// be launching a third-party keyboard extension behind it. So this
    /// asks, reads the answer back — `@FocusState` is written to when the
    /// field takes focus — and asks again until it sticks. It costs one
    /// 50ms hop on a phone that was ready, instead of 350ms on every one.
    ///
    /// It gives up after `focusBudget`, and stops early if anything else
    /// has asked for the keyboard in the meantime, so a person who taps
    /// a block or opens a sheet inside the first half-second does not get
    /// the title yanked back from under them.
    private func openOnce(_ note: NoteItem) async {
        guard !opened else { return }
        opened = true
        fmtBlock = 0
        sheet = nil

        guard JSText.trim(note.title).isEmpty && JSText.trim(note.body).isEmpty else {
            let last = max(0, note.blocks.count - 1)
            let end = note.blocks.indices.contains(last)
                ? note.blocks[last].text.utf16.count : 0
            focus.target = .block(index: last, offset: end)
            return
        }

        for _ in 0..<Self.focusAttempts {
            titleFocused = true
            try? await Task.sleep(nanoseconds: Self.focusRetry)
            if titleFocused || Task.isCancelled { return }
            // Somebody else wants it more than we do.
            if sheet != nil || focus.target != nil { return }
        }
    }

    /// 50ms a go, for up to three quarters of a second. The transition is
    /// ~0.35s, so the budget is roughly double what a slow one needs —
    /// long enough not to give up on a cold launch, short enough that a
    /// genuine failure stops rather than fights the screen.
    private static let focusRetry: UInt64 = 50_000_000
    private static let focusAttempts = 15

    /// `leaveNote()` = `closeNote()` + back to the index. The blank note
    /// is dropped inside `closeNote`.
    private func leave() {
        store.closeNote(noteID)
        leaveOnce()
    }

    /// **`onLeave` is called from two places and must run once.** `leave()`
    /// changes the store before it dismisses; for a blank note that is
    /// `closeNote` deleting it, which re-runs `body` with `note == nil` and
    /// fires the `Color.clear.onAppear` branch above on the way out. Today
    /// the second call only re-assigns a binding that is already nil, which
    /// is why nothing has gone wrong yet — this is here so that stays true
    /// the day `onLeave` does anything else.
    private func leaveOnce() {
        guard !left else { return }
        left = true
        onLeave()
    }

    /// `deleteNote()` (app.js:4981-4998). No confirmation, because there
    /// is an Undo — and the Undo puts it back at the same index rather
    /// than on the end, so the list does not reshuffle around it.
    private func delete() {
        guard let removal = store.deleteNote(noteID) else { return }
        onLeave()
        toasts.show(Copy.Note.deleted) {
            store.undoDeleteNote(removal)
        }
    }

    // MARK: the edits

    /// One block's text and marks came back from its view.
    private func edit(_ i: Int, text: String, marks: [NoteMark]) {
        store.editNote(noteID) { n in
            guard n.blocks.indices.contains(i) else { return }
            n.blocks[i].text = Normalize.slice(text, 2000)
            n.blocks[i].marks = marks
        }
    }

    private func split(_ i: Int, at offset: Int) {
        guard let note, let result = NoteEdit.split(note.blocks, at: i, offset: offset) else { return }
        store.editNote(noteID) { $0.blocks = result.blocks }
        focus.target = .block(index: result.caret, offset: result.offset)
    }

    /// Returns true when the merge happened, so the text view knows not to
    /// run its own delete as well.
    private func merge(_ i: Int) -> Bool {
        guard let note, let result = NoteEdit.merge(note.blocks, at: i) else { return false }
        store.editNote(noteID) { $0.blocks = result.blocks }
        focus.target = .block(index: result.caret, offset: result.offset)
        return true
    }

    /// `setBlockType` — choosing the type a line already is puts it back
    /// to a paragraph, and leaving `check` unticks it.
    private func setType(_ type: String) {
        guard let note, note.blocks.indices.contains(fmtBlock) else { return }
        let was = note.blocks[fmtBlock].type
        let next = was == type ? "p" : type
        store.editNote(noteID) { n in
            n.blocks[fmtBlock].type = next
            if next != "check" { n.blocks[fmtBlock].done = false }
        }
        focus.target = .block(index: fmtBlock,
                              offset: note.blocks[fmtBlock].text.utf16.count)
    }

    private func setAlign(_ align: String) {
        guard let note, note.blocks.indices.contains(fmtBlock) else { return }
        store.editNote(noteID) { $0.blocks[fmtBlock].align = align }
        focus.target = .block(index: fmtBlock,
                              offset: note.blocks[fmtBlock].text.utf16.count)
    }

    private func setFont(_ font: String) {
        store.editNote(noteID) { $0.look.font = font }
    }

    /// B / I / U / S. The web hands the live selection to `execCommand`
    /// and reads whatever the browser emitted straight back out; here the
    /// same flip is made on the attributed string and read back through
    /// `MarksBridge`, which is the same round trip with one fewer engine
    /// in it.
    ///
    /// With nothing selected it changes the typing attributes instead, so
    /// the next thing typed carries it — which is what a browser does with
    /// a collapsed selection too.
    private func applyMark(_ kind: String) {
        guard let note, note.blocks.indices.contains(fmtBlock) else { return }
        guard let view = UIResponder.currentFirstResponder as? BlockTextInput else { return }

        let flag: MarksBridge.Flags
        switch kind {
        case "b": flag = .b
        case "i": flag = .i
        case "u": flag = .u
        default:  flag = .strike
        }

        let block = note.blocks[fmtBlock]
        let face = MarksBridge.Face.block(type: block.type, font: note.look.font)
        let base: MarksBridge.Flags = block.done ? [.strike] : []
        let range = view.selectedRange

        if range.length == 0 {
            view.typingAttributes = MarksBridge.toggled(flag, in: view.typingAttributes,
                                                        face: face, base: base)
            return
        }

        let next = NSMutableAttributedString(attributedString: view.attributedText)
        MarksBridge.toggle(flag, in: range, of: next, face: face, base: base)
        view.attributedText = next
        view.selectedRange = range

        let read = MarksBridge.read(next, face: face, base: base)
        edit(fmtBlock, text: read.text, marks: read.marks)
    }

    /// Tapping the paper below the last line. `focusBlock(last, end)`.
    private func tapBelow(_ note: NoteItem) {
        let last = max(0, note.blocks.count - 1)
        let end = note.blocks.indices.contains(last) ? note.blocks[last].text.utf16.count : 0
        focus.target = .block(index: last, offset: end)
    }

    // MARK: the reminder

    /// `saveRemind` (app.js:4915-4925). The time and the repeat are only
    /// kept if the day survived `normalizeDay` — a time on no day is a
    /// time on no calendar.
    private func saveRemind(_ day: String, _ time: String, _ rule: String) {
        store.saveNote(noteID) { n in
            n.remindOn = Normalize.normalizeDay(day)
            n.remindAt = n.remindOn != nil ? Normalize.normalizeTime(time) : nil
            n.repeatRule = n.remindOn != nil ? rule : ""
        }
        withAnimation(Theme.outSheet(0.18)) { sheet = nil }
    }

    private func clearRemind() {
        store.saveNote(noteID) { n in
            n.remindOn = nil
            n.remindAt = nil
            n.repeatRule = ""
        }
        withAnimation(Theme.outSheet(0.18)) { sheet = nil }
    }

    // MARK: the ordinals

    /// `paintNoteEditor`'s counter: up over consecutive `ol` blocks, back
    /// to zero the moment anything else appears. Held as a table rather
    /// than recomputed per row so the reset is one rule in one place.
    static func ordinals(_ blocks: [NoteBlock]) -> [Int] {
        var out: [Int] = []
        var n = 0
        for b in blocks {
            if b.type == "ol" { n += 1 } else { n = 0 }
            out.append(n)
        }
        return out
    }
}

// MARK: - the grain

/// `background-image: radial-gradient(var(--note-dot) 1px, transparent 1px)`
/// at 14px/14px, offset 10px 12px. One dot per cell, drawn rather than
/// tiled from an asset — as on the web, where it is one gradient and not
/// an image either.
struct NoteGrain: View {
    let paper: NotePaper

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 14
            let radius: CGFloat = 1
            var y: CGFloat = 12
            while y < size.height {
                var x: CGFloat = 10
                while x < size.width {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                               width: radius * 2, height: radius * 2)),
                        with: .color(paper.dot))
                    x += step
                }
                y += step
            }
        }
        .background(paper.paper)
        .drawingGroup()
    }
}

// MARK: - who has the caret

extension UIResponder {
    private static weak var found: UIResponder?

    /// The text view the caret is in. There is no public way to ask UIKit
    /// this, and the format sheet's B/I/U/S has to have it: the sheet is
    /// not a responder itself, so `firstResponder` is still whichever
    /// block was being typed in.
    static var currentFirstResponder: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(claimFirstResponder), to: nil, from: nil, for: nil)
        return found
    }

    @objc private func claimFirstResponder() {
        UIResponder.found = self
    }
}
