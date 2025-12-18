# Open Questions

A consolidated list of open questions and design decisions to be made.

## Comparison Questions

### Hash Caching
**Question:** Should we cache computed hashes?

**Options:**
1. No caching - Always recompute (simple, always accurate)
2. In-memory caching - Cache during operation only
3. Persistent caching - Cache between runs (fastest)

**Considerations:**
- Persistent cache needs invalidation strategy
- Cache storage location and format
- Cache size limits

### Symlinks ✅ RESOLVED
**Question:** How to handle symbolic links?

**Decision (2025-11-05):** Follow symlinks by default, with `--no-follow-symlinks` flag to opt-out

**Rationale:**
- Matches user expectation (compare actual content)
- Consistent with common tools (rsync, cp -r)
- Circular symlink detection: Track visited paths
- Broken symlinks: Treat as missing file
- Cross-device symlinks: Follow naturally

**See:** `docs/decisions.md` for full details

### Hidden Files ✅ RESOLVED
**Question:** Should we include hidden files by default?

**Decision (2025-11-05):** Include all files by default, with `--no-hidden` flag to exclude

**Rationale:**
- Hidden files are legitimate data (configs, .git)
- Backup/sync tools should see everything by default
- Explicit exclusion is safer (no surprises)
- Platform: Files starting with `.` on Unix/macOS
- Ignore patterns (.diffaignore) deferred to Phase 5

**See:** `docs/decisions.md` for full details

### Ignore Patterns
**Question:** Should we support .gitignore-style patterns?

**Options:**
1. No filtering (compare everything)
2. Support ignore files (.diffaignore)
3. Programmatic filters only
4. Both ignore files and programmatic filters

**Considerations:**
- Pattern matching performance
- Which ignore file formats to support
- Ignore file location (root only, or per-directory)

### Comparison Depth
**Question:** Should we support shallow (non-recursive) comparison?

**Options:**
1. Always recursive
2. Optional depth parameter
3. Separate shallow comparison API

**Considerations:**
- Use cases for shallow comparison
- API complexity

### Metadata Comparison Level ✅ RESOLVED
**Question:** What metadata should be compared by default?

**Decision (2025-11-05):** Content + mtime + size + permissions (NO ownership by default)

**Default metadata:**
- SHA-256 hash (content)
- Modification time
- File size
- Permissions (chmod: 755, rwxr-xr-x)

**Opt-in with `--with-ownership`:**
- Owner (user)
- Group (group)

**Rationale:**
- Permissions matter for most use cases (executable, readable)
- Ownership useless for personal files across machines (different UIDs)
- Ownership requires sudo to restore (chown)
- System administrators can opt-in when needed

**See:** `docs/decisions.md` for full details
- Platform differences

## Patching Questions

### Content Storage
**Question:** Should patches include full file content or references?

**Options:**
1. Full content (self-contained patches)
2. References only (requires original files)
3. Hybrid (small files embedded, large files referenced)

**Considerations:**
- Patch file size
- Portability
- Use cases (local vs distributed)

### Compression
**Question:** Should patch content be compressed?

**Options:**
1. No compression (simple)
2. Always compress (smaller patches)
3. Compress large files only
4. Configurable compression

**Considerations:**
- Compression algorithm (gzip, bzip2, etc.)
- Compression time vs size tradeoff
- Decompression complexity

### Checksums
**Question:** Include checksums for verification?

**Options:**
1. No checksums (trust file system)
2. Optional checksums
3. Always include checksums
4. Signature-based verification

**Considerations:**
- Security requirements
- Performance impact
- Patch file size

### Partial Patches
**Question:** Support applying only part of a patch?

**Options:**
1. All-or-nothing application
2. Select operations to apply
3. Apply by path pattern

**Considerations:**
- Dependency between operations
- Use cases
- Complexity

### Patch Merging
**Question:** Can multiple patches be merged?

**Options:**
1. No merging (apply sequentially)
2. Automatic merge (when possible)
3. Manual merge tool

**Considerations:**
- Conflict detection
- Operation reordering
- Use cases

### Conflict Handling
**Question:** What if target was modified since patch creation?

**Options:**
1. Fail on conflict
2. Force apply (overwrite changes)
3. Three-way merge
4. Configurable conflict resolution

**Considerations:**
- Safety vs flexibility
- User needs
- Complexity

### Large Files
**Question:** How to handle very large files in patches?

**Options:**
1. Include full content (simple but large patches)
2. Block-level delta (complex but efficient)
3. External storage references
4. Streaming application

**Considerations:**
- File size threshold
- Memory constraints
- Performance

### Revert Data
**Question:** Always include data needed for revert, or optional?

