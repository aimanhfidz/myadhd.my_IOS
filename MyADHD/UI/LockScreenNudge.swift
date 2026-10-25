/* ============================================================
   MyADHD/UI/LockScreenNudge.swift — the lock screen, offered on Home

   The wallpaper is the one surface somebody looks at eighty times a day
   without deciding to, and its setup lived three taps deep in Settings.
   Ink puts its setup in front of you; this is ours, under the numbers.

   It is there only while it has something to say:

   - **Not set up, or broken** — it says which, in `SetupHealth`'s own
     words, so this card and the setup page never disagree.
   - **Working** — gone. A card that congratulates you every morning is
     furniture, and furniture stops being read.
   - **"Not now"** — gone for a week, then back once. Somebody who said
     no should not be asked daily.

   No web original: the website cannot set a wallpaper, so there is
   nothing in app.html for `Checks/copy.sh` to hold this to.

   It reads the shortcut's two stamps again whenever the app comes back
   to the front, because the usual way to fix what it says is to go to
   Shortcuts, run it, and come back.
   ============================================================ */

import SwiftUI

struct LockScreenNudge: View {

    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var stillMotion

    @State private var health = Self.read()
    @State private var snoozed = Self.isSnoozed()

    private static let snoozeKey = "myadhd.wallpaper.homeSnoozedUntil"
    private static let snoozeFor: TimeInterval = 7 * 24 * 60 * 60

    var body: some View {
        Group {
            if !health.isWorking && !snoozed {
                card
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: health.state == .never ? "lock.iphone" : health.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(broken ? theme.orange : theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Font.baloo(17, .bold))
                        .foregroundStyle(theme.ink)
                    Text(health.detail)
                        .font(Font.baloo(14))
                        .foregroundStyle(theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Button {
                    Inbox.openWallpaperSetup(steps: true)
                } label: {
                    Text(health.state == .never ? "Set it up" : health.action)
                        .font(Font.baloo(15, .bold))
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 44)
                        .background(theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)

                Button("Not now", action: snooze)
                    .font(Font.baloo(14.5))
                    .foregroundStyle(theme.faint)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
            }
            .padding(.leading, 40)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
                .strokeBorder(broken ? theme.orange : theme.line, lineWidth: 1.5)
        )
        .accessibilityElement(children: .contain)
    }

    /// The setup page says "Not set up yet" under a heading that already
    /// says what. On Home there is no heading, so the title has to.
    private var title: String {
        health.state == .never ? "Put your matrix on your lock screen" : health.title
    }

    /// Orange is for late and broken (BRAND.md §3.3); not set up is neither.
    private var broken: Bool {
        switch health.state {
        case .noConfirm, .unfinished, .stalled: return true
        case .never, .working: return false
        }
    }

    // MARK: - state

    private static func read() -> SetupHealth {
        SetupHealth(drawn: Wallpaper.lastRun, confirmed: Wallpaper.lastConfirmed)
    }

    private static func isSnoozed(_ now: Date = Date()) -> Bool {
        guard let until = UserDefaults.standard.object(forKey: snoozeKey) as? Date else { return false }
        return now < until
    }

    private func refresh() {
        health = Self.read()
        snoozed = Self.isSnoozed()
    }

    private func snooze() {
        UserDefaults.standard.set(Date().addingTimeInterval(Self.snoozeFor), forKey: Self.snoozeKey)
        withAnimation(stillMotion ? nil : Theme.ease(0.2)) { snoozed = true }
    }
}
