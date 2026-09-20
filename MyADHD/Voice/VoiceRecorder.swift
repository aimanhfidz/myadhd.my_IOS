/* ============================================================
   MyADHD/Voice/VoiceRecorder.swift — hold to talk, natively

   `window.Voice` (voice.js), minus the one part of it that cannot come
   across. Design §3.4, inventory §1.3.

   The thought you have on the bus is gone by the time you have found a
   keyboard. Typing is the narrowest part of the funnel in an app whose
   whole loop is "get it out of your head", so there is a second way in.

   Two things it does that ordinary dictation does not, both kept:

   **It does not stop for silence.** A dump is "the rent thing... uh...
   and the car insurance" with five seconds in the middle, and every
   dictation engine treats five seconds of nothing as the end of the
   sentence. The only thing that ends a recording here is letting go of
   the button.

   **It never loses the hold.** Nothing in `stop()` throws. If the
   network is gone the upload fails and the answer is an empty string,
   and `MicButton` says so without touching a word of what was already
   in the box.

   ## What did not come across, and why

   voice.js runs the browser's `SpeechRecognition` alongside the
   recording so there is rough text in the box while you are still
   talking. There is no equivalent here and there is deliberately not
   going to be one: `SFSpeechRecognizer` is a second permission and an
   `NSSpeechRecognitionUsageDescription` whose absence from Info.plist
   is a decision with its own comment beside it (design §4, decision 2 —
   "ship without one"). So `onText` does not exist, the level ring is
   the only thing that moves during a hold, and `source` can be `.model`
   or `.none` or `.noMic` but never `.browser`.

   That is exactly what an iPhone gets from the web app today — the home
   screen install has no `SpeechRecognition` either — so this is the
   behaviour being ported, not a reduction of it.

   ## The numbers

   16-bit mono at 16 kHz is 32 KB a second, and the route this posts to
   takes a 4.4 MB body — so the cap is not a judgement about how long a
   thought should be, it is that number divided by this one. 130 seconds
   is 4.16 MB. The warning lands fifteen seconds before it.

   16 kHz because speech models are trained there and gain nothing
   above it, while the mic hands over 48. `AVAudioEngine` will not
   resample an input tap for us the way a browser `AudioContext` will,
   so the tap takes the hardware rate and `WAV.resample` does the box
   averaging on the way out — three quarters of the upload gone for no
   loss of anything anyone can hear.

   ## Threads

   The tap block runs on a render thread and must not touch this actor.
   It hands its samples to `Reel`, which owns a lock and nothing else,
   and bounces the level back to the main actor for the ring. Everything
   else — `start`, `stop`, `abandon`, the timers — is main-actor only,
   because the one caller is a SwiftUI view.
   ============================================================ */

import AVFoundation
import Foundation

// MARK: - what came back

/// `source` on the result of `Voice.stop()`. The strings are the web's,
/// because `TriageClient.Spoken.source` puts one of them on the wire.
enum VoiceSource: String {
    /// The transcriber heard it. The text is already repaired and triage
    /// is told to leave it alone.
    case model

    /// The browser engine heard it and the transcriber did not. Cannot
    /// happen on this platform — see the header — but it is a value the
    /// server contract still has, so it is still a case.
    case browser

    /// Nothing usable. Either silence, or the upload failed.
    case none

    /// The microphone never opened at all, which wants the opposite
    /// advice from `none`: one is "hold it down and talk", the other is
    /// "we were not allowed to hear you".
    case noMic = "no-mic"
}

struct VoiceResult {
    var text: String
    var source: VoiceSource
    var lang: String?

    static let empty = VoiceResult(text: "", source: .none, lang: nil)
}

/// `onError(why)`. Two reasons, and they pick two different toasts.
enum VoiceFailure: String {
    case denied = "mic-denied"
    case failed
}

/// The `on` object handed to `Voice.start()`.
struct VoiceHooks {
    /// `knownNames()`, read once when the hold starts.
    var vocab: [String] = []

    /// The mic is genuinely open now. Everything between pressing the
    /// button and this is iOS deciding whether to allow a microphone,
    /// which the first time is a dialog and a person reading it.
    var onLive: () -> Void = {}

    /// 0-1, roughly twenty times a second.
    var onLevel: (Double) -> Void = { _ in }

    /// The cap is close.
    var onWarn: () -> Void = {}

