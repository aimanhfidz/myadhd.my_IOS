/* ============================================================
   Checks/cloud.swift — the sync, against the real cloud.js

   Not an Xcode target. A `swiftc` program that compiles the app target's
   own `MyADHD/Core`, `MyADHD/Sync` and `MyADHD/Bridge` sources and holds
   them against the REAL `cloud.js` running in JavaScriptCore.

       Checks/cloud.sh

   This is the most data-sensitive file in the port. A rule ported
   slightly wrong here does not fail a build, does not go red in a test
   and does not draw anything odd on a screen — it deletes somebody's task
   on their other phone, or resurrects one they threw away, weeks later.
   So every rule below is **cut out of `cloud.js` by content** and run, and
   nothing is retyped or paraphrased for comparison.

   Seven sections:

   1. **`sigOf`, byte for byte**, over 220 task fixtures — unicode titles,
      emoji that straddle surrogate pairs, quotes and backslashes, control
      characters, null fields, `gcal` refs, unknown keys, and rows with
      and without `updatedAt`. `s.length` is UTF-16 code units and so is
      `charCodeAt`, which is the one way a Swift port of this function
      gets it wrong.

   2. **The two copies of `sigOf` agree.** `LegacyImport` has its own
      (LegacyImport.swift:464) because the migration launch reseals the
      book before anything in `MyADHD/Sync` is alive. If those two ever
      disagree, the first pass after an upgrade restamps every row and
      pushes this phone's stale copy over another device's real edit —
      the exact failure the reseal exists to prevent. Nothing but this
      assertion stops them drifting.

   3. **`stamp`**, over 9 cases: the sig unchanged, the sig moved, a row
      with no timestamp at all, two saves inside one millisecond, an id
      that disappeared, a grave that expired, and a grave revived by an
      undo.

   4. **`merge` and `outbound`, replayed** over 48 row-and-local
      combinations. Remote-deleted on `<=` and on `>`; an arrival with a
      grave, without one, and with a grave exactly equal to the row;
      in-place replacement on strict `>` and the refusal on `==`; a
      tombstone pushed, and one skipped because the server already has
      it; an unknown payload key carried through untouched.

   5. **The wire**, through a `URLProtocol` stub: the exact PostgREST
      paths, the `apikey` + `Bearer` pair, `Prefer:
      resolution=merge-duplicates,return=minimal`, an ARRAY body, and the
      assertion that the pull never sends a `user_id` filter while every
      pushed row carries one.

   6. **The microsecond test.** PostgREST renders `updated_at` with six
      fractional digits; `Date.parse` keeps three and **truncates**. One
      millisecond of drift flips last-write-wins on a tie, and a tie is
      what two devices saving together make.

   7. **The liveness rule**, which is the one thing here that is NOT a
      port: a transport failure and a 5xx keep the session, and only a 4xx
      from `/auth/v1/token` ends it. auth.js drops it in every one of
      those cases, which signs somebody out on a train.

   `Date` is pinned on both sides to one instant, and the native clock is
   injected with the same one. Nothing here touches the network, the
   login keychain or the repo.
   ============================================================ */

import Foundation
import JavaScriptCore

// MARK: - cutting cloud.js

/// One extracted run of `cloud.js`, and what has to be in it. Cut by
/// content, so a rename or a move fails the run by name rather than
/// silently sliding onto whatever moved into a line range.
struct Cut {
    var name: String
    var from: String
    var to: String
    var mustContain: [String] = []
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

enum Extract {

    static func lines(of path: String) throws -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw Failure("cannot read \(path)")
        }
        return text.components(separatedBy: "\n")
    }

    static func index(_ lines: [String], containing needle: String, from: Int = 0) -> Int? {
        for i in from..<lines.count where lines[i].contains(needle) { return i }
        return nil
    }

    static func cut(_ lines: [String], _ c: Cut) throws -> String {
        guard let start = index(lines, containing: c.from) else {
            throw Failure("cloud.js no longer has a line containing `\(c.from)` "
                          + "(cut \(c.name)) — the port has drifted from its source")
        }
        guard let end = index(lines, containing: c.to, from: start + 1) else {
            throw Failure("cloud.js no longer has a line containing `\(c.to)` after "
                          + "`\(c.from)` (cut \(c.name))")
        }
        let body = lines[start..<end].joined(separator: "\n")
        for marker in c.mustContain where !body.contains(marker) {
            throw Failure("cut \(c.name) no longer contains `\(marker)` — it has moved "
                          + "out of the run this check cuts")
        }
        return body
    }
}

// MARK: - the JavaScript side

final class WebCloud {

    let ctx: JSContext
    private var thrown: String?

    /// Every cut this check makes, in the order they are evaluated. They
    /// are joined into ONE script so that `const GRAVE_TTL` and the
    /// functions that read it share a lexical scope.
    static let cuts: [Cut] = [
        Cut(name: "GRAVE_TTL",
            from: "  const GRAVE_TTL =",
            to: "  /* ---------------- the bookkeeping half ----------------",
            mustContain: ["90 * 24 * 60 * 60 * 1000"]),

        Cut(name: "sigOf",
            from: "  function sigOf(t) {",
            to: "  /* ---------------- what app.js lends us ---------------- */",
            mustContain: ["0x811c9dc5", "charCodeAt", "toString(36)", "k === 'updatedAt'"]),

        Cut(name: "stamp",
            from: "  function stamp() {",
            to: "  /** Re-record every task as-is",
            mustContain: ["Math.max(now", "book.graves[id] = now", "GRAVE_TTL"]),

        Cut(name: "reseal",
            from: "  function reseal() {",
            to: "  /* ---------------- talking to postgrest ---------------- */",
            mustContain: ["book.sigs = {}"]),

        Cut(name: "merge",
            from: "  function merge(rows) {",
            to: "  /** What the server has not got",
            mustContain: ["Date.parse(row.updated_at)", "<= rts", "grave >= rts",
                          "rts > (mine.updatedAt || 0)", "keep.delete(row.id)"]),

        Cut(name: "outbound",
            from: "  function outbound(rows) {",
            to: "  /* ---------------- a pass ---------------- */",
            mustContain: ["rts >= lts", "payload: {}", "deleted: true", "toISOString()"]),
    ]

    init(cloudJS: String, nowMS: Int) throws {
        let lines = try Extract.lines(of: cloudJS)
        guard let c = JSContext() else { throw Failure("no JSContext") }
        ctx = c
        ctx.exceptionHandler = { [weak self] _, e in self?.thrown = e?.toString() ?? "unknown" }

        try run(Self.prelude(nowMS: nowMS), "prelude")
        let body = try Self.cuts.map { try Extract.cut(lines, $0) }.joined(separator: "\n\n")
        try run(body, "cloud.js")
        try run(Self.postlude, "postlude")
    }

    @discardableResult
    func run(_ js: String, _ what: String) throws -> JSValue {
        thrown = nil
        let out = ctx.evaluateScript(js)
        if let thrown { throw Failure("\(what): \(thrown)") }
        return out ?? JSValue(undefinedIn: ctx)
    }

    func string(_ js: String) throws -> String {
        try run(js, js).toString() ?? ""
    }

    func number(_ js: String) throws -> Double {
        try run(js, js).toDouble()
    }

