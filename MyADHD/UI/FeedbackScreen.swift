/* ============================================================
   MyADHD/UI/FeedbackScreen.swift — the box, and one a day

   `paintFeedback` / `sendFeedback` (app.js:2658-2724),
   `showFeedbackScreen` (app.js:4097-4100), `#screen-feedback`
   (app.html:893-968), inventory §1.15.

   **Two shapes, chosen by one fact.** `sentFeedbackOn === utcDay()` —
   the box, or the thanks card. Nothing in between: an empty box with a
   dead button would be a worse answer than being told the door opens
   again tomorrow.

   **The day is UTC.** `AppStore.markFeedbackSent()` stamps
   `WebDates.utcDay()` and `AppStore.feedbackSpentToday` reads it back
   the same way. It is the one date in the whole app that is not local,
   and it is not an oversight: the server's own one-a-day counts UTC
   days, so a local day would disagree with it — and would hand anybody
   east of UTC a second go every evening (app.js:2650-2656).

   **A 429 counts as a send.** The device is spent either way; only the
   sentence changes. See `FeedbackClient`.

   **No tin.** `MYADHD_DONATE_URL` is forced empty in the shell, so the
   two donate blocks have never drawn on iOS, and design §4 decision 4
   settles it for the native build as well: nothing here is bought,
   nothing is unlocked, and App Store 3.1.1 has opinions about the
   difference.

   **The counter counts the TRIMMED length and the cap does not.**
   `${el.fbInput.value.trim().length} / 2000` against
   `maxlength="2000"` on the raw value — so a box full of trailing
   newlines reads as fewer characters than it will accept. That is
   app.js:2673 and app.html:918, and the two really are measured
   differently.
   ============================================================ */

import SwiftUI

struct FeedbackScreen: View {

    @Environment(\.theme) private var theme

    let store: AppStore
    let themeStore: ThemeStore
    let toasts: ToastCenter

    /// `#btn-feedback-back` — back to settings.
    var onClose: () -> Void

    var client = FeedbackClient()

    /// `#fb-input`.
    @State private var text = ""
    @FocusState private var boxFocused: Bool

    /// `el.fbSend.disabled` while the request is out, and the label that
    /// goes with it.
    @State private var sending = false

    /// `#fb-thanks-text`. app.html ships the 2xx sentence in the markup
    /// and `sendFeedback` only ever overwrites it, so arriving on a day
    /// already spent shows this one — which is the truth: the one for
    /// today has gone.
    @State private var thanks = Copy.Feedback.thanksToday

    /// `feedbackSentToday()`.
    private var spent: Bool { store.feedbackSpentToday }

    /// `.trim().length`, counted in UTF-16 units the way JavaScript
    /// counts a string's length.
    private var trimmed: String { JSText.trim(text) }
    private var trimmedLength: Int { trimmed.utf16.count }

