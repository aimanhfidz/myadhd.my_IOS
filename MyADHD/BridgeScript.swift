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
        template
            .replacingOccurrences(of: "__VERSION__", with: AppConfig.version)
            .replacingOccurrences(of: "__HOLDKEY__", with: AppConfig.holdKey)
    }

    private static let template = #"""
    (function () {
      /* ---- past the curtain, before the page can draw it ----
         This runs at .atDocumentStart: the document element exists, the
         <head> has not been parsed, and app.html's hold has therefore not
         had its chance to redirect yet. Writing the key here is the whole
         fix — by the time the inline block reads it, it is already there.

         Outside the return guard above on purpose. That guard exists so
         the bridge is only built once, and this has to run on every
         document, including one that has somehow already got a bridge.

         Temporary. See AppConfig.holdKey for what to delete when the app
         opens to everyone again. */
      try { localStorage.setItem('__HOLDKEY__', '1'); } catch (e) { /* private mode, or no storage yet */ }

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

      /* ---- the tin, closed on iOS ----
         app.html carries two asks — the tin in the thanks card and the
         quiet line above it — and paintFeedback() renders neither when
         MYADHD_DONATE_URL is empty. That is the web app's own "no link,
         no ask" path, already written and already exercised by any
         deployment without a Stripe link, so this takes it rather than
         hiding boxes by class name that could be renamed tomorrow.

         Why at all: a link out to a payment page is the murkiest corner
         of App Review. The US storefront stopped forbidding it in 2025,
         the rest of the world is a separate question, and the answer to
         both is still moving through a court. None of that is worth
         arguing about on a first submission, and the money was never the
         point — so the ask stays on the web, where nobody has to rule on
         it, and the shell simply does not show it.

         A property rather than an assignment because config.js sets the
         value long after this script has run: a setter that swallows the
         write is the only shape that survives it. The web app is not
         touched, and a browser never sees any of this.  */
      try {
        Object.defineProperty(window, 'MYADHD_DONATE_URL', {
          get: function () { return ''; },
          set: function () { /* config.js will try. It does not win. */ },
          configurable: false
        });
      } catch (e) { /* leave the page alone rather than break config.js */ }
    })();
    """#

    /* ---- at document end ----
       The DOM exists by now, which is what both halves of this need. */
    static var atEnd: String {
        endTemplate.replacingOccurrences(of: "__STOREKEY__", with: AppConfig.storeKey)
    }

    private static let endTemplate = #"""
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
        /* Push-to-talk is the one control on this screen where the press and
           the release are both instructions, so both are answered. A
           selection tick is not enough to say "recording": it is the same
           tick every other button gives, and the thing it would be
           confirming takes a second to visibly start. */
        if (t.closest('#composer-mic')) { post('haptic', { kind: 'medium' }); return; }
        if (t.closest('button, [role="button"], a')) { post('haptic', { kind: 'selection' }); }
      }, true);

      /* The only release worth answering. micDown captures the pointer to
         the button, so this lands here however far the thumb has rolled. */
      document.addEventListener('pointerup', function (e) {
        var t = e.target;
        if (t && t.closest && t.closest('#composer-mic')) {
          post('haptic', { kind: 'light' });
        }
      }, true);

      /* ---- say when the store changes ----
         The reminders are built out of localStorage, and until this existed
         the only moments the shell knew to rebuild them were a page load and
         the app going away. A task written and dated in one sitting was
         therefore never scheduled at all, which also meant iOS was never
         asked for permission to ring about it.

         Patching the prototype rather than listening for 'storage', because
         that event fires in every tab except the one that wrote it — which
         is the only tab there is here. */
      try {
        var write = Storage.prototype.setItem;
        Storage.prototype.setItem = function (key, value) {
          write.apply(this, arguments);
          if (key === '__STOREKEY__') post('store', {});
        };
      } catch (e) { /* leave the store alone rather than break saving */ }


      /* ---- the buzzes the app already asked for ----
         app.js calls navigator.vibrate?.(8) twice — when a swipe arms, and
         when a long press lifts a row — and calls it optionally because it
         knew some phones would not have it. Every iPhone is one of those
         phones: no Safari and no web view has ever had the Vibration API,
         so on the device this app is mostly used on, the two moments most
         worth feeling were the two that were silent.

         Polyfilling it rather than watching for the class is deliberate.
         The call sites are already in the right places, they already carry
         an intent in their duration, and anything added later gets this
         for free without the shell knowing about it. */
      if (!navigator.vibrate) {
        navigator.vibrate = function (pattern) {
          var ms = Array.isArray(pattern) ? pattern[0] : pattern;
          ms = Number(ms) || 0;
          if (ms <= 0) return true;                 // vibrate(0) cancels
          post('haptic', { kind: ms <= 10 ? 'light' : ms <= 30 ? 'medium' : 'heavy' });
          return true;
        };
      }

      /* ---- and the one it has no way to ask for ----
         Ticking a task off with the checkbox buzzes; swiping the same task
         off used to do nothing, so the same outcome felt different
         depending on how it was reached. leaveSwipe() is the commit, and
         is-leaving is the only trace of it in the DOM — with is-left for
         done and is-right for remove, still set from the last paint.

         A flick commits without ever arming, so this cannot be folded into
         the vibrate above: that one marks the threshold, this one marks
         the deed. */
      var buzzed = new WeakSet();
      new MutationObserver(function (records) {
        for (var i = 0; i < records.length; i++) {
          var row = records[i].target;
          if (!row.classList || !row.classList.contains('is-leaving')) continue;
          if (buzzed.has(row)) continue;
          buzzed.add(row);
          post('haptic', { kind: row.classList.contains('is-left') ? 'success' : 'heavy' });
        }
      }).observe(document.body, {
        subtree: true,
        attributes: true,
        attributeFilter: ['class'],   // style changes on every frame of a drag; class does not
      });

      /* ---- the header, as an app rather than a website ----
         A website says its name at the top of every page, because a
         browser tab does not. An installed app already says it on the
         icon you tapped and in the switcher — so the wordmark is the one
         thing in that bar carrying no information, in the place with the
         least room for it. Ink puts the section's own name there instead,
         which is what a native app does, and it is right.

         Only the four tab screens. Settings, Profile and Plans already
         have a back button and an h1.screen-title of their own, so they
         are left alone rather than given a second title.

         Injected, like everything else here: the page keeps its wordmark
         in a browser and has no idea this happened. If a screen id or the
         header class is ever renamed on the site, the title simply does
         not appear — the app does not break, it just looks like the web
         again. */
      var TITLES = {
        'screen-home':     'Home',
        'screen-calendar': 'Calendar',
        'screen-now':      'Lists',
        'screen-notes':    'Notes',
      };

      try {
        var css = document.createElement('style');
        css.textContent =
          /* No zooming at all. A website wants double-tap and pinch; an
             app with a tab bar, a composer and rows you tap to open does
             not — every mis-hit jumps the page to 2x and the person has to
             fight their way back out of a screen they never asked for.

             touch-action is not inherited, but the browser decides what a
             gesture may do by intersecting the value down the whole
             ancestor chain, so one rule at the root covers the page.
             'pan-x pan-y' is 'manipulation' with pinch-zoom removed: the
             page still scrolls, and nothing else.

             This is one of three layers. The viewport below and the scroll
             view lock in WebScreen.swift are the other two, because WebKit
             re-derives its zoom limits from the viewport on every load and
             any single layer leaves a way back in. */
          'html{touch-action:pan-x pan-y}' +

          /* ---- the eyebrows, gone ----
             "SORTED INTO LISTS." and "NOTES." were each screen saying its
             own name in small caps, because the header above them said
             the app's name instead. The header says the screen's name
             now (see TITLES below), so the eyebrow is the same word twice
             in two sizes. The summary line under the lists one goes with
             it — the count is on the tab bar badge and the header of
             every bucket. */
          '#eyebrow,#lists-summary,#notes-eyebrow,#notes-summary{display:none}' +
          /* With the eyebrow gone the chip bar was floating 30-40px below
             the header — the wrap's own top padding plus the header's
             margin, both sized for a label that is no longer there. */
          '#screen-now .now-wrap,#screen-notes .notes-wrap{padding-top:2px}' +
          '#screen-now .brand--sm,#screen-notes .brand--sm{margin-bottom:6px}' +
          '#screen-now .cat-bar{margin-bottom:12px}' +

          /* ---- home: the stats and "Worth a look", gone ----
             Five numbers about the list, and four links to the website —
             the screener, the tools, the blog, the about page. The numbers
             are on the tab-bar badge and every bucket's header; the links
             are the marketing site, and the shell does not go there (see
             AppConfig.inAppPaths). What is left on home is the box and
             the next three things, which is what home is for. */
          '#screen-home .stat-row,#home-discover{display:none}' +

          /* ---- the legal pages, as pages in the app ----
             privacy.html and terms.html open inside the shell. Their
             lockup, "Back to my.adhd" and footer all lead to /, which is
             the website; the header above already has the app's chrome. */
          '.legal-nav .brand-lockup,.legal-back,footer.site-foot,.legal-nav .nav-clock{display:none}' +
          /* The nav keeps its theme toggle, so it needs to clear the status
             bar: the shell draws under it (viewport-fit=cover, no content
             inset). The clock goes — a website nicety, and the phone's own
             status bar is showing the time an inch above it. */
          '.legal-nav{display:flex;align-items:center;gap:10px;min-height:0;' +
            'padding-top:calc(env(safe-area-inset-top,0px) + 6px);margin-bottom:14px}' +
          /* The way back. Both exits the page shipped with — the lockup and
             "Back to my.adhd" — went to /, which is the website and which
             the shell no longer follows. Without this the reader is
             stranded on a legal page with no button out. Styled like the
             app's own settings-back, and pointing at the app. */
          '.myadhd-native-back{display:inline-flex;align-items:center;gap:2px;margin-right:auto;' +
            'font-family:var(--display);font-size:15px;font-weight:600;color:var(--accent);' +
            'text-decoration:none;padding:6px 2px}' +
          '.myadhd-native-back::before{content:"";width:9px;height:9px;border-left:2px solid currentColor;' +
            'border-bottom:2px solid currentColor;transform:rotate(45deg);margin-right:4px}' +

          /* ---- the matrix fits the screen ----
             Two equal rows, the grid as tall as the space between the chip
             bar and the tab bar, and a card that has more rows than fit
             scrolls inside itself. The height is measured, not guessed —
             fitMatrix() below — because the header and chip bar are the
             page's and could change under us. */
          '#matrix.matrix{grid-template-rows:1fr 1fr;min-height:0}' +
          '#matrix .quad{min-height:0;overflow-y:auto;overscroll-behavior:contain}' +

          /* ---- the matrix, as four cards rather than a list ----
             The site stacks the quadrants below 560px, and its own CSS
             says why: a task row at ~170px wraps its chips onto three
             lines and truncates the title to nothing. Inside the shell
             the chips come off the rows instead — the quadrant already
             says how urgent and how important — and the 2x2 stays.

             Colour follows the house rule, not Ink's textbook palette.
             Do now is the one card Vivid Orange is FOR: it means act now.
             Plan takes the accent, Delegate the violet, Drop stays grey.
             Red is never on a card that is not destructive, and there is
             still no green anywhere in the app. Washes are mixed against
             --surface so they read on both grounds without a second set
             of values.

             Everything is scoped under #matrix, which outranks every
             class rule in styles.css, so this wins without !important. */
          '#matrix.matrix{grid-template-columns:1fr 1fr;grid-auto-rows:1fr;align-items:stretch;gap:12px}' +
          '#matrix .quad{position:relative;min-height:204px;border:0;border-left:0;border-radius:24px;padding:18px 16px 16px;gap:8px}' +
          '#matrix .quad--do{background:color-mix(in srgb,var(--orange) 15%,var(--surface))}' +
          '#matrix .quad--plan{background:color-mix(in srgb,var(--accent) 13%,var(--surface))}' +
          '#matrix .quad--delegate{background:color-mix(in srgb,var(--violet) 13%,var(--surface))}' +
          '#matrix .quad--drop{background:var(--wash-2)}' +
          '#matrix .quad-head{align-items:flex-start;gap:8px}' +
          '#matrix .quad-name{font-size:24px;font-weight:800;letter-spacing:-.025em;line-height:1.05}' +
          '#matrix .quad--do .quad-name{color:var(--orange)}' +
          '#matrix .quad--plan .quad-name{color:var(--accent)}' +
          '#matrix .quad--delegate .quad-name{color:var(--violet)}' +
          '#matrix .quad--drop .quad-name{color:var(--muted)}' +
          '#matrix .quad-sub{font-size:12px;color:var(--muted);margin-top:4px;line-height:1.3}' +
          '#matrix .quad-add{width:34px;height:34px;border:0;background:var(--surface);box-shadow:0 1px 3px rgba(16,16,24,.08)}' +
          '#matrix .quad--do .quad-add{color:var(--orange)}' +
          '#matrix .quad--plan .quad-add{color:var(--accent)}' +
          '#matrix .quad--delegate .quad-add{color:var(--violet)}' +
          '#matrix .quad--drop .quad-add{color:var(--muted)}' +
          '#matrix .quad-add svg{width:17px;height:17px}' +
          /* Empty state, centred in whatever height the card has, with a
             tray above it. currentColor, so each card tints its own. */
          '#matrix .quad-empty{margin:auto 0;padding:14px 0 10px;text-align:center;font-size:13px;color:var(--muted);display:flex;flex-direction:column;align-items:center;gap:10px}' +
          '#matrix .quad-empty::before{content:"";width:34px;height:34px;opacity:.55;background:currentColor;' +
            '-webkit-mask:url("data:image/svg+xml;utf8,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 24 24%22 fill=%22none%22 stroke=%22black%22 stroke-width=%221.6%22 stroke-linecap=%22round%22 stroke-linejoin=%22round%22%3E%3Cpath d=%22M3 13l2.2-6.3A2 2 0 0 1 7.1 5.3h9.8a2 2 0 0 1 1.9 1.4L21 13%22/%3E%3Cpath d=%22M3 13v4a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-4%22/%3E%3Cpath d=%22M3 13h5l1.5 2.5h5L16 13h5%22/%3E%3C/svg%3E") center/contain no-repeat}' +
          '#matrix .quad--do .quad-empty{color:var(--orange)}' +
          '#matrix .quad--plan .quad-empty{color:var(--accent)}' +
          '#matrix .quad--delegate .quad-empty{color:var(--violet)}' +
          /* Rows inside a quadrant: title and tick only. Two columns on a
             phone leave ~165px a card, and three lines of chips there is
             the reason the site gave up and stacked them. */
          '#matrix .quad .list-items{gap:8px}' +
          '#matrix .quad .task{padding:10px 10px 10px 8px;border-radius:14px;border-color:transparent;background:color-mix(in srgb,var(--surface) 78%,transparent)}' +
          '#matrix .quad .task-meta{display:none}' +
          '#matrix .quad .task-title{font-size:13.5px;line-height:1.25;-webkit-line-clamp:2;display:-webkit-box;-webkit-box-orient:vertical;overflow:hidden}' +
          '.myadhd-native .brand-lockup{display:none}' +
          '.myadhd-native-title{' +
            'margin:0;font-family:var(--display);' +
            'font-size:clamp(26px,7.5vw,33px);font-weight:800;' +
            'letter-spacing:-.03em;line-height:1.1;color:var(--ink)}';
        document.head.appendChild(css);

        /* The viewport, tightened. The page ships width=device-width,
           initial-scale=1, viewport-fit=cover and nothing about scale, so
           WebKit allows up to 5x. WKWebView still honours user-scalable=no
           — Safari stopped in iOS 10, but this is not Safari — and it
           re-reads the meta when it changes, so patching it late is fine.
           viewport-fit=cover is kept: losing it would put the ground
           back above the status bar. */
        var vp = document.querySelector('meta[name="viewport"]');
        if (vp) {
          var parts = (vp.getAttribute('content') || '')
            .split(',').map(function (p) { return p.trim(); })
            .filter(function (p) { return p && !/^(maximum-scale|minimum-scale|user-scalable)\s*=/.test(p); });
          parts.push('maximum-scale=1', 'minimum-scale=1', 'user-scalable=no');
          vp.setAttribute('content', parts.join(', '));
        }

        Object.keys(TITLES).forEach(function (id) {
          var screen = document.getElementById(id);
          if (!screen) return;
          var bar = screen.querySelector('header.brand');
          if (!bar || bar.querySelector('.myadhd-native-title')) return;

          var h = document.createElement('h1');
          h.className = 'myadhd-native-title';
          h.textContent = TITLES[id];

          /* First child, so it takes the place the lockup had. The tools
             carry margin-left:auto and stay where they are. */
          bar.insertBefore(h, bar.firstChild);
          bar.classList.add('myadhd-native');
        });
      } catch (e) { /* the page moved; leave its own header alone */ }

      /* ---- the legal pages get a way back ---- */
      try {
        var legal = document.querySelector('.legal-nav');
        if (legal && !legal.querySelector('.myadhd-native-back')) {
          var back = document.createElement('a');
          back.className = 'myadhd-native-back';
          back.href = '/app';
          back.textContent = 'Back';
          back.setAttribute('aria-label', 'Back to the app');
          legal.insertBefore(back, legal.firstChild);
        }
      } catch (e) { /* not a legal page, or it moved */ }

      /* ---- fitMatrix: the 2x2 as tall as the screen allows ----
         Runs whenever the lists screen or the matrix changes state, and on
         resize. The matrix is rebuilt by innerHTML on every paint but the
         #matrix container itself survives, so a height set on it holds. */
      (function () {
        var matrix = document.getElementById('matrix');
        var screen = document.getElementById('screen-now');
        var tabbar = document.getElementById('tabbar');
        if (!matrix || !screen) return;

        function fit() {
          if (matrix.classList.contains('is-hidden') || screen.classList.contains('is-hidden')) {
            matrix.style.height = ''; return;
          }
          var top = matrix.getBoundingClientRect().top;
          var bar = tabbar && !tabbar.classList.contains('is-hidden')
            ? (window.innerHeight - tabbar.getBoundingClientRect().top) : 0;
          var h = window.innerHeight - top - bar - 10;
          matrix.style.height = h > 240 ? h + 'px' : '';
        }

        var kick = function () { requestAnimationFrame(fit); };
        window.addEventListener('resize', kick);
        new MutationObserver(kick).observe(screen, { attributes: true, attributeFilter: ['class'] });
        new MutationObserver(kick).observe(matrix, { attributes: true, attributeFilter: ['class'], childList: true });
        kick();
      })();

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

    /// Hands the tokens to auth.js and then rebuilds the page around them.
    ///
    /// Not a plain load of `/app#access_token=…`, which is the obvious thing
    /// and does not work: WebKit treats a URL differing from the current one
    /// only by its fragment as a same-document navigation, so the document is
    /// never re-executed and absorbRedirect() — which runs once, at boot —
    /// never sees the tokens at all.
    ///
    /// So they go to auth.js directly, which writes the session to
    /// localStorage. The reload afterwards is what rebuilds the UI from it,
    /// and it is also the only thing that can reset the sign-in button:
    /// app.js disables it and relabels it "Taking you to Google…" on its way
    /// out, which is safe on the web because the page is about to be
    /// destroyed, and leaves it stuck there for ever in a shell that
    /// cancelled the navigation instead.
    static func absorb(fragment: String) -> String {
        """
        (function () {
          location.hash = \(jsString(fragment));
          function reboot() { location.reload(); }
          if (window.auth && window.auth.absorbRedirect) {
            try {
              Promise.resolve(window.auth.absorbRedirect()).then(reboot, reboot);
              return;
            } catch (e) { /* fall through to the plain reload */ }
          }
          reboot();
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
