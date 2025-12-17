import XCTest
@testable import Diffa

final class SQLiteSyncSnapshotTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteSyncSnapshotTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helper

    private func createTestDirectory() throws -> URL {
        let dir = tempDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Create Snapshot

    func testCreateEmptySnapshot() throws {
        let dir = try createTestDirectory()

        let snapshot = try SQLiteSyncSnapshot.create(at: dir)

        XCTAssertEqual(snapshot.fileCount, 0)
        XCTAssertEqual(snapshot.totalSize, 0)
        XCTAssertTrue(snapshot.allFiles().isEmpty)
    }

    func testCreateSnapshotWithSingleFile() throws {
        let dir = try createTestDirectory()
        let file = dir.appendingPathComponent("test.txt")
        try "hello world".write(to: file, atomically: true, encoding: .utf8)

        let snapshot = try SQLiteSyncSnapshot.create(at: dir)

        XCTAssertEqual(snapshot.fileCount, 1)
        let files = snapshot.allFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "test.txt")
        XCTAssertEqual(files[0].size, 11) // "hello world" = 11 bytes
        XCTAssertEqual(files[0].hash.count, 32) // SHA-256 = 32 bytes
    }

    func testCreateSnapshotWithNestedDirectories() throws {
        let dir = try createTestDirectory()

        // Create nested structure
        let subdir = dir.appendingPathComponent("photos/2024")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "photo1".write(to: subdir.appendingPathComponent("a.jpg"), atomically: true, encoding: .utf8)
        try "photo2".write(to: subdir.appendingPathComponent("b.jpg"), atomically: true, encoding: .utf8)
        try "readme".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let snapshot = try SQLiteSyncSnapshot.create(at: dir)

        XCTAssertEqual(snapshot.fileCount, 3)
        let paths = snapshot.allFiles().map(\.path).sorted()
        XCTAssertEqual(paths, ["README.md", "photos/2024/a.jpg", "photos/2024/b.jpg"])
    }

    // MARK: - Query by Path

    func testQueryFileByPath() throws {
        let dir = try createTestDirectory()
        try "content".write(to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let snapshot = try SQLiteSyncSnapshot.create(at: dir)
        let file = snapshot.fileByPath("file.txt")

        XCTAssertNotNil(file)
        XCTAssertEqual(file?.path, "file.txt")
        XCTAssertEqual(file?.size, 7) // "content" = 7 bytes
    }

    func testQueryFileByPathNotFound() throws {
        let dir = try createTestDirectory()
        try "content".write(to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let snapshot = try SQLiteSyncSnapshot.create(at: dir)
        let file = snapshot.fileByPath("nonexistent.txt")

        XCTAssertNil(file)
    }

    // MARK: - Query by Hash

    func testQueryFilesByHash() throws {
        let dir = try createTestDirectory()
        let content = "duplicate content"
        try content.write(to: dir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try content.write(to: dir.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)
        try "different".write(to: dir.appendingPathComponent("file3.txt"), atomically: true, encoding: .utf8)

        let snapshot = try SQLiteSyncSnapshot.create(at: dir)

        // Get hash of duplicate content
        let file1 = snapshot.fileByPath("file1.txt")!
        let duplicates = snapshot.filesByHash(file1.hash)

        XCTAssertEqual(duplicates.count, 2)
        let paths = duplicates.map(\.path).sorted()
        XCTAssertEqual(paths, ["file1.txt", "file2.txt"])
    }

    func testQueryFilesByHashNotFound() throws {
        let dir = try createTestDirectory()
        try "content".write(to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let snapshot = try SQLiteSyncSnapshot.create(at: dir)
        let files = snapshot.filesByHash(Data(repeating: 0, count: 32))

        XCTAssertTrue(files.isEmpty)
    }

    // MARK: - All Files (Sorted)

    func testAllFilesSortedByPath() throws {
        let dir = try createTestDirectory()
        try "c".write(to: dir.appendingPathComponent("zebra.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "a".write(to: dir.appendingPathComponent("middle.txt"), atomically: true, encoding: .utf8)

        let snapshot = try SQLiteSyncSnapshot.create(at: dir)
        let paths = snapshot.allFiles().map(\.path)

        // Should be alphabetically sorted
        XCTAssertEqual(paths, ["alpha.txt", "middle.txt", "zebra.txt"])
    }

    // MARK: - Statistics

    func testTotalSize() throws {
        let dir = try createTestDirectory()
        try "12345".write(to: dir.appendingPathComponent("five.txt"), atomically: true, encoding: .utf8)
        try "1234567890".write(to: dir.appendingPathComponent("ten.txt"), atomically: true, encoding: .utf8)

        let snapshot = try SQLiteSyncSnapshot.create(at: dir)

        XCTAssertEqual(snapshot.totalSize, 15)
    }

    // MARK: - Open Existing

    func testOpenExistingSnapshot() throws {
        let dir = try createTestDirectory()
        try "content".write(to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let dbPath = tempDir.appendingPathComponent("snapshot.db").path

        // Create and close
        _ = try SQLiteSyncSnapshot.create(at: dir, dbPath: dbPath)

        // Reopen
        let reopened = try SQLiteSyncSnapshot.open(at: dbPath)

        XCTAssertEqual(reopened.fileCount, 1)
        XCTAssertEqual(reopened.root, dir.path)
    }

    // MARK: - Performance

    func testPerformance1000Files() throws {
        let dir = try createTestDirectory()

        // Create 1000 small files
        for i in 0..<1000 {
            let file = dir.appendingPathComponent("file_\(String(format: "%04d", i)).txt")
            try "content \(i)".write(to: file, atomically: true, encoding: .utf8)
        }

        // Measure snapshot creation
        let start = Date()
        let snapshot = try SQLiteSyncSnapshot.create(at: dir)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(snapshot.fileCount, 1000)
        XCTAssertLessThan(elapsed, 10.0, "1000 files should complete in <10s")
        print("1000 files snapshot: \(String(format: "%.2f", elapsed))s")
    }

    // MARK: - Metadata Preservation

    func testMetadataPreserved() throws {
        let dir = try createTestDirectory()
        let file = dir.appendingPathComponent("file.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        // Set specific mtime
        let targetDate = Date(timeIntervalSince1970: 1700000000)
        try FileManager.default.setAttributes([.modificationDate: targetDate], ofItemAtPath: file.path)

        let snapshot = try SQLiteSyncSnapshot.create(at: dir)
        let item = snapshot.fileByPath("file.txt")!

        // mtime should be captured
        XCTAssertEqual(item.mtime, 1700000000)

        // mode should be captured (non-nil on macOS)
        XCTAssertNotNil(item.mode)
    }
}
