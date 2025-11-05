# Phase 1 Implementation Breakdown

**Goal:** Working snapshot and comparison
**Duration:** 2-3 weeks (broken into 10 incremental steps)

---

## Overview

Phase 1 delivers the foundation: Create snapshots of directories, store in SQLite, and compare them.

**Architecture:**
```
Directory → Scan → Snapshot (SQLite) → Compare → Difference
```

**Breakdown Strategy:**
- Small, testable increments
- Each step builds on previous
- Test as we go
- Can pause/resume at any step

---

## Step 1: Core Types & Metadata (2-3 hours)

**Goal:** Define the basic type system

**Deliverables:**
```swift
// Sources/Diffalla/Core/Metadata.swift
struct Metadata: Equatable, Codable {
    let modificationDate: Date
    let size: Int64
    let permissions: FilePermissions
    let owner: String?        // nil unless captureOwnership
    let group: String?        // nil unless captureOwnership
}

struct FilePermissions: Equatable, Codable {
    let posix: UInt16         // 0o755
    let symbolic: String      // "rwxr-xr-x"
}

// Sources/Diffalla/Core/ItemProtocol.swift
protocol ItemProtocol: Equatable {
    var path: String { get }
    var isFolder: Bool { get }
    var sha256: String? { get }
    var size: Int64 { get }
    var metadata: Metadata { get }
}
```

**Tests:**
- `testMetadataEquality()`
- `testFilePermissionsConversion()` (755 → rwxr-xr-x)
- `testMetadataCodable()` (JSON encode/decode)

**Exit Criteria:**
- ✅ Types compile
- ✅ Tests pass (3 tests)
- ✅ No warnings

---

## Step 2: FileSystemItem Implementation (3-4 hours)

**Goal:** Read file metadata from disk

**Deliverables:**
```swift
// Sources/Diffalla/Core/FileSystemItem.swift
struct FileSystemItem: ItemProtocol {
    let path: String
    let isFolder: Bool
    let sha256: String?
    let size: Int64
    let metadata: Metadata

    // Create from file path
    init(path: String, relativeTo baseURL: URL, options: ScanOptions) throws

    // Compute SHA-256 hash
    private func computeHash(at url: URL) throws -> String
}

// Sources/Diffalla/Core/ScanOptions.swift
struct ScanOptions {
    var followSymlinks: Bool = true
    var includeHidden: Bool = true
    var captureOwnership: Bool = false
}
```

**Tests:**
- `testReadRegularFile()` (create temp file, read metadata)
- `testReadDirectory()` (create temp dir, verify isFolder)
- `testComputeSHA256()` (hash known content, verify result)
- `testSymlinkHandling()` (follow vs store as-is)
- `testHiddenFileDetection()` (file starting with ".")
- `testOwnershipCapture()` (with/without captureOwnership flag)

**Exit Criteria:**
- ✅ Can read file metadata from disk
- ✅ SHA-256 hashing works correctly
- ✅ Tests pass (6 tests)
- ✅ No crashes on permission denied

---

## Step 3: Snapshot SQLite Schema (2 hours)

**Goal:** Define database schema and create/open databases

**Deliverables:**
```swift
// Sources/Diffalla/Snapshots/SnapshotSchema.swift
enum SnapshotSchema {
    static let version = 1

    static func createTables(in db: SQLiteDatabase) throws {
        // schema_version table
        // metadata table
        // items table with indexes
    }
}

// Sources/Diffalla/Snapshots/Snapshot.swift (partial)
public struct Snapshot {
    let databaseURL: URL
    let rootPath: String
    let createdDate: Date
    let metadata: SnapshotMetadata

    static func create(at url: URL, rootPath: String) throws -> Snapshot
    static func open(at url: URL) throws -> Snapshot
}

struct SnapshotMetadata: Codable {
    let totalFiles: Int
    let totalFolders: Int
    let totalSize: Int64
    let version: Int
}
```

**SQL Schema:**
```sql
CREATE TABLE schema_version (
    version INTEGER PRIMARY KEY,
    created_date TEXT NOT NULL,
    library_version TEXT NOT NULL
);

CREATE TABLE metadata (
    root_path TEXT PRIMARY KEY,
    created_date TEXT NOT NULL,
    total_files INTEGER NOT NULL,
    total_folders INTEGER NOT NULL,
    total_size INTEGER NOT NULL
);

CREATE TABLE items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    parent_id INTEGER REFERENCES items(id),
    path TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    is_folder INTEGER NOT NULL,
    size INTEGER NOT NULL,
    modification_date TEXT NOT NULL,
    permissions TEXT NOT NULL,
    owner TEXT,
    group_name TEXT,
    sha256 TEXT
);

CREATE INDEX idx_items_path ON items(path);
CREATE INDEX idx_items_parent ON items(parent_id);
CREATE INDEX idx_items_sha256 ON items(sha256);
```

