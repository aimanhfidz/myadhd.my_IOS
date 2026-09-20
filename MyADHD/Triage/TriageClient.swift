/* ============================================================
   TriageClient — POST /api/triage, both modes

   `parseWithAI` (app.js:618-634) and `breakDown` (app.js:1846-1873),
   with the same request bodies and the same failure conditions. The
   route is unauthenticated: no Authorization header, no api key, no
   Supabase session. `maxDuration` on the serverless function is 60
   seconds, so the client waits 60 and not the URLSession default.

   **The three throw sites are the product.** app.js falls back to the
   offline parser on any of them, and an app that fell back on only
   two would sit on a spinner until the socket gave up:

     1. the request never completed  — `fetch` rejected;
     2. the response was not 2xx     — `!res.ok`;
     3. `tasks` was not a non-empty array — which includes the model
        answering `{"tasks": []}` with a perfectly good 200, because
        an empty answer to a real dump is a failure to sort it.

   The body is built with `WebJSON` rather than `JSONEncoder` so it is
   byte-for-byte what the browser sends, key order included. `today`
   is the client's LOCAL day key (`dayKey()`), never a UTC date: the
   route only falls back to its own UTC date when ours does not look
   like a day, and a user in Kuala Lumpur would be sorted against
   yesterday for most of the working day.

   Nothing here touches the store. The caller decides what to do with
   the tasks — see the dedupe and `pendingQuadrant` in `triage()`.
   ============================================================ */

import Foundation

// MARK: -

enum TriageMode: String {
    case triage
    case breakdown
}

/// Why a call failed, carrying the message app.js puts on the Error so
/// the lists' `resortProblem` copy can be chosen from the same facts.
enum TriageError: Error, CustomStringConvertible {

    /// The request never completed. `fetch` rejects with a TypeError
    /// here, which is the branch that reads "Cannot reach the backend
    /// from here."
    case transport(Error)

    /// `!res.ok`. The status is what `/returned (\d+)/` reads back.
    case status(Int, TriageMode)

    /// The body was not JSON. A SyntaxError in the browser, which
    /// falls to the last branch of `resortProblem`.
    case malformed(Error)

    /// `tasks` missing, not an array, or empty.
    case noTasks

    /// `steps` missing, not an array, or empty.
    case noSteps

    /// `err.message`, verbatim.
    var message: String {
        switch self {
        case .transport(let e): return (e as NSError).localizedDescription
        case .status(let code, .triage): return "triage endpoint returned \(code)"
        case .status(let code, .breakdown): return "status \(code)"
        case .malformed(let e): return (e as NSError).localizedDescription
        case .noTasks: return "no tasks in response"
        case .noSteps: return "no steps"
        }
    }

    var description: String { message }

    /// `err instanceof TypeError` — the browser's shape for a request
    /// that never left.
    var isTransport: Bool {
        if case .transport = self { return true }
        return false
    }

    /// The status the sorter answered with, or nil. This is the typed
    /// form of `/returned (\d+)/.exec(err.message)`.
    var statusCode: Int? {
        if case .status(let code, _) = self { return code }
        return nil
    }
}

// MARK: -

struct TriageClient {

    /// What a dump that was spoken carries with it. `source` matters
    /// as much as the flag: a transcript from the audio model is
    /// already repaired and wants leaving alone, and one from the
    /// browser engine is the mangled kind that needs reading back
    /// phonetically.
    struct Spoken {
        var source: String
        var lang: String?
        var vocab: [String]

        init(source: String, lang: String?, vocab: [String]) {
            self.source = source
            self.lang = lang
            self.vocab = vocab
        }
    }

    // MARK: where it points

    /// One host, taken from `AppConfig.home` so there is no second
    /// copy of it to drift.
    static let endpoint: URL = URL(string: "/api/triage", relativeTo: AppConfig.home)!.absoluteURL

