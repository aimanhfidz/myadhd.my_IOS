/* ============================================================
   MyADHD/UI/Theme.swift — the token table, ported whole

   inventory §1.17. Every value here was read out of `theme.css` and
   `styles.css` rather than matched by eye, because the shell and the page
   used to sit on the same screen at once and a token that drifted showed
   up as a seam. There is no page any more, but the widgets, the wallpaper
   and the app icon are all still drawn against these numbers.

   Two rules the web keeps and this keeps with it:

   - **Light is the default and the OS never gets a vote.** `theme.js`
     reads its own key or answers 'light'; it never consults
     `prefers-color-scheme` from script, and the only dark CSS is behind an
     explicit `[data-theme="dark"]` or a media query the stamp overrides.
     So `ThemeStore` ignores `ColorScheme` entirely, and the screens push
     their answer back down with `.preferredColorScheme` so the status bar
     and the keyboard follow.
   - **The toggle is remembered, and in the key the shell already owns.**
     `myadhd.ground` was written by `ShellState` so a cold launch could
     paint the right ground before the web view had said anything. It is
     the same fact, so it is still the same key — `ShellState.rememberedTheme`
     reads it and `ShellState.remember(_:)` writes it, and nothing here
     knows the string.

   `--violet` is deliberately the same #7B3FE4 in both themes. theme.css
   has the long note: WCAG exempts a logotype from the contrast rule, and
   lifting it at night made the wordmark a different purple from the app
   icon beside it.
   ============================================================ */

import SwiftUI

// MARK: - one palette, two fillings

/// The whole of `:root`, resolved. A `Theme` value is passed down the view
/// tree rather than read from a global so a preview, a screenshot run and
/// the real app can all be handed a different one.
struct Theme: Equatable {

    // MARK: brand — the same in both themes unless noted

    let blue = Color(hex: 0x4737FF)        // --blue
    let blueDeep = Color(hex: 0x3529BF)    // --blue-deep
    let bluePale = Color(hex: 0xACA5FF)    // --blue-pale
    let pale = Color(hex: 0xD1CDFF)        // --pale
    let navy = Color(hex: 0x202030)        // --navy
    let black = Color(hex: 0x101018)       // --black
    let stone = Color(hex: 0x5E5E6A)       // --stone

    /// Vivid Orange does two jobs and only these two: the asterisk in the
    /// mark, and everything that is late.
    let orange = Color(hex: 0xF75C03)      // --orange

    /// The logo capsule, and the `.adhd` in the wordmark. Fixed across
    /// themes — see the file header.
    let violet = Color(hex: 0x7B3FE4)      // --violet
    let violetDeep = Color(hex: 0x3A1C86)  // --violet-deep
    let violetPale = Color(hex: 0xDCC9FF)  // --violet-pale

    /// Destructive only, never decoration.
    let danger = Color(hex: 0xD92D20)      // --danger

    // MARK: surfaces and text — these are what the two fillings move

    var dark: Bool

    var backdrop: Color { dark ? Color(hex: 0x15151F) : Color(hex: 0xE9E7FB) }
    var backdrop2: Color { dark ? Color(hex: 0x1D1D2B) : Color(hex: 0xD9D5F6) }
    var surface: Color { dark ? Color(hex: 0x101018) : Color(hex: 0xFFFFFF) }
    var wash: Color { dark ? Color(hex: 0x1A1A26) : Color(hex: 0xF4F3FE) }
    var wash2: Color { dark ? Color(hex: 0x232333) : Color(hex: 0xE9E7FD) }
    var ink: Color { dark ? Color(hex: 0xF3F2FB) : black }
    var inkSoft: Color { dark ? Color(hex: 0xD6D4EA) : navy }
    var muted: Color { dark ? Color(hex: 0x9A98AC) : stone }
    var faint: Color { dark ? Color(hex: 0x8B8AA0) : Color(hex: 0x6B6B7A) }
    var line: Color { dark ? Color(hex: 0x262636) : Color(hex: 0xE4E2F5) }
    var lineStrong: Color { dark ? Color(hex: 0x3B3A52) : Color(hex: 0xCFCBE9) }

