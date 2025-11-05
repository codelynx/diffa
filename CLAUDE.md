# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Diffalla** is a Swift library for file system comparison, patching, and synchronization on Apple platforms (macOS, iOS). It provides snapshot-based directory comparison, patch creation/application, and folder synchronization with conflict resolution.

**Current Status:** Design phase complete. Custom SQLite wrapper implemented and production-ready (28 passing tests). Phase 1 implementation (Snapshots and Comparison) awaiting resolution of critical design questions.

**Key Design Philosophy:**
- Simple first, no frills
- Optimize for large scale (100k+ files, GBs of data)
- Accept minor overhead for small cases
- SQLite-based storage for memory efficiency
- No UI - library/framework only

## Build and Test Commands

### Build
```bash
swift build
```

### Run Tests
```bash
swift test
```

### Run Single Test
```bash
swift test --filter SQLiteDatabaseTests.testCreateTable
```

### Clean Build
```bash
rm -rf .build
swift build
```

### Check for Build Warnings
```bash
swift build 2>&1 | grep -i warning
```

## Architecture Overview

### Current Implementation (Phase 0: SQLite Wrapper)

**Custom SQLite Wrapper** (`Sources/Diffalla/Database/`):
- Zero external dependencies, cross-platform (macOS, iOS, Linux)
- 5 core files (~525 lines total):
  - `SQLiteDatabase.swift` - Main database connection class
  - `SQLiteStatement.swift` - Prepared statement wrapper
  - `SQLiteValue.swift` - Type-safe value enum (integer, real, text, blob, null)
  - `SQLiteRow.swift` - Query result row with value semantics
  - `SQLiteError.swift` - Error types
- RAII pattern for automatic resource cleanup
- Value semantics for SQLiteRow (data copied, no dangling references)
- Special handling: `sqlite3_close_v2` in deinit, explicit length for text binding
- Full support for embedded null bytes in TEXT columns (round-trip tested)
- 28 passing tests in 0.16s

**Key Implementation Details:**
- **deinit cleanup:** Uses `sqlite3_close_v2` which defers close if statements active (never fails)
- **Explicit close():** Uses `sqlite3_close` which throws if database busy (allows error detection)
- **Text binding:** Uses `utf8CString.withUnsafeBytes` with explicit byte length (preserves embedded nulls)
- **Text reading:** Uses `sqlite3_column_bytes()` → Data → String (preserves embedded nulls)
- **Value semantics:** SQLiteRow copies all data in init (no references to statement)

### Planned Architecture (Phase 1+)

**Module Structure:**
```
Sources/Diffalla/
├── Database/           # ✅ Complete - SQLite wrapper
├── Core/               # Phase 1 - ItemProtocol, Metadata, FileSystemItem
├── Snapshots/          # Phase 1 - Snapshot creation, loading, comparison
├── Comparison/         # Phase 1 - Difference computation (SQL-powered)
├── Patching/           # Phase 2 - Patch creation, apply, revert
├── Synchronization/    # Phase 3 - Unidirectional/bidirectional sync
├── Optimization/       # Phase 4 - Move detection, hash caching
└── Utilities/          # All phases - Hash utils, file ops, errors
```

**Core Design Patterns:**

1. **Snapshot-Based Comparison:**
   - Snapshots stored as SQLite databases (~200 bytes in memory per Snapshot object)
   - Directory scanned once, compared many times
   - Historical comparison (compare to old snapshots)
   - Schema: hierarchical with parent_id relationships

2. **Lazy Evaluation:**
   - Difference object (~400 bytes) just references two snapshots
   - SQL queries execute on-demand when accessing `.added`, `.removed`, `.modified`
   - Uses `ATTACH DATABASE` to query both snapshots simultaneously

3. **Hybrid Storage for Patches:**
   - Small files (<1MB): Inline in patch SQLite database
   - Large files (≥1MB): External cache directory with UUID reference
   - Reversible patches with RevertData stored in SQLite

4. **Export Functions (Phase 2):**
   - `exportAsText()` - Human-readable diff format
   - `exportAsJSON()` - Machine-readable structured format
   - `exportAsHTML()` - Browser-friendly styled view
   - `exportAsDetailedDiff()` - Unix diff format

## Implementation Phases

### Phase 1: Foundation (In Progress - Blocked)
**Status:** Awaiting resolution of 3 critical design questions before coding starts

**Critical Questions (must resolve before Phase 1):**
1. **Symlink handling:** Follow by default or store as-is? (proposed: follow, configurable)
2. **Hidden files:** Include or exclude by default? (proposed: include, filterable)
3. **Metadata comparison:** Full stat() or selective? (proposed: minimal - mod time + size + hash)

**Location:** `docs/implementation-readiness.md:182-186` and `docs/open-questions.md`

**Deliverables:** Core types, Snapshot creation/loading, Difference comparison, basic tests

**Exit Criteria:**
- 10,000 files snapshot in <30s (HDD baseline)
- Memory usage <10 MB for 10,000 files
- Test coverage ≥80% for Core/Snapshots/Comparison

### Phase 2: Patching
**Depends on:** Phase 1 complete
**Deliverables:** Patch structure, creation, RevertData, apply/revert, export functions

### Phase 3: Synchronization
**Depends on:** Phase 1 & 2 complete
**Deliverables:** Unidirectional sync, bidirectional sync, conflict resolution

### Phase 4: Optimization
**Depends on:** Phase 1 (can run parallel to 2/3)
**Deliverables:** Hash caching, parallel hashing, benchmarking harness

### Phase 5: Polish (Future)
**Depends on:** Phase 1-4 complete
**Deliverables:** Documentation, examples, compression, platform support

## Schema Versioning

All SQLite databases include schema versioning:

