import XCTest
@testable import Diffalla
import Crypto

final class HashCacheIntegrationTests: XCTestCase {

    // MARK: - Step 1: Hash Cache Integration Tests

    func testSnapshotWithHashCacheEnabled() async throws {
        // Create temporary directory structure
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scanDir = tempRoot.appendingPathComponent("scan")
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Create test files in scan directory
        let file1 = scanDir.appendingPathComponent("file1.txt")
        let file2 = scanDir.appendingPathComponent("file2.txt")
        try "Content 1".write(to: file1, atomically: true, encoding: .utf8)
        try "Content 2".write(to: file2, atomically: true, encoding: .utf8)

        // Create snapshot with cache enabled (stored outside scan directory)
        let snapshotURL = tempRoot.appendingPathComponent("snapshot.db")
        let cacheDir = tempRoot.appendingPathComponent("cache")

        var options = ScanOptions()
        options.useHashCache = true
        options.hashCacheDirectory = cacheDir

        let engine = SnapshotEngine()
        let snapshot = try await engine.createSnapshot(
            from: scanDir,
            saveTo: snapshotURL,
            options: options
        )

        // Verify snapshot created successfully
        XCTAssertEqual(snapshot.metadata.totalFiles, 2, "Should have 2 files")

        // Verify cache directory was created
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDir.path), "Cache directory should exist")
    }

    func testSnapshotWithHashCacheDisabled() async throws {
        // Create temporary directory structure
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scanDir = tempRoot.appendingPathComponent("scan")
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Create test files in scan directory
        let file1 = scanDir.appendingPathComponent("file1.txt")
        try "Content 1".write(to: file1, atomically: true, encoding: .utf8)

        // Create snapshot with cache disabled (default, stored outside scan directory)
        let snapshotURL = tempRoot.appendingPathComponent("snapshot.db")
        let cacheDir = tempRoot.appendingPathComponent("cache")

        var options = ScanOptions()
        options.useHashCache = false
        options.hashCacheDirectory = cacheDir

        let engine = SnapshotEngine()
        let snapshot = try await engine.createSnapshot(
            from: scanDir,
            saveTo: snapshotURL,
            options: options
        )

        // Verify snapshot created successfully
        XCTAssertEqual(snapshot.metadata.totalFiles, 1, "Should have 1 file")

        // Verify cache directory was NOT created (since cache is disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDir.path), "Cache directory should not exist when cache disabled")
    }

    func testSnapshotCacheHit() async throws {
        // Create temporary directory structure
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scanDir = tempRoot.appendingPathComponent("scan")
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Create test files in scan directory
        let file1 = scanDir.appendingPathComponent("file1.txt")
        let file2 = scanDir.appendingPathComponent("file2.txt")
        try "Content 1".write(to: file1, atomically: true, encoding: .utf8)
        try "Content 2".write(to: file2, atomically: true, encoding: .utf8)

        let snapshot1URL = tempRoot.appendingPathComponent("snapshot1.db")
        let snapshot2URL = tempRoot.appendingPathComponent("snapshot2.db")
        let cacheDir = tempRoot.appendingPathComponent("cache")

        var options = ScanOptions()
        options.useHashCache = true
        options.hashCacheDirectory = cacheDir

        let engine = SnapshotEngine()

        // First scan: should have all cache misses
        var firstScanHits = 0
        var firstScanMisses = 0
        _ = try await engine.createSnapshot(
            from: scanDir,
            saveTo: snapshot1URL,
            options: options,
            progress: { progress in
                firstScanHits = progress.cacheHits
                firstScanMisses = progress.cacheMisses
            }
        )

        // First scan should have 0 hits, 2 misses
        XCTAssertEqual(firstScanHits, 0, "First scan should have 0 cache hits")
        XCTAssertEqual(firstScanMisses, 2, "First scan should have 2 cache misses")

        // Second scan: should have all cache hits (files unchanged)
        var secondScanHits = 0
        var secondScanMisses = 0
        _ = try await engine.createSnapshot(
            from: scanDir,
            saveTo: snapshot2URL,
            options: options,
            progress: { progress in
                secondScanHits = progress.cacheHits
                secondScanMisses = progress.cacheMisses
            }
        )

        // Second scan should have 2 hits, 0 misses
        XCTAssertEqual(secondScanHits, 2, "Second scan should have 2 cache hits")
        XCTAssertEqual(secondScanMisses, 0, "Second scan should have 0 cache misses")

        // Verify cache hit rate is 100%
        let hitRate = Double(secondScanHits) / Double(secondScanHits + secondScanMisses)
        XCTAssertEqual(hitRate, 1.0, accuracy: 0.01, "Cache hit rate should be 100%")
    }

    func testSnapshotCacheMiss() async throws {
        // Create temporary directory structure
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scanDir = tempRoot.appendingPathComponent("scan")
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Create test file in scan directory
        let file1 = scanDir.appendingPathComponent("file1.txt")
        try "Content 1".write(to: file1, atomically: true, encoding: .utf8)

        let snapshot1URL = tempRoot.appendingPathComponent("snapshot1.db")
        let snapshot2URL = tempRoot.appendingPathComponent("snapshot2.db")
        let cacheDir = tempRoot.appendingPathComponent("cache")

        var options = ScanOptions()
        options.useHashCache = true
        options.hashCacheDirectory = cacheDir

        let engine = SnapshotEngine()

        // First scan
        _ = try await engine.createSnapshot(
            from: scanDir,
            saveTo: snapshot1URL,
            options: options
        )

        // Modify the file (change content)
        try "Modified Content".write(to: file1, atomically: true, encoding: .utf8)

        // Second scan: should have cache miss due to modification
        var secondScanHits = 0
        var secondScanMisses = 0
        _ = try await engine.createSnapshot(
            from: scanDir,
            saveTo: snapshot2URL,
            options: options,
            progress: { progress in
                secondScanHits = progress.cacheHits
                secondScanMisses = progress.cacheMisses
            }
        )

        // Second scan should have 0 hits, 1 miss (file was modified)
        XCTAssertEqual(secondScanHits, 0, "Second scan should have 0 cache hits (file modified)")
        XCTAssertEqual(secondScanMisses, 1, "Second scan should have 1 cache miss")
    }

    func testSnapshotCachePrune() async throws {
        // Create temporary directory structure
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scanDir = tempRoot.appendingPathComponent("scan")
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Create test files in scan directory
        let file1 = scanDir.appendingPathComponent("file1.txt")
        let file2 = scanDir.appendingPathComponent("file2.txt")
        try "Content 1".write(to: file1, atomically: true, encoding: .utf8)
        try "Content 2".write(to: file2, atomically: true, encoding: .utf8)

        let snapshot1URL = tempRoot.appendingPathComponent("snapshot1.db")
        let snapshot2URL = tempRoot.appendingPathComponent("snapshot2.db")
        let cacheDir = tempRoot.appendingPathComponent("cache")

        var options = ScanOptions()
        options.useHashCache = true
        options.hashCacheDirectory = cacheDir

        let engine = SnapshotEngine()

        // First scan: cache both files
        _ = try await engine.createSnapshot(
            from: scanDir,
            saveTo: snapshot1URL,
            options: options
        )

        // Delete file2
        try FileManager.default.removeItem(at: file2)

        // Second scan: should prune file2 from cache
        var secondScanHits = 0
        var secondScanMisses = 0
        _ = try await engine.createSnapshot(
            from: scanDir,
            saveTo: snapshot2URL,
            options: options,
            progress: { progress in
                secondScanHits = progress.cacheHits
                secondScanMisses = progress.cacheMisses
            }
        )

        // Second scan should have 1 hit (file1), 0 misses
        XCTAssertEqual(secondScanHits, 1, "Second scan should have 1 cache hit (file1)")
        XCTAssertEqual(secondScanMisses, 0, "Second scan should have 0 cache misses")

        // Verify cache was pruned by checking cache directly
        // Open the cache database and verify file2 is not present
        let directoryPath = scanDir.path
        let pathHash = directoryPath.data(using: .utf8)!.sha256Hex()
        let cacheURL = cacheDir.appendingPathComponent("\(pathHash).db")

        let cache = try HashCache(at: cacheURL)

        // Try to lookup file2 in cache (should return nil since it was pruned)
        let file2Hash = try cache.lookup(path: "file2.txt", size: 9, modificationDate: Date())
        XCTAssertNil(file2Hash, "file2 should have been pruned from cache")
    }
}

// Extension to compute SHA256 for testing
extension Data {
    func sha256Hex() -> String {
        let hash = SHA256.hash(data: self)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