    var body: some View {
        VStack(spacing: 0) {
            SettingsBar(themeStore: themeStore,
                        backLabel: Copy.Feedback.back,
                        backAria: Copy.Feedback.backAria,
                        title: Copy.Feedback.title,
                        onBack: onClose)

            ScrollView {
                VStack(spacing: 0) {
                    glyph
                    heading
                    lede
                    if spent { thanksCard } else { form }
                }
                .frame(maxWidth: Theme.measure)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)      // .settings-wrap--fb
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, Theme.gutter(UIScreen.main.bounds.width))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.surface.ignoresSafeArea())
        .toastLayer(toasts, hasTabBar: false)
    }

    // MARK: - the top, which both shapes share

    /// `.fb-glyph` — a 60pt washed square with the heart in it.
    private var glyph: some View {
        Image(systemName: "heart")
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(theme.accent)
            .frame(width: 60, height: 60)
            .background(theme.wash,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1.5)
            )
            .accessibilityHidden(true)
            .padding(.bottom, 18)
    }

    private var heading: some View {
        Text(Copy.Feedback.heading)
            .font(Font.baloo(28, .heavy))
            .kerning(-0.03 * 28)
            .foregroundStyle(theme.ink)
            .multilineTextAlignment(.center)
            .padding(.bottom, 12)
    }

    private var lede: some View {
        Text(Copy.Feedback.lede)
            .font(.system(size: 15))
            .lineSpacing(15 * 0.6)
            .foregroundStyle(theme.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            .padding(.bottom, 26)
    }

    // MARK: - the box

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Copy.Feedback.label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.muted)
                .padding(.bottom, 8)

            box

            HStack(spacing: 12) {
                Text(Copy.Feedback.counter(trimmedLength))
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(theme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)

                sendButton
            }
            .padding(.top, 14)

            note
        }
    }

    /// `#fb-input`: five rows to start with, 2000 characters at most, and
    /// the cap applied to the raw value rather than the trimmed one.
    private var box: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(Copy.Feedback.placeholder)
                    .font(Font.baloo(16))
                    .foregroundStyle(theme.faint)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 23)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(Font.baloo(16))
                .foregroundStyle(theme.ink)
                .lineSpacing(16 * 0.55)
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled(true)
                .focused($boxFocused)
                .frame(minHeight: 130)
                .padding(.horizontal, 12)
                .padding(.vertical, 15)
                .onChange(of: text) { _, next in
                    // `maxlength` counts UTF-16 units, like every other
                    // cap in this app.
                    let capped = Normalize.slice(next, Copy.Feedback.max)
                    if capped != next { text = capped }
                }
        }
        .background(theme.wash)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
                .strokeBorder(boxFocused ? theme.accent : theme.line, lineWidth: 1.5)
        )
        .animation(Theme.ease(0.18), value: boxFocused)
    }

    /// `.btn-primary.fb-send`. Dead under four characters, which is the
    /// same test `sendFeedback` opens with.
    private var sendButton: some View {
        Button { Task { await send() } } label: {
            Text(sending ? Copy.Feedback.sending : Copy.Feedback.send)
                .font(Font.baloo(16.5, .bold))
                .kerning(-0.01 * 16.5)
                .foregroundStyle(Color(hex: 0xFFFFFF))
                .padding(.horizontal, 26)
                .padding(.vertical, 17)
                .background(theme.brandGradient, in: Capsule())
                .shadow(color: Color(hex: 0x4737FF, opacity: 0.55), radius: 17, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(sending || trimmedLength < Copy.Feedback.minimum)
        .opacity(sending || trimmedLength < Copy.Feedback.minimum ? 0.4 : 1)
        .animation(Theme.ease(0.18), value: trimmedLength < Copy.Feedback.minimum)
    }

    /// `.fb-note` — `One a day.` in the ink, and the reason for it after.
    private var note: some View {
        (Text(Copy.Feedback.noteStrong)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(theme.ink)
         + Text(Copy.Feedback.noteRest)
            .font(.system(size: 13))
            .foregroundColor(theme.faint))
            .lineSpacing(13 * 0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .overlay(alignment: .top) {
                Rectangle().fill(theme.line).frame(height: 1.5)
            }
            .padding(.top, 20)
    }

    // MARK: - the other shape

    /// `#fb-thanks`. No tin under it — see the header.
    private var thanksCard: some View {
        VStack(spacing: 8) {
            Text(Copy.Feedback.thanksTitle)
                .font(Font.baloo(20, .heavy))
                .kerning(-0.02 * 20)
                .foregroundStyle(theme.ink)

            Text(thanks)
                .font(.system(size: 14.5))
                .lineSpacing(14.5 * 0.6)
                .foregroundStyle(theme.muted)
                .frame(maxWidth: 300)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    // MARK: - sending it

    /// `sendFeedback` (app.js:2679-2724), in its order: the length guard,
    /// the disabled button, the request, and a `finally` that puts the
    /// label back whatever happened.
    private func send() async {
        let body = trimmed
        guard body.utf16.count >= Copy.Feedback.minimum else {
            boxFocused = true
            return
        }

        sending = true
        defer { sending = false }

        do {
            let outcome = try await client.send(body)
            /* Both branches spend the day. A 429 means the server
               already has one from here, which is the same fact as
               having sent one. */
            store.markFeedbackSent()
            text = ""
            thanks = outcome == .alreadyToday
                ? Copy.Feedback.thanksAlready
                : Copy.Feedback.thanksToday
        } catch let err as FeedbackError {
            toasts.show(Copy.Feedback.failed(err.message))
        } catch {
            /* Nothing else throws out of `FeedbackClient`, but a `catch`
               that can be reached and says nothing is worse than one
               line of the same copy. */
            toasts.show(Copy.Feedback.failed(Copy.Feedback.broke))
        }
    }
}
