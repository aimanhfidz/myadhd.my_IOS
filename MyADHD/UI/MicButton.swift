/* ============================================================
   MyADHD/UI/MicButton.swift — press and hold, not tap to toggle

   `#composer-voice` and everything that drives it: app.js:5280-5481,
   app.html:1118-1127, styles.css:2143-2255, inventory §1.3.

   A toggle leaves the app listening after you have walked away from it,
   and needs you to remember it is on; a hold cannot be left running,
   and letting go is the same gesture as being finished.

   **The 400 ms.** A press shorter than that is a tap, not a hold —
   nothing was said, so nothing is sent and nothing is waited for. The
   recording is thrown away, the box is put back exactly as it was, and
   the hint says what the button actually wants. Spinning for a second
   before admitting there was nothing to transcribe is the worst version
   of this.

   **Letting go is not the end of it.** The recording goes off to be
   transcribed and comes back a second or two later, so there is a third
   state between listening and resting — `.working`. With no network
   that second still happens, the upload fails, and the answer is "didn't
   catch anything that time". Nothing already in the box is touched: the
   old code put `base` back on an empty result, which on a phone meant a
   long dump vanished the moment anything went wrong, which is the worst
   possible ending for the one feature whose entire job is not losing
   what you just thought of.

   **The gesture stays with the button.** A dump takes half a minute and
   a thumb does not hold still for it — it rolls, it slides, it ends up
   half off a 76pt circle without the person having any idea they moved.
   The web pins the pointer with `setPointerCapture` for exactly this;
   a SwiftUI `DragGesture` tracks outside its own bounds by default, so
   sliding off does not end a recording here either. The only thing that
   ends a hold is letting go — or the 130-second cap.

   **No pointerleave, and nothing on backgrounding.** Both were tried on
   the web and both cut long dumps off mid-word. A permission prompt, a
   keyboard and the app switcher all hide the page on some browser
   somewhere.

   **Absent, never dimmed.** `#composer-voice` is hidden outright when
   `Voice.available()` is false. A mic button that does nothing is a bug
   report, so `Composer` asks `VoiceRecorder.available` and does not
   build this view at all.
   ============================================================ */

import SwiftUI

// MARK: - the handle the sheet holds

/// `Voice.abandon(); restMic();` — the two lines at the top of
/// `cancelComposer()` (app.js:2044-2045). The sheet closing has to be
/// able to throw a hold away, and it is the only thing outside this file
/// that does.
@MainActor
final class MicControl {
    /// Set by the button when it appears.
    var reset: (() -> Void)?

    func abandon() { reset?() }
}

// MARK: - where the circle is

/// The button's own frame, published so the sheet around it knows a touch
/// that lands here is not a drag. On the web `.composer-voice` is
/// `pointer-events: none` and the drag handler skips anything inside a
/// `<button>`; this is the same fact, measured rather than asked.
///
/// The hint underneath is deliberately not part of it — it does not take
/// touches on the web either.
struct MicButtonFrame: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: -

struct MicButton: View {

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var stillMotion

    let recorder: VoiceRecorder
    let control: MicControl

    /// The coordinate space the enclosing sheet named, so `MicButtonFrame`
    /// comes back in the space that sheet's drag is measured in.
    let space: String

    /// The composer's box. Read on the way down (`micBase`) and written
    /// on the way back up.
    ///
    /// There is no `syncComposer()` beside these writes and there does
    /// not need to be one: `Sort it` being enabled, the height the box
    /// wants and the date chips are all derived from this string on the
    /// native side, where on the web they were three imperative calls
    /// that a programmatic write would otherwise have skipped.
    @Binding var text: String

    /// `knownNames()`, read when the hold starts and not before: the
    /// task list can change while the sheet is open.
    var vocab: () -> [String]

    /// `spokenDump = { source, lang }`.
    var onSpoken: (VoiceSource, String?) -> Void

    var toast: (String) -> Void

    // MARK: state

    private enum Phase { case rest, live, working }

    @State private var phase: Phase = .rest
    @State private var hint: String = Copy.Mic.rest

    /// `--mic-level`. Held here rather than read off the recorder so the
    /// ring keeps its last value for the frame the engine is tearing
    /// down in.
    @State private var level: Double = 0

    /// `micBase` — what was in the box before this hold, trimmed.
    @State private var base = ""

    /// `micHeld`.
    @State private var heldAt: Date = .distantPast

    /// `micBusy` — a transcript is in the air. Cleared by `rest()`,
    /// which is what makes a result that arrives after the sheet closed
    /// get dropped.
    @State private var busy = false

    /// The finger is down. `DragGesture.onChanged` fires repeatedly and
    /// only the first one is the press.
    @State private var pressing = false

    /// app.js:5396.
    private static let tapThreshold: TimeInterval = 0.4

    // MARK: -

