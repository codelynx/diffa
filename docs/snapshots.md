# Snapshots (Feature)

## Goal

Create lightweight snapshots of directory state that capture structure, hashes, and metadata without storing file content. Snapshots can be compared to directories to programmatically observe differences.

## Use Cases

### Verification
- Capture known good state of directory
- Later verify directory matches snapshot
- Detect unauthorized changes

### Change Detection
- Take snapshot before operation
- Compare against snapshot after operation
- Identify what changed

### Integrity Monitoring
- Periodic snapshots to detect tampering
- Monitor critical system directories
- Alert on unexpected changes

### Build Verification
- Snapshot expected build output
- Verify actual build matches expected snapshot
- Detect build inconsistencies

### Deployment Validation
- Snapshot expected deployment state
- Compare deployed files to snapshot
- Identify missing or extra files

## Snapshot Structure

### Snapshot Object

```swift
struct Snapshot {
	let databaseURL: URL       // Reference to SQLite database file
	let rootPath: String       // Cached from database metadata
	let createdDate: Date      // Cached from database metadata
	let metadata: SnapshotMetadata  // Cached from database metadata

	// Create snapshot and save to SQLite database
	static func create(
		from directory: URL,
		saveTo snapshotURL: URL,  // .sqlite file path
		progress: ((SnapshotProgress) -> Void)? = nil
	) async throws -> Snapshot

	// Load existing snapshot from database
	static func load(from url: URL) throws -> Snapshot

	// Compare snapshot to live directory
	func compare(
		to directory: URL,
		progress: ((ComparisonProgress) -> Void)? = nil
	) async throws -> SnapshotDifference

	// Compare two snapshots
	func compare(to other: Snapshot) throws -> SnapshotDifference

	// Navigation methods (query database as needed)
	func listRootItems() throws -> [SnapshotItem]
	func listChildren(of parentId: Int) throws -> [SnapshotItem]
	func getItem(path: String) throws -> SnapshotItem?
	func getParent(of itemId: Int) throws -> SnapshotItem?
	func listDescendants(of itemId: Int, filesOnly: Bool) throws -> [SnapshotItem]
}

struct SnapshotProgress {
	var currentPath: String
	var filesProcessed: Int
	var totalFiles: Int?      // nil if unknown during traversal
	var bytesProcessed: Int64
}
```

**Key points:**
- **Snapshot object is just a reference to a SQLite database file**
- All data lives in the .sqlite file, not in memory
- Snapshot object is lightweight (~200 bytes)
- Metadata cached for quick access (total files, etc.)
- All navigation/queries execute against the database
- Multiple operations can work with same snapshot without loading everything

**Architecture:**

```
┌─────────────────────────────────────┐
│  Snapshot struct (in memory)        │
│  ┌───────────────────────────────┐  │
│  │ databaseURL: URL              │  │ ← Just a file path
│  │ rootPath: String              │  │ ← Cached metadata
│  │ createdDate: Date             │  │ ← Cached metadata
│  │ metadata: SnapshotMetadata    │  │ ← Cached metadata
│  └───────────────────────────────┘  │
│         (~200 bytes)                 │
└─────────────────────────────────────┘
                 │
                 │ References
                 ↓
┌─────────────────────────────────────┐
│  snapshot.sqlite (on disk)          │
│  ┌───────────────────────────────┐  │
│  │ snapshot_metadata table       │  │
│  │  - version, root_path, etc.   │  │
│  └───────────────────────────────┘  │
│  ┌───────────────────────────────┐  │
│  │ items table                   │  │
│  │  - 100,000 rows of files      │  │
│  │  - parent_id relationships    │  │
│  │  - Indexes for fast queries   │  │
│  └───────────────────────────────┘  │
│         (~7 MB for 100k files)      │
└─────────────────────────────────────┘

Operations query the database as needed:
  snapshot.listRootItems() → SELECT * FROM items WHERE parent_id IS NULL
  snapshot.getItem(path) → SELECT * FROM items WHERE path = ?
  snapshot.compare(to: dir) → Query each item, compare with directory
```

