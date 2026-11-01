/* ============================================================
   MyADHD/UI/GoogleCalendarCard.swift — `#gcal-card`

   app.html:1016-1041, `paintGoogle` (app.js:3755-3842), `connectGoogle`
   and `disconnectGoogle` (3709-3753). The same shape as `AccountCard`,
   because on the web they are the same `.gcal-card`.

   **The button follows the web's merged rule.** Signed in, the account
   card's `Sync now` already pushes the calendar too, so this card shows a
   button only for what that one cannot do: linking, and reconnecting.
   This app has no calendar without an account, so linked here always
   means signed in, and `Sync now` never shows on this card.

   No duplicate-calendar block: that cleanup is offered on the web, which
   is where the duplicates were made.
   ============================================================ */

import SwiftUI

struct GoogleCalendarCard: View {

    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    let store: AppStore
    let session: Session
    let calendar: CalendarSync
    let toasts: ToastCenter
    /// The same sign-in the account card starts. True when it landed.
    let signIn: () async -> Bool

    @State private var opening = false

    private var on: Bool { calendar.connected }
    private var stale: Bool { on && calendar.phase == .stale }

    var body: some View {
        if session.configured {
            VStack(alignment: .leading, spacing: 0) {
                head
                note
                if showButton { button }
                if on { more }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 18)
            .background(stale ? theme.dangerWash : theme.wash)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
                    .strokeBorder(theme.orange, lineWidth: 1.5)
                    .opacity(stale ? 1 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
        }
    }

    // MARK: - `.gcal-head`

    private var head: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "calendar")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(stale ? theme.orange : theme.accent)
                .frame(width: 34, height: 34)
                .background(on ? theme.surface : theme.wash)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(stale ? theme.orange : theme.lineStrong, lineWidth: 1.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(Copy.GoogleCalendar.title)
                    .font(Font.baloo(15.5, .bold))
                    .kerning(-0.015 * 15.5)
                    .foregroundStyle(theme.ink)

                Text(stateText)
                    .font(Font.baloo(12.5, .semibold))
                    .foregroundStyle(stale ? theme.orange : (on ? theme.accent : theme.faint))
            }
            Spacer(minLength: 0)
        }
    }

    private var stateText: String {
        guard on else { return Copy.GoogleCalendar.notLinked }
        switch calendar.phase {
        case .working: return Copy.GoogleCalendar.syncing
        case .stale:   return Copy.GoogleCalendar.stale
        case .error:   return Copy.GoogleCalendar.paused
        case .idle:    return Copy.GoogleCalendar.linked
        }
    }

    // MARK: - `.gcal-note`

    private var note: some View {
        Text(noteText)
            .font(Font.baloo(13.5))
            .lineSpacing(13.5 * 0.5)
            .foregroundStyle(theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
    }

    private var noteText: String {
        guard on else { return Copy.GoogleCalendar.offNote }
        switch calendar.phase {
        case .stale:
            return Copy.GoogleCalendar.staleNote
        case .error:
            if let why = calendar.lastError { return Copy.GoogleCalendar.errorNote(why) }
            return Copy.GoogleCalendar.errorNoteBare
        case .idle, .working:
            let dated = CalendarPush.dated(store.doc.tasks)
            return dated == 0 ? Copy.GoogleCalendar.nothingDated : Copy.GoogleCalendar.dated(dated)
        }
    }

    // MARK: - `.gcal-go`

    private var showButton: Bool { !on || stale }

    private var button: some View {
        Button {
            Task { await press() }
        } label: {
            Text(opening ? Copy.GoogleCalendar.opening
                 : (stale ? Copy.GoogleCalendar.reconnect : Copy.GoogleCalendar.link))
                .font(Font.baloo(15, .bold))
                .foregroundStyle(theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .padding(.horizontal, 20)
                .background(theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(opening || calendar.phase == .working)
        .opacity(opening ? 0.45 : 1)
        .padding(.top, 16)
    }

    // MARK: - `.gcal-more`

    private var more: some View {
        HStack(spacing: 10) {
            Button {
                if let url = URL(string: Copy.GoogleCalendar.openURL) { openURL(url) }
            } label: {
                Text(Copy.GoogleCalendar.open)
                    .font(Font.baloo(13.5, .semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 16)
                    .background(theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(theme.lineStrong, lineWidth: 1.5))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                calendar.switchOff()
                toasts.show(Copy.GoogleCalendar.unlinkedToast)
            } label: {
                Text(Copy.GoogleCalendar.unlink)
                    .font(Font.baloo(13.5, .semibold))
                    .foregroundStyle(theme.faint)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 14)
    }

    // MARK: - `connectGoogle` (app.js:3709-3738)

    /// Link or Reconnect. A device switched off here with the account
    /// still linked only needs switching back on; everything else needs
    /// Google's consent screen, which is a sign-in.
    private func press() async {
        opening = true
        defer { opening = false }

        let needsGoogle = !session.signedIn || stale || calendar.link == .notLinked
        if needsGoogle {
            /* A cancelled sign-in leaves everything as it was, including
               an Unlink this device chose earlier. */
            guard await signIn() else {
                toasts.show(Copy.GoogleCalendar.nothingLinked)
                return
            }
        }
        calendar.switchOn()

        await calendar.now()
        /* Only a clean answer earns "Linked". An error or a stale grant is
           already on the card in its own words; a toast saying the
           opposite would be the one place the screen lied. */
        if calendar.connected, calendar.phase == .idle {
            toasts.show(Copy.GoogleCalendar.linkedToast)
        } else if !calendar.connected {
            toasts.show(Copy.GoogleCalendar.nothingLinked)
        }
    }
}