**Tests:**
- `testCreateEmptySnapshot()` (create database, verify tables exist)
- `testOpenExistingSnapshot()` (open, verify metadata)
- `testSchemaVersion()` (verify version = 1)

**Exit Criteria:**
- ✅ Can create SQLite database with schema
- ✅ Can open existing database
- ✅ Tests pass (3 tests)
- ✅ SQLite queries work (manual verification)

---

## Step 4: Directory Scanning (4-5 hours)

**Goal:** Recursively scan directory and collect items

**Deliverables:**
```swift
// Sources/Diffalla/Snapshots/SnapshotEngine.swift
class SnapshotEngine {
    func scanDirectory(
        at url: URL,
        options: ScanOptions,
        progress: ((SnapshotProgress) -> Void)?
    ) async throws -> [FileSystemItem]

    private func shouldInclude(_ url: URL, options: ScanOptions) -> Bool
    private func handleSymlink(_ url: URL, options: ScanOptions) throws -> URL?
    private func detectCircularSymlink(_ url: URL, visited: Set<URL>) -> Bool
}

struct SnapshotProgress {
    var currentPath: String
    var filesProcessed: Int
    var bytesProcessed: Int64
}
```

**Tests:**
- `testScanEmptyDirectory()` (empty dir → empty array)
- `testScanSingleFile()` (1 file → 1 item)
- `testScanNestedDirectories()` (dir/subdir/file.txt)
- `testScanWithHiddenFiles()` (include/exclude hidden)
- `testScanFollowSymlink()` (symlink to file)
- `testScanStoreSymlink()` (store symlink as-is)
- `testScanCircularSymlink()` (detect and break cycle)
- `testScanBrokenSymlink()` (handle gracefully)
- `testScanProgressCallback()` (verify progress updates)

**Exit Criteria:**
- ✅ Recursively scans directories
- ✅ Respects ScanOptions (hidden, symlinks)
- ✅ Handles edge cases (symlinks, permissions)
- ✅ Tests pass (9 tests)
- ✅ No infinite loops on circular symlinks

---

## Step 5: Insert Items into SQLite (3-4 hours)

**Goal:** Stream items to database during scan

**Deliverables:**
```swift
// Sources/Diffalla/Snapshots/SnapshotWriter.swift
class SnapshotWriter {
    private let db: SQLiteDatabase
    private var itemIdMap: [String: Int64] = [:] // path → id

    func insertItem(_ item: FileSystemItem, parentPath: String?) throws -> Int64
    func updateMetadata(_ metadata: SnapshotMetadata) throws

    private func getParentId(for path: String) -> Int64?
}

// Update SnapshotEngine
extension SnapshotEngine {
    func createSnapshot(
        from directory: URL,
        saveTo snapshotURL: URL,
        options: ScanOptions,
        progress: ((SnapshotProgress) -> Void)?
    ) async throws -> Snapshot
}
```

**Implementation notes:**
- Build parent_id relationships as we scan
- Use transaction for bulk inserts
- Track totalFiles, totalFolders, totalSize during scan

**Tests:**
- `testInsertSingleItem()` (insert, verify in DB)
- `testInsertWithParentRelationship()` (dir → file, verify parent_id)
- `testInsertMultipleItems()` (transaction, verify all inserted)
- `testInsertUpdateMetadata()` (verify totals)
- `testCreateSnapshotIntegration()` (end-to-end: dir → snapshot)

**Exit Criteria:**
- ✅ Can insert items into database
- ✅ Parent-child relationships correct
- ✅ Metadata totals accurate
- ✅ Tests pass (5 tests)
- ✅ Database integrity maintained

---

## Step 6: Snapshot Loading & Querying (3 hours)

**Goal:** Load snapshot from database and query items

