# Phase 4 Implementation Breakdown

**Goal:** Performance optimizations for large-scale file operations
**Duration:** 2-3 weeks (broken into 8 incremental steps)

---

## Key Design Decisions

**1. Benchmarks Separate from Tests:**
- Heavy benchmarks (100k files, GB datasets) run via `Scripts/benchmark.sh`, NOT `swift test`
- Unit tests use small synthetic datasets (<100 files) for functional correctness only
- CI runs fast tests; benchmarks are opt-in/manual

**2. O(N) Move Detection:**
- Hash-based indexing (dictionary lookup) instead of nested loops
- Complexity: O(N) vs naive O(N²)
- Example: 10k moves = 10k lookups vs 100M comparisons

**3. No Hardware-Dependent Assertions:**
- Tests verify correctness, NOT absolute timing
- Benchmarks measure performance, NOT tests
- Relative speedups (cache vs uncached) validated, not absolute numbers
- Targets are guidelines, not enforced in CI

---

## Overview

Phase 4 delivers performance optimizations that make Diffa practical for large-scale use (100k+ files). The focus is on:
- **Speed:** Hash caching, parallel operations, move detection
- **Efficiency:** Memory optimization, smart comparison
- **Measurement:** Benchmarking harness, performance validation

**Architecture:**
```
Hash Cache ──> Faster snapshots (100x speedup on cached files)
    ↓
Parallel Hashing ──> Multi-core utilization (Nx speedup)
    ↓
Move Detection ──> Avoid unnecessary copies (1GB file: 1s vs 60s)
    ↓
Benchmarking ──> Validate performance targets
```

**Key Design Principle:**
Phase 4 is **additive** - all optimizations are opt-in or transparent. Existing APIs continue working unchanged.

**Breakdown Strategy:**
- Small, testable increments
- Each step adds one optimization
- Measure performance improvement at each step
- Can pause/resume at any step

---

## Step 0: Hash Cache Foundation (3-4 hours)

**Goal:** Create persistent hash cache infrastructure

**Deliverables:**
```swift
// Sources/Diffa/Optimization/HashCache.swift
public class HashCache {
    private let database: SQLiteDatabase

    /// Create or open a hash cache database
    public init(at url: URL) throws

    /// Look up cached hash for a file
    /// Returns cached hash if file unchanged (same size + mtime), nil otherwise
    public func lookup(path: String, size: Int64, modificationDate: Date) throws -> String?

    /// Store hash for a file
    public func store(path: String, size: Int64, modificationDate: Date, hash: String) throws

    /// Remove stale entries (files that no longer exist)
    public func prune(validPaths: Set<String>) throws

    /// Clear all cached hashes
    public func clear() throws
}
```

**Schema:**
```sql
CREATE TABLE hash_cache (
    path TEXT PRIMARY KEY,
    size INTEGER NOT NULL,
    modification_date TEXT NOT NULL,  -- ISO8601
    sha256 TEXT NOT NULL,
    cached_at TEXT NOT NULL            -- When hash was cached
);

CREATE INDEX idx_cached_at ON hash_cache(cached_at);
```

**Cache Invalidation Strategy:**
- Cache hit: Same path, size, and mtime → Use cached hash
- Cache miss: Any difference → Recompute hash
- Prune: Remove entries for non-existent files after scan

**Cache Location:**
Default: `~/.diffa/cache/<directory-hash>.db` (per-directory cache)

**Tests:**
- `testHashCacheLookup()` (cache hit returns hash)
- `testHashCacheMiss()` (changed file returns nil)
- `testHashCacheStore()` (stores hash correctly)
- `testHashCachePrune()` (removes stale entries)
- `testHashCacheClear()` (clears all entries)

**Exit Criteria:**
- ✅ HashCache class implemented
- ✅ SQLite schema created
- ✅ Tests pass (5 tests)
- ✅ Cache hit/miss logic correct
- ✅ No warnings

---

## Step 1: Integrate Hash Cache into Snapshot Creation (3-4 hours)

**Goal:** Use hash cache during snapshot creation for instant hash lookup

