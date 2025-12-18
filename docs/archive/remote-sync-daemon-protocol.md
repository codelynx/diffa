# Remote Synchronization via Snapshot Exchange

> **⚠️ ARCHIVED - SUPERSEDED BY SIMPLIFIED DESIGN**
>
> **Status:** Shelved / Reference Only
> **Date:** 2025-11-07 (archived 2025-11-07)
> **Superseded by:** `docs/efficient-sync.md`
>
> **Why archived:**
> This document described a daemon-based network protocol requiring:
> - Server mode (`diffa serve`)
> - Patch system (Phase 2 dependency)
> - Content-addressable storage with `.blob` + `.meta` sidecars
> - TLS/authentication infrastructure
> - Multi-phase rollout (6a, 6b, 6c)
>
> **Decision:** Too complex for core mission.
> - No daemon - use storage abstraction instead (local now, S3 later)
> - No patches - direct file transfer simpler
> - No custom protocol - use existing (SSH for local, S3 SDK for cloud)
> - Deduplication during transfer (not storage infrastructure)
>
> **Current approach:** See `docs/efficient-sync.md`
>
> Preserved for protocol design ideas and historical context.

---

## Original Proposal (Archived)

**Status:** Future feature proposal (Phase 6+)
**Depends on:** Phase 1-5 complete (especially Phase 4 move detection)
**Date:** 2025-11-07

## Problem Statement

Synchronizing large directory trees between remote computers using traditional network filesystem protocols (NFS, SMB, etc.) is inefficient due to excessive network traffic. Operations like renaming directories or moving files require transferring metadata for all affected files, even when the file contents haven't changed.

**Example inefficiency:**
- Rename directory containing 10,000 unchanged files
- NFS/SMB: 10,000 file operations over network, multiple RTTs per file
- Total traffic: Potentially hundreds of MB just for metadata
- Time: Minutes to hours depending on network latency

## Proposed Solution

Leverage Diffa's snapshot-based architecture to enable efficient remote synchronization by **exchanging snapshots instead of file listings**.

### Core Concept

1. Both computers run Diffa
2. Each side creates a local snapshot of their directory
3. Snapshots are exchanged over network (small transfer)
4. Each side compares snapshots locally (no network I/O)
5. Only minimal necessary files are transferred based on hash comparison
6. Local operations (copy, move) reconstruct directory structure

### Network Efficiency

**Traditional approach (NFS/SMB):**
```
Operation: Rename directory with 10,000 files
Network sees: 10,000 file metadata operations
Traffic: Multiple RTTs per file, all metadata transferred
```

**Diffa snapshot approach:**
```
1. Server: Create snapshot (local, ~2MB for 10,000 files)
2. Transfer: Send snapshot over network (~2MB)
3. Client: Compare snapshots locally (0 network traffic)
4. Client: Detect moves via hash comparison
5. Transfer: Only changed file contents (possibly 0 bytes!)
6. Client: Reconstruct using local copy/move operations
```

**Savings for rename scenario:** ~100s of MB → ~2MB transfer

## Protocol Design

### CLI Interface

```bash
# Host side: Run Diffa server with metadata level
diffa serve /path/to/data \
  --mode=both \
  --port=8080 \
  --metadata-level=standard \
  --auth-key=your-api-key \
  --tls=required

# Client side: Sync with remote
diffa sync /local/path diffa://192.168.1.100:8080/path/to/data \
  --metadata-level=standard \
  --auth-key=your-api-key

# Client with auto-detection (inspects remote level and matches it)
diffa sync /local/path diffa://192.168.1.100:8080/path/to/data
```

**Metadata Flags:**
- `--metadata-level={minimal|standard|full}`: Set capture level (default: auto-detect from remote)
- `--require-metadata-level=X`: Force specific level, fail if unsupported
- `--allow-metadata-downgrade`: Allow syncing with lower metadata level (logs warning)

