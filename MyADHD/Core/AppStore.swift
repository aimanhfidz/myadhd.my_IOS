/* ============================================================
   MyADHD/Core/AppStore.swift — the one writer

   design.md §2.3. `AppStore` holds one `StoreDocument` and is the only
   thing in the app allowed to change it. SwiftUI observes it directly:
   there is no second in-memory copy, no actor-plus-façade, no ORM. Every
   mutation the web app has lives here and nowhere else, ported from
   `app.js` rather than from a description of it — the line number is on
   each one.

   **The two write intents are app.js:293-304 exactly.**

   - `persistOnly()` writes the file and nothing else. `touchNote` uses it
     on every keystroke, `stampTimeOnly` uses it at boot, and a cloud
     merge uses it because the rows that just came down already carry the
     timestamps the other devices settled on — running them back through
     `save()` would restamp them as local edits and bounce them straight
     up again.
   - `save()` stamps for the cloud, writes the file, then pokes the two
     sync timers. The stamp goes BEFORE the write so what lands on disk
     carries the timestamps conflicts are settled on.

   The three sync calls are hooks here, and empty by default: `CloudBook`,
   `CloudSync` and `GCalSync` arrive in a later phase (design §2.2). They
   are properties rather than a protocol so that wiring them up is one
   assignment in `MyADHDApp` and nothing in this file has to change.

   **What is NOT here.** No copy (that is `Copy`), no ordering (that is
   `Ordering`), no toasts and no undo timers — the web's `markDone`
   raises its own toast with an Undo button inside it, and this returns
   the undo instead so the toast can live where toasts live. The
   behaviour is the same; the layering is not the web's, because the web
   had nowhere else to put it.
   ============================================================ */

import Foundation
import Observation

@MainActor
@Observable
final class AppStore {

    // MARK: - The document

    /// The whole of `myadhd.v1`. Read freely; write only through the
    /// methods below, which is what makes "exactly one writer" checkable
    /// by reading this file rather than by hoping.
    private(set) var doc: StoreDocument

    /// Set when the launch read found a document that would not parse.
    /// The document has been moved aside and this store started fresh —
    /// which is what `load()` does on the web (app.js:288), so the two
    /// agree about what a person sees.
    private(set) var quarantinedOnLaunch: URL?

    @ObservationIgnored let file: StoreFile
    @ObservationIgnored private let inShell: Bool
    @ObservationIgnored private let clock: () -> Date

    /// Milliseconds since the epoch, the way `Date.now()` gives them.
    @ObservationIgnored
    private var nowMS: Int { Int((clock().timeIntervalSince1970 * 1000).rounded(.down)) }

    // MARK: - The hooks a later phase fills in

    /// `cloud.stamp()` (app.js:300). Runs before the write, and is free
    /// when signed out — one hash per task and no network.
    @ObservationIgnored var stampForCloud: (() -> Void)?

    /// `syncSoon()` (app.js:302) — the Google Calendar debounce, 1200 ms.
    /// A no-op unless the calendar is linked.
    @ObservationIgnored var scheduleCalendarSync: (() -> Void)?

    /// `cloud.soon()` (app.js:303) — the Supabase debounce, 1500 ms. A
    /// no-op unless there is an account.
    @ObservationIgnored var scheduleCloudSync: (() -> Void)?

    /// Fires after every write of either kind, with the bytes that just
    /// went to disk. `StoreBridge` hangs the widget snapshot and the
    /// notification schedule off this behind its own 1.5 s debounce.
    @ObservationIgnored var didWrite: ((String) -> Void)?

    // MARK: - Session-lived state that is deliberately not on the store

    /// Set by a quadrant's `+`, read once when the dump lands, and
    /// cleared whether the dump went through or was abandoned. Not
    /// persisted and not synced: it describes one press of one button,
    /// and it must not outlive the composer (app.js:1112, 598-601, 2049).
    var pendingQuadrant: String?

    // MARK: - Boot

    init(file: StoreFile = StoreFile(),
         inShell: Bool = true,
         clock: @escaping () -> Date = Date.init)
    {
        self.file = file
        self.inShell = inShell
        self.clock = clock

        let bootMS = (clock().timeIntervalSince1970 * 1000).rounded(.down)
        switch file.read() {
        case .ok(let value, _):
            doc = StoreDocument.load(value, inShell: inShell, now: bootMS)
        case .missing:
            doc = StoreDocument()
        case .corrupt(let quarantined, _):
            /* "corrupt store — start fresh rather than crash", app.js:288.
               The bytes are not gone: they are at `quarantined`, and
               nothing will ever write over them. */
            doc = StoreDocument()
            quarantinedOnLaunch = quarantined
        }
    }

