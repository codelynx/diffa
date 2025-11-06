#!/bin/bash

# Install Swift on Linux
# This script installs Swift 5.9.2 on Ubuntu/Debian-based systems

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Installing Swift 5.9.2 for Linux...${NC}"

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION_ID=$VERSION_ID
else
    echo -e "${RED}Cannot detect OS version${NC}"
    exit 1
fi

# Determine the correct Swift download based on OS
case "$OS" in
    ubuntu)
        case "$VERSION_ID" in
            "22.04")
                SWIFT_URL="https://download.swift.org/swift-5.9.2-release/ubuntu2204/swift-5.9.2-RELEASE/swift-5.9.2-RELEASE-ubuntu22.04.tar.gz"
                ;;
            "20.04")
                SWIFT_URL="https://download.swift.org/swift-5.9.2-release/ubuntu2004/swift-5.9.2-RELEASE/swift-5.9.2-RELEASE-ubuntu20.04.tar.gz"
                ;;
            *)
                echo -e "${YELLOW}Ubuntu $VERSION_ID not officially supported. Trying Ubuntu 22.04 build...${NC}"
                SWIFT_URL="https://download.swift.org/swift-5.9.2-release/ubuntu2204/swift-5.9.2-RELEASE/swift-5.9.2-RELEASE-ubuntu22.04.tar.gz"
                ;;
        esac
        ;;
    debian)
        echo -e "${YELLOW}Debian detected. Using Ubuntu 22.04 build (may work)...${NC}"
        SWIFT_URL="https://download.swift.org/swift-5.9.2-release/ubuntu2204/swift-5.9.2-RELEASE/swift-5.9.2-RELEASE-ubuntu22.04.tar.gz"
        ;;
    *)
        echo -e "${RED}Unsupported OS: $OS${NC}"
        echo "Please visit https://swift.org/download/ for manual installation"
        exit 1
        ;;
esac

# Install dependencies
echo -e "${GREEN}Installing dependencies...${NC}"
sudo apt-get update
sudo apt-get install -y \
    binutils \
    git \
    gnupg2 \
    libc6-dev \
    libcurl4-openssl-dev \
    libedit2 \
    libgcc-11-dev \
    libpython3.10 \
    libsqlite3-0 \
    libsqlite3-dev \
    libstdc++-11-dev \
    libxml2-dev \
    libz3-4 \
    pkg-config \
    tzdata \
    unzip \
    zlib1g-dev

# Create installation directory
INSTALL_DIR="$HOME/swift-5.9.2"
if [ -d "$INSTALL_DIR" ]; then
    echo -e "${YELLOW}Swift directory already exists at $INSTALL_DIR${NC}"
    echo -n "Remove and reinstall? (y/n) "
    read -r response
    if [ "$response" = "y" ]; then
        rm -rf "$INSTALL_DIR"
    else
        echo "Skipping installation."
        exit 0
    fi
fi

# Download Swift
echo -e "${GREEN}Downloading Swift 5.9.2...${NC}"
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"
wget -q --show-progress "$SWIFT_URL" -O swift.tar.gz

# Extract Swift
echo -e "${GREEN}Extracting Swift...${NC}"
tar xzf swift.tar.gz
mv swift-5.9.2-RELEASE-ubuntu* "$INSTALL_DIR"

# Add to PATH
echo -e "${GREEN}Configuring PATH...${NC}"
SWIFT_BIN="$INSTALL_DIR/usr/bin"

# Add to bashrc if not already present
if ! grep -q "$SWIFT_BIN" ~/.bashrc; then
    echo "" >> ~/.bashrc
    echo "# Swift" >> ~/.bashrc
    echo "export PATH=\"$SWIFT_BIN:\$PATH\"" >> ~/.bashrc
    echo -e "${GREEN}Added Swift to ~/.bashrc${NC}"
fi

# Add to zshrc if zsh is installed
if [ -f ~/.zshrc ]; then
    if ! grep -q "$SWIFT_BIN" ~/.zshrc; then
        echo "" >> ~/.zshrc
        echo "# Swift" >> ~/.zshrc
        echo "export PATH=\"$SWIFT_BIN:\$PATH\"" >> ~/.zshrc
        echo -e "${GREEN}Added Swift to ~/.zshrc${NC}"
    fi
fi

# Clean up
cd /
rm -rf "$TEMP_DIR"

# Test installation
export PATH="$SWIFT_BIN:$PATH"
if swift --version > /dev/null 2>&1; then
    echo -e "${GREEN}Swift successfully installed!${NC}"
    swift --version
    echo ""
    echo -e "${GREEN}Installation complete!${NC}"
    echo "To use Swift in this session, run:"
    echo -e "  ${YELLOW}export PATH=\"$SWIFT_BIN:\$PATH\"${NC}"
    echo ""
    echo "Or start a new terminal session."
else
    echo -e "${RED}Installation failed. Swift command not found.${NC}"
    exit 1
fi