**This means:**
- Snapshot object can be copied/passed around cheaply
- Can have multiple Snapshot objects referencing same database
- Database stays on disk, queries read what's needed
- No memory explosion even with millions of files

### SQLite Schema

**Database structure:**

```sql
-- Snapshot metadata table
CREATE TABLE snapshot_metadata (
	key TEXT PRIMARY KEY,
	value TEXT NOT NULL
);

-- Snapshot items table (hierarchical structure)
CREATE TABLE items (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	parent_id INTEGER,                -- NULL for root items, references items(id)
	name TEXT NOT NULL,               -- File/folder name (not full path)
	path TEXT NOT NULL UNIQUE,        -- Full relative path for quick lookup
	is_folder INTEGER NOT NULL,       -- 0 = file, 1 = folder
	sha256 TEXT,                      -- NULL for folders
	size INTEGER NOT NULL,
	modification_date TEXT NOT NULL,
	permissions TEXT,
	owner TEXT,
	group_name TEXT,
	FOREIGN KEY (parent_id) REFERENCES items(id)
);

-- Index for fast path lookups
CREATE INDEX idx_items_path ON items(path);

-- Index for fast hash lookups (move detection)
CREATE INDEX idx_items_sha256 ON items(sha256) WHERE sha256 IS NOT NULL;

-- Index for hierarchical navigation (list children of a folder)
CREATE INDEX idx_items_parent_id ON items(parent_id);
```

**Key additions for hierarchy:**
- `parent_id`: References parent folder (NULL for root items)
- `name`: Just the item name (e.g., "file.txt" not "folder/file.txt")
- `path`: Still kept for fast path-based lookups
- Index on `parent_id` for fast "list children" queries

**Metadata stored in key-value table:**
- `version`: "1.0"
- `root_path`: "/Users/user/project"
- `created_date`: "2025-11-05T12:34:56Z"
- `total_files`: "1234"
- `total_folders`: "56"
- `total_size`: "123456789"

### Snapshot Item (in-memory representation)

```swift
struct SnapshotItem: Equatable {
	let path: String              // Relative path from root
	let isFolder: Bool
	let sha256: String?           // Hash for files, nil for folders
	let size: Int64
	let metadata: Metadata
}
```

**Note:** SnapshotItem is used for in-memory operations, but items are stored in SQLite database, not kept in memory.

### Snapshot Metadata

```swift
struct SnapshotMetadata {
	let totalFiles: Int
	let totalFolders: Int
	let totalSize: Int64
	let version: String
}
```

### Snapshot Difference

```swift
struct SnapshotDifference {
	let added: [String]           // Paths in directory, not in snapshot
	let removed: [String]         // Paths in snapshot, not in directory
	let modified: [String]        // Paths in both but different
	let unchanged: [String]       // Paths in both and identical

	var hasChanges: Bool {
		!added.isEmpty || !removed.isEmpty || !modified.isEmpty
	}
}
```

## Creating Snapshots

### From Directory

```swift
let directory = URL(fileURLWithPath: "/path/to/directory")
let snapshotDB = URL(fileURLWithPath: "/tmp/my-snapshot.sqlite")

// Create snapshot - saves to SQLite database during creation
let snapshot = try await Snapshot.create(
	from: directory,
	saveTo: snapshotDB,
	progress: { progress in
		print("Processing: \(progress.currentPath)")
		print("Files: \(progress.filesProcessed)")
	}
)

print("Snapshot saved to: \(snapshot.databaseURL.path)")
print("  Files: \(snapshot.metadata.totalFiles)")
print("  Folders: \(snapshot.metadata.totalFolders)")
print("  Total size: \(snapshot.metadata.totalSize) bytes")
```

**Storage locations:**

