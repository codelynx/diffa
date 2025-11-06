import Foundation

/// High-level errors for Diffalla operations
public enum DiffallaError: Error, CustomStringConvertible {
    /// File or directory not found at the specified path
    case fileNotFound(path: String)

    /// Permission denied when accessing file or directory
    case permissionDenied(path: String)

    /// Failed to compute SHA-256 hash for a file
    case hashComputationFailed(path: String, underlying: Error)

    /// Snapshot creation failed
    case snapshotCreationFailed(reason: String)

    /// Failed to load snapshot from database
    case snapshotLoadFailed(reason: String)

    /// Snapshot comparison failed
    case comparisonFailed(reason: String)

    /// Invalid or corrupt snapshot file
    case invalidSnapshot(reason: String)

    /// Invalid or corrupt patch file
    case invalidPatch(reason: String)

    /// Patch apply operation failed
    case applyFailed(operation: String, reason: String)

    /// Patch revert operation failed
    case revertFailed(operation: String, reason: String)

    /// Missing revert data for patch operation
    case missingRevertData(path: String)

    /// Target directory is not empty (conflict detection)
    case targetNotEmpty(path: String)

    /// Checksum verification failed
    case checksumMismatch(expected: String, actual: String)

    /// Database operation failed
    case databaseError(reason: String, underlying: Error?)

    /// Insufficient disk space for operation
    case insufficientSpace(required: Int64, available: Int64)

    /// Synchronization operation failed
    case syncFailed(reason: String)

    /// Conflicts detected during bidirectional sync
    case conflictDetected(conflicts: [Conflict])

    /// Synchronization was cancelled
    case syncCancelled

    public var description: String {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        case .hashComputationFailed(let path, let error):
            return "Failed to compute hash for \(path): \(error.localizedDescription)"
        case .snapshotCreationFailed(let reason):
            return "Snapshot creation failed: \(reason)"
        case .snapshotLoadFailed(let reason):
            return "Failed to load snapshot: \(reason)"
        case .comparisonFailed(let reason):
            return "Snapshot comparison failed: \(reason)"
        case .invalidSnapshot(let reason):
            return "Invalid snapshot: \(reason)"
        case .invalidPatch(let reason):
            return "Invalid patch: \(reason)"
        case .applyFailed(let operation, let reason):
            return "Patch apply failed for \(operation): \(reason)"
        case .revertFailed(let operation, let reason):
            return "Patch revert failed for \(operation): \(reason)"
        case .missingRevertData(let path):
            return "Missing revert data for: \(path)"
        case .targetNotEmpty(let path):
            return "Target directory is not empty: \(path)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch: expected \(expected), got \(actual)"
        case .databaseError(let reason, let error):
            if let error = error {
                return "Database error: \(reason) (\(error.localizedDescription))"
            } else {
                return "Database error: \(reason)"
            }
        case .insufficientSpace(let required, let available):
            let requiredMB = Double(required) / 1_048_576
            let availableMB = Double(available) / 1_048_576
            return String(format: "Insufficient disk space: %.2f MB required, %.2f MB available", requiredMB, availableMB)
        case .syncFailed(let reason):
            return "Synchronization failed: \(reason)"
        case .conflictDetected(let conflicts):
            return "Conflicts detected during sync: \(conflicts.count) conflict(s)"
        case .syncCancelled:
            return "Synchronization was cancelled"
        }
    }
}
