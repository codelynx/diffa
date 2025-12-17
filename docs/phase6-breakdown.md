-# Phase 6 Implementation Breakdown: Efficient Directory Sync

**Goal:** Implement efficient content-addressable sync with daemon + client architecture
**Duration:** 2-3 weeks (14 incremental steps)
**Status:** Ready to Start
**Reference:** `docs/efficient-directory-sync-proposal.md`

---

## Overview

Phase 6 implements a new approach to directory synchronization focused on efficient network transfer using content-addressable storage (MD5+size), daemon/client architecture, and intelligent move detection.

**Key Differences from Phase 1-5:**
- MD5 hashing (vs SHA-256) for performance
- Content-addressable deduplication
- Daemon + client model (Phase 1 = local sync only)
- ContentTracker for zero-copy optimization
- Deterministic move detection

**Architecture:**
```
Directory → Scan → Snapshot (SQLite with MD5) → Compare → Sync (with deduplication)
                                                         ↓
                                                  ContentTracker
                                                  (zero-copy optimization)
```

---

## Foundation Steps (1-5): Design Before Code

### Step 1: Module Organization (30 min)

**Goal:** Establish directory structure for Phase 6 code

**Action:**
```bash
mkdir -p Sources/Diffa/EfficientSync/Core
mkdir -p Sources/Diffa/EfficientSync/Snapshots
mkdir -p Sources/Diffa/EfficientSync/Comparison
```

**Deliverables:**
- `Sources/Diffa/EfficientSync/Core/README.md`
- `Sources/Diffa/EfficientSync/Snapshots/README.md`
- `Sources/Diffa/EfficientSync/Comparison/README.md`

**Tests:** None (structure only)

**Exit Criteria:**
- ✅ Directories created
- ✅ README stubs in place

---

### Step 2: Core Types (2-3 hours)

**Goal:** Define protocols and data structures

**Deliverables:**

```swift
// Sources/Diffa/EfficientSync/Core/FileItem.swift
public struct FileItem: Equatable, Codable {
    public let path: String
    public let size: Int64
    public let hash: Data      // MD5 (16 bytes)
    public let mtime: Int64    // Unix timestamp (seconds)
    public let mode: UInt16?   // POSIX permissions (optional)
}

// Sources/Diffa/EfficientSync/Core/Snapshot.swift
public protocol Snapshot {
    /// Query file by path
    func fileByPath(_ path: String) -> FileItem?

    /// Query files by hash (for move detection and deduplication)
    func filesByHash(_ hash: Data) -> [FileItem]

    /// Get all files (sorted by path for determinism)
    func allFiles() -> [FileItem]
}

// Sources/Diffa/EfficientSync/Core/SyncMode.swift
public enum SyncMode {
    case push   // Dest mirrors source (dest-only files deleted)
    case pull   // Source mirrors dest (source-only files deleted)
    case sync   // Merge both (no deletions, newer wins on conflicts)
}

// Sources/Diffa/EfficientSync/Core/FileOperation.swift
public struct FileOperation {
    public enum Action {
        case add
        case modify
        case delete
        case move(from: String)  // Stores old path for moves
        case conflict  // For --conflict=ask in sync mode (see local/remote fields)
    }

    public let action: Action
    public let path: String

    // Complete information for both sides (one may be nil for non-conflicts)
    public let localFile: FileItem?   // Destination/client version (nil for add)
    public let remoteFile: FileItem?  // Source/server version (nil for delete)

    // Convenience accessors
    public var hash: Data {
        remoteFile?.hash ?? localFile?.hash ?? Data()
    }
    public var size: Int64 {
        remoteFile?.size ?? localFile?.size ?? 0
    }
}
```

**Tests:**
```swift
func testFileItemEquality()
func testFileItemCodable()
func testFileOperationMoveAction()
func testFileOperationConflictAction()
func testFileOperationLocalRemoteFields()  // Verify both sides stored correctly
func testFileOperationConvenienceAccessors()  // Test hash/size accessors
func testSyncModeDescription()
```

