#!/bin/bash

# Universal installer for Diffa CLI
# Supports: macOS (via Homebrew) and Linux (direct binary)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REPO="codelynx/Diffa"
BINARY_NAME="diffa"
INSTALL_DIR="/usr/local/bin"

# Functions
print_header() {
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       Diffa CLI Installer           ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo
}

detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        ARCH=$(uname -m)
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS="linux"
        ARCH=$(uname -m)
        # Detect Linux distribution
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            DISTRO=$ID
            DISTRO_VERSION=$VERSION_ID
        fi
    else
        echo -e "${RED}Unsupported OS: $OSTYPE${NC}"
        exit 1
    fi
}

check_swift() {
    if ! command -v swift &> /dev/null; then
        echo -e "${YELLOW}Swift is not installed.${NC}"
        if [[ "$OS" == "linux" ]]; then
            echo -e "${GREEN}Would you like to install Swift? (y/n)${NC}"
            read -r response
            if [[ "$response" == "y" ]]; then
                echo -e "${GREEN}Installing Swift...${NC}"
                bash <(curl -sSL https://raw.githubusercontent.com/$REPO/main/Scripts/install-swift-linux.sh)
            else
                echo -e "${RED}Swift is required. Please install it first.${NC}"
                echo "Visit: https://swift.org/download/"
                exit 1
            fi
        else
            echo -e "${RED}Please install Swift from swift.org${NC}"
            exit 1
        fi
    fi
}

install_homebrew_version() {
    echo -e "${GREEN}Installing via Homebrew...${NC}"
    if ! command -v brew &> /dev/null; then
        echo -e "${YELLOW}Homebrew not found. Install it? (y/n)${NC}"
        read -r response
        if [[ "$response" == "y" ]]; then
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        else
            install_github_release
            return
        fi
    fi
    
    # Check if tap exists, if not add it
    if ! brew tap | grep -q "codelynx/diffa"; then
        brew tap codelynx/diffa
    fi
    brew install diffa
}

get_latest_release() {
    curl -s "https://api.github.com/repos/$REPO/releases/latest" | \
        grep '"tag_name":' | \
        sed -E 's/.*"([^"]+)".*/\1/'
}

install_github_release() {
    echo -e "${GREEN}Installing from GitHub Release...${NC}"
    
    # Get latest version
    VERSION=$(get_latest_release)
    if [ -z "$VERSION" ]; then
        echo -e "${RED}Could not fetch latest release version${NC}"
        install_from_source
        return
    fi
    
    echo -e "${BLUE}Latest version: $VERSION${NC}"
    
    # Construct download URL based on OS and architecture
    if [[ "$OS" == "macos" ]]; then
        if [[ "$ARCH" == "arm64" ]]; then
            BINARY_URL="https://github.com/$REPO/releases/download/$VERSION/diffa-macos-arm64"
        else
            BINARY_URL="https://github.com/$REPO/releases/download/$VERSION/diffa-macos-x86_64"
        fi
    else
        if [[ "$ARCH" == "x86_64" ]]; then
            BINARY_URL="https://github.com/$REPO/releases/download/$VERSION/diffa-linux-x86_64"
        elif [[ "$ARCH" == "aarch64" ]]; then
            BINARY_URL="https://github.com/$REPO/releases/download/$VERSION/diffa-linux-arm64"
        else
            echo -e "${YELLOW}No prebuilt binary for $ARCH. Building from source...${NC}"
            install_from_source
            return
        fi
    fi
    
    # Download binary
    echo -e "${GREEN}Downloading binary...${NC}"
    TEMP_DIR=$(mktemp -d)
    curl -L "$BINARY_URL" -o "$TEMP_DIR/$BINARY_NAME"
    
    # Make executable
    chmod +x "$TEMP_DIR/$BINARY_NAME"
    
    # Install (may require sudo)
    if [ -w "$INSTALL_DIR" ]; then
        mv "$TEMP_DIR/$BINARY_NAME" "$INSTALL_DIR/"
    else
        echo -e "${YELLOW}Installing to $INSTALL_DIR requires sudo${NC}"
        sudo mv "$TEMP_DIR/$BINARY_NAME" "$INSTALL_DIR/"
    fi
    
    # Clean up
    rm -rf "$TEMP_DIR"
    
    echo -e "${GREEN}✓ Installed to $INSTALL_DIR/$BINARY_NAME${NC}"
}

install_from_source() {
    echo -e "${GREEN}Building from source...${NC}"
    
    check_swift
    
    # Clone repository
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    echo -e "${GREEN}Cloning repository...${NC}"
    git clone "https://github.com/$REPO.git"
    cd Diffa
    
    # Build
    echo -e "${GREEN}Building (this may take a few minutes)...${NC}"
    swift build -c release
    
    # Install
    BUILT_BINARY=".build/release/$BINARY_NAME"
    if [ -f "$BUILT_BINARY" ]; then
        if [ -w "$INSTALL_DIR" ]; then
            cp "$BUILT_BINARY" "$INSTALL_DIR/"
        else
            echo -e "${YELLOW}Installing to $INSTALL_DIR requires sudo${NC}"
            sudo cp "$BUILT_BINARY" "$INSTALL_DIR/"
        fi
        echo -e "${GREEN}✓ Installed to $INSTALL_DIR/$BINARY_NAME${NC}"
    else
        echo -e "${RED}Build failed. Binary not found.${NC}"
        exit 1
    fi
    
    # Clean up
    cd /
    rm -rf "$TEMP_DIR"
}

verify_installation() {
    if command -v $BINARY_NAME &> /dev/null; then
        echo -e "${GREEN}✓ Installation successful!${NC}"
        echo -e "${BLUE}Version: $($BINARY_NAME --version)${NC}"
        echo
        echo -e "${GREEN}Get started with:${NC}"
        echo "  $BINARY_NAME --help"
    else
        echo -e "${RED}Installation failed. $BINARY_NAME not found in PATH.${NC}"
        exit 1
    fi
}

main() {
    print_header
    detect_os
    
    echo -e "${BLUE}Detected: $OS ($ARCH)${NC}"
    if [[ "$OS" == "linux" ]] && [ ! -z "$DISTRO" ]; then
        echo -e "${BLUE}Distribution: $DISTRO $DISTRO_VERSION${NC}"
    fi
    echo
    
    # Choose installation method
    if [[ "$OS" == "macos" ]]; then
        echo -e "${GREEN}Installation methods:${NC}"
        echo "1) Homebrew (recommended)"
        echo "2) GitHub Release (prebuilt binary)"
        echo "3) Build from source"
        echo -n "Choose [1-3]: "
        read -r choice
        
        case $choice in
            1) install_homebrew_version ;;
            2) install_github_release ;;
            3) install_from_source ;;
            *) install_homebrew_version ;;
        esac
    else
        echo -e "${GREEN}Installation methods:${NC}"
        echo "1) GitHub Release (prebuilt binary) - recommended"
        echo "2) Build from source"
        echo -n "Choose [1-2]: "
        read -r choice
        
        case $choice in
            1) install_github_release ;;
            2) install_from_source ;;
            *) install_github_release ;;
        esac
    fi
    
    verify_installation
}

# Run main function
main "$@"