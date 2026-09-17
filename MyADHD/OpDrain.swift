/* ============================================================
   my.adhd for iOS — landing the widget's ticks in the real store

   The other half of Shared/OpQueue.swift. A widget cannot reach the web
   view, so a tick taken on a tile is a note in the keychain until the app
   is next in front of somebody. This is where it lands.

   It lands by calling the page's own markDone(), not by editing
   localStorage behind its back. app.js is a classic script with no module
   wrapper, so every top-level function is on `window` and markDone is
   reachable from an injected call — which is one of the two
   routes CLAUDE.md allows, and requires nothing on the web side to change.

   Going through markDone rather than the store is not a shortcut, it is
   the point. markDone stamps doneAt (which pruneDone ages on and the Done
   graph counts), calls save() — which is cloud.stamp() for conflict
   resolution, persistOnly(), syncSoon() for Google Calendar and
   cloud.soon() — and offers the same Undo the app offers. Reimplementing
   that against localStorage would get four of those five wrong, and the
   live page would overwrite the fifth on its next save.

   Two things are load-bearing and easy to undo by accident:

   - markDone's `after` parameter defaults to goToNext, which would yank
     the user to another screen for something they did an hour ago on the
     home screen. It is passed an empty function on purpose.

   - Nothing is deleted from the queue until the page says it took it.
     No page, no answer, an error — the ops stay and are tried again.
   ============================================================ */

import Foundation
import WebKit

enum OpDrain {

    /// Ops older than this are not going to land: the task they name has
    /// very likely been pruned, and re-ticking something finished on
    /// Tuesday is worse than forgetting it.
    private static let staleAfter: TimeInterval = 48 * 60 * 60

    /// Applies what the widget queued and then calls back, whatever
    /// happened. There is no reload to arrange here: markDone repaints the
    /// live page itself, and the fallback below reloads from inside the JS.
    static func drain(into web: WKWebView, then done: @escaping () -> Void) {
        OpQueue.sweep(olderThan: staleAfter)

        let pending = OpQueue.peek()
        guard !pending.isEmpty else { done(); return }

        let ids = pending.filter { $0.op.kind == .done }.map(\.op.id)
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
            OpQueue.drop(pending.prefix(applied).map(\.account))
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
       between asking for a reload and the navigation committing. */
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
            Storage.prototype.setItem = function () {};
            localStorage.setItem.call(localStorage, '\(AppConfig.storeKey)', JSON.stringify(s));
            location.reload();
            return ids.length;
          } catch (e) { return 0; }
        })(\(ids))
        """
    }
}
