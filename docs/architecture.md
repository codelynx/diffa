# Architecture

## Overview

Diffa is a Swift library for file system comparison, patching, and synchronization.

**Platform:** macOS, iOS (Apple platforms initially)

**Type:** Library/framework (no UI components)

## Core Types

### ItemProtocol

Protocol for items that can be compared (files and folders).

```swift
protocol ItemProtocol: Equatable {
	var isFolder: Bool { get }
	var children: [ItemProtocol]? { get }
	var sha256: String? { get }
	var size: Int64 { get }
	var metadata: Metadata { get }
}
```

**Properties:**
- `isFolder` - True for directories, false for files
- `children` - Child items for folders, nil for files
- `sha256` - SHA-256 hash of file content, nil for folders
- `size` - Size in bytes (file size or total size for folders)
- `metadata` - File system metadata (timestamps, permissions, etc.)

**Conformance:**
- Must be `Equatable` for comparison
- Implementing types: `FileSystemItem`, future: `FTPItem`, `S3Item`

### Metadata

File system metadata for comparison.

```swift
struct Metadata: Equatable {
	var modificationDate: Date
	var creationDate: Date?
	var permissions: FilePermissions?
	var owner: String?
	var group: String?

	// Platform-specific
	#if os(macOS) || os(iOS)
	var extendedAttributes: [String: Data]?
	#endif
}
```

**Properties:**
- `modificationDate` - Last modification timestamp (required)
- `creationDate` - Creation timestamp (optional)
- `permissions` - Unix-style permissions (optional)
- `owner` - File owner (optional)
- `group` - File group (optional)
- `extendedAttributes` - Extended file attributes (platform-specific)

### Diffa Namespace

Top-level namespace for the library.

```swift
struct Diffa {
	// Contains nested types and operations
}
```

**Purpose:**
- Prevent namespace pollution
- Organize related types
- Provide clear entry point

### Difference

Lightweight comparison result that references two snapshots.

```swift
extension Diffa {
	struct Difference<T: ItemProtocol> {
		let sourceSnapshot: Snapshot      // Reference to snapshot A
		let destinationSnapshot: Snapshot // Reference to snapshot B

		// Factory method (creates snapshots and compares)
		static func compare(
			source: URL,
			destination: URL,
			progress: ((ComparisonProgress) -> Void)? = nil
		) async throws -> Difference<T>

		// Factory method (from existing snapshots)
		static func compare(
			source: Snapshot,
			destination: Snapshot
		) throws -> Difference<T>

		// Query differences (lazy evaluation via SQL)
		func getAdded() throws -> [T]      // In destination, not in source
		func getRemoved() throws -> [T]    // In source, not in destination
		func getModified() throws -> [T]   // In both but different

		// Cached results (computed on first access)
		var added: [T] { get }
		var removed: [T] { get }
		var modified: [T] { get }
	}
}
```

**In-memory representation:**
```
Difference struct: ~400 bytes (just snapshot references)
+ Cached results: variable (only changed items)
```

**Usage:**
```swift
// Option 1: Compare directories (creates snapshots internally)
let diff = try await Diffa.Difference.compare(
	source: dirA,
	destination: dirB
)

// Option 2: Compare existing snapshots (lightweight)
let snapA = try Snapshot.load(from: "a.diffa")
let snapB = try Snapshot.load(from: "b.diffa")
let diff = try Diffa.Difference.compare(
	source: snapA,
	destination: snapB
)

// Access results (queries SQLite as needed)
print("Added: \(diff.added.count)")
print("Removed: \(diff.removed.count)")
print("Modified: \(diff.modified.count)")
```

**Properties:**
- `sourceSnapshot` - Reference to source snapshot database
- `destinationSnapshot` - Reference to destination snapshot database
- `added` - Items in destination but not in source (lazy/cached)
- `removed` - Items in source but not in destination (lazy/cached)
- `modified` - Items in both but different (lazy/cached)

