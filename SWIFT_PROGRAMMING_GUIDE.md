# Swift Programming Guide

A comprehensive guide for Swift developers who want to use Diffa as a library in their macOS/iOS applications.

## Table of Contents

- [Quick Start](#quick-start)
- [Installation](#installation)
- [Snapshots API](#snapshots-api)
- [Comparison API](#comparison-api)
- [Patching API](#patching-api)
- [Synchronization API](#synchronization-api)
- [EfficientSync API](#efficientsync-api)
- [Network Sync API](#network-sync-api)
- [Error Handling](#error-handling)
- [Best Practices](#best-practices)

---

## Quick Start

```swift
import Diffa

// Create a snapshot of a directory
let engine = SnapshotEngine()
let snapshot = try await engine.createSnapshot(
    from: URL(fileURLWithPath: "/path/to/directory"),
    saveTo: URL(fileURLWithPath: "/path/to/snapshot.diffa"),
    options: ScanOptions()
)

print("Files: \(snapshot.metadata.totalFiles)")
print("Size: \(snapshot.metadata.totalSize) bytes")
```

---

## Installation

Add Diffa to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/codelynx/Diffa.git", from: "0.12.0")
]
```

Then add the dependency to your target:

```swift
.target(
    name: "YourApp",
    dependencies: ["Diffa"]
)
```

Import in your Swift files:

```swift
import Diffa
```

---

## Snapshots API

Snapshots capture the state of a directory at a point in time, including file paths, sizes, hashes, and modification times.

### Creating a Snapshot

```swift
import Diffa

let engine = SnapshotEngine()

// Basic snapshot creation
let snapshot = try await engine.createSnapshot(
    from: URL(fileURLWithPath: "/Users/me/Documents"),
    saveTo: URL(fileURLWithPath: "/tmp/documents.diffa"),
    options: ScanOptions()
)

// With progress tracking
let snapshot = try await engine.createSnapshot(
    from: directoryURL,
    saveTo: snapshotURL,
    options: ScanOptions(),
    progress: { progress in
        print("Processing: \(progress.currentPath)")
        print("Files: \(progress.filesProcessed), Bytes: \(progress.bytesProcessed)")
    }
)
```

### Scan Options

```swift
// Default options
let options = ScanOptions()

// Customized options
let options = ScanOptions(
    followSymlinks: true,          // Follow symbolic links (default: true)
    includeHidden: true,           // Include hidden files (default: true)
    captureOwnership: false,       // Capture owner/group (default: false)
    useHashCache: true,            // Cache file hashes (default: false)
    hashCacheDirectory: cacheURL,  // Custom cache location (default: ~/.diffa/cache/)
    useParallelHashing: true,      // Use multiple CPU cores (default: false)
    maxConcurrentHashing: 8        // Max concurrent hash operations
)
```

### Opening an Existing Snapshot

```swift
let snapshot = try Snapshot.open(at: URL(fileURLWithPath: "/path/to/snapshot.diffa"))

print("Root path: \(snapshot.rootPath)")
print("Created: \(snapshot.createdDate)")
print("Files: \(snapshot.metadata.totalFiles)")
print("Folders: \(snapshot.metadata.totalFolders)")
print("Total size: \(snapshot.metadata.totalSize)")
```

### Querying Snapshot Contents

```swift
let snapshot = try Snapshot.open(at: snapshotURL)

// Load all items
let allItems = try snapshot.loadAllItems()
for item in allItems {
    print("\(item.isFolder ? "D" : "F") \(item.path) (\(item.size) bytes)")
}

// Load a specific item
if let item = try snapshot.loadItem(path: "Documents/file.txt") {
    print("Found: \(item.path)")
    print("Size: \(item.size)")
    print("Modified: \(item.modificationDate)")
    print("Hash: \(item.hash?.hexString ?? "none")")
}

// Load children of a directory
let children = try snapshot.loadChildren(of: parentId)
```

---

## Comparison API

Compare two snapshots or directories to find differences.

### Comparing Snapshots

```swift
let sourceSnapshot = try Snapshot.open(at: sourceURL)
let destSnapshot = try Snapshot.open(at: destURL)

// Create difference object (lazy evaluation)
let difference = try Difference.compare(source: sourceSnapshot, destination: destSnapshot)

// Check if there are any differences
if try difference.hasDifferences {
    print("Directories differ!")
}

// Get added files (in destination, not in source)
let added = try difference.added
print("Added files: \(added.count)")
for item in added {
    print("  + \(item.path)")
}

// Get removed files (in source, not in destination)
let removed = try difference.removed
print("Removed files: \(removed.count)")
for item in removed {
    print("  - \(item.path)")
}

// Get modified files (different content or metadata)
let modified = try difference.modified
print("Modified files: \(modified.count)")
for item in modified {
    print("  M \(item.path)")
}
```

### Comparing Directories Directly

```swift
let engine = SnapshotEngine()

// Create temporary snapshots and compare
let tempDir = FileManager.default.temporaryDirectory
let sourceSnapshotURL = tempDir.appendingPathComponent("source.diffa")
let destSnapshotURL = tempDir.appendingPathComponent("dest.diffa")

let sourceSnapshot = try await engine.createSnapshot(
    from: sourceDirectory,
    saveTo: sourceSnapshotURL,
    options: ScanOptions()
)

let destSnapshot = try await engine.createSnapshot(
    from: destDirectory,
    saveTo: destSnapshotURL,
    options: ScanOptions()
)

let difference = try Difference.compare(source: sourceSnapshot, destination: destSnapshot)

// Clean up
try? FileManager.default.removeItem(at: sourceSnapshotURL)
try? FileManager.default.removeItem(at: destSnapshotURL)
```

---

## Patching API

Create patches that describe transformations between directory states, then apply or revert them.

### Creating a Patch

```swift
// First, get the difference
let sourceSnapshot = try Snapshot.open(at: sourceSnapshotURL)
let destSnapshot = try Snapshot.open(at: destSnapshotURL)
let difference = try Difference.compare(source: sourceSnapshot, destination: destSnapshot)

// Create a patch (without revert data)
let patch = try Patch.create(
    from: difference,
    sourceDirectory: sourceDirectory,
    destinationDirectory: destDirectory,
    saveTo: patchURL,
    includeRevertData: false
)

// Create a reversible patch (with revert data)
let reversiblePatch = try Patch.create(
    from: difference,
    sourceDirectory: sourceDirectory,
    destinationDirectory: destDirectory,
    saveTo: patchURL,
    includeRevertData: true
)

print("Patch created with \(patch.metadata.operationCount) operations")
```

### Opening and Inspecting a Patch

```swift
let patch = try Patch.open(at: patchURL)

print("Version: \(patch.metadata.version)")
print("Created: \(patch.metadata.createdDate)")
print("Operations: \(patch.metadata.operationCount)")
print("Has revert data: \(try patch.hasRevertData())")

// Load and inspect operations
let operations = try patch.loadOperations()
for operation in operations {
    switch operation {
    case .add(let path, let isFolder):
        print("+ \(path) \(isFolder ? "(dir)" : "")")
    case .remove(let path, let isFolder):
        print("- \(path) \(isFolder ? "(dir)" : "")")
    case .modify(let path, let isFolder):
        print("M \(path) \(isFolder ? "(dir)" : "")")
    case .move(let from, let to, let isFolder):
        print("R \(from) -> \(to) \(isFolder ? "(dir)" : "")")
    }
}
```

### Applying a Patch

```swift
let patch = try Patch.open(at: patchURL)

// Apply with progress tracking
try await patch.apply(to: targetDirectory) { progress in
    print("[\(progress.current)/\(progress.total)] Applying: \(progress.operation)")
}
```

### Reverting a Patch

```swift
let patch = try Patch.open(at: patchURL)

// Check if patch can be reverted
guard try patch.hasRevertData() else {
    print("Patch cannot be reverted (no revert data)")
    return
}

// Revert with progress
try await patch.revert(on: targetDirectory) { progress in
    print("[\(progress.current)/\(progress.total)] Reverting: \(progress.operation)")
}
```

### Exporting Patch Information

```swift
let patch = try Patch.open(at: patchURL)

// Export as text
let text = try patch.exportAsText()
print(text)

// Export as JSON
let json = try patch.exportAsJSON()
try json.write(toFile: "patch.json", atomically: true, encoding: .utf8)

// Export as HTML
let html = try patch.exportAsHTML()
try html.write(toFile: "patch.html", atomically: true, encoding: .utf8)

// Export as detailed diff (requires revert data)
if try patch.hasRevertData() {
    let diff = try patch.exportAsDetailedDiff()
    print(diff)
}
```

---

## Synchronization API

Synchronize directories with conflict detection and resolution.

### Unidirectional Sync (Source → Destination)

```swift
let synchronizer = Synchronizer()

// Basic sync
let result = try await synchronizer.syncUnidirectional(
    source: sourceDirectory,
    destination: destDirectory
)

print("Files copied: \(result.filesCopied)")
print("Files deleted: \(result.filesDeleted)")
print("Bytes transferred: \(result.bytesTransferred)")
print("Duration: \(result.duration) seconds")
```

### Sync Options

```swift
let options = SyncOptions(
    dryRun: false,           // Preview without making changes
    verifyAfterSync: true,   // Verify directories match after sync
    deleteExtraFiles: true   // Delete files in dest not in source
)

let result = try await synchronizer.syncUnidirectional(
    source: sourceDirectory,
    destination: destDirectory,
    options: options
)
```

### Dry Run (Preview Changes)

```swift
let options = SyncOptions(dryRun: true)

let result = try await synchronizer.syncUnidirectional(
    source: sourceDirectory,
    destination: destDirectory,
    options: options
)

print("Would copy \(result.filesCopied) files")
print("Would delete \(result.filesDeleted) files")
print("Would transfer \(result.bytesTransferred) bytes")
```

### Bidirectional Sync

```swift
let synchronizer = Synchronizer()

// Sync with automatic conflict resolution
let result = try await synchronizer.syncBidirectional(
    a: directoryA,
    b: directoryB,
    conflictResolution: .newest  // Keep newer file
)

print("Files copied: \(result.filesCopied)")
print("Conflicts resolved: \(result.conflicts.count)")

for conflict in result.conflicts {
    print("Resolved: \(conflict.conflict.path) -> \(conflict.direction)")
}
```

### Conflict Resolution Strategies

```swift
// Keep the file with the most recent modification time
let result = try await synchronizer.syncBidirectional(
    a: directoryA,
    b: directoryB,
    conflictResolution: .newest
)

// Always prefer source (directory A)
let result = try await synchronizer.syncBidirectional(
    a: directoryA,
    b: directoryB,
    conflictResolution: .sourceWins
)

// Always prefer destination (directory B)
let result = try await synchronizer.syncBidirectional(
    a: directoryA,
    b: directoryB,
    conflictResolution: .destinationWins
)

// Throw error on conflict (manual resolution required)
do {
    let result = try await synchronizer.syncBidirectional(
        a: directoryA,
        b: directoryB,
        conflictResolution: .error
    )
} catch {
    print("Conflict detected, manual resolution required")
}
```

### Progress Tracking

```swift
let result = try await synchronizer.syncUnidirectional(
    source: sourceDirectory,
    destination: destDirectory,
    options: SyncOptions(),
    progress: { syncProgress in
        print("Operation: \(syncProgress.operation)")
        print("Current: \(syncProgress.current)/\(syncProgress.total)")
        print("Bytes: \(syncProgress.bytesProcessed)/\(syncProgress.totalBytes)")
    },
    snapshotProgress: { snapshotProgress in
        print("Scanning: \(snapshotProgress.currentPath)")
        print("Files processed: \(snapshotProgress.filesProcessed)")
    }
)
```

---

## EfficientSync API

Phase 6 introduces a content-addressable sync system optimized for network transfers and large directories.

### Creating an Efficient Snapshot

```swift
// Create snapshot using the efficient sync system
let snapshot = try SQLiteSyncSnapshot.create(at: directoryURL)

print("Files: \(snapshot.allFiles().count)")

// Query files by hash
let files = snapshot.filesByHash(hash)
```

### Comparing Snapshots

```swift
let sourceSnapshot = try SQLiteSyncSnapshot.create(at: sourceDirectory)
let destSnapshot = try SQLiteSyncSnapshot.create(at: destDirectory)

let comparator = SnapshotComparator()
let operations = comparator.compare(source: sourceSnapshot, destination: destSnapshot)

for operation in operations {
    switch operation {
    case .add(let item):
        print("Add: \(item.path)")
    case .delete(let item):
        print("Delete: \(item.path)")
    case .modify(let oldItem, let newItem):
        print("Modify: \(oldItem.path)")
    case .move(let oldItem, let newItem):
        print("Move: \(oldItem.path) -> \(newItem.path)")
    }
}
```

### Using ContentTracker for Deduplication

```swift
let tracker = ContentTracker()

// Register source files
for file in sourceSnapshot.allFiles() {
    tracker.registerSource(file)
}

// Check if content already exists
if let existingFile = tracker.findExisting(hash: fileHash) {
    print("Content exists at: \(existingFile.path)")
    // Can copy locally instead of transferring
}
```

### Executing Sync Operations

```swift
let executor = EfficientSyncExecutor(
    sourceRoot: sourceDirectory,
    destinationRoot: destDirectory,
    contentTracker: tracker
)

for operation in operations {
    try executor.execute(operation)
}
```

---

## Network Sync API

Phase 7 provides TCP-based network synchronization between machines.

### Push/Pull Mirror Behavior

Both `push` and `pull` create **true mirrors**:

- **Push**: Local becomes authoritative. Remote will be modified to match local exactly.
  - Files only on local → uploaded to remote
  - Files different on local → uploaded to remote (overwrites)
  - Files only on remote → **deleted from remote**

- **Pull**: Remote becomes authoritative. Local will be modified to match remote exactly.
  - Files only on remote → downloaded to local
  - Files different on remote → downloaded to local (overwrites)
  - Files only on local → **deleted from local**

> **Warning:** Both operations are destructive. Files on the non-authoritative side that don't exist on the authoritative side will be permanently deleted. Make backups before syncing if needed.

### Automatic Compression

Network transfers automatically compress files to reduce bandwidth:

- **Threshold:** Files ≥4KB are compressed (smaller files have too much overhead)
- **Algorithm:** ZLIB (gzip compatible)
- **Skip list:** Already-compressed files are sent uncompressed:
  - Images: jpg, jpeg, png, gif, webp, heic
  - Video: mp4, mov, avi, mkv
  - Audio: mp3, aac, m4a, ogg
  - Archives: zip, gz, 7z, rar, tar.gz
  - Documents: pdf, docx, xlsx

Compression happens automatically - no configuration needed. Log output shows compression ratios:
```
Uploading: main.swift (15000 → 3200 bytes, 78% saved)
Uploading: image.jpg (50000 bytes)  // Not compressed
```

### Starting a Sync Server

```swift
import Diffa

let server = SyncServer(path: directoryURL, port: 8080)

// Set up logging
server.onLog = { message in
    print("[Server] \(message)")
}

// Start server (blocking)
try server.start()
```

### Starting a Server in Background

```swift
DispatchQueue.global().async {
    do {
        try server.start()
    } catch {
        print("Server error: \(error)")
    }
}

// Later, stop the server
server.stop()
```

### Push Local Files to Remote Server

```swift
let client = SyncClient()

// Set up logging
client.onLog = { message in
    print("[Client] \(message)")
}

// Set up progress tracking
client.onProgress = { path, current, total in
    print("[\(current)/\(total)] \(path)")
}

// Push local directory to remote server
try client.push(
    localPath: localDirectory,
    to: "192.168.1.100",
    port: 8080
)
```

### Pull Remote Files to Local

```swift
let client = SyncClient()

client.onLog = { message in
    print("[Client] \(message)")
}

client.onProgress = { path, current, total in
    print("[\(current)/\(total)] \(path)")
}

// Pull from remote server to local directory
try client.pull(
    localPath: localDirectory,
    from: "192.168.1.100",
    port: 8080
)
```

### Complete Network Sync Example

```swift
import Diffa
import Foundation

// Server side (remote machine)
func startServer() throws {
    let serverPath = URL(fileURLWithPath: "/data/shared")
    let server = SyncServer(path: serverPath, port: 8080)

    server.onLog = { print("[Server] \($0)") }

    print("Starting server...")
    try server.start()  // Blocking
}

// Client side (local machine)
func syncWithServer() throws {
    let localPath = URL(fileURLWithPath: "/Users/me/sync")
    let client = SyncClient()

    client.onLog = { print("[Client] \($0)") }
    client.onProgress = { path, current, total in
        let percent = total > 0 ? (current * 100) / total : 0
        print("[\(percent)%] \(path)")
    }

    // Push local changes to server
    try client.push(localPath: localPath, to: "server.local", port: 8080)

    // Or pull server changes to local
    // try client.pull(localPath: localPath, from: "server.local", port: 8080)
}
```

---

## Error Handling

Diffa uses typed errors for different failure modes.

### Common Error Types

```swift
do {
    let snapshot = try Snapshot.open(at: snapshotURL)
} catch let error as SnapshotError {
    switch error {
    case .snapshotNotFound(let path):
        print("Snapshot not found: \(path)")
    case .incompatibleVersion(let path):
        print("Incompatible version: \(path)")
    case .invalidSnapshot(let reason):
        print("Invalid snapshot: \(reason)")
    default:
        print("Snapshot error: \(error)")
    }
} catch let error as DiffaError {
    switch error {
    case .invalidPatch(let reason):
        print("Invalid patch: \(reason)")
    case .comparisonFailed(let reason):
        print("Comparison failed: \(reason)")
    case .syncFailed(let reason):
        print("Sync failed: \(reason)")
    default:
        print("Diffa error: \(error)")
    }
} catch let error as SyncProtocolError {
    switch error {
    case .connectionFailed(let host, let port):
        print("Cannot connect to \(host):\(port)")
    case .timeout:
        print("Connection timed out")
    case .serverError(let message):
        print("Server error: \(message)")
    default:
        print("Protocol error: \(error)")
    }
} catch {
    print("Unexpected error: \(error)")
}
```

### Handling Sync Errors

```swift
let result = try await synchronizer.syncUnidirectional(
    source: sourceDirectory,
    destination: destDirectory,
    options: SyncOptions()
)

// Check for errors in result
if !result.errors.isEmpty {
    print("Sync completed with \(result.errors.count) errors:")
    for error in result.errors {
        print("  - \(error)")
    }
}
```

---

## Best Practices

### 1. Use Snapshots for Repeated Comparisons

```swift
// Good: Create snapshots once, compare multiple times
let snapshotA = try await engine.createSnapshot(from: dirA, saveTo: urlA, options: options)
let snapshotB = try await engine.createSnapshot(from: dirB, saveTo: urlB, options: options)

let diff1 = try Difference.compare(source: snapshotA, destination: snapshotB)
let diff2 = try Difference.compare(source: snapshotB, destination: snapshotA)
// Fast - no re-scanning needed
```

### 2. Enable Hash Caching for Large Directories

```swift
let options = ScanOptions(
    useHashCache: true,
    useParallelHashing: true
)

// First scan: slower (computing hashes)
let snapshot1 = try await engine.createSnapshot(from: dir, saveTo: url1, options: options)

// Subsequent scans: faster (cached hashes for unchanged files)
let snapshot2 = try await engine.createSnapshot(from: dir, saveTo: url2, options: options)
```

### 3. Always Use Dry Run First

```swift
// Preview changes
let previewOptions = SyncOptions(dryRun: true)
let preview = try await synchronizer.syncUnidirectional(
    source: source,
    destination: dest,
    options: previewOptions
)

print("Will copy \(preview.filesCopied) files, delete \(preview.filesDeleted) files")

// Then execute if satisfied
let executeOptions = SyncOptions(dryRun: false)
let result = try await synchronizer.syncUnidirectional(
    source: source,
    destination: dest,
    options: executeOptions
)
```

### 4. Create Reversible Patches for Critical Operations

```swift
// Always include revert data for production deployments
let patch = try Patch.create(
    from: difference,
    sourceDirectory: source,
    destinationDirectory: dest,
    saveTo: patchURL,
    includeRevertData: true  // Enable rollback
)
```

### 5. Clean Up Temporary Files

```swift
let tempDir = FileManager.default.temporaryDirectory
let snapshotURL = tempDir.appendingPathComponent("\(UUID().uuidString).diffa")

defer {
    try? FileManager.default.removeItem(at: snapshotURL)
}

let snapshot = try await engine.createSnapshot(
    from: directory,
    saveTo: snapshotURL,
    options: ScanOptions()
)
// Use snapshot...
// Cleanup happens automatically
```

### 6. Handle Network Errors Gracefully

```swift
let client = SyncClient()
let maxRetries = 3
var lastError: Error?

for attempt in 1...maxRetries {
    do {
        try client.push(localPath: localPath, to: host, port: port)
        print("Sync successful!")
        break
    } catch let error as SyncProtocolError {
        lastError = error
        print("Attempt \(attempt) failed: \(error)")
        if attempt < maxRetries {
            Thread.sleep(forTimeInterval: Double(attempt) * 2.0)  // Exponential backoff
        }
    }
}

if let error = lastError {
    print("All attempts failed: \(error)")
}
```

---

## Platform Requirements

- **macOS:** 13.0+
- **iOS:** 16.0+
- **Swift:** 5.9+

## Dependencies

Diffa uses:
- `swift-crypto` for SHA-256 hashing (cross-platform)
- `libsqlite3` for database storage (system library)

---

## Getting Help

- **CLI Documentation:** See [GETTING_STARTED.md](GETTING_STARTED.md)
- **API Reference:** Inline documentation in source files
- **Issues:** [GitHub Issues](https://github.com/codelynx/Diffa/issues)
- **Design Docs:** See `docs/` directory
