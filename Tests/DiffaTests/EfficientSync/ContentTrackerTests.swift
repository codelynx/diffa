import XCTest
@testable import Diffa

/// Tests for ContentTracker - safe, deterministic content tracking
final class ContentTrackerTests: XCTestCase {

    // MARK: - Test Helpers

    /// Mock implementation of SyncSnapshot for testing
    private class MockSnapshot: SyncSnapshot {
        private let files: [FileItem]

        init(files: [FileItem]) {
            self.files = files
        }

        func fileByPath(_ path: String) -> FileItem? {
            files.first { $0.path == path }
        }

        func filesByHash(_ hash: Data) -> [FileItem] {
            files.filter { $0.hash == hash }
        }

        func allFiles() -> [FileItem] {
            files.sorted { $0.path < $1.path }
        }
    }

    private func makeHash(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 16)
    }

    private func makeFileItem(path: String, hash: UInt8, size: Int64 = 100, mtime: Int64 = 1000) -> FileItem {
        FileItem(
            path: path,
            size: size,
            hash: makeHash(hash),
            mtime: mtime
        )
    }

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentTrackerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Tests

    func testSeedFromDestSnapshot() throws {
        // Dest has 3 files
        let destFile1 = makeFileItem(path: "a.txt", hash: 0xAA)
        let destFile2 = makeFileItem(path: "b.txt", hash: 0xBB)
        let destFile3 = makeFileItem(path: "c.txt", hash: 0xCC)

        let source = MockSnapshot(files: [])
        let dest = MockSnapshot(files: [destFile1, destFile2, destFile3])

        let tracker = ContentTracker(
            sourceSnapshot: source,
            destSnapshot: dest,
            destRoot: tempDir,
            operations: [],
            mode: .sync
        )

        // Should be able to look up all hashes
        XCTAssertNotNil(tracker.canonicalPath(for: makeHash(0xAA)))
        XCTAssertNotNil(tracker.canonicalPath(for: makeHash(0xBB)))
        XCTAssertNotNil(tracker.canonicalPath(for: makeHash(0xCC)))

        // Verify paths are correct
        let pathA = tracker.canonicalPath(for: makeHash(0xAA))
        XCTAssertTrue(pathA?.lastPathComponent == "a.txt")
    }

    func testPushModeFiltersImplicitDeletions() throws {
        // Source: [A, B]
        // Dest: [B, C]
        // Push mode: C is implicitly deleted (dest-only)

        let sourceFileA = makeFileItem(path: "A.txt", hash: 0xAA)
        let sourceFileB = makeFileItem(path: "B.txt", hash: 0xBB)
        let destFileB = makeFileItem(path: "B.txt", hash: 0xBB)
        let destFileC = makeFileItem(path: "C.txt", hash: 0xCC)

        let source = MockSnapshot(files: [sourceFileA, sourceFileB])
        let dest = MockSnapshot(files: [destFileB, destFileC])

        let tracker = ContentTracker(
            sourceSnapshot: source,
            destSnapshot: dest,
            destRoot: tempDir,
            operations: [],
            mode: .push  // Push mode: dest-only files are deleted
        )

        // B should be tracked (exists on both sides)
        XCTAssertNotNil(tracker.canonicalPath(for: makeHash(0xBB)))

        // C should NOT be tracked (will be implicitly deleted)
        XCTAssertNil(tracker.canonicalPath(for: makeHash(0xCC)))
    }

    func testSyncModeNoImplicitDeletions() throws {
        // Source: [A, B]
        // Dest: [B, C]
        // Sync mode: no implicit deletions (merge both sides)

        let sourceFileA = makeFileItem(path: "A.txt", hash: 0xAA)
        let sourceFileB = makeFileItem(path: "B.txt", hash: 0xBB)
        let destFileB = makeFileItem(path: "B.txt", hash: 0xBB)
        let destFileC = makeFileItem(path: "C.txt", hash: 0xCC)

        let source = MockSnapshot(files: [sourceFileA, sourceFileB])
        let dest = MockSnapshot(files: [destFileB, destFileC])

        let tracker = ContentTracker(
            sourceSnapshot: source,
            destSnapshot: dest,
            destRoot: tempDir,
            operations: [],
            mode: .sync  // Sync mode: no implicit deletions
        )

        // Both B and C should be tracked
        XCTAssertNotNil(tracker.canonicalPath(for: makeHash(0xBB)))
        XCTAssertNotNil(tracker.canonicalPath(for: makeHash(0xCC)), "Sync mode should not delete dest-only files")
    }

    func testMoveSourcePathNotAvailable() throws {
        // Dest has old.txt (hash: AA)
        // Operation: move old.txt → new.txt
        // Result: old.txt should NOT be tracked (path will change)

        let destFile = makeFileItem(path: "old.txt", hash: 0xAA)
        let source = MockSnapshot(files: [])
        let dest = MockSnapshot(files: [destFile])

        let operations = [
            FileOperation(
                action: .move(from: "old.txt"),
                path: "new.txt",
                localFile: destFile,
                remoteFile: destFile
            )
        ]

        let tracker = ContentTracker(
            sourceSnapshot: source,
            destSnapshot: dest,
            destRoot: tempDir,
            operations: operations,
            mode: .sync
        )

        // Hash should not be tracked (move source path is unavailable)
        XCTAssertNil(tracker.canonicalPath(for: makeHash(0xAA)),
                     "Move source paths should not be available for deduplication")
    }

    func testPathNormalizationSecurity() throws {
        // Test that path traversal attempts are blocked

        let maliciousFile = makeFileItem(path: "../../../etc/passwd", hash: 0xAA)
        let source = MockSnapshot(files: [])
        let dest = MockSnapshot(files: [maliciousFile])

        let tracker = ContentTracker(
            sourceSnapshot: source,
            destSnapshot: dest,
            destRoot: tempDir,
            operations: [],
            mode: .sync
        )

        // Malicious path should not be tracked
        // (normalization should reject paths outside destRoot)
        let result = tracker.canonicalPath(for: makeHash(0xAA))

        // Result should either be nil (rejected) or within tempDir
        if let path = result {
            XCTAssertTrue(path.path.hasPrefix(tempDir.path),
                         "Tracked paths must be under destRoot")
        }
    }

    func testDeterministicSeeding() throws {
        // Multiple files with same hash: first in sorted order is canonical

        let destFile1 = makeFileItem(path: "z/last.txt", hash: 0xAA)
        let destFile2 = makeFileItem(path: "a/first.txt", hash: 0xAA)
        let destFile3 = makeFileItem(path: "m/middle.txt", hash: 0xAA)

        let source = MockSnapshot(files: [])
        let dest = MockSnapshot(files: [destFile1, destFile2, destFile3])

        let tracker = ContentTracker(
            sourceSnapshot: source,
            destSnapshot: dest,
            destRoot: tempDir,
            operations: [],
            mode: .sync
        )

        // Should map to first in sorted order: "a/first.txt"
        let canonical = tracker.canonicalPath(for: makeHash(0xAA))
        XCTAssertNotNil(canonical)
        XCTAssertTrue(canonical?.path.hasSuffix("a/first.txt") ?? false,
                     "Should use first file in sorted order as canonical")
    }

    func testRecordWrittenContentTakesPrecedence() throws {
        // Seed with old.txt, then record new.txt
        // new.txt should take precedence

        let destFile = makeFileItem(path: "old.txt", hash: 0xAA)
        let source = MockSnapshot(files: [])
        let dest = MockSnapshot(files: [destFile])

        let tracker = ContentTracker(
            sourceSnapshot: source,
            destSnapshot: dest,
            destRoot: tempDir,
            operations: [],
            mode: .sync
        )

        // Initially maps to old.txt
        let initialPath = tracker.canonicalPath(for: makeHash(0xAA))
        XCTAssertTrue(initialPath?.lastPathComponent == "old.txt")

        // Record new content
        let newPath = tempDir.appendingPathComponent("new.txt")
        tracker.recordWrittenContent(hash: makeHash(0xAA), at: newPath)

        // Should now map to new.txt
        let updatedPath = tracker.canonicalPath(for: makeHash(0xAA))
        XCTAssertTrue(updatedPath?.lastPathComponent == "new.txt",
                     "Newly written content should take precedence")
    }

    func testExplicitDeletionsFiltered() throws {
        // Dest has [A, B, C]
        // Operations include: delete B
        // Result: B should not be tracked

        let destFileA = makeFileItem(path: "A.txt", hash: 0xAA)
        let destFileB = makeFileItem(path: "B.txt", hash: 0xBB)
        let destFileC = makeFileItem(path: "C.txt", hash: 0xCC)

        let source = MockSnapshot(files: [])
        let dest = MockSnapshot(files: [destFileA, destFileB, destFileC])

        let operations = [
            FileOperation(action: .delete, path: "B.txt", localFile: destFileB)
        ]

        let tracker = ContentTracker(
            sourceSnapshot: source,
            destSnapshot: dest,
            destRoot: tempDir,
            operations: operations,
            mode: .sync
        )

        // A and C should be tracked
        XCTAssertNotNil(tracker.canonicalPath(for: makeHash(0xAA)))
        XCTAssertNotNil(tracker.canonicalPath(for: makeHash(0xCC)))

        // B should NOT be tracked (explicit deletion)
        XCTAssertNil(tracker.canonicalPath(for: makeHash(0xBB)),
                    "Explicitly deleted files should not be tracked")
    }
}
