# Phase 3 Implementation Breakdown

**Goal:** Working folder synchronization with conflict resolution
**Duration:** 3-4 weeks (broken into 11 incremental steps)

---

## Overview

Phase 3 delivers synchronization functionality: Unidirectional and bidirectional folder sync with conflict detection and resolution.

**Architecture:**
```
Snapshot → Difference → Sync Plan → Execute → SyncResult
                          ↓
                   Conflict Detection → Resolution
```

**Key Design Constraint:**
Phase 3 uses a **two-snapshot model** (current source and destination only). Without a common ancestor snapshot, we cannot distinguish "source added" from "destination deleted" or determine which side made changes. Conflicts are detected as "paths that diverge between the two trees" rather than tracking change causality.

**Breakdown Strategy:**
- Small, testable increments
- Each step builds on previous
- Test as we go
- Can pause/resume at any step

---

## Step 0: Extend Difference API (1-2 hours)

**Goal:** Add API to query both source and destination items for any path

**Problem:** Current `Difference` only exposes one `SnapshotItem` per path:
- `added` gives destination items only
- `removed` gives source items only
- `modified` gives destination items only

For conflict detection (Step 6), we need access to **both** source and destination versions.

**Deliverables:**
```swift
// Sources/Diffalla/Comparison/Difference.swift
extension Difference {
    /// Load source item for a given path
    /// - Returns: SnapshotItem from source snapshot, or nil if path doesn't exist in source
    public func sourceItem(for path: String) throws -> SnapshotItem?

    /// Load destination item for a given path
    /// - Returns: SnapshotItem from destination snapshot, or nil if path doesn't exist in destination
    public func destinationItem(for path: String) throws -> SnapshotItem?
}
```

**Implementation:**
```swift
public func sourceItem(for path: String) throws -> SnapshotItem? {
    let reader = SnapshotReader(snapshot: source)
    return try reader.loadItem(at: path)
}

public func destinationItem(for path: String) throws -> SnapshotItem? {
    let reader = SnapshotReader(snapshot: destination)
    return try reader.loadItem(at: path)
}
```

**Tests:**
- `testSourceItemForExistingPath()` (returns source item)
- `testSourceItemForNonexistentPath()` (returns nil)
- `testDestinationItemForExistingPath()` (returns destination item)
- `testDestinationItemForNonexistentPath()` (returns nil)
- `testSourceAndDestinationForModifiedPath()` (returns both versions)

**Exit Criteria:**
- ✅ Methods added to Difference extension
- ✅ Tests pass (5 tests)
- ✅ No warnings
- ✅ Both versions retrievable for any path

---

## Step 1: Sync Core Types (2-3 hours)

**Goal:** Define core synchronization types and enums

**Deliverables:**
```swift
// Sources/Diffalla/Synchronization/SyncProgress.swift
public struct SyncProgress {
    public let currentOperation: String
    public let filesProcessed: Int
    public let totalFiles: Int?
    public let bytesTransferred: Int64
    public let totalBytes: Int64?
    public let operationType: OperationType
}

public enum OperationType: String, Codable {
    case comparing
    case copying
    case deleting
    case moving
}

// Sources/Diffalla/Synchronization/SyncResult.swift
public struct SyncResult {
    public let filesCopied: Int
    public let filesDeleted: Int
    public let filesMoved: Int
    public let bytesTransferred: Int64
    public let conflicts: [ResolvedConflict]
    public let duration: TimeInterval
    public let errors: [DiffallaError]
}

// Sources/Diffalla/Synchronization/ConflictResolution.swift
public enum ConflictResolution {
    case newest          // Use file with newest modification date
    case sourceWins      // Always use source version
    case destinationWins // Always use destination version
    case error           // Throw error on conflict
}

public struct Conflict {
    public let path: String
    public let type: ConflictType
    public let sourceItem: SnapshotItem?
    public let destinationItem: SnapshotItem?
}

public enum ConflictType {
    case diverged           // Path exists in both with different hash/metadata
    case onlyInSource       // Path exists only in source (added or dest deleted? unknown without ancestor)
    case onlyInDestination  // Path exists only in destination (added or source deleted? unknown without ancestor)
}

// Note: Without a common ancestor snapshot, we cannot distinguish causality.
// "onlyInSource" could mean "source added" OR "destination deleted"
// "onlyInDestination" could mean "destination added" OR "source deleted"
// "diverged" means the path differs but we don't know which side changed

public struct ResolvedConflict {
    public let conflict: Conflict
    public let resolution: ConflictResolution
    public let action: String  // Description of what was done
}
```

