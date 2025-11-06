import Foundation

/// Plans synchronization operations from a Difference
class SyncPlanner {

    /// Plan unidirectional sync operations (source → destination)
    ///
    /// This makes destination identical to source by:
    /// - Copying items that exist only in source
    /// - Deleting items that exist only in destination
    /// - Updating items that are modified
    ///
    /// - Parameters:
    ///   - difference: The comparison result between source and destination
    ///   - sourceDirectory: Base directory for source files
    ///   - destinationDirectory: Base directory for destination files
    /// - Returns: Array of operations to execute in order
    func planUnidirectional(
        difference: Difference,
        sourceDirectory: URL,
        destinationDirectory: URL
    ) throws -> [SyncOperation] {
        var operations: [SyncOperation] = []

        // Note: Difference.removed = items in SOURCE not in DESTINATION
        // For unidirectional sync, these need to be COPIED to destination
        let toAdd = try difference.removed
        for item in toAdd {
            let sourcePath = sourceDirectory.appendingPathComponent(item.path)
            let destPath = destinationDirectory.appendingPathComponent(item.path)

            if item.isFolder {
                operations.append(.createDirectory(at: destPath))
            } else {
                operations.append(.copyFile(from: sourcePath, to: destPath, size: item.size))
            }
        }

        // Note: Difference.added = items in DESTINATION not in SOURCE
        // For unidirectional sync, these need to be DELETED from destination
        let toRemove = try difference.added
        // Delete in reverse order to handle nested items (delete children before parents)
        for item in toRemove.reversed() {
            let destPath = destinationDirectory.appendingPathComponent(item.path)

            if item.isFolder {
                operations.append(.deleteDirectory(at: destPath))
            } else {
                operations.append(.deleteFile(at: destPath))
            }
        }

        // Modified items need to be updated (copy from source to destination)
        let toUpdate = try difference.modified
        for item in toUpdate {
            let sourcePath = sourceDirectory.appendingPathComponent(item.path)
            let destPath = destinationDirectory.appendingPathComponent(item.path)

            if item.isFolder {
                // Folder metadata changed (permissions, etc.) - no action needed for now
                // Future: could update folder metadata
            } else {
                operations.append(.copyFile(from: sourcePath, to: destPath, size: item.size))
            }
        }

        return operations
    }

    /// Calculate total bytes for progress tracking
    ///
    /// Sums up all bytes that will be transferred during sync.
    /// Only counts copyFile operations (deletes/creates don't transfer data).
    ///
    /// - Parameter operations: Array of sync operations
    /// - Returns: Total bytes to be transferred
    func calculateTotalBytes(operations: [SyncOperation]) -> Int64 {
        var totalBytes: Int64 = 0

        for operation in operations {
            if case .copyFile(_, _, let size) = operation {
                totalBytes += size
            }
        }

        return totalBytes
    }
}
