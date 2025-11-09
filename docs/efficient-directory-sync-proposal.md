# Efficient Directory Synchronization Proposal

**Status:** Design Proposal
**Date:** 2025-11-07
**Author:** Based on core vision discussion

---

## Vision Statement

Enable efficient synchronization between two directories on different computers by transferring only what's necessary. Use content-addressable identification (MD5 + filesize) to minimize data transfer, with metadata applied separately.

---

## Core Principle: Content vs Metadata

**File identity = MD5 hash + size**

- **Content:** File bytes (identified by MD5+size, transferred once if needed)
- **Metadata:** Path, mtime, permissions (applied per-location, transferred separately)

**Key insight:** Same content can exist at multiple paths with different metadata.

---

## How It Works

### Phase 1: Automatic Snapshot Creation

When you run a sync command, diffa automatically creates snapshots internally:

**Snapshots capture:**
- File paths
- MD5 hashes
- File sizes
- Metadata (mtime, optionally mode)

**Snapshots are small** (200 bytes per file):
- 10,000 files ≈ 2 MB snapshot
- 100,000 files ≈ 20 MB snapshot

**Note:** Snapshots are created internally during sync operations and exchanged over the network. They are not exposed to users as files.

### Phase 2: Connect and Sync

**Exchange method (daemon + client):**
```bash
# Server (Computer B): Start daemon
diffa daemon --path ~/Photos-backup --port 8080
# Daemon listens, ready to receive connections

# Client (Computer A): Connect and sync
diffa push ~/Photos 192.168.1.10:8080
# Or: diffa pull ~/Photos 192.168.1.10:8080
# Or: diffa sync ~/Photos 192.168.1.10:8080
```

### Phase 3: Analyze Minimal Transfer

**Both sides compare snapshots:**

**Example scenario:**
```
Computer A (~/Photos):
├── album1/vacation.jpg  (MD5: a3f5..., 5 MB, mtime: 2025-11-01)
├── album2/vacation.jpg  (MD5: a3f5..., 5 MB, mtime: 2025-11-01)  # Same file!
└── album1/beach.jpg     (MD5: b4e6..., 3 MB, mtime: 2025-11-02)

Computer B (~/Photos-backup):
├── old/archived.jpg     (MD5: a3f5..., 5 MB, mtime: 2024-10-01)  # Same content as vacation.jpg!
└── temp/work.jpg        (MD5: c7d8..., 2 MB, mtime: 2025-10-15)
```

**Analysis:**
1. **Content needed by B:**
   - `b4e6...` (beach.jpg, 3 MB) - B doesn't have this

2. **Content B already has:**
   - `a3f5...` (vacation.jpg) - B has as archived.jpg!
   - Transfer: 0 bytes (B already has the content)

3. **Content A doesn't need:**
   - `c7d8...` (work.jpg) - A doesn't want this (delete or keep based on mode)

**Transfer plan:**
```
From A → B:
  Content transfer: 3 MB (only beach.jpg)
  Metadata updates:
    - Copy archived.jpg → album1/vacation.jpg (0 bytes, just metadata)
    - Copy archived.jpg → album2/vacation.jpg (0 bytes, just metadata)
    - Transfer beach.jpg → album1/beach.jpg (3 MB)
    - Delete old/archived.jpg (now duplicated elsewhere)

Total transfer: 3 MB (not 13 MB!)
Savings: 77%
```

### Phase 4: Content-Addressable Transfer

**Query by content, not path:**

**Computer A → B: "I need content with MD5 b4e6..., size 3 MB"**

**Computer B responds:**
- "I don't have that content" → A sends the bytes
- "I have that content" → A skips transfer, B copies locally

**Network protocol (simplified):**
```
A → B: REQUEST_CONTENT {hash: b4e6..., size: 3145728}
B → A: SEND_CONTENT (I don't have it)
A → B: CONTENT_DATA [3 MB binary stream]
B:     Write to temp, verify hash, copy to target paths

A → B: REQUEST_CONTENT {hash: a3f5..., size: 5242880}
B → A: HAVE_CONTENT (already exists as old/archived.jpg)
A → B: (skip transfer, B will copy locally)
```

**Key: No paths in content transfer protocol, only hash+size.**

---

## Efficiency Scenarios

### Scenario 1: Duplicate Files (Same Directory)

**Before sync (Computer A):**
```
photos/
├── album1/photo1.jpg  (5 MB)
├── album1/photo2.jpg  (5 MB, same content as photo1!)
├── album2/photo3.jpg  (5 MB, same content as photo1!)
└── album3/photo4.jpg  (3 MB, different)
```

**Naive transfer:** 18 MB (5+5+5+3)