**Tests:**
- `testSyncProgressCreation()` (struct initialization)
- `testOperationTypeCodable()` (encode/decode)
- `testSyncResultCreation()` (struct initialization)
- `testConflictCreation()` (conflict struct)

**Exit Criteria:**
- ✅ Types compile
- ✅ Tests pass (4 tests)
- ✅ No warnings

---

## Step 2: Sync Plan & Operations (3-4 hours)

**Goal:** Plan sync operations from Difference

**Deliverables:**
```swift
// Sources/Diffalla/Synchronization/SyncOperation.swift
enum SyncOperation {
    case copyFile(from: URL, to: URL, size: Int64)
    case deleteFile(at: URL)
    case createDirectory(at: URL)
    case deleteDirectory(at: URL)
}

// Sources/Diffalla/Synchronization/SyncPlanner.swift
class SyncPlanner {
    /// Plan unidirectional sync operations (source → destination)
    func planUnidirectional(
        difference: Difference,
        sourceDirectory: URL,
        destinationDirectory: URL
    ) throws -> [SyncOperation]

    /// Calculate total bytes for progress tracking
    func calculateTotalBytes(
        operations: [SyncOperation]
    ) -> Int64
}
```

**Implementation:**
- Added items → copy from source to destination
- Removed items → delete from destination
- Modified items → copy from source to destination (overwrite)
- Directories handled separately (create/delete)

**Tests:**
- `testPlanUnidirectionalWithAdded()` (plan copy operations)
- `testPlanUnidirectionalWithRemoved()` (plan delete operations)
- `testPlanUnidirectionalWithModified()` (plan update operations)
- `testPlanUnidirectionalWithMixed()` (all operation types)
- `testCalculateTotalBytes()` (byte counting)

**Exit Criteria:**
- ✅ Can plan sync operations from Difference
- ✅ Operations include source/destination URLs
- ✅ Tests pass (5 tests)
- ✅ Total bytes calculated correctly

---

## Step 3: Sync Executor (4-5 hours)

**Goal:** Execute sync operations with progress reporting

**Deliverables:**
```swift
// Sources/Diffalla/Synchronization/SyncExecutor.swift
class SyncExecutor {
    private let fileManager = FileManager.default

    /// Execute sync operations
    func execute(
        operations: [SyncOperation],
        totalBytes: Int64,
        progress: ((SyncProgress) -> Void)?
    ) async throws -> SyncResult

    private func executeCopyFile(
        from source: URL,
        to destination: URL,
        size: Int64,
        progress: inout SyncProgress,
        progressCallback: ((SyncProgress) -> Void)?
    ) throws

    private func executeDeleteFile(
        at path: URL,
        progress: inout SyncProgress,
        progressCallback: ((SyncProgress) -> Void)?
    ) throws
}
```

**Implementation:**
- Execute operations sequentially
- Track progress (files processed, bytes transferred)
- Report progress via callback
- Collect statistics for SyncResult
- Handle errors gracefully (continue on non-critical errors)

**Tests:**
- `testExecuteCopyOperation()` (copy single file)
- `testExecuteDeleteOperation()` (delete single file)
- `testExecuteMultipleOperations()` (sequence of operations)
- `testExecuteReportsProgress()` (progress callback invoked)
- `testExecuteCollectsStatistics()` (SyncResult accurate)

**Exit Criteria:**
- ✅ Operations execute correctly
- ✅ Progress reported accurately
- ✅ Tests pass (5 tests)
- ✅ Statistics collected

---

## Step 4: Unidirectional Sync (3-4 hours)

**Goal:** High-level unidirectional sync API