**Deliverables:**
```swift
// Sources/Diffa/Snapshots/ScanOptions.swift
public struct ScanOptions {
    // ... existing options

    /// Enable hash caching for faster subsequent scans
    /// Default: false (opt-in for Phase 4)
    public var useHashCache: Bool = false

    /// Custom hash cache location (default: ~/.diffa/cache/)
    public var hashCacheDirectory: URL? = nil
}

// Sources/Diffa/Snapshots/SnapshotEngine.swift
extension SnapshotEngine {
    /// Create snapshot with hash cache support
    func createSnapshot(
        from directory: URL,
        saveTo snapshotURL: URL,
        options: ScanOptions,
        progress: ((ScanProgress) -> Void)?
    ) async throws -> Snapshot {
        // 1. Open hash cache if enabled
        let cache: HashCache? = options.useHashCache ? try openOrCreateCache(for: directory, options: options) : nil

        // 2. Scan files
        // 3. For each file:
        //    - Try cache lookup first
        //    - If miss, compute hash and store in cache
        // 4. Write snapshot
        // 5. Prune cache (remove entries for deleted files)
    }
}
```

**Implementation:**
1. Check `ScanOptions.useHashCache` flag
2. If enabled, open/create cache database
3. During file scan, try cache lookup before hashing
4. On cache miss, compute hash and store
5. After scan, prune cache to remove stale entries
6. Report cache stats in progress callback

**Tests:**
- `testSnapshotWithHashCacheEnabled()` (uses cache)
- `testSnapshotWithHashCacheDisabled()` (no cache)
- `testSnapshotCacheHit()` (second scan uses cached hashes)
- `testSnapshotCacheMiss()` (modified file recomputed)
- `testSnapshotCachePrune()` (deleted files removed from cache)

**Exit Criteria:**
- ✅ Hash cache integration works
- ✅ Cache hit rate >90% on second scan
- ✅ Tests pass (10 total: 5 from Step 0 + 5 new tests)
- ✅ Performance improvement measurable
- ✅ No regression when cache disabled

---

## Step 2: Parallel Hashing with TaskGroup (4-5 hours)

**Goal:** Use Swift Concurrency to hash multiple files in parallel.

**What shipped:**
- `ScanOptions` gained `useParallelHashing` (default `false`) and `maxConcurrentHashing` (default `ProcessInfo.activeProcessorCount`).
- New `ParallelHasher` helper (OperationQueue-backed) limits active hash computations and is reused by every `FileSystemItem` cache miss.
- `HashCache` is now thread-safe (`DispatchQueue` guarded + `@unchecked Sendable`), allowing concurrent lookups/stores.
- `SnapshotEngine` builds batches with `withThrowingTaskGroup`:
  - Regular files (non-symlink, non-directory) are dispatched to the group.
  - Each task creates a `FileSystemItem` using the shared `ParallelHasher`.
  - Sequential path still handles directories/symlinks to preserve streaming + recursion order.
  - Cache hit/miss metrics are aggregated on the main thread to keep progress accurate.
- `FileSystemItem` accepts an optional `parallelHasher` and uses it for cache misses.

**Concurrency strategy:**
- TaskGroup fans out file work while keeping DB writes/recursion serialized.
- `ParallelHasher` caps concurrent hashing (no more than `maxConcurrentHashing` files reading at once).
- Directories, symlinks, and metadata updates remain sequential to avoid writer contention.

**Tests:**
- `ParallelHashingTests.testParallelHasherComputesExpectedHash`
- `ParallelHashingTests.testSnapshotParallelHashingMatchesSequential`
- `ParallelHashingTests.testParallelHashingWithHashCacheReportsHits`

**Exit Criteria:**
- ✅ Parallel hashing works (snapshots identical between sequential + parallel scans)
- ✅ Concurrency bounded by `maxConcurrentHashing`
- ✅ Tests pass (suite + 3 new parallel hashing tests)
- ✅ Cache stats + progress remain accurate
- ✅ Hash cache safe under concurrent access

---

## Step 3: Move Detection (5-6 hours)

**Goal:** Detect renamed/moved files to avoid unnecessary copy+delete

