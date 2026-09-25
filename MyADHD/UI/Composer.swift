/* ============================================================
   MyADHD/UI/Composer.swift — the sheet the + opens

   app.html:1084-1127, app.js:1875-2246, styles.css:2019-2200, inventory §1.3.

   **It is a front end for the dump buffer, not a second one.** The web
   kept `#dump-input` off screen when the box moved into this sheet, and
   every path in — the +, `Dump again`, a quadrant's `+`, Siri, the share
   sheet, `myadhd://dump?text=` — writes into that one buffer and lets
   `triage()` read it. `DumpBuffer` is that buffer, and this sheet copies
   it in on open and writes it back on close. There has only ever been one
   parser because there has only ever been one box.

   Four behaviours that are easy to "improve" and must not be:

   - **It does not focus on open.** Focusing brought the keyboard up with
     the sheet, which covered the mic before it had been seen once; for a
     one-handed dump the thumb wants the mic, not the caret. The keyboard
     is one tap away and that tap is the whole body.
   - **Cancel keeps the text.** It goes back to the buffer, so reaching for
     the + and changing your mind costs nothing. Dismissing by drag is the
     same path, deliberately.
   - **Send closes with no animation.** The loading morph is what should be
     arriving, not an empty sheet sliding down over it.
   - **`Sort it` is dimmed, not hidden, while the box is blank.** It is the
     thing you are working towards, so it should be visible before it is
     usable.

   The drag is the web's, constant for constant: claim at 8 px and only
   when the finger is going down more than sideways, let the keyboard go at
   24 px, dismiss past 120 px or on a flick — over 40 px at more than
   0.55 px/ms, measured on a move no older than 120 ms, with the speed
   exponentially smoothed at 0.4 so one quick sample among slow ones cannot
   decide the gesture. A release that stays carries on at something like
   the speed it was let go at: 130–300 ms, from how far the sheet still has
   to fall.

   **The mic.** `#composer-voice` is anchored to the bottom of the sheet
   rather than sitting in the flow, because the body scrolls and a mic that
   scrolls off is a mic you cannot find one-handed. It goes when the
   keyboard comes — there is no arrangement in which a button 30pt off the
   bottom of the screen is visible over a keyboard, and hiding it is more
   honest than letting it be covered. Typing and talking are alternatives,
   not a pair, which is also why the body's bottom padding drops from 150
   to 24 the moment the caret lands.

   It is not built at all when `VoiceRecorder.available` is false, which is
   what the web does with `Voice.available()` — hidden outright, never
   present and dimmed. Everything it does is in `MicButton`; what belongs
   here is where it hangs, that a touch on it is not a drag on the sheet
   (the web's `e.target.closest('button')` guard), and that closing the
   sheet throws a live hold away.
   ============================================================ */

import SwiftUI
import UIKit

// MARK: - the buffer

/// `#dump-input`, which is off screen on the web and has no screen at all
/// here. Session-lived: it is never persisted, and `triage()` is the only
/// thing that reads it.
@MainActor
@Observable
final class DumpBuffer {

    private(set) var text: String = ""

    /// Set when text arrived from outside — Siri, the share sheet, a URL —
    /// so the host can bring the sheet up over whatever was on screen.
    /// Cleared by the host once it has.
    var wantsComposer = false

    /// And in that case the caret *is* wanted: the person has already
    /// committed a sentence and is going to keep typing (app.js:5618).
    var wantsFocus = false

    /// `spokenDump` (app.js:547). Null means typed, and typing is the
    /// assumption: it is set only by a hold that produced words, and
    /// `triage()` takes it and clears it in the same breath.
    ///
    /// **Single use, and cleared by anything that writes text the user
    /// did not speak.** Inviting the repair pass on words someone chose
    /// themselves means watching their own sentences get rewritten under
    /// them — so `deliver()` clears it, because Siri, the share sheet and
    /// `myadhd://dump?text=` are all somebody else's text arriving.
    /// `write()` does not, because that is only ever this app moving its
    /// own buffer about, which is the `ownWrite` guard on the web.
    struct Spoken {
        var source: VoiceSource
        var lang: String?
    }