    /// Brand blue is far too dark to sit on #101018, so the accent lifts to
    /// the pale blue at night and the text on top of it goes near-black.
    var accent: Color { dark ? Color(hex: 0x8B7DFF) : blue }
    var onAccent: Color { dark ? Color(hex: 0x101018) : Color(hex: 0xFFFFFF) }
    var typeDim: Color { dark ? Color(hex: 0xA97BFF) : violet }

    /// Red as a *fill* carries white on both grounds and does not move.
    /// Red as *text* is the half that fails on a dark page.
    var dangerInk: Color { dark ? Color(hex: 0xFF8A7E) : danger }
    var dangerWash: Color {
        dark ? Color(hex: 0xFF8A7E, opacity: 0.10) : Color(hex: 0xD92D20, opacity: 0.06)
    }
    var dangerEdge: Color {
        dark ? Color(hex: 0xFF8A7E, opacity: 0.38) : Color(hex: 0xD92D20, opacity: 0.32)
    }

    var toastBG: Color { dark ? Color(hex: 0x2A2A3E) : navy }
    var toastInk: Color { dark ? Color(hex: 0xF3F2FB) : Color(hex: 0xFFFFFF) }

    var focus: Color {
        dark ? Color(hex: 0x8B7DFF, opacity: 0.26) : Color(hex: 0x4737FF, opacity: 0.18)
    }

    /// The brand gradient, at the same three stops and the same 103°.
    /// SwiftUI has no angular gradient constructor, so the angle is turned
    /// into the unit points a `LinearGradient` wants — 103° measured the
    /// CSS way, clockwise from "to top".
    var brandGradient: LinearGradient {
        let stops: [Gradient.Stop] = dark
            ? [.init(color: Color(hex: 0x2A1FA6), location: 0.00),
               .init(color: Color(hex: 0x3F30E8), location: 0.38),
               .init(color: Color(hex: 0x6558FF), location: 0.68),
               .init(color: Color(hex: 0xACA5FF), location: 1.00)]
            : [.init(color: Color(hex: 0x101018), location: 0.00),
               .init(color: Color(hex: 0x3529BF), location: 0.38),
               .init(color: Color(hex: 0x4737FF), location: 0.68),
               .init(color: Color(hex: 0xACA5FF), location: 1.00)]
        return LinearGradient(gradient: Gradient(stops: stops),
                              startPoint: Theme.gradStart,
                              endPoint: Theme.gradEnd)
    }

    /// 103deg in CSS is 13° past "to right". Written out so the two ends
    /// are one decision rather than two numbers that can drift.
    private static let gradStart = UnitPoint(x: 0.0, y: 0.612)
    private static let gradEnd = UnitPoint(x: 1.0, y: 0.388)

    // MARK: the floating bar (styles.css:1435-1449)

    var tabBG: Color {
        dark ? Color(hex: 0x1E1E2E, opacity: 0.90) : Color(hex: 0xFFFFFF, opacity: 0.88)
    }
    var tabEdge: Color {
        dark ? Color(hex: 0xFFFFFF, opacity: 0.09) : Color(hex: 0x101018, opacity: 0.07)
    }
    /// `0 22px 46px -20px …, 0 3px 10px -6px …`. A CSS spread of -20px on a
    /// 46px blur is a shadow drawn from a box inset by 20 on every side;
    /// SwiftUI has no spread, so the radius is halved (CSS blur is a
    /// two-sided Gaussian diameter) and the opacity carries the rest.
    var tabShadowFar: (color: Color, radius: CGFloat, y: CGFloat) {
        (dark ? Color(hex: 0x000000, opacity: 0.72) : Color(hex: 0x101018, opacity: 0.42), 15, 12)
    }
    var tabShadowNear: (color: Color, radius: CGFloat, y: CGFloat) {
        (dark ? Color(hex: 0x000000, opacity: 0.50) : Color(hex: 0x101018, opacity: 0.22), 3, 2)
    }

    // MARK: the LOUD glass (styles.css:147-175)

