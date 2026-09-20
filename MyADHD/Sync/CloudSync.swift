/* ============================================================
   MyADHD/Sync/CloudSync.swift — one pass, rule for rule

   cloud.js:247-553. `localStorage` stays the source of truth on the web
   and the document stays it here: Supabase is a second copy the devices
   meet in, not a database the app reads from. So a pass is a reconcile —
   work out the difference between what is here and what is there, fix
   it, and be safe to run again at any moment.

   **The order is the rule.** stamp, persist, pull, merge in place,
   persist-and-reseal, outbound (cloud.js:364-410). Each step exists
   because of what the one before it would otherwise get wrong:

   1. `stamp()` on the way in, and persist if it moved. A store written
      before `updatedAt` existed has rows with no timestamp, and a pass
      must never send one up as "now" while treating it as "the beginning
      of time" here. `save()` normally does this; doing it again means
      the first pass after an upgrade cannot be the one that gets it
      wrong.
   2. The account check. A different account on this device resets the
      book and reseals — the tasks stay put and go up as the new
      account's, which is what signing in on a device that already had a
      list is asking for.
   3. `newestSeen` is raised from the rows BEFORE the merge, because the
      merge may change our copy but not what the server holds.
   4. The merge writes through `persistOnly`, never `save()`: the rows
      that just came down already carry the timestamps the other devices
      settled on, and `save()` would restamp them as local edits and
      bounce them straight back up.
   5. `reseal()` after the merge, for the same reason.
   6. Then, and only then, what the server has not got.

   **Last write wins, per task, on `updatedAt`.** Whole-store versioning
   was the other option and it is wrong: two devices that both add a task
   between passes would make one of them lose an entire list. Per task
   they both keep theirs, and the only thing that can be lost is one edit
   to one task edited on two devices at once.

   **The three comparisons, and the exact operator each uses:**

     remote deleted   drop ours when `mine.updatedAt <= rts`   (`<=`, so a
                      tombstone wins a tie; touch it since and it lives)
     arrival          skip when `graves[id] >= rts`            (`>=`, so a
                      tombstone we have not pushed yet is not undone by
                      the row it is about to overwrite)
     replace in place strictly `rts > mine.updatedAt`          (equal is
                      not newer; equal is us)

   Get any of those backwards and the app deletes somebody's task or
   resurrects one they threw away, and nothing fails — no build, no test,
   no screen. `Checks/cloud.sh` replays all three out of the real
   `cloud.js`.

   **Arrivals are NOT normalised.** `Object.assign({}, payload, {id,
   updatedAt})` and no `normalizeTask`. A payload written by a newer web
   build carries fields this build has never heard of, and `TaskItem`
   keeps them, because the merge on the other side deletes every local key
   before assigning the payload (cloud.js:293) — a client that drops a
   field erases it for every device.

   **Reachability is advisory (design §2.8).** It may stop an automatic
   pass from starting. `now()` — which is what "Sync now" presses —
   ignores it completely. A path monitor is wrong more often than people
   think, and a VPN or a captive portal that reports satisfied while
   nothing works must never be able to stall sync with no error the
   person can see.
   ============================================================ */

import Foundation
import Observation

@MainActor
@Observable
final class CloudSync {

    /// What the card reads (cloud.js:121).
    enum Phase: String { case idle, working, error }

    // MARK: - The four clocks

    /// Long enough to swallow a burst — a triage lands eight tasks with
    /// eight `save()` calls — short enough that an edit is on the other
    /// device before you have picked it up (cloud.js:58).
    static let debounce: TimeInterval = 1.5

    /// While the app is in front, ask for other devices' changes on a
    /// timer (cloud.js:69). What makes twelve seconds affordable is the
    /// probe: most ticks never fetch a task at all.
    static let pollInterval: TimeInterval = 12

    /// The chain ticks well inside `pollInterval` and decides from the
    /// clock, so a suspended app that missed its turn catches up on the
    /// next one rather than waiting out a full period (cloud.js:528).
    static let tick: TimeInterval = 3

    /// Several resume events fire together — the scene coming active and
    /// the path coming back are usually the same second (cloud.js:468).
    static let wakeDedupe = 2_000

    /// How long scheduling stays shut after a merge. On the web this is
    /// the length of one synchronous `host.repaint()` (cloud.js:424-425);
    /// here the repaint is SwiftUI's and happens after this turn, so the
    /// window is a short wall-clock one. It suppresses only the automatic
    /// debounce — never `now()`, and never the stamping that decides what
    /// is owed.
    static let muteAfterMerge: TimeInterval = 0.25

    // MARK: - What the card reads

    private(set) var phase: Phase = .idle
    private(set) var lastError: String?

    /// `cloud.error()` — nil unless `phase == .error`.
    var error: String? { lastError }