**Exit Criteria:**
- ✅ All types compile
- ✅ Tests pass (7 tests)
- ✅ No warnings
- ✅ Conflict operations store complete file info for both sides

---

### Step 3: Move Detection Strategy (1-2 hours)

**Goal:** Document and implement deterministic pairing algorithm

**Deliverables:**

```swift
// Sources/Diffa/EfficientSync/Comparison/MoveDetector.swift
/// Detects file moves using deterministic hash-based pairing
///
/// Algorithm:
/// 1. Group files by hash on both sides
/// 2. For each hash with equal counts: sort by path and pair 1:1
/// 3. Unmatched files become add/delete operations
///
/// Example:
///   Source: [album1/photo.jpg, album2/photo.jpg] (hash: aaa)
///   Dest:   [old/img1.jpg, old/img2.jpg] (hash: aaa)
///
///   Result (deterministic):
///     old/img1.jpg → album1/photo.jpg (move)
///     old/img2.jpg → album2/photo.jpg (move)
///
public struct MoveDetector {
    /// Detect moves in operations list (modifies in place)
    public func detectMoves(
        source: Snapshot,
        dest: Snapshot,
        operations: inout [FileOperation]
    )
}
```

**Implementation:** See detailed algorithm in proposal (lines 301-350)

**Tests:**
```swift
func testSimpleRename()
func testMultipleFilesWithSameHash()
func testNonMatchingCountsStayAsAddDelete()
func testDeterminism() // Run 10 times, verify same result
```

**Exit Criteria:**
- ✅ Algorithm documented
- ✅ Implementation correct
- ✅ Tests pass (4 tests)
- ✅ Deterministic behavior verified

---

### Step 4: ContentTracker Design (3-4 hours)

**Goal:** Implement safe, deterministic content tracking for deduplication

**Deliverables:**

```swift
// Sources/Diffa/EfficientSync/Core/ContentTracker.swift
/// Tracks content presence in destination for zero-copy deduplication
///
/// Safety features:
/// - Seeds from destination snapshot (existing content)
/// - Filters implicit deletions (mode-aware)
/// - Filters move source paths (old paths unavailable)
/// - Normalizes paths (prevents directory traversal)
/// - Deterministic seeding (sorted iteration)
///
public final class ContentTracker {
    private var hashToCanonicalPath: [Data: URL] = [:]
    private let destRoot: URL  // Normalized, symlinks resolved

    /// Initialize tracker with safe, deterministic seeding
    public init(
        sourceSnapshot: Snapshot,
        destSnapshot: Snapshot,
        destRoot: URL,
        operations: [FileOperation],
        mode: SyncMode
    )

    /// Record newly written content (takes precedence)
    public func recordWrittenContent(hash: Data, at url: URL)

    /// Get canonical path for hash (for deduplication)
    public func canonicalPath(for hash: Data) -> URL?

    /// Internal: Collect paths that will be removed
    private func collectRemovedPaths(
        operations: [FileOperation],
        sourceSnapshot: Snapshot,
        destSnapshot: Snapshot,
        mode: SyncMode
    ) -> Set<String>
}
```

**Implementation:** See detailed design in proposal (lines 920-1050)

**Tests:**
```swift
func testSeedFromDestSnapshot()
func testPushModeFiltersImplicitDeletions()
func testSyncModeNoImplicitDeletions()
func testMoveSourcePathNotAvailable()
func testPathNormalizationSecurity()
func testDeterministicSeeding()
func testRecordWrittenContentTakesPrecedence()
```

**Exit Criteria:**
- ✅ All safety features implemented
- ✅ Tests pass (7 tests)
- ✅ Security verified (path traversal blocked)
- ✅ Determinism verified

---

### Step 5: Benchmark Generator (1 hour)

