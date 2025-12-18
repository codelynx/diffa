import Foundation

/// Compares two snapshots and generates file operations
///
/// **Design:**
/// - Mode-aware: push/pull/sync affect deletion behavior
/// - Move detection: pairs add+delete with same hash into moves
/// - Returns operations needed to make dest match source
///
/// **Modes:**
/// - `push`: Dest mirrors source (deletes dest-only files)
/// - `pull`: Source mirrors dest (deletes source-only files)
/// - `sync`: Merge both sides (no deletions, newer wins on conflicts)
///
/// **Example:**
/// ```swift
/// let comparator = SnapshotComparator()
/// let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .push)
/// for op in ops {
///     print("\(op.action): \(op.path)")
/// }
/// ```
public struct SnapshotComparator {
    private let moveDetector = SyncMoveDetector()

    public init() {}

    /// Compare two snapshots and generate operations
    ///
    /// - Parameters:
    ///   - source: Source snapshot (what we want)
    ///   - dest: Destination snapshot (current state)
    ///   - mode: Sync mode (affects deletion behavior)
    /// - Returns: Array of FileOperation to apply
    public func compare(
        source: SyncSnapshot,
        dest: SyncSnapshot,
        mode: SyncMode
    ) -> [FileOperation] {
        var operations: [FileOperation] = []

        // Build lookup dictionaries
        let sourceFiles = Dictionary(
            uniqueKeysWithValues: source.allFiles().map { ($0.path, $0) }
        )
        let destFiles = Dictionary(
            uniqueKeysWithValues: dest.allFiles().map { ($0.path, $0) }
        )

        // Added: in source, not in dest
        for (path, sourceFile) in sourceFiles {
            if destFiles[path] == nil {
                operations.append(FileOperation(
                    action: .add,
                    path: path,
                    localFile: nil,
                    remoteFile: sourceFile
                ))
            }
        }

        // Modified or Conflict: in both, different hash
        for (path, sourceFile) in sourceFiles {
            if let destFile = destFiles[path],
               sourceFile.hash != destFile.hash {

                if mode == .sync {
                    // Sync mode: generate conflict for resolution
                    operations.append(FileOperation(
                        action: .conflict,
                        path: path,
                        localFile: destFile,
                        remoteFile: sourceFile
                    ))
                } else {
                    // Push/Pull: unconditional overwrite
                    operations.append(FileOperation(
                        action: .modify,
                        path: path,
                        localFile: destFile,
                        remoteFile: sourceFile
                    ))
                }
            }
        }

        // Deleted: mode-dependent
        switch mode {
        case .push:
            // Push: dest mirrors source, delete dest-only files
            for (path, destFile) in destFiles {
                if sourceFiles[path] == nil {
                    operations.append(FileOperation(
                        action: .delete,
                        path: path,
                        localFile: destFile,
                        remoteFile: nil
                    ))
                }
            }

        case .pull:
            // Pull: source mirrors dest, delete source-only files
            // (In our model, "source" is remote, "dest" is local)
            // So dest-only files get deleted to match source
            for (path, destFile) in destFiles {
                if sourceFiles[path] == nil {
                    operations.append(FileOperation(
                        action: .delete,
                        path: path,
                        localFile: destFile,
                        remoteFile: nil
                    ))
                }
            }

        case .sync:
            // Sync: no deletions (merge both sides)
            // Dest-only files are kept as-is
            break
        }

        // Detect moves (pairs add+delete with same hash)
        moveDetector.detectMoves(source: source, dest: dest, operations: &operations)

        // Sort by path for determinism
        operations.sort { $0.path < $1.path }

        return operations
    }
}