    var body: some View {
        VStack(spacing: 12) {
            button
            Text(hint)
                .font(Font.baloo(13.5, .semibold))
                .kerning(-0.01 * 13.5)
                .foregroundStyle(phase == .rest ? theme.faint : theme.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .onAppear { control.reset = { abandonHold() } }
        .onDisappear { control.reset = nil }
    }

    // MARK: the circle

    private var button: some View {
        ZStack {
            Circle().fill(theme.brandGradient)
            pulse
            levelRing
            MicGlyph()
                .frame(width: 30, height: 30)
                .foregroundStyle(Color.white)
        }
        .frame(width: 76, height: 76)
        .shadow(color: Color(hex: 0x101018, opacity: shadowOpacity),
                radius: shadowRadius, y: shadowY)
        .scaleEffect(scale)
        .animation(still(Theme.ease(0.16)), value: phase)
        .contentShape(Circle())
        .background(
            GeometryReader { g in
                Color.clear.preference(key: MicButtonFrame.self,
                                       value: g.frame(in: .named(space)))
            }
        )
        .gesture(press)
        .accessibilityLabel(Copy.Composer.micSR)
        .accessibilityHint(hint)
    }

    /// `.composer-mic.is-live` grows it; `.is-working` shrinks it below
    /// resting size so it reads as busy rather than as live.
    private var scale: CGFloat {
        switch phase {
        case .rest: return 1
        case .live: return 1.12
        case .working: return 0.94
        }
    }

    /// `0 10px 28px -10px`, `0 14px 34px -10px`, `0 6px 18px -8px`. A CSS
    /// spread of -10 on a 28 blur is drawn from a box inset by 10; there
    /// is no spread in SwiftUI, so the radius is halved (a CSS blur is a
    /// two-sided diameter) and the opacity carries the rest.
    private var shadowRadius: CGFloat {
        switch phase {
        case .rest: return 14
        case .live: return 17
        case .working: return 9
        }
    }
    private var shadowY: CGFloat {
        switch phase {
        case .rest: return 10
        case .live: return 14
        case .working: return 6
        }
    }
    private var shadowOpacity: Double {
        switch phase {
        case .rest: return 0.5
        case .live: return 0.55
        case .working: return 0.45
        }
    }

    // MARK: the two rings

    /// `micPulse` while live, `micThinking` while working. Both are
    /// timers, and both are turned off by reduced motion — which leaves
    /// the ring sitting at 0.28, exactly as the media query says.
    private var pulse: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: stillMotion || phase == .rest)) { tick in
            let t = tick.date.timeIntervalSinceReferenceDate
            Circle()
                .fill(theme.brandGradient)
                .opacity(pulseOpacity(t))
                .scaleEffect(pulseScale(t))
        }
        .allowsHitTesting(false)
    }

    private func pulseOpacity(_ t: TimeInterval) -> Double {
        guard !stillMotion else { return phase == .rest ? 0 : 0.28 }
        switch phase {
        case .rest:
            return 0
        case .live:
            // `from {opacity:.5} to {opacity:0}` over 1.5s, ease-out.
            return 0.5 * (1 - easeOut(t.truncatingRemainder(dividingBy: 1.5) / 1.5))
        case .working:
            // `0,100% {.14} 50% {.42}` over 1.1s, on --ease.
            return 0.14 + 0.28 * thinking(t)
        }
    }

    private func pulseScale(_ t: TimeInterval) -> CGFloat {
        guard !stillMotion else { return 1 }
        switch phase {
        case .rest:
            return 1
        case .live:
            return 1 + 0.9 * easeOut(t.truncatingRemainder(dividingBy: 1.5) / 1.5)
        case .working:
            return 1 + 0.16 * thinking(t)
        }
    }

    /// The second ring is the one that is actually listening: the tap
    /// reports a level about twenty times a second, so this moves with
    /// the room rather than on a timer. On a phone with no live text it
    /// is the only evidence the app can hear anything, which is why
    /// reduced motion keeps it — it is not decoration, and it does not
    /// loop.
    ///
    /// Opacity eases over 80 ms and scale does not: a level meter that
    /// eases is a level meter half a beat behind what you just said.
    private var levelRing: some View {
        Circle()
            .strokeBorder(Color.white, lineWidth: 2.5)
            .padding(-6)
            .opacity(phase == .live ? 0.25 + level * 0.55 : 0)
            .scaleEffect(phase == .live ? 1 + level * 0.22 : 1)
            .animation(.linear(duration: 0.08), value: phase == .live ? level : 0)
            .allowsHitTesting(false)
    }

    /// `ease-out` is `cubic-bezier(0, 0, .58, 1)`; this is the cheap
    /// stand-in a per-frame sample can afford, and it is a glow behind a
    /// button rather than a layout.
    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

    /// 0 → 1 → 0 across 1.1 seconds.
    private func thinking(_ t: TimeInterval) -> Double {
        let cycle = t.truncatingRemainder(dividingBy: 1.1) / 1.1
        return 0.5 - 0.5 * cos(cycle * 2 * .pi)
    }

    private func still(_ animation: Animation) -> Animation {
        stillMotion ? .linear(duration: 0.001) : animation
    }

    // MARK: - the gesture

    /// `pointerdown` / `pointerup`. `minimumDistance: 0` so the press is
    /// the first change, and a `DragGesture` because a `Button` fires on
    /// release and has no down edge at all.
    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !pressing else { return }
                pressing = true
                micDown()
            }
            .onEnded { _ in
                guard pressing else { return }
                pressing = false
                micUp()
            }
    }

    // MARK: - down

    /// `micDown` (app.js:5324-5392).
    private func micDown() {
        guard VoiceRecorder.available, !recorder.isLive, !busy else { return }

        heldAt = Date()
        base = JSText.trim(text)
        level = 0
        phase = .live
        /* Not "listening" yet. The first hold of all goes through a
           permission dialog, and telling someone the app is listening
           while iOS is still asking whether it may is a lie about two
           seconds long — which is exactly long enough to say the thing
           into. */
        hint = Copy.Mic.opening

        var hooks = VoiceHooks()
        hooks.vocab = vocab()

        hooks.onLive = {
            // On every hold after the first this arrives within a few
            // milliseconds and the line above is never really read.
            if recorder.isLive { hint = Copy.Mic.listening }
        }
        hooks.onLevel = { value in
            level = value
        }
        hooks.onWarn = {
            if recorder.isLive { hint = Copy.Mic.warn }
        }
        hooks.onCap = {
            /* Ending it here rather than throwing it away means the two
               minutes someone just said still becomes tasks. */
            micUp()
            toast(Copy.Mic.cappedToast)
        }
        hooks.onError = { why in
            rest()
            toast(why == .denied ? Copy.Mic.deniedToast : Copy.Mic.failedToast)
        }

        Task { await recorder.start(hooks) }
    }

    // MARK: - up

    /// `micUp` (app.js:5394-5454).
    private func micUp() {
        guard recorder.isLive else {
            if !busy { rest() }
            return
        }

        /* Tapped it rather than held it. Nothing was said, so nothing is
           sent — say what the button wants instead of spinning for a
           second first. */
        if Date().timeIntervalSince(heldAt) < Self.tapThreshold {
            recorder.abandon()
            rest()
            text = base
            hint = Copy.Mic.tooQuick
            return
        }

        busy = true
        phase = .working
        level = 0
        hint = Copy.Mic.writing

        Task {
            let out = await recorder.stop()

            /* The sheet was closed, or another hold started, while that
               was in the air. Whatever came back belongs to a moment
               that has gone. */
            guard busy else { return }
            rest()

            /* Only ever written when there is something to write —
               nothing came back, so nothing is touched. */
            if !out.text.isEmpty {
                text = base.isEmpty ? out.text : base + " " + out.text
            }

            if out.text.isEmpty {
                if out.source == .noMic {
                    hint = Copy.Mic.neverOpened
                    toast(Copy.Mic.noPermissionToast)
                } else {
                    hint = Copy.Mic.nothingHeard
                }
                return
            }

            /* Which model heard it decides what triage is told about the
               text. A browser transcript needs the repair pass; a Gemini
               one has already had it. */
            onSpoken(out.source, out.lang)

            if out.source == .browser {
                toast(Copy.Mic.roughToast)
            }
        }
    }

    // MARK: - rest

    /// `restMic` (app.js:5293-5299).
    private func rest() {
        busy = false
        phase = .rest
        level = 0
        hint = Copy.Mic.rest
    }

    /// `Voice.abandon(); restMic();` — the sheet closing on a live hold.
    private func abandonHold() {
        recorder.abandon()
        rest()
        pressing = false
    }
}