**Deliverables:**
```swift
// Sources/Diffa/Optimization/MoveDetector.swift
public class MoveDetector {
    /// Detect moved/renamed files between snapshots
    ///
    /// Algorithm:
    /// 1. Find files removed from source
    /// 2. Find files added to destination
    /// 3. Match by hash + size
    /// 4. Emit move operations instead of delete+add
    ///
    /// - Returns: List of detected moves
    public func detectMoves(
        difference: Difference
    ) throws -> [DetectedMove]
}

public struct DetectedMove {
    public let fromPath: String
    public let toPath: String
    public let hash: String
    public let size: Int64
}

// Sources/Diffa/Synchronization/SyncOptions.swift
extension SyncOptions {
    /// Enable move detection (rename files instead of copy+delete)
    /// Default: false (opt-in for Phase 4)
    public var detectMoves: Bool = false
}
```

**Move Detection Algorithm (O(N) with Hash Index):**
```
1. Get removed items from Difference
2. Get added items from Difference

3. Build hash index for added items:
   addedByHash: [String: [SnapshotItem]] = [:]
   For each added item:
     key = "\(hash)-\(size)"  // Composite key: hash + size
     addedByHash[key].append(item)

4. For each removed item:
     key = "\(hash)-\(size)"
     If addedByHash[key] exists and not empty:
       → This is a move (from removed path to added[0] path)
       → Remove added[0] from addedByHash[key]
       → Add to moves set
     Else:
       → This is a deletion

5. Remaining items in addedByHash = actual additions
6. Moves = rename operations (no copy needed)

Complexity: O(N) where N = total differences
```

**Scalability:**
- Without index: O(removed × added) = O(N²) for N differences
- With hash index: O(removed + added) = O(N)
- Example: 10k moves without index = 100M comparisons vs 10k lookups with index (10,000x faster)

**SyncPlanner Integration:**
```swift
extension SyncPlanner {
    func planUnidirectional(
        difference: Difference,
        sourceDirectory: URL,
        destinationDirectory: URL,
        detectMoves: Bool = false
    ) throws -> [SyncOperation] {
        if detectMoves {
            let moveDetector = MoveDetector()
            let moves = try moveDetector.detectMoves(difference: difference)
            // Generate move operations instead of copy+delete
        } else {
            // Existing logic
        }
    }
}
```

**Tests:**
- `testDetectSimpleMove()` (single file renamed)
- `testDetectMoveToSubdirectory()` (file moved to different directory)
- `testDetectMultipleMoves()` (multiple files renamed)
- `testDetectNoMoves()` (no renames, only add/delete)
- `testDetectMoveVsCopy()` (distinguish move from copy)

**Exit Criteria:**
- ✅ Move detection works
- ✅ 100% accuracy on test dataset
- ✅ Tests pass (20 total: 5+5+5+5 tests)
- ✅ 1GB file move: <1s (vs 60s+ for copy+delete)
- ✅ No false positives

---

## Step 4: Move Operation Execution (3-4 hours)

**Goal:** Execute file moves using FileManager.moveItem

**Deliverables:**
```swift
// Sources/Diffa/Synchronization/SyncOperation.swift
extension SyncOperation {
    /// Move/rename a file (no copy needed)
    case moveFile(from: URL, to: URL, size: Int64)
}

// Sources/Diffa/Synchronization/SyncExecutor.swift
extension SyncExecutor {
    private func executeMoveFile(
        from source: URL,
        to destination: URL,
        size: Int64,
        progress: inout SyncProgress,
        progressCallback: ((SyncProgress) -> Void)?
    ) throws {
        // Create parent directory if needed
        // Move file using FileManager.moveItem
        // Update progress
    }
}
```

**Implementation:**
1. Ensure destination parent directory exists
2. Use `FileManager.moveItem(at:to:)` for atomic move
3. Handle cross-filesystem moves (falls back to copy+delete)
4. Update progress tracking
5. Report move in SyncResult

**Tests:**
- `testExecuteMoveOperation()` (move single file)
- `testExecuteMoveToNewDirectory()` (create parent dirs)
- `testExecuteMoveCrossDiskFallback()` (copy+delete fallback)
- `testExecuteMoveProgress()` (progress reported)
- `testExecuteMoveStatistics()` (SyncResult.filesMoved updated)

**Exit Criteria:**
- ✅ Move operations execute correctly
- ✅ Cross-filesystem fallback works
- ✅ Tests pass (25 total: 5+5+5+5+5 tests)
- ✅ Atomic on same filesystem
- ✅ Progress tracking accurate

---

