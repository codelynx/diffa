import Foundation

/// SQLite schema for EfficientSync snapshots
///
/// **Design:**
/// - Flat structure (no parent_id hierarchies)
/// - Hash index for move detection and deduplication
/// - Minimal metadata for memory efficiency
///
/// **Tables:**
/// 1. `files`: File metadata (path is primary key)
/// 2. `metadata`: Snapshot metadata (root path, creation time)
///
/// **Example:**
/// ```swift
/// let db = try SQLiteDatabase(path: "/path/to/snapshot.db")
/// try SyncSnapshotSchema.createTables(in: db)
///
/// // Insert file
/// try db.execute(
///     "INSERT INTO files (path, size, hash, mtime, mode) VALUES (?, ?, ?, ?, ?)",
///     [.text("photos/vacation.jpg"), .integer(2048576), .blob(hashData), .integer(1699459200), .integer(0o644)]
/// )
///
/// // Query by hash (for move detection)
/// let rows = try db.query("SELECT path FROM files WHERE hash = ?", [.blob(hashData)])
/// ```
public enum SyncSnapshotSchema {
    /// Schema version (for future migrations)
    public static let version = 1

    /// Create all tables and indexes
    ///
    /// Safe to call multiple times (uses IF NOT EXISTS).
    ///
    /// - Parameter db: SQLite database connection
    /// - Throws: SQLiteError if creation fails
    public static func createTables(in db: SQLiteDatabase) throws {
        // Files table: flat structure, path is primary key
        try db.execute("""
            CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY NOT NULL,
                size INTEGER NOT NULL,
                hash BLOB NOT NULL,
                mtime INTEGER NOT NULL,
                mode INTEGER
            );
        """)

        // Hash index for move detection and deduplication
        // Enables fast queries: SELECT path FROM files WHERE hash = ?
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_hash ON files(hash);
        """)

        // Metadata table: key-value store for snapshot info
        try db.execute("""
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT
            );
        """)

        // Insert schema version
        try db.run("""
            INSERT OR REPLACE INTO metadata (key, value) VALUES ('schema_version', ?);
        """, [.text("\(version)")])
    }

    /// Verify schema version is compatible.
    ///
    /// Gracefully handles legacy snapshots that lack the metadata table or schema_version row.
    ///
    /// - Parameter db: SQLite database connection
    /// - Returns: true if compatible, false for incompatible or legacy schemas
    public static func verifyVersion(in db: SQLiteDatabase) -> Bool {
        do {
            let rows = try db.query("SELECT value FROM metadata WHERE key = 'schema_version'")
            guard let row = rows.first,
                  let versionStr = try? row.string(at: 0),
                  let schemaVersion = Int(versionStr) else {
                return false
            }

            return schemaVersion == version
        } catch {
            // Legacy snapshot (no metadata table) or other error
            return false
        }
    }
}