**Auto-detection behavior:**
- Client inspects remote metadata level before scanning local tree
- Reuses remote level for local snapshot to keep comparisons stable
- Warns if metadata levels differ: "Remote uses 'standard', local snapshot will match"

### Permission Modes

- `--mode=receive`: Server only provides snapshots (read-only)
- `--mode=provide`: Server only receives updates (write-only)
- `--mode=both`: Bidirectional synchronization

### Protocol Flow

```
1. Handshake
   Client → Server: HELLO
     - protocol_version: integer
     - supported_metadata_levels: [minimal, standard, full]
     - default_metadata_level: standard
     - compression: [none]  (future: lz4, zstd)
     - auth_scheme: api-key
     - tls_mode: required

   Server → Client: CAPABILITIES
     - modes: [receive, provide, both]
     - supported_metadata_levels: [minimal, standard]
     - active_metadata_level: standard  (lowest common denominator)
     - compression: [none]
     - auth_required: true
     - tls_available: true

   Metadata negotiation:
   - Client and server agree on single active level (lowest common denominator)
   - If no overlap, abort with error: "Server requires metadata level X, client supports Y"
   - Client can override with --require-metadata-level flag (fails if unsupported)

   Hash algorithm: MD5 always (no negotiation needed)

2. Snapshot Exchange
   Client → Server: REQUEST_SNAPSHOT /path/to/data
   Server → Client: SNAPSHOT
     - snapshot_db: [SQLite database bytes]
     - metadata_capture_level: standard  (stored in snapshot header)
     - schema_version: 1

   Client creates local snapshot using active_metadata_level

3. Local Comparison
   Client: Compare snapshots using existing Difference logic
   Client: Handle metadata level mismatches (treat absent fields as nil, not "changed")
   Client: Compute minimal file transfer list

4. File Transfer (with metadata)
   Client → Server: REQUEST_FILES [
     {hash: <16-byte MD5 BLOB>, size: bytes},
     ...
   ]

   Server → Client: FILE_RESPONSE [
     {
       hash: <16-byte MD5 BLOB>,
       metadata: {level: standard, mtime: ts, mode: 0644, owner: "alice", group: "staff"},
       chunks: [{id: 0, size: 1048576, offset: 0}, ...],
       content: [binary stream]
     },
     ...
   ]

   For resumable transfers:
   - Server keeps metadata available until all chunks acked
   - Client requests missing chunks using session_id + chunk_id
   - Content-addressable storage includes hash.meta sidecar files

   Or for bidirectional:
   Client → Server: SEND_FILES [similar format with metadata]

5. Verification
   Client: Verify received file hashes
   Client: Apply metadata (chmod, chown, mtime) per active_metadata_level
   Client: Apply changes locally
   Client → Server: SYNC_COMPLETE
```

**Metadata Levels (from Decision 3):**
- `minimal`: MD5 hash (BLOB) + size + mtime + mode (permissions)
- `standard`: minimal + owner + group (POSIX ownership)
- `full`: standard + extended attributes (future)

**Note:** Hash is MD5 (16-byte BLOB) for all levels. Stored as binary in SQLite, hex in JSON/filenames.

### Content-Addressable Transfer

Files requested by MD5 hash rather than path:
- Enables deduplication (same content, different paths)
- Supports move detection (same hash, different path = local move)
- Allows resumable transfers (request missing hashes)
- Natural caching layer (hash → content mapping)

**Metadata Integration:**
- Each hash maps to `{content, metadata}` tuple, not just raw bytes
- Hash cache stores both `hash.blob` (content) and `hash.meta` (metadata JSON/CBOR)
- Metadata hash enables cache invalidation when only permissions/ownership change
- When applying cached files, metadata is restored per `active_metadata_level`
- Resumable transfers: Metadata sent once per file, replayed until all chunks acked

