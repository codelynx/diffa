# Getting Started with Diffa

A practical guide to using Diffa for directory snapshots, comparison, patching, and synchronization.

## Table of Contents

- [What is Diffa?](#what-is-diffa)
- [Installation](#installation)
- [Core Concepts](#core-concepts)
- [Basic Workflows](#basic-workflows)
- [Common Use Cases](#common-use-cases)
- [Command Reference](#command-reference)
- [Tips and Best Practices](#tips-and-best-practices)
- [Troubleshooting](#troubleshooting)

## What is Diffa?

Diffa is a command-line tool for:

- **Taking snapshots** of directories to capture their state
- **Comparing** directories or snapshots to see what changed
- **Creating patches** to transform one directory into another
- **Applying/reverting patches** to update directories
- **Synchronizing** directories while handling conflicts

Think of it as "Git for directories" - but simpler and focused on file system state rather than version control.

## Installation

See [README.md](README.md) for installation instructions. Quick options:

```bash
# macOS via Homebrew
brew install codelynx/tap/diffa

# Build from source (macOS/Linux)
git clone https://github.com/codelynx/Diffa.git
cd Diffa
swift build -c release
```

Verify installation:

```bash
diffa --version
```

## Core Concepts

### 1. Snapshots

A **snapshot** is a database file (`.diffa`) that captures the complete state of a directory at a point in time:

- File paths and names
- File sizes and modification times
- SHA-256 hashes (for detecting changes)
- File permissions
- Directory structure

Snapshots are lightweight (~200 bytes per file in memory) and enable fast comparisons without re-scanning directories.

### 2. Differences

A **difference** represents changes between two snapshots or directories:

- **Added**: Files that exist in destination but not in source
- **Removed**: Files that exist in source but not in destination
- **Modified**: Files that exist in both but have different content or metadata

### 3. Patches

A **patch** is a database file containing:

- Operations needed to transform source → destination
- Optional file content (for reversible patches)
- Metadata about the transformation

Patches can be applied to directories and optionally reverted.

### 4. Synchronization

**Sync** operations copy changes from source to destination:

- **Unidirectional**: Source → Destination (one-way)
- **Bidirectional**: Merge changes from both sides (two-way)
- **Conflict resolution**: Handles files changed in both locations

## Basic Workflows

### Workflow 1: Track Changes Over Time

**Scenario**: Monitor how your project evolves

```bash
# Day 1: Create initial snapshot
diffa snapshot ~/projects/myapp -o snapshots/day1.diffa

# Day 2: Create another snapshot
diffa snapshot ~/projects/myapp -o snapshots/day2.diffa

# Compare what changed
diffa compare snapshots/day1.diffa snapshots/day2.diffa

# See detailed diff
diffa compare snapshots/day1.diffa snapshots/day2.diffa --format diff
```

### Workflow 2: Backup and Verify

**Scenario**: Ensure your backup is complete and unchanged

```bash
# Create snapshot of source
diffa snapshot ~/important-files -o source.diffa

# Create backup
cp -r ~/important-files ~/backup/

# Verify backup matches
diffa verify source.diffa ~/backup/

# Or compare in detail
diffa compare ~/important-files ~/backup/ --summary
```

### Workflow 3: Distribute Updates

**Scenario**: Send changes to users without re-sending entire files

```bash
# Create patch from v1.0 to v1.1
diffa patch create v1.0/ v1.1/ -o update-1.1.patch --reversible

# User applies the patch to their v1.0 installation
diffa patch apply update-1.1.patch ~/apps/myapp/

# If something goes wrong, revert
diffa patch revert update-1.1.patch ~/apps/myapp/
```

### Workflow 4: Sync Directories

**Scenario**: Keep two directories in sync (like Dropbox folders)

```bash
# One-way sync: Update destination with source changes
diffa sync ~/documents ~/backup/documents

# Preview changes without applying (dry run)
diffa sync ~/documents ~/backup/documents --dry-run

# Two-way sync: Merge changes from both sides
diffa sync ~/laptop-files ~/desktop-files --bidirectional
```

## Common Use Cases

### Use Case 1: Website Deployment

Compare local development with production server:

```bash
# Snapshot local site
diffa snapshot ~/sites/mywebsite -o local.diffa

# Snapshot production (via SSH mount or rsync)
diffa snapshot /mnt/production/mywebsite -o production.diffa

# See what will change
diffa compare local.diffa production.diffa --summary

# Create deployment patch
diffa patch create production.diffa local.diffa -o deploy.patch

# Apply to production
diffa patch apply deploy.patch /mnt/production/mywebsite
```

### Use Case 2: Configuration Management

Track server configuration changes:

```bash
# Daily snapshot of /etc
diffa snapshot /etc -o /backup/etc-$(date +%Y%m%d).diffa

# Compare with yesterday
diffa compare /backup/etc-20250105.diffa /backup/etc-20250106.diffa

# See exactly what changed
diffa compare /backup/etc-20250105.diffa /backup/etc-20250106.diffa \
  --format diff > changes.diff
```

### Use Case 3: Code Release Management

Prepare release packages:

```bash
# Create snapshots for each version
diffa snapshot v1.0/ -o snapshots/v1.0.diffa
diffa snapshot v1.1/ -o snapshots/v1.1.diffa
diffa snapshot v1.2/ -o snapshots/v1.2.diffa

# Create upgrade patches
diffa patch create snapshots/v1.0.diffa snapshots/v1.1.diffa \
  -o patches/upgrade-1.0-to-1.1.patch --reversible

diffa patch create snapshots/v1.1.diffa snapshots/v1.2.diffa \
  -o patches/upgrade-1.1-to-1.2.patch --reversible

# Users can apply incremental updates
diffa patch apply patches/upgrade-1.0-to-1.1.patch ~/myapp/
diffa patch apply patches/upgrade-1.1-to-1.2.patch ~/myapp/
```

### Use Case 4: Data Migration

Migrate files between systems with verification:

```bash
# Source system
diffa snapshot /data/archives -o archives-source.diffa

# Transfer files and snapshot
rsync -av /data/archives remote:/data/archives
scp archives-source.diffa remote:

# Destination system - verify transfer
diffa verify archives-source.diffa /data/archives

# Or compare for any differences
diffa compare archives-source.diffa /data/archives --summary
```

### Use Case 5: Development Environment Setup

Standardize development environments:

```bash
# Create "golden" environment snapshot
diffa snapshot ~/dev-environment -o golden-env.diffa

# New team member sets up their environment
diffa snapshot ~/my-environment -o my-env.diffa

# See what's missing
diffa compare golden-env.diffa my-env.diffa --summary

# Sync to match golden environment
diffa sync ~/dev-environment ~/my-environment
```

## Command Reference

### Snapshot Command

```bash
diffa snapshot <directory> -o <output.diffa> [options]
```

**Options:**
- `--parallel` - Use parallel hashing for faster processing
- `--hash-cache <dir>` - Cache file hashes to speed up repeated snapshots
- `--no-follow-symlinks` - Don't follow symbolic links
- `--exclude-hidden` - Skip hidden files (starting with `.`)

**Examples:**

```bash
# Basic snapshot
diffa snapshot ~/Documents -o documents.diffa

# Fast snapshot with parallel hashing
diffa snapshot ~/large-project -o project.diffa --parallel

# With hash cache for repeated snapshots
diffa snapshot ~/project -o daily.diffa --hash-cache ~/.cache/diffa

# Skip hidden files and don't follow symlinks
diffa snapshot ~/code -o code.diffa \
  --exclude-hidden --no-follow-symlinks
```

### Compare Command

```bash
diffa compare <source> <destination> [options]
```

**Options:**
- `--summary` - Show summary counts only
- `--format <type>` - Output format: `text`, `json`, `html`, `diff`
- `--output <file>` - Save output to file

**Examples:**

```bash
# Compare two directories
diffa compare ~/old-version ~/new-version

# Compare snapshots
diffa compare old.diffa new.diffa --summary

# Export as JSON
diffa compare source.diffa dest.diffa --format json -o changes.json

# Export as HTML report
diffa compare v1.diffa v2.diffa --format html -o report.html

# Unix-style diff output
diffa compare v1.diffa v2.diffa --format diff -o changes.diff
```

### Verify Command

```bash
diffa verify <snapshot.diffa> <directory>
```

**Examples:**

```bash
# Verify backup matches snapshot
diffa verify original.diffa ~/backup/

# Verify with detailed output
diffa verify source.diffa /mnt/remote/ --show-diff
```

### Patch Command

#### Create Patch

```bash
diffa patch create <source> <destination> -o <patch-file> [options]
```

**Options:**
- `--reversible` - Include data needed to revert the patch

**Examples:**

```bash
# Create basic patch
diffa patch create v1.0/ v2.0/ -o upgrade.patch

# Create reversible patch
diffa patch create old.diffa new.diffa -o update.patch --reversible

# From snapshots
diffa patch create snapshot1.diffa snapshot2.diffa -o changes.patch
```

#### Apply Patch

```bash
diffa patch apply <patch-file> <target-directory> [options]
```

**Options:**
- `--dry-run` - Show what would change without applying
- `--force` - Apply even if validation fails

**Examples:**

```bash
# Preview changes
diffa patch apply update.patch ~/app/ --dry-run

# Apply patch
diffa patch apply update.patch ~/app/

# Force apply (careful!)
diffa patch apply risky.patch ~/data/ --force
```

#### Revert Patch

```bash
diffa patch revert <patch-file> <target-directory> [options]
```

**Options:**
- `--dry-run` - Show what would change without reverting

**Examples:**

```bash
# Revert a patch (requires --reversible flag during creation)
diffa patch revert update.patch ~/app/

# Preview revert
diffa patch revert update.patch ~/app/ --dry-run
```

### Sync Command

```bash
diffa sync <source> <destination> [options]
```

**Options:**
- `--bidirectional` - Two-way sync (merge changes from both sides)
- `--delete` - Delete files in destination not in source
- `--dry-run` - Preview changes without applying
- `--conflict <strategy>` - Conflict resolution: `newer`, `source`, `destination`, `ask`

**Examples:**

```bash
# One-way sync (source → destination)
diffa sync ~/source ~/destination

# Preview changes
diffa sync ~/source ~/destination --dry-run

# Two-way sync with conflict resolution
diffa sync ~/laptop ~/desktop \
  --bidirectional --conflict newer

# Sync with deletion
diffa sync ~/master ~/backup --delete

# Interactive conflict resolution
diffa sync ~/dir1 ~/dir2 \
  --bidirectional --conflict ask
```

### Export Command

```bash
diffa export <source> <destination> --format <type> -o <output>
```

**Formats:**
- `text` - Human-readable text
- `json` - Machine-readable JSON
- `html` - Styled HTML report
- `diff` - Unix diff format

**Examples:**

```bash
# Export comparison as JSON
diffa export v1.diffa v2.diffa --format json -o changes.json

# Export as HTML report
diffa export old/ new/ --format html -o report.html

# Export as diff
diffa export snapshot1.diffa snapshot2.diffa --format diff -o changes.diff
```

## Tips and Best Practices

### Performance Tips

1. **Use snapshots for repeated comparisons**
   ```bash
   # Good: Compare snapshots (fast)
   diffa snapshot dir1 -o s1.diffa
   diffa snapshot dir2 -o s2.diffa
   diffa compare s1.diffa s2.diffa  # Multiple times

   # Avoid: Re-scanning directories each time
   diffa compare dir1 dir2  # Rescans every time
   ```

2. **Enable parallel hashing for large directories**
   ```bash
   diffa snapshot ~/large-project -o snapshot.diffa --parallel
   ```

3. **Use hash cache for directories scanned frequently**
   ```bash
   # First scan is slower, subsequent scans are much faster
   diffa snapshot ~/project -o daily.diffa \
     --hash-cache ~/.cache/diffa
   ```

4. **Store snapshots outside the directory being snapshotted**
   ```bash
   # Good: Store elsewhere
   diffa snapshot ~/project -o ~/snapshots/project.diffa

   # Bad: Creates self-reference
   diffa snapshot ~/project -o ~/project/snapshot.diffa
   ```

### Workflow Tips

1. **Name snapshots with timestamps**
   ```bash
   diffa snapshot ~/data -o snapshots/$(date +%Y%m%d-%H%M%S).diffa
   ```

2. **Use dry-run before destructive operations**
   ```bash
   diffa patch apply update.patch ~/app/ --dry-run
   diffa sync source/ dest/ --dry-run --delete
   ```

3. **Create reversible patches for important changes**
   ```bash
   diffa patch create old/ new/ -o update.patch --reversible
   ```

4. **Verify backups after creation**
   ```bash
   rsync -av ~/important ~/backup/
   diffa verify ~/important ~/backup/
   ```

### Safety Tips

1. **Always backup before applying patches**
   ```bash
   cp -r ~/app ~/app.backup
   diffa patch apply update.patch ~/app/
   ```

2. **Test patches in staging first**
   ```bash
   cp -r production/ staging/
   diffa patch apply update.patch staging/
   # Test staging...
   diffa patch apply update.patch production/
   ```

3. **Keep snapshots for rollback**
   ```bash
   diffa snapshot ~/app -o pre-update.diffa
   diffa patch apply update.patch ~/app/
   # If issues occur:
   diffa patch create post-update.diffa pre-update.diffa -o rollback.patch
   ```

## Troubleshooting

### Problem: Snapshot creation is slow

**Solutions:**

1. Enable parallel hashing:
   ```bash
   diffa snapshot dir -o out.diffa --parallel
   ```

2. Use hash cache for repeated snapshots:
   ```bash
   diffa snapshot dir -o out.diffa --hash-cache ~/.cache/diffa
   ```

3. Exclude unnecessary files:
   ```bash
   diffa snapshot dir -o out.diffa --exclude-hidden
   ```

### Problem: "Permission denied" errors

**Solution:** Ensure you have read access to all files:

```bash
# Skip permission errors gracefully (they're logged but don't stop the snapshot)
diffa snapshot /restricted -o snapshot.diffa

# Or run with appropriate permissions
sudo diffa snapshot /etc -o etc-snapshot.diffa
```

### Problem: Patch won't apply

**Possible causes:**

1. **Target directory has been modified**
   ```bash
   # Check current state vs expected state
   diffa verify expected-state.diffa target-dir/
   ```

2. **Force apply (use carefully)**
   ```bash
   diffa patch apply update.patch target/ --force
   ```

3. **Files are locked or in use**
   - Close applications using the files
   - Reboot and try again

### Problem: Snapshot database is very large

**Causes and solutions:**

1. **Many large files in patch**
   - Large files (>1MB) are stored externally but referenced in DB
   - Check if external cache directory has space

2. **Reversible patches are larger**
   - They store original file content
   - Create non-reversible patches if revert isn't needed:
   ```bash
   diffa patch create old/ new/ -o update.patch
   # (omit --reversible)
   ```

### Problem: Sync conflicts

**Solution:** Choose conflict resolution strategy:

```bash
# Use newer file
diffa sync dir1 dir2 --bidirectional --conflict newer

# Always use source
diffa sync dir1 dir2 --bidirectional --conflict source

# Always use destination
diffa sync dir1 dir2 --bidirectional --conflict destination

# Ask for each conflict
diffa sync dir1 dir2 --bidirectional --conflict ask
```

### Problem: Different results on different platforms

**Cause:** Platform-specific file attributes (extended attributes, resource forks on macOS)

**Solution:** Diffa focuses on portable attributes:
- File content (SHA-256)
- Modification time
- File size
- Basic permissions

Extended attributes and platform-specific features are not tracked by default.

## Advanced Topics

### Scripting with Diffa

**Automated daily snapshots:**

```bash
#!/bin/bash
# daily-snapshot.sh

DATE=$(date +%Y%m%d)
SOURCE="$HOME/important-data"
SNAPSHOT_DIR="$HOME/snapshots"
SNAPSHOT="$SNAPSHOT_DIR/snapshot-$DATE.diffa"

# Create snapshot
diffa snapshot "$SOURCE" -o "$SNAPSHOT" --parallel

# Keep only last 30 days
find "$SNAPSHOT_DIR" -name "snapshot-*.diffa" -mtime +30 -delete

echo "Snapshot created: $SNAPSHOT"
```

**Monitoring for changes:**

```bash
#!/bin/bash
# monitor-changes.sh

BASELINE="baseline.diffa"
CURRENT="current.diffa"

# Create current snapshot
diffa snapshot /watched/directory -o "$CURRENT"

# Compare with baseline
if diffa compare "$BASELINE" "$CURRENT" --summary | grep -q "0 added, 0 removed, 0 modified"; then
    echo "No changes detected"
else
    echo "Changes detected!"
    diffa compare "$BASELINE" "$CURRENT" --format text
fi
```

### JSON Output for Integration

Process comparison results programmatically:

```bash
# Export to JSON
diffa compare old.diffa new.diffa --format json -o changes.json

# Process with jq
jq '.added | length' changes.json  # Count added files
jq '.modified[].path' changes.json  # List modified files
jq '.removed[] | select(.size > 1000000)' changes.json  # Large removed files
```

### Continuous Verification

Monitor backup integrity:

```bash
#!/bin/bash
# verify-backup.sh

SOURCE="/data/important"
BACKUP="/backup/important"
SNAPSHOT="/backup/snapshots/latest.diffa"

# Create fresh snapshot
diffa snapshot "$SOURCE" -o "$SNAPSHOT"

# Verify backup
if diffa verify "$SNAPSHOT" "$BACKUP"; then
    echo "✓ Backup verified successfully"
    exit 0
else
    echo "✗ Backup verification failed!"
    diffa compare "$SNAPSHOT" "$BACKUP" --format text
    exit 1
fi
```

## Getting Help

- **Documentation**: See [README.md](README.md) and [DESIGN.md](docs/DESIGN.md)
- **Command help**: `diffa --help` or `diffa <command> --help`
- **Issues**: Report bugs at [GitHub Issues](https://github.com/codelynx/Diffa/issues)
- **Examples**: Check `examples/` directory in the repository

## Next Steps

Now that you understand the basics:

1. **Try the examples** in this guide with test directories
2. **Integrate into your workflow** (backups, deployments, etc.)
3. **Automate with scripts** for repeated tasks
4. **Explore advanced features** like bidirectional sync and conflict resolution

Happy comparing! 🚀
