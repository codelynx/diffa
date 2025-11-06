import Foundation

/// Handles comparison operations between two snapshots using SQL queries
class ComparisonEngine {
    /// Escape single quotes in SQL string literals by doubling them
    /// - Parameter path: The file path to escape
    /// - Returns: Escaped path safe for SQL string literals
    private func escapeSQLString(_ path: String) -> String {
        return path.replacingOccurrences(of: "'", with: "''")
    }

    /// Find items added in destination (not present in source)
    /// - Parameters:
    ///   - source: The source snapshot
    ///   - destination: The destination snapshot
    /// - Returns: Array of added items
    func findAdded(source: Snapshot, destination: Snapshot) throws -> [SnapshotItem] {
        // Attach destination database as "dest" - escape path to prevent SQL injection
        let escapedPath = escapeSQLString(destination.databaseURL.path)
        try source.database.execute("ATTACH DATABASE '\(escapedPath)' AS dest")
        defer {
            try? source.database.execute("DETACH DATABASE dest")
        }

        // Query: items in destination but not in source
        let sql = """
            SELECT d.id, d.parent_id, d.path, d.name, d.is_folder, d.size,
                   d.modification_date, d.permissions, d.owner, d.group_name, d.sha256
            FROM dest.items d
            LEFT JOIN main.items s ON d.path = s.path
            WHERE s.path IS NULL
            ORDER BY d.path
            """

        let rows = try source.database.query(sql)
        return try rows.map { try parseSnapshotItem(from: $0) }
    }

    /// Find items removed from source (not present in destination)
    /// - Parameters:
    ///   - source: The source snapshot
    ///   - destination: The destination snapshot
    /// - Returns: Array of removed items
    func findRemoved(source: Snapshot, destination: Snapshot) throws -> [SnapshotItem] {
        // Attach destination database as "dest" - escape path to prevent SQL injection
        let escapedPath = escapeSQLString(destination.databaseURL.path)
        try source.database.execute("ATTACH DATABASE '\(escapedPath)' AS dest")
        defer {
            try? source.database.execute("DETACH DATABASE dest")
        }

        // Query: items in source but not in destination
        let sql = """
            SELECT s.id, s.parent_id, s.path, s.name, s.is_folder, s.size,
                   s.modification_date, s.permissions, s.owner, s.group_name, s.sha256
            FROM main.items s
            LEFT JOIN dest.items d ON s.path = d.path
            WHERE d.path IS NULL
            ORDER BY s.path
            """

        let rows = try source.database.query(sql)
        return try rows.map { try parseSnapshotItem(from: $0) }
    }

    /// Find items modified between source and destination
    /// - Parameters:
    ///   - source: The source snapshot
    ///   - destination: The destination snapshot
    /// - Returns: Array of modified items (from destination)
    func findModified(source: Snapshot, destination: Snapshot) throws -> [SnapshotItem] {
        // Attach destination database as "dest" - escape path to prevent SQL injection
        let escapedPath = escapeSQLString(destination.databaseURL.path)
        try source.database.execute("ATTACH DATABASE '\(escapedPath)' AS dest")
        defer {
            try? source.database.execute("DETACH DATABASE dest")
        }

        // Query: items in both snapshots but with differences
        // Compare sha256 (for files), size, modification_date (files only), permissions
        // Note: Directory modification times are excluded because they change whenever
        // files inside them are added/removed, making them unreliable for comparison
        let sql = """
            SELECT d.id, d.parent_id, d.path, d.name, d.is_folder, d.size,
                   d.modification_date, d.permissions, d.owner, d.group_name, d.sha256
            FROM dest.items d
            INNER JOIN main.items s ON d.path = s.path
            WHERE (d.sha256 IS NOT NULL AND s.sha256 IS NOT NULL AND d.sha256 != s.sha256)
               OR d.size != s.size
               OR (d.is_folder = 0 AND d.modification_date != s.modification_date)
               OR d.permissions != s.permissions
            ORDER BY d.path
            """

        let rows = try source.database.query(sql)
        return try rows.map { try parseSnapshotItem(from: $0) }
    }

    /// Parse a SQLiteRow into a SnapshotItem
    /// - Parameter row: The database row
    /// - Returns: Parsed SnapshotItem
    private func parseSnapshotItem(from row: SQLiteRow) throws -> SnapshotItem {
        let id = try row.int64(at: 0)

        // Handle nullable parent_id
        let parentId: Int64?
        let parentValue = try row.value(at: 1)
        if case .null = parentValue {
            parentId = nil
        } else if case .integer(let value) = parentValue {
            parentId = value
        } else {
            throw SQLiteError.invalidColumnType(column: "parent_id", expected: "INTEGER or NULL")
        }

        let path = try row.string(at: 2)!
        let name = try row.string(at: 3)!
        let isFolder = try row.int64(at: 4) != 0
        let size = try row.int64(at: 5)
        let modDateTimestamp = try row.int64(at: 6)
        let permissionsInt = try row.int64(at: 7)
        let owner = try row.string(at: 8)
        let group = try row.string(at: 9)
        let sha256 = try row.string(at: 10)

        return SnapshotItem(
            id: id,
            parentId: parentId,
            path: path,
            name: name,
            isFolder: isFolder,
            size: size,
            modificationDate: DateFormatting.fromUnixTimestamp(modDateTimestamp),
            permissions: FilePermissions(posix: UInt16(permissionsInt)),
            owner: owner,
            group: group,
            sha256: sha256
        )
    }
}
