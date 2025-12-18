#!/bin/bash
# deploy-with-rollback.sh - Deploy with automatic rollback on failure
#
# Usage:
#   ./deploy-with-rollback.sh /var/www /staging/new-version
#
# Features:
#   - Creates reversible patch for rollback
#   - Validates deployment
#   - Automatic rollback on failure
#   - Keeps patch for manual rollback

set -euo pipefail

PRODUCTION_DIR="${1:?Usage: $0 <production-dir> <new-version-dir>}"
NEW_VERSION_DIR="${2:?Usage: $0 <production-dir> <new-version-dir>}"

PATCH_FILE="/tmp/deployment-patch-$(date +%Y%m%d-%H%M%S).patch"
VALIDATION_SNAPSHOT="/tmp/validation-$$.diffa"

cleanup() {
    rm -f "$VALIDATION_SNAPSHOT"
}
trap cleanup EXIT

echo "=== Deployment with Rollback Support ==="
echo "Production: $PRODUCTION_DIR"
echo "New version: $NEW_VERSION_DIR"
echo "Patch file: $PATCH_FILE"
echo

# Create reversible patch
echo "📦 Creating reversible deployment patch..."
if ! diffa patch create "$PRODUCTION_DIR" "$NEW_VERSION_DIR" \
    -o "$PATCH_FILE" --reversible; then
    echo "❌ Failed to create patch"
    exit 1
fi
echo "✅ Patch created: $PATCH_FILE"
echo

# Show what will be deployed (dry-run)
echo "🔍 Deployment plan (dry-run):"
diffa patch apply "$PATCH_FILE" "$PRODUCTION_DIR" --dry-run
echo

# Confirm deployment
read -p "Proceed with deployment? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled"
    rm -f "$PATCH_FILE"
    exit 0
fi

# Apply patch
echo "🚀 Deploying..."
if ! diffa patch apply "$PATCH_FILE" "$PRODUCTION_DIR"; then
    echo "❌ Deployment failed!"
    echo
    echo "🔄 Rolling back..."
    if diffa patch revert "$PATCH_FILE" "$PRODUCTION_DIR"; then
        echo "✅ Rollback successful - production restored"
    else
        echo "❌ ROLLBACK FAILED - manual intervention required!"
        echo "Patch file: $PATCH_FILE"
        exit 2
    fi
    exit 1
fi

echo "✅ Deployment successful"
echo

# Validate deployment
echo "🔍 Validating deployment..."
diffa snapshot "$NEW_VERSION_DIR" -o "$VALIDATION_SNAPSHOT"
if diffa verify "$PRODUCTION_DIR" "$VALIDATION_SNAPSHOT"; then
    echo "✅ Validation passed - production matches expected state"
    echo
    echo "📄 Rollback patch saved: $PATCH_FILE"
    echo "   To rollback: diffa patch revert $PATCH_FILE $PRODUCTION_DIR"
else
    echo "⚠️  Validation failed - production doesn't match expected state"
    echo
    echo "🔄 Rolling back..."
    if diffa patch revert "$PATCH_FILE" "$PRODUCTION_DIR"; then
        echo "✅ Rollback successful"
    else
        echo "❌ ROLLBACK FAILED - manual intervention required!"
        exit 2
    fi
    exit 1
fi
