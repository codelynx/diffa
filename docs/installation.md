# Installation Guide

Diffalla can be installed on macOS and Linux using several methods. Choose the one that best fits your system and preferences.

## Quick Install

### Universal Installer (Recommended)
Works on both macOS and Linux:

```bash
curl -sSL https://raw.githubusercontent.com/codelynx/Diffalla/main/Scripts/install-diffalla.sh | bash
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
brew tap codelynx/diffalla
brew install diffalla
```

#### MacPorts (Coming Soon)
```bash
# Not yet available
sudo port install diffalla
```

### Linux

#### Homebrew on Linux (Yes, it works!)
```bash
# Install Homebrew if you don't have it
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Then install Diffalla (same as macOS!)
brew tap codelynx/diffalla
brew install diffalla
```

#### Snap Store (Ubuntu/Debian/Fedora/etc.)
```bash
sudo snap install diffalla --classic
```

The `--classic` flag is required because Diffalla needs full file system access.

#### APT Repository (Ubuntu/Debian) - Coming Soon
```bash
# PPA not yet available
sudo add-apt-repository ppa:codelynx/diffalla
sudo apt update
sudo apt install diffalla
```

## Manual Installation

### Download Prebuilt Binaries

1. Go to [Releases](https://github.com/codelynx/Diffalla/releases/latest)
2. Download the appropriate binary:
   - **Linux**: 
     - `diffalla-linux-x86_64` - 64-bit Intel/AMD
     - `diffalla-linux-arm64` - ARM64 (Raspberry Pi 4+, AWS Graviton)
   - **macOS**:
     - `diffalla-macos-x86_64` - Intel Macs
     - `diffalla-macos-arm64` - Apple Silicon (M1/M2/M3)

3. Make it executable and move to your PATH:
```bash
chmod +x diffalla-*
sudo mv diffalla-* /usr/local/bin/diffalla
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
curl -sSL https://raw.githubusercontent.com/codelynx/Diffalla/main/Scripts/install-swift-linux.sh | bash
```

Or manually from [swift.org](https://swift.org/download/)

#### Build Steps

```bash
# Clone the repository
git clone https://github.com/codelynx/Diffalla.git
cd Diffalla

# Build release version
swift build -c release

# Install (may require sudo)
sudo cp .build/release/diffalla /usr/local/bin/

# Verify installation
diffalla --version
```

## Container Image (Docker/Podman)

Coming soon:
```bash
# Docker
docker run --rm -v $(pwd):/data codelynx/diffalla snapshot /data

# Podman
podman run --rm -v $(pwd):/data codelynx/diffalla snapshot /data
```

## Package Managers Summary

| Platform | Package Manager | Status | Command |
|----------|----------------|--------|---------|
| macOS + Linux | Homebrew | ✅ Available | `brew tap codelynx/diffalla && brew install diffalla` |
| macOS | MacPorts | 🚧 Coming Soon | - |
| Linux (All) | Snap | ✅ Available | `snap install diffalla --classic` |
| Linux (All) | Binary Download | ✅ Available | See [Releases](https://github.com/codelynx/Diffalla/releases) |
| Ubuntu/Debian | APT (PPA) | 🚧 Coming Soon | - |
| RHEL/Fedora | YUM/DNF | 🚧 Planned | - |
| Arch Linux | AUR | 🚧 Planned | - |
| Any | Docker | 🚧 Coming Soon | - |

## Verification

After installation, verify it works:

```bash
# Check version
diffalla --version

# View help
diffalla --help

# Create a test snapshot
diffalla snapshot /tmp -o test.sqlite
```

## Updating

### Homebrew
```bash
brew upgrade diffalla
```

### Snap
```bash
# Auto-updates by default, or manually:
sudo snap refresh diffalla
```

### Manual Update
Re-run the installation script or download the latest binary from releases.

## Uninstalling

### Homebrew
```bash
brew uninstall diffalla
```

### Snap
```bash
sudo snap remove diffalla
```

### Manual
```bash
sudo rm /usr/local/bin/diffalla
```

## Troubleshooting

### Permission Denied
If you get permission errors when installing to `/usr/local/bin/`:
```bash
# Either use sudo
sudo mv diffalla /usr/local/bin/

# Or install to user directory
mkdir -p ~/.local/bin
mv diffalla ~/.local/bin/
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
- [GitHub Issues](https://github.com/codelynx/Diffalla/issues)
- [Discussions](https://github.com/codelynx/Diffalla/discussions)