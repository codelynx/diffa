# CLI Tool Design: `diffa`

**Date:** 2025-11-05
**Status:** Design phase - Phase 5 deliverable
**Target Platforms:** macOS, Linux

## Overview

The `diffa` command-line tool is a thin wrapper around the Diffa Swift library, providing rsync-like functionality for users who need a standalone tool rather than app integration.

**Design Philosophy:**
- Thin wrapper around library (minimal CLI-specific code)
- Familiar interface (inspired by rsync, git, diff)
- Cross-platform (macOS, Linux via Swift on Linux)
- Single binary, zero runtime dependencies

---

## Command Structure

### Top-Level Commands

```bash
diffa <command> [options] [arguments]

Commands:
  snapshot      Create a snapshot of a directory
  compare       Compare two directories or snapshots
  patch         Create, apply, or revert patches
  sync          Synchronize directories
  export        Export comparison results in various formats
  verify        Verify a directory against a snapshot
  serve         Start sync server daemon (network sync)
  push          Push local directory to remote server
  pull          Pull remote directory to local
  version       Show version information
  help          Show help for a command
```

---

## Command Reference

### 1. `diffa snapshot`

Create a lightweight snapshot of a directory.

**Syntax:**
```bash
diffa snapshot <directory> -o <output.diffa> [options]
```

**Examples:**
```bash
# Create snapshot
diffa snapshot /path/to/dir -o snapshot.diffa

# Create with progress
diffa snapshot /path/to/dir -o snapshot.diffa --progress

# Exclude hidden files
diffa snapshot /path/to/dir -o snapshot.diffa --no-hidden

# Store symlinks as-is (don't follow)
diffa snapshot /path/to/dir -o snapshot.diffa --no-follow-symlinks

# Capture ownership (requires sudo to restore later)
sudo diffa snapshot /etc -o snapshot.diffa --with-ownership
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
Snapshot saved to snapshot.diffa (5.2 MB)
```

---

### 2. `diffa compare`

Compare two directories or snapshots.

**Syntax:**
```bash
diffa compare <source> <destination> [options]
```

**Examples:**
```bash
# Compare two directories (creates temporary snapshots)
diffa compare /path/a /path/b

# Compare existing snapshots (fast)
diffa compare snapshot-a.diffa snapshot-b.diffa

# Compare directory to snapshot
diffa compare /path/a snapshot-b.diffa

# Output to JSON
diffa compare /path/a /path/b --format json -o result.json

# Show only summary
diffa compare /path/a /path/b --summary
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
  - data/cache.diffa
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

### 3. `diffa patch`

Create, apply, or revert patches.

#### 3a. Create Patch

**Syntax:**
```bash
diffa patch create <source> <destination> -o <patch-file> [options]
```

**Examples:**
```bash
# Create patch from directories
diffa patch create /old /new -o update.patch

# Create from snapshots (fast)
diffa patch create old.diffa new.diffa -o update.patch

# Include revert data
diffa patch create /old /new -o update.patch --with-revert

# External cache for large files
diffa patch create /old /new -o update.patch --cache-dir /tmp/cache
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
diffa patch apply <patch-file> <target-directory> [options]
```

**Examples:**
```bash
# Apply patch
diffa patch apply update.patch /install/dir

# Dry-run (preview without changes)
diffa patch apply update.patch /install/dir --dry-run

# With progress
diffa patch apply update.patch /install/dir --progress
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
diffa patch revert <patch-file> <target-directory> [options]
```

**Examples:**
```bash
# Revert patch
diffa patch revert update.patch /install/dir

# Dry-run
diffa patch revert update.patch /install/dir --dry-run
```

**Options:**
- `-n, --dry-run` - Show what would be done without making changes
- `-p, --progress` - Show progress during revert
- `-f, --force` - Revert even if target state unexpected

---

### 4. `diffa sync`

Synchronize directories.

**Syntax:**
```bash
diffa sync <source> <destination> [options]
```

**Examples:**
```bash
# Unidirectional sync (source → destination)
diffa sync /source /dest

# Bidirectional sync
diffa sync /dir-a /dir-b --bidirectional

# With conflict resolution strategy
diffa sync /dir-a /dir-b --bidirectional --conflicts newest

# Dry-run
diffa sync /source /dest --dry-run

# Delete extraneous files in destination
diffa sync /source /dest --delete
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

### 5. `diffa export`

Export comparison results in various formats.

**Syntax:**
```bash
diffa export <patch-file> -f <format> -o <output> [options]
```

**Examples:**
```bash
# Export as HTML
diffa export update.patch -f html -o report.html

# Export as JSON
diffa export update.patch -f json -o data.json

# Export as unified diff
diffa export update.patch -f diff -o changes.diff

# Export as text
diffa export update.patch -f text -o summary.txt
```

