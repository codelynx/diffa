# Remote Sync Metadata & Protocol Hardening Plan

**Status:** Proposal  
**Author:** Codex (GPT-5)  
**Date:** 2025-11-07  
**Scope:** Address metadata alignment, security, and blob-transfer gaps in `docs/remote-sync-proposal.md`

---

## 1. Metadata Capability Negotiation

### Problem
Peers can capture different metadata levels (mtime/size/permissions vs. ownership vs. future extended attributes). Without negotiation the protocol will:
- Mark identical files as modified because required metadata is missing.
- Strip ownership/permissions silently when syncing between heterogeneous peers.

### Proposal
1. **Define metadata tiers** (reuse Decision 3 terminology):
   - `minimal`: hash + size + mtime + mode.
   - `standard`: minimal + owner/group.
   - `full`: standard + extended attributes (future).
2. **Handshake extension**:
   - `HELLO` includes `supported_metadata_levels=[minimal,standard]`, `default_metadata_level=standard`.
   - `CAPABILITIES` response echoes server support and declares `active_metadata_level`.
3. **Policy**:
   - Client and server must agree on a single active level per session (choose lowest common denominator unless client overrides with `--require-metadata-level`).
   - If no overlap exists, abort with actionable error.
4. **Snapshot metadata**:
   - Store capture level in snapshot header (`metadata.capture_level`), add migration note to schema doc.
   - During comparison, if snapshots differ in capture level, warn and treat absent fields as `nil` rather than “changed.”

### Deliverables
- Protocol section update documenting fields and negotiation rules.
- Snapshot schema migration + tests ensuring capture level persists.
- CLI flag `--metadata-level {minimal|standard|full}` for `serve` and `sync`.

---

## 2. CLI Surfacing & Auto-Detection

### Problem
Examples run `diffa serve`/`diffa sync` with defaults, so users may mix capture settings inadvertently.

### Proposal
1. `diffa serve` advertises its capture level in logs and refuses downgrade unless `--allow-metadata-downgrade`.
2. `diffa sync` inspects remote metadata level before scanning local tree; if mismatch, it reuses the remote level for local snapshot to keep comparisons stable (unless user forces level).
3. Documentation updates in CLI design + proposal examples showing `--metadata-level standard`.

---

## 3. Metadata-Carrying Blob Format

### Problem
Content-addressable transfer currently only describes raw file bytes; metadata does not travel with blobs, leaving chmod/mtime restoration undefined.

### Proposal
1. **Blob manifest**:
   - Introduce `FILE_REQUEST`/`FILE_RESPONSE` messages that carry `{hash, size, chunking, metadata}`.
   - Metadata payload encoded as JSON/CBOR chunk referencing the negotiated level; content bytes remain separate stream to preserve zero-copy IO.
2. **Caching**:
   - Hash cache entry includes metadata hash so cached files can skip re-downloading metadata when only timestamps change.
3. **Resumable transfers**:
   - Session IDs and chunk IDs persist on both sides; metadata is replayed only once per file, but server keeps it available until chunks are fully acked.
4. **Storage**:
   - CAS on disk stores sidecar `hash.meta` files (small) alongside `hash.blob`.

---

## 4. Cloud Adapter Metadata Strategy

### Problem
Object stores lack POSIX semantics, yet Phase 6c relies on them.

### Proposal
1. **Snapshot-first**: Cloud adapters expose snapshots generated on machines that understand POSIX metadata. For purely cloud-native data, define default metadata (e.g., 0644, owner `diffa`) and include it explicitly.
2. **Metadata objects**:
   - Each blob upload writes two objects:
     - `blobs/<hash>`: raw bytes.
     - `blobs/<hash>.meta`: JSON with metadata level + fields.
3. **Consistency**:
   - Upload snapshot manifest last; manifest references exact blob versions (`ETag`/`generation`). Clients refuse to use manifest if referenced objects are missing.
4. **Restores**:
   - `diffa sync s3://...` reads `.meta` for every blob to restore permissions, falling back to defaults only if `.meta` absent (warn user).
5. **Docs**: Update cloud section describing metadata storage, IAM requirements for dual object writes, and eventual consistency considerations.

---

## 5. Security & Phase Criteria

### Problem
Phase 6a currently omits authentication/TLS and has no acceptance criteria for metadata fidelity.

### Proposal
1. **Security gating**:
   - Require API-key auth and TLS (self-signed allowed) in 6a; LAN-only assumption is unsafe.
   - Handshake now includes `auth_scheme` and `tls_mode` negotiation.
2. **Exit tests**:
   - 6a: Round-trip sync of 10k files preserves permissions + mtime; automated integration test compares pre/post metadata.
   - 6b: Add owner/group verification when `--metadata-level standard`.
   - 6c: Cloud adapter test writes files with varied modes, restores locally, and diff-checks metadata.

---

## 6. Implementation Order

1. Snapshot schema & CLI flags (shared foundation).
2. Protocol handshake update + metadata negotiation tests.
3. **Owner/permission fallback rules** (see `docs/cross-platform-metadata.md`):
   - Try username → Try UID → Keep current → Skip (FAT32)
   - Document synthetic owners ("diffa" for cloud-native files)
   - Add CLI mapping file support (optional: `~/.diffa/uid-mappings.json`)
4. Blob format change with metadata sidecars + resumable semantics.
5. Server/client enforcement of metadata levels, including log warnings.
6. Cloud adapter metadata plan + documentation.
7. Phase exit criteria and security requirements adjustments.
8. **Cross-platform integration tests:**
   - APFS ↔ FAT32 (round-trip, hash-based identity verification)
   - POSIX ↔ SMB (ownership mapping)
   - Cloud ↔ POSIX (synthetic owners, best-effort restore)

Each stage should land with unit/integration coverage so metadata regressions are caught early.

---

## 7. User-Facing Documentation

Add to CLI docs (before Phase 6a release):

**Synthetic Owners/Modes:**
```
When syncing to filesystems without POSIX ownership (FAT32, ExFAT, cloud):
  - Owner/group: "diffa" / "diffa" (synthetic)
  - Mode: Read-only flag preserved (0o444 vs 0o644)
  - Original metadata stored in snapshot for round-trip

Override with: --synthetic-owner=myname --synthetic-group=mygroup
```

**Metadata Levels:**
```
minimal:  hash + size + mtime (works on all filesystems)
standard: minimal + mode + owner/group (POSIX filesystems)
full:     standard + xattr (future, platform-specific)

Use --metadata-level=minimal for FAT32/ExFAT destinations.
```

**Timestamp Handling:**
```
Timestamps stored at second-level precision (Unix epoch seconds).
Sub-second precision is discarded during capture.
File identity determined by hash + size, not timestamps.
```

---

## References
- `docs/remote-sync-proposal.md`
- `docs/cross-platform-metadata.md` (detailed implementation guide)
- `docs/decisions.md` (Decision 3 – Metadata)
- `Sources/Diffa/Core/Metadata.swift`
- `Sources/Diffa/Core/FileSystemItem.swift`
- `docs/architecture.md`, `docs/phase3-breakdown.md`
