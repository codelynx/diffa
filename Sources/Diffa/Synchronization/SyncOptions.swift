import Foundation

/// Options for synchronization operations
public struct SyncOptions {
    /// Don't modify files, just report what would be done
    public var dryRun: Bool = false

    /// Re-compare snapshots after sync to verify result
    public var verifyAfterSync: Bool = false

    /// Delete files in destination that don't exist in source
    /// Only applies to unidirectional sync
    public var deleteExtraFiles: Bool = true

    /// Preserve modification times and permissions (future enhancement)
    /// Currently not implemented - reserved for Phase 4
    public var preserveMetadata: Bool = true

    public init(
        dryRun: Bool = false,
        verifyAfterSync: Bool = false,
        deleteExtraFiles: Bool = true,
        preserveMetadata: Bool = true
    ) {
        self.dryRun = dryRun
        self.verifyAfterSync = verifyAfterSync
        self.deleteExtraFiles = deleteExtraFiles
        self.preserveMetadata = preserveMetadata
    }
}
