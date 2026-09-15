/* ============================================================
   my.adhd for iOS — what the wallpaper actually shows

   Deliberately almost empty. iOS owns the top of a lock screen and the
   bottom of it, and the one thing worth putting in the middle is the next
   thing to do — not a list, which is what caused the freeze in the first
   place.

   Kept apart from Wallpaper.swift, and kept free of UIKit, for two
   reasons: the setup sheet shows it live as a preview, and a pure SwiftUI
   view can be rendered off-device to check the layout without a phone.
   ============================================================ */

import SwiftUI

struct WallpaperView: View {
    let snapshot: TaskSnapshot
    var dark: Bool = true

    /* The regions iOS draws over, as fractions of the height:
         0.00 – 0.30   the date line and the big clock
         0.30 – 0.38   the lock-screen widget row, when there is one
         0.78 – 1.00   torch, camera, and the home indicator
       So everything here lives between 0.38 and 0.78, and nothing at all
       goes above 0.30. */
    private let top = 0.38
    private let bottom = 0.78

    private var task: SnapTask? { snapshot.next }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height

            ZStack(alignment: .topLeading) {
                ground

                VStack(alignment: .leading, spacing: 0) {
                    rule
                    content
                        .padding(.vertical, 22)
                    rule
                }
                .padding(.horizontal, 34)
                .frame(width: geo.size.width, height: h * (bottom - top), alignment: .center)
                .offset(y: h * top)
            }
        }
        .ignoresSafeArea()
    }

    private var ground: some View {
        LinearGradient(
            colors: dark
                ? [Color(red: 16 / 255, green: 16 / 255, blue: 24 / 255),
                   Color(red: 26 / 255, green: 24 / 255, blue: 46 / 255)]
                : [Color(red: 233 / 255, green: 231 / 255, blue: 251 / 255),
                   Color(red: 209 / 255, green: 205 / 255, blue: 255 / 255)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var rule: some View {
        Rectangle()
            .fill(ink.opacity(0.18))
            .frame(height: 1)
    }

    @ViewBuilder
    private var content: some View {
        if let task {
            VStack(alignment: .leading, spacing: 0) {
                Text("NEXT")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(ink.opacity(0.5))

                Text(task.title)
                    .font(baloo(27, weight: .bold))
                    .foregroundStyle(ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                if let step = task.firstStep {
                    Text("START HERE — 2 MIN")
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(accent)
                        .padding(.top, 22)

                    Text(step)
                        .font(.system(size: 16.5, weight: .regular))
                        .foregroundStyle(ink.opacity(0.85))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }

                if behind > 0 {
                    Text(behind == 1 ? "1 more behind it" : "\(behind) more behind it")
                        .font(.system(size: 13))
                        .foregroundStyle(ink.opacity(0.42))
                        .padding(.top, 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("HEAD'S CLEAR")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(ink.opacity(0.5))
                Text("Nothing left in the queue.")
                    .font(baloo(24, weight: .bold))
                    .foregroundStyle(ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var behind: Int {
        max(0, snapshot.tasks.filter { !$0.done }.count - 1)
    }

    private var ink: Color {
        dark ? Color(red: 243 / 255, green: 242 / 255, blue: 251 / 255)
             : Color(red: 16 / 255, green: 16 / 255, blue: 24 / 255)
    }

    /// Vivid Orange is the app's "start here", and this is the one place
    /// on the picture that says start here.
    private var accent: Color { CategoryTint.urgent }

    /// Font.custom falls back to the system face on its own when the
    /// bundled file is missing, so this needs no UIFont lookup — and
    /// without one the whole view compiles anywhere SwiftUI does.
    private func baloo(_ size: CGFloat, weight: Font.Weight) -> Font {
        .custom("Baloo2-Regular", size: size).weight(weight)
    }
}