**Diffa transfer:**
- Identify unique content: `{hash1: 5MB, hash2: 3MB}`
- Transfer: 8 MB (hash1 once + hash2)
- Computer B copies hash1 to 3 different paths locally
- **Savings: 55% bandwidth**

### Scenario 2: Renamed/Moved Files

**Before (Computer A):**
```
photos/2024/vacation.jpg (5 MB, MD5: a3f5...)
```

**After (Computer A):**
```
photos/trips/hawaii-2024.jpg (5 MB, MD5: a3f5...)
```

**Computer B already has:**
```
backup/2024/vacation.jpg (5 MB, MD5: a3f5...)
```

**Naive transfer:** 5 MB (delete + re-upload)

**Diffa transfer:**
- B already has content a3f5...
- Just update metadata: rename backup/2024/vacation.jpg → trips/hawaii-2024.jpg
- **Transfer: 0 bytes!**
- **Savings: 100%**

### Scenario 3: Directory Reorganization

**Computer A reorganizes 10,000 files (50 GB):**
```
Old: photos/album1/*.jpg
New: photos/organized/2024/trips/*.jpg
```

**Computer B has old structure:**
```
backup/photos/album1/*.jpg
```

**Naive transfer:** Re-upload 50 GB

**Diffa transfer:**
- All content unchanged (same MD5 hashes)
- Only metadata changes (new paths)
- Transfer: ~20 KB (just path updates)
- **Savings: 99.9999%**

---

## Network Protocol Design

### Content-Addressable Protocol

**Key principle: Transfer by hash+size, not path**

**Advantages:**
1. **Deduplication automatic** - Same content = same hash
2. **Path-agnostic** - Don't care where content lives
3. **Efficient** - Only transfer what receiver doesn't have

---

### Protocol Flow: PUSH (Client → Server)

**Client has files, server receives:**

```
1. HELLO
   Client → Server: {command: "push", version: 1}
   Server → Client: {status: "ready", capabilities: []}

2. SNAPSHOT_EXCHANGE
   Client → Server: Client's snapshot
   Server → Client: Server's snapshot

3. CLIENT ANALYZES
   Client compares snapshots locally
   Determines what server needs

4. CONTENT_CHECK
   Client → Server: CONTENT_LIST [
     {hash: a3f5..., size: 5242880},
     {hash: b4e6..., size: 3145728}
   ]

   Server → Client: CONTENT_STATUS [
     {hash: a3f5..., have: true},   # Server already has this
     {hash: b4e6..., have: false}   # Server needs this
   ]

5. CONTENT_UPLOAD (Client sends missing content)
   For each missing content:
   Client → Server: SEND_CONTENT {hash: b4e6..., size: 3145728}
   Client → Server: CONTENT_DATA [binary stream]
   Server: Verify hash, store temporarily

6. METADATA_APPLY
   Client → Server: APPLY_METADATA [operations list]
   Server: Applies metadata (create/update/delete files)
   Server: Copies stored content to target paths

7. DONE
   Server → Client: {status: "complete", files_changed: 1234}
```

---

### Protocol Flow: PULL (Client ← Server)

**Server has files, client receives:**

```
1. HELLO
   Client → Server: {command: "pull", version: 1}

2. SNAPSHOT_EXCHANGE
   Client → Server: Client's snapshot
   Server → Client: Server's snapshot

3. CLIENT ANALYZES
   Client compares snapshots locally
   Determines what client needs

4. CONTENT_REQUEST (Client requests missing content)
   Client → Server: REQUEST_CONTENT_LIST [
     {hash: a3f5..., size: 5242880},
     {hash: b4e6..., size: 3145728}
   ]

5. CONTENT_DOWNLOAD (Server sends content)
   For each requested content:
   Server → Client: SEND_CONTENT {hash: b4e6..., size: 3145728}
   Server → Client: CONTENT_DATA [binary stream]
   Client: Verify hash, store temporarily

6. METADATA_APPLY (Client applies locally)
   Client: Applies metadata (create/update/delete files)
   Client: Copies stored content to target paths

7. DONE
   Client → Server: {status: "complete"}
```

---

### Protocol Flow: SYNC (Bidirectional)

**Both sides exchange files:**

```
1. HELLO
   Client → Server: {command: "sync", version: 1}

2. SNAPSHOT_EXCHANGE
   Client ↔ Server: Exchange both snapshots

3. BOTH ANALYZE & RECONCILE
   Client: Analyzes what server needs
   Server: Analyzes what client needs, sends analysis to client
   Client: Merges both analyses into single authoritative plan
   Client: Detects conflicts (same path, different hash)

4. CONFLICT RESOLUTION (if needed)
   Client → Server: CONFLICT_RESOLUTION [
     {path: "photo.jpg", strategy: "newer", winner: "client"}
   ]

5. BIDIRECTIONAL TRANSFER
   Client → Server: Upload content server needs
   Server → Client: Download content client needs
   (Uses same CONTENT_CHECK + CONTENT_DATA as push/pull)

6. METADATA_APPLY
   Both sides apply their changes

7. DONE
   Both confirm completion
```

