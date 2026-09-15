/* ============================================================
   my.adhd for iOS — getting the automation set up, once

   Apple gives no API for creating a Shortcut or an Automation, so a few
   taps here are irreducible. What is avoidable is the nagging.

   The competitor this was modelled on carries a permanent "finish setting
   up your lock screen" banner, and it is permanent because the app cannot
   tell whether setup finished. This one can: WallpaperIntent.perform() is
   ground truth, and it stamps Wallpaper.lastRun every time it runs. So
   there are three states and the middle one says nothing at all.

       never run      -> the instructions
       within 36h     -> "Working. Last updated 07:01 today." and no
                         banner anywhere else in the app
       older than 36h -> something is wrong, and what to check

   The thing that actually gets people through it is not the copy — it is
   the preview. It is the same SwiftUI view the renderer draws, so showing
   somebody their own tasks in the real layout costs nothing.
   ============================================================ */

import SwiftUI

struct WallpaperSetup: View {
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: TaskSnapshot? = TaskStore.read()
    @State private var lastRun: Date? = Wallpaper.lastRun

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    state
                    preview
                    steps
                    Spacer(minLength: 8)
                }
                .padding(20)
            }
            .navigationTitle("Lock screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: the three states

    @ViewBuilder
    private var state: some View {
        switch health {
        case .working:
            card(tint: .green,
                 title: "Working.",
                 body: "Last updated \(stamp). Nothing to do.")
        case .stalled(let when):
            card(tint: .orange,
                 title: "Hasn't run since \(when).",
                 body: "Open Shortcuts and check the automation is set to Run Immediately rather than Ask Before Running.")
        case .never:
            card(tint: .accentColor,
                 title: "Not set up yet.",
                 body: "About a minute, once. Your lock screen then redraws itself every morning without you opening anything.")
        }
    }

    private func card(tint: Color, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 17, weight: .bold, design: .rounded))
            Text(body).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    // MARK: the preview

    /// Their own tasks, in the real layout, with the regions iOS draws over
    /// marked. Worth more than any amount of instruction copy.
    @ViewBuilder
    private var preview: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 8) {
                Text("YOURS, RIGHT NOW")
                    .font(.system(size: 11, weight: .bold)).tracking(1.2)
                    .foregroundStyle(.secondary)

                WallpaperView(snapshot: snapshot, dark: ShellState.rememberedTheme != "light")
                    .aspectRatio(9.0 / 19.5, contentMode: .fit)
                    .frame(maxWidth: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(.quaternary, lineWidth: 1)
                    }
                    .overlay(alignment: .top) { guideLabel("clock sits here", 0.30) }
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        } else {
            card(tint: .secondary,
                 title: "Nothing to draw yet.",
                 body: "Open the app, dump something, and come back — the picture is made from your own list.")
        }
    }

    private func guideLabel(_ text: String, _ fraction: CGFloat) -> some View {
        GeometryReader { geo in
            Text(text)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity)
                .offset(y: geo.size.height * fraction - 10)
        }
    }

    // MARK: the steps

    private var steps: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("WHAT TO DO")
                .font(.system(size: 11, weight: .bold)).tracking(1.2)
                .foregroundStyle(.secondary)

            step(1, "Add the shortcut",
                 "Opens in Shortcuts with everything already set. One tap, then Add.")
            if let url = AppConfig.wallpaperShortcutURL {
                Link(destination: url) {
                    Label("Get the shortcut", systemImage: "square.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                }
                .padding(.leading, 26)
            }

            step(2, "Make it run every morning",
                 "Shortcuts → Automation → + → Time of Day → 07:00 → Run Immediately. Add the shortcut you just installed.")

            step(3, "Check your lock screen is a Photo",
                 "Not Photo Shuffle. Set Wallpaper Photo silently does nothing on Shuffle, and this is the most common reason it looks broken.")

            Button {
                if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) }
            } label: {
                Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.top, 2)

            Button {
                UIPasteboard.general.string = Self.plainSteps
            } label: {
                Label("Copy these steps", systemImage: "doc.on.doc")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 18, height: 18)
                .background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: health

    private enum Health {
        case never
        case working
        case stalled(String)
    }

    /// Thirty-six hours rather than twenty-four: a daily automation that
    /// fires at 07:00 has not failed at 07:05 the next morning, and a
    /// warning that cries wolf once is never read again.
    private var health: Health {
        guard let lastRun else { return .never }
        if Date().timeIntervalSince(lastRun) < 36 * 60 * 60 { return .working }
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return .stalled(f.string(from: lastRun))
    }

    private var stamp: String {
        guard let lastRun else { return "never" }
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        let time = f.string(from: lastRun)
        return Calendar.current.isDateInToday(lastRun) ? "\(time) today" : "\(time), \(dayName(lastRun))"
    }

    private func dayName(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: d)
    }

    private static let plainSteps = """
    my.adhd — lock screen setup

    1. Add the my.adhd wallpaper shortcut.
    2. Shortcuts → Automation → + → Time of Day → 07:00 → Run Immediately.
       Add: Update my.adhd wallpaper, then Set Wallpaper Photo.
       In Set Wallpaper Photo, turn off Show Preview and Crop to Subject,
       and untick Home Screen so only the lock screen changes.
    3. Make sure your current lock screen is a Photo, not Photo Shuffle.
    """
}
