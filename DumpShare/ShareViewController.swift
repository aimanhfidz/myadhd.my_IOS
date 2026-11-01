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
   for none of the code. The sheet is titled the way the app's own box is
   (New dump) and the button says Add, because what it does is put the
   words in the dump box for the next time the app is open — Post was
   never this app's word.

   **A photo is words too.** Ink's assistant takes "a photo of an invite
   or a schedule"; here a shared photo or screenshot (up to four) is read
   on the phone with Vision, and its words land in the box to be checked
   before they go. Nothing leaves the device for this, and the photo is
   not kept. Each photo is ONE thought — its lines are joined with commas
   — because the sorter reads a line as a thought, and a poster read as
   five lines would come back as five tasks.
   ============================================================ */

import ImageIO
import Social
import UIKit
import UniformTypeIdentifiers
import Vision

final class ShareViewController: SLComposeServiceViewController {

    /* The attachments are always asked, including when the box already
       has words in it. There used to be a guard here that skipped the
       whole load whenever it did, on the theory that Safari had "filled it
       already" — but what Safari fills the box with is the page's TITLE,
       and the address arrives separately, as an attachment. So the one
       share this file was written around kept the title and dropped the
       link every time. What arrives now is added to the box rather than
       put over it: see offer(heading:link:) and fill(_:). */
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "New dump"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.navigationBar.topItem?.rightBarButtonItem?.title = "Add"
    }

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

        /* Photos only when photos are all there is: a screenshot or a
           poster arrives as an image and nothing else. A post shared with
           a link or words AND a preview image is about the link, and goes
           the way it always has. */
        let image = UTType.image.identifier
        let attachments = item.attachments ?? []
        let photos = attachments.filter { $0.hasItemConformingToTypeIdentifier(image) }
        let carriesWords = attachments.contains {
            !$0.hasItemConformingToTypeIdentifier(image)
                && ($0.hasItemConformingToTypeIdentifier(url) || $0.hasItemConformingToTypeIdentifier(text))
        }
        if !photos.isEmpty, !carriesWords {
            read(Array(photos.prefix(4)))
            return
        }

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

    // MARK: - reading a photo

    private static let oneAtATime = NSLock()

    private func read(_ photos: [NSItemProvider]) {
        placeholder = "Reading your photo…"
        let group = DispatchGroup()
        let lock = NSLock()
        var found = Array<String>(repeating: "", count: photos.count)

        for (i, provider) in photos.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { value, _ in
                defer { group.leave() }
                /* One photo at a time. The callbacks can arrive together,
                   and four decoded photos with four text readers running
                   is more than a share extension is allowed to hold. The
                   work stays inside the callback because a file URL handed
                   to it is only promised for as long as it runs. */
                Self.oneAtATime.lock()
                defer { Self.oneAtATime.unlock() }
                let words = autoreleasepool { () -> String in
                    guard let image = Self.image(from: value) else { return "" }
                    return Self.words(in: image)
                }
                lock.lock(); found[i] = words; lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let text = found.filter { !$0.isEmpty }.joined(separator: "\n")
            if text.isEmpty {
                self.placeholder = "No words in that photo. Say what it was about."
                return
            }
            let typed = (self.textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.textView.text = typed.isEmpty ? text : typed + "\n" + text
            self.validateContent()
        }
    }

    /// The shared image, shrunk on the way in: a 48MP photo decoded whole
    /// would not survive a share extension's memory limit, and 2400
    /// pixels on the long side is plenty to read a poster.
    private static func image(from value: Any?) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
        ]
        let source: CGImageSource?
        switch value {
        case let url as URL:   source = CGImageSourceCreateWithURL(url as CFURL, nil)
        case let data as Data: source = CGImageSourceCreateWithData(data as CFData, nil)
        case let image as UIImage: return image.cgImage
        default: return nil
        }
        guard let source else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The words, top to bottom, as one line. Language correction is off:
    /// it "fixes" Malay into English, and a kenduri is not a kendo.
    private static func words(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces)
        }
        return lines.filter { !$0.isEmpty }.joined(separator: ", ")
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