```swift
// 1. Explicit location (user-specified)
let snapshot = try await Snapshot.create(
	from: directory,
	saveTo: URL(fileURLWithPath: "/path/to/snapshot.sqlite")
)

// 2. Temporary directory (cleared on reboot)
let tempSnapshot = FileManager.default.temporaryDirectory
	.appendingPathComponent("snapshot-\(UUID().uuidString).sqlite")
let snapshot = try await Snapshot.create(
	from: directory,
	saveTo: tempSnapshot
)

// 3. Cache directory (may be cleaned by OS)
let cacheDir = try FileManager.default.url(
	for: .cachesDirectory,
	in: .userDomainMask,
	appropriateFor: nil,
	create: true
)
let cacheSnapshot = cacheDir.appendingPathComponent("snapshots/baseline.sqlite")
let snapshot = try await Snapshot.create(
	from: directory,
	saveTo: cacheSnapshot
)
```

### Snapshot Process

**Step-by-step operation:**

1. **Initialize SQLite database**
   - Create SQLite database file at specified location
   - Create schema (tables and indexes)
   - Begin transaction for performance
   - Insert initial metadata (version, root_path, created_date)

2. **Traverse directory tree recursively**
   - Start from root directory
   - Use FileManager.enumerator or similar
   - Process files and folders in depth-first or breadth-first order

3. **For each file/folder encountered:**

   **For folders:**
   - Compute relative path
   - Get folder attributes from FileManager
   - INSERT into database:
     ```sql
     INSERT INTO items (path, is_folder, sha256, size, modification_date, ...)
     VALUES ('subfolder/nested', 1, NULL, 0, '2025-11-05T...', ...)
     ```
   - Increment totalFolders counter
   - Report progress

   **For files:**
   - Compute relative path
   - Compute SHA-256 hash (read file → hash → release)
   - Get file attributes from FileManager
   - INSERT into database:
     ```sql
     INSERT INTO items (path, is_folder, sha256, size, modification_date, ...)
     VALUES ('file.txt', 0, 'abc123...', 1024, '2025-11-05T...', ...)
     ```
   - Increment totalFiles counter
   - Add to totalSize counter
   - Report progress

4. **Stream to database incrementally**
   - Each item is INSERT-ed immediately as it's processed
   - Don't accumulate items in memory
   - SQLite handles buffering and disk writes efficiently
   - Allows processing arbitrarily large directories

5. **Finalize snapshot**
   - Update metadata table with final counts:
     ```sql
     INSERT INTO snapshot_metadata (key, value) VALUES
       ('total_files', '1234'),
       ('total_folders', '56'),
       ('total_size', '123456789');
     ```
   - Commit transaction
   - Close database connection
   - Return Snapshot object referencing the database

**Implementation pseudocode:**

