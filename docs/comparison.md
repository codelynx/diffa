# Comparison (Objective 1)

## Goal

Find differences between two folders to identify what files and folders differ between two locations.

## Design Philosophy

**Memory-efficient approach using snapshots:**

Instead of loading both directories into memory and comparing, we:
1. Take snapshot of A → `snapshot_a.sqlite`
2. Take snapshot of B → `snapshot_b.sqlite`
3. Create Difference that **references both snapshots**
4. Query differences on-demand using SQL

**Architecture:**
```
Directory A → Snapshot A (.sqlite file)
                    ↓
Directory B → Snapshot B (.sqlite file)
                    ↓
            Difference (references both)
                    ↓
         Query differences via SQL
```

**Benefits:**
- **Memory efficient**: Difference object ~400 bytes (just references)
- **Reusable snapshots**: Compare A to B, B to C, A to C without re-scanning
- **Historical comparison**: Compare old snapshots anytime
- **SQL-powered**: Database handles comparison logic
- **Lazy evaluation**: Only compute differences when requested
- **Scalable**: Works with millions of files

## Use Cases

### Installer Testing
Test what an installer does to the file system:
- Take snapshot of folder before installation
- Run installer
- Take snapshot of folder after installation
- Compare to see what was installed, removed, or modified

### Backup Verification
Verify that a backup matches the source:
- Compare backup folder to source folder
- Identify missing or corrupted files
- Verify nothing was accidentally removed

### Deployment Validation
Verify that a deployment succeeded:
- Compare deployed files to expected files
- Identify deployment errors or incomplete installations

## Difference Structure

### Difference Object

```swift
struct Difference<T: ItemProtocol> {
	let sourceSnapshot: Snapshot      // Reference to snapshot A
	let destinationSnapshot: Snapshot // Reference to snapshot B

	// Create difference from two snapshots
	static func compare(
		source: Snapshot,
		destination: Snapshot
	) throws -> Difference<T>

	// Query differences (lazy evaluation via SQL)
	func getAdded() throws -> [T]      // In destination, not in source
	func getRemoved() throws -> [T]    // In source, not in destination
	func getModified() throws -> [T]   // In both but different

	// Convenience properties (may cache results)
	let added: [T]
	let removed: [T]
	let modified: [T]
}
```

**In-memory representation:**
```
┌────────────────────────────────────┐
│ Difference<T> struct               │
│  ┌──────────────────────────────┐  │
│  │ sourceSnapshot: Snapshot     │ ─┼──→ snapshot_a.sqlite (7 MB)
│  │ destinationSnapshot: Snapshot│ ─┼──→ snapshot_b.sqlite (8 MB)
│  │                              │  │
│  │ added: [T]      (lazy/cache) │  │
│  │ removed: [T]    (lazy/cache) │  │
│  │ modified: [T]   (lazy/cache) │  │
│  └──────────────────────────────┘  │
│         (~400 bytes + cached results)│
└────────────────────────────────────┘
```

### What Gets Compared

From both snapshots:
- **Directory hierarchy** - Parent-child relationships
- **File paths** - Relative paths from root
- **File content** - SHA-256 hashes
- **File sizes** - Bytes
- **Metadata** - Modification dates, permissions, etc.
- **Presence/absence** - What exists in each snapshot

## Comparison Algorithm

### High-Level Process (Snapshot-Based)

**Step 1: Create snapshots**
```swift
let snapshotA = try await Snapshot.create(from: directoryA, saveTo: "a.sqlite")
let snapshotB = try await Snapshot.create(from: directoryB, saveTo: "b.sqlite")
```
- Each directory scanned once
- Data saved to SQLite databases
- Snapshots can be reused for multiple comparisons

**Step 2: Create Difference (lightweight)**
```swift
let diff = try Difference.compare(source: snapshotA, destination: snapshotB)
```
- Difference object created (just references to snapshots)
- No data loaded yet (~400 bytes in memory)

**Step 3: Query differences (on-demand)**

Uses SQLite `ATTACH DATABASE` to query both snapshots:

