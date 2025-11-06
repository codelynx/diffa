# Diffa Snapshots Module

Create and manage SQLite-based directory snapshots.

## Overview

The Snapshots module provides efficient directory scanning and snapshot creation. Snapshots are stored as SQLite databases, allowing for fast queries and minimal memory usage even with large file sets.

## Quick Start

```swift
import Diffa

// Create a snapshot
let engine = SnapshotEngine()
let options = ScanOptions(
    followSymlinks: true,
    includeHidden: true,
    captureOwnership: false
)

let snapshot = try await engine.createSnapshot(
    from: URL(fileURLWithPath: "/path/to/directory"),
    saveTo: URL(fileURLWithPath: "snapshot.snapshot"),
    options: options
)

// View metadata
print("Files: \(snapshot.metadata.totalFiles)")
print("Folders: \(snapshot.metadata.totalFolders)")
print("Total size: \(snapshot.metadata.totalSize) bytes")

// Load items
let allItems = try snapshot.loadAllItems()
let specificItem = try snapshot.loadItem(path: "subdir/file.txt")
```

## Key Types

### SnapshotEngine

Engine for scanning directories and creating snapshots.

```swift
let engine = SnapshotEngine()

// Create snapshot with progress tracking
let snapshot = try await engine.createSnapshot(
    from: directoryURL,
    saveTo: snapshotURL,
    options: options,
    progress: { progress in
        print("Processing: \(progress.currentPath)")
        print("Files: \(progress.filesProcessed)")
        print("Bytes: \(progress.bytesProcessed)")
    }
)
```

**Methods:**
- `scanDirectory(at:options:progress:)` - Scan directory and return items in memory
- `createSnapshot(from:saveTo:options:progress:)` - Create snapshot database

**Performance:**
- Streams items to database during scan (memory-efficient)
- O(depth) memory usage regardless of total item count
- ~1,000 files/second typical throughput on SSD

### Snapshot

A snapshot of a directory at a point in time, stored as SQLite database.

```swift
// Create new snapshot
let snapshot = try Snapshot.create(at: url, rootPath: "/path/to/dir")

// Open existing snapshot
let snapshot = try Snapshot.open(at: url)

// Query snapshot
let metadata = snapshot.metadata
let allItems = try snapshot.loadAllItems()
let item = try snapshot.loadItem(path: "relative/path.txt")
let children = try snapshot.loadChildren(of: parentId)
```

**Properties:**
- `databaseURL: URL` - Path to SQLite database file
- `rootPath: String` - Root directory path that was snapshotted
- `createdDate: Date` - Snapshot creation timestamp
- `metadata: SnapshotMetadata` - File counts and total size

**Methods:**
- `create(at:rootPath:)` - Create new empty snapshot database
- `open(at:)` - Open existing snapshot database
- `loadAllItems()` - Load all items from snapshot
- `loadItem(path:)` - Load specific item by relative path
- `loadChildren(of:)` - Load direct children of a folder

### SnapshotItem

Representation of a file/folder loaded from a snapshot database.

```swift
struct SnapshotItem {
    let id: Int64              // Database row ID
    let parentId: Int64?       // Parent folder ID (nil for root-level)
    let path: String           // Relative path from snapshot root
    let name: String           // File/folder name
    let isFolder: Bool         // True for directories
    let size: Int64            // Size in bytes
    let modificationDate: Date // Last modification date
    let permissions: FilePermissions // File permissions
    let owner: String?         // Owner (nil unless captured)
    let group: String?         // Group (nil unless captured)
    let sha256: String?        // SHA-256 hash (nil for folders)
}
```

### SnapshotMetadata

Summary metadata about a snapshot.

```swift
struct SnapshotMetadata {
    let totalFiles: Int       // Total number of files
    let totalFolders: Int     // Total number of folders
    let totalSize: Int64      // Total size in bytes
    let version: Int          // Schema version
}
```

### SnapshotProgress

Progress information during directory scanning.

```swift
struct SnapshotProgress {
    let currentPath: String      // Current file being processed
    let filesProcessed: Int      // Files processed so far
    let bytesProcessed: Int64    // Bytes processed so far
}
```

## Database Schema

Snapshots are stored as SQLite databases with the following schema:

### schema_version Table
```sql
CREATE TABLE schema_version (
    version INTEGER PRIMARY KEY,
    created_date INTEGER NOT NULL,  -- Unix timestamp
    library_version TEXT NOT NULL
);
```

### metadata Table
```sql
CREATE TABLE metadata (
    root_path TEXT PRIMARY KEY,
    created_date INTEGER NOT NULL,  -- Unix timestamp
    total_files INTEGER NOT NULL,
    total_folders INTEGER NOT NULL,
    total_size INTEGER NOT NULL
);
```

### items Table
```sql
CREATE TABLE items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    parent_id INTEGER REFERENCES items(id),
    path TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    is_folder INTEGER NOT NULL,
    size INTEGER NOT NULL,
    modification_date INTEGER NOT NULL,  -- Unix timestamp
    permissions INTEGER NOT NULL,        -- POSIX octal
    owner TEXT,
    group_name TEXT,
    sha256 TEXT
);

CREATE INDEX idx_items_path ON items(path);
CREATE INDEX idx_items_parent ON items(parent_id);
CREATE INDEX idx_items_sha256 ON items(sha256);
```