```
function createSnapshot(directory, snapshotDBPath):
	// Open SQLite database
	db = SQLite.open(snapshotDBPath)

	// Create schema
	db.execute("CREATE TABLE snapshot_metadata (...)")
	db.execute("CREATE TABLE items (...)")
	db.execute("CREATE INDEX idx_items_path ON items(path)")
	db.execute("CREATE INDEX idx_items_sha256 ON items(sha256)")

	// Begin transaction for performance
	db.execute("BEGIN TRANSACTION")

	// Initialize counters
	totalFiles = 0
	totalFolders = 0
	totalSize = 0
	createdDate = now()

	// Insert initial metadata
	db.execute("INSERT INTO snapshot_metadata VALUES ('version', '1.0')")
	db.execute("INSERT INTO snapshot_metadata VALUES ('root_path', ?)", directory.path)
	db.execute("INSERT INTO snapshot_metadata VALUES ('created_date', ?)", createdDate)

	// Prepare INSERT statement for reuse (performance)
	insertStmt = db.prepare("""
		INSERT INTO items (path, is_folder, sha256, size, modification_date, ...)
		VALUES (?, ?, ?, ?, ?, ...)
	""")

	// Traverse directory
	enumerator = FileManager.enumerator(at: directory)
	for fileURL in enumerator:
		// Compute relative path
		relativePath = fileURL.path - directory.path

		// Get file attributes
		attributes = FileManager.attributesOfItem(at: fileURL)
		isFolder = attributes.isDirectory
		size = attributes.fileSize
		modDate = attributes.modificationDate

		if isFolder:
			// Folder: no hash needed
			insertStmt.bind(
				relativePath,  // path
				1,             // is_folder (true)
				nil,           // sha256 (NULL)
				0,             // size
				modDate,       // modification_date
				...
			)
			insertStmt.execute()
			totalFolders++
		else:
			// File: compute hash
			hash = computeSHA256(fileURL)  // Read file, hash, release
			insertStmt.bind(
				relativePath,  // path
				0,             // is_folder (false)
				hash,          // sha256
				size,          // size
				modDate,       // modification_date
				...
			)
			insertStmt.execute()
			totalFiles++
			totalSize += size

		// Report progress
		progress(currentPath: relativePath, filesProcessed: totalFiles, ...)

		// Item is now in database, can be garbage collected

	// Insert final metadata
	db.execute("INSERT INTO snapshot_metadata VALUES ('total_files', ?)", totalFiles)
	db.execute("INSERT INTO snapshot_metadata VALUES ('total_folders', ?)", totalFolders)
	db.execute("INSERT INTO snapshot_metadata VALUES ('total_size', ?)", totalSize)

	// Commit transaction
	db.execute("COMMIT")

	// Close database
	db.close()

	// Return snapshot object (holds database reference, not data)
	return Snapshot(
		rootPath: directory.path,
		createdDate: createdDate,
		databaseURL: snapshotDBPath,
		metadata: SnapshotMetadata(totalFiles, totalFolders, totalSize)
	)
```

**Why SQLite instead of JSON?**

| Feature | SQLite | JSON |
|---------|--------|------|
| **Streaming writes** | Native support | Manual buffering needed |
| **Query capability** | SQL queries | Load entire file |
| **Indexing** | Fast path/hash lookups | Linear search |
| **Comparison** | Query without loading all | Must load entire file |
| **Compression** | Built-in page compression | Manual compression |
| **File size** | ~70-80 bytes/file | ~100 bytes/file |
| **Transaction safety** | ACID compliance | Manual validation |
| **Incremental reads** | Read one row at a time | Parse entire JSON |
| **Memory usage** | Constant | Constant (streaming) |

**Benefits:**
- **Fast lookups**: Indexed queries for comparison
- **Scalable**: Works well with millions of items
- **Robust**: SQLite is battle-tested
- **Efficient**: Better compression and performance
- **Queryable**: Can inspect snapshot without full load

**Memory considerations:**

- **Must use file-based storage**, not memory-based
- Directory with 100,000 files → ~7-8 MB SQLite database
- If held in memory during creation → could be gigabytes with full object overhead
- **Stream processing**: read file → hash → INSERT to database → release from memory
- Only one SnapshotItem in memory at a time during creation
- Snapshot object is lightweight (just metadata + database URL)
- SQLite handles its own buffering and memory management

**Performance estimates:**

| Directory Size | SQLite DB Size | Creation Time | Memory Usage |
|----------------|----------------|---------------|--------------|
| 1,000 files | ~70 KB | ~5 seconds | < 10 MB |
| 10,000 files | ~700 KB | ~30 seconds | < 10 MB |
| 100,000 files | ~7 MB | ~5 minutes | < 20 MB |
| 1,000,000 files | ~70 MB | ~50 minutes | < 30 MB |

(Assuming average file size and modern SSD)

**Where to save snapshot:**

Default locations:
1. User-specified path (explicit save location)
2. Cache directory (persistent, may be cleaned by OS)
3. Temp directory (temporary, cleared on reboot)

**Note:** No file content is stored in snapshot, only:
- Directory structure (relative paths)
- File hashes (SHA-256 for files, NULL for folders)
- File sizes
- Metadata (timestamps, permissions, etc.)

