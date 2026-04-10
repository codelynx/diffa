# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Diffa** is a Swift library and command-line tool for file system comparison, patching, and synchronization on Apple platforms, Linux, and Windows. It provides snapshot-based directory comparison, patch creation/application, and folder synchronization with conflict resolution.

**Dual Interface:**
- **Library:** Swift Package for embedding in macOS/iOS/Linux/Windows apps
- **CLI Tool:** `diffa` command for macOS, Linux, and Windows (Phase 5)

**Current Status:** Phases 0-7 complete. All core functionality implemented and cross-platform (macOS + Linux + Windows). Network sync (serve/push/pull) with automatic compression operational on all three platforms using cross-platform sockets (POSIX on macOS/Linux, Winsock2 on Windows) and bundled zlib.

**Key Design Philosophy:**
- Simple first, no frills
- Optimize for large scale (100k+ files, GBs of data)
- Accept minor overhead for small cases
- SQLite-based storage for memory efficiency
- Library + CLI tool from single codebase

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

**Custom SQLite Wrapper** (`Sources/Diffa/Database/`):
- Zero external dependencies, cross-platform (macOS, iOS, Linux, Windows)
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

### Current Architecture

**Module Structure:**
```
Sources/Diffa/
├── Database/           # ✅ Complete - SQLite wrapper
├── Core/               # ✅ Complete - ItemProtocol, Metadata, FileSystemItem
├── Snapshots/          # ✅ Complete - Snapshot creation, loading, comparison
├── Comparison/         # ✅ Complete - Difference computation (SQL-powered)
├── Patching/           # ✅ Complete - Patch creation, apply, revert
├── Synchronization/    # ✅ Complete - Unidirectional/bidirectional sync
├── Optimization/       # ✅ Complete - Move detection, hash caching
├── EfficientSync/      # ✅ Complete - Phase 6 content-addressable sync
│   ├── Core/           # FileItem, ContentTracker, SyncMode
│   ├── Snapshots/      # FileSystemScanner, FileHasher, SQLiteSyncSnapshot
│   ├── Comparison/     # SnapshotComparator, MoveDetector, EfficientSyncExecutor
│   └── Network/        # SyncProtocol, SyncServer, SyncClient, PlatformSocket
└── Utilities/          # Hash utils, file ops, errors

Sources/DiffaCLI/
├── DiffaTool.swift     # Main entry point
├── Commands/           # snapshot, compare, patch, sync, export, verify
└── Network/            # serve, push, pull commands
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

### Phase 0: SQLite Wrapper ✅ Complete
- Custom zero-dependency SQLite wrapper
- 28 comprehensive tests

### Phase 1: Foundation ✅ Complete
- Core types, Snapshot creation/loading, Difference comparison
- Symlinks: follow by default, configurable
- Hidden files: include by default, filterable
- Metadata: mod time + size + hash

### Phase 2: Patching ✅ Complete
- Patch structure, creation, RevertData, apply/revert
- Export formats (text, JSON, HTML, diff)

### Phase 3: Synchronization ✅ Complete
- Unidirectional sync, bidirectional sync
- Conflict resolution strategies (error, newest, source-wins, dest-wins)

### Phase 4: Optimization ✅ Complete
- Hash caching, parallel hashing
- Move detection, benchmarking harness

### Phase 5: CLI Tool ✅ Complete
- 9 commands: snapshot, compare, patch, sync, export, verify, serve, push, pull
- ANSI color support, dry-run mode, progress reporting
- 23 integration tests, 7 man pages

### Phase 6: EfficientSync ✅ Complete
- Content-addressable storage with SHA-256
- SQLite-backed snapshots with hash index
- Streaming file scanner and hasher
- Move detection with deterministic pairing
- ContentTracker for zero-copy deduplication
- 43+ new tests

### Phase 7: Network Sync ✅ Complete
- TCP server/client using cross-platform sockets (macOS + Linux + Windows)
- `serve`, `push`, `pull` commands
- Custom message protocol with proper buffering
- Automatic zlib compression for files ≥4KB (via bundled zlib)
- True mirror behavior (push/pull delete files not in source)
- Server displays local IP addresses
- Platform abstraction layer (PlatformSocket.swift) handles OS differences
- Server shutdown: self-pipe trick on Unix, loopback socket pair on Windows
- Client: non-blocking connect with 10s timeout, 30s read/write timeouts
- SIGPIPE handling: SO_NOSIGPIPE (macOS), MSG_NOSIGNAL (Linux), N/A (Windows)
- 14 integration tests (localhost push/pull, pass on all platforms)
- Cross-platform verified: all 3 pairs tested over LAN (Mac↔Linux, Mac↔Windows, Windows↔Linux) — 12/12 passed

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
- `docs/cli-design.md` - Command-line tool specification (Phase 5)
- `docs/competitive-analysis.md` - Comparison to rsync, Git, Unison, etc.
- `docs/cross-platform-network-sync.md` - Cross-platform network sync design and implementation

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
- `Sources/Diffa/Database/README.md` - SQLite wrapper usage guide
- `Tests/DiffaTests/SQLiteDatabaseTests.swift` - 28 comprehensive tests

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

### File Operations
- **Symlinks:** Follow by default (configurable with --no-follow-symlinks)
- **Hidden files:** Include by default (filterable with --no-hidden)
- **Metadata:** Minimal - mod time + size + hash

### Windows-Specific
- **POSIX permissions:** Not available; defaults to 0o644. Tests that assert specific permissions must be skipped on Windows.
- **Symlinks:** Require admin privileges on Windows. All symlink tests use `XCTSkip`.
- **Path comparison:** Case-insensitive on Windows. `FileSystemItem` uses lowercased comparison for containment checks.
- **Drive roots:** `C:/` is recognized as a root alongside `/`. See `isDriveRoot()` in `FileSystemItem.swift`.
- **MAX_PATH:** Windows has a 260-character path limit by default. Deep nesting tests are skipped.
- **Socket timeouts:** Winsock `SO_RCVTIMEO` returns `WSAETIMEDOUT`, not `EAGAIN`/`EWOULDBLOCK`. Handled in `PlatformSocket.swift`.
- **SO_REUSEADDR:** Has different semantics on Windows (allows port hijacking). We use `SO_EXCLUSIVEADDRUSE` instead.
- **WSAStartup:** Called once per process via lazy initialization; fails fast on error.

## Dependencies

**Swift Packages:**
- `swift-argument-parser` - CLI argument parsing
- `swift-crypto` - Cross-platform SHA-256 hashing

**Bundled C Libraries:**
- `CSQLite` - SQLite3 amalgamation (used on Linux and Windows; macOS/iOS use the system framework)
- `CZlib` - zlib 1.3.1 source (used on all platforms; provides cross-platform compression)

**System Libraries:**
- `libsqlite3` (macOS/iOS: system framework, linked automatically)
- `ws2_32` + `iphlpapi` (Windows: Winsock2 and IP Helper, linked automatically)

**Swift Package Manager:**
- Platforms: macOS 13+, iOS 16+, Linux, Windows
- Swift version: 5.9+

## Current Version

**Version:** 0.13.0
**Tests:** 386 passing on macOS (library + integration + EfficientSync + NetworkSync). On Linux, the full suite requires `--skip FileHasherTests` due to a pre-existing `FileHandle` directory-read trap; with that skipped, one known pre-existing failure remains in `PatchingIntegrationTests.testPatchWithLargeFiles`. On Windows, 363 tests executed with 0 unexpected failures; 17 tests skipped (symlinks require admin, POSIX permissions, MAX_PATH, drive-root paths); 1 pre-existing logic failure in `ContentTrackerTests`. CLIIntegrationTests need `.exe` path detection fix (separate issue).

## Next Steps

Potential future enhancements:
- Watch mode for file monitoring
- Remote sync via SSH
- Web UI for server status
- Performance optimization for 100k+ files
