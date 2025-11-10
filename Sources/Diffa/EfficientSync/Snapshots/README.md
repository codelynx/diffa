# EfficientSync Snapshots

Snapshot creation and storage using SQLite.

## Contents

- `SnapshotSchema.swift` - SQLite schema definition
- `SQLiteSnapshot.swift` - SQLite-backed snapshot implementation
- `FileSystemScanner.swift` - Directory scanning (streaming)
- `FileHasher.swift` - MD5 hashing (streaming)

## Design

Snapshots are stored as SQLite databases with:

- **Flat structure:** No hierarchical parent_id relationships
- **Hash index:** Fast lookups by MD5 for move detection and deduplication
- **Streaming:** Files processed one-at-a-time for memory efficiency
- **Small footprint:** ~200 bytes per file in memory

## Performance Targets

- 10,000 files: <60s snapshot creation (HDD)
- Memory usage: <10 MB regardless of file count
- Database size: ~170 bytes per file on disk

## Reference

See `docs/phase6-breakdown.md` Steps 6-9 for implementation details.
