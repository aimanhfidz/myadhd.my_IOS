/* ============================================================
   MyADHD/Net/FeedbackClient.swift — POST /api/feedback

   `sendFeedback` (app.js:2679-2724), inventory §1.15. One route, one
   field, no authentication: the note carries no name, no account and no
   email, and that is the promise printed under the box.

   **A 429 is a success.** The server keeps its own one-a-day and answers
   429 when it already has one from this address today. Either way this
   device is spent for the day, so both branches mark `sentFeedbackOn`
   and both show the thanks card — only the sentence on it differs
   (app.js:2702-2709). Treating 429 as a failure would leave the box open
   and invite somebody to type the same note again into a door that is
   already shut.

   **The day is UTC on both sides.** This client does not touch the
   store; `AppStore.markFeedbackSent()` stamps `WebDates.utcDay()`. The
   trap is real — the local day would hand anybody east of UTC a second
   go in the evening and would disagree with the index the server counts
   on (app.js:2650-2656, the comment above `utcDay`).

   **A request that never left has no words of its own.** `fetch`
   rejecting is a TypeError whose message is `Failed to fetch` on Chrome
   and `Load failed` on Safari, and `URLError` here is no better. Neither
   is a sentence to put in front of somebody who has just written you a
   note, so the reason goes no further than `.transport`'s payload and
   the copy says `no signal. Your note is still here` instead.
   ============================================================ */

import Foundation

/// The three ways this can fail, each carrying the words app.js puts on
/// the Error — which is what the toast interpolates (`Could not send —
/// ${err.message}.`).
enum FeedbackError: Error, CustomStringConvertible {

    /// The request never completed. The underlying error is kept for a
    /// log line and never shown.
    case transport(Error)

    /// 503 — the route answered, and said it is not configured.
    case notConfigured

    /// Any other non-2xx.
    case server(Int)

    var message: String {
        switch self {
        case .transport:    return Copy.Feedback.noSignal    // app.js:2696
        case .notConfigured: return Copy.Feedback.notWired   // app.js:2714
        case .server:       return Copy.Feedback.broke       // app.js:2715
        }
    }

    var description: String { message }
}

struct FeedbackClient {

    /// Which of the two thanks lines is owed.
    enum Outcome {
        /// 2xx — the note is in.
        case sent
        /// 429 — the server already had one from here today.
        case alreadyToday
    }

    /// One host, taken from `AppConfig.home` so there is no second copy
    /// of it to drift.
    static let endpoint: URL = URL(string: "/api/feedback", relativeTo: AppConfig.home)!.absoluteURL

    /// api/feedback.js declares no `maxDuration`, so it runs on the
    /// platform default of 10 s. Thirty is that with room for a slow
    /// hand-off, and well short of anybody deciding the app has hung.
    static let timeout: TimeInterval = 30

    static let defaultSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = FeedbackClient.timeout
        c.timeoutIntervalForResource = FeedbackClient.timeout
        /* The web has no `navigator.onLine` gate on this and neither does
           this: the request is always allowed to try, and fails into a
           toast that says the note is still in the box. */
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    var session: URLSession
    var endpoint: URL

    init(session: URLSession = FeedbackClient.defaultSession,
         endpoint: URL = FeedbackClient.endpoint)
    {
        self.session = session
        self.endpoint = endpoint
    }

    /// `JSON.stringify({ body })` — one key, and the body already
    /// trimmed by the caller, exactly as app.js:2680 trims it before the
    /// length test.
    static func requestBody(_ body: String) -> String {
        var o = JSONObject()
        o["body"] = .string(body)
        return WebJSON.encode(o)
    }

    func send(_ body: String) async throws -> Outcome {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.requestBody(body).utf8)
        req.timeoutInterval = Self.timeout

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: req)
        } catch {
            throw FeedbackError.transport(error)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // `res.ok` is 200-299 and nothing else.
        if (200...299).contains(code) { return .sent }
        if code == 429 { return .alreadyToday }
        if code == 503 { throw FeedbackError.notConfigured }
        throw FeedbackError.server(code)
    }
}
