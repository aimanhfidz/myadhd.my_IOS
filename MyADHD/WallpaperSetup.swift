/* ============================================================
   my.adhd for iOS — Lock Screen Display

   One page for everything about the matrix wallpaper: how it looks,
   what it shows, and whether the automation that puts it on the lock
   screen is actually running. Reached from Settings, from
   `myadhd://wallpaper`, and from the "Set up my.adhd wallpaper" action.

   **The preview never scrolls away.** It sits at the top beside the
   sliders that move it, and it is the same view the renderer draws, at
   the phone's own size and shrunk as a picture — so what moves here is
   what lands. A ghost of the clock and of the torch and camera is laid
   over it, because "where does the matrix start" only means something
   next to the things it has to clear.

   **Saved as it changes.** There is no Save button to forget. Every
   change is written to `Wallpaper.style` at once, and the lock screen
   picks it up the next time the Shortcut runs — the app cannot repaint a
   lock screen itself, and the page says so rather than implying it can.

   **Setup is a state, not a nag.** The shortcut leaves two stamps — one
   when the picture is drawn, one when its last step confirms the
   wallpaper was set — and `SetupHealth` (WallpaperHealth.swift) reads
   the pair. The steps themselves are one tap deeper, in
   `ShortcutSetupPage`.

   **What the competitor's page has that this one leaves out**, on
   purpose: a choice of matrix (there is one), a calendar mode, a task
   sort (the matrix's own order is the order), information above the
   matrix, and a manual wallpaper size (it is the screen's, always).
   ============================================================ */

import PhotosUI
import SwiftUI

/// The Settings row that leads here. Kept beside the page rather than in
/// `Copy`: like every wallpaper string, it has no web original for
/// Checks/copy.sh to find.
enum LockScreenCopy {
    static let caption = "Lock screen"
    static let row = "Lock Screen Display"
    static let note = "Your matrix on your wallpaper"
}

struct WallpaperSetup: View {
    @Environment(\.dismiss) private var dismiss

    @State private var style = Wallpaper.style
    @State private var board: WallpaperBoard? = WallpaperBoard.current()
    @State private var photo: CGImage? = Wallpaper.loadBackground()
    @State private var picked: PhotosPickerItem?
    @State private var lastRun: Date? = Wallpaper.lastRun
    @State private var lastConfirmed: Date? = Wallpaper.lastConfirmed
    @State private var showingSetup = false

