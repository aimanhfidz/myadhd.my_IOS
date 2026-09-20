/* ============================================================
   Checks/migration.swift — the existing user, brought across for real

   Not an Xcode target. A `swiftc` program that compiles the app's own
   `MyADHD/Bridge/LegacyImport.swift` — the file itself, not a copy of
   its logic — together with `MyADHD/Core`, and runs it against a REAL
   `WKWebView` on the REAL `https://myadhd.my` origin, with real
   `localStorage`, a real keychain and real files.

       Checks/migration.sh

   That is possible because `loadHTMLString("<html></html>", baseURL:
   "https://myadhd.my/app")` lands a document on that origin without
   fetching anything, and its `localStorage` is the origin's own,
   persisted by WebKit for this executable. Proven again at the top of
   every run: the check seeds keys through one web view and the import
   reads them through its own.

   `LegacyImport` compiles here because its UIKit — the hold pane and
   the line that parents the hidden view — is fenced behind
   `#if canImport(UIKit)`. Nothing the migration decides is inside that
   fence.

   **What this is for.** The migration is the one piece of the port that
   gets exactly one chance per person. If it reads wrong, somebody's
   lists are gone; if it decides wrong, somebody's app never opens. The
   two halves are checked separately:

   1. **The import itself** — tasks, notes, profile, theme, the calendar
      view, the cloud book's `user` and `graves`, the Google link, the
      Supabase session. And the assertion the whole cloud story hangs
      on: the sigs are **resealed from the native encoding**, not
      restamped. Restamping mints a fresh `updatedAt` for every row
      whose re-encoding differs — which is every row saved before
      `importance`, `skipped`, `gcal`, `local` or `doneAt` existed — and
      last-write-wins then pushes this phone's stale copy over a real
      edit made on another device yesterday. The check runs `stamp()`'s
      own comparison (`sigOf(task) != book.sigs[id]`) over every task
      after the import and requires it to move nothing at all.

   2. **The null-read guard, in both directions.** An empty read with a
      trace of the old install must NOT mark the migration done — it has
      to hold and retry. An empty read with NO trace MUST mark it done
      and open the ordinary empty app, or a fresh install hangs on a
      spinner with nothing to wait for.

      Which traces survive what is the whole of the second direction:

        App Store update   container kept    localStorage kept,
                                             UserDefaults kept,
                                             keychain kept
        delete + reinstall  container gone   localStorage GONE,
                                             UserDefaults GONE,
                                             keychain KEPT

      iOS does not delete keychain items when an app is deleted. So the
      keychain's `myadhd.task.snapshot` is a trace that outlives the
      data it was vouching for, and using it as a witness held a
      reinstalling person on `Bringing your lists over…` for ever behind
      a `Try again` that could not ever succeed. That is what the case
      named `the keychain alone is not a trace` is about, and it is why
      `LegacyImport.oldShellLeftTraces` now reads one witness and not
      two.

   **What this run touches, and puts back.** `UserDefaults` goes to a
   throwaway suite that is removed at the end. The store and the sidecars
   go to a temp directory. Two keychain items — `myadhd.task.snapshot`
   and `myadhd.auth.session` — are written and deleted, because both are
   what the code under test reads; on this Mac they land in the login
   keychain under this binary and nowhere near a phone. The six
   `localStorage` keys are cleared between cases and at the end. Nothing
   in the repo is written.
   ============================================================ */

import Foundation
import Security
import WebKit

// MARK: - the report

final class Report {
    private(set) var checks = 0
    private(set) var failures: [String] = []
    private var section = ""

    func open(_ name: String) {
        section = name
        print("\n  \(name)")
    }

    @discardableResult
    func equal(_ what: String, _ got: String, _ want: String) -> Bool {
        checks += 1
        if got == want {
            print("    ok    \(what)")
            return true
        }
        failures.append("\(section) / \(what)")
        print("    FAIL  \(what)")
        print("      want  \(want)")
        print("      got   \(got)")
        return false
    }

    @discardableResult
    func yes(_ what: String, _ value: Bool) -> Bool {
        equal(what, value ? "true" : "false", "true")
    }

    func note(_ line: String) { print("    ---   \(line)") }
}

// MARK: - the origin

/// A web view parked on `https://myadhd.my`, for putting keys into the
/// person's `localStorage` and reading them back out. The import builds
/// its own; this one only ever plays the part of the old shell.
@MainActor
final class Origin {