    /// Replace the document wholesale, without writing. For
    /// `LegacyImport`, which has just read somebody's real store out of
    /// WebKit and has not earned the right to be trusted with `save()`
    /// yet, and for `reloadIfChangedOnDisk`.
    func adopt(_ next: StoreDocument) {
        doc = next
    }

    /// `didBecomeActive`. Today there is one writer and this never fires;
    /// the day an App Intent or an extension writes, this is what stops
    /// a stale in-memory copy being stamped over the top of it.
    @discardableResult
    func reloadIfChangedOnDisk() -> Bool {
        guard file.changedOnDisk() else { return false }
        guard case .ok(let value, _) = file.read() else { return false }
        doc = StoreDocument.load(value, inShell: inShell, now: Double(nowMS))
        return true
    }

    // MARK: - The two write intents (app.js:293-304)

    /// The store, written and nothing else.
    func persistOnly() {
        let text = doc.jsonString
        file.write(Data(text.utf8))
        didWrite?(text)
    }

    func save() {
        /* Before the write, so what lands on disk carries the timestamps
           the other devices will settle conflicts on. */
        stampForCloud?()
        persistOnly()
        scheduleCalendarSync?()   // no-op unless the calendar is linked
        scheduleCloudSync?()      // no-op unless there is an account
    }

    // MARK: - Boot chores, in this order (design §3.1)

    /// app.js:330-347. Tasks stored before `when` and `at` were settled
    /// together: the model heard "eat at 8am", returned the time and no
    /// day, and `normalizeTask` kept the two as independent fields. The
    /// result sat under "No date yet" with the hour invisible.
    ///
    /// Anything already done is left alone — moving a finished task onto
    /// tomorrow would be a lie about a thing that has happened.
    /// Idempotent: once stamped, `when` is set and this never sees them
    /// again.
    @discardableResult
    func stampTimeOnly() -> Int {
        var stamped = 0
        let now = clock()
        for i in doc.tasks.indices {
            let t = doc.tasks[i]
            if t.done { continue }
            if let when = t.when, !when.isEmpty { continue }
            guard let at = t.at, !at.isEmpty else { continue }
            guard let day = Normalize.dayForTime(at, now: now) else { continue }
            doc.tasks[i].when = day
            stamped += 1
        }
        if stamped > 0 { persistOnly() }
        return stamped
    }

    /// How long a finished task stays in the "N done" pile before it is
    /// dropped for good (app.js:312).
    static let doneTTL = 7 * 24 * 60 * 60 * 1000

    /// A year and change of small integers, oldest days dropped
    /// (app.js:369).
    static let doneCountsMax = 400

    /// app.js:349-372. A store written before `doneAt` existed has
    /// finished tasks with no stamp; they are stamped now rather than
    /// dropped, because a missing timestamp means we do not know when it
    /// happened and guessing "long ago" would silently delete the pile
    /// the first time someone opened the updated app.
    @discardableResult
    func pruneDone() -> Int {
        let now = nowMS
        var stamped = 0

        for i in doc.tasks.indices where doc.tasks[i].done && doc.tasks[i].doneAt == nil {
            doc.tasks[i].doneAt = now
            stamped += 1
        }

        let before = doc.tasks.count
        var keep: [TaskItem] = []
        for t in doc.tasks {
            if !t.done || now - (t.doneAt ?? 0) < Self.doneTTL {
                keep.append(t)
                continue
            }
            /* Counted on its way out, on the day it was finished — the
               LOCAL day. This is the only record of it once the row is
               gone, and it is the only thing that ever writes
               doneCounts. */
            let day = WebDates.dayKey(Date(timeIntervalSince1970: Double(t.doneAt ?? 0) / 1000))
            doc.setDoneCount(day, doc.doneCount(day) + 1)
            orphanEvent(t)   // it is about to stop existing; its event must not outlive it
        }
        doc.tasks = keep

        /* Object.keys().sort() is lexicographic, and the LOWEST keys go —
           which for YYYY-MM-DD is the oldest days. The ones that stay
           keep their insertion order in the object, not the sorted one. */
        var days = doc.doneCounts.keys.sorted()
        while days.count > Self.doneCountsMax {
            doc.removeDoneCount(days.removeFirst())
        }

        if stamped > 0 || doc.tasks.count != before { save() }
        return before - doc.tasks.count
    }

    // MARK: - Ticking one off (app.js:1826-1845)

