/* ============================================================
   my.adhd for iOS — landing the widget's ticks in the real store

   The other half of Shared/OpQueue.swift. A widget cannot reach the app's
   memory, so a tick taken on a tile is a note in the keychain until the
   app is next in front of somebody. This is where it lands.

   There are two routes in this file and they are not equals.

   THE NATIVE ROUTE, below, is the one that counts. It hands each queued
   id to `AppStore.markDone`, which is the same call the row's own
   checkbox makes — so a tick taken on the home screen and a tick taken
   in the app are the same event, written by the same writer, with the
   same follow-on effects. That is not a shortcut, it is the point:
   markDone stamps `doneAt` (which `pruneDone()` ages on and the Done
   graph counts) and then calls `save()`, which is the cloud stamp, the
   write, the Google Calendar debounce and the Supabase debounce. Editing
   the document from here instead would get four of those five wrong.

   THE WEB ROUTE at the bottom is the shell's, and it is deleted at the
   cutover together with WebScreen and BridgeScript. Nothing new should
   be added to it. It is kept only so the app still builds and still
   works while the native screens are being written beside it.

   Two things are load-bearing in both routes and easy to undo by
   accident:

   - Nothing is deleted from the queue until the store says it took it.
     No store, no answer, an error — the ops stay and are tried again.

   - `applied` counts what was taken from `ticks`, so the slice that gets
     dropped has to come from the same list, not from `pending` — which
     is the same list today, and will not be the day a second kind of op
     exists.
   ============================================================ */

import Foundation

enum OpDrain {

    /// Ops older than this are not going to land: the task they name has
    /// very likely been pruned, and re-ticking something finished on
    /// Tuesday is worse than forgetting it.
    static let staleAfter: TimeInterval = 48 * 60 * 60

    // MARK: - the native route

    /// Applies what the widget queued straight to the store, and says how
    /// many landed.
    ///
    /// Ticks only, and only the accounts that actually applied are
    /// dropped. An op naming a task that is no longer on the store — it
    /// was removed, or `pruneDone()` aged it out while the tile still
    /// showed it — did not apply and is left in the queue, where the
    /// 48-hour sweep above takes it. That is the honest outcome: the tile
    /// un-ticks at the next refresh rather than the app pretending it
    /// wrote something.
    ///
    /// An op for a task that is already done applies and is dropped —
    /// `markDone` is idempotent on the store and the row is in the state
    /// the tile said it was.
    ///
    /// Synchronous on purpose. `StoreBridge` runs this BEFORE it pushes
    /// the snapshot out on `didBecomeActive`, so a widget tick and the
    /// snapshot that agrees with it land in one pass; a callback here
    /// would put the two in different turns of the run loop and the tile
    /// would un-tick for a frame.
    @MainActor
    @discardableResult
    static func drain(into store: AppStore) -> Int {
        OpQueue.sweep(olderThan: staleAfter)

        let ticks = OpQueue.peek().filter { $0.op.kind == .done }
        guard !ticks.isEmpty else { return 0 }

        var landed: [String] = []
        for tick in ticks {
            /* One save() per tick, which is what the web does too — every
               markDone is its own save. The file write coalesces them and
               StoreBridge's debounce coalesces the snapshot, so three
               ticks taken on a tile cost one of each. */
            guard store.markDone(tick.op.id) else { continue }
            landed.append(tick.account)
        }

        OpQueue.drop(landed)
        return landed.count
    }

}
