/* ============================================================
   Checks/wav.swift — the recording, byte for byte against voice.js

   Not an Xcode target. A `swiftc` program that compiles this repo's
   `MyADHD/Voice/WAV.swift` — the app target's own source, not a copy —
   and then loads the REAL `voice.js` from the web checkout into a
   JavaScriptCore context and runs both writers over the same samples.

       Checks/wav.sh

   What it evaluates is the arithmetic slice of voice.js and nothing
   else, cut out of the file on disk by line number every run:

     line   54        RATE
     lines 222-234    resample   — box averaging, not point sampling
     lines 240-262    toWav      — the 44-byte RIFF header and PCM16
     lines 278-285    heardAnything — the 0.01 silence floor

   A line range alone is a silent trap: insert forty lines above
   `toWav` and the range slides onto whatever now sits there, and the
   run either throws something unreadable or — worse — evaluates a
   slice that no longer holds the rule under test and reports a clean
   pass. Each slice is anchored by content, so a moved function fails
   the check by name instead of by accident.

   ## Why this check exists at all

   The endpoint takes the bytes and hands them to a speech model. A
   header field written into the wrong offset, or a float rounded onto
   an int16 a different way, does not crash anything: it produces a
   file that still opens, still plays, and transcribes slightly worse
   than the web app does from the same voice. Nothing else in this
   repo would ever say so.

   ## What is compared

     1. the header, parsed field by field — RIFF / WAVE / fmt  / PCM /
        mono / 16 kHz / 32000 bytes per second / block align 2 / 16
        bits / a `data` size that matches the sample count
     2. every byte of the file, against what voice.js produces from the
        identical Float32 samples
     3. `heardAnything`, over silence, near-silence and quiet-but-real
     4. that `VoiceRecorder.stop()` cannot reach `WAV.encode` without
        passing that floor — a source-level assertion, because the
        recorder itself needs AVAudioSession and cannot be built for
        the Mac this runs on

   The samples cross into JavaScriptCore as `Double`s, which is exact:
   every `Float` is a `Double`, and `new Float32Array(...)` rounds each
   one straight back to the `Float` it came from.
   ============================================================ */

import Foundation
import JavaScriptCore

// MARK: -

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ what: String) { description = what }
}

// MARK: - the samples

enum Tone {

    /// 2 seconds of 440 Hz at 48 kHz — the phone's rate, the tuning
    /// fork's pitch, and a length that puts a whole number of hardware
    /// buffers through the resampler.
    static func sine(seconds: Double, hz: Double, rate: Double, amplitude: Double = 0.8) -> [Float] {
        let count = Int(seconds * rate)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = Float(amplitude * sin(2 * Double.pi * hz * Double(i) / rate))
        }
        return out
    }

    /// -1.2 to 1.2 in a straight line. Everything outside ±1 has to be
    /// clamped, and the two ends of the range are where the asymmetric
    /// scale (0x8000 down, 0x7fff up) shows.
    static func ramp(count: Int) -> [Float] {
        (0..<count).map { Float(-1.2 + 2.4 * Double($0) / Double(count - 1)) }
    }

    static func flat(_ value: Float, count: Int) -> [Float] {
        [Float](repeating: value, count: count)
    }
}

// MARK: - the JavaScript side

struct WebSide {

    private let probe: JSValue
    private let heard: JSValue

    /// The four slices of voice.js, by 1-based line number.
    static let rateLines = 54...54
    static let resampleLines = 222...234
    static let wavLines = 240...262
    static let heardLines = 278...285

    /// What each slice has to still contain.
    static let rateAnchors = ["const RATE"]
    static let resampleAnchors = ["function resample("]
    static let wavAnchors = ["function toWav(", "tag(0, 'RIFF')", "tag(36, 'data')"]
    static let heardAnchors = ["function heardAnything(", "0.01"]

    let rate: Int

    init(voiceJS path: String) throws {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw Failure("cannot read \(path)")
        }
        let lines = source.components(separatedBy: "\n")
        func slice(_ r: ClosedRange<Int>, _ anchors: [String]) throws -> String {
            guard r.upperBound <= lines.count else {
                throw Failure("voice.js has \(lines.count) lines, needs \(r.upperBound)")
            }
            let body = lines[(r.lowerBound - 1)...(r.upperBound - 1)].joined(separator: "\n")
            for anchor in anchors where !body.contains(anchor) {
                throw Failure("voice.js \(r) no longer contains `\(anchor)` — the line "
                              + "numbers have drifted from their source; re-cut the slice")
            }
            return body
        }

