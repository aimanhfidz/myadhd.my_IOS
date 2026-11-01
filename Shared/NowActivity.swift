/* ============================================================
   my.adhd for iOS — the one task, pinned to the lock screen

   The Now card as a Live Activity: the task, its first step, Done and
   Not now. No timer, no countdown, no progress bar — Ink's only "doing"
   feature is a Pomodoro, and a clock running down is the pressure this
   app exists to take away. A Live Activity here is the Now card you
   cannot lose, nothing more.

   Compiled into BOTH the app and the widget extension: the extension
   draws it, the app starts it, and the two buttons are LiveActivityIntents,
   which iOS runs in the app's process — the only one allowed to update an
   activity from the background.

   **Who decides what is shown.** In the app, the app does, with the Now
   card's own walk (`Ordering.pickNow`, LiveNow.swift), so the lock screen
   and Home never disagree while the app is alive. Between opens, the two
   buttons have no store to ask, only the keychain snapshot the widgets
   read; they take the next task from `TaskSnapshot.ordered` with the
   pending ticks laid over it, exactly as the Next Up tile does. The app
   puts its own answer back the next time it writes.

   **Done goes through OpQueue**, the same drawer as a widget tick, so
   there is still one way a task gets ticked off outside the app and one
   place (OpDrain) that lands it in the store.
   ============================================================ */

import ActivityKit
import AppIntents
import Foundation
import WidgetKit

// MARK: - what the lock screen is told

struct NowActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        var id: String
        var title: String
        /// Empty when the task has none; the view leaves the line out.
        var firstStep: String
        var late: Bool
        /// Put off with Not now while the app was closed. Held here
        /// because the activity is the only thing alive to hold it, and
        /// dropped the moment the app takes over again — the same shrug
        /// the Now card keeps for a visit and never saves.
        var passed: [String]
    }
}

// MARK: - the next one, without the app

enum NowNext {

    /// The next open task from the widgets' snapshot, minus anything
    /// ticked off and not yet drained, minus `passed`. Pass over all of
    /// them and the first comes round again, as on the Now card.
    static func state(passed: [String], now: Date = Date()) -> NowActivityAttributes.ContentState? {
        guard let snap = TaskStore.read() else { return nil }
        let ticked = Set(OpQueue.peek().map { $0.op.id })
        let order = snap.ordered(now: now).filter { !ticked.contains($0.id) }
        guard let pick = order.first(where: { !passed.contains($0.id) }) ?? order.first else { return nil }
        let today = snap.effectiveDay(now)
        return NowActivityAttributes.ContentState(
            id: pick.id,
            title: pick.title,
            firstStep: pick.firstStep ?? "",
            late: pick.isOverdue(on: today),
            passed: passed.filter { id in order.contains { $0.id == id } }
        )
    }

    /// Every running activity to `state`, or ended when there is nothing
    /// left. One activity is all the app ever starts; the loop is for the
    /// leftovers of a crash.
    static func apply(_ state: NowActivityAttributes.ContentState?) async {
        for activity in Activity<NowActivityAttributes>.activities {
            if let state {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}

// MARK: - the two buttons

struct NowDoneIntent: LiveActivityIntent {

    static var title: LocalizedStringResource = "Done with the task on the lock screen"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Task")
    var id: String

    init() {}
    init(id: String) { self.id = id }

    func perform() async throws -> some IntentResult {
        OpQueue.push(.done(id))
        WidgetCenter.shared.reloadAllTimelines()
        let passed = Activity<NowActivityAttributes>.activities.first?.content.state.passed ?? []
        await NowNext.apply(NowNext.state(passed: passed.filter { $0 != id }))
        return .result()
    }
}

struct NowSkipIntent: LiveActivityIntent {

    static var title: LocalizedStringResource = "Not now, for the task on the lock screen"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Task")
    var id: String

    init() {}
    init(id: String) { self.id = id }

    func perform() async throws -> some IntentResult {
        var passed = Activity<NowActivityAttributes>.activities.first?.content.state.passed ?? []
        if !passed.contains(id) { passed.append(id) }
        await NowNext.apply(NowNext.state(passed: passed))
        return .result()
    }
}
