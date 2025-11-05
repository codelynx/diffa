import Foundation

/// Schema definition for snapshot SQLite database
enum SnapshotSchema {
    /// Current schema version
    static let version = 1

    /// Create all tables and indexes for snapshot database
    /// - Parameter db: SQLite database to create tables in
    static func createTables(in db: SQLiteDatabase) throws {
        // Schema version table
        try db.execute("""
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY,
                created_date INTEGER NOT NULL,
                library_version TEXT NOT NULL
            )
            """)

        // Metadata table - stores snapshot-level information
        try db.execute("""
            CREATE TABLE IF NOT EXISTS metadata (
                root_path TEXT PRIMARY KEY,
                created_date INTEGER NOT NULL,
                total_files INTEGER NOT NULL,
                total_folders INTEGER NOT NULL,
                total_size INTEGER NOT NULL
            )
            """)

        // Items table - stores all files and folders
        try db.execute("""
            CREATE TABLE IF NOT EXISTS items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                parent_id INTEGER REFERENCES items(id),
                path TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL,
                is_folder INTEGER NOT NULL,
                size INTEGER NOT NULL,
                modification_date INTEGER NOT NULL,
                permissions INTEGER NOT NULL,
                owner TEXT,
                group_name TEXT,
                sha256 TEXT
            )
            """)

        // Create indexes for efficient querying
        try db.execute("CREATE INDEX IF NOT EXISTS idx_items_path ON items(path)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_items_parent ON items(parent_id)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_items_sha256 ON items(sha256)")

        // Insert schema version
        try db.run(
            "INSERT OR REPLACE INTO schema_version (version, created_date, library_version) VALUES (?, ?, ?)",
            [
                .integer(Int64(version)),
                .integer(DateFormatting.toUnixTimestamp(Date())),
                .text(libraryVersion)
            ]
        )
    }

    /// Verify database has correct schema version
    /// - Parameter db: SQLite database to verify
    /// - Returns: True if schema version matches
    static func verifyVersion(in db: SQLiteDatabase) throws -> Bool {
        guard try db.tableExists("schema_version") else {
            return false
        }

        let rows = try db.query("SELECT version FROM schema_version LIMIT 1")
        guard let row = rows.first else {
            return false
        }

        let dbVersion = try row.int64(at: 0)
        return dbVersion == version
    }

    /// Library version string
    private static var libraryVersion: String {
        // TODO: Extract from package info
        "0.1.0"
    }
}
