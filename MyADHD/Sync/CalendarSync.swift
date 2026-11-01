/* ============================================================
   MyADHD/Sync/CalendarSync.swift — dated tasks, onto Google Calendar

   The push half of app.js's calendar sync (app.js:3386-3584) and gcal.js's
   three verbs and its find-or-make (gcal.js:283-400). `Core/CalendarPush`
   decides what should exist; this file makes Google agree.

   It was missing from the native app from the day the web view went
   (2026-09-20) until this file. Dated tasks made on the phone reached the
   calendar only when some browser that was signed in opened the web app
   and pushed them from there.

   **A reconcile, not a queue.** Each task keeps `gcal: {id, sig}`. A pass
   works out what should exist from the store, fixes the difference, and is
   safe to run again at any moment: a pass cut off by the phone locking
   loses nothing, because the next one plans from scratch.

   **Linked means signed in.** The web has a per-browser Link button
   because it also works with no account, through Google's in-page token.
   This app has no such path: its only token is the one `/api/gcal-token`
   mints from the refresh token the account holds. So it is on whenever
   the account is linked to Google, exactly as a signed-in browser adopts
   the link on its own (`gcal.adopt()`, app.js:4257). `Unlink` is a
   per-device off switch, kept in `UserDefaults`; unlike the web's it
   leaves every task's `gcal` alone, because those ids are the account's,
   not this device's — clearing them would send the cleared rows up and
   make every other device push the same events a second time.

   **One thing the web does not do: look before making.** A task made in a
   browser is pushed from there, but its new event id only reaches the
   cloud with that browser's next save. Until then this device sees a
   dated task with no `gcal` and would make a second event. Every event
   carries `extendedProperties.private.myadhdId`, so an insert first asks
   the my.adhd calendar for an event already stamped with this task's id
   and adopts it if there is one. It costs one small read per new task.
   ============================================================ */

import Foundation
import Observation

@MainActor
@Observable
final class CalendarSync {

    /// `syncState` (app.js:3413).
    enum Phase: String { case idle, working, stale, error }

    /// What `/api/gcal-token` last said about the account's Google link.
    enum Link { case unknown, linked, notLinked }

    /// app.js:3404 — long enough to swallow a triage's burst of saves.
    static let debounce: TimeInterval = 1.2

    /// app.js:3409 — a first pass with a backlog does not fire two
    /// hundred requests at once.
    static let batchSize = 24

    /// A pass that failed for any reason but consent waits this long
    /// before an automatic one tries again. `now()` ignores it.
    static let backoff: TimeInterval = 30

    static let offKey = "myadhd.gcal.off"

    // MARK: - What the card reads

    private(set) var phase: Phase = .idle
    private(set) var lastError: String?
    private(set) var link: Link = .unknown
    private(set) var optedOut: Bool

    /// `gcal.connected()`, for this app: an account, linked to Google,
    /// and not switched off on this device.
    var connected: Bool {
        session.configured && session.signedIn && !optedOut && link != .notLinked
    }

    // MARK: - Collaborators

    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private let session: Session
    @ObservationIgnored private let http: URLSession
    @ObservationIgnored private let reachability: Reachability
    @ObservationIgnored private let defaults: UserDefaults

    @ObservationIgnored private var token: (value: String, until: Date)?
    @ObservationIgnored private var calendarID: String?

    /// In flight, so two callers share one answer: a press of Link and the
    /// pass the same sign-in books can otherwise both find nothing and
    /// both make a calendar, or both mint a token.
    @ObservationIgnored private var settling: Task<String, Error>?
    @ObservationIgnored private var minting: Task<String, Error>?

    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var quietUntil = Date.distantPast
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var reachToken: UUID?
    @ObservationIgnored private var sessionToken: UUID?

    init(store: AppStore,
         session: Session,
         http: URLSession = Supabase.http,
         reachability: Reachability = .shared,
         defaults: UserDefaults = .standard)
    {
        self.store = store
        self.session = session
        self.http = http
        self.reachability = reachability
        self.defaults = defaults
        self.optedOut = defaults.bool(forKey: Self.offKey)
    }

    // MARK: - Wiring