**Goal:** Create dataset generation script (gitignored)

**Deliverables:**

```bash
# Tests/Fixtures/generate_benchmarks.sh
#!/bin/bash
set -e

OUTPUT_DIR="${1:-/tmp/diffa-benchmarks}"
mkdir -p "$OUTPUT_DIR"

# Small: 1,000 files (~5 MB)
echo "Generating small dataset..."
mkdir -p "$OUTPUT_DIR/small"
for i in $(seq 1 1000); do
    dd if=/dev/urandom of="$OUTPUT_DIR/small/file_$i.bin" bs=5120 count=1 2>/dev/null
done

# Medium: 10,000 files (~300 MB)
echo "Generating medium dataset..."
mkdir -p "$OUTPUT_DIR/medium"
for i in $(seq 1 10000); do
    dd if=/dev/urandom of="$OUTPUT_DIR/medium/file_$i.bin" bs=30720 count=1 2>/dev/null
done

echo "Datasets generated at $OUTPUT_DIR"
echo "Total: $(du -sh $OUTPUT_DIR)"
```

**Add to .gitignore:**
```
/tmp/diffa-benchmarks/
Tests/Fixtures/Benchmarks/
```

**Tests:**
```bash
./Tests/Fixtures/generate_benchmarks.sh
test -d /tmp/diffa-benchmarks/small
test $(ls /tmp/diffa-benchmarks/small | wc -l) -eq 1000
```

**Exit Criteria:**
- ✅ Script executes successfully
- ✅ Datasets created with correct counts
- ✅ Datasets gitignored

---

## Implementation Steps (6-13): Test Each Piece

### Step 6: Snapshot SQLite Schema (2 hours)

**Goal:** Design schema with hash index for efficient lookups

**Deliverables:**

```swift
// Sources/Diffa/EfficientSync/Snapshots/SnapshotSchema.swift
public enum SnapshotSchema {
    public static let version = 1

    public static func createTables(in db: SQLiteDatabase) throws {
        // Files table with hash index
        try db.execute("""
            CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY NOT NULL,
                size INTEGER NOT NULL,
                hash BLOB NOT NULL,
                mtime INTEGER NOT NULL,
                mode INTEGER
            );
        """)

        // Hash index for move detection and deduplication
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_hash ON files(hash);
        """)

        // Metadata table
        try db.execute("""
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT
            );
        """)
    }
}
```

**Tests:**
```swift
func testCreateSchema()
func testHashIndexExists()
func testInsertAndQueryByPath()
func testInsertAndQueryByHash()
```

**Exit Criteria:**
- ✅ Schema creates successfully
- ✅ Indexes verified
- ✅ Tests pass (4 tests)
- ✅ Query performance acceptable

---

### Step 7: File System Scanner (3-4 hours)

**Goal:** Traverse directory, gather metadata (streaming, no accumulation)

**Deliverables:**

```swift
// Sources/Diffa/EfficientSync/Snapshots/FileSystemScanner.swift
public struct FileSystemScanner {
    /// Scan directory and invoke callback for each file (streaming, memory efficient)
    public func scan(
        root: URL,
        onFile: (URL, FileMetadata) throws -> Void
    ) throws {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
                .posixPermissionsKey
            ]
        )

        while let url = enumerator?.nextObject() as? URL {
            // Skip directories
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }

            let attrs = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
                .posixPermissionsKey
            ])

            let relativePath = url.path.replacingOccurrences(
                of: root.path + "/",
                with: ""
            )

            let metadata = FileMetadata(
                path: relativePath,
                size: Int64(attrs.fileSize ?? 0),
                mtime: Int64(attrs.contentModificationDate?.timeIntervalSince1970 ?? 0),
                mode: attrs.posixPermissions.map { UInt16($0) }
            )

            // Invoke callback immediately (don't accumulate)
            try onFile(url, metadata)
        }
    }
}

public struct FileMetadata {
    public let path: String
    public let size: Int64
    public let mtime: Int64
    public let mode: UInt16?
}
```

