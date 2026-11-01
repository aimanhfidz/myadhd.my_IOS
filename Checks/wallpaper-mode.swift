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
import CoreGraphics

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
        designsMoveTheDigest(r)
        autoCardsFollowTheGround(r)

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
        r.open("5. which screens ride along — same, pair (+home for v2), blur — never on a skip")
        r.equal("set, lock only", WallpaperMode.answer(.set, lockOnly: true), "set pair home")
        r.equal("redraw, lock only", WallpaperMode.answer(.redraw, lockOnly: true), "redraw pair home")
        r.equal("skip, lock only", WallpaperMode.answer(.skip, lockOnly: true), "skip")
        r.equal("set, both screens", WallpaperMode.answer(.set, lockOnly: false), "set same")
        r.equal("set, both, blurred", WallpaperMode.answer(.set, lockOnly: false, homeBlur: true), "set same blur")
        r.equal("redraw, pair, blurred", WallpaperMode.answer(.redraw, lockOnly: true, homeBlur: true), "redraw pair home blur")
        r.equal("skip, blurred", WallpaperMode.answer(.skip, lockOnly: false, homeBlur: true), "skip")
        /* The shortcut tests each word with "contains"; no word may hide
           inside another, or one branch would fire for the other's answer. */
        let words = ["skip", "set", "redraw", "same", "pair", "home", "blur"]
        r.yes("no word contains another",
              words.allSatisfy { w in words.allSatisfy { $0 == w || !$0.contains(w) } })
        r.yes("on by default", WallpaperStyle().lockOnly)
        r.yes("blur off by default", !WallpaperStyle().homeBlur)

        var both = style
        both.lockOnly = false
        r.yes("turning it off moves the digest",
              WallpaperMode.digest(board, style: both, day: day) != WallpaperMode.digest(board, style: style, day: day))

        /* A style saved before the field existed still decodes, as on. */
        let old = #"{"position":0.4,"cards":"dark"}"#.data(using: .utf8)!
        let decoded = try? JSONDecoder().decode(WallpaperStyle.self, from: old)
        r.yes("an older saved style reads as on", decoded?.lockOnly == true)
    }

    static func designsMoveTheDigest(_ r: Report) {
        r.open("6. the library: a design's own data moves the digest, a design is kept")
        var month = style
        month.design = .month
        r.yes("choosing another design moves it",
              WallpaperMode.digest(board, style: month, day: day) != WallpaperMode.digest(board, style: style, day: day))

        var focused = board
        focused.focus = WallpaperBoard.Focus(title: "Pay the bill", step: nil, meta: "25 min",
                                             late: false, hue: 0, hueLight: 0, more: 0)
        var refocused = board
        refocused.focus = WallpaperBoard.Focus(title: "Call the bank", step: nil, meta: "25 min",
                                               late: false, hue: 0, hueLight: 0, more: 0)
        r.yes("a new one task moves it",
              WallpaperMode.digest(focused, style: style, day: day) != WallpaperMode.digest(refocused, style: style, day: day))

        let saved = try? JSONEncoder().encode(month)
        let back = saved.flatMap { try? JSONDecoder().decode(WallpaperStyle.self, from: $0) }
        r.yes("a saved design reads back", back?.design == .month)
        r.yes("an older saved style reads as the matrix",
              (try? JSONDecoder().decode(WallpaperStyle.self, from: #"{"cards":"light"}"#.data(using: .utf8)!))?.design == .matrix)

        let light = WallpaperPreset.library.first { $0.id == "matrix-light" }!
        r.yes("Matrix Light sets light cards", light.applied(to: style).cards == .light)
        r.yes("Matrix Light is not current on dark cards", !light.isCurrent(style))
        var lit = style
        lit.cards = .light
        let today = WallpaperPreset.library.first { $0.design == .agenda }!
        r.yes("a design without cards keeps the person's", today.applied(to: lit).cards == .light)
        r.yes("ids are unique", Set(WallpaperPreset.library.map(\.id)).count == WallpaperPreset.library.count)
        r.yes("every design is in the library",
              Set(WallpaperPreset.library.map(\.design)) == Set(WallpaperStyle.Design.allCases))
    }

    static func autoCardsFollowTheGround(_ r: Report) {
        r.open("7. Auto cards: light on a bright ground, dark on a dark one")
        func flat(_ grey: CGFloat) -> CGImage {
            let ctx = CGContext(data: nil, width: 40, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(red: grey, green: grey, blue: grey, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
            return ctx.makeImage()!
        }
        var auto = style
        auto.cards = .auto
        r.yes("a white photo takes light cards", WallpaperView.resolvedCards(auto, background: flat(0.95)) == .light)
        r.yes("a black photo takes dark cards", WallpaperView.resolvedCards(auto, background: flat(0.05)) == .dark)
        r.yes("no photo is the dark gradient", WallpaperView.resolvedCards(auto, background: nil) == .dark)
        var darkened = auto
        darkened.brightness = -0.6
        r.yes("darkened past the line, dark cards",
              WallpaperView.resolvedCards(darkened, background: flat(0.95)) == .dark)
        var pale = auto
        pale.ground = .color
        pale.color = 0xF4EFE6
        r.yes("a pale colour ground takes light cards", WallpaperView.resolvedCards(pale, background: nil) == .light)
        r.yes("an explicit choice is never overridden",
              WallpaperView.resolvedCards(style, background: flat(0.95)) == .dark)
        let lightMatrix = WallpaperPreset.library.first { $0.id == "matrix-light" }!
        r.yes("Auto on a white photo ticks Matrix Light", lightMatrix.isCurrent(auto, background: flat(0.95)))
        r.yes("…and not on a black one", !lightMatrix.isCurrent(auto, background: flat(0.05)))
        let old = #"{"cards":"auto"}"#.data(using: .utf8)!
        r.yes("auto is saved and read back",
              (try? JSONDecoder().decode(WallpaperStyle.self, from: old))?.cards == .auto)
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
