# Diffalla Comparison Module

Fast SQL-powered snapshot comparison with lazy evaluation.

## Overview

The Comparison module compares two snapshots to identify added, removed, and modified files. Comparisons use SQL joins for efficiency and lazy evaluation to avoid unnecessary computation.

## Quick Start

```swift
import Diffalla

// Open two snapshots
let snapshot1 = try Snapshot.open(at: URL(fileURLWithPath: "before.snapshot"))
let snapshot2 = try Snapshot.open(at: URL(fileURLWithPath: "after.snapshot"))

// Compare snapshots
let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

// Check for differences
if try diff.hasDifferences {
    print("Added: \(try diff.added.count)")
    print("Removed: \(try diff.removed.count)")
    print("Modified: \(try diff.modified.count)")
}

// Inspect changes
for item in try diff.added {
    print("+ \(item.path)")
}

for item in try diff.removed {
    print("- \(item.path)")
}

for item in try diff.modified {
    print("M \(item.path)")
}
```

## Key Types

### Difference

Represents the difference between two snapshots with lazy evaluation.

```swift
public class Difference {
    let sourceSnapshot: Snapshot        // Original snapshot
    let destinationSnapshot: Snapshot   // New snapshot

    var added: [SnapshotItem] { get throws }     // Items added in destination
    var removed: [SnapshotItem] { get throws }   // Items removed from source
    var modified: [SnapshotItem] { get throws }  // Items modified between snapshots
    var hasDifferences: Bool { get throws }      // True if any differences exist

    static func compare(source: Snapshot, destination: Snapshot) throws -> Difference
}
```

**Properties are lazy-evaluated:**
- SQL queries execute only when property is first accessed
- Results are cached after first access
- Accessing `hasDifferences` only computes counts (fast)
- Full item lists loaded on demand

**Memory Efficiency:**
- Difference object itself: ~400 bytes
- Only contains references to snapshots
- Item arrays loaded only when accessed

### Comparison Logic

**Added Items:**
Items present in destination but not in source (by path).

```sql
SELECT d.* FROM dest.items d
LEFT JOIN main.items s ON d.path = s.path
WHERE s.path IS NULL
```

**Removed Items:**
Items present in source but not in destination (by path).

```sql
SELECT s.* FROM main.items s
LEFT JOIN dest.items d ON s.path = d.path
WHERE d.path IS NULL
```

**Modified Items:**
Items present in both but with different content or metadata.

```sql
SELECT d.* FROM dest.items d
INNER JOIN main.items s ON d.path = s.path
WHERE (d.sha256 IS NOT NULL AND s.sha256 IS NOT NULL AND d.sha256 != s.sha256)
   OR d.size != s.size
   OR d.modification_date != s.modification_date
   OR d.permissions != s.permissions
```

**Modification Detection:**
- SHA-256 hash mismatch (for files with hashes)
- File size change
- Modification timestamp change
- Permission change

## Usage Patterns

### Basic Comparison

```swift
// Create two snapshots
let engine = SnapshotEngine()
let options = ScanOptions()

let before = try await engine.createSnapshot(
    from: directoryURL,
    saveTo: URL(fileURLWithPath: "before.snapshot"),
    options: options
)

// ... make changes to directory ...

let after = try await engine.createSnapshot(
    from: directoryURL,
    saveTo: URL(fileURLWithPath: "after.snapshot"),
    options: options
)

// Compare
let diff = try Difference.compare(source: before, destination: after)
```

### Quick Difference Check

```swift
// Just check if there are any differences (fast)
if try !diff.hasDifferences {
    print("No changes detected")
    return
}

// Only load added items if needed
if try !diff.added.isEmpty {
    print("New files:")
    for item in try diff.added {
        print("  + \(item.path)")
    }
}
```

### Detailed Change Analysis

```swift
let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

// Analyze added files
let added = try diff.added
print("\nAdded (\(added.count) items):")
for item in added {
    if item.isFolder {
        print("  + [DIR]  \(item.path)")
    } else {
        let sizeStr = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        print("  + [FILE] \(item.path) (\(sizeStr))")
    }
}

// Analyze removed files
let removed = try diff.removed
print("\nRemoved (\(removed.count) items):")
for item in removed {
    print("  - \(item.path)")
}

// Analyze modifications
let modified = try diff.modified
print("\nModified (\(modified.count) items):")
for item in modified {
    // Get old version from source snapshot
    if let oldItem = try snapshot1.loadItem(path: item.path) {
        let sizeDiff = item.size - oldItem.size
        let hashChanged = item.sha256 != oldItem.sha256
        let permsChanged = item.permissions.posix != oldItem.permissions.posix

        var changes: [String] = []
        if hashChanged { changes.append("content") }
        if sizeDiff != 0 { changes.append("size:\(sizeDiff > 0 ? "+" : "")\(sizeDiff)") }
        if permsChanged { changes.append("perms:\(item.permissions.octalString)") }

        print("  M \(item.path) [\(changes.joined(separator: ", "))]")
    }
}
```

### Historical Comparison

```swift
// Compare current state to snapshot from last week
let lastWeek = try Snapshot.open(at: URL(fileURLWithPath: "backup-2025-01-08.snapshot"))
let current = try await engine.createSnapshot(
    from: directoryURL,
    saveTo: URL(fileURLWithPath: "current.snapshot"),
    options: options
)

let diff = try Difference.compare(source: lastWeek, destination: current)

print("Changes since last week:")
print("  Added: \(try diff.added.count)")
print("  Removed: \(try diff.removed.count)")
print("  Modified: \(try diff.modified.count)")
```

