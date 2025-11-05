# Diffalla

A Swift package for comparing file systems and file system-like structures.

## Objectives

### 1. Find Differences Between Two Folders
Identify what files and folders differ between two locations.

**Use case:** Test installers - check what was installed, what was removed

### 2. Create Patches
Generate patches that describe how to transform folder A to B (or B to A).

**Use case:** Create deployment packages, backup deltas

### 3. Apply and Revert Patches
Apply patches to transform folders or revert changes.

**Use case:** Install/uninstall, deploy/rollback

### 4. Synchronize Folders
- Bidirectional sync: Make A and B identical
- Unidirectional sync: Sync A over B (overwrite B with A's contents)

**Use case:** Backup synchronization, deployment

### 5. Optimize Synchronization
Minimize file operations - use moves instead of copy+delete where possible.

**Use case:** Efficient large-scale synchronization with minimal I/O

### 6. Snapshots (Verification)
Create lightweight snapshots capturing directory structure, hashes, and metadata (no content).

**Use case:** Integrity monitoring, build verification, change detection

- Snapshot directory state without storing content
- Compare snapshot to directory programmatically
- Detect changes since known good state
- No revert or apply - observation only

## Scope

**Initial focus:** Local file system on Apple platforms (macOS, iOS)

**No UI:** Library/framework only - no user interface components

**Future expansion:** File system-like subjects (FTP, AWS S3, etc.)

## Design Goals

- Simple, focused API
- Clear difference reporting
- Extensible for different comparison types
- Swift-native implementation
