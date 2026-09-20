/* ============================================================
   MyADHD/UI/LoadingScreen.swift — the wait

   app.html:294-303, app.js:508-534, styles.css:305 (`.art--think`),
   inventory §1.4.

   The morph and one line of copy, and the copy moves on every 1900 ms
   through `LOADING_LINES` — four lines, wrapping, so a slow sort does not
   leave the same sentence on screen for eight seconds.

   Two things the web had to work around and this inherits:

   - **The clip is rewound every time.** A browser pauses a video inside a
     `display:none` screen and does not resume it when the screen comes
     back, so the wait had to start the morph itself; every wait therefore
     opens on beat 01, which is also the better picture. `AVPlayer` has the
     same problem for the same reason — the layer is gone while the screen
     is not on it — so it is seeked to zero and played on appear here too.
   - **Nothing decodes behind the lists.** `stopLoadingCopy()` pauses the
     video as well as clearing the timer.

   There are two clips because the artwork is drawn in ink, not in colour:
   `morph-light.mp4` and `morph-dark.mp4` are the same animation on the two
   grounds, picked by the theme rather than tinted. Both are copies of the
   web app's own files under `animation/app/`, and they are on the drift
   list in the README beside the font.

   Reduced motion holds frame 0 rather than playing, which is what
   `stillMode` does on the web.
   ============================================================ */

import AVFoundation
import SwiftUI

struct LoadingScreen: View {

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var stillMotion

    /// Which clip. Handed in rather than read from a store so a screenshot
    /// run can ask for either.
    var dark: Bool

    /// app.js:521.
    static let lineMS = 1900

    @State private var index = 0
    @State private var ticker: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            MorphView(dark: dark, still: stillMotion)
                .frame(width: 200, height: 200)
                .padding(.bottom, 20)
                .accessibilityHidden(true)

            Text(Copy.Loading.lines[index])
                .font(Font.baloo(16))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Copy.Loading.lines[index])
        }
        .padding(.horizontal, Theme.gutter(UIScreen.main.bounds.width))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    /// `startLoadingCopy()` — the first line is on screen before the timer
    /// has run once, which is why app.html ships it in the markup.
    private func start() {
        index = 0
        ticker?.cancel()
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.lineMS) * 1_000_000)
                guard !Task.isCancelled else { return }
                index = (index + 1) % Copy.Loading.lines.count
            }
        }
    }

    private func stop() {
        ticker?.cancel()
        ticker = nil
    }
}

// MARK: - the clip

/// `<video autoplay muted loop playsinline>`, in the terms AVFoundation
/// uses: no audio session of its own, looped by seeking back on the end
/// notification, and rewound whenever it comes on screen.
struct MorphView: UIViewRepresentable {

    let dark: Bool
    var still: Bool

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .clear
        context.coordinator.attach(to: view, dark: dark, still: still)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        context.coordinator.attach(to: view, dark: dark, still: still)
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// A view whose layer *is* the player layer, so the clip resizes with
    /// the view instead of being positioned frame by frame.
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    final class Coordinator {
        private var player: AVPlayer?
        private var loop: NSObjectProtocol?
        private var loaded: Bool?

        func attach(to view: PlayerView, dark: Bool, still: Bool) {
            if loaded != dark {
                stop()
                guard let url = Bundle.main.url(
                    forResource: dark ? "morph-dark" : "morph-light",
                    withExtension: "mp4"
                ) else { return }

                let player = AVPlayer(url: url)
                player.isMuted = true
                /* A muted decorative clip must not take the audio session
                   away from whatever the person is listening to. */
                player.actionAtItemEnd = .none
                view.playerLayer.player = player
                view.playerLayer.videoGravity = .resizeAspect

                loop = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: player.currentItem,
                    queue: .main
                ) { [weak player] _ in
                    player?.seek(to: .zero)
                    player?.play()
                }

                self.player = player
                loaded = dark
            }

            // every wait opens on beat 01
            player?.seek(to: .zero)
            if still { player?.pause() } else { player?.play() }
        }

        func stop() {
            player?.pause()
            if let loop { NotificationCenter.default.removeObserver(loop) }
            loop = nil
            player = nil
            loaded = nil
        }
    }
}
