/* ============================================================
   MyADHD/UI/AppShell.swift — the spine

   Everything else in MyADHD/UI/ is a screen that knows how to draw one
   thing from the store. This is the file that owns the store, decides
   which screen is up, and runs the one flow that crosses all of them:
   a dump goes in, triage happens, the lists come back.

   It replaces WebScreen. Where that file's job was to host a page and
   get out of its way, this one's job is the work the page used to do —
   `show()`, the tab bar's state, the composer's lifecycle, `triage()`,
   and the boot sequence at the bottom of app.js.

   The order at boot is not arbitrary and is app.js's own:

     1. the document is read (AppStore's init, which cannot fail — a
        corrupt file is quarantined and an empty store takes its place)
     2. the migration, but only on a first launch that has never run one
     3. pruneDone(), then stampTimeOnly() — that order, because pruning
        decides what is still here and stamping only touches what is
        (app.js:5667-5676) — and pruneBlankNotes() beside them, which is
        the same job for a note the editor never got to close
     4. StoreBridge starts, which pushes the widget snapshot and rebuilds
        the notification schedule off the bytes just read

   And on every return to the foreground, OpDrain runs BEFORE the bridge
   pushes, so a tick taken on a widget and the snapshot that reflects it
   land in one pass rather than two.
   ============================================================ */

import SwiftUI

@MainActor
struct AppShell: View {

    // MARK: - What the app is made of

    @State private var store = AppStore()
    @State private var themeStore = ThemeStore()
    @State private var toasts = ToastCenter()
    @State private var buffer = DumpBuffer()
    @State private var importer = LegacyImport()

    /// The account. `Session` is the Keychain record and can be built
    /// straight away; the other two need `store`, so they are made in
    /// `boot()` like the bridge. Signed out, all three are inert — the
    /// app works exactly the same, which is the point.
    @State private var session = Session()
    @State private var auth: AuthFlow?
    @State private var cloud: CloudSync?

    /// Not `@Observable`, and it cannot be built until `store` exists, so
    /// it is made once in `.task` rather than in a property initialiser.
    @State private var bridge: StoreBridge?

    private let triageClient = TriageClient()

    // MARK: - What is on screen

    @State private var tab: AppTab = .home
    @State private var composerUp = false
    @State private var settingsUp = false

    /// The loading screen. Named for what it is rather than for the
    /// screen, because the screen is the least of it: while this is true
    /// a dump is in flight and the composer must not reopen underneath it.
    @State private var sorting = false

    @State private var booted = false

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Drawing