    /// Fills the hook `AppStore.save()` has always called, and listens for
    /// the two other moments the web runs a pass: the network coming back
    /// (`online`, app.js:6312) and an account arriving or leaving.
    func attach() {
        store.scheduleCalendarSync = { [weak self] in self?.soon() }
        reachToken = reachability.onSatisfied { [weak self] in self?.soon() }
        sessionToken = session.onChange { [weak self] _ in
            guard let self else { return }
            /* A different account is a different calendar and a different
               grant. Forget both and ask again. */
            self.token = nil
            self.calendarID = nil
            self.settling = nil
            self.minting = nil
            self.link = .unknown
            self.quietUntil = .distantPast
            self.setPhase(.idle)
            self.soon()
        }
    }

    func detach() {
        if let reachToken { reachability.removeOnSatisfied(reachToken) }
        if let sessionToken { session.removeOnChange(sessionToken) }
        reachToken = nil
        sessionToken = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - When to run

    /// `syncSoon()` (app.js:3480). Free when nothing is linked, which is
    /// the common case: `save()` calls it on every write.
    func soon() {
        guard connected, reachability.allowsAutomaticWork else { return }
        guard Date() >= quietUntil else { return }
        if running { again = true; return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    /// Coming back to the front (app.js:6310).
    func wake() { soon() }

    /// Every explicit press: no debounce, no backoff, no path monitor.
    /// It asks Google even when there is nothing to push, because the
    /// person pressing it wants to know whether the link works, and a pass
    /// with an empty plan would never find out.
    func now() async {
        quietUntil = .distantPast
        if link == .notLinked { link = .unknown }   // a press is worth asking again
        guard connected, !running else { return await run() }
        do {
            _ = try await ensureCalendar()   // shared with a pass that starts meanwhile
        } catch {
            settle(error)
            return
        }
        await run()
    }

    /// The card's Link button, for a device that was switched off here.
    func switchOn() {
        optedOut = false
        defaults.set(false, forKey: Self.offKey)
        link = .unknown
        quietUntil = .distantPast
    }

    /// The card's Unlink: this device stops pushing. The events stay in
    /// Google and every task keeps its `gcal` — see the file header.
    func switchOff() {
        optedOut = true
        defaults.set(true, forKey: Self.offKey)
        debounceTask?.cancel()
        setPhase(.idle)
    }

    // MARK: - A pass (app.js:3487-3584)

    func run() async {
        guard connected else { return }
        /* The backoff, for every automatic caller at once — including the
           debounce a pass's own `save()` books on its way out, which would
           otherwise retry a failed pass 1.2 s later. `now()` clears it
           before it gets here. */
        guard Date() >= quietUntil else { return }
        if running { again = true; return }

        let plan = CalendarPush.plan(tasks: store.doc.tasks, orphans: store.doc.gcalOrphans)
        guard !plan.isEmpty else { setPhase(.idle); return }

        running = true
        again = false
        setPhase(.working)

        let batch = plan.prefix(Self.batchSize)
        var dirty = false
        var failure: Error?

        do {
            /* The calendar first, which also proves there is a live token,
               so a batch does not fail one step at a time when the grant
               has simply gone. */
            let calendar = try await ensureCalendar()

            steps: for step in batch {
                do {
                    if try await apply(step, in: calendar) { dirty = true }
                } catch let err as GoogleError where err.isLater {
                    /* Rate limiting is a "later", not a failure. Stop here;
                       the next pass plans from scratch, so nothing is
                       skipped. */
                    failure = err
                    break steps
                }
            }
        } catch {
            failure = error
        }

        running = false

        /* Settled BEFORE the save: `save()` books the next debounced pass,
           and that pass has to see the backoff this one just earned. */
        if let failure { settle(failure) } else { setPhase(.idle) }
        if dirty { store.save() }   // stamps the new ids for the cloud, too
        guard failure == nil else { return }

        /* What did not fit in this batch, and anything written while it
           was in the air. */
        if plan.count > batch.count || again {
            again = false
            debounceTask?.cancel()
            debounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await self?.run()
            }
        }
    }

    /// What a failed pass leaves the card saying (app.js:3571-3578).
    private func settle(_ failure: Error) {
        let kind = (failure as? GoogleError)?.kind
        if kind == .notLinked || kind == .signedOut {
            /* Not a failure: `connected` is false now (or about to be),
               and the card offers the sign-in that links it. */
            setPhase(.idle)
            return
        }
        if kind == .consent {
            /* Only the person can fix this, so nothing automatic asks again
               until they press something or the account changes. */
            quietUntil = .distantFuture
            setPhase(.stale)
            return
        }
        lastError = Self.describe(failure)
        quietUntil = Date().addingTimeInterval(Self.backoff)
        setPhase(.error)
    }

    /// One step. Each re-reads its task, because the store may have moved
    /// while the step before it was in the air. True when it changed the
    /// document.
    private func apply(_ step: CalendarPush.Step, in calendar: String) async throws -> Bool {
        switch step {
        case .add(let id):
            guard let t = task(id), CalendarPush.syncable(t), t.gcal == nil else { return false }
            let sig = CalendarPush.eventSig(t)
            let eventID = try await adoptOrInsert(t, in: calendar)
            keep(eventID, sig: sig, for: id)
            return true

        case .edit(let id):
            guard let t = task(id), CalendarPush.syncable(t), let ref = t.gcal else { return false }
            let sig = CalendarPush.eventSig(t)
            var eventID = ref.id
            do {
                try await patch(eventID, CalendarPush.eventBody(t, timeZone: Self.zone), in: calendar)
            } catch let err as GoogleError where err.kind == .google && (err.status == 404 || err.status == 410) {
                /* Deleted on the Google side, or it lives on a calendar this
                   account no longer uses. Rebuild it rather than carrying a
                   dead id around for ever. */
                eventID = try await adoptOrInsert(t, in: calendar)
            }
            keep(eventID, sig: sig, for: id)
            return true

        case .drop(let id):
            guard let t = task(id), !CalendarPush.syncable(t), let ref = t.gcal else { return false }
            try await remove(ref.id, in: calendar)
            store.setCalendarRef(id, nil)
            return true

        case .kill(let eventID):
            /* A task may hold this event again — an undo, or an adopt
               earlier in this same pass. Deleting it then would leave
               that task pointing at nothing. */
            if store.doc.tasks.contains(where: { $0.gcal?.id == eventID }) {
                store.forgetOrphanID(eventID)
                return true
            }
            try await remove(eventID, in: calendar)
            store.forgetOrphanID(eventID)
            return true
        }
    }

    private func task(_ id: String) -> TaskItem? {
        store.doc.tasks.first { $0.id == id }
    }

    /// The task may have been deleted while its event was being made. The
    /// web loses that event; here it is queued for deletion instead.
    private func keep(_ eventID: String, sig: String, for taskID: String) {
        if !store.setCalendarRef(taskID, TaskItem.GCalRef(id: eventID, sig: sig)) {
            store.orphanEventID(eventID)
        }
    }

    private static var zone: String { TimeZone.current.identifier }

    private static func describe(_ error: Error) -> String {
        if let g = error as? GoogleError { return g.message }
        return Copy.GoogleCalendar.unreachable
    }

    private func setPhase(_ next: Phase) {
        if next != .error && next != .stale { lastError = nil }
        if phase != next { phase = next }
    }

    // MARK: - The token (gcal.js:160-199)

    private func accessToken() async throws -> String {
        if let token, token.until > Date() { return token.value }
        if let minting { return try await minting.value }
        let task = Task { @MainActor in try await self.mintToken() }
        minting = task
        defer { minting = nil }
        return try await task.value
    }

    private func mintToken() async throws -> String {
        /* Signed out is "nothing to do"; anything else from the session
           is the network, and must not read as a revoked grant — that
           would park the push until somebody pressed Reconnect. */
        let jwt: String
        do {
            jwt = try await session.freshToken()
        } catch SessionError.signedOut {
            throw GoogleError.signedOut
        } catch {
            throw GoogleError.offline
        }

        guard let url = URL(string: "/api/gcal-token", relativeTo: AppConfig.home)?.absoluteURL
        else { throw GoogleError.offline }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + jwt, forHTTPHeaderField: "Authorization")

        let (data, response) = try await load(request)
        switch response.statusCode {
        case 200: break
        case 404:
            /* Signed in, never linked to Google. Not an error: the card
               says "Not linked" and offers the sign-in that links it. */
            link = .notLinked
            throw GoogleError.notLinked
        case 409:
            throw GoogleError.consent   // revoked on Google's side
        default:
            throw GoogleError(status: response.statusCode, message: Copy.GoogleCalendar.unreachable,
                              kind: .server)
        }

        guard let o = (try? JSONValue.parse(data))?.objectValue,
              let value = o["accessToken"]?.stringValue
        else { throw GoogleError.offline }

        link = .linked
        let given = Normalize.jsNumber(o["expiresIn"])
        let life = max(60, (given.isFinite && given > 0 ? given : 3600) - 60)
        token = (value, Date().addingTimeInterval(life))
        if let own = o["calendarId"]?.stringValue, !own.isEmpty, calendarID == nil {
            calendarID = own
        }
        return value
    }

    // MARK: - Our calendar (gcal.js:283-349)

    /// Asked of the account first, then of Google's list, then made — and
    /// whatever is made is claimed, with the loser binning its own.
    private func ensureCalendar() async throws -> String {
        _ = try await accessToken()                 // may carry the account's answer
        if let calendarID { return calendarID }
        if let settling { return try await settling.value }
        let task = Task { @MainActor in try await self.findOrMakeCalendar() }
        settling = task
        defer { settling = nil }
        return try await task.value
    }

    private func findOrMakeCalendar() async throws -> String {
        if let calendarID { return calendarID }

        if let settled = await claim("") {
            calendarID = settled
            return settled
        }

        /* Under this scope the list only ever holds calendars this app
           made, so a my.adhd in it is ours from an earlier link. */
        if let list = try? await send("GET", "users/me/calendarList",
                                      query: [("minAccessRole", "owner"), ("maxResults", "250")]),
           let hit = list.objectValue?["items"]?.arrayValue?
               .compactMap(\.objectValue)
               .first(where: { $0["summary"]?.stringValue == Copy.GoogleCalendar.calendarName }),
           let id = hit["id"]?.stringValue
        {
            let winner = await claim(id) ?? id
            calendarID = winner
            return winner
        }

        let made = try await send("POST", "calendars", body: .object(JSONObject([
            ("summary", .string(Copy.GoogleCalendar.calendarName)),
            ("description", .string(Copy.GoogleCalendar.calendarDescription)),
            ("timeZone", .string(Self.zone)),
        ])))
        guard let madeID = made.objectValue?["id"]?.stringValue else {
            throw GoogleError(status: 0, message: Copy.GoogleCalendar.unreachable)
        }

        if let winner = await claim(madeID), winner != madeID {
            /* Another device got there first. Ours is seconds old and
               empty; a leftover would be untidy, not harmful. */
            _ = try? await send("DELETE", "calendars/" + Self.pathEncode(madeID))
            calendarID = winner
            return winner
        }
        calendarID = madeID

        /* Cosmetic: its own colour, so it reads as its own layer. */
        _ = try? await send("PUT", "users/me/calendarList/" + Self.pathEncode(madeID),
                            body: .object(JSONObject([
                                ("id", .string(madeID)), ("colorId", .string("5")), ("selected", .bool(true)),
                            ])))
        return madeID
    }

    /// `/api/gcal-calendar` — a claim that only takes while the account's
    /// answer is still empty. Returns the account's answer, or nil. Never
    /// throws: no answer is "no tiebreaker", not a failure.
    private func claim(_ id: String) async -> String? {
        guard let jwt = try? await session.freshToken(),
              let url = URL(string: "/api/gcal-calendar", relativeTo: AppConfig.home)?.absoluteURL
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + jwt, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(WebJSON.encode(.object(JSONObject([("calendarId", .string(id))]))).utf8)

        guard let answered = try? await load(request), answered.1.statusCode == 200,
              let answer = (try? JSONValue.parse(answered.0))?.objectValue?["calendarId"]?.stringValue,
              !answer.isEmpty
        else { return nil }
        return answer
    }

    // MARK: - Events (gcal.js:363-390)

    private func eventsPath(_ calendar: String, _ eventID: String? = nil) -> String {
        "calendars/" + Self.pathEncode(calendar) + "/events"
            + (eventID.map { "/" + Self.pathEncode($0) } ?? "")
    }

    /// Insert, unless the calendar already holds an event stamped with this
    /// task's id — then that one is brought up to date and adopted.
    private func adoptOrInsert(_ t: TaskItem, in calendar: String) async throws -> String {
        let body = CalendarPush.eventBody(t, timeZone: Self.zone)

        let found = try await send("GET", eventsPath(calendar), query: [
            ("privateExtendedProperty", "myadhdId=" + t.id),
            ("showDeleted", "false"),
            ("maxResults", "25"),
        ])
        let ids = (found.objectValue?["items"]?.arrayValue ?? [])
            .compactMap { $0.objectValue?["id"]?.stringValue }
            .filter { !$0.isEmpty }
            .sorted()
        if let keep = ids.first {
            /* The lowest id, so two devices adopting at once pick the same
               one. The rest are copies of this task that a race made
               earlier; they carry our own stamp and nothing else of the
               person's, so they go. Best effort — a copy left behind is
               untidy, and the next adopt tries again. */
            for extra in ids.dropFirst() {
                _ = try? await remove(extra, in: calendar)
            }
            try await patch(keep, body, in: calendar)
            store.forgetOrphanID(keep)   // wanted again: an undo got here first
            return keep
        }

        let made = try await send("POST", eventsPath(calendar), query: [("sendUpdates", "none")], body: body)
        guard let id = made.objectValue?["id"]?.stringValue else {
            throw GoogleError(status: 0, message: Copy.GoogleCalendar.unreachable)
        }
        return id
    }

    /// PATCH rather than PUT: it leaves alone anything edited on the Google
    /// side that the app does not model.
    private func patch(_ eventID: String, _ body: JSONValue, in calendar: String) async throws {
        _ = try await send("PATCH", eventsPath(calendar, eventID), query: [("sendUpdates", "none")], body: body)
    }

    /// Already gone is a success: deleting it in Google is an ordinary
    /// thing to do and must not wedge the sync.
    private func remove(_ eventID: String, in calendar: String) async throws {
        do {
            _ = try await send("DELETE", eventsPath(calendar, eventID), query: [("sendUpdates", "none")])
        } catch let err as GoogleError where err.kind == .google && (err.status == 404 || err.status == 410) {
            return
        }
    }

    // MARK: - The wire (gcal.js:209-240)

    /// One request to the Calendar API, with one retry on a 401 — the only
    /// thing a 401 means here is that the hour ran out mid-pass.
    private func send(_ method: String, _ path: String,
                      query: [(String, String)] = [],
                      body: JSONValue? = nil,
                      retried: Bool = false) async throws -> JSONValue
    {
        let bearer = try await accessToken()

        var url = "https://www.googleapis.com/calendar/v3/" + path
        if !query.isEmpty {
            url += "?" + query.map { Self.queryEncode($0.0) + "=" + Self.queryEncode($0.1) }
                .joined(separator: "&")
        }
        guard let target = URL(string: url) else { throw GoogleError.offline }

        var request = URLRequest(url: target)
        request.httpMethod = method
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(WebJSON.encode(body).utf8)
        }

        let (data, response) = try await load(request)
        let status = response.statusCode

        if status == 401 {
            token = nil
            if retried { throw GoogleError.consent }
            return try await send(method, path, query: query, body: body, retried: true)
        }
        if status == 204 || data.isEmpty { return .null }

        let parsed = (try? JSONValue.parse(data)) ?? .null
        guard (200..<300).contains(status) else {
            let e = parsed.objectValue?["error"]?.objectValue
            let reason = e?["errors"]?.arrayValue?.first?.objectValue?["reason"]?.stringValue
            throw GoogleError(status: status,
                              message: e?["message"]?.stringValue ?? "Google returned \(status)",
                              reason: reason)
        }
        return parsed
    }

