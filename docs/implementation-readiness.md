# Implementation Readiness Review

This document summarizes the design phase completion and readiness for implementation.

## Overview

Diffalla is a Swift library for file system comparison, patching, and synchronization on Apple platforms.

**Status:** Design phase complete, ready for implementation.

## Design Documentation Complete

### Core Documentation ✅

All core design documents have been created and reviewed:

1. **[DESIGN.md](/DESIGN.md)** - High-level design and API surface
2. **[README.md](/README.md)** - Project objectives and scope
3. **[architecture.md](architecture.md)** - Core types and system architecture
4. **[snapshots.md](snapshots.md)** - Snapshot feature specification
5. **[comparison.md](comparison.md)** - Comparison operation specification
6. **[patching.md](patching.md)** - Patching operations specification
7. **[synchronization.md](synchronization.md)** - Sync operations specification
8. **[optimization.md](optimization.md)** - Optimization strategies specification

### Operation Reviews Complete ✅

All core operations have been reviewed in detail with implementation pseudocode:

1. **[operation-review-snapshot.md](operation-review-snapshot.md)**
   - Snapshot creation with SQLite storage
   - Streaming approach for memory efficiency
   - Hierarchical schema design
   - Status: **Ready for implementation**

2. **[operation-review-difference.md](operation-review-difference.md)**
   - Snapshot-based comparison
   - SQL-powered queries using ATTACH DATABASE
   - Lazy evaluation with caching
   - Status: **Ready for implementation**

3. **[operation-review-patching.md](operation-review-patching.md)**
   - Patch creation, apply, and revert
   - Hybrid RevertData storage
   - Serialization strategy
   - Status: **Ready for implementation**

4. **[operation-review-synchronization.md](operation-review-synchronization.md)**
   - Unidirectional and bidirectional sync
   - Conflict detection and resolution
   - Multiple resolution strategies
   - Status: **Ready for implementation**

5. **[operation-review-optimization.md](operation-review-optimization.md)**
   - Move detection (Priority 1)
   - Hash caching (Priority 2)
   - Parallel processing (Priority 1)
   - Block-level delta (Future)
   - Status: **Ready for implementation**

## Key Architectural Decisions

### 1. Snapshot-Based Approach ✅

**Decision:** Use SQLite-based snapshots as foundation for all operations.

**Benefits:**
- Memory efficient: ~200 bytes per Snapshot object in memory
- Reusable: Scan directory once, compare many times
- Queryable: SQL-powered comparisons and queries
- Historical: Compare to old snapshots anytime
- Scalable: Works with millions of files

**Implementation:** SQLite database with hierarchical schema (parent_id relationships)

### 2. Lazy Evaluation ✅

**Decision:** Compute differences on-demand, cache when needed.

**Benefits:**
- Don't compute what's not needed
- Lower memory usage
- Faster when only partial results needed

**Implementation:** Difference object (~400 bytes) references two snapshots; queries execute on property access

### 3. Hybrid Storage for Revert ✅

**Decision:** Store small files inline, large files in cache directory.

**Benefits:**
- Patches stay manageable size
- No size limit for large files
- Easy to transmit patches

**Implementation:**
- Inline: Files < 1 MB stored in patch JSON/binary
- Cache: Files ≥ 1 MB stored separately with UUID reference
- Configurable threshold and cache location

### 4. Move Detection ✅

**Decision:** Detect file moves by matching hashes to avoid copy+delete.

**Benefits:**
- 100x+ faster for large moved files
- Reduced disk I/O
- Lower bandwidth usage

**Implementation:** Group removed/added items by hash, match to detect moves

### 5. Conflict Resolution Strategies ✅

**Decision:** Support multiple strategies for bidirectional sync.

**Strategies:**
- `.newest` - Use most recent modification date
- `.sourceWins` - A always wins
- `.destinationWins` - B always wins
- `.keepBoth` - Keep both with renamed paths
- `.manual(resolver)` - Ask user for each conflict
- `.error` - Fail on any conflict

**Implementation:** Strategy pattern with configurable resolver

## Performance Targets

### Memory Usage

| Operation | Target | Actual (Design) |
|-----------|--------|-----------------|
| Snapshot object | < 500 bytes | ~200 bytes ✅ |
| Difference object | < 500 bytes | ~400 bytes ✅ |
| Snapshot creation (100k files) | < 50 MB | < 30 MB ✅ |
| Comparison (100k files) | < 100 MB | < 50 MB ✅ |
| Sync operation | < 100 MB | < 50 MB ✅ |

### Speed

| Operation | Target | Expected |
|-----------|--------|----------|
| Snapshot creation (100k files) | < 10 min | ~5 min ✅ |
| Comparison (snapshots) | < 5 sec | < 1 sec ✅ |
| Move vs copy+delete (1 GB file) | 100x faster | 100x faster ✅ |
| Second snapshot (cached) | 100x faster | 100x faster ✅ |

