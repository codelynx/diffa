import Foundation

/// Detects conflicts when syncing bidirectionally
///
/// Without a common ancestor snapshot, we detect **divergence** rather than **causality**.
/// We can only observe that paths differ, not which side changed or why.
class ConflictDetector {

    /// Detect conflicts when syncing bidirectionally
    ///
    /// Conflicts occur when paths exist in source, destination, or both with differences.
    /// Without a common ancestor, we cannot determine causality, only divergence.
    ///
    /// - Parameter difference: The comparison result between source and destination
    /// - Returns: Array of conflicts detected
    func detectConflicts(difference: Difference) throws -> [Conflict] {
        var conflicts: [Conflict] = []

        // Collect all unique paths from difference
        var allPaths = Set<String>()

        // Paths in added (exist in dest, not in source)
        for item in try difference.added {
            allPaths.insert(item.path)
        }

        // Paths in removed (exist in source, not in dest)
        for item in try difference.removed {
            allPaths.insert(item.path)
        }

        // Paths in modified (exist in both but differ)
        for item in try difference.modified {
            allPaths.insert(item.path)
        }

        // Classify each path
        for path in allPaths {
            let sourceItem = try difference.sourceItem(for: path)
            let destItem = try difference.destinationItem(for: path)

            if let conflictType = classifyConflict(
                path: path,
                sourceItem: sourceItem,
                destItem: destItem
            ) {
                let conflict = Conflict(
                    path: path,
                    type: conflictType,
                    sourceItem: sourceItem,
                    destinationItem: destItem
                )
                conflicts.append(conflict)
            }
        }

        return conflicts
    }

    /// Classify conflict type for a path
    ///
    /// - Parameters:
    ///   - path: The path being classified
    ///   - sourceItem: Item from source snapshot (nil if doesn't exist)
    ///   - destItem: Item from destination snapshot (nil if doesn't exist)
    /// - Returns: ConflictType if this is a conflict, nil if identical
    private func classifyConflict(
        path: String,
        sourceItem: SnapshotItem?,
        destItem: SnapshotItem?
    ) -> ConflictType? {

        switch (sourceItem, destItem) {
        case (let source?, let dest?):
            // Both exist - check if they're identical
            if areIdentical(source, dest) {
                // Not a conflict - files are identical
                return nil
            } else {
                // Files exist in both but differ
                return .diverged
            }

        case (_?, nil):
            // Only in source (destination doesn't have it)
            return .onlyInSource

        case (nil, _?):
            // Only in destination (source doesn't have it)
            return .onlyInDestination

        case (nil, nil):
            // Neither exists - shouldn't happen if path came from Difference
            // But handle gracefully
            return nil
        }
    }

    /// Check if two items are identical (same content and type)
    ///
    /// - Parameters:
    ///   - item1: First item to compare
    ///   - item2: Second item to compare
    /// - Returns: True if items are identical
    private func areIdentical(_ item1: SnapshotItem, _ item2: SnapshotItem) -> Bool {
        // Must be same type (both files or both folders)
        guard item1.isFolder == item2.isFolder else {
            return false
        }

        if item1.isFolder {
            // For folders, just check type matches
            // Metadata differences on folders aren't considered conflicts
            return true
        } else {
            // For files, check hash
            // If hashes match, files are identical
            return item1.sha256 == item2.sha256
        }
    }
}
