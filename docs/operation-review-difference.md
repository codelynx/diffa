# Operation Review: Difference (Comparison)

This document reviews the comparison operation using the snapshot-based approach.

## Core Concept

**Your brilliant idea:** Instead of loading both directories into memory and comparing, create snapshots first, then Difference just references both snapshots.

```
Traditional:
  Directory A (in memory) + Directory B (in memory) → Compare → Difference

Snapshot-based:
  Directory A → Snapshot A (.diffa)
  Directory B → Snapshot B (.diffa)
  Difference (references A + B) → Query via SQL
```

## Architecture

```
┌─────────────────────────────────┐
│  Difference<T> struct           │
│  ┌──────────────────────────┐   │
│  │ sourceSnapshot: Snapshot │ ──┼──→ snapshot_a.diffa (7 MB on disk)
│  │ destSnapshot: Snapshot   │ ──┼──→ snapshot_b.diffa (8 MB on disk)
│  │                          │   │
│  │ cachedAdded: [T]?        │   │    Computed lazily via SQL
│  │ cachedRemoved: [T]?      │   │    Cached for reuse
│  │ cachedModified: [T]?     │   │
│  └──────────────────────────┘   │
│         (~400 bytes base)        │
└─────────────────────────────────┘
```

**Key points:**
- Difference object is tiny (~400 bytes without cache)
- All data lives in snapshot SQLite files
- Queries both databases using SQL ATTACH DATABASE
- Results computed on-demand (lazy evaluation)
- Results can be cached for subsequent access

## Operation: Compare Two Snapshots

### Step 1: Have or Create Snapshots

**Option A: Use existing snapshots**
```swift
let snapA = try Snapshot.load(from: URL(fileURLWithPath: "snapshot_a.diffa"))
let snapB = try Snapshot.load(from: URL(fileURLWithPath: "snapshot_b.diffa"))
```

**Option B: Create snapshots from directories**
```swift
let snapA = try await Snapshot.create(
    from: directoryA,
    saveTo: URL(fileURLWithPath: "/tmp/snapshot_a.diffa")
)
let snapB = try await Snapshot.create(
    from: directoryB,
    saveTo: URL(fileURLWithPath: "/tmp/snapshot_b.diffa")
)
```

### Step 2: Create Difference Object

```swift
let diff = try Difference.compare(
    source: snapA,
    destination: snapB
)
```

**What happens:**
1. Create Difference struct (~400 bytes)
2. Store references to both snapshots
3. NO data loaded yet
4. NO queries executed yet
5. Return immediately

**Memory:** ~400 bytes

### Step 3: Query Differences (Lazy)

**User accesses results:**
```swift
let added = diff.added  // First access - triggers SQL query
```

**What happens behind the scenes:**

1. **Open source snapshot database**
   ```swift
   db = SQLite.open(sourceSnapshot.databaseURL)
   ```

2. **Attach destination database**
   ```sql
   ATTACH DATABASE '/path/to/snapshot_b.diffa' AS dest;
   ```

3. **Query added items**
   ```sql
   SELECT dest.path, dest.sha256, dest.size, dest.modification_date
   FROM dest.items
   WHERE dest.path NOT IN (SELECT path FROM main.items);
   ```

4. **Convert results to [T]**
   - Map SQL rows to SnapshotItem objects
   - Return as array

5. **Cache results**
   ```swift
   cachedAdded = results
   ```

6. **Return results**
   ```swift
   return results
   ```

**Subsequent access:**
```swift
let added = diff.added  // Second access - returns cached results
// No SQL query executed!
```

### Step 4: Query Other Differences (As Needed)

**Query removed:**
```swift
let removed = diff.removed  // Triggers SQL query if not cached
```

```sql
SELECT main.path, main.sha256, main.size, main.modification_date
FROM main.items
WHERE main.path NOT IN (SELECT path FROM dest.items);
```

**Query modified:**
```swift
let modified = diff.modified  // Triggers SQL query if not cached
```

```sql
SELECT
    main.path,
    main.sha256 AS source_hash,
    dest.sha256 AS dest_hash,
    main.size AS source_size,
    dest.size AS dest_size,
    main.modification_date AS source_date,
    dest.modification_date AS dest_date
FROM main.items
INNER JOIN dest.items ON main.path = dest.path
WHERE main.sha256 != dest.sha256
   OR main.size != dest.size
   OR main.modification_date != dest.modification_date;
```

## Benefits

### 1. Memory Efficiency

**Traditional approach (100,000 files):**
```
Directory A loaded: ~1 GB
Directory B loaded: ~1 GB
Difference object: ~100 MB (stores all differences)
Total: ~2.1 GB
```

**Snapshot-based approach (100,000 files):**
```
Snapshot A on disk: 7 MB
Snapshot B on disk: 8 MB
Difference object: ~400 bytes (just references)
Cached results: ~100 KB (only changed items, e.g., 1,000 changes)
Total memory: < 50 MB
```

**Savings: 40x less memory!**

### 2. Snapshot Reuse

