# Phase 5 Implementation Breakdown: CLI Tool

**Date:** 2025-11-06
**Status:** ✅ COMPLETE (All steps 0-10 complete)
**Goal:** Implement `diffalla` command-line tool - PRIMARY PROJECT GOAL

## Overview

Phase 5 delivers the `diffalla` CLI tool for macOS and Linux. This is a **thin wrapper** around the Diffalla library, providing rsync-like functionality as a standalone executable.

**Design Philosophy:**
- Minimal CLI-specific code (thin wrapper)
- Familiar interface (rsync/git-inspired)
- Single binary, zero runtime dependencies
- Cross-platform (macOS, Linux)

**Versioning Strategy:**
- Development: `0.1.0` (current - during Phase 5 implementation)
- Release: `1.0.0` (when Phase 5 complete and ready for distribution)

**Full design spec:** See `docs/cli-design.md`

---

## Prerequisites

✅ **Phase 0-4 Complete:**
- SQLite wrapper
- Snapshots & Comparison
- Patching (create, apply, revert, export)
- Synchronization (unidirectional, bidirectional, conflicts)
- Optimizations (hash cache, parallel hashing, move detection)

✅ **Library ready:**
- 250 tests passing
- All core features implemented
- Public APIs accessible

---

## Implementation Steps

### Step 0: Setup & Dependencies ✅ COMPLETE (1-2 hours)

**Goal:** Add CLI target and dependencies to Package.swift

**Status:** ✅ Implemented and committed

**Deliverables:**
```swift
// Package.swift additions
.executable(
    name: "diffalla",
    targets: ["DiffallaCLI"]
),

.executableTarget(
    name: "DiffallaCLI",
    dependencies: [
        "Diffalla",
        .product(name: "ArgumentParser", package: "swift-argument-parser")
    ],
    path: "Sources/DiffallaCLI"
),

.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
```

**Tasks:**
1. Add `swift-argument-parser` dependency
2. Create `Sources/DiffallaCLI/` directory
3. Create basic `main.swift` with `@main` struct
4. Verify `swift build` succeeds
5. Test `swift run diffalla --version`

**Exit Criteria:**
- ✅ Package builds successfully
- ✅ Basic CLI executable runs
- ✅ ArgumentParser integrated
- ✅ No library test regressions

---

### Step 1: Command Structure & Routing ✅ COMPLETE (2-3 hours)

**Goal:** Implement top-level command structure and routing

**Status:** ✅ Implemented and committed

**Deliverables:**
```swift
// Sources/DiffallaCLI/main.swift
@main
struct DiffallaCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diffalla",
        abstract: "Snapshot, compare, patch, and sync directories",
        version: "0.1.0",  // Pre-release version, will bump to 1.0.0 at Phase 5 completion
        subcommands: [
            SnapshotCommand.self,
            CompareCommand.self,
            PatchCommand.self,
            SyncCommand.self,
            ExportCommand.self,
            VerifyCommand.self
        ]
    )
}

// Command stubs
struct SnapshotCommand: AsyncParsableCommand { ... }
struct CompareCommand: AsyncParsableCommand { ... }
struct PatchCommand: AsyncParsableCommand { ... }
struct SyncCommand: AsyncParsableCommand { ... }
struct ExportCommand: AsyncParsableCommand { ... }
struct VerifyCommand: AsyncParsableCommand { ... }
```

**Tasks:**
1. Create main command struct with subcommands
2. Implement help text
3. Create stub for each subcommand
4. Test command routing (`diffalla help`, `diffalla snapshot --help`)
5. Implement `--version` flag

**Tests:**
```bash
diffalla --help              # Shows all commands
diffalla --version           # Shows version
diffalla snapshot --help     # Shows snapshot help
diffalla unknown-command     # Shows error + help
```

**Exit Criteria:**
- ✅ All 6 commands listed in help
- ✅ Each command has help text
- ✅ Version flag works
- ✅ Unknown commands show error

---

### Step 2: Snapshot Command ✅ COMPLETE (2-3 hours)

**Goal:** Implement `diffalla snapshot` command

**Status:** ✅ Implemented and committed

**Syntax:**
```bash
diffalla snapshot <directory> -o <output.sqlite> [options]
```

