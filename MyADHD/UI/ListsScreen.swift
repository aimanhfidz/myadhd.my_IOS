/* ============================================================
   MyADHD/UI/ListsScreen.swift — where the dump comes back

   `goToNext` (app.js:1221-1284), `paintListBody` (1287-1291),
   `#screen-now` (app.html:306-398).

   This is the screen the app is for. Everything before it is a way in and
   everything after it is a way of looking at what is already here.

   **The order on the page, and it is the order in the markup.** Eyebrow,
   summary, the offline note, the sign-up offer, the filter row, the
   buckets, the done pile, the danger zone. Each one is allowed to be
   absent and none of them moves when another is: the offline note only
   exists while something on the list was guessed at, the filter row only
   once there are two lists to choose between, the done pile only once
   something is done, the danger zone only while there is anything at all
   to clear.

   **The empty state is not an empty list.** With no open tasks the whole
   apparatus goes — including the done pile, which is deliberate
   (app.js:1230-1240 returns before `renderDone`): a screen that says
   "Head's clear" underneath fourteen struck-through rows is not saying it.
   The danger zone stays if finished tasks are still on the store, because
   they are still something to clear.

   **Three things the web does here that this does not.**

   1. `goToNext()` opens with `save()`. Every paint stamped the store for
      the cloud and poked both sync timers, because on the web a paint was
      the only reliable place to hang that off. Here a paint is what
      SwiftUI does when an `@Observable` changed, and everything that can
      change the store already went through `AppStore.save()` on its way.
      Saving again on paint would rewrite the file on every scroll.
   2. `show(screenNow)` rewinds the scroller, and `keepPlace()` exists to
      undo that for the cases where it is wrong. Nothing here rewinds:
      every row is identified by its task id, so the list is edited rather
      than rebuilt and the scroll offset survives on its own. `keepPlace`
      is the default rather than a special case.
   3. `goToNext` paints both shapes of this tab. Here the lists tab is two
      screens — this one and `MatrixScreen` — and which is up is
      `AppShell`'s branch on the document's `view`. So this screen draws the
      lists and nothing else, and `MatrixTools` in the header is the way
      across. It is drawn whatever is on the list, including nothing: a
      screen that hides the way out while it is empty is the same trap in a
      smaller room, and the one-way version of this had already shut people
      out of the matrix for good.
   ============================================================ */

import SwiftUI

struct ListsScreen: View {

    @Environment(\.theme) private var theme

    let store: AppStore
    let toasts: ToastCenter

    /// `auth.configured() && !auth.signedIn()`. No account layer exists in
    /// this build (design §3.5), so the answer comes from above and the
    /// offer stays down until it can mean something.
    var isSignupOffered: Bool = false
    /// `auth.signIn()`.
    var onSignIn: () -> Void = {}
    /// `#btn-dump-again` → `openComposer()`.
    var onDumpAgain: () -> Void = {}

    // MARK: what the screen itself remembers

    /// `catFilter` — a module variable on the web, and session-lived here
    /// for the same reason: it is where you are looking, not how you think.
    @State private var catFilter = "all"
    /// Which rows have their detail down. Keyed by task id so a repaint
    /// cannot shut one — see the note in `ListTaskRow`.
    @State private var openIDs: Set<String> = []
    /// `#done-toggle aria-expanded` — collapsed by default, and a
    /// re-render never touches it.
    @State private var doneOpen = false
    /// The `?`, which the matrix shows too and from the same button.
    @State private var helping = false

    // MARK: what one paint is looking at

    private var open: [TaskItem] { store.doc.tasks.filter { !$0.done } }
    private var finished: [TaskItem] { store.doc.tasks.filter(\.done) }
    private var groups: [(key: String, items: [TaskItem])] {
        Ordering.groupByCategory(open)
    }

    /// A filter has to survive a re-render but not the list it was
    /// filtering: tick the last thing off Money and the page must not sit
    /// there showing an empty Money.
    private func resolvedFilter(_ groups: [(key: String, items: [TaskItem])]) -> String {
        guard catFilter != "all" else { return "all" }
        return groups.contains { $0.key == catFilter } ? catFilter : "all"
    }

    // MARK: -