    private(set) var spoken: Spoken?

    init(text: String = "") { self.text = text }

    /// `writeBuffer(text)` (app.js:553-557). The app writing to its own
    /// box, which on the web had to be flagged so the input listener did
    /// not treat it as somebody typing.
    func write(_ value: String) { text = value }

    /// `spokenDump = { source, lang }` (app.js:5449).
    func spoke(source: VoiceSource, lang: String?) {
        spoken = Spoken(source: source, lang: lang)
    }

    /// `const spoken = spokenDump; spokenDump = null;` (app.js:568-569).
    /// `vocab` is deliberately not stored beside the other two: the web
    /// calls `knownNames()` again at triage time, over the task list as
    /// it stands then and not as it stood when the mic was let go.
    func takeSpoken(vocab: @autoclosure () -> [String]) -> TriageClient.Spoken? {
        guard let spoken else { return nil }
        self.spoken = nil
        return TriageClient.Spoken(source: spoken.source.rawValue,
                                   lang: spoken.lang,
                                   vocab: vocab())
    }

    /// The shell's `fillDumpBox` landing (app.js:5607-5619). Blank text is
    /// dropped rather than opening an empty sheet.
    func deliver(_ value: String) {
        spoken = nil                         // app.js:5609
        guard !JSText.trim(value).isEmpty else { return }
        text = value
        wantsComposer = true
        wantsFocus = true
    }

    func claimOpen() -> Bool {
        defer { wantsComposer = false }
        return wantsComposer
    }

    /// Text from outside that landed while the sheet was already up — the
    /// web's "text that lands while the sheet is already up" (app.js:5611).
    /// The sheet adds it to what is being typed rather than having it
    /// written behind it into this buffer, which the sheet then overwrites
    /// with its own copy on Cancel or Sort it.
    private(set) var arrived: String?

    func arrive(_ value: String) {
        guard !JSText.trim(value).isEmpty else { return }
        spoken = nil
        arrived = value
    }

    func takeArrived() -> String? {
        defer { arrived = nil }
        return arrived
    }
}

// MARK: - the sheet

struct Composer: View {

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var stillMotion

    let buffer: DumpBuffer
    let store: AppStore

    /// The mic's toasts — the cap, a refusal, a transcriber that could
    /// not be reached. Required rather than optional on purpose: a host
    /// that forgot to pass one would lose "no mic access" silently, and
    /// that is the message the button most needs to be able to say.
    let toasts: ToastCenter

    /// Set false by every way out. The host keeps it.
    @Binding var isPresented: Bool

    /// `triage()`. Called after the buffer has been written and the sheet
    /// has gone, so what comes up behind it is the loading screen.
    var send: () -> Void

    // MARK: the sheet's own state

    @State private var text = ""
    @State private var textHeight: CGFloat = 26
    @State private var sheetHeight: CGFloat = 0
    @State private var phase: Phase = .entering

    // MARK: the drag

    @State private var drag = DragState()

    @State private var input = ComposerInput()

    // MARK: the mic

    /// One recorder per sheet. It holds no state between holds worth
    /// keeping and it releases the audio session on every close, so
    /// there is nothing to hoist above this view.
    @State private var recorder = VoiceRecorder()
    @State private var mic = MicControl()

    /// `.composer.is-typing` — set on the box's focus and cleared on its
    /// blur (app.js:5270-5276).
    @State private var typing = false

    /// Where the mic is, so a touch that lands on it is not a drag on the
    /// sheet. The web gets this from `e.target.closest('button')`.
    @State private var micFrame: CGRect = .zero

    private enum Phase { case entering, home, leaving }

