# Changelog

All notable changes to Diffa will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.12.0] - 2025-12-17

### Added
- **Phase 7: Network Sync**
  - `diffa serve` - Start sync server daemon
  - `diffa push` - Push local directory to remote server
  - `diffa pull` - Pull remote directory to local
  - TCP-based sync protocol using Apple's Network framework
  - Server displays local IP addresses for easy connection
  - Proper message buffering for reliable large file transfers
  - **Automatic compression** for network transfers (ZLIB/gzip compatible)
    - Files >4KB automatically compressed
    - Skips already-compressed files (jpg, mp4, zip, etc.)
    - Backward-compatible protocol (works with older clients/servers)

### Fixed
- Network protocol buffer handling for rapid file transfers
- Push mode now deletes remote files not present locally (true mirror behavior)

## [0.11.0] - 2025-12-17

### Added
- **Phase 6: EfficientSync Foundation**
  - Content-addressable storage with SHA-256 hashing
  - SQLite-backed snapshots with hash index for fast lookups
  - FileSystemScanner for streaming directory traversal
  - FileHasher with 64KB chunk streaming
  - SQLiteSyncSnapshot for efficient snapshot creation
  - SnapshotComparator for detecting add/modify/delete/move operations
  - MoveDetector with deterministic hash-based pairing
  - ContentTracker for zero-copy deduplication
  - EfficientSyncExecutor for applying sync operations
  - 43+ new tests for Phase 6 components

### Changed
- Version bump to 0.11.0

## [0.10.0] - 2025-11-06

### Added
- **Linux Support with Swift Crypto**
  - Cross-platform hashing using Swift Crypto (replaces macOS-only CommonCrypto)
  - Full Linux compatibility (tested on Ubuntu)
  - Snap package support (snapcraft.yaml)
  - Linux installation scripts (install-swift-linux.sh, install-diffa.sh)

- **Enhanced Distribution**
  - Comprehensive distribution guide
  - Homebrew tap setup documentation
  - Installation documentation for all platforms

### Changed
- Dependency: Added swift-crypto for cross-platform support
- FileSystemItem: Updated to use Swift Crypto
- SnapshotEngine: Cross-platform hash computation

## [0.9.0] - 2025-11-06

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

[Unreleased]: https://github.com/codelynx/Diffa/compare/v0.12.0...HEAD
[0.12.0]: https://github.com/codelynx/Diffa/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/codelynx/Diffa/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/codelynx/Diffa/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/codelynx/Diffa/releases/tag/v0.9.0