    private final class Nav: NSObject, WKNavigationDelegate {
        var loaded = false
        var failure: String?
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { loaded = true }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!,
                     withError e: Error) { failure = "\(e)"; loaded = true }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
            failure = "\(e)"; loaded = true
        }
    }

    private let web: WKWebView
    private let nav = Nav()

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = nav
        web.loadHTMLString("<html></html>", baseURL: LegacyImport.origin)
        pump(until: { self.nav.loaded }, seconds: 20)
    }

    var failure: String? { nav.failure }

    @discardableResult
    func eval(_ js: String) -> String {
        var out = "(no answer)"
        var done = false
        web.evaluateJavaScript(js) { value, error in
            if let error { out = "error: \(error.localizedDescription)" }
            else if let value = value as? String { out = value }
            else if value == nil || value is NSNull { out = "null" }
            else { out = String(describing: value!) }
            done = true
        }
        pump(until: { done }, seconds: 20)
        return out
    }

    /// The six keys the import reads, and nothing else on the origin.
    static let keys = ["myadhd.v1", "myadhd.cloud.v1", "myadhd.auth.v1",
                       "myadhd.gcal.v1", "myadhd.theme", "myadhd.ios.calView"]

    func clear() {
        for k in Self.keys { _ = eval("localStorage.removeItem('\(k)'); 'ok'") }
    }

    func put(_ key: String, _ value: String) {
        _ = eval("localStorage.setItem('\(key)', \(jsQuoted(value))); 'ok'")
    }

    func get(_ key: String) -> String {
        eval("String(localStorage.getItem('\(key)'))")
    }
}

/// A JavaScript string literal for an arbitrary Swift string. `WebJSON`
/// is the app's own writer and produces exactly this.
func jsQuoted(_ s: String) -> String { WebJSON.quoted(s) }

