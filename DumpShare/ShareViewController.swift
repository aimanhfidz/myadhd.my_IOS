/* ============================================================
   my.adhd — the share sheet

   The thought that arrives already written, inside somebody else's app.
   The mic covers the one you are carrying; this covers the road tax
   email, the group chat, the page you are halfway down — the ones where
   what needs capturing is on screen already and merely on the wrong
   screen.

   What matters is what it does NOT do. It does not open the app, so the
   home screen is never shown and nothing else gets a chance to take the
   thought on the way past. And it does not ask you to retype, so the
   date and the reference number arrive exactly as they were written
   rather than as they were remembered.

   SLComposeServiceViewController rather than a hand-built sheet: it is
   the box, the Cancel and the button, already looking like the system,
   for none of the code. The button says Post, which is not the word this
   app would choose — the first thing to replace if this stops being a
   proof of concept.
   ============================================================ */

import Social
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: SLComposeServiceViewController {

    /* The attachments are always asked, including when the box already
       has words in it. There used to be a guard here that skipped the
       whole load whenever it did, on the theory that Safari had "filled it
       already" — but what Safari fills the box with is the page's TITLE,
       and the address arrives separately, as an attachment. So the one
       share this file was written around kept the title and dropped the
       link every time. What arrives now is added to the box rather than
       put over it: see offer(heading:link:) and fill(_:). */
    override func presentationAnimationDidFinish() {
        super.presentationAnimationDidFinish()
        load()
    }

    /// Post stays disabled on an empty box, which is also what stops an
    /// image-only share from being queued as nothing.
    override func isContentValid() -> Bool {
        !(contentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    override func didSelectPost() {
        DumpQueue.add(contentText ?? "")
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    // MARK: - what was shared

    private func load() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem else { return }

        /* Sharing a page from Safari puts its title here and the address
           in an attachment; sharing a selection puts the words here and
           nothing else. Both are worth having, and which one this is is
           only knowable after the attachment has been asked. */
        let heading = item.attributedContentText?.string
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let url = UTType.url.identifier
        let text = UTType.plainText.identifier

        for provider in item.attachments ?? [] {
            if provider.hasItemConformingToTypeIdentifier(url) {
                provider.loadItem(forTypeIdentifier: url, options: nil) { [weak self] value, _ in
                    let link = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
                    self?.offer(heading: heading, link: link)
                }
                return
            }
            if provider.hasItemConformingToTypeIdentifier(text) {
                provider.loadItem(forTypeIdentifier: text, options: nil) { [weak self] value, _ in
                    self?.fill(value as? String ?? heading)
                }
                return
            }
        }

        fill(heading)
    }

    /// Title and link, both. The title is what triage reads to write a
    /// real task out of; the link is what lets its first step be "open
    /// this" rather than "find the site, then open it".
    private static func compose(heading: String?, link: URL?) -> String? {
        let name = (heading?.isEmpty == false) ? heading : nil
        switch (name, link) {
        case let (name?, link?): return "\(name) — \(link.absoluteString)"
        case let (name?, nil):   return name
        case let (nil, link?):   return link.absoluteString
        default:                 return nil
        }
    }

    /* The link, laid onto whatever the box says by the time it arrives.
       Read on the main thread and at that moment, not when the load began:
       loadItem answers whenever it answers, and by then the box may hold
       Safari's title, or the person may already have started typing in it.

       An empty box gets title and link, both, exactly as before. A box
       with words in it keeps them and gains " — link" — unless the link is
       in there already, which is what a share from an app that puts the
       address into its own text looks like, and doubling it would make the
       task's title half URL. */
    private func offer(heading: String?, link: URL?) {
        DispatchQueue.main.async {
            let typed = (self.textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let value: String?
            if typed.isEmpty {
                value = Self.compose(heading: heading, link: link)
            } else if let link, !Self.mentions(typed, link) {
                value = Self.compose(heading: typed, link: link)
            } else {
                value = nil
            }
            guard let value, !value.isEmpty else { return }
            self.textView.text = value
            self.validateContent()
        }
    }

    /// Already in the text, near enough: the address as given, or the same
    /// address without its trailing slash, which is how most apps that
    /// quote a link in their own text actually write it.
    private static func mentions(_ text: String, _ link: URL) -> Bool {
        let full = link.absoluteString
        let bare = full.hasSuffix("/") ? String(full.dropLast()) : full
        return text.contains(full) || (!bare.isEmpty && text.contains(bare))
    }

    /// Text that arrives on its own fills an EMPTY box and never replaces
    /// one with words in it — those words are either Safari's, already
    /// what this would have put there, or the person's own.
    private func fill(_ value: String?) {
        guard let value, !value.isEmpty else { return }
        DispatchQueue.main.async {
            let typed = (self.textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard typed.isEmpty else { return }
            self.textView.text = value
            self.validateContent()
        }
    }
}
