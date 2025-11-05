# CLI Tool Design: `diffalla`

**Date:** 2025-11-05
**Status:** Design phase - Phase 5 deliverable
**Target Platforms:** macOS, Linux

## Overview

The `diffalla` command-line tool is a thin wrapper around the Diffalla Swift library, providing rsync-like functionality for users who need a standalone tool rather than app integration.

**Design Philosophy:**
- Thin wrapper around library (minimal CLI-specific code)
- Familiar interface (inspired by rsync, git, diff)
- Cross-platform (macOS, Linux via Swift on Linux)
- Single binary, zero runtime dependencies

---

## Command Structure

### Top-Level Commands

```bash
diffalla <command> [options] [arguments]

Commands:
  snapshot      Create a snapshot of a directory
  compare       Compare two directories or snapshots
  patch         Create, apply, or revert patches
  sync          Synchronize directories
  export        Export comparison results in various formats
  verify        Verify a directory against a snapshot
  version       Show version information
  help          Show help for a command
```

---

## Command Reference

### 1. `diffalla snapshot`

Create a lightweight snapshot of a directory.

**Syntax:**
```bash
diffalla snapshot <directory> -o <output.sqlite> [options]
```

**Examples:**
```bash
# Create snapshot
diffalla snapshot /path/to/dir -o snapshot.sqlite

# Create with progress
diffalla snapshot /path/to/dir -o snapshot.sqlite --progress

# Exclude hidden files
diffalla snapshot /path/to/dir -o snapshot.sqlite --no-hidden

# Store symlinks as-is (don't follow)
diffalla snapshot /path/to/dir -o snapshot.sqlite --no-follow-symlinks

# Capture ownership (requires sudo to restore later)
sudo diffalla snapshot /etc -o snapshot.sqlite --with-ownership
```

**Options:**
- `-o, --output <file>` - Output SQLite database file (required)
- `-p, --progress` - Show progress during snapshot creation
- `--no-hidden` - Exclude hidden files (starting with .)
- `--no-follow-symlinks` - Store symlinks as-is (default: follow symlinks)
- `--with-ownership` - Capture owner/group (default: permissions only)
- `-q, --quiet` - Suppress output except errors

**Note:** Defaults finalized 2025-11-05. See `docs/decisions.md` for rationale.

**Output:**
```
Creating snapshot of /path/to/dir...
[████████████████████] 10,000 files (100%)
Snapshot saved to snapshot.sqlite (5.2 MB)
```

---

### 2. `diffalla compare`

Compare two directories or snapshots.

**Syntax:**
```bash
diffalla compare <source> <destination> [options]
```

**Examples:**
```bash
# Compare two directories (creates temporary snapshots)
diffalla compare /path/a /path/b

# Compare existing snapshots (fast)
diffalla compare snapshot-a.sqlite snapshot-b.sqlite

# Compare directory to snapshot
diffalla compare /path/a snapshot-b.sqlite

# Output to JSON
diffalla compare /path/a /path/b --format json -o result.json

# Show only summary
diffalla compare /path/a /path/b --summary
```

**Options:**
- `-f, --format <type>` - Output format: text, json, html, diff (default: text)
- `-o, --output <file>` - Write output to file (default: stdout)
- `-s, --summary` - Show summary only (counts)
- `--added` - Show only added files
- `--removed` - Show only removed files
- `--modified` - Show only modified files
- `-q, --quiet` - Suppress output (exit code only)

**Output (text format):**
```
Comparing /path/a → /path/b

Added (5):
  + new-file.txt
  + images/photo.png
  ...

Removed (3):
  - old-file.txt
  - data/cache.db
  ...

Modified (12):
  M config.json (size changed: 1.2 KB → 1.5 KB)
  M app.bin (content changed)
  ...

Summary:
  Added:    5 files (10.5 MB)
  Removed:  3 files (2.3 MB)
  Modified: 12 files (5.2 MB → 6.8 MB)
```

**Exit Codes:**
- `0` - No differences
- `1` - Differences found
- `2` - Error occurred

---

### 3. `diffalla patch`

Create, apply, or revert patches.

#### 3a. Create Patch

**Syntax:**
```bash
diffalla patch create <source> <destination> -o <patch.sqlite> [options]
```