---

## Implementation Approach: Daemon + Client Model

### Server-Client Architecture

**Linux A (Server - runs continuously):**
```bash
# Foreground mode (see logs, Ctrl-C to stop)
diffa daemon --path ~/Photos --port 8080
# Output:
# Diffa daemon listening on port 8080...
# [waits for connections]
# [handles syncs]
# [stays running after each sync]
# [Ctrl-C to stop]

# Background mode (detached process)
diffa daemon --path ~/Photos --port 8080 --detach
# Runs in background, logs to file
```

**Mac B (Client - connects and exits):**
```bash
# Three simple commands (no complex flags!)

# Push: Mirror client → server (server becomes copy of client)
diffa push ~/Photos 192.168.0.39:8080

# Pull: Mirror server → client (client becomes copy of server)
diffa pull ~/Photos 192.168.0.39:8080

# Sync: Merge both sides (newer wins on conflicts)
diffa sync ~/Photos 192.168.0.39:8080
```

**Key Characteristics:**
- Server runs continuously (handles multiple clients over time)
- Client connects, syncs, exits
- Simple commands (push/pull/sync) - behavior is clear from command name
- No SSH required (direct protocol, faster on LAN)

---

## Command Behavior

### Push (Mirror Client → Server)

```bash
diffa push ~/Photos 192.168.0.39:8080
```

**Behavior:**
- Server becomes exact copy of client
- Client files overwrite server files
- Server-only files are **deleted**
- Use case: Backup client to server

**Example:**
```
Before:
  Client: [photo1.jpg, photo2.jpg, photo3.jpg]
  Server: [photo2.jpg, photo4.jpg]

After:
  Client: [photo1.jpg, photo2.jpg, photo3.jpg] (unchanged)
  Server: [photo1.jpg, photo2.jpg, photo3.jpg] (mirrors client, photo4.jpg deleted)
```

---

### Pull (Mirror Server → Client)

```bash
diffa pull ~/Photos 192.168.0.39:8080
```

**Behavior:**
- Client becomes exact copy of server
- Server files overwrite client files
- Client-only files are **deleted**
- Use case: Restore from server backup

**Example:**
```
Before:
  Server: [photo1.jpg, photo2.jpg, photo3.jpg]
  Client: [photo2.jpg, photo4.jpg]

After:
  Server: [photo1.jpg, photo2.jpg, photo3.jpg] (unchanged)
  Client: [photo1.jpg, photo2.jpg, photo3.jpg] (mirrors server, photo4.jpg deleted)
```

---

### Sync (Merge Both Sides)

```bash
diffa sync ~/Photos 192.168.0.39:8080
```

**Behavior:**
- Both sides get all files (merge)
- **No path deletions** (files unique to either side are preserved and copied; no paths removed from the combined set)
- If same path exists on both sides with **same hash**: Keep as-is (already in sync)
- If same path exists on both sides with **different hash**: **Newer wins** (by mtime, overwrites older content)
- Use case: Keep two directories in sync without losing any files

**Example (no conflicts):**
```
Before:
  Server: [photo1.jpg, photo2.jpg (hash: aaa, mtime: Nov 1)]
  Client: [photo2.jpg (hash: bbb, mtime: Nov 8), photo3.jpg]

After:
  Server: [photo1.jpg, photo2.jpg (hash: bbb, mtime: Nov 8), photo3.jpg]
  Client: [photo1.jpg, photo2.jpg (hash: bbb, mtime: Nov 8), photo3.jpg]

  (Client's photo2.jpg wins because newer, both get all files)
```

**Conflict resolution:**

When same path exists on both sides with different content (different hash):

- **Default (`--conflict=newer`)**: Newer file wins automatically
  - **In sync plan**: Appears as `modify` operation (not `conflict`)
  - Auto-resolved during execution, no user intervention needed

- **With `--conflict=ask`**: Prompt user for each conflict
  - **In sync plan**: Appears as `conflict` operation
  - Execution pauses, waits for user decision (keep local/remote/both/skip)

- **With `--conflict=keep-both`**: Keep both versions
  - **In sync plan**: Appears as `add` operation with renamed path (e.g., `vacation_conflict_a3f5.jpg`)
  - Both versions preserved automatically

**Preview mode (`--dry-run`):**
- Always shows conflicts in preview output (regardless of resolution strategy)
- Lets user review what will happen before committing