    /// Open on the shortcut steps rather than the style page. Read once,
    /// on the first appear, so Back still lands on the style page.
    var startOnSteps = false
    @State private var startedOnSteps = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                pinned
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        statusCard
                        backgroundSection
                        contentSection
                        styleSection
                        footer
                    }
                    .padding(16)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(LockScreenCopy.row)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .navigationDestination(isPresented: $showingSetup) {
                ShortcutSetupPage(health: SetupHealth(drawn: lastRun, confirmed: lastConfirmed))
            }
        }
        .onChange(of: style) { _, next in Wallpaper.style = next }
        /* Only these two change which tasks are on the board; a slider
           drag must not re-read the store sixty times a second. */
        .onChange(of: style.scope) { _, _ in reloadBoard() }
        .onChange(of: style.hidden) { _, _ in reloadBoard() }
        .onAppear {
            lastRun = Wallpaper.lastRun
            lastConfirmed = Wallpaper.lastConfirmed
            reloadBoard()
            if startOnSteps && !startedOnSteps {
                startedOnSteps = true
                showingSetup = true
            }
        }
    }

    private func reloadBoard() {
        board = WallpaperBoard.current(style: style)
    }

    // MARK: - the pinned half: preview and sliders

    private var pinned: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 6) {
                preview(width: 128)
                Text("Preview")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                slider("Matrix position", $style.position, 0...1,
                       shown: percent(style.position), low: "arrow.up", high: "arrow.down")
                slider("Matrix size", $style.size, 0.4...1,
                       shown: percent(style.size), low: "minus", high: "plus")
                slider("Text size", $style.textScale, 0.8...1.3,
                       shown: percent(style.textScale), low: "textformat.size.smaller", high: "textformat.size.larger")
                slider("Background blur", $style.blur, 0...20,
                       shown: "\(Int(style.blur.rounded()))", low: "circle", high: "circle.dotted")
                    .disabled(!photoShowing)
                    .opacity(photoShowing ? 1 : 0.4)
                slider("Background brightness", $style.brightness, -0.6...0.4,
                       shown: signedPercent(style.brightness), low: "moon", high: "sun.max")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color(.systemBackground))
    }

    private var photoShowing: Bool { style.ground == .photo && photo != nil }

    /// Drawn at the phone's own size and shrunk as a picture, not laid out
    /// small: the matrix is sized in points for a lock screen, and a
    /// squeezed layout would wrap every title to a letter.
    private func preview(width: CGFloat) -> some View {
        let screen = UIScreen.main.bounds.size
        return ZStack(alignment: .top) {
            WallpaperView(board: board ?? WallpaperBoard(quads: []), background: photo, style: style)
            LockGhost(height: screen.height)
        }
        .frame(width: screen.width, height: screen.height)
        .scaleEffect(width / screen.width, anchor: .topLeading)
        .frame(width: width, height: width * screen.height / screen.width, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        shown: String, low: String, high: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(shown)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: low).font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: value, in: range)
                Image(systemName: high).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    private func signedPercent(_ v: Double) -> String {
        let n = Int((v * 100).rounded())
        return n > 0 ? "+\(n)%" : "\(n)%"
    }

    // MARK: - is it running?

    private var statusCard: some View {
        let health = SetupHealth(drawn: lastRun, confirmed: lastConfirmed)
        return Button { showingSetup = true } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: health.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(health.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(health.title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(health.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                HStack(spacing: 3) {
                    Text(health.action)
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(health.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(health.tint.opacity(0.25), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - background

    private var backgroundSection: some View {
        section("Background", symbol: "photo") {
            Picker("Background", selection: $style.ground) {
                Text("Photo").tag(WallpaperStyle.Ground.photo)
                Text("Color").tag(WallpaperStyle.Ground.color)
            }
            .pickerStyle(.segmented)

            if style.ground == .photo { photoRow } else { colorRow }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task { @MainActor in
                guard let data = try? await item.loadTransferable(type: Data.self),
                      Wallpaper.saveBackground(data) else { return }
                photo = Wallpaper.loadBackground()
            }
        }
    }

    /// Set Wallpaper Photo replaces the lock screen's photo outright, so
    /// the matrix has to bring the person's own picture with it. The
    /// system picker runs out of process, so no library permission is
    /// asked for.
    private var photoRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let photo {
                    Image(decorative: photo, scale: 1).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [Color(red: 16 / 255, green: 16 / 255, blue: 24 / 255),
                                            Color(red: 26 / 255, green: 24 / 255, blue: 46 / 255)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(width: 56, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.quaternary, lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 10) {
                PhotosPicker(selection: $picked, matching: .images) {
                    Label(photo == nil ? "Choose your photo" : "Change photo", systemImage: "photo.badge.plus")
                        .font(.system(size: 14.5, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                if photo != nil {
                    Button(role: .destructive) {
                        Wallpaper.clearBackground()
                        photo = nil
                    } label: {
                        Label("Remove photo", systemImage: "trash")
                            .font(.system(size: 14.5, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color.red.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
                Text(photo == nil
                     ? "Until you choose one, the matrix sits on my.adhd's dark background."
                     : "Pick the same photo your lock screen uses now, and nothing behind the matrix changes.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static let swatches: [UInt32] = [
        0x101018, 0x1A1830, 0x0E2235, 0x0F2A1D, 0x2B1210, 0x3A2A12,
        0xE9E7FB, 0xF4EFE6, 0xDCEFE4, 0xFBE3DF,
    ]

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                ForEach(Self.swatches, id: \.self) { hex in
                    let on = style.color == hex
                    Button { style.color = hex } label: {
                        Circle()
                            .fill(WallpaperView.color(hex))
                            .frame(width: 34, height: 34)
                            .overlay(Circle().stroke(.quaternary, lineWidth: 1))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: on ? 3 : 0).padding(-4))
                    }
                    .buttonStyle(.plain)
                }
                ColorPicker("", selection: customColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 34, height: 34)
            }
            if Self.isLight(style.color) && style.cards == .dark {
                Text("Light cards read better on a pale colour — switch them under Style.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { WallpaperView.color(style.color) },
            set: { color in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
                style.color = (byte(r) << 16) | (byte(g) << 8) | byte(b)
            }
        )
    }

    private static func isLight(_ hex: UInt32) -> Bool {
        let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 160
    }

    // MARK: - what to show

    private static let quadrants: [(key: String, title: String, symbol: String)] = [
        ("do", "Important & Urgent", "flame.fill"),
        ("plan", "Important & Not Urgent", "calendar"),
        ("delegate", "Urgent & Less Important", "bolt.fill"),
        ("drop", "Not Urgent & Less Important", "list.bullet"),
    ]

    private var contentSection: some View {
        section("What to show", symbol: "square.grid.2x2") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Tasks", selection: $style.scope) {
                    Text("All tasks").tag(WallpaperStyle.Scope.all)
                    Text("Today & late").tag(WallpaperStyle.Scope.today)
                }
                .pickerStyle(.segmented)
                Text(style.scope == .all
                     ? "Every open task, in the box the matrix puts it."
                     : "Only tasks due today or already late. Boxes stay where they are.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Self.quadrants, id: \.key) { q in
                    Toggle(isOn: shown(q.key)) {
                        Label {
                            Text(q.title).font(.system(size: 14.5))
                        } icon: {
                            Image(systemName: q.symbol)
                                .foregroundStyle(WallpaperView.color(QuadrantPalette.hueHex(q.key, dark: false)))
                        }
                    }
                    .disabled(isLastShown(q.key))
                    .padding(.vertical, 7)
                    if q.key != Self.quadrants.last?.key { Divider() }
                }
            }
            Text("A box on its own takes the whole row. At least one stays on.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
    }

    private func shown(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !style.hidden.contains(key) },
            set: { on in
                var hidden = Set(style.hidden)
                if on { hidden.remove(key) } else { hidden.insert(key) }
                style.hidden = Self.quadrants.map(\.key).filter { hidden.contains($0) }
            }
        )
    }

    private func isLastShown(_ key: String) -> Bool {
        !style.hidden.contains(key) && style.hidden.count >= Self.quadrants.count - 1
    }

    // MARK: - style

    private var styleSection: some View {
        section("Style", symbol: "paintbrush") {
            HStack {
                Text("Cards").font(.system(size: 14.5))
                Spacer()
                Picker("Cards", selection: $style.cards) {
                    Text("Dark").tag(WallpaperStyle.Cards.dark)
                    Text("Light").tag(WallpaperStyle.Cards.light)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            Toggle(isOn: $style.lockOnly) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lock Screen only").font(.system(size: 14.5))
                    Text("Your Home Screen keeps the photo, without the matrix behind your apps.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Text("Changes are saved as you make them, and reach your lock screen the next time the shortcut runs.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Reset to default") { style = WallpaperStyle() }
                .font(.system(size: 14, weight: .semibold))
                .disabled(style == WallpaperStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    // MARK: - furniture

    private func section<Content: View>(_ title: String, symbol: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.system(size: 16, weight: .bold))
                .labelStyle(.titleAndIcon)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - the clock, torch and camera, for scale

/// A faint stand-in for what iOS draws over the wallpaper, so the preview
/// shows the matrix against the things it has to clear. Only ever drawn
/// in the preview — never baked into the picture.
private struct LockGhost: View {
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Text(Date.now, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.system(size: 21, weight: .semibold))
                Text(Date.now, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                    .font(.system(size: 92, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.72))
            .padding(.top, height * 0.075)

            HStack {
                Circle().frame(width: 50, height: 50)
                Spacer()
                Circle().frame(width: 50, height: 50)
            }
            .foregroundStyle(.white.opacity(0.22))
            .padding(.horizontal, 44)
            .padding(.top, height * 0.885)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}

// MARK: - the steps, one tap deeper

/// Apple gives no API for creating a Shortcut or an Automation, so these
/// taps are irreducible. Numbered, in the order they have to happen, with
/// the one mistake that makes everything look broken said out loud.
struct ShortcutSetupPage: View {
    let health: SetupHealth

    @State private var forceRedraw = Wallpaper.forceRedraw

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 8) {
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.accentColor)
                    Text("Shortcut automation setup")
                        .font(.system(size: 22, weight: .bold))
                    Text(health.isWorking ? "Setup already completed" : "About a minute, once.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)

                /* With the link it is one tap to Shortcuts' own Add page,
                   and the shortcut arrives already right: Lock Screen only,
                   no preview, skip when nothing moved, confirm at the end.
                   Without it, the three actions have to be built by hand. */
                if let url = AppConfig.wallpaperShortcutURL {
                    step(1, "Add the shortcut",
                         "It redraws your matrix and puts it on your lock screen, and only when something on it changed.") {
                        Link(destination: url) {
                            Label("Add the shortcut", systemImage: "plus.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                } else {
                    step(1, "Add the shortcut",
                         "Three actions, in this order: Update my.adhd wallpaper → Set Wallpaper Photo → Confirm my.adhd wallpaper. The last one is how this page knows it worked.") {}
                }
                step(2, "Make it run every morning",
                     "Shortcuts → Automation → + → Time of Day → 07:00 → Run Immediately. Add the shortcut you just installed.") {}
                step(3, "And every time you leave the app",
                     "Automation → + → App → my.adhd → Is Closed → Run Immediately. Same shortcut. Whatever you just changed is on your lock screen before you lock it.") {}
                step(4, "And when you lock the phone in the app",
                     "Automation → + → Notification → App: my.adhd, Body contains \"lock screen\" → Run Immediately. Same shortcut. Pressing the side button doesn't count as closing the app, so my.adhd sends a quiet notification instead, and this catches it.") {}
                step(5, "Check your lock screen is a Photo",
                     "Not Photo Shuffle. Set Wallpaper Photo silently does nothing on Shuffle, and this is the most common reason it looks broken.") {}

                Toggle(isOn: $forceRedraw) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Force a redraw").font(.system(size: 15.5, weight: .semibold))
                        Text("Turn on if your lock screen doesn't change after the shortcut runs. It sets the picture twice and switches to it, which is slower.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onChange(of: forceRedraw) { _, next in Wallpaper.forceRedraw = next }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Don't just run the shortcut by hand — set up the automations, so your lock screen updates by itself.")
                        .font(.system(size: 13.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(spacing: 18) {
                    Button {
                        if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) }
                    } label: {
                        Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Button {
                        UIPasteboard.general.string = Self.plainSteps
                    } label: {
                        Label("Copy steps", systemImage: "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Shortcut Setup")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step<Extra: View>(_ n: Int, _ title: String, _ detail: String,
                                   @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(.quaternary, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                extra().padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private static var plainSteps: String {
        AppConfig.wallpaperShortcutURL.map { url in """
        my.adhd — lock screen setup

        1. Add the shortcut: \(url.absoluteString)
        2. Shortcuts → Automation → + → Time of Day → 07:00 → Run Immediately.
           Run the my.adhd Lock Screen shortcut you just added.
        3. Automation → + → App → my.adhd → Is Closed → Run Immediately.
           Same shortcut.
        4. Automation → + → Notification → App: my.adhd,
           Body contains "lock screen" → Run Immediately. Same shortcut.
        5. Make sure your current lock screen is a Photo, not Photo Shuffle.
        """ } ?? handBuilt
    }

    private static let handBuilt = """
    my.adhd — lock screen setup

    1. Make the shortcut — three actions, in this order:
       Update my.adhd wallpaper → Set Wallpaper Photo → Confirm my.adhd wallpaper.
    2. Shortcuts → Automation → + → Time of Day → 07:00 → Run Immediately.
       Run the shortcut from step 1.
       In Set Wallpaper Photo, turn off Show Preview and Crop to Subject,
       and untick Home Screen so only the lock screen changes.
    3. Automation → + → App → my.adhd → Is Closed → Run Immediately.
       Same shortcut.
    4. Make sure your current lock screen is a Photo, not Photo Shuffle.
    """
}
