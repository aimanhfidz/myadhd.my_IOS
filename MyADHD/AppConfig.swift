/* ============================================================
   my.adhd for iOS — the handful of constants the shell is built on

   This project is a case around the web app, not a copy of it. Nothing
   here reimplements a feature: it opens https://myadhd.my/app, keeps the
   parts of iOS a browser tab cannot reach (haptics, reminders, the share
   sheet, a Shortcut), and gets out of the way.

   Which means every value in this file is a promise about the web app.
   If one of them drifts — the grounds in theme.css, the id of the dump
   box, Supabase's redirect — the shell breaks quietly. They are gathered
   here so there is one place to check.
   ============================================================ */

import UIKit

enum AppConfig {

    /// Where the shell opens. A fresh load of /app always lands on the dump
    /// box, which is what makes the Shortcut in DumpIntent.swift simple.
    static let home = URL(string: "https://myadhd.my/app")!

    /// The hosts the web view is allowed to keep. Anything else — Stripe's
    /// donation page, Google's account pages, a link out of the privacy
    /// policy — goes to Safari, where there is an address bar and the user
    /// can see whose form they are filling in.
    static let ownHosts: Set<String> = ["myadhd.my", "www.myadhd.my"]

    /// Supabase's front door to Google, the same path on every project.
    /// It must never open inside this web view: Google refuses OAuth in an
    /// embedded browser and answers `disallowed_useragent`. GoogleSignIn.swift
    /// catches it and hands it to Safari instead.
    static let authorizePath = "/auth/v1/authorize"

    /// What Supabase redirects back to once Google is finished. Declared in
    /// Info.plist, and it has to be on Supabase's redirect allow-list too —
    /// see the sign-in section of ios/README.md.
    static let callbackScheme = "myadhd"
    static let callbackURL = "myadhd://auth"

    /// The id of the textarea on the dump screen, from app.html.
    static let dumpBoxID = "dump-input"

    /// The two grounds from theme.css. The page is drawn on a transparent
    /// web view so the shell shows through at the edges and for the moment
    /// before first paint; if these drift from the stylesheet, opening the
    /// app on the dark theme flashes white.
    static let lightGround = UIColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let darkGround  = UIColor(red: 16 / 255, green: 16 / 255, blue: 24 / 255, alpha: 1)

    /// Appended to the default user agent, not swapped for it — the web app
    /// still needs to look like Safari to everything that sniffs it.
    static var userAgentSuffix: String { "MyADHD-iOS/\(version)" }

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }
}