## Implementation Priorities

### Phase 1: Foundation (MVP)
**Goal:** Working snapshot and comparison
**Duration:** 2-3 weeks
**Owner:** TBD

#### Deliverables
1. **Core types** (ItemProtocol, Metadata)
2. **Snapshot creation** with SQLite
3. **Snapshot loading** from database
4. **Difference comparison** using SQL
5. **Basic tests** for snapshot and comparison

#### Exit Criteria (Measurable Gates)
✅ **Tests Pass:**
- `SnapshotTests.testCreateSnapshot()` - Creates 1,000 file snapshot in <5s
- `SnapshotTests.testLoadSnapshot()` - Loads snapshot in <1s
- `ComparisonTests.testBasicDifference()` - Compares two snapshots in <1s
- Test coverage: ≥80% for Core, Snapshots, Comparison modules

✅ **Performance Verified:**
- Snapshot creation: 10,000 files in <30s (baseline HDD)
- Memory usage: <10 MB for 10,000 file snapshot
- Database size: <5 MB for 10,000 file snapshot

✅ **API Validated:**
- API review completed (see docs/api-review-phase1.md)
- Example code works: Create snapshot → Load → Compare
- No critical bugs blocking Phase 2

✅ **Open Questions Resolved:** (see Phase 1 Questions section below)
- All 3 critical Phase 1 questions resolved (see checkboxes below)

#### Phase 1 Open Questions to Resolve
**Must resolve before starting Phase 1:**
- [x] open-questions.md:20-33: Symlink handling strategy → **RESOLVED: Follow by default, --no-follow-symlinks to opt-out**
- [x] open-questions.md:34-46: Hidden files inclusion policy → **RESOLVED: Include by default, --no-hidden to exclude**
- [x] open-questions.md:73-85: Metadata comparison level → **RESOLVED: Content + mtime + size + permissions, --with-ownership to add owner/group**

**Decision deadline:** Before Phase 1 kickoff (pre-coding)
**Status:** ✅ RESOLVED - All critical questions answered (2025-11-05)
**Documentation:** See `docs/decisions.md` for full rationale

#### Phase 1 Risks
- SQLite performance on HDD (mitigated by indexing + benchmarking)
- Cross-platform path handling (mitigated by tests on macOS only initially)

### Phase 2: Patching
**Goal:** Create and apply patches
**Duration:** 2-3 weeks
**Owner:** TBD
**Prerequisites:** Phase 1 complete (Snapshot + Difference working)

#### Deliverables
1. **Patch structure** (operations, metadata)
2. **Patch creation** from Difference
3. **RevertData** storage in SQLite
4. **Apply patch** operation
5. **Revert patch** operation
6. **Export functions** (text, JSON, HTML, diff)
7. **Tests** for patching

#### Exit Criteria (Measurable Gates)
✅ **Tests Pass:**
- `PatchTests.testCreatePatch()` - Creates patch from difference
- `PatchTests.testApplyPatch()` - Applies patch to directory
- `PatchTests.testRevertPatch()` - Reverts applied patch
- `PatchTests.testExportFormats()` - All export functions work
- Test coverage: ≥80% for Patching module

✅ **Performance Verified:**
- Patch creation: 1,000 operations in <2s
- Patch apply: 1,000 operations in <10s
- Export HTML: 10,000 operations in <5s
- Database size: ~1KB per operation (content excluded)

✅ **API Validated:**
- Patch lifecycle works: Create → Save → Load → Apply → Revert
- Export functions verified: exportAsText(), exportAsJSON(), exportAsHTML()
- No data loss in revert operation (verified by hash comparison)

✅ **Open Questions Resolved:** (see Phase 2 Questions section below)
- Revert data storage (decision: SQLite with BLOBs)
- Serialization format (decision: SQLite for storage, exports for viewing)
- Schema versioning (decision: see Migration Strategy section)

#### Phase 2 Open Questions to Resolve
**Must resolve during Phase 2:**
- [ ] open-questions.md:89-101: Content storage for patches (decision: full content in SQLite BLOBs)
- [ ] open-questions.md:102-115: Compression strategy (decision: Phase 5 - future work)
- [ ] open-questions.md:184-195: Revert data inclusion (decision: always include by default)

**Should resolve during Phase 2:**
- [ ] open-questions.md:116-129: Checksums for verification (decision: use SQLite integrity)
- [ ] open-questions.md:156-169: Conflict handling on apply (decision: fail-fast with clear error)

**Decision deadline:** Before Phase 2 completion

