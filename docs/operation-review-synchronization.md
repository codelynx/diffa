# Operation Review: Synchronization

This document reviews folder synchronization operations.

## Core Concept

**Synchronization** makes two folders identical or mirrors one folder to another.

**Two modes:**
1. **Unidirectional sync** - Make B identical to A (A → B)
2. **Bidirectional sync** - Make A and B identical (A ↔ B)

```
Unidirectional:
    Directory A (source)
         ↓
    Directory B (destination)

    Result: B becomes exact copy of A

Bidirectional:
    Directory A ←→ Directory B

    Result: Both become identical
    (conflicts must be resolved)
```

## Architecture

```
┌─────────────────────────────────────────────┐
│  Synchronization Process                    │
│  ┌────────────────────────────────────────┐ │
│  │ 1. Create snapshots                    │ │
│  │    - Snapshot A                        │ │
│  │    - Snapshot B                        │ │
│  │                                        │ │
│  │ 2. Compare snapshots                   │ │
│  │    - Difference A→B                    │ │
│  │    - Difference B→A (bidirectional)    │ │
│  │                                        │ │
│  │ 3. Resolve conflicts (bidirectional)   │ │
│  │    - Detect conflicts                  │ │
│  │    - Apply resolution strategy         │ │
│  │                                        │ │
│  │ 4. Execute operations                  │ │
│  │    - Copy files                        │ │
│  │    - Delete files                      │ │
│  │    - Move files (optimization)         │ │
│  │                                        │ │
│  │ 5. Return SyncResult                   │ │
│  │    - Files copied/deleted/moved        │ │
│  │    - Bytes transferred                 │ │
│  │    - Conflicts resolved                │ │
│  │    - Errors encountered                │ │
│  └────────────────────────────────────────┘ │
└─────────────────────────────────────────────┘
```

## Operation 1: Unidirectional Sync (A → B)

**Goal:** Make B identical to A (mirror A to B)

### Input
```swift
let source = URL(fileURLWithPath: "/path/to/A")
let destination = URL(fileURLWithPath: "/path/to/B")
```

### Process

**Step 1: Create snapshots**

```swift
let snapshotA = try await Snapshot.create(
    from: source,
    saveTo: temporaryDirectory().appendingPathComponent("snapshot_a.sqlite"),
    progress: { progress in
        reportProgress(.scanning(directory: "A", progress: progress))
    }
)

let snapshotB = try await Snapshot.create(
    from: destination,
    saveTo: temporaryDirectory().appendingPathComponent("snapshot_b.sqlite"),
    progress: { progress in
        reportProgress(.scanning(directory: "B", progress: progress))
    }
)
```

**Step 2: Compare snapshots**

```swift
let diff = try Difference.compare(source: snapshotA, destination: snapshotB)

let toAdd = diff.added       // In A, not in B → copy to B
let toRemove = diff.removed  // In B, not in A → delete from B
let toUpdate = diff.modified // Different content → copy from A to B
```

**Step 3: Detect moves (optimization)**

```swift
// Find files that were moved in A
let moves = detectMoves(removed: toRemove, added: toAdd)

// Files with same hash but different paths
for (oldPath, newPath) in moves {
    // Instead of delete + copy, just move
    operations.append(.move(from: oldPath, to: newPath))
}
```

**Step 4: Execute operations**

```swift
var result = SyncResult()

// Process additions (files in A, not in B)
for item in toAdd where !isMoved(item) {
    let sourcePath = source.appendingPathComponent(item.path)
    let destPath = destination.appendingPathComponent(item.path)

    try createParentDirectories(for: destPath)
    try copyFile(from: sourcePath, to: destPath)

    result.filesCopied += 1
    result.bytesTransferred += item.size

    reportProgress(.copying(path: item.path, bytes: item.size))
}

// Process updates (different content)
for item in toUpdate {
    let sourcePath = source.appendingPathComponent(item.path)
    let destPath = destination.appendingPathComponent(item.path)

    try copyFile(from: sourcePath, to: destPath)

    result.filesCopied += 1
    result.bytesTransferred += item.size

    reportProgress(.copying(path: item.path, bytes: item.size))
}

// Process removals (files in B, not in A)
for item in toRemove where !isMoved(item) {
    let destPath = destination.appendingPathComponent(item.path)

    try FileManager.default.removeItem(at: destPath)

    result.filesDeleted += 1

    reportProgress(.deleting(path: item.path))
}

// Process moves (optimization)
for (oldPath, newPath) in moves {
    let oldURL = destination.appendingPathComponent(oldPath)
    let newURL = destination.appendingPathComponent(newPath)

    try createParentDirectories(for: newURL)
    try FileManager.default.moveItem(at: oldURL, to: newURL)

    result.filesMoved += 1

    reportProgress(.moving(from: oldPath, to: newPath))
}
```

