/* ============================================================
   Checks/calendar.swift — the calendar push, held against app.js

   `MyADHD/Core/CalendarPush.swift` against the real `syncable`,
   `eventSig` and `eventBody` in app.js, evaluated in JavaScriptCore. The
   slices are cut out of the file by the line they start on, never by
   line number, so an edit elsewhere in app.js cannot move them.

   **The signature is the one that must never drift.** It is stored on the
   task as `gcal.sig` and travels between devices, so if this build and the
   web disagreed about one task they would each read the other's as stale
   and take turns rewriting the same event for ever. Every case below is
   checked for it, including stored shapes the web never writes on
   purpose — a missing `minutes`, a fractional one, a null first step.

   The event body is checked for every case the web can build one for.
   Stubs stand in for the four things `eventBody` reaches that are not
   DOM-free: `tr` (English, so the template filled in), `trAs`, `trStamp`
   and `gcal.timeZone()`.

   The plan (`CalendarPush.plan`) has no function of its own on the web —
   it is inline in `syncNow` — so it is checked against the table in the
   web README's "How the sync works" instead.
   ============================================================ */

import Foundation
import JavaScriptCore

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - the slices

/// From the line that starts with `from` to the first line that is
/// exactly `to` (or just that line, for a one-liner).
func cut(_ lines: [String], from: String, to: String?) throws -> String {
    guard let start = lines.firstIndex(where: { $0.hasPrefix(from) }) else {
        throw Failure("app.js no longer has a line starting `\(from)` — the port has drifted")
    }
    guard let to else { return lines[start] }
    guard let end = lines[start...].firstIndex(where: { $0 == to }) else {
        throw Failure("no `\(to)` after `\(from)` in app.js")
    }
    return lines[start...end].joined(separator: "\n")
}

let zone = "Asia/Kuala_Lumpur"

func context(_ appJS: String) throws -> JSContext {
    let lines = appJS.components(separatedBy: "\n")
    let slices = [
        try cut(lines, from: "const pad2 = ", to: nil),
        try cut(lines, from: "function dayKey(", to: "}"),
        try cut(lines, from: "function keyToDate(", to: "}"),
        try cut(lines, from: "function addDays(", to: "}"),
        try cut(lines, from: "const CATEGORY_LABELS = {", to: "};"),
        try cut(lines, from: "function categoryLabel(", to: "}"),
        try cut(lines, from: "function minutesLabel(", to: "}"),
        try cut(lines, from: "const syncable = ", to: nil),
        try cut(lines, from: "function eventSig(", to: "}"),
        try cut(lines, from: "function localStamp(", to: "}"),
        try cut(lines, from: "function eventBody(", to: "}"),
    ]
    for s in slices where s.contains("document") || s.contains("window") {
        throw Failure("a slice now reaches the DOM:\n\(s)")
    }

    let ctx = JSContext()!
    var thrown: String?
    ctx.exceptionHandler = { _, e in thrown = e?.toString() }
    let stubs = """
    const tr = (s, v) => v ? s.replace(/\\{(\\w+)\\}/g, (_, k) => v[k]) : s;
    const trAs = (key, en) => en;
    const trStamp = (label) => label;
    const catName = (c) => trAs('category.' + c, categoryLabel(c));
    const gcal = { timeZone: () => '\(zone)' };
    """
    ctx.evaluateScript(stubs + "\n" + slices.joined(separator: "\n"))
    if let thrown { throw Failure("JavaScriptCore threw loading the slices: \(thrown)") }
    return ctx
}

// MARK: - the cases