**Deliverables:**
```swift
struct SnapshotCommand: AsyncParsableCommand {
    @Argument(help: "Directory to snapshot")
    var directory: String

    @Option(name: .shortAndLong, help: "Output SQLite database file")
    var output: String

    @Flag(name: .shortAndLong, help: "Show progress during snapshot creation")
    var progress: Bool = false

    @Flag(help: "Exclude hidden files")
    var noHidden: Bool = false

    @Flag(help: "Store symlinks as-is (don't follow)")
    var noFollowSymlinks: Bool = false

    @Flag(help: "Capture owner/group")
    var withOwnership: Bool = false

    @Flag(name: .shortAndLong, help: "Suppress output except errors")
    var quiet: Bool = false

    mutating func run() async throws {
        // 1. Validate directory exists
        // 2. Parse options into ScanOptions
        // 3. Call SnapshotEngine.createSnapshot()
        // 4. Show progress if --progress
        // 5. Print summary unless --quiet
    }
}
```

**Tasks:**
1. Implement argument parsing
2. Validate directory exists and is readable
3. Convert CLI flags to `ScanOptions`
4. Call `SnapshotEngine.createSnapshot()`
5. Implement progress callback (if `--progress`)
6. Print summary (file count, size, duration)
7. Handle errors gracefully

**Tests:**
```bash
# Basic snapshot
diffalla snapshot /tmp/test -o test.sqlite

# With progress
diffalla snapshot /tmp/test -o test.sqlite --progress

# Exclude hidden
diffalla snapshot /tmp/test -o test.sqlite --no-hidden

# Error: directory doesn't exist
diffalla snapshot /nonexistent -o test.sqlite  # Exit 3

# Error: no output file
diffalla snapshot /tmp/test  # Exit 2 (usage error)
```

**Exit Criteria:**
- ✅ Creates valid snapshot database
- ✅ Progress bar works (if `--progress`)
- ✅ All flags honored
- ✅ Error messages clear
- ✅ Exit codes correct

---

### Step 3: Compare Command ✅ COMPLETE (2-3 hours)

**Goal:** Implement `diffalla compare` command

**Status:** ✅ Implemented and committed

**Syntax:**
```bash
diffalla compare <source> <destination> [options]
```

**Deliverables:**
```swift
struct CompareCommand: AsyncParsableCommand {
    @Argument(help: "Source directory or snapshot")
    var source: String

    @Argument(help: "Destination directory or snapshot")
    var destination: String

    @Option(name: .shortAndLong, help: "Output format: text, json, html, diff")
    var format: OutputFormat = .text

    @Option(name: .shortAndLong, help: "Write output to file")
    var output: String?

    @Flag(name: .shortAndLong, help: "Show summary only")
    var summary: Bool = false

    @Flag(help: "Show only added files")
    var added: Bool = false

    @Flag(help: "Show only removed files")
    var removed: Bool = false

    @Flag(help: "Show only modified files")
    var modified: Bool = false

    mutating func run() async throws {
        // 1. Load or create snapshots
        // 2. Compare using Difference.compare()
        // 3. Format output based on --format
        // 4. Write to file or stdout
        // 5. Exit with code based on differences
    }
}
```

**Tasks:**
1. Detect input types (directory vs snapshot)
2. Create temporary snapshots for directories
3. Load existing snapshots
4. Compare using `Difference.compare()`
5. Implement text formatter (added/removed/modified)
6. Filter by `--added/--removed/--modified` flags
7. Exit code: 0 if no diff, 1 if differences

**Tests:**
```bash
# Compare two directories
diffalla compare /dir-a /dir-b

# Compare snapshots (fast)
diffalla compare a.sqlite b.sqlite

# Summary only
diffalla compare /dir-a /dir-b --summary

# Show only added
diffalla compare /dir-a /dir-b --added

# Exit code
diffalla compare /identical-a /identical-b && echo "No diff"
```

**Exit Criteria:**
- ✅ Compares directories and snapshots
- ✅ Text output formatted correctly
- ✅ Filter flags work
- ✅ Exit codes correct (0=no diff, 1=diff, 2=error)
- ✅ Temporary snapshots cleaned up

---

### Step 4: Patch Command ✅ COMPLETE (3-4 hours)

**Goal:** Implement `diffalla patch create|apply|revert` commands

**Status:** ✅ Implemented and committed

**Syntax:**
```bash
diffalla patch create <source> <dest> -o <patch.sqlite> [options]
diffalla patch apply <patch.sqlite> <target-dir> [options]
diffalla patch revert <patch.sqlite> <target-dir> [options]
```

