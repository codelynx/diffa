import XCTest
@testable import Diffalla

final class SynchronizationTests: XCTestCase {

    // MARK: - Step 1: Sync Core Types Tests

    func testSyncProgressCreation() {
        // Create a SyncProgress instance
        let progress = SyncProgress(
            currentOperation: "Copying file.txt",
            filesProcessed: 10,
            totalFiles: 100,
            bytesTransferred: 1024,
            totalBytes: 10240,
            operationType: .copying
        )

        // Verify all properties
        XCTAssertEqual(progress.currentOperation, "Copying file.txt")
        XCTAssertEqual(progress.filesProcessed, 10)
        XCTAssertEqual(progress.totalFiles, 100)
        XCTAssertEqual(progress.bytesTransferred, 1024)
        XCTAssertEqual(progress.totalBytes, 10240)
        XCTAssertEqual(progress.operationType, .copying)
    }

    func testOperationTypeCodable() throws {
        // Test all operation types can be encoded/decoded
        let types: [OperationType] = [.comparing, .copying, .deleting, .moving]

        for type in types {
            // Encode
            let encoder = JSONEncoder()
            let data = try encoder.encode(type)

            // Decode
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(OperationType.self, from: data)

            // Verify
            XCTAssertEqual(decoded, type, "OperationType \(type) should round-trip correctly")
        }
    }

    func testSyncResultCreation() {
        // Create a SyncResult instance
        let result = SyncResult(
            filesCopied: 5,
            filesDeleted: 3,
            filesMoved: 2,
            bytesTransferred: 5120,
            conflicts: [],
            duration: 1.5,
            errors: []
        )

        // Verify all properties
        XCTAssertEqual(result.filesCopied, 5)
        XCTAssertEqual(result.filesDeleted, 3)
        XCTAssertEqual(result.filesMoved, 2)
        XCTAssertEqual(result.bytesTransferred, 5120)
        XCTAssertEqual(result.conflicts.count, 0)
        XCTAssertEqual(result.duration, 1.5)
        XCTAssertEqual(result.errors.count, 0)
    }

    func testConflictCreation() {
        // Create mock SnapshotItems
        let sourceItem = SnapshotItem(
            id: 1,
            parentId: nil,
            path: "file.txt",
            name: "file.txt",
            isFolder: false,
            size: 100,
            modificationDate: Date(),
            permissions: FilePermissions(posix: 0o644),
            owner: nil,
            group: nil,
            sha256: "source-hash"
        )

        let destItem = SnapshotItem(
            id: 2,
            parentId: nil,
            path: "file.txt",
            name: "file.txt",
            isFolder: false,
            size: 200,
            modificationDate: Date(),
            permissions: FilePermissions(posix: 0o644),
            owner: nil,
            group: nil,
            sha256: "dest-hash"
        )

        // Create a conflict
        let conflict = Conflict(
            path: "file.txt",
            type: .diverged,
            sourceItem: sourceItem,
            destinationItem: destItem
        )

        // Verify properties
        XCTAssertEqual(conflict.path, "file.txt")
        XCTAssertEqual(conflict.type, .diverged)
        XCTAssertNotNil(conflict.sourceItem)
        XCTAssertNotNil(conflict.destinationItem)
        XCTAssertEqual(conflict.sourceItem?.sha256, "source-hash")
        XCTAssertEqual(conflict.destinationItem?.sha256, "dest-hash")
    }

    // MARK: - Step 2: Sync Plan & Operations Tests

    func testPlanUnidirectionalWithAdded() async throws {
        // Items only in destination should be DELETED for unidirectional sync
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create file only in destination
        let destFile = destDir.appendingPathComponent("extra.txt")
        try "extra content".write(to: destFile, atomically: true, encoding: .utf8)

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        // Compare
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Plan unidirectional sync
        let planner = SyncPlanner()
        let operations = try planner.planUnidirectional(
            difference: diff,
            sourceDirectory: sourceDir,
            destinationDirectory: destDir
        )

        // Should plan to delete the extra file in destination
        XCTAssertEqual(operations.count, 1)
        if case .deleteFile(let path) = operations[0] {
            XCTAssertTrue(path.path.hasSuffix("extra.txt"))
        } else {
            XCTFail("Expected deleteFile operation")
        }
    }

