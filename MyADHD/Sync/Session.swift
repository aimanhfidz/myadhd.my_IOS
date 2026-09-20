/* ============================================================
   MyADHD/Sync/Session.swift — the Supabase session, and when to let go of it

   auth.js:45-66, 131-172, ported with one deliberate change.

   **Where it lives.** The Keychain, service `myadhd.auth.session`, with
   `kSecAttrAccessibleAfterFirstUnlock` — the same class as the widget
   snapshot, so a launch on a phone that has not been unlocked since a
   reboot behaves the same way for both. Not `UserDefaults`: the record
   holds a refresh token, and a refresh token does not belong in a plist
   that any backup reads in the clear.

   The bytes are the page's own shape — `{access_token, refresh_token,
   expiresAt, user:{id, email, name}}` — because `LegacyImport` copies
   `myadhd.auth.v1` straight across on the migration launch
   (LegacyImport.swift:487-508) and this is what has to read it back.

   ---- THE LIVENESS RULE, which is the point of this file ----

   auth.js:159-165 drops the session on **any** refresh failure, network
   ones included:

       } catch (_) {
         // The session is genuinely gone -- signed out elsewhere, or
         // revoked. Drop it rather than retrying forever.
         session = null;

   In a browser that is defensible: the page was loaded over the network
   a moment ago, so a failing request is unusual. In an app that opens
   from disk, works with no signal by design and lives on a phone that
   goes into tunnels, it is wrong — it signs people out on a train, and
   signing back in means Google, a consent screen and a full re-merge.

   So (design §2.7, decision 7):

     - a **transport** failure keeps the session and is retried later;
     - a **5xx** keeps the session — the server is having a bad minute,
       the grant is not the thing that failed;
     - **any 4xx** from `/auth/v1/token` drops it.

   The boundary is a status code and not a body. The alternative, which
   was considered and rejected, is to drop only when the body names
   `invalid_grant` or `refresh_token_not_found` — that leaves a dead
   session in the Keychain for ever the day GoTrue answers 401 with
   something else, and every sync pass then fails with "the server
   answered 401" until somebody signs out by hand.

   ---- single flight ----

   `freshToken()` is called by every request the app makes, and several
   of them start together on a cold launch. One refresh, awaited by all
   of them (auth.js:135-171). Because this class is `@MainActor`, the
   in-flight task is stored before the first `await`, so a second caller
   arriving in the same turn sees it.
   ============================================================ */

import Foundation
import Observation
import Security

// MARK: - What a failure was

/// Why a token could not be had. The distinction is the product: an app
/// that cannot tell "offline" from "revoked" signs people out in a tunnel.
enum SessionError: Error, CustomStringConvertible {

    /// There is no session, or the one there was has just been dropped
    /// because the server refused the grant. This is the web's
    /// `throw new Error('signed out')` (cloud.js:218) and the card reads
    /// it as "idle", never as an error.
    case signedOut

    /// The request never completed. **The session is kept.**
    case offline(Error)

    /// The refresh endpoint answered, badly, and not with a 4xx. **The
    /// session is kept.**
    case server(Int)

    /// What the account card is allowed to show. The two that can reach a
    /// screen are cloud.js's own strings (147, 237) and live in `Copy`;
    /// `signed out` is the sentinel cloud.js throws and tests for
    /// (218, 428) and is never rendered, so it stays here.
    var message: String {
        switch self {
        case .signedOut: return "signed out"
        case .offline: return Copy.Account.unreachable
        case .server(let code): return Copy.Account.serverAnswered(code)
        }
    }

    var description: String { message }

    /// `String(err.message) === 'signed out'` (cloud.js:428).
    var isSignedOut: Bool {
        if case .signedOut = self { return true }
        return false
    }
}

// MARK: - Who is signed in

struct SessionUser: Equatable {
    var id: String
    var email: String?
    var name: String?

