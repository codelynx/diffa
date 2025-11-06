import Foundation

/// Internal class for capturing revert data during patch creation
class RevertDataWriter {
    private let database: SQLiteDatabase

    /// Maximum size for inline revert data storage (1 MB)
    /// Files larger than this are not stored inline (deferred to Phase 4 external cache)
    private let inlineThreshold: Int64

    init(database: SQLiteDatabase, inlineThreshold: Int64 = 1_048_576) {
        self.database = database
        self.inlineThreshold = inlineThreshold
    }

    /// Capture original file content and metadata for revert
    /// - Parameters:
    ///   - path: Relative path from root
    ///   - directory: Source directory to read from
    ///   - isFolder: True if item is a directory
    /// - Note: Files larger than inlineThreshold (1MB) are skipped until Phase 4
    func captureOriginalFile(path: String, from directory: URL, isFolder: Bool) throws {
        let fileURL = directory.appendingPathComponent(path)

        // Check if file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // File doesn't exist - nothing to capture
            return
        }

        // Check if this is a symlink
        let resourceValues = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        let isSymlink = resourceValues.isSymbolicLink ?? false

        // Read file content and metadata
        let content: Data?
        let metadata: Metadata
        let cacheReference: String?

        if isSymlink {
            // Symlinks: read the symlink itself, not the target
            metadata = try FileSystemItem.readMetadata(at: fileURL, followSymlinks: false)
            content = nil  // Symlinks don't have content

            // Store symlink target path in cache_reference
            cacheReference = try FileSystemItem.readSymlinkTarget(at: fileURL)
        } else if isFolder {
            // Directories don't have content
            content = nil
            metadata = try FileSystemItem.readMetadata(at: fileURL, followSymlinks: true)
            cacheReference = nil
        } else {
            // Regular files: read metadata and content
            metadata = try FileSystemItem.readMetadata(at: fileURL, followSymlinks: true)
            cacheReference = nil

            // Read content if file is below threshold
            let fileSize = metadata.size
            if fileSize <= inlineThreshold {
                do {
                    content = try Data(contentsOf: fileURL)
                } catch {
                    throw DiffallaError.snapshotCreationFailed(
                        reason: "Failed to read file content for revert data '\(path)': \(error.localizedDescription)"
                    )
                }
            } else {
                // File too large for inline storage - skip for now (Phase 4 will add external cache)
                content = nil
            }
        }

        // Serialize metadata to JSON
        let encoder = JSONEncoder()
        let metadataData = try encoder.encode(metadata)
        let metadataJson = String(data: metadataData, encoding: .utf8) ?? "{}"

        // Store in revert_data table
        try database.run(
            """
            INSERT OR REPLACE INTO revert_data (path, original_content_blob, original_metadata_json, cache_reference)
            VALUES (?, ?, ?, ?)
            """,
            [
                .text(path),
                content.map { .blob($0) } ?? .null,
                .text(metadataJson),
                cacheReference.map { .text($0) } ?? .null
            ]
        )
    }

    /// Capture source path for move operations (no content needed)
    /// - Parameters:
    ///   - fromPath: Original path
    ///   - toPath: Destination path
    ///   - directory: Source directory
    ///   - isFolder: True if item is a directory
    func captureMoveOperation(from fromPath: String, to toPath: String, in directory: URL, isFolder: Bool) throws {
        // For move operations, we just need to remember the source path
        // The file still exists at the source, so read its metadata
        let fileURL = directory.appendingPathComponent(fromPath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        // Read metadata without following symlinks (preserve symlink properties)
        let metadata = try FileSystemItem.readMetadata(at: fileURL, followSymlinks: false)

        // Serialize metadata
        let encoder = JSONEncoder()
        let metadataData = try encoder.encode(metadata)
        let metadataJson = String(data: metadataData, encoding: .utf8) ?? "{}"

        // Store the destination path (toPath) as the key, with original path in metadata
        // This allows revert to know where to move it back to
        try database.run(
            """
            INSERT OR REPLACE INTO revert_data (path, original_content_blob, original_metadata_json, cache_reference)
            VALUES (?, NULL, ?, ?)
            """,
            [
                .text(toPath),  // Store destination path as key
                .text(metadataJson),
                .text(fromPath)  // Store original path in cache_reference for move revert
            ]
        )
    }
}
