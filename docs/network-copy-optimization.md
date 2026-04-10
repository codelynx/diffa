# Network Sync: Hash-Based Copy Optimization

## Overview

Network sync (push/pull) avoids re-transferring files when the same content already exists on the destination. Both sides scan and hash files under the sync root, exchange path+hash metadata, and the client builds a hash index of destination content. For each file that needs to arrive at the destination, if the destination already has that content hash at some path, it copies locally instead of transferring over the network. The hash index is updated after each write so later duplicates within the same sync can also reuse local content. Deletes run last. Temporary artifacts are cleaned up on successful completion.

**Rule:** If a file needs transfer and the desired content hash already exists on the destination, copy locally instead of transferring.

## How It Works

### Sync Flow

```
1. Source scans and hashes all files under sync root
2. Destination scans and hashes all files under sync root
3. Both sides exchange metadata (path, size, hash, mtime) over network
4. Client builds destination hash index: { hash → path }
5. For each source file, in sorted path order:
   - Same hash at same path on destination → skip (no action)
   - Hash exists elsewhere on destination   → emit local copy
   - Hash not on destination                → emit network transfer
   - After each decision, record new path in hash index for later dedup
6. Append delete operations (destination paths not in source)
7. Resolve copy cycles with temp files (see below)
8. Execute: copies and transfers first, deletes last
9. Clean up temp files on successful completion
```

### Copy Cycle Resolution

When files swap or rotate content, copy operations form cycles. Executing them sequentially would corrupt data because a copy source gets overwritten before another copy reads it.

**Example — 2-way swap:**
```
Destination has: a.txt ("B"), b.txt ("A")
Source wants:    a.txt ("A"), b.txt ("B")

Copies needed: a.txt ← b.txt, b.txt ← a.txt  (cycle)
```

**Example — 3-way rotation:**
```
Destination has: a.txt ("A"), b.txt ("B"), c.txt ("C")
Source wants:    a.txt ("C"), b.txt ("A"), c.txt ("B")

Copies needed: a.txt ← c.txt, b.txt ← a.txt, c.txt ← b.txt  (cycle)
```

`resolveCopyCycles()` in `SyncClient.swift` detects cycles via graph traversal and breaks each one with a temp file:

1. Save one source to system temp directory (`.diffa_temp_<uuid>`)
2. Process remaining cycle copies forward — each source is untouched when read
3. Copy temp to first destination
4. Delete temp file

Temp files go to `FileManager.default.temporaryDirectory`, not the sync root.

### Protocol

Message type `COPY` added to `SyncMessageType` in `SyncProtocol.swift`:
- Payload: `<source_path>\t<dest_path>` (UTF-8)
- Server copies locally; no file data crosses the network
- Known limitation: tab/newline in filenames not supported (consistent with existing CSV metadata encoding)

### Path Validation

All server handlers validate client-supplied paths via `validatePath(_:)` in `SyncServer.swift`:
- Resolves symlinks before containment check
- Path-component-aware prefix match (`root.path + "/"`) prevents sibling-path false positives
- `resolvePath(_:)` routes `.diffa_temp_*` paths to system temp directory, delegates to `validatePath` for all others
- Client-side `validatePath(_:under:)` in `SyncClient.swift` protects local copy operations

### Scanner Exclusion

`FileSystemScanner.swift` excludes `.diffa_temp_*` files and `.diffa_staging` directories at the sync root only. Matches in subdirectories (e.g. `subdir/.diffa_temp_notes.txt`) are not excluded — those are real user files.

### Overwrite Semantics

`FileManager.copyItem` fails if the destination exists. Both server `copyFile` and client `copyLocal` remove the existing destination before copying. This matches the existing behavior where `Data.write(to:)` overwrites.

## Scenarios

| Scenario | Source | Destination | Transfers | Mechanism |
|----------|--------|-------------|-----------|-----------|
| Rename | `new.txt (E)` | `old.txt (E)` | 0 | Copy on destination, delete old |
| Swap | `a.txt (A), b.txt (B)` | `a.txt (B), b.txt (A)` | 0 | Copy via temp file |
| 3-way rotation | `a.txt (C), b.txt (A), c.txt (B)` | `a.txt (A), b.txt (B), c.txt (C)` | 0 | Copy via temp file |
| New duplicate | `a.txt (E), b.txt (E)` | _(empty)_ | 1 | Upload first, copy second |
| All paths differ | `a.txt (E), b.txt (E)` | `c.txt (E), d.txt (E)` | 0 | Both copy from existing |
| Overwrite + copy | `target.txt (E), source.txt (E)` | `target.txt (old), source.txt (E)` | 0 | Copy overwrites target |

## Cross-Platform

All APIs are available on macOS, Linux, and Windows:
- `resolvingSymlinksInPath()`, `.standardized` — Foundation
- `FileManager.copyItem`, `removeItem` — Foundation
- `FileManager.default.temporaryDirectory` — platform-appropriate (`/tmp` on Linux, `%TEMP%` on Windows)
- `UUID().uuidString` — Foundation

## Implementation

| File | What |
|------|------|
| `SyncProtocol.swift` | `COPY` message type |
| `SyncServer.swift` | `validatePath`, `resolvePath`, `copyFile` handler |
| `SyncClient.swift` | Hash index, `computeOperations`, `resolveCopyCycles`, `resolveLocalPath`, `validatePath` |
| `FileSystemScanner.swift` | Root-only exclusion of `.diffa_temp_*` and `.diffa_staging` |
| `NetworkSyncTests.swift` | Copy optimization tests (rename, duplicate, swap, 3-way rotation, all-paths-differ, overwrite, ordering) |
| `FileSystemScannerTests.swift` | 4 tests: exclusion at root, inclusion in subdirectories |

## Known Limitations

- Tab/newline in filenames not supported in COPY payload or CSV metadata encoding
- CSV unescape order: backslash+n in filenames may decode incorrectly (pre-existing)
- CSV silently skips malformed lines (pre-existing)
- Server COPY/FILE/DELETE failures are fire-and-forget — client is not notified (pre-existing, consistent across all mutating operations)
- Temp file leak if sync is interrupted mid-cycle (mitigated: files are in system temp directory, OS cleans up)

## Future: Content-Addressable Staging

The current cycle resolution uses graph traversal and per-cycle temp files. A simpler alternative would replace this with a content-addressable staging directory:

1. Before any overwrites, back up files whose content is needed elsewhere to `.diffa_staging/<session>/<hash>`
2. All copies read from staging (immutable) — no ordering constraints among copies, no cycle detection needed
3. Clean up staging directory after sync

Staging is session-scoped (UUID subdirectory) for concurrent session safety. Requires two new protocol messages (`STAGE`, `COPY_STAGED`) for push mode; pull mode needs no protocol changes. See git history of this file for the full staging design.
