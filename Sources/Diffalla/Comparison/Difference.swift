import Foundation

/// Represents the difference between two snapshots
public class Difference {
    /// The source (original) snapshot
    public let sourceSnapshot: Snapshot

    /// The destination (new) snapshot
    public let destinationSnapshot: Snapshot

    /// Cached added items (lazy evaluation)
    private var cachedAdded: [SnapshotItem]?

    /// Cached removed items (lazy evaluation)
    private var cachedRemoved: [SnapshotItem]?

    /// Cached modified items (lazy evaluation)
    private var cachedModified: [SnapshotItem]?

    /// Comparison engine for executing queries
    private let engine: ComparisonEngine

    /// Private initializer (use factory method)
    private init(source: Snapshot, destination: Snapshot) {
        self.sourceSnapshot = source
        self.destinationSnapshot = destination
        self.engine = ComparisonEngine()
    }

    /// Compare two snapshots and create a Difference
    /// - Parameters:
    ///   - source: The source (original) snapshot
    ///   - destination: The destination (new) snapshot
    /// - Returns: A Difference object representing the changes
    public static func compare(source: Snapshot, destination: Snapshot) throws -> Difference {
        return Difference(source: source, destination: destination)
    }

    /// Items added in destination (not in source) - lazy evaluated and cached
    public var added: [SnapshotItem] {
        get throws {
            if let cached = cachedAdded {
                return cached
            }
            let result = try engine.findAdded(source: sourceSnapshot, destination: destinationSnapshot)
            cachedAdded = result
            return result
        }
    }

    /// Items removed from source (not in destination) - lazy evaluated and cached
    public var removed: [SnapshotItem] {
        get throws {
            if let cached = cachedRemoved {
                return cached
            }
            let result = try engine.findRemoved(source: sourceSnapshot, destination: destinationSnapshot)
            cachedRemoved = result
            return result
        }
    }

    /// Items modified between snapshots - lazy evaluated and cached
    public var modified: [SnapshotItem] {
        get throws {
            if let cached = cachedModified {
                return cached
            }
            let result = try engine.findModified(source: sourceSnapshot, destination: destinationSnapshot)
            cachedModified = result
            return result
        }
    }

    /// Check if there are any differences
    public var hasDifferences: Bool {
        get throws {
            return try !added.isEmpty || !removed.isEmpty || !modified.isEmpty
        }
    }
}
