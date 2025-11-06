import XCTest
@testable import Diffalla

final class ParallelHashingTests: XCTestCase {

    func testParallelHasherComputesExpectedHash() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("sample.txt")
        try "parallel hashing data".write(to: fileURL, atomically: true, encoding: .utf8)

        let hasher = ParallelHasher(maxConcurrentHashes: 4)
        let parallelHash = try hasher.hashFile(at: fileURL)
        let directHash = try FileSystemItem.computeHash(at: fileURL)

        XCTAssertEqual(parallelHash, directHash, "Parallel hasher should match direct hash computation")
    }

    func testSnapshotParallelHashingMatchesSequential() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDir = tempDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for index in 0..<5 {
            let url = sourceDir.appendingPathComponent("file\(index).txt")
            try "content-\(index)".write(to: url, atomically: true, encoding: .utf8)
        }

        let engine = SnapshotEngine()

        var sequentialOptions = ScanOptions()
        let sequentialItems = try await engine.scanDirectory(at: sourceDir, options: sequentialOptions)

        var parallelOptions = ScanOptions()
        parallelOptions.useParallelHashing = true
        parallelOptions.maxConcurrentHashing = 2
        let parallelItems = try await engine.scanDirectory(at: sourceDir, options: parallelOptions)

        let sequentialMap = Dictionary(uniqueKeysWithValues: sequentialItems.map { ($0.path, $0.sha256 ?? "") })
        let parallelMap = Dictionary(uniqueKeysWithValues: parallelItems.map { ($0.path, $0.sha256 ?? "") })

        XCTAssertEqual(sequentialMap, parallelMap, "Parallel hashing should produce identical results")
    }

    func testParallelHashingWithHashCacheReportsHits() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDir = tempDir.appendingPathComponent("source")
        let snapshotOne = tempDir.appendingPathComponent("snapshot1.db")
        let snapshotTwo = tempDir.appendingPathComponent("snapshot2.db")
        let cacheDir = tempDir.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for index in 0..<3 {
            let url = sourceDir.appendingPathComponent("file\(index).txt")
            try "payload-\(index)".write(to: url, atomically: true, encoding: .utf8)
        }

        var options = ScanOptions()
        options.useHashCache = true
        options.hashCacheDirectory = cacheDir
        options.useParallelHashing = true
        options.maxConcurrentHashing = 3

        let engine = SnapshotEngine()

        _ = try await engine.createSnapshot(from: sourceDir, saveTo: snapshotOne, options: options)

        var cacheHits = 0
        var cacheMisses = 0
        _ = try await engine.createSnapshot(
            from: sourceDir,
            saveTo: snapshotTwo,
            options: options,
            progress: { progress in
                cacheHits = progress.cacheHits
                cacheMisses = progress.cacheMisses
            }
        )

        XCTAssertEqual(cacheHits, 3)
        XCTAssertEqual(cacheMisses, 0)
    }
}