#### Phase 2 Dependencies
- Depends on: Phase 1 (Snapshot, Difference)
- Blocks: Phase 3 (Sync uses Patch internally)

#### Phase 2 Risks
- Large file handling in SQLite BLOBs (mitigated by testing with 1GB+ files)
- Export HTML memory usage (mitigated by streaming/pagination)

### Phase 3: Synchronization
**Goal:** Folder sync operations
**Duration:** 3-4 weeks
**Owner:** TBD
**Prerequisites:** Phase 1 & 2 complete (uses Snapshot, Difference, Patch)

#### Deliverables
1. **Unidirectional sync** (A → B)
2. **Move detection** optimization
3. **Progress reporting**
4. **Bidirectional sync** (A ↔ B)
5. **Conflict detection**
6. **Conflict resolution** strategies
7. **Tests** for sync operations

#### Exit Criteria (Measurable Gates)
✅ **Tests Pass:**
- `SyncTests.testUnidirectionalSync()` - A→B sync works
- `SyncTests.testBidirectionalSync()` - A↔B sync with conflicts
- `SyncTests.testMoveDetection()` - Moved files detected correctly
- `SyncTests.testConflictResolution()` - All strategies work
- Test coverage: ≥80% for Synchronization module

✅ **Performance Verified:**
- Unidirectional sync: 10,000 files in <2 min
- Move detection: 1,000 moved files detected in <1s
- Bidirectional sync: 10,000 files with 100 conflicts in <3 min
- Progress reporting: Updates ≥1/sec, <1% CPU overhead

✅ **API Validated:**
- All conflict strategies work: newest, sourceWins, destinationWins, keepBoth, manual
- Progress reporting accurate: bytesProcessed matches actual
- Dry-run mode works (preview without changes)

✅ **Open Questions Resolved:** (see Phase 3 Questions section below)
- Metadata preservation (decision: mod time + permissions configurable)
- Change detection (decision: mod time + size, with hash fallback)
- Default conflict resolution (decision: error on conflict for safety)

#### Phase 3 Open Questions to Resolve
**Must resolve during Phase 3:**
- [ ] open-questions.md:238-251: Metadata preservation level
- [ ] open-questions.md:304-317: Change detection strategy
- [ ] open-questions.md:318-331: Default conflict resolution

**Should resolve during Phase 3:**
- [ ] open-questions.md:199-211: Atomic sync (decision: best-effort with rollback log)
- [ ] open-questions.md:225-237: Dry-run mode (decision: include in Phase 3)
- [ ] open-questions.md:252-264: Sparse files handling (decision: Phase 5)

**Can defer to Phase 5:**
- [ ] open-questions.md:212-224: Incremental/resumable sync
- [ ] open-questions.md:265-277: Hard links preservation
- [ ] open-questions.md:278-290: Extended attributes

**Decision deadline:** Before Phase 3 completion

#### Phase 3 Dependencies
- Depends on: Phase 1 (Snapshot, Difference), Phase 2 (Patch)
- Blocks: None (Phase 4 can start in parallel)

#### Phase 3 Risks
- Bidirectional conflict complexity (mitigated by strategy pattern)
- File system race conditions (mitigated by timestamp checks before write)

### Phase 4: Optimization
**Goal:** Performance improvements
**Duration:** 2-3 weeks
**Owner:** TBD
**Prerequisites:** Phase 1 complete (can run parallel to Phase 2/3)

#### Deliverables
1. **Hash caching** for incremental snapshots
2. **Parallel hashing** using TaskGroup
3. **Smart comparison** (early exit)
4. **Benchmarking harness** and datasets
5. **Performance tests** and reports
6. **Optimization documentation**

#### Exit Criteria (Measurable Gates)
✅ **Benchmarks Pass:**
- Snapshot creation: 100k files in <10 min (HDD), <5 min (SSD)
- Second snapshot (cached): 100x faster than first (hash cache working)
- Move detection: 1GB file moved in <1s (vs 60s+ for copy+delete)
- Parallel hashing: 4x speedup on 4-core system
- Memory usage: <50 MB for 100k file snapshot

✅ **Tests Pass:**
- `OptimizationTests.testHashCache()` - Cache hit rate >90% on second run
- `OptimizationTests.testParallelHashing()` - Speedup ≥ cores/2
- `OptimizationTests.testMoveDetection()` - 100% accuracy on test dataset
- Test coverage: ≥80% for Optimization module

✅ **Benchmark Harness:**
- Automated benchmark suite runs on CI
- 3 test datasets validated (see Benchmark Plan below)
- Performance regression detection (<10% variance)
- Reports generated (HTML, JSON)

✅ **Documentation:**
- Performance guide written (docs/performance.md)
- Optimization recommendations documented
- Benchmark results published

