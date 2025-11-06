# Distribution Scripts

This directory contains scripts for building, packaging, and distributing Diffalla.

## Scripts

### build-release.sh

Builds optimized release binaries for distribution.

**Features:**
- Builds universal macOS binary (arm64 + x86_64)
- Builds Linux x86_64 binary
- Strips debug symbols
- Creates distribution tarball with:
  - Binary
  - Man pages
  - Documentation
  - Example scripts
  - Installation script
- Generates SHA256 checksums

**Usage:**
```bash
# Build with auto-detected version (from git tags)
./Scripts/build-release.sh

# Build with specific version
./Scripts/build-release.sh 1.0.0
```

**Output:**
- `dist/diffalla-VERSION-PLATFORM.tar.gz` - Distribution tarball
- `dist/diffalla-VERSION-PLATFORM.tar.gz.sha256` - Checksum file

**Requirements:**
- macOS: Xcode with Swift 5.9+
- Linux: Swift 5.9+, libsqlite3-dev, bc

---

### install.sh

Universal installation script supporting both source and binary installs.

**Features:**
- Installs from source (if in repo directory)
- Downloads and installs pre-built binary
- Supports custom installation prefix
- Installs binary, man pages, and documentation

**Usage:**
```bash
# Install from source (in repo directory)
./Scripts/install.sh

# Install to custom location
PREFIX=$HOME/.local ./Scripts/install.sh

# One-line remote install (future)
curl -fsSL https://raw.githubusercontent.com/yourusername/Diffalla/main/Scripts/install.sh | bash
```

**Environment Variables:**
- `PREFIX` - Installation prefix (default: `/usr/local`)
- `VERSION` - Version to install (default: `latest`)
- `REPO` - GitHub repository (default: `codelynx/Diffalla`)

---

## GitHub Actions Workflows

### CI Workflow (.github/workflows/ci.yml)

Runs on every push and pull request:
- Tests on macOS and Linux
- Integration tests
- CLI installation test
- SwiftLint (optional)

**Triggers:**
- Push to `main` branch
- Pull requests to `main` branch

---

### Release Workflow (.github/workflows/release.yml)

Automated release process:
1. Builds macOS and Linux binaries
2. Runs all tests
3. Creates GitHub release
4. Uploads distribution tarballs and checksums
5. Generates release notes
6. Updates Homebrew formula

**Triggers:**
- Git tags matching `v*.*.*` (e.g., `v1.0.0`)
- Manual dispatch with version input

**Creating a Release:**
```bash
# Tag a release
git tag -a v1.0.0 -m "Release version 1.0.0"
git push origin v1.0.0

# GitHub Actions will automatically:
# - Build for macOS and Linux
# - Run all tests
# - Create GitHub release
# - Upload distribution packages
```

---

## Homebrew Distribution

### Formula

The Homebrew formula is in `Formula/diffalla.rb`.

**Local Testing:**
```bash
# Install from local formula
brew install --formula Formula/diffalla.rb

# Test the formula
brew test diffalla

# Audit the formula
brew audit --new-formula diffalla
```

**Creating a Tap:**
```bash
# Create tap repository
gh repo create homebrew-tap --public

# Add formula
cp Formula/diffalla.rb homebrew-tap/diffalla.rb
cd homebrew-tap
git add diffalla.rb
git commit -m "Add diffalla formula"
git push
```

**Installing from Tap:**
```bash
brew tap codelynx/tap
brew install diffalla
```

---

## Release Checklist

Before creating a release:

1. **Update Version Numbers:**
   - [ ] `Package.swift` (if applicable)
   - [ ] `Sources/DiffallaCLI/main.swift` (version in CLI)
   - [ ] `CHANGELOG.md` (document changes)

2. **Run Tests:**
   ```bash
   swift test
   swift test --filter CLIIntegrationTests
   ```

3. **Build and Test Release:**
   ```bash
   ./Scripts/build-release.sh X.Y.Z
   cd dist
   tar -xzf diffalla-X.Y.Z-macos.tar.gz
   cd diffalla-X.Y.Z-macos
   ./install.sh
   diffalla --version
   ```

4. **Create Git Tag:**
   ```bash
   git tag -a vX.Y.Z -m "Release version X.Y.Z"
   git push origin vX.Y.Z
   ```

5. **Wait for GitHub Actions:**
   - Monitor workflow at: https://github.com/yourusername/Diffalla/actions
   - Verify release created: https://github.com/yourusername/Diffalla/releases

6. **Update Homebrew Tap** (if not automated):
   ```bash
   # Calculate new SHA256
   shasum -a 256 dist/diffalla-X.Y.Z-macos.tar.gz

   # Update Formula/diffalla.rb:
   # - url: new version
   # - sha256: new checksum

   # Push to tap
   cd homebrew-tap
   git add diffalla.rb
   git commit -m "Update diffalla to X.Y.Z"
   git push
   ```

7. **Announce Release:**
   - [ ] Update README.md with new version
   - [ ] Post release notes
   - [ ] Update documentation

---

## Platform Support

### macOS
- **Minimum:** macOS 13.0 (Ventura)
- **Architectures:** arm64 (Apple Silicon), x86_64 (Intel)
- **Build:** Universal binary (both architectures in one)

### Linux
- **Distributions:** Ubuntu, Debian, Fedora, etc.
- **Architecture:** x86_64
- **Dependencies:** libsqlite3

### iOS (Library Only)
- **Minimum:** iOS 16.0
- **Architectures:** arm64
- **Note:** CLI tool not available on iOS

---

## Troubleshooting

### Build Fails on macOS
```bash
# Ensure Xcode Command Line Tools installed
xcode-select --install

# Verify Swift version
swift --version  # Should be 5.9 or later
```

### Build Fails on Linux
```bash
# Install required dependencies
sudo apt-get install libsqlite3-dev

# Or on Fedora/RHEL
sudo dnf install sqlite-devel
```

### Tests Fail
```bash
# Clean build
rm -rf .build
swift build

# Run specific test
swift test --filter TestName
```

### Installation Fails
```bash
# Check permissions
ls -la /usr/local/bin

# Install to user directory instead
PREFIX=$HOME/.local ./Scripts/install.sh
export PATH="$HOME/.local/bin:$PATH"
```

---

## CI/CD Pipeline

```
┌─────────────────┐
│  Push to main   │
│   or PR         │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Run CI tests  │
│  (macOS, Linux) │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Create git tag │
│   (vX.Y.Z)      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Build releases  │
│ (macOS, Linux)  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Create GitHub   │
│   release       │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Update Homebrew │
│    formula      │
└─────────────────┘
```

---

## Additional Resources

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Homebrew Formula Cookbook](https://docs.brew.sh/Formula-Cookbook)
- [Swift Package Manager](https://swift.org/package-manager/)
