/* ============================================================
   MyADHD/UI/AccountCard.swift — the one card that says what is happening

   `#acct-card` (app.html:714-753), `paintAccount` (app.js:3595-3673),
   `acctAction` / `syncEverything` (3697-3749), `signOutHere` (3745-3751)
   and the three-stage delete (3766-3826). `.gcal-card` / `.acct-card`
   (styles.css:1913-1981).

   Signing in is optional and stays optional: the app opened on the dump
   box before anybody got here and works with no account at all. So the
   card says what an account buys rather than asking for trust up front,
   and it is quieter than the calendar card below it until it is actually
   signed in.

   **The hint line is the sync's only report**, which is why it is not
   decoration. A list quietly not travelling is the exact bug cloud.js was
   written to end, and a device that has not checked in for a while is —
   from the outside — indistinguishable from a device whose lists are
   simply up to date. So: it says the reassuring thing almost always,
   because almost always that is the true thing, and it says plainly when
   a pass is failing.

   **One button, two jobs.** Signed out it starts the sign-in; signed in it
   becomes `Sync now` and forces everything through. Two buttons with the
   same word on them, one above the other, is a question nobody should
   have to answer to press either.

   **`Sync now` bypasses the reachability gate** — `CloudSync.now()` never
   reads the path monitor. A VPN or a captive portal that reports
   satisfied while nothing works must not be able to make this button do
   nothing quietly (design §2.8).

   **Signing out leaves the lists alone.** `signOutHere` clears the
   session and resets the sync's phase; it does not touch a task. Neither
   does deleting the account: what goes is the copy that lets the devices
   meet.

   ---- the calendar half ----

   Three branches of this card are about Google Calendar, which is a later
   phase (design §3.6). They are written the way the page writes them —
   `window.gcal && gcal.connected()`, which is false when the file is not
   there — so `calendar` is nil until `GCalSync` exists and every one of
   those branches reads exactly as it does in a browser with no calendar
   link. Nothing here is a placeholder for it; when the phase lands it
   passes a value in and the branches wake up.
   ============================================================ */

import SwiftUI

/// What this card needs to know about the Google Calendar push, and
/// nothing else. `state` is `syncState` (app.js:3447-3568): `idle`,
/// `working`, `error` or `stale`.
struct AccountCalendar {
    var connected: Bool
    var state: String
    var syncNow: () async -> Void

    init(connected: Bool, state: String, syncNow: @escaping () async -> Void) {
        self.connected = connected
        self.state = state
        self.syncNow = syncNow
    }
}

struct AccountCard: View {

    @Environment(\.theme) private var theme

    let store: AppStore
    let session: Session
    let auth: AuthFlow
    let cloud: CloudSync
    let toasts: ToastCenter
    /// nil until the calendar phase exists — see the file header.
    var calendar: AccountCalendar?

    /// `el.acctBtn.disabled = true; textContent = 'Taking you to Google…'`
    /// (app.js:3699-3700). Session-lived and deliberately not on the
    /// store: it describes one press.
    @State private var going = false

    /// 0 = the quiet button, 1 = the first ask, 2 = the last check,
    /// 3 = deleting.
    @State private var deleteStage = 0
    @State private var disarm: Task<Void, Never>?

    // MARK: -

    private var user: SessionUser? { session.user }

    /// `cloud.state() === 'working'`, or the calendar's.
    private var busy: Bool {
        cloud.phase == .working || calendar?.state == "working"
    }

    /// `.is-stale` on the card, which turns the edge orange.
    private var stale: Bool { cloud.phase == .error }

