/* ============================================================
   MyADHD/UI/BlockTextView.swift — one line of a note, and the two keys
   that move between lines

   `renderBlock` (app.js:4588-4635), `readNoteFromDom` (4640-4652),
   `blockKey` (4672-4722), `caretOffset` (4728-4735), `focusBlock`
   (4737-4763).

   **One `UITextView` per block, not one for the whole note.** A block is
   the unit that carries a type, a tick, an alignment and a lead glyph;
   folding them into one text view would mean a paragraph style per line
   and a custom layout manager for the checkboxes, and the two keystrokes
   below would become range surgery inside one string rather than a list
   edit. The web made the same choice — one contenteditable `div` per
   block — and everything downstream of it follows from that.

   **The three things a text view has to be told that SwiftUI cannot.**

   1. **Return.** `shouldChangeTextIn` intercepts it and hands the offset
      up; nothing is inserted. The offset handed up is the END of the
      selection, which is `caretOffset`'s (`sel.getRangeAt(0).endOffset`)
      and not its start — so Enter over a selection keeps the selected
      text at the end of the first block rather than deleting it, exactly
      as the web does.
   2. **Backspace at the very start.** UIKit does not report a delete that
      would change nothing, so there is no delegate call to catch and
      `deleteBackward()` is overridden instead. That is the only route to
      the merge rule.
   3. **Shift + Return.** A soft return puts a real `\n` INSIDE the block
      (`<br>` on the web, read back as `\n` by `readBlockText`). It comes
      in as a key command so the ordinary Return can stay intercepted, and
      it edits the attributed string directly rather than going through
      `insertText` — which would come straight back round through
      `shouldChangeTextIn` and be read as a split.

   **Why the view is never blindly reloaded.** `updateUIView` reads what
   the view currently holds back through `MarksBridge` and compares it to
   the block; only a real difference reloads it. Without that, every
   keystroke would write the store, the store would repaint the editor,
   and the repaint would drop the caret to the end of the line.
   ============================================================ */

import SwiftUI
import UIKit

// MARK: - where the caret is being sent

/// One pending focus move. The editor asks; whichever view owns that
/// index does it and clears the request.
///
/// `focusBlock(i, offset)` on the web is a call; here the view that has
/// to answer it may not exist yet — a split creates a block and then
/// focuses it — so it is a request that survives one render.
@MainActor
@Observable
final class NoteFocus {
    enum Target: Equatable {
        case title
        case block(index: Int, offset: Int)
    }
    var target: Target?
}

// MARK: - the text view itself

/// `UITextView` with the two keystrokes the web owns and UIKit does not
/// report.
final class BlockTextInput: UITextView {

    /// Backspace with nothing behind the caret. Returns true when it has
    /// been dealt with — the block merged into the one above — and the
    /// default delete is then not run.
    var onBackspaceAtStart: (() -> Bool)?

    /// Called after a soft return has put a newline in, because editing
    /// `attributedText` directly does not tell the delegate.
    var onSoftReturn: (() -> Void)?

    override func deleteBackward() {
        if selectedRange.location == 0, selectedRange.length == 0,
           onBackspaceAtStart?() == true
        {
            return
        }
        super.deleteBackward()
    }

    override var keyCommands: [UIKeyCommand]? {
        let soft = UIKeyCommand(input: "\r", modifierFlags: .shift,
                                action: #selector(softReturn))
        /* Otherwise the text system eats the return before the command
           ever runs, and shift-return is just return. */
        soft.wantsPriorityOverSystemBehavior = true
        return [soft]
    }

    @objc private func softReturn() {
        let at = selectedRange
        let next = NSMutableAttributedString(attributedString: attributedText)
        let run = NSAttributedString(string: "\n", attributes: typingAttributes)
        let clipped = NSIntersectionRange(at, NSRange(location: 0, length: next.length))
        next.replaceCharacters(in: at.length > 0 ? clipped : at, with: run)
        attributedText = next
        selectedRange = NSRange(location: min(at.location + 1, next.length), length: 0)
        onSoftReturn?()
    }
}

// MARK: - the block, as a view

struct BlockTextView: UIViewRepresentable {

    let index: Int
    let block: NoteBlock
    let face: MarksBridge.Face
    let ink: UIColor
    let faint: UIColor
    /// `data-hint`, which only block 0 gets and only while it is empty.
    let hintText: String?
    /// The focus request as the editor's body last saw it.
    let focusTarget: NoteFocus.Target?

    /// `readNoteFromDom` → `touchNote`.
    var onEdit: (String, [NoteMark]) -> Void
    /// Return: the caret offset it was pressed at.
    var onSplit: (Int) -> Void
    /// Backspace at offset 0. Returns true when the merge happened.
    var onMergeBack: () -> Bool
    /// `focus` → `fmtBlock = i`.
    var onFocused: () -> Void
    var onFocusApplied: () -> Void

