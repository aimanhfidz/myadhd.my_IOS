/* ============================================================
   MyADHD/UI/ScreenHeader.swift — the section's own name

   reference/BridgeScript.swift:125-147, 492-497, 515-529.

   A website says its name at the top of every page, because a browser tab
   does not. An installed app already says it on the icon you tapped and in
   the switcher — so the wordmark is the one thing in that bar carrying no
   information, in the place with the least room for it. The section's name
   goes there instead, which is what a native app does.

   The old shell did this by injection: it hid `.brand-lockup` and put an
   `h1.myadhd-native-title` in the place the lockup had, on the four tab
   screens and on no others. Settings, Profile and Feedback already have a
   back button and a title of their own and are still left alone.

   The four words are `Copy.ScreenTitle`, which the port wrote down at the
   cutover and nothing has used until now.

   **The trailing slot is what used to sit alone at the top right.** Home's
   gear and theme toggle, the calendar's four-way pill, the lists' `?` and
   the List/Matrix capsule. Notes asks for no trailing content at all, which
   is what the second `init` is for.
   ============================================================ */

import SwiftUI

struct ScreenHeader<Trailing: View>: View {

    @Environment(\.theme) private var theme

    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        /* `font-size: clamp(26px, 7.5vw, 33px)`. The screen's width rather
           than a `GeometryReader`'s, because a reader here would claim the
           whole column — `HomeScreen` reads the same value for its gutter. */
        let size = min(33, max(26, UIScreen.main.bounds.width * 0.075))

        return HStack(spacing: 10) {
            Text(title)
                .font(Font.baloo(size, .heavy))
                .kerning(-0.03 * size)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 10)

            trailing()
        }
        /* The top and bottom are the header's own, not each screen's, so
           the title does not jump by a few points as you move between the
           four tabs. */
        .padding(.top, 10)
        /* The top and bottom are the header's own, not each screen's, so
           the title does not jump by a few points as you move between the
           four tabs. */
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: Theme.measure)
        .frame(maxWidth: .infinity)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    /// A title and nothing beside it.
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}
