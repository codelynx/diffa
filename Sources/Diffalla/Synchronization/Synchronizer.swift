import Foundation

/// High-level API for folder synchronization
public class Synchronizer {
    private let engine = SnapshotEngine()

    public init() {}

    /// Sync source to destination (make destination identical to source)
    ///
    /// This performs unidirectional synchronization:
    /// - Files in source but not in destination are copied
    /// - Files in destination but not in source are deleted (if deleteExtraFiles is true)
    /// - Files that differ are updated from source
    ///
    /// - Parameters:
    ///   - source: Source directory URL
    ///   - destination: Destination directory URL
    ///   - options: Synchronization options (dry run, verify, etc.)
    ///   - progress: Optional progress callback
    /// - Returns: SyncResult with statistics and errors
    public func syncUnidirectional(
        source: URL,
        destination: URL,
        options: SyncOptions = SyncOptions(),
        progress: ((SyncProgress) -> Void)? = nil
    ) async throws -> SyncResult {
        // Step 1: Create snapshots of source and destination
        let tempDir = FileManager.default.temporaryDirectory
        let sourceSnapshotURL = tempDir.appendingPathComponent(UUID().uuidString + ".snapshot")
        let destSnapshotURL = tempDir.appendingPathComponent(UUID().uuidString + ".snapshot")

        defer {
            // Clean up temporary snapshots
            try? FileManager.default.removeItem(at: sourceSnapshotURL)
            try? FileManager.default.removeItem(at: destSnapshotURL)
        }

        let scanOptions = ScanOptions()

        let sourceSnapshot = try await engine.createSnapshot(
            from: source,
            saveTo: sourceSnapshotURL,
            options: scanOptions,
            progress: nil
        )

        let destSnapshot = try await engine.createSnapshot(
            from: destination,
            saveTo: destSnapshotURL,
            options: scanOptions,
            progress: nil
        )

        // Step 2: Compare snapshots
        let difference = try Difference.compare(source: sourceSnapshot, destination: destSnapshot)

        // Step 3: Plan sync operations
        let planner = SyncPlanner()
        var operations = try planner.planUnidirectional(
            difference: difference,
            sourceDirectory: source,
            destinationDirectory: destination
        )

        // Apply deleteExtraFiles option
        if !options.deleteExtraFiles {
            // Filter out delete operations
            operations = operations.filter { operation in
                switch operation {
                case .deleteFile, .deleteDirectory:
                    return false
                default:
                    return true
                }
            }
        }

        let totalBytes = planner.calculateTotalBytes(operations: operations)

        // Step 4: Execute operations (or skip if dry run)
        var result: SyncResult

        if options.dryRun {
            // Dry run: Don't actually execute, just return what would happen
            result = SyncResult(
                filesCopied: operations.filter { if case .copyFile = $0 { return true }; return false }.count,
                filesDeleted: operations.filter { if case .deleteFile = $0 { return true }; return false }.count,
                filesMoved: 0,
                bytesTransferred: totalBytes,
                conflicts: [],
                duration: 0,
                errors: []
            )
        } else {
            // Execute operations
            let executor = SyncExecutor()
            result = try await executor.execute(
                operations: operations,
                totalBytes: totalBytes,
                progress: progress
            )
        }

        // Step 5: Optionally verify result
        if options.verifyAfterSync && !options.dryRun {
            try await verifySync(source: source, destination: destination)
        }

        return result
    }

    // MARK: - Private Helpers

    /// Verify that destination matches source after sync
    private func verifySync(source: URL, destination: URL) async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let sourceSnapshotURL = tempDir.appendingPathComponent(UUID().uuidString + ".snapshot")
        let destSnapshotURL = tempDir.appendingPathComponent(UUID().uuidString + ".snapshot")

        defer {
            try? FileManager.default.removeItem(at: sourceSnapshotURL)
            try? FileManager.default.removeItem(at: destSnapshotURL)
        }

        let scanOptions = ScanOptions()

        let sourceSnapshot = try await engine.createSnapshot(
            from: source,
            saveTo: sourceSnapshotURL,
            options: scanOptions,
            progress: nil
        )

        let destSnapshot = try await engine.createSnapshot(
            from: destination,
            saveTo: destSnapshotURL,
            options: scanOptions,
            progress: nil
        )

        let difference = try Difference.compare(source: sourceSnapshot, destination: destSnapshot)

        // Check if there are any differences
        let hasAdded = try !difference.added.isEmpty
        let hasRemoved = try !difference.removed.isEmpty
        let hasModified = try !difference.modified.isEmpty

        if hasAdded || hasRemoved || hasModified {
            throw DiffallaError.comparisonFailed(
                reason: "Verification failed: destination does not match source after sync"
            )
        }
    }
}
