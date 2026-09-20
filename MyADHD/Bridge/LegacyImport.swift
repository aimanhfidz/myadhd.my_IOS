/* ============================================================
   MyADHD/Bridge/LegacyImport.swift — bringing the existing user across

   design.md §2.6. Everything a person has ever typed into this app is in
   `localStorage` on the `https://myadhd.my` origin, inside the WebKit
   data store the shell's web view used. The native app has to lift it
   out, once, on the first launch after the update — and it has to do that
   without a page load, without a network request and without ever asking
   anybody to sign in to read their own lists.

   **How it works.** A `WKWebView` on `WKWebsiteDataStore.default()` —
   the same store `WebScreen.swift:72` used — is given
   `loadHTMLString("<html></html>", baseURL: "https://myadhd.my/app")`.
   That document's origin IS `https://myadhd.my`, so its `localStorage`
   is the person's own, and nothing is fetched: the HTML is a string this
   file holds. The same bundle id keeps the container across the upgrade,
   which is what turns this into a read of their data rather than a
   request for their password. Proven on this machine before it was
   written: a second process reads a key the first one wrote, with the
   Wi-Fi off.

   **THE NULL-READ GUARD, which is the reason this file is careful.**
   `localStorage.getItem('myadhd.v1')` returning null is indistinguishable
   from a fresh install. Believe it, mark the migration done, and write an
   empty first snapshot, and somebody whose data is sitting intact in
   WebKit storage opens an empty app and watches every widget on their
   home screen go blank. So an empty read is corroborated before it is
   believed, against the one thing that exists if and only if the old
   shell ever ran **in this container**:

     UserDefaults  myadhd.snapshot.stamp   (TaskBridge.swift:43, 83)

   If it is there and the read came back null — or the evaluation errored,
   or never answered — the migration is NOT marked done. The app holds on
   `Bringing your lists over…` and tries again on the next launch, for
   ever if need be. A hold that a person can retry is recoverable; a blank
   list that says everything is fine is not.

   The guard has to be right in BOTH directions, and the second one is
   easier to get wrong: an empty read with no trace must mark the
   migration done and open the ordinary empty app, or a fresh install
   hangs on that pane with nothing to wait for. `oldShellLeftTraces` says
   why the keychain — which used to be the second witness, and which
   outlives the app it belongs to — cannot be part of this decision.

   **Nothing is written back and nothing is deleted.** Not a key, not a
   cookie, not the data store. It is the rollback: a build that puts the
   web view back finds every byte where it left it. It stays for at least
   two releases.

   **Why the sigs are resealed rather than stamped.** `myadhd.cloud.v1`
   holds, per task, a hash of what that task looked like when this device
   last pushed it. Re-encoding an old row through `TaskItem` adds the
   fields it was saved without — `importance`, `skipped`, `gcal`, `local`
   — so its hash legitimately differs from the one the page recorded. If
   the first cloud pass were allowed to notice that, `stamp()` would mint
   a fresh `updatedAt` for every such row, and last-write-wins would then
   push this phone's stale copy over a real edit made on another device
   yesterday (the flaw the data-integrity judge found in the tenant
   design). So the book is resealed here, from the native encoding, as if
   this device had always written them that way. `user` and `graves` come
   across untouched — a delete made in the old shell that never reached
   the server is still a delete.
   ============================================================ */

import Foundation
import Observation
import Security
import WebKit

/* The hold pane and the one line that parents the hidden web view are the
   only UIKit in this file. They are fenced so that `Checks/migration.swift`
   can compile THIS file — not a copy of it — for the Mac and run the real
   import against a real WKWebView on the real origin. Everything the
   migration actually decides is on the other side of the fence. */
#if canImport(UIKit)
import SwiftUI
import UIKit
#endif

@MainActor
@Observable
final class LegacyImport {

    // MARK: - Names

    /// Set only when the import has genuinely finished — which includes
    /// "there was nothing there and we are sure of it".
    static let migratedKey = "myadhd.native.migrated"

    /// The shell's own, already on this phone. Not overwritten if it is.
    static let groundKey = "myadhd.ground"

    /// `myadhd.ios.calView` on the web side; native-only from here.
    static let calViewKey = "myadhd.native.calView"