**Tests:**
```swift
func testScanEmptyDirectory()
func testScanSingleFile()
func testScanNestedDirectories()
func testScanExcludesDirectories()
func testScanStreamingCallback() // Verify no accumulation
func testScanCapturesMetadata()
```

**Note:** Scanner uses callback pattern for memory efficiency. Production code in `Snapshot.create()` can inline this for simplicity, but scanner is useful for testing.

**Exit Criteria:**
- ✅ Scans directories recursively
- ✅ Captures metadata correctly
- ✅ Streaming (no accumulation in memory)
- ✅ Tests pass (6 tests)
- ✅ Performance acceptable (1k files <1s)

---

### Step 8: MD5 Hasher (2 hours)

**Goal:** Hash file content efficiently using streaming

**Deliverables:**

```swift
// Sources/Diffa/EfficientSync/Snapshots/FileHasher.swift
import CryptoKit

public struct FileHasher {
    /// Hash file content using MD5 (streaming for large files)
    public func hash(fileAt url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = Insecure.MD5()

        // Stream in 64KB chunks (memory efficient)
        let bufferSize = 64 * 1024
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: bufferSize)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) { }

        return Data(hasher.finalize())
    }
}
```

**Tests:**
```swift
func testHashKnownFile() // Verify against known MD5
func testHashEmptyFile()
func testHashLargeFile() // 100MB file, verify streaming works
func testHashErrorHandling() // Permission denied
```

**Exit Criteria:**
- ✅ MD5 hashing works correctly
- ✅ Streaming works (low memory for large files)
- ✅ Tests pass (4 tests)
- ✅ Performance acceptable

---

### Step 9: Snapshot.create() (3-4 hours)

**Goal:** Combine scanner + hasher + SQLite storage

**Deliverables:**

```swift
// Sources/Diffa/EfficientSync/Snapshots/SQLiteSnapshot.swift
public final class SQLiteSnapshot: Snapshot {
    private let database: SQLiteDatabase
    private let rootPath: String

    /// Create snapshot from directory (streaming for memory efficiency)
    public static func create(at root: URL) throws -> SQLiteSnapshot {
        // 1. Create temp database
        let dbPath = NSTemporaryDirectory() + UUID().uuidString + ".db"
        let db = try SQLiteDatabase(path: dbPath)

        // 2. Initialize schema
        try SnapshotSchema.createTables(in: db)

        // 3. Stream: scan one file → hash → insert → repeat
        //    Memory stays bounded (no full tree in RAM)
        let hasher = FileHasher()

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
                .posixPermissionsKey
            ]
        )

        while let url = enumerator?.nextObject() as? URL {
            // Skip directories
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }

            // Get metadata
            let attrs = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
                .posixPermissionsKey
            ])

            let relativePath = url.path.replacingOccurrences(
                of: root.path + "/",
                with: ""
            )

            // Hash immediately (while file is in context)
            let hash = try hasher.hash(fileAt: url)

            // Insert immediately (don't accumulate in memory)
            try db.execute(
                "INSERT INTO files (path, size, hash, mtime, mode) VALUES (?, ?, ?, ?, ?)",
                relativePath,
                Int64(attrs.fileSize ?? 0),
                hash,
                Int64(attrs.contentModificationDate?.timeIntervalSince1970 ?? 0),
                attrs.posixPermissions.map { UInt16($0) }
            )
        }

        // 4. Store metadata
        try db.execute(
            "INSERT INTO metadata (key, value) VALUES ('root_path', ?)",
            root.path
        )

        return SQLiteSnapshot(database: db, rootPath: root.path)
    }

    public func fileByPath(_ path: String) -> FileItem? {
        // Query implementation
    }

    public func filesByHash(_ hash: Data) -> [FileItem] {
        // Query implementation using hash index
    }

    public func allFiles() -> [FileItem] {
        // Return all files (sorted by path for determinism)
    }
}
```

