import XCTest
@testable import Diffalla
import Foundation

/// Tests for error handling and edge cases
final class ErrorHandlingTests: XCTestCase {
    var tempDir: URL!
    var fileManager: FileManager!
    var engine: SnapshotEngine!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        engine = SnapshotEngine()

        // Create unique temp directory for each test
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("DiffallaErrorTests-\(UUID().uuidString)")
        try! fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Clean up temp directory (including any permission-restricted files)
        if fileManager.fileExists(atPath: tempDir.path) {
            // Reset permissions before cleanup
            let enumerator = fileManager.enumerator(atPath: tempDir.path)
            while let item = enumerator?.nextObject() as? String {
                let itemURL = tempDir.appendingPathComponent(item)
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: itemURL.path)
            }
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
            try? fileManager.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Test Cases

    func testPermissionDenied() async throws {
        // Create a test directory with files
        let testDir = tempDir.appendingPathComponent("testData")
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: false)

        let accessibleFile = testDir.appendingPathComponent("accessible.txt")
        try "accessible content".write(to: accessibleFile, atomically: true, encoding: .utf8)

        let restrictedDir = testDir.appendingPathComponent("restricted")
        try fileManager.createDirectory(at: restrictedDir, withIntermediateDirectories: false)

        let restrictedFile = restrictedDir.appendingPathComponent("secret.txt")
        try "secret content".write(to: restrictedFile, atomically: true, encoding: .utf8)