**Examples:**
```bash
# Create patch from directories
diffalla patch create /old /new -o update.patch

# Create from snapshots (fast)
diffalla patch create old.sqlite new.sqlite -o update.patch

# Include revert data
diffalla patch create /old /new -o update.patch --with-revert

# External cache for large files
diffalla patch create /old /new -o update.patch --cache-dir /tmp/cache
```

**Options:**
- `-o, --output <file>` - Output patch file (SQLite database)
- `--with-revert` - Include revert data (default: true)
- `--no-revert` - Exclude revert data (smaller patches)
- `--cache-dir <dir>` - External cache for large files (default: none, inline)
- `--threshold <bytes>` - Inline threshold in bytes (default: 1048576 = 1MB)

---

#### 3b. Apply Patch

**Syntax:**
```bash
diffalla patch apply <patch.sqlite> <target-directory> [options]
```

**Examples:**
```bash
# Apply patch
diffalla patch apply update.patch /install/dir

# Dry-run (preview without changes)
diffalla patch apply update.patch /install/dir --dry-run

# With progress
diffalla patch apply update.patch /install/dir --progress
```

**Options:**
- `-n, --dry-run` - Show what would be done without making changes
- `-p, --progress` - Show progress during application
- `-f, --force` - Apply even if target doesn't match expected state
- `--verify` - Verify patch integrity before applying

**Output:**
```
Applying patch to /install/dir...
[████████████████████] 100 operations (100%)
Applied successfully:
  5 files added (10.5 MB)
  3 files removed
  12 files modified (6.8 MB)
```

---

#### 3c. Revert Patch

**Syntax:**
```bash
diffalla patch revert <patch.sqlite> <target-directory> [options]
```

**Examples:**
```bash
# Revert patch
diffalla patch revert update.patch /install/dir

# Dry-run
diffalla patch revert update.patch /install/dir --dry-run
```

**Options:**
- `-n, --dry-run` - Show what would be done without making changes
- `-p, --progress` - Show progress during revert
- `-f, --force` - Revert even if target state unexpected

---

### 4. `diffalla sync`

Synchronize directories.

**Syntax:**
```bash
diffalla sync <source> <destination> [options]
```

**Examples:**
```bash
# Unidirectional sync (source → destination)
diffalla sync /source /dest

# Bidirectional sync
diffalla sync /dir-a /dir-b --bidirectional

# With conflict resolution strategy
diffalla sync /dir-a /dir-b --bidirectional --conflicts newest

# Dry-run
diffalla sync /source /dest --dry-run

# Delete extraneous files in destination
diffalla sync /source /dest --delete
```

**Options:**
- `-b, --bidirectional` - Two-way sync (default: unidirectional)
- `-n, --dry-run` - Show what would be done without making changes
- `-p, --progress` - Show progress during sync
- `--delete` - Delete extraneous files in destination
- `--conflicts <strategy>` - Conflict resolution: newest, source-wins, dest-wins, keep-both, error (default: error)
- `--no-move-detection` - Disable move detection optimization

**Output:**
```
Syncing /source → /dest...
[████████████████████] 10,000 files (100%)
Sync completed:
  50 files copied (120 MB)
  10 files deleted
  5 files moved/renamed
  0 conflicts
Time: 45.2s
```

---

### 5. `diffalla export`

Export comparison results in various formats.

**Syntax:**
```bash
diffalla export <patch.sqlite> -f <format> -o <output> [options]
```

**Examples:**
```bash
# Export as HTML
diffalla export update.patch -f html -o report.html

# Export as JSON
diffalla export update.patch -f json -o data.json

# Export as unified diff
diffalla export update.patch -f diff -o changes.diff

# Export as text
diffalla export update.patch -f text -o summary.txt
```

**Options:**
- `-f, --format <type>` - Format: text, json, html, diff (required)
- `-o, --output <file>` - Output file (default: stdout)
- `--preview-lines <n>` - Max preview lines in HTML (default: 50)

---

### 6. `diffalla verify`

Verify a directory against a snapshot.

**Syntax:**
```bash
diffalla verify <directory> <snapshot.sqlite> [options]
```

**Examples:**
```bash
# Verify directory matches snapshot
diffalla verify /path/to/dir snapshot.sqlite

# Show differences if any
diffalla verify /path/to/dir snapshot.sqlite --show-diff

# Quiet (exit code only)
diffalla verify /path/to/dir snapshot.sqlite --quiet
```