/// `bodyToo` is false for stored shapes `eventBody` was never meant to
/// see (it would print "undefined min"); the signature is still checked.
let cases: [(name: String, json: String, bodyToo: Bool)] = [
    ("timed", #"{"id":"a1","title":"Call the bank","minutes":20,"energy":"low","urgency":4,"importance":"high","quadrant":null,"firstStep":"Find the card","category":"money","when":"2026-11-03","at":"14:30","steps":null,"local":false,"gcal":null,"done":false,"doneAt":null,"skipped":false}"#, true),
    ("all day, over an hour", #"{"id":"a2","title":"Pick up the parcel","minutes":90,"energy":"medium","firstStep":"","category":"errand","when":"2026-12-31","at":null,"done":false}"#, true),
    ("past midnight", #"{"id":"a3","title":"Night shift","minutes":240,"energy":"high","firstStep":"Pack","category":"work","when":"2026-11-30","at":"23:30","done":false}"#, true),
    ("across New York's spring forward", #"{"id":"a4","title":"Early","minutes":90,"energy":"low","firstStep":"Wake","category":"health","when":"2026-03-08","at":"01:30","done":false}"#, true),
    ("across New York's fall back", #"{"id":"a5","title":"Late","minutes":120,"energy":"low","firstStep":"Go","category":"health","when":"2026-11-01","at":"00:45","done":false}"#, true),
    ("unknown category", #"{"id":"a6","title":"Prune","minutes":30,"energy":"medium","firstStep":"Gloves","category":"gardening","when":"2026-11-04","at":"08:05","done":false}"#, true),
    ("awkward title", #"{"id":"a7","title":"Say \"no\" to 🎉 the\nparty","minutes":5,"energy":"low","firstStep":"Open WhatsApp","category":"social","when":"2026-11-05","at":null,"done":false}"#, true),
    ("null first step", #"{"id":"a8","title":"Bins","minutes":10,"energy":"low","firstStep":null,"category":"home","when":"2026-11-06","at":"","done":false}"#, true),
    ("carries a gcal already", #"{"id":"a9","title":"Dentist","minutes":60,"energy":"medium","firstStep":"Call","category":"health","when":"2026-11-07","at":"09:00","gcal":{"id":"evt1","sig":"stale"},"done":false}"#, true),
    ("done", #"{"id":"b1","title":"Done thing","minutes":20,"when":"2026-11-03","at":"10:00","done":true}"#, false),
    ("empty day", #"{"id":"b2","title":"No day","minutes":20,"when":"","done":false}"#, false),
    ("no day key", #"{"id":"b3","title":"No day","minutes":20,"done":false}"#, false),
    ("fractional minutes", #"{"id":"b4","title":"Odd","minutes":12.5,"when":"2026-11-03","done":false}"#, false),
    ("no minutes", #"{"id":"b5","title":"Bare","when":"2026-11-03","at":"07:00","done":false}"#, false),
    ("no title", #"{"id":"b6","minutes":15,"when":"2026-11-03","done":false}"#, false),
    ("minutes as text", #"{"id":"b7","title":"Text","minutes":"45","when":"2026-11-03","at":"07:00","firstStep":0,"done":false}"#, false),
]

func js(_ ctx: JSContext, _ expr: String) -> JSValue { ctx.evaluateScript(expr)! }

func run(webRoot: String) throws -> Int {
    let appJS = try String(contentsOfFile: webRoot + "/js/app.js", encoding: .utf8)
    let ctx = try context(appJS)
    var bad = 0

    for c in cases {
        guard let value = try? JSONValue.parse(c.json), let t = TaskItem(value) else {
            throw Failure("case \(c.name) is not a task")
        }
        ctx.setObject(c.json, forKeyedSubscript: "raw" as NSString)
        _ = js(ctx, "var t = JSON.parse(raw);")

        let webSync = js(ctx, "!!syncable(t)").toBool()
        if webSync != CalendarPush.syncable(t) {
            print("FAIL \(c.name): syncable web=\(webSync) swift=\(CalendarPush.syncable(t))"); bad += 1
        }

        let webSig = js(ctx, "eventSig(t)").toString() ?? ""
        let swiftSig = CalendarPush.eventSig(t)
        if webSig != swiftSig {
            print("FAIL \(c.name): eventSig\n  web:   \(webSig.debugDescription)\n  swift: \(swiftSig.debugDescription)")
            bad += 1
        }

        if c.bodyToo {
            let webBody = js(ctx, "JSON.stringify(eventBody(t))").toString() ?? ""
            let swiftBody = WebJSON.encode(CalendarPush.eventBody(t, timeZone: zone))
            if webBody != swiftBody {
                print("FAIL \(c.name): eventBody\n  web:   \(webBody)\n  swift: \(swiftBody)")
                bad += 1
            }
        }
    }
    print("calendar: \(cases.count) cases against app.js, \(bad) failed")
    return bad
}

// MARK: - the plan, against the README's table

func planChecks() -> Int {
    func task(_ json: String) -> TaskItem { TaskItem(try! JSONValue.parse(json))! }
    var fresh = task(#"{"id":"p1","title":"A","minutes":20,"when":"2026-11-03","at":null,"firstStep":"","done":false}"#)
    var current = fresh
    current.fields.set("id", .string("p2"))
    current.gcal = TaskItem.GCalRef(id: "e2", sig: CalendarPush.eventSig(current))
    var moved = current
    moved.fields.set("id", .string("p3"))
    moved.gcal = TaskItem.GCalRef(id: "e3", sig: "old")
    var ticked = current
    ticked.fields.set("id", .string("p4"))
    ticked.done = true
    ticked.gcal = TaskItem.GCalRef(id: "e4", sig: "x")
    var undated = current
    undated.fields.set("id", .string("p5"))
    undated.when = nil
    undated.gcal = TaskItem.GCalRef(id: "e5", sig: "x")
    var plainDone = fresh
    plainDone.fields.set("id", .string("p6"))
    plainDone.done = true
    fresh.title = "A"

    let got = CalendarPush.plan(tasks: [fresh, current, moved, ticked, undated, plainDone],
                                orphans: ["gone1"])
    let want: [CalendarPush.Step] = [.add("p1"), .edit("p3"), .drop("p4"), .drop("p5"), .kill("gone1")]
    if got != want {
        print("FAIL plan:\n  want \(want)\n  got  \(got)")
        return 1
    }
    print("calendar: plan agrees with the README's table")
    return 0
}

@main
enum CalendarCheck {
    static func main() {
        let args = CommandLine.arguments
        let web = args.count > 1 ? args[1] : "../My.adhd"
        do {
            let bad = try run(webRoot: web) + planChecks()
            exit(bad == 0 ? 0 : 1)
        } catch {
            print("calendar: \(error)")
            exit(2)
        }
    }
}
