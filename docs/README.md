# Diffa Documentation

Detailed design documentation for the Diffa library.

## Overview

Diffa is a Swift library for file system comparison, patching, and synchronization on Apple platforms.

**Scope:** Library/framework only - no UI components

## Documentation Index

### [architecture.md](architecture.md)
Core types, protocols, and overall system architecture.

**Contents:**
- ItemProtocol and core types
- Diffa namespace structure
- Module organization
- Error handling
- Threading model
- Platform considerations

**Read this first** to understand the overall structure.

### [comparison.md](comparison.md)
**Objective 1:** Find differences between two folders

**Contents:**
- Comparison algorithm
- What to compare (structure, content, metadata)
- Output format (Difference object)
- Performance considerations
- Use cases: installer testing, backup verification

### [patching.md](patching.md)
**Objectives 2 & 3:** Create patches and apply/revert them

**Contents:**
- Patch structure and operations
- Creating patches from differences
- Applying patches forward
- Reverting patches
- Patch serialization formats
- Use cases: deployment packages, install/uninstall

### [synchronization.md](synchronization.md)
**Objective 4:** Synchronize folders

**Contents:**
- Unidirectional sync (A → B)
- Bidirectional sync (A ↔ B)
- Conflict resolution strategies
- Progress reporting
- Sync results
- Use cases: backup synchronization, deployment

### [optimization.md](optimization.md)
**Objective 5:** Optimize synchronization efficiency

**Contents:**
- Move detection (avoid copy+delete)
- Copy avoidance strategies
- Incremental hashing
- Smart file comparison
- Parallel processing
- Block-level delta sync
- Deduplication
- Performance metrics

### [snapshots.md](snapshots.md)
**Feature:** Lightweight directory state snapshots

**Contents:**
- Snapshot creation (structure, hashes, metadata)
- Comparison to directories
- Change detection
- Verification use cases
- No revert/apply - observation only

## Operation Reviews

Detailed step-by-step reviews of core operations before implementation.

### [operation-review-snapshot.md](operation-review-snapshot.md)
**Review:** Snapshot creation operation

**Contents:**
- Step-by-step snapshot creation process
- SQLite schema and implementation
- Memory management and streaming
- Performance characteristics
- Implementation pseudocode

### [operation-review-difference.md](operation-review-difference.md)
**Review:** Snapshot-based comparison operation

**Contents:**
- Lightweight Difference structure (~400 bytes)
- SQL-powered comparison using ATTACH DATABASE
- Lazy evaluation with caching
- Snapshot reuse benefits
- Memory efficiency (40x savings)
- Implementation pseudocode

### [operation-review-patching.md](operation-review-patching.md)
**Review:** Patch creation, apply, and revert operations

**Contents:**
- Patch creation from Difference
- RevertData with hybrid storage (inline/cache)
- Apply operation (forward transformation)
- Revert operation (rollback)
- Move detection optimization
- Serialization formats
- Implementation pseudocode

### [operation-review-synchronization.md](operation-review-synchronization.md)
**Review:** Folder synchronization operations

**Contents:**
- Unidirectional sync (A → B)
- Bidirectional sync (A ↔ B)
- Conflict detection and resolution
- Multiple resolution strategies (.newest, .sourceWins, etc.)
- Move detection integration
- Progress reporting
- Implementation pseudocode

### [operation-review-optimization.md](operation-review-optimization.md)
**Review:** Performance optimization techniques

**Contents:**
- Move detection (100x speedup)
- Hash caching (incremental operations)
- Parallel processing (multi-core utilization)
- Smart comparison (early exit strategies)
- Block-level delta sync (future)
- Deduplication (future)
- Performance metrics and priorities

### [open-questions.md](open-questions.md)
Consolidated list of design decisions to be made.

**Categories:**
- Comparison questions
- Patching questions
- Synchronization questions
- Optimization questions
- General questions

**Use this** to track unresolved design decisions.

### [implementation-readiness.md](implementation-readiness.md)
**Design Phase Summary**

**Contents:**
- Design documentation completion status
- Key architectural decisions summary
- Performance targets and expectations
- Implementation priorities (Phases 1-5)
- Code structure and module organization
- Next steps for implementation
- Design review summary

**Read this** to understand overall design status and implementation roadmap.

## Reading Path

### For Understanding the Library
1. Start with `architecture.md` - understand the types and structure
2. Read `comparison.md` - the foundation operation
3. Continue to `patching.md` and `synchronization.md` as needed
4. Read `optimization.md` for performance details

### For Implementation Planning
1. **Start with `implementation-readiness.md`** - overall status and roadmap
2. Review `architecture.md` - understand what to build
3. Read operation review docs for detailed implementation guidance
4. Check `open-questions.md` - resolve remaining design decisions
5. Refer back to architecture for type definitions

### For Design Discussions
1. Use `open-questions.md` as agenda
2. Reference specific objective docs for context
3. Update docs with decisions made

## Document Status

All documents represent the **design phase** ("what" not "how").

**Design phase:** ✅ Complete
**Operation reviews:** ✅ Complete (5 operations reviewed)
**Implementation readiness:** ✅ Ready

**Next step:** Begin Phase 1 implementation (Foundation/MVP)

## Related Files

- `/DESIGN.md` - High-level design document (overview)
- `/README.md` - Project README (objectives and scope)
- `/.swiftformat` - Code formatting configuration