✅ **Open Questions Resolved:** (see Phase 4 Questions section below)
- Hash cache persistence location (decision: per-directory .diffalla/cache)
- Parallel operation limits (decision: ProcessInfo.processInfo.activeProcessorCount)
- Cache invalidation strategy (decision: mod time + size + inode)

#### Benchmark Plan (Detailed)

**Hardware Baselines:**
- **Baseline HDD:** 5400 RPM (worst case)
- **Baseline SSD:** SATA SSD (common case)
- **Best Case:** NVMe SSD (best case)

**Test Datasets:**

1. **Small Dataset (1,000 files)**
   - Purpose: Baseline functionality, overhead measurement
   - Structure: 500 source files (10KB each), 500 text files (1KB each)
   - Total size: ~5 MB
   - Acceptance: Snapshot <5s on HDD

2. **Medium Dataset (10,000 files)**
   - Purpose: Typical project (e.g., Node.js project with node_modules)
   - Structure:
     - 5,000 source files (.swift, .js) - avg 50KB
     - 4,000 small files (.json, .md) - avg 10KB
     - 1,000 folders (nested 5 levels deep)
   - Total size: ~300 MB
   - Acceptance: Snapshot <30s on HDD, <10s on SSD

3. **Large Dataset (100,000 files)**
   - Purpose: Stress test, large monorepo simulation
   - Structure:
     - 50,000 source files - avg 100KB
     - 40,000 small files - avg 10KB
     - 10,000 large files (1MB-10MB) - avg 5MB
   - Total size: ~5 GB
   - Acceptance: Snapshot <10 min on HDD, <5 min on SSD
   - Cached snapshot: <1 min on HDD

**Benchmark Metrics:**
- Wall-clock time (total duration)
- CPU time (user + system)
- Memory usage (peak RSS)
- Disk I/O (read/write bytes)
- Cache hit rate (for cached operations)

**Benchmark Automation:**
- Script: `Scripts/benchmark.sh`
- CI integration: Run on every PR (regression detection)
- Output format: JSON + HTML report
- Comparison tool: Compare vs baseline (fail if >10% regression)

**Benchmark Tools:**
```swift
// BenchmarkHarness.swift
struct BenchmarkResult {
    let dataset: String
    let operation: String
    let duration: TimeInterval
    let memoryPeak: Int64
    let diskReadBytes: Int64
    let diskWriteBytes: Int64
}

class BenchmarkHarness {
    func run(dataset: BenchmarkDataset) async throws -> BenchmarkResult
    func compare(current: BenchmarkResult, baseline: BenchmarkResult) -> PerformanceReport
    func exportReport(format: ReportFormat) // HTML, JSON, Markdown
}
```

#### Phase 4 Open Questions to Resolve
**Must resolve before Phase 4:**
- [ ] open-questions.md:348-361: Hash cache persistence location
- [ ] open-questions.md:362-375: Parallel operation limits
- [ ] open-questions.md:404-418: Cache invalidation strategy

**Should resolve during Phase 4:**
- [ ] open-questions.md:334-347: Move detection hash collision handling
- [ ] open-questions.md:419-432: Optimization defaults (profiles)
- [ ] open-questions.md:469-482: Verification levels

**Can defer to Phase 5:**
- [ ] open-questions.md:376-389: Block-level delta sync
- [ ] open-questions.md:390-403: Deduplication strategy
- [ ] open-questions.md:433-450: Platform-specific optimizations

**Decision deadline:** Before Phase 4 kickoff (pre-optimization)

#### Phase 4 Dependencies
- Depends on: Phase 1 (Snapshot implementation needed for benchmarking)
- Blocks: None (can run parallel to Phase 2/3)
- Prerequisite for Phase 1/2/3 optimization: Hash cache design must be ready

#### Phase 4 Risks
- Performance targets too aggressive (mitigated by hardware baseline definition)
- Benchmark dataset generation time (mitigated by pre-generated datasets)
- Cache invalidation bugs (mitigated by paranoid verification mode)

### Phase 5: Polish & CLI Tool (Future)
**Goal:** Production-ready library + command-line tool
**Duration:** 4-6 weeks
**Owner:** TBD
**Prerequisites:** Phase 1-4 complete

#### Deliverables
1. **CLI Tool** (`diffalla` command) for macOS and Linux
   - Complete command-line interface (snapshot, compare, patch, sync, export, verify)
   - Argument parsing with `swift-argument-parser`
   - Progress bars, colored output, exit codes
   - Man pages and installation packages (Homebrew, APT)
   - See `docs/cli-design.md` for full specification
2. **Error handling** improvements
3. **Documentation** (API docs, guides, CLI docs)
4. **Example projects** (GUI app, Swift Package integration example)
5. **Compression** for snapshots/patches (optional)
6. **Platform support** (CLI: macOS + Linux, Library: iOS + macOS + Linux)

