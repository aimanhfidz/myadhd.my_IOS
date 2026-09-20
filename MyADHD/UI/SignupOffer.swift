/* ============================================================
   MyADHD/UI/SignupOffer.swift — the offer, and it waits its turn

   app.html:349-357, `paintSignupOffer` (app.js:3580-3591, 5556-5567),
   `.signup-offer` (styles.css).

   It appears after a list exists, never before. Asking someone to sign in
   before the app has done anything for them is asking for trust on credit;
   by here they have watched it work, so the offer can be about keeping
   what they can already see.

   **Four conditions, all of them.** `auth.configured()` (there is a
   Supabase project to sign into at all), `!auth.signedIn()`, the store's
   `signupOfferHidden !== true`, and at least one open task. Dismissed
   once, gone for good — `signupOfferHidden` is on the document and syncs
   with everything else, so turning it down on the phone turns it down on
   the laptop too.

   **Where the first two come from.** There is no account layer in this
   build (design §3.5), so whether an account is on offer is asked of the
   caller rather than assumed here, and it defaults to *no*. A screen that
   invented an answer would be a sign-in button that cannot sign anybody
   in.
   ============================================================ */

import SwiftUI

struct SignupOffer: View {

    @Environment(\.theme) private var theme

    let store: AppStore
    /// `auth.configured() && !auth.signedIn()`.
    let isOffered: Bool
    /// `#signup-yes` → `auth.signIn()`.
    let onSignIn: () -> Void

    /// `disabled`, and the label changes with it.
    @State private var going = false

    /* The one string on this card that is not in `Copy`: it is written
       straight onto the button by `paintSignupOffer` rather than through
       the copy table (app.js:5559), and the account card writes the same
       words again at 3700. */
    private static let goingLabel = "Taking you to Google…"   // app.js:5559

    private var isShown: Bool {
        isOffered
            && !store.doc.signupOfferHidden
            && store.doc.tasks.contains { !$0.done }
    }

    var body: some View {
        if isShown {
            VStack(alignment: .leading, spacing: 0) {
                Text(Copy.Signup.title)
                    .font(Font.baloo(16, .heavy))
                    .kerning(-0.02 * 16)
                    .foregroundStyle(theme.ink)
                    .padding(.trailing, 28)   // clear of the dismiss cross
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(Copy.Signup.body)
                    .font(Font.baloo(13.5))
                    .lineSpacing(13.5 * 0.55)
                    .foregroundStyle(theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)

                Button {
                    going = true
                    onSignIn()
                } label: {
                    Text(going ? Self.goingLabel : Copy.Signup.button)
                        .font(Font.baloo(15, .bold))
                        .foregroundStyle(theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .padding(.horizontal, 20)
                        .background(theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(going)
                .opacity(going ? 0.45 : 1)
                .padding(.top, 16)
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 18)
            .background(theme.wash)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(theme.lineStrong, lineWidth: 1.5)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    store.dismissSignupOffer()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.faint)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
                .padding(.trailing, 12)
                .accessibilityLabel(Copy.Signup.dismissAria)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .padding(.bottom, 18)
        }
    }
}
