import Foundation

/// Internal class for reading patch data from SQLite database
class PatchReader {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    /// Load all operations with metadata and content
    /// - Returns: Array of tuples containing operation, metadata, and optional content
    func loadOperations() throws -> [(PatchOperation, Metadata, Data?)] {
        let rows = try database.query(
            "SELECT type, path, path_to, is_folder, content_blob, metadata_json FROM operations ORDER BY sequence_order"
        )

        var results: [(PatchOperation, Metadata, Data?)] = []
        for row in rows {
            guard let type = try row.string(at: 0) else {
                throw DiffaError.invalidPatch(reason: "Missing operation type")
            }
            guard let path = try row.string(at: 1) else {
                throw DiffaError.invalidPatch(reason: "Missing operation path")
            }
            let pathTo = try row.string(at: 2)
            let isFolder = try row.int64(at: 3) != 0
            let content = try row.data(at: 4)
            guard let metadataJson = try row.string(at: 5) else {
                throw DiffaError.invalidPatch(reason: "Missing metadata")
            }

            // Parse operation
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
                    throw DiffaError.invalidPatch(reason: "Move operation missing path_to")
                }
                operation = .move(from: path, to: pathTo, isFolder: isFolder)
            default:
                throw DiffaError.invalidPatch(reason: "Unknown operation type: \(type)")
            }

            // Parse metadata
            let decoder = JSONDecoder()
            guard let metadataData = metadataJson.data(using: .utf8) else {
                throw DiffaError.invalidPatch(reason: "Invalid metadata JSON encoding")
            }
            let metadata = try decoder.decode(Metadata.self, from: metadataData)

            results.append((operation, metadata, content))
        }

        return results
    }

    /// Load content for a specific path
    /// - Parameter path: The path to load content for
    /// - Returns: File content, or nil if not found or no content stored
    func loadContent(for path: String) throws -> Data? {
        let rows = try database.query(
            "SELECT content_blob FROM operations WHERE path = ? LIMIT 1",
            [.text(path)]
        )

        guard let row = rows.first else {
            return nil
        }

        return try row.data(at: 0)
    }
}