**Deliverables:**
```swift
// Sources/Diffalla/Snapshots/SnapshotReader.swift
class SnapshotReader {
    private let db: SQLiteDatabase

    func loadMetadata() throws -> SnapshotMetadata
    func loadAllItems() throws -> [SnapshotItem]
    func loadItem(path: String) throws -> SnapshotItem?
    func loadChildren(of parentId: Int64) throws -> [SnapshotItem]
}

struct SnapshotItem: Codable, Equatable {
    let id: Int64
    let parentId: Int64?
    let path: String
    let name: String
    let isFolder: Bool
    let size: Int64
    let modificationDate: Date
    let permissions: String
    let owner: String?
    let group: String?
    let sha256: String?
}

// Complete Snapshot API
extension Snapshot {
    func loadMetadata() throws -> SnapshotMetadata
    func loadAllItems() throws -> [SnapshotItem]
    func loadItem(path: String) throws -> SnapshotItem?
}
```

**Tests:**
- `testLoadMetadata()` (verify totals)
- `testLoadAllItems()` (verify count, content)
- `testLoadSpecificItem()` (query by path)
- `testLoadChildren()` (query by parent_id)
- `testLoadNonexistentItem()` (returns nil)

**Exit Criteria:**
- ✅ Can load snapshot from database
- ✅ Query operations work correctly
- ✅ Tests pass (5 tests)
- ✅ SQL queries are efficient (use indexes)

---

## Step 7: Comparison Engine - Basic (4-5 hours)

**Goal:** Compare two snapshots and identify differences

**Deliverables:**
```swift
// Sources/Diffalla/Comparison/Difference.swift
public struct Difference {
    let sourceSnapshot: Snapshot
    let destinationSnapshot: Snapshot

    private var cachedAdded: [SnapshotItem]?
    private var cachedRemoved: [SnapshotItem]?
    private var cachedModified: [SnapshotItem]?

    // Factory method
    static func compare(
        source: Snapshot,
        destination: Snapshot
    ) throws -> Difference

    // Lazy properties
    var added: [SnapshotItem] { get throws }
    var removed: [SnapshotItem] { get throws }
    var modified: [SnapshotItem] { get throws }
}

// Sources/Diffalla/Comparison/ComparisonEngine.swift
class ComparisonEngine {
    func findAdded(source: Snapshot, destination: Snapshot) throws -> [SnapshotItem]
    func findRemoved(source: Snapshot, destination: Snapshot) throws -> [SnapshotItem]
    func findModified(source: Snapshot, destination: Snapshot) throws -> [SnapshotItem]
}
```

**SQL Queries:**
```sql
-- Added (in destination, not in source)
SELECT d.* FROM destination.items d
LEFT JOIN source.items s ON d.path = s.path
WHERE s.path IS NULL

-- Removed (in source, not in destination)
SELECT s.* FROM source.items s
LEFT JOIN destination.items d ON s.path = d.path
WHERE d.path IS NULL

-- Modified (in both, but different)
SELECT d.* FROM destination.items d
INNER JOIN source.items s ON d.path = s.path
WHERE d.sha256 != s.sha256
   OR d.size != s.size
   OR d.modification_date != s.modification_date
   OR d.permissions != s.permissions
```

**Tests:**
- `testCompareIdenticalSnapshots()` (no differences)
- `testCompareWithAddedFiles()` (detect added)
- `testCompareWithRemovedFiles()` (detect removed)
- `testCompareWithModifiedFiles()` (detect modified content)
- `testCompareWithModifiedMetadata()` (detect permission change)
- `testCompareLazyCaching()` (verify cache works)

**Exit Criteria:**
- ✅ Can compare two snapshots
- ✅ SQL queries use ATTACH DATABASE
- ✅ Lazy evaluation works
- ✅ Tests pass (6 tests)
- ✅ Performance: <1s for 10k files

---

## Step 8: Integration Tests (3 hours)

**Goal:** End-to-end tests with real file system

**Deliverables:**
```swift
// Tests/DiffallaTests/IntegrationTests.swift
class IntegrationTests: XCTestCase {
    func testCreateSnapshotAndCompare()
    func testModifyFilesAndDetect()
    func testAddRemoveFilesAndDetect()
    func testLargeDirectory() // 1,000 files
    func testSymlinkScenarios()
    func testPermissionChanges()
}
```

**Test scenarios:**
1. Create directory A with files → snapshot
2. Modify files → new snapshot → compare (detect modified)
3. Add/remove files → new snapshot → compare (detect added/removed)
4. 1,000 files → snapshot → verify performance
5. Symlinks → snapshot with follow/no-follow → verify
6. chmod files → snapshot → compare → detect permission change

