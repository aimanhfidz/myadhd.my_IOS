/* ============================================================
   MyADHD/Core/Reachability.swift — advisory, never authoritative

   design.md §2.8. An `NWPathMonitor` wrapper, and the whole point of it
   is what it is NOT allowed to do.

   **It never blocks a request.** The web app has no `navigator.onLine`
   gate on triage, on transcribe, on feedback or on a sync, and neither
   does this. A monitor is wrong more often than people think — a VPN
   that reports satisfied while the tunnel is down, a captive portal that
   reports satisfied and answers every request with a login page, a
   phone that reports unsatisfied for a second while it moves between
   Wi-Fi and cellular. A gate built on that stalls sync silently, with
   no error copy, and the person has nothing to read and nothing to
   press.

   What it is for, and it is only these three things:

   1. **Failing fast.** `TriageClient` can throw at once instead of
      waiting out a 60 s socket timeout, so the offline parser and its
      toast arrive while the loading morph is still the right thing to be
      looking at.
   2. **`resortProblem`'s first branch** (app.js:1744): `if
      (!navigator.onLine) return 'Still offline — no connection.'` —
      copy, chosen after a failure, not a decision taken before one.
   3. **Not starting doomed passes.** The automatic schedulers — the
      12 s poll, the debounced cloud and calendar syncs — skip a pass
      while the path is unsatisfied. A pass that cannot work costs
      battery and writes a failure into a log nobody reads.

   **Every explicit user action bypasses this entirely.** "Sync now",
   "Sort these properly", Send on the feedback box, the mic: they all
   try, and they all report what actually happened. `allowsAutomaticWork`
   is the only property an automatic scheduler is allowed to read, and
   it is named so that reading it from a button handler looks wrong.

   It starts optimistic. `NWPathMonitor` does not deliver its first path
   synchronously, and a request made in the first few milliseconds of a
   launch must not be told there is no network because nothing has
   answered yet.
   ============================================================ */

import Foundation
import Network
import Observation

@MainActor
@Observable
final class Reachability {

    /// One monitor for the process. A second `NWPathMonitor` is a second
    /// set of callbacks for the same information.
    static let shared = Reachability()

    // MARK: - What the app may read

    /// The last path the monitor reported, or `true` before it has
    /// reported anything. **Advisory.** Nothing may refuse to try
    /// because of this; see the file comment.
    private(set) var isOnline: Bool = true

    /// Cellular, a personal hotspot, or anything else the system would
    /// rather we did not pour data down.
    private(set) var isExpensive: Bool = false

    /// Low Data Mode.
    private(set) var isConstrained: Bool = false

    /// True once the monitor has actually told us something. Before
    /// that, `isOnline` is an assumption rather than an observation, and
    /// a caller that wants to say "offline" in copy should check this
    /// first.
    private(set) var hasObservedPath: Bool = false

    /// The only thing an automatic scheduler may gate on. A button must
    /// not read it.
    var allowsAutomaticWork: Bool { isOnline }

    // MARK: - Resume

    /// How long two "the path came back" events have to be apart before
    /// the second one counts. Wi-Fi handing over to cellular and back
    /// produces a flurry; every one of them would otherwise start a sync
    /// pass (design §2.8 — the cloud's own dedupe is 2 s, cloud.js:468).
    var resumeDedupe: TimeInterval = 2

    private var handlers: [UUID: () -> Void] = [:]
    private var lastResume: Date?

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "my.adhd.reachability")
    @ObservationIgnored private var running = false
    @ObservationIgnored private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    deinit {
        /* `cancel()` is safe from any thread and the monitor holds no
           reference back to us once it has been called. */
        monitor.cancel()
    }

    // MARK: - Lifecycle

    /// Start watching. Idempotent, so the app can call it from
    /// `onAppear` without keeping track of whether it already did.
    func start() {
        guard !running else { return }
        running = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor [weak self] in
                self?.accept(online: online, expensive: expensive, constrained: constrained)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard running else { return }
        running = false
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }

    /// Exposed so a test — and `-myadhd.forceOffline 1` — can drive the
    /// same path the monitor drives, without a network.
    func accept(online: Bool, expensive: Bool = false, constrained: Bool = false) {
        let wasOnline = isOnline
        let first = !hasObservedPath

        isOnline = online
        isExpensive = expensive
        isConstrained = constrained
        hasObservedPath = true

        /* A resume is an edge, not a level: the path went from not
           working to working. The very first observation is not an edge
           — the app has only just launched and its own `.active`
           trigger has already fired a pass. */
        guard online, first ? false : !wasOnline else { return }

        let now = clock()
        if let last = lastResume, now.timeIntervalSince(last) < resumeDedupe { return }
        lastResume = now

        for handler in handlers.values { handler() }
    }

    // MARK: - Who to tell

    /// Called when the path comes back, deduped by `resumeDedupe`. Hold
    /// the token and hand it to `removeOnSatisfied` when the observer
    /// goes away.
    @discardableResult
    func onSatisfied(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        handlers[token] = handler
        return token
    }

    func removeOnSatisfied(_ token: UUID) {
        handlers.removeValue(forKey: token)
    }
}
