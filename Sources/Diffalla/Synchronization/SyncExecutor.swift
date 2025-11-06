import Foundation

/// Executes synchronization operations with progress reporting
class SyncExecutor {
    private let fileManager = FileManager.default

    /// Execute sync operations
    ///
    /// - Parameters:
    ///   - operations: Array of operations to execute
    ///   - totalBytes: Total bytes to transfer (for progress calculation)
    ///   - progress: Optional callback for progress updates
    /// - Returns: SyncResult with statistics and errors
    func execute(
        operations: [SyncOperation],
        totalBytes: Int64,
        progress: ((SyncProgress) -> Void)?
    ) async throws -> SyncResult {
        let startTime = Date()

        var filesCopied = 0
        var filesDeleted = 0
        let filesMoved = 0  // Not used in Step 3 (reserved for future move detection)
        var bytesTransferred: Int64 = 0
        var errors: [DiffallaError] = []

        var filesProcessed = 0
        let totalFiles = operations.count

        for operation in operations {
            var currentProgress = SyncProgress(
                currentOperation: operationDescription(operation),
                filesProcessed: filesProcessed,
                totalFiles: totalFiles,
                bytesTransferred: bytesTransferred,
                totalBytes: totalBytes,
                operationType: operationType(operation)
            )

            do {
                switch operation {
                case .copyFile(let from, let to, let size):
                    try executeCopyFile(from: from, to: to, size: size)
                    filesCopied += 1
                    bytesTransferred += size

                case .deleteFile(let at):
                    try executeDeleteFile(at: at)
                    filesDeleted += 1

                case .createDirectory(let at):
                    try executeCreateDirectory(at: at)
                    // Don't count directories in file statistics

                case .deleteDirectory(let at):
                    try executeDeleteDirectory(at: at)
                    // Don't count directories in file statistics
                }

                filesProcessed += 1

                // Update progress after successful operation
                currentProgress = SyncProgress(
                    currentOperation: operationDescription(operation),
                    filesProcessed: filesProcessed,
                    totalFiles: totalFiles,
                    bytesTransferred: bytesTransferred,
                    totalBytes: totalBytes,
                    operationType: operationType(operation)
                )

                progress?(currentProgress)

            } catch let error as DiffallaError {
                // Collect errors but continue execution
                errors.append(error)
                filesProcessed += 1

            } catch {
                // Wrap unknown errors
                let diffallaError = DiffallaError.applyFailed(
                    operation: operationDescription(operation),
                    reason: error.localizedDescription
                )
                errors.append(diffallaError)
                filesProcessed += 1
            }
        }

        let duration = Date().timeIntervalSince(startTime)

        return SyncResult(
            filesCopied: filesCopied,
            filesDeleted: filesDeleted,
            filesMoved: filesMoved,
            bytesTransferred: bytesTransferred,
            conflicts: [], // No conflicts in Step 3 (added in Step 6)
            duration: duration,
            errors: errors
        )
    }

    // MARK: - Private Operation Executors

    private func executeCopyFile(from source: URL, to destination: URL, size: Int64) throws {
        // Ensure parent directory exists
        let parentDir = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        // Remove existing file if present
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        // Copy file
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw DiffallaError.applyFailed(
                operation: "copy \(source.path) to \(destination.path)",
                reason: error.localizedDescription
            )
        }
    }

    private func executeDeleteFile(at path: URL) throws {
        guard fileManager.fileExists(atPath: path.path) else {
            // Already deleted - not an error
            return
        }

        do {
            try fileManager.removeItem(at: path)
        } catch {
            throw DiffallaError.applyFailed(
                operation: "delete \(path.path)",
                reason: error.localizedDescription
            )
        }
    }

    private func executeCreateDirectory(at path: URL) throws {
        // Skip if already exists
        if fileManager.fileExists(atPath: path.path) {
            return
        }

        do {
            try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        } catch {
            throw DiffallaError.applyFailed(
                operation: "create directory \(path.path)",
                reason: error.localizedDescription
            )
        }
    }

    private func executeDeleteDirectory(at path: URL) throws {
        guard fileManager.fileExists(atPath: path.path) else {
            // Already deleted - not an error
            return
        }

        do {
            try fileManager.removeItem(at: path)
        } catch {
            throw DiffallaError.applyFailed(
                operation: "delete directory \(path.path)",
                reason: error.localizedDescription
            )
        }
    }

    // MARK: - Helpers

    private func operationDescription(_ operation: SyncOperation) -> String {
        switch operation {
        case .copyFile(let from, let to, _):
            return "Copying \(from.lastPathComponent) to \(to.path)"
        case .deleteFile(let at):
            return "Deleting \(at.lastPathComponent)"
        case .createDirectory(let at):
            return "Creating directory \(at.lastPathComponent)"
        case .deleteDirectory(let at):
            return "Deleting directory \(at.lastPathComponent)"
        }
    }

    private func operationType(_ operation: SyncOperation) -> OperationType {
        switch operation {
        case .copyFile:
            return .copying
        case .deleteFile, .deleteDirectory:
            return .deleting
        case .createDirectory:
            return .copying // Treat directory creation as part of copy workflow
        }
    }
}