**Storage Format:**
```
cache/
├── blobs/
│   ├── <hex-md5>.blob     # Raw file content (hex filename for filesystem compatibility)
│   └── <hex-md5>.meta     # JSON: {level, mtime, mode, owner, group}
└── sessions/
    └── session_id.db      # Resumable transfer state
```

**Example metadata sidecar:**
```json
{
  "level": "standard",
  "mtime": 1730937600,
  "mode": 420,
  "owner": "alice",
  "group": "staff",
  "size": 4096,
  "hash": "a3f5c81e8f4b2d1c..."  // Hex string for JSON (16 bytes MD5)
}
```

**Note:**
- Hash stored as BLOB in SQLite, hex in JSON/filenames for compatibility.
- Owner/group stored as strings (per `Sources/Diffa/Core/Metadata.swift`), not numeric IDs.
- For cloud storage without user/group semantics, use synthetic values like "diffa" / "diffa".

## Cloud Storage Extensions

The snapshot exchange protocol naturally extends to cloud storage providers. All three major providers have partial MD5 support, requiring custom metadata fallbacks for edge cases.

### Cloud Integration (S3, GCS, Azure)

```bash
# Cloud sync (all providers)
diffa sync /local/path s3://bucket/prefix
diffa sync /local/path gs://bucket/prefix
diffa sync /local/path az://account/container

# Protocol (same for all):
1. Download latest snapshot from cloud://.diffa/snapshot-latest.db
2. Compare local snapshot vs cloud snapshot
3. Fetch MD5 from cloud metadata when available, fallback to custom metadata
4. Use cloud API to fetch only needed objects (by hash)
5. Use multipart/chunked upload for efficient writes, store MD5 in custom metadata
```

**MD5 Availability (realistic view):**
- **GCS:** ✅ `md5Hash` usually present, ❌ missing for composite objects / CSEK
- **Azure:** ⚠️ `Content-MD5` only when client supplies on upload (no server-side compute)
- **S3:** ⚠️ ETag = MD5 only for simple uploads (multipart/KMS require custom metadata)

**Solution:** All adapters store MD5 in custom object metadata as fallback when native MD5 unavailable.

### Cloud Provider Adapters

Each adapter implements:
- **Snapshot endpoint**: Returns current snapshot database
- **Blob storage**: Content-addressable file storage by hash
- **Metadata storage**: POSIX metadata sidecars for each blob
- **Optional: Snapshot generation**: Periodic snapshot creation

**Supported providers:**
1. **GCP:** Cloud Storage + Cloud Functions (`md5Hash` usually available, except composite/CSEK)
2. **Azure:** Blob Storage + Azure Functions (`Content-MD5` when client supplies it)
3. **AWS:** S3 + Lambda (ETag = MD5 for simple uploads only)
4. **Generic:** Any HTTP endpoint serving snapshots + blob storage

**Implementation recommendation:** All three providers require similar custom metadata fallbacks for edge cases. Implement in order of user demand or cloud experience.

### Cloud Metadata Strategy

**Problem:** Object stores lack native POSIX semantics (permissions, ownership, mtime).

**Solution:** Snapshot-first approach with explicit metadata objects.

**Architecture:**

1. **Snapshot Generation:**
   - Snapshots created on POSIX-aware machines (e.g., Lambda with EFS mount)
   - For cloud-native data, use default metadata (mode=0644, owner="diffa", group="diffa")
   - Snapshot header stores `metadata_capture_level` used during creation

2. **Blob Upload (dual-object pattern):**
   ```
   PUT blobs/<hash>          # Raw file content
   PUT blobs/<hash>.meta     # JSON metadata sidecar
   PUT snapshots/latest.db   # Uploaded LAST (manifest references exact versions)
   ```

3. **Metadata Object Format:**
   ```json
   {
     "level": "standard",
     "mtime": 1730937600,
     "mode": 420,
     "owner": "alice",
     "group": "staff",
     "size": 4096,
     "etag": "abc123...",
     "generation": 1234
   }
   ```

   **Note:** Owner/group are strings (usernames/group names), not numeric IDs. For cloud-native files without POSIX origins, use synthetic values like `"diffa"` / `"diffa"`.

