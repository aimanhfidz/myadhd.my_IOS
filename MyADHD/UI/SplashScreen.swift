/* ============================================================
   MyADHD/UI/SplashScreen.swift — the way in

   What a cold start shows for about a second before the app: the mark
   drawing itself, and the wordmark opening out beside it. Nothing is
   loading behind it — the store is read synchronously before the first
   frame — so it is an entrance, not a wait, and it is kept short and can
   be tapped away.

   **The ground is `surface`, not `backdrop`,** because `surface` is what
   `LaunchGround` is (#FFFFFF / #101018) and what every screen paints
   itself in. The static launch screen hands over to this with no change
   of colour, as long as the phone's appearance and the app's theme agree;
   when they do not, the launch screen cannot know (see Info.plist) and
   the switch happens under the mark instead of under the app.

   **The lockup is the brand's own** (`icons/wordmark.py` in the web
   repo): the mark to the left of "my.adhd" in Baloo 2 at 700 with
   −0.03em tracking, the mark `font × 26/16` tall and `font × 10/16` clear
   of the word. "my" is ink and ".adhd", dot included, is violet — orange
   belongs to the mark alone.

   **The motion is the web hero's** (chrome.css:476-553): the rays come
   out on `--in-ease`, one after another as `hero-word` staggers its
   words, the capsule lands on `--in-pop`'s overshoot, and the word rises
   in the way `hero-word` does. Reduced motion gets the finished lockup,
   held still, and a shorter stay.

   It plays once per launch: `AppShell` owns the flag, and coming back
   from the background is not a launch.
   ============================================================ */

import SwiftUI

struct SplashScreen: View {

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var stillMotion

    /// Called once, when it starts to leave. The host fades it out.
    var done: () -> Void

    /// The wordmark's size. Everything else in the lockup is a share of it.
    private static let font: CGFloat = 34
    private static let markSize = font * 26 / 16
    private static let gap = font * 10 / 16

    @State private var rays: [CGFloat] = [0, 0, 0, 0]
    @State private var capsule: CGFloat = 0
    /// 0 → the word is folded away behind the mark; 1 → all of it.
    @State private var word: CGFloat = 0
    @State private var wordWidth: CGFloat = 0
    @State private var leaving = false
    @State private var finished = false

    var body: some View {
        ZStack {
            theme.surface.ignoresSafeArea()

            lockup
                .scaleEffect(leaving ? 1.06 : 1)
                .opacity(leaving ? 0 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task { await play() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Share.title)
    }

    // MARK: the lockup

    private var lockup: some View {
        HStack(spacing: Self.gap * word) {
            LogoMark(rays: rays, capsule: capsule)
                .frame(width: Self.markSize, height: Self.markSize)

            wordmark
                .fixedSize()
                .background {
                    GeometryReader { g in
                        Color.clear.preference(key: WordWidthKey.self, value: g.size.width)
                    }
                }
                /* Folded to nothing and opened to its own width, so the
                   mark starts dead centre and is walked left by the word
                   arriving, rather than sitting off to one side of an
                   empty space the word has not filled yet. */
                .frame(width: wordWidth * word, alignment: .leading)
                .clipped()
                .opacity(Double(word))
                .offset(y: (1 - word) * 8)
        }
        .onPreferenceChange(WordWidthKey.self) { w in
            if w > 0 { wordWidth = w }
        }
    }

    /// `<span class="wordmark">my<span class="accent">.adhd</span></span>`
    private var wordmark: some View {
        (Text(Copy.Brand.my).foregroundStyle(theme.ink)
            + Text(Copy.Brand.adhd).foregroundStyle(theme.violet))
            .font(Font.baloo(Self.font, .bold))
            .kerning(-0.03 * Self.font)
            .lineLimit(1)
    }

    // MARK: the timeline

    private func play() async {
        if stillMotion {
            rays = [1, 1, 1, 1]
            capsule = 1
            word = 1
            await pause(0.5)
            finish()
            return
        }

        /* One beat for the first frame to reach the glass, so the launch
           screen hands over to an empty ground rather than to a mark
           already half drawn. */
        await pause(0.08)

        for i in rays.indices {
            withAnimation(Theme.arrive(0.42)) { rays[i] = 1 }
            await pause(0.07)
        }
        withAnimation(Theme.pop(0.38)) { capsule = 1 }
        await pause(0.1)
        withAnimation(Theme.arrive(0.5)) { word = 1 }
        await pause(0.62)
        finish()
    }

    /// Leaving, whether the timeline got there or a tap did.
    private func finish() {
        guard !finished else { return }
        finished = true
        withAnimation(stillMotion ? .linear(duration: 0.15) : .easeOut(duration: 0.3)) {
            leaving = true
        }
        done()
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

private struct WordWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

// MARK: - the mark

/// `#logo-mark`: a four-ray asterisk in Vivid Orange with one short ray,
/// and the capsule's stroke in violet. Four rectangles and a line, at the
/// coordinates app.html:171-179 gives them in a 100-unit box.
///
/// It came out of the home header when the screen's own name took that
/// place, and it lives here now because the splash is what draws it.
///
/// `rays` and `capsule` are how far each part has arrived, 0 to 1, so the
/// splash can draw it in; at their defaults it is simply the mark.
struct LogoMark: View {

    @Environment(\.theme) private var theme

    /// The four rays, in drawing order: across, down, the long diagonal,
    /// the short one.
    var rays: [CGFloat] = [1, 1, 1, 1]
    var capsule: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 100
            ZStack {
                ray(64, angle: 0, grown: grown(0), s: s)
                ray(64, angle: 90, grown: grown(1), s: s)
                ray(64, angle: 45, grown: grown(2), s: s)
                /* the short one: half the length, and it is what stops the
                   mark reading as a snowflake */
                ray(32, angle: -45, grown: grown(3), s: s)

                Path { p in
                    p.move(to: CGPoint(x: 64.5 * s, y: 64.5 * s))
                    p.addLine(to: CGPoint(x: 71.5 * s, y: 71.5 * s))
                }
                .stroke(theme.violet, style: StrokeStyle(lineWidth: 7 * s, lineCap: .round))
                /* about its own middle, (68, 68) in the box */
                .scaleEffect(capsule, anchor: UnitPoint(x: 0.68, y: 0.68))
                .opacity(capsule > 0 ? 1 : 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func grown(_ i: Int) -> CGFloat {
        rays.indices.contains(i) ? rays[i] : 1
    }

    /// `<rect x="46.5" y="18" width="7" height="h" transform="rotate(a 50 50)">`
    ///
    /// `position` places the bar's own centre in the 100-unit box; the
    /// rotation is then about the centre of the box itself, which is the
    /// 50,50 the SVG rotates about.
    ///
    /// A long ray crosses the centre, so it grows out both ways from its
    /// middle; the short one ends at the centre, so it grows out from
    /// there — its bottom edge before the rotation.
    private func ray(_ height: CGFloat, angle: Double, grown: CGFloat, s: CGFloat) -> some View {
        Rectangle()
            .fill(theme.orange)
            .frame(width: 7 * s, height: height * s)
            .scaleEffect(x: 1, y: grown, anchor: height < 64 ? .bottom : .center)
            .position(x: 50 * s, y: (18 + height / 2) * s)
            .rotationEffect(.degrees(angle), anchor: .center)
    }
}