    var body: some View {
        ZStack {
            themeStore.theme.backdrop.ignoresSafeArea()

            if case .holding = importer.phase {
                /* The one screen that is not the app. An empty read that
                   the witnesses contradict means somebody's lists are
                   still in WebKit storage and we have not got them yet —
                   so we say so and keep trying, rather than opening an
                   empty app and letting them think it is gone. */
                MigrationHold(retry: { importer.retry() })
            } else {
                shell
            }
        }
        .environment(\.theme, themeStore.theme)
        .preferredColorScheme(themeStore.colorScheme)
        .toastLayer(toasts)
        .task { await boot() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                returned()
                cloud?.sceneBecameActive()
            } else {
                cloud?.sceneResigned()
            }
        }
        /* Inbox posts this when a Shortcut, the share sheet or a
           myadhd:// link hands text in while the app is already up. A cold
           launch does not need it — `boot()` drains the same inbox. */
        .onReceive(NotificationCenter.default.publisher(for: .myadhdOpen)) { _ in
            takeInbox()
        }
    }

    private var shell: some View {
        ZStack {
            current
                /* The bar floats *over* the screen rather than sitting
                   under it, so the room it needs is an inset inside the
                   screen and not a frame beneath the bar — `body.has-tabbar
                   .screen { padding-bottom: 96px + safe-bottom }`. Every
                   tab screen already writes its own short bottom padding on
                   top of this and says so in a comment; without it those
                   numbers were measured against a reservation that was
                   never made, and the matrix's bottom row and the notes `+`
                   both ran under the glass. */
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: TabBar.reservedHeight)
                }
                .opacity(sorting ? 0 : 1)

            if sorting {
                LoadingScreen(dark: themeStore.isDark)
                    .transition(.opacity)
            }

            if !sorting {
                VStack {
                    Spacer()
                    TabBar(current: tab,
                           tasks: store.doc.tasks,
                           select: { go(to: $0) },
                           add: { openComposer() })
                }
                .ignoresSafeArea(.keyboard)
            }
        }
        .animation(.easeOut(duration: 0.18), value: sorting)
        .sheet(isPresented: $composerUp) {
            Composer(buffer: buffer,
                     store: store,
                     toasts: toasts,
                     isPresented: $composerUp,
                     send: { sortIt() })
        }
        .fullScreenCover(isPresented: $settingsUp) {
            SettingsScreen(store: store,
                           themeStore: themeStore,
                           toasts: toasts,
                           onClose: { settingsUp = false },
                           accountCard: accountCard,
                           isSignedIn: session.signedIn)
        }
    }

    /// `show()`. The lists tab is two screens behind one button — which
    /// one is the store's `view`, and the toggle inside the screen is
    /// what changes it (app.js:1272, 5071-5074).
    @ViewBuilder
    private var current: some View {
        switch tab {
        case .home:
            HomeScreen(store: store,
                       themeStore: themeStore,
                       openSettings: { settingsUp = true },
                       openComposer: { openComposer() },
                       goToLists: { go(to: .lists) })
        case .calendar:
            CalendarScreen(store: store, toasts: toasts)
        case .lists:
            if store.doc.view == "matrix" {
                MatrixScreen(store: store,
                             toasts: toasts,
                             openComposer: { openComposer() })
            } else {
                ListsScreen(store: store,
                            toasts: toasts,
                            onDumpAgain: { openComposer() })
            }
        case .notes:
            NotesScreen(store: store, toasts: toasts)
        }
    }

    // MARK: - Boot

    private func boot() async {
        guard !booted else { return }
        booted = true

        /* Before anything is drawn from the store, and before a single
           byte is written to it: if there is an old shell's localStorage
           in this container, it is the person's real data and it wins
           over the empty document AppStore booted with. */
        if importer.isNeeded(file: StoreFile()) {
            importer.run(into: store)
        }

        /* app.js:5667-5676. Pruning first, because it decides what is
           still in the store; stamping second, because it only writes to
           what survived. Both go through persistOnly — neither is a
           change the person made, so neither earns a cloud stamp. */
        _ = store.pruneDone()
        _ = store.stampTimeOnly()

        /* And the notes' half of the same job, which app.js has no
           equivalent of because a page that goes away still runs its
           handlers. `newNote()` writes a blank note before the editor
           opens over it; if the app died in between, `closeNote` never
           took it away and the index has an `Untitled` card in it. */
        _ = store.pruneBlankNotes()

        let wire = StoreBridge(store: store)
        wire.start()
        bridge = wire

        /* The account, last. `attach()` fills the two hooks AppStore left
           empty — the cloud stamp and the debounced pass — so from here a
           `save()` schedules a sync; `wakeAtLaunch()` is `dirty = true` at
           boot, which is what makes an offline week push the moment there
           is a network again. Signed out it all no-ops. */
        let flow = AuthFlow(session: session)
        let sync = CloudSync(store: store, session: session)
        sync.attach()
        sync.wakeAtLaunch()
        auth = flow
        cloud = sync

        takeInbox()
    }

    /// Coming back to the front. The drain goes first so that the ticks a
    /// person took on a widget are in the store before the bridge writes
    /// the snapshot that is supposed to reflect them.
    private func returned() {
        store.reloadIfChangedOnDisk()

        let landed = OpDrain.drain(into: store)
        if landed > 0 {
            /* markDone's own toast, once per tick, the way the web's
               drain produced one per op (README: "An Undo toast appears
               for something done an hour ago"). */
            toasts.show(Copy.TaskRow.done)
        }

        bridge?.flush()
        takeInbox()
    }

    /// Settings draws the card; the shell owns the objects behind it.
    /// Nil until `boot()` has run, which is the one frame where settings
    /// cannot be open anyway.
    private var accountCard: (() -> AnyView)? {
        guard let auth, let cloud else { return nil }
        return {
            AnyView(AccountCard(store: store,
                                session: session,
                                auth: auth,
                                cloud: cloud,
                                toasts: toasts))
        }
    }

    // MARK: - Text arriving from somewhere that is not the keyboard

    /// A Shortcut, the share sheet, or a `myadhd://dump?text=` link. The
    /// buffer's `deliver` is what asks for focus and clears any spoken
    /// marker, so this only has to decide whether to open the composer.
    private func takeInbox() {
        guard let text = Inbox.take(), !text.isEmpty else { return }
        buffer.deliver(text)
        openComposer()
    }

    // MARK: - The flows

    private func go(to next: AppTab) {
        tab = next
    }

    private func openComposer() {
        guard !sorting else { return }
        composerUp = true
    }

    /// `triage()`, app.js:559-634, in the same order and with the same
    /// three outcomes.
    ///
    /// The `catch` is not an error path, it is the offline path: the
    /// client throws on a dead network, a bad status and an empty answer
    /// alike, and all three mean the same thing here — sort it ourselves
    /// and say so. That is what makes the app work on a plane.
    private func sortIt() {
        let text = JSText.trim(buffer.text)

        /* Only reachable if the buffer was emptied between the composer
           closing and this running — the composer refuses to send an
           empty sheet. */
        guard !text.isEmpty else {
            toasts.show(Copy.Triage.nothingToSort)
            return
        }

        sorting = true
        let spoken = buffer.takeSpoken(vocab: KnownNames.from(tasks: store.doc.tasks))

        Task {
            var tasks: [TaskItem]
            var sortedOurselves = false

            do {
                tasks = try await triageClient.triage(text: text, spoken: spoken)
            } catch {
                tasks = LocalTriage.parseLocally(text)
                sortedOurselves = true
            }

            sorting = false

            if sortedOurselves { toasts.show(Copy.Triage.offline) }

            guard !tasks.isEmpty else {
                tab = .home
                toasts.show(Copy.Triage.nothingFound)
                return
            }

            let result = store.applyTriage(tasks)
            buffer.write("")
            tab = .lists

            if let line = Copy.Triage.result(added: result.added, dupes: result.dupes) {
                toasts.show(line)
            }
        }
    }
}

// MARK: - The hold

/* Deliberately plain, and deliberately not the app. Someone seeing this
   has lists that exist and are not on screen yet; a screen that looked
   like the app with nothing in it would say the opposite. */
private struct MigrationHold: View {

    @Environment(\.theme) private var theme
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)

            Text(LegacyImport.holdCopy)
                .font(.baloo(17, .semibold))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)

            Button(action: retry) {
                /* Native-only: the web app has no migration and so has
                   no sentence for one. This is the word OfflineView used
                   for the same job, kept so the app says it one way. */
                Text("Try again")
                    .font(.baloo(15, .semibold))
                    .foregroundStyle(theme.accent)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
