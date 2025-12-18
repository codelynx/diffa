# Cross-Platform Metadata Compatibility

**Status:** Design Document
**Date:** 2025-11-07
**Context:** Phase 6 remote sync proposal exposed metadata compatibility gaps

---

## Key Design Decisions

### 1. No Source Tracking

**We do NOT store `sourceFilesystem` or `sourcePlatform` in metadata.**

**Why:** Chains like APFS → ExFAT → ext4 make source tracking stale and misleading. After passing through ExFAT, the data has ExFAT-level degradation (no permissions), but tracking would still claim "source was APFS" - a lie.

**Instead:** Snapshots describe **what they actually contain**:
- `mode == nil` = no permissions in THIS snapshot (whether lost in chain or never captured)
- Optional fields are self-documenting: presence = available, absence = not available

### 2. Simple Timestamp Storage (Seconds Only)

**Timestamps stored as Unix epoch seconds (Int64), sub-second precision discarded.**

**Why:** File identity = hash + size. Timestamps are advisory metadata, not content identity. Second-level precision is sufficient for content-oriented sync (photos, documents, code).

**Trade-off:** FAT32 round-trips may show "metadata changed" even when content unchanged.

**Example Chain (APFS → FAT32 → APFS):**
```
Snapshot 1 (APFS):
  mtime: 1730937601 (odd second, captured from APFS)
  mode: 0o644, owner: "alice"
  hash: a3f5c81e...
  ✅ Rich metadata captured

Snapshot 2 (FAT32 USB):
  mtime: 1730937600 (FAT32 rounds to 2-second boundary)
  mode: nil, owner: nil (lost permissions)
  hash: a3f5c81e... (same content)
  ✅ Accurately describes FAT32 limitations

Snapshot 3 (APFS from FAT32):
  mtime: 1730937600 (inherited from FAT32)
  mode: nil, owner: nil (can't recover lost metadata)
  hash: a3f5c81e... (same content)
  ✅ Honest about degraded state

Comparison: Snapshot 1 vs Snapshot 3
  → Hash: a3f5c81e == a3f5c81e ✅ Content identical
  → mtime: 1730937601 != 1730937600 ⚠️ Timestamp changed (FAT32 rounding)
  → mode: 0o644 → nil ⚠️ Permissions lost
  → Result: Content unchanged, metadata degraded
  → User sees: "Metadata-only change" (expected, acceptable)
```

**Accepted Trade-off:** FAT32 round-trips will show "metadata changed" warnings. This is acceptable because hash comparison ensures no false content-change detection.

---

## Problem Statement

Diffa must handle file synchronization across radically different platforms and filesystems, each with incompatible metadata capabilities. The current proposal assumes all systems support POSIX permissions and ownership, which breaks in practice.

### The Compatibility Matrix

#### 1. Timestamp Precision Varies by Filesystem

| Filesystem | Precision | Notes |
|------------|-----------|-------|
| APFS | Nanosecond | Diffa captures at second-level (sub-second discarded) |
| ext4 | Nanosecond | Diffa captures at second-level (sub-second discarded) |
| HFS+ | Second | Captured as-is |
| NTFS | 100-nanosecond | Diffa captures at second-level (sub-second discarded) |
| FAT32 | 2-second | OS rounds to 2-second boundary, Diffa captures result |
| ExFAT | 10-millisecond | OS rounds to 10ms, Diffa captures at second-level |
| Cloud (S3/GCS) | Second | Captured as-is |

**Diffa's Approach:** Capture timestamps at second-level precision (Int64). Sub-second components are discarded during snapshot creation.

**Trade-off:** FAT32 round-trips may show "metadata changed" warnings:
- APFS file at mtime=1730937601 (odd second)
- FAT32 rounds to 1730937600 (2-second boundary)
- Round-trip: mtime changes from 1730937601 → 1730937600
- **Result:** Shows as "metadata changed" (expected, acceptable)
- **But:** Hash unchanged → content identical → no re-transfer needed

