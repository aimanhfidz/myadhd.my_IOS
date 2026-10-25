/* ============================================================
   Checks/wallpaper-mode.swift — when the shortcut may skip

   Not an Xcode target. A `swiftc` program over the app target's own
   sources.

       Checks/wallpaper-mode.sh

   `WallpaperModeIntent` answers skip, set or redraw, and the shortcut
   branches on that text. A wrong "skip" is the dangerous one: the lock
   screen quietly stays on an old picture and nothing says so. So this
   holds `WallpaperMode` to the rules its header writes down:

     1. **Skip only a picture that was confirmed.** Same board, and the
        confirm step ran after the drawing. A drawing that was never
        confirmed is drawn again.
     2. **Anything the picture shows moves the digest** — a task, a box,
        the style — and so does the day, so one run a day really sets.
     3. **No board, no skip.** An unreadable store answers "set", so the
        run reaches WallpaperIntent, which throws and keeps yesterday's.
     4. **Force redraw never overrides skip**, only "set".
   ============================================================ */

import Foundation

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
}

// MARK: - fixtures

func quad(_ key: String, _ titles: [String]) -> WallpaperBoard.Quad {
    WallpaperBoard.Quad(key: key, title: key, symbol: "circle",
                        hue: 0, hueLight: 0, titles: titles)
}

let board = WallpaperBoard(quads: [
    quad("do", ["Pay the bill", "Call the bank"]),
    quad("plan", ["Renew passport"]),
])
let style = WallpaperStyle()
let day = "2026-10-26"

let drawn = Date(timeIntervalSince1970: 1_800_000_000)
let confirmedAfter = drawn.addingTimeInterval(8)
let confirmedBefore = drawn.addingTimeInterval(-3_600)

func decide(_ digest: String?, lastDrawn: String?, run: Date?, confirmed: Date?,
            force: Bool = false) -> String {
    WallpaperMode.decide(digest: digest, lastDrawn: lastDrawn,
                         lastRun: run, lastConfirmed: confirmed,
                         forceRedraw: force).rawValue
}

// MARK: - the checks

@main
struct WallpaperModeChecks {

    static func main() {
        let r = Report()
        print("wallpaper-mode")

        skipsOnlyWhatWasConfirmed(r)
        digestMovesWithThePicture(r)
        neverSkipsBlind(r)
        forceRedrawOnlyReplacesSet(r)
        homeRidesAlong(r)

        print("\n---")
        print("checked \(r.checks), \(r.failures.count) failed")
        if !r.failures.isEmpty {
            for f in r.failures { print("  FAIL \(f)") }
            exit(1)
        }
        print("wallpaper-mode OK")
        exit(0)
    }

    static func skipsOnlyWhatWasConfirmed(_ r: Report) {
        r.open("1. skip only a confirmed picture")
        let d = WallpaperMode.digest(board, style: style, day: day)
        r.equal("never drawn", decide(d, lastDrawn: nil, run: nil, confirmed: nil), "set")
        r.equal("same board, confirmed after drawing",
                decide(d, lastDrawn: d, run: drawn, confirmed: confirmedAfter), "skip")
        r.equal("same board, confirmed in the same second",
                decide(d, lastDrawn: d, run: drawn, confirmed: drawn), "skip")
        /* The device case: the run drew, died before its confirm, and the
           newest confirm is the previous run's, 21 seconds earlier. */
        r.equal("same board, a confirm from just before the drawing",
                decide(d, lastDrawn: d, run: drawn, confirmed: drawn.addingTimeInterval(-21)), "set")
        r.equal("same board, drawn but never confirmed",
                decide(d, lastDrawn: d, run: drawn, confirmed: nil), "set")
        r.equal("same board, last confirm older than the drawing",
                decide(d, lastDrawn: d, run: drawn, confirmed: confirmedBefore), "set")
        r.equal("different board, confirmed",
                decide("other", lastDrawn: d, run: drawn, confirmed: confirmedAfter), "set")
    }

    static func digestMovesWithThePicture(_ r: Report) {
        r.open("2. the digest moves with what the picture shows")
        let base = WallpaperMode.digest(board, style: style, day: day)
        r.yes("is made", base != nil)
        r.equal("is stable", WallpaperMode.digest(board, style: style, day: day) ?? "", base ?? "-")

        let ticked = WallpaperBoard(quads: [quad("do", ["Call the bank"]), quad("plan", ["Renew passport"])])
        r.yes("a task ticked off", WallpaperMode.digest(ticked, style: style, day: day) != base)

        let moved = WallpaperBoard(quads: [quad("do", ["Pay the bill"]), quad("plan", ["Call the bank", "Renew passport"])])
        r.yes("a task moved box", WallpaperMode.digest(moved, style: style, day: day) != base)

        let renamed = WallpaperBoard(quads: [quad("do", ["Pay the bills", "Call the bank"]), quad("plan", ["Renew passport"])])
        r.yes("a title edited", WallpaperMode.digest(renamed, style: style, day: day) != base)

        var light = style
        light.cards = .light
        r.yes("the style changed", WallpaperMode.digest(board, style: light, day: day) != base)

        r.yes("the next day", WallpaperMode.digest(board, style: style, day: "2026-10-27") != base)

        /* The separators keep the boundaries: "ab"+"c" is not "a"+"bc". */
        let a = WallpaperBoard(quads: [quad("do", ["ab", "c"])])
        let b = WallpaperBoard(quads: [quad("do", ["a", "bc"])])
        r.yes("titles do not run together",
              WallpaperMode.digest(a, style: style, day: day) != WallpaperMode.digest(b, style: style, day: day))
    }

    static func neverSkipsBlind(_ r: Report) {
        r.open("3. no board, no skip")
        r.equal("unreadable board, nothing stored",
                decide(nil, lastDrawn: nil, run: drawn, confirmed: confirmedAfter), "set")
        r.equal("unreadable board, force on",
                decide(nil, lastDrawn: nil, run: drawn, confirmed: confirmedAfter, force: true), "redraw")
    }

    static func homeRidesAlong(_ r: Report) {
        r.open("5. Lock Screen only adds \"home\", never to a skip")
        r.equal("set, lock only", WallpaperMode.answer(.set, lockOnly: true), "set home")
        r.equal("redraw, lock only", WallpaperMode.answer(.redraw, lockOnly: true), "redraw home")
        r.equal("skip, lock only", WallpaperMode.answer(.skip, lockOnly: true), "skip")
        r.equal("set, both screens", WallpaperMode.answer(.set, lockOnly: false), "set")
        r.yes("on by default", WallpaperStyle().lockOnly)

        var both = style
        both.lockOnly = false
        r.yes("turning it off moves the digest",
              WallpaperMode.digest(board, style: both, day: day) != WallpaperMode.digest(board, style: style, day: day))

        /* A style saved before the field existed still decodes, as on. */
        let old = #"{"position":0.4,"cards":"dark"}"#.data(using: .utf8)!
        let decoded = try? JSONDecoder().decode(WallpaperStyle.self, from: old)
        r.yes("an older saved style reads as on", decoded?.lockOnly == true)
    }

    static func forceRedrawOnlyReplacesSet(_ r: Report) {
        r.open("4. force redraw replaces set, never skip")
        let d = WallpaperMode.digest(board, style: style, day: day)
        r.equal("changed board, force on",
                decide("other", lastDrawn: d, run: drawn, confirmed: confirmedAfter, force: true), "redraw")
        r.equal("unchanged and confirmed, force on",
                decide(d, lastDrawn: d, run: drawn, confirmed: confirmedAfter, force: true), "skip")
    }
}