```sql
-- Open source snapshot database
ATTACH DATABASE '/path/to/snapshot_b.sqlite' AS dest;

-- Find added items (in destination, not in source)
SELECT path, sha256, size FROM dest.items
WHERE path NOT IN (SELECT path FROM main.items);

-- Find removed items (in source, not in destination)
SELECT path, sha256, size FROM main.items
WHERE path NOT IN (SELECT path FROM dest.items);

-- Find modified items (different hash or metadata)
SELECT main.path, main.sha256, dest.sha256
FROM main.items
INNER JOIN dest.items ON main.path = dest.path
WHERE main.sha256 != dest.sha256
   OR main.size != dest.size
   OR main.modification_date != dest.modification_date;
```

**Step 4: Return results**
- SQL queries return only changed items
- Results can be cached in Difference object
- Or queried each time (lazy evaluation)

## Example Usage

### Basic Comparison

```swift
// Step 1: Create snapshots
let snapshotA = try await Snapshot.create(
	from: URL(fileURLWithPath: "/directory/before"),
	saveTo: URL(fileURLWithPath: "/tmp/snapshot_before.sqlite"),
	progress: { progress in
		print("Scanning A: \(progress.filesProcessed) files")
	}
)

let snapshotB = try await Snapshot.create(
	from: URL(fileURLWithPath: "/directory/after"),
	saveTo: URL(fileURLWithPath: "/tmp/snapshot_after.sqlite"),
	progress: { progress in
		print("Scanning B: \(progress.filesProcessed) files")
	}
)

// Step 2: Compare snapshots (lightweight)
let diff = try Difference.compare(
	source: snapshotA,
	destination: snapshotB
)

// Step 3: Access results (queries SQLite as needed)
print("Added files: \(diff.added.count)")
for item in diff.added {
	print("  + \(item.path)")
}

print("Removed files: \(diff.removed.count)")
for item in diff.removed {
	print("  - \(item.path)")
}

print("Modified files: \(diff.modified.count)")
for item in diff.modified {
	print("  M \(item.path)")
}
```

### Reusing Snapshots

```swift
// Create snapshots once
let snapshotA = try await Snapshot.create(from: dirA, saveTo: "a.sqlite")
let snapshotB = try await Snapshot.create(from: dirB, saveTo: "b.sqlite")
let snapshotC = try await Snapshot.create(from: dirC, saveTo: "c.sqlite")

// Compare multiple times without re-scanning
let diffAB = try Difference.compare(source: snapshotA, destination: snapshotB)
let diffBC = try Difference.compare(source: snapshotB, destination: snapshotC)
let diffAC = try Difference.compare(source: snapshotA, destination: snapshotC)

print("A → B: \(diffAB.added.count) added, \(diffAB.removed.count) removed")
print("B → C: \(diffBC.added.count) added, \(diffBC.removed.count) removed")
print("A → C: \(diffAC.added.count) added, \(diffAC.removed.count) removed")
```

### Historical Comparison

```swift
// Load old snapshots from disk
let baseline = try Snapshot.load(from: URL(fileURLWithPath: "baseline-2023.sqlite"))
let current = try Snapshot.load(from: URL(fileURLWithPath: "current-2024.sqlite"))

// Compare without re-scanning directories
let diff = try Difference.compare(source: baseline, destination: current)

print("Changes since baseline:")
print("  New files: \(diff.added.count)")
print("  Deleted files: \(diff.removed.count)")
print("  Modified files: \(diff.modified.count)")
```

### Lazy Evaluation (Query on Demand)

```swift
let diff = try Difference.compare(source: snapshotA, destination: snapshotB)

// Only query what you need
if needsAddedFiles {
	let added = try diff.getAdded()  // Executes SQL query
	processAdded(added)
}

if needsRemovedFiles {
	let removed = try diff.getRemoved()  // Executes SQL query
	processRemoved(removed)
}

// Don't query modified if not needed - saves time
```

## Performance Characteristics

### Memory Usage (Snapshot-Based Approach)

**Traditional approach (both directories in memory):**
```
100,000 files × 2 directories = ~2 GB in memory
```

**Snapshot-based approach:**
```
Snapshot A: 7 MB on disk
Snapshot B: 8 MB on disk
Difference object: ~400 bytes in memory
SQL query results: Only changed items loaded (e.g., 1,000 items = ~100 KB)

Total memory: < 50 MB
```

**Comparison:**

| Aspect | Traditional | Snapshot-Based |
|--------|-------------|----------------|
| Memory (100k files) | ~2 GB | < 50 MB |
| Reusability | Must re-scan | Reuse snapshots |
| Historical comparison | Re-scan old directories | Load old snapshots |
| Comparison time | O(n) every time | O(n) once, O(changes) after |

