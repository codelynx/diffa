# Patching (Objectives 2 & 3)

## Goals

### Objective 2: Create Patches
Generate patches that describe how to transform folder A to B (or B to A).

### Objective 3: Apply and Revert Patches
Apply patches to transform folders or revert changes.

## Use Cases

### Deployment Packages
- Create patch from development to production state
- Package patch for distribution
- Apply patch on target systems
- Revert if deployment fails

### Backup Deltas
- Create incremental backup patches
- Store only changes instead of full copies
- Apply patches to restore to specific point in time

### Install/Uninstall
- Create installation patch from empty state to installed state
- Apply patch to install
- Revert patch to uninstall

### Deploy/Rollback
- Deploy new version via patch
- Rollback to previous version by reverting patch

## Patch Structure

### Patch Object

A patch contains a series of operations needed to transform source to destination.

```swift
struct Patch {
	let operations: [PatchOperation]
	let metadata: PatchMetadata
	let revertData: RevertData?    // Optional data for reverting

	static func create(
		from difference: Difference<T>,
		includeRevertData: Bool = true,
		cacheDirectory: URL? = nil,  // Optional: specify cache location
		inlineThreshold: Int64 = 1_048_576  // 1MB default
	) -> Patch

	func apply(to target: URL) async throws
	func revert(on target: URL) async throws
	func save(to url: URL) throws
	static func load(from url: URL) throws -> Patch
}
```

### Patch Operations

```swift
enum PatchOperation {
	case add(path: String, content: Data, metadata: Metadata)
	case remove(path: String)
	case modify(path: String, content: Data, metadata: Metadata)
	case move(from: String, to: String)
}
```

### Patch Metadata

```swift
struct PatchMetadata {
	let createdDate: Date
	let sourceChecksum: String?    // Optional verification
	let targetChecksum: String?    // Optional verification
	let version: String            // Patch format version
}
```

### Revert Data

Data needed to revert a patch after it's been applied.

```swift
struct RevertData {
	let originalFiles: [String: OriginalFileData]
	let cacheLocation: URL?    // Optional cache directory for large files
}

struct OriginalFileData {
	let path: String
	let content: Data?         // Inline content for small files
	let cacheReference: String?  // Reference to cached file for large files
	let metadata: Metadata
}
```

**Storage strategies:**

1. **Inline storage** (small files < 1MB)
   - Store original content directly in patch
   - Fast, self-contained
   - Increases patch size

2. **Cache directory** (large files)
   - Save original files to local cache/temp directory
   - Patch references cache location
   - Smaller patch size
   - Requires cache availability for revert

3. **Hybrid approach**
   - Inline for small files
   - Cache reference for large files
   - Balance between patch size and self-containment

## Creating Patches

### From Difference

Convert a Difference result into a Patch:

```swift
let diff = try await Diffa.Difference.compare(
	source: sourceFolder,
	destination: destFolder
)

// Create patch with revert data
let patch = Patch.create(from: diff, includeRevertData: true)

// Or create without revert data (smaller, but not reversible)
let patchNoRevert = Patch.create(from: diff, includeRevertData: false)
```

### Conversion Logic

- **Added items** → `add` operations
- **Removed items** → `remove` operations
- **Modified items** → `modify` operations
- **Move detection** → `move` operations (optimization)

### Preserving Original Content for Revert

When `includeRevertData: true`, the patch creation process:

1. **Identify files that will be overwritten or removed**
   - Modified files (will be overwritten)
   - Removed files (will be deleted)
   - Files affected by moves

2. **Save original content**
   - Small files (< 1MB): Store content inline in patch
   - Large files: Save to cache directory and store reference

3. **Build RevertData structure**
   - Map of file paths to original content
   - Cache location (if using cache)
   - Original metadata for each file

**Example with cache directory:**

```swift
let cacheDir = FileManager.default.temporaryDirectory
	.appendingPathComponent("diffa-cache")
	.appendingPathComponent(UUID().uuidString)

let diff = try await Diffa.Difference.compare(
	source: sourceFolder,
	destination: destFolder
)

let patch = Patch.create(
	from: diff,
	includeRevertData: true,
	cacheDirectory: cacheDir  // Optional: specify cache location
)

// Original files are now saved in cacheDir
// Patch contains references to cached files
```

### Move Detection

Detect when a file was moved/renamed rather than deleted and re-added:
- Compare SHA-256 hashes
- If removed file has same hash as added file → it's a move
- Use `move` operation instead of `remove` + `add`
- Preserves file data, faster, uses less space

## Applying Patches

### Forward Application

Transform target folder using patch:

```swift
let patch = try Patch.load(from: patchURL)
try await patch.apply(to: targetFolderURL)
```

### Application Process

1. **Validation** (optional)
   - Verify target matches expected source state
   - Check source checksum if provided

2. **Execute operations**
   - Process operations in order
   - Handle each operation type appropriately

3. **Verification** (optional)
   - Verify result matches expected destination state
   - Check target checksum if provided

### Operation Execution

- **Add**: Create file/folder at path with content
- **Remove**: Delete file/folder at path
- **Modify**: Update file content and metadata
- **Move**: Move/rename file from old path to new path

