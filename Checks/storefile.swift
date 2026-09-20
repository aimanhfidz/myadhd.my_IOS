/* ============================================================
   Checks/storefile.swift — the document on disk, with real files

   Not an Xcode target. A `swiftc` program over the app target's own
   `MyADHD/Core` sources, driving `StoreFile` against a real directory
   under `$TMPDIR`: real writes, real renames, real corrupt bytes.

       Checks/storefile.sh

   There is nothing to hold this one against — `localStorage` had no
   rotation, no quarantine and no temp file, so app.js cannot be the
   specification here the way it is for the store's rules. What it is
   held against instead is the four promises design §2.4 makes, each
   one checked by the only thing that can check it, which is the
   filesystem:

     1. **Atomic replacement.** A reader running flat out beside a
        writer never sees a half-written file. Proved by doing exactly
        that: one thread writing 400 documents of wildly different
        lengths, another reading the file as fast as it can, and every
        single read having to parse AND be one of the documents that
        was actually written. A `write(to:)` without the rename would
        fail this within a few hundred reads.

     2. **One rotation behind.** The document that was there is copied
        to `myadhd.v1.bak.json` before the new bytes land — and it is
        the PREVIOUS document, never the one being written.

     3. **Quarantine, never overwrite.** A document that will not parse
        is moved aside under a stamped name and left there. A second
        corrupt document in the same millisecond gets the next free
        name rather than landing on the first. Nothing — not a write,
        not another quarantine, not a later launch — ever writes over
        one.

     4. **Coalescing.** A newer pending write replaces an older one
        that has not started. Checked by suspending the write queue,
        queueing three documents, and then proving from the BACKUP that
        only one of them was ever performed: if all three had run, the
        rotation would hold the second.

   And two things that are not promises but are failure modes worth
   pinning: an UNREADABLE file (locked by data protection on a phone
   that has not been unlocked since a reboot) must NOT be quarantined —
   it is a perfectly good document that will read fine later — and a
   write that fails must leave the document that is already there
   alone.
   ============================================================ */

import Foundation

// MARK: - the report

final class Report {
    private(set) var checks = 0
    private(set) var failures: [String] = []
    private var section = ""

    func open(_ name: String) {
        section = name
        print("\n  \(name)")
    }

    @discardableResult
    func equal(_ what: String, _ got: String, _ want: String) -> Bool {
        checks += 1
        if got == want {
            print("    ok    \(what)")
            return true
        }
        failures.append("\(section) / \(what)")
        print("    FAIL  \(what)")
        print("      want  \(want)")
        print("      got   \(got)")
        return false
    }

    @discardableResult
    func yes(_ what: String, _ value: Bool) -> Bool {
        equal(what, value ? "true" : "false", "true")
    }

    func note(_ line: String) { print("    ---   \(line)") }
}

// MARK: - a directory that cleans up after itself

