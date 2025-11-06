#!/bin/bash
# verify-installer.sh - Test what an installer does to your system
#
# Usage:
#   ./verify-installer.sh /Applications installer.pkg
#   ./verify-installer.sh /System/Library before-after

set -euo pipefail

TARGET_DIR="${1:?Usage: $0 <directory> <installer-command>}"
shift
INSTALLER_CMD="$@"

BEFORE_SNAPSHOT="/tmp/diffalla-before-$$.db"
AFTER_SNAPSHOT="/tmp/diffalla-after-$$.db"

cleanup() {
    rm -f "$BEFORE_SNAPSHOT" "$AFTER_SNAPSHOT"
}
trap cleanup EXIT

echo "=== Installer Impact Verification ==="
echo "Target directory: $TARGET_DIR"
echo "Installer command: $INSTALLER_CMD"
echo

# Create before snapshot
echo "📸 Creating before snapshot..."
diffalla snapshot "$TARGET_DIR" -o "$BEFORE_SNAPSHOT"
echo

# Run installer
echo "🚀 Running installer..."
eval "$INSTALLER_CMD"
echo

# Create after snapshot
echo "📸 Creating after snapshot..."
diffalla snapshot "$TARGET_DIR" -o "$AFTER_SNAPSHOT"
echo

# Compare
echo "🔍 Comparing snapshots..."
echo
if diffalla compare "$BEFORE_SNAPSHOT" "$AFTER_SNAPSHOT"; then
    echo
    echo "✅ No changes detected (installer had no impact)"
    exit 0
else
    echo
    echo "⚠️  Changes detected - see above for details"
    exit 1
fi
