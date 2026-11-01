/* ============================================================
   MyADHDWidgets/DumpControl.swift — "Dump", in Control Centre and on
   the Action Button

   Siri still needs a phrase and the icon still needs finding. A control
   is one press from anywhere, locked or not, and the same control is what
   the Action Button runs when it is set to Controls › my.adhd › Dump.

   It opens `myadhd://listen`, which brings up the composer with the mic
   already on (Inbox.swift, MicButton.swift). Opening the app is the
   point: the words have to land somewhere you can see them land.

   iOS 18 and later; the bundle leaves it out below that.
   ============================================================ */

import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct DumpControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "myadhd.dump") {
            ControlWidgetButton(action: ListenIntent()) {
                Label("Dump", systemImage: "mic.fill")
            }
        }
        .displayName("Dump")
        .description("Opens a new dump, already listening.")
    }
}

@available(iOS 18.0, *)
struct ListenIntent: AppIntent {

    static var title: LocalizedStringResource = "Dump a thought out loud"
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "myadhd://listen")!))
    }
}