## Comparing Snapshots

### Snapshot vs Directory

Compare a snapshot to a live directory:

```swift
// Load snapshot
let snapshot = try Snapshot.load(from: snapshotURL)

// Compare to current directory
let diff = try await snapshot.compare(to: directoryURL)

if diff.hasChanges {
	print("Changes detected!")

	if !diff.added.isEmpty {
		print("Added files:")
		for path in diff.added {
			print("  + \(path)")
		}
	}

	if !diff.removed.isEmpty {
		print("Removed files:")
		for path in diff.removed {
			print("  - \(path)")
		}
	}

	if !diff.modified.isEmpty {
		print("Modified files:")
		for path in diff.modified {
			print("  M \(path)")
		}
	}
} else {
	print("No changes - directory matches snapshot")
}
```

### Comparison Algorithm

**Using SQLite for efficient comparison:**

1. **Open snapshot database**
   - No need to load all items into memory
   - SQLite allows querying items as needed

2. **Scan directory**
   - Walk directory tree
   - Compute hashes for files
   - For each item, query snapshot database:
     ```sql
     SELECT sha256, size, modification_date FROM items WHERE path = ?
     ```

3. **Compare each item**
   - If not in database → Added
   - If in database:
     - If hash/size/metadata differs → Modified
     - If same → Unchanged

4. **Find removed items**
   - Query items in database not seen during scan:
     ```sql
     SELECT path FROM items WHERE path NOT IN (...)
     ```
   - Or: Track seen paths, then query remaining

5. **Return difference**
   - Report changes as SnapshotDifference
   - No patch creation, just observation

**Benefits of SQL-based comparison:**
- No need to load entire snapshot into memory
- Fast path lookups via index
- Can query specific items on demand
- Efficient for large snapshots

### Snapshot vs Snapshot

Compare two snapshots using SQL:

```swift
let oldSnapshot = try Snapshot.load(from: oldSnapshotURL)
let newSnapshot = try Snapshot.load(from: newSnapshotURL)

let diff = oldSnapshot.compare(to: newSnapshot)

print("Changes between snapshots:")
print("  Added: \(diff.added.count)")
print("  Removed: \(diff.removed.count)")
print("  Modified: \(diff.modified.count)")
```

**SQL-based snapshot comparison:**

```sql
-- Attach second database for comparison
ATTACH DATABASE '/path/to/new-snapshot.sqlite' AS new;

-- Find added items (in new, not in old)
SELECT path FROM new.items
WHERE path NOT IN (SELECT path FROM main.items);

-- Find removed items (in old, not in new)
SELECT path FROM main.items
WHERE path NOT IN (SELECT path FROM new.items);

-- Find modified items (different hash or metadata)
SELECT main.path FROM main.items
INNER JOIN new.items ON main.path = new.path
WHERE main.sha256 != new.sha256
   OR main.size != new.size
   OR main.modification_date != new.modification_date;
```

**Benefits:**
- Efficient: SQLite handles the joins
- No memory overhead: Stream results
- Fast: Indexed lookups
- Simple: Standard SQL operations

## Key Differences from Full Comparison

### Snapshot Comparison

- **Lightweight**: No file content stored
- **Serializable**: Snapshot saved as JSON/binary
- **Historical**: Compare current state to past snapshot
- **Observation only**: No patch, no revert, no apply
- **Efficient**: Snapshot is small, fast to load

### Full Comparison (Difference)

- **Complete**: Includes full comparison results
- **Basis for patching**: Can create patch from Difference
- **Real-time**: Compare two live directories
- **Actionable**: Can apply/revert changes
- **Memory intensive**: Loads both directory trees

## Example Usage Patterns

### Pattern 1: Before/After Verification

