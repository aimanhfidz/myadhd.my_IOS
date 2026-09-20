/* ============================================================
   my.adhd for iOS — what is actually on screen

   For most of this project's life that was a WKWebView showing
   myadhd.my, and this file's whole job was to hide the white flash
   before the page painted. There is no page any more: `AppShell` draws
   the app, from a JSON document on the phone, with no network.

   So the cover is gone, and with it the remembered ground it existed
   for — there is no first frame to wait out, and `ThemeStore` inside the
   shell owns the colours now. What is left here is the one piece of
   native UI that is neither the app nor a screen of it: the wallpaper
   setup sheet, which is never shown uninvited (myadhd://wallpaper, the
   Shortcuts phrase, or the widget tapped on a phone that has not set the
   automation up).
   ============================================================ */

import SwiftUI

struct RootView: View {

    @State private var showingWallpaper = false

    var body: some View {
        AppShell()
            .sheet(isPresented: $showingWallpaper) { WallpaperSetup() }
            .onReceive(NotificationCenter.default.publisher(for: .myadhdWallpaper)) { _ in
                showingWallpaper = true
            }
    }
}
