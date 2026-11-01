/* ============================================================
   MyADHD/UI/WallpaperShelf.swift — the lock screen library, on Home

   Ink's Discover tab, for the designs in `WallpaperPreset.library`
   (WallpaperDesigns.swift): a heading with a count and a way into all of
   them, then a row of phone-shaped previews you swipe through, each with
   one button.

   **Every preview is your own.** Your tasks, your photo, your cards, at
   your phone's size and shrunk as a picture — the same view the shortcut
   renders, so a tile never promises a lock screen the shortcut will not
   draw. Ink's previews are stock photos with sample events; a list of
   somebody else's tasks is no help choosing how to see your own.

   **Tap the picture to try it on; tap the button to choose it.** The
   picture opens that design's own page (`WallpaperSetup(preset:)`), a
   draft you can change before anything is saved — Ink's design page.
   The button is the shortcut past it:
   - *Set as current* saves the design and runs the shortcut now, by name
     (`AppConfig.wallpaperShortcutName`), so it lands straight away. If the
     shortcut has never run, the setup steps open instead, because a saved
     design nobody can see is a broken promise.
   - *Update* on the current one runs the shortcut again.
   - *Set up* on the current one when the shortcut has never confirmed.

   No web original — the website cannot set a wallpaper — so like every
   wallpaper string these live here, not in `Copy`, and Checks/copy.sh has
   nothing to hold them to.
   ============================================================ */

import SwiftUI

struct WallpaperShelf: View {

    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    /// The store in memory, so a tile changes the moment a task does.
    let tasks: [TaskItem]
    var today: String = WebDates.dayKey()

    /// First run: Home has dimmed everything else and this shows a card
    /// saying what the row is for (WallpaperSpotlight, below).
    var spotlight = false
    /// Got it, or a design opened or chosen: the spotlight has done its job.
    var spotlightDone: () -> Void = {}

    /* SwiftUI evaluates these initial values every time Home rebuilds this
       view, ticking a task included, and throws them away. So nothing
       costly goes here: the photo (a full-screen JPEG decode) and the board
       (every design's data) are filled in by refresh(), on appear. */
    @State private var style = Wallpaper.style
    @State private var photo: CGImage?
    @State private var board = WallpaperBoard(quads: [])
    @State private var health = Self.health()
    @State private var showingAll = false
    @State private var opened: WallpaperPreset?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if spotlight { coach.transition(.opacity) }

