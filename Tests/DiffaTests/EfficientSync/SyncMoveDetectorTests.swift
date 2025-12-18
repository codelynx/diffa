import XCTest
@testable import Diffa

/// Tests for SyncMoveDetector - deterministic hash-based move detection
final class SyncMoveDetectorTests: XCTestCase {

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

    // MARK: - Tests

    func testSimpleRename() throws {
        let detector = SyncMoveDetector()

        let sourceFile = makeFileItem(path: "new.txt", hash: 0xAA)
        let destFile = makeFileItem(path: "old.txt", hash: 0xAA)

        let source = MockSnapshot(files: [sourceFile])
        let dest = MockSnapshot(files: [destFile])

        var operations: [FileOperation] = [
            FileOperation(action: .delete, path: "old.txt", localFile: destFile),
            FileOperation(action: .add, path: "new.txt", remoteFile: sourceFile)
        ]

        detector.detectMoves(source: source, dest: dest, operations: &operations)

        // Should have 1 move operation
        XCTAssertEqual(operations.count, 1)
        guard case .move(let from) = operations[0].action else {
            XCTFail("Expected move operation")
            return
        }
        XCTAssertEqual(from, "old.txt")
        XCTAssertEqual(operations[0].path, "new.txt")
        XCTAssertEqual(operations[0].hash, makeHash(0xAA))
    }

    func testMultipleFilesWithSameHash() throws {
        let detector = SyncMoveDetector()

        // Source: album1/photo.jpg, album2/photo.jpg (both hash: 0xBB)
        let sourceFile1 = makeFileItem(path: "album1/photo.jpg", hash: 0xBB)
        let sourceFile2 = makeFileItem(path: "album2/photo.jpg", hash: 0xBB)

        // Dest: old/img1.jpg, old/img2.jpg (both hash: 0xBB)
        let destFile1 = makeFileItem(path: "old/img1.jpg", hash: 0xBB)
        let destFile2 = makeFileItem(path: "old/img2.jpg", hash: 0xBB)

        let source = MockSnapshot(files: [sourceFile1, sourceFile2])
        let dest = MockSnapshot(files: [destFile1, destFile2])

        var operations: [FileOperation] = [
            FileOperation(action: .delete, path: "old/img1.jpg", localFile: destFile1),
            FileOperation(action: .delete, path: "old/img2.jpg", localFile: destFile2),
            FileOperation(action: .add, path: "album1/photo.jpg", remoteFile: sourceFile1),
            FileOperation(action: .add, path: "album2/photo.jpg", remoteFile: sourceFile2)
        ]

        detector.detectMoves(source: source, dest: dest, operations: &operations)

        // Should have 2 move operations
        XCTAssertEqual(operations.count, 2)

        // Verify deterministic pairing (sorted by path)
        let moves = operations.sorted { $0.path < $1.path }

        guard case .move(let from1) = moves[0].action else {
            XCTFail("Expected move operation")
            return
        }
        XCTAssertEqual(from1, "old/img1.jpg")  // First in sorted delete list
        XCTAssertEqual(moves[0].path, "album1/photo.jpg")  // First in sorted add list

        guard case .move(let from2) = moves[1].action else {
            XCTFail("Expected move operation")
            return
        }
        XCTAssertEqual(from2, "old/img2.jpg")  // Second in sorted delete list
        XCTAssertEqual(moves[1].path, "album2/photo.jpg")  // Second in sorted add list
    }