```swift
// Before operation
let beforeSnapshot = try await Snapshot.create(from: directory)

// Perform operation (install, deploy, etc.)
performOperation()

// After operation - compare to snapshot
let diff = try await beforeSnapshot.compare(to: directory)

if diff.hasChanges {
	// Operation made changes
	print("Operation modified:")
	print("  Added: \(diff.added.count) files")
	print("  Removed: \(diff.removed.count) files")
	print("  Modified: \(diff.modified.count) files")
}
```

### Pattern 2: Integrity Monitoring

```swift
// Create baseline snapshot
let baseline = try await Snapshot.create(from: systemDirectory)
try baseline.save(to: baselineURL)

// Later: Check for tampering
let baseline = try Snapshot.load(from: baselineURL)
let diff = try await baseline.compare(to: systemDirectory)

if diff.hasChanges {
	// Directory was modified!
	alertSecurityTeam(diff)
}
```

### Pattern 3: Build Verification

```swift
// Expected build output
let expectedSnapshot = try Snapshot.load(from: "expected-build.json")

// Compare actual build output
let diff = try await expectedSnapshot.compare(to: buildOutputDir)

if diff.hasChanges {
	// Build output doesn't match expected
	throw BuildError.unexpectedOutput(diff)
}
```

### Pattern 4: Deployment Validation

```swift
// Load deployment snapshot
let deploymentSnapshot = try Snapshot.load(from: "v1.2.3.snapshot")

// Verify deployed files
let diff = try await deploymentSnapshot.compare(to: deployedDirectory)

if !diff.removed.isEmpty {
	// Missing files!
	throw DeploymentError.missingFiles(diff.removed)
}

if !diff.added.isEmpty {
	// Extra files!
	print("Warning: Unexpected files: \(diff.added)")
}
```

## Snapshot File Format

### SQLite Database

Snapshots are stored as **SQLite database files** (.sqlite extension).

**Database structure:**

```
snapshot.sqlite
├── snapshot_metadata table (key-value pairs)
│   ├── version = "1.0"
│   ├── root_path = "/path/to/directory"
│   ├── created_date = "2025-11-05T12:34:56Z"
│   ├── total_files = "150"
│   ├── total_folders = "25"
│   └── total_size = "52428800"
└── items table (all files and folders)
    ├── Columns: id, path, is_folder, sha256, size, modification_date, ...
    ├── Index on path (fast lookups)
    └── Index on sha256 (fast hash lookups)
```

**Hierarchical navigation queries:**

```sql
-- List root items (top-level files/folders)
SELECT id, name, is_folder, size FROM items WHERE parent_id IS NULL;

-- List children of a specific folder (by path)
SELECT id, name, is_folder, size FROM items
WHERE parent_id = (SELECT id FROM items WHERE path = 'folder/subfolder');

-- List children of a specific folder (by id)
SELECT id, name, is_folder, size FROM items WHERE parent_id = 123;

-- Get all descendants recursively (using SQLite's WITH RECURSIVE)
WITH RECURSIVE descendants(id, name, path, level) AS (
  SELECT id, name, path, 0 FROM items WHERE path = 'folder'
  UNION ALL
  SELECT i.id, i.name, i.path, d.level + 1
  FROM items i JOIN descendants d ON i.parent_id = d.id
)
SELECT * FROM descendants;

-- Get parent folder of an item
SELECT parent.* FROM items AS parent
JOIN items AS child ON child.parent_id = parent.id
WHERE child.path = 'folder/subfolder/file.txt';

-- Get full path by traversing up (build path from hierarchy)
WITH RECURSIVE path_builder(id, name, full_path) AS (
  SELECT id, name, name FROM items WHERE id = 456
  UNION ALL
  SELECT p.id, p.name, p.name || '/' || pb.full_path
  FROM items p JOIN path_builder pb ON pb.id = p.parent_id
  WHERE p.parent_id IS NOT NULL
)
SELECT full_path FROM path_builder WHERE id = (
  SELECT id FROM items WHERE parent_id IS NULL AND id IN (SELECT id FROM path_builder)
);
```

**Other useful queries:**