    // app.js:2057-2079
    private static let dismissPX: CGFloat = 120
    private static let dismissSpeed: CGFloat = 0.55      // px per ms
    private static let flickMinPX: CGFloat = 40
    private static let keyboardPX: CGFloat = 24
    private static let settleMS: Double = 280
    /* The web's `SLOP` 8 and its hand-rolled speed are gone with the
       DragGesture: `UIPanGestureRecognizer` has its own movement threshold
       and reports velocity itself. See `SheetPanGesture`. */

    var body: some View {
        ZStack(alignment: .bottom) {
            scrim
            sheet
        }
        .coordinateSpace(name: Self.space)
        /* The pull-down. Behind everything and untouchable; the points it
           reports are in this view's space, which is `Self.space`. */
        .background {
            SheetPanGesture(shouldClaim: mayPull,
                            onBegan: pullBegan,
                            onChanged: pullMoved,
                            onEnded: pullEnded,
                            onCancelled: pullCancelled)
        }
        .onPreferenceChange(MicButtonFrame.self) { micFrame = $0 }
        /* Carries over whatever is sitting in the dump box, so a
           half-written thought is not lost by reaching for the + instead of
           the dump screen (app.js:1913). */
        .onAppear { text = buffer.text }
        /* Text from Siri, a link or the share sheet while the sheet is up:
           added on its own line, where the caret then goes. */
        .onChange(of: buffer.arrived) { _, new in
            guard new != nil, let more = buffer.takeArrived() else { return }
            let now = JSText.trim(text)
            text = now.isEmpty ? more : now + "\n" + more
            input.focusAtEnd()
        }
        /* Its own layer. The shell's is under this cover, so the mic's
           toasts — no mic access, the two-minute cap, a transcriber that
           could not be reached — were raised behind the sheet and expired
           unseen. Settings, feedback and the note editor each have one for
           the same reason. */
        .toastLayer(toasts, hasTabBar: false)
    }

    private static let space = "composer"

    /// Round at the top only: the bottom is the edge of the screen.
    private static let card = UnevenRoundedRectangle(topLeadingRadius: 22,
                                                     topTrailingRadius: 22,
                                                     style: .continuous)

    // MARK: scrim

    private var scrim: some View {
        Color(hex: 0x101018, opacity: 0.42)
            .opacity(scrimOpacity)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { cancel() }
            .accessibilityHidden(true)
    }

    /// `max(0, 1 - dy / 420)` while the finger is on it, so the page behind
    /// comes back in step with the sheet rather than all at once at the end.
    private var scrimOpacity: Double {
        switch phase {
        case .entering: return 0
        case .leaving:  return 0
        case .home:     return Double(max(0, 1 - drag.dy / 420))
        }
    }

    // MARK: the sheet

    private var sheet: some View {
        VStack(spacing: 0) {
            bar
            body(for: text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) { voice }
        /* The content is clipped to the card and the card is drawn AFTER
           that, in that order on purpose. The other way round the clip
           took the card's ground back off at the safe-area edge, and the
           sheet stopped a home indicator's height short of the screen —
           rounded corners, a hairline, and a paler strip under it. The
           ground is what runs under the home indicator (`env(safe-area-
           inset-bottom)` on the web), so only its top corners are round,
           and it reaches 2pt past the bottom so the hairline's bottom
           edge is off the glass. */
        .clipShape(Self.card)
        .background {
            Self.card
                .fill(theme.surface)
                /* On a dark page the sheet and the screen behind it are the
                   same value, and a shadow alone does not separate them —
                   the hairline does. */
                .overlay(Self.card.strokeBorder(theme.line, lineWidth: 1.5))
                .shadow(color: Color(hex: 0x101018, opacity: 0.45), radius: 20, y: -6)
                .padding(.bottom, -2)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        /* just clear of the status bar, so the screen underneath still shows
           as a sliver and the sheet reads as sitting on top of it */
        .padding(.top, 10)
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear {
                        sheetHeight = g.size.height
                        enter()
                    }
                    .onChange(of: g.size.height) { _, h in sheetHeight = h }
            }
        )
        .offset(y: offsetY)
    }