**Options:**
1. Always include (patches are reversible)
2. Optional (smaller patches if revert not needed)
3. Separate forward and reverse patches

**Considerations:**
- Patch file size
- Use cases requiring revert
- Complexity

## Synchronization Questions

### Atomic Sync
**Question:** Should sync be atomic (all-or-nothing)?

**Options:**
1. Atomic (rollback on failure)
2. Best-effort (continue on errors)
3. Configurable

**Considerations:**
- Complexity of rollback
- Large sync performance
- User needs

### Incremental Sync
**Question:** Support resuming interrupted sync?

**Options:**
1. No resume (restart on failure)
2. Resume from checkpoint
3. Automatic resume with state tracking

**Considerations:**
- State storage
- Complexity
- Use cases (large syncs over unreliable networks)

### Dry Run
**Question:** Support dry-run mode to preview changes?

**Options:**
1. No dry run (live only)
2. Dry run mode (preview without changes)
3. Separate preview API

**Considerations:**
- User needs
- Implementation complexity
- API design

### Metadata Preservation
**Question:** Should sync preserve timestamps, permissions?

**Options:**
1. Content only
2. Content + timestamps
3. Content + all metadata
4. Configurable

**Considerations:**
- Platform compatibility
- User expectations
- Permission issues

### Sparse Files
**Question:** How to handle sparse files efficiently?

**Options:**
1. Treat as regular files
2. Detect and preserve sparse regions
3. Platform-specific handling

**Considerations:**
- Platform support
- Performance
- Storage efficiency

### Hard Links
**Question:** How to handle hard links?

**Options:**
1. Treat as separate files
2. Detect and preserve hard link structure
3. Ignore (copy as separate files)

**Considerations:**
- Detection algorithm
- Cross-platform support
- Use cases

### Extended Attributes
**Question:** Should we sync extended attributes?

**Options:**
1. Ignore extended attributes
2. Sync extended attributes
3. Configurable

**Considerations:**
- Platform-specific (macOS, Linux)
- Compatibility
- Use cases

### Concurrent Sync
**Question:** Allow concurrent sync operations?

**Options:**
1. Single sync at a time
2. Multiple syncs allowed
3. Same-folder locking only

**Considerations:**
- File system locking
- Corruption risks
- Performance

### Change Detection
**Question:** Use modification time, hash, or both?

**Options:**
1. Modification time only (fast but risky)
2. Hash only (slow but accurate)
3. Modification time + hash (balanced)
4. Configurable

**Considerations:**
- Performance vs accuracy
- File system timestamp reliability
- User needs

### Conflict Resolution Priority
**Question:** Default conflict resolution for bidirectional sync?

**Options:**
1. Newest wins (based on timestamp)
2. Largest wins (based on size)
3. Error on conflict (safe but manual)
4. Always ask user

**Considerations:**
- User expectations
- Automation needs
- Safety

## Optimization Questions

### Move Detection Accuracy
**Question:** How to handle hash collisions?

**Options:**
1. Assume collision impossible (risky)
2. Compare file content byte-by-byte (safe)
3. Use multiple hash algorithms
4. Configurable verification level

**Considerations:**
- SHA-256 collision probability (extremely low)
- Performance impact
- Paranoia level

### Hash Cache Persistence
**Question:** Store cache between runs? Where?

**Options:**
1. No persistence (session only)
2. Per-directory cache file (.diffa-cache)
3. Central cache database
4. User-specified location

**Considerations:**
- Cache file location and naming
- Cache cleanup
- Security (cache poisoning)

### Parallel Operation Limits
**Question:** How many concurrent operations is optimal?

**Options:**
1. Number of CPU cores
2. Fixed number (e.g., 4)
3. Dynamic based on system load
4. User-configurable

**Considerations:**
- I/O vs CPU bound operations
- System resource contention
- Disk type (SSD vs HDD)

### Block Size for Delta Sync
**Question:** What block size for block-level delta sync?

**Options:**
1. Fixed size (e.g., 4KB, 64KB)
2. Variable size based on file size
3. Configurable
4. Match file system block size

**Considerations:**
- Performance vs overhead
- Network transfer efficiency
- Memory usage

### Deduplication Strategy
**Question:** How to handle duplicate files?

**Options:**
1. No deduplication (copy all)
2. Hard links (same inode)
3. Copy-on-write (APFS clones)
4. Reference counting

**Considerations:**
- File system support
- Cross-platform compatibility
- User expectations

### Cache Invalidation
**Question:** When to invalidate hash cache?

**Options:**
1. Modification time change
2. Size change
3. Inode change
4. Manual invalidation
5. All of the above

**Considerations:**
- Reliability
- Performance
- Edge cases

