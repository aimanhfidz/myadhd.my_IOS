/* ============================================================
   my.adhd for iOS — the one thing a web view cannot do

   Google refuses to run OAuth inside an embedded browser. A WKWebView
   pointed at accounts.google.com gets `disallowed_useragent` and a page
   telling the user to try a real browser, which is the end of the road
   for signing in — and signing in is what makes the lists follow you to
   another device and stops the calendar link expiring.

   ASWebAuthenticationSession is the sanctioned way through: it is Safari,
   so Google is satisfied, it shares Safari's cookies so an already
   signed-in Google needs no password, and it hands the redirect back to
   the app instead of stranding it in another browser.

   The one thing it will not do is catch an https redirect without an
   Associated Domains entitlement, which needs a paid developer account.
   So the redirect is pointed at myadhd://auth instead — rewritten here,
   on the way out, so auth.js never has to know. The tokens come back in
   the fragment exactly as they would have, and get handed to the page as
   a fresh load of /app#… which absorbRedirect() already knows how to read.

   Supabase will only redirect somewhere on its allow-list, so myadhd://auth
   has to be added there once. See the sign-in section of ios/README.md.
   ============================================================ */

import AuthenticationServices
import UIKit

final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {

    /// Held for the length of the flow; the system drops it otherwise.
    private var session: ASWebAuthenticationSession?

    /// `url` is the /auth/v1/authorize the page tried to navigate to.
    /// The callback carries the URL Supabase came back to, fragment intact,
    /// or nil if the user cancelled or it failed.
    func start(authorize url: URL, completion: @escaping (URL?) -> Void) {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            completion(nil)
            return
        }

        /* auth.js asks to come back to location.origin + pathname, which is
           an https page — fine in a browser, unreachable from here. */
        var items = parts.queryItems ?? []
        items.removeAll { $0.name == "redirect_to" }
        items.append(URLQueryItem(name: "redirect_to", value: AppConfig.callbackURL))
        parts.queryItems = items

        guard let rewritten = parts.url else {
            completion(nil)
            return
        }

        let flow = ASWebAuthenticationSession(
            url: rewritten,
            callbackURLScheme: AppConfig.callbackScheme
        ) { [weak self] callback, _ in
            self?.session = nil
            completion(callback)
        }

        flow.presentationContextProvider = self
        /* Not ephemeral: the whole point of going out to Safari is that the
           Google session already there means no password to type. */
        flow.prefersEphemeralWebBrowserSession = false
        session = flow
        flow.start()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
        for scene in scenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.activationState == .foregroundActive else { continue }
            if let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first {
                return window
            }
        }
        return ASPresentationAnchor()
    }
}
