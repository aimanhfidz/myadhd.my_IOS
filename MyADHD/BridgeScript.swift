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
        /* Kept as a name so a page that calls it never throws; it does
           nothing. Haptics were removed from the shell on 2026-09-18. */
        haptic: function () {},
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
          /* Nothing here is prose to copy. A long press on a tab, an hour
             label or a block was selecting it and offering Copy, Look Up,
             Translate — a browser's affordance in an app. Off everywhere,
             back on for the places a person actually types. */
          'html,body{-webkit-user-select:none;user-select:none;-webkit-touch-callout:none}' +
          'input,textarea,[contenteditable],[contenteditable] *{-webkit-user-select:text;user-select:text}' +

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
          /* ---- the interactive pop ---- */
          '#app.myadhd-sliding{position:relative;z-index:2;will-change:transform;box-shadow:-10px 0 28px rgba(16,16,24,.16)}' +
          '.myadhd-ghost-layer{position:fixed;inset:0;z-index:1;overflow:hidden;pointer-events:none;background:var(--surface)}' +
          '.myadhd-ghost{position:absolute;inset:0;overflow:hidden;will-change:transform}' +
          '.myadhd-ghost-dim{position:absolute;inset:0;background:#000}' +
          /* Release: UIKit's pop is about a quarter second on an ease-out. */
          '#app.myadhd-settling,.myadhd-settling .myadhd-ghost,.myadhd-settling .myadhd-ghost-dim{transition:transform .27s cubic-bezier(.2,.8,.2,1),opacity .27s cubic-bezier(.2,.8,.2,1)}' +
          /* ---- the theme toggle lives on home, and only there ----
             One switch for the whole app is enough; a copy in every header
             was a control that did the same thing from five places. */
          '.screen:not(#screen-home) .theme-toggle,.legal-nav .theme-toggle{display:none}' +

          /* ---- the note editor's tools, as a rail on the right ----
             They sat in a pill at the bottom, and the keyboard's accessory
             bar (removed natively now, see QuietKeyboard.swift) drew over
             them. A vertical rail at mid-height on the right is Ink's
             answer and it is the right one: the keyboard never reaches it,
             and the thumb does. */
          /* ---- notes: once there is one, the button becomes a + ----
             A full-width "New note" above a list of notes is a banner for
             the one thing the screen is already about. Ink puts a round +
             at the bottom right and it reads immediately. Same button,
             same handler — restyled by :has(), so with no notes the empty
             state and its "Write a note" are exactly as they were. Ink
             colour, the app's way: the ink colour, which is near-black by
             day and near-white by night. */
          '#screen-notes:has(#notes-list > *) #btn-note-new{position:fixed;right:18px;bottom:calc(env(safe-area-inset-bottom,0px) + 90px);' +
            'width:60px;height:60px;padding:0;border-radius:999px;z-index:44;background:var(--ink);color:var(--surface);' +
            'box-shadow:0 10px 26px rgba(16,16,24,.22);display:grid;place-items:center}' +
          '#screen-notes:has(#notes-list > *) #btn-note-new .btn-text{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}' +
          '#screen-notes:has(#notes-list > *) #btn-note-new::before{content:"";width:22px;height:2.5px;background:currentColor;border-radius:2px;position:absolute}' +
          '#screen-notes:has(#notes-list > *) #btn-note-new::after{content:"";width:2.5px;height:22px;background:currentColor;border-radius:2px;position:absolute}' +
          '#screen-notes:has(#notes-list > *) .notes-wrap{padding-bottom:calc(env(safe-area-inset-bottom,0px) + 160px)}' +
          /* ---- the editor comes up, not on ----
             .screen toggles display, so the editor appeared in one frame.
             Restarting a keyframe each time it is shown gives it a rise
             from the bottom edge; the rail is inside the screen and rides
             up with it. */
          '#screen-note:not(.is-hidden){animation:myadhd-sheet-up .34s cubic-bezier(.2,.8,.2,1) both}' +
          '@keyframes myadhd-sheet-up{from{transform:translateY(100%)}to{transform:none}}' +
          '#screen-note #note-tools{position:fixed;left:auto;right:12px;bottom:auto;top:46%;transform:translateY(-50%);' +
            'flex-direction:column;width:54px;padding:10px 0;gap:4px;border-radius:999px;z-index:30;' +
            'background:color-mix(in srgb,var(--surface) 84%,transparent);-webkit-backdrop-filter:blur(16px);backdrop-filter:blur(16px);' +
            'box-shadow:0 8px 28px rgba(16,16,24,.14);border:1px solid color-mix(in srgb,var(--line) 70%,transparent)}' +
          '#screen-note .note-tool{width:44px;height:44px;border-radius:999px}' +
          '#screen-note .note-tool svg{width:22px;height:22px}' +
          '#screen-note .note-canvas{padding-right:22px}' +
          /* ---- the editor's two sheets, as bottom sheets ----
             They were centred by left:50% and translateX(-50%), and the
             translate was losing to the rise animation's fill, so the
             sheet's LEFT edge sat at the middle of the screen and half of
             it was off the right. Anchored to the bottom edge instead —
             no transform to fight over, and Ink's shape: full width,
             rounded on top, sitting on the safe area. */
          '#screen-note .note-sheet{left:0;right:0;bottom:0;top:auto;width:auto;max-width:none;transform:none;' +
            'border-radius:26px 26px 0 0;border-width:1.5px 0 0;padding:14px 20px calc(env(safe-area-inset-bottom,0px) + 22px);' +
            'box-shadow:0 -12px 40px rgba(16,16,24,.18);animation:myadhd-rise .22s cubic-bezier(.2,.8,.2,1) both}' +
          '#screen-note .note-sheet::before{content:"";display:block;width:36px;height:5px;border-radius:999px;background:var(--line-strong);margin:-4px auto 12px}' +
          '@keyframes myadhd-rise{from{transform:translateY(28px);opacity:0}to{transform:none;opacity:1}}' +
          /* WebKit gives date and time inputs an intrinsic width and they
             overflowed the sheet on the right; the select beside them did
             not. Pin every field in the sheet to its column. */
          '#screen-note .note-sheet input,#screen-note .note-sheet select{width:100%;max-width:100%;min-width:0;box-sizing:border-box;-webkit-appearance:none;appearance:none}' +
          '#screen-note .note-sheet-title{font-size:16px}' +
          '#screen-note .note-sheet-x{width:36px;height:36px;border-radius:999px;background:var(--wash);color:var(--ink)}' +

          /* ---- the calendar: list, day, week, and the month it already had ---- */
          '.myadhd-calview{display:flex;gap:2px;padding:3px;border-radius:999px;background:var(--wash);border:1.5px solid var(--line)}' +
          '.myadhd-calview button{width:34px;height:30px;border:0;border-radius:999px;background:transparent;color:var(--muted);display:grid;place-items:center;padding:0}' +
          '.myadhd-calview button svg{width:17px;height:17px}' +
          '.myadhd-calview button.is-on{background:var(--surface);color:var(--ink);box-shadow:0 1px 3px rgba(16,16,24,.10)}' +
          '.myadhd-cal-pane{display:none;flex-direction:column;min-height:0}' +
          '.myadhd-cal-pane.is-on{display:flex}' +
          '#screen-calendar.myadhd-view-list #cal-months,#screen-calendar.myadhd-view-list #cal-tip,#screen-calendar.myadhd-view-list #cal-agenda,' +
          '#screen-calendar.myadhd-view-day #cal-months,#screen-calendar.myadhd-view-day #cal-tip,#screen-calendar.myadhd-view-day #cal-agenda,#screen-calendar.myadhd-view-day #cal-undated,' +
          '#screen-calendar.myadhd-view-week #cal-months,#screen-calendar.myadhd-view-week #cal-tip,#screen-calendar.myadhd-view-week #cal-agenda,#screen-calendar.myadhd-view-week #cal-undated{display:none}' +
          /* the week strip: Mon to Sun of the picked week */
          '.myadhd-wk{display:grid;grid-template-columns:repeat(7,1fr);gap:4px;margin:2px 0 12px}' +
          '.myadhd-wk button{border:0;background:transparent;border-radius:14px;padding:8px 0 7px;display:flex;flex-direction:column;align-items:center;gap:3px;color:var(--ink)}' +
          '.myadhd-wk button small{font-size:11px;font-weight:600;color:var(--muted)}' +
          '.myadhd-wk button b{font-family:var(--display);font-size:19px;font-weight:700;line-height:1}' +
          '.myadhd-wk button.is-picked{background:color-mix(in srgb,var(--accent) 14%,var(--surface))}' +
          '.myadhd-wk button.is-picked b,.myadhd-wk button.is-picked small{color:var(--accent)}' +
          '.myadhd-wk button.is-today b{text-decoration:underline;text-decoration-thickness:2px;text-underline-offset:3px}' +
          /* the hour grid, shared by day and week */
          /* The grid used to scroll inside itself, inside the page — two
             scrollers, and a finger never knew which one it had. Now the
             page is the only scroller and the grid is just tall. What
             stays put is the month row and the week strip, stuck under
             the header, so the hours scroll beneath them the way Ink's
             do. Their offsets are measured, not guessed — see render(). */
          '.myadhd-grid{position:relative;border-top:1px solid var(--line)}' +
          '#screen-calendar.myadhd-view-day .cal-head,#screen-calendar.myadhd-view-week .cal-head{position:sticky;top:calc(var(--safe-top,0px) + var(--myadhd-hdr,54px));z-index:6;background:var(--surface);margin:0;padding-bottom:6px}' +
          '#screen-calendar.myadhd-view-day .myadhd-wk,#screen-calendar.myadhd-view-week .myadhd-colhead{position:sticky;top:calc(var(--safe-top,0px) + var(--myadhd-hdr,54px) + var(--myadhd-calhead,58px));z-index:6;background:var(--surface);margin:0;padding:4px 0 8px}' +
          '#screen-calendar.myadhd-view-day .cal-wrap,#screen-calendar.myadhd-view-week .cal-wrap{padding-bottom:calc(env(safe-area-inset-bottom,0px) + 120px)}' +
          '.myadhd-grid-in{position:relative;display:grid;grid-template-columns:44px 1fr}' +
          '.myadhd-hours{display:grid;grid-auto-rows:var(--hh)}' +
          '.myadhd-hours span{font-size:10.5px;color:var(--faint);transform:translateY(-6px);padding-left:2px}' +
          '.myadhd-cols{position:relative;display:grid;grid-template-columns:repeat(var(--cols),1fr)}' +
          '.myadhd-col{position:relative;height:calc(var(--hh) * 24);border-left:1px solid var(--line);' +
            'background:repeating-linear-gradient(to bottom,var(--line) 0 1px,transparent 1px var(--hh))}' +
          '.myadhd-blk{position:absolute;left:3px;right:3px;border-radius:8px;padding:4px 6px 4px 8px;overflow:hidden;' +
            'background:color-mix(in srgb,var(--accent) 15%,var(--surface));border-left:3px solid var(--accent);font-size:12px;line-height:1.25}' +
          '.myadhd-blk b{display:block;font-family:var(--display);font-weight:600;font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}' +
          '.myadhd-blk small{display:block;color:var(--muted);font-size:10.5px}' +
          '.myadhd-blk.is-late{background:color-mix(in srgb,var(--orange) 15%,var(--surface));border-left-color:var(--orange)}' +
          '.myadhd-blk.is-done{opacity:.45}' +
          '.myadhd-blk.is-done b{text-decoration:line-through}' +
          '.myadhd-view-week .myadhd-blk{padding:3px 3px 3px 5px;border-radius:6px;border-left-width:2px}' +
          '.myadhd-view-week .myadhd-blk b{font-size:9.5px;font-weight:600}' +
          '.myadhd-view-week .myadhd-blk small{display:none}' +
          '.myadhd-now{position:absolute;left:0;right:0;height:2px;background:var(--danger);z-index:2;pointer-events:none}' +
          '.myadhd-now::before{content:"";position:absolute;left:-5px;top:-4px;width:10px;height:10px;border-radius:50%;background:var(--danger)}' +
          '.myadhd-colhead{display:grid;grid-template-columns:44px repeat(var(--cols),1fr);margin-bottom:6px}' +
          '.myadhd-colhead span{text-align:center;font-size:12px;color:var(--muted)}' +
          '.myadhd-colhead span b{color:var(--ink);font-weight:700}' +
          '.myadhd-colhead span.is-today b{color:var(--accent)}' +
          '.myadhd-anytime{display:flex;flex-wrap:wrap;gap:6px;margin:0 0 10px}' +
          '.myadhd-anytime span{font-size:12px;padding:5px 10px;border-radius:999px;background:var(--wash);border:1px solid var(--line)}' +
          '.myadhd-anytime i{font-style:normal;font-size:11px;color:var(--muted);align-self:center}' +
          '.myadhd-cal-list .cal-group{margin-bottom:18px}' +
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
          /* A row in a quadrant is a line in a list, not the task's page.
             Tapping one opened the first step, the break-it-down button
             and Edit/Remove inside a 165px card, which is the wrong place
             for any of it. The detail stays shut here; the list view has
             the room and keeps the behaviour. */
          '#matrix .quad .task .task-detail{display:none !important}' +
          '#matrix .quad .task-title{font-size:12.5px;font-weight:500;line-height:1.25;-webkit-line-clamp:2;display:-webkit-box;-webkit-box-orient:vertical;overflow:hidden}' +

          /* ---- pull to refresh, with the header staying put ----
             #app is the scroller and the header is sticky INSIDE it, so
             the rubber-band at the top carried the header down with it
             and opened a blank strip above. overscroll-behavior:none
             stops the bounce; the pull is then ours to draw, and it
             draws the way Ink's does — the header fixed, and the app's
             own mark spinning in a strip under it. */
          '#app,.myadhd-ghost{overscroll-behavior-y:none}' +
          '.myadhd-native-refresh{height:0;overflow:hidden;display:flex;align-items:center;justify-content:center;transition:height .22s var(--ease)}' +
          '.myadhd-native-refresh.is-pulling{transition:none}' +
          '.myadhd-native-refresh svg{width:36px;height:36px;color:var(--accent);opacity:0;transition:opacity .15s,transform .15s}' +
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

      /* ---- swipe from the left edge to go back, the way iOS does it ----
         The page is one document — Home, Lists, Settings are shown and
         hidden, never navigated — so WebKit's own back gesture has
         nothing to pop and stays off. This builds the interactive pop
         instead: the screen you are on follows the finger to the right,
         the screen you came from waits underneath — offset a third and
         dimmed, as UIKit does it — and letting go either finishes the
         slide and presses the real back control, or snaps back.

         The screen underneath is a clone of #app with the previous screen
         un-hidden, not the real one: un-hiding the real one would run the
         page's own layout and paint logic mid-gesture, and a preview that
         goes stale for 300ms is fine. The clone KEEPS its ids — every rule
         in this file that hides or restyles something is scoped by id, and
         a ghost without them showed the stats and "Worth a look" the app
         no longer has. It is inserted after #app, so getElementById keeps
         returning the original, and it is inert. It exists only for the
         duration of the swipe.

         Starts only in the outer 22px, so it cannot be mistaken for the
         swipe that ticks a task off; a mostly vertical move kills it so a
         scroll that began near the edge stays a scroll. */
      (function () {
        var app = document.getElementById('app');
        var EDGE = 22, DONE = 0.33, PARALLAX = 0.3, DIM = 0.16;
        /* Where "back" lands from each screen. Anything not here — the
           composer, a sheet, the walkthrough, a legal page — gets the
           plain press with no slide. */
        var PREV = {
          'screen-settings': 'screen-home', 'screen-profile': 'screen-settings',
          'screen-feedback': 'screen-settings', 'screen-plans': 'screen-settings',
          'screen-note': 'screen-notes'
          /* Not the tab screens. Calendar, Lists and Notes are siblings of
             home, not children of it, and a swipe that jumped to home from
             any of them was a tab bar with a hidden fifth way to use it. */
        };

        var x0 = null, y0 = null, dead = false, armed = false, live = false;
        var W = 0, layer = null, ghost = null, dim = null, current = null;

        function visible(el) { return !!(el && el.offsetParent !== null); }
        function firstVisible(sel, root) {
          var list = (root || document).querySelectorAll(sel);
          for (var i = 0; i < list.length; i++) if (visible(list[i])) return list[i];
          return null;
        }
        function press() {
          var wk = document.querySelector('.wk.is-open');
          if (wk) {
            var wb = wk.querySelector('.wk-back');
            (wb && wb.style.visibility !== 'hidden' ? wb : wk.querySelector('.wk-x')).click();
            return true;
          }
          var sheet = firstVisible('.note-sheet-x');
          if (sheet) { sheet.click(); return true; }
          var screen = document.querySelector('#app .screen:not(.is-hidden)');
          var btn = screen && firstVisible('.sheet-back, .settings-back', screen);
          if (btn) { btn.click(); return true; }
          var bar = firstVisible('.composer-bar');
          if (bar) { var c = bar.querySelector('button'); if (c) { c.click(); return true; } }
          var legal = firstVisible('.myadhd-native-back');
          if (legal) { legal.click(); return true; }
          return false;
        }

        /* Whether this swipe can be drawn, and if so, put the previous
           screen underneath. */
        function begin() {
          if (!app || document.querySelector('.wk.is-open') || firstVisible('.note-sheet-x') || firstVisible('.composer-bar')) return false;
          current = document.querySelector('#app .screen:not(.is-hidden)');
          var prevId = current && PREV[current.id];
          if (!prevId) return false;
          var screens = app.querySelectorAll('.screen');
          var index = -1;
          for (var i = 0; i < screens.length; i++) if (screens[i].id === prevId) index = i;
          if (index < 0) return false;

          ghost = app.cloneNode(true);
          ghost.removeAttribute('id');   // #app itself must stay unique; the rest may repeat
          ghost.setAttribute('inert', '');
          ghost.setAttribute('aria-hidden', 'true');
          var gs = ghost.querySelectorAll('.screen');
          for (var k = 0; k < gs.length; k++) gs[k].classList.toggle('is-hidden', k !== index);
          ghost.className += ' myadhd-ghost';

          layer = document.createElement('div');
          layer.className = 'myadhd-ghost-layer';
          dim = document.createElement('div');
          dim.className = 'myadhd-ghost-dim';
          layer.appendChild(ghost); layer.appendChild(dim);
          app.parentNode.insertBefore(layer, app.nextSibling);   // after #app: originals win every id lookup

          W = window.innerWidth;
          app.classList.add('myadhd-sliding');
          paint(0);
          return true;
        }
        function paint(p) {
          app.style.transform = 'translateX(' + (p * W) + 'px)';
          ghost.style.transform = 'translateX(' + (-PARALLAX * W * (1 - p)) + 'px)';
          dim.style.opacity = String(DIM * (1 - p));
        }
        function settle(finish) {
          app.classList.add('myadhd-settling'); layer.classList.add('myadhd-settling');
          paint(finish ? 1 : 0);
          var done = false;
          function cleanup() {
            if (done) return; done = true;
            if (finish) press();
            /* The page has switched to the very screen the ghost was
               showing, so dropping the ghost and the transform in the same
               frame is invisible. */
            app.classList.remove('myadhd-sliding', 'myadhd-settling');
            app.style.transform = '';
            if (layer && layer.parentNode) layer.parentNode.removeChild(layer);
            layer = ghost = dim = current = null; live = false;
          }
          app.addEventListener('transitionend', cleanup, { once: true });
          setTimeout(cleanup, 320);
        }

        document.addEventListener('touchstart', function (e) {
          if (live || e.touches.length !== 1) { x0 = null; return; }
          var t = e.touches[0];
          if (t.clientX > EDGE) { x0 = null; return; }
          x0 = t.clientX; y0 = t.clientY; armed = false; dead = false;
        }, { passive: true, capture: true });

        document.addEventListener('touchmove', function (e) {
          if (x0 === null || dead) return;
          var t = e.touches[0], dx = t.clientX - x0, dy = Math.abs(t.clientY - y0);
          if (!live) {
            if (dy > 40 && dx < 30) { dead = true; return; }
            if (dx < 12) return;
            live = begin();
            if (!live) { dead = !(dx >= 70); if (dx >= 70) { armed = true; } return; }
          }
          var p = Math.max(0, Math.min(1, dx / W));
          paint(p);
          var arm = p >= DONE;
          armed = arm;
        }, { passive: true, capture: true });

        function end() {
          if (x0 === null) return;
          var wasLive = live, wasArmed = armed && !dead;
          x0 = null; armed = false; dead = false;
          if (wasLive) { settle(wasArmed); return; }
          if (wasArmed) press();
        }
        document.addEventListener('touchend', end, { passive: true, capture: true });
        document.addEventListener('touchcancel', end, { passive: true, capture: true });
      })();

      /* ---- the calendar's other three views ----
         The page draws a month and an agenda for the picked day, and
         keeps them; that view is untouched. These are List (the next two
         weeks, grouped by day, drawn by the page's own agendaGroup so
         the rows behave exactly as they do below the month), Day (an
         hour grid for the picked day, with a now-line) and Week (the same
         grid, seven columns). All three read the page's own globals —
         state, tasksOn, calPicked — which is possible because app.js is a
         classic script, and they redraw whenever the page redraws its
         agenda, which it does on every change. The chosen view is
         remembered under its own key: it is the shell's preference, not
         the page's data. */
      (function () {
        var screen = document.getElementById('screen-calendar');
        var header = screen && screen.querySelector('header.brand');
        /* The calendar's header is the one with no .brand-tools — its
           toggle sat directly in the bar — so the slot the pill goes in
           is made here when it is missing. */
        var tools = header && header.querySelector('.brand-tools');
        if (header && !tools) {
          tools = document.createElement('div');
          tools.className = 'brand-tools';
          header.appendChild(tools);
        }
        var wrap = screen && screen.querySelector('.cal-wrap');
        var anchor = document.getElementById('cal-months');
        var agenda = document.getElementById('cal-agenda');
        if (!screen || !tools || !wrap || !anchor || !agenda) return;
        if (typeof tasksOn !== 'function' || typeof agendaGroup !== 'function' || typeof dayKey !== 'function') return;

        var KEY = 'myadhd.ios.calView', HH = 56, HHW = 40;
        var VIEWS = ['list', 'day', 'week', 'month'];
        var ICON = {
          list:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01"/></svg>',
          day:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="3.5" y="5" width="17" height="14" rx="3"/><path d="M3.5 11h17"/></svg>',
          week:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="3.5" y="5" width="17" height="14" rx="3"/><path d="M9.2 5v14M14.8 5v14"/></svg>',
          month: '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="6" cy="6" r="2"/><circle cx="12" cy="6" r="2"/><circle cx="18" cy="6" r="2"/><circle cx="6" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="18" cy="12" r="2"/><circle cx="6" cy="18" r="2"/><circle cx="12" cy="18" r="2"/><circle cx="18" cy="18" r="2"/></svg>'
        };
        var LABEL = { list: 'List', day: 'Day', week: 'Week', month: 'Month' };

        var view = 'month';
        try { var saved = localStorage.getItem(KEY); if (VIEWS.indexOf(saved) >= 0) view = saved; } catch (e) {}

        /* the switcher, where the theme toggle used to be */
        var pill = document.createElement('div');
        pill.className = 'myadhd-calview';
        pill.setAttribute('role', 'tablist');
        VIEWS.forEach(function (v) {
          var bt = document.createElement('button');
          bt.type = 'button'; bt.innerHTML = ICON[v];
          bt.setAttribute('aria-label', LABEL[v]); bt.dataset.view = v;
          bt.addEventListener('click', function () { setView(v); });
          pill.appendChild(bt);
        });
        tools.appendChild(pill);

        /* the three panes, after the month grid */
        var panes = {};
        ['list', 'day', 'week'].forEach(function (v) {
          var p = document.createElement('div');
          p.className = 'myadhd-cal-pane myadhd-cal-' + v;
          anchor.parentNode.insertBefore(p, anchor.nextSibling);
          panes[v] = p;
        });

        function today() { return dayKey(); }
        function picked() { return (typeof calPicked === 'string' && calPicked) ? calPicked : today(); }
        function add(key, n) { return dayKey(addDays(keyToDate(key), n)); }
        function mondayOf(key) {
          var d = keyToDate(key), back = (d.getDay() + 6) % 7;
          return add(key, -back);
        }
        function mins(at) { if (!at) return null; var p = at.split(':').map(Number); return p[0] * 60 + p[1]; }
        function pick(key) {
          try { calPicked = key; if (typeof renderCalendar === 'function') renderCalendar(); } catch (e) {}
        }

        function weekStrip(base) {
          var mon = mondayOf(base), t = today(), el = document.createElement('div');
          el.className = 'myadhd-wk';
          for (var i = 0; i < 7; i++) {
            var key = add(mon, i), d = keyToDate(key), bt = document.createElement('button');
            bt.type = 'button';
            bt.className = (key === base ? 'is-picked ' : '') + (key === t ? 'is-today' : '');
            bt.innerHTML = '<small>' + DAY_NAMES[d.getDay()].slice(0, 3) + '</small><b>' + d.getDate() + '</b>';
            bt.addEventListener('click', (function (k) { return function () { pick(k); }; })(key));
            el.appendChild(bt);
          }
          return el;
        }

        function block(task, hh, t) {
          var start = mins(task.at), len = Math.max(20, task.minutes || 20);
          var el = document.createElement('div');
          var late = !task.done && task.when < t;
          el.className = 'myadhd-blk' + (late ? ' is-late' : '') + (task.done ? ' is-done' : '');
          el.style.top = (start / 60 * hh) + 'px';
          el.style.height = Math.max(hh * 0.5, len / 60 * hh - 2) + 'px';
          el.innerHTML = '<b>' + task.title.replace(/</g, '&lt;') + '</b><small>' +
            (typeof timeLabel === 'function' ? timeLabel(task.at) : task.at) + ' · ' + len + ' min</small>';
          return el;
        }

        function hourGrid(days, hh) {
          var t = today();
          var grid = document.createElement('div'); grid.className = 'myadhd-grid';
          var inner = document.createElement('div'); inner.className = 'myadhd-grid-in'; inner.style.setProperty('--hh', hh + 'px');
          var hours = document.createElement('div'); hours.className = 'myadhd-hours';
          for (var h = 0; h < 24; h++) { var sp = document.createElement('span'); sp.textContent = (h < 10 ? '0' : '') + h + ':00'; hours.appendChild(sp); }
          var cols = document.createElement('div'); cols.className = 'myadhd-cols'; cols.style.setProperty('--cols', days.length);
          days.forEach(function (key) {
            var col = document.createElement('div'); col.className = 'myadhd-col';
            state.tasks.filter(function (x) { return x.when === key && x.at && !x.skipped; })
              .forEach(function (x) { col.appendChild(block(x, hh, t)); });
            if (key === t) {
              var now = new Date(), line = document.createElement('div');
              line.className = 'myadhd-now';
              line.style.top = ((now.getHours() * 60 + now.getMinutes()) / 60 * hh) + 'px';
              col.appendChild(line);
            }
            cols.appendChild(col);
          });
          inner.appendChild(hours); inner.appendChild(cols); grid.appendChild(inner);
          grid.dataset.focus = days.indexOf(t) >= 0 ? Math.max(0, new Date().getHours() - 2) : 7;
          grid.dataset.hh = hh;
          return grid;
        }

        function anytime(days) {
          var items = state.tasks.filter(function (x) { return days.indexOf(x.when) >= 0 && !x.at && !x.done && !x.skipped; });
          if (!items.length) return null;
          var row = document.createElement('div'); row.className = 'myadhd-anytime';
          var lab = document.createElement('i'); lab.textContent = 'Anytime'; row.appendChild(lab);
          items.slice(0, 6).forEach(function (x) { var sp = document.createElement('span'); sp.textContent = x.title; row.appendChild(sp); });
          if (items.length > 6) { var more = document.createElement('i'); more.textContent = '+' + (items.length - 6); row.appendChild(more); }
          return row;
        }

        function renderList() {
          var p = panes.list, t = today(), from = picked() < t ? picked() : t;
          p.innerHTML = '';
          if (from === t && typeof overdueTasks === 'function') {
            var late = overdueTasks(t);
            if (late.length) p.appendChild(agendaGroup(late.length + ' overdue', late, t, true));
          }
          var any = false;
          for (var i = 0; i < 14; i++) {
            var key = add(from, i), items = tasksOn(key);
            if (!items.length) continue;
            any = true;
            p.appendChild(agendaGroup(dayLabel(key, t), items, t, false));
          }
          if (!any) {
            var e = document.createElement('p'); e.className = 'cal-empty';
            e.textContent = 'Nothing in the next two weeks. Say a day in the dump box and it lands here.';
            p.appendChild(e);
          }
        }
        function renderDay() {
          var p = panes.day, key = picked(); p.innerHTML = '';
          p.appendChild(weekStrip(key));
          var a = anytime([key]); if (a) p.appendChild(a);
          p.appendChild(hourGrid([key], HH));
        }
        function renderWeek() {
          var p = panes.week, key = picked(), mon = mondayOf(key), t = today(); p.innerHTML = '';
          var days = []; for (var i = 0; i < 7; i++) days.push(add(mon, i));
          var head = document.createElement('div'); head.className = 'myadhd-colhead'; head.style.setProperty('--cols', 7);
          head.appendChild(document.createElement('span'));
          days.forEach(function (k) {
            var d = keyToDate(k), sp = document.createElement('span');
            sp.className = k === t ? 'is-today' : '';
            sp.innerHTML = DAY_NAMES[d.getDay()].slice(0, 3) + ' <b>' + d.getDate() + '</b>';
            head.appendChild(sp);
          });
          p.appendChild(head);
          var a = anytime(days); if (a) p.appendChild(a);
          p.appendChild(hourGrid(days, HHW));
        }
        var lastKey = null, lastView = null;
        function measure() {
          var hdr = screen.querySelector('header.brand'), ch = screen.querySelector('.cal-head');
          if (hdr) screen.style.setProperty('--myadhd-hdr', hdr.offsetHeight + 'px');
          if (ch) screen.style.setProperty('--myadhd-calhead', ch.offsetHeight + 'px');
        }
        /* Scroll the PAGE so the working hours sit just under the stuck
           strip — only when the view or the day has changed, never on the
           minute tick or a repaint, which would yank the page mid-read. */
        function settleScroll(pane) {
          var grid = pane.querySelector('.myadhd-grid'), app = document.getElementById('app');
          var stuck = pane.querySelector('.myadhd-wk, .myadhd-colhead');
          if (!grid || !app || !stuck) return;
          /* Keyed on the view alone: swiping to another day, or tapping
             one on the strip, keeps the hour you were looking at, the way
             Ink's does. Only entering the view finds the working hours. */
          if (view === lastKey) return;
          lastKey = view;
          requestAnimationFrame(function () {
            var target = grid.getBoundingClientRect().top + Number(grid.dataset.focus || 7) * Number(grid.dataset.hh || 56);
            var under = stuck.getBoundingClientRect().bottom;
            app.scrollTop += target - under;
          });
        }
        function render() {
          if (screen.classList.contains('is-hidden')) return;
          measure();
          if (view === 'list') renderList();
          else if (view === 'day') { renderDay(); settleScroll(panes.day); }
          else if (view === 'week') { renderWeek(); settleScroll(panes.week); }
          lastView = view;
        }
        function setView(v) {
          view = v;
          try { localStorage.setItem(KEY, v); } catch (e) {}
          VIEWS.forEach(function (x) { screen.classList.toggle('myadhd-view-' + x, x === v); });
          Object.keys(panes).forEach(function (x) { panes[x].classList.toggle('is-on', x === v); });
          pill.querySelectorAll('button').forEach(function (bt) { bt.classList.toggle('is-on', bt.dataset.view === v); });
          render();
        }

        /* ---- swipe sideways for the next day, or the next week ----
           The pane follows the finger, and on release glides off over the
           same 220ms the month uses (CAL_GLIDE_MS), while the new day
           glides in from the other side. Horizontal only: the first dozen
           points decide whether this is a swipe or a scroll, and after
           that it is one or the other. The outer 22px belong to the back
           gesture and are left alone. */
        var GLIDE = 220, EASE = 'cubic-bezier(.2,.8,.2,1)';
        function swipeable(pane, step) {
          var x0 = null, y0 = null, mode = null, dx = 0, busy = false;

          /* What slides is the grid and the anytime row — the strip and the
             column heads are the frame the days move inside, and they
             stay put with the picked day simply changing under the thumb.
             Looked up each time because a re-render replaces them. */
          function moving() { return pane.querySelectorAll('.myadhd-grid, .myadhd-anytime'); }
          function each(fn) { var m = moving(); for (var i = 0; i < m.length; i++) fn(m[i]); }

          pane.addEventListener('touchstart', function (e) {
            if (busy || e.touches.length !== 1 || e.touches[0].clientX <= 22) { x0 = null; return; }
            x0 = e.touches[0].clientX; y0 = e.touches[0].clientY; mode = null; dx = 0;
          }, { passive: true });

          pane.addEventListener('touchmove', function (e) {
            if (x0 === null) return;
            var t = e.touches[0]; dx = t.clientX - x0; var dy = t.clientY - y0;
            if (!mode) {
              if (Math.abs(dx) < 12 && Math.abs(dy) < 12) return;
              mode = Math.abs(dx) > Math.abs(dy) ? 'h' : 'v';
            }
            if (mode !== 'h') return;
            each(function (el) { el.style.transition = 'none'; el.style.transform = 'translateX(' + dx + 'px)'; });
          }, { passive: true });

          function glide(to, then) {
            each(function (el) { el.style.transition = 'transform ' + GLIDE + 'ms ' + EASE; el.style.transform = to; });
            setTimeout(then, GLIDE + 30);
          }
          function reset() { each(function (el) { el.style.transition = ''; el.style.transform = ''; }); }

          function end() {
            if (x0 === null) return;
            var wasH = mode === 'h', moved = dx; x0 = null; mode = null;
            if (!wasH) return;
            var W = pane.offsetWidth || window.innerWidth;
            if (Math.abs(moved) < 60) { glide('translateX(0)', reset); return; }
            busy = true;
            var dir = moved < 0 ? 1 : -1;   // swipe left: forward in time
            glide('translateX(' + (-dir * W) + 'px)', function () {
              pick(add(picked(), dir * step));
              /* The re-render has replaced the grid by now; the new one
                 starts off-screen on the far side and glides in. */
              requestAnimationFrame(function () { requestAnimationFrame(function () {
                each(function (el) { el.style.transition = 'none'; el.style.transform = 'translateX(' + (dir * W) + 'px)'; });
                requestAnimationFrame(function () { glide('translateX(0)', function () { reset(); busy = false; }); });
              }); });
            });
          }
          pane.addEventListener('touchend', end, { passive: true });
          pane.addEventListener('touchcancel', end, { passive: true });
        }
        swipeable(panes.day, 1);
        swipeable(panes.week, 7);

        /* The page rewrites #cal-agenda on every renderCalendar, which is
           every change that could matter here — a tick, a drag, a new
           task, a picked day. Redraw on that rather than guessing. */
        new MutationObserver(function () { requestAnimationFrame(render); }).observe(agenda, { childList: true });
        new MutationObserver(function () { requestAnimationFrame(render); }).observe(screen, { attributes: true, attributeFilter: ['class'] });
        setInterval(function () { if (view === 'day' || view === 'week') render(); }, 60000);
        setView(view);
      })();

      /* ---- pull to refresh ----
         Driven from the shell: a native pan recogniser calls
         __myadhdPull.move(dy) as the finger moves and .end() when it
         lifts, because once #app is taller than the screen WebKit hands a
         vertical drag to its scroller and the page's own touch events go
         quiet. Everything visible still happens here — the strip under
         the header, the mark, the refresh — and it only happens when the
         page is resting at the top and a tab screen is showing. */
      (function () {
        var app = document.getElementById('app');
        if (!app) return;
        var slot = null, pulling = false, loading = false, armed = false, ignore = false;
        var ARM = 66, MAX = 92;

        function slotFor() {
          var bar = document.querySelector('#app .screen:not(.is-hidden) > header.brand.myadhd-native');
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
            var now = document.querySelector('#app .screen:not(.is-hidden)');
            if (now && now.id === 'screen-now'  && typeof repaintLists === 'function') repaintLists();
            if (now && now.id === 'screen-home' && typeof renderHome   === 'function') renderHome();
            if (now && now.id === 'screen-calendar' && typeof renderCalendar === 'function') renderCalendar();
          } catch (e) {}
          Promise.all(waits).then(done, done);
        }

        function move(dy) {
          if (loading || ignore) return;
          if (!pulling) {
            /* Decided once, at the first movement: the page must be resting
               at the top, and a tab screen must be showing. Otherwise this
               drag is a scroll, or a sheet, and the pull stays out of it. */
            if (app.scrollTop > 0) { ignore = true; return; }
            slot = slotFor();
            if (!slot) { ignore = true; return; }
            pulling = true; armed = false;
          }
          var h = Math.max(0, Math.min(MAX, dy * 0.55));
          slot.classList.add('is-pulling');
          slot.style.height = h + 'px';
          var arm = h >= ARM;
          armed = arm;
          slot.classList.toggle('is-armed', armed);
        }

        function end() {
          var wasPulling = pulling, wasArmed = armed;
          pulling = false; armed = false; ignore = false;
          if (!wasPulling || !slot) return;
          slot.classList.remove('is-pulling');
          if (wasArmed) {
            loading = true;
            slot.style.height = ARM + 'px';
            slot.classList.add('is-loading');
            var s = slot;
            refresh(function () {
              s.classList.remove('is-loading', 'is-armed');
              s.style.height = '0px';
              loading = false;
            });
          } else {
            slot.classList.remove('is-armed');
            slot.style.height = '0px';
          }
        }

        window.__myadhdPull = { move: move, end: end };
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
