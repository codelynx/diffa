import Foundation

/// A patch that describes transformations between two directory states
public struct Patch {
    /// Path to the SQLite database file
    public let databaseURL: URL

    /// Patch metadata
    public let metadata: PatchMetadata

    /// Internal SQLite database handle
    internal let database: SQLiteDatabase

    /// Private initializer
    private init(databaseURL: URL, metadata: PatchMetadata, database: SQLiteDatabase) {
        self.databaseURL = databaseURL
        self.metadata = metadata
        self.database = database
    }

    /// Create a new patch from a Difference
    /// - Parameters:
    ///   - difference: The difference to create a patch from
    ///   - sourceDirectory: Source directory (needed for revert data in Step 6)
    ///   - destinationDirectory: Destination directory (needed for content in Step 4)
    ///   - patchURL: Where to save the patch database
    ///   - includeRevertData: Whether to include revert data (default: false)
    /// - Returns: Created patch
    public static func create(
        from difference: Difference,
        sourceDirectory: URL,
        destinationDirectory: URL,
        saveTo patchURL: URL,
        includeRevertData: Bool = false
    ) throws -> Patch {
        // Create database
        let database = try SQLiteDatabase(path: patchURL.path)
        try PatchSchema.createTables(in: database)

        // Create writer
        let writer = PatchWriter(database: database)

        // Convert difference to operations and read file content
        var sequenceOrder = 0
        var totalOperations = 0

        // Process added items (read content from destination)
        let added = try difference.added
        for item in added {
            let operation = PatchOperation.add(path: item.path, isFolder: item.isFolder)
            let metadata = convertToMetadata(item)

            // Read content for files (not folders)
            let content: Data?
            if !item.isFolder {
                let fileURL = destinationDirectory.appendingPathComponent(item.path)
                do {
                    content = try Data(contentsOf: fileURL)
                } catch {
                    throw DiffallaError.snapshotCreationFailed(
                        reason: "Failed to read file content for '\(item.path)': \(error.localizedDescription)"
                    )
                }
            } else {
                content = nil
            }

            try writer.writeOperation(operation, metadata: metadata, sequenceOrder: sequenceOrder, content: content)
            sequenceOrder += 1
            totalOperations += 1
        }

        // Process removed items (reverse order: children before parents, no content needed)
        let removed = try difference.removed
        for item in removed.reversed() {
            let operation = PatchOperation.remove(path: item.path, isFolder: item.isFolder)
            let metadata = convertToMetadata(item)
            try writer.writeOperation(operation, metadata: metadata, sequenceOrder: sequenceOrder, content: nil)
            sequenceOrder += 1
            totalOperations += 1
        }

        // Process modified items (read new content from destination)
        let modified = try difference.modified
        for item in modified {
            let operation = PatchOperation.modify(path: item.path, isFolder: item.isFolder)
            let metadata = convertToMetadata(item)

            // Read content for files (not folders)
            let content: Data?
            if !item.isFolder {
                let fileURL = destinationDirectory.appendingPathComponent(item.path)
                do {
                    content = try Data(contentsOf: fileURL)
                } catch {
                    throw DiffallaError.snapshotCreationFailed(
                        reason: "Failed to read file content for '\(item.path)': \(error.localizedDescription)"
                    )
                }
            } else {
                content = nil
            }

            try writer.writeOperation(operation, metadata: metadata, sequenceOrder: sequenceOrder, content: content)
            sequenceOrder += 1
            totalOperations += 1
        }

        // Create and write patch metadata
        let patchMetadata = PatchMetadata(
            version: 1,
            createdDate: Date(),
            sourceChecksum: nil,  // TODO: Calculate checksums in future
            targetChecksum: nil,
            operationCount: totalOperations
        )
        try writer.writeMetadata(patchMetadata)

        return Patch(databaseURL: patchURL, metadata: patchMetadata, database: database)
    }

    /// Open an existing patch from a database file
    /// - Parameter url: Path to the patch database
    /// - Returns: Opened patch
    public static func open(at url: URL) throws -> Patch {
        let database = try SQLiteDatabase(path: url.path)

        // Verify schema
        guard try PatchSchema.verifyVersion(in: database) else {
            throw DiffallaError.invalidPatch(reason: "Incompatible schema version")
        }

        // Load metadata
        let rows = try database.query("SELECT version, created_date, source_checksum, target_checksum, operation_count FROM metadata LIMIT 1")
        guard let row = rows.first else {
            throw DiffallaError.invalidPatch(reason: "Missing metadata")
        }

        let version = try row.int64(at: 0)
        let createdTimestamp = try row.int64(at: 1)
        let sourceChecksum = try row.string(at: 2)
        let targetChecksum = try row.string(at: 3)
        let operationCount = try row.int64(at: 4)

        let metadata = PatchMetadata(
            version: Int(version),
            createdDate: DateFormatting.fromUnixTimestamp(createdTimestamp),
            sourceChecksum: sourceChecksum,
            targetChecksum: targetChecksum,
            operationCount: Int(operationCount)
        )

        return Patch(databaseURL: url, metadata: metadata, database: database)
    }

    /// Load all operations from the patch
    /// - Returns: Array of patch operations in sequence order
    public func loadOperations() throws -> [PatchOperation] {
        let rows = try database.query("SELECT type, path, path_to, is_folder FROM operations ORDER BY sequence_order")

        var operations: [PatchOperation] = []
        for row in rows {
            guard let type = try row.string(at: 0) else {
                throw DiffallaError.invalidPatch(reason: "Missing operation type")
            }
            guard let path = try row.string(at: 1) else {
                throw DiffallaError.invalidPatch(reason: "Missing operation path")
            }
            let pathTo = try row.string(at: 2)
            let isFolder = try row.int64(at: 3) != 0

            let operation: PatchOperation
            switch type {
            case "add":
                operation = .add(path: path, isFolder: isFolder)
            case "remove":
                operation = .remove(path: path, isFolder: isFolder)
            case "modify":
                operation = .modify(path: path, isFolder: isFolder)
            case "move":
                guard let pathTo = pathTo else {
                    throw DiffallaError.invalidPatch(reason: "Move operation missing path_to")
                }
                operation = .move(from: path, to: pathTo, isFolder: isFolder)
            default:
                throw DiffallaError.invalidPatch(reason: "Unknown operation type: \(type)")
            }

            operations.append(operation)
        }

        return operations
    }

    /// Load all operations with metadata and content
    /// - Returns: Array of tuples containing operation, metadata, and optional content
    func loadOperationsWithContent() throws -> [(PatchOperation, Metadata, Data?)] {
        let reader = PatchReader(database: database)
        return try reader.loadOperations()
    }

    /// Load content for a specific path
    /// - Parameter path: The path to load content for
    /// - Returns: File content, or nil if not found or no content stored
    func loadContent(for path: String) throws -> Data? {
        let reader = PatchReader(database: database)
        return try reader.loadContent(for: path)
    }

    /// Convert SnapshotItem to Metadata
    private static func convertToMetadata(_ item: SnapshotItem) -> Metadata {
        return Metadata(
            modificationDate: item.modificationDate,
            size: item.size,
            permissions: item.permissions,
            owner: item.owner,
            group: item.group
        )
    }
}
