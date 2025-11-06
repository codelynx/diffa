# Changelog

All notable changes to Diffalla will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Distribution & Packaging infrastructure (Phase 5 Step 10)
  - Build script for release binaries (macOS universal + Linux)
  - Homebrew formula
  - Installation script
  - GitHub Actions CI/CD workflows

## [0.1.0] - 2025-11-06

### Added
- **Phase 0: SQLite Wrapper**
  - Custom zero-dependency SQLite wrapper
  - Value semantics for SQLiteRow
  - Full support for embedded null bytes
  - 28 comprehensive tests

- **Phase 1: Snapshots and Comparison**
  - FileSystemItem for efficient file representation
  - SnapshotEngine for directory scanning
  - Snapshot storage in SQLite
  - Difference comparison with lazy evaluation

- **Phase 2: Patching**
  - Patch creation from differences
  - Hybrid storage (inline + cache for large files)
  - Patch apply/revert operations
  - RevertData for rollback support
  - Export formats (text, JSON, HTML, diff)

- **Phase 3: Synchronization**
  - Unidirectional sync
  - Bidirectional sync with conflict resolution
  - Conflict strategies (error, newest, source-wins, dest-wins)
  - Progress reporting
  - Partial failure handling

- **Phase 4: Optimization**
  - Hash caching for faster scans
  - Parallel hashing (multi-core)
  - Move detection (copy+delete → move)
  - Benchmark harness

- **Phase 5: CLI Tool**
  - 6 commands: snapshot, compare, patch, sync, export, verify
  - ANSI color support with auto-detection
  - Dry-run mode for all destructive operations
  - Progress reporting
  - Comprehensive error handling
  - 23 integration tests
  - 7 man pages
  - 4 example scripts

### Technical Details
- 273 tests passing (250 library + 23 integration)
- Zero external dependencies
- SQLite-based storage
- Memory efficient (constant usage independent of file sizes)
- Cross-platform (macOS, iOS, Linux)

## Version Numbering

- **0.x.x**: Pre-1.0 development releases
- **1.0.0**: First stable release (when Phase 5 complete)
- **x.y.z**: Semantic versioning
  - x: Major (breaking changes)
  - y: Minor (new features, backward compatible)
  - z: Patch (bug fixes, backward compatible)

## Links

- [Phase 0-4 Implementation](docs/phase1-breakdown.md)
- [Phase 5 CLI Tool](docs/phase5-breakdown.md)
- [CLI Design](docs/cli-design.md)
- [Architecture](docs/architecture.md)

[Unreleased]: https://github.com/yourusername/Diffalla/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/yourusername/Diffalla/releases/tag/v0.1.0