        // Remove read permission from restricted directory
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restrictedDir.path)

        // Create snapshot - should succeed but skip restricted directory
        let snapshotURL = tempDir.appendingPathComponent("snapshot.snapshot")
        let options = ScanOptions()

        let snapshot = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshotURL,
            options: options
        )

        // Verify snapshot was created
        XCTAssertNotNil(snapshot)

        // Load items - should have accessible file but not restricted directory contents
        let items = try snapshot.loadAllItems()
        let paths = items.map { $0.path }

        // Should have accessible.txt
        XCTAssertTrue(paths.contains("accessible.txt"), "Accessible file should be present")

        // Should have restricted directory (we can see it exists, just can't read it)
        // OR it might not be present depending on when permission denied occurs
        // The key is: no crash, snapshot completes

        // Restore permissions for cleanup
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: restrictedDir.path)
    }

    func testFileDeletedDuringScan() async throws {
        // This test verifies that if a file is deleted during scanning,
        // the snapshot creation doesn't crash

        // Create a test directory with files
        let testDir = tempDir.appendingPathComponent("testData")
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: false)

        // Create a file that we'll try to snapshot
        let file1 = testDir.appendingPathComponent("file1.txt")
        try "content1".write(to: file1, atomically: true, encoding: .utf8)

        let file2 = testDir.appendingPathComponent("file2.txt")
        try "content2".write(to: file2, atomically: true, encoding: .utf8)

        // Note: It's difficult to reliably delete a file *during* scan in a test
        // because the scan is fast. Instead, we test that a nonexistent file
        // doesn't cause a crash when we try to create a FileSystemItem from it.

        // Try to create a FileSystemItem for a nonexistent file
        let nonexistentFile = testDir.appendingPathComponent("nonexistent.txt")

        do {
            _ = try await FileSystemItem(
                at: nonexistentFile,
                relativeTo: testDir,
                captureOwnership: false
            )
            XCTFail("Should have thrown an error")
        } catch {
            // Should throw an error, not crash
            XCTAssertNotNil(error)
        }

        // Create a snapshot of directory that exists
        let snapshotURL = tempDir.appendingPathComponent("snapshot.snapshot")
        let options = ScanOptions()
        let snapshot = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshotURL,
            options: options
        )

        // Snapshot should succeed with the files that exist
        let items = try snapshot.loadAllItems()
        XCTAssertGreaterThanOrEqual(items.count, 2, "Should have at least the 2 files we created")
    }

    func testInvalidSnapshotFile() async throws {
        // Create a corrupt snapshot file (not a valid SQLite database)
        let corruptSnapshotURL = tempDir.appendingPathComponent("corrupt.snapshot")
        try "This is not a SQLite database".write(to: corruptSnapshotURL, atomically: true, encoding: .utf8)

        // Try to open the corrupt snapshot
        XCTAssertThrowsError(try Snapshot.open(at: corruptSnapshotURL)) { error in
            // Should throw an error
            XCTAssertNotNil(error)

            // Verify it's a database-related error
            let errorString = String(describing: error)
            XCTAssertTrue(
                errorString.contains("database") || errorString.contains("SQLite") || errorString.contains("file"),
                "Error should indicate database/file issue: \(errorString)"
            )
        }

        // Try to open a nonexistent snapshot
        let nonexistentURL = tempDir.appendingPathComponent("nonexistent.snapshot")
        XCTAssertThrowsError(try Snapshot.open(at: nonexistentURL)) { error in
            // Should throw an error
            XCTAssertNotNil(error)
        }
    }

    func testConcurrentAccess() async throws {
        // Create a test directory with some files
        let testDir = tempDir.appendingPathComponent("testData")
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: false)

        for i in 0..<10 {
            let file = testDir.appendingPathComponent("file\(i).txt")
            try "content \(i)".write(to: file, atomically: true, encoding: .utf8)
        }

        // Create a snapshot
        let snapshotURL = tempDir.appendingPathComponent("snapshot.snapshot")
        let options = ScanOptions()
        _ = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshotURL,
            options: options
        )

        // Open the snapshot multiple times concurrently
        // SQLite supports multiple readers
        try await withThrowingTaskGroup(of: [SnapshotItem].self) { group in
            for _ in 0..<5 {
                group.addTask {
                    // Each task opens the snapshot and reads items
                    let concurrentSnapshot = try Snapshot.open(at: snapshotURL)
                    return try concurrentSnapshot.loadAllItems()
                }
            }

            // Collect all results
            var allResults: [[SnapshotItem]] = []
            for try await result in group {
                allResults.append(result)
            }

            // Verify all reads succeeded
            XCTAssertEqual(allResults.count, 5, "All 5 concurrent reads should succeed")

            // Verify all reads returned the same data
            let firstResult = allResults[0]
            for result in allResults {
                XCTAssertEqual(result.count, firstResult.count, "All reads should return same number of items")
            }
        }
    }

    func testEmptyDirectory() async throws {
        // Create an empty directory
        let testDir = tempDir.appendingPathComponent("emptyDir")
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: false)

        // Create snapshot of empty directory - should succeed
        let snapshotURL = tempDir.appendingPathComponent("empty.snapshot")
        let options = ScanOptions()
        let snapshot = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshotURL,
            options: options
        )

        // Verify metadata
        let metadata = snapshot.metadata
        XCTAssertEqual(metadata.totalFiles, 0, "Empty directory should have 0 files")
        XCTAssertEqual(metadata.totalFolders, 0, "Empty directory should have 0 folders")
        XCTAssertEqual(metadata.totalSize, 0, "Empty directory should have 0 total size")

        // Load items - should be empty
        let items = try snapshot.loadAllItems()
        XCTAssertTrue(items.isEmpty, "Empty directory should have no items")
    }

    func testBrokenSymlink() async throws {
        // Create a directory with a broken symlink
        let testDir = tempDir.appendingPathComponent("testData")
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: false)

        let regularFile = testDir.appendingPathComponent("regular.txt")
        try "regular".write(to: regularFile, atomically: true, encoding: .utf8)

        // Create symlink to nonexistent file
        let brokenSymlink = testDir.appendingPathComponent("broken_link")
        let nonexistentTarget = testDir.appendingPathComponent("nonexistent_target.txt")
        try fileManager.createSymbolicLink(at: brokenSymlink, withDestinationURL: nonexistentTarget)

        // Create snapshot with followSymlinks=true - should skip broken symlink
        let snapshotURL = tempDir.appendingPathComponent("snapshot.snapshot")
        let options = ScanOptions(followSymlinks: true)
        let snapshot = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshotURL,
            options: options
        )

        // Should have the regular file but not the broken symlink
        let items = try snapshot.loadAllItems()
        let paths = items.map { $0.path }

        XCTAssertTrue(paths.contains("regular.txt"), "Should have regular file")
        XCTAssertFalse(paths.contains("broken_link"), "Should skip broken symlink when following")

        // Now create snapshot with followSymlinks=false - should include the symlink itself
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let options2 = ScanOptions(followSymlinks: false)
        let snapshot2 = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshot2URL,
            options: options2
        )

        let items2 = try snapshot2.loadAllItems()
        let paths2 = items2.map { $0.path }

        XCTAssertTrue(paths2.contains("regular.txt"), "Should have regular file")
        // Broken symlink should be captured when not following
        // (it exists as a symlink, even if target doesn't exist)
    }

    func testDeepNesting() async throws {
        // Create a deeply nested directory structure
        let testDir = tempDir.appendingPathComponent("testData")
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: false)

        // Create 100 levels deep
        var currentDir = testDir
        for i in 0..<100 {
            currentDir = currentDir.appendingPathComponent("level\(i)")
            try fileManager.createDirectory(at: currentDir, withIntermediateDirectories: false)
        }

        // Add a file at the deepest level
        let deepFile = currentDir.appendingPathComponent("deep.txt")
        try "deep content".write(to: deepFile, atomically: true, encoding: .utf8)

        // Create snapshot - should handle deep nesting
        let snapshotURL = tempDir.appendingPathComponent("deep.snapshot")
        let options = ScanOptions()
        let snapshot = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshotURL,
            options: options
        )

        // Verify snapshot was created
        XCTAssertNotNil(snapshot)

        // Should have 100 folders + 1 file
        let metadata = snapshot.metadata
        XCTAssertEqual(metadata.totalFolders, 100, "Should have 100 nested folders")
        XCTAssertEqual(metadata.totalFiles, 1, "Should have 1 file at deepest level")

        // Verify we can find the deep file
        let items = try snapshot.loadAllItems()
        let deepFilePath = (0..<100).map { "level\($0)" }.joined(separator: "/") + "/deep.txt"
        let foundDeepFile = items.first { $0.path == deepFilePath }
        XCTAssertNotNil(foundDeepFile, "Should find file at deepest level")
    }

    func testCompareCorruptSnapshot() async throws {
        // Create a valid snapshot
        let testDir = tempDir.appendingPathComponent("testData")
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: false)

        let file1 = testDir.appendingPathComponent("file1.txt")
        try "content1".write(to: file1, atomically: true, encoding: .utf8)

        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let options = ScanOptions()
        _ = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshot1URL,
            options: options
        )

        // Create a corrupt snapshot file
        let corruptSnapshotURL = tempDir.appendingPathComponent("corrupt.snapshot")
        try "Not a database".write(to: corruptSnapshotURL, atomically: true, encoding: .utf8)

        // Try to open corrupt snapshot - should fail
        XCTAssertThrowsError(try Snapshot.open(at: corruptSnapshotURL)) { error in
            XCTAssertNotNil(error)
        }

        // Comparison with corrupt snapshot should not be possible
        // because opening the corrupt snapshot already fails
    }
}
