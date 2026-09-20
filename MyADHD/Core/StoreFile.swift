/* ============================================================
   MyADHD/Core/StoreFile.swift — the one document on disk

   design.md §2.4. One file, `Library/Application Support/myadhd/
   myadhd.v1.json`, holding exactly the bytes `JSON.stringify(state)`
   would have put in `localStorage`.

   What this file is careful about, and why:

   - **File protection.** `NSFileProtectionCompleteUntilFirstUserAuthentication`,
     the same class as the keychain snapshot, so a launch on a phone that
     has not been unlocked since a reboot behaves the same way for the
     document as it does for the widget's copy. Set on the directory and
     on every file written into it, including the temp file — the
     attribute has to be on the inode before the rename, because after it
     the file IS the document.

   - **Atomic replacement.** Serialise on the main actor, hand `Data` to a
     serial utility queue, write a temp file beside the document and
     `rename(2)` it into place. `rename` on one filesystem is atomic: a
     reader sees the old bytes or the new bytes, never a half-written
     file, and a crash mid-write costs the write and not the document.

   - **One rotation behind.** The document that was there is copied to
     `myadhd.v1.bak.json` before the rename. It is the only copy of
     yesterday, so it is written before the new bytes land and never
     after.

   - **Coalescing.** A newer pending write replaces an older one that has
     not started. Typing in a note calls `persistOnly()` on every
     keystroke; without this the queue would grow a write per letter and
     spend the battery re-encoding a document that is already stale.

   - **Quarantine, never overwrite.** A document that will not parse is
     moved aside as `myadhd.v1.corrupt-<stamp>.json` and left there. If
     that name is taken the next free one is used: a corrupt file is
     evidence, and evidence that gets overwritten by the next launch is
     no evidence at all. The stamp comes from an injected clock so a test
     can name the file it expects.

   - **Modification watch.** `changedOnDisk()` compares the document's
     modification date with the one this object last saw. Today there is
     exactly one writer and the answer is always false; the day an App
     Intent, an extension or a background task writes, the caller can
     re-read instead of stamping its stale copy over the top.

   Nothing in here knows what a task is. It moves bytes.
   ============================================================ */

import Foundation

final class StoreFile {

    // MARK: - Names

    /// `myadhd.v1` — the same key the page writes to `localStorage`.
    static let documentName = "myadhd.v1.json"
    static let backupName = "myadhd.v1.bak.json"
    static let corruptPrefix = "myadhd.v1.corrupt-"
    static let corruptSuffix = ".json"