4. **Consistency Guarantees:**
   - Snapshot manifest uploaded last (references blob ETags/generations)
   - Clients refuse manifests with missing blob references
   - Retry logic for eventual consistency (read-after-write)
   - Atomic snapshot updates (write to temp key, rename)

5. **Restore Operations:**
   ```bash
   diffa sync s3://bucket/data /local/restore
   ```
   - For each blob: Download `.meta` sidecar
   - Apply metadata per `active_metadata_level` (chmod, chown, touch)
   - Fall back to defaults if `.meta` missing (warn user)
   - Verify all metadata applied before marking sync complete

6. **IAM Requirements:**
   - `s3:GetObject` for blobs + metadata + snapshots
   - `s3:PutObject` for bidirectional sync
   - `s3:ListBucket` for resumable transfers (list incomplete uploads)
   - Bucket versioning recommended (recover from accidental deletes)

**Default Metadata Policy:**
- Files uploaded from POSIX systems: Preserve actual metadata
- Files created in cloud: Use sensible defaults (mode=0644, synthetic owner)
- Missing `.meta` files: Warn user, apply defaults, continue sync

### Hash Strategy: MD5 + BLOB Storage

**Decision:** Keep it simple - MD5 everywhere, stored as binary BLOB.

**Rationale:**
- **Use case:** Integrity checking, not defending against adversaries
- **Collision risk:** MD5 + size at 2B files ≈ 10^-20 (negligible)
- **Performance:** 3x faster than SHA256 (~2.3 hours vs ~7 hours for 100TB)
- **Cloud native (partial support, requires fallbacks):**
  - ⚠️ GCS: `md5Hash` usually available (missing for composite/CSEK)
  - ⚠️ Azure: `Content-MD5` only when client supplies on upload
  - ⚠️ S3: ETag = MD5 only for simple uploads
  - All providers: Store MD5 in custom metadata as fallback
- **Storage:** 16-byte BLOB vs 32-char hex TEXT (50% savings = 32GB for 2B files)
- **Philosophy:** "Simple first, no frills" - one algorithm, binary storage

**Cloud advantage:** Choosing MD5 means we can leverage native cloud provider metadata when available (majority of uploads), with custom metadata fallback for edge cases.

**Phase 1-5 Implementation Note:**
Current codebase uses SHA256 (see `Sources/Diffa/Core/FileSystemItem.swift`). Before Phase 6, Phase 1-5 will be updated to use MD5 BLOB storage. Since Diffa is pre-release, no migration tooling needed.

**Snapshot Schema:**
```sql
CREATE TABLE files (
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL,
    size INTEGER NOT NULL,
    mtime INTEGER NOT NULL,
    mode INTEGER NOT NULL,
    hash BLOB NOT NULL,  -- 16 bytes MD5, not hex string
    ...
);

CREATE INDEX idx_hash ON files(hash);  -- Fast lookup by hash
```

**Cloud Provider MD5 Support:**

GCS and Azure have better MD5 support than S3:

| Provider | MD5 Source | Always Available? | Format | Notes |
|----------|-----------|-------------------|--------|-------|
| **GCS** | `md5Hash` property | ⚠️ Usually | Base64 | Missing for composite objects, CSEK |
| **Azure** | `Content-MD5` header | ⚠️ Optional | Base64 | Client must supply on upload |
| **S3** | ETag | ⚠️ Simple only | Hex | Multipart/KMS not usable |

**Implementation:**

