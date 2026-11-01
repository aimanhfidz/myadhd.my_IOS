/* ============================================================
   MyADHD/Sync/GoogleMeetings.swift — asking Google for the day

   The network half of Core/Meetings.swift, which says why this is Google
   and not the phone's calendar. This file only fetches: a token from
   `/api/gcal-token`, the calendar list, and each calendar's events in the
   reader's window. What counts as a meeting is `GoogleEvents`, in Core,
   where `Checks/meetings.sh` can hold it to fixtures.

   **A failed fetch keeps what it had.** A dropped connection is not news
   about the diary, so only an answer from Google — or from our server
   about the Google link — changes what is drawn.
   ============================================================ */

import Foundation


@MainActor
final class GoogleMeetings: MeetingSource {


    private let session: Session
    private let http: URLSession

    private var held: [Meeting] = []
    private var calendarCount = 0
    private var offered: [CalendarOption] = []
    /// Events in the window per calendar id, switched off or not — the
    /// number beside each switch in Settings.
    private var counts: [String: Int] = [:]

    /// The person's per-calendar choices, read at the start of each fetch
    /// so a switch flipped in Settings is honoured by the very next one.
    private let choices: () -> [String: Bool]
    private(set) var access: MeetingAccess = .granted

    /// One fetch at a time. A pull and a return to the front can land
    /// together; the second waits for the first rather than asking twice.
    private var inflight: Task<Void, Never>?

    /// The Google token, kept until a minute before it dies so a pull
    /// does not cost a round trip to our own server as well as Google.
    private var token: (value: String, own: String?, until: Date)?

    init(session: Session,
         http: URLSession = Supabase.http,
         choices: @escaping () -> [String: Bool] = { MeetingCalendars.load() })
    {
        self.session = session
        self.http = http
        self.choices = choices
    }

    func meetings(from: String, to: String) -> [Meeting] {
        held.filter { $0.when >= from && $0.when <= to }
    }

    func calendarsRead() -> Int { calendarCount }

    func offeredCalendars() -> [CalendarOption] { offered }

    func eventCounts() -> [String: Int] { counts }

    func fetch(from: String, to: String) async {
        if let inflight { return await inflight.value }
        let task = Task { await run(from: from, to: to) }
        inflight = task
        await task.value
        inflight = nil
    }

    private enum Failure: Error {
        /// Google or our server said no in a way another try will not fix.
        case needsGoogle
        /// The network, or a 5xx. Keep what we had and try next time.
        case transient
    }

    private func run(from: String, to: String) async {
        guard session.signedIn else {
            access = .signedOut
            held = []; calendarCount = 0; offered = []; counts = [:]; token = nil
            return
        }
        do {
            let (bearer, own) = try await googleToken()
            let listed = try await calendarList(bearer)
            let chosen = choices()
            let calendars = listed.filter { GoogleEvents.reads($0, own: own, choices: chosen) }

            guard let start = WebDates.keyToDate(from),
                  let last = WebDates.keyToDate(to) else { return }
            let end = WebDates.addDays(last, 1)

            /* Every calendar on offer is read, switched off or not, so
               Settings can say what each one would put on your day — "23
               coming up" is the reason to turn one off. The reader drops
               the switched-off ones before anything is drawn, and that is
               also what makes switching one back on instant. A switched-off
               calendar that fails to read costs its count, never the read
               of the ones that are on. */
            let offeredHere = listed.filter { GoogleEvents.offers($0, own: own) }
            let extra = offeredHere.filter { o in !calendars.contains { $0.id == o.id } }
            var found: [Meeting] = []
            var tally: [String: Int] = [:]
            for calendar in calendars {
                let got = try await events(in: calendar, bearer, start: start, end: end)
                tally[calendar.id] = got.count
                found += got
            }
            for calendar in extra {
                guard let got = try? await events(in: calendar, bearer, start: start, end: end) else { continue }
                tally[calendar.id] = got.count
                found += got
            }
            held = found
            counts = tally
            calendarCount = calendars.count
            offered = listed.filter { GoogleEvents.offers($0, own: own) }.map {
                CalendarOption(id: $0.id, title: $0.title,
                               byDefault: GoogleEvents.reads($0, own: own))
            }
            access = .granted
        } catch Failure.needsGoogle {
            access = .needsGoogle
            held = []; calendarCount = 0; offered = []; counts = [:]; token = nil
        } catch {
            /* A dropped connection is not news about the diary. What was
               read last time is still the best answer there is. */
        }
    }