```swift
// Traditional: Must re-scan both directories each time
let diff1 = compare(dirA, dirB)  // Scan A + Scan B
let diff2 = compare(dirB, dirC)  // Scan B + Scan C (B scanned twice!)
let diff3 = compare(dirA, dirC)  // Scan A + Scan C (A and C scanned twice!)
// Total: 6 directory scans

// Snapshot-based: Scan each directory once
let snapA = createSnapshot(dirA)  // Scan A once
let snapB = createSnapshot(dirB)  // Scan B once
let snapC = createSnapshot(dirC)  // Scan C once
let diff1 = compare(snapA, snapB)  // SQL query only
let diff2 = compare(snapB, snapC)  // SQL query only
let diff3 = compare(snapA, snapC)  // SQL query only
// Total: 3 directory scans + 3 SQL queries (fast!)
```

### 3. Historical Comparison

```swift
// Traditional: Must re-scan old directories (if they even still exist!)
let diff = compare(oldDir, currentDir)  // Old dir may be deleted!

// Snapshot-based: Load old snapshot
let oldSnapshot = try Snapshot.load(from: "baseline-2023.diffa")
let currentSnapshot = try await Snapshot.create(from: currentDir, saveTo: "current.diffa")
let diff = try Difference.compare(source: oldSnapshot, destination: currentSnapshot)
// Compare to historical state anytime!
```

### 4. SQL-Powered

- SQLite handles comparison logic
- Indexed queries (O(log n) lookups)
- Efficient JOIN operations
- No manual iteration over millions of items
- Battle-tested database engine

### 5. Lazy Evaluation

```swift
let diff = try Difference.compare(source: snapA, destination: snapB)

// Only need to know if there are changes?
if diff.added.isEmpty && diff.removed.isEmpty && diff.modified.isEmpty {
    print("No changes!")
}
// Executes 3 SQL queries, returns counts only

// Only need added files?
if !diff.added.isEmpty {
    processAddedFiles(diff.added)  // Query only added
}
// Don't query removed/modified if not needed - saves time!
```

## Performance Comparison

| Operation | Traditional (100k files) | Snapshot-Based |
|-----------|--------------------------|----------------|
| First comparison | ~5 min (scan both) | ~5 min (create snapshots) |
| Second comparison (same dirs) | ~5 min (scan again) | < 1 sec (SQL query) |
| Memory usage | ~2 GB | < 50 MB |
| Multiple comparisons | N × 5 min | 1× 5 min + (N-1) × 1 sec |
| Historical comparison | Must re-scan (if exists) | Load snapshot (instant) |

**Example: Compare A to B, B to C, A to C**

Traditional:
- Scan A: 5 min
- Scan B: 5 min
- Compare A-B: instant
- Scan B again: 5 min
- Scan C: 5 min
- Compare B-C: instant
- Scan A again: 5 min
- Scan C again: 5 min
- Compare A-C: instant
- **Total: 30 minutes**

Snapshot-based:
- Create snapshot A: 5 min
- Create snapshot B: 5 min
- Create snapshot C: 5 min
- Compare A-B: 1 sec (SQL)
- Compare B-C: 1 sec (SQL)
- Compare A-C: 1 sec (SQL)
- **Total: 15 minutes + 3 seconds**

## Implementation Pseudocode

```
function Difference.compare(source: Snapshot, dest: Snapshot) -> Difference:
	// Create lightweight object
	diff = Difference(
		sourceSnapshot: source,
		destinationSnapshot: dest,
		cachedAdded: nil,
		cachedRemoved: nil,
		cachedModified: nil
	)
	return diff  // Just references, no queries yet

function Difference.added (getter):
	// Check cache
	if cachedAdded != nil:
		return cachedAdded

	// Open source database
	db = SQLite.open(sourceSnapshot.databaseURL)

	// Attach destination database
	db.execute("ATTACH DATABASE ? AS dest", destinationSnapshot.databaseURL)

	// Query added items
	results = db.query("""
		SELECT dest.path, dest.sha256, dest.size, dest.modification_date
		FROM dest.items
		WHERE dest.path NOT IN (SELECT path FROM main.items)
	""")

	// Convert to items
	items = results.map { row -> Item }

	// Cache results
	cachedAdded = items

	// Detach and close
	db.execute("DETACH DATABASE dest")
	db.close()

	return items
```

## API Design

```swift
// Two factory methods
struct Difference<T: ItemProtocol> {
	// Option 1: Create snapshots and compare (convenience)
	static func compare(
		source: URL,           // Directory path
		destination: URL,      // Directory path
		progress: ((ComparisonProgress) -> Void)? = nil
	) async throws -> Difference<T>

	// Option 2: Compare existing snapshots (lightweight, reusable)
	static func compare(
		source: Snapshot,
		destination: Snapshot
	) throws -> Difference<T>

	// Lazy properties (cached)
	var added: [T] { get }      // Computes on first access, caches
	var removed: [T] { get }    // Computes on first access, caches
	var modified: [T] { get }   // Computes on first access, caches

	// Or explicit methods (same behavior)
	func getAdded() throws -> [T]
	func getRemoved() throws -> [T]
	func getModified() throws -> [T]
}
```

## Review Summary

✅ **Lightweight** - Difference object ~400 bytes (just references)
✅ **Memory efficient** - 40x less memory than traditional approach
✅ **Reusable snapshots** - Scan directories once, compare many times
✅ **Historical comparison** - Compare to old snapshots anytime
✅ **SQL-powered** - Efficient indexed queries, JOINs
✅ **Lazy evaluation** - Compute only what's needed
✅ **Scalable** - Works with millions of files

**Ready for implementation?** YES / NO

If any concerns, document them here before proceeding to implementation.