    // MARK: - What a pass reasons from

    /// The highest `updated_at` this device has seen on the account. If
    /// the server's highest still matches it, nobody has written anything
    /// and there is nothing to come down.
    ///
    /// Held as milliseconds, never as the string: PostgREST renders the
    /// column with an offset and microseconds and our own pushes are
    /// `toISOString`, and compared as text those never match — so every
    /// push would make the next probe cry news and drag the whole list
    /// down behind it (cloud.js:126-142).
    private(set) var newestSeen = 0

    /// Whether there is anything to go up. **It starts true**, because an
    /// app that has just launched cannot know — a task edited offline
    /// yesterday is still owed a push (cloud.js:144).
    private(set) var dirty = true

    private var lastPullAt = 0

    // MARK: - Collaborators

    @ObservationIgnored let store: AppStore
    @ObservationIgnored let session: Session
    @ObservationIgnored let api: Supabase
    @ObservationIgnored let reachability: Reachability

    /// `myadhd.cloud.v1`, as a file beside the document.
    @ObservationIgnored private(set) var book: CloudBook
    @ObservationIgnored private let bookURL: URL

    @ObservationIgnored private let clock: () -> Date

    /// `document.hidden`, inverted. A poll only acts while the app is in
    /// front; nothing in the pass needs the app to be visible, but a
    /// phone in a pocket asking five times a minute is somebody's
    /// battery.
    @ObservationIgnored private(set) var isVisible = true

    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var muted = false
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var muteTask: Task<Void, Never>?
    @ObservationIgnored private var reachToken: UUID?

    @ObservationIgnored
    private var nowMS: Int { Int((clock().timeIntervalSince1970 * 1000).rounded(.down)) }

    init(store: AppStore,
         session: Session,
         api: Supabase? = nil,
         reachability: Reachability? = nil,
         bookURL: URL? = nil,
         clock: @escaping () -> Date = Date.init)
    {
        self.store = store
        self.session = session
        self.api = api ?? Supabase(session: session)
        self.reachability = reachability ?? .shared
        self.clock = clock
        let url = bookURL ?? store.file.directory.appendingPathComponent(CloudBook.fileName)
        self.bookURL = url
        self.book = CloudBook.read(from: url)
    }

    // MARK: - Wiring (app.js:300, 303)

    /// Fills `AppStore`'s two cloud hooks and starts the poll chain.
    /// `scheduleCalendarSync` is deliberately untouched — the Google
    /// Calendar push is a different phase and a different file.
    func attach() {
        store.stampForCloud = { [weak self] in self?.stamp() }
        store.scheduleCloudSync = { [weak self] in self?.soon() }

        /* The path coming back is a resume, and `Reachability` has
           already deduped the flurry a Wi-Fi handover makes. */
        reachToken = reachability.onSatisfied { [weak self] in self?.wake() }
        schedulePoll()
    }

    func detach() {
        if let reachToken { reachability.removeOnSatisfied(reachToken) }
        reachToken = nil
        debounceTask?.cancel()
        pollTask?.cancel()
        muteTask?.cancel()
        debounceTask = nil
        pollTask = nil
        muteTask = nil
    }

    // MARK: - Stamping (the `save()` hook)

    /// `cloud.stamp()`. Runs on every write, signed in or out, and is one
    /// hash per task with no network.
    func stamp() {
        guard stampMoving() else { return }
        dirty = true
        book.write(to: bookURL)
    }

    /// The half that touches the document, without the persisting. The
    /// tasks come out of `AppStore`, get their timestamps, and go back in
    /// through `adopt` — which replaces the document and writes nothing,
    /// because the caller (`save()`, or `run()`) is about to.
    @discardableResult
    private func stampMoving() -> Bool {
        var tasks = store.doc.tasks
        guard book.stamp(&tasks, now: nowMS) else { return false }
        var next = store.doc
        next.tasks = tasks
        store.adopt(next)
        return true
    }

    // MARK: - When to run (cloud.js:347-352, 439-531)

    /// `ready()` — cloud.js:354-356. Whether a pass could do anything at
    /// all. Reachability is deliberately not part of this: it gates the
    /// automatic callers below, and never `now()`.
    func ready() -> Bool {
        Supabase.configured && session.configured && session.signedIn
    }