## Step 5: Benchmarking Harness (4-5 hours)

**Goal:** Automated performance measurement framework (separate from test suite)

**IMPORTANT:** Benchmarks are **NOT** part of the main test suite. Heavy benchmarks run via separate opt-in scripts to avoid slow CI and hardware dependencies.

**Deliverables:**
```bash
# Scripts/benchmark.sh
#!/bin/bash
# Opt-in benchmarking harness (NOT run during swift test)
# Usage: ./Scripts/benchmark.sh [small|medium|large|all]

# Datasets (generated on-demand):
# - Small: 1,000 files (~5 MB)
# - Medium: 10,000 files (~300 MB)
# - Large: 100,000 files (~5 GB)

# Metrics collected:
# - Wall time
# - CPU usage (%)
# - Memory peak RSS
# - Disk I/O (MB/s)

# Output: JSON results file for tracking over time
# Example: benchmarks/results-2025-11-05.json
```

**Benchmark Scenarios:**
```swift
// Scripts/BenchmarkRunner/main.swift
// Separate executable, NOT in test suite

@main
struct BenchmarkRunner {
    static func main() async throws {
        // 1. Generate benchmark datasets
        // 2. Run benchmarks
        // 3. Collect metrics
        // 4. Output JSON results
        // 5. Compare to baseline (if exists)
    }

    func benchmarkSnapshotCreation(dataset: Dataset) async throws -> BenchmarkResult
    func benchmarkHashCacheSpeedup(dataset: Dataset) async throws -> BenchmarkResult
    func benchmarkParallelHashing(dataset: Dataset) async throws -> BenchmarkResult
    func benchmarkMoveDetection(dataset: Dataset) async throws -> BenchmarkResult
    func benchmarkComparison(dataset: Dataset) async throws -> BenchmarkResult
}
```

**Unit Tests (Functional Only, Small Datasets):**
```swift
// Tests/DiffaTests/OptimizationTests.swift
// ONLY functional correctness tests with small synthetic datasets

final class OptimizationTests: XCTestCase {
    /// Verify hash cache correctness (10 files, NOT 100k)
    func testHashCacheFunctional() async throws

    /// Verify parallel hashing produces same results (20 files)
    func testParallelHashingCorrectness() async throws

    /// Verify move detection accuracy (5 moves)
    func testMoveDetectionAccuracy() async throws

    // NO performance assertions, NO large datasets, NO timing checks
}
```

**Performance Targets (Measured via Benchmark Harness, NOT CI):**
| Operation | Dataset | Target (SSD) | Measurement Method |
|-----------|---------|--------------|-------------------|
| Snapshot (first) | 10k files | <10s | Benchmark script |
| Snapshot (cached) | 10k files | <0.5s | 100x speedup vs first |
| Snapshot (first) | 100k files | <5min | **Phase 4 target** |
| Snapshot (cached) | 100k files | <10s | **Phase 4 target** |
| Comparison | 100k files | <2s | SQL-powered |
| Move (1GB file) | 1 file | <1s | vs 60s copy+delete |
| Parallel hash | 100 x 10MB | ≥2x faster | On 4-core CPU |

**Note:** These targets are measured **manually** via benchmark harness, NOT enforced in CI tests. Actual timing varies by hardware.

**Functional Tests (Small Datasets Only):**
- `testHashCacheFunctional()` (10 files, verify correctness)
- `testParallelHashingCorrectness()` (20 files, same results)
- `testMoveDetectionAccuracy()` (5 moves, 100% accuracy)
- `testHashCacheInvalidation()` (modified file invalidates cache)
- `testMoveDetectionNoFalsePositives()` (copy vs move distinction)

**Exit Criteria:**
- ✅ Benchmark script executable works
- ✅ Dataset generator works
- ✅ Functional tests pass (5 tests, small datasets)
- ✅ Benchmark harness runs successfully
- ✅ Baseline metrics documented (not enforced)

---

## Step 6: Performance Validation (3-4 hours)

**Goal:** Run benchmarks and document performance characteristics

**IMPORTANT:** Performance validation is done via **benchmark harness**, NOT unit tests. Unit tests verify functional correctness only.