    var body: some View {
        let open = self.open
        let groups = self.groups
        let filter = resolvedFilter(groups)
        let shown = filter == "all" ? open : open.filter { Ordering.catKey($0) == filter }
        let today = WebDates.dayKey()

        VStack(alignment: .leading, spacing: 0) {
            /* The screen's own name, and the way across to the matrix. The
               header does not scroll: `MatrixTools` is how you leave this
               screen, and a way out that has to be scrolled back up to is
               not one. */
            ScreenHeader(title: Copy.ScreenTitle.lists) {
                MatrixTools(store: store, showHelp: { helping = true })
            }
            .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    /* The empty state is a `return` on the web (app.js:1240),
                       which is why the done pile is not under it: with nothing
                       open there is nothing to sort, nothing to filter and
                       nothing to be told about.

                       That `return` also jumps over the offline note and the
                       filter row without hiding them, so on the web both keep
                       whatever they were last left showing — tick the last
                       offline-sorted task off and the note sits there over an
                       empty screen offering to re-sort nothing. That is a
                       missed `classList.toggle`, not a decision, and it is not
                       reproduced: here the two are drawn from what is open, so
                       they go when it does. */
                    if !open.isEmpty {
                        OfflineNote(store: store, toasts: toasts)
                            .padding(.bottom, 22)
                        SignupOffer(store: store, isOffered: isSignupOffered, onSignIn: onSignIn)
                        CategoryBar(groups: groups, filter: filterBinding(groups))
                            .padding(.bottom, groups.count >= 2 ? 18 : 0)
                        buckets(shown, today: today)
                        DonePile(done: finished, store: store, isOpen: $doneOpen)
                    }

                    /* Shown whenever the store holds anything at all, open or
                       finished — a pile of ticked-off rows is still something
                       to clear. It sits ABOVE the cleared note, which is the
                       order the markup puts them in (app.html:381-396). */
                    if !store.doc.tasks.isEmpty {
                        DangerZone(store: store, toasts: toasts)
                    }

                    if open.isEmpty { clearedNote }
                }
                .frame(maxWidth: Theme.measure, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20)
                /* `.now-wrap { padding-top: clamp(18px,3vh,32px); padding-bottom: 8px }`.
                   Nothing more is needed at the foot: `AppShell` reserves the
                   room the floating bar needs as a bottom safe-area inset, and
                   a `ScrollView` already honours that. */
                .padding(.top, 22)
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        /* `html, body { background: var(--surface) }` — the screens sit on
           the surface, not on the backdrop; the backdrop is the ground behind
           the floating furniture. */
        .background(theme.surface.ignoresSafeArea())
        /* The same walkthrough the matrix shows, from the same `?`. */
        .fullScreenCover(isPresented: $helping) {
            MatrixHelp(onClose: { helping = false })
        }
        .onChange(of: groups.map(\.key)) { _, keys in
            /* `if (catFilter !== 'all' && !groups.some(...)) catFilter = 'all'`
               — the resolution above already draws the right thing; this is
               what makes it stick, so the pill does not light up again if
               the category comes back. */
            if catFilter != "all" && !keys.contains(catFilter) { catFilter = "all" }
        }
        .onChange(of: store.doc.tasks.map(\.id)) { _, ids in
            /* A row that has left cannot still be open. Without this the
               set grows by one id per removed task for as long as the app
               runs, and an id that comes back — Undo puts the same task
               back at the same index — would come back expanded. */
            openIDs.formIntersection(Set(ids))
        }
    }

    // MARK: the pieces, in the order they appear

    /* The eyebrow — `SORTED, AIMAN.` — and the summary line under it are
       both gone, and the shell's own reasoning for taking them out is why
       (reference/BridgeScript.swift:176-186). The eyebrow was this screen
       saying its own name in small caps because the bar above it said the
       app's name instead; the bar says the screen's name now, so it was
       the same word twice in two sizes. The summary's counts are on the
       tab bar's badge and on the heading of every bucket.

       `Copy.Lists.eyebrow`, `eyebrowPlain` and `summary` stay where they
       are. They are the web app's sentences and `Checks/copy.sh` holds
       them to it whether or not this screen draws them today. */

    /// The four headings, the ones with something under them, in the order
    /// the day presses on you.
    private func buckets(_ shown: [TaskItem], today: String) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(Ordering.bucketize(shown, today: today), id: \.key) { bucket in
                BucketSection(key: bucket.key, label: bucket.label, items: bucket.items) { task in
                    ListTaskRow(task: task,
                            today: today,
                            store: store,
                            toasts: toasts,
                            isOpen: openBinding(task.id))
                }
            }
        }
    }

    /// `Head's clear. Nothing left in the queue.` The done pile is not
    /// drawn under it — see the file header.
    private var clearedNote: some View {
        VStack(spacing: 0) {
            Text(Copy.Lists.clearedStrong)
                .font(Font.baloo(20, .bold))
                .kerning(-0.02 * 20)
                .foregroundStyle(theme.ink)
                .padding(.bottom, 6)

            Text(Copy.Lists.clearedRest)
                .font(Font.baloo(15))
                .foregroundStyle(theme.muted)

            Button(action: onDumpAgain) {
                Text(Copy.Lists.dumpAgain)
                    .font(Font.baloo(15, .semibold))
                    .foregroundStyle(theme.accent)
                    .underline()
                    .padding(.top, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: bindings into the sets above

    private func openBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { openIDs.contains(id) },
            set: { isOpen in
                if isOpen { openIDs.insert(id) } else { openIDs.remove(id) }
            }
        )
    }

    /// The bar reads the resolved filter and writes the raw one, so
    /// picking a pill is immediate and a vanished category still falls back
    /// to All without the pill ever having looked wrong.
    private func filterBinding(_ groups: [(key: String, items: [TaskItem])]) -> Binding<String> {
        Binding(
            get: { resolvedFilter(groups) },
            set: { catFilter = $0 }
        )
    }
}