    /// What cloud.js borrows from the page and from the browser. Nothing
    /// here reimplements a rule: it is the host object app.js lends
    /// (cloud.js:115-117, 538-539), a no-op `persistBook`, and `Date`
    /// pinned so both sides read one clock.
    static func prelude(nowMS: Int) -> String {
        """
        (function () {
          var Real = Date;
          var FIXED = \(nowMS);
          globalThis.Date = new Proxy(Real, {
            construct: function (target, args) {
              return args.length === 0 ? new target(FIXED) : new target(...args);
            },
            apply: function () { return new Real(FIXED).toString(); },
            get: function (target, prop, recv) {
              if (prop === 'now') return function () { return FIXED; };
              return Reflect.get(target, prop, recv);
            }
          });
        })();

        var book = { user: null, sigs: {}, graves: {} };
        var dirty = false;
        var __list = [];
        var __userId = 'u1';

        var host = {
          read: function () { return __list; },
          write: function (next) { __list = next; },
          persist: function () {},
          repaint: function () {}
        };

        var tasks = function () { return host.read(); };
        var auth = { user: function () { return { id: __userId }; } };
        function persistBook() {}
        """
    }

    /// The handful of entry points the Swift side drives. Each one only
    /// seeds state and calls one of the cut functions.
    static let postlude = """
        function __seed(listJSON, bookJSON, userId) {
          __list = JSON.parse(listJSON);
          book = JSON.parse(bookJSON);
          __userId = userId;
          dirty = false;
        }
        function __list_json() { return JSON.stringify(tasks()); }
        function __book_json() { return JSON.stringify(book); }
        function __sig(taskJSON) { return sigOf(JSON.parse(taskJSON)); }
        function __stamp() { return stamp() ? 1 : 0; }
        function __merge(rowsJSON) { return merge(JSON.parse(rowsJSON)) ? 1 : 0; }
        function __outbound(rowsJSON) { return JSON.stringify(outbound(JSON.parse(rowsJSON))); }
        function __parse(s) { return Date.parse(s) || 0; }
        function __iso(ms) { return new Date(ms).toISOString(); }
        """

    // MARK: the calls

    func seed(list: String, book: String, userID: String = "u1") throws {
        _ = try run("__seed(\(WebJSON.quoted(list)), \(WebJSON.quoted(book)), \(WebJSON.quoted(userID)))",
                    "seed")
    }

    func sig(of taskJSON: String) throws -> String {
        try string("__sig(\(WebJSON.quoted(taskJSON)))")
    }

    func stamp() throws -> Bool {
        try number("__stamp()") == 1
    }

    func merge(_ rowsJSON: String) throws -> Bool {
        try number("__merge(\(WebJSON.quoted(rowsJSON)))") == 1
    }

    func outbound(_ rowsJSON: String) throws -> String {
        try string("__outbound(\(WebJSON.quoted(rowsJSON)))")
    }

    func parse(_ s: String) throws -> Int {
        Int(try number("__parse(\(WebJSON.quoted(s)))"))
    }

    /// `new Date(ms).toISOString()` — the reference for what goes UP.
    func iso(_ ms: Int) throws -> String {
        try string("__iso(\(ms))")
    }

    var listJSON: String { (try? string("__list_json()")) ?? "?" }
    var bookJSON: String { (try? string("__book_json()")) ?? "?" }
}

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
    func equal(_ what: String, _ got: String, _ want: String, quiet: Bool = false) -> Bool {
        checks += 1
        if got == want {
            if !quiet { print("    ok    \(what)") }
            return true
        }
        failures.append("\(section) / \(what)")
        print("    FAIL  \(what)")
        print("      web     \(want)")
        print("      native  \(got)")
        return false
    }

    @discardableResult
    func `true`(_ what: String, _ value: Bool) -> Bool {
        equal(what, value ? "true" : "false", "true")
    }

    func note(_ line: String) { print("    ---   \(line)") }
}

// MARK: - fixtures

/// One task written the way `normalizeTask` writes one: every key
/// present, in its literal order (app.js:1044-1068), `updatedAt` last.
enum Fixture {

    static func task(id: String,
                     title: String,
                     minutes: Int = 20,
                     energy: String = "medium",
                     urgency: Int = 3,
                     importance: String = "low",
                     quadrant: String? = nil,
                     firstStep: String = "Open it and look at it for 2 minutes.",
                     category: String = "general",
                     when: String? = nil,
                     at: String? = nil,
                     steps: [String]? = nil,
                     local: Bool = false,
                     gcal: (String, String)? = nil,
                     done: Bool = false,
                     doneAt: Int? = nil,
                     skipped: Bool = false,
                     extra: [(String, JSONValue)] = [],
                     updatedAt: Int? = nil) -> TaskItem
    {
        var o = JSONObject()
        o.set("id", .string(id))
        o.set("title", .string(title))
        o.set("minutes", .int(minutes))
        o.set("energy", .string(energy))
        o.set("urgency", .int(urgency))
        o.set("importance", .string(importance))
        o.set("quadrant", quadrant.map { .string($0) } ?? .null)
        o.set("firstStep", .string(firstStep))
        o.set("category", .string(category))
        o.set("when", when.map { .string($0) } ?? .null)
        o.set("at", at.map { .string($0) } ?? .null)
        o.set("steps", steps.map { .array($0.map { .string($0) }) } ?? .null)
        o.set("local", .bool(local))
        if let gcal {
            o.set("gcal", .object(JSONObject([("id", .string(gcal.0)), ("sig", .string(gcal.1))])))
        } else {
            o.set("gcal", .null)
        }
        o.set("done", .bool(done))
        o.set("doneAt", doneAt.map { .int($0) } ?? .null)
        o.set("skipped", .bool(skipped))
        for (k, v) in extra { o.set(k, v) }
        if let updatedAt { o.set("updatedAt", .int(updatedAt)) }
        return TaskItem(fields: o)
    }

    static func list(_ tasks: [TaskItem]) -> String {
        WebJSON.encode(.array(tasks.map(\.json)))
    }

    static func book(user: String? = "u1",
                     sigs: [(String, String)] = [],
                     graves: [(String, Int)] = []) -> String
    {
        var o = JSONObject()
        o.set("user", user.map { .string($0) } ?? .null)
        o.set("sigs", .object(JSONObject(sigs.map { ($0.0, JSONValue.string($0.1)) })))
        o.set("graves", .object(JSONObject(graves.map { ($0.0, JSONValue.int($0.1)) })))
        return WebJSON.encode(.object(o))
    }

    /// A PostgREST row, rendered the way PostgREST renders one — six
    /// fractional digits and a `+00:00` offset, not our own `toISOString`.
    static func row(id: String, payload: TaskItem?, updatedAt: Int, deleted: Bool = false) -> JSONValue {
        var o = JSONObject()
        o.set("id", .string(id))
        o.set("payload", payload.map { $0.json } ?? .object(JSONObject()))
        o.set("updated_at", .string(postgrest(updatedAt)))
        o.set("deleted", .bool(deleted))
        return .object(o)
    }

    static func rows(_ list: [JSONValue]) -> String {
        WebJSON.encode(.array(list))
    }

