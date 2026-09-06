/* ============================================================
   my.adhd for iOS

   Brain dump -> auto-triage -> one task, in a case that can buzz, ring
   and be talked to by Siri.

   The web app at myadhd.my is the product and this project does not
   duplicate a line of it. What lives here is the four things a page in a
   browser cannot do on an iPhone: feel a tap, ring at a time, take a
   thought from a Shortcut, and get through Google's sign-in.
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