        guard let ctx = JSContext() else { throw Failure("no JSContext") }
        var trouble: String?
        ctx.exceptionHandler = { _, e in trouble = e?.toString() ?? "unknown" }

        func run(_ js: String, _ what: String) throws {
            trouble = nil
            ctx.evaluateScript(js)
            if let trouble { throw Failure("\(what): \(trouble)") }
        }

        try run(try slice(Self.rateLines, Self.rateAnchors), "voice.js \(Self.rateLines)")
        try run(try slice(Self.resampleLines, Self.resampleAnchors),
                "voice.js \(Self.resampleLines)")
        try run(try slice(Self.wavLines, Self.wavAnchors), "voice.js \(Self.wavLines)")
        try run(try slice(Self.heardLines, Self.heardAnchors), "voice.js \(Self.heardLines)")
        try run(Self.postlude, "postlude")

        /* `const` at the top level of a script is a lexical binding, not
           a property of the global object, so it has to be evaluated
           rather than looked up. */
        guard let r = ctx.evaluateScript("RATE"), r.isNumber else {
            throw Failure("RATE did not define")
        }
        self.rate = Int(r.toInt32())

        guard let p = ctx.objectForKeyedSubscript("__wav"), !p.isUndefined,
              let h = ctx.objectForKeyedSubscript("__heard"), !h.isUndefined
        else { throw Failure("the probes did not define") }
        self.probe = p
        self.heard = h
    }

    /// There is no `btoa` in JavaScriptCore, so the bytes come back
    /// base64-encoded by hand. A single string comparison is the whole
    /// file at once; the decode below names the offset when it differs.
    private static let postlude = """
    function __b64(bytes) {
      const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      let s = '';
      for (let i = 0; i < bytes.length; i += 3) {
        const b0 = bytes[i], b1 = bytes[i + 1], b2 = bytes[i + 2];
        s += A[b0 >> 2];
        s += A[((b0 & 3) << 4) | ((b1 === undefined ? 0 : b1) >> 4)];
        s += (b1 === undefined) ? '=' : A[((b1 & 15) << 2) | ((b2 === undefined ? 0 : b2) >> 6)];
        s += (b2 === undefined) ? '=' : A[b2 & 63];
      }
      return s;
    }

    function __wav(samples, from, to) {
      const pcm = resample(new Float32Array(samples), from, to);
      return JSON.stringify({
        frames: pcm.length,
        b64: __b64(toWav(pcm, to)),
        heard: heardAnything(pcm),
      });
    }

    function __heard(samples) {
      return heardAnything(new Float32Array(samples));
    }
    """

    struct Reading {
        var frames: Int
        var bytes: Data
        var heard: Bool
    }

    /// `resample` then `toWav`, as the web computes them.
    func wav(_ samples: [Float], from: Double, to: Double) throws -> Reading {
        let doubles = samples.map { Double($0) }
        guard let out = probe.call(withArguments: [doubles, from, to]), !out.isUndefined,
              let text = out.toString(),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let frames = json["frames"] as? Int,
              let b64 = json["b64"] as? String,
              let heardIt = json["heard"] as? Bool,
              let bytes = Data(base64Encoded: b64)
        else { throw Failure("__wav returned nothing usable") }
        return Reading(frames: frames, bytes: bytes, heard: heardIt)
    }

    /// `heardAnything` on its own, with no resample in front of it.
    func heardAnything(_ samples: [Float]) throws -> Bool {
        let doubles = samples.map { Double($0) }
        guard let out = heard.call(withArguments: [doubles]), out.isBoolean else {
            throw Failure("__heard returned nothing usable")
        }
        return out.toBool()
    }
}

// MARK: - reading a header back

struct Header {
    var riff: String
    var riffSize: UInt32
    var wave: String
    var fmtTag: String
    var fmtSize: UInt32
    var format: UInt16
    var channels: UInt16
    var sampleRate: UInt32
    var byteRate: UInt32
    var blockAlign: UInt16
    var bits: UInt16
    var dataTag: String
    var dataSize: UInt32