    /// `maxDuration` on api/triage.js is 60, so anything longer is the
    /// function having already given up.
    static let timeout: TimeInterval = 60

    static let defaultSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = TriageClient.timeout
        c.timeoutIntervalForResource = TriageClient.timeout
        /* The web has no `navigator.onLine` gate on triage and neither
           does this: a request is always allowed to try, and fails
           into the offline parser rather than sitting in a queue
           waiting for a path that may never come. */
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    var session: URLSession
    var endpoint: URL

    init(session: URLSession = TriageClient.defaultSession,
         endpoint: URL = TriageClient.endpoint)
    {
        self.session = session
        self.endpoint = endpoint
    }

    // MARK: - mode 'triage' (app.js:618-634)

    /// The model's reading of a dump, already through `normalizeTask`.
    ///
    /// Throws on all three of app.js's conditions, so the caller's
    /// `catch` is the offline parser.
    func triage(text: String,
                today: String = WebDates.dayKey(),
                spoken: Spoken? = nil,
                now: Date = Date()) async throws -> [TaskItem]
    {
        let body = Self.triageBody(text: text, today: today, spoken: spoken)
        let data = try await send(body, mode: .triage)

        let parsed: JSONValue
        do { parsed = try JSONValue.parse(data) } catch { throw TriageError.malformed(error) }

        guard let tasks = parsed["tasks"]?.arrayValue, !tasks.isEmpty else {
            throw TriageError.noTasks
        }
        return tasks.map { Normalize.task($0, now: now) }
    }

    /// The request body, exactly as `JSON.stringify` writes it:
    /// `mode`, `text`, `today`, and then the spoken trio only when a
    /// dump was actually spoken.
    ///
    /// `text` is NOT trimmed or capped here. app.js trims in `triage()`
    /// before it ever gets this far, and the 8000-character cap is the
    /// route's own — copying it into the client would mean two places
    /// to change it.
    static func triageBody(text: String, today: String, spoken: Spoken?) -> String {
        var o = JSONObject()
        o["mode"] = .string(TriageMode.triage.rawValue)
        o["text"] = .string(text)
        o["today"] = .string(today)
        if let spoken {
            o["spoken"] = .string(spoken.source)
            // `spokenDump = {source, lang}` and `lang` is explicitly
            // null when the engine did not name one, so the key is
            // always written — it is null, not absent.
            o["lang"] = spoken.lang.map { JSONValue.string($0) } ?? .null
            o["vocab"] = .array(spoken.vocab.map { JSONValue.string($0) })
        }
        return WebJSON.encode(o)
    }

    // MARK: - mode 'breakdown' (app.js:1846-1873)

    /// Three to six steps for one task that is too big to start.
    ///
    /// `firstStep` comes back only when the model sent one, and it is
    /// deliberately uncapped: app.js writes `String(data.firstStep)`
    /// with no `.slice(0, 240)`, unlike `normalizeTask`.
    func breakdown(task title: String) async throws -> (firstStep: String?, steps: [String]) {
        var o = JSONObject()
        o["mode"] = .string(TriageMode.breakdown.rawValue)
        o["task"] = .string(title)
        let data = try await send(WebJSON.encode(o), mode: .breakdown)

        let parsed: JSONValue
        do { parsed = try JSONValue.parse(data) } catch { throw TriageError.malformed(error) }

        guard let steps = parsed["steps"]?.arrayValue, !steps.isEmpty else {
            throw TriageError.noSteps
        }
        let first = parsed["firstStep"]
        return (first?.isTruthy == true ? Normalize.jsString(first) : nil,
                steps.prefix(7).map { Normalize.jsString($0) })
    }

    // MARK: - the one request

    private func send(_ body: String, mode: TriageMode) async throws -> Data {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        req.timeoutInterval = Self.timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw TriageError.transport(error)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // `res.ok` is 200-299 and nothing else.
        guard (200...299).contains(code) else { throw TriageError.status(code, mode) }
        return data
    }
}
