/* ============================================================
   my.adhd for iOS

   Brain dump -> auto-triage -> one task, in a case that can ring, be
   talked to by Siri, and sit on the home screen as a widget.

   The web app at myadhd.my is the product and this project does not
   duplicate a line of it. What lives here is what a page in a browser
   cannot do on an iPhone: ring at a time, take a thought from a Shortcut
   or the share sheet, get through Google's sign-in, and draw the next
   thing on a tile and a lock screen. No count — README.md says why.
   ============================================================ */

import SwiftUI

@main
struct MyADHDApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in Inbox.accept(url: url) }
        }
    }
}
