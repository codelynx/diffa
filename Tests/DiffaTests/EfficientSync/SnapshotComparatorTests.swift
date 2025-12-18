import XCTest
@testable import Diffa

final class SnapshotComparatorTests: XCTestCase {
    var tempDir: URL!
    var comparator: SnapshotComparator!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotComparatorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
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
        // Create parent directories if needed
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - Identical Snapshots

    func testCompareIdenticalSnapshots() throws {
        let dir = try createDir("source")
        try createFile(dir, "file.txt", "content")

        let snapshot = try SQLiteSyncSnapshot.create(at: dir)
        let ops = comparator.compare(source: snapshot, dest: snapshot, mode: .push)

        XCTAssertTrue(ops.isEmpty)
    }

    // MARK: - Detect Added Files

    func testDetectAddedFiles() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        try createFile(source, "new.txt", "new content")
        // dest is empty

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .push)

        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].action, .add)
        XCTAssertEqual(ops[0].path, "new.txt")
        XCTAssertNil(ops[0].localFile)
        XCTAssertNotNil(ops[0].remoteFile)
    }

    // MARK: - Detect Modified Files

    func testDetectModifiedFiles() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        try createFile(source, "file.txt", "new content")
        try createFile(dest, "file.txt", "old content")

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .push)

        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].action, .modify)
        XCTAssertEqual(ops[0].path, "file.txt")
        XCTAssertNotNil(ops[0].localFile)
        XCTAssertNotNil(ops[0].remoteFile)
    }

    // MARK: - Push Mode Deletions

    func testPushModeDeletions() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        // source is empty
        try createFile(dest, "old.txt", "old content")

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .push)

        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].action, .delete)
        XCTAssertEqual(ops[0].path, "old.txt")
        XCTAssertNotNil(ops[0].localFile)
        XCTAssertNil(ops[0].remoteFile)
    }

    // MARK: - Pull Mode Deletions

    func testPullModeDeletions() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        // source is empty
        try createFile(dest, "local.txt", "local content")

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .pull)

        // Pull: local-only files should be deleted to match remote
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].action, .delete)
        XCTAssertEqual(ops[0].path, "local.txt")
    }

    func testPullAddsServerFiles() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        try createFile(source, "server.txt", "server content")
        // dest is empty

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .pull)

        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].action, .add)
        XCTAssertEqual(ops[0].path, "server.txt")
    }

    // MARK: - Sync Mode No Deletions

    func testSyncModeNoDeletions() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        try createFile(source, "source-only.txt", "source content")
        try createFile(dest, "dest-only.txt", "dest content")

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .sync)

        // Sync should only add source-only to dest, not delete dest-only
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].action, .add)
        XCTAssertEqual(ops[0].path, "source-only.txt")
    }

    // MARK: - Sync Mode Generates Conflicts

    func testSyncModeGeneratesConflicts() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        try createFile(source, "conflict.txt", "source version")
        try createFile(dest, "conflict.txt", "dest version")

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .sync)

        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].action, .conflict)
        XCTAssertEqual(ops[0].path, "conflict.txt")
        XCTAssertNotNil(ops[0].localFile)
        XCTAssertNotNil(ops[0].remoteFile)
    }

    // MARK: - Mixed Operations

    func testMixedOperations() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        // Added
        try createFile(source, "new.txt", "new")
        // Modified
        try createFile(source, "modified.txt", "new content")
        try createFile(dest, "modified.txt", "old content")
        // Deleted (push mode)
        try createFile(dest, "deleted.txt", "old")
        // Unchanged
        try createFile(source, "same.txt", "same")
        try createFile(dest, "same.txt", "same")

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .push)

        XCTAssertEqual(ops.count, 3)

        let actions = Dictionary(uniqueKeysWithValues: ops.map { ($0.path, $0.action) })
        XCTAssertEqual(actions["new.txt"], .add)
        XCTAssertEqual(actions["modified.txt"], .modify)
        XCTAssertEqual(actions["deleted.txt"], .delete)
    }

    // MARK: - Move Detection

    func testDetectSimpleRename() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        // Same content, different path = move
        try createFile(source, "new-name.txt", "same content")
        try createFile(dest, "old-name.txt", "same content")

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .push)

        XCTAssertEqual(ops.count, 1)
        if case .move(let from) = ops[0].action {
            XCTAssertEqual(from, "old-name.txt")
            XCTAssertEqual(ops[0].path, "new-name.txt")
        } else {
            XCTFail("Expected move operation, got \(ops[0].action)")
        }
    }

    func testDetectMultipleMovesWithSameHash() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        // Multiple files with same content
        let content = "duplicate content"
        try createFile(source, "dir1/file.txt", content)
        try createFile(source, "dir2/file.txt", content)
        try createFile(dest, "old1.txt", content)
        try createFile(dest, "old2.txt", content)

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .push)

        // Should have 2 moves (deterministic pairing)
        XCTAssertEqual(ops.count, 2)
        let moveOps = ops.filter { if case .move = $0.action { return true } else { return false } }
        XCTAssertEqual(moveOps.count, 2)
    }

    func testMoveWithUnmatchedCounts() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        // 2 adds, 1 delete with same hash
        let content = "same content"
        try createFile(source, "new1.txt", content)
        try createFile(source, "new2.txt", content)
        try createFile(dest, "old.txt", content)

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .push)

        // Should have 1 move + 1 add (min pairing)
        let moveOps = ops.filter { if case .move = $0.action { return true } else { return false } }
        let addOps = ops.filter { $0.action == .add }
        XCTAssertEqual(moveOps.count, 1)
        XCTAssertEqual(addOps.count, 1)
    }

    func testNoMoveForDifferentContent() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        // Different content = no move
        try createFile(source, "new.txt", "new content")
        try createFile(dest, "old.txt", "old content")

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .push)

        // Should be add + delete, not move
        XCTAssertEqual(ops.count, 2)
        let actions = ops.map(\.action)
        XCTAssertTrue(actions.contains(.add))
        XCTAssertTrue(actions.contains(.delete))
    }

    // MARK: - Deterministic Ordering

    func testDeterministicOrdering() throws {
        let source = try createDir("source")
        let dest = try createDir("dest")

        try createFile(source, "z.txt", "z")
        try createFile(source, "a.txt", "a")
        try createFile(source, "m.txt", "m")

        let srcSnap = try SQLiteSyncSnapshot.create(at: source)
        let destSnap = try SQLiteSyncSnapshot.create(at: dest)

        let ops = comparator.compare(source: srcSnap, dest: destSnap, mode: .push)

        // Should be sorted alphabetically
        XCTAssertEqual(ops.map(\.path), ["a.txt", "m.txt", "z.txt"])
    }
}