**Key features:**
- Lightweight (~400 bytes without cache)
- SQL-powered comparison using ATTACH DATABASE
- Lazy evaluation (compute only what's needed)
- Reusable snapshots (compare A to B, B to C, A to C)
- Historical comparison (load old snapshots)

### ComparisonProgress

Progress information during comparison.

```swift
struct ComparisonProgress {
	var currentItem: String
	var itemsProcessed: Int
	var totalItems: Int?
	var bytesProcessed: Int64
	var totalBytes: Int64?
}
```

**Usage:**
```swift
let diff = try await Diffa.Difference.compare(
	source: a,
	destination: b,
	progress: { progress in
		print("\(progress.itemsProcessed) / \(progress.totalItems ?? 0)")
	}
)
```

### Patch

Serializable set of operations to transform folders.

```swift
struct Patch {
	let operations: [PatchOperation]
	let metadata: PatchMetadata
	let revertData: RevertData?

	static func create(
		from difference: Difference<T>,
		includeRevertData: Bool = true,
		cacheDirectory: URL? = nil,
		inlineThreshold: Int64 = 1_048_576
	) -> Patch

	func apply(to target: URL) async throws
	func revert(on target: URL) async throws
	func save(to url: URL) throws
	static func load(from url: URL) throws -> Patch
}

struct RevertData {
	let originalFiles: [String: OriginalFileData]
	let cacheLocation: URL?
}

struct OriginalFileData {
	let path: String
	let content: Data?
	let cacheReference: String?
	let metadata: Metadata
}
```

**Operations:**
- `create` - Convert Difference to Patch
- `apply` - Apply patch to folder
- `revert` - Undo applied patch
- `save` - Serialize to disk
- `load` - Deserialize from disk

### PatchOperation

Individual operations in a patch.

```swift
enum PatchOperation: Codable {
	case add(path: String, content: Data, metadata: Metadata)
	case remove(path: String)
	case modify(path: String, content: Data, metadata: Metadata)
	case move(from: String, to: String)
}
```

**Operation types:**
- `add` - Create new file/folder
- `remove` - Delete file/folder
- `modify` - Update existing file
- `move` - Move/rename file (optimization)

### PatchMetadata

Metadata for patches.

```swift
struct PatchMetadata: Codable {
	let createdDate: Date
	let sourceChecksum: String?
	let targetChecksum: String?
	let version: String
}
```

**Properties:**
- `createdDate` - When patch was created
- `sourceChecksum` - Expected source state (for verification)
- `targetChecksum` - Expected target state (for verification)
- `version` - Patch format version

### Synchronization Types

Synchronization operations and results.

```swift
extension Diffa {
	static func syncUnidirectional(
		source: URL,
		destination: URL,
		progress: ((SyncProgress) -> Void)? = nil
	) async throws -> SyncResult

	static func syncBidirectional(
		a: URL,
		b: URL,
		conflictResolution: ConflictResolution = .newest,
		progress: ((SyncProgress) -> Void)? = nil
	) async throws -> SyncResult
}
```

### SyncProgress

Progress information during synchronization.

```swift
struct SyncProgress {
	var currentOperation: String
	var filesProcessed: Int
	var totalFiles: Int?
	var bytesTransferred: Int64
	var totalBytes: Int64?
	var operationType: OperationType
}

enum OperationType {
	case copying
	case deleting
	case moving
	case comparing
}
```

### SyncResult

Result of synchronization operation.

```swift
struct SyncResult {
	let filesCopied: Int
	let filesDeleted: Int
	let filesMoved: Int
	let bytesTransferred: Int64
	let conflicts: [ConflictResolution]
	let duration: TimeInterval
	let errors: [SyncError]
}
```

### ConflictResolution

Strategy for resolving sync conflicts.

```swift
enum ConflictResolution {
	case newest
	case sourceWins
	case destinationWins
	case manual(ConflictResolver)
	case keepBoth
	case error
}

typealias ConflictResolver = (Conflict) async -> ConflictAction

enum ConflictAction {
	case useA
	case useB
	case keepBoth
	case skip
	case abort
}
```

### Snapshot Types

Lightweight directory state snapshots for verification.

```swift
extension Diffa {
	struct Snapshot {
		let databaseURL: URL          // Reference to SQLite database file
		let rootPath: String          // Cached from database
		let createdDate: Date         // Cached from database
		let metadata: SnapshotMetadata  // Cached from database

		// Create snapshot and save to SQLite database
		static func create(
			from directory: URL,
			saveTo snapshotURL: URL,
			progress: ((SnapshotProgress) -> Void)? = nil
		) async throws -> Snapshot

		// Load snapshot from SQLite database
		static func load(from url: URL) throws -> Snapshot

		// Compare snapshot to directory (queries database as needed)
		func compare(
			to directory: URL,
			progress: ((ComparisonProgress) -> Void)? = nil
		) async throws -> SnapshotDifference

		// Compare two snapshots (SQL-based comparison)
		func compare(to other: Snapshot) throws -> SnapshotDifference

		// Navigation methods (query database)
		func listRootItems() throws -> [SnapshotItem]
		func listChildren(of parentId: Int) throws -> [SnapshotItem]
		func getItem(path: String) throws -> SnapshotItem?
		func getParent(of itemId: Int) throws -> SnapshotItem?
		func listDescendants(of itemId: Int, filesOnly: Bool) throws -> [SnapshotItem]
	}

	struct SnapshotItem: Codable, Equatable {
		let path: String
		let isFolder: Bool
		let sha256: String?
		let size: Int64
		let metadata: Metadata
	}

	struct SnapshotMetadata: Codable {
		let totalFiles: Int
		let totalFolders: Int
		let totalSize: Int64
		let version: String
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

		var hasChanges: Bool {
			!added.isEmpty || !removed.isEmpty || !modified.isEmpty
		}
	}
}
```

**Purpose:**
- Capture directory state without storing content
- Lightweight verification and change detection
- File-based storage (not memory-based) for large directories
- Stream processing to handle arbitrarily large directories
- Serializable for historical comparison
- No revert/apply - observation only

**SQLite schema for hierarchical structure:**

```sql
CREATE TABLE items (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	parent_id INTEGER,           -- NULL for root, references items(id)
	name TEXT NOT NULL,          -- Item name only
	path TEXT NOT NULL UNIQUE,   -- Full relative path
	is_folder INTEGER NOT NULL,
	sha256 TEXT,
	size INTEGER NOT NULL,
	modification_date TEXT NOT NULL,
	FOREIGN KEY (parent_id) REFERENCES items(id)
);

CREATE INDEX idx_items_path ON items(path);
CREATE INDEX idx_items_sha256 ON items(sha256);
CREATE INDEX idx_items_parent_id ON items(parent_id);
```

**Key implementation notes:**
- **Snapshot object is just a reference to a SQLite database file (~200 bytes)**
- All snapshot data lives in the .diffa file on disk, not in memory
- Snapshot is always file-based (SQLite database)
- Stream items to database incrementally (INSERT per item)
- Hierarchical structure with parent-child relationships
- Support both tree navigation and path-based lookup
- Memory usage constant regardless of directory size (~10-30 MB during operations)
- SQLite WITH RECURSIVE for tree traversal
- Operations query database as needed (SELECT statements)
- Multiple Snapshot objects can reference same database file

## Module Structure

```
Diffa/
├── Core/
│   ├── ItemProtocol.swift
│   ├── Metadata.swift
│   └── FileSystemItem.swift
├── Comparison/
│   ├── Difference.swift
│   ├── ComparisonProgress.swift
│   └── ComparisonEngine.swift
├── Patching/
│   ├── Patch.swift
│   ├── PatchOperation.swift
│   ├── PatchMetadata.swift
│   ├── RevertData.swift
│   └── PatchEngine.swift
├── Synchronization/
│   ├── SyncEngine.swift
│   ├── SyncProgress.swift
│   ├── SyncResult.swift
│   └── ConflictResolution.swift
├── Snapshots/
│   ├── Snapshot.swift
│   ├── SnapshotItem.swift
│   ├── SnapshotMetadata.swift
│   ├── SnapshotDifference.swift
│   └── SnapshotEngine.swift
├── Optimization/
│   ├── MoveDetector.swift
│   ├── HashCache.swift
│   └── OptimizationOptions.swift
└── Utilities/
    ├── HashUtilities.swift
    ├── FileOperations.swift
    └── ErrorTypes.swift
```

## Implementation Modules

### Core Module
- Define protocols and base types
- Platform-agnostic interfaces
- Foundation for all operations

### Comparison Module
- Implement comparison algorithm
- Build directory trees
- Compute hashes
- Generate Difference results

### Patching Module
- Create patches from Differences
- Serialize/deserialize patches
- Apply and revert patches
- Handle patch operations

### Synchronization Module
- Unidirectional sync
- Bidirectional sync
- Conflict resolution
- Progress reporting

### Snapshots Module
- Create directory snapshots
- Capture structure, hashes, metadata
- Compare snapshots to directories
- Serialize/deserialize snapshots
- No content storage

### Optimization Module
- Move detection
- Hash caching
- Parallel processing
- Performance optimization

### Utilities Module
- SHA-256 hashing
- File I/O operations
- Error handling
- Helper functions

## Error Handling

### Error Types

```swift
enum DiffaError: Error {
	case fileNotFound(path: String)
	case permissionDenied(path: String)
	case hashComputationFailed(path: String)
	case patchApplicationFailed(reason: String)
	case syncFailed(reason: String)
	case invalidPatch(reason: String)
	case diskSpaceInsufficient
	case operationCancelled
}
```

## Threading Model

### Async/Await

All I/O operations use Swift concurrency:
- `async` functions for long-running operations
- `throws` for error handling
- Proper cancellation support

### Concurrency

```swift
// Example: Parallel hashing
await withTaskGroup(of: (String, String).self) { group in
	for file in files {
		group.addTask {
			let hash = try await computeSHA256(file)
			return (file.path, hash)
		}
	}
}
```

### Progress Callbacks

Use escaping closures for progress:
- Called from background thread
- User responsible for dispatching to main if needed
- Non-blocking callbacks

## Testing Strategy

### Unit Tests
- Test individual components
- Mock file system operations
- Test error conditions

### Integration Tests
- Test full workflows
- Use real file system (temporary directories)
- Test edge cases

### Performance Tests
- Benchmark optimization impact
- Test with large datasets
- Measure memory usage

## Platform Considerations

### macOS/iOS Specific
- Use FileManager for file operations
- Support for extended attributes
- APFS optimizations (file cloning)

### Future: Cross-platform
- Abstract file system operations
- Platform-specific implementations
- Conditional compilation for platform features