#### Exit Criteria (Measurable Gates)
✅ **Production Quality:**
- All modules at ≥90% test coverage
- Zero critical bugs
- API documentation 100% complete
- Performance targets met (see Phase 4)

✅ **Documentation:**
- API reference (100% documented)
- Getting Started guide
- Performance optimization guide
- Migration guide (schema versions)
- 3+ example projects

✅ **CLI Tool:**
- All commands implemented: snapshot, compare, patch, sync, export, verify
- Progress bars and colored output working
- Man pages complete (diffalla.1, diffalla-snapshot.1, etc.)
- Installation: Homebrew formula + binary releases
- Cross-platform: macOS and Linux tested
- Integration tests: All commands tested with various flags

✅ **Example Projects:**
- GUI app: Simple backup utility (macOS)
- Swift Package: Integration example with sample code

✅ **Platform Support:**
- CLI Tool: macOS + Linux ✅
- Library: macOS + iOS + Linux ✅

✅ **Open Questions Resolved:**
- Deferred questions from Phase 1-4
- Advanced features scoped and prioritized

#### Phase 5 Deferred Features
**Can be implemented post-1.0:**
- [ ] Block-level delta sync
- [ ] Incremental/resumable operations
- [ ] Compression (gzip, zstd)
- [ ] Ignore patterns (.diffallaignore)
- [ ] Hard link preservation
- [ ] Extended attributes sync
- [ ] Sparse file optimization
- [ ] Network drive optimization

#### Phase 5 Dependencies
- Depends on: Phase 1-4 complete
- Blocks: 1.0 release

#### Phase 5 Risks
- Feature creep (mitigated by strict scope control)
- Documentation lag (mitigated by writing docs during implementation)

## Migration and Versioning Strategy

### SQLite Schema Versioning

**Problem:** Snapshot and Patch SQLite databases need forward/backward compatibility as the schema evolves.

**Solution:** Schema versioning with migration paths.

#### Version Storage

```sql
-- In every SQLite database
CREATE TABLE schema_version (
    version INTEGER PRIMARY KEY,
    created_date TEXT NOT NULL,
    library_version TEXT NOT NULL  -- e.g., "1.0.0"
);
```

#### Version History

| Schema Version | Library Version | Changes | Migration Path |
|---------------|----------------|---------|----------------|
| 1 | 1.0.0 | Initial schema | N/A |
| 2 | 1.1.0 | Add `extended_attributes` column | Migration 1→2 |
| 3 | 1.2.0 | Add `compression_type` to metadata | Migration 2→3 |

#### Migration Framework

```swift
protocol SchemaMigration {
    var fromVersion: Int { get }
    var toVersion: Int { get }
    func migrate(database: SQLiteDatabase) throws
}

class SchemaManager {
    static let currentVersion: Int = 1  // Increment with each schema change

    static func getCurrentVersion(database: SQLiteDatabase) throws -> Int {
        // Read from schema_version table
    }

    static func migrate(database: SQLiteDatabase, to targetVersion: Int) throws {
        let currentVersion = try getCurrentVersion(database: database)

        guard currentVersion < targetVersion else {
            return  // Already at target version or newer
        }

        // Apply migrations sequentially
        for version in (currentVersion + 1)...targetVersion {
            guard let migration = migrations[version] else {
                throw SchemaError.missingMigration(version: version)
            }

            try migration.migrate(database: database)
            try updateSchemaVersion(database: database, to: version)
        }
    }

    static var migrations: [Int: SchemaMigration] = [
        // Will be populated as schema evolves
        // 2: Migration_1_to_2(),
        // 3: Migration_2_to_3(),
    ]
}
```

#### Migration Example

```swift
// Example: Add extended_attributes column in version 2
struct Migration_1_to_2: SchemaMigration {
    var fromVersion: Int { 1 }
    var toVersion: Int { 2 }

    func migrate(database: SQLiteDatabase) throws {
        // Add new column (backwards compatible)
        try database.execute("""
            ALTER TABLE items
            ADD COLUMN extended_attributes BLOB DEFAULT NULL
        """)

        // Backfill data if needed
        // (for this migration, NULL is fine for existing items)
    }
}
```

#### Compatibility Strategy

**Forward Compatibility (Newer schema → Older library):**
- Older library can read newer databases if schema changes are additive only
- Break compatibility only on major versions (1.x → 2.0)
- Graceful degradation: Ignore unknown columns

**Backward Compatibility (Older schema → Newer library):**
- Always maintained
- Newer library auto-migrates older databases on open
- Migration is transparent to user

#### Version Policy

