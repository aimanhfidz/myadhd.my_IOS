/* ============================================================
   my.adhd for iOS — the web view, and everything decided around it

   The rules, in one place:

     our own pages          stay here
     anybody else's         go to a Safari sheet, where there is an address
                            bar and the user can see whose form they are in
     Supabase's /authorize  goes to GoogleSignIn, because Google will not
                            run OAuth in an embedded browser
     mailto:, tel:          go to whichever app owns them

   The web view is transparent and ignores the safe area. Both are
   deliberate: styles.css already pads for env(safe-area-inset-*) on every
   screen, so letting iOS inset the view as well would pad it twice, and
   painting the shell's ground behind a transparent page is what keeps the
   notch and the home-bar strip the same colour as the page above them.
   ============================================================ */

import SafariServices
import SwiftUI
import WebKit

extension Notification.Name {
    /// A myadhd:// link, or the Shortcut, arriving from the app entry point.
    static let myadhdOpen = Notification.Name("myadhd.open")
    /// The retry button on the offline screen.
    static let myadhdReload = Notification.Name("myadhd.reload")
}

struct WebScreen: UIViewRepresentable {

    @ObservedObject var state: ShellState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeUIView(context: Context) -> WKWebView { context.coordinator.web }

    /* Nothing to push down. Everything that changes the page arrives as a
       notification or a script message, not as a SwiftUI state change. */
    func updateUIView(_ webView: WKWebView, context: Context) {}
}

// MARK: -