**Step 5: Return result**

```swift
return SyncResult(
    filesCopied: result.filesCopied,
    filesDeleted: result.filesDeleted,
    filesMoved: result.filesMoved,
    bytesTransferred: result.bytesTransferred,
    conflicts: [],  // No conflicts in unidirectional sync
    duration: elapsed,
    errors: []
)
```

### Result

```swift
let result = try await Diffa.syncUnidirectional(
    source: sourceDir,
    destination: destDir,
    progress: { progress in
        print("\\(progress.filesProcessed) / \\(progress.totalFiles ?? 0)")
    }
)

print("Copied: \\(result.filesCopied) files")
print("Deleted: \\(result.filesDeleted) files")
print("Moved: \\(result.filesMoved) files")
print("Transferred: \\(result.bytesTransferred) bytes")
```

**After sync:**
- B is identical to A
- Files in A are copied to B
- Files not in A are deleted from B
- Moves detected and optimized

## Operation 2: Bidirectional Sync (A ↔ B)

**Goal:** Make A and B identical (resolve conflicts)

### Input
```swift
let dirA = URL(fileURLWithPath: "/path/to/A")
let dirB = URL(fileURLWithPath: "/path/to/B")
let conflictResolution: ConflictResolution = .newest
```

### Process

**Step 1: Create snapshots**

```swift
let snapshotA = try await Snapshot.create(from: dirA, saveTo: "a.sqlite")
let snapshotB = try await Snapshot.create(from: dirB, saveTo: "b.sqlite")
```

**Step 2: Compare both directions**

```swift
// What's different from A's perspective?
let diffAtoB = try Difference.compare(source: snapshotA, destination: snapshotB)

// What's different from B's perspective?
let diffBtoA = try Difference.compare(source: snapshotB, destination: snapshotA)
```

**Step 3: Detect conflicts**

A conflict occurs when a file is:
- Modified in both A and B (different hashes)
- Added in both A and B with different content
- Deleted in A, modified in B
- Modified in A, deleted in B

```swift
struct Conflict {
    let path: String
    let itemA: SnapshotItem?  // nil if deleted
    let itemB: SnapshotItem?  // nil if deleted
    let type: ConflictType
}

enum ConflictType {
    case bothModified       // Modified in A and B
    case addedInBoth       // Added in A and B (different content)
    case deletedInAModifiedInB
    case modifiedInADeletedInB
}

var conflicts: [Conflict] = []

// Find files modified in both
let modifiedInA = Set(diffAtoB.modified.map { $0.path })
let modifiedInB = Set(diffBtoA.modified.map { $0.path })
let bothModified = modifiedInA.intersection(modifiedInB)

for path in bothModified {
    let itemA = try snapshotA.getItem(path: path)
    let itemB = try snapshotB.getItem(path: path)

    if itemA?.sha256 != itemB?.sha256 {
        conflicts.append(Conflict(
            path: path,
            itemA: itemA,
            itemB: itemB,
            type: .bothModified
        ))
    }
}

// Find files added in both (with different content)
let addedInA = Set(diffAtoB.added.map { $0.path })
let addedInB = Set(diffBtoA.added.map { $0.path })
let addedInBoth = addedInA.intersection(addedInB)

for path in addedInBoth {
    let itemA = try snapshotA.getItem(path: path)
    let itemB = try snapshotB.getItem(path: path)

    if itemA?.sha256 != itemB?.sha256 {
        conflicts.append(Conflict(
            path: path,
            itemA: itemA,
            itemB: itemB,
            type: .addedInBoth
        ))
    }
}

// Find delete-modify conflicts
let removedInA = Set(diffAtoB.removed.map { $0.path })
let removedInB = Set(diffBtoA.removed.map { $0.path })

for path in removedInA {
    if modifiedInB.contains(path) {
        conflicts.append(Conflict(
            path: path,
            itemA: nil,
            itemB: try snapshotB.getItem(path: path),
            type: .deletedInAModifiedInB
        ))
    }
}

for path in removedInB {
    if modifiedInA.contains(path) {
        conflicts.append(Conflict(
            path: path,
            itemA: try snapshotA.getItem(path: path),
            itemB: nil,
            type: .modifiedInADeletedInB
        ))
    }
}
```

