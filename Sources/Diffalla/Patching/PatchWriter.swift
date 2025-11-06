import Foundation

/// Internal class for writing patch data to SQLite database
class PatchWriter {
    private let database: SQLiteDatabase

    /// Maximum size for inline content storage (1 MB)
    /// Files larger than this are not stored inline (deferred to Phase 4 external cache)
    private let inlineThreshold: Int64 = 1_048_576  // 1 MB

    init(database: SQLiteDatabase) {
        self.database = database
    }

    /// Write a patch operation to the database
    /// - Parameters:
    ///   - operation: The operation to write
    ///   - metadata: File metadata associated with the operation
    ///   - sequenceOrder: Sequence order for the operation
    ///   - content: Optional file content (for add/modify operations)
    /// - Note: Files larger than 1MB are not stored inline (content will be NULL)
    func writeOperation(_ operation: PatchOperation, metadata: Metadata, sequenceOrder: Int, content: Data? = nil) throws {
        // Serialize metadata to JSON
        let encoder = JSONEncoder()
        let metadataData = try encoder.encode(metadata)
        let metadataJson = String(data: metadataData, encoding: .utf8) ?? "{}"

        // Extract operation fields
        let type = operation.operationType
        let path = operation.path
        let isFolder = operation.isFolder ? 1 : 0

        // Apply inline threshold - only store content if below 1MB
        let contentToStore: Data?
        if let content = content {
            if Int64(content.count) <= inlineThreshold {
                contentToStore = content
            } else {
                // File too large for inline storage - will need external cache (Phase 4)
                contentToStore = nil
            }
        } else {
            contentToStore = nil
        }

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
            // Regular operations (add, remove, modify) - may have content (if below threshold)
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
                    contentToStore.map { .blob($0) } ?? .null,
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