    private var offsetY: CGFloat {
        switch phase {
        case .entering: return sheetHeight > 0 ? sheetHeight : 2000
        case .leaving:  return sheetHeight > 0 ? sheetHeight : 2000
        case .home:     return drag.dy
        }
    }

    // MARK: the bar

    private var bar: some View {
        HStack(spacing: 10) {
            Button(action: cancel) {
                Text(Copy.Composer.cancel)
                    .font(Font.baloo(15, .semibold))
                    .foregroundStyle(theme.ink)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(Copy.Composer.title)
                .font(Font.baloo(16, .heavy))
                .kerning(-0.02 * 16)
                .foregroundStyle(theme.ink)
                .fixedSize()

            Button(action: sendIt) {
                Text(Copy.Composer.post)
                    .font(Font.baloo(14.5, .bold))
                    .foregroundStyle(Color(hex: 0xFFFFFF))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(theme.brandGradient, in: Capsule())
                    .opacity(canSend ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, barGutter)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.line).frame(height: 1.5)
        }
    }

    /// `clamp(16px, 4vw, 22px)`.
    private var barGutter: CGFloat {
        min(22, max(16, UIScreen.main.bounds.width * 0.04))
    }

    /// `el.compPost.disabled = value.trim().length === 0` (app.js:1894).
    /// Something to send, and no words still on their way from the mic.
    private var canSend: Bool { !JSText.trim(text).isEmpty && !mic.working }

    // MARK: the mic

    /// Whether the mic is on screen and taking touches — which is what
    /// both the body's bottom padding and the drag's exclusion zone
    /// actually depend on.
    private var micIsUp: Bool { VoiceRecorder.available && !typing }

    /// What sits under the mic's hint, above the safe area.
    private static let micFloor: CGFloat = 12

    /// `#composer-voice` (app.html:1118-1127, styles.css:2152-2165).
    /// Absent, not disabled, when there is no microphone to open.
    @ViewBuilder
    private var voice: some View {
        if VoiceRecorder.available {
            MicButton(recorder: recorder,
                      control: mic,
                      space: Self.space,
                      text: $text,
                      /* `knownNames()` over the store as it stands when
                         the finger lands, not as it stood when the sheet
                         opened. */
                      vocab: { KnownNames.from(tasks: store.doc.tasks) },
                      onSpoken: { source, lang in
                          buffer.spoke(source: source, lang: lang)
                      },
                      toast: { toasts.show($0) })
                /* The web's `bottom: calc(30px + env(safe-area-inset-
                   bottom))`, cut to 12. The sheet's ground runs under the
                   home indicator and its content stops at the safe area,
                   so this is measured from there — and on a phone that
                   inset is already 34pt of the same ground, so the full
                   30 on top of it left the hint floating over an empty
                   band. */
                .padding(.bottom, Self.micFloor)
                /* The keyboard and the mic cannot both have the bottom of
                   the screen. */
                .opacity(typing ? 0 : 1)
                .offset(y: typing ? 10 : 0)
                .allowsHitTesting(!typing)
                .animation(still(Theme.ease(0.18)), value: typing)
        }
    }

    // MARK: the body

    private func body(for value: String) -> some View {
        ScrollView {
            HStack(alignment: .top, spacing: 12) {
                Text(Avatars.face(store.doc.profile.avatar))
                    .font(.system(size: 21))
                    .frame(width: 38, height: 38)
                    .background(theme.wash2, in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 0) {
                    Text(store.doc.profile.name.isEmpty
                         ? Copy.Composer.youFallback : store.doc.profile.name)
                        .font(Font.baloo(14.5, .bold))
                        .foregroundStyle(theme.ink)
                        .padding(.bottom, 2)

                    ComposerTextView(text: $text,
                                     height: $textHeight,
                                     controller: input,
                                     placeholder: Copy.Composer.placeholder,
                                     ink: UIColor(theme.ink),
                                     faint: UIColor(theme.faint),
                                     /* `is-typing` (app.js:5270-5276). The
                                        keyboard and the mic cannot both have
                                        the bottom of the screen. */
                                     onFocus: { typing = $0 })
                        .frame(height: max(26, textHeight))

                    DateChips(text: value)
                        .padding(.top, 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, barGutter)
            .padding(.top, 16)
            /* `.composer-body { padding-bottom: 150px }`, which clears the
               mic so a long dump never ends up underneath it — and 24 once
               the keyboard has taken the mic's place. The 150 was sized
               against the web's 30 under the mic, so it gives back the
               same 18 the mic did. */
            .padding(.bottom, micIsUp ? 150 - (30 - Self.micFloor) : 24)
        }
        .scrollDismissesKeyboard(.interactively)
        /* Anywhere in the empty space under the text raises the keyboard.
           iOS only does that for a focus it believes came from a tap, and
           this one did. */
        .contentShape(Rectangle())
        .onTapGesture { input.focusAtEnd() }
    }


    // MARK: - opening and closing

    private func enter() {
        guard phase == .entering else { return }
        withAnimation(still(Theme.settle(0.38))) { phase = .home }
        if buffer.wantsFocus {
            buffer.wantsFocus = false
            input.focusAtEnd()
        }
    }

    /// `sendComposer()` (app.js:2237-2246).
    private func sendIt() {
        guard canSend else { input.focusAtEnd(); return }
        buffer.write(text)          // untrimmed, exactly as typed
        input.blur()
        dismissNow()                // no slide: the morph is what comes up
        send()
    }

    /// `cancelComposer()` (app.js:2043-2053). The text is kept.
    private func cancel() {
        mic.abandon()                  // Voice.abandon(); restMic();
        store.clearPendingQuadrant()   // the quadrant was this sheet's
        buffer.write(text)
        close()
    }

    /// `closeComposer(true)` — played back down at something like the speed
    /// it was released at, so letting go mid-drag continues the movement
    /// rather than restarting it.
    private func close() {
        input.blur()
        guard phase == .home else { dismissNow(); return }

        let travel = max(1, sheetHeight - drag.dy)
        let speed = min(max(drag.speed, 0.9), 3.2)              // px per ms
        let ms = (min(300, max(130, Double(travel / speed)))).rounded()

        withAnimation(still(Theme.outSheet(ms / 1000))) { phase = .leaving }

        /* An animation that never finishes must not leave the sheet up, so
           the hide is on a timer the animation does not own — the web keeps
           the same safety net (app.js:2037). */
        let wait = (stillMotion ? 1 : ms) + 150
        DispatchQueue.main.asyncAfter(deadline: .now() + wait / 1000) {
            dismissNow()
        }
    }

    /// The cover goes with no transition of its own. Either the sheet has
    /// already played its way down, or it is `Sort it` and the morph is
    /// what should come up — never a card sliding down in front of it.
    private func dismissNow() {
        withTransaction(Transaction.still) { isPresented = false }
    }

    /// `prefers-reduced-motion: reduce` → every animation 1 ms.
    private func still(_ animation: Animation) -> Animation {
        stillMotion ? .linear(duration: 0.001) : animation
    }

    // MARK: - the pull

    /// `dy` is how far the sheet has been pulled, and what `offsetY` and
    /// the scrim read; `from` is where the finger was when it was claimed.
    private struct DragState {
        var active = false
        var from: CGFloat = 0
        var dy: CGFloat = 0
        var speed: CGFloat = 0
    }

    /// `startDrag`'s rules (app.js:2083-2110), asked once and before
    /// anything is claimed — see `SheetPanGesture` for why that matters.
    ///
    /// - Down, and only down. Sideways is the text's (a selection) and up
    ///   is the scroller's; dragging up could never lift the sheet anyway.
    /// - Not on the mic: a hold there lasts half a minute, and the sheet
    ///   would follow the thumb for all of it (app.js:2091).
    /// - Not with the body scrolled off its top: that is somebody reading
    ///   back up through a long dump (app.js:2148).
    private func mayPull(_ start: CGPoint, _ t: CGSize) -> Bool {
        guard phase == .home else { return false }
        guard t.height > abs(t.width) else { return false }
        if micIsUp && micFrame.contains(start) { return false }
        if input.bodyScrolled { return false }
        return true
    }

    private func pullBegan(_ y: CGFloat) {
        drag.active = true
        // from where the finger is now, so committing does not jump the
        // sheet by the distance it took to decide
        drag.from = y
        drag.speed = 0
    }

    private func pullMoved(_ y: CGFloat) {
        guard drag.active else { return }
        // down only: dragging up must not lift the sheet off the top
        let dy = max(0, y - drag.from)

        /* Past a real movement this is a drag, not a tap — and dragging a
           sheet down is how the platform puts a keyboard away anyway. iOS
           pins the caret and the selection handles to a focused field, so
           every frame the sheet moves is a frame it re-places them. */
        if dy > Self.keyboardPX && input.isFocused { input.blur() }

        drag.dy = dy
    }

    /// `endDrag` (app.js:2112-2140): far enough, or a real flick, and it
    /// goes the way Cancel goes — the text is kept; otherwise it springs
    /// back.
    private func pullEnded(_ y: CGFloat, _ velocity: CGFloat) {
        guard drag.active else { return }
        drag.active = false
        let dy = max(0, y - drag.from)
        let speed = velocity / 1000                     // pt/s → px per ms

        let flicked = dy > Self.flickMinPX && speed > Self.dismissSpeed
        if dy > Self.dismissPX || flicked {
            drag.dy = dy
            drag.speed = speed
            cancel()                       // same as Cancel: the text is kept
            return
        }

        withAnimation(still(Theme.settle(Self.settleMS / 1000))) { drag.dy = 0 }
        drag.speed = 0
    }

    /// The system took the touch. Nobody let go, so nothing is decided:
    /// the sheet goes back where it was.
    private func pullCancelled() {
        guard drag.active else { return }
        drag.active = false
        drag.speed = 0
        withAnimation(still(Theme.settle(Self.settleMS / 1000))) { drag.dy = 0 }
    }
}

// MARK: - the avatars

/// `AVATARS` / `avatarFace` (app.js:3881-3906). A profile is written once
/// and read by every version of the app that comes after it, so a face this
/// build does not recognise is drawn as the default and never written back.
enum Avatars {
    static let faces = Copy.Avatars.faces

    static func face(_ stored: String) -> String {
        faces.contains(stored) ? stored : faces[0]
    }
}

// MARK: - the box itself

/// A `UITextView` rather than `TextEditor`, for three things `TextEditor`
/// cannot be made to do: open unfocused and stay that way, put the caret at
/// the end when a tap elsewhere focuses it, and report the height it wants
/// so the sheet grows with the text instead of scrolling inside a fixed box.
@MainActor
final class ComposerInput {
    weak var view: UITextView?

    var isFocused: Bool { view?.isFirstResponder ?? false }

    /// `focusComposer()` (app.js:1936-1940).
    func focusAtEnd() {
        guard let view else { return }
        view.becomeFirstResponder()
        /* UTF-16 units, which is what an NSRange counts — `count` is
           characters, and an emoji is one of those and two of these, so the
           caret landed short of the end, inside the last emoji if it ended
           on one. */
        let end = (view.text ?? "").utf16.count
        view.selectedRange = NSRange(location: end, length: 0)
    }

    func blur() { view?.resignFirstResponder() }

    /// The body is scrolled off its top.
    ///
    /// **Read off UIKit, not measured in SwiftUI.** It used to be a
    /// `GeometryReader` preference inside the `ScrollView`, and in this
    /// cover that value never moved — not for a scroll the caret made, not
    /// for one a finger made — so it said "at the top" with thirty lines
    /// scrolled away, and a drag meant to scroll a long dump back down was
    /// taken by the sheet and closed it. The scroller the box sits in is a
    /// real `UIScrollView`, and its offset is the answer. The first one
    /// ABOVE the box: a `UITextView` is a scroll view itself.
    var bodyScrolled: Bool {
        var candidate = view?.superview
        while let v = candidate {
            if let scroll = v as? UIScrollView {
                return scroll.contentOffset.y + scroll.adjustedContentInset.top > 1
            }
            candidate = v.superview
        }
        return false
    }
}

struct ComposerTextView: UIViewRepresentable {

    @Binding var text: String
    @Binding var height: CGFloat
    let controller: ComposerInput
    let placeholder: String
    let ink: UIColor
    let faint: UIColor

    /// The caret arriving and leaving — `focus` and `blur` on the web.
    var onFocus: (Bool) -> Void = { _ in }

    /// 16.5px / 1.45, in the app's own face.
    private static let size: CGFloat = 16.5

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        /* A text view that does not scroll wants its longest line on one
           line, and will say so as an intrinsic width. Nothing here is
           allowed to ask for width. */
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.spellCheckingType = .no
        view.autocorrectionType = .default
        view.font = Self.font
        view.textColor = ink
        view.text = text
        view.adjustsFontForContentSizeCategory = false

        let hint = UILabel()
        hint.text = placeholder
        hint.font = Self.font
        hint.textColor = faint
        hint.numberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            hint.topAnchor.constraint(equalTo: view.topAnchor),
        ])
        context.coordinator.hint = hint
        hint.isHidden = !text.isEmpty

        controller.view = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        view.textColor = ink
        context.coordinator.hint?.textColor = faint
        context.coordinator.hint?.isHidden = !view.text.isEmpty
        context.coordinator.measure(view)
    }

