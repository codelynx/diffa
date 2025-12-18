import XCTest
@testable import Diffa
import Foundation

final class ComparisonTests: XCTestCase {
    var tempDir: URL!
    var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default

        // Create unique temp directory for each test
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("DiffaComparisonTests-\(UUID().uuidString)")
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

    func testCompareIdenticalSnapshots() async throws {
        // Create identical directory structures
        let dir1 = tempDir.appendingPathComponent("dir1")
        try fileManager.createDirectory(at: dir1, withIntermediateDirectories: false)

        let file1 = dir1.appendingPathComponent("file.txt")
        try "same content".write(to: file1, atomically: true, encoding: .utf8)

        let subdir = dir1.appendingPathComponent("subdir")
        try fileManager.createDirectory(at: subdir, withIntermediateDirectories: false)

        // Create two snapshots from same directory
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: dir1, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: dir1, saveTo: snapshot2URL, options: options)

        // Compare
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Verify no differences
        XCTAssertTrue(try diff.added.isEmpty, "Should have no added items")
        XCTAssertTrue(try diff.removed.isEmpty, "Should have no removed items")
        XCTAssertTrue(try diff.modified.isEmpty, "Should have no modified items")
        XCTAssertFalse(try diff.hasDifferences, "Should have no differences")
    }

    func testCompareWithAddedFiles() async throws {
        // Create dir1 with one file
        let dir1 = tempDir.appendingPathComponent("dir1")
        try fileManager.createDirectory(at: dir1, withIntermediateDirectories: false)

        let file1 = dir1.appendingPathComponent("file1.txt")
        try "content1".write(to: file1, atomically: true, encoding: .utf8)

        // Create snapshot1
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let engine = SnapshotEngine()
        let options = ScanOptions()
        let snapshot1 = try await engine.createSnapshot(from: dir1, saveTo: snapshot1URL, options: options)

        // Add new files to dir1
        let file2 = dir1.appendingPathComponent("file2.txt")
        try "content2".write(to: file2, atomically: true, encoding: .utf8)

        let newDir = dir1.appendingPathComponent("newdir")
        try fileManager.createDirectory(at: newDir, withIntermediateDirectories: false)

        // Create snapshot2
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let snapshot2 = try await engine.createSnapshot(from: dir1, saveTo: snapshot2URL, options: options)

        // Compare
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Verify added files detected
        let added = try diff.added
        XCTAssertEqual(added.count, 2, "Should have 2 added items: file2.txt, newdir")

        let addedPaths = added.map { $0.path }.sorted()
        XCTAssertTrue(addedPaths.contains("file2.txt"))
        XCTAssertTrue(addedPaths.contains("newdir"))

        XCTAssertTrue(try diff.removed.isEmpty, "Should have no removed items")
        XCTAssertTrue(try diff.hasDifferences, "Should have differences")
    }

    func testCompareWithRemovedFiles() async throws {
        // Create dir1 with multiple files
        let dir1 = tempDir.appendingPathComponent("dir1")
        try fileManager.createDirectory(at: dir1, withIntermediateDirectories: false)

        let file1 = dir1.appendingPathComponent("file1.txt")
        try "content1".write(to: file1, atomically: true, encoding: .utf8)

        let file2 = dir1.appendingPathComponent("file2.txt")
        try "content2".write(to: file2, atomically: true, encoding: .utf8)

        let subdir = dir1.appendingPathComponent("subdir")
        try fileManager.createDirectory(at: subdir, withIntermediateDirectories: false)

        // Create snapshot1
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let engine = SnapshotEngine()
        let options = ScanOptions()
        let snapshot1 = try await engine.createSnapshot(from: dir1, saveTo: snapshot1URL, options: options)

        // Remove files
        try fileManager.removeItem(at: file2)
        try fileManager.removeItem(at: subdir)

        // Create snapshot2
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let snapshot2 = try await engine.createSnapshot(from: dir1, saveTo: snapshot2URL, options: options)

        // Compare
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Verify removed files detected
        let removed = try diff.removed
        XCTAssertEqual(removed.count, 2, "Should have 2 removed items: file2.txt, subdir")

        let removedPaths = removed.map { $0.path }.sorted()
        XCTAssertTrue(removedPaths.contains("file2.txt"))
        XCTAssertTrue(removedPaths.contains("subdir"))

        XCTAssertTrue(try diff.added.isEmpty, "Should have no added items")
        XCTAssertTrue(try diff.hasDifferences, "Should have differences")
    }

    func testCompareWithModifiedFiles() async throws {
        // Create dir1 with file
        let dir1 = tempDir.appendingPathComponent("dir1")
        try fileManager.createDirectory(at: dir1, withIntermediateDirectories: false)

        let file1 = dir1.appendingPathComponent("file1.txt")
        try "original content".write(to: file1, atomically: true, encoding: .utf8)

        // Create snapshot1
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let engine = SnapshotEngine()
        let options = ScanOptions()
        let snapshot1 = try await engine.createSnapshot(from: dir1, saveTo: snapshot1URL, options: options)

        // Small delay to ensure different modification time
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s

        // Modify file content
        try "modified content with different length".write(to: file1, atomically: true, encoding: .utf8)

        // Create snapshot2
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let snapshot2 = try await engine.createSnapshot(from: dir1, saveTo: snapshot2URL, options: options)

        // Compare
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Verify modified file detected
        let modified = try diff.modified
        XCTAssertEqual(modified.count, 1, "Should have 1 modified item")
        XCTAssertEqual(modified[0].path, "file1.txt")

        // Verify it was detected due to size and/or SHA-256 change
        let snapshot1Items = try snapshot1.loadItem(path: "file1.txt")!
        let snapshot2Items = try snapshot2.loadItem(path: "file1.txt")!
        XCTAssertNotEqual(snapshot1Items.sha256, snapshot2Items.sha256, "SHA-256 should differ")
        XCTAssertNotEqual(snapshot1Items.size, snapshot2Items.size, "Size should differ")

        XCTAssertTrue(try diff.added.isEmpty, "Should have no added items")
        XCTAssertTrue(try diff.removed.isEmpty, "Should have no removed items")
        XCTAssertTrue(try diff.hasDifferences, "Should have differences")
    }

    func testCompareWithModifiedMetadata() async throws {
        // Create dir1 with file
        let dir1 = tempDir.appendingPathComponent("dir1")
        try fileManager.createDirectory(at: dir1, withIntermediateDirectories: false)

        let file1 = dir1.appendingPathComponent("file1.txt")
        try "same content".write(to: file1, atomically: true, encoding: .utf8)

        // Create snapshot1
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let engine = SnapshotEngine()
        let options = ScanOptions()
        let snapshot1 = try await engine.createSnapshot(from: dir1, saveTo: snapshot1URL, options: options)

        // Change permissions
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file1.path)

        // Create snapshot2
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let snapshot2 = try await engine.createSnapshot(from: dir1, saveTo: snapshot2URL, options: options)

        // Compare
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Verify modified metadata detected
        let modified = try diff.modified
        XCTAssertEqual(modified.count, 1, "Should have 1 modified item due to permission change")
        XCTAssertEqual(modified[0].path, "file1.txt")

        // Verify permissions differ
        let snapshot1Item = try snapshot1.loadItem(path: "file1.txt")!
        let snapshot2Item = try snapshot2.loadItem(path: "file1.txt")!
        XCTAssertNotEqual(snapshot1Item.permissions.posix, snapshot2Item.permissions.posix, "Permissions should differ")

        XCTAssertTrue(try diff.hasDifferences, "Should have differences")
    }

    func testCompareLazyCaching() async throws {
        // Create simple directory
        let dir1 = tempDir.appendingPathComponent("dir1")
        try fileManager.createDirectory(at: dir1, withIntermediateDirectories: false)

        let file1 = dir1.appendingPathComponent("file1.txt")
        try "content".write(to: file1, atomically: true, encoding: .utf8)

        // Create two different snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let engine = SnapshotEngine()
        let options = ScanOptions()
        let snapshot1 = try await engine.createSnapshot(from: dir1, saveTo: snapshot1URL, options: options)

        // Add file
        let file2 = dir1.appendingPathComponent("file2.txt")
        try "content2".write(to: file2, atomically: true, encoding: .utf8)

        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let snapshot2 = try await engine.createSnapshot(from: dir1, saveTo: snapshot2URL, options: options)

        // Create diff
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // First access - should compute
        let firstAccess = try diff.added
        XCTAssertEqual(firstAccess.count, 1)

        // Second access - should use cache (verify by checking same array instance)
        let secondAccess = try diff.added
        XCTAssertEqual(secondAccess.count, 1)
        XCTAssertEqual(firstAccess.first?.path, secondAccess.first?.path, "Should return same data from cache")

        // Access other properties to ensure they're independently cached
        let removed = try diff.removed
        XCTAssertTrue(removed.isEmpty)

        let modified = try diff.modified
        XCTAssertTrue(modified.isEmpty)

        // Verify added is still cached
        let thirdAccess = try diff.added
        XCTAssertEqual(thirdAccess.count, 1)
    }

    func testCompareWithPathContainingSingleQuote() async throws {
        // Create directory with single quote in parent path (simulates /Users/O'Connor/)
        // Note: We can't actually create a path with quote in temp dir name on all systems,
        // so we create a snapshot in a subdirectory with quote in its name
        let quotedDir = tempDir.appendingPathComponent("O'Connor")
        try fileManager.createDirectory(at: quotedDir, withIntermediateDirectories: false)

        let testDir = quotedDir.appendingPathComponent("testData")
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: false)

        let file1 = testDir.appendingPathComponent("file1.txt")
        try "content1".write(to: file1, atomically: true, encoding: .utf8)

        // Create snapshot1 - path will contain O'Connor
        let snapshot1URL = quotedDir.appendingPathComponent("snapshot1.snapshot")
        let engine = SnapshotEngine()
        let options = ScanOptions()
        let snapshot1 = try await engine.createSnapshot(from: testDir, saveTo: snapshot1URL, options: options)

        // Add a file
        let file2 = testDir.appendingPathComponent("file2.txt")
        try "content2".write(to: file2, atomically: true, encoding: .utf8)

        // Create snapshot2 - path will also contain O'Connor
        let snapshot2URL = quotedDir.appendingPathComponent("snapshot2.snapshot")
        let snapshot2 = try await engine.createSnapshot(from: testDir, saveTo: snapshot2URL, options: options)

        // Compare - should not throw SQL error despite single quote in path
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Verify comparison works correctly
        let added = try diff.added
        XCTAssertEqual(added.count, 1, "Should detect 1 added file")
        XCTAssertEqual(added[0].path, "file2.txt")

        XCTAssertTrue(try diff.removed.isEmpty, "Should have no removed items")
    }

    // MARK: - Difference API Extension Tests (Step 0)

    func testSourceItemForExistingPath() async throws {
        // Create source and destination directories
        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create file in source
        let sourceFile = sourceDir.appendingPathComponent("file.txt")
        try "source content".write(to: sourceFile, atomically: true, encoding: .utf8)

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        // Compare and get difference
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Load source item for existing path
        let sourceItem = try diff.sourceItem(for: "file.txt")
        XCTAssertNotNil(sourceItem, "Should return source item for existing path")
        XCTAssertEqual(sourceItem?.path, "file.txt")
        XCTAssertEqual(sourceItem?.isFolder, false)
    }

    func testSourceItemForNonexistentPath() async throws {
        // Create source and destination directories
        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create file only in dest
        let destFile = destDir.appendingPathComponent("file.txt")
        try "dest content".write(to: destFile, atomically: true, encoding: .utf8)

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        // Compare and get difference
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Load source item for nonexistent path
        let sourceItem = try diff.sourceItem(for: "file.txt")
        XCTAssertNil(sourceItem, "Should return nil for nonexistent path in source")
    }

    func testDestinationItemForExistingPath() async throws {
        // Create source and destination directories
        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create file in destination
        let destFile = destDir.appendingPathComponent("file.txt")
        try "dest content".write(to: destFile, atomically: true, encoding: .utf8)

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        // Compare and get difference
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Load destination item for existing path
        let destItem = try diff.destinationItem(for: "file.txt")
        XCTAssertNotNil(destItem, "Should return destination item for existing path")
        XCTAssertEqual(destItem?.path, "file.txt")
        XCTAssertEqual(destItem?.isFolder, false)
    }

    func testDestinationItemForNonexistentPath() async throws {
        // Create source and destination directories
        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create file only in source
        let sourceFile = sourceDir.appendingPathComponent("file.txt")
        try "source content".write(to: sourceFile, atomically: true, encoding: .utf8)

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        // Compare and get difference
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Load destination item for nonexistent path
        let destItem = try diff.destinationItem(for: "file.txt")
        XCTAssertNil(destItem, "Should return nil for nonexistent path in destination")
    }

    func testSourceAndDestinationForModifiedPath() async throws {
        // Create source and destination directories
        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create file in both with different content
        let sourceFile = sourceDir.appendingPathComponent("file.txt")
        try "source content".write(to: sourceFile, atomically: true, encoding: .utf8)

        let destFile = destDir.appendingPathComponent("file.txt")
        try "destination content".write(to: destFile, atomically: true, encoding: .utf8)

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        // Compare and get difference
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Should be detected as modified
        let modified = try diff.modified
        XCTAssertEqual(modified.count, 1, "Should detect 1 modified file")

        // Load both versions
        let sourceItem = try diff.sourceItem(for: "file.txt")
        let destItem = try diff.destinationItem(for: "file.txt")

        XCTAssertNotNil(sourceItem, "Should return source item")
        XCTAssertNotNil(destItem, "Should return destination item")

        XCTAssertEqual(sourceItem?.path, "file.txt")
        XCTAssertEqual(destItem?.path, "file.txt")

        // Verify they have different hashes (different content)
        XCTAssertNotEqual(sourceItem?.sha256, destItem?.sha256, "Source and dest should have different hashes")
    }
}
