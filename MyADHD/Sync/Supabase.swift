/* ============================================================
   MyADHD/Sync/Supabase.swift — PostgREST, byte for byte

   cloud.js:216-241, 384, 401-409, 479. Four calls and no ORM: a pull, a
   probe, an upsert, and the `rest()` that carries all three.

   **The parts that are contract and not preference**, each of which has
   cost somebody their data somewhere:

   - `apikey` AND `Authorization: Bearer <access token>`. The publishable
     key identifies the project and grants nothing; the JWT is what RLS
     compares against `auth.uid()`.
   - **Never a `user_id` filter on the pull.** RLS scopes the rows to the
     signed-in user already. Sending the filter as well is how a client
     ends up quietly reading nothing when the column name or the policy
     moves under it — and it always sends `user_id` on the way UP, where
     it is required (inventory §2.6).
   - The upsert body is an **array**, `on_conflict=id,user_id` names the
     composite key, and `Prefer: resolution=merge-duplicates,return=minimal`
     is what turns a conflict into an update instead of a 409 and stops
     the server sending every row back.
   - `updated_at` goes up as `new Date(ms).toISOString()` — milliseconds
     and a `Z` — and comes back rendered by PostgREST with an offset and
     **six** fractional digits. `Date.parse` truncates those to three.
     `parseTimestamp` truncates too, and `Checks/cloud.sh` proves it: a
     microsecond of drift read as a millisecond flips last-write-wins on
     a tie, and a tie is exactly what two devices saving together make.

   **Errors are the page's.** A status becomes `the server answered N`
   (cloud.js:237) and anything that never arrived becomes `could not
   reach the server` (cloud.js:147). A `URLError`'s own text is better
   English than either, and it is still not used: the account card's copy
   is the product, and these two strings are what the web says.

   The detail of a PostgREST error body goes to the log and no further,
   as it does on the web (cloud.js:231-236) — it is a Postgres error code,
   which is the right thing to have when debugging and the wrong thing to
   put on a card somebody reads on their phone.
   ============================================================ */

import Foundation
import os

// MARK: -

/// What a pass can fail with. `signedOut` is not an error on the card —
/// cloud.js:428 turns it into `idle` — which is why it is a case here and
/// not a status.
enum SyncError: Error, CustomStringConvertible {
    case signedOut
    case transport(Error)
    case status(Int)

    var message: String {
        switch self {
        case .signedOut: return "signed out"
        case .transport: return Copy.Account.unreachable
        case .status(let code): return Copy.Account.serverAnswered(code)
        }
    }

    var description: String { message }

    var isSignedOut: Bool {
        if case .signedOut = self { return true }
        return false
    }

    /// A refresh that failed without ending the session keeps its own
    /// reason, so the card says "could not reach the server" for a tunnel
    /// and "the server answered 503" for a bad minute at GoTrue.
    static func from(_ e: SessionError) -> SyncError {
        switch e {
        case .signedOut: return .signedOut
        case .offline(let underlying): return .transport(underlying)
        case .server(let code): return .status(code)
        }
    }
}

// MARK: -

struct Supabase {

    // MARK: - Where the project is

    /* config.js:30-31. Public by design and shipped to every browser
       already: the publishable key identifies the project and grants
       nothing, and row-level security is what decides who may read what.
       The service key — the one that bypasses RLS — is in Vercel's env
       vars and only /api ever sees it. */
    static let urlBase = "https://ekjlzzqdzmvfhkimppsw.supabase.co"   // config.js:30
    static let anonKey = "sb_publishable_KCCs2u3DJ5pnZ6veM6TySw_eO8GHA9m"   // config.js:31

    /// `cloud.configured()` / `auth.configured()` — both are this test
    /// (cloud.js:536, auth.js:177).
    static var configured: Bool { !urlBase.isEmpty && !anonKey.isEmpty }

    static func restURL(_ path: String) -> URL {
        URL(string: urlBase + "/rest/v1/" + path)!
    }

    /// GoTrue, talked to directly — there is no SDK here for the same
    /// reason the web has none (auth.js:9-15).
    static func authURL(_ path: String) -> URL {
        URL(string: urlBase + "/auth/v1/" + path)!
    }

    /// design §2.7: everything but triage and transcribe waits 20 s, and
    /// nothing waits for connectivity — a request is always allowed to
    /// try and to fail, rather than sitting in a queue for a path that
    /// may never come (§2.8).
    static let timeout: TimeInterval = 20

    static let http: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = Supabase.timeout
        c.timeoutIntervalForResource = Supabase.timeout
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private static let log = Logger(subsystem: "my.adhd", category: "cloud")

    // MARK: - A row

    /// `select=id,payload,updated_at,deleted`.
    struct Row: Equatable {
        var id: String
        /// The WHOLE task, `{}` on a tombstone.
        var payload: JSONObject
        /// `Date.parse(row.updated_at) || 0`.
        var updatedAt: Int
        var deleted: Bool

        init(id: String, payload: JSONObject, updatedAt: Int, deleted: Bool) {
            self.id = id
            self.payload = payload
            self.updatedAt = updatedAt
            self.deleted = deleted
        }