    /// The tick means "I did this", and `doneAt` is what `pruneDone()`
    /// ages it out on. Returns false when the id is not on the store.
    @discardableResult
    func markDone(_ id: String) -> Bool {
        guard let i = doc.index(ofTask: id) else { return false }
        doc.tasks[i].done = true
        doc.tasks[i].doneAt = nowMS
        save()
        return true
    }

    /// The Undo behind that toast, and the same one the done pile
    /// carries: back on the lists, and no longer ageing out.
    @discardableResult
    func undoDone(_ id: String) -> Bool {
        guard let i = doc.index(ofTask: id) else { return false }
        doc.tasks[i].done = false
        doc.tasks[i].doneAt = nil
        save()
        return true
    }

    // MARK: - Removing (app.js:1798-1822)

    /// What a removal has to remember to be undoable: the task, and the
    /// index it left from. Undo puts it back where it was rather than
    /// appending, because a row reappearing at the bottom of a different
    /// list is not the thing that was taken away.
    struct Removal {
        var task: TaskItem
        var index: Int
    }

    /// Removing is not completing. The tick feeds the done count; this is
    /// for the ones the model invented or split wrongly, and it leaves no
    /// trace.
    func removeTask(_ id: String) -> Removal? {
        guard let i = doc.index(ofTask: id) else { return nil }
        let gone = doc.tasks.remove(at: i)
        orphanEvent(gone)
        save()
        return Removal(task: gone, index: i)
    }

    /// Pull the event back off the death-row list if the sync has not got
    /// to it yet. If it has, `unorphanEvent` finds nothing, the task comes
    /// back with a gcal id pointing at a deleted event, and the next push
    /// gets a 404 and rebuilds it. Either way it ends up right.
    func undoRemove(_ removal: Removal) {
        unorphanEvent(removal.task)
        doc.tasks.insert(removal.task, at: min(removal.index, doc.tasks.count))
        save()
    }

    // MARK: - Clear everything (app.js:1637-1648)

    /// Two confirmations and a 20 s disarm live in the danger zone's UI.
    /// This is the third press: no undo, no backup. Returns how many went.
    @discardableResult
    func clearAll() -> Int {
        let gone = doc.tasks.count
        for t in doc.tasks { orphanEvent(t) }
        doc.tasks = []
        save()
        return gone
    }

    // MARK: - Rewording (app.js:1754-1792)

    /// The commit half of the inline editor: trimmed, and ignored when it
    /// is empty or unchanged. Capped at 160 — the same cap the input's
    /// `maxLength` puts on it, applied again because a paste can beat an
    /// attribute. Returns true when the title actually moved, which is
    /// when the 'Reworded.' toast is owed.
    @discardableResult
    func editTitle(_ id: String, to raw: String) -> Bool {
        guard let i = doc.index(ofTask: id) else { return false }
        let next = JSText.trim(raw)
        guard !next.isEmpty, next != doc.tasks[i].title else { return false }
        doc.tasks[i].title = Normalize.slice(next, 160)
        save()
        return true
    }

    // MARK: - Breaking one down (app.js:1857-1861)

    /// What came back from `/api/triage` in breakdown mode, applied. At
    /// most seven steps; `firstStep` is replaced only when the model sent
    /// one, because the row prints whatever is stored and an empty
    /// replacement would blank a good line.
    func applyBreakdown(_ id: String, steps: [String], firstStep: String?) {
        guard let i = doc.index(ofTask: id) else { return }
        doc.tasks[i].steps = Array(steps.prefix(7))
        if let firstStep, !firstStep.isEmpty { doc.tasks[i].firstStep = firstStep }
        save()
    }

    // MARK: - The matrix (app.js:2853-2858)

    /// A placement the person made themselves. Returns false for the
    /// silent no-op the web does when the drop lands on the quadrant the
    /// task was already deriving to — no write, no toast, no repaint.
    ///
    /// Nothing in the app clears `quadrant` back to derived; that is the
    /// web's behaviour and not an oversight here.
    @discardableResult
    func moveToQuadrant(_ id: String, to quadrant: String) -> Bool {
        guard let i = doc.index(ofTask: id) else { return false }
        let today = WebDates.dayKey(clock())
        guard quadrant != Ordering.quadrantOf(doc.tasks[i], today: today) else { return false }
        doc.tasks[i].quadrant = quadrant
        save()
        return true
    }

    /// The view toggle. Persisted, unlike the category filter — that one
    /// is where you are looking right now, this one is how you think
    /// (app.js:1301-1308, 236-244).
    func setView(_ view: String) {
        guard doc.view != view else { return }
        doc.view = view
        save()
    }

    func toggleView() {
        setView(doc.view == "matrix" ? "list" : "matrix")
    }

    // MARK: - The dump landing (app.js:590-612)

