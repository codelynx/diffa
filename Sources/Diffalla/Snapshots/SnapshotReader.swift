import Foundation

/// Handles reading items from a snapshot database
class SnapshotReader {
    private let db: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.db = database
    }

    /// Load snapshot metadata (totals)
    /// - Returns: SnapshotMetadata with file/folder counts and total size
    func loadMetadata() throws -> SnapshotMetadata {
        let rows = try db.query("SELECT total_files, total_folders, total_size FROM metadata LIMIT 1")
        guard let row = rows.first else {
            throw SnapshotError.invalidSnapshot(reason: "Missing metadata")
        }

        let totalFiles = try Int(row.int64(at: 0))
        let totalFolders = try Int(row.int64(at: 1))
        let totalSize = try row.int64(at: 2)

        return SnapshotMetadata(
            totalFiles: totalFiles,
            totalFolders: totalFolders,
            totalSize: totalSize,
            version: SnapshotSchema.version
        )
    }

    /// Load all items from the snapshot
    /// - Returns: Array of all SnapshotItems
    func loadAllItems() throws -> [SnapshotItem] {
        let rows = try db.query("""
            SELECT id, parent_id, path, name, is_folder, size,
                   modification_date, permissions, owner, group_name, sha256
            FROM items
            ORDER BY path
            """)

        return try rows.map { try parseSnapshotItem(from: $0) }
    }

    /// Load a specific item by path
    /// - Parameter path: The relative path to find
    /// - Returns: SnapshotItem if found, nil otherwise
    func loadItem(path: String) throws -> SnapshotItem? {
        let rows = try db.query("""
            SELECT id, parent_id, path, name, is_folder, size,
                   modification_date, permissions, owner, group_name, sha256
            FROM items
            WHERE path = ?
            """, [.text(path)])

        guard let row = rows.first else {
            return nil
        }

        return try parseSnapshotItem(from: row)
    }

    /// Load all children of a given parent
    /// - Parameter parentId: The parent's database row ID
    /// - Returns: Array of child SnapshotItems
    func loadChildren(of parentId: Int64) throws -> [SnapshotItem] {
        let rows = try db.query("""
            SELECT id, parent_id, path, name, is_folder, size,
                   modification_date, permissions, owner, group_name, sha256
            FROM items
            WHERE parent_id = ?
            ORDER BY name
            """, [.integer(parentId)])

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
