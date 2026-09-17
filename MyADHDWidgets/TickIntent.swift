/* ============================================================
   my.adhd for iOS — ticking one off from the home screen

   Runs in the widget's process, not the app's: openAppWhenRun is false,
   so the whole point is that nothing comes to the front. All it does is
   append to OpQueue and ask for a redraw. The provider lays the pending
   ops over the snapshot, so the row strikes through in the time it takes
   WidgetKit to reload — and the real store catches up the next time the
   app is opened, which is the honest cost of a widget process that cannot
   reach a web view. See OpDrain.swift for that half.

   isDiscoverable is false because "tick the task whose id is t_a4f2c91"
   is not a thing anybody wants offered in Shortcuts.
   ============================================================ */

import AppIntents
import WidgetKit

struct TickIntent: AppIntent {

    static var title: LocalizedStringResource = "Tick a task off"
    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Task")
    var id: String

    init() {}

    init(id: String) { self.id = id }

    func perform() async throws -> some IntentResult {
        OpQueue.push(.done(id))

        /* WidgetKit reloads the widget this button was in on its own.
           Asking for the rest is what keeps Next Up and the band from
           disagreeing with the tile the user just tapped — three views of
           one list should not hold different opinions about it. */
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