    /// `{ id, email, name: u.user_metadata?.full_name || null }`
    /// (auth.js:128).
    init?(_ v: JSONValue?) {
        guard let o = v?.objectValue, let id = o["id"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        self.email = o["email"]?.stringValue
        let full = o["user_metadata"]?.objectValue?["full_name"]?.stringValue
        self.name = (full?.isEmpty == false) ? full : nil
    }

    init(id: String, email: String? = nil, name: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
    }

    var json: JSONValue {
        var o = JSONObject()
        o.set("id", .string(id))
        o.set("email", email.map { .string($0) } ?? .null)
        o.set("name", name.map { .string($0) } ?? .null)
        return .object(o)
    }
}

// MARK: - Where the bytes are kept

/// The one thing a test needs to swap. Everything else in this file is
/// the real code path.
protocol SessionStore: AnyObject {
    func read() -> Data?
    func write(_ data: Data)
    func clear()
}

/// Generic password, `kSecAttrAccessibleAfterFirstUnlock` (design §2.4).
/// The same service and account `LegacyImport` writes to.
final class KeychainSessionStore: SessionStore {

    static let service = "myadhd.auth.session"
    static let account = "current"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    func read() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func write(_ data: Data) {
        let fields: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updated = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
        guard updated == errSecItemNotFound else { return }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// For `Checks/cloud.swift`, which must not touch the login keychain of
/// whoever runs it.
final class MemorySessionStore: SessionStore {
    private(set) var data: Data?
    init(_ data: Data? = nil) { self.data = data }
    func read() -> Data? { data }
    func write(_ d: Data) { data = d }
    func clear() { data = nil }
}

// MARK: -

@MainActor
@Observable
final class Session {

    /// `live()` = `Date.now() < session.expiresAt - 60_000` (auth.js:66).
    /// A minute of margin, so a token cannot expire mid-request.
    static let skew = 60_000

    /// What is in the Keychain, and what goes back into it.
    struct Record: Equatable {
        var accessToken: String
        var refreshToken: String?
        /// `now + (expires_in || 3600) * 1000`, epoch milliseconds.
        var expiresAt: Int
        var user: SessionUser?

        /// The page's key order, so a build that still reads
        /// `myadhd.auth.v1` sees what it wrote.
        var json: JSONValue {
            var o = JSONObject()
            o.set("access_token", .string(accessToken))
            o.set("refresh_token", refreshToken.map { .string($0) } ?? .null)
            o.set("expiresAt", .int(expiresAt))
            o.set("user", user?.json ?? .null)
            return .object(o)
        }

        init(accessToken: String, refreshToken: String?, expiresAt: Int, user: SessionUser?) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.user = user
        }

        init?(_ v: JSONValue?) {
            guard let o = v?.objectValue,
                  let access = o["access_token"]?.stringValue, !access.isEmpty
            else { return nil }
            self.accessToken = access
            self.refreshToken = o["refresh_token"]?.stringValue
            self.expiresAt = o["expiresAt"]?.intValue ?? 0
            self.user = SessionUser(o["user"])
        }
    }

    // MARK: - State

    private(set) var record: Record?

    /// `auth.signedIn()` — true for an EXPIRED session too (auth.js:179).
    /// Signed in means "there is an account on this device", not "there
    /// is a usable token right now".
    var signedIn: Bool { record != nil }

    /// `auth.user()`.
    var user: SessionUser? { record?.user }

    /// `auth.configured()` — there is a Supabase project to sign in to.
    var configured: Bool { Supabase.configured }

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let http: URLSession
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var refreshing: Task<String, Error>?
    @ObservationIgnored private var watchers: [UUID: (SessionUser?) -> Void] = [:]

    @ObservationIgnored
    private var nowMS: Int { Int((clock().timeIntervalSince1970 * 1000).rounded(.down)) }

    init(store: SessionStore = KeychainSessionStore(),
         http: URLSession = Supabase.http,
         clock: @escaping () -> Date = Date.init)
    {
        self.store = store
        self.http = http
        self.clock = clock

        /* A record that will not parse is a signed-out device
           (auth.js:53), not a crash. */
        if let data = store.read(),
           let text = String(data: data, encoding: .utf8),
           let parsed = try? JSONValue.parse(text) {
            record = Record(parsed)
        }
    }

    // MARK: - Who is listening

    @discardableResult
    func onChange(_ fn: @escaping (SessionUser?) -> Void) -> UUID {
        let token = UUID()
        watchers[token] = fn
        return token
    }

    func removeOnChange(_ token: UUID) {
        watchers.removeValue(forKey: token)
    }

    private func announce() {
        for fn in watchers.values { fn(record?.user) }
    }

    // MARK: - Liveness

    /// auth.js:66.
    func live() -> Bool {
        guard let record else { return false }
        return nowMS < record.expiresAt - Self.skew
    }

    // MARK: - Writing it down

    /// The first half of `absorbRedirect` (auth.js:80-85): the tokens are
    /// held BEFORE the user is fetched, so `signedIn` is true while that
    /// request is in the air — exactly as the page has it. Nothing is
    /// written to the Keychain until `settle`.
    func begin(accessToken: String, refreshToken: String?, expiresIn: Int?) {
        record = Record(accessToken: accessToken,
                        refreshToken: refreshToken,
                        expiresAt: nowMS + (expiresIn ?? 3600) * 1000,
                        user: nil)
    }

    /// The account came back. Persist and tell everyone (auth.js:90-91, 118).
    func settle(user: SessionUser) {
        guard record != nil else { return }
        record?.user = user
        persist()
        announce()
    }

    /// A whole session from somewhere that already has one.
    func adopt(_ next: Record) {
        record = next
        persist()
        announce()
    }

    /// Signed out, deleted, or a grant the server refused. Clears the
    /// Keychain; **never touches `myadhd.v1`** (auth.js:219-221, 261-263).
    func clear() {
        record = nil
        refreshing?.cancel()
        refreshing = nil
        store.clear()
        announce()
    }

    private func persist() {
        guard let record else {
            store.clear()
            return
        }
        store.write(Data(WebJSON.encode(record.json).utf8))
    }

    // MARK: - A token to send

    /// `auth.token()` (auth.js:137-172), with the liveness rule above.
    ///
    /// Throws rather than returning nil, because the three reasons it can
    /// fail are three different things to do next and a nil says none of
    /// them.
    func freshToken() async throws -> String {
        guard let current = record else { throw SessionError.signedOut }
        if live() { return current.accessToken }

        if let inflight = refreshing { return try await inflight.value }

        let refresh = current.refreshToken
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw SessionError.signedOut }
            return try await self.performRefresh(using: refresh)
        }
        refreshing = task