---

## Optional Flags

**Common flags (all commands):**

```bash
--dry-run              # Preview changes without executing
--yes                  # Skip confirmation prompt
```

**Push/Pull specific flags:**

```bash
--no-delete            # Don't delete files (accumulate mode instead of mirror)
```

**Sync specific flags:**

```bash
--conflict=newer       # Newer wins (default behavior, explicit)
--conflict=ask         # Prompt user for each conflict
--conflict=keep-both   # Keep both versions (rename with hash suffix)
```

**Examples:**

```bash
# Preview what push would do
diffa push ~/Photos 192.168.0.39:8080 --dry-run

# Push without deleting server files (accumulate instead of mirror)
diffa push ~/Photos 192.168.0.39:8080 --no-delete

# Sync with manual conflict resolution
diffa sync ~/Photos 192.168.0.39:8080 --conflict=ask

# Sync and keep both versions on conflicts
diffa sync ~/Photos 192.168.0.39:8080 --conflict=keep-both
# Result: vacation.jpg (newer) and vacation_conflict_a3f5.jpg (older)
```

---


## Why This Design?

**Advantages:**

1. **Simple mental model** - Command name tells you everything
   - `push` = "Make server look like me"
   - `pull` = "Make me look like server"
   - `sync` = "Merge both, newer wins"

2. **No flag complexity** - No `--direction=X --mode=Y --conflict=Z` combinations

3. **Familiar** - Like git/docker:
   ```bash
   git push    # Upload to remote
   git pull    # Download from remote
   ```

4. **Persistent server** - Daemon always ready, no coordination needed

5. **Multiple clients** - Many clients can sync to one server

6. **Automation friendly** - Cron jobs work (daemon always running)

**Trade-offs:**

- Push/Pull delete by default (dangerous, but clear from command name)
- Mitigation: Show preview and ask for confirmation
- Safety valve: `--dry-run` flag

---

## Design Decisions

### ✅ Resolved

#### 1. Network Protocol: Daemon + Client
**Decision:** Daemon/client model (persistent server, ephemeral client)

**Server (Linux A):**
```bash
diffa daemon --path ~/Photos --port 8080           # Foreground
diffa daemon --path ~/Photos --port 8080 --detach  # Background
```

**Client (Mac B):**
```bash
diffa push ~/Photos 192.168.0.39:8080   # Mirror to server
diffa pull ~/Photos 192.168.0.39:8080   # Mirror from server
diffa sync ~/Photos 192.168.0.39:8080   # Merge both
```

**Why:** Simple, automation-friendly, no coordination needed, multiple clients supported

---

#### 2. Command Design: Push/Pull/Sync (No Complex Flags)
**Decision:** Three commands with clear behavior (no `--direction` or `--mode` flags)

- `push` = Mirror client → server (deletes server-only files)
- `pull` = Mirror server → client (deletes client-only files)
- `sync` = Merge both, newer wins (no deletions)

**Why:** Intuitive, familiar (like git), simple mental model

---

#### 3. Conflict Resolution: Newer Wins (for sync)
**Decision:** Default to newer-wins for `sync` command

- `push`: Client always wins (mirror behavior)
- `pull`: Server always wins (mirror behavior)
- `sync`: Newer file wins (by mtime)

**Optional:** `--conflict=keep-both` to keep both versions

**Why:** Automatic, sensible default, covers 90% of use cases

---

#### 4. Deletions: Built into Command Semantics
**Decision:** Deletion behavior is implicit in command choice

- `push`/`pull`: Delete by default (mirror mode)
- `sync`: Never delete (merge mode)

**Optional:** `--no-delete` for push/pull to accumulate instead of mirror

**Why:** Clear from command name, no hidden behavior

---

#### 5. Daemon Lifetime: User's Choice
**Decision:** Support both foreground and background modes

- Foreground: `diffa daemon ...` (Ctrl-C to stop)
- Background: `diffa daemon ... --detach` (process runs detached)
- Systemd: User installs service file manually (we provide template)

**Why:** Flexibility, simple to start, can scale to production

---

#### 6. Security: Phase 1 - No Auth (Design for Future)
**Decision:** Start with no authentication, protocol designed for future auth

**Phase 1:** Trust local network (LAN)
**Future:** Add `--auth-key`, pairing codes, or TLS

**Protocol design:** Include `auth` field in messages (null in Phase 1)

**Why:** Ship faster, avoid complexity, most users are on LAN initially

---

#### 7. Metadata: Minimal + Mode (Permissions)
**Decision:** Start with essential metadata

**Always preserved:**
- Path, size, mtime (seconds), hash (MD5)

