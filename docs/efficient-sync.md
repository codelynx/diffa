# Efficient Directory Synchronization

**Status:** Core Feature
**Scope:** Phase 1-5
**Last Updated:** 2025-11-07

## Objective

Efficiently sync two directories (local or cloud) by transferring only what's changed, with smart deduplication and move detection.

## Core Principle

**File identity = MD5 hash + size**

Metadata (mtime, permissions, ownership) is applied per-path but doesn't affect identity. Two files with the same hash+size are identical content, even if metadata differs.

## What We Build

### Phase 1-4: Local Sync

```bash
# Sync local directories
diffa sync ~/Photos ~/Backup/Photos

# What happens:
# 1. Create snapshot A (~/Photos)
# 2. Create snapshot B (~/Backup/Photos)
# 3. Compare: MD5+size comparison
# 4. Transfer: Copy missing/changed files
# 5. Apply metadata: chmod, chown, touch
```

**File identity:**
- Hash: MD5 (16 bytes)
- Size: Int64
- Comparison: `a.hash == b.hash && a.size == b.size`

**Metadata (advisory):**
- mtime (seconds, not nanoseconds)
- mode (POSIX permissions)
- owner/group (username strings, best-effort)

### Phase 5+: Cloud Sync (Future)

```bash
# Local → S3
diffa sync ~/Photos s3://my-bucket/photos

# S3 → Local
diffa sync s3://my-bucket/photos ~/Photos-restore

# What happens:
# 1. Create local snapshot (fast)
# 2. Create/fetch S3 snapshot (Lambda or cached)
# 3. Compare snapshots (MD5+size)
# 4. Transfer files via AWS SDK
# 5. Apply metadata (S3 object metadata)
```

## Transfer Optimization

### Deduplication During Transfer

**Problem:** Same file appears multiple times in source directory.

```
photos/
├── album1/vacation.jpg  (MD5: a3f5c8..., 5 MB)
├── album2/vacation.jpg  (MD5: a3f5c8..., 5 MB, same file!)
└── album3/beach.jpg     (MD5: b4e6d9..., 3 MB)
```

**Naive approach:** Transfer 13 MB (5 + 5 + 3)

**Diffa approach:** Transfer 8 MB (5 + 3)
1. Identify unique hashes: `{a3f5c8, b4e6d9}`
2. Transfer each unique file once
3. Copy locally to multiple paths
4. Apply different metadata per-path

**Implementation:**
```swift
struct TransferPlan {
    var uniqueFiles: [Hash: Data]           // Unique content to transfer
    var pathsPerHash: [Hash: [FilePath]]    // Where to copy each hash
    var metadataPerPath: [FilePath: Metadata]  // Metadata to apply
}

func executeTransfer(plan: TransferPlan) {
    // Transfer each unique file once
    for (hash, content) in plan.uniqueFiles {
        let paths = plan.pathsPerHash[hash]!

        // Write content to first path
        writeFile(paths[0], content)

        // Copy to other paths (instant, no transfer)
        for path in paths[1...] {
            copyFile(paths[0], path)
        }

        // Apply metadata per-path
        for path in paths {
            let metadata = plan.metadataPerPath[path]!
            applyMetadata(path, metadata)
        }
    }
}
```

**Savings:**
- Transfer: 5 MB (not 10 MB) ✅
- Bandwidth: 50% reduction
- Time: 50% faster

### Move Detection

**Problem:** Renamed files re-upload entire content.

**Diffa approach:**
1. Compare hashes in both snapshots
2. Detect hash exists in both but path changed
3. Local move (instant, no transfer)

**Example:**
```bash
# Before:
photos/album1/vacation.jpg (MD5: a3f5c8...)

# After rename:
photos/trips/hawaii.jpg (MD5: a3f5c8...)

# Naive sync: Delete + upload 5 MB
# Diffa sync: mv (instant, 0 bytes transferred)
```

## What We Don't Build

### ❌ Daemon Mode (diffad)
- No server process
- No ad-hoc commands (`diffa ls`, `diffa get`, `diffa put`)
- Use existing tools (SSH, S3 CLI) for browsing

### ❌ Multi-User ACLs/Quotas
- Not Diffa's responsibility
- Host OS handles permissions
- Diffa applies metadata, OS enforces access

**Example:**
```bash
# User tries to sync to restricted directory:
diffa sync ~/Photos /root/backup
# Host OS: Permission denied (mkdir /root/backup)
# Diffa: Catches error, reports clearly, exits gracefully
```

### ❌ Content-Addressable Storage (CAS)
- No `/var/lib/diffad/blobs/<hash>.blob`
- No hard-link deduplication infrastructure
- No hash-based queries (`diffa find --hash`)

**Why:** Deduplication happens during transfer, not storage.

### ❌ Patches
- No patch.db files
- No RevertData
- No cache management

**Why:** Direct file transfer is simpler and sufficient.

## Architecture

### Storage Abstraction (S3-Ready)

