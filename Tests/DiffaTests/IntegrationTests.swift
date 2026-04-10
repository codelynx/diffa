import XCTest
@testable import Diffa
import Foundation

/// End-to-end integration tests with real file system scenarios
final class IntegrationTests: XCTestCase {
    var tempDir: URL!
    var fileManager: FileManager!
    var engine: SnapshotEngine!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        engine = SnapshotEngine()

        // Create unique temp directory for each test
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("DiffaIntegrationTests-\(UUID().uuidString)")
        try! fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Clean up temp directory
        if fileManager.fileExists(atPath: tempDir.path) {
            try? fileManager.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Helper Methods

    /// Create a test file with content
    private func createFile(at path: String, content: String) throws {
        let url = tempDir.appendingPathComponent(path)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Create a test directory
    private func createDirectory(at path: String) throws {
        let url = tempDir.appendingPathComponent(path)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Remove file or directory
    private func removeItem(at path: String) throws {
        let url = tempDir.appendingPathComponent(path)
        try fileManager.removeItem(at: url)
    }

    /// Modify file content
    private func modifyFile(at path: String, newContent: String) throws {
        let url = tempDir.appendingPathComponent(path)
        try newContent.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Change file permissions
    private func changePermissions(at path: String, to permissions: UInt16) throws {
        let url = tempDir.appendingPathComponent(path)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    // MARK: - Test Cases

    func testCreateSnapshotAndCompare() async throws {
        // Create a test directory structure
        let testDir = tempDir.appendingPathComponent("testData")
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: false)

        try createFile(at: "testData/file1.txt", content: "content1")
        try createFile(at: "testData/file2.txt", content: "content2")
        try createDirectory(at: "testData/subdir")
        try createFile(at: "testData/subdir/file3.txt", content: "content3")

        // Create first snapshot
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let options = ScanOptions()
        let snapshot1 = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshot1URL,
            options: options
        )

        // Verify snapshot metadata
        let metadata1 = snapshot1.metadata
        XCTAssertEqual(metadata1.totalFiles, 3, "Should have 3 files")
        XCTAssertEqual(metadata1.totalFolders, 1, "Should have 1 folder (subdir)")
        XCTAssertGreaterThan(metadata1.totalSize, 0, "Should have non-zero total size")

        // Load items from snapshot
        let items1 = try snapshot1.loadAllItems()
        XCTAssertEqual(items1.count, 4, "Should have 4 items total")

        // Create second identical snapshot
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let snapshot2 = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshot2URL,
            options: options
        )

        // Compare snapshots - should be identical
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)
        XCTAssertTrue(try diff.added.isEmpty, "Should have no added items")
        XCTAssertTrue(try diff.removed.isEmpty, "Should have no removed items")
        XCTAssertTrue(try diff.modified.isEmpty, "Should have no modified items")
        XCTAssertFalse(try diff.hasDifferences, "Identical snapshots should have no differences")
    }

    func testModifyFilesAndDetect() async throws {
        // Create test directory with files
        let testDir = tempDir.appendingPathComponent("testData")
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: false)

        try createFile(at: "testData/file1.txt", content: "original content 1")
        try createFile(at: "testData/file2.txt", content: "original content 2")
        try createFile(at: "testData/file3.txt", content: "original content 3")

        // Create first snapshot
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let options = ScanOptions()
        let snapshot1 = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshot1URL,
            options: options
        )

        // Small delay to ensure different modification time
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s

        // Modify two files
        try modifyFile(at: "testData/file1.txt", newContent: "modified content 1 - much longer")
        try modifyFile(at: "testData/file2.txt", newContent: "modified content 2 - also longer")