func scratch(_ name: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("myadhd-storefile-\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

func names(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
}

/// A document of a given size, so a partial read of one can never be
/// mistaken for a whole one of another.
func document(_ n: Int, filler: String) -> String {
    "{\"tasks\":[],\"notes\":[],\"n\":\(n),\"pad\":\"\(String(repeating: filler, count: n))\"}"
}

/// 2026-03-09T17:30:00.125Z. The .125 is not decoration: an eighth of a
/// second is exact in binary, so `StoreFile.stamp` gets the millisecond
/// the name says it does. At .123 a `Date` actually holds 122999906 ns
/// and the stamp reads `.122` — right for the file, wrong for a test
/// that wants to name the file it expects.
let fixedClock = Date(timeIntervalSince1970: 1_773_077_400.125)

@main
struct StoreFileChecks {

    static func main() {
        let r = Report()
        print("storefile")
        print("  scratch  \(NSTemporaryDirectory())")

        writesAndRotates(r)
        atomicUnderAReader(r)
        coalesces(r)
        quarantines(r)
        neverOverwritesEvidence(r)
        doesNotQuarantineAnUnreadableFile(r)
        aFailedWriteKeepsTheDocument(r)
        watchesTheModificationDate(r)
        readsTheBackup(r)

        print("\n---")
        if r.failures.isEmpty {
            print("storefile OK — \(r.checks) checks, all passed")
            exit(0)
        }
        print("storefile FAILED — \(r.failures.count) of \(r.checks) checks:")
        for f in r.failures { print("  - \(f)") }
        exit(1)
    }

    // MARK: - 1. the write, and the rotation

    static func writesAndRotates(_ r: Report) {
        r.open("a write lands, and leaves nothing behind")
        let dir = scratch("write")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = StoreFile(directory: dir, clock: { fixedClock })

        let first = document(40, filler: "a")
        file.write(Data(first.utf8))
        file.flush()

        r.equal("the document is the bytes handed over", text(file.documentURL) ?? "(missing)", first)
        r.yes("no backup yet — there was nothing to rotate", !exists(file.backupURL))
        r.equal("nothing else in the directory", names(in: dir).joined(separator: ","),
                StoreFile.documentName)
        r.equal("no write error", file.lastWriteError.map { "\($0)" } ?? "none", "none")

        let second = document(900, filler: "b")
        file.write(Data(second.utf8))
        file.flush()
        r.equal("the document is the newer one", text(file.documentURL) ?? "(missing)", second)
        r.equal("the backup is the one it replaced", text(file.backupURL) ?? "(missing)", first)
        r.equal("still nothing else in the directory", names(in: dir).joined(separator: ","),
                "\(StoreFile.backupName),\(StoreFile.documentName)")

        let third = document(12, filler: "c")
        file.write(Data(third.utf8))
        file.flush()
        r.equal("one rotation behind, not two", text(file.backupURL) ?? "(missing)", second)

        /* The temp file is named with a leading dot and a UUID; a
           `contentsOfDirectory` listing includes dotfiles, so the two
           assertions above already cover it. This one says so out loud. */
        let leftovers = names(in: dir).filter { $0.contains(".tmp-") }
        r.equal("no temp file left behind", leftovers.joined(separator: ","), "")
    }

    // MARK: - 2. atomic under a reader

    /// The promise that matters most, checked the only way it can be:
    /// a reader running flat out beside a writer. Every read must parse
    /// and must be one of the documents that was actually written —
    /// never a prefix of one, never an empty file, never nothing at all.
    static func atomicUnderAReader(_ r: Report) {
        r.open("a reader beside a writer never sees half a document")
        let dir = scratch("atomic")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = StoreFile(directory: dir, clock: { fixedClock })

        let rounds = 400
        var legal = Set<String>()
        for i in 0..<rounds {
            /* Every document a different length, from 60 bytes to about
               3 KB: a torn write shows up as a document of the wrong
               length, and the lengths have to move for that to be
               visible. */
            let size = 1 + i * 7
            legal.insert(document(size, filler: i % 2 == 0 ? "x" : "y"))
        }
        let all = Array(legal)
        file.write(Data(all[0].utf8))
        file.flush()

        var reads = 0, torn = 0, unparseable = 0, missing = 0
        let done = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            for doc in all {
                file.write(Data(doc.utf8))
                /* Flushed, so every document really is written rather
                   than coalesced away — the race this is looking for is
                   with the rename, and there has to be one per document
                   for the reader to have a chance of catching it. No
                   sleep anywhere: a delay would make the check pass by
                   not trying. */
                file.flush()
            }
            done.signal()
        }

        while done.wait(timeout: .now()) == .timedOut {
            reads += 1
            guard let got = text(file.documentURL) else { missing += 1; continue }
            if (try? JSONValue.parse(got)) == nil { unparseable += 1; continue }
            if !legal.contains(got) { torn += 1 }
        }
        file.flush()

        r.note("\(reads) reads while \(all.count) documents were being written")
        r.yes("the reader actually raced (more than 50 reads)", reads > 50)
        r.equal("no read came back missing", "\(missing)", "0")
        r.equal("no read came back unparseable", "\(unparseable)", "0")
        r.equal("no read came back torn", "\(torn)", "0")
        r.equal("the last document is the last one written",
                text(file.documentURL) ?? "(missing)", all[all.count - 1])
    }

    // MARK: - 3. coalescing

    /// Suspend the queue, hand over three documents, resume. Only the
    /// last may be performed — and the proof is the BACKUP: if all three
    /// had run, the rotation would hold the second.
    static func coalesces(_ r: Report) {
        r.open("a newer pending write replaces an older unstarted one")
        let dir = scratch("coalesce")
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "storefile-check-coalesce", qos: .utility)
        let file = StoreFile(directory: dir, clock: { fixedClock }, queue: queue)

        let a = document(10, filler: "a")
        let b = document(20, filler: "b")
        let c = document(30, filler: "c")

        queue.suspend()
        file.write(Data(a.utf8))
        file.write(Data(b.utf8))
        file.write(Data(c.utf8))
        queue.resume()
        file.flush()

        r.equal("the document is the newest", text(file.documentURL) ?? "(missing)", c)
        r.yes("no backup — only one write was ever performed", !exists(file.backupURL))
        r.equal("the directory holds one file", names(in: dir).joined(separator: ","),
                StoreFile.documentName)

        /* And again over a document that already exists, where the
           rotation has something to say: the backup must be what was
           there BEFORE the burst, not one of the burst. */
        let before = text(file.documentURL) ?? ""
        queue.suspend()
        file.write(Data(document(40, filler: "d").utf8))
        file.write(Data(document(50, filler: "e").utf8))
        queue.resume()
        file.flush()
        r.equal("the backup is what was there before the burst",
                text(file.backupURL) ?? "(missing)", before)
        r.equal("the document is the last of the burst",
                text(file.documentURL) ?? "(missing)", document(50, filler: "e"))
    }

    // MARK: - 4. quarantine

    static func quarantines(_ r: Report) {
        r.open("a document that will not parse is moved aside, not read past")
        let dir = scratch("corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = StoreFile(directory: dir, clock: { fixedClock })

        let garbage = "{\"tasks\": [ this is not json"
        try? Data(garbage.utf8).write(to: file.documentURL)

        let result = file.read()
        switch result {
        case .corrupt(let quarantined, _):
            r.yes("read() says corrupt", true)
            guard let quarantined else {
                r.equal("it was moved", "(not moved)", "moved")
                return
            }
            /* The stamp is UTC and comes from the injected clock, so the
               name is the one a person reading a bug report would work
               out for themselves. */
            r.equal("the name is stamped from the clock", quarantined.lastPathComponent,
                    "myadhd.v1.corrupt-20260309-173000.125.json")
            r.equal("the bytes are the corrupt ones, verbatim",
                    text(quarantined) ?? "(missing)", garbage)
            r.yes("the document is gone from its own name", !exists(file.documentURL))
            r.equal("lastSeenModified was cleared",
                    file.lastSeenModified.map { "\($0)" } ?? "nil", "nil")
        default:
            r.equal("read() says corrupt", "\(result)", "corrupt")
            return
        }

        // A second corrupt document, in the same millisecond of the same clock.
        let more = "also not json"
        try? Data(more.utf8).write(to: file.documentURL)
        guard case .corrupt(let second, _) = file.read(), let second else {
            r.equal("the second one was quarantined too", "no", "yes")
            return
        }
        r.equal("the second gets the next free name", second.lastPathComponent,
                "myadhd.v1.corrupt-20260309-173000.125-1.json")
        r.equal("the first is untouched", text(dir.appendingPathComponent(
            "myadhd.v1.corrupt-20260309-173000.125.json")) ?? "(gone)", garbage)
        r.equal("both are listed, oldest name first",
                file.quarantinedFiles().map(\.lastPathComponent).joined(separator: ","),
                "myadhd.v1.corrupt-20260309-173000.125-1.json,"
                + "myadhd.v1.corrupt-20260309-173000.125.json")
        r.note("`.sorted()` puts `-1` before `.json`; both are there, which is what "
               + "the caller needs")

        r.open("a missing document is missing, not corrupt")
        let empty = scratch("empty")
        defer { try? FileManager.default.removeItem(at: empty) }
        let fresh = StoreFile(directory: empty, clock: { fixedClock })
        if case .missing = fresh.read() {
            r.yes("read() says missing", true)
        } else {
            r.equal("read() says missing", "something else", "missing")
        }
        r.equal("nothing was created by reading", names(in: empty).joined(separator: ","), "")
    }

    // MARK: - 5. evidence stays evidence

    static func neverOverwritesEvidence(_ r: Report) {
        r.open("nothing ever writes over a quarantined document")
        let dir = scratch("evidence")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = StoreFile(directory: dir, clock: { fixedClock })

        let garbage = "{ broken"
        try? Data(garbage.utf8).write(to: file.documentURL)
        guard case .corrupt(let quarantined, _) = file.read(), let quarantined else {
            r.equal("quarantined", "no", "yes")
            return
        }

        /* Everything the app does after a corrupt read, in order: it
           starts fresh and writes, several times, and rotates. */
        for i in 0..<5 {
            file.write(Data(document(10 + i, filler: "z").utf8))
            file.flush()   // one write per document, so the rotation moves five times
        }
        _ = file.read()

        r.equal("the quarantined bytes are still there", text(quarantined) ?? "(gone)", garbage)
        r.yes("the document exists again", exists(file.documentURL))
        r.equal("the quarantine is not the backup either",
                text(file.backupURL) ?? "(missing)", document(13, filler: "z"))
    }

    // MARK: - 6. unreadable is not unparseable

    /// A file locked by data protection on a phone that has not been
    /// unlocked since a reboot comes back as a read ERROR, and it is a
    /// perfectly good document that will read fine after the first
    /// unlock. Quarantining it would destroy it. On the Mac the same
    /// shape is made with a mode nobody can read.
    static func doesNotQuarantineAnUnreadableFile(_ r: Report) {
        r.open("an unreadable document is left exactly where it is")
        let dir = scratch("locked")
        let file = StoreFile(directory: dir, clock: { fixedClock })
        let good = document(30, filler: "g")
        try? Data(good.utf8).write(to: file.documentURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0],
                                               ofItemAtPath: file.documentURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: file.documentURL.path)
            try? FileManager.default.removeItem(at: dir)
        }

        guard geteuid() != 0 else {
            r.note("running as root — a mode of 0 does not stop a read; skipped")
            return
        }

        let result = file.read()
        if case .corrupt(let quarantined, _) = result {
            r.yes("read() reports it as unreadable", true)
            r.equal("it was NOT moved aside", quarantined.map(\.lastPathComponent) ?? "nil", "nil")
        } else {
            r.equal("read() reports it as unreadable", "\(result)", "corrupt(quarantined: nil)")
        }
        r.yes("the document is still at its own name", exists(file.documentURL))
        r.equal("no quarantine file was made",
                file.quarantinedFiles().map(\.lastPathComponent).joined(separator: ","), "")
    }

    // MARK: - 7. a failed write

    /// The document that is already there is somebody's only copy. A
    /// write that cannot happen must not be allowed to take it.
    static func aFailedWriteKeepsTheDocument(_ r: Report) {
        r.open("a write that fails leaves the document alone")
        let dir = scratch("readonly")
        let file = StoreFile(directory: dir, clock: { fixedClock })
        let good = document(25, filler: "k")
        file.write(Data(good.utf8))
        file.flush()

        try? FileManager.default.setAttributes([.posixPermissions: 0o500],
                                               ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        guard geteuid() != 0 else {
            r.note("running as root — a read-only directory does not stop a write; skipped")
            return
        }

        file.write(Data(document(60, filler: "m").utf8))
        file.flush()

        r.yes("the write reported an error", file.lastWriteError != nil)
        r.equal("the document is still the old one", text(file.documentURL) ?? "(missing)", good)
    }

    // MARK: - 8. the modification watch

    static func watchesTheModificationDate(_ r: Report) {
        r.open("changedOnDisk sees a second writer")
        let dir = scratch("watch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = StoreFile(directory: dir, clock: { fixedClock })

        r.yes("nothing seen, nothing there — no change", !file.changedOnDisk())

        file.write(Data(document(30, filler: "w").utf8))
        file.flush()
        r.yes("its own write is not a change", !file.changedOnDisk())

        _ = file.read()
        r.yes("its own read is not a change either", !file.changedOnDisk())

        /* Somebody else — an App Intent, an extension, a future
           background task — writing the same path. */
        let later = Date(timeIntervalSince1970: (file.lastSeenModified ?? Date())
                            .timeIntervalSince1970 + 5)
        try? Data(document(31, filler: "v").utf8).write(to: file.documentURL)
        try? FileManager.default.setAttributes([.modificationDate: later],
                                               ofItemAtPath: file.documentURL.path)
        r.yes("a write by something else is a change", file.changedOnDisk())

        _ = file.read()
        r.yes("re-reading settles it", !file.changedOnDisk())

        try? FileManager.default.removeItem(at: file.documentURL)
        r.yes("the document disappearing is a change", file.changedOnDisk())
    }

    // MARK: - 9. the rotation is readable

    static func readsTheBackup(_ r: Report) {
        r.open("the backup can be opened, and never quarantines")
        let dir = scratch("backup")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = StoreFile(directory: dir, clock: { fixedClock })

        let one = "{\"tasks\":[],\"notes\":[],\"view\":\"list\"}"
        file.write(Data(one.utf8))
        file.flush()
        file.write(Data(document(15, filler: "n").utf8))
        file.flush()

        if case .ok(let value, _) = file.readBackup() {
            r.equal("the backup parses", WebJSON.encode(value), one)
        } else {
            r.equal("the backup parses", "no", "yes")
        }

        try? Data("not json at all".utf8).write(to: file.backupURL)
        if case .corrupt(let quarantined, _) = file.readBackup() {
            r.equal("a corrupt backup is not quarantined",
                    quarantined.map(\.lastPathComponent) ?? "nil", "nil")
            r.yes("and it is still there", exists(file.backupURL))
        } else {
            r.equal("a corrupt backup reads as corrupt", "no", "yes")
        }
    }
}