### Error Handling

If operation fails:
- Stop processing
- Throw error with details
- Consider partial rollback options
- Let caller decide how to handle

## Reverting Patches

### Reverse Application

Undo a patch that was applied:

```swift
try await patch.revert(on: targetFolderURL)
```

### Revert Process

Execute operations in reverse using stored RevertData:

1. **Add** → Remove the added file/folder
   - Delete file that was created
   - No original content needed

2. **Remove** → Restore the deleted file
   - Retrieve original content from RevertData
   - If inline: Use content from patch
   - If cached: Load from cache directory
   - Restore with original metadata

3. **Modify** → Restore original content
   - Retrieve original file data from RevertData
   - Overwrite current content with original
   - Restore original metadata

4. **Move** → Move back to original location
   - Move file from new location back to old location
   - No content restoration needed

**Example:**

```swift
// Apply patch
try await patch.apply(to: targetFolder)

// Later, revert the changes
try await patch.revert(on: targetFolder)

// If using cache directory, ensure it still exists:
if let cacheLocation = patch.revertData?.cacheLocation {
	guard FileManager.default.fileExists(atPath: cacheLocation.path) else {
		throw DiffaError.cacheNotFound
	}
}
```

### Cache Management

**When using cache directory:**

1. **During apply**: Cache is read but not deleted (needed for revert)
2. **After successful revert**: Optionally clean up cache
3. **If cache deleted**: Revert will fail

**Best practices:**

```swift
// Keep cache until after revert
let patch = Patch.create(from: diff, includeRevertData: true)
try await patch.apply(to: target)

// Do work...

// Revert if needed
try await patch.revert(on: target)

// Clean up cache
if let cache = patch.revertData?.cacheLocation {
	try FileManager.default.removeItem(at: cache)
}
```

### Limitations and Requirements

**For successful revert:**

1. **RevertData must be present**
   - Patch must have been created with `includeRevertData: true`
   - Cannot revert if patch has no revert data

2. **Cache must be accessible** (if using cache)
   - Cache directory must still exist
   - Original files must be intact in cache
   - Read permissions on cache

3. **Target folder must be in expected state**
   - Optional: Verify checksums before revert
   - Detect if files were modified after patch application

## Patch Serialization

### File Format

Store patches in a serializable format:

**Option 1: JSON**
- Human-readable
- Easy to parse
- Larger file size

**Option 2: Binary**
- Compact
- Faster to parse
- Not human-readable

**Option 3: Custom format**
- Optimized for use case
- May include compression

### Example JSON Format

```json
{
	"version": "1.0",
	"metadata": {
		"createdDate": "2025-11-05T12:34:56Z",
		"sourceChecksum": "abc123...",
		"targetChecksum": "def456..."
	},
	"operations": [
		{
			"type": "add",
			"path": "folder/newfile.txt",
			"content": "base64encodedcontent...",
			"metadata": {...}
		},
		{
			"type": "remove",
			"path": "folder/oldfile.txt"
		},
		{
			"type": "modify",
			"path": "folder/modified.txt",
			"content": "base64encodedcontent...",
			"metadata": {...}
		},
		{
			"type": "move",
			"from": "old/path.txt",
			"to": "new/path.txt"
		}
	],
	"revertData": {
		"cacheLocation": "/tmp/diffa-cache/uuid-here",
		"originalFiles": {
			"folder/oldfile.txt": {
				"path": "folder/oldfile.txt",
				"content": "base64content...",
				"metadata": {...}
			},
			"folder/modified.txt": {
				"path": "folder/modified.txt",
				"cacheReference": "modified-txt-original",
				"metadata": {...}
			}
		}
	}
}
```

**Note:** In the example above:
- `oldfile.txt` has inline content (small file)
- `modified.txt` uses cache reference (large file, actual content in cache directory)

## Open Questions

1. **Revert data storage location**:
   - Default cache location? (temp dir, user-specified, current dir)
   - Per-patch cache or shared cache pool?

2. **Revert data threshold**:
   - What file size threshold for inline vs cached? (currently: 1MB)
   - Should this be configurable?

3. **Content storage for operations**:
   - Should operation content also use cache/inline hybrid?
   - Currently operations always include content inline

4. **Compression**:
   - Should cached files be compressed?
   - Compression algorithm (gzip, lzma, etc.)?

5. **Checksums**:
   - Include checksums for revert data verification?
   - Verify cache integrity before revert?

6. **Partial patches**:
   - Support applying only part of a patch?
   - How to handle revert data for partial application?

7. **Patch merging**:
   - Can multiple patches be merged?
   - How to merge revert data?

8. **Conflict handling**:
   - What if target was modified since patch creation?
   - Verify state before revert?

9. **Cache cleanup**:
   - Automatic cache cleanup after revert?
   - Cache expiration for orphaned caches?
   - Cache size limits?

10. **Serialization format**:
    - JSON, binary, or custom format?
    - Include revert data in same file or separate?

11. **Cache security**:
    - How to prevent cache tampering?
    - Encrypt sensitive cached files?
