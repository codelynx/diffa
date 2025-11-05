import Foundation

/// Handles writing items to a snapshot database
class SnapshotWriter {
    private let db: SQLiteDatabase
    // Only tracks ancestor directories in current traversal path (O(depth) not O(n))
    // Stack of (path, id) pairs for parent lookup
    private var ancestorStack: [(path: String, id: Int64)] = []

    init(database: SQLiteDatabase) {
        self.db = database
    }

    /// Insert a FileSystemItem into the database
    /// - Parameters:
    ///   - item: The item to insert
    ///   - parentPath: Optional parent path (for computing parent_id)
    /// - Returns: The database row ID of the inserted item
    func insertItem(_ item: FileSystemItem, parentPath: String?) throws -> Int64 {
        // Get parent_id if this item has a parent
        let parentId = parentPath.flatMap { getParentId(for: $0) }

        // Extract name from path (last component)
        let name = extractName(from: item.path)

        // Prepare insert statement
        let sql = """
            INSERT INTO items (
                parent_id, path, name, is_folder, size,
                modification_date, permissions, owner, group_name, sha256
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """

        let stmt = try db.prepare(sql)

        // Bind values as array
        try stmt.bind([
            parentId.map { .integer($0) } ?? .null,
            .text(item.path),
            .text(name),
            .integer(item.isFolder ? 1 : 0),
            .integer(item.size),
            .integer(DateFormatting.toUnixTimestamp(item.metadata.modificationDate)),
            .integer(Int64(item.metadata.permissions.posix)),
            item.metadata.owner.map { .text($0) } ?? .null,
            item.metadata.group.map { .text($0) } ?? .null,
            item.sha256.map { .text($0) } ?? .null
        ])

        // Execute insert
        try stmt.execute()

        // Get the row ID
        let rowId = db.lastInsertRowID

        return rowId
    }

    /// Push a directory onto the ancestor stack (called when entering directory during traversal)
    /// - Parameters:
    ///   - path: Directory path
    ///   - id: Database row ID for this directory
    func pushDirectory(path: String, id: Int64) {
        ancestorStack.append((path: path, id: id))
    }

    /// Pop a directory from the ancestor stack (called when exiting directory during traversal)
    func popDirectory() {
        guard !ancestorStack.isEmpty else { return }
        ancestorStack.removeLast()
    }

    /// Update snapshot metadata with totals
    /// - Parameters:
    ///   - totalFiles: Total number of files
    ///   - totalFolders: Total number of folders
    ///   - totalSize: Total size in bytes
    func updateMetadata(totalFiles: Int, totalFolders: Int, totalSize: Int64) throws {
        let sql = """
            UPDATE metadata SET
                total_files = ?,
                total_folders = ?,
                total_size = ?
            """

        let stmt = try db.prepare(sql)

        try stmt.bind([
            .integer(Int64(totalFiles)),
            .integer(Int64(totalFolders)),
            .integer(totalSize)
        ])

        try stmt.execute()
    }

    /// Extract the name (last path component) from a path
    /// - Parameter path: The relative path
    /// - Returns: The name (last component)
    private func extractName(from path: String) -> String {
        if let lastSlash = path.lastIndex(of: "/") {
            return String(path[path.index(after: lastSlash)...])
        }
        return path
    }

    /// Get the database row ID for a given path
    /// - Parameter path: The path to lookup (should be in ancestor stack)
    /// - Returns: The row ID, or nil if not found
    private func getParentId(for path: String) -> Int64? {
        // Search from end of stack (most recent ancestors first)
        for (ancestorPath, ancestorId) in ancestorStack.reversed() {
            if ancestorPath == path {
                return ancestorId
            }
        }
        return nil
    }
}