    /// The cap was hit. The caller calls `stop()` itself, exactly as
    /// app.js does.
    var onCap: () -> Void = {}

    var onError: (VoiceFailure) -> Void = { _ in }
}

// MARK: - the recorder

@MainActor
@Observable
final class VoiceRecorder {

    /// Speech models are trained at 16 kHz and gain nothing above it.
    static let rate = 16_000

    /// voice.js:64-65.
    static let maxSeconds: Double = 130
    static let warnSeconds: Double = 115

    /// `Voice.available()`. On the web this is "can this browser open a
    /// microphone at all"; here it is "is this build allowed to ask" —
    /// an app with no `NSMicrophoneUsageDescription` is killed by the
    /// system the instant it touches the input node, so a mic button on
    /// one is worse than no mic button.
    ///
    /// `MicButton` is *absent* when this is false, never present and
    /// dimmed. The web hides `#composer-voice` outright for the same
    /// reason: a button that does nothing is a bug report.
    static var available: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") is String
    }

    /// True while a hold is in progress (`Voice.live()`).
    private(set) var isLive = false

    /// The last level the tap reported, for anything that would rather
    /// read a value than take a callback.
    private(set) var level: Double = 0

    private let client: TranscribeClient

    private var hooks = VoiceHooks()

    /// Bumped per hold, so a late result can be dropped.
    private var holdId = 0

    /// The microphone actually got open. The difference between "you
    /// said nothing" and "we were never allowed to hear you".
    private var opened = false

    private var engine: AVAudioEngine?
    private var reel: Reel?

    /// What the hardware actually gave us. `AVAudioEngine` does not take
    /// a requested rate for an input tap the way an `AudioContext` does,
    /// so this is read rather than asked for.
    private var capRate: Double = Double(VoiceRecorder.rate)

    private var warnTimer: Task<Void, Never>?
    private var capTimer: Task<Void, Never>?

    init(client: TranscribeClient = TranscribeClient()) {
        self.client = client
    }

    // MARK: - begin a hold

    /// Returns once the mic is actually open — or once it is known that
    /// it will not be, in which case `onError` has already fired.
    func start(_ on: VoiceHooks) async {
        guard Self.available, !isLive else { return }
        hooks = on
        isLive = true
        opened = false
        level = 0
        holdId += 1
        let id = holdId

        do {
            try await openMic()
        } catch {
            /* Let go during the permission sheet, or another hold began.
               Whatever this was, it belongs to a moment that has gone. */
            if id != holdId { return }
            isLive = false
            closeMic()
            hooks.onError(error is Denied ? .denied : .failed)
            return
        }

        /* Let go while the permission sheet was up. The mic opened into a
           hold that is already over, so shut it again and say nothing. */
        if id != holdId || !isLive {
            closeMic()
            return
        }

        opened = true
        hooks.onLive()

        warnTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.warnSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isLive, self.holdId == id else { return }
            self.hooks.onWarn()
        }
        capTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maxSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isLive, self.holdId == id else { return }
            self.hooks.onCap()          // the caller calls stop() itself
        }
    }

    /// Thrown when the person — or the system — said no. Separate from
    /// every other way opening can fail, because the two want different
    /// advice on screen.
    private struct Denied: Error {}
    private struct Unopenable: Error {}

    private func openMic() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            throw Denied()
        case .undetermined:
            let granted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
            }
            if !granted { throw Denied() }
        default:
            break
        }

        let session = AVAudioSession.sharedInstance()
        /* `.record` and not `.playAndRecord`: this app plays nothing
           while it listens, and `.playAndRecord` would duck whatever the
           person had on. It also rules out `setVoiceProcessingEnabled`,
           which needs the playback half — so the echo cancellation and
           gain control the web asks `getUserMedia` for are whatever the
           input path does on its own. A brain dump is one person holding
           a phone to their face; there is no far end to echo. */
        /* A paired headset is the input a lot of people will actually
           speak into. `.allowBluetoothHFP` is the modern spelling of the
           option that lets one be chosen; on iOS 17 it is the same
           constant `.allowBluetooth` used to be. */
        try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Unopenable() }
        capRate = format.sampleRate

        let reel = Reel()
        reel.onLevel = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.isLive else { return }
                self.level = value
                self.hooks.onLevel(value)
            }
        }

        /* 2048 frames, the same buffer the web's worklet fills before it
           posts. The render quantum is far smaller than that at both
           ends, and twenty-odd messages a second to draw one ring is
           already more than the ring can show. */
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            reel.took(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Unopenable()
        }

        self.engine = engine
        self.reel = reel
    }

    private func closeMic() {
        warnTimer?.cancel(); warnTimer = nil
        capTimer?.cancel(); capTimer = nil

        reel?.close()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil

        /* Deactivating is what puts out the orange dot. Leaving the
           session up between holds would shave a few milliseconds off
           the next one and leave every user of this app with a
           permanently lit microphone indicator, which is not a trade
           worth making. */
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - let go

    /// Resolves to the finished text, which may be empty. There is a
    /// wait in here — the upload and the model — and the caller is
    /// expected to say so on screen.
    ///
    /// Never throws. The point of the button is that the thought gets
    /// out of your head.
    func stop() async -> VoiceResult {
        guard isLive else { return .empty }
        let id = holdId
        isLive = false

        let raw = reel?.drain() ?? []
        let pcm = WAV.resample(raw, from: capRate, to: Double(Self.rate))
        closeMic()
        reel = nil
        level = 0

        let seconds = Double(pcm.count) / Double(Self.rate)

        /* Nothing was captured. Whether that is because they said nothing
           or because the microphone never opened is not a distinction the
           caller can make from an empty string, and the two want opposite
           advice. */
        if pcm.isEmpty || !WAV.heardAnything(pcm) {
            return VoiceResult(text: "", source: opened ? .none : .noMic, lang: nil)
        }

        let wav = WAV.encode(pcm, rate: Self.rate)
        let out = await client.transcribe(wav: wav, seconds: seconds, vocab: hooks.vocab)

        // Superseded: another hold started, or this one was abandoned.
        if id != holdId { return .empty }
        if out.text.isEmpty { return .empty }
        return VoiceResult(text: out.text, source: .model, lang: out.lang)
    }

    /// Throw the hold away without transcribing it — the sheet is
    /// closing, or the button was tapped rather than held.
    func abandon() {
        guard isLive else { return }
        isLive = false
        opened = false
        holdId += 1
        closeMic()
        reel = nil
        level = 0
    }
}