    /// What `triage()` does with the tasks it got back, whether they came
    /// from the model or from the offline parser.
    struct TriageResult {
        var added: Int
        var dupes: Int
    }

    /// A dump ADDS to the lists. Nothing already captured gets thrown away
    /// just because you thought of something else.
    ///
    /// The de-dupe is against the titles of the OPEN tasks only, taken
    /// once before anything is added — so a finished task with the same
    /// title does not block a fresh one, and two identical lines in the
    /// same dump both land. Both of those are the web's behaviour, and
    /// both are load-bearing: the first is why ticking something off and
    /// dumping it again works, the second is why "call mum" twice in one
    /// dump is two calls.
    @discardableResult
    func applyTriage(_ incoming: [TaskItem]) -> TriageResult {
        var seen = Set<String>()
        for t in doc.tasks where !t.done {
            seen.insert(JSText.trim(t.title).lowercased())
        }

        var fresh = incoming.filter { !seen.contains(JSText.trim($0.title).lowercased()) }
        let dupes = incoming.count - fresh.count

        /* Dumped from a quadrant's +, so that is where it was meant to go
           — whatever the model made of it. Cleared either way: the pin
           belongs to one press of one button, not to the next dump from
           the tab bar. */
        if let quadrant = pendingQuadrant {
            for i in fresh.indices { fresh[i].quadrant = quadrant }
            pendingQuadrant = nil
        }

        doc.tasks.append(contentsOf: fresh)
        save()
        return TriageResult(added: fresh.count, dupes: dupes)
    }

    /// app.js:2049 — the composer is going, and the quadrant was this
    /// sheet's.
    func clearPendingQuadrant() {
        pendingQuadrant = nil
    }

    /// The tasks the offline parser guessed at — what 'Sort these
    /// properly' re-sorts, and what the offline note counts
    /// (app.js:1662).
    var staleLocalTasks: [TaskItem] {
        doc.tasks.filter { !$0.done && $0.local }
    }

    /// The apply half of `resortLocal` (app.js:1678-1680). The stale rows
    /// come OUT and the fresh ones go on the END — they are not replaced
    /// in place, because a re-sort is allowed to split one line into two
    /// and there would be no place to put the second one.
    func applyResort(staleIDs: [String], fresh: [TaskItem]) {
        let gone = Set(staleIDs)
        doc.tasks = doc.tasks.filter { !gone.contains($0.id) } + fresh
        save()
    }

    /// `settleForOffline` (app.js:1706-1714). Keep the offline reading and
    /// stop calling it provisional. Nothing is deleted and nothing is
    /// rewritten — the one change is that the list stops offering to
    /// re-sort what the sorter has already declined to touch.
    func settleForOffline(_ ids: [String]) {
        let stale = Set(ids)
        for i in doc.tasks.indices where stale.contains(doc.tasks[i].id) {
            doc.tasks[i].local = false
        }
        save()
    }

    // MARK: - Notes (app.js:4661-4671, 4960-4998)

    /// A new, empty note — `normalizeNote({})`, which mints the id and
    /// gives it one empty paragraph.
    @discardableResult
    func newNote() -> NoteItem {
        let n = NoteItem.normalize(nil, now: Double(nowMS))
        doc.notes.append(n)
        save()
        return n
    }

    /// Typing writes straight through, so nothing is ever lost to a
    /// closed editor — but through `persistOnly()` rather than `save()`.
    /// `save()` stamps the tasks for the cloud and pokes both sync
    /// timers, none of which has anything to do with a note, and running
    /// it on every keystroke would make the phone rebuild its reminders
    /// once per letter.
    func touchNote(_ id: String) {
        guard let i = doc.index(ofNote: id) else { return }
        doc.notes[i].refreshBody()
        doc.notes[i].updatedAt = Double(nowMS)
        persistOnly()
    }

    /// Edit a note's blocks, title or look in one go, then `touchNote`
    /// it. Every keystroke in the editor comes through here.
    func editNote(_ id: String, _ change: (inout NoteItem) -> Void) {
        guard let i = doc.index(ofNote: id) else { return }
        change(&doc.notes[i])
        touchNote(id)
    }

    /// The reminder fields and the delete both call `save()` rather than
    /// `persistOnly()`, because a reminder is a thing the phone has to
    /// schedule and the schedule is rebuilt off a write.
    func saveNote(_ id: String, _ change: (inout NoteItem) -> Void) {
        guard let i = doc.index(ofNote: id) else { return }
        change(&doc.notes[i])
        doc.notes[i].refreshBody()
        doc.notes[i].updatedAt = Double(nowMS)
        save()
    }