**Deliverables:**
```bash
# Run benchmark suite and generate report
./Scripts/benchmark.sh all > benchmarks/results-2025-11-05.json

# Generate human-readable performance report
./Scripts/generate-report.sh benchmarks/results-2025-11-05.json > docs/performance-report.md
```

**Benchmark Validation Checklist (Manual Review):**
```markdown
# Performance Validation Checklist

Run benchmarks and verify targets met:

- [ ] Small dataset (1k files): Baseline established
- [ ] Medium dataset (10k files): <10s snapshot (SSD)
- [ ] Large dataset (100k files): <5min snapshot (SSD)
- [ ] Hash cache speedup: >50x on second run (allow tolerance)
- [ ] Parallel hashing: >1.5x speedup on 4-core (allow variance)
- [ ] Move detection: 1GB file <5s (hardware dependent)
- [ ] Memory usage: <50 MB for 100k files
- [ ] No regressions vs Phase 3 baseline

NOTE: Exact timing varies by hardware. Focus on:
1. Relative speedup (cache vs uncached, parallel vs sequential)
2. Scalability (linear growth with file count)
3. No memory leaks or regressions
```

**Functional Tests (NO Performance Assertions):**
```swift
// Tests/DiffaTests/OptimizationRegressionTests.swift
final class OptimizationRegressionTests: XCTestCase {
    /// Verify optimizations don't break correctness
    func testHashCacheDoesNotChangeResults() async throws {
        // With cache vs without cache: identical snapshots
    }

    /// Verify parallel hashing produces identical results
    func testParallelHashingIdenticalToSequential() async throws {
        // Sequential vs parallel: same hashes
    }

    /// Verify move detection preserves file contents
    func testMoveDetectionPreservesContents() async throws {
        // Move operation: file contents unchanged
    }

    // Focus: Correctness, NOT speed
}
```

**Validation Workflow:**
1. Run `swift test` → All functional tests pass (small datasets, fast)
2. Run `./Scripts/benchmark.sh all` → Collect performance data
3. Review benchmarks/results.json → Check targets met
4. Document findings in docs/performance-report.md
5. Compare to baseline (if exists) → Detect regressions

**Exit Criteria:**
- ✅ Functional regression tests pass (5 tests, <5s)
- ✅ Benchmark script completes successfully
- ✅ Performance report generated
- ✅ Targets met (within tolerance, documented)
- ✅ No correctness regressions
- ✅ Relative speedups validated (cache, parallel)

---

## Step 7: Smart Comparison Optimizations (2-3 hours)

**Goal:** Optimize comparison with early exits and index usage

**Deliverables:**
```swift
// Sources/Diffa/Comparison/Difference.swift
extension Difference {
    /// Fast path: Check if snapshots identical without full comparison
    public func isEmpty() throws -> Bool {
        // Quick check: Compare root hashes first
        // If root hashes match, snapshots are identical
        // Return early without iterating all files
    }

    /// Count total differences without loading all items
    public func count() throws -> Int {
        // Use SQL COUNT(*) instead of loading all rows
        // Much faster for large datasets
    }
}
```

**Optimizations:**
1. **Root hash optimization:** Compare root directory hashes first
2. **COUNT queries:** Use SQL COUNT instead of loading rows
3. **Index optimization:** Ensure indexes on path, parent_id, sha256
4. **Lazy iteration:** Don't load all differences upfront

**Tests:**
- `testComparisonEarlyExitIdentical()` (identical snapshots fast path)
- `testComparisonCount()` (COUNT query vs loading)
- `testComparisonIndexUsage()` (verify indexes used)
- `testComparisonLargeDataset()` (100k files comparison <5s)

**Exit Criteria:**
- ✅ Early exit optimizations work
- ✅ Tests pass (39 total tests)
- ✅ 100k file comparison <5s
- ✅ No memory regression

---

## Step 8: Documentation & Final Validation (2-3 hours)

**Goal:** Document optimizations and validate end-to-end

**Deliverables:**
1. **docs/optimization.md** - Optimization guide
2. **docs/performance-report.md** - Benchmark results
3. **README updates** - Performance characteristics
4. **API documentation** - New options and flags