**Exit Criteria:**
- ✅ All integration tests pass
- ✅ Performance targets met (1k files <5s)
- ✅ Real-world scenarios work

---

## Step 9: Error Handling & Edge Cases (2-3 hours)

**Goal:** Robust error handling

**Deliverables:**
```swift
// Sources/Diffalla/Core/DiffallaError.swift
enum DiffallaError: Error, CustomStringConvertible {
    case fileNotFound(path: String)
    case permissionDenied(path: String)
    case hashComputationFailed(path: String, underlying: Error)
    case snapshotCreationFailed(reason: String)
    case snapshotLoadFailed(reason: String)
    case comparisonFailed(reason: String)
    case invalidSnapshot(reason: String)
}
```

**Tests:**
- `testPermissionDenied()` (try to read protected file)
- `testFileDeletedDuringScan()` (file disappears mid-scan)
- `testInvalidSnapshotFile()` (corrupt database)
- `testDiskFull()` (simulate disk full during write)
- `testConcurrentAccess()` (multiple readers)

**Exit Criteria:**
- ✅ Errors propagate correctly
- ✅ No crashes on edge cases
- ✅ Clear error messages
- ✅ Tests pass (5 tests)

---

## Step 10: Documentation & Polish (2-3 hours)

**Goal:** Complete API documentation and examples

**Deliverables:**
1. **API Documentation:**
   - Add doc comments to all public APIs
   - Usage examples in comments

2. **README for Core:**
   - `Sources/Diffalla/Core/README.md`
   - `Sources/Diffalla/Snapshots/README.md`
   - `Sources/Diffalla/Comparison/README.md`

3. **Example code:**
   ```swift
   // Example: Create and compare snapshots
   let options = ScanOptions(
       followSymlinks: true,
       includeHidden: true,
       captureOwnership: false
   )

   let snap1 = try await SnapshotEngine().createSnapshot(
       from: dirURL,
       saveTo: URL(fileURLWithPath: "snap1.sqlite"),
       options: options
   )

   // Later...
   let snap2 = try await SnapshotEngine().createSnapshot(
       from: dirURL,
       saveTo: URL(fileURLWithPath: "snap2.sqlite"),
       options: options
   )

   let diff = try Difference.compare(source: snap1, destination: snap2)
   print("Added: \(diff.added.count)")
   print("Removed: \(diff.removed.count)")
   print("Modified: \(diff.modified.count)")
   ```

4. **Performance verification:**
   - Run benchmark with 10,000 files
   - Verify <30s snapshot creation on HDD
   - Verify <1s comparison

**Exit Criteria:**
- ✅ All public APIs documented
- ✅ Examples work correctly
- ✅ Performance targets met
- ✅ No warnings

---

## Progress Tracking

Use checkboxes to track progress:

- [ ] Step 1: Core Types & Metadata (2-3 hours)
- [ ] Step 2: FileSystemItem Implementation (3-4 hours)
- [ ] Step 3: Snapshot SQLite Schema (2 hours)
- [ ] Step 4: Directory Scanning (4-5 hours)
- [ ] Step 5: Insert Items into SQLite (3-4 hours)
- [ ] Step 6: Snapshot Loading & Querying (3 hours)
- [ ] Step 7: Comparison Engine (4-5 hours)
- [ ] Step 8: Integration Tests (3 hours)
- [ ] Step 9: Error Handling & Edge Cases (2-3 hours)
- [ ] Step 10: Documentation & Polish (2-3 hours)

**Estimated Total:** 28-37 hours (3-5 days of focused work)

---

## Phase 1 Exit Criteria

Once all steps complete, verify:

✅ **Tests Pass:**
- SnapshotTests.testCreateSnapshot() - Creates 1,000 file snapshot in <5s
- SnapshotTests.testLoadSnapshot() - Loads snapshot in <1s
- ComparisonTests.testBasicDifference() - Compares two snapshots in <1s
- Test coverage: ≥80% for Core, Snapshots, Comparison modules

✅ **Performance Verified:**
- Snapshot creation: 10,000 files in <30s (baseline HDD)
- Memory usage: <10 MB for 10,000 file snapshot
- Database size: <5 MB for 10,000 file snapshot

✅ **API Validated:**
- Example code works: Create snapshot → Load → Compare
- No critical bugs blocking Phase 2

✅ **Open Questions Resolved:**
- All 3 critical Phase 1 questions resolved ✅ (already done)

---

**Next:** Start with Step 1 - Core Types & Metadata
