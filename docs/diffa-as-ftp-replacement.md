# Diffa as Modern FTP Replacement

**Status:** Proposal / Future Vision
**Date:** 2025-11-07
**Depends on:** Phase 6 (Remote Sync via Snapshot Exchange)

## Vision Statement

Position Diffa as a **modern FTP/SFTP replacement** with Git-like snapshot intelligence. Like FTP, but with incremental sync, content deduplication, move detection, and snapshot history.

**Target audience:** Anyone currently using FTP, SFTP, or basic file sync who wants:
- Faster transfers (only changed files)
- Automatic deduplication (same file copied once)
- Move detection (renames don't re-upload)
- Snapshot history (compare any point in time)
- Conflict resolution (bidirectional sync)

## Problem with Traditional FTP/SFTP

### FTP Daemon (ftpd) Limitations

| Feature | FTP/SFTP | Why It's Slow | Impact |
|---------|----------|---------------|---------|
| **File change detection** | Manual LIST + stat | Must traverse entire directory tree | Wastes time + bandwidth |
| **Transfer mode** | Full file always | No incremental, no resume | 1 GB file with 1 KB change = 1 GB transfer |
| **Duplicate files** | Transfer each copy | No deduplication | Same photo in 10 folders = 10x transfer |
| **Rename/move** | Delete + re-upload | No move detection | Rename 10k-file directory = hours of transfer |
| **Hash support** | ❌ Not in standard | Some servers have `XMD5` extension | Rare, non-standard, inconsistent |
| **Conflict detection** | ❌ None | Last-write-wins or manual | Data loss in bidirectional sync |
| **Snapshot history** | ❌ None | No versioning | Can't compare "before vs after" |

### Real-World FTP Pain Points

**Scenario 1: Photographer syncing to home NAS**
```bash
# Upload 10,000 photos (50 GB) via FTP
ftp nas.local
> cd /photos
> mput *.jpg
# Time: 2 hours (full transfer, no dedup)

# Later: Reorganize albums (move 5,000 photos to new folders)
> rename album1 album2  # Not supported!
> mkdir album2
> mput album2/*.jpg     # Re-upload 5,000 photos!
# Time: Another 1 hour (should be instant!)
```

**With Diffa:**
```bash
diffa sync ~/Photos diffa://nas:8080/photos
# First sync: 2 hours (same as FTP)

# Reorganize albums locally, then sync again
diffa sync ~/Photos diffa://nas:8080/photos
# Time: 5 seconds (move detection, no re-upload!)
```

**Scenario 2: Developer syncing project files**
```bash
# FTP: Upload 10 GB node_modules directory
# FTP: Rename src/ to lib/ = re-upload entire directory
# FTP: No conflict detection when both sides modified

# Diffa:
# - Only transfers changed files (not unchanged node_modules)
# - Rename = local move (zero transfer)
# - Conflict detection warns before overwriting
```

**Scenario 3: Duplicate files across folders**
```
photos/
├── album1/vacation.jpg  (10 MB)
├── album2/vacation.jpg  (10 MB, same file)
└── album3/vacation.jpg  (10 MB, same file)

FTP: Upload 30 MB (3 full copies)
Diffa: Upload 10 MB (transfer once, copy locally via hash)
```

## Diffa Daemon Architecture

### High-Level Design

```
┌─────────────────────────────────────────────────────────────┐
│ Client Machine (laptop, phone, desktop)                     │
│                                                              │
│  diffa sync ~/data diffa://server:8080/data                 │
│         │                                                    │
│         └──── Diffa Protocol (snapshot + content-addr) ───┐ │
└────────────────────────────────────────────────────────────┼─┘
                                                              │
                                                   TLS + Auth │
                                                              │
┌─────────────────────────────────────────────────────────────┼─┐
│ Server Machine (NAS, VPS, home server)                     │ │
│                                                              │ │
│  diffad --root=/data --port=8080 --auth-key=secret     ◄────┘ │
│         │                                                      │
│         ├─ Snapshot cache (SQLite databases)                  │
│         ├─ Content-addressable storage (MD5 blobs)            │
│         └─ Filesystem (/data)                                 │
└──────────────────────────────────────────────────────────────┘
```

### Protocol Flow (vs FTP)

**FTP Protocol:**
```
Client                           Server
  │                                │
  ├─ LIST /photos ─────────────────►
  ◄─ 10,000 filenames ─────────────┤
  │                                │
  ├─ STAT photo1.jpg ──────────────►
  ◄─ Size: 5MB, Date: ... ─────────┤
  │  (repeat 10,000 times!)        │
  │                                │
  ├─ GET photo1.jpg if changed ────►
  ◄─ 5MB full transfer ─────────────┤
  │  (repeat for each changed file)│
```

**Diffa Protocol:**
```
Client                                  Server
  │                                       │
  ├─ REQUEST_SNAPSHOT /photos ───────────►
  ◄─ SQLite snapshot (~2MB for 10k files)┤
  │                                       │
  ├─ Local comparison (by MD5 hash)      │
  │   → 100 files changed                │
  │   → 50 files moved (same hash!)      │
  │                                       │
  ├─ REQUEST_FILES [hash1, hash2, ...] ──►
  ◄─ FILE_DATA [100 changed files only]──┤
  │                                       │
  │  Server applies moves locally         │
  │  (no transfer needed!)                │
```

**Key differences:**
- FTP: 10,000 network round-trips to check files
- Diffa: 1 snapshot transfer (~2 MB), local comparison
- FTP: Re-upload moved files
- Diffa: Detect moves by hash, apply locally

## Feature Comparison

| Feature | FTP/SFTP | Diffa Daemon | Benefit |
|---------|----------|--------------|---------|
| **Change detection** | Manual LIST + STAT (slow) | Snapshot comparison (fast) | 100x faster for large directories |
| **Transfer mode** | Full file | Incremental (only changed) | 10x-100x less bandwidth |
| **Hash support** | ❌ Not standard | ✅ MD5 built-in | Integrity verification free |
| **Move detection** | ❌ None | ✅ Hash-based | Rename = instant, no re-upload |
| **Deduplication** | ❌ None | ✅ Content-addressable | Same file = one transfer |
| **Conflict detection** | ❌ None | ✅ Built-in | Warns before data loss |
| **Snapshot history** | ❌ None | ✅ Built-in | Compare any point in time |
| **Resumable transfers** | ⚠️ FTP REST command (limited) | ✅ Hash-based chunking | Reliable resume from any point |
| **Bidirectional sync** | ❌ Manual scripting | ✅ Built-in | Two-way sync with conflict resolution |
| **Security** | ⚠️ Plain FTP (no encryption) | ✅ TLS required | Modern security by default |
| **Authentication** | Username/password | API key or SSH key | No passwords, token-based |

## Use Cases

### 1. Home NAS / Media Server

**Traditional FTP setup:**
```bash
# NAS runs FTP server
ftpd --port=21 --root=/volume1/photos

# Client uploads photos manually
ftp nas.local
> cd /photos
> mput vacation/*.jpg  # Hours for 1000 photos
```

**Diffa setup:**
```bash
# NAS runs Diffa daemon
diffad --root=/volume1/photos --port=8080 --auth-key=secret

# Laptop auto-syncs on connect
diffa sync ~/Photos diffa://nas:8080/photos
# First time: Full transfer (same as FTP)
# Subsequent: Only new/changed photos (minutes → seconds)

# Phone uploads photos
diffa sync /sdcard/DCIM diffa://nas:8080/photos
# Deduplication: If photo already uploaded from laptop, skip
```

**Benefits:**
- No duplicate uploads (same photo from phone + laptop = one transfer)
- Move/organize photos locally, sync instantly (no re-upload)
- Conflict detection if same photo edited on multiple devices

### 2. Development Environment Sync

**Traditional approach:**
```bash
# Sync code from work to home via SFTP
# Problem: Must upload entire node_modules/ every time
# Problem: If both sides edited same file, last-write-wins (data loss)
```

**Diffa approach:**
```bash
# Work machine
diffad --root=~/Projects --mode=both --port=8080

# Home machine
diffa sync ~/Projects diffa://work-mac:8080/Projects

# What happens:
# - Only changed source files transfer (not unchanged dependencies)
# - Move detection: Refactor = renames, not re-uploads
# - Conflict detection: Warns if both sides modified same file
# - Git-like workflow but for entire filesystem
```

**Benefits:**
- Fast sync (only source code changes, not node_modules)
- Safe (conflict detection prevents accidental overwrites)
- Efficient (rename detection = instant)

### 3. Replace Corporate FTP Server

**Legacy FTP server:**
```bash
# Company runs aging FTP server for file sharing
ftpd --port=21 --root=/var/ftp
# Problems:
# - No encryption (plain FTP)
# - Slow for large directories
# - No deduplication (everyone uploads copies)
# - No versioning/snapshots
```

**Diffa replacement:**
```bash
# Modern Diffa server
diffad --root=/srv/shared \
       --port=8080 \
       --tls=required \
       --auth-key-env=DIFFA_AUTH_KEY \
       --mode=both

# Users get:
# - Fast incremental sync (only changes)
# - Automatic deduplication (same file uploaded once)
# - Snapshot history (see what changed when)
# - Conflict detection (prevent overwrites)
# - Modern security (TLS + API keys)
```

**Migration strategy:**
1. Run Diffa daemon alongside legacy FTP (different port)
2. Migrate users gradually (teach `diffa sync` command)
3. Users see immediate speed improvements
4. Retire FTP server once all migrated

### 4. Backup to VPS / Cloud VM

**Traditional rsync over SSH:**
```bash
rsync -avz ~/data user@vps:/backup/data
# Good: Incremental
# Bad: No snapshot management, no deduplication, no web UI
```

**Diffa approach:**
```bash
# VPS runs Diffa daemon
diffad --root=/backup --port=8080

# Laptop syncs
diffa sync ~/data diffa://vps:8080/backup/data

# Benefits:
# - Same incremental efficiency as rsync
# - Plus: Snapshot history (compare any backup version)
# - Plus: Deduplication (same file in multiple backups = one copy)
# - Plus: Web UI to browse snapshots (future Phase 7)
```

### 5. Mobile Photo Backup

**Traditional FTP:**
```bash
# Phone FTP client uploads to NAS
# Problem: Re-uploads photos if they were previously deleted
# Problem: No way to detect duplicates across devices
```

**Diffa mobile app (future):**
```swift
// iOS/Android app with Diffa library
let client = DiffaClient(url: "diffa://nas:8080/photos")
client.sync(source: "/sdcard/DCIM", destination: "/photos")

// Features:
// - Only uploads new photos (hash-based detection)
// - Skips duplicates (same photo on multiple devices)
// - Background sync when on WiFi
// - Shows sync progress (X new photos, Y already backed up)
```

## Ad-Hoc File Operations (True FTP Replacement)

**Problem:** Current proposal only supports full-tree sync (`diffa sync /local /remote`). Classic FTP users need:
- Browse directories without syncing
- Download/upload single files
- Selective operations (not full mirrors)

### Proposed CLI Commands

#### 1. Browse Remote Directory (Flat Listing)

**Phase 6 (Basic - On-Demand Scanning):**
```bash
# List directory contents by path (like FTP's LIST)
diffa ls remote://server:8080/photos/album1

# Server behavior (on-demand scan, like FTP):
# 1. readdir(/photos/album1)
# 2. stat() each file for size/mtime
# 3. Compute MD5 hash for each file (expensive!)

# Output:
# vacation.jpg     5242880  computing...  2024-11-07 12:00:00
# beach.jpg        3145728  computing...  2024-11-07 12:05:00
# (Server computes hashes on-the-fly, similar to FTP performance)
```

**Implementation:**
```swift
func listDirectory(path: String) -> [FileInfo] {
    let entries = try FileManager.default.contentsOfDirectory(atPath: path)
    return entries.map { name in
        let fullPath = path + "/" + name
        let attrs = try FileManager.default.attributesOfItem(atPath: fullPath)
        let size = attrs[.size] as! Int64
        let mtime = attrs[.modificationDate] as! Date

        // ⚠️ Expensive: compute MD5 on-demand (reads entire file!)
        let hash = computeMD5(path: fullPath)

        return FileInfo(name: name, size: size, mtime: mtime, hash: hash)
    }
}
```

**Performance:** Similar to FTP (must stat + hash every file). **No speedup over FTP yet.**

**Phase 7 (Advanced - Background Indexer):**
```bash
# List from cached metadata (instant!)
diffa ls remote://server:8080/photos/album1

# Server behavior (indexed):
# 1. SELECT * FROM files WHERE parent_path = '/photos/album1'
# 2. Return cached metadata (no filesystem scan!)

# Output (instant!):
# vacation.jpg     5242880  a3f5c81e...  2024-11-07 12:00:00
# beach.jpg        3145728  b4e6d92f...  2024-11-07 12:05:00
```

**Implementation:**
```swift
// Background thread maintains metadata cache
class MetadataIndexer {
    var db: SQLiteDatabase  // Persistent cache

    func watchDirectory(path: String) {
        // Use FSEvents (macOS) or inotify (Linux) to detect changes
        startWatching(path) { event in
            if event.type == .fileCreated || .fileModified {
                // Compute hash in background (async)
                let hash = computeMD5(path: event.path)
                db.execute("INSERT OR REPLACE INTO files VALUES (?, ?, ?, ?)",
                          event.path, size, mtime, hash)
            }
        }
    }

    func listDirectory(path: String) -> [FileInfo] {
        // Query cache (instant!)
        return db.query("SELECT * FROM files WHERE parent_path = ?", path)
    }
}
```

**Performance:** Instant (100x faster than FTP). Requires:
- Background indexer daemon
- Filesystem watch (FSEvents/inotify)
- Persistent SQLite metadata cache
- Initial index build (one-time cost)

#### 2. Download Single File/Folder (Phase 6)
```bash
# Get one file by path (like FTP's GET)
diffa get remote://server:8080/photos/album1/vacation.jpg ./

# Get entire folder
diffa get remote://server:8080/photos/album1 ./album1/

# Get with progress
diffa get remote://server:8080/large-file.zip ./ --progress
# Output:
# Downloading large-file.zip: 45% (500 MB / 1.1 GB) [====>    ] 10 MB/s
```

**Implementation:** Server reads file from filesystem, streams to client. No CAS needed.

#### 3. Upload Single File/Folder (Phase 6)
```bash
# Put one file by path (like FTP's PUT)
diffa put ./vacation.jpg remote://server:8080/photos/album1/

# Put entire folder
diffa put ./album1/ remote://server:8080/photos/

# Phase 6: No dedup awareness (uploads even if duplicate exists)
diffa put ./vacation.jpg remote://server:8080/photos/album1/
# Output:
# Uploading vacation.jpg... done (5 MB)
# (Even if identical file already exists elsewhere!)
```

**Implementation:** Client streams file to server, server writes to filesystem. No hash checking yet.

**Phase 7 (With CAS/Dedup):**
```bash
# Put with automatic deduplication
diffa put ./vacation.jpg remote://server:8080/photos/album1/
# Client computes hash: a3f5c81e...
# Server checks CAS: Already exists!
# Output:
# File already exists with hash a3f5c81e..., skipping upload (saved 5 MB)
```

#### 4. Content-Addressable Queries (Phase 7 Only!)

**⚠️ Requirements:** These commands require CAS infrastructure + background indexer from Phase 7. **Not available in Phase 6.**

**Infrastructure needed:**
1. **CAS store:** `/var/lib/diffad/blobs/<hash>.blob` (deduplicated storage)
2. **Hash index:** SQLite with `CREATE INDEX idx_hash ON files(hash)`
3. **Background indexer:** Continuously scans filesystem, populates index
4. **Hard-link layer:** User files are hard-links to CAS blobs

**Use case:** Find files by hash, not path. Enables deduplication detection.

```bash
# Find all files with given hash (requires hash index)
diffa find --hash=a3f5c81e... remote://server:8080/
# Server: SELECT path FROM files WHERE hash = 'a3f5c81e...'
# Output:
# /photos/album1/vacation.jpg
# /photos/album2/vacation.jpg
# /backup/2024/vacation.jpg
# (3 copies of same file!)

# Find by hash + size (your suggestion: "md5:filesize")
diffa find --hash=a3f5c81e... --size=5242880 remote://server:8080/
# Server: SELECT path FROM files WHERE hash = ? AND size = ?
# Output:
# /photos/album1/vacation.jpg
# /photos/album2/vacation.jpg

# Get file by hash (don't need to know path!)
diffa get --hash=a3f5c81e... --output=./vacation.jpg remote://server:8080/
# Server: Reads from /var/lib/diffad/blobs/a3f5c81e.blob directly
# No path needed! (CAS = content-addressable)

# List all duplicates in tree (requires hash index)
diffa duplicates remote://server:8080/photos
# Server: SELECT hash, COUNT(*), SUM(size) FROM files
#         WHERE path LIKE '/photos/%' GROUP BY hash HAVING COUNT(*) > 1
# Output:
# Hash: a3f5c81e...  Size: 5 MB  Count: 3  Wasted: 10 MB
#   /photos/album1/vacation.jpg
#   /photos/album2/vacation.jpg
#   /backup/2024/vacation.jpg
# Hash: b4e6d92f...  Size: 3 MB  Count: 2  Wasted: 3 MB
#   /photos/beach.jpg
#   /downloads/beach.jpg
# Total duplicates: 13 MB wasted (5 extra copies)
```

**Implementation (Phase 7):**
```swift
class ContentAddressableStore {
    let casPath = "/var/lib/diffad/blobs"
    let db: SQLiteDatabase  // Hash index

    func findByHash(hash: Data) -> [String] {
        // Query index (instant!)
        return db.query("SELECT path FROM files WHERE hash = ?", hash)
    }

    func getByHash(hash: Data) -> Data {
        // Read directly from CAS
        let blobPath = "\(casPath)/\(hash.hexString).blob"
        return try Data(contentsOf: URL(fileURLWithPath: blobPath))
    }

    func findDuplicates(rootPath: String) -> [(hash: Data, paths: [String])] {
        // Group by hash, filter count > 1
        let sql = """
            SELECT hash, GROUP_CONCAT(path, '|') as paths
            FROM files
            WHERE path LIKE ? || '%'
            GROUP BY hash
            HAVING COUNT(*) > 1
        """
        return db.query(sql, rootPath)
    }
}
```

**Benefits:**
- Deduplication awareness (users can see/clean duplicates)
- Content-addressable retrieval (hash = identity, path = location)
- Enables "I have this hash, give me the file" workflows

**Phase 6 limitations (without CAS):**
- ❌ Cannot query by hash (no index)
- ❌ Cannot detect duplicates (no hash tracking)
- ❌ Cannot get by hash (files stored by path, not hash)
- ✅ Can still get/put by path (basic FTP replacement)

#### 5. Interactive Shell (FTP-Like Experience)

```bash
# Launch interactive shell (like `ftp` command)
diffa shell remote://server:8080/
# Output:
# Connected to server:8080
# diffa> ls
# album1/  album2/  backup/
#
# diffa> cd album1
# diffa> ls
# vacation.jpg  beach.jpg
#
# diffa> get vacation.jpg
# Downloading vacation.jpg... done (5 MB)
#
# diffa> put ~/new-photo.jpg
# Uploading new-photo.jpg... done (3 MB)
#
# diffa> find --hash=a3f5c81e...
# /album1/vacation.jpg
# /album2/vacation.jpg
#
# diffa> quit
```

**Implementation:** REPL that wraps `ls`, `get`, `put`, `find`, `cd` commands. Like classic `ftp` but with hash awareness.

### Symbolic Link Handling

**Your question:** "Ignore or follow links?"

**Recommendation:** Configurable with sensible default.

```bash
# Default: Follow symlinks (safe, portable)
diffa sync /data remote://server/data
# Symlinks treated as regular files (content transferred)

# Preserve symlinks (advanced users)
diffa sync /data remote://server/data --symlinks=preserve
# Symlinks stored as symlinks (breaks on FAT32/Windows)

# Ignore symlinks (skip them)
diffa sync /data remote://server/data --symlinks=ignore
# Symlinks not synced at all

# Detect loops and warn
diffa sync /data remote://server/data --symlinks=follow
# Warning: Symlink loop detected: /data/link → /data
# Skipping /data/link to prevent infinite recursion
```

**Implementation:**
```swift
enum SymlinkPolicy {
    case follow     // Treat as regular file (default)
    case preserve   // Store as symlink
    case ignore     // Skip entirely
}

func scanFile(path: String, policy: SymlinkPolicy) {
    if isSymlink(path) {
        switch policy {
        case .follow:
            let target = readlink(path)
            scanFile(target, policy)  // Recurse into target

        case .preserve:
            metadata.symlinkTarget = readlink(path)
            // Store symlink itself, not target

        case .ignore:
            return  // Skip this file
        }
    }
}
```

**Loop detection:**
```swift
var visited: Set<String> = []  // Track inodes

func scanFile(path: String) {
    let inode = stat(path).st_ino
    if visited.contains(inode) {
        warn("Symlink loop detected: \(path)")
        return  // Break loop
    }
    visited.insert(inode)
    // ... continue scanning
}
```

**Cross-platform considerations:**
- **macOS/Linux:** Symlinks fully supported
- **Windows:** Symlinks exist but require admin privileges (rare)
- **FAT32/ExFAT:** No symlink support (must use `--symlinks=follow`)

**Metadata storage:**
```swift
struct Metadata {
    var isSymlink: Bool = false
    var symlinkTarget: String?  // If isSymlink, store target path
    // When --symlinks=preserve
}
```

**Restoration:**
```swift
func restoreSymlink(path: String, target: String) {
    if capabilities.supportsSymlinks {
        symlink(target, path)
    } else {
        warn("Destination doesn't support symlinks, skipping \(path)")
    }
}
```

### REST API for Programmatic Access

**For integration with scripts, web apps, etc:**

```bash
# REST API endpoints (Phase 7)
GET  /api/v1/files?path=/photos/album1          # List directory
GET  /api/v1/files/content?path=/photos/a.jpg   # Download file
POST /api/v1/files?path=/photos/album1          # Upload file
GET  /api/v1/files?hash=a3f5c81e...             # Find by hash
GET  /api/v1/duplicates?path=/photos            # List duplicates

# Example: Download file via REST
curl -H "Authorization: Bearer $API_KEY" \
     https://server:8080/api/v1/files/content?path=/photos/album1/vacation.jpg \
     -o vacation.jpg

# Example: List directory as JSON
curl -H "Authorization: Bearer $API_KEY" \
     https://server:8080/api/v1/files?path=/photos/album1 | jq
# Output:
# {
#   "files": [
#     {
#       "name": "vacation.jpg",
#       "size": 5242880,
#       "hash": "a3f5c81e...",
#       "mtime": "2024-11-07T12:00:00Z",
#       "mode": 420,
#       "owner": "alice"
#     }
#   ]
# }
```

**Benefit:** Enables web UI, mobile apps, CI/CD integrations, etc.

## Implementation Plan

### Phase 6a: Basic Daemon Mode + Path-Based Operations

**Deliverables:**
- `diffa serve` command with daemon mode (`--daemon` flag)
- TLS + API key authentication
- Snapshot exchange protocol (for full-tree sync)
- Content-addressable file transfer (for sync, not individual files yet)
- **Ad-hoc operations (basic FTP replacement):**
  - `diffa ls remote://server/path` - List directory (on-demand scan, like FTP LIST)
  - `diffa get remote://server/path/file.txt ./` - Download single file by path
  - `diffa put ./file.txt remote://server/path/` - Upload single file by path
- **Symlink handling:** `--symlinks=follow|preserve|ignore` with loop detection
- **REST API:** `/api/v1/files` endpoints for programmatic access

**Phase 6 limitations:**
- ❌ No hash-based queries (`find --hash`, `duplicates`) - requires Phase 7 CAS
- ❌ No dedup during upload (always transfers, even if duplicate) - requires Phase 7 CAS
- ❌ No instant directory listing (must scan filesystem like FTP) - requires Phase 7 indexer
- ✅ Supports full-tree sync with deduplication (via snapshot protocol)
- ✅ Supports get/put individual files by path (basic FTP replacement)

**Example usage:**
```bash
# Start daemon (foreground)
diffa serve /data --port=8080 --auth-key=secret

# Start daemon (background)
diffa serve /data --daemon --pid-file=/var/run/diffad.pid

# Ad-hoc operations (path-based only, no hash queries)
diffa ls remote://server:8080/photos/album1  # On-demand scan (like FTP)
diffa get remote://server:8080/photos/album1/vacation.jpg ./
diffa put ./new-photo.jpg remote://server:8080/photos/album1/

# Full-tree sync (uses snapshot protocol, has deduplication)
diffa sync ~/Photos remote://server:8080/photos
```

### Phase 6b: Production Hardening

**Deliverables:**
- Systemd service integration
- Docker container support
- Logging (syslog, file, journald)
- Metrics (Prometheus exporter)
- Health checks (`/health` endpoint)
- Graceful shutdown (SIGTERM handling)

**Systemd service:**
```ini
[Unit]
Description=Diffa File Sync Daemon
After=network.target

[Service]
Type=forking
User=diffad
Group=diffad
ExecStart=/usr/bin/diffad --root=/srv/data --port=8080 --pid-file=/var/run/diffad.pid
ExecReload=/bin/kill -HUP $MAINPID
PIDFile=/var/run/diffad.pid
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

**Docker deployment:**
```dockerfile
FROM swift:5.9-slim AS builder
WORKDIR /build
COPY . .
RUN swift build -c release

FROM swift:5.9-slim
RUN useradd -m -u 1000 diffad
COPY --from=builder /build/.build/release/diffad /usr/local/bin/
USER diffad
EXPOSE 8080
VOLUME ["/data"]
HEALTHCHECK CMD curl -f http://localhost:8080/health || exit 1
CMD ["diffad", "--root=/data", "--port=8080", "--auth-key-env=DIFFA_AUTH_KEY"]
```

### Phase 6c: Multi-User Features

**Deliverables:**
- Multi-user authentication (multiple API keys)
- Per-user namespaces (`/users/alice/`, `/users/bob/`)
- Access control lists (read/write permissions)
- User quotas (storage limits)
- Audit logging (who accessed what when)

**Configuration file:**
```yaml
# /etc/diffad/config.yaml
daemon:
  root: /srv/data
  port: 8080
  tls:
    cert: /etc/diffad/cert.pem
    key: /etc/diffad/key.pem

users:
  - name: alice
    api_key: "${ALICE_KEY}"
    paths:
      - /shared (read-write)
      - /alice (read-write)
    quota: 100GB

  - name: bob
    api_key: "${BOB_KEY}"
    paths:
      - /shared (read-only)
      - /bob (read-write)
    quota: 50GB

audit:
  enabled: true
  log_file: /var/log/diffad-audit.log
```

### Phase 7: Content-Addressable Storage + Background Indexer

**Deliverables:**
- **CAS infrastructure:**
  - `/var/lib/diffad/blobs/<hash>.blob` storage
  - Hard-link deduplication (user files → CAS blobs)
  - Garbage collection (remove unreferenced blobs)
- **Background indexer:**
  - FSEvents (macOS) / inotify (Linux) filesystem watching
  - SQLite metadata cache (`files` table with hash index)
  - Continuous background hashing (low-priority CPU)
  - Initial index build (one-time scan)
- **Hash-based commands (NOW AVAILABLE):**
  - `diffa find --hash=X remote://server/` - Find files by hash
  - `diffa duplicates remote://server/path` - List duplicate files
  - `diffa get --hash=X` - Download by hash (not path)
  - `diffa put` with automatic dedup detection
- **Instant directory listing:**
  - `diffa ls` queries index (100x faster than FTP)
  - No on-demand scanning needed

**Performance improvements over Phase 6:**
| Operation | Phase 6 (No CAS) | Phase 7 (With CAS) | Speedup |
|-----------|------------------|---------------------|---------|
| `diffa ls` (10k files) | 15 sec (scan + hash) | 0.1 sec (query index) | **150x faster** |
| Upload duplicate file | Full transfer (5 MB) | Skip (hash exists) | **Infinite (zero transfer)** |
| Find duplicates | Not supported | Instant (SQL GROUP BY) | **NEW** |
| Get by hash | Not supported | Direct CAS read | **NEW** |
| Storage (3 copies same file) | 15 MB (3× storage) | 5 MB (1× storage + links) | **3x savings** |

**Example usage:**
```bash
# Start daemon with CAS enabled
diffad --root=/data --port=8080 --storage-mode=cas --cas-path=/var/lib/diffad/blobs

# Hash-based operations (NOW WORK!)
diffa find --hash=a3f5c81e... remote://server:8080/
diffa duplicates remote://server:8080/photos
diffa get --hash=a3f5c81e... --output=vacation.jpg remote://server:8080/

# Upload with automatic dedup
diffa put ./vacation.jpg remote://server:8080/photos/album1/
# Output: Hash exists, skipping upload (saved 5 MB)

# Instant listing (from index, not filesystem scan)
diffa ls remote://server:8080/photos  # 0.1 sec for 10k files!
```

**Infrastructure components:**
```swift
// Background indexer
class MetadataIndexer {
    func start() {
        // Watch filesystem for changes
        startFSEventsWatcher()

        // Initial scan (one-time)
        scanDirectoryTree(root: "/data")

        // Background hash computation
        startHashingQueue()  // Low-priority CPU
    }
}

// CAS manager
class ContentAddressableStore {
    func store(path: String) -> Data {
        let hash = computeMD5(path)
        let blobPath = "/var/lib/diffad/blobs/\(hash.hex).blob"

        if !exists(blobPath) {
            // Copy to CAS
            copy(path, blobPath)
        }

        // Replace user file with hard-link
        rm(path)
        link(blobPath, path)

        return hash
    }
}
```

### Phase 8: Web Management UI (Future)

**Features:**
- Web-based file browser (like FileZilla UI)
- Snapshot timeline (visual history)
- User management (add/remove users, reset API keys)
- Storage analytics (who's using how much)
- Real-time sync monitoring (active transfers, progress)

**Access:**
```bash
# Web UI at https://nas:8080/ui
# REST API at https://nas:8080/api
# GraphQL endpoint at https://nas:8080/graphql
```

## Deployment Scenarios

### 1. Synology/QNAP NAS Integration

**Package format:**
- Synology SPK package
- QNAP QPKG package
- TrueNAS/FreeNAS plugin

**Installation:**
```bash
# Install Diffa package from NAS app store
# Configure via web UI (port, users, quotas)
# Start daemon automatically on boot
```

**Benefit:** Replace built-in FTP server with Diffa (same ease of use, much faster).

### 2. Docker Compose (Self-Hosted)

**docker-compose.yml:**
```yaml
version: '3.8'
services:
  diffad:
    image: diffa/diffad:latest
    container_name: diffad
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - /mnt/data:/data
      - diffad-snapshots:/var/lib/diffad
    environment:
      - DIFFA_AUTH_KEY=${DIFFA_AUTH_KEY}
      - DIFFA_LOG_LEVEL=info
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  diffad-snapshots:
```

### 3. Kubernetes Deployment

**StatefulSet with persistent volume:**
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: diffad
spec:
  serviceName: diffad
  replicas: 1
  selector:
    matchLabels:
      app: diffad
  template:
    metadata:
      labels:
        app: diffad
    spec:
      containers:
      - name: diffad
        image: diffa/diffad:latest
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: data
          mountPath: /data
        env:
        - name: DIFFA_AUTH_KEY
          valueFrom:
            secretKeyRef:
              name: diffad-secrets
              key: auth-key
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Ti
```

### 4. Raspberry Pi / ARM Devices

**Prebuilt binaries:**
```bash
# Download ARM64 binary
wget https://github.com/diffa/diffa/releases/download/v1.0.0/diffad-linux-arm64

# Run on Raspberry Pi
chmod +x diffad-linux-arm64
./diffad-linux-arm64 --root=/mnt/usb --port=8080
```

**Use case:** Cheap home file server (Pi + external HDD + Diffa).

## Migration Guide: FTP → Diffa

### Step 1: Assess Current FTP Usage

**Questions to ask:**
- How many users? (single vs multi-user)
- What do they upload? (photos, code, backups)
- How often? (hourly, daily, weekly)
- How much data? (GB, TB)
- Current pain points? (slow, duplicates, no versioning)

### Step 2: Set Up Diffa Alongside FTP

**Keep FTP running, add Diffa on different port:**
```bash
# Existing FTP server (port 21)
ftpd --port=21 --root=/data

# New Diffa daemon (port 8080)
diffad --root=/data --port=8080 --auth-key=secret
```

**No downtime, users can try Diffa without commitment.**

### Step 3: Migrate One User at a Time

**Pilot user:**
1. Install Diffa CLI client
2. Test sync: `diffa sync ~/data diffa://server:8080/data`
3. Compare speeds: FTP (30 min) vs Diffa (2 min) for 10k files
4. Validate: Compare file counts, check duplicates

**Training:**
```bash
# Old FTP workflow
ftp server.local
> cd /data
> mput *.jpg
> quit

# New Diffa workflow
diffa sync ~/data diffa://server:8080/data
# That's it! (automatic incremental, dedup, conflict detection)
```

### Step 4: Full Migration

**Once confident:**
1. Announce migration timeline (2 weeks notice)
2. Provide Diffa CLI download links + docs
3. Migrate all users (help them test first sync)
4. Retire FTP server (or keep read-only for legacy access)

**Success metrics:**
- All users migrated (100%)
- No data loss (verify file counts)
- Speed improvement (measure average sync time)
- User satisfaction (survey)

### Step 5: Enable Advanced Features

**Now that FTP is gone, leverage Diffa features:**
- Snapshot history: "See what changed last week"
- Conflict detection: "Warns before overwriting"
- Web UI: "Browse files from browser"
- API access: "Integrate with scripts/automation"

## Performance Expectations

### Benchmark: 10,000 Files (50 GB total)

| Operation | FTP/SFTP | Diffa | Speedup |
|-----------|----------|-------|---------|
| **Initial upload (all new)** | 60 min | 60 min | 1x (same) |
| **Check for changes (nothing changed)** | 15 min (LIST + STAT 10k files) | 5 sec (snapshot comparison) | **180x faster** |
| **Upload 100 changed files** | 3 min (transfer 100 files) | 2 min (incremental) | 1.5x faster |
| **Rename 5,000 files** | 30 min (re-upload all) | 2 sec (move detection) | **900x faster** |
| **Same file in 10 folders** | 10x transfer | 1x transfer + local copy | **10x less bandwidth** |

### Real-World Case Study (Hypothetical)

**Company:** Small design studio with 10 employees
**Data:** 500 GB of photos, PSDs, videos
**Old setup:** FTP server on NAS
**Problem:** Employees kept uploading duplicate files, slow syncs

**Migration to Diffa:**
- Initial sync: Same time as FTP (one-time cost)
- Daily syncs: 30 min → 2 min (15x faster)
- **Transfer deduplication:** Saved 200 GB bandwidth (same files uploaded by multiple people only transfer once)
- User feedback: "Feels like working on local disk, not network"

**ROI:**
- Time saved: 28 min/day × 10 employees = 4.6 hours/day
- **Bandwidth saved:** 200 GB transfers = $50/month (AWS transfer costs)
- **Storage saved:** 0 GB in Phase 6 (files still stored separately on disk)*
- Intangible: Happier employees, fewer complaints

**Note:** Current architecture saves **transfer bandwidth**, not storage. For storage deduplication, see "Future: Content-Addressable Storage" section below.

## Security Considerations

### Authentication

**FTP (weak):**
- Username/password (transmitted in plain text in plain FTP)
- No expiration, no rotation policy
- Shared passwords common (bad practice)

**Diffa (strong):**
- API key authentication (token-based)
- Keys can be rotated (revoke old, issue new)
- Per-user keys (audit who did what)
- Environment variable support (no hardcoded secrets)

### Encryption

**FTP:**
- Plain FTP: ❌ No encryption (everything visible on network)
- FTPS: ⚠️ TLS optional (often not configured)
- SFTP: ✅ SSH encryption (but still slow protocol)

**Diffa:**
- TLS required by default (can't disable without explicit flag)
- Modern ciphers (TLS 1.3)
- Certificate pinning support (prevent MITM)

### Access Control

**FTP:**
- Typically filesystem-based (user owns files)
- No fine-grained control (all-or-nothing access)

**Diffa (future):**
- Path-based ACLs (read/write per directory)
- Quotas (storage limits per user)
- Audit logging (track all operations)

## Future Work

### 1. Server-Side Storage Deduplication

**Problem:** Phase 6 only saves transfer bandwidth, not storage. If Alice and Bob upload the same file, it's stored twice on disk.

**Solution Options:**

**Option A: Hard-Link Deduplication (Phase 7)**
```bash
# Diffa daemon maintains CAS store
diffad --root=/data --storage-mode=cas --cas-path=/var/lib/diffad/blobs

# When file uploaded:
# 1. Compute MD5: a3f5c81e...
# 2. Check if /var/lib/diffad/blobs/a3f5c81e.blob exists
# 3. If yes: Create hard-link /data/alice/file.jpg → blobs/a3f5c81e.blob
# 4. If no: Store blob, then create hard-link

# Result: Multiple directory entries, one inode
```

**Pros:**
- Standard POSIX, works on ext4/XFS/APFS/btrfs
- Transparent to clients (files appear normal)
- Atomic updates (link = instant)

**Cons:**
- Requires filesystem support (no FAT32/ExFAT)
- Hard-links share permissions (can't have different modes per user)
- Deleting one link affects ref-count (need GC)

**Option B: Reflink Copy-on-Write (Phase 7)**
```bash
# On Btrfs/XFS/APFS with reflink support
diffad --root=/data --storage-mode=reflink

# When duplicate detected:
cp --reflink=always /data/alice/file.jpg /data/bob/file.jpg
# Zero storage until bob modifies it (then copy-on-write)
```

**Pros:**
- Separate inodes (can have different ownership/permissions per copy)
- COW = instant deduplication
- Modification doesn't affect other copies

**Cons:**
- Filesystem-specific (Btrfs, XFS with reflink, APFS on macOS 10.13+)
- Not available on ext4 (most common Linux FS)

**Option C: Virtual Filesystem with FUSE (Phase 8)**
```bash
# Diffa mounts virtual FS
diffad --root=/data --storage-mode=virtual --mount=/mnt/diffa

# Clients see:
/mnt/diffa/alice/file.jpg (virtual file, metadata only)
/mnt/diffa/bob/file.jpg   (virtual file, metadata only)

# Actual storage:
/var/lib/diffad/blobs/a3f5c81e.blob (real data, 1 copy)
/var/lib/diffad/metadata.db (SQLite: maps paths → hashes)
```

**Pros:**
- True content-addressable storage (CAS)
- Works on any underlying filesystem
- Granular control (per-user permissions, quotas)
- Snapshots are native (just SQLite DB state)

**Cons:**
- FUSE overhead (slower than native FS)
- More complex implementation
- Requires FUSE library (not available on all platforms)

**Recommendation:** Start with **Option A (hard-links)** in Phase 7 as it provides good deduplication with minimal complexity, then consider Option C (FUSE) in Phase 8 for advanced features.

### 2. Web UI Design
- Should it look like FileZilla? (familiar to FTP users)
- Or like Dropbox? (modern, simple)
- Or like Git history view? (snapshot-focused)

### 2. Mobile App Strategy
- Native iOS/Android apps? (Diffa library + UI)
- Or progressive web app? (works in browser)
- Photo backup vs full file access?

### 3. Integration with Cloud Storage
- Can Diffa daemon run on S3/GCS/Azure? (serverless?)
- Or only as gateway (Diffa → cloud backend)?

### 4. Pricing Model (if Commercial)
- Open source CLI + paid daemon with GUI?
- Free for personal use, paid for commercial?
- Hosted service (diffa.cloud) vs self-hosted?

## Related Documents

- `docs/remote-sync-proposal.md` - Technical foundation (Phase 6)
- `docs/cli-design.md` - CLI tool design
- `docs/competitive-analysis.md` - Comparison to rsync, Syncthing, etc.
- `docs/architecture.md` - Snapshot and comparison architecture

## Conclusion

**Diffa can replace FTP/SFTP** with:
- ✅ Same ease of use (client-server model)
- ✅ Much faster (snapshot comparison, incremental sync)
- ✅ Smarter (deduplication, move detection, conflict resolution)
- ✅ More secure (TLS required, API key auth, audit logs)
- ✅ Better features (snapshot history, bidirectional sync, web UI)

**Positioning:** "Modern FTP replacement with Git-like snapshots"

**Target market:**
1. Home users with NAS devices (Synology, QNAP users)
2. Small businesses with legacy FTP servers
3. Developers syncing code between machines
4. Photographers managing large media libraries

**Key differentiator:** Speed + deduplication + move detection = 10x-100x faster than FTP for typical workflows.