**Tests:**
```swift
func testCreateSnapshotOfTestDirectory()
func testQueryFileByPath()
func testQueryFilesByHash()
func testAllFilesSortedByPath() // Verify determinism
func testEmptyDirectory()
func testPerformance1000Files()
```

**Exit Criteria:**
- ✅ Creates snapshots successfully
- ✅ All query methods work
- ✅ Tests pass (6 tests)
- ✅ Performance: 1k files in <10s

---

### Step 10: Basic Comparison (3-4 hours)

**Goal:** Identify added/deleted/modified (NO moves yet)

**Deliverables:**

```swift
// Sources/Diffa/EfficientSync/Comparison/SnapshotComparator.swift
public struct SnapshotComparator {
    public func compare(
        source: Snapshot,
        dest: Snapshot,
        mode: SyncMode
    ) -> [FileOperation] {
        var operations: [FileOperation] = []

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

        // Modified/Conflict: in both, different hash
        for (path, sourceFile) in sourceFiles {
            if let destFile = destFiles[path],
               sourceFile.hash != destFile.hash {

                // In sync mode, emit conflict action (executor decides resolution)
                if mode == .sync {
                    operations.append(FileOperation(
                        action: .conflict,
                        path: path,
                        localFile: destFile,    // Complete local file info
                        remoteFile: sourceFile  // Complete remote file info
                    ))
                } else {
                    // Push/Pull: unconditional overwrite (modify)
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
            // Delete dest-only files (dest mirrors source)
            for (path, destFile) in destFiles {
                if sourceFiles[path] == nil {
                    operations.append(FileOperation(
                        action: .delete,
                        path: path,
                        localFile: destFile,  // File being deleted
                        remoteFile: nil       // Doesn't exist on remote
                    ))
                }
            }

        case .pull:
            // Pull mode: Client (dest) mirrors Server (source)
            //
            // This loop deletes client-only files. Server-only files are
            // handled by the "add" logic above (lines 622-631).
            //
            // Example:
            //   Server: [A, B, C]
            //   Client: [B, D]
            //   Operations:
            //     - Add A (server-only → added to client)
            //     - Delete D (client-only → removed)
            //   Result: Client = [A, B, C] (matches server)
            //
            for (path, destFile) in destFiles {
                if sourceFiles[path] == nil {
                    operations.append(FileOperation(
                        action: .delete,
                        path: path,
                        localFile: destFile,  // Client file being deleted
                        remoteFile: nil       // Doesn't exist on server
                    ))
                }
            }

        case .sync:
            // No deletions in sync mode (merge both)
            break
        }

        return operations
    }
}
```

**Tests:**
```swift
func testCompareIdenticalSnapshots()
func testDetectAddedFiles()
func testDetectDeletedFiles()
func testDetectModifiedFiles()
func testPushModeDeletions()
func testPullModeDeletions()  // Verify pull deletes client-only files
func testPullAddsServerFiles()  // Verify server-only files added to client
func testSyncModeNoDeletions()
func testSyncModeGeneratesConflicts()  // Verify conflict action generated with both file versions
```

**Exit Criteria:**
- ✅ Basic comparison works
- ✅ Mode affects deletions correctly (push/pull/sync)
- ✅ Pull mode correctly mirrors server (adds server files, deletes client-only)
- ✅ Sync mode generates conflict actions with complete file info
- ✅ All operations store localFile/remoteFile appropriately
- ✅ Tests pass (9 tests)

---

### Step 11: Move Detection (2-3 hours)

**Goal:** Implement deterministic pairing (Step 3 algorithm)

**Implementation:** Apply MoveDetector to operations list

**Tests:**
```swift
func testDetectSimpleRename()
func testDetectMultipleMovesWithSameHash()
func testDeterministicPairing()
func testNonMatchingCountsStayAsAddDelete()
```

