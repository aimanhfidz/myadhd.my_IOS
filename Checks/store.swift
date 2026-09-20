/* ============================================================
   Checks/store.swift — every AppStore mutation against app.js's own

   Not an Xcode target. A `swiftc` program that compiles the app
   target's own `MyADHD/Core` sources and `Shared/TaskSnapshot.swift`,
   and then holds `AppStore` against the REAL `app.js` running in
   JavaScriptCore.

       Checks/store.sh

   **How a mutation is compared.** One seed store, byte for byte, into
   both sides: written to a temp `myadhd.v1.json` and read back through
   `AppStore`'s own boot path, and put into `localStorage` and read back
   through `app.js`'s own `load()`. Then the same mutation on each side.
   Then two comparisons:

     1. `JSON.stringify(state)` versus `AppStore.doc.jsonString`, byte
        for byte — so field order, `null`-versus-absent and number
        formatting are all in scope.
     2. the **trail**: which of `cloud.stamp()`, the write, `syncSoon()`
        and `cloud.soon()` ran, in order. This is what proves `save()`
        and `persistOnly()` differ in exactly the way app.js:293-304
        says they do, rather than in a way that only looks right until
        somebody types in a note and the phone rebuilds its reminders
        once per letter.

   Everything the page does is cut out of `app.js` on disk by content —
   never by line number alone, and never retyped. Most of the mutations
   are whole functions (`markDone`, `removeTask`, `pruneDone`,
   `stampTimeOnly`, `touchNote`, `closeNote`, `newNote`, `deleteNote`,
   `settleForOffline`, `save`, `persistOnly`, `load`). Six are statement
   runs inside a DOM handler, and those are cut by their first and last
   line and **wrapped in a function header written here** — the cut text
   is the page's, the header is not:

     `__applyTriage`    app.js:587-602    inside triage()
     `__clearAll`       app.js:1638-1647  inside stepClear()'s third press
     `__editTitle`      app.js:1772-1778  inside editTitle()'s finish()
     `__breakDown`      app.js:1857-1859  inside breakDown()'s try
     `__setQuadrant`    app.js:2849-2853  inside endDrag()
     `__profileName` / `__avatar` / `__signupNo` / `__feedbackSent`
                        the four inline listeners, app.js:5562-5573, 3936, 2705

   Nothing in this file is a hand-written opinion about what app.js
   does. Where a rule could not be run at all it would say so in a
   comment naming the lines; as it turns out, every mutation in scope
   could be run.

   **What is pinned.** `Date` is a Proxy answering one instant for
   `new Date()` and `Date.now()`, and the native side takes the same
   instant as its injected clock. `Math.random` is an LCG; ids that are
   minted (a new note, a new file) are masked on both sides before the
   comparison, because two runs of the same minting never agree on one
   and nothing about the id is a rule. The time zone is set before
   `DayKey` is first touched and before the JSContext exists — one zone
   per process, which is why the shell script runs this three times.

   **The two day rules that are easy to swap, and are tested apart:**
   `pruneDone` counts on the LOCAL day (app.js:361) and
   `sentFeedbackOn` is the UTC one (app.js:2654). The pinned instants
   are chosen so those two answers are DIFFERENT strings, so a check
   that had them the wrong way round could not pass.
   ============================================================ */

import Foundation
import JavaScriptCore

// MARK: - cutting app.js

/// One extracted run of `app.js`, and what has to be in it. Cut by
/// content, so a rename or a move fails the run by name rather than
/// silently sliding onto whatever moved into a line range.
struct Slice {
    var name: String
    var from: String
    var to: String?
    var mustContain: [String] = []
    /// Wrapped in this header when the cut is a statement run out of a
    /// DOM handler rather than a whole function. `nil` for a function.
    var wrapAs: String?

    init(_ name: String, from: String, to: String?, mustContain: [String] = [],
         wrapAs: String? = nil) {
        self.name = name
        self.from = from
        self.to = to
        self.mustContain = mustContain
        self.wrapAs = wrapAs
    }
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

    static func cut(_ lines: [String], _ slice: Slice) throws -> String {
        guard let start = index(lines, containing: slice.from) else {
            throw Failure("app.js no longer has a line containing `\(slice.from)` "
                          + "(slice \(slice.name)) — the port has drifted from its source")
        }
        let end: Int
        if let to = slice.to {
            guard let e = index(lines, containing: to, from: start + 1) else {
                throw Failure("app.js no longer has a line containing `\(to)` after "
                              + "`\(slice.from)` (slice \(slice.name))")
            }
            end = e
        } else {
            end = start + 1
        }
        let body = lines[start..<end].joined(separator: "\n")
        for marker in slice.mustContain where !body.contains(marker) {
            throw Failure("slice \(slice.name) no longer contains `\(marker)` — it has "
                          + "moved out of the run this check cuts")
        }
        guard let header = slice.wrapAs else { return body }
        return header + "\n" + body + "\n}\n"
    }
}

// MARK: - the JavaScript side

final class WebStore {

    let ctx: JSContext
    private var thrown: String?