### Incremental Sync Detection

```swift
// Determine what needs to be synced
let local = try Snapshot.open(at: localSnapshotURL)
let remote = try Snapshot.open(at: remoteSnapshotURL)

let diff = try Difference.compare(source: local, destination: remote)

// Files to download from remote
let toDownload = try diff.added
print("Need to download \(toDownload.count) files")

// Files to delete locally
let toDelete = try diff.removed
print("Need to delete \(toDelete.count) files")

// Files to update
let toUpdate = try diff.modified
print("Need to update \(toUpdate.count) files")
```

## Performance Characteristics

### Comparison Speed
- **10,000 files:** <1 second (instant)
- **100,000 files:** <5 seconds
- **1,000,000 files:** <30 seconds

Speed depends on:
- SQLite index efficiency (very fast)
- Number of differences found (affects result size)
- SSD vs HDD (minimal impact, mostly in-memory)

### Memory Usage
- **Difference object:** ~400 bytes (just references)
- **Cached results:** O(changes) - only stores differences
- **No differences case:** Minimal memory (empty arrays cached)

### Lazy Evaluation Benefits
```swift
// Fast: Only checks if differences exist (doesn't load items)
if try diff.hasDifferences {
    // Slower: Loads all added items
    print("Added: \(try diff.added.count)")
}

// Efficient: Only loads what you need
if try !diff.added.isEmpty {
    // Only loads added items, not removed or modified
    for item in try diff.added {
        print(item.path)
    }
}
```

## SQL Implementation Details

### ATTACH DATABASE
Comparison uses SQLite's `ATTACH DATABASE` feature:

```swift
// Attach destination snapshot as "dest"
try source.database.execute("ATTACH DATABASE '\(destinationPath)' AS dest")

// Query both databases in a single statement
let sql = """
    SELECT d.* FROM dest.items d
    LEFT JOIN main.items s ON d.path = s.path
    WHERE s.path IS NULL
    """

// Detach when done
try source.database.execute("DETACH DATABASE dest")
```

**Benefits:**
- Single query compares both snapshots
- Leverages SQLite's query optimizer
- Efficient index usage across databases

### SQL Injection Prevention
All file paths are properly escaped:

```swift
// Single quotes in paths are doubled ('→'')
// Safe for paths like: /Users/O'Connor/Documents
let escapedPath = path.replacingOccurrences(of: "'", with: "''")
try db.execute("ATTACH DATABASE '\(escapedPath)' AS dest")
```

## Error Handling

```swift
do {
    let diff = try Difference.compare(source: snap1, destination: snap2)
    let added = try diff.added
} catch DiffallaError.comparisonFailed(let reason) {
    print("Comparison failed: \(reason)")
} catch DiffallaError.databaseError(let reason, let error) {
    print("Database error: \(reason)")
} catch {
    print("Unexpected error: \(error)")
}
```

**Common Errors:**
- Invalid snapshot files (corrupt SQLite databases)
- Schema version mismatch
- Missing indexes (performance degradation, not failure)
- Disk I/O errors

## Thread Safety

- **Difference.compare():** Thread-safe (creates independent Difference object)
- **Property access:** Thread-safe (SQL queries use separate connections)
- **Multiple concurrent comparisons:** Supported (each has own Difference object)
- **Caching:** Thread-safe (accessed via Swift's thread-safe property access)

## Best Practices

1. **Check hasDifferences first:**
   ```swift
   if try !diff.hasDifferences {
       print("No changes")
       return  // Skip expensive item loading
   }
   ```

2. **Load only what you need:**
   ```swift
   // Good: Only loads added items
   if try !diff.added.isEmpty {
       for item in try diff.added {
           process(item)
       }
   }

   // Wasteful: Loads all three arrays
   let hasChanges = try !diff.added.isEmpty ||
                        !diff.removed.isEmpty ||
                        !diff.modified.isEmpty
   ```

3. **Reuse Difference objects:**
   ```swift
   let diff = try Difference.compare(source: s1, destination: s2)

   // First access computes and caches
   let added = try diff.added

   // Second access uses cache (free)
   let addedAgain = try diff.added
   ```

4. **Handle large differences:**
   ```swift
   let added = try diff.added
   if added.count > 10000 {
       print("Warning: Large number of changes (\(added.count))")
       // Process in batches or show progress
   }
   ```

5. **Compare snapshots from same options:**
   ```swift
   // Inconsistent: Will report false modifications
   let snap1 = try await engine.createSnapshot(..., options: ScanOptions(captureOwnership: false))
   let snap2 = try await engine.createSnapshot(..., options: ScanOptions(captureOwnership: true))

   // Consistent: Reliable comparison
   let options = ScanOptions()
   let snap1 = try await engine.createSnapshot(..., options: options)
   let snap2 = try await engine.createSnapshot(..., options: options)
   ```

## Limitations

1. **Path-based comparison:**
   - Files are matched by path only
   - Moved files appear as removed + added
   - Renamed files appear as removed + added
   - (Move detection planned for Phase 4)

2. **No diff output:**
   - Returns list of changed files, not line-by-line diffs
   - Use external diff tools for content comparison
   - (Detailed diff export planned for Phase 2)

3. **Modification detection:**
   - Relies on timestamps, size, and hashes
   - May miss metadata-only changes
   - Timestamp precision limited to seconds

## See Also

- [Core Module](../Core/README.md) - Core types and metadata
- [Snapshots Module](../Snapshots/README.md) - Snapshot creation and storage
- [Database Module](../Database/README.md) - SQLite wrapper implementation