**Optional (if supported by filesystem):**
- Mode (POSIX permissions: 0644, 0755, etc.)

**Future:**
- Owner/group (multi-user scenarios)
- Extended attributes (tags, ACLs)

**Why:** Simple, cross-platform, covers most use cases

---

### ❓ Still Open

#### 8. Deduplication on Receiver: Transfer Only or Storage?

**Current plan:** Deduplicate during transfer, store separately on receiver

**Question:** Should we support storage deduplication (hard-links/reflinks)?

**Options:**
- Store separately (simple, safe, wastes space)
- Hard-links (saves space, shared content)
- Reflinks (best, but filesystem-dependent)

**Decision pending:** Start without storage dedup, add later if requested?

---

#### 9. Large Files: Resume Support?

**Question:** Support resumable transfers for large files?

**Options:**
- No resume (simple, Phase 1)
- Chunk-based resume (complex, Phase 2+)

**Trade-off:** Simplicity vs robustness for large files

**Recommendation:** Skip in Phase 1, add in Phase 2 if users need it

---

#### 10. Compression: Support or Skip?

**Question:** Compress during transfer?

**Options:**
- No compression (simple, fast for images/videos)
- Optional `--compress` flag (slower CPU, faster network)
- Auto-detect (compress text, skip media)

**Recommendation:** Skip in Phase 1, add `--compress` flag in Phase 2

---

#### 11. Progress Reporting: How Detailed?

**Question:** How much detail to show during sync?

**Options:**
- Minimal: "Syncing... done"
- Summary: Show analysis + progress bar
- Per-file: Show each file transfer

**Recommendation:** Start with summary, add per-file for large transfers

---

## Implementation Phases (Revised)

### Phase 1: Core Library - Local Sync (2-3 weeks)
**Deliverables:**
- Snapshot creation (SQLite, MD5 hashing)
- Snapshot comparison (identify added/modified/deleted/renamed)
- File transfer with content-addressable deduplication
- Move detection (hash tracking, zero-transfer renames)
- Metadata preservation (mtime, size, mode)

**Example (local only):**
```bash
# Library usage (Swift)
let sourceSnapshot = try await Snapshot.create(at: "/Users/alice/Photos")
let destSnapshot = try await Snapshot.create(at: "/Volumes/Backup/Photos")
let diff = try Difference.compare(sourceSnapshot, destSnapshot)
try await diff.apply(mode: .mirror)  // Mirror source to dest
```

**Exit criteria:**
- Sync 10k files in <1 minute (local disk)
- Deduplication works (transfer unique content once)
- Move detection works (renames = 0 bytes transfer)
- Metadata preserved (mtime, mode)

---

### Phase 2: Network Protocol + Daemon (3-4 weeks)
**Deliverables:**
- Custom network protocol (content-addressable queries)
- Daemon mode (`diffa daemon --path ~/Photos --port 8080`)
- Client commands (`push`, `pull`, `sync`)
- Snapshot exchange over network
- Content transfer by hash+size (no paths in protocol)
- Foreground and background daemon modes (`--detach`)

**Example:**
```bash
# Server (Linux A)
diffa daemon --path ~/Photos --port 8080

# Client (Mac B)
diffa push ~/Photos 192.168.0.39:8080
diffa pull ~/Photos 192.168.0.39:8080
diffa sync ~/Photos 192.168.0.39:8080
```

**Exit criteria:**
- Daemon runs continuously, handles multiple clients
- Client connects, syncs, exits
- Content-addressable protocol works (transfer by hash+size)
- Push/Pull/Sync behaviors work as designed
- Network efficiency (no re-transfer of existing content)

---

### Phase 3: Safety & Polish (1-2 weeks)
**Deliverables:**
- Confirmation prompts (show preview before dangerous operations)
- `--dry-run` flag (preview without executing)
- `--no-delete` flag (accumulate instead of mirror)
- `--conflict=keep-both` (keep both versions on conflict)
- Error handling (network failures, disk full, permission denied)
- Progress reporting (summary with progress bar)

**Example:**
```bash
diffa push ~/Photos 192.168.0.39:8080

# Output:
# Analysis complete:
#   Upload to server: 10 files (5 MB)
#   Delete on server: 3 files (old1.jpg, old2.jpg, old3.jpg)
#   Total: 13 files
#
# Continue? [y/N]
```

**Exit criteria:**
- No silent failures (all errors reported clearly)
- Dangerous operations require confirmation
- User can preview with `--dry-run`
- Progress visible for large transfers

---