    /// Every cut this check makes. The order is the order they are
    /// evaluated in; only `state` has to come first, because everything
    /// else is a function declaration and is hoisted into the same
    /// global scope.
    static let slices: [Slice] = [
        Slice("store", from: "let state = {", to: "function repaintLists() {",
              mustContain: ["function load(", "function persistOnly(", "function save(",
                            "const DONE_TTL", "function stampTimeOnly(",
                            "function pruneDone("]),

        Slice("dates", from: "const pad2 = (n) =>", to: "const CATEGORY_LABELS = {",
              mustContain: ["function dayKey(", "function dayForTime(",
                            "function normalizeDay(", "function normalizeTime(",
                            "function timing(", "function normalizeTask("]),

        Slice("ordering", from: "const CATEGORY_LABELS = {", to: "function goToNext() {",
              mustContain: ["const QUADRANTS", "const QUADRANT_KEYS",
                            "function quadrantOf", "function dueAt"]),

        Slice("settle", from: "function settleForOffline(stale) {",
              to: "/* A stale task written back out",
              mustContain: ["t.local = false"]),

        Slice("rows", from: "function removeTask(id, after = goToNext) {",
              to: "async function breakDown(task, ui) {",
              mustContain: ["function removeTask(", "function markDone(",
                            "t.doneAt = Date.now()", "unorphanEvent(gone)"]),

        Slice("feedbackDay", from: "function utcDay(d = new Date()) {",
              to: "function paintFeedback() {",
              mustContain: ["toISOString().slice(0, 10)", "function feedbackSentToday("]),

        Slice("orphans", from: "function orphanEvent(t) {",
              to: "/* save() calls this on every write.",
              mustContain: ["function unorphanEvent(", "state.gcalOrphans.push"]),

        Slice("notes", from: "const BLOCK_TYPES = [", to: "/* The canvas and the rail",
              mustContain: ["function normalizeBlock(", "function normalizeNote(",
                            "function normalizeLook(", "const NOTE_FILE_MAX",
                            "const PAPERS", "const FONTS"]),

        Slice("noteIndex", from: "let openNoteId = null;", to: "/* ---- the index ---- */",
              mustContain: ["function notesByRecent(", "function noteIsBlank(",
                            "function firstLine("]),

        Slice("currentNote", from: "function currentNote() {", to: "function paintNoteEditor() {",
              mustContain: ["openNoteId"]),

        Slice("touchNote", from: "function touchNote(n) {", to: "/* Enter splits the line",
              mustContain: ["n.updatedAt = Date.now()", "persistOnly()"]),

        Slice("remind", from: "function saveRemind() {", to: "/* ---- open, close, new, delete ---- */",
              mustContain: ["function clearRemind(", "n.remindOn = normalizeDay("]),

        Slice("noteLife", from: "function closeNote() {", to: "function showNotes() {",
              mustContain: ["function newNote(", "function deleteNote(",
                            "noteIsBlank(n)", "normalizeNote({})"]),

        // --- the statement runs, wrapped in a header written here ------

        Slice("applyTriage", from: "  // A dump adds to the lists.", to: "  writeBuffer('');",
              mustContain: ["state.tasks.concat(fresh)", "pendingQuadrant", "save();"],
              wrapAs: "function __applyTriage(tasks) {"),

        Slice("clearAll", from: "    const gone = state.tasks.length;", to: "    resetClear();",
              mustContain: ["state.tasks.forEach(orphanEvent)", "state.tasks = [];", "save();"],
              wrapAs: "function __clearAll() {"),

        Slice("editTitle", from: "    const next = input.value.trim();",
              to: "    titleEl.textContent = task.title;",
              mustContain: ["next.slice(0, 160)", "next !== task.title", "save();"],
              wrapAs: "function __editTitle(task, value, commit) { var input = { value: value };"),

        Slice("breakDown", from: "    task.steps = data.steps.slice(0, 7).map(String);",
              to: "    ui.stepText.textContent = task.firstStep;",
              mustContain: ["data.firstStep", "save();"],
              wrapAs: "function __breakDown(task, data) {"),

        /* The page's own toggle. It does NOT call save() itself — the
           write comes from `goToNext()` (app.js:1223), which the harness
           stubs, so the case below says `save()` out loud. One save
           either way; the native one comes from `setView`. */
        Slice("viewToggle", from: "  state.view = state.view === 'matrix' ? 'list' : 'matrix';",
              to: "  keepPlace(goToNext);",
              mustContain: ["state.view"],
              wrapAs: "function __toggleView() {"),

        Slice("setQuadrant", from: "  const to = cell.dataset.quad;", to: "  keepPlace(goToNext);",
              mustContain: ["quadrantOf(task, dayKey())", "task.quadrant = to;", "save();"],
              wrapAs: "function __setQuadrant(task, quad) { var cell = { dataset: { quad: quad } };"),

        Slice("profileName", from: "  state.profile.name = el.nameInput.value.trim().slice(0, 24);",
              to: "  paintProfile();",
              mustContain: ["save();"],
              wrapAs: "function __profileName(value) { el.nameInput.value = value;"),

        Slice("avatar", from: "      state.profile.avatar = face;", to: "      paintProfile();",
              mustContain: ["save();"],
              wrapAs: "function __avatar(face) {"),

        Slice("signupNo", from: "    state.signupOfferHidden = true;", to: "    paintSignupOffer();",
              mustContain: ["save();"],
              wrapAs: "function __signupNo() {"),

        Slice("feedbackSent", from: "      state.sentFeedbackOn = utcDay();", to: "      el.fbInput.value = '';",
              mustContain: ["save();"],
              wrapAs: "function __feedbackSent() {"),
    ]

    init(appJS: String, nowMS: Double) throws {
        let lines = try Extract.lines(of: appJS)
        guard let c = JSContext() else { throw Failure("no JSContext") }
        ctx = c
        ctx.exceptionHandler = { [weak self] _, e in self?.thrown = e?.toString() ?? "unknown" }

        try run(Self.prelude(nowMS: nowMS), "prelude")
        for slice in Self.slices {
            try run(try Extract.cut(lines, slice), "slice \(slice.name)")
        }
        try run(Self.postlude, "postlude")
    }

    @discardableResult
    func run(_ js: String, _ what: String) throws -> JSValue {
        thrown = nil
        let out = ctx.evaluateScript(js)
        if let thrown { throw Failure("\(what): \(thrown)") }
        return out ?? JSValue(undefinedIn: ctx)
    }

    /// `localStorage[STORE_KEY] = json`, a blank `state`, then the
    /// page's own `load()`. The trail is cleared afterwards, so a case
    /// only ever sees what its own mutation did.
    func seed(_ json: String) throws {
        _ = try run("__seed(\(WebJSON.quoted(json)))", "seed")
    }

    var state: String {
        get throws { try run("JSON.stringify(state)", "state").toString() ?? "" }
    }

    /// What `localStorage.setItem` was last handed.
    var written: String? {
        get throws {
            let v = try run("__written()", "written")
            return v.isNull || v.isUndefined ? nil : v.toString()
        }
    }

    var trail: [String] {
        get throws {
            let text = try run("JSON.stringify(__trail)", "trail").toString() ?? "[]"
            return (try JSONValue.parse(text).arrayValue ?? []).compactMap(\.stringValue)
        }
    }

    func string(_ js: String) throws -> String {
        try run(js, js).toString() ?? ""
    }

    /// `Date` pinned, `Math.random` stubbed, and every screen the page
    /// would have painted replaced by something that does nothing.
    /// Nothing here reimplements a rule: each one is a paint, a focus or
    /// a scroll, and the store never reads any of them back.
    static func prelude(nowMS: Double) -> String {
        """
        (function () {
          var Real = Date;
          var FIXED = \(String(format: "%.0f", nowMS));
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
          var seed = 1;
          Math.random = function () {
            seed = (seed * 1103515245 + 12345) % 2147483648;
            return seed / 2147483648;
          };
        })();

        var STORE_KEY = 'myadhd.v1';

        /* The native app IS the shell (design §2.5), so `load()` is given
           the branch the phone takes: a saved 'matrix' is honoured. */
        var IN_SHELL = true;

        /* The four things save() pokes, and the write itself. Each one
           leaves its name in the trail, in the order it ran, which is the
           whole of what this check knows about app.js:293-304. */
        var __trail = [];
        var __store = {};
        var localStorage = {
          getItem: function (k) { return Object.prototype.hasOwnProperty.call(__store, k) ? __store[k] : null; },
          setItem: function (k, v) { __trail.push('write'); __store[k] = String(v); },
          removeItem: function (k) { delete __store[k]; }
        };
        function __written() { return Object.prototype.hasOwnProperty.call(__store, STORE_KEY) ? __store[STORE_KEY] : null; }

        globalThis.window = globalThis;
        globalThis.cloud = {
          stamp: function () { __trail.push('stamp'); },
          soon: function () { __trail.push('cloud'); }
        };
        function syncSoon() { __trail.push('gcal'); }

        /* Every toast with an action is kept, because the Undo behind
           `Done.` and `Removed.` IS the undo path (app.js:1806, 1834) and
           there is nowhere else to reach it from. */
        var __toasts = [];
        function toast(msg, action) { __toasts.push({ msg: msg, action: action || null }); }
        function __undo(i) { __toasts[i].action.fn(); }
        function __toastList() { return JSON.stringify(__toasts.map(function (t) { return t.msg; })); }

        /* Paints. None of them is read back by anything under test.

           `goToNext()` is the one that is not only a paint: the real one
           calls `save()` on its way through (app.js:1223), so every
           mutation that ends `after()` writes the store twice on the web.
           That second write belongs to the lists screen repainting and
           not to the mutation — natively it lives in the UI layer
           (design §2.3) — so the stub does not do it, and the trail this
           check compares is the mutation's own. */
        function goToNext() {}
        function keepPlace(fn) { if (fn) fn(); }
        function repaintLists() {}
        function show() {}
        function renderNotes() {}
        function paintProfile() {}
        function paintSignupOffer() {}
        function paintFeedback() {}
        function paintNoteRemind() {}
        function paintNoteEditor() {}
        function focusBlock() {}
        function resetClear() {}
        function openNote(id) { openNoteId = id; }
        function writeBuffer() {}

        /* `el` on demand: one memoised fake element per id, so a handler
           that reads `el.remDay.value` gets what the case put there and a
           handler that only paints gets something harmless. */
        var __els = {};
        function __mkEl() {
          return {
            value: '', textContent: '', href: '', disabled: false,
            classList: { add: function () {}, remove: function () {}, toggle: function () {} },
            focus: function () {}, select: function () {}, appendChild: function () {},
            addEventListener: function () {}, setAttribute: function () {},
            querySelector: function () { return null; }, style: {}
          };
        }
        globalThis.el = new Proxy({}, {
          get: function (_, k) {
            if (!__els[k]) __els[k] = __mkEl();
            return __els[k];
          }
        });
        """
    }