    var loudGlass: Color {
        dark ? Color(hex: 0xFFFFFF, opacity: 0.045) : Color(hex: 0xFFFFFF, opacity: 0.62)
    }
    var loudGlassStrong: Color {
        dark ? Color(hex: 0xFFFFFF, opacity: 0.085) : Color(hex: 0xFFFFFF, opacity: 0.86)
    }
    var loudEdge: Color {
        dark ? Color(hex: 0xFFFFFF, opacity: 0.14) : Color(hex: 0x101018, opacity: 0.10)
    }
    var loudTop: Color {
        dark ? Color(hex: 0xFFFFFF, opacity: 0.16) : Color(hex: 0xFFFFFF, opacity: 0.75)
    }
    var loudCast: (color: Color, radius: CGFloat, y: CGFloat) {
        (dark ? Color(hex: 0x000000, opacity: 0.90) : Color(hex: 0x101028, opacity: 0.45), 24, 16)
    }

    // MARK: geometry

    static let radius: CGFloat = 14        // --radius
    static let radiusLg: CGFloat = 22      // --radius-lg
    static let radiusCard: CGFloat = 34    // --radius-card
    /// The readable column the app is held to. A phone never reaches it;
    /// an iPad and a Mac window do (--measure).
    static let measure: CGFloat = 720
    /// The gutter is `clamp(20px, 5vw, 40px)`.
    static func gutter(_ width: CGFloat) -> CGFloat {
        min(40, max(20, width * 0.05))
    }
    /// `--brand-gap: clamp(12px, 2vw, 20px)`.
    static func brandGap(_ width: CGFloat) -> CGFloat {
        min(20, max(12, width * 0.02))
    }

    // MARK: motion

    /// `--ease: cubic-bezier(.22,.9,.28,1)`.
    static func ease(_ duration: Double) -> Animation {
        .timingCurve(0.22, 0.9, 0.28, 1, duration: duration)
    }
    /// The sheet curve, `cubic-bezier(.32,.72,0,1)` — almost all of the
    /// travel spent slowing down, which is what makes a sheet feel thrown.
    static func settle(_ duration: Double) -> Animation {
        .timingCurve(0.32, 0.72, 0, 1, duration: duration)
    }
    /// The exit curve, `cubic-bezier(.33,0,.68,1)`.
    static func outSheet(_ duration: Double) -> Animation {
        .timingCurve(0.33, 0, 0.68, 1, duration: duration)
    }

    static let light = Theme(dark: false)
    static let night = Theme(dark: true)
}

// MARK: - the toggle, and where it is remembered

/// The one mutable thing about the theme: which of the two is on. Kept
/// small on purpose — it owns a string and a `UserDefaults` key, and every
/// colour decision is `Theme`'s.
@MainActor
@Observable
final class ThemeStore {

    /// 'light' or 'dark', exactly as `theme.js` stores it.
    private(set) var mode: String

    init(mode: String = ShellState.rememberedTheme) {
        /* theme.js: `active() = stored() || 'light'`. Anything else on disk
           is not a theme this build knows how to draw. */
        self.mode = (mode == "dark") ? "dark" : "light"
    }

    var theme: Theme { mode == "dark" ? .night : .light }
    var isDark: Bool { mode == "dark" }

    /// What the whole app is put in. Never `nil`: handing SwiftUI `nil`
    /// would let the OS decide, which is the one thing `theme.js` refuses
    /// to allow.
    var colorScheme: ColorScheme { isDark ? .dark : .light }

    /// The accessible name says what pressing it *does*; the icon says
    /// where the app *is*. theme.js:29 draws the same distinction.
    var toggleLabel: String { isDark ? Copy.Theme.toLight : Copy.Theme.toDark }

    /// Light shows the sun, dark shows the moon — the state, not the
    /// destination (theme.css, `.theme-toggle .t-sun`).
    var toggleSymbol: String { isDark ? "moon.fill" : "sun.max.fill" }

    func set(_ next: String) {
        let value = (next == "dark") ? "dark" : "light"
        guard value != mode else { return }
        mode = value
        ShellState.remember(value)
    }

    func toggle() { set(isDark ? "light" : "dark") }
}

// MARK: - passing it down

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.light
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - hex

extension Color {
    /// `0xRRGGBB`, because that is how every one of these was written down
    /// in the stylesheet and a three-argument constructor makes them
    /// unreadable at a glance.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
