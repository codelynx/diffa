import XCTest
@testable import Diffalla

/// End-to-end integration tests for synchronization workflows
final class SynchronizationIntegrationTests: XCTestCase {

    // MARK: - Step 9: Integration Tests

    func testFullUnidirectionalSyncWorkflow() async throws {
        // Create temporary directories
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("source")
        let destination = tempDir.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Create source files
        try "File 1 content".write(to: source.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try "File 2 content".write(to: source.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

        let subdir = source.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "Nested file".write(to: subdir.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)

        // Create file only in destination (should be deleted)
        try "Old file".write(to: destination.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)

        // Perform unidirectional sync (source → destination)
        let synchronizer = Synchronizer()
        let result = try await synchronizer.syncUnidirectional(
            source: source,
            destination: destination,
            options: SyncOptions(deleteExtraFiles: true)
        )

        // Verify result statistics
        XCTAssertEqual(result.filesCopied, 3, "Should copy 3 files from source")
        XCTAssertEqual(result.filesDeleted, 1, "Should delete 1 file from destination")
        XCTAssertTrue(result.bytesTransferred > 0, "Should transfer bytes")
        XCTAssertEqual(result.errors.count, 0, "Should have no errors")

        // Verify destination matches source
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("file1.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("file2.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("subdir/nested.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("old.txt").path))

        // Verify file contents
        let file1Content = try String(contentsOf: destination.appendingPathComponent("file1.txt"))
        XCTAssertEqual(file1Content, "File 1 content")
    }

    func testFullBidirectionalSyncWorkflow() async throws {
        // Create temporary directories
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dirA = tempDir.appendingPathComponent("a")
        let dirB = tempDir.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        // Create files in A
        try "A file 1".write(to: dirA.appendingPathComponent("a1.txt"), atomically: true, encoding: .utf8)
        try "Shared file A version".write(to: dirA.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)

        // Wait to ensure B's version is newer
        try await Task.sleep(nanoseconds: 1_100_000_000) // 1.1 seconds

        // Create files in B
        try "B file 1".write(to: dirB.appendingPathComponent("b1.txt"), atomically: true, encoding: .utf8)
        try "Shared file B version (newer)".write(to: dirB.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)

        // Perform bidirectional sync with .newest strategy
        let synchronizer = Synchronizer()
        let result = try await synchronizer.syncBidirectional(
            a: dirA,
            b: dirB,
            conflictResolution: .newest
        )

        // Verify conflicts detected and resolved
        XCTAssertEqual(result.conflicts.count, 3, "Should detect 3 conflicts (a1.txt, b1.txt, shared.txt)")
        XCTAssertTrue(result.filesCopied > 0, "Should copy files in both directions")
        XCTAssertEqual(result.errors.count, 0, "Should have no errors")

        // Verify both directories identical after sync
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirA.appendingPathComponent("a1.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirA.appendingPathComponent("b1.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirA.appendingPathComponent("shared.txt").path))

        XCTAssertTrue(FileManager.default.fileExists(atPath: dirB.appendingPathComponent("a1.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirB.appendingPathComponent("b1.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirB.appendingPathComponent("shared.txt").path))

        // Verify shared.txt used B's version (newer)
        let sharedContentA = try String(contentsOf: dirA.appendingPathComponent("shared.txt"))
        let sharedContentB = try String(contentsOf: dirB.appendingPathComponent("shared.txt"))
        XCTAssertEqual(sharedContentA, "Shared file B version (newer)")
        XCTAssertEqual(sharedContentB, "Shared file B version (newer)")
    }

    func testSyncWithLargeDirectories() async throws {
        // Create temporary directories
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("source")
        let destination = tempDir.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Create 100 files (reduced from 1,000 for faster testing)
        let fileCount = 100
        let content = String(repeating: "x", count: 1024) // 1 KB per file

        for i in 0..<fileCount {
            let filename = String(format: "file%04d.txt", i)
            try content.write(to: source.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }

        // Measure sync time
        let startTime = Date()
        let synchronizer = Synchronizer()
        let result = try await synchronizer.syncUnidirectional(
            source: source,
            destination: destination
        )
        let duration = Date().timeIntervalSince(startTime)

        // Verify all files copied
        XCTAssertEqual(result.filesCopied, fileCount, "Should copy all \(fileCount) files")
        XCTAssertEqual(result.errors.count, 0, "Should have no errors")
        XCTAssertTrue(result.bytesTransferred >= Int64(fileCount * 1024), "Should transfer at least \(fileCount) KB")

        // Performance check (should be fast for 100 files)
        XCTAssertLessThan(duration, 10.0, "Sync should complete in less than 10 seconds for \(fileCount) files")

        // Verify all files exist in destination
        for i in 0..<fileCount {
            let filename = String(format: "file%04d.txt", i)
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(filename).path))
        }
    }

    func testSyncWithConflictResolution() async throws {
        // Create temporary directories
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dirA = tempDir.appendingPathComponent("a")
        let dirB = tempDir.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        // Create diverged file (same path, different content)
        try "Version from A".write(to: dirA.appendingPathComponent("conflict.txt"), atomically: true, encoding: .utf8)
        try "Version from B".write(to: dirB.appendingPathComponent("conflict.txt"), atomically: true, encoding: .utf8)

        // Create files only in A
        try "Only in A".write(to: dirA.appendingPathComponent("a-only.txt"), atomically: true, encoding: .utf8)

        // Create files only in B
        try "Only in B".write(to: dirB.appendingPathComponent("b-only.txt"), atomically: true, encoding: .utf8)

        // Test sourceWins strategy
        let synchronizer = Synchronizer()
        let result = try await synchronizer.syncBidirectional(
            a: dirA,
            b: dirB,
            conflictResolution: .sourceWins
        )

        // Verify conflicts detected
        XCTAssertEqual(result.conflicts.count, 3, "Should detect 3 conflicts")
        XCTAssertEqual(result.errors.count, 0, "Should have no errors")

        // Verify sourceWins behavior:
        // - conflict.txt should use A's version in both
        // - a-only.txt should be in both
        // - b-only.txt should be deleted from B
        let conflictContentA = try String(contentsOf: dirA.appendingPathComponent("conflict.txt"))
        let conflictContentB = try String(contentsOf: dirB.appendingPathComponent("conflict.txt"))
        XCTAssertEqual(conflictContentA, "Version from A")
        XCTAssertEqual(conflictContentB, "Version from A")

        XCTAssertTrue(FileManager.default.fileExists(atPath: dirA.appendingPathComponent("a-only.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirB.appendingPathComponent("a-only.txt").path))

        XCTAssertFalse(FileManager.default.fileExists(atPath: dirB.appendingPathComponent("b-only.txt").path),
                       "b-only.txt should be deleted from B (sourceWins)")
    }

    func testSyncProgressReporting() async throws {
        // Create temporary directories
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("source")
        let destination = tempDir.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Create 10 files
        for i in 0..<10 {
            let filename = "file\(i).txt"
            try "Content \(i)".write(to: source.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }

        // Track progress callbacks
        var progressCallbacks: [SyncProgress] = []

        // Perform sync with progress tracking
        let synchronizer = Synchronizer()
        let result = try await synchronizer.syncUnidirectional(
            source: source,
            destination: destination,
            progress: { progress in
                progressCallbacks.append(progress)
            }
        )

        // Verify progress callbacks were made
        XCTAssertTrue(progressCallbacks.count > 0, "Should receive progress callbacks")
        XCTAssertEqual(result.filesCopied, 10, "Should copy 10 files")

        // Verify progress information
        for progress in progressCallbacks {
            XCTAssertTrue(progress.filesProcessed >= 0, "Files processed should be non-negative")
            XCTAssertTrue(progress.bytesTransferred >= 0, "Bytes transferred should be non-negative")
            XCTAssertFalse(progress.currentOperation.isEmpty, "Should have operation description")
        }

        // Verify final progress reflects completion
        if let lastProgress = progressCallbacks.last {
            XCTAssertEqual(lastProgress.filesProcessed, 10, "Final progress should show all files processed")
        }
    }

    func testSyncDryRunDoesNotModify() async throws {
        // Create temporary directories
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("source")
        let destination = tempDir.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Create source files
        try "File 1".write(to: source.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try "File 2".write(to: source.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

        // Create destination file that should be deleted (but won't be in dry run)
        try "Old file".write(to: destination.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)

        // Take snapshot of destination before dry run
        let oldFileExistedBefore = FileManager.default.fileExists(atPath: destination.appendingPathComponent("old.txt").path)
        let file1ExistedBefore = FileManager.default.fileExists(atPath: destination.appendingPathComponent("file1.txt").path)

        // Perform dry run
        let synchronizer = Synchronizer()
        let result = try await synchronizer.syncUnidirectional(
            source: source,
            destination: destination,
            options: SyncOptions(dryRun: true, deleteExtraFiles: true)
        )

        // Verify result shows what WOULD happen
        XCTAssertEqual(result.filesCopied, 2, "Dry run should report 2 files would be copied")
        XCTAssertEqual(result.filesDeleted, 1, "Dry run should report 1 file would be deleted")
        XCTAssertEqual(result.errors.count, 0, "Should have no errors")

        // Verify destination was NOT modified
        let oldFileExistsAfter = FileManager.default.fileExists(atPath: destination.appendingPathComponent("old.txt").path)
        let file1ExistsAfter = FileManager.default.fileExists(atPath: destination.appendingPathComponent("file1.txt").path)

        XCTAssertEqual(oldFileExistedBefore, oldFileExistsAfter, "old.txt should not be deleted in dry run")
        XCTAssertEqual(file1ExistedBefore, file1ExistsAfter, "file1.txt should not be copied in dry run")

        XCTAssertTrue(oldFileExistsAfter, "old.txt should still exist after dry run")
        XCTAssertFalse(file1ExistsAfter, "file1.txt should NOT exist after dry run")
    }
}