**Why this is acceptable:** Hash comparison prevents false content-change detection. Metadata warnings are informational only.

#### 2. Available Metadata Fields Differ

| Filesystem | mtime | mode | owner/group | Extended attrs | Other |
|------------|-------|------|-------------|----------------|-------|
| APFS | ✅ ns | ✅ POSIX | ✅ name+UID | ✅ xattr | birthtime, flags |
| ext4 | ✅ ns | ✅ POSIX | ✅ name+UID | ✅ xattr | atime, ctime |
| FAT32 | ✅ 2s | ❌ | ❌ | ❌ | mtime ONLY |
| ExFAT | ✅ 10ms | ❌ | ❌ | ❌ | mtime ONLY |
| NTFS | ✅ 100ns | ⚠️ ACLs | ⚠️ SIDs | ⚠️ ADS | Complex ACL system |
| SMB/NFS | ⚠️ Varies | ⚠️ Mapped | ⚠️ Mapped | ⚠️ Maybe | Depends on server |
| Cloud | ✅ s | ❌ | ❌ | ⚠️ Custom | Custom metadata only |

**Problem:** Syncing macOS → FAT32 USB drive → Linux loses all permissions and ownership. When syncing back, should Diffa restore them? From where?

**Impact:** Metadata loss on round-trips through limited filesystems.

#### 3. Username/Group Semantics Break Across Systems

| Platform | "alice" User Representation | Group "staff" |
|----------|----------------------------|---------------|
| Mac A | Username: "alice", UID: 501 | GID: 20 |
| Mac B | Username: "alice", UID: 1001 | GID: 50 (different!) |
| Linux | Username: "alice", UID: 1000 | Group doesn't exist |
| Windows | "DOMAIN\alice" (SID-based) | Different security model |
| FAT32 | No concept of users | No permissions |
| Cloud | Synthetic string "alice" | No OS meaning |

**Problem:**
- `chown("alice", ...)` might find the wrong user (UID 1001 on Mac B could be someone else)
- Username might not exist (restoring Mac snapshot to Linux without "alice" user)
- Numeric UIDs are machine-specific (UID 501 on Mac A ≠ UID 501 on Linux)

**Impact:** Incorrect ownership restoration, security implications, or restore failures.

#### 4. Filesystem Capability Detection is Non-Trivial

```swift
// Examples of ambiguous cases:
NTFS mounted on macOS:  Supports permissions? (Depends on mount options)
SMB share:              Supports ownership? (Depends on server config)
Encrypted volumes:      Same capabilities as underlying FS? (Usually yes)
FUSE filesystems:       Capabilities vary wildly (rclone, sshfs, etc.)
```

**Problem:** Can't assume capabilities from filesystem type alone. Must test at runtime.

## Current Proposal Gaps

Reviewing `docs/remote-sync-proposal.md` and `Sources/Diffa/Core/Metadata.swift`:

❌ **Assumes universal permission support:** Every snapshot stores `mode`, but FAT32/ExFAT can't preserve it
❌ **No timestamp precision handling:** Comparing nanosecond vs 2-second timestamps will always differ
❌ **No fallback when chown() fails:** If "alice" doesn't exist, restore fails or errors
❌ **No cross-platform UID mapping:** Restoring macOS snapshot to Linux applies wrong UID
❌ **No source filesystem metadata:** Can't tell if metadata was captured from FAT32 (lossy) vs APFS (complete)
❌ **No user warnings:** Syncing to FAT32 silently loses permissions without user knowledge

## Proposed Solution: Metadata Compatibility Framework

### 1. Enhanced Metadata Schema

```swift
struct Metadata {
    // Universal fields (always captured)
    var size: Int64             // File size in bytes
    var mtime: Int64            // Modification time (seconds since Unix epoch)
    var hash: Data              // MD5 BLOB (16 bytes)

    // Optional POSIX metadata (nil if not supported/captured)
    var mode: UInt16?           // POSIX permissions (nil if not captured/supported)
    var owner: String?          // Username string (nil if not captured/supported)
    var group: String?          // Group name string
    var ownerUID: UInt32?       // Numeric UID (for same-machine restore)
    var groupGID: UInt32?       // Numeric GID
}
```