**Exit Criteria:**
- ✅ Move detection works
- ✅ Deterministic behavior verified
- ✅ Tests pass (4 tests)

---

### Step 12: ContentTracker Implementation (3-4 hours)

**Goal:** Implement Step 4 design with all safety features

**Implementation:** Full ContentTracker as designed

**Tests:** (From Step 4)
- All 7 tests from Step 4 specification

**Exit Criteria:**
- ✅ All safety features work
- ✅ Tests pass (7 tests)

---

### Step 13: Sync Execution (4-5 hours)

**Goal:** Apply operations to target directory with ContentTracker

**Deliverables:**

```swift
// Sources/Diffa/EfficientSync/Comparison/SyncExecutor.swift
public struct SyncExecutor {
    public func execute(
        operations: [FileOperation],
        sourceRoot: URL,
        destRoot: URL,
        sourceSnapshot: Snapshot,
        destSnapshot: Snapshot,
        mode: SyncMode
    ) throws {
        let tracker = ContentTracker(
            sourceSnapshot: sourceSnapshot,
            destSnapshot: destSnapshot,
            destRoot: destRoot,
            operations: operations,
            mode: mode
        )

        for operation in operations {
            switch operation.action {
            case .add:
                try applyAdd(operation, sourceRoot, destRoot, tracker)
            case .modify:
                try applyModify(operation, sourceRoot, destRoot, tracker)
            case .delete:
                try applyDelete(operation, destRoot)
            case .move(let oldPath):
                try applyMove(operation, oldPath: oldPath, destRoot: destRoot)
            case .conflict:
                try applyConflict(operation, sourceRoot, destRoot, tracker)
            }
        }
    }

    private func applyAdd(/* ... */) throws { }
    private func applyModify(/* ... */) throws { }
    private func applyDelete(/* ... */) throws { }
    private func applyMove(/* ... */) throws { }

    private func applyConflict(
        _ operation: FileOperation,
        _ sourceRoot: URL,
        _ destRoot: URL,
        _ tracker: ContentTracker
    ) throws {
        guard let localFile = operation.localFile,
              let remoteFile = operation.remoteFile else {
            throw Error.invalidConflictOperation
        }

        // Resolve based on strategy (would come from config/flags):
        let resolution: ConflictResolution = .newer  // Default

        let chosenFile: FileItem
        switch resolution {
        case .newer:
            // Compare mtimes, keep newer
            chosenFile = localFile.mtime > remoteFile.mtime ? localFile : remoteFile

        case .ask:
            // Pause for user input (CLI integration)
            chosenFile = try askUser(local: localFile, remote: remoteFile)

        case .keepBoth:
            // Keep both with hash suffix
            try writeBothVersions(local: localFile, remote: remoteFile, at: destRoot, tracker: tracker)
            return
        }

        // Write chosen version
        try writeFile(chosenFile, at: destRoot, tracker: tracker)
    }
}
}
```

**Tests:**
```swift
func testFullWorkflowScanCompareExecute()
func testDeduplicationMultipleFilesWithSameHash()
func testMovesNoContentTransfer()
func testMetadataPreserved()
func testAllOperationTypes()
func testConflictResolutionNewerWins() // Verify conflict handling
```

**Exit Criteria:**
- ✅ Full sync workflow works
- ✅ Deduplication verified
- ✅ Move optimization verified
- ✅ Conflict resolution works
- ✅ Tests pass (6 tests)

---

## Validation Step (14): Benchmark

### Step 14: Benchmark Harness (2-3 hours)

**Goal:** Verify Phase 6 exit criteria

**Deliverables:**

