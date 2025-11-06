# Phase 2 Implementation Breakdown

**Goal:** Working patch creation, apply, and revert system
**Duration:** 2-3 weeks (broken into 8-10 incremental steps)

---

## Overview

Phase 2 delivers patching functionality: Create patches that describe transformations, apply them to directories, and revert changes.

**Architecture:**
```
Difference → Patch Creation → Patch (SQLite) → Apply/Revert → Directory
```

**Breakdown Strategy:**
- Small, testable increments
- Each step builds on previous
- Test as we go
- Can pause/resume at any step

---

## Step 1: Patch Operations & Metadata (2-3 hours)

**Goal:** Define core patch types and operations

**Deliverables:**
```swift
// Sources/Diffa/Patching/PatchOperation.swift
enum PatchOperation: Codable, Equatable {
    case add(path: String, isFolder: Bool)
    case remove(path: String, isFolder: Bool)
    case modify(path: String)
    case move(from: String, to: String, isFolder: Bool)
}

// Sources/Diffa/Patching/PatchMetadata.swift
struct PatchMetadata: Codable, Equatable {
    let version: Int                    // Patch format version
    let createdDate: Date              // When patch was created
    let sourceChecksum: String?        // Optional verification
    let targetChecksum: String?        // Optional verification
    let operationCount: Int            // Number of operations
}
```

**Tests:**
- `testPatchOperationCodable()` (JSON encode/decode)
- `testPatchOperationEquality()` (equality checks)
- `testPatchMetadataCreation()` (metadata initialization)

**Exit Criteria:**
- ✅ Types compile
- ✅ Tests pass (3 tests)
- ✅ No warnings

---

## Step 2: Patch SQLite Schema (2-3 hours)

**Goal:** Define database schema for storing patches

**Deliverables:**
```swift
// Sources/Diffa/Patching/PatchSchema.swift
enum PatchSchema {
    static let version = 1

    static func createTables(in db: SQLiteDatabase) throws {
        // schema_version table
        // metadata table
        // operations table (ordered sequence)
        // revert_data table (optional)
    }
}
```

**SQL Schema:**
```sql
CREATE TABLE schema_version (
    version INTEGER PRIMARY KEY,
    created_date INTEGER NOT NULL,
    library_version TEXT NOT NULL
);

CREATE TABLE metadata (
    id INTEGER PRIMARY KEY,
    version INTEGER NOT NULL,
    created_date INTEGER NOT NULL,
    source_checksum TEXT,
    target_checksum TEXT,
    operation_count INTEGER NOT NULL
);

CREATE TABLE operations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sequence_order INTEGER NOT NULL,
    type TEXT NOT NULL,  -- 'add', 'remove', 'modify', 'move'
    path TEXT NOT NULL,
    path_to TEXT,        -- For move operations
    is_folder INTEGER NOT NULL,
    content_blob BLOB,   -- File content for add/modify
    metadata_json TEXT   -- File metadata (permissions, dates, etc.)
);

CREATE INDEX idx_operations_sequence ON operations(sequence_order);

CREATE TABLE revert_data (
    path TEXT PRIMARY KEY,
    original_content_blob BLOB,
    original_metadata_json TEXT,
    cache_reference TEXT  -- UUID for large files in cache
);
```

**Tests:**
- `testCreateEmptyPatch()` (create database, verify tables)
- `testSchemaVersion()` (verify version = 1)
- `testTablesExist()` (verify all tables created)

**Exit Criteria:**
- ✅ Can create SQLite database with patch schema
- ✅ Tests pass (3 tests)
- ✅ All tables and indexes created

---

## Step 3: Basic Patch Creation (3-4 hours)

**Goal:** Create patches from Difference objects (without revert data)