### Phase 4: Optimization (1-2 weeks)
**Deliverables:**
- Hash caching (avoid re-hashing unchanged files)
- Parallel transfer (multiple files concurrently)
- Incremental snapshots (faster re-scanning by skipping unchanged files via hash cache)
- Streaming for large files (don't load entire file in memory)

**Exit criteria:**
- Re-sync 100k files (no changes) in <5 seconds
- Large syncs use multiple threads (configurable)
- Memory usage stays low (<100 MB for 100k files)

---

### Phase 5: Advanced Features (Optional, 2-3 weeks)
**Deliverables:**
- Authentication (`--auth-key` or pairing codes)
- TLS encryption (optional `--tls` flag)
- Resume support for large files (chunked transfer)
- Compression (`--compress` flag)
- Storage deduplication (hard-links/reflinks on receiver)

**Exit criteria:**
- Secure operation over untrusted networks
- Large file transfers resume after interruption
- Compression reduces bandwidth for text files

---

### Phase 6: Cloud Support (Optional, 4-6 weeks)
**Deliverables:**
- S3 backend (`diffa push ~/Photos s3://bucket/photos`)
- Cloud snapshot storage (SQLite in S3)
- Cloud-native metadata handling (S3 ETags, multipart uploads)
- Lambda/serverless snapshot creation (for large buckets)

**Exit criteria:**
- Can sync local directory to S3 bucket
- Leverages S3 ETags (MD5) for efficiency
- Handles large buckets (millions of objects)

---

## Success Metrics

**What does success look like?**

### Scenario: Photographer with 100k Photos (500 GB)

**First backup (baseline):**
```bash
# Server: diffa daemon --path ~/Backup/Photos --port 8080
# Client:
diffa push ~/Photos 192.168.0.39:8080
# Time: 2 hours (limited by network/disk I/O)
# Transfer: 500 GB (all files)
```

**Daily backup (mirror changes):**
```bash
# User added: 50 new photos (500 MB)
# User deleted: 20 old photos
# User reorganized: Renamed 5 albums (5k files moved)

diffa push ~/Photos 192.168.0.39:8080
# Time: 30 seconds
# Transfer: 500 MB (only new photos)
# Moved: 5k files (instant, no transfer)
# Deleted on server: 20 files (mirror mode)
```

**Reorganization backup (zero content changes):**
```bash
# User renamed all directories: 2024/ → archive/2024/
# 100k files affected

diffa push ~/Photos 192.168.0.39:8080
# Time: 5 seconds
# Transfer: ~50 KB (just metadata updates)
# Savings: 99.9999% (no file content transfer, only path changes)
```

---

## Summary

**Core vision:**
- Efficient sync between directories on different computers
- Content-addressable (MD5+size) for deduplication
- Metadata applied separately
- Zero-transfer for reorganizations

**Key decisions (RESOLVED):**
1. ✅ Network protocol: Daemon + client (persistent server, ephemeral client)
2. ✅ Commands: `push`/`pull`/`sync` (no complex flags)
3. ✅ Security: No auth in Phase 1 (LAN only), design for future auth
4. ✅ Metadata: Minimal (path, mtime, size, hash) + mode (permissions)
5. ✅ Conflicts: Newer wins (sync), client/server wins (push/pull)
6. ✅ Deletions: Built into command (push/pull delete, sync merges)

**Revised phases:**
1. Core library - local sync (2-3 weeks)
2. Network protocol + daemon (3-4 weeks)
3. Safety & polish (1-2 weeks)
4. Optimization (1-2 weeks)
5. Advanced features - auth, resume, compression (optional)
6. Cloud support - S3 backend (optional)

**Next steps:**
- Begin Phase 1 implementation (core library)
- Snapshot creation, comparison, file transfer
- Local-only first, network in Phase 2

---

## Snapshot Exchange Protocol (Internal)

### Overview

For efficient network communication, snapshots are exchanged in a compact CSV format:

**Purpose:**
- **Internal protocol only** (not exposed to users as files)
- Efficient transfer of snapshot data between client and server
- Enables client-side plan generation without heavy network traffic

**Why CSV:**
- Compact: ~170 bytes per file (vs ~500 bytes for JSON)
- Streamable: Process line-by-line, low memory
- Efficient: Handles millions of files

**Flow:**
```
1. Client creates snapshot → exports as CSV
2. Client sends CSV to server (network transfer)
3. Server parses CSV → reconstructs snapshot in memory
4. Server creates own snapshot → exports as CSV
5. Server sends CSV to client
6. Client parses both snapshots → generates SyncPlan (in memory)
7. User previews plan
8. User executes or aborts
```

---

### Snapshot Metadata (JSON Header)

**Small JSON header sent before CSV data:**

```json
{
  "version": 1,
  "path": "/Users/alice/Photos",
  "totalFiles": 100000,
  "totalBytes": 524288000000,
  "timestamp": "2025-11-08T14:30:00Z"
}
```

**Size: ~200 bytes** (constant)

**Fields:**
- `version` - Protocol version
- `path` - Snapshot root path
- `totalFiles` - Number of files in snapshot
- `totalBytes` - Total size of all files
- `timestamp` - When snapshot was created

---

### Snapshot File List (CSV)

**CSV containing all files in snapshot:**

```csv
path,size,hash,mtime,mode
photos/2024/jan/photo001.jpg,2048576,a3f5b2c8d4e6f1a7b9c3e5d7a1f4b6c2,1699459200,0644
photos/2024/jan/photo002.jpg,1835008,b4e6c9a1d5f2a8b3c7e4f6a2b8d5c9e1,1699459201,0644
old/photo.jpg,524288,c5f7d3e2a4b8f6c1d9e7a3f5b2c8d4e6,1699372800,0644
existing/photo.jpg,3145728,d6a8e4f3b5c9a7d2e1f8b4c6a3e7d5f2,1699545600,0644
2024/vacation.jpg,5242880,e7b9f5a4c6d1b8e3f2a7c5d9e4b6f1a8,1699459200,0644
```

**Columns:**
- `path` - File path relative to snapshot root
- `size` - File size in bytes
- `hash` - MD5 hash (32-character hex string, 128 bits)
- `mtime` - Modification time (Unix timestamp, seconds)
- `mode` - POSIX permissions (octal, optional)

**Size: ~170 bytes per row** (with 32-char MD5 hashes)
- 1,000 files ≈ 170 KB
- 10,000 files ≈ 1.7 MB
- 100,000 files ≈ 17 MB
- 1,000,000 files ≈ 170 MB

---

---

## CLI Usage (Simple Workflow)

```bash
# Step 1: Preview changes (dry-run)
diffa push ~/Photos 192.168.0.39:8080 --dry-run

# Behind the scenes:
# 1. Client creates snapshot → exports as CSV
# 2. Client sends CSV to server over network
# 3. Server creates snapshot → sends CSV back
# 4. Client compares snapshots → generates plan in memory
# 5. Client displays formatted preview:
#
# Analysis complete (PUSH mode: mirror client → server):
#
#   📤 Upload (new files): 75,000 files (400 GB)
#      + photos/2024/jan/photo001.jpg (2 MB)
#      + photos/2024/jan/photo002.jpg (1.8 MB)
#      ... and 74,998 more
#
#   ✏️  Overwrite (server files replaced): 10,000 files (20 GB)
#      ≠ existing/photo.jpg (server: 3 MB → client: 1 MB)
#      ≠ sunset.jpg (server: 3.5 MB → client: 3 MB)
#      ... and 9,998 more
#
#   📦 Moved (zero-transfer): 5,000 files
#      → 2024/vacation.jpg → trips/hawaii-2024.jpg
#      ... and 4,999 more
#
#   🗑️  Delete (server-only files): 15,000 files
#      - old/photo1.jpg
#      - old/photo2.jpg
#      ... and 14,998 more
#
# Summary:
#   Total files processed: 100,000
#   Transfer required: 420 GB (new + overwrite)
#   Estimated time: 1 hour
#
# ⚠️  WARNING: This will DELETE 15,000 files on the server!
#     Server will become an exact mirror of client.
#
# Continue? [y/N]

# If user says 'y', execute the sync
# If user says 'n', abort (no changes made)

# Actually execute (after reviewing --dry-run output)
diffa push ~/Photos 192.168.0.39:8080
# Executes the sync, shows progress, completes
```

---

### GUI App Usage (Future Phase)

**SwiftUI example (uses library directly, no file export):**

```swift
// GUI app uses library API directly
Task {
    // 1. Create snapshots
    let clientSnapshot = try await Snapshot.create(at: localPath)
    let serverSnapshot = try await connection.getRemoteSnapshot()

    // 2. Generate plan
    let plan = try SyncPlan.analyze(
        client: clientSnapshot,
        server: serverSnapshot,
        mode: .sync
    )

    // 3. Display preview
    await MainActor.run {
        statisticsView.display(plan.statistics)
        operationsView.display(plan.operations)
    }

    // 4. User reviews and clicks "Apply"
    // (Execute happens when user confirms)
}

// SwiftUI view
struct SyncPlanView: View {
    let plan: SyncPlan

    var body: some View {
        List {
            ForEach(plan.operations, id: \.path) { operation in
                OperationRow(operation)
                    .icon(for: operation.action)
            }
        }
        .toolbar {
            Button("Apply Changes") {
                Task {
                    try await plan.execute()
                }
            }
        }
    }
}

// Icon mapping
func icon(for action: FileAction) -> String {
    switch action {
    case .add:      return "arrow.up.circle.fill"     // Green
    case .delete:   return "trash.fill"               // Red
    case .modify:   return "pencil.circle.fill"       // Orange
    case .move:     return "arrow.right.circle.fill"  // Blue
    case .conflict: return "exclamationmark.triangle.fill" // Yellow
    }
}
```

**Visual representation:**

```
┌─────────────────────────────────────────────────┐
│  Sync with 192.168.0.39:8080                    │
├─────────────────────────────────────────────────┤
│  Summary                                        │
│    Total: 100,000 files (500 GB)                │
│    Transfer: 80,000 files (420 GB)              │
│    Estimated: 1 hour                            │
├─────────────────────────────────────────────────┤
│  📤 Upload to server (75,000 files) [Filter ▾]  │
│    ✓ photos/2024/jan/photo001.jpg      2 MB    │
│    ✓ photos/2024/jan/photo002.jpg    1.8 MB    │
│    ...                                          │
│                                                 │
│  📥 Download from server (20,000)   [Filter ▾]  │
│    ✓ remote/photo1.jpg                  5 MB    │
│    ✓ remote/photo2.jpg                  3 MB    │
│    ...                                          │
│                                                 │
│  ⚠️  Conflicts (500 files)          [Filter ▾]   │
│    ! photos/sunset.jpg                          │
│      Local:  3 MB (Nov 8, 14:00)                │
│      Remote: 3.5 MB (Nov 8, 15:00)              │
│      [Keep Local] [Keep Remote] [Keep Both]     │
│    ...                                          │
│                                                 │
│             [Cancel]  [Apply Changes]           │
└─────────────────────────────────────────────────┘
```

---

### Swift API (Library)

```swift
// Core workflow
struct SyncPlan {
    var mode: SyncMode
    var statistics: Statistics
    var operations: [FileOperation]

    // Create plan by comparing snapshots
    static func analyze(
        client: Snapshot,
        server: Snapshot,
        mode: SyncMode
    ) throws -> SyncPlan {
        // Compare snapshots and generate operations
        let operations = try compareSnapshots(client, server, mode)
        let statistics = calculateStatistics(operations)

        return SyncPlan(
            mode: mode,
            statistics: statistics,
            operations: operations
        )
    }

    // Execute the plan
    func execute() async throws {
        for operation in operations {
            try await applyOperation(operation)
        }
    }

    // Format as text for CLI display
    func formatAsText() -> String {
        // Generate formatted output for terminal
        // ... implementation
    }
}

enum SyncMode {
    case push   // Client → Server (mirror)
    case pull   // Server → Client (mirror)
    case sync   // Bidirectional (merge)
}

struct Statistics {
    var totalFiles: Int
    var totalBytes: Int64
    var transferFiles: Int
    var transferBytes: Int64
    var addedFiles: Int
    var modifiedFiles: Int
    var deletedFiles: Int
    var movedFiles: Int
    var conflictFiles: Int
    var estimatedTime: TimeInterval
}

enum FileAction {
    case add        // New file
    case delete     // Remove file
    case modify     // Update existing (includes auto-resolved conflicts)
    case move       // Rename/move (zero-transfer)
    case conflict   // Manual resolution needed (--conflict=ask only)
}

struct FileOperation {
    var action: FileAction
    var path: String
    var size: Int64
    var hash: Data          // MD5 (16 bytes binary)
    var mtime: Int64
    var oldSize: Int64?     // For modify
    var oldHash: Data?      // For modify
    var newPath: String?    // For move
    var remoteHash: Data?   // For conflict
}
```

---

### Protocol Benefits

✅ **Efficient** - CSV is 70% more compact than JSON for large file lists
✅ **Scalable** - Handles millions of files without memory issues
✅ **Streamable** - Can process CSV line-by-line during network transfer (low memory)
✅ **Simple** - Easy to parse in any programming language
✅ **Fast** - Minimal parsing overhead, direct string processing
✅ **Resumable** - Can resume transfer mid-stream if connection drops (future)
✅ **Bandwidth-efficient** - Transfers only metadata, not file content

---

## Remaining Questions

1. **Deduplication on receiver: Transfer-only or storage?**
   - Current plan: Deduplicate during transfer, store separately
   - Future option: Hard-links/reflinks for storage dedup

2. **Large file resume: Phase 1 or later?**
   - Recommendation: Skip in Phase 1, add chunking in Phase 5

3. **Compression: Support or skip initially?**
   - Recommendation: Skip in Phase 1, add `--compress` in Phase 5

4. **Progress reporting: How detailed?**
   - Recommendation: Summary with progress bar (Phase 3)

These are minor details that won't block Phase 1 implementation. Can be decided during or after Phase 1 based on user feedback.