**Rationale:**
- **File identity = hash + size:** Timestamps are metadata hints, not content identity
- **Second-level precision is sufficient:** For content files (photos, documents, code), second granularity is adequate
- **Simplicity over precision:** No sub-second tracking, no precision markers, no normalization logic
- **Filesystem differences handled gracefully:** FAT32 (2s), ExFAT (10ms), APFS (nanosecond) all round to nearest second when captured
- **Hash is truth:** If timestamps differ but hash matches, content is unchanged (metadata-only change)
- **No provenance tracking** (sourceFilesystem/Platform) - gets stale in chains (APFS→ExFAT→ext4)
- **Optional fields are self-documenting**: `mode == nil` means "no permissions", not "unknown"
- **Dual UID/name** storage for cross-machine vs same-machine restore

**Storage impact:** 8 bytes per file for mtime (simple Int64). Total: 32 bytes base + ~26 bytes optional POSIX = 58 bytes per file.

### 2. File Comparison Strategy

```swift
func filesEqual(_ a: Metadata, _ b: Metadata) -> Bool {
    // Content identity (definitive)
    if a.hash != b.hash || a.size != b.size {
        return false  // Content changed
    }

    // Metadata comparison (advisory)
    if a.mtime != b.mtime { return false }  // Timestamp changed
    if a.mode != b.mode { return false }    // Permissions changed

    return true  // Identical
}

func contentEqual(_ a: Metadata, _ b: Metadata) -> Bool {
    // Hash is truth - ignore timestamp/permissions
    return a.hash == b.hash && a.size == b.size
}
```

**Philosophy:**
- **Hash + size = content identity** (definitive truth)
- **Timestamp = modification hint** (advisory, not definitive)
- **Simple direct comparison** (no filesystem-aware rounding)
- **Accept FAT32 noise** (timestamp changes show as "metadata changed", not a big deal)

**Example Scenarios:**

1. **APFS → FAT32 → APFS round-trip (shows metadata change):**
   ```
   Original (APFS):  mtime = 1730937601 (odd second)
                     hash = a3f5c81e...
   FAT32 copy:       mtime = 1730937600 (FAT32 rounds to 2-second)
                     hash = a3f5c81e... (same content)
   Restored (APFS):  mtime = 1730937600
                     hash = a3f5c81e... (same content)

   Comparison (Original vs Restored):
     Hash: a3f5c81e == a3f5c81e ✅ Content identical
     mtime: 1730937601 ≠ 1730937600 ⚠️ Timestamp changed
     Result: "Metadata changed" (expected, acceptable)
   ```

2. **APFS ↔ APFS (no round-trip issues):**
   ```
   File A: mtime = 1730937600, hash = a3f5c81e...
   File B: mtime = 1730937600, hash = a3f5c81e...

   Comparison:
     Hash: Equal ✅
     mtime: Equal ✅
     Result: Identical
   ```

3. **Actual content change (detected correctly):**
   ```
   File A: mtime = 1730937600, hash = a3f5c81e...
   File B: mtime = 1730937604, hash = b4e6d92f... (different!)

   Comparison:
     Hash: Not equal ✅ Content changed
     Result: Modified (re-transfer needed)
   ```

**Result:** Simple comparison logic. Hash ensures content changes are always detected. Timestamp differences may occur due to FAT32 rounding, but content identity is never compromised.

### 3. Filesystem Capability Detection