**Deliverables:**
```swift
// Sources/Diffa/Patching/Patch.swift
public struct Patch {
    let databaseURL: URL
    let metadata: PatchMetadata

    internal let database: SQLiteDatabase

    static func create(
        from difference: Difference,
        sourceDirectory: URL,      // NEW: Need source for revert data (Step 6)
        destinationDirectory: URL,  // NEW: Need destination for file content (Step 4)
        saveTo patchURL: URL,
        includeRevertData: Bool = false
    ) throws -> Patch

    static func open(at url: URL) throws -> Patch

    func loadOperations() throws -> [PatchOperation]
}

// Sources/Diffa/Patching/PatchWriter.swift
class PatchWriter {
    func writeOperation(_ operation: PatchOperation, metadata: Metadata) throws
    func writeMetadata(_ metadata: PatchMetadata) throws
}
```

**Implementation:**
- Convert `difference.added` → `add` operations (capture metadata from SnapshotItem)
- Convert `difference.removed` → `remove` operations (capture metadata from SnapshotItem)
- Convert `difference.modified` → `modify` operations (capture metadata from SnapshotItem)
- Store operations in sequence order with metadata_json
- Store patch metadata
- Note: Content storage deferred to Step 4 (need destination directory access)

**Tests:**
- `testCreatePatchFromEmptyDiff()` (no changes → empty patch)
- `testCreatePatchWithAdded()` (added files → add operations)
- `testCreatePatchWithRemoved()` (removed files → remove operations)
- `testCreatePatchWithModified()` (modified files → modify operations)
- `testCreatePatchWithMixed()` (all operation types)
- `testLoadOperations()` (read operations back)

**Exit Criteria:**
- ✅ Can create patches from Difference
- ✅ Operations stored in database
- ✅ Tests pass (6 tests)
- ✅ Patch can be opened and queried

---

## Step 4: Content Storage in Patches (3-4 hours)

**Goal:** Store file content in patch operations

**Deliverables:**
```swift
// Update PatchWriter to store content
class PatchWriter {
    func writeOperation(_ operation: PatchOperation, metadata: Metadata, content: Data?) throws
}

// Sources/Diffa/Patching/PatchReader.swift
class PatchReader {
    func loadOperations() throws -> [(PatchOperation, Metadata, Data?)]
    func loadContent(for path: String) throws -> Data?
}
```

**Implementation:**
- For `add` operations: Read file content from destinationDirectory (passed in Step 3)
- For `modify` operations: Read new file content from destinationDirectory (passed in Step 3)
- Store content as BLOB in operations table
- Efficient reading/writing of large files
- Metadata already captured in Step 3, now add content

**Tests:**
- `testStoreSmallFileContent()` (< 1 KB file)
- `testStoreLargeFileContent()` (> 1 MB file)
- `testStoreBinaryContent()` (binary file, not text)
- `testLoadContent()` (retrieve stored content)
- `testContentRoundTrip()` (write + read = same content)

**Exit Criteria:**
- ✅ File content stored in patches
- ✅ Content can be retrieved
- ✅ Tests pass (5 tests)
- ✅ Large files handled efficiently

---

## Step 5: Apply Patch Operation (4-5 hours)

**Goal:** Apply patches to transform directories

**Deliverables:**
```swift
// Update Patch with apply functionality
extension Patch {
    func apply(to targetDirectory: URL) async throws
}

// Sources/Diffa/Patching/PatchApplicator.swift
class PatchApplicator {
    func applyAdd(path: String, content: Data, metadata: Metadata, to: URL) throws
    func applyRemove(path: String, from: URL) throws
    func applyModify(path: String, content: Data, metadata: Metadata, to: URL) throws
    func applyMove(from: String, to: String, in: URL) throws
}
```

**Implementation:**
- Execute operations in sequence order
- For `add`: Create file with content and metadata
- For `remove`: Delete file/folder
- For `modify`: Overwrite file with new content and metadata
- For `move`: Rename/move file/folder
- Handle errors gracefully (rollback on failure)

**Tests:**
- `testApplyAddOperation()` (create new files)
- `testApplyRemoveOperation()` (delete existing files)
- `testApplyModifyOperation()` (overwrite files)
- `testApplyMoveOperation()` (move files)
- `testApplyFullPatch()` (complete transformation)
- `testApplyPreservesMetadata()` (permissions, dates preserved)

**Exit Criteria:**
- ✅ Patches can be applied to directories
- ✅ All operation types work correctly
- ✅ Tests pass (6 tests)
- ✅ Metadata preserved during apply

