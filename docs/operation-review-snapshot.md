# Operation Review: Snapshot Creation

This document reviews the snapshot creation operation in detail before implementation.

## Operation: Create Snapshot

**Purpose:** Create a lightweight snapshot of a directory's state without storing file content.

**Key constraint:** MUST be file-based (not memory-based) because directories can be huge (100k+ files).

## Step-by-Step Process

### Step 1: Initialize

**Input:**
- `directory: URL` - The directory to snapshot
- `snapshotURL: URL` - Where to save the snapshot file

**Action:**
1. Create/open snapshot file for writing at `snapshotURL`
2. Initialize counters:
   - `totalFiles = 0`
   - `totalFolders = 0`
   - `totalSize = 0`
3. Write JSON header:
   ```json
   {
     "version": "1.0",
     "rootPath": "/path/to/directory",
     "createdDate": "2025-11-05T...",
     "items": [
   ```

### Step 2: Traverse Directory

**Action:**
1. Use `FileManager.enumerator(at: directory)` to traverse recursively
2. Enumerate all files and folders depth-first

**For each item encountered:**

### Step 3a: Process Folder

**If item is a folder:**

1. Compute relative path from root
2. Get folder attributes from FileManager
3. Create `SnapshotItem`:
   - `path`: relative path (e.g., "subfolder/nested")
   - `isFolder`: true
   - `sha256`: nil (folders don't have hashes)
   - `size`: 0 (or total size of contents)
   - `metadata`: modification date, permissions, etc.
4. Write item to snapshot file immediately (as JSON)
5. Increment `totalFolders`
6. Report progress

### Step 3b: Process File

**If item is a file:**

1. Compute relative path from root
2. Get file attributes from FileManager
3. **Compute SHA-256 hash:**
   - Open file for reading
   - Read file content (streaming for large files)
   - Compute SHA-256 hash
   - Close file
   - **Release file content from memory**
4. Create `SnapshotItem`:
   - `path`: relative path (e.g., "file.txt")
   - `isFolder`: false
   - `sha256`: computed hash string
   - `size`: file size in bytes
   - `metadata`: modification date, permissions, etc.
5. Write item to snapshot file immediately (as JSON)
6. Increment `totalFiles`
7. Add to `totalSize`
8. Report progress

**Critical:** Item is written immediately and can be garbage collected. Do NOT accumulate all items in memory.

### Step 4: Finalize

**Action:**
1. Close JSON items array:
   ```json
   ]
   ```
2. Write metadata section:
   ```json
   "metadata": {
     "totalFiles": 1234,
     "totalFolders": 56,
     "totalSize": 123456789,
     "version": "1.0"
   }
   ```
3. Close JSON object:
   ```json
   }
   ```
4. Flush and close snapshot file

### Step 5: Return

**Action:**
Return `Snapshot` object containing:
- `rootPath`: original directory path
- `createdDate`: timestamp when snapshot was created
- `fileURL`: location of snapshot file (for later loading)
- `metadata`: summary statistics (totalFiles, totalFolders, totalSize)

**Note:** The returned `Snapshot` object does NOT contain all items in memory. It only holds metadata and a reference to the file.

## Data Flow

```
Directory
    ↓
Traverse (enumerator)
    ↓
For each item:
    ↓
Get attributes (FileManager)
    ↓
[If file] Compute SHA-256
    ↓
Create SnapshotItem
    ↓
Write to file immediately ← STREAMING (no memory accumulation)
    ↓
Release from memory
    ↓
Continue to next item
    ↓
Finalize file
    ↓
Return Snapshot (lightweight object with file reference)
```

## Memory Management

### What's in memory:

**During creation:**
- Current file being hashed (released immediately after)
- Current SnapshotItem (released after writing)
- Counters (totalFiles, etc.) - trivial
- File writer/buffer - small

**Total:** ~10-20 MB regardless of directory size

### What's NOT in memory:

- All SnapshotItems (they're streamed to disk)
- File contents (read, hash, release immediately)
- Complete snapshot data structure

### After creation:

**Snapshot object contains:**
- `rootPath: String` - trivial
- `createdDate: Date` - trivial
- `fileURL: URL` - trivial
- `metadata: SnapshotMetadata` - ~50 bytes

**Total:** ~200 bytes

## Performance Estimates

| Directory | Files | Size | Snapshot File | Time | Memory |
|-----------|-------|------|---------------|------|--------|
| Small | 1,000 | 100 MB | 100 KB | ~5 sec | < 10 MB |
| Medium | 10,000 | 1 GB | 1 MB | ~30 sec | < 10 MB |
| Large | 100,000 | 10 GB | 10 MB | ~5 min | < 20 MB |
| Huge | 1,000,000 | 100 GB | 100 MB | ~50 min | < 30 MB |

**Key point:** Memory usage stays constant even for massive directories!

## Storage Locations

### 1. User-specified (explicit path)
```swift
let snapshot = try await Snapshot.create(
    from: directory,
    saveTo: URL(fileURLWithPath: "/my/snapshots/baseline.json")
)
```
**Pros:** Full control, persistent
**Cons:** User must manage location

### 2. Temporary directory
```swift
let snapshotURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("snapshot-\(UUID()).json")
let snapshot = try await Snapshot.create(
    from: directory,
    saveTo: snapshotURL
)
```
**Pros:** Automatic cleanup on reboot
**Cons:** May be cleared anytime

### 3. Cache directory
```swift
let cacheDir = try FileManager.default.url(
    for: .cachesDirectory,
    in: .userDomainMask,
    appropriateFor: nil,
    create: true
)
let snapshotURL = cacheDir.appendingPathComponent("diffalla/snapshot.json")
let snapshot = try await Snapshot.create(
    from: directory,
    saveTo: snapshotURL
)
```
**Pros:** Persistent across reboots, OS can clean if needed
**Cons:** May be cleared by OS under storage pressure

## File Format

### JSON Structure

```json
{
  "version": "1.0",
  "rootPath": "/Users/user/project",
  "createdDate": "2025-11-05T12:34:56Z",
  "items": [
    {
      "path": "file1.txt",
      "isFolder": false,
      "sha256": "abc123...",
      "size": 1024,
      "metadata": {
        "modificationDate": "2025-11-05T10:00:00Z"
      }
    },
    {
      "path": "folder1",
      "isFolder": true,
      "sha256": null,
      "size": 0,
      "metadata": {
        "modificationDate": "2025-11-05T09:00:00Z"
      }
    },
    {
      "path": "folder1/file2.txt",
      "isFolder": false,
      "sha256": "def456...",
      "size": 2048,
      "metadata": {
        "modificationDate": "2025-11-05T11:00:00Z"
      }
    }
  ],
  "metadata": {
    "totalFiles": 2,
    "totalFolders": 1,
    "totalSize": 3072,
    "version": "1.0"
  }
}
```

### Size Calculation

Per item: ~100 bytes average
- Path: ~30 bytes
- SHA-256: 64 characters = 64 bytes
- Metadata: ~6 bytes
- JSON overhead: ~10 bytes

1,000 files = ~100 KB
10,000 files = ~1 MB
100,000 files = ~10 MB
1,000,000 files = ~100 MB

## Progress Reporting

During creation, report progress via callback:

```swift
struct SnapshotProgress {
    var currentPath: String       // File/folder currently processing
    var filesProcessed: Int       // Files processed so far
    var totalFiles: Int?          // Total files (nil if unknown)
    var bytesProcessed: Int64     // Bytes processed so far
}
```

**Example:**
```swift
let snapshot = try await Snapshot.create(
    from: directory,
    saveTo: snapshotURL,
    progress: { progress in
        print("Processing: \(progress.currentPath)")
        print("Files: \(progress.filesProcessed)")
    }
)
```

## Error Handling

**Possible errors:**
1. Directory doesn't exist → `FileNotFound`
2. No read permission → `PermissionDenied`
3. Can't create snapshot file → `CannotCreateFile`
4. Disk full → `DiskFull`
5. File hash computation fails → `HashComputationFailed`

All operations are `async throws` to handle these errors.

## Review Summary

✅ **File-based storage** - not memory-based
✅ **Streaming** - items written immediately, not accumulated
✅ **Constant memory** - regardless of directory size
✅ **Progress reporting** - user can monitor long operations
✅ **Configurable location** - temp, cache, or user-specified
✅ **Lightweight result** - Snapshot object just holds reference

**Ready for implementation?** YES / NO

If any concerns, document them here before proceeding to coding phase.