```sql
-- Get metadata
SELECT value FROM snapshot_metadata WHERE key = 'total_files';

-- Get specific item by path (fast with index)
SELECT * FROM items WHERE path = 'folder/file1.txt';

-- Get all files (not folders)
SELECT path, sha256, size FROM items WHERE is_folder = 0;

-- Find files by hash (move detection)
SELECT path FROM items WHERE sha256 = 'abc123...';

-- Count files in a folder (non-recursive)
SELECT COUNT(*) FROM items
WHERE parent_id = (SELECT id FROM items WHERE path = 'folder')
AND is_folder = 0;

-- Count all files in a folder tree (recursive)
WITH RECURSIVE folder_tree(id) AS (
  SELECT id FROM items WHERE path = 'folder'
  UNION ALL
  SELECT i.id FROM items i JOIN folder_tree ft ON i.parent_id = ft.id
)
SELECT COUNT(*) FROM items WHERE id IN (SELECT id FROM folder_tree) AND is_folder = 0;
```

**Example data:**

```
Directory structure:
/project
├── README.md (id=1, parent_id=NULL, name="README.md", path="README.md")
├── src (id=2, parent_id=NULL, name="src", path="src")
│   ├── main.swift (id=3, parent_id=2, name="main.swift", path="src/main.swift")
│   └── utils (id=4, parent_id=2, name="utils", path="src/utils")
│       └── helper.swift (id=5, parent_id=4, name="helper.swift", path="src/utils/helper.swift")
└── tests (id=6, parent_id=NULL, name="tests", path="tests")
    └── test.swift (id=7, parent_id=6, name="test.swift", path="tests/test.swift")
```

**Programmatic navigation example:**

```swift
// Open snapshot database
let snapshot = try Snapshot.load(from: snapshotURL)

// List root items
let rootItems = try snapshot.listRootItems()
// Returns: ["README.md", "src", "tests"]

// Navigate into a folder
let srcFolder = rootItems.first(where: { $0.name == "src" })!

// List children of src folder
let srcChildren = try snapshot.listChildren(of: srcFolder.id)
// Returns: ["main.swift", "utils"]

// Navigate deeper
let utilsFolder = srcChildren.first(where: { $0.name == "utils" })!
let utilsChildren = try snapshot.listChildren(of: utilsFolder.id)
// Returns: ["helper.swift"]

// Get all descendants recursively
let allSrcFiles = try snapshot.listDescendants(of: srcFolder.id, filesOnly: true)
// Returns: ["src/main.swift", "src/utils/helper.swift"]

// Find parent of an item
let helper = try snapshot.getItem(path: "src/utils/helper.swift")
let parent = try snapshot.getParent(of: helper.id)
// Returns: utils folder (id=4)
```

**Advantages:**
- **Hierarchical**: True parent-child relationships via `parent_id`
- **Navigable**: Easy to traverse tree programmatically
- **Recursive queries**: SQLite `WITH RECURSIVE` for tree operations
- **Efficient**: ~30% smaller than JSON, no need to parse paths
- **Queryable**: Use SQL tools to inspect and navigate
- **Indexed**: Fast lookups without loading entire file
- **Standard**: Cross-platform, well-supported
- **Robust**: ACID compliance, corruption recovery
- **Flexible**: Both hierarchical navigation AND path-based lookup

## Performance Characteristics

### Snapshot Creation

- **Time**: O(n) where n = number of files
- **I/O**: Read each file to compute hash
- **Memory**: Constant (streaming to SQLite)
- **Storage**: Very small (no content)

**Example sizes (SQLite):**
- 1,000 files → ~70 KB
- 10,000 files → ~700 KB
- 100,000 files → ~7 MB

### Snapshot Comparison

- **Time**: O(n) where n = number of files
- **I/O**: Read directory tree, compute hashes, SQL queries
- **Memory**: Constant (SQL queries, no full load)
- **Fast**: No content comparison, only hashes; indexed lookups