**Schema version increments:**
- **Patch releases (1.0.0 → 1.0.1):** No schema changes allowed
- **Minor releases (1.0.0 → 1.1.0):** Additive changes only (new columns, new tables)
- **Major releases (1.0.0 → 2.0.0):** Breaking changes allowed (remove columns, change types)

**Migration requirements:**
- All migrations must be idempotent (safe to run multiple times)
- Migrations must be atomic (wrapped in transaction)
- Failed migrations roll back completely

#### Testing Strategy

```swift
class MigrationTests: XCTestCase {
    func testMigration_1_to_2() throws {
        // Create v1 database
        let db = try createV1Database()

        // Apply migration
        try SchemaManager.migrate(database: db, to: 2)

        // Verify schema
        XCTAssertTrue(db.hasColumn("items", "extended_attributes"))

        // Verify data integrity
        let count = try db.query("SELECT COUNT(*) FROM items")
        XCTAssertEqual(count, originalCount)
    }

    func testMigrationChain() throws {
        // Test migrating from v1 → v3 (skipping v2)
        let db = try createV1Database()
        try SchemaManager.migrate(database: db, to: 3)
        // Verify all intermediate migrations applied
    }
}
```

#### Snapshot Schema (Version 1)

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
    sha256 TEXT
);

CREATE INDEX idx_items_parent ON items(parent_id);
CREATE INDEX idx_items_path ON items(path);
CREATE INDEX idx_items_sha256 ON items(sha256);
```

#### Patch Schema (Version 1)

```sql
CREATE TABLE schema_version (
    version INTEGER PRIMARY KEY,
    created_date TEXT NOT NULL,
    library_version TEXT NOT NULL
);

CREATE TABLE metadata (
    version TEXT PRIMARY KEY,
    created_date TEXT NOT NULL,
    source_checksum TEXT,
    target_checksum TEXT
);

CREATE TABLE operations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sequence_order INTEGER NOT NULL,
    type TEXT NOT NULL,  -- add, remove, modify, move
    path TEXT NOT NULL,
    path_to TEXT,  -- for move operations
    content_blob BLOB,
    size INTEGER,
    metadata_json TEXT
);

CREATE TABLE revert_data (
    path TEXT PRIMARY KEY,
    original_content_blob BLOB,
    original_metadata_json TEXT
);

CREATE INDEX idx_operations_sequence ON operations(sequence_order);
```

#### Format Detection

```swift
extension Snapshot {
    static func load(from url: URL) throws -> Snapshot {
        let db = try SQLiteDatabase.open(url)

        // Detect version
        let version = try SchemaManager.getCurrentVersion(database: db)

        // Migrate if needed
        if version < SchemaManager.currentVersion {
            print("Migrating snapshot from v\(version) to v\(SchemaManager.currentVersion)...")
            try SchemaManager.migrate(database: db, to: SchemaManager.currentVersion)
        }

        // Load snapshot
        return try Snapshot(databaseURL: url)
    }
}
```

#### Future-Proofing

**Phase 1 Implementation:**
- Implement schema versioning framework
- Include schema_version table in all databases
- Set version = 1 for initial release

**Future Schema Changes:**
- Document changes in migration guide (docs/migrations.md)
- Implement migration class
- Register in SchemaManager.migrations
- Increment SchemaManager.currentVersion
- Add tests for migration

**Breaking Changes (Rare):**
- Only on major versions
- Provide migration tool: `diffalla-migrate-v1-to-v2`
- Document migration path clearly

## Open Questions

Remaining design decisions documented in [open-questions.md](open-questions.md):

### Critical (Must resolve before implementation)
- ✅ Snapshot storage format (SQLite)
- ✅ Comparison approach (snapshot-based)
- ✅ Revert data storage (hybrid inline/cache)
- ✅ Conflict resolution strategies (multiple)
- ✅ Move detection algorithm (hash-based)

### Important (Should resolve during Phase 1-2)
- Symlink handling strategy
- Hidden files inclusion policy
- Metadata comparison level
- API design (properties vs methods)
- Snapshot lifecycle management

### Nice to have (Can resolve later)
- Ignore patterns (.gitignore-style)
- Incremental/resumable operations
- Compression for patches
- Block-level delta algorithm

## Code Structure

### Module Organization

```
Sources/
└── Diffalla/
    ├── Core/
    │   ├── ItemProtocol.swift
    │   ├── Metadata.swift
    │   └── FileSystemItem.swift
    ├── Snapshots/
    │   ├── Snapshot.swift
    │   ├── SnapshotItem.swift
    │   ├── SnapshotMetadata.swift
    │   ├── SnapshotDifference.swift
    │   └── SnapshotEngine.swift
    ├── Comparison/
    │   ├── Difference.swift
    │   ├── ComparisonProgress.swift
    │   └── ComparisonEngine.swift
    ├── Patching/
    │   ├── Patch.swift
    │   ├── PatchOperation.swift
    │   ├── PatchMetadata.swift
    │   ├── RevertData.swift
    │   └── PatchEngine.swift
    ├── Synchronization/
    │   ├── SyncEngine.swift
    │   ├── SyncProgress.swift
    │   ├── SyncResult.swift
    │   └── ConflictResolution.swift
    ├── Optimization/
    │   ├── MoveDetector.swift
    │   ├── HashCache.swift
    │   └── OptimizationOptions.swift
    └── Utilities/
        ├── HashUtilities.swift
        ├── FileOperations.swift
        └── ErrorTypes.swift

