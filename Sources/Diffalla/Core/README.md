# Diffalla Core Module

Core types and protocols for file system metadata representation.

## Overview

The Core module provides fundamental types for representing file system items and their metadata. These types are used throughout Diffalla for snapshot creation and comparison.

## Key Types

### FileSystemItem

Represents a file or directory read from the file system with full metadata.

```swift
let item = try FileSystemItem(
    at: fileURL,
    relativeTo: baseURL,
    captureOwnership: false,
    followSymlinks: true
)

print("Path: \(item.path)")
print("Size: \(item.size) bytes")
print("SHA-256: \(item.sha256 ?? "N/A")")
print("Permissions: \(item.metadata.permissions.symbolic)")
```

**Properties:**
- `path: String` - Relative path from snapshot root
- `isFolder: Bool` - True for directories
- `sha256: String?` - SHA-256 hash of file content (nil for folders)
- `size: Int64` - File size in bytes
- `metadata: Metadata` - File system metadata

**Symlink Handling:**
- `followSymlinks: true` - Reads target's attributes and computes hash
- `followSymlinks: false` - Reads symlink's own attributes, no hash

### Metadata

File system metadata captured during snapshot.

```swift
let metadata = Metadata(
    modificationDate: Date(),
    size: 1024,
    permissions: FilePermissions(posix: 0o644),
    owner: "user",
    group: "staff"
)

print("Modified: \(metadata.modificationDate)")
print("Permissions: \(metadata.permissions.octalString)") // "644"
```

**Properties:**
- `modificationDate: Date` - Last modification date
- `size: Int64` - File size in bytes
- `permissions: FilePermissions` - File permissions
- `owner: String?` - File owner (nil unless `captureOwnership` enabled)
- `group: String?` - File group (nil unless `captureOwnership` enabled)

### FilePermissions

POSIX file permissions with symbolic and octal representations.

```swift
let perms = FilePermissions(posix: 0o755)

print(perms.symbolic)      // "rwxr-xr-x"
print(perms.octalString)   // "755"
print(perms.posix)         // 493 (0o755 in decimal)
```

**Properties:**
- `posix: UInt16` - POSIX permissions as octal value (canonical source)
- `symbolic: String` - Symbolic representation (e.g., "rwxr-xr-x")
- `octalString: String` - Octal string representation (e.g., "755")

### ScanOptions

Configuration options for directory scanning.

```swift
let options = ScanOptions(
    followSymlinks: true,
    includeHidden: true,
    captureOwnership: false
)
```

**Options:**
- `followSymlinks: Bool` - Follow symbolic links to their target (default: true)
- `includeHidden: Bool` - Include hidden files starting with '.' (default: true)
- `captureOwnership: Bool` - Capture file owner/group (default: false)

**Defaults:**
- Follows symlinks (matches `rsync`, `cp -r` behavior)
- Includes hidden files (captures complete directory state)
- Skips ownership (often not useful across machines)

### DiffallaError

High-level application errors with descriptive messages.

```swift
do {
    let snapshot = try Snapshot.open(at: url)
} catch DiffallaError.invalidSnapshot(let reason) {
    print("Invalid snapshot: \(reason)")
} catch DiffallaError.fileNotFound(let path) {
    print("File not found: \(path)")
}
```

**Error Cases:**
- `fileNotFound(path:)` - File or directory not found
- `permissionDenied(path:)` - Permission denied accessing file
- `hashComputationFailed(path:, underlying:)` - Failed to compute SHA-256 hash
- `snapshotCreationFailed(reason:)` - Snapshot creation failed
- `snapshotLoadFailed(reason:)` - Failed to load snapshot from database
- `comparisonFailed(reason:)` - Snapshot comparison failed
- `invalidSnapshot(reason:)` - Invalid or corrupt snapshot file
- `databaseError(reason:, underlying:)` - Database operation failed

All errors implement `CustomStringConvertible` for clear, user-friendly error messages.

## Protocols

### ItemProtocol

Protocol for items that can be compared and snapshotted.

```swift
protocol ItemProtocol: Equatable {
    var path: String { get }
    var isFolder: Bool { get }
    var sha256: String? { get }
    var size: Int64 { get }
    var metadata: Metadata { get }
}
```

**Conforming Types:**
- `FileSystemItem` - Items read from disk
- `SnapshotItem` - Items loaded from snapshot database

## Design Philosophy

**Simple First:**
- Clear, straightforward types without unnecessary complexity
- Sensible defaults for common use cases

**Cross-Platform:**
- Uses standard Foundation APIs
- POSIX permissions for compatibility

**Memory Efficient:**
- Value semantics (structs) for lightweight copying
- Computed properties instead of storing redundant data
- SHA-256 only computed for files (not folders or symlinks)

## Performance Characteristics

- **FileSystemItem creation:** O(1) file reads + O(n) hash computation for files
- **Hash computation:** 64 KB chunks, ~100 MB/s typical throughput
- **Memory usage:** ~200 bytes per FileSystemItem
- **Metadata access:** Constant time (all properties stored directly)

## Thread Safety

All Core types are thread-safe for reading:
- Structs with value semantics
- Immutable once created
- Can be safely passed between threads

Creating FileSystemItems from disk is not thread-safe (file system operations).

## See Also

- [Snapshots Module](../Snapshots/README.md) - Snapshot creation and storage
- [Comparison Module](../Comparison/README.md) - Snapshot comparison