    /// app.js:4373-4375. A note nobody typed anything into is not a note
    /// — it is the button press that opened it. A paper colour or a
    /// reminder alone does not save it.
    static func noteIsBlank(_ n: NoteItem) -> Bool {
        JSText.trim(n.title).isEmpty && JSText.trim(n.body).isEmpty && n.files.isEmpty
    }

    /// **The blanks nothing closed.** `newNote()` writes the note before
    /// the editor is on screen, deliberately, so a crash between the two
    /// leaves the note and not a lost one. What it also leaves, if the app
    /// went away in between, is an `Untitled` card nobody typed into —
    /// `closeNote` never ran for it and nothing else looks. One pass at
    /// boot, beside `pruneDone()`, which is the same job for tasks.
    ///
    /// The open note is exempt: a cold launch has none, but the argument
    /// is there so a later caller cannot delete the note under an editor.
    @discardableResult
    func pruneBlankNotes(except open: String? = nil) -> Int {
        let before = doc.notes.count
        doc.notes.removeAll { $0.id != open && Self.noteIsBlank($0) }
        let gone = before - doc.notes.count
        if gone > 0 { persistOnly() }
        return gone
    }

    /// Leaving the editor.
    func closeNote(_ id: String) {
        if let n = doc.note(id: id), Self.noteIsBlank(n) {
            doc.notes.removeAll { $0.id == id }
        }
        save()
    }

    struct NoteRemoval {
        var note: NoteItem
        var index: Int
    }

    func deleteNote(_ id: String) -> NoteRemoval? {
        guard let i = doc.index(ofNote: id) else { return nil }
        let gone = doc.notes.remove(at: i)
        save()
        return NoteRemoval(note: gone, index: i)
    }

    func undoDeleteNote(_ removal: NoteRemoval) {
        doc.notes.insert(removal.note, at: min(removal.index, doc.notes.count))
        save()
    }

    /// The index, newest first (app.js `notesByRecent`).
    var notesByRecent: [NoteItem] {
        Ordering.stableSorted(doc.notes) { a, b in
            let d = b.updatedAt - a.updatedAt
            if d < 0 { return true }
            if d > 0 { return false }
            return nil
        }
    }

    // MARK: - Profile, the offer, the feedback day

    /// app.js:5570 — trimmed, then capped at 24 by `Profile.name`'s own
    /// setter (a UTF-16 slice, as `String.prototype.slice` is).
    func setProfileName(_ raw: String) {
        doc.profile.name = JSText.trim(raw)
        save()
    }

    /// app.js:3936. An unrecognised face is kept and re-emitted; drawing
    /// it as the default is the renderer's business.
    func setProfileAvatar(_ face: String) {
        doc.profile.avatar = face
        save()
    }

    /// app.js:5563 — the onboarding offer, once turned down, stays turned
    /// down.
    func dismissSignupOffer() {
        doc.signupOfferHidden = true
        save()
    }

    /// app.js:2705. The UTC day of the last note sent from this device —
    /// UTC and not local, because the server's one-a-day is UTC.
    func markFeedbackSent() {
        doc.sentFeedbackOn = WebDates.utcDay(clock())
        save()
    }

    /// app.js:2659.
    var feedbackSpentToday: Bool {
        doc.sentFeedbackOn == WebDates.utcDay(clock())
    }

    // MARK: - Google Calendar orphans (app.js:3206-3216)

    /// A task is deleted from the store the moment it is removed, which
    /// would strand its event in Google for ever — so the event id is
    /// dropped here on the way out and the sync clears it on the next
    /// pass.
    private func orphanEvent(_ t: TaskItem) {
        guard let id = t.gcal?.id, !id.isEmpty else { return }
        guard !doc.gcalOrphans.contains(id) else { return }
        doc.gcalOrphans.append(id)
    }

    /// Undo's half of that, for a removal that gets taken back in time.
    private func unorphanEvent(_ t: TaskItem) {
        guard let id = t.gcal?.id, !id.isEmpty else { return }
        doc.gcalOrphans.removeAll { $0 == id }
    }

    /// The sync's half, once the events really are gone from Google.
    func clearOrphans(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let gone = Set(ids)
        doc.gcalOrphans.removeAll { gone.contains($0) }
        persistOnly()
    }

    // MARK: - Cloud merge

    /// The rows a pull moved, written WITHOUT a stamp: they already carry
    /// the timestamps the other devices settled on, and `save()` would
    /// restamp them as local edits and bounce them straight back up
    /// (app.js:291-296).
    func applyMerged(_ tasks: [TaskItem]) {
        doc.tasks = tasks
        persistOnly()
    }

    // MARK: - JS string helpers
}