```swift
struct FilesystemCapabilities {
    var supportsPermissions: Bool = false
    var supportsOwnership: Bool = false
    var supportsExtendedAttrs: Bool = false
    var filesystemType: String = "unknown"  // "apfs", "msdos", "ext4", etc.
}

func detectCapabilities(at path: String) throws -> FilesystemCapabilities {
    // Get filesystem type from OS
    #if os(macOS)
    var statfs = statfs()
    guard statfs(path, &statfs) == 0 else {
        throw MetadataError.cannotDetectFilesystem
    }
    let fsType = String(cString: &statfs.f_fstypename.0).lowercased()
    #elseif os(Linux)
    let fsType = getFilesystemType(path).lowercased()
    #endif

    // Known filesystem capabilities (hardcoded table)
    return knownFilesystemCapabilities[fsType] ?? .minimal
}

// Well-known filesystem capabilities
let knownFilesystemCapabilities: [String: FilesystemCapabilities] = [
    // POSIX filesystems (full metadata support)
    "apfs": FilesystemCapabilities(
        supportsPermissions: true,
        supportsOwnership: true,
        supportsExtendedAttrs: true,
        filesystemType: "apfs"
    ),
    "hfs": FilesystemCapabilities(
        supportsPermissions: true,
        supportsOwnership: true,
        supportsExtendedAttrs: true,
        filesystemType: "hfs"
    ),
    "ext4": FilesystemCapabilities(
        supportsPermissions: true,
        supportsOwnership: true,
        supportsExtendedAttrs: true,
        filesystemType: "ext4"
    ),

    // FAT filesystems (no POSIX metadata)
    "msdos": FilesystemCapabilities(
        supportsPermissions: false,
        supportsOwnership: false,
        supportsExtendedAttrs: false,
        filesystemType: "msdos"
    ),
    "vfat": FilesystemCapabilities(
        supportsPermissions: false,
        supportsOwnership: false,
        supportsExtendedAttrs: false,
        filesystemType: "vfat"
    ),
    "exfat": FilesystemCapabilities(
        supportsPermissions: false,
        supportsOwnership: false,
        supportsExtendedAttrs: false,
        filesystemType: "exfat"
    ),
]

extension FilesystemCapabilities {
    // Safe default for unknown filesystems
    static let minimal = FilesystemCapabilities(
        supportsPermissions: false,
        supportsOwnership: false,
        supportsExtendedAttrs: false,
        filesystemType: "unknown"
    )
}
```

**Result:** Fast, reliable detection. Unknown filesystems fall back to minimal support (safe default).

### 4. Permission Application with Fallback Chain

```swift
struct RestoreOptions {
    var ignoreMetadataErrors: Bool = false
    var requireMetadata: Set<String> = []  // ["permissions", "ownership"]
    var verbose: Bool = true
}

func applyMetadata(
    to path: String,
    metadata: Metadata,
    capabilities: FilesystemCapabilities,
    options: RestoreOptions
) throws {
    var errors: [String] = []

    // 1. Apply mtime (always try, universal support)
    do {
        let date = Date(timeIntervalSince1970: TimeInterval(metadata.mtime))
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: path
        )
    } catch {
        errors.append("mtime: \(error.localizedDescription)")
    }

    // 2. Apply permissions (if supported and present)
    if let mode = metadata.mode {
        if capabilities.supportsPermissions {
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: mode],
                    ofItemAtPath: path
                )
            } catch {
                errors.append("permissions: \(error.localizedDescription)")
                if options.requireMetadata.contains("permissions") {
                    throw MetadataError.requiredFieldFailed("permissions", error)
                }
            }
        } else {
            // Filesystem doesn't support permissions (e.g., FAT32)
            if options.verbose {
                log("Skipping permissions (filesystem: \(capabilities.filesystemType))")
            }
            if options.requireMetadata.contains("permissions") {
                throw MetadataError.unsupportedByFilesystem("permissions")
            }
        }
    }

    // 3. Apply ownership (best-effort, multiple fallback strategies)
    if capabilities.supportsOwnership,
       let owner = metadata.owner {

        // Strategy A: Try username (cross-machine compatible)
        if userExists(owner) {
            do {
                try chown(path, user: owner, group: metadata.group)
            } catch {
                errors.append("ownership (by name): \(error.localizedDescription)")
                // Fall through to Strategy B
            }
        }

        // Strategy B: Try numeric UID (same machine or compatible UID range)
        if let uid = metadata.ownerUID, let gid = metadata.groupGID {
            do {
                try chown(path, uid: uid, gid: gid)
            } catch {
                errors.append("ownership (by UID): \(error.localizedDescription)")
                // Fall through to Strategy C
            }
        }

        // Strategy C: Keep current owner (silent fallback)
        if options.verbose {
            log("Could not restore ownership '\(owner)', keeping current owner")
        }

        if options.requireMetadata.contains("ownership") {
            throw MetadataError.requiredFieldFailed("ownership", MetadataError.ownerNotFound(owner))
        }
    }

    // Report non-fatal errors
    if !errors.isEmpty && !options.ignoreMetadataErrors {
        for error in errors {
            warn("Failed to restore metadata: \(error)")
        }
    }
}
```

