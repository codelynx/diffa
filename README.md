# Diffa

A Swift library and command-line tool for comparing file systems and file system-like structures.

**Dual Interface:**
- **Swift Library:** Embed in macOS/iOS applications
- **CLI Tool:** `diffa` command for macOS and Linux

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

# Install diffa
brew install diffa
```

Or install directly without tap:
```bash
brew install codelynx/tap/diffa
```

### Pre-built Binaries

Download the latest release for your platform:

**macOS (Universal: arm64 + x86_64):**
```bash
curl -fsSL https://github.com/codelynx/Diffa/releases/latest/download/diffa-0.12.0-macos.tar.gz | tar -xz
cd diffa-0.12.0-macos
sudo ./install.sh
```

**Linux (x86_64):**
```bash
curl -fsSL https://github.com/codelynx/Diffa/releases/latest/download/diffa-0.12.0-linux.tar.gz | tar -xz
cd diffa-0.12.0-linux
sudo ./install.sh
```

**Ubuntu Snap:**
```bash
snap install diffa
```

### From Source

Build the CLI tool:

```bash
git clone https://github.com/codelynx/Diffa.git
cd Diffa
swift build -c release
```

The binary will be at `.build/release/diffa`. Copy to your PATH:

```bash
cp .build/release/diffa /usr/local/bin/
```

### Swift Package Manager (Library)

To use Diffa as a library in your Swift project, add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/codelynx/Diffa.git", from: "0.12.0")
]
```

## Documentation

📚 **[Getting Started Guide](GETTING_STARTED.md)** - CLI user guide with practical examples, workflows, and troubleshooting

🔧 **[Swift Programming Guide](SWIFT_PROGRAMMING_GUIDE.md)** - API guide for embedding Diffa in your Swift apps

## CLI Quick Start

### Basic Commands

**Create a snapshot:**
```bash
diffa snapshot /path/to/dir -o snapshot.diffa
```

**Compare two directories:**
```bash
diffa compare /dir-a /dir-b
```

**Create and apply a patch:**
```bash
diffa patch create /old /new -o update.patch
diffa patch apply update.patch /target
```

**Synchronize directories:**
```bash
# Unidirectional (source → destination)
diffa sync /source /destination

# Bidirectional (merge changes)
diffa sync /dir-a /dir-b --bidirectional --conflict-resolution newest
```

**Network sync (remote machines):**
```bash
# Start server on remote machine
diffa serve --path /path/to/sync --port 8080

# Push local files to remote server (creates mirror - deletes remote-only files)
diffa push /local/path host:port

# Pull remote files to local (creates mirror - deletes local-only files)
diffa pull /local/path host:port
```

**Verify directory integrity:**
```bash
diffa verify /path/to/dir baseline.diffa
```

### Common Workflows

**Test Installer Impact:**
```bash
# Before install
diffa snapshot /Applications -o before.diffa

# After install
diffa snapshot /Applications -o after.diffa

# Compare
diffa compare before.diffa after.diffa --show-diff
```

**Deployment with Rollback:**
```bash
# Create reversible patch
diffa patch create /current /new -o deploy.patch --reversible

# Apply deployment
diffa patch apply deploy.patch /production

# Rollback if needed
diffa patch revert deploy.patch /production
```

**Integrity Monitoring:**
```bash
# Create baseline
diffa snapshot /etc -o etc-baseline.diffa

# Verify periodically (e.g., via cron)
diffa verify /etc etc-baseline.diffa || echo "Changes detected!"
```

### Documentation

- `man diffa` - Main command overview
- `man diffa-snapshot` - Snapshot creation
- `man diffa-compare` - Directory comparison
- `man diffa-patch` - Patch operations
- `man diffa-sync` - Synchronization
- `man diffa-export` - Export formats
- `man diffa-verify` - Verification
- `diffa serve --help` - Network sync server
- `diffa push --help` - Push to remote
- `diffa pull --help` - Pull from remote

See `docs/cli-design.md` for complete CLI specification.