**Deliverables:**
```swift
// Sources/Diffalla/Synchronization/Synchronizer.swift
public class Synchronizer {
    private let engine = SnapshotEngine()

    /// Sync source to destination (make destination identical to source)
    public func syncUnidirectional(
        source: URL,
        destination: URL,
        options: SyncOptions = SyncOptions(),
        progress: ((SyncProgress) -> Void)? = nil
    ) async throws -> SyncResult
}

// Sources/Diffalla/Synchronization/SyncOptions.swift
public struct SyncOptions {
    public var dryRun: Bool = false           // Don't modify files, just report
    public var verifyAfterSync: Bool = false  // Re-compare after sync
    public var deleteExtraFiles: Bool = true  // Delete files in dest not in source
    public var preserveMetadata: Bool = true  // Preserve mod times, permissions
}
```

**Implementation:**
1. Create snapshots of source and destination
2. Compare snapshots
3. Plan sync operations
4. Execute operations (or skip if dry run)
5. Optionally verify result
6. Return SyncResult

**Tests:**
- `testSyncUnidirectionalEmptyToEmpty()` (no changes needed)
- `testSyncUnidirectionalWithNewFiles()` (copy new files)
- `testSyncUnidirectionalWithDeletedFiles()` (remove old files)
- `testSyncUnidirectionalWithModifiedFiles()` (update files)
- `testSyncUnidirectionalDryRun()` (no actual changes)
- `testSyncUnidirectionalVerify()` (verification succeeds)

**Exit Criteria:**
- ✅ Unidirectional sync works end-to-end
- ✅ Dry run mode works
- ✅ Tests pass (6 tests)
- ✅ Destination matches source after sync

---

## Step 5: Conflict Detection (3-4 hours)

**Goal:** Detect conflicts in bidirectional sync

**Note:** With only two snapshots (no common ancestor), we detect **divergence** rather than **causality**. We can't determine if a path difference is due to source changes or destination changes.

**Deliverables:**
```swift
// Sources/Diffalla/Synchronization/ConflictDetector.swift
class ConflictDetector {
    /// Detect conflicts when syncing bidirectionally
    /// Uses Difference.sourceItem(for:) and destinationItem(for:) to get both versions
    func detectConflicts(
        difference: Difference
    ) throws -> [Conflict]

    /// Classify conflict type for a path
    private func classifyConflict(
        path: String,
        sourceItem: SnapshotItem?,
        destItem: SnapshotItem?
    ) -> ConflictType?
}
```

**Conflict Detection Logic:**

Given a path that appears in `added`, `removed`, or `modified` from Difference:

1. **Load both versions** using `difference.sourceItem(for: path)` and `difference.destinationItem(for: path)`

2. **Classify the conflict:**
   - Both exist but differ (hash or metadata) → `diverged`
   - Only in source (dest is nil) → `onlyInSource`
   - Only in destination (source is nil) → `onlyInDestination`
   - Both exist and identical → **Not a conflict** (skip)

3. **For bidirectional sync:** Most paths will be conflicts because we can't know which side is "correct" without an ancestor.

**Tests:**
- `testDetectDivergedConflict()` (path exists in both with different hash)
- `testDetectOnlyInSourceConflict()` (path only in source)
- `testDetectOnlyInDestinationConflict()` (path only in destination)
- `testDetectNoConflictForIdentical()` (identical files not flagged)
- `testDetectMultipleConflictTypes()` (mixed conflict types)

**Exit Criteria:**
- ✅ Conflicts detected accurately
- ✅ Identical files not flagged as conflicts
- ✅ Tests pass (5 tests)
- ✅ All paths from Difference classified correctly

---

## Step 6: Conflict Resolution (4-5 hours)

**Goal:** Resolve conflicts using strategies

**Deliverables:**
```swift
// Sources/Diffalla/Synchronization/ConflictResolver.swift
class ConflictResolver {
    /// Resolve a conflict using the given strategy
    func resolve(
        conflict: Conflict,
        strategy: ConflictResolution,
        sourceDirectory: URL,
        destinationDirectory: URL
    ) throws -> ResolvedConflict

    private func resolveNewest(
        conflict: Conflict,
        sourceDirectory: URL,
        destinationDirectory: URL
    ) throws -> ResolvedConflict

    private func resolveSourceWins(
        conflict: Conflict
    ) throws -> ResolvedConflict

    private func resolveDestinationWins(
        conflict: Conflict
    ) throws -> ResolvedConflict
}
```