### Optimization Defaults
**Question:** What optimizations should be on by default?

**Options:**
1. All optimizations on
2. Conservative (only safe optimizations)
3. Aggressive (maximum performance)
4. User profiles (safe, balanced, fast)

**Considerations:**
- Safety vs performance
- User expectations
- Complexity

### Platform-specific Optimizations
**Question:** Use platform-specific optimizations?

**Options:**
1. Generic implementation only
2. Platform-specific when available
3. Feature detection at runtime

**Examples:**
- APFS file cloning (macOS)
- Copy-on-write (Linux btrfs, ZFS)
- Reflinks (Linux XFS)

**Considerations:**
- Maintenance complexity
- Performance gains
- Fallback implementation

### Network Drive Detection
**Question:** Detect network drives and adjust strategy?

**Options:**
1. Treat all drives the same
2. Detect and optimize for network drives
3. User-specified drive type

**Optimizations for network:**
- Minimize round trips
- Batch operations
- Skip hash computation for quick sync

**Considerations:**
- Detection reliability
- Configuration complexity
- Performance impact

### Verification Level
**Question:** How much verification is enough?

**Options:**
1. Minimal (trust timestamps)
2. Moderate (hash when uncertain)
3. Paranoid (always hash and verify)
4. Configurable levels

**Considerations:**
- Performance vs safety
- Use cases (backup vs development)
- User trust level

## Snapshot Questions

### Metadata Level
**Question:** What metadata to include in snapshots?

**Options:**
1. Minimal (modification time only)
2. Standard (mod time, size, permissions)
3. Complete (all available metadata)
4. Configurable

**Considerations:**
- Snapshot file size
- Comparison granularity
- Platform differences

### Compression
**Question:** Should snapshots be compressed?

**Options:**
1. No compression (fast, human-readable JSON)
2. Always compress (smaller files)
3. Compress large snapshots only
4. User-configurable

**Considerations:**
- File size reduction
- Load/save performance
- Human readability

### Incremental Snapshots
**Question:** Support delta/incremental snapshots?

**Options:**
1. Full snapshots only
2. Delta snapshots (only changes since previous)
3. Both full and delta

**Considerations:**
- Storage efficiency for frequent snapshots
- Complexity of implementation
- Delta chain length

### Snapshot Verification
**Question:** Include checksum of snapshot itself?

**Options:**
1. No verification (trust file system)
2. Include snapshot checksum
3. Cryptographic signature

**Considerations:**
- Tamper detection
- Security requirements
- Complexity

### Filtering
**Question:** Support include/exclude patterns in snapshots?

**Options:**
1. No filtering (capture everything)
2. .gitignore-style patterns
3. Programmatic filters
4. Both patterns and filters

**Considerations:**
- Use cases for partial snapshots
- Pattern matching performance
- API complexity

### Comparison Options
**Question:** What comparison modes to support?

**Options:**
1. Full comparison (structure + hashes + metadata)
2. Structure only (paths, ignore content)
3. Hashes only (ignore metadata)
4. Configurable comparison levels

**Considerations:**
- Different verification needs
- Performance vs accuracy
- API complexity

### Serialization Format
**Question:** JSON, binary, or both?

**Options:**
1. JSON only (human-readable)
2. Binary only (compact)
3. Both with format detection
4. User-specified format

**Considerations:**
- File size
- Human readability
- Parse performance

### Snapshot Signing
**Question:** Cryptographically sign snapshots?

**Options:**
1. No signing (trust file system)
2. Optional signing
3. Always sign

**Considerations:**
- Security requirements
- Key management
- Verification process

## General Questions

### API Design Philosophy
**Question:** Should API be flexible or opinionated?

**Options:**
1. Flexible (many options, complex)
2. Opinionated (sane defaults, simple)
3. Balanced (simple defaults, expert options)

**Considerations:**
- Beginner vs expert users
- Common use cases
- Maintenance burden

### Error Handling Strategy
**Question:** How aggressively to handle errors?

**Options:**
1. Fail fast (throw on first error)
2. Collect errors (continue, report at end)
3. Configurable error handling

**Considerations:**
- User expectations
- Data safety
- Debugging experience

### Logging and Debugging
**Question:** Built-in logging support?

**Options:**
1. No logging (user handles)
2. Optional logging via closure
3. Structured logging (OSLog, etc.)
4. Multiple logging levels

**Considerations:**
- Debugging needs
- Performance impact
- Privacy (don't log sensitive paths)

### Backwards Compatibility
**Question:** How to handle future API changes?

**Options:**
1. Semantic versioning
2. Deprecation warnings
3. Multiple API versions

**Considerations:**
- Breaking changes policy
- Migration path
- Documentation
