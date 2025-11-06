# Design Document

## What (Not How)

### Scope

**Primary focus:** File system comparison, patching, and synchronization for local file systems on Apple platforms

**No UI:** This is a library/framework only - no user interface components

**Future expansion:** File system-like subjects (FTP, AWS S3, etc.)

### Core Functionality

#### 1. Find Differences
**Compare two folders** - Identify what's different between two locations
- Compare directory structures
- Compare file contents (via SHA-256)
- Compare metadata (timestamps, permissions, etc.)
- Report added, removed, and modified items

**Use case:** Test installer behavior - what was installed, what was removed

#### 2. Create Patches
**Generate transformation patches** - Create patch that describes how to transform A to B
- Patch contains operations needed to transform source to destination
- Reversible - preserves original content for revert
- Original files cached (inline for small files, separate cache for large files)
- Serializable for storage or transmission

**Use case:** Deployment packages, backup deltas

#### 3. Apply and Revert Patches
**Apply patches** - Transform a folder using a patch
- Execute operations: add files, remove files, modify files
- Move/rename detection for efficiency

**Revert patches** - Undo applied patches
- Restore original files from cache
- Hybrid storage: inline content for small files, cache directory for large files
- Configurable threshold and cache location

**Use case:** Install/uninstall, deploy/rollback

#### 4. Synchronize Folders
**Sync operations** - Make folders identical or mirror one to another
- Bidirectional sync: Make A and B identical
- Unidirectional sync: Make B identical to A (sync A over B)

**Use case:** Backup synchronization, deployment

#### 5. Optimize Synchronization
**Efficient operations** - Minimize I/O and disk usage
- Detect moves/renames to avoid copy+delete
- Smart file operations to reduce data transfer
- Reuse existing files where possible

**Use case:** Large-scale synchronization with minimal overhead

#### 6. Snapshots (Verification)
**Lightweight state capture** - Record directory state without storing content
- Capture structure, hashes, and metadata only
- Compare snapshot to directory programmatically
- Detect changes since known good state
- Serializable for storage and comparison
- No revert or apply - observation only

**Use cases:**
- Integrity monitoring: Detect unauthorized changes
- Build verification: Verify output matches expected state
- Change detection: Track what changed during operation
- Deployment validation: Ensure correct files deployed

### Key Outputs

**Difference** - Comparison result containing:
- Added items (in destination, not in source)
- Removed items (in source, not in destination)
- Modified items (different content/metadata)
- Unchanged items (optional)

**Patch** - Serializable set of operations to transform folders:
- Add operations (files to create)
- Remove operations (files to delete)
- Modify operations (files to update)
- Move operations (optimized renames/moves)
- RevertData (preserves original content for rollback)
  - Inline storage for small files
  - Cache directory references for large files
  - Configurable threshold and location
- Can be applied forward or reverted

**Sync result** - Report of synchronization actions:
- Files copied
- Files deleted
- Files moved/renamed
- Conflicts resolved (for bidirectional sync)

**Snapshot** - Lightweight directory state capture:
- Directory structure (paths)
- File hashes (SHA-256)
- Metadata (timestamps, permissions, etc.)
- No file content stored
- Serializable (JSON/binary)
- Can be compared to directories to detect changes

### API Surface

```swift
struct Diffa {
	struct Difference<T: ItemProtocol> {
		let sourceSnapshot: Snapshot      // Reference to snapshot A
		let destinationSnapshot: Snapshot // Reference to snapshot B

		// Compare directories (creates snapshots)
		static func compare(
			source: URL,
			destination: URL,
			progress: ((ComparisonProgress) -> Void)? = nil
		) async throws -> Difference<T>

		// Compare existing snapshots (lightweight)
		static func compare(
			source: Snapshot,
			destination: Snapshot
		) throws -> Difference<T>

		// Query differences (lazy, SQL-powered)
		func getAdded() throws -> [T]
		func getRemoved() throws -> [T]
		func getModified() throws -> [T]

		// Cached results
		var added: [T] { get }
		var removed: [T] { get }
		var modified: [T] { get }
	}
}
```

**Key design:**
- Difference is lightweight (~400 bytes), just references two snapshots
- Uses SQLite ATTACH DATABASE to query both databases
- Lazy evaluation - compute only what's needed
- Snapshots can be reused for multiple comparisons

**Main comparison type:**
- `Diffa` - Top-level namespace for the library
- `Difference<T>` - Generic nested struct containing comparison results
- `compare()` - Static factory method to perform comparison
- `source` - The original/base item to compare from
- `destination` - The target item to compare to
- `progress` - Optional callback for progress updates during comparison
- `async throws` - Supports long-running operations with error handling

**Result properties:**
- `added` - Items present in destination but not in source
- `removed` - Items present in source but not in destination
- `modified` - Items present in both but with different content/metadata

