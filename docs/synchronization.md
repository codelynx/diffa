# Synchronization (Objective 4)

## Goal

Synchronize folders to make them identical or mirror one to another.

## Use Cases

### Backup Synchronization
- Keep backup folder synchronized with source
- Only copy changed files
- Remove deleted files from backup

### Deployment Synchronization
- Sync local development folder to server
- Deploy only changed files
- Ensure server matches expected state

### Mirror Maintenance
- Maintain exact mirror of source folder
- Automatic synchronization on change detection
- Bidirectional sync for collaborative scenarios

## Sync Modes

### Unidirectional Sync

Make destination identical to source (source → destination).

```swift
extension Diffa {
	static func syncUnidirectional(
		source: URL,
		destination: URL,
		progress: ((SyncProgress) -> Void)? = nil
	) async throws -> SyncResult
}
```

**Behavior:**
- Copy new/modified files from source to destination
- Delete files in destination that don't exist in source
- After sync, destination is identical to source
- Source remains unchanged

**Use case:** Backup, deployment, mirroring

### Bidirectional Sync

Make both folders identical (A ↔ B).

```swift
extension Diffa {
	static func syncBidirectional(
		a: URL,
		b: URL,
		conflictResolution: ConflictResolution = .newest,
		progress: ((SyncProgress) -> Void)? = nil
	) async throws -> SyncResult
}
```

**Behavior:**
- Copy new files from A to B and B to A
- Copy modified files based on conflict resolution strategy
- Delete files that were deleted on one side
- After sync, both folders are identical

**Use case:** Collaborative editing, two-way backup, redundancy

## Synchronization Process

### Unidirectional Sync Process

1. **Compare folders**
   - Run comparison: `Diffa.Difference.compare(source, destination)`
   - Identify added, removed, modified items

2. **Plan operations**
   - Added in source → Copy to destination
   - Removed from source → Delete from destination
   - Modified in source → Update in destination
   - Optimize with move detection

3. **Execute operations**
   - Copy files
   - Delete files
   - Move files (if optimization enabled)
   - Report progress

4. **Verify result**
   - Optional: Re-compare to verify sync succeeded
   - Return SyncResult with statistics

### Bidirectional Sync Process

1. **Compare folders**
   - Run comparison: `Diffa.Difference.compare(a, b)`
   - Identify added, removed, modified items

2. **Analyze conflicts**
   - File exists in both but modified → Conflict
   - File deleted on one side, modified on other → Conflict
   - Apply conflict resolution strategy

3. **Plan operations**
   - Added in A only → Copy to B
   - Added in B only → Copy to A
   - Modified in both → Resolve conflict
   - Deleted on one side → Delete on other (unless modified)

4. **Execute operations**
   - Copy files in both directions
   - Delete files in both directions
   - Resolve conflicts
   - Report progress

5. **Verify result**
   - Ensure both folders are now identical
   - Return SyncResult with statistics and conflict resolutions

## Conflict Resolution

### Conflict Types

1. **Both modified**: File modified in both A and B
2. **Modified vs deleted**: File modified on one side, deleted on other
3. **Metadata conflict**: Content same but metadata differs

### Resolution Strategies

```swift
enum ConflictResolution {
	case newest          // Use file with newest modification date
	case sourceWins      // Always use source version
	case destinationWins // Always use destination version
	case manual          // Callback for manual resolution
	case keepBoth        // Keep both versions with different names
	case error           // Throw error on conflict
}
```

### Manual Resolution

```swift
typealias ConflictResolver = (Conflict) async -> ConflictAction

enum ConflictAction {
	case useA
	case useB
	case keepBoth
	case skip
	case abort
}
```

## Progress Reporting

### SyncProgress

```swift
struct SyncProgress {
	var currentOperation: String      // Current file being processed
	var filesProcessed: Int          // Files processed so far
	var totalFiles: Int?             // Total files (nil if unknown)
	var bytesTransferred: Int64      // Bytes transferred
	var totalBytes: Int64?           // Total bytes (nil if unknown)
	var operationType: OperationType // Current operation type
}

enum OperationType {
	case copying
	case deleting
	case moving
	case comparing
}
```

## Sync Result

### SyncResult

```swift
struct SyncResult {
	let filesCopied: Int
	let filesDeleted: Int
	let filesMoved: Int
	let bytesTransferred: Int64
	let conflicts: [ConflictResolution]
	let duration: TimeInterval
	let errors: [SyncError]
}
```

### Example Usage

```swift
// Unidirectional sync
let result = try await Diffa.syncUnidirectional(
	source: URL(fileURLWithPath: "/source"),
	destination: URL(fileURLWithPath: "/backup"),
	progress: { progress in
		print("\(progress.operationType): \(progress.currentOperation)")
		let percent = (progress.bytesTransferred * 100) / (progress.totalBytes ?? 1)
		print("Progress: \(percent)%")
	}
)

print("Sync complete:")
print("  Copied: \(result.filesCopied) files")
print("  Deleted: \(result.filesDeleted) files")
print("  Transferred: \(result.bytesTransferred) bytes")
print("  Duration: \(result.duration) seconds")

// Bidirectional sync
let result = try await Diffa.syncBidirectional(
	a: URL(fileURLWithPath: "/folderA"),
	b: URL(fileURLWithPath: "/folderB"),
	conflictResolution: .newest,
	progress: { progress in
		print("Syncing: \(progress.currentOperation)")
	}
)

if !result.conflicts.isEmpty {
	print("Resolved \(result.conflicts.count) conflicts")
}
```

## Safety and Reliability

### Pre-sync Checks

- Verify source and destination exist
- Check permissions (read source, write destination)
- Estimate space requirements
- Warn if destination will lose data

### During Sync

- Handle errors gracefully
- Continue on non-critical errors
- Log all operations for audit
- Support cancellation

### Post-sync

- Verify sync completed successfully
- Report any errors encountered
- Optional: Verify folders are identical

### Rollback

On critical failure:
- Stop processing
- Option to rollback partial changes
- Preserve original state where possible

## Open Questions

1. **Atomic sync**: Should sync be atomic (all-or-nothing)?
2. **Incremental sync**: Support resuming interrupted sync?
3. **Dry run**: Support dry-run mode to preview changes?
4. **Filters**: Support include/exclude patterns?
5. **Metadata sync**: Preserve timestamps, permissions?
6. **Sparse files**: How to handle sparse files efficiently?
7. **Hard links**: How to handle hard links?
8. **Extended attributes**: Should we sync extended attributes?
9. **Concurrent sync**: Allow concurrent sync operations?
10. **Change detection**: Use modification time, hash, or both?