**Resolution Strategies:**
- **newest**: Compare modification dates, use newer file
- **sourceWins**: Always use source version
- **destinationWins**: Always use destination version
- **error**: Throw error (user must resolve manually)

**Tests:**
- `testResolveNewestUsesNewerFile()` (newest strategy)
- `testResolveSourceWins()` (source wins strategy)
- `testResolveDestinationWins()` (destination wins strategy)
- `testResolveErrorThrows()` (error strategy throws)
- `testResolveModifiedVsDeleted()` (deletion conflicts)

**Exit Criteria:**
- ✅ All strategies work correctly
- ✅ Resolution decisions correct
- ✅ Tests pass (5 tests)
- ✅ Error strategy throws

---

## Step 7: Bidirectional Sync (4-5 hours)

**Goal:** High-level bidirectional sync API

**Deliverables:**
```swift
// Update Synchronizer with bidirectional sync
extension Synchronizer {
    /// Sync A and B to make them identical
    public func syncBidirectional(
        a: URL,
        b: URL,
        conflictResolution: ConflictResolution = .newest,
        options: SyncOptions = SyncOptions(),
        progress: ((SyncProgress) -> Void)? = nil
    ) async throws -> SyncResult
}
```

**Implementation:**
1. Create snapshots of A and B
2. Compare snapshots (A vs B)
3. Detect conflicts
4. Resolve conflicts using strategy
5. Plan sync operations (copy in both directions)
6. Execute operations
7. Optionally verify both folders identical
8. Return SyncResult with conflict resolutions

**Tests:**
- `testSyncBidirectionalNoConflicts()` (simple two-way sync)
- `testSyncBidirectionalWithConflicts()` (conflict resolution)
- `testSyncBidirectionalNewestStrategy()` (newest wins)
- `testSyncBidirectionalSourceWinsStrategy()` (source wins)
- `testSyncBidirectionalBothIdenticalAfter()` (verification)
- `testSyncBidirectionalDryRun()` (no actual changes)

**Exit Criteria:**
- ✅ Bidirectional sync works end-to-end
- ✅ Conflicts resolved correctly
- ✅ Tests pass (6 tests)
- ✅ Both folders identical after sync

---

## Step 8: Safety Checks & Pre-flight (3-4 hours)

**Goal:** Pre-sync validation and safety checks

**Deliverables:**
```swift
// Sources/Diffalla/Synchronization/SyncValidator.swift
class SyncValidator {
    /// Validate sync is safe to perform
    func validateSync(
        source: URL,
        destination: URL,
        operations: [SyncOperation]
    ) throws

    /// Estimate disk space required
    func estimateSpaceRequired(
        operations: [SyncOperation]
    ) -> Int64

    /// Check if destination has enough space
    func hasEnoughSpace(
        at url: URL,
        requiredBytes: Int64
    ) throws -> Bool
}
```

**Validation Checks:**
- Source directory exists and is readable
- Destination directory exists and is writable
- Sufficient disk space for operations
- Warn if destination will lose data (deleted files)

**Tests:**
- `testValidateSourceExists()` (source must exist)
- `testValidateDestinationWritable()` (destination writable)
- `testValidateEnoughSpace()` (space check)
- `testEstimateSpaceRequired()` (space calculation)
- `testValidateFailsOnMissingSource()` (error on missing source)

**Exit Criteria:**
- ✅ Pre-flight checks work
- ✅ Space estimation accurate
- ✅ Tests pass (5 tests)
- ✅ Errors thrown for invalid state

---

## Step 9: Integration Tests (3 hours)

**Goal:** End-to-end synchronization workflows

**Deliverables:**
```swift
// Tests/DiffallaTests/SynchronizationIntegrationTests.swift
class SynchronizationIntegrationTests: XCTestCase {
    func testFullUnidirectionalSyncWorkflow()
    func testFullBidirectionalSyncWorkflow()
    func testSyncWithLargeDirectories()
    func testSyncWithConflictResolution()
    func testSyncProgressReporting()
    func testSyncDryRunDoesNotModify()
}
```