    private func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await http.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GoogleError.offline }
            return (data, http)
        } catch let err as GoogleError {
            throw err
        } catch {
            throw GoogleError.offline
        }
    }

    /// A calendar id is an address, often with a `#` in it.
    static func pathEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// Stricter than URLComponents, which leaves `=` and `+` alone — and
    /// `myadhdId=<id>` is a value with an `=` in it.
    static func queryEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
}

/// What Google, or our server about Google, said.
struct GoogleError: Error {
    enum Kind { case google, server, notLinked, signedOut, consent, offline }

    var status: Int
    var message: String
    var reason: String? = nil
    var kind: Kind = .google

    /// Signed in, but the account was never linked to Google.
    static let notLinked = GoogleError(status: 404, message: "calendar not linked", kind: .notLinked)
    /// The grant is gone; only a fresh sign-in brings it back
    /// (app.js:3576-3577).
    static let consent = GoogleError(status: 409, message: "reconnect", kind: .consent)
    /// No session any more; the account went while a pass was running.
    static let signedOut = GoogleError(status: 0, message: "signed out", kind: .signedOut)
    /// The request never got an answer.
    static let offline = GoogleError(status: 0, message: Copy.GoogleCalendar.unreachable, kind: .offline)

    /// Rate limited, by Google: stop the batch and carry on next pass
    /// (app.js:3557). The web reads every 403 this way; here only the ones
    /// Google labels as limits do, so a 403 that will never clear (a
    /// calendar this grant cannot write) fails the pass and says so.
    var isLater: Bool {
        guard kind == .google else { return false }
        if status == 429 { return true }
        return status == 403 && Self.limitReasons.contains(reason ?? "")
    }

    static let limitReasons: Set<String> = [
        "rateLimitExceeded", "userRateLimitExceeded", "quotaExceeded",
    ]
}
