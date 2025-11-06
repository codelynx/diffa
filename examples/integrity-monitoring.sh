#!/bin/bash
# integrity-monitoring.sh - Monitor directory for unauthorized changes
#
# Usage:
#   # Create baseline
#   ./integrity-monitoring.sh init /etc /root/baselines/etc.db
#
#   # Check for changes
#   ./integrity-monitoring.sh check /etc /root/baselines/etc.db
#
#   # Update baseline (after authorized changes)
#   ./integrity-monitoring.sh update /etc /root/baselines/etc.db
#
# Use with cron:
#   */30 * * * * /usr/local/bin/integrity-monitoring.sh check /etc /root/baselines/etc.db

set -euo pipefail

COMMAND="${1:?Usage: $0 <init|check|update> <directory> <baseline>}"
DIRECTORY="${2:?Usage: $0 <init|check|update> <directory> <baseline>}"
BASELINE="${3:?Usage: $0 <init|check|update> <directory> <baseline>}"

case "$COMMAND" in
    init)
        echo "=== Initializing Baseline ==="
        echo "Directory: $DIRECTORY"
        echo "Baseline: $BASELINE"
        echo

        # Create baseline directory if needed
        mkdir -p "$(dirname "$BASELINE")"

        # Create snapshot
        if diffalla snapshot "$DIRECTORY" -o "$BASELINE"; then
            echo
            echo "✅ Baseline created: $BASELINE"
            echo
            echo "Next steps:"
            echo "  Check: $0 check $DIRECTORY $BASELINE"
            echo "  Update: $0 update $DIRECTORY $BASELINE"
        else
            echo "❌ Failed to create baseline"
            exit 1
        fi
        ;;

    check)
        echo "=== Integrity Check ==="
        echo "Directory: $DIRECTORY"
        echo "Baseline: $BASELINE"
        echo

        if [ ! -f "$BASELINE" ]; then
            echo "❌ Baseline not found: $BASELINE"
            echo "Run: $0 init $DIRECTORY $BASELINE"
            exit 1
        fi

        # Verify directory matches baseline
        if diffalla verify "$DIRECTORY" "$BASELINE" --show-diff; then
            echo
            echo "✅ Integrity check passed - no changes detected"
            exit 0
        else
            echo
            echo "⚠️  INTEGRITY CHECK FAILED - unauthorized changes detected!"
            echo
            echo "Actions:"
            echo "  1. Investigate changes listed above"
            echo "  2. If changes are authorized:"
            echo "     $0 update $DIRECTORY $BASELINE"
            echo "  3. If changes are unauthorized:"
            echo "     - Restore from backup"
            echo "     - Investigate security incident"
            exit 1
        fi
        ;;

    update)
        echo "=== Updating Baseline ==="
        echo "Directory: $DIRECTORY"
        echo "Baseline: $BASELINE"
        echo

        if [ ! -f "$BASELINE" ]; then
            echo "⚠️  Baseline doesn't exist, creating new one..."
            exec "$0" init "$DIRECTORY" "$BASELINE"
        fi

        # Show changes before updating
        echo "Changes since last baseline:"
        echo
        if diffalla verify "$DIRECTORY" "$BASELINE" --show-diff; then
            echo "No changes to record"
            exit 0
        fi

        echo
        read -p "Update baseline with these changes? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Baseline update cancelled"
            exit 0
        fi

        # Backup old baseline
        BACKUP="$BASELINE.$(date +%Y%m%d-%H%M%S).bak"
        cp "$BASELINE" "$BACKUP"
        echo "📦 Old baseline backed up: $BACKUP"

        # Create new baseline
        if diffalla snapshot "$DIRECTORY" -o "$BASELINE"; then
            echo "✅ Baseline updated: $BASELINE"
        else
            echo "❌ Failed to update baseline"
            echo "Old baseline preserved: $BACKUP"
            exit 1
        fi
        ;;

    *)
        echo "❌ Unknown command: $COMMAND"
        echo "Usage: $0 <init|check|update> <directory> <baseline>"
        exit 1
        ;;
esac