**Options:**
- `-s, --show-diff` - Show differences if verification fails
- `-q, --quiet` - Suppress output (exit code only)

**Output:**
```
Verifying /path/to/dir against snapshot.sqlite...
✓ Verification passed: No changes detected
```

**Exit Codes:**
- `0` - Verification passed (no changes)
- `1` - Verification failed (changes detected)
- `2` - Error occurred

---

### 7. `diffalla version`

Show version information.

**Syntax:**
```bash
diffalla version [--verbose]
```

**Output:**
```
diffalla version 1.0.0
Library version: 1.0.0
SQLite version: 3.43.0
Platform: macOS 14.0 (arm64)
```

---

### 8. `diffalla help`

Show help for a command.

**Syntax:**
```bash
diffalla help [command]
```

**Examples:**
```bash
diffalla help
diffalla help snapshot
diffalla help sync
```

---

## Global Options

Available for all commands:

- `-h, --help` - Show help for the command
- `-V, --version` - Show version information
- `-v, --verbose` - Verbose output (debug information)
- `-q, --quiet` - Suppress non-error output
- `--color <when>` - Colorize output: auto, always, never (default: auto)

---

## Environment Variables

- `DIFFALLA_CACHE_DIR` - Default cache directory for patches
- `DIFFALLA_INLINE_THRESHOLD` - Default inline threshold in bytes
- `DIFFALLA_NO_COLOR` - Disable colored output (set to 1)

---

## Configuration File

Optional configuration file: `~/.diffallarc` (JSON format)

**Example:**
```json
{
  "snapshot": {
    "followSymlinks": true,
    "includeHidden": true,
    "captureOwnership": false
  },
  "patch": {
    "withRevert": true,
    "cacheDir": "/tmp/diffalla-cache",
    "inlineThreshold": 1048576
  },
  "sync": {
    "conflictResolution": "newest",
    "moveDetection": true
  }
}
```

**Note:** Defaults finalized 2025-11-05. See `docs/decisions.md` for rationale.

---

## Examples: Common Workflows

### Workflow 1: Verify Installer Output

```bash
# Before install
diffalla snapshot /Applications -o before.sqlite

# Run installer
./installer.pkg

# After install
diffalla snapshot /Applications -o after.sqlite

# See what changed
diffalla compare before.sqlite after.sqlite
```

---

### Workflow 2: Deploy with Rollback

```bash
# Create deployment patch
diffalla patch create /current-version /new-version -o deploy.patch

# Apply to production
diffalla patch apply deploy.patch /production --progress

# If issues, rollback
diffalla patch revert deploy.patch /production
```

---

### Workflow 3: Bidirectional Sync with Conflict Resolution

```bash
# Sync laptop ↔ desktop
diffalla sync ~/Documents /mnt/desktop/Documents --bidirectional --conflicts newest

# Dry-run first to preview
diffalla sync ~/Documents /mnt/desktop/Documents --bidirectional --dry-run
```

---

### Workflow 4: Integrity Monitoring

```bash
# Create baseline snapshot
diffalla snapshot /etc -o baseline.sqlite

# Later, verify no unauthorized changes
diffalla verify /etc baseline.sqlite

# If changes detected, show what changed
diffalla verify /etc baseline.sqlite --show-diff
```

---

### Workflow 5: Generate Deployment Report

```bash
# Create patch
diffalla patch create v1.0 v1.1 -o update.patch

# Export as HTML for review
diffalla export update.patch -f html -o deployment-report.html

# Open in browser
open deployment-report.html
```

---

## Implementation Notes

### Architecture

```
┌─────────────────────────────────────────┐
│  CLI Binary (diffalla)                  │
│  - Argument parsing (swift-argument-parser)
│  - Command dispatch                     │
│  - Progress formatting                  │
│  - Exit code handling                   │
└─────────────────────────────────────────┘
                   ↓
┌─────────────────────────────────────────┐
│  Diffalla Library (Swift Package)       │
│  - Snapshot, Comparison, Patching, Sync │
│  - SQLite wrapper                       │
│  - Core algorithms                      │
└─────────────────────────────────────────┘
```

**CLI is a thin wrapper:**
- Parse arguments using `swift-argument-parser`
- Call library functions
- Format output (progress bars, tables, colors)
- Handle exit codes

**Benefits:**
- CLI and library stay in sync (single codebase)
- Easy to test (CLI just calls library)
- Users can choose: CLI tool or embed library