---

## Step 6: Revert Data Capture (3-4 hours)

**Goal:** Capture original file state for revert

**Deliverables:**
```swift
// Patch.create already has sourceDirectory parameter (added in Step 3)
// Now implement revert data capture when includeRevertData: true

// Sources/Diffa/Patching/RevertDataWriter.swift
class RevertDataWriter {
    func captureOriginalFile(
        path: String,
        from directory: URL,
        inlineThreshold: Int64 = 1_048_576  // 1MB
    ) throws
}
```

**Implementation:**
- For `remove` operations: Capture content before deletion
- For `modify` operations: Capture original content before overwrite
- For `move` operations: Capture source path
- Small files (< 1MB): Store inline in revert_data table
- Large files: Skip for now (external cache in Phase 4)

**Tests:**
- `testCaptureRevertDataForRemoved()` (save removed files)
- `testCaptureRevertDataForModified()` (save original versions)
- `testInlineThreshold()` (small files inline, large files skipped)
- `testRevertDataStored()` (verify data in database)

**Exit Criteria:**
- ✅ Original files captured for revert
- ✅ Small files stored inline
- ✅ Tests pass (4 tests)
- ✅ Revert data retrievable

---

## Step 7: Revert Patch Operation (3-4 hours)

**Goal:** Revert applied patches to restore original state

**Deliverables:**
```swift
// Update Patch with revert functionality
extension Patch {
    func revert(on targetDirectory: URL) async throws
}

// Sources/Diffa/Patching/PatchReverter.swift
class PatchReverter {
    func revertAdd(path: String, from: URL) throws
    func revertRemove(path: String, content: Data, metadata: Metadata, to: URL) throws
    func revertModify(path: String, originalContent: Data, metadata: Metadata, to: URL) throws
    func revertMove(from: String, to: String, in: URL) throws
}
```

**Implementation:**
- Execute operations in REVERSE sequence order
- For `add` operations: Delete added files
- For `remove` operations: Restore original content from revert_data
- For `modify` operations: Restore original content from revert_data
- For `move` operations: Move back to original location

**Tests:**
- `testRevertAddOperation()` (delete added files)
- `testRevertRemoveOperation()` (restore deleted files)
- `testRevertModifyOperation()` (restore original content)
- `testRevertMoveOperation()` (move back)
- `testApplyAndRevert()` (full round-trip)
- `testRevertRestoresMetadata()` (permissions, dates restored)

**Exit Criteria:**
- ✅ Patches can be reverted
- ✅ Original state restored
- ✅ Tests pass (6 tests)
- ✅ Round-trip apply/revert works

---

## Step 8: Patch Export Functions (3-4 hours)

**Goal:** Export patches in human-readable formats

**Deliverables:**
```swift
// Update Patch with export functions
extension Patch {
    func exportAsText() throws -> String
    func exportAsJSON() throws -> String
    func exportAsHTML() throws -> String
    func exportAsDetailedDiff() throws -> String
}
```

**Export Formats:**

1. **Text (diff-style):**
```
+ path/to/added.txt
- path/to/removed.txt
M path/to/modified.txt
```

2. **JSON:**
```json
{
  "version": 1,
  "created": "2025-01-15T10:30:00Z",
  "operations": [
    {"type": "add", "path": "file.txt"},
    {"type": "remove", "path": "old.txt"}
  ]
}
```

3. **HTML:**
Interactive browser view with syntax highlighting

4. **Detailed Diff:**
Git-style diff with content changes (requires revert data)
- **Note:** Only available for patches created with `includeRevertData: true`
- Shows before/after content for modified files
- Shows removed file content
- Throws error if revert data not available

**Tests:**
- `testExportAsText()` (verify text format)
- `testExportAsJSON()` (verify JSON structure)
- `testExportAsHTML()` (verify HTML structure)
- `testExportAsDetailedDiff()` (verify diff format with revert data)
- `testExportAsDetailedDiffWithoutRevertData()` (verify error thrown)

**Exit Criteria:**
- ✅ All export formats work
- ✅ Output is human-readable
- ✅ Detailed diff requires revert data (documented + tested)
- ✅ Tests pass (5 tests)

