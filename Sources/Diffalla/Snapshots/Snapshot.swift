import Foundation

/// Metadata about a snapshot
public struct SnapshotMetadata: Codable {
    /// Total number of files in snapshot
    public let totalFiles: Int

    /// Total number of folders in snapshot
    public let totalFolders: Int

    /// Total size in bytes of all files
    public let totalSize: Int64

    /// Schema version
    public let version: Int

    public init(totalFiles: Int, totalFolders: Int, totalSize: Int64, version: Int) {
        self.totalFiles = totalFiles
        self.totalFolders = totalFolders
        self.totalSize = totalSize
        self.version = version
    }
}

/// A snapshot of a directory at a point in time
public struct Snapshot {
    /// Path to the SQLite database file
    public let databaseURL: URL

    /// Root path that was snapshotted
    public let rootPath: String

    /// Date the snapshot was created
    public let createdDate: Date

    /// Snapshot metadata (file counts, size)
    public let metadata: SnapshotMetadata

    /// Internal database connection
    internal let database: SQLiteDatabase

    /// Create a new empty snapshot database
    /// - Parameters:
    ///   - url: Location to create the snapshot database
    ///   - rootPath: Root directory path being snapshotted
    /// - Returns: New Snapshot instance
    public static func create(at url: URL, rootPath: String) throws -> Snapshot {
        // Create database
        let db = try SQLiteDatabase(path: url.path)

        // Create schema
        try SnapshotSchema.createTables(in: db)

        // Insert initial metadata
        let now = Date()
        let metadata = SnapshotMetadata(
            totalFiles: 0,
            totalFolders: 0,
            totalSize: 0,
            version: SnapshotSchema.version
        )

        try db.run(
            "INSERT INTO metadata (root_path, created_date, total_files, total_folders, total_size) VALUES (?, ?, ?, ?, ?)",
            [
                .text(rootPath),
                .text(ISO8601DateFormatter().string(from: now)),
                .integer(0),
                .integer(0),
                .integer(0)
            ]
        )

        return Snapshot(
            databaseURL: url,
            rootPath: rootPath,
            createdDate: now,
            metadata: metadata,
            database: db
        )
    }

    /// Open an existing snapshot database
    /// - Parameter url: Path to existing snapshot database
    /// - Returns: Snapshot instance
    public static func open(at url: URL) throws -> Snapshot {
        // Check file exists BEFORE opening (sqlite3_open creates the file if it doesn't exist)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SnapshotError.snapshotNotFound(path: url.path)
        }

        // Open database
        let db = try SQLiteDatabase(path: url.path)

        // Verify schema version
        guard try SnapshotSchema.verifyVersion(in: db) else {
            throw SnapshotError.incompatibleVersion(path: url.path)
        }

        // Load metadata
        let rows = try db.query("SELECT root_path, created_date, total_files, total_folders, total_size FROM metadata LIMIT 1")
        guard let row = rows.first else {
            throw SnapshotError.invalidSnapshot(reason: "Missing metadata")
        }

        guard let rootPath = try row.string(at: 0) else {
            throw SnapshotError.invalidSnapshot(reason: "Missing root_path")
        }
        guard let createdDateString = try row.string(at: 1) else {
            throw SnapshotError.invalidSnapshot(reason: "Missing created_date")
        }
        let totalFiles = try Int(row.int64(at: 2))
        let totalFolders = try Int(row.int64(at: 3))
        let totalSize = try row.int64(at: 4)

        // Parse date
        guard let createdDate = ISO8601DateFormatter().date(from: createdDateString) else {
            throw SnapshotError.invalidSnapshot(reason: "Invalid date format: \(createdDateString)")
        }

        let metadata = SnapshotMetadata(
            totalFiles: totalFiles,
            totalFolders: totalFolders,
            totalSize: totalSize,
            version: SnapshotSchema.version
        )

        return Snapshot(
            databaseURL: url,
            rootPath: rootPath,
            createdDate: createdDate,
            metadata: metadata,
            database: db
        )
    }

    /// Private initializer - use create() or open() instead
    private init(databaseURL: URL, rootPath: String, createdDate: Date, metadata: SnapshotMetadata, database: SQLiteDatabase) {
        self.databaseURL = databaseURL
        self.rootPath = rootPath
        self.createdDate = createdDate
        self.metadata = metadata
        self.database = database
    }
}

// MARK: - Errors

enum SnapshotError: Error, CustomStringConvertible {
    case snapshotNotFound(path: String)
    case incompatibleVersion(path: String)
    case invalidSnapshot(reason: String)
    case snapshotCreationFailed(reason: String)
    case snapshotLoadFailed(reason: String)

    var description: String {
        switch self {
        case .snapshotNotFound(let path):
            return "Snapshot not found at: \(path)"
        case .incompatibleVersion(let path):
            return "Incompatible snapshot version at: \(path)"
        case .invalidSnapshot(let reason):
            return "Invalid snapshot: \(reason)"
        case .snapshotCreationFailed(let reason):
            return "Snapshot creation failed: \(reason)"
        case .snapshotLoadFailed(let reason):
            return "Snapshot load failed: \(reason)"
        }
    }
}