    // MARK: the token

    private func googleToken() async throws -> (String, String?) {
        if let token, token.until > Date() { return (token.value, token.own) }

        let jwt: String
        do { jwt = try await session.freshToken() } catch { throw Failure.transient }

        guard let url = URL(string: "/api/gcal-token", relativeTo: AppConfig.home)?.absoluteURL
        else { throw Failure.transient }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + jwt, forHTTPHeaderField: "Authorization")

        let (data, response) = try await load(request)
        switch response.statusCode {
        case 200: break
        /* 404: signed in, never linked. 409: revoked. Both need the
           sign-in that hands the server a new refresh token. */
        case 404, 409: throw Failure.needsGoogle
        default: throw Failure.transient
        }

        struct Minted: Decodable { var accessToken: String; var expiresIn: Double?; var calendarId: String? }
        guard let minted = try? JSONDecoder().decode(Minted.self, from: data) else { throw Failure.transient }
        let life = max(60, (minted.expiresIn ?? 3600) - 60)
        token = (minted.accessToken, minted.calendarId, Date().addingTimeInterval(life))
        return (minted.accessToken, minted.calendarId)
    }

    // MARK: the calendars

    /// Every calendar on the account, unfiltered: the fetch reads the
    /// chosen ones, and Settings lists the ones there are to choose from.
    private func calendarList(_ bearer: String) async throws -> [GoogleEvents.CalendarEntry] {
        struct Page: Decodable { var items: [GoogleEvents.CalendarEntry]?; var nextPageToken: String? }
        var out: [GoogleEvents.CalendarEntry] = []
        var pageToken: String?
        repeat {
            var q = [URLQueryItem(name: "maxResults", value: "250")]
            if let pageToken { q.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: Page = try await get("users/me/calendarList", q, bearer)
            out += page.items ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        return out
    }

    // MARK: the events

    private func events(in calendar: GoogleEvents.CalendarEntry, _ bearer: String,
                        start: Date, end: Date) async throws -> [Meeting]
    {
        struct Page: Decodable { var items: [GoogleEvents.Event]?; var nextPageToken: String? }
        let stamp = ISO8601DateFormatter()
        var out: [Meeting] = []
        var pageToken: String?
        repeat {
            var q = [
                URLQueryItem(name: "timeMin", value: stamp.string(from: start)),
                URLQueryItem(name: "timeMax", value: stamp.string(from: end)),
                /* One row per occurrence, which is what a day draws. */
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "maxResults", value: "2500"),
            ]
            if let pageToken { q.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: Page = try await get("calendars/\(Self.pathEncode(calendar.id))/events", q, bearer)
            for e in page.items ?? [] {
                for var m in GoogleEvents.meetings(from: e, calendarTitle: calendar.title) {
                    m.calendarID = calendar.id
                    out.append(m)
                }
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return out
    }

    /// A calendar id is an address, often with a `#` in it; every
    /// character outside the unreserved set is escaped for the path.
    static func pathEncode(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    // MARK: the wire

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem],
                                   _ bearer: String) async throws -> T
    {
        guard var parts = URLComponents(string: "https://www.googleapis.com/calendar/v3/" + path)
        else { throw Failure.transient }
        parts.queryItems = query
        guard let url = parts.url else { throw Failure.transient }

        var request = URLRequest(url: url)
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")

        let (data, response) = try await load(request)
        switch response.statusCode {
        case 200:
            guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw Failure.transient }
            return value
        /* 403 is a grant without the read scope. 401 on a token we minted
           a minute ago is a grant Google has since dropped. */
        case 401, 403:
            token = nil
            throw Failure.needsGoogle
        default:
            throw Failure.transient
        }
    }

    private func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await http.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.transient }
            return (data, http)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.transient
        }
    }
}