**Step 4: Resolve conflicts**

```swift
var resolutions: [ConflictAction] = []

for conflict in conflicts {
    let action = try await resolveConflict(conflict, strategy: conflictResolution)
    resolutions.append(action)
}

func resolveConflict(
    _ conflict: Conflict,
    strategy: ConflictResolution
) async throws -> ConflictAction {
    switch strategy {
    case .newest:
        // Use file with most recent modification date
        if let itemA = conflict.itemA, let itemB = conflict.itemB {
            return itemA.metadata.modificationDate > itemB.metadata.modificationDate
                ? .useA
                : .useB
        } else if conflict.itemA != nil {
            return .useA  // B deleted it, but A has newer version
        } else {
            return .useB  // A deleted it, but B has newer version
        }

    case .sourceWins:
        // A always wins
        return .useA

    case .destinationWins:
        // B always wins
        return .useB

    case .keepBoth:
        // Keep both files (rename one)
        return .keepBoth

    case .manual(let resolver):
        // Ask user
        return try await resolver(conflict)

    case .error:
        // Fail on conflicts
        throw SyncError.conflictDetected(conflict)
    }
}
```

**Step 5: Execute operations**

```swift
var operations: [SyncOperation] = []

// Handle conflicts first
for (conflict, action) in zip(conflicts, resolutions) {
    switch action {
    case .useA:
        // Copy A to B (or delete from B if A deleted)
        if let itemA = conflict.itemA {
            operations.append(.copy(from: dirA, to: dirB, path: itemA.path))
        } else {
            operations.append(.delete(from: dirB, path: conflict.path))
        }

    case .useB:
        // Copy B to A (or delete from A if B deleted)
        if let itemB = conflict.itemB {
            operations.append(.copy(from: dirB, to: dirA, path: itemB.path))
        } else {
            operations.append(.delete(from: dirA, path: conflict.path))
        }

    case .keepBoth:
        // Keep both with different names
        let newPathA = conflict.path + ".fromA"
        let newPathB = conflict.path + ".fromB"
        operations.append(.copy(from: dirA, to: dirB, path: conflict.path, as: newPathA))
        operations.append(.copy(from: dirB, to: dirA, path: conflict.path, as: newPathB))

    case .skip:
        // Do nothing
        continue

    case .abort:
        throw SyncError.userAborted
    }
}

// Handle non-conflicting changes

// Files only in A → copy to B
for item in diffAtoB.added where !isConflict(item.path) {
    operations.append(.copy(from: dirA, to: dirB, path: item.path))
}

// Files only in B → copy to A
for item in diffBtoA.added where !isConflict(item.path) {
    operations.append(.copy(from: dirB, to: dirA, path: item.path))
}

// Files modified only in A → copy to B
for item in diffAtoB.modified where !isConflict(item.path) {
    operations.append(.copy(from: dirA, to: dirB, path: item.path))
}

// Files modified only in B → copy to A
for item in diffBtoA.modified where !isConflict(item.path) {
    operations.append(.copy(from: dirB, to: dirA, path: item.path))
}

// Execute all operations
var result = SyncResult()

for operation in operations {
    try await executeOperation(operation, result: &result)
}
```

