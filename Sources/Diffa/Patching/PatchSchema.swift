import Foundation

/// Schema definition for patch SQLite database
enum PatchSchema {
    /// Current schema version
    static let version = 1

    /// Create all tables and indexes for patch database
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

        // Metadata table - stores patch-level information
        try db.execute("""
            CREATE TABLE IF NOT EXISTS metadata (
                id INTEGER PRIMARY KEY,
                version INTEGER NOT NULL,
                created_date INTEGER NOT NULL,
                source_checksum TEXT,
                target_checksum TEXT,
                operation_count INTEGER NOT NULL
            )
            """)

        // Operations table - stores all patch operations in sequence
        try db.execute("""
            CREATE TABLE IF NOT EXISTS operations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                sequence_order INTEGER NOT NULL,
                type TEXT NOT NULL,
                path TEXT NOT NULL,
                path_to TEXT,
                is_folder INTEGER NOT NULL,
                content_blob BLOB,
                metadata_json TEXT
            )
            """)

        // Create index for efficient sequential access
        try db.execute("CREATE INDEX IF NOT EXISTS idx_operations_sequence ON operations(sequence_order)")

        // Revert data table - stores original file state for revert
        try db.execute("""
            CREATE TABLE IF NOT EXISTS revert_data (
                path TEXT PRIMARY KEY,
                original_content_blob BLOB,
                original_metadata_json TEXT,
                cache_reference TEXT
            )
            """)

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