**Test scenarios:**
1. Create directories → unidirectional sync → verify destination matches
2. Create directories → bidirectional sync → verify both identical
3. Sync 1,000+ files and measure performance
4. Create conflicts → sync with resolution → verify resolved correctly
5. Sync with progress callback → verify all progress reported
6. Dry run → verify no files actually changed

**Exit Criteria:**
- ✅ All integration tests pass
- ✅ Real-world scenarios work
- ✅ Performance acceptable (1,000 files <10s)

---

## Step 10: Error Handling & Edge Cases (2-3 hours)

**Goal:** Robust error handling for sync operations

**Deliverables:**
```swift
// Add to DiffallaError
enum DiffallaError: Error {
    case syncFailed(reason: String)
    case conflictDetected(conflicts: [Conflict])
    case insufficientSpace(required: Int64, available: Int64)
    case syncCancelled
    // ... existing errors
}
```

**Tests:**
- `testSyncToReadOnlyDestination()` (permission error)
- `testSyncWithInsufficientSpace()` (disk space error)
- `testSyncWithMissingSource()` (source doesn't exist)
- `testSyncConflictWithErrorStrategy()` (error on conflict)
- `testSyncPartialFailure()` (continue on non-critical errors)

**Exit Criteria:**
- ✅ Errors handled gracefully
- ✅ Clear error messages
- ✅ Tests pass (5 tests)
- ✅ Partial sync supported

---

## Progress Tracking

Use checkboxes to track progress:

- [x] Step 0: Extend Difference API (1-2 hours)
- [ ] Step 1: Sync Core Types (2-3 hours)
- [ ] Step 2: Sync Plan & Operations (3-4 hours)
- [ ] Step 3: Sync Executor (4-5 hours)
- [ ] Step 4: Unidirectional Sync (3-4 hours)
- [ ] Step 5: Conflict Detection (3-4 hours)
- [ ] Step 6: Conflict Resolution (4-5 hours)
- [ ] Step 7: Bidirectional Sync (4-5 hours)
- [ ] Step 8: Safety Checks & Pre-flight (3-4 hours)
- [ ] Step 9: Integration Tests (3 hours)
- [ ] Step 10: Error Handling & Edge Cases (2-3 hours)

**Estimated Total:** 32-45 hours (4-6 days of focused work)

---

## Phase 3 Exit Criteria

Once all steps complete, verify:

✅ **Tests Pass:**
- Unidirectional sync works correctly
- Bidirectional sync with conflict resolution works
- All conflict strategies implemented
- Test coverage ≥80% for Synchronization module

✅ **Performance Verified:**
- Sync 10,000 files: <30s
- Progress reporting: <10ms overhead per file
- Memory usage: <20 MB for 10,000 files

✅ **API Validated:**
- Example code works: Unidirectional sync
- Example code works: Bidirectional sync with conflicts
- Dry run mode works correctly
- Progress callbacks work

✅ **Features Complete:**
- Unidirectional sync (source → destination)
- Bidirectional sync (A ↔ B)
- Conflict detection and resolution
- Progress reporting
- Safety checks and validation
- Error handling

---

## Deferred to Phase 4 (Optimization)

The following features are intentionally deferred:

- **Move detection:** Detect renamed/moved files (treat as delete+add for now)
- **Parallel operations:** Concurrent file copies (sequential for now)
- **Incremental sync:** Resume interrupted sync (full sync for now)
- **Filters:** Include/exclude patterns (sync everything for now)
- **Manual conflict resolution:** Callback-based resolution (strategies only for now)
- **Keep both strategy:** Save conflicting files with different names (error for now)

**Rationale:** Phase 3 focuses on core sync functionality. Optimizations and advanced features come in Phase 4.

---

## Open Questions (Resolve Before Starting)

1. **Atomic sync:** Should sync be all-or-nothing? → **Decision: No, continue on errors**
2. **Dry run default:** Should dry run be default? → **Decision: No, default to actual sync**
3. **Metadata sync:** Preserve all metadata? → **Decision: Yes, preserve mod time and permissions**
4. **Empty directories:** Sync empty directories? → **Decision: Yes, create/delete directories**
5. **Symlinks:** How to handle in sync? → **Decision: Follow symlinks by default (use Phase 1 setting)**

---

**Next:** Start with Step 1 - Sync Core Types