```sql
CREATE TABLE schema_version (
    version INTEGER PRIMARY KEY,
    created_date TEXT NOT NULL,
    library_version TEXT NOT NULL
);
```

**Migration Framework:**
- `SchemaMigration` protocol for migration definitions
- `SchemaManager` orchestrates sequential migrations
- Current schema version: 1 (initial release)
- Auto-migration on database load (transparent to user)

**Version Policy:**
- Patch releases (1.0.x): No schema changes
- Minor releases (1.x.0): Additive changes only
- Major releases (2.0.0): Breaking changes allowed

## Performance Targets

**Hardware Baselines:**
- Baseline HDD: 5400 RPM (worst case)
- Baseline SSD: SATA SSD (common case)
- Best Case: NVMe SSD (optimal case)

**Benchmark Datasets:**
- Small: 1,000 files (~5 MB) - Baseline functionality
- Medium: 10,000 files (~300 MB) - Typical project
- Large: 100,000 files (~5 GB) - Stress test

**Acceptance Criteria:**
- Phase 1: 10,000 files in <30s (HDD), memory <10 MB
- Phase 4: 100,000 files in <10 min (HDD), <5 min (SSD)
- Snapshot-to-snapshot comparison: <1s

**Benchmark Harness (Phase 4):**
- Script: `Scripts/benchmark.sh` (to be created)
- CI integration: Run on every PR
- Metrics: Wall time, CPU, memory (RSS), disk I/O
- Regression detection: Fail if >10% slower

## Key Files and Documentation

**Core Documentation:**
- `DESIGN.md` - High-level design and API surface
- `README.md` - Project objectives and scope
- `docs/architecture.md` - Core types and system architecture
- `docs/implementation-readiness.md` - Phase plan, exit criteria, open questions
- `docs/sqlite-wrapper-fixes.md` - SQLite wrapper implementation details

**Operation Reviews (Detailed Pseudocode):**
- `docs/operation-review-snapshot.md` - Snapshot creation
- `docs/operation-review-difference.md` - Comparison logic
- `docs/operation-review-patching.md` - Patch operations
- `docs/operation-review-synchronization.md` - Sync algorithms
- `docs/operation-review-optimization.md` - Performance optimizations

**Feature Specifications:**
- `docs/snapshots.md` - Snapshot feature spec
- `docs/comparison.md` - Comparison operation spec
- `docs/patching.md` - Patching operations spec
- `docs/synchronization.md` - Sync operations spec
- `docs/optimization.md` - Optimization strategies spec

**Current Implementation:**
- `Sources/Diffalla/Database/README.md` - SQLite wrapper usage guide
- `Tests/DiffallaTests/SQLiteDatabaseTests.swift` - 28 comprehensive tests

## Important Conventions

### When in Design Phase
- Focus on **what** (requirements, behavior), not **how** (implementation)
- Document decisions in `docs/` before coding
- Resolve critical open questions before starting a phase

### When in Implementation Phase
- Focus on **how** (implementation details)
- Follow exit criteria for each phase strictly
- Write tests alongside implementation (≥80% coverage)

### Feedback Handling
- Feedback is a comment, not an order
- Consider and respond, but you decide implementation
- Document decisions when ambiguous

### Code Style
- Simple first, no frills
- RAII pattern for resource management
- Value semantics where possible (avoid dangling references)
- Explicit error handling (no silent failures)
- Test edge cases (empty strings, nulls, large data)

## Testing Strategy

**Unit Tests:** Test individual components in isolation
**Integration Tests:** Test full workflows with real file system
**Performance Tests:** Benchmark with datasets (1k, 10k, 100k files)

**Critical Edge Cases to Test:**
- Empty directories
- Embedded null bytes in strings
- Large files (1GB+)
- Deep nesting (1000+ levels)
- Unicode filenames (emoji, non-ASCII)
- Symlinks (once strategy decided)
- Hidden files (once policy decided)
- File system errors (permission denied, disk full)

## Common Gotchas

### SQLite Wrapper
- **Text binding:** Always use explicit length (don't rely on null terminator)
- **Text reading:** Always use `sqlite3_column_bytes()` (don't use `String(cString:)`)
- **deinit:** Uses `sqlite3_close_v2` (safe, never fails)
- **close():** Uses `sqlite3_close` (throws if busy)
- **Thread safety:** Each thread needs its own connection

### File Operations (Future)
- **Symlinks:** Strategy TBD (follow vs store)
- **Hidden files:** Policy TBD (include vs exclude)
- **Metadata:** Level TBD (minimal vs full)

## Dependencies

**External:** None (zero external dependencies policy)

**System Libraries:**
- `libsqlite3` (macOS/iOS: system, Linux: apt-get install libsqlite3-dev)

**Swift Package Manager:**
- Platforms: macOS 13+, iOS 16+
- Swift version: 5.9+

## Next Steps Before Coding

Before starting Phase 1 implementation:

1. **Resolve Phase 1 critical questions** (see `docs/implementation-readiness.md:182-186`):
   - Symlink handling strategy
   - Hidden files inclusion policy
   - Metadata comparison level

2. **Validate hardware baselines:**
   - Confirm access to HDD + SSD test machines
   - Benchmark simple file operations

3. **Generate benchmark datasets:**
   - Create 1k, 10k, 100k file test datasets
   - Store in `Tests/Fixtures/Datasets/`

4. **Review and finalize API design** based on question resolutions

## Contact and Decisions

For design decisions and open questions, refer to:
- `docs/open-questions.md` - All unresolved design questions
- `docs/implementation-readiness.md` - Phase plan and question assignment

When making significant design decisions during implementation:
- Document in `docs/decisions.md` (to be created)
- Update relevant specification documents
- Add tests to verify the decision
