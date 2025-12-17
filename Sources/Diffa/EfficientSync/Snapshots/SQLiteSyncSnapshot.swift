import Foundation

/// SQLite-backed snapshot implementation for EfficientSync
///
/// **Design:**
/// - Streaming creation: scan → hash → insert (one file at a time)
/// - Memory efficient: O(1) for creation, SQLite handles storage
/// - SHA-256 hashing consistent with Phase 1-5
///
/// **Example:**
/// ```swift
/// // Create snapshot
/// let snapshot = try SQLiteSyncSnapshot.create(at: URL(fileURLWithPath: "/path/to/photos"))
///
/// // Query files
/// if let file = snapshot.fileByPath("vacation.jpg") {
///     print("Size: \(file.size)")
/// }
///
/// // Find duplicates
/// let dupes = snapshot.filesByHash(someHash)
/// ```
public final class SQLiteSyncSnapshot: SyncSnapshot {
    private let database: SQLiteDatabase
    private let rootPath: String

    /// Database file path (for debugging/testing)
    public var databasePath: String {
        database.path
    }

    /// Root directory path this snapshot represents
    public var root: String {
        rootPath
    }

    // MARK: - Initialization

    private init(database: SQLiteDatabase, rootPath: String) {
        self.database = database
        self.rootPath = rootPath
    }

    /// Create snapshot from directory (streaming, memory efficient)
    ///
    /// Scans directory, hashes each file, and inserts into SQLite.
    /// Processing is streaming: one file at a time (no full tree in memory).
    ///
    /// - Parameter root: Directory to snapshot
    /// - Parameter dbPath: Optional path for database file (default: temp file)
    /// - Returns: SQLiteSyncSnapshot instance
    /// - Throws: ScannerError, HasherError, or SQLiteError
    public static func create(
        at root: URL,
        dbPath: String? = nil
    ) throws -> SQLiteSyncSnapshot {
        // Create database (temp file if not specified)
        let path = dbPath ?? NSTemporaryDirectory() + "sync-snapshot-\(UUID().uuidString).db"
        let db = try SQLiteDatabase(path: path)

        // Initialize schema
        try SyncSnapshotSchema.createTables(in: db)

        // Store root path in metadata
        try db.run(
            "INSERT OR REPLACE INTO metadata (key, value) VALUES ('root_path', ?)",
            [.text(root.path)]
        )

        // Prepare insert statement for reuse
        let insertSQL = "INSERT INTO files (path, size, hash, mtime, mode) VALUES (?, ?, ?, ?, ?)"

        // Scan and hash files (streaming)
        let scanner = FileSystemScanner()
        let hasher = FileHasher()

        try scanner.scan(root: root) { fileURL, metadata in
            // Hash file content
            let hash = try hasher.hash(fileAt: fileURL)

            // Insert immediately (no accumulation)
            try db.run(insertSQL, [
                .text(metadata.path),
                .integer(metadata.size),
                .blob(hash),
                .integer(metadata.mtime),
                metadata.mode.map { SQLiteValue.integer(Int64($0)) } ?? .null
            ])
        }

        return SQLiteSyncSnapshot(database: db, rootPath: root.path)
    }

    /// Open existing snapshot database
    ///
    /// - Parameter dbPath: Path to snapshot database file
    /// - Returns: SQLiteSyncSnapshot instance
    /// - Throws: SQLiteError or SnapshotError
    public static func open(at dbPath: String) throws -> SQLiteSyncSnapshot {
        let db = try SQLiteDatabase(path: dbPath)

        // Verify schema version
        guard SyncSnapshotSchema.verifyVersion(in: db) else {
            throw SyncSnapshotError.incompatibleSchema(path: dbPath)
        }

        // Get root path from metadata
        let rows = try db.query("SELECT value FROM metadata WHERE key = 'root_path'")
        guard let row = rows.first,
              let rootPath = try? row.string(at: 0) else {
            throw SyncSnapshotError.missingMetadata(key: "root_path")
        }

        return SQLiteSyncSnapshot(database: db, rootPath: rootPath)
    }

    // MARK: - SyncSnapshot Protocol

    public func fileByPath(_ path: String) -> FileItem? {
        do {
            let rows = try database.query(
                "SELECT path, size, hash, mtime, mode FROM files WHERE path = ?",
                [.text(path)]
            )
            return rows.first.map { rowToFileItem($0) }
        } catch {
            return nil
        }
    }

    public func filesByHash(_ hash: Data) -> [FileItem] {
        do {
            let rows = try database.query(
                "SELECT path, size, hash, mtime, mode FROM files WHERE hash = ?",
                [.blob(hash)]
            )
            return rows.map { rowToFileItem($0) }
        } catch {
            return []
        }
    }

    public func allFiles() -> [FileItem] {
        do {
            let rows = try database.query(
                "SELECT path, size, hash, mtime, mode FROM files ORDER BY path"
            )
            return rows.map { rowToFileItem($0) }
        } catch {
            return []
        }
    }

    // MARK: - Statistics

    /// Total number of files in snapshot
    public var fileCount: Int {
        do {
            let rows = try database.query("SELECT COUNT(*) FROM files")
            if let row = rows.first, let count = try? row.int64(at: 0) {
                return Int(count)
            }
        } catch {}
        return 0
    }

    /// Total size of all files in bytes
    public var totalSize: Int64 {
        do {
            let rows = try database.query("SELECT SUM(size) FROM files")
            if let row = rows.first, let sum = try? row.int64(at: 0) {
                return sum
            }
        } catch {}
        return 0
    }

    // MARK: - Private Helpers

    private func rowToFileItem(_ row: SQLiteRow) -> FileItem {
        FileItem(
            path: (try? row.string(at: 0)) ?? "",
            size: (try? row.int64(at: 1)) ?? 0,
            hash: (try? row.data(at: 2)) ?? Data(),
            mtime: (try? row.int64(at: 3)) ?? 0,
            mode: (try? row.int64(at: 4)).map { UInt16($0) }
        )
    }
}

// MARK: - Errors

/// SyncSnapshot-related errors
public enum SyncSnapshotError: Error, CustomStringConvertible {
    case incompatibleSchema(path: String)
    case missingMetadata(key: String)
    case invalidPath(path: String)

    public var description: String {
        switch self {
        case .incompatibleSchema(let path):
            return "Incompatible snapshot schema: \(path)"
        case .missingMetadata(let key):
            return "Missing metadata key: \(key)"
        case .invalidPath(let path):
            return "Invalid path: \(path)"
        }
    }
}