    /// The witness for an empty read: written in this container, by the
    /// old shell, every time it wrote a widget snapshot.
    static let snapshotStampKey = "myadhd.snapshot.stamp"

    /// The keychain item that used to be a second witness and is now only
    /// a line in a reason — see `oldShellLeftTraces`.
    static let snapshotService = "myadhd.task.snapshot"
    static let snapshotAccount = "current"

    /// Where the Supabase session lands (design §2.4). Not `myadhd.auth.v1`
    /// in UserDefaults: a refresh token does not belong in a plist.
    static let authService = "myadhd.auth.session"
    static let authAccount = "current"

    static let cloudFileName = "myadhd.cloud.v1.json"
    static let gcalFileName = "myadhd.gcal.v1.json"

    /// The origin whose `localStorage` is being read. The path matters as
    /// little as it does in a browser — origin is scheme, host and port —
    /// but it is `/app` because that is the page that wrote the keys.
    static let origin = URL(string: "https://myadhd.my/app")!

    /// A local document cannot really fail to load, but a web content
    /// process can be killed on a phone under memory pressure and then
    /// nothing ever calls back. A launch that hangs on a spinner is worse
    /// than one that says it is still trying.
    static let timeout: TimeInterval = 12

    /// The hold pane's line. Deliberately NOT in `Copy.swift`: every
    /// string in that file has to grep back to the web app, and the web
    /// app has never had a migration to name.
    static let holdCopy = "Bringing your lists over…"

    // MARK: - What the caller watches

    enum Phase: Equatable {
        /// Not started, or nothing to do — the normal launch.
        case idle
        /// The web view is up and the read is in flight.
        case reading
        /// It came across. `tasks` and `notes` are what landed, for a log.
        case done(tasks: Int, notes: Int)
        /// An empty or failed read that the witnesses contradict. Show
        /// `holdCopy`, offer `retry()`, and try again on every launch.
        case holding(reason: String)
    }

    private(set) var phase: Phase = .idle

    // MARK: - Shape

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var web: WKWebView?
    @ObservationIgnored private var driver: Driver?
    @ObservationIgnored private var timer: DispatchWorkItem?
    @ObservationIgnored private var finished = false
    @ObservationIgnored private var landing: ((Phase) -> Void)?
    @ObservationIgnored private weak var target: AppStore?

    init(defaults: UserDefaults = .standard,
         directory: URL = StoreFile.defaultDirectory())
    {
        self.defaults = defaults
        self.directory = directory
    }

    // MARK: - Is there anything to do

    /// True when the migration has not been marked done AND there is no
    /// document yet. Both halves matter: the flag alone would re-run for
    /// somebody who had cleared it, and the document alone would re-run on
    /// the launch after a person cleared all their tasks.
    func isNeeded(file: StoreFile) -> Bool {
        if defaults.bool(forKey: Self.migratedKey) { return false }
        return !FileManager.default.fileExists(atPath: file.documentURL.path)
    }

    /// The old shell left a trace here if it ever ran **in this
    /// container**. That qualification is the whole of the rule, and it
    /// is why there is one witness and not two.
    ///
    /// `myadhd.snapshot.stamp` is in `Library/Preferences`; the person's
    /// `localStorage` is in `Library/WebKit`. Both are inside the app
    /// container, so they live and die together — an App Store update
    /// keeps the container and keeps both, deleting the app takes the
    /// container and takes both. A stamp with no store therefore means
    /// one thing only: the read did not work. That is what a witness is
    /// for.
    ///
    /// **The keychain is not a witness, and used to be.** The item it
    /// corroborated with, `myadhd.task.snapshot`, is in the shared access
    /// group — outside the container — and iOS keeps keychain items when
    /// an app is deleted. So on a delete-and-reinstall, which is a thing
    /// people do and the one case where an empty store is the honest
    /// answer, the ghost of the old install contradicts a perfectly good
    /// empty read: the migration is never marked done, and the app opens
    /// on `Bringing your lists over…` behind a `Try again` that cannot
    /// ever succeed. Every launch. For ever. A witness that outlives the
    /// thing it vouches for is not a witness.
    ///
    /// It is still read, by `keychainNote`, into the reason line of a
    /// hold that something else has already decided — on an upgrade it
    /// says something true, and a support case is easier with it than
    /// without. It just cannot decide anything any more.
    var oldShellLeftTraces: Bool {
        defaults.string(forKey: Self.snapshotStampKey) != nil
    }

