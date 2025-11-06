import Foundation

/// Persistent cache for file hashes to speed up snapshot creation
///
/// The hash cache stores SHA-256 hashes for files along with their size and
/// modification date. On subsequent scans, if a file's size and mtime haven't
/// changed, the cached hash is reused instead of recomputing.
///
/// **Cache Invalidation:**
/// - Cache hit: Same path, size, and mtime → Use cached hash
/// - Cache miss: Any difference → Recompute hash
/// - Prune: Remove entries for files that no longer exist
///
/// **Storage:**
/// Each cache is stored in a separate SQLite database file, typically in
/// ~/.diffa/cache/<directory-hash>.db
public class HashCache {
    private let database: SQLiteDatabase
    private let dateFormatter: ISO8601DateFormatter
    private let queue: DispatchQueue

    /// Create or open a hash cache database
    ///
    /// - Parameter url: Path to cache database file
    /// - Throws: SQLiteError if database creation fails
    public init(at url: URL) throws {
        self.database = try SQLiteDatabase(path: url.path)
        self.dateFormatter = ISO8601DateFormatter()
        self.queue = DispatchQueue(label: "com.diffa.hashcache.\(UUID().uuidString)")

        // Create schema if needed
        try createSchema()
    }

    /// Look up cached hash for a file
    ///
    /// Returns the cached hash if the file's size and modification date match
    /// the cached values. If any attribute differs, returns nil (cache miss).
    ///
    /// - Parameters:
    ///   - path: File path (relative or absolute)
    ///   - size: Current file size
    ///   - modificationDate: Current file modification date
    /// - Returns: Cached SHA-256 hash if valid, nil otherwise
    /// - Throws: SQLiteError on database errors
    public func lookup(path: String, size: Int64, modificationDate: Date) throws -> String? {
        try queue.sync {
            try lookupUnlocked(path: path, size: size, modificationDate: modificationDate)
        }
    }

    private func lookupUnlocked(path: String, size: Int64, modificationDate: Date) throws -> String? {
        let sql = """
            SELECT sha256, size, modification_date
            FROM hash_cache
            WHERE path = ?
            """

        let statement = try database.prepare(sql)
        try statement.bind([.text(path)])
        let rows = try statement.query()

        guard let row = rows.first else {
            // No cached entry for this path
            return nil
        }

        guard let cachedHash = try row.string(at: 0) else {
            // NULL hash → cache miss
            return nil
        }
        let cachedSize = try row.int64(at: 1)
        guard let cachedDateString = try row.string(at: 2) else {
            // NULL date → cache miss
            return nil
        }

        // Validate cached entry
        guard cachedSize == size else {
            // Size changed → cache miss
            return nil
        }

        guard let cachedDate = dateFormatter.date(from: cachedDateString) else {
            // Invalid date format → cache miss
            return nil
        }

        // Compare modification dates (allowing 1 second tolerance for file system precision)
        let timeDifference = abs(modificationDate.timeIntervalSince(cachedDate))
        guard timeDifference < 1.0 else {
            // Modification date changed → cache miss
            return nil
        }

        // Cache hit!
        return cachedHash
    }

    /// Store hash for a file
    ///
    /// Stores the SHA-256 hash along with the file's size and modification date.
    /// If an entry already exists for this path, it is replaced.
    ///
    /// - Parameters:
    ///   - path: File path
    ///   - size: File size
    ///   - modificationDate: File modification date
    ///   - hash: SHA-256 hash to cache
    /// - Throws: SQLiteError on database errors
    public func store(path: String, size: Int64, modificationDate: Date, hash: String) throws {
        try queue.sync {
            try storeUnlocked(path: path, size: size, modificationDate: modificationDate, hash: hash)
        }
    }

    private func storeUnlocked(path: String, size: Int64, modificationDate: Date, hash: String) throws {
        let sql = """
            INSERT OR REPLACE INTO hash_cache (path, size, modification_date, sha256, cached_at)
            VALUES (?, ?, ?, ?, ?)
            """

        let statement = try database.prepare(sql)

        let modDateString = dateFormatter.string(from: modificationDate)
        let cachedAtString = dateFormatter.string(from: Date())

        try statement.bind([
            .text(path),
            .integer(size),
            .text(modDateString),
            .text(hash),
            .text(cachedAtString)
        ])

        try statement.execute()
    }

    /// Remove stale entries (files that no longer exist)
    ///
    /// Deletes cache entries for paths not in the provided set. This is typically
    /// called after a directory scan to remove entries for deleted files.
    ///
    /// - Parameter validPaths: Set of paths that currently exist
    /// - Throws: SQLiteError on database errors
    public func prune(validPaths: Set<String>) throws {
        try queue.sync {
            try pruneUnlocked(validPaths: validPaths)
        }
    }

    private func pruneUnlocked(validPaths: Set<String>) throws {
        // For large path sets, this could be optimized with a temporary table
        // For now, use a simple approach: delete entries not in the valid set

        if validPaths.isEmpty {
            // If no valid paths, clear everything
            try clearUnlocked()
            return
        }

        // Get all cached paths
        let selectSql = "SELECT path FROM hash_cache"
        let selectStatement = try database.prepare(selectSql)
        let rows = try selectStatement.query()

        var pathsToDelete: [String] = []
        for row in rows {
            guard let cachedPath = try row.string(at: 0) else { continue }
            if !validPaths.contains(cachedPath) {
                pathsToDelete.append(cachedPath)
            }
        }

        // Delete stale entries
        if !pathsToDelete.isEmpty {
            let deleteSql = "DELETE FROM hash_cache WHERE path = ?"
            let deleteStatement = try database.prepare(deleteSql)

            try database.transaction {
                for path in pathsToDelete {
                    deleteStatement.reset()
                    try deleteStatement.bind([.text(path)])
                    try deleteStatement.execute()
                }
            }
        }
    }

    /// Clear all cached hashes
    ///
    /// Removes all entries from the cache. Useful for testing or when you want
    /// to force a full recomputation of all hashes.
    ///
    /// - Throws: SQLiteError on database errors
    public func clear() throws {
        try queue.sync {
            try clearUnlocked()
        }
    }

    private func clearUnlocked() throws {
        let sql = "DELETE FROM hash_cache"
        let statement = try database.prepare(sql)
        try statement.execute()
    }

    // MARK: - Private Helpers

    /// Create database schema if it doesn't exist
    private func createSchema() throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS hash_cache (
                path TEXT PRIMARY KEY,
                size INTEGER NOT NULL,
                modification_date TEXT NOT NULL,
                sha256 TEXT NOT NULL,
                cached_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_cached_at ON hash_cache(cached_at);
            """

        let statement = try database.prepare(sql)
        try statement.execute()
    }
}

extension HashCache: @unchecked Sendable {}