/// Spin the main run loop until `done` or the deadline. The import calls
/// back on the main actor, and a command-line tool has no one else to
/// run it.
@MainActor
func pump(until done: () -> Bool, seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done(), Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

// MARK: - the keychain, as the shell leaves it

enum Keychain {

    static func put(service: String, account: String, data: Data) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var item = q
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read(service: String, account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecMatchLimit as String: kSecMatchLimitOne,
                                kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func drop(service: String, account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - the store somebody actually has

enum Fixture {

    /// A store with the shapes that make the reseal matter: two rows
    /// written before `importance`, `quadrant`, `gcal`, `local`,
    /// `doneAt` and `skipped` existed, one modern row, a note, a legacy
    /// `{title, body}` note, a profile, `view: 'matrix'`, orphans,
    /// doneCounts, and a top-level key this build has never heard of.
    static let store = """
    {"tasks":[\
    {"id":"t_old0001","title":"pay the water bill","minutes":15,"energy":"low","urgency":4,\
    "firstStep":"Open the banking app.","category":"money","when":"2026-03-12","at":null,\
    "done":false,"updatedAt":1770000000000},\
    {"id":"t_old0002","title":"beli barang dapur","minutes":45,"energy":"medium","urgency":2,\
    "firstStep":"Buat senarai dulu.","category":"errand","when":null,"at":null,\
    "done":true,"updatedAt":1770000111000},\
    {"id":"t_new0003","title":"call the clinic 🏥","minutes":10,"energy":"medium","urgency":5,\
    "importance":"high","quadrant":"do","firstStep":"Find the number.","category":"health",\
    "when":"2026-03-11","at":"09:00","steps":["find the number","ring it"],"local":false,\
    "gcal":{"id":"ev_clinic","sig":"abc.120"},"done":false,"doneAt":null,"skipped":false,\
    "mystery":"from a newer web build","updatedAt":1770000222000}],\
    "notes":[\
    {"id":"n_note001","title":"Standup","body":"blocked on signing","blocks":[{"type":"p",\
    "text":"blocked on signing","marks":[],"done":false,"align":"left"}],"remindOn":null,\
    "remindAt":null,"repeat":"","files":[],"look":{"paper":"violet","font":"baloo"},\
    "createdAt":1769000000000,"updatedAt":1769000001000},\
    {"id":"n_note002","title":"Groceries","body":"milk\\nbread"}],\
    "profile":{"name":"Aiman","avatar":"🦊"},"sentFeedbackOn":"2026-03-01",\
    "signupOfferHidden":true,"view":"matrix","gcalOrphans":["ev_gone"],\
    "doneCounts":{"2026-03-01":3,"2026-03-02":1},"somethingNewer":{"keep":"me"}}
    """

    /// The cloud book as the PAGE wrote it: its own `sigOf` over its own
    /// encoding of those rows. The values here are deliberately not the
    /// ones this build computes — that is the point of the reseal.
    static let cloud = """
    {"user":"u_9f3c21","sigs":{"t_old0001":"pagesig1.180","t_old0002":"pagesig2.150",\
    "t_new0003":"pagesig3.300"},"graves":{"t_deleted01":1769500000000,\
    "t_deleted02":1769600000000}}
    """

    static let auth = """
    {"access_token":"eyJhbGciOi.notarealtoken","refresh_token":"r_abc123",\
    "expires_at":1770000900,"user":{"id":"u_9f3c21","email":"better4builder@gmail.com"}}
    """

    /// Four fields on the page; two of them are native-only from here —
    /// the token is an hour old at best and the email is a label.
    static let gcal = """
    {"connected":true,"calendarId":"cal_myadhd_9f3c","email":"better4builder@gmail.com",\
    "token":"ya29.stale"}
    """
}

// MARK: - one run of the import

@MainActor
final class Attempt {

    let dir: URL
    let suite: String
    let defaults: UserDefaults
    let file: StoreFile
    let store: AppStore
    let importer: LegacyImport
    private(set) var phase: LegacyImport.Phase = .idle

    init(now: Date = Date(timeIntervalSince1970: 1_773_077_400)) {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("myadhd-migration-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "my.adhd.migration-check.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite) ?? .standard
        file = StoreFile(directory: dir, clock: { now })
        store = AppStore(file: file, inShell: true, clock: { now })
        importer = LegacyImport(defaults: defaults, directory: dir)
    }

    /// Run it and wait for the phase it settles on.
    @discardableResult
    func run() -> LegacyImport.Phase {
        var landed: LegacyImport.Phase?
        importer.run(into: store) { landed = $0 }
        pump(until: { landed != nil }, seconds: 30)
        phase = landed ?? .reading
        file.flush()
        return phase
    }

    @discardableResult
    func retry() -> LegacyImport.Phase {
        var landed: LegacyImport.Phase?
        importer.retry()
        /* `retry()` re-runs with the same landing callback the first run
           was given, so the wait is on the phase settling rather than on
           a new closure. */
        pump(until: {
            if case .reading = self.importer.phase { return false }
            landed = self.importer.phase
            return true
        }, seconds: 30)
        phase = landed ?? .reading
        file.flush()
        return phase
    }

    var migrated: Bool { defaults.bool(forKey: LegacyImport.migratedKey) }
    var document: String? { try? String(contentsOf: file.documentURL, encoding: .utf8) }
    func sidecar(_ name: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    func clean() {
        file.flush()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }
}

/// `normalizeNote` gives a note with no `createdAt` the clock's answer
/// (app.js:4338-4339). The import reads that clock when it runs and this
/// check reads it when it builds what it expects, a few milliseconds
/// apart, so those two numbers can never be compared directly. They are
/// zeroed on both sides here — and the value itself is asserted where it
/// matters, as a stamp from this minute rather than a number out of
/// nowhere.
func maskMintedStamps(_ text: String) -> String {
    var doc = StoreDocument.load(text: text)
    let nowMS = Date().timeIntervalSince1970 * 1000
    for i in doc.notes.indices where abs(doc.notes[i].createdAt - nowMS) < 300_000 {
        doc.notes[i].createdAt = 0
        doc.notes[i].updatedAt = 0
    }
    return doc.jsonString
}

func describe(_ p: LegacyImport.Phase) -> String {
    switch p {
    case .idle: return "idle"
    case .reading: return "reading"
    case .done(let t, let n): return "done(tasks: \(t), notes: \(n))"
    case .holding: return "holding"
    }
}

func holdingReason(_ p: LegacyImport.Phase) -> String {
    if case .holding(let reason) = p { return reason }
    return "(not holding)"
}

// MARK: - the run

@main
struct MigrationChecks {

    static func main() {
        MainActor.assumeIsolated { go() }
    }

    @MainActor
    static func go() {
        let r = Report()
        print("migration")

        /* Nothing from a previous run, and nothing of anybody's left
           behind afterwards. */
        Keychain.drop(service: LegacyImport.snapshotService, account: LegacyImport.snapshotAccount)
        Keychain.drop(service: LegacyImport.authService, account: LegacyImport.authAccount)
        defer {
            Keychain.drop(service: LegacyImport.snapshotService,
                          account: LegacyImport.snapshotAccount)
            Keychain.drop(service: LegacyImport.authService, account: LegacyImport.authAccount)
        }

        let origin = Origin()
        if let failure = origin.failure {
            print("  the origin would not load: \(failure)")
            exit(2)
        }
        origin.clear()

        r.open("the origin is the person's own")
        r.equal("location.origin", origin.eval("location.origin"), "https://myadhd.my")
        origin.put("myadhd.probe", "round-trip")
        r.equal("a key written here reads back", origin.get("myadhd.probe"), "round-trip")
        _ = origin.eval("localStorage.removeItem('myadhd.probe'); 'ok'")
        r.note("no network: the document is the string <html></html> and nothing is fetched")

        theWholeStore(r, origin)
        resealedNotRestamped(r, origin)
        nothingIsWrittenBack(r, origin)
        thePreferencesThatAreAlreadySet(r, origin)
        aFreshInstall(r, origin)
        anEmptyReadWithATrace(r, origin)
        theKeychainAloneIsNotATrace(r, origin)
        nothingToDo(r, origin)

        origin.clear()

        print("\n---")
        if r.failures.isEmpty {
            print("migration OK — \(r.checks) checks, all passed")
            exit(0)
        }
        print("migration FAILED — \(r.failures.count) of \(r.checks) checks:")
        for f in r.failures { print("  - \(f)") }
        exit(1)
    }

    /// Everything the old shell had, on the far side of the update.
    @MainActor
    static func theWholeStore(_ r: Report, _ origin: Origin) {
        r.open("a whole store comes across")
        seedEverything(origin)
        Keychain.drop(service: LegacyImport.authService, account: LegacyImport.authAccount)

        let a = Attempt()
        defer { a.clean() }
        let phase = a.run()

        r.equal("the phase", describe(phase), "done(tasks: 3, notes: 2)")
        r.yes("the migration is marked done", a.migrated)

        /* The document is `load()`'s reading of the page's bytes — not a
           second opinion about them. Notes normalised, `view: 'matrix'`
           honoured because the native app IS the shell, unknown
           top-level key carried. */
        let expected = StoreDocument.load(text: Fixture.store, inShell: true).jsonString
        r.equal("the document is load()'s reading of it",
                maskMintedStamps(a.document ?? "(missing)"), maskMintedStamps(expected))

        /* The one number that cannot be compared that way, asserted for
           what it has to be: the legacy note had no `createdAt`, so
           `normalizeNote` minted one, and it has to be now. */
        let minted = StoreDocument.load(text: a.document ?? "{}").notes.last?.createdAt ?? 0
        let drift = abs(minted - Date().timeIntervalSince1970 * 1000)
        r.yes("the legacy note's minted createdAt is from this minute", drift < 60_000)

        let doc = StoreDocument.load(text: a.document ?? "{}")
        r.equal("three tasks", "\(doc.tasks.count)", "3")
        r.equal("two notes", "\(doc.notes.count)", "2")
        r.equal("the legacy note split into blocks",
                doc.notes.last.map { "\($0.blocks.count)" } ?? "?", "2")
        r.equal("the profile came with it", doc.profile.name + " " + doc.profile.avatar,
                "Aiman 🦊")
        r.equal("the matrix is honoured in the shell", doc.view, "matrix")
        r.equal("the feedback day came with it", doc.sentFeedbackOn ?? "nil", "2026-03-01")
        r.equal("the orphan list came with it", doc.gcalOrphans.joined(separator: ","), "ev_gone")
        r.equal("doneCounts came with it", WebJSON.encode(.object(doc.doneCounts)),
                "{\"2026-03-01\":3,\"2026-03-02\":1}")
        r.equal("the unknown top-level key survived",
                doc.extra["somethingNewer"].map { WebJSON.encode($0) } ?? "(dropped)",
                "{\"keep\":\"me\"}")
        r.equal("the unknown TASK key survived",
                doc.tasks.last?.raw("mystery").map { WebJSON.encode($0) } ?? "(dropped)",
                "\"from a newer web build\"")

        // The cloud book.
        let book = (try? JSONValue.parse(a.sidecar(LegacyImport.cloudFileName) ?? "{}"))?.objectValue
        r.equal("the account came across", book?["user"].map { WebJSON.encode($0) } ?? "(missing)",
                "\"u_9f3c21\"")
        r.equal("the graves came across verbatim",
                book?["graves"].map { WebJSON.encode($0) } ?? "(missing)",
                "{\"t_deleted01\":1769500000000,\"t_deleted02\":1769600000000}")
        r.equal("the book has a sig per task",
                "\(book?["sigs"]?.objectValue?.count ?? 0)", "3")

        // The Google link: two fields of the four.
        r.equal("the calendar link is trimmed to two fields",
                a.sidecar(LegacyImport.gcalFileName) ?? "(missing)",
                "{\"connected\":true,\"calendarId\":\"cal_myadhd_9f3c\"}")

        // The session.
        let session = Keychain.read(service: LegacyImport.authService,
                                    account: LegacyImport.authAccount)
        r.equal("the session went to the keychain as-is",
                session.map { String(decoding: $0, as: UTF8.self) } ?? "(missing)",
                Fixture.auth)
        r.equal("and not into UserDefaults",
                a.defaults.string(forKey: "myadhd.auth.v1") ?? "nil", "nil")

        // The two preferences.
        r.equal("the theme became the shell's ground",
                a.defaults.string(forKey: LegacyImport.groundKey) ?? "nil", "dark")
        r.equal("the calendar view became a native-only key",
                a.defaults.string(forKey: LegacyImport.calViewKey) ?? "nil", "week")

        r.yes("no corrupt file was made", a.file.quarantinedFiles().isEmpty)
    }

    /// The assertion the whole cloud story hangs on.
    ///
    /// `cloud.stamp()` walks the tasks and, for each one whose current
    /// `sigOf` differs from the sig the book has, writes a fresh
    /// `updatedAt` (cloud.js:363). Re-encoding a row that was saved
    /// before `importance`/`skipped`/`gcal`/`local`/`doneAt` existed
    /// legitimately changes its bytes — so if the book were copied
    /// across from the page, the first pass after the update would
    /// restamp those rows to NOW and push this phone's stale copy over a
    /// real edit made on another device yesterday.
    ///
    /// So: after the import, every row's `sigOf` must already equal the
    /// book's, and every `updatedAt` must be exactly the number the page
    /// had. That is `stamp()` moving nothing at all, which is what
    /// "zero spurious pushes" means in one process.
    @MainActor
    static func resealedNotRestamped(_ r: Report, _ origin: Origin) {
        r.open("the sigs are resealed from the native encoding, not restamped")
        seedEverything(origin)
        let a = Attempt()
        defer { a.clean() }
        _ = a.run()

        let doc = StoreDocument.load(text: a.document ?? "{}")
        guard let book = (try? JSONValue.parse(a.sidecar(LegacyImport.cloudFileName) ?? "{}"))?
                .objectValue, let sigs = book["sigs"]?.objectValue else {
            r.equal("the book was written", "no", "yes")
            return
        }

        var wouldRestamp: [String] = []
        var changedShape: [String] = []
        for t in doc.tasks {
            let mine = LegacyImport.sigOf(t)
            if sigs[t.id]?.stringValue != mine { wouldRestamp.append(t.id) }
        }
        r.equal("stamp() would restamp nothing", wouldRestamp.joined(separator: ","), "")

        /* And the sigs are genuinely NEW values — if they had been copied
           from the page this would be empty and the check above would be
           passing on nothing. */
        let pageSigs = (try? JSONValue.parse(Fixture.cloud))?.objectValue?["sigs"]?.objectValue
        for t in doc.tasks where pageSigs?[t.id]?.stringValue != sigs[t.id]?.stringValue {
            changedShape.append(t.id)
        }
        r.equal("and every one of them is a new seal, not the page's",
                changedShape.sorted().joined(separator: ","),
                "t_new0003,t_old0001,t_old0002")

        // Every updatedAt is the number the page had, to the millisecond.
        let before = StoreDocument.load(text: Fixture.store)
        let mine = doc.tasks.map { "\($0.id)=\($0.updatedAt.map(String.init) ?? "nil")" }
        let theirs = before.tasks.map { "\($0.id)=\($0.updatedAt.map(String.init) ?? "nil")" }
        r.equal("no updatedAt moved", mine.joined(separator: " "), theirs.joined(separator: " "))

        r.note("the three rows encode differently from the page's — two have no "
               + "importance/skipped/gcal/local/doneAt at all — which is exactly the "
               + "case a copied book would have restamped")
    }

    /// The file says it is read-only by inspection. This says it in
    /// bytes: every key is what it was, and nothing was removed.
    @MainActor
    static func nothingIsWrittenBack(_ r: Report, _ origin: Origin) {
        r.open("nothing is written back, and nothing is deleted")
        seedEverything(origin)
        let a = Attempt()
        defer { a.clean() }
        _ = a.run()

        r.equal("myadhd.v1", origin.get("myadhd.v1"), Fixture.store)
        r.equal("myadhd.cloud.v1", origin.get("myadhd.cloud.v1"), Fixture.cloud)
        r.equal("myadhd.auth.v1", origin.get("myadhd.auth.v1"), Fixture.auth)
        r.equal("myadhd.gcal.v1", origin.get("myadhd.gcal.v1"), Fixture.gcal)
        r.equal("myadhd.theme", origin.get("myadhd.theme"), "dark")
        r.equal("myadhd.ios.calView", origin.get("myadhd.ios.calView"), "week")
        r.note("the rollback is intact: a build that puts the web view back finds "
               + "every byte where it left it")
    }

    /// Already-set wins, because it was set by this device about this
    /// device.
    @MainActor
    static func thePreferencesThatAreAlreadySet(_ r: Report, _ origin: Origin) {
        r.open("a preference this device already has is not overwritten")
        seedEverything(origin)
        let a = Attempt()
        defer { a.clean() }
        a.defaults.set("light", forKey: LegacyImport.groundKey)
        a.defaults.set("day", forKey: LegacyImport.calViewKey)
        _ = a.run()

        r.equal("the ground stays as this device had it",
                a.defaults.string(forKey: LegacyImport.groundKey) ?? "nil", "light")
        r.equal("so does the calendar view",
                a.defaults.string(forKey: LegacyImport.calViewKey) ?? "nil", "day")
        r.equal("the store still came across", describe(a.phase), "done(tasks: 3, notes: 2)")
    }

    /// Direction one of the guard: an empty read that is telling the
    /// truth. A phone that has never had this app, and a phone that had
    /// it and deleted it, look identical from in here — and they should,
    /// because deleting the app took the container and every byte in it.
    @MainActor
    static func aFreshInstall(_ r: Report, _ origin: Origin) {
        r.open("an empty read with no trace is a fresh install")
        origin.clear()
        Keychain.drop(service: LegacyImport.snapshotService, account: LegacyImport.snapshotAccount)

        let a = Attempt()
        defer { a.clean() }
        let phase = a.run()

        r.equal("the phase", describe(phase), "done(tasks: 0, notes: 0)")
        r.yes("the migration IS marked done", a.migrated)
        r.yes("nobody is held on a spinner", { if case .holding = phase { return false }
                                               return true }())
        r.equal("no document was written over anything",
                a.document ?? "(none)", "(none)")
        r.equal("no cloud book was invented", a.sidecar(LegacyImport.cloudFileName) ?? "(none)",
                "(none)")
    }

    /// Direction two: an empty read that is lying. The store did not
    /// come back, but this install has run the old shell — so it holds,
    /// and it keeps holding until the read works.
    @MainActor
    static func anEmptyReadWithATrace(_ r: Report, _ origin: Origin) {
        r.open("an empty read with a trace holds, and retries until it works")
        origin.clear()

        let a = Attempt()
        defer { a.clean() }
        /* The stamp TaskBridge leaves in this container every time it
           writes a widget snapshot (TaskBridge.swift:43, 83). */
        a.defaults.set("a1b2c3d4e5f6", forKey: LegacyImport.snapshotStampKey)

        let first = a.run()
        r.equal("the phase", describe(first), "holding")
        r.equal("the reason names it", holdingReason(first),
                "the store read back empty, but this install has run the old app")
        r.equal("the migration is NOT marked done", a.migrated ? "marked" : "not marked",
                "not marked")
        r.equal("nothing was written", a.document ?? "(none)", "(none)")

        // Try again, still empty: still holding, still not marked.
        let second = a.retry()
        r.equal("a retry against the same nothing still holds", describe(second), "holding")
        r.equal("still not marked", a.migrated ? "marked" : "not marked", "not marked")

        // Now the read works — which is what a retry is for.
        seedEverything(origin)
        let third = a.retry()
        r.equal("the retry that finds the store brings it across",
                describe(third), "done(tasks: 3, notes: 2)")
        r.yes("and marks the migration done", a.migrated)
        r.equal("the document is there now",
                maskMintedStamps(a.document ?? "(missing)"),
                maskMintedStamps(StoreDocument.load(text: Fixture.store, inShell: true).jsonString))
    }

    /// The case that is a real person: they deleted the app and
    /// installed it again. The container went with it, so the store and
    /// the stamp are gone — but iOS keeps keychain items when an app is
    /// deleted, so the widget snapshot from the old install is still
    /// sitting there.
    ///
    /// While that item was a witness, this person's app opened on
    /// `Bringing your lists over…` with a `Try again` that could not
    /// ever succeed, on every launch, for ever.
    @MainActor
    static func theKeychainAloneIsNotATrace(_ r: Report, _ origin: Origin) {
        r.open("the keychain alone is not a trace (delete and reinstall)")
        origin.clear()
        Keychain.put(service: LegacyImport.snapshotService,
                     account: LegacyImport.snapshotAccount,
                     data: Data("a widget snapshot from the install before".utf8))
        defer {
            Keychain.drop(service: LegacyImport.snapshotService,
                          account: LegacyImport.snapshotAccount)
        }

        r.yes("the keychain item really is there", LegacyImport.keychainHasSnapshot())

        let a = Attempt()
        defer { a.clean() }
        r.equal("no stamp in this container",
                a.defaults.string(forKey: LegacyImport.snapshotStampKey) ?? "nil", "nil")
        r.equal("so it is not a trace", a.importer.oldShellLeftTraces ? "trace" : "no trace",
                "no trace")

        let phase = a.run()
        r.equal("the phase", describe(phase), "done(tasks: 0, notes: 0)")
        r.yes("the migration IS marked done", a.migrated)
        r.note("before the fix this was holding(reason:) for ever — the ghost of an "
               + "install whose data was deleted with it")

        /* And the other half of the same rule: on an UPGRADE both the
           keychain item and the stamp are there, and then it does hold. */
        let b = Attempt()
        defer { b.clean() }
        b.defaults.set("a1b2c3d4e5f6", forKey: LegacyImport.snapshotStampKey)
        let upgrade = b.run()
        r.equal("with the stamp as well, it holds", describe(upgrade), "holding")
        r.equal("and the keychain is in the reason, where it cannot decide anything",
                holdingReason(upgrade),
                "the store read back empty, but this install has run the old app"
                + " (a widget snapshot from an earlier install is in the keychain)")
    }

    /// `run()` is safe to call when there is nothing to do, and answers
    /// without building a web view.
    @MainActor
    static func nothingToDo(_ r: Report, _ origin: Origin) {
        r.open("there is nothing to do")
        seedEverything(origin)

        let a = Attempt()
        defer { a.clean() }
        a.defaults.set(true, forKey: LegacyImport.migratedKey)
        r.equal("already migrated", describe(a.run()), "idle")
        r.equal("and nothing was read", a.document ?? "(none)", "(none)")

        let b = Attempt()
        defer { b.clean() }
        b.store.persistOnly()
        b.file.flush()
        let before = b.document
        r.equal("a document already exists", describe(b.run()), "idle")
        r.equal("and it was not touched", b.document ?? "(missing)", before ?? "(missing)")
        r.equal("nor was the flag set", b.migrated ? "set" : "unset", "unset")
    }

    // MARK: - the seed

    @MainActor
    static func seedEverything(_ origin: Origin) {
        origin.clear()
        origin.put("myadhd.v1", Fixture.store)
        origin.put("myadhd.cloud.v1", Fixture.cloud)
        origin.put("myadhd.auth.v1", Fixture.auth)
        origin.put("myadhd.gcal.v1", Fixture.gcal)
        origin.put("myadhd.theme", "dark")
        origin.put("myadhd.ios.calView", "week")
    }
}
