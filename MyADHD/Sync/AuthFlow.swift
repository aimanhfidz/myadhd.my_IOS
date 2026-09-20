/* ============================================================
   MyADHD/Sync/AuthFlow.swift — signing in, and ending it

   auth.js:73-129, 203-264, native. The redirect the page performs becomes
   an `ASWebAuthenticationSession`, and everything after the fragment is
   the page's own code translated.

   **Reusing `GoogleSignIn.swift`.** That file already does the hard part
   and already explains why it has to: Google answers
   `disallowed_useragent` to OAuth in an embedded web view, and
   `ASWebAuthenticationSession` is Safari — so Google is satisfied, an
   already signed-in Google needs no password, and the redirect comes back
   to the app instead of stranding it in another browser. It also rewrites
   `redirect_to` to `myadhd://auth` on the way out, because catching an
   https redirect needs an Associated Domains entitlement. Nothing here
   duplicates any of that; the authorize URL is built and handed over.

   **`myadhd://auth` must be on Supabase's redirect allow-list**
   (docs/supabase-setup.md:23-30 lists five https URLs and no scheme).
   Until it is, Supabase refuses the redirect and this returns nothing —
   which is dashboard work and cannot be done or tested from here
   (design §4, decision 14).

   ---- the two Googles ----

   Worth keeping straight, because one is written down and the other must
   never be:

     session token   proves who you are to Supabase. Ours to refresh, and
                     it lives in the Keychain.
     provider token  lets the server write to Google Calendar. Google's,
                     expires hourly, and **the refresh token that renews
                     it is posted straight to /api/link-google and never
                     written to this device** (auth.js:98-101). A refresh
                     token on a phone is a permanent credential sitting in
                     somebody's pocket.

   `access_type=offline&prompt=consent` is what makes Google mint that
   refresh token at all: Google hands one out once per grant, so without
   `prompt=consent` a second sign-in comes back with nothing and the
   calendar link silently stops renewing (auth.js:37-42).

   ---- ending the account ----

   Guideline 5.1.1(v) wants this reachable from inside the app and says in
   as many words that an email address does not count. The server does the
   deleting — it needs the service key to touch `auth.users`, and the
   cascades take the tasks and the Google token with it. This end only
   proves who is asking and then forgets the session, because there is no
   longer an account to log out of (auth.js:232-247). It throws when the
   account is still there, so the card can say so rather than quietly
   leaving somebody signed in to nothing.
   ============================================================ */

import Foundation

#if canImport(UIKit)
import UIKit
#endif

// MARK: -

enum AuthError: Error, CustomStringConvertible {
    /// `throw new Error('not signed in')` (auth.js:250). Internal — the
    /// card's own copy is what a person reads.
    case notSignedIn
    /// `detail.error || 'could not delete the account'` (auth.js:258).
    case refused(String)

    var description: String {
        switch self {
        case .notSignedIn: return "not signed in"
        case .refused(let why): return why
        }
    }
}

// MARK: -

@MainActor
final class AuthFlow {

    /// The calendar scope, asked for during sign-in so there is one
    /// consent screen rather than two (auth.js:43). `nonisolated` because
    /// it is a default argument of `authorizeURL`, which is evaluated in
    /// the caller's context.
    nonisolated static let scopes = "https://www.googleapis.com/auth/calendar.app.created"

    let session: Session

    private let http: URLSession

    #if canImport(UIKit)
    private let google = GoogleSignIn()
    #endif

    init(session: Session, http: URLSession = Supabase.http) {
        self.session = session
        self.http = http
    }

    // MARK: - Going out

    /// `auth.signIn()` (auth.js:203-215), with the page's defaults —
    /// every caller in the app passes nothing and wants exactly these.
    ///
    /// `redirect_to` is written as `myadhd://auth` here rather than left
    /// for `GoogleSignIn` to substitute, so the URL this builds is the URL
    /// that goes out; `GoogleSignIn` replaces the parameter with the same
    /// value.
    static func authorizeURL(scopes: String? = AuthFlow.scopes, offline: Bool = true) -> URL? {
        guard Supabase.configured else { return nil }

        var url = Supabase.urlBase + AppConfig.authorizePath
            + "?provider=google"
            + "&redirect_to=" + encode(AppConfig.callbackURL)
        if let scopes, !scopes.isEmpty { url += "&scopes=" + encode(scopes) }
        if offline { url += "&access_type=offline&prompt=consent" }
        return URL(string: url)
    }

