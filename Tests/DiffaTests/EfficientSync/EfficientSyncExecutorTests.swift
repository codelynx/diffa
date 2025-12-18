import XCTest
@testable import Diffa

final class EfficientSyncExecutorTests: XCTestCase {
    var tempDir: URL!
    var executor: EfficientSyncExecutor!
    var comparator: SnapshotComparator!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EfficientSyncExecutorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        executor = EfficientSyncExecutor()
        comparator = SnapshotComparator()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func createDir(_ name: String) throws -> URL {
        let dir = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func createFile(_ dir: URL, _ name: String, _ content: String) throws {
        let file = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    private func readFile(_ dir: URL, _ name: String) throws -> String {
        let file = dir.appendingPathComponent(name)
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func fileExists(_ dir: URL, _ name: String) -> Bool {
        let file = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: file.path)
    }

    // MARK: - Full Workflow Tests

    func testFullWorkflowAddFiles() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        try createFile(source, "new1.txt", "content1")
        try createFile(source, "new2.txt", "content2")

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .push)
        let result = try executor.execute(
            operations: ops,
            sourceRoot: source,
            destRoot: dest,
            sourceSnapshot: srcSnap,
            destSnapshot: destSnap,
            mode: .push
        )

        XCTAssertEqual(result.addedCount, 2)
        XCTAssertTrue(fileExists(dest, "new1.txt"))
        XCTAssertTrue(fileExists(dest, "new2.txt"))
        XCTAssertEqual(try readFile(dest, "new1.txt"), "content1")
    }

    func testFullWorkflowModifyFiles() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        try createFile(source, "file.txt", "new content")
        try createFile(dest, "file.txt", "old content")

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .push)
        let result = try executor.execute(
            operations: ops,
            sourceRoot: source,
            destRoot: dest,
            sourceSnapshot: srcSnap,
            destSnapshot: destSnap,
            mode: .push
        )

        XCTAssertEqual(result.modifiedCount, 1)
        XCTAssertEqual(try readFile(dest, "file.txt"), "new content")
    }

    func testFullWorkflowDeleteFiles() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        // Source empty, dest has file
        try createFile(dest, "old.txt", "to be deleted")

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .push)
        let result = try executor.execute(
            operations: ops,
            sourceRoot: source,
            destRoot: dest,
            sourceSnapshot: srcSnap,
            destSnapshot: destSnap,
            mode: .push
        )

        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertFalse(fileExists(dest, "old.txt"))
    }

    func testFullWorkflowMoveFiles() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        // Same content, different path = move
        try createFile(source, "new-name.txt", "same content")
        try createFile(dest, "old-name.txt", "same content")

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .push)
        let result = try executor.execute(
            operations: ops,
            sourceRoot: source,
            destRoot: dest,
            sourceSnapshot: srcSnap,
            destSnapshot: destSnap,
            mode: .push
        )

        XCTAssertEqual(result.movedCount, 1)
        XCTAssertTrue(fileExists(dest, "new-name.txt"))
        XCTAssertFalse(fileExists(dest, "old-name.txt"))
        XCTAssertEqual(try readFile(dest, "new-name.txt"), "same content")
    }

    // MARK: - Deduplication Tests

    func testDeduplicationZeroCopy() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        // Source has new file with same content as existing dest file
        let content = "duplicate content"
        try createFile(source, "new.txt", content)
        try createFile(dest, "existing.txt", content)

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .sync)
        let result = try executor.execute(
            operations: ops,
            sourceRoot: source,
            destRoot: dest,
            sourceSnapshot: srcSnap,
            destSnapshot: destSnap,
            mode: .sync
        )

        XCTAssertEqual(result.addedCount, 1)
        XCTAssertTrue(fileExists(dest, "new.txt"))
        XCTAssertEqual(try readFile(dest, "new.txt"), content)
        // Content was copied from existing.txt (zero-copy from source)
    }

    // MARK: - Conflict Resolution Tests

    func testConflictResolutionNewerWins() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        try createFile(source, "conflict.txt", "source version")
        try createFile(dest, "conflict.txt", "dest version")

        // Set source file to be newer
        let sourceFile = source.appendingPathComponent("conflict.txt")
        let destFile = dest.appendingPathComponent("conflict.txt")
        let newerTime = Date(timeIntervalSince1970: 2000000000)
        let olderTime = Date(timeIntervalSince1970: 1000000000)
        try FileManager.default.setAttributes([.modificationDate: newerTime], ofItemAtPath: sourceFile.path)
        try FileManager.default.setAttributes([.modificationDate: olderTime], ofItemAtPath: destFile.path)

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .sync)
        let result = try executor.execute(
            operations: ops,
            sourceRoot: source,
            destRoot: dest,
            sourceSnapshot: srcSnap,
            destSnapshot: destSnap,
            mode: .sync
        )

        XCTAssertEqual(result.conflictsResolved, 1)
        // Source was newer, so it should win
        XCTAssertEqual(try readFile(dest, "conflict.txt"), "source version")
    }

    func testConflictResolutionKeepsLocalWhenNewer() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        try createFile(source, "conflict.txt", "source version")
        try createFile(dest, "conflict.txt", "dest version")

        // Set dest file to be newer
        let sourceFile = source.appendingPathComponent("conflict.txt")
        let destFile = dest.appendingPathComponent("conflict.txt")
        let olderTime = Date(timeIntervalSince1970: 1000000000)
        let newerTime = Date(timeIntervalSince1970: 2000000000)
        try FileManager.default.setAttributes([.modificationDate: olderTime], ofItemAtPath: sourceFile.path)
        try FileManager.default.setAttributes([.modificationDate: newerTime], ofItemAtPath: destFile.path)

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .sync)
        let result = try executor.execute(
            operations: ops,
            sourceRoot: source,
            destRoot: dest,
            sourceSnapshot: srcSnap,
            destSnapshot: destSnap,
            mode: .sync
        )

        XCTAssertEqual(result.conflictsResolved, 1)
        // Dest was newer, so it should be kept
        XCTAssertEqual(try readFile(dest, "conflict.txt"), "dest version")
    }

    // MARK: - Nested Directory Tests

    func testAddFilesInNestedDirectories() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        try createFile(source, "a/b/c/deep.txt", "deep content")

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .push)
        let result = try executor.execute(
            operations: ops,
            sourceRoot: source,
            destRoot: dest,
            sourceSnapshot: srcSnap,
            destSnapshot: destSnap,
            mode: .push
        )

        XCTAssertEqual(result.addedCount, 1)
        XCTAssertTrue(fileExists(dest, "a/b/c/deep.txt"))
    }

    // MARK: - Statistics Tests

    func testResultStatistics() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        // Setup: add, modify, delete, move
        try createFile(source, "new.txt", "new")
        try createFile(source, "modified.txt", "new content")
        try createFile(dest, "modified.txt", "old content")
        try createFile(dest, "deleted.txt", "will delete")
        try createFile(source, "renamed.txt", "move content")
        try createFile(dest, "old-name.txt", "move content")

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .push)
        let result = try executor.execute(
            operations: ops,
            sourceRoot: source,
            destRoot: dest,
            sourceSnapshot: srcSnap,
            destSnapshot: destSnap,
            mode: .push
        )

        XCTAssertEqual(result.addedCount, 1)
        XCTAssertEqual(result.modifiedCount, 1)
        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertEqual(result.movedCount, 1)
        XCTAssertEqual(result.totalOperations, 4)
        XCTAssertFalse(result.hasErrors)
    }
}