final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    let web: WKWebView
    private let state: ShellState
    private let signIn = GoogleSignIn()

    /// Text from a Shortcut or a myadhd://dump link, waiting for the page it
    /// goes in. Held rather than typed straight in because a fresh load of
    /// /app is what guarantees the dump box is the box on screen.
    private var pendingDump: String?

    /// The store is written on nearly every interaction, so the rebuild it
    /// triggers waits for the typing to stop.
    private var storeSettle: DispatchWorkItem?

    init(state: ShellState) {
        self.state = state

        let content = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        /* The default store, explicitly: localStorage is where every task
           lives, so this is the app's database and it has to survive a
           relaunch. */
        configuration.websiteDataStore = .default()
        /* Appended to Safari's user agent rather than replacing it — the web
           app should still look like the browser it was built for. */
        configuration.applicationNameForUserAgent = AppConfig.userAgentSuffix
        configuration.allowsInlineMediaPlayback = true
        /* The two waits are mp4s of the logo morphing. They have to start
           themselves or they are a black rectangle. */
        configuration.mediaTypesRequiringUserActionForPlayback = []

        web = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        content.add(self, name: "native")
        content.addUserScript(WKUserScript(source: BridgeScript.atStart,
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: BridgeScript.atEnd,
                                           injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: true))

        web.navigationDelegate = self
        web.uiDelegate = self
        /* An SPA with its own back affordances; a swipe back here leaves the
           screen the user is looking at for no reason they asked for. */
        web.allowsBackForwardNavigationGestures = false
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        /* body is overflow:hidden and #app does the scrolling, so this view
           has nothing to scroll — without this it still rubber-bands. */
        web.scrollView.bounces = false

        #if DEBUG
        web.isInspectable = true   // Safari > Develop > iPhone, on device
        #endif

        /* A Shortcut can fire, and the share sheet can be used, while the app
           is not running — in which case the thought was written down before
           this object existed. */
        pendingDump = Self.waiting()

        listen()
        web.load(URLRequest(url: AppConfig.home))
    }

    /* The content controller holds this object and this object holds the web
       view that holds the controller. One cycle, one web view, alive for as
       long as the app is — cheaper to say so than to thread a weak proxy
       through it. */

    // MARK: - what the page says to us

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let envelope = message.body as? [String: Any],
              let name = envelope["name"] as? String else { return }
        let body = envelope["body"] as? [String: Any] ?? [:]

        switch name {
        case "haptic":
            Haptics.play(body["kind"] as? String ?? "light")
        case "theme":
            state.remember(theme: body["theme"] as? String ?? "light")
        case "share":
            share(body["text"] as? String ?? "")
        case "store":
            reminderSyncSoon()
        case "ready":
            pageReady()
        default:
            break
        }
    }

    private func pageReady() {
        state.painted = true
        state.offline = false
        Haptics.warm()

        if let text = pendingDump {
            pendingDump = nil
            web.evaluateJavaScript(BridgeScript.fillDumpBox(with: text), completionHandler: nil)
        }

        Reminders.sync(from: web)
    }

    /// Called every time the page writes its store. Ticking a task off writes
    /// it, and so does every keystroke that lands in a draft, so this coalesces
    /// a burst into one rebuild rather than one per save.
    private func reminderSyncSoon() {
        storeSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Reminders.sync(from: self.web)
        }
        storeSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - where a tap is allowed to go

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        /* An iframe is the page's own business — gcal.js uses one against
           Google to read a session cookie, and cancelling that would break a
           feature to enforce a rule about links. */
        let targetFrame = navigationAction.targetFrame
        if let targetFrame, !targetFrame.isMainFrame {
            decisionHandler(.allow)
            return
        }

        /* Supabase's front door to Google. Cancel it here and run it in
           Safari instead — see GoogleSignIn.swift for why. */
        if url.path == AppConfig.authorizePath {
            decisionHandler(.cancel)
            startSignIn(url)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            decisionHandler(.cancel)
            UIApplication.shared.open(url)    // mailto:, tel:, whatever else
            return
        }

        /* target="_blank". There is no second window to open it in, so it
           either continues here or leaves. */
        if targetFrame == nil {
            decisionHandler(.cancel)
            if isOurs(url) { webView.load(URLRequest(url: url)) } else { openOutside(url) }
            return
        }

        if isOurs(url) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            openOutside(url)
        }
    }

    /// The backstop for a window.open the policy handler let through.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { openOutside(url) }
        return nil
    }

    private func isOurs(_ url: URL) -> Bool {
        AppConfig.ownHosts.contains(url.host?.lowercased() ?? "")
    }

    // MARK: - the microphone

    /// hold-to-talk. Granting here is only half of it: iOS still puts up its
    /// own microphone prompt the first time, which is what
    /// NSMicrophoneUsageDescription in Info.plist is for.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let host = origin.host.lowercased()
        decisionHandler(AppConfig.ownHosts.contains(host) ? .grant : .deny)
    }

    // MARK: - loading, and failing to

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        state.painted = true
        state.offline = false
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        showFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure(error)
    }

    private func showFailure(_ error: Error) {
        /* A cancelled navigation is every link we sent to Safari on purpose,
           and is not a failure of anything. */
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled { return }

        /* Only when there is nothing on screen. A dropped signal halfway
           through a session should not throw away the page the user is
           already reading — the service worker will serve it from cache. */
        guard web.url == nil || !state.painted else { return }
        state.offline = true
        state.painted = true
    }

    /// WebKit kills the content process under memory pressure, which leaves a
    /// blank white view and no error. Reloading is the whole fix.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: - signing in

    private func startSignIn(_ url: URL) {
        signIn.start(authorize: url) { [weak self] callback in
            guard let self else { return }

            /* Kept percent-encoded so nothing is re-escaped on the way back
               into the page. */
            let fragment = callback.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedFragment
            }

            guard let fragment, !fragment.isEmpty else {
                /* Cancelled, or came back with nothing. The page still has a
                   disabled button on it reading "Taking you to Google…", and
                   app.js has no code to put that right — it never expected to
                   still be here. Only a reload will. */
                self.web.reload()
                return
            }

            self.web.evaluateJavaScript(BridgeScript.absorb(fragment: fragment)) { _, error in
                guard error != nil else { return }
                /* No page to hand them to. Land on one carrying the fragment
                   instead, which boots and absorbs them the ordinary way. */
                var parts = URLComponents(url: AppConfig.home, resolvingAgainstBaseURL: false)
                parts?.percentEncodedFragment = fragment
                if let landing = parts?.url { self.web.load(URLRequest(url: landing)) }
            }
        }
    }

    // MARK: - links, sheets and the share card

    private func openOutside(_ url: URL) {
        guard url.scheme == "http" || url.scheme == "https" else {
            UIApplication.shared.open(url)
            return
        }
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = AppConfig.darkGround
        present(safari)
    }

    private func share(_ text: String) {
        guard !text.isEmpty else { return }
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = web
            popover.sourceRect = CGRect(x: web.bounds.midX, y: web.bounds.maxY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(sheet)
    }

    private func present(_ controller: UIViewController) {
        guard var top = keyWindow()?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        top.present(controller, animated: true)
    }

    private func keyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.activationState == .foregroundActive else { continue }
            if let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first {
                return window
            }
        }
        return nil
    }

    // MARK: - the outside world

    private func listen() {
        let centre = NotificationCenter.default
        centre.addObserver(self, selector: #selector(opened(_:)),
                           name: .myadhdOpen, object: nil)
        centre.addObserver(self, selector: #selector(retry),
                           name: .myadhdReload, object: nil)
        /* Not didEnterBackground: by then the page may already be suspended
           and the read of localStorage never comes back. */
        centre.addObserver(self, selector: #selector(leaving),
                           name: UIApplication.willResignActiveNotification, object: nil)
        /* Coming back matters too: the lists may have been changed on another
           device and pulled down by cloud.js while this copy was away. Before
           the first load this reads nothing and changes nothing — see the
           guard at the top of Reminders.sync. */
        centre.addObserver(self, selector: #selector(returning),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func returning() {
        /* Only when there is something: dump() reloads the page to land on
           the box, and doing that on every return to the foreground would
           throw away the screen the user was looking at. */
        if let text = Self.waiting() { dump(text) }
        Reminders.sync(from: web)
    }

    /// Everything queued up elsewhere while this was not the front app: a
    /// thought from a Shortcut, and whatever the share extension left in the
    /// keychain. Separate lines, because splitDump() in app.js reads a line
    /// as a thought — so three things shared before you next opened the app
    /// stay three things.
    private static func waiting() -> String? {
        let parts = [Inbox.take(), DumpQueue.drainedText()].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    @objc private func opened(_ note: Notification) {
        guard let text = note.object as? String else { return }
        dump(text)
    }

    /// Loads /app and fills the box once it is up. A fresh load always lands
    /// on the dump screen, which is what makes this two lines instead of a
    /// conversation with the app's router.
    func dump(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Inbox.take()          // arrived live; it must not arrive again on relaunch
        pendingDump = trimmed
        web.load(URLRequest(url: AppConfig.home))
    }

    @objc private func retry() {
        state.offline = false
        web.load(URLRequest(url: AppConfig.home))
    }

    @objc private func leaving() {
        storeSettle?.cancel()      // no point waiting out a debounce we are leaving
        Reminders.sync(from: web)
    }
}