**Options:**
- `-f, --format <type>` - Format: text, json, html, diff (required)
- `-o, --output <file>` - Output file (default: stdout)
- `--preview-lines <n>` - Max preview lines in HTML (default: 50)

---

### 6. `diffa verify`

Verify a directory against a snapshot.

**Syntax:**
```bash
diffa verify <directory> <snapshot.diffa> [options]
```

**Examples:**
```bash
# Verify directory matches snapshot
diffa verify /path/to/dir snapshot.diffa

# Show differences if any
diffa verify /path/to/dir snapshot.diffa --show-diff

# Quiet (exit code only)
diffa verify /path/to/dir snapshot.diffa --quiet
```

**Options:**
- `-s, --show-diff` - Show differences if verification fails
- `-q, --quiet` - Suppress output (exit code only)

**Output:**
```
Verifying /path/to/dir against snapshot.diffa...
✓ Verification passed: No changes detected
```

**Exit Codes:**
- `0` - Verification passed (no changes)
- `1` - Verification failed (changes detected)
- `2` - Error occurred

---

### 7. `diffa serve`

Start a sync server daemon for network synchronization.

**Syntax:**
```bash
diffa serve --path <directory> --port <port>
```

**Examples:**
```bash
# Start server on default port 8080
diffa serve --path /path/to/sync --port 8080

# Server displays connection info
# Connect using:
#   diffa push <local-dir> 192.168.1.100:8080
#   diffa pull <local-dir> 192.168.1.100:8080
```

**Options:**
- `--path <dir>` - Directory to serve (required)
- `-p, --port <port>` - Port to listen on (default: 8080)

**Output:**
```
Starting Diffa sync server...
  Path: /path/to/sync
  Port: 8080

Server listening on port 8080
Serving: /path/to/sync

Connect using:
  diffa push <local-dir> 192.168.1.100:8080
  diffa pull <local-dir> 192.168.1.100:8080
```

**Notes:**
- Files >4KB are automatically compressed during transfer (ZLIB)
- Already-compressed files (jpg, mp4, zip, etc.) are sent as-is
- Log shows compression ratios: `Uploading: file.swift (15000 → 3200 bytes, 78% saved)`

---

### 8. `diffa push`

Push local directory contents to a remote server. Creates a **true mirror** - remote will match local exactly.

> **Warning:** Files that exist only on the remote server will be **deleted**. This is destructive. Make backups before pushing if needed.

**Syntax:**
```bash
diffa push <local-path> <host:port>
```

**Examples:**
```bash
# Push local directory to remote server
diffa push ~/Documents/project 192.168.1.100:8080

# Push to localhost (testing)
diffa push /local/path localhost:8080
```

**Arguments:**
- `<local-path>` - Local directory to push
- `<host:port>` - Remote server address (e.g., 192.168.1.100:8080)

**Output:**
```
Pushing /local/path to 192.168.1.100:8080...

Connecting to 192.168.1.100:8080...
Connected!
Handshake complete
Creating local snapshot...
Local files: 184
Remote files: 10
Operations: 187
Uploading: file1.txt
Uploading: file2.txt
Deleting (remote): old-file.txt
...
Sync complete!
```

---

### 9. `diffa pull`

Pull remote directory contents to local. Creates a **true mirror** - local will match remote exactly.

> **Warning:** Files that exist only on the local directory will be **deleted**. This is destructive. Make backups before pulling if needed.

**Syntax:**
```bash
diffa pull <local-path> <host:port>
```

**Examples:**
```bash
# Pull from remote server to local directory
diffa pull ~/Documents/backup 192.168.1.100:8080

# Pull to empty directory (full clone)
mkdir /new/local/dir
diffa pull /new/local/dir 192.168.1.100:8080
```

**Arguments:**
- `<local-path>` - Local directory to sync to
- `<host:port>` - Remote server address (e.g., 192.168.1.100:8080)

**Output:**
```
Pulling from 192.168.1.100:8080 to /local/path...

Connecting to 192.168.1.100:8080...
Connected!
Handshake complete
Creating local snapshot...
Local files: 10
Remote files: 184
Operations: 187
Downloading: file1.txt
Downloading: file2.txt
Deleting (local): old-local-file.txt
...
Sync complete!
```

---

### 10. `diffa version`

Show version information.

**Syntax:**
```bash
diffa version [--verbose]
```

**Output:**
```
diffa version 1.0.0
Library version: 1.0.0
SQLite version: 3.43.0
Platform: macOS 14.0 (arm64)
```

---

### 11. `diffa help`

