#!/bin/bash
# build-release.sh - Build optimized release binaries for distribution
#
# Usage:
#   ./Scripts/build-release.sh [version]
#
# Builds:
#   - Universal macOS binary (arm64 + x86_64)
#   - Linux x86_64 binary (if on Linux)
#   - Creates tarball with binaries and man pages

set -euo pipefail

VERSION="${1:-$(git describe --tags --always 2>/dev/null || echo "0.1.0")}"
BUILD_DIR=".build/release-dist"
DIST_DIR="dist"

echo "=== Diffa Release Builder ==="
echo "Version: $VERSION"
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
        exit 1
        ;;
esac

echo "Platform: $PLATFORM_NAME"
echo

# Clean previous builds
echo "🧹 Cleaning previous builds..."
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# Build release binary
echo "🔨 Building release binary..."
if [ "$PLATFORM_NAME" = "macos" ]; then
    # Build universal binary for macOS (arm64 + x86_64)
    echo "  Building for arm64..."
    swift build -c release --arch arm64

    echo "  Building for x86_64..."
    swift build -c release --arch x86_64

    echo "  Creating universal binary..."
    lipo -create \
        .build/arm64-apple-macosx/release/diffa \
        .build/x86_64-apple-macosx/release/diffa \
        -output "$BUILD_DIR/diffa"

    BINARY_PATH="$BUILD_DIR/diffa"
else
    # Build for Linux
    swift build -c release
    cp .build/release/diffa "$BUILD_DIR/diffa"
    BINARY_PATH="$BUILD_DIR/diffa"
fi

echo "✅ Binary built: $BINARY_PATH"

# Verify binary
echo
echo "🔍 Verifying binary..."
BINARY_VERSION=$("$BINARY_PATH" --version 2>&1 | head -1 || echo "unknown")
echo "  Version: $BINARY_VERSION"

BINARY_SIZE=$(stat -f%z "$BINARY_PATH" 2>/dev/null || stat -c%s "$BINARY_PATH" 2>/dev/null)
BINARY_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $BINARY_SIZE / 1024 / 1024}")
echo "  Size: ${BINARY_SIZE_MB}MB"

if [ "$PLATFORM_NAME" = "macos" ]; then
    ARCHS=$(lipo -info "$BINARY_PATH" | awk -F: '{print $3}')
    echo "  Architectures:$ARCHS"
fi

# Strip binary
echo
echo "✂️  Stripping binary..."
strip "$BINARY_PATH"
STRIPPED_SIZE=$(stat -f%z "$BINARY_PATH" 2>/dev/null || stat -c%s "$BINARY_PATH" 2>/dev/null)
STRIPPED_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $STRIPPED_SIZE / 1024 / 1024}")
echo "  Stripped size: ${STRIPPED_SIZE_MB}MB"

# Create distribution package
echo
echo "📦 Creating distribution package..."
PACKAGE_NAME="diffa-${VERSION}-${PLATFORM_NAME}"
PACKAGE_DIR="$BUILD_DIR/$PACKAGE_NAME"

mkdir -p "$PACKAGE_DIR/bin"
mkdir -p "$PACKAGE_DIR/man/man1"
mkdir -p "$PACKAGE_DIR/share/doc/diffa"

# Copy binary
cp "$BINARY_PATH" "$PACKAGE_DIR/bin/"

# Copy man pages
if [ -d "man/man1" ]; then
    cp man/man1/*.1 "$PACKAGE_DIR/man/man1/"
    echo "  ✓ Man pages included"
fi

# Copy documentation
cp README.md "$PACKAGE_DIR/share/doc/diffa/" 2>/dev/null || true
cp LICENSE* "$PACKAGE_DIR/share/doc/diffa/" 2>/dev/null || true

# Copy examples
if [ -d "examples" ]; then
    cp -r examples "$PACKAGE_DIR/share/doc/diffa/"
    echo "  ✓ Example scripts included"
fi

# Create install script
cat > "$PACKAGE_DIR/install.sh" << 'EOF'
#!/bin/bash
# install.sh - Install diffa
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"

echo "Installing diffa to $PREFIX..."

# Install binary
install -m 755 bin/diffa "$PREFIX/bin/diffa"
echo "✓ Binary installed to $PREFIX/bin/diffa"

# Install man pages
if [ -d "man/man1" ]; then
    mkdir -p "$PREFIX/share/man/man1"
    for manpage in man/man1/*.1; do
        install -m 644 "$manpage" "$PREFIX/share/man/man1/"
    done
    echo "✓ Man pages installed to $PREFIX/share/man/man1/"
fi

# Install documentation
if [ -d "share/doc/diffa" ]; then
    mkdir -p "$PREFIX/share/doc/diffa"
    cp -r share/doc/diffa/* "$PREFIX/share/doc/diffa/"
    echo "✓ Documentation installed to $PREFIX/share/doc/diffa/"
fi

echo
echo "Installation complete!"
echo
echo "Run 'diffa --help' to get started"
echo "Run 'man diffa' for documentation"
EOF

chmod +x "$PACKAGE_DIR/install.sh"

# Create tarball
echo
echo "🗜️  Creating tarball..."
cd "$BUILD_DIR"
tar -czf "$PACKAGE_NAME.tar.gz" "$PACKAGE_NAME"
TARBALL_SIZE=$(stat -f%z "$PACKAGE_NAME.tar.gz" 2>/dev/null || stat -c%s "$PACKAGE_NAME.tar.gz" 2>/dev/null)
TARBALL_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $TARBALL_SIZE / 1024 / 1024}")
cd - > /dev/null

mv "$BUILD_DIR/$PACKAGE_NAME.tar.gz" "$DIST_DIR/"

echo "✅ Tarball created: $DIST_DIR/$PACKAGE_NAME.tar.gz (${TARBALL_SIZE_MB}MB)"

# Generate checksums
echo
echo "🔐 Generating checksums..."
cd "$DIST_DIR"
shasum -a 256 "$PACKAGE_NAME.tar.gz" > "$PACKAGE_NAME.tar.gz.sha256"
cd - > /dev/null

echo "✅ Checksum: $DIST_DIR/$PACKAGE_NAME.tar.gz.sha256"

# Summary
echo
echo "=== Build Complete ==="
echo "Version: $VERSION"
echo "Platform: $PLATFORM_NAME"
echo "Package: $DIST_DIR/$PACKAGE_NAME.tar.gz"
echo
echo "To install locally:"
echo "  tar -xzf $DIST_DIR/$PACKAGE_NAME.tar.gz"
echo "  cd $PACKAGE_NAME"
echo "  sudo ./install.sh"
echo
echo "To verify checksum:"
echo "  cd $DIST_DIR && shasum -a 256 -c $PACKAGE_NAME.tar.gz.sha256"
