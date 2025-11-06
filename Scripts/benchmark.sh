#!/bin/bash
# Diffalla Benchmark Harness
#
# Opt-in benchmarking script (NOT run during swift test).
# Runs performance benchmarks and outputs JSON results.
#
# Usage:
#   ./Scripts/benchmark.sh [small|medium|large|all]
#
# Output:
#   - Console output with timing and memory stats
#   - JSON results file in benchmarks/results-<date>.json
#
# Note: This is NOT part of CI. Run manually for performance validation.

set -e

# Parse arguments
DATASET="${1:-small}"

# Create benchmarks directory
mkdir -p benchmarks

# Generate output filename with timestamp
TIMESTAMP=$(date +"%Y-%m-%d-%H%M%S")
OUTPUT_FILE="benchmarks/results-${TIMESTAMP}.json"

echo "========================================="
echo "Diffalla Benchmark Harness"
echo "========================================="
echo "Dataset: ${DATASET}"
echo "Output: ${OUTPUT_FILE}"
echo ""

# Build benchmark executable in release mode for accurate performance
echo "Building benchmark executable (release mode)..."
swift build -c release --product diffalla-benchmark

# Run benchmarks and capture output
echo ""
echo "Running benchmarks..."
echo ""

# Run and tee output to both console and file
.build/release/diffalla-benchmark "${DATASET}" | tee "${OUTPUT_FILE}.log"

# Extract JSON from output (everything after "Results JSON:")
echo ""
echo "Extracting JSON results..."
sed -n '/Results JSON:/,$p' "${OUTPUT_FILE}.log" | tail -n +2 > "${OUTPUT_FILE}"

# Clean up log file
rm "${OUTPUT_FILE}.log"

echo ""
echo "========================================="
echo "Benchmark complete!"
echo "Results saved to: ${OUTPUT_FILE}"
echo "========================================="
echo ""

# Display summary
if command -v jq &> /dev/null; then
    echo "Summary:"
    jq -r '.[] | "\(.dataset): \(.fileCount) files, snapshot: \(.snapshotTime)s, cached: \(.snapshotTimeWithCache)s (speedup: \((.snapshotTime / .snapshotTimeWithCache) | round)x)"' "${OUTPUT_FILE}"
else
    echo "Install jq for formatted summary: brew install jq"
    cat "${OUTPUT_FILE}"
fi
