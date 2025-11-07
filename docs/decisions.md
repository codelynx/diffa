# Design Decisions

**Date:** 2025-11-05
**Status:** Phase 1 critical questions resolved

This document records key design decisions made during development.

---

## Phase 1 Critical Decisions

### Decision 1: Symlink Handling

**Date:** 2025-11-05
**Status:** ✅ Decided

**Question:** How should Diffa handle symbolic links?

**Decision:** Follow symlinks by default, with opt-out flag

**Implementation:**
- Default behavior: Follow symlinks (compare target content)
- CLI flag: `--no-follow-symlinks` to store as-is
- Library API: `followSymlinks: Bool = true` parameter

**Rationale:**
- Matches user expectation (compare actual content)
- Consistent with common tools (rsync, cp -r)
- Safer default (users see what's really there)
- Circular symlink detection required

**Edge cases to handle:**
- Circular symlinks: Track visited paths, break cycles
- Broken symlinks: Treat as missing file
- Cross-device symlinks: Follow naturally (just read target)

**Alternative considered:** Store symlink as-is (rejected - less intuitive)

---

### Decision 2: Hidden Files

**Date:** 2025-11-05
**Status:** ✅ Decided

**Question:** Should hidden files be included by default?

**Decision:** Include all files by default, with opt-out flag

**Implementation:**
- Default behavior: Include hidden files (starting with `.`)
- CLI flag: `--no-hidden` to exclude
- Library API: `includeHidden: Bool = true` parameter

**Rationale:**
- Hidden files are legitimate data (configs, caches, .git)
- Backup/sync tools should see everything by default
- Explicit exclusion is safer than implicit (no surprises)
- Ignore patterns (.diffaignore) deferred to Phase 5

**Platform detection:**
- Unix/macOS: Files starting with `.` prefix
- Easy to implement: Check `path.lastPathComponent.hasPrefix(".")`

**Alternative considered:** Exclude by default (rejected - too many surprises)

---

### Decision 3: Metadata Comparison Level

**Date:** 2025-11-05
**Status:** ✅ Decided

**Question:** What metadata should be captured and compared?

**Decision:** Content + mtime + size + permissions (NO ownership by default)

**Default Metadata (Phase 1):**
```swift
struct Metadata: Equatable {
    let modificationDate: Date          // ✅ Always captured
    let size: Int64                     // ✅ Always captured
    let permissions: FilePermissions    // ✅ Always captured (chmod: 755)
    let owner: String?                  // ❌ Opt-in only (--with-ownership)
    let group: String?                  // ❌ Opt-in only (--with-ownership)
}
```

**Implementation:**
- Default: SHA-256 hash + mtime + size + permissions
- CLI flag: `--with-ownership` to add owner/group
- Library API: `captureOwnership: Bool = false` parameter

**Rationale:**
- Permissions (chmod) matter for most use cases (executable, readable)
- Ownership is useless for personal files across machines (different UIDs)
- Ownership requires sudo to restore (chown needs elevated privileges)
- System administrators can opt-in when needed

**Storage impact:**
- Without ownership: ~5 bytes per file (permissions only)
- With ownership: ~35 bytes per file (+owner +group strings)
- Difference: ~300 KB for 10,000 files (minimal)

**Use cases:**
- Personal files across machines: Ownership useless ✅
- Build verification: Ownership irrelevant ✅
- System administration: Ownership needed (opt-in with flag) ✅

**Metadata levels (future):**
- `minimal`: hash + mtime + size + permissions (default)
- `standard`: + owner + group (opt-in)
- `full`: + extended attributes (Phase 5)

**Alternative considered:** Include ownership by default (rejected - requires sudo, useless for most users)

---

## Decision Summary

| Question | Decision | CLI Flag | Default |
|----------|----------|----------|---------|
| **Symlinks** | Follow by default | `--no-follow-symlinks` | Follow |
| **Hidden files** | Include by default | `--no-hidden` | Include |
| **Metadata** | Content + mtime + size + permissions | `--with-ownership` | No ownership |

---

## Implementation Impact

### Phase 1 (Foundation)

**Snapshot creation:**
```swift
struct SnapshotOptions {
    var followSymlinks: Bool = true
    var includeHidden: Bool = true
    var captureOwnership: Bool = false
}

func createSnapshot(
    from directory: URL,
    options: SnapshotOptions = .init()
) async throws -> Snapshot
```

**CLI commands:**
```bash
# Defaults (most common)
diffa snapshot /path -o snap.diffa

# Store symlinks as-is
diffa snapshot /path -o snap.diffa --no-follow-symlinks

# Exclude hidden files
diffa snapshot /path -o snap.diffa --no-hidden

# System admin: capture ownership
sudo diffa snapshot /etc -o snap.diffa --with-ownership
```

### SQLite Schema

**Metadata table:**
```sql
CREATE TABLE items (
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL,
    sha256 TEXT,
    size INTEGER NOT NULL,
    modification_date TEXT NOT NULL,
    permissions TEXT NOT NULL,        -- "755" or "rwxr-xr-x"
    owner TEXT,                       -- NULL unless --with-ownership
    group_name TEXT                   -- NULL unless --with-ownership
);
```

### Comparison logic

**Default comparison:**
```swift
func compare(source: Snapshot, destination: Snapshot) -> Difference {
    // Compare: hash, size, mtime, permissions
    // Ignore: owner, group (if NULL)
}
```

**With ownership:**
```swift
// Only when both snapshots have ownership data
// Compare: hash, size, mtime, permissions, owner, group
```

---

## Future Considerations

### Phase 5 Enhancements

**Extended metadata levels:**
```bash
diffa snapshot /path --metadata full
# Captures: + extended attributes + ACLs + creation time
```

**Ignore patterns:**
```bash
diffa snapshot /path --ignore .diffaignore
# Respect .gitignore-style patterns
```

**Watch mode:**
```bash
diffa watch /path --baseline snap.diffa
# Alert on any changes
```

---

## Questions Resolved

These decisions resolve the following open questions:

1. ✅ `docs/open-questions.md:20-33` - Symlink handling
2. ✅ `docs/open-questions.md:34-46` - Hidden files
3. ✅ `docs/open-questions.md:73-85` - Metadata comparison level

**Phase 1 is now unblocked** - all critical design questions resolved.

---

**Document Status:** Complete - Phase 1 decisions finalized
**Last Updated:** 2025-11-05
**Next Steps:** Begin Phase 1 implementation