        do {
            let token = try await task.value
            refreshing = nil
            return token
        } catch {
            refreshing = nil
            throw error
        }
    }

    /// `POST /auth/v1/token?grant_type=refresh_token`, body
    /// `{refresh_token}`, headers `Content-Type` and `apikey` — no
    /// Authorization, the grant is the credential (auth.js:144-148).
    private func performRefresh(using refresh: String?) async throws -> String {
        /* No refresh token at all is not a network problem and never will
           be one. It is the one local reason to let go. */
        guard let refresh, !refresh.isEmpty else {
            clear()
            throw SessionError.signedOut
        }

        var request = URLRequest(url: Supabase.authURL("token?grant_type=refresh_token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Supabase.anonKey, forHTTPHeaderField: "apikey")
        var body = JSONObject()
        body.set("refresh_token", .string(refresh))
        request.httpBody = Data(WebJSON.encode(.object(body)).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http.data(for: request)
        } catch {
            /* THE DIVERGENCE. auth.js drops the session here. A tunnel is
               not a revocation, and an app that cannot open its own lists
               on a train is not an offline-first app. */
            throw SessionError.offline(error)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0

        if (400...499).contains(code) {
            /* The grant was refused: signed out elsewhere, revoked, or a
               token from a project that no longer exists. This is the
               only answer that ends a session. */
            clear()
            throw SessionError.signedOut
        }

        guard (200...299).contains(code) else { throw SessionError.server(code) }

        guard let parsed = try? JSONValue.parse(data),
              let access = parsed["access_token"]?.stringValue, !access.isEmpty
        else {
            /* A 2xx with no token in it. GoTrue does not do this; if it
               ever does, it is the server misbehaving and not the grant
               being dead, so the session stays. */
            throw SessionError.server(code)
        }

        record = Record(
            accessToken: access,
            /* auth.js assigns `d.refresh_token` straight across. Keeping
               the old one when the answer omits it cannot lose a session
               and cannot resurrect a dead one — GoTrue rotates on every
               refresh, so in practice this always takes the new one. */
            refreshToken: parsed["refresh_token"]?.stringValue ?? record?.refreshToken,
            expiresAt: nowMS + (parsed["expires_in"]?.intValue ?? 3600) * 1000,
            user: record?.user
        )
        persist()
        return access
    }
}
