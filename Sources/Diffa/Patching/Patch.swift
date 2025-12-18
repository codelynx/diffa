import Foundation

/// Progress information emitted while applying or reverting a patch
public struct PatchProgress: Sendable {
    public let current: Int
    public let total: Int
    public let operation: PatchOperation
    public let isRevert: Bool
}

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

        // Create revert data writer if needed
        let revertWriter: RevertDataWriter? = includeRevertData ? RevertDataWriter(database: database) : nil

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
                    throw DiffaError.snapshotCreationFailed(
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

            // Capture revert data if requested (original file before removal)
            if let revertWriter = revertWriter {
                try revertWriter.captureOriginalFile(path: item.path, from: sourceDirectory, isFolder: item.isFolder)
            }

            try writer.writeOperation(operation, metadata: metadata, sequenceOrder: sequenceOrder, content: nil)
            sequenceOrder += 1
            totalOperations += 1
        }

        // Process modified items (read new content from destination)
        let modified = try difference.modified
        for item in modified {
            let operation = PatchOperation.modify(path: item.path, isFolder: item.isFolder)
            let metadata = convertToMetadata(item)

            // Capture revert data if requested (original file before modification)
            if let revertWriter = revertWriter {
                try revertWriter.captureOriginalFile(path: item.path, from: sourceDirectory, isFolder: item.isFolder)
            }

            // Read content for files (not folders)
            let content: Data?
            if !item.isFolder {
                let fileURL = destinationDirectory.appendingPathComponent(item.path)
                do {
                    content = try Data(contentsOf: fileURL)
                } catch {
                    throw DiffaError.snapshotCreationFailed(
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
            throw DiffaError.invalidPatch(reason: "Incompatible schema version")
        }

        // Load metadata
        let rows = try database.query("SELECT version, created_date, source_checksum, target_checksum, operation_count FROM metadata LIMIT 1")
        guard let row = rows.first else {
            throw DiffaError.invalidPatch(reason: "Missing metadata")
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
                throw DiffaError.invalidPatch(reason: "Missing operation type")
            }
            guard let path = try row.string(at: 1) else {
                throw DiffaError.invalidPatch(reason: "Missing operation path")
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
                    throw DiffaError.invalidPatch(reason: "Move operation missing path_to")
                }
                operation = .move(from: path, to: pathTo, isFolder: isFolder)
            default:
                throw DiffaError.invalidPatch(reason: "Unknown operation type: \(type)")
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

    /// Apply this patch to a target directory
    /// - Parameters:
    ///   - targetDirectory: Directory to apply the patch to
    ///   - progress: Optional callback invoked before each operation executes
    public func apply(
        to targetDirectory: URL,
        progress: (@Sendable (PatchProgress) -> Void)? = nil
    ) async throws {
        let applicator = PatchApplicator()

        // Load all operations with content and metadata
        let operations = try loadOperationsWithContent()

        // Apply operations in sequence order
        for (index, (operation, metadata, content)) in operations.enumerated() {
            progress?(PatchProgress(
                current: index + 1,
                total: operations.count,
                operation: operation,
                isRevert: false
            ))

            switch operation {
            case .add(let path, let isFolder):
                try applicator.applyAdd(path: path, isFolder: isFolder, content: content, metadata: metadata, to: targetDirectory)

            case .remove(let path, _):
                try applicator.applyRemove(path: path, from: targetDirectory)

            case .modify(let path, let isFolder):
                try applicator.applyModify(path: path, isFolder: isFolder, content: content, metadata: metadata, to: targetDirectory)

            case .move(let from, let to, _):
                try applicator.applyMove(from: from, to: to, in: targetDirectory)
            }
        }
    }

    /// Revert this patch to restore the original directory state
    /// - Parameters:
    ///   - targetDirectory: Directory to revert the patch in
    ///   - progress: Optional callback invoked before each operation executes
    /// - Throws: Error if patch doesn't have required revert data or revert fails
    /// - Note: Add operations don't require revert data (just delete the file), but remove/modify operations do
    public func revert(
        on targetDirectory: URL,
        progress: (@Sendable (PatchProgress) -> Void)? = nil
    ) async throws {
        let reverter = PatchReverter()

        // Load all operations
        let operations = try loadOperations()
        let total = operations.count

        // Execute operations in REVERSE order to undo changes
        for (index, operation) in operations.reversed().enumerated() {
            progress?(PatchProgress(
                current: index + 1,
                total: total,
                operation: operation,
                isRevert: true
            ))

            switch operation {
            case .add(let path, _):
                // Revert add: delete the added file/folder (no revert data needed)
                try reverter.revertAdd(path: path, from: targetDirectory)

            case .remove(let path, _):
                // Revert remove: restore the original file/folder from revert_data
                guard let revertData = try loadRevertData(for: path) else {
                    throw DiffaError.invalidPatch(
                        reason: "Cannot revert remove operation for '\(path)': revert data missing"
                    )
                }
                try reverter.revertRemove(
                    path: path,
                    content: revertData.content,
                    metadata: revertData.metadata,
                    cacheReference: revertData.cacheReference,
                    to: targetDirectory
                )

            case .modify(let path, _):
                // Revert modify: restore the original file content/metadata from revert_data
                guard let revertData = try loadRevertData(for: path) else {
                    throw DiffaError.invalidPatch(
                        reason: "Cannot revert modify operation for '\(path)': revert data missing"
                    )
                }
                try reverter.revertModify(
                    path: path,
                    originalContent: revertData.content,
                    metadata: revertData.metadata,
                    to: targetDirectory
                )

            case .move(_, let to, _):
                // Revert move: move back from 'to' to original source (stored in revert_data)
                // Load revert data to get the original source path (stored in cache_reference)
                guard let revertData = try loadRevertData(for: to) else {
                    throw DiffaError.invalidPatch(
                        reason: "Cannot revert move operation for '\(to)': revert data missing"
                    )
                }
                // cache_reference contains the original source path
                guard let originalPath = revertData.cacheReference else {
                    throw DiffaError.invalidPatch(
                        reason: "Cannot revert move operation for '\(to)': missing original path"
                    )
                }
                try reverter.revertMove(from: to, to: originalPath, in: targetDirectory)
            }
        }
    }

    /// Load revert data for a specific path
    /// - Parameter path: The path to load revert data for
    /// - Returns: Tuple of (content, metadata, cacheReference), or nil if not found
    func loadRevertData(for path: String) throws -> (content: Data?, metadata: Metadata, cacheReference: String?)? {
        let rows = try database.query(
            "SELECT original_content_blob, original_metadata_json, cache_reference FROM revert_data WHERE path = ? LIMIT 1",
            [.text(path)]
        )

        guard let row = rows.first else {
            return nil
        }

        let content = try row.data(at: 0)
        guard let metadataJson = try row.string(at: 1) else {
            throw DiffaError.invalidPatch(reason: "Missing metadata for revert data '\(path)'")
        }
        let cacheReference = try row.string(at: 2)

        // Deserialize metadata
        let decoder = JSONDecoder()
        guard let metadataData = metadataJson.data(using: .utf8) else {
            throw DiffaError.invalidPatch(reason: "Invalid metadata JSON for revert data '\(path)'")
        }
        let metadata = try decoder.decode(Metadata.self, from: metadataData)

        return (content: content, metadata: metadata, cacheReference: cacheReference)
    }

    /// Check if patch has revert data
    /// - Returns: True if patch contains revert data
    public func hasRevertData() throws -> Bool {
        let rows = try database.query("SELECT COUNT(*) FROM revert_data")
        guard let row = rows.first else {
            return false
        }
        let count = try row.int64(at: 0)
        return count > 0
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

// MARK: - Export Functions

extension Patch {
    /// Export patch as simple text format (diff-style)
    /// - Returns: Text representation with operation symbols (+ add, - remove, M modify, R move)
    public func exportAsText() throws -> String {
        let operations = try loadOperations()
        var lines: [String] = []

        // Header
        lines.append("Patch: \(databaseURL.lastPathComponent)")
        lines.append("Created: \(metadata.createdDate)")
        lines.append("Operations: \(metadata.operationCount)")
        lines.append("")

        // Operations
        for operation in operations {
            switch operation {
            case .add(let path, let isFolder):
                let marker = isFolder ? "+ (dir)" : "+"
                lines.append("\(marker) \(path)")
            case .remove(let path, let isFolder):
                let marker = isFolder ? "- (dir)" : "-"
                lines.append("\(marker) \(path)")
            case .modify(let path, let isFolder):
                let marker = isFolder ? "M (dir)" : "M"
                lines.append("\(marker) \(path)")
            case .move(let from, let to, let isFolder):
                let marker = isFolder ? "R (dir)" : "R"
                lines.append("\(marker) \(from) -> \(to)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Export patch as JSON format
    /// - Returns: JSON string with patch metadata and operations
    public func exportAsJSON() throws -> String {
        let operations = try loadOperations()

        // Build JSON structure manually for control over format
        var json = "{\n"
        json += "  \"version\": \(metadata.version),\n"

        // Format date as ISO 8601
        let formatter = ISO8601DateFormatter()
        let dateString = formatter.string(from: metadata.createdDate)
        json += "  \"created\": \"\(dateString)\",\n"

        if let sourceChecksum = metadata.sourceChecksum {
            json += "  \"sourceChecksum\": \"\(sourceChecksum)\",\n"
        }

        if let targetChecksum = metadata.targetChecksum {
            json += "  \"targetChecksum\": \"\(targetChecksum)\",\n"
        }

        json += "  \"operationCount\": \(metadata.operationCount),\n"
        json += "  \"operations\": [\n"

        for (index, operation) in operations.enumerated() {
            let isLast = index == operations.count - 1

            json += "    {"
            switch operation {
            case .add(let path, let isFolder):
                json += "\"type\": \"add\", \"path\": \"\(escapeJSON(path))\", \"isFolder\": \(isFolder)"
            case .remove(let path, let isFolder):
                json += "\"type\": \"remove\", \"path\": \"\(escapeJSON(path))\", \"isFolder\": \(isFolder)"
            case .modify(let path, let isFolder):
                json += "\"type\": \"modify\", \"path\": \"\(escapeJSON(path))\", \"isFolder\": \(isFolder)"
            case .move(let from, let to, let isFolder):
                json += "\"type\": \"move\", \"from\": \"\(escapeJSON(from))\", \"to\": \"\(escapeJSON(to))\", \"isFolder\": \(isFolder)"
            }
            json += "}"
            json += isLast ? "\n" : ",\n"
        }

        json += "  ]\n"
        json += "}"

        return json
    }

    /// Export patch as HTML format
    /// - Returns: HTML string with styled patch display
    public func exportAsHTML() throws -> String {
        let operations = try loadOperations()

        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <title>Patch: \(escapeHTML(databaseURL.lastPathComponent))</title>
            <style>
                body { font-family: 'Courier New', monospace; background: #1e1e1e; color: #d4d4d4; padding: 20px; }
                .header { margin-bottom: 20px; }
                .header h1 { color: #569cd6; }
                .header .meta { color: #808080; }
                .operation { margin: 5px 0; padding: 5px; border-radius: 3px; }
                .add { background: #1e3a1e; color: #4ec9b0; }
                .remove { background: #3a1e1e; color: #f48771; }
                .modify { background: #3a3a1e; color: #dcdcaa; }
                .move { background: #1e2a3a; color: #9cdcfe; }
                .symbol { font-weight: bold; margin-right: 10px; }
                .path { color: #ce9178; }
                .folder { font-style: italic; }
            </style>
        </head>
        <body>
            <div class="header">
                <h1>Patch: \(escapeHTML(databaseURL.lastPathComponent))</h1>
                <div class="meta">Created: \(metadata.createdDate)</div>
                <div class="meta">Operations: \(metadata.operationCount)</div>
            </div>
            <div class="operations">

        """

        for operation in operations {
            switch operation {
            case .add(let path, let isFolder):
                let folderClass = isFolder ? " folder" : ""
                html += "        <div class=\"operation add\"><span class=\"symbol\">+</span><span class=\"path\(folderClass)\">\(escapeHTML(path))</span>\(isFolder ? " <span class=\"folder\">(directory)</span>" : "")</div>\n"
            case .remove(let path, let isFolder):
                let folderClass = isFolder ? " folder" : ""
                html += "        <div class=\"operation remove\"><span class=\"symbol\">-</span><span class=\"path\(folderClass)\">\(escapeHTML(path))</span>\(isFolder ? " <span class=\"folder\">(directory)</span>" : "")</div>\n"
            case .modify(let path, let isFolder):
                let folderClass = isFolder ? " folder" : ""
                html += "        <div class=\"operation modify\"><span class=\"symbol\">M</span><span class=\"path\(folderClass)\">\(escapeHTML(path))</span>\(isFolder ? " <span class=\"folder\">(directory)</span>" : "")</div>\n"
            case .move(let from, let to, let isFolder):
                let folderClass = isFolder ? " folder" : ""
                html += "        <div class=\"operation move\"><span class=\"symbol\">R</span><span class=\"path\(folderClass)\">\(escapeHTML(from)) → \(escapeHTML(to))</span>\(isFolder ? " <span class=\"folder\">(directory)</span>" : "")</div>\n"
            }
        }

        html += """
            </div>
        </body>
        </html>
        """

        return html
    }

    /// Export patch as detailed diff format (requires revert data)
    /// - Returns: Git-style diff with before/after content
    /// - Throws: Error if patch doesn't have revert data
    public func exportAsDetailedDiff() throws -> String {
        // Check if patch has revert data
        guard try hasRevertData() else {
            throw DiffaError.invalidPatch(
                reason: "Cannot export detailed diff: patch does not contain revert data. Patch must be created with includeRevertData: true"
            )
        }

        let operations = try loadOperationsWithContent()
        var lines: [String] = []

        // Header
        lines.append("diff --diffa \(databaseURL.lastPathComponent)")
        lines.append("Created: \(metadata.createdDate)")
        lines.append("Operations: \(metadata.operationCount)")
        lines.append("")

        // Process operations
        for (operation, newMetadata, newContent) in operations {
            switch operation {
            case .add(let path, let isFolder):
                lines.append("diff --diffa a/\(path) b/\(path)")
                lines.append("new file \(isFolder ? "directory" : "mode \(String(format: "%o", newMetadata.permissions.posix))")")
                if !isFolder, let content = newContent, let text = String(data: content, encoding: .utf8) {
                    lines.append("--- /dev/null")
                    lines.append("+++ b/\(path)")
                    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                        lines.append("+\(line)")
                    }
                }
                lines.append("")

            case .remove(let path, let isFolder):
                lines.append("diff --diffa a/\(path) b/\(path)")

                // Get original content from revert data
                if let revertData = try loadRevertData(for: path) {
                    lines.append("deleted file \(isFolder ? "directory" : "mode \(String(format: "%o", revertData.metadata.permissions.posix))")")

                    if !isFolder, let content = revertData.content, let text = String(data: content, encoding: .utf8) {
                        lines.append("--- a/\(path)")
                        lines.append("+++ /dev/null")
                        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                            lines.append("-\(line)")
                        }
                    }
                }
                lines.append("")

            case .modify(let path, let isFolder):
                lines.append("diff --diffa a/\(path) b/\(path)")

                // Get original content from revert data
                if let revertData = try loadRevertData(for: path) {
                    if !isFolder {
                        lines.append("--- a/\(path)")
                        lines.append("+++ b/\(path)")

                        // Show original content
                        if let originalContent = revertData.content, let originalText = String(data: originalContent, encoding: .utf8) {
                            for line in originalText.split(separator: "\n", omittingEmptySubsequences: false) {
                                lines.append("-\(line)")
                            }
                        }

                        // Show new content
                        if let content = newContent, let text = String(data: content, encoding: .utf8) {
                            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                                lines.append("+\(line)")
                            }
                        }
                    } else {
                        lines.append("metadata change (directory)")
                    }
                }
                lines.append("")

            case .move(let from, let to, _):
                lines.append("diff --diffa a/\(from) b/\(to)")
                lines.append("rename from \(from)")
                lines.append("rename to \(to)")
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helper Functions

    /// Escape string for JSON
    private func escapeJSON(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Escape string for HTML
    private func escapeHTML(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