**Step 6: Return result**

```swift
return SyncResult(
    filesCopied: result.filesCopied,
    filesDeleted: result.filesDeleted,
    filesMoved: result.filesMoved,
    bytesTransferred: result.bytesTransferred,
    conflicts: conflicts.map { ConflictResolution(conflict: $0, action: action) },
    duration: elapsed,
    errors: []
)
```

### Result

```swift
let result = try await Diffa.syncBidirectional(
    a: dirA,
    b: dirB,
    conflictResolution: .newest,
    progress: { progress in
        print("\\(progress.currentOperation)")
    }
)

print("Synced: \\(result.filesCopied) files")
print("Conflicts: \\(result.conflicts.count)")
```

**After sync:**
- A and B are identical
- All conflicts resolved according to strategy
- Files in one copied to the other
- Both directories have same content

## Conflict Resolution Strategies

### .newest (Most Common)
```swift
// Use file with most recent modification date
if itemA.modificationDate > itemB.modificationDate {
    use itemA
} else {
    use itemB
}
```

**Use case:** Backup sync where latest changes should win

### .sourceWins
```swift
// A always wins
use itemA
```

**Use case:** Deployment where source is authoritative

### .destinationWins
```swift
// B always wins
use itemB
```

**Use case:** Restore where destination should be preserved

### .keepBoth
```swift
// Keep both files with different names
save itemA as "file.txt.fromA"
save itemB as "file.txt.fromB"
```

**Use case:** When can't decide automatically

### .manual(resolver)
```swift
// Ask user for each conflict
let action = await resolver(conflict)
```

**Use case:** Interactive sync with user input

### .error
```swift
// Fail immediately on conflict
throw SyncError.conflictDetected
```

**Use case:** When conflicts are unexpected and should be investigated

## Move Detection

**Problem:** File moved from `old/path.txt` to `new/path.txt`
- Without detection: Delete `old/path.txt` + Copy `new/path.txt`
- With detection: Move `old/path.txt` to `new/path.txt`

**Algorithm:**

```swift
func detectMoves(removed: [SnapshotItem], added: [SnapshotItem]) -> [(String, String)] {
    var moves: [(String, String)] = []

    // Group by hash
    let removedByHash = Dictionary(grouping: removed) { $0.sha256 ?? "" }
    let addedByHash = Dictionary(grouping: added) { $0.sha256 ?? "" }

    // Find matching hashes
    for (hash, removedItems) in removedByHash {
        guard let addedItems = addedByHash[hash] else { continue }

        // Match removed and added items with same hash
        for removedItem in removedItems {
            for addedItem in addedItems {
                // Same hash, different path = move
                if removedItem.path != addedItem.path {
                    moves.append((removedItem.path, addedItem.path))
                }
            }
        }
    }

    return moves
}
```

**Benefits:**
- Faster: Move is O(1), copy is O(n) where n = file size
- Less disk I/O
- Preserves file inodes (on some file systems)

## API Design

```swift
extension Diffa {
    // Unidirectional sync (A → B)
    static func syncUnidirectional(
        source: URL,
        destination: URL,
        progress: ((SyncProgress) -> Void)? = nil
    ) async throws -> SyncResult

    // Bidirectional sync (A ↔ B)
    static func syncBidirectional(
        a: URL,
        b: URL,
        conflictResolution: ConflictResolution = .newest,
        progress: ((SyncProgress) -> Void)? = nil
    ) async throws -> SyncResult
}

struct SyncProgress {
    var currentOperation: String
    var filesProcessed: Int
    var totalFiles: Int?
    var bytesTransferred: Int64
    var totalBytes: Int64?
    var operationType: OperationType
}

enum OperationType {
    case scanning
    case comparing
    case copying
    case deleting
    case moving
}

struct SyncResult {
    let filesCopied: Int
    let filesDeleted: Int
    let filesMoved: Int
    let bytesTransferred: Int64
    let conflicts: [ConflictResolution]
    let duration: TimeInterval
    let errors: [SyncError]
}

enum ConflictResolution {
    case newest
    case sourceWins
    case destinationWins
    case keepBoth
    case manual((Conflict) async -> ConflictAction)
    case error
}

enum ConflictAction {
    case useA
    case useB
    case keepBoth
    case skip
    case abort
}

struct Conflict {
    let path: String
    let itemA: SnapshotItem?
    let itemB: SnapshotItem?
    let type: ConflictType
}

enum ConflictType {
    case bothModified
    case addedInBoth
    case deletedInAModifiedInB
    case modifiedInADeletedInB
}
```