**Deliverables:**
```swift
struct PatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create, apply, or revert patches",
        subcommands: [
            CreatePatch.self,
            ApplyPatch.self,
            RevertPatch.self
        ]
    )
}

struct CreatePatch: AsyncParsableCommand { ... }
struct ApplyPatch: AsyncParsableCommand { ... }
struct RevertPatch: AsyncParsableCommand { ... }
```

**Tasks:**
1. Implement `patch create` subcommand
2. Implement `patch apply` with `--dry-run`
3. Implement `patch revert` with `--dry-run`
4. Add progress callbacks
5. Handle cache directory for large files
6. Error handling (patch integrity, target mismatch)

**Tests:**
```bash
# Create patch
diffalla patch create /old /new -o update.patch

# Apply patch
diffalla patch apply update.patch /target

# Dry-run
diffalla patch apply update.patch /target --dry-run

# Revert
diffalla patch revert update.patch /target
```

**Exit Criteria:**
- ✅ Creates valid patches
- ✅ Applies patches correctly
- ✅ Dry-run shows operations without changes
- ✅ Revert restores original state
- ✅ Progress reporting works

---

### Step 5: Sync Command ✅ COMPLETE (3-4 hours)

**Goal:** Implement `diffalla sync` command

**Status:** ✅ Implemented and committed

**Syntax:**
```bash
diffalla sync <source> <destination> [options]
```

**Deliverables:**
```swift
struct SyncCommand: AsyncParsableCommand {
    @Argument(help: "Source directory")
    var source: String

    @Argument(help: "Destination directory")
    var destination: String

    @Flag(name: .shortAndLong, help: "Two-way sync")
    var bidirectional: Bool = false

    @Flag(name: .shortAndLong, help: "Show what would be done")
    var dryRun: Bool = false

    @Flag(name: .shortAndLong, help: "Show progress")
    var progress: Bool = false

    @Flag(help: "Delete extraneous files")
    var delete: Bool = false

    @Option(help: "Conflict resolution: newest, source-wins, dest-wins, error")
    var conflicts: ConflictStrategy = .error

    @Flag(help: "Disable move detection")
    var noMoveDetection: Bool = false

    mutating func run() async throws {
        // 1. Create snapshots
        // 2. Plan sync operations
        // 3. Show operations if --dry-run
        // 4. Execute sync with progress
        // 5. Report results
    }
}
```

**Tasks:**
1. Implement unidirectional sync
2. Implement bidirectional sync (`--bidirectional`)
3. Conflict detection and resolution
4. Dry-run mode
5. Progress reporting
6. Move detection integration
7. Statistics summary

**Tests:**
```bash
# Unidirectional sync
diffalla sync /source /dest

# Bidirectional with conflicts
diffalla sync /dir-a /dir-b --bidirectional --conflicts newest

# Dry-run
diffalla sync /source /dest --dry-run

# With delete
diffalla sync /source /dest --delete
```

**Exit Criteria:**
- ✅ Unidirectional sync works
- ✅ Bidirectional sync works
- ✅ Conflict strategies implemented
- ✅ Dry-run shows operations
- ✅ Progress reporting accurate
- ✅ Move detection works

---

### Step 6: Export & Verify Commands ✅ COMPLETE (2-3 hours)

**Goal:** Implement remaining utility commands

**Status:** ✅ Implemented and committed

**Export Syntax:**
```bash
diffalla export <patch.sqlite> -f <format> -o <output>
```

**Verify Syntax:**
```bash
diffalla verify <directory> <snapshot.sqlite>
```

**Deliverables:**
```swift
struct ExportCommand: AsyncParsableCommand {
    // Call patch.exportAsText/JSON/HTML/Diff()
}

struct VerifyCommand: AsyncParsableCommand {
    // Compare directory to snapshot, exit 0 if match
}
```

**Tasks:**
1. Implement export for all formats (text, JSON, HTML, diff)
2. Implement verify command
3. Exit codes (0=match, 1=mismatch)
4. Show diff option for verify

**Tests:**
```bash
# Export as HTML
diffalla export update.patch -f html -o report.html

# Verify
diffalla verify /etc baseline.sqlite  # Exit 0 if match

# Verify with diff
diffalla verify /etc baseline.sqlite --show-diff
```

**Exit Criteria:**
- ✅ All export formats work
- ✅ Verify detects changes
- ✅ Exit codes correct

---

### Step 7: Output Formatting & Polish ✅ COMPLETE (2-3 hours)