    /// `encodeURIComponent`. `URLComponents` percent-encoding leaves `/`
    /// and `:` alone and Supabase compares `redirect_to` exactly, so the
    /// allowed set is spelled out rather than borrowed.
    private static func encode(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// The whole flow: out to Safari, back with a fragment, absorbed.
    ///
    /// Returns `arrived` — the same boolean `absorbRedirect()` returns,
    /// which is what decides whether `wakeAccount` toasts "Signed in.
    /// Bringing your lists together…". A cancel is `false` and is not an
    /// error: nothing happened.
    @discardableResult
    func signIn() async -> Bool {
        #if canImport(UIKit)
        guard let url = Self.authorizeURL() else { return false }

        let callback: URL? = await withCheckedContinuation { continuation in
            google.start(authorize: url) { continuation.resume(returning: $0) }
        }
        guard let callback else { return false }
        return await absorb(callback)
        #else
        /* `ASWebAuthenticationSession` needs a window to present in.
           `Checks/cloud.sh` compiles this file for the Mac and drives
           everything on the other side of the fragment. */
        return false
        #endif
    }

    // MARK: - Coming back (auth.js:73-120)

    /// Supabase puts the tokens in the fragment — a fragment never
    /// reaches a server, not ours and not Vercel's logs, which is the
    /// reason this flow uses one.
    @discardableResult
    func absorb(_ url: URL) async -> Bool {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
              fragment.contains("access_token=")
        else { return false }

        let p = Self.fragmentFields(fragment)
        guard let access = p["access_token"], !access.isEmpty else { return false }

        session.begin(accessToken: access,
                      refreshToken: p["refresh_token"],
                      expiresIn: p["expires_in"].flatMap { Int($0) })

        do {
            session.settle(user: try await fetchUser(access))
        } catch {
            /* The tokens were real enough to parse and the account could
               not be read. The page drops the session rather than keeping
               one it cannot name (auth.js:92-96). */
            session.clear()
            return false
        }

        /* The provider refresh token appears exactly once, here, and only
           because we asked for offline access. Straight to the server,
           never to this device. */
        if let provider = p["provider_refresh_token"], !provider.isEmpty {
            await linkGoogle(refreshToken: provider, access: access)
        }

        return true
    }

    /// `new URLSearchParams(hash.slice(1))` — `+` is a space and `%xx` is
    /// decoded. A duplicate key keeps the first, as `get` does.
    static func fragmentFields(_ fragment: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in fragment.split(separator: "&", omittingEmptySubsequences: true) {
            let halves = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = decode(String(halves[0]))
            guard !key.isEmpty, out[key] == nil else { continue }
            out[key] = halves.count > 1 ? decode(String(halves[1])) : ""
        }
        return out
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            ?? s.replacingOccurrences(of: "+", with: " ")
    }

    /// `GET /auth/v1/user` with `apikey` and the bearer token
    /// (auth.js:122-129).
    private func fetchUser(_ access: String) async throws -> SessionUser {
        var request = URLRequest(url: Supabase.authURL("user"))
        request.setValue(Supabase.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")

        let (data, response) = try await http.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw AuthError.refused("could not read the account") }
        guard let user = SessionUser(try? JSONValue.parse(data)) else {
            throw AuthError.refused("could not read the account")
        }
        return user
    }

    /// `POST /api/link-google {refreshToken}` (auth.js:104-116,
    /// inventory §3.6). Best effort: a failure here costs the calendar
    /// link its renewal and costs the sign-in nothing, so it is logged
    /// and swallowed exactly as the page does.
    private func linkGoogle(refreshToken: String, access: String) async {
        guard let url = URL(string: "/api/link-google", relativeTo: AppConfig.home)?.absoluteURL
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        var body = JSONObject()
        body.set("refreshToken", .string(refreshToken))
        request.httpBody = Data(WebJSON.encode(.object(body)).utf8)

        _ = try? await http.data(for: request)
    }

    // MARK: - Signing out (auth.js:217-230)

    /// Local state first, network second: the device is signed out the
    /// moment it is pressed, whatever the server says next. **`myadhd.v1`
    /// is not touched** — the lists stay.
    func signOut() async {
        let access = session.record?.accessToken
        session.clear()

        guard let access else { return }
        var request = URLRequest(url: Supabase.authURL("logout"))
        request.httpMethod = "POST"
        request.setValue(Supabase.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        _ = try? await http.data(for: request)
    }

    // MARK: - Ending it (auth.js:248-264)

    /// Throws when the account is still there; clears the session only on
    /// a 2xx.
    func deleteAccount() async throws {
        let access: String
        do {
            access = try await session.freshToken()
        } catch {
            throw AuthError.notSignedIn
        }

        guard let url = URL(string: "/api/delete-account", relativeTo: AppConfig.home)?.absoluteURL
        else { throw AuthError.refused("could not delete the account") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http.data(for: request)
        } catch {
            throw AuthError.refused("could not delete the account")
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            let detail = (try? JSONValue.parse(data))?["error"]?.stringValue
            throw AuthError.refused(detail ?? "could not delete the account")
        }

        session.clear()
    }
}