## Use Cases

### Backup Synchronization

```swift
// Sync source to backup (unidirectional)
let result = try await Diffa.syncUnidirectional(
    source: documents,
    destination: backup,
    progress: { progress in
        updateProgressBar(progress.bytesTransferred, progress.totalBytes)
    }
)

print("Backup complete: \\(result.bytesTransferred) bytes")
```

### Two-Way Sync (Dropbox-style)

```swift
// Sync two folders (bidirectional)
let result = try await Diffa.syncBidirectional(
    a: localFolder,
    b: remoteFolder,
    conflictResolution: .newest,  // Latest changes win
    progress: { progress in
        print(progress.currentOperation)
    }
)

print("Conflicts resolved: \\(result.conflicts.count)")
```

### Deployment

```swift
// Deploy source to production (source wins)
let result = try await Diffa.syncUnidirectional(
    source: stagingDir,
    destination: productionDir,
    progress: { progress in
        logProgress(progress)
    }
)

print("Deployed \\(result.filesCopied) files")
```

## Error Handling

### Common Errors

```swift
enum SyncError: Error {
    case snapshotCreationFailed(URL, Error)
    case comparisonFailed(Error)
    case conflictDetected(Conflict)
    case copyFailed(from: String, to: String, Error)
    case deleteFailed(String, Error)
    case moveFailed(from: String, to: String, Error)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case permissionDenied(String)
    case userAborted
}
```

### Partial Sync

**Question:** What if sync fails halfway?

**Options:**
1. **Continue** - Complete as much as possible, return errors in result
2. **Rollback** - Undo all changes (complex, requires transaction log)
3. **Abort** - Stop immediately, leave partial state

**Recommendation:** Option 1 (continue), with detailed error reporting in `SyncResult.errors`

```swift
struct SyncResult {
    // ...
    let errors: [SyncError]  // Non-fatal errors that occurred
}
```

## Performance Characteristics

### Unidirectional Sync (100,000 files, 10 GB)

| Phase | Time | Memory |
|-------|------|--------|
| Create snapshot A | ~5 min | < 30 MB |
| Create snapshot B | ~5 min | < 30 MB |
| Compare | < 1 sec | < 50 MB |
| Execute (1% changed) | ~30 sec | < 50 MB |
| **Total** | **~10 min** | **< 50 MB** |

### Bidirectional Sync (Same Dataset)

| Phase | Time | Memory |
|-------|------|--------|
| Create snapshots | ~10 min | < 30 MB |
| Compare both directions | < 2 sec | < 50 MB |
| Detect conflicts | < 1 sec | < 50 MB |
| Resolve conflicts | varies | minimal |
| Execute operations | ~60 sec | < 50 MB |
| **Total** | **~11 min** | **< 50 MB** |

### Move Detection Impact

**Without move detection:**
- Delete file: ~0.01 sec
- Copy file (1 GB): ~10 sec
- **Total: ~10 sec**

**With move detection:**
- Move file (1 GB): ~0.1 sec
- **Total: ~0.1 sec**

**100x faster for large files!**

## Review Summary

✅ **Unidirectional sync** - Mirror A to B
✅ **Bidirectional sync** - Make A and B identical
✅ **Conflict detection** - Find files changed in both
✅ **Conflict resolution** - Multiple strategies (.newest, .sourceWins, etc.)
✅ **Move detection** - Optimize by detecting file moves
✅ **Progress reporting** - Track operation progress
✅ **Error handling** - Continue on non-fatal errors

**Ready for implementation?** YES / NO

If any concerns, document them here before proceeding to implementation.