**Goal:** Add progress bars, tables, colors, and polish

**Status:** ✅ Implemented and committed

**Deliverables:**
- Progress bars for long operations
- Formatted tables for comparison output
- Colors for added (green), removed (red), modified (yellow)
- `--color` flag (auto, always, never)
- Error messages with suggestions

**Tasks:**
1. Implement progress bar (simple ASCII or library)
2. Format comparison output as table
3. Add ANSI colors (respect `--color` and `NO_COLOR`)
4. Improve error messages
5. Add exit code constants

**Example Output:**
```
Syncing /source → /dest...
[████████████████████] 10,000 files (100%)
Sync completed:
  ✓ 50 files copied (120 MB)
  ✓ 10 files deleted
  ✓ 5 files moved/renamed
  ⚠ 2 conflicts (resolved: newest)
Time: 45.2s
```

**Exit Criteria:**
- ✅ Progress bars work
- ✅ Colors work (and respect flags)
- ✅ Output is readable and clear
- ✅ Error messages helpful

---

### Step 8: Integration Tests ✅ COMPLETE (2-3 hours)

**Goal:** End-to-end CLI testing

**Status:** ✅ Implemented and committed

**Test Framework:**
- Execute CLI via `Process`
- Capture stdout/stderr
- Check exit codes
- Verify file system changes

**Test Coverage:**
23 integration tests covering:
- Basic functionality (version, help, unknown command)
- Snapshot command (create, invalid directory, exclude patterns)
- Compare command (identical/different directories, summary mode)
- Patch commands (create, apply, dry-run, revert, non-reversible)
- Sync command (unidirectional, dry-run, delete flag, bidirectional validation)
- Export command (all formats, error handling)
- Verify command (matching/modified directories, show-diff)
- Error handling (missing arguments, invalid options, nonexistent files)

**Implementation:**
```swift
final class CLIIntegrationTests: XCTestCase {
    func testSnapshotCommand() throws
    func testCompareDirectories() throws
    func testPatchCreateApply() throws
    func testSyncUnidirectional() throws
    func testSyncBidirectional() throws
    func testVerifyCommand() throws
    func testErrorHandling() throws
    // ... 23 tests total
}
```

**Tasks:**
1. ✅ Create integration test target
2. ✅ Test each command with real file system
3. ✅ Test error cases
4. ✅ Test exit codes
5. ✅ Test output format

**Results:**
- All 273 tests passing (250 library + 23 integration)
- No regressions in library tests
- Comprehensive CLI coverage

**Exit Criteria:**
- ✅ All commands tested end-to-end
- ✅ Error cases covered
- ✅ Exit codes verified
- ✅ Output format checked

---

### Step 9: Documentation ✅ COMPLETE (2-3 hours)

**Goal:** Create man pages, README, and examples

**Status:** ✅ Implemented and committed

**Deliverables:**
1. **Man pages (7 total):**
   - ✅ `man/man1/diffalla.1` - Main man page
   - ✅ `man/man1/diffalla-snapshot.1` - Snapshot creation
   - ✅ `man/man1/diffalla-compare.1` - Directory comparison
   - ✅ `man/man1/diffalla-patch.1` - Patch operations
   - ✅ `man/man1/diffalla-sync.1` - Synchronization
   - ✅ `man/man1/diffalla-export.1` - Export formats
   - ✅ `man/man1/diffalla-verify.1` - Verification

2. **README updates:**
   - ✅ Installation instructions (from source, SPM)
   - ✅ CLI Quick Start section (all 6 commands)
   - ✅ Common workflows (installer testing, deployment, monitoring)
   - ✅ Man page references
   - ✅ Updated CLI status (no longer "coming")

3. **Example scripts (4 total):**
   - ✅ `examples/verify-installer.sh` - Test installer impact
   - ✅ `examples/deploy-with-rollback.sh` - Safe deployment with rollback
   - ✅ `examples/bidirectional-sync.sh` - Two-way sync with conflicts
   - ✅ `examples/integrity-monitoring.sh` - Baseline monitoring
   - ✅ `examples/README.md` - Comprehensive usage guide

**Implementation:**
- All man pages render correctly with man(1)
- All example scripts are executable and documented
- README includes installation, quick start, and workflows
- Examples cover 4 major use cases with automation tips

**Exit Criteria:**
- ✅ All man pages created
- ✅ README has CLI section
- ✅ Example scripts work
- ✅ `man diffalla` works

