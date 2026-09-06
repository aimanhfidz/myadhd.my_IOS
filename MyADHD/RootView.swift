/* ============================================================
   my.adhd for iOS — what is actually on screen

   A coloured ground, the page on top of it, and a cover over the page
   until it has painted. The cover is the whole reason the ground is
   remembered between launches: WKWebView shows white until the first
   frame, and a white rectangle for half a second is exactly the flash
   theme.js goes to such lengths to avoid on the web.
   ============================================================ */

import SwiftUI

struct RootView: View {

    @StateObject private var state = ShellState()

    var body: some View {
        ZStack {
            state.ground
                .ignoresSafeArea()

            WebScreen(state: state)
                /* styles.css already pads for env(safe-area-inset-*) on every
                   screen. Letting iOS inset the view as well would pad it
                   twice — and the keyboard region belongs to the page too,
                   which handles it with the visual viewport. */
                .ignoresSafeArea()
                .opacity(state.painted ? 1 : 0)

            if state.offline {
                OfflineView(retry: {
                    NotificationCenter.default.post(name: .myadhdReload, object: nil)
                })
                .background(state.ground.ignoresSafeArea())
            }
        }
        .animation(.easeOut(duration: 0.22), value: state.painted)
        /* Not a theme for the app — the app has no SwiftUI chrome. This is
           what makes the status bar readable against whichever ground the
           page is on. */
        .preferredColorScheme(state.theme == "dark" ? .dark : .light)
    }
}
