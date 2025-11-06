import Foundation

/// Internal class for writing patch data to SQLite database
class PatchWriter {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    /// Write a patch operation to the database
    /// - Parameters:
    ///   - operation: The operation to write
    ///   - metadata: File metadata associated with the operation
    ///   - sequenceOrder: Sequence order for the operation
    ///   - content: Optional file content (for add/modify operations)
    func writeOperation(_ operation: PatchOperation, metadata: Metadata, sequenceOrder: Int, content: Data? = nil) throws {
        // Serialize metadata to JSON
        let encoder = JSONEncoder()
        let metadataData = try encoder.encode(metadata)
        let metadataJson = String(data: metadataData, encoding: .utf8) ?? "{}"

        // Extract operation fields
        let type = operation.operationType
        let path = operation.path
        let isFolder = operation.isFolder ? 1 : 0

        // Handle move operation (has path_to, no content)
        if case .move(let from, let to, _) = operation {
            try database.run(
                """
                INSERT INTO operations (sequence_order, type, path, path_to, is_folder, content_blob, metadata_json)
                VALUES (?, ?, ?, ?, ?, NULL, ?)
                """,
                [
                    .integer(Int64(sequenceOrder)),
                    .text(type),
                    .text(from),
                    .text(to),
                    .integer(Int64(isFolder)),
                    .text(metadataJson)
                ]
            )
        } else {
            // Regular operations (add, remove, modify) - may have content
            try database.run(
                """
                INSERT INTO operations (sequence_order, type, path, path_to, is_folder, content_blob, metadata_json)
                VALUES (?, ?, ?, NULL, ?, ?, ?)
                """,
                [
                    .integer(Int64(sequenceOrder)),
                    .text(type),
                    .text(path),
                    .integer(Int64(isFolder)),
                    content.map { .blob($0) } ?? .null,
                    .text(metadataJson)
                ]
            )
        }
    }

    /// Write patch metadata to the database
    /// - Parameter metadata: The patch metadata to write
    func writeMetadata(_ metadata: PatchMetadata) throws {
        try database.run(
            """
            INSERT INTO metadata (id, version, created_date, source_checksum, target_checksum, operation_count)
            VALUES (1, ?, ?, ?, ?, ?)
            """,
            [
                .integer(Int64(metadata.version)),
                .integer(DateFormatting.toUnixTimestamp(metadata.createdDate)),
                metadata.sourceChecksum.map { .text($0) } ?? .null,
                metadata.targetChecksum.map { .text($0) } ?? .null,
                .integer(Int64(metadata.operationCount))
            ]
        )
    }
}
