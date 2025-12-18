# Distribution Guide for Diffa

This guide covers how to distribute Diffa across different platforms and package managers.

## Table of Contents
- [Overview](#overview)
- [Quick Start](#quick-start)
- [Platform Distribution Methods](#platform-distribution-methods)
- [Homebrew Distribution](#homebrew-distribution)
- [Linux Package Managers](#linux-package-managers)
- [Release Automation](#release-automation)

## Overview

Diffa uses a multi-channel distribution strategy to reach users on macOS and Linux:

1. **Direct Downloads** - GitHub Releases with prebuilt binaries
2. **Homebrew** - Works on both macOS and Linux
3. **Snap Store** - Universal Linux packages
4. **Platform-specific** - APT, YUM, AUR (future)

## Quick Start

### For Users

```bash
# Universal installer (macOS & Linux)
curl -sSL https://raw.githubusercontent.com/codelynx/Diffa/main/Scripts/install-diffa.sh | bash

# Homebrew (macOS & Linux)
brew tap codelynx/diffa
brew install diffa

# Snap (Linux)
sudo snap install diffa --classic
```

### For Maintainers

1. **Tag a release**: `git tag v1.0.0 && git push origin v1.0.0`
2. **GitHub Actions** automatically builds and publishes binaries
3. **Update Homebrew formula** in your tap repository
4. **Push to Snap Store** if using snapcraft

## Platform Distribution Methods

### GitHub Releases (All Platforms)

**Setup**: Already configured in `.github/workflows/release.yml`

**Process**:
1. Push a version tag: `git tag v1.0.0`
2. GitHub Actions builds for all platforms
3. Creates release with binaries attached

**Binary naming convention**:
- `diffa-linux-x86_64` - Linux 64-bit Intel/AMD
- `diffa-linux-arm64` - Linux ARM64
- `diffa-macos-x86_64` - macOS Intel
- `diffa-macos-arm64` - macOS Apple Silicon

### Universal Install Script

**Location**: `Scripts/install-diffa.sh`

**Features**:
- Auto-detects OS and architecture
- Downloads appropriate binary from GitHub Releases
- Falls back to building from source
- Optionally installs Swift on Linux

**Maintenance**:
- Update VERSION variable when releasing
- Test on multiple platforms before release

## Homebrew Distribution

### Understanding Homebrew Structure

Homebrew has two distribution models:

1. **Homebrew Core** (Centralized)
   - Prestigious but strict requirements
   - Users install with: `brew install diffa`
   - Requires 50+ GitHub stars, PR review process

2. **Personal Taps** (Decentralized)
   - Full control, instant updates
   - Users install with: `brew tap owner/repo && brew install diffa`
   - No requirements or review process

### Creating Your Own Tap

#### Step 1: Create Repository

Create a GitHub repository named `homebrew-diffa` or `homebrew-tools`.

#### Step 2: Write Formula

Create `Formula/diffa.rb`:

```ruby
class Diffa < Formula
  desc "Fast file system comparison and synchronization"
  homepage "https://github.com/codelynx/Diffa"
  version "0.9.0"
  license "MIT"
  
  # Source tarball
  url "https://github.com/codelynx/Diffa/archive/refs/tags/v0.9.0.tar.gz"
  sha256 "SHA256_OF_TARBALL"
  
  # Bottles (prebuilt binaries) - optional but recommended
  bottle do
    root_url "https://github.com/codelynx/Diffa/releases/download/v0.9.0"
    sha256 cellar: :any_skip_relocation, arm64_sonoma:   "SHA256_OF_MACOS_ARM64_BOTTLE"
    sha256 cellar: :any_skip_relocation, arm64_ventura:  "SHA256_OF_MACOS_ARM64_BOTTLE"
    sha256 cellar: :any_skip_relocation, x86_64_linux:   "SHA256_OF_LINUX_X64_BOTTLE"
  end
  
  depends_on "swift" => :build
  depends_on "sqlite"
  
  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/diffa"
    man1.install "man/diffa.1" if File.exist?("man/diffa.1")
  end
  
  test do
    system "#{bin}/diffa", "--version"
  end
end
```

#### Step 3: Calculate SHA256

```bash
# For source tarball
curl -sL https://github.com/codelynx/Diffa/archive/refs/tags/v0.9.0.tar.gz | sha256sum

# For bottles (after building them)
sha256sum diffa--0.9.0.arm64_sonoma.bottle.tar.gz
```

#### Step 4: Test Formula Locally

```bash
# In your tap repository
brew install --build-from-source Formula/diffa.rb
brew test diffa
brew audit --strict diffa
```

#### Step 5: Push to GitHub

```bash
git add Formula/diffa.rb
git commit -m "Add diffa formula"
git push
```

#### Step 6: Users Install

```bash
brew tap codelynx/diffa
brew install diffa
```

### Building Bottles (Prebuilt Binaries)

Bottles speed up installation by providing prebuilt binaries:

```bash
# 1. Install formula from source
brew install --build-bottle diffa

# 2. Create bottle
brew bottle diffa

# 3. This creates files like:
# diffa--0.9.0.arm64_sonoma.bottle.tar.gz

# 4. Upload to GitHub releases

# 5. Update formula with bottle block (SHA256s)
```

### Automating Formula Updates

Create `.github/workflows/update-homebrew.yml` in your tap repo:

```yaml
name: Update Formula

on:
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to release'
        required: true

jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Update Formula
        run: |
          VERSION=${{ github.event.inputs.version }}
          URL="https://github.com/codelynx/Diffa/archive/refs/tags/v${VERSION}.tar.gz"
          SHA=$(curl -sL "$URL" | sha256sum | cut -d' ' -f1)
          
          sed -i "s/version \".*\"/version \"$VERSION\"/" Formula/diffa.rb
          sed -i "s|url \".*\"|url \"$URL\"|" Formula/diffa.rb
          sed -i "s/sha256 \".*\"/sha256 \"$SHA\"/" Formula/diffa.rb
      
      - name: Commit and Push
        run: |
          git config user.name "GitHub Actions"
          git config user.email "actions@github.com"
          git add Formula/diffa.rb
          git commit -m "Update diffa to v${{ github.event.inputs.version }}"
          git push
```

### Homebrew on Linux

Homebrew works identically on Linux with these differences:

- **Install location**: `/home/linuxbrew/.linuxbrew/` instead of `/usr/local/`
- **No sudo required**: Installs in user space
- **Same formulas**: One formula works on both macOS and Linux
- **Bottles**: Can have Linux-specific bottles

**Linux-specific considerations in formulas**:

```ruby
# Detect OS in formula
if OS.mac?
  depends_on "swift" => :build
elsif OS.linux?
  depends_on "swift-lang" => :build
  depends_on "libsqlite3-dev"
end
```

## Linux Package Managers

### Snap Store

**Configuration**: `snap/snapcraft.yaml`

**Publishing Process**:

```bash
# 1. Install snapcraft
sudo snap install snapcraft --classic

# 2. Login to Snap Store
snapcraft login

# 3. Register the name (one-time)
snapcraft register diffa

# 4. Build the snap
snapcraft

# 5. Upload to store
snapcraft upload diffa_0.9.0_amd64.snap

# 6. Release to stable channel
snapcraft release diffa 0.9.0 stable
```

**Benefits**:
- Auto-updates
- Works on most Linux distributions
- Sandboxed (use `classic` confinement for file system tools)
- Available in Ubuntu Software Center

### APT Repository (Ubuntu PPA) - Future

**Process Overview**:

1. Create Launchpad account
2. Set up PPA: `ppa:yourusername/diffa`
3. Create Debian package structure
4. Build and upload to PPA

**Users install with**:
```bash
sudo add-apt-repository ppa:yourusername/diffa
sudo apt update
sudo apt install diffa
```

### AUR (Arch Linux) - Future

Create `PKGBUILD` file and submit to AUR.

**Users install with**:
```bash
yay -S diffa  # or any AUR helper
```

## Release Automation

### Complete Release Workflow

1. **Update version** in `Package.swift`
2. **Tag release**:
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```

3. **GitHub Actions** automatically:
   - Builds binaries for all platforms
   - Creates GitHub Release
   - Attaches binaries

4. **Update Homebrew tap**:
   ```bash
   # In your homebrew-diffa repo
   ./update-formula.sh 1.0.0
   ```

5. **Update Snap** (if using):
   ```bash
   snapcraft upload diffa_1.0.0_amd64.snap
   snapcraft release diffa 1.0.0 stable
   ```

### Version Management

Keep versions synchronized across:
- Git tags
- Package.swift
- Homebrew formula
- Snap package
- Documentation

### Testing Distribution Channels

Before releasing, test each channel:

```bash
# Test GitHub Release binary
curl -L https://github.com/codelynx/Diffa/releases/download/v1.0.0/diffa-linux-x86_64 -o diffa
chmod +x diffa
./diffa --version

# Test Homebrew
brew tap codelynx/diffa
brew install diffa
diffa --version

# Test Snap
sudo snap install diffa --classic --edge
diffa --version
```

## Platform Comparison Matrix

| Method | macOS | Linux | Auto-Update | Sudo Required | User Effort |
|--------|-------|-------|-------------|--------------|-------------|
| GitHub Release | ✅ | ✅ | ❌ | Maybe | Medium |
| Homebrew | ✅ | ✅ | Manual | No | Low |
| Snap | ❌ | ✅ | ✅ | Yes | Low |
| APT (PPA) | ❌ | Ubuntu/Debian | Manual | Yes | Low |
| Direct Binary | ✅ | ✅ | ❌ | Maybe | High |
| Build from Source | ✅ | ✅ | ❌ | Maybe | High |

## Best Practices

### For New Projects

1. **Start with GitHub Releases** - Immediate distribution
2. **Add personal Homebrew tap** - Better user experience
3. **Consider Snap** for Linux auto-updates
4. **Submit to Homebrew Core** when popular enough

### Versioning

- Use semantic versioning (MAJOR.MINOR.PATCH)
- Tag with `v` prefix: `v1.0.0`
- Keep consistent across all channels

### Documentation

Always provide:
- Installation instructions for each platform
- Uninstall instructions
- Troubleshooting guide
- Version compatibility matrix

### Support Channels

- GitHub Issues for bug reports
- GitHub Discussions for questions
- Discord/Slack for community (if applicable)

## Troubleshooting

### Common Issues

**Homebrew Formula Rejected from Core**
- Build user base with personal tap first
- Ensure 50+ GitHub stars
- Fix all `brew audit --strict` issues

**Snap Confinement Issues**
- Use `classic` confinement for file system tools
- Document why classic is needed

**Binary Compatibility**
- Build on oldest supported OS version
- Static link when possible
- Test on multiple distributions

**Signature/Notarization (macOS)**
- Sign binaries with Developer ID
- Notarize for Gatekeeper
- Use `codesign` and `notarytool`

## Resources

- [Homebrew Formula Cookbook](https://docs.brew.sh/Formula-Cookbook)
- [Snapcraft Documentation](https://snapcraft.io/docs)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Swift on Linux](https://swift.org/download/#linux)