**Design Decisions:**
- Unix timestamps for cross-platform compatibility and efficient storage
- POSIX permissions as INTEGER for compact storage
- Hierarchical parent_id relationships for efficient tree traversal
- Indexes on path, parent_id, and sha256 for fast queries

## Usage Patterns

### Basic Snapshot Creation

```swift
let engine = SnapshotEngine()
let options = ScanOptions()

let snapshot = try await engine.createSnapshot(
    from: URL(fileURLWithPath: "/Users/alice/Documents"),
    saveTo: URL(fileURLWithPath: "documents.snapshot"),
    options: options
)
```

### With Progress Tracking

```swift
let snapshot = try await engine.createSnapshot(
    from: directoryURL,
    saveTo: snapshotURL,
    options: options,
    progress: { progress in
        let percentage = Double(progress.filesProcessed) / Double(estimatedTotal) * 100
        print("\(percentage)%: \(progress.currentPath)")
    }
)
```

### Querying Snapshots

```swift
// Open existing snapshot
let snapshot = try Snapshot.open(at: snapshotURL)

// Get metadata
let meta = snapshot.metadata
print("Snapshot contains \(meta.totalFiles) files")

// Find specific file
if let file = try snapshot.loadItem(path: "config.json") {
    print("Found: \(file.name)")
    print("Size: \(file.size) bytes")
    print("Modified: \(file.modificationDate)")
}

// List all items (ordered by path)
let allItems = try snapshot.loadAllItems()
for item in allItems {
    let type = item.isFolder ? "DIR" : "FILE"
    print("\(type): \(item.path)")
}

// Browse directory structure
let rootItem = try snapshot.loadItem(path: "subdir")
if let rootItem = rootItem {
    let children = try snapshot.loadChildren(of: rootItem.id)
    for child in children {
        print("  \(child.name)")
    }
}
```

### Custom Scan Options

```swift
// Capture everything, including ownership
let fullOptions = ScanOptions(
    followSymlinks: true,
    includeHidden: true,
    captureOwnership: true
)

// Minimal snapshot (no hidden files, no symlink following)
let minimalOptions = ScanOptions(
    followSymlinks: false,
    includeHidden: false,
    captureOwnership: false
)

// Security-focused (preserve exact permissions and ownership)
let securityOptions = ScanOptions(
    followSymlinks: false,  // Don't follow symlinks
    includeHidden: true,    // Capture hidden files
    captureOwnership: true  // Preserve ownership
)
```

## Performance Characteristics

### Creation Performance
- **Small (1,000 files):** <1 second
- **Medium (10,000 files):** 1-2 seconds (SSD), <30 seconds (HDD)
- **Large (100,000 files):** 1-3 minutes (SSD)

**Run Performance Benchmark:**
```bash
# Opt-in benchmark test (creates 10,000 files)
DIFFA_RUN_BENCHMARKS=1 swift test --filter testVeryLargeDirectory
```

Bottlenecks:
- SHA-256 computation for file content (~100 MB/s)
- File system metadata reads
- Disk I/O for database writes

### Memory Usage
- **Engine:** O(depth) - only current directory path stack in memory
- **Snapshot object:** ~200 bytes (just URL and metadata references)
- **Item queries:** O(results) - only requested items loaded

### Database Size
- ~200 bytes per item (file/folder)
- 10,000 items ≈ 2 MB database
- 100,000 items ≈ 20 MB database

## Error Handling

```swift
do {
    let snapshot = try await engine.createSnapshot(
        from: directoryURL,
        saveTo: snapshotURL,
        options: options
    )
} catch DiffaError.permissionDenied(let path) {
    print("Permission denied: \(path)")
} catch DiffaError.snapshotCreationFailed(let reason) {
    print("Snapshot creation failed: \(reason)")
} catch {
    print("Unexpected error: \(error)")
}
```

**Graceful Degradation:**
- Permission-denied files/folders are skipped automatically
- Broken symlinks are skipped when `followSymlinks: true`
- Scan continues even if individual items fail

## Thread Safety

- **SnapshotEngine:** Not thread-safe (file system operations)
- **Snapshot queries:** Thread-safe for read operations
- **Multiple readers:** Supported (SQLite SHARED lock mode)
- **Concurrent writes:** Not supported (would require serialization)

## Best Practices

1. **Choose appropriate scan options:**
   - Use defaults for most cases
   - Enable `captureOwnership` only when needed (requires permissions)
   - Disable `followSymlinks` to capture exact directory structure

2. **Handle large directories:**
   - Use progress callbacks for user feedback
   - Consider breaking into multiple snapshots if >1 million files
   - Run on background thread to avoid blocking UI

3. **Database management:**
   - Snapshot files are self-contained SQLite databases
   - Can be copied, moved, or archived freely
   - Use meaningful names with timestamps: `backup-2025-01-15.snapshot`

4. **Error handling:**
   - Wrap creation in try-catch
   - Permission errors are common - handle gracefully
   - Check metadata after creation to verify completeness

## See Also

- [Core Module](../Core/README.md) - Core types and metadata
- [Comparison Module](../Comparison/README.md) - Snapshot comparison
- [Database Module](../Database/README.md) - SQLite wrapper implementation