Tests/
└── DiffallaTests/
    ├── SnapshotTests.swift
    ├── ComparisonTests.swift
    ├── PatchingTests.swift
    ├── SynchronizationTests.swift
    ├── OptimizationTests.swift
    └── IntegrationTests.swift
```

## Next Steps (See Revised Next Steps Below)

**⚠️ IMPORTANT:** Do not use this section. See "Next Steps (Revised)" in the Feedback Response Summary section below for the correct gating and sequencing.

This section is preserved for historical context only.

## Design Review Summary

All core operations have been thoroughly reviewed:

- ✅ **Snapshots** - SQLite-based, hierarchical, streaming, memory-efficient
- ✅ **Difference** - Snapshot-based, SQL-powered, lazy evaluation, reusable
- ✅ **Patching** - Reversible, hybrid storage, serializable, verifiable
- ✅ **Synchronization** - Bidirectional/unidirectional, conflict resolution, move detection
- ✅ **Optimization** - Move detection, hash caching, parallel processing

**Design confidence:** HIGH - All operations have clear implementation paths

**Ready for implementation:** YES

**Risk areas:**
- SQLite performance with very large directories (millions of files) - mitigated by indexing
- Conflict resolution complexity in bidirectional sync - mitigated by strategy pattern
- Cross-platform file system differences - initial focus on Apple platforms only

**Recommendation:** Proceed to Phase 1 implementation (Foundation/MVP) **after** resolving Phase 1 critical open questions.

---

## Feedback Response Summary

### Questions Answered

#### Q: Should critical open questions be resolved before Phase 1, or is there appetite to iterate during coding?

**Answer: Resolve critical questions BEFORE Phase 1 coding starts.**

**Rationale:**
- **Phase 1 questions** (symlink handling, hidden files, metadata level) directly impact core API design
- Changing these mid-coding causes expensive rework and API churn
- Team should reach consensus during design phase (1-2 days max)

**Approach:**
1. Schedule design meeting to resolve Phase 1 questions (see Phase 1 Open Questions section)
2. Document decisions in docs/decisions.md
3. Update API specs based on decisions
4. **Then** start Phase 1 coding

**Non-critical questions** (Phase 2-5) can be resolved during coding, but must be resolved by phase completion gate.

#### Q: Do the performance targets reflect actual hardware baselines?

**Answer: Performance targets now tied to explicit hardware baselines.**

**Hardware Baselines Defined:**
- **Baseline HDD:** 5400 RPM (worst case scenario)
- **Baseline SSD:** SATA SSD (common case)
- **Best Case:** NVMe SSD (optimal case)

**Benchmark Datasets Specified:**
- Small: 1,000 files (~5 MB) - Baseline functionality
- Medium: 10,000 files (~300 MB) - Typical project
- Large: 100,000 files (~5 GB) - Stress test

**Acceptance Criteria Updated:**
- Phase 1: 10,000 files in <30s (HDD baseline)
- Phase 4: 100,000 files in <10 min (HDD), <5 min (SSD)
- All targets now hardware-specific (see Phase 4 Benchmark Plan)

**Benchmark Harness Specified:**
- Script: `Scripts/benchmark.sh`
- CI integration: Run on every PR
- Metrics: Wall-clock time, CPU time, memory (RSS), disk I/O
- Reports: JSON + HTML format
- Regression detection: Fail if >10% slower than baseline

### Implementation Plan Improvements

#### 1. Exit Criteria (Measurable Gates) ✅

**Each phase now includes:**
- ✅ **Tests Pass:** Specific test names and thresholds (e.g., "SnapshotTests.testCreateSnapshot() creates 1,000 files in <5s")
- ✅ **Performance Verified:** Hardware-specific targets with acceptance criteria
- ✅ **API Validated:** Concrete validation steps (e.g., "API review completed at docs/api-review-phase1.md")
- ✅ **Open Questions Resolved:** Explicit list with checkboxes and deadlines

**Example (Phase 1):**
```
✅ Tests Pass:
- SnapshotTests.testCreateSnapshot() - Creates 1,000 file snapshot in <5s
- Test coverage: ≥80% for Core, Snapshots, Comparison modules

