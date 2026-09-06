/* ============================================================
   my.adhd for iOS — the little the SwiftUI side needs to know

   Three facts, and they exist for one reason each:

     theme     so the ground behind the page is never a different colour
               from the page. It is remembered between launches because the
               shell has to paint before the web view has told it anything.
     painted   so there is a plain coloured cover over the web view until
               the first frame lands, instead of a white rectangle.
     offline   so a first launch with no signal says something, rather than
               sitting on an empty page for ever.
   ============================================================ */

import SwiftUI

final class ShellState: ObservableObject {

    @Published var theme: String
    @Published var painted = false
    @Published var offline = false

    private static let key = "myadhd.ground"

    init() {
        /* theme.js defaults to light and the system preference does not get
           a vote, so the shell must not have one either. */
        theme = UserDefaults.standard.string(forKey: Self.key) ?? "light"
    }

    /// Told to us by the injected bridge, on load and on every toggle.
    func remember(theme value: String) {
        guard value == "light" || value == "dark", value != theme else { return }
        theme = value
        UserDefaults.standard.set(value, forKey: Self.key)
    }

    var ground: Color {
        Color(theme == "dark" ? AppConfig.darkGround : AppConfig.lightGround)
    }

    /// The status bar has to be readable against whichever ground is up.
    var statusBarScheme: ColorScheme {
        theme == "dark" ? .dark : .light
    }
}