        init?(_ v: JSONValue) {
            guard let o = v.objectValue, let id = o["id"]?.stringValue else { return nil }
            self.id = id
            self.payload = o["payload"]?.objectValue ?? JSONObject()
            self.updatedAt = Supabase.parseTimestamp(o["updated_at"]?.stringValue)
            self.deleted = o["deleted"]?.isTruthy == true
        }
    }

    /// One row on its way up (cloud.js:316-322, 328-334). The key order
    /// is the page's, because the body is compared byte for byte in
    /// `Checks/cloud.sh` and because there is no reason for it to differ.
    struct Outgoing: Equatable {
        var id: String
        var userID: String
        var payload: JSONValue
        /// Milliseconds. Rendered as `toISOString()` on the way out and
        /// read back with the same parser, so `newestSeen` cannot drift
        /// from what the server will report next time.
        var updatedAt: Int
        var deleted: Bool

        var json: JSONValue {
            var o = JSONObject()
            o.set("id", .string(id))
            o.set("user_id", .string(userID))
            o.set("payload", payload)
            o.set("updated_at", .string(Supabase.iso(updatedAt)))
            o.set("deleted", .bool(deleted))
            return .object(o)
        }
    }

    // MARK: - The client

    var session: Session
    var http: URLSession

    init(session: Session, http: URLSession = Supabase.http) {
        self.session = session
        self.http = http
    }

    /// cloud.js:216-241.
    @discardableResult
    func rest(_ path: String,
              method: String = "GET",
              prefer: String? = nil,
              body: Data? = nil) async throws -> Data?
    {
        let token: String
        do {
            token = try await session.freshToken()
        } catch let e as SessionError {
            /* `if (!token) throw new Error('signed out')`. A refresh that
               failed for a network reason is NOT signed out here — the
               session is still on the device and the pass simply did not
               happen. */
            throw SyncError.from(e)
        }

        var request = URLRequest(url: Self.restURL(path))
        request.httpMethod = method
        request.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http.data(for: request)
        } catch {
            throw SyncError.transport(error)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            if !detail.isEmpty { Self.log.warning("list sync, in full: \(detail, privacy: .private)") }
            throw SyncError.status(code)
        }
        if code == 204 { return nil }
        return data
    }

    /// Every row on the account. No `user_id` filter — see the header.
    func pull() async throws -> [Row] {
        guard let data = try await rest("tasks?select=id,payload,updated_at,deleted") else { return [] }
        guard let parsed = try? JSONValue.parse(data), let rows = parsed.arrayValue else { return [] }
        return rows.compactMap { Row($0) }
    }

    /// "Has anybody written anything since we last looked?" — a few dozen
    /// bytes: one column, one row, newest first (cloud.js:478-482).
    func probeNewest() async throws -> Int {
        guard let data = try await rest("tasks?select=updated_at&order=updated_at.desc&limit=1"),
              let parsed = try? JSONValue.parse(data),
              let first = parsed.arrayValue?.first
        else { return 0 }
        return Self.parseTimestamp(first["updated_at"]?.stringValue)
    }

    /// One upsert for the lot (cloud.js:401-405).
    func upsert(_ rows: [Outgoing]) async throws {
        guard !rows.isEmpty else { return }
        let body = WebJSON.encode(.array(rows.map(\.json)))
        try await rest("tasks?on_conflict=id,user_id",
                       method: "POST",
                       prefer: "resolution=merge-duplicates,return=minimal",
                       body: Data(body.utf8))
    }

    // MARK: - Instants

    /// `new Date(ms).toISOString()` — always three fractional digits and
    /// a `Z`.
    static func iso(_ ms: Int) -> String {
        isoOut.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// `Date.parse(s) || 0`, over what PostgREST actually renders:
    /// `2026-09-20T12:34:56.789123+00:00`.
    ///
    /// **The fraction is truncated to three digits, not rounded.** That is
    /// what `Date.parse` does, and the difference is a whole millisecond
    /// on `…789999`. One millisecond decides `rts > mine.updatedAt`, and
    /// that decides which device's edit survives.
    static func parseTimestamp(_ raw: String?) -> Int {
        guard let raw, !raw.isEmpty else { return 0 }
        let text = truncateFraction(raw)
        let parser = text.contains(".") ? isoInFraction : isoIn
        guard let date = parser.date(from: text) else { return 0 }
        return Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Keep at most three digits of the fraction, padding a shorter one
    /// out to three — `.7` is 700 ms to `Date.parse` and to
    /// `ISO8601DateFormatter`, which wants exactly three.
    static func truncateFraction(_ s: String) -> String {
        guard let dot = s.firstIndex(of: ".") else { return s }

        var out = String(s[s.startIndex...dot])
        var digits = 0
        var i = s.index(after: dot)
        while i < s.endIndex, s[i].isASCII, s[i].isNumber {
            if digits < 3 { out.append(s[i]) }
            digits += 1
            i = s.index(after: i)
        }
        /* A lone dot with nothing after it is not a timestamp; hand it
           back untouched so the parser refuses it, as `Date.parse` does. */
        guard digits > 0 else { return s }
        out += String(repeating: "0", count: max(0, 3 - digits))
        return out + String(s[i...])
    }

    private static let isoOut: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static let isoInFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoIn: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