---

## Step 9: Integration Tests (3 hours)

**Goal:** End-to-end patching workflows

**Deliverables:**
```swift
// Tests/DiffaTests/PatchingIntegrationTests.swift
class PatchingIntegrationTests: XCTestCase {
    func testFullPatchWorkflow()
    func testApplyAndRevertRoundTrip()
    func testPatchWithLargeFiles()
    func testPatchSerialization()
    func testMultiplePatchesSequentially()
}
```

**Test scenarios:**
1. Create two directories → snapshot → compare → create patch → apply → verify
2. Create patch → apply → revert → verify original state restored
3. Patch with 1,000+ files
4. Save patch to disk → load patch → apply
5. Create multiple patches and apply in sequence

**Exit Criteria:**
- ✅ All integration tests pass
- ✅ Real-world scenarios work
- ✅ Performance acceptable (1,000 files <10s)

---

## Step 10: Error Handling & Edge Cases (2-3 hours)

**Goal:** Robust error handling for patching

**Deliverables:**
```swift
// Sources/Diffa/Patching/PatchError.swift
enum PatchError: Error, CustomStringConvertible {
    case invalidPatch(reason: String)
    case applyFailed(operation: PatchOperation, reason: String)
    case revertFailed(operation: PatchOperation, reason: String)
    case missingRevertData(path: String)
    case targetNotEmpty(path: String)
    case checksumMismatch(expected: String, actual: String)
}
```

**Tests:**
- `testApplyToNonEmptyDirectory()` (conflict detection)
- `testRevertWithoutRevertData()` (error handling)
- `testApplyWithMissingContent()` (corrupt patch)
- `testApplyPartialFailure()` (rollback on error)
- `testChecksumVerification()` (validate target state)

**Exit Criteria:**
- ✅ Errors handled gracefully
- ✅ Clear error messages
- ✅ Tests pass (5 tests)
- ✅ Rollback on failure

---

## Progress Tracking

Use checkboxes to track progress:

- [x] Step 1: Patch Operations & Metadata (2-3 hours)
- [x] Step 2: Patch SQLite Schema (2-3 hours)
- [x] Step 3: Basic Patch Creation (3-4 hours)
- [x] Step 4: Content Storage in Patches (3-4 hours)
- [x] Step 5: Apply Patch Operation (4-5 hours)
- [x] Step 6: Revert Data Capture (3-4 hours)
- [x] Step 7: Revert Patch Operation (3-4 hours)
- [x] Step 8: Patch Export Functions (3-4 hours)
- [x] Step 9: Integration Tests (3 hours)
- [x] Step 10: Error Handling & Edge Cases (2-3 hours)

**Estimated Total:** 27-37 hours (3-5 days of focused work)

---

## Phase 2 Exit Criteria

Once all steps complete, verify:

✅ **Tests Pass:**
- Patch creation from Difference works
- Apply transforms directories correctly
- Revert restores original state
- Test coverage ≥80% for Patching module

✅ **Performance Verified:**
- Create patch from 10,000 file diff: <5s
- Apply patch with 10,000 operations: <30s
- Patch database size: <2x source size for small files

✅ **API Validated:**
- Example code works: Create → Save → Load → Apply → Revert
- All export formats produce correct output
- No critical bugs blocking Phase 3

✅ **Features Complete:**
- Patch creation with/without revert data
- Apply and revert operations
- All export formats (text, JSON, HTML, diff)
- Error handling and rollback

---

## Deferred to Phase 4 (Optimization)

The following features are intentionally deferred:

- **Large file caching:** External cache directory for files >1MB (inline only for now)
- **Move detection:** Matching hashes to detect renames (treat as remove+add for now)
- **Parallel apply:** Concurrent file operations (sequential for now)
- **Compression:** Compress content blobs (uncompressed for now)
- **Incremental apply:** Resume partial patch application (atomic only for now)

**Rationale:** Phase 2 focuses on core patching functionality. Optimizations come in Phase 4 after synchronization (Phase 3) is complete.

---

**Next:** Start with Step 1 - Patch Operations & Metadata
