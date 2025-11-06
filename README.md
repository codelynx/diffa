# Diffalla

A Swift library and command-line tool for comparing file systems and file system-like structures.

**Dual Interface:**
- **Swift Library:** Embed in macOS/iOS applications
- **CLI Tool:** `diffalla` command for macOS and Linux

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

**Dual interface:**
- Library/framework for app integration (no UI components)
- Command-line tool for standalone use (Phase 5)

**Future expansion:** File system-like subjects (FTP, AWS S3, etc.)

## Design Goals

- Simple, focused API
- Clear difference reporting
- Extensible for different comparison types
- Swift-native implementation

## Installation

### Homebrew (macOS)

```bash
# Add the tap
brew tap codelynx/tap

# Install diffalla
brew install diffalla
```

Or install directly without tap:
```bash
brew install codelynx/tap/diffalla
```

### Pre-built Binaries

Download the latest release for your platform:

**macOS (Universal: arm64 + x86_64):**
```bash
curl -fsSL https://github.com/codelynx/Diffalla/releases/latest/download/diffalla-0.10.0-macos.tar.gz | tar -xz
cd diffalla-0.10.0-macos
sudo ./install.sh
```

**Linux (x86_64):**
```bash
curl -fsSL https://github.com/codelynx/Diffalla/releases/latest/download/diffalla-0.10.0-linux.tar.gz | tar -xz
cd diffalla-0.10.0-linux
sudo ./install.sh
```

**Ubuntu Snap:**
```bash
snap install diffalla
```

### From Source

Build the CLI tool:

```bash
git clone https://github.com/codelynx/Diffalla.git
cd Diffalla
swift build -c release
```

The binary will be at `.build/release/diffalla`. Copy to your PATH:

```bash
cp .build/release/diffalla /usr/local/bin/
```

### Swift Package Manager (Library)

To use Diffalla as a library in your Swift project, add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/codelynx/Diffalla.git", from: "0.10.0")
]
```

## Documentation

📚 **[Getting Started Guide](GETTING_STARTED.md)** - Comprehensive user guide with practical examples, workflows, and troubleshooting

## CLI Quick Start

### Basic Commands

**Create a snapshot:**
```bash
diffalla snapshot /path/to/dir -o snapshot.db
```

**Compare two directories:**
```bash
diffalla compare /dir-a /dir-b
```

**Create and apply a patch:**
```bash
diffalla patch create /old /new -o update.patch
diffalla patch apply update.patch /target
```

**Synchronize directories:**
```bash
# Unidirectional (source → destination)
diffalla sync /source /destination

# Bidirectional (merge changes)
diffalla sync /dir-a /dir-b --bidirectional --conflict-resolution newest
```

**Verify directory integrity:**
```bash
diffalla verify /path/to/dir baseline.db
```

### Common Workflows

**Test Installer Impact:**
```bash
# Before install
diffalla snapshot /Applications -o before.db

# After install
diffalla snapshot /Applications -o after.db

# Compare
diffalla compare before.db after.db --show-diff
```

**Deployment with Rollback:**
```bash
# Create reversible patch
diffalla patch create /current /new -o deploy.patch --reversible

# Apply deployment
diffalla patch apply deploy.patch /production

# Rollback if needed
diffalla patch revert deploy.patch /production
```

**Integrity Monitoring:**
```bash
# Create baseline
diffalla snapshot /etc -o etc-baseline.db

# Verify periodically (e.g., via cron)
diffalla verify /etc etc-baseline.db || echo "Changes detected!"
```

### Documentation

- `man diffalla` - Main command overview
- `man diffalla-snapshot` - Snapshot creation
- `man diffalla-compare` - Directory comparison
- `man diffalla-patch` - Patch operations
- `man diffalla-sync` - Synchronization
- `man diffalla-export` - Export formats
- `man diffalla-verify` - Verification

See `docs/cli-design.md` for complete CLI specification.