    /// `Library/Application Support/myadhd`.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("myadhd", isDirectory: true)
    }

    // MARK: - Shape

    let directory: URL
    var documentURL: URL { directory.appendingPathComponent(Self.documentName) }
    var backupURL: URL { directory.appendingPathComponent(Self.backupName) }

    private let clock: () -> Date
    private let fm = FileManager.default

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: Data?
    private var draining = false
    private var idle: [() -> Void] = []

    /* Both of these are touched from the caller's thread AND from the
       write queue, so both live behind the same lock the pending slot
       does. Reading one is a method call, not a stored property, so
       there is no way to touch the storage without the lock. */
    private var _lastSeenModified: Date?
    private var _lastWriteError: Error?

    /// The modification date of the document as this object last saw it —
    /// after a read, or after a write it made itself.
    var lastSeenModified: Date? {
        lock.lock(); defer { lock.unlock() }
        return _lastSeenModified
    }

    /// The last write's failure, if it failed. Read after `flush()`; a
    /// write does not throw at the caller, because the caller is a
    /// keystroke.
    var lastWriteError: Error? {
        lock.lock(); defer { lock.unlock() }
        return _lastWriteError
    }

    private func setLastSeenModified(_ date: Date?) {
        lock.lock(); _lastSeenModified = date; lock.unlock()
    }

    init(directory: URL = StoreFile.defaultDirectory(),
         clock: @escaping () -> Date = Date.init,
         queue: DispatchQueue = DispatchQueue(label: "my.adhd.store-file", qos: .utility))
    {
        self.directory = directory
        self.clock = clock
        self.queue = queue
    }

    // MARK: - Reading

    enum ReadResult {
        /// Nothing has been written yet — a fresh install, or the very
        /// first launch after the migration.
        case missing
        /// The document parsed. `modified` is its modification date.
        case ok(JSONValue, modified: Date?)
        /// It did not parse and has been moved aside. The document no
        /// longer exists at `documentURL`; `quarantined` says where it
        /// went, or is nil if it could not be moved.
        case corrupt(quarantined: URL?, error: Error)
    }

    /// Read and parse the document. Never throws: every outcome a caller
    /// has to act on differently is a case of `ReadResult`.
    @discardableResult
    func read() -> ReadResult {
        read(at: documentURL, quarantineOnFailure: true)
    }

    /// The rotation, read the same way. Nothing calls this on the launch
    /// path — the web's `load()` starts fresh on a corrupt store and so
    /// does this app, so that the two agree about what a person sees.
    /// It is here for a recovery affordance to use, and because the file
    /// is worthless if nothing can open it.
    func readBackup() -> ReadResult {
        read(at: backupURL, quarantineOnFailure: false)
    }

    private func read(at url: URL, quarantineOnFailure: Bool) -> ReadResult {
        guard fm.fileExists(atPath: url.path) else { return .missing }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            /* Unreadable is not the same as unparseable: a file locked by
               data protection comes back as an error here and will read
               fine after the first unlock. Quarantining it would destroy
               a perfectly good document. */
            return .corrupt(quarantined: nil, error: error)
        }

        do {
            let value = try JSONValue.parse(data)
            let modified = modificationDate(of: url)
            if url == documentURL { setLastSeenModified(modified) }
            return .ok(value, modified: modified)
        } catch {
            guard quarantineOnFailure else { return .corrupt(quarantined: nil, error: error) }
            let moved = quarantine(url)
            if url == documentURL { setLastSeenModified(nil) }
            return .corrupt(quarantined: moved, error: error)
        }
    }

    /// Move a document that will not parse out of the way, under a name
    /// that is not already taken. Returns where it went, or nil if even
    /// the move failed — in which case the caller is about to overwrite
    /// it, and there is nothing further this can do about that.
    @discardableResult
    func quarantine(_ url: URL) -> URL? {
        let stamp = Self.stamp(clock())
        for attempt in 0..<1000 {
            let suffix = attempt == 0 ? "" : "-\(attempt)"
            let target = directory.appendingPathComponent(
                Self.corruptPrefix + stamp + suffix + Self.corruptSuffix)
            /* Taken means taken. A quarantined file is evidence and is
               never written over, not even by another corrupt document
               from the same second. */
            if fm.fileExists(atPath: target.path) { continue }
            do {
                try fm.moveItem(at: url, to: target)
                return target
            } catch {
                return nil
            }
        }
        return nil
    }

    /// `20260920-081500.123`, UTC — sortable, and legal in a filename on
    /// every filesystem iOS will hand us.
    static func stamp(_ date: Date) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let p = c.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond],
                                 from: date)
        let ms = Int((Double(p.nanosecond ?? 0) / 1_000_000).rounded(.down))
        return String(format: "%04d%02d%02d-%02d%02d%02d.%03d",
                      p.year ?? 0, p.month ?? 0, p.day ?? 0,
                      p.hour ?? 0, p.minute ?? 0, p.second ?? 0, ms)
    }

    // MARK: - The modification watch

    func modificationDate(of url: URL) -> Date? {
        (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// True when the document on disk is not the one this object last
    /// saw. Called on `didBecomeActive`; cheap insurance for the day a
    /// second writer exists.
    func changedOnDisk() -> Bool {
        guard fm.fileExists(atPath: documentURL.path) else {
            return lastSeenModified != nil
        }
        guard let now = modificationDate(of: documentURL) else { return false }
        guard let seen = lastSeenModified else { return true }
        /* HFS+ and some network filesystems keep whole seconds; a
           tolerance below that would report a change on every check. */
        return abs(now.timeIntervalSince(seen)) > 0.5
    }

    // MARK: - Writing

    /// Hand over the bytes. Returns immediately; the write happens on the
    /// serial queue, and a newer call replaces an older one that has not
    /// started yet.
    func write(_ data: Data) {
        lock.lock()
        pending = data
        let alreadyDraining = draining
        draining = true
        lock.unlock()

        if !alreadyDraining {
            queue.async { [weak self] in self?.drain() }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let data = pending else {
                draining = false
                let waiting = idle
                idle = []
                lock.unlock()
                waiting.forEach { $0() }
                return
            }
            pending = nil
            lock.unlock()

            var failure: Error?
            do { try perform(data) } catch { failure = error }
            lock.lock(); _lastWriteError = failure; lock.unlock()
        }
    }

    /// Block until every queued write has landed. For app termination,
    /// for a test, and for the moment before handing the document to
    /// another process. Never call it from the write queue.
    func flush() {
        let done = DispatchSemaphore(value: 0)
        lock.lock()
        if !draining && pending == nil {
            lock.unlock()
            return
        }
        idle.append { done.signal() }
        lock.unlock()
        done.wait()
    }

    private func perform(_ data: Data) throws {
        try ensureDirectory()

        // 1. Rotate. The document that is there becomes the backup, before
        //    anything new can land on top of it.
        if fm.fileExists(atPath: documentURL.path) {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: documentURL, to: backupURL)
            try? protect(backupURL)
        }

        // 2. A temp file beside the document, so the rename stays on one
        //    filesystem and therefore stays atomic.
        let temp = directory.appendingPathComponent(
            ".\(Self.documentName).tmp-\(UUID().uuidString)")
        try data.write(to: temp, options: [.atomic])
        try protect(temp)

        // 3. rename(2). POSIX, not FileManager: this one overwrites, and
        //    it is the only step in here that is not allowed to leave a
        //    half-state behind.
        let from = (temp.path as NSString).fileSystemRepresentation
        let to = (documentURL.path as NSString).fileSystemRepresentation
        if rename(from, to) != 0 {
            let err = errno
            try? fm.removeItem(at: temp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [
                NSLocalizedDescriptionKey:
                    "could not replace \(Self.documentName): \(String(cString: strerror(err)))",
            ])
        }

        setLastSeenModified(modificationDate(of: documentURL))
    }

    private func ensureDirectory() throws {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue {
            return
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ])
    }

    private func protect(_ url: URL) throws {
        try fm.setAttributes([
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ], ofItemAtPath: url.path)
    }

    // MARK: - Housekeeping

    /// Every quarantined document, oldest name first.
    func quarantinedFiles() -> [URL] {
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(Self.corruptPrefix) && $0.hasSuffix(Self.corruptSuffix) }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }
}
