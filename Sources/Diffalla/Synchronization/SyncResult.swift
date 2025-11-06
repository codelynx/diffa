import Foundation

/// Result of a synchronization operation
public struct SyncResult {
    /// Number of files copied
    public let filesCopied: Int

    /// Number of files deleted
    public let filesDeleted: Int

    /// Number of files moved
    public let filesMoved: Int

    /// Total bytes transferred
    public let bytesTransferred: Int64

    /// Conflicts that were resolved during sync
    public let conflicts: [ResolvedConflict]

    /// Duration of the sync operation
    public let duration: TimeInterval

    /// Errors encountered during sync (non-fatal)
    public let errors: [DiffallaError]

    public init(
        filesCopied: Int,
        filesDeleted: Int,
        filesMoved: Int,
        bytesTransferred: Int64,
        conflicts: [ResolvedConflict],
        duration: TimeInterval,
        errors: [DiffallaError]
    ) {
        self.filesCopied = filesCopied
        self.filesDeleted = filesDeleted
        self.filesMoved = filesMoved
        self.bytesTransferred = bytesTransferred
        self.conflicts = conflicts
        self.duration = duration
        self.errors = errors
    }
}