    /// SwiftUI sizes a representable from its intrinsic size unless it is
    /// given a better answer, and the intrinsic width of a non-scrolling
    /// `UITextView` is the whole dump on one line. That width went up
    /// through the body, the scroll view and the sheet until the bar itself
    /// hung off both edges of the screen — `Cancel` cut off on the left
    /// while `Sort it` ran off the right. Take the width the sheet proposes
    /// and only ever answer with a height.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: UITextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width < .infinity else {
            return nil
        }
        let wanted = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        return CGSize(width: width, height: max(26, wanted))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private static var font: UIFont {
        UIFont(name: "Baloo2-Regular", size: size) ?? .systemFont(ofSize: size)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: ComposerTextView
        var hint: UILabel?

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocus(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocus(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
            hint?.isHidden = !(textView.text ?? "").isEmpty
            measure(textView)
        }

        /// `growComposer()` (app.js:1888-1892): reset, then take the height
        /// the content actually wants. A text view will not size itself.
        func measure(_ view: UITextView, tries: Int = 8) {
            let width = view.bounds.width
            /* Not laid out yet. The first update of a sheet that opens with
               a long dump already in it comes before the view has a width,
               and nothing asked again until the text changed — so the box
               sat at its 26pt floor with thirty lines spilling out of it
               over the name above, until somebody touched it. Ask again on
               the next turns of the run loop, a few times, once there is a
               width to measure against. */
            guard width > 0 else {
                guard tries > 0 else { return }
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.measure(view, tries: tries - 1)
                }
                return
            }
            let wanted = view.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            let next = max(26, wanted)
            if abs(next - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = next }
            }
        }
    }
}
