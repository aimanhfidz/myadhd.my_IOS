/* ============================================================
   MyADHD/UI/ShareApp.swift — the one row that does not go anywhere

   `shareApp` (app.js:4108-4128), `#set-row-share` (app.html:812-819),
   inventory §1.11.

   The web has three ways down — `navigator.share`, then the clipboard,
   then a new window — because the share sheet is the newest of those
   APIs and the oldest browser that opens the app has none of them. On
   iOS 17 there is only the first: `UIActivityViewController` is always
   there, so the clipboard fallback and its `Link copied.` toast are
   unreachable here and are not carried. Nothing is lost — the sheet's
   own Copy action is the same thing, with the person choosing it.

   **A cancel is not an error.** `navigator.share` rejects with
   `AbortError` when somebody changes their mind and app.js says nothing
   about it; `UIActivityViewController` simply dismisses. Both are
   silence, which is the point.

   **The title, the text and the url are the web's exactly.** The title
   is what the sheet puts in a mail subject line, which is where
   `navigator.share`'s `title` ends up too.
   ============================================================ */

import UIKit

enum ShareApp {

    static let url = URL(string: Copy.Share.url)!

    /// Put the sheet up over whatever is on screen.
    ///
    /// It is presented from the topmost view controller rather than
    /// through a SwiftUI `.sheet`, because `UIActivityViewController`
    /// brings its own presentation and wrapping it in another one gives
    /// a sheet inside a sheet on a phone and a broken popover on a pad.
    @MainActor
    static func present() {
        guard let host = top() else { return }

        let items: [Any] = [Item(), url]
        let sheet = UIActivityViewController(activityItems: items,
                                             applicationActivities: nil)

        /* A popover needs somewhere to point on an iPad, and iOS raises
           rather than guessing. The middle of the presenter is the
           honest answer when the caller is a settings row we do not
           have the frame of. */
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = host.view
            pop.sourceRect = CGRect(x: host.view.bounds.midX,
                                    y: host.view.bounds.midY,
                                    width: 0, height: 0)
            pop.permittedArrowDirections = []
        }

        host.present(sheet, animated: true)
    }

    /// `{ title, text }`. A plain `String` in the items array would go
    /// into a mail with no subject; an item source can answer both.
    private final class Item: NSObject, UIActivityItemSource {

        func activityViewControllerPlaceholderItem(_ c: UIActivityViewController) -> Any {
            Copy.Share.text
        }

        func activityViewController(_ c: UIActivityViewController,
                                    itemForActivityType type: UIActivity.ActivityType?) -> Any?
        {
            Copy.Share.text
        }

        func activityViewController(_ c: UIActivityViewController,
                                    subjectForActivityType type: UIActivity.ActivityType?) -> String
        {
            Copy.Share.title
        }
    }

    /// The deepest thing currently presented on the active window, which
    /// is what a modal has to be presented from.
    @MainActor
    private static func top() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
              var vc = window.rootViewController
        else { return nil }

        while let next = vc.presentedViewController, !next.isBeingDismissed {
            vc = next
        }
        return vc
    }
}
