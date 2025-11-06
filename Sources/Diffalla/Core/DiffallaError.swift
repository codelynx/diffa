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

    /// Database operation failed
    case databaseError(reason: String, underlying: Error?)

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
        case .databaseError(let reason, let error):
            if let error = error {
                return "Database error: \(reason) (\(error.localizedDescription))"
            } else {
                return "Database error: \(reason)"
            }
        }
    }
}
