# EfficientSync Core

Core types and protocols for efficient directory synchronization.

## Contents

- `FileItem.swift` - File metadata representation
- `Snapshot.swift` - Snapshot protocol
- `SyncMode.swift` - Sync mode enumeration (push/pull/sync)
- `FileOperation.swift` - Sync operation representation
- `ContentTracker.swift` - Content deduplication tracker

## Design

This module contains the fundamental types used throughout EfficientSync. All types are designed for:

- **Memory efficiency:** Minimal overhead per file
- **Content-addressable storage:** Files identified by MD5+size
- **Safety:** Path normalization, deterministic behavior
- **Testability:** Clear interfaces, value semantics

## Reference

See `docs/phase6-breakdown.md` for implementation details.
