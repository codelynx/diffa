import Foundation

/// Strategy for resolving conflicts during bidirectional sync
public enum ConflictResolution {
    /// Use the file with the newest modification date
    case newest

    /// Always use the source version
    case sourceWins

    /// Always use the destination version
    case destinationWins

    /// Throw an error when a conflict is detected
    case error
}

/// Represents a conflict between source and destination
public struct Conflict {
    /// Path where the conflict occurred
    public let path: String

    /// Type of conflict
    public let type: ConflictType

    /// Source snapshot item (nil if only in destination)
    public let sourceItem: SnapshotItem?

    /// Destination snapshot item (nil if only in source)
    public let destinationItem: SnapshotItem?

    public init(
        path: String,
        type: ConflictType,
        sourceItem: SnapshotItem?,
        destinationItem: SnapshotItem?
    ) {
        self.path = path
        self.type = type
        self.sourceItem = sourceItem
        self.destinationItem = destinationItem
    }
}

/// Type of conflict detected
///
/// Note: Without a common ancestor snapshot, we cannot distinguish causality.
/// These types reflect divergence, not which side changed.
public enum ConflictType {
    /// Path exists in both with different hash/metadata
    /// (Can't tell which side changed without ancestor)
    case diverged

    /// Path exists only in source
    /// (Could be "source added" OR "destination deleted" - unknown without ancestor)
    case onlyInSource

    /// Path exists only in destination
    /// (Could be "destination added" OR "source deleted" - unknown without ancestor)
    case onlyInDestination
}

/// Record of how a conflict was resolved
public struct ResolvedConflict {
    /// The original conflict
    public let conflict: Conflict

    /// The resolution strategy that was applied
    public let resolution: ConflictResolution

    /// Description of the action taken
    public let action: String

    public init(
        conflict: Conflict,
        resolution: ConflictResolution,
        action: String
    ) {
        self.conflict = conflict
        self.resolution = resolution
        self.action = action
    }
}
