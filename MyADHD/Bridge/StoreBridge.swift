/* ============================================================
   MyADHD/Bridge/StoreBridge.swift — the store, pushed out to iOS

   design.md §2.3. `AppStore` writes the document; two things outside the
   app's own screens have to be rebuilt from it afterwards:

     TaskBridge.write(from:)   the widgets' and the wallpaper's copy
     Reminders.sync(json:)     the local notification schedule

   Both are handed `AppStore.doc.jsonString` — the same bytes that just
   went to disk, not a second rendering of the same document — so there
   is exactly one encoding of the store in the app and nothing can drift
   between what the file says and what a tile draws.

   **The debounce.** `AppStore.didWrite` fires on every `persistOnly()`,
   and typing in a note calls that on every keystroke. Rebuilding the
   notification schedule once per letter would spend the battery and put
   64 round trips through UNUserNotificationCenter inside a background
   task window. 1.5 s, the same figure the shell used and the same figure
   `cloud.soon()` uses, because it is the same burst being swallowed: a
   triage that lands eight tasks is eight `save()` calls.

   **The four moments.** The shell got its reads at first paint, on a
   debounced write, on the way out and on the way back. This has the same
   four and one improvement on each end:

   - a write settles → push (debounced)
   - `willResignActive` → push NOW, cancelling the debounce. There is no
     point waiting out 1.5 s the app is not going to be given.
   - `didBecomeActive` → drain the widget's ticks FIRST, then push. The
     other order writes `done: false` back over the row the person ticked
     on the home screen and the tile un-ticks itself.
   - `start()` → one push, so a cold launch with no signal still rebuilds
     the snapshot and the schedule. The shell could not do this: its first
     read had to wait for a page.

   **What this is not.** It is not a writer. It never mutates the
   document and never calls `save()`; the only thing it does to `AppStore`
   is read `doc.jsonString` and, on foreground, ask `OpDrain` to apply
   what a widget queued. The single-writer rule (§2.3) is unharmed.
   ============================================================ */

import Foundation
import UIKit

@MainActor
final class StoreBridge {

    /// Long enough to swallow a triage's eight saves and a sentence typed
    /// into a note; short enough that a tile is right by the time you have
    /// put the phone down.
    static let debounce: TimeInterval = 1.5

    private let store: AppStore

    /// The last bytes `AppStore` reported writing. Kept so a push costs a
    /// dictionary lookup rather than a re-encode of the whole document,
    /// and so the snapshot is built from what is genuinely on disk.
    private var latest: String?

    private var settle: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    init(store: AppStore) {
        self.store = store
    }

    deinit {
        /* The work item cannot be cancelled from here — it is main-actor
           state and deinit is not — but it holds only a weak self, so at
           worst it wakes up, finds nothing and returns. The observers are
           the ones that must go. */
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - Turning it on

    /// Hooks `AppStore.didWrite`, subscribes to the two lifecycle
    /// notifications, and pushes once. Idempotent.
    ///
    /// The first push is not conditional on a write having happened: on a
    /// cold launch the document has been read and nothing has been
    /// written yet, and that is exactly the launch where the widget's copy
    /// and the schedule most want rebuilding — the phone may have been in
    /// a drawer since the last pass.
    func start() {
        guard !started else { return }
        started = true

        store.didWrite = { [weak self] json in
            self?.wrote(json)
        }

        let centre = NotificationCenter.default
        observers.append(centre.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.leaving() }
        })
        /* Not didEnterBackground: by then the app may have been frozen and
           the keychain write never comes back. */
        observers.append(centre.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.returning() }
        })

        push()
    }

    /// Unhooks everything. For a test, and for the day the app has more
    /// than one store.
    func stop() {
        guard started else { return }
        started = false
        settle?.cancel()
        settle = nil
        store.didWrite = nil
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers = []
    }

    // MARK: - The moments

    /// `AppStore` has just written. Remember the bytes and start the clock.
    private func wrote(_ json: String) {
        latest = json
        schedule()
    }

    private func schedule() {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.push() }
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    /// Going away. No point waiting out a debounce the app is not going to
    /// be given the time to finish.
    private func leaving() {
        flush()
    }

    /// Coming back. The ticks a widget took while the app was away land
    /// first, so the snapshot pushed underneath them already has them in
    /// it and the tile never flickers back to un-ticked.
    ///
    /// `reloadIfChangedOnDisk` comes before both, for the day a second
    /// writer exists — an App Intent, an extension, a background task.
    /// Today it always answers false.
    private func returning() {
        /* If it did move, the bytes this object is holding are somebody
           else's previous version and must not be what the widget is
           rebuilt from. Dropping them makes the push below re-encode the
           document that was just read. */
        if store.reloadIfChangedOnDisk() { latest = nil }
        OpDrain.drain(into: store)
        flush()
    }

    /// Push now, whatever the debounce was doing.
    func flush() {
        settle?.cancel()
        settle = nil
        push()
    }

    // MARK: - The push

    /// `TaskBridge` first, then `Reminders`, and `TaskBridge`
    /// unconditionally.
    ///
    /// That order is the same one the shell was careful about for the same
    /// reason: `Reminders` gives up early for anybody who declined
    /// notifications, and a widget has nothing to do with notifications.
    /// Behind one call it was a matter of which line came first; here they
    /// are two calls and it is a matter of which one can return early.
    private func push() {
        let json = latest ?? store.doc.jsonString
        latest = json

        TaskBridge.write(from: json)
        Reminders.sync(json: json)
    }
}