    /// What the keychain has to add, once the decision is made without it.
    var keychainNote: String {
        Self.keychainHasSnapshot()
            ? " (a widget snapshot from an earlier install is in the keychain)"
            : ""
    }

    /// Existence only — the data is not returned and not decoded. A blob
    /// that will not decode is still evidence that the shell ran.
    static func keychainHasSnapshot() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: snapshotService,
            kSecAttrAccount as String: snapshotAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
    }

    // MARK: - The run

    /// Reads the old store and, if it is there, brings it across into
    /// `store`. Calls back on the main actor with the phase it settled on.
    ///
    /// Safe to call when there is nothing to do: it answers `.idle`
    /// immediately without building a web view.
    func run(into store: AppStore, then done: ((Phase) -> Void)? = nil) {
        guard isNeeded(file: store.file) else {
            phase = .idle
            done?(.idle)
            return
        }
        guard web == nil else { return }   // already in flight

        target = store
        landing = done
        finished = false
        phase = .reading

        let config = WKWebViewConfiguration()
        /* The store the shell used. Not a fresh non-persistent one — that
           would be an empty origin, which is the whole point of not using
           it. */
        config.websiteDataStore = .default()

        let view = WKWebView(frame: .zero, configuration: config)
        view.isHidden = true
        #if canImport(UIKit)
        view.isUserInteractionEnabled = false
        #endif
        let driver = Driver(owner: self)
        view.navigationDelegate = driver

        /* Attached so the web content process is given a normal lifetime.
           A view in no hierarchy does load a local string, but a phone
           under pressure is quicker to reclaim one that is on screen
           nowhere; zero by zero and hidden, it costs nothing. */
        #if canImport(UIKit)
        if let host = Self.hostWindow() { host.addSubview(view) }
        #endif

        self.web = view
        self.driver = driver

        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.settle(read: nil, failed: "the read did not answer")
            }
        }
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: timer)

        view.loadHTMLString("<html></html>", baseURL: Self.origin)
    }

    /// The hold pane's button. Same run, from the top.
    func retry() {
        guard let store = target else { return }
        teardown()
        run(into: store, then: landing)
    }

    #if canImport(UIKit)
    private static func hostWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
    #endif

    // MARK: - The one script

    /* Six reads and nothing else. No write, no removeItem, no clear — this
       function is the whole of this app's contact with somebody's WebKit
       storage, and it is read-only by inspection.

       Each read is wrapped on its own: `localStorage` itself can throw
       when a data store is unavailable, and one key throwing must not
       cost the other five. If ALL of them throw, the result is six nulls,
       which is exactly the case the null-read guard is for. */
    static let readScript = """
    (function () {
      function g(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
      return {
        store:   g('myadhd.v1'),
        cloud:   g('myadhd.cloud.v1'),
        auth:    g('myadhd.auth.v1'),
        gcal:    g('myadhd.gcal.v1'),
        theme:   g('myadhd.theme'),
        calView: g('myadhd.ios.calView'),
        origin:  location.origin
      };
    })()
    """

    fileprivate func documentLoaded() {
        guard let web, !finished else { return }
        web.evaluateJavaScript(Self.readScript) { [weak self] value, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    self.settle(read: nil, failed: "the read failed: \(error.localizedDescription)")
                    return
                }
                self.settle(read: value as? [String: Any], failed: nil)
            }
        }
    }

    fileprivate func documentFailed(_ error: Error) {
        settle(read: nil, failed: "the document did not load: \(error.localizedDescription)")
    }

    // MARK: - Deciding what happened

    private func settle(read: [String: Any]?, failed: String?) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil

        let raw = read?["store"] as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let trimmed, !trimmed.isEmpty {
            let landed = bring(across: read ?? [:], store: trimmed)
            defaults.set(true, forKey: Self.migratedKey)
            conclude(.done(tasks: landed.tasks, notes: landed.notes))
            return
        }

        /* Nothing came back. Either this is a fresh install — including a
           reinstall, where the container went with the app and an empty
           store is the honest answer — or it is somebody's whole life
           behind a read that did not work. The witness decides, and when
           it disagrees with the read the answer is always "try again",
           never "start empty". */
        if oldShellLeftTraces {
            conclude(.holding(reason: (failed ?? "the store read back empty, but this "
                                       + "install has run the old app") + keychainNote))
            return
        }
        if let failed {
            conclude(.holding(reason: failed))
            return
        }

        /* A first launch with nothing to bring over: no store, no stamp,
           and a read that worked. A never-installed-before phone and a
           reinstall look identical here, and they should — the container
           is gone either way, and holding a person on a spinner over data
           that no longer exists helps nobody. This is the only path that
           marks the migration done on an empty read, and it is the only
           one that can afford to. */
        defaults.set(true, forKey: Self.migratedKey)
        conclude(.done(tasks: 0, notes: 0))
    }

    private func conclude(_ next: Phase) {
        teardown()
        phase = next
        landing?(next)
    }

    private func teardown() {
        timer?.cancel()
        timer = nil
        web?.navigationDelegate = nil
        web?.removeFromSuperview()
        web = nil
        driver = nil
        /* `finished` is NOT reset here. A late callback — an
           evaluateJavaScript that answers after the timeout already
           settled — must find the door shut. `run()` opens it again. */
    }

    // MARK: - The import itself

    @discardableResult
    private func bring(across read: [String: Any], store raw: String) -> (tasks: Int, notes: Int) {
        /* `load()`'s own rules, not a second opinion about them:
           Object.assign semantics, profile defaults, notes normalised, the
           `view` rule, legacy `energy` deleted. `inShell: true` because the
           native app IS the shell — a saved 'matrix' is honoured. */
        let doc = StoreDocument.load(text: raw, inShell: true)

        target?.adopt(doc)
        /* `persistOnly()`, never `save()`. `save()` would stamp for the
           cloud, and stamping is the one thing this must not do — see the
           header. */
        target?.persistOnly()

        writeCloudBook(read["cloud"] as? String, resealing: doc.tasks)
        writeAuthSession(read["auth"] as? String)
        writeGCalLink(read["gcal"] as? String)
        adoptTheme(read["theme"] as? String)
        adoptCalView(read["calView"] as? String)

        return (doc.tasks.count, doc.notes.count)
    }

    // MARK: - The cloud book

    private func writeCloudBook(_ raw: String?, resealing tasks: [TaskItem]) {
        var user: JSONValue = .null
        var graves = JSONObject()

        if let raw, let parsed = try? JSONValue.parse(raw), let book = parsed.objectValue {
            if let u = book["user"] { user = u }
            if let g = book["graves"]?.objectValue { graves = g }
        }

        /* Resealed, never copied: the recorded sig was taken over the
           page's encoding of a row, and this device now encodes that row
           through `TaskItem`. Writing the old hash down would make the
           first pass see a change that is not one. */
        var sigs = JSONObject()
        for t in tasks {
            sigs.set(t.id, .string(Self.sigOf(t)))
        }

        var book = JSONObject()
        book.set("user", user)
        book.set("sigs", .object(sigs))
        book.set("graves", .object(graves))

        write(WebJSON.encode(.object(book)), to: Self.cloudFileName)
    }

    /// `sigOf` from cloud.js:102-112, in Swift: FNV-1a 32 over the task's
    /// JSON with `updatedAt` removed by the replacer, rendered
    /// `h.toString(36) + '.' + s.length`.
    ///
    /// `s.length` is UTF-16 code units and `charCodeAt` walks the same, so
    /// both loops below are over `utf16` and not over `Character`s.
    static func sigOf(_ t: TaskItem) -> String {
        var fields = t.encoded()
        fields.removeValue(forKey: "updatedAt")
        let s = WebJSON.encode(.object(fields))

        var h: UInt32 = 0x811c_9dc5
        for unit in s.utf16 {
            h ^= UInt32(unit)
            /* The web writes the multiply out as shifts and adds and
               masks it back to 32 bits with >>> 0. `&+` and `&<<` are the
               same arithmetic without the mask, because UInt32 already
               wraps. */
            h = h &+ ((h &<< 1) &+ (h &<< 4) &+ (h &<< 7) &+ (h &<< 8) &+ (h &<< 24))
        }
        return String(h, radix: 36) + "." + String(s.utf16.count)
    }

    // MARK: - The session

    /// As-is, expired or not. A dead session refreshes or is dropped by
    /// the sign-in code's own rule; throwing it away here would sign
    /// somebody out for having taken an update on a plane.
    private func writeAuthSession(_ raw: String?) {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.authService,
            kSecAttrAccount as String: Self.authAccount,
        ]
        let fields: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updated = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
        guard updated == errSecItemNotFound else { return }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    // MARK: - The calendar link

    /// Two fields of the four. `email` is a label the settings card can
    /// ask for again, and `token` is an hour old at best and memory-only
    /// from here (design §2.4).
    private func writeGCalLink(_ raw: String?) {
        guard let raw, let parsed = try? JSONValue.parse(raw), let link = parsed.objectValue
        else { return }

        var out = JSONObject()
        out.set("connected", .bool(link["connected"]?.isTruthy ?? false))
        out.set("calendarId", link["calendarId"] ?? .null)
        write(WebJSON.encode(.object(out)), to: Self.gcalFileName)
    }

    // MARK: - The two preferences

    /// `myadhd.theme` becomes the shell's `myadhd.ground`, which may
    /// already be right: the old shell was told the theme by the injected
    /// bridge on every load. Already set wins, because it was set by this
    /// device about this device.
    private func adoptTheme(_ raw: String?) {
        guard defaults.string(forKey: Self.groundKey) == nil else { return }
        guard let raw, raw == "light" || raw == "dark" else { return }
        defaults.set(raw, forKey: Self.groundKey)
    }

    /// The calendar's List / Day / Week / Month pill, which only ever
    /// existed inside the shell (BridgeScript.swift:821).
    private func adoptCalView(_ raw: String?) {
        guard let raw, !raw.isEmpty else { return }
        guard defaults.string(forKey: Self.calViewKey) == nil else { return }
        defaults.set(raw, forKey: Self.calViewKey)
    }

    // MARK: - Sidecars on disk

    /// Beside the document, with the document's file protection. Written
    /// through a temp file and a replace so a crash costs the write rather
    /// than the file.
    private func write(_ text: String, to name: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])

        let url = directory.appendingPathComponent(name)
        let temp = directory.appendingPathComponent(name + ".tmp")
        do {
            try Data(text.utf8).write(to: temp, options: [.atomic])
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                 ofItemAtPath: temp.path)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.moveItem(at: temp, to: url)
        } catch {
            try? fm.removeItem(at: temp)
        }
    }

    // MARK: - The navigation delegate

    /// Its own object because `WKNavigationDelegate` is an `NSObject`
    /// protocol and `LegacyImport` is an `@Observable` class. It holds the
    /// owner weakly; the owner holds it strongly, which is the lifetime
    /// the web view needs.
    private final class Driver: NSObject, WKNavigationDelegate {
        private weak var owner: LegacyImport?
        init(owner: LegacyImport) { self.owner = owner }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { owner?.documentLoaded() }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            MainActor.assumeIsolated { owner?.documentFailed(error) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated { owner?.documentFailed(error) }
        }

        /* Nothing is allowed off this host, and nothing should try: the
           document is `<html></html>` and has no way to navigate. Belt and
           braces around the promise that no network is involved — and
           deliberately loose about the path, because cancelling the one
           navigation this thing makes would hold every migration on the
           retry pane for ever. */
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            let allowed = url == nil
                || url?.scheme == "about"
                || url?.host == LegacyImport.origin.host
            decisionHandler(allowed ? .allow : .cancel)
        }
    }
}

// MARK: - The hold pane

#if canImport(UIKit)
/// What a person sees while the import is being retried, and the only
/// screen in the app that can appear before their lists do.
///
/// Deliberately plain: it is drawn before the native theme exists, on the
/// ground the shell remembered, and it says the one true thing. The retry
/// is there because a hold is recoverable and a person who can see a
/// button knows it is.
struct LegacyImportHoldView: View {

    let reason: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .progressViewStyle(.circular)
            Text(LegacyImport.holdCopy)
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(reason)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: retry) {
                Text("Try again")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .tint(Color(AppConfig.accent))
            .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(ShellState.rememberedTheme == "dark"
                          ? AppConfig.darkGround : AppConfig.lightGround))
    }
}
#endif
