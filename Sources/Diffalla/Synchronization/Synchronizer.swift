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

    // MARK: - Bidirectional Sync

    /// Sync A and B to make them identical (bidirectional sync)
    ///
    /// This performs bidirectional synchronization:
    /// - Files that differ are resolved using the conflict resolution strategy
    /// - After sync, both directories will be identical
    ///
    /// - Parameters:
    ///   - a: First directory URL
    ///   - b: Second directory URL
    ///   - conflictResolution: Strategy for resolving conflicts (default: .newest)
    ///   - options: Synchronization options (dry run, verify, etc.)
    ///   - progress: Optional progress callback
    /// - Returns: SyncResult with statistics, errors, and resolved conflicts
    public func syncBidirectional(
        a: URL,
        b: URL,
        conflictResolution: ConflictResolution = .newest,
        options: SyncOptions = SyncOptions(),
        progress: ((SyncProgress) -> Void)? = nil
    ) async throws -> SyncResult {
        // Step 1: Create snapshots of A and B
        let tempDir = FileManager.default.temporaryDirectory
        let snapshotAURL = tempDir.appendingPathComponent(UUID().uuidString + ".snapshot")
        let snapshotBURL = tempDir.appendingPathComponent(UUID().uuidString + ".snapshot")

        defer {
            // Clean up temporary snapshots
            try? FileManager.default.removeItem(at: snapshotAURL)
            try? FileManager.default.removeItem(at: snapshotBURL)
        }

        let scanOptions = ScanOptions()

        let snapshotA = try await engine.createSnapshot(
            from: a,
            saveTo: snapshotAURL,
            options: scanOptions,
            progress: nil
        )

        let snapshotB = try await engine.createSnapshot(
            from: b,
            saveTo: snapshotBURL,
            options: scanOptions,
            progress: nil
        )

        // Step 2: Compare snapshots (A vs B)
        let difference = try Difference.compare(source: snapshotA, destination: snapshotB)

        // Step 3: Detect conflicts
        let detector = ConflictDetector()
        let conflicts = try detector.detectConflicts(difference: difference)

        // Step 4: Resolve conflicts using strategy
        let resolver = ConflictResolver()
        var resolvedConflicts: [ResolvedConflict] = []
        var errors: [DiffallaError] = []

        for conflict in conflicts {
            do {
                let resolution = try resolver.resolve(
                    conflict: conflict,
                    strategy: conflictResolution,
                    sourceDirectory: a,
                    destinationDirectory: b
                )
                resolvedConflicts.append(resolution)
            } catch let error as DiffallaError {
                errors.append(error)
                // If strategy is .error, stop immediately
                if case .error = conflictResolution {
                    throw error
                }
            } catch {
                let diffallaError = DiffallaError.comparisonFailed(
                    reason: "Failed to resolve conflict at '\(conflict.path)': \(error.localizedDescription)"
                )
                errors.append(diffallaError)
            }
        }

        // Step 5: Plan sync operations based on resolved conflicts
        var operations: [SyncOperation] = []

        for resolution in resolvedConflicts {
            let conflict = resolution.conflict

            // Determine which direction to sync based on resolution direction
            switch resolution.direction {
            case .copyToDestination:
                // Copy from A to B
                if let sourceItem = conflict.sourceItem {
                    let sourcePath = a.appendingPathComponent(sourceItem.path)
                    let destPath = b.appendingPathComponent(sourceItem.path)

                    if sourceItem.isFolder {
                        operations.append(.createDirectory(at: destPath))
                    } else {
                        operations.append(.copyFile(from: sourcePath, to: destPath, size: sourceItem.size))
                    }
                }

            case .copyToSource:
                // Copy from B to A
                if let destItem = conflict.destinationItem {
                    let sourcePath = b.appendingPathComponent(destItem.path)
                    let destPath = a.appendingPathComponent(destItem.path)

                    if destItem.isFolder {
                        operations.append(.createDirectory(at: destPath))
                    } else {
                        operations.append(.copyFile(from: sourcePath, to: destPath, size: destItem.size))
                    }
                }

            case .deleteFromSource:
                // Delete from A
                if let sourceItem = conflict.sourceItem {
                    let sourcePath = a.appendingPathComponent(sourceItem.path)
                    if sourceItem.isFolder {
                        operations.append(.deleteDirectory(at: sourcePath))
                    } else {
                        operations.append(.deleteFile(at: sourcePath))
                    }
                }

            case .deleteFromDestination:
                // Delete from B
                if let destItem = conflict.destinationItem {
                    let destPath = b.appendingPathComponent(destItem.path)
                    if destItem.isFolder {
                        operations.append(.deleteDirectory(at: destPath))
                    } else {
                        operations.append(.deleteFile(at: destPath))
                    }
                }
            }
        }

        let planner = SyncPlanner()
        let totalBytes = planner.calculateTotalBytes(operations: operations)

        // Step 6: Execute operations (or skip if dry run)
        var result: SyncResult

        if options.dryRun {
            // Dry run: Don't actually execute
            result = SyncResult(
                filesCopied: operations.filter { if case .copyFile = $0 { return true }; return false }.count,
                filesDeleted: operations.filter { if case .deleteFile = $0 { return true }; return false }.count,
                filesMoved: 0,
                bytesTransferred: totalBytes,
                conflicts: resolvedConflicts,
                duration: 0,
                errors: errors
            )
        } else {
            // Execute operations
            let executor = SyncExecutor()
            result = try await executor.execute(
                operations: operations,
                totalBytes: totalBytes,
                progress: progress
            )

            // Merge resolved conflicts and any execution errors
            result = SyncResult(
                filesCopied: result.filesCopied,
                filesDeleted: result.filesDeleted,
                filesMoved: result.filesMoved,
                bytesTransferred: result.bytesTransferred,
                conflicts: resolvedConflicts,
                duration: result.duration,
                errors: errors + result.errors
            )
        }

        // Step 7: Optionally verify both folders identical
        if options.verifyAfterSync && !options.dryRun {
            try await verifyBidirectional(a: a, b: b)
        }

        return result
    }

    /// Verify that A and B are identical after bidirectional sync
    private func verifyBidirectional(a: URL, b: URL) async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let snapshotAURL = tempDir.appendingPathComponent(UUID().uuidString + ".snapshot")
        let snapshotBURL = tempDir.appendingPathComponent(UUID().uuidString + ".snapshot")

        defer {
            try? FileManager.default.removeItem(at: snapshotAURL)
            try? FileManager.default.removeItem(at: snapshotBURL)
        }

        let scanOptions = ScanOptions()

        let snapshotA = try await engine.createSnapshot(
            from: a,
            saveTo: snapshotAURL,
            options: scanOptions,
            progress: nil
        )

        let snapshotB = try await engine.createSnapshot(
            from: b,
            saveTo: snapshotBURL,
            options: scanOptions,
            progress: nil
        )

        let difference = try Difference.compare(source: snapshotA, destination: snapshotB)

        // Check if there are any differences
        let hasAdded = try !difference.added.isEmpty
        let hasRemoved = try !difference.removed.isEmpty
        let hasModified = try !difference.modified.isEmpty

        if hasAdded || hasRemoved || hasModified {
            throw DiffallaError.comparisonFailed(
                reason: "Verification failed: A and B are not identical after bidirectional sync"
            )
        }
    }
}
