// MasterFabric Cut — Shared/Storage
// Author: Gürkan Fikret Günak · masterfabric.co
import Foundation
import SQLite3

/// Minimal SQLite wrapper (system libsqlite3, no dependencies). One connection, serialized by a lock.
final class Database {
    static let shared = Database()

    enum Value { case int(Int64), double(Double), text(String), null }

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    let url: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("MasterFabric Cut", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("MasterFabricCut.sqlite")
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            NSLog("Database: open failed, falling back to in-memory store")
            sqlite3_close(db)
            sqlite3_open(":memory:", &db)
        }
        exec("PRAGMA journal_mode=WAL")
        migrate()
    }

    // MARK: Schema

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS permissions (
            name TEXT PRIMARY KEY,
            requested INTEGER NOT NULL DEFAULT 0,
            last_status TEXT NOT NULL DEFAULT 'notDetermined',
            updated_at REAL NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS history (
            id TEXT PRIMARY KEY,
            date REAL NOT NULL,
            kind TEXT NOT NULL,
            file_path TEXT NOT NULL DEFAULT '',
            thumbnail_path TEXT,
            width INTEGER NOT NULL DEFAULT 0,
            height INTEGER NOT NULL DEFAULT 0,
            text TEXT);
        CREATE INDEX IF NOT EXISTS history_date ON history(date DESC);
        """)
    }

    // MARK: Execution

    @discardableResult
    func exec(_ sql: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            NSLog("Database: %@", err.map { String(cString: $0) } ?? "error \(rc)")
            sqlite3_free(err)
        }
        return rc == SQLITE_OK
    }

    /// Runs `sql` with bound parameters; `row` is called per result row. Returns success.
    @discardableResult
    func run(_ sql: String, _ params: [Value] = [], row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("Database: prepare failed: %@", String(cString: sqlite3_errmsg(db)))
            return false
        }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row?(stmt!); continue }
            if rc != SQLITE_DONE { NSLog("Database: step failed: %@", String(cString: sqlite3_errmsg(db))) }
            return rc == SQLITE_DONE
        }
    }

    func transaction(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        exec("BEGIN"); body(); exec("COMMIT")
    }

    // MARK: Column helpers

    static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }
}
