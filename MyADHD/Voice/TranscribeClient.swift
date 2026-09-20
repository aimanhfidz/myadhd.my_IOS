/* ============================================================
   MyADHD/Voice/TranscribeClient.swift — POST /api/transcribe

   `transcribe(pcm, seconds, vocab)` (voice.js:357-376) and the route it
   talks to (api/transcribe.js, inventory §3.3). Unauthenticated: no
   Authorization header, no api key, no Supabase session.

   **The WAV is the body and nothing else is.** It used to go up as
   base64 inside JSON, which cost a third of the request budget to say
   the same thing — the 130-second cap is 4.16 MB of raw bytes against
   the route's `MAX_BYTES` of 4,400,000, and base64 would put it over.
   What is left to send rides in a header: how long it was, and the
   names this person uses, encoded because some of those names are not
   ASCII and a header is Latin-1.

   **It never throws, and that is the feature.** voice.js catches
   everything `fetch` can do and hands back whatever the browser engine
   heard instead; there is no browser engine here (design §4 decision 2
   — no on-device recogniser, which would need a second permission and
   an Info.plist key this app deliberately does not have), so a failure
   hands back an empty string and `MicButton` says "didn't catch
   anything that time". With no network that is the *normal* path, not
   an error path: the hold still works, the level ring still moves, and
   nothing that was typed before the hold is touched.

   `WebJSON` builds the meta rather than `JSONEncoder` so the header is
   byte-for-byte what the browser sends, key order included.
   ============================================================ */

import Foundation

// MARK: -

struct TranscribeClient {

    /// What came back. An empty `text` is every kind of failure at once
    /// — offline, 413, 502, a model that heard no speech — because the
    /// caller treats them identically and voice.js gives it no way to
    /// tell them apart either.
    struct Reading {
        var text: String
        var lang: String?

        static let nothing = Reading(text: "", lang: nil)
    }

    /// One host, taken from `AppConfig.home` so there is no second copy
    /// of it to drift.
    static let endpoint: URL =
        URL(string: "/api/transcribe", relativeTo: AppConfig.home)!.absoluteURL

    /// The route gives Gemini `AbortSignal.timeout(25000)` and allows
    /// itself one fallback attempt on a smaller model, so a live request
    /// can legitimately take the better part of a minute. Anything past
    /// that is the function having already given up.
    static let timeout: TimeInterval = 60

    /// `vocab.slice(0, 40)`.
    static let vocabCap = 40

    static let defaultSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = TranscribeClient.timeout
        c.timeoutIntervalForResource = TranscribeClient.timeout
        /* Never queued. Offline is a real answer here — the recording is
           already thrown away by the time this returns, and a request
           parked waiting for a path that may never come would hold the
           mic in `writing it down…` for as long as the app is open. */
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    var session: URLSession
    var endpoint: URL

    init(session: URLSession = TranscribeClient.defaultSession,
         endpoint: URL = TranscribeClient.endpoint)
    {
        self.session = session
        self.endpoint = endpoint
    }

    // MARK: - the round trip

    func transcribe(wav: Data, seconds: Double, vocab: [String]) async -> Reading {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.meta(seconds: seconds, vocab: vocab),
                     forHTTPHeaderField: "X-Voice-Meta")
        req.httpBody = wav
        req.timeoutInterval = Self.timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            // `fetch` rejected. The hold is not lost; the transcript is.
            return .nothing
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // `res.ok` is 200-299 and nothing else.
        guard (200...299).contains(code) else { return .nothing }

        guard let parsed = try? JSONValue.parse(data) else { return .nothing }
        /* `String(data.text || '')` — a missing, null or empty text is
           an empty string, and `clean` then makes it the same empty
           string it would have been anyway. `lang` is kept only when
           truthy; the route already caps it at 40 characters. */
        let text = Self.clean(parsed["text"]?.stringValue ?? "")
        let lang = parsed["lang"].flatMap { $0.isTruthy ? $0.stringValue : nil }
        return Reading(text: text, lang: lang)
    }

    // MARK: - the header

    /// `base64(utf8(JSON.stringify({seconds, vocab})))`, in that key
    /// order.
    ///
    /// `Math.round` in JavaScript is round-half-up — toward +Infinity,
    /// not away from zero — which is `floor(x + 0.5)`. Seconds are never
    /// negative here, but writing the rule down is cheaper than
    /// remembering why it did not matter.
    static func meta(seconds: Double, vocab: [String]) -> String {
        var o = JSONObject()
        o["seconds"] = .int(Int((seconds + 0.5).rounded(.down)))
        o["vocab"] = .array(vocab.prefix(vocabCap).map { JSONValue.string($0) })
        return Data(WebJSON.encode(o).utf8).base64EncodedString()
    }

    // MARK: - text

    /// `clean(s)` (voice.js:351-353): `replace(/\s+/g, ' ')` then
    /// `replace(/^\s+/, '')`.
    ///
    /// Engines run words together across restarts and leave leading
    /// spaces on each leg. One space between things, none at the front.
    /// `JSText.trimScalars` is JavaScript's `\s` — it includes U+FEFF,
    /// which Foundation's `.whitespacesAndNewlines` does not, and
    /// excludes the zero-width joiners it does.
    static func clean(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var runOfSpace = false
        for scalar in s.unicodeScalars {
            if JSText.trimScalars.contains(scalar) {
                runOfSpace = true
                continue
            }
            if runOfSpace {
                // `^\s+` is dropped rather than collapsed to one space.
                if !out.isEmpty { out.append(" ") }
                runOfSpace = false
            }
            out.append(scalar)
        }
        // A trailing run collapses to one space and stays: `/^\s+/` is
        // anchored at the front and nothing trims the end.
        if runOfSpace && !out.isEmpty { out.append(" ") }
        return String(out)
    }
}
