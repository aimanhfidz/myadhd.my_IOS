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

    override func presentationAnimationDidFinish() {
        super.presentationAnimationDidFinish()
        guard contentText?.isEmpty ?? true else { return }   // Safari filled it already
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
                    self?.fill(Self.compose(heading: heading, link: link))
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

    private func fill(_ value: String?) {
        guard let value, !value.isEmpty else { return }
        DispatchQueue.main.async {
            self.textView.text = value
            self.validateContent()
        }
    }
}