**Documentation Contents:**
```markdown
# Optimization Guide

## Hash Caching
- How it works
- When to use
- Cache location
- Performance impact

## Parallel Hashing
- CPU core utilization
- When to enable
- Concurrency tuning
- Speedup expectations

## Move Detection
- How moves are detected
- Accuracy guarantees
- Performance benefits
- Edge cases

## Performance Characteristics
- Timing benchmarks
- Memory usage
- Scalability limits
- Best practices
```

**Final Validation:**
- Run full test suite (all 39+ tests)
- Run benchmark suite on all datasets
- Verify performance targets met
- Check for regressions
- Update documentation

**Exit Criteria:**
- ✅ Documentation complete
- ✅ All tests pass (39+ tests)
- ✅ All benchmarks pass
- ✅ Performance targets met
- ✅ No warnings
- ✅ Phase 4 complete

---

## Progress Tracking

Use checkboxes to track progress:

- [ ] Step 0: Hash Cache Foundation (3-4 hours)
- [ ] Step 1: Integrate Hash Cache (3-4 hours)
- [x] Step 2: Parallel Hashing (4-5 hours)
- [ ] Step 3: Move Detection (5-6 hours)
- [ ] Step 4: Move Operation Execution (3-4 hours)
- [ ] Step 5: Benchmarking Harness (4-5 hours)
- [ ] Step 6: Performance Validation (3-4 hours)
- [ ] Step 7: Smart Comparison Optimizations (2-3 hours)
- [ ] Step 8: Documentation & Final Validation (2-3 hours)

**Estimated Total:** 29-38 hours (4-5 days of focused work)

---

## Phase 4 Exit Criteria

Once all steps complete, verify:

✅ **Functional Tests Pass (Fast, Hardware-Independent):**
- All optimization correctness tests pass (~30-40 tests)
- Small synthetic datasets only (<100 files per test)
- Tests complete in <10s total
- No regressions in existing Phase 1-3 tests
- Test coverage ≥80% for Optimization module
- Zero flaky tests due to timing or hardware

✅ **Benchmarks Complete (Manual, Hardware-Specific):**
- Benchmark harness executable works
- All datasets generated (1k, 10k, 100k files)
- Baseline metrics collected and documented
- Performance report generated
- Relative improvements measured (cache vs uncached, parallel vs sequential)
- NOTE: Absolute timing targets (e.g., "<5 min") are guidelines, not enforced

✅ **Performance Characteristics Documented:**
- Hash cache speedup: >50x on second run (target, may vary)
- Parallel hashing: >1.5x speedup on multi-core (target, may vary)
- Move detection: O(N) complexity validated
- Memory usage: <50 MB for 100k files (measured)
- Scalability: Linear growth with file count (validated)
- Known limitations and hardware dependencies documented

✅ **Features Complete:**
- Hash caching with automatic invalidation
- Parallel hashing with TaskGroup
- Move detection with high accuracy
- Move operation execution
- Benchmarking harness
- Performance validation
- Documentation

✅ **API Validated:**
- Hash cache API works correctly
- Parallel hashing is opt-in
- Move detection is opt-in
- No breaking changes to existing APIs
- Performance characteristics documented

---

## Deferred to Phase 5 (Polish & CLI)

The following features are intentionally deferred:

- **CLI tool:** `diffa` command-line interface
- **Filters:** Include/exclude patterns for sync
- **Incremental sync:** Resume interrupted operations
- **Compression:** Snapshot/patch compression
- **Manual conflict resolution:** Interactive resolution callbacks
- **Keep both strategy:** Save conflicting files with timestamps
- **GUI example:** Sample macOS/iOS GUI application

**Rationale:** Phase 4 focuses on performance. UI/UX features come in Phase 5.

---

## Open Questions (Resolve Before Starting)

1. **Hash cache persistence:** Per-directory or global? → **Proposed: Per-directory (~/.diffa/cache/<dir-hash>.db)**
2. **Parallel hashing threshold:** Min file size for parallel hashing? → **Proposed: >1 MB files only**
3. **Move detection threshold:** Max hash collisions before giving up? → **Proposed: Match by hash+size, no limit**
4. **Benchmark CI integration:** Run on every PR or nightly? → **Proposed: Nightly only (too slow for PR)**
5. **Memory limits:** Max memory usage for 1M files? → **Proposed: <500 MB (5x Phase 1 target)**

---

**Next:** Resolve open questions, then start with Step 0 - Hash Cache Foundation