**Fallback strategies:**

1. **Permissions:**
   - Try to apply → Success ✅
   - Permission denied → Warn (file exists but owned by someone else)
   - Filesystem doesn't support → Silent skip (FAT32, expected)

2. **Ownership:**
   - Try by username ("alice") → Works if user exists
   - Try by numeric UID (501) → Works if same machine or UID valid
   - Keep current owner → Silent fallback
   - Fail if `--require-metadata=ownership` → User explicitly demanded preservation

3. **Philosophy:** Metadata is **advisory**, not mandatory. File content (hash + size) is the source of truth.

### 5. Cross-Platform UID/Username Mapping

```swift
func chown(_ path: String, user: String, group: String?) throws {
    // Look up UID from username
    guard let pw = getpwnam(user) else {
        throw MetadataError.userNotFound(user)
    }
    let uid = pw.pointee.pw_uid

    var gid: gid_t = 0
    if let groupName = group, let gr = getgrnam(groupName) {
        gid = gr.pointee.gr_gid
    } else {
        gid = pw.pointee.pw_gid  // Use user's primary group
    }

    guard chown(path, uid, gid) == 0 else {
        throw POSIXError(.EPERM)
    }
}

func chown(_ path: String, uid: uid_t, gid: gid_t) throws {
    guard chown(path, uid, gid) == 0 else {
        throw POSIXError(.EPERM)
    }
}

func userExists(_ username: String) -> Bool {
    return getpwnam(username) != nil
}
```

**Decision tree for ownership restoration:**

```
1. Same platform (darwin → darwin)?
   → Try numeric UID first (more reliable, handles renamed users)
   → Fallback to username

2. Cross-platform (darwin → linux)?
   → Only try username (UIDs meaningless across OSes)
   → Silent fallback if user doesn't exist

3. From cloud (s3 → darwin)?
   → Username only (synthetic "alice" from cloud metadata)
   → Warn if user doesn't exist

4. To FAT32/ExFAT?
   → Skip entirely (no ownership support)
```

### 6. User-Facing Controls

#### CLI Flags

```bash
# Preview metadata compatibility before sync
diffa sync /apfs /fat32 --verify-metadata
# Output:
# Warning: Destination filesystem (FAT32) does not support:
#   - Permissions (mode will be lost)
#   - Ownership (owner/group will be lost)
# 10,000 files will lose metadata. Continue? [y/N]

# Ignore metadata preservation failures (useful for FAT32, removable media)
diffa sync /source /fat32 --ignore-metadata-errors

# Require specific metadata preservation (fail if impossible)
diffa sync /source /dest --require-metadata=permissions
# Error: Destination filesystem (FAT32) does not support permissions
# Aborting.

diffa sync /source /dest --require-metadata=ownership
# Warning: User 'alice' does not exist on destination system
# Aborting. Use --ignore-metadata-errors to proceed.

# Verbose output (show metadata application details)
diffa sync /source /dest --verbose-metadata
# Applying metadata to file.txt:
#   mtime: 2024-11-07 12:00:00 ✓
#   mode: 0644 ✓
#   owner: alice (UID 501) ✗ User not found, keeping current owner
#   group: staff (GID 20) ✗ Group not found, keeping current group
```