    static let postlude = """
    /* The blank store, captured before anything has been loaded into it,
       so every seed starts from the literal at app.js:220-256 rather than
       from whatever the last case left behind. `load()` assigns onto the
       live object, so this has to be a copy. */
    var __BLANK = JSON.stringify(state);

    function __seed(json) {
      state = JSON.parse(__BLANK);
      __store[STORE_KEY] = json;
      load();
      __trail = [];
      __toasts = [];
      pendingQuadrant = null;
      openNoteId = null;
    }

    function __byId(id) { return state.tasks.find(function (t) { return t.id === id; }) || null; }
    function __noteById(id) { return state.notes.find(function (n) { return n.id === id; }) || null; }
    """
}

// MARK: - the native side

/// One `AppStore` over a real file in a real temp directory, booted the
/// way the app boots it, with the same trail the web side keeps.
@MainActor
final class NativeStore {

    let dir: URL
    let file: StoreFile
    let store: AppStore
    var trail: [String] = []
    /// What the last write was handed, for the assertion that the bytes
    /// on disk are the bytes the document says it is.
    var lastWritten: String?

    init(seed: String, now: Date) {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("myadhd-store-check-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = StoreFile(directory: dir, clock: { now })
        try? Data(seed.utf8).write(to: dir.appendingPathComponent(StoreFile.documentName))

        store = AppStore(file: file, inShell: true, clock: { now })

        store.stampForCloud = { [weak self] in self?.trail.append("stamp") }
        store.scheduleCalendarSync = { [weak self] in self?.trail.append("gcal") }
        store.scheduleCloudSync = { [weak self] in self?.trail.append("cloud") }
        store.didWrite = { [weak self] text in
            self?.trail.append("write")
            self?.lastWritten = text
        }
    }

    var state: String { store.doc.jsonString }

    /// The bytes that actually landed, once the write queue has drained.
    func settled() -> String? {
        file.flush()
        return try? String(contentsOf: file.documentURL, encoding: .utf8)
    }

    func clean() {
        file.flush()
        try? FileManager.default.removeItem(at: dir)
    }
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
    func equal(_ what: String, _ got: String, _ want: String) -> Bool {
        checks += 1
        if got == want {
            print("    ok    \(what)")
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

// MARK: - the fixtures

/// One task, written the way `normalizeTask` writes one: every key
/// present, in its literal order (app.js:1044-1068).
struct T {
    var id: String
    var title: String
    var minutes = 20
    var energy = "medium"
    var urgency = 3
    var importance = "low"
    var quadrant: String?
    var firstStep = "Open it and look at it for 2 minutes."
    var category = "general"
    var when: String?
    var at: String?
    var steps: [String]?
    var local = false
    var gcal: String?
    var done = false
    var doneAt: Int?
    var updatedAt: Int?
    /// Keys a build this one has never heard of would have written.
    var unknown: [(String, JSONValue)] = []
    /// Keys to leave out entirely — an old row that predates them.
    var absent: Set<String> = []

    var json: JSONValue {
        var o = JSONObject()
        func put(_ k: String, _ v: JSONValue) { if !absent.contains(k) { o[k] = v } }
        put("id", .string(id))
        put("title", .string(title))
        put("minutes", .int(minutes))
        put("energy", .string(energy))
        put("urgency", .int(urgency))
        put("importance", .string(importance))
        put("quadrant", quadrant.map { .string($0) } ?? .null)
        put("firstStep", .string(firstStep))
        put("category", .string(category))
        put("when", when.map { .string($0) } ?? .null)
        put("at", at.map { .string($0) } ?? .null)
        put("steps", steps.map { .array($0.map { .string($0) }) } ?? .null)
        put("local", .bool(local))
        put("gcal", gcal.map { .object(JSONObject([("id", .string($0)), ("sig", .string("s.1"))])) } ?? .null)
        put("done", .bool(done))
        put("doneAt", doneAt.map { .int($0) } ?? .null)
        put("skipped", .bool(false))
        for (k, v) in unknown { o[k] = v }
        if let updatedAt { o["updatedAt"] = .int(updatedAt) }
        return .object(o)
    }
}

enum Seeds {

    /// The whole store, in the key order of the literal at app.js:222-256.
    static func store(tasks: [T] = [], notes: [JSONValue] = [],
                      profile: (String, String) = ("", "🧔🏻"),
                      sentFeedbackOn: String? = nil,
                      signupOfferHidden: Bool = false,
                      view: String = "list",
                      gcalOrphans: [String] = [],
                      doneCounts: [(String, Int)] = [],
                      extra: [(String, JSONValue)] = []) -> String
    {
        var o = JSONObject()
        o["tasks"] = .array(tasks.map(\.json))
        o["notes"] = .array(notes)
        o["profile"] = .object(JSONObject([("name", .string(profile.0)),
                                           ("avatar", .string(profile.1))]))
        o["sentFeedbackOn"] = sentFeedbackOn.map { .string($0) } ?? .null
        o["signupOfferHidden"] = .bool(signupOfferHidden)
        o["view"] = .string(view)
        o["gcalOrphans"] = .array(gcalOrphans.map { .string($0) })
        var counts = JSONObject()
        for (k, n) in doneCounts { counts[k] = .int(n) }
        o["doneCounts"] = .object(counts)
        for (k, v) in extra { o[k] = v }
        return WebJSON.encode(.object(o))
    }

    /// A note as `normalizeNote` writes one.
    static func note(id: String, title: String = "", blocks: [String] = [""],
                     remindOn: String? = nil, remindAt: String? = nil,
                     repeatRule: String = "", createdAt: Int, updatedAt: Int) -> JSONValue
    {
        var o = JSONObject()
        o["id"] = .string(id)
        o["title"] = .string(title)
        o["body"] = .string(blocks.joined(separator: "\n"))
        o["blocks"] = .array(blocks.map { text in
            .object(JSONObject([("type", .string("p")), ("text", .string(text)),
                                ("marks", .array([])), ("done", .bool(false)),
                                ("align", .string("left"))]))
        })
        o["remindOn"] = remindOn.map { .string($0) } ?? .null
        o["remindAt"] = remindAt.map { .string($0) } ?? .null
        o["repeat"] = .string(repeatRule)
        o["files"] = .array([])
        o["look"] = .object(JSONObject([("paper", .string("lavender")),
                                        ("font", .string("baloo"))]))
        o["createdAt"] = .int(createdAt)
        o["updatedAt"] = .int(updatedAt)
        return .object(o)
    }
}

// MARK: - the run

@main
struct StoreChecks {

    static func main() {
        MainActor.assumeIsolated { run() }
    }

    @MainActor
    static func run() {
        var args = Array(CommandLine.arguments.dropFirst())
        func take(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let v = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return v
        }
        let tz = take("--tz") ?? "UTC"
        let nowMS = Double(take("--now") ?? "") ?? 0
        let appJS = take("--app-js") ?? "/Users/User/Desktop/Claude Code/My.adhd/app.js"

        /* Before anything reads a date: `DayKey.calendar` captures
           `.current` the first time it is touched and keeps it, and
           JavaScriptCore asks the C library, so both have to be set now. */
        guard let zone = TimeZone(identifier: tz) else {
            FileHandle.standardError.write(Data("unknown time zone \(tz)\n".utf8))
            exit(2)
        }
        NSTimeZone.default = zone
        setenv("TZ", tz, 1)
        tzset()

        let now = Date(timeIntervalSince1970: nowMS / 1000)
        let stamp = ISO8601DateFormatter()
        stamp.timeZone = zone
        stamp.formatOptions = [.withInternetDateTime]

        print("store")
        print("  zone     \(tz)")
        print("  pinned   \(stamp.string(from: now))")
        print("  local    \(WebDates.dayKey(now))    (what pruneDone counts on)")
        print("  utc      \(WebDates.utcDay(now))    (what sentFeedbackOn is)")
        print("  app.js   \(appJS)")

        let web: WebStore
        do {
            web = try WebStore(appJS: appJS, nowMS: nowMS)
        } catch {
            FileHandle.standardError.write(Data("cannot load app.js: \(error)\n".utf8))
            exit(2)
        }

        let r = Report()
        let h = Harness(web: web, now: now, report: r)

        h.dayRules()
        h.writeIntents()
        h.markingDone()
        h.removing()
        h.clearing()
        h.rewording()
        h.breakingDown()
        h.quadrants()
        h.triage()
        h.resorting()
        h.pruning()
        h.stampingTimeOnly()
        h.notes()
        h.profileAndFlags()
        h.fixtures()

        print("\n---")
        if r.failures.isEmpty {
            print("store OK — \(r.checks) comparisons, all matched app.js")
            exit(0)
        }
        print("store FAILED — \(r.failures.count) of \(r.checks) comparisons disagreed:")
        for f in r.failures { print("  - \(f)") }
        exit(1)
    }
}

// MARK: - the cases

@MainActor
final class Harness {

    let web: WebStore
    let now: Date
    let r: Report
    let nowMS: Int

    init(web: WebStore, now: Date, report: Report) {
        self.web = web
        self.now = now
        self.r = report
        self.nowMS = Int((now.timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// How the document that comes out is allowed to relate to the one
    /// app.js wrote. Anything other than `.identical` is a divergence
    /// this port makes on purpose, and each one carries the reason it is
    /// allowed — a check that hid one would be worse than no check.
    enum Expect {
        /// Byte for byte. The default, and what almost everything is.
        case identical
        /// Same values, different key order: the page appends a key that
        /// was absent where it lands, and this side writes it in
        /// `normalizeTask`'s place (design §2.5). Compared after both
        /// sides go back through `StoreDocument.load`, which reorders
        /// neither values nor unknown keys — only positions.
        case sameValues(String)
        /// The page's cap cut a surrogate pair in half and kept the
        /// orphan; a Swift `String` cannot hold one, so `Normalize.slice`
        /// takes one unit less (Normalize.swift:53-56). The native text
        /// must be the page's with exactly that trailing half removed —
        /// nothing else may move.
        case loneSurrogate(String)
    }

    /// Seed both sides, hand them to `body`, then compare the whole
    /// document byte for byte and the trail step for step.
    ///
    /// `maskIDs` blanks minted ids on both sides — a new note's `n_…`
    /// never agrees between two runs of the same minting, and nothing
    /// about the id is a rule.
    ///
    /// `trailDiffers` pins a trail that is deliberately not the page's,
    /// with both sides written down: the check fails if EITHER moves.
    func pair(_ name: String, _ seed: String, maskIDs: Bool = false,
              expect: Expect = .identical,
              trailDiffers: (native: String, web: String, why: String)? = nil,
              _ body: (NativeStore) throws -> String)
    {
        r.open(name)
        let native = NativeStore(seed: seed, now: now)
        defer { native.clean() }
        do {
            try web.seed(seed)

            /* The precondition. If the two sides do not agree about the
               store before the mutation, nothing after it means anything. */
            guard r.equal("loads the same", mask(native.state, maskIDs),
                          mask(try web.state, maskIDs)) else { return }

            let js = try body(native)
            try web.run(js, "mutation \(name)")

            let mine = mask(native.state, maskIDs)
            let theirs = mask(try web.state, maskIDs)
            compare("document", mine, theirs, expect)

            let myTrail = native.trail.joined(separator: ",")
            let theirTrail = (try web.trail).joined(separator: ",")
            if let trailDiffers {
                r.note(trailDiffers.why)
                r.equal("trail, native side pinned", myTrail, trailDiffers.native)
                r.equal("trail, the page's pinned", theirTrail, trailDiffers.web)
            } else {
                r.equal("trail", myTrail, theirTrail)
            }

            /* The bytes on disk are the bytes the document says it is —
               and the page's own `localStorage` write is the same string. */
            if let written = native.lastWritten {
                r.equal("written == document", mask(written, maskIDs), mine)
                compare("on disk", mask(native.settled() ?? "(nothing)", maskIDs),
                        mask(try web.written ?? "(nothing)", maskIDs), expect)
            }
        } catch {
            r.equal("ran", "\(error)", "no error")
        }
    }

    private func compare(_ what: String, _ mine: String, _ theirs: String, _ expect: Expect) {
        switch expect {
        case .identical:
            r.equal(what, mine, theirs)
        case .sameValues(let why):
            r.note(why)
            r.equal("\(what) (values, key order normalised)",
                    StoreDocument.load(text: mine).jsonString,
                    StoreDocument.load(text: theirs).jsonString)
        case .loneSurrogate(let why):
            r.note(why)
            r.equal("\(what) (the page's, less the orphaned surrogate)",
                    mine, Harness.dropTrailingLoneSurrogates(theirs))
        }
    }

    /// `"…bbb\ud83d"` -> `"…bbb"`. Only a high surrogate immediately
    /// before the closing quote of a JSON string — which is the only
    /// place a cap can leave one.
    static func dropTrailingLoneSurrogates(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\\\ud[89ab][0-9a-fA-F]{2}(?=\")")
        else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                           withTemplate: "")
    }

    /// A JSON array of tasks, as `TaskItem`s.
    static func tasks(from text: String) -> [TaskItem] {
        guard let parsed = try? JSONValue.parse(text), let a = parsed.arrayValue else { return [] }
        return a.compactMap { TaskItem($0) }
    }

    /// `"t_ab12cd3"` -> `"t_×"`, on both sides.
    func mask(_ s: String, _ on: Bool) -> String {
        guard on else { return s }
        let pattern = "\"([tnf])_[0-9a-z]{1,12}\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                           withTemplate: "\"$1_×\"")
    }

    // MARK: fixtures used by more than one case

    var open1: T { T(id: "t_open001", title: "call the dentist", category: "health",
                     when: "2026-03-10", at: "09:30") }
    var open2: T { T(id: "t_open002", title: "pay rent", urgency: 5, importance: "high",
                     category: "money", gcal: "ev_rent") }
    var open3: T { T(id: "t_open003", title: "sort the bins", local: true) }
    var done1: T { T(id: "t_done001", title: "buy milk", done: true, doneAt: 0) }

    func basic(_ doneAtOffset: Int = -3600_000) -> String {
        var d = done1
        d.doneAt = nowMS + doneAtOffset
        return Seeds.store(tasks: [open1, open2, open3, d], gcalOrphans: ["ev_old"])
    }

    // MARK: - the two day rules

    /// `pruneDone` counts on the LOCAL day and `sentFeedbackOn` is the
    /// UTC one. Held against the page's own `dayKey()` and `utcDay()`
    /// over a year of instants, in this process's zone.
    func dayRules() {
        r.open("the day rules (app.js:648, 2654)")
        var localBad = 0, utcBad = 0, n = 0
        var t = now.addingTimeInterval(-200 * 86_400)
        while t < now.addingTimeInterval(200 * 86_400) {
            let ms = (t.timeIntervalSince1970 * 1000).rounded(.down)
            let js = (try? web.string("JSON.stringify([dayKey(new Date(\(String(format: "%.0f", ms)))), "
                                      + "utcDay(new Date(\(String(format: "%.0f", ms)))) ])")) ?? ""
            let pair = (try? JSONValue.parse(js).arrayValue ?? []) ?? []
            let wantLocal = pair.first?.stringValue ?? "?"
            let wantUTC = pair.last?.stringValue ?? "?"
            if WebDates.dayKey(t) != wantLocal { localBad += 1 }
            if WebDates.utcDay(t) != wantUTC { utcBad += 1 }
            n += 1
            t = t.addingTimeInterval(86_400 / 3 * 1.37)   // a drifting time of day
        }
        r.equal("dayKey over \(n) instants", "\(localBad) differ", "0 differ")
        r.equal("utcDay over \(n) instants", "\(utcBad) differ", "0 differ")
        if WebDates.dayKey(now) == WebDates.utcDay(now) {
            r.note("local and UTC agree at this instant — the swap test is weak here")
        } else {
            r.note("local \(WebDates.dayKey(now)) != utc \(WebDates.utcDay(now)) "
                   + "— a swapped rule cannot pass")
        }
    }

    // MARK: - save() versus persistOnly()

    /// app.js:293-304. The trail is the assertion; the two cases exist
    /// so that the difference between them is visible in one place.
    func writeIntents() {
        pair("persistOnly writes and nothing else", basic()) { n in
            n.store.persistOnly()
            return "persistOnly();"
        }
        pair("save stamps, writes, then pokes both timers", basic()) { n in
            n.store.save()
            return "save();"
        }
    }

    // MARK: - markDone / undoDone

    func markingDone() {
        pair("markDone stamps doneAt in epoch ms", basic()) { n in
            n.store.markDone("t_open001")
            return "markDone('t_open001');"
        }
        pair("markDone on an already-done task", basic()) { n in
            n.store.markDone("t_done001")
            return "markDone('t_done001');"
        }
        pair("markDone on an id that is not there", basic()) { n in
            n.store.markDone("t_nope")
            return "markDone('t_nope');"
        }
        pair("undoDone clears doneAt to null", basic()) { n in
            n.store.markDone("t_open002")
            n.store.undoDone("t_open002")
            return "markDone('t_open002'); __undo(0);"
        }
        /* A row saved before `doneAt` existed — a real shape, since
           `doneAt` arrived after the store did. */
        var old = open1
        old.absent = ["doneAt"]
        pair("markDone on a pre-doneAt row", Seeds.store(tasks: [old]),
             expect: .sameValues("the page appends `doneAt` after `skipped`, where the "
                                 + "assignment lands (app.js:1832); this side writes it in "
                                 + "normalizeTask's place (design §2.5). Same values, one "
                                 + "key in a different position — and the reason "
                                 + "LegacyImport reseals the cloud sigs from the native "
                                 + "encoding instead of copying the page's.")) { n in
            n.store.markDone("t_open001")
            return "markDone('t_open001');"
        }
    }

    // MARK: - removeTask / undoRemove

    func removing() {
        pair("removeTask takes the row and orphans its event", basic()) { n in
            _ = n.store.removeTask("t_open002")
            return "removeTask('t_open002');"
        }
        pair("undoRemove puts it back at its own index", basic()) { n in
            if let gone = n.store.removeTask("t_open002") { n.store.undoRemove(gone) }
            return "removeTask('t_open002'); __undo(0);"
        }
        pair("undo after a second removal shifted the list", basic()) { n in
            let first = n.store.removeTask("t_open001")
            _ = n.store.removeTask("t_open003")
            if let first { n.store.undoRemove(first) }
            return "removeTask('t_open001'); removeTask('t_open003'); __undo(0);"
        }
        pair("undo of a row whose event is already on death row", basic()) { n in
            if let gone = n.store.removeTask("t_open002") { n.store.undoRemove(gone) }
            return "removeTask('t_open002'); __undo(0);"
        }
        pair("removeTask on an id that is not there", basic()) { n in
            _ = n.store.removeTask("t_nope")
            return "removeTask('t_nope');"
        }
    }

    // MARK: - clearAll

    func clearing() {
        pair("clearAll empties the lists and keeps the notes", basic()) { n in
            _ = n.store.clearAll()
            return "__clearAll();"
        }
        pair("clearAll on an already empty store", Seeds.store()) { n in
            _ = n.store.clearAll()
            return "__clearAll();"
        }
    }

    // MARK: - editTitle

    func rewording() {
        let cases: [(String, String)] = [
            ("plain", "call the dentist back"),
            ("trimmed", "   call the dentist back   "),
            ("unchanged", "call the dentist"),
            ("unchanged but padded", "  call the dentist  "),
            ("empty", ""),
            ("whitespace only", "     "),
            ("over 160", String(repeating: "a", count: 200)),
            ("over 160 landing between whole emoji", String(repeating: "b", count: 158) + "🙂🙂"),
            ("unicode", "café — naïve — 日本語"),
            ("a tab and a non-breaking space", "\t call\u{00A0}the vet \u{2003}"),
        ]
        for (label, raw) in cases {
            pair("editTitle \(label)", basic()) { n in
                _ = n.store.editTitle("t_open001", to: raw)
                return "__editTitle(__byId('t_open001'), \(WebJSON.quoted(raw)), true);"
            }
        }
        /* The one place the two cannot agree, pinned rather than hidden:
           `'b'×159 + '👩‍👩‍👧'` is 170 UTF-16 units, so slice(0, 160) lands
           INSIDE the first surrogate pair. */
        pair("editTitle over 160 cutting a surrogate pair in half", basic(),
             expect: .loneSurrogate("the page keeps the orphaned high surrogate; a Swift "
                                    + "String cannot hold one, so Normalize.slice takes one "
                                    + "unit less (Normalize.swift:53-56). The two differ by "
                                    + "exactly that half and by nothing else.")) { n in
            let raw = String(repeating: "b", count: 159) + "👩‍👩‍👧"
            _ = n.store.editTitle("t_open001", to: raw)
            return "__editTitle(__byId('t_open001'), \(WebJSON.quoted(raw)), true);"
        }
        pair("editTitle on an id that is not there", basic()) { n in
            _ = n.store.editTitle("t_nope", to: "whatever")
            return "var t = __byId('t_nope'); if (t) __editTitle(t, 'whatever', true);"
        }
    }

    // MARK: - breakDown apply

    func breakingDown() {
        let ten = (1...10).map { "step \($0)" }
        pair("breakDown keeps seven steps", basic()) { n in
            n.store.applyBreakdown("t_open002", steps: ten, firstStep: "Open the bank app.")
            return "__breakDown(__byId('t_open002'), { steps: \(WebJSON.encode(.array(ten.map { .string($0) }))), "
                 + "firstStep: 'Open the bank app.' });"
        }
        pair("breakDown with no firstStep leaves the line alone", basic()) { n in
            n.store.applyBreakdown("t_open002", steps: ["one", "two"], firstStep: nil)
            return "__breakDown(__byId('t_open002'), { steps: ['one','two'] });"
        }
        pair("breakDown with an empty firstStep leaves the line alone", basic()) { n in
            n.store.applyBreakdown("t_open002", steps: ["one"], firstStep: "")
            return "__breakDown(__byId('t_open002'), { steps: ['one'], firstStep: '' });"
        }
    }

    // MARK: - the matrix

    func quadrants() {
        /* `t_open002` has urgency 5 and importance high, so it derives to
           'do'. Dropping it on 'do' is the silent no-op (app.js:2851). */
        pair("setQuadrant onto the derived one is a no-op", basic()) { n in
            _ = n.store.moveToQuadrant("t_open002", to: "do")
            return "__setQuadrant(__byId('t_open002'), 'do');"
        }
        pair("setQuadrant somewhere else writes", basic()) { n in
            _ = n.store.moveToQuadrant("t_open002", to: "delegate")
            return "__setQuadrant(__byId('t_open002'), 'delegate');"
        }
        pair("setQuadrant onto a placement already made", basic()) { n in
            _ = n.store.moveToQuadrant("t_open002", to: "drop")
            _ = n.store.moveToQuadrant("t_open002", to: "drop")
            return "__setQuadrant(__byId('t_open002'), 'drop'); __setQuadrant(__byId('t_open002'), 'drop');"
        }
        pair("setQuadrant on an undated, unimportant row", basic()) { n in
            _ = n.store.moveToQuadrant("t_open003", to: "plan")
            return "__setQuadrant(__byId('t_open003'), 'plan');"
        }
        pair("the view toggle is persisted", basic()) { n in
            n.store.toggleView()
            /* `save()` is spelled out because the page's comes from
               `goToNext()` — see the prelude. */
            return "__toggleView(); save();"
        }
        pair("the view toggle is a no-op when it is already there",
             Seeds.store(tasks: [open1], view: "matrix")) { n in
            n.store.setView("matrix")
            return ""
        }
    }

    // MARK: - a dump landing

    func triage() {
        /* The incoming tasks are minted by the page's own
           `normalizeTask`, once, and handed to both sides — so the ids
           are the same on both and the comparison is about what the
           store does with them, not about what minted them. */
        func incoming(_ specs: String) -> (swift: [TaskItem], js: String) {
            let text = (try? web.string("JSON.stringify((\(specs)).map(normalizeTask))")) ?? "[]"
            return (Harness.tasks(from: text), text)
        }

        let dupes = incoming("""
        [{ title: 'call the dentist' },
         { title: 'CALL THE DENTIST  ' },
         { title: 'buy milk' },
         { title: 'water the plants' },
         { title: 'water the plants' }]
        """)
        pair("applyTriage dedupes against OPEN titles only", basic()) { n in
            _ = n.store.applyTriage(dupes.swift)
            return "__applyTriage(JSON.parse(\(WebJSON.quoted(dupes.js))));"
        }

        let two = incoming("[{ title: 'ring the vet' }, { title: 'book the car in' }]")
        pair("applyTriage pins the pending quadrant and clears it", basic()) { n in
            n.store.pendingQuadrant = "delegate"
            _ = n.store.applyTriage(two.swift)
            r.equal("pendingQuadrant cleared", n.store.pendingQuadrant ?? "nil", "nil")
            return "pendingQuadrant = 'delegate'; __applyTriage(JSON.parse(\(WebJSON.quoted(two.js))));"
        }
        pair("applyTriage with nothing new", basic()) { n in
            _ = n.store.applyTriage([])
            return "__applyTriage([]);"
        }
        let unicode = incoming("[{ title: 'ÅNGSTRÖM report' }, { title: 'ångström report' }]")
        pair("applyTriage folds case the way the page folds it", basic()) { n in
            _ = n.store.applyTriage(unicode.swift)
            return "__applyTriage(JSON.parse(\(WebJSON.quoted(unicode.js))));"
        }
    }

    // MARK: - re-sorting the offline guesses

    func resorting() {
        pair("settleForOffline drops the provisional flag", basic()) { n in
            n.store.settleForOffline(["t_open003"])
            return "settleForOffline([__byId('t_open003')]);"
        }
        pair("applyResort takes the stale out and puts the fresh on the end", basic()) { n in
            let fresh = (try? web.string("JSON.stringify([{title:'sort the bins'},{title:'order bin bags'}].map(normalizeTask))")) ?? "[]"
            n.store.applyResort(staleIDs: ["t_open003"], fresh: Harness.tasks(from: fresh))
            return """
            var fresh = JSON.parse(\(WebJSON.quoted(fresh)));
            var staleIds = new Set(['t_open003']);
            state.tasks = state.tasks.filter(function (t) { return !staleIds.has(t.id); }).concat(fresh);
            save();
            """
        }
        r.note("applyResort's own lines are app.js:1678-1680, inside resortLocal()'s "
               + "await — the two statements are reproduced in the case above because "
               + "the surrounding function cannot run without a fetch")
    }

    // MARK: - pruneDone

    func pruning() {
        let ttl = AppStore.doneTTL

        var fresh = done1; fresh.doneAt = nowMS - 1000
        var edge = T(id: "t_edge", title: "just inside", done: true, doneAt: nowMS - ttl + 1)
        var onTheNose = T(id: "t_nose", title: "exactly a week", done: true, doneAt: nowMS - ttl)
        var stale = T(id: "t_stale", title: "long gone", gcal: "ev_stale",
                      done: true, doneAt: nowMS - ttl - 86_400_000)
        var unstamped = T(id: "t_nostamp", title: "done before doneAt existed", done: true)
        unstamped.absent = ["doneAt"]
        edge.category = "health"; onTheNose.category = "health"; stale.category = "health"

        pair("pruneDone: the TTL boundary, the stamp and the count",
             Seeds.store(tasks: [open1, fresh, edge, onTheNose, stale, unstamped]),
             expect: .sameValues("`t_nostamp` had no `doneAt`; the page appends the stamp "
                                 + "at the end of the row (app.js:353) and this side writes "
                                 + "it in normalizeTask's place (design §2.5). Values, "
                                 + "counts and survivors are compared in full.")) { n in
            _ = n.store.pruneDone()
            return "pruneDone();"
        }

        pair("pruneDone counts on the LOCAL day",
             Seeds.store(tasks: [stale])) { n in
            _ = n.store.pruneDone()
            return "pruneDone();"
        }

        pair("pruneDone increments a day that is already counted",
             Seeds.store(tasks: [stale],
                         doneCounts: [(WebDates.dayKey(Date(timeIntervalSince1970: Double(stale.doneAt!) / 1000)), 4)])) { n in
            _ = n.store.pruneDone()
            return "pruneDone();"
        }

        /* 402 days in, shuffled, plus one more falling out: the oldest
           three go and the survivors keep their INSERTION order, not the
           sorted one (app.js:369-370). */
        var days: [(String, Int)] = []
        var d = Date(timeIntervalSince1970: now.timeIntervalSince1970 - 500 * 86_400)
        var keys: [String] = []
        for _ in 0..<402 {
            keys.append(WebDates.dayKey(d))
            d = d.addingTimeInterval(86_400)
        }
        var seed: UInt64 = 0xC0FFEE
        for i in stride(from: keys.count - 1, to: 0, by: -1) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let j = Int(seed >> 33) % (i + 1)
            keys.swapAt(i, j)
        }
        for (i, k) in keys.enumerated() { days.append((k, i % 7 + 1)) }
        pair("pruneDone bounds doneCounts at 400 keys, oldest first",
             Seeds.store(tasks: [stale], doneCounts: days)) { n in
            _ = n.store.pruneDone()
            return "pruneDone();"
        }

        pair("pruneDone with nothing to do writes nothing",
             Seeds.store(tasks: [open1, fresh])) { n in
            _ = n.store.pruneDone()
            return "pruneDone();"
        }

        pair("pruneDone orphans the events of the rows it drops",
             Seeds.store(tasks: [stale], gcalOrphans: ["ev_stale"])) { n in
            _ = n.store.pruneDone()
            return "pruneDone();"
        }
    }

    // MARK: - stampTimeOnly

    func stampingTimeOnly() {
        var timeOnly = T(id: "t_time", title: "eat", at: "08:00")
        var timeOnlyLate = T(id: "t_time2", title: "call", at: "23:59")
        var doneWithTime = T(id: "t_time3", title: "gym", at: "06:00", done: true, doneAt: nowMS)
        var dated = T(id: "t_time4", title: "dentist", when: "2026-03-10", at: "09:00")
        timeOnly.category = "food"; timeOnlyLate.category = "home"
        doneWithTime.category = "health"; dated.category = "health"

        pair("stampTimeOnly gives a bare time its day",
             Seeds.store(tasks: [timeOnly, timeOnlyLate, doneWithTime, dated])) { n in
            _ = n.store.stampTimeOnly()
            return "stampTimeOnly();"
        }
        pair("stampTimeOnly is idempotent",
             Seeds.store(tasks: [timeOnly])) { n in
            _ = n.store.stampTimeOnly()
            _ = n.store.stampTimeOnly()
            return "stampTimeOnly(); stampTimeOnly();"
        }
        pair("stampTimeOnly with nothing to stamp writes nothing",
             Seeds.store(tasks: [dated])) { n in
            _ = n.store.stampTimeOnly()
            return "stampTimeOnly();"
        }
        pair("boot order: pruneDone then stampTimeOnly (design §3.1)",
             Seeds.store(tasks: [timeOnly, T(id: "t_old", title: "gone",
                                             done: true, doneAt: nowMS - AppStore.doneTTL - 1)])) { n in
            _ = n.store.pruneDone()
            _ = n.store.stampTimeOnly()
            return "pruneDone(); stampTimeOnly();"
        }
    }

    // MARK: - notes

    func notes() {
        let a = Seeds.note(id: "n_aaa0001", title: "shopping", blocks: ["milk", "bread"],
                           createdAt: nowMS - 900_000, updatedAt: nowMS - 900_000)
        let b = Seeds.note(id: "n_bbb0002", title: "", blocks: [""],
                           createdAt: nowMS - 600_000, updatedAt: nowMS - 600_000)
        let c = Seeds.note(id: "n_ccc0003", title: "ideas", blocks: ["one"],
                           remindOn: "2026-04-01", remindAt: "09:00", repeatRule: "daily",
                           createdAt: nowMS - 300_000, updatedAt: nowMS - 300_000)
        let seed = Seeds.store(tasks: [open1], notes: [a, b, c])

        pair("newNote appends one empty paragraph and saves", seed, maskIDs: true) { n in
            _ = n.store.newNote()
            return "newNote();"
        }
        pair("touchNote regenerates the body and persists only", seed) { n in
            n.store.editNote("n_aaa0001") { note in
                note.blocks[0].text = "milk and eggs"
            }
            return """
            var n = __noteById('n_aaa0001');
            n.blocks[0].text = 'milk and eggs';
            touchNote(n);
            """
        }
        pair("the title is the note's own field, not a block", seed) { n in
            n.store.editNote("n_aaa0001") { note in note.title = "big shop" }
            return "var n = __noteById('n_aaa0001'); n.title = 'big shop'; touchNote(n);"
        }
        pair("closeNote deletes a note nobody typed into", seed) { n in
            n.store.closeNote("n_bbb0002")
            return "openNoteId = 'n_bbb0002'; closeNote();"
        }
        pair("closeNote keeps one that has words in it", seed) { n in
            n.store.closeNote("n_aaa0001")
            return "openNoteId = 'n_aaa0001'; closeNote();"
        }
        /* A paper colour or a reminder alone does not save a note
           (app.js:4373-4375) — blankness is title, body and files only. */
        let looksOnly = Seeds.note(id: "n_look001", title: "", blocks: [""],
                                   remindOn: "2026-04-01", remindAt: "10:00",
                                   createdAt: nowMS, updatedAt: nowMS)
        pair("a reminder alone does not make a note", Seeds.store(notes: [looksOnly])) { n in
            n.store.closeNote("n_look001")
            return "openNoteId = 'n_look001'; closeNote();"
        }
        pair("deleteNote and its Undo put it back at its index", seed) { n in
            if let gone = n.store.deleteNote("n_bbb0002") { n.store.undoDeleteNote(gone) }
            return "openNoteId = 'n_bbb0002'; deleteNote(); __undo(0);"
        }
        pair("deleteNote alone", seed) { n in
            _ = n.store.deleteNote("n_ccc0003")
            return "openNoteId = 'n_ccc0003'; deleteNote();"
        }
        pair("the reminder fields save rather than persist", seed,
             trailDiffers: (native: "stamp,write,gcal,cloud",
                            web: "write,stamp,write,gcal,cloud",
                            why: "saveRemind() calls touchNote() and THEN save() "
                               + "(app.js:4922-4923), so the page writes twice for one "
                               + "press; `saveNote` folds the body refresh and the stamp "
                               + "into the one save. Same document, one fewer write.")) { n in
            n.store.saveNote("n_aaa0001") { note in
                note.remindOn = Normalize.normalizeDay("2026-05-05")
                note.remindAt = Normalize.normalizeTime("07:15")
                note.repeatRule = "weekly"
            }
            return """
            openNoteId = 'n_aaa0001';
            el.remDay.value = '2026-05-05'; el.remTime.value = '07:15'; el.remRepeat.value = 'weekly';
            saveRemind();
            """
        }
        pair("clearing the reminder clears the time and the repeat", seed,
             trailDiffers: (native: "stamp,write,gcal,cloud",
                            web: "write,stamp,write,gcal,cloud",
                            why: "clearRemind() is touchNote() then save() as well "
                               + "(app.js:4936-4937).")) { n in
            n.store.saveNote("n_ccc0003") { note in
                note.remindOn = nil
                note.remindAt = nil
                note.repeatRule = ""
            }
            return "openNoteId = 'n_ccc0003'; clearRemind();"
        }

        // The index order, which is a read rather than a write.
        r.open("notesByRecent")
        do {
            try web.seed(seed)
            let native = NativeStore(seed: seed, now: now)
            defer { native.clean() }
            let mine = native.store.notesByRecent.map(\.id).joined(separator: ",")
            let theirs = try web.string("notesByRecent().map(function (n) { return n.id; }).join(',')")
            r.equal("newest first", mine, theirs)
        } catch {
            r.equal("ran", "\(error)", "no error")
        }
    }

    // MARK: - the profile, the offer, the feedback day

    func profileAndFlags() {
        let seed = Seeds.store(tasks: [open1], profile: ("", "🧔🏻"))
        for raw in ["Aiman", "   Aiman   ", "", "  ",
                    String(repeating: "n", count: 40),
                    String(repeating: "x", count: 22) + "🙂",
                    "Zulaikha binti Abdullah al-Rahman"] {
            pair("profile name \(WebJSON.quoted(raw))", seed) { n in
                n.store.setProfileName(raw)
                return "__profileName(\(WebJSON.quoted(raw)));"
            }
        }
        /* The 24 cap landing inside a surrogate pair — the same
           unavoidable divergence as the 160 one, pinned here too because
           a name is the more likely place for an emoji. */
        pair("profile name capped mid-surrogate-pair", seed,
             expect: .loneSurrogate("`'x'×23 + '👩‍👩‍👧'` is 31 UTF-16 units; slice(0, 24) "
                                    + "lands inside the first pair. Normalize.swift:53-56.")) { n in
            let raw = String(repeating: "x", count: 23) + "👩‍👩‍👧"
            n.store.setProfileName(raw)
            return "__profileName(\(WebJSON.quoted(raw)));"
        }
        for face in ["🦊", "🧔🏻", "🫠"] {
            pair("avatar \(face)", seed) { n in
                n.store.setProfileAvatar(face)
                return "__avatar(\(WebJSON.quoted(face)));"
            }
        }
        pair("the signup offer stays turned down", seed) { n in
            n.store.dismissSignupOffer()
            return "__signupNo();"
        }
        pair("sentFeedbackOn is the UTC day", seed) { n in
            n.store.markFeedbackSent()
            r.equal("spent today", n.store.feedbackSpentToday ? "true" : "false", "true")
            return "__feedbackSent();"
        }
        pair("sentFeedbackOn overwrites yesterday's", Seeds.store(sentFeedbackOn: "2020-01-01")) { n in
            n.store.markFeedbackSent()
            return "__feedbackSent();"
        }
        r.open("feedbackSpentToday (app.js:2658)")
        do {
            try web.seed(Seeds.store(sentFeedbackOn: WebDates.dayKey(now)))
            let native = NativeStore(seed: Seeds.store(sentFeedbackOn: WebDates.dayKey(now)), now: now)
            defer { native.clean() }
            let theirs = try web.string("String(feedbackSentToday())")
            r.equal("the LOCAL day does not spend it", native.store.feedbackSpentToday ? "true" : "false", theirs)
        } catch {
            r.equal("ran", "\(error)", "no error")
        }
    }

    // MARK: - the fixture stores

    /// Every store in `Checks/fixtures` through the mutations that do
    /// not need to know what is in it. The shapes there — a store with
    /// no `importance`, one with keys this build has never heard of, the
    /// old notes shape — are the ones a real phone actually holds.
    func fixtures() {
        let dir = FileManager.default.currentDirectoryPath + "/Checks/fixtures"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        guard !names.isEmpty else {
            r.open("fixtures")
            r.note("none found at \(dir)")
            return
        }
        for name in names {
            guard let text = try? String(contentsOfFile: dir + "/" + name, encoding: .utf8) else { continue }
            let seed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            /* `load()` is the comparison here: everything after it is a
               mutation that must leave the same document on both sides. */
            pair("\(name): save()", seed, maskIDs: true) { n in
                n.store.save()
                return "save();"
            }
            pair("\(name): pruneDone + stampTimeOnly", seed, maskIDs: true) { n in
                _ = n.store.pruneDone()
                _ = n.store.stampTimeOnly()
                return "pruneDone(); stampTimeOnly();"
            }
            pair("\(name): clearAll", seed, maskIDs: true) { n in
                _ = n.store.clearAll()
                return "__clearAll();"
            }
            pair("\(name): the profile and the flags", seed, maskIDs: true) { n in
                n.store.setProfileName("  Someone  ")
                n.store.setProfileAvatar("🦊")
                n.store.dismissSignupOffer()
                n.store.markFeedbackSent()
                return "__profileName('  Someone  '); __avatar('🦊'); __signupNo(); __feedbackSent();"
            }
            pair("\(name): markDone the first open row", seed, maskIDs: true) { n in
                guard let id = n.store.doc.tasks.first(where: { !$0.done })?.id else { return "" }
                n.store.markDone(id)
                return "var t = state.tasks.filter(function (x) { return !x.done; })[0];"
                     + "if (t) markDone(t.id);"
            }
        }
    }
}
