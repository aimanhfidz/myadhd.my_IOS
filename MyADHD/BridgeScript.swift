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
          /* ---- how the matrix works: the ? and its four pages ---- */
          '.myadhd-native-help{font-family:var(--display);font-size:16px;font-weight:700;line-height:1}' +
          '.wk{position:fixed;inset:0;z-index:60;background:var(--surface);color:var(--ink);display:none;flex-direction:column;' +
            'padding:calc(env(safe-area-inset-top,0px) + 10px) 20px calc(env(safe-area-inset-bottom,0px) + 18px)}' +
          '.wk.is-open{display:flex}' +
          '.wk-bar{display:grid;grid-template-columns:40px 1fr 40px;align-items:center;margin-bottom:22px}' +
          '.wk-bar h2{grid-column:2;margin:0;text-align:center;font-family:var(--display);font-size:15px;font-weight:600}' +
          '.wk-x{grid-column:3;width:40px;height:40px;border-radius:999px;border:0;background:var(--wash);color:var(--ink);font-size:22px;line-height:1;display:grid;place-items:center;padding:0}' +
          '.wk-page{display:none;flex:1;flex-direction:column;min-height:0}' +
          '.wk-page.is-on{display:flex}' +
          '.wk-page h1{font-family:var(--display);font-size:clamp(26px,7.5vw,32px);font-weight:800;letter-spacing:-.03em;line-height:1.08;margin:0 0 8px}' +
          '.wk-page p{margin:0 0 22px;font-size:15.5px;line-height:1.4;color:var(--muted)}' +
          '.wk-art{flex:1;min-height:0;display:flex;flex-direction:column}' +
          '.wk-rows{display:flex;flex-direction:column;gap:8px}' +
          '.wk-row{display:flex;align-items:center;gap:12px;background:var(--wash);border-radius:14px;padding:11px 14px;font-size:14px;font-weight:500}' +
          '.wk-ring{flex:none;width:18px;height:18px;border-radius:50%;border:2px solid var(--c)}' +
          '.wk-grid{display:grid;grid-template-columns:1fr 1fr;grid-template-rows:1fr 1fr;gap:12px;flex:1;min-height:0}' +
          '.wk-quad{border-radius:20px;padding:14px;background:color-mix(in srgb,var(--c) 13%,var(--surface));display:flex;flex-direction:column;gap:9px;min-height:0;overflow:hidden}' +
          '.wk-quad h3{margin:0 0 2px;font-family:var(--display);font-size:17px;font-weight:800;letter-spacing:-.02em;color:var(--c)}' +
          '.wk-quad .wk-row{background:transparent;padding:0;gap:9px;font-size:13px}' +
          '.wk-quad .wk-ring{width:16px;height:16px}' +
          '.wk-phone{flex:1;min-height:0;margin:0 10px;border:5px solid var(--ink);border-bottom:0;border-radius:38px 38px 0 0;padding:20px 14px 0;' +
            'background:linear-gradient(180deg,color-mix(in srgb,var(--accent) 10%,var(--surface)),var(--surface));display:flex;flex-direction:column;gap:14px;overflow:hidden}' +
          '.wk-page p.wk-date{text-align:center;font-size:13px;color:var(--muted);margin:0}' +
          '.wk-page p.wk-time{text-align:center;font-family:var(--display);font-size:54px;font-weight:700;letter-spacing:-.04em;line-height:1;color:var(--ink);margin:0 0 6px}' +
          '.wk-page p.wk-eyebrow{margin:0 0 8px}' +
          '.wk-widget{background:var(--surface);border-radius:20px;padding:14px 14px 12px;margin:6px 2px 0;box-shadow:0 4px 18px rgba(16,16,24,.08)}' +
          '.wk-widget .wk-eyebrow{font-size:9.5px;font-weight:700;letter-spacing:.09em;color:var(--muted);margin:0 0 8px}' +
          '.wk-widget .wk-row{background:transparent;padding:5px 0;gap:9px;font-size:13.5px;font-family:var(--display);font-weight:600}' +
          '.wk-widget .wk-row .wk-ring{border-color:var(--line-strong)}' +
          '.wk-widget .wk-row.is-done .wk-ring{background:var(--accent);border-color:var(--accent)}' +
          '.wk-widget .wk-row.is-done span{text-decoration:line-through;color:var(--muted)}' +
          '.wk-dots{display:flex;justify-content:center;gap:9px;margin:18px 0}' +
          '.wk-dots i{width:7px;height:7px;border-radius:50%;background:var(--line-strong);display:block}' +
          '.wk-dots i.is-on{background:var(--ink)}' +
          '.wk-foot{display:flex;gap:12px;align-items:center}' +
          '.wk-back{flex:none;width:52px;height:52px;border-radius:999px;border:0;background:var(--wash);color:var(--ink);display:grid;place-items:center;padding:0}' +
          '.wk-back::before{content:"";width:10px;height:10px;border-left:2.5px solid currentColor;border-bottom:2.5px solid currentColor;transform:rotate(45deg);margin-left:4px}' +
          '.wk-foot .btn-primary{flex:1;min-height:52px}' +
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
          /* The four quadrant hues, from the brand guidelines: red is
             --danger, purple is --violet, orange is --orange. There is no
             green in the guidelines at all, so Drop's is chosen to sit
             with the other three — mid-saturation, similar weight to the
             orange — with a lighter cut for dark grounds the way
             --danger-ink is to --danger. One variable to change. */
          ':root{--q-do:var(--danger);--q-plan:var(--violet);--q-delegate:var(--orange);--q-drop:#1F8A45}' +
          'html[data-theme="dark"]{--q-do:var(--danger-ink,#FF8A7E);--q-plan:#A97BFF;--q-drop:#4CC47A}' +
          '@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--q-do:var(--danger-ink,#FF8A7E);--q-plan:#A97BFF;--q-drop:#4CC47A}}' +
          '#matrix .quad--do{background:color-mix(in srgb,var(--q-do) 13%,var(--surface))}' +
          '#matrix .quad--plan{background:color-mix(in srgb,var(--q-plan) 13%,var(--surface))}' +
          '#matrix .quad--delegate{background:color-mix(in srgb,var(--q-delegate) 14%,var(--surface))}' +
          '#matrix .quad--drop{background:color-mix(in srgb,var(--q-drop) 13%,var(--surface))}' +
          '#matrix .quad-head{align-items:flex-start;gap:8px}' +
          '#matrix .quad-name{font-size:24px;font-weight:800;letter-spacing:-.025em;line-height:1.05}' +
          '#matrix .quad--do .quad-name{color:var(--q-do)}' +
          '#matrix .quad--plan .quad-name{color:var(--q-plan)}' +
          '#matrix .quad--delegate .quad-name{color:var(--q-delegate)}' +
          '#matrix .quad--drop .quad-name{color:var(--q-drop)}' +
          '#matrix .quad-sub{font-size:12px;color:var(--muted);margin-top:4px;line-height:1.3}' +
          '#matrix .quad-add{width:34px;height:34px;border:0;background:var(--surface);box-shadow:0 1px 3px rgba(16,16,24,.08)}' +
          '#matrix .quad--do .quad-add{color:var(--q-do)}' +
          '#matrix .quad--plan .quad-add{color:var(--q-plan)}' +
          '#matrix .quad--delegate .quad-add{color:var(--q-delegate)}' +
          '#matrix .quad--drop .quad-add{color:var(--q-drop)}' +
          '#matrix .quad-add svg{width:17px;height:17px}' +
          /* Empty state, centred in whatever height the card has, with a
             tray above it. currentColor, so each card tints its own. */
          '#matrix .quad-empty{margin:auto 0;padding:14px 0 10px;text-align:center;font-size:13px;color:var(--muted);display:flex;flex-direction:column;align-items:center;gap:10px}' +
          '#matrix .quad-empty::before{content:"";width:34px;height:34px;opacity:.55;background:currentColor;' +
            '-webkit-mask:url("data:image/svg+xml;utf8,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 24 24%22 fill=%22none%22 stroke=%22black%22 stroke-width=%221.6%22 stroke-linecap=%22round%22 stroke-linejoin=%22round%22%3E%3Cpath d=%22M3 13l2.2-6.3A2 2 0 0 1 7.1 5.3h9.8a2 2 0 0 1 1.9 1.4L21 13%22/%3E%3Cpath d=%22M3 13v4a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-4%22/%3E%3Cpath d=%22M3 13h5l1.5 2.5h5L16 13h5%22/%3E%3C/svg%3E") center/contain no-repeat}' +
          '#matrix .quad--do .quad-empty{color:var(--q-do)}' +
          '#matrix .quad--plan .quad-empty{color:var(--q-plan)}' +
          '#matrix .quad--delegate .quad-empty{color:var(--q-delegate)}' +
          '#matrix .quad--drop .quad-empty{color:var(--q-drop)}' +
          /* Rows inside a quadrant: title and tick only. Two columns on a
             phone leave ~165px a card, and three lines of chips there is
             the reason the site gave up and stacked them. */
          '#matrix .quad .list-items{gap:8px}' +
          /* Ink's rows: no card behind each task, a small ring in the
             quadrant's own hue, and the title at reading size. A white
             pill per row inside a tinted card was a card inside a card. */
          '#matrix .quad .list-items{gap:1px}' +
          '#matrix .quad .task{padding:5px 0 5px 1px;gap:9px;border:0;border-radius:8px;background:transparent;align-items:center}' +
          '#matrix .quad .task-check{width:18px;height:18px;margin-top:0;border-width:1.5px}' +
          '#matrix .quad--do .task-check{border-color:var(--q-do)}' +
          '#matrix .quad--plan .task-check{border-color:var(--q-plan)}' +
          '#matrix .quad--delegate .task-check{border-color:var(--q-delegate)}' +
          '#matrix .quad--drop .task-check{border-color:var(--q-drop)}' +
          '#matrix .quad .task-meta{display:none}' +
          '#matrix .quad .task-title{font-size:12.5px;font-weight:500;line-height:1.25;-webkit-line-clamp:2;display:-webkit-box;-webkit-box-orient:vertical;overflow:hidden}' +

          /* ---- pull to refresh, with the header staying put ----
             #app is the scroller and the header is sticky INSIDE it, so
             the rubber-band at the top carried the header down with it
             and opened a blank strip above. overscroll-behavior:none
             stops the bounce; the pull is then ours to draw, and it
             draws the way Ink's does — the header fixed, and the app's
             own mark spinning in a strip under it. */
          '#app{overscroll-behavior-y:none}' +
          '.myadhd-native-refresh{height:0;overflow:hidden;display:flex;align-items:center;justify-content:center;transition:height .22s var(--ease)}' +
          '.myadhd-native-refresh.is-pulling{transition:none}' +
          '.myadhd-native-refresh svg{width:30px;height:30px;color:var(--accent);opacity:0;transition:opacity .15s,transform .15s}' +
          '.myadhd-native-refresh.is-armed svg,.myadhd-native-refresh.is-loading svg{opacity:1}' +
          '.myadhd-native-refresh.is-loading svg{animation:myadhd-spin .8s linear infinite}' +
          '@keyframes myadhd-spin{to{transform:rotate(360deg)}}' +
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

      /* ---- how the matrix works ----
         A ? beside List/Matrix, and four pages behind it. The sample tasks
         are made up — the point is the shape, not the person's list — and
         the fourth page shows what this app actually puts on a home
         screen, which is the Today widget, not a wallpaper. */
      (function () {
        var tools = document.querySelector('#screen-now .brand-tools');
        var view = document.getElementById('btn-view');
        if (!tools || !view || document.querySelector('.myadhd-native-help')) return;

        var help = document.createElement('button');
        help.type = 'button';
        help.className = 'icon-btn myadhd-native-help';
        help.setAttribute('aria-label', 'How the matrix works');
        help.textContent = '?';
        tools.insertBefore(help, view);

        var Q = { do: 'var(--q-do)', plan: 'var(--q-plan)', delegate: 'var(--q-delegate)', drop: 'var(--q-drop)' };
        var T = [
          ['Send the invoice', 'do'], ['Sort old photos', 'drop'], ['Plan next month', 'plan'],
          ['Reply to the vendor', 'delegate'], ['Pay the rent', 'do'], ['Watch that series', 'drop'],
          ['Book the flights', 'delegate'], ['Save for the trip', 'plan']
        ];
        function row(t, q, extra) {
          return '<div class="wk-row' + (extra || '') + '"><i class="wk-ring" style="--c:' + Q[q] + '"></i><span>' + t + '</span></div>';
        }
        function quad(key, name, rows) {
          return '<div class="wk-quad" style="--c:' + Q[key] + '"><h3>' + name + '</h3>' + rows.join('') + '</div>';
        }
        function grid(moved) {
          var by = { do: [], plan: [], delegate: [], drop: [] };
          T.forEach(function (x) {
            var q = x[1];
            if (moved && x[0] === 'Pay the rent') { by.plan.push(row(x[0], 'do')); return; }
            by[q].push(row(x[0], q));
          });
          return '<div class="wk-grid">' + quad('do', 'Do now', by.do) + quad('plan', 'Plan', by.plan) +
                 quad('delegate', 'Delegate', by.delegate) + quad('drop', 'Drop', by.drop) + '</div>';
        }
        var pages = [
          { h: 'One list, no order', p: 'Everything shouts the same. Nothing says what to do first.', cta: 'Sort them into boxes',
            art: '<div class="wk-rows">' + T.map(function (x) { return row(x[0], x[1]); }).join('') + '</div>' },
          { h: 'Four boxes, one decision', p: 'Urgent and important first. The rest waits, moves, or goes.', cta: 'Move one', art: grid(false) },
          { h: 'Hold, then drag', p: 'Press a task and drop it in another box. Nothing is stuck where it landed.', cta: 'See it on the home screen', art: grid(true) },
          { h: 'On your home screen', p: 'The Today widget shows the next few things every time you look — and you can tick one off right there.', cta: 'Done',
            art: '<div class="wk-phone"><p class="wk-date">Friday, 18 September</p><p class="wk-time">05:59</p>' +
                 '<div class="wk-widget"><p class="wk-eyebrow">TODAY</p>' + row('Send the invoice', 'do', ' is-done') + row('Pay the rent', 'do') + row('Plan next month', 'plan') + '</div></div>' }
        ];

        var wk = null, at = 0;
        function build() {
          wk = document.createElement('div');
          wk.className = 'wk';
          wk.setAttribute('role', 'dialog');
          wk.setAttribute('aria-label', 'How the matrix works');
          wk.innerHTML =
            '<div class="wk-bar"><h2>How the matrix works</h2><button type="button" class="wk-x" aria-label="Close">×</button></div>' +
            pages.map(function (pg) {
              return '<section class="wk-page"><h1>' + pg.h + '</h1><p>' + pg.p + '</p><div class="wk-art">' + pg.art + '</div></section>';
            }).join('') +
            '<div class="wk-dots">' + pages.map(function () { return '<i></i>'; }).join('') + '</div>' +
            '<div class="wk-foot"><button type="button" class="wk-back" aria-label="Back"></button><button type="button" class="btn-primary wk-next"><span class="btn-text"></span></button></div>';
          document.body.appendChild(wk);
          wk.querySelector('.wk-x').addEventListener('click', close);
          wk.querySelector('.wk-back').addEventListener('click', function () { go(at - 1); });
          wk.querySelector('.wk-next').addEventListener('click', function () { at === pages.length - 1 ? close() : go(at + 1); });
        }
        function go(n) {
          at = Math.max(0, Math.min(pages.length - 1, n));
          var ps = wk.querySelectorAll('.wk-page'), ds = wk.querySelectorAll('.wk-dots i');
          for (var i = 0; i < ps.length; i++) { ps[i].classList.toggle('is-on', i === at); ds[i].classList.toggle('is-on', i === at); }
          wk.querySelector('.wk-back').style.visibility = at === 0 ? 'hidden' : 'visible';
          wk.querySelector('.wk-next .btn-text').textContent = pages[at].cta;
          try { post('haptic', { kind: 'selection' }); } catch (e) {}
        }
        function open()  { if (!wk) build(); wk.classList.add('is-open'); go(0); }
        function close() { if (wk) wk.classList.remove('is-open'); }
        help.addEventListener('click', open);
      })();

      /* ---- "Write one" reads better as what it does ---- */
      try {
        var first = document.querySelector('#btn-note-first .btn-text');
        if (first) first.textContent = 'Write a note';
      } catch (e) {}

      /* ---- swipe from the left edge to go back ----
         The page is one document — Home, Lists, Settings are shown and
         hidden, never navigated — so WebKit's own back gesture has nothing
         to pop, and it stays off (see WebScreen). This does what a person
         means by the gesture: whatever the screen's own back control is,
         it gets pressed. In order — a sheet inside the note editor, the
         walkthrough's back or close, a screen's back button, the
         composer's Cancel, the legal page's Back, and failing all of
         those, home. Starts only in the outer 22px so it cannot be
         mistaken for the swipe that ticks a task off. */
      (function () {
        var x0 = null, y0 = null, armed = false, dead = false;
        var EDGE = 22, ARM = 70;

        function visible(el) { return !!(el && el.offsetParent !== null); }
        function firstVisible(sel, root) {
          var list = (root || document).querySelectorAll(sel);
          for (var i = 0; i < list.length; i++) if (visible(list[i])) return list[i];
          return null;
        }
        function back() {
          var wk = document.querySelector('.wk.is-open');
          if (wk) {
            var wb = wk.querySelector('.wk-back');
            (wb && wb.style.visibility !== 'hidden' ? wb : wk.querySelector('.wk-x')).click();
            return true;
          }
          var sheet = firstVisible('.note-sheet-x');
          if (sheet) { sheet.click(); return true; }
          var screen = document.querySelector('.screen:not(.is-hidden)');
          var btn = screen && firstVisible('.sheet-back, .settings-back', screen);
          if (btn) { btn.click(); return true; }
          var bar = firstVisible('.composer-bar');
          if (bar) { var c = bar.querySelector('button'); if (c) { c.click(); return true; } }
          var legal = firstVisible('.myadhd-native-back');
          if (legal) { legal.click(); return true; }
          if (screen && screen.id !== 'screen-home') {
            var home = document.getElementById('tab-home');
            if (home) { home.click(); return true; }
          }
          return false;
        }

        document.addEventListener('touchstart', function (e) {
          if (e.touches.length !== 1) { x0 = null; return; }
          var t = e.touches[0];
          if (t.clientX > EDGE) { x0 = null; return; }
          x0 = t.clientX; y0 = t.clientY; armed = false; dead = false;
        }, { passive: true, capture: true });

        document.addEventListener('touchmove', function (e) {
          if (x0 === null || dead) return;
          var t = e.touches[0], dx = t.clientX - x0, dy = Math.abs(t.clientY - y0);
          if (dy > 40 && dx < 30) { dead = true; return; }
          if (dx >= ARM && !armed) { armed = true; try { post('haptic', { kind: 'light' }); } catch (err) {} }
        }, { passive: true, capture: true });

        function end() {
          if (x0 !== null && armed && !dead) back();
          x0 = null; armed = false; dead = false;
        }
        document.addEventListener('touchend', end, { passive: true, capture: true });
        document.addEventListener('touchcancel', end, { passive: true, capture: true });
      })();

      /* ---- pull to refresh ----
         A real refresh, not a spinner for its own sake: the page's cloud
         pass runs if there is an account, the screen repaints, and the
         shell is told — which rewrites the widget snapshot and drains
         any ticks taken on a tile. Then the strip closes. */
      (function () {
        var app = document.getElementById('app');
        if (!app) return;
        var startY = null, slot = null, pulling = false, loading = false;
        var ARM = 60, MAX = 84;

        function slotFor() {
          var bar = document.querySelector('.screen:not(.is-hidden) > header.brand.myadhd-native');
          if (!bar) return null;
          var next = bar.nextElementSibling;
          if (next && next.classList.contains('myadhd-native-refresh')) return next;
          var el = document.createElement('div');
          el.className = 'myadhd-native-refresh';
          el.innerHTML = '<svg viewBox="0 0 100 100" aria-hidden="true"><use href="#logo-mark"/></svg>';
          bar.parentNode.insertBefore(el, bar.nextSibling);
          return el;
        }

        function refresh(done) {
          var waits = [new Promise(function (r) { setTimeout(r, 750); })];
          try { post('refresh', {}); } catch (e) {}
          try {
            if (window.cloud && cloud.configured && cloud.configured() && cloud.now) {
              var p = cloud.now(); if (p && p.then) waits.push(p.catch(function () {}));
            }
          } catch (e) {}
          try {
            var now = document.querySelector('.screen:not(.is-hidden)');
            if (now && now.id === 'screen-now'  && typeof repaintLists === 'function') repaintLists();
            if (now && now.id === 'screen-home' && typeof renderHome   === 'function') renderHome();
          } catch (e) {}
          Promise.all(waits).then(done, done);
        }

        app.addEventListener('touchstart', function (e) {
          if (loading || app.scrollTop > 0 || e.touches.length !== 1) { startY = null; return; }
          startY = e.touches[0].clientY; pulling = false;
        }, { passive: true });

        app.addEventListener('touchmove', function (e) {
          if (startY === null || loading) return;
          var dy = e.touches[0].clientY - startY;
          if (dy <= 0 || app.scrollTop > 0) { if (pulling && slot) { slot.style.height = '0px'; slot.classList.remove('is-armed'); } return; }
          slot = slot || slotFor(); if (!slot) return;
          pulling = true;
          var h = Math.min(MAX, dy * 0.55);
          slot.classList.add('is-pulling');
          slot.style.height = h + 'px';
          var armed = h >= ARM;
          if (armed && !slot.classList.contains('is-armed')) { try { post('haptic', { kind: 'light' }); } catch (e) {} }
          slot.classList.toggle('is-armed', armed);
        }, { passive: true });

        function end() {
          if (startY === null) return;
          startY = null;
          if (!pulling || !slot) return;
          pulling = false;
          slot.classList.remove('is-pulling');
          if (slot.classList.contains('is-armed')) {
            loading = true;
            slot.style.height = ARM + 'px';
            slot.classList.add('is-loading');
            refresh(function () {
              slot.classList.remove('is-loading', 'is-armed');
              slot.style.height = '0px';
              loading = false;
            });
          } else {
            slot.classList.remove('is-armed');
            slot.style.height = '0px';
          }
        }
        app.addEventListener('touchend', end, { passive: true });
        app.addEventListener('touchcancel', end, { passive: true });
      })();

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