```bash
# Tests/benchmark_phase6.sh
#!/bin/bash
set -e

echo "Generating benchmark dataset..."
./Tests/Fixtures/generate_benchmarks.sh /tmp/diffa-benchmarks

echo "Building release..."
swift build -c release

echo ""
echo "=== Benchmark: 10k files snapshot creation ==="
/usr/bin/time -l swift test --filter testSnapshot10kFiles

echo ""
echo "=== Benchmark: 10k files comparison ==="
/usr/bin/time -l swift test --filter testCompare10kFiles

echo ""
echo "=== Benchmark: Full sync with deduplication ==="
/usr/bin/time -l swift test --filter testSync10kFilesWithDuplicates

echo ""
echo "=== Exit Criteria Check ==="
echo "  ✓ Time: Should be <1 minute for 10k files"
echo "  ✓ Memory: Should be <10 MB RSS"
echo "  ✓ Deduplication: Verify zero-copy for duplicates"
```

**Tests:**
```swift
func testSnapshot10kFiles()
func testCompare10kFiles()
func testSync10kFilesWithDuplicates()
func testMoveDetection10kFiles()
```

**Exit Criteria:**
- ✅ 10k files snapshot in <60s
- ✅ Memory usage <10 MB RSS
- ✅ Comparison <1s
- ✅ Deduplication verified (zero-copy)
- ✅ Move detection verified (zero-transfer)

---

## Progress Tracking

Use checkboxes to track progress:

- [ ] Step 1: Module Organization (30 min)
- [ ] Step 2: Core Types (2-3 hours)
- [ ] Step 3: Move Detection Strategy (1-2 hours)
- [ ] Step 4: ContentTracker Design (3-4 hours)
- [ ] Step 5: Benchmark Generator (1 hour)
- [ ] Step 6: Snapshot SQLite Schema (2 hours)
- [ ] Step 7: File System Scanner (3-4 hours)
- [ ] Step 8: MD5 Hasher (2 hours)
- [ ] Step 9: Snapshot.create() (3-4 hours)
- [ ] Step 10: Basic Comparison (3-4 hours)
- [ ] Step 11: Move Detection (2-3 hours)
- [ ] Step 12: ContentTracker Implementation (3-4 hours)
- [ ] Step 13: Sync Execution (4-5 hours)
- [ ] Step 14: Benchmark Harness (2-3 hours)

**Estimated Total:** 30-40 hours (4-5 days of focused work)

---

## Phase 6 Exit Criteria

✅ **All Tests Pass:**
- Unit tests: ≥80% coverage
- Integration tests: Full workflows
- Security tests: Path traversal blocked
- Performance tests: Meet benchmarks

✅ **Performance Verified:**
- Snapshot creation: 10k files in <60s (HDD)
- Memory usage: <10 MB for 10k files
- Comparison: <1s
- Deduplication: Zero-copy verified
- Move detection: Zero-transfer verified

✅ **Safety Verified:**
- ContentTracker security (path normalization)
- Deterministic behavior (move detection, seeding)
- Mode-aware deletions (push/pull/sync)

✅ **API Complete:**
- All public APIs documented
- Example code works
- Ready for Phase 7 (Network Protocol + Daemon)

---

## Comparison: Phase 6 vs Phase 1-5

| Aspect | Phase 1-5 | Phase 6 |
|--------|-----------|---------|
| Hash Algorithm | SHA-256 | MD5 |
| Architecture | ItemProtocol | Content-addressable |
| Storage | SQLite (hierarchical) | SQLite (flat with hash index) |
| Deduplication | None | ContentTracker (zero-copy) |
| Move Detection | None | Deterministic pairing |
| Sync Modes | Mirror only | Push/Pull/Sync |
| Use Case | Snapshot comparison | Efficient network sync |

---

## Next Steps

1. **Start with Step 1** (Module Organization)
2. **Follow incremental approach** (test each step before moving on)
3. **After Phase 6 complete** → Begin Phase 7 (Network Protocol + Daemon)
4. **Reference existing Phase 1-5** for SQLite wrapper usage patterns

---

**Ready to begin!** Start with Step 1: Module Organization.
