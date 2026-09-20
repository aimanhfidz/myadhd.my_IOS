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
import WebKit

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

    // MARK: - the web route (deleted at the cutover, with WebScreen)

    /// Applies what the widget queued and then calls back, whatever
    /// happened. There is no reload to arrange here: markDone repaints the
    /// live page itself, and the fallback below reloads from inside the JS.
    static func drain(into web: WKWebView, then done: @escaping () -> Void) {
        OpQueue.sweep(olderThan: staleAfter)

        let pending = OpQueue.peek()
        guard !pending.isEmpty else { done(); return }

        /* Only the ticks go to the page, and only the ticks are dropped
           afterwards — see the note in the header about `applied` and
           which list the slice comes from.

           It lands by calling the page's own markDone(), not by editing
           localStorage behind its back. app.js is a classic script with no
           module wrapper, so every top-level function is on `window`.
           markDone's `after` parameter defaults to goToNext, which would
           yank the user to another screen for something they did an hour
           ago on the home screen; it is passed an empty function on
           purpose. */
        let ticks = pending.filter { $0.op.kind == .done }
        let ids = ticks.map(\.op.id)
        guard !ids.isEmpty,
              let payload = try? JSONSerialization.data(withJSONObject: ids),
              let list = String(data: payload, encoding: .utf8)
        else { done(); return }

        web.evaluateJavaScript(script(ids: list)) { value, error in
            /* No page to ask is not "the page refused". Leave the ops
               where they are and try again on the next foreground. */
            guard error == nil, let applied = value as? Int, applied > 0 else {
                done()
                return
            }
            OpQueue.drop(ticks.prefix(applied).map(\.account))
            done()
        }
    }

    /* The fallback matters more than it looks. If markDone is ever renamed
       on the web side this still works, and it fails toward the honest
       outcome either way: an op that lands nowhere is swept after two days
       and the tile un-ticks, which is better than a row that pretends.

       In the fallback, setItem and reload go in ONE synchronous statement
       so nothing can save over us in between — JavaScript is single
       threaded, so there is no window. setItem is neutered first so a save
       already queued on a timer cannot fire during the few milliseconds
       between asking for a reload and the navigation committing.

       The real setItem is captured BEFORE it is neutered, and the write
       goes through the captured one. localStorage has no setItem of its
       own — it inherits Storage.prototype's — so a call made after the
       prototype has been replaced resolves to the no-op, writes nothing,
       and the reload throws the edit away while the op is dropped as
       applied. That was the shape of this for a while. */
    private static func script(ids: String) -> String {
        """
        (function (ids) {
          var n = 0;
          if (typeof window.markDone === 'function') {
            for (var i = 0; i < ids.length; i++) {
              try { window.markDone(ids[i], function () {}); n++; } catch (e) {}
            }
            if (typeof window.repaintLists === 'function') {
              try { window.repaintLists(); } catch (e) {}
            }
            return n;
          }
          try {
            var raw = localStorage.getItem('\(AppConfig.storeKey)');
            if (!raw) { return 0; }
            var s = JSON.parse(raw);
            var hit = 0;
            (s.tasks || []).forEach(function (t) {
              if (ids.indexOf(t.id) !== -1 && !t.done) {
                t.done = true; t.doneAt = Date.now(); hit++;
              }
            });
            if (!hit) { return ids.length; }
            var write = Storage.prototype.setItem;
            Storage.prototype.setItem = function () {};
            write.call(localStorage, '\(AppConfig.storeKey)', JSON.stringify(s));
            location.reload();
            return ids.length;
          } catch (e) { return 0; }
        })(\(ids))
        """
    }
}