    var body: some View {
        /* `if (!window.auth || !auth.configured()) { hide }` — with no
           Supabase project there is nothing to sign in to, and a card
           offering it would be a button that cannot work. */
        if session.configured {
            VStack(alignment: .leading, spacing: 0) {
                head
                note
                button
                more
                if user != nil { danger }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 18)
            .background(user != nil ? theme.wash : theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(edge, lineWidth: 1.5)
            )
            .background(stale ? theme.dangerWash : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .padding(.top, 18)
            .animation(Theme.ease(0.22), value: user?.id)
            .onChange(of: user?.id) { _, id in
                /* Signed out there is no account to end, and a confirm box
                   left armed from before would be asking about something
                   that is already gone (app.js:3606). */
                if id == nil { resetDelete() }
                going = false
            }
            .onDisappear { disarm?.cancel() }
        }
    }

    private var edge: Color {
        if stale { return theme.orange }
        return user != nil ? theme.lineStrong : theme.line
    }

    // MARK: - `.gcal-head`

    private var head: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(user != nil ? Copy.Account.inFace : Copy.Account.face)
                .font(.system(size: 17))
                .foregroundStyle(stale ? theme.orange : theme.accent)
                .frame(width: 34, height: 34)
                .background(user != nil ? theme.surface : theme.wash)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(stale ? theme.orange : theme.lineStrong, lineWidth: 1.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Font.baloo(15.5, .bold))
                    .kerning(-0.015 * 15.5)
                    .foregroundStyle(theme.ink)

                Text(state)
                    .font(Font.baloo(12.5, .semibold))
                    .foregroundStyle(stateInk)
            }
            Spacer(minLength: 0)
        }
    }

    /// `user.name || 'Signed in'` (app.js:3626).
    private var title: String {
        guard let user else { return Copy.Account.outTitle }
        if let name = user.name, !name.isEmpty { return name }
        return Copy.Account.inTitle
    }

    /// The email, or nothing (app.js:3627).
    private var state: String {
        guard let user else { return Copy.Account.outState }
        return user.email ?? ""
    }

    private var stateInk: Color {
        if stale { return theme.orange }
        return user != nil ? theme.accent : theme.faint
    }

    // MARK: - `.gcal-note`

    private var note: some View {
        Text(noteText)
            .font(Font.baloo(13.5))
            .lineSpacing(13.5 * 0.5)
            .foregroundStyle(theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
    }

    private var noteText: String {
        guard user != nil else { return Copy.Account.outNote }
        /* `window.gcal && gcal.connected() && syncState !== 'stale'`. */
        let both = (calendar?.connected == true) && calendar?.state != "stale"
        return Copy.Account.inNote(pushesBoth: both)
    }

    // MARK: - `.gcal-go`

    private var button: some View {
        Button {
            Task { await press() }
        } label: {
            Text(buttonLabel)
                .font(Font.baloo(15, .bold))
                .foregroundStyle(theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .padding(.horizontal, 20)
                .background(theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(buttonDisabled)
        .opacity(buttonDisabled ? 0.45 : 1)
        .padding(.top, 16)
    }

    private var buttonLabel: String {
        guard user != nil else {
            return going ? Copy.Account.takingYou : Copy.Account.signIn
        }
        return busy ? Copy.Account.syncing : Copy.Account.syncNow
    }

    private var buttonDisabled: Bool {
        user != nil ? busy : going
    }

    // MARK: - `.gcal-more`

    private var more: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(hint)
                .font(Font.baloo(12.5))
                .foregroundStyle(theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)

            if user != nil {
                Button {
                    Task { await signOutHere() }
                } label: {
                    Text(Copy.Account.signOut)
                        .font(Font.baloo(13.5, .semibold))
                        .foregroundStyle(theme.faint)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 12)
    }

    /// app.js:3663-3671. Signed out the line is empty, and the row
    /// collapses (`.gcal-more:empty{display:none}`).
    private var hint: String {
        guard user != nil else { return "" }
        switch cloud.phase {
        case .working: return Copy.Account.bringingUpToDate
        case .error:   return Copy.Account.notTravelling(cloud.error)
        case .idle:    return Copy.Account.signingOutIsSafe
        }
    }

    // MARK: - `.acct-danger` (app.html:740-752)

    private var danger: some View {
        VStack(alignment: .leading, spacing: 0) {
            theme.line.frame(height: 1.5)
                .padding(.bottom, 14)

            if deleteStage == 0 {
                Button {
                    stepDelete()
                } label: {
                    Text(Copy.Account.delete)
                        .font(Font.baloo(13.5, .semibold))
                        .foregroundStyle(theme.faint)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                deleteConfirm
            }
        }
        .padding(.top, 16)
    }

    /// The same two-stage shape as `Clear everything` on the lists screen,
    /// because it is the same kind of moment and the app should not keep
    /// two vocabularies for "are you sure". What differs is the stake, and
    /// the copy carries it.
    private var deleteConfirm: some View {
        let final = deleteStage >= 2

        return VStack(alignment: .leading, spacing: 0) {
            Text(final ? Copy.Account.lastAsk : Copy.Account.firstAsk)
                .font(Font.baloo(14, .medium))
                .lineSpacing(14 * 0.55)
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 13)

            HStack(spacing: 9) {
                Button {
                    resetDelete()
                } label: {
                    Text(Copy.Account.cancel)
                        .font(Font.baloo(14, .medium))
                        .foregroundStyle(theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(theme.lineStrong, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(deleteStage >= 3)

                Button {
                    stepDelete()
                } label: {
                    Text(deleteGoLabel)
                        .font(Font.baloo(14, .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(theme.danger, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(deleteStage >= 3)
                .opacity(deleteStage >= 3 ? 0.45 : 1)
            }
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 17)
        .background(final ? theme.dangerWash : theme.wash)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(final ? theme.dangerEdge : theme.lineStrong, lineWidth: 1.5)
        )
        .overlay(alignment: .leading) { theme.dangerInk.frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.top, 12)
        .transition(.opacity.combined(with: .offset(y: 10)))
    }

    private var deleteGoLabel: String {
        switch deleteStage {
        case 1:  return Copy.Account.firstGo
        case 2:  return Copy.Account.lastGo
        default: return Copy.Account.deleting
        }
    }

    // MARK: - One button, two jobs (app.js:3697-3703)

    private func press() async {
        guard user == nil else {
            await syncEverything()
            return
        }
        going = true
        let arrived = await auth.signIn()
        going = false
        /* `wakeAccount`'s half, at the moment the tokens land rather than
           at the next boot (app.js:3862-3872). A pass runs whether the
           session is new or not — this is the first moment there is one,
           so it is the first moment the lists can be merged with the
           other devices'. Not `soon()`: the person is looking at the
           card. */
        if arrived {
            toasts.show(Copy.Account.signedIn)
            await cloud.now()
        }
    }

    /// app.js:3716-3749. Everything this screen can push, in one press.
    ///
    /// The lists go first and the calendar second, and that order is the
    /// whole reason this is one button rather than two run at the same
    /// time: a pass can bring a dated task down from the other device, and
    /// doing Google second means that task reaches the calendar in the
    /// same press rather than waiting for the next one.
    ///
    /// The card already draws what both halves are doing, so the only
    /// thing to add is the answer at the end — a pass that finds nothing
    /// looks exactly like a pass that never ran, and being told is the
    /// entire reason to press it.
    private func syncEverything() async {
        let before = store.doc.tasks.count
        let linked = calendar?.connected == true

        await cloud.now()

        let listsBroke = cloud.phase == .error
        if linked, !listsBroke { await calendar?.syncNow() }

        if listsBroke {
            toasts.show(Copy.Account.listsUnreachable)
            return
        }
        if linked, calendar?.state == "error" {
            toasts.show(Copy.Account.googleSilent)
            return
        }
        if linked, calendar?.state == "stale" {
            toasts.show(Copy.Account.googleStale)
            return
        }

        let added = store.doc.tasks.count - before
        toasts.show(added > 0 ? Copy.Account.cameOver(added)
                    : added < 0 ? Copy.Account.otherDeviceRemoved
                    : Copy.Account.alreadyUpToDate)
    }

    /// app.js:3745-3751. **The local tasks are untouched.**
    private func signOutHere() async {
        await auth.signOut()
        cloud.forget()
        toasts.show(Copy.Account.signedOut)
    }

    // MARK: - Ending the account (app.js:3777-3826)

    private func stepDelete() {
        let next = deleteStage + 1
        guard next >= 3 else {
            withAnimation(Theme.ease(0.22)) { deleteStage = next }
            arm()
            return
        }

        disarm?.cancel()
        withAnimation(Theme.ease(0.22)) { deleteStage = 3 }

        Task { @MainActor in
            do {
                try await auth.deleteAccount()
            } catch {
                /* Back to the last armed step rather than all the way out.
                   The answer to a delete that failed is usually to press
                   it again, and making somebody walk both stages a second
                   time reads as though the app were arguing with them. */
                withAnimation(Theme.ease(0.22)) { deleteStage = 2 }
                arm()
                toasts.show(Copy.Account.deleteFailed)
                return
            }
            cloud.forget()
            resetDelete()
            toasts.show(Copy.Account.deleted)
        }
    }

    /// Don't leave it armed.
    private func arm() {
        disarm?.cancel()
        disarm = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Copy.Account.disarmAfter * 1_000_000_000))
            guard !Task.isCancelled else { return }
            resetDelete()
        }
    }

    private func resetDelete() {
        disarm?.cancel()
        disarm = nil
        guard deleteStage != 0 else { return }
        withAnimation(Theme.ease(0.22)) { deleteStage = 0 }
    }
}
