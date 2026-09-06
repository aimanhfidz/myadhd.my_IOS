/* ============================================================
   my.adhd for iOS — the screen for a first launch with no signal

   Only ever shown when there is nothing else to show. Once the page has
   painted, a dropped connection is the service worker's problem and it
   already handles it: the shell is cached, the lists are in localStorage,
   and the only thing that actually needs the network is triage. Covering
   a working offline app with an "offline" screen would be a lie.
   ============================================================ */

import SwiftUI

struct OfflineView: View {

    let retry: () -> Void

    private let violet = Color(red: 123 / 255, green: 63 / 255, blue: 228 / 255)

    var body: some View {
        VStack(spacing: 14) {
            Text("No signal")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Text("The app needs one connection to install itself. After that it opens without one.")
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 36)

            Button(action: retry) {
                Text("Try again")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 13)
                    .background(violet, in: Capsule())
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