    /// `2026-09-20T12:34:56.789000+00:00` — milliseconds padded out to
    /// microseconds, which is what the column actually gives back.
    static func postgrest(_ ms: Int) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        let text = f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
        return text.replacingOccurrences(of: "Z", with: "000+00:00")
    }

    /// 220 tasks: ten titles that each break a different assumption,
    /// crossed with twenty-two shapes.
    static let titles = [
        "Pay the rent",
        "Hantar borang ke sekolah 📄",
        "café ☕️ meeting with Zoë",
        "日本語のタスクを終わらせる",
        "quote \"this\" and \\ that",
        "line\nbreak\ttab\u{0B}vertical",
        "family 👩‍👩‍👧‍👦 photo",
        "   padded   ",
        "",
        "Ünïcödé ﬁ ligature and a ʼn",
    ]

    static func corpus() -> [TaskItem] {
        var out: [TaskItem] = []
        for (i, title) in titles.enumerated() {
            let n = i + 1
            out.append(task(id: "t_a\(n)", title: title))
            out.append(task(id: "t_b\(n)", title: title, updatedAt: 1_700_000_000_000 + n))
            out.append(task(id: "t_c\(n)", title: title, minutes: 240, urgency: 5,
                            importance: "high", quadrant: "do"))
            out.append(task(id: "t_d\(n)", title: title, when: "2026-09-20", at: "09:05"))
            out.append(task(id: "t_e\(n)", title: title, when: "2026-09-20", at: nil))
            out.append(task(id: "t_f\(n)", title: title, steps: ["one", "two 🙂", "three"]))
            out.append(task(id: "t_g\(n)", title: title, steps: []))
            out.append(task(id: "t_h\(n)", title: title, gcal: ("abc123def", "sig :: with :: colons")))
            out.append(task(id: "t_i\(n)", title: title, gcal: ("x", "")))
            out.append(task(id: "t_j\(n)", title: title, done: true, doneAt: 1_700_000_000_123))
            out.append(task(id: "t_k\(n)", title: title, done: true, doneAt: nil))
            out.append(task(id: "t_l\(n)", title: title, firstStep: "", local: true))
            out.append(task(id: "t_m\(n)", title: title, skipped: true))
            out.append(task(id: "t_n\(n)", title: title, energy: "banana", importance: "sideways"))
            out.append(task(id: "t_o\(n)", title: title, category: "kerja rumah"))
            out.append(task(id: "t_p\(n)", title: title,
                            extra: [("colour", .string("violet"))]))
            out.append(task(id: "t_q\(n)", title: title,
                            extra: [("nested", .object(JSONObject([("a", .int(1)), ("b", .null)])))]))
            out.append(task(id: "t_r\(n)", title: title,
                            extra: [("list", .array([.int(1), .string("two"), .bool(true), .null]))]))
            out.append(task(id: "t_s\(n)", title: title, minutes: 2, urgency: 1,
                            extra: [("n", .double(1.5))]))
            out.append(task(id: "t_t\(n)", title: title, quadrant: "drop",
                            updatedAt: 1_700_000_000_000 + n * 7))
            out.append(task(id: "t_u\(n)", title: title, firstStep: title, category: title))
            out.append(task(id: "t_v\(n)", title: title, when: nil, at: "23:59",
                            steps: ["\u{1F4A1} idea"], gcal: ("g", "s"), updatedAt: 1))
        }
        return out
    }
}

// MARK: - the native side

/// One `AppStore` and one `CloudSync` over a real temp directory, built
/// the way the app builds them.
@MainActor
final class NativeCloud {

    let dir: URL
    let store: AppStore
    let session: Session
    let sync: CloudSync
    let now: Date