### Comparison: Snapshot vs Full Comparison

| Operation | Snapshot | Full Comparison |
|-----------|----------|-----------------|
| Storage | Small (~70-80 bytes/file in SQLite) | Large (full content) |
| Format | SQLite database | Multiple options |
| Creation | Fast (hash only, stream to DB) | Fast (hash only) |
| Load time | Instant (don't load all) | Slow (large dataset) |
| Comparison | Fast (SQL queries + hash compare) | Fast (hash compare) |
| Memory | Constant (query as needed) | Variable (full comparison) |
| Actions | Observe only | Apply/revert patches |
| Queryable | Yes (SQL) | No |
| Use case | Verification | Synchronization |

## API Integration

### Snapshot in Diffalla Namespace

```swift
extension Diffalla {
	struct Snapshot {
		let rootPath: String
		let createdDate: Date
		let databaseURL: URL
		let metadata: SnapshotMetadata

		// Create snapshot and save to SQLite database
		static func create(
			from directory: URL,
			saveTo snapshotURL: URL,  // .sqlite file
			progress: ((SnapshotProgress) -> Void)? = nil
		) async throws -> Snapshot

		// Load snapshot from database
		static func load(from url: URL) throws -> Snapshot

		// Compare to directory
		func compare(
			to directory: URL,
			progress: ((ComparisonProgress) -> Void)? = nil
		) async throws -> SnapshotDifference

		// Compare to another snapshot
		func compare(to other: Snapshot) throws -> SnapshotDifference
	}

	struct SnapshotProgress {
		var currentPath: String
		var filesProcessed: Int
		var totalFiles: Int?
		var bytesProcessed: Int64
	}

	struct SnapshotDifference {
		let added: [String]
		let removed: [String]
		let modified: [String]
		let unchanged: [String]
		var hasChanges: Bool
	}
}
```

### Usage Example

```swift
// Create snapshot - saves to SQLite database
let snapshotDB = URL(fileURLWithPath: "/tmp/baseline.sqlite")
let snapshot = try await Diffalla.Snapshot.create(
	from: directory,
	saveTo: snapshotDB,
	progress: { progress in
		print("Processing: \(progress.currentPath)")
	}
)

// Compare later - loads from database
let snapshot = try Diffalla.Snapshot.load(from: snapshotDB)
let diff = try await snapshot.compare(to: directory)

if diff.hasChanges {
	print("Directory changed!")
	print("Added: \(diff.added.count)")
	print("Removed: \(diff.removed.count)")
	print("Modified: \(diff.modified.count)")
}
```

## Limitations

### What Snapshots Cannot Do

1. **No revert**: Cannot restore directory to snapshot state
   - Snapshots don't store content
   - Use patches for revert capability

2. **No apply**: Cannot apply snapshot to directory
   - Snapshots are read-only state
   - Use patches to transform directories

3. **No content comparison**: Only compares hashes
   - If hashes differ, files are different
   - Cannot show content diff

4. **No synchronization**: Cannot sync based on snapshot
   - Snapshots are for verification only
   - Use sync operations for synchronization

### When to Use Snapshots

✅ **Use snapshots for:**
- Verification (does directory match expected state?)
- Change detection (what changed since snapshot?)
- Integrity monitoring (has directory been tampered with?)
- Lightweight storage (track state over time)

❌ **Don't use snapshots for:**
- Restoring directories (use patches)
- Applying changes (use patches)
- Synchronization (use sync operations)
- Storing backups (need actual content)

## Open Questions

1. **Metadata level**: What metadata to include in snapshot?
2. **Compression**: Should snapshots be compressed?
3. **Incremental snapshots**: Support delta snapshots?
4. **Snapshot verification**: Include checksum of snapshot itself?
5. **Filtering**: Support include/exclude patterns?
6. **Comparison options**: Compare only structure? Only hashes? Only metadata?
7. **Format**: JSON, binary, or both?
8. **Signing**: Cryptographically sign snapshots for security?