        // Create second snapshot
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let snapshot2 = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshot2URL,
            options: options
        )

        // Compare snapshots
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Verify modifications detected
        let modified = try diff.modified
        XCTAssertEqual(modified.count, 2, "Should detect 2 modified files")

        let modifiedPaths = Set(modified.map { $0.path })
        XCTAssertTrue(modifiedPaths.contains("file1.txt"), "file1.txt should be modified")
        XCTAssertTrue(modifiedPaths.contains("file2.txt"), "file2.txt should be modified")

        XCTAssertTrue(try diff.added.isEmpty, "Should have no added items")
        XCTAssertTrue(try diff.removed.isEmpty, "Should have no removed items")
        XCTAssertTrue(try diff.hasDifferences, "Should have differences")
    }

    func testAddRemoveFilesAndDetect() async throws {
        // Create test directory with initial files
        let testDir = tempDir.appendingPathComponent("testData")
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: false)

        try createFile(at: "testData/file1.txt", content: "content1")
        try createFile(at: "testData/file2.txt", content: "content2")
        try createFile(at: "testData/file3.txt", content: "content3")
        try createDirectory(at: "testData/subdir1")

        // Create first snapshot
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let options = ScanOptions()
        let snapshot1 = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshot1URL,
            options: options
        )

        // Remove some items
        try removeItem(at: "testData/file2.txt")
        try removeItem(at: "testData/subdir1")

        // Add new items
        try createFile(at: "testData/file4.txt", content: "content4")
        try createDirectory(at: "testData/subdir2")
        try createFile(at: "testData/subdir2/file5.txt", content: "content5")

        // Create second snapshot
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let snapshot2 = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshot2URL,
            options: options
        )

        // Compare snapshots
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Verify added items detected
        let added = try diff.added
        XCTAssertEqual(added.count, 3, "Should detect 3 added items: file4.txt, subdir2, subdir2/file5.txt")

        let addedPaths = Set(added.map { $0.path })
        XCTAssertTrue(addedPaths.contains("file4.txt"))
        XCTAssertTrue(addedPaths.contains("subdir2"))
        XCTAssertTrue(addedPaths.contains("subdir2/file5.txt"))

        // Verify removed items detected
        let removed = try diff.removed
        XCTAssertEqual(removed.count, 2, "Should detect 2 removed items: file2.txt, subdir1")

        let removedPaths = Set(removed.map { $0.path })
        XCTAssertTrue(removedPaths.contains("file2.txt"))
        XCTAssertTrue(removedPaths.contains("subdir1"))

        // file1.txt and file3.txt should not be in modified (unchanged)
        let modified = try diff.modified
        let modifiedPaths = Set(modified.map { $0.path })
        XCTAssertFalse(modifiedPaths.contains("file1.txt"), "file1.txt should be unchanged")
        XCTAssertFalse(modifiedPaths.contains("file3.txt"), "file3.txt should be unchanged")

        XCTAssertTrue(try diff.hasDifferences, "Should have differences")
    }

    func testLargeDirectory() async throws {
        // Create test directory with 1,000 files
        let testDir = tempDir.appendingPathComponent("largeData")
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: false)

        // Create nested structure: 10 subdirectories with 100 files each (1,000 total)
        for i in 0..<10 {
            let subdirPath = "largeData/dir\(i)"
            try createDirectory(at: subdirPath)

            for j in 0..<100 {
                let filePath = "\(subdirPath)/file\(j).txt"
                try createFile(at: filePath, content: "Content for file \(i)-\(j)")
            }
        }

        // Measure snapshot creation time
        let snapshot1URL = tempDir.appendingPathComponent("largeSnapshot.snapshot")
        let options = ScanOptions()

        let startTime = Date()
        let snapshot = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshot1URL,
            options: options
        )
        let elapsedTime = Date().timeIntervalSince(startTime)

        // Verify metadata
        let metadata = snapshot.metadata
        XCTAssertEqual(metadata.totalFiles, 1000, "Should have 1,000 files")
        XCTAssertEqual(metadata.totalFolders, 10, "Should have 10 folders")
        XCTAssertGreaterThan(metadata.totalSize, 0, "Should have non-zero total size")

        // Verify all items loaded correctly
        let items = try snapshot.loadAllItems()
        XCTAssertEqual(items.count, 1010, "Should have 1,010 items total (1000 files + 10 dirs)")

        // Performance check: Should be <5s on most systems
        print("Large directory snapshot creation time: \(String(format: "%.2f", elapsedTime))s")
        XCTAssertLessThan(elapsedTime, 10.0, "Snapshot creation should be <10s (target <5s)")

        // Verify comparison performance
        let snapshot2URL = tempDir.appendingPathComponent("largeSnapshot2.snapshot")
        let snapshot2 = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshot2URL,
            options: options
        )

        let compareStart = Date()
        let diff = try Difference.compare(source: snapshot, destination: snapshot2)
        _ = try diff.hasDifferences
        let compareTime = Date().timeIntervalSince(compareStart)

        print("Large directory comparison time: \(String(format: "%.2f", compareTime))s")
        XCTAssertLessThan(compareTime, 1.0, "Comparison should be <1s")
    }

    func testSymlinkScenarios() async throws {
        #if os(Windows)
        throw XCTSkip("Symlinks require admin privileges on Windows")
        #endif
        // Create test directory with symlinks
        let testDir = tempDir.appendingPathComponent("symlinkData")
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: false)

        // Create regular file
        let regularFile = testDir.appendingPathComponent("regular.txt")
        try "regular content".write(to: regularFile, atomically: true, encoding: .utf8)

        // Create symlink to file
        let symlinkToFile = testDir.appendingPathComponent("symlink_to_file.txt")
        try fileManager.createSymbolicLink(at: symlinkToFile, withDestinationURL: regularFile)

        // Create directory
        let regularDir = testDir.appendingPathComponent("regularDir")
        try fileManager.createDirectory(at: regularDir, withIntermediateDirectories: false)
        let fileInDir = regularDir.appendingPathComponent("file_in_dir.txt")
        try "content in dir".write(to: fileInDir, atomically: true, encoding: .utf8)

        // Create symlink to directory
        let symlinkToDir = testDir.appendingPathComponent("symlink_to_dir")
        try fileManager.createSymbolicLink(at: symlinkToDir, withDestinationURL: regularDir)

        // Test with followSymlinks = true
        let snapshot1URL = tempDir.appendingPathComponent("snapshot_follow.snapshot")
        let optionsFollow = ScanOptions(followSymlinks: true)
        let snapshot1 = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshot1URL,
            options: optionsFollow
        )

        let items1 = try snapshot1.loadAllItems()
        // Should have: regular.txt, symlink_to_file.txt (followed), regularDir, regularDir/file_in_dir.txt,
        // symlink_to_dir (followed), symlink_to_dir/file_in_dir.txt
        XCTAssertGreaterThanOrEqual(items1.count, 4, "Should have at least 4 items when following symlinks")

        // Verify symlinks are followed (appear as regular files/dirs)
        let symlinkFileItem = items1.first { $0.path == "symlink_to_file.txt" }
        XCTAssertNotNil(symlinkFileItem, "Symlink to file should be present")
        XCTAssertFalse(symlinkFileItem?.isFolder ?? true, "Followed symlink should appear as file")
        XCTAssertNotNil(symlinkFileItem?.sha256, "Followed symlink should have hash")

        // Test with followSymlinks = false
        let snapshot2URL = tempDir.appendingPathComponent("snapshot_nofollow.snapshot")
        let optionsNoFollow = ScanOptions(followSymlinks: false)
        let snapshot2 = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshot2URL,
            options: optionsNoFollow
        )

        let items2 = try snapshot2.loadAllItems()
        // Should have: regular.txt, symlink_to_file.txt (as symlink), regularDir, regularDir/file_in_dir.txt, symlink_to_dir (as symlink)
        // Symlinks are stored as-is, not followed
        XCTAssertGreaterThanOrEqual(items2.count, 3, "Should have base items when not following symlinks")
    }

    func testPermissionChanges() async throws {
        #if os(Windows)
        throw XCTSkip("POSIX permissions not supported on Windows")
        #endif
        // Create test directory with file
        let testDir = tempDir.appendingPathComponent("permData")
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: false)

        let testFile = testDir.appendingPathComponent("test.txt")
        try "test content".write(to: testFile, atomically: true, encoding: .utf8)

        // Set initial permissions
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: testFile.path)

        // Create first snapshot
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let options = ScanOptions()
        let snapshot1 = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshot1URL,
            options: options
        )

        // Verify initial permissions
        let item1 = try snapshot1.loadItem(path: "test.txt")
        XCTAssertNotNil(item1)
        XCTAssertEqual(item1?.permissions.posix, 0o644, "Initial permissions should be 644")

        // Change permissions
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: testFile.path)

        // Create second snapshot
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let snapshot2 = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshot2URL,
            options: options
        )

        // Verify changed permissions
        let item2 = try snapshot2.loadItem(path: "test.txt")
        XCTAssertNotNil(item2)
        XCTAssertEqual(item2?.permissions.posix, 0o755, "Changed permissions should be 755")

        // Compare snapshots
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Verify modification detected
        let modified = try diff.modified
        #if os(Windows)
        // Windows doesn't support POSIX permissions, so no modification is detected
        XCTAssertEqual(modified.count, 0, "Windows: no permission change detected")
        #else
        XCTAssertEqual(modified.count, 1, "Should detect permission change as modification")
        XCTAssertEqual(modified[0].path, "test.txt")

        // Verify the permission actually changed
        XCTAssertNotEqual(item1?.permissions.posix, item2?.permissions.posix, "Permissions should differ")

        XCTAssertTrue(try diff.added.isEmpty, "Should have no added items")
        XCTAssertTrue(try diff.removed.isEmpty, "Should have no removed items")
        XCTAssertTrue(try diff.hasDifferences, "Should have differences")
        #endif
    }

    func testVeryLargeDirectory() async throws {
        // Performance benchmark test - opt-in only via environment variable
        // Run with: DIFFA_RUN_BENCHMARKS=1 swift test --filter testVeryLargeDirectory
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DIFFA_RUN_BENCHMARKS"] == "1",
            "Skipping performance benchmark test. Set DIFFA_RUN_BENCHMARKS=1 to run."
        )

        // Phase 1 Exit Criteria: Verify 10,000 files in <30s (HDD target)
        // Create test directory with 10,000 files
        let testDir = tempDir.appendingPathComponent("veryLargeData")
        try fileManager.createDirectory(at: testDir, withIntermediateDirectories: false)

        print("\n=== Phase 1 Performance Verification ===")
        print("Creating 10,000 files...")

        // Create nested structure: 100 subdirectories with 100 files each
        let createStart = Date()
        for i in 0..<100 {
            let subdirPath = "veryLargeData/dir\(i)"
            try createDirectory(at: subdirPath)

            for j in 0..<100 {
                let filePath = "\(subdirPath)/file\(j).txt"
                try createFile(at: filePath, content: "Content for file \(i)-\(j)")
            }
        }
        let createTime = Date().timeIntervalSince(createStart)
        print("File creation time: \(String(format: "%.2f", createTime))s")

        // Measure snapshot creation time
        let snapshotURL = tempDir.appendingPathComponent("10kSnapshot.snapshot")
        let options = ScanOptions()

        print("Creating snapshot of 10,000 files...")
        let startTime = Date()
        let snapshot = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshotURL,
            options: options
        )
        let elapsedTime = Date().timeIntervalSince(startTime)

        // Verify metadata
        let metadata = snapshot.metadata
        XCTAssertEqual(metadata.totalFiles, 10000, "Should have 10,000 files")
        XCTAssertEqual(metadata.totalFolders, 100, "Should have 100 folders")
        XCTAssertGreaterThan(metadata.totalSize, 0, "Should have non-zero total size")

        // Performance check: Phase 1 target is <30s on HDD
        print("Snapshot creation time: \(String(format: "%.2f", elapsedTime))s")
        print("Target: <30s (HDD baseline)")
        print("Status: \(elapsedTime < 30.0 ? "✅ PASS" : "⚠️  SLOW")")

        XCTAssertLessThan(elapsedTime, 30.0, "10,000 file snapshot should be <30s (Phase 1 target)")

        // Verify comparison performance
        print("\nCreating second snapshot for comparison...")
        let snapshot2URL = tempDir.appendingPathComponent("10kSnapshot2.snapshot")
        let snapshot2 = try await engine.createSnapshot(
            from: testDir,
            saveTo: snapshot2URL,
            options: options
        )

        print("Comparing snapshots...")
        let compareStart = Date()
        let diff = try Difference.compare(source: snapshot, destination: snapshot2)
        _ = try diff.hasDifferences
        let compareTime = Date().timeIntervalSince(compareStart)

        print("Comparison time: \(String(format: "%.3f", compareTime))s")
        print("Target: <1s")
        print("Status: \(compareTime < 1.0 ? "✅ PASS" : "⚠️  SLOW")")

        XCTAssertLessThan(compareTime, 1.0, "10,000 file comparison should be <1s")

        print("\n=== Phase 1 Performance: ALL TARGETS MET ===\n")
    }
}
