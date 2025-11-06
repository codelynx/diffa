import Foundation
import Diffalla
import Crypto

// MARK: - Main Entry Point

Task {
    do {
        let arguments = CommandLine.arguments
        let dataset = arguments.count > 1 ? arguments[1] : "small"

        print("Diffalla Benchmark Runner")
        print("=========================")
        print("Dataset: \(dataset)")
        print("Date: \(ISO8601DateFormatter().string(from: Date()))")
        print()

        var results: [BenchmarkResult] = []

        switch dataset {
        case "small":
            results.append(try await BenchmarkRunner.runSmallBenchmarks())
        case "medium":
            results.append(try await BenchmarkRunner.runMediumBenchmarks())
        case "large":
            results.append(try await BenchmarkRunner.runLargeBenchmarks())
        case "all":
            results.append(try await BenchmarkRunner.runSmallBenchmarks())
            results.append(try await BenchmarkRunner.runMediumBenchmarks())
            results.append(try await BenchmarkRunner.runLargeBenchmarks())
        default:
            print("Unknown dataset: \(dataset)")
            print("Usage: diffalla-benchmark [small|medium|large|all]")
            exit(1)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(results)
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print("\nResults JSON:")
            print(jsonString)
        }

        exit(0)
    } catch {
        print("Error running benchmarks: \(error)")
        exit(1)
    }
}

RunLoop.main.run()

// MARK: - Benchmark Runner

struct BenchmarkRunner {
    static func runSmallBenchmarks() async throws -> BenchmarkResult {
        print("Running small dataset benchmarks (1,000 files)...")

        let generator = DatasetGenerator()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("diffalla-bench-small-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try generator.generateDataset(
            at: tempDir,
            fileCount: 1000,
            avgFileSize: 5 * 1024, // 5 KB
            seed: 42
        )

        defer { BenchmarkRunner.cleanupHashCache(for: tempDir) }

        let metrics = try await measureSnapshot(directory: tempDir, label: "small-1k-files")

        return BenchmarkResult(
            dataset: "small",
            fileCount: 1000,
            totalSize: metrics.totalSize,
            snapshotTime: metrics.snapshotTime,
            snapshotTimeWithCache: metrics.snapshotTimeWithCache,
            comparisonTime: metrics.comparisonTime,
            peakMemoryMB: metrics.peakMemoryMB
        )
    }

    static func runMediumBenchmarks() async throws -> BenchmarkResult {
        print("Running medium dataset benchmarks (10,000 files)...")

        let generator = DatasetGenerator()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("diffalla-bench-medium-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try generator.generateDataset(
            at: tempDir,
            fileCount: 10_000,
            avgFileSize: 30 * 1024, // 30 KB
            seed: 42
        )

        defer { BenchmarkRunner.cleanupHashCache(for: tempDir) }

        let metrics = try await measureSnapshot(directory: tempDir, label: "medium-10k-files")

        return BenchmarkResult(
            dataset: "medium",
            fileCount: 10_000,
            totalSize: metrics.totalSize,
            snapshotTime: metrics.snapshotTime,
            snapshotTimeWithCache: metrics.snapshotTimeWithCache,
            comparisonTime: metrics.comparisonTime,
            peakMemoryMB: metrics.peakMemoryMB
        )
    }

    static func runLargeBenchmarks() async throws -> BenchmarkResult {
        print("Running large dataset benchmarks (100,000 files)...")

        let generator = DatasetGenerator()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("diffalla-bench-large-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try generator.generateDataset(
            at: tempDir,
            fileCount: 100_000,
            avgFileSize: 50 * 1024, // 50 KB
            seed: 42
        )

        defer { BenchmarkRunner.cleanupHashCache(for: tempDir) }

        let metrics = try await measureSnapshot(directory: tempDir, label: "large-100k-files")

        return BenchmarkResult(
            dataset: "large",
            fileCount: 100_000,
            totalSize: metrics.totalSize,
            snapshotTime: metrics.snapshotTime,
            snapshotTimeWithCache: metrics.snapshotTimeWithCache,
            comparisonTime: metrics.comparisonTime,
            peakMemoryMB: metrics.peakMemoryMB
        )
    }

    static func measureSnapshot(directory: URL, label: String) async throws -> SnapshotMetrics {
        let snapshotURL = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(label).db")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }

        let engine = SnapshotEngine()
        let coldOptions = ScanOptions(useHashCache: false, useParallelHashing: false)
        let cachedOptions = ScanOptions(useHashCache: true, useParallelHashing: true)

        // Measure first snapshot (no cache)
        let startTime1 = Date()
        let snapshot1 = try await engine.createSnapshot(
            from: directory,
            saveTo: snapshotURL,
            options: coldOptions
        )
        let snapshotTime = Date().timeIntervalSince(startTime1)

        print("  First snapshot: \(String(format: "%.2f", snapshotTime))s")

        // Warm up cache (not timed) so the next run has real cache hits
        try? FileManager.default.removeItem(at: snapshotURL)
        print("  Warming cache...")
        _ = try await engine.createSnapshot(
            from: directory,
            saveTo: snapshotURL,
            options: cachedOptions
        )

        // Measure second snapshot (with cache hits)
        try? FileManager.default.removeItem(at: snapshotURL)
        let startTime2 = Date()
        let snapshot2 = try await engine.createSnapshot(
            from: directory,
            saveTo: snapshotURL,
            options: cachedOptions
        )
        let snapshotTimeWithCache = Date().timeIntervalSince(startTime2)

        print("  Cached snapshot: \(String(format: "%.2f", snapshotTimeWithCache))s (\(String(format: "%.1f", snapshotTime / snapshotTimeWithCache))x speedup)")

        // Measure comparison
        let startTime3 = Date()
        _ = try Difference.compare(source: snapshot1, destination: snapshot2)
        let comparisonTime = Date().timeIntervalSince(startTime3)

        print("  Comparison: \(String(format: "%.3f", comparisonTime))s")

        // Get memory usage (simplified)
        let peakMemoryMB: Double = 0  // TODO: Implement platform-specific memory measurement
        print("  Memory: N/A")

        let metrics = SnapshotMetrics(
            totalSize: snapshot1.metadata.totalSize,
            snapshotTime: snapshotTime,
            snapshotTimeWithCache: snapshotTimeWithCache,
            comparisonTime: comparisonTime,
            peakMemoryMB: peakMemoryMB
        )

        return metrics
    }

    // MARK: - Cache Cleanup Helpers

    static func cleanupHashCache(for directory: URL) {
        guard let cacheFile = hashCacheFileURL(for: directory) else {
            return
        }
        try? FileManager.default.removeItem(at: cacheFile)
    }

    static func hashCacheFileURL(for directory: URL) -> URL? {
        guard let data = directory.path.data(using: .utf8) else {
            return nil
        }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cacheDir = homeDir.appendingPathComponent(".diffalla/cache")
        let pathHash = sha256Hex(data: data)
        return cacheDir.appendingPathComponent("\(pathHash).db")
    }

    static func sha256Hex(data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

struct SnapshotMetrics {
    let totalSize: Int64
    let snapshotTime: TimeInterval
    let snapshotTimeWithCache: TimeInterval
    let comparisonTime: TimeInterval
    let peakMemoryMB: Double
}

struct BenchmarkResult: Codable {
    let dataset: String
    let fileCount: Int
    let totalSize: Int64
    let snapshotTime: TimeInterval
    let snapshotTimeWithCache: TimeInterval
    let comparisonTime: TimeInterval
    let peakMemoryMB: Double
}