    /// `cloud.soon()` — what `save()` pokes. Automatic, so it respects
    /// the path monitor.
    func soon() {
        guard ready(), !muted else { return }
        guard reachability.allowsAutomaticWork else { return }
        if running { again = true; return }

        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    /// A pass, but only if one is actually due. Safe to call on any
    /// event: the scene coming active, the path coming back.
    func wake() {
        schedulePoll()   // the chain may have been suspended while we were away
        guard isVisible, ready() else { return }
        guard reachability.allowsAutomaticWork else { return }
        if nowMS - lastPullAt < Self.wakeDedupe { return }
        soon()
    }

    /// The last line of `wakeAccount()` (app.js:3872). Whether the session
    /// arrived just now or came off disk, boot is the first moment the
    /// lists can be merged with the other devices'.
    ///
    /// `run()` and not `soon()`, as the web has it: the debounce exists to
    /// collapse a burst of saves, and there is no burst at launch.
    func wakeAtLaunch() {
        guard ready() else { return }
        Task { @MainActor [weak self] in await self?.run() }
    }

    /// `scenePhase == .active`.
    func sceneBecameActive() {
        isVisible = true
        wake()
    }

    func sceneResigned() {
        isVisible = false
    }

    /// **"Sync now", and every other explicit press.** No reachability
    /// gate, no debounce, no dedupe — the person asked, so it tries and
    /// reports what actually happened (design §2.8).
    func now() async {
        await run()
    }

    /// `cloud.forget()` — signing out here leaves this device's copy
    /// alone, including the bookkeeping, so signing back in is a merge
    /// and not a re-upload of everything as if it were new
    /// (cloud.js:548).
    func forget() {
        setPhase(.idle)
    }

    // MARK: - The poll (cloud.js:489-531)

    private func schedulePoll() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.tick * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.poll()
            }
        }
    }

    private func poll() async {
        guard isVisible, ready(), !running else { return }
        guard reachability.allowsAutomaticWork else { return }
        guard nowMS - lastPullAt >= Int(Self.pollInterval * 1000) else { return }

        // Something of ours is owed either way, so there is nothing to ask.
        if dirty { soon(); return }

        do {
            /* `run()` rather than `soon()`: the debounce exists to
               collapse a burst of saves, and a probe that has already
               confirmed there is something waiting has nothing to
               collapse. */
            if try await api.probeNewest() != newestSeen {
                await run()
            } else {
                lastPullAt = nowMS   // asked, nothing there, clock restarts
            }
        } catch {
            /* Not worth reporting a probe that failed — the next tick
               asks again, and a real pass is what earns the error on the
               card. */
        }
    }

    // MARK: - A pass (cloud.js:358-437)

    func run() async {
        guard !running, ready() else { return }
        running = true
        again = false
        setPhase(.working)

        do {
            guard let user = session.user, !user.id.isEmpty else { throw SyncError.signedOut }

            if stampMoving() {
                store.persistOnly()
                dirty = true
                book.write(to: bookURL)
            }

            if book.userID != user.id {
                /* A different account on this device. The bookkeeping
                   describes the old one's rows and means nothing here. */
                book = CloudBook(user: .string(user.id))
                book.reseal(store.doc.tasks)
                book.write(to: bookURL)
            }

            let rows = try await api.pull()

            for r in rows { newestSeen = max(newestSeen, r.updatedAt) }

            let merged = merge(rows)
            if merged.changed {
                /* Written without re-stamping, then resealed so the copies
                   that just came down are not read as local edits. */
                store.applyMerged(merged.list)
                book.reseal(store.doc.tasks)
                book.write(to: bookURL)
            }

            let out = outbound(rows, userID: user.id)
            if !out.isEmpty {
                try await api.upsert(out)
                /* Our own writes are now the newest thing on the account.
                   Saying so here is what stops the next probe seeing them
                   as somebody else's news and pulling the whole list back
                   down. */
                for r in out { newestSeen = max(newestSeen, r.updatedAt) }
            }

            // Everything owed is now sent.
            dirty = false
            lastPullAt = nowMS
            setPhase(.idle)

            /* Last, and with the scheduler held shut. Redrawing the lists
               runs through the web's `goToNext()`, which calls `save()`,
               which would otherwise book a whole extra pass for changes
               this one has just finished reconciling (cloud.js:419-426).
               The native lists screen keeps that save-on-paint, so this
               keeps the guard. */
            if merged.changed { mute() }
        } catch let e as SyncError {
            if e.isSignedOut { setPhase(.idle) } else { setPhase(.error, e.message) }
        } catch let e as SessionError {
            if e.isSignedOut { setPhase(.idle) } else { setPhase(.error, e.message) }
        } catch {
            setPhase(.error, Copy.Account.unreachable)
        }

        running = false
        if again { soon() }
    }

    /// The window in which a repaint caused by the merge cannot book
    /// another pass for work this one has just finished reconciling.
    private func mute() {
        muted = true
        muteTask?.cancel()
        muteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.muteAfterMerge * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.muted = false
        }
    }

    private func setPhase(_ next: Phase, _ err: String? = nil) {
        lastError = next == .error ? (err ?? Copy.Account.unreachable) : nil
        guard phase != next || next == .error else { return }
        phase = next
    }

    // MARK: - The merge (cloud.js:247-303)

    /// Pure decision-making over the rows that came down. Nothing here
    /// touches the network, the file or the clock, which is what lets
    /// `Checks/cloud.sh` replay it against the real `cloud.js`.
    func merge(_ rows: [Supabase.Row]) -> (changed: Bool, list: [TaskItem]) {
        var list = store.doc.tasks

        /* `new Map(list.map(t => [t.id, t]))` — a later duplicate id wins
           the lookup, and `keep` is a set of ids, so both copies of a
           duplicated id live or die together. Faithfully odd. */
        var indexByID: [String: Int] = [:]
        for (i, t) in list.enumerated() { indexByID[t.id] = i }
        var keep = Set(indexByID.keys)
        var arrivals: [TaskItem] = []
        var changed = false

        for row in rows {
            let rts = row.updatedAt

            if row.deleted {
                /* Removed somewhere else — unless this device has touched
                   it since, in which case the task is alive again and the
                   push will say so.

                   Nothing is done about the Google event here on purpose:
                   the calendar belongs to the account, not the device, so
                   the device that did the deleting is already clearing
                   it. Orphaning it a second time would only earn a 404. */
                if let i = indexByID[row.id], (list[i].updatedAt ?? 0) <= rts {
                    keep.remove(row.id)
                    book.sigs.removeValue(forKey: row.id)
                    book.graves.set(row.id, .int(rts))
                    changed = true
                }
                continue
            }

            guard let i = indexByID[row.id] else {
                /* Not here. Either it is new to this device, or this
                   device is the one that deleted it — and a tombstone we
                   have not managed to push yet must not be undone by the
                   row it is about to overwrite. */
                let grave = book.graves[row.id]?.intValue ?? 0
                if grave >= rts { continue }
                book.graves.removeValue(forKey: row.id)
                arrivals.append(arrival(row))
                changed = true
                continue
            }

            if rts > (list[i].updatedAt ?? 0) {
                /* Edited elsewhere, more recently. Every local key goes
                   and the payload is assigned over it — a field this
                   build does not know about is carried, and a field the
                   other device dropped is dropped here too. In place, so
                   the row keeps its position in the list. */
                list[i] = arrival(row)
                changed = true
            }
        }

        guard changed else { return (false, list) }
        return (true, list.filter { keep.contains($0.id) } + arrivals)
    }

    /// `Object.assign({}, row.payload, { id: row.id, updatedAt: rts })`.
    /// No `normalizeTask`: a payload is taken exactly as it was sent.
    private func arrival(_ row: Supabase.Row) -> TaskItem {
        var t = TaskItem(fields: row.payload)
        t.id = row.id
        t.updatedAt = row.updatedAt
        return t
    }

    // MARK: - What goes up (cloud.js:306-338)

    /// What the server has not got, or has got an older copy of. Read
    /// AFTER the merge has been applied, so a row that just came down is
    /// not pushed straight back.
    func outbound(_ rows: [Supabase.Row], userID: String) -> [Supabase.Outgoing] {
        var remote: [String: Supabase.Row] = [:]
        for r in rows { remote[r.id] = r }
        var out: [Supabase.Outgoing] = []

        for t in store.doc.tasks {
            let r = remote[t.id]
            /* `-1` for a row that is not there at all, so a local task
               with no timestamp yet (`lts` 0) still beats it. */
            let rts = r.map { $0.updatedAt } ?? -1
            let lts = t.updatedAt ?? 0
            if let r, !r.deleted, rts >= lts { continue }
            out.append(Supabase.Outgoing(id: t.id,
                                         userID: userID,
                                         payload: t.json,
                                         updatedAt: lts != 0 ? lts : nowMS,
                                         deleted: false))
        }

        for (id, at) in book.graves.pairs {
            let atMS = at.intValue ?? 0
            if let r = remote[id], r.deleted, r.updatedAt >= atMS { continue }
            out.append(Supabase.Outgoing(id: id,
                                         userID: userID,
                                         // the column is NOT NULL; a tombstone has nothing to say
                                         payload: .object(JSONObject()),
                                         updatedAt: atMS,
                                         deleted: true))
        }

        return out
    }

    // MARK: - For the account card and the checks

    /// The account-change reset, exposed because signing in as somebody
    /// else on a device that already has a list is the one moment the
    /// book is thrown away rather than merged.
    func resetBook(to userID: String) {
        book = CloudBook(user: .string(userID))
        book.reseal(store.doc.tasks)
        book.write(to: bookURL)
        dirty = true
    }

    /// Only for `Checks/cloud.sh`, which drives the merge and the
    /// outbound directly against the rules cut out of `cloud.js`.
    func loadBook(_ next: CloudBook) {
        book = next
    }
}
