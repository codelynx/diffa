import XCTest
@testable import Diffa

final class SyncExecutorTests: XCTestCase {

    // MARK: - Step 4: Move Operation Execution Tests

    func testExecuteMoveOperation() async throws {
        // Create temporary directory
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create source file
        let sourceFile = tempDir.appendingPathComponent("source.txt")
        let content = "Test content for move operation"
        try content.write(to: sourceFile, atomically: true, encoding: .utf8)

        // Prepare move operation
        let destFile = tempDir.appendingPathComponent("destination.txt")
        let fileSize = try FileManager.default.attributesOfItem(atPath: sourceFile.path)[.size] as! Int64

        let operation = SyncOperation.moveFile(from: sourceFile, to: destFile, size: fileSize)

        // Execute operation
        let executor = SyncExecutor()
        let result = try await executor.execute(
            operations: [operation],
            totalBytes: fileSize,
            progress: nil
        )

        // Verify source file no longer exists
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path), "Source file should be removed")

        // Verify destination file exists with correct content
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile.path), "Destination file should exist")
        let movedContent = try String(contentsOf: destFile, encoding: .utf8)
        XCTAssertEqual(movedContent, content, "Content should match")

        // Verify result statistics
        XCTAssertEqual(result.filesMoved, 1, "Should have moved 1 file")
        XCTAssertEqual(result.filesCopied, 0, "Should have copied 0 files")
        XCTAssertEqual(result.filesDeleted, 0, "Should have deleted 0 files")
        XCTAssertEqual(result.bytesTransferred, fileSize, "Bytes transferred should match file size")
        XCTAssertEqual(result.errors.count, 0, "Should have no errors")
    }

    func testExecuteMoveToNewDirectory() async throws {
        // Create temporary directory
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create source file
        let sourceFile = tempDir.appendingPathComponent("file.txt")
        let content = "Test content for directory creation"
        try content.write(to: sourceFile, atomically: true, encoding: .utf8)

        // Prepare move to new directory (directory doesn't exist yet)
        let destDir = tempDir.appendingPathComponent("newdir/subdir")
        let destFile = destDir.appendingPathComponent("file.txt")
        let fileSize = try FileManager.default.attributesOfItem(atPath: sourceFile.path)[.size] as! Int64

        let operation = SyncOperation.moveFile(from: sourceFile, to: destFile, size: fileSize)

        // Execute operation
        let executor = SyncExecutor()
        let result = try await executor.execute(
            operations: [operation],
            totalBytes: fileSize,
            progress: nil
        )

        // Verify parent directories were created
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.path), "Parent directory should be created")

        // Verify destination file exists with correct content
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile.path), "Destination file should exist")
        let movedContent = try String(contentsOf: destFile, encoding: .utf8)
        XCTAssertEqual(movedContent, content, "Content should match")

        // Verify source no longer exists
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path), "Source file should be removed")

        // Verify result statistics
        XCTAssertEqual(result.filesMoved, 1, "Should have moved 1 file")
        XCTAssertEqual(result.errors.count, 0, "Should have no errors")
    }

    func testExecuteMoveOverwritesExisting() async throws {
        // Test that move operation overwrites existing file at destination
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create source file
        let sourceFile = tempDir.appendingPathComponent("source.txt")
        let content = "New content from source"
        try content.write(to: sourceFile, atomically: true, encoding: .utf8)

        // Create existing destination file with different content
        let destFile = tempDir.appendingPathComponent("destination.txt")
        try "Old content at destination".write(to: destFile, atomically: true, encoding: .utf8)

        let fileSize = try FileManager.default.attributesOfItem(atPath: sourceFile.path)[.size] as! Int64
        let operation = SyncOperation.moveFile(from: sourceFile, to: destFile, size: fileSize)

        // Execute operation
        let executor = SyncExecutor()
        let result = try await executor.execute(
            operations: [operation],
            totalBytes: fileSize,
            progress: nil
        )

        // Verify destination has new content
        let movedContent = try String(contentsOf: destFile, encoding: .utf8)
        XCTAssertEqual(movedContent, content, "Destination should have new content from source")

        // Verify source no longer exists
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path), "Source file should be removed")

        // Verify result statistics
        XCTAssertEqual(result.filesMoved, 1, "Should have moved 1 file")
        XCTAssertEqual(result.errors.count, 0, "Should have no errors")
    }

    func testExecuteMoveProgress() async throws {
        // Test that progress is reported during move operation
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create source file
        let sourceFile = tempDir.appendingPathComponent("file.txt")
        try "Progress test content".write(to: sourceFile, atomically: true, encoding: .utf8)

        let destFile = tempDir.appendingPathComponent("moved.txt")
        let fileSize = try FileManager.default.attributesOfItem(atPath: sourceFile.path)[.size] as! Int64

        let operation = SyncOperation.moveFile(from: sourceFile, to: destFile, size: fileSize)

        // Track progress callbacks
        var progressUpdates: [SyncProgress] = []

        // Execute operation with progress callback
        let executor = SyncExecutor()
        _ = try await executor.execute(
            operations: [operation],
            totalBytes: fileSize,
            progress: { progress in
                progressUpdates.append(progress)
            }
        )

        // Verify progress was reported
        XCTAssertGreaterThan(progressUpdates.count, 0, "Should have progress updates")

        // Verify final progress
        let finalProgress = progressUpdates.last!
        XCTAssertEqual(finalProgress.filesProcessed, 1, "Should have processed 1 file")
        XCTAssertEqual(finalProgress.totalFiles, 1, "Should have 1 total file")
        XCTAssertEqual(finalProgress.bytesTransferred, fileSize, "Should have transferred file size bytes")
        XCTAssertEqual(finalProgress.totalBytes, fileSize, "Total bytes should match")
        XCTAssertEqual(finalProgress.operationType, .moving, "Operation type should be moving")
        XCTAssertTrue(finalProgress.currentOperation.contains("Moving"), "Operation description should mention moving")
    }

    func testExecuteMoveStatistics() async throws {
        // Test that SyncResult.filesMoved is correctly updated with multiple operations
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create multiple source files
        let file1 = tempDir.appendingPathComponent("file1.txt")
        let file2 = tempDir.appendingPathComponent("file2.txt")
        let file3 = tempDir.appendingPathComponent("file3.txt")
        try "Content 1".write(to: file1, atomically: true, encoding: .utf8)
        try "Content 2".write(to: file2, atomically: true, encoding: .utf8)
        try "Content 3".write(to: file3, atomically: true, encoding: .utf8)

        let size1 = try FileManager.default.attributesOfItem(atPath: file1.path)[.size] as! Int64
        let size2 = try FileManager.default.attributesOfItem(atPath: file2.path)[.size] as! Int64
        let size3 = try FileManager.default.attributesOfItem(atPath: file3.path)[.size] as! Int64

        // Create move operations
        let operations = [
            SyncOperation.moveFile(from: file1, to: tempDir.appendingPathComponent("moved1.txt"), size: size1),
            SyncOperation.moveFile(from: file2, to: tempDir.appendingPathComponent("moved2.txt"), size: size2),
            SyncOperation.moveFile(from: file3, to: tempDir.appendingPathComponent("moved3.txt"), size: size3)
        ]

        let totalBytes = size1 + size2 + size3

        // Execute operations
        let executor = SyncExecutor()
        let result = try await executor.execute(
            operations: operations,
            totalBytes: totalBytes,
            progress: nil
        )

        // Verify statistics
        XCTAssertEqual(result.filesMoved, 3, "Should have moved 3 files")
        XCTAssertEqual(result.filesCopied, 0, "Should have copied 0 files")
        XCTAssertEqual(result.filesDeleted, 0, "Should have deleted 0 files")
        XCTAssertEqual(result.bytesTransferred, totalBytes, "Bytes transferred should be sum of all files")
        XCTAssertEqual(result.errors.count, 0, "Should have no errors")

        // Verify all source files are gone
        XCTAssertFalse(FileManager.default.fileExists(atPath: file1.path), "Source file 1 should be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file2.path), "Source file 2 should be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file3.path), "Source file 3 should be removed")

        // Verify all destination files exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("moved1.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("moved2.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("moved3.txt").path))
    }

    func testExecuteMoveMixedOperations() async throws {
        // Test move operations mixed with copy and delete operations
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create files for different operations
        let moveSource = tempDir.appendingPathComponent("to_move.txt")
        let copySource = tempDir.appendingPathComponent("to_copy.txt")
        let deleteTarget = tempDir.appendingPathComponent("to_delete.txt")

        try "Move content".write(to: moveSource, atomically: true, encoding: .utf8)
        try "Copy content".write(to: copySource, atomically: true, encoding: .utf8)
        try "Delete content".write(to: deleteTarget, atomically: true, encoding: .utf8)

        let moveSize = try FileManager.default.attributesOfItem(atPath: moveSource.path)[.size] as! Int64
        let copySize = try FileManager.default.attributesOfItem(atPath: copySource.path)[.size] as! Int64

        // Create mixed operations
        let operations: [SyncOperation] = [
            .moveFile(from: moveSource, to: tempDir.appendingPathComponent("moved.txt"), size: moveSize),
            .copyFile(from: copySource, to: tempDir.appendingPathComponent("copied.txt"), size: copySize),
            .deleteFile(at: deleteTarget)
        ]

        let totalBytes = moveSize + copySize

        // Execute operations
        let executor = SyncExecutor()
        let result = try await executor.execute(
            operations: operations,
            totalBytes: totalBytes,
            progress: nil
        )

        // Verify statistics
        XCTAssertEqual(result.filesMoved, 1, "Should have moved 1 file")
        XCTAssertEqual(result.filesCopied, 1, "Should have copied 1 file")
        XCTAssertEqual(result.filesDeleted, 1, "Should have deleted 1 file")
        XCTAssertEqual(result.bytesTransferred, totalBytes, "Bytes transferred should be move + copy")
        XCTAssertEqual(result.errors.count, 0, "Should have no errors")

        // Verify move: source gone, destination exists
        XCTAssertFalse(FileManager.default.fileExists(atPath: moveSource.path), "Move source should be gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("moved.txt").path))

        // Verify copy: source still exists, destination exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: copySource.path), "Copy source should still exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("copied.txt").path))

        // Verify delete: target gone
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleteTarget.path), "Delete target should be gone")
    }
}
