import XCTest
@testable import Diffa

/// Tests for EfficientSync core types: FileItem, SyncMode, FileOperation
final class CoreTypesTests: XCTestCase {

    // MARK: - FileItem Tests

    func testFileItemEquality() throws {
        let hash1 = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                          0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10])
        let hash2 = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8,
                          0xF7, 0xF6, 0xF5, 0xF4, 0xF3, 0xF2, 0xF1, 0xF0])

        let file1 = FileItem(
            path: "test/file.txt",
            size: 1024,
            hash: hash1,
            mtime: 1699459200,
            mode: 0o644
        )

        let file2 = FileItem(
            path: "test/file.txt",
            size: 1024,
            hash: hash1,
            mtime: 1699459200,
            mode: 0o644
        )

        let file3 = FileItem(
            path: "test/file.txt",
            size: 1024,
            hash: hash2,  // Different hash
            mtime: 1699459200,
            mode: 0o644
        )

        XCTAssertEqual(file1, file2, "Identical FileItems should be equal")
        XCTAssertNotEqual(file1, file3, "FileItems with different hashes should not be equal")
    }

    func testFileItemDescription() throws {
        let hash = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                         0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10])

        let file = FileItem(
            path: "docs/readme.md",
            size: 2048,
            hash: hash,
            mtime: 1699459200,
            mode: 0o644
        )

        let desc = file.description
        XCTAssertTrue(desc.contains("docs/readme.md"), "Description should contain path")
        XCTAssertTrue(desc.contains("2048"), "Description should contain size")
        XCTAssertTrue(desc.contains("01020304"), "Description should contain hash prefix")
        XCTAssertTrue(desc.contains("0o644"), "Description should contain mode")
    }

    // MARK: - SyncMode Tests

    func testSyncModeDescription() throws {
        XCTAssertEqual(SyncMode.push.description, "push (dest mirrors source)")
        XCTAssertEqual(SyncMode.pull.description, "pull (source mirrors dest)")
        XCTAssertEqual(SyncMode.sync.description, "sync (merge both, newer wins)")
    }

    func testSyncModeCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let pushData = try encoder.encode(SyncMode.push)
        let pushDecoded = try decoder.decode(SyncMode.self, from: pushData)
        XCTAssertEqual(pushDecoded, .push)

        let pullData = try encoder.encode(SyncMode.pull)
        let pullDecoded = try decoder.decode(SyncMode.self, from: pullData)
        XCTAssertEqual(pullDecoded, .pull)

        let syncData = try encoder.encode(SyncMode.sync)
        let syncDecoded = try decoder.decode(SyncMode.self, from: syncData)
        XCTAssertEqual(syncDecoded, .sync)
    }

    // MARK: - FileOperation Tests

    func testFileOperationAdd() throws {
        let hash = Data(repeating: 0xAB, count: 16)
        let remoteFile = FileItem(
            path: "new.txt",
            size: 512,
            hash: hash,
            mtime: 1699459200
        )

        let op = FileOperation(
            action: .add,
            path: "new.txt",
            localFile: nil,
            remoteFile: remoteFile
        )

        XCTAssertEqual(op.action, .add)
        XCTAssertEqual(op.path, "new.txt")
        XCTAssertNil(op.localFile)
        XCTAssertEqual(op.remoteFile, remoteFile)

        // Convenience accessors should use remoteFile
        XCTAssertEqual(op.hash, hash)
        XCTAssertEqual(op.size, 512)
        XCTAssertEqual(op.mtime, 1699459200)
    }

    func testFileOperationDelete() throws {
        let hash = Data(repeating: 0xCD, count: 16)
        let localFile = FileItem(
            path: "old.txt",
            size: 256,
            hash: hash,
            mtime: 1699450000
        )

        let op = FileOperation(
            action: .delete,
            path: "old.txt",
            localFile: localFile,
            remoteFile: nil
        )

        XCTAssertEqual(op.action, .delete)
        XCTAssertEqual(op.path, "old.txt")
        XCTAssertEqual(op.localFile, localFile)
        XCTAssertNil(op.remoteFile)

        // Convenience accessors should fall back to localFile
        XCTAssertEqual(op.hash, hash)
        XCTAssertEqual(op.size, 256)
        XCTAssertEqual(op.mtime, 1699450000)
    }

    func testFileOperationConflict() throws {
        let oldHash = Data(repeating: 0x11, count: 16)
        let newHash = Data(repeating: 0x22, count: 16)

        let localFile = FileItem(
            path: "conflict.txt",
            size: 100,
            hash: oldHash,
            mtime: 1699450000
        )

        let remoteFile = FileItem(
            path: "conflict.txt",
            size: 200,
            hash: newHash,
            mtime: 1699459200
        )

        let op = FileOperation(
            action: .conflict,
            path: "conflict.txt",
            localFile: localFile,
            remoteFile: remoteFile
        )

        XCTAssertEqual(op.action, .conflict)
        XCTAssertEqual(op.localFile, localFile)
        XCTAssertEqual(op.remoteFile, remoteFile)

        // Can choose newer file by comparing mtimes
        let newerFile = op.remoteFile!.mtime > op.localFile!.mtime ? op.remoteFile! : op.localFile!
        XCTAssertEqual(newerFile, remoteFile, "Should identify remote as newer")
    }

    func testFileOperationMove() throws {
        let hash = Data(repeating: 0x33, count: 16)
        let localFile = FileItem(
            path: "renamed.txt",
            size: 1024,
            hash: hash,
            mtime: 1699459200
        )

        let op = FileOperation(
            action: .move(from: "old-name.txt"),
            path: "renamed.txt",
            localFile: localFile,
            remoteFile: nil
        )

        XCTAssertEqual(op.path, "renamed.txt")
        if case .move(let from) = op.action {
            XCTAssertEqual(from, "old-name.txt")
        } else {
            XCTFail("Expected .move action")
        }
    }

    func testFileOperationConvenienceAccessorsWithNilFiles() throws {
        let op = FileOperation(
            action: .add,
            path: "empty.txt",
            localFile: nil,
            remoteFile: nil
        )

        // Should return empty/zero defaults when both files are nil
        XCTAssertEqual(op.hash, Data())
        XCTAssertEqual(op.size, 0)
        XCTAssertEqual(op.mtime, 0)
        XCTAssertNil(op.mode)
    }

    func testFileOperationDescription() throws {
        let hash = Data(repeating: 0xAB, count: 16)
        let remoteFile = FileItem(
            path: "test.txt",
            size: 512,
            hash: hash,
            mtime: 1699459200
        )

        let addOp = FileOperation(
            action: .add,
            path: "test.txt",
            remoteFile: remoteFile
        )

        let desc = addOp.description
        XCTAssertTrue(desc.contains("add"), "Description should contain action")
        XCTAssertTrue(desc.contains("test.txt"), "Description should contain path")
        XCTAssertTrue(desc.contains("ababab"), "Description should contain hash prefix")
        XCTAssertTrue(desc.contains("512"), "Description should contain size")
    }
}