---

### Dependencies

**CLI-specific dependencies:**
- `swift-argument-parser` - Argument parsing
- `swift-log` - Logging (optional, for --verbose)
- Terminal UI helpers (progress bars, colors)

**Library dependencies:**
- None (zero external dependencies)

---

### Distribution

**macOS:**
- Homebrew formula: `brew install diffalla`
- DMG with binary: Install to `/usr/local/bin/diffalla`
- Swift Package Manager: `swift build -c release`

**Linux:**
- APT package: `sudo apt install diffalla`
- RPM package: `sudo yum install diffalla`
- Static binary: Download and copy to `/usr/local/bin/`

**From Source:**
```bash
git clone https://github.com/user/diffalla.git
cd diffalla
swift build -c release
cp .build/release/diffalla /usr/local/bin/
```

---

### Phase 5 Implementation Plan

**Step 1: CLI Structure (Week 1)**
- Create `Sources/diffalla-cli/` target
- Add `swift-argument-parser` dependency
- Implement argument parsing for all commands
- Wire up to library functions

**Step 2: Output Formatting (Week 1)**
- Progress bars (for --progress)
- Tables (for compare output)
- Colors (for added/removed/modified)
- Exit codes

**Step 3: Testing (Week 2)**
- Integration tests (execute CLI, check output)
- Test all commands with various flags
- Test error cases
- Test across platforms (macOS, Linux)

**Step 4: Documentation (Week 2)**
- Man pages (diffalla.1, diffalla-snapshot.1, etc.)
- README with examples
- Homebrew formula
- Packaging scripts

**Step 5: Distribution (Week 3)**
- GitHub releases (binaries for macOS/Linux)
- Homebrew tap
- APT/RPM packages (optional)
- CI/CD for automated builds

---

## Exit Codes Convention

Consistent exit codes across all commands:

- `0` - Success
- `1` - Differences found / verification failed (expected failure)
- `2` - Invalid arguments / usage error
- `3` - File not found / I/O error
- `4` - Permission denied
- `5` - Operation cancelled by user
- `6` - Internal error / unexpected failure

---

## Comparison to rsync CLI

| Feature | rsync | diffalla |
|---------|-------|----------|
| Syntax | `rsync [options] source dest` | `diffalla sync source dest [options]` |
| Dry-run | `-n, --dry-run` | `-n, --dry-run` ✅ |
| Progress | `--progress` | `-p, --progress` ✅ |
| Delete | `--delete` | `--delete` ✅ |
| Verbose | `-v, --verbose` | `-v, --verbose` ✅ |
| Bidirectional | Run twice manually | `--bidirectional` ✅ |
| Conflicts | N/A | `--conflicts <strategy>` ✅ |
| Snapshot | N/A | `diffalla snapshot` ✅ |
| Verify | N/A | `diffalla verify` ✅ |
| Patch | N/A | `diffalla patch` ✅ |

**Advantages over rsync CLI:**
- ✅ Snapshot and verify commands
- ✅ Reversible patches
- ✅ Bidirectional sync built-in
- ✅ Multiple conflict strategies
- ✅ Export formats (HTML/JSON)

**rsync advantages:**
- ✅ Network sync (SSH)
- ✅ Block-level delta
- ✅ Ubiquitous (installed everywhere)
- ✅ Mature (30+ years)

---

## Future Enhancements (Post-1.0)

**Phase 6+ potential additions:**

1. **Watch mode:** `diffalla watch <dir> --snapshot baseline.sqlite --alert`
2. **Remote sync:** `diffalla sync local-dir user@host:/remote-dir`
3. **Compression:** `diffalla snapshot --compress zstd`
4. **Ignore patterns:** `diffalla snapshot --ignore .diffallaignore`
5. **Interactive mode:** `diffalla sync --interactive` (prompt for each file)
6. **Daemon mode:** `diffallad --config sync-config.json`

---

## Documentation Deliverables

**Phase 5 includes:**

1. ✅ Man pages (all commands)
2. ✅ README with examples
3. ✅ Tutorial (common workflows)
4. ✅ Migration guide (from rsync/git)
5. ✅ Homebrew formula
6. ✅ Installation instructions

---

**Document Status:** Complete - Phase 5 design spec
**Last Updated:** 2025-11-05
**Next Review:** Before Phase 5 implementation
**Dependencies:** Phase 1-4 library complete