// MARK: - the samples, off the main actor

/// Everything the tap block is allowed to touch. It owns a lock and a
/// list of blocks and knows nothing about the recorder above it, which
/// is what makes it safe to call from a render thread.
private final class Reel: @unchecked Sendable {

    private let lock = NSLock()
    private var chunks: [[Float]] = []
    private var frames = 0
    private var open = true
    private var level: ((Double) -> Void)?

    /// Called on an audio thread, and read under the lock: a tap block
    /// already in flight when the engine stops still lands, and it must
    /// not race the main actor clearing the handler out from under it.
    var onLevel: ((Double) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return level }
        set { lock.lock(); level = newValue; lock.unlock() }
    }

    func took(_ buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        guard count > 0, let channels = buffer.floatChannelData else { return }

        /* Mono. The built-in mic is one channel; a headset or a
           Bluetooth input can be two, and the web asks `getUserMedia`
           for `channelCount: 1` and lets the browser pick — which is the
           first channel. Same answer, taken the same way. */
        let source = channels[0]
        var block = [Float](repeating: 0, count: count)
        var sum = 0.0
        for i in 0..<count {
            let v = source[i]
            block[i] = v
            sum += Double(v) * Double(v)
        }

        lock.lock()
        guard open else { lock.unlock(); return }
        chunks.append(block)
        frames += count
        let handler = level
        lock.unlock()

        // `Math.min(1, Math.sqrt(sum / block.length) * 4)` (voice.js:155).
        handler?(Swift.min(1, (sum / Double(count)).squareRoot() * 4))
    }

    /// Joins everything captured and empties the reel. The join is
    /// already a second full copy of the recording, so the chunk list is
    /// dropped here rather than held alongside it while the resample
    /// makes a third.
    func drain() -> [Float] {
        lock.lock()
        let taken = chunks
        let total = frames
        chunks = []
        frames = 0
        lock.unlock()

        var all = [Float]()
        all.reserveCapacity(total)
        for chunk in taken { all.append(contentsOf: chunk) }
        return all
    }

    /// No more samples, and no more level callbacks.
    func close() {
        lock.lock()
        open = false
        chunks = []
        frames = 0
        level = nil
        lock.unlock()
    }
}