```python
def get_hash_from_cloud(provider, object):
    if provider == 'gcs':
        # GCS: Usually has md5Hash (base64), but not for composite/CSEK
        if object.md5_hash:
            return base64.b64decode(object.md5_hash)  # → 16-byte BLOB
        else:
            # Composite object or CSEK: Check custom metadata first
            if 'md5' in object.metadata:
                return bytes.fromhex(object.metadata['md5'])
            # Fallback: Compute locally (expensive for large objects)
            else:
                return compute_md5_blob(download_object(object))

    elif provider == 'azure':
        # Azure: Client must supply Content-MD5 on upload (no server-side compute)
        md5_b64 = object.content_settings.content_md5
        if md5_b64:
            return base64.b64decode(md5_b64)
        else:
            # Check custom metadata (if client stored it separately)
            if 'md5' in object.metadata:
                return bytes.fromhex(object.metadata['md5'])
            # Fallback: Compute locally (expensive)
            else:
                return compute_md5_blob(download_object(object))

    elif provider == 's3':
        # S3: Try ETag first (simple uploads), fallback to compute
        etag = object.etag.strip('"')
        if len(etag) == 32 and etag.isalnum():  # Simple upload
            return bytes.fromhex(etag)  # Hex → BLOB
        else:  # Multipart/KMS
            # Check custom metadata 'x-amz-meta-md5'
            if 'md5' in object.metadata:
                return bytes.fromhex(object.metadata['md5'])
            # Fallback: Compute locally (expensive)
            else:
                return compute_md5_blob(download_object(object))
```

**Strategy (with realistic limitations):**
- **GCS:** Use `md5Hash` when present (most uploads), check custom metadata for composite/CSEK, compute locally as last resort
- **Azure:** Use `Content-MD5` if present (client must supply on upload), check custom metadata fallback, compute locally as last resort
- **S3:** Use ETag for simple uploads, check custom metadata `x-amz-meta-md5` for multipart, compute locally as last resort

**Upload Requirements:**
- **GCS:** Simple/resumable uploads get automatic MD5. For composite uploads, store MD5 in custom metadata before composing.
- **Azure:** Always include `Content-MD5` header when calling `upload_blob()`, or store in custom metadata.
- **S3:** Simple uploads automatic. For multipart, compute MD5 client-side and store in `x-amz-meta-md5`.

**Performance Impact:**
- When MD5 available from cloud: Zero compute ✅
- When custom metadata exists: Zero compute ✅
- When neither present: Must download + compute MD5 ❌ (expensive, avoid by storing MD5 on upload)

**CLI Simplification:**
```bash
# All commands use MD5 by default
diffa sync /local/path diffa://remote:8080/data
diffa sync /local/path s3://bucket/data

# No --hash-algorithm flag needed (only one choice)
# S3 adapter automatically uses ETags when valid
```

**Performance at 100TB (2B files, 8-core parallelism):**
- MD5 scan: ~2.3 hours
- S3 ETag reuse: ~0 hours (metadata only) when ETags are pure MD5
- Storage: 32GB for hashes (vs 64GB if using SHA256 hex strings)

