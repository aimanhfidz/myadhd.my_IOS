/* ============================================================
   my.adhd for iOS — keeping the lock screen's one task honest

   The app's half of the Live Activity (Shared/NowActivity.swift has the
   model and the buttons). One switch on the Now card turns it on; from
   then on every push StoreBridge makes also puts the Now card's answer on
   the lock screen, so the two can never show different tasks while the
   app is alive.

   **The same pick as Home.** `Ordering.pickNow`, with Home's own
   "Not now" set handed in by HomeScreen. Anything ticked from a widget or
   from the lock screen and not drained yet is left out, so a Done pressed
   a second ago does not come back.

   **Starting needs the app in front.** iOS refuses `Activity.request`
   from the background, and quietly ends any activity after about eight
   hours. So the switch is remembered, and the next time the app is opened
   with it on and nothing running, a new one starts. Updating and ending
   work from anywhere.

   **Off means off.** The switch off ends every activity at once; an
   empty list ends it too, and the next task starts it again.

   **Light or dark is the phone's, not the app's.** The lock screen gives
   a Live Activity a dark appearance whatever the phone is set to, so the
   card cannot see the setting; every push sends it (`deviceIsDark`). It
   is read off the screen, because the app's own toggle is applied to its
   windows with `.preferredColorScheme` and must not leak onto the lock
   screen. The cost: the card changes when the app next pushes — coming
   back to the front after the switch, or the next write — not at the
   moment the phone flips while the app is closed. (Owner's call,
   2026-11-01.)
   ============================================================ */

import ActivityKit
import Foundation
import UIKit

@MainActor
enum LiveNow {

    private static let key = "myadhd.native.liveNow"

    /// The switch on the Now card. Kept on this phone, like the nudges.
    static var wanted: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Off in Settings › my.adhd › Live Activities, or not supported.
    static var allowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Home's "Not now" set for this visit. Never saved, as on the card.
    static var passed: Set<String> = []

    /// The last tasks seen, so the switch and Home can re-sync without a
    /// store in hand.
    private static var tasks: [TaskItem] = []

    // MARK: - the switch

    /// Turns it on or off from the Now card. Returns false when iOS will
    /// not show it, so the card can say why rather than look broken.
    @discardableResult
    static func set(_ on: Bool, tasks: [TaskItem]) -> Bool {
        if on && !allowed { return false }
        wanted = on
        sync(tasks: tasks)
        return true
    }

    // MARK: - keeping it current

    static func sync(tasks: [TaskItem], today: String = WebDates.dayKey()) {
        self.tasks = tasks
        /* `activities` keeps ones iOS has already ended (the eight-hour
           limit) while their card is still on screen. Updating one of
           those does nothing, so they are cleared away and do not count:
           a new one is started in their place. */
        let all = Activity<NowActivityAttributes>.activities
        for gone in all where gone.activityState == .ended {
            Task { await gone.end(nil, dismissalPolicy: .immediate) }
        }
        let running = all.filter { $0.activityState == .active || $0.activityState == .stale }

        guard wanted, let state = state(tasks: tasks, today: today) else {
            for activity in running {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
            return
        }

        if let first = running.first {
            if first.content.state != state {
                Task { await first.update(ActivityContent(state: state, staleDate: nil)) }
            }
            for extra in running.dropFirst() {
                Task { await extra.end(nil, dismissalPolicy: .immediate) }
            }
        } else if UIApplication.shared.applicationState != .background, allowed {
            _ = try? Activity.request(attributes: NowActivityAttributes(),
                                      content: ActivityContent(state: state, staleDate: nil))
        }
    }

    /// Home's "Not now" moved: follow it.
    static func passedChanged(_ set: Set<String>) {
        passed = set
        sync(tasks: tasks)
    }

    /// The Now card's task, as the lock screen draws it.
    static func state(tasks: [TaskItem], today: String) -> NowActivityAttributes.ContentState? {
        let ticked = Set(OpQueue.peek().map { $0.op.id })
        let open = tasks.filter { !ticked.contains($0.id) }
        guard let task = Ordering.pickNow(open, passed: passed, today: today) else { return nil }
        let when = task.when ?? ""
        return NowActivityAttributes.ContentState(
            id: task.id,
            title: task.title,
            firstStep: JSText.trim(task.firstStep),
            late: !when.isEmpty && when < today,
            passed: [],
            dark: deviceIsDark
        )
    }

    /// The phone's Light/Dark setting. The screen's traits, not a
    /// window's: the windows carry the app's own theme toggle.
    static var deviceIsDark: Bool {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let style = scene?.screen.traitCollection.userInterfaceStyle
            ?? UIScreen.main.traitCollection.userInterfaceStyle
        return style == .dark
    }
}