✅ Performance Verified:
- Snapshot creation: 10,000 files in <30s (baseline HDD)
- Memory usage: <10 MB for 10,000 file snapshot
```

#### 2. Open Questions Scheduled ✅

**All open questions now assigned to phases:**
- **Phase 1:** Symlink handling, hidden files, metadata level (3 questions)
- **Phase 2:** Content storage, revert data, conflict handling (5 questions)
- **Phase 3:** Metadata preservation, change detection, conflict resolution (6 questions)
- **Phase 4:** Hash cache, parallel limits, cache invalidation (6 questions)
- **Phase 5:** Advanced features deferred post-1.0

**Each phase includes:**
- **Must resolve before phase:** Blocks start of coding
- **Must resolve during phase:** Blocks phase completion
- **Should resolve during phase:** Preferably resolved, can defer if needed
- **Can defer to Phase 5:** Future work

#### 3. Benchmarking Plan ✅

**Now includes:**
- ✅ Hardware baselines (HDD, SSD, NVMe)
- ✅ 3 test datasets (1k, 10k, 100k files) with structure specs
- ✅ Benchmark metrics (time, CPU, memory, disk I/O, cache hit rate)
- ✅ Automation plan (Scripts/benchmark.sh, CI integration)
- ✅ Reporting format (JSON + HTML)
- ✅ Regression detection (<10% variance threshold)
- ✅ BenchmarkHarness implementation sketch

**Phase 4 deliverable:** Benchmarking harness is now explicit deliverable with acceptance criteria.

#### 4. Migration/Versioning Strategy ✅

**New section added:** "Migration and Versioning Strategy"

**Includes:**
- ✅ Schema versioning table in all SQLite databases
- ✅ Migration framework (SchemaMigration protocol, SchemaManager)
- ✅ Version policy (patch/minor/major releases)
- ✅ Compatibility strategy (forward/backward)
- ✅ Testing strategy (idempotent, atomic migrations)
- ✅ Initial schemas (Snapshot v1, Patch v1)
- ✅ Migration example code
- ✅ Future-proofing plan

**Phase 1 deliverable:** Schema versioning framework is now implicit in Phase 1 (included in "Snapshot creation with SQLite").

#### 5. Prerequisites and Dependencies ✅

**Each phase now includes:**
- **Prerequisites:** What must be complete before starting (e.g., "Phase 1 complete")
- **Depends on:** Modules/features required (e.g., "Phase 1: Snapshot, Difference")
- **Blocks:** What this phase unblocks (e.g., "Blocks Phase 3: Sync uses Patch internally")
- **Risks:** Specific risks with mitigation strategies

**Dependency Graph:**
```
Phase 1 (Foundation)
  ↓
Phase 2 (Patching) ← depends on Phase 1
  ↓
Phase 3 (Sync) ← depends on Phase 1 + 2
  ↓
Phase 4 (Optimization) ← can run parallel to Phase 2/3
  ↓
Phase 5 (Polish) ← depends on Phase 1-4
```

### Next Steps (Revised)

#### Immediate (Before Phase 1 Starts)
1. **Resolve Phase 1 critical questions** (1-2 days)
   - [ ] Symlink handling: Follow by default, configurable
   - [ ] Hidden files: Include by default, filterable
   - [ ] Metadata level: Minimal (mod time + size + hash)
2. **Hardware baseline validation** (1 day)
   - [ ] Confirm team has access to HDD + SSD test machines
   - [ ] Benchmark simple file operations on baselines
3. **Create benchmark datasets** (1 day)
   - [ ] Generate 1k, 10k, 100k file datasets
   - [ ] Store in `Tests/Fixtures/Datasets/`
4. **Phase 1 kickoff** (after above complete)

#### Phase 1 Execution (2-3 weeks)
- Follow Phase 1 exit criteria
- Weekly check-ins on progress
- Gate: All exit criteria met before Phase 2

#### Post-Phase 1
- Phase 1 retrospective
- Update implementation plan based on learnings
- Proceed to Phase 2

### Risk Mitigation Summary

**Scope Creep:**
- Mitigated by explicit exit criteria per phase
- Deferred features clearly marked (Phase 5 section)

**Performance Targets:**
- Mitigated by hardware baselines + benchmark harness
- Early performance testing (Phase 1 includes basic benchmarks)

**Rework:**
- Mitigated by resolving critical questions before coding
- Migration framework ensures schema can evolve safely

**Dependencies:**
- Mitigated by explicit dependency mapping
- Phases can run parallel where possible (Phase 4 vs 2/3)

---

**Document status:** Complete with feedback addressed
**Last updated:** Implementation readiness review with exit criteria
**Next review:** After Phase 1 critical questions resolved (before coding starts)