    func testPlanUnidirectionalWithRemoved() async throws {
        // Items only in source should be COPIED to destination for unidirectional sync
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create file only in source
        let sourceFile = sourceDir.appendingPathComponent("new.txt")
        try "new content".write(to: sourceFile, atomically: true, encoding: .utf8)

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        // Compare
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Plan unidirectional sync
        let planner = SyncPlanner()
        let operations = try planner.planUnidirectional(
            difference: diff,
            sourceDirectory: sourceDir,
            destinationDirectory: destDir
        )

        // Should plan to copy the new file from source to destination
        XCTAssertEqual(operations.count, 1)
        if case .copyFile(let from, let to, let size) = operations[0] {
            XCTAssertTrue(from.path.hasSuffix("new.txt"))
            XCTAssertTrue(to.path.hasSuffix("new.txt"))
            XCTAssertGreaterThan(size, 0)
        } else {
            XCTFail("Expected copyFile operation")
        }
    }

    func testPlanUnidirectionalWithModified() async throws {
        // Modified items should be COPIED from source to destination
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create file in both with different content
        let sourceFile = sourceDir.appendingPathComponent("modified.txt")
        try "source content".write(to: sourceFile, atomically: true, encoding: .utf8)

        let destFile = destDir.appendingPathComponent("modified.txt")
        try "dest content".write(to: destFile, atomically: true, encoding: .utf8)

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        // Compare
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Plan unidirectional sync
        let planner = SyncPlanner()
        let operations = try planner.planUnidirectional(
            difference: diff,
            sourceDirectory: sourceDir,
            destinationDirectory: destDir
        )

        // Should plan to copy the modified file from source to destination
        XCTAssertEqual(operations.count, 1)
        if case .copyFile(let from, let to, let size) = operations[0] {
            XCTAssertTrue(from.path.hasSuffix("modified.txt"))
            XCTAssertTrue(to.path.hasSuffix("modified.txt"))
            XCTAssertGreaterThan(size, 0)
        } else {
            XCTFail("Expected copyFile operation")
        }
    }

