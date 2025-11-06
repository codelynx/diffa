#!/bin/bash
# bidirectional-sync.sh - Safely sync two directories with conflict handling
#
# Usage:
#   ./bidirectional-sync.sh /dir-a /dir-b [conflict-strategy]
#
# Conflict strategies:
#   - error (default) - abort on conflicts
#   - newest - keep newer file
#   - ask - interactive resolution (future)

set -euo pipefail

DIR_A="${1:?Usage: $0 <dir-a> <dir-b> [conflict-strategy]}"
DIR_B="${2:?Usage: $0 <dir-a> <dir-b> [conflict-strategy]}"
CONFLICT_STRATEGY="${3:-error}"

echo "=== Bidirectional Sync ==="
echo "Directory A: $DIR_A"
echo "Directory B: $DIR_B"
echo "Conflict strategy: $CONFLICT_STRATEGY"
echo

# Validate conflict strategy
case "$CONFLICT_STRATEGY" in
    error|newest|source-wins|dest-wins)
        ;;
    *)
        echo "❌ Invalid conflict strategy: $CONFLICT_STRATEGY"
        echo "Valid options: error, newest, source-wins, dest-wins"
        exit 1
        ;;
esac

# Dry-run first
echo "🔍 Analyzing changes (dry-run)..."
echo
if ! diffalla sync "$DIR_A" "$DIR_B" --bidirectional \
    --conflict-resolution "$CONFLICT_STRATEGY" --dry-run; then
    if [ "$CONFLICT_STRATEGY" = "error" ]; then
        echo
        echo "⚠️  Conflicts detected!"
        echo "Options:"
        echo "  1. Resolve conflicts manually"
        echo "  2. Use --conflict-resolution newest (automatic)"
        echo "  3. Use --conflict-resolution source-wins (prefer A)"
        echo "  4. Use --conflict-resolution dest-wins (prefer B)"
        exit 1
    fi
fi
echo

# Confirm sync
if [ "$CONFLICT_STRATEGY" != "error" ]; then
    echo "⚠️  Using automatic conflict resolution: $CONFLICT_STRATEGY"
    read -p "This may overwrite files. Proceed? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Sync cancelled"
        exit 0
    fi
fi

# Perform actual sync
echo "🔄 Syncing..."
echo
if diffalla sync "$DIR_A" "$DIR_B" --bidirectional \
    --conflict-resolution "$CONFLICT_STRATEGY" --progress; then
    echo
    echo "✅ Sync completed successfully"
else
    echo
    echo "❌ Sync failed - see errors above"
    exit 1
fi

# Verify both directories are now identical
echo
echo "🔍 Verifying sync..."
if diffalla compare "$DIR_A" "$DIR_B" --summary; then
    echo "✅ Verification passed - directories are identical"
else
    echo "⚠️  Verification failed - directories still differ"
    echo "This may indicate sync errors or exclusions"
    exit 1
fi
