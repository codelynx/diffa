import Foundation

/// Pre-sync validation and safety checks
class SyncValidator {
    private let fileManager = FileManager.default

    /// Validate sync is safe to perform
    ///
    /// Checks:
    /// - Source directory exists and is readable
    /// - Destination directory exists and is writable
    /// - Sufficient disk space for operations
    ///
    /// - Parameters:
    ///   - source: Source directory URL
    ///   - destination: Destination directory URL
    ///   - operations: Planned sync operations
    /// - Throws: DiffaError if validation fails
    func validateSync(
        source: URL,
        destination: URL,
        operations: [SyncOperation]
    ) throws {
        // Check source exists
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DiffaError.fileNotFound(path: source.path)
        }

        // Check source is readable
        guard fileManager.isReadableFile(atPath: source.path) else {
            throw DiffaError.permissionDenied(path: source.path)
        }

        // Check destination exists
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DiffaError.fileNotFound(path: destination.path)
        }

        // Check destination is writable
        guard fileManager.isWritableFile(atPath: destination.path) else {
            throw DiffaError.permissionDenied(path: destination.path)
        }

        // Check disk space
        let requiredSpace = estimateSpaceRequired(operations: operations)
        if requiredSpace > 0 {
            let hasSpace = try hasEnoughSpace(at: destination, requiredBytes: requiredSpace)
            if !hasSpace {
                // Get available space for error message
                if let attrs = try? fileManager.attributesOfFileSystem(forPath: destination.path),
                   let freeSpace = attrs[.systemFreeSize] as? Int64 {
                    throw DiffaError.insufficientSpace(required: requiredSpace, available: freeSpace)
                } else {
                    throw DiffaError.insufficientSpace(required: requiredSpace, available: 0)
                }
            }
        }
    }

    /// Estimate disk space required for operations
    ///
    /// Calculates the net disk space change:
    /// - Copy operations: Add file size
    /// - Move operations: Add file size (for cross-filesystem fallback safety)
    /// - Delete operations: Subtract file size (frees space)
    ///
    /// - Parameter operations: Planned sync operations
    /// - Returns: Net bytes required (can be negative if deleting more than copying)
    func estimateSpaceRequired(operations: [SyncOperation]) -> Int64 {
        var totalBytes: Int64 = 0

        for operation in operations {
            switch operation {
            case .copyFile(_, _, let size):
                // Copying requires space
                totalBytes += size

            case .moveFile(_, _, let size):
                // Move on same filesystem is atomic (no extra space)
                // But cross-filesystem move does copy+delete (needs temporary space)
                // For conservative estimation, treat as requiring space
                totalBytes += size

            case .deleteFile, .deleteDirectory:
                // Deleting frees space (we don't track how much is freed)
                // For conservative estimation, assume deletion frees no space
                break

            case .createDirectory:
                // Directory creation uses negligible space
                break
            }
        }

        return totalBytes
    }

    /// Check if destination has enough space for the required bytes
    ///
    /// - Parameters:
    ///   - url: Directory to check
    ///   - requiredBytes: Bytes required
    /// - Returns: true if sufficient space available
    /// - Throws: DiffaError if cannot determine available space
    func hasEnoughSpace(at url: URL, requiredBytes: Int64) throws -> Bool {
        do {
            let attrs = try fileManager.attributesOfFileSystem(forPath: url.path)
            guard let freeSpace = attrs[.systemFreeSize] as? Int64 else {
                throw DiffaError.comparisonFailed(reason: "Cannot determine free space at \(url.path)")
            }

            // Add 10% buffer for safety
            let requiredWithBuffer = Int64(Double(requiredBytes) * 1.1)
            return freeSpace >= requiredWithBuffer
        } catch let error as DiffaError {
            throw error
        } catch {
            throw DiffaError.comparisonFailed(
                reason: "Failed to check disk space at \(url.path): \(error.localizedDescription)"
            )
        }
    }
}
