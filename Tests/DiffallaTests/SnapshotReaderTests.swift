import XCTest
@testable import Diffalla
import Foundation

final class SnapshotReaderTests: XCTestCase {
    var tempDir: URL!
    var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default

        // Create unique temp directory for each test
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("DiffallaReaderTests-\(UUID().uuidString)")
        try! fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Clean up temp directory
        if fileManager.fileExists(atPath: tempDir.path) {
            try? fileManager.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Test Cases

    func testLoadMetadata() async throws {
        // Create a test directory structure
        let testData = tempDir.appendingPathComponent("testData")
        try fileManager.createDirectory(at: testData, withIntermediateDirectories: false)

        let file1 = testData.appendingPathComponent("file1.txt")
        try "content1".write(to: file1, atomically: true, encoding: .utf8)

        let dir = testData.appendingPathComponent("dir")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: false)

        let file2 = dir.appendingPathComponent("file2.txt")
        try "content2".write(to: file2, atomically: true, encoding: .utf8)

        // Create snapshot
        let snapshotURL = tempDir.appendingPathComponent("test.snapshot")
        let engine = SnapshotEngine()
        let snapshot = try await engine.createSnapshot(
            from: testData,
            saveTo: snapshotURL,
            options: ScanOptions()
        )

        // Load metadata
        let metadata = snapshot.metadata

        // Verify totals
        XCTAssertEqual(metadata.totalFiles, 2, "Should have 2 files")
        XCTAssertEqual(metadata.totalFolders, 1, "Should have 1 folder")
        XCTAssertGreaterThan(metadata.totalSize, 0, "Total size should be > 0")
    }

    func testLoadAllItems() async throws {
        // Create a test directory structure
        let testData = tempDir.appendingPathComponent("testData")
        try fileManager.createDirectory(at: testData, withIntermediateDirectories: false)

        let file1 = testData.appendingPathComponent("file1.txt")
        try "content".write(to: file1, atomically: true, encoding: .utf8)

        let dir = testData.appendingPathComponent("dir")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: false)

        let file2 = dir.appendingPathComponent("file2.txt")
        try "content".write(to: file2, atomically: true, encoding: .utf8)

        // Create snapshot
        let snapshotURL = tempDir.appendingPathComponent("test.snapshot")
        let engine = SnapshotEngine()
        let snapshot = try await engine.createSnapshot(
            from: testData,
            saveTo: snapshotURL,
            options: ScanOptions()
        )

        // Load all items
        let items = try snapshot.loadAllItems()

        // Verify count
        XCTAssertEqual(items.count, 3, "Should have 3 items: dir, file1.txt, dir/file2.txt")

        // Verify paths (ordered by path)
        let paths = items.map { $0.path }
        XCTAssertTrue(paths.contains("dir"))
        XCTAssertTrue(paths.contains("file1.txt"))
        XCTAssertTrue(paths.contains("dir/file2.txt"))

        // Verify item properties
        let dirItem = items.first { $0.path == "dir" }!
        XCTAssertTrue(dirItem.isFolder, "dir should be a folder")
        XCTAssertEqual(dirItem.name, "dir")
        XCTAssertNil(dirItem.parentId, "dir is root-level so no parent")

        let file1Item = items.first { $0.path == "file1.txt" }!
        XCTAssertFalse(file1Item.isFolder, "file1.txt should be a file")
        XCTAssertGreaterThan(file1Item.size, 0)
        XCTAssertNotNil(file1Item.sha256, "file should have SHA-256")

        let file2Item = items.first { $0.path == "dir/file2.txt" }!
        XCTAssertNotNil(file2Item.parentId, "file2 should have parent")
        XCTAssertEqual(file2Item.parentId, dirItem.id, "file2's parent should be dir")
    }

    func testLoadSpecificItem() async throws {
        // Create a test directory structure
        let testData = tempDir.appendingPathComponent("testData")
        try fileManager.createDirectory(at: testData, withIntermediateDirectories: false)

        let file1 = testData.appendingPathComponent("file1.txt")
        try "test content".write(to: file1, atomically: true, encoding: .utf8)

        // Create snapshot
        let snapshotURL = tempDir.appendingPathComponent("test.snapshot")
        let engine = SnapshotEngine()
        let snapshot = try await engine.createSnapshot(
            from: testData,
            saveTo: snapshotURL,
            options: ScanOptions()
        )

        // Load specific item by path
        let item = try snapshot.loadItem(path: "file1.txt")

        // Verify item found
        XCTAssertNotNil(item, "Should find file1.txt")
        XCTAssertEqual(item?.path, "file1.txt")
        XCTAssertEqual(item?.name, "file1.txt")
        XCTAssertFalse(item?.isFolder ?? true, "Should be a file")
        XCTAssertGreaterThan(item?.size ?? 0, 0)
    }

    func testLoadChildren() async throws {
        // Create a test directory structure
        let testData = tempDir.appendingPathComponent("testData")
        try fileManager.createDirectory(at: testData, withIntermediateDirectories: false)

        let dir = testData.appendingPathComponent("dir")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: false)

        let child1 = dir.appendingPathComponent("child1.txt")
        try "content1".write(to: child1, atomically: true, encoding: .utf8)

        let child2 = dir.appendingPathComponent("child2.txt")
        try "content2".write(to: child2, atomically: true, encoding: .utf8)

        let subdir = dir.appendingPathComponent("subdir")
        try fileManager.createDirectory(at: subdir, withIntermediateDirectories: false)

        // Create snapshot
        let snapshotURL = tempDir.appendingPathComponent("test.snapshot")
        let engine = SnapshotEngine()
        let snapshot = try await engine.createSnapshot(
            from: testData,
            saveTo: snapshotURL,
            options: ScanOptions()
        )

        // Load the directory item first
        let dirItem = try snapshot.loadItem(path: "dir")
        XCTAssertNotNil(dirItem, "Should find dir")

        // Load children of directory
        let children = try snapshot.loadChildren(of: dirItem!.id)

        // Verify count (should have 3 children: 2 files + 1 subdir)
        XCTAssertEqual(children.count, 3, "dir should have 3 children")

        // Verify all children are ordered by name
        let names = children.map { $0.name }
        XCTAssertEqual(names.sorted(), names, "Children should be ordered by name")

        // Verify children have correct parent
        for child in children {
            XCTAssertEqual(child.parentId, dirItem!.id, "All children should have dir as parent")
        }

        // Verify paths
        let paths = children.map { $0.path }
        XCTAssertTrue(paths.contains("dir/child1.txt"))
        XCTAssertTrue(paths.contains("dir/child2.txt"))
        XCTAssertTrue(paths.contains("dir/subdir"))
    }

    func testLoadNonexistentItem() async throws {
        // Create empty snapshot
        let testData = tempDir.appendingPathComponent("testData")
        try fileManager.createDirectory(at: testData, withIntermediateDirectories: false)

        let snapshotURL = tempDir.appendingPathComponent("test.snapshot")
        let engine = SnapshotEngine()
        let snapshot = try await engine.createSnapshot(
            from: testData,
            saveTo: snapshotURL,
            options: ScanOptions()
        )

        // Try to load nonexistent item
        let item = try snapshot.loadItem(path: "nonexistent.txt")

        // Verify nil is returned
        XCTAssertNil(item, "Should return nil for nonexistent item")
    }
}