    /// A ticked-off line is struck through by its TYPE, not by a mark.
    private var base: MarksBridge.Flags { block.done ? [.strike] : [] }

    /// Everything about the block that changes how it is drawn but does
    /// not change its text. When this moves, the view is rebuilt even
    /// though the words are the same.
    private var styleToken: String {
        [block.type, block.align, block.done ? "1" : "0",
         face.regular.fontName, String(format: "%.2f", face.regular.pointSize),
         "\(ink.hashValue)", hintText ?? "-"].joined(separator: "|")
    }

    // MARK: making it

    func makeUIView(context: Context) -> BlockTextInput {
        let view = BlockTextInput()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.spellCheckingType = .yes            // spellcheck="true", app.js:4622
        view.autocorrectionType = .default
        view.adjustsFontForContentSizeCategory = false
        /* `.nb-text:empty[data-hint]::before`. A label rather than a
           placeholder, because UITextView has none. */
        let label = UILabel()
        label.numberOfLines = 0
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
        ])
        context.coordinator.hint = label

        return view
    }

    // MARK: keeping it

    func updateUIView(_ view: BlockTextInput, context: Context) {
        let c = context.coordinator
        c.parent = self

        /* Hung here rather than in `makeUIView`: these two close over the
           representable, and the representable is a fresh value on every
           render. Captured once at creation they would still be calling
           into the editor as it was when the block first appeared. */
        view.onBackspaceAtStart = { [weak c] in c?.parent.onMergeBack() ?? false }
        view.onSoftReturn = { [weak c, weak view] in
            guard let c, let view else { return }
            c.push(view)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = Self.alignment(block.align)
        paragraph.lineHeightMultiple = block.type == "h" ? 1.2 : 1.35

        /* Only reload when the view is actually holding something else.
           Mid-composition the view is holding a marked range that is not
           text yet, and replacing it under an IME loses the composition. */
        let held = MarksBridge.read(view.attributedText, face: face, base: base)
        let stale = c.appliedStyle != styleToken
            || held.text != block.text
            || held.marks != block.marks
        if stale && view.markedTextRange == nil {
            let was = view.selectedRange
            let next = MarksBridge.attributed(text: block.text, marks: block.marks,
                                              face: face, ink: ink, base: base,
                                              paragraph: paragraph)
            view.attributedText = next
            let end = next.length
            view.selectedRange = NSRange(location: min(was.location, end), length: 0)
            c.appliedStyle = styleToken
        }

        view.typingAttributes = MarksBridge.baseAttributes(face: face, ink: ink,
                                                           base: base, paragraph: paragraph)
        view.textColor = block.done ? faint : ink

        c.hint?.text = hintText
        c.hint?.font = face.regular
        c.hint?.textColor = faint
        c.hint?.textAlignment = Self.alignment(block.align)
        c.hint?.isHidden = hintText == nil || !block.text.isEmpty

        if case .block(let i, let offset) = focusTarget, i == index {
            /* Not during the update: becoming first responder here runs a
               layout pass inside SwiftUI's, and clearing the request is a
               write to observed state from inside a read of it. */
            DispatchQueue.main.async {
                onFocusApplied()
                view.becomeFirstResponder()
                let end = view.attributedText.length
                view.selectedRange = NSRange(location: max(0, min(offset, end)), length: 0)
            }
        }
    }

    static func alignment(_ align: String) -> NSTextAlignment {
        switch align {
        case "center": return .center
        case "right":  return .right
        default:       return .left
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: the delegate

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {

        var parent: BlockTextView
        var hint: UILabel?
        /// What `styleToken` was when the view was last loaded.
        var appliedStyle: String?

        init(_ parent: BlockTextView) { self.parent = parent }

        /// `readNoteFromDom`, for this one block.
        func push(_ view: UITextView) {
            let (text, marks) = MarksBridge.read(view.attributedText,
                                                 face: parent.face,
                                                 base: parent.block.done ? [.strike] : [])
            appliedStyle = parent.styleToken
            hint?.isHidden = parent.hintText == nil || !text.isEmpty
            parent.onEdit(text, marks)
        }

        func textViewDidChange(_ textView: UITextView) {
            push(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocused()
        }

        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool
        {
            /* Return, and nothing else. A paste that happens to contain
               newlines goes in whole — `readBlockText` turns a `<br>` back
               into a `\n` inside the block, so a block holding newlines is
               a shape the store already has. */
            if text == "\n" {
                parent.onSplit(range.location + range.length)
                return false
            }
            return true
        }
    }
}

// MARK: - the faces a block can be drawn in

extension MarksBridge.Face {

    /// The block's face, from its type and the note's chosen one.
    ///
    /// `.nb-text` sets `font-family: var(--sans)` on itself and
    /// `.nb--h .nb-text` sets `var(--display)`, which on the web means the
    /// canvas's `data-font` reaches neither of them — a declared value on
    /// the element always beats an inherited one, so on the page today
    /// picking Mono changes the TITLE and nothing else. That is a
    /// specificity accident rather than a decision, and this is the one
    /// place the port does not reproduce one: `look.font` dresses the
    /// whole sheet here, which is what the Typeface row in the format
    /// sheet says it will do. Everything else about a note is the page's
    /// answer, including the seven papers it is mixed from.
    static func block(type: String, font: String, size: CGFloat? = nil) -> MarksBridge.Face {
        let heading = type == "h"
        let points = size ?? (heading ? 19 : 15.5)

        switch font {
        case "mono":
            return monospaced(points, heavy: heading)
        case "sans":
            return system(points, heavy: heading)
        default:
            return baloo(points, heavy: heading) ?? system(points, heavy: heading)
        }
    }

    /// The title, which is 24px and 800 whatever else it is.
    static func title(font: String) -> MarksBridge.Face {
        switch font {
        case "mono": return monospaced(24, heavy: true)
        case "sans": return system(24, heavy: true)
        default:     return baloo(24, heavy: true) ?? system(24, heavy: true)
        }
    }

    // MARK: the three families

    private static func system(_ points: CGFloat, heavy: Bool) -> MarksBridge.Face {
        let base = UIFont.systemFont(ofSize: points, weight: heavy ? .bold : .regular)
        return build(base, boldWeight: heavy ? .heavy : .bold, points: points)
    }

    private static func monospaced(_ points: CGFloat, heavy: Bool) -> MarksBridge.Face {
        let base = UIFont.monospacedSystemFont(ofSize: points, weight: heavy ? .bold : .regular)
        let bold = UIFont.monospacedSystemFont(ofSize: points, weight: heavy ? .heavy : .bold)
        return MarksBridge.Face(regular: base,
                                bold: bold,
                                italic: italicised(base) ?? base,
                                boldItalic: italicised(bold) ?? bold)
    }

    /// Baloo 2 is a variable face and the bundled instance is the 400
    /// master, so a heavier cut has to be asked for through the
    /// descriptor. When it comes back the same font — which is what
    /// happens if the file ever stops carrying the axis — the four fonts
    /// would no longer be four, and `MarksBridge.read`'s fallback path
    /// could not tell a bold run from a plain one. So the answer is
    /// checked, and the system face is used rather than a face that
    /// cannot say.
    private static func baloo(_ points: CGFloat, heavy: Bool) -> MarksBridge.Face? {
        guard let base = weighted("Baloo2-Regular", points, heavy ? .bold : .regular),
              let bold = weighted("Baloo2-Regular", points, heavy ? .black : .bold),
              base != bold
        else { return nil }
        return MarksBridge.Face(regular: base,
                                bold: bold,
                                italic: italicised(base) ?? base,
                                boldItalic: italicised(bold) ?? bold)
    }

    private static func build(_ base: UIFont,
                              boldWeight: UIFont.Weight,
                              points: CGFloat) -> MarksBridge.Face
    {
        let bold = UIFont.systemFont(ofSize: points, weight: boldWeight)
        return MarksBridge.Face(regular: base,
                                bold: bold,
                                italic: italicised(base) ?? base,
                                boldItalic: italicised(bold) ?? bold)
    }

    private static func weighted(_ name: String, _ points: CGFloat,
                                 _ weight: UIFont.Weight) -> UIFont?
    {
        guard let raw = UIFont(name: name, size: points) else { return nil }
        let descriptor = raw.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: points)
    }

    /// Baloo 2 ships no italic cut, and `withSymbolicTraits` answers nil
    /// rather than inventing one. A browser does invent one — that is what
    /// `font-style: italic` on a family with no italic gets you — so the
    /// same shear is applied here rather than letting the run come out
    /// looking exactly like the text around it.
    private static func italicised(_ font: UIFont) -> UIFont? {
        var traits = font.fontDescriptor.symbolicTraits
        traits.insert(.traitItalic)
        if let real = font.fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: real, size: font.pointSize)
        }
        let sheared = font.fontDescriptor.withMatrix(
            CGAffineTransform(a: 1, b: 0, c: 0.22, d: 1, tx: 0, ty: 0))
        return UIFont(descriptor: sheared, size: font.pointSize)
    }
}