    func testPlanUnidirectionalWithMixed() async throws {
        // Test all operation types together
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Source: new.txt, modified.txt
        try "new".write(to: sourceDir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try "source modified".write(to: sourceDir.appendingPathComponent("modified.txt"), atomically: true, encoding: .utf8)

        // Dest: extra.txt, modified.txt
        try "extra".write(to: destDir.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        try "dest modified".write(to: destDir.appendingPathComponent("modified.txt"), atomically: true, encoding: .utf8)

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        // Compare
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Plan unidirectional sync
        let planner = SyncPlanner()
        let operations = try planner.planUnidirectional(
            difference: diff,
            sourceDirectory: sourceDir,
            destinationDirectory: destDir
        )

        // Should have:
        // - 1 copyFile for new.txt (from source)
        // - 1 deleteFile for extra.txt (from dest)
        // - 1 copyFile for modified.txt (update from source)
        XCTAssertEqual(operations.count, 3)

        var hasCopyNew = false
        var hasDeleteExtra = false
        var hasCopyModified = false

        for op in operations {
            switch op {
            case .copyFile(let from, _, _):
                if from.path.hasSuffix("new.txt") {
                    hasCopyNew = true
                } else if from.path.hasSuffix("modified.txt") {
                    hasCopyModified = true
                }
            case .deleteFile(let at):
                if at.path.hasSuffix("extra.txt") {
                    hasDeleteExtra = true
                }
            default:
                break
            }
        }

        XCTAssertTrue(hasCopyNew, "Should copy new.txt from source")
        XCTAssertTrue(hasDeleteExtra, "Should delete extra.txt from dest")
        XCTAssertTrue(hasCopyModified, "Should copy modified.txt from source")
    }

    func testCalculateTotalBytes() {
        // Create some operations
        let operations: [SyncOperation] = [
            .copyFile(from: URL(fileURLWithPath: "/a"), to: URL(fileURLWithPath: "/b"), size: 100),
            .deleteFile(at: URL(fileURLWithPath: "/c")),
            .copyFile(from: URL(fileURLWithPath: "/d"), to: URL(fileURLWithPath: "/e"), size: 200),
            .createDirectory(at: URL(fileURLWithPath: "/f")),
            .copyFile(from: URL(fileURLWithPath: "/g"), to: URL(fileURLWithPath: "/h"), size: 50),
        ]

        let planner = SyncPlanner()
        let totalBytes = planner.calculateTotalBytes(operations: operations)

        // Should sum only copyFile sizes: 100 + 200 + 50 = 350
        XCTAssertEqual(totalBytes, 350)
    }

    // MARK: - Step 3: Sync Executor Tests

    func testExecuteCopyOperation() async throws {
        // Create temp directories
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFile = tempDir.appendingPathComponent("source.txt")
        let destFile = tempDir.appendingPathComponent("dest.txt")

        // Create source file
        let content = "test content"
        try content.write(to: sourceFile, atomically: true, encoding: .utf8)

        // Create and execute copy operation
        let operation = SyncOperation.copyFile(
            from: sourceFile,
            to: destFile,
            size: Int64(content.utf8.count)
        )

        let executor = SyncExecutor()
        let result = try await executor.execute(
            operations: [operation],
            totalBytes: Int64(content.utf8.count),
            progress: nil
        )

        // Verify file was copied
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile.path))
        let copiedContent = try String(contentsOf: destFile, encoding: .utf8)
        XCTAssertEqual(copiedContent, content)

        // Verify result
        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertEqual(result.bytesTransferred, Int64(content.utf8.count))
        XCTAssertEqual(result.errors.count, 0)
    }

    func testExecuteDeleteOperation() async throws {
        // Create temp directory
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileToDelete = tempDir.appendingPathComponent("delete_me.txt")

        // Create file
        try "content".write(to: fileToDelete, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileToDelete.path))

        // Create and execute delete operation
        let operation = SyncOperation.deleteFile(at: fileToDelete)

        let executor = SyncExecutor()
        let result = try await executor.execute(
            operations: [operation],
            totalBytes: 0,
            progress: nil
        )