---

### Step 10: Distribution & Packaging ✅ COMPLETE (Optional/Future)

**Goal:** Package for distribution

**Status:** ✅ Implemented and committed

**Deliverables:**
- ✅ Build script for release binaries (`Scripts/build-release.sh`)
  - Universal macOS binary (arm64 + x86_64)
  - Linux x86_64 binary
  - Distribution tarball with binaries, man pages, docs, examples
  - SHA256 checksums
- ✅ Homebrew formula (`Formula/diffalla.rb`)
  - Builds from source
  - Includes tests
- ✅ Installation script (`Scripts/install.sh`)
  - Source and binary installation
  - Custom PREFIX support
- ✅ GitHub Actions workflows
  - CI workflow (test on macOS/Linux)
  - Release workflow (automated releases)
- ✅ CHANGELOG.md for version tracking
- ✅ Scripts/README.md with distribution guide

**Tasks:**
1. ✅ Create `Scripts/build-release.sh`
2. ✅ Create Homebrew formula
3. ✅ Create installation script
4. ✅ Add GitHub Actions for releases

**Testing:**
- Build script creates working 1.1MB tarball
- Binary works correctly (universal, 2.7MB stripped)
- Checksum verification passes
- All 273 tests still pass

---

## Exit Criteria (Phase 5 Complete) ✅ ALL MET

### Functionality
- ✅ All 6 commands implemented and working
- ✅ All command-line flags functional
- ✅ Progress reporting works
- ✅ Error handling robust
- ✅ Exit codes correct

### Testing
- ✅ Integration tests pass (23 tests covering all commands)
- ✅ All 273 tests pass (250 library + 23 integration)
- ✅ All library tests still pass (no regressions)
- ✅ Manual testing completed

### Documentation
- ✅ Man pages for all commands (7 pages)
- ✅ README with CLI examples
- ✅ Example workflows (4 scripts)
- ✅ Comprehensive usage documentation

### Quality
- ✅ Help text clear and complete
- ✅ Error messages helpful
- ✅ Output formatted and colorized
- ✅ Cross-platform (macOS ready, Linux compatible)

---

## Estimated Timeline

**Total: 2-3 weeks (20-30 hours)**

| Step | Description | Time |
|------|-------------|------|
| 0 | Setup & Dependencies | 1-2h |
| 1 | Command Structure | 2-3h |
| 2 | Snapshot Command | 2-3h |
| 3 | Compare Command | 2-3h |
| 4 | Patch Command | 3-4h |
| 5 | Sync Command | 3-4h |
| 6 | Export & Verify | 2-3h |
| 7 | Output Formatting | 2-3h |
| 8 | Integration Tests | 2-3h |
| 9 | Documentation | 2-3h |
| 10 | Distribution (future) | TBD |

---

## Dependencies & Risks

**Dependencies:**
- `swift-argument-parser` (mature, maintained by Apple)
- Library APIs are stable and public

**Risks:**
- Cross-platform testing (need Linux VM/CI)
- Terminal capabilities vary (progress bars, colors)
- File path edge cases (spaces, special chars)

**Mitigation:**
- Start with macOS, add Linux support incrementally
- Use simple ASCII progress bars (fallback)
- Comprehensive path testing

---

## Success Metrics ✅ ALL ACHIEVED

**Phase 5 is complete when:**
1. ⏸️ User can run `brew install diffalla` (or equivalent) - **Deferred to Step 10**
2. ✅ All 6 commands work as documented
3. ✅ `man diffalla` shows complete documentation
4. ✅ Integration tests pass on macOS (23 tests)
5. ✅ Example workflows run successfully (4 scripts)
6. ✅ Zero library test regressions (all 273 tests pass)

**Additional achievements:**
- ✅ ANSI color support with auto-detection
- ✅ Comprehensive error handling with proper exit codes
- ✅ Dry-run support for all destructive operations
- ✅ Progress reporting for long operations
- ✅ Conflict resolution strategies for bidirectional sync
- ✅ Complete distribution infrastructure (Step 10)
- ✅ CI/CD automation with GitHub Actions
- ✅ Universal macOS binary (arm64 + x86_64)

---

**Document Status:** ✅ COMPLETE - All Steps 0-10 implemented
**Last Updated:** 2025-11-06 (Phase 5 fully complete including distribution)
**Next Steps:** Project complete and ready for distribution!
