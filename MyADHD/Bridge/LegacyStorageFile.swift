/* ============================================================
   MyADHD/Bridge/LegacyStorageFile.swift — the old store, read as a file

   `LegacyImport` used to have one way in: stand up a hidden WKWebView on
   the myadhd.my origin and ask the page for `localStorage`. It works, and
   it is still here as the fallback, but it is a heavy way to read a file.
   WebKit answers a `loadHTMLString` of a literal string by starting three
   helper processes — web content, GPU and networking — and on a cold or
   busy phone that is seconds, not milliseconds. Observed on one loaded
   machine: 3.9s, 4.1s and 13.3s respectively, with the page declared
   unresponsive before they were done. None of that work is ours; we want
   one row out of one table.

   `localStorage` is a SQLite database inside our own container:

     Library/WebKit/<bundle id>/WebsiteData/Default/<hash>/<hash>
       /LocalStorage/localstorage.sqlite3

     CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE,
                             value BLOB NOT NULL ON CONFLICT FAIL)

   The `<hash>` is salted per data store, so it is found by walking rather
   than computed. Values are WebKit strings: UTF-16 little-endian in
   practice, and 8-bit when the string happens to be all-Latin1, so both
   are decoded.

   This is reading our own app's files, not calling private API — but it
   IS depending on a layout Apple has never promised. So it is written to
   fail the safe way: anything unexpected returns `nil`, which is not
   "there is nothing", it is "I could not tell", and `LegacyImport` then
   does exactly what it did before and asks a web view.

   The database is copied before it is opened. It may be in WAL mode, and
   a read-only open of a WAL database wants to create a `-shm` beside it;
   copying the three files into our own temporary directory and opening
   the copy read-write lets SQLite replay the log normally, cannot disturb
   whatever WebKit thinks it owns, and cannot leave a lock behind.
   ============================================================ */

import Foundation
import SQLite3

enum LegacyStorageFile {

    /// Every key the old shell could have written, read in one pass.
    ///
    /// - Returns: the pairs, or `nil` when the database could not be
    ///   found, copied, opened or read. An empty dictionary is a real
    ///   answer — the store existed and held nothing — and is not `nil`.
    static func read(container: URL = defaultContainer(),
                     bundleID: String = Bundle.main.bundleIdentifier ?? "my.adhd.ios") -> [String: String]? {
        guard let db = locate(container: container, bundleID: bundleID) else { return nil }
        guard let copied = copyAside(db) else { return nil }
        defer { try? FileManager.default.removeItem(at: copied.deletingLastPathComponent()) }
        return items(in: copied)
    }

    /// `Library/` two levels up from `Library/Application Support/myadhd`.
    /// Taken as a parameter everywhere else so the check can point at a
    /// fixture instead.
    static func defaultContainer() -> URL {
        let library = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library.deletingLastPathComponent()
    }

    // MARK: - Finding it

    /// Walks to the database rather than computing the hashed directory
    /// names, which are salted per data store and are not ours to derive.
    ///
    /// Both layouts are tried: the partitioned one every current WebKit
    /// writes, and the flat `WebsiteData/LocalStorage` an older one used.
    /// If more than one origin has storage — which our container should
    /// never have, having only ever loaded myadhd.my — the largest file
    /// wins, on the grounds that the store with the lists in it is the
    /// store with bytes in it.
    static func locate(container: URL, bundleID: String) -> URL? {
        let fm = FileManager.default
        let roots = [
            container.appendingPathComponent("Library/WebKit/\(bundleID)/WebsiteData"),
            container.appendingPathComponent("Library/WebKit/WebsiteData"),
        ]

        var found: [URL] = []
        for root in roots {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let walk = fm.enumerator(at: root,
                                           includingPropertiesForKeys: [.isRegularFileKey],
                                           options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walk where url.lastPathComponent == "localstorage.sqlite3" {
                found.append(url)
            }
        }
        guard !found.isEmpty else { return nil }

        return found.max { a, b in size(of: a) < size(of: b) }
    }

    private static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    // MARK: - Copying it

    /// The database and its journal, into a directory of our own. The
    /// `-wal` may hold writes the main file does not; leaving it behind
    /// would read a store missing whatever was saved last.
    private static func copyAside(_ db: URL) -> URL? {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("myadhd-legacy-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }

        let target = dir.appendingPathComponent(db.lastPathComponent)
        guard (try? fm.copyItem(at: db, to: target)) != nil else {
            try? fm.removeItem(at: dir)
            return nil
        }
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: db.path + suffix)
            if fm.fileExists(atPath: side.path) {
                try? fm.copyItem(at: side, to: URL(fileURLWithPath: target.path + suffix))
            }
        }
        return target
    }

    // MARK: - Reading it

    private static func items(in db: URL) -> [String: String]? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle
        else {
            if handle != nil { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT key, value FROM ItemTable", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }

        var out: [String: String] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }

            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let key = String(cString: raw)

            let bytes = sqlite3_column_bytes(statement, 1)
            guard bytes > 0, let blob = sqlite3_column_blob(statement, 1) else {
                out[key] = ""
                continue
            }
            let data = Data(bytes: blob, count: Int(bytes))
            if let text = decode(data) { out[key] = text }
        }
        return out
    }

    /// A WebKit string is 16-bit unless every character fits in 8, so a
    /// value is UTF-16 little-endian in the ordinary case and Latin-1 in
    /// the compact one. UTF-8 is tried last: it is what a future WebKit
    /// would most plausibly move to, and an all-ASCII value decodes the
    /// same either way so nothing is lost by looking.
    static func decode(_ data: Data) -> String? {
        if data.count % 2 == 0,
           let text = String(data: data, encoding: .utf16LittleEndian),
           !text.contains("\u{FFFD}") {
            /* An even number of Latin-1 bytes also decodes as UTF-16, into
               mojibake rather than into an error. The tell is NUL: real
               UTF-16 of ordinary text is full of them, and no string the
               web app stores contains one. */
            if data.count >= 2 && (data.contains(0) || text.utf16.count * 2 == data.count && looksLikeText(text)) {
                return text
            }
        }
        if let text = String(data: data, encoding: .utf8), !text.contains("\u{FFFD}") { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Enough to tell a decoded string from noise: no control characters
    /// other than the three a JSON document can legitimately carry.
    private static func looksLikeText(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.value < 0x20 {
            if scalar != "\n" && scalar != "\r" && scalar != "\t" { return false }
        }
        return true
    }
}
