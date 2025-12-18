#!/bin/bash
# Benchmark dataset generator for EfficientSync performance testing
#
# Usage:
#   ./Tests/Fixtures/generate_benchmarks.sh [output_dir]
#
# Default output: /tmp/diffa-benchmarks
#
# Generates:
#   - small: 1,000 files (~5 MB)
#   - medium: 10,000 files (~300 MB)

set -e

OUTPUT_DIR="${1:-/tmp/diffa-benchmarks}"
mkdir -p "$OUTPUT_DIR"

echo "Diffa Benchmark Dataset Generator"
echo "=================================="
echo "Output directory: $OUTPUT_DIR"
echo ""

# Small: 1,000 files (~5 MB)
echo "Generating small dataset (1,000 files, ~5 MB)..."
mkdir -p "$OUTPUT_DIR/small"
for i in $(seq 1 1000); do
    dd if=/dev/urandom of="$OUTPUT_DIR/small/file_$i.bin" bs=5120 count=1 2>/dev/null

    # Progress indicator every 100 files
    if [ $((i % 100)) -eq 0 ]; then
        echo "  Progress: $i/1000 files"
    fi
done
echo "  ✓ Small dataset complete"
echo ""

# Medium: 10,000 files (~300 MB)
echo "Generating medium dataset (10,000 files, ~300 MB)..."
mkdir -p "$OUTPUT_DIR/medium"
for i in $(seq 1 10000); do
    dd if=/dev/urandom of="$OUTPUT_DIR/medium/file_$i.bin" bs=30720 count=1 2>/dev/null

    # Progress indicator every 1000 files
    if [ $((i % 1000)) -eq 0 ]; then
        echo "  Progress: $i/10000 files"
    fi
done
echo "  ✓ Medium dataset complete"
echo ""

# Summary
echo "=================================="
echo "Datasets generated at $OUTPUT_DIR"
echo ""
echo "Small:  $(ls "$OUTPUT_DIR/small" | wc -l | tr -d ' ') files, $(du -sh "$OUTPUT_DIR/small" | cut -f1)"
echo "Medium: $(ls "$OUTPUT_DIR/medium" | wc -l | tr -d ' ') files, $(du -sh "$OUTPUT_DIR/medium" | cut -f1)"
echo "Total:  $(du -sh "$OUTPUT_DIR" | cut -f1)"
echo ""
echo "To clean up: rm -rf $OUTPUT_DIR"
