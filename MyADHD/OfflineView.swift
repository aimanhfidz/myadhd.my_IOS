/* ============================================================
   my.adhd for iOS — the screen for a first launch with no signal

   Only ever shown when there is nothing else to show. Once the page has
   painted, a dropped connection costs only triage: the lists are in
   localStorage and the screen is already drawn. Covering a working app
   with an "offline" screen would be a lie.

   What this does NOT have is the web app's offline install. sw.js
   precaches the shell for Safari, but WKWebView runs service workers only
   for app-bound domains (WKAppBoundDomains in Info.plist), and this shell
   declares none — declaring them would cap the web view at ten domains
   and cut evaluateJavaScript off from any frame outside the list, which is
   the whole bridge. So a cold launch with no signal comes here, every
   time, and the copy below says so rather than promising an install that
   never happened. Turning app-bound domains on is a decision to take with
   the Google and Supabase frames in view, not a line to add.
   ============================================================ */

import SwiftUI

struct OfflineView: View {

    let retry: () -> Void

    private let violet = Color(AppConfig.accent)

    var body: some View {
        VStack(spacing: 14) {
            Text("No signal")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Text("Your lists are safe on this phone, but the app needs a connection to open.")
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
