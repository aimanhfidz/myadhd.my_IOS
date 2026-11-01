/* ============================================================
   Shared/ListenIntent.swift — what the Dump control runs

   Compiled into BOTH the app and the widget extension, with
   `openAppWhenRun`: a control that opens its app should have its intent
   in the app too, so iOS can bring the app up and run the intent there.
   Run in either process, it answers with `myadhd://listen`, which
   Inbox.swift turns into the composer with the mic already on.

   `OpenURLIntent` is iOS 18, as is the control (DumpControl.swift).
   ============================================================ */

import AppIntents
import Foundation

@available(iOS 18.0, *)
struct ListenIntent: AppIntent {

    static var title: LocalizedStringResource = "Dump a thought out loud"
    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "myadhd://listen")!))
    }
}