#### Snapshot Metadata Report

```bash
diffa inspect snapshot.db --metadata-summary
# Snapshot created on: macOS (APFS)
# Files: 10,000
# Metadata captured:
#   mtime: 10,000 files (second-level precision)
#   mode: 10,000 files
#   owner/group: 10,000 files (501 unique users, 20 unique groups)
#
# Compatibility:
#   → FAT32: Will lose permissions + ownership (10,000 files affected)
#   → Linux ext4: May lose ownership if users don't exist
#   → Windows NTFS: Permissions will be mapped to ACLs (may not round-trip)
```

### 7. Metadata Levels

**Minimal (universal):**
- `hash` (MD5 BLOB, 16 bytes)
- `size` (Int64)
- `mtime` (Int64, Unix timestamp in seconds)

**Standard (POSIX-aware):**
- `minimal` +
- `mode` (UInt16, POSIX permissions, if captured)
- `owner` / `group` (String, usernames, if captured)
- `ownerUID` / `groupGID` (UInt32, numeric IDs, for same-machine restore)

**Full (future, platform-specific):**
- `standard` + extended attributes (xattr)
- `birthtime` / `ctime` (if available)
- Filesystem-specific flags (macOS flags, Windows alternate data streams)

**Note:** "If captured" means field is non-nil in metadata. nil = not supported by source filesystem OR lost in a chain (e.g., APFS→ExFAT→ext4).

### 8. Snapshot Schema

```sql
-- Snapshot header stores global metadata
CREATE TABLE snapshot_metadata (
    key TEXT PRIMARY KEY,
    value TEXT
);

INSERT INTO snapshot_metadata (key, value) VALUES
    ('metadata_capture_level', 'standard');  -- minimal | standard | full

-- Files table with simple second-level timestamps
CREATE TABLE files (
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL,
    size INTEGER NOT NULL,
    mtime INTEGER NOT NULL,             -- Seconds since epoch (always present)
    mode INTEGER,                        -- POSIX permissions (NULL if not captured)
    owner TEXT,                          -- Username string (NULL if not captured)
    owner_uid INTEGER,                   -- Numeric UID (NULL if not captured)
    group_name TEXT,                     -- Group name string (NULL if not captured)
    group_gid INTEGER,                   -- Numeric GID (NULL if not captured)
    hash BLOB NOT NULL,                  -- 16-byte MD5
    parent_id INTEGER,
    FOREIGN KEY (parent_id) REFERENCES files(id)
);
```

**Design principles:**
- **Simple timestamps:** `mtime` in seconds only (no sub-second fields)
- **No precision tracking:** Filesystem detection happens at comparison time, not stored
- **Optional POSIX fields:** `mode`, `owner`, `owner_uid`, etc. are NULL when not captured
- **Self-documenting:** NULL = not captured/supported, non-NULL = available for restore

**Storage:** ~58 bytes per file (32 bytes base + 26 bytes optional POSIX metadata).

## Implementation Strategy

### Phase 1: Schema & Capture (Pre-Phase 6)
- Implement `detectCapabilities()` using hardcoded filesystem table
- Add `FilesystemCapabilities` to `ScanOptions`
- Update schema: `mtime INTEGER` (seconds only), optional POSIX fields
- Capture metadata at second-level precision (discard sub-second)
- Update tests to cover FAT32, ExFAT, NTFS, APFS

### Phase 2: Comparison (Phase 6a)
- Implement simple timestamp comparison (`a.mtime == b.mtime`)
- Add `--verify-metadata` flag to CLI
- Warn users about expected FAT32 round-trip metadata changes
- Hash-based content identity prevents false content-change detection