// MARK: - the glyph

/// `.composer-mic-icon` (app.html:1122-1126), off the same 24×24 box:
/// a filled capsule for the head, and a stroked cradle and stem under
/// it.
///
/// The cradle is sampled rather than drawn with `addArc`, because
/// `addArc`'s `clockwise` flag is measured in a coordinate space whose
/// y runs down and is a reliable way to end up with the arc on the
/// wrong side of the mic.
private struct MicGlyph: View {

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height) / 24

            ZStack {
                // "M12 3a3 3 0 0 1 3 3v6a3 3 0 0 1-6 0V6a3 3 0 0 1 3-3z"
                Capsule()
                    .frame(width: 6 * s, height: 12 * s)
                    .position(x: 12 * s, y: 9 * s)

                // "M5 11a7 7 0 0 0 14 0M12 18v3", stroke-width 2, round caps
                Path { p in
                    var first = true
                    var degrees = 180.0
                    while degrees >= 0 {
                        let r = degrees * .pi / 180
                        let point = CGPoint(x: (12 + 7 * cos(r)) * s,
                                            y: (11 + 7 * sin(r)) * s)
                        if first { p.move(to: point); first = false } else { p.addLine(to: point) }
                        degrees -= 5
                    }
                    p.move(to: CGPoint(x: 12 * s, y: 18 * s))
                    p.addLine(to: CGPoint(x: 12 * s, y: 21 * s))
                }
                .stroke(style: StrokeStyle(lineWidth: 2 * s, lineCap: .round, lineJoin: .round))
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .accessibilityHidden(true)
    }
}