        // Verify file was deleted
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileToDelete.path))

        // Verify result
        XCTAssertEqual(result.filesDeleted, 1)
        XCTAssertEqual(result.errors.count, 0)
    }

    func testExecuteMultipleOperations() async throws {
        // Create temp directories
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Setup: create source files and files to delete
        let sourceFile1 = tempDir.appendingPathComponent("source1.txt")
        let sourceFile2 = tempDir.appendingPathComponent("source2.txt")
        let destFile1 = tempDir.appendingPathComponent("dest1.txt")
        let destFile2 = tempDir.appendingPathComponent("dest2.txt")
        let fileToDelete = tempDir.appendingPathComponent("delete.txt")
        let newDir = tempDir.appendingPathComponent("newdir")

        try "content1".write(to: sourceFile1, atomically: true, encoding: .utf8)
        try "content2".write(to: sourceFile2, atomically: true, encoding: .utf8)
        try "old".write(to: fileToDelete, atomically: true, encoding: .utf8)

        // Create mixed operations
        let operations: [SyncOperation] = [
            .copyFile(from: sourceFile1, to: destFile1, size: 8),
            .copyFile(from: sourceFile2, to: destFile2, size: 8),
            .deleteFile(at: fileToDelete),
            .createDirectory(at: newDir)
        ]

        let executor = SyncExecutor()
        let result = try await executor.execute(
            operations: operations,
            totalBytes: 16,
            progress: nil
        )

        // Verify all operations executed
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile2.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileToDelete.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDir.path))

        // Verify result
        XCTAssertEqual(result.filesCopied, 2)
        XCTAssertEqual(result.filesDeleted, 1)
        XCTAssertEqual(result.bytesTransferred, 16)
        XCTAssertEqual(result.errors.count, 0)
    }

    func testExecuteReportsProgress() async throws {
        // Create temp directory
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFile = tempDir.appendingPathComponent("source.txt")
        let destFile = tempDir.appendingPathComponent("dest.txt")

        try "content".write(to: sourceFile, atomically: true, encoding: .utf8)

        let operation = SyncOperation.copyFile(from: sourceFile, to: destFile, size: 7)

        // Track progress callbacks
        var progressReports: [SyncProgress] = []

        let executor = SyncExecutor()
        _ = try await executor.execute(
            operations: [operation],
            totalBytes: 7,
            progress: { progress in
                progressReports.append(progress)
            }
        )

        // Verify progress was reported
        XCTAssertGreaterThan(progressReports.count, 0)

        if let lastProgress = progressReports.last {
            XCTAssertEqual(lastProgress.filesProcessed, 1)
            XCTAssertEqual(lastProgress.totalFiles, 1)
            XCTAssertEqual(lastProgress.bytesTransferred, 7)
            XCTAssertEqual(lastProgress.totalBytes, 7)
            XCTAssertEqual(lastProgress.operationType, .copying)
        }
    }

    func testExecuteCollectsStatistics() async throws {
        // Create temp directory
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create files
        let source1 = tempDir.appendingPathComponent("s1.txt")
        let source2 = tempDir.appendingPathComponent("s2.txt")
        let dest1 = tempDir.appendingPathComponent("d1.txt")
        let dest2 = tempDir.appendingPathComponent("d2.txt")
        let toDelete = tempDir.appendingPathComponent("del.txt")

        try "12345".write(to: source1, atomically: true, encoding: .utf8)
        try "1234567890".write(to: source2, atomically: true, encoding: .utf8)
        try "old".write(to: toDelete, atomically: true, encoding: .utf8)

        let operations: [SyncOperation] = [
            .copyFile(from: source1, to: dest1, size: 5),
            .copyFile(from: source2, to: dest2, size: 10),
            .deleteFile(at: toDelete)
        ]

        let executor = SyncExecutor()
        let result = try await executor.execute(
            operations: operations,
            totalBytes: 15,
            progress: nil
        )

        // Verify statistics
        XCTAssertEqual(result.filesCopied, 2, "Should have copied 2 files")
        XCTAssertEqual(result.filesDeleted, 1, "Should have deleted 1 file")
        XCTAssertEqual(result.filesMoved, 0, "No files moved")
        XCTAssertEqual(result.bytesTransferred, 15, "Should have transferred 15 bytes")
        XCTAssertEqual(result.conflicts.count, 0, "No conflicts in Step 3")
        XCTAssertEqual(result.errors.count, 0, "No errors")
        XCTAssertGreaterThan(result.duration, 0, "Duration should be positive")
    }

    // MARK: - Step 4: Unidirectional Sync Tests

    func testSyncUnidirectionalEmptyToEmpty() async throws {
        // Create two empty directories
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Sync empty to empty
        let synchronizer = Synchronizer()
        let result = try await synchronizer.syncUnidirectional(
            source: sourceDir,
            destination: destDir
        )

        // Should have no operations
        XCTAssertEqual(result.filesCopied, 0)
        XCTAssertEqual(result.filesDeleted, 0)
        XCTAssertEqual(result.bytesTransferred, 0)
        XCTAssertEqual(result.errors.count, 0)
    }

    func testSyncUnidirectionalWithNewFiles() async throws {
        // Create directories with new files in source
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create files in source
        try "file1 content".write(to: sourceDir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try "file2 content".write(to: sourceDir.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

        // Sync
        let synchronizer = Synchronizer()
        let result = try await synchronizer.syncUnidirectional(
            source: sourceDir,
            destination: destDir
        )

        // Verify files copied
        XCTAssertEqual(result.filesCopied, 2)
        XCTAssertEqual(result.errors.count, 0)

        // Verify files exist in destination
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("file1.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("file2.txt").path))

        // Verify content
        let content1 = try String(contentsOf: destDir.appendingPathComponent("file1.txt"), encoding: .utf8)
        let content2 = try String(contentsOf: destDir.appendingPathComponent("file2.txt"), encoding: .utf8)
        XCTAssertEqual(content1, "file1 content")
        XCTAssertEqual(content2, "file2 content")
    }

    func testSyncUnidirectionalWithDeletedFiles() async throws {
        // Create directories with extra files in destination
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create files only in destination
        try "extra1".write(to: destDir.appendingPathComponent("extra1.txt"), atomically: true, encoding: .utf8)
        try "extra2".write(to: destDir.appendingPathComponent("extra2.txt"), atomically: true, encoding: .utf8)

        // Sync (should delete extra files)
        let synchronizer = Synchronizer()
        let result = try await synchronizer.syncUnidirectional(
            source: sourceDir,
            destination: destDir
        )

        // Verify files deleted
        XCTAssertEqual(result.filesDeleted, 2)
        XCTAssertEqual(result.errors.count, 0)

        // Verify files removed from destination
        XCTAssertFalse(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("extra1.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("extra2.txt").path))
    }

    func testSyncUnidirectionalWithModifiedFiles() async throws {
        // Create directories with modified files
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create same file with different content
        try "source version".write(to: sourceDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "dest version".write(to: destDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        // Sync (should update file)
        let synchronizer = Synchronizer()
        let result = try await synchronizer.syncUnidirectional(
            source: sourceDir,
            destination: destDir
        )

        // Verify file updated
        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertEqual(result.errors.count, 0)

        // Verify content updated from source
        let content = try String(contentsOf: destDir.appendingPathComponent("file.txt"), encoding: .utf8)
        XCTAssertEqual(content, "source version")
    }

    func testSyncUnidirectionalDryRun() async throws {
        // Create directories with differences
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Source has new file, dest has extra file
        try "new".write(to: sourceDir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try "extra".write(to: destDir.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)

        // Sync with dry run
        let synchronizer = Synchronizer()
        var options = SyncOptions()
        options.dryRun = true

        let result = try await synchronizer.syncUnidirectional(
            source: sourceDir,
            destination: destDir,
            options: options
        )

        // Verify result shows what would happen
        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertEqual(result.filesDeleted, 1)

        // Verify NO actual changes made
        XCTAssertFalse(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("new.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("extra.txt").path))
    }

    func testSyncUnidirectionalVerify() async throws {
        // Create directories
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create files in source
        try "file content".write(to: sourceDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        // Sync with verification
        let synchronizer = Synchronizer()
        var options = SyncOptions()
        options.verifyAfterSync = true

        let result = try await synchronizer.syncUnidirectional(
            source: sourceDir,
            destination: destDir,
            options: options
        )

        // Should succeed without errors
        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertEqual(result.errors.count, 0)

        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("file.txt").path))
    }

    // MARK: - Step 5: Conflict Detection Tests

    func testDetectDivergedConflict() async throws {
        // Path exists in both with different content (diverged)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Same file, different content
        try "source content".write(to: sourceDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "dest content".write(to: destDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        // Create snapshots and compare
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Detect conflicts
        let detector = ConflictDetector()
        let conflicts = try detector.detectConflicts(difference: difference)

        // Should have 1 diverged conflict
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].type, .diverged)
        XCTAssertEqual(conflicts[0].path, "file.txt")
        XCTAssertNotNil(conflicts[0].sourceItem)
        XCTAssertNotNil(conflicts[0].destinationItem)
    }

    func testDetectOnlyInSourceConflict() async throws {
        // Path only in source
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // File only in source
        try "source only".write(to: sourceDir.appendingPathComponent("source_only.txt"), atomically: true, encoding: .utf8)

        // Create snapshots and compare
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Detect conflicts
        let detector = ConflictDetector()
        let conflicts = try detector.detectConflicts(difference: difference)

        // Should have 1 onlyInSource conflict
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].type, .onlyInSource)
        XCTAssertEqual(conflicts[0].path, "source_only.txt")
        XCTAssertNotNil(conflicts[0].sourceItem)
        XCTAssertNil(conflicts[0].destinationItem)
    }

    func testDetectOnlyInDestinationConflict() async throws {
        // Path only in destination
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // File only in destination
        try "dest only".write(to: destDir.appendingPathComponent("dest_only.txt"), atomically: true, encoding: .utf8)

        // Create snapshots and compare
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Detect conflicts
        let detector = ConflictDetector()
        let conflicts = try detector.detectConflicts(difference: difference)

        // Should have 1 onlyInDestination conflict
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].type, .onlyInDestination)
        XCTAssertEqual(conflicts[0].path, "dest_only.txt")
        XCTAssertNil(conflicts[0].sourceItem)
        XCTAssertNotNil(conflicts[0].destinationItem)
    }

    func testDetectNoConflictForIdentical() async throws {
        // Identical files should not be flagged as conflicts
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Same file, identical content
        let content = "identical content"
        try content.write(to: sourceDir.appendingPathComponent("identical.txt"), atomically: true, encoding: .utf8)
        try content.write(to: destDir.appendingPathComponent("identical.txt"), atomically: true, encoding: .utf8)

        // Create snapshots and compare
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Detect conflicts
        let detector = ConflictDetector()
        let conflicts = try detector.detectConflicts(difference: difference)

        // Should have NO conflicts (files are identical)
        XCTAssertEqual(conflicts.count, 0)
    }

    func testDetectMultipleConflictTypes() async throws {
        // Test all conflict types together
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Diverged: same file, different content
        try "source version".write(to: sourceDir.appendingPathComponent("diverged.txt"), atomically: true, encoding: .utf8)
        try "dest version".write(to: destDir.appendingPathComponent("diverged.txt"), atomically: true, encoding: .utf8)

        // Only in source
        try "source only".write(to: sourceDir.appendingPathComponent("source_only.txt"), atomically: true, encoding: .utf8)

        // Only in destination
        try "dest only".write(to: destDir.appendingPathComponent("dest_only.txt"), atomically: true, encoding: .utf8)

        // Identical (not a conflict)
        try "same".write(to: sourceDir.appendingPathComponent("identical.txt"), atomically: true, encoding: .utf8)
        try "same".write(to: destDir.appendingPathComponent("identical.txt"), atomically: true, encoding: .utf8)

        // Create snapshots and compare
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Detect conflicts
        let detector = ConflictDetector()
        let conflicts = try detector.detectConflicts(difference: difference)

        // Should have 3 conflicts (diverged, onlyInSource, onlyInDestination)
        XCTAssertEqual(conflicts.count, 3)

        var hasDiverged = false
        var hasOnlyInSource = false
        var hasOnlyInDestination = false

        for conflict in conflicts {
            switch conflict.type {
            case .diverged:
                hasDiverged = true
                XCTAssertEqual(conflict.path, "diverged.txt")
            case .onlyInSource:
                hasOnlyInSource = true
                XCTAssertEqual(conflict.path, "source_only.txt")
            case .onlyInDestination:
                hasOnlyInDestination = true
                XCTAssertEqual(conflict.path, "dest_only.txt")
            }
        }

        XCTAssertTrue(hasDiverged, "Should detect diverged conflict")
        XCTAssertTrue(hasOnlyInSource, "Should detect onlyInSource conflict")
        XCTAssertTrue(hasOnlyInDestination, "Should detect onlyInDestination conflict")
    }
}