### Performance Benefits

**1. Snapshot reuse**
```swift
// Traditional: Scan both directories each time
let diff1 = compare(dirA, dirB)  // Scan A + B
let diff2 = compare(dirA, dirC)  // Scan A + C (A scanned twice!)

// Snapshot-based: Scan each directory once
let snapA = createSnapshot(dirA)  // Scan A once
let snapB = createSnapshot(dirB)  // Scan B once
let snapC = createSnapshot(dirC)  // Scan C once
let diff1 = compare(snapA, snapB)  // Just SQL queries
let diff2 = compare(snapA, snapC)  // Just SQL queries
```

**2. SQL-powered comparison**
- SQLite handles the heavy lifting
- Indexed queries (fast path lookups)
- Efficient JOIN operations
- No manual iteration over millions of items

**3. Lazy evaluation**
- Don't compute what you don't need
- Query only added files if that's all you need
- Save time when only partial results needed

### Performance Estimates

| Operation | Traditional | Snapshot-Based |
|-----------|-------------|----------------|
| First comparison (100k files) | ~5 min | ~5 min (snapshot creation) |
| Second comparison (same dirs) | ~5 min | < 1 sec (SQL query) |
| Memory (100k files) | ~2 GB | < 50 MB |
| Historical comparison | Must re-scan | Load snapshot (instant) |

## Implementation Details

### SQL Comparison Query

**Using ATTACH DATABASE for efficient comparison:**

```sql
-- Open source snapshot
-- Attach destination snapshot
ATTACH DATABASE '/path/to/destination.sqlite' AS dest;

-- Find added items (in dest, not in main)
SELECT dest.path, dest.sha256, dest.size, dest.modification_date
FROM dest.items
WHERE dest.path NOT IN (SELECT path FROM main.items);

-- Find removed items (in main, not in dest)
SELECT main.path, main.sha256, main.size, main.modification_date
FROM main.items
WHERE main.path NOT IN (SELECT path FROM dest.items);

-- Find modified items (in both but different)
SELECT
	main.path,
	main.sha256 AS source_hash,
	dest.sha256 AS dest_hash,
	main.size AS source_size,
	dest.size AS dest_size
FROM main.items
INNER JOIN dest.items ON main.path = dest.path
WHERE main.sha256 != dest.sha256
   OR main.size != dest.size
   OR main.modification_date != dest.modification_date;

-- Detach when done
DETACH DATABASE dest;
```

### Caching Strategy

**Option 1: Eager evaluation (cache on creation)**
```swift
struct Difference<T> {
	let added: [T]      // Computed immediately, cached
	let removed: [T]    // Computed immediately, cached
	let modified: [T]   // Computed immediately, cached
}
```
- Pros: Simple, results always available
- Cons: Computes everything even if not needed

**Option 2: Lazy evaluation (compute on demand)**
```swift
struct Difference<T> {
	func getAdded() throws -> [T]     // Query only when called
	func getRemoved() throws -> [T]   // Query only when called
	func getModified() throws -> [T]  // Query only when called
}
```
- Pros: Only compute what's needed
- Cons: Multiple calls = multiple queries

**Option 3: Lazy with caching (best of both)**
```swift
struct Difference<T> {
	private var cachedAdded: [T]?
	private var cachedRemoved: [T]?
	private var cachedModified: [T]?

	mutating func getAdded() throws -> [T] {
		if let cached = cachedAdded { return cached }
		let result = // Execute SQL query
		cachedAdded = result
		return result
	}
}
```
- Pros: Compute only when needed, cache for reuse
- Cons: Slightly more complex

## Open Questions

1. **Caching strategy**: Eager, lazy, or lazy with caching?
2. **Result lifetime**: Keep Difference object alive to maintain cache?
3. **Symlinks**: How to handle symbolic links in snapshots?
4. **Hidden files**: Should snapshots include hidden files by default?
5. **Ignore patterns**: Support .gitignore-style patterns in snapshots?
6. **Metadata level**: What metadata should trigger "modified" status?
7. **API design**: Properties (`diff.added`) vs methods (`diff.getAdded()`)?
8. **Snapshot cleanup**: Who manages snapshot file lifecycle?
