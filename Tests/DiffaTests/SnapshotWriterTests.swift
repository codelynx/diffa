import XCTest
@testable import Diffa
import Foundation

final class SnapshotWriterTests: XCTestCase {
    var tempDir: URL!
    var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default

        // Create unique temp directory for each test
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("DiffaWriterTests-\(UUID().uuidString)")
        try! fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Clean up temp directory
        if fileManager.fileExists(atPath: tempDir.path) {
            try? fileManager.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Insert Tests

    func testInsertSingleItem() async throws {
        // Create a snapshot database
        let snapshotURL = tempDir.appendingPathComponent("test.snapshot")
        let snapshot = try Snapshot.create(at: snapshotURL, rootPath: tempDir.path)

        // Create a test file
        let fileURL = tempDir.appendingPathComponent("test.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        // Create FileSystemItem
        let item = try await FileSystemItem(at: fileURL, relativeTo: tempDir)

        // Insert using SnapshotWriter
        let writer = SnapshotWriter(database: snapshot.database)
        let rowId = try writer.insertItem(item, parentPath: nil)

        // Verify it was inserted
        XCTAssertGreaterThan(rowId, 0, "Row ID should be positive")

        // Query the database to verify
        let rows = try snapshot.database.query("SELECT path, name, is_folder FROM items WHERE id = ?", [.integer(rowId)])
        XCTAssertEqual(rows.count, 1, "Should have exactly 1 row")

        let row = rows[0]
        XCTAssertEqual(try row.string(at: 0), "test.txt")
        XCTAssertEqual(try row.string(at: 1), "test.txt")
        XCTAssertEqual(try row.int64(at: 2), 0) // not a folder
    }

    func testInsertWithParentRelationship() async throws {
        // Create a snapshot database
        let snapshotURL = tempDir.appendingPathComponent("test.snapshot")
        let snapshot = try Snapshot.create(at: snapshotURL, rootPath: tempDir.path)

        // Create directory with file
        let dir = tempDir.appendingPathComponent("dir")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: false)
        let fileURL = dir.appendingPathComponent("file.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        // Create FileSystemItems
        let dirItem = try await FileSystemItem(at: dir, relativeTo: tempDir)
        let fileItem = try await FileSystemItem(at: fileURL, relativeTo: tempDir)

        // Insert using SnapshotWriter
        let writer = SnapshotWriter(database: snapshot.database)

        // Insert directory first (no parent)
        let dirId = try writer.insertItem(dirItem, parentPath: nil)

        // Push directory onto stack so it can be found as parent
        writer.pushDirectory(path: "dir", id: dirId)

        // Insert file with directory as parent
        let fileId = try writer.insertItem(fileItem, parentPath: "dir")

        // Verify parent-child relationship
        let rows = try snapshot.database.query("SELECT parent_id, path FROM items WHERE id = ?", [.integer(fileId)])
        XCTAssertEqual(rows.count, 1)

        let row = rows[0]
        let parentId = try row.int64(at: 0)
        XCTAssertEqual(parentId, dirId, "File's parent_id should match directory's id")
        XCTAssertEqual(try row.string(at: 1), "dir/file.txt")
    }

    func testInsertMultipleItems() async throws {
        // Create a snapshot database
        let snapshotURL = tempDir.appendingPathComponent("test.snapshot")
        let snapshot = try Snapshot.create(at: snapshotURL, rootPath: tempDir.path)

        // Create multiple files
        let files = ["file1.txt", "file2.txt", "file3.txt"]
        for fileName in files {
            let fileURL = tempDir.appendingPathComponent(fileName)
            try "content".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        // Create FileSystemItems before transaction (async calls)
        var items: [FileSystemItem] = []
        for fileName in files {
            let fileURL = tempDir.appendingPathComponent(fileName)
            let item = try await FileSystemItem(at: fileURL, relativeTo: tempDir)
            items.append(item)
        }

        // Insert all in a transaction (sync calls only)
        try snapshot.database.transaction {
            let writer = SnapshotWriter(database: snapshot.database)

            for item in items {
                _ = try writer.insertItem(item, parentPath: nil)
            }
        }

        // Verify all were inserted
        let rows = try snapshot.database.query("SELECT COUNT(*) FROM items")
        let count = try rows[0].int64(at: 0)
        XCTAssertEqual(count, 3, "Should have 3 items in database")
    }

    func testInsertUpdateMetadata() async throws {
        // Create a snapshot database
        let snapshotURL = tempDir.appendingPathComponent("test.snapshot")
        let snapshot = try Snapshot.create(at: snapshotURL, rootPath: tempDir.path)

        // Create test structure: 1 directory, 2 files
        let dir = tempDir.appendingPathComponent("dir")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: false)
        let file1 = tempDir.appendingPathComponent("file1.txt")
        let file2 = dir.appendingPathComponent("file2.txt")
        try "content1".write(to: file1, atomically: true, encoding: .utf8)
        try "content2".write(to: file2, atomically: true, encoding: .utf8)

        // Track totals
        var totalFiles = 0
        var totalFolders = 0
        var totalSize: Int64 = 0

        // Create FileSystemItems before transaction (async calls)
        let dirItem = try await FileSystemItem(at: dir, relativeTo: tempDir)
        let file1Item = try await FileSystemItem(at: file1, relativeTo: tempDir)
        let file2Item = try await FileSystemItem(at: file2, relativeTo: tempDir)

        // Insert items in transaction (sync calls only)
        try snapshot.database.transaction {
            let writer = SnapshotWriter(database: snapshot.database)

            // Insert dir
            let dirId = try writer.insertItem(dirItem, parentPath: nil)
            totalFolders += 1

            // Push directory onto stack so it can be found as parent
            writer.pushDirectory(path: "dir", id: dirId)

            // Insert file1
            _ = try writer.insertItem(file1Item, parentPath: nil)
            totalFiles += 1
            totalSize += file1Item.size

            // Insert file2
            _ = try writer.insertItem(file2Item, parentPath: "dir")
            totalFiles += 1
            totalSize += file2Item.size

            // Update metadata
            try writer.updateMetadata(totalFiles: totalFiles, totalFolders: totalFolders, totalSize: totalSize)
        }

        // Verify metadata was updated
        let rows = try snapshot.database.query("SELECT total_files, total_folders, total_size FROM metadata")
        XCTAssertEqual(rows.count, 1)

        let row = rows[0]
        XCTAssertEqual(try row.int64(at: 0), 2, "Should have 2 files")
        XCTAssertEqual(try row.int64(at: 1), 1, "Should have 1 folder")
        XCTAssertEqual(try row.int64(at: 2), totalSize, "Total size should match")
    }

    func testCreateSnapshotIntegration() async throws {
        // Create test directory structure
        // testData/
        //   ├── file1.txt
        //   └── dir/
        //       └── file2.txt

        let testData = tempDir.appendingPathComponent("testData")
        try fileManager.createDirectory(at: testData, withIntermediateDirectories: false)

        let file1 = testData.appendingPathComponent("file1.txt")
        try "content1".write(to: file1, atomically: true, encoding: .utf8)

        let dir = testData.appendingPathComponent("dir")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: false)

        let file2 = dir.appendingPathComponent("file2.txt")
        try "content2".write(to: file2, atomically: true, encoding: .utf8)

        // Create snapshot using SnapshotEngine (outside testData)
        let snapshotURL = tempDir.appendingPathComponent("test.snapshot")
        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot = try await engine.createSnapshot(
            from: testData,
            saveTo: snapshotURL,
            options: options
        )

        // Verify snapshot was created
        XCTAssertTrue(fileManager.fileExists(atPath: snapshotURL.path))

        // Verify items were inserted
        let items = try snapshot.database.query("SELECT path, is_folder FROM items ORDER BY path")
        XCTAssertEqual(items.count, 3, "Should have 3 items: dir, file1.txt, dir/file2.txt")

        // Verify paths
        let paths = items.compactMap { try? $0.string(at: 0) }
        XCTAssertTrue(paths.contains("dir"))
        XCTAssertTrue(paths.contains("file1.txt"))
        XCTAssertTrue(paths.contains("dir/file2.txt"))

        // Verify metadata totals using public API (not database queries)
        // This tests that the returned Snapshot has correct metadata loaded
        XCTAssertEqual(snapshot.metadata.totalFiles, 2, "Should have 2 files")
        XCTAssertEqual(snapshot.metadata.totalFolders, 1, "Should have 1 folder")
        XCTAssertGreaterThan(snapshot.metadata.totalSize, 0, "Total size should be > 0")
    }
}
