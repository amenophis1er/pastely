import Foundation
import Observation
import SQLite3

/// SQLite-backed history. All access happens on the main actor; the table is small
/// and every query is indexed, so this stays well under a millisecond per call.
@MainActor
@Observable
final class ClipStore {
    private(set) var items: [ClipItem] = []
    /// Bumps on every reload so view caches keyed on it stay fresh.
    private(set) var version = 0
    var isPaused = false

    var maxItems = 500
    var maxAgeDays = 30

    @ObservationIgnored nonisolated(unsafe) private let db: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            throw StoreError.open(String(cString: sqlite3_errmsg(handle)))
        }
        db = handle
        if path != ":memory:" {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        exec("PRAGMA journal_mode=WAL")
        exec("""
        CREATE TABLE IF NOT EXISTS items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            kind TEXT NOT NULL,
            uti TEXT NOT NULL,
            preview BLOB NOT NULL,
            payload BLOB NOT NULL,
            byte_size INTEGER NOT NULL,
            content_hash TEXT NOT NULL UNIQUE,
            source_app TEXT,
            pinned INTEGER NOT NULL DEFAULT 0,
            thumb BLOB
        );
        CREATE INDEX IF NOT EXISTS items_created ON items(created_at DESC);
        """)
        if !hasColumn("thumb") { exec("ALTER TABLE items ADD COLUMN thumb BLOB") }
        if !hasColumn("ocr_text") { exec("ALTER TABLE items ADD COLUMN ocr_text BLOB") }
        if !hasColumn("label") { exec("ALTER TABLE items ADD COLUMN label BLOB") }
        reload()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Writes

    /// Inserts or bumps, and returns the row id. `isNew` is false for a repeat copy.
    /// Throws, and writes nothing, if encryption or the database write fails.
    @discardableResult
    func insert(_ item: ClipItem, payload: Data) throws -> (id: Int64, isNew: Bool) {
        // A repeat copy bumps the existing row instead of duplicating it.
        if let existing = items.first(where: { $0.contentHash == item.contentHash }) {
            try run("UPDATE items SET created_at = ? WHERE id = ?") { stmt in
                sqlite3_bind_double(stmt, 1, item.createdAt.timeIntervalSince1970)
                sqlite3_bind_int64(stmt, 2, existing.id)
            }
            reload()
            return (existing.id, false)
        }
        // Encrypt everything before touching the database, so a crypto failure writes nothing.
        let sealedPreview = try Crypto.seal(Data(item.preview.utf8))
        let sealedPayload = try Crypto.seal(payload)
        let sealedThumb = try item.thumb.map { try Crypto.seal($0) }
        try run("""
        INSERT INTO items (created_at, kind, uti, preview, payload, byte_size, content_hash, source_app, pinned, thumb)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
        """) { stmt in
            sqlite3_bind_double(stmt, 1, item.createdAt.timeIntervalSince1970)
            bind(stmt, 2, item.kind.rawValue)
            bind(stmt, 3, item.uti)
            bind(stmt, 4, sealedPreview)
            bind(stmt, 5, sealedPayload)
            sqlite3_bind_int64(stmt, 6, Int64(item.byteSize))
            bind(stmt, 7, item.contentHash)
            if let app = item.sourceApp { bind(stmt, 8, app) } else { sqlite3_bind_null(stmt, 8) }
            if let thumb = sealedThumb { bind(stmt, 9, thumb) } else { sqlite3_bind_null(stmt, 9) }
        }
        let id = sqlite3_last_insert_rowid(db)
        prune()
        reload()
        return (id, true)
    }

    func setOCRText(_ text: String, for id: Int64) throws {
        let sealed = try Crypto.seal(Data(text.utf8))
        try run("UPDATE items SET ocr_text = ? WHERE id = ?") { stmt in
            bind(stmt, 1, sealed)
            sqlite3_bind_int64(stmt, 2, id)
        }
        reload()
    }

    /// Applies new retention limits immediately, without waiting for the next copy.
    func applyRetention(maxItems: Int, maxAgeDays: Int) {
        self.maxItems = maxItems
        self.maxAgeDays = maxAgeDays
        prune()
        reload()
    }

    /// Names the item, and pins it when `pin` is set. An empty label clears the name.
    /// Labels are user-written and can describe a secret, so they are encrypted like previews.
    func setLabel(_ label: String?, for item: ClipItem, pin: Bool = false) throws {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sealed = trimmed.isEmpty ? nil : try Crypto.seal(Data(trimmed.utf8))
        try run("UPDATE items SET label = ?, pinned = MAX(pinned, ?) WHERE id = ?") { stmt in
            if let sealed { bind(stmt, 1, sealed) } else { sqlite3_bind_null(stmt, 1) }
            sqlite3_bind_int(stmt, 2, pin ? 1 : 0)
            sqlite3_bind_int64(stmt, 3, item.id)
        }
        reload()
    }

    func togglePin(_ item: ClipItem) {
        try? run("UPDATE items SET pinned = NOT pinned WHERE id = ?") { sqlite3_bind_int64($0, 1, item.id) }
        prune() // an unpinned item is subject to the caps again
        reload()
    }

    func delete(_ item: ClipItem) {
        try? run("DELETE FROM items WHERE id = ?") { sqlite3_bind_int64($0, 1, item.id) }
        reload()
    }

    func clear() {
        exec("DELETE FROM items WHERE pinned = 0")
        reload()
    }

    /// Drops unpinned rows beyond the count or age cap.
    func prune() {
        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86_400).timeIntervalSince1970
        try? run("DELETE FROM items WHERE pinned = 0 AND created_at < ?") { sqlite3_bind_double($0, 1, cutoff) }
        try? run("""
        DELETE FROM items WHERE pinned = 0 AND id NOT IN (
            SELECT id FROM items WHERE pinned = 0 ORDER BY created_at DESC LIMIT ?
        )
        """) { sqlite3_bind_int64($0, 1, Int64(maxItems)) }
    }

    // MARK: - Reads

    /// The full decrypted payload for one item. One indexed row read plus AES-GCM,
    /// so it is cheap, but callers should still decode images off the main thread.
    func payload(for item: ClipItem) -> Data? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM items WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, item.id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Crypto.open(column(stmt, 0))
    }

    func text(for item: ClipItem) -> String? {
        if item.kind == .file { return item.preview }
        return payload(for: item).flatMap(item.text(from:))
    }

    /// Substring matches rank first, then fuzzy subsequence matches by score.
    func search(_ query: String) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        var scored: [(ClipItem, Int)] = []
        for item in items {
            let hay = item.searchText.lowercased()
            if hay.contains(q) {
                scored.append((item, 1_000))
            } else if let score = FuzzyMatcher.score(q, in: hay) {
                scored.append((item, score))
            }
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    var totalBytes: Int { items.reduce(0) { $0 + $1.byteSize } }

    private func reload() {
        var result: [ClipItem] = []
        let sql = "SELECT id, created_at, kind, uti, preview, thumb, byte_size, content_hash, source_app, pinned, ocr_text, label FROM items ORDER BY pinned DESC, created_at DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let preview = Crypto.open(column(stmt, 4)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let thumb = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Crypto.open(column(stmt, 5))
            let ocr = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil
                : Crypto.open(column(stmt, 10)).flatMap { String(data: $0, encoding: .utf8) }
            let label = sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil
                : Crypto.open(column(stmt, 11)).flatMap { String(data: $0, encoding: .utf8) }
            result.append(ClipItem(
                id: sqlite3_column_int64(stmt, 0),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                kind: ClipKind(rawValue: String(cString: sqlite3_column_text(stmt, 2))) ?? .text,
                uti: String(cString: sqlite3_column_text(stmt, 3)),
                preview: preview,
                thumb: thumb,
                ocrText: ocr,
                byteSize: Int(sqlite3_column_int64(stmt, 6)),
                contentHash: String(cString: sqlite3_column_text(stmt, 7)),
                sourceApp: sqlite3_column_text(stmt, 8).map { String(cString: $0) },
                pinned: sqlite3_column_int(stmt, 9) != 0,
                label: label
            ))
        }
        items = result
        version += 1
    }

    // MARK: - SQLite helpers

    private func hasColumn(_ name: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(items)", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if String(cString: sqlite3_column_text(stmt, 1)) == name { return true }
        }
        return false
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func run(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.write(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.write(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ text: String) {
        sqlite3_bind_text(stmt, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ data: Data) {
        data.withUnsafeBytes { buf in
            _ = sqlite3_bind_blob(stmt, index, buf.baseAddress, Int32(buf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private func column(_ stmt: OpaquePointer?, _ index: Int32) -> Data {
        guard let ptr = sqlite3_column_blob(stmt, index) else { return Data() }
        return Data(bytes: ptr, count: Int(sqlite3_column_bytes(stmt, index)))
    }

    enum StoreError: Error {
        case open(String)
        case write(String)
    }
}
