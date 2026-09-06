/* ============================================================
   my.adhd for iOS — the two scripts injected into the page

   Deliberately not a file in the web repo. The shell has to work against
   whatever is deployed at myadhd.my right now, including a version that
   has never heard of it, so everything the native side needs is pushed in
   from here rather than pulled from there. Nothing in the web app has to
   change for any of this to work, and nothing breaks in a browser because
   none of it ships to one.

   Injected as JavaScript rather than driven from Swift because the page
   is the only thing that knows when a tap happened, and a round trip per
   tap through the message handler would arrive after the animation.
   ============================================================ */

import Foundation

enum BridgeScript {

    /* ---- at document start ----
       Defined before any of the app's own scripts run, so a page that wants
       to check whether it is inside the shell can do so at the top of its
       first line. Nothing deployed does yet; this is the hook for when it
       does — hiding the "add to home screen" prompt, mainly, which is a
       nonsense to show inside an installed app. */
    static var atStart: String {
        template.replacingOccurrences(of: "__VERSION__", with: AppConfig.version)
    }

    private static let template = #"""
    (function () {
      if (window.MYADHD_NATIVE) return;

      function post(name, body) {
        try {
          window.webkit.messageHandlers.native.postMessage({ name: name, body: body || {} });
        } catch (e) { /* not in the shell, or the handler is gone */ }
      }

      window.MYADHD_NATIVE = {
        platform: 'ios',
        version: '__VERSION__',
        /* 'light' | 'medium' | 'heavy' | 'success' | 'warning' | 'error',
           and anything else is the selection tick. */
        haptic: function (kind) { post('haptic', { kind: String(kind || 'light') }); },
        share:  function (text) { post('share',  { text: String(text || '') }); },
        _post: post
      };
    })();
    """#

    /* ---- at document end ----
       The DOM exists by now, which is what both halves of this need. */
    static let atEnd = #"""
    (function () {
      var native = window.MYADHD_NATIVE;
      if (!native) return;
      var post = native._post;

      /* ---- tell the shell which ground to paint ----
         theme.js stamps data-theme on <html> before first paint and calls
         onChange every time the toggle is used. The shell paints behind a
         transparent web view, so without this a dark page sits on a white
         card at the safe areas. */
      function tell(theme) { post('theme', { theme: theme || 'light' }); }
      tell(document.documentElement.dataset.theme);
      if (window.myadhdTheme && window.myadhdTheme.onChange) {
        window.myadhdTheme.onChange(tell);
      }

      /* ---- the buzz ----
         On pointerdown, not click: a haptic that waits for the click has
         already missed the moment it was meant to confirm. Capture phase,
         because the app stops propagation on several of these itself.

         Three cases and no more. Buzzing on every tap is what a cheap
         wrapper does, and it stops meaning anything by the second screen. */
      document.addEventListener('pointerdown', function (e) {
        var t = e.target;
        if (!t || !t.closest) return;
        if (t.closest('.task-check')) { post('haptic', { kind: 'success' }); return; }
        if (t.closest('#btn-triage')) { post('haptic', { kind: 'medium' });  return; }
        if (t.closest('button, [role="button"], a')) { post('haptic', { kind: 'selection' }); }
      }, true);

      post('ready', {});
    })();
    """#

    /// Puts text in the dump box and leaves the caret after it. Used by the
    /// Shortcut and the `myadhd://dump?text=` link, both of which load /app
    /// first — a fresh load always lands on the dump screen, so the box this
    /// fills is the one on screen.
    static func fillDumpBox(with text: String) -> String {
        let literal = jsString(text)
        return """
        (function () {
          var box = document.getElementById('\(AppConfig.dumpBoxID)');
          if (!box) return false;
          var had = box.value && box.value.trim() ? box.value.replace(/\\s+$/, '') + '\\n' : '';
          box.value = had + \(literal);
          box.dispatchEvent(new Event('input', { bubbles: true }));
          box.focus();
          try { box.setSelectionRange(box.value.length, box.value.length); } catch (e) {}
          return true;
        })();
        """
    }

    /// A JS string literal, escaped by the JSON encoder rather than by hand.
    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else { return "''" }
        return String(array.dropFirst().dropLast())   // ["…"] -> "…"
    }
}
