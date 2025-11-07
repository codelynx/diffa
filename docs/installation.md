# Installation Guide

Diffa can be installed on macOS and Linux using several methods. Choose the one that best fits your system and preferences.

## Quick Install

### Universal Installer (Recommended)
Works on both macOS and Linux:

```bash
curl -sSL https://raw.githubusercontent.com/codelynx/Diffa/main/Scripts/install-diffa.sh | bash
```

This script will:
- Detect your operating system and architecture
- Download the appropriate prebuilt binary
- Install it to `/usr/local/bin/`
- Optionally install Swift if building from source

## Platform-Specific Methods

### macOS

#### Homebrew (Recommended)
```bash
brew tap codelynx/diffa
brew install diffa
```

#### MacPorts (Coming Soon)
```bash
# Not yet available
sudo port install diffa
```

### Linux

#### Homebrew on Linux (Yes, it works!)
```bash
# Install Homebrew if you don't have it
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Then install Diffa (same as macOS!)
brew tap codelynx/diffa
brew install diffa
```

#### Snap Store (Ubuntu/Debian/Fedora/etc.)
```bash
sudo snap install diffa --classic
```

The `--classic` flag is required because Diffa needs full file system access.

#### APT Repository (Ubuntu/Debian) - Coming Soon
```bash
# PPA not yet available
sudo add-apt-repository ppa:codelynx/diffa
sudo apt update
sudo apt install diffa
```

## Manual Installation

### Download Prebuilt Binaries

1. Go to [Releases](https://github.com/codelynx/Diffa/releases/latest)
2. Download the appropriate binary:
   - **Linux**: 
     - `diffa-linux-x86_64` - 64-bit Intel/AMD
     - `diffa-linux-arm64` - ARM64 (Raspberry Pi 4+, AWS Graviton)
   - **macOS**:
     - `diffa-macos-x86_64` - Intel Macs
     - `diffa-macos-arm64` - Apple Silicon (M1/M2/M3)

3. Make it executable and move to your PATH:
```bash
chmod +x diffa-*
sudo mv diffa-* /usr/local/bin/diffa
```

### Build from Source

Requirements:
- Swift 5.9 or later
- SQLite3 development libraries
- Git

#### Install Swift

**macOS**: Swift is included with Xcode. Install from the App Store or:
```bash
xcode-select --install
```

**Linux**: Use the provided installer script:
```bash
curl -sSL https://raw.githubusercontent.com/codelynx/Diffa/main/Scripts/install-swift-linux.sh | bash
```

Or manually from [swift.org](https://swift.org/download/)

#### Build Steps

```bash
# Clone the repository
git clone https://github.com/codelynx/Diffa.git
cd Diffa

# Build release version
swift build -c release

# Install (may require sudo)
sudo cp .build/release/diffa /usr/local/bin/

# Verify installation
diffa --version
```

## Container Image (Docker/Podman)

Coming soon:
```bash
# Docker
docker run --rm -v $(pwd):/data codelynx/diffa snapshot /data

# Podman
podman run --rm -v $(pwd):/data codelynx/diffa snapshot /data
```

## Package Managers Summary

| Platform | Package Manager | Status | Command |
|----------|----------------|--------|---------|
| macOS + Linux | Homebrew | ✅ Available | `brew tap codelynx/diffa && brew install diffa` |
| macOS | MacPorts | 🚧 Coming Soon | - |
| Linux (All) | Snap | ✅ Available | `snap install diffa --classic` |
| Linux (All) | Binary Download | ✅ Available | See [Releases](https://github.com/codelynx/Diffa/releases) |
| Ubuntu/Debian | APT (PPA) | 🚧 Coming Soon | - |
| RHEL/Fedora | YUM/DNF | 🚧 Planned | - |
| Arch Linux | AUR | 🚧 Planned | - |
| Any | Docker | 🚧 Coming Soon | - |

## Verification

After installation, verify it works:

```bash
# Check version
diffa --version

# View help
diffa --help

# Create a test snapshot
diffa snapshot /tmp -o test.diffa
```

## Updating

### Homebrew
```bash
brew upgrade diffa
```

### Snap
```bash
# Auto-updates by default, or manually:
sudo snap refresh diffa
```

### Manual Update
Re-run the installation script or download the latest binary from releases.

## Uninstalling

### Homebrew
```bash
brew uninstall diffa
```

### Snap
```bash
sudo snap remove diffa
```

### Manual
```bash
sudo rm /usr/local/bin/diffa
```

## Troubleshooting

### Permission Denied
If you get permission errors when installing to `/usr/local/bin/`:
```bash
# Either use sudo
sudo mv diffa /usr/local/bin/

# Or install to user directory
mkdir -p ~/.local/bin
mv diffa ~/.local/bin/
# Add to PATH in ~/.bashrc or ~/.zshrc:
export PATH="$HOME/.local/bin:$PATH"
```

### Swift Not Found (Linux)
Install Swift using our script:
```bash
./Scripts/install-swift-linux.sh
```

### Library Dependencies (Linux)
Install required libraries:
```bash
# Ubuntu/Debian
sudo apt-get install libsqlite3-dev

# Fedora/RHEL
sudo dnf install sqlite-devel

# Arch
sudo pacman -S sqlite
```

## Support

For issues or questions:
- [GitHub Issues](https://github.com/codelynx/Diffa/issues)
- [Discussions](https://github.com/codelynx/Diffa/discussions)