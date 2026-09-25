import Foundation
import CSQLite

/// Actor confinement serializes all SQLite use. Only explicit user actions call put/delete.
public actor MemoryStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw JarvisError.message("Could not open memory database.") }
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA secure_delete=ON;
        CREATE TABLE IF NOT EXISTS memories (
          key TEXT PRIMARY KEY, value TEXT NOT NULL, source TEXT NOT NULL,
          updated REAL NOT NULL, revision INTEGER NOT NULL DEFAULT 1
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(key UNINDEXED, value, content='memories', content_rowid='rowid');
        CREATE TRIGGER IF NOT EXISTS memory_ai AFTER INSERT ON memories BEGIN
          INSERT INTO memory_fts(rowid,key,value) VALUES(new.rowid,new.key,new.value);
        END;
        CREATE TRIGGER IF NOT EXISTS memory_ad AFTER DELETE ON memories BEGIN
          INSERT INTO memory_fts(memory_fts,rowid,key,value) VALUES('delete',old.rowid,old.key,old.value);
        END;
        CREATE TRIGGER IF NOT EXISTS memory_au AFTER UPDATE ON memories BEGIN
          INSERT INTO memory_fts(memory_fts,rowid,key,value) VALUES('delete',old.rowid,old.key,old.value);
          INSERT INTO memory_fts(rowid,key,value) VALUES(new.rowid,new.key,new.value);
        END;
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            let reason = String(cString: sqlite3_errmsg(db)); sqlite3_close(db); db = nil
            throw JarvisError.message("Memory schema failed: \(reason)")
        }
        sqlite3_busy_timeout(db, 3000)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { sqlite3_close(db) }

    @discardableResult public func put(key: String, value: String, source: String) throws -> Memory {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 80, !value.isEmpty, value.count <= 2000, source.count <= 4000 else {
            throw JarvisError.message("Invalid memory size or empty memory.")
        }
        try Task.checkCancellation()
        let stmt = try prepare("""
        INSERT INTO memories(key,value,source,updated) VALUES(?,?,?,?)
        ON CONFLICT(key) DO UPDATE SET value=excluded.value, source=excluded.source,
        updated=excluded.updated, revision=memories.revision+1
        WHERE memories.value != excluded.value
        """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, key); bind(stmt, 2, value); bind(stmt, 3, source)
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        try done(stmt)
        return try all().first { $0.key == key }!
    }

    public func all() throws -> [Memory] {
        let stmt = try prepare("SELECT key,value,source,updated,revision FROM memories ORDER BY updated DESC,key")
        defer { sqlite3_finalize(stmt) }; return try rows(stmt)
    }

    public func relevant(to text: String, limit: Int = 12) throws -> [Memory] {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }.prefix(16)
        guard !words.isEmpty else { return [] }
        let stmt = try prepare("""
        SELECT m.key,m.value,m.source,m.updated,m.revision FROM memory_fts
        JOIN memories m ON m.rowid=memory_fts.rowid WHERE memory_fts MATCH ? ORDER BY rank LIMIT ?
        """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, words.map { "\"\($0)\"" }.joined(separator: " OR "))
        sqlite3_bind_int(stmt, 2, Int32(max(1, min(limit, 30))))
        return try rows(stmt)
    }

    public func delete(key: String) throws {
        try Task.checkCancellation()
        let stmt = try prepare("DELETE FROM memories WHERE key=?")
        defer { sqlite3_finalize(stmt) }; bind(stmt, 1, key); try done(stmt)
        // Purge FTS tombstones and checkpoint so deleted text isn't kept in our live WAL.
        guard sqlite3_exec(db, "INSERT INTO memory_fts(memory_fts) VALUES('optimize'); PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil) == SQLITE_OK else {
            throw failure()
        }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        return stmt
    }
    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ text: String) {
        _ = text.withCString { sqlite3_bind_text(stmt, index, $0, -1, transient) }
    }
    private func done(_ stmt: OpaquePointer) throws { guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() } }
    private func failure() -> JarvisError { .message("Memory database error: \(String(cString: sqlite3_errmsg(db)))") }
    private func rows(_ stmt: OpaquePointer) throws -> [Memory] {
        var result: [Memory] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            func string(_ i: Int32) -> String { String(cString: sqlite3_column_text(stmt, i)) }
            result.append(Memory(key: string(0), value: string(1), source: string(2),
                                 updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                                 revision: Int(sqlite3_column_int(stmt, 4))))
        }
    }
}