**Trade-offs Accepted:**
- ❌ No cryptographic security (MD5 is broken for adversarial use)
- ❌ S3 multipart/KMS uploads require re-computing MD5 (can't use ETag directly)
- ✅ 3x faster than SHA256
- ✅ Native S3 compatibility for simple uploads
- ✅ 50% less storage (BLOB vs hex TEXT)
- ✅ Simpler codebase (no algorithm negotiation)
- ✅ Adequate for typical use case (directory integrity, not security)

**Future:** If cryptographic security needed later, add SHA256 as opt-in (not default)

## Technical Requirements

### Security

**Authentication:**
- API key authentication
- SSH key-based authentication
- OAuth for cloud providers

**Encryption:**
- TLS 1.3 for all network traffic
- Optional: End-to-end encryption for file contents

**Authorization:**
- Path-based permissions (who can access which directories)
- Read/write access control per client

### Reliability

**Resumable Transfers:**
- Store transfer state in local SQLite database
- Request only missing hashes on reconnection
- Verify each file hash after transfer

**Network Partitions:**
- Detect connection loss and retry with exponential backoff
- Preserve partial transfer state
- Conflict resolution for bidirectional sync (use existing Phase 3 logic)

**Error Handling:**
- Verify all received file hashes match requested hashes
- Atomic operations (all-or-nothing sync)
- Rollback capability using patch revert logic

### Performance

**Parallel Transfers:**
- Transfer multiple files concurrently
- Configurable parallelism (default: 4 simultaneous transfers)

**Streaming:**
- Stream large files (>100MB) without loading into memory
- Chunked transfer with progress reporting

**Compression (Optional):**
- Per "simple first" philosophy: Maybe later
- If added: Negotiate compression in CAPABILITIES handshake
- LZ4 or Zstd for balance of speed/compression

## Implementation Phases

This feature requires foundational work from earlier phases:

**Dependencies:**
- ✅ Phase 1: Snapshot creation and comparison
- ✅ Phase 2: Patch system for minimal transfers
- ✅ Phase 3: Synchronization logic and conflict resolution
- ✅ Phase 4: Move detection via hash comparison (CRITICAL)
- ✅ Phase 5: CLI tool foundation

**Note:** Current implementation (Phase 1-5) uses SHA256 (see `Sources/Diffa/Core/FileSystemItem.swift`). Before starting Phase 6, the hash algorithm will be switched to MD5 BLOB storage as specified in this proposal. Since Diffa is pre-release, no migration tooling needed - just update Phase 1-5 code.

**New components needed:**
- ❌ Network protocol specification (this document is a start)
- ❌ Server mode for Diffa (`diffa serve`)
- ❌ Content-addressable storage and transfer
- ❌ Authentication and authorization
- ❌ Cloud provider adapters

**Suggested phasing:**

**Phase 6a: Local Network Sync**
- **Deliverables:**
  - Snapshot schema: Add `metadata_capture_level` to header, store hash as BLOB (16-byte MD5)
  - CLI flags: `--metadata-level`, `--require-metadata-level`, `--allow-metadata-downgrade`
  - Protocol handshake with metadata negotiation (HELLO/CAPABILITIES)
  - Basic file transfer with metadata sidecars (FILE_REQUEST/FILE_RESPONSE)
  - MD5 hash computation (only algorithm, simple)
  - Server mode (`diffa serve`) with API key authentication
  - TLS encryption (required, self-signed certs allowed for LAN)
  - Content-addressable storage: `<hex-md5>.blob` + `<hex-md5>.meta` sidecars
  - Single-threaded transfers (simplicity first)

- **Exit Criteria:**
  - ✅ Sync 10k files between two Macs on LAN (<5 min)
  - ✅ **Metadata fidelity:** Round-trip preserves permissions + mtime (automated test)
  - ✅ TLS required by default (self-signed cert auto-generation for dev)
  - ✅ API key authentication enforced
  - ✅ Metadata level negotiation prevents silent downgrades
  - ✅ Integration test: Compare pre-sync and post-sync metadata, zero diffs

**Phase 6b: Production Hardening**
- **Deliverables:**
  - Parallel transfers (configurable, default 4 concurrent)
  - Resumable transfers with session state (SQLite tracking)
  - Chunked transfer for large files (>100MB)
  - SSH key authentication support
  - Production TLS (CA-signed certs, certificate pinning)
  - Bandwidth limiting (`--bwlimit`)
  - Network partition handling (retry with exponential backoff)

- **Exit Criteria:**
  - ✅ Sync 100k files reliably with network interruptions (<30 min on SSD)
  - ✅ **Metadata fidelity:** Owner/group preserved when using `--metadata-level=standard`
  - ✅ Resumable: Interrupt at 50%, resume completes remaining files only
  - ✅ No metadata regressions: Automated tests verify chmod/chown/mtime
  - ✅ Stress test: 10 interruptions during 100k file sync, completes successfully

**Phase 6c: Cloud Adapters**
- **Deliverables:**
  - S3 adapter with dual-object pattern (`blobs/<hex-md5>` + `blobs/<hex-md5>.meta`)
  - S3 ETag reuse for simple uploads + `x-amz-meta-md5` custom metadata for multipart
  - **GCS adapter** (`md5Hash` when available, custom metadata for composite/CSEK)
  - **Azure adapter** (`Content-MD5` when client supplies, custom metadata fallback)
  - All adapters: Custom metadata storage for MD5 when native support unavailable
  - Consistency handling (read-after-write retry, ETag/generation verification)
  - Default metadata policy for cloud-native files
  - Snapshot manifest references exact blob versions (ETag/generation)

- **Exit Criteria:**
  - ✅ Sync from local to S3/GCS/Azure and back (10k files, <10 min each)
  - ✅ **Metadata fidelity:** Cloud round-trip preserves permissions + owner/group strings (via `.meta` sidecars)
  - ✅ **Cloud MD5 optimization:**
    - GCS: Uses `md5Hash` when present, custom metadata for composite objects
    - Azure: Uses `Content-MD5` when present, custom metadata fallback
    - S3: Simple uploads use ETag, multipart stores `x-amz-meta-md5`
  - ✅ **Edge case handling:**
    - GCS composite uploads: MD5 stored in custom metadata, verified on download
    - Azure missing Content-MD5: Falls back to custom metadata or local compute
    - S3 multipart: Client computes MD5 during upload, stores in metadata
  - ✅ Restore test: Files with varied modes/ownership strings restored correctly
  - ✅ Default metadata: Missing `.meta` files trigger warning, apply defaults (mode=0644, owner="diffa")
  - ✅ Consistency: Refuse manifests with missing blob references
  - ✅ Integration test: Compare local → cloud → local2, verify metadata diff = 0 (all 3 providers)

## Advantages Over Existing Tools

**vs rsync:**
- rsync: Incremental transfer but no persistent snapshots
- Diffa: Reuse snapshots for multiple comparisons, historical comparisons

**vs Syncthing:**
- Syncthing: P2P sync with distributed indices, complex setup
- Diffa: Simple client-server or peer-peer, explicit snapshots

**vs restic:**
- restic: Backup-focused with snapshots and content-addressable storage
- Diffa: Bidirectional sync with conflict resolution, not just backup

**Diffa's unique advantages:**
- Snapshot-first design makes protocol simpler
- Separation of comparison logic from transfer logic
- Hash-based move detection built-in (Phase 4)
- Existing patch/revert infrastructure for reliability

## Example Use Cases

### 1. Development Machine Sync
```bash
# Work Mac
diffa serve ~/Projects --mode=both --port=8080 --metadata-level=standard

# Home Mac (auto-detects standard level from server)
diffa sync ~/Projects diffa://work-mac.local:8080/Projects
```
Result: Only changed source files transfer, not entire Git repos. Permissions and ownership preserved.

### 2. Backup to S3
```bash
# Periodic backup
diffa snapshot /important/data -o /tmp/snapshot.db
diffa sync /important/data s3://backup-bucket/important-data

# Later: Restore
diffa sync s3://backup-bucket/important-data /restore/here
```
Result: Only changed files uploaded to S3, efficient incremental backup

### 3. Multi-Site Deployment
```bash
# Central server has golden master (minimal metadata sufficient)
diffa serve /var/www/production --mode=receive --port=8080 --metadata-level=minimal

# Regional servers sync (matches minimal level)
diffa sync /var/www/local diffa://central:8080/var/www/production
```
Result: Only changed web assets transfer, near-instant deploys. File permissions preserved, ownership not needed for web content.

### 4. Mobile Photo Sync
```bash
# Home NAS
diffa serve /photos --mode=both --port=8080

# Laptop (on vacation)
diffa sync ~/Photos diffa://home-nas:8080/photos
```
Result: Only new photos upload, existing photos matched by hash

## Open Questions

### Resolved via Metadata Plan (2025-11-07)

~~1. **Metadata negotiation:** How do peers agree on metadata levels?~~
   - **Resolution:** Protocol handshake exchanges `supported_metadata_levels`, negotiates to lowest common denominator
   - See: Protocol Flow section, lines 72-93

~~2. **Metadata in file transfer:** How is metadata sent with content-addressable blobs?~~
   - **Resolution:** Dual sidecar pattern: `hash.blob` + `hash.meta` (JSON)
   - See: Content-Addressable Transfer section, lines 172-200

~~3. **Cloud metadata storage:** How to preserve POSIX metadata in object stores?~~
   - **Resolution:** Dual-object pattern with `.meta` sidecars, snapshot-first approach
   - See: Cloud Metadata Strategy section, lines 233-291

~~4. **Security in Phase 6a:** Can we defer TLS/auth to later phases?~~
   - **Resolution:** No. TLS + API key auth required in 6a (self-signed certs allowed for LAN)
   - See: Phase 6a exit criteria, lines 446-453

~~5. **Hash algorithm for cloud scale:** Should we support MD5 + S3 ETags for 100TB+ use cases?~~
   - **Resolution:** Yes. MD5 everywhere, stored as BLOB. Simple, fast, S3-compatible.
   - See: Hash Strategy section, lines 293-359

### Still Open

1. **Protocol format:** Binary (msgpack, protobuf) or text (JSON)?
   - Recommendation: JSON for metadata sidecars (already decided), binary (msgpack) for protocol messages
   - Rationale: JSON makes `.meta` files debuggable, msgpack keeps protocol efficient

2. **Snapshot caching:** Should server cache client snapshots?
   - Use case: Avoid re-sending unchanged snapshots
   - Recommendation: Yes, with TTL expiration (Phase 6b)
   - Implementation: Store hash of snapshot + metadata_level, return cached if match

3. **Conflict resolution UI:** How to present conflicts to user in CLI?
   - Recommendation: Interactive prompt with diff preview (Phase 3 conflict resolution applies)
   - Format: Show file path, timestamps, sizes, metadata diffs, prompt for action

4. **Bandwidth limiting:** Support for `--bwlimit` like rsync?
   - **Resolution:** Yes, add to Phase 6b (important for background sync)
   - Implementation: Token bucket algorithm per connection

5. **Incremental snapshots:** Send only snapshot delta instead of full snapshot?
   - Optimization: For 100k+ file directories
   - Recommendation: Phase 6b or later, after basic protocol proven
   - Approach: Send base snapshot hash + SQLite journal/diff

6. **Extended attributes:** When to support `full` metadata level?
   - Decision: Not Phase 6. Requires platform-specific APIs (xattr on macOS/Linux, ADS on Windows)
   - Recommendation: Phase 7 or later, after standard workflow validated

7. **Metadata downgrade policy:** What happens when syncing standard → minimal?
   - Current: `--allow-metadata-downgrade` permits (logs warning), default rejects
   - Question: Should we preserve downgraded metadata in snapshot annotations for future restore?
   - Recommendation: No for Phase 6a (adds complexity), revisit if users request

## References

- Main design: `DESIGN.md`
- Architecture: `docs/architecture.md`
- Phase planning: `docs/implementation-readiness.md`
- CLI design: `docs/cli-design.md`
- Synchronization: `docs/synchronization.md`
- Competitive analysis: `docs/competitive-analysis.md`
- **Metadata hardening plan:** `docs/remote-sync-metadata-plan.md` (2025-11-07)
- **Cross-platform metadata:** `docs/cross-platform-metadata.md` (2025-11-07) - Critical compatibility framework
- Decision 3 (Metadata): `docs/decisions.md` (lines 69-116)

## Notes

- This is a brainstorm/proposal, not a commitment
- Focus remains on Phase 1-5 (local operations)
- This document captures the idea for future consideration
- Design may evolve significantly before implementation
- "Simple first, no frills" still applies