```swift
protocol SnapshotStore {
    func createSnapshot(at location: String) async throws -> Snapshot
    func loadSnapshot(from location: String) async throws -> Snapshot
    func readFile(at path: String) async throws -> Data
    func writeFile(to path: String, data: Data) async throws
    func deleteFile(at path: String) async throws
}

// Phase 1-4: Local only
class LocalFilesystemStore: SnapshotStore { ... }

// Phase 5+: S3 support
class S3Store: SnapshotStore { ... }  // Not yet implemented
```

**Benefit:** S3 support requires no changes to sync logic.

### Sync Algorithm

```swift
func sync(source: String, destination: String) async throws {
    let sourceStore = StorageLocation.parse(source).createStore()
    let destStore = StorageLocation.parse(destination).createStore()

    // Create/load snapshots
    let sourceSnapshot = try await sourceStore.createSnapshot(at: source)
    let destSnapshot = try await destStore.loadSnapshot(from: destination)

    // Compare (MD5 + size)
    let diff = sourceSnapshot.compare(to: destSnapshot)

    // Build transfer plan (dedup + move detection)
    let plan = buildTransferPlan(diff)

    // Execute transfer
    try await executeTransfer(plan, sourceStore, destStore)
}
```

## Error Handling

### Host OS Errors

Diffa **degrades gracefully** when host OS denies operations:

```swift
func applyMetadata(path: String, metadata: Metadata) throws {
    // Try mtime (usually works)
    do {
        try setModificationTime(path, metadata.mtime)
    } catch {
        warn("Could not set mtime for \(path): \(error)")
    }

    // Try permissions (may fail on FAT32, permission denied)
    if let mode = metadata.mode {
        do {
            try chmod(path, mode)
        } catch {
            // Don't fail - host OS may not support permissions
            warn("Could not set permissions for \(path): \(error)")
        }
    }

    // Try ownership (may fail if not root, user doesn't exist)
    if let owner = metadata.owner {
        do {
            try chown(path, owner)
        } catch {
            // Don't fail - non-root can't chown, or user doesn't exist
            warn("Could not set owner for \(path): \(error)")
        }
    }

    // File content was transferred successfully ✅
    // Metadata is best-effort, not critical
}
```

**Philosophy:**
- Content transfer is critical → fails hard
- Metadata application is advisory → warns, continues
- Host OS enforces access → Diffa respects, reports clearly

## Implementation Phases

### Phase 1: Snapshots + Comparison ✅
- Snapshot creation (SQLite, MD5 hashing)
- Snapshot comparison (hash+size)
- Move detection (hash tracking)

### Phase 2: File Transfer + Sync
- `LocalFilesystemStore` implementation
- Unidirectional sync
- Bidirectional sync + conflict resolution
- Deduplication during transfer

### Phase 3: Optimization
- Hash caching (avoid re-hashing unchanged files)
- Parallel transfer (multiple files concurrently)
- Incremental snapshots (update existing snapshot)

### Phase 4: CLI Polish
- Progress bars, error messages
- Documentation, examples
- **Ship v1.0** 🚀

### Phase 5: S3 Support (Future)
- `S3Store` implementation
- Lambda snapshot creator
- S3 multipart upload
- Cloud-native metadata handling

## What Success Looks Like

**User story:**
```bash
# Photographer with 100k photos (500 GB)

# First sync (baseline):
diffa sync ~/Photos ~/Backup/Photos
# Time: 2 hours (copy all files)

# Daily sync (only changes):
# Added: 50 new photos (500 MB)
# Deleted: 20 old photos
# Renamed: 100 albums (10k files moved)
diffa sync ~/Photos ~/Backup/Photos --delete
# Time: 30 seconds (transfer 500 MB, 10k instant moves, 20 deletes)
# Bandwidth: 500 MB (not 50 GB!)

# Round-trip via FAT32 USB:
diffa sync ~/Photos /Volumes/USB/Photos
diffa sync /Volumes/USB/Photos ~/Photos-restored
# Content: Identical (hash verified) ✅
# Metadata: Degraded (FAT32 rounds timestamps, no permissions) ⚠️
# Result: "Metadata changed" warnings, but content intact
```

## Documentation

- `docs/remote-sync-proposal.md` - Phase 6 protocol (optional future)
- `docs/cross-platform-metadata.md` - Metadata compatibility
- `docs/architecture.md` - Core types and design
- `README.md` - User-facing documentation

## Not Included

These features were considered but deemed out of scope:

- **Daemon mode** - Use existing SSH/FTP servers
- **Web UI** - Use file managers, S3 console
- **REST API** - Library can be embedded in custom servers
- **Multi-user management** - Use OS users, permissions
- **Quotas** - Use filesystem quotas, S3 billing alerts
- **Audit logs** - Use OS audit logs, CloudTrail

**Philosophy:** Simple first, no frills. Focus on efficient sync, let OS/cloud handle access control.
