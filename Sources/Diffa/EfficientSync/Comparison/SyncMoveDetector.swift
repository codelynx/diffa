import Foundation

/// Detects file moves using deterministic hash-based pairing (EfficientSync implementation)
///
/// **Algorithm:**
/// 1. Group add/delete operations by hash
/// 2. For each hash with matching add+delete counts: sort by path and pair 1:1
/// 3. Convert paired operations into move operations
/// 4. Unmatched operations remain as add/delete
///
/// **Determinism:**
/// - Pairing is stable across runs (sorted by path)
/// - Same input always produces same moves
/// - No heuristics or "smart" matching (e.g., shortest distance)
///
/// **Example:**
/// ```
/// Source: [album1/photo.jpg, album2/photo.jpg] (hash: aaa)
/// Dest:   [old/img1.jpg, old/img2.jpg] (hash: aaa)
///
/// Operations before move detection:
///   - Delete old/img1.jpg (hash: aaa)
///   - Delete old/img2.jpg (hash: aaa)
///   - Add album1/photo.jpg (hash: aaa)
///   - Add album2/photo.jpg (hash: aaa)
///
/// Operations after move detection:
///   - Move old/img1.jpg → album1/photo.jpg
///   - Move old/img2.jpg → album2/photo.jpg
/// ```
public struct SyncMoveDetector {
    public init() {}

    /// Detect moves in operations list (modifies in place)
    ///
    /// - Parameters:
    ///   - source: Source snapshot (not currently used, reserved for future optimization)
    ///   - dest: Destination snapshot (not currently used, reserved for future optimization)
    ///   - operations: Operations list to modify in place
    public func detectMoves(
        source: SyncSnapshot,
        dest: SyncSnapshot,
        operations: inout [FileOperation]
    ) {
        // Step 1: Group operations by hash
        var addOperationsByHash: [Data: [FileOperation]] = [:]
        var deleteOperationsByHash: [Data: [FileOperation]] = [:]

        for operation in operations {
            switch operation.action {
            case .add:
                addOperationsByHash[operation.hash, default: []].append(operation)
            case .delete:
                deleteOperationsByHash[operation.hash, default: []].append(operation)
            default:
                // Ignore modify/move/conflict operations
                continue
            }
        }

        // Step 2: Find matching hashes and pair them
        var moveOperations: [FileOperation] = []
        var operationsToRemove: Set<String> = []  // Track by path (unique identifier)

        for (hash, addOps) in addOperationsByHash {
            guard let deleteOps = deleteOperationsByHash[hash] else {
                // No matching deletes, keep as add operations
                continue
            }

            // Only pair if counts match (deterministic pairing)
            let pairCount = min(addOps.count, deleteOps.count)
            guard pairCount > 0 else { continue }

            // Sort both lists by path for deterministic pairing
            let sortedAdds = addOps.sorted { $0.path < $1.path }
            let sortedDeletes = deleteOps.sorted { $0.path < $1.path }

            // Pair 1:1 in sorted order
            for i in 0..<pairCount {
                let addOp = sortedAdds[i]
                let deleteOp = sortedDeletes[i]

                // Create move operation: delete.path → add.path
                let moveOp = FileOperation(
                    action: .move(from: deleteOp.path),
                    path: addOp.path,
                    localFile: deleteOp.localFile,  // Old location file info
                    remoteFile: addOp.remoteFile    // New location file info
                )

                moveOperations.append(moveOp)

                // Mark original add/delete for removal
                operationsToRemove.insert(addOp.path)
                operationsToRemove.insert(deleteOp.path)
            }
        }

        // Step 3: Remove paired operations and add move operations
        operations.removeAll { operation in
            // Remove operations that were paired into moves
            switch operation.action {
            case .add, .delete:
                return operationsToRemove.contains(operation.path)
            default:
                return false
            }
        }

        // Add all move operations
        operations.append(contentsOf: moveOperations)
    }
}

// MARK: - CustomStringConvertible

extension SyncMoveDetector: CustomStringConvertible {
    public var description: String {
        "SyncMoveDetector(deterministic hash-based pairing)"
    }
}