Show help for a command.

**Syntax:**
```bash
diffa help [command]
```

**Examples:**
```bash
diffa help
diffa help snapshot
diffa help sync
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

- `DIFFA_CACHE_DIR` - Default cache directory for patches
- `DIFFA_INLINE_THRESHOLD` - Default inline threshold in bytes
- `DIFFA_NO_COLOR` - Disable colored output (set to 1)

---

## Configuration File

Optional configuration file: `~/.diffarc` (JSON format)

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
    "cacheDir": "/tmp/diffa-cache",
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
diffa snapshot /Applications -o before.diffa

# Run installer
./installer.pkg

# After install
diffa snapshot /Applications -o after.diffa

# See what changed
diffa compare before.diffa after.diffa
```

---

### Workflow 2: Deploy with Rollback

```bash
# Create deployment patch
diffa patch create /current-version /new-version -o deploy.patch

# Apply to production
diffa patch apply deploy.patch /production --progress

# If issues, rollback
diffa patch revert deploy.patch /production
```

---

### Workflow 3: Bidirectional Sync with Conflict Resolution

```bash
# Sync laptop ↔ desktop
diffa sync ~/Documents /mnt/desktop/Documents --bidirectional --conflicts newest

# Dry-run first to preview
diffa sync ~/Documents /mnt/desktop/Documents --bidirectional --dry-run
```

---

### Workflow 4: Integrity Monitoring

```bash
# Create baseline snapshot
diffa snapshot /etc -o baseline.diffa

# Later, verify no unauthorized changes
diffa verify /etc baseline.diffa

# If changes detected, show what changed
diffa verify /etc baseline.diffa --show-diff
```

---

### Workflow 5: Generate Deployment Report

```bash
# Create patch
diffa patch create v1.0 v1.1 -o update.patch

# Export as HTML for review
diffa export update.patch -f html -o deployment-report.html

# Open in browser
open deployment-report.html
```

---

## Implementation Notes

### Architecture

```
┌─────────────────────────────────────────┐
│  CLI Binary (diffa)                  │
│  - Argument parsing (swift-argument-parser)
│  - Command dispatch                     │
│  - Progress formatting                  │
│  - Exit code handling                   │
└─────────────────────────────────────────┘
                   ↓
┌─────────────────────────────────────────┐
│  Diffa Library (Swift Package)       │
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
- Homebrew formula: `brew install diffa`
- DMG with binary: Install to `/usr/local/bin/diffa`
- Swift Package Manager: `swift build -c release`

**Linux:**
- APT package: `sudo apt install diffa`
- RPM package: `sudo yum install diffa`
- Static binary: Download and copy to `/usr/local/bin/`

**From Source:**
```bash
git clone https://github.com/user/diffa.git
cd diffa
swift build -c release
cp .build/release/diffa /usr/local/bin/
```

---

### Phase 5 Implementation Plan

**Step 1: CLI Structure (Week 1)**
- Create `Sources/diffa-cli/` target
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
- Man pages (diffa.1, diffa-snapshot.1, etc.)
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

| Feature | rsync | diffa |
|---------|-------|----------|
| Syntax | `rsync [options] source dest` | `diffa sync source dest [options]` |
| Dry-run | `-n, --dry-run` | `-n, --dry-run` ✅ |
| Progress | `--progress` | `-p, --progress` ✅ |
| Delete | `--delete` | `--delete` ✅ |
| Verbose | `-v, --verbose` | `-v, --verbose` ✅ |
| Bidirectional | Run twice manually | `--bidirectional` ✅ |
| Conflicts | N/A | `--conflicts <strategy>` ✅ |
| Snapshot | N/A | `diffa snapshot` ✅ |
| Verify | N/A | `diffa verify` ✅ |
| Patch | N/A | `diffa patch` ✅ |

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

**Implemented in Phase 7:**
- ✅ **Network sync:** `diffa serve`, `diffa push`, `diffa pull`
- ✅ **Daemon mode:** `diffa serve --path /dir --port 8080`

**Potential future additions:**

1. **Watch mode:** `diffa watch <dir> --snapshot baseline.diffa --alert`
2. **SSH sync:** `diffa sync local-dir user@host:/remote-dir` (via SSH tunnel)
3. **Compression:** `diffa snapshot --compress zstd`
4. **Ignore patterns:** `diffa snapshot --ignore .diffaignore`
5. **Interactive mode:** `diffa sync --interactive` (prompt for each file)
6. **Web UI:** Browser-based server status dashboard

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

**Document Status:** Updated - Phase 7 implemented
**Last Updated:** 2025-12-17
**Version:** 0.12.0
**Dependencies:** All phases (0-7) complete