    init(now: Date, http: URLSession = Supabase.http) {
        self.now = now
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("myadhd-cloud-check-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let file = StoreFile(directory: dir, clock: { now })
        store = AppStore(file: file, inShell: true, clock: { now })

        /* A live session, in memory — the login keychain of whoever runs
           this is not touched. `expiresAt` is an hour out, so
           `freshToken()` answers from the record and never goes near the
           network. */
        var record = JSONObject()
        record.set("access_token", .string("jwt-for-the-stub"))
        record.set("refresh_token", .string("refresh-for-the-stub"))
        record.set("expiresAt", .int(Int(now.timeIntervalSince1970 * 1000) + 3_600_000))
        record.set("user", .object(JSONObject([
            ("id", .string("u1")), ("email", .string("someone@example.com")), ("name", .null),
        ])))
        session = Session(store: MemorySessionStore(Data(WebJSON.encode(.object(record)).utf8)),
                          http: http,
                          clock: { now })

        sync = CloudSync(store: store,
                         session: session,
                         api: Supabase(session: session, http: http),
                         reachability: Reachability(clock: { now }),
                         bookURL: dir.appendingPathComponent(CloudBook.fileName),
                         clock: { now })
    }

    /// Put the same state into the native side that `__seed` puts into
    /// the JavaScript one.
    func seed(list: String, book: String) {
        var doc = store.doc
        doc.tasks = (try? JSONValue.parse(list))?.arrayValue?.compactMap { TaskItem($0) } ?? []
        store.adopt(doc)
        sync.loadBook(CloudBook.load(text: book))
    }

    func adopt(_ tasks: [TaskItem]) {
        var doc = store.doc
        doc.tasks = tasks
        store.adopt(doc)
    }

    var listJSON: String { WebJSON.encode(.array(store.doc.tasks.map(\.json))) }
    var bookJSON: String { sync.book.jsonString }

    func clean() {
        store.file.flush()
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - the URLProtocol stub

/// Every request the client makes, recorded, with a canned answer. The
/// point of it is the assertion that the bytes on the wire are the bytes
/// cloud.js puts there.
final class StubProtocol: URLProtocol {

    struct Call {
        var method: String
        var url: String
        var headers: [String: String]
        var body: String?
    }

    nonisolated(unsafe) static var calls: [Call] = []
    nonisolated(unsafe) static var answer: (status: Int, body: String) = (200, "[]")
    /// Set to make the request fail the way a tunnel fails it: nothing
    /// arrives, and there is no status to read.
    nonisolated(unsafe) static var failure: URLError?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body: String?
        if let data = request.httpBody {
            body = String(data: data, encoding: .utf8)
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
            body = String(data: data, encoding: .utf8)
        }

        Self.calls.append(Call(method: request.httpMethod ?? "",
                               url: request.url?.absoluteString ?? "",
                               headers: request.allHTTPHeaderFields ?? [:],
                               body: body))

        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }

        let answer = Self.answer
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: answer.status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !answer.body.isEmpty {
            client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }

    static func reset(status: Int = 200, body: String = "[]", failure: URLError? = nil) {
        calls = []
        answer = (status, body)
        self.failure = failure
    }
}

// MARK: - the run

@main
struct CloudChecks {

    @MainActor
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        func take(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let v = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return v
        }
        let cloudJS = take("--cloud-js") ?? "/Users/User/Desktop/Claude Code/My.adhd/cloud.js"

        /* A zone is set even though nothing in the sync formats a local
           date: `toISOString` and `Date.parse` both read the process
           zone through the C library, and a check that only ever ran in
           UTC would not notice a port that used a local formatter. */
        let tz = take("--tz") ?? "Asia/Kuala_Lumpur"
        guard let zone = TimeZone(identifier: tz) else {
            FileHandle.standardError.write(Data("unknown time zone \(tz)\n".utf8))
            exit(2)
        }
        NSTimeZone.default = zone
        setenv("TZ", tz, 1)
        tzset()

        let nowMS = Int(take("--now") ?? "") ?? 1_789_000_000_000
        let now = Date(timeIntervalSince1970: Double(nowMS) / 1000)

        let report = Report()
        let web: WebCloud
        do {
            web = try WebCloud(cloudJS: cloudJS, nowMS: nowMS)
        } catch {
            FileHandle.standardError.write(Data("cloud.swift: \(error)\n".utf8))
            exit(2)
        }

        print("cloud.swift — \(tz), pinned at \(nowMS)")
        print("             cloud.js: \(cloudJS)")

        signatures(web, report, now: now)
        twins(report)
        stamping(web, report, now: now)
        mergeAndOutbound(web, report, now: now)
        await wire(web, report, now: now)
        await liveness(report, now: now)
        instants(web, report)

        print("\n  \(report.checks) checks, \(report.failures.count) failed")
        for f in report.failures { print("    - \(f)") }
        exit(report.failures.isEmpty ? 0 : 1)
    }

    // MARK: 1 — sigOf, byte for byte

    @MainActor
    static func signatures(_ web: WebCloud, _ report: Report, now: Date) {
        report.open("1. sigOf against cloud.js, over the corpus")
        let corpus = Fixture.corpus()
        var bad = 0

        for t in corpus {
            let mine = CloudBook.sigOf(t)
            let theirs = (try? web.sig(of: t.jsonString)) ?? "<threw>"
            if !report.equal("sigOf \(t.id)", mine, theirs, quiet: true) { bad += 1 }
        }
        report.note("\(corpus.count) tasks, \(bad) divergences")

        /* The two properties a Swift port gets wrong, asserted on their
           own so a failure names the cause and not just a hash. */
        let emoji = Fixture.task(id: "t_len", title: "👩‍👩‍👧‍👦")
        let mine = CloudBook.sigOf(emoji)
        report.equal("a surrogate pair counts as two units, not one",
                     String(mine.split(separator: ".").last ?? ""),
                     String(WebJSON.encode(withoutStamp(emoji)).utf16.count))

        let stamped = Fixture.task(id: "t_st", title: "same", updatedAt: 5)
        let restamped = Fixture.task(id: "t_st", title: "same", updatedAt: 999_999)
        report.equal("updatedAt is not part of the signature",
                     CloudBook.sigOf(stamped), CloudBook.sigOf(restamped))
    }

    /// The text the hash is taken over, for the length assertion above.
    static func withoutStamp(_ t: TaskItem) -> JSONValue {
        var o = t.encoded()
        o.removeValue(forKey: "updatedAt")
        return .object(o)
    }

    // MARK: 2 — the two copies agree

    @MainActor
    static func twins(_ report: Report) {
        report.open("2. LegacyImport.sigOf == CloudBook.sigOf")
        var bad = 0
        let corpus = Fixture.corpus()
        for t in corpus {
            if !report.equal("twin \(t.id)", LegacyImport.sigOf(t), CloudBook.sigOf(t), quiet: true) {
                bad += 1
            }
        }
        report.note("\(corpus.count) tasks, \(bad) divergences")
        report.note("if this fails, the migration reseals with a hash the first pass "
                    + "does not recognise and every row is restamped")
    }

    // MARK: 3 — stamp

    @MainActor
    static func stamping(_ web: WebCloud, _ report: Report, now: Date) {
        report.open("3. stamp")

        let n = NativeCloud(now: now)
        defer { n.clean() }
        let nowMS = Int(now.timeIntervalSince1970 * 1000)

        let a = Fixture.task(id: "t_a", title: "Pay the rent")
        let b = Fixture.task(id: "t_b", title: "Call the clinic", updatedAt: nowMS - 5_000)
        let sigA = CloudBook.sigOf(a)
        let sigB = CloudBook.sigOf(b)

        func pair(_ name: String, list: String, book: String) {
            n.seed(list: list, book: book)
            try? web.seed(list: list, book: book)

            var tasks = (try? JSONValue.parse(list))?.arrayValue?.compactMap { TaskItem($0) } ?? []
            var native = CloudBook.load(text: book)
            let mineMoved = native.stamp(&tasks, now: nowMS)
            let theirsMoved = (try? web.stamp()) ?? false

            report.equal("\(name): moved", mineMoved ? "1" : "0", theirsMoved ? "1" : "0")
            report.equal("\(name): tasks",
                         WebJSON.encode(.array(tasks.map(\.json))), web.listJSON)
            report.equal("\(name): book", native.jsonString, web.bookJSON)
        }

        pair("a fresh task with no sig and no stamp",
             list: Fixture.list([a]), book: Fixture.book())
        pair("the sig matches and the stamp is there — untouched",
             list: Fixture.list([b]), book: Fixture.book(sigs: [("t_b", sigB)]))
        pair("the sig matches but there is no stamp — stamped anyway",
             list: Fixture.list([a]), book: Fixture.book(sigs: [("t_a", sigA)]))
        pair("the sig moved",
             list: Fixture.list([Fixture.task(id: "t_b", title: "Call the dentist",
                                              updatedAt: nowMS - 5_000)]),
             book: Fixture.book(sigs: [("t_b", sigB)]))
        pair("a stamp in the future — never go backwards, never repeat",
             list: Fixture.list([Fixture.task(id: "t_b", title: "moved", updatedAt: nowMS + 60_000)]),
             book: Fixture.book(sigs: [("t_b", sigB)]))
        pair("an id that is gone leaves a grave",
             list: Fixture.list([]), book: Fixture.book(sigs: [("t_b", sigB)]))
        pair("a grave older than the TTL is dropped",
             list: Fixture.list([]),
             book: Fixture.book(graves: [("t_old", nowMS - CloudBook.graveTTL - 1)]))
        pair("a grave exactly at the TTL stays",
             list: Fixture.list([]),
             book: Fixture.book(graves: [("t_edge", nowMS - CloudBook.graveTTL)]))
        pair("re-adding a buried id digs it up",
             list: Fixture.list([a]), book: Fixture.book(graves: [("t_a", nowMS - 1_000)]))
    }

    // MARK: 4 — merge and outbound

    @MainActor
    static func mergeAndOutbound(_ web: WebCloud, _ report: Report, now: Date) {
        report.open("4. merge and outbound, replayed from cloud.js")

        let nowMS = Int(now.timeIntervalSince1970 * 1000)
        let T = nowMS - 100_000        // "then"
        let LATER = nowMS - 50_000
        let n = NativeCloud(now: now)
        defer { n.clean() }

        /// One combination: the same local list, book and rows into both
        /// sides, then `merge` and `outbound` compared.
        func combo(_ name: String, list: String, book: String, rows: String) {
            n.seed(list: list, book: book)
            do { try web.seed(list: list, book: book) } catch {
                report.equal("\(name): seed", "\(error)", "ok"); return
            }

            let mine = n.sync.merge((try? JSONValue.parse(rows))?.arrayValue?
                .compactMap { Supabase.Row($0) } ?? [])
            let theirs = (try? web.merge(rows)) ?? false

            report.equal("\(name): changed", mine.changed ? "1" : "0", theirs ? "1" : "0")
            report.equal("\(name): list",
                         WebJSON.encode(.array(mine.list.map(\.json))), web.listJSON)
            report.equal("\(name): book", n.bookJSON, web.bookJSON)

            /* outbound reads the list the merge left behind, on both
               sides — cloud.js:397 runs after `host.write`. */
            n.adopt(mine.list)
            let out = n.sync.outbound((try? JSONValue.parse(rows))?.arrayValue?
                .compactMap { Supabase.Row($0) } ?? [], userID: "u1")
            report.equal("\(name): outbound",
                         WebJSON.encode(.array(out.map(\.json))),
                         (try? web.outbound(rows)) ?? "<threw>")
        }

        let mineOld = Fixture.task(id: "t_1", title: "mine, old", updatedAt: T)
        let mineNew = Fixture.task(id: "t_1", title: "mine, new", updatedAt: LATER)
        let theirs = Fixture.task(id: "t_1", title: "theirs", updatedAt: LATER)
        let sig1 = CloudBook.sigOf(mineOld)

        // ---- the deleted branch, on every side of `<=`
        combo("remote deleted, mine is older",
              list: Fixture.list([mineOld]), book: Fixture.book(sigs: [("t_1", sig1)]),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: nil, updatedAt: LATER, deleted: true)]))
        combo("remote deleted, mine is the same millisecond",
              list: Fixture.list([mineOld]), book: Fixture.book(sigs: [("t_1", sig1)]),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: nil, updatedAt: T, deleted: true)]))
        combo("remote deleted, mine is newer — it lives",
              list: Fixture.list([mineNew]), book: Fixture.book(sigs: [("t_1", sig1)]),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: nil, updatedAt: T, deleted: true)]))
        combo("remote deleted, mine has no stamp at all",
              list: Fixture.list([Fixture.task(id: "t_1", title: "unstamped")]),
              book: Fixture.book(),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: nil, updatedAt: T, deleted: true)]))
        combo("remote deleted, not mine at all",
              list: Fixture.list([]), book: Fixture.book(),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: nil, updatedAt: T, deleted: true)]))
        combo("remote deleted at an unparsable instant",
              list: Fixture.list([mineOld]), book: Fixture.book(),
              rows: "[{\"id\":\"t_1\",\"payload\":{},\"updated_at\":\"nonsense\",\"deleted\":true}]")

        // ---- arrivals, against the grave
        combo("an arrival with no grave",
              list: Fixture.list([]), book: Fixture.book(),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: theirs, updatedAt: LATER)]))
        combo("an arrival with an older grave — it comes back",
              list: Fixture.list([]), book: Fixture.book(graves: [("t_1", T)]),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: theirs, updatedAt: LATER)]))
        combo("an arrival with a grave at the same millisecond — skipped",
              list: Fixture.list([]), book: Fixture.book(graves: [("t_1", LATER)]),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: theirs, updatedAt: LATER)]))
        combo("an arrival with a newer grave — skipped",
              list: Fixture.list([]), book: Fixture.book(graves: [("t_1", nowMS)]),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: theirs, updatedAt: LATER)]))
        combo("an arrival carrying a key this build has never heard of",
              list: Fixture.list([]), book: Fixture.book(),
              rows: Fixture.rows([Fixture.row(
                  id: "t_2",
                  payload: Fixture.task(id: "t_2", title: "from a newer web build",
                                        extra: [("mood", .string("calm")),
                                                ("weight", .double(0.5))],
                                        updatedAt: LATER),
                  updatedAt: LATER)]))
        combo("an arrival with nulls all the way down",
              list: Fixture.list([]), book: Fixture.book(),
              rows: Fixture.rows([Fixture.row(
                  id: "t_3",
                  payload: Fixture.task(id: "t_3", title: "", firstStep: "", updatedAt: LATER),
                  updatedAt: LATER)]))
        combo("an arrival with a gcal ref",
              list: Fixture.list([]), book: Fixture.book(),
              rows: Fixture.rows([Fixture.row(
                  id: "t_4",
                  payload: Fixture.task(id: "t_4", title: "dated", when: "2026-10-01", at: "08:00",
                                        gcal: ("evt-1", "a :: b :: c"), updatedAt: LATER),
                  updatedAt: LATER)]))
        combo("an arrival whose payload disagrees with the row about the id",
              list: Fixture.list([]), book: Fixture.book(),
              rows: Fixture.rows([Fixture.row(
                  id: "t_5",
                  payload: Fixture.task(id: "t_WRONG", title: "row wins", updatedAt: LATER),
                  updatedAt: LATER)]))

        // ---- in place, on strict `>`
        combo("edited elsewhere, strictly newer — replaced in place",
              list: Fixture.list([mineOld]), book: Fixture.book(sigs: [("t_1", sig1)]),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: theirs, updatedAt: LATER)]))
        combo("edited elsewhere, same millisecond — left alone",
              list: Fixture.list([mineOld]), book: Fixture.book(sigs: [("t_1", sig1)]),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: theirs, updatedAt: T)]))
        combo("older on the server — left alone",
              list: Fixture.list([mineNew]), book: Fixture.book(sigs: [("t_1", sig1)]),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: theirs, updatedAt: T)]))
        combo("replaced in place keeps its position in the list",
              list: Fixture.list([Fixture.task(id: "t_0", title: "first", updatedAt: T),
                                  mineOld,
                                  Fixture.task(id: "t_9", title: "last", updatedAt: T)]),
              book: Fixture.book(),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: theirs, updatedAt: LATER)]))
        combo("an in-place replace drops a key the payload does not have",
              list: Fixture.list([Fixture.task(id: "t_1", title: "mine",
                                               extra: [("legacy", .string("gone"))],
                                               updatedAt: T)]),
              book: Fixture.book(),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: theirs, updatedAt: LATER)]))

        // ---- several at once
        combo("a delete, an arrival and a replace in one pass",
              list: Fixture.list([mineOld,
                                  Fixture.task(id: "t_gone", title: "to be deleted", updatedAt: T)]),
              book: Fixture.book(sigs: [("t_1", sig1), ("t_gone", "x.1")]),
              rows: Fixture.rows([
                  Fixture.row(id: "t_1", payload: theirs, updatedAt: LATER),
                  Fixture.row(id: "t_gone", payload: nil, updatedAt: LATER, deleted: true),
                  Fixture.row(id: "t_new", payload: Fixture.task(id: "t_new", title: "hello",
                                                                 updatedAt: LATER),
                              updatedAt: LATER),
              ]))
        combo("no rows at all",
              list: Fixture.list([mineOld]), book: Fixture.book(sigs: [("t_1", sig1)]),
              rows: "[]")
        combo("rows for things this device has never had",
              list: Fixture.list([]), book: Fixture.book(),
              rows: Fixture.rows([
                  Fixture.row(id: "t_x", payload: Fixture.task(id: "t_x", title: "x", updatedAt: T),
                              updatedAt: T),
                  Fixture.row(id: "t_y", payload: Fixture.task(id: "t_y", title: "y", updatedAt: T),
                              updatedAt: T),
              ]))
        combo("the same row twice in one answer",
              list: Fixture.list([mineOld]), book: Fixture.book(),
              rows: Fixture.rows([
                  Fixture.row(id: "t_1", payload: theirs, updatedAt: LATER),
                  Fixture.row(id: "t_1", payload: nil, updatedAt: nowMS, deleted: true),
              ]))

        // ---- outbound on its own
        combo("a local task the server has never seen",
              list: Fixture.list([Fixture.task(id: "t_p", title: "push me", updatedAt: T)]),
              book: Fixture.book(), rows: "[]")
        combo("a local task with no stamp goes up at now",
              list: Fixture.list([Fixture.task(id: "t_p", title: "no stamp")]),
              book: Fixture.book(), rows: "[]")
        combo("the server has an older copy",
              list: Fixture.list([mineNew]), book: Fixture.book(),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: mineOld, updatedAt: T)]))
        combo("the server has the same millisecond — nothing goes up",
              list: Fixture.list([mineOld]), book: Fixture.book(),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: mineOld, updatedAt: T)]))
        combo("the server has a newer copy and the merge took it",
              list: Fixture.list([mineOld]), book: Fixture.book(),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: theirs, updatedAt: LATER)]))
        combo("the server row is a tombstone and mine is newer — it goes back up",
              list: Fixture.list([mineNew]), book: Fixture.book(),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: nil, updatedAt: T, deleted: true)]))
        combo("a grave the server has not got",
              list: Fixture.list([]), book: Fixture.book(graves: [("t_d", T)]), rows: "[]")
        combo("a grave the server has, older",
              list: Fixture.list([]), book: Fixture.book(graves: [("t_d", LATER)]),
              rows: Fixture.rows([Fixture.row(id: "t_d", payload: nil, updatedAt: T, deleted: true)]))
        combo("a grave the server has at the same millisecond — nothing goes up",
              list: Fixture.list([]), book: Fixture.book(graves: [("t_d", T)]),
              rows: Fixture.rows([Fixture.row(id: "t_d", payload: nil, updatedAt: T, deleted: true)]))
        combo("a grave the server has newer — nothing goes up",
              list: Fixture.list([]), book: Fixture.book(graves: [("t_d", T)]),
              rows: Fixture.rows([Fixture.row(id: "t_d", payload: nil, updatedAt: LATER, deleted: true)]))
        combo("a grave for a row the server still thinks is alive",
              list: Fixture.list([]), book: Fixture.book(graves: [("t_d", LATER)]),
              rows: Fixture.rows([Fixture.row(
                  id: "t_d", payload: Fixture.task(id: "t_d", title: "alive", updatedAt: T),
                  updatedAt: T)]))
        combo("two graves and a push, in one body",
              list: Fixture.list([Fixture.task(id: "t_p", title: "push", updatedAt: LATER)]),
              book: Fixture.book(graves: [("t_d1", T), ("t_d2", LATER)]), rows: "[]")
        combo("everything at once",
              list: Fixture.list([mineNew,
                                  Fixture.task(id: "t_p", title: "push", updatedAt: LATER),
                                  Fixture.task(id: "t_same", title: "same", updatedAt: T)]),
              book: Fixture.book(sigs: [("t_1", sig1)], graves: [("t_d", LATER)]),
              rows: Fixture.rows([
                  Fixture.row(id: "t_1", payload: theirs, updatedAt: T),
                  Fixture.row(id: "t_same", payload: mineOld, updatedAt: T),
                  Fixture.row(id: "t_d", payload: nil, updatedAt: T, deleted: true),
                  Fixture.row(id: "t_ghost", payload: Fixture.task(id: "t_ghost", title: "ghost",
                                                                    updatedAt: LATER),
                              updatedAt: LATER),
              ]))

        // ---- the odd shapes a real answer contains
        combo("a row with no `deleted` key at all",
              list: Fixture.list([]), book: Fixture.book(),
              rows: "[{\"id\":\"t_1\",\"payload\":"
                  + WebJSON.encode(theirs.json) + ",\"updated_at\":\""
                  + Fixture.postgrest(LATER) + "\"}]")
        combo("a live row whose payload is null",
              list: Fixture.list([]), book: Fixture.book(),
              rows: "[{\"id\":\"t_1\",\"payload\":null,\"updated_at\":\""
                  + Fixture.postgrest(LATER) + "\",\"deleted\":false}]")
        combo("a grave of zero is no grave at all",
              list: Fixture.list([]), book: Fixture.book(graves: [("t_1", 0)]),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: theirs, updatedAt: LATER)]))
        combo("an arrival the other device sorted offline",
              list: Fixture.list([]), book: Fixture.book(),
              rows: Fixture.rows([Fixture.row(
                  id: "t_6",
                  payload: Fixture.task(id: "t_6", title: "rough guess", firstStep: "",
                                        local: true, updatedAt: LATER),
                  updatedAt: LATER)]))
        combo("three arrivals keep the answer's order",
              list: Fixture.list([]), book: Fixture.book(),
              rows: Fixture.rows([
                  Fixture.row(id: "t_c", payload: Fixture.task(id: "t_c", title: "c", updatedAt: T),
                              updatedAt: T),
                  Fixture.row(id: "t_a", payload: Fixture.task(id: "t_a", title: "a", updatedAt: T),
                              updatedAt: T),
                  Fixture.row(id: "t_b", payload: Fixture.task(id: "t_b", title: "b", updatedAt: T),
                              updatedAt: T),
              ]))
        combo("two deletes, one older than mine and one newer",
              list: Fixture.list([Fixture.task(id: "t_old", title: "older than the tombstone",
                                               updatedAt: T),
                                  Fixture.task(id: "t_new", title: "newer than the tombstone",
                                               updatedAt: nowMS)]),
              book: Fixture.book(sigs: [("t_old", "a.1"), ("t_new", "b.2")]),
              rows: Fixture.rows([
                  Fixture.row(id: "t_old", payload: nil, updatedAt: LATER, deleted: true),
                  Fixture.row(id: "t_new", payload: nil, updatedAt: LATER, deleted: true),
              ]))
        combo("an id with unicode in it",
              list: Fixture.list([]), book: Fixture.book(),
              rows: Fixture.rows([Fixture.row(
                  id: "t_ünï_🙂",
                  payload: Fixture.task(id: "t_ünï_🙂", title: "café", updatedAt: LATER),
                  updatedAt: LATER)]))
        combo("the same id held twice locally",
              list: Fixture.list([mineOld, Fixture.task(id: "t_1", title: "the other copy",
                                                        updatedAt: T)]),
              book: Fixture.book(),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: theirs, updatedAt: LATER)]))
        combo("the book mentions an id neither side has",
              list: Fixture.list([mineOld]),
              book: Fixture.book(sigs: [("t_ghost", "z.9")]),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: mineOld, updatedAt: T)]))
        combo("a local task stamped zero",
              list: Fixture.list([Fixture.task(id: "t_z", title: "zero", updatedAt: 0)]),
              book: Fixture.book(), rows: "[]")
        combo("a row alive one millisecond after the grave",
              list: Fixture.list([]), book: Fixture.book(graves: [("t_1", LATER)]),
              rows: Fixture.rows([Fixture.row(id: "t_1", payload: theirs, updatedAt: LATER + 1)]))
        combo("five local, four rows, every branch at once",
              list: Fixture.list([
                  Fixture.task(id: "t_keep", title: "untouched", updatedAt: T),
                  mineOld,
                  Fixture.task(id: "t_bye", title: "deleted elsewhere", updatedAt: T),
                  Fixture.task(id: "t_win", title: "mine is newer", updatedAt: nowMS),
                  Fixture.task(id: "t_up", title: "never been up"),
              ]),
              book: Fixture.book(sigs: [("t_1", sig1)], graves: [("t_buried", T)]),
              rows: Fixture.rows([
                  Fixture.row(id: "t_1", payload: theirs, updatedAt: LATER),
                  Fixture.row(id: "t_bye", payload: nil, updatedAt: LATER, deleted: true),
                  Fixture.row(id: "t_win", payload: Fixture.task(id: "t_win", title: "stale",
                                                                 updatedAt: T),
                              updatedAt: T),
                  Fixture.row(id: "t_buried", payload: Fixture.task(id: "t_buried", title: "back",
                                                                     updatedAt: LATER),
                              updatedAt: LATER),
              ]))
    }

    // MARK: 5 — the wire

    @MainActor
    static func wire(_ web: WebCloud, _ report: Report, now: Date) async {
        report.open("5. the wire, through a URLProtocol stub")

        let http = StubProtocol.session()
        let n = NativeCloud(now: now, http: http)
        defer { n.clean() }
        let api = Supabase(session: n.session, http: http)

        let base = Supabase.urlBase

        // ---- the pull
        StubProtocol.reset(body: "[]")
        _ = try? await api.pull()
        guard let call = StubProtocol.calls.first else {
            report.equal("pull: a request was made", "none", "one"); return
        }
        report.equal("pull: method", call.method, "GET")
        report.equal("pull: url", call.url,
                     base + "/rest/v1/tasks?select=id,payload,updated_at,deleted")
        report.equal("pull: apikey", call.headers["apikey"] ?? "", Supabase.anonKey)
        report.equal("pull: bearer", call.headers["Authorization"] ?? "", "Bearer jwt-for-the-stub")
        report.equal("pull: content type", call.headers["Content-Type"] ?? "", "application/json")
        report.true("pull: no Prefer header", call.headers["Prefer"] == nil)
        report.true("pull: no body", call.body == nil || call.body == "")
        /* RLS scopes the rows already. A client that also filters is
           how a pull quietly starts returning nothing. */
        report.true("pull: NEVER a user_id filter", !call.url.contains("user_id"))

        // ---- the probe
        let probeStamp = "2026-09-20T12:34:56.789123+00:00"
        StubProtocol.reset(body: "[{\"updated_at\":\"\(probeStamp)\"}]")
        let newest = (try? await api.probeNewest()) ?? -1
        guard let call = StubProtocol.calls.first else {
            report.equal("probe: a request was made", "none", "one"); return
        }
        report.equal("probe: url", call.url,
                     base + "/rest/v1/tasks?select=updated_at&order=updated_at.desc&limit=1")
        report.equal("probe: the newest instant, in ms",
                     String(newest), String((try? web.parse(probeStamp)) ?? -1))
        report.true("probe: no user_id filter", !call.url.contains("user_id"))

        // ---- the upsert
        StubProtocol.reset(status: 204, body: "")
        let rows = [
            Supabase.Outgoing(id: "t_1", userID: "u1",
                              payload: Fixture.task(id: "t_1", title: "up", updatedAt: 1_789_000_000_000).json,
                              updatedAt: 1_789_000_000_000, deleted: false),
            Supabase.Outgoing(id: "t_2", userID: "u1", payload: .object(JSONObject()),
                              updatedAt: 1_789_000_000_001, deleted: true),
        ]
        try? await api.upsert(rows)
        guard let call = StubProtocol.calls.first else {
            report.equal("upsert: a request was made", "none", "one"); return
        }
        report.equal("upsert: method", call.method, "POST")
        report.equal("upsert: url", base + "/rest/v1/tasks?on_conflict=id,user_id", call.url)
        report.equal("upsert: Prefer", call.headers["Prefer"] ?? "",
                     "resolution=merge-duplicates,return=minimal")
        report.equal("upsert: apikey", call.headers["apikey"] ?? "", Supabase.anonKey)
        report.equal("upsert: bearer", call.headers["Authorization"] ?? "", "Bearer jwt-for-the-stub")

        let body = call.body ?? ""
        report.true("upsert: the body is an ARRAY", body.hasPrefix("[") && body.hasSuffix("]"))
        report.equal("upsert: the body, byte for byte", body,
                     WebJSON.encode(.array(rows.map(\.json))))
        report.true("upsert: every row carries user_id", body.contains("\"user_id\":\"u1\""))
        let graveISO = (try? web.iso(1_789_000_000_001)) ?? "?"
        let taskISO = (try? web.iso(1_789_000_000_000)) ?? "?"
        report.true("upsert: a tombstone's payload is {}",
                    body.contains("\"payload\":{},\"updated_at\":\"\(graveISO)\",\"deleted\":true"))
        report.true("upsert: updated_at is toISOString, ms and a Z",
                    body.contains("\"updated_at\":\"\(taskISO)\""))

        // ---- an empty upsert asks nothing
        StubProtocol.reset(status: 204, body: "")
        try? await api.upsert([])
        report.true("upsert: nothing to say, nothing sent", StubProtocol.calls.isEmpty)

        // ---- the error shape
        StubProtocol.reset(status: 401, body: "{\"code\":\"42501\",\"message\":\"permission denied\"}")
        var caught = "none"
        do { _ = try await api.pull() } catch let e as SyncError { caught = e.message } catch {}
        report.equal("a status becomes cloud.js's own sentence", caught, "the server answered 401")

        StubProtocol.reset(status: 500, body: "{}")
        caught = "none"
        do { _ = try await api.probeNewest() } catch let e as SyncError { caught = e.message } catch {}
        report.equal("a 500 too", caught, "the server answered 500")

        // ---- signed out
        let signedOut = NativeCloud(now: now, http: http)
        signedOut.session.clear()
        StubProtocol.reset(body: "[]")
        let api2 = Supabase(session: signedOut.session, http: http)
        caught = "none"
        do { _ = try await api2.pull() } catch let e as SyncError { caught = e.message } catch {}
        report.equal("no session, no request", caught, "signed out")
        report.true("and nothing went out", StubProtocol.calls.isEmpty)
        signedOut.clean()
    }


    // MARK: 7 — the liveness rule

    /// **The one deliberate divergence from auth.js** (design §2.7 and §4,
    /// decision 7). auth.js:159-165 drops the session on any refresh
    /// failure, a network one included, which signs somebody out on a
    /// train. Here a transport failure and a 5xx keep it; only a 4xx from
    /// `/auth/v1/token` ends it.
    ///
    /// There is nothing to replay from `cloud.js` in this section, because
    /// the rule is a departure from the page and not a port of it. What it
    /// is held against is the decision, stated as cases.
    @MainActor
    static func liveness(_ report: Report, now: Date) async {
        report.open("7. the session keeps a tunnel and lets go of a refusal")

        let http = StubProtocol.session()
        let nowMS = Int(now.timeIntervalSince1970 * 1000)

        func expiredSession(refresh: String? = "r1") -> Session {
            var record = JSONObject()
            record.set("access_token", .string("stale"))
            record.set("refresh_token", refresh.map { .string($0) } ?? .null)
            record.set("expiresAt", .int(nowMS - 1_000))
            record.set("user", .object(JSONObject([
                ("id", .string("u1")), ("email", .string("someone@example.com")), ("name", .null),
            ])))
            return Session(store: MemorySessionStore(Data(WebJSON.encode(.object(record)).utf8)),
                           http: http, clock: { now })
        }

        func attempt(_ s: Session) async -> SessionError? {
            do { _ = try await s.freshToken(); return nil }
            catch let e as SessionError { return e }
            catch { return .offline(error) }
        }

        // ---- a request that never left
        StubProtocol.reset(failure: URLError(.notConnectedToInternet))
        var s = expiredSession()
        var why = await attempt(s)
        report.equal("a tunnel: the reason", why?.message ?? "none", "could not reach the server")
        report.true("a tunnel: THE SESSION IS KEPT", s.signedIn)
        report.true("a tunnel: and so is the account it names", s.user?.id == "u1")

        StubProtocol.reset(failure: URLError(.timedOut))
        s = expiredSession()
        why = await attempt(s)
        report.true("a timeout is a tunnel too", s.signedIn && why?.isSignedOut == false)

        // ---- a refusal
        for code in [400, 401, 403, 422] {
            StubProtocol.reset(status: code, body: "{\"error\":\"invalid_grant\"}")
            s = expiredSession()
            why = await attempt(s)
            report.true("a \(code) ends the session", !s.signedIn && why?.isSignedOut == true)
        }

        // ---- a bad minute at the server
        for code in [500, 502, 503] {
            StubProtocol.reset(status: code, body: "{}")
            s = expiredSession()
            why = await attempt(s)
            report.equal("a \(code) keeps it, and says so",
                         (s.signedIn ? "kept: " : "dropped: ") + (why?.message ?? "none"),
                         "kept: the server answered \(code)")
        }

        // ---- a 2xx with nothing in it
        StubProtocol.reset(status: 200, body: "{\"expires_in\":3600}")
        s = expiredSession()
        why = await attempt(s)
        report.true("a 200 with no token in it keeps the session", s.signedIn)

        // ---- no refresh token at all
        StubProtocol.reset(status: 200, body: "{}")
        s = expiredSession(refresh: nil)
        why = await attempt(s)
        report.true("no grant to refresh with ends it, without asking",
                    !s.signedIn && why?.isSignedOut == true && StubProtocol.calls.isEmpty)

        // ---- the good case, and the shape of the request
        StubProtocol.reset(status: 200,
                           body: "{\"access_token\":\"fresh\",\"refresh_token\":\"r2\",\"expires_in\":3600}")
        s = expiredSession()
        let token = try? await s.freshToken()
        report.equal("a good refresh returns the new token", token ?? "none", "fresh")
        report.true("and the session is live again", s.live())
        report.true("and the account survives the swap", s.user?.email == "someone@example.com")
        if let call = StubProtocol.calls.first {
            report.equal("refresh: method", call.method, "POST")
            report.equal("refresh: url", call.url,
                         Supabase.urlBase + "/auth/v1/token?grant_type=refresh_token")
            report.equal("refresh: apikey", call.headers["apikey"] ?? "", Supabase.anonKey)
            /* The grant IS the credential here; a bearer token would be
               the dead one we are trying to replace. */
            report.true("refresh: no Authorization header", call.headers["Authorization"] == nil)
            report.equal("refresh: body", call.body ?? "", "{\"refresh_token\":\"r1\"}")
        } else {
            report.equal("refresh: a request was made", "none", "one")
        }

        // ---- a live session never asks
        StubProtocol.reset(status: 200, body: "{}")
        let live = Session(store: MemorySessionStore(Data(WebJSON.encode(.object({
            var r = JSONObject()
            r.set("access_token", .string("good"))
            r.set("refresh_token", .string("r1"))
            r.set("expiresAt", .int(nowMS + 3_600_000))
            r.set("user", .object(JSONObject([("id", .string("u1"))])))
            return r
        }())).utf8)), http: http, clock: { now })
        let cached = try? await live.freshToken()
        report.equal("a live session answers from the record", cached ?? "none", "good")
        report.true("and asks nobody", StubProtocol.calls.isEmpty)

        // ---- single flight
        StubProtocol.reset(status: 200,
                           body: "{\"access_token\":\"once\",\"refresh_token\":\"r2\",\"expires_in\":3600}")
        let shared = expiredSession()
        async let first = try? shared.freshToken()
        async let second = try? shared.freshToken()
        let pair = await (first, second)
        report.equal("two callers, one refresh", String(StubProtocol.calls.count), "1")
        report.equal("and both get the same token",
                     (pair.0 ?? "a") + "/" + (pair.1 ?? "b"), "once/once")

        report.note("auth.js:159-165 drops the session in every case above. "
                    + "An offline-first app must not: that is a sign-out on a train.")
    }

    // MARK: 6 — the microsecond test

    @MainActor
    static func instants(_ web: WebCloud, _ report: Report) {
        report.open("6. updated_at parses to the millisecond Date.parse gives")

        let cases = [
            "2026-09-20T12:34:56.789123+00:00",   // what PostgREST actually renders
            "2026-09-20T12:34:56.789999+00:00",   // truncated, NOT rounded
            "2026-09-20T12:34:56.000001+00:00",
            "2026-09-20T12:34:56.999999+00:00",
            "2026-09-20T12:34:56.100000+00:00",
            "2026-09-20T12:34:56.1+00:00",
            "2026-09-20T12:34:56.12+00:00",
            "2026-09-20T12:34:56.123+00:00",
            "2026-09-20T12:34:56.1234+00:00",
            "2026-09-20T12:34:56+00:00",
            "2026-09-20T12:34:56.789Z",
            "2026-09-20T12:34:56Z",
            "2026-09-20T12:34:56.789123456+00:00",
            "2026-09-20T12:34:56.789123+08:00",
            "2026-09-20T12:34:56.789123-05:00",
            "1999-12-31T23:59:59.999999Z",
            "2026-01-01T00:00:00.000000+00:00",
            "1970-01-01T00:00:00.000000+00:00",
            "",
            "not a date",
            "2026-13-45T99:99:99Z",
        ]

        for s in cases {
            let mine = Supabase.parseTimestamp(s)
            let theirs = (try? web.parse(s)) ?? -1
            report.equal("Date.parse(\(s.isEmpty ? "<empty>" : s))", String(mine), String(theirs))
        }

        /* The whole reason for the truncation, said as the thing it
           decides: `.789999` and `.789000` are the same millisecond, so a
           row at `.789999` does NOT beat a local edit stamped at `.789`. */
        let a = Supabase.parseTimestamp("2026-09-20T12:34:56.789999+00:00")
        let b = Supabase.parseTimestamp("2026-09-20T12:34:56.789000+00:00")
        report.true("a microsecond does not flip last-write-wins", a == b)

        /* And what goes UP: `new Date(ms).toISOString()`, held against
           the real one rather than against a string typed here. */
        for ms in [1_789_000_496_789, 1_789_000_000_000, 1_789_000_000_001,
                   0, 1, 946_684_799_999, 1_609_459_200_000] {
            report.equal("toISOString(\(ms))", Supabase.iso(ms), (try? web.iso(ms)) ?? "<threw>")
            report.equal("toISOString(\(ms)) round trips",
                         String(Supabase.parseTimestamp(Supabase.iso(ms))), String(ms))
        }
    }
}