**Usage:**
```swift
// Option 1: Compare directories (creates snapshots internally)
let diff = try await Diffa.Difference.compare(source: dirA, destination: dirB)
print("Added: \(diff.added.count)")
print("Removed: \(diff.removed.count)")
print("Modified: \(diff.modified.count)")

// Option 2: Compare existing snapshots (reusable, lightweight)
let snapA = try Snapshot.load(from: "snapshot_a.sqlite")
let snapB = try Snapshot.load(from: "snapshot_b.sqlite")
let diff = try Diffa.Difference.compare(source: snapA, destination: snapB)
// Comparison is just SQL queries - very fast!

// Option 3: Multiple comparisons with snapshot reuse
let snapA = try await Snapshot.create(from: dirA, saveTo: "a.sqlite")
let snapB = try await Snapshot.create(from: dirB, saveTo: "b.sqlite")
let snapC = try await Snapshot.create(from: dirC, saveTo: "c.sqlite")

let diffAB = try Diffa.Difference.compare(source: snapA, destination: snapB)
let diffBC = try Diffa.Difference.compare(source: snapB, destination: snapC)
let diffAC = try Diffa.Difference.compare(source: snapA, destination: snapC)
// Each comparison is fast - directories only scanned once!
```

**Additional APIs (to be designed):**

```swift
// Patch operations
struct Patch {
	static func create(from difference: Difference<T>) -> Patch
	func apply(to target: URL) async throws
	func revert(on target: URL) async throws
}

// Synchronization
extension Diffa {
	static func syncBidirectional(
		a: URL,
		b: URL,
		progress: ((SyncProgress) -> Void)?
	) async throws

	static func syncUnidirectional(
		source: URL,
		destination: URL,
		progress: ((SyncProgress) -> Void)?
	) async throws
}

// Snapshots (file-based, not memory-based)
extension Diffa {
	struct Snapshot {
		// Create and save snapshot to file (streaming)
		static func create(
			from directory: URL,
			saveTo snapshotURL: URL,
			progress: ((SnapshotProgress) -> Void)? = nil
		) async throws -> Snapshot

		// Load snapshot from file
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

**Future considerations:**
- Options: Comparison depth, filters, ignore rules
- Cancellation support via Task
- Streaming results for very large comparisons
- Move/rename detection algorithm
- Conflict resolution strategies for bidirectional sync

### Core Types

**ItemProtocol**

```swift
protocol ItemProtocol: Equatable {
	var isFolder: Bool { get }
	var children: [ItemProtocol]? { get }
	var sha256: String? { get }
	var size: Int64 { get }
	var metadata: Metadata { get }
}
```

- Represents a file system item (file or directory)
- Supports hierarchical directory structures
- `isFolder` - Indicates if the item is a folder/directory
- `children` - Child items (files/subdirectories) for folders, nil for files
- `sha256` - SHA-256 hash of file content, nil for folders
- `size` - Size in bytes (file size or total size for folders)
- `metadata` - Additional metadata (timestamps, permissions, etc.)
- Starting implementation: Local file system on macOS/iOS
- Future: FTP entries, S3 objects, etc.

**ComparisonProgress**

```swift
struct ComparisonProgress {
	var currentItem: String
	var itemsProcessed: Int
	var totalItems: Int?
	var bytesProcessed: Int64
	var totalBytes: Int64?
}
```

- Progress information during comparison
- `currentItem` - Name/path of item currently being compared
- `itemsProcessed` - Number of items processed so far
- `totalItems` - Total items to process (nil if unknown)
- `bytesProcessed` - Bytes processed so far
- `totalBytes` - Total bytes to process (nil if unknown)

**Metadata**

```swift
struct Metadata: Equatable {
	// To be defined
	// Examples: createdDate, modifiedDate, permissions, owner, group
}
```

- Contains file system metadata
- Used for comparing file attributes beyond content
- Starting implementation: macOS file attributes
- Future: Platform-specific attributes


## Open Questions

### Comparison
- How to handle symlinks?
- Should we compare file permissions/ownership?
- What level of metadata comparison (creation date, modification date, access date)?
- Performance requirements for large directories?

### Patching
- What format for serialized patches (JSON, binary, custom)?
- How to handle patch conflicts (file modified since patch created)?
- Should patches include file content or just references?
- How to verify patch integrity?

### Synchronization
- Conflict resolution strategy for bidirectional sync?
- How to detect moves vs copy+delete (hash-based, path-based)?
- Should sync preserve metadata (timestamps, permissions)?
- How to handle failures mid-sync (rollback, continue, manual)?

### Optimization
- Algorithm for detecting file moves/renames?
- When to use move vs copy+delete?
- How to minimize disk I/O for large operations?
- Should we support incremental/resumable operations?