    init(_ d: Data) throws {
        guard d.count >= 44 else { throw Failure("only \(d.count) bytes, a header is 44") }
        func text(_ o: Int) -> String { String(decoding: d[o..<(o + 4)], as: UTF8.self) }
        func u32(_ o: Int) -> UInt32 {
            UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
        }
        func u16(_ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }

        riff = text(0); riffSize = u32(4); wave = text(8)
        fmtTag = text(12); fmtSize = u32(16)
        format = u16(20); channels = u16(22)
        sampleRate = u32(24); byteRate = u32(28)
        blockAlign = u16(32); bits = u16(34)
        dataTag = text(36); dataSize = u32(40)
    }
}

// MARK: - the run

struct Report {
    private(set) var bad = 0

    mutating func ok(_ what: String) { print("  ok    \(what)") }

    mutating func fail(_ what: String, _ why: String) {
        print("  FAIL  \(what): \(why)")
        bad += 1
    }

    mutating func expect(_ what: String, _ got: some Equatable, _ want: some Equatable) {
        if "\(got)" == "\(want)" { ok("\(what) = \(want)") }
        else { fail(what, "\(got), expected \(want)") }
    }
}

// MARK: - the run

@main
enum Check {

    static func main() {
    let args = CommandLine.arguments
    func option(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    let voicePath = option("--voice-js")
        ?? "/Users/User/Desktop/Claude Code/My.adhd/voice.js"
    let recorderPath = option("--recorder") ?? "MyADHD/Voice/VoiceRecorder.swift"

    var report = Report()

    do {
        let web = try WebSide(voiceJS: voicePath)
        print("voice.js: \(voicePath)")
        report.expect("RATE", web.rate, 16_000)
        let RATE = Double(web.rate)

        // ---- 1. the headline case: 2 s of 440 Hz at 48 kHz -------------
        print("\n2 s of 440 Hz at 48 kHz, resampled to \(web.rate)")

        let tone = Tone.sine(seconds: 2, hz: 440, rate: 48_000)
        report.expect("input frames", tone.count, 96_000)

        let pcm = WAV.resample(tone, from: 48_000, to: RATE)
        report.expect("resampled frames", pcm.count, 32_000)

        let bytes = WAV.encode(pcm, rate: web.rate)
        report.expect("file size", bytes.count, 44 + 32_000 * 2)

        let head = try Header(bytes)
        report.expect("RIFF", head.riff, "RIFF")
        report.expect("riff size", head.riffSize, UInt32(36 + 64_000))
        report.expect("WAVE", head.wave, "WAVE")
        report.expect("fmt tag", head.fmtTag, "fmt ")
        report.expect("fmt size", head.fmtSize, UInt32(16))
        report.expect("format (1 = PCM)", head.format, UInt16(1))
        report.expect("channels (mono)", head.channels, UInt16(1))
        report.expect("sample rate", head.sampleRate, UInt32(web.rate))
        report.expect("byte rate", head.byteRate, UInt32(web.rate * 2))
        report.expect("block align", head.blockAlign, UInt16(2))
        report.expect("bits", head.bits, UInt16(16))
        report.expect("data tag", head.dataTag, "data")
        report.expect("data size", head.dataSize, UInt32(64_000))

        // ---- 2. byte for byte against voice.js -------------------------
        print("\nagainst voice.js's own writer")

        /// One case: run both sides and compare every byte.
        func compare(_ what: String, _ samples: [Float], from: Double, to: Double) {
            do {
                let mine = WAV.encode(WAV.resample(samples, from: from, to: to), rate: Int(to))
                let theirs = try web.wav(samples, from: from, to: to)

                guard mine.count == theirs.bytes.count else {
                    report.fail(what, "\(mine.count) bytes, voice.js wrote \(theirs.bytes.count)")
                    return
                }
                let a = [UInt8](mine), b = [UInt8](theirs.bytes)
                for i in 0..<a.count where a[i] != b[i] {
                    report.fail(what, "byte \(i) is \(a[i]), voice.js wrote \(b[i])")
                    return
                }
                report.ok("\(what) — \(a.count) bytes identical")
            } catch {
                report.fail(what, "\(error)")
            }
        }

        compare("440 Hz, 48000 → 16000", tone, from: 48_000, to: RATE)
        compare("440 Hz, 44100 → 16000 (fractional ratio)",
                Tone.sine(seconds: 1, hz: 440, rate: 44_100), from: 44_100, to: RATE)
        compare("440 Hz, 16000 → 16000 (identity path)",
                Tone.sine(seconds: 1, hz: 440, rate: 16_000), from: RATE, to: RATE)
        compare("full-scale 1 kHz (clipping the ends)",
                Tone.sine(seconds: 0.5, hz: 1_000, rate: 48_000, amplitude: 1.0),
                from: 48_000, to: RATE)
        compare("a ramp through ±1.2 (the clamp and the asymmetric scale)",
                Tone.ramp(count: 48_000), from: 48_000, to: RATE)
        compare("exactly -1 and +1", Tone.flat(-1, count: 300) + Tone.flat(1, count: 300),
                from: 48_000, to: RATE)
        compare("two samples, fewer than one output frame",
                [0.5, -0.5], from: 48_000, to: RATE)
        compare("silence", Tone.flat(0, count: 48_000), from: 48_000, to: RATE)

        // ---- 3. the floor ---------------------------------------------
        print("\nthe 0.01 floor — what is never uploaded")

        let floorCases: [(String, [Float], Bool)] = [
            ("digital silence", Tone.flat(0, count: 16_000), false),
            ("a tapped button (1e-6)", Tone.flat(1e-6, count: 16_000), false),
            ("a hold in a pocket (0.008)",
             Tone.sine(seconds: 1, hz: 440, rate: 16_000, amplitude: 0.008), false),
            ("exactly at the floor (0.01)", Tone.flat(0.01, count: 16_000), false),
            ("just over it (0.0101)", Tone.flat(0.0101, count: 16_000), true),
            ("quiet but real (0.05)",
             Tone.sine(seconds: 1, hz: 440, rate: 16_000, amplitude: 0.05), true),
            ("negative only (-0.4)", Tone.flat(-0.4, count: 16_000), true),
            ("nothing at all", [], false),
        ]

        for (what, samples, want) in floorCases {
            let mine = WAV.heardAnything(samples)
            do {
                let theirs = try web.heardAnything(samples)
                if mine != want {
                    report.fail("floor: \(what)", "heardAnything = \(mine), expected \(want)")
                } else if mine != theirs {
                    report.fail("floor: \(what)", "\(mine) here, \(theirs) in voice.js")
                } else {
                    report.ok("floor: \(what) → \(mine ? "uploaded" : "never uploaded")")
                }
            } catch {
                report.fail("floor: \(what)", "\(error)")
            }
        }

        // ---- 4. the floor is actually in the upload path ----------------
        /* `WAV.heardAnything` agreeing with voice.js proves the rule, not
           that anything obeys it. The recorder needs AVAudioSession and
           cannot be built for a Mac, so the guard is read rather than run:
           `stop()` has exactly one call to `WAV.encode`, and the floor is
           checked above it with a `return` in between. */
        print("\nthe floor is the only way to WAV.encode")
        do {
            let source = try String(contentsOfFile: recorderPath, encoding: .utf8)
            let guardLine = "if pcm.isEmpty || !WAV.heardAnything(pcm) {"
            let encodeLine = "WAV.encode(pcm, rate: Self.rate)"

            let encodes = source.components(separatedBy: encodeLine).count - 1
            report.expect("calls to WAV.encode in \(recorderPath)", encodes, 1)

            if let g = source.range(of: guardLine), let e = source.range(of: encodeLine) {
                if g.lowerBound < e.lowerBound {
                    let between = source[g.upperBound..<e.lowerBound]
                    if between.contains("return VoiceResult(text: \"\", source: opened ? .none : .noMic") {
                        report.ok("the floor returns before the encode")
                    } else {
                        report.fail("the floor", "no early return between the guard and the encode")
                    }
                } else {
                    report.fail("the floor", "the guard is below the encode")
                }
            } else {
                report.fail("the floor", "`\(guardLine)` is no longer in \(recorderPath)")
            }
        } catch {
            report.fail("the floor", "\(error)")
        }
    } catch {
        print("  FAIL  \(error)")
        exit(1)
    }

    print("")
    if report.bad == 0 {
        print("wav: clean")
        exit(0)
    } else {
        print("wav: \(report.bad) divergence\(report.bad == 1 ? "" : "s")")
        exit(1)
    }

}
}
