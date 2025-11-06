#!/bin/bash
# install.sh - Install diffa from source or binary
#
# Usage:
#   # Install from source (recommended)
#   curl -fsSL https://raw.githubusercontent.com/yourusername/Diffa/main/Scripts/install.sh | bash
#
#   # Or download and run
#   ./Scripts/install.sh
#
#   # Specify installation prefix
#   PREFIX=/opt/local ./Scripts/install.sh

set -euo pipefail

# Configuration
PREFIX="${PREFIX:-/usr/local}"
REPO="${REPO:-codelynx/Diffa}"
VERSION="${VERSION:-latest}"

echo "=== Diffa Installer ==="
echo

# Detect platform
PLATFORM="$(uname -s)"
case "$PLATFORM" in
    Darwin)
        PLATFORM_NAME="macos"
        ;;
    Linux)
        PLATFORM_NAME="linux"
        ;;
    *)
        echo "❌ Unsupported platform: $PLATFORM"
        echo "Supported: macOS, Linux"
        exit 1
        ;;
esac

echo "Platform: $PLATFORM_NAME"
echo "Install prefix: $PREFIX"
echo

# Check if we're in the source directory
if [ -f "Package.swift" ] && [ -d "Sources/DiffaCLI" ]; then
    echo "📦 Building from source..."
    echo

    # Check for Swift
    if ! command -v swift &> /dev/null; then
        echo "❌ Swift compiler not found"
        echo
        echo "Install Swift from: https://swift.org/download/"
        exit 1
    fi

    SWIFT_VERSION=$(swift --version | head -1)
    echo "Swift version: $SWIFT_VERSION"
    echo

    # Build release binary
    echo "🔨 Building release binary..."
    swift build -c release

    BINARY_PATH=".build/release/diffa"

    # Verify binary
    if [ ! -f "$BINARY_PATH" ]; then
        echo "❌ Build failed - binary not found"
        exit 1
    fi

    echo "✅ Build successful"
    echo

    # Install binary
    echo "📥 Installing binary..."
    if [ ! -w "$PREFIX/bin" ]; then
        echo "Need sudo to install to $PREFIX/bin"
        sudo install -m 755 "$BINARY_PATH" "$PREFIX/bin/diffa"
    else
        install -m 755 "$BINARY_PATH" "$PREFIX/bin/diffa"
    fi
    echo "✓ Binary installed to $PREFIX/bin/diffa"

    # Install man pages
    if [ -d "man/man1" ]; then
        echo
        echo "📚 Installing man pages..."
        if [ ! -w "$PREFIX/share/man/man1" ]; then
            sudo mkdir -p "$PREFIX/share/man/man1"
            for manpage in man/man1/*.1; do
                sudo install -m 644 "$manpage" "$PREFIX/share/man/man1/"
            done
        else
            mkdir -p "$PREFIX/share/man/man1"
            for manpage in man/man1/*.1; do
                install -m 644 "$manpage" "$PREFIX/share/man/man1/"
            done
        fi
        echo "✓ Man pages installed to $PREFIX/share/man/man1/"
    fi

    # Install documentation
    if [ -d "docs" ] || [ -f "README.md" ]; then
        echo
        echo "📖 Installing documentation..."
        if [ ! -w "$PREFIX/share/doc" ]; then
            sudo mkdir -p "$PREFIX/share/doc/diffa"
            [ -f "README.md" ] && sudo cp README.md "$PREFIX/share/doc/diffa/"
            [ -d "examples" ] && sudo cp -r examples "$PREFIX/share/doc/diffa/"
        else
            mkdir -p "$PREFIX/share/doc/diffa"
            [ -f "README.md" ] && cp README.md "$PREFIX/share/doc/diffa/"
            [ -d "examples" ] && cp -r examples "$PREFIX/share/doc/diffa/"
        fi
        echo "✓ Documentation installed to $PREFIX/share/doc/diffa/"
    fi

else
    # Download pre-built binary
    echo "📦 Installing from pre-built binary..."
    echo

    # Determine download URL
    if [ "$VERSION" = "latest" ]; then
        DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/diffa-$VERSION-$PLATFORM_NAME.tar.gz"
    else
        DOWNLOAD_URL="https://github.com/$REPO/releases/download/v$VERSION/diffa-$VERSION-$PLATFORM_NAME.tar.gz"
    fi

    echo "Download URL: $DOWNLOAD_URL"
    echo

    # Create temp directory
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    # Download
    echo "⬇️  Downloading..."
    if command -v curl &> /dev/null; then
        curl -fsSL "$DOWNLOAD_URL" -o "$TEMP_DIR/diffa.tar.gz"
    elif command -v wget &> /dev/null; then
        wget -q "$DOWNLOAD_URL" -O "$TEMP_DIR/diffa.tar.gz"
    else
        echo "❌ Neither curl nor wget found"
        echo "Install curl or wget to continue"
        exit 1
    fi

    # Extract
    echo "📂 Extracting..."
    cd "$TEMP_DIR"
    tar -xzf diffa.tar.gz
    cd diffa-*

    # Run install script from package
    if [ -f "install.sh" ]; then
        PREFIX="$PREFIX" ./install.sh
    else
        echo "❌ Package does not contain install.sh"
        exit 1
    fi
fi

echo
echo "=== Installation Complete ==="
echo

# Verify installation
if command -v diffa &> /dev/null; then
    INSTALLED_VERSION=$(diffa --version 2>&1 | head -1)
    echo "✅ diffa installed successfully!"
    echo "   Version: $INSTALLED_VERSION"
    echo "   Location: $(which diffa)"
else
    echo "⚠️  Installation complete but 'diffa' not found in PATH"
    echo "   Add $PREFIX/bin to your PATH:"
    echo "   export PATH=\"$PREFIX/bin:\$PATH\""
fi

echo
echo "Get started:"
echo "  diffa --help"
echo "  man diffa"
