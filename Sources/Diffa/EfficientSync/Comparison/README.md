# EfficientSync Comparison

Snapshot comparison and sync execution.

## Contents

- `SnapshotComparator.swift` - Snapshot comparison logic
- `MoveDetector.swift` - Deterministic move detection
- `SyncExecutor.swift` - Execute sync operations

## Design

### Comparison
- Mode-aware: push/pull/sync have different semantics
- Conflict detection: Sync mode generates conflict operations
- Complete metadata: Both local and remote file info stored

### Move Detection
- Deterministic pairing: Hash-based with sorted matching
- Zero-transfer: Moves require no content transfer

### Execution
- ContentTracker integration: Zero-copy deduplication
- Conflict resolution: newer-wins, ask, keep-both
- Safety: Path normalization, transaction support

## Performance Targets

- Comparison: <1s for 10,000 files
- Move detection: O(n log n) complexity
- Deduplication: Zero-copy for duplicate content

## Reference

See `docs/phase6-breakdown.md` Steps 10-13 for implementation details.
