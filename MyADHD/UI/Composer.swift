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
    /// Where the text sits inside the sheet, so a touch that starts on it
    /// can be told from one that starts anywhere else.
    @State private var inputFrame: CGRect = .zero
    @State private var bodyScrolledDown = false

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
    private static let flickWindow: Double = 0.120       // seconds
    private static let flickMinPX: CGFloat = 40
    private static let speedSmoothing: CGFloat = 0.4
    private static let claimPX: CGFloat = 8
    private static let keyboardPX: CGFloat = 24
    private static let settleMS: Double = 280

    var body: some View {
        ZStack(alignment: .bottom) {
            scrim
            sheet
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(InputFrame.self) { inputFrame = $0 }
        .onPreferenceChange(MicButtonFrame.self) { micFrame = $0 }
        /* Carries over whatever is sitting in the dump box, so a
           half-written thought is not lost by reaching for the + instead of
           the dump screen (app.js:1913). */
        .onAppear { text = buffer.text }
    }

    private static let space = "composer"

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
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(theme.surface)
                /* On a dark page the sheet and the screen behind it are the
                   same value, and a shadow alone does not separate them —
                   the hairline does. */
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(theme.line, lineWidth: 1.5)
                )
                .shadow(color: Color(hex: 0x101018, opacity: 0.45), radius: 20, y: -6)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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
        .simultaneousGesture(dragGesture)
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
    private var canSend: Bool { !JSText.trim(text).isEmpty }

    // MARK: the mic

    /// Whether the mic is on screen and taking touches — which is what
    /// both the body's bottom padding and the drag's exclusion zone
    /// actually depend on.
    private var micIsUp: Bool { VoiceRecorder.available && !typing }

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
                /* `bottom: calc(30px + env(safe-area-inset-bottom))`. The
                   sheet's background is the thing that runs under the home
                   indicator; its content stops at the safe area, so this is
                   measured from there. */
                .padding(.bottom, 30)
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
                        /* Where the box is, so a touch that starts on it can
                           be told from one that starts anywhere else — the
                           claim rule below needs the answer, and the web got
                           it from `e.target.closest('.composer-input')`. */
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: InputFrame.self,
                                    value: g.frame(in: .named(Self.space))
                                )
                            }
                        )

                    DateChips(text: value)
                        .padding(.top, 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, barGutter)
            .padding(.top, 16)
            /* `.composer-body { padding-bottom: 150px }`, which clears the
               mic so a long dump never ends up underneath it — and 24 once
               the keyboard has taken the mic's place. */
            .padding(.bottom, micIsUp ? 150 : 24)
            .background(
                GeometryReader { g in
                    Color.clear.preference(
                        key: ScrollTop.self,
                        value: -g.frame(in: .named(Self.space)).minY
                    )
                }
            )
        }
        .scrollDismissesKeyboard(.interactively)
        .onPreferenceChange(ScrollTop.self) { top in
            /* "a body scrolled off its top is being read, not dragged"
               (app.js:2148). The number itself is noisy, so only the answer
               is kept. */
            bodyScrolledDown = top > 1
        }
        /* Anywhere in the empty space under the text raises the keyboard.
           iOS only does that for a focus it believes came from a tap, and
           this one did. */
        .contentShape(Rectangle())
        .onTapGesture { input.focusAtEnd() }
    }

    private struct ScrollTop: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    private struct InputFrame: PreferenceKey {
        static var defaultValue: CGRect = .zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            value = nextValue()
        }
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
        isPresented = false         // no slide: the morph is what comes up
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
        guard phase == .home else { isPresented = false; return }

        let travel = max(1, sheetHeight - drag.dy)
        let speed = min(max(drag.speed, 0.9), 3.2)              // px per ms
        let ms = (min(300, max(130, Double(travel / speed)))).rounded()

        withAnimation(still(Theme.outSheet(ms / 1000))) { phase = .leaving }

        /* An animation that never finishes must not leave the sheet up, so
           the hide is on a timer the animation does not own — the web keeps
           the same safety net (app.js:2037). */
        let wait = (stillMotion ? 1 : ms) + 150
        DispatchQueue.main.asyncAfter(deadline: .now() + wait / 1000) {
            isPresented = false
        }
    }

    /// `prefers-reduced-motion: reduce` → every animation 1 ms.
    private func still(_ animation: Animation) -> Animation {
        stillMotion ? .linear(duration: 0.001) : animation
    }

    // MARK: - the drag

    private struct DragState {
        var active = false
        /// Touched the text and has not committed yet.
        var pending = false
        /// Went sideways or upwards from the text: not ours, and it does not
        /// get a second chance this gesture.
        var dead = false
        var from: CGFloat = 0
        var x0: CGFloat = 0
        var dy: CGFloat = 0
        var lastY: CGFloat = 0
        var lastT: Date = .distantPast
        var speed: CGFloat = 0
        var started = false
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { g in dragChanged(g) }
            .onEnded { g in dragEnded(g) }
    }

    private func dragChanged(_ g: DragGesture.Value) {
        if !drag.started {
            drag.started = true
            drag.from = g.startLocation.y
            drag.x0 = g.startLocation.x
            drag.lastY = g.startLocation.y
            drag.lastT = Date()
            drag.speed = 0

            /* A body scrolled off its top is being read, not dragged. */
            if bodyScrolledDown { drag.dead = true; return }

            /* `if (e.target.closest('button')) return;` (app.js:2091). The
               mic is the one button inside the sheet's own drag area, and
               a hold on it lasts half a minute — without this the sheet
               would follow the thumb for the whole recording. */
            if micIsUp && micFrame.contains(g.startLocation) {
                drag.dead = true
                return
            }

            /* The text is the one surface with something else to do with a
               touch — a tap has to land a caret, a sideways drag has to
               select — so it waits to see which way the finger goes. The
               header, the avatar and the whole empty page below take the
               gesture immediately. */
            if inputFrame.contains(g.startLocation) {
                drag.pending = true
            } else {
                claim(at: g.location.y)
            }
        }

        guard !drag.dead else { return }

        if drag.pending {
            let dy = g.location.y - drag.from
            let dx = abs(g.location.x - drag.x0)
            if dy > Self.claimPX && dy > dx {
                claim(at: g.location.y)          // down: ours
            } else if dx > Self.claimPX || dy < -Self.claimPX {
                drag.pending = false             // sideways: theirs
                drag.dead = true
            }
            return
        }

        guard drag.active else { return }

        // down only: dragging up must not lift the sheet off the top
        let dy = max(0, g.location.y - drag.from)
        let now = Date()
        let gap = now.timeIntervalSince(drag.lastT)
        if gap > 0 {
            let instant = (g.location.y - drag.lastY) / CGFloat(gap * 1000)
            drag.speed += (instant - drag.speed) * Self.speedSmoothing
            drag.lastY = g.location.y
            drag.lastT = now
        }

        /* Past a real movement this is a drag, not a tap — and dragging a
           sheet down is how the platform puts a keyboard away anyway. iOS
           pins the caret and the selection handles to a focused field, so
           every frame the sheet moves is a frame it re-places them. */
        if dy > Self.keyboardPX && input.isFocused { input.blur() }

        drag.dy = dy
    }

    private func claim(at y: CGFloat) {
        drag.active = true
        drag.pending = false
        // rebased to where the finger is now, so committing does not jump
        // the sheet by the distance it took to decide
        drag.from = y
        drag.lastY = y
        drag.lastT = Date()
        drag.speed = 0
    }

    private func dragEnded(_ g: DragGesture.Value) {
        let wasActive = drag.active
        let dy = max(0, g.location.y - drag.from)
        let fresh = Date().timeIntervalSince(drag.lastT) < Self.flickWindow
        let speed = fresh ? drag.speed : 0

        drag.started = false
        drag.pending = false
        drag.dead = false
        drag.active = false

        guard wasActive else { drag.dy = 0; return }

        let flicked = dy > Self.flickMinPX && speed > Self.dismissSpeed
        if dy > Self.dismissPX || flicked {
            drag.dy = dy
            drag.speed = speed
            cancel()                       // same as Cancel: the text is kept
            return
        }

        // not far enough — put it back
        withAnimation(still(Theme.settle(Self.settleMS / 1000))) { drag.dy = 0 }
        drag.speed = 0
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
        let end = view.text?.count ?? 0
        view.selectedRange = NSRange(location: end, length: 0)
    }

    func blur() { view?.resignFirstResponder() }
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
        func measure(_ view: UITextView) {
            let width = view.bounds.width
            guard width > 0 else { return }
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