    func testNonMatchingCountsStayAsAddDelete() throws {
        let detector = SyncMoveDetector()

        // Source has 3 files with hash 0xCC
        let sourceFile1 = makeFileItem(path: "new1.txt", hash: 0xCC)
        let sourceFile2 = makeFileItem(path: "new2.txt", hash: 0xCC)
        let sourceFile3 = makeFileItem(path: "new3.txt", hash: 0xCC)

        // Dest has only 2 files with hash 0xCC
        let destFile1 = makeFileItem(path: "old1.txt", hash: 0xCC)
        let destFile2 = makeFileItem(path: "old2.txt", hash: 0xCC)

        let source = MockSnapshot(files: [sourceFile1, sourceFile2, sourceFile3])
        let dest = MockSnapshot(files: [destFile1, destFile2])

        var operations: [FileOperation] = [
            FileOperation(action: .delete, path: "old1.txt", localFile: destFile1),
            FileOperation(action: .delete, path: "old2.txt", localFile: destFile2),
            FileOperation(action: .add, path: "new1.txt", remoteFile: sourceFile1),
            FileOperation(action: .add, path: "new2.txt", remoteFile: sourceFile2),
            FileOperation(action: .add, path: "new3.txt", remoteFile: sourceFile3)
        ]

        detector.detectMoves(source: source, dest: dest, operations: &operations)

        // Should pair 2 and leave 1 add
        let moves = operations.filter { if case .move = $0.action { return true } else { return false } }
        let adds = operations.filter { if case .add = $0.action { return true } else { return false } }

        XCTAssertEqual(moves.count, 2, "Should have 2 move operations (min of 2 and 3)")
        XCTAssertEqual(adds.count, 1, "Should have 1 add operation remaining")
        XCTAssertEqual(operations.count, 3, "Total should be 2 moves + 1 add")
    }

    func testDeterminism() throws {
        let detector = SyncMoveDetector()

        let sourceFile1 = makeFileItem(path: "z/file1.txt", hash: 0xDD)
        let sourceFile2 = makeFileItem(path: "a/file2.txt", hash: 0xDD)

        let destFile1 = makeFileItem(path: "x/old1.txt", hash: 0xDD)
        let destFile2 = makeFileItem(path: "b/old2.txt", hash: 0xDD)

        let source = MockSnapshot(files: [sourceFile1, sourceFile2])
        let dest = MockSnapshot(files: [destFile1, destFile2])

        // Run detection 10 times and verify same result
        var previousResult: [FileOperation]?

        for _ in 0..<10 {
            var operations: [FileOperation] = [
                FileOperation(action: .delete, path: "x/old1.txt", localFile: destFile1),
                FileOperation(action: .delete, path: "b/old2.txt", localFile: destFile2),
                FileOperation(action: .add, path: "z/file1.txt", remoteFile: sourceFile1),
                FileOperation(action: .add, path: "a/file2.txt", remoteFile: sourceFile2)
            ]

            detector.detectMoves(source: source, dest: dest, operations: &operations)

            // Sort for comparison
            let sortedOps = operations.sorted { $0.path < $1.path }

            if let prev = previousResult {
                XCTAssertEqual(sortedOps.count, prev.count, "Should have same number of operations")

                for (i, op) in sortedOps.enumerated() {
                    XCTAssertEqual(op.path, prev[i].path, "Path should match at index \(i)")
                    XCTAssertEqual(op.action, prev[i].action, "Action should match at index \(i)")
                }
            }

            previousResult = sortedOps
        }

        // Verify the pairing is alphabetically sorted
        guard let result = previousResult else {
            XCTFail("Should have run at least once")
            return
        }

        XCTAssertEqual(result.count, 2)

        // "a/file2.txt" pairs with "b/old2.txt" (both first alphabetically)
        // "z/file1.txt" pairs with "x/old1.txt" (both second alphabetically)
        guard case .move(let from1) = result[0].action else {
            XCTFail("Expected move")
            return
        }
        XCTAssertEqual(result[0].path, "a/file2.txt")
        XCTAssertEqual(from1, "b/old2.txt")

        guard case .move(let from2) = result[1].action else {
            XCTFail("Expected move")
            return
        }
        XCTAssertEqual(result[1].path, "z/file1.txt")
        XCTAssertEqual(from2, "x/old1.txt")
    }

    func testIgnoresNonAddDeleteOperations() throws {
        let detector = SyncMoveDetector()

        let file = makeFileItem(path: "test.txt", hash: 0xEE)

        let source = MockSnapshot(files: [file])
        let dest = MockSnapshot(files: [file])

        var operations: [FileOperation] = [
            FileOperation(action: .modify, path: "test.txt", localFile: file, remoteFile: file),
            FileOperation(action: .conflict, path: "conflict.txt", localFile: file, remoteFile: file)
        ]

        detector.detectMoves(source: source, dest: dest, operations: &operations)

        // Should not modify non-add/delete operations
        XCTAssertEqual(operations.count, 2)
        XCTAssertEqual(operations[0].action, .modify)
        XCTAssertEqual(operations[1].action, .conflict)
    }
}