            Button { showingAll = true } label: {
                HStack(alignment: .center, spacing: 10) {
                    Text("Lock Screen")
                        .font(Font.baloo(24, .heavy))
                        .kerning(-0.02 * 24)
                        .foregroundStyle(theme.ink)
                    Text(String(WallpaperPreset.library.count))
                        .font(Font.baloo(14, .bold))
                        .foregroundStyle(theme.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .background(theme.line, in: Capsule())
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(theme.muted)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows every design")

            Text("Your tasks, drawn on your lock screen. Pick a design.")
                .font(Font.baloo(14))
                .foregroundStyle(theme.faint)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(WallpaperPreset.library) { preset in
                        WallpaperTile(preset: preset, board: board, photo: photo, style: style,
                                      health: health, width: 150,
                                      open: { spotlightDone(); opened = $0 },
                                      choose: { spotlightDone(); choose($0) })
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            /* So the current tile's ring is not shaved off top and bottom.
               Sideways the row still stops at Home's gutter: the page's own
               ScrollView clips there, and bleeding past it would mean
               unclipping the whole page. */
            .scrollClipDisabled()
        }
        .padding(.top, 10)
        .onAppear(perform: refresh)
        .onChange(of: tasks) { _, _ in rebuildBoard() }
        .onChange(of: style) { _, _ in rebuildBoard() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
        .sheet(isPresented: $showingAll, onDismiss: refresh) {
            WallpaperLibraryPage(board: board, photo: photo, style: style,
                                 health: health, choose: choose)
        }
        .sheet(item: $opened, onDismiss: refresh) { preset in
            WallpaperSetup(preset: preset)
        }
    }

    /// Ink's first-run spotlight, said our way: what the row does, and
    /// that trying one on changes nothing.
    private var coach: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Put your day on your lock screen")
                .font(Font.baloo(16.5, .heavy))
                .foregroundStyle(theme.ink)
            Text("Tap a design to see your own tasks on it. Nothing changes until you set it.")
                .font(Font.baloo(14))
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: spotlightDone) {
                    Text("Got it")
                        .font(Font.baloo(14.5, .bold))
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
                .strokeBorder(theme.accent, lineWidth: 1.5)
        )
    }

    /// Every design's data at once, from the tasks in memory. Rebuilt when
    /// the tasks or the style move, not on every redraw of Home.
    private func rebuildBoard() {
        board = WallpaperBoard.build(tasks, style: style, today: today,
                                     designs: Set(WallpaperStyle.Design.allCases))
    }

    private static func health() -> SetupHealth {
        SetupHealth(drawn: Wallpaper.lastRun, confirmed: Wallpaper.lastConfirmed)
    }

    /// Re-read what the setup page and the shortcut may have changed while
    /// we were away: the style, the photo, and the two stamps.
    private func refresh() {
        style = Wallpaper.style
        photo = Wallpaper.loadBackground()
        health = Self.health()
        rebuildBoard()
    }

    private func choose(_ preset: WallpaperPreset) {
        if !preset.isCurrent(style, background: photo) {
            let next = preset.applied(to: style)
            Wallpaper.style = next
            style = next
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        if health.state == .never {
            Inbox.openWallpaperSetup(steps: true)
        } else {
            Self.runShortcut()
        }
    }

    /// Runs the installed shortcut and comes back. Shortcuts says so
    /// itself if there is none by that name — an older version, renamed,
    /// or deleted — which is a clearer message than any guess from here.
    static func runShortcut() {
        var parts = URLComponents()
        parts.scheme = "shortcuts"
        parts.host = "x-callback-url"
        parts.path = "/run-shortcut"
        parts.queryItems = [
            URLQueryItem(name: "name", value: AppConfig.wallpaperShortcutName),
            URLQueryItem(name: "x-success", value: "myadhd://open"),
            /* Shortcuts calls this when the run fails, and the usual
               reason is that this version is not installed: a phone still
               on v2 has no shortcut by this name. The steps install it. */
            URLQueryItem(name: "x-error", value: "myadhd://wallpaper?steps=1"),
        ]
        if let url = parts.url { UIApplication.shared.open(url) }
    }
}

// MARK: - one design

/// A phone-shaped preview with its button laid over the foot, and its
/// name underneath. The current one is ringed in the accent.
struct WallpaperTile: View {

    @Environment(\.theme) private var theme

    let preset: WallpaperPreset
    let board: WallpaperBoard
    let photo: CGImage?
    let style: WallpaperStyle
    let health: SetupHealth
    let width: CGFloat
    let open: (WallpaperPreset) -> Void
    let choose: (WallpaperPreset) -> Void

    private var current: Bool { preset.isCurrent(style, background: photo) }

    /// The tile shows the design on the person's own cards: their Auto
    /// stays Auto on every design that does not pin the cards itself.
    private var tried: WallpaperStyle {
        preset.isCurrent(style, background: photo) ? style : preset.applied(to: style)
    }

    var body: some View {
        let screen = UIScreen.main.bounds.size
        let height = width * screen.height / screen.width
        let radius = width * 0.12

        VStack(spacing: 10) {
            ZStack(alignment: .bottom) {
                /* Drawn at the phone's own size and shrunk as a picture,
                   as the setup page's preview is: laid out at 150 points
                   wide, every title would wrap to a letter. */
                Button { open(preset) } label: {
                    ZStack(alignment: .top) {
                        WallpaperView(board: board, background: photo, style: tried)
                        LockGhost(height: screen.height)
                    }
                    .frame(width: screen.width, height: screen.height)
                    .scaleEffect(width / screen.width, anchor: .topLeading)
                    .frame(width: width, height: height, alignment: .topLeading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.name)
                .accessibilityHint("Opens this design to try it and change it")

                Button { choose(preset) } label: {
                    Text(label)
                        .font(Font.baloo(14.5, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
                        .background(Color.black.opacity(0.25), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                        .environment(\.colorScheme, .dark)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .accessibilityLabel("\(preset.name): \(label)")
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(current ? theme.accent : theme.line, lineWidth: current ? 3 : 1)
            }

            HStack(spacing: 5) {
                if current {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.accent)
                }
                Text(preset.name)
                    .foregroundStyle(current ? theme.ink : theme.muted)
            }
            .font(Font.baloo(15, current ? .bold : .semibold))
        }
        .frame(width: width)
    }

    private var label: String {
        guard current else { return "Set as current" }
        return health.state == .never ? "Set up" : "Update"
    }
}

// MARK: - all of them

/// The chevron's page: the whole library, two to a row. Six designs fit
/// on the shelf today; this is what still works at sixty.
struct WallpaperLibraryPage: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let board: WallpaperBoard
    let photo: CGImage?
    let style: WallpaperStyle
    let health: SetupHealth
    let choose: (WallpaperPreset) -> Void

    /// The page's own copy of the style, so a tap ticks the new tile here
    /// without waiting for Home behind the sheet.
    @State private var shown: WallpaperStyle?
    @State private var opened: WallpaperPreset?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let gap: CGFloat = 14
                let width = (min(geo.size.width, Theme.measure) - 16 * 2 - gap) / 2
                ScrollView {
                    LazyVGrid(columns: [GridItem(.fixed(width), spacing: gap),
                                        GridItem(.fixed(width), spacing: gap)],
                              spacing: 22) {
                        ForEach(WallpaperPreset.library) { preset in
                            WallpaperTile(preset: preset, board: board, photo: photo,
                                          style: shown ?? style, health: health,
                                          width: width, open: { opened = $0 }) { p in
                                /* Not set up yet, the tap ends on the
                                   setup steps — a sheet of the shell's,
                                   which cannot rise over this one. */
                                if health.state == .never {
                                    dismiss()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { choose(p) }
                                } else {
                                    choose(p)
                                    shown = p.applied(to: shown ?? style)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(theme.surface.ignoresSafeArea())
            /* A sheet over this sheet: the design page is its own, so it
               can rise from here without closing the library first. */
            .sheet(item: $opened, onDismiss: { shown = Wallpaper.style }) { preset in
                WallpaperSetup(preset: preset)
            }
            .navigationTitle("Lock Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Customise") {
                        dismiss()
                        /* After the sheet is gone: the setup page is a
                           sheet of the shell's, and one cannot rise over
                           another. */
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            Inbox.openWallpaperSetup()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - the first-run spotlight

/// Once per phone: the first time Home has a shelf to show and the
/// wallpaper shortcut has never run, Home dims everything else and the
/// shelf says what it is for. Done for good on "Got it", or the moment a
/// design is opened or chosen, which is the thing it was pointing at.
enum WallpaperSpotlight {
    private static let key = "myadhd.wallpaper.spotlightSeen"

    static var due: Bool {
        guard !UserDefaults.standard.bool(forKey: key) else { return false }
        return SetupHealth(drawn: Wallpaper.lastRun, confirmed: Wallpaper.lastConfirmed).state == .never
    }

    static func done() { UserDefaults.standard.set(true, forKey: key) }
}