### Phase 3: Restoration (Phase 6b)
- Implement `applyMetadata()` with fallback chain (username → UID → keep current)
- Add `--ignore-metadata-errors` and `--require-metadata` flags
- Test cross-platform restore (macOS → Linux → macOS)
- Accept FAT32 timestamp degradation as expected behavior

### Phase 4: Reporting (Phase 6c)
- Add `diffa inspect snapshot.db --metadata-summary`
- Generate compatibility reports
- Document best practices for cross-platform sync

## Design Principles

1. **Content is king:** File hash + size are the source of truth. Metadata is supplementary.

2. **Capture everything, apply best-effort:** Store all available metadata from source, but don't fail if destination can't preserve it.

3. **Silent skips for expected limitations:** FAT32 doesn't support permissions → No warning (user knows USB drives don't have permissions).

4. **Warnings for unexpected failures:** User "alice" doesn't exist on restore target → Warn (might be important).

5. **User control:** Provide flags for strict (`--require-metadata`) vs lenient (`--ignore-metadata-errors`) behavior.

6. **Hash-based identity:** Content changes detected via hash comparison, not timestamp differences.

7. **Cross-platform by default:** Use username strings (not UIDs) as primary ownership representation.

## Testing Strategy

### Test Matrix

| Source FS | Dest FS | Expected Behavior |
|-----------|---------|-------------------|
| APFS | APFS | Full metadata preserved ✅ |
| APFS | FAT32 | Permissions lost, no warning ✅ |
| APFS | ext4 (Linux) | Permissions preserved, ownership best-effort ⚠️ |
| FAT32 | APFS | Only mtime preserved (no perms to restore) ✅ |
| FAT32 | FAT32 | mtime preserved (2-second precision) ✅ |
| NTFS (Mac) | APFS | Depends on mount options ⚠️ |
| Cloud | APFS | Synthetic owner/group, best-effort ⚠️ |

### Test Cases

1. **Timestamp handling:**
   - Sync APFS → FAT32 → APFS, verify content identity via hash (expect "metadata changed" warning)
   - Verify hash comparison prevents false content-change detection

2. **Ownership fallback:**
   - Restore snapshot with user "alice" to system without that user
   - Restore snapshot with UID 501 to system where UID 501 is someone else

3. **Capability detection:**
   - Detect FAT32 correctly (no permissions)
   - Detect NTFS on macOS with different mount options

4. **User controls:**
   - `--require-metadata=permissions` fails on FAT32
   - `--ignore-metadata-errors` succeeds on FAT32 with warnings suppressed

5. **Cross-platform:**
   - Sync macOS snapshot to Linux, verify permissions preserved
   - Sync Linux snapshot to macOS, verify ownership applied correctly

## Future Extensions

### 1. UID Mapping Database (Optional)
```swift
// For organizations with consistent UID policies
struct UIDMapping {
    let sourceUID: uid_t
    let destUID: uid_t
    let destUsername: String
}

// Load from config file
let mappings = loadMappings("~/.diffa/uid-mappings.json")
// Example: {501: {uid: 1000, username: "alice"}}
```

### 2. ACL Support (Windows/NFSv4)
```swift
// Store Windows ACLs or NFSv4 ACLs separately
var acl: AccessControlList?  // Platform-specific
```

### 3. Extended Attributes (Phase 7+)
```swift
var xattrs: [String: Data]?  // Store all xattrs
```

## Related Documents

- `docs/remote-sync-proposal.md` - Main Phase 6 proposal
- `docs/decisions.md` - Decision 3: Metadata levels
- `Sources/Diffa/Core/Metadata.swift` - Current metadata implementation
- `Sources/Diffa/Core/FileSystemItem.swift` - File scanning logic

## Decision Log

**2025-11-07:** Initial design based on feedback during Phase 6 proposal review. Identified timestamp precision, ownership mapping, and capability detection as critical gaps. Designed solution prioritizing content integrity over metadata fidelity, with user controls for strict vs lenient behavior.
