import Foundation

/// Represents a detected file move/rename operation
public struct DetectedMove {
    /// Original path (in source snapshot)
    public let fromPath: String

    /// New path (in destination snapshot)
    public let toPath: String

    /// SHA-256 hash (must match for both paths)
    public let hash: String

    /// File size (must match for both paths)
    public let size: Int64

    public init(fromPath: String, toPath: String, hash: String, size: Int64) {
        self.fromPath = fromPath
        self.toPath = toPath
        self.hash = hash
        self.size = size
    }
}

/// Detects moved/renamed files between snapshots
///
/// Uses O(N) hash-based indexing to match removed and added files.
/// Files with matching hash+size are considered moves rather than delete+add.
///
/// **Algorithm:**
/// 1. Get removed items from difference
/// 2. Get added items from difference
/// 3. Build hash index for added items (key = "hash-size")
/// 4. For each removed item, look up in index
/// 5. If match found → move, else → deletion
/// 6. Remaining added items → actual additions
///
/// **Complexity:** O(N) where N = total differences
public class MoveDetector {

    /// Detect moved/renamed files in a difference
    ///
    /// - Parameter difference: Difference between two snapshots
    /// - Returns: List of detected moves
    /// - Throws: DiffallaError on comparison failure
    public func detectMoves(difference: Difference) throws -> [DetectedMove] {
        // Get all removed and added items
        let removed = try difference.removed
        let added = try difference.added

        // Build hash index for added items
        // Key format: "hash-size" to ensure both match
        var addedByHashSize: [String: [SnapshotItem]] = [:]

        for item in added {
            // Only consider files (not directories)
            guard !item.isFolder, let hash = item.sha256 else {
                continue
            }

            let key = "\(hash)-\(item.size)"
            addedByHashSize[key, default: []].append(item)
        }

        // Match removed items with added items
        var moves: [DetectedMove] = []

        for removedItem in removed {
            // Only consider files (not directories)
            guard !removedItem.isFolder, let hash = removedItem.sha256 else {
                continue
            }

            let key = "\(hash)-\(removedItem.size)"

            // Check if there's a matching added item
            if var candidates = addedByHashSize[key], !candidates.isEmpty {
                // Found a match - this is a move
                // Use removeLast() instead of removeFirst() for O(1) removal
                // (avoids O(k) array shift, keeping algorithm truly O(N))
                let addedItem = candidates.removeLast()

                let move = DetectedMove(
                    fromPath: removedItem.path,
                    toPath: addedItem.path,
                    hash: hash,
                    size: removedItem.size
                )
                moves.append(move)

                // Update the index
                if candidates.isEmpty {
                    addedByHashSize.removeValue(forKey: key)
                } else {
                    addedByHashSize[key] = candidates
                }
            }
            // If no match, it's a deletion (not a move)
        }

        return moves
    }

    /// Detect moves and return updated lists of additions/removals
    ///
    /// - Parameter difference: Difference between two snapshots
    /// - Returns: Tuple of (moves, actualAdditions, actualRemovals)
    /// - Throws: DiffallaError on comparison failure
    public func detectMovesWithRemainder(
        difference: Difference
    ) throws -> (moves: [DetectedMove], additions: [SnapshotItem], removals: [SnapshotItem]) {
        let removed = try difference.removed
        let added = try difference.added

        // Build hash index for added items
        var addedByHashSize: [String: [SnapshotItem]] = [:]
        for item in added {
            guard !item.isFolder, let hash = item.sha256 else {
                continue
            }
            let key = "\(hash)-\(item.size)"
            addedByHashSize[key, default: []].append(item)
        }

        // Track which items are moves vs actual removals
        var moves: [DetectedMove] = []
        var actualRemovals: [SnapshotItem] = []

        for removedItem in removed {
            guard !removedItem.isFolder, let hash = removedItem.sha256 else {
                // Directories are always considered removals (not moves)
                actualRemovals.append(removedItem)
                continue
            }

            let key = "\(hash)-\(removedItem.size)"

            if var candidates = addedByHashSize[key], !candidates.isEmpty {
                // Found a match - this is a move
                // Use removeLast() instead of removeFirst() for O(1) removal
                let addedItem = candidates.removeLast()

                let move = DetectedMove(
                    fromPath: removedItem.path,
                    toPath: addedItem.path,
                    hash: hash,
                    size: removedItem.size
                )
                moves.append(move)

                // Update index
                if candidates.isEmpty {
                    addedByHashSize.removeValue(forKey: key)
                } else {
                    addedByHashSize[key] = candidates
                }
            } else {
                // No match - actual removal
                actualRemovals.append(removedItem)
            }
        }

        // Remaining items in index are actual additions
        var actualAdditions: [SnapshotItem] = []
        for items in addedByHashSize.values {
            actualAdditions.append(contentsOf: items)
        }

        // Also include directories and files without hashes from original added list
        for item in added {
            if item.isFolder {
                actualAdditions.append(item)
            } else if item.sha256 == nil {
                actualAdditions.append(item)
            }
        }

        // Sort for deterministic ordering (Dictionary.values is unordered)
        actualAdditions.sort { $0.path < $1.path }

        return (moves, actualAdditions, actualRemovals)
    }
}
